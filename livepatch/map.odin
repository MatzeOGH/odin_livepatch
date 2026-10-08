#+build windows amd64
package livepatch

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

load_exe_symbols :: proc(exe_path: string) {
	map_path := strings.concatenate({strings.trim_suffix(exe_path, filepath.ext(exe_path)), ".map"}, context.temp_allocator)
	symbols, starts := read_msvc_map(map_path, exe_base(), context.allocator)
	slice.sort(starts[:])
	exe_map, exe_starts = symbols, starts[:]
	load_exe_sections()
}

// `starts` is the live address of every symbol
read_msvc_map :: proc(map_path: string, base: uintptr, allocator := context.allocator, stable_keys := true) -> (index: map[string]uintptr, starts: [dynamic]uintptr) {
	index = make(map[string]uintptr, allocator)
	starts = make([dynamic]uintptr, allocator)
	data, read_err := os.read_entire_file_from_path(map_path, context.temp_allocator)
	if read_err != nil {
		return
	}

	Line :: struct {
		name:           string,
		live:           uintptr,
		linker_defined: bool,
	}
	lines := make([dynamic]Line, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)

	preferred: uintptr
	have_preferred := false
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if !have_preferred {
			if preferred_base, ok := parse_map_preferred_base(line); ok {
				preferred = preferred_base
				have_preferred = true
			}
			continue
		}
		name, va, ok := parse_map_line(line)
		if !ok || va == 0 {
			continue // va 0: an absolute symbol line
		}
		live := base + (va - preferred)
		append(&starts, live)
		append(&lines, Line{name, live, strings.has_suffix(strings.trim_space(line), "<linker-defined>")})
		append(&names, name)
	}

	keys: Static_Keys
	if stable_keys {
		keys = static_keys_make(names[:])
	}
	ambiguous := make(map[string]bool, context.temp_allocator)
	for line in lines {
		if !line.linker_defined {
			index_add(&index, &ambiguous, data_key(keys, line.name), line.live, allocator)
		}
	}
	// radlink also lists the name string of each export as a linker-defined symbol
	for line in lines {
		key := data_key(keys, line.name)
		if line.linker_defined && key not_in index && key not_in ambiguous {
			index_add(&index, &ambiguous, key, line.live, allocator)
		}
	}
	return
}

parse_map_preferred_base :: proc(line: string) -> (base: uintptr, ok: bool) {
	tag :: "Preferred load address is"
	tag_pos := strings.index(line, tag)
	if tag_pos < 0 {
		return
	}
	address := strconv.parse_uint(strings.trim_space(line[tag_pos + len(tag):]), 16) or_return
	return uintptr(address), true
}

// Parses "SSSS:OOOOOOOO  name  VA  lib:obj"
parse_map_line :: proc(line: string) -> (name: string, va: uintptr, ok: bool) {
	rest := line
	section_offset := strings.fields_iterator(&rest) or_return
	section, _, offset := strings.partition(section_offset, ":")
	strconv.parse_uint(section, 16) or_return
	strconv.parse_uint(offset, 16) or_return
	name_start := len(line) - len(rest)
	va_start := -1
	for field in strings.fields_iterator(&rest) {
		if address, is_hex := strconv.parse_uint(field, 16); is_hex && len(field) == 16 {
			va, va_start = uintptr(address), len(line) - len(rest) - len(field)
		}
	}
	if va_start < 0 {
		return
	}
	name = strings.trim_space(line[name_start:va_start])
	return name, va, name != ""
}

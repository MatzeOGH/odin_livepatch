#+build windows amd64
package livepatch

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

load_exe_symbols :: proc(exe_path: string) {
	starts := make([dynamic]uintptr)
	map_path := strings.concatenate({strings.trim_suffix(exe_path, filepath.ext(exe_path)), ".map"}, context.temp_allocator)
	exe_map = read_msvc_map(map_path, exe_base(), context.allocator, &starts)
	slice.sort(starts[:])
	exe_starts = starts[:]
}

// Reads an MSVC-format map
read_msvc_map :: proc(map_path: string, base: uintptr, allocator := context.allocator, starts: ^[dynamic]uintptr = nil) -> (index: map[string]uintptr) {
	index = make(map[string]uintptr, allocator)
	data, read_err := os.read_entire_file_from_path(map_path, context.temp_allocator)
	if read_err != nil {
		return
	}

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
		if starts != nil {
			append(starts, live)
		}
		key := canonical_data_name(name)
		if key not_in index {
			index[strings.clone(key, allocator)] = live
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

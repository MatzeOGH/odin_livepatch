#+build windows amd64
package livepatch

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

exe_map:    map[string]uintptr // canonical name -> live address
exe_starts: []uintptr          // sorted live address of every map symbol

load_exe_map :: proc(exe_path: string) {
	starts := make([dynamic]uintptr)
	map_path := strings.concatenate({strings.trim_suffix(exe_path, filepath.ext(exe_path)), ".map"}, context.temp_allocator)
	exe_map = read_map(map_path, exe_base(), context.allocator, &starts)
	slice.sort(starts[:])
	exe_starts = starts[:]
}

exe_symbol :: proc(name: string) -> (addr: rawptr, ok: bool) {
	a, found := exe_map[canonical_data_name(name)]
	return rawptr(a), found
}

// Reads an MSVC-format map
read_map :: proc(map_path: string, base: uintptr, allocator := context.allocator, starts: ^[dynamic]uintptr = nil) -> (index: map[string]uintptr) {
	index = make(map[string]uintptr, allocator)
	data, rerr := os.read_entire_file_from_path(map_path, context.temp_allocator)
	if rerr != nil {
		return
	}

	preferred: uintptr
	have_preferred := false
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		if !have_preferred {
			if p, ok := parse_preferred_line(line); ok {
				preferred = p
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

parse_preferred_line :: proc(line: string) -> (base: uintptr, ok: bool) {
	tag :: "Preferred load address is"
	i := strings.index(line, tag)
	if i < 0 {
		return
	}
	v := strconv.parse_uint(strings.trim_space(line[i + len(tag):]), 16) or_return
	return uintptr(v), true
}

// Parses "SSSS:OOOOOOOO  name  VA  lib:obj"
parse_map_line :: proc(line: string) -> (name: string, va: uintptr, ok: bool) {
	rest := line
	secoff := strings.fields_iterator(&rest) or_return
	sec, _, off := strings.partition(secoff, ":")
	strconv.parse_uint(sec, 16) or_return
	strconv.parse_uint(off, 16) or_return
	name_start := len(line) - len(rest)
	va_start := -1
	for tok in strings.fields_iterator(&rest) {
		if v, vok := strconv.parse_uint(tok, 16); vok && len(tok) == 16 {
			va, va_start = uintptr(v), len(line) - len(rest) - len(tok)
		}
	}
	if va_start < 0 {
		return
	}
	name = strings.trim_space(line[name_start:va_start])
	return name, va, name != ""
}

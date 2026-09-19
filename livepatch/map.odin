#+build windows
package livepatch

// Exe symbol lookup through the linker .map, for data the PDB drops. A file-private global
// and an @static local have internal linkage, so DbgHelp cannot see them (exe_symbol
// misses). The .map lists them with their address, so it is the only way to reach a
// base-build @static's live storage without a compiler change. Built with
// `-extra-linker-flags:"/MAP:<exe>.map"`, this reads the map once and returns the live
// runtime address for a canonical data name. No map beside the exe means every lookup
// misses and the caller falls back to the object copy.

import "core:os"
import "core:strings"
import win "core:sys/windows"

@(private) map_index:  map[string]uintptr
@(private) map_loaded: bool

// The live runtime address of a data symbol from the exe's .map, by canonical name.
exe_static_addr :: proc(canonical_name: string) -> (addr: rawptr, ok: bool) {
	if !map_loaded {
		load_exe_map()
		map_loaded = true
	}
	if a, hit := map_index[canonical_name]; hit {
		return rawptr(a), true
	}
	return nil, false
}

// Loads <exe>.map into map_index, shifting each address from the map's preferred base to
// the loaded image (ASLR-correct). A missing or unreadable map leaves the index empty.
@(private)
load_exe_map :: proc() {
	map_index = make(map[string]uintptr)

	base := uintptr(win.GetModuleHandleW(nil))
	if base == 0 {
		return
	}

	buf: [1024]u16
	n := win.GetModuleFileNameW(nil, &buf[0], len(buf))
	if n == 0 {
		return
	}
	exe_path, werr := win.wstring_to_utf8(win.wstring(&buf[0]), int(n), context.temp_allocator)
	if werr != nil {
		return
	}
	map_path := strings.concatenate({strip_ext(exe_path), ".map"}, context.temp_allocator)

	data, rerr := os.read_entire_file_from_path(map_path, context.temp_allocator)
	if rerr != nil {
		return
	}

	// The "Preferred load address is HHHH" line precedes the symbol table, so a single
	// pass has `preferred` set before any symbol line. First canonical name wins.
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
		if !ok {
			continue
		}
		key := canonical_data_name(name)
		if key not_in map_index {
			map_index[strings.clone(key)] = base + (va - preferred)
		}
	}
}

// Parses "Preferred load address is HHHH".
@(private)
parse_preferred_line :: proc(line: string) -> (base: uintptr, ok: bool) {
	tag :: "Preferred load address is"
	i := strings.index(line, tag)
	if i < 0 {
		return
	}
	tok, _ := next_token(line, i + len(tag))
	return parse_hex(tok)
}

// Parses "SSSS:OOOOOOOO  name  VA  lib:obj" into the symbol name and its preferred-base
// address. `ok` is false for header, section, and blank lines.
parse_map_line :: proc(line: string) -> (name: string, va: uintptr, ok: bool) {
	secoff, r0 := next_token(line, 0)
	if !is_sec_offset(secoff) {
		return
	}
	nm, r1 := next_token(line, r0)
	if nm == "" {
		return
	}
	addr, _ := next_token(line, r1)
	v, vok := parse_hex(addr)
	if !vok {
		return
	}
	return nm, v, true
}

@(private)
next_token :: proc(s: string, start: int) -> (tok: string, next: int) {
	i := start
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	j := i
	for j < len(s) && s[j] != ' ' && s[j] != '\t' {
		j += 1
	}
	return s[i:j], j
}

@(private)
is_sec_offset :: proc(tok: string) -> bool {
	colon := strings.index_byte(tok, ':')
	if colon <= 0 || colon == len(tok) - 1 {
		return false
	}
	for c, i in tok {
		if i == colon {
			continue
		}
		if !is_hex_digit(u8(c)) {
			return false
		}
	}
	return true
}

@(private)
parse_hex :: proc(s: string) -> (v: uintptr, ok: bool) {
	if len(s) == 0 {
		return
	}
	for i in 0 ..< len(s) {
		d: uintptr
		switch c := s[i]; {
		case c >= '0' && c <= '9': d = uintptr(c - '0')
		case c >= 'a' && c <= 'f': d = uintptr(c - 'a' + 10)
		case c >= 'A' && c <= 'F': d = uintptr(c - 'A' + 10)
		case:                      return 0, false
		}
		v = v * 16 + d
	}
	return v, true
}

@(private)
is_hex_digit :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// The path without its final extension, or the whole path if it has none.
@(private)
strip_ext :: proc(path: string) -> string {
	if dot := strings.last_index_byte(path, '.'); dot >= 0 {
		if strings.last_index_byte(path, '\\') < dot && strings.last_index_byte(path, '/') < dot {
			return path[:dot]
		}
	}
	return path
}

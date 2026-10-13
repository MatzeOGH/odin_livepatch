#+build windows amd64, linux amd64, darwin arm64
package livepatch

import "base:runtime"
import "core:strings"

// The exe's symbols, filled by load_exe_symbols of the platform.
exe_map:    map[string]uintptr // stable key (data_key)
exe_starts: []uintptr          // sorted live address of every exe symbol
exe_file:   []byte             // the exe file on disk
variable_sizes: map[uintptr]int

Exe_Section :: struct {
	name:        string,
	start:       uintptr, // live address
	size:        int,
	code:        bool,
	variable:    bool, // writable data that a patch binds to
	file_offset: int,  // of its bytes in exe_file
	file_size:   int,  // 0 for zero fill
}

exe_sections: []Exe_Section

exe_section_at :: proc(address: uintptr) -> (section: ^Exe_Section, ok: bool) {
	for &candidate in exe_sections {
		if address >= candidate.start && address < candidate.start + uintptr(candidate.size) {
			return &candidate, true
		}
	}
	return
}

exe_section_end :: proc(address: uintptr) -> int {
	if section, found := exe_section_at(address); found {
		return int(section.start) + section.size
	}
	return int(address)
}

exe_holds_code :: proc(address: uintptr) -> bool {
	section := exe_section_at(address) or_return
	return section.code
}

exe_holds_variable :: proc(address: uintptr) -> bool {
	section := exe_section_at(address) or_return
	return section.variable
}

exe_section_named :: proc(name: string) -> (address: uintptr, size: int, ok: bool) {
	section_name := name[strings.index_byte(name, ',') + 1:]
	for section in exe_sections {
		if section.name == section_name {
			return section.start, section.size, true
		}
	}
	return
}

exe_file_byte :: proc(address: uintptr) -> (file_byte: u8, ok: bool) {
	section := exe_section_at(address) or_return
	offset := int(address - section.start)
	if offset >= section.file_size || section.file_offset + offset >= len(exe_file) {
		return
	}
	return exe_file[section.file_offset + offset], true
}

exe_symbol_address :: proc(name: string, keys: Static_Keys = nil) -> (address: rawptr, ok: bool) {
	live, found := exe_map[data_key(keys, name)]
	return rawptr(live), found
}

index_add :: proc(index: ^map[string]uintptr, ambiguous: ^map[string]bool, key: string, address: uintptr, allocator: runtime.Allocator) {
	if key in ambiguous {
		return
	}
	if old, found := index[key]; found {
		if old != address {
			old_key, _ := delete_key(index, key)
			delete(old_key, allocator)
			ambiguous[key] = true
		}
		return
	}
	index[strings.clone(key, allocator)] = address
}

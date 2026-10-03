#+build windows amd64, linux amd64
package livepatch

import "base:runtime"
import "core:strings"

// The exe's symbols, filled by load_exe_symbols of the platform.
exe_map:    map[string]uintptr // stable key (data_key)
exe_starts: []uintptr          // sorted live address of every exe symbol
exe_file:   []byte             // the exe file on disk
variable_sizes: map[uintptr]int

exe_symbol_address :: proc(name: string, keys: Static_Keys = nil) -> (addr: rawptr, ok: bool) {
	live, found := exe_map[data_key(keys, name)]
	return rawptr(live), found
}

// Adds a symbol to an index of a module
index_add :: proc(index: ^map[string]uintptr, ambiguous: ^map[string]bool, key: string, addr: uintptr, allocator: runtime.Allocator) {
	if key in ambiguous {
		return
	}
	if old, found := index[key]; found {
		if old != addr {
			old_key, _ := delete_key(index, key)
			delete(old_key, allocator)
			ambiguous[key] = true
		}
		return
	}
	index[strings.clone(key, allocator)] = addr
}

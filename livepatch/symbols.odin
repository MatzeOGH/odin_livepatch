#+build windows amd64, linux amd64
package livepatch

// The exe's symbols, filled by load_exe_symbols of the platform.
exe_map:    map[string]uintptr // stable key (data_key)
exe_starts: []uintptr          // sorted live address of every exe symbol
exe_file:   []byte             // the exe file on disk

exe_symbol_address :: proc(name: string, keys: Static_Keys = nil) -> (addr: rawptr, ok: bool) {
	key := data_key(keys, name)
	if key == FRESH {
		return
	}
	live, found := exe_map[key]
	return rawptr(live), found
}

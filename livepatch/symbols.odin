#+build windows amd64, linux amd64
package livepatch

// The exe's symbols, filled by load_exe_symbols of the platform.
exe_map:    map[string]uintptr // canonical name -> live address
exe_starts: []uintptr          // sorted live address of every exe symbol

exe_symbol :: proc(name: string) -> (addr: rawptr, ok: bool) {
	a, found := exe_map[canonical_data_name(name)]
	return rawptr(a), found
}

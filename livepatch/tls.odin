#+build windows amd64
package livepatch

IMAGE_TLS_DIRECTORY64 :: struct #packed {
	start_address_of_raw_data: u64,
	end_address_of_raw_data:   u64,
	address_of_index:          u64,
	address_of_callbacks:      u64,
	size_of_zero_fill:         u32,
	characteristics:           u32,
}

// Returns false when the exe has no TLS directory.
tls_template_start :: proc "contextless" () -> (start: uintptr, ok: bool) {
	base := exe_base()
	rva := pe_headers(rawptr(base)).OptionalHeader.TLSTable.VirtualAddress
	if rva == 0 {
		return
	}
	dir := (^IMAGE_TLS_DIRECTORY64)(rawptr(base + uintptr(rva)))
	return uintptr(dir.start_address_of_raw_data), true
}

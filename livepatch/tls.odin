#+build windows
package livepatch

// Thread-local storage support for SECREL relocations.
//
// A SECREL relocation patches a 32-bit field with a thread-local's offset inside the TLS
// block. The running code adds that offset to this thread's block base, so each thread
// reads its own copy. The offset is the variable's live address minus the TLS template
// start, both from the loaded image, so it is correct under ASLR.
//
// DbgHelp sees only a package-level @thread_local. A file-private or @static thread-local
// is resolved from the .map instead (map.odin), so it needs the exe built with /MAP.

import win "core:sys/windows"

// The PE TLS data directory, entry 9 of the optional header's data directory. Its address
// fields are relocated with the image, so a value read from the loaded image is live.
IMAGE_TLS_DIRECTORY64 :: struct #packed {
	start_address_of_raw_data: u64,
	end_address_of_raw_data:   u64,
	address_of_index:          u64,
	address_of_callbacks:      u64,
	size_of_zero_fill:         u32,
	characteristics:           u32,
}

@(private) tls_start_cached: uintptr
@(private) tls_start_ok:     bool
@(private) tls_start_done:   bool

// The loaded start address of the exe's TLS template, the base a thread-local's offset is
// measured from. `ok` is false when the exe has no TLS directory. The template does not
// move, so the result is cached for the process.
tls_template_start :: proc() -> (start: uintptr, ok: bool) {
	if tls_start_done {
		return tls_start_cached, tls_start_ok
	}
	tls_start_done = true

	base := uintptr(win.GetModuleHandleW(nil))
	if base == 0 {
		return
	}
	e_lfanew := (^i32)(rawptr(base + 0x3c))^
	nt := base + uintptr(e_lfanew)
	// IMAGE_NT_HEADERS64: Signature(4) + FileHeader(20) + OptionalHeader. In the
	// PE32+ optional header the data directory starts at offset 112, and the TLS
	// directory is entry 9 (each entry is 8 bytes).
	dd := nt + 4 + 20 + 112 + 9 * 8
	rva := (^u32)(rawptr(dd))^
	if rva == 0 {
		return
	}
	dir := (^IMAGE_TLS_DIRECTORY64)(rawptr(base + uintptr(rva)))

	tls_start_cached = uintptr(dir.start_address_of_raw_data)
	tls_start_ok = true
	return tls_start_cached, true
}

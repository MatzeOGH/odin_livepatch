#+build windows amd64, linux amd64
package livepatch

import "base:runtime"
import "core:slice"
import "core:strings"

Redirect_Site :: struct {
	site:    rawptr,
	tramp:   rawptr,
	written: bool,
}

@(private) sites: map[rawptr]Redirect_Site // keyed by the exe entry

// Sets up the stubs and the trampoline
prepare_redirects :: proc(merged: ^Merged) -> Error {
	failed := make([dynamic]string, context.temp_allocator)
	for redirect in merged.redirects {
		if redirect.exe_address in sites {
			continue
		}
		planned, result := plan_site(redirect.exe_address)
		switch result {
		case .Ok:
			sites[redirect.exe_address] = planned
		case .Breakpoint:
			append(&failed, redirect.name)
		case .No_Memory:
			return Load_Failed{kind = .No_Stub_Memory, os_error = last_alloc_error()}
		}
	}
	if len(failed) > 0 {
		return Breakpoint_In_Redirect{strings.join(failed[:], "\n", runtime.heap_allocator())}
	}
	return nil
}

Plan_Result :: enum {
	Ok,
	Breakpoint,
	No_Memory,
}

slots: map[string]rawptr

// The trampoline that a procedure without a redirect is reached through
slot_for :: proc(name: string) -> rawptr {
	if slot, found := slots[name]; found {
		return slot
	}
	slot, ok := alloc_tramp()
	if ok {
		slots[strings.clone(name)] = slot
	}
	return slot
}

// The bytes up to the next symbol or the section end.
exe_room :: proc(entry: rawptr) -> int {
	addr := uintptr(entry)
	room := exe_section_end(addr) - int(addr)
	next, _ := slice.binary_search(exe_starts, addr + 1)
	if next < len(exe_starts) {
		room = min(room, int(exe_starts[next] - addr))
	}
	return max(room, 0)
}


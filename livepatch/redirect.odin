#+build windows amd64, linux amd64, darwin arm64
package livepatch

import "base:runtime"
import "core:slice"
import "core:strings"

Redirect_Site :: struct {
	site:    rawptr,
	tramp:   rawptr,
	call:    rawptr,
	written: bool,
}

sites: map[rawptr]Redirect_Site // keyed by the exe entry

call_target :: proc(merged: ^Merged, name: string) -> rawptr {
	addr := merged.defs[name]
	if redirect_site, found := sites[addr]; found {
		return redirect_site.call
	}
	return addr // a slot, or a procedure without a redirect
}

prepare_redirects :: proc(merged: ^Merged) -> Error {
	failed := make([dynamic]string, context.temp_allocator)
	for redirect in merged.redirects {
		if redirect.from in sites {
			continue
		}
		planned, result := plan_site(redirect.from)
		switch result {
		case .Ok:
			sites[redirect.from] = planned
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

exe_room :: proc(entry: rawptr) -> int {
	addr := uintptr(entry)
	room := exe_section_end(addr) - int(addr)
	next, _ := slice.binary_search(exe_starts, addr + 1)
	if next < len(exe_starts) {
		room = min(room, int(exe_starts[next] - addr))
	}
	return max(room, 0)
}

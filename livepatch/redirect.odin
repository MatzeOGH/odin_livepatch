#+build windows amd64, linux amd64, darwin arm64
package livepatch

import "base:runtime"
import "core:mem"
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

near_range :: proc(reach := BRANCH_REACH) -> (lo, hi: uintptr, ok: bool) {
	size := exe_image_size()
	if size >= reach {
		return
	}
	window := (reach - size) / 2
	lo = exe_base() > window ? exe_base() - window : 0
	return lo, exe_base() + size + window, true
}

is_near :: proc(addr: uintptr) -> bool {
	lo, hi, ok := near_range()
	return ok && addr >= lo && addr < hi
}

alloc_near :: proc(size: int, commit := true, reach := BRANCH_REACH, from := uintptr(0)) -> rawptr {
	lo, hi, ok := near_range(reach)
	if !ok {
		return nil
	}
	STEP :: uintptr(0x0010_0000)
	GRANULE :: uintptr(0x10000) // the allocation granularity of Windows, a multiple of each page size
	rounded := mem.align_forward_uintptr(uintptr(size), GRANULE)
	top := mem.align_forward_uintptr(exe_base() + exe_image_size(), GRANULE)
	bottom := mem.align_backward_uintptr(exe_base(), GRANULE)
	for offset := from; ; offset += STEP {
		tried := false
		if above := top + offset; above + rounded <= hi {
			tried = true
			if memory := page_alloc_at(above, size, commit); memory != nil {
				return memory
			}
		}
		if bottom >= offset + rounded && bottom - offset - rounded >= lo {
			tried = true
			if memory := page_alloc_at(bottom - offset - rounded, size, commit); memory != nil {
				return memory
			}
		}
		if !tried {
			return nil
		}
	}
}

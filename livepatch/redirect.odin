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
	for r in merged.redirects {
		if r.exe_address in sites {
			continue
		}
		s, result := plan_site(r.exe_address)
		switch result {
		case .Ok:
			sites[r.exe_address] = s
		case .Breakpoint:
			append(&failed, r.name)
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
	if s, found := slots[name]; found {
		return s
	}
	s, ok := alloc_tramp()
	if ok {
		slots[strings.clone(name)] = s
	}
	return s
}

// The bytes up to the next symbol or the section end.
exe_room :: proc(entry: rawptr) -> int {
	a := uintptr(entry)
	room := exe_section_end(a) - int(a)
	i, _ := slice.binary_search(exe_starts, a + 1)
	if i < len(exe_starts) {
		room = min(room, int(exe_starts[i] - a))
	}
	return max(room, 0)
}


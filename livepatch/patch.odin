#+build windows amd64, linux amd64
package livepatch

import "base:runtime"
import "core:time"

// Each attempt that fails the RIP check waits 1 ms
MAX_ATTEMPTS :: 100

// Returns false with no change if it finds no safe moment to write.
commit :: proc(merged: ^Merged, pre_hooks, post_hooks: []Patch_Hook, changed: []Type_Change) -> (ok: bool) {
	unwritten := make([dynamic]rawptr, 0, len(merged.redirects), context.temp_allocator) // keys of sites
	for redirect in merged.redirects {
		redirect_site := sites[redirect.from] or_return
		if !redirect_site.written {
			append(&unwritten, redirect.from)
		}
	}

	exe_type_table: ^[]^runtime.Type_Info
	if merged.type_table_new != nil {
		if addr, found := exe_symbol_address("runtime::type_table"); found {
			exe_type_table = (^[]^runtime.Type_Info)(addr)
		}
	}

	handles: Suspended_Threads
	suspended := false
	for _ in 0 ..< MAX_ATTEMPTS {
		all_stopped: bool
		handles, all_stopped = suspend_others()
		if all_stopped && !ip_conflicts(handles, unwritten[:]) {
			suspended = true
			break
		}
		resume_all(handles)
		time.sleep(time.Millisecond)
	}
	if !suspended {
		return false
	}
	fire_hooks(pre_hooks, changed)

	for redirect in merged.redirects {
		write_tramp_target(sites[redirect.from].tramp, redirect.body)
	}
	if !write_sites(unwritten[:]) {
		resume_all(handles)
		return false
	}
	for slot_target in merged.slot_targets {
		write_tramp_target(slot_target.from, slot_target.body)
	}
	// Old exe code then also sees the new types
	if exe_type_table != nil {
		exe_type_table^ = (^[]^runtime.Type_Info)(merged.type_table_new)^
	}
	fire_hooks(post_hooks, changed)
	resume_all(handles)
	return true
}

// True when `pc` is in the jmp of a site that the commit writes
in_unwritten_site :: proc(pc: uintptr, unwritten: []rawptr) -> bool {
	for key in unwritten {
		site := uintptr(sites[key].site)
		if pc >= site && pc < site + REDIRECT_SIZE {
			return true
		}
	}
	return false
}

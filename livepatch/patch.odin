#+build windows amd64, linux amd64
package livepatch

import "base:runtime"
import "core:time"

// Each attempt that fails the RIP check waits 1 ms
MAX_ATTEMPTS :: 100

// [lo, hi)
@(private)
Range :: struct {
	lo: uintptr,
	hi: uintptr,
}

// Returns false with no change if it finds no safe moment to write.
commit :: proc(merged: ^Merged, pre_hooks, post_hooks: []Patch_Hook, changed: []Type_Change) -> (ok: bool) {
	regions := make([dynamic]Range, 0, len(merged.redirects), context.temp_allocator)
	unwritten := make([dynamic]Redirect_Site, 0, len(merged.redirects), context.temp_allocator)
	for redirect in merged.redirects {
		redirect_site := sites[redirect.exe_address] or_return
		if !redirect_site.written {
			append(&regions, Range{uintptr(redirect_site.site), uintptr(redirect_site.site) + REDIRECT_SIZE})
			append(&unwritten, redirect_site)
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
		if all_stopped && !ip_conflicts(handles, regions[:]) {
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
		write_tramp_target(sites[redirect.exe_address].tramp, redirect.body)
	}
	write_sites(unwritten[:])
	for slot_target in merged.slot_targets {
		write_tramp_target(slot_target.slot, slot_target.body)
	}
	// Old exe code then also sees the new types
	if exe_type_table != nil {
		exe_type_table^ = (^[]^runtime.Type_Info)(merged.type_table_new)^
	}
	fire_hooks(post_hooks, changed)
	resume_all(handles)

	for redirect in merged.redirects {
		if redirect_site, found := &sites[redirect.exe_address]; found {
			redirect_site.written = true
		}
	}
	return true
}

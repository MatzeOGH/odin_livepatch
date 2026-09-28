#+build windows amd64, linux amd64
package livepatch

import "base:runtime"

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
	for r in merged.redirects {
		s := sites[r.exe_address] or_return
		if !s.written {
			append(&regions, Range{uintptr(s.site), uintptr(s.site) + 5})
		}
	}

	tt_exe: ^[]^runtime.Type_Info
	if merged.type_table_new != nil {
		if addr, found := exe_symbol("runtime::type_table"); found {
			tt_exe = (^[]^runtime.Type_Info)(addr)
		}
	}

	handles: Suspended_Threads
	suspended := false
	for _ in 0 ..< MAX_ATTEMPTS {
		all: bool
		handles, all = suspend_others()
		if all && !ip_conflicts(handles, regions[:]) {
			suspended = true
			break
		}
		resume_all(handles)
		sleep_briefly()
	}
	if !suspended {
		return false
	}
	fire_hooks(pre_hooks, changed)

	for r in merged.redirects {
		// The trampoline first, so a new site never reaches an old target.
		s := sites[r.exe_address]
		write_tramp_target(s.tramp, r.body)
		if !s.written {
			write_site_bytes(s)
			flush_icache(s.site, 5)
		}
	}
	for s in merged.slot_targets {
		write_tramp_target(s.slot, s.body)
	}
	// Old exe code then also sees the new types
	if tt_exe != nil {
		tt_exe^ = (^[]^runtime.Type_Info)(merged.type_table_new)^
	}
	fire_hooks(post_hooks, changed)
	resume_all(handles)

	for r in merged.redirects {
		if s, found := &sites[r.exe_address]; found {
			s.written = true
		}
	}
	return true
}

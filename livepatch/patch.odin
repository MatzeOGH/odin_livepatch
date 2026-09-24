#+build windows amd64
package livepatch

import "base:runtime"
import "core:slice"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	FlushInstructionCache :: proc(hProcess: win.HANDLE, lpBaseAddress: rawptr, dwSize: win.SIZE_T) -> win.BOOL ---
	GetThreadId           :: proc(Thread: win.HANDLE) -> win.DWORD ---
}

foreign import ntdll "system:ntdll.lib"

@(default_calling_convention = "system")
foreign ntdll {
	NtGetNextThread :: proc(process, thread: win.HANDLE, access: win.DWORD, attributes, flags: win.ULONG, next: ^win.HANDLE) -> i32 ---
}

CONTEXT_CONTROL :: 0x0010_0001

// Each attempt that fails the RIP check waits 1 ms
MAX_ATTEMPTS :: 100

// [lo, hi)
@(private = "file")
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

	handles: [dynamic]win.HANDLE
	suspended := false
	for _ in 0 ..< MAX_ATTEMPTS {
		all: bool
		handles, all = suspend_others()
		if all && !ip_conflicts(handles[:], regions[:]) {
			suspended = true
			break
		}
		resume_all(handles)
		win.Sleep(1)
	}
	if !suspended {
		return false
	}
	fire_hooks(pre_hooks, changed)

	proc_handle := win.GetCurrentProcess()
	for r in merged.redirects {
		// The trampoline first, so a new site never reaches an old target.
		s := sites[r.exe_address]
		write_tramp_target(s.tramp, r.body)
		if !s.written {
			write_site_bytes(s)
			FlushInstructionCache(proc_handle, s.site, 5)
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

// suspend other threads so we can patch
suspend_others :: proc() -> (handles: [dynamic]win.HANDLE, ok: bool) {
	ids := make([dynamic]win.DWORD, context.temp_allocator)
	scan_threads(&handles, &ids, grow = true)
	reserve(&handles, 2 * len(handles) + 64)
	reserve(&ids, cap(handles))
	for t in handles {
		win.SuspendThread(t)
	}
	for {
		found, fits := scan_threads(&handles, &ids, grow = false)
		if !fits {
			return handles, false
		}
		if !found {
			return handles, true
		}
	}
}

scan_threads :: proc(handles: ^[dynamic]win.HANDLE, ids: ^[dynamic]win.DWORD, grow: bool) -> (found, fits: bool) {
	ACCESS :: win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_QUERY_LIMITED_INFORMATION

	me := win.GetCurrentThreadId()
	fits = true
	cur, next: win.HANDLE
	kept := false
	for NtGetNextThread(win.GetCurrentProcess(), cur, ACCESS, 0, 0, &next) >= 0 {

		if cur != nil && !kept {
			win.CloseHandle(cur)
		}
		cur, kept = next, false
		id := GetThreadId(cur)
		if id == me || slice.contains(ids[:], id) {
			continue
		}
		if !grow && len(handles) == cap(handles) {
			fits = false
			continue
		}
		if !grow {
			win.SuspendThread(cur)
		}
		append(handles, cur)
		append(ids, id)
		kept, found = true, true
	}
	if cur != nil && !kept {
		win.CloseHandle(cur)
	}
	return
}

ip_conflicts :: proc(handles: []win.HANDLE, regions: []Range) -> bool {
	for h in handles {
		ctx: win.CONTEXT
		ctx.ContextFlags = CONTEXT_CONTROL
		if !win.GetThreadContext(h, &ctx) {
			continue
		}
		rip := uintptr(ctx.Rip)
		for reg in regions {
			if rip >= reg.lo && rip < reg.hi {
				return true
			}
		}
	}
	return false
}

resume_all :: proc(handles: [dynamic]win.HANDLE) {
	#reverse for h in handles {
		win.ResumeThread(h)
		win.CloseHandle(h)
	}
	delete(handles)
}

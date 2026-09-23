#+build windows
package livepatch

// The write step: halt the world, redirect procedures, resume.
//
// After bind.odin and reloc.odin, the new code is mapped and relocated but nothing live
// jumps to it yet. `commit` suspends every other thread, checks none is mid-overwrite,
// writes a 5-byte `jmp rel32` at each exe entry, fills each slot, flushes the icache, and
// resumes.
//
// Correctness rule: a patched procedure is only ever entered at its new entry. A frame
// already in flight runs the old body to completion; later calls reach the new body
// through the stable address. So the only unsafe state is a suspended thread whose RIP is
// inside the 5 bytes being overwritten, [entry, entry+5). Deeper in the old body is safe.

import win "core:sys/windows"

// CONTEXT_CONTROL (missing from core:sys/windows): selects the control registers,
// including Rip, in GetThreadContext.
CONTEXT_CONTROL :: 0x0010_0001

// Retry budget for the RIP check. Each miss resumes, sleeps 1 ms, and tries again.
MAX_ATTEMPTS :: 100

// A half-open address range [lo, hi) covering a redirect's overwritten bytes.
@(private = "file")
Range :: struct {
	lo: uintptr,
	hi: uintptr,
}

// Suspends every other thread, runs the hooks around the publication, writes both merge
// lists, then resumes. Returns false without changing any code if a redirect is out of
// rel32 range, a page cannot be made writable, or no safe moment to write is found. Hooks
// run while the other threads are paused, so they must not allocate, block, or take a lock
// a paused thread could hold.
commit :: proc(merged: ^Merged, pre_hooks, post_hooks: []Patch_Hook, changed: []Type_Change) -> (ok: bool) {
	n := len(merged.redirects)

	Saved_Prot :: struct {
		addr: rawptr,
		old:  win.DWORD,
		size: win.SIZE_T,
	}
	saved := make([dynamic]Saved_Prot, 0, n + 1, context.temp_allocator)
	regions := make([dynamic]Range, 0, n, context.temp_allocator)

	// Reverse order: for a shared page, only the first entry holds the original protection.
	defer #reverse for s in saved {
		old: win.DWORD
		win.VirtualProtect(s.addr, s.size, s.old, &old)
	}

	// Prepare before any thread is suspended: validate each rel32 and make each redirect
	// site writable. Slot blocks are already writable-and-executable from alloc_near.
	for r in merged.redirects {
		rel := i64(uintptr(r.body)) - (i64(uintptr(r.exe_address)) + 5)
		if rel < i64(min(i32)) || rel > i64(max(i32)) {
			return false
		}
		old: win.DWORD
		if !win.VirtualProtect(r.exe_address, 5, win.PAGE_EXECUTE_READWRITE, &old) {
			return false
		}
		append(&saved, Saved_Prot{r.exe_address, old, 5})
		append(&regions, Range{uintptr(r.exe_address), uintptr(r.exe_address) + 5})
	}

	// Make the exe's runtime.type_table slice header writable for the swap (it sits in
	// read-only .rdata). It is data, so no suspended thread can stop inside it: no region.
	SLICE_HDR :: size_of(rawptr) + size_of(int)
	tt_exe: rawptr
	if merged.type_table_new != nil {
		if addr, _, found := exe_symbol("runtime::type_table"); found {
			old: win.DWORD
			if !win.VirtualProtect(addr, SLICE_HDR, win.PAGE_READWRITE, &old) {
				return false
			}
			append(&saved, Saved_Prot{addr, old, SLICE_HDR})
			tt_exe = addr
		}
	}

	// The halt window. If a thread sits inside a region being overwritten, resume, wait,
	// and try again.
	handles: [dynamic]win.HANDLE
	suspended := false
	for _ in 0 ..< MAX_ATTEMPTS {
		enumerated: bool
		handles, enumerated = suspend_others()
		if !enumerated {
			return false
		}
		if !ip_conflicts(handles[:], regions[:]) {
			suspended = true
			break
		}
		resume_all(handles)
		win.Sleep(1)
	}
	if !suspended {
		return false
	}
	// Pre hooks still reach old code; post hooks reach the new bodies after the redirects
	// below are written.
	fire_hooks(pre_hooks, changed)

	// Inside the window: memory writes and cache flushes only. No allocation and no
	// printing, because a suspended thread may hold the heap or console lock.
	proc_handle := win.GetCurrentProcess()
	for r in merged.redirects {
		write_redirect_bytes(r.exe_address, r.body)
	}
	for s in merged.slot_targets {
		write_slot_target(s.slot, s.body)
	}
	for r in merged.redirects {
		FlushInstructionCache(proc_handle, r.exe_address, 5)
	}
	// Swap the exe's type_table to the new build's array by copying the 16-byte slice
	// header, so pruned or frozen exe code sees the new types. The halt prevents a torn
	// read during a typeid lookup.
	if tt_exe != nil {
		(^[SLICE_HDR]u8)(tt_exe)^ = (^[SLICE_HDR]u8)(merged.type_table_new)^
	}
	fire_hooks(post_hooks, changed)
	resume_all(handles)

	return true
}

// Writes the 5-byte `E9 rel32` redirect. The caller validated the range and made the page
// writable, so this only stores bytes. Contextless, so it is safe inside the halt window.
@(private = "file")
write_redirect_bytes :: proc "contextless" (exe_address, body: rawptr) {
	rel := i32(i64(uintptr(body)) - (i64(uintptr(exe_address)) + 5))
	(^u8)(exe_address)^ = 0xE9
	(^i32)(rawptr(uintptr(exe_address) + 1))^ = rel
}

// Opens a handle to every other thread in this process, then suspends them all. The two
// passes matter: every allocation happens in the first pass, before any thread is
// suspended, so a suspended thread can never hold the allocator lock. Enumeration uses the
// toolhelp snapshot, which avoids an ntdll binding.
@(private = "file")
suspend_others :: proc() -> (handles: [dynamic]win.HANDLE, ok: bool) {
	snapshot := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0)
	if snapshot == win.INVALID_HANDLE_VALUE {
		return
	}
	defer win.CloseHandle(snapshot)

	me_pid := win.GetCurrentProcessId()
	me_tid := win.GetCurrentThreadId()

	ACCESS :: win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_QUERY_LIMITED_INFORMATION

	te: win.THREADENTRY32
	te.dwSize = size_of(te)
	if win.Thread32First(snapshot, &te) {
		for {
			if te.th32OwnerProcessID == me_pid && te.th32ThreadID != me_tid {
				h := win.OpenThread(ACCESS, false, te.th32ThreadID)
				if h != nil && h != win.INVALID_HANDLE_VALUE {
					append(&handles, h)
				}
			}
			if !win.Thread32Next(snapshot, &te) {
				break
			}
		}
	}

	for h in handles {
		win.SuspendThread(h)
	}
	return handles, true
}

// Reports whether any suspended thread's RIP is inside a region about to be overwritten.
@(private = "file")
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

// Resumes and closes every handle, then frees the list, in reverse of the suspend order.
@(private = "file")
resume_all :: proc(handles: [dynamic]win.HANDLE) {
	#reverse for h in handles {
		win.ResumeThread(h)
		win.CloseHandle(h)
	}
	delete(handles)
}

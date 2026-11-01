package main

// Debugger breakpoints on the first instruction of a procedure and on the one after it
// block the redirect: patch() returns Breakpoint_In_Redirect, and the old code keeps
// running. On x64 the test does not know the length of the first instruction, so it writes
// an int3 on each of bytes 0 to 8. On arm64 it writes a brk on each of the first two
// instructions. After the debugger removes them, the next patches work.

import lp "../../../livepatch"
import "core:fmt"
@(require) import "core:mem"
import "core:os"
@(require) import "core:sys/posix"
@(require) import win "core:sys/windows"

VERSION :: #config(VERSION, 1)

sum :: #force_no_inline proc(xs: []int) -> (total: int) {
	for x in xs {
		total += x
	}
	return
}

// The stack array makes a frame
guarded :: #force_no_inline proc(n: int) -> int {
	buf: [64]int
	for &x, i in buf {
		x = i * n
	}
	return sum(buf[:]) + VERSION
}

// The breakpoint of a debugger: int3 on x64, brk #0 in place of a whole instruction on arm64.
// UNITS: bytes 0 to 8 on x64, the first two instructions on arm64.
when ODIN_ARCH == .arm64 {
	Code_Unit :: u32
	BREAKPOINT :: Code_Unit(0xD420_0000)
	UNITS :: 2
} else {
	Code_Unit :: u8
	BREAKPOINT :: Code_Unit(0xCC)
	UNITS :: 9
}

when ODIN_OS == .Darwin {
	foreign import libSystem "system:System"
	@(default_calling_convention = "c")
	foreign libSystem {
		sys_icache_invalidate :: proc(start: rawptr, size: uint) ---
		mach_task_self        :: proc() -> u32 ---
		mach_vm_remap         :: proc(target_task: u32, address: ^u64, size, mask: u64, flags: i32, source_task: u32,
		                              source_address: u64, copy: b32, current, maximum: ^i32, inheritance: u32) -> i32 ---
	}
	VM_FLAGS_OVERWRITE :: 0x4000 // with VM_FLAGS_FIXED, which is 0
	VM_INHERIT_COPY    :: 1
}

// Writes code in the exe, as a debugger does to set or remove a breakpoint
code_write :: proc(address: rawptr, unit: Code_Unit) {
	when ODIN_OS == .Darwin {
		// macOS does not let exe code be writable: map a changed copy over its page
		PAGE :: 0x4000
		page := uintptr(address) &~ (PAGE - 1)
		copy_page := posix.mmap(nil, PAGE, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
		mem.copy_non_overlapping(copy_page, rawptr(page), PAGE)
		(^Code_Unit)(uintptr(copy_page) + uintptr(address) - page)^ = unit
		posix.mprotect(copy_page, PAGE, {.READ, .EXEC})
		target := u64(page)
		current, maximum: i32
		task := mach_task_self()
		mach_vm_remap(task, &target, PAGE, 0, VM_FLAGS_OVERWRITE, task, u64(uintptr(copy_page)), true, &current, &maximum, VM_INHERIT_COPY)
		posix.munmap(copy_page, PAGE)
		sys_icache_invalidate(rawptr(page), PAGE)
	} else when ODIN_OS == .Windows {
		old: win.DWORD
		win.VirtualProtect(address, 16, win.PAGE_EXECUTE_READWRITE, &old)
		(^Code_Unit)(address)^ = unit
	} else {
		// The two pages that the first 16 bytes can touch
		page := rawptr(uintptr(address) &~ 4095)
		posix.mprotect(page, 8192, {.READ, .WRITE, .EXEC})
		(^Code_Unit)(address)^ = unit
	}
}

// Writes a breakpoint on each of the first units, as a debugger does
breakpoints_set :: proc(entry: rawptr) -> (original: [UNITS]Code_Unit) {
	units := ([^]Code_Unit)(entry)
	for i in 0 ..< UNITS {
		original[i] = units[i]
		code_write(&units[i], BREAKPOINT)
	}
	return
}

// Writes back the units that the debugger saved, as a debugger does when it removes a breakpoint
breakpoints_remove :: proc(entry: rawptr, original: [UNITS]Code_Unit) {
	units := ([^]Code_Unit)(entry)
	for i in 0 ..< UNITS {
		code_write(&units[i], original[i])
	}
}

checks :: proc(v: int) {
	check("value", guarded(1), 2016 + v)
}

@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	checks(1)
	original := breakpoints_set(rawptr(guarded))
	_, rejected := patch_to(2).(lp.Breakpoint_In_Redirect)
	breakpoints_remove(rawptr(guarded), original)
	check("rejected: Breakpoint_In_Redirect", rejected, true)
	checks(1)
	check("patch", patch_to(3), nil)
	checks(3)
	check("patch", patch_to(4), nil)
	checks(4)
	os.exit(failures == 0 ? 0 : 1)
}

// The test harness. Each test has its own copy. A test defines LAST_VERSION, setup and checks, or its own main.

// The build script that patch() runs
BUILD_SCRIPT :: "build.bat" when ODIN_OS == .Windows else "build.sh"

failures: int

check :: proc(label: string, got, want: $T) {
	ok := got == want
	if !ok {
		failures += 1
	}
	fmt.printfln("  %-44s %v (want %v) %s", label, got, want, ok ? "OK" : "FAIL")
}

// Builds version v and patches it in. patch() runs the build script with the environment of this process.
patch_to :: proc(v: int) -> lp.Error {
	fmt.printfln("v%d", v)
	os.set_env("VERSION", fmt.tprint(v))
	return lp.patch(BUILD_SCRIPT)
}

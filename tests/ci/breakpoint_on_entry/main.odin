package main

// A debugger breakpoint (int3) is on the first byte of a procedure during the first patch.
// After the debugger removes it, a call from the exe and a direct call from patch code must
// both keep the stack correct.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
@(require) import "core:sys/posix"
@(require) import win "core:sys/windows"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

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

call_guarded :: #force_no_inline proc(n: int) -> int {
	return guarded(n)
}

// Makes the first bytes of a procedure writable, as a debugger does to write a breakpoint
make_code_writable :: proc(entry: rawptr) {
	when ODIN_OS == .Windows {
		old: win.DWORD
		win.VirtualProtect(entry, 16, win.PAGE_EXECUTE_READWRITE, &old)
	} else {
		// The two pages that the first 16 bytes can touch
		page := rawptr(uintptr(entry) &~ 4095)
		posix.mprotect(page, 8192, {.READ, .WRITE, .EXEC})
	}
}

// Writes an int3 on the first byte of a procedure, as a debugger does for a breakpoint
breakpoint_set :: proc(entry: rawptr) -> (original: u8) {
	make_code_writable(entry)
	original = (^u8)(entry)^
	(^u8)(entry)^ = 0xCC
	return
}

setup :: proc() {}

checks :: proc(v: int) {
	check("call from the exe", guarded(1), 2016 + v)
	check("direct call from patch code", call_guarded(1), 2016 + v)
}

@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	checks(1)
	original := breakpoint_set(rawptr(guarded))
	err := patch_to(2)
	(^u8)(rawptr(guarded))^ = original // the debugger removes the breakpoint
	check("patch", err, nil)
	checks(2)
	check("patch", patch_to(3), nil)
	checks(3)
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

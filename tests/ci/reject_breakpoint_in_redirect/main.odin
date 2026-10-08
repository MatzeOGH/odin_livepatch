package main

// Debugger breakpoints (int3) on the first byte of a procedure and on the byte after its first
// instruction block the redirect: patch() returns Breakpoint_In_Redirect, and the old code keeps
// running. The test does not know the length of the first instruction, so it writes a breakpoint
// on each of bytes 0 to 8. After the debugger removes them, the next patches work.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import win "core:sys/windows"

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

BYTES :: 9

// Writes an int3 on each of the first bytes, as a debugger does for a breakpoint
breakpoints_set :: proc(entry: rawptr) -> (original: [BYTES]u8) {
	old: win.DWORD
	win.VirtualProtect(entry, 16, win.PAGE_EXECUTE_READWRITE, &old)
	bytes := ([^]u8)(entry)
	for i in 0 ..< BYTES {
		original[i] = bytes[i]
		bytes[i] = 0xCC
	}
	return
}

// Writes back the bytes that the debugger saved, as a debugger does when it removes a breakpoint
breakpoints_remove :: proc(entry: rawptr, original: [BYTES]u8) {
	bytes := ([^]u8)(entry)
	for i in 0 ..< BYTES {
		bytes[i] = original[i]
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

failures: int

check :: proc(label: string, got, want: $T) {
	ok := got == want
	if !ok {
		failures += 1
	}
	fmt.printfln("  %-44s %v (want %v) %s", label, got, want, ok ? "OK" : "FAIL")
}

// Builds version v and patches it in. patch() runs build.bat with the environment of this process.
patch_to :: proc(v: int) -> lp.Error {
	fmt.printfln("v%d", v)
	os.set_env("VERSION", fmt.tprint(v))
	return lp.patch("build.bat")
}

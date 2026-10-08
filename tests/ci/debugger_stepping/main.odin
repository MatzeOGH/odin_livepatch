package main

// Under a debugger (debugger.ps1, debugger_gdb.sh, debugger_lldb.sh): stepping. main is the code
// of the exe, which no patch changes. It calls target, which each patch changes. At a breakpoint on
// the call, the debugger steps into target and must arrive in the body of the newest version: in
// v2 and v3, through the jump from the old body of the exe into the patch. It then steps over a
// line, reads body_version, and finishes target with its return value. Without a debugger, the
// test checks the values only.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

// zero is a global, so that -o:speed cannot fold the result of target into main
zero: int

target :: proc(n: int) -> int {
	body_version := VERSION // the debugger steps into target to here
	doubled := n * 2
	return doubled + body_version
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

// main keeps its v1 body through all patches. Its call of target goes to the newest body.
@(optimization_mode="none")
main :: proc() {
	for v in 1 ..= 3 {
		if v > 1 {
			check("patch", patch_to(v), nil)
		} else {
			fmt.println("v1")
		}
		got := target(10 + zero) // the debugger breaks here
		check("target(10)", got, 20 + v)
	}
	fmt.println(failures == 0 ? "ALL OK" : "FAILED")
	os.exit(failures == 0 ? 0 : 1)
}

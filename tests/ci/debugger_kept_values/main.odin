package main

// Under a debugger (debugger.ps1, debugger_gdb.sh, debugger_lldb.sh): values that livepatch keeps
// or moves. At a stop in bump in each version, the debugger must read the values that the code
// uses: a @static of bump, which keeps its value across patches; a global that v2 adds, whose
// storage is in the patch of v2 and which v3 keeps; a @thread_local of the exe; a global of the
// exe. A patch module also has its own copies of these variables, which the code does not use.
// Without a debugger, the test checks the values only.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

total := 100
@(thread_local) tl_value: int

when VERSION >= 2 {
	added_global := 1000
}

// The debugger stops here. It writes a global: at -o:speed, LLVM removes a call to a procedure
// that does nothing. gdb and lldb break on the line in the body, not on the entry. After a patch, a
// call goes through the entry in the exe to the body in the patch, so a breakpoint on the entry
// would stop two times for each call.
stops: int
stop_here :: #force_no_inline proc() {
	stops += VERSION // the debugger breaks here
}

// Returns the number of calls
bump :: proc() -> int {
	@(static) calls: int
	calls += 1
	total += VERSION
	tl_value += VERSION
	when VERSION >= 2 {
		added_global += VERSION
	}
	stop_here() // the debugger reads the values in this frame
	return calls
}

setup :: proc() {
	tl_value = 7
}

checks :: proc(v: int) {
	check("@static calls", bump(), v)
	check("global total", total, 100 + v * (v + 1) / 2)
	check("@thread_local tl_value", tl_value, 7 + v * (v + 1) / 2)
	when VERSION >= 2 {
		// 1000 + 2 + .. + v
		check("global added_global", added_global, 1000 + v * (v + 1) / 2 - 1)
	}
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

// Checks that the code that runs is version v. A patch that does not apply, or a call that the
// optimizer removed, then fails instead of passing with the old code.
version_check :: proc(v: int) {
	check("the running code is version", VERSION, v)
}

// main stays in its v1 body through all patches, so it does no checks itself. At -o:speed,
// LLVM can fold a result of v1 code into it. checks() is a new call after each patch.
@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	setup()
	checks(1)
	version_check(1)
	for v in 2 ..= LAST_VERSION {
		check("patch", patch_to(v), nil)
		checks(v)
		version_check(v)
	}
	fmt.println(failures == 0 ? "ALL OK" : "FAILED")
	os.exit(failures == 0 ? 0 : 1)
}

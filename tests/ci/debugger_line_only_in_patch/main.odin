package main

// Under a debugger (debugger.ps1, debugger_gdb.sh, debugger_lldb.sh): a breakpoint on a source
// line that only the patches have code on, set before the program starts. It must stop in v2, and
// again in v3: after the first patch, the debugger must also learn of the next one. The patch code
// is the last code in this file, so the exe has no code on that line or after it, and a debugger
// cannot move the breakpoint into the exe. Without a debugger, the test checks the values only.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

setup :: proc() {}

checks :: proc(v: int) {
	when VERSION >= 2 {
		check("added(20)", added(20), 40 + v)
	} else {
		// Not empty: at -o:speed, LLVM removes a call to an empty procedure, and the checks of v2 would never run
		check("v1 has no added", v, 1)
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

// Only the patches have this code. Keep it the last code in the file.
when VERSION >= 2 {
	added :: proc(n: int) -> int {
		version_here := VERSION
		doubled := n * 2
		total := doubled + version_here // the debugger breaks here
		return total
	}
}

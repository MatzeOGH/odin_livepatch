package main

// A procedure that only patches have: v2 adds it, v3 changes it, v4 removes it, v5 adds it again.
// A pointer to it that the code stored gets each new body, and keeps the last one while it is removed.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 5

HAS_ADDED :: VERSION == 2 || VERSION == 3 || VERSION == 5

stored: proc() -> int

when HAS_ADDED {
	added :: proc() -> int {
		return VERSION * 10
	}
	call_added :: proc() -> int {
		stored = added
		return added()
	}
} else {
	call_added :: proc() -> int {
		return -1
	}
}

setup :: proc() {}

checks :: proc(v: int) {
	has := v == 2 || v == 3 || v == 5
	check("added proc", call_added(), has ? v * 10 : -1)
	if v >= 2 {
		// v4 removes it: the pointer keeps the body of v3
		check("stored pointer", stored(), v == 4 ? 30 : v * 10)
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

// main stays in its v1 body through all patches, so it does no checks itself. At -o:speed,
// LLVM can fold a result of v1 code into it. checks() is a new call after each patch.
@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	setup()
	checks(1)
	for v in 2 ..= LAST_VERSION {
		check("patch", patch_to(v), nil)
		checks(v)
	}
	os.exit(failures == 0 ? 0 : 1)
}

package main

// A patch that calls a C procedure that no loaded library has is rejected with Unresolved_Symbol.
// The old code keeps running, and the next patch works.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

when VERSION == 3 {
	when ODIN_OS == .Windows {
		foreign import lib "system:kernel32.lib"
	} else {
		foreign import lib "system:c"
	}
	foreign lib {
		lp_missing_c_proc :: proc "c" () -> i32 ---
	}
	value :: proc() -> int {
		return int(lp_missing_c_proc())
	}
} else {
	value :: proc() -> int {
		return VERSION
	}
}

checks :: proc(v: int) {
	check("value", value(), v)
}

@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	checks(1)
	check("patch", patch_to(2), nil)
	checks(2)
	err := patch_to(3)
	unresolved, rejected := err.(lp.Unresolved_Symbol)
	check("rejected: Unresolved_Symbol", rejected, true)
	check("symbol", unresolved.name, "lp_missing_c_proc")
	lp.error_delete(err)
	checks(2)
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

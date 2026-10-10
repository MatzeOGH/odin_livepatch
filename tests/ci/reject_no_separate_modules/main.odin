package main

// A patch built without -use-separate-modules is rejected, because it cannot redirect a procedure.
// The old code keeps running, and the next patch works.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

value :: proc() -> int {
	return VERSION
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
	failed, _ := err.(lp.Build_Failed)
	check("rejected: No_Separate_Modules", failed.kind, lp.Build_Error_Kind.No_Separate_Modules)
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

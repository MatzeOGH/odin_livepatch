package main

// The build script links the exe without its symbols (Windows: no /MAP, Linux: stripped).
// patch() rejects each patch with No_Map, and the old code keeps running.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

value :: proc() -> int {
	return VERSION
}

@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	check("value", value(), 1)
	for v in 2 ..= 3 {
		_, rejected := patch_to(v).(lp.No_Map)
		check("rejected: No_Map", rejected, true)
		check("value: still v1", value(), 1)
	}
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

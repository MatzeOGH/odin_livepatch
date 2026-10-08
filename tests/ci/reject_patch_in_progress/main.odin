package main

// While a patch from patch_start builds, patch() and patch_start() return Patch_In_Progress.
// After patch_poll applies it, the next patch works.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "core:time"

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
	fmt.println("v2")
	os.set_env("VERSION", "2")
	check("patch_start", lp.patch_start(BUILD_SCRIPT), nil)
	_, rejected := lp.patch(BUILD_SCRIPT).(lp.Patch_In_Progress)
	check("patch: Patch_In_Progress", rejected, true)
	_, rejected = lp.patch_start(BUILD_SCRIPT).(lp.Patch_In_Progress)
	check("patch_start: Patch_In_Progress", rejected, true)
	for {
		finished, err := lp.patch_poll()
		if finished {
			check("patch_poll", err, nil)
			break
		}
		time.sleep(time.Millisecond)
	}
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

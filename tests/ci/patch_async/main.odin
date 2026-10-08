package main

// patch_start builds in the background while this thread keeps running. patch_poll applies the patch.

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
	for v in 2 ..= 3 {
		fmt.printfln("v%d", v)
		os.set_env("VERSION", fmt.tprint(v))
		check("patch_start", lp.patch_start(BUILD_SCRIPT), nil)
		polls := 0
		for {
			finished, err := lp.patch_poll()
			if finished {
				check("patch_poll", err, nil)
				break
			}
			polls += 1
			time.sleep(time.Millisecond)
		}
		check("polled during the build", polls > 0, true)
		checks(v)
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

package main

// A patch that adds a global whose value the startup code computes is rejected. The old code
// keeps running, and the next patch works.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

when VERSION == 3 {
	six :: proc "contextless" () -> int {
		return 6
	}
	// File-private: a compiler can reach it through a section symbol instead of its name
	@(private = "file") added := six() * 7
	value :: proc() -> int {
		return VERSION + added - added
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
	_, rejected := patch_to(3).(lp.Global_Needs_Init)
	check("rejected: Global_Needs_Init", rejected, true)
	checks(2)
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

package main

// A patch that adds a @thread_local is rejected. The old code keeps running, and the next patch works.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

when VERSION == 3 {
	@(thread_local) added_tls: int
	value :: proc() -> int {
		added_tls += 1
		return VERSION + added_tls - added_tls
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
	_, rejected := patch_to(3).(lp.Unresolved_Symbol)
	check("rejected: Unresolved_Symbol", rejected, true)
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

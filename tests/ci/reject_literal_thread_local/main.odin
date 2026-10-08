package main

// A proc literal has a @thread_local local. v3 adds a second literal to its procedure, so the
// count changed and the @thread_local would be new: the patch is rejected. The old code keeps
// running, and v4, with one literal again, works.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

when VERSION == 3 {
	make_counter :: proc() -> proc() -> int {
		_ = proc() -> int { return 0 } // new in v3
		return proc() -> int {
			@(thread_local) n: int
			n += 1
			return VERSION * 1000 + n
		}
	}
} else {
	make_counter :: proc() -> proc() -> int {
		return proc() -> int {
			@(thread_local) n: int
			n += 1
			return VERSION * 1000 + n
		}
	}
}

stored: proc() -> int
calls: int

checks :: proc(v: int) {
	calls += 1
	check("stored literal", stored(), v * 1000 + calls)
}

@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	stored = make_counter()
	checks(1)
	check("patch", patch_to(2), nil)
	checks(2)
	err := patch_to(3)
	fmt.println("  error:", err)
	check("rejected", err != nil, true)
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

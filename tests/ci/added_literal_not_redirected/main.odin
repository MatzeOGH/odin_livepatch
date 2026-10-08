package main

// v2 adds a third proc literal to a procedure that has two. Then the count of literals in that
// procedure changed: the pointers that the exe stored keep their old bodies (a limit of livepatch).
// New pointers get the new bodies. v3 has three literals, as v2: its pointers from v2 get the new bodies.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

when VERSION == 1 {
	register :: proc() -> (a, b: proc() -> int) {
		a = proc() -> int { return VERSION * 1000 + 1 }
		b = proc() -> int { return VERSION * 1000 + 2 }
		return
	}
} else {
	register :: proc() -> (a, b: proc() -> int) {
		a = proc() -> int { return VERSION * 1000 + 1 }
		b = proc() -> int { return VERSION * 1000 + 2 }
		_ = proc() -> int { return VERSION * 1000 + 3 } // new in v2
		return
	}
}

exe_a, exe_b: proc() -> int
v2_a, v2_b: proc() -> int

setup :: proc() {
	exe_a, exe_b = register()
}

checks :: proc(v: int) {
	check("pointer of the exe keeps the v1 body", exe_a(), 1001)
	check("second pointer of the exe too", exe_b(), 1002)
	new_a, new_b := register()
	check("new pointer", new_a() + new_b(), 2 * v * 1000 + 3)
	if v == 2 {
		v2_a, v2_b = new_a, new_b
	}
	if v == 3 {
		check("pointer from v2 gets the v3 body", v2_a() + v2_b(), 2 * 3000 + 3)
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

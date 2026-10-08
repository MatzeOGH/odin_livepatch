package main

// Generic instances with a constant parameter ($N: int) and a typeid parameter ($T: typeid).
// main calls them directly: main keeps its v1 body, so each call goes through the redirect of
// the instance in the exe.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

Key :: struct { a, b: int }

// zero is a writable global, so that -o:speed cannot fold the results into main
zero: int

poly_const :: proc($N: int) -> int {
	return N + VERSION * 1000 + zero
}

poly_typeid :: proc($T: typeid) -> int {
	return size_of(T) + VERSION * 1000 + zero
}

@(optimization_mode="none")
main :: proc() {
	for v in 1 ..= 3 {
		if v > 1 {
			check("patch", patch_to(v), nil)
		} else {
			fmt.println("v1")
		}
		check("$N: int instance", poly_const(3), v * 1000 + 3)
		check("$T: typeid instance", poly_typeid(Key), v * 1000 + 16)
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

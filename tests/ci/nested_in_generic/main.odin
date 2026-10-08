package main

// A nested procedure in a generic procedure: its parent is the instance. A stored pointer to it
// gets the new body, and its @static keeps its value. v2 moves the code in the file.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

when VERSION == 1 {
	poly_nested :: proc(x: $T) -> proc() -> int {
		helper :: proc() -> int {
			@(static) n: int
			n += 1
			return VERSION * 1000 + n
		}
		return helper
	}
}

stored: proc() -> int

setup :: proc() {
	stored = poly_nested(1)
}

checks :: proc(v: int) {
	// Two calls in each version: the stored pointer, then a new pointer
	check("stored nested proc of an instance", stored(), v * 1000 + 2 * v - 1)
	check("new pointer to it", poly_nested(1)(), v * 1000 + 2 * v)
}

// From v2 on: the same code, at another place in the file
when VERSION >= 2 {
	poly_nested :: proc(x: $T) -> proc() -> int {
		helper :: proc() -> int {
			@(static) n: int
			n += 1
			return VERSION * 1000 + n
		}
		return helper
	}
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

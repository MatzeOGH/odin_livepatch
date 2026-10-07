package main

// v3 replaces a global with a procedure of the same name. A pointer to the global that the exe
// stored keeps its value: the redirect must not write the old variable.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

// zero is a writable global, so that -o:speed cannot fold the results into constants
zero := 0

when VERSION < 3 {
	switched := 77
	switched_ptr :: proc() -> ^int { return &switched }
	switched_value :: proc() -> int { return switched + zero }
} else {
	switched :: proc() -> int { return 99 }
	switched_storage: int
	switched_ptr :: proc() -> ^int { return &switched_storage }
	switched_value :: proc() -> int { return switched() + zero }
}

stored: ^int

setup :: proc() {
	stored = switched_ptr()
}

checks :: proc(v: int) {
	check("value", switched_value(), v < 3 ? 77 : 99)
	check("old storage, through the stored pointer", stored^, 77)
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

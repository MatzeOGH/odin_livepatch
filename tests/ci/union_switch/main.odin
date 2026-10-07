package main

// A patched procedure that switches on a union.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

Value :: union {
	int,
	string,
	f64,
}

describe :: proc(v: Value) -> string {
	switch x in v {
	case int:
		return fmt.tprintf("v%d int %d", VERSION, x)
	case string:
		return fmt.tprintf("v%d string %s", VERSION, x)
	case f64:
		return fmt.tprintf("v%d f64 %.1f", VERSION, x)
	}
	return "nil"
}

setup :: proc() {}

checks :: proc(v: int) {
	check("int", describe(42), fmt.tprintf("v%d int 42", v))
	check("string", describe("x"), fmt.tprintf("v%d string x", v))
	check("f64", describe(2.5), fmt.tprintf("v%d f64 2.5", v))
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

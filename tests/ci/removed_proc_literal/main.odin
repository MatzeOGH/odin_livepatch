package main

// A procedure has two proc literals, which the exe stored. v3 removes the first: the pointer
// to the first must not go to the body of the second.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

when VERSION < 3 {
	literal_pair :: proc() -> (proc() -> int, proc() -> int) {
		return proc() -> int { return VERSION * 1000 + 1 }, proc() -> int { return VERSION * 1000 + 2 }
	}
} else {
	literal_pair :: proc() -> (proc() -> int, proc() -> int) {
		b := proc() -> int { return VERSION * 1000 + 2 }
		return b, b
	}
}

first, second: proc() -> int

setup :: proc() {
	first, second = literal_pair()
}

checks :: proc(v: int) {
	// v3 has no first literal: both stored pointers keep the bodies of v2
	old := v == 3 ? 2 : v
	check("stored first", first(), old * 1000 + 1)
	check("stored second", second(), old * 1000 + 2)
	new_first, _ := literal_pair()
	check("new first", new_first(), v * 1000 + (v == 3 ? 2 : 1))
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

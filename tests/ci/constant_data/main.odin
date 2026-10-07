package main

// The data of constants, which the compiler names with a counter: constant slices and strings
// that a patch changes, and globals that a patch adds above the globals of the exe. Each must
// point to its own data, not to the data of another global with the same counter.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

Pair :: struct { a, b: int }

when VERSION >= 2 {
	added_slice := []int{7, 8, 9}
	added_ptr := &Pair{7, 8}
}

base_slice := []int{1, 2, 3}
base_ptr := &Pair{1, 2}

when VERSION == 1 {
	const_slice :: proc() -> int {
		s := []int{1, 2, 3}
		return s[0] * 100 + s[1] * 10 + s[2]
	}
	const_strings :: proc() -> string {
		s := []string{"a", "1"}
		return fmt.tprint(s[0], s[1], sep = "")
	}
	added_sum :: proc() -> int { return 0 }
} else {
	const_slice :: proc() -> int {
		s := []int{4, 5, 6}
		return s[0] * 100 + s[1] * 10 + s[2] + (VERSION - 2) * 1000
	}
	const_strings :: proc() -> string {
		s := []string{"b", "2"}
		return fmt.tprint(s[0], s[1], VERSION, sep = "")
	}
	added_sum :: proc() -> int {
		return added_slice[0] * 100 + added_slice[1] * 10 + added_slice[2] + added_ptr.a * 1000
	}
}

base_sum :: proc() -> int {
	return base_slice[0] * 100 + base_slice[1] * 10 + base_slice[2] + base_ptr.a * 1000
}

setup :: proc() {}

checks :: proc(v: int) {
	check("const slice", const_slice(), v == 1 ? 123 : 456 + (v - 2) * 1000)
	check("const strings", const_strings(), v == 1 ? "a1" : fmt.tprintf("b2%d", v))
	check("globals of the exe", base_sum(), 1123)
	check("globals that a patch added", added_sum(), v == 1 ? 0 : 7789)
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

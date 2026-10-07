package main

// Direct calls in patched code reach the newest body: a recursion, a mutual recursion, and a
// call to another patched procedure.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

calls: int

// The base case shows which body ran. count(10) has 89 leaves.
count :: #force_no_inline proc(n: int) -> int {
	calls += 1 // a side effect: else -o:speed reuses an earlier result
	if n < 2 {
		return VERSION
	}
	return count(n - 1) + count(n - 2)
}

count_twice :: #force_no_inline proc(n: int) -> int {
	return count(n) + count(n)
}

is_even :: #force_no_inline proc(n: int) -> int {
	return n == 0 ? VERSION : is_odd(n - 1)
}

is_odd :: #force_no_inline proc(n: int) -> int {
	return n == 0 ? -VERSION : is_even(n - 1)
}

setup :: proc() {}

checks :: proc(v: int) {
	check("recursion", count(10), 89 * v)
	check("call to a patched procedure", count_twice(10), 2 * 89 * v)
	check("mutual recursion", is_even(10), v)
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

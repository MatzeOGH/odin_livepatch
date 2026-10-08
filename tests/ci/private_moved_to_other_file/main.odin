package main

// v3 moves @(private) declarations to extra.odin: a procedure, its @static, a global and a
// @thread_local global keep their stored pointers and values.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

Int_Proc :: proc(x: int) -> int

// In v1 and v2 the declarations are in this file
when VERSION < 3 {
	@(private) private_proc :: proc(x: int) -> int { return VERSION * 1000 + x }
	@(private) private_static :: proc() -> int {
		@(static) n: int
		n += 1
		return VERSION * 1000 + n
	}
	@(private) private_global := 0
	@(private, thread_local) private_tls: int
}

get_private :: proc() -> Int_Proc { return private_proc }

private_global_next :: proc() -> int {
	private_global += 1
	return VERSION * 1000 + private_global
}

private_tls_next :: proc() -> int {
	private_tls += 1
	return VERSION * 1000 + private_tls
}

stored: Int_Proc

setup :: proc() {
	stored = get_private()
}

checks :: proc(v: int) {
	check("@(private) proc, stored", stored(1), v * 1000 + 1)
	check("its @static", private_static(), v * 1000 + v)
	check("@(private) global", private_global_next(), v * 1000 + v)
	check("@(private) @thread_local global", private_tls_next(), v * 1000 + v)
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

// Checks that the code that runs is version v. A patch that does not apply, or a call that the
// optimizer removed, then fails instead of passing with the old code.
version_check :: proc(v: int) {
	check("the running code is version", VERSION, v)
}

// main stays in its v1 body through all patches, so it does no checks itself. At -o:speed,
// LLVM can fold a result of v1 code into it. checks() is a new call after each patch.
@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	setup()
	checks(1)
	version_check(1)
	for v in 2 ..= LAST_VERSION {
		check("patch", patch_to(v), nil)
		checks(v)
		version_check(v)
	}
	os.exit(failures == 0 ? 0 : 1)
}

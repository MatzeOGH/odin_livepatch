package main

// main.odin has a public helper and a public total. extra.odin has a file-private helper and
// total with the same names. The two pairs must not get one key: each keeps its own body and value.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

helper :: proc() -> int {
	return VERSION * 1000 + 1
}

total: int

bump_public :: proc() -> int {
	total += 1
	return total
}

public_ptr, private_ptr: proc() -> int

setup :: proc() {
	public_ptr = helper
	private_ptr = private_helper()
	total = 100
	private_total_set(200)
}

checks :: proc(v: int) {
	check("public helper, stored", public_ptr(), v * 1000 + 1)
	check("file-private helper, stored", private_ptr(), v * 1000 + 2)
	check("public global", bump_public(), 100 + v)
	check("file-private global", bump_private(), 200 + 10 * v)
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

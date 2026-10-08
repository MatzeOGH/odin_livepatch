package main

// Two local types named Local in two block scopes of one procedure, and a generic instance over
// each, which the exe stored. Each stored instance gets its own new body. v2 moves the code in the file.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

inst :: proc(x: $T) -> int {
	return VERSION * 1000 + int(x.q)
}

when VERSION == 1 {
	get_insts :: proc() -> (a, b: rawptr) {
		{
			Local :: struct { q: int }
			f: proc(Local) -> int = inst
			a = rawptr(f)
		}
		{
			Local :: struct { q: int }
			f: proc(Local) -> int = inst
			b = rawptr(f)
		}
		return
	}
}

first, second: proc(x: int) -> int

setup :: proc() {
	// Local is a struct of one int: each instance takes it as an int
	a, b := get_insts()
	first, second = (proc(x: int) -> int)(a), (proc(x: int) -> int)(b)
}

checks :: proc(v: int) {
	check("instance over the first Local", first(1), v * 1000 + 1)
	check("instance over the second Local", second(2), v * 1000 + 2)
}

// From v2 on: the same code, at another place in the file
when VERSION >= 2 {
	get_insts :: proc() -> (a, b: rawptr) {
		{
			Local :: struct { q: int }
			f: proc(Local) -> int = inst
			a = rawptr(f)
		}
		{
			Local :: struct { q: int }
			f: proc(Local) -> int = inst
			b = rawptr(f)
		}
		return
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

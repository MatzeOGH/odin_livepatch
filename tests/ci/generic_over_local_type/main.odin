package main

// A generic instance over a local type, which the exe stored. Each version moves the code in the file.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

inst :: proc(x: $T) -> int {
	return VERSION * 1000 + int(x.q)
}

when VERSION == 1 {
	get_inst :: proc() -> rawptr {
		Local :: struct { q: int }
		f: proc(Local) -> int = inst
		return rawptr(f)
	}
	call_inst :: proc() -> int {
		Local :: struct { q: int }
		return inst(Local{1})
	}
}

stored: proc(x: int) -> int

setup :: proc() {
	// Local is a struct of one int: the instance takes it as an int
	stored = (proc(x: int) -> int)(get_inst())
}

checks :: proc(v: int) {
	check("stored instance", stored(1), v * 1000 + 1)
	check("direct call", call_inst(), v * 1000 + 1)
}

when VERSION == 2 {
	call_inst :: proc() -> int {
		Local :: struct { q: int }
		return inst(Local{1})
	}
	get_inst :: proc() -> rawptr {
		Local :: struct { q: int }
		f: proc(Local) -> int = inst
		return rawptr(f)
	}
}

when VERSION >= 3 {
	get_inst :: proc() -> rawptr {
		Local :: struct { q: int }
		f: proc(Local) -> int = inst
		return rawptr(f)
	}
	call_inst :: proc() -> int {
		Local :: struct { q: int }
		return inst(Local{1})
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

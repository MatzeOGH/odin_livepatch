package main

// Two packages (main and other/) each have a map[int]int, so each object has its own local
// compiler code for the map (__$hasher$$int and others). The exe has two symbols with one key:
// livepatch must not bind either. The maps work in each version.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "other"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

counts: map[int]int

bump :: proc(key: int) -> int {
	counts[key] += VERSION
	return counts[key]
}

setup :: proc() {}

checks :: proc(v: int) {
	// 1 + .. + v
	check("map in main", bump(7), v * (v + 1) / 2)
	check("map in the other package", other.bump(7), 10 * v * (v + 1) / 2)
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

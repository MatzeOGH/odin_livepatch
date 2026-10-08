package main

// An @(rodata) global and an @(static, rodata) local: v2 changes their values, v3 makes them
// writable and writes them. They then start from the v2 values, in their own storage.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

// zero is a writable global, so that -o:speed cannot fold the results into constants
zero := 0

when VERSION == 1 {
	@(rodata) table := [3]int{1, 2, 3}
	read_table :: proc() -> int { return table[0] + zero }
	read_static :: proc() -> int {
		@(static, rodata) pair := [2]int{10, 20}
		return pair[0] + pair[1] + zero
	}
} else when VERSION == 2 {
	@(rodata) table := [3]int{4, 5, 6}
	read_table :: proc() -> int { return table[0] + zero }
	read_static :: proc() -> int {
		@(static, rodata) pair := [2]int{30, 40}
		return pair[0] + pair[1] + zero
	}
} else {
	table := [3]int{4, 5, 6}
	read_table :: proc() -> int {
		table[0] += 100
		return table[0] + zero
	}
	read_static :: proc() -> int {
		@(static) pair := [2]int{30, 40}
		pair[0] += 1
		return pair[0] + pair[1] + zero
	}
}

setup :: proc() {}

checks :: proc(v: int) {
	tables := [?]int{1, 4, 104}
	statics := [?]int{30, 70, 71}
	check("@(rodata) global", read_table(), tables[v - 1])
	check("@(static, rodata) local", read_static(), statics[v - 1])
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

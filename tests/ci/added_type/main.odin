package main

// A type that only patches have: v2 adds it, v3 makes it larger, v4 smaller again. The post
// hook sees only the changes of v3 and v4: a new type is not a change.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 4

thing_changes: int

@(link_section=lp.HOOK_POST_SECTION, export) _post := proc(changed: []lp.Type_Change) {
	for change in changed {
		if change.name == "Thing" {
			thing_changes += 1
		}
	}
}

when VERSION == 1 {
	thing_size :: proc() -> int {
		return 0
	}
} else {
	when VERSION == 3 {
		Thing :: struct { a, b: int }
	} else {
		Thing :: struct { a: int }
	}
	thing_size :: proc() -> int {
		return size_of(Thing) + 0 * len(fmt.tprint(Thing{}))
	}
}

setup :: proc() {}

checks :: proc(v: int) {
	sizes := [?]int{0, 8, 16, 8}
	changes := [?]int{0, 0, 1, 2}
	check("size of Thing", thing_size(), sizes[v - 1])
	check("hook saw Thing change", thing_changes, changes[v - 1])
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

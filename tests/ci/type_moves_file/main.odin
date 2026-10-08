package main

// A type that is the only one with its name changes its layout in v2, and v3 moves it to
// extra.odin and changes it again. The post hook sees both changes.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

when VERSION == 1 {
	Thing :: struct { a: int }
} else when VERSION == 2 {
	Thing :: struct { a, b: int }
}

thing_changes: int

@(link_section=lp.HOOK_POST_SECTION, export) _post := proc(changed: []lp.Type_Change) {
	for change in changed {
		if change.name == "Thing" {
			thing_changes += 1
		}
	}
}

setup :: proc() {}

checks :: proc(v: int) {
	// The type table has only the types whose type info the code uses. The hook sees changes only there.
	check("size of Thing", type_info_of(Thing).size, v * size_of(int))
	check("hook saw Thing change", thing_changes, v - 1)
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

package main

// Two local types named Local in two procedures. v3 changes the second. The post hook must see
// only that one, also when v3 adds a third Local in extra.odin.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

// What the post hook saw of the types named Local. It must not allocate.
local_changes, local_old_size, local_new_size: int

@(link_section=lp.HOOK_POST_SECTION, export) _post := proc(changed: []lp.Type_Change) {
	local_changes = 0
	for change in changed {
		if change.name == "Local" {
			local_changes += 1
			local_old_size, local_new_size = change.old.size, change.new.size
		}
	}
}

size_a :: proc() -> int {
	Local :: struct { x: int }
	return type_info_of(Local).size
}

when VERSION < 3 {
	size_b :: proc() -> int {
		Local :: struct { x, y: f64 }
		return type_info_of(Local).size
	}
} else {
	size_b :: proc() -> int {
		Local :: struct { x, y, z: f64 }
		return type_info_of(Local).size + size_c() - size_c()
	}
}

setup :: proc() {}

checks :: proc(v: int) {
	check("sizes", [2]int{size_a(), size_b()}, v < 3 ? [2]int{8, 16} : [2]int{8, 24})
	check("changes seen by the hook", [3]int{local_changes, local_old_size, local_new_size}, v < 3 ? [3]int{0, 0, 0} : [3]int{1, 16, 24})
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

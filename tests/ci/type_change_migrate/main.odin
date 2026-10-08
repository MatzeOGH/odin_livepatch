package main

// Each patch changes the layout of a struct on the heap. The post hook of the exe sees the
// change and calls migrate, whose new body copies the data into the new layout.

import lp "../../../livepatch"
import "core:fmt"
import "core:mem"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

when VERSION == 1 {
	State :: struct { a: int }
} else when VERSION == 2 {
	State :: struct { a, b: int }
} else {
	State :: struct { a, b, c: int }
}

state: ^State
state_changes: int

@(link_section=lp.HOOK_POST_SECTION, export) _post := proc(changed: []lp.Type_Change) {
	for change in changed {
		if change.name == "State" {
			state_changes += 1
			migrate(change.old.size)
		}
	}
}

// The old layout is a prefix of the new one
migrate :: proc(old_size: int) {
	fresh := new(State)
	mem.copy(fresh, state, old_size)
	when VERSION == 2 { fresh.b = 20 }
	when VERSION == 3 { fresh.c = 30 }
	state = fresh
}

setup :: proc() {
	state = new(State)
	state.a = 5
}

checks :: proc(v: int) {
	// The type table has only the types whose type info the code uses. The hook sees changes only there.
	_ = type_info_of(State)
	check("size of State", size_of(State), v * size_of(int))
	check("hook saw State change", state_changes, v - 1)
	check("a kept", state.a, 5)
	when VERSION >= 2 { check("b", state.b, 20) }
	when VERSION >= 3 { check("c", state.c, 30) }
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

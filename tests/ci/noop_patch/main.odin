package main

// v3 has the same code as v2. The patch works, the statics keep their values, and the hook sees no change.

import "base:runtime"
import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 4

// v3 is the same as v2, v4 is new again
CODE :: 2 when VERSION == 3 else VERSION

when CODE == 1 {
	Thing :: struct { a: int }
} else {
	Thing :: struct { a, b: int }
}

changes: int

@(link_section=lp.HOOK_POST_SECTION, export) _post := proc(changed: []lp.Type_Change) {
	changes += len(changed)
}

count :: proc() -> int {
	@(static) n: int
	n += 1
	return n + CODE * 100 + 0 * size_of(Thing)
}

// The type table has only the types whose type info the code uses. The hook sees changes only there.
thing_info :: proc() -> ^runtime.Type_Info {
	return type_info_of(Thing)
}

setup :: proc() {}

checks :: proc(v: int) {
	code := v == 3 ? 2 : v
	_ = thing_info()
	check("@static kept", count(), v + code * 100)
	check("type changes seen by the hook", changes, v == 1 ? 0 : 1)
}

// The test harness. Each test has its own copy. A test defines LAST_VERSION, setup and checks, or its own main.

failures: int

check :: proc(label: string, got, want: $T) {
	ok := got == want
	if !ok {
		failures += 1
	}
	fmt.printfln("  %-44s %v (want %v) %s", label, got, want, ok ? "OK" : "FAIL")
}

// Builds version v and patches it in. patch() runs build.bat with the environment of this process.
patch_to :: proc(v: int) -> lp.Error {
	fmt.printfln("v%d", v)
	os.set_env("VERSION", fmt.tprint(v))
	return lp.patch("build.bat")
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

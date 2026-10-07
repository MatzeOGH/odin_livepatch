package main

// Stored pointers to procedures with special names or calling conventions get the new body:
// @(export), @(link_name), contextless, and @(private = "file").

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

@(export) exported :: proc "c" () -> i32 { return VERSION * 1000 }
@(link_name = "my_linked") linked :: proc() -> int { return VERSION * 1000 }
contextless_proc :: proc "contextless" () -> int { return VERSION * 1000 }
@(private = "file") file_private :: proc() -> int { return VERSION * 1000 }

exported_ptr: proc "c" () -> i32
linked_ptr: proc() -> int
contextless_ptr: proc "contextless" () -> int
file_private_ptr: proc() -> int

setup :: proc() {
	exported_ptr = exported
	linked_ptr = linked
	contextless_ptr = contextless_proc
	file_private_ptr = file_private
}

checks :: proc(v: int) {
	check("@(export)", int(exported_ptr()), v * 1000)
	check("@(link_name)", linked_ptr(), v * 1000)
	check("contextless", contextless_ptr(), v * 1000)
	check("@(private = \"file\")", file_private_ptr(), v * 1000)
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

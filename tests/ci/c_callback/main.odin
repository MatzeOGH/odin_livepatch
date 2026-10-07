package main

// C's qsort calls back into patched code: through a comparator pointer that the exe stored,
// and through one that new code passes. The new code's address of the comparator is the stored pointer.

import "core:c/libc"
import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

// Ascending in odd versions, descending in even versions
compare :: proc "c" (a, b: rawptr) -> libc.int {
	x, y := (^i32)(a)^, (^i32)(b)^
	d := libc.int(x) - libc.int(y)
	return VERSION % 2 == 1 ? d : -d
}

compare_ptr: proc "c" (a, b: rawptr) -> libc.int

sorted :: proc(by: proc "c" (a, b: rawptr) -> libc.int) -> [4]i32 {
	xs := [4]i32{3, 1, 4, 2}
	libc.qsort(&xs, len(xs), size_of(i32), by)
	return xs
}

setup :: proc() {
	compare_ptr = compare
}

checks :: proc(v: int) {
	want := v % 2 == 1 ? [4]i32{1, 2, 3, 4} : [4]i32{4, 3, 2, 1}
	check("qsort with the stored pointer", sorted(compare_ptr), want)
	check("qsort with the new pointer", sorted(compare), want)
	check("&compare is the stored pointer", compare == compare_ptr, true)
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

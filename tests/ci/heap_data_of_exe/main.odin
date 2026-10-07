package main

// Patched code adds to a map and a dynamic array that the exe made on the heap, and calls C.

import "core:c/libc"
import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "core:strings"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

registry: map[string]int
lines: [dynamic]string

register :: proc(name: string, n: int) {
	registry[strings.clone(name)] = n * VERSION
}

note :: proc(s: string) {
	append(&lines, fmt.aprintf("v%d %s", VERSION, s))
}

c_length :: proc(s: cstring) -> int {
	return int(libc.strlen(s)) + VERSION * 1000
}

setup :: proc() {
	registry["exe"] = 1
	append(&lines, "exe")
}

checks :: proc(v: int) {
	register(fmt.tprintf("v%d", v), 10)
	note("x")
	total := 0
	for _, n in registry {
		total += n
	}
	// 1 + 10 * (1 + .. + v)
	check("map total", total, 1 + 10 * v * (v + 1) / 2)
	check("map entry of the exe", registry["exe"], 1)
	check("dynamic array", lines[len(lines) - 1], fmt.tprintf("v%d x", v))
	check("dynamic array length", len(lines), v + 1)
	check("call to C", c_length("hello"), 5 + v * 1000)
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

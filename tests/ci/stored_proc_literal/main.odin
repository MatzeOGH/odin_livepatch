package main

// Proc literals that the exe stored: one in a procedure and one at file scope. Each version
// moves them in the file. They get the new body and keep their @static.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

when VERSION == 1 {
	make_counter :: proc() -> proc() -> int {
		return proc() -> int {
			@(static) calls: int
			calls += 1
			return VERSION * 1000 + calls
		}
	}
	global_literal := proc() -> int {
		@(static) calls: int
		calls += 1
		return VERSION * 1000 + calls
	}
}

counter: proc() -> int

setup :: proc() {
	counter = make_counter()
}

checks :: proc(v: int) {
	check("literal in a procedure", counter(), v * 1000 + v)
	check("literal at file scope", global_literal(), v * 1000 + v)
}

// Version 2: the same code, at another place in the file
when VERSION == 2 {
	make_counter :: proc() -> proc() -> int {
		return proc() -> int {
			@(static) calls: int
			calls += 1
			return VERSION * 1000 + calls
		}
	}
	global_literal := proc() -> int {
		@(static) calls: int
		calls += 1
		return VERSION * 1000 + calls
	}
}

// Version 3: and at a third place
when VERSION >= 3 {
	global_literal := proc() -> int {
		@(static) calls: int
		calls += 1
		return VERSION * 1000 + calls
	}
	make_counter :: proc() -> proc() -> int {
		return proc() -> int {
			@(static) calls: int
			calls += 1
			return VERSION * 1000 + calls
		}
	}
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

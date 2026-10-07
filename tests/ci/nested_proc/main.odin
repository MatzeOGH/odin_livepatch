package main

// Nested procedures, which the compiler names by their offset in the file. Each version moves
// them. A stored pointer to one gets the new body, and the @static of one keeps its value.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

stored: proc() -> int

setup :: proc() {
	stored = nested_ptr()
}

checks :: proc(v: int) {
	check("stored nested proc", stored(), v * 1000)
	check("@static of a nested proc", nested_counter(), v * 1000 + v)
}

when VERSION == 1 {
	nested_counter :: proc() -> int {
		inner :: proc() -> int {
			@(static) n: int
			n += 1
			return VERSION * 1000 + n
		}
		return inner()
	}
	nested_ptr :: proc() -> proc() -> int {
		inner :: proc() -> int { return VERSION * 1000 }
		return inner
	}
}

// Version 2: the same code, at another place in the file
when VERSION == 2 {
	nested_ptr :: proc() -> proc() -> int {
		inner :: proc() -> int { return VERSION * 1000 }
		return inner
	}
	nested_counter :: proc() -> int {
		inner :: proc() -> int {
			@(static) n: int
			n += 1
			return VERSION * 1000 + n
		}
		return inner()
	}
}

// Version 3: and at a third place
when VERSION >= 3 {
	nested_counter :: proc() -> int {
		inner :: proc() -> int {
			@(static) n: int
			n += 1
			return VERSION * 1000 + n
		}
		return inner()
	}
	nested_ptr :: proc() -> proc() -> int {
		inner :: proc() -> int { return VERSION * 1000 }
		return inner
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

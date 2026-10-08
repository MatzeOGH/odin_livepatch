package main

// @thread_local locals of procedures, nested procedures and proc literals keep their values.
// Each version has its code at another place in the file.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

when VERSION == 1 {
	tls_static_next :: proc() -> int {
		@(thread_local) t: int
		t += 1
		return VERSION * 1000 + t
	}
	tls_nested_next :: proc() -> int {
		inner :: proc() -> int {
			@(thread_local) t: int
			t += 1
			return VERSION * 1000 + t
		}
		return inner()
	}
	tls_literal :: proc() -> proc() -> int {
		return proc() -> int {
			@(thread_local) t: int
			t += 1
			return VERSION * 1000 + t
		}
	}
	tls_deep_next :: proc() -> int {
		inner :: proc() -> int {
			f := proc() -> int {
				@(thread_local) t: int
				t += 1
				return VERSION * 1000 + t
			}
			return f()
		}
		return inner()
	}
}

literal: proc() -> int

setup :: proc() {
	literal = tls_literal()
}

checks :: proc(v: int) {
	check("@thread_local local", tls_static_next(), v * 1000 + v)
	check("... in a nested proc", tls_nested_next(), v * 1000 + v)
	check("... in a stored literal", literal(), v * 1000 + v)
	check("... in a literal in a nested proc", tls_deep_next(), v * 1000 + v)
}

when VERSION == 2 {
	tls_deep_next :: proc() -> int {
		inner :: proc() -> int {
			f := proc() -> int {
				@(thread_local) t: int
				t += 1
				return VERSION * 1000 + t
			}
			return f()
		}
		return inner()
	}
	tls_literal :: proc() -> proc() -> int {
		return proc() -> int {
			@(thread_local) t: int
			t += 1
			return VERSION * 1000 + t
		}
	}
	tls_nested_next :: proc() -> int {
		inner :: proc() -> int {
			@(thread_local) t: int
			t += 1
			return VERSION * 1000 + t
		}
		return inner()
	}
	tls_static_next :: proc() -> int {
		@(thread_local) t: int
		t += 1
		return VERSION * 1000 + t
	}
}

when VERSION >= 3 {
	tls_nested_next :: proc() -> int {
		inner :: proc() -> int {
			@(thread_local) t: int
			t += 1
			return VERSION * 1000 + t
		}
		return inner()
	}
	tls_static_next :: proc() -> int {
		@(thread_local) t: int
		t += 1
		return VERSION * 1000 + t
	}
	tls_deep_next :: proc() -> int {
		inner :: proc() -> int {
			f := proc() -> int {
				@(thread_local) t: int
				t += 1
				return VERSION * 1000 + t
			}
			return f()
		}
		return inner()
	}
	tls_literal :: proc() -> proc() -> int {
		return proc() -> int {
			@(thread_local) t: int
			t += 1
			return VERSION * 1000 + t
		}
	}
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

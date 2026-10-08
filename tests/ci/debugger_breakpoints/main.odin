package main

// Under cdb (debugger.ps1): a breakpoint set before the program starts, on a procedure that only
// one patch has, must stop in the code of that patch, with its locals. After the first patch,
// the debugger must also learn of the second. Without a debugger, the test checks the values only.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

when VERSION == 1 {
	compute :: proc(n: int) -> int {
		return n
	}
} else when VERSION == 2 {
	// debugger.ps1 stops in stop_v2 and reads the locals of body_v2, in the patch module of v2
	stop_v2 :: #force_no_inline proc() {}
	body_v2 :: proc(n: int) -> int {
		doubled := n * 2
		stop_v2()
		result := doubled + 2
		return result
	}
	compute :: proc(n: int) -> int {
		return body_v2(n)
	}
} else {
	// debugger.ps1 stops in stop_v3 and reads the locals of body_v3, in the patch module of v3
	stop_v3 :: #force_no_inline proc() {}
	body_v3 :: proc(n: int) -> int {
		tripled := n * 3
		stop_v3()
		result := tripled + 3
		return result
	}
	compute :: proc(n: int) -> int {
		return body_v3(n)
	}
}

setup :: proc() {}

checks :: proc(v: int) {
	wants := [?]int{20, 42, 63}
	check("compute(20)", compute(20), wants[v - 1])
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
	fmt.println(failures == 0 ? "ALL OK" : "FAILED")
	os.exit(failures == 0 ? 0 : 1)
}

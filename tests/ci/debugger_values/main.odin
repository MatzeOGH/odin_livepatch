package main

// Under cdb (debugger.ps1): three patches, a stop in each, and the values that the debugger must
// read there. v2: a struct local, a global before the update, the call stack back to main in the
// exe. v3: a conditional breakpoint in a loop with its variables, an array, the global as v2 left
// it. v4: a procedure that only v4 has, with a string argument. Each stop is on a procedure that
// only one patch has. Without a debugger, the test checks the values only.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 4

Point :: struct {
	x, y: int,
}

// A package global, which each version reads from the exe
counter := 5

// A frame between checks and the patched code, for the backtrace
drive :: proc() -> int {
	return scene(3)
}

when VERSION == 1 {
	scene :: proc(n: int) -> int {
		return n
	}
} else when VERSION == 2 {
	// debugger.ps1 stops in stop_v2 and reads the locals of scene_v2
	stop_v2 :: #force_no_inline proc() {}
	scene_v2 :: proc(n: int) -> int {
		p := Point{n, n * 2}
		total := p.x + p.y
		stop_v2()
		counter += total
		return total
	}
	scene :: proc(n: int) -> int {
		return scene_v2(n)
	}
} else when VERSION == 3 {
	// debugger.ps1 stops in loop_v3 only when i is 5, and in stop_v3 after the loop
	loop_v3 :: #force_no_inline proc(i: int) {}
	stop_v3 :: #force_no_inline proc() {}
	scene_v3 :: proc(n: int) -> int {
		sum := 0
		for i in 0 ..< 12 {
			sum += i
			loop_v3(i)
		}
		values := [3]int{sum, 1, counter}
		total := values[0] + values[1]
		stop_v3()
		return total
	}
	scene :: proc(n: int) -> int {
		return scene_v3(n)
	}
} else {
	// debugger.ps1 stops in stop_v4 and reads the arguments and locals of added_helper
	stop_v4 :: #force_no_inline proc() {}
	added_helper :: proc(n: int, label: string) -> int {
		doubled := n * len(label)
		stop_v4()
		result := doubled + 1
		return result
	}
	scene :: proc(n: int) -> int {
		return added_helper(n, "four")
	}
}

setup :: proc() {}

checks :: proc(v: int) {
	// v2: 3 + 6, and counter becomes 14. v3: 0 + .. + 11, plus 1. v4: 3 * len("four") + 1.
	wants := [?]int{3, 9, 67, 13}
	check("scene", drive(), wants[v - 1])
	check("counter", counter, v == 1 ? 5 : 14)
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

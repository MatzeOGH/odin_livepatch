package main

// A procedure gets a new body in each of two patches.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

value :: proc() -> int {
	return VERSION
}

failures: int

check :: proc(label: string, got, want: $T) {
	ok := got == want
	if !ok {
		failures += 1
	}
	fmt.printfln("  %-12s %v (want %v) %s", label, got, want, ok ? "OK" : "FAIL")
}

// Calls p in a new frame. At -o:speed, LLVM folds the constant result of a patched procedure
// into main, which runs through the patches. A new call of this procedure runs its new body.
check_call :: proc(label: string, p: proc() -> int, want: int) {
	check(label, p(), want)
}

// At -o:speed, code inlined into main would never see a patch.
@(optimization_mode="none")
main :: proc() {
	check_call("v1 value", value, 1)
	for v in 2 ..= 3 {
		// patch() runs build.bat with the environment of this process
		os.set_env("VERSION", fmt.tprint(v))
		check(fmt.tprintf("v%d patch", v), lp.patch("build.bat"), nil)
		check_call(fmt.tprintf("v%d value", v), value, v)
	}
	os.exit(failures == 0 ? 0 : 1)
}

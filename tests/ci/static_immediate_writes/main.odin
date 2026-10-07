package main

// @static locals that the code writes with immediate operands keep their values.

import "base:intrinsics"
import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

poke :: proc() -> int {
	@(static) wide:  i64
	@(static) count: i64
	@(static) fixed: i32
	@(static) small: i8
	intrinsics.atomic_add(&count, 1) // lock xadd [rip+count]
	fixed = 5                        // mov dword [rip+fixed], imm32
	small = 1                        // mov byte [rip+small], imm8
	wide = 0                         // mov qword [rip+wide], imm32
	return int(count) + int(fixed) + int(small) + int(wide) + VERSION * 100
}

setup :: proc() {}

checks :: proc(v: int) {
	check("statics", poke(), v + 5 + 1 + v * 100)
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

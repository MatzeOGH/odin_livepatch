package main

// A thread calls the patched code in a loop during each patch, and gets the new body.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

// zero is a global, so that -o:speed cannot fold the result of value into the worker loop,
// which runs through the patches
zero: int

value :: proc() -> int {
	return zero + VERSION
}

seen, calls: int

// It runs through the patches. At -o:speed, code inlined into it would never see a patch.
@(optimization_mode="none")
worker :: proc() {
	for {
		sync.atomic_store(&seen, value())
		sync.atomic_add(&calls, 1)
	}
}

setup :: proc() {
	thread.create_and_start(worker)
	time.sleep(20 * time.Millisecond)
}

checks :: proc(v: int) {
	before := sync.atomic_load(&calls)
	time.sleep(20 * time.Millisecond)
	check("worker runs", sync.atomic_load(&calls) > before, true)
	check("worker sees the new body", sync.atomic_load(&seen), v)
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

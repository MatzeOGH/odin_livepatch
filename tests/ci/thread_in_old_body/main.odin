package main

// A thread that is in an old body during a patch finishes that body. Its next call runs the new one.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

entered, release: bool

// Runs until released
long_running :: proc() -> int {
	sync.atomic_store(&entered, true)
	for !sync.atomic_load(&release) {
		time.sleep(time.Millisecond)
	}
	return VERSION
}

inflight: ^thread.Thread
inflight_result: int

setup :: proc() {
	inflight = thread.create_and_start(proc() {
		sync.atomic_store(&inflight_result, long_running())
	})
	for !sync.atomic_load(&entered) {
		time.sleep(time.Millisecond)
	}
}

checks :: proc(v: int) {
	if v == 2 {
		sync.atomic_store(&release, true)
		thread.join(inflight)
		check("the thread finished the v1 body", sync.atomic_load(&inflight_result), 1)
	}
	if v >= 2 {
		check("a new call runs the new body", long_running(), v)
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

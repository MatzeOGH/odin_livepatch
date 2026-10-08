package main

// Linux only. patch() stops the other threads with LIVEPATCH_SIGNAL. A thread that blocks this
// signal, like an audio thread that a C library starts, is not stopped: the patch must still
// finish, and the thread keeps running. The thread does not run patched code.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

value :: proc() -> int {
	return VERSION
}

ticks: int

blocker :: proc() {
	set: posix.sigset_t
	posix.sigemptyset(&set)
	posix.sigaddset(&set, posix.Signal(lp.LIVEPATCH_SIGNAL))
	posix.pthread_sigmask(.BLOCK, &set, nil)
	for {
		sync.atomic_add(&ticks, 1)
		time.sleep(time.Millisecond)
	}
}

setup :: proc() {
	thread.create_and_start(blocker)
	time.sleep(20 * time.Millisecond)
}

checks :: proc(v: int) {
	check("value", value(), v)
	before := sync.atomic_load(&ticks)
	time.sleep(20 * time.Millisecond)
	check("the blocking thread runs", sync.atomic_load(&ticks) > before, true)
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

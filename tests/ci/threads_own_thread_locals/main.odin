package main

// Four threads run the patched code. It reads the @thread_local of the thread that runs it.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 3

WORKERS :: 4

@(thread_local) tl_id: int

work :: proc() -> int {
	return tl_id * 10 + VERSION
}

results: [WORKERS]int

// It runs through the patches. At -o:speed, code inlined into it would never see a patch.
@(optimization_mode="none")
worker :: proc(id: int) {
	tl_id = id + 1
	for {
		sync.atomic_store(&results[id], work())
	}
}

setup :: proc() {
	tl_id = 7
	for id in 0 ..< WORKERS {
		thread.create_and_start_with_poly_data(id, worker)
	}
}

// True when each worker returns its own value of version v
workers_see :: proc(v: int) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 10 * time.Second {
		all := true
		for id in 0 ..< WORKERS {
			if sync.atomic_load(&results[id]) != (id + 1) * 10 + v {
				all = false
			}
		}
		if all {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

checks :: proc(v: int) {
	check("main thread", work(), 70 + v)
	check("each worker sees its own @thread_local", workers_see(v), true)
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

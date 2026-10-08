package main

// 300 procedures (procs.odin, written by gen.py) change in each patch, while a thread calls
// each of them through the pointers that the exe stored. Each must reach its new body, through
// a stored pointer and through a direct call, and the thread must see only whole versions.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

VERSION :: #config(VERSION, 1)
LAST_VERSION :: 4

rounds, bad: int

// Calls each procedure through the table. A call during a commit returns the value of the old
// or of the new version: any other value is wrong.
// It runs through the patches. At -o:speed, code inlined into it would never see a patch.
@(optimization_mode="none")
worker :: proc() {
	for {
		for p, i in table {
			r := p(1) - 1 - i
			if r % 1000 != 0 || r / 1000 < 1 || r / 1000 > LAST_VERSION {
				sync.atomic_add(&bad, 1)
			}
		}
		sync.atomic_add(&rounds, 1)
	}
}

setup :: proc() {
	thread.create_and_start(worker)
	for sync.atomic_load(&rounds) == 0 {
		time.sleep(time.Millisecond)
	}
}

checks :: proc(v: int) {
	wrong, sum := 0, 0
	for p, i in table {
		want := 1 + v * 1000 + i
		sum += want
		if p(1) != want {
			wrong += 1
		}
	}
	check("stored pointers that miss the new body", wrong, 0)
	check("sum of direct calls", sum_direct(), sum)
	before := sync.atomic_load(&rounds)
	start := time.tick_now()
	for sync.atomic_load(&rounds) < before + 2 && time.tick_since(start) < 5 * time.Second {
		time.sleep(time.Millisecond)
	}
	check("worker still calls", sync.atomic_load(&rounds) >= before + 2, true)
	check("worker saw only whole versions", sync.atomic_load(&bad), 0)
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

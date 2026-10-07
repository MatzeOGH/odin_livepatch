package main

// With LIVEPATCH=false (build.bat sets it), the API compiles and does nothing: patch() returns
// nil, the old code keeps running, and the watcher reports no change.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

value :: proc() -> int {
	return VERSION
}

main :: proc() {
	check("LIVEPATCH", lp.LIVEPATCH, false)
	for v in 2 ..= 3 {
		check("patch", patch_to(v), nil)
		check("value: still v1", value(), 1)
	}
	check("patch_start", lp.patch_start("build.bat"), nil)
	finished, err := lp.patch_poll()
	check("patch_poll: nothing", finished || err != nil, false)
	w, werr := lp.watch_start(".")
	check("watch_start", werr, nil)
	changed, cerr := lp.watch_poll(&w)
	check("watch_poll: nothing", changed || cerr != nil, false)
	lp.watch_stop(&w)
	os.exit(failures == 0 ? 0 : 1)
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

package main

// Linux only (the object files on Windows have no symbol sizes). A global stored by value that a
// patch makes larger is rejected with Global_Grew: v3 grows a global of the exe, and v5 grows a
// global that v4 added. The old code keeps running, and the next patches work.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"

VERSION :: #config(VERSION, 1)

when VERSION == 3 {
	grow_me: [8]int // larger than its storage in the exe
} else {
	grow_me: [4]int
}

when VERSION == 4 || VERSION == 6 {
	late: [2]int // added by v4
} else when VERSION == 5 {
	late: [4]int // larger than its storage from v4
}

value :: proc() -> int {
	grow_me[len(grow_me) - 1] = VERSION
	when VERSION >= 4 {
		late[len(late) - 1] = VERSION
	}
	return VERSION
}

checks :: proc(v: int) {
	check("value", value(), v)
}

// Patches to v, which must be rejected with Global_Grew, then checks that version keep still runs
reject :: proc(v, keep: int) {
	err := patch_to(v)
	grew, rejected := err.(lp.Global_Grew)
	check("rejected: Global_Grew", rejected, true)
	fmt.println("  global:", grew.name, grew.old_size, "->", grew.new_size)
	checks(keep)
}

@(optimization_mode="none")
main :: proc() {
	fmt.println("v1")
	checks(1)
	check("patch", patch_to(2), nil)
	checks(2)
	reject(3, 2)
	check("patch", patch_to(4), nil)
	checks(4)
	reject(5, 4)
	check("patch", patch_to(6), nil)
	checks(6)
	os.exit(failures == 0 ? 0 : 1)
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

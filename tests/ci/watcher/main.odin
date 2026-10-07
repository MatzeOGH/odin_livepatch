package main

// The source watcher, without a patch: it reports a changed .odin file, also in a directory
// made after watch_start, and ignores other files.

import lp "../../../livepatch"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

// True when the watcher reports a change in the next 3 seconds
changed_soon :: proc(w: ^lp.Watcher) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 3 * time.Second {
		if changed, _ := lp.watch_poll(w); changed {
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

write :: proc(path, text: string) {
	_ = os.write_entire_file(path, transmute([]u8)text)
}

main :: proc() {
	exe_dir, _ := os.get_executable_directory(context.allocator)
	root, _ := filepath.join({exe_dir, "watched"}, context.allocator)
	sub, _ := filepath.join({root, "sub"}, context.allocator)
	_ = os.remove_all(root)
	_ = os.make_directory(root)
	file, _ := filepath.join({root, "a.odin"}, context.allocator)
	write(file, "package a // 1")

	w, err := lp.watch_start(root)
	check("watch_start", err, nil)
	check("quiet at the start", changed_soon(&w), false)

	for n in 2 ..= 3 {
		write(file, fmt.tprintf("package a // %d", n))
		check(fmt.tprintf("change %d of a .odin file", n), changed_soon(&w), true)
	}

	notes, _ := filepath.join({root, "notes.txt"}, context.allocator)
	write(notes, "x")
	check("a file that is not .odin", changed_soon(&w), false)

	_ = os.make_directory(sub)
	time.sleep(50 * time.Millisecond)
	_ = changed_soon(&w)
	nested, _ := filepath.join({sub, "b.odin"}, context.allocator)
	write(nested, "package b")
	check("a .odin file in a new directory", changed_soon(&w), true)

	lp.watch_stop(&w)
	_ = os.remove_all(root)
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

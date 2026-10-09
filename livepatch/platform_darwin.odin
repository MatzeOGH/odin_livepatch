#+build darwin arm64
package livepatch

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"
@(require) import "core:time"
foreign import libSystem "system:System"

@(default_calling_convention = "c")
foreign libSystem {
	thread_suspend         :: proc(thread: darwin.thread_act_t) -> i32 ---
	thread_resume          :: proc(thread: darwin.thread_act_t) -> i32 ---
	vm_deallocate          :: proc(task: darwin.mach_port_t, address: uintptr, size: uint) -> i32 ---
	sys_icache_invalidate  :: proc(start: rawptr, size: uint) ---
	pthread_mach_thread_np :: proc(thread: posix.pthread_t) -> darwin.thread_act_t ---
}
@(private = "file") found_linker: string

find_linker :: proc() -> (path: string, ok: bool) {
	if found_linker != "" {
		return found_linker, true
	}
	path, ok = find_ld64_lld()
	if ok {
		found_linker = strings.clone(path, runtime.heap_allocator())
	}
	return found_linker, ok
}

find_ld64_lld :: proc() -> (path: string, ok: bool) {
	if strings.contains(LIVEPATCH_LINKER, "/") {
		return LIVEPATCH_LINKER, true
	}
	for candidate in ([]string{"/opt/homebrew/opt/lld/bin/ld64.lld", "/opt/homebrew/opt/llvm/bin/ld64.lld"}) {
		if os.exists(candidate) {
			return candidate, true
		}
	}
	return on_path("ld64.lld")
}

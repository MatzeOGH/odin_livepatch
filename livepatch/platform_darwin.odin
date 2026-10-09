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

ODIN_EXE_NAME :: "odin"
PAGE_SIZE :: uintptr(0x4000)

foreign import libSystem "system:System"

@(default_calling_convention = "c")
foreign libSystem {
	thread_suspend         :: proc(thread: darwin.thread_act_t) -> i32 ---
	thread_resume          :: proc(thread: darwin.thread_act_t) -> i32 ---
	vm_deallocate          :: proc(task: darwin.mach_port_t, address: uintptr, size: uint) -> i32 ---
	sys_icache_invalidate  :: proc(start: rawptr, size: uint) ---
	pthread_mach_thread_np :: proc(thread: posix.pthread_t) -> darwin.thread_act_t ---
}

PROT_RX      :: posix.Prot_Flags{.READ, .EXEC}
PROT_RW      :: posix.Prot_Flags{.READ, .WRITE}
RTLD_DEFAULT :: posix.Symbol_Table(~uintptr(1)) // (void *)-2


exe_view:  Macho_View
exe_slide: uintptr
exe_lo:    uintptr // without __PAGEZERO
exe_hi:    uintptr

exe_probe: u8

exe_base :: proc "contextless" () -> uintptr {
	return exe_lo
}

exe_image_size :: proc "contextless" () -> uintptr {
	return exe_hi - exe_lo
}
mapped_sizes: map[uintptr]int
alloc_error:  os.Error

page_alloc_at :: proc(addr: uintptr, size: int, commit: bool) -> rawptr {
	protection := commit ? PROT_RW : posix.PROT_NONE
	memory := posix.mmap(rawptr(addr), uint(size), protection, {.PRIVATE, .ANONYMOUS})
	if memory == posix.MAP_FAILED {
		alloc_error = errno_error()
		return nil
	}
	if uintptr(memory) != addr {
		posix.munmap(memory, uint(size))
		return nil
	}
	mapped_sizes[addr] = size
	return memory
}

last_alloc_error :: proc() -> os.Error {
	return alloc_error
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

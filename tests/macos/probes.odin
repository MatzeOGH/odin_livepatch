#+build darwin arm64

package macos_probes

import "base:intrinsics"
import "core:log"
import "core:sys/darwin"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

foreign import libSystem "system:System"

@(default_calling_convention = "c")
foreign libSystem {
	thread_suspend         :: proc(thread: darwin.thread_act_t) -> i32 ---
	thread_resume          :: proc(thread: darwin.thread_act_t) -> i32 ---
	sys_icache_invalidate  :: proc(start: rawptr, size: uint) ---
	pthread_mach_thread_np :: proc(thread: posix.pthread_t) -> darwin.thread_act_t ---
	_dyld_get_image_header :: proc(index: u32) -> rawptr ---
	getsectiondata         :: proc(header: rawptr, segment, section: cstring, size: ^uint) -> rawptr ---
}

PAGE_SIZE :: uintptr(0x4000)
B_REACH   :: 128 << 20 // the reach of an arm64 B instruction
MOV_W0_42 :: u32(0x52800540)
RET       :: u32(0xD65F03C0)

probe_target :: #force_no_inline proc "c" () -> i32 {
	return 7
}

code_near_exe :: proc(t: ^testing.T) -> rawptr {
	anchor := uintptr(rawptr(probe_target)) &~ (PAGE_SIZE - 1)
	for step in uintptr(1) ..< 120 {
		hint := anchor + step << 20
		memory := posix.mmap(rawptr(hint), uint(PAGE_SIZE), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
		if memory == posix.MAP_FAILED {
			continue
		}
		if uintptr(memory) != hint {
			posix.munmap(memory, uint(PAGE_SIZE))
			continue
		}
		words := ([^]u32)(memory)
		words[0], words[1] = MOV_W0_42, RET
		if !testing.expect(t, posix.mprotect(memory, uint(PAGE_SIZE), {.READ, .EXEC}) == .OK, "mprotect RX of anonymous memory") {
			return nil
		}
		sys_icache_invalidate(memory, uint(PAGE_SIZE))
		log.infof("code at %p, exe code at %p", memory, rawptr(anchor))
		return memory
	}
	testing.fail_now(t, "no free page within 120 MB above the exe code")
}

@(test)
probe_alloc_near_exe :: proc(t: ^testing.T) {
	code := code_near_exe(t)
	if code == nil {
		return
	}
	defer posix.munmap(code, uint(PAGE_SIZE))
	call := (proc "c" () -> i32)(code)
	testing.expect_value(t, call(), 42)
}

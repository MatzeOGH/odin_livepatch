#+build darwin arm64

package macos_probes

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
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
MOV_W0    :: u32(0x52800000) // mov w0, #imm16 (imm16 << 5)
RET       :: u32(0xD65F03C0)

probe_target :: #force_no_inline proc "c" () -> i32 {
	return 7
}

// The redirect probes call through this pointer, so the compiler cannot see the target
probe_target_pointer := probe_target

// Maps RW memory at the first free 1 MB step above the exe code, or returns nil
map_near_exe :: proc(size: uintptr) -> rawptr {
	anchor := uintptr(rawptr(probe_target)) &~ (PAGE_SIZE - 1)
	for step in uintptr(1) ..< 120 {
		hint := anchor + step << 20
		memory := posix.mmap(rawptr(hint), uint(size), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
		if memory == posix.MAP_FAILED {
			continue
		}
		if uintptr(memory) == hint {
			return memory
		}
		posix.munmap(memory, uint(size))
	}
	return nil
}

code_near_exe :: proc(t: ^testing.T, value: u32) -> rawptr {
	memory := map_near_exe(PAGE_SIZE)
	if memory == nil {
		testing.fail_now(t, "no free page within 120 MB above the exe code")
	}
	words := ([^]u32)(memory)
	words[0], words[1] = MOV_W0 | value << 5, RET
	if !testing.expect(t, posix.mprotect(memory, uint(PAGE_SIZE), {.READ, .EXEC}) == .OK, "mprotect RX of anonymous memory") {
		return nil
	}
	sys_icache_invalidate(memory, uint(PAGE_SIZE))
	log.infof("code at %p, exe code at %p", memory, rawptr(probe_target))
	return memory
}

@(test)
probe_alloc_near_exe :: proc(t: ^testing.T) {
	code := code_near_exe(t, 42)
	if code == nil {
		return
	}
	defer posix.munmap(code, uint(PAGE_SIZE))
	call := (proc "c" () -> i32)(code)
	testing.expect_value(t, call(), 42)
}

@(test)
probe_redirect_text :: proc(t: ^testing.T) {
	redirect_probe_target(t, 42)
}

// The second remap replaces a page that is already an anonymous copy, as patch v3 does after v2
@(test)
probe_redirect_twice :: proc(t: ^testing.T) {
	if redirect_probe_target(t, 43) {
		redirect_probe_target(t, 44)
	}
}

redirect_probe_target :: proc(t: ^testing.T, value: u32) -> bool {
	code := code_near_exe(t, value)
	if code == nil {
		return false
	}
	entry := uintptr(rawptr(probe_target))
	page := entry &~ (PAGE_SIZE - 1)
	offset := int(uintptr(code)) - int(entry)
	if !testing.expect(t, abs(offset) < B_REACH, "the new code is in B reach") {
		return false
	}

	copy_page := posix.mmap(nil, uint(PAGE_SIZE), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if !testing.expect(t, copy_page != posix.MAP_FAILED, "mmap of the copy page") {
		return false
	}
	defer posix.munmap(copy_page, uint(PAGE_SIZE))
	intrinsics.mem_copy_non_overlapping(copy_page, rawptr(page), int(PAGE_SIZE))
	(^u32)(uintptr(copy_page) + entry - page)^ = 0x14000000 | (u32(offset >> 2) & 0x03FFFFFF)
	if !testing.expect(t, posix.mprotect(copy_page, uint(PAGE_SIZE), {.READ, .EXEC}) == .OK, "mprotect RX of the copy page") {
		return false
	}

	target := u64(page)
	current, maximum: i32
	task := darwin.mach_task_self()
	result := darwin.mach_vm_remap(task, &target, u64(PAGE_SIZE), 0, transmute(i32)(darwin.VM_FLAGS_FIXED | {.Overwrite}),
	                               task, u64(uintptr(copy_page)), true, &current, &maximum, .Copy)
	log.infof("mach_vm_remap: %v, protection %x (max %x)", result, current, maximum)
	if !testing.expect_value(t, result, darwin.Kern_Return.Success) || !testing.expect_value(t, target, u64(page)) {
		return false
	}
	sys_icache_invalidate(rawptr(page), uint(PAGE_SIZE))

	// Through a pointer that the compiler cannot see, so the call reads the new page
	target_proc := intrinsics.volatile_load(&probe_target_pointer)
	return testing.expect_value(t, target_proc(), i32(value))
}

spinning:  bool
spin_port: darwin.thread_act_t

spin :: #force_no_inline proc "contextless" () {
	for intrinsics.atomic_load(&spinning) {}
}

@(test)
probe_suspend_pc :: proc(t: ^testing.T) {
	intrinsics.atomic_store(&spinning, true)
	worker := thread.create_and_start(proc() {
		intrinsics.atomic_store(&spin_port, pthread_mach_thread_np(posix.pthread_self()))
		spin()
	})
	defer {
		intrinsics.atomic_store(&spinning, false)
		thread.join(worker)
		thread.destroy(worker)
	}
	for intrinsics.atomic_load(&spin_port) == 0 {
		time.sleep(time.Millisecond)
	}
	time.sleep(20 * time.Millisecond) // the worker is now in spin

	port := intrinsics.atomic_load(&spin_port)
	if !testing.expect_value(t, thread_suspend(port), 0) {
		return
	}
	state: darwin.arm_thread_state64_t
	count := u32(darwin.ARM_THREAD_STATE64_COUNT)
	result := darwin.thread_get_state(port, darwin.ARM_THREAD_STATE64, darwin.thread_state_t(&state), &count)
	testing.expect_value(t, thread_resume(port), 0)
	testing.expect_value(t, result, darwin.Kern_Return.Success)

	entry := u64(uintptr(rawptr(spin)))
	log.infof("pc %x, spin at %x", state.pc, entry)
	testing.expect(t, state.pc >= entry && state.pc < entry + 256, "the pc is in spin")
}
}

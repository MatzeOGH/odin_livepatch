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

@(thread_local)
tl_var: int

tlv_address :: proc() -> rawptr {
	Descriptor :: struct {
		thunk:  proc "c" (descriptor: ^Descriptor) -> rawptr,
		key:    uint,
		offset: uint,
	}
	size: uint
	section := ([^]Descriptor)(getsectiondata(_dyld_get_image_header(0), "__DATA", "__thread_vars", &size))
	for &descriptor in section[:size / size_of(Descriptor)] {
		if address := descriptor.thunk(&descriptor); address == &tl_var {
			return address
		}
	}
	return nil
}

@(test)
probe_tlv :: proc(t: ^testing.T) {
	main_address := tlv_address()
	testing.expect_value(t, main_address, rawptr(&tl_var))

	@(static) worker_ok: bool
	@(static) worker_address: rawptr
	worker := thread.create_and_start(proc() {
		worker_address = tlv_address()
		worker_ok = worker_address == &tl_var
	})
	thread.join(worker)
	thread.destroy(worker)
	log.infof("tl_var: main %p, worker %p", main_address, worker_address)
	testing.expect(t, worker_ok, "the descriptor gives the worker's own tl_var")
	testing.expect(t, worker_address != main_address, "each thread has its own tl_var")
}

// make_exe_writable makes the page of runtime.type_table writable, so a patch can set a new
// type table. The page is in __DATA_CONST, which dyld makes read-only after startup.
@(test)
probe_data_const_writable :: proc(t: ^testing.T) {
	address := uintptr(&runtime.type_table)
	page := address &~ (PAGE_SIZE - 1)
	size: uint
	section := uintptr(getsectiondata(_dyld_get_image_header(0), "__DATA_CONST", "__const", &size))
	log.infof("type_table at %x, __DATA_CONST,__const at %x size %x", address, section, size)
	result := posix.mprotect(rawptr(page), uint(PAGE_SIZE), {.READ, .WRITE})
	if !testing.expectf(t, result == .OK, "mprotect RW of the type_table page: %v", posix.errno()) {
		return
	}
	intrinsics.volatile_store(&runtime.type_table, intrinsics.volatile_load(&runtime.type_table))
}

LC_BUILD_VERSION      :: 0x32
LC_VERSION_MIN_MACOSX :: 0x24
PLATFORM_MACOS        :: 1
MACOS_11              :: u32(11 << 16)

// Finds LC_BUILD_VERSION in a Mach-O header and its load commands. livepatch reads minos from it
// with no fallback, so each Odin exe must have it.
build_version :: proc(t: ^testing.T, data: []u8) -> (minos: u32, ok: bool) {
	if !testing.expect(t, len(data) >= 32 && (^u32)(&data[0])^ == MH_MAGIC_64, "a 64-bit Mach-O header") {
		return
	}
	command_count := (^u32)(&data[16])^
	offset := 32
	for _ in 0 ..< command_count {
		if !testing.expect(t, offset + 16 <= len(data), "the load commands are in the data") {
			return
		}
		switch (^u32)(&data[offset])^ {
		case LC_VERSION_MIN_MACOSX:
			testing.fail_now(t, "the exe has LC_VERSION_MIN_MACOSX")
		case LC_BUILD_VERSION:
			platform := (^u32)(&data[offset + 8])^
			minos = (^u32)(&data[offset + 12])^
			log.infof("LC_BUILD_VERSION: platform %d, minos %d.%d.%d", platform, minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF)
			testing.expect_value(t, platform, u32(PLATFORM_MACOS))
			ok = true
		}
		offset += int((^u32)(&data[offset + 4])^)
	}
	testing.expect(t, ok, "the exe has LC_BUILD_VERSION")
	return
}

// The running test exe, as Odin builds it by default
@(test)
probe_exe_build_version :: proc(t: ^testing.T) {
	header := ([^]u8)(_dyld_get_image_header(0))
	commands_size := (^u32)(&header[20])^
	if minos, ok := build_version(t, header[:32 + commands_size]); ok {
		testing.expect_value(t, minos, MACOS_11)
	}
}

// A minimum below 11.0 is not possible on arm64: the toolchain raises it to 11.0. A higher one is kept.
@(test)
probe_exe_build_version_flag :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/macos_probe_minos_%d", posix.getpid())
	if !testing.expect(t, os.make_directory(dir) == nil, "make the work directory") {
		return
	}
	source := fmt.tprintf("%s/main.odin", dir)
	if !testing.expect(t, os.write_entire_file(source, transmute([]u8)string("package main\nmain :: proc() {}\n")) == nil, "write main.odin") {
		return
	}
	cases := [?]struct{flag: string, minos: u32}{{"10.15", MACOS_11}, {"14.0", 14 << 16}}
	for c in cases {
		exe := fmt.tprintf("%s/main_%s", dir, c.flag)
		// env searches the PATH for odin
		if !run_command(t, {"/usr/bin/env", "odin", "build", dir, fmt.tprintf("-out:%s", exe),
		                    fmt.tprintf("-minimum-os-version:%s", c.flag)}) {
			continue
		}
		data, read_err := os.read_entire_file_from_path(exe, context.temp_allocator)
		if !testing.expect(t, read_err == nil, "read the exe") {
			continue
		}
		if minos, ok := build_version(t, data); ok {
			testing.expectf(t, minos == c.minos, "-minimum-os-version:%s gives minos %x, expected %x", c.flag, minos, c.minos)
		}
	}
}

MODULE_SOURCE :: `
int counter = 41;
const char *name = "probe";
int module_entry(void) { return ++counter + (name[0] == 'p'); }
`

LC_SEGMENT_64          :: 0x19
LC_MAIN                :: 0x80000028
LC_DYLD_CHAINED_FIXUPS :: 0x80000034
MH_MAGIC_64            :: 0xFEEDFACF
MH_EXECUTE             :: 2

Segment_Command_64 :: struct {
	cmd, cmdsize:      u32,
	segname:           [16]u8,
	vmaddr, vmsize:    u64,
	fileoff, filesize: u64,
	maxprot, initprot: u32,
	nsects, flags:     u32,
}

run_command :: proc(t: ^testing.T, command: []string) -> bool {
	state, stdout, stderr, err := os.process_exec({command = command}, context.temp_allocator)
	log.infof("%v -> exit %v %v\n%s%s", command, state.exit_code, err, stdout, stderr)
	return testing.expect(t, err == nil && state.exit_code == 0, "the command succeeds")
}

// Links a module with ld64.lld and loads it. map
// the segments at the link address, copy the file bytes, set the segment protections.
@(test)
probe_macho_module :: proc(t: ^testing.T) {
	linker := "/opt/homebrew/opt/lld/bin/ld64.lld"
	if !testing.expect(t, os.exists(linker), "ld64.lld is installed") {
		return
	}
	dir := fmt.tprintf("/tmp/macos_probe_%d", posix.getpid())
	if !testing.expect(t, os.make_directory(dir) == nil, "make the work directory") {
		return
	}
	source := fmt.tprintf("%s/module.c", dir)
	object := fmt.tprintf("%s/module.o", dir)
	image := fmt.tprintf("%s/module.macho", dir)
	if !testing.expect(t, os.write_entire_file(source, transmute([]u8)string(MODULE_SOURCE)) == nil, "write module.c") {
		return
	}
	if !run_command(t, {"/usr/bin/cc", "-c", "-arch", "arm64", "-O1", "-fno-stack-protector", "-o", object, source}) {
		return
	}

	// The base: free memory near the exe, as livepatch links each patch near it
	MODULE_RESERVE :: 4 << 20
	reserved := map_near_exe(MODULE_RESERVE)
	if !testing.expect(t, reserved != nil, "free memory near the exe") {
		return
	}
	base := uintptr(reserved)
	posix.munmap(reserved, MODULE_RESERVE)
	if !run_command(t, {linker, "-arch", "arm64", "-execute", "-e", "_module_entry",
	                    "-pagezero_size", fmt.tprintf("0x%x", base),
	                    "-platform_version", "macos", "11.0.0", "11.0.0",
	                    "-o", image, object, "-no_fixup_chains"}) {
		return
	}

	data, read_err := os.read_entire_file_from_path(image, context.temp_allocator)
	if !testing.expect(t, read_err == nil && len(data) >= 32, "read the module") {
		return
	}
	testing.expect_value(t, (^u32)(&data[0])^, MH_MAGIC_64)
	testing.expect_value(t, (^u32)(&data[12])^, MH_EXECUTE)
	command_count := (^u32)(&data[16])^

	segments := make([dynamic]^Segment_Command_64, context.temp_allocator)
	entry_offset := ~u64(0)
	lo, hi := max(uintptr), uintptr(0)
	offset := 32
	for _ in 0 ..< command_count {
		if !testing.expect(t, offset + 16 <= len(data), "the load commands are in the file") {
			return
		}
		switch (^u32)(&data[offset])^ {
		case LC_SEGMENT_64:
			segment := (^Segment_Command_64)(&data[offset])
			name := string(cstring(&segment.segname[0]))
			log.infof("%-16s vm %x+%x file %x+%x prot %x", name, segment.vmaddr, segment.vmsize, segment.fileoff, segment.filesize, segment.initprot)
			if segment.initprot != 0 { // not __PAGEZERO
				append(&segments, segment)
				lo = min(lo, mem.align_backward_uintptr(uintptr(segment.vmaddr), PAGE_SIZE))
				hi = max(hi, mem.align_forward_uintptr(uintptr(segment.vmaddr + segment.vmsize), PAGE_SIZE))
			}
		case LC_MAIN:
			entry_offset = (^u64)(&data[offset + 8])^
		case LC_DYLD_CHAINED_FIXUPS:
			testing.fail_now(t, "the linker wrote chained fixups despite -no_fixup_chains")
		}
		offset += int((^u32)(&data[offset + 4])^)
	}
	if !testing.expect_value(t, lo, base) || !testing.expect(t, entry_offset != ~u64(0), "the module has LC_MAIN") {
		return
	}

	memory := posix.mmap(rawptr(lo), uint(hi - lo), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if !testing.expect(t, memory == rawptr(lo), "map the module at its link address") {
		return
	}
	for segment in segments {
		if !testing.expect(t, segment.fileoff + segment.filesize <= u64(len(data)), "the segment is in the file") {
			return
		}
		copy(([^]u8)(uintptr(segment.vmaddr))[:segment.filesize], data[segment.fileoff:][:segment.filesize])
	}
	for segment in segments {
		segment_lo := mem.align_backward_uintptr(uintptr(segment.vmaddr), PAGE_SIZE)
		segment_hi := mem.align_forward_uintptr(uintptr(segment.vmaddr + segment.vmsize), PAGE_SIZE)
		protection := transmute(posix.Prot_Flags)(i32(segment.initprot & 7))
		if .EXEC in protection {
			protection -= {.WRITE} // W^X
		}
		if !testing.expect(t, posix.mprotect(rawptr(segment_lo), uint(segment_hi - segment_lo), protection) == .OK, "mprotect a segment") {
			return
		}
		if .EXEC in protection {
			sys_icache_invalidate(rawptr(segment_lo), uint(segment_hi - segment_lo))
		}
	}

	// LC_MAIN gives the entry as a file offset. __TEXT starts at file offset 0.
	module_entry := (proc "c" () -> i32)(rawptr(base + uintptr(entry_offset)))
	testing.expect_value(t, module_entry(), 43) // 42, + 1 for the name
	testing.expect_value(t, module_entry(), 44) // the data segment is writable
}

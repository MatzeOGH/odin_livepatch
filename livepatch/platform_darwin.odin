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
exe_start: uintptr // without __PAGEZERO
exe_end:   uintptr

exe_probe: u8

exe_base :: proc "contextless" () -> uintptr {
	return exe_start
}

exe_image_size :: proc "contextless" () -> uintptr {
	return exe_end - exe_start
}

load_exe_symbols :: proc(exe_path: string) {
	view, ok := parse_macho(exe_file, context.allocator)
	if !ok || view.header.filetype != MH_EXECUTE || len(view.symbols) == 0 {
		return
	}
	probe_value: uintptr
	found := false
	for symbol in view.symbols {
		if macho_symbol_section(view, symbol) != nil && macho_raw_name(view, symbol) == "_livepatch::exe_probe" {
			probe_value, found = uintptr(symbol.n_value), true
			break
		}
	}
	if !found {
		return
	}
	exe_slide = uintptr(&exe_probe) - probe_value

	link_start, link_end := max(uintptr), uintptr(0)
	for segment in view.segments {
		if is_page_zero(segment) {
			continue
		}
		link_start = min(link_start, uintptr(segment.vmaddr))
		link_end = max(link_end, uintptr(segment.vmaddr + segment.vmsize))
	}
	if link_start >= link_end {
		return
	}
	exe_start = mem.align_backward_uintptr(exe_slide + link_start, PAGE_SIZE)
	exe_end = mem.align_forward_uintptr(exe_slide + link_end, PAGE_SIZE)
	exe_view = view

	sections := make([dynamic]Exe_Section)
	for section in view.sections {
		if section.flags & S_ATTR_DEBUG != 0 {
			continue
		}
		bytes, _ := macho_section_bytes(exe_file, section)
		append(&sections, Exe_Section{
			name        = fixed_name(&section.sectname),
			start       = exe_slide + uintptr(section.addr),
			size        = int(section.size),
			code        = macho_is_code(section),
			variable    = section_holds_variables(section),
			file_offset = int(section.offset),
			file_size   = len(bytes),
		})
	}
	exe_sections = sections[:]

	exe_symbols := read_macho_symbols(view, exe_slide)
	slice.sort(exe_symbols.starts[:])
	exe_map = exe_symbols.symbols
	exe_starts = exe_symbols.starts[:]
}

is_page_zero :: proc(segment: ^Segment_Command_64) -> bool {
	return segment.vmaddr == 0 && segment.filesize == 0 && segment.initprot == 0
}

is_mapped :: proc(segment: ^Segment_Command_64) -> bool {
	return !is_page_zero(segment) && fixed_name(&segment.segname) != "__LINKEDIT"
}

exe_tls_descriptor :: proc(name: string, keys: Static_Keys = nil) -> (address: uintptr, ok: bool) {
	descriptor := uintptr(exe_symbol_address(name, keys) or_return)
	for section in exe_view.sections {
		start := exe_slide + uintptr(section.addr)
		if section.flags & SECTION_TYPE == S_THREAD_LOCAL_VARIABLES && descriptor >= start && descriptor < start + uintptr(section.size) {
			return descriptor, true
		}
	}
	return
}

make_exe_writable :: proc() -> Error {
	if type_table, found := exe_symbol_address("runtime::type_table"); found {
		page_start := mem.align_backward_uintptr(uintptr(type_table), PAGE_SIZE)
		page_end := mem.align_forward_uintptr(uintptr(type_table) + size_of([]rawptr), PAGE_SIZE)
		if posix.mprotect(rawptr(page_start), uint(page_end - page_start), PROT_RW) != .OK {
			return Commit_Failed{os_error = errno_error()}
		}
	}
	page := mem.align_backward_uintptr(uintptr(rawptr(make_exe_writable)), PAGE_SIZE)
	if !replace_code_page(page, nil) {
		return Commit_Failed{os_error = code_error}
	}
	return nil
}

code_error: os.Error

replace_code_page :: proc(page: uintptr, keys: []rawptr) -> bool {
	copy_page := posix.mmap(nil, uint(PAGE_SIZE), PROT_RW, {.PRIVATE, .ANONYMOUS})
	if copy_page == posix.MAP_FAILED {
		code_error = errno_error()
		return false
	}
	defer posix.munmap(copy_page, uint(PAGE_SIZE))
	runtime.mem_copy_non_overlapping(copy_page, rawptr(page), int(PAGE_SIZE))
	for key in keys {
		redirect_site := sites[key]
		(^u32)(rawptr(uintptr(copy_page) + (uintptr(redirect_site.site) - page)))^ = site_word(redirect_site)
	}
	if posix.mprotect(copy_page, uint(PAGE_SIZE), PROT_RX) != .OK {
		code_error = errno_error()
		return false
	}
	target := u64(page)
	current, maximum: i32
	task := darwin.mach_task_self()
	result := darwin.mach_vm_remap(task, &target, u64(PAGE_SIZE), 0, transmute(i32)(darwin.VM_FLAGS_FIXED | {.Overwrite}),
	                               task, u64(uintptr(copy_page)), true, &current, &maximum, .Copy)
	if result != .Success || target != u64(page) {
		code_error = os.Platform_Error(i32(result)) // a kern_return_t, not an errno
		return false
	}
	sys_icache_invalidate(rawptr(page), uint(PAGE_SIZE))
	return true
}

mapped_sizes: map[uintptr]int
alloc_error:  os.Error

page_alloc_at :: proc(address: uintptr, size: int, commit: bool) -> rawptr {
	protection := commit ? PROT_RW : posix.PROT_NONE
	memory := posix.mmap(rawptr(address), uint(size), protection, {.PRIVATE, .ANONYMOUS})
	if memory == posix.MAP_FAILED {
		alloc_error = errno_error()
		return nil
	}
	if uintptr(memory) != address {
		posix.munmap(memory, uint(size))
		return nil
	}
	mapped_sizes[address] = size
	return memory
}

last_alloc_error :: proc() -> os.Error {
	return alloc_error
}

page_free :: proc(memory: rawptr) {
	if size, found := mapped_sizes[uintptr(memory)]; found {
		posix.munmap(memory, uint(size))
		delete_key(&mapped_sizes, uintptr(memory))
	}
}

make_executable :: proc(memory: rawptr, size: int) -> bool {
	if posix.mprotect(memory, uint(size), PROT_RX) != .OK {
		alloc_error = errno_error()
		return false
	}
	sys_icache_invalidate(memory, uint(size))
	return true
}

errno_error :: proc() -> os.Error {
	return os.Platform_Error(posix.errno())
}

MAX_STOPPED :: 1024

stopped: struct {
	threads: [MAX_STOPPED]darwin.thread_act_t,
	count:   int,
}

// The threads are in `stopped`
Suspended_Threads :: struct {}

suspend_others :: proc() -> (handles: Suspended_Threads, ok: bool) {
	task := darwin.mach_task_self()
	self := pthread_mach_thread_np(posix.pthread_self())
	stopped.count = 0
	for {
		list: darwin.thread_list_t
		count: u32
		if darwin.task_threads(task, &list, &count) != .Success {
			return {}, false
		}
		added, fits := false, true
		for thread in list[:count] {
			kept := false
			if thread != self && !slice.contains(stopped.threads[:stopped.count], thread) {
				if stopped.count == MAX_STOPPED {
					fits = false
				} else if thread_suspend(thread) == 0 {
					stopped.threads[stopped.count] = thread
					stopped.count += 1
					kept, added = true, true
				}
			}
			if !kept {
				darwin.mach_port_deallocate(task, u32(thread))
			}
		}
		vm_deallocate(task, uintptr(rawptr(list)), uint(count) * size_of(u32))
		if !fits {
			return {}, false
		}
		if !added {
			return {}, true
		}
	}
}

ip_conflicts :: proc(handles: Suspended_Threads, unwritten: []rawptr) -> bool {
	return false
}

unpaused_threads :: proc() -> int {
	return 0
}

resume_all :: proc(handles: Suspended_Threads) {
	task := darwin.mach_task_self()
	for thread in stopped.threads[:stopped.count] {
		thread_resume(thread)
		darwin.mach_port_deallocate(task, u32(thread))
	}
	stopped.count = 0
}

debugger_attached :: proc() -> bool {
	return false
}

loaded_export :: proc(name: string) -> (address: rawptr, ok: bool) {
	if strings.contains(name, "::") {
		return
	}
	c_name := strings.clone_to_cstring(name, context.temp_allocator)
	address = posix.dlsym(RTLD_DEFAULT, c_name)
	if address == nil && name == "_tlv_bootstrap" {
		return rawptr(tlv_unused), true
	}
	return address, address != nil
}

tlv_unused :: proc "c" () {
	runtime.trap()
}

run_linker :: proc(objects: []Loaded_Object, absolute_object_path, stem: string, base: uintptr) -> Error {
	linker, found := find_linker()
	if !found {
		return Load_Failed{kind = .Cannot_Run_Linker, output = error_text(
			"ld64.lld not found: install it with `brew install lld`, or set LIVEPATCH_LINKER in the build script to its path")}
	}
	out_path := strings.concatenate({stem, ".macho"}, context.temp_allocator)

	list := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&list, "%s\n", absolute_object_path)
	for &object in objects {
		fmt.sbprintf(&list, "%s\n", object.path)
	}
	list_path := strings.concatenate({stem, ".filelist"}, context.temp_allocator)
	if write_err := os.write_entire_file(list_path, transmute([]u8)strings.to_string(list)); write_err != nil {
		return Load_Failed{kind = .Cannot_Write_File, os_error = write_err}
	}

	command := []string{linker, "-arch", "arm64", "-execute",
		"-e", "_" + ENTRY_SYMBOL,
		"-pagezero_size", fmt.tprintf("0x%x", base),
		// Any version works: we load the image ourselves, and newer objects only cause a warning
		"-platform_version", "macos", "11.0.0", "11.0.0",
		"-o", out_path,
		"-filelist", list_path,
		"-no_fixup_chains"}
	return run_linker_command(command)
}

@(private = "file") found_linker: string

find_linker :: proc() -> (path: string, ok: bool) {
	if found_linker != "" {
		return found_linker, true
	}
	path, ok = find_ld64_lld()
	if ok {
		found_linker = strings.clone(path)
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

load_patch_module :: proc(stem: string, base: uintptr, objects: []Loaded_Object) -> (module: Patch_Module, err: Error) {
	path := strings.concatenate({stem, ".macho"}, context.temp_allocator)
	data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return {}, Load_Failed{kind = .Load_Library_Failed, os_error = read_err}
	}
	view, ok := parse_macho(data)
	if !ok {
		return {}, Load_Failed{kind = .Load_Library_Failed}
	}

	start, end := max(uintptr), uintptr(0)
	for segment in view.segments {
		if !is_mapped(segment) {
			continue
		}
		start = min(start, mem.align_backward_uintptr(uintptr(segment.vmaddr), PAGE_SIZE))
		end = max(end, mem.align_forward_uintptr(uintptr(segment.vmaddr + segment.vmsize), PAGE_SIZE))
	}
	if start != base || end <= start {
		return {}, Load_Failed{kind = .Wrong_Load_Base}
	}
	memory := page_alloc_at(start, int(end - start), commit = true)
	if memory == nil {
		return {}, Load_Failed{kind = .Wrong_Load_Base, os_error = last_alloc_error()}
	}
	veneer_block: rawptr
	defer if err != nil {
		page_free(memory)
		page_free(veneer_block) // no-op when nil
	}
	// The module can be out of branch reach of the exe, so its far branches need veneers
	veneers := Module_Veneers{at = make(map[uintptr]uintptr, context.temp_allocator)}
	veneer_size := mem.align_forward_int(far_branch_targets(objects) * MODULE_VENEER_SIZE, int(PAGE_SIZE))
	if veneer_size > 0 {
		veneer_block = page_alloc_at(end, veneer_size, commit = true)
		if veneer_block == nil {
			return {}, Load_Failed{kind = .No_Near_Memory, os_error = last_alloc_error()}
		}
		veneers.next = end
	}
	for segment in view.segments {
		if !is_mapped(segment) || segment.filesize == 0 {
			continue
		}
		if int(segment.fileoff + segment.filesize) > len(data) || segment.filesize > segment.vmsize {
			return {}, Load_Failed{kind = .Load_Library_Failed}
		}
		copy(([^]u8)(rawptr(uintptr(segment.vmaddr)))[:segment.filesize], data[segment.fileoff:][:segment.filesize])
	}
	symbols := read_macho_symbols(view, 0, stable_keys = false, allocator = context.temp_allocator).symbols
	if failed := apply_fixups(objects, symbols, &veneers); failed != "" {
		return {}, Load_Failed{kind = .Load_Library_Failed, output = error_text(
			fmt.tprintf("a reference to %s is out of reach of its instruction", failed))}
	}
	for segment in view.segments {
		if !is_mapped(segment) {
			continue
		}
		segment_start := mem.align_backward_uintptr(uintptr(segment.vmaddr), PAGE_SIZE)
		segment_end := mem.align_forward_uintptr(uintptr(segment.vmaddr + segment.vmsize), PAGE_SIZE)
		#assert(VM_PROT_READ == posix.PROT_READ && VM_PROT_WRITE == posix.PROT_WRITE && VM_PROT_EXECUTE == posix.PROT_EXEC)
		protection := transmute(posix.Prot_Flags)(segment.initprot & (VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE))
		if .EXEC in protection {
			protection -= {.WRITE} // W^X
		}
		if posix.mprotect(rawptr(segment_start), uint(segment_end - segment_start), protection) != .OK {
			return {}, Load_Failed{kind = .Load_Library_Failed, os_error = errno_error()}
		}
		if .EXEC in protection {
			sys_icache_invalidate(rawptr(segment_start), uint(segment_end - segment_start))
		}
	}
	if veneer_block != nil && !make_executable(veneer_block, veneer_size) {
		return {}, Load_Failed{kind = .Load_Library_Failed, os_error = last_alloc_error()}
	}
	return symbols, nil
}

when LIVEPATCH {

	show_toast :: proc(total: time.Duration) {
		when LIVEPATCH_TOAST {
			script := fmt.tprintf("display notification \"Patch applied in %.0f ms\" with title \"livepatch\"", time.duration_milliseconds(total))
			description := os.Process_Desc{command = []string{"osascript", "-e", script}}
			_, _, _, _ = os.process_exec(description, context.temp_allocator)
		}
	}

}

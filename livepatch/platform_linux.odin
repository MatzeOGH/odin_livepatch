#+build linux amd64
package livepatch

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "core:sys/linux"
import "core:sys/posix"

ODIN_EXE_NAME :: "odin"
// The signal that stops the other threads during a commit
LIVEPATCH_SIGNAL :: #config(LIVEPATCH_SIGNAL, 62)

PAGE_SIZE :: uintptr(0x1000)

exe_view:  Elf_View
exe_bias:  uintptr
exe_start: uintptr // the live image
exe_end:   uintptr
exe_tls:   map[string]uintptr // stable key (data_key): offset in the exe's TLS template

exe_probe: u8

@(thread_local) tls_probe: u8

exe_base :: proc "contextless" () -> uintptr {
	return exe_start
}

exe_image_size :: proc "contextless" () -> uintptr {
	return exe_end - exe_start
}

load_exe_symbols :: proc(exe_path: string) {
	view, ok := parse_elf(exe_file)
	if !ok || view.symtab == 0 {
		return
	}
	probe_value: uintptr
	found := false
	for &sym in view.syms {
		_ = elf_symbol_section_index(&view, &sym) or_continue
		if elf_symbol_name(&view, &sym) == "livepatch::exe_probe" {
			probe_value, found = uintptr(sym.value), true
			break
		}
	}
	if !found {
		return
	}
	exe_bias = uintptr(&exe_probe) - probe_value

	link_start, link_end := max(uintptr), uintptr(0)
	for &segment in view.segments {
		if segment.type == PT_LOAD {
			link_start = min(link_start, uintptr(segment.vaddr))
			link_end = max(link_end, uintptr(segment.vaddr + segment.memsz))
		}
	}
	if link_start >= link_end {
		return
	}
	exe_start = mem.align_backward_uintptr(exe_bias + link_start, PAGE_SIZE)
	exe_end = mem.align_forward_uintptr(exe_bias + link_end, PAGE_SIZE)
	exe_view = view

	exe_symbols := read_elf_symbols(&view, exe_bias, context.allocator)
	slice.sort(exe_symbols.starts[:])
	exe_map = exe_symbols.symbols
	exe_starts = exe_symbols.starts[:]
	exe_tls = exe_symbols.tls
	for &sym in view.syms {
		if elf_symbol_type(sym.info) == STT_OBJECT && sym.size > 0 {
			_ = elf_symbol_section_index(&view, &sym) or_continue
			address := exe_bias + uintptr(sym.value)
			variable_sizes[address] = max(variable_sizes[address], int(sym.size))
		}
	}
}

// The end of the exe section that holds `addr`, or `addr` if no section holds it
exe_section_end :: proc(addr: uintptr) -> int {
	if section, found := exe_section_at(addr); found {
		return int(exe_bias + uintptr(section.addr) + uintptr(section.size))
	}
	return int(addr)
}

exe_holds_variable :: proc(addr: uintptr) -> bool {
	section := exe_section_at(addr) or_return
	return section_holds_variables(&exe_view, section)
}

exe_holds_code :: proc(addr: uintptr) -> bool {
	section := exe_section_at(addr) or_return
	return section.flags & SHF_EXECINSTR != 0
}

exe_section_at :: proc(addr: uintptr) -> (section: ^Elf64_Shdr, ok: bool) {
	for &candidate in exe_view.sections {
		start := exe_bias + uintptr(candidate.addr)
		if candidate.flags & SHF_ALLOC != 0 && addr >= start && addr < start + uintptr(candidate.size) {
			return &candidate, true
		}
	}
	return
}

// The live address and size of the first exe section with this name
exe_section_named :: proc(name: string) -> (addr: uintptr, size: int, ok: bool) {
	for &section in exe_view.sections {
		if section.flags & SHF_ALLOC != 0 && elf_section_name(&exe_view, &section) == name {
			return exe_bias + uintptr(section.addr), int(section.size), true
		}
	}
	return
}

exe_file_byte :: proc(addr: uintptr) -> (file_byte: u8, ok: bool) {
	link_addr := addr - exe_bias
	for &segment in exe_view.segments {
		if segment.type == PT_LOAD && link_addr >= uintptr(segment.vaddr) && link_addr < uintptr(segment.vaddr + segment.filesz) {
			file_offset := int(segment.offset) + int(link_addr - uintptr(segment.vaddr))
			if file_offset < len(exe_file) {
				return exe_file[file_offset], true
			}
			return
		}
	}
	return
}

exe_tls_offset :: proc(name: string, keys: Static_Keys = nil) -> (offset: i64, ok: bool) {
	@(static) delta: i64
	@(static) have_delta: bool
	key := data_key(keys, name)
	if key == "" {
		return
	}
	value := exe_tls[key] or_return
	if !have_delta {
		probe_value := exe_tls["livepatch::tls_probe"] or_return
		thread_pointer: uintptr
		ARCH_GET_FS :: 0x1003
		if linux.arch_prctl(ARCH_GET_FS, uint(uintptr(&thread_pointer))) != .NONE {
			return
		}
		delta = i64(uintptr(&tls_probe)) - i64(thread_pointer) - i64(probe_value)
		have_delta = true
	}
	return i64(value) + delta, true
}

make_exe_writable :: proc() -> Error {
	if system_page_size := posix.sysconf(._PAGESIZE); int(system_page_size) != int(PAGE_SIZE) {
		return Commit_Failed{os_error = os.Platform_Error(linux.Errno.EINVAL)} // see "Page size" in the README
	}
	for &segment in exe_view.segments {
		if segment.type == PT_LOAD && segment.flags & PF_X != 0 {
			page_start := mem.align_backward_uintptr(exe_bias + uintptr(segment.vaddr), PAGE_SIZE)
			page_end := mem.align_forward_uintptr(exe_bias + uintptr(segment.vaddr + segment.memsz), PAGE_SIZE)
			if protect_err := linux.mprotect(rawptr(page_start), uint(page_end - page_start), {.READ, .WRITE, .EXEC}); protect_err != .NONE {
				return Commit_Failed{os_error = os.Platform_Error(protect_err)} // see "Hardened kernels" in the README
			}
		}
	}
	if type_table, found := exe_symbol_address("runtime::type_table"); found {
		page_start := mem.align_backward_uintptr(uintptr(type_table), PAGE_SIZE)
		page_end := mem.align_forward_uintptr(uintptr(type_table) + size_of([]rawptr), PAGE_SIZE)
		protection := linux.Mem_Protection{.READ, .WRITE}
		for &segment in exe_view.segments {
			start := exe_bias + uintptr(segment.vaddr)
			if segment.type == PT_LOAD && segment.flags & PF_X != 0 && page_end > start && page_start < start + uintptr(segment.memsz) {
				protection += {.EXEC} // shares a page with code
			}
		}
		if protect_err := linux.mprotect(rawptr(page_start), uint(page_end - page_start), protection); protect_err != .NONE {
			return Commit_Failed{os_error = os.Platform_Error(protect_err)}
		}
	}
	return nil
}

mapped_sizes: map[uintptr]int
alloc_error:  linux.Errno

page_alloc_at :: proc(addr: uintptr, size: int, commit: bool) -> rawptr {
	protection := linux.Mem_Protection{}
	flags := linux.Map_Flags{.PRIVATE, .ANONYMOUS, .FIXED_NOREPLACE}
	if commit {
		protection = {.READ, .WRITE, .EXEC}
	} else {
		flags += {.NORESERVE}
	}
	mem, map_err := linux.mmap(addr, uint(size), protection, flags)
	if map_err != .NONE {
		if map_err != .EEXIST {
			alloc_error = map_err // for example EACCES, when SELinux denies execmem
		}
		return nil
	}
	if uintptr(mem) != addr {
		linux.munmap(mem, uint(size))
		return nil
	}
	mapped_sizes[addr] = size
	return mem
}

last_alloc_error :: proc() -> os.Error {
	if alloc_error == .NONE {
		return nil
	}
	return os.Platform_Error(alloc_error)
}

page_free :: proc(mem: rawptr) {
	if size, found := mapped_sizes[uintptr(mem)]; found {
		linux.munmap(mem, uint(size))
		delete_key(&mapped_sizes, uintptr(mem))
	}
}

commit_at :: proc(start: uintptr, size: int) -> bool {
	for page := mem.align_backward_uintptr(start, PAGE_SIZE); page < start + uintptr(size); page += PAGE_SIZE {
		if page in own_pages {
			continue
		}
		mem, map_err := linux.mmap(page, uint(PAGE_SIZE), {.READ, .WRITE, .EXEC}, {.PRIVATE, .ANONYMOUS, .FIXED_NOREPLACE})
		if map_err != .NONE {
			if map_err != .EEXIST {
				alloc_error = map_err
			}
			return false
		}
		if uintptr(mem) != page {
			linux.munmap(mem, uint(PAGE_SIZE))
			return false
		}
		own_pages[page] = true
	}
	return true
}

own_pages: map[uintptr]bool

// x86-64 keeps the instruction cache coherent with stores
flush_icache :: proc "contextless" (addr: rawptr, size: int) {}

MAX_STOPPED :: 1024

// 1 ms each
STOP_WAIT_ATTEMPTS :: 2000

// uc_flags, uc_link, uc_stack (24 bytes), then gregs, where REG_RIP is 16
UCONTEXT_PC :: 40 + 16 * 8

Stop_Entry :: struct {
	tid:      i32, // 0 once the thread is gone
	acked:    u32, // the stop generation that the thread acknowledged
	pc:       uintptr,
	unpaused: bool, // it blocks the signal, so it keeps running
}

stop: struct {
	entries:   [MAX_STOPPED]Stop_Entry,
	count:     int,
	gen:       u32,           // the current stop
	released:  sync.Futex,    // stopped threads wait until it reaches their generation
	installed: bool,
}

// The stopped threads are in `stop`
Suspended_Threads :: struct {}

stop_handler :: proc "c" (signal: posix.Signal, info: ^posix.siginfo_t, ucontext: rawptr) {
	generation := sync.atomic_load(&stop.gen)
	if i32(u32(sync.atomic_load(&stop.released)) - generation) >= 0 {
		return // late, from a stop that is over
	}
	thread_id := i32(linux.gettid())
	listed := sync.atomic_load(&stop.count)
	found := false
	for i in 0 ..< listed {
		entry := &stop.entries[i]
		if sync.atomic_load(&entry.tid) == thread_id {
			entry.pc = (^uintptr)(uintptr(ucontext) + UCONTEXT_PC)^
			sync.atomic_store(&entry.acked, generation)
			found = true
			break
		}
	}
	if !found {
		return // not listed yet: the signal for this stop follows
	}
	for {
		released := sync.atomic_load(&stop.released)
		if i32(u32(released) - generation) >= 0 {
			return
		}
		sync.futex_wait(&stop.released, u32(released))
	}
}

install_stop_handler :: proc() -> bool {
	if stop.installed {
		return true
	}
	action: posix.sigaction_t
	action.sa_sigaction = stop_handler
	action.sa_flags = {.SIGINFO, .RESTART}
	if posix.sigaction(posix.Signal(LIVEPATCH_SIGNAL), &action, nil) != .OK {
		return false
	}
	stop.installed = true
	return true
}

suspend_others :: proc() -> (handles: Suspended_Threads, ok: bool) {
	install_stop_handler() or_return
	generation := stop.gen + 1
	sync.atomic_store(&stop.count, 0)
	sync.atomic_store(&stop.gen, generation)

	pid := linux.getpid()
	self_tid := i32(linux.gettid())
	for {
		added, fits := signal_new_threads(pid, self_tid, generation)
		if !fits {
			return handles, false
		}
		wait_for_acks(pid, generation) or_return
		if !added {
			return handles, true
		}
	}
}

signal_new_threads :: proc(pid: linux.Pid, self_tid: i32, generation: u32) -> (added, fits: bool) {
	fits = true
	task_dir, open_err := linux.open("/proc/self/task", {.DIRECTORY, .CLOEXEC})
	if open_err != .NONE {
		return false, false
	}
	defer linux.close(task_dir)
	dirent_buffer: [8192]u8
	for {
		bytes_read, getdents_err := linux.getdents(task_dir, dirent_buffer[:])
		if getdents_err != .NONE {
			return added, false
		}
		if bytes_read <= 0 {
			return
		}
		offset := 0
		for dirent in linux.dirent_iterate_buf(dirent_buffer[:bytes_read], &offset) {
			tid_value, is_tid := strconv.parse_i64_of_base(linux.dirent_name(dirent), 10)
			thread_id := i32(tid_value)
			if !is_tid || thread_id == self_tid || is_listed(thread_id) {
				continue
			}
			if stop.count == MAX_STOPPED {
				fits = false
				continue
			}
			entry := &stop.entries[stop.count]
			entry.acked, entry.pc, entry.unpaused = 0, 0, false
			if blocks_stop_signal(thread_id) {
				entry.acked, entry.unpaused = generation, true
				sync.atomic_store(&entry.tid, thread_id)
				sync.atomic_store(&stop.count, stop.count + 1)
				continue
			}
			sync.atomic_store(&entry.tid, thread_id)
			sync.atomic_store(&stop.count, stop.count + 1)
			if kill_err := linux.tgkill(pid, linux.Pid(thread_id), linux.Signal(LIVEPATCH_SIGNAL)); kill_err != .NONE {
				sync.atomic_store(&entry.tid, 0)
				if kill_err != .ESRCH {
					return added, false // the signal cannot be sent (qemu-user cannot send 62)
				}
			}
			added = true
		}
	}
}

wait_for_acks :: proc(pid: linux.Pid, generation: u32) -> bool {
	for _ in 0 ..< STOP_WAIT_ATTEMPTS {
		all_acked := true
		for i in 0 ..< stop.count {
			entry := &stop.entries[i]
			thread_id := sync.atomic_load(&entry.tid)
			if thread_id == 0 || sync.atomic_load(&entry.acked) == generation {
				continue
			}
			if linux.tgkill(pid, linux.Pid(thread_id), linux.Signal(0)) == .ESRCH {
				sync.atomic_store(&entry.tid, 0)
				continue
			}
			all_acked = false
		}
		if all_acked {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

is_listed :: proc(thread_id: i32) -> bool {
	for i in 0 ..< stop.count {
		if stop.entries[i].tid == thread_id {
			return true
		}
	}
	return false
}


blocks_stop_signal :: proc(thread_id: i32) -> bool {
	path: [64]u8
	fmt.bprintf(path[:], "/proc/self/task/%d/status\x00", thread_id)
	status_fd, open_err := linux.open(cstring(raw_data(path[:])), {.CLOEXEC})
	if open_err != .NONE {
		return false
	}
	defer linux.close(status_fd)
	status_buffer: [4096]u8
	bytes_read, _ := linux.read(status_fd, status_buffer[:])
	text := string(status_buffer[:max(bytes_read, 0)])
	sigblk_pos := strings.index(text, "SigBlk:")
	if sigblk_pos < 0 {
		return false
	}
	mask_line, _, _ := strings.partition(text[sigblk_pos + len("SigBlk:"):], "\n")
	blocked_mask, parsed := strconv.parse_u64_of_base(strings.trim_space(mask_line), 16)
	return parsed && blocked_mask & (1 << uint(LIVEPATCH_SIGNAL - 1)) != 0
}

ip_conflicts :: proc(handles: Suspended_Threads, unwritten: []rawptr) -> bool {
	for i in 0 ..< stop.count {
		entry := &stop.entries[i]
		if sync.atomic_load(&entry.tid) != 0 && !entry.unpaused && in_unwritten_site(entry.pc, unwritten) {
			return true
		}
	}
	return false
}

unpaused_threads :: proc() -> (count: int) {
	for i in 0 ..< stop.count {
		if stop.entries[i].unpaused && stop.entries[i].tid != 0 {
			count += 1
		}
	}
	return
}

resume_all :: proc(handles: Suspended_Threads) {
	sync.atomic_store(&stop.released, sync.Futex(stop.gen))
	sync.futex_broadcast(&stop.released)
}

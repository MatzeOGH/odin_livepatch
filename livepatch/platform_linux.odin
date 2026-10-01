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
exe_tls:   map[string]uintptr // canonical name: offset in the exe's TLS template

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
}

// The end of the exe section that holds `addr`, or `addr` if no section holds it
exe_section_end :: proc(addr: uintptr) -> int {
	for &section in exe_view.sections {
		if section.flags & SHF_ALLOC == 0 {
			continue
		}
		start := exe_bias + uintptr(section.addr)
		if addr >= start && addr < start + uintptr(section.size) {
			return int(start + uintptr(section.size))
		}
	}
	return int(addr)
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

exe_tls_offset :: proc(name: string) -> (offset: i64, ok: bool) {
	@(static) delta: i64
	@(static) have_delta: bool
	value := exe_tls[canonical_data_name(name)] or_return
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

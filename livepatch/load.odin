#+build windows amd64
package livepatch

import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:time"

Loaded_Object :: struct {
	path: string,
	data: []byte,
	view: Coff_View,
}

exe_base :: proc "contextless" () -> uintptr {
	return uintptr(win.GetModuleHandleW(nil))
}

// `image` is a loaded module or the bytes of a PE file. The headers are the same in both.
pe_headers :: proc "contextless" (image: rawptr) -> ^win.IMAGE_NT_HEADERS64 {
	dos := (^win.IMAGE_DOS_HEADER)(image)
	return (^win.IMAGE_NT_HEADERS64)(uintptr(image) + uintptr(dos.e_lfanew))
}

pe_sections :: proc "contextless" (image: rawptr) -> []Coff_Section_Header {
	nt := pe_headers(image)
	first := uintptr(nt) + 4 + size_of(win.IMAGE_FILE_HEADER) + uintptr(nt.FileHeader.SizeOfOptionalHeader)
	return ([^]Coff_Section_Header)(rawptr(first))[:nt.FileHeader.NumberOfSections]
}

// The patch DLL and the trampolines stay within NEAR_WINDOW of the exe base, so a rel32 reaches between any two.
NEAR_WINDOW :: uintptr(0x3C00_0000) // 960MB

// Without `commit`, only reserves. nil if the window is full.
alloc_near :: proc(near: uintptr, size: int, commit := true) -> rawptr {
	step :: uintptr(0x0010_0000)
	sz := win.SIZE_T(size)
	kind: win.DWORD = win.MEM_RESERVE
	prot: win.DWORD = win.PAGE_NOACCESS
	if commit {
		kind |= win.MEM_COMMIT
		prot = win.PAGE_EXECUTE_READWRITE
	}
	for off := step; off <= NEAR_WINDOW; off += step {
		if near > off {
			if m := win.VirtualAlloc(rawptr(near - off), sz, kind, prot); m != nil {
				return m
			}
		}
		if off + uintptr(size) <= NEAR_WINDOW {
			if m := win.VirtualAlloc(rawptr(near + off), sz, kind, prot); m != nil {
				return m
			}
		}
	}
	return nil
}

read_all :: proc(dir: string, since: time.Time, allocator := context.temp_allocator) -> (objs: []Loaded_Object, ok: bool) {
	entries, dir_err := os.read_all_directory_by_path(dir, allocator)
	if dir_err != nil {
		return
	}

	loaded := make([dynamic]Loaded_Object, allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".obj") || time.diff(since, entry.modification_time) < 0 {
			continue
		}
		path := entry.fullpath
		data, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return
		}
		view := coff_parse(data) or_return
		if view.n_sections == 0 {
			return
		}
		append(&loaded, Loaded_Object{path, data, view})
	}
	return loaded[:], true
}

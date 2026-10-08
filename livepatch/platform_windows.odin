#+build windows amd64
package livepatch

import pe "core:debug/pe"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
@(require) import "core:time"
import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	FlushInstructionCache :: proc(hProcess: win.HANDLE, lpBaseAddress: rawptr, dwSize: win.SIZE_T) -> win.BOOL ---
	GetThreadId           :: proc(Thread: win.HANDLE) -> win.DWORD ---
	IsDebuggerPresent     :: proc() -> win.BOOL ---
}

foreign import ntdll "system:ntdll.lib"

@(default_calling_convention = "system")
foreign ntdll {
	NtGetNextThread :: proc(process, thread: win.HANDLE, access: win.DWORD, attributes, flags: win.ULONG, next: ^win.HANDLE) -> i32 ---
}

CONTEXT_CONTROL :: 0x0010_0001
STILL_ACTIVE    :: 259 // GetExitCodeThread
ODIN_EXE_NAME :: "odin.exe"

exe_base :: proc "contextless" () -> uintptr {
	return uintptr(win.GetModuleHandleW(nil))
}

// `image` is a loaded module or the bytes of a PE file. The headers are the same in both.
pe_headers :: proc "contextless" (image: rawptr) -> ^win.IMAGE_NT_HEADERS64 {
	dos_header := (^win.IMAGE_DOS_HEADER)(image)
	return (^win.IMAGE_NT_HEADERS64)(uintptr(image) + uintptr(dos_header.e_lfanew))
}

pe_sections :: proc "contextless" (image: rawptr) -> []pe.Section_Header32 {
	nt_headers := pe_headers(image)
	first := uintptr(nt_headers) + 4 + size_of(win.IMAGE_FILE_HEADER) + uintptr(nt_headers.FileHeader.SizeOfOptionalHeader)
	return ([^]pe.Section_Header32)(rawptr(first))[:nt_headers.FileHeader.NumberOfSections]
}

load_exe_sections :: proc() {
	base := exe_base()
	headers := pe_sections(rawptr(base))
	sections := make([]Exe_Section, len(headers))
	for &header, i in headers {
		sections[i] = {
			name        = coff_section_name(&header),
			start       = base + uintptr(header.virtual_address),
			size        = int(header.virtual_size),
			code        = header.characteristics & .MEM_EXECUTE != {},
			variable    = header.characteristics & .MEM_WRITE != {},
			file_offset = int(header.pointer_to_raw_data),
			file_size   = int(header.size_of_raw_data),
		}
	}
	exe_sections = sections
}

exe_image_size :: proc "contextless" () -> uintptr {
	return uintptr(pe_headers(rawptr(exe_base())).OptionalHeader.SizeOfImage)
}

// Makes the exe code and the type_table header writable
make_exe_writable :: proc() -> Error {
	base := exe_base()
	old_protect: win.DWORD
	for &section in pe_sections(rawptr(base)) {
		if section.characteristics & .MEM_EXECUTE != {} {
			if !win.VirtualProtect(rawptr(base + uintptr(section.virtual_address)), win.SIZE_T(section.virtual_size), win.PAGE_EXECUTE_READWRITE, &old_protect) {
				return Commit_Failed{os_error = os.Platform_Error(win.GetLastError())}
			}
		}
	}
	if type_table, found := exe_symbol_address("runtime::type_table"); found {
		if !win.VirtualProtect(type_table, size_of([]rawptr), win.PAGE_READWRITE, &old_protect) {
			return Commit_Failed{os_error = os.Platform_Error(win.GetLastError())}
		}
	}
	return nil
}

page_alloc_at :: proc(addr: uintptr, size: int, commit: bool) -> rawptr {
	alloc_type: win.DWORD = win.MEM_RESERVE
	protect: win.DWORD = win.PAGE_NOACCESS
	if commit {
		alloc_type |= win.MEM_COMMIT
		protect = win.PAGE_EXECUTE_READWRITE
	}
	return win.VirtualAlloc(rawptr(addr), win.SIZE_T(size), alloc_type, protect)
}

// Why the last allocation failed
last_alloc_error :: proc() -> os.Error {
	return os.Platform_Error(win.GetLastError())
}

// Frees a whole allocation from page_alloc_at
page_free :: proc(mem: rawptr) {
	win.VirtualFree(mem, 0, win.MEM_RELEASE)
}

commit_at :: proc(start: uintptr, size: int) -> bool {
	for page := mem.align_backward_uintptr(start, 0x1000); page < start + uintptr(size); page += 0x1000 {
		info: win.MEMORY_BASIC_INFORMATION
		if win.VirtualQuery(rawptr(page), &info, size_of(info)) == 0 {
			return false
		}
		granule := mem.align_backward_uintptr(page, 0x10000)
		switch info.State {
		case win.MEM_COMMIT:
			if page not_in own_pages {
				return false
			}
			continue
		case win.MEM_FREE:
			if win.VirtualAlloc(rawptr(granule), 0x10000, win.MEM_RESERVE, win.PAGE_NOACCESS) == nil {
				return false
			}
			own_granules[granule] = true
		case:
			if granule not_in own_granules {
				return false
			}
		}
		if win.VirtualAlloc(rawptr(page), 0x1000, win.MEM_COMMIT, win.PAGE_EXECUTE_READWRITE) == nil {
			return false
		}
		own_pages[page] = true
	}
	return true
}

own_pages:    map[uintptr]bool
own_granules: map[uintptr]bool // 64KB reservations

flush_icache :: proc "contextless" (addr: rawptr, size: int) {
	FlushInstructionCache(win.GetCurrentProcess(), addr, win.SIZE_T(size))
}

Suspended_Threads :: [dynamic]win.HANDLE

// suspend other threads so we can patch
suspend_others :: proc() -> (handles: Suspended_Threads, ok: bool) {
	ids := make([dynamic]win.DWORD, context.temp_allocator)
	scan_threads(&handles, &ids, grow = true)
	reserve(&handles, 2 * len(handles) + 64)
	reserve(&ids, cap(handles))
	for thread in handles {
		win.SuspendThread(thread)
	}
	for {
		found := scan_threads(&handles, &ids, grow = false) or_return
		if !found {
			return handles, true
		}
	}
}

scan_threads :: proc(handles: ^[dynamic]win.HANDLE, ids: ^[dynamic]win.DWORD, grow: bool) -> (found, fits: bool) {
	ACCESS :: win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_QUERY_LIMITED_INFORMATION

	self_id := win.GetCurrentThreadId()
	fits = true
	current, next: win.HANDLE
	kept := false
	for NtGetNextThread(win.GetCurrentProcess(), current, ACCESS, 0, 0, &next) >= 0 {

		if current != nil && !kept {
			win.CloseHandle(current)
		}
		current, kept = next, false
		thread_id := GetThreadId(current)
		if thread_id == self_id || slice.contains(ids[:], thread_id) {
			continue
		}
		if !grow && len(handles) == cap(handles) {
			fits = false
			continue
		}
		if !grow {
			win.SuspendThread(current)
		}
		append(handles, current)
		append(ids, thread_id)
		kept, found = true, true
	}
	if current != nil && !kept {
		win.CloseHandle(current)
	}
	return
}

ip_conflicts :: proc(handles: Suspended_Threads, unwritten: []rawptr) -> bool {
	for thread in handles {
		thread_context: win.CONTEXT
		thread_context.ContextFlags = CONTEXT_CONTROL
		if !win.GetThreadContext(thread, &thread_context) {
			// A thread that exited stays in the list while a handle to it is open. It runs no code.
			exit_code: win.DWORD
			if win.GetExitCodeThread(thread, &exit_code) && exit_code != STILL_ACTIVE {
				continue
			}
			return true // an unknown RIP can be in a site
		}
		if in_unwritten_site(uintptr(thread_context.Rip), unwritten) {
			return true
		}
	}
	return false
}

unpaused_threads :: proc() -> int {
	return 0
}

resume_all :: proc(handles: Suspended_Threads) {
	#reverse for thread in handles {
		win.ResumeThread(thread)
		win.CloseHandle(thread)
	}
	delete(handles)
}

debugger_attached :: proc() -> bool {
	return bool(IsDebuggerPresent())
}

// An export of any loaded DLL
loaded_export :: proc(name: string) -> (addr: rawptr, ok: bool) {
	if strings.contains(name, "::") {
		return
	}
	modules: [1024]win.HMODULE
	needed: win.DWORD
	if !win.EnumProcessModules(win.GetCurrentProcess(), &modules[0], size_of(modules), &needed) {
		return
	}
	c_name := strings.clone_to_cstring(name, context.temp_allocator)
	for module in modules[:min(int(needed) / size_of(win.HMODULE), len(modules))] {
		if proc_addr := win.GetProcAddress(module, c_name); proc_addr != nil {
			return proc_addr, true
		}
	}
	return
}

// Links `<stem>.dll` for `base` with lld-link, and writes its `<stem>.map`.
// LIVEPATCH_LINKER has no effect on Windows.
run_linker :: proc(objects: []Loaded_Object, absolute_object_path, stem: string, base: uintptr) -> Error {
	linker_path, _ := filepath.join({ODIN_ROOT, "bin", "lld-link.exe"}, context.temp_allocator)
	dll_path := strings.concatenate({stem, ".dll"}, context.temp_allocator)
	map_path := strings.concatenate({stem, ".map"}, context.temp_allocator)

	// A response file, because the object list can exceed the command-line limit.
	response := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&response, "/nologo /dll /noentry /nodefaultlib /machine:x64 /fixed /base:0x%x\n", base)
	// The PDB is only for a debugger. A debugger that attaches later does not see this patch.
	if debugger_attached() {
		fmt.sbprintf(&response, "/debug:full\n")
	}
	fmt.sbprintf(&response, "/opt:noref /opt:noicf\n")
	fmt.sbprintf(&response, "\"/out:%s\"\n\"/map:%s\"\n\"%s\"\n", dll_path, map_path, absolute_object_path)
	for &object in objects {
		fmt.sbprintf(&response, "\"%s\"\n", object.path)
	}
	response_path := strings.concatenate({stem, ".rsp"}, context.temp_allocator)
	if write_err := os.write_entire_file(response_path, transmute([]u8)strings.to_string(response)); write_err != nil {
		return Load_Failed{kind = .Cannot_Write_File, os_error = write_err}
	}

	return run_linker_command({linker_path, strings.concatenate({"@", response_path}, context.temp_allocator)})
}

// Loads `<stem>.dll`, which must land at `base`, and reads its symbols from `<stem>.map`.
load_patch_module :: proc(stem: string, base: uintptr, objects: []Loaded_Object) -> (module: Patch_Module, err: Error) {
	dll_path := strings.concatenate({stem, ".dll"}, context.temp_allocator)
	map_path := strings.concatenate({stem, ".map"}, context.temp_allocator)
	dll := win.LoadLibraryExW(win.utf8_to_wstring(dll_path), nil, {})
	if dll == nil {
		return {}, Load_Failed{kind = .Load_Library_Failed, os_error = os.Platform_Error(win.GetLastError())}
	}
	if uintptr(dll) != base {
		win.FreeLibrary(dll)
		return {}, Load_Failed{kind = .Wrong_Load_Base}
	}
	symbols, _ := read_msvc_map(map_path, base, context.temp_allocator, stable_keys = false)
	return symbols, nil
}

when LIVEPATCH {

	@(private = "file")
	toast: win.NOTIFYICONDATAW

	// Shows a toast
	show_toast :: proc(total: time.Duration) {
		when LIVEPATCH_TOAST {

			notify_message := u32(win.NIM_MODIFY)
			if toast.hWnd == nil {
				user32 := win.LoadLibraryW(win.L("user32.dll"))
				create_window := (proc "system" (win.DWORD, cstring16, cstring16, win.DWORD, i32, i32, i32, i32, win.HWND, win.HMENU, win.HINSTANCE, rawptr) -> win.HWND)(win.GetProcAddress(user32, "CreateWindowExW"))
				load_icon := (proc "system" (win.HINSTANCE, cstring16) -> win.HICON)(win.GetProcAddress(user32, "LoadIconW"))
				if create_window == nil || load_icon == nil {
					return
				}
				toast = {
					cbSize = size_of(toast),
					hWnd   = create_window(0, win.L("STATIC"), nil, 0, 0, 0, 0, 0, win.HWND_MESSAGE, nil, nil, nil),
					uFlags = win.NIF_ICON | win.NIF_TIP | win.NIF_INFO,
					hIcon  = load_icon(nil, cstring16(rawptr(win.IDI_INFORMATION))),
				}
				_ = win.utf8_to_utf16(toast.szTip[:len(toast.szTip) - 1], "livepatch")
				_ = win.utf8_to_utf16(toast.szInfoTitle[:len(toast.szInfoTitle) - 1], "livepatch")
				notify_message = win.NIM_ADD
			}
			toast.szInfo = {}
			_ = win.utf8_to_utf16(toast.szInfo[:len(toast.szInfo) - 1], fmt.tprintf("Patch applied in %.0f ms", time.duration_milliseconds(total)))
			win.Shell_NotifyIconW(notify_message, &toast)
		}
	}

}

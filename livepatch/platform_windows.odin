#+build windows amd64
package livepatch

import "core:fmt"
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
}

foreign import ntdll "system:ntdll.lib"

@(default_calling_convention = "system")
foreign ntdll {
	NtGetNextThread :: proc(process, thread: win.HANDLE, access: win.DWORD, attributes, flags: win.ULONG, next: ^win.HANDLE) -> i32 ---
}

CONTEXT_CONTROL :: 0x0010_0001
ODIN_EXE_NAME :: "odin.exe"

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

exe_image_size :: proc "contextless" () -> uintptr {
	return uintptr(pe_headers(rawptr(exe_base())).OptionalHeader.SizeOfImage)
}

// The end of the exe section that holds `a`, or `a` if no section holds it
exe_section_end :: proc(a: uintptr) -> int {
	base := exe_base()
	for &sh in pe_sections(rawptr(base)) {
		va := base + uintptr(sh.virtual_address)
		if a >= va && a < va + uintptr(sh.virtual_size) {
			return int(va + uintptr(sh.virtual_size))
		}
	}
	return int(a)
}

// The live address and size of the first exe section with this name
exe_section_named :: proc(name: string) -> (addr: uintptr, size: int, ok: bool) {
	base := exe_base()
	for &sh in pe_sections(rawptr(base)) {
		if section_name(&sh) == name {
			return base + uintptr(sh.virtual_address), int(sh.virtual_size), true
		}
	}
	return
}

// A breakpoint is a 0xCC in memory where the file has another byte
exe_file_byte :: proc(a: uintptr) -> (b: u8, ok: bool) {
	if len(exe_file) == 0 {
		return
	}
	rva := a - exe_base()
	for &sh in pe_sections(raw_data(exe_file)) {
		va := uintptr(sh.virtual_address)
		if rva >= va && rva < va + uintptr(sh.virtual_size) {
			off := int(sh.pointer_to_raw_data) + int(rva - va)
			if off < len(exe_file) {
				return exe_file[off], true
			}
			return
		}
	}
	return
}

// Makes the exe code and the type_table header writable
make_exe_writable :: proc() -> Error {
	base := exe_base()
	old: win.DWORD
	for &sh in pe_sections(rawptr(base)) {
		if sh.characteristics & IMAGE_SCN_MEM_EXECUTE != 0 {
			if !win.VirtualProtect(rawptr(base + uintptr(sh.virtual_address)), win.SIZE_T(sh.virtual_size), win.PAGE_EXECUTE_READWRITE, &old) {
				return Commit_Failed{os_error = os.Platform_Error(win.GetLastError())}
			}
		}
	}
	if tt, found := exe_symbol("runtime::type_table"); found {
		if !win.VirtualProtect(tt, size_of([]rawptr), win.PAGE_READWRITE, &old) {
			return Commit_Failed{os_error = os.Platform_Error(win.GetLastError())}
		}
	}
	return nil
}

// Allocates at `addr` exactly, or returns nil. Without `commit`, only reserves
page_alloc_at :: proc(addr: uintptr, size: int, commit: bool) -> rawptr {
	kind: win.DWORD = win.MEM_RESERVE
	prot: win.DWORD = win.PAGE_NOACCESS
	if commit {
		kind |= win.MEM_COMMIT
		prot = win.PAGE_EXECUTE_READWRITE
	}
	return win.VirtualAlloc(rawptr(addr), win.SIZE_T(size), kind, prot)
}

// Why the last allocation failed
last_alloc_error :: proc() -> os.Error {
	return os.Platform_Error(win.GetLastError())
}

// Frees a whole allocation from page_alloc_at
page_free :: proc(p: rawptr) {
	win.VirtualFree(p, 0, win.MEM_RELEASE)
}

// Refuses memory that it did not commit or reserve itself
commit_at :: proc(t: uintptr, n: int) -> bool {
	for page := t & ~uintptr(0xFFF); page < t + uintptr(n); page += 0x1000 {
		info: win.MEMORY_BASIC_INFORMATION
		if win.VirtualQuery(rawptr(page), &info, size_of(info)) == 0 {
			return false
		}
		granule := page & ~uintptr(0xFFFF)
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
	for t in handles {
		win.SuspendThread(t)
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

	me := win.GetCurrentThreadId()
	fits = true
	cur, next: win.HANDLE
	kept := false
	for NtGetNextThread(win.GetCurrentProcess(), cur, ACCESS, 0, 0, &next) >= 0 {

		if cur != nil && !kept {
			win.CloseHandle(cur)
		}
		cur, kept = next, false
		id := GetThreadId(cur)
		if id == me || slice.contains(ids[:], id) {
			continue
		}
		if !grow && len(handles) == cap(handles) {
			fits = false
			continue
		}
		if !grow {
			win.SuspendThread(cur)
		}
		append(handles, cur)
		append(ids, id)
		kept, found = true, true
	}
	if cur != nil && !kept {
		win.CloseHandle(cur)
	}
	return
}

ip_conflicts :: proc(handles: Suspended_Threads, regions: []Range) -> bool {
	for h in handles {
		ctx: win.CONTEXT
		ctx.ContextFlags = CONTEXT_CONTROL
		if !win.GetThreadContext(h, &ctx) {
			continue
		}
		rip := uintptr(ctx.Rip)
		for reg in regions {
			if rip >= reg.lo && rip < reg.hi {
				return true
			}
		}
	}
	return false
}

unpaused_threads :: proc() -> int {
	return 0
}

resume_all :: proc(handles: Suspended_Threads) {
	#reverse for h in handles {
		win.ResumeThread(h)
		win.CloseHandle(h)
	}
	delete(handles)
}

sleep_briefly :: proc() {
	win.Sleep(1)
}

current_process_id :: proc() -> int {
	return int(win.GetCurrentProcessId())
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
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	for m in modules[:min(int(needed) / size_of(win.HMODULE), len(modules))] {
		if p := win.GetProcAddress(m, cname); p != nil {
			return p, true
		}
	}
	return
}

// The command that runs the build script
build_command :: proc(script, outdir: string) -> []string {
	return slice.clone([]string{"cmd", "/c", script, outdir}, context.temp_allocator)
}

// Links `<stem>.dll` for `base` with lld-link, and writes its `<stem>.map`.
run_linker :: proc(objects: []Loaded_Object, abs_path, stem: string, base: uintptr) -> Error {
	lld, _ := filepath.join({ODIN_ROOT, "bin", "lld-link.exe"}, context.temp_allocator)
	dll_path := strings.concatenate({stem, ".dll"}, context.temp_allocator)
	map_path := strings.concatenate({stem, ".map"}, context.temp_allocator)

	// A response file, because the object list can exceed the command-line limit.
	rsp := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&rsp, "/nologo /dll /noentry /nodefaultlib /machine:x64 /fixed /base:0x%x\n", base)
	fmt.sbprintf(&rsp, "/debug:full /opt:noref /opt:noicf /incremental:no\n")
	fmt.sbprintf(&rsp, "\"/out:%s\"\n\"/map:%s\"\n\"%s\"\n", dll_path, map_path, abs_path)
	for &o in objects {
		fmt.sbprintf(&rsp, "\"%s\"\n", o.path)
	}
	rsp_path := strings.concatenate({stem, ".rsp"}, context.temp_allocator)
	if werr := os.write_entire_file(rsp_path, transmute([]u8)strings.to_string(rsp)); werr != nil {
		return Load_Failed{kind = .Cannot_Write_File, os_error = werr}
	}

	desc := os.Process_Desc{command = []string{lld, strings.concatenate({"@", rsp_path}, context.temp_allocator)}}
	state, stdout, stderr, exec_err := os.process_exec(desc, context.temp_allocator)
	if exec_err != nil {
		return Load_Failed{kind = .Cannot_Run_Linker, os_error = exec_err}
	}
	if state.exit_code != 0 {
		return Load_Failed{kind = .Link_Failed, output = error_text(len(stderr) > 0 ? string(stderr) : string(stdout))}
	}
	return nil
}

// Loads `<stem>.dll`, which must land at `base`, and reads its symbols from `<stem>.map`.
load_patch_module :: proc(stem: string, base: uintptr) -> (m: Patch_Module, err: Error) {
	dll_path := strings.concatenate({stem, ".dll"}, context.temp_allocator)
	map_path := strings.concatenate({stem, ".map"}, context.temp_allocator)
	h := win.LoadLibraryExW(win.utf8_to_wstring(dll_path), nil, {})
	if h == nil {
		return {}, Load_Failed{kind = .Load_Library_Failed, os_error = os.Platform_Error(win.GetLastError())}
	}
	if uintptr(h) != base {
		win.FreeLibrary(h)
		return {}, Load_Failed{kind = .Wrong_Load_Base}
	}
	return Patch_Module{base, read_map(map_path, base, context.temp_allocator)}, nil
}

when LIVEPATCH {

	@(private = "file")
	toast: win.NOTIFYICONDATAW

	// Shows a toast
	show_toast :: proc(total: time.Duration) {
		when LIVEPATCH_TOAST {

			op := u32(win.NIM_MODIFY)
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
				op = win.NIM_ADD
			}
			toast.szInfo = {}
			_ = win.utf8_to_utf16(toast.szInfo[:len(toast.szInfo) - 1], fmt.tprintf("Patch applied in %.0f ms", time.duration_milliseconds(total)))
			win.Shell_NotifyIconW(op, &toast)
		}
	}

}

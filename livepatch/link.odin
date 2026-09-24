#+build windows amd64
package livepatch

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import win "core:sys/windows"

PATCH_MODULE_DIRNAME :: "livepatch_mod"

@(private) patch_generation: int

Patch_Dll :: struct {
	base:    uintptr,
	symbols: map[string]uintptr, // canonical link name -> address, from the DLL's map
}

link_and_load :: proc(outdir: string, objects: []Loaded_Object, merged: ^Merged) -> (dll: Patch_Dll, err: Error) {
	exe_dir, exe_err := os.get_executable_directory(context.temp_allocator)
	if exe_err != nil {
		return {}, Load_Failed{kind = .Exe_Path_Unknown}
	}
	moddir, _ := filepath.join({exe_dir, PATCH_MODULE_DIRNAME}, context.temp_allocator)
	if patch_generation == 0 {
		sweep_module_dir(moddir)
	}
	patch_generation += 1
	stem, _ := filepath.join({moddir, fmt.tprintf("lp_%d_g%d", win.GetCurrentProcessId(), patch_generation)}, context.temp_allocator)
	dll_path := strings.concatenate({stem, ".dll"}, context.temp_allocator)
	map_path := strings.concatenate({stem, ".map"}, context.temp_allocator)

	abs_path, _ := filepath.join({outdir, "lp_abs.o"}, context.temp_allocator)
	if werr := os.write_entire_file(abs_path, abs_object(merged)); werr != nil {
		return {}, Load_Failed{kind = .Cannot_Write_File, os_error = werr}
	}

	size := 1 << 20
	for &o in objects {
		for i in 0 ..< o.view.n_sections {
			sh := section_header(o.data, o.view.sec_off, i)
			if !is_discarded_section(sh) {
				size += max(int(sh.virtual_size), int(sh.size_of_raw_data)) + section_align(sh)
			}
		}
	}

	// reserv space near exe
	reserve := alloc_near(exe_base(), size, commit = false)
	if reserve == nil {
		return {}, Load_Failed{kind = .No_Near_Memory}
	}
	base := uintptr(reserve)
	link_err := run_linker(objects, abs_path, dll_path, map_path, base)
	win.VirtualFree(reserve, 0, win.MEM_RELEASE)
	if link_err != nil {
		return {}, link_err
	}

	h := win.LoadLibraryExW(win.utf8_to_wstring(dll_path), nil, {})
	if h == nil {
		return {}, Load_Failed{kind = .Load_Library_Failed, os_error = os.Platform_Error(win.GetLastError())}
	}
	if uintptr(h) != base {
		win.FreeLibrary(h)
		return {}, Load_Failed{kind = .Wrong_Load_Base}
	}
	return Patch_Dll{base, read_map(map_path, base, context.temp_allocator)}, nil
}

// A COFF object with only absolute symbols. A symbol value holds only the low 32 bits of the address
abs_object :: proc(merged: ^Merged) -> []byte {
	n := len(merged.aliases) + len(merged.externals)
	strs := make([dynamic]u8, context.temp_allocator)
	append(&strs, 0, 0, 0, 0) // the size, set below
	syms := make([dynamic]Coff_Symbol, 0, n, context.temp_allocator)
	add :: proc(syms: ^[dynamic]Coff_Symbol, strs: ^[dynamic]u8, name: string, addr: rawptr) {
		s: Coff_Symbol
		(^u32)(&s.name[4])^ = u32(len(strs))
		append(strs, name)
		append(strs, 0)
		s.value = u32(uintptr(addr))
		s.section_number = -1 // IMAGE_SYM_ABSOLUTE
		s.storage_class = IMAGE_SYM_CLASS_EXTERNAL
		append(syms, s)
	}
	for name, alias in merged.aliases {
		add(&syms, &strs, alias, merged.defs[name])
	}
	for name, addr in merged.externals {
		add(&syms, &strs, name, addr)
	}
	(^u32)(raw_data(strs[:]))^ = u32(len(strs))

	out := make([]byte, FILE_HDR_SIZE + n * COFF_SYMBOL_SIZE + len(strs), context.temp_allocator)
	fh := (^Coff_File_Header)(raw_data(out))
	fh.machine = IMAGE_FILE_MACHINE_AMD64
	fh.pointer_to_symbol_table = FILE_HDR_SIZE
	fh.number_of_symbols = u32(n)
	copy(out[FILE_HDR_SIZE:], slice.to_bytes(syms[:]))
	copy(out[FILE_HDR_SIZE + n * COFF_SYMBOL_SIZE:], strs[:])
	return out
}

@(private = "file")
run_linker :: proc(objects: []Loaded_Object, abs_path, dll_path, map_path: string, base: uintptr) -> Error {
	lld, _ := filepath.join({ODIN_ROOT, "bin", "lld-link.exe"}, context.temp_allocator)

	// A response file, because the object list can exceed the command-line limit.
	rsp := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&rsp, "/nologo /dll /noentry /nodefaultlib /machine:x64 /fixed /base:0x%x\n", base)
	fmt.sbprintf(&rsp, "/debug:full /opt:noref /opt:noicf /incremental:no\n")
	fmt.sbprintf(&rsp, "\"/out:%s\"\n\"/map:%s\"\n\"%s\"\n", dll_path, map_path, abs_path)
	for &o in objects {
		fmt.sbprintf(&rsp, "\"%s\"\n", o.path)
	}
	rsp_path := strings.concatenate({strings.trim_suffix(dll_path, ".dll"), ".rsp"}, context.temp_allocator)
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

// delete old artifacts
sweep_module_dir :: proc(moddir: string) {
	os.make_directory(moddir)
	entries, err := os.read_all_directory_by_path(moddir, context.temp_allocator)
	if err != nil {
		return
	}
	for e in entries {
		if strings.has_prefix(e.name, "lp_") {
			os.remove(e.fullpath)
		}
	}
}

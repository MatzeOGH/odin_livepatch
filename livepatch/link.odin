#+build windows amd64, linux amd64
package livepatch

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

PATCH_MODULE_DIRNAME :: "livepatch_mod"

@(private) patch_generation: int

Patch_Module :: struct {
	base:    uintptr,
	symbols: map[string]uintptr, // canonical link name -> address, from the module's symbols
}

link_and_load :: proc(outdir: string, objects: []Loaded_Object, merged: ^Merged) -> (mod: Patch_Module, err: Error) {
	exe_dir, exe_err := os.get_executable_directory(context.temp_allocator)
	if exe_err != nil {
		return {}, Load_Failed{kind = .Exe_Path_Unknown}
	}
	moddir, _ := filepath.join({exe_dir, PATCH_MODULE_DIRNAME}, context.temp_allocator)
	if patch_generation == 0 {
		sweep_module_dir(moddir)
	}
	patch_generation += 1
	stem, _ := filepath.join({moddir, fmt.tprintf("lp_%d_g%d", current_process_id(), patch_generation)}, context.temp_allocator)

	abs_path, _ := filepath.join({outdir, "lp_abs.o"}, context.temp_allocator)
	if werr := os.write_entire_file(abs_path, abs_object(merged)); werr != nil {
		return {}, Load_Failed{kind = .Cannot_Write_File, os_error = werr}
	}

	size := 1 << 20
	for &o in objects {
		size += object_image_size(&o)
	}

	// reserv space near exe
	reserve := alloc_near(exe_base(), size, commit = false)
	if reserve == nil {
		return {}, Load_Failed{kind = .No_Near_Memory}
	}
	base := uintptr(reserve)
	link_err := run_linker(objects, abs_path, stem, base)
	page_free(reserve)
	if link_err != nil {
		return {}, link_err
	}
	return load_patch_module(stem, base)
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

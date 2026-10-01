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

link_and_load :: proc(output_dir: string, objects: []Loaded_Object, merged: ^Merged) -> (mod: Patch_Module, err: Error) {
	exe_dir, exe_err := os.get_executable_directory(context.temp_allocator)
	if exe_err != nil {
		return {}, Load_Failed{kind = .Exe_Path_Unknown}
	}
	module_dir, _ := filepath.join({exe_dir, PATCH_MODULE_DIRNAME}, context.temp_allocator)
	if patch_generation == 0 {
		sweep_module_dir(module_dir)
	}
	patch_generation += 1
	stem, _ := filepath.join({module_dir, fmt.tprintf("lp_%d_g%d", current_process_id(), patch_generation)}, context.temp_allocator)

	absolute_object_path, _ := filepath.join({output_dir, "lp_abs.o"}, context.temp_allocator)
	if write_err := os.write_entire_file(absolute_object_path, absolute_symbols_object(merged)); write_err != nil {
		return {}, Load_Failed{kind = .Cannot_Write_File, os_error = write_err}
	}

	size := 1 << 20
	for &object in objects {
		size += object_max_image_size(&object)
	}

	// reserv space near exe
	reserve := alloc_near(size, commit = false)
	if reserve == nil {
		return {}, Load_Failed{kind = .No_Near_Memory, os_error = last_alloc_error()}
	}
	base := uintptr(reserve)
	link_err := run_linker(objects, absolute_object_path, stem, base)
	page_free(reserve)
	if link_err != nil {
		return {}, link_err
	}
	return load_patch_module(stem, base, objects)
}

// delete old artifacts
sweep_module_dir :: proc(module_dir: string) {
	os.make_directory(module_dir)
	entries, err := os.read_all_directory_by_path(module_dir, context.temp_allocator)
	if err != nil {
		return
	}
	for entry in entries {
		if strings.has_prefix(entry.name, "lp_") {
			os.remove(entry.fullpath)
		}
	}
}

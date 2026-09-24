#+build windows amd64
package livepatch

import "core:os"
import "core:path/filepath"

build_output_dir :: proc(allocator := context.temp_allocator) -> (dir: string, err: Error) {
	exe_dir, exe_err := os.get_executable_directory(allocator)
	if exe_err != nil {
		return "", Build_Failed{kind = .Exe_Path_Unknown}
	}
	joined, join_err := filepath.join({exe_dir, PATCH_OUTPUT_DIRNAME}, allocator)
	if join_err != nil {
		return "", Build_Failed{kind = .Out_Of_Memory}
	}
	if os.exists(joined) {
		return joined, nil
	}
	if make_err := os.make_directory(joined); make_err != nil {
		return "", Build_Failed{kind = .Cannot_Create_Dir, os_error = make_err}
	}
	return joined, nil
}

run_build :: proc(build_script, outdir: string) -> Error {
	script := build_script
	if !filepath.is_abs(script) {
		if exe_dir, exe_err := os.get_executable_directory(context.temp_allocator); exe_err == nil {
			if abs, join_err := filepath.join({exe_dir, script}, context.temp_allocator); join_err == nil {
				script = abs
			}
		}
	}

	// If ODIN is not set, the script uses the compiler that built this exe.
	if _, found := os.lookup_env("ODIN", context.temp_allocator); !found {
		if odin, join_err := filepath.join({ODIN_ROOT, "odin.exe"}, context.temp_allocator); join_err == nil {
			_ = os.set_env("ODIN", odin)
		}
	}

	desc := os.Process_Desc{
		command = []string{"cmd", "/c", script, outdir},
	}
	state, stdout, stderr, exec_err := os.process_exec(desc, context.temp_allocator)
	if exec_err != nil {
		return Build_Failed{kind = .Cannot_Run_Script, os_error = exec_err}
	}
	if state.exit_code != 0 {
		out := len(stdout) > 0 ? string(stdout) : string(stderr)
		return Build_Failed{kind = .Script_Failed, exit_code = state.exit_code, output = error_text(out)}
	}
	return nil
}

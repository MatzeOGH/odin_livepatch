#+build windows amd64, linux amd64
package livepatch

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

build_command :: proc(script, output_dir: string) -> []string {
	command := []string{"cmd", "/c", script, output_dir} when ODIN_OS == .Windows else []string{"/bin/sh", script, output_dir}
	return slice.clone(command, context.temp_allocator)
}

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

run_build :: proc(build_script, output_dir: string) -> Error {
	script := build_script
	if !filepath.is_abs(script) {
		if exe_dir, exe_err := os.get_executable_directory(context.temp_allocator); exe_err == nil {
			if abs, join_err := filepath.join({exe_dir, script}, context.temp_allocator); join_err == nil {
				script = abs
			}
		}
	}

	desc := os.Process_Desc{
		command = build_command(script, output_dir),
		env     = build_env(),
	}
	state, stdout, stderr, exec_err := os.process_exec(desc, context.temp_allocator)
	if exec_err != nil {
		return Build_Failed{kind = .Cannot_Run_Script, os_error = exec_err}
	}
	if state.exit_code != 0 {
		return Build_Failed{kind = .Script_Failed, exit_code = state.exit_code, output = error_text(process_output(stdout, stderr))}
	}
	return nil
}

build_env :: proc() -> []string {
	env, _ := os.environ(context.temp_allocator)
	result := make([dynamic]string, 0, len(env) + 2, context.temp_allocator)
	has_odin := false
	for entry in env {
		key, _, _ := strings.partition(entry, "=")
		if strings.equal_fold(key, "LIVEPATCH_DEBUGGER") {
			continue
		}
		has_odin ||= strings.equal_fold(key, "ODIN")
		append(&result, entry)
	}
	// Without a debugger, the patch does not need debug info, so the script can leave out -debug.
	append(&result, debugger_attached() ? "LIVEPATCH_DEBUGGER=1" : "LIVEPATCH_DEBUGGER=0")
	// If ODIN is not set, the script uses the compiler that built this exe.
	if !has_odin {
		if odin, join_err := filepath.join({ODIN_ROOT, ODIN_EXE_NAME}, context.temp_allocator); join_err == nil {
			append(&result, strings.concatenate({"ODIN=", odin}, context.temp_allocator))
		}
	}
	return result[:]
}

process_output :: proc(stdout, stderr: []u8) -> string {
	if len(stdout) == 0 || len(stderr) == 0 {
		return string(stdout) if len(stderr) == 0 else string(stderr)
	}
	return strings.concatenate({string(stdout), "\n", string(stderr)}, context.temp_allocator)
}

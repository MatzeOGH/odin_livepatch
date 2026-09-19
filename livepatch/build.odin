#+build windows
package livepatch

// Runs the build script and prepares the output directory.
//
// The script must carry the livepatch build flags (`-debug -o:none -use-separate-modules
// /OPT:NOREF /OPT:NOICF`). The driver checks only the results, not the flags.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The build's object directory, under the exe directory. The watcher ignores this name so
// rewriting it does not trigger another patch (watch.odin).
PATCH_OUTPUT_DIRNAME :: "livepatch"

build_output_dir :: proc(allocator := context.temp_allocator) -> (dir: string, err: Error) {
	exe, exe_err := os.get_executable_path(allocator)
	if exe_err != nil {
		return "", Build_Failed{output = "cannot find the running executable path"}
	}
	joined, join_err := filepath.join({os.dir(exe), PATCH_OUTPUT_DIRNAME}, allocator)
	if join_err != nil {
		return "", Build_Failed{output = "out of memory building the output directory path"}
	}
	os.remove_all(joined) // a leftover from a previous patch is fine
	if make_err := os.make_directory(joined); make_err != nil {
		return "", Build_Failed{output = fmt.tprintf("cannot create %s: %v", joined, make_err)}
	}
	return joined, nil
}

run_build :: proc(build_script, outdir: string) -> Error {
	script := build_script
	if !filepath.is_abs(script) {
		// Resolve against the exe directory, not the cwd.
		if exe, exe_err := os.get_executable_path(context.temp_allocator); exe_err == nil {
			if abs, join_err := filepath.join({os.dir(exe), script}, context.temp_allocator); join_err == nil {
				script = abs
			}
		}
	}

	desc := os.Process_Desc{
		command = []string{"cmd", "/c", script, outdir},
	}
	state, stdout, stderr, exec_err := os.process_exec(desc, context.temp_allocator)
	if exec_err != nil {
		return Build_Failed{output = fmt.aprintf("cannot run the build script: %v", exec_err)}
	}
	if state.exit_code != 0 {
		out := len(stdout) > 0 ? string(stdout) : string(stderr)
		return Build_Failed{exit_code = state.exit_code, output = strings.clone(out)}
	}
	return nil
}

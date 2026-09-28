#+build windows amd64, linux amd64
package livepatch

@(require) import "core:os"
@(require) import "core:path/filepath"
@(require) import "core:strings"

when LIVEPATCH {

	watch_root :: proc(source_root: string) -> (root: string, err: Watch_Error) {
		if len(source_root) == 0 {
			return "", Watch_Start_Failed{kind = .Empty_Path}
		}

		path := source_root
		if !filepath.is_abs(path) {
			exe_dir, exe_err := os.get_executable_directory(context.temp_allocator)
			if exe_err != nil {
				return "", Watch_Start_Failed{kind = .Exe_Path_Unknown}
			}
			path, exe_err = filepath.join({exe_dir, path}, context.temp_allocator)
			if exe_err != nil {
				return "", Watch_Start_Failed{kind = .Out_Of_Memory}
			}
		}

		stored_root, clone_err := strings.clone(path, context.allocator)
		if clone_err != nil {
			return "", Watch_Start_Failed{kind = .Out_Of_Memory}
		}
		return stored_root, nil
	}

	// ignore anything but .odin files
	watch_change_affects_sources :: proc(name: string) -> bool {
		return len(name) >= 5 && strings.equal_fold(name[len(name) - 5:], ".odin")
	}

}

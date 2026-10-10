#+build windows amd64, linux amd64
package livepatch

@(require) import "base:runtime"
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

		stored_root, clone_err := strings.clone(path)
		if clone_err != nil {
			return "", Watch_Start_Failed{kind = .Out_Of_Memory}
		}
		return stored_root, nil
	}

	watch_clone_extensions :: proc(extensions: []string) -> []string {
		cloned := make([]string, len(extensions))
		for extension, i in extensions {
			cloned[i] = strings.clone(extension)
		}
		return cloned
	}

	watch_delete_extensions :: proc(extensions: []string, allocator: runtime.Allocator) {
		for extension in extensions {
			delete(extension, allocator)
		}
		delete(extensions, allocator)
	}

	watch_change_affects_sources :: proc(name: string, extensions: []string) -> bool {
		ext := filepath.ext(name)
		if strings.equal_fold(ext, ".odin") {
			return true
		}
		for extension in extensions {
			if strings.equal_fold(ext, extension) {
				return true
			}
		}
		return false
	}

}

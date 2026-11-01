#+build windows amd64, linux amd64, darwin arm64
package livepatch

@(require) import "base:runtime"
@(require) import "core:os"
@(require) import "core:path/filepath"
@(require) import "core:strings"
@(require) import "core:time"

when LIVEPATCH {

	Watcher :: struct {
		platform:      Watch_Platform,
		extensions:    []string,
		allocator:     runtime.Allocator, // of the extensions and of the strings of the platform part
		pending:       bool,
		pending_since: time.Tick,
		active:        bool,
	}

	watch_start :: proc(source_root: string, extensions: []string = nil) -> (watcher: Watcher, err: Watch_Error) {
		root := watch_root(source_root) or_return
		watcher = Watcher{
			extensions = watch_clone_extensions(extensions),
			allocator  = context.allocator,
			active     = true,
		}
		if start_err := watch_platform_start(&watcher, root); start_err != nil {
			watch_delete_extensions(watcher.extensions, watcher.allocator)
			return {}, start_err
		}
		return watcher, nil
	}

	watch_poll :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) {
		if watcher == nil || !watcher.active {
			return false, nil
		}
		if watch_platform_changes(watcher) or_return {
			watcher.pending = true
			watcher.pending_since = time.tick_now()
		}
		if watcher.pending && time.tick_since(watcher.pending_since) >= debounce {
			watcher.pending = false
			return true, nil
		}
		return false, nil
	}

	watch_stop :: proc(watcher: ^Watcher) {
		if watcher == nil || !watcher.active {
			return
		}
		watch_platform_stop(watcher)
		watch_delete_extensions(watcher.extensions, watcher.allocator)
		watcher^ = {}
	}

	watch_root :: proc(source_root: string) -> (root: string, err: Watch_Error) {
		if len(source_root) == 0 {
			return "", Watch_Start_Failed{kind = .Empty_Path}
		}
		if filepath.is_abs(source_root) {
			return source_root, nil
		}
		exe_dir, exe_err := os.get_executable_directory(context.temp_allocator)
		if exe_err != nil {
			return "", Watch_Start_Failed{kind = .Exe_Path_Unknown}
		}
		joined, join_err := filepath.join({exe_dir, source_root}, context.temp_allocator)
		if join_err != nil {
			return "", Watch_Start_Failed{kind = .Out_Of_Memory}
		}
		return joined, nil
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
		ext := strings.trim_prefix(filepath.ext(name), ".")
		if ext == "" {
			return false
		}
		if strings.equal_fold(ext, "odin") {
			return true
		}
		for extension in extensions {
			if strings.equal_fold(ext, strings.trim_prefix(extension, ".")) {
				return true
			}
		}
		return false
	}

	// Ignore .git and similar directories
	watch_skips_directory :: proc(name: string) -> bool {
		return strings.has_prefix(name, ".") || strings.has_suffix(name, ".dSYM")
	}

}

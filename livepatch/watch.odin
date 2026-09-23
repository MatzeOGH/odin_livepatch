#+build windows
package livepatch

// The source watcher reports settled source changes. It deliberately never calls patch():
// the application applies the patch at its own safe point.

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:path/filepath"
@(require) import "core:strings"
import "core:time"
import win "core:sys/windows"

Watch_Error :: union {
	Watch_Start_Failed,
	Watch_Failed,
}

Watch_Start_Failed :: struct {
	output: string,
}

Watch_Failed :: struct {
	output: string,
}

// Opaque to callers; pass it to watch_poll and watch_stop.
Watcher :: struct {
	directory:     win.HANDLE,
	event:         win.HANDLE,
	overlapped:    win.OVERLAPPED,
	source_root:   string,
	buffer:        [64 * 1024]u8,
	pending:       bool,
	pending_since: time.Tick,
	reading:       bool,
	active:        bool,
}

WATCH_DEBOUNCE :: 150 * time.Millisecond

when LIVEPATCH {

	// A relative source_root is resolved against the running executable.
	watch_start :: proc(source_root: string) -> (watcher: Watcher, err: Watch_Error) {
		root, root_err := watch_root(source_root)
		if root_err != nil {
			return {}, root_err
		}

		wroot := win.utf8_to_utf16(root, context.temp_allocator)
		if wroot == nil {
			delete(root, context.allocator)
			return {}, Watch_Start_Failed{output = "cannot encode the source directory path"}
		}

		directory := win.CreateFileW(
			cstring16(raw_data(wroot)),
			win.FILE_LIST_DIRECTORY,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
			nil,
			win.OPEN_EXISTING,
			win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OVERLAPPED,
			nil,
		)
		if directory == win.INVALID_HANDLE_VALUE {
			delete(root, context.allocator)
			return {}, Watch_Start_Failed{output = fmt.tprintf("cannot watch %s: Windows error %d", source_root, win.GetLastError())}
		}

		event := win.CreateEventW(nil, true, false, nil)
		if event == nil {
			win.CloseHandle(directory)
			delete(root, context.allocator)
			return {}, Watch_Start_Failed{output = fmt.tprintf("cannot create the watcher event: Windows error %d", win.GetLastError())}
		}

		watcher = Watcher{
			directory   = directory,
			event       = event,
			source_root = root,
			active      = true,
		}
		return watcher, nil
	}

	// Reports one debounced source change. Non-blocking; call it from the main loop.
	watch_poll :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) {
		if watcher == nil || !watcher.active {
			return false, nil
		}
		if !watcher.reading {
			// Windows retains the OVERLAPPED pointer, so start I/O only once the caller owns
			// the watcher's stable storage (it is returned by value).
			if err = watch_begin_read(watcher); err != nil {
				return false, err
			}
			return false, nil
		}

		switch win.WaitForSingleObject(watcher.event, 0) {
		case win.WAIT_TIMEOUT:
			// No new event: a prior write has settled.
		case win.WAIT_OBJECT_0:
			bytes: win.DWORD
			if !win.GetOverlappedResult(watcher.directory, &watcher.overlapped, &bytes, false) {
				return false, Watch_Failed{output = fmt.tprintf("source watcher failed: Windows error %d", win.GetLastError())}
			}
			if bytes == 0 || watch_buffer_affects_sources(watcher, int(bytes)) {
				watcher.pending = true
				watcher.pending_since = time.tick_now()
			}
			if err = watch_begin_read(watcher); err != nil {
				return false, err
			}
		case:
			return false, Watch_Failed{output = fmt.tprintf("cannot poll the source watcher: Windows error %d", win.GetLastError())}
		}

		if watcher.pending && time.tick_since(watcher.pending_since) >= debounce {
			watcher.pending = false
			return true, nil
		}
		return false, nil
	}

	// Safe to call repeatedly.
	watch_stop :: proc(watcher: ^Watcher) {
		if watcher == nil || !watcher.active {
			return
		}
		if watcher.reading {
			// The kernel writes the buffer until the cancel completes.
			bytes: win.DWORD
			_ = win.CancelIoEx(watcher.directory, &watcher.overlapped)
			_ = win.GetOverlappedResult(watcher.directory, &watcher.overlapped, &bytes, true)
		}
		_ = win.CloseHandle(watcher.event)
		_ = win.CloseHandle(watcher.directory)
		delete(watcher.source_root, context.allocator)
		watcher^ = {}
	}

	@(private = "file")
	watch_root :: proc(source_root: string) -> (root: string, err: Watch_Error) {
		if len(source_root) == 0 {
			return "", Watch_Start_Failed{output = "the source directory path is empty"}
		}

		path := source_root
		if !filepath.is_abs(path) {
			exe, exe_err := os.get_executable_path(context.temp_allocator)
			if exe_err != nil {
				return "", Watch_Start_Failed{output = "cannot find the running executable path"}
			}
			path, exe_err = filepath.join({os.dir(exe), path}, context.temp_allocator)
			if exe_err != nil {
				return "", Watch_Start_Failed{output = "out of memory building the source directory path"}
			}
		}

		stored_root, clone_err := strings.clone(path, context.allocator)
		if clone_err != nil {
			return "", Watch_Start_Failed{output = "out of memory storing the source directory path"}
		}
		return stored_root, nil
	}

	@(private = "file")
	watch_begin_read :: proc(watcher: ^Watcher) -> Watch_Error {
		watcher.overlapped = win.OVERLAPPED{hEvent = watcher.event}
		_ = win.ResetEvent(watcher.event)
		ok := win.ReadDirectoryChangesW(
			watcher.directory,
			raw_data(watcher.buffer[:]),
			win.DWORD(len(watcher.buffer)),
			true,
			win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_LAST_WRITE,
			nil,
			&watcher.overlapped,
			nil,
		)
		if !ok && win.GetLastError() != win.ERROR_IO_PENDING {
			return Watch_Failed{output = fmt.tprintf("cannot watch the source directory: Windows error %d", win.GetLastError())}
		}
		watcher.reading = true
		return nil
	}

	@(private = "file")
	watch_buffer_affects_sources :: proc(watcher: ^Watcher, bytes: int) -> bool {
		offset := 0
		header_size := int(offset_of(win.FILE_NOTIFY_INFORMATION, FileName))
		for {
			if offset + header_size > bytes {
				return true // A malformed record may hide a source change; rebuild safely.
			}
			info := (^win.FILE_NOTIFY_INFORMATION)(raw_data(watcher.buffer[offset:]))
			name_bytes := int(info.FileNameLength)
			if name_bytes < 0 || name_bytes % size_of(u16) != 0 || name_bytes > bytes - offset - header_size {
				return true
			}

			name16 := ([^]u16)(raw_data(info.FileName[:]))[:name_bytes / size_of(u16)]
			name := win.utf16_to_utf8(name16, context.temp_allocator) or_else ""
			if watch_change_affects_sources(watcher, info.Action, name) {
				return true
			}

			next := int(info.NextEntryOffset)
			if next == 0 {
				return false
			}
			if next < header_size || next > bytes - offset {
				return true
			}
			offset += next
		}
	}

	@(private = "file")
	watch_change_affects_sources :: proc(watcher: ^Watcher, action: win.DWORD, name: string) -> bool {
		// Ignore the patch object directory: patch() rewrites it every patch, which would
		// otherwise trigger another patch and loop forever. Comes first, before the
		// conservative removed-directory rule below reacts to its removal.
		if name == PATCH_OUTPUT_DIRNAME || strings.has_prefix(name, PATCH_OUTPUT_DIRNAME + "\\") {
			return false
		}
		if strings.has_suffix(name, ".odin") {
			return true
		}
		if action == win.FILE_ACTION_REMOVED || action == win.FILE_ACTION_RENAMED_OLD_NAME {
			// Windows does not say if a deleted entry was a file or directory, and a removed
			// directory may have held source. Rebuild conservatively.
			return true
		}
		if action == win.FILE_ACTION_ADDED || action == win.FILE_ACTION_RENAMED_NEW_NAME {
			path, join_err := filepath.join({watcher.source_root, name}, context.temp_allocator)
			if join_err != nil {
				return true
			}
			info, stat_err := os.stat(path, context.temp_allocator)
			if stat_err != nil {
				return false
			}
			defer os.file_info_delete(info, context.temp_allocator)
			return info.type == .Directory
		}
		return false
	}

} else {

	watch_start :: proc(source_root: string) -> (watcher: Watcher, err: Watch_Error) {
		return {}, nil
	}

	watch_poll :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) {
		return false, nil
	}

	watch_stop :: proc(watcher: ^Watcher) {}

}

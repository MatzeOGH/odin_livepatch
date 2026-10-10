#+build windows amd64
package livepatch

@(require) import "core:os"
@(require) import "core:time"
@(require) import win "core:sys/windows"

when LIVEPATCH {

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

	watch_start :: proc(source_root: string) -> (watcher: Watcher, err: Watch_Error) {
		root := watch_root(source_root) or_return
		defer if err != nil {
			delete(root, context.allocator)
		}

		wroot := win.utf8_to_utf16(root, context.temp_allocator)
		if wroot == nil {
			return {}, Watch_Start_Failed{kind = .Out_Of_Memory}
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
			return {}, Watch_Start_Failed{kind = .Cannot_Open_Dir, os_error = os.Platform_Error(win.GetLastError())}
		}

		event := win.CreateEventW(nil, true, false, nil)
		if event == nil {
			win.CloseHandle(directory)
			return {}, Watch_Start_Failed{kind = .Cannot_Create_Event, os_error = os.Platform_Error(win.GetLastError())}
		}

		watcher = Watcher{
			directory   = directory,
			event       = event,
			source_root = root,
			active      = true,
		}
		return watcher, nil
	}

	watch_poll :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) {
		if watcher == nil || !watcher.active {
			return false, nil
		}
		if !watcher.reading {
			return false, watch_begin_read(watcher)
		}

		switch win.WaitForSingleObject(watcher.event, 0) {
		case win.WAIT_TIMEOUT:
		case win.WAIT_OBJECT_0:
			bytes: win.DWORD
			if !win.GetOverlappedResult(watcher.directory, &watcher.overlapped, &bytes, false) {
				return false, Watch_Failed{kind = .Cannot_Read_Changes, os_error = os.Platform_Error(win.GetLastError())}
			}
			if bytes == 0 || watch_buffer_affects_sources(watcher, int(bytes)) {
				watcher.pending = true
				watcher.pending_since = time.tick_now()
			}
			watch_begin_read(watcher) or_return
		case:
			return false, Watch_Failed{kind = .Cannot_Poll, os_error = os.Platform_Error(win.GetLastError())}
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
		if watcher.reading {
			bytes: win.DWORD
			_ = win.CancelIoEx(watcher.directory, &watcher.overlapped)
			_ = win.GetOverlappedResult(watcher.directory, &watcher.overlapped, &bytes, true)
		}
		_ = win.CloseHandle(watcher.event)
		_ = win.CloseHandle(watcher.directory)
		delete(watcher.source_root, context.allocator)
		watcher^ = {}
	}

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
			return Watch_Failed{kind = .Cannot_Read_Changes, os_error = os.Platform_Error(win.GetLastError())}
		}
		watcher.reading = true
		return nil
	}

	watch_buffer_affects_sources :: proc(watcher: ^Watcher, bytes: int) -> bool {
		offset := 0
		header_size := int(offset_of(win.FILE_NOTIFY_INFORMATION, FileName))
		for {
			if offset + header_size > bytes {
				return true // a malformed record can hide a source change
			}
			info := (^win.FILE_NOTIFY_INFORMATION)(raw_data(watcher.buffer[offset:]))
			name_bytes := int(info.FileNameLength)
			if name_bytes % size_of(u16) != 0 || name_bytes > bytes - offset - header_size {
				return true
			}

			name16 := ([^]u16)(raw_data(info.FileName[:]))[:name_bytes / size_of(u16)]
			name := win.utf16_to_utf8(name16, context.temp_allocator) or_else ""
			if watch_change_affects_sources(name) {
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

}

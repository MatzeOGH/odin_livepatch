#+build windows amd64
package livepatch

@(require) import "core:os"
@(require) import win "core:sys/windows"

when LIVEPATCH {

	Watch_Platform :: struct {
		directory:  win.HANDLE,
		event:      win.HANDLE,
		overlapped: win.OVERLAPPED,
		buffer:     [64 * 1024]u8,
		reading:    bool,
	}

	watch_platform_start :: proc(watcher: ^Watcher, root: string) -> Watch_Error {
		wroot := win.utf8_to_utf16(root, context.temp_allocator)
		if wroot == nil {
			return Watch_Start_Failed{kind = .Out_Of_Memory}
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
			return Watch_Start_Failed{kind = .Cannot_Open_Dir, os_error = os.Platform_Error(win.GetLastError())}
		}
		event := win.CreateEventW(nil, true, false, nil)
		if event == nil {
			win.CloseHandle(directory)
			return Watch_Start_Failed{kind = .Cannot_Create_Event, os_error = os.Platform_Error(win.GetLastError())}
		}
		watcher.platform = {directory = directory, event = event}
		return nil
	}

	watch_platform_changes :: proc(watcher: ^Watcher) -> (affects: bool, err: Watch_Error) {
		platform := &watcher.platform
		if !platform.reading {
			return false, watch_begin_read(platform)
		}
		switch win.WaitForSingleObject(platform.event, 0) {
		case win.WAIT_TIMEOUT:
			return false, nil
		case win.WAIT_OBJECT_0:
			bytes: win.DWORD
			if !win.GetOverlappedResult(platform.directory, &platform.overlapped, &bytes, false) {
				return false, Watch_Failed{kind = .Cannot_Read_Changes, os_error = os.Platform_Error(win.GetLastError())}
			}
			// 0 bytes: the buffer overflowed, and the changes are lost
			affects = bytes == 0 || watch_buffer_affects_sources(platform.buffer[:bytes], watcher.extensions)
			return affects, watch_begin_read(platform)
		}
		return false, Watch_Failed{kind = .Cannot_Poll, os_error = os.Platform_Error(win.GetLastError())}
	}

	watch_platform_stop :: proc(watcher: ^Watcher) {
		platform := &watcher.platform
		if platform.reading {
			bytes: win.DWORD
			_ = win.CancelIoEx(platform.directory, &platform.overlapped)
			_ = win.GetOverlappedResult(platform.directory, &platform.overlapped, &bytes, true)
		}
		_ = win.CloseHandle(platform.event)
		_ = win.CloseHandle(platform.directory)
	}

	watch_begin_read :: proc(platform: ^Watch_Platform) -> Watch_Error {
		platform.overlapped = win.OVERLAPPED{hEvent = platform.event}
		_ = win.ResetEvent(platform.event)
		ok := win.ReadDirectoryChangesW(
			platform.directory,
			raw_data(platform.buffer[:]),
			win.DWORD(len(platform.buffer)),
			true,
			win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_LAST_WRITE,
			nil,
			&platform.overlapped,
			nil,
		)
		platform.reading = bool(ok) || win.GetLastError() == win.ERROR_IO_PENDING
		if !platform.reading {
			return Watch_Failed{kind = .Cannot_Read_Changes, os_error = os.Platform_Error(win.GetLastError())}
		}
		return nil
	}

	watch_buffer_affects_sources :: proc(buffer: []u8, extensions: []string) -> bool {
		offset := 0
		header_size := int(offset_of(win.FILE_NOTIFY_INFORMATION, FileName))
		for {
			if offset + header_size > len(buffer) {
				return true // a malformed record can hide a source change
			}
			info := (^win.FILE_NOTIFY_INFORMATION)(raw_data(buffer[offset:]))
			name_bytes := int(info.FileNameLength)
			if name_bytes % size_of(u16) != 0 || name_bytes > len(buffer) - offset - header_size {
				return true
			}

			name16 := ([^]u16)(raw_data(info.FileName[:]))[:name_bytes / size_of(u16)]
			name := win.utf16_to_utf8(name16, context.temp_allocator) or_else ""
			if watch_change_affects_sources(name, extensions) {
				return true
			}

			next := int(info.NextEntryOffset)
			if next == 0 {
				return false
			}
			if next < header_size || next > len(buffer) - offset {
				return true
			}
			offset += next
		}
	}

}

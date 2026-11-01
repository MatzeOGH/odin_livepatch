#+build linux amd64
package livepatch

@(require) import "core:os"
@(require) import "core:path/filepath"
@(require) import "core:strings"
@(require) import "core:sys/linux"

when LIVEPATCH {

	Watch_Platform :: struct {
		fd:          linux.Fd,
		directories: map[linux.Wd]string, // watch -> its directory
		buffer:      [64 * 1024]u8,
	}

	WATCH_MASK :: linux.Inotify_Event_Mask{.MODIFY, .CLOSE_WRITE, .MOVED_FROM, .MOVED_TO, .CREATE, .DELETE, .ONLYDIR}

	watch_platform_start :: proc(watcher: ^Watcher, root: string) -> Watch_Error {
		fd, init_err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
		if init_err != .NONE {
			return Watch_Start_Failed{kind = .Cannot_Create_Event, os_error = os.Platform_Error(init_err)}
		}
		watcher.platform.fd = fd
		watcher.platform.directories = make(map[linux.Wd]string)
		if add_err := watch_add_tree(watcher, root); add_err != .NONE {
			watch_platform_stop(watcher)
			return Watch_Start_Failed{kind = .Cannot_Open_Dir, os_error = os.Platform_Error(add_err)}
		}
		return nil
	}

	watch_platform_changes :: proc(watcher: ^Watcher) -> (affects: bool, err: Watch_Error) {
		for {
			bytes_read, read_err := linux.read(watcher.platform.fd, watcher.platform.buffer[:])
			if read_err == .EAGAIN {
				return
			}
			if read_err != .NONE {
				return false, Watch_Failed{kind = .Cannot_Read_Changes, os_error = os.Platform_Error(read_err)}
			}
			if watch_buffer_affects_sources(watcher, bytes_read) { // also adds new directories: always parse
				affects = true
			}
		}
	}

	watch_platform_stop :: proc(watcher: ^Watcher) {
		_ = linux.close(watcher.platform.fd)
		for _, dir in watcher.platform.directories {
			delete(dir, watcher.allocator)
		}
		delete(watcher.platform.directories)
	}

	watch_add_tree :: proc(watcher: ^Watcher, dir: string) -> linux.Errno {
		cdir := strings.clone_to_cstring(dir, context.temp_allocator)
		wd, err := linux.inotify_add_watch(watcher.platform.fd, cdir, WATCH_MASK)
		if err != .NONE {
			return err
		}
		if old, found := watcher.platform.directories[wd]; found {
			delete(old, watcher.allocator) // the same directory, seen again
		}
		watcher.platform.directories[wd] = strings.clone(dir, watcher.allocator)

		entries, _ := watch_read_directory(dir)
		for entry in entries {
			if entry.directory && !watch_skips_directory(entry.name) {
				_ = watch_add_tree(watcher, entry.path) // a directory that went away meanwhile
			}
		}
		return .NONE
	}

	watch_buffer_affects_sources :: proc(watcher: ^Watcher, bytes: int) -> (affects: bool) {
		buffer := watcher.platform.buffer[:bytes]
		offset := 0
		header_size := size_of(linux.Inotify_Event)
		for offset + header_size <= len(buffer) {
			event := (^linux.Inotify_Event)(raw_data(buffer[offset:]))
			name_len := int(event.len)
			if name_len > len(buffer) - offset - header_size {
				return true // a malformed record can hide a source change
			}
			name := strings.truncate_to_byte(string(buffer[offset + header_size:][:name_len]), 0)
			offset += header_size + name_len

			switch {
			case .Q_OVERFLOW in event.mask:
				affects = true // events were lost
			case .IGNORED in event.mask:
				if dir, found := watcher.platform.directories[event.wd]; found {
					delete(dir, watcher.allocator)
					delete_key(&watcher.platform.directories, event.wd)
				}
			case .ISDIR in event.mask:
				// A new directory
				if event.mask & {.CREATE, .MOVED_TO} != {} && !watch_skips_directory(name) {
					if parent, found := watcher.platform.directories[event.wd]; found {
						path, _ := filepath.join({parent, name}, context.temp_allocator)
						_ = watch_add_tree(watcher, path)
					}
				}
			case watch_change_affects_sources(name, watcher.extensions):
				affects = true
			}
		}
		return
	}

}

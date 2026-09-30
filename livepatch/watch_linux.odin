#+build linux amd64
package livepatch

@(require) import "core:os"
@(require) import "core:path/filepath"
@(require) import "core:strings"
@(require) import "core:time"
@(require) import "core:sys/linux"

when LIVEPATCH {

	Watcher :: struct {
		fd:            linux.Fd,
		source_root:   string,
		directories:   map[linux.Wd]string, // watch -> its directory
		buffer:        [64 * 1024]u8,
		pending:       bool,
		pending_since: time.Tick,
		active:        bool,
	}

	WATCH_MASK :: linux.Inotify_Event_Mask{.MODIFY, .CLOSE_WRITE, .MOVED_FROM, .MOVED_TO, .CREATE, .DELETE, .ONLYDIR}

	watch_start :: proc(source_root: string) -> (watcher: Watcher, err: Watch_Error) {
		root := watch_root(source_root) or_return

		fd, ierr := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
		if ierr != .NONE {
			delete(root, context.allocator)
			return {}, Watch_Start_Failed{kind = .Cannot_Create_Event, os_error = os.Platform_Error(ierr)}
		}

		watcher = Watcher{
			fd          = fd,
			source_root = root,
			directories = make(map[linux.Wd]string, context.allocator),
			active      = true,
		}
		if werr := watch_add_tree(&watcher, root); werr != .NONE {
			watch_stop(&watcher)
			return {}, Watch_Start_Failed{kind = .Cannot_Open_Dir, os_error = os.Platform_Error(werr)}
		}
		return watcher, nil
	}

	watch_poll :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) {
		if watcher == nil || !watcher.active {
			return false, nil
		}

		for {
			n, rerr := linux.read(watcher.fd, watcher.buffer[:])
			if rerr == .EAGAIN {
				break
			}
			if rerr != .NONE {
				return false, Watch_Failed{kind = .Cannot_Read_Changes, os_error = os.Platform_Error(rerr)}
			}
			if watch_buffer_affects_sources(watcher, n) {
				watcher.pending = true
				watcher.pending_since = time.tick_now()
			}
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
		_ = linux.close(watcher.fd)
		for _, dir in watcher.directories {
			delete(dir, context.allocator)
		}
		delete(watcher.directories)
		delete(watcher.source_root, context.allocator)
		watcher^ = {}
	}

	watch_add_tree :: proc(watcher: ^Watcher, dir: string) -> linux.Errno {
		cdir := strings.clone_to_cstring(dir, context.temp_allocator)
		wd, err := linux.inotify_add_watch(watcher.fd, cdir, WATCH_MASK)
		if err != .NONE {
			return err
		}
		if old, found := watcher.directories[wd]; found {
			delete(old, context.allocator) // the same directory, seen again
		}
		watcher.directories[wd] = strings.clone(dir, context.allocator)

		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for e in entries {
			if e.type == .Directory {
				_ = watch_add_tree(watcher, e.fullpath) // a directory that went away meanwhile
			}
		}
		return .NONE
	}

	watch_buffer_affects_sources :: proc(watcher: ^Watcher, bytes: int) -> (affects: bool) {
		offset := 0
		header_size := size_of(linux.Inotify_Event)
		for offset + header_size <= bytes {
			event := (^linux.Inotify_Event)(raw_data(watcher.buffer[offset:]))
			name_len := int(event.len)
			if name_len > bytes - offset - header_size {
				return true // a malformed record can hide a source change
			}
			name := strings.truncate_to_byte(string(watcher.buffer[offset + header_size:][:name_len]), 0)
			offset += header_size + name_len

			switch {
			case .Q_OVERFLOW in event.mask:
				affects = true // events were lost
			case .IGNORED in event.mask:
				if dir, found := watcher.directories[event.wd]; found {
					delete(dir, context.allocator)
					delete_key(&watcher.directories, event.wd)
				}
			case .ISDIR in event.mask:
				// A new directory: watch it. Its sources count on their next change.
				if event.mask & {.CREATE, .MOVED_TO} != {} {
					if parent, found := watcher.directories[event.wd]; found {
						path, _ := filepath.join({parent, name}, context.temp_allocator)
						_ = watch_add_tree(watcher, path)
					}
				}
			case watch_change_affects_sources(name):
				affects = true
			}
		}
		return
	}

}

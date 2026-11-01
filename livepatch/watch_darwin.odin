#+build darwin arm64
package livepatch

@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:sys/kqueue"
@(require) import "core:sys/posix"

when LIVEPATCH {

	Watch_Platform :: struct {
		kq:      kqueue.KQ,
		watched: map[posix.FD]Watched, // open descriptor -> what it watches
		paths:   map[string]posix.FD,  // the watched paths, which are the strings of `watched`
	}

	Watched :: struct {
		path:      string,
		directory: bool,
	}

	// A descriptor for events only: it does not keep a volume busy. core:sys/posix does not
	// have this flag.
	@(private = "file")
	O_EVTONLY :: 0x8000

	// No .Attrib: macOS changes the attributes of a file by itself after a write (Spotlight,
	// provenance attributes). The inotify watcher does not watch attributes either.
	@(private = "file")
	VNODE_FLAGS :: kqueue.VNode_Flags{.Delete, .Write, .Extend, .Rename, .Revoke}

	// setrlimit refuses a larger soft limit for open files (OPEN_MAX)
	@(private = "file")
	MAX_OPEN_FILES :: 10240

	watch_platform_start :: proc(watcher: ^Watcher, root: string) -> Watch_Error {
		// watch_path accepts a path that does not exist
		if !os.is_dir(root) {
			return Watch_Start_Failed{kind = .Cannot_Open_Dir, os_error = os.General_Error.Not_Exist}
		}

		// Each watched path has an open descriptor, and a process starts with a limit of 256
		limit: posix.rlimit
		if posix.getrlimit(.NOFILE, &limit) == .OK && limit.rlim_cur < MAX_OPEN_FILES {
			limit.rlim_cur = min(limit.rlim_max, MAX_OPEN_FILES)
			posix.setrlimit(.NOFILE, &limit)
		}

		kq, kqueue_err := kqueue.kqueue()
		if kqueue_err != .NONE {
			return Watch_Start_Failed{kind = .Cannot_Create_Event, os_error = os.Platform_Error(kqueue_err)}
		}
		watcher.platform = {
			kq      = kq,
			watched = make(map[posix.FD]Watched),
			paths   = make(map[string]posix.FD),
		}
		if _, add_err := watch_tree(watcher, root); add_err != .NONE {
			watch_platform_stop(watcher)
			return Watch_Start_Failed{kind = .Cannot_Open_Dir, os_error = os.Platform_Error(add_err)}
		}
		return nil
	}

	watch_platform_changes :: proc(watcher: ^Watcher) -> (affects: bool, err: Watch_Error) {
		events: [64]kqueue.KEvent
		no_wait: posix.timespec
		for {
			count, kevent_err := kqueue.kevent(watcher.platform.kq, nil, events[:], &no_wait)
			if kevent_err == .EINTR {
				continue
			}
			if kevent_err != .NONE {
				return false, Watch_Failed{kind = .Cannot_Read_Changes, os_error = os.Platform_Error(kevent_err)}
			}
			for &event in events[:count] {
				event_affects, add_err := watch_event_affects_sources(watcher, &event)
				if add_err != .NONE {
					return false, Watch_Failed{kind = .Cannot_Open_Dir, os_error = os.Platform_Error(add_err)}
				}
				if event_affects {
					affects = true
				}
			}
			if int(count) < len(events) {
				return
			}
		}
	}

	watch_platform_stop :: proc(watcher: ^Watcher) {
		for fd, watched in watcher.platform.watched {
			posix.close(fd)
			delete(watched.path, watcher.allocator)
		}
		delete(watcher.platform.watched)
		delete(watcher.platform.paths)
		posix.close(watcher.platform.kq)
	}

	// Watches the directory `dir` and each entry in it that has no watch yet: a source file, or
	// a directory with what it holds. added: a source file got a watch.
	@(private = "file")
	watch_tree :: proc(watcher: ^Watcher, dir: string) -> (added: bool, err: posix.Errno) {
		watch_path(watcher, dir, true) or_return
		entries, read_ok := watch_read_directory(dir)
		if !read_ok {
			return // the directory went away meanwhile: its parent reports it
		}
		for entry in entries {
			if entry.path in watcher.platform.paths {
				continue
			}
			if entry.directory {
				if watch_skips_directory(entry.name) {
					continue
				}
				if watch_tree(watcher, entry.path) or_return {
					added = true
				}
			} else if watch_change_affects_sources(entry.name, watcher.extensions) {
				watch_path(watcher, entry.path, false) or_return
				added = true
			}
		}
		return
	}

	// Watches `path`, if it has no watch yet. A path that does not exist (any more) is no error.
	@(private = "file")
	watch_path :: proc(watcher: ^Watcher, path: string, directory: bool) -> posix.Errno {
		if path in watcher.platform.paths {
			return .NONE
		}
		flags := transmute(posix.O_Flags)i32(O_EVTONLY) + {.CLOEXEC}
		fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), flags)
		if fd < 0 {
			open_err := posix.errno()
			return open_err == .ENOENT ? .NONE : open_err
		}
		change := kqueue.KEvent{ident = uintptr(fd), filter = .VNode, flags = {.Add, .Enable, .Clear}}
		change.fflags.vnode = VNODE_FLAGS
		if _, kevent_err := kqueue.kevent(watcher.platform.kq, {change}, nil, nil); kevent_err != .NONE {
			posix.close(fd)
			return kevent_err
		}
		stored := strings.clone(path, watcher.allocator)
		watcher.platform.watched[fd] = Watched{stored, directory}
		watcher.platform.paths[stored] = fd
		return .NONE
	}

	// Stops watching a descriptor. Closing it also removes its kqueue event.
	@(private = "file")
	watch_remove :: proc(watcher: ^Watcher, fd: posix.FD) {
		watched := watcher.platform.watched[fd]
		delete_key(&watcher.platform.paths, watched.path)
		delete_key(&watcher.platform.watched, fd)
		delete(watched.path, watcher.allocator)
		posix.close(fd)
	}

	// Stops watching the directory `dir` and everything below it. After a rename, the watches
	// below it would keep the old paths, and a new file at one of those paths would get no watch.
	@(private = "file")
	watch_remove_tree :: proc(watcher: ^Watcher, dir: string) {
		below := strings.concatenate({dir, "/"}, context.temp_allocator)
		removed := make([dynamic]posix.FD, context.temp_allocator)
		for path, fd in watcher.platform.paths {
			if path == dir || strings.has_prefix(path, below) {
				append(&removed, fd)
			}
		}
		for fd in removed {
			watch_remove(watcher, fd)
		}
	}

	@(private = "file")
	watch_event_affects_sources :: proc(watcher: ^Watcher, event: ^kqueue.KEvent) -> (affects: bool, err: posix.Errno) {
		fd := posix.FD(event.ident)
		watched, found := watcher.platform.watched[fd]
		if !found {
			return
		}
		path := strings.clone(watched.path, context.temp_allocator) // removing the watch frees watched.path
		gone := event.fflags.vnode & {.Delete, .Rename, .Revoke} != {}
		switch {
		case !watched.directory:
			if gone {
				// Replaced or removed: watch the file that is at the path now, if there is one
				watch_remove(watcher, fd)
				watch_path(watcher, path, false) or_return
			}
			return true, .NONE
		case gone:
			watch_remove_tree(watcher, path)
			return false, .NONE // a moved directory: its sources count on their next change
		case .Write in event.fflags.vnode:
			return watch_tree(watcher, path)
		}
		return
	}

}

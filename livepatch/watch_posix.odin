#+build linux amd64, darwin arm64
package livepatch

@(require) import "core:strings"
@(require) import "core:sys/posix"

when LIVEPATCH {

	Watch_Entry :: struct {
		name:      string,
		path:      string,
		directory: bool,
	}

	// The entries of `dir`, in the temp allocator. readdir gives the type of most entries, so
	// this needs no stat for each entry, as os.read_all_directory_by_path does.
	watch_read_directory :: proc(dir: string) -> (entries: []Watch_Entry, ok: bool) {
		handle := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
		if handle == nil {
			return
		}
		defer posix.closedir(handle)

		list := make([dynamic]Watch_Entry, context.temp_allocator)
		for {
			entry := posix.readdir(handle)
			if entry == nil {
				break
			}
			name_c := cstring(&entry.d_name[0])
			if name_c == "." || name_c == ".." {
				continue
			}
			directory := entry.d_type == .DIR
			if entry.d_type == .UNKNOWN { // a file system that does not give the type
				status: posix.stat_t
				directory = posix.fstatat(posix.dirfd(handle), name_c, &status, {.SYMLINK_NOFOLLOW}) == .OK && posix.S_ISDIR(status.st_mode)
			}
			path := strings.concatenate({dir, "/", string(name_c)}, context.temp_allocator)
			append(&list, Watch_Entry{name = path[len(dir) + 1:], path = path, directory = directory})
		}
		return list[:], true
	}

}

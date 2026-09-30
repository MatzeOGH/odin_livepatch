#+build windows amd64, linux amd64
package livepatch

import "core:os"
import "core:strings"
import "core:time"

read_all :: proc(dir: string, since: time.Time, allocator := context.temp_allocator) -> (objs: []Loaded_Object, ok: bool) {
	entries, dir_err := os.read_all_directory_by_path(dir, allocator)
	if dir_err != nil {
		return
	}

	loaded := make([dynamic]Loaded_Object, allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, OBJECT_EXT) || time.diff(since, entry.modification_time) < 0 {
			continue
		}
		path := entry.fullpath
		data, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return
		}
		o := object_parse(path, data) or_return
		append(&loaded, o)
	}
	return loaded[:], true
}

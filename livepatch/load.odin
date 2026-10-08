#+build windows amd64, linux amd64
package livepatch

import "core:os"
import "core:strings"

remove_objects :: proc(dir: string) {
	entries, dir_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if dir_err != nil {
		return
	}
	for entry in entries {
		if entry.type != .Directory && strings.has_suffix(entry.name, OBJECT_EXT) {
			_ = os.remove(entry.fullpath)
		}
	}
}

read_all :: proc(dir: string, allocator := context.temp_allocator) -> (objs: []Loaded_Object, ok: bool) {
	entries, dir_err := os.read_all_directory_by_path(dir, allocator)
	if dir_err != nil {
		return
	}

	loaded := make([dynamic]Loaded_Object, allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, OBJECT_EXT) {
			continue
		}
		path := entry.fullpath
		data, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return
		}
		object := parse_object(path, data) or_return
		append(&loaded, object)
	}
	return loaded[:], true
}

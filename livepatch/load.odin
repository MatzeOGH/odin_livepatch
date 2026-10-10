#+build windows amd64, linux amd64
package livepatch

import "core:fmt"
import "core:os"
import "core:path/filepath"
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

read_all :: proc(dir: string) -> (objs: []Loaded_Object, ok: bool) {
	entries, dir_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if dir_err != nil {
		return
	}

	loaded := make([dynamic]Loaded_Object, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, OBJECT_EXT) {
			continue
		}
		path := entry.fullpath
		data, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {
			return
		}
		object := parse_object(path, data) or_return
		append(&loaded, object)
	}
	return loaded[:], true
}

object_archive_path :: proc(dir: string) -> string {
	path, _ := filepath.join({dir, "lp_objects.lib"}, context.temp_allocator)
	return path
}

write_objects :: proc(dir: string, objects: []Loaded_Object) -> bool {
	when ODIN_OS == .Windows {
		return os.write_entire_file(object_archive_path(dir), archive_make(objects)) == nil
	} else {
		for object in objects {
			if os.write_entire_file(object.path, object.out) != nil {
				return false
			}
		}
		return true
	}
}

archive_make :: proc(objects: []Loaded_Object) -> []byte {
	member :: proc(archive: ^strings.Builder, name: string, data: []byte) {
		fmt.sbprintf(archive, "%-16s%-12d%-6d%-6d%-8d%-10d`\n", name, 0, 0, 0, 644, len(data))
		strings.write_bytes(archive, data)
		if len(data) % 2 == 1 {
			strings.write_byte(archive, '\n')
		}
	}
	names := strings.builder_make(context.temp_allocator)
	offsets := make([]int, len(objects), context.temp_allocator)
	size := 8 + 64
	for object, index in objects {
		offsets[index] = strings.builder_len(names)
		fmt.sbprintf(&names, "%s/\n", filepath.base(object.path))
		size += 60 + len(object.out) + 1
	}
	archive := strings.builder_make(0, size + strings.builder_len(names), context.temp_allocator)
	strings.write_string(&archive, "!<arch>\n")
	member(&archive, "//", names.buf[:])
	for object, index in objects {
		member(&archive, fmt.tprintf("/%d", offsets[index]), object.out)
	}
	return archive.buf[:]
}

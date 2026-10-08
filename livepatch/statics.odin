#+build windows amd64, linux amd64, darwin arm64
package livepatch

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

Static_Keys :: map[string]string

// A local declaration is named by its parent and its offset in the file:
//   a proc literal:      <parent>$anon-<pkg>:<file>:<offset>
//   a nested procedure:  <parent>.<name>-<offset>
//   a local type:        <parent>::<name>::$<offset of its scope>, in the names of generic instances
// They nest, as in `main::outer.inner-589$anon-main:a.odin:640`.
ANON :: "$anon-"

static_split :: proc(name: string) -> (group: string, offset: int, ok: bool) {
	dot := strings.last_index(name, "-.")
	dash := strings.last_index_byte(name, '-')
	if dot < 0 || dash <= dot + 2 {
		return
	}
	value := strconv.parse_u64_of_base(name[dash + 1:], 10) or_return
	return name[:dash], int(value), true
}

Segment :: struct {
	group, start, sep, end, offset: int,
}

segment_at :: proc(name: string, i: int) -> (segment: Segment, ok: bool) {
	start, sep, group := i, -1, 0
	switch {
	case strings.has_prefix(name[i:], ANON):
		EXT :: ".odin"
		ext := strings.index(name[i + len(ANON):], EXT + ":")
		if ext < 0 {
			return
		}
		sep = i + len(ANON) + ext + len(EXT)
	case name[i] == '$' && i >= 2 && name[i - 2:i] == "::":
		// The group is the path of the type, as `main::outer::Local`
		start, sep, group = i - 2, i, i - 2
		for group > 0 {
			if group >= 2 && name[group - 2:group] == "::" {
				group -= 2
			} else if c := name[group - 1]; is_ident_byte(c) || c == '.' || c == '-' || c == '[' || c == ']' {
				group -= 1
			} else {
				break
			}
		}
	case name[i] == '.' && i > 0 && name[i - 1] != '-':
		// A nested procedure is `.<name>-<offset>`, a static `-.<name>-<offset>`
		sep = i + 1
		for sep < len(name) && is_ident_byte(name[sep]) {
			sep += 1
		}
		if sep == i + 1 || sep >= len(name) || name[sep] != '-' {
			return
		}
	case:
		return
	}
	digits: int
	value, _ := strconv.parse_u64_of_base(name[sep + 1:], 10, &digits)
	end := sep + 1 + digits
	if digits == 0 || name[i] == '.' && end < len(name) && strings.index_byte(".-$", name[end]) < 0 {
		return
	}
	return {group, start, sep, end, int(value)}, true
}

// The local declarations in a name, from the outermost
local_segments :: proc(name: string, segments: ^[dynamic]Segment) {
	clear(segments)
	for i := 0; i < len(name); i += 1 {
		if name[i] != '$' && name[i] != '.' {
			continue
		}
		segment := segment_at(name, i) or_continue
		append(segments, segment)
		i = segment.end - 1
	}
}

Local_Keys :: struct {
	offsets: map[string][dynamic]int, // name[group:sep] -> the offsets of that group
	keys:    map[string]string,       // name[:end] -> key
}

local_key :: proc(locals: ^Local_Keys, name: string, segments: []Segment) -> string {
	segment := segments[len(segments) - 1]
	path := name[:segment.end]
	if key, found := locals.keys[path]; found {
		return key
	}
	parent := name[:segment.start]
	if len(segments) > 1 {
		before := segments[len(segments) - 2]
		parent = strings.concatenate({local_key(locals, name, segments[:len(segments) - 1]), name[before.end:segment.start]}, context.temp_allocator)
	}
	offsets := locals.offsets[name[segment.group:segment.sep]][:]
	key := fmt.tprintf("%s%s#%d/%d", parent, name[segment.start:segment.sep], rank_of(offsets, segment.offset), len(offsets))
	locals.keys[path] = key
	return key
}

local_name :: proc(locals: ^Local_Keys, name: string, segments: ^[dynamic]Segment) -> string {
	local_segments(name, segments)
	if len(segments) == 0 {
		return name
	}
	return strings.concatenate({local_key(locals, name, segments[:]), name[slice.last(segments[:]).end:]}, context.temp_allocator)
}

Private_Files :: map[string]string // `<pkg>::<name>` -> its file, or "" when it must stay

next_private :: proc(name: string, from: int) -> (at, name_start: int, id, file: string, ok: bool) {
	open := strings.index(name[from:], "::[")
	if open < 0 {
		return
	}
	at = from + open
	close := strings.index(name[at:], "]::")
	if close < 0 {
		return
	}
	file = name[at + 3:at + close]
	name_start = at + close + 3
	pkg := at
	for pkg > 0 && is_ident_byte(name[pkg - 1]) {
		pkg -= 1
	}
	id = strings.concatenate({name[pkg:at], "::", name[name_start:ident_end(name, name_start)]}, context.temp_allocator)
	return at, name_start, id, file, true
}

private_files_add :: proc(files: ^Private_Files, name: string) {
	from := 0
	for {
		_, name_start, id, file := next_private(name, from) or_break
		if other, found := files[id]; !found {
			files[id] = file
		} else if other != file {
			files[id] = ""
		}
		from = name_start
	}
}

private_files_strip :: proc(files: Private_Files, name: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	last, from := 0, 0
	for {
		at, name_start, id, _ := next_private(name, from) or_break
		if files[id] != "" {
			strings.write_string(&out, name[last:at + 2])
			last = name_start
		}
		from = name_start
	}
	if last == 0 {
		return name
	}
	strings.write_string(&out, name[last:])
	return strings.to_string(out)
}

static_keys_make :: proc(names: []string, allocator := context.temp_allocator) -> Static_Keys {
	locals := Local_Keys{make(map[string][dynamic]int, context.temp_allocator), make(map[string]string, context.temp_allocator)}
	statics := make(map[string][dynamic]int, context.temp_allocator)
	files := make(Private_Files, context.temp_allocator)
	segments := make([dynamic]Segment, context.temp_allocator)
	for name in names {
		if !may_have_key(name) {
			continue
		}
		private_files_add(&files, name)
		local_segments(name, &segments)
		for segment in segments {
			add_offset(&locals.offsets, name[segment.group:segment.sep], segment.offset)
		}
		group, offset := static_split(name) or_continue
		add_offset(&statics, group, offset)
	}
	// Another file can have a public declaration with the name of a private one
	if len(files) > 0 {
		for name in names {
			sep := strings.index(name, "::")
			if sep > 0 && !strings.has_prefix(name[sep:], "::[") {
				if id := name[:ident_end(name, sep + 2)]; id in files {
					files[id] = ""
				}
			}
		}
	}

	keys := make(Static_Keys, allocator)
	for name in names {
		if !may_have_key(name) || name in keys {
			continue
		}
		key := local_name(&locals, name, &segments)
		if group, offset, is_static := static_split(name); is_static {
			offsets := statics[group][:]
			key = fmt.tprintf("%s#%d/%d", local_name(&locals, group, &segments), rank_of(offsets, offset), len(offsets))
		}
		if key = private_files_strip(files, key); key != name {
			keys[name] = strings.clone(key, allocator)
		}
	}
	return keys
}

may_have_key :: proc(name: string) -> bool {
	return strings.index_byte(name, '.') >= 0 || strings.index_byte(name, '$') >= 0
}

is_ident_byte :: proc(c: byte) -> bool {
	return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

ident_end :: proc(name: string, from: int) -> int {
	end := from
	for end < len(name) && is_ident_byte(name[end]) {
		end += 1
	}
	return end
}

rank_of :: proc(offsets: []int, offset: int) -> (rank: int) {
	for other in offsets {
		if other < offset {
			rank += 1
		}
	}
	return
}

add_offset :: proc(offsets_by_group: ^map[string][dynamic]int, group: string, offset: int) {
	if group not_in offsets_by_group {
		offsets_by_group[group] = make([dynamic]int, context.temp_allocator)
	}
	offsets := &offsets_by_group[group]
	if !slice.contains(offsets[:], offset) {
		append(offsets, offset)
	}
}

data_key :: proc(keys: Static_Keys, name: string) -> string {
	return keys[name] or_else name
}

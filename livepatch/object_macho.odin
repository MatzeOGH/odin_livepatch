#+build darwin arm64
package livepatch

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

OBJECT_EXT :: ".o"
ENTRY_SYMBOL :: "lp$entry"

Loaded_Object :: struct {
	path:   string,
	data:   []byte,
	view:   Macho_View,
	fixups: [dynamic]Fixup, // written by load_patch_module after the link
}

Near_References :: struct {
	names: map[string]bool, // undefined names that some BRANCH26 reaches
}

startup_initialized_global :: proc(objects: []Loaded_Object, merged: ^Merged) -> string {
	return ""
}
Fixup :: struct {
	marker: string,  // the marker symbol, without the underscore
	offset: u32,     // from the marker
	kind:   Fixup_Kind,
	target: uintptr, // the address that the reference must reach, addend included
	name:   string,  // what it refers to, for an error
}

Fixup_Kind :: enum u8 {
	Branch26,
	Page21,
	Pageoff12, // add, or a load or store scaled by the access size
	Pointer64,
}

marker_count: int

Macho_Rewrite :: struct {
	object:             ^Loaded_Object,
	merged:             ^Merged,
	markers:            [dynamic]Nlist_64,
	added_strings:      [dynamic]u8,
	marker_at:          map[[2]u64]string, // section index, atom address -> its marker
	symbols_by_section: [][dynamic]Section_Symbol, // section index -> its defined symbols, by address
}

Section_Symbol :: struct {
	value: u64,
	index: int,
}

#+build windows amd64
package livepatch

import "core:slice"
import "core:strings"

OBJECT_EXT :: ".obj"

Loaded_Object :: struct {
	path: string,
	data: []byte,
	view: Coff_View,
}

object_parse :: proc(path: string, data: []byte) -> (o: Loaded_Object, ok: bool) {
	view := coff_parse(data) or_return
	if view.n_sections == 0 {
		return
	}
	return Loaded_Object{path, data, view}, true
}

object_symbol_count :: proc(o: ^Loaded_Object) -> int {
	return o.view.n_syms
}

object_image_size :: proc(o: ^Loaded_Object) -> (size: int) {
	for i in 0 ..< o.view.n_sections {
		sh := section_header(o.data, o.view.sec_off, i)
		if !is_discarded_section(sh) {
			size += max(int(sh.virtual_size), int(sh.size_of_raw_data)) + section_align(sh)
		}
	}
	return
}

// Skips the auxiliary records.
object_symbols :: proc(o: ^Loaded_Object, cursor: ^int) -> (s: Object_Symbol, ok: bool) {
	sym, idx := coff_symbols(o.data, o.view.sym_off, o.view.n_syms, cursor) or_return
	s.name = symbol_name(sym, o.data, o.view.strtab_off)
	s.local = sym.storage_class == IMAGE_SYM_CLASS_STATIC

	def_section := int(sym.section_number)
	if def_section > 0 {
		s.provides = sym.storage_class == IMAGE_SYM_CLASS_EXTERNAL
	} else if def_section == 0 {
		// A weak external defines its name through its default, the tag symbol.
		if aux, weak := weak_external_aux(o.data, o.view.sym_off, idx, sym); weak {
			s.provides = true
			def_section = int(coff_symbol(o.data, o.view.sym_off, int(aux.tag_index)).section_number)
		} else if sym.storage_class == IMAGE_SYM_CLASS_EXTERNAL {
			s.kind = .Undefined
			return s, true
		}
	}
	if def_section <= 0 {
		return s, true // UNDEF with no default, or ABS
	}

	section := section_header(o.data, o.view.sec_off, def_section - 1)
	switch {
	case is_discarded_section(section),
	     sym.section_number > 0 && is_object_local(sym, s.name, section),
	     strings.has_prefix(s.name, ".weak."),
	     section_name(section) == ".tls$":
		s.kind = .Skipped
	case (section.characteristics & IMAGE_SCN_MEM_EXECUTE) != 0:
		s.kind = .Code
	case (section.characteristics & IMAGE_SCN_MEM_WRITE) != 0:
		s.kind = .Data
	case:
		s.kind = .Read_Only
	}
	return s, true
}

// Not relevant for windows
Near_References :: struct {}

near_references :: proc(objects: []Loaded_Object) -> Near_References {
	return {}
}

needs_near_address :: proc(refs: ^Near_References, name: string) -> bool {
	return true
}

// A COFF object with only absolute symbols. A symbol value holds only the low 32 bits of the address
abs_object :: proc(merged: ^Merged) -> []byte {
	n := len(merged.aliases) + len(merged.externals)
	strs := make([dynamic]u8, context.temp_allocator)
	append(&strs, 0, 0, 0, 0) // the size, set below
	syms := make([dynamic]Coff_Symbol, 0, n, context.temp_allocator)
	add :: proc(syms: ^[dynamic]Coff_Symbol, strs: ^[dynamic]u8, name: string, addr: rawptr) {
		s: Coff_Symbol
		(^u32)(&s.name[4])^ = u32(len(strs))
		append(strs, name)
		append(strs, 0)
		s.value = u32(uintptr(addr))
		s.section_number = -1 // IMAGE_SYM_ABSOLUTE
		s.storage_class = IMAGE_SYM_CLASS_EXTERNAL
		append(syms, s)
	}
	for name, alias in merged.aliases {
		add(&syms, &strs, alias, merged.defs[name])
	}
	for name, addr in merged.externals {
		add(&syms, &strs, name, addr)
	}
	(^u32)(raw_data(strs[:]))^ = u32(len(strs))

	out := make([]byte, FILE_HDR_SIZE + n * COFF_SYMBOL_SIZE + len(strs), context.temp_allocator)
	fh := (^Coff_File_Header)(raw_data(out))
	fh.machine = IMAGE_FILE_MACHINE_AMD64
	fh.pointer_to_symbol_table = FILE_HDR_SIZE
	fh.number_of_symbols = u32(n)
	copy(out[FILE_HDR_SIZE:], slice.to_bytes(syms[:]))
	copy(out[FILE_HDR_SIZE + n * COFF_SYMBOL_SIZE:], strs[:])
	return out
}

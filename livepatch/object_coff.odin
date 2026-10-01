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

parse_object :: proc(path: string, data: []byte) -> (object: Loaded_Object, ok: bool) {
	view := parse_coff(data) or_return
	if view.section_count == 0 {
		return
	}
	return Loaded_Object{path, data, view}, true
}

object_symbol_count :: proc(object: ^Loaded_Object) -> int {
	return object.view.symbol_count
}

object_max_image_size :: proc(object: ^Loaded_Object) -> (size: int) {
	for section_index in 0 ..< object.view.section_count {
		section := coff_section_header(object.data, object.view.section_headers_offset, section_index)
		if !is_discarded_section(section) {
			size += max(int(section.virtual_size), int(section.size_of_raw_data)) + coff_section_align(section)
		}
	}
	return
}

// Skips the auxiliary records.
next_object_symbol :: proc(object: ^Loaded_Object, cursor: ^int) -> (symbol: Object_Symbol, ok: bool) {
	view := &object.view
	coff_sym, symbol_index := next_coff_symbol(object.data, view.symtab_offset, view.symbol_count, cursor) or_return
	symbol.name = coff_symbol_name(coff_sym, object.data, view.strtab_offset)
	symbol.local = coff_sym.storage_class == IMAGE_SYM_CLASS_STATIC

	def_section := int(coff_sym.section_number)
	if def_section > 0 {
		symbol.provides = coff_sym.storage_class == IMAGE_SYM_CLASS_EXTERNAL
	} else if def_section == 0 {
		// A weak external defines its name through its default, the tag symbol.
		if aux, weak := coff_weak_external_aux(object.data, view.symtab_offset, symbol_index, coff_sym); weak {
			symbol.provides = true
			def_section = int(coff_symbol_at(object.data, view.symtab_offset, int(aux.tag_index)).section_number)
		} else if coff_sym.storage_class == IMAGE_SYM_CLASS_EXTERNAL {
			symbol.kind = .Undefined
			return symbol, true
		}
	}
	if def_section <= 0 {
		return symbol, true // UNDEF with no default, or ABS
	}

	section := coff_section_header(object.data, view.section_headers_offset, def_section - 1)
	switch {
	case is_discarded_section(section),
	     coff_sym.section_number > 0 && is_object_local(coff_sym, symbol.name, section),
	     strings.has_prefix(symbol.name, ".weak."),
	     coff_section_name(section) == ".tls$":
		symbol.kind = .Skipped
	case (section.characteristics & IMAGE_SCN_MEM_EXECUTE) != 0:
		symbol.kind = .Code
	case (section.characteristics & IMAGE_SCN_MEM_WRITE) != 0:
		symbol.kind = .Data
	case:
		symbol.kind = .Read_Only
	}
	return symbol, true
}

// Not relevant for windows
Near_References :: struct {}

find_near_references :: proc(objects: []Loaded_Object) -> Near_References {
	return {}
}

needs_near_address :: proc(refs: ^Near_References, name: string) -> bool {
	return true
}

// A COFF object with only absolute symbols. A symbol value holds only the low 32 bits of the address
absolute_symbols_object :: proc(merged: ^Merged) -> []byte {
	symbol_count := len(merged.aliases) + len(merged.externals)
	string_table := make([dynamic]u8, context.temp_allocator)
	append(&string_table, 0, 0, 0, 0) // the size, set below
	symbols := make([dynamic]Coff_Symbol, 0, symbol_count, context.temp_allocator)
	add_absolute_symbol :: proc(symbols: ^[dynamic]Coff_Symbol, string_table: ^[dynamic]u8, name: string, addr: rawptr) {
		symbol: Coff_Symbol
		(^u32)(&symbol.name[4])^ = u32(len(string_table))
		append(string_table, name)
		append(string_table, 0)
		symbol.value = u32(uintptr(addr))
		symbol.section_number = -1 // IMAGE_SYM_ABSOLUTE
		symbol.storage_class = IMAGE_SYM_CLASS_EXTERNAL
		append(symbols, symbol)
	}
	for name, alias in merged.aliases {
		add_absolute_symbol(&symbols, &string_table, alias, merged.defs[name])
	}
	for name, addr in merged.externals {
		add_absolute_symbol(&symbols, &string_table, name, addr)
	}
	(^u32)(raw_data(string_table[:]))^ = u32(len(string_table))

	out := make([]byte, FILE_HDR_SIZE + symbol_count * COFF_SYMBOL_SIZE + len(string_table), context.temp_allocator)
	file_header := (^Coff_File_Header)(raw_data(out))
	file_header.machine = IMAGE_FILE_MACHINE_AMD64
	file_header.pointer_to_symbol_table = FILE_HDR_SIZE
	file_header.number_of_symbols = u32(symbol_count)
	copy(out[FILE_HDR_SIZE:], slice.to_bytes(symbols[:]))
	copy(out[FILE_HDR_SIZE + symbol_count * COFF_SYMBOL_SIZE:], string_table[:])
	return out
}

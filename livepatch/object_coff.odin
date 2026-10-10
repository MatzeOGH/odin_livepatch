#+build windows amd64
package livepatch

import pe "core:debug/pe"
import "core:slice"
import "core:strings"

OBJECT_EXT :: ".obj"

Loaded_Object :: struct {
	path: string,
	data: []byte,
	view: Coff_View,
	out:  []byte, // the rewritten object
}

parse_object :: proc(path: string, data: []byte) -> (object: Loaded_Object, ok: bool) {
	view := parse_coff(data) or_return
	if view.section_count == 0 {
		return
	}
	return Loaded_Object{path = path, data = data, view = view}, true
}

object_max_image_size :: proc(object: Loaded_Object) -> (size: int) {
	for section_index in 0 ..< object.view.section_count {
		section := coff_section_header(object.data, object.view.section_headers_offset, section_index)
		if !is_discarded_section(section) {
			size += max(int(section.virtual_size), int(section.size_of_raw_data)) + coff_section_align(section)
		}
	}
	return
}

// Skips the auxiliary records.
next_object_symbol :: proc(object: Loaded_Object, cursor: ^int) -> (symbol: Object_Symbol, ok: bool) {
	view := object.view
	coff_sym, symbol_index := next_coff_symbol(object.data, view.symtab_offset, view.symbol_count, cursor) or_return
	symbol.name = coff_symbol_name(coff_sym, object.data, view.strtab_offset)
	symbol.local = coff_sym.storage_class == .STATIC

	def_section := coff_symbol_section(coff_sym)
	if def_section > 0 {
		symbol.provides = coff_sym.storage_class == .EXTERNAL
	} else if def_section == 0 {
		// A weak external defines its name through its default, the tag symbol.
		aux, weak := coff_weak_external_aux(object.data, view.symtab_offset, symbol_index, coff_sym)
		if weak && int(aux.tag_index) < view.symbol_count {
			symbol.provides = true
			def_section = coff_symbol_section(coff_symbol_at(object.data, view.symtab_offset, int(aux.tag_index)))
		} else if coff_sym.storage_class == .EXTERNAL {
			symbol.kind = .Undefined
			return symbol, true
		}
	}
	if def_section <= 0 || def_section > view.section_count {
		return symbol, true // UNDEF with no default, ABS, DEBUG
	}

	section := coff_section_header(object.data, view.section_headers_offset, def_section - 1)
	section_name := object_section_name(section, object.data, view.strtab_offset)
	switch {
	case is_discarded_section(section),
	     coff_symbol_section(coff_sym) > 0 && is_object_local(coff_sym, symbol.name, section_name),
	     strings.has_prefix(symbol.name, ".weak."),
	     section_name == ".tls$":
		symbol.kind = .Skipped
	case section.characteristics & .MEM_EXECUTE != {}:
		symbol.kind = .Code
	case section.characteristics & .MEM_WRITE != {}:
		symbol.kind = .Data
	case:
		symbol.kind = .Skipped
	}
	return symbol, true
}

// Not relevant for windows
Near_References :: struct {}

find_near_references :: proc(objects: []Loaded_Object) -> Near_References {
	return {}
}

needs_near_address :: proc(refs: Near_References, name: string) -> bool {
	return true
}

// A COFF object with the absolute symbols
absolute_symbols_object :: proc(merged: ^Merged) -> []byte {
	cell_count := len(merged.debug_cells)
	symbol_count := len(merged.aliases) + len(merged.call_aliases) + len(merged.externals) + cell_count
	string_table := make([dynamic]u8, context.temp_allocator)
	append(&string_table, 0, 0, 0, 0) // the size, set below
	symbols := make([dynamic]Coff_Symbol, 0, symbol_count, context.temp_allocator)
	add_absolute_symbol :: proc(symbols: ^[dynamic]Coff_Symbol, string_table: ^[dynamic]u8, name: string, addr: rawptr, section := i16le(pe.IMAGE_SYM_ABSOLUTE)) {
		symbol := Coff_Symbol{value = u32le(uintptr(addr)), section_number = section, storage_class = .EXTERNAL}
		(^u32le)(&symbol.name[4])^ = u32le(len(string_table))
		append(string_table, name)
		append(string_table, 0)
		append(symbols, symbol)
	}
	for name, alias in merged.aliases {
		add_absolute_symbol(&symbols, &string_table, alias, merged.defs[name])
	}
	for name, alias in merged.call_aliases {
		add_absolute_symbol(&symbols, &string_table, alias, call_target(merged, name))
	}
	for name, addr in merged.externals {
		add_absolute_symbol(&symbols, &string_table, name, addr)
	}
	// Each cell symbol is in section 1, at the offset of its cell
	cells := make([dynamic]u64le, 0, cell_count, context.temp_allocator)
	for name, addr in merged.debug_cells {
		add_absolute_symbol(&symbols, &string_table, name, rawptr(uintptr(len(cells) * 8)), section = 1)
		append(&cells, u64le(uintptr(addr)))
	}
	(^u32le)(raw_data(string_table[:]))^ = u32le(len(string_table))

	section_count := cell_count > 0 ? 1 : 0
	cells_offset := FILE_HDR_SIZE + section_count * SECTION_HDR_SIZE
	symtab_offset := cells_offset + cell_count * 8
	out := make([]byte, symtab_offset + symbol_count * pe.COFF_SYMBOL_SIZE + len(string_table), context.temp_allocator)
	file_header := (^pe.File_Header)(raw_data(out))
	file_header.machine = .AMD64
	file_header.number_of_sections = u16le(section_count)
	file_header.pointer_to_symbol_table = u32le(symtab_offset)
	file_header.number_of_symbols = u32le(symbol_count)
	if section_count > 0 {
		section := coff_section_header(out, FILE_HDR_SIZE, 0)
		copy(section.name[:], ".rdata")
		section.size_of_raw_data = u32le(cell_count * 8)
		section.pointer_to_raw_data = u32le(cells_offset)
		section.characteristics = .CNT_INITIALIZED_DATA | .MEM_READ | .ALIGN_8BYTES
		copy(out[cells_offset:], slice.to_bytes(cells[:]))
	}
	copy(out[symtab_offset:], slice.to_bytes(symbols[:]))
	copy(out[symtab_offset + symbol_count * pe.COFF_SYMBOL_SIZE:], string_table[:])
	return out
}

startup_initialized_global :: proc(objects: []Loaded_Object, merged: ^Merged) -> string {
	if len(merged.new_globals) == 0 {
		return ""
	}
	Range :: struct {
		section, start, end: int,
	}
	ranges := make([dynamic]Range, context.temp_allocator)
	for &object in objects {
		data, view := object.data, object.view
		clear(&ranges)
		cursor := 0
		for symbol in next_coff_symbol(data, view.symtab_offset, view.symbol_count, &cursor) {
			section := coff_symbol_section(symbol)
			if section > 0 && section <= view.section_count && is_global_init_proc(coff_symbol_name(symbol, data, view.strtab_offset)) {
				size := coff_section_header(data, view.section_headers_offset, section - 1).size_of_raw_data
				append(&ranges, Range{section, int(symbol.value), int(size)})
			}
		}
		if len(ranges) == 0 {
			continue
		}
		cursor = 0
		for symbol in next_coff_symbol(data, view.symtab_offset, view.symbol_count, &cursor) {
			for &r in ranges {
				if coff_symbol_section(symbol) == r.section && int(symbol.value) > r.start {
					r.end = min(r.end, int(symbol.value))
				}
			}
		}
		for r in ranges {
			for reloc in coff_section_relocs(data, view.section_headers_offset, r.section - 1) {
				if site := int(reloc.virtual_address); site < r.start || site >= r.end || int(reloc.symbol_table_index) >= view.symbol_count {
					continue
				}
				name := coff_symbol_name(coff_symbol_at(data, view.symtab_offset, int(reloc.symbol_table_index)), data, view.strtab_offset)
				if name in merged.new_globals {
					return name
				}
			}
		}
	}
	return ""
}

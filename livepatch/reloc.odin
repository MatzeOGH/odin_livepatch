#+build windows amd64
package livepatch

import pe "core:debug/pe"
import "core:mem"
import "core:slice"
import "core:strings"

retarget_object_references :: proc(object: ^Loaded_Object, merged: ^Merged, allocator := context.temp_allocator) -> (out: []byte, failed: string) {
	data := object.data
	view := object.view

	if view.strtab_offset + 4 > len(data) {
		return nil, "<string table>"
	}
	strtab_size := int((^u32)(raw_data(data[view.strtab_offset:]))^)
	if view.strtab_offset + strtab_size != len(data) {
		return nil, "<string table not at end of object>"
	}

	live := make(map[int]uintptr, allocator)
	retarget := make(map[int]u32, allocator) // symbol index -> index of its `lp$N`
	callable := make(map[int]string, allocator) // symbol index -> link name, for a symbol that can get an `lp$cN`
	call_retarget := make(map[int]u32, allocator) // symbol index -> index of its `lp$cN`
	added_syms := make([dynamic]Coff_Symbol, allocator)
	added_strings := make([dynamic]u8, allocator)
	set_long_name :: proc(symbol: ^Coff_Symbol, name: string, added_strings: ^[dynamic]u8, strtab_size: int) {
		symbol.name = {}
		(^u32le)(&symbol.name[4])^ = u32le(strtab_size + len(added_strings))
		append(added_strings, name)
		append(added_strings, 0)
	}
	cursor := 0
	for symbol, symbol_index in next_coff_symbol(data, view.symtab_offset, view.symbol_count, &cursor) {
		name := coff_symbol_name(symbol, data, view.strtab_offset)
		section_number := coff_symbol_section(symbol)
		if section_number == pe.IMAGE_SYM_UNDEFINED {
			if external_address, found := merged.externals[name]; found {
				live[symbol_index] = uintptr(external_address)
			}
		}
		addr := merged.defs[name] or_continue
		if section_number > view.section_count {
			return nil, name
		}
		if section_number > 0 {
			section := coff_section_header(data, view.section_headers_offset, section_number - 1)
			if is_object_local(symbol, name, object_section_name(section, data, view.strtab_offset)) {
				continue
			}
			if section.characteristics & (.MEM_EXECUTE | .LNK_COMDAT) == {} {
				// Data: the definition becomes the undefined `lp$N`.
				live[symbol_index] = uintptr(addr)
				retarget[symbol_index] = u32(symbol_index)
				set_long_name(symbol, alias_in(&merged.aliases, "lp$", name), &added_strings, strtab_size)
				symbol.section_number = pe.IMAGE_SYM_UNDEFINED
				symbol.value = 0
				symbol.storage_class = .EXTERNAL
				continue
			}
		}
		alias_sym: Coff_Symbol
		set_long_name(&alias_sym, alias_in(&merged.aliases, "lp$", name), &added_strings, strtab_size)
		alias_sym.storage_class = .EXTERNAL
		live[symbol_index] = uintptr(addr)
		retarget[symbol_index] = u32(view.symbol_count + len(added_syms))
		append(&added_syms, alias_sym)
		callable[symbol_index] = name
	}

	// Debug records of kept data point at the live storage (see Debug_Types)
	types := Debug_Types{refs = make(map[u32]u32, allocator), records = make([dynamic]u8, allocator), section = -1}
	cells := make(map[int]u32, allocator) // symbol index -> index of its `lp$r<name>`
	for section_index in 0 ..< view.section_count {
		section := coff_section_header(data, view.section_headers_offset, section_index)
		if coff_section_name(section) == ".debug$T" {
			types.section = section_index
			types.next = CV_FIRST_TYPE + u32(cv_type_count(data, section))
		}
	}

	for section_index in 0 ..< view.section_count {
		section := coff_section_header(data, view.section_headers_offset, section_index)
		if coff_section_name(section) == ".drectve" {
			strip_exports(data, section)
		}
		if coff_section_name(section) == ".debug$S" && types.section >= 0 {
			relocs := coff_section_relocs(data, view.section_headers_offset, section_index)
			for reloc_index in kept_data_records(data, section, relocs, live, &types) {
				symbol_index := int(relocs[reloc_index].symbol_table_index)
				cell, found := cells[symbol_index]
				if !found {
					name := strings.concatenate({"lp$r", coff_symbol_name(coff_symbol_at(data, view.symtab_offset, symbol_index), data, view.strtab_offset)}, allocator)
					merged.debug_cells[name] = rawptr(live[symbol_index])
					cell_sym: Coff_Symbol
					set_long_name(&cell_sym, name, &added_strings, strtab_size)
					cell_sym.storage_class = .EXTERNAL
					cell = u32(view.symbol_count + len(added_syms))
					cells[symbol_index] = cell
					append(&added_syms, cell_sym)
				}
				// The SECREL of the offset and the SECTION of the section index
				relocs[reloc_index].symbol_table_index = u32le(cell)
				relocs[reloc_index + 1].symbol_table_index = u32le(cell)
			}
		}
		if is_discarded_section(section) {
			continue
		}
		relocs := coff_section_relocs(data, view.section_headers_offset, section_index)
		raw_offset := int(section.pointer_to_raw_data)
		kept := 0
		for reloc in relocs {
			reloc := reloc
			symbol_index := int(reloc.symbol_table_index)
			site := raw_offset + int(reloc.virtual_address)

			switch {
			case reloc.type == .AMD64_SECREL:
				if symbol_index >= view.symbol_count {
					return nil, "<relocation symbol out of range>"
				}
				symbol := coff_symbol_at(data, view.symtab_offset, symbol_index)
				name := coff_symbol_name(symbol, data, view.strtab_offset)
				tls_target, found := exe_symbol_address(name, merged.keys)
				tls_start, have_tls := tls_template_start()
				tls_offset := i64(uintptr(tls_target)) - i64(tls_start)
				if !found || !have_tls || tls_offset < 0 || tls_offset > i64(max(u32)) || site + 4 > len(data) {
					return nil, name
				}
				(^u32)(raw_data(data[site:]))^ += u32(tls_offset)
				continue // removed

			case reloc.type == .AMD64_ADDR64:
				if target, found := live[symbol_index]; found {
					if site + 8 > len(data) {
						return nil, "<relocation out of bounds>"
					}
					(^u64)(raw_data(data[site:]))^ += u64(target)
					continue // removed
				}

			case reloc.type >= .AMD64_REL32 && reloc.type <= .AMD64_REL32_5:
				is_call := reloc.type == .AMD64_REL32 && section.characteristics & .MEM_EXECUTE != {} && reloc.virtual_address > 0 && (data[site - 1] == 0xE8 || data[site - 1] == 0xE9)
				if name, found := callable[symbol_index]; found && is_call {
					if symbol_index not_in call_retarget {
						call_sym: Coff_Symbol
						set_long_name(&call_sym, alias_in(&merged.call_aliases, "lp$c", name), &added_strings, strtab_size)
						call_sym.storage_class = .EXTERNAL
						call_retarget[symbol_index] = u32(view.symbol_count + len(added_syms))
						append(&added_syms, call_sym)
					}
					reloc.symbol_table_index = u32le(call_retarget[symbol_index])
				} else if alias_index, aliased := retarget[symbol_index]; aliased {
					reloc.symbol_table_index = u32le(alias_index)
				}
			}
			relocs[kept] = reloc
			kept += 1
		}
		set_section_reloc_count(data, view.section_headers_offset, section_index, kept)
	}

	// New symbols go before the string table, a grown .debug$T after it.
	head := view.strtab_offset
	tail := head + len(added_syms) * pe.COFF_SYMBOL_SIZE
	types_offset := mem.align_forward_int(tail + strtab_size + len(added_strings), 4)
	old_types: []byte
	if len(types.records) > 0 {
		section := coff_section_header(data, view.section_headers_offset, types.section)
		old_types = data[int(section.pointer_to_raw_data):][:int(section.size_of_raw_data)]
	}
	out = make([]byte, len(old_types) > 0 ? types_offset + len(old_types) + len(types.records) : tail + strtab_size + len(added_strings), allocator)
	copy(out, data[:head])
	copy(out[head:], slice.to_bytes(added_syms[:]))
	copy(out[tail:], data[view.strtab_offset:])
	copy(out[tail + strtab_size:], added_strings[:])
	(^u32le)(raw_data(out[tail:]))^ = u32le(strtab_size + len(added_strings))
	file_header := (^pe.File_Header)(raw_data(out))
	file_header.number_of_symbols = u32le(view.symbol_count + len(added_syms))
	if len(old_types) > 0 {
		copy(out[types_offset:], old_types)
		copy(out[types_offset + len(old_types):], types.records[:])
		section := coff_section_header(out, view.section_headers_offset, types.section)
		section.pointer_to_raw_data = u32le(types_offset)
		section.size_of_raw_data = u32le(len(old_types) + len(types.records))
	}
	return out, ""
}

// A debug record of kept data becomes a reference through a cell `lp$r<name>` that holds the live address.
CV_FIRST_TYPE :: 0x1000
CV_S_SKIP :: 0x0007
CV_S_LDATA32 :: 0x110C
CV_S_GDATA32 :: 0x110D
CV_S_LTHREAD32 :: 0x1112
CV_S_GTHREAD32 :: 0x1113
CV_LF_POINTER :: 0x1002
// CV_PTR_64 (0x0C), mode CV_PTR_MODE_LVREF (1 << 5), size 8 (8 << 13)
CV_REFERENCE_64 :: 0x0C | 1 << 5 | 8 << 13

Debug_Types :: struct {
	section: int,         // the .debug$T section, or -1
	next:    u32,         // the index of the next new type record
	refs:    map[u32]u32, // type index -> index of its reference type
	records: [dynamic]u8, // the new type records
}

// The number of type records in a .debug$T section, after its 4-byte signature
cv_type_count :: proc(data: []byte, section: ^pe.Section_Header32) -> (count: int) {
	start := int(section.pointer_to_raw_data)
	end := start + int(section.size_of_raw_data)
	if end > len(data) {
		return
	}
	for pos := start + 4; pos + 2 <= end; count += 1 {
		pos += 2 + int((^u16le)(raw_data(data[pos:]))^)
	}
	return
}

// Makes kept data records references and thread-local records S_SKIP. Returns the SECREL index of each data record.
kept_data_records :: proc(data: []byte, section: ^pe.Section_Header32, relocs: []Coff_Reloc, live: map[int]uintptr, types: ^Debug_Types) -> []int {
	found := make([dynamic]int, context.temp_allocator)
	start := int(section.pointer_to_raw_data)
	end := start + int(section.size_of_raw_data)
	for reloc, reloc_index in relocs {
		if reloc.type != .AMD64_SECREL || reloc_index + 1 >= len(relocs) {
			continue
		}
		next := relocs[reloc_index + 1]
		if next.type != .AMD64_SECTION || next.symbol_table_index != reloc.symbol_table_index || next.virtual_address != reloc.virtual_address + 4 {
			continue
		}
		// The record: length (2), kind (2), type index (4), then the offset with this relocation
		offset_at := start + int(reloc.virtual_address)
		if offset_at - 8 < start || offset_at + 6 > end || end > len(data) {
			continue
		}
		kind := (^u16le)(raw_data(data[offset_at - 6:]))
		if kind^ == CV_S_LTHREAD32 || kind^ == CV_S_GTHREAD32 {
			kind^ = CV_S_SKIP
			continue
		}
		if kind^ != CV_S_LDATA32 && kind^ != CV_S_GDATA32 || int(reloc.symbol_table_index) not_in live {
			continue
		}
		type_index := (^u32le)(raw_data(data[offset_at - 4:]))
		ref, made := types.refs[u32(type_index^)]
		if !made {
			ref = types.next
			types.next += 1
			types.refs[u32(type_index^)] = ref
			record := struct #packed {
				length, kind: u16le,
				referent, attributes: u32le,
			}{10, CV_LF_POINTER, type_index^, CV_REFERENCE_64}
			append(&types.records, ..mem.ptr_to_bytes(&record))
		}
		type_index^ = u32le(ref)
		append(&found, reloc_index)
	}
	return found[:]
}

strip_exports :: proc(data: []byte, section: ^pe.Section_Header32) {
	start := int(section.pointer_to_raw_data)
	end := start + int(section.size_of_raw_data)
	if start <= 0 || end > len(data) {
		return
	}
	text := data[start:end]
	for pos := 0; pos < len(text); {
		if text[pos] != '/' && text[pos] != '-' {
			pos += 1
			continue
		}
		if pos + 8 > len(text) || !strings.equal_fold(string(text[pos + 1:pos + 8]), "export:") {
			pos += 1
			continue
		}
		// The directive ends at the first space outside quotes.
		quoted := false
		directive_end := pos
		for directive_end < len(text) && (quoted || (text[directive_end] != ' ' && text[directive_end] != 0)) {
			if text[directive_end] == '"' {
				quoted = !quoted
			}
			text[directive_end] = ' '
			directive_end += 1
		}
		pos = directive_end
	}
}

set_section_reloc_count :: proc(data: []byte, section_headers_offset, section_index, reloc_count: int) {
	section := coff_section_header(data, section_headers_offset, section_index)
	if section.characteristics & .LNK_NRELOC_OVFL != {} && section.number_of_relocations == 0xFFFF {
		placeholder := (^Coff_Reloc)(raw_data(data[int(section.pointer_to_relocations):]))
		placeholder.virtual_address = u32le(reloc_count + 1)
		return
	}
	section.number_of_relocations = u16le(reloc_count)
}

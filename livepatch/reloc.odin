#+build windows amd64
package livepatch

import pe "core:debug/pe"
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
				set_long_name(symbol, alias_for(merged, name), &added_strings, strtab_size)
				symbol.section_number = pe.IMAGE_SYM_UNDEFINED
				symbol.value = 0
				symbol.storage_class = .EXTERNAL
				continue
			}
		}
		alias_sym: Coff_Symbol
		set_long_name(&alias_sym, alias_for(merged, name), &added_strings, strtab_size)
		alias_sym.storage_class = .EXTERNAL
		live[symbol_index] = uintptr(addr)
		retarget[symbol_index] = u32(view.symbol_count + len(added_syms))
		append(&added_syms, alias_sym)
	}

	for section_index in 0 ..< view.section_count {
		section := coff_section_header(data, view.section_headers_offset, section_index)
		if coff_section_name(section) == ".drectve" {
			strip_exports(data, section)
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
				tls_target, found := exe_symbol_address(name)
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
				if alias_index, found := retarget[symbol_index]; found {
					reloc.symbol_table_index = u32le(alias_index)
				}
			}
			relocs[kept] = reloc
			kept += 1
		}
		set_section_reloc_count(data, view.section_headers_offset, section_index, kept)
	}

	// The new symbols go between the symbol table and the string table.
	head := view.strtab_offset
	out = make([]byte, head + len(added_syms) * pe.COFF_SYMBOL_SIZE + strtab_size + len(added_strings), allocator)
	copy(out, data[:head])
	copy(out[head:], slice.to_bytes(added_syms[:]))
	tail := head + len(added_syms) * pe.COFF_SYMBOL_SIZE
	copy(out[tail:], data[view.strtab_offset:])
	copy(out[tail + strtab_size:], added_strings[:])
	(^u32le)(raw_data(out[tail:]))^ = u32le(strtab_size + len(added_strings))
	file_header := (^pe.File_Header)(raw_data(out))
	file_header.number_of_symbols = u32le(view.symbol_count + len(added_syms))
	return out, ""
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

#+build windows amd64
package livepatch

import "core:slice"
import "core:strings"

rewrite_object :: proc(o: ^Loaded_Object, merged: ^Merged, allocator := context.temp_allocator) -> (out: []byte, failed: string) {
	data := o.data
	v := o.view

	if v.strtab_off + 4 > len(data) {
		return nil, "<string table>"
	}
	strtab_size := int((^u32)(raw_data(data[v.strtab_off:]))^)
	if v.strtab_off + strtab_size != len(data) {
		return nil, "<string table not at end of object>"
	}

	live := make(map[int]uintptr, allocator)
	retarget := make(map[int]u32, allocator) // symbol index -> index of its `lp$N`
	new_syms := make([dynamic]Coff_Symbol, allocator)
	new_strs := make([dynamic]u8, allocator)
	add_name :: proc(sym: ^Coff_Symbol, name: string, strs: ^[dynamic]u8, strtab_size: int) {
		sym.name = {}
		(^u32)(&sym.name[4])^ = u32(strtab_size + len(strs))
		append(strs, name)
		append(strs, 0)
	}
	cursor := 0
	for sym, idx in coff_symbols(data, v.sym_off, v.n_syms, &cursor) {
		name := symbol_name(sym, data, v.strtab_off)
		if sym.section_number == 0 {
			if a, found := merged.externals[name]; found {
				live[idx] = uintptr(a)
			}
		}
		addr, found := merged.defs[name]
		if !found {
			continue
		}
		if sym.section_number > 0 {
			sh := section_header(data, v.sec_off, int(sym.section_number) - 1)
			if is_object_local(sym, name, sh) {
				continue
			}
			ch := sh.characteristics
			if (ch & IMAGE_SCN_MEM_EXECUTE) == 0 && (ch & IMAGE_SCN_LNK_COMDAT) == 0 {
				// Data: the definition becomes the undefined `lp$N`.
				live[idx] = uintptr(addr)
				retarget[idx] = u32(idx)
				add_name(sym, alias_for(merged, name), &new_strs, strtab_size)
				sym.section_number = 0
				sym.value = 0
				sym.storage_class = IMAGE_SYM_CLASS_EXTERNAL
				continue
			}
		}
		s: Coff_Symbol
		add_name(&s, alias_for(merged, name), &new_strs, strtab_size)
		s.storage_class = IMAGE_SYM_CLASS_EXTERNAL
		live[idx] = uintptr(addr)
		retarget[idx] = u32(v.n_syms + len(new_syms))
		append(&new_syms, s)
	}

	for si in 0 ..< v.n_sections {
		sh := section_header(data, v.sec_off, si)
		if section_name(sh) == ".drectve" {
			strip_exports(data, sh)
		}
		if is_discarded_section(sh) {
			continue
		}
		relocs := section_relocs(data, v.sec_off, si)
		raw := int(sh.pointer_to_raw_data)
		kept := 0
		for rel in relocs {
			rel := rel
			ty := int(rel.type)
			idx := int(rel.symbol_table_index)
			site := raw + int(rel.virtual_address)

			switch {
			case ty == IMAGE_REL_AMD64_SECREL:
				sym := coff_symbol(data, v.sym_off, idx)
				name := symbol_name(sym, data, v.strtab_off)
				tls_target, found := exe_symbol(name)
				start, have_tls := tls_template_start()
				off := i64(uintptr(tls_target)) - i64(start)
				if !found || !have_tls || off < 0 || off > i64(max(u32)) || site + 4 > len(data) {
					return nil, name
				}
				(^u32)(raw_data(data[site:]))^ += u32(off)
				continue // removed

			case ty == IMAGE_REL_AMD64_ADDR64:
				if target, ok := live[idx]; ok {
					if site + 8 > len(data) {
						return nil, "<relocation out of bounds>"
					}
					(^u64)(raw_data(data[site:]))^ += u64(target)
					continue // removed
				}

			case ty >= IMAGE_REL_AMD64_REL32 && ty <= IMAGE_REL_AMD64_REL32 + 5:
				if n, ok := retarget[idx]; ok {
					rel.symbol_table_index = n
				}
			}
			relocs[kept] = rel
			kept += 1
		}
		set_reloc_count(data, v.sec_off, si, kept)
	}

	// The new symbols go between the symbol table and the string table.
	head := v.strtab_off
	out = make([]byte, head + len(new_syms) * COFF_SYMBOL_SIZE + strtab_size + len(new_strs), allocator)
	copy(out, data[:head])
	copy(out[head:], slice.to_bytes(new_syms[:]))
	tail := head + len(new_syms) * COFF_SYMBOL_SIZE
	copy(out[tail:], data[v.strtab_off:])
	copy(out[tail + strtab_size:], new_strs[:])
	(^u32)(raw_data(out[tail:]))^ = u32(strtab_size + len(new_strs))
	fh := (^Coff_File_Header)(raw_data(out))
	fh.number_of_symbols = u32(v.n_syms + len(new_syms))
	return out, ""
}

strip_exports :: proc(data: []byte, sh: ^Coff_Section_Header) {
	start := int(sh.pointer_to_raw_data)
	end := start + int(sh.size_of_raw_data)
	if start <= 0 || end > len(data) {
		return
	}
	text := data[start:end]
	for i := 0; i < len(text); {
		if text[i] != '/' && text[i] != '-' {
			i += 1
			continue
		}
		if i + 8 > len(text) || !strings.equal_fold(string(text[i + 1:i + 8]), "export:") {
			i += 1
			continue
		}
		// The directive ends at the first space outside quotes.
		quoted := false
		j := i
		for j < len(text) && (quoted || (text[j] != ' ' && text[j] != 0)) {
			if text[j] == '"' {
				quoted = !quoted
			}
			text[j] = ' '
			j += 1
		}
		i = j
	}
}

set_reloc_count :: proc(data: []byte, sec_off, i, n: int) {
	sh := section_header(data, sec_off, i)
	if (sh.characteristics & IMAGE_SCN_LNK_NRELOC_OVFL) != 0 && sh.number_of_relocations == 0xFFFF {
		r0 := (^Coff_Reloc)(raw_data(data[int(sh.pointer_to_relocations):]))
		r0.virtual_address = u32(n + 1)
		return
	}
	sh.number_of_relocations = u16(n)
}

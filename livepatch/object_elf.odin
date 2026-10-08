#+build linux amd64
package livepatch

import "core:encoding/varint"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

OBJECT_EXT :: ".o"

Loaded_Object :: struct {
	path: string,
	data: []byte,
	view: Elf_View,
}

parse_object :: proc(path: string, data: []byte) -> (object: Loaded_Object, ok: bool) {
	view := parse_elf(data) or_return
	if view.header.type != ET_REL || view.symtab == 0 {
		return
	}
	return Loaded_Object{path, data, view}, true
}

object_max_image_size :: proc(object: ^Loaded_Object) -> (size: int) {
	for &section in object.view.sections {
		if section.flags & SHF_ALLOC != 0 {
			size += int(section.size) + max(int(section.addralign), 1)
		}
	}
	return
}

next_object_symbol :: proc(object: ^Loaded_Object, cursor: ^int) -> (symbol: Object_Symbol, ok: bool) {
	cursor^ = max(cursor^, 1) // symbol 0 is the null symbol
	if cursor^ >= len(object.view.syms) {
		return
	}
	elf_sym := &object.view.syms[cursor^]
	cursor^ += 1

	symbol.name = elf_symbol_name(&object.view, elf_sym)
	symbol.local = elf_symbol_binding(elf_sym.info) == STB_LOCAL
	symbol.size = int(elf_sym.size)
	sym_type := elf_symbol_type(elf_sym.info)
	if sym_type == STT_SECTION || sym_type == STT_FILE || symbol.name == "" {
		return symbol, true
	}
	if elf_sym.shndx == SHN_UNDEF {
		// A thread-local reference binds in retarget_object_references, to the exe's TLS block
		if !symbol.local && sym_type != STT_TLS {
			symbol.kind = .Undefined
		}
		return symbol, true
	}
	section_index, defined := elf_symbol_section_index(&object.view, elf_sym)
	if !defined {
		return symbol, true
	}
	symbol.provides = !symbol.local

	section := &object.view.sections[section_index]
	switch {
	case section.flags & SHF_ALLOC == 0,
	     section.flags & SHF_TLS != 0,
	     sym_type == STT_TLS,
	     strings.has_prefix(symbol.name, ".L"):
		symbol.kind = .Skipped
	case section.flags & SHF_EXECINSTR != 0:
		symbol.kind = .Code
	case section_holds_variables(&object.view, section):
		symbol.kind = .Data
	case:
		symbol.kind = .Read_Only
	}
	return symbol, true
}

section_holds_variables :: proc(view: ^Elf_View, section: ^Elf64_Shdr) -> bool {
	if section.flags & SHF_WRITE == 0 || section.flags & SHF_EXECINSTR != 0 {
		return false
	}
	name := elf_section_name(view, section)
	return !strings.has_prefix(name, ".data.rel.ro") && name != ".odinti"
}

// The first global that the patch adds and that a startup procedure sets, or ""
startup_initialized_global :: proc(objects: []Loaded_Object, merged: ^Merged) -> string {
	if len(merged.new_globals) == 0 {
		return ""
	}
	for &object in objects {
		view := &object.view
		for &sym in view.syms {
			if !is_global_init_proc(elf_symbol_name(view, &sym)) {
				continue
			}
			section_index := elf_symbol_section_index(view, &sym) or_continue
			for &rela_section in view.sections {
				if rela_section.type != SHT_RELA || int(rela_section.info) != section_index || int(rela_section.link) != view.symtab {
					continue
				}
				relas := elf_section_relas(object.data, &rela_section) or_continue
				for &rela in relas {
					symbol_index := int(elf_rela_symbol_index(rela.info))
					if rela.offset < sym.value || rela.offset >= sym.value + sym.size || symbol_index >= len(view.syms) {
						continue
					}
					if name := elf_symbol_name(view, &view.syms[symbol_index]); name in merged.new_globals {
						return name
					}
				}
			}
		}
	}
	return ""
}

Near_References :: struct {
	names: map[string]bool, // undefined names that some rel32 reaches
}

find_near_references :: proc(objects: []Loaded_Object) -> (refs: Near_References) {
	refs.names = make(map[string]bool, context.temp_allocator)
	for &object in objects {
		view := &object.view
		for &rela_section in view.sections {
			if rela_section.type != SHT_RELA || int(rela_section.link) != view.symtab {
				continue
			}
			relas := elf_section_relas(object.data, &rela_section) or_continue
			for &rela in relas {
				if !is_rel32_reference(elf_rela_type(rela.info)) {
					continue
				}
				symbol_index := int(elf_rela_symbol_index(rela.info))
				if symbol_index < len(view.syms) && view.syms[symbol_index].shndx == SHN_UNDEF {
					refs.names[elf_symbol_name(view, &view.syms[symbol_index])] = true
				}
			}
		}
	}
	return
}

needs_near_address :: proc(refs: ^Near_References, name: string) -> bool {
	return name in refs.names
}

Elf_Rewrite :: struct {
	object:             ^Loaded_Object,
	merged:             ^Merged,
	added_syms:         [dynamic]Elf64_Sym,
	added_strings:      [dynamic]u8,
	alias_index:        map[string]u32,  // `lp$N`: its symbol index in this object
	symbols_by_section: [][dynamic]int,  // section index: the named symbols that it defines
}

Relocation_Class :: enum {
	Ignored,      // no relocation, or debug info of a thread-local
	Thread_Local, // code that reaches a thread-local
	Other,
}

retarget_object_references :: proc(object: ^Loaded_Object, merged: ^Merged, allocator := context.temp_allocator) -> (out: []byte, failed: string) {
	data := object.data
	view := &object.view
	rewrite := Elf_Rewrite{
		object             = object,
		merged             = merged,
		added_syms         = make([dynamic]Elf64_Sym, allocator),
		added_strings      = make([dynamic]u8, allocator),
		alias_index        = make(map[string]u32, allocator),
		symbols_by_section = make([][dynamic]int, len(view.sections), allocator),
	}
	for &list in rewrite.symbols_by_section {
		list = make([dynamic]int, allocator)
	}
	for &sym, symbol_index in view.syms {
		section_index := elf_symbol_section_index(view, &sym) or_continue
		sym_type := elf_symbol_type(sym.info)
		if sym_type != STT_SECTION && sym_type != STT_FILE && sym.name != 0 {
			append(&rewrite.symbols_by_section[section_index], symbol_index)
		}
	}

	for &rela_section in view.sections {
		if rela_section.type != SHT_RELA {
			continue
		}
		patched_index := int(rela_section.info)
		if int(rela_section.link) != view.symtab || patched_index <= 0 || patched_index >= len(view.sections) {
			continue
		}
		patched_section := &view.sections[patched_index]
		section_bytes := elf_section_bytes(data, patched_section) or_continue
		relas, relas_ok := elf_section_relas(data, &rela_section)
		if !relas_ok {
			return nil, "<relocation table>"
		}
		in_code := patched_section.flags & SHF_EXECINSTR != 0
		allocated := patched_section.flags & SHF_ALLOC != 0

		for &rela, rela_index in relas {
			rela_type := elf_rela_type(rela.info)
			symbol_index := int(elf_rela_symbol_index(rela.info))
			if symbol_index >= len(view.syms) {
				return nil, "<relocation symbol>"
			}
			switch classify_relocation(rela_type) {
			case .Ignored:
				if !allocated && rela_type == R_X86_64_DTPOFF64 {
					hide_debug_thread_local(view, data, section_bytes, relas, int(rela.offset))
				}
			case .Thread_Local:
				if allocated && !rewrite_tls_to_local_exec(&rewrite, section_bytes, relas, rela_index) {
					name := elf_symbol_name(view, &view.syms[symbol_index])
					return nil, name if name != "" else "<thread-local>"
				}
			case .Other:
				target_offset := rela.addend
				if in_code {
					target_offset = reference_target_offset(rela_type, rela.addend, section_bytes, int(rela.offset))
				}
				if key, bound := binding_key(&rewrite, symbol_index, target_offset); bound {
					// A call or a tail jmp goes to the trampoline. A reference to the address stays on the exe entry.
					is_call := in_code && rela_type == R_X86_64_PLT32 && elf_symbol_type(view.syms[symbol_index].info) != STT_SECTION
					alias := alias_in(&merged.call_aliases, "lp$c", key) if is_call else alias_in(&merged.aliases, "lp$", key)
					rela.info = elf_rela_info(alias_symbol_index(&rewrite, alias), rela_type)
				}
			}
		}
	}

	symtab_section := &view.sections[view.symtab]
	strtab_index := int(symtab_section.link)
	symbol_count := len(view.syms) + len(rewrite.added_syms)
	symtab_offset := mem.align_forward_int(len(data), 8)
	strtab_offset := symtab_offset + symbol_count * size_of(Elf64_Sym)
	out = make([]byte, strtab_offset + len(view.strtab) + len(rewrite.added_strings), allocator)
	copy(out, data)
	copy(out[symtab_offset:], slice.to_bytes(view.syms))
	copy(out[symtab_offset + len(view.syms) * size_of(Elf64_Sym):], slice.to_bytes(rewrite.added_syms[:]))
	copy(out[strtab_offset:], view.strtab)
	copy(out[strtab_offset + len(view.strtab):], rewrite.added_strings[:])

	out_sections := ([^]Elf64_Shdr)(raw_data(out[view.header.shoff:]))[:len(view.sections)]
	out_sections[view.symtab].offset = u64(symtab_offset)
	out_sections[view.symtab].size = u64(symbol_count * size_of(Elf64_Sym))
	out_sections[strtab_index].offset = u64(strtab_offset)
	out_sections[strtab_index].size = u64(len(view.strtab) + len(rewrite.added_strings))
	return out, ""
}

binding_key :: proc(rewrite: ^Elf_Rewrite, symbol_index: int, target_offset: i64) -> (key: string, ok: bool) {
	view := &rewrite.object.view
	sym := &view.syms[symbol_index]
	if elf_symbol_type(sym.info) != STT_SECTION {
		name := elf_symbol_name(view, sym)
		if name != "" && name in rewrite.merged.defs {
			return name, true
		}
		return
	}

	section_index := elf_symbol_section_index(view, sym) or_return
	section := &view.sections[section_index]
	if section.flags & (SHF_ALLOC | SHF_TLS) != SHF_ALLOC || !section_holds_variables(view, section) {
		return
	}
	holder_index := symbol_covering_offset(rewrite, section_index, target_offset) or_return
	holder_name := elf_symbol_name(view, &view.syms[holder_index])
	live_address := rewrite.merged.defs[holder_name] or_return
	holder_value := view.syms[holder_index].value
	key = fmt.tprintf("%s\x00%x", holder_name, holder_value)
	if key not_in rewrite.merged.defs {
		rewrite.merged.defs[key] = rawptr(uintptr(live_address) - uintptr(holder_value))
	}
	return key, true
}

symbol_covering_offset :: proc(rewrite: ^Elf_Rewrite, section_index: int, offset: i64) -> (symbol_index: int, ok: bool) {
	for candidate in rewrite.symbols_by_section[section_index] {
		sym := &rewrite.object.view.syms[candidate]
		start := i64(sym.value)
		if offset >= start && offset < start + max(i64(sym.size), 1) {
			return candidate, true
		}
	}
	return
}

alias_symbol_index :: proc(rewrite: ^Elf_Rewrite, alias: string) -> u32 {
	if index, found := rewrite.alias_index[alias]; found {
		return index
	}
	alias_sym := Elf64_Sym{
		name  = u32(len(rewrite.object.view.strtab) + len(rewrite.added_strings)),
		info  = elf_symbol_info(STB_GLOBAL, STT_NOTYPE),
		shndx = SHN_UNDEF,
	}
	append(&rewrite.added_strings, alias)
	append(&rewrite.added_strings, 0)
	index := u32(len(rewrite.object.view.syms) + len(rewrite.added_syms))
	append(&rewrite.added_syms, alias_sym)
	rewrite.alias_index[alias] = index
	return index
}

thread_pointer_offset :: proc(rewrite: ^Elf_Rewrite, symbol_index: int, offset_in_symbol: i64) -> (offset: i32, ok: bool) {
	view := &rewrite.object.view
	sym := &view.syms[symbol_index]
	offset_in_symbol := offset_in_symbol
	if elf_symbol_type(sym.info) == STT_SECTION {
		section_index := elf_symbol_section_index(view, sym) or_return
		holder_index := symbol_covering_offset(rewrite, section_index, offset_in_symbol) or_return
		offset_in_symbol -= i64(view.syms[holder_index].value)
		sym = &view.syms[holder_index]
	}
	symbol_offset := exe_tls_offset(elf_symbol_name(view, sym), rewrite.merged.keys) or_return
	total := symbol_offset + offset_in_symbol
	if total < i64(min(i32)) || total > i64(max(i32)) {
		return
	}
	return i32(total), true
}

absolute_symbols_object :: proc(merged: ^Merged) -> []byte {
	string_table := make([dynamic]u8, context.temp_allocator)
	append(&string_table, "\x00.strtab\x00.symtab\x00")
	symbols := make([dynamic]Elf64_Sym, 0, 1 + len(merged.aliases) + len(merged.call_aliases) + len(merged.externals), context.temp_allocator)
	append(&symbols, Elf64_Sym{})
	add_absolute_symbol :: proc(symbols: ^[dynamic]Elf64_Sym, string_table: ^[dynamic]u8, name: string, addr: rawptr) {
		append(symbols, Elf64_Sym{
			name  = u32(len(string_table)),
			info  = elf_symbol_info(STB_GLOBAL, STT_NOTYPE),
			shndx = SHN_ABS,
			value = u64(uintptr(addr)),
		})
		append(string_table, name)
		append(string_table, 0)
	}
	for key, alias in merged.aliases {
		add_absolute_symbol(&symbols, &string_table, alias, merged.defs[key])
	}
	for name, alias in merged.call_aliases {
		add_absolute_symbol(&symbols, &string_table, alias, call_target(merged, name))
	}
	for name, addr in merged.externals {
		add_absolute_symbol(&symbols, &string_table, name, addr)
	}

	symtab_offset := size_of(Elf64_Ehdr)
	strtab_offset := symtab_offset + len(symbols) * size_of(Elf64_Sym)
	section_headers_offset := mem.align_forward_int(strtab_offset + len(string_table), 8)
	out := make([]byte, section_headers_offset + 3 * size_of(Elf64_Shdr), context.temp_allocator)
	header := (^Elf64_Ehdr)(raw_data(out))
	header.ident = {0x7F, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	header.type = ET_REL
	header.machine = ELF_MACHINE
	header.version = 1
	header.shoff = u64(section_headers_offset)
	header.ehsize = size_of(Elf64_Ehdr)
	header.shentsize = size_of(Elf64_Shdr)
	header.shnum = 3
	header.shstrndx = 1
	copy(out[symtab_offset:], slice.to_bytes(symbols[:]))
	copy(out[strtab_offset:], string_table[:])
	sections := ([^]Elf64_Shdr)(raw_data(out[section_headers_offset:]))[:3]
	sections[1] = {name = 1, type = SHT_STRTAB, offset = u64(strtab_offset), size = u64(len(string_table)), addralign = 1}
	sections[2] = {name = 9, type = SHT_SYMTAB, offset = u64(symtab_offset), size = u64(len(symbols) * size_of(Elf64_Sym)),
	               link = 1, info = 1, addralign = 8, entsize = size_of(Elf64_Sym)}
	return out
}

// Empties the name of the thread-local at `site`, so the debugger uses the exe's (gdb and lldb do not read fs.base).
hide_debug_thread_local :: proc(view: ^Elf_View, data: []byte, info: []byte, relas: []Elf64_Rela, site: int) -> bool {
	DW_AT_NAME :: 0x03
	DW_AT_LOCATION :: 0x02
	DW_AT_STR_OFFSETS_BASE :: 0x72
	DW_FORM_STRP :: 0x0E
	DW_FORM_STRX :: 0x1A
	DW_FORM_STRX1 :: 0x25
	DW_FORM_STRX4 :: 0x28
	DW_FORM_IMPLICIT_CONST :: 0x21

	abbrev, debug_str: []byte
	str_offset_relas: []Elf64_Rela
	debug_str_index := -1
	for &section, section_index in view.sections {
		switch elf_section_name(view, &section) {
		case ".debug_abbrev":           abbrev = elf_section_bytes(data, &section) or_return
		case ".debug_str":              debug_str, debug_str_index = elf_section_bytes(data, &section) or_return, section_index
		case ".rela.debug_str_offsets": str_offset_relas = elf_section_relas(data, &section) or_return
		}
	}

	uleb :: proc(bytes: []byte, pos: ^int) -> (value: int, ok: bool) {
		if pos^ >= len(bytes) {
			return
		}
		decoded, size, err := varint.decode_uleb128_buffer(bytes[pos^:])
		if err != nil {
			return
		}
		pos^ += size
		return int(decoded), true
	}
	// The relocated value of a 4-byte field at `offset`: in an object, the relocation holds it
	relocated :: proc(bytes: []byte, relas: []Elf64_Rela, offset: int) -> (rela: ^Elf64_Rela, value: int) {
		for &r in relas {
			if int(r.offset) == offset {
				return &r, int(r.addend)
			}
		}
		if offset < 0 || offset + 4 > len(bytes) {
			return nil, 0
		}
		return nil, int((^u32le)(raw_data(bytes[offset:]))^)
	}

	// The compile unit that holds the site. DWARF 4 and 5 headers differ in the abbrev offset and length.
	unit, unit_end, abbrev_at, header_size := 0, 0, 0, 0
	for {
		if unit + 12 > len(info) {
			return false
		}
		unit_end = unit + 4 + int((^u32le)(raw_data(info[unit:]))^)
		switch (^u16le)(raw_data(info[unit + 4:]))^ {
		case 4: abbrev_at, header_size = unit + 6, 11
		case 5: abbrev_at, header_size = unit + 8, 12
		case:   return false
		}
		if unit_end > len(info) {
			return false
		}
		if site < unit_end {
			break
		}
		unit = unit_end
	}
	_, abbrev_offset := relocated(info, relas, abbrev_at)

	// The abbreviation codes of the unit: code -> offset of its attribute specifications
	specs := make(map[int]int, context.temp_allocator)
	for pos := abbrev_offset; true; {
		code := uleb(abbrev, &pos) or_return
		if code == 0 {
			break
		}
		uleb(abbrev, &pos) or_return // the tag
		pos += 1 // children
		specs[code] = pos
		for {
			attribute := uleb(abbrev, &pos) or_return
			form := uleb(abbrev, &pos) or_return
			if form == DW_FORM_IMPLICIT_CONST {
				_, size, _ := varint.decode_ileb128_buffer(abbrev[pos:])
				pos += size
			}
			if attribute == 0 && form == 0 {
				break
			}
		}
	}

	// Each entry of the unit: find the one whose location holds the site
	str_offsets_base := 0
	for pos := unit + header_size; pos < unit_end; {
		code := uleb(info, &pos) or_return
		if code == 0 {
			continue
		}
		spec := specs[code] or_return
		name_at, name_form := -1, 0
		for {
			attribute := uleb(abbrev, &spec) or_return
			form := uleb(abbrev, &spec) or_return
			if attribute == 0 && form == 0 {
				break
			}
			if form == DW_FORM_IMPLICIT_CONST {
				_, size, _ := varint.decode_ileb128_buffer(abbrev[spec:])
				spec += size
			}
			start := pos
			pos = dwarf_skip_form(info, pos, form) or_return
			switch {
			case attribute == DW_AT_STR_OFFSETS_BASE:
				_, str_offsets_base = relocated(info, relas, start)
			case attribute == DW_AT_NAME:
				name_at, name_form = start, form
			case attribute == DW_AT_LOCATION && site >= start && site < pos:
				// The entry of the thread-local: the relocation that gives its name gets the NUL at the end
				name_rela: ^Elf64_Rela
				switch name_form {
				case DW_FORM_STRP:
					name_rela, _ = relocated(info, relas, name_at)
				case DW_FORM_STRX, DW_FORM_STRX1 ..= DW_FORM_STRX4:
					index := 0
					if name_form == DW_FORM_STRX {
						uleb_at := name_at
						index = uleb(info, &uleb_at) or_return
					} else {
						for byte_index in 0 ..< name_form - DW_FORM_STRX1 + 1 {
							index |= int(info[name_at + byte_index]) << uint(8 * byte_index)
						}
					}
					name_rela, _ = relocated(nil, str_offset_relas, str_offsets_base + 4 * index)
				}
				if name_rela == nil || name_rela.addend < 0 || int(name_rela.addend) >= len(debug_str) {
					return false
				}
				if elf_symbol_type(view.syms[elf_rela_symbol_index(name_rela.info)].info) != STT_SECTION {
					return false
				}
				// Each reference to the name, also from the .debug_names index, gets the NUL at its end
				name_offset := name_rela.addend
				name_length := i64(len(strings.truncate_to_byte(string(debug_str[name_offset:]), 0)))
				for &section in view.sections {
					if section.type != SHT_RELA || !strings.has_prefix(elf_section_name(view, &section), ".rela.debug") {
						continue
					}
					for &rela in elf_section_relas(data, &section) or_continue {
						sym := &view.syms[elf_rela_symbol_index(rela.info)]
						if rela.addend == name_offset && elf_symbol_type(sym.info) == STT_SECTION && sym.shndx == u16(debug_str_index) {
							rela.addend += name_length
						}
					}
				}
				return true
			}
		}
	}
	return false
}

// The offset after an attribute value of the form `form` at `pos` (DWARF 4 and 5, 32-bit DWARF)
dwarf_skip_form :: proc(info: []byte, pos: int, form: int) -> (next: int, ok: bool) {
	block :: proc(info: []byte, pos: int) -> (int, bool) {
		length, size, err := varint.decode_uleb128_buffer(info[pos:])
		return pos + size + int(length), err == nil
	}
	size := 0
	switch form {
	case 0x19, 0x21: // flag_present, implicit_const
	case 0x0B, 0x0C, 0x11, 0x25, 0x29: size = 1 // data1, flag, ref1, strx1, addrx1
	case 0x05, 0x12, 0x26, 0x2A: size = 2 // data2, ref2, strx2, addrx2
	case 0x27, 0x2B: size = 3 // strx3, addrx3
	case 0x06, 0x0E, 0x10, 0x13, 0x17, 0x1C, 0x1D, 0x1F, 0x28, 0x2C: size = 4 // data4, strp, ref_addr, ref4, sec_offset, ref_sup4, strp_sup, line_strp, strx4, addrx4
	case 0x01, 0x07, 0x14, 0x20, 0x24: size = 8 // addr, data8, ref8, ref_sig8, ref_sup8
	case 0x1E: size = 16 // data16
	case 0x0D, 0x0F, 0x15, 0x1A, 0x1B, 0x22, 0x23: // sdata, udata, ref_udata, strx, addrx, loclistx, rnglistx
		_, leb_size, err := varint.decode_uleb128_buffer(info[pos:])
		if err != nil {
			return
		}
		size = leb_size
	case 0x08: // string
		size = len(strings.truncate_to_byte(string(info[pos:]), 0)) + 1
	case 0x09, 0x18: // block, exprloc
		return block(info, pos)
	case 0x0A: size = 1 + int(info[pos]) // block1
	case 0x03: size = 2 + int((^u16le)(raw_data(info[pos:]))^) // block2
	case 0x04: size = 4 + int((^u32le)(raw_data(info[pos:]))^) // block4
	case:
		return
	}
	return pos + size, pos + size <= len(info)
}

#+build linux amd64
package livepatch

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

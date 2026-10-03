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

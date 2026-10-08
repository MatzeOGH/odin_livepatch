#+build windows amd64
package livepatch

// COFF object parsing. AMD64 only.

import pe "core:debug/pe"
import "core:encoding/base64"
import "core:slice"
import "core:strconv"
import "core:strings"

SECTION_HDR_SIZE :: size_of(pe.Section_Header32)
FILE_HDR_SIZE    :: size_of(pe.File_Header)
RELOC_SIZE       :: size_of(Coff_Reloc)

MAX_NUMBER_OF_SECTIONS16 :: 0xFEFF

Coff_Symbol :: struct #packed {
	name:                  [8]u8,
	value:                 u32le,
	section_number:        i16le,
	type:                  pe.IMAGE_SYM_TYPE,
	storage_class:         pe.IMAGE_SYM_CLASS,
	number_of_aux_symbols: u8,
}

Coff_Reloc :: struct #packed {
	virtual_address:    u32le,
	symbol_table_index: u32le,
	type:               pe.IMAGE_REL,
}

Coff_Aux_Weak_External :: struct #packed {
	tag_index:       u32le,
	characteristics: u32le,
	_unused:         [10]u8,
}

#assert(size_of(Coff_Symbol) == pe.COFF_SYMBOL_SIZE)
#assert(size_of(Coff_Reloc) == 10)
#assert(size_of(Coff_Aux_Weak_External) == pe.COFF_SYMBOL_SIZE)
#assert(SECTION_HDR_SIZE == 40)
#assert(FILE_HDR_SIZE == 20)

Coff_View :: struct {
	section_headers_offset: int,
	symtab_offset:          int,
	strtab_offset:          int,
	section_count:          int,
	symbol_count:           int,
}

coff_section_header :: proc "contextless" (data: []byte, section_headers_offset, section_index: int) -> ^pe.Section_Header32 {
	return (^pe.Section_Header32)(raw_data(data[section_headers_offset + section_index * SECTION_HDR_SIZE:]))
}

coff_symbol_at :: proc "contextless" (data: []byte, symtab_offset, symbol_index: int) -> ^Coff_Symbol {
	return (^Coff_Symbol)(raw_data(data[symtab_offset + symbol_index * pe.COFF_SYMBOL_SIZE:]))
}

next_coff_symbol :: proc "contextless" (data: []byte, symtab_offset, symbol_count: int, cursor: ^int) -> (symbol: ^Coff_Symbol, symbol_index: int, ok: bool) {
	if cursor^ >= symbol_count {
		return
	}
	symbol_index = cursor^
	symbol = coff_symbol_at(data, symtab_offset, symbol_index)
	cursor^ += 1 + int(symbol.number_of_aux_symbols)
	return symbol, symbol_index, true
}

coff_symbol_section :: proc "contextless" (symbol: ^Coff_Symbol) -> int {
	number := u16(symbol.section_number)
	if number <= MAX_NUMBER_OF_SECTIONS16 {
		return int(number)
	}
	return int(symbol.section_number)
}

coff_section_name :: proc "contextless" (section: ^pe.Section_Header32) -> string {
	return strings.truncate_to_byte(string(section.name[:]), 0)
}

object_section_name :: proc(section: ^pe.Section_Header32, data: []byte, strtab_offset: int) -> string {
	name := coff_section_name(section)
	offset: uint
	ok: bool
	if strings.has_prefix(name, "//") {
		ok = true
		for c in transmute([]u8)name[2:] {
			digit := base64.DEC_TABLE[c]
			ok &&= digit >= 0
			offset = offset * 64 + uint(digit)
		}
	} else if strings.has_prefix(name, "/") {
		offset, ok = strconv.parse_uint(name[1:], 10)
	}
	start := strtab_offset + int(offset)
	if !ok || start >= len(data) {
		return name
	}
	return strings.truncate_to_byte(string(data[start:]), 0)
}

// Bits 20-23 hold log2(alignment)+1. Zero means the default of 16.
coff_section_align :: proc "contextless" (section: ^pe.Section_Header32) -> int {
	align_bits := (u32(section.characteristics) & 0x00F00000) >> 20
	if align_bits == 0 {
		return 16
	}
	return 1 << uint(align_bits - 1)
}

coff_section_relocs :: proc "contextless" (data: []byte, section_headers_offset, section_index: int) -> []Coff_Reloc {
	section := coff_section_header(data, section_headers_offset, section_index)
	reloc_count := int(section.number_of_relocations)
	relocs_offset := int(section.pointer_to_relocations)
	first := 0
	if section.characteristics & .LNK_NRELOC_OVFL != {} && reloc_count == 0xFFFF {
		if relocs_offset + RELOC_SIZE > len(data) {
			return {}
		}
		placeholder := (^Coff_Reloc)(raw_data(data[relocs_offset:]))
		reloc_count = int(placeholder.virtual_address) - 1
		first = 1
	}
	start := relocs_offset + first * RELOC_SIZE
	if reloc_count <= 0 || start + reloc_count * RELOC_SIZE > len(data) {
		return {}
	}
	return slice.reinterpret([]Coff_Reloc, data[start:][:reloc_count * RELOC_SIZE])
}

coff_weak_external_aux :: proc "contextless" (data: []byte, symtab_offset, symbol_index: int, symbol: ^Coff_Symbol) -> (aux: ^Coff_Aux_Weak_External, ok: bool) {
	if symbol.storage_class != .WEAK_EXTERNAL || symbol.number_of_aux_symbols < 1 {
		return
	}
	aux_offset := symtab_offset + (symbol_index + 1) * pe.COFF_SYMBOL_SIZE
	if aux_offset + pe.COFF_SYMBOL_SIZE > len(data) {
		return
	}
	return (^Coff_Aux_Weak_External)(raw_data(data[aux_offset:])), true
}

is_object_local :: proc(symbol: ^Coff_Symbol, name: string, section_name: string) -> bool {
	if symbol.storage_class != .STATIC {
		return false
	}
	return name == section_name || strings.has_prefix(name, ".L")
}

// Debug info and linker directives
is_discarded_section :: proc "contextless" (section: ^pe.Section_Header32) -> bool {
	return section.characteristics & (.MEM_DISCARDABLE | .LNK_REMOVE) != {}
}

coff_symbol_name :: proc(symbol: ^Coff_Symbol, data: []byte, strtab_offset: int) -> string {
	if (^u32)(&symbol.name[0])^ == 0 {
		name_offset := int((^u32)(&symbol.name[4])^)
		start := strtab_offset + name_offset
		if start >= len(data) {
			return ""
		}
		return strings.truncate_to_byte(string(data[start:]), 0)
	}
	return strings.truncate_to_byte(string(symbol.name[:]), 0)
}

parse_coff :: proc(data: []byte) -> (view: Coff_View, ok: bool) {
	if len(data) < FILE_HDR_SIZE {
		return
	}
	file_header := (^pe.File_Header)(raw_data(data))

	assert(!(file_header.machine == .UNKNOWN && file_header.number_of_sections == 0xFFFF), "bigobj COFF format is not supported")
	if file_header.machine != .AMD64 {
		return
	}
	section_count := int(file_header.number_of_sections)
	symbol_count := int(file_header.number_of_symbols)
	section_headers_offset := FILE_HDR_SIZE + int(file_header.size_of_optional_header)
	symtab_offset := int(file_header.pointer_to_symbol_table)
	if symtab_offset == 0 || section_count > MAX_NUMBER_OF_SECTIONS16 {
		return
	}
	if section_headers_offset + section_count * SECTION_HDR_SIZE > len(data) {
		return
	}
	strtab_offset := symtab_offset + symbol_count * pe.COFF_SYMBOL_SIZE
	if strtab_offset > len(data) {
		return
	}
	view.section_headers_offset = section_headers_offset
	view.symtab_offset = symtab_offset
	view.section_count = section_count
	view.symbol_count = symbol_count
	view.strtab_offset = strtab_offset
	return view, true
}

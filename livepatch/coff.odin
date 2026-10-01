#+build windows amd64
package livepatch

// COFF object parsing. AMD64 only.

import "core:strings"

COFF_SYMBOL_SIZE :: 18
SECTION_HDR_SIZE :: 40
FILE_HDR_SIZE    :: 20
RELOC_SIZE       :: 10

IMAGE_SYM_CLASS_STATIC        :: 3
IMAGE_SYM_CLASS_EXTERNAL      :: 2
IMAGE_SYM_CLASS_WEAK_EXTERNAL :: 105

IMAGE_FILE_MACHINE_AMD64 :: 0x8664

IMAGE_SCN_MEM_EXECUTE     :: 0x20000000
IMAGE_SCN_MEM_WRITE       :: 0x80000000
IMAGE_SCN_LNK_NRELOC_OVFL :: 0x01000000
IMAGE_SCN_MEM_DISCARDABLE :: 0x02000000
IMAGE_SCN_LNK_REMOVE      :: 0x00000800
IMAGE_SCN_LNK_COMDAT      :: 0x00001000
IMAGE_SCN_ALIGN_MASK      :: 0x00F00000

IMAGE_REL_AMD64_ADDR64   :: 0x01
IMAGE_REL_AMD64_REL32    :: 0x04
IMAGE_REL_AMD64_SECREL   :: 0x0B

Coff_File_Header :: struct #packed {
	machine:                 u16,
	number_of_sections:      u16,
	time_date_stamp:         u32,
	pointer_to_symbol_table: u32,
	number_of_symbols:       u32,
	size_of_optional_header: u16,
	characteristics:         u16,
}

Coff_Section_Header :: struct #packed {
	name:                    [8]u8,
	virtual_size:            u32,
	virtual_address:         u32,
	size_of_raw_data:        u32,
	pointer_to_raw_data:     u32,
	pointer_to_relocations:  u32,
	pointer_to_line_numbers: u32,
	number_of_relocations:   u16,
	number_of_line_numbers:  u16,
	characteristics:         u32,
}

Coff_Symbol :: struct #packed {
	name:                  [8]u8,
	value:                 u32,
	section_number:        i16,
	type:                  u16,
	storage_class:         u8,
	number_of_aux_symbols: u8,
}

Coff_Reloc :: struct #packed {
	virtual_address:    u32,
	symbol_table_index: u32,
	type:               u16,
}

Coff_Aux_Weak_External :: struct #packed {
	tag_index:       u32,
	characteristics: u32,
	_unused:         [10]u8,
}

Coff_View :: struct {
	section_headers_offset: int,
	symtab_offset:          int,
	strtab_offset:          int,
	section_count:          int,
	symbol_count:           int,
}

coff_section_header :: proc  "contextless" (data: []byte, section_headers_offset, section_index: int) -> ^Coff_Section_Header {
	return (^Coff_Section_Header)(raw_data(data[section_headers_offset + section_index * SECTION_HDR_SIZE:]))
}

coff_symbol_at :: proc  "contextless" (data: []byte, symtab_offset, symbol_index: int) -> ^Coff_Symbol {
	return (^Coff_Symbol)(raw_data(data[symtab_offset + symbol_index * COFF_SYMBOL_SIZE:]))
}

// Skips the auxiliary records.
next_coff_symbol :: proc "contextless" (data: []byte, symtab_offset, symbol_count: int, cursor: ^int) -> (symbol: ^Coff_Symbol, symbol_index: int, ok: bool) {
	if cursor^ >= symbol_count {
		return
	}
	symbol_index = cursor^
	symbol = coff_symbol_at(data, symtab_offset, symbol_index)
	cursor^ += 1 + int(symbol.number_of_aux_symbols)
	return symbol, symbol_index, true
}

coff_section_name :: proc "contextless" (section: ^Coff_Section_Header) -> string {
	return strings.truncate_to_byte(string(section.name[:]), 0)
}

// Bits 20-23 hold log2(alignment)+1. Zero means the default of 16.
coff_section_align :: proc "contextless" (section: ^Coff_Section_Header) -> int {
	align_bits := (section.characteristics & IMAGE_SCN_ALIGN_MASK) >> 20
	if align_bits == 0 {
		return 16
	}
	return 1 << uint(align_bits - 1)
}

// With more than 0xFFFF relocations, the header stores 0xFFFF and sets
// IMAGE_SCN_LNK_NRELOC_OVFL. Then the first record is a placeholder, and its
// virtual_address is the true count plus one.
coff_section_relocs :: proc "contextless" (data: []byte, section_headers_offset, section_index: int) -> []Coff_Reloc {
	section := coff_section_header(data, section_headers_offset, section_index)
	reloc_count := int(section.number_of_relocations)
	relocs_offset := int(section.pointer_to_relocations)
	first := 0
	if (section.characteristics & IMAGE_SCN_LNK_NRELOC_OVFL) != 0 && reloc_count == 0xFFFF {
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
	return ([^]Coff_Reloc)(raw_data(data[start:]))[:reloc_count]
}

coff_weak_external_aux :: proc "contextless" (data: []byte, symtab_offset, symbol_index: int, symbol: ^Coff_Symbol) -> (aux: ^Coff_Aux_Weak_External, ok: bool) {
	if symbol.storage_class != IMAGE_SYM_CLASS_WEAK_EXTERNAL || symbol.number_of_aux_symbols < 1 {
		return
	}
	aux_offset := symtab_offset + (symbol_index + 1) * COFF_SYMBOL_SIZE
	if aux_offset + COFF_SYMBOL_SIZE > len(data) {
		return
	}
	return (^Coff_Aux_Weak_External)(raw_data(data[aux_offset:])), true
}

is_object_local :: proc (symbol: ^Coff_Symbol, name: string, section: ^Coff_Section_Header) -> bool {
	if symbol.storage_class != IMAGE_SYM_CLASS_STATIC {
		return false
	}
	return name == coff_section_name(section) || strings.has_prefix(name, ".L")
}

// Debug info and linker directives
is_discarded_section :: proc "contextless" (section: ^Coff_Section_Header) -> bool {
	return (section.characteristics & (IMAGE_SCN_MEM_DISCARDABLE | IMAGE_SCN_LNK_REMOVE)) != 0
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
	file_header := (^Coff_File_Header)(raw_data(data))
	if file_header.machine != IMAGE_FILE_MACHINE_AMD64 {
		return
	}
	section_count := int(file_header.number_of_sections)
	symbol_count := int(file_header.number_of_symbols)
	section_headers_offset := FILE_HDR_SIZE + int(file_header.size_of_optional_header)
	symtab_offset := int(file_header.pointer_to_symbol_table)
	if symtab_offset == 0 {
		return
	}
	if section_headers_offset + section_count * SECTION_HDR_SIZE > len(data) {
		return
	}
	strtab_offset := symtab_offset + symbol_count * COFF_SYMBOL_SIZE
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

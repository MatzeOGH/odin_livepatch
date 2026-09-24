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
	sec_off:    int,
	sym_off:    int,
	strtab_off: int,
	n_sections: int,
	n_syms:     int,
}

section_header :: proc  "contextless" (data: []byte, sec_off, i: int) -> ^Coff_Section_Header {
	return (^Coff_Section_Header)(raw_data(data[sec_off + i * SECTION_HDR_SIZE:]))
}

coff_symbol :: proc  "contextless" (data: []byte, sym_off, i: int) -> ^Coff_Symbol {
	return (^Coff_Symbol)(raw_data(data[sym_off + i * COFF_SYMBOL_SIZE:]))
}

// Skips the auxiliary records.
coff_symbols :: proc "contextless" (data: []byte, sym_off, n_syms: int, cursor: ^int) -> (sym: ^Coff_Symbol, idx: int, ok: bool) {
	if cursor^ >= n_syms {
		return
	}
	idx = cursor^
	sym = coff_symbol(data, sym_off, idx)
	cursor^ += 1 + int(sym.number_of_aux_symbols)
	return sym, idx, true
}

section_name :: proc "contextless" (sh: ^Coff_Section_Header) -> string {
	return strings.truncate_to_byte(string(sh.name[:]), 0)
}

// Bits 20-23 hold log2(alignment)+1. Zero means the default of 16.
section_align :: proc "contextless" (sh: ^Coff_Section_Header) -> int {
	a := (sh.characteristics & IMAGE_SCN_ALIGN_MASK) >> 20
	if a == 0 {
		return 16
	}
	return 1 << uint(a - 1)
}

// With more than 0xFFFF relocations, the header stores 0xFFFF and sets
// IMAGE_SCN_LNK_NRELOC_OVFL. Then the first record is a placeholder, and its
// virtual_address is the true count plus one.
section_relocs :: proc "contextless" (data: []byte, sec_off, i: int) -> []Coff_Reloc {
	sh := section_header(data, sec_off, i)
	nreloc := int(sh.number_of_relocations)
	roff := int(sh.pointer_to_relocations)
	first := 0
	if (sh.characteristics & IMAGE_SCN_LNK_NRELOC_OVFL) != 0 && nreloc == 0xFFFF {
		if roff + RELOC_SIZE > len(data) {
			return {}
		}
		r0 := (^Coff_Reloc)(raw_data(data[roff:]))
		nreloc = int(r0.virtual_address) - 1
		first = 1
	}
	start := roff + first * RELOC_SIZE
	if nreloc <= 0 || start + nreloc * RELOC_SIZE > len(data) {
		return {}
	}
	return ([^]Coff_Reloc)(raw_data(data[start:]))[:nreloc]
}

weak_external_aux :: proc "contextless" (data: []byte, sym_off, idx: int, sym: ^Coff_Symbol) -> (aux: ^Coff_Aux_Weak_External, ok: bool) {
	if sym.storage_class != IMAGE_SYM_CLASS_WEAK_EXTERNAL || sym.number_of_aux_symbols < 1 {
		return
	}
	off := sym_off + (idx + 1) * COFF_SYMBOL_SIZE
	if off + COFF_SYMBOL_SIZE > len(data) {
		return
	}
	return (^Coff_Aux_Weak_External)(raw_data(data[off:])), true
}

is_object_local :: proc (sym: ^Coff_Symbol, name: string, sh: ^Coff_Section_Header) -> bool {
	if sym.storage_class != IMAGE_SYM_CLASS_STATIC {
		return false
	}
	return name == section_name(sh) || strings.has_prefix(name, ".L")
}

// Debug info and linker directives
is_discarded_section :: proc "contextless" (sh: ^Coff_Section_Header) -> bool {
	return (sh.characteristics & (IMAGE_SCN_MEM_DISCARDABLE | IMAGE_SCN_LNK_REMOVE)) != 0
}

symbol_name :: proc(sym: ^Coff_Symbol, data: []byte, strtab_off: int) -> string {
	if (^u32)(&sym.name[0])^ == 0 {
		off := int((^u32)(&sym.name[4])^)
		start := strtab_off + off
		if start >= len(data) {
			return ""
		}
		return strings.truncate_to_byte(string(data[start:]), 0)
	}
	return strings.truncate_to_byte(string(sym.name[:]), 0)
}

coff_parse :: proc(data: []byte) -> (v: Coff_View, ok: bool) {
	if len(data) < FILE_HDR_SIZE {
		return
	}
	fh := (^Coff_File_Header)(raw_data(data))
	if fh.machine != IMAGE_FILE_MACHINE_AMD64 {
		return
	}
	n_sections := int(fh.number_of_sections)
	n_syms := int(fh.number_of_symbols)
	sec_off := FILE_HDR_SIZE + int(fh.size_of_optional_header)
	sym_off := int(fh.pointer_to_symbol_table)
	if sym_off == 0 {
		return
	}
	if sec_off + n_sections * SECTION_HDR_SIZE > len(data) {
		return
	}
	strtab_off := sym_off + n_syms * COFF_SYMBOL_SIZE
	if strtab_off > len(data) {
		return
	}
	v.sec_off = sec_off
	v.sym_off = sym_off
	v.n_sections = n_sections
	v.n_syms = n_syms
	v.strtab_off = strtab_off
	return v, true
}

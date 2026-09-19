#+build windows
package livepatch

// COFF object parsing: file header, section headers, symbol table (with auxiliary
// records), string table, and relocations. AMD64 only.


import "core:strings"

// COFF record sizes (bytes)
COFF_SYMBOL_SIZE :: 18
SECTION_HDR_SIZE :: 40
FILE_HDR_SIZE    :: 20
RELOC_SIZE       :: 10

IMAGE_SYM_CLASS_STATIC        :: 3
IMAGE_SYM_CLASS_EXTERNAL      :: 2
IMAGE_SYM_CLASS_WEAK_EXTERNAL :: 105

// machine, section-characteristic and AMD64 relocation constants
IMAGE_FILE_MACHINE_AMD64 :: 0x8664

IMAGE_SCN_MEM_EXECUTE     :: 0x20000000
IMAGE_SCN_MEM_WRITE       :: 0x80000000
IMAGE_SCN_LNK_NRELOC_OVFL :: 0x01000000
IMAGE_SCN_MEM_DISCARDABLE :: 0x02000000
IMAGE_SCN_LNK_REMOVE      :: 0x00000800
IMAGE_SCN_ALIGN_MASK      :: 0x00F00000

IMAGE_REL_AMD64_ADDR64   :: 0x01
IMAGE_REL_AMD64_ADDR32NB :: 0x03
IMAGE_REL_AMD64_REL32    :: 0x04
IMAGE_REL_AMD64_SECREL   :: 0x0B

Coff_File_Header :: struct #packed {
	machine:                 u16le,
	number_of_sections:      u16le,
	time_date_stamp:         u32le,
	pointer_to_symbol_table: u32le,
	number_of_symbols:       u32le,
	size_of_optional_header: u16le,
	characteristics:         u16le,
}

Coff_Section_Header :: struct #packed {
	name:                    [8]u8,
	virtual_size:            u32le,
	virtual_address:         u32le,
	size_of_raw_data:        u32le,
	pointer_to_raw_data:     u32le,
	pointer_to_relocations:  u32le,
	pointer_to_line_numbers: u32le,
	number_of_relocations:   u16le,
	number_of_line_numbers:  u16le,
	characteristics:         u32le,
}

Coff_Symbol :: struct #packed {
	name:                  [8]u8,
	value:                 u32le,
	section_number:        i16le,
	type:                  u16le,
	storage_class:         u8,
	number_of_aux_symbols: u8,
}

Coff_Reloc :: struct #packed {
	virtual_address:    u32le,
	symbol_table_index: u32le,
	type:               u16le,
}

// `tag_index` is the symbol-table index of the default definition, which the binder
// follows. Odin emits weak externals (runtime::type_table, the startup/cleanup markers).
Coff_Aux_Weak_External :: struct #packed {
	tag_index:       u32le,
	characteristics: u32le,
	_unused:         [10]u8,
}

Coff_View :: struct {
	data:       []byte,
	sec_off:    int, // start of the section table
	sym_off:    int, // start of the symbol table
	strtab_off: int, // start of the string table
	n_sections: int,
	n_syms:     int,
}

section_header :: proc  "contextless" (data: []byte, sec_off, i: int) -> ^Coff_Section_Header {
	return (^Coff_Section_Header)(raw_data(data[sec_off + i * SECTION_HDR_SIZE:]))
}

coff_symbol :: proc  "contextless" (data: []byte, sym_off, i: int) -> ^Coff_Symbol {
	return (^Coff_Symbol)(raw_data(data[sym_off + i * COFF_SYMBOL_SIZE:]))
}

// Iterates the symbol table, skipping each symbol's auxiliary records.
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

// The required alignment of a section, in bytes. The characteristics field holds
// log2(alignment)+1 in bits 20-23; a zero field means the COFF default of 16.
section_align :: proc "contextless" (sh: ^Coff_Section_Header) -> int {
	a := (u32(sh.characteristics) & IMAGE_SCN_ALIGN_MASK) >> 20
	if a == 0 {
		return 16
	}
	return 1 << uint(a - 1)
}

// The relocations of the i-th section as a view into the object bytes. Returns an empty
// slice if the range would fall outside the file.
//
// A section with more than 0xFFFF relocations sets IMAGE_SCN_LNK_NRELOC_OVFL and stores
// 0xFFFF in the header. The true count is the first (placeholder) record's
// virtual_address minus one, and the real records start one entry later.
section_relocs :: proc "contextless" (data: []byte, sec_off, i: int) -> []Coff_Reloc {
	sh := section_header(data, sec_off, i)
	nreloc := int(sh.number_of_relocations)
	roff := int(sh.pointer_to_relocations)
	first := 0
	if (u32(sh.characteristics) & IMAGE_SCN_LNK_NRELOC_OVFL) != 0 && nreloc == 0xFFFF {
		if roff < 0 || roff + RELOC_SIZE > len(data) {
			return {}
		}
		r0 := (^Coff_Reloc)(raw_data(data[roff:]))
		nreloc = int(r0.virtual_address) - 1
		first = 1
	}
	start := roff + first * RELOC_SIZE
	if nreloc <= 0 || start < 0 || start + nreloc * RELOC_SIZE > len(data) {
		return {}
	}
	return ([^]Coff_Reloc)(raw_data(data[start:]))[:nreloc]
}

// The auxiliary record after the weak external at `idx`. `ok` is false for any other
// symbol, or if the record would fall outside the file.
weak_external_aux :: proc "contextless" (data: []byte, sym_off, idx: int, sym: ^Coff_Symbol) -> (aux: ^Coff_Aux_Weak_External, ok: bool) {
	if sym.storage_class != IMAGE_SYM_CLASS_WEAK_EXTERNAL || sym.number_of_aux_symbols < 1 {
		return
	}
	off := sym_off + (idx + 1) * COFF_SYMBOL_SIZE
	if off < 0 || off + COFF_SYMBOL_SIZE > len(data) {
		return
	}
	return (^Coff_Aux_Weak_External)(raw_data(data[off:])), true
}

// Reports whether a defined symbol must resolve within its own object, not through the
// merged map. A section symbol or `.L` temporary shares a name across objects, so merging
// it would cross-bind. STATIC alone is not enough: file-local and @static names are STATIC
// but name the same entity everywhere, so they must keep merging.
is_object_local :: proc(sym: ^Coff_Symbol, name: string, sh: ^Coff_Section_Header) -> bool {
	if sym.storage_class != IMAGE_SYM_CLASS_STATIC {
		return false
	}
	return name == section_name(sh) || strings.has_prefix(name, ".L")
}

// Reports whether a section is dropped at link time: debug info and linker directives.
// Mapping them wastes scarce near-exe address space and applies pointless relocations.
is_discarded_section :: proc "contextless" (sh: ^Coff_Section_Header) -> bool {
	return (u32(sh.characteristics) & (IMAGE_SCN_MEM_DISCARDABLE | IMAGE_SCN_LNK_REMOVE)) != 0
}

// A symbol's name, following the string-table indirection for long names.
symbol_name :: proc(sym: ^Coff_Symbol, data: []byte, strtab_off: int) -> string {
	// First 4 bytes of 0 means the name lives in the string table.
	if (^u32le)(&sym.name[0])^ == 0 {
		off := int((^u32le)(&sym.name[4])^)
		start := strtab_off + off
		if start < 0 || start >= len(data) {
			return "" // a corrupt offset past the buffer: do not read out of bounds
		}

		return strings.truncate_to_byte(string(data[start:]), 0)
	}

	return strings.truncate_to_byte(string(sym.name[:]), 0)
}

// Parses an AMD64 COFF object and returns a view into its tables. `ok` is false for an
// unsupported or invalid object (a bigobj file fails the AMD64 check: its machine field
// is zero, and Odin never emits bigobj). A successful parse guarantees that iterating
// the section and symbol tables stays in bounds.
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
	if n_sections < 0 || n_syms < 0 || sec_off < 0 || sym_off <= 0 {
		return
	}
	// The section and symbol tables must lie within the file, so iterating never reads
	// past the end.
	if sec_off + n_sections * SECTION_HDR_SIZE > len(data) {
		return
	}
	strtab_off := sym_off + n_syms * COFF_SYMBOL_SIZE
	if strtab_off < sym_off || strtab_off > len(data) {
		return
	}
	v.data = data
	v.sec_off = sec_off
	v.sym_off = sym_off
	v.n_sections = n_sections
	v.n_syms = n_syms
	v.strtab_off = strtab_off
	return v, true
}

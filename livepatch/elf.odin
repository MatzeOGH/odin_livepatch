#+build linux amd64
package livepatch

import "core:strings"

Elf64_Ehdr :: struct #packed {
	ident:     [16]u8,
	type:      u16,
	machine:   u16,
	version:   u32,
	entry:     u64,
	phoff:     u64,
	shoff:     u64,
	flags:     u32,
	ehsize:    u16,
	phentsize: u16,
	phnum:     u16,
	shentsize: u16,
	shnum:     u16,
	shstrndx:  u16,
}

Elf64_Shdr :: struct #packed {
	name:      u32,
	type:      u32,
	flags:     u64,
	addr:      u64,
	offset:    u64,
	size:      u64,
	link:      u32,
	info:      u32,
	addralign: u64,
	entsize:   u64,
}

Elf64_Phdr :: struct #packed {
	type:   u32,
	flags:  u32,
	offset: u64,
	vaddr:  u64,
	paddr:  u64,
	filesz: u64,
	memsz:  u64,
	align:  u64,
}

Elf64_Sym :: struct #packed {
	name:  u32,
	info:  u8,
	other: u8,
	shndx: u16,
	value: u64,
	size:  u64,
}

Elf64_Rela :: struct #packed {
	offset: u64,
	info:   u64,
	addend: i64,
}

ET_REL  :: 1
ET_EXEC :: 2
ET_DYN  :: 3

EM_X86_64 :: 62
ELF_MACHINE :: EM_X86_64

SHT_PROGBITS :: 1
SHT_SYMTAB   :: 2
SHT_STRTAB   :: 3
SHT_RELA     :: 4
SHT_NOBITS   :: 8

SHF_WRITE     :: 0x1
SHF_ALLOC     :: 0x2
SHF_EXECINSTR :: 0x4
SHF_TLS       :: 0x400

SHN_UNDEF  :: 0
SHN_ABS    :: 0xFFF1
SHN_COMMON :: 0xFFF2
SHN_XINDEX :: 0xFFFF

STB_LOCAL  :: 0
STB_GLOBAL :: 1
STB_WEAK   :: 2

STT_NOTYPE  :: 0
STT_OBJECT  :: 1
STT_FUNC    :: 2
STT_SECTION :: 3
STT_FILE    :: 4
STT_TLS     :: 6

PT_LOAD :: 1
PT_TLS  :: 7

PF_X :: 0x1
PF_W :: 0x2
PF_R :: 0x4

R_X86_64_NONE          :: 0
R_X86_64_64            :: 1
R_X86_64_PC32          :: 2
R_X86_64_GOT32         :: 3
R_X86_64_PLT32         :: 4
R_X86_64_GOTPCREL      :: 9
R_X86_64_32            :: 10
R_X86_64_32S           :: 11
R_X86_64_DTPMOD64      :: 16
R_X86_64_DTPOFF64      :: 17
R_X86_64_TPOFF64       :: 18
R_X86_64_TLSGD         :: 19
R_X86_64_TLSLD         :: 20
R_X86_64_DTPOFF32      :: 21
R_X86_64_GOTTPOFF      :: 22
R_X86_64_TPOFF32       :: 23
R_X86_64_PC64          :: 24
R_X86_64_GOTPCRELX     :: 41
R_X86_64_REX_GOTPCRELX :: 42

// ELF64_ST_BIND, ELF64_ST_TYPE, ELF64_ST_INFO, ELF64_R_SYM, ELF64_R_TYPE and ELF64_R_INFO of the spec
elf_symbol_binding    :: #force_inline proc "contextless" (info: u8) -> u8 { return info >> 4 }
elf_symbol_type       :: #force_inline proc "contextless" (info: u8) -> u8 { return info & 0xF }
elf_symbol_info       :: #force_inline proc "contextless" (bind, type: u8) -> u8 { return bind << 4 | type & 0xF }
elf_rela_symbol_index :: #force_inline proc "contextless" (info: u64) -> u32 { return u32(info >> 32) }
elf_rela_type         :: #force_inline proc "contextless" (info: u64) -> u32 { return u32(info) }
elf_rela_info         :: #force_inline proc "contextless" (sym, type: u32) -> u64 { return u64(sym) << 32 | u64(type) }

Elf_View :: struct {
	header:   ^Elf64_Ehdr,
	sections: []Elf64_Shdr,
	segments: []Elf64_Phdr,
	shstrtab: []u8,
	symtab:   int, // index of the .symtab section, 0 if none
	syms:     []Elf64_Sym,
	strtab:   []u8, // the names of syms
}

parse_elf :: proc(data: []byte) -> (view: Elf_View, ok: bool) {
	if len(data) < size_of(Elf64_Ehdr) {
		return
	}
	header := (^Elf64_Ehdr)(raw_data(data))
	if string(header.ident[:4]) != "\x7fELF" || header.ident[4] != 2 || header.ident[5] != 1 || header.machine != ELF_MACHINE {
		return // not ELF64, little endian, for this CPU
	}
	view.header = header
	if header.shnum == 0 || int(header.shentsize) != size_of(Elf64_Shdr) || header.shstrndx == SHN_XINDEX {
		return
	}
	section_headers_offset := int(header.shoff)
	if section_headers_offset <= 0 || section_headers_offset + int(header.shnum) * size_of(Elf64_Shdr) > len(data) {
		return
	}
	view.sections = ([^]Elf64_Shdr)(raw_data(data[section_headers_offset:]))[:header.shnum]
	if header.phnum > 0 {
		program_headers_offset := int(header.phoff)
		if int(header.phentsize) != size_of(Elf64_Phdr) || program_headers_offset + int(header.phnum) * size_of(Elf64_Phdr) > len(data) {
			return
		}
		view.segments = ([^]Elf64_Phdr)(raw_data(data[program_headers_offset:]))[:header.phnum]
	}
	view.shstrtab = elf_section_bytes(data, &view.sections[header.shstrndx]) or_return
	for &section, section_index in view.sections {
		if section.type == SHT_SYMTAB {
			if int(section.link) >= len(view.sections) || section.entsize != size_of(Elf64_Sym) {
				return
			}
			symtab_bytes := elf_section_bytes(data, &section) or_return
			view.symtab = section_index
			view.syms = ([^]Elf64_Sym)(raw_data(symtab_bytes))[:len(symtab_bytes) / size_of(Elf64_Sym)]
			view.strtab = elf_section_bytes(data, &view.sections[section.link]) or_return
			break
		}
	}
	return view, true
}

elf_section_bytes :: proc "contextless" (data: []byte, section: ^Elf64_Shdr) -> (bytes: []byte, ok: bool) {
	if section.type == SHT_NOBITS {
		return {}, true
	}
	start, size := int(section.offset), int(section.size)
	if start < 0 || size < 0 || start + size > len(data) {
		return
	}
	return data[start:][:size], true
}

// The relocations of an SHT_RELA section
elf_section_relas :: proc "contextless" (data: []byte, section: ^Elf64_Shdr) -> (relas: []Elf64_Rela, ok: bool) {
	bytes := elf_section_bytes(data, section) or_return
	if len(bytes) % size_of(Elf64_Rela) != 0 {
		return
	}
	return ([^]Elf64_Rela)(raw_data(bytes))[:len(bytes) / size_of(Elf64_Rela)], true
}

elf_string_at :: proc "contextless" (table: []u8, offset: u32) -> string {
	if int(offset) >= len(table) {
		return ""
	}
	return strings.truncate_to_byte(string(table[offset:]), 0)
}

elf_section_name :: proc "contextless" (view: ^Elf_View, section: ^Elf64_Shdr) -> string {
	return elf_string_at(view.shstrtab, section.name)
}

elf_symbol_name :: proc "contextless" (view: ^Elf_View, sym: ^Elf64_Sym) -> string {
	return elf_string_at(view.strtab, sym.name)
}

// The index of the section that defines sym. Not ok for undefined, absolute and common symbols
elf_symbol_section_index :: proc "contextless" (view: ^Elf_View, sym: ^Elf64_Sym) -> (section_index: int, ok: bool) {
	if sym.shndx == SHN_UNDEF || sym.shndx >= 0xFF00 || int(sym.shndx) >= len(view.sections) {
		return
	}
	return int(sym.shndx), true
}

Elf_Symbols :: struct {
	symbols: map[string]uintptr, // stable key (data_key) -> live address
	starts:  [dynamic]uintptr,   // live address of every symbol
	tls:     map[string]uintptr, // stable key (data_key) -> offset in the TLS block, for STT_TLS
}

// With `stable_keys`, statics are indexed by data_key, for lookups from a later build; without,
// by their full link name, for lookups from the same build.
read_elf_symbols :: proc(view: ^Elf_View, bias: uintptr, allocator := context.allocator, stable_keys := true) -> (out: Elf_Symbols) {
	out.symbols = make(map[string]uintptr, allocator)
	out.starts = make([dynamic]uintptr, allocator)
	out.tls = make(map[string]uintptr, allocator)

	keys: Static_Keys
	if stable_keys {
		names := make([dynamic]string, context.temp_allocator)
		for &sym in view.syms {
			append(&names, elf_symbol_name(view, &sym))
		}
		keys = static_keys_make(names[:])
	}

	ambiguous := make(map[string]bool, context.temp_allocator)
	for &sym in view.syms {
		section_index := elf_symbol_section_index(view, &sym) or_continue
		if view.sections[section_index].flags & SHF_ALLOC == 0 {
			// Not in memory
			continue
		}
		sym_type := elf_symbol_type(sym.info)
		if sym_type == STT_SECTION || sym_type == STT_FILE {
			continue
		}
		name := elf_symbol_name(view, &sym)
		if name == "" {
			continue
		}
		key := data_key(keys, name)
		if sym_type == STT_TLS {
			index_add(&out.tls, &ambiguous, key, uintptr(sym.value), allocator)
			continue
		}
		live_address := bias + uintptr(sym.value)
		append(&out.starts, live_address)
		index_add(&out.symbols, &ambiguous, key, live_address, allocator)
	}
	return
}

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

elf_st_bind :: #force_inline proc "contextless" (info: u8) -> u8 { return info >> 4 }
elf_st_type :: #force_inline proc "contextless" (info: u8) -> u8 { return info & 0xF }
elf_st_info :: #force_inline proc "contextless" (bind, type: u8) -> u8 { return bind << 4 | type & 0xF }
elf_r_sym   :: #force_inline proc "contextless" (info: u64) -> u32 { return u32(info >> 32) }
elf_r_type  :: #force_inline proc "contextless" (info: u64) -> u32 { return u32(info) }
elf_r_info  :: #force_inline proc "contextless" (sym, type: u32) -> u64 { return u64(sym) << 32 | u64(type) }

Elf_View :: struct {
	header:   ^Elf64_Ehdr,
	sections: []Elf64_Shdr,
	segments: []Elf64_Phdr,
	shstrtab: []u8,
	symtab:   int, // index of the .symtab section, 0 if none
	syms:     []Elf64_Sym,
	strtab:   []u8, // the names of syms
}

elf_parse :: proc(data: []byte) -> (v: Elf_View, ok: bool) {
	if len(data) < size_of(Elf64_Ehdr) {
		return
	}
	h := (^Elf64_Ehdr)(raw_data(data))
	if string(h.ident[:4]) != "\x7fELF" || h.ident[4] != 2 || h.ident[5] != 1 || h.machine != EM_X86_64 {
		return // not ELF64, little endian, x86-64
	}
	v.header = h
	if h.shnum == 0 || int(h.shentsize) != size_of(Elf64_Shdr) || h.shstrndx == SHN_XINDEX {
		return
	}
	shoff := int(h.shoff)
	if shoff <= 0 || shoff + int(h.shnum) * size_of(Elf64_Shdr) > len(data) {
		return
	}
	v.sections = ([^]Elf64_Shdr)(raw_data(data[shoff:]))[:h.shnum]
	if h.phnum > 0 {
		phoff := int(h.phoff)
		if int(h.phentsize) != size_of(Elf64_Phdr) || phoff + int(h.phnum) * size_of(Elf64_Phdr) > len(data) {
			return
		}
		v.segments = ([^]Elf64_Phdr)(raw_data(data[phoff:]))[:h.phnum]
	}
	v.shstrtab = elf_section_bytes(data, &v.sections[h.shstrndx]) or_return
	for &sh, i in v.sections {
		if sh.type == SHT_SYMTAB {
			if int(sh.link) >= len(v.sections) || sh.entsize != size_of(Elf64_Sym) {
				return
			}
			bytes := elf_section_bytes(data, &sh) or_return
			v.symtab = i
			v.syms = ([^]Elf64_Sym)(raw_data(bytes))[:len(bytes) / size_of(Elf64_Sym)]
			v.strtab = elf_section_bytes(data, &v.sections[sh.link]) or_return
			break
		}
	}
	return v, true
}

// The file bytes of a section
elf_section_bytes :: proc "contextless" (data: []byte, sh: ^Elf64_Shdr) -> (bytes: []byte, ok: bool) {
	if sh.type == SHT_NOBITS {
		return {}, true
	}
	start, size := int(sh.offset), int(sh.size)
	if start < 0 || size < 0 || start + size > len(data) {
		return
	}
	return data[start:][:size], true
}

elf_string :: proc "contextless" (table: []u8, off: u32) -> string {
	if int(off) >= len(table) {
		return ""
	}
	return strings.truncate_to_byte(string(table[off:]), 0)
}

elf_section_name :: proc "contextless" (view: ^Elf_View, sh: ^Elf64_Shdr) -> string {
	return elf_string(view.shstrtab, sh.name)
}

elf_symbol_name :: proc "contextless" (view: ^Elf_View, sym: ^Elf64_Sym) -> string {
	return elf_string(view.strtab, sym.name)
}

// The index of the section that defines sym. Not ok for undefined, absolute and common symbols
elf_symbol_section :: proc "contextless" (view: ^Elf_View, sym: ^Elf64_Sym) -> (index: int, ok: bool) {
	if sym.shndx == SHN_UNDEF || sym.shndx >= 0xFF00 || int(sym.shndx) >= len(view.sections) {
		return
	}
	return int(sym.shndx), true
}

Elf_Symbols :: struct {
	symbols: map[string]uintptr, // canonical name -> live address
	starts:  [dynamic]uintptr,   // live address of every symbol
	tls:     map[string]uintptr, // canonical name -> offset in the TLS block, for STT_TLS
}

read_elf_symbols :: proc(view: ^Elf_View, bias: uintptr, allocator := context.allocator) -> (out: Elf_Symbols) {
	out.symbols = make(map[string]uintptr, allocator)
	out.starts = make([dynamic]uintptr, allocator)
	out.tls = make(map[string]uintptr, allocator)
	for &sym in view.syms {
		_ = elf_symbol_section(view, &sym) or_continue
		type := elf_st_type(sym.info)
		if type == STT_SECTION || type == STT_FILE {
			continue
		}
		name := elf_symbol_name(view, &sym)
		if name == "" {
			continue
		}
		key := canonical_data_name(name)
		if type == STT_TLS {
			if key not_in out.tls {
				out.tls[strings.clone(key, allocator)] = uintptr(sym.value)
			}
			continue
		}
		live := bias + uintptr(sym.value)
		append(&out.starts, live)
		if key not_in out.symbols {
			out.symbols[strings.clone(key, allocator)] = live
		}
	}
	return
}

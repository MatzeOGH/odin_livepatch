#+build darwin arm64
package livepatch

import "core:slice"
import "core:strings"

Mach_Header_64 :: struct #packed {
	magic:      u32,
	cputype:    i32,
	cpusubtype: i32,
	filetype:   u32,
	ncmds:      u32,
	sizeofcmds: u32,
	flags:      u32,
	reserved:   u32,
}

Load_Command :: struct #packed {
	cmd:     u32,
	cmdsize: u32,
}

Segment_Command_64 :: struct #packed {
	cmd:      u32,
	cmdsize:  u32,
	segname:  [16]u8,
	vmaddr:   u64,
	vmsize:   u64,
	fileoff:  u64,
	filesize: u64,
	maxprot:  i32,
	initprot: i32,
	nsects:   u32,
	flags:    u32,
}

Section_64 :: struct #packed {
	sectname:  [16]u8,
	segname:   [16]u8,
	addr:      u64,
	size:      u64,
	offset:    u32,
	align:     u32,
	reloff:    u32,
	nreloc:    u32,
	flags:     u32,
	reserved1: u32,
	reserved2: u32,
	reserved3: u32,
}

Symtab_Command :: struct #packed {
	cmd:     u32,
	cmdsize: u32,
	symoff:  u32,
	nsyms:   u32,
	stroff:  u32,
	strsize: u32,
}

Dysymtab_Command :: struct #packed {
	cmd:            u32,
	cmdsize:        u32,
	ilocalsym:      u32,
	nlocalsym:      u32,
	iextdefsym:     u32,
	nextdefsym:     u32,
	iundefsym:      u32,
	nundefsym:      u32,
	tocoff:         u32,
	ntoc:           u32,
	modtaboff:      u32,
	nmodtab:        u32,
	extrefsymoff:   u32,
	nextrefsyms:    u32,
	indirectsymoff: u32,
	nindirectsyms:  u32,
	extreloff:      u32,
	nextrel:        u32,
	locreloff:      u32,
	nlocrel:        u32,
}

Linkedit_Data_Command :: struct #packed {
	cmd:      u32,
	cmdsize:  u32,
	dataoff:  u32,
	datasize: u32,
}

Build_Version_Command :: struct #packed {
	cmd:      u32,
	cmdsize:  u32,
	platform: u32,
	minos:    u32, // X.Y.Z as xxxx.yy.zz nibbles
	sdk:      u32,
	ntools:   u32,
}

Nlist_64 :: struct #packed {
	n_strx:  u32,
	n_type:  u8,
	n_sect:  u8,
	n_desc:  u16,
	n_value: u64,
}

Relocation_Info :: bit_field u64 {
	address:   i32  | 32,
	symbolnum: u32  | 24, // a section number when !is_extern, the addend for ARM64_RELOC_ADDEND
	pcrel:     bool | 1,
	length:    u32  | 2,
	is_extern: bool | 1,
	type:      u32  | 4,
}

MH_MAGIC_64 :: 0xFEED_FACF

MH_OBJECT  :: 0x1
MH_EXECUTE :: 0x2

MH_SUBSECTIONS_VIA_SYMBOLS :: 0x2000

CPU_TYPE_ARM64 :: 0x0100_000C

LC_SEGMENT_64                 :: 0x19
LC_SYMTAB                     :: 0x2
LC_DYSYMTAB                   :: 0xB
LC_BUILD_VERSION              :: 0x32
LC_LINKER_OPTIMIZATION_HINT   :: 0x2E
LC_DYLD_CHAINED_FIXUPS        :: 0x8000_0034

PLATFORM_MACOS :: 1

// n_type
N_STAB :: 0xE0
N_PEXT :: 0x10
N_TYPE :: 0x0E
N_EXT  :: 0x01
N_UNDF :: 0x0
N_ABS  :: 0x2
N_SECT :: 0xE

NO_SECT :: 0

SECTION_TYPE                         :: 0x0000_00FF
S_REGULAR                            :: 0x00
S_ZEROFILL                           :: 0x01
S_GB_ZEROFILL                        :: 0x0C
S_THREAD_LOCAL_REGULAR               :: 0x11
S_THREAD_LOCAL_ZEROFILL              :: 0x12
S_THREAD_LOCAL_VARIABLES             :: 0x13
S_THREAD_LOCAL_VARIABLE_POINTERS     :: 0x14
S_THREAD_LOCAL_INIT_FUNCTION_POINTERS :: 0x15
S_ATTR_PURE_INSTRUCTIONS             :: 0x8000_0000
S_ATTR_DEBUG                         :: 0x0200_0000
S_ATTR_SOME_INSTRUCTIONS             :: 0x0000_0400

// vm_prot_t
VM_PROT_READ    :: 0x1
VM_PROT_WRITE   :: 0x2
VM_PROT_EXECUTE :: 0x4

ARM64_RELOC_UNSIGNED            :: 0
ARM64_RELOC_SUBTRACTOR          :: 1
ARM64_RELOC_BRANCH26            :: 2
ARM64_RELOC_PAGE21              :: 3
ARM64_RELOC_PAGEOFF12           :: 4
ARM64_RELOC_GOT_LOAD_PAGE21     :: 5
ARM64_RELOC_GOT_LOAD_PAGEOFF12  :: 6
ARM64_RELOC_POINTER_TO_GOT      :: 7
ARM64_RELOC_TLVP_LOAD_PAGE21    :: 8
ARM64_RELOC_TLVP_LOAD_PAGEOFF12 :: 9
ARM64_RELOC_ADDEND              :: 10

Macho_View :: struct {
	header:     ^Mach_Header_64,
	segments:   [dynamic]^Segment_Command_64,
	sections:   [dynamic]^Section_64, // in file order: n_sect N is sections[N - 1]
	symtab:     ^Symtab_Command,
	dysymtab:   ^Dysymtab_Command,
	build:      ^Build_Version_Command,
	loh:        ^Linkedit_Data_Command,
	syms:       []Nlist_64,
	strtab:     []u8,
	chained_fixups: bool, // pointers that only dyld can decode
}

macho_parse :: proc(data: []byte, allocator := context.temp_allocator) -> (view: Macho_View, ok: bool) {
	if len(data) < size_of(Mach_Header_64) {
		return
	}
	header := (^Mach_Header_64)(raw_data(data))
	if header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 {
		return
	}
	view.header = header
	view.segments = make([dynamic]^Segment_Command_64, allocator)
	view.sections = make([dynamic]^Section_64, allocator)
	offset := size_of(Mach_Header_64)
	end := offset + int(header.sizeofcmds)
	if end > len(data) {
		return
	}
	for _ in 0 ..< header.ncmds {
		if offset + size_of(Load_Command) > end {
			return
		}
		command := (^Load_Command)(raw_data(data[offset:]))
		if command.cmdsize < size_of(Load_Command) || offset + int(command.cmdsize) > end {
			return
		}
		switch command.cmd {
		case LC_SEGMENT_64:
			if int(command.cmdsize) < size_of(Segment_Command_64) {
				return
			}
			segment := (^Segment_Command_64)(command)
			if size_of(Segment_Command_64) + int(segment.nsects) * size_of(Section_64) > int(command.cmdsize) {
				return
			}
			append(&view.segments, segment)
			first := ([^]Section_64)(rawptr(uintptr(segment) + size_of(Segment_Command_64)))
			for &section in first[:segment.nsects] {
				append(&view.sections, &section)
			}
		case LC_SYMTAB:
			view.symtab = (^Symtab_Command)(command)
		case LC_DYSYMTAB:
			view.dysymtab = (^Dysymtab_Command)(command)
		case LC_BUILD_VERSION:
			view.build = (^Build_Version_Command)(command)
		case LC_LINKER_OPTIMIZATION_HINT:
			view.loh = (^Linkedit_Data_Command)(command)
		case LC_DYLD_CHAINED_FIXUPS:
			view.chained_fixups = true
		}
		offset += int(command.cmdsize)
	}
	if symtab := view.symtab; symtab != nil {
		if int(symtab.symoff) + int(symtab.nsyms) * size_of(Nlist_64) > len(data) || int(symtab.stroff) + int(symtab.strsize) > len(data) {
			return
		}
		view.syms = slice.reinterpret([]Nlist_64, data[symtab.symoff:][:int(symtab.nsyms) * size_of(Nlist_64)])
		view.strtab = data[symtab.stroff:][:symtab.strsize]
	}
	return view, true
}

// A pointer, because an array parameter cannot be sliced
fixed_name :: proc(name: ^[16]u8) -> string {
	return strings.truncate_to_byte(string(name[:]), 0)
}

macho_raw_name :: proc(view: Macho_View, sym: Nlist_64) -> string {
	if int(sym.n_strx) >= len(view.strtab) {
		return ""
	}
	return strings.truncate_to_byte(string(view.strtab[sym.n_strx:]), 0)
}

macho_symbol_name :: proc(view: Macho_View, sym: Nlist_64) -> string {
	return strings.trim_prefix(macho_raw_name(view, sym), "_")
}

macho_is_temporary :: proc(raw: string) -> bool {
	return !strings.has_prefix(raw, "_")
}

macho_symbol_section :: proc(view: Macho_View, sym: Nlist_64) -> ^Section_64 {
	if sym.n_type & (N_STAB | N_TYPE) != N_SECT || sym.n_sect == NO_SECT || int(sym.n_sect) > len(view.sections) {
		return nil
	}
	return view.sections[sym.n_sect - 1]
}

// The section procedures take ^Section_64 because Macho_View holds pointers into the file.
macho_section_bytes :: proc(data: []byte, section: ^Section_64) -> (bytes: []byte, ok: bool) {
	switch section.flags & SECTION_TYPE {
	case S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL:
		return {}, true
	}
	if int(section.offset) + int(section.size) > len(data) {
		return
	}
	return data[section.offset:][:section.size], true
}

macho_section_relocs :: proc(data: []byte, section: ^Section_64) -> (relocs: []Relocation_Info, ok: bool) {
	size := int(section.nreloc) * size_of(Relocation_Info)
	if int(section.reloff) + size > len(data) {
		return
	}
	return slice.reinterpret([]Relocation_Info, data[section.reloff:][:size]), true
}

macho_is_thread_local :: proc(section: ^Section_64) -> bool {
	type := section.flags & SECTION_TYPE
	return type >= S_THREAD_LOCAL_REGULAR && type <= S_THREAD_LOCAL_INIT_FUNCTION_POINTERS
}

macho_is_code :: proc(section: ^Section_64) -> bool {
	return section.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS) != 0
}

Macho_Symbols :: struct {
	symbols: map[string]uintptr, // stable key (data_key) -> live address
	starts:  [dynamic]uintptr,   // live address of every symbol
}

read_macho_symbols :: proc(view: Macho_View, slide: uintptr, stable_keys := true, allocator := context.allocator) -> (out: Macho_Symbols) {
	out.symbols = make(map[string]uintptr, allocator)
	out.starts = make([dynamic]uintptr, allocator)

	keys: Static_Keys
	if stable_keys {
		names := make([dynamic]string, context.temp_allocator)
		for sym in view.syms {
			append(&names, macho_symbol_name(view, sym))
		}
		keys = static_keys_make(names[:])
	}

	ambiguous := make(map[string]bool, context.temp_allocator)
	for sym in view.syms {
		if macho_symbol_section(view, sym) == nil {
			continue
		}
		raw := macho_raw_name(view, sym)
		if raw == "" {
			continue
		}
		live := slide + uintptr(sym.n_value)
		append(&out.starts, live)
		if macho_is_temporary(raw) {
			continue
		}
		index_add(&out.symbols, &ambiguous, data_key(keys, raw[1:]), live, allocator)
	}
	return
}

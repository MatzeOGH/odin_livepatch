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

macho_parse :: proc(data: []byte, allocator := context.temp_allocator) -> (v: Macho_View, ok: bool) {
	if len(data) < size_of(Mach_Header_64) {
		return
	}
	h := (^Mach_Header_64)(raw_data(data))
	if h.magic != MH_MAGIC_64 || h.cputype != CPU_TYPE_ARM64 {
		return
	}
	v.header = h
	v.segments = make([dynamic]^Segment_Command_64, allocator)
	v.sections = make([dynamic]^Section_64, allocator)
	off := size_of(Mach_Header_64)
	end := off + int(h.sizeofcmds)
	if end > len(data) {
		return
	}
	for _ in 0 ..< h.ncmds {
		if off + size_of(Load_Command) > end {
			return
		}
		lc := (^Load_Command)(raw_data(data[off:]))
		if lc.cmdsize < size_of(Load_Command) || off + int(lc.cmdsize) > end {
			return
		}
		switch lc.cmd {
		case LC_SEGMENT_64:
			if int(lc.cmdsize) < size_of(Segment_Command_64) {
				return
			}
			seg := (^Segment_Command_64)(lc)
			if size_of(Segment_Command_64) + int(seg.nsects) * size_of(Section_64) > int(lc.cmdsize) {
				return
			}
			append(&v.segments, seg)
			first := ([^]Section_64)(rawptr(uintptr(seg) + size_of(Segment_Command_64)))
			for i in 0 ..< int(seg.nsects) {
				append(&v.sections, &first[i])
			}
		case LC_SYMTAB:
			v.symtab = (^Symtab_Command)(lc)
		case LC_DYSYMTAB:
			v.dysymtab = (^Dysymtab_Command)(lc)
		case LC_BUILD_VERSION:
			v.build = (^Build_Version_Command)(lc)
		case LC_LINKER_OPTIMIZATION_HINT:
			v.loh = (^Linkedit_Data_Command)(lc)
		case LC_DYLD_CHAINED_FIXUPS:
			v.chained_fixups = true
		}
		off += int(lc.cmdsize)
	}
	if st := v.symtab; st != nil {
		if int(st.symoff) + int(st.nsyms) * size_of(Nlist_64) > len(data) || int(st.stroff) + int(st.strsize) > len(data) {
			return
		}
		v.syms = slice.reinterpret([]Nlist_64, data[st.symoff:][:int(st.nsyms) * size_of(Nlist_64)])
		v.strtab = data[st.stroff:][:st.strsize]
	}
	return v, true
}

fixed_name :: proc(b: ^[16]u8) -> string {
	return strings.truncate_to_byte(string(b[:]), 0)
}

macho_raw_name :: proc(v: ^Macho_View, sym: ^Nlist_64) -> string {
	if int(sym.n_strx) >= len(v.strtab) {
		return ""
	}
	return strings.truncate_to_byte(string(v.strtab[sym.n_strx:]), 0)
}

macho_symbol_name :: proc(v: ^Macho_View, sym: ^Nlist_64) -> string {
	return strings.trim_prefix(macho_raw_name(v, sym), "_")
}

macho_is_temporary :: proc(raw: string) -> bool {
	return !strings.has_prefix(raw, "_")
}

macho_symbol_section :: proc(v: ^Macho_View, sym: ^Nlist_64) -> ^Section_64 {
	if sym.n_type & (N_STAB | N_TYPE) != N_SECT || sym.n_sect == NO_SECT || int(sym.n_sect) > len(v.sections) {
		return nil
	}
	return v.sections[sym.n_sect - 1]
}

macho_section_bytes :: proc(data: []byte, sh: ^Section_64) -> (bytes: []byte, ok: bool) {
	switch sh.flags & SECTION_TYPE {
	case S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL:
		return {}, true
	}
	if int(sh.offset) + int(sh.size) > len(data) {
		return
	}
	return data[sh.offset:][:sh.size], true
}

macho_section_relocs :: proc(data: []byte, sh: ^Section_64) -> (relocs: []Relocation_Info, ok: bool) {
	size := int(sh.nreloc) * size_of(Relocation_Info)
	if int(sh.reloff) + size > len(data) {
		return
	}
	return slice.reinterpret([]Relocation_Info, data[sh.reloff:][:size]), true
}

macho_is_thread_local :: proc(sh: ^Section_64) -> bool {
	type := sh.flags & SECTION_TYPE
	return type >= S_THREAD_LOCAL_REGULAR && type <= S_THREAD_LOCAL_INIT_FUNCTION_POINTERS
}

macho_is_code :: proc(sh: ^Section_64) -> bool {
	return sh.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS) != 0
}

Macho_Symbols :: struct {
	symbols: map[string]uintptr, // stable key (data_key) -> live address
	starts:  [dynamic]uintptr,   // live address of every symbol
}

read_macho_symbols :: proc(v: ^Macho_View, slide: uintptr, allocator := context.allocator, stable_keys := true) -> (out: Macho_Symbols) {
	out.symbols = make(map[string]uintptr, allocator)
	out.starts = make([dynamic]uintptr, allocator)

	keys: Static_Keys
	if stable_keys {
		names := make([dynamic]string, context.temp_allocator)
		for &sym in v.syms {
			append(&names, macho_symbol_name(v, &sym))
		}
		keys = static_keys_make(names[:])
	}

	ambiguous := make(map[string]bool, context.temp_allocator)
	for &sym in v.syms {
		sh := macho_symbol_section(v, &sym)
		if sh == nil {
			continue
		}
		raw := macho_raw_name(v, &sym)
		if raw == "" {
			continue
		}
		live := slide + uintptr(sym.n_value)
		append(&out.starts, live)
		if macho_is_temporary(raw) {
			continue
		}
		key := data_key(keys, raw[1:])
		index_add(&out.symbols, &ambiguous, key, live, allocator)
	}
	return
}

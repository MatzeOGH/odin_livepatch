#+build darwin arm64
package livepatch

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

OBJECT_EXT :: ".o"
ENTRY_SYMBOL :: "lp$entry"

Loaded_Object :: struct {
	path:   string,
	data:   []byte,
	view:   Macho_View,
	out:    []byte,
	fixups: [dynamic]Fixup,
}

parse_object :: proc(path: string, data: []byte) -> (object: Loaded_Object, ok: bool) {
	view := parse_macho(data) or_return
	if view.header.filetype != MH_OBJECT || view.symbol_table == nil || view.dynamic_symbol_table == nil {
		return
	}
	return Loaded_Object{path = path, data = data, view = view}, true
}

object_max_image_size :: proc(object: Loaded_Object) -> (size: int) {
	for section in object.view.sections {
		if section.flags & S_ATTR_DEBUG == 0 {
			size += int(section.size) + (1 << min(section.align, 16))
		}
	}
	if symbol_table := object.view.symbol_table; symbol_table != nil {
		size += 3 * int(symbol_table.nsyms) * size_of(Nlist_64) + 2 * int(symbol_table.strsize)
	}
	return
}

next_object_symbol :: proc(object: Loaded_Object, cursor: ^int) -> (symbol: Object_Symbol, ok: bool) {
	view := object.view
	if cursor^ >= len(view.symbols) {
		return
	}
	macho_symbol := view.symbols[cursor^]
	cursor^ += 1

	raw_name := macho_raw_name(view, macho_symbol)
	symbol.name = macho_symbol_name(view, macho_symbol)
	symbol.local = macho_symbol.n_type & N_EXT == 0
	if macho_symbol.n_type & N_STAB != 0 || macho_is_temporary(raw_name) {
		return symbol, true
	}

	if macho_symbol.n_type & N_TYPE == N_UNDF {
		if !symbol.local && macho_symbol.n_value == 0 { // a common symbol has its size in n_value
			symbol.kind = .Undefined
		}
		return symbol, true
	}

	section := macho_symbol_section(view, macho_symbol)
	if section == nil {
		return symbol, true // absolute or indirect
	}
	symbol.provides = !symbol.local

	switch {
	case section.flags & S_ATTR_DEBUG != 0,
	     macho_is_thread_local(section):
		symbol.kind = .Skipped
	case macho_is_code(section):
		symbol.kind = .Code
	case section_holds_variables(section):
		symbol.kind = .Data
	case:
		symbol.kind = .Skipped
	}
	return symbol, true
}

section_holds_variables :: proc(section: ^Section_64) -> bool {
	switch section.flags & SECTION_TYPE {
	case S_REGULAR, S_ZEROFILL, S_GB_ZEROFILL:
		name := fixed_name(&section.sectname)
		return fixed_name(&section.segname) == "__DATA" && !macho_is_code(section) &&
		       name != "__const" && name != "__cfstring" && !strings.has_prefix(name, "__objc_")
	}
	return false
}

keeps_relocations :: proc(section: ^Section_64) -> bool {
	return section.flags & S_ATTR_DEBUG != 0 || fixed_name(&section.segname) == "__LD" ||
	       fixed_name(&section.sectname) == "__eh_frame" || macho_is_thread_local(section)
}

Near_References :: struct {
	names: map[string]bool, // undefined names that some BRANCH26 reaches
}

startup_initialized_global :: proc(objects: []Loaded_Object, merged: ^Merged) -> string {
	return ""
}

find_near_references :: proc(objects: []Loaded_Object) -> (refs: Near_References) {
	refs.names = make(map[string]bool, context.temp_allocator)
	for object in objects {
		view := object.view
		for section in view.sections {
			relocations := macho_section_relocations(object.data, section) or_continue
			for relocation in relocations {
				if relocation.type != ARM64_RELOC_BRANCH26 || !relocation.is_extern {
					continue
				}
				symbol_index := int(relocation.symbolnum)
				if symbol_index < len(view.symbols) && view.symbols[symbol_index].n_type & N_TYPE == N_UNDF {
					refs.names[macho_symbol_name(view, view.symbols[symbol_index])] = true
				}
			}
		}
	}
	return
}

needs_near_address :: proc(refs: Near_References, name: string) -> bool {
	return name in refs.names
}

Fixup :: struct {
	marker: string,  // the marker symbol, without the underscore
	offset: u32,     // from the marker
	kind:   Fixup_Kind,
	target: uintptr, // the address that the reference must reach, addend included
	name:   string,  // what it refers to, for an error
}

Fixup_Kind :: enum u8 {
	Branch26,
	Page21,
	Pageoff12, // add, or a load or store scaled by the access size
	Pointer64,
}

marker_count: int

Macho_Rewrite :: struct {
	object:             ^Loaded_Object,
	merged:             ^Merged,
	markers:            [dynamic]Nlist_64,
	added_strings:      [dynamic]u8,
	marker_at:          map[[2]u64]string, // section index, atom address -> its marker
	symbols_by_section: [][dynamic]Section_Symbol, // section index -> its defined symbols, by address
}

Section_Symbol :: struct {
	value: u64,
	index: int,
}

retarget_object_references :: proc(object: ^Loaded_Object, merged: ^Merged) -> (out: []byte, failed: string) {
	data := object.data
	view := object.view
	object.fixups = make([dynamic]Fixup, context.temp_allocator)
	rewrite := Macho_Rewrite{
		object             = object,
		merged             = merged,
		markers            = make([dynamic]Nlist_64, context.temp_allocator),
		added_strings      = make([dynamic]u8, context.temp_allocator),
		marker_at          = make(map[[2]u64]string, context.temp_allocator),
		symbols_by_section = make([][dynamic]Section_Symbol, len(view.sections), context.temp_allocator),
	}
	for &list in rewrite.symbols_by_section {
		list = make([dynamic]Section_Symbol, context.temp_allocator)
	}
	for symbol, symbol_index in view.symbols {
		if macho_symbol_section(view, symbol) != nil && macho_raw_name(view, symbol) != "" {
			append(&rewrite.symbols_by_section[symbol.n_sect - 1], Section_Symbol{symbol.n_value, symbol_index})
		}
	}
	for &list in rewrite.symbols_by_section {
		slice.stable_sort_by(list[:], proc(a, b: Section_Symbol) -> bool { return a.value < b.value })
	}

	for section, section_index in view.sections {
		if section.nreloc == 0 || keeps_relocations(section) {
			continue
		}

		bytes, bytes_ok := macho_section_bytes(data, section)
		relocations, relocations_ok := macho_section_relocations(data, section)

		if !bytes_ok || !relocations_ok {
			return nil, "<relocation table>"
		}

		kept := 0
		addend: i64         // from a preceding ARM64_RELOC_ADDEND
		has_addend := false // that ADDEND is the last kept relocation

		for relocation_index := 0; relocation_index < len(relocations); relocation_index += 1 {
			relocation := relocations[relocation_index]
			if relocation.type == ARM64_RELOC_ADDEND {
				addend = i64(i32(relocation.symbolnum << 8) >> 8) // 24-bit, sign extended
				relocations[kept] = relocation
				has_addend = true
				kept += 1
				continue
			}

			pending, had_addend := addend, has_addend
			addend, has_addend = 0, false

			if relocation.type == ARM64_RELOC_SUBTRACTOR {
				// With the UNSIGNED after it: a difference inside the module
				relocations[kept] = relocation
				kept += 1
				if relocation_index + 1 < len(relocations) {
					relocations[kept] = relocations[relocation_index + 1]
					kept += 1
					relocation_index += 1
				}
				continue
			}

			fixup, out_of_image, plan_failed := plan_fixup(&rewrite, relocation, pending, bytes)
			if plan_failed != "" {
				return nil, plan_failed
			}

			if !out_of_image {
				relocations[kept] = relocation
				kept += 1
				continue
			}

			if had_addend {
				kept -= 1 // its ADDEND goes too
			}

			if marker_failed := add_fixup(&rewrite, section_index, u64(relocation.address), fixup); marker_failed != "" {
				return nil, marker_failed
			}
		}
		section.nreloc = u32(kept)
	}

	return with_markers(&rewrite)
}

plan_fixup :: proc(rewrite: ^Macho_Rewrite, relocation: Relocation_Info, addend: i64, bytes: []byte) -> (fixup: Fixup, out_of_image: bool, failed: string) {
	view := rewrite.object.view
	site := int(relocation.address)

	if site < 0 || site + 4 > len(bytes) {
		return {}, false, "<relocation out of bounds>"
	}

	switch relocation.type {
	case ARM64_RELOC_TLVP_LOAD_PAGE21, ARM64_RELOC_TLVP_LOAD_PAGEOFF12:
		// ldr of the descriptor pointer becomes add, the thunk then uses the descriptor of the exe
		symbol_index := int(relocation.symbolnum)
		if !relocation.is_extern || symbol_index >= len(view.symbols) {
			return {}, false, "<thread-local>"
		}

		name := macho_symbol_name(view, view.symbols[symbol_index])
		descriptor, found := exe_tls_descriptor(name, rewrite.merged.keys)
		page := relocation.type == ARM64_RELOC_TLVP_LOAD_PAGE21

		if !found || (!page && !ldr_to_add(bytes, site)) {
			return {}, false, name
		}

		return {kind = page ? .Page21 : .Pageoff12, target = descriptor, name = name}, true, ""

	case ARM64_RELOC_GOT_LOAD_PAGE21, ARM64_RELOC_GOT_LOAD_PAGEOFF12:
		// Near: ldr becomes add. Past the 4GB of ADRP the shared cache, ldr from a near cell
		address, name, found := outside_address(rewrite, relocation, 0)
		if !found {
			return
		}
		page := relocation.type == ARM64_RELOC_GOT_LOAD_PAGE21
		if !is_near(address) {
			address = uintptr(got_cell_for(strings.concatenate({"\x00got:", name}, context.temp_allocator), rawptr(address)))
			if address == 0 {
				return {}, false, name
			}
		} else if !page && !ldr_to_add(bytes, site) {
			return {}, false, name
		}
		return {kind = page ? .Page21 : .Pageoff12, target = address, name = name}, true, ""

	case ARM64_RELOC_BRANCH26:
		fixup.kind = .Branch26
		fixup.target, fixup.name, out_of_image = outside_address(rewrite, relocation, addend)
	case ARM64_RELOC_PAGE21:
		fixup.kind = .Page21
		fixup.target, fixup.name, out_of_image = outside_address(rewrite, relocation, addend)
	case ARM64_RELOC_PAGEOFF12:
		fixup.kind = .Pageoff12
		fixup.target, fixup.name, out_of_image = outside_address(rewrite, relocation, addend)

	case ARM64_RELOC_UNSIGNED:
		if relocation.length != 3 || site + 8 > len(bytes) {
			if _, name, outside := outside_address(rewrite, relocation, 0); outside {
				return {}, false, name
			}
			return
		}
		// For a section-based relocation, the bytes hold the target address in the object
		fixup.kind = .Pointer64
		fixup.target, fixup.name, out_of_image = outside_address(rewrite, relocation, (^i64)(&bytes[site])^)

	case ARM64_RELOC_POINTER_TO_GOT:
		if _, name, outside := outside_address(rewrite, relocation, 0); outside {
			return {}, false, name // only in unwind info, which keeps its relocations
		}
	}
	return
}

outside_address :: proc(rewrite: ^Macho_Rewrite, relocation: Relocation_Info, addend: i64) -> (address: uintptr, name: string, ok: bool) {
	view := rewrite.object.view

	if !relocation.is_extern {
		section := int(relocation.symbolnum)
		if relocation.type != ARM64_RELOC_UNSIGNED || section < 1 || section > len(view.sections) || !section_holds_variables(view.sections[section - 1]) {
			return
		}

		holding := holding_symbol(rewrite, section - 1, addend, -1) or_return
		name = macho_symbol_name(view, view.symbols[holding])
		live := rewrite.merged.defs[name] or_return
		return uintptr(i64(uintptr(live)) + addend - i64(view.symbols[holding].n_value)), name, true
	}

	symbol_index := int(relocation.symbolnum)
	if symbol_index >= len(view.symbols) {
		return
	}

	symbol := view.symbols[symbol_index]
	if symbol.n_type & N_STAB != 0 {
		return
	}

	name = macho_symbol_name(view, symbol)
	if symbol.n_type & N_TYPE == N_UNDF {
		if macho_is_temporary(macho_raw_name(view, symbol)) {
			return
		}
		if live, bound := rewrite.merged.defs[name]; bound {
			return uintptr(i64(uintptr(live)) + addend), name, true
		}
		if live, external := rewrite.merged.externals[name]; external {
			return uintptr(i64(uintptr(live)) + addend), name, true
		}
		return
	}

	section := macho_symbol_section(view, symbol)
	if section == nil || macho_is_thread_local(section) {
		return
	}

	// LLVM reaches data without a name through the symbol before it
	target := i64(symbol.n_value) + addend
	holding := holding_symbol(rewrite, int(symbol.n_sect) - 1, target, symbol_index) or_return

	if macho_is_code(section) && i64(view.symbols[holding].n_value) != target {
		return // into a procedure: the copy of the exe has another layout
	}

	name = macho_symbol_name(view, view.symbols[holding])
	live := rewrite.merged.defs[name] or_return

	return uintptr(i64(uintptr(live)) + target - i64(view.symbols[holding].n_value)), name, true
}

symbols_upto :: proc(rewrite: ^Macho_Rewrite, section_index: int, address: u64) -> []Section_Symbol {
	list := rewrite.symbols_by_section[section_index][:]
	end, _ := slice.binary_search_by(list, address, proc(entry: Section_Symbol, address: u64) -> slice.Ordering {
		return entry.value <= address ? .Less : .Greater
	})
	return list[:end]
}

holding_symbol :: proc(rewrite: ^Macho_Rewrite, section_index: int, target: i64, prefer: int) -> (symbol_index: int, ok: bool) {
	view := rewrite.object.view

	if target < 0 {
		return
	}

	below := symbols_upto(rewrite, section_index, u64(target))
	if len(below) == 0 {
		return
	}

	// Of the symbols at the nearest address, the preferred one, else the first one with a name
	first := len(below) - 1

	for first > 0 && below[first - 1].value == below[first].value {
		first -= 1
	}
	best := below[first].index

	for entry in below[first + 1:] {
		if entry.index == prefer || (best != prefer && macho_is_temporary(macho_raw_name(view, view.symbols[best]))) {
			best = entry.index
		}
	}

	if macho_is_temporary(macho_raw_name(view, view.symbols[best])) {
		return
	}

	return best, true
}

add_fixup :: proc(rewrite: ^Macho_Rewrite, section_index: int, site: u64, fixup: Fixup) -> (failed: string) {
	view := rewrite.object.view
	address := view.sections[section_index].addr + site
	below := symbols_upto(rewrite, section_index, address)

	if len(below) == 0 {
		return "<reference outside every atom>"
	}

	start := below[len(below) - 1].value
	marker, found := rewrite.marker_at[{u64(section_index), start}]

	if !found {
		marker_count += 1
		marker = fmt.tprintf("lp$m%d", marker_count)
		rewrite.marker_at[{u64(section_index), start}] = marker
		append(&rewrite.markers, Nlist_64{
			n_strx  = u32(len(view.string_table) + len(rewrite.added_strings)),
			n_type  = N_SECT, // local
			n_sect  = u8(section_index + 1),
			n_value = start,
		})
		append(&rewrite.added_strings, '_')
		append(&rewrite.added_strings, marker)
		append(&rewrite.added_strings, 0)
	}

	fixup := fixup
	fixup.marker, fixup.offset = marker, u32(address - start)
	append(&rewrite.object.fixups, fixup)
	return ""
}

ldr_to_add :: proc(bytes: []byte, site: int) -> bool {
	instruction := (^Unsigned_Immediate)(&bytes[site])
	switch instruction.opcode {
	case LDR_X_IMM:
		instruction.opcode, instruction.imm12 = ADD_X_IMM, 0 // keeps rn and rd
		return true
	case ADD_X_IMM:
		return true
	}
	return false
}

with_markers :: proc(rewrite: ^Macho_Rewrite) -> (out: []byte, failed: string) {
	data := rewrite.object.data
	view := rewrite.object.view
	dynamic_symbol_table := view.dynamic_symbol_table
	local_count := int(dynamic_symbol_table.ilocalsym + dynamic_symbol_table.nlocalsym)

	if dynamic_symbol_table.ilocalsym != 0 || local_count > len(view.symbols) {
		return nil, "<symbol table order>"
	}

	new_marker_count := u32(len(rewrite.markers))

	if new_marker_count > 0 {
		for section in view.sections {
			relocations := macho_section_relocations(data, section) or_continue
			for &relocation in relocations {
				if relocation.is_extern && relocation.type != ARM64_RELOC_ADDEND && int(relocation.symbolnum) >= local_count {
					relocation.symbolnum += new_marker_count
				}
			}
		}

		if dynamic_symbol_table.nindirectsyms > 0 {
			INDIRECT_SYMBOL_LOCAL :: 0x8000_0000
			INDIRECT_SYMBOL_ABS   :: 0x4000_0000
			start := int(dynamic_symbol_table.indirectsymoff)

			if start + int(dynamic_symbol_table.nindirectsyms) * 4 > len(data) {
				return nil, "<indirect symbol table>"
			}

			for &entry in slice.reinterpret([]u32, data[start:][:dynamic_symbol_table.nindirectsyms * 4]) {
				if entry & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) == 0 && int(entry) >= local_count {
					entry += new_marker_count
				}
			}
		}
	}

	symbol_count := len(view.symbols) + len(rewrite.markers)
	symbol_table_offset := mem.align_forward_int(len(data), 8)
	string_table_offset := symbol_table_offset + symbol_count * size_of(Nlist_64)
	string_table_size := mem.align_forward_int(len(view.string_table) + len(rewrite.added_strings), 8)
	out = make([]byte, string_table_offset + string_table_size, context.temp_allocator)
	copy(out, data)
	out_symbols := slice.reinterpret([]Nlist_64, out[symbol_table_offset:string_table_offset])
	copy(out_symbols, view.symbols[:local_count])
	copy(out_symbols[local_count:], rewrite.markers[:])
	copy(out_symbols[local_count + len(rewrite.markers):], view.symbols[local_count:])
	copy(out[string_table_offset:], view.string_table)
	copy(out[string_table_offset + len(view.string_table):], rewrite.added_strings[:])

	// The load commands of out are at the same offsets as in data
	out_command :: proc(out, data: []byte, command: rawptr) -> rawptr {
		return &out[uintptr(command) - uintptr(raw_data(data))]
	}
	symbol_table := (^Symtab_Command)(out_command(out, data, view.symbol_table))
	symbol_table.symoff = u32(symbol_table_offset)
	symbol_table.nsyms = u32(symbol_count)
	symbol_table.stroff = u32(string_table_offset)
	symbol_table.strsize = u32(string_table_size)
	out_dynamic_symbol_table := (^Dysymtab_Command)(out_command(out, data, dynamic_symbol_table))
	out_dynamic_symbol_table.nlocalsym += new_marker_count
	out_dynamic_symbol_table.iextdefsym += new_marker_count
	out_dynamic_symbol_table.iundefsym += new_marker_count

	if view.optimization_hints != nil {
		(^Linkedit_Data_Command)(out_command(out, data, view.optimization_hints)).datasize = 0 // the hints describe instructions that may have changed
	}

	return out, ""
}

// A branch out of the module that cannot reach its target goes through a veneer after the module.
Module_Veneer :: struct {
	ldr, br: u32, // ldr x16, #8; br x16
	target:  uintptr,
}
MODULE_VENEER_SIZE :: size_of(Module_Veneer)
LDR_X16_8 :: u32(0x5800_0050) // ldr x16, #8

Module_Veneers :: struct {
	next: uintptr,
	at:   map[uintptr]uintptr, // target -> its veneer
}

far_branch_targets :: proc(objects: []Loaded_Object) -> int {
	targets := make(map[uintptr]bool, context.temp_allocator)
	for object in objects {
		for fixup in object.fixups {
			if fixup.kind == .Branch26 {
				targets[fixup.target] = true
			}
		}
	}
	return len(targets)
}

veneer_for :: proc(veneers: ^Module_Veneers, target: uintptr) -> uintptr {
	if veneer, found := veneers.at[target]; found {
		return veneer
	}

	veneer := veneers.next
	(^Module_Veneer)(veneer)^ = {LDR_X16_8, BR_X16, target}
	veneers.next += MODULE_VENEER_SIZE
	veneers.at[target] = veneer
	return veneer
}

apply_fixups :: proc(objects: []Loaded_Object, symbols: map[string]uintptr, veneers: ^Module_Veneers) -> (failed: string) {
	for object in objects {
		for fixup in object.fixups {
			marker, found := symbols[fixup.marker]
			if !found {
				return fixup.marker
			}
			if !write_fixup(marker + uintptr(fixup.offset), fixup, veneers) {
				return fixup.name
			}
		}
	}
	return ""
}

branch_reaches :: proc(site, target: uintptr) -> bool {
	distance := i64(target) - i64(site)
	return distance & 3 == 0 && distance >= -(1 << 27) && distance < 1 << 27
}

Page_Address :: bit_field u32 {
	rd:     u32 | 5,
	immhi:  i32 | 19,
	opcode: u32 | 5,
	immlo:  u32 | 2,
	op:     u32 | 1,
}

Unsigned_Immediate :: bit_field u32 {
	rd:     u32 | 5,
	rn:     u32 | 5,
	imm12:  u32 | 12,
	opcode: u32 | 10,
}
LDR_X_IMM :: 0b11_1110_0101 // ldr x, [rn, #imm]
ADD_X_IMM :: 0b10_0100_0100 // add x, rn, #imm

write_fixup :: proc(site: uintptr, fixup: Fixup, veneers: ^Module_Veneers) -> bool {
	instruction := (^u32)(rawptr(site))
	switch fixup.kind {
	case .Branch26:
		target := fixup.target
		if !branch_reaches(site, target) {
			target = veneer_for(veneers, target)
			if !branch_reaches(site, target) {
				return false // ponytail: a module larger than 128MB cannot reach the veneers after it
			}
		}
		(^Branch)(site).imm26 = i32((i64(target) - i64(site)) >> 2)
	case .Page21:
		pages := i64(fixup.target >> 12) - i64(site >> 12)
		if pages < -(1 << 20) || pages >= 1 << 20 {
			return false
		}
		page_address := (^Page_Address)(site)
		page_address.immlo, page_address.immhi = u32(pages), i32(pages >> 2)
	case .Pageoff12:
		page_offset := u32(fixup.target & 0xFFF)
		scale: u32
		switch {
		case instruction^ & 0x1F00_0000 == 0x1100_0000: // add or sub, immediate
		case instruction^ & 0x3B00_0000 == 0x3900_0000: // load or store, unsigned offset
			scale = instruction^ >> 30
			if instruction^ & 0x0480_0000 == 0x0480_0000 { // a 128-bit q register
				scale = 4
			}
		case:
			return false
		}
		if page_offset & ((1 << scale) - 1) != 0 {
			return false
		}
		(^Unsigned_Immediate)(site).imm12 = page_offset >> scale
	case .Pointer64:
		(^u64)(rawptr(site))^ = u64(fixup.target)
	}
	return true
}

absolute_symbols_object :: proc(merged: ^Merged) -> []byte {
	symbol_count := 1 + len(merged.externals)
	string_table_size := len(" \x00") + len(ENTRY_SYMBOL) + 2 // each name has '_' before it and a zero after it
	for name in merged.externals {
		string_table_size += len(name) + 2
	}
	string_table_size = mem.align_forward_int(string_table_size, 8)

	SEGMENT_SIZE :: size_of(Segment_Command_64) + size_of(Section_64)
	commands_size := SEGMENT_SIZE + size_of(Symtab_Command) + size_of(Dysymtab_Command)
	text_offset := size_of(Mach_Header_64) + commands_size
	symbol_table_offset := text_offset + 8
	string_table_offset := symbol_table_offset + symbol_count * size_of(Nlist_64)
	out := make([]byte, string_table_offset + string_table_size, context.temp_allocator)

	// The tables fill out directly, and the zeros of make are the padding
	symbols := slice.into_dynamic(slice.reinterpret([]Nlist_64, out[symbol_table_offset:string_table_offset]))
	string_table := slice.into_dynamic(out[string_table_offset:])
	append(&string_table, " \x00") // index 0 is the empty name

	add_symbol :: proc(symbols: ^[dynamic]Nlist_64, string_table: ^[dynamic]u8, name: string, type: u8, section: u8, value: u64) {
		append(symbols, Nlist_64{n_strx = u32(len(string_table)), n_type = type | N_EXT, n_sect = section, n_value = value})
		append(string_table, '_')
		append(string_table, name)
		append(string_table, 0)
	}

	add_symbol(&symbols, &string_table, ENTRY_SYMBOL, N_SECT, 1, 0)

	// Includes _tlv_bootstrap: ld64.lld links no libSystem
	for name, address in merged.externals {
		add_symbol(&symbols, &string_table, name, N_ABS, NO_SECT, u64(uintptr(address)))
	}

	assert(len(symbols) == symbol_count)

	header := (^Mach_Header_64)(raw_data(out))
	header^ = {magic = MH_MAGIC_64, cputype = CPU_TYPE_ARM64, filetype = MH_OBJECT, ncmds = 3,
	           sizeofcmds = u32(commands_size), flags = MH_SUBSECTIONS_VIA_SYMBOLS}
	at := size_of(Mach_Header_64)

	segment := (^Segment_Command_64)(raw_data(out[at:]))
	segment^ = {cmd = LC_SEGMENT_64, cmdsize = SEGMENT_SIZE, vmsize = 4, fileoff = u64(text_offset), filesize = 4,
	            maxprot = VM_PROT_READ | VM_PROT_EXECUTE, initprot = VM_PROT_READ | VM_PROT_EXECUTE, nsects = 1}
	section := (^Section_64)(raw_data(out[at + size_of(Segment_Command_64):]))
	copy(section.sectname[:], "__text")
	copy(section.segname[:], "__TEXT")
	section.size = 4
	section.offset = u32(text_offset)
	section.align = 2
	section.flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS
	at += SEGMENT_SIZE

	symbol_table := (^Symtab_Command)(raw_data(out[at:]))
	symbol_table^ = {cmd = LC_SYMTAB, cmdsize = size_of(Symtab_Command), symoff = u32(symbol_table_offset), nsyms = u32(len(symbols)),
	           stroff = u32(string_table_offset), strsize = u32(string_table_size)}
	at += size_of(Symtab_Command)

	dynamic_symbol_table := (^Dysymtab_Command)(raw_data(out[at:]))
	dynamic_symbol_table^ = {cmd = LC_DYSYMTAB, cmdsize = size_of(Dysymtab_Command), nextdefsym = u32(len(symbols)), iundefsym = u32(len(symbols))}

	(^u32)(raw_data(out[text_offset:]))^ = 0xD420_0000 // brk #0
	return out
}

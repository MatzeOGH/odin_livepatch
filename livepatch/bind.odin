#+build windows
package livepatch

import "core:strings"

// Binds every referenced symbol to one address across all patch objects. Pass A
// (merge_symbols) picks each shared symbol's address and pass B (resolve_symbols) resolves
// each object's symbol indices.

Redirect :: struct {
	exe_address: rawptr,
	body:        rawptr,
}

Slot_Target :: struct {
	slot: rawptr,
	body: rawptr,
}

// A writable data symbol absent from the exe, seeded from `src` (the relocated copy).
New_Global :: struct {
	key:   string,
	store: rawptr,
	src:   rawptr,
	size:  int,
}

Merged :: struct {
	defs:           map[string]rawptr, // link name -> stable address
	redirects:      [dynamic]Redirect,
	slot_targets:   [dynamic]Slot_Target,
	new_globals:    [dynamic]New_Global,
	type_table_new: rawptr, // the new build's runtime.type_table slice header
}

section_addr :: proc "contextless" (o: ^Loaded_Object, section_number, value: int) -> rawptr {
	return rawptr(uintptr(o.section_bases[section_number]) + uintptr(value))
}

// Pass A. Assigns each shared defined symbol one stable address. First definer wins (COFF
// COMDAT folding).
merge_symbols :: proc(objects: []Loaded_Object, allocator := context.temp_allocator) -> (merged: Merged) {
	merged.defs = make(map[string]rawptr, allocator)
	merged.redirects = make([dynamic]Redirect, allocator)
	merged.slot_targets = make([dynamic]Slot_Target, allocator)
	merged.new_globals = make([dynamic]New_Global, allocator)

	for &o in objects {
		cursor := 0
		for symbol, index in coff_symbols(o.data, o.view.sym_off, o.view.n_syms, &cursor) {
			section_number := int(symbol.section_number)
			name := symbol_name(symbol, o.data, o.view.strtab_off)
			def_section := section_number
			def_value := int(symbol.value)
			if section_number == 0 {
				aux := weak_external_aux(o.data, o.view.sym_off, index, symbol) or_continue
				def := coff_symbol(o.data, o.view.sym_off, int(aux.tag_index))
				def_section = int(def.section_number)
				def_value = int(def.value)
			}

			if def_section <= 0 || o.section_bases[def_section] == nil {
				continue // UNDEF with no default, ABS, or a section we did not map
			}
			section := section_header(o.data, o.view.sec_off, def_section - 1)

			// Object-local binds to its own copy in Pass B, so it is never merged.
			if section_number > 0 && is_object_local(symbol, name, section) {
				continue
			}
			if strings.has_prefix(name, ".weak.") {
				continue // never referenced by that mangled name
			}
			if section_name(section) == ".tls$" {
				continue // reached through the TEB, not this copy (tls.odin)
			}
			if name in merged.defs {
				continue
			}

			body_address := section_addr(&o, def_section, def_value)
			characteristics := u32(section.characteristics)

			// The write step copies this header into the exe, so a typeid lookup finds the
			// new build's types.
			if name == "runtime::type_table" {
				merged.type_table_new = body_address
			}

			if (characteristics & IMAGE_SCN_MEM_EXECUTE) != 0 {
				// Never redirect or slot the livepatch package's own procedures (that would
				// corrupt the patcher mid-run). Bind an exported proc to the exe, a
				// file-private one to its own (dead) copy, so livepatch stays self-resolving
				// and never goes dirty.
				if strings.has_prefix(name, "livepatch::") {
					if exe_address, _, found := exe_symbol(name); found {
						merged.defs[name] = exe_address
					} else {
						merged.defs[name] = body_address
					}
					continue
				}
				// size >= 5: needs room for a 5-byte jmp rel32, else a slot.
				if exe_address, size, found := exe_symbol(name); found && size >= 5 {
					merged.defs[name] = exe_address
					append(&merged.redirects, Redirect{exe_address, body_address})
				} else {
					slot := slot_for(name)
					merged.defs[name] = slot
					if slot != nil {
						append(&merged.slot_targets, Slot_Target{slot, body_address})
					}
				}
			} else if (characteristics & IMAGE_SCN_MEM_WRITE) != 0 {
				key := canonical_data_name(name)
				if exe_address, _, found := exe_symbol(name); found {
					merged.defs[name] = exe_address
				} else if live, ok := exe_static_addr(key); ok {
					// base-build @static or file-private, from the .map
					merged.defs[name] = live
				} else {
					// added by a patch
					size := symbol_extent(&o, def_section, def_value)
					store, created := global_for(key, size)
					merged.defs[name] = store
					if created && store != nil {
						append(&merged.new_globals, New_Global{key, store, body_address, size})
					}
				}
			} else {
				merged.defs[name] = body_address // rodata: object copy takes the new values
			}
		}
	}
	return
}

// Pass B. Resolves one object's symbol indices to addresses. Object-local symbols bind to
// their own copy; the rest read the merged table first, then the exe.
resolve_symbols :: proc(o: ^Loaded_Object, merged: ^Merged, allocator := context.temp_allocator) -> (resolved: []rawptr, unresolved: int) {
	resolved = make([]rawptr, o.view.n_syms, allocator)
	cursor := 0
	for symbol, index in coff_symbols(o.data, o.view.sym_off, o.view.n_syms, &cursor) {
		name := symbol_name(symbol, o.data, o.view.strtab_off)
		section_number := int(symbol.section_number)

		if section_number > 0 && o.section_bases[section_number] != nil {
			section := section_header(o.data, o.view.sec_off, section_number - 1)
			if is_object_local(symbol, name, section) {
				resolved[index] = section_addr(o, section_number, int(symbol.value))
				continue
			}
		}

		if address, found := merged.defs[name]; found {
			resolved[index] = address
		} else if exe_addr, _, exe_found := exe_symbol(name); exe_found {
			resolved[index] = exe_addr
		} else if section_number == 0 {
			unresolved += 1 // an unbound external: foreign import or build mismatch
		}
	}
	return
}

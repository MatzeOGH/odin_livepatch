#+build windows amd64
package livepatch

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

Redirect :: struct {
	exe_address: rawptr,
	body:        rawptr,
	name:        string,
}

Slot_Target :: struct {
	slot: rawptr,
	body: rawptr,
	name: string,
}

Merged :: struct {
	defs:           map[string]rawptr, // defined link name -> live address that references use
	defined:        map[string]bool,   // external names that a patch object defines
	externals:      map[string]rawptr, // undefined name that no object defines -> exe address
	aliases:        map[string]string, // retargeted link name -> its `lp$N` alias
	redirects:      [dynamic]Redirect,
	slot_targets:   [dynamic]Slot_Target,
	new_globals:    [dynamic]string, // writable data that this patch adds
	has_type_table: bool,
	type_table_new: rawptr, // the new build's runtime.type_table slice header, in the DLL
}

merge_symbols :: proc(objects: []Loaded_Object, allocator := context.temp_allocator) -> (merged: Merged) {
	merged.defs = make(map[string]rawptr, allocator)
	merged.defined = make(map[string]bool, allocator)
	merged.externals = make(map[string]rawptr, allocator)
	merged.aliases = make(map[string]string, allocator)
	merged.redirects = make([dynamic]Redirect, allocator)
	merged.slot_targets = make([dynamic]Slot_Target, allocator)
	merged.new_globals = make([dynamic]string, allocator)
	seen := make(map[string]bool, allocator)

	for &o in objects {
		cursor := 0
		for symbol, index in coff_symbols(o.data, o.view.sym_off, o.view.n_syms, &cursor) {
			section_number := int(symbol.section_number)
			name := symbol_name(symbol, o.data, o.view.strtab_off)
			if section_number > 0 && symbol.storage_class == IMAGE_SYM_CLASS_EXTERNAL {
				merged.defined[name] = true
			}
			def_section := section_number
			if section_number == 0 {
				aux := weak_external_aux(o.data, o.view.sym_off, index, symbol) or_continue
				merged.defined[name] = true
				def := coff_symbol(o.data, o.view.sym_off, int(aux.tag_index))
				def_section = int(def.section_number)
			}

			if def_section <= 0 {
				continue // UNDEF with no default, or ABS
			}
			section := section_header(o.data, o.view.sec_off, def_section - 1)
			if is_discarded_section(section) {
				continue
			}

			if section_number > 0 && is_object_local(symbol, name, section) {
				continue
			}
			if strings.has_prefix(name, ".weak.") {
				continue
			}
			if section_name(section) == ".tls$" {
				continue
			}
			if name in seen {
				continue
			}
			seen[name] = true

			if name == "runtime::type_table" {
				merged.has_type_table = true
			}

			characteristics := section.characteristics
			if (characteristics & IMAGE_SCN_MEM_EXECUTE) != 0 {
				// Never redirect the patcher while it runs.
				if strings.has_prefix(name, "livepatch::") {
					if exe_address, found := exe_symbol(name); found {
						merged.defs[name] = exe_address
					}
					continue
				}
				// Do not redirect a procedure with internal linkage
				if symbol.storage_class == IMAGE_SYM_CLASS_STATIC {
					continue
				}
				// A redirect needs 5 bytes for the jmp. Else the procedure gets a slot.
				if exe_address, found := exe_symbol(name); found && exe_room(exe_address) >= 5 {
					merged.defs[name] = exe_address
					append(&merged.redirects, Redirect{exe_address, nil, name})
				} else if slot := slot_for(name); slot != nil {
					merged.defs[name] = slot
					append(&merged.slot_targets, Slot_Target{slot, nil, name})
				}
			} else if (characteristics & IMAGE_SCN_MEM_WRITE) != 0 {
				if symbol.storage_class == IMAGE_SYM_CLASS_STATIC && !strings.contains(name, "::") {
					continue
				}
				if exe_address, found := exe_symbol(name); found {
					merged.defs[name] = exe_address
				} else if live, ok := global_store[canonical_data_name(name)]; ok {
					merged.defs[name] = live
				} else {
					append(&merged.new_globals, name)
				}
			}
		}
	}
	return
}

// Binds each external that no patch object defines
resolve_externals :: proc(objects: []Loaded_Object, merged: ^Merged) -> Error {
	for &o in objects {
		cursor := 0
		for symbol in coff_symbols(o.data, o.view.sym_off, o.view.n_syms, &cursor) {
			if symbol.section_number != 0 || symbol.storage_class != IMAGE_SYM_CLASS_EXTERNAL {
				continue
			}
			name := symbol_name(symbol, o.data, o.view.strtab_off)
			if name in merged.defs || name in merged.defined || name in merged.externals {
				continue
			}
			addr, found := exe_symbol(name)
			if !found {
				addr, found = loaded_export(name)
			}
			if !found {
				return Unresolved_Symbol{error_text(name), error_text(filepath.base(o.path))}
			}
			if !is_near(uintptr(addr)) {
				slot := slot_for(strings.concatenate({"far:", name}, context.temp_allocator))
				if slot == nil {
					return Unresolved_Symbol{error_text(name), error_text(filepath.base(o.path))}
				}
				write_tramp_target(slot, addr)
				addr = slot
			}
			merged.externals[name] = addr
		}
	}
	return nil
}

loaded_export :: proc(name: string) -> (addr: rawptr, ok: bool) {
	if strings.contains(name, "::") {
		return
	}
	modules: [1024]win.HMODULE
	needed: win.DWORD
	if !win.EnumProcessModules(win.GetCurrentProcess(), &modules[0], size_of(modules), &needed) {
		return
	}
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	for m in modules[:min(int(needed) / size_of(win.HMODULE), len(modules))] {
		if p := win.GetProcAddress(m, cname); p != nil {
			return p, true
		}
	}
	return
}

is_near :: proc(addr: uintptr) -> bool {
	LIMIT :: uintptr(0x4000_0000) // 1GB, plus NEAR_WINDOW stays under 2GB
	return abs(int(addr) - int(exe_base())) < int(LIMIT)
}

alias_for :: proc(merged: ^Merged, name: string) -> string {
	if a, ok := merged.aliases[name]; ok {
		return a
	}
	a := fmt.tprintf("lp$%d", len(merged.aliases))
	merged.aliases[name] = a
	return a
}

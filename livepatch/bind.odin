#+build windows amd64, linux amd64
package livepatch

import "core:fmt"
import "core:path/filepath"
import "core:strings"

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

// The GDB JIT interface hook (platform_linux.odin)
JIT_REGISTER_NAME :: "__jit_debug_register_code"

Merged :: struct {
	defs:           map[string]rawptr, // defined link name -> live address that references use
	defined:        map[string]bool,   // external names that a patch object defines
	externals:      map[string]rawptr, // undefined name that no object defines -> exe address
	aliases:        map[string]string, // retargeted link name -> its `lp$N` alias
	redirects:      [dynamic]Redirect,
	slot_targets:   [dynamic]Slot_Target,
	new_globals:    [dynamic]string, // writable data that this patch adds
	has_type_table: bool,
	type_table_new: rawptr, // the new build's runtime.type_table slice header, in the patch module
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
		for symbol in object_symbols(&o, &cursor) {
			name := symbol.name
			if symbol.provides {
				merged.defined[name] = true
			}
			if symbol.kind == .Skipped || symbol.kind == .Undefined {
				continue
			}
			if name in seen {
				continue
			}
			seen[name] = true

			if name == "runtime::type_table" {
				merged.has_type_table = true
			}

			#partial switch symbol.kind {
			case .Code:
				// Never redirect the patcher while it runs, Nor the JIT interface hook
				if strings.has_prefix(name, "livepatch::") || name == JIT_REGISTER_NAME {
					if exe_address, found := exe_symbol(name); found {
						merged.defs[name] = exe_address
					}
					continue
				}
				// Do not redirect a procedure with internal linkage
				if symbol.local {
					continue
				}
				// A redirect needs REDIRECT_SIZE bytes for the jump
				if exe_address, found := exe_symbol(name); found && exe_room(exe_address) >= REDIRECT_SIZE {
					merged.defs[name] = exe_address
					append(&merged.redirects, Redirect{exe_address, nil, name})
				} else if slot := slot_for(name); slot != nil {
					merged.defs[name] = slot
					append(&merged.slot_targets, Slot_Target{slot, nil, name})
				}
			case .Data:
				if symbol.local && !strings.contains(name, "::") {
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
	near_refs: Near_References
	have_near_refs := false
	for &o in objects {
		cursor := 0
		for symbol in object_symbols(&o, &cursor) {
			if symbol.kind != .Undefined {
				continue
			}
			name := symbol.name
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
				if !have_near_refs {
					near_refs, have_near_refs = near_references(objects), true
				}
				if needs_near_address(&near_refs, name) {
					slot := slot_for(strings.concatenate({"far:", name}, context.temp_allocator))
					if slot == nil {
						return Unresolved_Symbol{error_text(name), error_text(filepath.base(o.path))}
					}
					write_tramp_target(slot, addr)
					addr = slot
				}
			}
			merged.externals[name] = addr
		}
	}
	return nil
}

alias_for :: proc(merged: ^Merged, name: string) -> string {
	if a, ok := merged.aliases[name]; ok {
		return a
	}
	a := fmt.tprintf("lp$%d", len(merged.aliases))
	merged.aliases[name] = a
	return a
}

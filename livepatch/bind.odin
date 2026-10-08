#+build windows amd64, linux amd64
package livepatch

import "core:fmt"
import "core:path/filepath"
import "core:strings"

Redirect :: struct {
	from: rawptr, // the exe entry redirects or the slot targets
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
	call_aliases:   map[string]string, // procedure link name -> its `lp$cN` alias, for direct calls
	redirects:      [dynamic]Redirect,
	slot_targets:   [dynamic]Redirect,
	new_globals:    map[string]int, // writable data that this patch adds -> its size, where the object has sizes
	grew:           Global_Grew,    // the first data that is larger than the storage it binds to
	keys:           Static_Keys,    // stable keys of the statics in the patch objects
	type_table_new: rawptr,         // the new build's runtime.type_table slice header, in the patch module
	debug_cells:    map[string]rawptr, // `lp$r<name>` -> live address of kept data, for the debug info (Windows)
}

merge_symbols :: proc(objects: []Loaded_Object, allocator := context.temp_allocator) -> (merged: Merged) {
	merged.defs = make(map[string]rawptr, allocator)
	merged.defined = make(map[string]bool, allocator)
	merged.externals = make(map[string]rawptr, allocator)
	merged.aliases = make(map[string]string, allocator)
	merged.call_aliases = make(map[string]string, allocator)
	merged.redirects = make([dynamic]Redirect, allocator)
	merged.slot_targets = make([dynamic]Redirect, allocator)
	merged.new_globals = make(map[string]int, allocator)
	merged.debug_cells = make(map[string]rawptr, allocator)
	seen :=make(map[string]bool, allocator)

	names := make([dynamic]string, context.temp_allocator)
	for &object in objects {
		cursor := 0
		for symbol in next_object_symbol(&object, &cursor) {
			append(&names, symbol.name)
		}
	}
	merged.keys = static_keys_make(names[:], allocator)

	for &object in objects {
		cursor := 0
		for symbol in next_object_symbol(&object, &cursor) {
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

			#partial switch symbol.kind {
			case .Code:
				// Never redirect the patcher while it runs its procedures and its proc literals, nor the JIT interface hook
				if strings.has_prefix(name, "livepatch::") || strings.contains(name, ANON + "livepatch:") || name == JIT_REGISTER_NAME {
					if exe_address, found := exe_symbol_address(name, merged.keys); found {
						merged.defs[name] = exe_address
					}
					continue
				}
				// Do not redirect a procedure with internal linkage
				if symbol.local {
					continue
				}
				// A redirect needs REDIRECT_SIZE bytes for the jump, in code
				if exe_address, found := exe_symbol_address(name, merged.keys); found && exe_holds_code(uintptr(exe_address)) && exe_room(exe_address) >= REDIRECT_SIZE {
					merged.defs[name] = exe_address
					append(&merged.redirects, Redirect{exe_address, nil, name})
				} else if slot := slot_for(data_key(merged.keys, name)); slot != nil {
					merged.defs[name] = slot
					append(&merged.slot_targets, Redirect{slot, nil, name})
				}
			case .Data:
				// A static of a top-level proc literal has no package prefix
				if symbol.local && !strings.contains(name, "::") && !strings.contains(name, ANON) {
					continue
				}
				// The data of a constant, such as a slice literal or `&T{}`
				if strings.has_prefix(name, "csba$") || strings.has_prefix(name, "ggv$") {
					continue
				}
				// Data that was `@(rodata)` in the exe gets storage of its own: the exe copy is read-only
				storage: rawptr
				if exe_address, found := exe_symbol_address(name, merged.keys); found && exe_holds_variable(uintptr(exe_address)) {
					storage = exe_address
				} else if stored, in_store := global_store[data_key(merged.keys, name)]; in_store {
					storage = stored
				}
				if storage == nil {
					merged.new_globals[name] = symbol.size
					continue
				}
				merged.defs[name] = storage
				// Larger data would write past its storage, into the next variable
				if known := variable_sizes[uintptr(storage)]; known > 0 && symbol.size > known && merged.grew.name == "" {
					merged.grew = {name, known, symbol.size}
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
	for &object in objects {
		cursor := 0
		for symbol in next_object_symbol(&object, &cursor) {
			if symbol.kind != .Undefined {
				continue
			}
			name := symbol.name
			if name in merged.defs || name in merged.defined || name in merged.externals {
				continue
			}
			addr, found := exe_symbol_address(name, merged.keys)
			if !found {
				addr, found = loaded_export(name)
			}
			if !found {
				return Unresolved_Symbol{error_text(name), error_text(filepath.base(object.path))}
			}
			if !is_near(uintptr(addr)) {
				if !have_near_refs {
					near_refs, have_near_refs = find_near_references(objects), true
				}
				if needs_near_address(&near_refs, name) {
					slot := slot_for(strings.concatenate({"far:", name}, context.temp_allocator))
					if slot == nil {
						return Unresolved_Symbol{error_text(name), error_text(filepath.base(object.path))}
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

// The alias `<prefix>N` of a name. The first use makes it.
alias_in :: proc(aliases: ^map[string]string, prefix, name: string) -> string {
	if alias, found := aliases[name]; found {
		return alias
	}
	alias := fmt.tprintf("%s%d", prefix, len(aliases))
	aliases[name] = alias
	return alias
}

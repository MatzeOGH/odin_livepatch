#+build windows
package livepatch

// Global store: a stable, process-lifetime address for every writable data symbol that a
// patch adds. Without it the merge would bind such a symbol to the fresh object copy, so
// it would reset to its initializer on every patch. Keyed by a build-stable name and seeded
// once (seed_new_globals), so the value carries across patches.
//
// Like the jump table, it lives near the exe (Odin reads globals RIP-relative) and is never
// freed.

import "base:intrinsics"
import "core:mem"
import "core:strings"

GLOBAL_BLOCK_SIZE :: 64 * 1024

@(private) Global_Store :: struct {
	entries:       map[string]rawptr,
	current_block: rawptr,
	used:          int,
	block_size:    int,
}

@(private) global_store: Global_Store

// `created` is true on the first sighting of `name`, when the caller must seed the block.
// `addr` is nil if the near window has no room.
// `name` must be the build-stable key from canonical_data_name.
global_for :: proc(name: string, size: int) -> (addr: rawptr, created: bool) {
	if global_store.entries == nil {
		global_store.entries = make(map[string]rawptr)
	}
	if existing, found := global_store.entries[name]; found {
		return existing, false
	}

	// 16-byte bump keeps every start 16-aligned, which covers a typical Odin global.
	need := mem.align_forward_int(size, 16)
	if global_store.current_block == nil || global_store.used + need > global_store.block_size {
		bs := max(GLOBAL_BLOCK_SIZE, mem.align_forward_int(need, PAGE))
		global_store.current_block = alloc_near(exe_base(), bs)
		global_store.used = 0
		global_store.block_size = bs
		if global_store.current_block == nil {
			return nil, false
		}
	}
	addr = rawptr(uintptr(global_store.current_block) + uintptr(global_store.used))
	global_store.used += need

	global_store.entries[strings.clone(name)] = addr
	return addr, true
}

// A build-stable key. An @static local is `pkg::proc-.var-NNNN`, where `-NNNN` is a
// per-build codegen counter, so it is stripped to `pkg::proc-.var`.
canonical_data_name :: proc(name: string) -> string {
	if !strings.contains(name, "-.") {
		return name
	}
	i := strings.last_index_byte(name, '-')
	if i <= 0 || i == len(name) - 1 {
		return name
	}
	for c in name[i + 1:] {
		if c < '0' || c > '9' {
			return name
		}
	}
	return name[:i]
}

// The byte extent of a data symbol, inferred (COFF carries no size) as the gap to the next
// symbol or the section end. An upper bound (trailing padding), safe here.
// ponytail: O(syms) per symbol; a per-section value index would make it O(1).
symbol_extent :: proc(o: ^Loaded_Object, section_number, value: int) -> int {
	sh := section_header(o.data, o.view.sec_off, section_number - 1)
	next := max(int(sh.virtual_size), int(sh.size_of_raw_data))
	cursor := 0
	for sym, _ in coff_symbols(o.data, o.view.sym_off, o.view.n_syms, &cursor) {
		if int(sym.section_number) != section_number {
			continue
		}
		v := int(sym.value)
		if v > value && v < next {
			next = v
		}
	}
	return next - value
}

// Frees the bookkeeping (not the near-exe blocks). Tests only: a live process never resets.
global_reset :: proc() {
	for k in global_store.entries {
		delete(k)
	}
	delete(global_store.entries)
	global_store = {}
}

// Seeds every first-seen store. Runs after relocation, so the source bytes carry final
// addresses. Earlier patches' stores are absent from the list, so they keep their value.
seed_new_globals :: proc(merged: ^Merged) {
	for g in merged.new_globals {
		intrinsics.mem_copy(g.store, g.src, g.size)
	}
}

// Drops the stores a failed patch created, so the next patch seeds them again.
global_forget :: proc(merged: ^Merged) {
	for g in merged.new_globals {
		if g.key in global_store.entries {
			key, _ := delete_key(&global_store.entries, g.key)
			delete(key)
		}
	}
}

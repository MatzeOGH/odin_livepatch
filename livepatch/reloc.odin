#+build windows
package livepatch

// Applies the AMD64 relocations of one mapped object.
//
// A relocation patches a field in the new code or data so it points at a symbol's bound
// address (bind.odin). After the patches, this flushes the icache over the new code and
// registers its unwind data with the OS.

import win "core:sys/windows"

// TODO: move to core:sys/windows
RUNTIME_FUNCTION :: struct {
	begin_address:       u32,
	end_address:         u32,
	unwind_info_address: u32,
}

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	FlushInstructionCache :: proc(hProcess: win.HANDLE, lpBaseAddress: rawptr, dwSize: win.SIZE_T) -> win.BOOL ---
	RtlAddFunctionTable :: proc(FunctionTable: ^RUNTIME_FUNCTION, EntryCount: win.DWORD, BaseAddress: win.DWORD64) -> win.BOOLEAN ---
}

Reloc_Stats :: struct {
	unresolved:  int, // a target address was nil or out of range
	unsupported: int, // an unknown relocation type
}

// `resolved` comes from resolve_symbols.
relocate_object :: proc(o: ^Loaded_Object, resolved: []rawptr) -> (stats: Reloc_Stats) {
	for si in 0 ..< o.view.n_sections {
		base := o.section_bases[si + 1]
		if base == nil {
			continue
		}

		for &rel in section_relocs(o.data, o.view.sec_off, si) {
			site := uintptr(base) + uintptr(rel.virtual_address)
			ty := int(rel.type)

			if ty == IMAGE_REL_AMD64_SECREL {
				// A thread-local reference. The 32-bit field is the variable's offset
				// within the TLS block: its exe address minus the TLS template start. Only
				// an exe-visible thread-local resolves (tls.odin).
				tls_target := resolved[int(rel.symbol_table_index)]
				start, have_tls := tls_template_start()
				if tls_target == nil || !have_tls {
					stats.unresolved += 1
					continue
				}
				off := i64(uintptr(tls_target)) - i64(start)
				if off < 0 || off > i64(max(u32)) {
					stats.unresolved += 1
					continue
				}
				(^u32)(site)^ += u32(off)
				continue
			}

			target := resolved[int(rel.symbol_table_index)]
			if target == nil {
				stats.unresolved += 1
				continue
			}

			switch ty {
			case IMAGE_REL_AMD64_ADDR64:
				// A 64-bit absolute pointer. Add the target to the field's addend.
				(^u64)(site)^ += u64(uintptr(target))

			case IMAGE_REL_AMD64_REL32 ..= IMAGE_REL_AMD64_REL32 + 5:
				// A 32-bit relative reference (a call or RIP-relative access). The
				// displacement runs from the next instruction to the target. REL32_1..5 add
				// 1..5 bytes to that point.
				extra := i64(ty - IMAGE_REL_AMD64_REL32)
				addend := i64((^i32)(site)^)
				next := i64(site) + 4 + extra
				disp := i64(uintptr(target)) + addend - next
				if disp < i64(min(i32)) || disp > i64(max(i32)) {
					// Target more than 2GB away: route through a near-exe jump slot so the
					// rel32 reaches. A safety net; near-exe mapping keeps targets in range.
					// ponytail: assumes a code target (call/jmp) -- a far rip-relative
					// *data* access cannot use a jump slot. Unseen; revisit if it appears.
					usym := coff_symbol(o.data, o.view.sym_off, int(rel.symbol_table_index))
					name := symbol_name(usym, o.data, o.view.strtab_off)
					slot := slot_for(name)
					write_slot_target(slot, target)
					disp = i64(uintptr(slot)) + addend - next
					if disp < i64(min(i32)) || disp > i64(max(i32)) {
						stats.unresolved += 1
						continue
					}
				}
				(^i32)(site)^ = i32(disp)

			case IMAGE_REL_AMD64_ADDR32NB:
				// A 32-bit address relative to the block base (an image RVA), so the target
				// must be inside this object's block. .pdata uses this.
				usym := coff_symbol(o.data, o.view.sym_off, int(rel.symbol_table_index))
				tsn := int(usym.section_number)
				local := target
				if tsn > 0 && o.section_bases[tsn] != nil {
					local = section_addr(o, tsn, int(usym.value))
				}
				addend := i64((^i32)(site)^)
				off := i64(uintptr(local)) - i64(uintptr(o.block))
				if off < 0 || off + addend < 0 || off + addend > i64(o.total) {
					stats.unresolved += 1
				} else {
					(^u32)(site)^ = u32(off + addend)
				}

			case:
				stats.unsupported += 1
			}
		}
	}

	// Flush every code section so the CPU drops any stale icache bytes.
	for si in 0 ..< o.view.n_sections {
		sh := section_header(o.data, o.view.sec_off, si)
		base := o.section_bases[si + 1]
		if base == nil {
			continue
		}
		if (u32(sh.characteristics) & IMAGE_SCN_MEM_EXECUTE) != 0 {
			size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
			FlushInstructionCache(win.GetCurrentProcess(), base, win.SIZE_T(size))
		}
	}

	// Register the .pdata unwind data, so a stack walk through the new code (debugger,
	// crash dump, panic backtrace) is correct.
	for si in 0 ..< o.view.n_sections {
		sh := section_header(o.data, o.view.sec_off, si)
		if section_name(sh) != ".pdata" {
			continue
		}
		base := o.section_bases[si + 1]
		if base == nil {
			continue
		}
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		count := u32(size / size_of(RUNTIME_FUNCTION))
		if count > 0 {
			RtlAddFunctionTable((^RUNTIME_FUNCTION)(base), win.DWORD(count), win.DWORD64(uintptr(o.block)))
		}
	}
	return
}

#+build windows amd64, linux amd64
package livepatch

import "core:mem"
import "core:slice"

MIRROR_DELTA :: uintptr(0x3333332F) // site + 5 + i32(0xCCCCCCCC) == site - MIRROR_DELTA
REDIRECT_SIZE :: 5 // jmp rel32
TRAMP_SIZE :: 32
TRAMP_TARGET :: 24 // offset of the 8-byte target
NEAR_WINDOW :: uintptr(0x3C00_0000) // 960MB

mirror_ok:    bool
mirror_start: uintptr
mirror_end:   uintptr
used_mirror:  map[uintptr]bool // exe addresses whose mirror slot holds a stub for another site

// Call before any other near-exe allocation can take the range.
mirror_init :: proc() {
	base := exe_base()
	size := exe_image_size()
	start := mem.align_backward_uintptr(base - MIRROR_DELTA, 0x10000)
	end := base + size - MIRROR_DELTA + 16
	mirror := page_alloc_at(start, int(end - start), commit = true)
	if mirror != nil && mirror != rawptr(start) {
		page_free(mirror)
		mirror = nil
	}
	mirror_ok = mirror != nil
	if mirror_ok {
		mirror_start, mirror_end = start, end
	}
}

plan_site :: proc(entry: rawptr) -> (planned: Redirect_Site, result: Plan_Result) {
	live_bytes := ([^]u8)(entry)
	pristine: [16]u8
	has_breakpoint: [16]bool
	for i in 0 ..< 16 {
		pristine[i] = live_bytes[i]
		if file_byte, found := exe_file_byte(uintptr(entry) + uintptr(i)); found {
			pristine[i] = file_byte
			has_breakpoint[i] = live_bytes[i] == 0xCC && file_byte != 0xCC
		}
	}

	// A breakpoint on the first byte: keep the first instruction and jmp after it.
	kept_length, stack_undo := 0, 0
	if has_breakpoint[0] {
		keepable: bool
		kept_length, stack_undo, keepable = first_instruction(pristine[:])
		if !keepable {
			return {}, .Breakpoint
		}
	}
	if has_breakpoint[kept_length] || exe_room(entry) < kept_length + 5 {
		return {}, .Breakpoint
	}
	site := rawptr(uintptr(entry) + uintptr(kept_length))
	tramp, have_tramp := alloc_tramp(stack_undo)
	if !have_tramp {
		return {}, .No_Memory
	}

	if !mirror_ok {
		// A plain jmp cannot keep a breakpoint in its displacement.
		if slice.contains(has_breakpoint[kept_length + 1:][:4], true) {
			return {}, .Breakpoint
		}
		rel32 := i64(uintptr(tramp)) - (i64(uintptr(site)) + 5)
		if rel32 < i64(min(i32)) || rel32 > i64(max(i32)) {
			return {}, .No_Memory
		}
		return Redirect_Site{site, tramp, false}, .Ok
	}

	// A stub for each combination of 0xCC and P on the displacement bytes under a breakpoint.
	breakpoint_mask := 0
	for disp_byte in 0 ..< 4 {
		if has_breakpoint[kept_length + 1 + disp_byte] {
			breakpoint_mask |= 1 << uint(disp_byte)
		}
	}
	for variant in 0 ..< 16 {
		if variant & ~breakpoint_mask != 0 {
			continue
		}
		displacement := [4]u8{0xCC, 0xCC, 0xCC, 0xCC}
		for disp_byte in 0 ..< 4 {
			if variant & (1 << uint(disp_byte)) != 0 {
				displacement[disp_byte] = pristine[kept_length + 1 + disp_byte]
			}
		}
		target := uintptr(i64(uintptr(site)) + 5 + i64(transmute(i32)displacement))
		if !place_stub(rawptr(target), tramp, variant != 0) {
			return {}, variant == 0 ? .No_Memory : .Breakpoint
		}
	}
	return Redirect_Site{site, tramp, false}, .Ok
}

// A first instruction that a redirect can keep
first_instruction :: proc(code: []u8) -> (length, undo: int, ok: bool) {
	switch {
	case code[0] == 0xEB && code[1] == 0x00: // jmp +0: LLVM -O0 starts a frameless procedure with it
		return 2, 0, true
	case code[0] == 0x90: // nop
		return 1, 0, true
	case code[0] >= 0x50 && code[0] <= 0x57: // push r64
		return 1, 8, true
	case code[0] == 0x41 && code[1] >= 0x50 && code[1] <= 0x57: // push r8..r15
		return 2, 8, true
	case code[0] == 0x48 && code[1] == 0x83 && code[2] == 0xEC && code[3] < 0x80: // sub rsp, imm8
		return 4, int(code[3]), true
	case code[0] == 0x48 && code[1] == 0x81 && code[2] == 0xEC: // sub rsp, imm32
		frame_size := int((^i32)(&code[3])^)
		return 7, frame_size, frame_size >= 0
	case (code[0] == 0x48 || code[0] == 0x4C) && code[1] == 0x89 && (code[2] & 0xC7) == 0x44 && code[3] == 0x24 && code[4] < 0x80 && code[4] >= 8:
		// mov [rsp+disp8], r64: a spill to the caller's home space. Nothing to undo.
		return 5, 0, true
	}
	return
}

place_stub :: proc(target, tramp: rawptr, variant: bool) -> bool {
	target_addr := uintptr(target)
	if target_addr >= mirror_start && target_addr + 5 <= mirror_end {
		owner := target_addr + MIRROR_DELTA // the exe address whose mirror slot this is
		if variant {
			if near_symbol_start(owner) {
				return false
			}
			for delta in -4 ..= 4 {
				if uintptr(int(owner) + delta) in used_mirror {
					return false
				}
			}
			used_mirror[owner] = true
		}
		rel32 := i64(uintptr(tramp)) - i64(target_addr + 5)
		if rel32 < i64(min(i32)) || rel32 > i64(max(i32)) {
			return false
		}
		write_jmp_rel32(target, tramp)
		return true
	}
	// jmp [rip+0], then the 8-byte target.
	commit_at(target_addr, 14) or_return
	stub := ([^]u8)(target)
	stub[0], stub[1], stub[2], stub[3], stub[4], stub[5] = 0xFF, 0x25, 0, 0, 0, 0
	(^u64)(rawptr(target_addr + 6))^ = u64(uintptr(tramp))
	return true
}

tramp_block: rawptr
tramp_used:  int

// [lea rsp, [rsp+undo]] jmp [tramp+TRAMP_TARGET]
alloc_tramp :: proc(undo := 0) -> (tramp: rawptr, ok: bool) {
	if tramp_block == nil || tramp_used + TRAMP_SIZE > 4096 {
		tramp_block = alloc_near(4096)
		tramp_used = 0
		if tramp_block == nil {
			return
		}
	}
	tramp = rawptr(uintptr(tramp_block) + uintptr(tramp_used))
	tramp_used += TRAMP_SIZE

	code := ([^]u8)(tramp)
	lea_size := 0
	switch {
	case undo == 0:
	case undo < 0x80:
		code[0], code[1], code[2], code[3], code[4] = 0x48, 0x8D, 0x64, 0x24, u8(undo) // lea rsp, [rsp+imm8]
		lea_size = 5
	case:
		code[0], code[1], code[2], code[3] = 0x48, 0x8D, 0xA4, 0x24 // lea rsp, [rsp+imm32]
		(^i32)(&code[4])^ = i32(undo)
		lea_size = 8
	}
	// jmp [rip+rel] to TRAMP_TARGET
	code[lea_size], code[lea_size + 1] = 0xFF, 0x25
	(^i32)(&code[lea_size + 2])^ = i32(TRAMP_TARGET - (lea_size + 6))
	slice.fill(code[lea_size + 6:TRAMP_TARGET], 0xCC)
	(^u64)(rawptr(uintptr(tramp) + TRAMP_TARGET))^ = 0
	return tramp, true
}

write_tramp_target :: proc "contextless" (tramp, body: rawptr) {
	(^u64)(rawptr(uintptr(tramp) + TRAMP_TARGET))^ = u64(uintptr(body))
}

write_site_bytes :: proc "contextless" (redirect_site: Redirect_Site) {
	if mirror_ok {
		code := ([^]u8)(redirect_site.site)
		code[0], code[1], code[2], code[3], code[4] = 0xE9, 0xCC, 0xCC, 0xCC, 0xCC
	} else {
		write_jmp_rel32(redirect_site.site, redirect_site.tramp)
	}
}

write_jmp_rel32 :: proc "contextless" (site, target: rawptr) {
	rel32 := i32(i64(uintptr(target)) - (i64(uintptr(site)) + 5))
	(^u8)(site)^ = 0xE9
	(^i32)(rawptr(uintptr(site) + 1))^ = rel32
}

near_symbol_start :: proc(addr: uintptr) -> bool {
	index, _ := slice.binary_search(exe_starts, addr - 11)
	return index < len(exe_starts) && exe_starts[index] < addr + 5
}

write_sites :: proc(unwritten: []Redirect_Site) {
	for redirect_site in unwritten {
		write_site_bytes(redirect_site)
		flush_icache(redirect_site.site, REDIRECT_SIZE)
	}
}

alloc_near :: proc(size: int, commit := true) -> rawptr {
	exe := exe_base()
	step :: uintptr(0x0010_0000)
	for distance := step; distance <= NEAR_WINDOW; distance += step {
		if exe > distance {
			if mem := page_alloc_at(exe - distance, size, commit); mem != nil {
				return mem
			}
		}
		if distance + uintptr(size) <= NEAR_WINDOW {
			if mem := page_alloc_at(exe + distance, size, commit); mem != nil {
				return mem
			}
		}
	}
	return nil
}

is_near :: proc(addr: uintptr) -> bool {
	LIMIT :: uintptr(0x4000_0000) // 1GB plus NEAR_WINDOW
	return abs(int(addr) - int(exe_base())) < int(LIMIT)
}

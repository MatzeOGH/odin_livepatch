#+build windows amd64
package livepatch

import "base:runtime"
import "core:slice"
import "core:strings"
import win "core:sys/windows"

MIRROR_DELTA :: uintptr(0x3333332F) // site + 5 + i32(0xCCCCCCCC) == site - MIRROR_DELTA

TRAMP_SIZE :: 32
TRAMP_TARGET :: 24 // offset of the 8-byte target

Redirect_Site :: struct {
	site:    rawptr,
	tramp:   rawptr,
	written: bool,
}

@(private) sites:       map[rawptr]Redirect_Site // keyed by the exe entry
@(private) mirror_ok:   bool
@(private) mirror_lo:   uintptr
@(private) mirror_hi:   uintptr
@(private) used_mirror: map[uintptr]bool // exe addresses whose mirror slot holds a stub for another site
@(private) exe_file:    []byte           // the exe file on disk

// Call before any other near-exe allocation can take the range.
mirror_init :: proc() {
	base := exe_base()
	size := uintptr(pe_headers(rawptr(base)).OptionalHeader.SizeOfImage)
	lo := (base - MIRROR_DELTA) & ~uintptr(0xFFFF)
	hi := base + size - MIRROR_DELTA + 16
	m := win.VirtualAlloc(rawptr(lo), win.SIZE_T(hi - lo), win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_EXECUTE_READWRITE)
	if m != nil && m != rawptr(lo) {
		win.VirtualFree(m, 0, win.MEM_RELEASE)
		m = nil
	}
	mirror_ok = m != nil
	if mirror_ok {
		mirror_lo, mirror_hi = lo, hi
	}
}

// Sets up the stubs and the trampoline
prepare_redirects :: proc(merged: ^Merged) -> Error {
	failed := make([dynamic]string, context.temp_allocator)
	for r in merged.redirects {
		if r.exe_address in sites {
			continue
		}
		s, result := plan_site(r.exe_address)
		switch result {
		case .Ok:
			sites[r.exe_address] = s
		case .Breakpoint:
			append(&failed, r.name)
		case .No_Memory:
			return Load_Failed{kind = .No_Stub_Memory}
		}
	}
	if len(failed) > 0 {
		return Breakpoint_In_Redirect{strings.join(failed[:], "\n", runtime.heap_allocator())}
	}
	return nil
}

Plan_Result :: enum {
	Ok,
	Breakpoint,
	No_Memory,
}

plan_site :: proc(entry: rawptr) -> (s: Redirect_Site, result: Plan_Result) {
	live := ([^]u8)(entry)
	pristine: [16]u8
	bp: [16]bool
	for i in 0 ..< 16 {
		pristine[i] = live[i]
		if p, found := exe_file_byte(uintptr(entry) + uintptr(i)); found {
			pristine[i] = p
			bp[i] = live[i] == 0xCC && p != 0xCC
		}
	}

	// A breakpoint on the first byte: keep the first instruction and jmp after it.
	off, undo := 0, 0
	if bp[0] {
		kept: bool
		off, undo, kept = first_instruction(pristine[:])
		if !kept {
			return {}, .Breakpoint
		}
	}
	if bp[off] || exe_room(entry) < off + 5 {
		return {}, .Breakpoint
	}
	site := rawptr(uintptr(entry) + uintptr(off))
	tramp, have_tramp := alloc_tramp(undo)
	if !have_tramp {
		return {}, .No_Memory
	}

	if !mirror_ok {
		// A plain jmp cannot keep a breakpoint in its displacement.
		for k in 1 ..< 5 {
			if bp[off + k] {
				return {}, .Breakpoint
			}
		}
		rel := i64(uintptr(tramp)) - (i64(uintptr(site)) + 5)
		if rel < i64(min(i32)) || rel > i64(max(i32)) {
			return {}, .No_Memory
		}
		return Redirect_Site{site, tramp, false}, .Ok
	}

	// A stub for each combination of 0xCC and P on the displacement bytes under a breakpoint.
	mask := 0
	for k in 0 ..< 4 {
		if bp[off + 1 + k] {
			mask |= 1 << uint(k)
		}
	}
	for m in 0 ..< 16 {
		if m & ~mask != 0 {
			continue
		}
		disp := [4]u8{0xCC, 0xCC, 0xCC, 0xCC}
		for k in 0 ..< 4 {
			if m & (1 << uint(k)) != 0 {
				disp[k] = pristine[off + 1 + k]
			}
		}
		target := uintptr(i64(uintptr(site)) + 5 + i64(transmute(i32)disp))
		if !place_stub(rawptr(target), tramp, m != 0) {
			return {}, m == 0 ? .No_Memory : .Breakpoint
		}
	}
	return Redirect_Site{site, tramp, false}, .Ok
}

// A first instruction that a redirect can keep
first_instruction :: proc(b: []u8) -> (length, undo: int, ok: bool) {
	switch {
	case b[0] == 0xEB && b[1] == 0x00: // jmp +0: LLVM -O0 starts a frameless procedure with it
		return 2, 0, true
	case b[0] == 0x90: // nop
		return 1, 0, true
	case b[0] >= 0x50 && b[0] <= 0x57: // push r64
		return 1, 8, true
	case b[0] == 0x41 && b[1] >= 0x50 && b[1] <= 0x57: // push r8..r15
		return 2, 8, true
	case b[0] == 0x48 && b[1] == 0x83 && b[2] == 0xEC && b[3] < 0x80: // sub rsp, imm8
		return 4, int(b[3]), true
	case b[0] == 0x48 && b[1] == 0x81 && b[2] == 0xEC: // sub rsp, imm32
		n := int((^i32)(&b[3])^)
		return 7, n, n >= 0
	case (b[0] == 0x48 || b[0] == 0x4C) && b[1] == 0x89 && (b[2] & 0xC7) == 0x44 && b[3] == 0x24 && b[4] < 0x80 && b[4] >= 8:
		// mov [rsp+disp8], r64: a spill to the caller's home space. Nothing to undo.
		return 5, 0, true
	}
	return
}

place_stub :: proc(target, tramp: rawptr, variant: bool) -> bool {
	t := uintptr(target)
	if t >= mirror_lo && t + 5 <= mirror_hi {
		a := t + MIRROR_DELTA // the exe address whose mirror slot this is
		if variant {
			if near_symbol_start(a) {
				return false
			}
			for d in -4 ..= 4 {
				if uintptr(int(a) + d) in used_mirror {
					return false
				}
			}
			used_mirror[a] = true
		}
		rel := i64(uintptr(tramp)) - i64(t + 5)
		if rel < i64(min(i32)) || rel > i64(max(i32)) {
			return false
		}
		write_jmp_rel32(target, tramp)
		return true
	}
	// jmp [rip+0], then the 8-byte target.
	if !commit_at(t, 14) {
		return false
	}
	b := ([^]u8)(target)
	b[0], b[1], b[2], b[3], b[4], b[5] = 0xFF, 0x25, 0, 0, 0, 0
	(^u64)(rawptr(t + 6))^ = u64(uintptr(tramp))
	return true
}

// Refuses memory that it did not commit or reserve itself.
commit_at :: proc(t: uintptr, n: int) -> bool {
	for page := t & ~uintptr(0xFFF); page < t + uintptr(n); page += 0x1000 {
		info: win.MEMORY_BASIC_INFORMATION
		if win.VirtualQuery(rawptr(page), &info, size_of(info)) == 0 {
			return false
		}
		granule := page & ~uintptr(0xFFFF)
		switch info.State {
		case win.MEM_COMMIT:
			if page not_in own_pages {
				return false
			}
			continue
		case win.MEM_FREE:
			if win.VirtualAlloc(rawptr(granule), 0x10000, win.MEM_RESERVE, win.PAGE_NOACCESS) == nil {
				return false
			}
			own_granules[granule] = true
		case:
			if granule not_in own_granules {
				return false
			}
		}
		if win.VirtualAlloc(rawptr(page), 0x1000, win.MEM_COMMIT, win.PAGE_EXECUTE_READWRITE) == nil {
			return false
		}
		own_pages[page] = true
	}
	return true
}

own_pages:    map[uintptr]bool
own_granules: map[uintptr]bool // 64KB reservations

tramp_block: rawptr
tramp_used:  int
slots:       map[string]rawptr

slot_for :: proc(name: string) -> rawptr {
	if s, found := slots[name]; found {
		return s
	}
	s, ok := alloc_tramp(0)
	if ok {
		slots[strings.clone(name)] = s
	}
	return s
}

// [lea rsp, [rsp+undo]] jmp [tramp+TRAMP_TARGET]
alloc_tramp :: proc(undo: int) -> (tramp: rawptr, ok: bool) {
	if tramp_block == nil || tramp_used + TRAMP_SIZE > 4096 {
		tramp_block = alloc_near(exe_base(), 4096)
		tramp_used = 0
		if tramp_block == nil {
			return
		}
	}
	tramp = rawptr(uintptr(tramp_block) + uintptr(tramp_used))
	tramp_used += TRAMP_SIZE

	b := ([^]u8)(tramp)
	n := 0
	switch {
	case undo == 0:
	case undo < 0x80:
		b[0], b[1], b[2], b[3], b[4] = 0x48, 0x8D, 0x64, 0x24, u8(undo) // lea rsp, [rsp+imm8]
		n = 5
	case:
		b[0], b[1], b[2], b[3] = 0x48, 0x8D, 0xA4, 0x24 // lea rsp, [rsp+imm32]
		(^i32)(&b[4])^ = i32(undo)
		n = 8
	}
	// jmp [rip+rel] to TRAMP_TARGET
	b[n], b[n + 1] = 0xFF, 0x25
	(^i32)(&b[n + 2])^ = i32(TRAMP_TARGET - (n + 6))
	for i in n + 6 ..< TRAMP_TARGET {
		b[i] = 0xCC
	}
	(^u64)(rawptr(uintptr(tramp) + TRAMP_TARGET))^ = 0
	return tramp, true
}

write_tramp_target :: proc "contextless" (tramp, body: rawptr) {
	(^u64)(rawptr(uintptr(tramp) + TRAMP_TARGET))^ = u64(uintptr(body))
}

write_site_bytes :: proc "contextless" (s: Redirect_Site) {
	if mirror_ok {
		b := ([^]u8)(s.site)
		b[0], b[1], b[2], b[3], b[4] = 0xE9, 0xCC, 0xCC, 0xCC, 0xCC
	} else {
		write_jmp_rel32(s.site, s.tramp)
	}
}

write_jmp_rel32 :: proc "contextless" (at, target: rawptr) {
	rel := i32(i64(uintptr(target)) - (i64(uintptr(at)) + 5))
	(^u8)(at)^ = 0xE9
	(^i32)(rawptr(uintptr(at) + 1))^ = rel
}

// The bytes up to the next symbol or the section end.
exe_room :: proc(entry: rawptr) -> int {
	a := uintptr(entry)
	room := section_end(a) - int(a)
	i, _ := slice.binary_search(exe_starts, a + 1)
	if i < len(exe_starts) {
		room = min(room, int(exe_starts[i] - a))
	}
	return max(room, 0)
}

near_symbol_start :: proc(a: uintptr) -> bool {
	i, _ := slice.binary_search(exe_starts, a - 11)
	return i < len(exe_starts) && exe_starts[i] < a + 5
}

section_end :: proc(a: uintptr) -> int {
	base := exe_base()
	for &sh in pe_sections(rawptr(base)) {
		va := base + uintptr(sh.virtual_address)
		if a >= va && a < va + uintptr(sh.virtual_size) {
			return int(va + uintptr(sh.virtual_size))
		}
	}
	return int(a)
}

// A breakpoint is a 0xCC in memory where the file has another byte
exe_file_byte :: proc(a: uintptr) -> (b: u8, ok: bool) {
	if len(exe_file) == 0 {
		return
	}
	rva := a - exe_base()
	for &sh in pe_sections(raw_data(exe_file)) {
		va := uintptr(sh.virtual_address)
		if rva >= va && rva < va + uintptr(sh.virtual_size) {
			off := int(sh.pointer_to_raw_data) + int(rva - va)
			if off < len(exe_file) {
				return exe_file[off], true
			}
			return
		}
	}
	return
}

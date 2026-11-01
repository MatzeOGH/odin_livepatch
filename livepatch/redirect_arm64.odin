#+build darwin arm64
package livepatch

import "core:mem"
import "core:slice"

REDIRECT_SIZE :: 4

BRANCH_REACH :: uintptr(126 << 20) // reaches ±128MB, keep a 2MB margin
MODULE_REACH :: uintptr(2 << 30)
VENEERS_PER_BLOCK :: int(PAGE_SIZE) / size_of(Veneer)
LDR_X16_TARGET :: u32(0x5800_0000) | u32(PAGE_SIZE / 4) << 5 | 16 // ldr x16, #PAGE_SIZE
LDR_X16_UNDO   :: LDR_X16_TARGET - 1 << 5                          // ldr x16, #(PAGE_SIZE - 4)
BR_X16         :: u32(0xD61F_0200)                               // br x16
NOP            :: u32(0xD503_201F)
BRK_MASK       :: u32(0xFFE0_001F)
BRK            :: u32(0xD420_0000) // brk #imm16, the breakpoint of a debugger

ADD_IMM_64 :: u32(0b1_0_0_100010) // add (immediate), 64-bit
SUB_IMM_64 :: u32(0b1_1_0_100010) // sub (immediate), 64-bit
STP_PRE_64 :: u32(0b10_101_0_011_0) // stp (pre-index), 64-bit registers
SP         :: u32(31)

Veneer :: struct {
	ldr, br: u32,
}

// A trampoline that first undoes the instruction that a breakpoint site keeps. Its target
// is PAGE_SIZE after its start, as for a Veneer.
Undo_Veneer :: struct {
	undo, ldr, br: u32,
}

Branch :: bit_field u32 {
	imm26: i32 | 26,
	op:    u32 | 6,
}

Add_Sub_Imm :: bit_field u32 {
	rd:     u32 | 5,
	rn:     u32 | 5,
	imm12:  u32 | 12,
	shift:  u32 | 1,
	opcode: u32 | 9,
}

Stp_Pre_Index :: bit_field u32 {
	rt:     u32 | 5,
	rn:     u32 | 5,
	rt2:    u32 | 5,
	imm7:   i32 | 7,
	opcode: u32 | 10,
}

trampoline_block: rawptr
trampoline_used:  int

mirror_init :: proc() {}

alloc_module :: proc(size: int) -> rawptr {
	return alloc_near(size, commit = false, reach = MODULE_REACH, from = BRANCH_REACH / 2)
}

plan_site :: proc(entry: rawptr) -> (planned: Redirect_Site, result: Plan_Result) {
	site := entry
	trampoline: rawptr
	ok: bool
	if first, found := breakpoint_at(uintptr(entry)); found {
		// A debugger breakpoint on the entry. The debugger steps over it with the first
		// instruction and writes that instruction back when it removes the breakpoint. So keep
		// the first instruction, branch after it, and undo it in the trampoline.
		// Note: a loop back to entry+4 would run the undo again. LLVM changes the stack
		// before any loop, and other first instructions are not kept.
		undo, keepable := undo_of(first)
		_, second := breakpoint_at(uintptr(entry) + 4)
		if !keepable || second || exe_room(entry) < 8 {
			return {}, .Breakpoint
		}
		site = rawptr(uintptr(entry) + 4)
		trampoline, ok = alloc_undo_trampoline(undo)
	} else {
		trampoline, ok = alloc_trampoline()
	}
	if !ok {
		return {}, .No_Memory
	}
	assert(abs(i64(uintptr(trampoline)) - i64(uintptr(site))) < 1 << 27) // alloc_near keeps tramps in BRANCH_REACH
	return Redirect_Site{site = site, trampoline = trampoline, call = entry}, .Ok
}

// The instruction in the exe file at `address` when a debugger breakpoint replaces it in memory
breakpoint_at :: proc(address: uintptr) -> (instruction: u32, found: bool) {
	live := (^u32)(address)^
	if live & BRK_MASK != BRK {
		return
	}
	for i in uintptr(0) ..< 4 {
		file_byte := exe_file_byte(address + i) or_return
		instruction |= u32(file_byte) << (8 * i)
	}
	return instruction, instruction != live // a brk that the exe has is code, not a breakpoint
}

// The instruction that undoes the stack change of `instruction`, the first one of a procedure.
// keepable is false when that change cannot be undone.
undo_of :: proc(instruction: u32) -> (undo: u32, keepable: bool) {
	if instruction == NOP {
		return NOP, true
	}
	sub := transmute(Add_Sub_Imm)instruction
	if sub.opcode == SUB_IMM_64 && sub.rd == SP && sub.rn == SP {
		sub.opcode = ADD_IMM_64
		return transmute(u32)sub, true
	}
	stp := transmute(Stp_Pre_Index)instruction
	if stp.opcode == STP_PRE_64 && stp.rn == SP && stp.imm7 < 0 {
		return transmute(u32)Add_Sub_Imm{rd = SP, rn = SP, imm12 = u32(-stp.imm7 * 8), opcode = ADD_IMM_64}, true
	}
	return
}

// Note: two pages for each site with a breakpoint, which is rare. Use blocks as
// alloc_trampoline does if many are needed.
alloc_undo_trampoline :: proc(undo: u32) -> (trampoline: rawptr, ok: bool) {
	memory := alloc_near(2 * int(PAGE_SIZE))
	if memory == nil {
		return
	}
	(^Undo_Veneer)(memory)^ = {undo, LDR_X16_UNDO, BR_X16}
	if !make_executable(memory, int(PAGE_SIZE)) {
		page_free(memory)
		return
	}
	return memory, true
}

alloc_trampoline :: proc() -> (trampoline: rawptr, ok: bool) {
	if trampoline_block == nil || trampoline_used == VENEERS_PER_BLOCK {
		memory := alloc_near(2 * int(PAGE_SIZE))
		if memory == nil {
			return
		}
		slice.fill(([^]Veneer)(memory)[:VENEERS_PER_BLOCK], Veneer{LDR_X16_TARGET, BR_X16})
		if !make_executable(memory, int(PAGE_SIZE)) {
			page_free(memory)
			return
		}
		trampoline_block, trampoline_used = memory, 0
	}
	trampoline = &([^]Veneer)(trampoline_block)[trampoline_used]
	trampoline_used += 1
	return trampoline, true
}

trampoline_cell :: proc "contextless" (trampoline: rawptr) -> ^rawptr {
	return (^rawptr)(uintptr(trampoline) + PAGE_SIZE)
}

write_trampoline_target :: proc "contextless" (trampoline, body: rawptr) {
	trampoline_cell(trampoline)^ = body
}

got_cell_for :: proc(key: string, address: rawptr) -> rawptr {
	slot := slot_for(key)
	if slot == nil {
		return nil
	}
	write_trampoline_target(slot, address)
	return trampoline_cell(slot)
}

site_word :: proc "contextless" (redirect_site: Redirect_Site) -> u32 {
	distance := i64(uintptr(redirect_site.trampoline)) - i64(uintptr(redirect_site.site))
	return transmute(u32)Branch{imm26 = i32(distance >> 2), op = 0b000101}
}

write_sites :: proc(unwritten: []rawptr) -> bool {
	unwritten := unwritten
	slice.sort(unwritten) // the key is the entry: the site is the entry or the word after it
	for len(unwritten) > 0 {
		page := mem.align_backward_uintptr(uintptr(sites[unwritten[0]].site), PAGE_SIZE)
		page_sites := 1
		for page_sites < len(unwritten) && mem.align_backward_uintptr(uintptr(sites[unwritten[page_sites]].site), PAGE_SIZE) == page {
			page_sites += 1
		}
		replace_code_page(page, unwritten[:page_sites]) or_return
		for key in unwritten[:page_sites] {
			(&sites[key]).written = true
		}
		unwritten = unwritten[page_sites:]
	}
	return true
}

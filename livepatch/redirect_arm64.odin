#+build darwin arm64
package livepatch

import "core:mem"
import "core:slice"

REDIRECT_SIZE :: 4

BRANCH_REACH :: uintptr(126 << 20) // reaches ±128MB, keep a 2MB margin
MODULE_REACH :: uintptr(2 << 30)
VENEERS_PER_BLOCK :: int(PAGE_SIZE) / size_of(Veneer)
LDR_X16_TARGET :: u32(0x5800_0000) | u32(PAGE_SIZE / 4) << 5 | 16 // ldr x16, #PAGE_SIZE
BR_X16         :: u32(0xD61F_0200)                               // br x16

Veneer :: struct {
	ldr, br: u32,
}

Branch :: bit_field u32 {
	imm26: i32 | 26,
	op:    u32 | 6,
}

tramp_block: rawptr
tramp_used:  int

mirror_init :: proc() {}

alloc_module :: proc(size: int) -> rawptr {
	return alloc_near(size, commit = false, reach = MODULE_REACH, from = BRANCH_REACH / 2)
}

plan_site :: proc(entry: rawptr) -> (planned: Redirect_Site, result: Plan_Result) {
	tramp, ok := alloc_tramp()
	if !ok {
		return {}, .No_Memory
	}
	assert(abs(i64(uintptr(tramp)) - i64(uintptr(entry))) < 1 << 27) // alloc_near keeps tramps in BRANCH_REACH
	return Redirect_Site{site = entry, tramp = tramp, call = entry}, .Ok
}

alloc_tramp :: proc() -> (tramp: rawptr, ok: bool) {
	if tramp_block == nil || tramp_used == VENEERS_PER_BLOCK {
		memory := alloc_near(2 * int(PAGE_SIZE))
		if memory == nil {
			return
		}
		slice.fill(([^]Veneer)(memory)[:VENEERS_PER_BLOCK], Veneer{LDR_X16_TARGET, BR_X16})
		if !make_executable(memory, int(PAGE_SIZE)) {
			page_free(memory)
			return
		}
		tramp_block, tramp_used = memory, 0
	}
	tramp = &([^]Veneer)(tramp_block)[tramp_used]
	tramp_used += 1
	return tramp, true
}

tramp_cell :: proc "contextless" (tramp: rawptr) -> ^rawptr {
	return (^rawptr)(uintptr(tramp) + PAGE_SIZE)
}

write_tramp_target :: proc "contextless" (tramp, body: rawptr) {
	tramp_cell(tramp)^ = body
}

got_cell_for :: proc(key: string, addr: rawptr) -> rawptr {
	slot := slot_for(key)
	if slot == nil {
		return nil
	}
	write_tramp_target(slot, addr)
	return tramp_cell(slot)
}

site_word :: proc "contextless" (redirect_site: Redirect_Site) -> u32 {
	distance := i64(uintptr(redirect_site.tramp)) - i64(uintptr(redirect_site.site))
	return transmute(u32)Branch{imm26 = i32(distance >> 2), op = 0b000101}
}

write_sites :: proc(unwritten: []rawptr) -> bool {
	unwritten := unwritten
	slice.sort(unwritten) // the key is the site
	for len(unwritten) > 0 {
		page := mem.align_backward_uintptr(uintptr(unwritten[0]), PAGE_SIZE)
		page_sites := 1
		for page_sites < len(unwritten) && mem.align_backward_uintptr(uintptr(unwritten[page_sites]), PAGE_SIZE) == page {
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

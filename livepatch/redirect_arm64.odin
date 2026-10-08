#+build darwin arm64
package livepatch

import "core:mem"
import "core:slice"

REDIRECT_SIZE :: 4

BRANCH_REACH :: uintptr(126 << 20) // 128MB
VENEER_SIZE :: 8
VENEERS_PER_BLOCK :: int(PAGE_SIZE) / VENEER_SIZE
LDR_X16_TARGET :: u32(0x5800_0000) | u32(PAGE_SIZE / 4) << 5 | 16 // ldr x16, #PAGE_SIZE
BR_X16         :: u32(0xD61F_0200)                               // br x16

tramp_block: uintptr
tramp_used:  int

mirror_init :: proc() {}

near_range :: proc() -> (lo, hi: uintptr, ok: bool) {
	size := exe_image_size()
	if size >= BRANCH_REACH {
		return
	}
	window := (BRANCH_REACH - size) / 2
	lo = exe_base() > window ? exe_base() - window : 0
	return lo, exe_base() + size + window, true
}

is_near :: proc(addr: uintptr) -> bool {
	lo, hi, ok := near_range()
	return ok && addr >= lo && addr < hi
}

alloc_near :: proc(size: int, commit := true) -> rawptr {
	lo, hi, ok := near_range()
	if !ok {
		return nil
	}
	STEP :: uintptr(0x0010_0000)
	rounded := mem.align_forward_uintptr(uintptr(size), PAGE_SIZE)
	top := mem.align_forward_uintptr(exe_base() + exe_image_size(), PAGE_SIZE)
	bottom := mem.align_backward_uintptr(exe_base(), PAGE_SIZE)
	for offset := uintptr(0); ; offset += STEP {
		tried := false
		if above := top + offset; above + rounded <= hi {
			tried = true
			if memory := page_alloc_at(above, size, commit); memory != nil {
				return memory
			}
		}
		if bottom >= offset + rounded && bottom - offset - rounded >= lo {
			tried = true
			if memory := page_alloc_at(bottom - offset - rounded, size, commit); memory != nil {
				return memory
			}
		}
		if !tried {
			return nil
		}
	}
}

#+build windows
package livepatch

// Jump table: a stable address for every procedure with no exe entry to redirect.
//
// A procedure added by a patch, or one whose exe body is under 5 bytes, cannot be reached
// by overwriting an exe entry. It gets a 16-byte slot instead, and every relocation against
// that name targets the slot. The patch step writes the slot's absolute target to the
// newest copy, so older generations reach the newest body and procedure pointers compare
// equal across patches.
//
// The table lives for the whole process and is never freed.

import "core:strings"

SLOT_SIZE  :: 16
BLOCK_SIZE :: 4096 // one near-exe block holds 256 slots

// Process-lifetime jump table. `slots` owns its keys.
@(private) Jump_Table :: struct {
	slots:          map[string]rawptr,
	current_block:  rawptr,
	used_in_block:  int,
}

@(private) jump_table: Jump_Table

// The stable slot address for a link name.
slot_for :: proc(name: string) -> rawptr {
	if jump_table.slots == nil {
		jump_table.slots = make(map[string]rawptr)
	}
	if existing, found := jump_table.slots[name]; found {
		return existing
	}

	if jump_table.current_block == nil || jump_table.used_in_block + SLOT_SIZE > BLOCK_SIZE {
		jump_table.current_block = alloc_near(exe_base(), BLOCK_SIZE)
		jump_table.used_in_block = 0
	}
	slot := rawptr(uintptr(jump_table.current_block) + uintptr(jump_table.used_in_block))
	jump_table.used_in_block += SLOT_SIZE

	// jmp qword ptr [rip+0]
	stub := ([^]u8)(slot)
	stub[0], stub[1], stub[2], stub[3], stub[4], stub[5] = 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00
	(^u64)(uintptr(slot) + 6)^ = 0
	stub[14], stub[15] = 0xCC, 0xCC

	jump_table.slots[strings.clone(name)] = slot
	return slot
}

// Writes a slot's 8-byte absolute target.
write_slot_target :: proc "contextless" (slot, target: rawptr) {
	(^u64)(uintptr(slot) + 6)^ = u64(uintptr(target))
}

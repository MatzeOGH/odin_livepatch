#+build darwin arm64
package livepatch

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_find_linker :: proc(t: ^testing.T) {
	path, ok := find_linker()
	log.infof("find_linker: %q ok=%v", path, ok)
	testing.expect(t, ok, "ld64.lld is found")
	if !ok {
		return
	}
	testing.expect(t, strings.contains(path, "/"), "the linker path is a path, not a bare name")
	testing.expect(t, os.exists(path), "the linker file exists")

	again, ok_again := find_linker()
	testing.expect(t, ok_again, "the second call finds the linker")
	testing.expect_value(t, again, path) // cached
}

@(test)
test_undo_of :: proc(t: ^testing.T) {
	undo, keepable := undo_of(0xD100_C3FF) // sub sp, sp, #0x30
	testing.expect(t, keepable)
	testing.expect_value(t, undo, u32(0x9100_C3FF)) // add sp, sp, #0x30
	undo, keepable = undo_of(0xD140_07FF) // sub sp, sp, #1, lsl #12
	testing.expect(t, keepable)
	testing.expect_value(t, undo, u32(0x9140_07FF)) // add sp, sp, #1, lsl #12
	undo, keepable = undo_of(0xA9BF_7BFD) // stp x29, x30, [sp, #-16]!
	testing.expect(t, keepable)
	testing.expect_value(t, undo, u32(0x9100_43FF)) // add sp, sp, #16
	undo, keepable = undo_of(NOP)
	testing.expect(t, keepable)
	testing.expect_value(t, undo, NOP)
	_, keepable = undo_of(0x9100_03FD) // mov x29, sp: changes a register
	testing.expect(t, !keepable)
	_, keepable = undo_of(0xD100_C3E0) // sub x0, sp, #0x30: changes an argument
	testing.expect(t, !keepable)
}

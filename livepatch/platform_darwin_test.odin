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

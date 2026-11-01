#+build darwin arm64
package livepatch

import "core:log"
import "core:testing"

@(test)
test_macho_object :: proc(t: ^testing.T) {
	merged: Merged
	merged.externals = make(map[string]rawptr, context.temp_allocator)
	merged.externals["test_external"] = rawptr(uintptr(0x1234_5678))
	merged.externals["test_other"] = rawptr(uintptr(0x9_8765_4320))
	data := absolute_symbols_object(&merged)
	log.infof("absolute_symbols_object: %d bytes", len(data))

	object, ok := parse_object("lp_abs.o", data)
	testing.expect(t, ok, "the object parses")
	if !ok {
		return
	}
	testing.expect_value(t, object.view.header.filetype, MH_OBJECT)
	testing.expect_value(t, len(object.view.sections), 1)
	testing.expect_value(t, len(object.view.symbols), 1 + len(merged.externals))

	found := make(map[string]bool, context.temp_allocator)
	cursor := 0
	for symbol in next_object_symbol(object, &cursor) {
		log.infof("  next_object_symbol: %-20s kind=%v local=%v provides=%v size=%d", symbol.name, symbol.kind, symbol.local, symbol.provides, symbol.size)
		found[symbol.name] = true
		switch symbol.name {
		case ENTRY_SYMBOL:
			testing.expect_value(t, symbol.kind, Symbol_Kind.Code)
			testing.expect(t, symbol.provides, "the entry symbol is a definition")
			testing.expect(t, !symbol.local, "the entry symbol is external")
		case "test_external", "test_other":
			testing.expect_value(t, symbol.kind, Symbol_Kind.Skipped) // absolute
		}
	}
	testing.expect(t, found[ENTRY_SYMBOL], "the object has the entry symbol")
	testing.expect(t, found["test_external"], "the object has test_external")
	testing.expect(t, found["test_other"], "the object has test_other")
	for symbol in object.view.symbols {
		name := macho_symbol_name(object.view, symbol)
		if want, is_external := merged.externals[name]; is_external {
			testing.expect_value(t, symbol.n_type & N_TYPE, N_ABS)
			testing.expect_value(t, symbol.n_value, u64(uintptr(want)))
		}
	}
	testing.expect(t, object_max_image_size(object) > 0, "the object needs room in the image")
}


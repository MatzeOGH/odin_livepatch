#+build darwin arm64
package livepatch

// Run: odin test livepatch -use-separate-modules -define:ODIN_TEST_LOG_LEVEL=debug -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

@(thread_local) test_thread_local: int

test_probe: u8

// Not file-private: that would add `[macho_test.odin]::` to its link name
test_generic :: proc(x: $T) -> T {
	return x * 2
}

@(test)
test_macho_exe :: proc(t: ^testing.T) {
	test_thread_local = 1 // keeps the variable in the exe

	exe_path, path_err := os.get_executable_path(context.temp_allocator)
	testing.expect_value(t, path_err, nil)
	data, read_err := os.read_entire_file_from_path(exe_path, context.temp_allocator)
	testing.expect_value(t, read_err, nil)
	log.infof("exe: %s, %d bytes", exe_path, len(data))

	view, ok := macho_parse(data)
	testing.expect(t, ok, "the exe parses")
	if !ok {
		return
	}
	log_view(view)
	testing.expect_value(t, view.header.magic, MH_MAGIC_64)
	testing.expect_value(t, view.header.filetype, MH_EXECUTE)
	testing.expect_value(t, view.header.cputype, CPU_TYPE_ARM64)
	testing.expect(t, view.symtab != nil, "the exe has LC_SYMTAB")
	testing.expect(t, view.dysymtab != nil, "the exe has LC_DYSYMTAB")
	testing.expect(t, len(view.syms) > 0, "the exe has a symbol table")
	testing.expect(t, len(view.segments) == int(count_commands(data, view, LC_SEGMENT_64)), "each LC_SEGMENT_64 is in segments")

	has_page_zero, has_text := false, false
	for segment in view.segments {
		if fixed_name(&segment.segname) == "__PAGEZERO" {
			has_page_zero = true
			testing.expect_value(t, segment.initprot, 0)
		}
	}
	for section in view.sections {
		if fixed_name(&section.segname) == "__TEXT" && fixed_name(&section.sectname) == "__text" {
			has_text = true
			testing.expect(t, macho_is_code(section), "__TEXT,__text holds code")
			bytes, bytes_ok := macho_section_bytes(data, section)
			testing.expect(t, bytes_ok && len(bytes) == int(section.size), "the bytes of __TEXT,__text are in the file")
		}
	}
	testing.expect(t, has_page_zero, "the exe has __PAGEZERO")
	testing.expect(t, has_text, "the exe has __TEXT,__text")

	probe_value: uintptr
	for sym in view.syms {
		if macho_symbol_section(view, sym) != nil && macho_raw_name(view, sym) == "_livepatch::test_probe" {
			probe_value = uintptr(sym.n_value)
			testing.expect_value(t, macho_symbol_name(view, sym), "livepatch::test_probe")
			testing.expect(t, !macho_is_temporary(macho_raw_name(view, sym)), "a name with _ is not a temporary")
		}
	}
	testing.expect(t, probe_value != 0, "the exe has the symbol _livepatch::test_probe")
	slide := uintptr(&test_probe) - probe_value
	log.infof("slide: 0x%x (live &test_probe 0x%x - n_value 0x%x)", slide, uintptr(&test_probe), probe_value)

	symbols := read_macho_symbols(view, slide, allocator = context.temp_allocator)
	log.infof("read_macho_symbols: %d keys, %d starts", len(symbols.symbols), len(symbols.starts))
	for key, addr in symbols.symbols {
		if strings.has_prefix(key, "livepatch::") {
			log.debugf("  symbol %-50s 0x%x", key, addr)
		}
	}

	expect_address(t, symbols.symbols, "livepatch::test_probe", uintptr(&test_probe))
	expect_address(t, symbols.symbols, "livepatch::test_macho_exe", uintptr(rawptr(test_macho_exe)))
	expect_address(t, symbols.symbols, "livepatch::macho_parse", uintptr(rawptr(macho_parse)))

	instances := 0
	testing.expect_value(t, test_generic(1), 2)
	testing.expect_value(t, test_generic(1.5), 3.0)
	for key, addr in symbols.symbols {
		if strings.has_prefix(key, "livepatch::test_generic") {
			log.infof("generic instance %s 0x%x", key, addr)
			instances += 1
		}
	}
	testing.expect_value(t, instances, 2)
	testing.expect(t, len(symbols.starts) >= len(symbols.symbols), "each symbol has a start")
	testing.expect_value(t, slide & (0x4000 - 1), 0)

	if dysymtab := view.dysymtab; dysymtab != nil {
		testing.expect_value(t, len(symbols.starts), int(dysymtab.nlocalsym + dysymtab.nextdefsym))
	}

	// Each 24-byte TLV descriptor in __thread_vars has a key
	for section in view.sections {
		if section.flags & SECTION_TYPE != S_THREAD_LOCAL_VARIABLES {
			continue
		}
		start := slide + uintptr(section.addr)
		descriptors := 0
		for key, addr in symbols.symbols {
			if addr >= start && addr < start + uintptr(section.size) {
				log.debugf("  TLV descriptor %-42s 0x%x", key, addr)
				descriptors += 1
			}
		}
		log.infof("__thread_vars: 0x%x bytes = %d descriptors, %d found", section.size, section.size / 24, descriptors)
		testing.expect_value(t, descriptors, int(section.size / 24))
		descriptor, found := symbols.symbols["livepatch::test_thread_local"]
		testing.expect(t, found && descriptor >= start && descriptor < start + uintptr(section.size), "the thread-local has a TLV descriptor")
	}

	// Only compiler helpers have internal linkage under -use-separate-modules, so only they repeat
	addresses := make(map[string]uintptr, context.temp_allocator)
	ambiguous := make(map[string]int, context.temp_allocator)
	for sym in view.syms {
		raw := macho_raw_name(view, sym)
		if macho_symbol_section(view, sym) == nil || macho_is_temporary(raw) {
			continue
		}
		name := macho_symbol_name(view, sym)
		if addr, found := addresses[name]; found && addr != uintptr(sym.n_value) {
			ambiguous[name] += 1
		}
		addresses[name] = uintptr(sym.n_value)
	}
	for name, extra in ambiguous {
		log.debugf("  ambiguous %-60s %d more definitions", name, extra)
		testing.expect(t, name not_in symbols.symbols, "an ambiguous name has no key")
		testing.expectf(t, strings.has_prefix(name, "__$"), "only compiler helpers repeat, but %s does", name)
	}
	log.infof("%d names, %d of them ambiguous", len(addresses), len(ambiguous))

	for section in view.sections {
		start := uintptr(section.addr)
		if macho_is_code(section) && uintptr(rawptr(test_macho_exe)) - slide >= start && uintptr(rawptr(test_macho_exe)) - slide < start + uintptr(section.size) {
			bytes, _ := macho_section_bytes(data, section)
			offset := int(uintptr(rawptr(test_macho_exe)) - slide - start)
			file_word := (^u32)(&bytes[offset])^
			live_word := (^u32)(rawptr(test_macho_exe))^
			log.infof("first instruction of test_macho_exe: file 0x%08x, live 0x%08x", file_word, live_word)
			testing.expect_value(t, live_word, file_word)
		}
	}
}

@(test)
test_macho_rejects :: proc(t: ^testing.T) {
	_, short_ok := macho_parse([]byte{0xCF, 0xFA})
	log.infof("2 bytes: parsed=%v", short_ok)
	testing.expect(t, !short_ok, "refuses data shorter than a header")

	header := Mach_Header_64{magic = MH_MAGIC_64, cputype = 0x0100_0007} // x86-64
	_, x64_ok := macho_parse(([^]byte)(&header)[:size_of(header)])
	log.infof("x86-64 header: parsed=%v", x64_ok)
	testing.expect(t, !x64_ok, "refuses x86-64")

	header.cputype = CPU_TYPE_ARM64
	header.magic = 0xFEED_FACE // 32-bit
	_, magic_ok := macho_parse(([^]byte)(&header)[:size_of(header)])
	log.infof("32-bit magic: parsed=%v", magic_ok)
	testing.expect(t, !magic_ok, "refuses a 32-bit Mach-O")

	header.magic = MH_MAGIC_64
	header.ncmds = 1
	header.sizeofcmds = 1 << 20 // past the end of the data
	_, bad_ok := macho_parse(([^]byte)(&header)[:size_of(header)])
	log.infof("load commands past the end: parsed=%v", bad_ok)
	testing.expect(t, !bad_ok, "refuses load commands past the end")

	header.ncmds = 0
	header.sizeofcmds = 0
	empty, empty_ok := macho_parse(([^]byte)(&header)[:size_of(header)])
	log.infof("header with no load commands: parsed=%v segments=%d sections=%d", empty_ok, len(empty.segments), len(empty.sections))
	testing.expect(t, empty_ok, "accepts a header with no load commands")
}

log_view :: proc(view: Macho_View) {
	header := view.header
	log.infof("header: magic=0x%x cputype=0x%x filetype=%d ncmds=%d sizeofcmds=%d flags=0x%x",
		header.magic, header.cputype, header.filetype, header.ncmds, header.sizeofcmds, header.flags)
	for segment in view.segments {
		log.infof("  segment %-16s vmaddr=0x%x vmsize=0x%x fileoff=0x%x filesize=0x%x initprot=%d maxprot=%d nsects=%d",
			fixed_name(&segment.segname), segment.vmaddr, segment.vmsize, segment.fileoff, segment.filesize,
			segment.initprot, segment.maxprot, segment.nsects)
	}
	for section, index in view.sections {
		log.infof("    section %2d %s,%-20s addr=0x%x size=0x%x offset=0x%x align=%d nreloc=%d type=0x%x flags=0x%x code=%v thread_local=%v",
			index + 1, fixed_name(&section.segname), fixed_name(&section.sectname), section.addr, section.size, section.offset,
			section.align, section.nreloc, section.flags & SECTION_TYPE, section.flags, macho_is_code(section), macho_is_thread_local(section))
	}
	if symtab := view.symtab; symtab != nil {
		log.infof("  LC_SYMTAB: nsyms=%d symoff=0x%x strsize=%d stroff=0x%x", symtab.nsyms, symtab.symoff, symtab.strsize, symtab.stroff)
	}
	if dysymtab := view.dysymtab; dysymtab != nil {
		log.infof("  LC_DYSYMTAB: locals %d+%d, external definitions %d+%d, undefined %d+%d, indirect %d",
			dysymtab.ilocalsym, dysymtab.nlocalsym, dysymtab.iextdefsym, dysymtab.nextdefsym,
			dysymtab.iundefsym, dysymtab.nundefsym, dysymtab.nindirectsyms)
	}
	if build := view.build; build != nil {
		log.infof("  LC_BUILD_VERSION: platform=%d minos=%d.%d.%d sdk=%d.%d.%d", build.platform,
			build.minos >> 16, (build.minos >> 8) & 0xFF, build.minos & 0xFF, build.sdk >> 16, (build.sdk >> 8) & 0xFF, build.sdk & 0xFF)
	}
	MAX_LOGGED :: 40
	for sym, index in view.syms {
		if index == MAX_LOGGED {
			log.debugf("  ... %d more symbols", len(view.syms) - MAX_LOGGED)
			break
		}
		log.debugf("  nlist %4d %-50s type=0x%02x sect=%d desc=0x%x value=0x%x", index, macho_raw_name(view, sym), sym.n_type, sym.n_sect, sym.n_desc, sym.n_value)
	}
}

count_commands :: proc(data: []byte, view: Macho_View, cmd: u32) -> (count: u32) {
	offset := size_of(Mach_Header_64)
	for _ in 0 ..< view.header.ncmds {
		command := (^Load_Command)(raw_data(data[offset:]))
		if command.cmd == cmd {
			count += 1
		}
		offset += int(command.cmdsize)
	}
	return
}

expect_address :: proc(t: ^testing.T, symbols: map[string]uintptr, key: string, want: uintptr, loc := #caller_location) {
	got, found := symbols[key]
	log.infof("%-30s found=%v got=0x%x want=0x%x", key, found, got, want)
	testing.expect(t, found, key, loc = loc)
	testing.expect_value(t, got, want, loc = loc)
}

#+build linux amd64
package livepatch

classify_relocation :: proc "contextless" (rela_type: u32) -> Relocation_Class {
	switch rela_type {
	case R_X86_64_NONE, R_X86_64_DTPOFF64, R_X86_64_DTPMOD64, R_X86_64_TPOFF64:
		return .Ignored
	case R_X86_64_GOTTPOFF, R_X86_64_TLSGD, R_X86_64_TLSLD, R_X86_64_DTPOFF32, R_X86_64_TPOFF32:
		return .Thread_Local
	}
	return .Other
}

is_rel32_reference :: proc "contextless" (rela_type: u32) -> bool {
	return rela_type == R_X86_64_PLT32 || rela_type == R_X86_64_PC32
}

reference_target_offset :: proc(rela_type: u32, addend: i64, code: []byte, site: int) -> i64 {
	switch rela_type {
	case R_X86_64_PC32, R_X86_64_PLT32, R_X86_64_GOTPCREL, R_X86_64_GOTPCRELX, R_X86_64_REX_GOTPCRELX:
		return addend + 4 + i64(rip_operand_immediate_size(code, site))
	}
	return addend
}

// The bytes between a RIP-relative displacement at `site` and the end of its instruction
rip_operand_immediate_size :: proc(code: []byte, site: int) -> int {
	if site < 2 || site > len(code) {
		return 0
	}
	modrm := code[site - 1]
	if modrm & 0xC7 != 0x05 {
		return 0 // not a [rip+disp32] operand
	}
	opcode := code[site - 2]
	if site >= 4 && code[site - 4] == 0x0F && code[site - 3] == 0x3A {
		return 1 // 0F 3A: every opcode takes an imm8
	}
	if site >= 3 && code[site - 3] == 0x0F {
		switch opcode {
		case 0x70 ..= 0x73, 0xA4, 0xAC, 0xBA, 0xC2, 0xC4 ..= 0xC6:
			return 1
		}
		return 0
	}
	// A 0x66 prefix, possibly before a REX prefix, makes a 32-bit immediate 16-bit.
	prefix_pos := site - 3
	if prefix_pos >= 0 && code[prefix_pos] >= 0x40 && code[prefix_pos] <= 0x4F {
		prefix_pos -= 1
	}
	imm32_size := 4
	if prefix_pos >= 0 && code[prefix_pos] == 0x66 {
		imm32_size = 2
	}
	modrm_reg := (modrm >> 3) & 7
	switch opcode {
	case 0x80, 0x82, 0x83, 0xC0, 0xC1, 0xC6, 0x6B:
		return 1
	case 0x81, 0xC7, 0x69:
		return imm32_size
	case 0xF6:
		return modrm_reg <= 1 ? 1 : 0 // test
	case 0xF7:
		return modrm_reg <= 1 ? imm32_size : 0 // test
	}
	return 0
}

// Rewrites the thread-local access at relas[rela_index] to local-exec
rewrite_tls_to_local_exec :: proc(rewrite: ^Elf_Rewrite, code: []byte, relas: []Elf64_Rela, rela_index: int) -> (ok: bool) {
	rela := &relas[rela_index]
	view := &rewrite.object.view
	rela_type := elf_rela_type(rela.info)
	symbol_index := int(elf_rela_symbol_index(rela.info))
	site := int(rela.offset)

	// The call to __tls_get_addr that follows a TLSGD or TLSLD
	drop_tls_get_addr_call :: proc(relas: []Elf64_Rela, rela_index: int, call_site: int) -> bool {
		for later in rela_index + 1 ..< len(relas) {
			if int(relas[later].offset) == call_site {
				relas[later].info = elf_rela_info(0, R_X86_64_NONE)
				return true
			}
		}
		return false
	}
	is_section := elf_symbol_type(view.syms[symbol_index].info) == STT_SECTION

	switch rela_type {
	case R_X86_64_GOTTPOFF:
		// mov/add reg, [rip+x@gottpoff]  ->  mov/add reg, imm32
		if site < 3 || site + 4 > len(code) {
			return
		}
		tp_offset := thread_pointer_offset(rewrite, symbol_index, is_section ? rela.addend + 4 : 0) or_return
		rex, opcode, modrm := &code[site - 3], &code[site - 2], &code[site - 1]
		if (rex^ != 0x48 && rex^ != 0x4C) || modrm^ & 0xC7 != 0x05 {
			return
		}
		switch opcode^ {
		case 0x8B: opcode^ = 0xC7 // mov r/m64, imm32
		case 0x03: opcode^ = 0x81 // add r/m64, imm32
		case:      return
		}
		if rex^ == 0x4C {
			rex^ = 0x49 // the register moves from ModRM.reg to ModRM.rm
		}
		modrm^ = 0xC0 | (modrm^ >> 3) & 7
		(^i32)(&code[site])^ = tp_offset

	case R_X86_64_TLSGD:
		// lea rdi, [rip+x@tlsgd]; call __tls_get_addr  ->  mov rax, fs:0; lea rax, [rax+x@tpoff]
		// The call is `call __tls_get_addr@PLT` (66 66 48 e8), or, from LLVM 20 on,
		// `call *__tls_get_addr@GOTPCREL(%rip)` (66 48 ff 15). Both are 16 bytes with the lea.
		if site < 4 || site + 12 > len(code) || string(code[site - 4:site]) != "\x66\x48\x8d\x3d" {
			return
		}
		if call := string(code[site + 4:site + 8]); call != "\x66\x66\x48\xe8" && call != "\x66\x48\xff\x15" {
			return
		}
		tp_offset := thread_pointer_offset(rewrite, symbol_index, is_section ? rela.addend + 4 : 0) or_return
		drop_tls_get_addr_call(relas, rela_index, site + 8) or_return
		copy(code[site - 4:], "\x64\x48\x8b\x04\x25\x00\x00\x00\x00\x48\x8d\x80")
		(^i32)(&code[site + 8])^ = tp_offset

	case R_X86_64_TLSLD:
		// lea rdi, [rip+x@tlsld]; call __tls_get_addr  ->  mov rax, fs:0
		// With `call *__tls_get_addr@GOTPCREL(%rip)` (ff 15) the sequence is a byte longer.
		if site < 3 || site + 9 > len(code) || string(code[site - 3:site]) != "\x48\x8d\x3d" {
			return
		}
		switch {
		case code[site + 4] == 0xE8:
			drop_tls_get_addr_call(relas, rela_index, site + 5) or_return
			copy(code[site - 3:], "\x66\x66\x66\x64\x48\x8b\x04\x25\x00\x00\x00\x00")
		case site + 10 <= len(code) && code[site + 4] == 0xFF && code[site + 5] == 0x15:
			drop_tls_get_addr_call(relas, rela_index, site + 6) or_return
			copy(code[site - 3:], "\x66\x66\x66\x66\x64\x48\x8b\x04\x25\x00\x00\x00\x00")
		case:
			return
		}

	case R_X86_64_DTPOFF32, R_X86_64_TPOFF32:
		// After the TLSLD rewrite, rax is the thread pointer, so x@dtpoff becomes x@tpoff.
		if site + 4 > len(code) {
			return
		}
		tp_offset := thread_pointer_offset(rewrite, symbol_index, rela.addend) or_return
		(^i32)(&code[site])^ = tp_offset
	}
	rela.info = elf_rela_info(0, R_X86_64_NONE)
	return true
}

#+build linux amd64, darwin arm64
package livepatch

@(require) import "core:sync"

// The GDB JIT interface
when LIVEPATCH {

	Jit_Code_Entry :: struct {
		next_entry:   ^Jit_Code_Entry,
		prev_entry:   ^Jit_Code_Entry,
		symfile_addr: rawptr,
		symfile_size: u64,
	}

	Jit_Descriptor :: struct {
		version:        u32,
		action_flag:    u32,
		relevant_entry: ^Jit_Code_Entry,
		first_entry:    ^Jit_Code_Entry,
	}

	@(export, link_name = "__jit_debug_descriptor")
	jit_debug_descriptor := Jit_Descriptor{version = 1}

	@(export, link_name = "__jit_debug_register_code")
	jit_debug_register_code :: proc "c" () {
		sync.atomic_signal_fence(.Seq_Cst)
	}

	register_with_debugger :: proc(symfile: []byte) {
		entry := new(Jit_Code_Entry)
		entry^ = {next_entry = jit_debug_descriptor.first_entry, symfile_addr = raw_data(symfile), symfile_size = u64(len(symfile))}
		if entry.next_entry != nil {
			entry.next_entry.prev_entry = entry
		}
		jit_debug_descriptor.first_entry = entry
		jit_debug_descriptor.relevant_entry = entry
		jit_debug_descriptor.action_flag = 1
		jit_debug_register_code()
	}

} else {

	register_with_debugger :: proc(symfile: []byte) {}

}

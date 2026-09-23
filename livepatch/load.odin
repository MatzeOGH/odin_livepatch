#+build windows
package livepatch

// Loading patch objects into memory near the exe.
//
// Each object's kept sections are copied into a single block reserved within +/-2GB of the
// exe, so the new code can reach exe procedures (and be reached) with 32-bit relative
// displacements. The block is never freed: old generations must stay live.
//
// Trust model: objects are the output of a same-session `odin build -build-mode:obj`, so
// they are trusted. coff_parse still rejects a non-AMD64 or malformed file.

import "base:intrinsics"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

PAGE :: 0x1000

// One patch object mapped near the exe. `data` and the two bookkeeping slices are freed by
// unload_object; `block` is deliberately not freed.
Loaded_Object :: struct {
	path:          string,
	data:          []byte,
	view:          Coff_View,
	block:         rawptr,
	total:         int,
	// Indexed by 1-based COFF section number; index 0 unused. nil for a section
	// that was skipped (discarded or empty) or for UNDEF/ABS symbols (section 0).
	section_bases: []rawptr,
	offsets:       []int, // block-relative offset per section, or -1 if skipped
}

exe_base :: proc() -> uintptr {
	return uintptr(win.GetModuleHandleW(nil))
}

// Blocks stay within +/-NEAR_WINDOW of the exe, so a rel32 reaches between any two.
NEAR_WINDOW :: uintptr(0x3C00_0000) // 960MB

// Reserves executable memory near the exe, probing outward in 1MB steps. nil if full.
alloc_near :: proc(near: uintptr, size: int) -> rawptr {
	step :: uintptr(0x0010_0000)
	sz := win.SIZE_T(size)
	for off := step; off <= NEAR_WINDOW; off += step {
		if near > off {
			if m := win.VirtualAlloc(rawptr(near - off), sz, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE); m != nil {
				return m
			}
		}
		if off + uintptr(size) <= NEAR_WINDOW {
			if m := win.VirtualAlloc(rawptr(near + off), sz, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE); m != nil {
				return m
			}
		}
	}
	return nil
}

// Reads one COFF object and copies its kept sections into a single near-exe block. On
// failure everything allocated is freed and ok is false. The near block is never freed.
map_object :: proc(path: string, allocator := context.allocator) -> (o: Loaded_Object, ok: bool) {
	data, rerr := os.read_entire_file_from_path(path, allocator)
	if rerr != nil {
		return
	}
	view := coff_parse(data) or_return
	if view.n_sections == 0 {
		delete(data, allocator)
		return
	}

	o.path = path
	o.data = data
	o.view = view
	o.section_bases = make([]rawptr, view.n_sections + 1, allocator)
	o.offsets = make([]int, view.n_sections + 1, allocator)

	// Lay kept sections out page-aligned; -1 marks a section we do not map.
	total := 0
	for i in 0 ..< view.n_sections {
		sh := section_header(data, view.sec_off, i)
		size := max(int(sh.virtual_size), int(sh.size_of_raw_data))
		if size == 0 || is_discarded_section(sh) {
			o.offsets[i + 1] = -1
			continue
		}
		total = mem.align_forward_int(total, PAGE)
		o.offsets[i + 1] = total
		total += size
	}
	total = mem.align_forward_int(total, PAGE)
	o.total = total

	o.block = alloc_near(exe_base(), total)
	if o.block == nil {
		unload_object(&o, allocator)
		return
	}

	// Copy raw bytes in; .bss stays zero (VirtualAlloc zero-fills). Record each base.
	for i in 0 ..< view.n_sections {
		if o.offsets[i + 1] < 0 {
			continue
		}
		sh := section_header(data, view.sec_off, i)
		base := rawptr(uintptr(o.block) + uintptr(o.offsets[i + 1]))
		o.section_bases[i + 1] = base

		raw := int(sh.pointer_to_raw_data)
		n := int(sh.size_of_raw_data)
		if n > 0 && raw != 0 {
			if raw < len(data) {
				n = min(n, len(data) - raw) // never read past the buffer even if a header lied
				intrinsics.mem_copy(base, raw_data(data[raw:]), n)
			}
		}
	}
	return o, true
}

// Maps every .obj in a directory. The objects stay mapped as a set, so the merge can
// resolve a symbol UNDEF in one against another's copy. `ok` is false if any step fails.
map_all :: proc(dir: string, allocator := context.allocator) -> (objs: []Loaded_Object, ok: bool) {
	entries, read_err := os.read_all_directory_by_path(dir, allocator)
	if read_err != nil {
		return
	}
	defer os.file_info_slice_delete(entries, allocator)

	loaded := make([dynamic]Loaded_Object, allocator)
	for entry in entries {
		if entry.type == .Directory || !strings.has_suffix(entry.name, ".obj") {
			continue
		}
		path := filepath.join({dir, entry.name}, allocator) or_continue
		object, mapped := map_object(path, allocator)
		if !mapped {
			delete(path, allocator)
			return
		}
		append(&loaded, object)
	}
	return loaded[:], true
}

unload_object :: proc(o: ^Loaded_Object, allocator := context.allocator) {
	delete(o.data, allocator)
	delete(o.section_bases, allocator)
	delete(o.offsets, allocator)
	o^ = {}
}

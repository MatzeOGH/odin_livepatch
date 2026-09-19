#+build windows
package livepatch

// Pre and post patch hooks for state migration.
//
// A patch that changes a type's layout leaves live instances in the old layout. The app
// registers a migration procedure and the patcher calls it around the switch, with the
// changed types from the type diff (typediff.odin). Hooks run while other process threads
// are paused, so they must not allocate, block, or take a lock another thread could hold.
//
// Discovery needs no compiler change: the app puts a procedure pointer into a fixed
// section, and the linker coalesces that section from every object into one array.
//
//     @(link_section="lp_pre",  export) _pre  := my_pre_hook
//     @(link_section="lp_post", export) _post := my_post_hook
//
// @(export) is required, or the compiler drops the pointer as unreferenced. The pointer
// is the exe entry the commit redirects, so a pre hook runs the current body and a post
// hook the new one. A hook added by a patch is not in the section and does not fire.

import "base:runtime"
import win "core:sys/windows"

// A type whose layout changed in this patch. `old` points into the exe's current type-info
// array, `new` into the new build's. A post hook reads old-layout instances through `old`
// and writes new-layout through `new`.
Type_Change :: struct {
	name: string,
	old:  ^runtime.Type_Info,
	new:  ^runtime.Type_Info,
}

Patch_Hook :: proc(changed: []Type_Change)

// Reads the hook pointers from a named section of the loaded image, a linker-coalesced
// array of Patch_Hook pointers. The name must be 8 characters or fewer (PE section
// headers truncate longer names). Returns an empty slice if absent.
find_hooks_in_exe :: proc(section: string) -> []Patch_Hook {
	base := uintptr(win.GetModuleHandleW(nil))
	if base == 0 {
		return nil
	}
	e_lfanew := (^i32)(rawptr(base + 0x3c))^
	nt := base + uintptr(e_lfanew)
	// After the 4-byte signature: IMAGE_FILE_HEADER NumberOfSections at +2,
	// SizeOfOptionalHeader at +16. The section table follows the optional header.
	num_sections := int((^u16)(rawptr(nt + 4 + 2))^)
	size_opt := uintptr((^u16)(rawptr(nt + 4 + 16))^)
	sec := nt + 4 + 20 + size_opt

	for i in 0 ..< num_sections {
		// IMAGE_SECTION_HEADER is 40 bytes: Name[8], VirtualSize(4), VirtualAddress(4).
		sh := sec + uintptr(i * 40)
		raw := (^[8]u8)(rawptr(sh))^
		n := 0
		for n < 8 && raw[n] != 0 {
			n += 1
		}
		if string(raw[:n]) != section {
			continue
		}
		vsize := int((^u32)(rawptr(sh + 8))^)
		va := uintptr((^u32)(rawptr(sh + 12))^)
		ptr := ([^]Patch_Hook)(rawptr(base + va))
		return ptr[:vsize / size_of(rawptr)]
	}
	return nil
}

fire_hooks :: proc(hooks: []Patch_Hook, changed: []Type_Change) {
	for cb in hooks {
		if cb != nil {
			cb(changed)
		}
	}
}

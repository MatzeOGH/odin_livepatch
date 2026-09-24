#+build windows amd64
package livepatch

find_hooks_in_exe :: proc(section: string) -> []Patch_Hook {
	base := exe_base()
	for &sh in pe_sections(rawptr(base)) {
		if section_name(&sh) == section {
			ptr := ([^]Patch_Hook)(rawptr(base + uintptr(sh.virtual_address)))
			return ptr[:int(sh.virtual_size) / size_of(rawptr)]
		}
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

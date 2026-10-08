#+build windows amd64, linux amd64, darwin arm64
package livepatch

find_hooks_in_exe :: proc(section: string) -> []Patch_Hook {
	if addr, size, found := exe_section_named(section); found {
		ptr := ([^]Patch_Hook)(rawptr(addr))
		return ptr[:size / size_of(rawptr)]
	}
	return nil
}

fire_hooks :: proc(hooks: []Patch_Hook, changed: []Type_Change) {
	for hook in hooks {
		if hook != nil {
			hook(changed)
		}
	}
}

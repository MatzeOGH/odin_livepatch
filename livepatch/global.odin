#+build windows amd64
package livepatch

import "core:strings"

global_store: map[string]rawptr

global_register :: proc(key: string, addr: rawptr) {
	if key not_in global_store {
		global_store[strings.clone(key)] = addr
	}
}

canonical_data_name :: proc(name: string) -> string {
	base := strings.trim_right(name, "0123456789")
	if len(base) < len(name) && strings.has_suffix(base, "-") && strings.contains(base, "-.") {
		return base[:len(base) - 1]
	}
	return name
}

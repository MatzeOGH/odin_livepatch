#+build windows amd64, linux amd64, darwin arm64
package livepatch

import "core:strings"

global_store: map[string]rawptr // stable key data_key live address

global_register :: proc(key: string, address: rawptr, size: int) {
	if key != "" && key not_in global_store {
		global_store[strings.clone(key)] = address
		if size > 0 {
			variable_sizes[uintptr(address)] = size
		}
	}
}

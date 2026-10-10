#+build windows amd64, linux amd64
package livepatch

import "core:strings"

Symbol_Kind :: enum {
	Skipped,   // not bound: absolute, debug, object-local, discarded, thread-local, or read-only
	Undefined, // a reference that this object does not define
	Code,
	Data,      // writable data
}

Object_Symbol :: struct {
	name:     string,
	kind:     Symbol_Kind,
	local:    bool, // internal linkage
	provides: bool, // a definition, strong or a weak default, that other objects can bind to
	size:     int,  // in bytes. 0 when the object format has no sizes (COFF)
}

// A procedure that the startup code calls to set the globals of one module: `__$startup_runtime$<N>`.
// On Windows its code is the default of a weak external, `.weak.__$startup_runtime$<N>.default.<x>`.
is_global_init_proc :: proc(name: string) -> bool {
	PREFIX :: "__$startup_runtime$"
	proc_name := strings.trim_prefix(name, ".weak.")
	return strings.has_prefix(proc_name, PREFIX) && len(proc_name) > len(PREFIX) && proc_name[len(PREFIX)] >= '0' && proc_name[len(PREFIX)] <= '9'
}

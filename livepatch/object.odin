#+build windows amd64
package livepatch

Symbol_Kind :: enum {
	Skipped,   // not bound: absolute, debug, object-local, discarded, or thread-local
	Undefined, // a reference that this object does not define
	Code,
	Data,      // writable data
	Read_Only, // other defined data
}

Object_Symbol :: struct {
	name:     string,
	kind:     Symbol_Kind,
	local:    bool, // internal linkage
	provides: bool, // a definition, strong or a weak default, that other objects can bind to
}

package main

// v3 adds a third local type named Local, in this file

when VERSION >= 3 {
	size_c :: proc() -> int {
		Local :: struct { c: [3]f64 }
		return type_info_of(Local).size
	}
}

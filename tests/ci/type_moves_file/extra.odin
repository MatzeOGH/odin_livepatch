package main

// From v3 on, Thing is in this file

when VERSION >= 3 {
	Thing :: struct { a, b, c: int }
}

package main

// From v3 on, the @(private) declarations of main.odin are in this file

when VERSION >= 3 {
	@(private) private_proc :: proc(x: int) -> int { return VERSION * 1000 + x }
	@(private) private_static :: proc() -> int {
		@(static) n: int
		n += 1
		return VERSION * 1000 + n
	}
	@(private) private_global := 0
	@(private, thread_local) private_tls: int
}

package main

// A file-private helper and total, with the names of the public ones in main.odin

@(private = "file") helper :: proc() -> int {
	return VERSION * 1000 + 2
}

@(private = "file") total: int

private_helper :: proc() -> proc() -> int {
	return helper
}

private_total_set :: proc(n: int) {
	total = n
}

bump_private :: proc() -> int {
	total += 10
	return total
}

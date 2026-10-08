package other

// A second package with a map[int]int, for the test in the directory above

VERSION :: #config(VERSION, 1)

counts: map[int]int

bump :: proc(key: int) -> int {
	counts[key] += VERSION * 10
	return counts[key]
}

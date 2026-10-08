#!/usr/bin/env python3
# Writes procs.odin: N procedures of three shapes, the table of pointers to them that the exe
# stores, and direct calls. The output is checked in, so the test does not need Python. Run
# this only to change N or the shapes.
import os

N = 300

def proc(i):
    name = f"p{i:03d}"
    # Three shapes, so the procedures differ in size. Each returns x + VERSION * 1000 + i.
    if i % 3 == 0:
        return f"{name} :: proc(x: int) -> int {{\n\treturn x + VERSION * 1000 + {i}\n}}\n"
    if i % 3 == 1:
        return (f"{name} :: proc(x: int) -> int {{\n\ts := x\n\tfor j in 0 ..< 3 {{\n\t\ts += j\n\t}}\n"
                f"\treturn s + VERSION * 1000 + {i - 3}\n}}\n")
    return (f"{name} :: proc(x: int) -> int {{\n\tswitch x {{\n\tcase 0:\n\t\treturn VERSION * 1000 + {i}\n"
            f"\tcase:\n\t\treturn x + VERSION * 1000 + {i}\n\t}}\n}}\n")

with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "procs.odin"), "w", newline="\n") as f:
    f.write("package main\n\n// Written by gen.py.\n\n")
    f.write(f"N :: {N}\n\n")
    f.write("\n".join(proc(i) for i in range(N)))
    f.write("\n// The addresses of the procedures of the exe, stored before the first patch\n")
    f.write("table := [N]proc(x: int) -> int{\n")
    f.writelines(f"\tp{i:03d},\n" for i in range(N))
    f.write("}\n\n// Calls each procedure directly\nsum_direct :: proc() -> (sum: int) {\n")
    f.writelines(f"\tsum += p{i:03d}(1)\n" for i in range(N))
    f.write("\treturn\n}\n")

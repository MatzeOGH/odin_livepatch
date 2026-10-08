#!/bin/sh
# Runs app under gdb: three patches, a stop in each, and the values that gdb must read there.
# Each breakpoint is set before the program starts, on a procedure that only one patch has. Run
# build.sh first. Without gdb, the test is skipped, except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
GDB=${GDB:-gdb}
if ! command -v "$GDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  gdb not found"; exit 1; fi
	echo "  skipped: gdb not found"
	exit 0
fi
cd "$DIR" || exit 1

# gdb learns of each patch through its JIT interface. patch() stops the other threads with
# signal 62, which gdb must give to the program. Each breakpoint prints a marker line and what
# it reads, then continues. Frame 1 (up) is the patched caller. loop_v3 stops only when its
# argument i (rdi) is 5. The global counter is in the exe.
cat > gdb_commands.txt << 'EOF'
set pagination off
set breakpoint pending on
handle SIG62 nostop noprint pass
break main::stop_v2
commands
silent
echo STOP v2\n
backtrace 6
up
info locals
print (long)'main::counter'
continue
end
break main::loop_v3 if $rdi == 5
commands
silent
echo STOP v3 loop\n
info registers rdi
up
info locals
continue
end
break main::stop_v3
commands
silent
echo STOP v3 end\n
up
info locals
print (long)'main::counter'
continue
end
break main::stop_v4
commands
silent
echo STOP v4\n
backtrace 3
up
info args
info locals
continue
end
run
EOF
"$GDB" --batch --nx -x gdb_commands.txt ./app > gdb.log 2>&1
cat gdb.log

failed=0
# Passes when at least $3 (default 1) lines of the log match the extended regex $2
expect() {
	found=$(grep -Ec -- "$2" gdb.log)
	if [ "$found" -ge "${3:-1}" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (found $found of ${3:-1})"; failed=1; fi
}
# A local, an argument, or the frame of a patched caller: optimized code removes values and
# inlines callers. Checked at -o:none only.
expect_unoptimized() {
	if [ "${OPT:-none}" != none ]; then echo "  SKIP  $1 (-o:$OPT)"; else expect "$@"; fi
}
echo 'v2: a struct, a global, the call stack'
expect             'stopped in stop_v2'                 '^#0 +main::stop_v2 '
expect_unoptimized 'struct local p'                     '^p = \{x = 3, y = 6\}$'
expect_unoptimized 'local total'                        '^total = 9$'
expect             'global counter, before the update'  '^\$[0-9]+ = 5$'
expect_unoptimized 'scene_v2 in the stack'              '^#1 .*main::scene_v2 '
expect_unoptimized 'drive in the stack'                 '^#[0-9]+ .*main::drive '
expect             'main of the exe in the stack'       '^#[0-9]+ .*main::main '
echo 'v3: a conditional breakpoint in a loop, an array, the global as v2 left it'
expect             'stopped once in the loop'           '^STOP v3 loop$'
expect             'loop variable i, as the argument'   '^rdi +0x5 +5$'
expect_unoptimized 'sum so far'                         '^sum = 15$'
expect             'stopped after the loop'             '^STOP v3 end$'
expect_unoptimized 'array values'                       '^values = \{66, 1, 14\}$'
expect_unoptimized 'local total'                        '^total = 67$'
expect             'global counter, as v2 left it'      '^\$[0-9]+ = 14$'
echo 'v4: a procedure that only this patch has, with a string argument'
expect             'stopped in stop_v4'                 '^#0 +main::stop_v4 '
expect_unoptimized 'added_helper in the stack'          '^#1 .*main::added_helper '
expect_unoptimized 'argument n'                         '^n = 3$'
expect_unoptimized 'string argument label'              '^label = \{data = 0x[0-9a-f]+ "four", len = 4\}$'
expect_unoptimized 'local doubled'                      '^doubled = 12$'
expect             'the program finished'               'ALL OK'
expect             'it exited normally'                 'exited normally'
loops=$(grep -c '^STOP v3 loop$' gdb.log)
if [ "$loops" -ne 1 ]; then echo "  FAIL  the loop breakpoint stopped $loops times, not 1"; failed=1; fi
exit $failed

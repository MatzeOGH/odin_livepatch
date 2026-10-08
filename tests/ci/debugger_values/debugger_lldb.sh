#!/bin/sh
# Runs app under lldb: three patches, a stop in each, and the values that lldb must read there.
# Each breakpoint is set before the program starts, on a procedure that only one patch has. Run
# build.sh first. Without lldb, the test is skipped, except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
LLDB=${LLDB:-lldb}
if ! command -v "$LLDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  lldb not found"; exit 1; fi
	echo "  skipped: lldb not found"
	exit 0
fi
cd "$DIR" || exit 1

# lldb learns of each patch through the GDB JIT interface, which is off by default. patch()
# stops the other threads with signal 62, which lldb must give to the program. lldb reads
# main::stop_v2 as a C++ scope, so the breakpoints are regexes. Each breakpoint prints what it
# reads, then continues (-G true). Frame 1 is the patched caller. loop_v3 stops only when its
# argument i (rdi) is 5. The global counter is in the exe.
cat > lldb_commands.txt << 'EOF'
settings set plugin.jit-loader.gdb.enable on
breakpoint set -r ^main::stop_v2$ -G true -C "thread backtrace --count 6" -C "frame select 1" -C "frame variable" -C "target variable counter"
breakpoint set -r ^main::loop_v3$ -c "$rdi == 5" -G true -C "register read rdi" -C "frame select 1" -C "frame variable"
breakpoint set -r ^main::stop_v3$ -G true -C "frame select 1" -C "frame variable" -C "target variable counter"
breakpoint set -r ^main::stop_v4$ -G true -C "thread backtrace --count 3" -C "frame select 1" -C "frame variable"
process launch --stop-at-entry
process handle 62 --stop false --notify false --pass true
continue
EOF
"$LLDB" --batch -s lldb_commands.txt -- ./app > lldb.log 2>&1
cat lldb.log

failed=0
# Passes when at least $3 (default 1) lines of the log match the extended regex $2
expect() {
	found=$(grep -Ec -- "$2" lldb.log)
	if [ "$found" -ge "${3:-1}" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (found $found of ${3:-1})"; failed=1; fi
}
# A local, an argument, or the frame of a patched caller: optimized code removes values and
# inlines callers. Checked at -o:none only.
expect_unoptimized() {
	if [ "${OPT:-none}" != none ]; then echo "  SKIP  $1 (-o:$OPT)"; else expect "$@"; fi
}
echo 'v2: a struct, a global, the call stack'
expect             'stopped in stop_v2'                 'frame #0: .*main::stop_v2'
expect_unoptimized 'struct local p'                     ' p = \(x = 3, y = 6\)$'
expect_unoptimized 'local total'                        ' total = 9$'
expect             'global counter, before the update'  ' counter = 5$'
expect_unoptimized 'scene_v2 in the stack'              'frame #1: .*main::scene_v2'
expect_unoptimized 'drive in the stack'                 'frame #[0-9]+: .*main::drive'
expect             'main of the exe in the stack'       'frame #[0-9]+: .*main::main'
echo 'v3: a conditional breakpoint in a loop, an array, the global as v2 left it'
expect             'loop variable i, as the argument'   'rdi = 0x0+5$'
expect_unoptimized 'sum so far'                         ' sum = 15$'
expect_unoptimized 'array values'                       ' values = \(\[0\] = 66, \[1\] = 1, \[2\] = 14\)$'
expect_unoptimized 'local total'                        ' total = 67$'
expect             'global counter, as v2 left it'      ' counter = 14$'
echo 'v4: a procedure that only this patch has, with a string argument'
expect             'stopped in stop_v4'                 'frame #0: .*main::stop_v4'
expect_unoptimized 'added_helper in the stack'          'frame #1: .*main::added_helper'
expect_unoptimized 'argument n'                         ' n = 3$'
expect_unoptimized 'string argument label'              'label = \(data = "four", len = 4\)$'
expect_unoptimized 'local doubled'                      ' doubled = 12$'
expect             'the program finished'               'ALL OK'
expect             'it exited normally'                 'exited with status = 0'
loops=$(grep -c 'rdi = 0x0*5$' lldb.log)
if [ "$loops" -ne 1 ]; then echo "  FAIL  the loop breakpoint stopped $loops times, not 1"; failed=1; fi
exit $failed

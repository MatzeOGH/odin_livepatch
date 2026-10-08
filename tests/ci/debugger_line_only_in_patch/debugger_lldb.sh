#!/bin/sh
# Runs app under lldb. A breakpoint on a source line that only the patches have code on must stop
# in v2 and again in v3. Run build.sh first. Without lldb, the test is skipped, except in CI
# ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
LLDB=${LLDB:-lldb}
if ! command -v "$LLDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  lldb not found"; exit 1; fi
	echo "  skipped: lldb not found"
	exit 0
fi
cd "$DIR" || exit 1
# The line of the breakpoint: it has the comment "the debugger breaks here"
LINE=$(grep -n 'the debugger breaks here' main.odin | cut -d: -f1)

# lldb learns of each patch through the GDB JIT interface, which is off by default. patch() stops
# the other threads with signal 62, which lldb must give to the program. The exe has no code on
# the line, so the breakpoint has no location until a patch has it. The commands for each stop
# run in order after the continue that reaches it.
cat > lldb_commands.txt << EOF
settings set plugin.jit-loader.gdb.enable on
breakpoint set -f main.odin -l $LINE
process launch --stop-at-entry
process handle 62 --stop false --notify false --pass true
continue
thread backtrace --count 3
frame variable version_here doubled
continue
thread backtrace --count 3
frame variable version_here doubled
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
# A local: optimized code keeps a value in a register or removes it. Checked at -o:none only.
expect_unoptimized() {
	if [ "${OPT:-none}" != none ]; then echo "  SKIP  $1 (-o:$OPT)"; else expect "$@"; fi
}
expect             'stopped two times in added, on the line'  "frame #0: .*main::added.* at main.odin:$LINE" 2
expect_unoptimized 'v2: stopped in the code of v2'             ' version_here = 2$'
expect_unoptimized 'v3: stopped in the code of v3'             ' version_here = 3$'
expect_unoptimized 'local doubled'                             ' doubled = 40$' 2
expect             'the program finished'                     'ALL OK'
expect             'it exited normally'                       'exited with status = 0'
exit $failed

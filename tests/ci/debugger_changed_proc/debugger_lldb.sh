#!/bin/sh
# Runs app under lldb. A breakpoint on a source line of work, which the exe has and each patch
# changes, must stop in the body of the exe, then of v2, then of v3, and never in an old body.
# Run build.sh first. Without lldb, the test is skipped, except in CI ($CI), where it fails.
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

# lldb learns of each patch through the GDB JIT interface, which is off by default, and gives the
# breakpoint a location in each patch. patch() stops the other threads with signal 62, which lldb
# must give to the program. The commands for each stop run in order after the continue that
# reaches it. A fourth continue ends the program: a stop in an old body would use it instead.
cat > lldb_commands.txt << EOF
settings set plugin.jit-loader.gdb.enable on
breakpoint set -f main.odin -l $LINE
process launch --stop-at-entry
process handle 62 --stop false --notify false --pass true
continue
thread backtrace --count 3
frame variable body_version scaled
continue
thread backtrace --count 3
frame variable body_version scaled
continue
thread backtrace --count 3
frame variable body_version scaled
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
expect             'v1: stopped in work of the exe'  "frame #0: .*app\`main::work.* at main.odin:$LINE"
expect             'v2, v3: stopped in a patch'      "frame #0: .*JIT\(0x[0-9a-f]+\)\`main::work.* at main.odin:$LINE" 2
expect_unoptimized 'v1: the body of the exe'         ' body_version = 1$'
expect_unoptimized 'v2: the body of v2'              ' body_version = 2$'
expect_unoptimized 'v3: the body of v3'              ' body_version = 3$'
expect_unoptimized 'v3: its local scaled'            ' scaled = 30$'
expect             'the program finished'            'ALL OK'
expect             'it exited normally'              'exited with status = 0'
# One stop for each version: a stop in an old body would be a fourth
stops=$(grep -c 'stop reason = breakpoint' lldb.log)
if [ "$stops" -ne 3 ]; then echo "  FAIL  the breakpoint stopped $stops times, not 3"; failed=1; fi
exit $failed

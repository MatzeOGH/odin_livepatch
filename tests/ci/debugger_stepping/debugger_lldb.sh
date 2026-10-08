#!/bin/sh
# Runs app under lldb. At a breakpoint on the call of target in main, lldb steps into target and
# must arrive in the body of the newest version, steps over a line, reads body_version, and
# finishes target with its return value. Run build.sh first. Without lldb, the test is skipped,
# except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
LLDB=${LLDB:-lldb}
if ! command -v "$LLDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  lldb not found"; exit 1; fi
	echo "  skipped: lldb not found"
	exit 0
fi
cd "$DIR" || exit 1
# The lines of the call and of the first line of target: they have comments
CALL=$(grep -n 'the debugger breaks here' main.odin | cut -d: -f1)
INTO=$(grep -n 'the debugger steps into target to here' main.odin | cut -d: -f1)

# A command that fails must not stop the next ones. lldb learns of each patch through the GDB JIT
# interface, which is off by default. patch() stops the other threads with signal 62, which lldb
# must give to the program. The commands for each stop run in order after the continue that
# reaches it.
STOP='thread step-in
thread backtrace --count 1
thread step-over
frame variable body_version
thread step-out
continue'
cat > lldb_commands.txt << EOF
settings set interpreter.stop-command-source-on-error false
settings set plugin.jit-loader.gdb.enable on
breakpoint set -f main.odin -l $CALL
process launch --stop-at-entry
process handle 62 --stop false --notify false --pass true
continue
$STOP
$STOP
$STOP
EOF
"$LLDB" --batch -s lldb_commands.txt -- ./app > lldb.log 2>&1
cat lldb.log

failed=0
# Passes when at least $3 (default 1) lines of the log match the extended regex $2
expect() {
	found=$(grep -Ec -- "$2" lldb.log)
	if [ "$found" -ge "${3:-1}" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (found $found of ${3:-1})"; failed=1; fi
}
expect 'step-in: arrived in target, on its first line' "frame #0: .*main::target.* at main.odin:$INTO" 3
expect 'v1: the body of v1'                      ' body_version = 1$'
expect 'v2: the body of v2'                      ' body_version = 2$'
expect 'v3: the body of v3'                      ' body_version = 3$'
expect 'v1: step-out returns 21'                 'Return value: .* = 21$'
expect 'v2: step-out returns 22'                 'Return value: .* = 22$'
expect 'v3: step-out returns 23'                 'Return value: .* = 23$'
expect 'the program finished'                    'ALL OK'
expect 'it exited normally'                      'exited with status = 0'
exit $failed

#!/bin/sh
# Runs app under lldb. At a breakpoint on the call of target in main, lldb steps into target, steps
# over a line, reads body_version, and finishes target with its return value. It steps in v1 only:
# see the known limit in main.odin. Run build.sh first. Without lldb, the test is skipped, except
# in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
LLDB=${LLDB:-lldb}
if ! command -v "$LLDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  lldb not found"; exit 1; fi
	echo "  skipped: lldb not found"
	exit 0
fi
cd "$DIR" || exit 1
# The lines of the call and of the proc line of target: they have comments
CALL=$(grep -n 'the debugger breaks here' main.odin | cut -d: -f1)
INTO=$(grep -n 'a step into target arrives here' main.odin | cut -d: -f1)

# A command that fails must not stop the next ones. -O sets this before lldb reads the file: a
# setting in the file does not apply to the file itself. lldb learns of each patch through the GDB
# JIT interface, which is off by default. patch() stops the other threads with signal 62, which
# lldb must give to the program. The commands for each stop run in order after the continue that
# reaches it. At the stop of v1: step in, step over, read, step out. At v2 and v3: continue.
cat > lldb_commands.txt << EOF
settings set plugin.jit-loader.gdb.enable on
breakpoint set -f main.odin -l $CALL
process launch --stop-at-entry
process handle 62 --stop false --notify false --pass true
continue
thread step-in
thread backtrace --count 1
thread step-over
frame variable body_version
thread step-out
continue
continue
continue
EOF
"$LLDB" --batch -O 'settings set interpreter.stop-command-source-on-error false' -s lldb_commands.txt -- ./app > lldb.log 2>&1
cat lldb.log

failed=0
# Passes when at least $3 (default 1) lines of the log match the extended regex $2
expect() {
	found=$(grep -Ec -- "$2" lldb.log)
	if [ "$found" -ge "${3:-1}" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (found $found of ${3:-1})"; failed=1; fi
}
expect 'v1: step-in: arrived in target'          "frame #0: .*main::target.* at main.odin:$INTO"
expect 'v1: the body of v1'                      ' body_version = 1$'
expect 'v1: step-out returns 21'                 'Return value: .* = 21$'
echo   '  KNOWN v2, v3: step into the patch (no debugger steps through the redirect stub)'
expect 'v2: the code of v2 ran'                  'target\(10\) +22 \(want 22\) OK'
expect 'v3: the code of v3 ran'                  'target\(10\) +23 \(want 23\) OK'
expect 'the program finished'                    'ALL OK'
expect 'it exited normally'                      'exited with status = 0'
exit $failed

#!/bin/sh
# Runs app under gdb. At a breakpoint on the call of target in main, gdb steps into target, steps
# over a line, reads body_version, and finishes target with its return value. It steps in v1 only:
# see the known limit in main.odin. Run build.sh first. Without gdb, the test is skipped, except in
# CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
GDB=${GDB:-gdb}
if ! command -v "$GDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  gdb not found"; exit 1; fi
	echo "  skipped: gdb not found"
	exit 0
fi
cd "$DIR" || exit 1
# The lines of the call and of the proc line of target: they have comments
CALL=$(grep -n 'the debugger breaks here' main.odin | cut -d: -f1)
INTO=$(grep -n 'a step into target arrives here' main.odin | cut -d: -f1)

# Each -ex runs on its own, so a command that fails does not stop the next ones. patch() stops
# the other threads with signal 62, which gdb must give to the program.
# At the stop of v1: step into target, show the frame, step over a line, read the locals, finish
# target with its return value, continue. At the stops of v2 and v3: continue.
set -- --batch --nx -ex 'set pagination off' -ex 'set breakpoint pending on' \
	-ex 'handle SIG62 nostop noprint pass' -ex "break main.odin:$CALL" -ex run \
	-ex 'echo STOP\n' -ex step -ex 'backtrace 1' -ex next -ex 'info locals' -ex finish -ex continue
for stop in 2 3; do
	set -- "$@" -ex 'echo STOP\n' -ex continue
done
"$GDB" "$@" ./app > gdb.log 2>&1
cat gdb.log

failed=0
# Passes when at least $3 (default 1) lines of the log match the extended regex $2
expect() {
	found=$(grep -Ec -- "$2" gdb.log)
	if [ "$found" -ge "${3:-1}" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (found $found of ${3:-1})"; failed=1; fi
}
expect 'stopped at the call three times'         '^STOP$' 3
expect 'v1: step: arrived in target'             "^#0 +main::target .*main.odin:$INTO$"
expect 'v1: the body of v1'                      '^body_version = 1$'
expect 'v1: finish returns 21'                   '^Value returned is \$[0-9]+ = 21$'
echo   '  KNOWN v2, v3: step into the patch (no debugger steps through the redirect stub)'
expect 'v2: the code of v2 ran'                  'target\(10\) +22 \(want 22\) OK'
expect 'v3: the code of v3 ran'                  'target\(10\) +23 \(want 23\) OK'
expect 'the program finished'                    'ALL OK'
expect 'it exited normally'                      'exited normally'
exit $failed

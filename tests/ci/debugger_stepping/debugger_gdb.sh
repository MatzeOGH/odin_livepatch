#!/bin/sh
# Runs app under gdb. At a breakpoint on the call of target in main, gdb steps into target and
# must arrive in the body of the newest version, steps over a line, reads body_version, and
# finishes target with its return value. Run build.sh first. Without gdb, the test is skipped,
# except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
GDB=${GDB:-gdb}
if ! command -v "$GDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  gdb not found"; exit 1; fi
	echo "  skipped: gdb not found"
	exit 0
fi
cd "$DIR" || exit 1
# The lines of the call and of the first line of target: they have comments
CALL=$(grep -n 'the debugger breaks here' main.odin | cut -d: -f1)
INTO=$(grep -n 'the debugger steps into target to here' main.odin | cut -d: -f1)

# Each -ex runs on its own, so a command that fails does not stop the next ones. patch() stops
# the other threads with signal 62, which gdb must give to the program.
# At each stop: step into target, show the frame, step over a line, read the locals, finish
# target with its return value, continue.
set -- --batch --nx -ex 'set pagination off' -ex 'set breakpoint pending on' \
	-ex 'handle SIG62 nostop noprint pass' -ex "break main.odin:$CALL" -ex run
for stop in 1 2 3; do
	set -- "$@" -ex 'echo STOP\n' -ex step -ex 'backtrace 1' -ex next -ex 'info locals' -ex finish -ex continue
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
expect 'step: arrived in target, on its first line' "^#0 +main::target .*main.odin:$INTO$" 3
expect 'v1: the body of v1'                      '^body_version = 1$'
expect 'v2: the body of v2'                      '^body_version = 2$'
expect 'v3: the body of v3'                      '^body_version = 3$'
expect 'v1: finish returns 21'                   '^Value returned is \$[0-9]+ = 21$'
expect 'v2: finish returns 22'                   '^Value returned is \$[0-9]+ = 22$'
expect 'v3: finish returns 23'                   '^Value returned is \$[0-9]+ = 23$'
expect 'the program finished'                    'ALL OK'
expect 'it exited normally'                      'exited normally'
exit $failed

#!/bin/sh
# Runs app under gdb. At a stop in bump in each version, gdb must read the values that the code
# uses: the @static calls, the global that v2 adds, a @thread_local and a global of the exe. Run
# build.sh first. Without gdb, the test is skipped, except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
GDB=${GDB:-gdb}
if ! command -v "$GDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  gdb not found"; exit 1; fi
	echo "  skipped: gdb not found"
	exit 0
fi
cd "$DIR" || exit 1
# The line of the breakpoint: it has the comment "the debugger breaks here"
LINE=$(grep -n 'the debugger breaks here' main.odin | cut -d: -f1)

# Each -ex runs on its own, so a command that fails (added_global is not in v1) does not stop the
# next ones. The breakpoint on the line in stop_here gets a location in the exe and in each
# patch, and only the location in the newest code runs. patch()
# stops the other threads with signal 62, which gdb must give to the program. At each stop: go up
# to bump, read its locals (with the @static calls) and the globals, continue.
set -- --batch --nx -ex 'set pagination off' -ex 'set breakpoint pending on' \
	-ex 'handle SIG62 nostop noprint pass' -ex "break main.odin:$LINE" -ex run
for stop in 1 2 3; do
	set -- "$@" -ex 'echo STOP\n' -ex up -ex 'info locals' -ex 'print total' -ex 'print tl_value' \
		-ex 'print added_global' -ex continue
done
"$GDB" "$@" ./app > gdb.log 2>&1
cat gdb.log

failed=0
# Passes when at least $3 (default 1) lines of the log match the extended regex $2
expect() {
	found=$(grep -Ec -- "$2" gdb.log)
	if [ "$found" -ge "${3:-1}" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (found $found of ${3:-1})"; failed=1; fi
}
expect 'stopped three times'                     '^STOP$' 3
expect 'v1, v2, v3: @static calls kept'          '^calls = [123]$' 3
expect 'v3: @static calls is 3'                  '^calls = 3$'
expect 'v1: global total'                        '^\$[0-9]+ = 101$'
expect 'v3: global total'                        '^\$[0-9]+ = 106$'
expect 'v1: @thread_local tl_value'              '^\$[0-9]+ = 8$'
expect 'v3: @thread_local tl_value'              '^\$[0-9]+ = 13$'
expect 'v2: global that v2 adds'                 '^\$[0-9]+ = 1002$'
expect 'v3: the same global, kept'               '^\$[0-9]+ = 1005$'
expect 'the program finished'                    'ALL OK'
expect 'it exited normally'                      'exited normally'
exit $failed

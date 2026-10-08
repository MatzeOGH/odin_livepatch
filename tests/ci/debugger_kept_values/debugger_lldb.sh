#!/bin/sh
# Runs app under lldb. At a stop in bump in each version, lldb must read the values that the code
# uses: the @static calls, the global that v2 adds, a @thread_local and a global of the exe. Run
# build.sh first. Without lldb, the test is skipped, except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
LLDB=${LLDB:-lldb}
if ! command -v "$LLDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  lldb not found"; exit 1; fi
	echo "  skipped: lldb not found"
	exit 0
fi
cd "$DIR" || exit 1
# The line of the breakpoint in stop_here: it has the comment "the debugger breaks here". Only the
# location in the newest code runs.
LINE=$(grep -n 'the debugger breaks here' main.odin | cut -d: -f1)

# A command that fails (added_global is not in v1) must not stop the next ones. -O sets this
# before lldb reads the file: a setting in the file does not apply to the file itself. Each
# variable has its own command, so that the error does not hide the others. lldb learns of each
# patch through the GDB JIT interface, which is off by default. patch() stops the other threads
# with signal 62, which lldb must give to the program. At each stop: select bump (frame 1), read
# the @static calls and the globals, continue.
STOP='frame select 1
frame variable calls
target variable total
target variable tl_value
target variable added_global
continue'
cat > lldb_commands.txt << EOF
settings set plugin.jit-loader.gdb.enable on
breakpoint set -f main.odin -l $LINE
process launch --stop-at-entry
process handle 62 --stop false --notify false --pass true
continue
$STOP
$STOP
$STOP
EOF
"$LLDB" --batch -O 'settings set interpreter.stop-command-source-on-error false' -s lldb_commands.txt -- ./app > lldb.log 2>&1
cat lldb.log

failed=0
# Passes when at least $3 (default 1) lines of the log match the extended regex $2
expect() {
	found=$(grep -Ec -- "$2" lldb.log)
	if [ "$found" -ge "${3:-1}" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (found $found of ${3:-1})"; failed=1; fi
}
expect 'stopped three times in bump'             'frame #1: .*main::bump' 3
expect 'v3: @static calls is 3'                  ' calls = 3$'
expect 'v1: global total'                        ' total = 101$'
expect 'v3: global total'                        ' total = 106$'
expect 'v1: @thread_local tl_value'              ' tl_value = 8$'
expect 'v3: @thread_local tl_value'              ' tl_value = 13$'
expect 'v2: global that v2 adds'                 ' added_global = 1002$'
expect 'v3: the same global, kept'               ' added_global = 1005$'
# target variable lists the variable of the exe and of each patch module. The debug info of a patch
# gives a thread-local in the TLS block of the exe (see rewrite_debug_thread_local), so no entry may
# lack TLS data.
if grep -q 'No TLS data' lldb.log; then echo '  FAIL  each @thread_local entry has a value (found "No TLS data")'; failed=1; else echo '  OK    each @thread_local entry has a value'; fi
expect 'the program finished'                    'ALL OK'
expect 'it exited normally'                      'exited with status = 0'
exit $failed

#!/bin/sh
# Runs app under lldb. At a stop in bump in each version, lldb must read the values that the code
# uses: the global that v2 adds, a @thread_local and a global of the exe. Odin writes no DWARF for
# a @static, so lldb cannot read calls. Run build.sh first. Without lldb, the test is skipped,
# except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
LLDB=${LLDB:-lldb}
if ! command -v "$LLDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  lldb not found"; exit 1; fi
	echo "  skipped: lldb not found"
	exit 0
fi
cd "$DIR" || exit 1

# A command that fails (added_global is not in v1) must not stop the next ones. -O sets this
# before lldb reads the file: a setting in the file does not apply to the file itself. Each
# variable has its own command, so that the error does not hide the others. lldb learns of each
# patch through the GDB JIT interface, which is off by default. patch() stops the other threads
# with signal 62, which lldb must give to the program. At each stop: select bump (frame 1), read
# the globals, continue.
STOP='frame select 1
target variable total
target variable tl_value
target variable added_global
continue'
cat > lldb_commands.txt << EOF
settings set plugin.jit-loader.gdb.enable on
breakpoint set -r ^main::stop_here$
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
expect 'v1: global total'                        ' total = 101$'
expect 'v3: global total'                        ' total = 106$'
expect 'v1: @thread_local tl_value'              ' tl_value = 8$'
expect 'v3: @thread_local tl_value'              ' tl_value = 13$'
expect 'v2: global that v2 adds'                 ' added_global = 1002$'
expect 'v3: the same global, kept'               ' added_global = 1005$'
expect 'the program finished'                    'ALL OK'
expect 'it exited normally'                      'exited with status = 0'
exit $failed

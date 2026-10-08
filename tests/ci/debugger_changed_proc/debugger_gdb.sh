#!/bin/sh
# Runs app under gdb. A breakpoint on a source line of work, which the exe has and each patch
# changes, must stop in the body of the exe, then of v2, then of v3, and never in an old body.
# Run build.sh first. Without gdb, the test is skipped, except in CI ($CI), where it fails.
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

# gdb learns of each patch through its JIT interface, and gives the breakpoint a location in each
# patch. patch() stops the other threads with signal 62, which gdb must give to the program. The
# breakpoint prints a marker line, the stack and the locals, then continues.
cat > gdb_commands.txt << EOF
set pagination off
set breakpoint pending on
handle SIG62 nostop noprint pass
break main.odin:$LINE
commands
silent
echo STOP\n
backtrace 3
info locals
continue
end
run
EOF
"$GDB" --batch --nx -x gdb_commands.txt ./app > gdb.log 2>&1
cat gdb.log

failed=0
# Passes when at least $3 (default 1) lines of the log match the extended regex $2
expect() {
	found=$(grep -Ec -- "$2" gdb.log)
	if [ "$found" -ge "${3:-1}" ]; then echo "  OK    $1"; else echo "  FAIL  $1 (found $found of ${3:-1})"; failed=1; fi
}
# A local: optimized code keeps a value in a register or removes it. Checked at -o:none only.
expect_unoptimized() {
	if [ "${OPT:-none}" != none ]; then echo "  SKIP  $1 (-o:$OPT)"; else expect "$@"; fi
}
expect             'stopped in work, on the line'  "^#0 +main::work .*main.odin:$LINE$" 3
expect_unoptimized 'v1: the body of the exe'       '^body_version = 1$'
expect_unoptimized 'v2: the body of v2'            '^body_version = 2$'
expect_unoptimized 'v3: the body of v3'            '^body_version = 3$'
expect_unoptimized 'v3: its local scaled'          '^scaled = 30$'
expect             'the program finished'          'ALL OK'
expect             'it exited normally'            'exited normally'
# One stop for each version: a stop in an old body would be a fourth
stops=$(grep -c '^STOP$' gdb.log)
if [ "$stops" -ne 3 ]; then echo "  FAIL  the breakpoint stopped $stops times, not 3"; failed=1; fi
exit $failed

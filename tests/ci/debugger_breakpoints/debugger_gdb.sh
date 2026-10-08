#!/bin/sh
# Runs app under gdb. A breakpoint on stop_v2 and on stop_v3, set before the program starts,
# must stop in the patch module of each version, with the locals of the patched caller. The exe
# has no such procedures, so a stop is in a patch. Run build.sh first. Without gdb, the test is
# skipped, except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
GDB=${GDB:-gdb}
if ! command -v "$GDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  gdb not found"; exit 1; fi
	echo "  skipped: gdb not found"
	exit 0
fi
cd "$DIR" || exit 1

# gdb learns of each patch through its JIT interface. patch() stops the other threads with
# signal 62, which gdb must give to the program. Each breakpoint prints a marker line, the stack
# and the locals of its caller (frame 1), then continues.
cat > gdb_commands.txt << 'EOF'
set pagination off
set breakpoint pending on
handle SIG62 nostop noprint pass
break main::stop_v2
commands
silent
echo STOP v2\n
backtrace 6
up
info args
info locals
continue
end
break main::stop_v3
commands
silent
echo STOP v3\n
backtrace 6
up
info args
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
# A local, an argument, or the frame of a patched caller: optimized code removes values and
# inlines callers. Checked at -o:none only.
expect_unoptimized() {
	if [ "${OPT:-none}" != none ]; then echo "  SKIP  $1 (-o:$OPT)"; else expect "$@"; fi
}
expect             'v2: stopped in the patch'          '^STOP v2$'
expect             'v2: in stop_v2'                    '^#0 +main::stop_v2 '
expect_unoptimized 'v2: caller body_v2'                '^#1 .*main::body_v2 '
expect_unoptimized 'v2: argument n'                    '^n = 20$'
expect_unoptimized 'v2: local doubled'                 '^doubled = 40$'
expect             'v3: stopped in the second patch'   '^STOP v3$'
expect             'v3: in stop_v3'                    '^#0 +main::stop_v3 '
expect_unoptimized 'v3: local tripled'                 '^tripled = 60$'
expect             'called from main in the exe'       '^#[0-9]+ .*main::main ' 2
expect             'the program finished'              'ALL OK'
expect             'it exited normally'                'exited normally'
exit $failed

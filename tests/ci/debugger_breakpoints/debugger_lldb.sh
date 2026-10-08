#!/bin/sh
# Runs app under lldb. A breakpoint on stop_v2 and on stop_v3, set before the program starts,
# must stop in the patch module of each version, with the locals of the patched caller. The exe
# has no such procedures, so a stop is in a patch. Run build.sh first. Without lldb, the test is
# skipped, except in CI ($CI), where it fails.
DIR=$(cd "$(dirname "$0")" && pwd)
LLDB=${LLDB:-lldb}
if ! command -v "$LLDB" > /dev/null 2>&1; then
	if [ -n "${CI:-}" ]; then echo "  FAIL  lldb not found"; exit 1; fi
	echo "  skipped: lldb not found"
	exit 0
fi
cd "$DIR" || exit 1

# lldb learns of each patch through the GDB JIT interface, which is off by default. patch()
# stops the other threads with signal 62, which lldb must give to the program. lldb reads
# main::stop_v2 as a C++ scope, so the breakpoints are regexes. Each breakpoint prints the stack
# and the variables of its caller (frame 1), then continues (-G true).
cat > lldb_commands.txt << 'EOF'
settings set plugin.jit-loader.gdb.enable on
breakpoint set -r ^main::stop_v2$ -G true -C "thread backtrace --count 6" -C "frame select 1" -C "frame variable"
breakpoint set -r ^main::stop_v3$ -G true -C "thread backtrace --count 6" -C "frame select 1" -C "frame variable"
process launch --stop-at-entry
process handle SIG62 --stop false --notify false --pass true
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
# A local, an argument, or the frame of a patched caller: optimized code removes values and
# inlines callers. Checked at -o:none only.
expect_unoptimized() {
	if [ "${OPT:-none}" != none ]; then echo "  SKIP  $1 (-o:$OPT)"; else expect "$@"; fi
}
expect             'v2: stopped in stop_v2'            'frame #0: .*main::stop_v2'
expect_unoptimized 'v2: caller body_v2'                'frame #1: .*main::body_v2'
expect_unoptimized 'v2: argument n'                    ' n = 20$'
expect_unoptimized 'v2: local doubled'                 ' doubled = 40$'
expect             'v3: stopped in stop_v3'            'frame #0: .*main::stop_v3'
expect_unoptimized 'v3: local tripled'                 ' tripled = 60$'
expect             'called from main in the exe'       'frame #[0-9]+: .*main::main' 2
expect             'the program finished'              'ALL OK'
expect             'it exited normally'                'exited with status = 0'
exit $failed

#!/bin/sh
# Builds the demo. Run it once with no argument to build ./demo.
# patch() runs it with an output directory to build the patch objects.
# Both modes use the same flags, so the exe and the patch always match.

# The compiler. Set ODIN if odin is not on PATH. patch() runs this script with the
# environment of the demo, so the same value applies to each patch.
ODIN=${ODIN:-odin}

DIR=$(cd "$(dirname "$0")" && pwd)
PKG=$DIR
EXE=$DIR/demo

# patch() sets LIVEPATCH_DEBUGGER=0 when no debugger is attached. Then the patch needs no
# debug info, and the build is faster.
DEBUG=-debug
[ "${LIVEPATCH_DEBUGGER:-}" = 0 ] && DEBUG=

# Mandatory: -use-separate-modules and -define:LIVEPATCH=true.
# Optional: the -o: level, -thread-count, LIVEPATCH_TIMINGS, and LIVEPATCH_TOAST.
FLAGS="$DEBUG -o:none -use-separate-modules -thread-count:4 -define:LIVEPATCH=true -define:LIVEPATCH_TIMINGS=true -define:LIVEPATCH_TOAST=true"

if [ -z "$1" ]; then
	exec "$ODIN" build "$PKG" $FLAGS -out:"$EXE"
else
	exec "$ODIN" build "$PKG" $FLAGS -build-mode:obj -out:"$1/"
fi

#!/bin/sh
# Builds the demo host, and (with an output dir argument) the patch objects that
# patch() maps in. patch() calls this script the second way. Every flag is required.
# Run the first form once by hand to produce ./demo next to this script.

# ODIN is the compiler to call. It defaults to `odin` (on PATH). To build without odin
# on PATH, set it first: `export ODIN=/path/to/odin`. patch() runs this script in the
# running exe's environment, so this covers the F5 rebuild too.
ODIN=${ODIN:-odin}

DIR=$(cd "$(dirname "$0")" && pwd)
PKG=$DIR
EXE=$DIR/demo

FLAGS="-debug -o:none -use-separate-modules -define:LIVEPATCH=true -define:LIVEPATCH_TIMINGS=true -define:LIVEPATCH_TOAST=true"

if [ -z "$1" ]; then
	exec "$ODIN" build "$PKG" $FLAGS -out:"$EXE"
else
	exec "$ODIN" build "$PKG" $FLAGS -build-mode:obj -out:"$1/"
fi

#!/bin/sh
# No argument: builds app. patch() runs it with an output directory to build the patch objects.
# OPT is the -o: level (default: none). VERSION selects the version of the code (default: 1).
# LIVEPATCH=false builds the exe with livepatch off (default: true).
# RELOC=static builds with -reloc-mode:static (default: a PIE).
ODIN=${ODIN:-odin}
DIR=$(cd "$(dirname "$0")" && pwd)
# patch() sets LIVEPATCH_DEBUGGER=0 when no debugger is attached. Then the patch needs no debug info.
DEBUG=-debug
[ -n "$1" ] && [ "${LIVEPATCH_DEBUGGER:-}" = 0 ] && DEBUG=
RELOC_FLAG=
[ "${RELOC:-}" = static ] && RELOC_FLAG=-reloc-mode:static
# The exe and the patch link with lld. The default linker of the exe is the system linker.
# On macOS, ld64.lld is the only linker of the patch, so the test keeps the default.
LINKER=lld
[ "$(uname)" = Darwin ] && LINKER=default
FLAGS="$DEBUG -o:${OPT:-none} -define:VERSION=${VERSION:-1} -use-separate-modules -define:LIVEPATCH=${LIVEPATCH:-true} $RELOC_FLAG -linker:$LINKER -define:LIVEPATCH_LINKER=$LINKER"

if [ -z "$1" ]; then
	exec "$ODIN" build "$DIR" $FLAGS -out:"$DIR/app"
else
	exec "$ODIN" build "$DIR" $FLAGS -build-mode:obj -out:"$1/"
fi

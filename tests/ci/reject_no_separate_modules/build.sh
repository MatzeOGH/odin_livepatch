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
# Version 3: the patch build leaves out -use-separate-modules. At -o:speed, Odin then makes one module.
SEPARATE=-use-separate-modules
[ -n "$1" ] && [ "${VERSION:-1}" = 3 ] && SEPARATE= && OPT=speed
FLAGS="$DEBUG -o:${OPT:-none} -define:VERSION=${VERSION:-1} $SEPARATE -define:LIVEPATCH=${LIVEPATCH:-true} $RELOC_FLAG"

if [ -z "$1" ]; then
	exec "$ODIN" build "$DIR" $FLAGS -out:"$DIR/app"
else
	exec "$ODIN" build "$DIR" $FLAGS -build-mode:obj -out:"$1/"
fi

#!/bin/sh
# No argument: builds app. patch() runs it with an output directory to build the patch objects.
# OPT is the -o: level (default: none). VERSION selects the version of the code (default: 1).
# This test always builds with livepatch off. It also type-checks the API with LIVEPATCH=true
# on targets that livepatch does not patch, where the API must compile to no-ops.
ODIN=${ODIN:-odin}
DIR=$(cd "$(dirname "$0")" && pwd)
FLAGS="-debug -o:${OPT:-none} -define:VERSION=${VERSION:-1} -use-separate-modules -define:LIVEPATCH=false"

if [ -z "$1" ]; then
	# Not windows_i386: on Linux, Odin needs a Windows SDK to check a Windows target
	for target in linux_arm64 linux_riscv64 darwin_amd64 darwin_arm64 freebsd_amd64; do
		echo "type-check LIVEPATCH=true -target:$target"
		"$ODIN" check "$DIR" -target:$target -define:LIVEPATCH=true || exit 1
	done
	exec "$ODIN" build "$DIR" $FLAGS -out:"$DIR/app"
else
	exec "$ODIN" build "$DIR" $FLAGS -build-mode:obj -out:"$1/"
fi

#!/bin/sh

NAME=ur
RELEASE="${1:-safe}"
OUT_DIR="$PWD/zig-out"
DIST_DIR="dist-$RELEASE"

OUT_DIST_DIR="$OUT_DIR/$DIST_DIR"

# Check for existing distributions
if [ -d "$OUT_DIST_DIR" ]; then
	printf '%s already exists!\n' "$(realpath "$OUT_DIST_DIR")"
	exit 1
fi

# Compute platforms that zig supports and compile
curl 'https://ziglang.org/download/index.json?source='"$NAME" |
	jq -r '.master|keys[]' | grep -- - |
	xargs -P0 -I{} zig build --prefix-exe-dir "$DIST_DIR"/{} --release="$RELEASE" -Dtarget={}

# Remove debugging symbols
find "$OUT_DIST_DIR" -name "$NAME".pdb -exec rm {} \;
# find "$OUT_DIST_DIR" -regex '.*/ur\(\.exe\)?' -exec strip {} \;

# Tarball
tar -cvaf "ur-$RELEASE.tar.xz" -C "$OUT_DIST_DIR" .

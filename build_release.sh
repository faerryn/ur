#!/bin/sh

# Ensure programs are available
ensure() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo >&2 "$1 required"
  return 1
}

ensure parallel || exit 1
ensure zig || exit 1
ensure tar || exit 1

# Define variables
RELEASE_MODE="${1:-safe}"

BUILD_TARGETS="$PWD/build_targets.txt"
DIST_DIR="dist-$RELEASE_MODE"
OUT_DIR="$PWD/zig-out"

OUT_DIST_DIR="$OUT_DIR/$DIST_DIR"

# Compile using GNU parallel
parallel --bar zig build --prefix-exe-dir "$DIST_DIR"/{} --release="$RELEASE_MODE" -Dtarget={} :::: "$BUILD_TARGETS"

# Package binaries into a tarball
tar -cvaf "ur-$RELEASE_MODE.tar.xz" -C "$OUT_DIST_DIR" .

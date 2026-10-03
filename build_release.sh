#!/bin/sh

ensure() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo >&2 "$1 required"
  return 1
}

ensure parallel || exit 1
ensure zig || exit 1

RELEASE_MODE="${1:-safe}"
BUILD_TARGETS="$PWD/build_targets.txt"
DIST_DIR="dist-$RELEASE_MODE"

parallel --bar zig build --prefix-exe-dir "$DIST_DIR"/{} --release="$RELEASE_MODE" -Dtarget={} :::: "$BUILD_TARGETS"

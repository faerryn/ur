#!/bin/sh

ensure() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo >&2 "$1 required"
  return 1
}

ensure grep || exit 1
ensure parallel || exit 1

ensure zig || exit 1

ensure gzip || exit 1
ensure tar || exit 1
ensure zip || exit 1

NAME=ur
RELEASE_MODE="${1:-safe}"
BUILD_TARGETS="$PWD/build_targets.txt"
DIST_DIR="dist-$RELEASE_MODE"
ZIG_OUT="$PWD/zig-out"
ZIG_OUT_DIST_DIR="$ZIG_OUT/$DIST_DIR"
RELEASES_DIR="$PWD/releases"

printf "Buiding %s-%s...\n" "$NAME" "$RELEASE_MODE"
parallel --bar zig build --prefix-exe-dir "$DIST_DIR/{}" --release="$RELEASE_MODE" -Dtarget={} :::: "$BUILD_TARGETS"

printf "Pacakaging %s-%s...\n" "$NAME" "$RELEASE_MODE"
mkdir -p "$RELEASES_DIR"
grep '\-windows$' "$BUILD_TARGETS" | parallel --bar zip -jq "$RELEASES_DIR/{}-${RELEASE_MODE}.zip" "$ZIG_OUT_DIST_DIR/{}/${NAME}.exe"
grep -v '\-windows$' "$BUILD_TARGETS" | parallel --bar tar -C "$ZIG_OUT_DIST_DIR/{}" -czf "$RELEASES_DIR/{}-${RELEASE_MODE}.tar.gz" "$NAME"

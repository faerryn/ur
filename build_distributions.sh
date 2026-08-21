#!/bin/sh

DIST_DIR=dist
RELEASE=small

curl 'https://ziglang.org/download/index.json?source=ur' | jq -r '.master|keys[]' | grep -- - |
	parallel zig build --prefix-exe-dir "$DIST_DIR"/{} --release="$RELEASE" -Dtarget={}

tar -cvaf ur.tar.xz -C "zig-out/$DIST_DIR" .

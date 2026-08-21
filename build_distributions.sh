#!/bin/sh

DIST_DIR=dist
RELEASE=fast

curl 'https://ziglang.org/download/index.json?source=ur' | jq -r '.master|keys[]' | grep -- - |
	parallel zig build --prefix-exe-dir "$DIST_DIR"/{} --release="$RELEASE" -Dtarget={}

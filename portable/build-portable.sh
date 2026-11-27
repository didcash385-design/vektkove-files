#!/bin/bash
# Cross-builds the portable Vektkove command-line runner for Linux and Windows.
# Requires a Zig compiler (https://ziglang.org/download/) as the C cross-compiler.
#   ZIG=/path/to/zig portable/build-portable.sh
# Output goes to dist/<platform>/ next to this repository's Makefile.
set -eu
cd "$(dirname "$0")/.."
ZIG="${ZIG:-zig}"
command -v "$ZIG" >/dev/null 2>&1 || [ -x "$ZIG" ] || { echo "Zig compiler not found. Set ZIG=/path/to/zig" >&2; exit 1; }

build() {  # name target output [extra flags]
  name="$1"; target="$2"; output="$3"; shift 3
  portable/build-sodium.sh "$name" >/dev/null
  mkdir -p "dist/$name"
  "$ZIG" cc -target "$target" -std=c11 -O2 -s -Wall -Wextra -DCJSON_HIDE_SYMBOLS -DSODIUM_STATIC -Ideps/sodium-"$name"/include "$@" portable/vkport.c portable/vkai.c portable/vkjson.c deps/sodium-"$name"/lib/libsodium.a -o "dist/$name/$output"
  echo "built dist/$name/$output"
}

case "${1:-all}" in
  all) platforms="linux-x64 linux-aarch64 windows-x64 windows-arm64" ;;
  --windows-only) platforms="windows-x64 windows-arm64" ;;
  *) echo "Usage: $0 [--windows-only]" >&2; exit 1 ;;
esac

if [ "${1:-all}" = all ]; then
  build linux-x64     x86_64-linux-musl   vk -lm -pthread
  build linux-aarch64 aarch64-linux-musl  vk -lm -pthread
fi
build windows-x64   x86_64-windows-gnu  vk.exe -lws2_32
build windows-arm64 aarch64-windows-gnu vk.exe -lws2_32

for dir in $platforms; do
  mkdir -p "dist/$dir/examples"
  cp -R examples/. "dist/$dir/examples/"
done
echo "done"

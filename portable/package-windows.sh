#!/bin/bash
set -eu
cd "$(dirname "$0")/.."

VERSION=1.4.3
portable/build-portable.sh --windows-only
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xOf "deps/libsodium-1.0.20.tar.gz" libsodium-1.0.20/LICENSE > "$WORK/LICENSE.libsodium.txt"
cp third_party/cjson/LICENSE "$WORK/LICENSE.cJSON.txt"

for architecture in x64 arm64; do
  archive="$PWD/dist/vektkove-$VERSION-windows-$architecture.zip"
  [ ! -e "$archive" ] || { echo "Archive already exists: $archive" >&2; exit 1; }
  zip -q -j "$archive" "dist/windows-$architecture/vk.exe" LICENSE "$WORK/LICENSE.libsodium.txt" "$WORK/LICENSE.cJSON.txt" portable/WINDOWS.md MANUAL.md
  zip -q -r "$archive" examples
  shasum -a 256 "$archive"
done
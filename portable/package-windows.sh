#!/bin/bash
set -eu
cd "$(dirname "$0")/.."

VERSION=1.2.0
portable/build-portable.sh --windows-only
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xOf "deps/libsodium-1.0.20.tar.gz" libsodium-1.0.20/LICENSE > "$WORK/LICENSE.libsodium.txt"

for architecture in x64 arm64; do
  archive="$PWD/dist/vektkove-$VERSION-windows-$architecture.zip"
  [ ! -e "$archive" ] || { echo "Archive already exists: $archive" >&2; exit 1; }
  zip -q -j "$archive" "dist/windows-$architecture/vk.exe" LICENSE "$WORK/LICENSE.libsodium.txt" portable/WINDOWS.md
  zip -q -r "$archive" examples
  shasum -a 256 "$archive"
done
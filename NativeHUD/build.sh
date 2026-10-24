#!/bin/zsh
# Builds the universal (arm64 + x86_64/Rosetta) stats library and copies the launch wrapper.
# Usage: NativeHUD/build.sh <output-dir>   (Xcode passes the app's Resources folder)
set -euo pipefail
src=${0:A:h}
out=${1:-$src/build}
tmp=$(mktemp -d "${TEMP_DIR:-${TMPDIR:-/tmp}}/mhud-stats.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
for a in arm64 x86_64; do
  xcrun --sdk macosx clang++ -arch $a -mmacosx-version-min=26.0 -std=c++17 -O2 -fobjc-arc -dynamiclib \
    -install_name @rpath/libMHUDStats.dylib -framework Foundation -framework IOKit \
    "$src/mhud_stats.mm" -o "$tmp/libMHUDStats.$a.dylib"
done
xcrun lipo -create "$tmp/libMHUDStats.arm64.dylib" "$tmp/libMHUDStats.x86_64.dylib" -output "$tmp/libMHUDStats.dylib"
# codesign creates a .cstemp sibling. Sign in the declared build scratch area
# before copying to the exact output path allowed by Xcode's script sandbox.
codesign --force --sign - "$tmp/libMHUDStats.dylib"
# Copying over a signed binary in place keeps its inode, and the kernel's cached signature then
# kills whatever maps it (this app included). Remove it first so the copy is a new file.
rm -f "$out/libMHUDStats.dylib"
cp "$tmp/libMHUDStats.dylib" "$out/libMHUDStats.dylib"
cp "$src/mhud-run" "$out/mhud-run"
chmod +x "$out/mhud-run"

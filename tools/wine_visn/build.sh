#!/bin/sh
# Build the 32-bit Windows VISN harness with the mingw-w64 cross compiler.
#
#   ./build.sh [OUTDIR]
#
# OUTDIR defaults to $VISN_BUILD_DIR, else ./build.  Build artefacts are kept
# out of the repository on purpose; pass a scratch directory.
set -e

CC=${CC:-i686-w64-mingw32-gcc}
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR=${1:-${VISN_BUILD_DIR:-$SRC_DIR/build}}

mkdir -p "$OUT_DIR"

# Eng3d.dll is a PE32 based at 0x400000.  It does carry a .reloc section so the
# loader can move it, but linking the harness away from 0x400000 avoids relying
# on that and makes the load deterministic.
"$CC" -m32 -O2 -Wall -Wextra \
    -Wl,--image-base,0x10000000 \
    -o "$OUT_DIR/visn_harness.exe" \
    "$SRC_DIR/visn_harness.c"

echo "built $OUT_DIR/visn_harness.exe"

#!/bin/sh
# Build inc_control.exe, the out-of-process reader for a running game under
# Wine, with the mingw-w64 cross compiler.
#
#   ./build.sh [OUTDIR]
#
# OUTDIR defaults to this directory, where .gitignore keeps the .exe out of
# the repository.
set -eu

CC=${CC:-i686-w64-mingw32-gcc}
SRC_DIR=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$SRC_DIR}
mkdir -p "$OUT"
"$CC" -O2 -Wall -Wextra -Werror -o "$OUT/inc_control.exe" \
    "$SRC_DIR/inc_control.c" -lgdi32 -luser32
echo "built $OUT/inc_control.exe"

#!/bin/sh
set -eu

CC=${CC:-i686-w64-mingw32-gcc}
OUT=${1:-/private/tmp/incubation-wine-control}
mkdir -p "$OUT"
"$CC" -O2 -Wall -Wextra -Werror -o "$OUT/inc_control.exe" \
    "$(dirname "$0")/inc_control.c" -lgdi32 -luser32
"$CC" -O2 -Wall -Wextra -Werror -o "$OUT/inc_probe.exe" \
    "$(dirname "$0")/inc_probe.c"

#!/usr/bin/env python3
"""Verify the Incubation .IMG fixed-point lookup tables.

`WorldSet/World_*/IMG/` ships two files that are not images despite the
extension. Both are static engine tables, byte-identical in all 21 world sets:

    ATN.IMG   1025 x u16   arctangent table
    TRIG.IMG  5120 x u16   sine table with a wrapped cosine window

Angles use a 4096-unit circle ("binary degrees"), and the sine table is Q14
signed fixed point.

    ATN[i]  = round(atan(i / 1024) * 4096 / (2*pi))       for i in 0..1024
    TRIG[i] = trunc(sin(2*pi*i / 4096) * 16383) as int16   for i in 0..5119

TRIG is 4096 + 1024 entries long so that `cos(a) == TRIG[a + 1024]` needs no
wrap-around check: the trailing 1024 entries repeat the first quarter period.

The shipped tables were generated with single-precision floats, so individual
entries deviate from the exact formula by at most 1 unit; the checker allows
that and reports anything larger as a failure.

This tool regenerates both tables from the formulas above and diffs them against
the shipped files, which is the proof that the interpretation is correct.
"""

from __future__ import annotations

import argparse
import glob
import logging
import math
import os
import struct

LOG = logging.getLogger("img_tables")

ANGLE_UNITS = 4096
"""Full circle, in the engine's angle units."""
ATAN_INPUT_SCALE = 1024
"""ATN.IMG is indexed by (dy/dx) * 1024."""
SINE_SCALE = 16383
"""TRIG.IMG stores sin() in Q14 signed fixed point (peak 16383, truncated)."""
ATAN_ENTRIES = 1025
TRIG_ENTRIES = 5120
TRIG_PERIOD = 4096
COSINE_OFFSET = 1024

# Tolerance in table units. The shipped tables carry <=1 unit of generation-time
# rounding noise; anything above that would mean the formula is wrong.
TOLERANCE = 1


def expected_atan() -> list[int]:
    return [round(math.atan(i / ATAN_INPUT_SCALE) * ANGLE_UNITS / (2 * math.pi))
            for i in range(ATAN_ENTRIES)]


def expected_trig() -> list[int]:
    return [math.trunc(math.sin(2 * math.pi * i / TRIG_PERIOD) * SINE_SCALE)
            for i in range(TRIG_ENTRIES)]


def read_u16(path: str) -> list[int]:
    with open(path, "rb") as fh:
        data = fh.read()
    return list(struct.unpack(f"<{len(data) // 2}H", data))


def as_signed(values: list[int]) -> list[int]:
    return [v - 0x10000 if v >= 0x8000 else v for v in values]


def compare(name: str, actual: list[int], expected: list[int]) -> int:
    if len(actual) != len(expected):
        LOG.error("%s: %d entries, expected %d", name, len(actual), len(expected))
        return len(expected)
    bad = [(i, a, e) for i, (a, e) in enumerate(zip(actual, expected))
           if abs(a - e) > TOLERANCE]
    if bad:
        LOG.error("%s: %d/%d entries differ by more than %d, e.g. %s",
                  name, len(bad), len(actual), TOLERANCE, bad[:5])
    else:
        LOG.info("%s: %d/%d entries match the formula (tolerance %d)",
                 name, len(actual), len(actual), TOLERANCE)
    return len(bad)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("game_root", nargs="?", default="gog_incubation")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    paths = sorted(glob.glob(os.path.join(args.game_root, "**", "*.IMG"),
                             recursive=True))
    if not paths:
        LOG.error("no .IMG files under %s", args.game_root)
        return 1

    contents: dict[bytes, list[str]] = {}
    for path in paths:
        with open(path, "rb") as fh:
            contents.setdefault(fh.read(), []).append(path)
    LOG.info("%d .IMG files, %d distinct contents", len(paths), len(contents))

    failures = 0
    for blob, files in contents.items():
        name = os.path.basename(files[0]).upper()
        values = list(struct.unpack(f"<{len(blob) // 2}H", blob))
        LOG.info("%s: %d copies, %d entries", name, len(files), len(values))
        if name.startswith("ATN"):
            failures += compare(name, values, expected_atan())
        elif name.startswith("TRIG"):
            signed = as_signed(values)
            failures += compare(name, signed, expected_trig())
            wrap = [abs(signed[i] - signed[i + TRIG_PERIOD]) for i in range(COSINE_OFFSET)]
            if max(wrap) > TOLERANCE:
                LOG.error("%s: cosine window does not repeat the sine table "
                          "(max deviation %d)", name, max(wrap))
                failures += 1
            else:
                LOG.info("%s: cosine window repeats the first %d sine entries",
                         name, COSINE_OFFSET)
        else:
            LOG.warning("%s: unrecognised table, skipped", name)

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

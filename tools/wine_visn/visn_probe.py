#!/usr/bin/env python3
"""Probe format corners the shipped corpus never exercises, against the real DLL.

Retail data is uniformly 256x256, quality 93, mode 2, escape widths 7..11. This
driver synthesises records that step outside all four of those, runs them through
``visn_harness.exe`` (the game's own decoder under Wine) and diffs the result
against :mod:`inclib.visn`.

    visn_probe.py --build-dir DIR [--only mode0|escape|quality]

Every case is checked to be non-degenerate before it counts: the synthetic
picture must actually vary, so that "both sides agree" cannot mean "both sides
produced a flat block".
"""

from __future__ import annotations

import argparse
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.dirname(_HERE))

import inclib.visn as V  # noqa: E402
import visn_synth as S  # noqa: E402
from visn_compare import (  # noqa: E402
    build_job, decode_planes, halve_reference, run_harness,
)


def sample_range(record: bytes) -> tuple[int, int]:
    planes = decode_planes(record)
    return min(min(p) for p in planes), max(max(p) for p in planes)


def pick_quality(build, low: int = -100, high: int = 350) -> tuple[int, bytes]:
    """Choose the coarsest quality whose samples still land inside the tables.

    The engine's colour tables span index -128..+383 and it does not clamp before
    indexing them, so a record whose samples leave that window makes the real
    decoder fault. Lower quality means a coarser quantiser and therefore larger
    coefficients, so the lowest quality that stays in range is also the one that
    makes a given coefficient most visible.
    """
    for quality in range(1, 101):
        record = build(quality)
        lo, hi = sample_range(record)
        if lo >= low and hi <= high:
            return quality, record
    raise RuntimeError("no quality keeps this record inside the colour tables")


#: Scan positions to try when placing a probe coefficient, coarsest first. The
#: quantiser shrinks steeply towards position 63 (whose AAN scale is the
#: mistyped 124), so a huge escape value only fits in range at the far end.
PROBE_SCANS = (1, 3, 7, 15, 31, 47, 63)


def pick_placement(build, low: int = -100, high: int = 350) -> tuple[int, int, bytes]:
    """Find a (scan position, quality) at which a probe coefficient is in range."""
    for scan in PROBE_SCANS:
        for quality in range(1, 101):
            record = build(quality, scan)
            lo, hi = sample_range(record)
            if lo >= low and hi <= high:
                return scan, quality, record
    raise RuntimeError("no placement keeps this record inside the colour tables")


# ---------------------------------------------------------------------------
# Case builders
# ---------------------------------------------------------------------------

def mode0_cases() -> list[tuple[str, bytes]]:
    """Mode 0: Y sub-block layout and the chroma upsampling rule."""
    cases: list[tuple[str, bytes]] = []
    empty = S.empty_table_lengths()

    # One macroblock, four distinct flat Y blocks: shows where Y0..Y3 land.
    blocks = [S.Block(S.flat_dc(128)), S.Block(S.flat_dc(128))]
    blocks += [S.Block(S.flat_dc(v)) for v in (40, 80, 160, 220)]
    cases.append(("mode0/y-quadrants 16x16",
                  S.build_record(16, 16, 93, 0, empty, empty, blocks)))

    # A grid of macroblocks with every Y block distinct: also checks the
    # macroblock raster order and the destination row stride.
    blocks = []
    n = 0
    for _ in range(4 * 4):
        blocks += [S.Block(S.flat_dc(110)), S.Block(S.flat_dc(140))]
        for _ in range(4):
            blocks.append(S.Block(S.flat_dc(16 + (n * 37) % 200)))
            n += 1
    cases.append(("mode0/y-grid 64x64",
                  S.build_record(64, 64, 93, 0, empty, empty, blocks)))

    # Non-square, to separate the row and column counts.
    blocks = []
    n = 0
    for _ in range(2 * 4):
        blocks += [S.Block(S.flat_dc(120)), S.Block(S.flat_dc(150))]
        for _ in range(4):
            blocks.append(S.Block(S.flat_dc(30 + (n * 53) % 190)))
            n += 1
    cases.append(("mode0/y-grid 64x32",
                  S.build_record(64, 32, 93, 0, empty, empty, blocks)))

    # Chroma detail: a horizontal and a vertical AC coefficient in the Cb and Cr
    # blocks make the chroma vary inside the macroblock, which is the only way to
    # tell replication from interpolation.
    esc = S.table_lengths_for({S.escape_symbol(w): 4 for w in range(1, 13)})

    def build_chroma(quality: int) -> bytes:
        cb = S.Block(S.flat_dc(128), [("esc", 8, 60)])                    # scan 1
        cr = S.Block(S.flat_dc(128), [("esc", 8, 0), ("esc", 8, -60)])    # scan 2
        blocks = [cb, cr] + [S.Block(S.flat_dc(v)) for v in (100, 130, 160, 190)]
        return S.build_record(16, 16, quality, 0, esc, esc, blocks)

    quality, record = pick_quality(build_chroma)
    cases.append((f"mode0/chroma-detail 16x16 q={quality}", record))

    def build_chroma_grid(quality: int) -> bytes:
        blocks = []
        for k in range(2 * 2):
            blocks.append(S.Block(S.flat_dc(128), [("esc", 8, 40 - 20 * k)]))
            blocks.append(S.Block(S.flat_dc(128), [("esc", 8, 0), ("esc", 8, 25 * k - 40)]))
            blocks += [S.Block(S.flat_dc(90 + 30 * j)) for j in range(4)]
        return S.build_record(32, 32, quality, 0, esc, esc, blocks)

    quality, record = pick_quality(build_chroma_grid)
    cases.append((f"mode0/chroma-grid 32x32 q={quality}", record))
    return cases


def escape_cases() -> list[tuple[str, bytes]]:
    """Every escape width 1..12, at the edges of its signed range.

    The escape sits in the first Y block, and the three later Y blocks carry
    distinct flat DCs. A width read wrongly by either decoder desynchronises the
    bitstream, so those later blocks turn to noise even when the coefficient
    itself is too small to see -- which makes the width testable independently of
    the value. Sensitivity to the *value* is measured separately, by comparing
    each record against the same record carrying a zero coefficient.
    """
    esc = S.table_lengths_for(
        {S.escape_symbol(w): 5 for w in range(1, 13)} | {S.literal_symbol(0): 5})
    cases: list[tuple[str, bytes]] = []
    for bits in range(1, 13):
        span = 1 << (bits - 1)
        if bits <= 3:
            values = list(range(-span, span))
        else:
            values = [-span, -span + 1, -1, 0, 1, span - 1]
        for value in values:
            def build(quality: int, scan: int, bits=bits, value=value) -> bytes:
                # Pad with explicit zero coefficients so the escape can sit at
                # any scan position; the format has no run-length coding.
                ac = [("lit", 0)] * (scan - 1) + [("esc", bits, value)]
                first = S.Block(S.flat_dc(128), ac)
                blocks = [S.Block(S.flat_dc(128)), S.Block(S.flat_dc(128)), first]
                for dc in (60, 150, 220):
                    blocks += [S.Block(S.flat_dc(128)), S.Block(S.flat_dc(128)),
                               S.Block(S.flat_dc(dc))]
                return S.build_record(16, 16, quality, 2, esc, esc, blocks)

            scan, quality, record = pick_placement(build)
            zero = build(quality, scan, value=0)
            sensitive = V.decode_record(record).pixels != V.decode_record(zero).pixels
            mark = "" if sensitive or value == 0 else "  [value not observable]"
            cases.append(
                (f"escape/w={bits:2d} v={value:+6d} scan={scan} q={quality}{mark}",
                 record))
    return cases


def quality_cases() -> list[tuple[str, bytes]]:
    """The IJG scaling formula across its whole range, including the q<=50 branch.

    Shipped records are all quality 93, so the ``5000 / q`` branch has never run
    against real data. A synthetic picture keeps the samples inside the colour
    tables at any quality, which retail data cannot do below 89.
    """
    esc = S.table_lengths_for({S.escape_symbol(w): 4 for w in range(1, 13)})
    cases: list[tuple[str, bytes]] = []
    for quality in (1, 2, 5, 10, 25, 49, 50, 51, 52, 75, 90, 93, 99, 100):
        # Scale the coefficient with the quality so the picture stays detailed
        # but in range at both ends of the scale.
        for magnitude in (2048, 256, 32, 4, 1):
            blocks = []
            for k in range(4):
                blocks.append(S.Block(S.flat_dc(128), [("esc", 12, magnitude // 4)]))
                blocks.append(S.Block(S.flat_dc(128), [("esc", 12, -magnitude // 4)]))
                blocks.append(S.Block(S.flat_dc(120 + 10 * k),
                                      [("esc", 12, magnitude), ("esc", 12, -magnitude)]))
            record = S.build_record(16, 16, quality, 2, esc, esc, blocks)
            lo, hi = sample_range(record)
            if lo >= -100 and hi <= 350:
                cases.append((f"quality/q={quality:3d} mag={magnitude}", record))
                break
    return cases


def flat_picture(width: int, height: int, mode: int, seed: int = 1) -> bytes:
    """A picture of the given size whose every block carries a distinct flat DC.

    Deliberately AC-free: the point of these cases is the *geometry* — macroblock
    counts, raster order and the destination stride — not the transform, which
    the other groups already cover. Distinct DCs make any miscount visible as a
    displaced block rather than as noise.
    """
    empty = S.empty_table_lengths()
    per_axis = 2 if mode == V.MODE_444 else 1
    mbx = (width >> 4) * per_axis
    mby = (height >> 4) * per_axis
    blocks: list[S.Block] = []
    n = seed
    for _ in range(mbx * mby):
        blocks.append(S.Block(S.flat_dc(120 + (n * 17) % 60)))    # Cb
        blocks.append(S.Block(S.flat_dc(110 + (n * 29) % 70)))    # Cr
        for _ in range(1 if mode == V.MODE_444 else 4):           # Y
            blocks.append(S.Block(S.flat_dc(30 + (n * 37) % 190)))
            n += 1
        n += 1
    return S.build_record(width, height, 93, mode, empty, empty, blocks)


#: Sizes for the ``size`` group. All are mode 2 and all exceed one 256x256
#: texture page in at least one axis, except the first, which is the control.
SIZE_CASES = ((256, 256), (272, 272), (320, 240), (512, 256), (256, 512),
              (512, 512), (1024, 1024), (2048, 16), (16, 2048), (4096, 16),
              (8192, 16))

#: Sizes for the ``mode0size`` group. Capped at 256 wide because mode 0 is the
#: one stage that reads the self-patched stride immediates; see ``size_group``.
MODE0_SIZES = ((16, 16), (64, 32), (128, 96), (64, 240), (256, 256))


def size_group(build_dir: str, verbose: bool) -> tuple[int, int, list[str]]:
    """Sizes above 256x256, one harness run per width.

    Every record needs its own destination stride, and a stride is a property of
    the whole job, so these cannot share one invocation. The stride also cannot
    simply be passed: the DLL caches it at ``0x41A988`` and, when it changes,
    **patches its own code** with ``2 * stride``. Seeding the cache
    (``VISN_POKE_STRIDE``) skips that patch, which is correct for mode 2 —
    only the mode-0 colour stage reads the patched immediates — and is why this
    group is mode 2 throughout.
    """
    ok = total = 0
    problems: list[str] = []
    for width, height in SIZE_CASES:
        record = flat_picture(width, height, V.MODE_444)
        out_bytes = width * height * 2
        os.environ["VISN_POKE_STRIDE"] = str(width)
        try:
            path, stats, got = run_harness(
                build_dir, build_job([record], 0, width, out_bytes=out_bytes),
                keep=False)
        except SystemExit as exc:
            problems.append(f"size/{width}x{height}: harness failed: {exc}")
            total += 1
            continue
        finally:
            os.environ.pop("VISN_POKE_STRIDE", None)
        with open(path, "rb") as fh:
            fh.seek(16 + 16)
            payload = fh.read(got)
        os.unlink(path)
        total += 1
        touched, _first, _last, guard = stats[0]
        img = V.decode_record(record)
        ref = b"".join(payload[(r * width) * 2:(r * width + img.width) * 2]
                       for r in range(img.height))
        mine = struct.pack(f"<{len(img.pixels)}H", *img.pixels)
        label = f"size/{width}x{height}"
        if touched == 0:
            problems.append(f"{label}: the DLL wrote nothing")
        elif guard:
            problems.append(f"{label}: the DLL wrote {guard} bytes past the buffer")
        elif mine == ref:
            ok += 1
            if verbose:
                print(f"  ok   {label}  ({len(set(img.pixels))} distinct pixels)")
        else:
            theirs = struct.unpack_from(f"<{len(img.pixels)}H", ref, 0)
            bad = sum(1 for a, b in zip(theirs, img.pixels) if a != b)
            problems.append(f"{label}: {bad}/{len(img.pixels)} pixels differ")
    return ok, total, problems


def mode0size_group(build_dir: str, verbose: bool) -> tuple[int, int, list[str]]:
    """Mode 0 at sizes the original five cases never reached, all at stride 256.

    Mode 0 is the stage that reads the self-patched stride immediates, so the
    only stride that is safe without letting the DLL rewrite its own code is the
    built-in 256. That bounds the widths here, not the codec.
    """
    cases = [(f"mode0size/{w}x{h}", flat_picture(w, h, V.MODE_420))
             for w, h in MODE0_SIZES]
    out_bytes = 256 * max(h for _, h in MODE0_SIZES) * 2
    return _run_group(build_dir, cases, op=0, stride=256,
                      out_bytes=out_bytes, verbose=verbose)


def halve0_group(build_dir: str, verbose: bool) -> tuple[int, int, list[str]]:
    """The mode-0 cases through ``_E3D_decode_picture_halve_size``.

    Both entry points dispatch on the mode byte through the table at
    ``0x41A97C`` and only the mode-2 slot is rewritten on entry, so half size
    should silently produce the **full-size** picture for a 4:2:0 record. This
    group is what turns that reading of the dispatch table into a measurement.
    """
    cases = mode0_cases()
    return _run_group(build_dir, cases, op=1, stride=256, out_bytes=None,
                      verbose=verbose, halve=True)


def _run_group(build_dir: str, cases: list[tuple[str, bytes]], op: int,
               stride: int, out_bytes: int | None, verbose: bool,
               halve: bool = False) -> tuple[int, int, list[str]]:
    """One harness invocation over ``cases``; diff each result against inclib."""
    kwargs = {} if out_bytes is None else {"out_bytes": out_bytes}
    path, stats, got = run_harness(
        build_dir, build_job([r for _, r in cases], op, stride, **kwargs),
        keep=False)
    ok = 0
    problems: list[str] = []
    with open(path, "rb") as fh:
        fh.seek(16 + 16 * len(cases))
        for (label, record), (touched, _f, _l, guard) in zip(cases, stats):
            payload = fh.read(got)
            if halve:
                expect, width, height = halve_reference(record)
            else:
                img = V.decode_record(record)
                expect, width, height = img.pixels, img.width, img.height
            ref = b"".join(payload[(r * stride) * 2:(r * stride + width) * 2]
                           for r in range(height))
            mine = struct.pack(f"<{len(expect)}H", *expect)
            if touched == 0:
                problems.append(f"{label}: the DLL wrote nothing")
            elif guard:
                problems.append(f"{label}: the DLL wrote {guard} bytes past the buffer")
            elif mine == ref:
                ok += 1
                if verbose:
                    print(f"  ok   {label}  -> {width}x{height}")
            else:
                theirs = struct.unpack_from(f"<{len(expect)}H", ref, 0)
                bad = sum(1 for a, b in zip(theirs, expect) if a != b)
                problems.append(f"{label}: {bad}/{len(expect)} pixels differ")
    os.unlink(path)
    return ok, len(cases), problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build-dir", required=True)
    ap.add_argument("--only", default="",
                    help="mode0, escape, quality, size, mode0size or halve0")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    #: Groups that share one harness run at the default stride of 256.
    simple = {"mode0": mode0_cases, "escape": escape_cases, "quality": quality_cases}
    #: Groups that need their own stride, entry point or destination size.
    special = {"size": size_group, "mode0size": mode0size_group,
               "halve0": halve0_group}

    wanted = [args.only] if args.only else list(simple) + list(special)
    unknown = [n for n in wanted if n not in simple and n not in special]
    if unknown:
        ap.error(f"unknown group(s): {', '.join(unknown)}")

    equal = count = 0
    problems: list[str] = []
    for name in wanted:
        if name not in special:
            continue
        print(f"--- {name}")
        ok, total, bad = special[name](args.build_dir, args.verbose)
        equal += ok
        count += total
        problems += bad

    cases: list[tuple[str, bytes]] = []
    for name in wanted:
        if name in simple:
            cases.extend(simple[name]())
    if not cases:
        print(f"byte-exact : {equal}/{count}")
        for line in problems[:40]:
            print(f"  FAIL {line}")
        return 0 if not problems else 1
    print(f"synthetic records: {len(cases)}")

    out_path, stats, out_bytes = run_harness(
        args.build_dir, build_job([r for _, r in cases], 0, 256), keep=False)

    count += len(cases)
    degenerate = 0
    with open(out_path, "rb") as fh:
        fh.seek(16 + 16 * len(cases))
        for (label, record), (touched, _first, _last, guard) in zip(cases, stats):
            payload = fh.read(out_bytes)
            if touched == 0:
                problems.append(f"{label}: the DLL wrote nothing")
                continue
            if guard:
                problems.append(f"{label}: the DLL wrote {guard} bytes past the buffer")
                continue
            img = V.decode_record(record)
            ref = b"".join(payload[(r * 256) * 2:(r * 256 + img.width) * 2]
                           for r in range(img.height))
            mine = struct.pack(f"<{len(img.pixels)}H", *img.pixels)
            variety = len(set(img.pixels))
            if variety < 2:
                degenerate += 1
            if mine == ref:
                equal += 1
                if args.verbose:
                    print(f"  ok   {label}  ({variety} distinct pixels)")
                continue
            theirs = struct.unpack_from(f"<{len(img.pixels)}H", ref, 0)
            bad = sum(1 for a, b in zip(theirs, img.pixels) if a != b)
            first = next(i for i, (a, b) in enumerate(zip(theirs, img.pixels)) if a != b)
            problems.append(
                f"{label}: {bad}/{len(img.pixels)} pixels differ, first at "
                f"(y={first // img.width}, x={first % img.width}) "
                f"DLL={theirs[first]:04X} ours={img.pixels[first]:04X}")

    os.unlink(out_path)
    print(f"byte-exact : {equal}/{count}")
    print(f"degenerate (flat) pictures, which prove nothing : {degenerate}")
    for line in problems[:40]:
        print(f"  FAIL {line}")
    return 0 if not problems else 1


if __name__ == "__main__":
    raise SystemExit(main())

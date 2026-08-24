#!/usr/bin/env python3
"""Compare our from-scratch VISN decoder against the game's own decoder.

This drives ``visn_harness.exe`` (a 32-bit Windows program that calls
``_E3D_decode_picture`` inside the shipped ``Eng3d.dll``) under Wine, then
diffs the RGB565 buffers the DLL produced against ``VisnImage.pixels`` from
:mod:`inclib.visn`.

The DLL is ground truth. Any disagreement is our bug.

Usage:
    visn_compare.py GOG_DIR --build-dir DIR [options]

Options:
    --limit N          only the first N records of each container
    --containers PAT   substring filter on the container label
    --op halve         call _E3D_decode_picture_halve_size instead
    --op convert       feed our RGB565 output through
                       _E3D_convert_picblock_from_64kcolor_to_32kcolor
    --pixel-format N   _E3D_init_vision argument: 0x565 (default) or 0x555
    --dump-first N     print the first N output words from both decoders
    --keep             keep the job/result files for inspection
"""

from __future__ import annotations

import argparse
import os
import struct
import subprocess
import sys
import tempfile
import time

_TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _TOOLS)

import inclib.visn as visn  # noqa: E402
from inclib.visn import VisnError, decode_record  # noqa: E402
from visn_decode import Container, find_containers, _load  # noqa: E402

#: Default bytes the harness captures per record: one full 256x256 RGB565 page.
OUT_BYTES = 256 * 256 * 2

OP_DECODE = 0
OP_HALVE = 1
OP_CONVERT = 2

#: ``_E3D_init_vision`` arguments. Only the three channel tables depend on this.
FMT_RGB565 = 0x565
FMT_RGB555 = 0x555


def build_job(records: list[bytes], op: int, stride: int,
              pixel_format: int = FMT_RGB565, out_bytes: int = OUT_BYTES) -> bytes:
    """Pack records into the harness job-file format (24-byte header)."""
    header_len = 24 + 8 * len(records)
    index = bytearray()
    blob = bytearray()
    for rec in records:
        index += struct.pack("<II", header_len + len(blob), len(rec))
        blob += rec
    return (b"VJOB"
            + struct.pack("<IIIII", len(records), op, stride, pixel_format, out_bytes)
            + bytes(index) + bytes(blob))


def run_harness(build_dir: str, job: bytes, keep: bool) -> tuple[str, list[tuple[int, int, int, int]], int]:
    """Run the harness under Wine; return (result path, per-record stats, out_bytes)."""
    job_path = os.path.join(build_dir, "job.bin")
    out_path = os.path.join(build_dir, "out.bin")
    with open(job_path, "wb") as fh:
        fh.write(job)

    env = dict(os.environ)
    env.setdefault("WINEDEBUG", "-all")
    if "WINEPREFIX" not in env:
        raise SystemExit("WINEPREFIX must be set to a prepared 32-bit-capable Wine prefix")

    started = time.time()
    proc = subprocess.run(
        ["wine", "visn_harness.exe", "Eng3d.dll", "job.bin", "out.bin"],
        cwd=build_dir, env=env, capture_output=True, text=True,
    )
    elapsed = time.time() - started
    # Wine's own chatter (MoltenVK etc.) goes to stderr; keep only our lines.
    for line in proc.stderr.splitlines():
        if line.startswith("harness:"):
            print(f"  [wine] {line}")
    if proc.returncode != 0:
        print(proc.stderr[-4000:], file=sys.stderr)
        raise SystemExit(f"harness exited {proc.returncode}")
    print(f"  [wine] {elapsed:.1f}s wall")

    with open(out_path, "rb") as fh:
        head = fh.read(16)
        if head[:4] != b"VOUT":
            raise SystemExit("harness produced a malformed result file")
        count, out_bytes, _op = struct.unpack("<III", head[4:])
        raw = fh.read(16 * count)
    stats = [struct.unpack_from("<IIII", raw, i * 16) for i in range(count)]
    if not keep:
        os.unlink(job_path)
    return out_path, stats, out_bytes


def decode_planes(record: bytes) -> tuple[list[int], list[int], list[int]]:
    """Decode a record and return its pre-colour Y/Cb/Cr sample planes."""
    original = visn._convert_colour
    captured: dict = {}

    def spy(py, pcb, pcr, *rest):
        captured["planes"] = (py, pcb, pcr)
        return original(py, pcb, pcr, *rest)

    visn._convert_colour = spy
    try:
        visn.decode_record(record)
    finally:
        visn._convert_colour = original
    return captured["planes"]


def halve_reference(record: bytes,
                    pixel_format: int = FMT_RGB565) -> tuple[list[int], int, int]:
    """Model _E3D_decode_picture_halve_size and return (pixels, width, height).

    Eng3d.dll @ 0x413814 runs the ordinary full 8x8 inverse transform and then,
    per output pixel, averages the 2x2 group of Y, Cb and Cr *samples* with an
    arithmetic shift right by two before the usual colour lookup. The averaging
    is therefore in the YCbCr domain, ahead of the tables -- it is neither a
    reduced transform nor a decimation, and it is not the same as averaging the
    finished RGB565 pixels.

    **Mode 0 is not halved at all.** Both entry points dispatch on the mode byte
    through the table at 0x41a97c, and only the mode-2 slot (0x41a984) is
    rewritten on entry -- 0x412868 for the full-size call, 0x412945 for the
    half-size one. The mode-0 slot is the constant 0x412749, so asking for half
    size on a 4:2:0 record silently produces the full-size picture.
    """
    img = visn.decode_record(record, pixel_format=pixel_format)
    if img.mode == visn.MODE_420:
        return img.pixels, img.width, img.height
    plane_y, plane_cb, plane_cr = decode_planes(record)
    out_w = (img.width >> 4) * 2 * 4
    out_h = (img.height >> 4) * 2 * 4
    half_y, half_cb, half_cr = [], [], []
    for y in range(out_h):
        top = 2 * y * img.width
        bottom = top + img.width
        for x in range(out_w):
            a, b = 2 * x, 2 * x + 1
            half_y.append((plane_y[top + a] + plane_y[top + b]
                           + plane_y[bottom + a] + plane_y[bottom + b]) >> 2)
            half_cb.append((plane_cb[top + a] + plane_cb[top + b]
                            + plane_cb[bottom + a] + plane_cb[bottom + b]) >> 2)
            half_cr.append((plane_cr[top + a] + plane_cr[top + b]
                            + plane_cr[bottom + a] + plane_cr[bottom + b]) >> 2)
    return visn._convert_colour(half_y, half_cb, half_cr, pixel_format), out_w, out_h


def field_deltas(a: int, b: int) -> tuple[int, int, int]:
    """Per-channel signed differences of two RGB565 words."""
    return (
        ((a >> 11) & 31) - ((b >> 11) & 31),
        ((a >> 5) & 63) - ((b >> 5) & 63),
        (a & 31) - (b & 31),
    )


def run_convert(args, jobs: list[bytes], labels: list[str]) -> int:
    """Drive _E3D_convert_picblock_from_64kcolor_to_32kcolor over real pixels.

    The input is our own RGB565 output, which section 10.6 already proves is
    byte-identical to what the DLL's decoder produces, so this isolates the
    colour-depth conversion from everything upstream of it.
    """
    buffers: list[bytes] = []
    references: list[list[int]] = []
    kept: list[str] = []
    for record, label in zip(jobs, labels):
        try:
            img = decode_record(record, pixel_format=FMT_RGB565)
        except VisnError as exc:
            print(f"  skipped {label}: our decoder failed: {exc}")
            continue
        # The routine's element counter is `sar ecx,1` feeding a dec/jne
        # do-while, so counts of 0 and 1 wrap it to 2**32-1. Everything here is
        # a whole picture, but the guard is cheap and the hazard is real.
        if len(img.pixels) < 2:
            continue
        buffers.append(struct.pack(f"<{len(img.pixels)}H", *img.pixels))
        references.append(visn.convert_64k_to_32k(img.pixels))
        kept.append(label)

    # Odd element counts take a different code path: the routine handles one
    # leading 16-bit pixel before switching to its 32-bit main loop. Retail
    # pictures all have an even pixel count, so an odd case is spliced in.
    if buffers:
        odd = buffers[0][: (len(buffers[0]) // 2 - 1) * 2]
        pixels = list(struct.unpack(f"<{len(odd) // 2}H", odd))
        buffers.append(odd)
        references.append(visn.convert_64k_to_32k(pixels))
        kept.append("<synthetic odd-length buffer>")

    out_bytes = args.out_bytes or max(len(b) for b in buffers)
    print(f"buffers queued : {len(buffers)}, {out_bytes} bytes captured per buffer")
    out_path, stats, out_bytes = run_harness(
        args.build_dir,
        build_job(buffers, OP_CONVERT, args.stride, FMT_RGB565, out_bytes),
        args.keep)

    equal = 0
    degenerate = 0
    failures: list[str] = []
    with open(out_path, "rb") as fh:
        fh.seek(16 + 16 * len(buffers))
        for label, source, reference, (touched, _f, _l, guard) in zip(
                kept, buffers, references, stats):
            payload = fh.read(out_bytes)
            if touched == 0:
                failures.append(f"{label}: the DLL wrote nothing")
                continue
            if guard:
                failures.append(f"{label}: the DLL wrote {guard} bytes past the buffer")
                continue
            if len(set(reference)) < 2:
                degenerate += 1
            got = list(struct.unpack_from(f"<{len(reference)}H", payload, 0))
            if got == reference:
                equal += 1
                continue
            bad = sum(1 for a, b in zip(got, reference) if a != b)
            first = next(k for k, (a, b) in enumerate(zip(got, reference)) if a != b)
            failures.append(
                f"{label}: {bad}/{len(reference)} pixels differ, first at {first}: "
                f"in={struct.unpack_from('<H', source, first * 2)[0]:04X} "
                f"DLL={got[first]:04X} ours={reference[first]:04X}")

    os.unlink(out_path)
    print()
    print(f"buffers compared    : {len(buffers)}")
    print(f"byte-exact matches  : {equal}")
    print(f"mismatches          : {len(buffers) - equal}")
    print(f"degenerate (flat)   : {degenerate}")
    for line in failures[:25]:
        print(f"  FAIL {line}")
    return 0 if not failures else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", help="gog_incubation directory (or a single texture.lib)")
    ap.add_argument("--build-dir", required=True,
                    help="directory holding visn_harness.exe, Eng3d.dll and ENGWLIB.DLL")
    ap.add_argument("--limit", type=int, default=0, help="first N records per container")
    ap.add_argument("--containers", default="", help="substring filter on container label")
    ap.add_argument("--op", choices=("decode", "halve", "convert"), default="decode")
    ap.add_argument("--stride", type=int, default=256)
    ap.add_argument("--pixel-format", type=lambda v: int(v, 0), default=FMT_RGB565,
                    help="_E3D_init_vision argument: 0x565 (default) or 0x555")
    ap.add_argument("--out-bytes", type=int, default=0,
                    help="destination buffer size; 0 = stride * max height * 2")
    ap.add_argument("--patch-quality", type=int, default=0,
                    help="overwrite the record's quality byte (header +8) before "
                         "decoding, to exercise IJG scaling at q != 93")
    ap.add_argument("--patch-size", default="",
                    help="overwrite the record's WxH (header +4/+6); the bitstream "
                         "is reinterpreted with fewer macroblocks")
    ap.add_argument("--dump-first", type=int, default=0,
                    help="print this many output words from both decoders, record 0")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args(argv)

    containers: list[Container] = find_containers(args.path)
    if args.containers:
        containers = [c for c in containers if args.containers.lower() in c.label.lower()]
    if not containers:
        raise SystemExit("no containers matched")

    jobs: list[bytes] = []
    labels: list[str] = []
    for container in containers:
        data, entries = _load(container)
        chosen = entries[: args.limit] if args.limit else entries
        for entry in chosen:
            rec = bytearray(data[entry.offset: entry.offset + entry.size])
            if args.patch_quality:
                rec[8] = args.patch_quality
            if args.patch_size:
                w, h = (int(v) for v in args.patch_size.lower().split("x"))
                struct.pack_into("<HH", rec, 4, w, h)
            jobs.append(bytes(rec))
            labels.append(f"{container.label}/{entry.name}")

    print(f"records queued : {len(jobs)} from {len(containers)} container(s)")
    op = {"decode": OP_DECODE, "halve": OP_HALVE, "convert": OP_CONVERT}[args.op]

    if op == OP_CONVERT:
        return run_convert(args, jobs, labels)

    heights = [struct.unpack_from("<H", rec, 6)[0] for rec in jobs]
    want = args.out_bytes or max(OUT_BYTES, args.stride * max(heights) * 2)
    print(f"pixel format   : 0x{args.pixel_format:03X}")
    print(f"destination    : stride {args.stride}, {want} bytes captured per record")
    out_path, stats, out_bytes = run_harness(
        args.build_dir,
        build_job(jobs, op, args.stride, args.pixel_format, want), args.keep)

    equal = 0
    failures: list[str] = []
    never_written = 0
    guard_hits = 0
    delta_hist: dict[tuple[int, int, int], int] = {}
    worst_records: list[tuple[int, str]] = []

    with open(out_path, "rb") as fh:
        fh.seek(16 + 16 * len(jobs))
        for i, label in enumerate(labels):
            payload = fh.read(out_bytes)
            touched, first_diff, last_diff, guard_dirty = stats[i]
            if guard_dirty:
                guard_hits += 1
            if touched == 0:
                never_written += 1
                failures.append(f"{label}: DLL wrote nothing (buffer still poison)")
                continue

            if op == OP_HALVE:
                try:
                    ref_pixels, out_w, out_h = halve_reference(
                        jobs[i], args.pixel_format)
                except VisnError as exc:
                    failures.append(f"{label}: our decoder failed: {exc}")
                    continue
                got = [struct.unpack_from("<H", payload,
                                          (r * args.stride + c) * 2)[0]
                       for r in range(out_h) for c in range(out_w)]
                if got == ref_pixels:
                    equal += 1
                else:
                    bad = sum(1 for a, b in zip(got, ref_pixels) if a != b)
                    first = next(k for k, (a, b) in enumerate(zip(got, ref_pixels))
                                 if a != b)
                    failures.append(
                        f"{label}: halve output differs in {bad}/{len(ref_pixels)} "
                        f"pixels of the {out_w}x{out_h} result, first at "
                        f"(y={first // out_w}, x={first % out_w}) "
                        f"DLL={got[first]:04X} ours={ref_pixels[first]:04X}")
                continue

            try:
                img = decode_record(jobs[i], pixel_format=args.pixel_format)
            except VisnError as exc:
                failures.append(f"{label}: our decoder failed: {exc}")
                continue

            # The DLL writes img.width pixels per row at args.stride pixels of
            # pitch, so a patched-down width leaves the row tails untouched.
            if args.stride == img.width:
                ref = payload[: img.width * img.height * 2]
            else:
                ref = b"".join(
                    payload[(r * args.stride) * 2:(r * args.stride + img.width) * 2]
                    for r in range(img.height))
            mine = struct.pack(f"<{len(img.pixels)}H", *img.pixels)
            if args.dump_first and i < 1:
                n = args.dump_first
                all_words = struct.unpack_from(f"<{len(img.pixels)}H", ref, 0)
                # Start the dump at the first non-zero word so an all-black
                # corner cannot make a vacuous "match" look convincing.
                start = next((k for k, w in enumerate(all_words) if w), 0)
                nonzero = sum(1 for w in all_words if w)
                distinct = len(set(all_words))
                print(f"  record {i} ({label}): DLL buffer touched={touched} B, "
                      f"non-zero words={nonzero}, distinct values={distinct}")
                print(f"  {n} words from offset {start}:")
                print("    DLL   :", " ".join(f"{w:04X}" for w in all_words[start:start + n]))
                print("    python:", " ".join(f"{w:04X}" for w in img.pixels[start:start + n]))

            if mine == ref:
                equal += 1
                continue

            # The engine only writes 2*(size>>4) macroblocks of 8 pixels per
            # axis, so a size that is not a multiple of 16 leaves a right and
            # bottom margin untouched. Those pixels hold whatever the caller's
            # buffer held (here: the poison byte), so they are reported apart
            # from real disagreements.
            wrote_w = (img.width >> 4) * 2 * 8
            wrote_h = (img.height >> 4) * 2 * 8
            theirs = struct.unpack_from(f"<{len(img.pixels)}H", ref, 0)
            bad = 0
            margin = 0
            first = -1
            for j, (a, b) in enumerate(zip(theirs, img.pixels)):
                if a == b:
                    continue
                if j % img.width >= wrote_w or j // img.width >= wrote_h:
                    margin += 1
                    continue
                bad += 1
                if first < 0:
                    first = j
                d = field_deltas(a, b)
                delta_hist[d] = delta_hist.get(d, 0) + 1
            if bad == 0:
                equal += 1
                if margin:
                    print(f"  {label}: exact over the {wrote_w}x{wrote_h} region "
                          f"the engine writes; {margin} pixels of unwritten margin ignored")
                continue
            worst_records.append((bad, label))
            failures.append(
                f"{label}: {bad}/{len(img.pixels)} pixels differ ({margin} in the "
                f"unwritten margin), first at {first} "
                f"(y={first // img.width}, x={first % img.width}), "
                f"DLL={theirs[first]:04X} ours={img.pixels[first]:04X}")

    print()
    print(f"records compared    : {len(jobs)}")
    print(f"byte-exact matches  : {equal}")
    print(f"mismatches          : {len(jobs) - equal - never_written}")
    print(f"DLL wrote nothing   : {never_written}")
    print(f"guard-region writes : {guard_hits}")

    if delta_hist:
        print("\nper-channel delta histogram (DLL - ours), top 20:")
        for d, n in sorted(delta_hist.items(), key=lambda kv: -kv[1])[:20]:
            print(f"  dR={d[0]:+d} dG={d[1]:+d} dB={d[2]:+d} : {n}")
    if worst_records:
        print("\nworst records:")
        for bad, label in sorted(worst_records, reverse=True)[:15]:
            print(f"  {bad:8d}  {label}")
    if failures:
        print(f"\nfirst 25 of {len(failures)} problem records:")
        for line in failures[:25]:
            print(f"  {line}")

    if not args.keep:
        os.unlink(out_path)
    return 0 if (not failures and guard_hits == 0) else 1


if __name__ == "__main__":
    raise SystemExit(main())

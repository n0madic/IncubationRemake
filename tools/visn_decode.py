#!/usr/bin/env python3
"""Decode Incubation VISN texture containers to PNG files.

Every ``texture.lib`` under ``WorldSet/*/TEXTURES/`` and ``Video/*/Textures/``
is a plain concatenation of VISN records, addressed by the sibling ``texture.din``
(binary) or ``texture.dir`` (ASCII) table of contents. This tool enumerates those
records, decodes them with :mod:`inclib.visn` and writes 24-bit PNGs.

Usage:
    visn_decode.py gog_incubation --list
    visn_decode.py gog_incubation --check
    visn_decode.py gog_incubation -o tools/out/textures
    visn_decode.py gog_incubation/WorldSet/World_A00/TEXTURES/texture.lib -o out/
    visn_decode.py gog_incubation --contact-sheet tools/out/textures/contact.png
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys
import time
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.png import write_rgb_png  # noqa: E402
from inclib.visn import (  # noqa: E402
    RGB565_TO_RGB888,
    ContainerEntry,
    VisnError,
    VisnImage,
    decode_record,
    derive_rgb565,
    parse_header,
    read_din_index,
)

LOG = logging.getLogger("visn_decode")

#: Non-portable characters in record names (five records use cp1252 0xE4, 'ä').
_UNSAFE_NAME = re.compile(r"[^A-Za-z0-9._-]")


@dataclass(frozen=True)
class Container:
    """A ``texture.lib`` paired with its ``.din`` index."""

    lib_path: str
    din_path: str

    @property
    def label(self) -> str:
        """A short, unique, filesystem-safe name such as ``WorldSet_World_A00``."""
        textures_dir = os.path.dirname(os.path.abspath(self.lib_path))
        world_dir = os.path.dirname(textures_dir)
        group = os.path.basename(os.path.dirname(world_dir))
        return f"{group}_{os.path.basename(world_dir)}"


def find_containers(root: str) -> list[Container]:
    """Locate every VISN container at or below ``root``.

    ``root`` may be a ``texture.lib`` itself or a directory to walk. Filenames
    are matched case-insensitively: the retail tree mixes ``texture.lib`` with
    ``Texture.lib`` and ``TEXTURES`` with ``Textures``.
    """
    if os.path.isfile(root):
        return [_pair_with_index(root)]

    found: list[Container] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.lower() == "texture.lib":
                found.append(_pair_with_index(os.path.join(dirpath, name)))
    return sorted(found, key=lambda c: c.lib_path)


def _pair_with_index(lib_path: str) -> Container:
    stem = os.path.splitext(lib_path)[0]
    for candidate in (stem + ".din", stem + ".DIN"):
        if os.path.exists(candidate):
            return Container(lib_path, candidate)
    raise VisnError(f"{lib_path}: no sibling .din index found")


def safe_filename(name: str) -> str:
    """Make a record name safe to use as a filename, keeping it recognisable."""
    cleaned = _UNSAFE_NAME.sub("_", name)
    return cleaned or "unnamed"


def _load(container: Container) -> tuple[bytes, list[ContainerEntry]]:
    with open(container.lib_path, "rb") as fh:
        data = fh.read()
    return data, read_din_index(container.din_path)


def cmd_list(containers: list[Container]) -> int:
    """Print the index of every container without decoding anything."""
    total = 0
    for container in containers:
        data, entries = _load(container)
        print(f"{container.lib_path}  ({len(entries)} records, {len(data)} bytes)")
        cursor = 0
        for entry in entries:
            try:
                width, height, quality, mode = parse_header(data, entry.offset)
                header = f"{width}x{height} q={quality} mode={mode}"
            except VisnError as exc:
                header = f"BAD HEADER: {exc}"
            gap = "" if entry.offset == cursor else f"  GAP from {cursor}"
            cursor = entry.offset + entry.size
            print(
                f"  [{entry.index:3d}] {entry.name:<14} "
                f"offset={entry.offset:<9} size={entry.size:<7} {header}{gap}"
            )
        if cursor != len(data):
            print(f"  TRAILING BYTES: index ends at {cursor}, file is {len(data)}")
        total += len(entries)
    print(f"\n{len(containers)} containers, {total} records")
    return 0


def cmd_check(containers: list[Container]) -> int:
    """Decode everything, write nothing, and report success and failure counts.

    Besides catching hard errors this reports the *slack*: the bytes of each
    record left unread by the bitstream. A Huffman or bitstream desync would
    make the slack drift wildly, so a tight slack across every record is strong
    evidence the entropy layer is being read correctly.

    It also requires that the engine's RGB565 picture **derives** from the exact
    24-bit one (:func:`derive_rgb565`) on every record: the remake's cache
    carries only the latter (docs/50 section 9.1), so a record where the two
    part would be drawn wrong under the original's colour depth.
    """
    ok = 0
    underived: list[tuple[str, str, int]] = []
    failures: list[tuple[str, str, str]] = []
    slack_hist: dict[int, int] = {}
    overrun_hist: dict[int, int] = {}
    started = time.monotonic()

    for container in containers:
        data, entries = _load(container)
        for entry in entries:
            try:
                image = decode_record(data, entry.offset, entry.size, exact=True)
            except Exception as exc:  # noqa: BLE001 - every failure is reported, never hidden
                failures.append((container.lib_path, entry.name, f"{type(exc).__name__}: {exc}"))
                continue
            ok += 1
            assert image.exact is not None
            derived = derive_rgb565(image.exact)
            if derived != image.pixels:
                differ = sum(1 for a, b in zip(derived, image.pixels) if a != b)
                underived.append((container.lib_path, entry.name, differ))
            slack = entry.size - image.bytes_read
            slack_hist[slack] = slack_hist.get(slack, 0) + 1
            overrun_hist[image.overrun_words] = overrun_hist.get(image.overrun_words, 0) + 1

    elapsed = time.monotonic() - started
    total = ok + len(failures)
    print(f"containers : {len(containers)}")
    print(f"records    : {total}")
    print(f"decoded    : {ok}")
    print(f"failed     : {len(failures)}")
    print(f"elapsed    : {elapsed:.1f}s ({elapsed / max(total, 1) * 1000:.0f} ms/record)")
    print("slack bytes: " + ", ".join(
        f"{k}->{v}" for k, v in sorted(slack_hist.items())
    ))
    print("overrun words: " + ", ".join(
        f"{k}->{v}" for k, v in sorted(overrun_hist.items())
    ))
    print(f"RGB565 derived from the exact RGB888: {ok - len(underived)}/{ok}")
    for lib, name, err in failures:
        print(f"FAIL {lib} :: {name} :: {err}")
    for lib, name, differ in underived:
        print(f"FAIL {lib} :: {name} :: {differ} pixels do not derive")
    return 1 if failures or underived or ok == 0 else 0


def cmd_decode(containers: list[Container], out_dir: str) -> int:
    """Decode every record and write ``<out_dir>/<container>/<name>.png``."""
    written = 0
    failures = 0
    for container in containers:
        data, entries = _load(container)
        target = os.path.join(out_dir, container.label)
        os.makedirs(target, exist_ok=True)
        for entry in entries:
            try:
                image = decode_record(data, entry.offset, entry.size)
            except Exception as exc:  # noqa: BLE001 - reported, not hidden
                LOG.error("%s :: %s :: %s", container.lib_path, entry.name, exc)
                failures += 1
                continue
            path = os.path.join(target, f"{safe_filename(entry.name)}.png")
            write_rgb_png(path, image.width, image.height, image.to_rgb888())
            written += 1
        LOG.info("%s -> %s", container.lib_path, target)
    print(f"wrote {written} PNGs to {out_dir} ({failures} failures)")
    return 1 if failures else 0


def _thumbnail(image: VisnImage, size: int) -> list[int]:
    """Nearest-neighbour downscale of an RGB565 picture to ``size`` x ``size``."""
    src = image.pixels
    width, height = image.width, image.height
    out = []
    for y in range(size):
        row = (y * height // size) * width
        for x in range(size):
            out.append(src[row + (x * width // size)])
    return out


def cmd_contact_sheet(containers: list[Container], path: str, cell: int, per_lib: int) -> int:
    """Tile a sample of decoded textures into one PNG for eyeballing."""
    thumbs: list[list[int]] = []
    for container in containers:
        data, entries = _load(container)
        step = max(1, len(entries) // per_lib)
        for entry in entries[::step][:per_lib]:
            try:
                thumbs.append(_thumbnail(decode_record(data, entry.offset, entry.size), cell))
            except Exception as exc:  # noqa: BLE001
                LOG.error("%s :: %s :: %s", container.lib_path, entry.name, exc)

    if not thumbs:
        LOG.error("no textures decoded, nothing to draw")
        return 1

    cols = 12
    rows = (len(thumbs) + cols - 1) // cols
    width, height = cols * cell, rows * cell
    canvas = bytearray(width * height * 3)
    for i, thumb in enumerate(thumbs):
        ox, oy = (i % cols) * cell, (i // cols) * cell
        for y in range(cell):
            base = ((oy + y) * width + ox) * 3
            canvas[base:base + cell * 3] = b"".join(
                [RGB565_TO_RGB888[p] for p in thumb[y * cell:(y + 1) * cell]]
            )

    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    write_rgb_png(path, width, height, bytes(canvas))
    print(f"contact sheet: {len(thumbs)} textures, {width}x{height} -> {path}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("path", help="a texture.lib, or a directory to search")
    parser.add_argument("-o", "--out", help="directory to write PNGs into")
    parser.add_argument("--list", action="store_true", help="list records, decode nothing")
    parser.add_argument("--check", action="store_true",
                        help="decode everything, write nothing, report counts")
    parser.add_argument("--contact-sheet", metavar="PNG",
                        help="write a tiled sample of decoded textures")
    parser.add_argument("--cell", type=int, default=64, help="contact sheet cell size")
    parser.add_argument("--per-lib", type=int, default=6,
                        help="contact sheet samples per container")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    containers = find_containers(args.path)
    if not containers:
        LOG.error("no VISN containers found under %s", args.path)
        return 1
    LOG.debug("found %d containers", len(containers))

    if args.list:
        return cmd_list(containers)
    if args.check:
        return cmd_check(containers)
    if args.contact_sheet:
        return cmd_contact_sheet(containers, args.contact_sheet, args.cell, args.per_lib)
    if args.out:
        return cmd_decode(containers, args.out)

    parser.error("nothing to do: pass --list, --check, --contact-sheet or -o")
    return 2


if __name__ == "__main__":
    sys.exit(main())

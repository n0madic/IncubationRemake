#!/usr/bin/env python3
"""Generic token/chunk walker for Charisma ``.cho`` / ``.cha`` streams.

This is the exploration tool that was used to reverse the grammar, kept as a
debugging aid.  It makes **no assumption about field layouts**: it scans the
byte stream for ``u32 length`` + ASCII records, keeps the ones that spell a
known Charisma class name, and dumps everything in between as raw hex plus
candidate interpretations (u16 / u32 / f32 / length-prefixed string).

Modes::

    # token map with annotated gaps
    python3 tools/charisma_dump.py gog_incubation/CHData/Objects/P0_000.cho

    # census of class names, and of the two bytes before / after each one
    python3 tools/charisma_dump.py --census gog_incubation --ext .cha

    # prove that class names are always spelled out (no numeric back-refs)
    python3 tools/charisma_dump.py --registry gog_incubation
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import struct
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.binio import read_file  # noqa: E402
from inclib.charisma import KNOWN_CLASSES, STORABLE_CLASSES, iter_corpus  # noqa: E402

logger = logging.getLogger("charisma_dump")

# A length-prefixed string in these files is u32 length + raw cp1252 bytes.
_TOKEN_RE = re.compile(rb"[A-Za-z_][\x20-\x7e\xa0-\xff]{1,63}")


def find_tokens(data: bytes, only_known: bool = True) -> list[tuple[int, str]]:
    """Return ``(offset_of_length_prefix, text)`` for every valid lp-string.

    A candidate matches only if the ``u32`` immediately before the ASCII run
    equals the run's exact length - this is what makes the scan reliable
    without knowing any field layout.
    """
    out: list[tuple[int, str]] = []
    for match in _TOKEN_RE.finditer(data):
        text = match.group()
        for length in range(len(text), 2, -1):
            start = match.start()
            off = start - 4
            if off < 0:
                continue
            if struct.unpack_from("<I", data, off)[0] != length:
                continue
            name = text[:length].decode("cp1252")
            if only_known and name not in KNOWN_CLASSES:
                continue
            out.append((off, name))
            break
    out.sort()
    return out


def describe_gap(data: bytes, start: int, end: int) -> list[str]:
    """Produce candidate readings of the unclaimed bytes in ``[start, end)``."""
    blob = data[start:end]
    lines = [f"  gap 0x{start:x}..0x{end:x} ({len(blob)} bytes): {blob[:48].hex(' ')}"
             + (" ..." if len(blob) > 48 else "")]
    if not blob:
        return []
    if len(blob) % 2 == 0 and len(blob) <= 64:
        u16 = struct.unpack(f"<{len(blob) // 2}H", blob)
        lines.append(f"      u16: {u16}")
    if len(blob) % 4 == 0 and len(blob) <= 64:
        u32 = struct.unpack(f"<{len(blob) // 4}I", blob)
        f32 = struct.unpack(f"<{len(blob) // 4}f", blob)
        lines.append(f"      u32: {u32}")
        lines.append("      f32: (" + ", ".join(f"{v:g}" for v in f32) + ")")
    return lines


def dump_tokens(path: str, show_gaps: bool = True) -> None:
    """Print the class-name token map of one file with annotated gaps."""
    data = read_file(path)
    tokens = find_tokens(data)
    print(f"{path}  ({len(data)} bytes, {len(tokens)} class records)")
    prev = 0
    for off, name in tokens:
        if show_gaps and off > prev:
            for line in describe_gap(data, prev, off):
                print(line)
        print(f"0x{off:08x}  CLASS {name}")
        prev = off + 4 + len(name)
    if prev < len(data):
        for line in describe_gap(data, prev, len(data)):
            print(line)


def census(root: str, ext: str) -> None:
    """Count class names and the two bytes surrounding each occurrence.

    The ``before`` / ``after`` histograms are what pinned down the version
    fields: a value that is constant per class is a schema version, a value
    that varies with the following string is a length prefix.
    """
    paths = iter_corpus(root, ext)
    names: Counter[str] = Counter()
    before: dict[str, Counter[str]] = defaultdict(Counter)
    after: dict[str, Counter[str]] = defaultdict(Counter)
    for path in paths:
        data = read_file(path)
        for off, name in find_tokens(data):
            names[name] += 1
            if off >= 2:
                before[name][data[off - 2:off].hex()] += 1
            end = off + 4 + len(name)
            after[name][data[end:end + 2].hex()] += 1
    print(f"{len(paths)} {ext} files")
    for name, count in names.most_common():
        pre = ", ".join(f"{k}={v}" for k, v in before[name].most_common(4))
        post = ", ".join(f"{k}={v}" for k, v in after[name].most_common(4))
        print(f"  {name}: {count}")
        print(f"      2 bytes before: {pre}")
        print(f"      2 bytes after:  {post}")


def registry(root: str) -> None:
    """Test whether the stream uses numeric class back-references.

    In an MFC ``CArchive``-style scheme a class name is written once and later
    occurrences are replaced by a small numeric tag.  If that were the case
    here, a class would appear far fewer times than it has instances.  This
    mode prints, per file, the number of spelled-out occurrences of each
    class so the two hypotheses can be told apart.
    """
    for ext in (".cho", ".cha"):
        paths = iter_corpus(root, ext)
        totals: Counter[str] = Counter()
        multi = 0
        for path in paths:
            per_file = Counter(name for _off, name in find_tokens(read_file(path)))
            totals.update(per_file)
            if any(v > 1 for v in per_file.values()):
                multi += 1
        print(f"{ext}: {len(paths)} files, "
              f"{multi} of them spell at least one class name more than once")
        for name, count in totals.most_common():
            kind = "storable" if name in STORABLE_CLASSES else "component-name field"
            print(f"    {name}: {count} spelled-out occurrence(s)  [{kind}]")
        print("  => names are repeated verbatim; there is no numeric class registry."
              if multi else "  => every class name occurs once per file.")
        print("     Only the [storable] names introduce a polymorphic record; the")
        print("     others are componentClass string fields of StdComponentDesc.")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("path", nargs="?", help="a .cho/.cha file to walk")
    ap.add_argument("--no-gaps", action="store_true", help="only print class records")
    ap.add_argument("--all-strings", action="store_true",
                    help="also print length-prefixed strings that are not class names")
    ap.add_argument("--census", metavar="ROOT", help="class-name census below ROOT")
    ap.add_argument("--ext", default=".cho", help="extension for --census")
    ap.add_argument("--registry", metavar="ROOT",
                    help="test the numeric-class-registry hypothesis below ROOT")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING,
                        format="%(levelname)s %(name)s: %(message)s")

    if args.census:
        census(args.census, args.ext)
        return 0
    if args.registry:
        registry(args.registry)
        return 0
    if not args.path:
        ap.error("a path, --census or --registry is required")

    if args.all_strings:
        data = read_file(args.path)
        for off, text in find_tokens(data, only_known=False):
            kind = "CLASS" if text in KNOWN_CLASSES else "str  "
            print(f"0x{off:08x}  {kind} {text!r}")
        return 0

    dump_tokens(args.path, show_gaps=not args.no_gaps)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

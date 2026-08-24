#!/usr/bin/env python3
"""Parser for Eng3d ``.dir`` ASCII directory files (magic ``3DI``).

A ``.dir`` file is the human-readable index of a container:

* ``Objects/prototyp.dir``  indexes ``prototyp.bin`` (geometry prototypes)
* ``TEXTURES/texture.dir``  indexes ``texture.lib`` (VISN texture blobs)

Both flavours share the same envelope::

    "3DI" CRLF
    "[DIRECTORY]" CRLF
    <row> CRLF ...
    "ENDDIR" CRLF
    "[END3DI]" CRLF

The row layout differs by flavour (whitespace separated, texture names are
TAB-padded):

    prototyp row := NAME  type  index  class  cull_radius
    texture  row := NAME  type  index  offset  size  timestamp

**No shipped binary reads a ``.dir``** - the runtime index is the ``.din``.
The substrings ``.dir``/``.DIR`` do not occur in any of the 29 shipped
executables in ASCII or UTF-16, and the ``.din`` record carries neither the
``type`` nor the ``class`` column, so those two are build-time authoring
metadata that a remake can ignore.  See ``docs/30-eng3d-ascii-formats.md``
section 3.4 for the proof and 3.3/3.5 for the observed distributions.

Usage::

    python3 tools/dir3di_parse.py [--json] FILE_OR_DIR...
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from typing import Any, Iterator

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.binio import ParseError  # noqa: E402

LOG = logging.getLogger("dir3di")

MAGIC = "3DI"
HEADER = "[DIRECTORY]"
ROWS_TERMINATOR = "ENDDIR"
FILE_TERMINATOR = "[END3DI]"

KIND_PROTOTYP = "prototyp"
KIND_TEXTURE = "texture"

#: Column count (excluding the name) that identifies each flavour.
_COLUMNS_BY_KIND = {4: KIND_PROTOTYP, 5: KIND_TEXTURE}


def parse_dir(path: str) -> dict[str, Any]:
    """Parse a ``.dir`` file into ``{"kind", "path", "entries"}``.

    Raises:
        ParseError: The file does not match the documented layout.
    """
    with open(path, "rb") as fh:
        raw = fh.read()
    text = raw.decode("cp1252", errors="replace")
    lines = text.split("\r\n")
    if len(lines) < 4:
        raise ParseError(f"{path}: too short to be a 3DI directory")
    if lines[0] != MAGIC:
        raise ParseError(f"{path}: expected magic {MAGIC!r}, got {lines[0]!r}")
    if lines[1] != HEADER:
        raise ParseError(f"{path}: expected {HEADER!r}, got {lines[1]!r}")

    entries: list[dict[str, Any]] = []
    kind: str | None = None
    saw_enddir = False
    saw_end3di = False

    for lineno, line in enumerate(lines[2:], start=3):
        if line == "":
            # Only the implicit final element after the last CRLF may be empty.
            continue
        if line == ROWS_TERMINATOR:
            saw_enddir = True
            continue
        if line == FILE_TERMINATOR:
            saw_end3di = True
            continue
        if saw_enddir:
            raise ParseError(f"{path}: line {lineno}: row after {ROWS_TERMINATOR}")

        fields = line.split()
        row_kind = _COLUMNS_BY_KIND.get(len(fields) - 1)
        if row_kind is None:
            raise ParseError(
                f"{path}: line {lineno}: unexpected column count {len(fields)}: {line!r}"
            )
        if kind is None:
            kind = row_kind
        elif kind != row_kind:
            raise ParseError(
                f"{path}: line {lineno}: mixed row flavours ({kind} vs {row_kind})"
            )

        name = fields[0]
        try:
            nums = [int(f) for f in fields[1:]]
        except ValueError as exc:
            raise ParseError(f"{path}: line {lineno}: non-integer column: {line!r}") from exc

        if row_kind == KIND_PROTOTYP:
            entry: dict[str, Any] = {
                "name": name,
                # always 0 corpus-wide; build metadata, never read at runtime
                "type_code": nums[0],
                "index": nums[1],
                # 0..11, clusters by object family; meaning UNVERIFIED, and the
                # engine cannot see it (it is absent from prototyp.din)
                "class_code": nums[2],
                # == first u32 of the prototyp.bin record == the bounding/cull
                # radius the renderer tests against the view box
                "bin_first_u32": nums[3],
            }
        else:
            entry = {
                "name": name,
                # always 2 corpus-wide; build metadata, never read at runtime
                "type_code": nums[0],
                "index": nums[1],
                "offset": nums[2],          # byte offset into texture.lib
                "size": nums[3],            # byte size in texture.lib
                # a time_t: 2-second granularity in 20 of 21 containers and a
                # working-hours distribution.  Which event it stamps (source
                # mtime vs export time) is UNVERIFIED.
                "timestamp": nums[4],
            }
        entries.append(entry)

    if kind is None:
        kind = KIND_PROTOTYP if "prototyp" in os.path.basename(path).lower() else KIND_TEXTURE
    if not saw_enddir:
        raise ParseError(f"{path}: missing {ROWS_TERMINATOR}")
    if not saw_end3di:
        raise ParseError(f"{path}: missing {FILE_TERMINATOR}")

    return {"path": path, "kind": kind, "entries": entries}


def iter_dir_files(targets: list[str]) -> Iterator[str]:
    """Yield ``.dir`` paths from files and/or directories (recursive)."""
    for target in targets:
        if os.path.isdir(target):
            for root, _dirs, files in os.walk(target):
                for fname in sorted(files):
                    if fname.lower().endswith(".dir"):
                        yield os.path.join(root, fname)
        else:
            yield target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Parse Eng3d 3DI .dir directory files.")
    parser.add_argument("paths", nargs="+", help="files or directories to parse")
    parser.add_argument("--json", action="store_true", help="emit JSON to stdout")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    results = []
    failures = 0
    for path in iter_dir_files(args.paths):
        try:
            parsed = parse_dir(path)
        except ParseError as exc:
            LOG.error("%s", exc)
            failures += 1
            continue
        results.append(parsed)
        if not args.json:
            print(f"{path}: kind={parsed['kind']} entries={len(parsed['entries'])}")

    if args.json:
        json.dump(results if len(results) != 1 else results[0], sys.stdout, indent=2)
        sys.stdout.write("\n")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

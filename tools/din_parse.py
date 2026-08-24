#!/usr/bin/env python3
"""Parser for Eng3d ``.din`` binary directory files.

``.din`` is the binary companion of the ASCII ``.dir``.  Two structurally
different layouts share the extension:

``prototyp.din`` (headerless, variable length records, one per prototype)::

    record := u32 name_len
              char name[name_len]     ; ASCII, NOT NUL terminated inside len
              u8   0x00               ; explicit terminator, not counted
              u32  offset             ; byte offset into prototyp.bin

``texture.din`` (``DBIN`` header, fixed 25-byte records)::

    header := "DBIN" u32 count
    record := u32  index              ; slot number; equals the row position in
                                      ; all shipped data, but the engine uses it
                                      ; as the slot index (slot = base + index*32)
              char name[13]           ; NUL padded; treat as 12 chars + NUL
              u32  offset             ; byte offset into texture.lib
              u32  size               ; byte size in texture.lib

    file_size == 8 + 25 * count

Both layouts are confirmed against the engine's own readers in ``Eng3d.dll``
(``fcn.00401054`` for prototyp, ``fcn.00401ae0`` for texture); the compiled
capacity limits those readers enforce are exported below as constants.

Usage::

    python3 tools/din_parse.py [--json] FILE_OR_DIR...
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from typing import Any, Iterator

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.binio import ParseError, Reader, read_file  # noqa: E402

LOG = logging.getLogger("din")

MAGIC_TEXTURE = b"DBIN"
TEXTURE_HEADER_SIZE = 8
TEXTURE_NAME_SIZE = 13
TEXTURE_RECORD_SIZE = 4 + TEXTURE_NAME_SIZE + 4 + 4  # 25

# Limits compiled into Eng3d.dll.  Exceeding any of them makes the engine abort
# at startup with a "3DENGINE STARTUP: ..." message.  See
# docs/30-eng3d-ascii-formats.md sections 4.1 and 4.2 for the addresses.
#: Largest accepted prototyp.din name_len (size of the name scratch buffer).
ENGINE_MAX_PROTOTYP_NAME_LEN = 0xFFFF
#: Largest accepted prototyp.din record count ("Error: too many prototypes").
ENGINE_MAX_PROTOTYP_RECORDS = 2499
#: Largest accepted texture.din record count ("not enough textureslots!").
ENGINE_MAX_TEXTURE_RECORDS = 300

KIND_PROTOTYP = "prototyp"
KIND_TEXTURE = "texture"

#: Upper bound used as a sanity check while parsing prototyp.din names.
MAX_NAME_LEN = 255


def parse_din(path: str) -> dict[str, Any]:
    """Parse a ``.din`` file, auto-detecting the flavour by magic.

    Returns:
        ``{"path", "kind", "count", "entries"}``.

    Raises:
        ParseError: The file does not match either documented layout.
    """
    data = read_file(path)
    if data[:4] == MAGIC_TEXTURE:
        return _parse_texture_din(path, data)
    return _parse_prototyp_din(path, data)


def _parse_texture_din(path: str, data: bytes) -> dict[str, Any]:
    reader = Reader(data)
    magic = reader.take(4)
    if magic != MAGIC_TEXTURE:
        raise ParseError(f"{path}: expected {MAGIC_TEXTURE!r}, got {magic!r}")
    count = reader.u32()

    expected = TEXTURE_HEADER_SIZE + TEXTURE_RECORD_SIZE * count
    if expected != len(data):
        raise ParseError(
            f"{path}: size mismatch: header says {count} records "
            f"(expected {expected} bytes) but file is {len(data)} bytes"
        )

    entries: list[dict[str, Any]] = []
    for i in range(count):
        index = reader.u32()
        raw_name = reader.take(TEXTURE_NAME_SIZE)
        offset = reader.u32()
        size = reader.u32()
        if raw_name[-1] != 0:
            raise ParseError(f"{path}: record {i}: name field is not NUL terminated")
        name = raw_name.split(b"\x00", 1)[0].decode("cp1252", errors="replace")
        entries.append({"index": index, "name": name, "offset": offset, "size": size})

    if not reader.eof():
        raise ParseError(f"{path}: {reader.remaining} trailing bytes after {count} records")

    return {"path": path, "kind": KIND_TEXTURE, "count": count, "entries": entries}


def _parse_prototyp_din(path: str, data: bytes) -> dict[str, Any]:
    reader = Reader(data)
    entries: list[dict[str, Any]] = []
    while not reader.eof():
        start = reader.pos
        name_len = reader.u32()
        if name_len == 0 or name_len > MAX_NAME_LEN:
            raise ParseError(
                f"{path}: record {len(entries)} at 0x{start:x}: implausible "
                f"name length {name_len}"
            )
        raw_name = reader.take(name_len)
        terminator = reader.u8()
        if terminator != 0:
            raise ParseError(
                f"{path}: record {len(entries)} at 0x{start:x}: expected NUL after "
                f"name, got 0x{terminator:02x}"
            )
        if b"\x00" in raw_name:
            raise ParseError(
                f"{path}: record {len(entries)} at 0x{start:x}: embedded NUL in name"
            )
        offset = reader.u32()
        entries.append(
            {
                "index": len(entries),
                "name": raw_name.decode("cp1252", errors="replace"),
                "offset": offset,
            }
        )

    return {"path": path, "kind": KIND_PROTOTYP, "count": len(entries), "entries": entries}


def iter_din_files(targets: list[str]) -> Iterator[str]:
    """Yield ``.din`` paths from files and/or directories (recursive)."""
    for target in targets:
        if os.path.isdir(target):
            for root, _dirs, files in os.walk(target):
                for fname in sorted(files):
                    if fname.lower().endswith(".din"):
                        yield os.path.join(root, fname)
        else:
            yield target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Parse Eng3d binary .din index files.")
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
    for path in iter_din_files(args.paths):
        try:
            parsed = parse_din(path)
        except ParseError as exc:
            LOG.error("%s", exc)
            failures += 1
            continue
        results.append(parsed)
        if not args.json:
            print(f"{path}: kind={parsed['kind']} entries={parsed['count']}")

    if args.json:
        json.dump(results if len(results) != 1 else results[0], sys.stdout, indent=2)
        sys.stdout.write("\n")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

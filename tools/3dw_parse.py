#!/usr/bin/env python3
"""Parser for Eng3d ``.3DW`` ASCII scene/world files (magic ``3DW``).

A ``.3DW`` file describes one world/level as a flat list of object *clones*
(``[CLO]`` blocks) that each reference a prototype by name.  The prototype
names resolve through ``Objects/prototyp.dir`` + ``prototyp.din`` into records
inside ``Objects/prototyp.bin`` (see ``dir3di_parse.py`` / ``din_parse.py``).

Grammar as observed in the shipped corpus (LF line endings, no CR):

    file        := "3DW" NL coord_system group clone* "[END3DW]" NL
    coord_system:= "[COORD_SYSTEM]" SP IDENT NL
    group       := "[GRP]" SP TEXT NL (SP NAME NL)* "ENDGRP" NL
    clone       := "[CLO]" SP NAME NL clone_field+ "ENDCLO" NL
    clone_field := KEY SP VALUE NL

Blank lines may appear between top-level blocks and are ignored.

What the runtime actually consumes (``aParseLandscapeFile``, see
``docs/30-eng3d-ascii-formats.md`` section 2.5): the ``[CLO]`` argument -- *not*
the ``PROTOTYP`` line -- plus the ``ROTATION`` and ``POSITION`` triples.
``[COORD_SYSTEM]``, ``[GRP]``, ``TYP`` and ``EDITORDETAIL`` are never read.
Conversion applied on load, which a remake must reproduce::

    engine_slot0 =  POSITION[0] * 16          # X, right
    engine_slot1 =  POSITION[2] * 16          # depth (the file's Z)
    engine_slot2 = -POSITION[1] * 16          # up    (the file's Y is DOWN)
    angle_slot_k =  ROTATION[k] * 16          # NOT reordered; 256 units/turn
                                              # in the file, 4096 in the engine

``ROTATION[2]`` is therefore the yaw (rotation about the vertical axis).
This parser keeps the file's raw values and does not convert.

Usage::

    python3 tools/3dw_parse.py [--json] FILE_OR_DIR...
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

LOG = logging.getLogger("3dw")

MAGIC = "3DW"

#: Section headers accepted at top level.
SECTION_COORD_SYSTEM = "[COORD_SYSTEM]"
SECTION_GRP = "[GRP]"
SECTION_CLO = "[CLO]"
SECTION_END = "[END3DW]"

#: Keys accepted inside a ``[CLO]`` block, mapped to their value parser name.
CLONE_KEYS: dict[str, str] = {
    "PROTOTYP": "str",
    "ROTATION": "ivec3",
    "POSITION": "ivec3",
    "TYP": "str",
    "EDITORDETAIL": "int",
}

CLONE_TERMINATOR = "ENDCLO"
GROUP_TERMINATOR = "ENDGRP"


class World3DW:
    """Parsed representation of a ``.3DW`` file."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.coord_system: str | None = None
        self.group_header: str | None = None
        self.group_members: list[str] = []
        self.clones: list[dict[str, Any]] = []

    def to_dict(self) -> dict[str, Any]:
        """Return a JSON-serialisable view of the world."""
        return {
            "path": self.path,
            "magic": MAGIC,
            "coord_system": self.coord_system,
            "group": {
                "header": self.group_header,
                "members": self.group_members,
            },
            "clones": self.clones,
        }


def _split_ivec3(value: str, lineno: int, key: str) -> list[int]:
    parts = value.split()
    if len(parts) != 3:
        raise ParseError(f"line {lineno}: {key} expects 3 integers, got {value!r}")
    try:
        return [int(p) for p in parts]
    except ValueError as exc:
        raise ParseError(f"line {lineno}: {key} has non-integer component: {value!r}") from exc


def parse_3dw(path: str, *, strict: bool = True) -> World3DW:
    """Parse a ``.3DW`` file into a :class:`World3DW`.

    Args:
        path: Path to the ``.3DW`` file.
        strict: Raise :class:`ParseError` on any unknown token.  When False,
            unknown lines are logged and skipped.

    Raises:
        ParseError: The file does not match the documented grammar.
    """
    with open(path, "rb") as fh:
        raw = fh.read()
    text = raw.decode("cp1252", errors="replace")
    # The shipped corpus uses bare LF; tolerate CRLF without silently rewriting
    # the parsed payload.
    lines = text.split("\n")

    world = World3DW(path)
    it: Iterator[tuple[int, str]] = enumerate((ln.rstrip("\r") for ln in lines), start=1)

    lineno, first = next(it, (0, ""))
    if first != MAGIC:
        raise ParseError(f"{path}: line {lineno}: expected magic {MAGIC!r}, got {first!r}")

    saw_end = False
    for lineno, line in it:
        if line == "":
            continue
        if saw_end:
            raise ParseError(f"{path}: line {lineno}: trailing data after {SECTION_END}")

        keyword, _, value = line.partition(" ")

        if keyword == SECTION_COORD_SYSTEM:
            if world.coord_system is not None:
                raise ParseError(f"{path}: line {lineno}: duplicate {SECTION_COORD_SYSTEM}")
            world.coord_system = value
        elif keyword == SECTION_GRP:
            if world.group_header is not None:
                raise ParseError(f"{path}: line {lineno}: duplicate {SECTION_GRP}")
            world.group_header = value
            world.group_members = _parse_group(path, it)
        elif keyword == SECTION_CLO:
            world.clones.append(_parse_clone(path, it, value, lineno, strict=strict))
        elif keyword == SECTION_END:
            saw_end = True
        elif strict:
            raise ParseError(f"{path}: line {lineno}: unknown top-level token {keyword!r}")
        else:
            LOG.warning("%s: line %d: skipping unknown token %r", path, lineno, keyword)

    if not saw_end:
        raise ParseError(f"{path}: missing {SECTION_END}")
    if world.coord_system is None:
        raise ParseError(f"{path}: missing {SECTION_COORD_SYSTEM}")
    if world.group_header is None:
        raise ParseError(f"{path}: missing {SECTION_GRP}")
    return world


def _parse_group(path: str, it: Iterator[tuple[int, str]]) -> list[str]:
    """Consume the body of a ``[GRP]`` block up to and including ``ENDGRP``."""
    members: list[str] = []
    for lineno, line in it:
        line = line.rstrip("\r")
        if line == GROUP_TERMINATOR:
            return members
        if not line.startswith(" "):
            raise ParseError(
                f"{path}: line {lineno}: expected indented group member or "
                f"{GROUP_TERMINATOR}, got {line!r}"
            )
        members.append(line[1:])
    raise ParseError(f"{path}: unterminated {SECTION_GRP} block")


def _parse_clone(
    path: str,
    it: Iterator[tuple[int, str]],
    name: str,
    header_lineno: int,
    *,
    strict: bool,
) -> dict[str, Any]:
    """Consume the body of a ``[CLO]`` block up to and including ``ENDCLO``."""
    clone: dict[str, Any] = {"name": name, "line": header_lineno}
    for lineno, line in it:
        line = line.rstrip("\r")
        if line == CLONE_TERMINATOR:
            missing = [k for k in CLONE_KEYS if k.lower() not in clone]
            if missing and strict:
                raise ParseError(
                    f"{path}: line {lineno}: [CLO] {name!r} missing keys {missing}"
                )
            return clone
        key, _, value = line.partition(" ")
        kind = CLONE_KEYS.get(key)
        if kind is None:
            if strict:
                raise ParseError(f"{path}: line {lineno}: unknown [CLO] key {key!r}")
            LOG.warning("%s: line %d: skipping unknown [CLO] key %r", path, lineno, key)
            continue
        if kind == "ivec3":
            clone[key.lower()] = _split_ivec3(value, lineno, key)
        elif kind == "int":
            try:
                clone[key.lower()] = int(value)
            except ValueError as exc:
                raise ParseError(f"{path}: line {lineno}: {key} not an int: {value!r}") from exc
        else:
            clone[key.lower()] = value
    raise ParseError(f"{path}: unterminated [CLO] block starting at line {header_lineno}")


def iter_3dw_files(targets: list[str]) -> Iterator[str]:
    """Yield ``.3DW`` paths from files and/or directories (recursive)."""
    for target in targets:
        if os.path.isdir(target):
            for root, _dirs, files in os.walk(target):
                for fname in sorted(files):
                    if fname.lower().endswith(".3dw"):
                        yield os.path.join(root, fname)
        else:
            yield target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Parse Eng3d .3DW world files.")
    parser.add_argument("paths", nargs="+", help="files or directories to parse")
    parser.add_argument("--json", action="store_true", help="emit JSON to stdout")
    parser.add_argument("--lenient", action="store_true", help="warn instead of failing on unknown tokens")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    results: list[dict[str, Any]] = []
    failures = 0
    for path in iter_3dw_files(args.paths):
        try:
            world = parse_3dw(path, strict=not args.lenient)
        except ParseError as exc:
            LOG.error("%s", exc)
            failures += 1
            continue
        results.append(world.to_dict())
        if not args.json:
            print(
                f"{path}: coord_system={world.coord_system} "
                f"group_members={len(world.group_members)} clones={len(world.clones)}"
            )

    if args.json:
        json.dump(results if len(results) != 1 else results[0], sys.stdout, indent=2)
        sys.stdout.write("\n")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Parse ``OBJECT.TYP`` and check what it claims about the engine.  See docs/30 2.11.

``OBJECT.TYP`` is a 213-byte configuration file for the object exporter that
Blue Byte never shipped.  Exactly one copy survives in the retail release, in
``Video/Dialog_03/Objects/``, and **no shipped binary reads it** -- so it is not
a format a remake implements.  It is worth a parser because its three
directives name build-time axes that are decoded on the engine side, and the
corpus can be asked whether they show up in the exporter's output.

Usage::

    python3 tools/typ_parse.py --check gog_incubation
    python3 tools/typ_parse.py gog_incubation/Video/Dialog_03/Objects/OBJECT.TYP --json

``--check`` covers four independent things: the file's grammar, that it is
unique in the tree, that none of its keywords occurs in any shipped PE (ASCII
*and* UTF-16LE, the sweep docs/30 2.7 uses), and the engine-side facts the
subsection leans on -- the 4x4 distance switch table in both Eng3d builds, and
the opcode counts over all 26072 prototype records.
"""

from __future__ import annotations

import argparse
import json
import logging
import struct
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib import prototyp  # noqa: E402
from inclib.pe import PEFile  # noqa: E402

log = logging.getLogger("typ_parse")


class TypError(Exception):
    """Raised instead of returning a partial parse."""


# --- grammar ------------------------------------------------------------------

HEAD = "TYPFILE"
FOOT = "[ENDTYPFILE]"
TYP_OPEN = "[TYP]"
TYP_CLOSE = "ENDTYP"
COMPILER_OPEN = "[COMPILER]"
COMPILER_CLOSE = "ENDCOMPILER"

#: Directive name -> whether it takes an integer argument.
DIRECTIVES = {"SORT_OBJECT": False, "DETAIL_METHODE": True, "USE_MATRIX": False}

#: Every token the format uses, for the binary sweep.  docs/30 2.11.
KEYWORDS = [HEAD, FOOT, TYP_OPEN, TYP_CLOSE, COMPILER_OPEN, COMPILER_CLOSE,
            *DIRECTIVES, ".TYP"]

#: Positive control for the sweep: a string that *is* in the binaries, checked
#: through the same code path, so a clean negative cannot come from a broken
#: search.
CONTROL_KEYWORD = "ENG3D.DLL"

#: PE files shipped anywhere under the game root, docs/30 2.10.
EXPECTED_PE_FILES = 35

# --- what the one shipped file says -------------------------------------------

EXPECTED_PATH = Path("Video/Dialog_03/Objects/OBJECT.TYP")
EXPECTED_SIZE = 213
EXPECTED_TYPES = ["Charisma", "Static"]
EXPECTED_BODY = {"SORT_OBJECT": None, "DETAIL_METHODE": 1, "USE_MATRIX": None}

# --- engine side, docs/30 2.11 and docs/31 4 ----------------------------------

#: Eng3d build -> VA of export #7's thunk.  The thunk saves three registers and
#: tail-calls the implementation, so the check follows its ``call rel32`` rather
#: than hard-coding two implementation addresses that differ between builds.
SWITCH_SETTER = {"Eng3d.dll": 0x00402050, "ENG3DFX.DLL": 0x00402A90}
SWITCH_METHODES = 4
SWITCH_LEVELS = 4
#: The table-of-tables the setter indexes.  Software and Glide builds are
#: separate compilations, so the address differs between them.
SWITCH_TABLE_INDEX = {"Eng3d.dll": 0x004142A0, "ENG3DFX.DLL": 0x004102A0}

#: Opcodes keyed on the four method tables -- the ones DETAIL_METHODE chooses
#: between.  All zero in the corpus.
METHODE_OPCODES = [f"lod_switch_{i}" for i in range(4)] + \
                  [f"distance_cull_{i}" for i in range(4)]
#: The hard-wired detail selector the exporter actually emitted, once per record.
DETAIL_OPCODE = "select_detail"

MATRIX_SET = ["matrix_identity", "matrix_set_a8ac", "matrix_set_a8ac_b",
              "matrix_set_a8d0", "matrix_from_angles", "matrix_from_angles_b",
              "matrix_clone", "matrix_clone_compose"]
MATRIX_NONE = ["matrix_none", "matrix_none_b", "matrix_none_c"]

EXPECTED_RECORDS = 26072
EXPECTED_CONTAINERS = 21
EXPECTED_MATRIX_SET = 75886
EXPECTED_MATRIX_NONE = 4
#: The single prototype compiled without USE_MATRIX, docs/30 2.11.
EXPECTED_NO_MATRIX_NAMES = {"L096EE00.3DI", "L096EF00.3DI"}


@dataclass
class TypBlock:
    name: str
    directives: dict[str, int | None] = field(default_factory=dict)

    def to_json(self) -> dict:
        return {"name": self.name, "directives": self.directives}


@dataclass
class TypFile:
    path: Path
    size: int
    blocks: list[TypBlock]

    def to_json(self) -> dict:
        return {"path": str(self.path), "size": self.size,
                "blocks": [b.to_json() for b in self.blocks]}


def parse(path: Path) -> TypFile:
    """Parse a ``.TYP`` file, raising :class:`TypError` on anything unexpected."""
    raw = path.read_bytes()
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise TypError(f"{path}: not ASCII ({exc})") from exc

    lines = [ln.strip() for ln in text.splitlines()]
    body = [ln for ln in lines if ln]
    if not body or body[0] != HEAD:
        raise TypError(f"{path}: expected {HEAD!r} first, got {body[:1]}")
    if body[-1] != FOOT:
        raise TypError(f"{path}: expected {FOOT!r} last, got {body[-1]!r}")

    blocks: list[TypBlock] = []
    i = 1
    while i < len(body) - 1:
        line = body[i]
        if not line.startswith(TYP_OPEN + " "):
            raise TypError(f"{path}: line {i}: expected a {TYP_OPEN} block, got {line!r}")
        block = TypBlock(name=line[len(TYP_OPEN) + 1:].strip())
        i += 1
        if body[i] != COMPILER_OPEN:
            raise TypError(f"{path}: {block.name}: expected {COMPILER_OPEN}, got {body[i]!r}")
        i += 1
        while body[i] != COMPILER_CLOSE:
            parts = body[i].split()
            name = parts[0]
            if name not in DIRECTIVES:
                raise TypError(f"{path}: {block.name}: unknown directive {body[i]!r}")
            if DIRECTIVES[name]:
                if len(parts) != 2 or not parts[1].lstrip("-").isdigit():
                    raise TypError(f"{path}: {block.name}: {name} wants one integer, "
                                   f"got {body[i]!r}")
                block.directives[name] = int(parts[1])
            else:
                if len(parts) != 1:
                    raise TypError(f"{path}: {block.name}: {name} takes no argument, "
                                   f"got {body[i]!r}")
                block.directives[name] = None
            i += 1
        i += 1
        if body[i] != TYP_CLOSE:
            raise TypError(f"{path}: {block.name}: expected {TYP_CLOSE}, got {body[i]!r}")
        i += 1
        blocks.append(block)

    if not blocks:
        raise TypError(f"{path}: no {TYP_OPEN} blocks")
    return TypFile(path=path, size=len(raw), blocks=blocks)


class Checker:
    def __init__(self) -> None:
        self.results: list[tuple[bool, str, str]] = []

    def check(self, name: str, ok: bool, detail: str) -> None:
        self.results.append((bool(ok), name, detail))

    def expect(self, name: str, got, want) -> None:
        self.check(name, got == want, f"{got} (expected {want})")


def check_file(c: Checker, root: Path) -> TypFile | None:
    found = sorted(root.rglob("*.[Tt][Yy][Pp]"))
    c.expect("typ.unique", [p.relative_to(root).as_posix() for p in found],
             [EXPECTED_PATH.as_posix()])
    if not found:
        return None
    typ = parse(found[0])
    c.expect("typ.size", typ.size, EXPECTED_SIZE)
    c.expect("typ.blocks", [b.name for b in typ.blocks], EXPECTED_TYPES)
    for b in typ.blocks:
        c.expect(f"typ.body[{b.name}]", b.directives, EXPECTED_BODY)

    # Every prototyp.bin directory but this one lacks a config.
    objdirs = {p.parent for p in root.rglob("[Pp]rototyp.din")}
    c.expect("typ.containers", len(objdirs), EXPECTED_CONTAINERS)
    with_typ = {d for d in objdirs if any(d.glob("*.[Tt][Yy][Pp]"))}
    c.expect("typ.one_of_n", len(with_typ), 1)
    return typ


def check_binaries(c: Checker, root: Path) -> None:
    """No shipped PE mentions any keyword, in ASCII or UTF-16LE (docs/30 2.7)."""
    # The whole tree, not just the game directory, so this matches the 35-file
    # sweep docs/30 2.10 uses -- Install/ carries five more PEs.
    pes = sorted(p for p in root.rglob("*")
                 if p.suffix.lower() in (".exe", ".dll") and p.is_file())
    if not pes:
        c.check("typ.binaries", False, "no PE files found")
        return
    hits: dict[str, list[str]] = {}
    for pe in pes:
        blob = pe.read_bytes()
        for kw in KEYWORDS:
            if kw.encode("ascii") in blob or kw.encode("utf-16-le") in blob:
                hits.setdefault(kw, []).append(pe.name)
    c.expect("typ.unread", hits, {})

    # A sweep that finds nothing proves nothing unless it can find something.
    # ENG3D.DLL is named by both game binaries, so it must come back positive
    # through exactly the same code path.
    control = [pe.name for pe in pes
               if CONTROL_KEYWORD.encode("ascii") in pe.read_bytes()
               or CONTROL_KEYWORD.encode("utf-16-le") in pe.read_bytes()]
    c.check("typ.sweep_control", len(control) >= 2,
            f"{CONTROL_KEYWORD!r} found in {sorted(control)}")
    c.check("typ.pe_count", len(pes) >= EXPECTED_PE_FILES, f"{len(pes)} PE files swept, "
            f"{len(KEYWORDS)} keywords, ASCII + UTF-16LE")


def check_switch_table(c: Checker, root: Path) -> None:
    """The setter bounds-checks both indices against 4, in both Eng3d builds."""
    for name, va in SWITCH_SETTER.items():
        path = root / name
        if not path.is_file():
            c.check(f"switch.{name}", False, "missing")
            continue
        pe = PEFile(path)
        thunk = pe.bytes_at(va, 0x20)
        rel = thunk.find(b"\xe8")
        if rel < 0:
            c.check(f"switch.{name}", False,
                    f"no call in export #7's thunk at {va:#010x}")
            continue
        impl = va + rel + 5 + struct.unpack_from("<i", thunk, rel + 1)[0]
        blob = pe.bytes_at(impl, 0x20)
        # cmp eax, 4 / jae ; cmp ebx, 4 / jae ; mov eax, [eax*4 + table]
        want_a = bytes([0x83, 0xF8, SWITCH_METHODES])
        want_b = bytes([0x83, 0xFB, SWITCH_LEVELS])
        table = b"\x8b\x04\x85" + struct.pack("<I", SWITCH_TABLE_INDEX[name])
        c.check(f"switch.{name}",
                want_a in blob and want_b in blob and table in blob,
                f"{SWITCH_METHODES} methodes x {SWITCH_LEVELS} levels at "
                f"{impl:#010x}, table index {SWITCH_TABLE_INDEX[name]:#010x}")


def check_corpus(c: Checker, root: Path) -> None:
    """The opcode counts docs/30 2.11 leans on, over every prototype record."""
    hist: Counter[str] = Counter()
    records = 0
    no_matrix: set[str] = set()
    dins = sorted(root.rglob("[Pp]rototyp.din"))
    if not dins:
        c.check("corpus.records", False, f"no prototyp.din under {root}")
        return
    for din in dins:
        for rec in prototyp.load_container(str(din)):
            records += 1
            for stream in (rec.render_cmds, rec.collision_cmds, rec.partinfo_cmds):
                for cmd in stream:
                    hist[cmd.name] += 1
                    if cmd.name in MATRIX_NONE:
                        no_matrix.add(rec.name)

    c.expect("corpus.records", records, EXPECTED_RECORDS)
    # DETAIL_METHODE: every table-keyed opcode unused, the hard-wired one
    # emitted exactly once per record.
    c.expect("corpus.methode_opcodes",
             {op: hist[op] for op in METHODE_OPCODES if hist[op]}, {})
    c.expect("corpus.select_detail", hist[DETAIL_OPCODE], records)
    # USE_MATRIX: on everywhere but one prototype.
    c.expect("corpus.matrix_set", sum(hist[op] for op in MATRIX_SET),
             EXPECTED_MATRIX_SET)
    c.expect("corpus.matrix_none", sum(hist[op] for op in MATRIX_NONE),
             EXPECTED_MATRIX_NONE)
    c.expect("corpus.no_matrix_names", no_matrix, EXPECTED_NO_MATRIX_NAMES)


def run_checks(root: Path) -> int:
    c = Checker()
    try:
        check_file(c, root)
    except TypError as exc:
        c.check("typ.grammar", False, str(exc))
    check_binaries(c, root)
    check_switch_table(c, root)
    check_corpus(c, root)

    if not c.results:
        log.error("no checks ran")
        return 1
    failed = 0
    for ok, name, detail in c.results:
        print(f"  {'OK ' if ok else 'FAIL'} {name:<26} {detail}")
        failed += not ok
    print(f"{len(c.results) - failed}/{len(c.results)} checks passed")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("path", nargs="?", type=Path, help="a .TYP file")
    ap.add_argument("--check", metavar="GAME_ROOT", type=Path,
                    help="verify the file, the binaries and the corpus")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    if args.check:
        return run_checks(args.check)
    if not args.path:
        ap.print_help()
        return 2
    try:
        typ = parse(args.path)
    except TypError as exc:
        log.error("%s", exc)
        return 1
    if args.json:
        print(json.dumps(typ.to_json(), indent=2))
    else:
        print(f"{typ.path}  ({typ.size} bytes)")
        for b in typ.blocks:
            print(f"  [TYP] {b.name}")
            for k, v in b.directives.items():
                print(f"      {k}" + (f" {v}" if v is not None else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

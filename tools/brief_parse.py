#!/usr/bin/env python3
"""Parse the briefing and info text files under ``DATA/TXT`` (docs/24).

The 120 shipped ``.txt`` files carry the same XOR-0xFF obfuscation as ``.lcl``
and a small markup on top: two-character **labels** ``{:xy}`` that address a
piece of text, **format commands** ``{<A7>n}`` (font) and ``{#n}`` (colour),
``@`` for a line break and ``{*}`` for the end of a block.  Blue Byte's own
note to translators, at the top of ``Errors.txt``, is the source of that
vocabulary.

Two readers in ``aGUI.cpp`` consume the syntax and this tool reproduces both:
``aGetGUITextBoxString`` pulls one field (stopping at ``|``, ``@`` or ``#``),
``aCreateGUITextBox`` lays a whole block out into lines.  The layout is exact:
``{<A7>0}`` and ``{<A7>1}`` are ``Libs/font_0.LIB`` and ``Libs/font_1.LIB``,
whose glyph widths the shipped libraries carry, and the engine's own metrics
(line height 12, space width 4, tracking 1) come from ``aCreateLibFont``.

``--check`` verifies the specification against 100% of the corpus and against
the constants in ``Incubation.exe``.  Every check fails on an empty corpus.

Usage::

    brief_parse.py --check gog_incubation
    brief_parse.py gog_incubation/DATA/TXT/English/Briefing/_C_105.txt
    brief_parse.py FILE --label A0 --layout 280
    brief_parse.py FILE --program
    brief_parse.py FILE --json
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.brieftext import (BriefError, COLOUR_RAMPS, FIELD_LIMIT,        # noqa: E402
                              FIELD_SEPARATOR, Font, TIP_BASE_ROW,
                              BRIEFING_BASE_ROW, block, field, labels,
                              layout, program)
from inclib.liblib import LibError, load_lib                                # noqa: E402
from inclib.pe import PEError, PEFile                                       # noqa: E402
from inclib.lcl import decode, encode, is_encoded                         # noqa: E402

LOG = logging.getLogger("brief")

GAME_EXE = "Incubation.exe"
TXT_DIR = os.path.join("DATA", "TXT")
BITMAP_DIR = os.path.join("Graphics", "Briefing")
FONT_LIBS = {0: os.path.join("Libs", "font_0.LIB"),
             1: os.path.join("Libs", "font_1.LIB")}

# --- what the engine asks for ---------------------------------------------

BRIEFING_KEYS = ("A0", "B0", "C0")
"""The only keys ``aActivateBriefingInfo`` is ever called with (8/8 sites)."""

FALLBACK_KEY = "**"
"""``0x0043E920`` retries with this when the requested label is missing."""

BRIEFING_SITES = {
    # call site: (key, x, y, width, height)
    0x0041B629: ("A0", 100, 100, 387, 199),
    0x0044EEDA: ("B0", 220, 120, 200, 500),
    0x00453990: ("B0", 220, 100, 200, 300),
    0x00456D96: ("C0", 84, 77, 230, 276),
    0x00456DE0: ("A0", 84, 77, 280, 276),
    0x004577DB: ("A0", 190, 107, 387, 199),
    0x0045783F: ("A0", 190, 107, 387, 199),
    0x0047CEE8: ("A0", 100, 100, 387, 199),
}
"""Every ``aActivateBriefingInfo`` call site and the literals it pushes.

The two label characters are the first two immediates in push order and the
box is the last four, reversed.  One site (``0x00453990``) computes its scroll
flag in a register instead of pushing a literal, which is why the flag is not
part of the tuple.
"""

BOX_FOR_KEY = {"A0": (280, 276), "B0": (200, 300), "C0": (230, 276)}
"""The narrowest box each block is shown in, for the fit checks."""

# --- corpus expectations ---------------------------------------------------

EXPECTED_FILES = 120
EXPECTED_BRIEFINGS = 116
EXPECTED_INFO = 4
EXPECTED_PLAIN = ("Default.txt",)
EXPECTED_LABELS = 1234
EXPECTED_ENDS = 442
EXPECTED_FONT_COMMANDS = {0: 901, 1: 799}
EXPECTED_COLOUR_COMMANDS = {0: 302, 1: 325, 2: 0}
EXPECTED_BREAKS = 2347
EXPECTED_DUPLICATES = {("_C_180.txt", "13"): 2}
EXPECTED_BARE_HASH = {"Errors.txt": 1}
EXPECTED_WITH_C0 = 91
EXPECTED_PROGRAM_ENTRIES = 198
EXPECTED_PROGRAM_FILES = 75
EXPECTED_PROGRAM_ROWS = {0: 75, 1: 20, 2: 2, 5: 70, 6: 19, 7: 9, 8: 3}
EXPECTED_MISSING_PICTURES = {("_C_132.txt", "No")}
EXPECTED_INFO_FALLBACKS = {"Data.txt": ["**", "*1", "*2"],
                           "Campaign.txt": ["**"]}
INFO_NAME_LITERALS = {0x004C2F14: "Data", 0x004C1304: "Events"}
"""The only two info file names the binary carries as a literal."""
INFO_NAMES_ABSENT = ("Errors", "Campaign", "errors", "campaign")
"""The other two ship as data but no code names them; see docs/24 7.2."""
ACTIVATE_INFO_COMMANDS = ("ActivateInfo", "ActivateInfoSuccessor")
"""The only two LCL commands that can name an info file at runtime."""
DIALOG_INFO_NAME = 0x004CADC4
"""``aActivateDialogInfo`` is called with this literal at 0x0045C6B0 ..."""
EXPECTED_INFO_STEMS = {"campaign", "data", "errors", "events"}
"""... and no such file ships."""
EXPECTED_A0_OVERFLOW = 6
EXPECTED_LONGEST_FIELD = 59

# --- code expectations -----------------------------------------------------

FIND_LABEL_TESTS = {0x0043DE1D: ord("{"), 0x0043DE23: ord(":")}
GET_STRING_TESTS = {0x0043DF1E: ord("@"), 0x0043DF22: ord("|"),
                    0x0043DF26: ord("#")}
GET_STRING_LIMIT = 0x0043DF34
MEASURE_TESTS = {0x0043DA5A: (2, ord("{")), 0x0043DA5F: (3, ord(":")),
                 0x0043DBF4: (2, ord("{")), 0x0043DBF9: (3, ord("*")),
                 0x0043DC29: (3, ord("@")), 0x0043DC6C: (1, ord("{")),
                 0x0043DC75: (1, ord("#")), 0x0043DC79: (1, 0xA7)}
LABEL_SKIP_SITES = (0x0043DA8E, 0x0043DE52)
GET_FONT = 0x00439E20
GET_FONT_FALLBACK = 0x00439E2C
"""``or eax, -1`` -- the arm every id but 0 and 1 falls into."""
FONT_SLOTS = {0: 0x005057E8, 1: 0x005057EC}
FONT_LIB_SITES = {0: (0x00439D66, 0x004C41CC), 1: (0x00439DA7, 0x004C41B0)}
FONT_METRICS = (12, 4, 1)
FONT_METRIC_SITES = (0x00439D64, 0x00439D62, 0x00439D60)
"""``push 12; push 4; push 1`` -- line height, space width, tracking."""
COLOUR_SITES = {1: (0x0043E47A, (0x94B2, 0x528A, 0x0841, 0x0000)),
                2: (0x0043E458, (0xF800, 0x6000, 0x0800, 0x0000))}
INDENT_VALUE = 100
INDENT_SITES = (0x0043E7AC, 0x0043E8BB, 0x0043E9EB, 0x0043EB27)
BOX_ID_GETTER = 0x0043ECE0
BOX_ID = 2
PATH_FORMATS = {0x004C4000: "%sTXT\\%s\\Briefing\\%s.txt",
                0x004C3FAC: "%sTXT\\%s\\Briefing\\default.txt",
                0x004C4688: "%s%s\\Info\\%s.txt"}
FALLBACK_SITE = 0x0043E910
ACTIVATE_BRIEFING = 0x0043EAB0


# --- corpus ----------------------------------------------------------------

def text_files(root: str) -> list[str]:
    """Every ``.txt`` under ``DATA/TXT``, in a stable order."""
    base = os.path.join(root, TXT_DIR)
    out = []
    for dirpath, _dirs, names in os.walk(base):
        for name in names:
            if name.lower().endswith(".txt"):
                out.append(os.path.join(dirpath, name))
    return sorted(out)


def load(path: str) -> str:
    """The plain text of one file, latin-1, marker byte stripped."""
    with open(path, "rb") as fh:
        return decode(fh.read()).decode("latin-1")


def load_fonts(root: str) -> dict[int, Font]:
    fonts = {}
    for font_id, rel in FONT_LIBS.items():
        lib = load_lib(os.path.join(root, rel))
        fonts[font_id] = Font.from_lib(font_id, os.path.basename(rel), lib,
                                       *FONT_METRICS)
    return fonts


def commands(text: str) -> list[tuple[int, str]]:
    """Every ``{``-introduced command, as ``(offset, body)`` without braces."""
    out = []
    start = 0
    while True:
        hit = text.find("{", start)
        if hit < 0:
            return out
        end = text.find("}", hit)
        if end < 0 or end - hit > 4:
            out.append((hit, text[hit + 1:hit + 4]))
            start = hit + 1
            continue
        out.append((hit, text[hit + 1:end]))
        start = end + 1


# --- code ------------------------------------------------------------------

_IMMEDIATE = {0x6A: 1, 0x68: 4}
"""``push imm8`` and ``push imm32`` -- the only operands worth recovering."""


def _modrm_length(pe: PEFile, va: int) -> int:
    """Bytes taken by a modrm byte and whatever addressing follows it."""
    modrm = pe.u8(va)
    mod, rm = modrm >> 6, modrm & 7
    size = 1
    if mod != 3 and rm == 4:
        sib = pe.u8(va + 1)
        size += 1
        if mod == 0 and (sib & 7) == 5:
            size += 4
    if mod == 1:
        size += 1
    elif mod == 2 or (mod == 0 and rm == 5):
        size += 4
    return size


def _instruction_length(pe: PEFile, va: int) -> int | None:
    """Length of the one instruction at *va*, for the handful of forms that
    appear between the pushes of an argument list.  ``None`` means "not one of
    them", which makes a mis-aligned decode fail instead of inventing values.
    """
    op = pe.u8(va)
    if 0x40 <= op <= 0x5F:          # inc/dec/push/pop of a register
        return 1
    if op in (0x6A,):
        return 2
    if op in (0x68, 0xE8, 0xA1, 0xB8):
        return 5
    if op in (0x8B, 0x8D, 0x89, 0x33, 0x85, 0x03, 0x2B):
        return 1 + _modrm_length(pe, va + 1)
    if op == 0x83:
        return 1 + _modrm_length(pe, va + 1) + 1
    return None


def push_chain(pe: PEFile, call_va: int, window: int = 64) -> list[int]:
    """The immediates pushed for the call at *call_va*, in push order.

    Every start inside *window* is decoded forward; a start counts only when
    its instruction stream lands exactly on the call, and the longest such
    chain wins.  A mis-aligned guess desynchronises and is rejected rather
    than producing plausible-looking numbers.
    """
    best: list[int] = []
    for back in range(4, window):
        va = call_va - back
        values: list[int] = []
        while va < call_va:
            size = _instruction_length(pe, va)
            if size is None:
                break
            width = _IMMEDIATE.get(pe.u8(va))
            if width == 1:
                values.append(pe.u8(va + 1))
            elif width == 4:
                values.append(pe.u32(va + 1))
            va += size
        if va == call_va and len(values) > len(best):
            best = values
    return best


def callers(pe: PEFile, target: int) -> list[int]:
    """Every ``call rel32`` in ``.text`` that reaches *target*."""
    lo, size, raw, rawsize = pe.section(".text")
    data = pe.data[raw:raw + rawsize]
    out = []
    for i in range(len(data) - 5):
        if data[i] != 0xE8:
            continue
        rel = int.from_bytes(data[i + 1:i + 5], "little", signed=True)
        if lo + i + 5 + rel == target:
            out.append(lo + i)
    return out


# --- reporting -------------------------------------------------------------

def describe(path: str, fonts: dict[int, Font] | None = None) -> dict:
    text = load(path)
    found = labels(text)
    out: dict = {
        "file": os.path.basename(path),
        "bytes": os.path.getsize(path),
        "obfuscated": is_encoded(open(path, "rb").read()),
        "labels": [{"key": lb.key, "offset": lb.tag} for lb in found],
        "blocks": {},
        "program": [],
    }
    out["fields"] = {}
    for key in dict.fromkeys(lb.key for lb in found):
        try:
            value = field(text, key)
        except BriefError:
            value = None        # longer than a field may be: it is a block
        if value is not None:
            at = text.find("{:" + key) + 5
            stop = at + len(value)
            if stop < len(text) and text[stop] == FIELD_SEPARATOR:
                out["fields"][key] = value.strip()
                continue
        try:
            body = block(text, key)
        except BriefError:
            continue
        if body is not None:
            out["blocks"][key] = body
    for base in (BRIEFING_BASE_ROW, TIP_BASE_ROW):
        for entry in program(text, base):
            out["program"].append({"row": entry.row, "picture": entry.picture,
                                   "x": entry.x, "y": entry.y,
                                   "descriptions": entry.descriptions})
    if fonts:
        out["lines"] = {}
        for key, (width, _height) in BOX_FOR_KEY.items():
            if key in out["blocks"]:
                at = text.find("{:" + key) + 5
                out["lines"][key] = [ln.rendered
                                     for ln in layout(text, at, width, fonts)]
    return out


def print_file(path: str, root: str | None, args) -> int:
    fonts = None
    if root:
        try:
            fonts = load_fonts(root)
        except (LibError, OSError):
            fonts = None
    text = load(path)
    if args.json:
        print(json.dumps(describe(path, fonts), indent=2))
        return 0
    if args.program:
        for base in (BRIEFING_BASE_ROW, TIP_BASE_ROW):
            for entry in program(text, base):
                print(f"row {entry.row}  {entry.picture:<12} "
                      f"({entry.x:>3},{entry.y:>3})  "
                      f"{' / '.join(entry.descriptions)}")
        return 0
    if args.label:
        body = block(text, args.label)
        if body is None:
            LOG.error("no label {:%s} in %s", args.label, path)
            return 1
        if args.layout:
            if not fonts:
                LOG.error("--layout needs the game root for the font libraries")
                return 2
            at = text.find("{:" + args.label) + 5
            for line in layout(text, at, args.layout, fonts):
                print(line.rendered)
            return 0
        print(body)
        return 0
    info = describe(path, fonts)
    print(f"{info['file']}  {info['bytes']} bytes  "
          f"{'obfuscated' if info['obfuscated'] else 'plain text'}")
    print(f"  labels : {' '.join(lb['key'] for lb in info['labels'])}")
    print(f"  blocks : {' '.join(sorted(info['blocks']))}")
    if info["fields"]:
        print(f"  fields : {' '.join(sorted(info['fields']))}")
    for entry in info["program"]:
        print(f"  row {entry['row']}  {entry['picture']:<12} "
              f"({entry['x']:>3},{entry['y']:>3})  "
              f"{' / '.join(entry['descriptions'])}")
    return 0


# --- checks ----------------------------------------------------------------

class Checker:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            self.passed += 1
            LOG.info("  ok    %-24s %s", name, detail)
        else:
            self.failed += 1
            LOG.error("  FAIL  %-24s %s", name, detail)

    def equal(self, name: str, got, want, fmt=str) -> None:
        self.check(name, got == want,
                   fmt(got) if got == want else f"got {fmt(got)} want {fmt(want)}")


def _hexlist(values) -> str:
    return "[" + ", ".join(f"0x{v:08X}" for v in values) + "]"


def run_check(root: str) -> int:  # noqa: C901 -- a checklist, not a branchy algorithm
    exe = os.path.join(root, GAME_EXE)
    if not os.path.isfile(exe):
        LOG.error("%s not found under %s", GAME_EXE, root)
        return 2
    pe = PEFile(exe)
    c = Checker()

    LOG.info("the corpus")
    files = text_files(root)
    c.equal("corpus.files", len(files), EXPECTED_FILES)
    if not files:
        LOG.error("empty corpus -- nothing was examined")
        return 1
    briefings = [p for p in files if os.path.basename(os.path.dirname(p)).lower()
                 == "briefing"]
    infos = [p for p in files if os.path.basename(os.path.dirname(p)).lower()
             == "info"]
    c.equal("corpus.briefings", len(briefings), EXPECTED_BRIEFINGS)
    c.equal("corpus.info", len(infos), EXPECTED_INFO)

    raw = {p: open(p, "rb").read() for p in files}
    plain = tuple(sorted(os.path.basename(p) for p in files
                         if not is_encoded(raw[p])))
    c.equal("corpus.plain", plain, EXPECTED_PLAIN)
    trips = sum(1 for p in files
                if (encode(decode(raw[p])) if is_encoded(raw[p])
                    else decode(raw[p])) == raw[p])
    c.equal("corpus.roundtrip", trips, len(files),
            lambda v: f"{v}/{len(files)}")

    texts = {p: raw[p].decode("latin-1") if not is_encoded(raw[p])
             else decode(raw[p]).decode("latin-1") for p in files}

    label_total = ends = breaks = 0
    fonts_used: dict[int, int] = {}
    colours_used: dict[int, int] = {}
    unknown: list[tuple[str, str]] = []
    duplicates: dict[tuple[str, str], int] = {}
    bare_hash: dict[str, int] = {}
    for path, text in texts.items():
        name = os.path.basename(path)
        seen: dict[str, int] = {}
        for lb in labels(text):
            seen[lb.key] = seen.get(lb.key, 0) + 1
        label_total += sum(seen.values())
        for key, count in seen.items():
            if count > 1:
                duplicates[(name, key)] = count
        breaks += text.count("@")
        for _offset, body in commands(text):
            if body == "*":
                ends += 1
            elif body[:1] == ":" and len(body) == 3:
                pass
            elif body[:1] == "\xa7" and len(body) == 2:
                fonts_used[int(body[1])] = fonts_used.get(int(body[1]), 0) + 1
            elif body[:1] == "#" and len(body) == 2:
                colours_used[int(body[1])] = colours_used.get(int(body[1]), 0) + 1
            else:
                unknown.append((name, body))
        for i, ch in enumerate(text):
            if ch == "#" and (i == 0 or text[i - 1] != "{"):
                bare_hash[name] = bare_hash.get(name, 0) + 1

    c.equal("corpus.labels", label_total, EXPECTED_LABELS)
    c.equal("corpus.ends", ends, EXPECTED_ENDS)
    c.equal("corpus.breaks", breaks, EXPECTED_BREAKS)
    c.equal("corpus.fonts", dict(sorted(fonts_used.items())),
            EXPECTED_FONT_COMMANDS)
    c.equal("corpus.colours",
            {n: colours_used.get(n, 0) for n in sorted(COLOUR_RAMPS)},
            EXPECTED_COLOUR_COMMANDS)
    c.equal("corpus.unknown", unknown, [("Errors.txt", "...")])
    c.equal("corpus.duplicates", duplicates, EXPECTED_DUPLICATES)
    c.equal("corpus.bare_hash", bare_hash, EXPECTED_BARE_HASH)

    LOG.info("the three briefing blocks")
    have = {key: [p for p in briefings if "{:" + key in texts[p]]
            for key in BRIEFING_KEYS}
    c.equal("brief.a0", len(have["A0"]), EXPECTED_BRIEFINGS)
    c.equal("brief.b0", len(have["B0"]), EXPECTED_BRIEFINGS)
    c.equal("brief.c0", len(have["C0"]), EXPECTED_WITH_C0)
    unclosed = []
    closed = 0
    for key in BRIEFING_KEYS:
        for path in have[key]:
            try:
                closed += block(texts[path], key) is not None
            except BriefError:
                unclosed.append(f"{os.path.basename(path)} {key}")
    total = sum(len(have[key]) for key in BRIEFING_KEYS)
    c.check("brief.closed", closed == total and not unclosed,
            f"{closed}/{total}" + (f" unclosed {unclosed}" if unclosed else ""))

    LOG.info("the briefing program")
    entries = []
    program_files = 0
    rows: dict[int, int] = {}
    longest = 0
    broken = []
    for path in briefings:
        found = []
        try:
            for base in (BRIEFING_BASE_ROW, TIP_BASE_ROW):
                found += program(texts[path], base)
        except BriefError as exc:
            broken.append(f"{os.path.basename(path)}: {exc}")
            continue
        if found:
            program_files += 1
        for entry in found:
            rows[entry.row] = rows.get(entry.row, 0) + 1
            longest = max([longest, len(entry.picture)]
                          + [len(d) for d in entry.descriptions])
        entries += [(os.path.basename(path), e) for e in found]
    c.equal("program.readable", broken, [], lambda v: f"{len(briefings)} files")
    c.equal("program.entries", len(entries), EXPECTED_PROGRAM_ENTRIES)
    c.equal("program.files", program_files, EXPECTED_PROGRAM_FILES)
    c.equal("program.rows", dict(sorted(rows.items())), EXPECTED_PROGRAM_ROWS)
    c.check("program.limit", longest < FIELD_LIMIT,
            f"longest field {longest} < {FIELD_LIMIT}")
    c.equal("program.longest", longest, EXPECTED_LONGEST_FIELD)
    c.check("program.coords",
            all(0 <= e.x < 640 and 0 <= e.y < 480 for _n, e in entries),
            f"{len(entries)}/{len(entries)} inside 640x480")
    bitmaps = {os.path.splitext(n)[0].lower()
               for n in os.listdir(os.path.join(root, BITMAP_DIR))}
    missing = {(name, e.picture) for name, e in entries
               if e.picture.lower() not in bitmaps}
    c.equal("program.pictures", missing, EXPECTED_MISSING_PICTURES)

    LOG.info("the info files")
    fallbacks = {os.path.basename(p): sorted({lb.key for lb in labels(texts[p])
                                              if "*" in lb.key})
                 for p in infos}
    c.equal("info.fallbacks",
            {k: v for k, v in fallbacks.items() if v}, EXPECTED_INFO_FALLBACKS)
    info_unclosed = []
    for path in infos:
        for lb in labels(texts[path]):
            try:
                block(texts[path], lb.key)
            except BriefError:
                info_unclosed.append(f"{os.path.basename(path)} {lb.key}")
    c.check("info.closed", not info_unclosed,
            f"{len(infos)}/{len(infos)} files" if not info_unclosed
            else f"unclosed {info_unclosed}")

    c.equal("info.named",
            {va: pe.cstring(va) for va in INFO_NAME_LITERALS},
            INFO_NAME_LITERALS, lambda d: ", ".join(d.values()))
    image = pe.data

    def standalone(word: str) -> bool:
        return b"\x00" + word.encode("ascii") + b"\x00" in image

    c.check("info.named_control",
            all(standalone(n) for n in INFO_NAME_LITERALS.values()),
            "the same scan does find Data and Events")
    c.equal("info.unnamed", [n for n in INFO_NAMES_ABSENT if standalone(n)],
            ["campaign"], lambda v: f"{v} (the session-type word, 0x004C33EC)")

    scripts = [os.path.join(d, n) for d, _s, names in os.walk(root)
               for n in names if n.lower().endswith((".lcl", ".gcl"))]
    used = sum(decode(open(p, "rb").read()).count(cmd.encode("ascii"))
               for p in scripts for cmd in ACTIVATE_INFO_COMMANDS)
    c.check("info.lcl_sites", bool(scripts) and used == 0,
            f"{len(scripts)} scripts, 0 uses of {'/'.join(ACTIVATE_INFO_COMMANDS)}")

    stems = {os.path.splitext(os.path.basename(p))[0].lower() for p in infos}
    c.equal("info.stems", stems, EXPECTED_INFO_STEMS, lambda v: " ".join(sorted(v)))
    c.check("info.dialog", pe.cstring(DIALOG_INFO_NAME) == "dialog_1"
            and "dialog_1" not in stems,
            "the dialogue info box names a file that does not ship")

    LOG.info("layout against the shipped fonts")
    fonts = load_fonts(root)
    c.equal("font.glyphs", {i: len(f.glyphs) for i, f in fonts.items()},
            {0: 224, 1: 224})
    overflow = {"A0": 0, "B0": 0, "C0": 0}
    unlayoutable = []
    for key, (width, height) in BOX_FOR_KEY.items():
        for path in have[key]:
            at = texts[path].find("{:" + key) + 5
            try:
                lines = layout(texts[path], at, width, fonts)
            except BriefError as exc:
                unlayoutable.append(f"{os.path.basename(path)} {key}: {exc}")
                continue
            if len(lines) * fonts[0].line_height > height:
                overflow[key] += 1
    c.equal("layout.readable", unlayoutable, [],
            lambda v: f"{sum(len(v) for v in have.values())} blocks")
    c.equal("layout.b0", overflow["B0"], 0,
            lambda v: f"{len(have['B0'])}/{len(have['B0'])} fit 200x300")
    c.equal("layout.c0", overflow["C0"], 0,
            lambda v: f"{len(have['C0'])}/{len(have['C0'])} fit 230x276")
    c.equal("layout.a0", overflow["A0"], EXPECTED_A0_OVERFLOW,
            lambda v: f"{v}/{len(have['A0'])} overflow 280x276")

    LOG.info("the readers in Incubation.exe")
    c.equal("code.find_label",
            {va: pe.u8(va + 3) for va in FIND_LABEL_TESTS},
            FIND_LABEL_TESTS, lambda d: ", ".join(f"{v:#04x}" for v in d.values()))
    c.check("code.label_skip",
            all(pe.u8(va + 2) == 5 for va in LABEL_SKIP_SITES),
            "both readers step 5 bytes past {:xy}")
    c.equal("code.terminators",
            {va: pe.u8(va + 1) for va in GET_STRING_TESTS},
            GET_STRING_TESTS, lambda d: "".join(chr(v) for v in d.values()))
    c.equal("code.field_limit", pe.u32(GET_STRING_LIMIT + 2), FIELD_LIMIT)
    c.equal("code.markup",
            {va: pe.u8(va + off) for va, (off, _want) in MEASURE_TESTS.items()},
            {va: want for va, (_off, want) in MEASURE_TESTS.items()},
            lambda d: " ".join(f"{v:#04x}" for v in d.values()))

    LOG.info("fonts and colours")
    c.equal("code.font_slots",
            {0: pe.u32(GET_FONT + 0x17), 1: pe.u32(GET_FONT + 0x11)},
            FONT_SLOTS, _hexlist_map)
    c.equal("code.font_default", pe.bytes_at(GET_FONT_FALLBACK, 3),
            b"\x83\xc8\xff",
            lambda v: "or eax, -1 for any id but 0 and 1")
    c.equal("code.font_libs",
            {i: pe.cstring(pe.u32(va + 1)) for i, (va, _s) in FONT_LIB_SITES.items()},
            {0: "font_0.lib", 1: "font_1.lib"})
    c.equal("code.font_metrics",
            tuple(pe.u8(va + 1) for va in FONT_METRIC_SITES), FONT_METRICS)
    c.equal("code.colours",
            {n: tuple(pe.u32(va + 8 * i + 4) for i in range(4))
             for n, (va, _want) in COLOUR_SITES.items()},
            {n: want for n, (_va, want) in COLOUR_SITES.items()},
            lambda d: " ".join(f"{n}:{tuple(hex(x) for x in v)}"
                               for n, v in d.items()))
    c.check("code.indent",
            all(pe.u32(va + 6) == INDENT_VALUE for va in INDENT_SITES),
            f"all four activators set indent {INDENT_VALUE}")
    c.equal("code.box_id", pe.u32(BOX_ID_GETTER + 1), BOX_ID)
    c.equal("code.paths", {va: pe.cstring(va) for va in PATH_FORMATS},
            PATH_FORMATS, lambda d: "; ".join(d.values()))
    c.equal("code.fallback",
            chr(pe.u8(FALLBACK_SITE + 1)) + chr(pe.u8(FALLBACK_SITE + 3)),
            FALLBACK_KEY, lambda v: "{:" + v + "}")

    LOG.info("every briefing call site")
    sites = callers(pe, ACTIVATE_BRIEFING)
    c.equal("code.sites", sites, sorted(BRIEFING_SITES), _hexlist)
    decoded = {}
    for va in sites:
        chain = push_chain(pe, va)
        if len(chain) < 6:
            c.check("code.site_args", False, f"{va:#010x}: no push chain")
            continue
        height, width, y, x = chain[-4:]
        decoded[va] = (chr(chain[1]) + chr(chain[0]), x, y, width, height)
    c.equal("code.site_args", decoded, BRIEFING_SITES,
            lambda d: f"{len(d)}/{len(BRIEFING_SITES)} sites")
    c.equal("code.site_keys", sorted({v[0] for v in decoded.values()}),
            sorted(set(BRIEFING_KEYS)))

    print()
    LOG.info("=== %d/%d checks passed ===",
             c.passed, c.passed + c.failed)
    return 1 if c.failed else 0


def _hexlist_map(d) -> str:
    return " ".join(f"{k}:0x{v:08X}" for k, v in d.items())


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("target", nargs="?", default="gog_incubation",
                    help="a .txt file, or the game directory")
    ap.add_argument("--check", metavar="ROOT", help="run every check")
    ap.add_argument("--label", metavar="XY", help="print one labelled block")
    ap.add_argument("--layout", type=int, metavar="WIDTH",
                    help="wrap the block the way the engine does")
    ap.add_argument("--program", action="store_true",
                    help="print the briefing/tip program rows")
    ap.add_argument("--root", help="game directory, for the font libraries")
    ap.add_argument("--json", action="store_true", help="dump as JSON")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    try:
        if args.check:
            if not os.path.isdir(args.check):
                LOG.error("root %s is not a directory", args.check)
                return 2
            return run_check(args.check)
        if os.path.isdir(args.target):
            files = text_files(args.target)
            if not files:
                LOG.error("no .txt files under %s", args.target)
                return 1
            for path in files:
                info = describe(path)
                print(f"{info['file']:<16} {len(info['labels']):>3} labels  "
                      f"{' '.join(sorted(info['blocks']))}")
            return 0
        root = args.root
        if root is None:
            head = os.path.abspath(args.target)
            while head != os.path.dirname(head):
                head = os.path.dirname(head)
                if os.path.isfile(os.path.join(head, GAME_EXE)):
                    root = head
                    break
        return print_file(args.target, root, args)
    except (BriefError, LibError, PEError, OSError) as exc:
        LOG.error("%s", exc)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

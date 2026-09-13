#!/usr/bin/env python3
"""Pin the engine's language switch chain against ``Incubation.exe``.

``docs/24`` §1: a command-line switch (``-english`` … ``-japanese``) becomes a
1-based code in ``[0x50DC1C]`` (default 1), the jump table at ``0x44A4D8``
turns the code into a *name* literal (``"English"``, ``"German"``, …;
codes 4..6 fall to ``"unknown"``), the setter ``0x453DC0`` stores it and
``aGetLanguage`` ``0x453DF0`` returns ``0x510780``.  The name is only ever a
directory component in three ``wsprintf`` templates.  Everything
:mod:`inclib.language` says about the engine is read out of the binary here,
byte by byte, so a row of that table cannot drift from the code it describes.

The census at the end is the localisation model's premise: the GOG tree holds
exactly one ``DATA/TXT/<Name>`` directory, ``English``, so any other language
has to arrive as a pack laid over it (``docs/92`` §7.6).

Usage::

    python3 tools/language_tables.py --check gog_incubation
    python3 tools/language_tables.py --json
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import struct
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import language  # noqa: E402
from inclib.check import Checker  # noqa: E402
from inclib.pe import PEFile  # noqa: E402

LOG = logging.getLogger("language_tables")

GAME_EXE = "Incubation.exe"

#: ``aMain.cpp``'s parser: each switch literal, and the instruction that
#: stores its code into ``[0x50DC1C]``.  German's store is ``mov [..], ebx``
#: with ``ebx`` set to 2 at ``0x4494FB`` (it doubles as the strcmp stride),
#: so its immediate is pinned at that earlier instruction.
LANGUAGE_CODE_VAR = 0x50DC1C
SWITCH_LITERALS = {
    "-english": 0x4C6098,
    "-german": 0x4C6090,
    "-french": 0x4C6088,
    "-spanish": 0x4C607C,
    "-italian": 0x4C6070,
    "-japanese": 0x4C6064,
}
#: ``mov dword [0x50DC1C], imm32`` -- ``c7 05 <var> <imm>``.
CODE_STORES = {
    "-english": (0x44970C, 1),
    "-french": (0x449780, 3),
    "-spanish": (0x4497BC, 8),
    "-italian": (0x4497F8, 9),
    "-japanese": (0x449834, 7),
}
#: ``mov ebx, 2`` at 0x4494FB, then ``mov dword [0x50DC1C], ebx`` at 0x449748.
GERMAN_EBX_LOAD = 0x4494FB
GERMAN_CODE_STORE = 0x449748
#: ``mov esi, 1`` / ``mov dword [0x50DC1C], esi`` -- the default before any
#: switch is read.
DEFAULT_LOAD = 0x449583
DEFAULT_STORE = 0x44958F
DEFAULT_CODE = 1
#: ``-debugx`` (``0x4C60C0``) sets ``[0x50DC18]``, and ``0x449864`` then pushes
#: ``"English"`` unconditionally -- the debug build forces the language.
DEBUGX_LITERAL = 0x4C60C0
DEBUGX_PUSH = 0x449864

#: ``lea eax, [ecx-1]; cmp eax, 8; ja unknown; jmp [eax*4 + 0x44A4D8]``.
SWITCH_HEAD = 0x4498A5
SWITCH_HEAD_BYTES = bytes.fromhex("8d41ff" "83f808" "0f87be0b0000"
                                  "ff2485d8a44400")
JUMP_TABLE = 0x44A4D8
JUMP_TABLE_ENTRIES = 9
NAME_LITERALS = {
    "English": 0x4C605C,
    "German": 0x4C5E88,
    "French": 0x4C5E80,
    "Japanese": 0x4C4144,
    "Spanish": 0x4C5E78,
    "Italian": 0x4C5E70,
    "unknown": 0x4C5E68,
}
#: Jump-table index (code - 1) -> the arm's name.  Arms 3..5 are the
#: ``unknown`` arm, which loads the literal into ``esi`` rather than pushing it.
ARMS = {0: "English", 1: "German", 2: "French", 3: "unknown", 4: "unknown",
        5: "unknown", 6: "Japanese", 7: "Spanish", 8: "Italian"}
UNKNOWN_ARM = 0x44A46F
SETTER = 0x453DC0
GETTER = 0x453DF0
GETTER_BYTES = bytes.fromhex("b880075100c3")
LANGUAGE_NAME_VAR = 0x510780

TEMPLATES = {
    0x4C4000: "%sTXT\\%s\\Briefing\\%s.txt",
    0x4C4688: "%s%s\\Info\\%s.txt",
    0x4CC914: "TXT\\%s\\GUI\\%s",
}


def _push_imm32(pe: PEFile, va: int) -> int | None:
    """The operand of a ``push imm32`` (``68 xx xx xx xx``) at *va*."""
    code = pe.bytes_at(va, 5)
    if code[0] != 0x68:
        return None
    return struct.unpack_from("<I", code, 1)[0]


def _mov_esi_imm32(pe: PEFile, va: int) -> int | None:
    code = pe.bytes_at(va, 5)
    if code[0] != 0xBE:
        return None
    return struct.unpack_from("<I", code, 1)[0]


def _call_target(pe: PEFile, va: int) -> int | None:
    code = pe.bytes_at(va, 5)
    if code[0] != 0xE8:
        return None
    return (va + 5 + struct.unpack_from("<i", code, 1)[0]) & 0xFFFFFFFF


def _mov_mem_imm32(pe: PEFile, va: int) -> tuple[int, int] | None:
    """``c7 05 <addr> <imm>`` -> ``(addr, imm)``."""
    code = pe.bytes_at(va, 10)
    if code[:2] != b"\xc7\x05":
        return None
    return struct.unpack_from("<II", code, 2)


def run_check(root: Path) -> int:
    c = Checker()
    exe = root / GAME_EXE
    if not exe.is_file():
        c.check("binary", False, f"no {GAME_EXE} under {root}")
        return c.report()
    pe = PEFile(exe)

    # The six switches and where each one's code lands.
    for switch, va in sorted(SWITCH_LITERALS.items()):
        c.expect(f"switch.{switch}", pe.cstring(va), switch, hex(va))
    for switch, (va, code) in sorted(CODE_STORES.items()):
        c.expect(f"code.{switch}", _mov_mem_imm32(pe, va),
                 (LANGUAGE_CODE_VAR, code), f"{hex(va)} stores {code}")
    c.expect("code.-german.ebx",
             pe.bytes_at(GERMAN_EBX_LOAD, 5), bytes.fromhex("bb02000000"),
             "mov ebx, 2")
    c.expect("code.-german.store",
             pe.bytes_at(GERMAN_CODE_STORE, 6),
             b"\x89\x1d" + struct.pack("<I", LANGUAGE_CODE_VAR),
             "mov [0x50DC1C], ebx")
    c.expect("code.default", (pe.bytes_at(DEFAULT_LOAD, 5),
                              pe.bytes_at(DEFAULT_STORE, 6)),
             (b"\xbe" + struct.pack("<I", DEFAULT_CODE),
              b"\x89\x35" + struct.pack("<I", LANGUAGE_CODE_VAR)),
             f"mov esi, {DEFAULT_CODE}; mov [0x50DC1C], esi")
    c.expect("debugx.literal", pe.cstring(DEBUGX_LITERAL), "-debugx")
    c.expect("debugx.forces_english", _push_imm32(pe, DEBUGX_PUSH),
             NAME_LITERALS["English"], "push \"English\" on the debug arm")

    # The code -> name switch.
    c.expect("switch.head", pe.bytes_at(SWITCH_HEAD, len(SWITCH_HEAD_BYTES)),
             SWITCH_HEAD_BYTES, "lea eax,[ecx-1]; cmp eax,8; ja; jmp [table]")
    for name, va in sorted(NAME_LITERALS.items()):
        c.expect(f"name.{name}", pe.cstring(va), name, hex(va))
    arms = [pe.u32(JUMP_TABLE + 4 * i) for i in range(JUMP_TABLE_ENTRIES)]
    for index, arm in enumerate(arms):
        want = ARMS[index]
        if want == "unknown":
            c.expect(f"arm.{index}", arm, UNKNOWN_ARM, "the unknown arm")
            continue
        c.expect(f"arm.{index}", _push_imm32(pe, arm), NAME_LITERALS[want],
                 f"{hex(arm)} pushes \"{want}\"")
        c.expect(f"arm.{index}.setter", _call_target(pe, arm + 5), SETTER,
                 "then calls the setter")
    c.expect("arm.unknown", _mov_esi_imm32(pe, UNKNOWN_ARM),
             NAME_LITERALS["unknown"], "mov esi, \"unknown\"")
    c.expect("getter.bytes", pe.bytes_at(GETTER, 6), GETTER_BYTES,
             f"mov eax, {hex(LANGUAGE_NAME_VAR)}; ret")
    for va, text in sorted(TEMPLATES.items()):
        c.expect(f"template.{hex(va)}", pe.cstring(va), text)

    # The table agrees with the binary: every engine row's switch and code
    # are the ones the parser stores, and the engine's order of codes is the
    # table's.
    by_switch = {row.switch: row for row in language.LANGUAGES
                 if row.switch is not None}
    c.expect("table.switches", sorted(by_switch), sorted(SWITCH_LITERALS))
    stores = {s: code for s, (_va, code) in CODE_STORES.items()}
    stores["-german"] = 2
    c.expect("table.codes", {s: row.engine_code for s, row in by_switch.items()},
             stores)
    c.expect("table.arms",
             {row.engine_code - 1: row.name for row in by_switch.values()},
             {i: n for i, n in ARMS.items() if n != "unknown"})
    c.expect("table.default", language.DEFAULT_LANGUAGE,
             ARMS[DEFAULT_CODE - 1])
    c.expect("table.directory_is_name",
             [row.directory for row in by_switch.values()],
             [row.name for row in by_switch.values()],
             "an engine language's directory is its name")
    c.expect("table.packs_without_arm",
             sorted(row.name for row in language.LANGUAGES
                    if row.switch is None), ["Russian"],
             "the in-place releases the engine has no arm for")

    # The census: the GOG tree ships one language directory.
    txt = root / "DATA" / "TXT"
    dirs = sorted(p.name for p in txt.iterdir() if p.is_dir()) \
        if txt.is_dir() else []
    c.expect("census.text_directories", dirs, [language.DEFAULT_LANGUAGE],
             "DATA/TXT holds exactly the default language")
    for byte in (0x81, 0x8D, 0x8F, 0x90, 0x9D):
        c.expect(f"codepoint.cp1252.{byte:02x}",
                 language.codepoint(byte, "cp1252"), byte,
                 "an undefined byte maps to itself")
    c.expect("codepoint.cp1251.98", language.codepoint(0x98, "cp1251"), 0x98)
    c.expect("codepoint.cp1251.c0", language.codepoint(0xC0, "cp1251"),
             ord("А"), "0xC0 is Cyrillic A")
    c.expect("codepoint.cp1252.a7", language.codepoint(0xA7, "cp1252"),
             ord("§"), "the briefing markup's own marker")
    return c.report()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", metavar="ROOT", help="pin the chain in the binary")
    ap.add_argument("--json", action="store_true",
                    help="print the language table")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    if args.json:
        print(json.dumps(language.to_dict(), indent=2, ensure_ascii=False))
        return 0
    if args.check:
        return run_check(Path(args.check))
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Dump Win32 PE resources — dialog templates, string tables, menus.

Stdlib only.  Written for the Incubation research work: the level
editor ``iDesigner.exe`` names most of the binary record layouts in its dialog
resources, and reading those templates is the fastest way to recover an
authoring-side field name.

Usage::

    python3 tools/pe_resources.py <file.exe> --list
    python3 tools/pe_resources.py <file.exe> --dialogs
    python3 tools/pe_resources.py <file.exe> --dialog 112
    python3 tools/pe_resources.py <file.exe> --strings
    python3 tools/pe_resources.py <file.exe> --grep charisma

``--dialogs`` prints every control with its **coordinates**, which is how a
control's identity must be resolved: the order of controls in the template is
not the order they appear on screen and has misled this project before.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.pe import PEError, PEFile, noff_of  # noqa: E402,F401

# Resource type ids (RT_*).
RT_NAMES = {
    1: "CURSOR", 2: "BITMAP", 3: "ICON", 4: "MENU", 5: "DIALOG",
    6: "STRING", 7: "FONTDIR", 8: "FONT", 9: "ACCELERATOR",
    10: "RCDATA", 11: "MESSAGETABLE", 12: "GROUP_CURSOR",
    14: "GROUP_ICON", 16: "VERSION", 24: "MANIFEST",
}

# Predefined dialog control window classes (atom form).
ATOM_CLASS = {
    0x80: "BUTTON", 0x81: "EDIT", 0x82: "STATIC",
    0x83: "LISTBOX", 0x84: "SCROLLBAR", 0x85: "COMBOBOX",
}

# Button styles worth reporting (low nibble of the control style).
BS_TYPE = {
    0: "PUSHBUTTON", 1: "DEFPUSHBUTTON", 2: "CHECKBOX", 3: "AUTOCHECKBOX",
    4: "RADIOBUTTON", 5: "3STATE", 6: "AUTO3STATE", 7: "GROUPBOX",
    8: "USERBUTTON", 9: "AUTORADIOBUTTON", 10: "OWNERDRAW",
}




# --- dialog templates -------------------------------------------------------

def _align4(n: int) -> int:
    return (n + 3) & ~3


def _sz_or_ord(buf: bytes, o: int):
    """Read a dialog template name field: ordinal, empty, or UTF-16 string."""
    w = struct.unpack_from("<H", buf, o)[0]
    if w == 0:
        return None, o + 2
    if w == 0xFFFF:
        return struct.unpack_from("<H", buf, o + 2)[0], o + 4
    end = o
    while struct.unpack_from("<H", buf, end)[0] != 0:
        end += 2
    return buf[o:end].decode("utf-16-le", "replace"), end + 2


class Control:
    __slots__ = ("cid", "cls", "text", "x", "y", "cx", "cy", "style", "exstyle")

    def __init__(self, cid, cls, text, x, y, cx, cy, style, exstyle):
        self.cid, self.cls, self.text = cid, cls, text
        self.x, self.y, self.cx, self.cy = x, y, cx, cy
        self.style, self.exstyle = style, exstyle

    @property
    def kind(self) -> str:
        if self.cls == "BUTTON":
            return BS_TYPE.get(self.style & 0xF, "BUTTON")
        return self.cls if isinstance(self.cls, str) else f"class#{self.cls}"

    def __str__(self) -> str:
        text = "" if self.text is None else str(self.text)
        return (f"    id={self.cid:<6} @({self.x:>4},{self.y:>4}) "
                f"{self.cx:>3}x{self.cy:<3} {self.kind:<14} "
                f"style={self.style:#010x} {text!r}")


class Dialog:
    def __init__(self, res_id, title, x, y, cx, cy, font, controls, ex):
        self.res_id, self.title = res_id, title
        self.x, self.y, self.cx, self.cy = x, y, cx, cy
        self.font, self.controls, self.ex = font, controls, ex

    def dump(self) -> str:
        head = (f"DIALOG{'EX' if self.ex else ''} {self.res_id}  "
                f"({self.x},{self.y}) {self.cx}x{self.cy}  "
                f"caption={self.title!r}  font={self.font}  "
                f"{len(self.controls)} controls")
        return "\n".join([head] + [str(c) for c in self.controls])


def parse_dialog(res_id, buf: bytes) -> Dialog:
    ex = (struct.unpack_from("<HH", buf, 0) == (1, 0xFFFF))
    if ex:
        # DLGTEMPLATEEX
        _dlgver, _sig, _helpid, exstyle, style = struct.unpack_from("<HHIII", buf, 0)
        cdit, x, y, cx, cy = struct.unpack_from("<Hhhhh", buf, 16)
        o = 26
    else:
        style, exstyle, cdit, x, y, cx, cy = struct.unpack_from("<IIHhhhh", buf, 0)
        o = 18
    _menu, o = _sz_or_ord(buf, o)
    _cls, o = _sz_or_ord(buf, o)
    title, o = _sz_or_ord(buf, o)
    font = None
    if style & 0x40:                                   # DS_SETFONT
        pt = struct.unpack_from("<H", buf, o)[0]
        o += 2
        if ex:
            o += 4                                     # weight, italic, charset
        face, o = _sz_or_ord(buf, o)
        font = (pt, face)

    controls = []
    for _ in range(cdit):
        o = _align4(o)
        if o >= len(buf):
            break
        if ex:
            _helpid, cexstyle, cstyle = struct.unpack_from("<III", buf, o)
            cx_, cy_, ccx, ccy = struct.unpack_from("<hhhh", buf, o + 12)
            cid = struct.unpack_from("<I", buf, o + 20)[0]
            o += 24
        else:
            cstyle, cexstyle = struct.unpack_from("<II", buf, o)
            cx_, cy_, ccx, ccy = struct.unpack_from("<hhhh", buf, o + 8)
            cid = struct.unpack_from("<H", buf, o + 16)[0]
            o += 18
        cls, o = _sz_or_ord(buf, o)
        if isinstance(cls, int):
            cls = ATOM_CLASS.get(cls, f"atom{cls:#x}")
        text, o = _sz_or_ord(buf, o)
        extra = struct.unpack_from("<H", buf, o)[0]
        o += 2 + extra
        controls.append(Control(cid, cls, text, cx_, cy_, ccx, ccy, cstyle, cexstyle))
    return Dialog(res_id, title, x, y, cx, cy, font, controls, ex)


class TruncatedResource(Exception):
    """A resource block ended before its declared contents did."""


def parse_stringtable(block_id: int, buf: bytes):
    """RT_STRING block ``n`` holds string ids ``(n-1)*16 .. (n-1)*16+15``.

    Raises :class:`TruncatedResource` rather than stopping quietly. This tool's
    output backs *negative* claims in the docs -- "no string in either binary
    names it" -- and a silent short read makes an absence indistinguishable
    from a truncation.
    """
    out, o, base = [], 0, (block_id - 1) * 16
    for i in range(16):
        if o + 2 > len(buf):
            raise TruncatedResource(
                f"string block {block_id}: ran out of data after {i} of 16 "
                f"entries ({len(buf)} bytes)")
        ln = struct.unpack_from("<H", buf, o)[0]
        o += 2
        if ln:
            if o + 2 * ln > len(buf):
                raise TruncatedResource(
                    f"string block {block_id}, entry {i}: declares {ln} chars "
                    f"but only {(len(buf) - o) // 2} remain")
            out.append((base + i, buf[o:o + 2 * ln].decode("utf-16-le", "replace")))
            o += 2 * ln
    return out


# --- CLI --------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("binary", type=Path)
    ap.add_argument("--list", action="store_true", help="list every resource")
    ap.add_argument("--dialogs", action="store_true", help="dump all dialog templates")
    ap.add_argument("--dialog", type=int, help="dump one dialog by resource id")
    ap.add_argument("--strings", action="store_true", help="dump the string table")
    ap.add_argument("--grep", help="case-insensitive filter over dialog and string text")
    args = ap.parse_args(argv)

    pe = PEFile(args.binary)
    res = list(pe.resources())
    problems = 0
    if not (args.list or args.dialogs or args.dialog is not None
            or args.strings or args.grep):
        args.list = True

    if args.list:
        print(f"{args.binary}  timestamp={pe.timestamp}  {len(res)} resources")
        for t, n, lang, blob in res:
            tn = RT_NAMES.get(t, t) if isinstance(t, int) else t
            print(f"  type={tn:<12} id={n:<8} lang={lang:<5} {len(blob):>7} bytes")

    needle = args.grep.lower() if args.grep else None

    if args.dialogs or args.dialog is not None or needle:
        for t, n, _lang, blob in res:
            if t != 5:
                continue
            if args.dialog is not None and n != args.dialog:
                continue
            try:
                dlg = parse_dialog(n, blob)
            except Exception as exc:                    # noqa: BLE001 - report and continue
                print(f"DIALOG {n}: parse failed: {exc}", file=sys.stderr)
                problems += 1
                continue
            text = dlg.dump()
            if needle and needle not in text.lower():
                continue
            print(text)
            print()

    if args.strings or needle:
        for t, n, _lang, blob in res:
            if t != 6:
                continue
            try:
                entries = parse_stringtable(n, blob)
            except TruncatedResource as exc:
                print(f"STRINGTABLE {n}: {exc}", file=sys.stderr)
                problems += 1
                continue
            for sid, s in entries:
                if needle and needle not in s.lower():
                    continue
                print(f"STRING {sid}: {s!r}")

    if problems:
        print(f"{problems} resource block(s) could not be read in full; the "
              f"listing above is incomplete", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

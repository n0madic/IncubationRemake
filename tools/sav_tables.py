#!/usr/bin/env python3
"""Check the save-game layout in Incubation.exe against docs/11.

The ``.sav`` format has no corpus -- the shipped ``Work/Saves`` tree is empty --
so the acceptance criterion is the binary itself.  Every block of a save is one
``WriteFile(h, &global, size)``, and the loader mirrors it; this tool recovers
the two chains from the machine code and asserts that they agree with each
other and with the documented layout.

Usage::

    python3 tools/sav_tables.py --check gog_incubation
    python3 tools/sav_tables.py --layout gog_incubation

Exit status is 0 only if every category passes and at least one was run.
"""

from __future__ import annotations

import argparse
import bisect
import logging
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib.pe import PEError, PEFile  # noqa: E402

log = logging.getLogger("sav_tables")

# --- addresses documented in docs/11 -----------------------------------------

A_SAVE_GAME = 0x00448AD0
A_LOAD_GAME = 0x00448E60
A_SAVE_BATTLE_MAP = 0x00419820
A_LOAD_BATTLE_MAP = 0x004195A0

A_WRITE_FILE = 0x00438BF0          # WriteFile(h, buf, size)
A_LOAD_FILE = 0x00438BD0           # ReadFile  variant
A_TRACE = 0x00453E00               # the compiled-out CHECK() reporter

# The nine save blocks, in file order: (name, writer, source VA, size).
# `None` marks a size or address the writer computes at run time.
SAVE_CHAIN = [
    ("GameFileHeader",     0x00448D10, 0x0050C240, 0x105),
    ("GameControl",        0x0043BC30, 0x00509D18, 0x2D0),
    ("ViewPlayer",         0x0047DBE0, 0x005229D0, 0x44C),
    ("UnitPool",           0x00479220, 0x0051F2A0, 0x1554),
    ("BattleMap",          0x00419820, None,       None),
    ("ProgramState",       0x0042E910, 0x004FEA50, 0x00C),
    ("LCL",                0x004406B0, 0x0050B850, 0x06D),
    ("MissionObjectives",  0x0045FF90, 0x00512590, 0x01C),
]

LOAD_CHAIN = [
    ("GameFileHeader",     0x004489F0, 0x0050C240, 0x105),
    ("GameControl",        0x0043BC80, 0x00509D18, 0x2D0),
    ("ViewPlayer",         0x0047DC20, 0x005229D0, 0x44C),
    ("UnitPool",           0x00479260, 0x0051F2A0, 0x1554),
    ("BattleMap",          0x004195A0, None,       None),
    ("ProgramState",       0x0042E950, 0x004FEA50, 0x00C),
    ("LCL",                0x004406F0, 0x0050B850, 0x06D),
    ("MissionObjectives",  0x0045FFD0, 0x00512590, 0x01C),
]

# aSaveBattleMap's own chain: (name, writer VA or None for the inline write,
# source VA, size).  None marks what the writer computes at run time.
BATTLE_MAP_BLOCKS = [
    ("Header",    None,       0x004FCED0, 0x360),
    ("CtrlMap",   0x00430FB0, None,       None),    # base and 23*W*H both live
    ("UnitMap",   0x004791E0, None,       0x4718),  # base is a pointer
    ("3DObjects", 0x00407B20, None,       None),    # three writes, BATTLE_MAP_3D
]
BATTLE_MAP_3D = [0x2D4, 0x26AC, 0x2AB98]
A_3D_HEADER_SIZE = 0x00407400   # mov eax, 0x2D4 / ret

FIXED_PREFIX = 0x105 + 0x2D0 + 0x44C + 0x1554          # 7541
LEV_FIXED = 0x360 + 0x4718 + 0x2D4 + 0x26AC + 0x2AB98  # 204688
SAV_FIXED = FIXED_PREFIX + LEV_FIXED + 0x00C + 0x06D + 0x01C

# --- filenames ----------------------------------------------------------------

A_BUILD_SAVE_NAME = 0x00449340
A_IS_SAVES2 = 0x0043BEE0
SAVES2_FLAG = 0x00509A40
SAVE_MODE = 0x0050C76C
A_SET_SAVE_MODE = 0x00448770
MODE_TEXT_TABLE = 0x00448410
EXPECTED_MODE_TEXT = [10, 11, 12, 13, 18]
EXPECTED_NAME_FORMATS = {
    "%s\\_%d_.sav",
    "%s\\PBM\\_%d_.sav",
    "%s\\Scenario\\_%d_.sav",
}
EXPECTED_DIR_NAMES = {"Saves", "Saves2"}

# --- directory ids -------------------------------------------------------------

DIR_JUMP_TABLE = 0x00463268
DIR_BUFFER_STRIDE = 0x105
DIR_BUFFER_BASE = 0x00512FF0
DIR_WORK_ID = 6
DIR_WORK_BUFFER = 0x0051360E
A_DIR_INIT = 0x00462EE0
EXPECTED_DIR_SUFFIXES = {
    0: "Graphics\\", 1: "Fonts\\", 2: "Temp\\", 3: "Misc\\", 4: "Libs\\",
    5: "Data\\", 6: "Work\\", 8: "Waves\\", 9: "Missions\\",
    10: "WorldSet\\", 11: "WorldDesc\\", 12: "CHData\\", 13: "Video\\",
    14: "Briefing\\",
}
DIR_ROOT_ONLY_ID = 7

# --- GameControl fields --------------------------------------------------------

GC_BASE = 0x00509D18
GC_PASSWORDS = 0x00509E83          # +0x16B
GC_PASSWORD_END = 0x00509EE7       # +0x1CF, the loop bound
GC_PASSWORD_STRIDE = 25
GC_PASSWORD_SLOTS = 4
A_PASSWORD_FLIP = 0x0043BCC0
A_GET_PASSWORD = 0x0043B650
PASSWORD_SENTINEL = "INVALID_PASSWORD"

GC_VERSION = 0x00509EEA            # +0x1D2
GC_MAX_PLAYER = 0x00509E30         # +0x118
GC_CUR_PLAYER = 0x00509E32         # +0x11A
GC_GAME_MODE = 0x00509EE8          # +0x1D0
GC_SCOREBOARD = 0x00509F48         # +0x230
GC_SCOREBOARD_STRIDE = 40
GC_SCOREBOARD_SLOTS = 4
RUNNING_BUILD = 0x00522ED0
VERSION_GATE_MIN = 150

# --- slot directory ------------------------------------------------------------

SLOT_BASE = 0x0050C778
SLOT_STRIDE = 0x84
SLOT_SCAN_END = 0x0050D6F0
SLOT_SCAN_COUNT = 30
A_SCAN_SLOTS = 0x004488B0
A_GET_COMMENT = 0x00448A30
SLOT_ACCESSOR_MAX = 39

# --- unit pool -----------------------------------------------------------------

POOL_BASE = 0x0051F2A0
A_INIT_POOL = 0x00478600
POOL_RECORD = 0x5B
POOL_ROW_SLOTS = 31
POOL_USABLE_SLOTS = 30
POOL_ROWS = 5
POOL_END = 0x005229B9

# --- LCL variable bank ---------------------------------------------------------

LCL_BASE = 0x0050B850
A_LCL_CLEAR = 0x0043FC70
LCL_ENTRIES = 28


class Checker:
    """Accumulates pass/fail results so one bad category does not hide the rest."""

    def __init__(self, pe: PEFile) -> None:
        self.pe = pe
        base, _vsize, raw, rawsize = pe.section(".text")
        self.text_base = base
        self.text = pe.data[raw:raw + rawsize]
        self.results: list[tuple[bool, str, str]] = []
        self._targets: list[int] | None = None

    # --- machine-code helpers --------------------------------------------------

    def code(self, va: int, n: int) -> bytes:
        off = va - self.text_base
        if off < 0 or off + n > len(self.text):
            raise PEError(f"{va:#010x} is outside .text")
        return self.text[off:off + n]

    def call_target(self, va: int) -> int | None:
        """Target of the ``call rel32`` at *va*, or ``None`` if that is not one."""
        b = self.code(va, 5)
        if b[0] != 0xE8:
            return None
        return va + 5 + struct.unpack_from("<i", b, 1)[0]

    def calls_in(self, start: int, end: int) -> list[tuple[int, int]]:
        """Every ``call rel32`` in ``[start, end)`` as ``(site, target)``."""
        out = []
        for va in range(start, end - 4):
            t = self.call_target(va)
            if t is not None and self.text_base <= t < self.text_base + len(self.text):
                out.append((va, t))
        return out

    def imm_sites(self, value: int) -> list[int]:
        """Every ``.text`` offset whose four bytes equal *value*."""
        needle = struct.pack("<I", value)
        out, i = [], 0
        while True:
            i = self.text.find(needle, i)
            if i < 0:
                return out
            out.append(self.text_base + i)
            i += 1

    def call_targets(self) -> list[int]:
        """Every address ``.text`` calls, sorted.  Cached; this is the slow scan."""
        if self._targets is None:
            lo, hi = self.text_base, self.text_base + len(self.text)
            seen = set()
            for i in range(len(self.text) - 4):
                if self.text[i] != 0xE8:
                    continue
                t = lo + i + 5 + struct.unpack_from("<i", self.text, i + 1)[0]
                if not lo <= t < hi:
                    continue
                # The scan is not instruction-aligned, so an 0xE8 byte inside a
                # longer instruction yields a plausible-looking target.  Every
                # real function here starts after padding or a return, which
                # throws those out.
                if t > lo and self.text[t - lo - 1] in (0x90, 0xCC, 0xC3):
                    seen.add(t)
            self._targets = sorted(seen)
        return self._targets

    def function_span(self, start: int, limit: int = 0x400) -> int:
        """End of the routine at *start*: the next address anything calls.

        Scanning forward for a ``ret`` followed by NOP padding does not work
        here -- MSVC pads only to the next 16-byte boundary, which is sometimes
        a single NOP, and a ``C3`` byte inside a longer instruction reads as a
        ``ret``.  The next call target is exact for every routine in these
        chains, because each of them is called from somewhere.
        """
        targets = self.call_targets()
        i = bisect.bisect_right(targets, start)
        if i < len(targets):
            return min(targets[i], start + limit)
        return start + limit

    def push_imm_before(self, call_site: int, lookback: int = 40) -> list[int]:
        """The ``push imm`` operands immediately preceding a call, in push order.

        Both forms count -- ``68 imm32`` and ``6A imm8`` -- because a block
        size below 128 is encoded short (``push 0xc`` for ProgramState).  The
        file handle always arrives in a register and never shows up here.
        """
        start = max(self.text_base, call_site - lookback)
        blob = self.code(start, call_site - start)
        out = []
        i = 0
        while i < len(blob):
            if blob[i] == 0x68 and i + 5 <= len(blob):
                out.append(struct.unpack_from("<I", blob, i + 1)[0])
                i += 5
            elif blob[i] == 0x6A and i + 2 <= len(blob):
                out.append(blob[i + 1])
                i += 2
            else:
                i += 1
        return out

    def trace_names_in(self, start: int, end: int) -> list[str]:
        """Names pushed to the CHECK() reporter inside ``[start, end)``, in order."""
        names = []
        for site, target in self.calls_in(start, end):
            if target != A_TRACE:
                continue
            for value in self.push_imm_before(site, lookback=24):
                s = self.pe.cstring(value, limit=64)
                if s and s.isascii() and s[:1].isalpha() and "\\" not in s:
                    names.append(s)
        return names

    def io_call_args(self, func: int, io: int) -> tuple[int, int] | None:
        """``(buffer, size)`` of the first ``aWriteFile``/``aLoadFile`` in *func*.

        Returns ``None`` when the call passes them in registers, which is how
        every run-time-sized block is written.
        """
        end = self.function_span(func)
        for site, target in self.calls_in(func, end):
            if target != io:
                continue
            pushes = self.push_imm_before(site)
            if len(pushes) >= 2:
                return pushes[-1], pushes[-2]   # push size; push buf; push h
            return None
        return None

    # --- result plumbing -------------------------------------------------------

    def check(self, name: str, ok: bool, detail: str) -> None:
        self.results.append((bool(ok), name, detail))

    def expect(self, name: str, got, want, fmt=str) -> None:
        self.check(name, got == want, f"{fmt(got)} (expected {fmt(want)})")


def hexs(v) -> str:
    if isinstance(v, int):
        return f"{v:#x}"
    if isinstance(v, (list, tuple)):
        return "[" + " ".join(hexs(x) for x in v) + "]"
    return str(v)


# --- the individual categories ------------------------------------------------

def check_chain(c: Checker, label: str, func: int, io: int, chain) -> None:
    """The nine blocks are called in order, and each writes what docs/11 says."""
    end = c.function_span(func, limit=0x600)
    names = c.trace_names_in(func, end)
    expected = [n for n, *_ in chain]
    # aSaveGame's first guarded call is aOpenFile / aLoadGame's is
    # aOpenExistingFileHardDriveOnly, so drop everything before the first block.
    verb = "Save" if io == A_WRITE_FILE else "Load"
    want = [("l" if n == "MissionObjectives" else "a") + verb + n for n in expected]
    if verb == "Load":
        # aLoadGame reaches block 1 through aLoadGameComment -- the same
        # routine the save/load screen uses to list the slots.
        want[0] = "aLoadGameComment"
    ordered = [n for n in names if n in set(want)]
    c.expect(f"{label}.order", ordered, want, fmt=lambda v: " ".join(v))

    for name, writer, addr, size in chain:
        if addr is None:
            continue
        args = c.io_call_args(writer, io)
        c.expect(f"{label}.{name}", args, (addr, size), fmt=hexs)


def check_symmetry(c: Checker) -> None:
    """Writer and loader must agree on every fixed block, or a save cannot load."""
    bad = []
    for (n1, _w, a1, s1), (n2, _l, a2, s2) in zip(SAVE_CHAIN, LOAD_CHAIN):
        if (n1, a1, s1) != (n2, a2, s2):
            bad.append(n1)
    c.check("chain.symmetry", not bad, f"{len(SAVE_CHAIN)} blocks, mismatched: {bad}")


def check_battle_map(c: Checker) -> None:
    end = c.function_span(A_SAVE_BATTLE_MAP, limit=0x200)
    names = c.trace_names_in(A_SAVE_BATTLE_MAP, end)
    want = ["aWriteFile", "aSaveCtrlMap", "aSaveUnitMap", "aSave3DObjects"]
    c.expect("battlemap.order", names, want, fmt=lambda v: " ".join(v))

    hdr_name, _w, hdr_addr, hdr_size = BATTLE_MAP_BLOCKS[0]
    c.expect(f"battlemap.{hdr_name}",
             c.io_call_args(A_SAVE_BATTLE_MAP, A_WRITE_FILE),
             (hdr_addr, hdr_size), fmt=hexs)

    # aSaveUnitMap pushes the size but takes the buffer from an accessor.
    um_writer, um_size = BATTLE_MAP_BLOCKS[2][1], BATTLE_MAP_BLOCKS[2][3]
    unitmap = c.push_imm_before(
        next(s for s, t in c.calls_in(um_writer, c.function_span(um_writer))
             if t == A_WRITE_FILE))
    c.expect("battlemap.UnitMap", unitmap[0] if unitmap else None, um_size, fmt=hexs)

    # aSave3DObjects writes three blocks.  Only the last two sizes are
    # immediates; the first is returned by a constant-folded accessor, which is
    # why it has to be read out of that function instead.
    end3d = c.function_span(0x00407B20, limit=0x200)
    writes = [s for s, t in c.calls_in(0x00407B20, end3d) if t == A_WRITE_FILE]
    c.expect("battlemap.3d_writes", len(writes), 3, fmt=str)
    header_size = struct.unpack_from("<I", c.code(A_3D_HEADER_SIZE, 5), 1)[0]
    c.expect("battlemap.3d_header", header_size, BATTLE_MAP_3D[0], fmt=hexs)
    blob3d = c.code(0x00407B20, end3d - 0x00407B20)
    c.check("battlemap.3d_blocks",
            all(struct.pack("<I", n) in blob3d for n in BATTLE_MAP_3D[1:]),
            hexs(BATTLE_MAP_3D))

    # The ctrl map is 23 bytes per cell: (n*24) - n, assembled as lea/shl/sub.
    blob = c.code(0x00430FB0, 0x20)
    pattern = bytes.fromhex("8d0c40c1e103")   # lea ecx,[eax+eax*2]; shl ecx,3
    c.check("battlemap.ctrlmap_stride",
            pattern in blob and b"\x2b\xc8" in blob,      # sub ecx, eax
            "23 = n*24 - n computed inline")


def check_size_identity(c: Checker) -> None:
    c.expect("size.prefix", FIXED_PREFIX, 7541, fmt=str)
    c.expect("size.lev_fixed", LEV_FIXED, 864 + 203824, fmt=str)
    c.expect("size.total_fixed", SAV_FIXED, 212378, fmt=str)


def check_filenames(c: Checker) -> None:
    end = c.function_span(A_BUILD_SAVE_NAME, limit=0x100)
    seen = set()
    for va in range(A_BUILD_SAVE_NAME, end - 4):
        if c.code(va, 1) != b"\x68":
            continue
        s = c.pe.cstring(struct.unpack_from("<I", c.code(va, 5), 1)[0], limit=64)
        if s:
            seen.add(s)
    c.check("name.formats", EXPECTED_NAME_FORMATS <= seen,
            f"{sorted(EXPECTED_NAME_FORMATS & seen)}")
    c.check("name.dirs", EXPECTED_DIR_NAMES <= seen, f"{sorted(EXPECTED_DIR_NAMES & seen)}")

    # aIsSaves2 reads one global; that global has exactly one writer.
    c.expect("name.saves2_getter",
             c.code(A_IS_SAVES2, 6), b"\xa1" + struct.pack("<I", SAVES2_FLAG) + b"\xc3",
             fmt=lambda v: v.hex())
    writers = [s for s in c.imm_sites(SAVES2_FLAG)
               if c.code(s - 1, 1) == b"\xa3"]     # mov [imm32], eax
    c.expect("name.saves2_writers", len(writers), 1, fmt=str)

    # The save mode likewise has a single setter.
    setters = [s for s in c.imm_sites(SAVE_MODE) if c.code(s - 1, 1) == b"\xa3"]
    c.expect("name.mode_writers", len(setters), 1, fmt=str)
    c.check("name.mode_setter", A_SET_SAVE_MODE < setters[0] < A_SET_SAVE_MODE + 0x10,
            f"only writer at {setters[0]:#x}, inside aSetSaveMode")


def check_mode_texts(c: Checker) -> None:
    """Mode -> GUI text id, and the ids against Txtmod_f.lcl."""
    targets = [c.pe.u32(MODE_TEXT_TABLE + 4 * i) for i in range(5)]
    ids = []
    for t in targets:
        b = c.code(t, 2)
        ids.append(b[1] if b[0] == 0x6A else None)   # push imm8
    c.expect("mode.text_ids", ids, EXPECTED_MODE_TEXT, fmt=str)


def check_dirs(c: Checker) -> None:
    table = [c.pe.u32(DIR_JUMP_TABLE + 4 * i) for i in range(15)]
    c.check("dir.table", all(0x00463150 < t < 0x00463268 for t in table),
            f"15 handlers in range")
    # Handler i does `mov edi, <buffer>`; buffer i = base + i*0x105.
    buffers = []
    for t in table:
        blob = c.code(t, 16)
        i = blob.find(b"\xbf")
        buffers.append(struct.unpack_from("<I", blob, i + 1)[0] if i >= 0 else None)
    want = [DIR_BUFFER_BASE + i * DIR_BUFFER_STRIDE for i in range(15)]
    c.expect("dir.buffers", buffers, want, fmt=hexs)
    c.expect("dir.work_id", buffers[DIR_WORK_ID], DIR_WORK_BUFFER, fmt=hexs)

    # The initialiser pairs `mov edi, <literal>` with `mov edi, <buffer>`.
    end = c.function_span(A_DIR_INIT, limit=0x300)
    pairs, pending = {}, None
    for va in range(A_DIR_INIT, end - 4):
        if c.code(va, 1) != b"\xbf":
            continue
        value = struct.unpack_from("<I", c.code(va, 5), 1)[0]
        if value in want:
            if pending is not None:
                pairs[want.index(value)] = pending
                pending = None
        else:
            s = c.pe.cstring(value, limit=32)
            if s and s.endswith("\\"):
                pending = s
    c.expect("dir.suffixes", pairs, EXPECTED_DIR_SUFFIXES, fmt=str)
    c.check("dir.root_only", DIR_ROOT_ONLY_ID not in pairs,
            f"id {DIR_ROOT_ONLY_ID} is never appended to")


def check_passwords(c: Checker) -> None:
    end = c.function_span(A_PASSWORD_FLIP, limit=0x80)
    blob = c.code(A_PASSWORD_FLIP, end - A_PASSWORD_FLIP)
    c.check("pw.base", struct.pack("<I", GC_PASSWORDS) in blob,
            f"{GC_PASSWORDS:#x} = GameControl+{GC_PASSWORDS - GC_BASE:#x}")
    c.check("pw.loop_end", struct.pack("<I", GC_PASSWORD_END) in blob,
            f"{GC_PASSWORD_END:#x} = base + {GC_PASSWORD_END - GC_PASSWORDS}")
    c.expect("pw.span", GC_PASSWORD_END - GC_PASSWORDS,
             GC_PASSWORD_SLOTS * GC_PASSWORD_STRIDE, fmt=str)
    # aGetPassword scales the player index by 25 as lea x5 then lea x5.
    acc = c.code(A_GET_PASSWORD, 0x30)
    scale = (b"\x8d\x04\xb6" in acc                      # lea eax,[esi+esi*4]
             and b"\x8d\x84\x80" + struct.pack("<I", GC_PASSWORDS) in acc)
    c.check("pw.stride", scale and GC_PASSWORD_STRIDE == 25,
            f"aGetPassword scales the index by 5*5 = {GC_PASSWORD_STRIDE}")
    c.check("pw.bound", bytes([0x83, 0xFE, GC_PASSWORD_SLOTS]) in acc,
            f"aGetPassword rejects player >= {GC_PASSWORD_SLOTS}")
    sentinel = [c.pe.cstring(struct.unpack_from("<I", blob, i + 1)[0], limit=32)
                for i in range(len(blob) - 4) if blob[i] == 0xBE]
    c.check("pw.sentinel", PASSWORD_SENTINEL in sentinel, f"{sentinel}")
    c.check("pw.involution", b"\xf6\xd1" in blob, "not cl -- the flip is its own inverse")
    # aSaveGameControl brackets the WriteFile with the flip.
    calls = [t for _s, t in c.calls_in(0x0043BC30, 0x0043BC80)]
    c.expect("pw.bracketed", calls.count(A_PASSWORD_FLIP), 2, fmt=str)


def check_version_gate(c: Checker) -> None:
    # aSaveGameControl stamps the running build into the blob.
    blob = c.code(0x0043BC30, 0x30)
    c.check("ver.stamp",
            struct.pack("<I", RUNNING_BUILD) in blob and struct.pack("<I", GC_VERSION) in blob,
            f"[{RUNNING_BUILD:#x}] -> GameControl+{GC_VERSION - GC_BASE:#x}")
    # aLoadGame compares it, gated on build >= 150.
    gate = c.code(0x00448F3E, 0x40)
    c.check("ver.gate",
            struct.pack("<I", RUNNING_BUILD) in gate and bytes([VERSION_GATE_MIN]) in gate[:12],
            f"build >= {VERSION_GATE_MIN}")
    getter = c.code(0x0043BEF0, 6)
    c.expect("ver.getter", getter[:1] + getter[1:5], b"\xa0" + struct.pack("<I", GC_VERSION),
             fmt=lambda v: v.hex())


def check_slots(c: Checker) -> None:
    blob = c.code(A_SCAN_SLOTS, 0x100)
    c.check("slot.base", struct.pack("<I", SLOT_BASE) in blob, f"{SLOT_BASE:#x}")
    c.check("slot.stride", struct.pack("<I", SLOT_STRIDE) in blob or
            bytes([0x81, 0xC3]) + struct.pack("<I", SLOT_STRIDE) in blob,
            f"{SLOT_STRIDE:#x}")
    c.check("slot.scan_end", struct.pack("<I", SLOT_SCAN_END) in blob, f"{SLOT_SCAN_END:#x}")
    c.expect("slot.count", (SLOT_SCAN_END - SLOT_BASE) // SLOT_STRIDE,
             SLOT_SCAN_COUNT, fmt=str)
    acc = c.code(A_GET_COMMENT, 0x20)
    c.check("slot.accessor_bound", bytes([0x83, 0xF8, SLOT_ACCESSOR_MAX]) in acc,
            f"aGetGameComment accepts 0..{SLOT_ACCESSOR_MAX}")


def check_unit_pool(c: Checker) -> None:
    blob = c.code(A_INIT_POOL, 0x30)
    row_stride = POOL_ROW_SLOTS * POOL_RECORD
    cleared = POOL_USABLE_SLOTS * POOL_RECORD
    c.check("pool.row_stride", struct.pack("<I", row_stride) in blob,
            f"{row_stride} = {POOL_ROW_SLOTS} * {POOL_RECORD}")
    c.check("pool.cleared_dwords", struct.pack("<I", cleared // 4) in blob,
            f"{cleared // 4} dwords + 1 word = {cleared} = "
            f"{POOL_USABLE_SLOTS} * {POOL_RECORD}")
    c.check("pool.end", struct.pack("<I", POOL_END) in blob, f"{POOL_END:#x}")
    c.expect("pool.rows", (POOL_END - POOL_BASE) // row_stride, POOL_ROWS, fmt=str)
    c.expect("pool.span", POOL_END - POOL_BASE, POOL_ROWS * row_stride, fmt=str)

    # The save writes 2*30 records, but the rows are 31 apart -- so the last
    # usable slot of player 1 falls outside the block.  docs/11 5.7.
    saved = next(sz for n, _w, _a, sz in SAVE_CHAIN if n == "UnitPool")
    c.expect("pool.saved_bytes", saved, 2 * POOL_USABLE_SLOTS * POOL_RECORD, fmt=str)
    last_player1 = (1 * POOL_ROW_SLOTS + POOL_USABLE_SLOTS - 1) * POOL_RECORD
    c.check("pool.truncation", last_player1 >= saved,
            f"player 1 slot {POOL_USABLE_SLOTS - 1} starts at {last_player1}, "
            f"block ends at {saved}")


def check_lcl_bank(c: Checker) -> None:
    blob = c.code(A_LCL_CLEAR, 0x14)
    c.check("lcl.base", struct.pack("<I", LCL_BASE) in blob, f"{LCL_BASE:#x}")
    c.check("lcl.entries", struct.pack("<I", LCL_ENTRIES) in blob,
            f"{LCL_ENTRIES} dwords cleared")
    saved = 0x6D
    c.check("lcl.truncation", saved < LCL_ENTRIES * 4,
            f"{saved} of {LCL_ENTRIES * 4} bytes saved; variable "
            f"{saved // 4} keeps {saved % 4} byte(s)")


def check_scoreboard(c: Checker) -> None:
    reset = c.code(0x0043B990, 0x60)
    fields = [GC_SCOREBOARD + 4 * i for i in range(9)]
    c.check("score.reset",
            all(struct.pack("<I", f) in reset for f in fields),
            f"9 dwords at GameControl+{GC_SCOREBOARD - GC_BASE:#x}")
    end = GC_SCOREBOARD + GC_SCOREBOARD_SLOTS * GC_SCOREBOARD_STRIDE
    c.expect("score.fits", end, GC_BASE + 0x2D0, fmt=hexs)


def check_text_module(c: Checker, root: Path) -> None:
    """The five mode labels must exist in Txtmod_f.lcl."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from lcl_decode import decode  # noqa: PLC0415

    path = root / "DATA" / "TXT" / "English" / "GUI" / "Txtmod_f.lcl"
    text = decode(path.read_bytes()).decode("latin-1")
    found = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("%:"):
            continue
        head, _, rest = line[2:].partition(",")
        if not head.isdigit():
            continue
        ident = int(head)
        if ident in EXPECTED_MODE_TEXT and '"' in rest:
            found[ident] = rest.split('"')[1]
    c.expect("mode.labels", sorted(found), sorted(EXPECTED_MODE_TEXT), fmt=str)
    c.check("mode.pbm", any("mail" in v.lower() for v in found.values()),
            f"{found}")


# --- driver --------------------------------------------------------------------

def run_checks(root: Path) -> int:
    exe = root / "Incubation.exe"
    if not exe.is_file():
        log.error("no Incubation.exe under %s -- nothing to check", root)
        return 1
    c = Checker(PEFile(exe))

    check_chain(c, "save", A_SAVE_GAME, A_WRITE_FILE, SAVE_CHAIN)
    check_chain(c, "load", A_LOAD_GAME, A_LOAD_FILE, LOAD_CHAIN)
    check_symmetry(c)
    check_battle_map(c)
    check_size_identity(c)
    check_filenames(c)
    check_mode_texts(c)
    check_dirs(c)
    check_passwords(c)
    check_version_gate(c)
    check_slots(c)
    check_unit_pool(c)
    check_lcl_bank(c)
    check_scoreboard(c)
    check_text_module(c, root)

    if not c.results:
        log.error("no checks ran")
        return 1
    failed = 0
    for ok, name, detail in c.results:
        print(f"  {'OK ' if ok else 'FAIL'} {name:<26} {detail}")
        failed += not ok
    print(f"{len(c.results) - failed}/{len(c.results)} checks passed")
    return 1 if failed else 0


def print_layout() -> None:
    print(f"{'offset':>8}  {'size':>8}  block")
    off = 0
    for name, _w, _a, size in SAVE_CHAIN:
        if size is None:
            print(f"{off:>8}  {'864+23*W*H+203824':>8}  {name}  (a complete .lev image)")
            off += LEV_FIXED  # plus 23*W*H, which the header supplies
            continue
        print(f"{off:>8}  {size:>8}  {name}")
        off += size
    print(f"\nsav_size = {SAV_FIXED} + 23 * width * height")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", metavar="GAME_ROOT", type=Path,
                    help="verify the layout against Incubation.exe")
    ap.add_argument("--layout", action="store_true",
                    help="print the documented block layout and exit")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")
    if args.layout:
        print_layout()
        return 0
    if args.check:
        return run_checks(args.check)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())

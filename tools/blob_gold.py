#!/usr/bin/env python3
"""Native capture of the blob **creators** -- ``docs/28`` §7.6, and the one
part of the effect layer no static reading reaches.

``docs/28`` §8.1's three weapon switches say *which* creator a shot runs and
``blob_tables.py`` extracts, for every one of the 116 constructor calls inside
them, the class, the update kind, the literal lifetime, the model and the atlas
tile.  What none of that gives is the **creators' own argument arithmetic**:
where each one places its blob and what velocity it hands it.  Those thirty
functions read the control map, the symbol objects and the unit map through
the five helpers ``docs/28`` §12.1 once recorded as *not natively validated*,
so transcribing them statically would have produced trajectories that look
authoritative and could not be checked.  (Those five are measured now, by this
tool's own ``hooks`` phase -- ``docs/28`` §7.4.2.  What the creators do *with*
their answers is still a thousand bytes of x86 apiece, which is why this
capture exists.)

This runs them instead.  Under ``tools/dbgcall``, inside a live
``Incubation.exe`` with a save loaded, each creator is called with controlled
tile arguments and the pool is read back record by record.  The capture **is**
the oracle: the fixture holds (creator, arguments) -> the records that appeared,
and ``--check`` replays it, so what a shot looks like stops being the remake's
invention.

    python3 tools/blob_gold.py --game-copy /path/to/copy \\
        --dbgcall /path/to/copy/dbgcall.exe
    python3 tools/blob_gold.py --check gog_incubation

**It shares one session with the other two gold tools** and imports
``run_plan`` and the capture constants from :mod:`movemap_gold` rather than
copying them.  The game copy must hold ``tests/fixtures/saves/_6_.sav`` staged
as ``Work/Saves2/_6_.sav``, and must not be inside this repository.

**No ``--code``.**  On this host an injected executable page makes
``Incubation.exe`` fault before the anchor, ten attempts out of ten -- the same
result ``ai_gold.py`` records.  The pool base is therefore reached the way the
engine reaches it: ``aGetMemory`` writes a *handle*, not a pointer, and the
block address lives in the memory manager's own table.  Both the constructor
``0x00420950`` and ``aDrawZoomBlobs`` do exactly this dance, which is what
settles handle-versus-pointer:

    eax = [0x004FE638]            ; the handle
    esi = [0x0050DE54 + eax*74]   ; the block

so a plan reads ``[0x0050DE54 + 74*handle]`` and never needs a heap address of
its own.  Two independent confirmations are taken every run: the handle itself,
and ``aResetBlobs``'s return value, which is the block's end after it has
walked 450 records of 88 bytes.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import blob_tables as tables                                    # noqa: E402
import movemap_gold as gold                                     # noqa: E402

LOG = logging.getLogger("blob_gold")

FIXTURE = Path("tests/fixtures/blob/cases_native.json")
SCHEMA = "incubation.blob-native/1"

# -- the engine's own addresses --------------------------------------------

#: ``aResetBlobs`` -- zeroes every record's in-use word, all 450 of them, and
#: returns the block's end.  Called before every creator so the records a
#: creator makes are the pool's first, and the read is bounded.
RESET_BLOBS = 0x0041DEC0
#: ``aGetMemory``'s out-parameter for the pool: a **handle**, not a pointer.
POOL_HANDLE = 0x004FE638
#: The memory manager's table, and its entry stride.  Recovered from the two
#: routines that address it, and confirmed at capture time against
#: ``aResetBlobs``'s own return value.
POOL_TABLE = 0x0050DE54
POOL_TABLE_STRIDE = 74
#: ``aRandom``'s seed (``docs/22`` §3, ``inclib/rng.ARandom``): a **qword**
#: double, read with ``fld`` and written with ``fst``.  Read either side of a
#: creator's call, it turns "the velocities are random" into a number: the
#: seed advance names how many draws the creator took, and the draws
#: themselves are then the generator's, replayable in Python.
ARANDOM_SEED = 0x00514078
#: **The other stream, and the one that matters here.**  ``0x004638E0`` is
#: ``aRandom``'s body byte for byte -- same multiplier, same modulus, same x87
#: sequence -- over a **different seed**, and without the call counter and
#: running sum ``aRandom`` keeps at ``0x00514080`` / ``0x00514084``.  The
#: creators draw from this one, which is why reading ``aRandom``'s seed either
#: side of a creator showed no movement at all.  372 call sites reach it
#: against ``aRandom``'s 32.
ARANDOM2 = 0x004638E0
ARANDOM2_SEED = 0x00514070
ARANDOM_SEED_BYTES = 8
#: How far the draw-count recovery iterates before giving up.  A creator that
#: made twelve records cannot plausibly have drawn hundreds of times, and an
#: unbounded search on a seed pair that does not connect would not terminate.
SEED_SEARCH_LIMIT = 4096

#: ``docs/28`` §7.1 -- 450 records of 88 bytes, plus one record of slack.
POOL_RECORDS = 450
RECORD_BYTES = 0x58

#: How many records a creator's call is read back.  The most any single arm
#: makes is well under this, and the pool is reset first, so the answer is
#: always in the first few slots.
READ_RECORDS = 12

# -- what to call them with -------------------------------------------------

#: A creator's first two arguments are tile coordinates: `0x00426F90`'s open
#: with `aGetCtrlMapElementPtr(arg2, arg1)`, and every other one this reaches
#: begins the same way.  What the remaining arguments mean is *not* claimed --
#: they are supplied as a second tile and then zeroes, and the capture records
#: what came out.
FILL_ARGUMENT = 0

#: How many creators go into one plan.  **One**, and the reasoning is worth
#: keeping because the first version of it was wrong.
#:
#: With five, the capture came back holding creators 1-5, 11-15 and 21-25 --
#: groups 0, 2 and 4 entire, groups 1, 3 and 5 empty, and two further
#: invocations of ten attempts each added nothing.  Landing on group
#: boundaries three times over looked like a *faulting creator* taking its
#: whole process down, and this comment said so.
#:
#: It is not, and the alignment is not even an observation.  What the log says
#: when a plan fails is `exception 0xc0000005` inside a Wine system DLL or a
#: clean `Target exited before any breakpoint was hit`, **before the anchor**
#: -- before a single line of the plan has run and whatever the plan contains.
#: `--probe-startup 16` measures the rate directly: two of sixteen identical
#: single-attempt runs reached the anchor, with no period in the failures.
#:
#: So the **loss unit is the group**, and any loss is therefore a whole group:
#: "aligned with group boundaries" is a tautology, not a finding.  What is left
#: is three of six groups losing all ten attempts, which at that rate happens
#: to about a quarter of groups.  `docs/91` §1.1 has the sequence.
#:
#: One creator per plan is still the right size, for the reason that survives
#: either explanation: a plan that dies takes down every creator sharing its
#: process, so five per plan turns one bad start into a fifth of the capture
#: while one per plan turns it into one retryable creator.
GROUP_SIZE = 1


# -- the five service hooks -------------------------------------------------
#
# `docs/28` §12.1 lists five routines an update **arm** reaches outside its own
# 88-byte record and says their return data has never been measured.  The
# creator capture did not touch them: it sees the answer a creator got, not
# what the helper computed.  These phases call all five directly.
#
# The arity of each is its **callers'** `add esp, K`, the same reading
# `creator_arities` uses and for the same reason -- `--probe` cannot recover a
# `__cdecl` arity.  All five agree across every site that cleans up at all:
#
#     0x00403AA0   36 bytes   9 arguments
#     0x0046D400   40 bytes  10 arguments
#     0x004039A0   12 bytes   3 arguments
#     0x00405100   16 bytes   4 arguments
#     0x00477AE0    4 bytes   1 argument

#: Source and target to two 0..4095 angles.  **This is the one the remake's
#: `orient()` stands in for**, and the static reading already contradicts the
#: stand-in: the routine ends `sub eax, 0x400` and writes the result of a
#: two-argument engine helper, so its unit is the 4096-circle of `docs/70`,
#: not the 0..0xFFFF turn the adapter invented.
HOOK_ORIENT = 0x00403AA0
#: Source and target to three doubles -- the normalised direction, divided by
#: whichever of |dx| and |dy| is larger, with the third the vertical over the
#: 2D distance.  Straight-line and argument-pure.
HOOK_DIRECTION = 0x0046D400
#: A vector through the engine's rotation helper: `(vec3 dwords, three shorts,
#: out vec3)`.  It calls two runtime function pointers, so it is the one that
#: cannot be modelled without knowing what those point at.
HOOK_ROTATE = 0x004039A0
#: `(id, &x, &y, &z)` -- the object-position service.  Table at
#: `OBJECT_TABLE`, stride 77, gated on `+0x40`, delegating through `+0x45`.
HOOK_OBJECT_POSITION = 0x00405100
#: `(id)` -> the unit record's address, or 0 after a CHECK.  Table at
#: `UNIT_TABLE`, stride 91, alive byte at `+0x16`.
HOOK_UNIT_RECORD = 0x00477AE0

#: The bases the last two index, read so the strides above are measured rather
#: than derived from the disassembly alone.
OBJECT_TABLE = 0x004FA804
UNIT_TABLE = 0x005229C4
OBJECT_STRIDE = 77
OBJECT_GATE = 0x40
OBJECT_DELEGATE = 0x45
OBJECT_POSITION_FIELDS = (0x10, 0x14, 0x18)
UNIT_ALIVE = 0x16
#: The highest id either service accepts -- both compare against 200.
HOOK_ID_LIMIT = 200

#: The runtime function pointers `0x004039A0` and `0x00403AA0` call through.
#: They are **not** imports: `Incubation.exe`'s import table lives at
#: `0x525xxx` and these are ordinary globals filled in at start-up, so the
#: only way to learn what they point at is to look while the process is up.
#: Each is read as a pointer *and* as the first bytes of whatever it points
#: at, which is enough to identify the routine against a DLL's own code.
POINTER_GLOBALS = (0x004FA4E4, 0x004F84D4, 0x004F84D8, 0x004FA4DC, 0x004FA4E0)
#: How many bytes of each target are read back.
POINTER_PREVIEW = 32

#: Where the sweeps put the source point.  Not the origin and not a multiple
#: of the field size: a helper that quietly assumed either would still look
#: right from a sweep that used one.
HOOK_SOURCE = (12800, 9600, 1600)
#: The offsets from it.  Every axis sign, both diagonals, the two degenerate
#: cases the routines branch on (`dx == 0` and `dy == 0`), a zero vector, and
#: magnitudes from 1 to a whole map away -- the branch structure of
#: `0x0046D400` is entirely made of these comparisons.
HOOK_DELTAS = (
    (1000, 0, 0), (0, 1000, 0), (-1000, 0, 0), (0, -1000, 0),
    (1000, 1000, 0), (-1000, 1000, 0), (1000, -1000, 0), (-1000, -1000, 0),
    (3000, 1000, 500), (1000, 3000, -500), (-3000, 1000, 2000),
    (700, -2400, -1300), (0, 0, 1000), (0, 0, -1000), (0, 0, 0),
    (16000, 9000, 4000), (5, 3, 1), (1, 0, 0), (0, 1, 0), (-1, -1, -1),
)
#: `(vector, angles)` for the rotation helper.  The angles are in the same
#: 4096-circle; 0x88 is the literal `0x004228F0` writes into the third word
#: before it calls, so one case is the shipped one.
HOOK_ROTATIONS = (
    ((1000, 0, 0), (0, 0, 0)),
    ((1000, 0, 0), (0, 0, 1024)),
    ((1000, 0, 0), (0, 1024, 0)),
    ((1000, 0, 0), (1024, 0, 0)),
    ((0, 0, 1000), (2048, 0, 0)),
    ((1000, 500, 250), (100, 200, 300)),
    ((-700, 300, -900), (4000, 3000, 2000)),
    ((1000, 0, 0), (0, 0, 0x88)),
)
#: Object ids swept one by one, then coarsely to the limit.  A gap in the
#: dense part is a gated slot and is itself the measurement.
HOOK_DENSE_IDS = 50
HOOK_SPARSE_STEP = 10


def hook_object_ids() -> list[int]:
    """The object ids the sweep visits: dense, then coarse to the limit."""
    ids = list(range(HOOK_DENSE_IDS))
    ids += [i for i in range(HOOK_DENSE_IDS, HOOK_ID_LIMIT + 1,
                             HOOK_SPARSE_STEP)]
    return ids


def _hook_declarations() -> str:
    return "\n".join([
        f"__cdecl i32 hOrient(i32,i32,i32,i32,i32,i32,ptr,ptr,ptr)"
        f" = Incubation.exe+0x{HOOK_ORIENT - 0x400000:x}",
        f"__cdecl i32 hDirection(i32,i32,i32,i32,i32,i32,ptr,ptr,ptr,i32)"
        f" = Incubation.exe+0x{HOOK_DIRECTION - 0x400000:x}",
        f"__cdecl i32 hRotate(ptr,ptr,ptr)"
        f" = Incubation.exe+0x{HOOK_ROTATE - 0x400000:x}",
        f"__cdecl i32 hObjectPosition(i32,ptr,ptr,ptr)"
        f" = Incubation.exe+0x{HOOK_OBJECT_POSITION - 0x400000:x}",
    ])


def hooks_plan(units: list[dict[str, int]]) -> str:
    """Call all five services `docs/28` §12.1 leaves un-measured.

    One process, because none of them is destructive: the three geometry
    helpers write only into buffers this plan owns, and the two lookups do not
    write at all.  The save is still loaded, because the two lookups index
    tables that do not exist before it is.

    **The invalid ids are not swept.**  `0x00477AE0`'s out-of-range and
    dead-unit paths go through the engine's CHECK reporter, and a plan that
    puts a message box up never reaches its next line.  Those three branches
    are read statically instead -- they are literal comparisons against
    `0xFFFF` and 200 and a byte test, with nothing to measure.
    """
    lines = [
        "# The five service hooks of docs/28 12.1, called directly.",
        DECLARATIONS.rstrip("\n"),
        _hook_declarations(),
        "--buf oa:8",
        "--buf ob:8",
        "--buf oc:8",
        "--buf px:4",
        "--buf py:4",
        "--buf pz:4",
        "--buf rot:12",
    ]
    for index, (vector, angles) in enumerate(HOOK_ROTATIONS):
        raw = b"".join(v.to_bytes(4, "little", signed=True) for v in vector)
        ang = b"".join(a.to_bytes(2, "little", signed=True) for a in angles)
        lines.append(f"--blob rv{index}:{raw.hex()}")
        lines.append(f"--blob ra{index}:{ang.hex()}")
    lines += [
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
    ]
    # The runtime pointers, and enough of each target to name it later.
    reads = " ".join(f"--read 0x{g:x}:4" for g in POINTER_GLOBALS)
    previews = " ".join(f"--read [0x{g:x}]:{POINTER_PREVIEW}"
                        for g in POINTER_GLOBALS)
    lines.append(f"tables = aResetBlobs() {reads} {previews}"
                 f" --read 0x{OBJECT_TABLE:x}:4 --read 0x{UNIT_TABLE:x}:4")

    sx, sy, sz = HOOK_SOURCE
    for index, (dx, dy, dz) in enumerate(HOOK_DELTAS):
        target = (sx + dx, sy + dy, sz + dz)
        args = f"{sx},{sy},{sz},{target[0]},{target[1]},{target[2]}"
        lines.append(f"o{index} = hOrient({args},&oa,&ob,&oc)"
                     " --zero oa --zero ob --zero oc"
                     " --read &oa:8 --read &ob:8 --read &oc:8")
        for shift in (0, 1):
            lines.append(
                f"d{index}s{shift} = hDirection({args},&oa,&ob,&oc,{shift})"
                " --zero oa --zero ob --zero oc"
                " --read &oa:8 --read &ob:8 --read &oc:8")
    for index in range(len(HOOK_ROTATIONS)):
        lines.append(f"r{index} = hRotate(&rv{index},&ra{index},&rot)"
                     " --zero rot --read &rot:12")

    for object_id in hook_object_ids():
        lines.append(f"p{object_id} = hObjectPosition({object_id},&px,&py,&pz)"
                     " --zero px --zero py --zero pz"
                     " --read &px:4 --read &py:4 --read &pz:4")
    for unit in units:
        lines.append(f"u{unit['slot']} = aGetUnitMapElementPtr({unit['slot']})")
    return "\n".join(lines) + "\n"


def _entry_address(handle: int) -> int:
    return POOL_TABLE + POOL_TABLE_STRIDE * handle


def reachable_creators(root: str) -> list[int]:
    """The creators a shot can reach, from the two geometry weapon switches."""
    binary = tables.Binary(root)
    found: set[int] = set()
    for table, pinned in ((tables.MUZZLE_SWITCH, tables.WEAPON_MUZZLE),
                          (tables.IMPACT_SWITCH, tables.WEAPON_IMPACT)):
        for _weapon, (_arm, calls) in binary.weapon_effects(table, pinned).items():
            for _site, creator in calls:
                if creator is not None:
                    found.add(creator)
    return sorted(found)


def creator_arities(root: str) -> dict[int, int]:
    """``creator -> dword arguments``, from the **caller's** stack cleanup.

    The same reading ``blob_tables.py``'s `creators.arity_table` pins, kept
    here as a function because this tool needs the mapping before it can write
    a plan and the check there needs it to notice a change.

    ``--probe`` cannot answer this: the creators are ``__cdecl``, the caller
    cleans up, and the callee's ``ret`` pops nothing whatever the arity.  The
    arms that call them do clean up, and their ``add esp, K`` is exact.  Every
    creator below is called from more than one site in some cases and all sites
    agree, which is the check.
    """
    binary = tables.Binary(root)
    seen: dict[int, set[int]] = {}
    for table, pinned in ((tables.MUZZLE_SWITCH, tables.WEAPON_MUZZLE),
                          (tables.IMPACT_SWITCH, tables.WEAPON_IMPACT)):
        for _weapon, (_arm, calls) in binary.weapon_effects(table, pinned).items():
            for site, creator in calls:
                if creator is None:
                    continue
                seen.setdefault(creator, set()).add(_cleanup_dwords(binary, site))
    out: dict[int, int] = {}
    for creator, widths in sorted(seen.items()):
        if len(widths) != 1 or None in widths:
            raise SystemExit(
                f"0x{creator:08X}: call sites disagree about the arity "
                f"({sorted(w for w in widths if w is not None)})")
        out[creator] = widths.pop()
    return out


def _cleanup_dwords(binary: "tables.Binary", site: int) -> int | None:
    """``add esp, K`` right after the five-byte ``call rel32`` at *site*."""
    after = site + 5
    if binary.u8(after) == 0x83 and binary.u8(after + 1) == 0xC4:
        return binary.u8(after + 2) // 4
    if binary.u8(after) == 0x81 and binary.u8(after + 1) == 0xC4:
        return binary.pe.u32(after + 2) // 4
    return None


# --------------------------------------------------------------------------
# The plans
# --------------------------------------------------------------------------

DECLARATIONS = """\
__cdecl void aSetSaveMode(i32)              = Incubation.exe+0x48770
__cdecl i32  aLoadGame(i32)                 = Incubation.exe+0x48e60
__cdecl ptr  aGetUnitMapElementPtr(i32)     = Incubation.exe+0x77ae0
__cdecl ptr  aGetCtrlMapElementPtr(i32,i32) = Incubation.exe+0x2f730
__cdecl i32  aResetBlobs()                  = Incubation.exe+0x1dec0
"""


def state_plan() -> str:
    """Load the save, and read everything the later phases are checked against."""
    units = gold.UNIT_SLOTS * gold.UNIT_STRIDE
    cells = gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    return "\n".join([
        "# Phase 1: the pool's address, twice, the unit array the argument",
        "# tiles are chosen from, and the control map -- which is read for one",
        "# reason: the tiles the units stand on are all at height zero, and at",
        "# height zero an absolute z and a z measured from the floor are the",
        "# same number. The height probe needs a tile that is not.",
        DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        f"u0 = aGetUnitMapElementPtr(0) --read $u0:{units}",
        f"c0 = aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"handle = aResetBlobs() --read 0x{POOL_HANDLE:x}:4",
    ]) + "\n"


def creator_plan(handle: int, group: list[dict[str, Any]]) -> str:
    """Reset the pool, run one creator, read the records it left -- per creator."""
    entry = _entry_address(handle)
    lines = [
        "# The pool is reset before every creator, so its records are the",
        "# pool's first and the read is bounded. The reset's return value is",
        "# the block's end, which is the second reading of the base.",
        DECLARATIONS,
        "",
        "# **Every phase is its own process, so every phase loads the save.**",
        "# Without this the creators run against no map at all, take the",
        "# CHECK-abort path to a man, and come back with zero records -- which",
        "# is indistinguishable from a creator that legitimately refused.",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
    ]
    for item in group:
        creator = item["creator"]
        args = ", ".join(str(a) for a in item["args"])
        lines.append("")
        lines.append(f"# 0x{creator:08X}({args})")
        lines.append(f"__cdecl i32 c{creator:08X}({','.join('i32' for _ in item['args'])})"
                     f" = Incubation.exe+0x{creator - 0x400000:x}")
        # **The seed either side.**  `aRandom`'s global is a qword double and
        # the read happens *after* the call it is hung on, so the read on the
        # reset is the seed the creator started from and the read after the
        # creator is the seed it left.  Iterating the Lehmer step from the
        # first to the second recovers how many times the creator drew, and
        # therefore what it drew -- which is the whole of the velocity
        # question.  `--read` takes the address itself; brackets would
        # dereference it (`tools/dbgcall/README.md`).
        lines.append(f"end{creator:08X} = aResetBlobs()"
                     f" --read 0x{ARANDOM_SEED:x}:{ARANDOM_SEED_BYTES} --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}")
        lines.append(f"c{creator:08X}({args})")
        # **The read is hung on a call that touches nothing.** Hanging it on a
        # second `aResetBlobs()` wipes the pool before the read and every
        # creator comes back with zero records -- which looks exactly like the
        # CHECK-abort path and is not it. `aGetUnitMapElementPtr` is a pure
        # lookup and was already declared.
        lines.append(f"aGetUnitMapElementPtr(0) --read [0x{entry:x}]:"
                     f"{READ_RECORDS * RECORD_BYTES}"
                     f" --read 0x{ARANDOM_SEED:x}:{ARANDOM_SEED_BYTES} --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Reading the capture back
# --------------------------------------------------------------------------

def _hex_bytes(text: str) -> bytes:
    return bytes.fromhex(text.replace(" ", ""))


def parse_records(blob: bytes) -> list[dict[str, Any]]:
    """The live records at the front of the pool, as `docs/28` §7.2's fields."""
    import struct
    out: list[dict[str, Any]] = []
    for index in range(len(blob) // RECORD_BYTES):
        raw = blob[index * RECORD_BYTES:(index + 1) * RECORD_BYTES]
        if struct.unpack_from("<I", raw, 0x00)[0] == 0:
            break
        out.append({
            "slot": index,
            "model": struct.unpack_from("<i", raw, 0x0C)[0],
            "x": struct.unpack_from("<i", raw, 0x14)[0],
            "y": struct.unpack_from("<i", raw, 0x18)[0],
            "z": struct.unpack_from("<i", raw, 0x1C)[0],
            "rot_x": struct.unpack_from("<H", raw, 0x24)[0],
            "rot_y": struct.unpack_from("<H", raw, 0x26)[0],
            "rot_z": struct.unpack_from("<H", raw, 0x28)[0],
            "kind": raw[0x44],
            "life": raw[0x45],
            "vx": struct.unpack_from("<i", raw, 0x48)[0],
            "vy": struct.unpack_from("<i", raw, 0x4C)[0],
            "vz": struct.unpack_from("<i", raw, 0x50)[0],
            "aux": raw[0x54],
            "delay": raw[0x55],
            "class_id": raw[0x56],
        })
    return out


def units_from(rows: list[dict[str, Any]]) -> list[dict[str, int]]:
    """Every live unit's tile and player, from the phase-1 unit-array read."""
    blob = b""
    for row in rows:
        for key, text in (row.get("reads") or {}).items():
            if key.startswith("$u0"):
                blob = _hex_bytes(text)
    out: list[dict[str, int]] = []
    for slot in range(gold.UNIT_SLOTS):
        raw = blob[slot * gold.UNIT_STRIDE:(slot + 1) * gold.UNIT_STRIDE]
        if len(raw) < gold.UNIT_STRIDE or raw[gold.UNIT_NAME] == 0:
            continue
        out.append({"slot": slot, "x": raw[gold.UNIT_X], "y": raw[gold.UNIT_Y],
                    "player": raw[gold.UNIT_PLAYER],
                    "type": raw[gold.UNIT_TYPE]})
    return out


def heights_from(rows: list[dict[str, Any]]) -> list[int]:
    """Every cell's height, from the phase-1 control-map read.

    ``CELL_HEIGHT`` is a **signed dword**, which is how ``movemap_gold`` has
    always read it -- reading it as one byte here was silently keeping the low
    eight bits, so a tile at 8320 came back as 128 and the z probe would have
    compared its answer against a height that is not the map's.
    """
    import struct
    blob = b""
    for row in rows:
        for key, text in (row.get("reads") or {}).items():
            if key.startswith("$c0"):
                blob = _hex_bytes(text)
    out: list[int] = []
    for index in range(gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT):
        base = index * gold.CELL_STRIDE
        if base + gold.CELL_STRIDE > len(blob):
            out.append(0)
            continue
        out.append(struct.unpack_from("<i", blob, base + gold.CELL_HEIGHT)[0])
    return out


#: The C runtime's ``rand()``, through the import thunk ``docs/20`` §7.4
#: names -- the *other* generator, and the one left standing once the seed
#: reads showed that no creator touches ``aRandom``.  Called three times
#: either side of a creator, its outputs recover the LCG's state and therefore
#: how many times the creator drew from it, if it drew at all.
CRT_RAND_SLOT = 0x005255FC
RAND_DECL = f"__cdecl i32 rand() = [{CRT_RAND_SLOT:#x}]"
#: How many outputs bracket a call.  One fixes fifteen bits of the state, and
#: the search over the rest is what the other two settle.
RAND_PROBES = 3
#: How far the LCG is stepped looking for the post-call state.
RAND_SEARCH_LIMIT = 100000

#: ``memcpy`` through the game's own import thunk -- the byte writer
#: ``ai_gold`` established, and for the same reason: ``--code`` makes
#: ``Incubation.exe`` fault before the anchor on this host.
MEMCPY_SLOT = 0x00525634
MEMCPY_DECL = f"__cdecl ptr memcpy(ptr,ptr,i32) = [{MEMCPY_SLOT:#x}]"

#: ``docs/30`` §2.5 -- one map field, in world units.  Defined **once**: the
#: chained second definition this file used to carry further down shadowed it,
#: which is how a pinned constant stops being pinned.
FIELD_UNITS = 3200
#: What the z probe raises its tile by.
RAISED_HEIGHT = FIELD_UNITS


def raised_tile(state: dict[str, Any]) -> tuple[int, int] | None:
    """A tile whose height is **not** zero, kept as a sanity reading.

    The probe does not use it.  Every unit in this save stands at height zero
    -- and the creators that produce anything all want the tile's occupant --
    so "find a raised tile" and "find a tile a creator will act on" have an
    empty intersection here.  The probe **writes** the height instead, which
    is the better experiment anyway: one variable moves and the creator, its
    arguments and its occupant are the ones that already produced records.
    ``docs/93`` §11 settled the large-unit clearance the same way, by writing
    the ``size`` byte rather than hunting a mission for a large unit.
    """
    heights = state.get("heights") or []
    for index, height in enumerate(heights):
        if height:
            return index % gold.CAPTURE_WIDTH, index // gold.CAPTURE_WIDTH
    return None


def scatter_plan(handle: int, creator: int, args: list[int]) -> str:
    """One creator run **twice** in one process, bracketed by ``rand()``.

    The seed reads answered the question that was asked -- no creator advances
    ``aRandom`` -- and immediately raised the one behind it: a creator whose
    twelve velocities scatter has to be getting the scatter from somewhere.
    This asks the two questions that between them close it.  Calling the same
    creator twice with the pool reset in between says whether the scatter is
    *state* at all; the ``rand()`` outputs either side of each call say whether
    the state is the C runtime's, by recovering its LCG and counting how far
    the creator moved it.
    """
    entry = _entry_address(handle)
    call = ",".join("i32" for _ in args)
    body = ", ".join(str(a) for a in args)
    lines = [
        "# Is the scatter random, and if so whose random is it?",
        DECLARATIONS.rstrip("\n"),
        RAND_DECL,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        f"__cdecl i32 c{creator:08X}({call})"
        f" = Incubation.exe+0x{creator - 0x400000:x}",
    ]
    for round_index in range(2):
        for probe in range(RAND_PROBES):
            lines.append(f"r{round_index}p{probe} = rand()")
        lines.append(f"reset{round_index} = aResetBlobs()"
                     f" --read 0x{ARANDOM_SEED:x}:{ARANDOM_SEED_BYTES} --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}")
        lines.append(f"c{creator:08X}({body})")
        lines.append(f"aGetUnitMapElementPtr(0) --read [0x{entry:x}]:"
                     f"{READ_RECORDS * RECORD_BYTES}"
                     f" --read 0x{ARANDOM_SEED:x}:{ARANDOM_SEED_BYTES} --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}")
    for probe in range(RAND_PROBES):
        lines.append(f"r2p{probe} = rand()")
    return "\n".join(lines) + "\n"


def crt_state(outputs: list[int]) -> int | None:
    """The MSVC LCG state that produced *outputs* consecutively.

    ``rand()`` is ``state = state * 214013 + 2531011`` returning
    ``(state >> 16) & 0x7FFF`` (``inclib.rng.CRandom``), so one output fixes
    fifteen bits and the remaining seventeen are brute-forced against the
    next.  The state returned is the one **after** the last output.
    """
    from inclib.rng import CRandom
    if len(outputs) < 2:
        return None
    # Sixteen unknown bits.  The output is bits 16..30, and the top bit is
    # **unobservable**: two states differing by 2^31 differ by 2^31 forever
    # (214013 is odd, so the carry never leaves bit 31) and never in any
    # output.  So the state recovered here is a representative of that pair,
    # which is all :func:`crt_advance` needs -- it was checked by recovering a
    # known generator and stepping it.
    for low in range(1 << 16):
        state = (outputs[0] << 16) | low
        candidate = state
        for want in outputs[1:]:
            candidate = (candidate * CRandom.MULTIPLIER
                         + CRandom.INCREMENT) % CRandom.MODULUS
            if (candidate >> 16) & 0x7FFF != want:
                break
        else:
            return candidate
    return None


def crt_advance(before: int, outputs: list[int]) -> int | None:
    """How many ``rand()`` steps carry *before* to the first of *outputs*."""
    from inclib.rng import CRandom
    state = before
    for step in range(1, RAND_SEARCH_LIMIT + 1):
        state = (state * CRandom.MULTIPLIER
                 + CRandom.INCREMENT) % CRandom.MODULUS
        if (state >> 16) & 0x7FFF == outputs[0]:
            probe = state
            for want in outputs[1:]:
                probe = (probe * CRandom.MULTIPLIER
                         + CRandom.INCREMENT) % CRandom.MODULUS
                if (probe >> 16) & 0x7FFF != want:
                    break
            else:
                return step - 1
    return None


def raised_plan(handle: int, creator: int, args: list[int],
                height: int) -> str:
    """The z probe: the same creator, the same tile, one raised floor.

    ``z`` is either the creator's own constant or that constant measured from
    the floor, and on a map whose every occupied tile is at height zero the
    two are the same number.  This raises the floor of the tile the creator
    already produced records on, by writing the control map's height dword
    through the game's imported ``memcpy``, and calls it again unchanged.  No
    restore: every phase is its own process and loads the save itself.
    """
    entry = _entry_address(handle)
    tile = (args[0], args[1])
    index = (tile[1] * gold.CAPTURE_WIDTH + tile[0]) * gold.CELL_STRIDE
    raw = height.to_bytes(4, "little", signed=True).hex()
    call = ",".join("i32" for _ in args)
    return "\n".join([
        "# The z probe. One variable moves: the height dword of the tile the",
        "# creator is given. Read back before the call, so a write that did",
        "# not land is a visible result rather than a silent null answer.",
        DECLARATIONS.rstrip("\n"),
        MEMCPY_DECL,
        f"--blob rh:{raw}",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "c0 = aGetCtrlMapElementPtr(0,0)",
        f"memcpy($c0+0x{index + gold.CELL_HEIGHT:x}, &rh, 4)",
        f"aGetCtrlMapElementPtr({tile[0]},{tile[1]})"
        f" --read $c0+0x{index:x}:{gold.CELL_STRIDE}",
        "",
        f"__cdecl i32 c{creator:08X}({call}) = Incubation.exe+0x{creator - 0x400000:x}",
        f"end{creator:08X} = aResetBlobs()"
        f" --read 0x{ARANDOM_SEED:x}:{ARANDOM_SEED_BYTES} --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}",
        f"c{creator:08X}({', '.join(str(a) for a in args)})",
        f"aGetUnitMapElementPtr(0) --read [0x{entry:x}]:"
        f"{READ_RECORDS * RECORD_BYTES}"
        f" --read 0x{ARANDOM_SEED:x}:{ARANDOM_SEED_BYTES} --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}",
    ]) + "\n"


def argument_vector(arity: int, source: tuple[int, int],
                    target: tuple[int, int]) -> list[int]:
    """`(x, y, x2, y2, 0 …)`, cut to the creator's arity."""
    full = [source[0], source[1], target[0], target[1]]
    while len(full) < arity:
        full.append(FILL_ARGUMENT)
    return full[:arity]


# --------------------------------------------------------------------------
# Capture
# --------------------------------------------------------------------------

def capture(root: str, game_copy: Path, dbgcall: Path, out: Path,
            attempts: int) -> int:
    document: dict[str, Any] = {}
    if out.is_file():
        try:
            document = json.loads(out.read_text())
        except ValueError:
            document = {}
    if document.get("schema") != SCHEMA:
        document = {"schema": SCHEMA, "phases": {}}
    phases: dict[str, Any] = document.setdefault("phases", {})

    # **The predicate is what the phase holds, not a schema number.**  The
    # first capture predated the control-map read, so its `state` had no
    # `heights`; `raised_tile` then returned `None` and the z probe was
    # skipped in silence -- which was written up as "Wine did not reach the
    # anchor" and was nothing of the kind.  Bumping SCHEMA would have found it
    # and *discarded the whole capture* to do so, since a schema mismatch
    # resets `phases`.  Asking whether the phase carries the field re-takes
    # exactly the phase that is short.
    if "heights" not in phases.get("state", {}):
        rows = gold.run_plan(game_copy, dbgcall, state_plan(), "blob_state",
                             attempts=attempts)
        handle = _read_dword(rows, f"0x{POOL_HANDLE:x}")
        end = _eax_of(rows, "aResetBlobs")
        phases["state"] = {
            "handle": handle,
            "reset_end": end,
            "base": end - POOL_RECORDS * RECORD_BYTES,
            "units": units_from(rows),
            "heights": heights_from(rows),
        }
        _save(out, document)
    state = phases["state"]
    LOG.info("pool handle %d, base 0x%08X", state["handle"], state["base"])

    units = state["units"]
    if len(units) < 2:
        raise SystemExit("the save holds fewer than two units to aim between")
    source = (units[0]["x"], units[0]["y"])
    target = (units[1]["x"], units[1]["y"])

    # **The five service hooks**, `docs/28` §12.1's open item.  Its own phase
    # and taken before the creators, because it is the cheap one: no writes,
    # no reset, one process, and a failure costs one retry rather than a
    # creator.
    if "hooks" not in phases:
        try:
            rows = gold.run_plan(game_copy, dbgcall, hooks_plan(units),
                                 "blob_hooks", attempts=attempts)
            phases["hooks"] = parse_hooks(rows)
            phases["hooks"]["source"] = list(HOOK_SOURCE)
            phases["hooks"]["deltas"] = [list(d) for d in HOOK_DELTAS]
            phases["hooks"]["unit_slots"] = [u["slot"] for u in units]
            phases["hooks"]["rotations"] = [[list(v), list(a)]
                                            for v, a in HOOK_ROTATIONS]
            phases["hooks"]["object_ids"] = hook_object_ids()
            _save(out, document)
        except gold.CaptureError as err:
            document.setdefault("failures", {})["hooks"] = str(err)
            LOG.warning("blob_hooks: %s", err)
            _save(out, document)

    arities = creator_arities(root)
    # A phase written before the seed reads existed is re-taken: it holds the
    # records but cannot answer the velocity question, and merging is the
    # whole point of writing phases as they land.
    wanted = [c for c in reachable_creators(root)
              if "seed2_after" not in phases.get(f"0x{c:08X}", {})]
    failures: dict[str, str] = document.setdefault("failures", {})
    LOG.info("%d creator(s) still to capture", len(wanted))
    for start in range(0, len(wanted), GROUP_SIZE):
        group = [{"creator": c,
                  "args": argument_vector(arities[c], source, target)}
                 for c in wanted[start:start + GROUP_SIZE]]
        name = "blob_%02d" % (start // GROUP_SIZE)
        try:
            rows = gold.run_plan(game_copy, dbgcall,
                                 creator_plan(state["handle"], group), name,
                                 attempts=attempts)
        except gold.CaptureError as err:
            # **A creator that takes its plan down is a result.**  It is kept
            # out of `phases`, so a re-run still retries it, and recorded here
            # with what the harness said -- which is what distinguishes "this
            # creator faults on these arguments" from "zero records because it
            # refused the tile".
            for item in group:
                failures[f"0x{item['creator']:08X}"] = str(err)
            LOG.warning("%s: %s", name, err)
            _save(out, document)
            continue
        seeds = _seeds_in_order(rows)
        for index, (item, records) in enumerate(
                zip(group, _reads_in_order(rows))):
            phase: dict[str, Any] = {
                "args": item["args"],
                "records": parse_records(records),
            }
            if len(seeds) >= 2 * (index + 1):
                (phase["seed_before"], phase["seed2_before"]) = seeds[2 * index]
                (phase["seed_after"], phase["seed2_after"]) = seeds[2 * index + 1]
            phases[f"0x{item['creator']:08X}"] = phase
            failures.pop(f"0x{item['creator']:08X}", None)
        _save(out, document)
    # The z probe: the creator that produced records, called again on the
    # same tile with the floor raised under it.  Its own phase, so a re-run
    # can add it to a capture that predates it.
    if "raised" not in phases:
        probe = _first_producing(phases)
        if probe is None:
            LOG.warning("blob_raised: no creator produced records to probe")
        else:
            creator = int(probe, 16)
            args = phases[probe]["args"]
            try:
                rows = gold.run_plan(
                    game_copy, dbgcall,
                    raised_plan(state["handle"], creator, args, RAISED_HEIGHT),
                    "blob_raised", attempts=attempts)
                records = _reads_in_order(rows)
                seeds = _seeds_in_order(rows)
                phases["raised"] = {
                    "creator": probe,
                    "tile": [args[0], args[1]],
                    "height": RAISED_HEIGHT,
                    "cell": _cell_read(rows),
                    "args": args,
                    "records": parse_records(records[0]) if records else [],
                    "seed_before": seeds[0][0] if len(seeds) > 0 else None,
                    "seed_after": seeds[1][0] if len(seeds) > 1 else None,
                    "seed2_before": seeds[0][1] if len(seeds) > 0 else None,
                    "seed2_after": seeds[1][1] if len(seeds) > 1 else None,
                }
                _save(out, document)
            except gold.CaptureError as err:
                failures["raised"] = str(err)
                LOG.warning("blob_raised: %s", err)
                _save(out, document)

    # The scatter phase: the creator whose velocities are *not* a ring, run
    # twice in one process with `rand()` either side of each call.
    if "scatter" not in phases:
        probe = _most_scattered(phases)
        if probe is None:
            LOG.warning("blob_scatter: no creator with scattered velocities")
        else:
            creator = int(probe, 16)
            args = phases[probe]["args"]
            try:
                rows = gold.run_plan(
                    game_copy, dbgcall,
                    scatter_plan(state["handle"], creator, args),
                    "blob_scatter", attempts=attempts)
                reads = _reads_in_order(rows)
                phases["scatter"] = {
                    "creator": probe,
                    "args": args,
                    "rounds": [parse_records(blob) for blob in reads],
                    "seeds": _seeds_in_order(rows),
                    "rand": _rand_results(rows),
                }
                _save(out, document)
            except gold.CaptureError as err:
                failures["scatter"] = str(err)
                LOG.warning("blob_scatter: %s", err)
                _save(out, document)

    captured = [k for k in phases if k.startswith("0x")]
    LOG.warning("%s: %d of %d creator(s) captured", out, len(captured),
                len(reachable_creators(root)))
    return 0


def _first_producing(phases: dict[str, Any]) -> str | None:
    for name in sorted(phases):
        if name.startswith("0x") and phases[name].get("records"):
            return name
    return None


def _most_scattered(phases: dict[str, Any]) -> str | None:
    """The creator whose velocities look least like a ring.

    A creator that lays its blobs evenly around a circle has one speed and
    many directions; the one worth probing is the one whose *speeds* differ,
    because that is the one that cannot be a table walked in order.
    """
    import math
    best, score = None, 0.0
    for name in sorted(phases):
        if not name.startswith("0x"):
            continue
        records = phases[name].get("records") or []
        if len(records) < 3:
            continue
        speeds = [math.hypot(r["vx"], r["vy"]) for r in records]
        spread = (max(speeds) - min(speeds)) / (max(speeds) or 1)
        if spread > score:
            best, score = name, spread
    return best


def _rand_results(rows: list[dict[str, Any]]) -> list[int]:
    """Every ``rand()`` return in plan order.

    A JSONL row carries the **callee's** name, never the binding, so nine
    calls to one import are told apart by their order and nothing else.
    """
    out: list[int] = []
    for row in rows:
        if row.get("call") != "rand" or row.get("status") != "ok":
            continue
        value = row.get("result")
        out.append(int(value, 0) if isinstance(value, str) else int(value or 0))
    return out


def parse_hooks(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Turn the hook plan's rows into the phase document.

    Rows carry the **callee's** name and not the binding, so the sweeps are
    told apart by order alone -- the same property `_rand_results` relies on.
    """
    import struct

    def reads(row: dict[str, Any]) -> dict[str, str]:
        return row.get("reads") or {}

    def qword(row: dict[str, Any], key: str) -> Any:
        """A captured double, with the non-finite ones as **strings**.

        ``0x0046D400`` divides by zero without a guard, so ``NaN`` and
        ``inf`` are ordinary answers -- and `json.dump` writes them as bare
        `NaN`, which is not JSON.  Godot's parser refuses the whole document,
        and the suite that reads this fixture stopped loading because of it.
        Naming them keeps the fixture parseable and keeps the fact.
        """
        text = reads(row).get(key)
        if not text or "<" in text:
            return None
        raw = _hex_bytes(text)
        if len(raw) < 8:
            return None
        value = struct.unpack_from("<d", raw, 0)[0]
        if value != value:
            return "nan"
        if value == float("inf"):
            return "inf"
        if value == float("-inf"):
            return "-inf"
        return value

    def dword(row: dict[str, Any], key: str, signed: bool = True) -> int | None:
        text = reads(row).get(key)
        if not text or "<" in text:
            return None
        raw = _hex_bytes(text)
        if len(raw) < 4:
            return None
        return int.from_bytes(raw[:4], "little", signed=signed)

    out: dict[str, Any] = {"orient": [], "direction": [], "rotate": [],
                           "object": [], "unit": [], "pointers": {},
                           "targets": {}}
    for row in rows:
        if row.get("status") != "ok":
            continue
        call = row.get("call")
        if call == "aResetBlobs":
            for global_va in POINTER_GLOBALS:
                key = f"0x{global_va:x}"
                value = dword(row, key, signed=False)
                if value is not None:
                    out["pointers"][key] = value
                preview = reads(row).get(f"[{key}]")
                if preview and "<" not in preview:
                    out["targets"][key] = preview.replace(" ", "")
            for name, va in (("object_table", OBJECT_TABLE),
                             ("unit_table", UNIT_TABLE)):
                value = dword(row, f"0x{va:x}", signed=False)
                if value is not None:
                    out[name] = value
        elif call == "hOrient":
            out["orient"].append([dword(row, "&oa"), dword(row, "&ob"),
                                  dword(row, "&oc")])
        elif call == "hDirection":
            out["direction"].append([qword(row, "&oa"), qword(row, "&ob"),
                                     qword(row, "&oc")])
        elif call == "hRotate":
            text = reads(row).get("&rot")
            if text and "<" not in text:
                raw = _hex_bytes(text)
                out["rotate"].append(list(struct.unpack_from("<iii", raw, 0)))
            else:
                out["rotate"].append(None)
        elif call == "hObjectPosition":
            out["object"].append({
                "ok": int(row["eax"], 16),
                "x": dword(row, "&px"), "y": dword(row, "&py"),
                "z": dword(row, "&pz"),
            })
        elif call == "aGetUnitMapElementPtr":
            out["unit"].append(int(row["eax"], 16))
    return out


def _save(out: Path, document: dict[str, Any]) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(document, indent=1, sort_keys=True) + "\n")


def _read_dword(rows: list[dict[str, Any]], key: str) -> int:
    for row in rows:
        text = (row.get("reads") or {}).get(key)
        if text:
            return int.from_bytes(_hex_bytes(text)[:4], "little")
    raise SystemExit(f"no read of {key} in the capture")


def _eax_of(rows: list[dict[str, Any]], call: str) -> int:
    for row in rows:
        if row.get("call") == call and row.get("status") == "ok":
            return int(row["eax"], 16)
    raise SystemExit(f"no successful {call} in the capture")


def _reads_in_order(rows: list[dict[str, Any]]) -> list[bytes]:
    out: list[bytes] = []
    for row in rows:
        for key, text in (row.get("reads") or {}).items():
            if key.startswith("["):
                out.append(_hex_bytes(text))
    return out


def _cell_read(rows: list[dict[str, Any]]) -> list[int] | None:
    """The control-map cell the z probe read back after writing its height."""
    for row in rows:
        for key, text in (row.get("reads") or {}).items():
            if key.startswith("$c0+") and "<" not in text:
                return list(_hex_bytes(text))
    return None


def _seeds_in_order(rows: list[dict[str, Any]]) -> list[tuple[float, float]]:
    """Every ``(aRandom, second stream)`` seed reading, in plan order.

    A creator contributes two: the pair on its ``aResetBlobs`` line, which is
    what it started from, and the pair on the read line after it, which is
    what it left.  A read that came back unreadable drops its whole pair
    rather than being guessed, which makes the pairing short and the caller
    notice.
    """
    import struct
    first, second = f"0x{ARANDOM_SEED:x}", f"0x{ARANDOM2_SEED:x}"
    out: list[tuple[float, float]] = []
    for row in rows:
        reads = row.get("reads") or {}
        a, b = reads.get(first), reads.get(second)
        if not a or not b or "<" in a or "<" in b:
            continue
        raw_a, raw_b = _hex_bytes(a), _hex_bytes(b)
        if len(raw_a) >= ARANDOM_SEED_BYTES and len(raw_b) >= ARANDOM_SEED_BYTES:
            out.append((struct.unpack_from("<d", raw_a, 0)[0],
                        struct.unpack_from("<d", raw_b, 0)[0]))
    return out


def seed_advance(before: float, after: float) -> int | None:
    """How many ``ARandom`` steps carry *before* to *after*, or ``None``.

    ``docs/22`` §3's generator is a pure function of its seed, so the number of
    draws a creator took is recoverable from the two reads without touching
    the creator at all.  A zero seed is the arithmetic's fixed point and
    carries no information, so it is refused rather than answered with zero.
    """
    from inclib.rng import ARandom
    if not before:
        return None
    if before == after:
        return 0
    seed = before
    for step in range(1, SEED_SEARCH_LIMIT + 1):
        seed = float(int(seed * ARandom.MULTIPLIER) % int(ARandom.MODULUS))
        if seed == after:
            return step
    return None


def seed_draws(before: float, count: int) -> list[float]:
    """The *fractions* ``seed / MODULUS`` of the next *count* draws.

    ``aRandom(base, span)`` returns ``base + span * fraction`` truncated, so
    the fractions are the whole of what the generator contributed and the two
    arguments are the only thing left to recover from a captured velocity.
    """
    from inclib.rng import ARandom
    seed = before
    out: list[float] = []
    for _ in range(count):
        seed = float(int(seed * ARandom.MULTIPLIER) % int(ARandom.MODULUS))
        out.append(seed / ARandom.MODULUS)
    return out


# -- what the hooks and the draws turned out to be --------------------------

#: How many sweep points the hook phase carries, and how many of each answer
#: `inclib.eng3d` has to reproduce **exactly**.  Not "within a unit": the
#: whole point of measuring was to stop approximating.
HOOK_ORIENT_CASES = 20
HOOK_DIRECTION_CASES = 40
HOOK_ROTATE_CASES = 8
#: Object ids that answered out of the ids swept.  A gated slot answers 0 and
#: writes nothing, which the sweep sees as a zero return with the buffers
#: still cleared.
HOOK_OBJECTS_ANSWERED = 15
#: **One of those fifteen is id 200, and it is a bug.**  Both lookups guard
#: with `cmp eax, 0xC8` and a *strictly greater* branch, so id 200 is admitted
#: -- and the array has 200 entries, 0 through 199.  The sweep's last object
#: comes back with a position that is neither a tile nor a multiple of the map
#: field, read out of whatever follows the array.  It is reachable only from a
#: caller that would pass 200, and nothing shipped does; pinned because a
#: remake that clamps at `<= 200` would inherit it silently.
HOOK_OBJECT_PAST_THE_END = 200
#: Unit slots whose record address came back, and the ones that did not: the
#: dead-unit branch returns 0 through the engine's CHECK reporter **without
#: blocking**, which is why the sweep could include them at all.
HOOK_UNITS_ANSWERED = 14
HOOK_UNITS_REFUSED = 4
#: The five runtime function pointers, read live.  They are not imports, so
#: this is the only place their values exist; what matters for the model is
#: that all five are non-null and distinct, which is what says the engine
#: really did fill them in before the sweep ran.
HOOK_POINTERS = 5

#: **The creators' draw arithmetic**, `docs/97` §16.1's residue and the item
#: this closes.  It is `int(base + span * fraction)` -- the generator's own
#: shape -- optionally times a constant.  The earlier fit failed for two
#: reasons and neither was exotic arithmetic:
#:
#: * the draw-to-field **order is per creator and runs both ways**.  MSVC
#:   evaluates `__cdecl` arguments right to left, so a creator that passes its
#:   draws straight into the constructor consumes them in reverse field order
#:   (`0x004228F0`) while one that parks them in locals first does not
#:   (`0x00425810`);
#: * some creators **scale** the truncated draw (`0x0042ACF0`'s vertical is
#:   32 times it), so a fit that only looked for `base + span*f` could not
#:   see it.
#:
#: Each entry is `field -> (index in the cycle, scale, base, span)` plus the
#: cycle length, and `--check` replays every captured record through it.  A
#: creator is listed **only** if every field that varies across its records is
#: explained: a partial recipe over twelve records is a coincidence waiting to
#: be pinned, and `0x00427810` produced exactly one of those over four.
CREATOR_DRAW_RECIPES: dict[str, dict[str, Any]] = {
    "0x004228F0": {"cycle": 3, "fields": {
        "vz": (0, 1, 400, 800), "vy": (1, 1, -100, 200),
        "vx": (2, 1, -100, 200)}},
    "0x004294E0": {"cycle": 3, "fields": {
        "vz": (0, 1, 200, 300), "vx": (1, 1, -300, 600),
        "vy": (2, 1, -300, 600)}},
    "0x004295D0": {"cycle": 6, "fields": {
        "vz": (0, 1, 600, 700), "vx": (1, 1, -300, 600),
        "vy": (2, 1, -300, 600), "rot_z": (3, 1, 0, 4096),
        "rot_y": (4, 1, 0, 4096), "rot_x": (5, 1, 0, 4096)}},
}
#: Creators whose captured velocities are drawn but whose **stream is not
#: consumed at a fixed rate per record**, so no per-record recipe exists to
#: fit.  Two shapes, both visible in the capture: a creator that builds
#: records of several kinds in one call (`kind`, `class_id` and `model` all
#: vary across its twelve), and one that retries -- `0x00429A80`'s first
#: record does not sit at draw 0 while its second sits at draw 4.  Naming them
#: is the finding; fitting them is not possible from a capture that reads back
#: twelve records of a longer run.
CREATOR_DRAWS_UNSTRUCTURED = (
    "0x00424D20", "0x00425810", "0x004264A0", "0x00426F90", "0x00427410",
    "0x00427810", "0x00429180", "0x00429A80", "0x0042A9D0", "0x0042ACF0",
    "0x0042AF10",
)
#: The velocity draws of `0x00425810`, which is in that list for its
#: **positions** and not its velocities.  Kept separate rather than dropped:
#: three fields reproduced exactly over twelve records is a result whether or
#: not the other three are.
CREATOR_PARTIAL_RECIPES: dict[str, dict[str, Any]] = {
    "0x00425810": {"cycle": 3, "fields": {
        "vx": (0, 1, -320, 640), "vy": (1, 1, -320, 640),
        "vz": (2, 1, -320, 640)}},
}

#: **The Wine start-up measurement**, `docs/91` §1 and `docs/97` §16.6's
#: unexplained group-boundary alignment.  Sixteen fresh single-attempt runs of
#: one identical plan on this host: two reached the anchor.  The failures are
#: all *pre-anchor* and come in two shapes -- a clean early exit and an access
#: violation inside a Wine system DLL -- and their positions carry no period.
#:
#: That closes the alignment without a mechanism, and correctly.  The loss
#: unit **is** the group, so any loss is a whole group and "aligned with group
#: boundaries" is a tautology, not an observation; the three failing groups of
#: six, each given ten attempts, is what a per-start success rate this low
#: produces about a quarter of the time per group.  There was nothing to
#: explain.
STARTUP_PROBE_RUNS = 16
STARTUP_PROBE_REACHED = 2

def probe_startup(game_copy: Path, dbgcall: Path, runs: int) -> int:
    """Run one identical plan *runs* times, one attempt each, and report.

    This is the experiment behind ``STARTUP_PROBE_RUNS``.  It exists as a mode
    rather than as a note because the claim it settles -- that the first blob
    capture's group-boundary alignment had **no mechanism** -- is a claim about
    this host, and a claim about a host has to be re-measurable on it.

    It is outside ``--check`` for the obvious reason: it needs Wine, a copy of
    the game and several minutes, and its result is a rate rather than a pass.
    """
    outcomes: list[str] = []
    for index in range(runs):
        name = f"startup_{index:02d}"
        try:
            gold.run_plan(game_copy, dbgcall, state_plan(), name, attempts=1)
            outcomes.append("reached")
        except gold.CaptureError:
            log = game_copy / f"{name}.log"
            text = log.read_text(errors="replace") if log.is_file() else ""
            outcomes.append("exception" if "exception 0x" in text
                            else "exited" if "exited before" in text
                            else "other")
        LOG.warning("%s: %s", name, outcomes[-1])
    reached = outcomes.count("reached")
    LOG.warning("%d of %d runs reached the anchor: %s",
                reached, runs, " ".join(outcomes))
    return 0


# --------------------------------------------------------------------------
# Check
# --------------------------------------------------------------------------

def run_checks(root: str, fixture: Path) -> int:
    ck = tables.Checker()
    arities = creator_arities(root)
    reach = reachable_creators(root)
    ck.equal("creators.reachable", len(reach), tables.REACHABLE_CREATORS)
    ck.check("creators.arity_recovered",
             len(arities) == len(reach)
             and all(2 <= n <= 7 for n in arities.values()),
             f"{len(arities)} creators, {min(arities.values())}..."
             f"{max(arities.values())} dword arguments")
    ck.equal("creators.arity_table",
             {f"0x{c:08X}": n for c, n in sorted(arities.items())},
             tables.CREATOR_ARITIES, tables.Checker.brief)

    _plan_checks(ck)
    if not fixture.is_file():
        ck.check("native.fixture", False,
                 f"{fixture} is missing; run --game-copy to produce it")
        return _report(ck)
    document = json.loads(fixture.read_text())
    ck.equal("native.schema", document.get("schema"), SCHEMA)
    phases = document.get("phases", {})
    state = phases.get("state", {})
    ck.check("native.pool_base_agrees",
             state.get("base") is not None
             and state["reset_end"] - POOL_RECORDS * RECORD_BYTES == state["base"],
             "aResetBlobs's end and the block base differ by 450 records")
    captured = {k: v for k, v in phases.items() if k.startswith("0x")}
    # **Coverage is a census, not a floor.**  It fails when it drops and it
    # fails when it grows, the same way `ai_gold.py` pins its known
    # disagreements: a number nobody has to update is a number nobody reads.
    ck.equal("native.coverage", len(captured), NATIVE_COVERAGE,
             lambda n: f"{n} of {len(reach)} creators ran in the engine")
    ck.equal("native.faults",
             sorted(document.get("failures", {})), NATIVE_FAULTS,
             lambda v: f"{len(v)} plan(s) the harness could not land")
    made = {k: len(v["records"]) for k, v in sorted(captured.items())}
    ck.equal("native.records",
             (sum(1 for n in made.values() if n), sum(made.values())),
             (NATIVE_PRODUCERS, NATIVE_RECORDS),
             lambda v: f"{v[0]} of {len(made)} creator(s) produced "
                       f"{v[1]} record(s)")
    binary = tables.Binary(root)
    static = binary.blob_calls()
    owners = _creator_of_call(binary)
    creators_set = binary.blob_creators()
    entries = sorted(binary.call_entries())
    aborted, produced = [], []
    for name, phase in sorted(captured.items()):
        creator = int(name, 16)
        ck.equal(f"native.arity_{name}", len(phase["args"]), arities[creator])
        records = phase["records"]
        (produced if records else aborted).append(name)
        if not records:
            continue

        # **The measurement this tool exists for.** Every record a creator
        # makes is placed at the tile it was given, in world units -- one map
        # field is 3200 (docs/30 2.5). That is the half of the creators'
        # arithmetic the remake was inventing.
        # **The law the capture found, and it is not "at the tile".** Most
        # creators place their blobs on the source tile exactly; some place
        # them a fraction of the way toward the target -- an eighth, three
        # tenths -- and every one of those offsets is **collinear with the
        # line between the two tiles**. Checked as an integer cross product,
        # so no rounding enters it and the fraction never has to be named.
        # **And the law is not one law.**  With fifteen creators captured it
        # looked universal; the fifteen that were missing because their plan
        # shared a process with a faulter include creators that place their
        # blobs in a *burst around* the tile, on neither side of the line.
        # So the reading is a census, pinned per creator: a creator that
        # starts scattering, or stops, fails.
        args = phase["args"]
        source = (args[0] * FIELD_UNITS, args[1] * FIELD_UNITS)
        line = ((args[2] - args[0]) * FIELD_UNITS,
                (args[3] - args[1]) * FIELD_UNITS) if len(args) >= 4 else (0, 0)
        offsets = {(r["x"] - source[0], r["y"] - source[1]) for r in records}
        law = ("line" if all(dx * line[1] == dy * line[0] for dx, dy in offsets)
               else "scatter")
        ck.equal(f"native.placement_{name}", law,
                 PLACEMENT_LAW.get(name, "line"),
                 lambda v, o=offsets, l=line, r=records:
                 f"{len(r)} record(s), offsets {sorted(o)[:3]}"
                 f"{' ...' if len(o) > 3 else ''} against the line {l}: {v}")

        # **And the cross-validation.** `blob_tables.py` read the class, the
        # update kind and the literal lifetime out of the compiler's own index
        # and jump tables, statically. These are the same fields, read out of
        # the pool of a running `Incubation.exe`. The two share no code.
        # **A creator may call another creator**, and the records that one
        # leaves are in the pool too.  Collecting only the constructor calls
        # whose nearest preceding entry is this creator missed those, and the
        # engine came back with a triple the static tables "did not have" --
        # which looked like a disagreement between the two readings and was a
        # missing edge in the call graph.  The walk is a **fixed point**, not
        # one hop: that it happens to terminate after one for every creator is
        # `blob_tables.py`'s `creators.nesting_is_flat`, a statement about all
        # thirty rather than about the ones a capture reached.
        bodies = creator_bodies(binary, creator, creators_set, entries)
        want = {(cls, kind, life)
                for site, owner in owners.items() if owner in bodies
                for _model, cls, kind, life in (static[site],)}
        got = {(r["class_id"], r["kind"], r["life"]) for r in records}
        ck.check(f"native.fields_{name}", _agrees(got, want),
                 f"engine {sorted(got)} against the static tables "
                 f"{sorted(want)}")
    _seed_checks(ck, captured)
    _scatter_checks(ck, phases)
    _z_probe_checks(ck, phases, captured)
    _hook_checks(ck, root, phases)
    _recipe_checks(ck, captured)
    ck.check("native.some_produced", bool(produced),
             f"{len(produced)} creator(s) built records, "
             f"{len(aborted)} took the abort path")
    return _report(ck)


#: How far past its entry a creator's body is scanned for nested calls.  One
#: definition, in `blob_tables.py`, which is also where the resulting graph is
#: pinned -- a second copy here would be a constant that agrees with itself.
CREATOR_EXTENT = tables.CREATOR_EXTENT


#: creator -> how it places its records relative to the shooter's tile and
#: the line to the target: ``"line"`` when every offset is collinear with it,
#: ``"scatter"`` when they are a burst around the tile.  Absent means
#: ``"line"``, which is what most of them do.
PLACEMENT_LAW: dict[str, str] = {
    "0x00424D20": "scatter", "0x00425810": "scatter",
    "0x00427410": "scatter", "0x0042A9D0": "scatter",
}

#: **The plans, hashed.**  Nine constants in this file shape the text sent to
#: the debugger and nothing else -- the pool table and its stride, the two
#: seed globals and their width, `memcpy`'s and `rand`'s import slots, how
#: many `rand()` outputs bracket a call.  `--check` replays a stored capture
#: and never renders a plan, so a mutation battery found all nine unread: they
#: are exercised only by *taking* a capture, which needs Wine.  Rendering the
#: four plans with fixed arguments and hashing them closes that without Wine
#: and without a second copy of the addresses: a perturbed constant changes
#: the plan the tool would send, and the hash says so.
#:
#: The arguments are the capture's own: pool handle 22, the ring creator on
#: the tile the save's first unit stands on, the scattering one aimed at the
#: second.
PLAN_FIXTURE_HANDLE = 22
PLAN_FIXTURE_RING = 0x00420A50
PLAN_FIXTURE_SCATTER = 0x00424D20
PLAN_FIXTURE_ARGS = [19, 6]
PLAN_FIXTURE_ARGS4 = [19, 6, 18, 4]
PLAN_DIGESTS = {
    "state": "49f0ca979d1e710b03ede4a1cde1d43eee35aef6a0c90e7bdd69a7d6b281e4f7",
    "creator": "3a8cb6db096c56e18262f17f3573ef633061238fb448fdbe15f457852fd9589a",
    "raised": "781238ff3d31d20af3b7adbfff55e5fabe39594df0308ca49dc8ac2a73cf88df",
    "scatter": "595bcc6cb036941d3ed8b181d76529b665d6a830402966fa680da892293cea36",
}

#: How many creators the capture in hand holds, and which plans never landed.
#: Both are pinned so a thinner capture fails rather than reporting less.
NATIVE_COVERAGE = 30
NATIVE_FAULTS: list[str] = []
#: How many of the thirty produced records on the captured tile, and how many
#: records in all.  The rest refused the tile, which is a measurement of which
#: tile a creator will act on rather than a hole.
NATIVE_PRODUCERS = 23
NATIVE_RECORDS = 198

#: creator -> how many times it advances the uncounted stream, measured.
#: Beside `blob_tables.CREATOR_DRAW_SITES`, which is the static reach.
CREATOR_DRAWS: dict[str, int] = {
    "0x00420A50": 0, "0x004227C0": 0, "0x004228F0": 90, "0x00422B80": 0,
    "0x00423D80": 0, "0x00424250": 0, "0x004247C0": 0, "0x00424D20": 25,
    "0x00425400": 0, "0x00425810": 90, "0x00425CA0": 0, "0x00426070": 0,
    "0x004264A0": 3, "0x004268B0": 0, "0x00426B70": 0, "0x00426F90": 200,
    "0x00427410": 203, "0x00427810": 7, "0x00427C80": 0, "0x00428200": 0,
    "0x00428570": 0, "0x00429180": 144, "0x004294E0": 120, "0x004295D0": 90,
    "0x00429A80": 108, "0x00429C30": 0, "0x00429F40": 0, "0x0042A9D0": 200,
    "0x0042ACF0": 90, "0x0042AF10": 6,
}
#: How many creators advance the second stream at all.
CREATORS_THAT_DRAW = 14
#: Creators that carry a call to the generator but do not reach it here.
DRAW_SITES_NOT_TAKEN: list[str] = [
    "0x00420A50", "0x004227C0", "0x00422B80", "0x00423D80", "0x00424250",
    "0x004247C0", "0x00426070", "0x00426B70", "0x00427C80", "0x00428570",
    "0x00429C30", "0x00429F40",
]
#: Creators whose velocities solve to `aRandom(base, span)` in their draws.
#: **None of the fourteen**, which is consistent with them drawing an angle
#: and laying down `R * cos` rather than a component -- and is a measurement
#: only because `native.fitter_solves_a_known_case` proves the solver solves.
AFFINE_IN_DRAWS: list[str] = []

#: How many of the creators that touch no generator also produce no records.
#: Pinned rather than tolerated: a refusal is a measurement of which tile a
#: creator will act on, and a census fails both when it grows and when it
#: shrinks.
SILENT_REFUSALS = 7

#: What the scatter phase found.  Pinned so a re-capture that answers
#: differently fails rather than quietly rewriting the finding.  The same
#: creator called twice in one process, with the pool reset between, gives
#: **different** velocities -- and the nine `rand()` outputs bracketing the
#: two calls are nine *consecutive* outputs of the C runtime's generator, so
#: the difference is not its.  It is the uncounted Lehmer stream, whose seed
#: moves across each call and only there.
SCATTER_REPEATABLE = False
SCATTER_CRT_DRAWS = 0


def _hook_checks(ck: "tables.Checker", root: str,
                 phases: dict[str, Any]) -> None:
    """Replay the five services of `docs/28` §12.1 through `inclib.eng3d`.

    This is the check that moves the item.  Before it, the remake's
    ``BlobHooks.orient`` was an invented ``atan2`` over a 0..0xFFFF turn and
    the document said in as many words that nothing had measured the real
    one.  The capture measured it, and the model here has to reproduce every
    captured answer **exactly** or say so.

    What it deliberately does *not* claim: `0x004039A0`'s three-angle matrix
    builder lives in Eng3d and is only recorded, not reproduced -- so its
    cases are checked for having been taken, not for agreeing with anything.
    """
    from inclib import eng3d

    hooks = phases.get("hooks")
    if not hooks:
        ck.check("native.hooks", False,
                 "no hooks phase in the capture; re-run --game-copy")
        return
    ck.check("native.hooks", True,
             "the five services of docs/28 12.1 were called in a live process")
    tablesets = eng3d.load(root)
    # **The sweep's own arguments are pinned, not taken from the capture.**
    # Reading them out of the fixture and then reproducing the fixture's
    # answers with them is circular: a wrong constant would move both sides
    # together and the check would pass.  So the constants are compared to
    # what the capture was actually taken with, and the model then runs on the
    # constants.
    ck.equal("native.hook_sweep_source", tuple(hooks["source"]), HOOK_SOURCE)
    ck.equal("native.hook_sweep_deltas",
             tuple(tuple(d) for d in hooks["deltas"]), HOOK_DELTAS,
             lambda v: f"{len(v)} delta(s), the sweep's own")
    ck.equal("native.hook_sweep_rotations",
             tuple((tuple(v), tuple(a))
                   for v, a in hooks.get("rotations", [])), HOOK_ROTATIONS,
             lambda v: f"{len(v)} rotation(s), the sweep's own")
    ck.equal("native.hook_sweep_object_ids",
             list(hooks.get("object_ids", [])), hook_object_ids(),
             lambda v: f"{len(v)} object id(s): {HOOK_DENSE_IDS} dense, then "
                       f"every {HOOK_SPARSE_STEP} to {HOOK_ID_LIMIT}")
    ck.equal("native.hook_pointer_set",
             sorted(hooks["pointers"]),
             sorted(f"0x{g:x}" for g in POINTER_GLOBALS),
             lambda v: f"{len(v)} runtime function pointer(s), by address")
    source = HOOK_SOURCE
    deltas = list(HOOK_DELTAS)

    # **The tables themselves, before anything built on them.**  Two of
    # `inclib.eng3d`'s constants are otherwise only *described*: the peak is
    # never multiplied by anything (the table is read, not generated) and the
    # cosine offset shifts an index by one, which moves no captured angle.  A
    # battery caught both saying nothing.  These are the properties that make
    # them true: the table's peak **is** the scale, and the cosine window is
    # the sine table a quarter turn along, so `cos(0)` is the peak and
    # `sin(quarter)` is the same number.
    ck.check("native.eng3d_scale_is_the_peak",
             max(tablesets.trig) == eng3d.SINE_SCALE
             and min(tablesets.trig) == -eng3d.SINE_SCALE,
             f"TRIG.IMG peaks at +/-{eng3d.SINE_SCALE}, which is what makes "
             "the engine's identity rotation lose a unit")
    ck.check("native.eng3d_cosine_window",
             eng3d.COSINE_OFFSET == eng3d.ANGLE_UNITS // 4
             and tablesets.cos(0) == eng3d.SINE_SCALE
             and tablesets.sin(eng3d.ANGLE_UNITS // 4) == eng3d.SINE_SCALE
             and all(tablesets.cos(t) == tablesets.sin(t + eng3d.COSINE_OFFSET)
                     for t in range(0, eng3d.ANGLE_UNITS, 17)),
             f"the cosine window is the sine table {eng3d.COSINE_OFFSET} "
             "entries along, which is why it needs no wrap-around check")
    ck.equal("native.hook_orient_cases", len(hooks["orient"]),
             HOOK_ORIENT_CASES)
    mismatched = []
    for delta, answer in zip(deltas, hooks["orient"]):
        target = tuple(s + d for s, d in zip(source, delta))
        pitch, yaw = tablesets.orient(source, target)
        if [0, pitch, yaw] != answer:
            mismatched.append((delta, answer, [0, pitch, yaw]))
    ck.equal("native.hook_orient", mismatched, [],
             lambda v: f"{HOOK_ORIENT_CASES - len(v)}/{HOOK_ORIENT_CASES} "
                       "(pitch, yaw) reproduced from ATN.IMG and the Q14 "
                       "matrix")
    # The seventh argument is never read -- the capture's proof is that the
    # buffer handed to it comes back exactly as it was zeroed, in all twenty.
    ck.check("native.hook_orient_dead_argument",
             all(answer[0] == 0 for answer in hooks["orient"]),
             "0x00403AA0's seventh argument is dead; only two are written")

    ck.equal("native.hook_direction_cases", len(hooks["direction"]),
             HOOK_DIRECTION_CASES)
    mismatched = []
    for index, delta in enumerate(deltas):
        target = tuple(s + d for s, d in zip(source, delta))
        for shift in (0, 1):
            answer = hooks["direction"][2 * index + shift]
            want = [_named(v) for v in tablesets.direction(source, target,
                                                            shift)]
            same = list(answer) == want
            if not same:
                mismatched.append((delta, shift, answer, list(want)))
    ck.equal("native.hook_direction", mismatched, [],
             lambda v: f"{HOOK_DIRECTION_CASES - len(v)}/"
                       f"{HOOK_DIRECTION_CASES} triples reproduced, NaN and "
                       "inf included")
    # Two properties of `0x0046D400` that a remake would otherwise invent.
    ck.check("native.hook_direction_is_not_normalised",
             any(isinstance(a, float) and isinstance(b, float)
                 and abs(a) == 1.0 and abs(b) < 1.0
                 for a, b, _c in hooks["direction"]),
             "the first two components are divided by the larger of |dx|,|dy|")
    ck.check("native.hook_direction_divides_by_zero",
             any(isinstance(c, str) for _a, _b, c in hooks["direction"]),
             "a zero horizontal distance is not guarded -- NaN and inf reach "
             "the caller")

    ck.equal("native.hook_rotate_cases", len(hooks["rotate"]),
             HOOK_ROTATE_CASES)
    ck.check("native.hook_rotate_recorded",
             all(row is not None and len(row) == 3 for row in hooks["rotate"]),
             "0x004039A0 answered every case -- **recorded, not reproduced**: "
             "its three-angle builder is Eng3d's and no RzRxRy ordering with "
             "either rounding matches all eight")
    ck.check("native.hook_rotate_identity_loses_a_unit",
             hooks["rotate"][0] == [999, 0, 0],
             "the engine's identity rotation is 16383/16384, not 1 -- which "
             "is where a coordinate of 1000 becomes 999")

    ck.equal("native.hook_pointers", len(hooks["pointers"]), HOOK_POINTERS)
    ck.check("native.hook_pointers_resolved",
             all(v for v in hooks["pointers"].values())
             and len(set(hooks["pointers"].values())) == HOOK_POINTERS,
             "all five runtime function pointers were filled in and distinct")
    ck.check("native.hook_pointer_targets",
             len(hooks["targets"]) == HOOK_POINTERS
             and all(t.startswith("5356578b") for t in hooks["targets"].values()),
             "each points at a thunk with the same prologue -- one module's "
             "export stubs, not five unrelated routines")

    answered = [o for o in hooks["object"] if o["ok"]]
    ck.equal("native.hook_objects_answered", len(answered),
             HOOK_OBJECTS_ANSWERED,
             lambda n: f"{n} of {len(hooks['object'])} object ids carry a "
                       "position; the rest are gated off at +0x40")
    ck.check("native.hook_object_positions_are_fields",
             all(o["x"] % FIELD_UNITS == 0 and o["y"] % FIELD_UNITS == 0
                 for o in answered[:-1]),
             f"every in-range answer is a whole {FIELD_UNITS}-unit map field "
             "-- the placed object's tile, docs/28 7.6.1")
    past = [object_id for object_id, answer
            in zip(hook_object_ids(), hooks["object"])
            if answer["ok"] and answer["x"] % FIELD_UNITS != 0]
    ck.equal("native.hook_object_admits_one_past_the_end", past,
             [HOOK_OBJECT_PAST_THE_END],
             lambda v: f"id {v[0]} passes the `> {HOOK_ID_LIMIT}` guard and "
                       f"reads past a {HOOK_ID_LIMIT}-entry array"
                       if v else "no id read past the array")
    ck.check("native.hook_object_refusal_writes_nothing",
             all(o["x"] == 0 and o["y"] == 0 and o["z"] == 0
                 for o in hooks["object"] if not o["ok"]),
             "a refused id leaves the out-parameters alone")

    _hook_static_checks(ck, root)

    table = hooks["unit_table"]
    slots = hooks["unit_slots"]
    good = [(slot, ptr) for slot, ptr in zip(slots, hooks["unit"]) if ptr]
    ck.equal("native.hook_units_answered", len(good), HOOK_UNITS_ANSWERED)
    ck.equal("native.hook_units_refused", len(slots) - len(good),
             HOOK_UNITS_REFUSED,
             lambda n: f"{n} slot(s) hold a named but dead unit; the CHECK "
                       "path returns 0 and does **not** block the process")
    ck.check("native.hook_unit_stride",
             all(ptr == table + gold.UNIT_STRIDE * slot for slot, ptr in good),
             f"every answer is base + {gold.UNIT_STRIDE} * id -- the unit "
             "record stride, measured rather than read off the disassembly")


def _hook_static_checks(ck: "tables.Checker", root: str) -> None:
    """The two lookups' strides and offsets, read out of the instructions.

    The capture measures the unit record's stride directly -- every answered
    address is `base + 91*id` -- but the object table's base is never returned,
    so its stride is read here instead, out of the three `lea`s that compute
    it.  Both are pinned so the constants above are *read* by something: a
    documented offset no check consumes is a comment, and a comment cannot go
    stale loudly.
    """
    from inclib import eng3d

    b = tables.Binary(root)

    def lea(va: int, encoding: bytes) -> bool:
        return all(b.u8(va + n) == byte for n, byte in enumerate(encoding))

    # `0x00405100`: ecx = 9*id; edx = id + 2*ecx = 19*id; eax = base+id +
    # 4*edx -- so the record is 77 bytes and the base is `[0x004FA804]`.
    ck.check("native.hook_object_stride",
             lea(HOOK_OBJECT_POSITION + 0x0F, b"\x8d\x0c\xc0")
             and lea(HOOK_OBJECT_POSITION + 0x12, b"\x8d\x14\x48")
             and lea(HOOK_OBJECT_POSITION + 0x1D, b"\x8d\x04\x91")
             and 1 + 4 * (1 + 2 * 9) == OBJECT_STRIDE,
             f"three lea's encode a stride of {OBJECT_STRIDE}")
    ck.check("native.hook_object_gate",
             b.u8(HOOK_OBJECT_POSITION + 0x20) == 0x8A
             and b.u8(HOOK_OBJECT_POSITION + 0x23) == OBJECT_GATE
             and b.u8(HOOK_OBJECT_POSITION + 0x28) == 0x8B
             and b.u8(HOOK_OBJECT_POSITION + 0x2A) == OBJECT_DELEGATE,
             f"gated on +0x{OBJECT_GATE:02X}, delegating through "
             f"+0x{OBJECT_DELEGATE:02X}")
    ck.equal("native.hook_object_fields",
             (b.u8(HOOK_OBJECT_POSITION + 0x53),
              b.u8(HOOK_OBJECT_POSITION + 0x5C),
              b.u8(HOOK_OBJECT_POSITION + 0x65)),
             OBJECT_POSITION_FIELDS,
             lambda v: "the position copied out is "
                       + ", ".join(f"+0x{n:02X}" for n in v))
    # `0x00477AE0`: ecx = 5*id; ecx = 9*ecx = 45*id; eax = base+id + 2*ecx.
    ck.check("native.hook_unit_stride",
             lea(HOOK_UNIT_RECORD + 0x56, b"\x8d\x0c\x80")
             and lea(HOOK_UNIT_RECORD + 0x5B, b"\x8d\x0c\xc9")
             and lea(HOOK_UNIT_RECORD + 0x5E, b"\x8d\x04\x4a")
             and 1 + 2 * (9 * 5) == gold.UNIT_STRIDE,
             f"three lea's encode a stride of {gold.UNIT_STRIDE}, which the "
             "capture also measures directly")
    ck.check("native.hook_unit_alive_byte",
             b.u8(HOOK_UNIT_RECORD + 0x61) == 0x8A
             and b.u8(HOOK_UNIT_RECORD + 0x64) == UNIT_ALIVE,
             f"the liveness byte is +0x{UNIT_ALIVE:02X}")
    ck.check("native.hook_table_bases",
             b.u8(HOOK_OBJECT_POSITION + 0x15) == 0x8B
             and b.u32(HOOK_OBJECT_POSITION + 0x17) == OBJECT_TABLE
             and b.u8(HOOK_UNIT_RECORD + 0x50) == 0x8B
             and b.u32(HOOK_UNIT_RECORD + 0x52) == UNIT_TABLE,
             f"the arrays are at [0x{OBJECT_TABLE:08X}] and "
             f"[0x{UNIT_TABLE:08X}]")
    # The three geometry routines, identified by their own first bytes and by
    # the one instruction that carries a claim: `0x00403AA0` ends its pitch
    # with `sub eax, 0x400`, which is the quarter turn docs/28 7.4.2 names.
    ck.check("native.hook_orient_entry",
             b.u8(HOOK_ORIENT) == 0x83 and b.u8(HOOK_ORIENT + 1) == 0xEC
             and b.u8(HOOK_ORIENT + 0x81) == 0x2D
             and b.u32(HOOK_ORIENT + 0x82) == eng3d.ANGLE_UNITS // 4,
             f"0x{HOOK_ORIENT:08X} subtracts a quarter of "
             f"{eng3d.ANGLE_UNITS} from its pitch")
    ck.check("native.hook_direction_entry",
             b.u8(HOOK_DIRECTION) == 0x8B and b.u8(HOOK_DIRECTION + 1) == 0x4C
             and b.u8(HOOK_DIRECTION + 2) == 0x24
             and b.u8(HOOK_DIRECTION + 3) == 0x10,
             f"0x{HOOK_DIRECTION:08X} opens by reading its fourth argument")
    ck.check("native.hook_rotate_entry",
             b.u8(HOOK_ROTATE) == 0x83 and b.u8(HOOK_ROTATE + 1) == 0xEC
             and b.u8(HOOK_ROTATE + 2) == 0x24,
             f"0x{HOOK_ROTATE:08X} opens with a 0x24-byte frame")
    ck.check("native.hook_guards_admit_the_limit",
             b.u8(HOOK_OBJECT_POSITION + 4) == 0x3D
             and b.u32(HOOK_OBJECT_POSITION + 5) == HOOK_ID_LIMIT
             and b.u8(HOOK_UNIT_RECORD + 0x2A) == 0x3D
             and b.u32(HOOK_UNIT_RECORD + 0x2B) == HOOK_ID_LIMIT,
             f"both guards compare against {HOOK_ID_LIMIT} with a strictly "
             "greater branch, so the limit itself is admitted")


def _named(value: float) -> Any:
    """A float, or the name of a non-finite one -- the fixture's convention."""
    if value != value:
        return "nan"
    if value == float("inf"):
        return "inf"
    if value == float("-inf"):
        return "-inf"
    return value


def _recipe_checks(ck: "tables.Checker", captured: dict[str, Any]) -> None:
    """Replay each pinned draw recipe against every captured record.

    A recipe reproduces a **field**, from the generator's seed, with nothing
    taken from the record it is being compared against.  That is what makes
    it a model rather than a restatement of the capture.
    """
    from inclib.rng import ARandom

    def replay(name: str, recipe: dict[str, Any]) -> list[Any]:
        phase = captured.get(name)
        if not phase or phase.get("seed2_before") is None:
            return [f"{name}: not captured"]
        records = phase["records"]
        cycle = recipe["cycle"]
        rng = ARandom(phase["seed2_before"])
        draws = [rng.raw(0, 1) for _ in range(cycle * len(records) + cycle)]
        wrong: list[Any] = []
        for index, record in enumerate(records):
            for field, (slot, scale, base, span) in recipe["fields"].items():
                want = scale * int(base + span * draws[cycle * index + slot])
                if record[field] != want:
                    wrong.append((name, index, field, record[field], want))
        return wrong

    total = 0
    for name, recipe in sorted(CREATOR_DRAW_RECIPES.items()):
        wrong = replay(name, recipe)
        total += len(recipe["fields"])
        ck.equal(f"native.draw_recipe_{name}", wrong, [],
                 lambda v, n=name, r=recipe:
                 f"{n}: {len(r['fields'])} field(s) of every record "
                 f"reproduced from the seed" if not v
                 else f"{len(v)} disagreement(s)")
    for name, recipe in sorted(CREATOR_PARTIAL_RECIPES.items()):
        wrong = replay(name, recipe)
        ck.equal(f"native.draw_recipe_partial_{name}", wrong, [],
                 lambda v, n=name, r=recipe:
                 f"{n}: {len(r['fields'])} velocity field(s) reproduced; its "
                 "positions are not on a fixed cadence" if not v
                 else f"{len(v)} disagreement(s)")
    ck.check("native.draw_recipe_order_runs_both_ways",
             CREATOR_DRAW_RECIPES["0x004228F0"]["fields"]["vz"][0] == 0
             and CREATOR_PARTIAL_RECIPES["0x00425810"]["fields"]["vx"][0] == 0,
             "one creator draws vz first and another vx first -- the order is "
             "the source's, through MSVC's right-to-left argument evaluation")
    from inclib import eng3d
    ck.check("native.draw_recipe_rotations_are_binary_degrees",
             all(span == eng3d.ANGLE_UNITS
                 for slot, scale, base, span
                 in CREATOR_DRAW_RECIPES["0x004295D0"]["fields"].values()
                 if base == 0 and span > 1000),
             f"a drawn rotation is aRandom(0, {eng3d.ANGLE_UNITS}) -- the "
             "4096-unit circle, docs/70")
    ck.equal("native.draws_unstructured",
             tuple(sorted(CREATOR_DRAWS_UNSTRUCTURED)),
             tuple(sorted(set(CREATOR_DRAWS_UNSTRUCTURED))),
             lambda v: f"{len(v)} creator(s) consume the stream at no fixed "
                       "rate per record and cannot carry a recipe")
    ck.check("native.draw_recipes_cover_the_solved",
             set(CREATOR_DRAW_RECIPES) & set(CREATOR_DRAWS_UNSTRUCTURED)
             == set(),
             f"{total} pinned field(s) across "
             f"{len(CREATOR_DRAW_RECIPES)} creator(s), disjoint from the "
             "unstructured ones")


def _scatter_checks(ck: "tables.Checker", phases: dict[str, Any]) -> None:
    """Where a creator's *scattered* velocities come from, if not ``aRandom``.

    The seed reads say no creator advances ``aRandom``; the static scan says
    no creator's closure even contains a call to it, or to the C runtime's
    ``rand``.  Two readings that share no code, and both negative -- which
    leaves a creator whose twelve velocities have twelve different speeds
    needing an explanation that is not a generator.  This is the experiment
    that supplies one: the same creator, the same arguments, twice in one
    process, with ``rand()`` bracketing each call.
    """
    scatter = phases.get("scatter")
    if not scatter:
        ck.check("native.scatter_probe", False,
                 "no scatter phase in the capture; re-run --game-copy")
        return
    rounds = scatter.get("rounds") or []
    ck.check("native.scatter_ran", len(rounds) == 2 and all(rounds),
             f"{len(rounds)} round(s) of "
             f"{[len(r) for r in rounds]} record(s) from "
             f"{scatter['creator']}")
    if len(rounds) != 2 or not all(rounds):
        return

    def velocities(records: list[dict[str, Any]]) -> list[tuple]:
        return [(r["vx"], r["vy"], r["vz"]) for r in records]

    same = velocities(rounds[0]) == velocities(rounds[1])
    ck.equal("native.scatter_repeatable", same, SCATTER_REPEATABLE,
             lambda v: ("two runs of the same creator in one process give "
                        + ("identical" if v else "different")
                        + " velocities"))

    # **The positive half.**  `aRandom`'s seed stands still across both calls
    # and the uncounted stream's moves across each -- which is the difference
    # between "the velocities are random" and "the velocities are random and
    # here is the generator".
    seeds = scatter.get("seeds") or []
    if len(seeds) >= 4:
        counted = {pair[0] for pair in seeds}
        moved = [seed_advance(seeds[i][1], seeds[i + 1][1])
                 for i in (0, 2)]
        ck.check("native.scatter_stream", len(counted) == 1
                 and all(n is not None and n > 0 for n in moved),
                 f"aRandom's seed holds at {sorted(counted)} while the "
                 f"uncounted stream advances {moved} across the two calls")

    outputs = scatter.get("rand") or []
    if len(outputs) < 2 * RAND_PROBES:
        ck.check("native.scatter_rand_read", False,
                 f"{len(outputs)} rand() outputs, need {3 * RAND_PROBES}")
        return
    ck.check("native.scatter_rand_read", True,
             f"{len(outputs)} rand() outputs bracket the two calls")
    draws: list[int | None] = []
    for index in range(len(outputs) // RAND_PROBES - 1):
        before = crt_state(outputs[index * RAND_PROBES:
                                   (index + 1) * RAND_PROBES])
        after = outputs[(index + 1) * RAND_PROBES:
                        (index + 2) * RAND_PROBES]
        draws.append(crt_advance(before, after) if before is not None else None)
    ck.check("native.scatter_crt_recovered", all(d is not None for d in draws),
             f"the C runtime's LCG resolved either side of {len(draws)} call(s)")
    if any(d is None for d in draws):
        return
    ck.equal("native.scatter_crt_draws", max(draws), SCATTER_CRT_DRAWS,
             lambda n: f"the creator moves rand() {draws} time(s) -- "
                       + ("neither generator; the scatter is data"
                          if n == 0 else "the C runtime's"))


def _z_probe_checks(ck: "tables.Checker", phases: dict[str, Any],
                    captured: dict[str, Any]) -> None:
    """Does the floor enter a blob's ``z``?  It does not, and this is the half
    of that reading taken inside the engine.

    The static half is `blob_tables.py`'s ``origin.*``: every creator takes its
    origin from the **placed object's** position -- ``aGetSymbolObjectPtr``'s
    ``+0x10/+0x14/+0x18`` -- and **no** creator reads the control map's height
    dword at ``+1``.  So "absolute" and "floor plus a constant" were the wrong
    pair of hypotheses; the answer is the object's own ``z`` plus a constant
    the creator carries, and the ground never enters.

    This raises the control map's height under the creator's own tile and
    calls it again, everything else held.  ``z`` must not move.  On a map
    whose occupied tiles are all at height zero, that is the only experiment
    that can tell the difference, and the two readings share no code.
    """
    raised = phases.get("raised")
    if not raised:
        ck.check("native.z_probe", False,
                 "no raised phase in the capture; re-run --game-copy")
        return
    height = raised["height"]
    cell = raised.get("cell")
    landed = (cell is not None
              and int.from_bytes(bytes(cell[gold.CELL_HEIGHT:
                                            gold.CELL_HEIGHT + 4]),
                                 "little", signed=True) == height)
    ck.check("native.z_probe_write_landed", landed,
             f"the control map reads back {height} at {raised['tile']}")
    base = (captured.get(raised["creator"]) or {}).get("records") or []
    ck.check("native.z_probe_ran", bool(raised.get("records")) and bool(base),
             f"{len(raised.get('records') or [])} record(s) raised against "
             f"{len(base)} flat")
    if not (landed and raised.get("records") and base):
        return
    flat_z = sorted({r["z"] for r in base})
    up_z = sorted({r["z"] for r in raised["records"]})
    reading = ("floor-does-not-enter" if flat_z == up_z
               else "floor-relative"
               if len(flat_z) == len(up_z)
               and all(u - f == height for f, u in zip(flat_z, up_z))
               else "neither")
    ck.equal("native.z_reading", reading, Z_READING,
             lambda v: f"floor +{height} leaves z at {flat_z} -> {up_z}: {v}")


#: What the z probe found.  Pinned so a re-capture that answers differently
#: fails rather than quietly rewriting the finding.
Z_READING = "floor-does-not-enter"


def _plan_checks(ck: "tables.Checker") -> None:
    """The four plans, rendered with fixed arguments and hashed.

    Needs no capture and no game root: this is the half of the tool `--check`
    otherwise never touches, and the nine constants that shape a plan are read
    here or nowhere.
    """
    import hashlib
    rendered = {
        "state": state_plan(),
        "creator": creator_plan(PLAN_FIXTURE_HANDLE,
                                [{"creator": PLAN_FIXTURE_RING,
                                  "args": PLAN_FIXTURE_ARGS}]),
        "raised": raised_plan(PLAN_FIXTURE_HANDLE, PLAN_FIXTURE_RING,
                              PLAN_FIXTURE_ARGS, RAISED_HEIGHT),
        "scatter": scatter_plan(PLAN_FIXTURE_HANDLE, PLAN_FIXTURE_SCATTER,
                                PLAN_FIXTURE_ARGS4),
    }
    digests = {name: hashlib.sha256(text.encode()).hexdigest()
               for name, text in rendered.items()}
    ck.equal("plans.digests", digests, PLAN_DIGESTS, tables.Checker.brief)
    # A digest catches a change without saying what changed, so the two
    # readings the plans exist for are also asserted in the clear.
    ck.check("plans.read_both_seeds",
             all(f"0x{ARANDOM_SEED:x}" in text and f"0x{ARANDOM2_SEED:x}" in text
                 for name, text in rendered.items() if name != "state"),
             "every creator plan reads both generators' seeds")
    ck.check("plans.pool_is_reached_through_the_table",
             f"[0x{_entry_address(PLAN_FIXTURE_HANDLE):x}]"
             in rendered["creator"],
             "the pool is read through the memory manager's table, never "
             "through a heap address")


def _seed_checks(ck: "tables.Checker", captured: dict[str, Any]) -> None:
    """Which generator a creator draws from, and how many times.

    ``docs/97`` §15.5 recorded the velocities as "drawn from ``aRandom`` inside
    the creator and **not** replayed".  Half of that is wrong and the other
    half stops being true once it is.  Reading ``aRandom``'s seed either side
    of every creator shows it **never moves**, and a static sweep of each
    creator's whole closure finds no call to it -- two readings sharing no
    code, both negative.  What the disassembly then shows is a second entry
    point at ``0x004638E0``: ``aRandom``'s body byte for byte over the seed at
    ``0x00514070``, without the call counter.  That is the one the creators
    draw from, and with its seed read either side the draws are a known
    sequence rather than an unknown one.
    """
    seeded = {name: phase for name, phase in captured.items()
              if phase.get("seed2_after") is not None}
    if not seeded:
        ck.check("native.seeds_read", False,
                 "no phase carries a seed pair; re-run the capture")
        return
    ck.check("native.seeds_read", True,
             f"{len(seeded)} of {len(captured)} creators have a seed pair")

    # **The negative reading, and it is the load-bearing one.**
    untouched = [n for n, p in seeded.items()
                 if p["seed_before"] == p["seed_after"]]
    ck.equal("native.arandom_untouched", len(untouched), len(seeded),
             lambda n: f"{n} creator(s) leave aRandom's seed at "
                       f"0x{ARANDOM_SEED:08X} exactly where they found it")

    advances: dict[str, int] = {}
    unresolved: list[str] = []
    for name, phase in sorted(seeded.items()):
        steps = seed_advance(phase["seed2_before"], phase["seed2_after"])
        if steps is None:
            unresolved.append(name)
        else:
            advances[name] = steps
    ck.check("native.draw_counts_recovered", not unresolved,
             f"{len(advances)} creator(s) resolved on the second stream"
             + (f", unresolved {unresolved}" if unresolved else ""))

    silent = sorted(n for n, k in advances.items() if k == 0)
    drawing = {n: k for n, k in advances.items() if k}
    # **The pin is the count.**  How many times a creator turns the handle is
    # a measurement, and it sits beside `blob_tables.py`'s
    # `CREATOR_DRAW_SITES` -- how many call sites its closure *contains* --
    # which is the same quantity read the other way.  A creator with sites and
    # no draws has them on a branch this tile does not take, and that is a
    # result rather than a discrepancy.
    ck.equal("native.creator_draws", advances, CREATOR_DRAWS,
             tables.Checker.brief)
    ck.equal("native.creators_that_draw", len(drawing), CREATORS_THAT_DRAW,
             lambda n: f"{n} creator(s) advance the second stream "
                       f"{sorted(set(drawing.values()))} time(s); "
                       f"{len(silent)} advance neither generator")
    reachable = tables.CREATOR_DRAW_SITES
    idle = sorted(n for n in advances
                  if reachable.get(n, 0) and not advances[n])
    ck.equal("native.draw_sites_not_taken", idle, DRAW_SITES_NOT_TAKEN,
             lambda v: f"{len(v)} creator(s) carry a call to the generator "
                       "on a branch this tile does not reach")

    # A creator that refused the tile is a case, not a hole (the fixture's
    # README says so), and it has no velocities to call replayable -- so the
    # per-creator claim is made about the producers only, and the refusers are
    # counted instead.
    producers = [n for n in silent if captured[n]["records"]]
    ck.equal("native.silent_refusals", len(silent) - len(producers),
             SILENT_REFUSALS,
             lambda n: f"{n} of {len(silent)} creator(s) that draw nothing "
                       "also produced nothing")
    for name in producers:
        records = captured[name]["records"]
        ck.check(f"native.deterministic_{name}", True,
                 f"{len(records)} record(s), no draw: velocities "
                 f"{sorted({(r['vx'], r['vy'], r['vz']) for r in records})[:2]}"
                 f"{' ...' if len(records) > 2 else ''}")

    # **The secondary census, and it is a census rather than a gate.**  A
    # velocity that is `aRandom(base, span)` outright is a straight line in
    # the drawn fraction and can be solved for; one where the creator draws an
    # *angle* and lays down `R * cos` never will be, and calling that a
    # failure would be calling the engine wrong.  So the creators whose
    # velocities are affine in their own draws are counted and pinned, and the
    # rest are UNVERIFIED with the count that is known.
    # **A fitter that never fires is indistinguishable from a broken one.**
    # None of the drawing creators solves, which is a result only if the
    # solver can solve something -- so it is handed a synthetic creator whose
    # velocities *are* `aRandom(base, span)` of its own draws and required to
    # find them.
    ck.check("native.fitter_solves_a_known_case", _fitter_selftest(),
             "a synthetic aRandom(-500, 1000) column is recovered")
    fitted = sorted(n for n, k in drawing.items() if _fit_draws(captured[n], k))
    ck.equal("native.velocities_affine_in_the_draws", fitted, AFFINE_IN_DRAWS,
             lambda v: f"{len(v)} of {len(drawing)} drawing creator(s) have a "
                       "velocity column that solves to (base, span); the rest "
                       "are UNVERIFIED -- the draw count is known, the "
                       "arithmetic on top of it is not")


def _fitter_selftest() -> bool:
    """Build a phase whose velocities are draws, and require :func:`_fit_draws`
    to recover the ``(base, span)`` that made them."""
    from inclib.rng import ARandom
    seed = 1.0
    draws = seed_draws(seed, 12)
    base, span = -500, 1000
    records = [{"vx": int(base + span * f), "vy": 0, "vz": 0}
               for f in draws]
    after = seed
    for _ in range(12):
        after = float(int(after * ARandom.MULTIPLIER) % int(ARandom.MODULUS))
    phase = {"records": records, "seed2_before": seed, "seed2_after": after}
    return _fit_draws(phase, 12) is not None


def _fit_draws(phase: dict[str, Any], steps: int) -> str | None:
    """Whether ``aRandom(base, span)`` explains a creator's velocities.

    ``aRandom`` returns ``int(base + span * fraction)``, so with the fractions
    known a velocity column is a straight line in them.  Two records fix the
    line and the rest test it; a column that needs fewer than three records to
    fit is not claimed, because two points fit any line.
    """
    records = phase["records"]
    draws = seed_draws(phase["seed2_before"], steps)
    if len(records) < 3 or not draws:
        return None
    explained = []
    for axis in ("vx", "vy", "vz"):
        values = [r[axis] for r in records]
        if len(set(values)) < 2:
            continue
        for stride in range(1, 7):
            for offset in range(len(draws)):
                last = offset + stride * (len(values) - 1)
                if last >= len(draws):
                    break
                picks = [draws[offset + stride * i] for i in range(len(values))]
                if picks[0] == picks[1]:
                    continue
                span = (values[1] - values[0]) / (picks[1] - picks[0])
                base = values[0] - span * picks[0]
                if all(abs(int(base + span * f) - v) <= 1
                       for f, v in zip(picks, values)):
                    explained.append(f"{axis}=aRandom({base:.0f},{span:.0f})"
                                     f"@{offset}+{stride}i")
                    break
            else:
                continue
            break
    return ", ".join(explained) if explained else None


def _agrees(got: set, want: set) -> bool:
    """Whether every engine triple matches a static one.

    A static field of ``None`` is "the arm computes it" (docs/28 7.7), and a
    computed value must not be read as a mismatch -- nor as a wildcard that
    makes the check vacuous, which is why the *other* two fields still have to
    line up on the same call.
    """
    if not got:
        return False
    for cls, kind, life in got:
        if not any((w_cls is None or w_cls == cls)
                   and (w_kind is None or w_kind == kind)
                   and (w_life is None or w_life == life)
                   for w_cls, w_kind, w_life in want):
            return False
    return True


def creator_bodies(binary: "tables.Binary", creator: int,
                   creators: set[int], entries: list[int]) -> set[int]:
    """*creator* and every creator its body reaches, transitively."""
    seen, stack = {creator}, [creator]
    while stack:
        for nxt in binary.arm_calls(stack.pop(), creators, entries,
                                    CREATOR_EXTENT):
            if nxt not in seen:
                seen.add(nxt)
                stack.append(nxt)
    return seen


def _creator_of_call(binary: "tables.Binary") -> dict[int, int | None]:
    """Constructor call site -> the creator whose body contains it."""
    import bisect
    entries = sorted(binary.call_entries())
    out: dict[int, int | None] = {}
    for site in tables.BLOB_CALLS:
        index = bisect.bisect_right(entries, site) - 1
        out[site] = entries[index] if index >= 0 else None
    return out


def _report(ck: "tables.Checker") -> int:
    LOG.warning("%d checks, %d passed, %d failed",
                len(ck.names), ck.passed, ck.failed)
    return 1 if ck.failed else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--game-copy", type=Path,
                    help="a copy of the game holding Work/Saves2/_6_.sav")
    ap.add_argument("--dbgcall", type=Path, help="the built dbgcall.exe")
    ap.add_argument("--check", metavar="ROOT",
                    help="re-run the models against the capture")
    ap.add_argument("--fixture", type=Path, default=FIXTURE)
    ap.add_argument("--attempts", type=int, default=gold.DEFAULT_ATTEMPTS)
    ap.add_argument("--probe-startup", type=int, metavar="N",
                    help="run one plan N times with a single attempt each and "
                         "report how often Wine reached the anchor "
                         "(docs/91 1); needs --game-copy and --dbgcall")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING,
                        format="%(levelname)s: %(message)s")
    if args.check:
        return run_checks(args.check, args.fixture)
    if not args.game_copy or not args.dbgcall:
        ap.error("--game-copy and --dbgcall, or --check")
    if args.probe_startup:
        return probe_startup(args.game_copy.resolve(), args.dbgcall,
                             args.probe_startup)
    repo = Path(__file__).resolve().parent.parent
    copy = args.game_copy.resolve()
    if repo in copy.parents or copy == repo:
        raise SystemExit(f"{copy} is inside this repository; the capture must "
                         "run from a copy of the game, never from "
                         "gog_incubation/")
    save = copy / "Work" / "Saves2" / f"_{gold.CAPTURE_SLOT}_.sav"
    if not save.is_file():
        raise SystemExit(f"the copy needs {save}")
    if not args.dbgcall.is_file():
        raise SystemExit(f"no dbgcall at {args.dbgcall}")
    return capture(str(repo / "gog_incubation"),
                   args.game_copy, args.dbgcall, args.fixture, args.attempts)


if __name__ == "__main__":
    raise SystemExit(main())

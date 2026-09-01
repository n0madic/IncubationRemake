#!/usr/bin/env python3
"""Native capture of the blob **creators** -- ``docs/28`` §7.6, and the one
part of the effect layer no static reading reaches.

``docs/28`` §8.1's three weapon switches say *which* creator a shot runs and
``blob_tables.py`` extracts, for every one of the 116 constructor calls inside
them, the class, the update kind, the literal lifetime, the model and the atlas
tile.  What none of that gives is the **creators' own argument arithmetic**:
where each one places its blob and what velocity it hands it.  Those thirty
functions read the control map, the symbol objects and the unit map through the
five helpers ``docs/28`` §12.1 records as *not natively validated*, so
transcribing them statically would produce trajectories that look authoritative
and could not be checked.

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
#: It is not.  With one creator per plan, a plan still fails now and then, and
#: what the log says when it does is `exception 0xc0000005 at 0x7bf2123d`
#: inside a Wine system DLL, **before the anchor** -- so before a single line
#: of the plan has run and whatever the plan contains.  That is `docs/91`
#: §1's start-up intermittency exactly, the original attribution was right,
#: and the group-boundary alignment stays **unexplained**.
#:
#: One creator per plan is still the right size, for the reason that survives
#: either explanation: a plan that dies takes down every creator sharing its
#: process, so five per plan turns one bad start into a fifth of the capture
#: while one per plan turns it into one retryable creator.
GROUP_SIZE = 1


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
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING,
                        format="%(levelname)s: %(message)s")
    if args.check:
        return run_checks(args.check, args.fixture)
    if not args.game_copy or not args.dbgcall:
        ap.error("--game-copy and --dbgcall, or --check")
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

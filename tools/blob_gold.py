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
import struct
import sys
from pathlib import Path
from typing import Any, Sequence

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

#: **What the five actually are.**  They were "read as bytes and not matched
#: to an export" for exactly as long as nobody looked at the string the
#: resolver pushes: `Incubation.exe` calls `GetProcAddress` with the ordinal
#: written out as **decimal text**, so `push 0x004BF9F8` is the literal `"13"`
#: and the export table of `Eng3d.dll` finishes the sentence.  Three readings
#: agree and none of them shares a step with the others -- the literal in the
#: caller, the export table in the callee, and the captured thunk bytes, which
#: occur once in the shipped DLL and at exactly that export's RVA.
POINTER_ORDINALS = {
    0x004FA4E4: 13,   # _E3D_init_matrix_RzRxRy
    0x004F84D4: 15,   # _E3D_c_rotate_coordinate
    0x004FA4E0: 27,   # _E3D_calc_angle_dx_dy
    0x004F84D8: 28,   # _E3D_fsin
    0x004FA4DC: 29,   # _E3D_fcos
}
POINTER_EXPORTS = {
    13: "_E3D_init_matrix_RzRxRy",
    15: "_E3D_c_rotate_coordinate",
    27: "_E3D_calc_angle_dx_dy",
    28: "_E3D_fsin",
    29: "_E3D_fcos",
}
#: The neighbouring builder, and the reason it is worth a check of its own.
#: `docs/30` §2.5 item 7 concluded from the joint opcodes that both matrix
#: builders the shipped data reaches build `RzRxRy`; the export table says the
#: other ordering **exists** and the call graph says nothing calls it.  Note
#: the resolver does fill its slot -- it resolves 86 of the DLL's 89 ordinals
#: unconditionally -- so "unresolved" would have been the wrong claim and
#: "never called" is the right one.
ENG3D_UNCALLED_ORDINAL = 14
ENG3D_UNCALLED_EXPORT = "_E3D_init_matrix_RyRxRz"
ENG3D_UNCALLED_GLOBAL = 0x004FA4A0
#: How many of `Eng3d.dll`'s exports the start-up resolver asks for by ordinal.
ENG3D_RESOLVED_ORDINALS = 86

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


#: **The whole pool, ticked.**  `aCheckInBlobObjects` `0x0041E3D0` is what a
#: frame calls: it sweeps the twenty emitter slots, then walks all 450 records
#: and hands each to `0x0041E500` -- the wrapper `tools/blob_runtime.py`
#: transcribes.  It takes no arguments, so calling it in the live process is
#: one line and steps *the engine's own* arms over the pool a creator left.
#: That is the difference between diffing two transcriptions and diffing a
#: transcription against the thing.
POOL_TICK = 0x0041E3D0
#: The record count its loop walks, read out of the `cmp edi, 0x1C2`.
POOL_TICK_RECORDS = 450
#: How many times the sweep is called per capture.  Long enough for a delay to
#: expire, a life to run out and a morph to fire; short enough that one plan
#: is one process's worth of work.
TICK_ROUNDS = 8


def ticks_plan(handle: int, creator: int, args: list[int]) -> str:
    """Populate the pool with one creator, then tick the engine's own sweep.

    The records are read **before** the first tick and after every one, so the
    diff has the engine's own starting state rather than the model's idea of
    it -- a comparison that seeded itself from the model would be a
    transcription against a transcription with extra steps.

    The second generator's seed is read beside every round for the same reason
    it is read around a creator: an arm that draws has to draw the same number
    of times, and the seed delta is the only thing that says so.
    """
    entry = _entry_address(handle)
    signature = ",".join("i32" for _ in args)
    read = (f" --read [0x{entry:x}]:{READ_RECORDS * RECORD_BYTES}"
            f" --read 0x{ARANDOM_SEED:x}:{ARANDOM_SEED_BYTES}"
            f" --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}")
    lines = [
        "# One creator's pool, stepped by the engine's own frame sweep.",
        DECLARATIONS,
        f"__cdecl i32 aCheckInBlobObjects() = Incubation.exe+0x{POOL_TICK - 0x400000:x}",
        f"__cdecl i32 c{creator:08X}({signature})"
        f" = Incubation.exe+0x{creator - 0x400000:x}",
        "",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "reset = aResetBlobs()",
        f"c{creator:08X}({', '.join(str(a) for a in args)})",
        f"aGetUnitMapElementPtr(0){read}",
    ]
    for _round in range(TICK_ROUNDS):
        lines.append(f"aCheckInBlobObjects(){read}")
    return "\n".join(lines) + "\n"


#: `aBlob_Update` itself -- the per-record wrapper the sweep calls, and the
#: one `tools/blob_runtime.py` transcribes line for line.  Arguments are
#: `(index, blob)`: the sweep pushes `esi` then `edi`, so the **last** push is
#: the first argument and it is the index.
BLOB_ARM = 0x0041E500
#: Why there are two tick families rather than one.  `aCheckInBlobObjects`
#: hands every non-sprite record to Eng3d's `0x00403CC0` before it ticks it,
#: and outside an open render frame that faults -- deterministically, on the
#: first sweep, for any creator whose records are class 0.  The check-in is
#: **not part of the arm**, so calling `0x0041E500` per record skips it and is
#: the more precise measurement of the two; the sweep family is kept for the
#: sprite creators because it also exercises the pool walk and the emitter
#: pass around them.
#:
#: Calling the wrapper on a record that has already deleted itself is safe and
#: was checked before it was relied on: an all-zero record has delay 0 and
#: life 0, which takes the expiry path at `0x004207F8`, which calls
#: `0x0041E320` with the **index** and writes the same zero back.


def arms_plan(handle: int, creator: int, args: list[int],
              slots: list[int]) -> str:
    """Populate the pool, then call `aBlob_Update` per record per round.

    The slot list comes from the creator's own captured records, so the plan
    ticks what that creator actually filled.  The expression grammar has no
    multiplication, so each record's address is emitted as a literal offset
    from the pool block at plan-generation time.
    """
    entry = _entry_address(handle)
    signature = ",".join("i32" for _ in args)
    read = (f" --read [0x{entry:x}]:{READ_RECORDS * RECORD_BYTES}"
            f" --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}")
    lines = [
        "# One creator's pool, stepped by the engine's own aBlob_Update.",
        DECLARATIONS,
        f"__cdecl i32 aBlob_Update(i32,ptr) = Incubation.exe+0x{BLOB_ARM - 0x400000:x}",
        f"__cdecl i32 c{creator:08X}({signature})"
        f" = Incubation.exe+0x{creator - 0x400000:x}",
        "",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "reset = aResetBlobs()",
        f"c{creator:08X}({', '.join(str(a) for a in args)})",
        f"aGetUnitMapElementPtr(0){read}",
    ]
    for _round in range(TICK_ROUNDS):
        for slot in slots[:-1]:
            lines.append(f"aBlob_Update({slot},"
                         f" [0x{entry:x}]+0x{RECORD_BYTES * slot:x})")
        last = slots[-1]
        lines.append(f"aBlob_Update({last},"
                     f" [0x{entry:x}]+0x{RECORD_BYTES * last:x}){read}")
    return "\n".join(lines) + "\n"


#: The donor whose pool the poked phases borrow.  It has to fill its slots
#: with **class 0** records that carry a model handle, because an arm that
#: poses a model or swaps one dereferences it: a class-2 donor would turn every
#: such arm into a fault rather than a comparison.  `aBlob_SparkingPlug` is the
#: one reachable creator that does, and its own arm (index 20) is already
#: native, so nothing about the donor is being taken on trust.
POKE_DONOR = 0x0042ACF0
#: How many rounds a poked plan steps each record.  It was four until a
#: mutation battery pointed out what four rounds of a donor's `life` of 30
#: cannot reach: kind 76 branches on `life <= 4` and that branch was being
#: transcribed and never run.  Eight rounds and a poked `life` of six reach
#: both sides of every such gate, and the last rounds reach `life == 0`,
#: which is where the terminal arms spawn, morph and hand the record back.
POKE_ROUNDS = 8
#: The life every poked record is given, written in the same pass as the kind.
#: Six is chosen so four rounds see `life > 4` and four see it at or below --
#: kind 76 branches there and a battery caught the branch going unexercised --
#: and so the last rounds reach `life == 0`, which is where the terminal arms
#: spawn, morph and hand the record back to the wrapper.
POKE_LIFE = 6
#: The second vector's life.  Twelve, with fourteen rounds, is the shortest
#: pair that reaches **both** `life == 10` -- kind 43's and kind 65's gate --
#: and `life == 0`, which is where the terminal arms spawn.  One vector cannot
#: do both at eight rounds, which is why there are two.
POKE_LIFE_LONG = 12
POKE_ROUNDS_LONG = 14
#: Slots per plan.  One plan is one process, so this is also how many unknown
#: arms share a fate.
POKE_SLOTS = 6


#: `0x004038F0` -- the model lookup two arms call, and the three names they
#: can ask for.  `docs/28` §7.5: it answers `-1` for a model the world set
#: does not carry, and the arm then leaves the record alone.
MODEL_LOOKUP = 0x004038F0

#: Every model name the ten transcribed creators pass to the constructor,
#: collected from their own instructions.  The two swap arms' three names are
#: `blob_runtime.CASE_MODELS`; these are the creators', and the phase asks the
#: engine for both sets in one process -- a creator's record carries the
#: handle, so a transcription that guessed one would be comparing an invented
#: index against a measured one (`docs/97` §20.5's rule, applied again).
CREATOR_MODELS = (
    "A_BLASER.3DI", "A_BLIZ01.3DI", "A_BLIZ02.3DI", "A_BLIZ03.3DI",
    "A_CASE.3DI", "A_LASERG.3DI", "A_LINE5.3DI", "A_LINE6.3DI",
    "A_PLSMA1.3DI", "A_SPARK.3DI",
)

#: The same, for the twelve creators an update **arm** calls (`docs/97` §49).
#: They are a separate tuple rather than more entries above because they are
#: reached from a different place -- no weapon switch names them -- and
#: because adding a name here is what re-takes the `models` phase.
ARM_CREATOR_MODELS = (
    "A_DEBRIS.3DI", "A_EXPL04.3DI", "A_FUNKE.3DI", "A_HIT1.3DI",
    "A_LINE2.3DI", "A_PARAB1.3DI",
)


def _model_names() -> tuple[str, ...]:
    """The two swap arms' names and the creators', in one stable order."""
    import blob_runtime
    return (tuple(blob_runtime.CASE_MODELS) + CREATOR_MODELS
            + ARM_CREATOR_MODELS)


def models_plan(names: Sequence[str]) -> str:
    """Ask the engine what handle each swappable model name has.

    The two swap arms (kinds 16 and 17) store `0x004038F0`'s answer straight
    into `+0x0C`, so a diff of their records is a diff of this service.  The
    fixture's adapter answers with an index into its own list -- fine for
    comparing two transcriptions, useless for comparing one against the
    engine -- so the check resolves the name through **this** measurement
    instead, exactly as the seekers' target is resolved through the object
    sweep rather than assumed.
    """
    lines = [
        "# The model lookup, one call per name a swap arm can ask for.",
        DECLARATIONS,
        f"__cdecl i32 aGetModelIndex(ptr) = Incubation.exe+0x{MODEL_LOOKUP - 0x400000:x}",
    ]
    for index, name in enumerate(names):
        lines.append(f"--blob mn{index}:{(name + chr(0)).encode('ascii').hex()}")
    lines += ["", "aSetSaveMode(0)", f"loaded = aLoadGame({gold.CAPTURE_SLOT})"]
    for index in range(len(names)):
        lines.append(f"aGetModelIndex(&mn{index})")
    return "\n".join(lines) + "\n"


def parse_models(rows: list[dict[str, Any]],
                 names: Sequence[str]) -> dict[str, int]:
    """``name -> handle``, in call order."""
    out: dict[str, int] = {}
    calls = [row for row in rows
             if row.get("call") == "aGetModelIndex" and row.get("status") == "ok"]
    for name, row in zip(names, calls):
        out[name] = int(row["eax"], 16) - (1 << 32) \
            if int(row["eax"], 16) & 0x80000000 else int(row["eax"], 16)
    return out


#: The unit record byte the three seeking arms take their object id from,
#: and the whole-array read that makes it readable.  `docs/28` §7.7.1: an arm
#: loads its record's `+0x54` as a unit-map slot, asks `aGetUnitMapElementPtr`
#: for that unit and takes **this** byte out of the record it gets back.
#: Until this phase existed the byte had never been read, and the object the
#: capture's seekers steer at was known only by elimination -- which is a
#: weaker claim than it looks, because the unit array of `_6_.sav` makes slot
#: and id equal for its first twelve units and **not** for the rest.
UNIT_OBJECT_FIELD = 0x4B


def units_plan() -> str:
    """Read the whole unit array, for one byte of each record.

    Deliberately **not** folded into `state_plan`.  That phase's other output
    is the pool's base, which is a heap address and moves between runs, and
    `slot_tag` -- the low byte kinds 25 and 56 branch on -- is derived from
    it, so re-taking `state` to gain a field would silently re-base every
    tick phase already captured.  A read-only phase of its own costs one
    process and cannot do that.
    """
    return "\n".join([
        "# The unit array, read for +0x4B: the object id a seeking arm steers",
        "# at.  Read-only, and separate from `state` on purpose -- see",
        "# units_plan.",
        DECLARATIONS,
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        f"u0 = aGetUnitMapElementPtr(0)"
        f" --read $u0:{gold.UNIT_SLOTS * gold.UNIT_STRIDE}",
    ]) + "\n"


def parse_units(rows: list[dict[str, Any]]) -> list[dict[str, int]]:
    """Every live unit's slot, tile and **object id**, from the array read."""
    blob = b""
    for row in rows:
        for key, text in (row.get("reads") or {}).items():
            if key.startswith("$u0") and "<" not in text:
                blob = _hex_bytes(text)
    out: list[dict[str, int]] = []
    for slot in range(gold.UNIT_SLOTS):
        raw = blob[slot * gold.UNIT_STRIDE:(slot + 1) * gold.UNIT_STRIDE]
        if len(raw) < gold.UNIT_STRIDE or raw[gold.UNIT_NAME] == 0:
            continue
        out.append({"slot": slot, "x": raw[gold.UNIT_X], "y": raw[gold.UNIT_Y],
                    "player": raw[gold.UNIT_PLAYER],
                    "type": raw[gold.UNIT_TYPE],
                    "object": raw[UNIT_OBJECT_FIELD]})
    return out


def poked_arms() -> list[tuple[int, int]]:
    """``(arm, kind)`` for every arm no creator a weapon switch selects fills.

    The kind is the **lowest** one that maps to the arm, so the choice is a
    property of the jump table rather than of this run.  The eleven kinds
    `docs/28` §7.7 calls unreachable are eligible here on purpose: poking is
    the only thing that can step them, and stepping one says what its arm
    does without saying anything about whether the shipped game reaches it.
    """
    arm_of = _arm_of_kind()
    first: dict[int, int] = {}
    for kind in sorted(arm_of):
        first.setdefault(arm_of[kind], kind)
    return [(arm, kind) for arm, kind in sorted(first.items())
            if arm not in TICK_ARMS_SEEN]


#: **The input vectors every poked arm is stepped at.**  One vector is one
#: point of an arm's input space, and one point exercises one path: the first
#: pass reached 341 of the 385 transcribed lines of the seventy-four arms and
#: left the rest untouched, which is a coverage figure and not a bug.  So the
#: sweep is run again with a second vector chosen against that measurement --
#: a longer life, so `life == 10` and `life == 0` are both reached inside one
#: plan, and an `aux` of 10, which is kind 74's gate.  `docs/97` §21.
#:
#: It **used** to zero `vx` as well, which is the only thing that reaches
#: kind 41's other branch, and that is how this experiment found out there is
#: no such branch: the engine's arm is `mov eax, 0x200 / cdq / idiv [esi+0x48]`
#: with nothing in front of it, so a record with no `vx` divides by zero and
#: `Incubation.exe` dies.  It did, at slot 3 of `poked_v1_04`, after the three
#: arms before it had been measured.  The guard in `blob_runtime._kind_41` is
#: the **port's**, not the engine's, and the write was removed because a plan
#: that faults costs the arms after it -- not because the answer was
#: unwelcome.  `docs/97` §21.2.
#:
#: The name prefix is empty for the first, so the phases the earlier capture
#: already holds keep their names and are **not** re-taken.
POKE_VECTORS: tuple[dict[str, Any], ...] = (
    {"name": "", "writes": {"life": POKE_LIFE}, "rounds": POKE_ROUNDS},
    {"name": "v1_", "writes": {"life": POKE_LIFE_LONG, "aux": 10},
     "rounds": POKE_ROUNDS_LONG},
)
#: How many rounds a probe plan steps its records.  Long enough that a life of
#: twelve reaches zero, which is where the terminal branches are.
POKE_PROBE_ROUNDS = POKE_ROUNDS_LONG

#: The one plan that writes something outside the pool.  Kind 59 at two donor
#: slots under the two sweep vectors, with the output-system mode held at
#: `EMITTER_MODE_SPECIAL` for its length -- the arm's other half, which no
#: record can select.  It is its own plan for the same reason every creator
#: is: a plan that dies takes the arms sharing its process with it, and this
#: one writes engine state the others do not.
MODE_PHASE = "mode_59"
MODE_VECTORS: tuple[dict[str, int], ...] = (
    {"life": POKE_LIFE},
    {"life": POKE_LIFE_LONG, "aux": 10},
)
MODE_ROUNDS = POKE_ROUNDS_LONG


def poke_probes(target: tuple[int, int, int] | None
                ) -> list[tuple[int, int, dict[str, int]]]:
    """The vectors that reach the last few lines, one arm at a time.

    Everything a *sweep* vector can reach, a sweep vector does; these five are
    the residue of that measurement, and each names the branch it is for:

    * kinds 26 and 61 with `aux` naming a **dead** unit slot -- 14, whose
      `+0x4B` names an object `aGetStdObjectPosition` refuses -- reach the
      early return `docs/28` §7.7.1 calls `target_missing`.  That slot is not
      invented: the `units` phase reads it.
    * kind 75 with the same `aux`, which is its `aux > 2` spawn.
    * kind 65 with a life of sixty, which is the `life >= 0x28` return, and
      again with position and velocity zeroed, which is the near half of its
      distance test -- the only branch in the seventy-four that needs the
      record's *position* rather than a counter.
    * kinds 26 and 61 placed **on** the object they steer at, which is the
      arrival branch: `_seek` writes `life = 0` and the arm spawns.
    """
    probes: list[tuple[int, int, dict[str, int]]] = [
        (25, 26, {"life": 12, "aux": UNIT_OBJECT_DEAD_SLOT}),
        (58, 61, {"life": 12, "aux": UNIT_OBJECT_DEAD_SLOT}),
        (71, 75, {"life": 12, "aux": UNIT_OBJECT_DEAD_SLOT}),
        (62, 65, {"life": 60}),
        (62, 65, {"life": 12, "x": 0, "y": 0, "z": 0,
                  "vx": 0, "vy": 0, "vz": 0}),
        # Three arms whose spawn sits behind `life == 0`.  Their creators
        # give them a life the eight and nine rounds of a tick phase cannot
        # run out, so the branch was transcribed and never stepped; a poked
        # twelve reaches it.  Kind 75's needs `aux <= 2` as well, which is
        # the *other* side of the gate the dead-slot probe above takes.
        (42, 44, {"life": 12}),
        (45, 47, {"life": 12}),
        (71, 75, {"life": 12, "aux": 1}),
    ]
    if target is not None:
        arrival = {"life": 12, "aux": SEEK_UNIT_SLOT,
                   "x": target[0], "y": target[1], "z": target[2],
                   "vx": 0, "vy": 0, "vz": 0}
        probes += [(25, 26, dict(arrival)), (58, 61, dict(arrival))]
    return probes


def poked_batches(donor_slots: list[int], vector: dict[str, Any]
                  ) -> list[list[tuple[int, int, dict[str, int]]]]:
    """The poked arms under one vector, cut into one plan's worth each."""
    slots = donor_slots[:POKE_SLOTS]
    pairs = poked_arms()
    writes = vector["writes"]
    out: list[list[tuple[int, int, dict[str, int]]]] = []
    for start in range(0, len(pairs), len(slots)):
        group = pairs[start:start + len(slots)]
        out.append([(slot, kind, dict(writes))
                    for slot, (_arm, kind) in zip(slots, group)])
    return out


def probe_batches(donor_slots: list[int],
                  probes: list[tuple[int, int, dict[str, int]]]
                  ) -> list[list[tuple[int, int, dict[str, int]]]]:
    """The probe vectors, cut into one plan's worth of slots each."""
    slots = donor_slots[:POKE_SLOTS]
    out: list[list[tuple[int, int, dict[str, int]]]] = []
    for start in range(0, len(probes), len(slots)):
        group = probes[start:start + len(slots)]
        out.append([(slot, kind, writes)
                    for slot, (_arm, kind, writes) in zip(slots, group)])
    return out


# --------------------------------------------------------------------------
# The arms that spawn: what a creator is *given*
# --------------------------------------------------------------------------

#: How many records the two spawning families read back.  The donor fills
#: **thirty** slots and a child lands in the first free one past them, so the
#: `READ_RECORDS` window every other pool read uses comes back holding no
#: child at all -- which is what the first run of this family measured.
#: Forty-four leaves fourteen for a brood, and three of the thirteen creators
#: make more than that (`0x0042A7A0` a hundred, `0x0042B300` and `0x00429390`
#: twenty each): those are compared as the **prefix** they are, with the
#: generator's seed after the call accounting for the records past it.
SPAWN_READ_RECORDS = 44
#: Rounds and life, the poked family's -- a spawn behind `life == 0` is
#: reached by the same eight rounds that reach every other terminal branch.
SPAWN_ROUNDS = POKE_ROUNDS

#: **The two seeds a spawning arm is stepped under.**  `docs/97` §48 read two
#: jitters out of the bytes and could not tell them apart by measurement: kind
#: 56 adds the coordinate to the draw and truncates the sum (`fiadd`), kind 77
#: truncates the draw and adds the coordinate (`movsx`), and the two agree
#: everywhere except where the draw is **negative with a fraction** -- there
#: they differ by exactly one.  The engine's own seed comes from
#: `GetTickCount()`, so whether a capture lands on such a draw is luck; these
#: two are chosen instead.  Under 6.0 every one of the three jitters both arms
#: take is negative and fractional, so every coordinate discriminates; under
#: 2.0 every one is positive, which is the same arms on the side where the two
#: readings agree.  Both are pinned rather than searched for at capture time:
#: a seed the check did not know could not be replayed.
SPAWN_SEED_NEGATIVE = 6.0
SPAWN_SEED_POSITIVE = 2.0
SPAWN_SEEDS = (SPAWN_SEED_NEGATIVE, SPAWN_SEED_POSITIVE)

#: The seven arms that ask for `0x00423720`, the zoom bob -- `docs/97` §48's
#: table, and the reason this family exists.  Each is stepped under both
#: seeds.
ZOOM_BOB_KINDS = (6, 15, 26, 56, 69, 73, 77)
ZOOM_BOB_PREFIX = "zoom_bob_"
#: Every other arm that asks a creator for something.  One seed each: their
#: creators' arguments are integers the arm computes, and the second seed
#: buys nothing there -- it is the two jitters above that need both signs.
SPAWN_OTHER_KINDS = (3, 19, 22, 25, 32, 36, 44, 47, 52, 59, 62, 67, 71, 75)
SPAWN_PREFIX = "spawn_"
#: Kind 26 is a **seeker** and spawns only when it arrives, so it is stepped
#: at `poke_probes`' arrival vector rather than the sweep's -- the same
#: recipe, named once and used twice.
SPAWN_ARRIVAL_KINDS = (26,)
#: An arm whose spawn is behind a **roll** needs a seed that passes it, and
#: the two above do not: kind 52 asks `aRandom2(0, 8)` for a zero and drops a
#: para bomb only then, so a seed of 1.0 -- whose first draw is that zero --
#: is what reaches `0x0042B150` at all.  Written down rather than searched
#: for at capture time, so the check can replay it.
#:
#: Kind 62's is the other: its spark burst is behind `aRandom2(0, 10) > 5.0`
#: and 6.0's first draw is 1.73, so the branch never ran and its jitter went
#: unmeasured while the note beside it said otherwise.  19.0 rolls 5.49 and
#: then three **negative fractional** jitters, which is both halves at once --
#: the branch taken and the arithmetic discriminated.
SPAWN_SEED_OVERRIDES: dict[int, float] = {52: 1.0, 62: 19.0}


def spawn_entries(kinds: Sequence[int], seeds: Sequence[float],
                  target: tuple[int, int, int] | None
                  ) -> list[tuple[int, dict[str, int], float]]:
    """`(kind, vector, seed)` for one family, in a stable order.

    The seeds vary **inside** a kind rather than across the list so a plan
    that dies loses both readings of one arm rather than one reading of every
    arm -- the same reason every creator gets a plan of its own.
    """
    out: list[tuple[int, dict[str, int], float]] = []
    for kind in kinds:
        vector: dict[str, int] = {"life": POKE_LIFE}
        if kind in SPAWN_ARRIVAL_KINDS and target is not None:
            vector |= {"aux": SEEK_UNIT_SLOT, "vx": 0, "vy": 0, "vz": 0,
                       "x": target[0], "y": target[1], "z": target[2]}
        for seed in seeds:
            out.append((kind, dict(vector),
                        SPAWN_SEED_OVERRIDES.get(kind, float(seed))))
    return out


def spawn_batches(entries: Sequence[tuple[int, dict[str, int], float]]
                  ) -> list[list[tuple[int, dict[str, int], float]]]:
    """One family's entries, cut into one plan's worth each.

    An entry is a whole pool of its own here rather than a slot in a shared
    one, so the batch size is about how much a single process should carry
    and not about how many donor records there are: a plan that dies takes
    every entry after it, and six is what the poked family settled on.
    """
    return [list(entries[start:start + POKE_SLOTS])
            for start in range(0, len(entries), POKE_SLOTS)]


def spawn_plan(handle: int, donor: int, args: list[int], slot: int,
               entries: Sequence[tuple[int, dict[str, int], float]],
               rounds: int) -> str:
    """One **fresh pool per entry**: reset, donor, poke, then step one arm.

    The poked family shares one pool across a plan's six records, which is
    right when what is being measured is the records themselves.  It is wrong
    here.  A spawning arm's children go into the pool as well, and one arm's
    brood can be a hundred records (`0x0042A7A0`): the read window fills, the
    next arm's child lands past its end, and the comparison silently stops
    finding children -- which is exactly what the first run of this family
    did, from round two onward.

    So every entry opens with `aResetBlobs` and a fresh call to the donor,
    and only one record is poked.  Whatever is past the donor's own slots
    afterwards is **this** arm's, and the window has to hold one round of one
    brood rather than eight rounds of six.  A brood bigger than the window --
    the hundred streaks -- is compared as the prefix it is, with the seed
    read either side of every call saying how many draws the rest took.
    """
    entry = _entry_address(handle)
    signature = ",".join("i32" for _ in args)
    read = (f" --read [0x{entry:x}]:{SPAWN_READ_RECORDS * RECORD_BYTES}"
            f" --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}")
    seed_read = f" --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}"
    lines = [
        "# One pool per entry -- reset, donor, poke, step.  See spawn_plan:",
        "# a shared pool loses every child past the read window.",
        DECLARATIONS,
        f"__cdecl i32 aBlob_Update(i32,ptr) = Incubation.exe+0x{BLOB_ARM - 0x400000:x}",
        f"__cdecl i32 c{donor:08X}({signature})"
        f" = Incubation.exe+0x{donor - 0x400000:x}",
        MEMCPY_DECL,
    ]
    for index, (kind, vector, seed) in enumerate(entries):
        for run, (_offset, raw) in enumerate(poke_writes(kind, vector)):
            lines.append(f"--blob pk{index}_{run}:{raw.hex()}")
        lines.append("--blob sd%d:%s"
                     % (index, struct.pack("<d", float(seed)).hex()))
    lines += ["", "aSetSaveMode(0)", f"loaded = aLoadGame({gold.CAPTURE_SLOT})"]
    for index, (kind, vector, _seed) in enumerate(entries):
        lines.append("")
        lines.append(f"# kind {kind} at slot {slot}")
        lines.append("reset = aResetBlobs()")
        lines.append(f"c{donor:08X}({', '.join(str(a) for a in args)})")
        for run, (offset, raw) in enumerate(poke_writes(kind, vector)):
            lines.append(
                f"memcpy([0x{entry:x}]+0x{RECORD_BYTES * slot + offset:x},"
                f" &pk{index}_{run}, {len(raw)})")
        lines.append(f"memcpy(0x{ARANDOM2_SEED:x}, &sd{index},"
                     f" {ARANDOM_SEED_BYTES}){seed_read}")
        lines.append(f"aGetUnitMapElementPtr(0){read}")
        for _round in range(rounds):
            lines.append(f"memcpy(0x{ARANDOM2_SEED:x}, &sd{index},"
                         f" {ARANDOM_SEED_BYTES}){seed_read}")
            lines.append(f"aBlob_Update({slot},"
                         f" [0x{entry:x}]+0x{RECORD_BYTES * slot:x}){read}")
    return "\n".join(lines) + "\n"


def parse_spawn(rows: list[dict[str, Any]], entry: int) -> dict[str, Any]:
    """One `{start, steps, written}` per entry, split on the pool resets.

    A plan that faulted part way simply has fewer entries, and an entry that
    faulted mid-round fewer steps -- the check counts both rather than
    assuming a rectangle, the same way :func:`parse_poked` does.
    """
    key = f"[0x{entry:x}]"
    seed_key = f"0x{ARANDOM2_SEED:x}"
    out: list[dict[str, Any]] = []
    for row in rows:  # noqa: PLR1702 -- one pass, four row kinds
        if row.get("status") != "ok":
            continue
        reads = row.get("reads") or {}
        text = reads.get(seed_key)
        seed = (struct.unpack_from("<d", _hex_bytes(text), 0)[0]
                if text and "<" not in text else None)
        if row.get("call") == "aResetBlobs":
            out.append({"start": None, "steps": [], "written": []})
            continue
        if not out:
            continue
        if row.get("call") == "memcpy" and key not in reads:
            if seed is not None:
                out[-1]["written"].append(seed)
            continue
        if key not in reads or "<" in reads[key]:
            continue
        shot = {"pool": reads[key].replace(" ", ""), "seed": seed}
        if row.get("call") == "aBlob_Update":
            out[-1]["steps"].append(shot)
        elif out[-1]["start"] is None:
            out[-1]["start"] = shot
    for item in out:
        _fill_born(item)
    return {"entries": out}


def _fill_born(entry: dict[str, Any]) -> None:
    """Give every step the records that **appeared** in it, already parsed.

    The pools are stored as raw hex because a snapshot after a tick is not a
    contiguous run of live records and `parse_records` would stop at the first
    free slot.  What a reader of this family wants is the difference, though,
    and one of them is a GDScript suite: writing it here keeps the record
    layout of `docs/28` §7.2 read in one place rather than two.
    """
    start = entry.get("start")
    if not start:
        return
    previous = parse_slots(bytes.fromhex(start["pool"]))
    for step in entry.get("steps") or []:
        current = parse_slots(bytes.fromhex(step["pool"]))
        step["born"] = [record for slot, record in enumerate(current)
                        if record is not None and previous[slot] is None]
        step["full"] = all(record is not None for record in current)
        previous = current


#: `aGetSymbolObjectPtr` and the unit-height helper the creators open with.
#: Every one of the ten unexplained creators starts the same way: the tile
#: argument through `aGetCtrlMapElementPtr`, the cell's `+5` through this
#: lookup for the **placed object**, and the cell's `+7` through the unit map
#: for a height.  `docs/97` §22.
SYMBOL_OBJECT = 0x00404C40
UNIT_HEIGHT = 0x0047AD30
#: Where the cell names its object and its unit.
CELL_OBJECT = 0x05
CELL_UNIT = 0x07


def origins_plan() -> str:
    """Everything a creator reads before it draws anything.

    Read-only, one process, and separate from `state` for the same reason
    `units` is: `state` also yields the pool's base, which moves between runs.

    The object array is read **raw**, not through `aGetStdObjectPosition`:
    the creators load `+0x10/+0x14/+0x18` out of the record themselves, and
    those are not what the position service returns -- the service answers
    160 for a z the record holds as 0.  A transcription fed the service's
    answer would be out by that much on every record it places.
    """
    cells = gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT * gold.CELL_STRIDE
    objects = HOOK_ID_LIMIT * OBJECT_STRIDE
    return "\n".join([
        "# The creators' own inputs: the control map, the object array as the",
        "# records hold it, and the unit height helper for both tiles.",
        DECLARATIONS,
        f"__cdecl ptr aGetSymbolObjectPtr(i32) = Incubation.exe+0x{SYMBOL_OBJECT - 0x400000:x}",
        f"__cdecl i32 aGetUnitHeight(ptr)      = Incubation.exe+0x{UNIT_HEIGHT - 0x400000:x}",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        f"c0 = aGetCtrlMapElementPtr(0,0) --read $c0:{cells}",
        f"objects = aGetSymbolObjectPtr(0)"
        f" --read [0x{OBJECT_TABLE:x}]:{objects}",
        "u0 = aGetUnitMapElementPtr(0)",
        "h0 = aGetUnitHeight($u0)",
        "u1 = aGetUnitMapElementPtr(1)",
        "h1 = aGetUnitHeight($u1)",
    ]) + "\n"


def parse_origins(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """The control map, the object array and the two unit heights."""
    import struct

    cells = b""
    objects = b""
    for row in rows:
        for key, text in (row.get("reads") or {}).items():
            if "<" in text:
                continue
            if key.startswith("$c0"):
                cells = _hex_bytes(text)
            elif key.startswith(f"[0x{OBJECT_TABLE:x}]"):
                objects = _hex_bytes(text)
    heights = [int(row["eax"], 16) for row in rows
               if row.get("call") == "aGetUnitHeight" and row.get("status") == "ok"]
    grid: list[dict[str, int]] = []
    for index in range(gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT):
        base = index * gold.CELL_STRIDE
        if base + gold.CELL_STRIDE > len(cells):
            break
        grid.append({
            "object": struct.unpack_from("<H", cells, base + CELL_OBJECT)[0],
            "unit": struct.unpack_from("<H", cells, base + CELL_UNIT)[0],
        })
    table: list[dict[str, int]] = []
    for index in range(HOOK_ID_LIMIT):
        base = index * OBJECT_STRIDE
        if base + OBJECT_STRIDE > len(objects):
            break
        table.append({
            "x": struct.unpack_from("<i", objects, base + 0x10)[0],
            "y": struct.unpack_from("<i", objects, base + 0x14)[0],
            "z": struct.unpack_from("<i", objects, base + 0x18)[0],
        })
    return {"cells": grid, "objects": table, "heights": heights}


#: How much of a symbol-object record the `symbols` phase reads.  Only
#: `+0x10/+0x14/+0x18` are used; the rest is read so a wrong offset is visible
#: rather than plausible.
SYMBOL_RECORD_BYTES = 0x40


def symbols_plan(ids: Sequence[int]) -> str:
    """The **symbol** objects the argument tiles name.

    `aGetSymbolObjectPtr` `0x00404C40` and `aGetStdObjectPosition` `0x00405100`
    are two different tables, and the creators use the first: the cell at the
    capture's source tile names symbol 139 while the *standard* object standing
    there is id 0.  Reading the second and calling it the first is a mistake
    that produces a plausible position and the wrong z -- symbol 139's `+0x18`
    is 0 where standard object 0's is 160.
    """
    lines = [
        "# The symbol objects the two argument tiles name, read raw.",
        DECLARATIONS,
        f"__cdecl ptr aGetSymbolObjectPtr(i32) = Incubation.exe+0x{SYMBOL_OBJECT - 0x400000:x}",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
    ]
    for index, symbol in enumerate(ids):
        lines.append(f"s{index} = aGetSymbolObjectPtr({symbol})"
                     f" --read $s{index}:{SYMBOL_RECORD_BYTES}")
    return "\n".join(lines) + "\n"


def parse_symbols(rows: list[dict[str, Any]],
                  ids: Sequence[int]) -> dict[str, dict[str, int]]:
    """``symbol id -> its own x, y, z``, in call order."""
    import struct

    out: dict[str, dict[str, int]] = {}
    index = 0
    for row in rows:
        if row.get("call") != "aGetSymbolObjectPtr" or row.get("status") != "ok":
            continue
        raw = b""
        for key, text in (row.get("reads") or {}).items():
            if key.startswith("$s") and "<" not in text:
                raw = _hex_bytes(text)
        if len(raw) >= 0x1C and index < len(ids):
            out[str(ids[index])] = {
                "x": struct.unpack_from("<i", raw, 0x10)[0],
                "y": struct.unpack_from("<i", raw, 0x14)[0],
                "z": struct.unpack_from("<i", raw, 0x18)[0],
            }
        index += 1
    return out


#: The record fields a poked vector may write, and how wide each is.
#: Deliberately short: `class_id` and `model` are **not** on it, because an
#: arm that poses or swaps a model dereferences the handle the donor carries
#: and a rewritten class turns a comparison into a fault.  Everything here is
#: a number the arm reads and nothing more.
POKE_FIELD_OFFSETS: dict[str, tuple[int, int]] = {
    "x": (0x14, 4), "y": (0x18, 4), "z": (0x1C, 4),
    "kind": (0x44, 1), "life": (0x45, 1),
    "vx": (0x48, 4), "vy": (0x4C, 4), "vz": (0x50, 4),
    "aux": (0x54, 1),
}


def poke_writes(kind: int, vector: dict[str, int]) -> list[tuple[int, bytes]]:
    """One vector, as the fewest contiguous writes that express it.

    `kind` and `life` are adjacent, so the common case is still the single
    two-byte write the first poked pass used; a vector that also sets the
    velocity adds one more run rather than a write per field.
    """
    raw: dict[int, bytes] = {}
    for field, value in ({"kind": kind} | vector).items():
        offset, width = POKE_FIELD_OFFSETS[field]
        raw[offset] = int(value).to_bytes(width, "little", signed=width > 1)
    out: list[tuple[int, bytes]] = []
    for offset in sorted(raw):
        if out and out[-1][0] + len(out[-1][1]) == offset:
            out[-1] = (out[-1][0], out[-1][1] + raw[offset])
        else:
            out.append((offset, raw[offset]))
    return out


def poked_plan(handle: int, donor: int, args: list[int],
               entries: Sequence[tuple[int, int, dict[str, int]]],
               rounds: int, mode: int | None = None) -> str:
    """Overwrite each donor record's fields, then step one arm per call.

    `docs/97` §18.6 said the fifty arms no creator populates would want
    "writing records into the pool directly, which is a different and more
    invasive experiment".  This is that experiment.  In its first form it was
    **two adjacent bytes**: `+0x44` is the jump-table index and `+0x45` is
    `life`, so one two-byte write makes a donor record a record of any kind
    with a lifetime short enough to reach its own terminal branches.

    What that form could not do is say *how much* of an arm it had run.  A
    record is an input, and one input exercises one path: `docs/97` §21
    measures which lines of each transcribed arm the comparison actually
    reached, and a second and third vector -- a different life, a zeroed
    velocity, an aux naming a dead unit, a position on top of the target --
    are chosen to reach the ones the first left cold.  Each *entry* is
    therefore a slot, a kind and its own vector, and one plan may hold the
    same arm twice under two of them.

    What this still is **not** is a record a creator would have built: the
    class and the model stay the donor's, so it measures the arm and says
    nothing about the arguments the arm would normally see.

    ``mode`` writes `EMITTER_MODE_GLOBAL` for the length of the plan, which
    is the only way to reach kind 59's special emitter: it branches on a byte
    the **output system** owns and no record can set.  The global is read
    before the write and again after the restore, so the check can say the
    write took and the value it displaced was the one this file pins -- the
    restore is a static `EMITTER_MODE_MEASURED` rather than the measured
    number because a plan's text is fixed before the read happens, and the
    read is what makes a wrong assumption a failure instead of a silence.

    The pool is read after **every** call rather than once per round.  A
    poked arm can fault, and a fault costs the rest of the process; per-call
    reads mean the calls before it are still a measurement, and they isolate
    one arm's writes instead of twelve arms' together.

    A spawning arm's **child** is not in this window and is not meant to be:
    :func:`spawn_plan` is the family that measures those.
    """
    entry = _entry_address(handle)
    signature = ",".join("i32" for _ in args)
    read = (f" --read [0x{entry:x}]:{READ_RECORDS * RECORD_BYTES}"
            f" --read 0x{ARANDOM2_SEED:x}:{ARANDOM_SEED_BYTES}")
    lines = [
        "# One donor pool, each record's fields overwritten, one arm per",
        "# call.  The read after every call is deliberate: see poked_plan.",
        DECLARATIONS,
        f"__cdecl i32 aBlob_Update(i32,ptr) = Incubation.exe+0x{BLOB_ARM - 0x400000:x}",
        f"__cdecl i32 c{donor:08X}({signature})"
        f" = Incubation.exe+0x{donor - 0x400000:x}",
        MEMCPY_DECL,
    ]
    for index, (_slot, kind, vector) in enumerate(entries):
        for run, (_offset, raw) in enumerate(poke_writes(kind, vector)):
            lines.append(f"--blob pk{index}_{run}:{raw.hex()}")
    if mode is not None:
        lines.append("--blob mode_on:"
                     + int(mode).to_bytes(4, "little").hex())
        lines.append("--blob mode_off:"
                     + EMITTER_MODE_MEASURED.to_bytes(4, "little").hex())
    lines += [
        "",
        "aSetSaveMode(0)",
        f"loaded = aLoadGame({gold.CAPTURE_SLOT})",
        "reset = aResetBlobs()",
        f"c{donor:08X}({', '.join(str(a) for a in args)})"
        + (f" --read 0x{EMITTER_MODE_GLOBAL:x}:4" if mode is not None else ""),
    ]
    if mode is not None:
        lines.append(f"memcpy(0x{EMITTER_MODE_GLOBAL:x}, &mode_on, 4)"
                     f" --read 0x{EMITTER_MODE_GLOBAL:x}:4")
    for index, (slot, kind, vector) in enumerate(entries):
        for run, (offset, raw) in enumerate(poke_writes(kind, vector)):
            lines.append(
                f"memcpy([0x{entry:x}]+0x{RECORD_BYTES * slot + offset:x},"
                f" &pk{index}_{run}, {len(raw)})")
    lines.append(f"aGetUnitMapElementPtr(0){read}")
    for _round in range(rounds):
        for slot, _kind, _vector in entries:
            lines.append(f"aBlob_Update({slot},"
                         f" [0x{entry:x}]+0x{RECORD_BYTES * slot:x}){read}")
    if mode is not None:
        lines.append(f"memcpy(0x{EMITTER_MODE_GLOBAL:x}, &mode_off, 4)"
                     f" --read 0x{EMITTER_MODE_GLOBAL:x}:4")
    return "\n".join(lines) + "\n"


def parse_poked(rows: list[dict[str, Any]], entry: int) -> dict[str, Any]:
    """Every snapshot a poked plan produced, in call order.

    ``steps`` is one entry per `aBlob_Update` that returned, holding the pool
    and the second generator's seed **after** it; ``start`` is the state the
    first call saw.  A plan that faulted mid-way simply has fewer steps, which
    is why the check counts them rather than assuming a rectangle.
    """
    import struct

    key = f"[0x{entry:x}]"
    seed_key = f"0x{ARANDOM2_SEED:x}"

    def snapshot(row: dict[str, Any]) -> dict[str, Any] | None:
        reads = row.get("reads") or {}
        if key not in reads or "<" in reads[key]:
            return None
        text = reads.get(seed_key)
        seed = (struct.unpack_from("<d", _hex_bytes(text), 0)[0]
                if text and "<" not in text else None)
        return {"pool": reads[key].replace(" ", ""), "seed": seed}

    start: dict[str, Any] | None = None
    steps: list[dict[str, Any]] = []
    # Every reading of the output-system mode, in the order the plan took
    # them: before the write, after it, and after the restore.  A plan that
    # never wrote it has none, which is how the check tells the two families
    # apart without a flag.
    mode_key = f"0x{EMITTER_MODE_GLOBAL:x}"
    mode: list[int] = []
    for row in rows:
        if row.get("status") != "ok":
            continue
        text = (row.get("reads") or {}).get(mode_key)
        if text and "<" not in text:
            mode.append(struct.unpack_from("<I", _hex_bytes(text), 0)[0])
        shot = snapshot(row)
        if shot is None:
            continue
        if row.get("call") == "aBlob_Update":
            steps.append(shot)
        elif start is None:
            start = shot
    return {"start": start, "steps": steps, "mode": mode}


def parse_ticks(rows: list[dict[str, Any]], entry: int) -> dict[str, Any]:
    """The pool as it stood before the first tick and after every one.

    The rounds are stored as **raw hex**, not as parsed records, and that is
    deliberate: :func:`parse_records` stops at the first free slot because a
    creator's records are contiguous, and after a tick they are not -- a blob
    that deleted itself in slot 3 would hide slots 4 through 11 from every
    later round and the diff would silently shrink. The check parses all
    twelve, free ones included.
    """
    import struct

    key = f"[0x{entry:x}]"
    rounds: list[str] = []
    seeds: list[float | None] = []
    for row in rows:
        if row.get("status") != "ok":
            continue
        reads = row.get("reads") or {}
        if key not in reads or "<" in reads[key]:
            continue
        rounds.append(reads[key].replace(" ", ""))
        text = reads.get(f"0x{ARANDOM2_SEED:x}")
        seeds.append(struct.unpack_from("<d", _hex_bytes(text), 0)[0]
                     if text and "<" not in text else None)
    return {"rounds": rounds, "seed2": seeds}


def parse_slots(blob: bytes) -> list[dict[str, Any] | None]:
    """All `READ_RECORDS` slots, with ``None`` where the record is free.

    `docs/28` §7.1: the first dword is the in-use marker the frame sweep
    tests, so a zero there is a slot the engine skipped rather than the end of
    anything.
    """
    import struct

    out: list[dict[str, Any] | None] = []
    for index in range(len(blob) // RECORD_BYTES):
        raw = blob[index * RECORD_BYTES:(index + 1) * RECORD_BYTES]
        if struct.unpack_from("<I", raw, 0x00)[0] == 0:
            out.append(None)
            continue
        out.append(parse_records(raw)[0] | {"slot": index})
    return out


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
#: ``Incubation.exe`` fault before the anchor on this host.  The definition
#: lives in the session module; ``presentation_gold`` reads it from here.
MEMCPY_SLOT = gold.MEMCPY_SLOT
MEMCPY_DECL = gold.MEMCPY_DECL

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

    # **The model lookup.**  Its own small phase, for the same reason `hooks`
    # is one: no writes, no reset, and the two swap arms are otherwise a diff
    # of an adapter's invented index against an engine handle.
    # Re-taken when the name list grows, the same way `state` is re-taken
    # when it is missing a field: a phase that answers for fewer names than
    # the checks ask about would leave a creator's model unresolved.
    if not set(_model_names()) <= set(phases.get("models") or {}):
        import blob_runtime
        try:
            rows = gold.run_plan(game_copy, dbgcall,
                                 models_plan(_model_names()),
                                 "blob_models", attempts=attempts)
            phases["models"] = parse_models(rows, _model_names())
            _save(out, document)
        except gold.CaptureError as err:
            document.setdefault("failures", {})["models"] = str(err)
            LOG.warning("blob_models: %s", err)
            _save(out, document)

    # **The unit array's `+0x4B`**, `docs/28` §12 item 3's residue.  Its own
    # read-only phase, and not a field added to `state`: see `units_plan`.
    if "units" not in phases:
        try:
            rows = gold.run_plan(game_copy, dbgcall, units_plan(),
                                 "blob_units", attempts=attempts)
            phases["units"] = parse_units(rows)
            _save(out, document)
        except gold.CaptureError as err:
            document.setdefault("failures", {})["units"] = str(err)
            LOG.warning("blob_units: %s", err)
            _save(out, document)

    # **The creators' inputs**, `docs/97` §22: what each of them reads before
    # it draws.  Read-only and additive, like `units`.
    if "origins" not in phases:
        try:
            rows = gold.run_plan(game_copy, dbgcall, origins_plan(),
                                 "blob_origins", attempts=attempts)
            phases["origins"] = parse_origins(rows)
            _save(out, document)
        except gold.CaptureError as err:
            document.setdefault("failures", {})["origins"] = str(err)
            LOG.warning("blob_origins: %s", err)
            _save(out, document)

    # **The symbol objects** the two argument tiles name -- built from the
    # cells the `origins` phase read, so it comes after it.
    if "symbols" not in phases and phases.get("origins"):
        cells = phases["origins"]["cells"]
        ids = []
        for tile in (source, target):
            index = tile[1] * gold.CAPTURE_WIDTH + tile[0]
            if index < len(cells):
                ids.append(cells[index]["object"])
        try:
            rows = gold.run_plan(game_copy, dbgcall, symbols_plan(ids),
                                 "blob_symbols", attempts=attempts)
            phases["symbols"] = parse_symbols(rows, ids)
            _save(out, document)
        except gold.CaptureError as err:
            document.setdefault("failures", {})["symbols"] = str(err)
            LOG.warning("blob_symbols: %s", err)
            _save(out, document)

    arities = creator_arities(root)
    # **The tick phases.**  One per creator that actually filled the pool, and
    # one plan each for the same reason the creators are one per plan: a plan
    # that dies takes every creator sharing its process with it.  Written as
    # they land and skipped when present, so a bounded run loses at most the
    # phase in flight.
    entry = _entry_address(state["handle"])
    for creator in reachable_creators(root):
        name = f"0x{creator:08X}"
        if not (phases.get(name) or {}).get("records"):
            continue
        records = phases[name]["records"]
        args = argument_vector(arities[creator], source, target)
        # **The family is chosen from the records, not by retrying.**  A
        # creator whose blobs are class 0 faults the sweep before it ticks
        # anything, every time; picking the family up front spends the
        # attempts on reaching the anchor rather than on reaching a known
        # fault.
        # A creator whose own records are all sprites can go through the
        # sweep -- unless one of its arms **spawns** a model blob, which the
        # next sweep then hands to the renderer and which killed one phase
        # three ticks in. There is no static answer to "does this arm spawn a
        # model", so the rule is: try the sweep once per sprite creator, and
        # fall back to the direct wrapper for anything that has not landed.
        sprite = ({r["class_id"] for r in records} <= {2, 3}
                  and "ticks_" + name not in document.get("failures", {})
                  and "arms_" + name not in document.get("failures", {}))
        if "ticks_" + name in phases or "arms_" + name in phases:
            continue
        tick_name = ("ticks_" if sprite else "arms_") + name
        slots = sorted({r["slot"] for r in records})[:READ_RECORDS]
        plan = (ticks_plan(state["handle"], creator, args) if sprite
                else arms_plan(state["handle"], creator, args, slots))
        try:
            rows = gold.run_plan(game_copy, dbgcall, plan, tick_name,
                                 attempts=attempts)
            phases[tick_name] = parse_ticks(rows, entry)
            phases[tick_name]["args"] = list(args)
            _save(out, document)
        except gold.CaptureError as err:
            document.setdefault("failures", {})[tick_name] = str(err)
            LOG.warning("%s: %s", tick_name, err)
            _save(out, document)

    # **The fifty arms no creator reaches**, `docs/97` §18.6's second residue.
    # A donor pool with the kind byte rewritten per record reaches every one
    # of them; the plans are small and one per batch for the same reason the
    # creators are one per plan.
    donor = (phases.get(f"0x{POKE_DONOR:08X}") or {}).get("records") or []
    donor_slots = sorted({r["slot"] for r in donor})
    if donor_slots and POKE_DONOR in arities:
        donor_args = argument_vector(arities[POKE_DONOR], source, target)
        plans: list[tuple[str, list[tuple[int, int, dict[str, int]]], int]] = []
        for vector in POKE_VECTORS:
            for index, entries in enumerate(poked_batches(donor_slots, vector)):
                plans.append(("poked_%s%02d" % (vector["name"], index),
                              entries, vector["rounds"]))
        probes = poke_probes(_seek_target(phases))
        for index, entries in enumerate(probe_batches(donor_slots, probes)):
            plans.append(("poked_probe_%02d" % index, entries,
                          POKE_PROBE_ROUNDS))
        LOG.info("%d poked plan(s) over %d arm-and-vector pair(s)",
                 len(plans), sum(len(e) for _n, e, _r in plans))
        for name, entries, rounds in plans:
            if name in phases:
                continue
            plan = poked_plan(state["handle"], POKE_DONOR, donor_args,
                              entries, rounds)
            try:
                rows = gold.run_plan(game_copy, dbgcall, plan, name,
                                     attempts=attempts)
                phases[name] = parse_poked(rows, entry)
                phases[name]["slots"] = [slot for slot, _k, _v in entries]
                phases[name]["kinds"] = [kind for _s, kind, _v in entries]
                phases[name]["vectors"] = [vec for _s, _k, vec in entries]
                phases[name]["rounds"] = rounds
                phases[name]["args"] = list(donor_args)
                _save(out, document)
            except gold.CaptureError as err:
                document.setdefault("failures", {})[name] = str(err)
                LOG.warning("%s: %s", name, err)
                _save(out, document)

    # **The branch a record cannot reach.**  Kind 59 asks the output system
    # what mode it is in and spawns a second emitter only for one answer;
    # `docs/97` §23.  The global is written for the length of this plan and
    # put back at the end of it.
    if donor_slots and POKE_DONOR in arities and MODE_PHASE not in phases:
        entries = [(slot, EMITTER_ARM_KIND, dict(vector))
                   for slot, vector in zip(donor_slots[:len(MODE_VECTORS)],
                                           MODE_VECTORS)]
        donor_args = argument_vector(arities[POKE_DONOR], source, target)
        plan = poked_plan(state["handle"], POKE_DONOR, donor_args, entries,
                          MODE_ROUNDS, mode=EMITTER_MODE_SPECIAL)
        try:
            rows = gold.run_plan(game_copy, dbgcall, plan, MODE_PHASE,
                                 attempts=attempts)
            phases[MODE_PHASE] = parse_poked(rows, entry)
            phases[MODE_PHASE]["slots"] = [s for s, _k, _v in entries]
            phases[MODE_PHASE]["kinds"] = [k for _s, k, _v in entries]
            phases[MODE_PHASE]["vectors"] = [v for _s, _k, v in entries]
            phases[MODE_PHASE]["rounds"] = MODE_ROUNDS
            phases[MODE_PHASE]["args"] = list(donor_args)
            # A phase that landed on a later run is not a fault.  The
            # creator loop already does this; a plan whose failure entry
            # outlived its success made `native.faults` a record of the
            # worst attempt rather than of the capture.
            document.get("failures", {}).pop(MODE_PHASE, None)
            _save(out, document)
        except gold.CaptureError as err:
            document.setdefault("failures", {})[MODE_PHASE] = str(err)
            LOG.warning("%s: %s", MODE_PHASE, err)
            _save(out, document)

    # **What a creator is given.**  The poked family measures an arm's own
    # record and stops there: its window is the donor's twelve slots and a
    # child lands past them, so every argument an arm hands a creator went
    # unmeasured -- which is how `docs/97` §48's five wrong ones survived a
    # capture that says all seventy-four arms agree.  These two families step
    # the twenty-one arms that ask for a creator, with the second generator's
    # seed **written** before every call and the pool read wide enough to hold
    # the children.
    if donor_slots and POKE_DONOR in arities:
        donor_args = argument_vector(arities[POKE_DONOR], source, target)
        arrival = _seek_target(phases)
        families = (
            (ZOOM_BOB_PREFIX,
             spawn_entries(ZOOM_BOB_KINDS, SPAWN_SEEDS, arrival)),
            (SPAWN_PREFIX,
             spawn_entries(SPAWN_OTHER_KINDS, SPAWN_SEEDS[:1], arrival)),
        )
        for prefix, entries in families:
            for index, batch in enumerate(spawn_batches(entries)):
                name = f"{prefix}{index:02d}"
                if name in phases:
                    continue
                plan = spawn_plan(state["handle"], POKE_DONOR, donor_args,
                                  donor_slots[0], batch, SPAWN_ROUNDS)
                try:
                    rows = gold.run_plan(game_copy, dbgcall, plan, name,
                                         attempts=attempts)
                    phases[name] = parse_spawn(rows, entry)
                    phases[name]["slot"] = donor_slots[0]
                    phases[name]["kinds"] = [k for k, _v, _sd in batch]
                    phases[name]["vectors"] = [v for _k, v, _sd in batch]
                    phases[name]["seeds"] = [sd for _k, _v, sd in batch]
                    phases[name]["rounds"] = SPAWN_ROUNDS
                    phases[name]["args"] = list(donor_args)
                    phases[name]["read_records"] = SPAWN_READ_RECORDS
                    document.get("failures", {}).pop(name, None)
                    _save(out, document)
                except gold.CaptureError as err:
                    document.setdefault("failures", {})[name] = str(err)
                    LOG.warning("%s: %s", name, err)
                    _save(out, document)

    # A spawning phase captured before the parsed diff existed gets it here:
    # it is pure arithmetic over the pools the phase already holds, so it
    # costs no process and re-taking one would.
    for name, phase in phases.items():
        if not (name.startswith(ZOOM_BOB_PREFIX)
                or name.startswith(SPAWN_PREFIX)):
            continue
        for item in phase.get("entries") or []:
            if any("born" not in step for step in item.get("steps") or []):
                _fill_born(item)
                _save(out, document)

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
    # **The one the first pass called unstructured, and the reason it was.**
    # Its draws are ordinary and its cadence is three per record; what the
    # fitter could not see is that the engine **scales after truncating**
    # (`ftol`, then `shl eax, 5` / `shl eax, 4`), and `32 * trunc(x)` is not
    # `trunc(32 * x)`.  Reading the loop settles it independently: thirty
    # iterations of `aRandom(5, 10) << 5`, `aRandom(-10, 20) << 4` twice --
    # which is also exactly the ninety draws the seed delta counts.
    "0x0042ACF0": {"cycle": 3, "fields": {
        "vz": (0, 32, 5, 10), "vy": (1, 16, -10, 20),
        "vx": (2, 16, -10, 20)}},
}

#: **The second shape, and it is not random at all.**  Several creators stagger
#: their records with `delay = index / k` -- a signed divide of the loop
#: counter, `cdq / sub eax, edx / sar eax, 1` for k = 2.  A fitter looking only
#: for a line in the draws cannot see it and reports the creator unexplained,
#: which is what "no per-record recipe" partly meant.  Each entry is
#: `field -> k`, and `--check` replays it against every captured record.
CREATOR_INDEX_RECIPES: dict[str, dict[str, int]] = {
    "0x004228F0": {"delay": 2},
    "0x004264A0": {"delay": 1},
    "0x00429A80": {"delay": 3},
}

#: **The third shape: velocity that is a direction, not a draw.**
#: `0x00426F90`, `0x00427410` and `0x0042A9D0` all take a target, call
#: `0x0046D400` and multiply.  §7.4.2's finding that that routine is **not
#: normalised** -- it divides by whichever of `|dx|` and `|dy|` is larger, so
#: one of the two is always exactly ±1 -- has a signature no other arithmetic
#: produces: **every** record carries `|vx|` or `|vy|` equal to the speed
#: exactly.  33 of 33 across the three.  So these velocities were never
#: candidates for `aRandom(base, span)`, and the fit was not failing, it was
#: being asked the wrong question.
DIRECTION_SPEED = 1600
CREATOR_DIRECTION_VELOCITY = ("0x00426F90", "0x00427410", "0x0042A9D0")
#: The two shapes' sizes, pinned so shortening either list is a failure and
#: not a smaller report.
DIRECTION_VELOCITY_CREATORS = 3
DIRECTION_VELOCITY_RECORDS = 33
INDEX_RECIPE_CREATORS = 3
INDEX_RECIPE_FIELDS = 3

#: The residue, written out a second time so the tuple below is pinned against
#: something other than itself.  **Empty since `docs/97` §22**: all ten are
#: transcribed instruction by instruction in `tools/inclib/blob_creators.py`
#: and reproduce the engine's records field for field, with their draw counts
#: checked against the measured seed either side of the call.
DRAWS_UNSTRUCTURED_PIN: tuple[str, ...] = ()
#: Creators for which no per-record *recipe* exists, because their draw
#: stream is not consumed at a fixed rate: they build records of several
#: kinds in one call, or call another creator first, or retry.
#:
#: **Empty.**  It held ten for as long as "a mechanism" meant "a recipe a
#: search over the draws can find".  `docs/97` §22 stopped searching and read
#: the ten functions instead: each is now a program in
#: `tools/inclib/blob_creators.py`, replayed from the measured seed by
#: `native.creator_program_records`, and what it produces is not a fitted
#: field but every field of every record the engine left.  Four shapes no
#: recipe could have expressed came out of it -- a draw with a counter added
#: **inside** the conversion, a position that reads a *different* axis'
#: direction ratio, a creator that calls another creator before it places
#: anything, and a constructor that silently drops a record whose `life` is
#: zero.
CREATOR_DRAWS_UNSTRUCTURED: tuple[str, ...] = ()
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
    # **Coverage is measured on the comparison itself**, so the tracer is
    # installed around it rather than around a run of its own -- a second run
    # would measure a different set of inputs and say nothing about the one
    # that agreed with the engine.  `docs/97` §21.
    with ArmLines() as lines:
        _tick_checks(ck, root, phases)
    _coverage_checks(ck, lines)
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
#: Two symbol ids, so the plan renders with fixed arguments like the rest.
PLAN_FIXTURE_SYMBOLS = (139, 98)

PLAN_DIGESTS = {
    "state": "49f0ca979d1e710b03ede4a1cde1d43eee35aef6a0c90e7bdd69a7d6b281e4f7",
    "units": "ada0bfa1db2064771681de1906a4b6fb8d0e858ce389345a4ba262a3f16edd18",
    "origins": "1a930330c90c01b762ee9a0022dade554710158e5a3d8fccb4490b41f9e0609a",
    "symbols": "a177043d0a567cfa08cc540a639e775fef8cbc8a841c9ef6ae0a0299c4d6ebd6",
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
#: What the **independent search** finds, kept separate from the pinned
#: recipes on purpose: the recipes above are exact and read off the loop, this
#: is a solver given nothing but the seed and the records.  It used to be
#: empty, and that emptiness was quoted as a measurement.  It was a bug --
#: the stride loop broke out of itself the first time an offset ran past the
#: end of the draw list, so nothing past stride 1 at a low offset was ever
#: tried -- on top of the missing scale.  Both are fixed; five of the fourteen
#: drawing creators now solve without being told anything.
AFFINE_IN_DRAWS: list[str] = [
    "0x004228F0", "0x00425810", "0x004294E0", "0x004295D0", "0x0042ACF0",
]

#: The multipliers `_fit_draws` tries between the truncation and the store.
#: Powers of two only: the engine reaches them with `shl`, and a general
#: multiplier would let the solver fit noise.
FIT_SCALES = (1, 2, 4, 8, 16, 32, 64, 128, 256)

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


def _eng3d_dll(root: str) -> "PEFile":
    """``Eng3d.dll`` out of a game root, by the name the resolver loads."""
    from inclib.pe import PEFile

    for name in ("Eng3d.dll", "ENG3D.DLL", "eng3d.dll"):
        path = Path(root) / name
        if path.is_file():
            return PEFile(path)
    raise SystemExit(f"{root}: no Eng3d.dll -- is this the game root?")


def _resolver_ordinal(b: "tables.Binary", store: int) -> int | None:
    """The decimal-text ordinal pushed before the ``mov [global], eax``.

    The resolver is one repeated shape: push the ordinal **as a string**, turn
    it into a number, call ``GetProcAddress``, store.  Walking backwards from
    the store to the nearest ``push imm32`` whose target is all digits is
    therefore exact, and it is what makes the names below a reading rather
    than an attribution.
    """
    for back in range(4, 64):
        va = store - back
        if not b.mapped(va, 5) or b.u8(va) != 0x68:
            continue
        text = b.string(b.u32(va + 1), 8)
        if text and text.isdigit():
            return int(text)
    return None


def _store_site(b: "tables.Binary", data: bytes, global_va: int) -> int | None:
    """The single ``mov [global_va], eax`` in ``.text``, or ``None``."""
    hits = _byte_sites(data, b.text_lo, b"\xa3" + global_va.to_bytes(4, "little"))
    hits += _byte_sites(data, b.text_lo,
                        b"\x89\x05" + global_va.to_bytes(4, "little"))
    return hits[0] if len(hits) == 1 else None


def _byte_sites(data: bytes, base: int, pattern: bytes) -> list[int]:
    out, start = [], 0
    while True:
        index = data.find(pattern, start)
        if index < 0:
            return out
        out.append(base + index)
        start = index + 1


def _resolved_slot(b: "tables.Binary", text: bytes,
                   ordinal: int) -> int | None:
    """The global the start-up resolver stores *ordinal*'s address into.

    Forwards from the ``push`` of the ordinal's decimal text to the first
    ``mov [global], eax``, which is the inverse of :func:`_resolver_ordinal`
    and the only way to make a claim about a slot depend on the slot.
    """
    for index in range(len(text) - 5):
        if text[index] != 0x68:
            continue
        literal = b.string(int.from_bytes(text[index + 1:index + 5], "little"), 8)
        if not literal or not literal.isdigit() or int(literal) != ordinal:
            continue
        site = b.text_lo + index
        for forward in range(4, 64):
            if not b.mapped(site + forward, 6):
                break
            if b.u8(site + forward) == 0xA3:
                return b.u32(site + forward + 1)
            if b.u8(site + forward) == 0x89 and b.u8(site + forward + 1) == 0x05:
                return b.u32(site + forward + 2)
    return None


def _eng3d_export_checks(ck: "tables.Checker", root: str,
                         hooks: dict[str, Any]) -> None:
    """Name the five runtime function pointers, three ways that do not share
    a step.

    This is the check that closes "read as bytes and not matched to an
    export".  The three readings are the ordinal literal in the **caller**,
    the export table in the **callee**, and the **captured** thunk's own bytes;
    the first two are static and the third is the running process, and a wrong
    name would have to be wrong in all three the same way.
    """
    b = tables.Binary(root)
    dll = _eng3d_dll(root)
    text = b.pe.bytes_at(b.text_lo, b.text_hi - b.text_lo)
    exports = {ordinal: (rva, name)
               for ordinal, rva, name, _forward in dll.exports()[1]}

    read: dict[int, int] = {}
    for global_va in sorted(POINTER_ORDINALS):
        store = _store_site(b, text, global_va)
        ordinal = _resolver_ordinal(b, store) if store else None
        if ordinal is not None:
            read[global_va] = ordinal
    ck.equal("eng3d.pointer_ordinals", read, POINTER_ORDINALS,
             lambda v: f"{len(v)} runtime pointer(s) resolved by ordinal, the "
                       "literal pushed as decimal text at the store site")
    ck.equal("eng3d.pointer_exports",
             {o: exports[o][1] for o in sorted(POINTER_EXPORTS) if o in exports},
             POINTER_EXPORTS,
             lambda v: "; ".join(f"{o}={n}" for o, n in sorted(v.items())))

    # The captured thunk bytes, back against the shipped file.  Each preview
    # must occur **once** in the DLL -- a pattern that occurs twice names
    # nothing -- and at the RVA its export claims.
    placed, base_of = {}, set()
    for global_va, ordinal in sorted(POINTER_ORDINALS.items()):
        preview = hooks["targets"].get(f"0x{global_va:x}")
        if not preview:
            continue
        raw = bytes.fromhex(preview)
        offset = dll.data.find(raw)
        if offset < 0 or dll.data.find(raw, offset + 1) >= 0:
            placed[ordinal] = None
            continue
        va = dll.off_to_va(offset)
        placed[ordinal] = None if va is None else va - dll.image_base
        base_of.add(hooks["pointers"][f"0x{global_va:x}"] - placed[ordinal])
    ck.equal("eng3d.thunks_are_the_exports", placed,
             {o: exports[o][0] for o in sorted(POINTER_EXPORTS)},
             lambda v: f"{len(v)} captured thunk(s) occur once in the shipped "
                       "DLL, each at its export's own RVA")
    ck.check("eng3d.one_module_base", len(base_of) == 1,
             "all five captured pointers minus their RVAs give one module "
             f"base (0x{min(base_of) if base_of else 0:08X}) -- they are one "
             "relocated Eng3d.dll, not five unrelated routines")

    # The neighbouring builder.  `docs/30` §2.5 item 7 read the joint opcodes
    # and concluded both reachable builders are RzRxRy; here is the same fact
    # from the other end.
    ordinals = set()
    for index in range(len(text) - 5):
        if text[index] != 0x68:
            continue
        literal = b.string(int.from_bytes(text[index + 1:index + 5], "little"), 8)
        if literal and literal.isdigit() and 1 <= int(literal) <= 200:
            ordinals.add(int(literal))
    ck.equal("eng3d.resolved_ordinals", len(ordinals), ENG3D_RESOLVED_ORDINALS,
             lambda v: f"the start-up resolver asks for {v} of the DLL's "
                       f"{len(exports)} exports by ordinal")
    # Which slot ordinal 14 lands in is **read**, not asserted: the check that
    # only asked "is 0x004FA4A0 uncalled?" passed just as happily when handed
    # a neighbouring address that is also uncalled, which is a check about
    # nothing.  Walking the resolver forwards from the literal ties the two.
    slot = _resolved_slot(b, text, ENG3D_UNCALLED_ORDINAL)
    ck.equal("eng3d.ryrxrz_slot", slot, ENG3D_UNCALLED_GLOBAL,
             lambda v: f"ordinal {ENG3D_UNCALLED_ORDINAL} is stored into "
                       f"0x{v:08X}" if v else "ordinal is never stored")
    ck.check("eng3d.ryrxrz_is_resolved_and_never_called",
             ENG3D_UNCALLED_ORDINAL in ordinals
             and exports[ENG3D_UNCALLED_ORDINAL][1] == ENG3D_UNCALLED_EXPORT
             and slot == ENG3D_UNCALLED_GLOBAL
             and not _byte_sites(
                 text, b.text_lo,
                 b"\xff\x15" + ENG3D_UNCALLED_GLOBAL.to_bytes(4, "little"))
             and not _byte_sites(
                 text, b.text_lo,
                 b"\xa1" + ENG3D_UNCALLED_GLOBAL.to_bytes(4, "little")),
             f"{ENG3D_UNCALLED_EXPORT} is resolved into "
             f"0x{ENG3D_UNCALLED_GLOBAL:08X} and **never called or loaded** -- "
             "docs/30 2.5 item 7 from the other end")


def _rotate_truncating(tablesets: Any, vector: tuple[int, int, int],
                       angles: tuple[int, int, int]) -> list[int]:
    """:meth:`Tables.rotate` with **the other** rounding, as a control.

    `docs/28` §7.4.2's claim that the two builders round differently is only
    worth making if the difference is visible, so this rebuilds the same
    matrix with the truncate-toward-zero idiom ``0x004039F0`` uses and hands
    it to the same transform.  If the eight captured answers agreed with both,
    the claim would be unfalsifiable and the check says so by failing.
    """
    from inclib import eng3d

    def sh(value: int) -> int:
        return -((-value) >> 14) if value < 0 else value >> 14

    sa, ca = tablesets.sin(-angles[0]), tablesets.cos(-angles[0])
    sb, cb = tablesets.sin(-angles[1]), tablesets.cos(-angles[1])
    sc, cc = tablesets.sin(-angles[2]), tablesets.cos(-angles[2])
    m = [sh(cb * cc) - sh(sh(sa * sb) * sc), sh(ca * sc),
         sh(sb * cc) + sh(sh(sa * cb) * sc),
         -(sh(cb * sc) + sh(sh(sa * sb) * cc)), sh(ca * cc),
         sh(sh(sa * cb) * cc) - sh(sb * sc),
         -sh(ca * sb), -sa, sh(ca * cb)]
    return [sh(m[row] * vector[0] + m[row + 3] * vector[1]
               + m[row + 6] * vector[2]) for row in range(3)]


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
    # The GDScript twin is diffed on **these** vectors, so the list the
    # fixture emitter carries has to be this list and not a copy that drifted.
    import blob_runtime
    ck.equal("native.hook_rotations_are_the_fixture's",
             blob_runtime.CASE_ROTATIONS, HOOK_ROTATIONS,
             lambda v: f"blob_runtime carries the same {len(v)} rotation(s) "
                       "into tests/fixtures/blob/cases_blob.json")
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
             "0x004039A0 answered every case")
    mismatched = []
    for (vector, angles), answer in zip(HOOK_ROTATIONS, hooks["rotate"]):
        got = tablesets.rotate(vector, angles)
        if got != answer:
            mismatched.append((vector, angles, answer, got))
    ck.equal("native.hook_rotate", mismatched, [],
             lambda v: f"{HOOK_ROTATE_CASES - len(v)}/{HOOK_ROTATE_CASES} "
                       "vectors reproduced through Eng3d's own RzRxRy builder")
    # The three things that had to be right together, each stated as a
    # property the capture can refute rather than as a comment.  A model that
    # got any one of them wrong reproduced at most three of the eight.
    ck.check("native.hook_rotate_negates_its_angles",
             tablesets.matrix3(0, 0, 1024)
             != [-v for v in tablesets.matrix3(0, 0, -1024)]
             and tablesets.matrix3(0, 0, 1024)[1] == -tablesets.sin(1024),
             "_E3D_init_matrix_RzRxRy negates each angle before it indexes "
             "the table -- it builds the matrix of the opposite turns")
    truncated = [_rotate_truncating(tablesets, v, a)
                 for v, a in HOOK_ROTATIONS]
    ck.check("native.hook_rotate_floors_where_the_other_truncates",
             truncated != hooks["rotate"]
             and [tablesets.rotate(v, a) for v, a in HOOK_ROTATIONS]
             == hooks["rotate"],
             "the same eight cases built with 0x004039F0's rounding disagree "
             "with the engine: the three-angle builder shifts a 64-bit "
             "product with shrd, which floors, and its neighbour truncates a "
             "32-bit one toward zero")
    ck.check("native.hook_rotate_reads_the_matrix_by_column",
             tablesets.transform(list(range(9)), (1, 0, 0)) == [0, 0, 0]
             and tablesets.transform([1 << 14 if i == 3 else 0
                                      for i in range(9)], (0, 1, 0))
             == [1, 0, 0],
             "_E3D_c_rotate_coordinate reads m[i], m[i+3], m[i+6] for output "
             "i -- a transposed read paired with a transposed build cancels, "
             "which is how orient passed twenty cases while both were wrong")
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
    _eng3d_export_checks(ck, root, hooks)

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
    # The stagger, replayed the same way: from the record's **index**, with
    # nothing taken from the record.
    for name, fields in sorted(CREATOR_INDEX_RECIPES.items()):
        phase = captured.get(name)
        records = (phase or {}).get("records") or []
        wrong = [(name, index, field, record[field], index // k)
                 for field, k in fields.items()
                 for index, record in enumerate(records)
                 if record[field] != index // k]
        ck.equal(f"native.index_recipe_{name}", wrong, [],
                 lambda v, n=name, f=fields, r=len(records):
                 f"{n}: {', '.join(f'{k} = index / {d}' for k, d in f.items())}"
                 f" over {r} record(s)" if not v
                 else f"{len(v)} disagreement(s)")
    ck.equal("native.index_recipe_count",
             (len(CREATOR_INDEX_RECIPES),
              sum(len(f) for f in CREATOR_INDEX_RECIPES.values())),
             (INDEX_RECIPE_CREATORS, INDEX_RECIPE_FIELDS),
             lambda v: f"{v[1]} staggered field(s) across {v[0]} creator(s)")
    ck.check("native.index_recipes_are_not_draws",
             all(name not in CREATOR_DRAW_RECIPES
                 or field not in CREATOR_DRAW_RECIPES[name]["fields"]
                 for name, fields in CREATOR_INDEX_RECIPES.items()
                 for field in fields),
             f"{len(CREATOR_INDEX_RECIPES)} creator(s) stagger a field by the "
             "loop counter, which is a shape no search of the draws can find")

    # The direction signature.  This is the check that turns "the arithmetic
    # on top of the draws is UNVERIFIED" into a named mechanism for three of
    # the creators that carried it.
    off_speed, counted = [], 0
    for name in CREATOR_DIRECTION_VELOCITY:
        records = (captured.get(name) or {}).get("records") or []
        for index, record in enumerate(records[1:], start=1):
            counted += 1
            if DIRECTION_SPEED not in (abs(record["vx"]), abs(record["vy"])):
                off_speed.append((name, index, record["vx"], record["vy"]))
    ck.equal("native.direction_velocity_counted",
             (len(CREATOR_DIRECTION_VELOCITY), counted),
             (DIRECTION_VELOCITY_CREATORS, DIRECTION_VELOCITY_RECORDS),
             lambda v: f"{v[1]} record(s) across {v[0]} creator(s)")
    ck.equal("native.direction_velocity_signature", off_speed, [],
             lambda v: f"{counted - len(v)}/{counted} records carry |vx| or "
                       f"|vy| = {DIRECTION_SPEED} exactly -- 0x0046D400's "
                       "larger-axis division, not a draw" if not v
                       else f"{len(v)} record(s) miss the signature")
    # And it must be a signature, not a tautology: a creator whose velocities
    # *are* draws must fail the same test.
    drawn = (captured.get("0x0042ACF0") or {}).get("records") or []
    ck.check("native.direction_velocity_is_discriminating",
             bool(drawn) and not any(
                 DIRECTION_SPEED in (abs(r["vx"]), abs(r["vy"])) for r in drawn),
             "0x0042ACF0's drawn velocities never land on the speed exactly, "
             "so the signature separates the two mechanisms")
    # **The residue is pinned by name, not by a property of itself.**  This
    # check used to compare the tuple against its own de-duplication, which is
    # true for every tuple without repeats: deleting an entry passed silently,
    # and the number it reported was therefore unguarded.
    ck.equal("native.draws_unstructured",
             tuple(sorted(CREATOR_DRAWS_UNSTRUCTURED)), DRAWS_UNSTRUCTURED_PIN,
             lambda v: f"{len(v)} creator(s) still have fields no named "
                       "mechanism explains")
    ck.check("native.fit_scales_cover_the_recipes",
             all(scale in FIT_SCALES
                 for recipe in CREATOR_DRAW_RECIPES.values()
                 for _slot, scale, _base, _span in recipe["fields"].values()),
             f"the solver's {len(FIT_SCALES)} scales include every scale a "
             "pinned recipe uses -- a search that could not find its own "
             "answers would report the engine as unexplained")
    ck.check("native.draw_recipes_cover_the_solved",
             set(CREATOR_DRAW_RECIPES) & set(CREATOR_DRAWS_UNSTRUCTURED)
             == set(),
             f"{total} pinned field(s) across "
             f"{len(CREATOR_DRAW_RECIPES)} creator(s), disjoint from the "
             "unstructured ones")


#: The record fields the tick diff compares.  Everything `parse_records`
#: reads, which is everything an arm can write that survives into the next
#: frame.
TICK_FIELDS = ("x", "y", "z", "vx", "vy", "vz", "rot_x", "rot_y", "rot_z",
               "kind", "life", "delay", "class_id", "model", "aux")

#: **The arms the engine itself validated.**  Filled in from a capture and
#: pinned, so a thinner one fails rather than reporting less -- the same rule
#: every other coverage number here follows.  An arm is on this list only if
#: every occupied slot of its creator's pool agreed with the transcription in
#: every field for every tick.
TICK_ARMS_NATIVE: list[int] = [
    5, 6, 8, 9, 11, 12, 15, 20, 21, 22, 25, 33, 42, 44, 45, 48, 49, 58, 60,
    61, 63, 68, 71, 73,
]
#: The arms the capture actually stepped, and the phases that stepped them.
#: Pinned by name so a thinner capture **fails** rather than quietly reporting
#: a smaller number -- the rule every other coverage figure here follows.
TICK_ARMS_SEEN: list[int] = [
    5, 6, 8, 9, 11, 12, 15, 20, 21, 22, 25, 33, 42, 44, 45, 48, 49, 58, 60,
    61, 63, 68, 71, 73,
]
#: Stepped and **not** agreeing: none any more.  Arms 25 and 58 -- the two
#: seekers of kinds 26 and 61 -- sat here until `_seek` stopped inventing a
#: normalised direction and started asking `0x0046D400`, which is the routine
#: the three arms actually call.  See :data:`SEEK_ARMS`.
TICK_ARMS_UNRESOLVED: tuple[int, ...] = ()

#: Kind 41's arm, and the four instructions that are all of it.  There is no
#: test in front of the `idiv`, which is what a poked record with no `vx`
#: measured the hard way: `docs/97` §21.2.
DIVIDING_ARM_KIND = 41
DIVIDING_ARM_BYTES = bytes.fromhex("b800020000" "99" "f77e48" "66014628")

#: Kind 59's **special emitter**, and the one thing in the seventy-four arms
#: that no record can switch on.  `0x0041E500`'s arm for kind 59 calls
#: `0x00461E80` -- whose whole body is `mov eax, [0x00512A78]; ret` -- and
#: takes the branch only when the answer is 3.
#:
#: `0x00512A78` is not a blob field and not a unit field: it is the **output
#: system's** mode id, written by `0x00461310` (`aOutSys.cpp`) once at
#: start-up, and 3 is the case its jump table selects for argument 11 -- the
#: 640x480 configuration whose stride is `0x500` and whose driver entry is
#: `[0x004FA514]`.  So the extra emitter is a *display-mode* effect: on this
#: host's Wine session the mode is `EMITTER_MODE_MEASURED` and the branch
#: never runs, which is why a sweep and eight targeted vectors left its six
#: lines cold.  Writing the global for the length of one `aBlob_Update` is
#: the only way in, and it is safe to do because the constructor reaches
#: none of the getter's other callers -- `0x00420950` calls `0x004604A0`,
#: which reads a **different** global (`0x00512A00`).
EMITTER_ARM_KIND = 59
EMITTER_MODE_GLOBAL = 0x00512A78
EMITTER_MODE_GETTER = 0x00461E80
#: `mov eax, [0x00512A78]` / `ret` -- the whole routine.
EMITTER_GETTER_BYTES = bytes.fromhex("a1782a5100" "c3")
#: `call 0x00461E80` / `cmp eax, 3` / `jne`, inside the arm.
EMITTER_CALL_SITE = 0x004200E4
EMITTER_BRANCH_BYTES = bytes.fromhex("e8971d0400" "83f803" "7561")
#: The value the branch wants, and the one this host's session actually runs
#: at.  Both are cases of `0x00461310`'s jump table and both configure
#: 640x480 with the same 16-bit pixel code; what separates them is **how the
#: surface is made**.  Mode 2 calls `aCreateMainDDObject` (`0x00432CD0`);
#: mode 3 calls `[0x004FA514]`, which `0x00401000` (`a3DEngine.cpp` line 436)
#: fills at start-up with `Eng3d.dll`'s ordinal **67**, asked for by the
#: decimal string `"67"` -- `_E3DCARD_open_3dcard_screen`.  Mode 3 is the
#: **3D accelerator** path, and Wine runs mode 2, plain DirectDraw, which is
#: why the special branch had never executed.
#:
#: `EMITTER_MODE_MEASURED` is also what the plan restores.  A plan's text is
#: fixed before its own read happens, so the restore cannot use the measured
#: number; instead `mode.global_readings` pins the reading taken *before* the
#: write, and a host that runs some other mode fails that check rather than
#: quietly having its mode replaced with this one.
EMITTER_MODE_SPECIAL = 3
EMITTER_MODE_MEASURED = 2
#: How many draws kind 59's arm takes in the ordinary display mode: `vz`,
#: then the ordinary emitter's size and two velocities.
EMITTER_ARM_DRAWS = 4
#: How the special branch pays for itself: three extra draws before the
#: ordinary spawn's four, so the second generator's seed either side says
#: whether the branch was taken without trusting the record alone.
#: `mode.special_draws` measures exactly this -- the same arm advances the
#: second generator by seven under the written mode and by four without it,
#: which is what says the second emitter takes **two** velocity draws and an
#: `aux` rather than three velocities.  Where the three draws *go* is the one
#: half the capture cannot see: the child is not in a poked window, and the
#: `spawn_*` family runs in this host's own display mode, so the literal zero
#: for `vz` stays `push ebp` at `0x00420101` -- the same instruction the
#: ordinary branch has at `0x00420162`, and that one *is* measured by a child.
EMITTER_SPECIAL_DRAWS = 3

#: The three seeking arms, by jump-table index -- which for this table *is*
#: the kind, since `0x0041E553` indexes with the record's own `+0x44`.
#: `docs/28` §7.7.1.  Kind 27 is populated by no creator a weapon switch
#: selects, so the capture never stepped it; it stays verified-static.
SEEK_ARMS = {26: 0x0041F92F, 27: 0x0041FB8A, 61: 0x0042030A}
#: `aGetUnitMapElementPtr`, `aGetStdObjectPosition` and the direction service,
#: in the order every seeker calls them.
SEEK_SERVICES = (0x00477AE0, 0x00405100, 0x0046D400)
#: The record byte that names the unit-map slot, and the unit byte that names
#: the object whose position is the target.
SEEK_UNIT_FIELD = 0x54
SEEK_OBJECT_FIELD = 0x4B
#: `[0x004B1238]` -- the double the direction is multiplied by.
SEEK_PULL_ADDRESS = 0x004B1238
SEEK_PULL = -240.0
#: The unit-map slot every captured seeker record names, and the object id its
#: unit holds.  Arrived at twice, by readings that share no step.  By
#: **elimination**: the `hooks` phase swept sixty-six object ids, this save
#: answers for fifteen of them, and object 1's position is the only one that
#: reproduces the engine's next record -- on every transition where an arm
#: ran.  And by **reading the byte**: the `units` phase reads `+0x4B` out of
#: every unit record, and slot 1 holds 1.
#:
#: The second reading is not a formality, because the first one's *shape*
#: could have been a coincidence of this save.  It is not: `[unit + 0x4B]`
#: equals the slot for the first twelve units of `_6_.sav` and **not** for
#: the rest -- slot 16 holds 12 and slot 17 holds 13 -- so "the seeker steers
#: at object 1" and "the seeker steers at unit 1's object" are different
#: claims about this save, and the byte says which one is true.
SEEK_UNIT_SLOT = 1
SEEK_OBJECT_ID = 1
#: The **second** point the identity is tested at: the donor record's `+0x54`
#: is 0, so the poked kind-27 seeker names slot 0 and resolves to object 0.
SEEK_POKED_SLOT = 0
#: Every `(unit-map slot, [unit + 0x4B])` pair the poked seekers reach.  The
#: donor's own `+0x54` is 0; the second sweep vector writes 10 and a probe
#: writes 1, and the fourth -- slot 14, whose byte names an object the
#: position service refuses -- is deliberately absent, because a refusal has
#: no position to fit and is the `target_missing` branch instead.
POKED_SEEKER_SLOTS: list[tuple[int, int]] = [(0, 0), (1, 1), (10, 10)]
TICK_PHASES: list[str] = [
    "arms_0x00424D20", "arms_0x00425CA0", "arms_0x00426070",
    "arms_0x004264A0", "arms_0x00426B70", "arms_0x00426F90",
    "arms_0x00427410", "arms_0x00427810", "arms_0x00428200",
    "arms_0x00429180", "arms_0x004294E0", "arms_0x004295D0",
    "arms_0x0042A9D0", "arms_0x0042ACF0", "arms_0x0042AF10",
    "ticks_0x00420A50", "ticks_0x004227C0", "ticks_0x004228F0",
    "ticks_0x00425810", "ticks_0x004268B0", "ticks_0x00428570",
    "ticks_0x00429A80", "ticks_0x00429C30",
]
#: The poked batches, by name, and what stepping them found.  Filled in from
#: a capture and pinned, so a thinner one fails rather than reporting less.
POKED_PHASES: list[str] = (["poked_%02d" % n for n in range(9)]
                           + ["poked_v1_%02d" % n for n in range(9)])
POKED_ARMS_STEPPED: list[int] = [0, 1, 2, 3, 4, 7, 10, 13, 14, 16, 17, 18, 19, 23, 24, 26, 27, 28, 29, 30, 31, 32, 34, 35, 36, 37, 38, 39, 40, 41, 43, 46, 47, 50, 51, 52, 53, 54, 55, 56, 57, 59, 62, 64, 65, 66, 67, 69, 70, 72]
#: **All fifty.**  Every arm no creator a weapon switch selects can fill
#: was stepped with a donor record whose kind byte was rewritten, and every
#: one reproduces the engine's record field for field -- after ten of them
#: were fixed, which is what the experiment was for (`docs/97` §20).
POKED_ARMS_NATIVE: list[int] = list(POKED_ARMS_STEPPED)
POKED_ARMS_DISAGREE: list[int] = []
#: What the coverage instrument found, pinned.  The first is
#: `(covered, total)` transcribed arm lines; the second, how many of the
#: seventy-four arms have every line executed; the third names the rest, by
#: source text rather than by line number.
#: **The total moves whenever any arm's line count does** -- wrapping a line
#: or splitting a comment out of one is enough.  That is deliberate: a
#: coverage figure has to be re-earned when the thing it counts changes, and
#: the uncovered *lines* beside it are pinned by source text so an unrelated
#: edit does not silently rename a gap.  If this pin breaks and
#: `coverage.uncovered_lines` does not, the transcription grew or shrank a
#: line and the number simply wants updating.
COVERAGE_ARM_LINES = (383, 385)
COVERAGE_ARMS_COMPLETE = 73
#: The two that remain, and they are one *divergence* rather than a gap:
#: `0x0041E55A` has no test in front of its `idiv`, so a record with no `vx`
#: kills the engine -- measured, once (`docs/97` §21.2).  The port's guard has
#: no counterpart to reach, and reaching it again would cost the arms after
#: it in the same plan.
#:
#: Arm 56's six lines were here too, on the same footing -- "gated on a byte
#: `0x00461E80` returns, not on anything in the record".  They are gone
#: because the byte turned out to be the *output system's* mode global and
#: writing it for the length of one plan runs the branch: `docs/97` §23.3,
#: and `MODE_PHASE`.  The lesson is worth keeping attached to this list: a
#: line called unreachable is a claim about what has been tried.
COVERAGE_UNCOVERED: list[tuple[int, str]] = [
    (39, 'result.event("division_by_zero", 0x200)'),
    (39, 'return'),
]

#: The lives and round counts the poked *sweep* phases carry, and how many
#: distinct input vectors each of the fifty arms was stepped at.  Pinned so a
#: capture that dropped a vector fails rather than reporting a smaller
#: coverage figure with the same wording.
POKE_LIVES = [6, 12]
POKE_ROUNDS_SEEN = [8, 14]
POKED_ARMS_MULTI_VECTOR = 50
POKED_VECTORS_PER_ARM: list[tuple[int, int]] = [
    (arm, 2) for arm in [0, 1, 2, 3, 4, 7, 10, 13, 14, 16, 17, 18, 19, 23, 24,
                         26, 27, 28, 29, 30, 31, 32, 34, 35, 36, 37, 38, 39,
                         40, 41, 43, 46, 47, 50, 51, 52, 53, 54, 55, 56, 57,
                         59, 62, 64, 65, 66, 67, 69, 70, 72]]
#: The probe family: the plans, the arms they reach and the vectors each is
#: reached under.  Two of the four are creator-filled arms already on
#: :data:`TICK_ARMS_SEEN` -- a probe is a coverage instrument, not a way of
#: reaching an arm nothing else reaches.
PROBE_PHASES = ["poked_probe_00", "poked_probe_01"]
PROBE_ARMS = [25, 42, 45, 58, 62, 71]
PROBE_VECTORS_PER_ARM: list[tuple[int, int]] = [(25, 2), (42, 1), (45, 1),
                                                (58, 2), (62, 2), (71, 2)]

#: How many of the 74 arms a shot can reach at all.  The rest cannot be
#: populated by firing a weapon, so no capture of this shape can reach them.
TICK_ARMS_REACHABLE = 24


def _seek_positions(phases: dict[str, Any]) -> dict[int, tuple[int, int, int]]:
    """``object id -> position``, exactly as the `hooks` phase measured it."""
    hooks = phases.get("hooks") or {}
    ids = hooks.get("object_ids") or []
    table = hooks.get("object") or []
    return {oid: (e["x"], e["y"], e["z"])
            for oid, e in zip(ids, table) if e.get("ok")}


def _seek_hooks(seed: float, positions: dict[int, tuple[int, int, int]],
                tables: Any, handles: dict[str, int] | None = None,
                emitter_mode: int = 0) -> Any:
    """`CaseHooks` whose target is the record's **own** `+0x54`, resolved.

    The captured seekers all name slot 1 and the poked kind-27 record names
    slot 0, so a single fixed target would answer one of them and not the
    other.  Resolving through the measured object table instead is what makes
    the identity `unit-map slot -> object id` a *tested* proposition rather
    than an assumption: get it wrong for either value and that arm fails.
    """
    import blob_runtime

    class _Hooks(blob_runtime.CaseHooks):
        def target_position(self, blob: Any) -> tuple[int, int, int] | None:
            self.target_calls.append(blob.aux)
            return positions.get(blob.aux)

        def lookup_model(self, name: str) -> int:
            self.model_calls.append(name)
            if handles is None:
                return super().lookup_model(name)
            return handles.get(name, -1)

    return _Hooks(seed, target=None, tables=tables,
                  emitter_mode=emitter_mode)


def _seek_target(phases: dict[str, Any]) -> tuple[int, int, int] | None:
    """Where the captured seekers were steering, out of the `hooks` phase.

    `aGetStdObjectPosition` was swept over sixty-six object ids there, so this
    is a **read of the engine's own answer** rather than a position invented
    for the replay.
    """
    hooks = phases.get("hooks") or {}
    ids = hooks.get("object_ids") or []
    table = hooks.get("object") or []
    for oid, entry in zip(ids, table):
        if oid == SEEK_OBJECT_ID and entry.get("ok"):
            return entry["x"], entry["y"], entry["z"]
    return None


def _seek_sites(binary: "tables.Binary", arm: int,
                window: int = 0x260) -> list[int]:
    """The service calls one seeking arm makes, in order."""
    out: list[int] = []
    for offset in range(window):
        va = arm + offset
        if not binary.mapped(va, 5) or binary.u8(va) != 0xE8:
            continue
        target = (va + 5 + binary.i32(va + 1)) & 0xFFFFFFFF
        if target in SEEK_SERVICES:
            out.append(target)
    return out


def _seek_checks(ck: "tables.Checker", binary: "tables.Binary",
                 phases: dict[str, Any], arm_of_kind: dict[int, int],
                 tablesets: Any) -> None:
    """What the three seekers read, and which object the capture says it is.

    Two independent readings have to agree here.  The **static** one is the
    arms themselves: each opens by loading the record's `+0x54` as a byte,
    hands it to `aGetUnitMapElementPtr`, takes `+0x4B` out of the unit record
    it gets back, hands *that* to `aGetStdObjectPosition`, and steers with
    `0x0046D400` scaled by the double at `0x004B1238`.  The **dynamic** one is
    the capture: replaying each seeker transition against all sixty-six object
    positions the `hooks` phase measured -- the fifteen of sixty-six ids that
    exist in this save -- leaves exactly one that reproduces the engine's next
    record.
    """
    import blob_runtime

    arm = binary.pe.u32(tables.BLOB_UPDATE_TABLE + 4 * DIVIDING_ARM_KIND)
    ck.equal("seek.dividing_arm_has_no_guard",
             binary.pe.bytes_at(arm, len(DIVIDING_ARM_BYTES)),
             DIVIDING_ARM_BYTES,
             lambda v: f"kind {DIVIDING_ARM_KIND}'s whole arm is "
                       "`mov eax, 0x200 / cdq / idiv [esi+0x48] / add "
                       "[esi+0x28], ax` -- the divisor is the record's vx and "
                       "nothing tests it, so a record with no vx faults")
    ck.equal("seek.emitter_mode_getter",
             binary.pe.bytes_at(EMITTER_MODE_GETTER, len(EMITTER_GETTER_BYTES)),
             EMITTER_GETTER_BYTES,
             lambda v: f"0x{EMITTER_MODE_GETTER:08X} is `mov eax, "
                       f"[0x{EMITTER_MODE_GLOBAL:08X}]; ret` and nothing else "
                       "-- the byte kind 59 branches on is a global, not a "
                       "record field")
    emitter_arm = binary.pe.u32(
        tables.BLOB_UPDATE_TABLE + 4 * EMITTER_ARM_KIND)
    ck.check("seek.emitter_branch_site",
             EMITTER_CALL_SITE > emitter_arm
             and binary.pe.bytes_at(
                 EMITTER_CALL_SITE, len(EMITTER_BRANCH_BYTES))
             == EMITTER_BRANCH_BYTES,
             f"kind {EMITTER_ARM_KIND}'s arm calls it at "
             f"0x{EMITTER_CALL_SITE:08X} and compares the answer with "
             f"{EMITTER_MODE_SPECIAL}")
    ck.equal("seek.pull_constant", struct.unpack(
        "<d", binary.pe.bytes_at(SEEK_PULL_ADDRESS, 8))[0], SEEK_PULL,
        lambda v: f"[0x{SEEK_PULL_ADDRESS:08X}] is {v}, the scale every "
                  "seeker multiplies the direction service by")
    for kind, arm in sorted(SEEK_ARMS.items()):
        ck.equal(f"seek.services_of_kind_{kind}", _seek_sites(binary, arm),
                 list(SEEK_SERVICES),
                 lambda v, kind=kind: f"kind {kind}'s arm calls the unit map, "
                                      "the object position and the direction "
                                      "service, once each and in that order")
        unit_field = [binary.u8(arm + n + 2) for n in range(6)
                      if binary.u8(arm + n) == 0x8A
                      and binary.u8(arm + n + 1) in (0x46, 0x4E, 0x56)]
        ck.equal(f"seek.unit_field_of_kind_{kind}", unit_field,
                 [SEEK_UNIT_FIELD],
                 lambda v, kind=kind: f"kind {kind}'s arm opens by reading the "
                                      f"record's +0x{SEEK_UNIT_FIELD:02X} as "
                                      "the unit-map slot")

    landed = [n for n in phases if n.startswith("ticks_") or n.startswith("arms_")]
    ids = (phases.get("hooks") or {}).get("object_ids") or []
    table = (phases.get("hooks") or {}).get("object") or []
    candidates = [(oid, (e["x"], e["y"], e["z"]))
                  for oid, e in zip(ids, table) if e.get("ok")]
    slots: set[int] = set()
    fits: list[list[int]] = []
    for name in sorted(landed):
        phase = phases[name]
        rounds = [parse_slots(bytes.fromhex(h)) for h in phase["rounds"]]
        for step in range(1, len(rounds)):
            for index, record in enumerate(rounds[step - 1]):
                if record is None or record["kind"] not in SEEK_ARMS:
                    continue
                after = rounds[step][index]
                if after is None or after["kind"] != record["kind"]:
                    continue
                slots.add(record["aux"])
                if record["delay"]:
                    continue
                fit = []
                for oid, position in candidates:
                    blob = blob_runtime.Blob(
                        **{f: record[f] for f in TICK_FIELDS})
                    hooks = blob_runtime.CaseHooks(1.0, target=position,
                                                   tables=tablesets)
                    blob_runtime.tick_blob(blob, hooks)
                    if _tick_agrees(blob, after):
                        fit.append(oid)
                fits.append(fit)
    ck.check("seek.transitions_replayed", len(fits) > 0,
             f"{len(fits)} seeker transition(s) where an arm actually ran, "
             f"replayed against {len(candidates)} measured object position(s)")
    ck.equal("seek.unit_slot", sorted(slots), [SEEK_UNIT_SLOT],
             lambda v: f"every captured seeker record names unit-map slot {v}")
    ck.equal("seek.target_is_unique",
             sorted({tuple(f) for f in fits}), [(SEEK_OBJECT_ID,)],
             lambda v: f"exactly one object id reproduces the engine's next "
                       f"record, on every transition: {v}")


#: The unit array of `_6_.sav`, slot by slot, as the `units` phase read it:
#: `(slot, [unit + 0x4B])`.  Eighteen records carry a name; the four the unit
#: map itself refuses -- 12 through 15 -- are in the list because what they
#: hold is part of the finding.
UNIT_OBJECTS: list[tuple[int, int]] = [
    (0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8),
    (9, 9), (10, 10), (11, 11), (12, 10), (13, 11), (14, 14), (15, 15),
    (16, 12), (17, 13),
]
#: The slots `aGetUnitMapElementPtr` answers for -- the live units.  Every one
#: of them resolves `+0x4B` to an object standing on that unit's **own tile**,
#: which is the cross-check that makes the byte an identification rather than
#: a number that happens to be in range.
UNIT_OBJECTS_LIVE = 14
#: World units per tile, the scale that cross-check needs.  Derived from the
#: capture rather than assumed: every answered object's x and y are exact
#: multiples of it, and dividing by it lands on a unit's tile.
FIELD_SCALE = 3200
#: The live slots where `[unit + 0x4B]` is **not** the slot.  Two of fourteen,
#: which is what stops the elimination result from being a tautology.
UNIT_OBJECT_NOT_SLOT = [(16, 12), (17, 13)]
#: What a dead record holds.  Slots 12 and 13 repeat a live unit's id and 14
#: and 15 name ids `aGetStdObjectPosition` refuses; all four are slots the
#: unit map declines, so nothing reads them -- except a blob whose `+0x54`
#: names one, which is `blob_runtime`'s `no_target` scenario and the reason
#: that scenario exists.
UNIT_OBJECT_DEAD = [(12, 10), (13, 11), (14, 14), (15, 15)]
#: The dead slot the probe vectors point a seeker at.  Its `+0x4B` names an
#: object `aGetStdObjectPosition` refuses, which is the only way to reach the
#: three seekers' `target_missing` return from a record field.
UNIT_OBJECT_DEAD_SLOT = 14


def _unit_object_checks(ck: "tables.Checker", phases: dict[str, Any]) -> None:
    """`[unit + 0x4B]`, read -- the last link of the seeking chain.

    `docs/28` §7.7.1 reads the chain out of the arms statically: `+0x54` names
    a unit-map slot, the unit record's `+0x4B` names an object, the object's
    position is the target.  Every link but the middle one was measured; this
    is the middle one, and it is measured three ways at once.

    * the byte itself, for all eighteen named slots;
    * against the object sweep: for each of the fourteen live units, the
      object `+0x4B` names stands on **that unit's own tile**, so the number
      identifies the unit's object rather than merely being in range;
    * against the elimination result: slot 1 holds 1, which is the id the
      replay of every seeker transition had already singled out, and slot 0
      holds 0, which is the poked seeker's.

    And the failure mode the first two rule out is real: slot and id are equal
    for twelve of this save's units and different for two, so a check that
    only asserted "slot 1 -> object 1" would have passed on a save where the
    arm read something else entirely.
    """
    units = phases.get("units")
    if not units:
        ck.check("units.phase_landed", False,
                 "the unit array was never read; +0x4B stays unmeasured")
        return
    ck.equal("units.objects_read", [(u["slot"], u["object"]) for u in units],
             UNIT_OBJECTS,
             lambda v: f"{len(v)} named unit record(s), each with the object "
                       "id its +0x4B holds")

    hooks = phases.get("hooks") or {}
    answered = {slot for slot, ptr in zip(hooks.get("unit_slots") or [],
                                          hooks.get("unit") or []) if ptr}
    positions = _seek_positions(phases)
    live = [u for u in units if u["slot"] in answered]
    ck.equal("units.live_slots", len(live), UNIT_OBJECTS_LIVE,
             lambda n: f"{n} slot(s) the unit map answers for")
    named = [positions[u["object"]] for u in live if u["object"] in positions]
    ck.check("units.scale_divides_every_object",
             bool(named) and all(x % FIELD_SCALE == 0 and y % FIELD_SCALE == 0
                                 for x, y, _z in named),
             f"every object a live unit names sits on an exact multiple of "
             f"{FIELD_SCALE}, so the tile it stands on is exact")
    tiles = [(u["slot"], u["object"],
              (positions[u["object"]][0] // FIELD_SCALE,
               positions[u["object"]][1] // FIELD_SCALE) == (u["x"], u["y"]))
             for u in live if u["object"] in positions]
    ck.equal("units.object_stands_on_the_unit's_tile",
             [(slot, oid) for slot, oid, ok in tiles if not ok], [],
             lambda v: f"{len(tiles)} live unit(s) resolve +0x4B to an object "
                       "on that unit's own tile; "
                       f"{len(v)} do not")
    ck.equal("units.object_is_not_the_slot",
             [(u["slot"], u["object"]) for u in live
              if u["object"] != u["slot"]], UNIT_OBJECT_NOT_SLOT,
             lambda v: f"{len(v)} live unit(s) name an object id that is not "
                       "their slot -- which is why the elimination result "
                       "needed this byte")
    ck.equal("units.dead_slots_hold_stale_ids",
             [(u["slot"], u["object"]) for u in units
              if u["slot"] not in answered], UNIT_OBJECT_DEAD,
             lambda v: f"{len(v)} named-but-dead slot(s), holding a repeat of "
                       "a live id or an id the object service refuses")
    byslot = {u["slot"]: u["object"] for u in units}
    ck.equal("units.seeker_target_is_the_byte",
             byslot.get(SEEK_UNIT_SLOT), SEEK_OBJECT_ID,
             lambda v: f"unit {SEEK_UNIT_SLOT}'s +0x4B holds {v} -- the id "
                       "replaying every seeker transition had singled out by "
                       "elimination")
    ck.equal("units.poked_seeker_target_is_the_byte",
             byslot.get(SEEK_POKED_SLOT), SEEK_POKED_SLOT,
             lambda v: f"unit {SEEK_POKED_SLOT}'s +0x4B holds {v}, the "
                       "donor record's second point")


#: The ten creators `docs/28` §7.6.1 left with "a residue of fields with no
#: named mechanism", now transcribed instruction by instruction in
#: `tools/inclib/blob_creators.py` -- `docs/97` §22.
CREATOR_PROGRAMS_EXPECTED = 10
#: How many draws each takes from the second generator, and how many records
#: the constructor refuses for a zero `life`.  Both are pinned because both
#: are checked against the **measured** seed either side of the call: the
#: record comparison can only see the pool's first twelve, and the draw count
#: sees the whole call.
CREATOR_PROGRAM_DRAWS: dict[str, tuple[int, int]] = {
    "0x00424D20": (25, 1), "0x00425810": (90, 0), "0x004264A0": (3, 0),
    "0x00426F90": (200, 0), "0x00427410": (203, 0), "0x00427810": (7, 3),
    "0x00429180": (144, 0), "0x00429A80": (108, 0), "0x0042A9D0": (200, 0),
    "0x0042AF10": (6, 0),
}


def _creator_inputs(root: str, phases: dict[str, Any]) -> Any:
    """The three read-only phases, assembled into what a program is given."""
    from inclib import blob_creators, eng3d

    origins = phases.get("origins") or {}
    symbols = phases.get("symbols") or {}
    models = phases.get("models") or {}
    cells = origins.get("cells") or []
    if not cells or not symbols:
        return None
    units = (phases.get("state") or {}).get("units") or []
    if len(units) < 2:
        return None
    tiles = [(units[0]["x"], units[0]["y"]), (units[1]["x"], units[1]["y"])]
    found = []
    for tile in tiles:
        index = tile[1] * gold.CAPTURE_WIDTH + tile[0]
        if index >= len(cells):
            return None
        found.append(cells[index])
    source = symbols.get(str(found[0]["object"]))
    target = symbols.get(str(found[1]["object"]))
    heights = origins.get("heights") or []
    if not source or not target or len(heights) < 2:
        return None
    return blob_creators.Inputs(
        source=(source["x"], source["y"], source["z"]),
        source_height=heights[0],
        target=(target["x"], target["y"], target["z"]),
        target_height=heights[1],
        models={str(k): int(v) for k, v in models.items()},
        tables=eng3d.load(root),
        target_unit=found[1]["unit"] & 0xFF)


#: The constants a creator program carries that this capture **cannot tell
#: apart from a neighbour**.  Every one is *read* out of the disassembly, so
#: none is a guess; but a constant no captured record exercises is a
#: transcription nothing has tested, which is the same thing the arm-line
#: coverage of `docs/97` §21 measures one level down.  Naming them is the
#: point: a richer capture that did discriminate one would fail this check
#: and the list would shrink.
#:
#: Why each is invisible here: `HEAD_SPEED` belongs to three records the
#: constructor drops for a zero `life` and `DOT_SPEED` to records past the
#: twelve a capture reads back; the three length constants divide a span of
#: 6400 whose quotient an off-by-one does not move; and `HEAD_STEP` shifts an
#: orientation target by one unit, which does not move a 4096th.
#:
#: **What closes them is not a second capture.**  Only two of the six are the
#: kind of thing a different tile pair or a wider read window would reach:
#: `HEAD_STEP` feeds a quantised orientation and `BEAM_UNIT`, `BEAM_BASE` and
#: `TRAIL_UNIT` are divisors an off-by-one moves for almost no dividend, so a
#: perturbation test is the wrong instrument for them at *any* span.  The
#: right one is static, and it is
#: `blob_tables.CREATOR_CONSTANT_SITES`: every constant's value is read back
#: out of the shipped `Incubation.exe` at a named address -- the doubles from
#: the constant block, the subtracted immediates from their own instructions,
#: the two divisors by replaying the reciprocal multiply the compiler left
#: instead of the number -- and each site is required to fall inside the
#: creator the transcription attributes it to.  This list stays as the honest
#: statement of *the capture's* reach; it is no longer the only thing
#: standing behind the six.
CREATOR_CONSTANTS_UNDISCRIMINATED = (
    "BEAM_BASE", "BEAM_UNIT", "DOT_SPEED", "HEAD_SPEED", "HEAD_STEP",
    "TRAIL_UNIT",
    # The death creators' doubles: no weapon switch reaches those creators,
    # so this capture never runs them.  `presentation_gold.py`'s `deaths`
    # phases do, and its `deaths.constants_discriminated` is where each of
    # these five is told from its neighbour.
    "BLOOD_LIFT", "BLOOD_STEP", "BLOOD_VELOCITY", "BLOOD_VELOCITY_LARGE",
    "SPECIES_COIN",
    # The unit animations' and the set pieces' constants (`docs/97` §31,
    # §32): no weapon switch reaches those creators either, and it is
    # `presentation_gold.py`'s own `death_*` phases that run them.
    "BOMBER_SPEED", "BOMB_CEILING", "BOMB_DROP", "BOMB_FALL",
    "DUST_RADIUS", "DUST_TURN",
    "FIRE_CIRCLE_FLAMES", "FIRE_CIRCLE_RADIUS", "FIRE_CIRCLE_TURN",
    "FLASH_RADIUS", "FLASH_RADIUS_LARGE", "LASER_OFFSET", "LASER_STEP",
    "PLATFORM_DUST_SPREAD", "PLATFORM_DUST_UP", "RING_RADIUS",
    "RING_RADIUS_LARGE", "STREAM_RECORDS", "STREAM_STEP", "TUBE_PAIRS",
    # `docs/97` §49's twelve are reached by the `zoom_bob_*` and `spawn_*`
    # families here rather than by a weapon switch, so this list is where
    # their one shared constant sits: the scratch **name**, which is an
    # address and not an arithmetic constant at all -- nothing can tell it
    # from a neighbouring value because it is compared as a pointer.
    "NAME_SCRATCH",
)
#: The ones it does pin, so the check is a measurement in both directions
#: rather than a list of excuses.
CREATOR_CONSTANTS_DISCRIMINATED = (
    "BEAM_STEP", "CASING_SPEED", "SHARD_SPEED", "SPARK_SPEED",
    "TRACER_LEAN", "TRACER_SPREAD", "TRAIL_STEP",
)


def _creator_discrimination(root: str, phases: dict[str, Any]) -> list[str]:
    """Which program constants this capture can tell apart from a neighbour.

    Perturbs each by one and replays; a constant whose perturbation changes
    no captured record and no draw count is not discriminated *here*.
    """
    from inclib import blob_creators

    inputs = _creator_inputs(root, phases)
    if inputs is None:
        return []

    def replays() -> list[Any]:
        out: list[Any] = []
        for address, (_arity, program) in sorted(
                blob_creators.PROGRAMS.items()):
            phase = phases.get(f"0x{address:08X}") or {}
            if not phase.get("records"):
                continue
            pool = blob_creators.Pool(inputs)
            draws = blob_creators.Draws(phase["seed2_before"])
            program(pool, draws, phase["args"])
            keep = len(phase["records"])
            out.append((draws.count, pool.refused, pool.records[:keep]))
        return out

    base = replays()
    moved: list[str] = []
    for name in sorted(CREATOR_CONSTANTS_UNDISCRIMINATED
                       + CREATOR_CONSTANTS_DISCRIMINATED):
        was = getattr(blob_creators, name)
        setattr(blob_creators, name, was + (1.0 if isinstance(was, float)
                                            else 1))
        try:
            if replays() != base:
                moved.append(name)
        finally:
            setattr(blob_creators, name, was)
    return moved


def _creator_program_checks(ck: "tables.Checker", root: str,
                            phases: dict[str, Any]) -> None:
    """Replay each transcribed creator against the records the engine left.

    Two comparisons, and the second is the one that reaches past the read
    window.  The **records** are compared field for field over the twelve
    slots the capture reads back -- which for two of the ten are entirely a
    *nested* creator's, because they call one before they place anything of
    their own.  The **draw count** is compared against `aRandom2`'s measured
    seed either side of the call, and that covers every record the program
    builds, seen or not: a beam whose length is one dot wrong takes a
    different number of draws.

    Nothing here is fitted.  The programs are read out of the creators' own
    instructions and their constants are the doubles at `0x004B12xx`; a wrong
    one fails.
    """
    from inclib import blob_creators
    from inclib.rng import ARandom

    inputs = _creator_inputs(root, phases)
    ck.check("native.creator_inputs",
             inputs is not None,
             "the control map, the two symbol objects, the two unit heights "
             "and the model handles are all captured, so a program can be "
             "given what the engine read")
    if inputs is None:
        return
    ck.equal("native.creator_programs",
             len(blob_creators.PROGRAMS), CREATOR_PROGRAMS_EXPECTED,
             lambda n: f"{n} creator(s) transcribed instruction by "
                       "instruction")
    arities = creator_arities(root)
    wrong: list[Any] = []
    counts: dict[str, tuple[int, int]] = {}
    seeds: list[str] = []
    compared = 0
    for address, (arity, program) in sorted(blob_creators.PROGRAMS.items()):
        name = f"0x{address:08X}"
        phase = phases.get(name) or {}
        records = phase.get("records") or []
        if not records or phase.get("seed2_before") is None:
            wrong.append((name, "not captured"))
            continue
        ck.equal(f"native.creator_arity_{name}", arities.get(address), arity,
                 lambda v, n=name: f"{n} takes {v} dword argument(s), as its "
                                   "callers' own stack cleanup says")
        pool = blob_creators.Pool(inputs)
        draws = blob_creators.Draws(phase["seed2_before"])
        program(pool, draws, phase["args"])
        counts[name] = (draws.count, pool.refused)
        rng = ARandom(phase["seed2_before"])
        for _ in range(draws.count):
            rng.raw(0, 1)
        if abs(rng.seed - phase["seed2_after"]) > 1e-9:
            seeds.append(name)
        for index, record in enumerate(records):
            compared += 1
            if index >= len(pool.records):
                wrong.append((name, index, "missing"))
                continue
            built = pool.records[index]
            for field in blob_creators.FIELDS:
                if record[field] != built[field]:
                    wrong.append((name, index, field, record[field],
                                  built[field]))
    ck.equal("native.creator_program_records", wrong, [],
             lambda v: f"{compared} record(s) across "
                       f"{len(blob_creators.PROGRAMS)} creator(s) reproduced "
                       "field for field" if not v
                       else f"{len(v)} disagreement(s): {v[:3]}")
    ck.equal("native.creator_program_draws", counts, CREATOR_PROGRAM_DRAWS,
             tables.Checker.brief)
    # **The denominator has to cover the module**, or a constant added later
    # sits in neither list and the figure below quietly means something else.
    numeric = sorted(
        name for name in dir(blob_creators)
        if name.isupper()
        and isinstance(getattr(blob_creators, name), (int, float))
        and not isinstance(getattr(blob_creators, name), bool))
    ck.equal("native.creator_constants_all_listed", numeric,
             sorted(CREATOR_CONSTANTS_DISCRIMINATED
                    + CREATOR_CONSTANTS_UNDISCRIMINATED),
             lambda v: f"all {len(v)} numeric constant(s) of "
                       "blob_creators.py are named by one of the two lists")
    moved = _creator_discrimination(root, phases)
    ck.equal("native.creator_constants_discriminated", moved,
             sorted(CREATOR_CONSTANTS_DISCRIMINATED),
             lambda v: f"{len(v)} of "
                       f"{len(CREATOR_CONSTANTS_DISCRIMINATED) + len(CREATOR_CONSTANTS_UNDISCRIMINATED)}"
                       " program constant(s) are pinned by this capture; the "
                       "rest are read from the disassembly and exercised by "
                       "no record it holds")
    ck.equal("native.creator_program_seed_delta", seeds, [],
             lambda v: "every program takes exactly the number of draws the "
                       "measured seed delta says, which is a claim about the "
                       "records past the read window too" if not v
                       else f"{len(v)} creator(s) draw a different number")


def _tick_state(phases: dict[str, Any]) -> int:
    return (phases.get("state") or {}).get("base", 0)


def _tick_checks(ck: "tables.Checker", root: str,
                 phases: dict[str, Any]) -> None:
    """Step the transcription beside the engine's own frame sweep.

    Every other check in this file compares a *creator's* output. This one
    compares the **arms**, which is what `docs/28` §12 item 1's second half
    said had never been done: `tools/blob_runtime.py` is a transcription of
    `aBlob_Update` and `godot/game/fx/` is a transcription of that, so the
    Godot suite diffs two readings of one listing and cannot tell whether the
    listing is right.

    The capture calls `aCheckInBlobObjects` -- the routine a frame calls --
    and reads the pool between rounds. The model is re-seeded from the
    **measured** second-generator seed at the start of each round, so a slot
    that drew in an earlier round cannot drift the comparison; the engine
    walks the pool by ascending index and so does this, which is what makes
    the prefix of the stream the same.
    """
    import blob_runtime
    from inclib import eng3d

    b = tables.Binary(root)
    tablesets = eng3d.load(root)
    base = _tick_state(phases)
    landed = sorted(n for n in phases
                    if n.startswith("ticks_") or n.startswith("arms_"))
    ck.equal("native.tick_phases", landed, TICK_PHASES,
             lambda v: f"{len(v)} creator pool(s) stepped inside the engine: "
                       f"{sum(1 for n in v if n.startswith('ticks_'))} through "
                       "the frame sweep and "
                       f"{sum(1 for n in v if n.startswith('arms_'))} through "
                       "aBlob_Update directly")
    if not landed:
        return

    arm_of_kind = _arm_of_kind()
    # **The seekers' target.**  Every other arm is a closed function of its own
    # record; these three read the unit map, and the capture's adapter used to
    # answer nothing, which is why they were the only stepped arms that
    # disagreed.  The position comes from the `hooks` phase's own sweep of
    # `aGetStdObjectPosition`, so it is measured rather than assumed -- see
    # :data:`SEEK_OBJECT_ID` for what "measured" covers and what it does not.
    positions = _seek_positions(phases)
    # **The model lookup, measured.**  `docs/97` §20.5: the two swap arms store
    # `0x004038F0`'s answer straight into the record, so without this the diff
    # compares an engine handle against an adapter's index into its own list.
    handles = {str(k): int(v) for k, v in (phases.get("models") or {}).items()}
    agreed: dict[int, bool] = {}
    rounds_seen = slots_seen = 0
    for name in landed:
        phase = phases[name]
        rounds = [parse_slots(bytes.fromhex(h)) for h in phase["rounds"]]
        seeds = phase.get("seed2") or []
        if len(rounds) < 2 or len(seeds) < len(rounds):
            continue
        live = [index for index, record in enumerate(rounds[0])
                if record is not None]
        slots_seen += len(live)
        models = [blob_runtime.Blob(
            **{f: rounds[0][index][f] for f in TICK_FIELDS},
            slot_tag=(base + RECORD_BYTES * index) & 0xFF) for index in live]
        kinds = [rounds[0][index]["kind"] for index in live]
        dropped = [False] * len(live)
        previous = [rounds[0][index]["life"] for index in live]
        for step in range(1, len(rounds)):
            rounds_seen += 1
            hooks = _seek_hooks(seeds[step - 1], positions, tablesets,
                                handles)
            for position, index in enumerate(live):
                if dropped[position]:
                    continue
                blob = models[position]
                if blob.alive:
                    blob_runtime.tick_blob(blob, hooks)
                arm = arm_of_kind.get(kinds[position])
                if arm is None:
                    continue
                record = rounds[step][index]
                # **A freed slot is reused within the same round.**  The engine
                # walks slots in ascending order, so a blob that spawns while
                # slot 1 is being ticked lands in slot 1 the moment slot 1 is
                # freed later in that same round, and the read at the end of
                # the round shows a *different* blob at the tracked index --
                # of the same kind, often, since a kind-75 emitter spawns more
                # kind 75.  Comparing on compares two unrelated records.
                #
                # The tell is **life**, not kind: the wrapper decrements it by
                # exactly one per tick and holds it only at the immortal 0xFF,
                # so a record whose life is neither `was` nor `was - 1` is not
                # the record that was there before.  Stopping there is honest
                # in both directions -- an arm that wrongly deletes early
                # still fails, because the engine's record for its slot *is* a
                # continuation and the comparison runs.  That is how kind 11's
                # spurious self-delete was caught rather than excused.
                was = previous[position]
                continues = (record is not None and was is not None
                             and record["life"] in (was, was - 1))
                if record is not None and not continues and not blob.alive:
                    dropped[position] = True
                    continue
                previous[position] = None if record is None else record["life"]
                agreed.setdefault(arm, True)
                if not _tick_agrees(blob, record):
                    agreed[arm] = False
    ck.check("native.tick_rounds_compared", rounds_seen > 0,
             f"{rounds_seen} round(s) over {slots_seen} occupied slot(s)")
    ck.equal("native.tick_rounds_per_phase",
             sorted({len(phases[n]["rounds"]) for n in landed}),
             [TICK_ROUNDS + 1],
             lambda v: f"every phase holds {v} read(s): the pool before the "
                       f"first tick and after each of {TICK_ROUNDS}")
    # **The diff must look at the whole record.**  A field quietly dropped
    # from the comparison is a field the engine is no longer consulted about,
    # and the count would not move.
    ck.equal("native.tick_fields",
             sorted(TICK_FIELDS), sorted(parse_records(b"\x01" + b"\0" * (RECORD_BYTES - 1))[0]
                                         .keys() - {"slot"}),
             lambda v: f"{len(v)} field(s) compared -- every one "
                       "`parse_records` reads")
    ck.check("native.tick_entries",
             b.u8(POOL_TICK) == 0x56 and b.u8(POOL_TICK + 1) == 0x57
             and b.u8(BLOB_ARM) == 0x83 and b.u8(BLOB_ARM + 1) == 0xEC
             and b.u32(POOL_TICK + 0x89) == POOL_TICK_RECORDS,
             f"0x{POOL_TICK:08X} walks {POOL_TICK_RECORDS} records and "
             f"0x{BLOB_ARM:08X} opens with its own frame")
    # **What a shot can reach at all**, from the creators' own records rather
    # than from the tick phases: an arm no creator populates is out of this
    # capture's reach whatever Wine does, and separating the two numbers keeps
    # a thin capture from looking like a small engine.
    reachable = {arm_of_kind[record["kind"]]
                 for name, phase in phases.items()
                 if name.startswith("0x")
                 for record in (phase.get("records") or [])
                 if record["kind"] in arm_of_kind}
    ck.equal("native.tick_arms_reachable", len(reachable),
             TICK_ARMS_REACHABLE,
             lambda v: f"{v} of 74 arms are populated by a creator a weapon "
                       "switch selects; the other 50 are not reachable by "
                       "firing anything and no capture of this shape reaches "
                       "them")
    ck.equal("native.tick_arms_seen", len(agreed), len(TICK_ARMS_SEEN),
             lambda v: f"{v} arm(s) were actually stepped")
    ck.equal("native.tick_arms_stepped", sorted(agreed), TICK_ARMS_SEEN,
             lambda v: f"{len(v)} arm(s), by index")
    # **A diff that cannot fail is not a diff.**  The reuse rule above stops
    # comparing a slot on purpose, and a rule that stopped too eagerly would
    # turn every disagreement into silence and report 24 of 24.  So the same
    # machinery is handed a model that is deliberately one unit wrong and has
    # to say so.
    ck.check("native.tick_diff_is_discriminating",
             _tick_disagrees_when_perturbed(phases, landed, base, tablesets),
             "a model started one unit off its captured record fails the "
             "same comparison the arms pass")
    ck.equal("native.tick_arms_unresolved",
             tuple(sorted(a for a, ok in agreed.items() if not ok)),
             TICK_ARMS_UNRESOLVED,
             lambda v: f"{len(v)} stepped arm(s) disagree with the engine")
    _unit_object_checks(ck, phases)
    _creator_program_checks(ck, root, phases)
    _seek_checks(ck, b, phases, arm_of_kind, tablesets)
    _poked_checks(ck, phases, base, tablesets, positions, handles)
    _probe_checks(ck, phases, base, tablesets, positions, handles)
    _mode_checks(ck, phases, base, tablesets, positions, handles)
    _spawn_checks(ck, phases, base, tablesets, positions, handles)
    # The fixture the Godot suite reads carries the same two lists, so the
    # boundary it prints cannot drift from the capture that earned it.
    ck.equal("native.tick_arms_are_the_fixture's",
             (blob_runtime.NATIVE_ARMS, blob_runtime.UNRESOLVED_ARMS),
             (tuple(TICK_ARMS_NATIVE), TICK_ARMS_UNRESOLVED),
             lambda v: f"blob_runtime carries the same {len(v[0])} native "
                       f"and {len(v[1])} unresolved arm(s)")
    ck.equal("native.tick_arms_native",
             sorted(a for a, ok in agreed.items() if ok), TICK_ARMS_NATIVE,
             lambda v: f"{len(v)} arm(s) reproduce the engine's own records "
                       f"field for field; the other {len(agreed) - len(v)} "
                       "stepped arm(s) differ and stay executable-Python")


class ArmLines:
    """Which transcribed lines of each arm the engine comparison executed.

    `docs/97` §21.  Every other number here says the model **agreed** with the
    engine; this one says how much of the model was asked.  An arm is a
    function with branches, a poked record is one point of its input space,
    and a branch no input reached is a transcription nothing has tested --
    which is exactly the shape of the defect a mutation battery once found in
    kind 76 (`docs/97` §18.5).

    It is **Python line coverage**, and honest about being that: the arms are
    a transcription and the lines are the transcription's, not the engine's
    basic blocks.  It is a fair proxy for one specific reason -- the same
    replay it measures is the one that reproduces the engine's records field
    for field, so a line the replay ran is a line the engine ran too.  The
    converse does not hold: a line the replay never ran might still be right,
    and might still be wrong, and that is the whole point of naming it.
    """

    def __init__(self) -> None:
        self.hit: dict[str, set[int]] = {}
        self._previous: Any = None

    def __enter__(self) -> "ArmLines":
        self._previous = sys.gettrace()
        sys.settrace(self._trace)
        return self

    def __exit__(self, *exc: Any) -> bool:
        sys.settrace(self._previous)
        return False

    def _trace(self, frame: Any, event: str, _arg: Any) -> Any:
        if frame.f_code.co_name not in _watched_functions():
            return None
        if event == "line":
            self.hit.setdefault(frame.f_code.co_name, set()).add(frame.f_lineno)
        return self._trace


#: The shared steps an arm reaches through, traced beside the arms themselves.
#: They are not attributed to any one arm -- `_seek` belongs to three and
#: `_move` to most of them -- so they are reported as their own row.
ARM_HELPERS = ("_seek", "_move", "_orient", "_spawn", "_drift", "_fall",
               "_request_delete", "_explicit_delete")


def _watched_functions() -> frozenset[str]:
    import blob_runtime
    global _WATCHED
    if _WATCHED is None:
        _WATCHED = frozenset(
            [fn.__code__.co_name for fn in blob_runtime.HANDLERS.values()]
            + [name for name in ARM_HELPERS if hasattr(blob_runtime, name)])
    return _WATCHED


_WATCHED: frozenset[str] | None = None


def _executable_lines(fn: Any) -> set[int]:
    """Every line of *fn* that can be executed, less its own `def`."""
    code = fn.__code__
    return {line for _start, _end, line in code.co_lines()
            if line is not None and line != code.co_firstlineno}


def _arm_functions() -> dict[int, Any]:
    """``arm -> the function the dispatch table sends its lowest kind to``."""
    import blob_runtime
    arm_of = _arm_of_kind()
    out: dict[int, Any] = {}
    for kind in sorted(blob_runtime.HANDLERS):
        arm = arm_of.get(kind)
        if arm is not None:
            out.setdefault(arm, blob_runtime.HANDLERS[kind])
    return out


def _source_of(fn: Any, line: int) -> str:
    """One line of the transcription, stripped -- the stable name for a gap.

    Uncovered lines are pinned by their **text** and not their number: a line
    number moves whenever anything above it is edited, and a pin that breaks
    for an unrelated reason gets deleted rather than earned.
    """
    import inspect
    source, first = inspect.getsourcelines(inspect.getmodule(fn))
    return source[line - 1].strip() if 0 < line <= len(source) else ""


def _coverage_checks(ck: "tables.Checker", lines: "ArmLines") -> None:
    """What the comparison reached, and -- by name -- what it did not."""
    arms = _arm_functions()
    total = covered = 0
    gaps: list[tuple[int, str]] = []
    for arm, fn in sorted(arms.items()):
        wanted = _executable_lines(fn)
        seen = lines.hit.get(fn.__code__.co_name, set()) & wanted
        total += len(wanted)
        covered += len(seen)
        gaps += [(arm, _source_of(fn, line)) for line in sorted(wanted - seen)]
    ck.equal("coverage.arm_lines", (covered, total), COVERAGE_ARM_LINES,
             lambda v: f"{v[0]} of {v[1]} transcribed arm line(s) were "
                       "executed by the replay that reproduces the engine's "
                       "records")
    ck.equal("coverage.arms_complete",
             sum(1 for arm, fn in arms.items()
                 if not (_executable_lines(fn)
                         - lines.hit.get(fn.__code__.co_name, set()))),
             COVERAGE_ARMS_COMPLETE,
             lambda n: f"{n} of {len(arms)} arm(s) have every transcribed "
                       "line executed against the engine")
    ck.equal("coverage.uncovered_lines", gaps, COVERAGE_UNCOVERED,
             lambda v: f"{len(v)} arm line(s) no captured input reaches, by "
                       "name rather than by line number")


def _vector_key(phase: dict[str, Any], position: int
                ) -> tuple[tuple[str, int], ...]:
    """The input vector one entry of a poked phase was stepped at.

    A phase written before vectors existed carries none, and *is* the first
    vector -- which is why the fallback is `POKE_VECTORS[0]` rather than an
    empty tuple: an unlabelled phase must not read as a distinct point.
    """
    vectors = phase.get("vectors")
    writes = (vectors[position] if vectors and position < len(vectors)
              else POKE_VECTORS[0]["writes"])
    return tuple(sorted((str(k), int(v)) for k, v in writes.items()))


def _replay_poked(phases: dict[str, Any], names: list[str], base: int,
                  tablesets: Any,
                  positions: dict[int, tuple[int, int, int]],
                  handles: dict[str, int],
                  emitter_mode: int = 0) -> tuple[
                      dict[int, bool],
                      dict[int, set[tuple[tuple[str, int], ...]]], int]:
    """Replay one family of poked phases against the engine's snapshots.

    One call, one snapshot: the comparison is per `aBlob_Update` rather than
    per round, so an arm that faults costs the arms after it in its plan and
    nothing before it, and each arm's writes are isolated from its
    neighbours'.  The model is re-seeded from the **measured** second-generator
    seed before every call for the same reason the tick diff is: an arm that
    draws must draw from where the engine drew.

    Returns ``(agreed, stepped_at, steps)`` -- whether each arm reproduced
    every snapshot, which input vectors it was stepped at, and how many
    comparisons were made.
    """
    import blob_runtime

    arm_of_kind = _arm_of_kind()
    agreed: dict[int, bool] = {}
    stepped_at: dict[int, set[tuple[tuple[str, int], ...]]] = {}
    steps_seen = 0
    for name in names:
        phase = phases[name]
        start = phase.get("start")
        steps = phase.get("steps") or []
        slots = phase.get("slots") or []
        kinds = phase.get("kinds") or []
        if not start or not slots:
            continue
        first = parse_slots(bytes.fromhex(start["pool"]))
        models: dict[int, Any] = {}
        previous: dict[int, int | None] = {}
        dropped: set[int] = set()
        for position, slot in enumerate(slots):
            record = first[slot]
            if record is None or record["kind"] != kinds[position]:
                continue
            models[slot] = blob_runtime.Blob(
                **{f: record[f] for f in TICK_FIELDS},
                slot_tag=(base + RECORD_BYTES * slot) & 0xFF)
            previous[slot] = record["life"]
        seed = start["seed"]
        for index, step in enumerate(steps):
            slot = slots[index % len(slots)]
            after = parse_slots(bytes.fromhex(step["pool"]))[slot]
            if slot in models and slot not in dropped:
                blob = models[slot]
                if blob.alive:
                    hooks = _seek_hooks(seed or 0.0, positions, tablesets,
                                        handles, emitter_mode)
                    blob_runtime.tick_blob(blob, hooks)
                was = previous[slot]
                continues = (after is not None and was is not None
                             and after["life"] in (was, was - 1))
                if after is not None and not continues and not blob.alive:
                    dropped.add(slot)
                else:
                    previous[slot] = None if after is None else after["life"]
                    position = slots.index(slot)
                    arm = arm_of_kind[kinds[position]]
                    agreed.setdefault(arm, True)
                    stepped_at.setdefault(arm, set()).add(
                        _vector_key(phase, position))
                    steps_seen += 1
                    if not _tick_agrees(blob, after):
                        agreed[arm] = False
            seed = step["seed"]
    return agreed, stepped_at, steps_seen


#: Poked phases whose vectors are chosen against a coverage measurement rather
#: than swept over every arm.  Their own accounting: two of the four arms they
#: reach are creator-filled and already native, so they are not part of the
#: fifty.
PROBE_PREFIX = "poked_probe_"


def _probe_checks(ck: "tables.Checker", phases: dict[str, Any], base: int,
                  tablesets: Any,
                  positions: dict[int, tuple[int, int, int]],
                  handles: dict[str, int]) -> None:
    """The targeted vectors -- the branches a sweep cannot reach.

    `docs/97` §21: five of the seventy-four arms have a branch gated by
    something a uniform vector cannot set at the same time as the rest --
    an `aux` naming a **dead** unit, a life of sixty, a record standing on
    its own target.  These are those, one arm and one vector per slot.
    """
    landed = sorted(n for n in phases if n.startswith(PROBE_PREFIX))
    ck.equal("probe.phases", landed, PROBE_PHASES,
             lambda v: f"{len(v)} probe plan(s) landed")
    if not landed:
        return
    agreed, stepped_at, steps_seen = _replay_poked(
        phases, landed, base, tablesets, positions, handles)
    ck.check("probe.steps_compared", steps_seen > 0,
             f"{steps_seen} single-arm call(s) compared under a targeted "
             "vector")
    ck.equal("probe.arms_stepped", sorted(stepped_at), PROBE_ARMS,
             lambda v: f"{len(v)} arm(s) reached by a vector chosen against "
                       "the coverage measurement")
    ck.equal("probe.arms_agree", sorted(a for a, ok in agreed.items() if ok),
             PROBE_ARMS,
             lambda v: f"{len(v)} of them reproduce the engine's record under "
                       "the probe vector too")
    ck.equal("probe.vectors", sorted((arm, len(seen))
                                     for arm, seen in stepped_at.items()),
             PROBE_VECTORS_PER_ARM, tables.Checker.brief)


#: What kind 59's arm is expected to have been stepped at, and the readings
#: of the output-system global the plan takes around its write.  The middle
#: one is the whole point: it says the write **took**, so a run of the arm
#: that agreed proves the special branch ran rather than that both sides
#: skipped it.
MODE_ARM = 56
MODE_READS = [EMITTER_MODE_MEASURED, EMITTER_MODE_SPECIAL,
              EMITTER_MODE_MEASURED]


def _mode_checks(ck: "tables.Checker", phases: dict[str, Any], base: int,
                 tablesets: Any,
                 positions: dict[int, tuple[int, int, int]],
                 handles: dict[str, int]) -> None:
    """Kind 59's special emitter, with the display mode written under it.

    Everything else in this file steps an arm by giving it a **record**.
    This one cannot: `0x004200E4` asks `0x00461E80` what output mode the game
    is in and takes its second branch only for one answer, so the six lines
    behind it were the last in the seventy-four that no vector could reach
    (`docs/97` §21.2 listed them; §23 closes them).  The plan writes the mode
    for its own length through the game's own imported `memcpy`, steps the
    arm, and puts it back.

    Three claims, and the third is what makes the first two mean anything:
    the arm reproduces the engine's record; the global read back **after**
    the write is `EMITTER_MODE_SPECIAL`, so the branch was taken; and the
    reading before it is `EMITTER_MODE_MEASURED`, which is both what this
    host's Wine session runs at and what the restore puts back.
    """
    phase = phases.get(MODE_PHASE)
    ck.check("mode.phase_landed", bool(phase),
             f"{MODE_PHASE} captured -- the one plan that writes engine "
             "state outside the pool")
    if not phase:
        return
    ck.equal("mode.global_readings", phase.get("mode") or [], MODE_READS,
             lambda v: "the output-system mode read before the write, after "
                       f"it and after the restore: {v} -- the middle value "
                       "is what says the special branch could run at all")
    agreed, stepped_at, steps_seen = _replay_poked(
        phases, [MODE_PHASE], base, tablesets, positions, handles,
        emitter_mode=EMITTER_MODE_SPECIAL)
    ck.check("mode.steps_compared", steps_seen > 0,
             f"{steps_seen} call(s) of kind {EMITTER_ARM_KIND}'s arm "
             "compared with the special emitter live")
    ck.equal("mode.arms_stepped", sorted(stepped_at), [MODE_ARM],
             lambda v: f"arm(s) {v} stepped under the written mode")
    ck.equal("mode.arms_agree", sorted(a for a, ok in agreed.items() if ok),
             [MODE_ARM],
             lambda v: "the arm reproduces the engine's record on the branch "
                       "no record can select")
    # **What the branch costs the stream.**  The record comparison above
    # re-seeds from the engine before every call and so cannot see a draw
    # count at all; the seed either side can.  A step that found the record
    # already gone advances nothing, so the zeros are dropped and both sides
    # are required to have something left.
    special = _kind_advances(phases, [MODE_PHASE], EMITTER_ARM_KIND)
    ordinary = _kind_advances(
        phases,
        sorted(n for n in phases if n.startswith("poked_")),
        EMITTER_ARM_KIND)
    ck.check("mode.special_draws",
             bool(special) and bool(ordinary)
             and set(special) == {EMITTER_ARM_DRAWS + EMITTER_SPECIAL_DRAWS}
             and set(ordinary) == {EMITTER_ARM_DRAWS},
             f"kind {EMITTER_ARM_KIND}'s arm advances the second generator "
             f"by {sorted(set(special))} under the written mode over "
             f"{len(special)} call(s) and by {sorted(set(ordinary))} without "
             f"it over {len(ordinary)} -- the special emitter's "
             f"{EMITTER_SPECIAL_DRAWS} draws, measured rather than counted "
             "off the listing")


def _kind_advances(phases: dict[str, Any], names: list[str],
                   kind: int) -> list[int]:
    """How far each call of one poked kind advanced the second generator.

    One entry per `aBlob_Update` of a record poked to ``kind``, in call order,
    with the calls that advanced nothing dropped -- those are the steps that
    found the record already expired, and a dead record's arm is not a draw
    count.
    """
    out: list[int] = []
    for name in names:
        phase = phases.get(name) or {}
        slots = phase.get("slots") or []
        kinds = phase.get("kinds") or []
        steps = phase.get("steps") or []
        start = phase.get("start") or {}
        if not slots or kind not in kinds:
            continue
        wanted = {index for index, k in enumerate(kinds) if k == kind}
        seed = start.get("seed")
        for index, step in enumerate(steps):
            after = step.get("seed")
            moved = (seed_advance(seed, after)
                     if seed is not None and after is not None else None)
            seed = after
            if index % len(slots) in wanted and moved:
                out.append(moved)
    return out


def _poked_checks(ck: "tables.Checker", phases: dict[str, Any], base: int,
                  tablesets: Any,
                  positions: dict[int, tuple[int, int, int]],
                  handles: dict[str, int]) -> None:
    """The fifty arms no creator reaches, swept once per input vector."""
    import blob_runtime

    landed = sorted(n for n in phases
                    if n.startswith("poked_") and not n.startswith(PROBE_PREFIX))
    ck.equal("poked.phases", landed, POKED_PHASES,
             lambda v: f"{len(v)} poked batch(es) landed")
    if not landed:
        return
    agreed, stepped_at, steps_seen = _replay_poked(
        phases, landed, base, tablesets, positions, handles)
    ck.check("poked.steps_compared", steps_seen > 0,
             f"{steps_seen} single-arm call(s) compared, one snapshot each")
    # **Pin the inputs, not only the result.**  A mutation battery caught
    # kind 76's `life <= 4` branch being transcribed and never run, because a
    # donor's `life` of 30 cannot reach it in four rounds.  The poke writes
    # `life` as well for that reason, and a second sweep vector and seven
    # probes were added for the same one -- `docs/97` §21 measures which
    # transcribed lines the comparison reaches, and these pin the inputs that
    # earned the figure.  A thinner capture that went back to one vector
    # fails rather than quietly checking less.
    ck.equal("poked.lives_written",
             sorted({parse_slots(
                         bytes.fromhex(phases[name]["start"]["pool"]))[slot]["life"]
                     for name in landed
                     for slot in phases[name]["slots"]}),
             POKE_LIVES,
             lambda v: f"the poked records start at life {v} -- each short "
                       "enough to reach a branch the others cannot")
    ck.equal("poked.rounds_per_phase",
             sorted({len(phases[name]["steps"]) // len(phases[name]["slots"])
                     for name in landed}),
             POKE_ROUNDS_SEEN,
             lambda v: f"the phases step each record {v} time(s)")
    ck.equal("poked.vectors_per_arm",
             sorted({(arm, len(seen)) for arm, seen in stepped_at.items()},
                    key=lambda p: (p[1], p[0])),
             POKED_VECTORS_PER_ARM, tables.Checker.brief)
    ck.equal("poked.arms_at_two_vectors_or_more",
             sum(1 for seen in stepped_at.values() if len(seen) > 1),
             POKED_ARMS_MULTI_VECTOR,
             lambda n: f"{n} arm(s) are stepped at more than one point of "
                       "their input space, so the agreement is not a "
                       "property of one record")
    ck.equal("poked.model_handles", sorted(handles), sorted(_model_names()),
             lambda v: f"{len(v)} model name(s) resolved by the engine's own "
                       "lookup, so the two swap arms are compared against a "
                       "measured handle rather than an adapter's index")
    ck.equal("poked.arms_stepped", sorted(agreed), POKED_ARMS_STEPPED,
             lambda v: f"{len(v)} arm(s) no creator reaches were stepped by "
                       "rewriting a donor record's kind byte")
    ck.equal("poked.arms_native", sorted(a for a, ok in agreed.items() if ok),
             POKED_ARMS_NATIVE,
             lambda v: f"{len(v)} of them reproduce the engine's record field "
                       "for field")
    ck.equal("poked.arms_disagree",
             sorted(a for a, ok in agreed.items() if not ok),
             POKED_ARMS_DISAGREE,
             lambda v: f"{len(v)} disagree and are named rather than rounded "
                       "off")
    _poked_seek_check(ck, phases, base, tablesets, positions,
                      {u["slot"]: u["object"]
                       for u in (phases.get("units") or [])})


def _poked_seek_check(ck: "tables.Checker", phases: dict[str, Any], base: int,
                      tablesets: Any,
                      positions: dict[int, tuple[int, int, int]],
                      byte_of: dict[int, int]) -> None:
    """Every poked seeker, swept against the object its unit record names.

    `seek.target_is_unique` singles out object 1 for the captured seekers by
    elimination, and `units.seeker_target_is_the_byte` reads `[unit + 0x4B]`
    and finds 1 there.  This is the two put together at every *other* point
    the capture reaches: a poked record carries whichever `+0x54` its vector
    wrote -- 0 from the donor, 10 from the second sweep vector, 1 and 14 from
    the probes -- and sweeping the fifteen measured positions has to leave
    exactly the object that unit's byte names, at each of them.

    A record whose byte names an object `aGetStdObjectPosition` refuses is
    **not** in the comparison: there is no position to fit, which is the
    `target_missing` return and is checked by the arm's own coverage instead.
    """
    import blob_runtime

    candidates = sorted(positions)
    fits: list[tuple[int, int, bool]] = []
    for name in sorted(n for n in phases if n.startswith("poked_")):
        phase = phases[name]
        start = phase.get("start")
        slots = phase.get("slots") or []
        kinds = phase.get("kinds") or []
        if not start or not slots:
            continue
        first = parse_slots(bytes.fromhex(start["pool"]))
        for index, step in enumerate(phase.get("steps") or []):
            position = index % len(slots)
            kind = kinds[position]
            if kind not in SEEK_ARMS or index >= len(slots):
                continue
            record = first[slots[position]]
            after = parse_slots(bytes.fromhex(step["pool"]))[slots[position]]
            if record is None or after is None or record["kind"] != kind:
                continue
            wanted = byte_of.get(record["aux"])
            if wanted is None or wanted not in positions:
                continue
            fit = []
            for oid in candidates:
                blob = blob_runtime.Blob(
                    **{f: record[f] for f in TICK_FIELDS},
                    slot_tag=(base + RECORD_BYTES * slots[position]) & 0xFF)
                hooks = blob_runtime.CaseHooks(start["seed"] or 0.0,
                                               target=positions[oid],
                                               tables=tablesets)
                blob_runtime.tick_blob(blob, hooks)
                if _tick_agrees(blob, after):
                    fit.append(oid)
            fits.append((record["aux"], wanted, tuple(fit) == (wanted,)))
    ck.check("poked.seeker_present", len(fits) > 0,
             f"{len(fits)} poked seeker step(s) swept over "
             f"{len(candidates)} measured object position(s)")
    ck.equal("poked.seeker_slots_swept",
             sorted({(aux, wanted) for aux, wanted, _ok in fits}),
             POKED_SEEKER_SLOTS,
             lambda v: f"{len(v)} distinct (unit-map slot, [unit + 0x4B]) "
                       "pair(s) among the poked seekers")
    ck.equal("poked.seeker_target_is_its_own_byte",
             [(aux, wanted) for aux, wanted, ok in fits if not ok], [],
             lambda v: "every poked seeker steers at exactly the object its "
                       "unit record's +0x4B names, and at no other of the "
                       f"fifteen" if not v else f"{len(v)} disagreement(s)")


def _tick_disagrees_when_perturbed(phases: dict[str, Any], landed: list[str],
                                   base: int, tablesets: Any) -> bool:
    """Whether the tick diff notices a model that starts one unit wrong."""
    import blob_runtime

    for name in landed:
        phase = phases[name]
        rounds = [parse_slots(bytes.fromhex(h)) for h in phase["rounds"]]
        seeds = phase.get("seed2") or []
        if len(rounds) < 2 or not seeds:
            continue
        for index, start in enumerate(rounds[0]):
            if start is None or rounds[1][index] is None:
                continue
            fields = dict((f, start[f]) for f in TICK_FIELDS)
            fields["x"] += 1
            blob = blob_runtime.Blob(
                **fields, slot_tag=(base + RECORD_BYTES * index) & 0xFF)
            hooks = blob_runtime.CaseHooks(seeds[0], target=None,
                                           tables=tablesets)
            blob_runtime.tick_blob(blob, hooks)
            return not _tick_agrees(blob, rounds[1][index])
    return False


#: **The four arms that add a draw to a coordinate**, and what each draws
#: before the first jitter.  ``fiadd`` says which reading the bytes carry:
#: three add the coordinate to the draw and truncate the sum, one truncates
#: the draw and adds the coordinate through `movsx ecx, ax`.
#: `blob_tables.py`'s `spawn.jitter_forms` pins the twelve instructions; this
#: is the measurement beside that reading, and the seeds are chosen so every
#: jitter lands where the two forms disagree.
JITTER_ARMS: dict[int, dict[str, Any]] = {
    56: {"first": (2, 5), "jitter": (-50, 100), "fiadd": True},
    62: {"first": (0, 10), "jitter": (-1000, 2000), "fiadd": True},
    67: {"first": (0, 7), "jitter": (-1000, 2000), "fiadd": True},
    77: {"first": (5, 10), "jitter": (-20, 40), "fiadd": False},
}


def _jitter_forms(seed: float, kind: int, position: tuple[int, int, int]
                  ) -> tuple[tuple[int, ...], tuple[int, ...]]:
    """The two readings of one arm's jitter, **from the seed and nothing else**.

    Neither is the transcription's: both are rebuilt here from the generator
    and the record's position, so the check compares the engine against two
    candidates rather than against itself.  Returned in `(x, y, z)` order,
    which is the constructor's; the draws come in the other one.
    """
    from inclib import blob_creators as creators
    from inclib.rng import ARandom

    spec = JITTER_ARMS[kind]
    rng = ARandom(seed)
    rng.raw(*spec["first"])
    added, truncated = [], []
    for coordinate in (position[2], position[1], position[0]):
        value = rng.raw(*spec["jitter"])
        added.append(creators.ftol(value + coordinate))
        truncated.append(coordinate + creators.ftol(value))
    return tuple(reversed(added)), tuple(reversed(truncated))


def _spawn_hooks(seed: float, positions: dict[int, tuple[int, int, int]],
                 tables: Any, handles: dict[str, int]) -> Any:
    """:func:`_seek_hooks` that also records **where** each spawn was asked.

    An arm may ask before its own `_move` or after it, and the jitter check
    needs the position at the moment of the call rather than either end of
    the tick.
    """
    base = _seek_hooks(seed, positions, tables, handles)

    class _Hooks(type(base)):                                  # type: ignore
        def __init__(self, *args: Any, **kw: Any) -> None:
            super().__init__(*args, **kw)
            self.spawn_positions: list[tuple[int, int, int]] = []

        def spawn(self, creator: int, args: Any, source: Any) -> bool:
            self.spawn_positions.append((source.x, source.y, source.z))
            return super().spawn(creator, args, source)

    return _Hooks(seed, target=None, tables=tables)


def _run_arm_creators(result: Any, seed: float, tables: Any,
                      handles: dict[str, int], gore: int
                      ) -> tuple[Any, Any] | None:
    """Run what the arm asked for, from where the arm left the generator.

    The engine has **one** `aRandom2` stream and a creator called from an arm
    draws from it at the moment of the call, so the model's creator has to
    start where the model's arm stopped.  Answers ``None`` for a request this
    file has no program for, which is a gap rather than a disagreement.
    """
    from inclib import blob_creators as creators

    inputs = creators.DeathInputs(tiles={}, gore=gore, display_mode=0,
                                  models=handles, tables=tables)
    pool = creators.Pool(inputs)
    draws = creators.Draws(seed)
    for event in result.spawns:
        entry = creators.DEATH_PROGRAMS.get(event.creator)
        if entry is None:
            return None
        entry[1](pool, draws, event.args, inputs)
    return pool, draws


def _tick_agrees(blob: Any, record: dict[str, Any] | None) -> bool:
    """Whether the model's blob is the engine's record, field for field."""
    if record is None:
        return not blob.alive
    if not blob.alive:
        return False
    return all(getattr(blob, field) == record[field] for field in TICK_FIELDS)


def _arm_of_kind() -> dict[int, int]:
    """``kind -> arm index``, the same grouping the fixture carries."""
    import blob_runtime

    order: list[int] = []
    out: dict[int, int] = {}
    for kind in range(len(blob_runtime.HANDLERS)):
        key = id(blob_runtime.HANDLERS[kind])
        if key not in order:
            order.append(key)
        out[kind] = order.index(key)
    return out


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


#: What the two spawning families reached, pinned so a thinner capture fails
#: rather than reporting less.  The kinds are every arm the transcription asks
#: a creator from, and the creators are the thirteen an arm can reach --
#: twelve of them named nowhere else, which is the gap `docs/97` §49 closes.
SPAWN_KINDS_STEPPED = [3, 6, 15, 19, 22, 25, 26, 32, 36, 44, 47, 52, 56, 59,
                       62, 67, 69, 71, 73, 75, 77]
SPAWN_CREATORS_REACHED = [0x00420950, 0x00423720, 0x00428E30, 0x00428ED0,
                          0x00428F70, 0x00429390, 0x00429430, 0x0042A410,
                          0x0042A480, 0x0042A7A0, 0x0042A9D0, 0x0042B150,
                          0x0042B300]
#: Arms whose children the capture and the transcription disagree about.
SPAWN_ARMS_DISAGREE: list[int] = []


def _replay_spawn(phases: dict[str, Any], names: list[str], base: int,
                  tablesets: Any, positions: dict[int, tuple[int, int, int]],
                  handles: dict[str, int], gore: int) -> dict[str, Any]:
    """Replay the spawning families: the arm, then what the arm asked for.

    Each entry is a pool of its own -- reset, donor, one poked record -- so
    everything alive past the donor's own slots after a call is that arm's
    brood, and the diff is a diff of the **creator's arguments**, which no
    other phase here measures.

    Three things are compared per call: the poked record itself, exactly as
    the poked family compares it; the records the arm's creator left, field
    for field and in slot order; and the generator's seed afterwards, which
    accounts for the draws of a brood too big for the read window.
    """
    import blob_runtime

    agreed: dict[int, bool] = {}
    creators_seen: dict[int, int] = {}
    children = 0
    calls = 0
    truncated = 0
    discriminated: list[tuple[int, float]] = []
    for name in names:
        phase = phases[name]
        slot = phase["slot"]
        for index, entry in enumerate(phase.get("entries") or []):
            kind = phase["kinds"][index]
            seed = phase["seeds"][index]
            start = entry.get("start")
            if not start:
                continue
            first = parse_slots(bytes.fromhex(start["pool"]))
            record = first[slot]
            if record is None or record["kind"] != kind:
                continue
            blob = blob_runtime.Blob(
                **{f: record[f] for f in TICK_FIELDS},
                slot_tag=(base + RECORD_BYTES * slot) & 0xFF)
            agreed.setdefault(kind, True)
            previous = first
            for step in entry["steps"]:
                after = parse_slots(bytes.fromhex(step["pool"]))
                born = [r for position, r in enumerate(after)
                        if r is not None and previous[position] is None]
                full = all(r is not None for r in after)
                if step.get("born") is not None and step["born"] != born:
                    agreed[kind] = False
                if not blob.alive:
                    previous = after
                    continue
                hooks = _spawn_hooks(seed, positions, tablesets, handles)
                result = blob_runtime.tick_blob(blob, hooks)
                calls += 1
                if not _tick_agrees(blob, after[slot]):
                    agreed[kind] = False
                made = _run_arm_creators(result, hooks.rng.seed, tablesets,
                                         handles, gore)
                for event in result.spawns:
                    creators_seen[event.creator] = \
                        creators_seen.get(event.creator, 0) + 1
                if made is None:
                    if result.spawns:
                        agreed[kind] = False
                    previous = after
                    continue
                pool, draws = made
                wanted = pool.records
                # A brood bigger than the window is compared as the prefix it
                # is; the seed below still accounts for the rest.
                if full and len(born) < len(wanted):
                    wanted = wanted[:len(born)]
                    truncated += 1
                if len(wanted) != len(born):
                    agreed[kind] = False
                for model_record, engine_record in zip(wanted, born):
                    children += 1
                    if any(model_record[f] != engine_record[f]
                           for f in TICK_FIELDS if f in model_record):
                        agreed[kind] = False
                if result.spawns and step["seed"] is not None \
                        and draws.seed != step["seed"]:
                    agreed[kind] = False
                if kind in JITTER_ARMS and hooks.spawn_positions and born:
                    added, cut = _jitter_forms(seed, kind,
                                               hooks.spawn_positions[0])
                    if added != cut:
                        engine = (born[0]["x"], born[0]["y"], born[0]["z"])
                        wanted_form = (added if JITTER_ARMS[kind]["fiadd"]
                                       else cut)
                        discriminated.append((kind, seed))
                        if engine != wanted_form:
                            agreed[kind] = False
                previous = after
    return {"agreed": agreed, "creators": creators_seen, "children": children,
            "calls": calls, "truncated": truncated,
            "discriminated": discriminated}


def _spawn_checks(ck: "tables.Checker", phases: dict[str, Any], base: int,
                  tablesets: Any, positions: dict[int, tuple[int, int, int]],
                  handles: dict[str, int]) -> None:
    """What a creator is **given** -- `docs/97` §49.

    The poked family measures an arm's own record and reads twelve slots; a
    child lands past them, so an arm's arguments to its creator were the one
    thing about the effect layer nothing here measured.  `docs/97` §48 found
    five wrong ones by stepping the arms by hand, which is what said this
    needed a phase family rather than a note.
    """
    landed = sorted(n for n in phases
                    if n.startswith(ZOOM_BOB_PREFIX) or n.startswith(SPAWN_PREFIX))
    ck.equal("spawn.phases", len(landed),
             len(spawn_batches(spawn_entries(ZOOM_BOB_KINDS, SPAWN_SEEDS,
                                             (0, 0, 0))))
             + len(spawn_batches(spawn_entries(SPAWN_OTHER_KINDS,
                                               SPAWN_SEEDS[:1], (0, 0, 0)))),
             lambda v: f"{v} plan(s) of the two spawning families landed")
    if not landed:
        return
    gore = (phases.get("gore") or {}).get("value", 3)
    out = _replay_spawn(phases, landed, base, tablesets, positions, handles,
                        gore)
    ck.check("spawn.calls_compared", out["calls"] > 0,
             f"{out['calls']} single-arm call(s) replayed, "
             f"{out['children']} child record(s) compared field for field")
    ck.equal("spawn.arms_stepped", sorted(out["agreed"]), SPAWN_KINDS_STEPPED,
             lambda v: f"{len(v)} arm(s) that ask a creator for something "
                       "were stepped with the pool read wide enough to hold "
                       "the child")
    ck.equal("spawn.creators_reached", sorted(out["creators"]),
             SPAWN_CREATORS_REACHED,
             lambda v: f"{len(v)} creator(s) an arm calls ran in the engine "
                       "and in the model on the same arguments")
    ck.equal("spawn.arms_disagree",
             sorted(k for k, ok in out["agreed"].items() if not ok),
             SPAWN_ARMS_DISAGREE,
             lambda v: f"{len(v)} disagree and are named rather than rounded "
                       "off")
    # **The jitter check has to be able to fail.**  Two readings of kinds 56
    # and 77 agree everywhere except where a draw is negative with a
    # fraction, so a capture whose seed drifted positive would compare two
    # identical candidates and pass without measuring anything.  The seeds are
    # chosen to put every jitter there and this counts the calls where the
    # two candidates actually differed.
    ck.equal("spawn.jitter_discriminated",
             sorted({kind for kind, _seed in out["discriminated"]}),
             sorted(JITTER_ARMS),
             lambda v: f"{len(v)} arm(s) stepped on a draw where the two "
                       "readings give different answers, so the engine chose "
                       "between them")
    # **Read the overrides back out of the capture**, not out of the constant
    # beside them: comparing a table with itself is a check that cannot fail,
    # and this file keeps `native.tick_diff_is_discriminating` for exactly
    # that reason.  A fixture taken before an override was added fails here.
    overridden = sorted({kind for name in landed
                         for kind, seed in zip(phases[name]["kinds"],
                                               phases[name]["seeds"])
                         if seed not in SPAWN_SEEDS})
    ck.equal("spawn.seed_overrides", overridden, sorted(SPAWN_SEED_OVERRIDES),
             lambda v: f"{len(v)} arm(s) were stepped at a seed of their own, "
                       "their spawn being behind a roll neither sweep seed "
                       "passes")
    ck.check("spawn.jitter_seeds",
             {seed for _kind, seed in out["discriminated"]}
             <= {SPAWN_SEED_NEGATIVE} | set(SPAWN_SEED_OVERRIDES.values()),
             "the discriminating calls are the negative-jitter seed's and the "
             "overrides'; the positive seed is the same arms where the two "
             "readings agree")


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
        "units": units_plan(),
        "origins": origins_plan(),
        "symbols": symbols_plan(PLAN_FIXTURE_SYMBOLS),
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
                 for name, text in rendered.items()
                 if name not in ("state", "units", "origins", "symbols")),
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
                       "velocity column an unaided search solves to "
                       "(scale, base, span)")


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
        found = False
        for stride in range(1, 7):
            for offset in range(len(draws)):
                last = offset + stride * (len(values) - 1)
                if last >= len(draws):
                    break
                picks = [draws[offset + stride * i] for i in range(len(values))]
                if picks[0] == picks[1]:
                    continue
                # **The scale is searched, and it has to be.**  The engine
                # truncates with `ftol` and *then* shifts, so a column is
                # `scale * int(base + span*f)` and not `int(base + span*f)`.
                # Without this the solver missed a creator whose recipe the
                # disassembly hands over in three lines.
                for scale in FIT_SCALES:
                    if any(v % scale for v in values):
                        continue
                    scaled = [v // scale for v in values]
                    span = (scaled[1] - scaled[0]) / (picks[1] - picks[0])
                    base = scaled[0] - span * picks[0]
                    if all(abs(int(base + span * f) - v) <= 1
                           for f, v in zip(picks, scaled)):
                        explained.append(
                            f"{axis}={scale}*aRandom({base:.0f},{span:.0f})"
                            f"@{offset}+{stride}i")
                        found = True
                        break
                if found:
                    break
            if found:
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

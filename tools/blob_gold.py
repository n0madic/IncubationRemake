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

#: How many creators go into one plan.  One fault takes its whole plan down, so
#: this trades a re-run's cost against the number of Wine start-ups.
GROUP_SIZE = 5


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
        lines.append(f"end{creator:08X} = aResetBlobs()")
        lines.append(f"c{creator:08X}({args})")
        # **The read is hung on a call that touches nothing.** Hanging it on a
        # second `aResetBlobs()` wipes the pool before the read and every
        # creator comes back with zero records -- which looks exactly like the
        # CHECK-abort path and is not it. `aGetUnitMapElementPtr` is a pure
        # lookup and was already declared.
        lines.append(f"aGetUnitMapElementPtr(0) --read [0x{entry:x}]:"
                     f"{READ_RECORDS * RECORD_BYTES}")
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
    """Every cell's height, from the phase-1 control-map read."""
    blob = b""
    for row in rows:
        for key, text in (row.get("reads") or {}).items():
            if key.startswith("$c0"):
                blob = _hex_bytes(text)
    out: list[int] = []
    for index in range(gold.CAPTURE_WIDTH * gold.CAPTURE_HEIGHT):
        raw = blob[index * gold.CELL_STRIDE:(index + 1) * gold.CELL_STRIDE]
        out.append(raw[gold.CELL_HEIGHT] if len(raw) == gold.CELL_STRIDE else 0)
    return out


def raised_tile(state: dict[str, Any]) -> tuple[int, int] | None:
    """A tile whose height is **not** zero, for the z probe.

    Every unit in this save stands at height zero, and at height zero "z is the
    creator's own constant" and "z is the floor plus the creator's own
    constant" are the same number.  One call on a raised tile separates them,
    and this is where that tile comes from.
    """
    heights = state.get("heights") or []
    for index, height in enumerate(heights):
        if height:
            return index % gold.CAPTURE_WIDTH, index // gold.CAPTURE_WIDTH
    return None


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

    if "state" not in phases:
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
    wanted = [c for c in reachable_creators(root)
              if f"0x{c:08X}" not in phases]
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
            LOG.warning("%s: %s", name, err)
            continue
        for item, records in zip(group, _reads_in_order(rows)):
            phases[f"0x{item['creator']:08X}"] = {
                "args": item["args"],
                "records": parse_records(records),
            }
        _save(out, document)
    # The z probe: one creator that produced records, called again on a tile
    # whose height is not zero. Its own phase so a re-run can add it to a
    # capture that predates it.
    raised = raised_tile(state)
    if raised is not None and "raised" not in phases:
        probe = _first_producing(phases)
        if probe is not None:
            creator = int(probe, 16)
            group = [{"creator": creator,
                      "args": argument_vector(arities[creator], raised, target)}]
            try:
                rows = gold.run_plan(game_copy, dbgcall,
                                     creator_plan(state["handle"], group),
                                     "blob_raised", attempts=attempts)
                records = _reads_in_order(rows)
                phases["raised"] = {
                    "creator": probe, "tile": list(raised),
                    "height": state["heights"][raised[1] * gold.CAPTURE_WIDTH
                                               + raised[0]],
                    "args": group[0]["args"],
                    "records": parse_records(records[0]) if records else [],
                }
                _save(out, document)
            except gold.CaptureError as err:
                LOG.warning("blob_raised: %s", err)

    captured = [k for k in phases if k.startswith("0x")]
    LOG.warning("%s: %d of %d creator(s) captured", out, len(captured),
                len(reachable_creators(root)))
    return 0


def _first_producing(phases: dict[str, Any]) -> str | None:
    for name in sorted(phases):
        if name.startswith("0x") and phases[name].get("records"):
            return name
    return None


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
    ck.check("native.creators_captured", bool(captured),
             f"{len(captured)} of {len(reach)} creators ran in the engine")
    made = {k: len(v["records"]) for k, v in sorted(captured.items())}
    ck.check("native.records", any(made.values()),
             f"{sum(made.values())} record(s) over {len(made)} creator(s)")
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
        args = phase["args"]
        source = (args[0] * FIELD_UNITS, args[1] * FIELD_UNITS)
        line = ((args[2] - args[0]) * FIELD_UNITS,
                (args[3] - args[1]) * FIELD_UNITS) if len(args) >= 4 else (0, 0)
        offsets = {(r["x"] - source[0], r["y"] - source[1]) for r in records}
        ck.check(f"native.on_the_line_{name}",
                 all(dx * line[1] == dy * line[0] for dx, dy in offsets),
                 f"{len(records)} record(s), offsets {sorted(offsets)} "
                 f"along {line}, z = {sorted({r['z'] for r in records})}")

        # **And the cross-validation.** `blob_tables.py` read the class, the
        # update kind and the literal lifetime out of the compiler's own index
        # and jump tables, statically. These are the same fields, read out of
        # the pool of a running `Incubation.exe`. The two share no code.
        # **A creator may call another creator**, and the records that one
        # leaves are in the pool too.  Collecting only the constructor calls
        # whose nearest preceding entry is this creator missed those, and the
        # engine came back with a triple the static tables "did not have" --
        # which looked like a disagreement between the two readings and was a
        # missing edge in the call graph.  One level of nesting is enough for
        # every creator here.
        bodies = {creator} | set(binary.arm_calls(creator, creators_set,
                                                  entries, CREATOR_EXTENT))
        want = {(cls, kind, life)
                for site, owner in owners.items() if owner in bodies
                for _model, cls, kind, life in (static[site],)}
        got = {(r["class_id"], r["kind"], r["life"]) for r in records}
        ck.check(f"native.fields_{name}", _agrees(got, want),
                 f"engine {sorted(got)} against the static tables "
                 f"{sorted(want)}")
    raised = phases.get("raised")
    if raised and raised.get("records"):
        base = captured.get(raised["creator"], {}).get("records") or []
        flat_z = sorted({r["z"] for r in base})
        up_z = sorted({r["z"] for r in raised["records"]})
        ck.check("native.z_is_absolute" if flat_z == up_z
                 else "native.z_follows_the_floor",
                 flat_z == up_z
                 or all(u - f == raised["height"]
                        for f, u in zip(flat_z, up_z)),
                 f"height {raised['height']} moves z from {flat_z} to {up_z}")
    ck.check("native.some_produced", bool(produced),
             f"{len(produced)} creator(s) built records, "
             f"{len(aborted)} took the abort path")
    return _report(ck)


#: docs/30 2.5 -- one map field, in world units.
FIELD_UNITS = 3200
#: How far past its entry a creator's body is scanned for nested calls.
CREATOR_EXTENT = 1400


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

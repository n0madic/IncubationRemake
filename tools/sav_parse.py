#!/usr/bin/env python3
"""Parse an Incubation save game (``Work/Saves/_N_.sav``).  See docs/11.

There is no sample save in the retail release, so this parser has never been
run against real data.  Its layout comes from the writer and reader chains in
``Incubation.exe``, which ``tools/sav_tables.py --check`` verifies; what is
unverified is the parser, not the format.

Usage::

    python3 tools/sav_parse.py FILE                  # summary
    python3 tools/sav_parse.py FILE --json
    python3 tools/sav_parse.py FILE --lev OUT.lev    # extract the battle map
    python3 tools/sav_parse.py DIR --scan            # every _N_.sav under DIR

The embedded battle map is a byte-identical ``.lev`` image, so ``--lev``
produces a file ``tools/lev_parse.py`` accepts unchanged.  That is the strongest
check available on a save: it validates roughly 95% of the bytes.
"""

from __future__ import annotations

import argparse
import json
import logging
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib.binio import Reader  # noqa: E402,F401  (kept for API consistency)

log = logging.getLogger("sav_parse")


class SavError(Exception):
    """Raised instead of returning a partial parse."""


# --- layout, from docs/11 3 ----------------------------------------------------

OFF_COMMENT = 0
LEN_COMMENT = 0x105

OFF_GAME_CONTROL = OFF_COMMENT + LEN_COMMENT          # 261
LEN_GAME_CONTROL = 0x2D0

OFF_VIEW_PLAYER = OFF_GAME_CONTROL + LEN_GAME_CONTROL  # 981
LEN_VIEW_PLAYER = 0x44C

OFF_UNIT_POOL = OFF_VIEW_PLAYER + LEN_VIEW_PLAYER      # 2081
LEN_UNIT_POOL = 0x1554

OFF_BATTLE_MAP = OFF_UNIT_POOL + LEN_UNIT_POOL         # 7541

LEN_PROGRAM_STATE = 0x00C
LEN_LCL = 0x06D
LEN_OBJECTIVES = 0x01C

# .lev, from docs/10 2
LEV_HEADER = 0x360
LEV_CELL = 23
LEV_TAIL = 0x4718 + 0x2D4 + 0x26AC + 0x2AB98           # 203824
LEV_OFF_HEIGHT = 0x357
LEV_OFF_WIDTH = 0x35B
LEV_OFF_MISSION = 0x105
LEV_OFF_NEXT_MISSION = 0x000
LEV_OFF_SCENE = 0x244
LEV_OFF_WORLDSET = 0x349

SAV_FIXED = (LEN_COMMENT + LEN_GAME_CONTROL + LEN_VIEW_PLAYER + LEN_UNIT_POOL
             + LEV_HEADER + LEV_TAIL
             + LEN_PROGRAM_STATE + LEN_LCL + LEN_OBJECTIVES)   # 212378

# --- GameControl fields, from docs/11 5.2 -------------------------------------

GC_MAX_PLAYER = 0x118
GC_PREV_PLAYER = 0x119
GC_CUR_PLAYER = 0x11A
GC_PLAYER_IN_USE = 0x108        # u32[4]
GC_PASSWORDS = 0x16B            # char[4][25]
GC_PASSWORD_STRIDE = 25
GC_PASSWORD_SLOTS = 4
GC_GAME_MODE = 0x1D0
GC_VERSION = 0x1D2
GC_SCOREBOARD = 0x230
GC_SCOREBOARD_STRIDE = 40
GC_SCOREBOARD_SLOTS = 4
GC_RESULT_IN_RECORD = 0x20

PASSWORD_SENTINEL = b"INVALID_PASSWORD"
MISSION_RESULT_SCORE = {1: -100, 2: 0, 3: 100, 4: 200, 5: 300}

# --- UnitPool, from docs/11 5.7 ------------------------------------------------

POOL_RECORD = 0x5B
POOL_ROW_SLOTS = 31
POOL_USABLE_SLOTS = 30
POOL_SAVED_RECORDS = LEN_UNIT_POOL // POOL_RECORD     # 60

# --- LCL variables, from docs/11 5.9 -------------------------------------------

LCL_WHOLE_VARS = LEN_LCL // 4                          # 27
LCL_PARTIAL_BYTES = LEN_LCL % 4                        # 1


def _cstring(data: bytes) -> str:
    end = data.find(b"\0")
    return data[:end if end >= 0 else len(data)].decode("latin-1")


@dataclass
class Password:
    player: int
    set: bool
    value: str          # empty when unset

    def to_json(self) -> dict:
        return {"player": self.player, "set": self.set, "value": self.value}


@dataclass
class SaveGame:
    path: Path
    size_on_disk: int
    comment: str
    width: int
    height: int
    expected_size: int
    mission: str
    next_mission: str
    scene: str
    world_set: str
    game_mode: int
    version: int
    max_player: int
    current_player: int
    previous_player: int
    players_in_use: list[int]
    passwords: list[Password]
    mission_results: list[int]
    scores: list[int]
    program_state: list[int]
    lcl_vars: list[int]
    lcl_partial: int
    pool_used: list[tuple[int, int]] = field(default_factory=list)
    trailing_bytes: int = 0

    @property
    def lev_offset(self) -> int:
        return OFF_BATTLE_MAP

    @property
    def lev_size(self) -> int:
        return LEV_HEADER + LEV_CELL * self.width * self.height + LEV_TAIL

    def to_json(self) -> dict:
        return {
            "path": str(self.path),
            "size_on_disk": self.size_on_disk,
            "expected_size": self.expected_size,
            "trailing_bytes": self.trailing_bytes,
            "comment": self.comment,
            "map": {"width": self.width, "height": self.height,
                    "lev_offset": self.lev_offset, "lev_size": self.lev_size},
            "mission": self.mission,
            "next_mission": self.next_mission,
            "scene": self.scene,
            "world_set": self.world_set,
            "game_control": {
                "game_mode": self.game_mode,
                "version": self.version,
                "max_player": self.max_player,
                "current_player": self.current_player,
                "previous_player": self.previous_player,
                "players_in_use": self.players_in_use,
                "passwords": [p.to_json() for p in self.passwords],
                "mission_results": self.mission_results,
                "scores": self.scores,
            },
            "program_state": self.program_state,
            "lcl": {"whole_vars": self.lcl_vars, "partial_low_byte": self.lcl_partial},
            "unit_pool_used": [{"record": r, "player": p} for r, p in self.pool_used],
        }


def parse(path: Path) -> SaveGame:
    data = path.read_bytes()
    size = len(data)
    if size < OFF_BATTLE_MAP + LEV_HEADER:
        raise SavError(f"{path}: {size} bytes, too short to hold a battle map header")

    lev = OFF_BATTLE_MAP
    height = struct.unpack_from("<I", data, lev + LEV_OFF_HEIGHT)[0]
    width = struct.unpack_from("<I", data, lev + LEV_OFF_WIDTH)[0]
    if not (1 <= width <= 256 and 1 <= height <= 256):
        raise SavError(
            f"{path}: implausible map size {width}x{height} at +{lev + LEV_OFF_WIDTH}; "
            f"this is probably not a save game")

    expected = SAV_FIXED + LEV_CELL * width * height
    # The file is opened with OPEN_ALWAYS and never truncated (docs/11 1), so a
    # slot reused for a smaller map keeps the old tail.  Longer is fine; shorter
    # is not.
    if size < expected:
        raise SavError(f"{path}: {size} bytes, expected at least {expected} "
                       f"for a {width}x{height} map")

    gc = OFF_GAME_CONTROL
    passwords = []
    for i in range(GC_PASSWORD_SLOTS):
        off = gc + GC_PASSWORDS + i * GC_PASSWORD_STRIDE
        raw = data[off:off + GC_PASSWORD_STRIDE]
        if raw.startswith(PASSWORD_SENTINEL):
            passwords.append(Password(i, False, ""))
        else:
            passwords.append(Password(i, True, _cstring(bytes(b ^ 0xFF for b in raw))))

    results, scores = [], []
    for i in range(GC_SCOREBOARD_SLOTS):
        rec = gc + GC_SCOREBOARD + i * GC_SCOREBOARD_STRIDE
        result = struct.unpack_from("<i", data, rec + GC_RESULT_IN_RECORD)[0]
        results.append(result)
        scores.append(MISSION_RESULT_SCORE.get(result))

    ps = OFF_BATTLE_MAP + LEV_HEADER + LEV_CELL * width * height + LEV_TAIL
    lcl = ps + LEN_PROGRAM_STATE

    pool_used = []
    for r in range(POOL_SAVED_RECORDS):
        rec = OFF_UNIT_POOL + r * POOL_RECORD
        if data[rec + 0x16]:                    # docs/10 5.11: slot occupied
            pool_used.append((r, r // POOL_ROW_SLOTS))

    return SaveGame(
        path=path,
        size_on_disk=size,
        comment=_cstring(data[OFF_COMMENT:OFF_COMMENT + LEN_COMMENT]),
        width=width, height=height, expected_size=expected,
        trailing_bytes=size - expected,
        mission=_cstring(data[lev + LEV_OFF_MISSION:lev + LEV_OFF_MISSION + 32]),
        next_mission=_cstring(data[lev:lev + 32]),
        scene=_cstring(data[lev + LEV_OFF_SCENE:lev + LEV_OFF_SCENE + 32]),
        world_set=_cstring(data[lev + LEV_OFF_WORLDSET:lev + LEV_OFF_WORLDSET + 16]),
        game_mode=data[gc + GC_GAME_MODE],
        version=data[gc + GC_VERSION],
        max_player=data[gc + GC_MAX_PLAYER],
        current_player=data[gc + GC_CUR_PLAYER],
        previous_player=data[gc + GC_PREV_PLAYER],
        players_in_use=list(struct.unpack_from("<4I", data, gc + GC_PLAYER_IN_USE)),
        passwords=passwords,
        mission_results=results,
        scores=scores,
        program_state=list(struct.unpack_from("<3i", data, ps)),
        lcl_vars=list(struct.unpack_from(f"<{LCL_WHOLE_VARS}i", data, lcl)),
        lcl_partial=data[lcl + LCL_WHOLE_VARS * 4],
        pool_used=pool_used,
    )


def extract_lev(save: SaveGame, out: Path) -> None:
    data = save.path.read_bytes()
    out.write_bytes(data[save.lev_offset:save.lev_offset + save.lev_size])
    log.debug("wrote %d bytes to %s", save.lev_size, out)


def summarise(s: SaveGame) -> None:
    print(f"{s.path}")
    print(f"  comment           {s.comment!r}")
    print(f"  size              {s.size_on_disk} on disk, {s.expected_size} expected"
          + (f", {s.trailing_bytes} stale trailing bytes" if s.trailing_bytes else ""))
    print(f"  mission           {s.mission!r} -> next {s.next_mission!r}")
    print(f"  scene             {s.scene!r} in WorldSet/World_{s.world_set}")
    print(f"  map               {s.width}x{s.height}, .lev image at "
          f"+{s.lev_offset} ({s.lev_size} bytes)")
    print(f"  game mode         {s.game_mode}   build stamp {s.version}")
    print(f"  players           current {s.current_player}, previous "
          f"{s.previous_player}, max index {s.max_player}, in use "
          f"{s.players_in_use}")
    for p in s.passwords:
        print(f"  password[{p.player}]       " +
              (f"{p.value!r}" if p.set else "(unset)"))
    print(f"  mission results   {s.mission_results}  -> base scores {s.scores}")
    print(f"  program state     {s.program_state}")
    print(f"  LCL vars 0..{LCL_WHOLE_VARS - 1}    {s.lcl_vars}")
    print(f"  LCL var {LCL_WHOLE_VARS}         low byte {s.lcl_partial:#04x} only "
          f"(docs/11 5.9)")
    occupied = len(s.pool_used)
    print(f"  unit pool         {occupied} of {POOL_SAVED_RECORDS} saved records "
          f"occupied")


def selftest(root: Path) -> int:
    """Round-trip the layout against a real ``.lev`` from the corpus.

    No save exists to parse, but the largest block of one does: a save is a
    ``.lev`` image with 7541 bytes of fixed prefix and 149 of fixed suffix.
    Wrapping a corpus mission in those blocks and reading it back exercises
    every offset in this file, and extracting the map again has to reproduce
    the original byte for byte.  A layout that is off by one anywhere fails.
    """
    # The layout constants above are what the parser uses; these are the same
    # numbers written out again from docs/11 3.  Building the synthetic save
    # from the module's own constants would make the round trip circular -- a
    # wrong constant would move the field and the expectation together -- so
    # the two are compared first and everything below uses the literals.
    documented = {
        "OFF_COMMENT": (OFF_COMMENT, 0), "LEN_COMMENT": (LEN_COMMENT, 261),
        "OFF_GAME_CONTROL": (OFF_GAME_CONTROL, 261),
        "LEN_GAME_CONTROL": (LEN_GAME_CONTROL, 720),
        "OFF_VIEW_PLAYER": (OFF_VIEW_PLAYER, 981),
        "LEN_VIEW_PLAYER": (LEN_VIEW_PLAYER, 1100),
        "OFF_UNIT_POOL": (OFF_UNIT_POOL, 2081),
        "LEN_UNIT_POOL": (LEN_UNIT_POOL, 5460),
        "OFF_BATTLE_MAP": (OFF_BATTLE_MAP, 7541),
        "LEN_PROGRAM_STATE": (LEN_PROGRAM_STATE, 12),
        "LEN_LCL": (LEN_LCL, 109), "LEN_OBJECTIVES": (LEN_OBJECTIVES, 28),
        "LEV_HEADER": (LEV_HEADER, 864), "LEV_CELL": (LEV_CELL, 23),
        "LEV_TAIL": (LEV_TAIL, 203824), "SAV_FIXED": (SAV_FIXED, 212378),
        "LEV_OFF_HEIGHT": (LEV_OFF_HEIGHT, 0x357),
        "LEV_OFF_WIDTH": (LEV_OFF_WIDTH, 0x35B),
        "GC_PASSWORDS": (GC_PASSWORDS, 0x16B),
        "GC_PASSWORD_STRIDE": (GC_PASSWORD_STRIDE, 25),
        "GC_PASSWORD_SLOTS": (GC_PASSWORD_SLOTS, 4),
        "GC_MAX_PLAYER": (GC_MAX_PLAYER, 0x118),
        "GC_PREV_PLAYER": (GC_PREV_PLAYER, 0x119),
        "GC_CUR_PLAYER": (GC_CUR_PLAYER, 0x11A),
        "GC_PLAYER_IN_USE": (GC_PLAYER_IN_USE, 0x108),
        "GC_GAME_MODE": (GC_GAME_MODE, 0x1D0), "GC_VERSION": (GC_VERSION, 0x1D2),
        "GC_SCOREBOARD": (GC_SCOREBOARD, 0x230),
        "GC_SCOREBOARD_STRIDE": (GC_SCOREBOARD_STRIDE, 40),
        "GC_RESULT_IN_RECORD": (GC_RESULT_IN_RECORD, 0x20),
        "POOL_RECORD": (POOL_RECORD, 91), "POOL_ROW_SLOTS": (POOL_ROW_SLOTS, 31),
        "POOL_SAVED_RECORDS": (POOL_SAVED_RECORDS, 60),
        "LCL_WHOLE_VARS": (LCL_WHOLE_VARS, 27),
    }
    wrong = {k: v for k, v in documented.items() if v[0] != v[1]}
    if wrong:
        raise SavError("layout constants disagree with docs/11: " + ", ".join(
            f"{k} is {got}, documented {want}" for k, (got, want) in wrong.items()))

    all_missions = sorted((root / "Missions").rglob("*.lev"))
    if not all_missions:
        log.error("no .lev under %s/Missions -- nothing to build a save from", root)
        return 1

    # Only the map dimensions change the layout, so one mission per distinct
    # WxH covers every size a save can have.
    by_size: dict[tuple[int, int], Path] = {}
    for path in all_missions:
        head = path.open("rb").read(LEV_HEADER)
        key = (struct.unpack_from("<I", head, LEV_OFF_WIDTH)[0],
               struct.unpack_from("<I", head, LEV_OFF_HEIGHT)[0])
        by_size.setdefault(key, path)
    missions = [by_size[k] for k in sorted(by_size)]

    import tempfile  # noqa: PLC0415

    checked = 0
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "_0_.sav"
        lev_out = Path(tmp) / "out.lev"
        for mission in missions:
            lev = mission.read_bytes()
            height = struct.unpack_from("<I", lev, LEV_OFF_HEIGHT)[0]
            width = struct.unpack_from("<I", lev, LEV_OFF_WIDTH)[0]

            gc = bytearray(0xCD for _ in range(LEN_GAME_CONTROL))
            for i in range(GC_PASSWORD_SLOTS):
                off = GC_PASSWORDS + i * GC_PASSWORD_STRIDE
                plain = b"pw%d" % i if i == 0 else PASSWORD_SENTINEL
                if i == 0:
                    gc[off:off + GC_PASSWORD_STRIDE] = bytes(
                        b ^ 0xFF for b in plain.ljust(GC_PASSWORD_STRIDE, b"\0"))
                else:
                    gc[off:off + GC_PASSWORD_STRIDE] = plain.ljust(
                        GC_PASSWORD_STRIDE, b"\0")
            gc[GC_MAX_PLAYER] = 1
            gc[GC_CUR_PLAYER] = 0
            gc[GC_PREV_PLAYER] = 1
            gc[GC_GAME_MODE] = 1
            gc[GC_VERSION] = 152
            struct.pack_into("<4I", gc, GC_PLAYER_IN_USE, 1, 1, 0, 0)
            for i, result in enumerate((3, 5, 0, 0)):
                struct.pack_into("<i", gc, GC_SCOREBOARD + i * GC_SCOREBOARD_STRIDE
                                 + GC_RESULT_IN_RECORD, result)

            pool = bytearray(LEN_UNIT_POOL)
            for rec in (0, 1, POOL_ROW_SLOTS):
                pool[rec * POOL_RECORD + 0x16] = 1

            blob = bytearray()
            blob += b"selftest\0".ljust(LEN_COMMENT, b"\xCD")
            blob += gc
            blob += bytes(LEN_VIEW_PLAYER)
            blob += pool
            blob += lev
            blob += struct.pack("<3i", 4, 0, -1)
            blob += struct.pack("<%di" % LCL_WHOLE_VARS, *range(LCL_WHOLE_VARS))
            blob += b"\x2a"
            blob += bytes(LEN_OBJECTIVES)
            out.write_bytes(blob)

            expected = SAV_FIXED + LEV_CELL * width * height
            if len(blob) != expected:
                raise SavError(f"{mission.name}: assembled {len(blob)} bytes, "
                               f"layout says {expected}")

            save = parse(out)
            if (save.width, save.height) != (width, height):
                raise SavError(f"{mission.name}: read back {save.width}x{save.height}")
            if save.comment != "selftest":
                raise SavError(f"{mission.name}: comment {save.comment!r}")
            if not save.passwords[0].set or save.passwords[0].value != "pw0":
                raise SavError(f"{mission.name}: password 0 {save.passwords[0]}")
            if any(p.set for p in save.passwords[1:]):
                raise SavError(f"{mission.name}: sentinel not recognised")
            if save.mission_results != [3, 5, 0, 0] or save.scores[:2] != [100, 300]:
                raise SavError(f"{mission.name}: scoreboard {save.mission_results}")
            if save.program_state != [4, 0, -1]:
                raise SavError(f"{mission.name}: program state {save.program_state}")
            if save.lcl_vars != list(range(LCL_WHOLE_VARS)) or save.lcl_partial != 0x2A:
                raise SavError(f"{mission.name}: LCL bank {save.lcl_vars}")
            if len(save.pool_used) != 3:
                raise SavError(f"{mission.name}: pool {save.pool_used}")
            if save.trailing_bytes:
                raise SavError(f"{mission.name}: {save.trailing_bytes} trailing")

            extract_lev(save, lev_out)
            if lev_out.read_bytes() != lev:
                raise SavError(f"{mission.name}: extracted .lev differs from the "
                               f"original")
            checked += 1

    print(f"{checked}/{checked} synthetic saves round-tripped "
          f"({checked} distinct map sizes out of {len(all_missions)} missions; "
          f"layout, fields, and a byte-identical .lev image)")
    return 0


def wrap(save: Path, lev: Path, out: Path) -> int:
    """Write a save carrying `lev` instead of the one `save` holds.

    A save is a ``.lev`` image between a 7541-byte prefix and a 149-byte
    suffix (:func:`selftest` round-trips exactly that), so swapping the image
    swaps the **mission**: the prefix's game-control block, unit pool and
    player state are the ones the played save left, and the mission, its
    scene, its world set and its whole map come from the ``.lev``.

    What it is for: reaching a mission no shipped save is on.  The glow of
    ``docs/42`` §9.1 only exists in ``World_D00`` -- ``GLOW1/2.3DI`` are in
    that one prototype container -- and every real save in
    ``tests/fixtures/saves`` is on `_C_140` or `_C_141`, which are ``A00`` and
    ``B00``.  Wrapping `_C_116.lev` gives a save the debugger harness can load
    to measure the placer and its decay (``docs/97`` §37).

    The result is **not** a played save and must not be treated as one: only
    the map and what the game derives from it are trustworthy in it.
    """
    raw = save.read_bytes()
    image = lev.read_bytes()
    # The suffix is whatever the parsed save has after its own map -- derived
    # rather than named, so a save with the untruncated tail docs/11 1
    # describes is wrapped as correctly as a clean one.
    parsed = parse(save)
    carried = LEV_HEADER + LEV_CELL * parsed.width * parsed.height + LEV_TAIL
    suffix = len(raw) - OFF_BATTLE_MAP - carried
    if suffix < 0:
        raise SavError(f"{save}: the map runs past the end of the file")
    built = raw[:OFF_BATTLE_MAP] + image + raw[len(raw) - suffix:]
    out.write_bytes(built)
    log.info("%s: %d bytes, %s in place of the parsed map",
             out, len(built), lev.name)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("path", type=Path,
                    help="a .sav file; a directory with --scan; the game root "
                         "with --selftest")
    ap.add_argument("--scan", action="store_true",
                    help="parse every _N_.sav under the directory")
    ap.add_argument("--selftest", action="store_true",
                    help="round-trip the layout against corpus .lev missions")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--lev", type=Path, metavar="OUT",
                    help="write the embedded battle map as a standalone .lev")
    ap.add_argument("--wrap", type=Path, metavar="LEV",
                    help="write a save carrying this .lev instead of the "
                         "parsed one's; needs --out")
    ap.add_argument("--out", type=Path, metavar="PATH",
                    help="where --wrap writes")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    if args.selftest:
        try:
            return selftest(args.path)
        except SavError as exc:
            log.error("%s", exc)
            return 1

    if args.wrap is not None:
        if args.out is None:
            log.error("--wrap needs --out")
            return 1
        return wrap(args.path, args.wrap, args.out)

    if args.scan:
        files = sorted(args.path.rglob("_*_.sav"))
        if not files:
            log.error("no _N_.sav under %s -- nothing to parse. The retail release "
                      "ships this tree empty; a save has to be produced by the "
                      "game before this tool has anything to check.", args.path)
            return 1
        saves = []
        for f in files:
            try:
                saves.append(parse(f))
            except SavError as exc:
                log.error("%s", exc)
                return 1
        if args.json:
            print(json.dumps([s.to_json() for s in saves], indent=2))
        else:
            for s in saves:
                summarise(s)
        print(f"{len(saves)}/{len(files)} parsed")
        return 0

    if not args.path.is_file():
        log.error("%s is not a file", args.path)
        return 1
    try:
        save = parse(args.path)
    except SavError as exc:
        log.error("%s", exc)
        return 1
    if args.lev:
        extract_lev(save, args.lev)
        log.info("wrote %d bytes to %s", save.lev_size, args.lev)
    if args.json:
        print(json.dumps(save.to_json(), indent=2))
    elif not args.lev:
        summarise(save)
    return 0


if __name__ == "__main__":
    sys.exit(main())

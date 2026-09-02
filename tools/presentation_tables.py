#!/usr/bin/env python3
"""Pin ``docs/42`` -- the mission's presentation layer -- to ``Incubation.exe``.

Every number ``docs/42`` quotes about the camera, the walk, the shot, the
idle scheduler, the set pieces and the scenery objects is a literal in the
shipped executable, and this tool reads each one back: an immediate inside a
named routine, the argument bytes a call site pushes, a jump table, a string
push, or the set of update arms that write one flag.  A claim the binary does
not carry fails here rather than surviving as prose.

Every ``--check`` run must find the executable and inspect every site; an
empty root is a failure, not zero work.

Usage::

    python3 tools/presentation_tables.py --check gog_incubation
    python3 tools/presentation_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("presentation_tables")

GAME_EXE = "Incubation.exe"

# --- the routines docs/42 names, as (start, end) virtual-address ranges ------
FLIGHT = (0x0040EEE0, 0x0040F226)            # docs/42 §2.2
UNIT_CAMERA = (0x004529D0, 0x00452E90)       # docs/42 §2.3
FREE_POSITION = (0x00453510, 0x004536C3)     # docs/42 §2.3
EYE_VIEW = (0x00452E90, 0x0045304E)          # docs/42 §2.4
MAP_VIEW_HEIGHT = (0x00453270, 0x00453297)   # docs/42 §2.4
ROTATE_CAMERA = (0x00403600, 0x00403717)     # docs/42 §2.1
SET_CAMERA = (0x00403560, 0x004035F9)
MOVE_CAMERA = (0x004037D0, 0x004038E6)
MOUSE_ROTATE = (0x00451000, 0x00451060)      # docs/42 §2.5
MOUSE_PAN = (0x004511A0, 0x00451200)
MAIN_LOOP = (0x0041C010, 0x0041D2A0)
VIEW_ON_UNIT = (0x004510A0, 0x00451150)      # GUI event 4
VIEW_EYES = (0x00451150, 0x004511A0)         # GUI event 2
VIEW_MAP = (0x00450F60, 0x00451000)          # GUI event 3
CYCLE = (0x00453CF0, 0x00453DB0)             # command 14
WALK_STEP = (0x0040EBB0, 0x0040ED90)         # docs/42 §3.2, the tracking step
RIDE_STEP = (0x0040EA30, 0x0040EBA0)         # the first-person step
SELECT_ANIMATION = (0x0040EDB0, 0x0040EEDA)
EXECUTE_MOVE = (0x0046E220, 0x0046EF50)
START_ANIMATION = (0x004055E0, 0x00405CB0)   # docs/42 §1.2
IDLE_STARTER = (0x004060B0, 0x004064F0)      # docs/42 §6.1
VIEW_REFRESH = (0x00406FC0, 0x00407250)      # docs/42 §1.3
FIGHT = (0x0040BD70, 0x0040E300)             # docs/42 §4
FRAME_TICK = (0x0040B6F0, 0x0040BD70)        # docs/42 §1.1
ATTACK_UNIT = (0x0046B450, 0x0046C400)
JUMP = (0x00411460, 0x004118E0)              # docs/42 §7.1
PUSH = (0x0046D530, 0x0046DA00)              # docs/42 §7.2
PUSH_DUST = (0x0042A6E0, 0x0042A760)
ARROW_MARKER = (0x00422D40, 0x00422ED0)      # docs/42 §7.3
ORBIT_SKILL = (0x00410190, 0x004104A0)       # docs/42 §7.5
ORBIT_JAM = (0x004104A0, 0x00410780)
ORBIT_HEAL = (0x0040FBE0, 0x0040FF30)
ORBIT_POISON = (0x0040F8F0, 0x0040FBE0)
ORBIT_OVERHEAT = (0x0040F420, 0x0040F8F0)
ORBIT_ROTATING = (0x0040FF30, 0x00410190)
DOOR = (0x00410A20, 0x00410DA0)              # docs/42 §8
ELEVATOR = (0x004125D0, 0x00412A00)
PLATFORM = (0x00412A00, 0x004131C0)
BARRIER = (0x00413560, 0x00413A40)
GROUND_FIRE = (0x004157B0, 0x00415C70)
CRUSH_WALL = (0x00415C70, 0x00415E90)
MINE_PLACER = (0x0042FA70, 0x0042FB90)       # docs/42 §9.1
FIRE_PLACER = (0x0042F840, 0x0042FA70)
GLOW_PLACER = (0x0042FCB0, 0x0042FE80)
CREATE_SPECIAL = (0x004069C0, 0x00406A40)
FREE_ANIMATION = (0x00406000, 0x00406070)
TEXT_BANKS = (0x00449CA0, 0x00449D10)        # docs/42 §4.2
BLOB_UPDATE = (0x0041E500, 0x00420814)       # docs/42 §4.6
BLOB_JUMP_TABLE = 0x00420814
BLOB_KINDS = 78
ARRIVED_FLAG = 0x004FE63C
ARRIVED_KINDS = frozenset({1, 15, 25, 26, 27, 28, 32, 45, 47, 49, 69, 71, 74})
EMPTY_CAPTION = 0x004FA524
TEXT = (0x00401000, 0x004B0000)

# Callees, for `call rel32` pins.
A_SET_CAMERA = 0x00403560
A_ROTATE = 0x00403600
A_MOVE = 0x004037D0
A_FLIGHT = 0x0040EEE0
A_UNIT_CAMERA = 0x004529D0
A_FREE_POSITION = 0x00453510
A_CLAMP = 0x00453420
A_GRADIENTS = 0x0047ABD0
A_FRAME = 0x0040B6F0
A_VIEW_MODE = 0x004536D0
A_ON_SCREEN = 0x00453050
A_MAP_CAMERA = 0x00453150
A_EYE_CAMERA = 0x00452E90
A_SELECT_ANIM = 0x0040EDB0
A_START_ANIM = 0x004055E0
A_CONT_ANIM = 0x004054D0
A_REMAINING = 0x00405460
A_FREE_ANIM = 0x00406000
A_IDLE_START = 0x004060B0
A_HIDE = 0x00405320
A_RANDOM2 = 0x004638E0
A_DISTANCE = 0x0044AE10
A_DIRECTION = 0x0046D400
A_REACTION_POS = 0x00453730
REACTION_POS = (0x00453730, 0x00453900)
#: `0x00453320` fills the camera box; `0x00419B90/A50/A60` read the loaded
#: `.lev` header at `0x004FCED0` (`+0x224` camera height, `+0x357` rows,
#: `+0x35B` columns -- docs/10 section 3).
CAMERA_BOX_INIT = (0x00453320, 0x00453390)
HEADER_BASE = 0x004FCED0
A_CAMERA_HEIGHT = 0x00419B90
#: `0x0047ABD0`'s facing jump table and its eight `(gx, gy)` arms, in facing
#: order -- the inverse of docs/10 section 5.10's step table.
GRADIENT_TABLE = 0x0047AD04
GRADIENTS = [(0, 1), (-1, 0), (0, -1), (1, 0), (1, -1), (-1, 1), (1, 1),
             (-1, -1)]
#: `0x004794B0` -- the walk's "would the unit be seen at this cell" probe.
SEEN_AT = (0x004794B0, 0x00479700)
A_SEEN_AT = 0x004794B0
A_LOS_EX = 0x0046C460
FREE_ROTATION = (0x00451000, 0x00451092)
A_ARRIVED = 0x0042B480
A_ALIVE = 0x0042B4A0
A_BLOB_SWEEP = 0x0041E3D0
A_NOTE_CALLBACK = 0x0042C5D0
A_ENEMY_MOVE = 0x00460510
A_ANIM_LEVEL = 0x004604D0
A_IDLE_SELECT = 0x0042DDF0
A_RIDE = 0x0040EA30
A_TRACK = 0x0040EBB0
A_FIGHT = 0x0040BD70
A_ARROWS = 0x00422D40
A_ROTATE_VECTOR = 0x004039A0
A_DUST = 0x0042A6E0
A_TRAIL = 0x00423670
A_LANDING_DUST = 0x004227C0
A_CTOR = 0x00420950
A_CREATE_SPECIAL = 0x004069C0
A_FLASH_CIRCLE_HEAL = 0x00423030
A_FLASH_CIRCLE_POISON = 0x004232E0
A_BEAM = 0x00428990
A_BARRIER_HIT_A = 0x0042AB40
A_BARRIER_HIT_B = 0x0042A9D0
A_TUBE_SMOKE = 0x00423C20
A_WALL_DEBRIS = 0x004238C0
A_PLATFORM_DUST = 0x004234C0
#: The creators the death switch of docs/42 §4.8 reaches.  Four carry no
#: developer name (`blob_tables.BLOB_CREATOR_NAMES` holds `None` for them);
#: their names here are this project's, from what the code does, and
#: `tools/inclib/blob_creators.py`'s `DEATH_PROGRAMS` transcribes them.
DEATH_CREATORS = {
    "BloodFlood": 0x00420D80, "blood_spray_large": 0x00421360,
    "KillFire": 0x00423AD0, "FireExplosion": 0x00429A80,
    "FlyingDebris": 0x004216D0, "blood_burst": 0x00420B80,
    "species_burst": 0x00421C50, "FireDeath": 0x0042B1D0,
    "FlyingUnit": 0x00429700, "barrel_burst": 0x004298D0,
}
DEATH_PUFF = (0x004297F0, 0x004298D0)
BLOOD_BURST = (0x00420B80, 0x00420D80)
BLOOD_FLOOD = (0x00420D80, 0x00421360)
BLOOD_SPRAY_LARGE = (0x00421360, 0x004216D0)
FLYING_DEBRIS = (0x004216D0, 0x00421C50)
SPECIES_BURST = (0x00421C50, 0x00422460)
BARREL_BURST = (0x004298D0, 0x00429A80)
#: `0x004604A0` reads the gore level, dword 10 of `Game.opt` (`docs/20` §8).
A_GORE_LEVEL = 0x004604A0
GORE_PLAYER_TEST = b"\x80\x7f\x45\xff"      # cmp byte [edi+0x45], -1
GORE_READERS = {0x004169CE, 0x00420B84, 0x00420C13, 0x00420FE2, 0x00421C5A, 0x00421D42}
GORE_READER_RANGES = (TELEPORT_KILL := (0x00416840, 0x00416AD0), BLOOD_BURST,
                      BLOOD_FLOOD, SPECIES_BURST)
#: The doubles the blood sprays and the species coin read (`blob_creators`).
BLOOD_DOUBLES = {0x004B1248: 16.0, 0x004B1250: 160.0, 0x004B1258: -1280.0,
                 0x004B1260: 48.0, 0x004B1268: 6.0}
#: The set pieces docs/42 §8 transcribes line by line.
STATUE = (0x00413A40, 0x00414000)
STATUE_2 = (0x00414000, 0x00414360)
STATUE_BEAM = (0x00428BF0, 0x00428E30)
FOOTBRIDGE = (0x00414A70, 0x00415110)
FOOTBRIDGE_2 = (0x00415110, 0x004157B0)
GROUND_UNIT = (0x00411FB0, 0x004125D0)
GROUND_UNIT_DEBRIS = (0x00422610, 0x004227C0)
TELEPORTER = (0x004164F0, 0x00416840)
TELEPORTER_STREAM = (0x0042A120, 0x0042A2F0)
#: docs/42 §9.1 -- the shield placer and its two callers.
SHIELD_PLACER = (0x0042FB90, 0x0042FCB0)
OBJECT_SEEDING = (0x004079D0, 0x00407A90)
A_SHIELD_PLACER = 0x0042FB90
#: docs/42 §1.2 -- the length chain and the interface the starts go through.
ANIMATION_INIT = (0x004A0A01, 0x004A0C50)
KEYFRAMED_INTERFACE_VTABLE = 0x004B1DDC     # KeyFramedAnimation, sub-object +80
KEYFRAMED_INTERFACE_ABSTRACT = 0x004B1E7C   # KeyFramedAnimationInterface
INTERFACE_SLOTS = {0x18: 0x004A0E1A, 0x24: 0x004A0E83, 0x2C: 0x004A0EBB}
MOVEMENT_LENGTH_SLOT = 0x2C
MOVEMENT_VTABLES = {"LinearVectorMovement": (0x004B2634, 0x004A8873),
                    "LinearRotationMovement": (0x004B2704, 0x004A97A4)}
KEY_TIME_SLOT = 0x14
KEY_VTABLES = {"LinearVectorKey": (0x004B3A3C, 0x004A9667),
               "LinearRotationKey": (0x004B3A9C, 0x004AA57E)}
PART_VTABLE = 0x004B1FEC
MODEL_VTABLE = 0x004B2244
#: docs/42 §6.1 -- the starter's type search never advances.
STARTER_LOOP = 0x0040616C
STARTER_LOOP_BYTES = bytes.fromhex("3bc5740b4181f9c80000007cf3")
STARTER_RANDOM_PUSHES = 0x00406182


class Checker:
    def __init__(self) -> None:
        self.passed = 0
        self.failed: list[str] = []
        self.lines: list[str] = []

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            self.passed += 1
            self.lines.append(f"ok   {name}")
        else:
            self.failed.append(name)
            self.lines.append(f"FAIL {name}" + (f" -- {detail}" if detail else ""))


class Binary:
    def __init__(self, path: str) -> None:
        self.pe = PEFile(path)  # type: ignore[arg-type]

    def span(self, lo: int, hi: int) -> bytes:
        return self.pe.bytes_at(lo, hi - lo)

    def count(self, rng: tuple[int, int], pattern: bytes) -> int:
        blob = self.span(*rng)
        n, start = 0, 0
        while True:
            i = blob.find(pattern, start)
            if i < 0:
                return n
            n += 1
            start = i + 1

    def calls(self, rng: tuple[int, int], target: int) -> list[int]:
        """Every ``call rel32`` inside the range that lands on ``target``."""
        lo, hi = rng
        blob = self.span(lo, hi)
        out = []
        for i in range(len(blob) - 4):
            if blob[i] != 0xE8:
                continue
            rel = struct.unpack_from("<i", blob, i + 1)[0]
            if lo + i + 5 + rel == target:
                out.append(lo + i)
        return out

    def u32(self, va: int) -> int:
        return self.pe.u32(va)


def _pin_calls(ck: Checker, b: Binary, name: str, rng: tuple[int, int],
               target: int, expect: int) -> list[int]:
    sites = b.calls(rng, target)
    ck.check(f"{name}.calls_0x{target:08X}", len(sites) == expect,
             f"{len(sites)} != {expect}: {[hex(s) for s in sites]}")
    return sites


def _pin_bytes(ck: Checker, b: Binary, name: str, rng: tuple[int, int],
               pattern: bytes, expect: int, at_least: bool = False) -> None:
    n = b.count(rng, pattern)
    ok = n >= expect if at_least else n == expect
    ck.check(name, ok, f"{pattern.hex()} found {n} times, expected "
                       f"{'>= ' if at_least else ''}{expect}")


def _pin_at(ck: Checker, b: Binary, name: str, va: int, expect: bytes) -> None:
    got = b.pe.bytes_at(va, len(expect))
    ck.check(name, got == expect, f"{got.hex()} at {va:#x}, expected {expect.hex()}")


def _rtti_name(b: Binary, vtable: int) -> tuple[str, int]:
    """The class name and sub-object offset MSVC's RTTI records for a vtable:
    the complete-object locator sits in the dword before the table and names
    the type descriptor, whose mangled name follows its two pointers."""
    locator = b.u32(vtable - 4)
    offset = b.u32(locator + 4)
    descriptor = b.u32(locator + 12)
    return b.pe.cstring(descriptor + 8), offset


def _push8(value: int) -> bytes:
    return bytes([0x6A, value & 0xFF])


def _push32(value: int) -> bytes:
    return b"\x68" + struct.pack("<I", value & 0xFFFFFFFF)


def _check_camera(ck: Checker, b: Binary) -> None:
    # §2.1 -- the primitives refuse under the lock, pitch is clamped to ±1024.
    lock_string = _push32(0x004BFCFC)
    for name, rng in (("set", SET_CAMERA), ("rotate", ROTATE_CAMERA),
                      ("move", MOVE_CAMERA)):
        _pin_bytes(ck, b, f"camera.{name}.locked_message", rng, lock_string, 1)
    _pin_bytes(ck, b, "camera.rotate.pitch_min", ROTATE_CAMERA,
               b"\x66\x3d\x00\xfc", 1)                      # cmp ax, -1024
    _pin_bytes(ck, b, "camera.rotate.pitch_max", ROTATE_CAMERA,
               b"\x66\x3d\x00\x04", 1)                      # cmp ax, 1024

    # §2.2 -- the flight.
    _pin_bytes(ck, b, "flight.snap_20m", FLIGHT, b"\x3d\x00\x7d\x00\x00", 1)
    _pin_bytes(ck, b, "flight.snap_reads_new_pos_z", FLIGHT,
               b"\x8b\x4c\x24\x54", 1)                       # [esp+0x54] = arg 3
    _pin_bytes(ck, b, "flight.snap_reads_cur_pos_z", FLIGHT,
               b"\x8b\x5c\x24\x28", 1)                       # the read-back posZ
    _pin_bytes(ck, b, "flight.fast_threshold_500_x6", FLIGHT,
               b"\x3d\xf4\x01\x00\x00", 6)
    _pin_bytes(ck, b, "flight.stop_threshold_30_x6", FLIGHT, b"\x83\xf8\x1e", 6)
    _pin_bytes(ck, b, "flight.third_x6", FLIGHT, b"\xb8\x56\x55\x55\x55", 6)
    _pin_bytes(ck, b, "flight.sixth_x6", FLIGHT, b"\xb8\xab\xaa\xaa\x2a", 6)
    _pin_calls(ck, b, "flight", FLIGHT, A_SET_CAMERA, 2)
    _pin_calls(ck, b, "flight", FLIGHT, A_FRAME, 1)
    # The fast/slow choice is made before the loop head: the back edge at
    # 0x0040F214 lands at 0x0040F019, after the six threshold tests.
    back_edge = b.pe.bytes_at(0x0040F214, 5)
    rel = struct.unpack("<i", back_edge[1:])[0]
    ck.check("flight.choice_made_once", back_edge[0] == 0xE9
             and 0x0040F214 + 5 + rel == 0x0040F019,
             f"back edge lands at {0x0040F214 + 5 + rel:#x}")

    # §2.3 -- placing the camera on a unit.
    _pin_bytes(ck, b, "unit_camera.mode_switch_bound", UNIT_CAMERA,
               b"\x83\xf8\x03", 1)
    table = [b.u32(0x00452E80 + 4 * i) for i in range(4)]
    ck.check("unit_camera.quadrant_table",
             all(UNIT_CAMERA[0] <= t < UNIT_CAMERA[1] for t in table)
             and len(set(table)) == 4, str([hex(t) for t in table]))
    _pin_bytes(ck, b, "unit_camera.axis_offset_3200", UNIT_CAMERA,
               b"\xc1\xe3\x07", 1)                           # gx*25 << 7
    _pin_bytes(ck, b, "unit_camera.target_plus_1m_x2", UNIT_CAMERA,
               b"\x40\x06\x00\x00", 2)
    _pin_bytes(ck, b, "unit_camera.near_test_6m_x2", UNIT_CAMERA,
               b"\x80\x25\x00\x00", 2)
    _pin_bytes(ck, b, "unit_camera.near_lowering_12800", UNIT_CAMERA,
               b"\x8d\x84\x0a\x00\xce\xff\xff", 1)
    _pin_calls(ck, b, "unit_camera", UNIT_CAMERA, A_GRADIENTS, 1)
    _pin_calls(ck, b, "unit_camera", UNIT_CAMERA, A_FREE_POSITION, 1)
    _pin_calls(ck, b, "unit_camera", UNIT_CAMERA, A_CLAMP, 1)
    _pin_calls(ck, b, "unit_camera", UNIT_CAMERA, A_FLIGHT, 1)
    _pin_bytes(ck, b, "free_position.tries_70", FREE_POSITION,
               b"\x83\xfd\x46", 1)
    _pin_bytes(ck, b, "free_position.second_ray_plus_2400", FREE_POSITION,
               b"\x81\xc1\x60\x09\x00\x00", 1)
    # The cap inside the placement multiplies the header's camera height --
    # already world units -- by 1600 (`lea eax,[eax+eax*4]` twice, `shl 6`)
    # and so never bites; the box clamp below is the cap that does. Both
    # modes call the search: the `jmp` at `0x00452E11` joins mode 1 to it.
    _pin_calls(ck, b, "unit_camera.cap_reads_camera_height", UNIT_CAMERA,
               A_CAMERA_HEIGHT, 4)
    _pin_bytes(ck, b, "unit_camera.cap_x1600_dead", UNIT_CAMERA,
               b"\x8d\x04\x80\x8d\x04\x80\xc1\xe0\x06", 2, at_least=True)
    _pin_at(ck, b, "camera_height.is_header_0x224", A_CAMERA_HEIGHT,
            b"\xa1" + struct.pack("<I", HEADER_BASE + 0x224) + b"\xc3")
    _pin_at(ck, b, "map_rows.is_header_0x357", 0x00419A50,
            b"\xa1" + struct.pack("<I", HEADER_BASE + 0x357) + b"\xc3")
    _pin_at(ck, b, "map_columns.is_header_0x35b", 0x00419A60,
            b"\xa1" + struct.pack("<I", HEADER_BASE + 0x35B) + b"\xc3")
    # §2.1 -- the box: 800 on every low side, `(n - 1) * 3200` on x and y,
    # the header's camera height on z.
    _pin_at(ck, b, "camera_box.low_800_x3", CAMERA_BOX_INIT[0],
            b"\xb8\x20\x03\x00\x00\xa3\x60\x07\x51\x00\xa3\x64\x07\x51\x00"
            b"\xa3\x68\x07\x51\x00")
    _pin_bytes(ck, b, "camera_box.x25x128_x2", CAMERA_BOX_INIT,
               b"\x8d\x04\x80", 2, at_least=True)
    _pin_at(ck, b, "camera_box.x_high_minus_3200", 0x00453342,
            b"\x2d\x80\x0c\x00\x00\xa3\x6c\x07\x51\x00")
    _pin_at(ck, b, "camera_box.y_high_minus_3200", 0x0045335A,
            b"\x81\xe9\x80\x0c\x00\x00\x89\x0d\x70\x07\x51\x00")
    _pin_calls(ck, b, "camera_box.z_high", CAMERA_BOX_INIT, A_CAMERA_HEIGHT, 1)
    _pin_at(ck, b, "camera_box.z_high_store", 0x0045336B,
            b"\xa3\x74\x07\x51\x00")
    _pin_calls(ck, b, "camera_box.columns", CAMERA_BOX_INIT, 0x00419A60, 1)
    _pin_calls(ck, b, "camera_box.rows", CAMERA_BOX_INIT, 0x00419A50, 1)
    # `0x0047ABD0` -- the gradient of a facing, arm by arm out of the table.
    arms = [b.u32(GRADIENT_TABLE + 4 * i) for i in range(8)]
    decoded = []
    for arm in arms:
        head = b.pe.bytes_at(arm, 12)
        ok = head[0:2] == b"\xc7\x00" and head[6:8] == b"\xc7\x01"
        gx = struct.unpack_from("<i", head, 2)[0]
        gy = struct.unpack_from("<i", head, 8)[0]
        decoded.append((gx, gy) if ok else None)
    ck.check("gradients.table_is_facing_inverse", decoded == GRADIENTS,
             str(decoded))
    # §2.5 -- the pan's axes are `(0, -10, 0)` turned by the camera's angles,
    # written by the free rotation, and the drag is `* 40` on top.
    _pin_at(ck, b, "pan.forward_is_minus_10", 0x00451044,
            b"\xc7\x44\x24\x14\xf6\xff\xff\xff")
    _pin_calls(ck, b, "pan.forward_turned", FREE_ROTATION, 0x004039A0, 1)
    _pin_bytes(ck, b, "pan.forward_stored_at_0x50fe64", FREE_ROTATION,
               b"\x68\x64\xfe\x50\x00", 1)
    _pin_bytes(ck, b, "free_position.step_17x3", FREE_POSITION,
               b"\xc1\xe0\x04", 1)
    _pin_bytes(ck, b, "free_position.step_17x3_b", FREE_POSITION,
               b"\x8d\x04\x40", 1)
    _pin_calls(ck, b, "free_position", FREE_POSITION, A_CLAMP, 1)

    # The call sites and the (dist, height) bytes they push, docs/42 §2.3.
    sites = {
        "execute_move": (EXECUTE_MOVE, (4, 6)),
        "cycle": (CYCLE, (7, 8)),
        "view_on_unit": (VIEW_ON_UNIT, (7, 8)),
        "fight_behind_shooter": (FIGHT, (5, 9)),
        "fight_behind_victim": (FIGHT, (3, 5)),
        "bomb": ((0x004702C0, 0x00470790), (2, 5)),
        "lcl_a": ((0x00482130, 0x004821A0), (5, 6)),
        "lcl_b": ((0x004821A0, 0x00482250), (5, 6)),
    }
    for name, (rng, (height, dist)) in sites.items():
        _pin_bytes(ck, b, f"unit_camera.args.{name}", rng,
                   _push8(height) + _push8(dist), 1, at_least=True)
    # Two sites interleave the pushes with the coordinate loads.
    _pin_at(ck, b, "unit_camera.args.ground_fire_height_7", 0x00415B24, _push8(7))
    _pin_at(ck, b, "unit_camera.args.ground_fire_dist_9", 0x00415B2C, _push8(9))
    _pin_at(ck, b, "unit_camera.args.teleporter_height_5", 0x00470248, _push8(5))
    _pin_at(ck, b, "unit_camera.args.teleporter_dist_5", 0x00470250, _push8(5))
    calls = {"execute_move": (EXECUTE_MOVE, 1), "cycle": (CYCLE, 2),
             "view_on_unit": (VIEW_ON_UNIT, 1), "ground_fire": (GROUND_FIRE, 1),
             "fight": (FIGHT, 2),
             "teleporter": ((0x00470150, 0x004702C0), 1),
             "bomb": ((0x004702C0, 0x00470790), 1),
             "lcl_a": ((0x00482130, 0x004821A0), 1),
             "lcl_b": ((0x004821A0, 0x00482250), 1)}
    for name, (rng, n) in calls.items():
        _pin_calls(ck, b, f"unit_camera.site.{name}", rng, A_UNIT_CAMERA, n)

    # §2.4 -- the three views.
    mode = lambda v: b"\xc7\x05\xd8\x06\x51\x00" + struct.pack("<I", v)
    _pin_bytes(ck, b, "views.on_unit_sets_mode_2", VIEW_ON_UNIT, mode(2), 1)
    _pin_bytes(ck, b, "views.eyes_sets_mode_1", VIEW_EYES, mode(1), 1)
    _pin_bytes(ck, b, "views.map_sets_mode_4", VIEW_MAP, mode(4), 1)
    _pin_calls(ck, b, "views.eyes", VIEW_EYES, A_EYE_CAMERA, 1)
    _pin_calls(ck, b, "views.map", VIEW_MAP, A_MAP_CAMERA, 1)
    _pin_bytes(ck, b, "views.map_height_24000", MAP_VIEW_HEIGHT,
               struct.pack("<I", 24000), 1)
    _pin_bytes(ck, b, "views.map_target_ahead_3200", MAP_VIEW_HEIGHT,
               b"\x81\xc1\x80\x0c\x00\x00", 1)
    _pin_bytes(ck, b, "views.eyes_offset_800", EYE_VIEW, b"\xc1\xe0\x05", 1)
    _pin_bytes(ck, b, "views.eyes_height_640", EYE_VIEW,
               b"\x8d\x8c\x08\x80\x02\x00\x00", 1)
    _pin_bytes(ck, b, "views.eyes_target_minus_320", EYE_VIEW,
               b"\x81\xc1\xc0\xfe\xff\xff", 1)

    # §2.5 -- free control.
    _pin_bytes(ck, b, "mouse.rotate_x8_x2", MOUSE_ROTATE, b"\xc1\xe0\x03", 2)
    _pin_calls(ck, b, "mouse.rotate", MOUSE_ROTATE, A_ROTATE, 1)
    _pin_bytes(ck, b, "mouse.pan_x40", MOUSE_PAN, b"\x8d\x04\x80\xc1\xe0\x03", 1)
    _pin_calls(ck, b, "mouse.pan", MOUSE_PAN, A_MOVE, 1)
    _pin_calls(ck, b, "main_loop.rotate_on_right_drag", MAIN_LOOP, 0x00451000, 1)
    _pin_calls(ck, b, "main_loop.pan_on_middle_drag", MAIN_LOOP, 0x004511A0, 1)
    _pin_bytes(ck, b, "main_loop.height_key_plus_2000", MAIN_LOOP,
               _push32(2000), 1)
    _pin_bytes(ck, b, "main_loop.height_key_minus_2000", MAIN_LOOP,
               _push32(-2000), 1)
    _pin_calls(ck, b, "main_loop.height_key", MAIN_LOOP, A_MOVE, 1)


def _check_walk(ck: Checker, b: Binary) -> None:
    # §3.2 -- the tracking step keeps the position and re-aims the target.
    _pin_calls(ck, b, "walk.track.set_camera", WALK_STEP, A_SET_CAMERA, 1)
    _pin_calls(ck, b, "walk.track.view_mode", WALK_STEP, A_VIEW_MODE, 3)
    _pin_bytes(ck, b, "walk.track.not_in_map_view", WALK_STEP, b"\x83\xf8\x04", 1)
    _pin_bytes(ck, b, "walk.track.plus_0xa0", WALK_STEP, b"\x05\xa0\x00\x00\x00", 1)
    _pin_calls(ck, b, "walk.track.frame", WALK_STEP, A_FRAME, 1)
    _pin_bytes(ck, b, "walk.ride.sixths_x3", RIDE_STEP, b"\xb8\xab\xaa\xaa\x2a", 3)
    _pin_calls(ck, b, "walk.ride.set_camera", RIDE_STEP, A_SET_CAMERA, 1)
    _pin_calls(ck, b, "walk.ride.frame", RIDE_STEP, A_FRAME, 1)
    # The mode byte's branches inside aExecuteMove.
    _pin_calls(ck, b, "walk.mode.enemy_move_option", EXECUTE_MOVE, A_ENEMY_MOVE, 2)
    _pin_calls(ck, b, "walk.mode.on_screen_test", EXECUTE_MOVE, A_ON_SCREEN, 1)
    _pin_bytes(ck, b, "walk.mode.camera_low_12800", EXECUTE_MOVE,
               b"\x81\x7c\x24\x68\x00\x32\x00\x00", 1)
    _pin_calls(ck, b, "walk.mode.select_animation", EXECUTE_MOVE, A_SELECT_ANIM, 2)
    _pin_calls(ck, b, "walk.mode.map_camera", EXECUTE_MOVE, A_MAP_CAMERA, 1)
    _pin_calls(ck, b, "walk.step.ride", EXECUTE_MOVE, A_RIDE, 2)
    _pin_calls(ck, b, "walk.step.track", EXECUTE_MOVE, A_TRACK, 1)
    # The mode byte's inputs: `0x004794B0` asked at the destination and at
    # the source, the destination's answer dropped when the cell's `+0x0C`
    # is over 6. The probe is one `aCheckLineOfSightEx` per other-player unit
    # at `0x0047AD70` heights, skipping the beacon types 0x3D and 0x3E.
    _pin_calls(ck, b, "walk.mode.seen_probe_x3", EXECUTE_MOVE, A_SEEN_AT, 3)
    _pin_at(ck, b, "walk.mode.seen_probe_at_destination", 0x0046E330,
            b"\xe8" + struct.pack("<i", A_SEEN_AT - 0x0046E335))
    _pin_at(ck, b, "walk.mode.seen_probe_at_source", 0x0046E385,
            b"\xe8" + struct.pack("<i", A_SEEN_AT - 0x0046E38A))
    _pin_at(ck, b, "walk.mode.destination_plus_0x0c_over_6", 0x0046E357,
            b"\x80\x78\x0c\x06")
    _pin_calls(ck, b, "seen_at.line_of_sight", SEEN_AT, A_LOS_EX, 1)
    _pin_calls(ck, b, "seen_at.unit_height_x2", SEEN_AT, 0x0047AD70, 2)
    _pin_bytes(ck, b, "seen_at.skips_0x3d", SEEN_AT, b"\x3c\x3d", 1)
    _pin_bytes(ck, b, "seen_at.skips_0x3e", SEEN_AT, b"\x3c\x3e", 1)
    _pin_calls(ck, b, "walk.step.hide_rider", EXECUTE_MOVE, A_HIDE, 4)
    _pin_calls(ck, b, "walk.clip_started_once", EXECUTE_MOVE, A_START_ANIM, 1)
    # The selection animation only re-aims in view modes 2 and 3.
    _pin_calls(ck, b, "walk.select.view_mode", SELECT_ANIMATION, A_VIEW_MODE, 3)
    _pin_calls(ck, b, "walk.select.flight", SELECT_ANIMATION, A_FLIGHT, 1)


def _check_clocks(ck: Checker, b: Binary) -> None:
    # §1.2 -- the four start speeds and the loop counts.
    _pin_bytes(ck, b, "speed.walk_2_0", START_ANIMATION, _push32(0x40000000), 1)
    _pin_bytes(ck, b, "speed.fight_6_0", START_ANIMATION, _push32(0x40C00000), 1)
    _pin_bytes(ck, b, "speed.m2_1_0", START_ANIMATION, _push32(0x3F800000), 1)
    _pin_bytes(ck, b, "speed.idle_1_5", IDLE_STARTER, _push32(0x3FC00000), 1)
    _pin_bytes(ck, b, "loops.walk_and_m2_100000_x2", START_ANIMATION,
               _push32(100000), 2)
    _pin_bytes(ck, b, "speed.start_slot_0x2c_x3", START_ANIMATION,
               b"\xff\x55\x2c", 1)
    _pin_bytes(ck, b, "speed.start_slot_0x2c_x3_b", START_ANIMATION,
               b"\xff\x57\x2c", 2)
    _pin_bytes(ck, b, "speed.idle_start_slot_0x2c", IDLE_STARTER, b"\xff\x55\x2c", 1)
    _pin_bytes(ck, b, "fight.break_note", START_ANIMATION, _push32(0x004C0268), 1)
    _pin_calls(ck, b, "fight.break_callback", START_ANIMATION, A_NOTE_CALLBACK, 1)
    # §1.3 -- the refresh: four idle slots, the 60 m freeze, the sweep.
    idle_calls = _pin_calls(ck, b, "refresh.idle_slots", VIEW_REFRESH,
                            A_IDLE_START, 4)
    slots = []
    for site in idle_calls:
        # the slot is the second-to-last push: `push type; push slot`? no --
        # `push slot` is the last before the call for slots 2, 4, 5 and the
        # type-carrying slot 1 pushes `push 0x3d`/`-1` first.
        window = b.pe.bytes_at(site - 12, 12)
        pushes = [window[i + 1] for i in range(len(window) - 1) if window[i] == 0x6A]
        slots.append(pushes[-1] if pushes else None)
    ck.check("refresh.idle_slots_are_1_2_4_5", slots == [1, 2, 4, 5], str(slots))
    _pin_bytes(ck, b, "refresh.boss_type_61_in_C118", VIEW_REFRESH, _push8(0x3D), 1)
    _pin_bytes(ck, b, "refresh.C118_string", VIEW_REFRESH, b"\xbe\x70\x04\x4c\x00", 1)
    _pin_bytes(ck, b, "refresh.freeze_above_96000", VIEW_REFRESH,
               b"\x3d\x00\x77\x01\x00", 1)
    _pin_bytes(ck, b, "refresh.simulate_1_0", VIEW_REFRESH, _push32(0x3F800000), 1)
    _pin_bytes(ck, b, "refresh.simulate_slot_0x40", VIEW_REFRESH, b"\xff\x50\x40", 1)
    _pin_bytes(ck, b, "refresh.knocked_down_model", VIEW_REFRESH,
               _push32(0x004C0464), 1)                       # "A_BLIB.3DI"
    _pin_calls(ck, b, "refresh.blob_sweep", VIEW_REFRESH, A_BLOB_SWEEP, 1)
    # §6.1 -- the starter.
    _pin_calls(ck, b, "idle.animation_level_option", IDLE_STARTER, A_ANIM_LEVEL, 1)
    _pin_calls(ck, b, "idle.frees_the_slot", IDLE_STARTER, A_FREE_ANIM, 1)
    _pin_calls(ck, b, "idle.random_unit", IDLE_STARTER, A_RANDOM2, 1)
    _pin_calls(ck, b, "idle.selector", IDLE_STARTER, A_IDLE_SELECT, 1)
    _pin_bytes(ck, b, "idle.length_stored", IDLE_STARTER,
               b"\xd9\x9f\x44\xa8\x4f\x00", 1)               # fstp [edi+0x4fa844]
    _pin_bytes(ck, b, "idle.length_slot_0x24", IDLE_STARTER, b"\xff\x55\x24", 1)
    # §6.2 -- freeing detaches through the model's slot 2.
    _pin_bytes(ck, b, "idle.free_calls_model_slot_2", FREE_ANIMATION,
               b"\xff\x50\x08", 1)
    _pin_calls(ck, b, "idle.free_clears_unit_slot", FREE_ANIMATION, 0x00477980, 1)
    # §6.1 -- the type search compares unit 0's type two hundred times and
    # never advances, so the argument is dead and the draw decides (measured
    # by presentation_gold's idle_random phase).
    _pin_at(ck, b, "idle.type_search_does_not_advance", STARTER_LOOP, STARTER_LOOP_BYTES)
    _pin_at(ck, b, "idle.draw_is_0_200", STARTER_RANDOM_PUSHES, _push32(200) + _push8(0))
    # §1.2 -- the length: KeyFramedAnimation::Init asks the first movement
    # (slot 0xC of its own list, index 0) for IMovement slot 0x2C and stores
    # the answer at +0x60; the movement classes answer the last key's +4.
    _pin_at(ck, b, "length.first_movement_slot_0x0c", 0x004A0B6C, b"\xff\x50\x0c")
    _pin_at(ck, b, "length.movement_slot_0x2c", 0x004A0B8D, b"\xff\x50\x2c")
    _pin_at(ck, b, "length.stored_at_0x60", 0x004A0B90, b"\x8b\x45\xcc\xd9\x58\x60")
    for name, (vtable, fn) in MOVEMENT_VTABLES.items():
        ck.check(f"length.{name}_slot_0x2c", b.u32(vtable + MOVEMENT_LENGTH_SLOT) == fn,
                 hex(b.u32(vtable + MOVEMENT_LENGTH_SLOT)))
        ck.check(f"length.{name}_rtti", _rtti_name(b, vtable)[0] == f".?AV{name}@@",
                 str(_rtti_name(b, vtable)))
    # the last key: `(count - 1) * stride` through +0x74 / +0x78, then the
    # key's slot 0x14, which is `fld dword [ecx + 4]` -- its time.
    _pin_bytes(ck, b, "length.last_key_count_at_0x74", (0x004A8873, 0x004A88CB),
               b"\x8b\x40\x74", 1)
    _pin_bytes(ck, b, "length.keys_at_0x78", (0x004A8873, 0x004A88CB), b"\x03\x41\x78", 1)
    _pin_bytes(ck, b, "length.key_slot_0x14", (0x004A8873, 0x004A88CB), b"\xff\x52\x14", 1)
    for name, (vtable, fn) in KEY_VTABLES.items():
        ck.check(f"length.{name}_slot_0x14", b.u32(vtable + KEY_TIME_SLOT) == fn,
                 hex(b.u32(vtable + KEY_TIME_SLOT)))
        _pin_bytes(ck, b, f"length.{name}_time_is_plus_4", (fn, fn + 0x20), b"\xd9\x40\x04", 1)
    # §1.2 -- the start slot's class: the starters cast to
    # KeyFramedAnimationInterface, implemented by KeyFramedAnimation's
    # sub-object at +80; its slot 0x2C writes +0x14 of that sub-object --
    # +0x64, the speed -- and re-runs Update(0); 0x24 reads +0x10 (+0x60,
    # the length); 0x18 zeroes +8 (+0x58, the time).
    ck.check("interface.abstract_rtti",
             _rtti_name(b, KEYFRAMED_INTERFACE_ABSTRACT) == (".?AVKeyFramedAnimationInterface@@", 0),
             str(_rtti_name(b, KEYFRAMED_INTERFACE_ABSTRACT)))
    ck.check("interface.implementation_rtti",
             _rtti_name(b, KEYFRAMED_INTERFACE_VTABLE) == (".?AVKeyFramedAnimation@@", 80),
             str(_rtti_name(b, KEYFRAMED_INTERFACE_VTABLE)))
    for slot, fn in INTERFACE_SLOTS.items():
        ck.check(f"interface.slot_0x{slot:02x}", b.u32(KEYFRAMED_INTERFACE_VTABLE + slot) == fn,
                 hex(b.u32(KEYFRAMED_INTERFACE_VTABLE + slot)))
    _pin_bytes(ck, b, "interface.set_speed_writes_0x14", (0x004A0EBB, 0x004A0EED),
               b"\x8b\x4d\x08\x89\x48\x14", 1)
    _pin_bytes(ck, b, "interface.set_speed_updates", (0x004A0EBB, 0x004A0EED),
               b"\x83\xe9\x50\xff\x50\x38", 1)
    _pin_bytes(ck, b, "interface.get_length_reads_0x10", (0x004A0E83, 0x004A0E9F), b"\xd9\x40\x10", 1)
    _pin_bytes(ck, b, "interface.rewind_zeroes_0x08", (0x004A0E1A, 0x004A0E4B),
               b"\xc7\x40\x08\x00\x00\x00\x00", 1)
    ck.check("interface.part_and_model_rtti",
             _rtti_name(b, PART_VTABLE) == (".?AVV100Part@@", 0)
             and _rtti_name(b, MODEL_VTABLE) == (".?AVV100Model@@", 0), "")


def _check_fight(ck: Checker, b: Binary) -> None:
    # §4 -- the reaction flag is aAttackUnit's fifth argument.
    _pin_at(ck, b, "fight.reaction_flag_forwarded", 0x0046C16A,
            b"\x8b\x84\x24\x84\x00\x00\x00")
    _pin_calls(ck, b, "fight.called_by_attack", ATTACK_UNIT, A_FIGHT, 1)
    # §4.1
    _pin_calls(ck, b, "fight.clip_started", FIGHT, A_START_ANIM, 1)
    _pin_calls(ck, b, "fight.adjacent_test", FIGHT, A_DISTANCE, 2)
    _pin_calls(ck, b, "fight.remaining_frames", FIGHT, A_REMAINING, 3)
    # §4.2 -- the caption format and the text ids.
    _pin_bytes(ck, b, "fight.caption_format", FIGHT, _push32(0x004C11D4), 1)
    for name, tid in (("received", 0x11), ("experience_points", 0x12),
                      ("missed", 0x0A), ("paralyzed", 0x13)):
        _pin_bytes(ck, b, f"fight.text_{name}", FIGHT, _push8(tid), 1, at_least=True)
    _pin_bytes(ck, b, "text_bank_3_is_txtmod_h", TEXT_BANKS,
               _push32(0x004C5F74) + _push8(3), 1)
    off = b.pe.va_to_off(EMPTY_CAPTION)
    ck.check("fight.empty_caption_is_zero",
             off is None or b.pe.bytes_at(EMPTY_CAPTION, 4) == b"\0\0\0\0")
    # §4.3 -- the camera.
    _pin_bytes(ck, b, "fight.screen_y_max_99", FIGHT, b"\x83\xf8\x64", 1)
    _pin_at(ck, b, "fight.screen_y_min_21", 0x0040C2C3, b"\x83\xf8\x14")
    _pin_bytes(ck, b, "fight.height_gap_0x12c0", FIGHT, b"\x3d\xc0\x12\x00\x00", 1)
    _pin_bytes(ck, b, "fight.large_type_5600_x3", FIGHT, b"\xb8\xe0\x15\x00\x00", 3)
    _pin_calls(ck, b, "fight.direction", FIGHT, A_DIRECTION, 3)
    _pin_calls(ck, b, "fight.reaction_position", FIGHT, A_REACTION_POS, 2)
    _pin_calls(ck, b, "fight.reaction_coin", FIGHT, A_RANDOM2, 1)
    # The reaction camera's numbers, both arms (`0x0040C08E`, `0x0040C1C8`):
    # 2400 in `eax` is what the horizontal direction is scaled by (`fild
    # [esp+0x14]`, `fmul [esp+0x34]`), 4800 in `[esp+0x1c]` what the slope
    # is (`fild [esp+0x20]` after the push, `fmul [esp+0x60]`); 5600 and
    # 8000 for a large type behind.
    for name, va in (("first", 0x0040C08E), ("second", 0x0040C1C8)):
        _pin_at(ck, b, f"fight.reaction_{name}.back_2400_slope_4800", va,
                b"\xb8\x60\x09\x00\x00\xc7\x44\x24\x1c\xc0\x12\x00\x00")
    for name, va in (("first", 0x0040C0A5), ("second", 0x0040C1DF)):
        _pin_at(ck, b, f"fight.reaction_{name}.large_5600_8000", va,
                b"\xb8\xe0\x15\x00\x00\xc7\x44\x24\x1c\x40\x1f\x00\x00")
    _pin_at(ck, b, "fight.reaction_first.back_scales_direction", 0x0040C0BA,
            b"\xdb\x44\x24\x14\xdc\x4c\x24\x34")
    _pin_at(ck, b, "fight.reaction_first.slope_term", 0x0040C0E8,
            b"\xdb\x44\x24\x20")
    _pin_at(ck, b, "fight.reaction_first.slope_times_third", 0x0040C0F3,
            b"\xdc\x4c\x24\x60")
    _pin_bytes(ck, b, "reaction_pos.neighbour_limit_16000", REACTION_POS,
               b"\x80\x3e\x00\x00", 1, at_least=True)
    _pin_bytes(ck, b, "reaction_pos.plus_800", REACTION_POS,
               b"\x20\x03\x00\x00", 1, at_least=True)
    _pin_bytes(ck, b, "reaction_pos.no_unit_plus_3200", REACTION_POS,
               b"\x80\x0c\x00\x00", 1, at_least=True)
    _pin_calls(ck, b, "fight.flight", FIGHT, A_FLIGHT, 1)
    # §4.4 -- the markers and the colour.
    _pin_bytes(ck, b, "fight.marker_0x5a_x2", FIGHT, b"\x3c\x5a", 2)
    _pin_bytes(ck, b, "fight.marker_0x5d_x2", FIGHT, b"\x3c\x5d", 2)
    _pin_bytes(ck, b, "fight.text_colour_0x5acb_x5", FIGHT,
               b"\x66\xc7\x06\xcb\x5a", 5)
    # §4.5 -- the death screams.
    for name, va in (("SP_HUM_0", 0x004C1124), ("SP_HUM_1", 0x004C1134),
                     ("SP_HUM_2", 0x004C1144)):
        _pin_bytes(ck, b, f"fight.scream_{name}_x2", FIGHT, _push32(va), 2)
    _pin_bytes(ck, b, "fight.scream_species_3_explosion", FIGHT,
               _push32(0x004C1154), 1, at_least=True)
    # §4.6 -- the projectile wait and the flag.
    _pin_bytes(ck, b, "fight.wait_100_frames", FIGHT, b"\x83\xf9\x64", 1)
    _pin_calls(ck, b, "fight.arrived_flag", FIGHT, A_ARRIVED, 1)
    writes = []
    lo, hi = BLOB_UPDATE
    blob = b.span(lo, hi)
    one = b"\xc7\x05" + struct.pack("<I", ARRIVED_FLAG) + struct.pack("<I", 1)
    reg = b"\x89\x2d" + struct.pack("<I", ARRIVED_FLAG)
    start = 0
    while True:
        i = blob.find(one, start)
        j = blob.find(reg, start)
        cands = [c for c in (i, j) if c >= 0]
        if not cands:
            break
        k = min(cands)
        writes.append(lo + k)
        start = k + 1
    arms = [b.u32(BLOB_JUMP_TABLE + 4 * i) for i in range(BLOB_KINDS)]
    starts = sorted(set(arms))
    kinds = set()
    for site in writes:
        arm = max(s for s in starts if s <= site)
        kinds |= {k for k, a in enumerate(arms) if a == arm}
    ck.check("fight.arrived_flag_written_by_13_arms", len(writes) == 13,
             str([hex(w) for w in writes]))
    ck.check("fight.arrived_flag_kinds", kinds == ARRIVED_KINDS,
             str(sorted(kinds)))
    # §4.8 -- the death switch's creators and the hide.
    for name, va in DEATH_CREATORS.items():
        n = len(b.calls(FIGHT, va))
        ck.check(f"fight.death.{name}", n >= 1, f"{n} calls")
    _pin_calls(ck, b, "fight.death.hide_x2", FIGHT, A_HIDE, 2)
    # §4.8 -- what the four unnamed creators build (docs/42 §4.8.1).
    _pin_bytes(ck, b, "death.blood_burst.kind_17_life_15", BLOOD_BURST, _push8(0xF) + _push8(0x11), 1)
    _pin_bytes(ck, b, "death.blood_burst.kind_43_life_15", BLOOD_BURST, _push8(0xF) + _push8(0x2B), 1)
    _pin_bytes(ck, b, "death.blood_burst.model", BLOOD_BURST, _push32(0x004C22B4), 2)   # A_BLUT4
    _pin_calls(ck, b, "death.blood_burst.gore_x2", BLOOD_BURST, A_GORE_LEVEL, 2)
    _pin_calls(ck, b, "death.blood_burst.puff", BLOOD_BURST, DEATH_PUFF[0], 2)
    _pin_bytes(ck, b, "death.puff.kind_59_life_20", DEATH_PUFF, _push8(0x14) + _push8(0x3B), 1)
    _pin_bytes(ck, b, "death.barrel_burst.kind_5_life_100", BARREL_BURST, _push8(0x64) + _push8(0x05), 1)
    _pin_bytes(ck, b, "death.blood_spray_large.kind_50_life_8", BLOOD_SPRAY_LARGE, _push8(0x08) + _push8(0x32), 1)
    _pin_bytes(ck, b, "death.blood_flood.kind_60_life_8_x2", BLOOD_FLOOD, _push8(0x08) + _push8(0x3C), 2)
    _pin_bytes(ck, b, "death.blood_flood.kind_17_life_8_x2", BLOOD_FLOOD, _push8(0x08) + _push8(0x11), 2)
    _pin_calls(ck, b, "death.blood_flood.gore", BLOOD_FLOOD, A_GORE_LEVEL, 1)
    _pin_bytes(ck, b, "death.species_burst.splat5_kind_18_life_30_x3", SPECIES_BURST,
               _push8(0x1E) + _push8(0x12), 3)
    _pin_bytes(ck, b, "death.species_burst.puffs_kind_51_life_16_x2", SPECIES_BURST,
               _push8(0x10) + _push8(0x33), 2)
    _pin_bytes(ck, b, "death.species_burst.piece_kind_18_life_50", SPECIES_BURST,
               _push8(0x32) + _push8(0x12), 1)
    _pin_at(ck, b, "death.species_burst.coin_6_0", 0x00421DFB, b"\xdc\x1d\x68\x12\x4b\x00")
    _pin_calls(ck, b, "death.species_burst.gore_x2", SPECIES_BURST, A_GORE_LEVEL, 2)
    _pin_calls(ck, b, "death.species_burst.blood_flood_x2", SPECIES_BURST, 0x00420D80, 2)
    _pin_calls(ck, b, "death.species_burst.flying_debris_x2", SPECIES_BURST, 0x004216D0, 2)
    for name, va in (("A_50A", 0x004C2388), ("A_51A", 0x004C2364), ("A_56A", 0x004C2340),
                     ("A_57A", 0x004C2334)):
        _pin_bytes(ck, b, f"death.species_burst.model_{name}", SPECIES_BURST,
                   struct.pack("<I", va), 1)
    _pin_bytes(ck, b, "death.flying_debris.kind_18_life_50_x2", FLYING_DEBRIS,
               _push8(0x32) + _push8(0x12), 1, at_least=True)
    _pin_bytes(ck, b, "death.flying_debris.kind_18_life_30", FLYING_DEBRIS,
               _push8(0x1E) + _push8(0x12), 1, at_least=True)
    for va, value in BLOOD_DOUBLES.items():
        ck.check(f"death.double_{va:08x}_is_{value}", b.pe.f64(va) == value, str(b.pe.f64(va)))
    # The gore level: six reads in four routines, and what level 2 tests.
    sites = set(b.calls(TEXT, A_GORE_LEVEL))
    ck.check("gore.readers", sites == GORE_READERS, str(sorted(hex(x) for x in sites)))
    ck.check("gore.readers_in_four_routines",
             all(any(lo <= site < hi for lo, hi in GORE_READER_RANGES) for site in sites), "")
    _pin_bytes(ck, b, "gore.level_2_tests_player_0xff", BLOOD_BURST, GORE_PLAYER_TEST, 1)
    _pin_bytes(ck, b, "gore.level_1_test", BLOOD_BURST, b"\x83\xf8\x01", 1)
    _pin_bytes(ck, b, "gore.level_2_test", BLOOD_BURST, b"\x83\xf8\x02", 1)
    # §4.9 -- the end.
    _pin_at(ck, b, "fight.end_min_20_frames", 0x0040E256, b"\x83\xf8\x14")
    _pin_calls(ck, b, "fight.end_pool_empty", FIGHT, A_ALIVE, 2)
    _pin_calls(ck, b, "fight.end_resumes_clip", FIGHT, A_CONT_ANIM, 1)
    # §1.1 -- the tick's overlay: caption at (80, 54), rise by 2, fade.
    _pin_bytes(ck, b, "tick.caption_at_80_54", FRAME_TICK, _push8(0x36) + _push8(0x50), 1)
    _pin_bytes(ck, b, "tick.text_rises_2px", FRAME_TICK, b"\x83\xc2\xfe", 1)
    _pin_bytes(ck, b, "tick.fade_reads_countdown", FRAME_TICK,
               b"\xa1\xa0\xc0\x4f\x00", 3)
    _pin_bytes(ck, b, "tick.skip_controller_10_20", FRAME_TICK,
               _push8(0x14) + _push8(0x0A), 1)


def _check_others(ck: Checker, b: Binary) -> None:
    # §7.1 -- the jump.
    _pin_calls(ck, b, "jump.trail", JUMP, A_TRAIL, 1)
    _pin_calls(ck, b, "jump.landing_dust_x2", JUMP, A_LANDING_DUST, 2)
    _pin_calls(ck, b, "jump.camera_looks_at_flyer", JUMP, A_SET_CAMERA, 1)
    _pin_bytes(ck, b, "jump.gravity_160", JUMP, b"\x2d\xa0\x00\x00\x00", 1)
    _pin_bytes(ck, b, "jump.wave", JUMP, _push32(0x004C1384), 1)
    _pin_bytes(ck, b, "jump.drop_wave", JUMP, _push32(0x004C1378), 1)
    # §7.2 -- the push.
    _pin_calls(ck, b, "push.flight", PUSH, A_FLIGHT, 1)
    _pin_calls(ck, b, "push.dust_per_frame", PUSH, A_DUST, 1)
    _pin_bytes(ck, b, "push.four_frames_per_cell", PUSH, b"\x83\xf8\x04", 1)
    _pin_bytes(ck, b, "push.hole_50_steps", PUSH, b"\x83\xff\x32", 1)
    _pin_calls(ck, b, "push.dust_is_a_blob", PUSH_DUST, A_CTOR, 1)
    _pin_bytes(ck, b, "push.dust_life_20", PUSH_DUST, _push8(0x14), 1)
    # §7.3 -- the arrows.
    _pin_bytes(ck, b, "marker.model", ARROW_MARKER, _push32(0x004C2404), 1)
    _pin_bytes(ck, b, "marker.kind_14_life_15", ARROW_MARKER, _push8(0x0F) + _push8(0x0E), 1)
    _pin_bytes(ck, b, "marker.radius_large_9600", ARROW_MARKER, b"\xbf\x80\x25\x00\x00", 1)
    _pin_calls(ck, b, "marker.is_a_blob", ARROW_MARKER, A_CTOR, 1)
    # §7.5 -- the orbits: 40 frames, arrows or flash circle, a rotation step.
    for name, rng, arrows in (("skill", ORBIT_SKILL, True), ("jam", ORBIT_JAM, True),
                              ("overheat", ORBIT_OVERHEAT, True),
                              ("rotating", ORBIT_ROTATING, True),
                              ("heal", ORBIT_HEAL, False), ("poison", ORBIT_POISON, False)):
        _pin_bytes(ck, b, f"orbit.{name}.frames_40", rng, b"\x28\x00\x00\x00", 1, at_least=True)
        _pin_calls(ck, b, f"orbit.{name}.rotate_step", rng, A_ROTATE_VECTOR, 1)
        _pin_calls(ck, b, f"orbit.{name}.arrows", rng, A_ARROWS, 1 if arrows else 0)
    _pin_calls(ck, b, "orbit.heal.flash_circle", ORBIT_HEAL, A_FLASH_CIRCLE_HEAL, 1)
    _pin_calls(ck, b, "orbit.poison.flash_circle", ORBIT_POISON, A_FLASH_CIRCLE_POISON, 1)
    _pin_bytes(ck, b, "orbit.heal.step_minus_40", ORBIT_HEAL, b"\xd8\xff", 1, at_least=True)
    _pin_bytes(ck, b, "orbit.poison.step_minus_40", ORBIT_POISON, b"\xd8\xff", 1, at_least=True)
    _pin_bytes(ck, b, "orbit.heal.offset_0x1900", ORBIT_HEAL, b"\x81\xc6\x00\x19\x00\x00", 1)
    _pin_bytes(ck, b, "orbit.poison.offset_0x1900", ORBIT_POISON, b"\x81\xc6\x00\x19\x00\x00", 1)
    _pin_bytes(ck, b, "orbit.rotating.offset_0xc80", ORBIT_ROTATING, b"\x8d\xaf\x80\x0c\x00\x00", 1)
    for name, rng, tid in (("skill", ORBIT_SKILL, 3), ("heal", ORBIT_HEAL, 4),
                           ("poison", ORBIT_POISON, 5)):
        _pin_bytes(ck, b, f"orbit.{name}.text_id", rng, _push8(tid), 1, at_least=True)
    for tid in (0x0E, 0x0F, 0x10):
        _pin_bytes(ck, b, f"orbit.overheat.text_{tid}", ORBIT_OVERHEAT, _push8(tid), 1, at_least=True)
    _pin_calls(ck, b, "orbit.overheat.fire_explosion", ORBIT_OVERHEAT, 0x00429A80, 1)
    _pin_calls(ck, b, "orbit.overheat.blood", ORBIT_OVERHEAT, 0x00420D80, 1)
    _pin_calls(ck, b, "orbit.overheat.hide", ORBIT_OVERHEAT, A_HIDE, 1)
    # §8 -- set pieces: the camera and the effects.
    _pin_calls(ck, b, "setpiece.door.flights_x2", DOOR, A_FLIGHT, 2)
    _pin_bytes(ck, b, "setpiece.door.frames_10", DOOR, b"\xbd\x0a\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.door.no_camera_on_minus_1", DOOR, b"\x83\xfe\xff", 2)
    _pin_calls(ck, b, "setpiece.elevator.flight", ELEVATOR, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.elevator.camera_per_frame", ELEVATOR, A_SET_CAMERA, 1)
    _pin_calls(ck, b, "setpiece.platform.flight", PLATFORM, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.platform.camera_per_frame", PLATFORM, A_SET_CAMERA, 1)
    _pin_calls(ck, b, "setpiece.platform.dust_per_frame", PLATFORM, A_PLATFORM_DUST, 1)
    _pin_calls(ck, b, "setpiece.barrier.flights_x2", BARRIER, A_FLIGHT, 2)
    _pin_calls(ck, b, "setpiece.barrier.beam", BARRIER, A_BEAM, 1)
    _pin_calls(ck, b, "setpiece.barrier.kill_effects", BARRIER, A_BARRIER_HIT_A, 1)
    _pin_calls(ck, b, "setpiece.barrier.kill_effects_b", BARRIER, A_BARRIER_HIT_B, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.free_position", GROUND_FIRE, A_FREE_POSITION, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.hide", GROUND_FIRE, A_HIDE, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.blood", GROUND_FIRE, 0x00420D80, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.debris", GROUND_FIRE, 0x004216D0, 1)
    _pin_calls(ck, b, "setpiece.ground_fire.smoke", GROUND_FIRE, A_TUBE_SMOKE, 1)
    _pin_calls(ck, b, "setpiece.crush_wall.debris", CRUSH_WALL, A_WALL_DEBRIS, 1)
    # §8 -- the four set pieces transcribed line by line (docs/42 §8.1).
    _pin_bytes(ck, b, "setpiece.statue.box_10000_x3", STATUE, _push32(0x2710), 3)
    _pin_bytes(ck, b, "setpiece.statue.height_32000", STATUE, _push32(0x7D00), 1)
    _pin_bytes(ck, b, "setpiece.statue.frames_13", STATUE, b"\x0d\x00\x00\x00", 1, at_least=True)
    _pin_bytes(ck, b, "setpiece.statue.settle_plus_0x400", STATUE, b"\x81\xc2\x00\x04\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.statue.path_5_x2", STATUE, b"\x83\x7c\x24\x3c\x06", 2)
    _pin_calls(ck, b, "setpiece.statue.flight", STATUE, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.statue.fire_death_x2", STATUE, 0x0042B1D0, 2)
    _pin_calls(ck, b, "setpiece.statue.beam_x2", STATUE, 0x00428BF0, 2)
    _pin_calls(ck, b, "setpiece.statue.hide_x2", STATUE, A_HIDE, 2)
    _pin_calls(ck, b, "setpiece.statue.remove_x2", STATUE, 0x004779C0, 2)
    _pin_bytes(ck, b, "setpiece.statue2.height_32000", STATUE_2, _push32(0x7D00), 1)
    _pin_bytes(ck, b, "setpiece.statue2.path_9", STATUE_2, b"\x83\xf8\x0a", 1)
    _pin_calls(ck, b, "setpiece.statue2.beam", STATUE_2, 0x00428BF0, 1)
    _pin_bytes(ck, b, "setpiece.statue_beam.kind_62_life_7", STATUE_BEAM, _push8(0x07) + _push8(0x3E), 2)
    _pin_bytes(ck, b, "setpiece.statue_beam.dots_z_3200", STATUE_BEAM, _push32(0xC80), 2)
    _pin_bytes(ck, b, "setpiece.statue_beam.spark_spread_6000_x2", STATUE_BEAM, _push32(0x1770), 2)
    _pin_bytes(ck, b, "setpiece.statue_beam.spark_vz_800", STATUE_BEAM, _push32(0x320), 1)
    _pin_bytes(ck, b, "setpiece.statue_beam.sparks_6", STATUE_BEAM, b"\x83\xf8\x06", 1)
    for name, rng in (("footbridge", FOOTBRIDGE), ("footbridge2", FOOTBRIDGE_2)):
        _pin_bytes(ck, b, f"setpiece.{name}.tilt_draw_minus2_4", rng, _push8(4) + _push8(0xFE), 1)
        _pin_bytes(ck, b, f"setpiece.{name}.block_drop_3360", rng, b"\x81\xe9\x20\x0d\x00\x00", 1)
        _pin_bytes(ck, b, f"setpiece.{name}.camera_drop_2400", rng, b"\x81\xea\x60\x09\x00\x00", 1)
        _pin_bytes(ck, b, f"setpiece.{name}.rider_drop_3200", rng, b"\x2d\x80\x0c\x00\x00", 1)
        _pin_bytes(ck, b, f"setpiece.{name}.rider_drawn_160_up", rng, b"\x05\xa0\x00\x00\x00",
                   1 if name == "footbridge" else 3)
        _pin_bytes(ck, b, f"setpiece.{name}.rider_tilt_25_12", rng, b"\xbb\x0c\x00\x00\x00", 1)
        _pin_calls(ck, b, f"setpiece.{name}.flights_x2", rng, A_FLIGHT, 2)
        _pin_calls(ck, b, f"setpiece.{name}.camera_per_frame", rng, A_SET_CAMERA, 2)
        _pin_calls(ck, b, f"setpiece.{name}.rotation_read_write", rng, 0x00405180, 1)
        _pin_calls(ck, b, f"setpiece.{name}.rotation_write", rng, 0x004051E0, 1)
        _pin_calls(ck, b, f"setpiece.{name}.riders_removed", rng, 0x004779C0, 1)
        _pin_calls(ck, b, f"setpiece.{name}.tilt_draw", rng, A_RANDOM2, 1)
    _pin_bytes(ck, b, "setpiece.footbridge.tilt_x17", FOOTBRIDGE, b"\xc1\xe7\x04", 1)
    _pin_bytes(ck, b, "setpiece.footbridge2.tilt_x17", FOOTBRIDGE_2, b"\xc1\xe0\x04", 1)
    _pin_bytes(ck, b, "setpiece.footbridge2.box_500_500_12800", FOOTBRIDGE_2,
               _push32(0x3200) + _push32(0x1F4) + _push32(0x1F4), 2)
    _pin_bytes(ck, b, "setpiece.ground_unit.rise_1120", GROUND_UNIT, b"\x81\xc6\x60\x04\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.start_3200_down", GROUND_UNIT, b"\x81\xee\x80\x0c\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.frames_8", GROUND_UNIT, b"\x83\xfb\x07", 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.fifths_x3", GROUND_UNIT, b"\xb8\x67\x66\x66\x66", 3)
    _pin_bytes(ck, b, "setpiece.ground_unit.scream_wait_4", GROUND_UNIT,
               b"\xc7\x44\x24\x2c\x04\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.exit_model", GROUND_UNIT, _push32(0x004C13F8), 1)
    _pin_bytes(ck, b, "setpiece.ground_unit.debris_1600_up", GROUND_UNIT, b"\x81\xc1\x40\x06\x00\x00", 1)
    _pin_calls(ck, b, "setpiece.ground_unit.flight", GROUND_UNIT, A_FLIGHT, 1)
    _pin_calls(ck, b, "setpiece.ground_unit.debris", GROUND_UNIT, 0x00422610, 1)
    _pin_calls(ck, b, "setpiece.ground_unit.landing_dust", GROUND_UNIT, A_LANDING_DUST, 1)
    _pin_calls(ck, b, "setpiece.ground_unit.object_inserted", GROUND_UNIT, 0x00404E30, 1)
    _pin_bytes(ck, b, "setpiece.ground_debris.debris_20", GROUND_UNIT_DEBRIS, _push8(0x28), 2)
    _pin_bytes(ck, b, "setpiece.ground_debris.splats_4", GROUND_UNIT_DEBRIS,
               b"\xc7\x44\x24\x18\x04\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.teleporter.frames_70", TELEPORTER, b"\xbe\x46\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.teleporter.hide_at_40_x2", TELEPORTER, b"\x83\xfe\x28", 2)
    _pin_bytes(ck, b, "setpiece.teleporter.move_at_10_x2", TELEPORTER, b"\x83\xfe\x0a", 2)
    _pin_calls(ck, b, "setpiece.teleporter.camera_follows", TELEPORTER, 0x0042B4B0, 1)
    _pin_calls(ck, b, "setpiece.teleporter.stream", TELEPORTER, 0x0042A120, 1)
    _pin_bytes(ck, b, "setpiece.teleporter_stream.200_x16", TELEPORTER_STREAM, b"\x81\xff\xc8\x00\x00\x00", 1)
    _pin_bytes(ck, b, "setpiece.teleporter_stream.rise_16", TELEPORTER_STREAM, b"\x83\xc6\x10", 1)
    _pin_bytes(ck, b, "setpiece.teleporter_stream.kind_65_life_70", TELEPORTER_STREAM,
               _push8(0x46) + _push8(0x41), 1)
    _pin_bytes(ck, b, "setpiece.teleport_kill.frames_10", TELEPORT_KILL, b"\x0a\x00\x00\x00", 1, at_least=True)
    _pin_calls(ck, b, "setpiece.teleport_kill.gore", TELEPORT_KILL, A_GORE_LEVEL, 1)
    _pin_calls(ck, b, "setpiece.teleport_kill.puff", TELEPORT_KILL, DEATH_PUFF[0], 1)
    _pin_calls(ck, b, "setpiece.teleport_kill.debris", TELEPORT_KILL, 0x004216D0, 1)
    # §9.1 -- the special-object state byte.
    _pin_calls(ck, b, "objects.mine_placer", MINE_PLACER, A_CREATE_SPECIAL, 1)
    _pin_calls(ck, b, "objects.fire_placer", FIRE_PLACER, A_CREATE_SPECIAL, 1)
    _pin_calls(ck, b, "objects.glow_placer", GLOW_PLACER, A_CREATE_SPECIAL, 1)
    # aCreateSpecialObject writes its last two arguments to +0x40 and +0x41.
    _pin_bytes(ck, b, "objects.free_slot_is_0xff", CREATE_SPECIAL, b"\xb0\xff\x38\x46\x40", 1)
    _pin_bytes(ck, b, "objects.slots_80", CREATE_SPECIAL, b"\x83\xff\x50", 1)
    # The refresh's per-state rotation increments (docs/42 §9.1).
    _pin_bytes(ck, b, "objects.array_of_80", VIEW_REFRESH, b"\xbb\x50\x00\x00\x00", 1)
    _pin_bytes(ck, b, "objects.state_2_turns_51", VIEW_REFRESH, b"\x66\x83\x06\x33", 1, at_least=True)
    arms = (VIEW_REFRESH[0], 0x00407400)
    _pin_bytes(ck, b, "objects.state_3_turns_25", arms, b"\x66\x83\x06\x19", 1)
    _pin_bytes(ck, b, "objects.state_3_turns_102", arms, b"\x66\x83\x06\x66", 1)
    # State 3 is the shield (docs/23 §7.1): `0x0042FB90` creates `A_SHILD.3DI`
    # with state 3 and subtype from the cell's `+0x0E`, which it sets to 2
    # first -- so a shield turns by 51 a frame.  Two callers: the object
    # seeding for a cell marked 3 and the fight routine's weapon-43 arm.
    _pin_calls(ck, b, "objects.shield_placer", SHIELD_PLACER, A_CREATE_SPECIAL, 1)
    _pin_at(ck, b, "objects.shield_state_3", 0x0042FC63, _push8(3))
    _pin_bytes(ck, b, "objects.shield_subtype_2", SHIELD_PLACER, b"\xc6\x45\x0e\x02", 1)
    _pin_bytes(ck, b, "objects.shield_model", SHIELD_PLACER, struct.pack("<I", 0x004C2D14), 1)
    _pin_calls(ck, b, "objects.shield_from_seeding", OBJECT_SEEDING, A_SHIELD_PLACER, 1)
    _pin_calls(ck, b, "objects.shield_from_fight", FIGHT, A_SHIELD_PLACER, 1)
    _pin_bytes(ck, b, "objects.seeding_cases_1_2_3", OBJECT_SEEDING, b"\x48\x74\x38\x48\x74\x1f\x48\x75\x4e", 1)
    # The call-site counts docs/42 quotes, over the whole text section.
    for name, va, n in (("flight", A_FLIGHT, 45), ("set_camera", A_SET_CAMERA, 43),
                        ("unit_camera", A_UNIT_CAMERA, 11), ("frame_tick", A_FRAME, 70)):
        sites = b.calls(TEXT, va)
        ck.check(f"call_sites.{name}_{n}", len(sites) == n, str(len(sites)))
    _pin_bytes(ck, b, "objects.random_heading_range_4096_x2", VIEW_REFRESH,
               _push32(0x1000) + _push8(0), 2)
    _pin_calls(ck, b, "objects.random_headings", VIEW_REFRESH, A_RANDOM2, 2)


def _check_corpus(ck: Checker, root: str) -> None:
    """The two corpus facts docs/42 §1.2 and §6.1 lean on."""
    import glob
    from inclib import charisma, lev
    # §1.2 -- the length is the first movement's last key time, and in every
    # shipped clip every movement ends at the same time, so it is the clip's.
    paths = sorted(glob.glob(os.path.join(root, "CHData", "Animations", "*.cha")))
    with_movements = 0
    uneven: list[str] = []
    for path in paths:
        clip = charisma.parse_animation_file(path)
        if not clip.movements:
            continue
        with_movements += 1
        ends = {movement.keys[-1].time for movement in clip.movements}
        if len(ends) != 1 or clip.movements[0].keys[-1].time != max(ends):
            uneven.append(clip.name)
    ck.check("corpus.cha_files_113", len(paths) == 113, str(len(paths)))
    ck.check("corpus.cha_with_movements_112", with_movements == 112, str(with_movements))
    ck.check("corpus.every_movement_ends_together", with_movements > 0 and not uneven,
             str(uneven[:5]))
    # §6.1 -- the one shipped use of the starter's type argument works only
    # because _C_118's unit 0 is the boss it asks for.
    boss = lev.load_lev(os.path.join(root, "Missions", "_C_118.lev"))
    ck.check("corpus.C118_unit_0_is_type_61",
             bool(boss.units) and boss.units[0].type_id == 0x3D,
             str(boss.units[0].type_id if boss.units else None))


def run_check(root: str) -> Checker:
    ck = Checker()
    path = os.path.join(root, GAME_EXE)
    if not os.path.isfile(path):
        ck.check("binary.present", False, f"{path} not found")
        return ck
    b = Binary(path)
    ck.check("binary.present", True)
    _check_camera(ck, b)
    _check_walk(ck, b)
    _check_clocks(ck, b)
    _check_fight(ck, b)
    _check_others(ck, b)
    _check_corpus(ck, root)
    return ck


def document(root: str) -> dict:
    b = Binary(os.path.join(root, GAME_EXE))
    table = [b.u32(0x00452E80 + 4 * i) for i in range(4)]
    return {
        "schema": "presentation-tables/1",
        "flight": {"snap_units": 0x7D00, "fast_threshold": 500, "stop_threshold": 30,
                   "fast_divisor": 3, "slow_divisor": 6},
        "unit_camera": {"quadrant_arms": [f"0x{t:08X}" for t in table],
                        "axis_extra": 3200, "target_up": 1600, "near": 9600,
                        "free_position_tries": 70, "free_position_step": 51},
        "speeds": {"walk": 2.0, "fight": 6.0, "idle": 1.5, "m2": 1.0},
        "idle_slots": [1, 2, 4, 5],
        "orbit_frames": 40,
        "arrived_flag_kinds": sorted(ARRIVED_KINDS),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", metavar="ROOT")
    ap.add_argument("--json", metavar="ROOT")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s")
    if args.json:
        json.dump(document(args.json), sys.stdout, indent=1)
        sys.stdout.write("\n")
        return 0
    if not args.check:
        ap.error("--check ROOT or --json ROOT")
    try:
        ck = run_check(args.check)
    except PEError as exc:
        LOG.error("%s", exc)
        return 1
    for line in ck.lines:
        if line.startswith("FAIL") or args.verbose:
            print(line)
    total = ck.passed + len(ck.failed)
    print(f"presentation_tables: {ck.passed}/{total} checks passed")
    return 0 if ck.failed == [] and ck.passed > 0 else 1


if __name__ == "__main__":
    sys.exit(main())

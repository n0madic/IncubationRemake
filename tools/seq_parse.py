#!/usr/bin/env python3
"""Inventory and verify Incubation's hard-coded sequence-player manifest.

The game has no sequence-description file.  ``aSetSeqPlayerVideoPart`` at
0x00465CC0 selects one of the entries below, constructs the model/animation
filenames, and hands the resulting list to the Charisma/3D runtime.  See
``docs/41-sequence-player.md``.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cha_parse  # noqa: E402
from inclib.pe import PEFile  # noqa: E402

# Every arm of aSetSeqPlayerVideoPart ends by loading its camera/rate string
# into edi and jumping here; the tail copies the actor list, installs the
# camera and increments the part counter.  The last arm falls through instead.
TAIL = 0x00467DD5

# The zero-initialised global the Seq_5 arm loads as its camera.  It sits past
# .data's raw bytes, so it is an empty string at load time -- and it is the very
# sentinel the tail compares the installed camera against, which is why Seq_5 is
# the one part that does not raise newPart.
EMPTY_STRING = 0x004FA524
EMPTY_STRING_COMPARE = 0x00467E94


@dataclass(frozen=True)
class Arm:
    """Where ``aSetSeqPlayerVideoPart`` builds one video part.

    ``model_pushes`` and ``animation_pushes`` are ``(push va, string va, text)``:
    one entry for an arm that formats ``%d`` in a loop, one per stem for an arm
    the compiler unrolled.  ``camera_mov`` is the ``mov edi, <string>`` that
    closes the arm.  The camera therefore belongs to the arm *preceding* it,
    which is what the ``contiguous`` check proves: no other arm's jump to
    ``TAIL`` lies between the arm's first push and its camera load.
    ``count_cmp`` is the ``cmp reg, imm8`` that closes a looping arm; unrolled
    arms have none and are pinned by their per-stem pushes instead.
    """

    model_pushes: tuple[tuple[int, int, str], ...]
    animation_pushes: tuple[tuple[int, int, str], ...]
    camera_mov: int
    camera_string: int
    count_cmp: int | None = None


@dataclass(frozen=True)
class Part:
    directory: str
    stems: tuple[str, ...]
    camera: str
    arm: Arm

    def model(self, stem: str) -> str:
        if self.directory == "Dialog_09":
            return "Model_D09.cho"
        return f"Model_{stem}.cho"

    def animation(self, stem: str) -> str:
        return f"Animation_{stem}.cha"


def numbered(prefix: str, first: int, last: int) -> tuple[str, ...]:
    return tuple(f"{prefix}_{i}" for i in range(first, last + 1))


# Logical id passed to aCreateSeqPlayer -> successive video parts.  IDs not
# present here are rejected by the executable's compressed 0..15 switch.
SEQUENCES: dict[int, tuple[Part, ...]] = {
    0: (
        Part("Seq_1", numbered("1", 1, 15), "9,30", Arm(
            ((0x00465D8A, 0x004CBFF8, "%sSeq_1\\Model_1_%d.cho"),),
            ((0x00465DB8, 0x004CBFD0, "%sSeq_1\\Animation_1_%d.cha"),),
            0x00465E68, 0x004CBFB8, 0x00465E5B)),
        Part("Seq_3", numbered("3", 1, 34), "10,30", Arm(
            ((0x00465F58, 0x004CBF68, "%sSeq_3\\Model_3_%d.cho"),),
            ((0x00465F86, 0x004CBF40, "%sSeq_3\\Animation_3_%d.cha"),),
            0x004660BC, 0x004CBF28, 0x00466029)),
        Part("Seq_4", ("4_0", "4_1", "4_3", "4_4"), "11,30", Arm(
            ((0x004661A0, 0x004CBED8, "%sSeq_4\\Model_4_0.cho"),
             (0x0046627F, 0x004CBE88, "%sSeq_4\\Model_4_1.cho"),
             (0x0046639B, 0x004CBE38, "%sSeq_4\\Model_4_3.cho"),
             (0x00466476, 0x004CBDE8, "%sSeq_4\\Model_4_4.cho")),
            ((0x004661CC, 0x004CBEB0, "%sSeq_4\\Animation_4_0.cha"),
             (0x004662AB, 0x004CBE60, "%sSeq_4\\Animation_4_1.cha"),
             (0x004663C7, 0x004CBE10, "%sSeq_4\\Animation_4_3.cha"),
             (0x004664A2, 0x004CBDC0, "%sSeq_4\\Animation_4_4.cha")),
            0x004665FC, 0x004CBDA8)),
        Part("Seq_5", ("5_0", "5_1", "5_2", "5_3", "5_7", "5_9", "5_10"), "", Arm(
            ((0x004666E0, 0x004CBD58, "%sSeq_5\\Model_5_0.cho"),
             (0x00466804, 0x004CBD08, "%sSeq_5\\Model_5_1.cho"),
             (0x00466922, 0x004CBCB8, "%sSeq_5\\Model_5_2.cho"),
             (0x00466A40, 0x004CBC68, "%sSeq_5\\Model_5_3.cho"),
             (0x00466B1B, 0x004CBC18, "%sSeq_5\\Model_5_7.cho"),
             (0x00466C39, 0x004CBBC8, "%sSeq_5\\Model_5_9.cho"),
             (0x00466D14, 0x004CBB78, "%sSeq_5\\Model_5_10.cho")),
            ((0x0046670C, 0x004CBD30, "%sSeq_5\\Animation_5_0.cha"),
             (0x00466830, 0x004CBCE0, "%sSeq_5\\Animation_5_1.cha"),
             (0x0046694E, 0x004CBC90, "%sSeq_5\\Animation_5_2.cha"),
             (0x00466A6C, 0x004CBC40, "%sSeq_5\\Animation_5_3.cha"),
             (0x00466B47, 0x004CBBF0, "%sSeq_5\\Animation_5_7.cha"),
             (0x00466C65, 0x004CBBA0, "%sSeq_5\\Animation_5_9.cha"),
             (0x00466D40, 0x004CBB50, "%sSeq_5\\Animation_5_10.cha")),
            0x00466E9A, EMPTY_STRING)),
    ),
    1: (Part("Extro", numbered("Extro", 1, 8), "19,30", Arm(
        ((0x00467CB3, 0x004CB7BC, "%sExtro\\Model_Extro_%d.cho"),),
        ((0x00467CE1, 0x004CB78C, "%sExtro\\Animation_Extro_%d.cha"),),
        0x00467DD0, 0x004CB770, 0x00467DC3)),),
    2: (Part("Dialog_02", ("D02",), "12,30", Arm(
        ((0x00466F5B, 0x004CBB24, "%sDialog_02\\Model_D02.cho"),),
        ((0x00466F87, 0x004CBAF8, "%sDialog_02\\Animation_D02.cha"),),
        0x00467065, 0x004CBAE0)),),
    3: (Part("Dialog_03", numbered("D03", 1, 9), "13,30", Arm(
        ((0x004670D6, 0x004CBABC, "Video\\Dialog_03\\Model_D03_%d.cho"),),
        ((0x004670F9, 0x004CBA84, "Video\\Dialog_03\\Animation_D03_%d.cha"),),
        0x004671E8, 0x004CBA68, 0x004671DB)),),
    7: (
        Part("Dialog_07", ("D07",), "14,30", Arm(
            ((0x0046757F, 0x004CB9A0, "%sDialog_07\\Model_D07.cho"),),
            ((0x004675AB, 0x004CB974, "%sDialog_07\\Animation_D07.cha"),),
            0x00467689, 0x004CB95C)),
        Part("Dialog_09", numbered("D09", 1, 18), "15,30", Arm(
            ((0x0046732E, 0x004CBA08, "%sDialog_09\\Model_D09.cho"),),
            ((0x00467388, 0x004CB9D8, "%sDialog_09\\Animation_D09_%d.cha"),),
            0x0046755D, 0x004CB9BC, 0x00467448)),
    ),
    14: (Part("Dialog_14", ("D14",), "16,30", Arm(
        ((0x004676FF, 0x004CB940, "%sDialog_14\\Model_D14.cho"),),
        ((0x0046772B, 0x004CB914, "%sDialog_14\\Animation_D14.cha"),),
        0x00467809, 0x004CB8FC)),),
    15: (
        Part("Dialog_15", numbered("D15", 1, 11), "17,30", Arm(
            ((0x00467B1A, 0x004CB828, "%sDialog_15\\Model_D15_%d.cho"),),
            ((0x00467B48, 0x004CB7F4, "%sDialog_15\\Animation_D15_%d.cha"),),
            0x00467C37, 0x004CB7D8, 0x00467C2A)),
        Part("Dialog_16", numbered("D16", 1, 21), "18,30", Arm(
            ((0x0046794F, 0x004CB898, "%sDialog_16\\Model_D16_%d.cho"),),
            ((0x0046797D, 0x004CB864, "%sDialog_16\\Animation_D16_%d.cha"),),
            0x00467AF2, 0x004CB848, 0x00467A5F)),
    ),
}

EXPECTED_IDS = (0, 1, 2, 3, 7, 14, 15)
EXPECTED_DIRS = {
    "Dialog_02", "Dialog_03", "Dialog_07", "Dialog_09", "Dialog_14",
    "Dialog_15", "Dialog_16", "Extro", "Seq_1", "Seq_3", "Seq_4", "Seq_5",
}

# The per-directory resource roots the arms hand to aInit3DEnginePure when a
# part changes directory.
RESOURCE_STRINGS = {
    0x004CBFA4: "%sSeq_3\\Objects\\",
    0x004CBF90: "%sSeq_3\\Textures\\",
    0x004CBF80: "%sSeq_3\\Img\\",
    0x004CB8E4: "%sDialog_16\\Objects\\",
    0x004CBA50: "%sDialog_09\\Objects\\",
}


class Checks:
    def __init__(self) -> None:
        self.total = 0
        self.failures: list[str] = []

    def check(self, name: str, condition: bool, detail: str) -> None:
        self.total += 1
        if not condition:
            self.failures.append(f"{name}: {detail}")


def parts() -> list[Part]:
    return [part for chain in SEQUENCES.values() for part in chain]


def push_ok(pe: PEFile, push_va: int, string_va: int, text: str) -> bool:
    """The instruction at ``push_va`` pushes exactly ``text``'s address."""
    return (pe.bytes_at(push_va, 5) == b"\x68" + struct.pack("<I", string_va)
            and pe.cstring(string_va) == text)


def jumps_to_tail(pe: PEFile, lo: int, hi: int) -> bool:
    """Is there a ``jmp TAIL`` — an arm boundary — in ``[lo, hi)``?"""
    window = pe.bytes_at(lo, hi - lo)
    for offset in range(len(window) - 4):
        if window[offset] != 0xE9:
            continue
        rel = struct.unpack_from("<i", window, offset + 1)[0]
        if lo + offset + 5 + rel == TAIL:
            return True
    return False


def check_arms(pe: PEFile, ck: Checks) -> None:
    """Pin every arm to its directory, its stems, its camera and its bound.

    This is the check the manifest actually rests on: the file-existence check
    below would pass for any table derived by listing ``Video/``, and pinning
    the camera strings alone would not notice two of them being swapped.
    """
    for part in parts():
        arm, tag = part.arm, part.directory
        pushes = arm.model_pushes + arm.animation_pushes
        ck.check(f"arm.{tag}.strings",
                 all(push_ok(pe, *push) for push in pushes),
                 "a model/animation template is not pushed where expected")
        ck.check(f"arm.{tag}.unrolled",
                 (len(arm.model_pushes) == len(arm.animation_pushes)
                  and len(arm.model_pushes) in (1, len(part.stems))),
                 f"{len(arm.model_pushes)} pushes for {len(part.stems)} stems")

        camera = ("" if arm.camera_string == EMPTY_STRING
                  else pe.cstring(arm.camera_string))
        ck.check(f"arm.{tag}.camera",
                 (pe.bytes_at(arm.camera_mov, 5)
                  == b"\xbf" + struct.pack("<I", arm.camera_string)
                  and camera == part.camera),
                 f"camera at 0x{arm.camera_mov:08X} is {camera!r}, "
                 f"not {part.camera!r}")

        first_push = min(va for va, _, _ in pushes)
        ck.check(f"arm.{tag}.contiguous",
                 (first_push < arm.camera_mov
                  and not jumps_to_tail(pe, first_push, arm.camera_mov)),
                 "another arm ends between this arm's pushes and its camera")

        if arm.count_cmp is None:
            continue
        cmp_bytes = pe.bytes_at(arm.count_cmp, 3)
        last = int(part.stems[-1].rsplit("_", 1)[1])
        ck.check(f"arm.{tag}.bound",
                 cmp_bytes[0] == 0x83 and cmp_bytes[2] == last,
                 f"loop bound at 0x{arm.count_cmp:08X} is {cmp_bytes.hex()}, "
                 f"not cmp reg, {last}")


def selected_files(video: Path) -> tuple[list[Path], list[Path]]:
    models: list[Path] = []
    animations: list[Path] = []
    for part in parts():
        base = video / part.directory
        models.extend(base / part.model(stem) for stem in part.stems)
        animations.extend(base / part.animation(stem) for stem in part.stems)
    return models, animations


def run_check(root: Path) -> int:
    ck = Checks()
    exe = root / "Incubation.exe"
    video = root / "Video"
    ck.check("corpus.exe", exe.is_file(), f"missing {exe}")
    ck.check("corpus.video", video.is_dir(), f"missing {video}")
    if not exe.is_file() or not video.is_dir():
        for failure in ck.failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1

    pe = PEFile(exe)
    ck.check("dispatch.ids", tuple(SEQUENCES) == EXPECTED_IDS,
             f"logical ids are {tuple(SEQUENCES)}")
    ck.check("dispatch.create_map",
             tuple(pe.bytes_at(0x0046588C, 16)) ==
             (0, 1, 2, 3, 7, 7, 7, 4, 7, 7, 7, 7, 7, 7, 5, 6),
             "aCreateSeqPlayer's compressed switch changed")
    ck.check("dispatch.part_map",
             pe.bytes_at(0x00467FC4, 16) == pe.bytes_at(0x0046588C, 16),
             "create and video-part switches no longer agree")
    ck.check("manifest.pe_strings",
             all(pe.cstring(va) == value for va, value in RESOURCE_STRINGS.items()),
             "one or more hard-coded resource roots changed")
    ck.check("camera.empty",
             pe.bytes_at(EMPTY_STRING_COMPARE, 5)
             == b"\xbe" + struct.pack("<I", EMPTY_STRING),
             "the tail no longer compares the camera against the global Seq_5 loads")
    ck.check("camera.distinct",
             len({part.arm.camera_string for part in parts()}) == len(parts()),
             "two parts share one camera string address")
    check_arms(pe, ck)
    ck.check("lifecycle.create", pe.bytes_at(0x0046546E, 20).startswith(
             b"\xc7\x05\x70\x42\x51\x00\x01\x00\x00\x00"),
             "active flag is not set at creation")
    ck.check("lifecycle.start", pe.bytes_at(0x00465BC0, 20).startswith(
             b"\xc7\x05\x74\x42\x51\x00\x01\x00\x00\x00"),
             "running flag is not set at start")
    ck.check("lifecycle.destroy",
             pe.bytes_at(0x00465C6F, 20).startswith(
                 b"\xc7\x05\x74\x42\x51\x00\x00\x00\x00\x00\xc7\x05\x70\x42\x51\x00"),
             "destroy no longer clears running then active")
    ck.check("lifecycle.advance", pe.bytes_at(0x00467E8F, 16).endswith(
             b"\x40\xa3\x80\x42\x51\x00"),
             "video-part counter is not incremented")
    ck.check("timing.tick", pe.u32(0x0046592C) == 0x00525588,
             "update no longer imports GetTickCount through the expected IAT slot")
    ck.check("timing.scale", pe.u32(0x0046596E) == 0x004B157C,
             "elapsed milliseconds no longer use the seconds scale constant")
    ck.check("audio.extro", pe.cstring(0x004CA91C) == "%sextro.wav",
             "the separate extro soundtrack path changed")

    dirs = {p.name for p in video.iterdir() if p.is_dir()}
    ck.check("corpus.directories", dirs == EXPECTED_DIRS,
             f"directories: {sorted(dirs)}")
    models, animations = selected_files(video)
    missing = [str(p.relative_to(root)) for p in models + animations if not p.is_file()]
    ck.check("manifest.files", not missing, f"missing selected files: {missing}")
    ck.check("manifest.actors", len(models) == 130 and len(animations) == 130,
             f"selected {len(models)} models and {len(animations)} animations")

    parsed = 0
    parse_errors: list[str] = []
    for path in animations:
        try:
            cha_parse.parse(str(path))
            parsed += 1
        except Exception as exc:  # parser supplies a path and byte offset
            parse_errors.append(f"{path}: {exc}")
    ck.check("manifest.parse", parsed == len(animations),
             f"parsed {parsed}/{len(animations)}; {parse_errors[:3]}")

    selected = {p.resolve() for p in models + animations}
    all_scene = {p.resolve() for p in video.glob("*/*")
                 if p.suffix.lower() in {".cho", ".cha"}}
    video_real = video.resolve()
    ignored = sorted("Video/" + str(p.relative_to(video_real))
                     for p in all_scene - selected)
    ck.check("manifest.unselected",
             ignored == [
                 "Video/Dialog_16/Model_D16_01.cho",
                 "Video/Dialog_16/Model_D16_02.cho",
                 "Video/Dialog_16/Model_D16_03.cho",
                 "Video/Dialog_16/Model_D16_04.cho",
                 "Video/Dialog_16/Model_D16_05.cho",
                 "Video/Dialog_16/Model_D16_06.cho",
                 "Video/Dialog_16/Model_D16_07.cho",
                 "Video/Dialog_16/Model_D16_08.cho",
                 "Video/Dialog_16/Model_D16_09.cho",
                 "Video/Seq_3/Animaton_3_6.cha",
                 "Video/Seq_3/Animmation_3_18.cha",
             ], f"unselected files: {ignored}")

    if ck.failures:
        for failure in ck.failures:
            print(f"FAIL {failure}", file=sys.stderr)
        print(f"sequence player: {ck.total} checks, {len(ck.failures)} failed")
        return 1
    print(f"sequence player: {ck.total}/{ck.total} checks passed; "
          f"12/12 directories, {parsed}/{len(animations)} animations parsed")
    return 0


def report(root: Path, as_json: bool) -> int:
    video = root / "Video"
    out = []
    for logical_id, chain in SEQUENCES.items():
        out.append({
            "id": logical_id,
            "parts": [{
                "directory": part.directory,
                "camera": part.camera,
                "actors": list(part.stems),
            } for part in chain],
        })
    if as_json:
        print(json.dumps({"root": str(root), "sequences": out}, indent=2))
    else:
        for seq in out:
            print(f"id {seq['id']}")
            for index, part in enumerate(seq["parts"]):
                print(f"  part {index}: {part['directory']:<10} camera={part['camera'] or '-':<5} "
                      f"actors={len(part['actors'])}")
    return 0 if video.is_dir() else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", type=Path)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    return run_check(args.root) if args.check else report(args.root, args.json)


if __name__ == "__main__":
    raise SystemExit(main())

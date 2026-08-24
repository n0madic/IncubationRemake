#!/usr/bin/env python3
"""Exercise the Charisma reader paths that the shipped corpus never uses.

`cho_parse.py --check` and `cha_parse.py --check` prove the parsers against the
482 files Blue Byte shipped, but four branches of the engine's own `Load`
methods have no data behind them:

* `SkeletonDesc` version 0 - one `LoadStorableObject` per node instead of a
  hoisted class name (0x0048471d);
* `KeyFramedMovementDesc` version 0 - one `LoadStorableObject` per key
  (0x004a26d5);
* `StdMovementDesc` attribute pairs - `u32 count` + `count x {lpstring,
  lpstring}` (0x0049b4e7);
* `StdComponentDesc` children - `childCount x LoadStorableObject()`, each
  required to dynamic-cast to `IComponentDesc` (0x0049a9c4 / 0x0049aabf).

This script synthesises byte streams that take those branches, parses them and
checks the result, so the code that implements them is not merely written but
run.  It writes nothing outside a temporary directory.

Usage::

    python3 tools/charisma_selftest.py
"""

from __future__ import annotations

import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cha_parse  # noqa: E402
import cho_parse  # noqa: E402


# --------------------------------------------------------------------------
# Stream builders - the mirror image of the readers
# --------------------------------------------------------------------------

def u16(v: int) -> bytes:
    return struct.pack("<H", v)


def u32(v: int) -> bytes:
    return struct.pack("<I", v)


def f32(v: float) -> bytes:
    return struct.pack("<f", v)


def lps(s: str) -> bytes:
    raw = s.encode("cp1252")
    return u32(len(raw)) + raw


def component(cls: str, name: str, kind: int, children: bytes = b"",
              child_count: int = 0) -> bytes:
    """StdComponentDesc tail (0x0049a9c4)."""
    return u16(0) + lps(cls) + lps(name) + u16(kind) + u32(child_count) + children


def skeleton_node_body(name: str, parent: str) -> bytes:
    matrix = [1.0, 0.0, 0.0, 0.0,
              0.0, 1.0, 0.0, 0.0,
              0.0, 0.0, 1.0, 0.0,
              0.0, 0.0, 0.0, 1.0]
    return u16(0) + lps(name) + lps(parent) + b"".join(f32(v) for v in matrix)


def skeleton_v0(nodes: list[tuple[str, str]]) -> bytes:
    """SkeletonDesc version 0: a class-name record per node."""
    out = lps("SkeletonDesc") + u16(0) + u32(len(nodes))
    for name, parent in nodes:
        out += lps("SkeletonNode") + skeleton_node_body(name, parent)
    return out


def skeleton_v1(nodes: list[tuple[str, str]]) -> bytes:
    """SkeletonDesc version 1: the class name is hoisted out of the loop."""
    out = lps("SkeletonDesc") + u16(1) + u32(len(nodes))
    if nodes:
        out += lps("SkeletonNode")
    for name, parent in nodes:
        out += skeleton_node_body(name, parent)
    return out


def rotation_key(t: float, q: tuple[float, float, float, float]) -> bytes:
    return u16(0) + f32(t) + b"".join(f32(v) for v in q)


def movement_v0_base0(target: str, attributes: list[tuple[str, str]]) -> bytes:
    """LinearRotationMovementDesc v0 over KeyFramedMovementDesc v0.

    Version 0 of the base class spells the key class out per key and is
    followed by a per-track note list; version 0 of the derived class writes no
    keys of its own.  Also carries StdMovementDesc attribute pairs.
    """
    # Four distinct components, so any permutation of the tuple -- a reversal,
    # a w-first rotation -- changes the parsed value. Symmetric quaternions
    # like (0,0,0,1) let a component-order bug through unnoticed, which is
    # exactly the blind spot this file exists to close.
    keys = [(0.0, (0.125, 0.25, 0.5, 0.8125)),
            (30.0, (-0.375, 0.0625, -0.75, 0.5))]
    out = lps("LinearRotationMovementDesc") + u16(0)
    out += u16(0) + u32(len(keys))                      # KeyFramedMovementDesc v0
    for t, q in keys:
        out += lps("LinearRotationKey") + rotation_key(t, q)
    out += u32(1) + f32(12.0) + lps("BREAK")            # per-track note list
    out += u16(0) + u32(100) + lps(target) + lps("Rotation matrix")
    out += u32(len(attributes))
    for k, v in attributes:
        out += lps(k) + lps(v)
    out += component("LinearRotationMovement", f"{target}.Rotation matrix", 3)
    return out


def cha_with_child(target: str) -> bytes:
    """A .cha whose animation component carries one nested movement child."""
    child = lps("LinearVectorMovementDesc") + u16(1)
    child += u32(1) + lps("LinearVectorKey")
    child += u16(0) + f32(0.0) + f32(1.0) + f32(2.0) + f32(3.0)
    child += u16(3)                                     # KeyFramedMovementDesc v3
    child += u16(0) + u32(100) + lps(target) + lps("Position") + u32(0)
    child += component("LinearVectorMovement", f"{target}.Position", 3)

    out = u32(1) + lps("KeyFramedAnimationDesc") + u16(1)
    out += u32(0)                                       # no animation notes
    out += u16(0) + u32(1)                              # StdAnimationDesc, 1 movement
    out += movement_v0_base0(target, [("author", "selftest"), ("unit", "frames")])
    out += u16(1) + skeleton_v0([(target, "ROOT")])
    out += component("KeyFramedAnimation", "SelfTest", 2,
                     children=child, child_count=1)
    return out


def cho_with_child() -> bytes:
    """A .cho whose model component carries one nested V100PartDesc child."""
    child = lps("V100PartDesc") + u16(0) + lps("CHILD_MESH")
    child += component("V100Part", "ChildPart", 1)

    out = u32(1) + lps("V100ModelDesc") + u16(0) + u16(0)
    out += u32(1)
    out += lps("V100PartDesc") + u16(0) + lps("ROOT_MESH")
    out += component("V100Part", "Root", 1)
    out += u16(1) + skeleton_v1([("Root", "ROOT")])
    out += component("V100Model", "SelfTestModel", 0,
                     children=child, child_count=1)
    return out


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

def check(condition: bool, what: str) -> None:
    if not condition:
        raise AssertionError(what)
    print(f"  ok  {what}")


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory(prefix="charisma_selftest_") as tmp:
        cha_path = os.path.join(tmp, "SelfTest.cha")
        cho_path = os.path.join(tmp, "SelfTest.cho")
        with open(cha_path, "wb") as fh:
            fh.write(cha_with_child("Bip000"))
        with open(cho_path, "wb") as fh:
            fh.write(cho_with_child())

        try:
            print("cha: KeyFramedMovementDesc v0 + attributes + SkeletonDesc v0 "
                  "+ nested child")
            anim = cha_parse.parse(cha_path)
            mov = anim.movements[0]
            check(mov.desc_version == 0 and mov.base_version == 0,
                  "movement versions (0, 0) round-trip")
            check(mov.key_class == "LinearRotationKey" and len(mov.keys) == 2,
                  "two polymorphic keys read, class per key")
            # Assert the decoded numbers, not just the shapes. Structure-only
            # checks pass unchanged when the components are permuted or a time
            # is read with the wrong type, which leaves the component-order
            # claim in docs/40 resting on a test that cannot falsify it.
            check([k.time for k in mov.keys] == [0.0, 30.0],
                  "key time stamps decode as f32 in file order")
            check(mov.keys[0].values == (0.125, 0.25, 0.5, 0.8125)
                  and mov.keys[1].values == (-0.375, 0.0625, -0.75, 0.5),
                  "key components decode in file order, sign and all")
            check([n.text for n in mov.track_notes] == ["BREAK"],
                  "per-track note list read")
            check([n.time for n in mov.track_notes] == [12.0],
                  "note time decodes as f32, not as a u32 bit pattern")
            check(mov.attributes == [("author", "selftest"), ("unit", "frames")],
                  "StdMovementDesc attribute pairs read")
            check(anim.skeleton is not None and len(anim.skeleton.nodes) == 1,
                  "SkeletonDesc version 0 read")
            check(anim.component.child_count == 1
                  and anim.component.children[0].desc_class
                  == "LinearVectorMovementDesc",
                  "nested IComponentDesc child parsed, not rejected")

            print("cho: nested V100PartDesc child")
            model = cho_parse.parse(cho_path)
            check(model.component.child_count == 1
                  and model.component.children[0].component.instance_name
                  == "ChildPart",
                  "nested V100PartDesc child parsed")

            print("negative: a non-IComponentDesc child must be refused")
            bad = cha_with_child("Bip000").replace(
                lps("LinearVectorMovementDesc"), lps("SkeletonNode"), 1)
            bad_path = os.path.join(tmp, "Bad.cha")
            with open(bad_path, "wb") as fh:
                fh.write(bad)
            try:
                cha_parse.parse(bad_path)
            except Exception as exc:  # noqa: BLE001 - any parse error is fine
                check("IComponentDesc" in str(exc),
                      "SkeletonNode child rejected as not an IComponentDesc")
            else:
                raise AssertionError("SkeletonNode child was accepted")
        except AssertionError as exc:
            print(f"  FAIL {exc}")
            failures += 1

    print("selftest: FAILED" if failures else "selftest: all paths exercised")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

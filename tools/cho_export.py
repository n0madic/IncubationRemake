#!/usr/bin/env python3
"""Pose a Charisma skeleton and export it as OBJ line segments and PNG sheets.

This is the end-to-end proof that the decoded transform chain is right: it
reimplements ``V100Part::Update`` (0x004a6807) and ``StdPart::GetWorldMatrix``
(0x0049db84) in Python and draws the result.  If the quaternion component
order, the matrix layout or the parent chain were wrong, the figure would come
out collapsed, inside out or scrambled.

The pose rule, transcribed from ``V100Part::Update``::

    translation = position_track(t) if present else (0, 0, 0)
    translation += bind_matrix.translation           # 0x004828ff adds, not sets
    local        = quat_to_matrix(rotation_track(t)) if present
                   else bind_matrix with its translation column zeroed
    local.translation = translation
    world        = parent.world * local              # 0x00482ab3, M * v

Usage::

    # bind pose only
    python3 tools/cho_export.py gog_incubation/CHData/Objects/P0_000.cho

    # bind pose plus an animation, 12 sampled frames
    python3 tools/cho_export.py gog_incubation/CHData/Objects/P0_000.cho \
        --anim gog_incubation/CHData/Animations/P0_M0_000.cha --frames 12

    # regenerate the sample set under tools/out/skeletons/
    python3 tools/cho_export.py --samples gog_incubation

Outputs land in ``tools/out/skeletons/`` by default: one ``.obj`` per frame
(vertices = joints, ``l`` lines = bones) plus a contact-sheet ``.png`` drawn
in orthographic projection.

See ``docs/40-charisma-model-animation.md`` sections 5 and 6.
"""

from __future__ import annotations

import argparse
import bisect
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cha_parse  # noqa: E402
import cho_parse  # noqa: E402
from inclib.charisma import (  # noqa: E402
    HOLD_DT,
    HOLD_PICK,
    bezier_rotation_controls,
    bezier_scalar,
    mat_mul,
    mat_translation,
    mat_with_translation,
    quat_slerp,
    quat_squad,
    quat_to_matrix,
)
from inclib.png import write_rgb_png  # noqa: E402

logger = logging.getLogger("cho_export")

DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "skeletons")

# The engine treats a key interval of 0.25 frames or less as a hold and returns
# one of the two keys outright; `u <= 0.5` picks the first.  Both constants are
# shared by all five GetValue implementations - see HOLD_DT / HOLD_PICK in
# inclib/charisma.py for the addresses.  5.2 % of the corpus' 896 443 segments
# are exactly 0.25 frames long, so this threshold is not academic.
EPS = HOLD_DT

# StdModel's per-instance placement, read through its "StandardModel" interface
# (0x0049fc2d GetFlag / 0x0049fc6a GetScale).  The constructor at 0x0049ed2c
# leaves the flag 0 and the scale (1, 1, 1); nothing in the shipped .cho/.cha
# data can change them, so the exporter uses the defaults.  The owning
# animation's offset vector (0x0049c5ac) is likewise (0, 0, 0) by default.
MODEL_SCALE = (1.0, 1.0, 1.0)
ANIM_OFFSET = (0.0, 0.0, 0.0)


# --------------------------------------------------------------------------
# Track sampling - one function per interpolator, mirroring the engine
# --------------------------------------------------------------------------

def _segment(mov: cha_parse.Movement,
             t: float) -> tuple[int, cha_parse.Key, cha_parse.Key, float]:
    """Locate the key pair bracketing *t*, its index and the parameter u."""
    times = [k.time for k in mov.keys]
    i = bisect.bisect_right(times, t) - 1
    if i < 0:
        return 0, mov.keys[0], mov.keys[0], 0.0
    if i >= len(mov.keys) - 1:
        last = mov.keys[-1]
        return len(mov.keys) - 1, last, last, 1.0
    k0, k1 = mov.keys[i], mov.keys[i + 1]
    dt = k1.time - k0.time
    # The engine (0x004ac9c5 and friends) divides unconditionally and only
    # guards a zero numerator; the zero-length case cannot reach the caller
    # because the hold test below catches it first.
    u = 0.0 if dt == 0.0 else (t - k0.time) / dt
    return i, k0, k1, u


def _squad_controls(mov: cha_parse.Movement) -> list[tuple[float, ...]]:
    """Control quaternions of a BezierRotation track, derived once per track."""
    cached = getattr(mov, "_squad_controls", None)
    if cached is None:
        cached = bezier_rotation_controls([k.values for k in mov.keys])
        mov._squad_controls = cached  # noqa: SLF001 - lazy per-track cache
    return cached


def sample_rotation(mov: cha_parse.Movement, t: float) -> list[float]:
    """Rotation channel -> 4x4 matrix (0x004a9a9a linear, 0x004aca7a Bezier).

    Linear rotation slerps the two keys.  Bezier rotation carries no tangents
    in the file: the engine derives one inner control quaternion per key at
    load time (0x004ad53e -> 0x004ad7ab -> 0x004af0d1, stored twice in the key
    at +0x18 and +0x28) and evaluates Shoemake's ``squad``
    ``(q[i], s[i], s[i+1], q[i+1], u)`` at 0x004aef75.
    """
    i, k0, k1, u = _segment(mov, t)
    if k0 is k1 or k1.time - k0.time <= EPS:
        return quat_to_matrix(k0.values if u <= HOLD_PICK else k1.values)
    if mov.key_class == "BezierRotationKey":
        ctrl = _squad_controls(mov)
        return quat_to_matrix(quat_squad(k0.values, ctrl[i], ctrl[i + 1],
                                         k1.values, u))
    return quat_to_matrix(quat_slerp(k0.values, k1.values, u))


def sample_vector(mov: cha_parse.Movement, t: float) -> tuple[float, float, float]:
    """Position channel -> vec3 (0x004a8b72 linear lerp, 0x004ab918 Bezier)."""
    _, k0, k1, u = _segment(mov, t)
    if k0 is k1 or k1.time - k0.time <= EPS:
        v = k0.values if u <= HOLD_PICK else k1.values
        return (v[0], v[1], v[2])
    if mov.key_class == "LinearVectorKey":
        return tuple(k0.values[i] + (k1.values[i] - k0.values[i]) * u for i in range(3))
    dt = k1.time - k0.time
    # BezierVectorKey: [0:3] value, [3:6] in-tangent, [6:9] out-tangent.
    return tuple(
        bezier_scalar(k0.values[i], k0.values[6 + i], k1.values[i], k1.values[3 + i], dt, u)
        for i in range(3)
    )


def sample_float(mov: cha_parse.Movement, t: float) -> float:
    """Visibility channel -> scalar (0x004aa9df).  Visible when > 0."""
    _, k0, k1, u = _segment(mov, t)
    if k0 is k1 or k1.time - k0.time <= EPS:
        return (k0.values if u <= HOLD_PICK else k1.values)[0]
    if mov.key_class == "LinearFloatKey":
        return k0.values[0] + (k1.values[0] - k0.values[0]) * u
    dt = k1.time - k0.time
    # BezierFloatKey: [0] value, [1] in-tangent, [2] out-tangent.
    return bezier_scalar(k0.values[0], k0.values[2], k1.values[0], k1.values[1], dt, u)


# --------------------------------------------------------------------------
# Posing
# --------------------------------------------------------------------------

class Pose:
    """World transforms of every bone of a model at one point in time."""

    def __init__(self, model: cho_parse.Model, anim: cha_parse.Animation | None,
                 time: float) -> None:
        assert model.skeleton is not None
        self.model = model
        self.time = time
        self.nodes = model.skeleton.nodes
        self.parent_of = {n.name: n.parent for n in self.nodes}
        tracks: dict[tuple[str, str], cha_parse.Movement] = {}
        if anim is not None:
            for mov in anim.movements:
                tracks[(mov.target, mov.channel)] = mov
        self.tracks = tracks
        self.local: dict[str, list[float]] = {}
        self.world: dict[str, list[float]] = {}
        self.visible: dict[str, bool] = {}
        for node in self.nodes:
            self.local[node.name] = self._local(node)
        for node in self.nodes:
            self.world[node.name] = self._world(node.name)

    def _local(self, node) -> list[float]:
        """One bone's local matrix, exactly as V100Part::Update builds it."""
        bind_t = mat_translation(node.matrix)
        pos = self.tracks.get((node.name, "Position"))
        if pos is not None and pos.keys:
            v = sample_vector(pos, self.time)
            if self.parent_of.get(node.name) in self.parent_of:
                # Ordinary bone: the track is an offset from the bind pose
                # (0x004a68ff, ADDS).
                trans = (bind_t[0] + v[0], bind_t[1] + v[1], bind_t[2] + v[2])
            else:
                # Top-level bone (its .cho parent is the "ROOT" sentinel, so at
                # runtime its parent is the synthetic root part and that part
                # has no parent of its own): V100Part::Update takes the second
                # branch at 0x004a68d1.  The bind translation is NOT added; the
                # track value is scaled by the model's own scale vector and
                # offset by the owning animation's offset vector.  Both default
                # to (1,1,1) / (0,0,0), so with stock data the track value is
                # the local translation outright.
                trans = (v[0] * MODEL_SCALE[0] + ANIM_OFFSET[0],
                         v[1] * MODEL_SCALE[1] + ANIM_OFFSET[1],
                         v[2] * MODEL_SCALE[2] + ANIM_OFFSET[2])
        else:
            trans = bind_t

        rot = self.tracks.get((node.name, "Rotation matrix"))
        if rot is not None and rot.keys:
            local = sample_rotation(rot, self.time)
        else:
            local = mat_with_translation(node.matrix, (0.0, 0.0, 0.0))

        vis = self.tracks.get((node.name, "Visibility"))
        self.visible[node.name] = True if vis is None or not vis.keys \
            else sample_float(vis, self.time) > 0.0
        return mat_with_translation(local, trans)

    def _world(self, name: str) -> list[float]:
        if name in self.world:
            return self.world[name]
        parent = self.parent_of.get(name)
        if parent is None or parent not in self.local:
            out = list(self.local[name])
        else:
            out = mat_mul(self._world(parent), self.local[name])
        self.world[name] = out
        return out

    def is_visible(self, name: str) -> bool:
        """Whether the part's Visibility track is positive at this time.

        Parts whose track has gone to zero are switched off by the animation
        and must not be drawn. 272 of the Video sequences' tracks dip to <= 0,
        so on those models this is the difference between the pose the game
        shows and one with 18 extra limbs in it.
        """
        return self.visible.get(name, True)

    def joints(self, include_hidden: bool = False
               ) -> dict[str, tuple[float, float, float]]:
        return {n.name: mat_translation(self.world[n.name]) for n in self.nodes
                if include_hidden or self.is_visible(n.name)}

    def bones(self, include_hidden: bool = False) -> list[tuple[str, str]]:
        names = {n.name for n in self.nodes
                 if include_hidden or self.is_visible(n.name)}
        return [(n.parent, n.name) for n in self.nodes
                if n.name in names and n.parent in names]


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def write_obj(path: str, pose: Pose) -> None:
    """Write the posed skeleton as OBJ vertices plus ``l`` line segments."""
    joints = pose.joints()
    order = [n.name for n in pose.nodes if n.name in joints]
    index = {name: i + 1 for i, name in enumerate(order)}
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"# {os.path.basename(pose.model.path)} @ frame {pose.time:g}\n")
        fh.write("o skeleton\n")
        for name in order:
            x, y, z = joints[name]
            fh.write(f"v {x:.5f} {y:.5f} {z:.5f}\n")
        for name in order:
            fh.write(f"# vertex {index[name]} = {name}\n")
        for parent, child in pose.bones():
            fh.write(f"l {index[parent]} {index[child]}\n")


def _project(joints, axes: tuple[int, int]):
    ax, ay = axes
    return [(p[ax], p[ay]) for p in joints]


def write_sheet(path: str, poses: list[Pose], cell: int = 220,
                columns: int = 6) -> None:
    """Draw the poses as an orthographic contact sheet (X right, Z up)."""
    if not poses:
        return
    pts = [p for pose in poses for p in pose.joints().values()]
    xs = [p[0] for p in pts]
    zs = [p[2] for p in pts]
    minx, maxx = min(xs), max(xs)
    minz, maxz = min(zs), max(zs)
    span = max(maxx - minx, maxz - minz, 1e-3) * 1.12
    cx, cz = (minx + maxx) / 2.0, (minz + maxz) / 2.0

    rows = (len(poses) + columns - 1) // columns
    width, height = cell * min(columns, len(poses)), cell * rows
    buf = bytearray(width * height * 3)
    for i in range(0, len(buf), 3):
        buf[i:i + 3] = b"\x12\x14\x1a"

    def plot(px: int, py: int, rgb: bytes) -> None:
        if 0 <= px < width and 0 <= py < height:
            o = (py * width + px) * 3
            buf[o:o + 3] = rgb

    def line(x0, y0, x1, y1, rgb):
        steps = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
        for s in range(steps + 1):
            u = s / steps
            plot(int(round(x0 + (x1 - x0) * u)), int(round(y0 + (y1 - y0) * u)), rgb)

    for n, pose in enumerate(poses):
        ox = (n % columns) * cell
        oy = (n // columns) * cell
        joints = pose.joints()

        def to_px(p):
            sx = (p[0] - cx) / span + 0.5
            sz = (p[2] - cz) / span + 0.5
            return ox + sx * cell, oy + (1.0 - sz) * cell

        for parent, child in pose.bones():
            x0, y0 = to_px(joints[parent])
            x1, y1 = to_px(joints[child])
            line(x0, y0, x1, y1, b"\x7a\xc7\xff")
        for name, p in joints.items():
            x, y = to_px(p)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    plot(int(round(x)) + dx, int(round(y)) + dy, b"\xff\xd0\x60")
    write_rgb_png(path, width, height, bytes(buf))


# --------------------------------------------------------------------------
# Driver
# --------------------------------------------------------------------------

def export(model_path: str, anim_path: str | None, frames: int, out_dir: str,
           tag: str | None = None) -> list[str]:
    """Export one model (optionally posed by one animation) and return paths."""
    os.makedirs(out_dir, exist_ok=True)
    model = cho_parse.parse(model_path)
    anim = cha_parse.parse(anim_path) if anim_path else None
    name = tag or os.path.splitext(os.path.basename(model_path))[0]
    if anim is not None:
        name = f"{name}__{os.path.splitext(os.path.basename(anim_path))[0]}"

    if anim is None or anim.duration <= 0.0:
        times = [0.0]
    else:
        times = [anim.duration * i / (frames - 1) for i in range(frames)] \
            if frames > 1 else [0.0]

    poses = [Pose(model, anim, t) for t in times]
    written: list[str] = []
    for i, pose in enumerate(poses):
        obj = os.path.join(out_dir, f"{name}_{i:03d}.obj")
        write_obj(obj, pose)
        written.append(obj)
    png = os.path.join(out_dir, f"{name}.png")
    write_sheet(png, poses)
    written.append(png)
    return written


SAMPLES = [
    ("CHData/Objects/P0_000.cho", None, 1),
    ("CHData/Objects/P0_000.cho", "CHData/Animations/P0_M0_000.cha", 12),
    ("CHData/Objects/P0_000.cho", "CHData/Animations/P0_F0_000.cha", 12),
    ("CHData/Objects/PC_000.cho", "CHData/Animations/PC_F0_000.cha", 12),
]


def run_samples(root: str, out_dir: str) -> int:
    made = 0
    for model_rel, anim_rel, frames in SAMPLES:
        model = os.path.join(root, model_rel)
        anim = os.path.join(root, anim_rel) if anim_rel else None
        if not os.path.exists(model) or (anim and not os.path.exists(anim)):
            logger.warning("skipping missing sample %s / %s", model_rel, anim_rel)
            continue
        for path in export(model, anim, frames, out_dir):
            print(path)
        made += 1
    return 0 if made else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("model", nargs="?", help=".cho model file")
    ap.add_argument("--anim", help=".cha animation to pose the model with")
    ap.add_argument("--frames", type=int, default=12, help="frames to sample")
    ap.add_argument("--out", default=DEFAULT_OUT, help="output directory")
    ap.add_argument("--samples", metavar="ROOT",
                    help="regenerate the documented sample set from the game root")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING,
                        format="%(levelname)s %(name)s: %(message)s")

    if args.samples:
        return run_samples(args.samples, args.out)
    if not args.model:
        ap.error("a model path or --samples is required")
    for path in export(args.model, args.anim, args.frames, args.out):
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

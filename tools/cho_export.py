#!/usr/bin/env python3
"""Pose a Charisma skeleton and export it as OBJ line segments and PNG sheets.

This is the end-to-end proof that the decoded transform chain is right: it
draws the result of ``V100Part::Update`` (0x004a6807) and
``StdPart::GetWorldMatrix`` (0x0049db84).  If the quaternion component order,
the matrix layout or the parent chain were wrong, the figure would come out
collapsed, inside out or scrambled.

The pose rule itself lives in :mod:`inclib.pose`, which is where the remake's
GDScript sampler is diffed against it; this file is the drawing half.

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
import logging
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cha_parse  # noqa: E402
import cho_parse  # noqa: E402
from inclib.pose import Pose, pose_model  # noqa: E402
from inclib.png import write_rgb_png  # noqa: E402

logger = logging.getLogger("cho_export")

DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "out", "skeletons")


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def write_obj(path: str, pose: Pose, source: str) -> None:
    """Write the posed skeleton as OBJ vertices plus ``l`` line segments."""
    joints = pose.joints()
    order = [n.name for n in pose.nodes if n.name in joints]
    index = {name: i + 1 for i, name in enumerate(order)}
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"# {os.path.basename(source)} @ frame {pose.time:g}\n")
        fh.write("o skeleton\n")
        for name in order:
            x, y, z = joints[name]
            fh.write(f"v {x:.5f} {y:.5f} {z:.5f}\n")
        for name in order:
            fh.write(f"# vertex {index[name]} = {name}\n")
        for parent, child in pose.bones():
            fh.write(f"l {index[parent]} {index[child]}\n")


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

    poses = [pose_model(model, anim, t) for t in times]
    written: list[str] = []
    for i, pose in enumerate(poses):
        obj = os.path.join(out_dir, f"{name}_{i:03d}.obj")
        write_obj(obj, pose, model_path)
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

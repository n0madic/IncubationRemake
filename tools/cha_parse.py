#!/usr/bin/env python3
"""Parser for Charisma ``.cha`` animation files (Incubation, Blue Byte 1997).

A ``.cha`` file is a serialised ``KeyFramedAnimationDesc``.  As with ``.cho``,
a record is the concatenation of the C++ inheritance chain, each level writing
its own ``u16`` schema version first::

    KeyFramedAnimationDesc::Load @ 0x004a1dde   u16 version, note list
    StdAnimationDesc::Load       @ 0x0049cba6   u16 version, movements, skeleton
    StdComponentDesc::Load       @ 0x0049a9c4   component class / instance / kind

and one movement track is::

    <Interp><Channel>MovementDesc::Load         u16 version, inline key array
    KeyFramedMovementDesc::Load  @ 0x004a26d5   u16 version, key array + notes
    StdMovementDesc::Load        @ 0x0049b4e7   weight, target, channel, attrs
    StdComponentDesc::Load       @ 0x0049a9c4   component class / instance / kind

Usage::

    python3 tools/cha_parse.py gog_incubation/CHData/Animations/P0_F0_000.cha
    python3 tools/cha_parse.py --json <file>
    python3 tools/cha_parse.py --check gog_incubation
    python3 tools/cha_parse.py --notes gog_incubation     # event vocabulary

See ``docs/40-charisma-model-animation.md`` for the byte-level specification.
"""

from __future__ import annotations

import argparse
import json
import logging
import math
import os
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.binio import Reader, read_file  # noqa: E402
from inclib.charisma import (  # noqa: E402
    parse_animation_file as parse,
    KEY_COMPONENTS,
    KEY_STRIDE,
    CharismaError,
    ComponentDesc,
    Skeleton,
    expect_eof,
    iter_corpus,
    read_component_desc,
    read_file_version,
    read_optional_skeleton,
    read_storable_name,
    read_version,
    register_desc_reader,
    run_check,
)

logger = logging.getLogger("cha_parse")


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def dump_text(anim: Animation) -> None:
    """Print a human-readable summary of one animation."""
    print(f"{anim.path}")
    print(f"  name={anim.name} stream_version={anim.stream_version} "
          f"KeyFramedAnimationDesc.version={anim.desc_version}")
    print(f"  duration={anim.duration:g} frames")
    print(f"  notes: {len(anim.notes)}")
    for note in anim.notes:
        print(f"    t={note.time:g}  {note.text}")
    print(f"  movements: {len(anim.movements)}")
    for mov in anim.movements:
        print(f"    {mov.target}.{mov.channel}  {mov.key_class} x{len(mov.keys)} "
              f"(t 0..{mov.duration:g})")
    if anim.skeleton:
        print(f"  skeleton: {len(anim.skeleton.nodes)} nodes")


def inspect(anim: Animation, stats: dict) -> None:
    """Accumulate corpus-wide consistency checks for ``--check``."""
    stats.setdefault("files", 0)
    stats["files"] += 1
    for key, value in (
        ("stream_version", anim.stream_version),
        ("KeyFramedAnimationDesc.version", anim.desc_version),
        ("StdAnimationDesc.version", anim.base_version),
        ("has_skeleton", anim.has_skeleton),
    ):
        stats.setdefault(key, Counter())[value] += 1
    assert anim.component is not None
    stats.setdefault("anim_component_class", Counter())[anim.component.component_class] += 1
    stats.setdefault("anim_component_version", Counter())[anim.component.version] += 1
    stats.setdefault("anim_kind", Counter())[anim.component.kind] += 1
    stats.setdefault("notes", 0)
    stats["notes"] += len(anim.notes)
    for note in anim.notes:
        stats.setdefault("note_text", Counter())[note.text] += 1
        if not (0.0 <= note.time <= 100000.0):
            stats.setdefault("bad_note_time", []).append(f"{anim.path}:{note.time}")

    assert anim.skeleton is not None
    node_names = {n.name for n in anim.skeleton.nodes}
    stats.setdefault("nodes", 0)
    stats["nodes"] += len(anim.skeleton.nodes)

    stats.setdefault("movements", 0)
    stats["movements"] += len(anim.movements)
    for mov in anim.movements:
        stats.setdefault("desc_class", Counter())[mov.desc_class] += 1
        stats.setdefault("key_class", Counter())[mov.key_class] += 1
        stats.setdefault("channel", Counter())[mov.channel] += 1
        stats.setdefault("mov_version", Counter())[(mov.desc_version, mov.base_version)] += 1
        stats.setdefault("weight", Counter())[mov.weight] += 1
        stats.setdefault("track_note_count", Counter())[len(mov.track_notes)] += 1
        stats.setdefault("attribute_count", Counter())[len(mov.attributes)] += 1
        stats.setdefault("mov_component_version", Counter())[mov.component.version] += 1
        stats.setdefault("mov_kind", Counter())[mov.component.kind] += 1
        stats.setdefault("key_version", Counter())
        # The component instance name is "<target>.<channel>".
        if mov.component.instance_name != f"{mov.target}.{mov.channel}":
            stats.setdefault("name_join_mismatch", []).append(
                f"{anim.path}:{mov.component.instance_name}")
        # Movement targets must exist in the embedded skeleton.
        if mov.target not in node_names:
            stats.setdefault("target_not_a_bone", Counter())[mov.target] += 1
        if mov.keys:
            stats.setdefault("tracks_with_keys", 0)
            stats["tracks_with_keys"] += 1
            if mov.keys[0].time == 0.0:
                stats.setdefault("first_key_at_zero", 0)
                stats["first_key_at_zero"] += 1
        prev = -math.inf
        for key in mov.keys:
            stats["key_version"][key.version] += 1
            if key.time < prev:
                stats.setdefault("non_monotonic_time", []).append(
                    f"{anim.path}:{mov.target}.{mov.channel}")
                break
            prev = key.time
        # Quaternion sanity for the rotation channels.
        if mov.key_class in ("LinearRotationKey", "BezierRotationKey"):
            for key in mov.keys:
                norm = math.sqrt(sum(v * v for v in key.values))
                dev = abs(norm - 1.0)
                if dev > stats.get("max_quat_norm_dev", 0.0):
                    stats["max_quat_norm_dev"] = dev
                    stats["max_quat_norm_dev_at"] = f"{anim.path}:{mov.target}"
                if dev > 1e-2:
                    stats.setdefault("non_unit_quat", []).append(
                        f"{anim.path}:{mov.target}:{norm:.6f}")
                    break
        if mov.key_class in ("LinearVectorKey", "BezierVectorKey"):
            for key in mov.keys:
                if any(abs(v) > 1e6 for v in key.values):
                    stats.setdefault("wild_position", []).append(
                        f"{anim.path}:{mov.target}")
                    break
    stats.setdefault("keys", 0)
    stats["keys"] += sum(len(m.keys) for m in anim.movements)


def report(stats: dict) -> None:
    """Print the aggregated ``--check`` statistics."""
    print()
    print("field value distributions (value: files/records)")
    for key in sorted(stats):
        value = stats[key]
        if isinstance(value, Counter):
            items = value.most_common(10)
            print(f"  {key}: " + ", ".join(f"{k!r}={v}" for k, v in items)
                  + (f" ... (+{len(value) - 10} more)" if len(value) > 10 else ""))
        elif isinstance(value, list):
            print(f"  {key}: {len(value)} problem(s)")
            for item in value[:5]:
                print(f"      {item}")
        else:
            print(f"  {key}: {value}")


def notes_report(paths: list[str]) -> None:
    """Print the note/event vocabulary found across the corpus."""
    vocab: Counter[str] = Counter()
    where: dict[str, set[str]] = defaultdict(set)
    for path in paths:
        anim = parse(path)
        for note in anim.notes:
            vocab[note.text] += 1
            where[note.text].add(os.path.basename(path))
    print(f"{len(vocab)} distinct note texts across {len(paths)} files")
    for text, count in vocab.most_common():
        files = sorted(where[text])
        sample = ", ".join(files[:3]) + (" ..." if len(files) > 3 else "")
        print(f"  {text!r}: {count} occurrence(s) in {len(files)} file(s)  [{sample}]")


def cross_check(root: str) -> int:
    """Verify that movement targets name real parts of the matching models.

    Two independent checks:

    1. every movement target must be a node of the animation's own embedded
       skeleton (this is what the runtime binds against);
    2. every movement target should also be a part of a ``.cho`` model that
       belongs to the same family - same ``P<n>``/``Model`` filename prefix
       for ``CHData/``, same directory for ``Video/``.

    Check 2 is expected to be imperfect: the exporter kept helper objects
    (``Banner``, ``Dummy01``, ``Shadow``, extra finger bones) in the animation
    that were not exported into the model.
    """
    import cho_parse  # local import: only needed for this mode

    pools: dict[str, set[str]] = defaultdict(set)

    def family(path: str) -> str:
        directory = os.path.dirname(path)
        if os.sep + "Video" + os.sep in directory + os.sep:
            return directory
        return "CHData:" + os.path.basename(path).split("_")[0]

    models = iter_corpus(root, ".cho")
    for path in models:
        pools[family(path)] |= {p.name for p in cho_parse.parse(path).parts}

    anims = iter_corpus(root, ".cha")
    total = resolved = 0
    in_skeleton = 0
    clean_files = 0
    unresolved: Counter[str] = Counter()
    for path in anims:
        anim = parse(path)
        assert anim.skeleton is not None
        nodes = {n.name for n in anim.skeleton.nodes}
        targets = {m.target for m in anim.movements}
        in_skeleton += len(targets & nodes)
        missing = targets - pools.get(family(path), set())
        total += len(targets)
        resolved += len(targets) - len(missing)
        if not missing:
            clean_files += 1
        unresolved.update(missing)

    print(f"models: {len(models)}   animations: {len(anims)}")
    print(f"distinct movement targets: {total}")
    print(f"  present in the animation's own skeleton: {in_skeleton} "
          f"({100 * in_skeleton / total:.2f}%)")
    print(f"  present in a model of the same family:   {resolved} "
          f"({100 * resolved / total:.2f}%)")
    print(f"  animations with every target resolved:   {clean_files}/{len(anims)}")
    if unresolved:
        print("  unresolved target names (helper objects not exported as parts):")
        for name, count in unresolved.most_common(20):
            print(f"      {name!r}: {count}")
    return 0 if in_skeleton == total else 1


#: Floors for `--verify-convention`, set below the values the shipped corpus
#: produces (5821 tracks, 87.82% on the documented hypothesis, 138/245 files)
#: with enough slack that they only trip on a real change of meaning.
MIN_ROTATION_TRACKS = 5000
MIN_LEADING_SHARE = 0.80
MIN_PERFECT_FILES = 120


def verify_convention(root: str) -> int:
    """Prove the quaternion component order against the bind-pose matrices.

    The engine's rotation-key-to-matrix routine (0x004827b0, reimplemented as
    :func:`inclib.charisma.quat_to_matrix`) already settles the order on its
    own: ``q[3]`` is the only component absent from all three diagonal terms,
    so it is the scalar ``w`` and the storage order is ``(x, y, z, w)``.  This
    mode is the independent data check.

    For every rotation track whose target is a bone of the animation's own
    embedded skeleton, the first key is converted under four hypotheses and
    compared (Frobenius norm over the 3x3) with that bone's bind-pose
    rotation.  Animations that start in the bind pose - most of them - must
    match under exactly one hypothesis.
    """
    from inclib.charisma import quat_to_matrix

    idx = (0, 1, 2, 4, 5, 6, 8, 9, 10)

    def rot9(m):
        return [m[i] for i in idx]

    def frob(a, b):
        return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))

    def transpose(r):
        return [r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]]

    hypotheses = {
        "(x, y, z, w) file order, engine formula": lambda q: q,
        "(x, y, z, w) transposed": lambda q: q,
        "(w, x, y, z) w first": lambda q: (q[1], q[2], q[3], q[0]),
        "(w, x, y, z) transposed": lambda q: (q[1], q[2], q[3], q[0]),
    }
    wins = dict.fromkeys(hypotheses, 0)
    paths = iter_corpus(root, ".cha")
    tracks = 0
    perfect_files = 0
    for path in paths:
        anim = parse(path)
        assert anim.skeleton is not None
        nodes = anim.skeleton.node_map()
        hits = misses = 0
        for mov in anim.movements:
            if mov.channel != "Rotation matrix" or not mov.keys:
                continue
            node = nodes.get(mov.target)
            if node is None:
                continue
            tracks += 1
            bind = rot9(node.matrix)
            matched = False
            for label, permute in hypotheses.items():
                built = rot9(quat_to_matrix(permute(mov.keys[0].values)))
                if "transposed" in label:
                    built = transpose(built)
                if frob(built, bind) < 1e-3:
                    wins[label] += 1
                    if label.startswith("(x, y, z, w) file"):
                        matched = True
            if matched:
                hits += 1
            else:
                misses += 1
        if hits and not misses:
            perfect_files += 1
    print(f"rotation tracks bound to a bone: {tracks} in {len(paths)} files")
    for label, count in wins.items():
        print(f"  {label:42s} {count:6d}  ({100 * count / tracks:6.2f}%)")
    print(f"files where every rotation track's first key equals the bind pose: "
          f"{perfect_files}/{len(paths)}")
    print("The remaining tracks are animations that simply do not start in the")
    print("bind pose; no hypothesis explains them, so they are not evidence.")

    # Gate on the result. Without this the routine printed its evidence and
    # returned 0 unconditionally, so the command CLAUDE.md lists under "a
    # non-zero exit is a regression" could not regress: reversing the
    # quaternion component order collapses the leading hypothesis from 87.82%
    # to 0.94% and this still reported success.
    leading = "(x, y, z, w) file order, engine formula"
    share = wins[leading] / tracks if tracks else 0.0
    problems = []
    if tracks < MIN_ROTATION_TRACKS:
        problems.append(f"only {tracks} rotation tracks found, expected at "
                        f"least {MIN_ROTATION_TRACKS}")
    if share < MIN_LEADING_SHARE:
        problems.append(f"the documented convention explains {100 * share:.2f}% "
                        f"of tracks, below the {100 * MIN_LEADING_SHARE:.0f}% "
                        f"floor")
    for label, count in wins.items():
        if label != leading and count > wins[leading]:
            problems.append(f"hypothesis {label!r} now outranks the documented "
                            f"one ({count} vs {wins[leading]})")
    if perfect_files < MIN_PERFECT_FILES:
        problems.append(f"only {perfect_files} files match the bind pose "
                        f"exactly, expected at least {MIN_PERFECT_FILES}")
    for line in problems:
        print(f"FAIL {line}")
    return 1 if problems else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("path", nargs="?", help=".cha file to parse")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    ap.add_argument("--check", metavar="ROOT",
                    help="parse every .cha below ROOT and report coverage")
    ap.add_argument("--notes", metavar="ROOT",
                    help="print the note/event vocabulary below ROOT")
    ap.add_argument("--cross-check", metavar="ROOT",
                    help="check movement targets against the .cho part names")
    ap.add_argument("--verify-convention", metavar="ROOT",
                    help="statistical check of the quaternion component order")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING,
                        format="%(levelname)s %(name)s: %(message)s")

    if args.verify_convention:
        return verify_convention(args.verify_convention)

    if args.cross_check:
        return cross_check(args.cross_check)

    if args.notes:
        notes_report(iter_corpus(args.notes, ".cha"))
        return 0

    if args.check:
        paths = iter_corpus(args.check, ".cha")
        stats: dict = {}
        code = run_check(paths, parse, lambda doc, _s: inspect(doc, stats))
        report(stats)
        return code

    if not args.path:
        ap.error("a path, --check or --notes is required")
    anim = parse(args.path)
    if args.json:
        json.dump(anim.to_json(), sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
    else:
        dump_text(anim)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Parser for Charisma ``.cho`` model files (Incubation, Blue Byte 1997).

A ``.cho`` file is a serialised ``V100ModelDesc``.  The record is the
concatenation of the three levels of its C++ inheritance chain, each of which
writes a ``u16`` schema version followed by its own fields::

    V100ModelDesc::Load     @ 0x004a77bd   u16 version
    StdModelDesc::Load      @ 0x004a021f   u16 version, parts, skeleton
    StdComponentDesc::Load  @ 0x0049a9c4   component class / instance / kind

Usage::

    python3 tools/cho_parse.py gog_incubation/CHData/Objects/P0_000.cho
    python3 tools/cho_parse.py --json <file>
    python3 tools/cho_parse.py --check gog_incubation

See ``docs/40-charisma-model-animation.md`` for the byte-level specification.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections import Counter
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib.binio import Reader, read_file  # noqa: E402
from inclib.charisma import (  # noqa: E402
    parse_model_file as parse,
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

logger = logging.getLogger("cho_parse")


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def dump_text(model: Model) -> None:
    """Print a human-readable summary of one model."""
    print(f"{model.path}")
    print(f"  stream_version={model.stream_version} "
          f"V100ModelDesc.version={model.desc_version} "
          f"StdModelDesc.version={model.base_version}")
    comp = model.component
    print(f"  model name: {model.name} "
          f"(component {comp.component_class if comp else '?'}, "
          f"kind={comp.kind if comp else '?'})")
    print(f"  parts: {len(model.parts)}")
    for part in model.parts:
        mesh = f"  mesh={part.mesh}" if part.mesh else ""
        print(f"    {part.name}{mesh}")
    if model.skeleton:
        print(f"  skeleton: {len(model.skeleton.nodes)} nodes "
              f"(version={model.skeleton.version})")
        for node in model.skeleton.nodes:
            tx, ty, tz = node.translation
            print(f"    {node.name} <- {node.parent}  t=({tx:.3f}, {ty:.3f}, {tz:.3f})")


def inspect(model: Model, stats: dict) -> None:
    """Accumulate corpus-wide consistency checks for ``--check``."""
    stats.setdefault("files", 0)
    stats["files"] += 1
    stats.setdefault("parts", 0)
    stats["parts"] += len(model.parts)
    for key, value in (
        ("stream_version", model.stream_version),
        ("V100ModelDesc.version", model.desc_version),
        ("StdModelDesc.version", model.base_version),
        ("has_skeleton", model.has_skeleton),
    ):
        stats.setdefault(key, Counter())[value] += 1
    for part in model.parts:
        stats.setdefault("V100PartDesc.version", Counter())[part.version] += 1
        stats.setdefault("part_component_version", Counter())[part.component.version] += 1
        stats.setdefault("part_component_class", Counter())[part.component.component_class] += 1
        stats.setdefault("part_kind", Counter())[part.component.kind] += 1
        stats.setdefault("meshed_parts", 0)
        if part.mesh:
            stats["meshed_parts"] += 1
    assert model.component is not None
    stats.setdefault("model_component_version", Counter())[model.component.version] += 1
    stats.setdefault("model_component_class", Counter())[model.component.component_class] += 1
    stats.setdefault("model_kind", Counter())[model.component.kind] += 1

    skeleton = model.skeleton
    assert skeleton is not None
    stats.setdefault("skeleton_version", Counter())[skeleton.version] += 1
    stats.setdefault("nodes", 0)
    stats["nodes"] += len(skeleton.nodes)

    # Consistency: node count == part count, and the node/part name sets match.
    if len(skeleton.nodes) != len(model.parts):
        stats.setdefault("node_part_count_mismatch", []).append(model.path)
    part_names = {p.name for p in model.parts}
    node_names = {n.name for n in skeleton.nodes}
    if part_names != node_names:
        stats.setdefault("name_set_mismatch", []).append(model.path)

    # Every parent must be an existing node or the synthetic root.
    roots = 0
    for node in skeleton.nodes:
        if node.parent not in node_names:
            roots += 1
            stats.setdefault("root_parent", Counter())[node.parent] += 1
        # The bottom matrix row is (0, 0, 0, 1) in a well-formed affine matrix.
        bottom = node.matrix[12:16]
        if bottom != (0.0, 0.0, 0.0, 1.0):
            stats.setdefault("bad_matrix_bottom", []).append(
                f"{model.path}:{node.name}:{bottom}")
        for value in node.matrix:
            if not (-1e6 < value < 1e6):
                stats.setdefault("wild_matrix_value", []).append(
                    f"{model.path}:{node.name}:{value}")
    stats.setdefault("roots_per_file", Counter())[roots] += 1
    stats.setdefault("node_version", Counter())
    for node in skeleton.nodes:
        stats["node_version"][node.version] += 1


def report(stats: dict) -> None:
    """Print the aggregated ``--check`` statistics."""
    print()
    print("field value distributions (value: files/records)")
    for key in sorted(stats):
        value = stats[key]
        if isinstance(value, Counter):
            items = value.most_common(8)
            print(f"  {key}: " + ", ".join(f"{k}={v}" for k, v in items)
                  + (" ..." if len(value) > 8 else ""))
        elif isinstance(value, list):
            print(f"  {key}: {len(value)} problem(s)")
            for item in value[:5]:
                print(f"      {item}")
        else:
            print(f"  {key}: {value}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("path", nargs="?", help=".cho file to parse")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    ap.add_argument("--check", metavar="ROOT",
                    help="parse every .cho below ROOT and report coverage")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.WARNING,
                        format="%(levelname)s %(name)s: %(message)s")

    if args.check:
        paths = iter_corpus(args.check, ".cho")
        stats: dict = {}
        code = run_check(paths, parse, lambda doc, _s: inspect(doc, stats))
        report(stats)
        return code

    if not args.path:
        ap.error("a path or --check is required")
    model = parse(args.path)
    if args.json:
        json.dump(model.to_json(), sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
    else:
        dump_text(model)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

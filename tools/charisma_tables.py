#!/usr/bin/env python3
"""Extract and check the four Charisma name selectors of ``docs/40`` §7.2.

A unit's body and its three gameplay animations are chosen by four sibling
routines in ``Incubation.exe`` that are pure `switch` cascades over the unit's
own bytes.  ``tools/inclib/charisma_tables.py`` enumerates them by interpreting
the code; this is the CLI over it, and the corpus checks that make the result
usable as a specification rather than as a plausible listing.

What the checks establish:

* the two eagerly-registered sets -- the models and the idle animations that
  ``fcn.00407e90`` hands to ``aCreateCHModelDescriptor`` and
  ``aCreateCHAnimationDescriptor`` -- are **exactly** the sets the model and
  idle selectors can return.  The two readings share no code, so agreement is
  evidence and not a tautology;
* every name any of the four can return resolves to a shipped file, ``N/N``;
* every mesh those models name is present in **every** world set's
  ``prototyp.din``, so a remake can convert unit geometry once instead of nine
  times;
* every unit type in ``SetUnitInfo`` either gets a body or is refused for a
  reason the tool names, and the refusals are counted rather than tolerated;
* every movement target of every gameplay animation is either a part of a model
  the same key selects, or one of the authoring helpers ``docs/40`` §7 measured
  -- which a runtime must **ignore**, not fail on.

Usage::

    python3 tools/charisma_tables.py --check gog_incubation
    python3 tools/charisma_tables.py --names gog_incubation
    python3 tools/charisma_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import glob
import json
import logging
import math
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import charisma  # noqa: E402
from inclib import prototyp as protomod  # noqa: E402
from inclib.check import Checker  # noqa: E402
from inclib.charisma_tables import (  # noqa: E402
    HERO_TYPE, KIND4_LITERAL_VA, PLAYERS, SELECTORS, TYPE_LIMIT, WEAPON_LIMIT,
    NEUTRAL_PLAYER, SelectorError, SelectorKey, SelectorTables,
    registered_names, split_registered,
)
from inclib.info import load_info  # noqa: E402
from inclib.charisma import mat_translation  # noqa: E402
from inclib.pose import (CHANNEL_POSITION, pose_model,  # noqa: E402
                         sample_vector)
from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("charisma_tables")

GAME_EXE = "Incubation.exe"
OBJECTS_DIR = os.path.join("CHData", "Objects")
ANIMATIONS_DIR = os.path.join("CHData", "Animations")

#: The three selectors that name animations, as opposed to the model one.
ANIMATION_SELECTORS = ("move", "idle", "fire")

#: Unit types the engine gives a body but not a full set of clips, with the
#: families it *does* return.  This is a measured property of the shipped
#: tables, not a shortfall in the extraction: ``docs/40`` §7.2 says an idle is
#: "always playing", and for these nine types there is none to play.  Two of
#: them -- the Norc'Yn's detachable arms -- have no clip of any family, which
#: fits ``docs/40`` §6: a limb aimed by an ``External*Movement`` is driven by
#: the game writing a matrix, not by a clip.  A remake's state machine has to
#: tolerate every one of these rather than assume three clips per body.
PARTIAL_ANIMATION_TYPES: dict[int, tuple[str, ...]] = {
    24: ("move",),                    # Spider
    52: ("move", "idle"),             # Dec'Ther
    55: ("fire",),                    # Cy'Coo
    60: ("fire",),                    # War'Coo
    61: ("idle",),                    # Norc'Yn -- and its idle is an `F1` name
    62: (),                           # Norc'Yn left arm
    63: (),                           # Norc'Yn right arm
    65: ("move", "idle"),             # Bea'Ther
    66: ("move", "idle"),             # Bea'Coo
}

#: The schema of the pose case file the Godot suite replays.
POSE_SCHEMA = "incubation.charisma-pose/1"
#: Frames sampled per animation.  Five is enough to cross every interpolation
#: segment class in the corpus while keeping the fixture around a megabyte;
#: the middle one additionally carries every bone's full local matrix, so a
#: rotation error on a childless leaf -- which no joint position can show --
#: is still caught.
POSE_FRAMES = 5

#: The authoring helpers of ``docs/40`` §7: movement targets the exporter left
#: in a gameplay animation and never emitted as a model part.  A runtime
#: **ignores** a track with no part; this is the vocabulary it must ignore, and
#: it is pinned so that a track going missing for any *other* reason fails.
AUTHORING_HELPERS: frozenset[str] = frozenset({
    "Banner", "Line00", "Linie01",
    "Bip01 Kopf", "Bip01 L Finger0", "Bip01 R Finger0",
    "Bip01 Schritte", "Bip01 Schwanz", "Bip01 Schwanz1",
})


# ---------------------------------------------------------------------------
# The installation
# ---------------------------------------------------------------------------

def _stems(pattern: str) -> dict[str, str]:
    """Basename without suffix -> path, for a glob over the installation."""
    return {os.path.splitext(os.path.basename(p))[0]: p
            for p in sorted(glob.glob(pattern))}


def shipped_models(root: str) -> dict[str, str]:
    return _stems(os.path.join(root, OBJECTS_DIR, "*.cho"))


def shipped_animations(root: str) -> dict[str, str]:
    return _stems(os.path.join(root, ANIMATIONS_DIR, "*.cha"))


def selectable_keys(tables: SelectorTables) -> list[SelectorKey]:
    """Every key for which the model selector returns a body."""
    return [key for key, outcomes in tables.tables["model"].items()
            if any(o.name for o in outcomes)]


# ---------------------------------------------------------------------------
# The checks
# ---------------------------------------------------------------------------

def _check_registration(ck: Checker, tables: SelectorTables,
                        pe: PEFile) -> None:
    """The eager registrations against the enumerated selectors."""
    models, animations = split_registered(registered_names(pe))
    got_models = tables.names("model")
    got_idle = tables.names("idle")
    ck.expect("model set == registrations", len(got_models & models),
              len(models | got_models),
              f"{len(got_models)} enumerated, {len(models)} registered")
    ck.expect("idle set == registrations", len(got_idle & animations),
              len(animations | got_idle),
              f"{len(got_idle)} enumerated, {len(animations)} registered")
    # docs/40 §7.2 states the three counts; they are quoted here so a change in
    # the binary or in this tool shows up as a disagreement with the document.
    ck.expect("model names", len(got_models), 104)
    ck.expect("move names", len(tables.names("move")), 28)
    ck.expect("idle names", len(got_idle), 30)
    ck.expect("fire names", len(tables.names("fire")), 33)


def _check_resolution(ck: Checker, tables: SelectorTables, root: str,
                      pe: PEFile) -> tuple[dict[str, str], dict[str, str]]:
    """Every returnable name against the shipped files."""
    models = shipped_models(root)
    animations = shipped_animations(root)
    ck.check("corpus present", bool(models) and bool(animations),
             f"{len(models)} .cho, {len(animations)} .cha")

    wanted_models = sorted(tables.names("model"))
    resolved = [n for n in wanted_models if n in models]
    ck.expect("model names resolve", len(resolved), len(wanted_models),
              f"{len(resolved)}/{len(wanted_models)}")

    wanted_anims: set[str] = set()
    for selector in ANIMATION_SELECTORS:
        wanted_anims |= tables.names(selector)
    ordered = sorted(wanted_anims)
    ok = [n for n in ordered if n in animations]
    ck.expect("animation names resolve", len(ok), len(ordered),
              f"{len(ok)}/{len(ordered)}")

    # docs/40 §7.2: `kind == 4` reaches one fixed literal rather than a
    # selector.  It is part of the name closure even though nothing returns it.
    literal = pe.cstring(KIND4_LITERAL_VA)
    ck.expect("kind-4 literal", literal, "P0_M2_000")
    ck.check("kind-4 literal resolves", literal in animations, str(literal))
    return models, animations


def _check_guards(ck: Checker, tables: SelectorTables, root: str) -> None:
    """The routines' own bounds against ``Info.lcl``.

    ``docs/40`` §7.2 identifies the two unit fields by their bounds: the type
    is checked against ``0x44`` and the weapon against ``0x2F``.  That argument
    is only as good as the two top ids, so they are read back out of the
    balance tables rather than asserted.
    """
    tbl = load_info(root)
    ck.expect("top unit type id", max(tbl.units), TYPE_LIMIT - 2,
              "the type guard's own bound, 0x44")
    ck.expect("top weapon id", max(tbl.weapons), WEAPON_LIMIT - 2,
              "the weapon guard's own bound, 0x2F")

    # ``docs/40`` §7.2 identifies the type field partly by the special case for
    # ``0x17``, the hero.  What that case *does* is rewrite the pair to
    # (type 0, player 1) before the cascade, so the hero is drawn as a type-0
    # body in player 1's colours whatever player actually owns it.  Stating it
    # as an equality makes it falsifiable; as a named constant it was not.
    hero = {w: [o.name for o in tables.lookup("model", SelectorKey(HERO_TYPE, w, p))]
            for w in range(WEAPON_LIMIT) for p in (0, 1, 2, 3)}
    baseline = {w: [o.name for o in tables.lookup("model", SelectorKey(0, w, 1))]
                for w in range(WEAPON_LIMIT) for p in (0, 1, 2, 3)}
    ck.expect("hero is type 0 in player 1's skin", hero, baseline,
              f"unit type {HERO_TYPE:#x} over every weapon and owner")

    # The neutral player is refused outright by the model selector; nothing
    # else in the domain may be.
    neutral = {key for key, outcomes in tables.tables["model"].items()
               if key.player == NEUTRAL_PLAYER and any(o.name for o in outcomes)}
    ck.expect("neutral player has no body", len(neutral), 0)


def _check_unit_types(ck: Checker, tables: SelectorTables, root: str) -> None:
    """Every ``SetUnitInfo`` row gets a body, or is refused for a reason."""
    tbl = load_info(root)
    bodied: list[int] = []
    refused: dict[int, str] = {}
    for type_id in sorted(tbl.units):
        names = {o.name
                 for player in PLAYERS if player != NEUTRAL_PLAYER
                 for weapon in range(WEAPON_LIMIT)
                 for o in tables.lookup("model",
                                        SelectorKey(type_id, weapon, player))
                 if o.name}
        if names:
            bodied.append(type_id)
        else:
            refused[type_id] = tbl.units[type_id].description
    ck.expect("unit types with a body", len(bodied), len(tbl.units),
              f"{len(bodied)}/{len(tbl.units)}"
              + (f"; refused: {sorted(refused)}" if refused else ""))


def _check_meshes(ck: Checker, tables: SelectorTables, root: str,
                  models: dict[str, str]) -> None:
    """Every mesh the selectable models name, in every world set.

    This is what lets the converter emit unit geometry **once**: if a mesh
    name is present in all nine containers, the world set a mission happens to
    use cannot change which meshes a body needs.
    """
    meshes: set[str] = set()
    parts = 0
    for name in sorted(tables.names("model")):
        path = models.get(name)
        if path is None:
            continue
        model = charisma.parse_model_file(path)
        parts += len(model.parts)
        meshes |= {p.mesh for p in model.parts if p.mesh}
    ck.check("selectable models parsed", parts > 0,
             f"{parts} parts, {len(meshes)} distinct meshes")

    # Only the `WorldSet/World_*` containers.  `find_containers` also returns
    # the `Video/*/Objects/` ones, which hold a cutscene's own props and are
    # not where a unit body is ever looked up -- counting them would turn a
    # true statement about the game's world sets into a false one about
    # everything on the disc.
    containers = [(din, bin_) for din, bin_ in protomod.find_containers(root)
                  if os.sep + "World_" in din]
    ck.check("world sets found", len(containers) > 0, f"{len(containers)}")
    absent: dict[str, int] = {}
    for din, _bin in containers:
        label = os.path.basename(os.path.dirname(os.path.dirname(din)))
        have = set(protomod.load_container(din).names)
        missing = meshes - have
        if missing:
            absent[label] = len(missing)
    ck.expect("unit meshes in every world set", len(absent), 0,
              f"{len(meshes)} meshes x {len(containers)} sets"
              + ("" if not absent else f"; short: {absent}"))


def _check_track_binding(ck: Checker, tables: SelectorTables, root: str,
                         models: dict[str, str],
                         animations: dict[str, str]) -> None:
    """Movement targets against the skeleton of a model the same key selects.

    ``docs/40`` §7 measures 116 authoring helpers over the whole corpus --
    ``Banner``, ``Dummy01``, ``Zopf``, spare Biped fingers -- that the exporter
    kept in the animation and never emitted as parts.  The rule a runtime must
    follow is to **ignore** a track with no part; this check states how many
    such tracks the gameplay set actually has, so that ignoring them is a
    measured decision rather than a swallowed error.
    """
    skeletons: dict[str, set[str]] = {}
    for name in sorted(tables.names("model")):
        path = models.get(name)
        if path is None:
            continue
        model = charisma.parse_model_file(path)
        names = {p.name for p in model.parts}
        if model.skeleton is not None:
            names |= {n.name for n in model.skeleton.nodes}
        skeletons[name] = names

    # Which models each animation is ever paired with, key by key.
    paired: dict[str, set[str]] = defaultdict(set)
    for selector in ANIMATION_SELECTORS:
        for key, outcomes in tables.tables[selector].items():
            bodies = {o.name for o in tables.lookup("model", key) if o.name}
            for outcome in outcomes:
                if outcome.name:
                    paired[outcome.name] |= bodies

    bound = 0
    unbound: Counter[str] = Counter()
    orphans = 0
    for anim_name in sorted(paired):
        path = animations.get(anim_name)
        if path is None:
            continue
        anim = charisma.parse_animation_file(path)
        reachable: set[str] = set()
        for body in paired[anim_name]:
            reachable |= skeletons.get(body, set())
        if not reachable:
            orphans += 1
            continue
        for movement in anim.movements:
            if movement.target in reachable:
                bound += 1
            else:
                unbound[movement.target] += 1
    ck.check("gameplay tracks bound", bound > 0,
             f"{bound} bound, {sum(unbound.values())} unbound over "
             f"{len(unbound)} helper names")
    ck.expect("every animation reaches a body", orphans, 0)
    # The unbound set is pinned by name.  Checking only that it is *small*
    # would pass just as well if a real bone stopped resolving, which is the
    # one failure this check exists to catch.
    ck.expect("unbound targets are the known helpers",
              sorted(unbound), sorted(AUTHORING_HELPERS),
              f"{sum(unbound.values())} tracks a runtime must ignore")


def _check_reachability(ck: Checker, tables: SelectorTables, root: str) -> None:
    """Every key the shipped missions can present, against the selectors.

    A histogram, not a pass/fail on each unit: what matters is that no mission
    can put a unit on the map for which the engine would choose nothing, and
    that the statement is made over the whole corpus rather than over a demo.
    """
    from inclib.lev import load_lev

    paths = sorted(glob.glob(os.path.join(root, "Missions", "*.lev")))
    ck.check("mission corpus present", bool(paths), f"{len(paths)} .lev")
    seen: Counter[tuple[int, int, int]] = Counter()
    for path in paths:
        battle = load_lev(path)
        for unit in battle.active_units:
            seen[(unit.type_id, unit.weapon, unit.player)] += 1

    missing: list[tuple[int, int, int]] = []
    for key_tuple in sorted(seen):
        key = SelectorKey(*key_tuple)
        if key.player == NEUTRAL_PLAYER:
            continue
        if not any(o.name for o in tables.lookup("model", key)):
            missing.append(key_tuple)
    ck.expect("every placed unit has a body", len(missing), 0,
              f"{len(seen)} distinct (type, weapon, player) keys"
              + ("" if not missing else f"; missing {missing[:8]}"))

    # Animation coverage is *not* total, and pretending otherwise would be the
    # easy mistake here.  Nine unit types get fewer than three clips
    # (PARTIAL_ANIMATION_TYPES); what is checked is that the set of gaps is
    # exactly that one, so a new gap fails and a closed one fails too.
    partial: dict[int, tuple[str, ...]] = {}
    for type_id in sorted({k[0] for k in seen}):
        weapons = sorted({k[1] for k in seen if k[0] == type_id})
        players = sorted({k[2] for k in seen if k[0] == type_id}
                         - {NEUTRAL_PLAYER})
        if not players:
            continue
        families = tuple(
            selector for selector in ANIMATION_SELECTORS
            if all(any(o.name
                       for o in tables.lookup(selector,
                                              SelectorKey(type_id, w, p)))
                   for w in weapons for p in players))
        if len(families) != len(ANIMATION_SELECTORS):
            partial[type_id] = families
    expected = {t: f for t, f in PARTIAL_ANIMATION_TYPES.items()
                if t in {k[0] for k in seen}}
    ck.expect("placed types with partial clips", partial, expected,
              f"{len(seen) - len(partial)} of {len(seen)} keys fully clipped")


def _gameplay_pairs(tables: SelectorTables) -> list[tuple[str, str]]:
    """(model, animation) pairs the selectors actually put together.

    Posing an animation against a model it is never selected with would be a
    test of nothing: the targets would not resolve and the pose would be the
    bind pose with extra steps.
    """
    pairs: set[tuple[str, str]] = set()
    for selector in ANIMATION_SELECTORS:
        for key, outcomes in tables.tables[selector].items():
            bodies = {o.name for o in tables.lookup("model", key) if o.name}
            for outcome in outcomes:
                if outcome.name:
                    pairs |= {(b, outcome.name) for b in bodies}
    return sorted(pairs)


def _pose_frames(model, anim) -> list[float]:
    duration = getattr(anim, "duration", 0.0)
    if duration <= 0.0:
        return [0.0]
    return [duration * i / (POSE_FRAMES - 1) for i in range(POSE_FRAMES)]


def _check_pose(ck: Checker, tables: SelectorTables, models: dict[str, str],
                animations: dict[str, str]) -> None:
    """Every gameplay pose, on a frame grid, bone by bone.

    Two properties, and they are the two that a wrong transform chain breaks
    rather than merely perturbs: every matrix element is finite, and the one
    top-level bone takes its translation **from the track** and not from the
    bind pose (``docs/40`` §6.2).  The second is the check that would have
    caught the earlier draft of that section, which had the branch firing for
    no model at all.
    """
    pairs = _gameplay_pairs(tables)
    ck.check("gameplay pose pairs", bool(pairs), f"{len(pairs)} (model, clip)")

    posed = 0
    nonfinite: list[str] = []
    top_level_counts: Counter[int] = Counter()
    absolute_root = 0
    root_tracked = 0
    for model_name, anim_name in pairs:
        model_path = models.get(model_name)
        anim_path = animations.get(anim_name)
        if model_path is None or anim_path is None:
            continue
        model = charisma.parse_model_file(model_path)
        anim = charisma.parse_animation_file(anim_path)
        if model.skeleton is None:
            continue
        tracks = {(m.target, m.channel) for m in anim.movements}
        for time in _pose_frames(model, anim):
            pose = pose_model(model, anim, time)
            posed += 1
            tops = [n.name for n in pose.nodes if pose.is_top_level(n.name)]
            top_level_counts[len(tops)] += 1
            for node in pose.nodes:
                for value in pose.world[node.name]:
                    if not math.isfinite(value):
                        nonfinite.append(f"{model_name}/{anim_name}:{node.name}")
                        break
            # docs/40 §6.2: where the top-level bone has a Position track, its
            # local translation is that track's value outright -- the bind
            # translation is not added.  Stated as an equality against the
            # sampled value, so the branch is checked and not just executed.
            for name in tops:
                if (name, CHANNEL_POSITION) not in tracks:
                    continue
                root_tracked += 1
                movement = next(m for m in anim.movements
                                if m.target == name
                                and m.channel == CHANNEL_POSITION)
                want = sample_vector(movement, time)
                got = mat_translation(pose.local[name])
                if all(abs(got[i] - want[i]) < 1e-6 for i in range(3)):
                    absolute_root += 1

    ck.check("poses computed", posed > 0, f"{posed} frames over {len(pairs)} pairs")
    ck.expect("every bone matrix is finite", len(nonfinite), 0,
              "" if not nonfinite else f"{nonfinite[:4]}")
    ck.expect("exactly one top-level bone per pose",
              sorted(top_level_counts), [1],
              f"{posed} poses")
    ck.expect("top-level translation comes from the track",
              absolute_root, root_tracked,
              f"{absolute_root}/{root_tracked} poses whose root has a "
              f"Position track")


def emit_pose_cases(root: str, path: str) -> int:
    """Write the fixture ``godot/tests/test_charisma.gd`` replays."""
    tables = SelectorTables(PEFile(os.path.join(root, GAME_EXE)))
    models = shipped_models(root)
    animations = shipped_animations(root)
    cases: list[dict[str, object]] = []
    for model_name, anim_name in _gameplay_pairs(tables):
        model_path = models.get(model_name)
        anim_path = animations.get(anim_name)
        if model_path is None or anim_path is None:
            continue
        model = charisma.parse_model_file(model_path)
        anim = charisma.parse_animation_file(anim_path)
        if model.skeleton is None:
            continue
        times = _pose_frames(model, anim)
        order = [n.name for n in model.skeleton.nodes]
        frames = []
        for time in times:
            pose = pose_model(model, anim, time)
            frames.append({
                "time": time,
                "joints": [c for name in order
                           for c in pose.joints(include_hidden=True)[name]],
            })
        middle = pose_model(model, anim, times[len(times) // 2])
        cases.append({
            "model": model_name,
            "animation": anim_name,
            "bones": order,
            # The interpolators this pair exercises, so the suite can assert
            # that the fixture covers squad and the cubic Bezier vector rather
            # than only the two linear paths.
            "key_classes": sorted({m.key_class for m in anim.movements}),
            "frames": frames,
            "local_time": middle.time,
            "locals": [v for name in order for v in middle.local[name]],
        })
    document = {
        "schema": POSE_SCHEMA,
        "source": {"root": os.path.abspath(root)},
        "frames_per_case": POSE_FRAMES,
        "cases": cases,
    }
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle)
    LOG.info("wrote %d pose cases to %s (%.1f MB)", len(cases), path,
             os.path.getsize(path) / 1e6)
    return 0 if cases else 1


def run_check(root: str) -> int:
    ck = Checker()
    pe = PEFile(os.path.join(root, GAME_EXE))
    tables = SelectorTables(pe)
    _check_registration(ck, tables, pe)
    models, animations = _check_resolution(ck, tables, root, pe)
    _check_guards(ck, tables, root)
    _check_unit_types(ck, tables, root)
    _check_meshes(ck, tables, root, models)
    _check_track_binding(ck, tables, root, models, animations)
    _check_reachability(ck, tables, root)
    _check_pose(ck, tables, models, animations)
    return ck.report()


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def print_names(root: str) -> int:
    tables = SelectorTables(PEFile(os.path.join(root, GAME_EXE)))
    for selector, address in SELECTORS.items():
        names = sorted(tables.names(selector))
        print(f"{selector} ({address:#010x}): {len(names)} names")
        for name in names:
            print(f"  {name}")
    return 0


def dump_json(root: str) -> int:
    tables = SelectorTables(PEFile(os.path.join(root, GAME_EXE)))
    json.dump(tables.to_dict(), sys.stdout, indent=1, sort_keys=True)
    print()
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", nargs="?", default="gog_incubation",
                    help="the game directory (default: gog_incubation)")
    ap.add_argument("--check", metavar="ROOT", help="run the corpus checks")
    ap.add_argument("--names", action="store_true",
                    help="print every name each selector can return")
    ap.add_argument("--json", action="store_true",
                    help="dump the four decision tables as JSON")
    ap.add_argument("--emit-pose-cases", metavar="PATH",
                    help="write the pose fixture the Godot suite replays")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    root = args.check or args.root
    if not os.path.isdir(root):
        LOG.error("root %s is not a directory", root)
        return 2
    try:
        if args.emit_pose_cases:
            return emit_pose_cases(root, args.emit_pose_cases)
        if args.check:
            return run_check(root)
        if args.json:
            return dump_json(root)
        return print_names(root)
    except (PEError, SelectorError, OSError) as exc:
        LOG.error("%s", exc)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

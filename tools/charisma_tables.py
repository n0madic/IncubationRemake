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
import os
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cha_parse  # noqa: E402
import cho_parse  # noqa: E402
from inclib import prototyp as protomod  # noqa: E402
from inclib.check import Checker  # noqa: E402
from inclib.charisma_tables import (  # noqa: E402
    HERO_TYPE, KIND4_LITERAL_VA, PLAYERS, SELECTORS, TYPE_LIMIT, WEAPON_LIMIT,
    NEUTRAL_PLAYER, SelectorError, SelectorKey, SelectorTables,
    registered_names, split_registered,
)
from inclib.info import load_info  # noqa: E402
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
        model = cho_parse.parse(path)
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
        model = cho_parse.parse(path)
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
        anim = cha_parse.parse(path)
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
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    root = args.check or args.root
    if not os.path.isdir(root):
        LOG.error("root %s is not a directory", root)
        return 2
    try:
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

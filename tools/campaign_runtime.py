#!/usr/bin/env python3
"""Run the campaign model over the corpus -- ``docs/27``.

``inclib/campaign.py`` is the executable model; this is the check that it says
what the shipped data and the shipped executable say, and the emitter for the
fixture ``godot/tests/test_campaign.gd`` replays.

The strongest checks here are the ones where two readings that share no code
have to agree: the model's rule constants against the immediates
``campaign_tables.py`` reads out of ``Incubation.exe``, the recruit price
against ``Info.lcl``'s weapon 0, and the location graph against the cells of
``_C_XXX``/``_C_YYY``.

Usage::

    campaign_runtime.py --check gog_incubation
    campaign_runtime.py --emit-cases FILE --root gog_incubation
    campaign_runtime.py --check-saves tests/fixtures/saves   # outside always-run
"""

from __future__ import annotations

import argparse
import json
import logging
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import campaign_tables as ctables                                   # noqa: E402
from inclib import campaign as cam                                  # noqa: E402
from inclib.check import Checker                                    # noqa: E402
from inclib.info import load_info                                   # noqa: E402
from inclib.lev import load_lev                                     # noqa: E402

LOG = logging.getLogger("campaign_runtime")

#: ``docs/27`` §2.1 -- the two chains, by the mission ids their headers carry.
CHAIN_MISSION_IDS = {1: range(1, 35), 2: range(40, 80)}
#: The epilogue, whose id is outside both switches (``docs/27`` §2.2).
EPILOGUE = ("_C_180", 180)
#: ``docs/29`` §1.2, ``0x00431118`` -- a deployment cell is one whose action
#: point is the player's slot plus one.
DEPLOYMENT_ACTION_POINT_BIAS = 1
#: ``docs/10`` +0x004 -- ten 64-byte deployment-ring records, so ten is the
#: most a squad can take to a mission.
DEPLOYMENT_RING_RECORDS = 10


def campaign_missions(root: Path) -> dict[str, Any]:
    """Every shipped campaign mission `.lev`, by basename.

    The two campaign maps are excluded: they are map type 4 and carry the
    location cells, not a mission.
    """
    out: dict[str, Any] = {}
    for path in sorted((root / "Missions").glob("_C_*.lev")):
        if path.stem.upper() in {"_C_XXX", "_C_YYY"}:
            continue
        out[path.stem] = load_lev(str(path))
    return out


#: ``Info.lcl``'s ``SetWeaponInfo`` cost column, as ``campaign_tables``'
#: own price check indexes it.
WEAPON_COST_COLUMN = 15


def weapon_zero_cost(corpus: ctables.Corpus) -> int:
    """``Info.lcl``'s ``SetWeaponInfo`` row 0, cost column."""
    row = corpus.weapons.get(0)
    numbers = ctables.numbers(row) if row else []
    if len(numbers) <= WEAPON_COST_COLUMN:
        raise SystemExit("Info.lcl carries no weapon 0 -- is this the game root?")
    return int(numbers[WEAPON_COST_COLUMN])


def recruit_hit_points(root: Path, player: int = 0) -> int:
    """What ``recomputeUnitStats`` leaves a fresh recruit.

    ``aEnlargeUnitPool`` writes ``unitType = player`` (``docs/27`` §3.2), so
    the recruit's hit points are ``Info.lcl``'s ``hp_max`` for unit type
    *player* -- types 0..3 are `Human Soldier (1)` .. `(4)`.
    """
    row = load_info(str(root)).units.get(player)
    if row is None:
        raise SystemExit(f"Info.lcl carries no unit type {player}")
    return row.hp_max


@dataclass(frozen=True)
class Context:
    """Everything the checks read, loaded once."""

    root: Path
    corpus: ctables.Corpus
    binary: ctables.Binary
    tables: cam.LocationTables
    missions: dict[str, Any]
    #: ``Info.lcl``'s weapon 0 cost, which prices a recruit.
    cost: int
    #: What ``recomputeUnitStats`` leaves a recruit.
    hp: int
    #: ``Txtmod_h.lcl`` 60..62, the three seeded names.
    seeded: list[str]

    @classmethod
    def load(cls, root: Path) -> "Context":
        corpus = ctables.Corpus(str(root))
        names = corpus.text.get(ctables.SQUAD_TEXT_FILE, {})
        return cls(
            root=root,
            corpus=corpus,
            binary=ctables.Binary(str(root)),
            tables=cam.LocationTables.from_json(
                ctables.tables_document(str(root))),
            missions=campaign_missions(root),
            cost=weapon_zero_cost(corpus),
            hp=recruit_hit_points(root),
            seeded=[names.get(i, n) for i, n in
                    zip(ctables.SQUAD_NAME_IDS, ctables.SQUAD_NAMES)],
        )

    def begin(self, campaign: int) -> cam.CampaignState:
        """A fresh campaign, with the corpus's own prices and names."""
        return cam.CampaignState.begin(
            campaign, weapon_cost=self.cost, hit_points=self.hp,
            names=self.seeded if campaign == 1 else cam.SEED_NAMES)


# --- the checks ---------------------------------------------------------------

def check_constants(ck: Checker, binary: ctables.Binary) -> None:
    """The model's rule constants against the executable's own immediates.

    Two readings that share no code: ``campaign_tables`` decodes each from an
    instruction, ``inclib/campaign`` declares it as the rule.
    """
    ck.expect("const.pool_record", cam.POOL_RECORD_SIZE, ctables.POOL_STRIDE)
    ck.expect("const.pool_slots", cam.POOL_USABLE_SLOTS, ctables.POOL_SLOTS)
    ck.expect("const.hp_offset", cam.OFF_HIT_POINTS, ctables.HP_OFFSET)
    ck.expect("const.location_bias", cam.LOCATION_BIAS, ctables.LOCATION_BIAS)
    ck.expect("const.hero_type", cam.HERO_UNIT_TYPE, ctables.HERO_UNIT_TYPE)
    ck.expect("const.hero_flag", cam.HERO_POOL_FLAG, ctables.HERO_FLAG)
    ck.expect("const.hero_flag_offset", cam.OFF_POOL_FLAG,
              ctables.HERO_FLAG_OFFSET)
    ck.expect("const.medic_equipment", cam.MEDIC_EQUIPMENT_ID,
              ctables.MEDIC_EQUIPMENT_ID)
    ck.expect("const.equipment_base", cam.OFF_EQUIPMENT, ctables.EQUIPMENT_BASE)
    ck.expect("const.rank_scale", cam.EP_PER_RANK, ctables.RANK_SCALE)
    ck.expect("const.fp_floor", cam.FP_FLOOR, ctables.FP_FLOOR)
    ck.expect("const.recruit_name", cam.RECRUIT_NAME_FORMAT, ctables.ENLARGE_NAME)
    ck.expect("const.speech_draw", (cam.SPEECH_BASE, cam.SPEECH_SPAN),
              (ctables.SPEECH_BASE, ctables.SPEECH_SPAN))
    ck.expect("const.mode_campaign", cam.MODE_CAMPAIGN, ctables.MODE_CAMPAIGN)
    ck.expect("const.payout_scores", list(cam.RESULT_BASE_SCORE),
              binary.payout_scores())
    # The immediates the enlarge block stores, by offset.
    stores = set(ctables.ENLARGE_STORES.values())
    for name, offset in (("unit_type", cam.OFF_UNIT_TYPE), ("ep", cam.OFF_EP),
                         ("tp", cam.OFF_TP), ("fp", cam.OFF_FP),
                         ("player", cam.OFF_PLAYER), ("weapon", cam.OFF_WEAPON),
                         ("pool_flag", cam.OFF_POOL_FLAG),
                         ("resale", cam.OFF_RESALE), ("speech", cam.OFF_SPEECH)):
        ck.check(f"const.enlarge_store.{name}", offset in stores,
                 f"+{offset:#04x}")


def check_seed(ck: Checker, ctx: Context) -> None:
    """``docs/27`` §3.1 -- the two campaigns' opening rosters."""
    binary, seeded = ctx.binary, ctx.seeded

    empty = ctx.begin(2)
    ck.expect("seed.campaign2_pool_empty", empty.roster.used_slots(), 0)
    ck.expect("seed.campaign2_first_mission", empty.mission, "_C_140")

    state = ctx.begin(1)
    ck.expect("seed.campaign1_first_mission", state.mission, "_C_100")
    ck.expect("seed.campaign1_pool_size", state.roster.used_slots(), 3)
    ck.expect("seed.names", [r.name for _, r in state.roster.occupied()], seeded)

    # The sixteen field writes, against the same block campaign_tables decodes
    # straight out of 0x0047883B..0x004788A5.
    fields = binary.squad_fields()
    for (record, offset), want in sorted(fields.items()):
        got = state.roster.row(cam.ROW_LIVE)[record].raw[offset]
        ck.expect(f"seed.field.{record}.{offset:#04x}", got, want)

    hero = state.roster.row(cam.ROW_LIVE)[0]
    ck.expect("seed.hero_type", hero.unit_type, cam.HERO_UNIT_TYPE)
    ck.expect("seed.hero_flag", hero.pool_flag, cam.HERO_POOL_FLAG)
    ck.expect("seed.ranks", [r.rank for _, r in state.roster.occupied()],
              [1, 1, 1], "docs/27 3.1: all three start at rank 1")
    ck.check("seed.medic_kit",
             state.roster.row(cam.ROW_LIVE)[1].has_equipment(
                 cam.MEDIC_EQUIPMENT_ID),
             "West carries equipment 15, Small Medic Kit")
    # The campaign init arm, 0x0043AE76: player 0 alone.
    ck.expect("seed.equipment_points", state.equipment_points,
              [cam.CAMPAIGN_START_EQUIPMENT_POINTS, 0, 0, 0])
    ck.expect("seed.tech_level", state.tech_level, 1)
    ck.expect("seed.skill_level", state.skill_level, 0)
    ck.expect("seed.player_count", state.player_count, 1)


def check_economy(ck: Checker, ctx: Context) -> None:
    """``docs/27`` §5 -- the purse, the price of a soldier, buying."""
    cost = ctx.cost
    ck.expect("economy.weapon0_cost", cost, 10, "Info.lcl's Light Combat Gun")
    ck.expect("economy.recruit_price", cost + cam.RECRUIT_MARKUP, 60)

    state = ctx.begin(2)
    ck.expect("economy.start_points", state.equipment_points[0], 100)

    slot = state.recruit(0, weapon_zero_cost=cost, speech=1)
    ck.expect("economy.recruit_slot", slot, 0)
    ck.expect("economy.after_recruit", state.equipment_points[0], 40)
    ck.check("economy.recruit_refused_when_poor",
             state.recruit(0, weapon_zero_cost=cost, speech=1) is None,
             "40 points will not buy a 60-point soldier")
    ck.expect("economy.poor_purse_unchanged", state.equipment_points[0], 40)

    refund = state.dismiss(0, 0)
    ck.expect("economy.dismiss_refund", refund, 60,
              "the +50 markup is in both the price and the resale")
    ck.expect("economy.round_trip_free", state.equipment_points[0], 100)
    ck.expect("economy.dismiss_empties", state.roster.used_slots(), 0)

    # The cap and the floor.
    state.set_points(0, 9990)
    state.add_points(0, 100)
    ck.expect("economy.cap", state.equipment_points[0],
              cam.EQUIPMENT_POINT_CAP)
    ck.check("economy.spend_refuses", not state.spend_points(0, 20000),
             "a purchase never goes negative")
    ck.expect("economy.spend_refused_unchanged", state.equipment_points[0],
              cam.EQUIPMENT_POINT_CAP)
    ck.check("economy.empty_slot_holds_nothing", not state.add_points(3, 100),
             "playerKind[3] is 0")
    ck.expect("economy.empty_slot_purse", state.equipment_points[3], 0)

    # A weapon swap costs the difference, and refunds first.
    state.set_points(0, 100)
    state.recruit(0, weapon_zero_cost=cost, speech=1)
    costs = {0: 10, 5: 30}
    ck.check("economy.buy_weapon", state.buy_weapon(0, 0, 5, costs=costs))
    ck.expect("economy.swap_costs_difference", state.equipment_points[0],
              100 - 60 + 10 - 30)
    ck.expect("economy.resale_recomputed",
              state.roster.row(cam.ROW_LIVE)[0].resale,
              (30 + cam.RECRUIT_MARKUP) // cam.RESALE_SCALE)


def check_sort(ck: Checker) -> None:
    """``0x00478630`` -- descending by EP, free slots left where they are."""
    roster = cam.Roster()
    for i, ep in enumerate((10, 40, 20, 70)):
        rec = cam.PoolRecord()
        rec.hit_points = 5
        rec.ep = ep
        rec.name = f"u{i}"
        roster.row(cam.ROW_LIVE)[i] = rec
    roster.sort_by_ep()
    ck.expect("sort.descending", [r.ep for _, r in roster.occupied()],
              [70, 40, 20, 10])

    # A gap: the pair-skip means the free slot does not migrate, so the two
    # records after it never meet the two before it.
    gapped = cam.Roster()
    for i, ep in ((0, 10), (1, 40), (3, 70), (4, 20)):
        rec = cam.PoolRecord()
        rec.hit_points = 5
        rec.ep = ep
        gapped.row(cam.ROW_LIVE)[i] = rec
    gapped.sort_by_ep()
    ck.expect("sort.gap_is_a_wall",
              [(i, r.ep) for i, r in gapped.occupied()],
              [(0, 40), (1, 10), (3, 70), (4, 20)],
              "0x00478630 skips any pair whose either side has zero HP")


def check_banks(ck: Checker, ctx: Context) -> None:
    """``docs/27`` §3.5 as corrected: row 0 live, row 1 the entry snapshot."""
    state = ctx.begin(1)
    roster = state.roster

    roster.snapshot()
    ck.expect("banks.snapshot_copies", roster.used_slots(cam.ROW_SNAPSHOT), 3)
    ck.expect("banks.entry_rows_match",
              [r.name for _, r in roster.occupied(cam.ROW_LIVE)],
              [r.name for _, r in roster.occupied(cam.ROW_SNAPSHOT)],
              "_31_.sav: both rows hold the squad at mission entry")

    # Deploying removes from the live row and leaves the snapshot alone --
    # which is what _6_.sav and _33_.sav read, with row 0 empty.
    for slot in (0, 1, 2):
        roster.row(cam.ROW_LIVE)[slot] = cam.PoolRecord()
    ck.expect("banks.live_empty_in_mission", roster.used_slots(cam.ROW_LIVE), 0)
    ck.expect("banks.snapshot_survives", roster.used_slots(cam.ROW_SNAPSHOT), 3)

    roster.restore()
    ck.expect("banks.restore_is_a_replay", roster.used_slots(cam.ROW_LIVE), 3)
    roster.clear_snapshot()
    ck.expect("banks.snapshot_gone_by_the_map",
              roster.used_slots(cam.ROW_SNAPSHOT), 0,
              "_5_.sav is on the map screen with row 1 empty")


def check_survival(ck: Checker) -> None:
    """``docs/27`` §3.4 -- ``+0x4D`` and a free slot, both silent in the engine."""
    roster = cam.Roster()

    def unit(name: str, flag: int, player: int = 0) -> cam.PoolRecord:
        rec = cam.PoolRecord()
        rec.hit_points = 7
        rec.name = name
        rec.pool_flag = flag
        rec.player = player
        return rec

    kept, dropped = cam.recover_units(
        roster, [unit("keeper", 1), unit("hero", 2), unit("prop", 0),
                 unit("theirs", 1, player=1)], player=0)
    ck.expect("survival.kept", len(kept), 2)
    ck.expect("survival.dropped_not_candidate",
              [d["name"] for d in dropped], ["prop"])
    ck.expect("survival.other_players_ignored",
              [r.name for _, r in roster.occupied()], ["keeper", "hero"])

    full = cam.Roster()
    for i in range(cam.POOL_USABLE_SLOTS):
        full.row(cam.ROW_LIVE)[i] = unit(f"u{i}", 1)
    _, overflow = cam.recover_units(full, [unit("late", 1)], player=0)
    ck.expect("survival.pool_full",
              [d["reason"] for d in overflow], [cam.DROP_POOL_FULL])


def check_score(ck: Checker, ctx: Context) -> None:
    """``docs/27`` §6.2 -- all five results by all three difficulties."""
    for difficulty, multiplier in enumerate(cam.DIFFICULTY_MULTIPLIER):
        for result in range(1, 6):
            state = ctx.begin(2)
            state.difficulty = difficulty
            board = state.scoreboard[0]
            board.kills, board.losses, board.result = 7, 2, result
            report = state.score_mission()[0]
            want = 7 * multiplier - 2 * 2 + cam.RESULT_BASE_SCORE[result - 1]
            ck.expect(f"score.d{difficulty}.r{result}", report["score"], want)
            ck.expect(f"score.d{difficulty}.r{result}.total",
                      state.scoreboard[0].total, want)

    # The multiplier is campaign-only.
    state = ctx.begin(2)
    state.mode = 3
    state.difficulty = 2
    state.scoreboard[0].kills, state.scoreboard[0].result = 7, 2
    ck.expect("score.multiplier_is_campaign_only",
              state.score_mission()[0]["score"], 7 * 1 + 100)

    # The payouts: gated on campaign mode and on the result not being defeat.
    for result, paid in ((2, True), (5, False)):
        state = ctx.begin(2)
        state.game_control[cam.SLOT_EQUIPMENT_POINTS] = 250
        state.game_control[cam.SLOT_COMMENDATIONS] = 2
        state.scoreboard[0].result = result
        report = state.score_mission()[0]
        ck.expect(f"score.payout.r{result}.points",
                  report["equipment_points"], 250 if paid else 0)
        ck.expect(f"score.payout.r{result}.commendations",
                  report["commendations"], 2 if paid else 0)
        ck.expect(f"score.payout.r{result}.purse",
                  state.equipment_points[0], 350 if paid else 100)

    state = ctx.begin(2)
    state.mode = 2
    state.game_control[cam.SLOT_EQUIPMENT_POINTS] = 250
    state.scoreboard[0].result = 2
    ck.expect("score.payout_is_campaign_only",
              state.score_mission()[0]["equipment_points"], 0)

    # A slot that is not in the game is not scored at all.
    state = ctx.begin(2)
    ck.expect("score.unused_slots_skipped", len(state.score_mission()), 1)

    reset = cam.ScoreRecord(kills=9, losses=1, score=5, total=77, result=4)
    reset.reset()
    ck.expect("score.reset", (reset.kills, reset.score, reset.total,
                              reset.result), (0, 0, 0, cam.RESULT_NOTHING))


def check_chain(ck: Checker, ctx: Context) -> None:
    """``docs/27`` §6.6 -- the header's next-map field and its LCL override."""
    corpus, missions = ctx.corpus, ctx.missions
    shipped = {p.stem for p in corpus.missions}
    linked = 0
    for name, battle in sorted(missions.items()):
        nxt = battle.next_map
        if not nxt:
            continue
        linked += 1
        ck.check(f"chain.header.{name}", nxt in shipped,
                 f"{name} -> {nxt}")
    ck.check("chain.header_count", linked > 0, f"{linked} linked headers")

    overrides = 0
    for stem, target in corpus.next_map_calls:
        overrides += 1
        ck.check(f"chain.script.{stem}.{target}", target in shipped,
                 "EnterNameOfNextMap names a shipped mission")
    ck.check("chain.script_count", overrides > 0,
             f"{overrides} EnterNameOfNextMap arguments")

    # The two chains, by the mission id each header carries.
    for campaign, ids in CHAIN_MISSION_IDS.items():
        members = sorted(n for n, b in missions.items() if b.mission_id in ids)
        ck.check(f"chain.{campaign}.nonempty", bool(members),
                 f"{len(members)} missions, {members[0]}..{members[-1]}")
        first = cam.CAMPAIGN_FIRST_MISSION[campaign]
        ck.check(f"chain.{campaign}.starts_at_{first}", first in members,
                 "0x0043AF57 / 0x0043AF2A")
    ck.expect("chain.epilogue_id", missions[EPILOGUE[0]].mission_id, EPILOGUE[1])
    ck.expect("chain.epilogue_ends", missions[EPILOGUE[0]].next_map, "")
    ck.expect("chain.campaign1_hands_over", missions["_C_133"].next_map,
              "_C_YYY", "one campaign hands over to the other")


def check_graph(ck: Checker, ctx: Context) -> None:
    """``docs/27`` §2 -- the unlock graph against the campaign maps' cells."""
    corpus, tables = ctx.corpus, ctx.tables
    ck.expect("graph.arms", len(tables.unlock_graph),
              ctables.LOCATION_MAP_ENTRIES - len(ctables.LOCATION_MAP_GAPS))

    cells = {k.upper(): v for k, v in corpus.campaign_cells.items()}
    ck.check("graph.maps_read", set(cells) == {"_C_XXX", "_C_YYY"},
             f"{sorted(cells)}")

    every = sorted({loc for opens in tables.unlock_graph.values()
                    for loc in opens})
    both = cells["_C_XXX"] | cells["_C_YYY"]
    for loc in every:
        ck.check(f"graph.location_has_a_cell.{loc}", loc in both,
                 tables.kind(loc))
    unopened = sorted(both - set(every))
    ck.expect("graph.cells_no_arm_opens", unopened,
              sorted(ctables.UNREACHABLE_LOCATIONS),
              "_C_XXX's TEST EXTRO and <<Invalid Location>>")

    # location = missionId + 50, and aMapName is its exact inverse.
    round_trips = 0
    for mission_id, opens in sorted(tables.unlock_graph.items()):
        own = tables.location_of(mission_id)
        ck.check(f"graph.opens_own_location.{mission_id}", own in opens,
                 f"location {own}")
        name = tables.mission_of(own)
        if name is not None:
            round_trips += 1
    ck.check("graph.round_trips", round_trips > 0,
             f"{round_trips} locations name a mission")

    # Locations 3 and 6 load each other's map -- shipped behaviour, pinned.
    ck.expect("graph.upgrade_3_6_crossed",
              (tables.upgrade.get(3), tables.upgrade.get(6)), (6, 3))
    ck.expect("graph.campaign2_start_opens", tables.open_locations(40), [90],
              "a fresh campaign 2 opens no upgrade location")
    ck.expect("graph.campaign1_start_opens", tables.open_locations(1),
              [1, 10, 51])


def check_deployment(ck: Checker, ctx: Context) -> None:
    """``docs/29`` §1.2 -- deployment is ``action_point == player + 1``.

    Not ``start_index``: that is ``+0x14``, the VictoryPoints band 80..85 that
    ``docs/10`` §4.2 marks *only Multiplayer*.
    """
    missions = ctx.missions
    want = 0 + DEPLOYMENT_ACTION_POINT_BIAS
    counts: dict[str, int] = {}
    for name, battle in sorted(missions.items()):
        counts[name] = sum(1 for c in battle.cells if c.action_point == want)
    with_cells = {n: c for n, c in counts.items() if c}
    ck.expect("deploy.missions_with_cells",
              (len(with_cells), len(counts)), (73, 75),
              "the corpus sweep behind docs/98's premise")
    # The two exceptions, each with the reason it is exempt rather than a
    # tolerance that would swallow a third.
    without = sorted(n for n, c in counts.items() if not c)
    ck.expect("deploy.exceptions", without, ["_C_131", EPILOGUE[0]])
    ck.expect("deploy.epilogue_has_none", counts[EPILOGUE[0]], 0)
    ck.check("deploy.exception_ships_its_own_squad",
             any(u.placed and u.player == 0 for u in missions["_C_131"].units),
             "_C_131 needs no deployment cell because it places a squad itself")
    ck.check("deploy.epilogue_has_no_squad",
             not any(u.placed and u.player == 0
                     for u in missions[EPILOGUE[0]].units),
             "the epilogue is not played")
    over = {n: c for n, c in counts.items() if c > DEPLOYMENT_RING_RECORDS}
    ck.expect("deploy.never_over_the_ring", over, {},
              f"the header's ring holds {DEPLOYMENT_RING_RECORDS} records")
    for name in ("_C_115", "_C_141"):
        ck.check(f"deploy.{name}", counts.get(name, 0) > 0,
                 f"{counts.get(name, 0)} cells")

    # The slice's premise: most campaign missions ship no placed player-0
    # squad, which is why the roster has to put one there.
    placed = sum(1 for b in missions.values()
                 if any(u.placed and u.player == 0 for u in b.units))
    ck.expect("deploy.missions_shipping_a_squad", (placed, len(missions)),
              (31, 75),
              "the other 44 do not start at all without deployment")


def check_start_fields_are_not_deployment(ck: Checker, ctx: Context) -> None:
    """``+0x14`` is a different band, and the corpus shows it."""
    both = 0
    for battle in ctx.missions.values():
        for cell in battle.cells:
            if cell.is_start_field and cell.action_point == 1:
                both += 1
    ck.expect("deploy.start_index_is_a_different_band", both, 0,
              "no cell is both a VictoryPoint and deployment cell")


# --- the fixture --------------------------------------------------------------

def build_cases(root: Path) -> dict[str, Any]:
    """The document ``godot/tests/test_campaign.gd`` replays."""
    ctx = Context.load(root)
    corpus, binary = ctx.corpus, ctx.binary
    tables, missions, cost = ctx.tables, ctx.missions, ctx.cost

    seed_states = {str(n): ctx.begin(n).to_dict() for n in (1, 2)}

    scores = []
    for difficulty in range(len(cam.DIFFICULTY_MULTIPLIER)):
        for result in range(1, 6):
            for kills, losses in ((0, 0), (7, 2), (19, 0)):
                state = ctx.begin(2)
                state.difficulty = difficulty
                board = state.scoreboard[0]
                board.kills, board.losses, board.result = kills, losses, result
                report = state.score_mission()[0]
                scores.append({
                    "difficulty": difficulty, "result": result,
                    "kills": kills, "losses": losses,
                    "score": report["score"], "total": report["total"],
                })

    payouts = []
    for mode in (cam.MODE_CAMPAIGN, 2):
        for result in (1, 2, 5):
            state = ctx.begin(2)
            state.mode = mode
            state.game_control[cam.SLOT_EQUIPMENT_POINTS] = 250
            state.game_control[cam.SLOT_COMMENDATIONS] = 2
            state.scoreboard[0].result = result
            report = state.score_mission()[0]
            payouts.append({
                "mode": mode, "result": result,
                "equipment_points": report["equipment_points"],
                "commendations": report["commendations"],
                "purse": state.equipment_points[0],
            })

    sorts = []
    for layout in ([(0, 10), (1, 40), (2, 20), (3, 70)],
                   [(0, 10), (1, 40), (3, 70), (4, 20)],
                   [(2, 5), (3, 5), (4, 90)]):
        roster = cam.Roster()
        for slot, ep in layout:
            rec = cam.PoolRecord()
            rec.hit_points = 5
            rec.ep = ep
            rec.name = f"u{slot}"
            roster.row(cam.ROW_LIVE)[slot] = rec
        roster.sort_by_ep()
        sorts.append({"before": [list(p) for p in layout],
                      "after": [[i, r.ep] for i, r in roster.occupied()]})

    economy = []
    state = ctx.begin(2)
    economy.append({"step": "start", "purse": state.equipment_points[0],
                    "used": state.roster.used_slots()})
    state.recruit(0, weapon_zero_cost=cost, speech=1)
    economy.append({"step": "recruit", "purse": state.equipment_points[0],
                    "used": state.roster.used_slots()})
    state.dismiss(0, 0)
    economy.append({"step": "dismiss", "purse": state.equipment_points[0],
                    "used": state.roster.used_slots()})
    state.set_points(0, 9990)
    state.add_points(0, 100)
    economy.append({"step": "cap", "purse": state.equipment_points[0],
                    "used": state.roster.used_slots()})

    deployment = {name: sorted((c.x, c.y) for c in battle.cells
                               if c.action_point == 1)
                  for name, battle in missions.items()}

    return {
        "schema": "incubation.campaign-cases/1",
        "recruit_hit_points": ctx.hp,
        "oracle": "executable-Python",
        "recruit_cost": cost + cam.RECRUIT_MARKUP,
        "weapon_zero_cost": cost,
        "seed": seed_states,
        "squad_fields": [{"record": r, "offset": o, "value": v}
                         for (r, o), v in sorted(binary.squad_fields().items())],
        "scores": scores,
        "payouts": payouts,
        "sorts": sorts,
        "economy": economy,
        "survival": _survival_cases(),
        "banks": _bank_cases(ctx),
        "tables": tables.to_records(),
        "chain": {name: battle.next_map for name, battle in missions.items()},
        "mission_ids": {name: battle.mission_id
                        for name, battle in missions.items()},
        "deployment_cells": {k: [list(p) for p in v]
                             for k, v in deployment.items()},
        "script_overrides": sorted(set(corpus.next_map_calls)),
    }


def _survival_cases() -> list[dict[str, Any]]:
    out = []
    for flag, reason in ((0, cam.DROP_NOT_CANDIDATE), (1, None), (2, None)):
        roster = cam.Roster()
        rec = cam.PoolRecord()
        rec.hit_points = 7
        rec.name = "u"
        rec.pool_flag = flag
        kept, dropped = cam.recover_units(roster, [rec], player=0)
        out.append({"pool_flag": flag, "kept": len(kept),
                    "reason": dropped[0]["reason"] if dropped else reason})
    full = cam.Roster()
    for i in range(cam.POOL_USABLE_SLOTS):
        rec = cam.PoolRecord()
        rec.hit_points = 7
        rec.pool_flag = 1
        rec.name = f"u{i}"
        full.row(cam.ROW_LIVE)[i] = rec
    late = cam.PoolRecord()
    late.hit_points = 7
    late.pool_flag = 1
    late.name = "late"
    kept, dropped = cam.recover_units(full, [late], player=0)
    out.append({"pool_flag": 1, "kept": len(kept), "full": True,
                "reason": dropped[0]["reason"] if dropped else None})
    return out


def _bank_cases(ctx: "Context") -> list[dict[str, Any]]:
    roster = ctx.begin(1).roster
    out = [{"step": "start", "live": roster.used_slots(cam.ROW_LIVE),
            "snapshot": roster.used_slots(cam.ROW_SNAPSHOT)}]
    roster.snapshot()
    out.append({"step": "snapshot", "live": roster.used_slots(cam.ROW_LIVE),
                "snapshot": roster.used_slots(cam.ROW_SNAPSHOT)})
    for slot in range(3):
        roster.row(cam.ROW_LIVE)[slot] = cam.PoolRecord()
    out.append({"step": "deployed", "live": roster.used_slots(cam.ROW_LIVE),
                "snapshot": roster.used_slots(cam.ROW_SNAPSHOT)})
    roster.restore()
    out.append({"step": "restore", "live": roster.used_slots(cam.ROW_LIVE),
                "snapshot": roster.used_slots(cam.ROW_SNAPSHOT)})
    roster.clear_snapshot()
    out.append({"step": "debriefing_over",
                "live": roster.used_slots(cam.ROW_LIVE),
                "snapshot": roster.used_slots(cam.ROW_SNAPSHOT)})
    return out


# --- the saves, outside the always-run block ---------------------------------

#: ``docs/11`` §5.2 -- the GameControl block starts here in the file.
SAVE_GAME_CONTROL = 261
SAVE_POOL = 2081
GC = 0x00509D18


def _dword(data: bytes, va: int) -> int:
    return struct.unpack_from("<i", data, SAVE_GAME_CONTROL + va - GC)[0]


def _byte(data: bytes, va: int) -> int:
    return data[SAVE_GAME_CONTROL + va - GC]


def check_saves(ck: Checker, directory: Path) -> None:
    """The model against the six real saves -- ``docs/27`` §2.2 and §2.4.

    Outside the always-run block: the files are gitignored, so this fails
    loudly when they are absent rather than passing on nothing.
    """
    saves = sorted(directory.glob("*.sav"))
    if not saves:
        LOG.error("%s holds no .sav -- see tests/fixtures/saves/README.md",
                  directory)
        return
    for path in saves:
        data = path.read_bytes()
        name = path.stem
        ck.expect(f"save.{name}.campaign", _byte(data, GC + 0x1D1), 2,
                  "every fixture is a campaign-2 session")
        ck.expect(f"save.{name}.tech", _byte(data, 0x00509F04),
                  cam.CAMPAIGN_START_TECH_LEVEL,
                  "0x0043AEBB writes 1 and nothing in a campaign writes it again")
        ck.expect(f"save.{name}.skill", _dword(data, 0x00509F00),
                  cam.CAMPAIGN_START_SKILL_LEVEL)
        ck.expect(f"save.{name}.player_count", _byte(data, 0x00509E30),
                  cam.CAMPAIGN_PLAYER_COUNT)
        ck.expect(f"save.{name}.equipment_points_0",
                  _dword(data, 0x00509EEC),
                  cam.CAMPAIGN_START_EQUIPMENT_POINTS,
                  "the campaign arm writes player 0 alone")
        ck.expect(f"save.{name}.player_kind", [_dword(data, 0x00509E20 + 4 * i)
                                               for i in range(4)],
                  [1, 0, 0, 0])
        for player in range(cam.PLAYER_SLOTS):
            base = 0x00509F48 + cam.SCOREBOARD_STRIDE * player
            ck.expect(f"save.{name}.board{player}.result",
                      _dword(data, base + 0x20), cam.RESULT_NOTHING,
                      "resetScoreboard's value; no fixture was saved after a "
                      "debriefing")
            ck.expect(f"save.{name}.board{player}.score",
                      _dword(data, base + 0x18), 0)
            # The four pairs. Every mission half is zero -- these saves were
            # taken at a mission's start or on the map screen, never after a
            # kill was scored except `_2_`, which is mid-mission.
            lost = _dword(data, base + 0x08)
            lost_to_enemy = _dword(data, base + 0x10)
            ck.check(f"save.{name}.board{player}.lost_is_a_superset",
                     lost >= lost_to_enemy,
                     f"{lost} lost, {lost_to_enemy} of them to an enemy -- "
                     "0x0043B8D0 fires on every death and 0x0043B860 only "
                     "where 0x0043B810 does")
            campaign_lost = _dword(data, base + 0x0C)
            campaign_to_enemy = _dword(data, base + 0x14)
            ck.check(f"save.{name}.board{player}.campaign_lost_is_a_superset",
                     campaign_lost >= campaign_to_enemy,
                     f"{campaign_lost} over the campaign, "
                     f"{campaign_to_enemy} to an enemy")
            ck.check(f"save.{name}.board{player}.pairs_are_ordered",
                     _dword(data, base + 0x04) >= _dword(data, base + 0x00),
                     "the campaign half of a pair is at least its mission half")

    # The two rows, which is what settles docs/27 3.5's naming.
    rows = {}
    for path in saves:
        data = path.read_bytes()
        occupied = {0: [], 1: []}
        for record in range(60):
            off = SAVE_POOL + record * cam.POOL_RECORD_SIZE
            if data[off + cam.OFF_HIT_POINTS]:
                label = bytes(data[off:off + cam.NAME_SIZE]).split(b"\0")[0]
                occupied[record // cam.POOL_ROW_SLOTS].append(
                    label.decode("latin1"))
        rows[path.stem] = occupied

    def expect_rows(stem: str, live: list[str], snapshot: list[str],
                    why: str) -> None:
        if stem not in rows:
            ck.check(f"save.rows.{stem}", False, "fixture absent")
            return
        ck.expect(f"save.rows.{stem}", rows[stem], {0: live, 1: snapshot}, why)

    expect_rows("_5_", ["Sgt. Bratt"], [],
                "the map screen: the snapshot is already gone")
    expect_rows("_31_", ["Sgt. Bratt"], ["Sgt. Bratt"],
                "the mission-entry snapshot, both rows equal")
    for stem in ("_6_", "_33_"):
        expect_rows(stem, [], ["Sgt. Bratt"],
                    "inside the mission: row 0 is empty because deployment "
                    "took from it, so row 0 is the live bank")


# --- the run ------------------------------------------------------------------

def run_check(root: Path) -> int:
    ck = Checker()
    ctx = Context.load(root)
    if not ctx.missions:
        LOG.error("%s holds no campaign missions -- is this the game root?", root)
        return 1

    check_constants(ck, ctx.binary)
    check_seed(ck, ctx)
    check_economy(ck, ctx)
    check_sort(ck)
    check_banks(ck, ctx)
    check_survival(ck)
    check_score(ck, ctx)
    check_chain(ck, ctx)
    check_graph(ck, ctx)
    check_deployment(ck, ctx)
    check_start_fields_are_not_deployment(ck, ctx)
    return ck.report(quiet_ok=True)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", metavar="ROOT", help="game root")
    ap.add_argument("--check-saves", metavar="DIR", type=Path,
                    help="verify the model against real .sav fixtures")
    ap.add_argument("--emit-cases", metavar="FILE", type=Path,
                    help="write the fixture test_campaign.gd replays")
    ap.add_argument("--root", metavar="ROOT", help="game root for --emit-cases")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    logging.basicConfig(
        level=logging.INFO if args.verbose else logging.WARNING,
        format="%(levelname)s: %(message)s")

    if not any((args.check, args.check_saves, args.emit_cases)):
        ap.error("nothing to do: pass --check, --check-saves or --emit-cases")

    code = 0
    if args.check:
        code = run_check(Path(args.check)) or code
    if args.check_saves is not None:
        ck = Checker()
        check_saves(ck, args.check_saves)
        code = ck.report(quiet_ok=True) or code
    if args.emit_cases is not None:
        if not args.root:
            ap.error("--emit-cases needs --root")
        document = build_cases(Path(args.root))
        args.emit_cases.parent.mkdir(parents=True, exist_ok=True)
        args.emit_cases.write_text(json.dumps(document, indent=1, sort_keys=True))
        print(f"wrote {args.emit_cases}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())

"""The campaign layer as an executable model -- ``docs/27``.

This is the Python twin of ``godot/core/campaign/``: the unit pool and its two
rows, the equipment-point economy, the score and the payouts, the location
graph and the mission chain.  ``tools/campaign_runtime.py`` runs it over the
corpus and emits the fixture the GDScript suite replays, so the two
implementations are compared rather than merely written twice.

Three things here are **not** what a first reading of ``docs/27`` gives, and
each is measured -- see ``docs/98``:

* **Row 0 is the live roster and row 1 is the mission-entry snapshot.**
  ``docs/27`` §3.5 named row 1 "the mission's working copy"; the four saves
  that carry a pool say otherwise -- inside a mission row 0 is *empty* because
  deployment removed the records from it, and row 1 still holds them.
* **A clean campaign start is a choice of two chains, not one.**  Campaign 1
  seeds Bratt/West/Maxon and begins at ``_C_100``; campaign 2 seeds nothing and
  begins at ``_C_140``.  Both are written into ``0x0043AE76`` as a switch on
  the campaign number.
* **The tech level does not grow.**  ``0x00509F04`` has four ``.text``
  references in the whole image, and the campaign's is a single ``= 1`` at
  start-up.  The five ``setTechLevel`` call sites are the single-mission front
  end, which is what the mission header's ``+0x21E`` is for.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Iterable

LOG = logging.getLogger(__name__)

# --- the pool's storage -- docs/27 section 3, docs/10 section 5.11 -----------

#: ``aUnit[5][31]`` at ``0x0051F2A0``: 91-byte records, 31 per row.
POOL_RECORD_SIZE = 0x5B
POOL_ROW_SLOTS = 31
#: 30 are addressable; the 31st is the scratch ``aRemoveUnitFromUnitPool``
#: compacts into (``docs/11`` §5.7).
POOL_USABLE_SLOTS = 30
POOL_ROWS = 5

#: The live roster, and the snapshot taken on entering a mission.
ROW_LIVE = 0
ROW_SNAPSHOT = 1

# Record offsets the campaign layer reads or writes.
OFF_NAME = 0x00
NAME_SIZE = 16
OFF_ACTION_POINTS = 0x15
#: A zero HP byte *is* the free-slot marker -- the same convention an unplaced
#: unit uses in a ``.lev``.
OFF_HIT_POINTS = 0x16
OFF_EP = 0x17
OFF_TP = 0x18
OFF_FP = 0x19
OFF_SKILLS = 0x1A
SKILL_COUNT = 6
OFF_EQUIPMENT = 0x21
EQUIPMENT_COUNT = 21
OFF_DECORATIONS = 0x38
OFF_AMMO = 0x3D
OFF_WEAPON = 0x3F
OFF_X = 0x42
OFF_Y = 0x43
OFF_PLAYER = 0x45
OFF_UNIT_TYPE = 0x4C
#: 0 dropped at mission end, 1 pool candidate, 2 hero.
OFF_POOL_FLAG = 0x4D
OFF_SPEECH = 0x55
#: The cached resale value, in tens of equipment points.
OFF_RESALE = 0x5A

#: ``docs/10`` §5.11 -- rank is EP over this, and ``aEnlargeUnitPool`` scales a
#: starting rank by it.
EP_PER_RANK = 12
#: ``aEnlargeUnitPool``'s floor: a recruit below rank 3 still gets 3 FP.
FP_FLOOR = 3

#: ``0x00478A47``.
RECRUIT_NAME_FORMAT = "Soldier %d"
#: ``0x00478AEB`` / ``0x00478AE3`` -- ``aRandom(1, 6)``.
SPEECH_BASE, SPEECH_SPAN = 1, 6

# --- the economy -- docs/27 section 5 ----------------------------------------

#: ``0x0043B010`` clamps the add here.
EQUIPMENT_POINT_CAP = 10000
#: ``0x0045B821`` -- the markup over weapon 0's cost, in both the recruit price
#: and the resale formula, which is why dismissing a fresh recruit is free.
#: ``0x004776E0`` -- the Jet Pack (item 7) sets item 1's flag for nothing
#: (``0x00475601``), and the kit value takes item 1's cost back off for it.
JET_PACK_ID = 7
JET_PACK_GRANTS = 1
RECRUIT_MARKUP = 50
#: ``+0x5A`` is stored in tens.
RESALE_SCALE = 10

# --- game control -- docs/11 section 5.2 -------------------------------------

PLAYER_SLOTS = 4
MODE_CAMPAIGN = 1

#: ``0x00509F48``, stride 40, one per player slot.
SCOREBOARD_STRIDE = 40
#: The value ``resetScoreboard`` writes into ``+0x20``: "nothing happened".
RESULT_NOTHING = 1
RESULT_DEFEAT = 5
#: ``0x0043BBB8``, indexed by ``missionResult - 1`` -- ``docs/27`` §6.2.
RESULT_BASE_SCORE = (0, 100, 200, 300, -100)
#: ``0x0043BAC8`` -- ``0x00460450``'s three settings.
DIFFICULTY_MULTIPLIER = (1, 2, 3)
#: ``docs/20`` §7 -- the two payout slots.
SLOT_EQUIPMENT_POINTS = 10
SLOT_COMMENDATIONS = 11

# --- campaign start -- 0x0043AE76 --------------------------------------------

#: The campaign arm writes exactly these, for player 0 alone: its loop bound is
#: the player count, which it sets to 1.
CAMPAIGN_PLAYER_COUNT = 1
CAMPAIGN_START_EQUIPMENT_POINTS = 100
CAMPAIGN_START_TECH_LEVEL = 1
CAMPAIGN_START_SKILL_LEVEL = 0
CAMPAIGN_START_COMMENDATIONS = 0
#: ``0x0043AF57`` and ``0x0043AF2A``.
CAMPAIGN_FIRST_MISSION = {1: "_C_100", 2: "_C_140"}
#: ``docs/27`` §2.1 -- the campaign map each chain draws its locations on.
CAMPAIGN_MAP = {1: "_C_XXX", 2: "_C_YYY"}

#: ``docs/27`` §2.2 -- ``location = missionId + 50``.
LOCATION_BIAS = 50

#: ``docs/27`` §3.1 -- the three seeded records, decoded from
#: ``0x0047883B``..``0x004788A5``.  ``skills`` is by index into ``+0x1A``.
SEED_TEXT_BANK = 3
SEED_TEXT_IDS = (0x3C, 0x3D, 0x3E)
SEED_NAMES = ("Bratt", "West", "Maxon")
HERO_UNIT_TYPE = 0x17
HERO_POOL_FLAG = 2
MEDIC_EQUIPMENT_ID = 15


class CampaignError(Exception):
    """Raised when a campaign rule is asked for something it refuses."""


def _seed_records() -> tuple[dict[str, Any], ...]:
    """``docs/27`` §3.1's table, as the writes the engine performs."""
    return (
        {"ep": 17, "tp": 0, "skills": {1: 1, 5: 2}, "unit_type": HERO_UNIT_TYPE,
         "pool_flag": HERO_POOL_FLAG, "speech": 10, "equipment": ()},
        {"ep": 12, "tp": 0, "skills": {4: 2}, "unit_type": None,
         "pool_flag": 1, "speech": 3, "equipment": (MEDIC_EQUIPMENT_ID,)},
        {"ep": 12, "tp": 12, "skills": {2: 1}, "unit_type": None,
         "pool_flag": 1, "speech": 4, "equipment": ()},
    )


SEED_RECORDS = _seed_records()


# --- one roster record -------------------------------------------------------

def kit_value(weapon_cost: int, rec: "PoolRecord",
              equipment_costs: dict[int, int]) -> int:
    """``0x004776E0`` -- what a weapon purchase caches in ``+0x5A``.

    The weapon's cost, plus every carried item's (``+0x21..+0x35`` walked
    against the 21 equipment records), less item 1's when ``+0x28`` -- the
    Jet Pack -- is set, plus the recruit markup, in tens.
    """
    total = weapon_cost
    for item in range(EQUIPMENT_COUNT):
        if rec.has_equipment(item):
            total += equipment_costs.get(item, 0)
    if rec.has_equipment(JET_PACK_ID):
        total -= equipment_costs.get(JET_PACK_GRANTS, 0)
    return (total + RECRUIT_MARKUP) // RESALE_SCALE


class PoolRecord:
    """One 91-byte roster slot.

    Held as raw bytes on purpose: ``aAddUnitToUnitPool`` copies the record
    verbatim, and a model that carried only the fields it understands would
    silently drop what a mission wrote into the rest.
    """

    __slots__ = ("raw",)

    def __init__(self, raw: bytes | bytearray | None = None) -> None:
        if raw is None:
            self.raw = bytearray(POOL_RECORD_SIZE)
        else:
            if len(raw) != POOL_RECORD_SIZE:
                raise CampaignError(
                    f"a pool record is {POOL_RECORD_SIZE} bytes, got {len(raw)}")
            self.raw = bytearray(raw)

    # -- scalar fields --------------------------------------------------------

    def _get(self, off: int) -> int:
        return self.raw[off]

    def _set(self, off: int, value: int) -> None:
        if not 0 <= value <= 0xFF:
            raise CampaignError(f"byte field at +{off:#04x} out of range: {value}")
        self.raw[off] = value

    @property
    def name(self) -> str:
        return bytes(self.raw[OFF_NAME:OFF_NAME + NAME_SIZE]).split(b"\0")[0].decode(
            "latin1")

    @name.setter
    def name(self, value: str) -> None:
        encoded = value.encode("latin1")[:NAME_SIZE - 1]
        self.raw[OFF_NAME:OFF_NAME + NAME_SIZE] = encoded.ljust(NAME_SIZE, b"\0")

    hit_points = property(lambda s: s._get(OFF_HIT_POINTS),
                          lambda s, v: s._set(OFF_HIT_POINTS, v))
    ep = property(lambda s: s._get(OFF_EP), lambda s, v: s._set(OFF_EP, v))
    tp = property(lambda s: s._get(OFF_TP), lambda s, v: s._set(OFF_TP, v))
    fp = property(lambda s: s._get(OFF_FP), lambda s, v: s._set(OFF_FP, v))
    ammo = property(lambda s: s._get(OFF_AMMO),
                    lambda s, v: s._set(OFF_AMMO, v))
    weapon = property(lambda s: s._get(OFF_WEAPON),
                      lambda s, v: s._set(OFF_WEAPON, v))
    player = property(lambda s: s._get(OFF_PLAYER),
                      lambda s, v: s._set(OFF_PLAYER, v))
    unit_type = property(lambda s: s._get(OFF_UNIT_TYPE),
                         lambda s, v: s._set(OFF_UNIT_TYPE, v))
    pool_flag = property(lambda s: s._get(OFF_POOL_FLAG),
                         lambda s, v: s._set(OFF_POOL_FLAG, v))
    speech = property(lambda s: s._get(OFF_SPEECH),
                      lambda s, v: s._set(OFF_SPEECH, v))
    resale = property(lambda s: s._get(OFF_RESALE),
                      lambda s, v: s._set(OFF_RESALE, v))

    @property
    def occupied(self) -> bool:
        """``docs/27`` §3.2 -- a zero HP byte is the free-slot marker."""
        return self.hit_points != 0

    @property
    def rank(self) -> int:
        return self.ep // EP_PER_RANK

    def skill(self, index: int) -> int:
        return self.raw[OFF_SKILLS + index]

    def set_skill(self, index: int, value: int) -> None:
        if not 0 <= index < SKILL_COUNT:
            raise CampaignError(f"skill index {index} out of range")
        self._set(OFF_SKILLS + index, value)

    def has_equipment(self, item: int) -> bool:
        return self.raw[OFF_EQUIPMENT + item] != 0

    def set_equipment(self, item: int, carried: bool) -> None:
        if not 0 <= item < EQUIPMENT_COUNT:
            raise CampaignError(f"equipment id {item} out of range")
        self._set(OFF_EQUIPMENT + item, 1 if carried else 0)

    def clone(self) -> "PoolRecord":
        return PoolRecord(self.raw)

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "hit_points": self.hit_points,
            "ep": self.ep,
            "tp": self.tp,
            "fp": self.fp,
            "rank": self.rank,
            "ammo": self.ammo,
            "weapon": self.weapon,
            "player": self.player,
            "unit_type": self.unit_type,
            "pool_flag": self.pool_flag,
            "speech": self.speech,
            "resale": self.resale,
            "skills": [self.skill(i) for i in range(SKILL_COUNT)],
            "equipment": [i for i in range(EQUIPMENT_COUNT) if self.has_equipment(i)],
        }


# --- the two rows ------------------------------------------------------------

class Roster:
    """``aUnit[5][31]``, but only the rows and slots the campaign addresses."""

    def __init__(self) -> None:
        self.rows: list[list[PoolRecord]] = [
            [PoolRecord() for _ in range(POOL_ROW_SLOTS)] for _ in range(POOL_ROWS)]

    # -- queries --------------------------------------------------------------

    def row(self, index: int) -> list[PoolRecord]:
        if not 0 <= index < POOL_ROWS:
            raise CampaignError(f"pool row {index} out of range")
        return self.rows[index]

    def occupied(self, row: int = ROW_LIVE) -> list[tuple[int, PoolRecord]]:
        """Every used slot of a row, in slot order."""
        return [(i, r) for i, r in enumerate(self.row(row)[:POOL_USABLE_SLOTS])
                if r.occupied]

    def free_slots(self, row: int = ROW_LIVE) -> int:
        """``0x004788C0``."""
        return sum(1 for r in self.row(row)[:POOL_USABLE_SLOTS] if not r.occupied)

    def used_slots(self, row: int = ROW_LIVE) -> int:
        """``0x00478960``."""
        return POOL_USABLE_SLOTS - self.free_slots(row)

    def first_free(self, row: int = ROW_LIVE) -> int | None:
        for i, r in enumerate(self.row(row)[:POOL_USABLE_SLOTS]):
            if not r.occupied:
                return i
        return None

    # -- mutation -------------------------------------------------------------

    def enlarge(self, player: int, *, mode: int, skill_level: int,
                weapon_cost: int, speech: int, hit_points: int, ammo: int = 0,
                row: int = ROW_LIVE) -> int | None:
        """``aEnlargeUnitPool`` ``0x004789B0`` -- seed the first free slot.

        Returns the slot, or ``None`` when the row is full.  *speech* is the
        caller's draw: ``docs/27`` §3.2 has the engine call ``aRandom(1, 6)``
        here, and which generator that is belongs to the caller (D8).

        *hit_points* and *ammo* are what the closing ``recomputeUnitStats``
        (``0x004759E0``, called at ``0x00478B4A``) leaves -- the unit type's
        ``hp_max`` and weapon 0's ``mun`` from ``Info.lcl``.  They are
        arguments rather than constants because this model holds no balance
        tables, and because a zero HP byte **is** the free-slot marker: a
        recruit the model left at zero would be seeded into its own slot again
        by the next call.  The pool row of every ``.sav`` fixture carries the
        magazine: Sgt. Bratt reads ``+0x3D = 10`` beside ``+0x3F = 2``, and
        weapon 2's ``mun`` is 10.
        """
        if hit_points <= 0:
            raise CampaignError(
                "a recruit needs non-zero hit points -- zero is the free-slot "
                "marker")
        slot = self.first_free(row)
        if slot is None:
            return None
        rank = 0 if mode == MODE_CAMPAIGN else skill_level
        rec = PoolRecord()
        rec.name = RECRUIT_NAME_FORMAT % (slot + 1)
        rec.unit_type = player
        rec.ep = rank * EP_PER_RANK
        rec.tp = rank * EP_PER_RANK
        rec.fp = FP_FLOOR if rank < FP_FLOOR else rank
        rec.weapon = 0
        rec.player = player
        rec.pool_flag = 1
        rec.resale = (weapon_cost + RECRUIT_MARKUP) // RESALE_SCALE
        rec.speech = speech
        rec.hit_points = hit_points
        rec.ammo = ammo
        self.row(row)[slot] = rec
        return slot

    def dismiss(self, slot: int, row: int = ROW_LIVE) -> int:
        """``aRemoveUnitFromUnitPool`` ``0x00478B70`` -- shift down and refund.

        Returns the equipment points refunded, ``+0x5A * 10``.
        """
        if not 0 <= slot < POOL_USABLE_SLOTS:
            raise CampaignError(f"pool slot {slot} out of range")
        records = self.row(row)
        refund = records[slot].resale * RESALE_SCALE
        for i in range(slot, POOL_ROW_SLOTS - 1):
            records[i] = records[i + 1]
        # The 31st slot is the scratch the compaction shifts into; the engine
        # zeroes its HP byte rather than the whole record.
        records[POOL_ROW_SLOTS - 1] = PoolRecord()
        return refund

    def add(self, record: PoolRecord, row: int = ROW_LIVE) -> int | None:
        """``aAddUnitToUnitPool`` ``0x00478C10`` -- verbatim into the first free
        slot, or ``None`` when the row is full.

        The re-randomisation of ``+0x55`` fires only with more than one human
        player or in a net session, so in a campaign a soldier keeps their
        voice and this copy is exact.
        """
        slot = self.first_free(row)
        if slot is None:
            return None
        self.row(row)[slot] = record.clone()
        return slot

    def sort_by_ep(self, row: int = ROW_LIVE) -> None:
        """``0x00478630`` -- a bubble sort, descending by ``+0x17``.

        Pairs where **either** record has a zero HP byte are skipped, so the
        free slots do not migrate and the used ones do not sort past them.
        Reproduced as the same pass rather than as a `sorted()` call, because
        the skip makes the result depend on the traversal.
        """
        records = self.row(row)
        for _ in range(POOL_USABLE_SLOTS):
            for i in range(POOL_USABLE_SLOTS - 1):
                a, b = records[i], records[i + 1]
                if not a.occupied or not b.occupied:
                    continue
                if a.ep < b.ep:
                    records[i], records[i + 1] = b, a

    def copy_row(self, source: int, destination: int) -> None:
        """``aCopyUnitPool`` ``0x00478910`` -- 2730 bytes, one usable row."""
        src = self.row(source)
        dst = self.row(destination)
        for i in range(POOL_USABLE_SLOTS):
            dst[i] = src[i].clone()

    def snapshot(self) -> None:
        """Entering a mission: ``aCopyUnitPool(0, 1)`` at ``0x0045A914``."""
        self.copy_row(ROW_LIVE, ROW_SNAPSHOT)

    def restore(self) -> None:
        """The debriefing's *back to the map* button: ``aCopyUnitPool(1, 0)``
        at ``0x0045E9D9`` -- the pre-mission roster, so a replay."""
        self.copy_row(ROW_SNAPSHOT, ROW_LIVE)

    def clear_snapshot(self) -> None:
        """What the campaign map's state says happened by the time it is drawn.

        ``_5_.sav`` is on the map screen with row 1 **empty**, though neither
        debriefing button clears it.  What clears it is not traced; that the
        snapshot does not outlive the debriefing is what the save shows, and it
        is why *replay* is a debriefing button rather than a map one.
        """
        self.rows[ROW_SNAPSHOT] = [PoolRecord() for _ in range(POOL_ROW_SLOTS)]


# --- the scoreboard ----------------------------------------------------------

@dataclass
class ScoreRecord:
    """One player's 40-byte scoreboard record -- ``docs/11`` §5.5.

    The record is **four pairs**, each "this mission" beside "the campaign",
    which is what the debriefing's two reading passes show
    (``0x0045DF24``..``0x0045E44B`` read ``+0x1C/+0x14/+0x0C/+0x04`` and then
    ``+0x18/+0x10/+0x08/+0x00``):

    ===================  =======  ========  ============================
    Pair                 Mission  Campaign  Written by
    ===================  =======  ========  ============================
    kills                ``+0x00``  ``+0x04``  ``0x0043B810``, the shooter's
    lost                 ``+0x08``  ``+0x0C``  ``0x0043B8D0``, all 11 deaths
    lost to an enemy     ``+0x10``  ``+0x14``  ``0x0043B860``
    score                ``+0x18``  ``+0x1C``  the scorer ``0x0043BA10``
    ===================  =======  ========  ============================

    ``+0x24`` is the hero counter ``aRemoveUnitElement`` keeps and the LCL
    predicate ``HeroKilled`` reads (``0x004409E0``).
    """

    kills: int = 0                  # +0x00
    campaign_kills: int = 0         # +0x04
    losses: int = 0                 # +0x08
    campaign_losses: int = 0        # +0x0C
    lost_to_enemy: int = 0          # +0x10
    campaign_lost_to_enemy: int = 0  # +0x14
    score: int = 0                  # +0x18
    total: int = 0                  # +0x1C
    result: int = RESULT_NOTHING    # +0x20
    heroes_lost: int = 0            # +0x24

    def reset_mission(self) -> None:
        """Zero the **mission** half of each pair, leaving the campaign half.

        The engine has no such routine -- ``resetScoreboard`` runs once, at
        campaign start -- but a remake whose campaign state outlives the world
        that carried the counters needs it, and ``reset`` is the wrong tool:
        calling that between missions wipes the campaign totals the debriefing
        has just added to.
        """
        self.kills = self.losses = self.lost_to_enemy = 0
        self.heroes_lost = 0
        self.score = 0
        self.result = RESULT_NOTHING

    def reset(self) -> None:
        """``resetScoreboard`` ``0x0043B990``: zero +0x00..+0x1C, +0x20 = 1.

        **The whole record**, campaign halves included; the engine calls it at
        campaign start and nowhere else.
        """
        self.kills = self.campaign_kills = 0
        self.losses = self.campaign_losses = 0
        self.lost_to_enemy = self.campaign_lost_to_enemy = 0
        self.score = self.total = 0
        self.result = RESULT_NOTHING
        self.heroes_lost = 0

    def to_dict(self) -> dict[str, Any]:
        return {"kills": self.kills, "campaign_kills": self.campaign_kills,
                "losses": self.losses, "campaign_losses": self.campaign_losses,
                "lost_to_enemy": self.lost_to_enemy,
                "campaign_lost_to_enemy": self.campaign_lost_to_enemy,
                "score": self.score, "total": self.total,
                "result": self.result, "heroes_lost": self.heroes_lost}


# --- the whole state ---------------------------------------------------------

@dataclass
class CampaignState:
    """Everything ``docs/27`` §8 item 1 lists, and nothing derived."""

    campaign: int = 2
    mission: str = ""
    #: ``0x00509EEC``, one per player slot.
    equipment_points: list[int] = field(
        default_factory=lambda: [0] * PLAYER_SLOTS)
    #: ``0x00509EFC``.
    commendations: list[int] = field(default_factory=lambda: [0] * PLAYER_SLOTS)
    #: ``0x00509E20`` -- 0 means the slot is not in the game.
    player_kind: list[int] = field(default_factory=lambda: [0] * PLAYER_SLOTS)
    scoreboard: list[ScoreRecord] = field(
        default_factory=lambda: [ScoreRecord() for _ in range(PLAYER_SLOTS)])
    roster: Roster = field(default_factory=Roster)
    difficulty: int = 0
    tech_level: int = CAMPAIGN_START_TECH_LEVEL
    skill_level: int = CAMPAIGN_START_SKILL_LEVEL
    player_count: int = CAMPAIGN_PLAYER_COUNT
    mode: int = MODE_CAMPAIGN
    #: ``docs/20`` §7 -- the twelve slots a mission script writes.
    game_control: list[int] = field(default_factory=lambda: [0] * 12)
    #: ``Info.lcl``'s ``hp_max`` for the recruit's unit type, which is the
    #: player slot (``docs/27`` §3.2's deliberate ``unitType = player``).
    recruit_hit_points: int = 1
    #: ``Info.lcl``'s weapon 0 ``mun``.  ``aEnlargeUnitPool`` gives a recruit
    #: weapon 0 and its closing recompute fills the magazine from it.
    recruit_ammo: int = 0

    # -- start ----------------------------------------------------------------

    @classmethod
    def begin(cls, campaign: int, *, speech: Iterable[int] = (),
              weapon_cost: int = 10, hit_points: int = 1, magazine: int = 0,
              names: Iterable[str] = SEED_NAMES) -> "CampaignState":
        """A new campaign -- ``0x0043AE76`` then ``aCreateUnitPoolForCampaign``.

        The init arm writes for **player 0 alone**: its loop runs to the player
        count, which it has just set to 1.  Slots 1..3 keep whatever the front
        end left in them, which is why real saves read
        ``EP = (100, 2000, 2000, 2000)`` -- the 2000s are the multiplayer arm's
        and the campaign never touched them.
        """
        if campaign not in CAMPAIGN_FIRST_MISSION:
            raise CampaignError(f"no such campaign: {campaign}")
        state = cls(campaign=campaign)
        state.recruit_hit_points = hit_points
        state.recruit_ammo = magazine
        state.player_count = CAMPAIGN_PLAYER_COUNT
        for p in range(state.player_count):
            state.equipment_points[p] = CAMPAIGN_START_EQUIPMENT_POINTS
            state.commendations[p] = CAMPAIGN_START_COMMENDATIONS
            state.scoreboard[p].reset()
        state.tech_level = CAMPAIGN_START_TECH_LEVEL
        state.skill_level = CAMPAIGN_START_SKILL_LEVEL
        # The front end marks player 0 as human; every shipped save reads
        # `used = [1, 0, 0, 0]`.
        state.player_kind[0] = 1
        state.mission = CAMPAIGN_FIRST_MISSION[campaign]
        state.seed_pool(speech=speech, weapon_cost=weapon_cost, names=names)
        return state

    def seed_pool(self, *, speech: Iterable[int] = (), weapon_cost: int = 10,
                  names: Iterable[str] = SEED_NAMES) -> None:
        """``aCreateUnitPoolForCampaign`` ``0x00478710``.

        Campaign 2 is a bare ``return TRUE``: whatever the pool holds is what it
        runs on, which for a clean start is nothing.
        """
        if self.campaign == 2:
            return
        draws = list(speech)
        for i in range(len(SEED_RECORDS)):
            drawn = draws[i] if i < len(draws) else SPEECH_BASE
            slot = self.roster.enlarge(
                0, mode=self.mode, skill_level=self.skill_level,
                weapon_cost=weapon_cost, speech=drawn,
                hit_points=self.recruit_hit_points, ammo=self.recruit_ammo)
            if slot is None:
                raise CampaignError("a fresh pool has no free slot")
        listed = list(names)
        for i, seed in enumerate(SEED_RECORDS):
            rec = self.roster.row(ROW_LIVE)[i]
            rec.name = listed[i] if i < len(listed) else SEED_NAMES[i]
            rec.ep = seed["ep"]
            rec.tp = seed["tp"]
            for index, value in seed["skills"].items():
                rec.set_skill(index, value)
            if seed["unit_type"] is not None:
                rec.unit_type = seed["unit_type"]
            rec.pool_flag = seed["pool_flag"]
            rec.speech = seed["speech"]
            for item in seed["equipment"]:
                rec.set_equipment(item, True)

    # -- the economy -- docs/27 section 5.1 -----------------------------------

    def add_points(self, player: int, amount: int) -> bool:
        """``0x0043B010`` -- clamped at 10000, refused for an empty slot."""
        if not self._slot_in_game(player):
            return False
        self.equipment_points[player] = min(
            EQUIPMENT_POINT_CAP, self.equipment_points[player] + amount)
        return True

    def spend_points(self, player: int, amount: int) -> bool:
        """``0x0043B060`` -- refuses when the purse is short, so never negative."""
        if not self._slot_in_game(player):
            return False
        if self.equipment_points[player] < amount:
            return False
        self.equipment_points[player] -= amount
        return True

    def set_points(self, player: int, amount: int) -> None:
        """``0x0043B0A0``."""
        self.equipment_points[player] = amount

    def _slot_in_game(self, player: int) -> bool:
        return 0 <= player < PLAYER_SLOTS and self.player_kind[player] != 0

    def recruit_cost(self, weapon_zero_cost: int) -> int:
        """``docs/27`` §5.4 -- ``weapon[0].cost + 50``."""
        return weapon_zero_cost + RECRUIT_MARKUP

    def recruit(self, player: int, *, weapon_zero_cost: int,
                speech: int) -> int | None:
        """The Recruit screen's button: price, purse, then ``aEnlargeUnitPool``."""
        cost = self.recruit_cost(weapon_zero_cost)
        if self.equipment_points[player] < cost:
            return None
        if self.roster.first_free() is None:
            return None
        if not self.spend_points(player, cost):
            return None
        return self.roster.enlarge(
            player, mode=self.mode, skill_level=self.skill_level,
            weapon_cost=weapon_zero_cost, speech=speech,
            hit_points=self.recruit_hit_points, ammo=self.recruit_ammo)

    def dismiss(self, player: int, slot: int) -> int:
        """The Recruit screen's other button -- refunds ``+0x5A * 10``."""
        refund = self.roster.dismiss(slot)
        self.add_points(player, refund)
        return refund

    def buy_weapon(self, player: int, slot: int, weapon: int, *,
                   costs: dict[int, int],
                   equipment_costs: dict[int, int] | None = None) -> bool:
        """``docs/27`` §5.3 -- refund the old, spend the new, recompute ``+0x5A``.

        The order is the engine's: the refund at ``0x0045AAC7`` happens first,
        so a swap costs the difference and an upgrade the player cannot quite
        afford outright still goes through.  The recompute is ``0x004776E0``'s
        (:func:`kit_value`), the whole kit and not the weapon alone; a caller
        with no equipment table gets the weapon-only value, which is what an
        unequipped soldier's kit is worth.
        """
        rec = self.roster.row(ROW_LIVE)[slot]
        if not rec.occupied:
            return False
        new_cost = costs.get(weapon, 0)
        self.add_points(player, costs.get(rec.weapon, 0))
        if not self.spend_points(player, new_cost):
            # Put the refund back: the engine's `add` already happened, and a
            # failed spend leaves the player holding it, but the weapon does
            # not change.
            self.spend_points(player, costs.get(rec.weapon, 0))
            return False
        rec.weapon = weapon
        rec.resale = kit_value(new_cost, rec, equipment_costs or {})
        return True

    def buy_equipment(self, player: int, slot: int, item: int, *,
                      cost: int) -> bool:
        """``0x0045A9E9`` -- guarded on the unit's carried-equipment bitmap."""
        rec = self.roster.row(ROW_LIVE)[slot]
        if not rec.occupied or rec.has_equipment(item):
            return False
        if not self.spend_points(player, cost):
            return False
        rec.set_equipment(item, True)
        return True

    # -- the end of a mission -- docs/27 section 6.2 --------------------------

    def score_mission(self) -> list[dict[str, Any]]:
        """``0x0043BA10`` -- the scorer and the two payouts.

        Returns one report per scored player, so a screen can name what
        happened rather than only show the number.
        """
        reports: list[dict[str, Any]] = []
        for player in range(PLAYER_SLOTS):
            if self.player_kind[player] == 0:
                continue
            board = self.scoreboard[player]
            result = board.result
            if not 1 <= result <= len(RESULT_BASE_SCORE):
                raise CampaignError(f"unknown missionresult {result}")
            base = RESULT_BASE_SCORE[result - 1]
            multiplier = 1
            if self.mode == MODE_CAMPAIGN:
                multiplier = DIFFICULTY_MULTIPLIER[self.difficulty]
            score = board.kills * multiplier - 2 * board.losses + base
            board.score = score
            board.total += score
            # The campaign half of each pair accumulates its mission half.
            board.campaign_kills += board.kills
            board.campaign_losses += board.losses
            board.campaign_lost_to_enemy += board.lost_to_enemy
            # ``0x0043B860``'s third increment: every unit lost to an enemy
            # is one commendation for its player (docs/27 section 6.2).  The
            # engine counts it at the death; the model folds it here with the
            # pair's campaign half, which nothing reads in between.
            death_medals = board.lost_to_enemy
            self.commendations[player] = (
                self.commendations[player] + death_medals) & 0xFF
            paid_points = paid_commendations = 0
            if self.mode == MODE_CAMPAIGN and result != RESULT_DEFEAT:
                bonus = self.game_control[SLOT_EQUIPMENT_POINTS]
                if bonus:
                    # What landed, not what the slot said: ``add_points``
                    # caps the purse, and a replay's rollback subtracts this.
                    purse_before = self.equipment_points[player]
                    self.add_points(player, bonus)
                    paid_points = self.equipment_points[player] - purse_before
                medals = self.game_control[SLOT_COMMENDATIONS]
                if medals:
                    self.commendations[player] = (
                        self.commendations[player] + medals) & 0xFF
                    paid_commendations = medals
            reports.append({
                "player": player, "result": result, "base": base,
                "multiplier": multiplier, "kills": board.kills,
                "losses": board.losses, "score": score, "total": board.total,
                "equipment_points": paid_points,
                "commendations": paid_commendations,
                "death_medals": death_medals,
            })
        return reports

    def to_dict(self) -> dict[str, Any]:
        return {
            "campaign": self.campaign,
            "mission": self.mission,
            "equipment_points": list(self.equipment_points),
            "commendations": list(self.commendations),
            "player_kind": list(self.player_kind),
            "difficulty": self.difficulty,
            "tech_level": self.tech_level,
            "skill_level": self.skill_level,
            "player_count": self.player_count,
            "scoreboard": [s.to_dict() for s in self.scoreboard],
            "roster": [
                {"slot": i, **r.to_dict()} for i, r in self.roster.occupied()],
            "snapshot": [
                {"slot": i, **r.to_dict()}
                for i, r in self.roster.occupied(ROW_SNAPSHOT)],
        }


# --- the survival gate -- docs/27 section 3.4 --------------------------------

#: Why a unit that finished the mission alive did not reach the roster.
DROP_NOT_CANDIDATE = "not_a_pool_candidate"
DROP_POOL_FULL = "pool_full"


def recover_units(roster: Roster, units: Iterable[PoolRecord], player: int,
                  ) -> tuple[list[int], list[dict[str, Any]]]:
    """``aTransferAllUnitsFromMapToPool`` ``0x00478E50`` and its gate.

    Returns ``(slots, dropped)``.  Both refusals are silent in the engine --
    it returns TRUE and the unit is gone -- and ``docs/92`` §7.4 decides the
    remake names them instead, which is why they come back as a report.
    """
    slots: list[int] = []
    dropped: list[dict[str, Any]] = []
    for record in units:
        if record.player != player:
            continue
        if record.pool_flag == 0:
            dropped.append({"name": record.name, "reason": DROP_NOT_CANDIDATE})
            continue
        slot = roster.add(record)
        if slot is None:
            dropped.append({"name": record.name, "reason": DROP_POOL_FULL})
            continue
        slots.append(slot)
    return slots, dropped


# --- the location graph -- docs/27 section 2 ---------------------------------

@dataclass(frozen=True)
class LocationTables:
    """``campaign_tables.py --json``, narrowed to what a campaign needs.

    Kept as **lists of records** rather than dictionaries keyed by id: a JSON
    object's key is a string, and the cache the remake reads has to carry
    integers (D12, and the precedent ``inclib/info.py`` set).
    """

    #: location id -> mission basename.
    map_names: dict[int, str]
    #: mission id -> the location ids it opens.
    unlock_graph: dict[int, list[int]]
    #: location id -> the dialogue number its arm passes.
    dialogue: dict[int, int]
    #: location id -> the ``upgrade_N.lev`` it loads.
    upgrade: dict[int, int]
    #: location id -> the ``(low, high)`` tech band that base's shop sells.
    #: ``0x0045BF2A``'s campaign arm reads this pair rather than the campaign
    #: tech level (``docs/27`` §5.2).
    tech_bands: dict[int, tuple[int, int]]

    @classmethod
    def from_json(cls, document: dict[str, Any]) -> "LocationTables":
        # Mission ids 35..39 have no arm -- three missions were cut and the
        # table was not (docs/27 section 2.2), so the decoder emits `null` for
        # them.  They are absent from the graph, not empty in it.
        return cls(
            map_names={int(k): v for k, v in document["map_names"].items()},
            unlock_graph={int(k): [int(pair[0]) for pair in v]
                          for k, v in document["unlock_graph"].items()
                          if v is not None},
            dialogue={int(k): int(v) for k, v in document["dialogue"].items()},
            upgrade={int(k): int(v) for k, v in document["upgrade"].items()},
            tech_bands={int(k): (int(v[0]), int(v[1]))
                        for k, v in document.get("tech_bands", {}).items()},
        )

    def location_of(self, mission_id: int) -> int:
        """``docs/27`` §2.2 -- ``0x004541D5`` and ``0x00455486``."""
        return mission_id + LOCATION_BIAS

    def mission_of(self, location: int) -> str | None:
        """``aMapName`` ``0x0045C200``.  The inverse is a table, not a
        subtraction: ``_C_104`` and ``_C_105`` are crossed."""
        return self.map_names.get(location)

    def open_locations(self, mission_id: int) -> list[int]:
        """``aCreateLocationMap`` ``0x00431420`` -- the map as it looks when
        *mission_id* is the one to play next."""
        return sorted(self.unlock_graph.get(mission_id, []))

    def tech_band(self, location: int) -> tuple[int, int] | None:
        """The band that base sells, or ``None`` where it is not an upgrade
        location."""
        return self.tech_bands.get(location)

    def kind(self, location: int) -> str:
        if location in self.upgrade:
            return "upgrade"
        if location in self.dialogue:
            return "dialogue"
        if location in self.map_names:
            return "battle"
        return "none"

    def to_records(self) -> dict[str, Any]:
        """The cache document -- lists of records, integer ids intact."""
        return {
            "location_bias": LOCATION_BIAS,
            "map_names": [{"location": k, "mission": v}
                          for k, v in sorted(self.map_names.items())],
            "unlock_graph": [{"mission": k, "opens": sorted(v)}
                             for k, v in sorted(self.unlock_graph.items())],
            "dialogue": [{"location": k, "sequence": v}
                         for k, v in sorted(self.dialogue.items())],
            "upgrade": [{"location": k, "map": v,
                         "tech_low": self.tech_bands.get(k, (0, 0))[0],
                         "tech_high": self.tech_bands.get(k, (0, 0))[1]}
                        for k, v in sorted(self.upgrade.items())],
        }


# --- the scoreboard's counters -- 0x0043B810, 0x0043B860, 0x0043B8D0 ---------

#: All three guard the same way before they index the scoreboard.
SCORED_TYPE_MAX = 30
SCORED_TYPE_EXCLUDED = 24


def scores_as_a_loss(type_id: int, player: int) -> bool:
    return (type_id <= SCORED_TYPE_MAX and type_id != SCORED_TYPE_EXCLUDED
            and 0 <= player < PLAYER_SLOTS)


def count_unit_lost(board: list[ScoreRecord], type_id: int,
                    player: int) -> None:
    """``0x0043B8D0`` -- every death of a unit that counts, whatever killed it.

    Eleven callers: the six set-piece killers, ``aAttackUnit``,
    ``aCheckWeaponDamage``, ``aExecuteTeleporter`` and ``aExecuteBomb``.
    """
    if scores_as_a_loss(type_id, player):
        board[player].losses += 1


def count_kill_and_loss(board: list[ScoreRecord], killer: int,
                        victim_type: int, victim_player: int) -> None:
    """``0x0043B810`` and ``0x0043B860``, which fire together and only when the
    two players differ.

    ``0x0043B810`` carries **no** player guard, so an alien killer -- player
    255 -- makes the engine write 40 * 255 bytes past the array.  That is an
    out-of-bounds write rather than a rule, and it is bounded here.

    ``0x0043B860``'s third increment -- one commendation per unit lost to an
    enemy -- is not here: the counter is campaign state, and
    :meth:`CampaignState.score_mission` folds the mission's count into it
    (docs/27 section 6.2).
    """
    if killer == victim_player:
        return
    if 0 <= killer < PLAYER_SLOTS:
        board[killer].kills += 1
    if scores_as_a_loss(victim_type, victim_player):
        board[victim_player].lost_to_enemy += 1

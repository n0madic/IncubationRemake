"""An executable model of the LCL interpreter -- ``docs/20``.

Nothing in this repository executed LCL before: ``inclib.lcl`` recovers the
program and ``inclib.script`` puts it in the cache, but the language's *meaning*
lived only in prose.  This module is the executable form of ``docs/20`` §2, §4,
§5 and §7, and ``tools/lcl_runtime.py`` runs it over the whole corpus.

**It executes the cache document, not the parse tree.**  ``run`` takes exactly
what ``inclib.script.script_document`` writes and ``godot/game/cache_loader.gd``
loads, so the GDScript interpreter and this one walk the same list and a
three-way diff is document against document rather than "two in-memory shapes
that happen to agree".

What the model is faithful about, because ``docs/20`` §2 says a remake must be:

* one cursor, one boolean flag, **no block structure and no skipping** -- every
  construct is walked whatever the flag says, and only dispatch is gated;
* ``&`` and ``|`` fold strictly left to right with no precedence and **no
  short-circuit**: a predicate runs even when the flag is already false;
* ``<`` sets the flag true unconditionally, ``#`` inverts it, a label and a
  comment touch neither;
* ``[END]`` stops the program and is **not** gated by the flag;
* ``Goto`` is an ordinary command -- gated like any other -- and jumps to the
  **first** label of that name, or aborts when there is none;
* any failure is "report, then return 0" for the whole invocation, which is
  what the ``abort`` instruction in the stream marks;
* the 28 locals are refilled with **-1**, not 0, on every run.

What it is **not** yet: the exact effect of the set pieces.  ``Platform``,
``Barrier`` and their relatives are applied as the state change ``docs/20`` §7.4
records and their animation is not modelled -- the deviation the second slice
declares rather than hides.  Their exactness gate is the native capture, not
this file.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Callable

from . import combat as combatmod
from . import ctrlmap as ctrlmapmod
from . import interact as interactmod
from . import lev as levmod
from .info import BalanceTables
from .rng import ARandom, CRandom

LOG = logging.getLogger("lcl.runtime")

#: ``docs/20`` §4.1 -- ``0x0043fc70`` clears 28 dwords before every run.
LOCAL_VAR_SLOTS = 28
#: ``docs/20`` §4.2 -- and fills them with -1, so a read before the first write
#: yields -1 rather than 0.
LOCAL_VAR_INITIAL = -1
#: ``docs/20`` §4 -- the environment array the host writes; ``0x004402a0``
#: range-checks ``letter - 'A'`` against 0..26.
ENV_VAR_SLOTS = 27

#: ``docs/20`` §7.4 -- ``SetGameControl``/``IncGameControl``/
#: ``GameControlCmpNum`` all address this one array at ``0x00509f18``; a slot
#: outside it makes the call a no-op rather than an error.
GAME_CONTROL_SLOTS = 12

#: ``docs/20`` §5 -- the call types the host writes into ``_A``.
CALL_NEXT_PLAYER = 1
CALL_MOVE_UNIT = 2
CALL_ATTACK = 3
CALL_USE = 4
CALL_NEXT_TURN = 5
CALL_INIT_MAP = 6
MISSION_CALL_TYPES = (CALL_NEXT_PLAYER, CALL_MOVE_UNIT, CALL_ATTACK,
                      CALL_USE, CALL_NEXT_TURN, CALL_INIT_MAP)

#: ``docs/10`` §5.7 and ``docs/20`` §7.4 -- 255 is the computer in every
#: player argument; ``UnitOnField``/``MechOnField`` also accept 254 for "any".
PLAYER_COMPUTER = 255
PLAYER_ANY = 254

#: ``docs/20`` §7.4 -- species 2 is an object and 3 a machine; ``UnitOnField``
#: excludes both and ``MechOnField`` requires the second.
SPECIES_OBJECT = 2
SPECIES_MACHINE = 3

#: ``docs/20`` §7.4 -- ``InsertUnit`` refuses to spawn on a cell whose ActPt is
#: 71 (``'G'``).
ACTPT_NO_SPAWN = 71

#: ``docs/20`` §7.4 -- the control-map types the set pieces write.
CTRL_TYPE_WALL = 2
#: ``0x00415d66`` -- ``CrushWall`` marks its footprint with this field type.
CTRL_TYPE_FREE_PLACE = 1
# ``Statue`` reaches at most this far, each way -- ``0x00413c97``,
# ``cmp dword [esp+0x3c], 6``.
STATUE_BEAM_REACH = 6
CTRL_TYPE_DEEP_HOLE = 4

#: ``docs/20`` §7.4 -- ``GetHeight``/``SetHeight`` speak in units of 160 world
#: units; one map tile is 3200.
HEIGHT_LEVEL_UNITS = 160


def div_trunc(a: int, b: int) -> int:
    """C's integer division: truncated **toward zero**, not floored.

    ``GetHeight`` is ``cell.height / 160`` in C, and 1844 shipped cells carry a
    negative height, so Python's ``//`` -- which floors -- would return a
    different level for every one of them.  ``godot/core/int_ops.gd`` marks the
    same sites on the GDScript side for the same reason.
    """
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q

#: ``docs/20`` §7.4 -- the AI-difficulty setting ``InsertUnit``'s count draw
#: branches on.  ``docs/93`` §11 left the choice to the campaign layer and this
#: slice makes it: 1, normal.
AI_LEVEL_EASY = 0
AI_LEVEL_NORMAL = 1
AI_LEVEL_HARD = 2
DEFAULT_AI_LEVEL = AI_LEVEL_NORMAL

#: A hard stop.  ``Goto`` makes an unbounded loop expressible, and a corpus
#: check that hangs on one script is worse than one that names it.
MAX_STEPS = 100_000

#: ``docs/10`` §5 -- the unit array is 200 fixed records, and a spawn takes one.
UNIT_SLOTS = 200

#: ``docs/20`` §2.3 and §7.4 -- the two directions a set piece can be given,
#: which do **not** agree on the north/south axis.  Keeping both spellings here
#: is the point: folding them into one is the trap the doc calls out.
DIR_PLATFORM = {0: (0, -1), 1: (-1, 0), 2: (0, 1), 3: (1, 0)}
DIR_BARRIER = {0: (0, 1), 1: (-1, 0), 2: (0, -1), 3: (1, 0)}


class RuntimeError_(Exception):
    """Raised when the model cannot run a program at all."""


# ---------------------------------------------------------------------------
# What a run produced
# ---------------------------------------------------------------------------

#: How a run ended.  All three are ordinary outcomes of the original: it has no
#: notion of "the program crashed".
OUTCOME_END = "end"
"""``[END]`` was reached -- the normal stop."""
OUTCOME_FELL_OFF = "fell_off"
"""The cursor ran past the last instruction.  ``docs/20`` §2: the loop simply
runs out of buffer; a script with no ``[END]`` ends this way."""
OUTCOME_ABORT = "abort"
"""``docs/20`` §2.2 -- report, then return 0.  The host gets a zero and carries
on; the reporter is an empty stub in the release build, so it is silent."""


@dataclass
class Outcome:
    """What one invocation did.  A value, never a mutation handed outwards."""

    kind: str
    reason: str = ""
    line: int = 0
    steps: int = 0
    dispatched: int = 0
    """Commands actually dispatched -- i.e. reached with the flag true."""
    events: list[tuple[str, Any]] = field(default_factory=list)
    """What the model applied but does not simulate: camera moves, sounds and
    the set pieces' animations.  Recorded rather than dropped, so a later stage
    can diff them instead of rediscovering that they happened."""

    @property
    def ok(self) -> bool:
        return self.kind != OUTCOME_ABORT

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "reason": self.reason,
            "line": self.line,
            "steps": self.steps,
            "dispatched": self.dispatched,
            "events": [[name, value] for name, value in self.events],
        }


# ---------------------------------------------------------------------------
# The world the commands act on
# ---------------------------------------------------------------------------

@dataclass
class RuntimeUnit:
    """One live unit, reduced to what ``docs/20``'s commands read and write."""

    slot: int
    player: int
    type_id: int
    x: int
    y: int
    hit_points: int
    group: int = 0
    ammo: int = 0
    ep: int = 0
    tp: int = 0
    pool_flag: int = 0
    speech: int = 0
    name: str = ""

    @property
    def alive(self) -> bool:
        return self.hit_points > 0


class LclWorld:
    """The mutable state one mission program can reach.

    Deliberately **not** the whole battle map: the language touches four cell
    fields (``docs/20`` §7.4), the unit array, the turn, the player, the
    12-entry game-control array and the next-map name.  Carrying more would
    invite treating it as validated.
    """

    def __init__(self, bm: levmod.BattleMap, tables: BalanceTables,
                 turn: int = 1, player: int = 0,
                 ai_level: int = DEFAULT_AI_LEVEL,
                 seed: float = 0.0) -> None:
        self.width = bm.width
        self.height = bm.height
        cells = bm.cells
        self.actpt = [c.action_point for c in cells]
        self.ctrl_type = [c.field_type for c in cells]
        self.cell_height = [c.height for c in cells]
        self.unit_at = [-1 if c.unit is None else c.unit for c in cells]
        #: ``+0x0E``..``+0x13`` -- the transient-object block of
        #: ``docs/42`` §9.1.  ``SetGroundFire`` and ``ParaBombs`` write it
        #: through :mod:`inclib.ctrlmap`, so the language touches **six** cell
        #: fields rather than the four ``docs/20`` §7.4 tabulates.
        self.effect_timer = [c.raw[0x0E] for c in cells]
        self.effect_object = [c.raw[0x0F] for c in cells]
        self.effect_state = [c.raw[0x10] for c in cells]
        self.decal_object = [c.raw[0x11] for c in cells]
        self.decal_phase = [c.raw[0x12] for c in cells]
        self.decal_state = [c.raw[0x13] for c in cells]
        self.special_objects: list[int] = []
        #: ``0x00406F20`` plus ``0x0042F410``: cell -> every cell of the object
        #: standing on it, which is what ``CrushWall`` crushes (``docs/42``
        #: §8.2).  Filled by :func:`inclib.footprint.footprint_index` from the
        #: mission's own ``.lev`` and ``prototyp.bin``; empty here, because a
        #: ``LclWorld`` is built from the ``.lev`` alone and the meshes live a
        #: directory away.  Empty means every reader falls back to the cell it
        #: was given, which is what the synthetic maps want.
        self.object_cells: dict[int, list[int]] = {}
        #: The placer models the mission's world set carries; ``None`` skips
        #: the gate (``inclib.ctrlmap``).
        self.special_models: frozenset[str] | None = None
        self.units: dict[int, RuntimeUnit] = {}
        for u in bm.units:
            if not u.placed:
                continue
            self.units[u.slot] = RuntimeUnit(
                slot=u.slot, player=u.player, type_id=u.type_id, x=u.x, y=u.y,
                hit_points=u.hit_points, group=u.group, ammo=u.ammo, ep=u.ep,
                tp=u.tp, pool_flag=u.pool_flag, speech=u.speech, name=u.name)
        self.tables = tables
        self.turn = turn
        self.player = player
        self.ai_level = ai_level
        self.game_control = [0] * GAME_CONTROL_SLOTS
        self.next_map = bm.next_map
        #: ``docs/20`` §7.4 -- ``HeroKilled`` reads the player record's `+0x24`
        #: and :meth:`LclWorld.remove` writes it.  The ``.lev`` carries no
        #: player records, so it starts clear for all four; from there it is
        #: the removal of a **hero** that moves one (``docs/22`` §9.5).
        self.hero_killed = [0, 0, 0, 0]
        self.turn_control = 0
        self.rng = ARandom(seed)
        #: ``docs/20`` §7.4 -- ``InsertUnit`` draws from the C runtime's
        #: generator, not from ``aRandom``.  Keeping them separate is the point.
        self.crand = CRandom()

    # --- cells ------------------------------------------------------------

    def in_bounds(self, x: int, y: int) -> bool:
        return 0 <= x < self.width and 0 <= y < self.height

    def index(self, x: int, y: int) -> int:
        return y * self.width + x

    def ctrlmap(self) -> ctrlmapmod.CtrlMap:
        """The placers' view of these cells, aliasing the columns."""
        cells = ctrlmapmod.CtrlMap(
            width=self.width, height=self.height,
            cell_height=self.cell_height, unit_at=self.unit_at,
            action_point=self.actpt, field_type=self.ctrl_type,
            effect_timer=self.effect_timer,
            effect_object=self.effect_object,
            effect_state=self.effect_state,
            decal_object=self.decal_object, decal_phase=self.decal_phase,
            decal_state=self.decal_state, objects=self.special_objects,
            models=self.special_models)
        if not self.special_objects:
            ctrlmapmod.rebuild_objects(cells)
            self.special_objects = cells.objects
        return cells

    def species(self, type_id: int) -> int:
        row = self.tables.units.get(type_id)
        return 0 if row is None else row.species

    def unit_on(self, x: int, y: int) -> RuntimeUnit | None:
        if not self.in_bounds(x, y):
            return None
        slot = self.unit_at[self.index(x, y)]
        if slot < 0:
            return None
        unit = self.units.get(slot)
        return unit if unit is not None and unit.alive else None

    #: ``+0x4D`` at or above this is a **hero** -- ``docs/22`` §9.5.
    HERO_POOL_FLAG = 2
    #: The player record's ``+0x24`` is one byte.
    HERO_COUNT_WRAP = 256

    def remove_slot(self, slot: int) -> bool:
        """:meth:`remove` addressed by slot -- what the ground fire hands over."""
        unit = self.units.get(slot)
        return False if unit is None else self.remove(unit)

    def footprint(self, unit: RuntimeUnit, x: int, y: int) -> list[int]:
        """``aWriteUnitIdIntoCtrlMap`` (``0x0047A240``) -- the cells a unit
        covers: its own for size 0, the **nine** of the 3x3 block for size 1,
        clipped to the map as ``aGetCtrlMapElementPtr`` ``0x0042F730``'s NULL
        answer clips them.  ``docs/10`` §4.4 -- the authored map already ships
        all nine of every large unit.
        """
        row = self.tables.units.get(unit.type_id)
        if row is None or row.size != combatmod.SIZE_LARGE:
            return [self.index(x, y)] if self.in_bounds(x, y) else []
        return [self.index(x + dx, y + dy)
                for dy in (-1, 0, 1) for dx in (-1, 0, 1)
                if self.in_bounds(x + dx, y + dy)]

    def remove(self, unit: RuntimeUnit) -> bool:
        """``aRemoveUnitElement`` (``0x004779C0``) -- and its hero counter.

        ``docs/22`` §9.5:

        .. code-block:: c

           if (unit[+0x4D] >= 2 && getTurnCounter() != 0)
               playerRecord(unit[+0x45])[+0x24]++;

        ``+0x24`` is what ``HeroKilled`` reads (``0x004409E0``), and the gate
        is the turn counter at ``0x00509E1D``: a hero taken off the map before
        the first hand-over does not count.  Returns whether it moved.

        Its last instruction, ``0x00477ABD``, is ``mov byte [esi+0x16], 0``:
        the routine kills as well as unlinks, so a removed unit is a dead one.
        """
        counted = False
        if (unit.pool_flag >= self.HERO_POOL_FLAG and self.turn != 0
                and 0 <= unit.player < len(self.hero_killed)):
            self.hero_killed[unit.player] = (
                (self.hero_killed[unit.player] + 1) % self.HERO_COUNT_WRAP)
            counted = True
        # Every cell the unit covers, and only the ones that still name it
        # (:meth:`footprint`).
        for at in self.footprint(unit, unit.x, unit.y):
            if self.unit_at[at] == unit.slot:
                self.unit_at[at] = -1
        # ``0x00477ABD`` -- the routine's own last write.
        unit.hit_points = 0
        return counted

    def kill(self, unit: RuntimeUnit) -> None:
        self.remove(unit)

    def free_cell(self, x: int, y: int) -> bool:
        return self.in_bounds(x, y) and self.unit_on(x, y) is None

    def spawn(self, player: int, type_id: int, name: str, rank: int,
              pool_flag: int, x: int, y: int) -> RuntimeUnit | None:
        """``0x00479cf0`` with ``exact == 0`` -- the form both LCL commands use.

        ``docs/20`` §7.4: an occupied target cell makes it search up to eight
        neighbours, ``rank * 12`` goes into **both** the experience points and
        the skill-point pool, and an empty name is filled from the unit type's
        description string.
        """
        target = None
        if self.free_cell(x, y):
            target = (x, y)
        else:
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    if self.free_cell(x + dx, y + dy):
                        target = (x + dx, y + dy)
                        break
                if target is not None:
                    break
        if target is None:
            return None
        slot = self.free_slot()
        row = self.tables.units.get(type_id)
        unit = RuntimeUnit(
            slot=slot, player=player, type_id=type_id, x=target[0],
            y=target[1], hit_points=0 if row is None else row.hp_max,
            ep=rank * 12, tp=rank * 12, pool_flag=pool_flag,
            name=name or ("" if row is None else row.description))
        if unit.hit_points == 0:
            # `placed` is `hp != 0`, so a type with no row -- or one whose
            # `hp_max` is 0 -- would be an unplaced slot the moment it is
            # written.  One hit point keeps it a unit; the exact value is for
            # the native capture to settle, not this model to guess.
            unit.hit_points = 1
        self.units[slot] = unit
        for at in self.footprint(unit, *target):
            self.unit_at[at] = slot
        return unit

    def free_slot(self) -> int:
        """The lowest slot in 0..199 that holds no **live** unit.

        **UNVERIFIED.**  ``docs/20`` §7.4 records everything ``0x00479cf0``
        writes and not which index it writes it to; the engine's array is 200
        fixed records, so the lowest free one is the natural reading and it is
        what both this model and ``godot/core/lcl/lcl_context.gd`` use.

        The rule matters more than the answer: a ``.lev`` carries *named* slots
        whose hit points are zero -- ``_C_140`` has two -- and "one past the
        highest key" gives 10 for a roster built from the placed units and 12
        for one built from the named ones.  Those are two different missions
        after the first reinforcement, and nothing downstream would say so.
        """
        for slot in range(UNIT_SLOTS):
            unit = self.units.get(slot)
            if unit is None or not unit.alive:
                return slot
        return UNIT_SLOTS - 1

    def cells_with_actpt(self, low: int, high: int) -> list[int]:
        return [i for i, v in enumerate(self.actpt) if low <= v <= high]


# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

class Params:
    """The three parameter arrays of ``docs/20`` §3.2, per kind.

    Numbers, strings and variable references go into **separate** arrays in the
    order they appear, and the arrays are pre-filled with -1 and ``""``.  That
    is why calling a command with fewer arguments than its handler reads is
    well defined rather than undefined, and why ``FallingSpores``'s string can
    sit between its sixth and seventh number.
    """

    MISSING_NUM = -1
    MISSING_STR = ""

    def __init__(self, args: list[dict[str, Any]]) -> None:
        self.num: list[int] = []
        self.str: list[str] = []
        self.var: list[int] = []
        for arg in args:
            kind = arg.get("kind")
            if kind == "number":
                self.num.append(int(arg.get("value", 0)))
            elif kind == "var":
                self.var.append(int(arg.get("slot_index", -1)))
            elif kind in ("string", "name"):
                self.str.append(str(arg.get("value", "")))
            # `empty` contributes to no array; the corpus has none.

    def n(self, index: int) -> int:
        return self.num[index] if index < len(self.num) else self.MISSING_NUM

    def s(self, index: int) -> str:
        return self.str[index] if index < len(self.str) else self.MISSING_STR

    def v(self, index: int) -> int:
        return self.var[index] if index < len(self.var) else self.MISSING_NUM


# ---------------------------------------------------------------------------
# The interpreter
# ---------------------------------------------------------------------------

class Interpreter:
    """One invocation of one program.  Construct, ``run``, read the outcome."""

    def __init__(self, document: dict[str, Any], world: LclWorld,
                 env: dict[int, int] | None = None,
                 max_steps: int = MAX_STEPS) -> None:
        self.instructions: list[dict[str, Any]] = list(
            document.get("instructions", []))
        self.labels: dict[str, int] = dict(document.get("labels", {}))
        self.world = world
        self.local = [LOCAL_VAR_INITIAL] * LOCAL_VAR_SLOTS
        self.env = [0] * ENV_VAR_SLOTS
        for slot, value in (env or {}).items():
            # Out of range is an error, not a skip.  The engine indexes the
            # environment by `letter - 'A'` (0x004402A0), so a caller passing
            # ord('A') rather than 0 is asking for slot 65 -- and silently
            # dropping it made an invocation run to its end having never
            # reached the entry point it was supposed to select.
            if not 0 <= slot < ENV_VAR_SLOTS:
                raise RuntimeError_(
                    f"environment slot {slot} is outside 0..{ENV_VAR_SLOTS - 1};"
                    f" the engine indexes by letter - 'A', so pass 0 for _A")
            self.env[slot] = value
        self.flag = True
        self.pos = 0
        self.max_steps = max_steps
        self.events: list[tuple[str, Any]] = []
        self.dispatched = 0

    # --- the loop ---------------------------------------------------------

    def run(self) -> Outcome:
        """``0x0043f6e0``: start at instruction 0 with the flag true."""
        steps = 0
        while True:
            if self.pos >= len(self.instructions):
                return self._outcome(OUTCOME_FELL_OFF, "", self._last_line(),
                                     steps)
            steps += 1
            if steps > self.max_steps:
                return self._outcome(
                    OUTCOME_ABORT,
                    f"more than {self.max_steps} steps; a Goto loop that never "
                    f"reaches [END]", self._line(self.pos), steps)
            instr = self.instructions[self.pos]
            kind = instr["kind"]
            line = int(instr.get("line", 0))
            self.pos += 1

            if kind == "cond":
                value = self._predicate(instr)
                op = instr.get("op", ">")
                # No short-circuit: the predicate above already ran.
                if op == ">":
                    self.flag = value
                elif op == "&":
                    self.flag = self.flag and value
                else:
                    self.flag = self.flag or value
            elif kind == "close":
                self.flag = True
            elif kind == "else":
                self.flag = not self.flag
            elif kind == "label":
                pass
            elif kind == "text":
                pass                     # a store the mission layer never reads
            elif kind == "end":
                return self._outcome(OUTCOME_END, "", line, steps)
            elif kind == "abort":
                return self._outcome(OUTCOME_ABORT,
                                     str(instr.get("name", "")), line, steps)
            elif kind == "command":
                if not self.flag:
                    continue
                jumped = self._command(instr)
                if jumped is not None:
                    return self._outcome(OUTCOME_ABORT, jumped, line, steps)
            else:
                return self._outcome(OUTCOME_ABORT,
                                     f"unknown instruction kind {kind!r}",
                                     line, steps)

    def _outcome(self, kind: str, reason: str, line: int,
                 steps: int) -> Outcome:
        return Outcome(kind=kind, reason=reason, line=line, steps=steps,
                       dispatched=self.dispatched, events=self.events)

    def _line(self, pos: int) -> int:
        if 0 <= pos < len(self.instructions):
            return int(self.instructions[pos].get("line", 0))
        return self._last_line()

    def _last_line(self) -> int:
        return (int(self.instructions[-1].get("line", 0))
                if self.instructions else 0)

    # --- dispatch ---------------------------------------------------------

    def _predicate(self, instr: dict[str, Any]) -> bool:
        name = instr.get("name", "")
        handler = PREDICATES.get(name)
        if handler is None:
            # docs/20 section 7.1: an unmatched name makes the dispatcher
            # return "not found", which aborts.  Modelled by leaving the flag
            # alone and failing the corpus check, because a silent false would
            # look like a working script.
            raise RuntimeError_(f"unknown predicate {name!r}")
        return handler(self, Params(instr.get("args", [])))

    def _command(self, instr: dict[str, Any]) -> str | None:
        """Dispatch one command.  Returns an abort reason, or ``None``."""
        name = instr.get("name", "")
        handler = COMMANDS.get(name)
        if handler is None:
            raise RuntimeError_(f"unknown command {name!r}")
        self.dispatched += 1
        return handler(self, Params(instr.get("args", [])))

    def event(self, name: str, *values: Any) -> None:
        self.events.append((name, list(values)))

    # --- variable access --------------------------------------------------

    def get_local(self, slot: int) -> int:
        return (self.local[slot] if 0 <= slot < LOCAL_VAR_SLOTS
                else LOCAL_VAR_INITIAL)

    def set_local(self, slot: int, value: int) -> None:
        if 0 <= slot < LOCAL_VAR_SLOTS:
            self.local[slot] = value

    def get_env(self, slot: int) -> int:
        return self.env[slot] if 0 <= slot < ENV_VAR_SLOTS else 0


# ---------------------------------------------------------------------------
# Predicates -- docs/20 section 7.4
# ---------------------------------------------------------------------------

def _p_env_cmp(it: Interpreter, p: Params) -> bool:
    return it.get_env(p.v(0)) == p.n(0)


def _p_env_lower(it: Interpreter, p: Params) -> bool:
    return it.get_env(p.v(0)) < p.n(0)


def _p_env_greater(it: Interpreter, p: Params) -> bool:
    return it.get_env(p.v(0)) > p.n(0)


def _p_var_cmp(it: Interpreter, p: Params) -> bool:
    return it.get_local(p.v(0)) == p.n(0)


def _p_var_lower(it: Interpreter, p: Params) -> bool:
    return it.get_local(p.v(0)) < p.n(0)


def _p_var_greater(it: Interpreter, p: Params) -> bool:
    return it.get_local(p.v(0)) > p.n(0)


def _p_var_cmp_var(it: Interpreter, p: Params) -> bool:
    return it.get_local(p.v(0)) == it.get_local(p.v(1))


def _p_check_turn(it: Interpreter, p: Params) -> bool:
    return p.n(0) <= it.world.turn <= p.n(1)


def _p_hero_killed(it: Interpreter, p: Params) -> bool:
    player = p.n(0)
    return (0 <= player < len(it.world.hero_killed)
            and it.world.hero_killed[player] != 0)


def _p_group_on_field(it: Interpreter, p: Params) -> bool:
    unit = it.world.unit_on(p.n(1), p.n(2))
    return unit is not None and unit.group == p.n(0)


def _p_unit_on_field(it: Interpreter, p: Params) -> bool:
    unit = it.world.unit_on(p.n(1), p.n(2))
    if unit is None:
        return False
    species = it.world.species(unit.type_id)
    if species in (SPECIES_OBJECT, SPECIES_MACHINE):
        return False
    player = p.n(0)
    return player == PLAYER_ANY or unit.player == player


def _p_mech_on_field(it: Interpreter, p: Params) -> bool:
    unit = it.world.unit_on(p.n(1), p.n(2))
    if unit is None or it.world.species(unit.type_id) != SPECIES_MACHINE:
        return False
    player = p.n(0)
    return player == PLAYER_ANY or unit.player == player


def _p_no_unit_on_field(it: Interpreter, p: Params) -> bool:
    return it.world.unit_on(p.n(0), p.n(1)) is None


def _p_game_control_cmp(it: Interpreter, p: Params) -> bool:
    slot = p.n(0)
    return (0 <= slot < GAME_CONTROL_SLOTS
            and it.world.game_control[slot] == p.n(1))


PREDICATES: dict[str, Callable[[Interpreter, Params], bool]] = {
    "EnvVarCmpNum": _p_env_cmp,
    "EnvVarLowerNum": _p_env_lower,
    "EnvVarGreaterNum": _p_env_greater,
    "VarCmpNum": _p_var_cmp,
    "VarLowerNum": _p_var_lower,
    "VarGreaterNum": _p_var_greater,
    "VarCmpVar": _p_var_cmp_var,
    "CheckCurrentTurn": _p_check_turn,
    "HeroKilled": _p_hero_killed,
    "GroupOnField": _p_group_on_field,
    "UnitOnField": _p_unit_on_field,
    "MechOnField": _p_mech_on_field,
    "NoUnitOnField": _p_no_unit_on_field,
    "GameControlCmpNum": _p_game_control_cmp,
}


# ---------------------------------------------------------------------------
# Commands -- docs/20 section 7.4
#
# A handler returns `None` normally, or an abort reason.  Three groups:
#
#   * **state** -- the effect is in what `LclWorld` holds, and is applied;
#   * **set piece** -- the documented *state change* is applied and the
#     animation is recorded as an event, which is the deviation docs/94
#     declares (the plan's "применяются как изменение состояния мгновенно");
#   * **presentation** -- camera, sound and GUI: recorded, never simulated.
#
# A command with no entry here is a corpus-check failure, not a silent no-op:
# an unknown name aborts the invocation in the original too (section 7.1).
# ---------------------------------------------------------------------------

# --- flow -----------------------------------------------------------------

def _c_goto(it: Interpreter, p: Params) -> str | None:
    """``0x00440e00`` -- rescan from byte 0, first match wins, missing aborts."""
    target = p.s(0)
    if target not in it.labels:
        return f"Goto to a missing label {target!r}"
    # The label instruction itself is a no-op, so landing on it is the same as
    # landing after it; jumping *to* it keeps the index arithmetic obvious.
    it.pos = it.labels[target]
    return None


# --- variables ------------------------------------------------------------

def _c_set_var_num(it: Interpreter, p: Params) -> str | None:
    it.set_local(p.v(0), p.n(0))
    return None


def _c_set_var_var(it: Interpreter, p: Params) -> str | None:
    """**Broken as shipped** -- docs/20 section 8.2.

    ``0x00440750`` indexes the local array with the second *numeric* argument
    instead of the second *variable* argument, so ``SetVarVar (_A,_B)`` reads
    ``local[-1]`` -- the missing number -- rather than ``local[1]``.  Modelled
    as written: a remake that "fixes" it changes the one shipped call's result.
    """
    it.set_local(p.v(0), it.get_local(p.n(1)))
    return None


def _c_set_var_random(it: Interpreter, p: Params) -> str | None:
    """``0x004407d0`` -- ``aRandom(0, n)``, i.e. uniform in ``0 .. n-1``."""
    it.set_local(p.v(0), it.world.rng(0, p.n(0)))
    return None


def _c_var_add_num(it: Interpreter, p: Params) -> str | None:
    it.set_local(p.v(0), it.get_local(p.v(0)) + p.n(0))
    return None


def _c_var_sub_num(it: Interpreter, p: Params) -> str | None:
    it.set_local(p.v(0), it.get_local(p.v(0)) - p.n(0))
    return None


def _c_var_add_var(it: Interpreter, p: Params) -> str | None:
    it.set_local(p.v(0), it.get_local(p.v(0)) + it.get_local(p.v(1)))
    return None


def _c_var_sub_var(it: Interpreter, p: Params) -> str | None:
    it.set_local(p.v(0), it.get_local(p.v(0)) - it.get_local(p.v(1)))
    return None


# --- map cells ------------------------------------------------------------

def _c_get_actpt(it: Interpreter, p: Params) -> str | None:
    w = it.world
    if w.in_bounds(p.n(0), p.n(1)):
        it.set_local(p.v(0), w.actpt[w.index(p.n(0), p.n(1))])
    return None


def _c_set_actpt(it: Interpreter, p: Params) -> str | None:
    """``0x00442a40`` -- writes a **byte**, so the two-argument form stores 255.

    docs/20 section 7.4: `_C_120.lcl:66`'s `SetActPt (14,16);` leaves the third
    argument at -1, and `(byte)(-1)` is 255.  Masking here rather than at the
    reader is what makes that come out right.
    """
    w = it.world
    if w.in_bounds(p.n(0), p.n(1)):
        w.actpt[w.index(p.n(0), p.n(1))] = p.n(2) & 0xFF
    return None


def _c_get_ctrl_type(it: Interpreter, p: Params) -> str | None:
    w = it.world
    if w.in_bounds(p.n(0), p.n(1)):
        it.set_local(p.v(0), w.ctrl_type[w.index(p.n(0), p.n(1))])
    return None


def _c_set_ctrl_type(it: Interpreter, p: Params) -> str | None:
    w = it.world
    if w.in_bounds(p.n(0), p.n(1)):
        w.ctrl_type[w.index(p.n(0), p.n(1))] = p.n(2) & 0xFF
    return None


def _c_get_height(it: Interpreter, p: Params) -> str | None:
    w = it.world
    if w.in_bounds(p.n(0), p.n(1)):
        it.set_local(p.v(0), div_trunc(w.cell_height[w.index(p.n(0), p.n(1))],
                                       HEIGHT_LEVEL_UNITS))
    return None


def _c_set_height(it: Interpreter, p: Params) -> str | None:
    w = it.world
    if w.in_bounds(p.n(0), p.n(1)):
        w.cell_height[w.index(p.n(0), p.n(1))] = p.n(2) * HEIGHT_LEVEL_UNITS
        it.event("land_object_height", p.n(0), p.n(1), p.n(2))
    return None


# --- queries --------------------------------------------------------------

def _c_get_turn(it: Interpreter, p: Params) -> str | None:
    it.set_local(p.v(0), it.world.turn)
    return None


def _c_get_player(it: Interpreter, p: Params) -> str | None:
    it.set_local(p.v(0), it.world.player)
    return None


def _c_get_units(it: Interpreter, p: Params) -> str | None:
    player = p.n(0)
    it.set_local(p.v(0), sum(1 for u in it.world.units.values()
                             if u.alive and u.player == player))
    return None


def _c_get_units_in_area(it: Interpreter, p: Params) -> str | None:
    """``0x00478000`` -- inclusive rectangle; a player of -1 matches any."""
    player, x1, y1, x2, y2 = p.n(0), p.n(1), p.n(2), p.n(3), p.n(4)
    count = 0
    for u in it.world.units.values():
        if not u.alive:
            continue
        if player != -1 and u.player != player:
            continue
        if x1 <= u.x <= x2 and y1 <= u.y <= y2:
            count += 1
    it.set_local(p.v(0), count)
    return None


def _c_get_groups_in_area(it: Interpreter, p: Params) -> str | None:
    """``0x004780a0`` -- the same loop on the group id, despite the name."""
    group, x1, y1, x2, y2 = p.n(0), p.n(1), p.n(2), p.n(3), p.n(4)
    count = sum(1 for u in it.world.units.values()
                if u.alive and u.group == group
                and x1 <= u.x <= x2 and y1 <= u.y <= y2)
    it.set_local(p.v(0), count)
    return None


def _c_get_units_in_group(it: Interpreter, p: Params) -> str | None:
    group = p.n(0)
    it.set_local(p.v(0), sum(1 for u in it.world.units.values()
                             if u.alive and u.group == group))
    return None


# --- units ----------------------------------------------------------------

def insert_count_divisor(max_count: int, level: int) -> int:
    """The divisor ``0x004418c0``'s ``idiv esi`` runs with, per difficulty.

    Read off the branch at ``0x0044194e``: easy takes the normal arm outright
    when ``maxCount <= 2`` (``cmp esi, 2 / jle``) and otherwise takes one off
    with ``dec esi``, while normal and hard divide by ``maxCount`` as it stands.
    ``max_count == 0`` never reaches the divide -- the caller returns 1 -- and
    is not a legal argument here.
    """
    if max_count == 0:
        raise RuntimeError_("max_count 0 never reaches the divide")
    if level == AI_LEVEL_EASY and max_count > 2:
        return max_count - 1
    return max_count


def insert_count_bounds(max_count: int, level: int) -> tuple[int, int]:
    """The inclusive range one ``InsertUnit`` can spawn -- a second reading.

    ``_insert_count`` performs the draw; this states what the draw can produce.
    It deliberately shares **no code** with it -- the divisor rule is read off
    ``0x0044194E`` a second time here rather than borrowed -- so
    ``lcl_runtime.py --check`` can hold the two against each other instead of
    trusting either alone.  The draw is uniform over the range, so its mean is
    ``(lo + hi) / 2``.
    """
    if max_count == 0:
        return (1, 1)
    if level not in (AI_LEVEL_EASY, AI_LEVEL_NORMAL, AI_LEVEL_HARD):
        return (0, 0)
    # `cmp esi, 2 / jle` at `0x0044194E`: below 3 the easy arm falls into the
    # normal one, and above it `dec esi` takes one off.
    divisor = max_count - 1 if level == AI_LEVEL_EASY and max_count > 2 \
        else max_count
    # `idiv` leaves a remainder strictly smaller in magnitude than the divisor
    # and signed like the dividend, and the dividend -- `rand()` -- is never
    # negative.  So a divisor of -1 yields 0 and nothing else, which is what
    # makes the six short call sites spawn nothing outside hard.
    top = abs(divisor) - 1
    add = 1 if level == AI_LEVEL_HARD else 0
    return (add, top + add)


def _insert_count(it: Interpreter, max_count: int) -> int:
    """``0x004418c0`` step 2 -- how many units one ``InsertUnit`` spawns.

    ``max_count == 0`` means exactly one.  Otherwise the draw is the C
    runtime's ``rand()``, and the bound is **exclusive** on easy and normal and
    inclusive on hard -- so ``InsertUnit (..., 1)`` spawns nothing except on
    hard, and the six short call sites, whose ``maxCount`` reads as -1, spawn
    nothing except on hard.

    **The draw is unconditional whenever ``max_count`` is not zero**, including
    the arms whose result can only be 0.  All three of ``0x00441942``,
    ``0x0044195c`` and ``0x0044194e`` reach ``call [0x5255fc]`` before the
    ``idiv``, with no guard in front of any of them -- so ``maxCount`` 1 and
    the short sites' -1 still consume one ``rand()``.  An earlier revision
    short-circuited those, which desynchronised the stream against the engine
    from that point on: ``_C_116`` fires its six short sites on turn 8 and
    another ``InsertUnit`` on every turn after, so the divergence was
    observable rather than theoretical.
    """
    if max_count == 0:
        return 1
    level = it.world.ai_level
    if level not in (AI_LEVEL_EASY, AI_LEVEL_NORMAL, AI_LEVEL_HARD):
        # `incorrect ai level!` -- the engine's own path, which spawns nothing
        # and, having branched before the call, draws nothing either.
        return 0
    divisor = insert_count_divisor(max_count, level)
    # The dividend is non-negative, so C's truncated remainder is the plain
    # modulus against the divisor's magnitude.
    count = it.world.crand() % abs(divisor)
    return count + 1 if level == AI_LEVEL_HARD else count


def _c_insert_unit(it: Interpreter, p: Params) -> str | None:
    """``InsertUnit (player, type, "name", rank, poolFlag, x, y, maxCount)``."""
    w = it.world
    x, y = p.n(4), p.n(5)
    if w.in_bounds(x, y) and w.actpt[w.index(x, y)] == ACTPT_NO_SPAWN:
        return None                       # step 1: ActPt 71 refuses the spawn
    for _ in range(_insert_count(it, p.n(6))):
        w.spawn(p.n(0), p.n(1), p.s(0), p.n(2), p.n(3), x, y)
    it.event("build_visible_map", w.player)
    return None


def _c_insert_unit_with_group(it: Interpreter, p: Params) -> str | None:
    """``0x004419d0`` -- exactly one unit, then its group id."""
    w = it.world
    x, y = p.n(4), p.n(5)
    if w.in_bounds(x, y) and w.actpt[w.index(x, y)] == ACTPT_NO_SPAWN:
        return None
    unit = w.spawn(p.n(0), p.n(1), p.s(0), p.n(2), p.n(3), x, y)
    if unit is not None:
        unit.group = p.n(6)
    return None


def _c_set_ammo_for_unit(it: Interpreter, p: Params) -> str | None:
    """``0x00441710`` -- takes a **tile**, and sets that unit's ammo to 0."""
    unit = it.world.unit_on(p.n(0), p.n(1))
    if unit is not None:
        unit.ammo = 0
    return None


def _c_link_chr_with_group(it: Interpreter, p: Params) -> str | None:
    for unit in it.world.units.values():
        if unit.alive and unit.group == p.n(0):
            unit.speech = p.n(1)
    return None


def _c_roof_unit(it: Interpreter, p: Params) -> str | None:
    """``0x00442030`` -- drop one computer unit onto a free tile."""
    w = it.world
    if w.free_cell(p.n(0), p.n(1)):
        w.spawn(PLAYER_COMPUTER, p.n(3), "", 0, 0, p.n(0), p.n(1))
        it.event("roof_unit", p.n(0), p.n(1), p.n(2), p.n(3))
    return None


def _c_ground_unit(it: Interpreter, p: Params) -> str | None:
    """``0x00442150`` -- burst out at ``(x2,y2)``, leaving a hole at ``(x1,y1)``."""
    w = it.world
    x1, y1, x2, y2 = p.n(0), p.n(1), p.n(2), p.n(3)
    if not (w.free_cell(x1, y1) and w.free_cell(x2, y2)):
        return None
    w.spawn(PLAYER_COMPUTER, p.n(4), "", 0, 0, x2, y2)
    w.ctrl_type[w.index(x1, y1)] = CTRL_TYPE_DEEP_HOLE
    it.event("ground_unit", x1, y1, x2, y2, p.n(4))
    return None


def _c_spores(it: Interpreter, p: Params) -> str | None:
    """``0x00441ff0`` -- hatch one computer unit on every tile in the ActPt range."""
    w = it.world
    for cell in w.cells_with_actpt(p.n(0), p.n(1)):
        w.actpt[cell] = 0
        w.spawn(PLAYER_COMPUTER, p.n(2), "", 0, 0,
                cell % w.width, cell // w.width)
    return None


# --- game control ---------------------------------------------------------

def _c_set_game_control(it: Interpreter, p: Params) -> str | None:
    slot = p.n(0)
    if 0 <= slot < GAME_CONTROL_SLOTS:
        it.world.game_control[slot] = p.n(1)
    return None


def _c_inc_game_control(it: Interpreter, p: Params) -> str | None:
    slot = p.n(0)
    if 0 <= slot < GAME_CONTROL_SLOTS:
        it.world.game_control[slot] += p.n(1)
    return None


def _c_enter_name_of_next_map(it: Interpreter, p: Params) -> str | None:
    it.world.next_map = p.s(0)
    return None


def _c_set_turn_control(it: Interpreter, p: Params) -> str | None:
    """``0x004418b0`` -- one argument into ``0x0043be00``; role **UNVERIFIED**.

    Stored rather than dropped so a later capture has something to compare.
    """
    it.world.turn_control = p.n(0)
    return None


# --- set pieces: applied as state, animation recorded ----------------------

def _c_platform(it: Interpreter, p: Params) -> str | None:
    """``0x004422b0`` -- move the 3x3 block ``dist`` tiles, leaving deep holes.

    docs/20 section 7.4 pins the arguments arithmetically off `_C_105.lcl`'s
    there-and-back pairs: ``(x,y)`` is the platform's centre **before** the
    move and ``dist`` is a distance in tiles, not an identifier.

    The copy below reads each source after possibly writing an earlier one,
    which would be wrong if the source and destination 3x3 blocks overlapped.
    They cannot: the smallest shipped ``dist`` is **3** (4 sites; the corpus
    spans 3..16), and a distance of 3 already separates the two blocks.  A
    mission with ``dist`` 1 or 2 would need the nine cells buffered first --
    and would need the engine's own copy order, which is an S4 probe, not
    something to guess.
    """
    w = it.world
    x, y, dist = p.n(0), p.n(1), p.n(3)
    step = DIR_PLATFORM.get(p.n(2))
    if step is None:
        return None
    dx, dy = step[0] * dist, step[1] * dist
    moved: list[tuple[int, int]] = []
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            sx, sy = x + ox, y + oy
            tx, ty = sx + dx, sy + dy
            if not (w.in_bounds(sx, sy) and w.in_bounds(tx, ty)):
                continue
            src, dst = w.index(sx, sy), w.index(tx, ty)
            w.cell_height[dst] = w.cell_height[src]
            w.ctrl_type[dst] = w.ctrl_type[src]
            unit = w.unit_on(sx, sy)
            w.unit_at[dst] = w.unit_at[src]
            if unit is not None:
                unit.x, unit.y = tx, ty
            w.unit_at[src] = -1
            w.ctrl_type[src] = CTRL_TYPE_DEEP_HOLE
            moved.append((sx, sy))
    it.event("platform", x, y, p.n(2), dist, len(moved))
    return None


def _c_elevator(it: Interpreter, p: Params) -> str | None:
    """``0x00442590`` -- ``steps * 5`` height levels up (dir 0) or down (dir 1)."""
    w = it.world
    x, y, direction, steps = p.n(0), p.n(1), p.n(2), p.n(3)
    if not w.in_bounds(x, y) or direction not in (0, 1):
        return None
    delta = steps * 800 * (1 if direction == 0 else -1)
    w.cell_height[w.index(x, y)] += delta
    it.event("elevator", x, y, direction, steps)
    return None


def _c_barrier(it: Interpreter, p: Params) -> str | None:
    """``0x004423d0`` -- a toggle keyed on the emitter tile's own ActPt.

    Seeded only when the ActPt is 0, so a barrier seeded with the "on" value
    is switched **off** by its first call.  All 164 shipped sites use 90/91.
    """
    w = it.world
    x, y, direction = p.n(0), p.n(1), p.n(2)
    on, off, seed = p.n(3), p.n(4), p.n(5)
    if not w.in_bounds(x, y):
        return None
    cell = w.index(x, y)
    if w.actpt[cell] == 0:
        w.actpt[cell] = seed & 0xFF
    if w.actpt[cell] == on:
        w.actpt[cell] = off & 0xFF
        it.event("barrier_off", x, y)
        return None
    w.actpt[cell] = on & 0xFF
    step = DIR_BARRIER.get(direction)
    killed = 0
    if step is not None:
        bx, by = x + step[0], y + step[1]
        while w.in_bounds(bx, by) and w.ctrl_type[w.index(bx, by)] != CTRL_TYPE_WALL:
            unit = w.unit_on(bx, by)
            if unit is not None:
                w.kill(unit)
                killed += 1
            bx, by = bx + step[0], by + step[1]
    it.event("barrier_on", x, y, direction, killed)
    return None


def _c_fixed_statue(it: Interpreter, p: Params) -> str | None:
    """``0x00442370`` -- up to ten cells along ``dir``; the first unit dies."""
    w = it.world
    x, y = p.n(0), p.n(1)
    step = DIR_BARRIER.get(p.n(2))
    if step is None:
        return None
    cx, cy = x, y
    for _ in range(10):
        cx, cy = cx + step[0], cy + step[1]
        if not w.in_bounds(cx, cy):
            break
        if w.ctrl_type[w.index(cx, cy)] == CTRL_TYPE_WALL:
            break
        unit = w.unit_on(cx, cy)
        if unit is not None:
            w.kill(unit)
            it.event("fixed_statue_kill", cx, cy)
            break
    return None


def _c_foot_bridge(it: Interpreter, p: Params) -> str | None:
    """``0x00442650`` -- collapses only when **more than** ``minUnits`` stand on it.

    The event is ``x, y, frames, standing`` and then the riders' slots, in
    the block's row-major order.  ``aPlayFootBridgeSequence`` ``0x00414A70``
    lists every unit on the nine cells before its loop and, after it, takes
    each one off the map through ``aRemoveUnitElement`` (``0x00414F8C``,
    ``0x0043B8D0`` then ``0x004779C0``) -- and removal kills (``docs/42``
    §12, the closed item on ``0x00477ABD``).  The slots are carried because
    the map no longer knows who stood there once they are gone.
    """
    w = it.world
    x, y, frames, min_units = p.n(0), p.n(1), p.n(2), p.n(3)
    riders: list[RuntimeUnit] = []
    block: list[int] = []
    for oy in (-1, 0, 1):
        for ox in (-1, 0, 1):
            if not w.in_bounds(x + ox, y + oy):
                continue
            block.append(w.index(x + ox, y + oy))
            unit = w.unit_on(x + ox, y + oy)
            if unit is not None:
                riders.append(unit)
    if len(riders) <= min_units:
        return None
    for cell in block:
        w.ctrl_type[cell] = CTRL_TYPE_DEEP_HOLE
    it.event("foot_bridge", x, y, frames, len(riders),
             *[unit.slot for unit in riders])
    for unit in riders:
        w.kill(unit)
    return None


def _c_foot_bridge2(it: Interpreter, p: Params) -> str | None:
    """``0x004426d0`` -- nothing happens unless the turn number matches exactly.

    The event is ``actpt, frames, hit``, then the ``hit`` matched cells as
    ``x, y`` pairs in the engine's own row-major scan order, then the
    riders' slots.  ``0x00415110`` clears the group byte on each cell as it
    scans (``0x004151EB``), so the cells have to travel on the event for the
    picture to find the block -- ``L069EI00`` stands on one of the two --
    and it removes every rider the way ``FootBridge`` does (``0x00415653``,
    ``0x00415663``).
    """
    w = it.world
    actpt, frames, turn = p.n(0), p.n(1), p.n(2)
    if w.turn != turn:
        return None
    cells = list(w.cells_with_actpt(actpt, actpt))
    riders: list[RuntimeUnit] = []
    for cell in cells:
        w.ctrl_type[cell] = CTRL_TYPE_DEEP_HOLE
        w.actpt[cell] = 0
        unit = w.unit_on(cell % w.width, cell // w.width)
        if unit is not None:
            riders.append(unit)
    values: list[int] = [actpt, frames, len(cells)]
    for cell in cells:
        values.extend((cell % w.width, cell // w.width))
    values.extend(unit.slot for unit in riders)
    it.event("foot_bridge2", *values)
    for unit in riders:
        w.kill(unit)
    return None


def _statue_walk(w: LclWorld, x: int, y: int, dx: int, dy: int):
    """One arm of :func:`_statue`: ``(end x, end y, cells stepped, victim)``."""
    cx, cy, stepped = x, y, 0
    while stepped < STATUE_BEAM_REACH:
        nx, ny = cx + dx, cy + dy
        if not w.in_bounds(nx, ny):
            break
        if w.ctrl_type[w.index(nx, ny)] == CTRL_TYPE_WALL:
            return nx, ny, stepped, None
        cx, cy = nx, ny
        stepped += 1
        victim = w.unit_on(cx, cy)
        if victim is not None:
            return cx, cy, stepped, victim
    return cx, cy, stepped, None


def _statue(it: Interpreter, x: int, y: int) -> None:
    """``0x00413a40``, ``aPlayRotateStatueSequence`` -- the rule half.

    The statue's own action-point byte toggles bit 0 (``0x00413c31``: an odd
    byte goes down by one, an even one up by one) and the **new** bit picks the
    axis -- 0 walks ``+y``, 1 walks ``+x`` (``0x00413c5a``).  The beam then runs
    both ways from the statue's cell, at most :data:`STATUE_BEAM_REACH` cells
    each (``0x00413c97``, ``cmp dword [esp+0x3c], 6``), and stops at the map
    edge, at a cell of field type 2, or at the **first** unit it meets:
    ``0x00413d67`` re-enters the loop only on the no-unit branch, which is why
    the routine has exactly two kill sites (``0x00413f4e``, ``0x00413f94``).
    Each victim is booked as a loss (``0x0043b8d0``) and taken off the map by
    ``aRemoveUnitElement`` ``0x004779c0``.

    The endpoint the beam is drawn to is the cell that stopped the walk.
    Running off the map leaves the engine with a null cell pointer there, so
    the remake draws to the last cell it did reach instead -- the remake's, and
    the only place this differs from the instructions.
    """
    w = it.world
    if not w.in_bounds(x, y):
        return
    cell = w.index(x, y)
    flipped = w.actpt[cell]
    flipped = (flipped - 1) if flipped & 1 else (flipped + 1)
    flipped &= 0xFF
    w.actpt[cell] = flipped
    axis = flipped & 1
    dx, dy = (1, 0) if axis else (0, 1)
    forward = _statue_walk(w, x, y, dx, dy)
    backward = _statue_walk(w, x, y, -dx, -dy)
    # Fifteen numbers, fixed width: the statue's cell, the axis the toggle
    # chose, each arm's endpoint and step count, and each arm's victim as
    # ``slot, x, y`` with ``-1, -1, -1`` for an arm that found nobody.  The
    # picture cannot re-derive any of it -- the byte it would read has already
    # been toggled and the victims are already off the map by the time it runs.
    values = [x, y, axis,
              forward[0], forward[1], forward[2],
              backward[0], backward[1], backward[2]]
    for reached in (forward, backward):
        victim = reached[3]
        values += [-1, -1, -1] if victim is None else [victim.slot, victim.x,
                                                       victim.y]
    it.event("statue", *values)
    for reached in (forward, backward):
        if reached[3] is not None:
            w.kill(reached[3])
            it.event("statue_kill", reached[0], reached[1])


def _c_statue2(it: Interpreter, p: Params) -> str | None:
    """``0x004424b0`` -> ``0x00413500`` -- the batch form, over an ActPt range.

    The engine reads the byte fresh at each cell of a row-major sweep, and the
    toggle only ever touches the cell being processed, so the matched set is
    the one taken up front.
    """
    w = it.world
    cells = w.cells_with_actpt(p.n(0), p.n(1))
    it.event("statue2", p.n(0), p.n(1), len(cells))
    for cell in cells:
        _statue(it, cell % w.width, cell // w.width)
    return None


def _c_statue(it: Interpreter, p: Params) -> str | None:
    _statue(it, p.n(0), p.n(1))
    return None


def _c_growing_land(it: Interpreter, p: Params) -> str | None:
    """``0x00442010`` -- grow into a random free neighbour of each tagged tile.

    The new tile inherits the ActPt and becomes a wall.  ``0x00407410`` refuses
    once the scene holds 141 objects; the scene object count is outside this
    model, so the refusal is recorded as a deviation rather than guessed at.
    """
    w = it.world
    actpt, model = p.n(0), p.s(0)
    grown = 0
    for cell in w.cells_with_actpt(actpt, actpt):
        cx, cy = cell % w.width, cell // w.width
        free = [(cx + dx, cy + dy)
                for dy in (-1, 0, 1) for dx in (-1, 0, 1)
                if (dx or dy) and w.free_cell(cx + dx, cy + dy)]
        if not free:
            continue
        tx, ty = free[w.rng(0, len(free))]
        target = w.index(tx, ty)
        w.actpt[target] = actpt & 0xFF
        w.ctrl_type[target] = CTRL_TYPE_WALL
        grown += 1
    it.event("growing_land", actpt, model, grown)
    return None


def _c_falling_spores(it: Interpreter, p: Params) -> str | None:
    """``0x00441f60`` -- ``count`` drops on random tiles of the ``w x h`` block."""
    w = it.world
    x, y, bw, bh, count, actpt = (p.n(0), p.n(1), p.n(2), p.n(3), p.n(4),
                                  p.n(5))
    for _ in range(max(count, 0)):
        tx = w.rng(x, bw)
        ty = w.rng(y, bh)
        if not w.in_bounds(tx, ty):
            continue
        cell = w.index(tx, ty)
        w.ctrl_type[cell] = CTRL_TYPE_WALL
        w.actpt[cell] = actpt & 0xFF
    it.event("falling_spores", x, y, bw, bh, count, actpt, p.s(0))
    return None


def _c_set_ground_fire(it: Interpreter, p: Params) -> str | None:
    """``0x00442730`` -- ``tries`` attempts at a tile of the right type and height.

    What it lays is a **glow**, not a flame: ``0x0042FCB0(x, y, 2)`` writes
    ``+0x11``, ``+0x12`` and ``+0x13`` and nothing else, so a fresh
    ``SetGroundFire`` blocks nobody.  The fuse is two hand-overs long -- the
    round tick decays the glow to phase 1 and the next round's sweep burns it,
    removing every unit the flames reach (``docs/42`` §9.1,
    :func:`inclib.ctrlmap.ground_effects_tick`).  The cell must have no glow on
    it already, control-map type 0 or 1, and a height of exactly
    ``level * 160``.
    """
    w = it.world
    x, y, level, bw, bh, tries = (p.n(0), p.n(1), p.n(2), p.n(3), p.n(4),
                                  p.n(5))
    cells = w.ctrlmap()
    lit: list[tuple[int, int]] = []
    for _ in range(max(tries, 0)):
        tx, ty = w.rng(x, bw), w.rng(y, bh)
        if not w.in_bounds(tx, ty):
            continue
        cell = w.index(tx, ty)
        if (w.decal_state[cell] == ctrlmapmod.DECAL_NONE
                and w.ctrl_type[cell] in (0, 1)
                and w.cell_height[cell] == level * HEIGHT_LEVEL_UNITS
                and ctrlmapmod.place_glow(
                    cells, tx, ty, ctrlmapmod.GLOW_PHASE_FRESH) >= 0):
            lit.append((tx, ty))
    # The tiles ride on the event after the count, as `ParaBombs`' do: the
    # picture puts a glow on each and must not re-draw them.
    it.event("set_ground_fire", x, y, level, bw, bh, tries, len(lit),
             *[c for tile in lit for c in tile])
    return None


def _c_para_bombs(it: Interpreter, p: Params) -> str | None:
    """``0x00442270`` -- the fly-past, then **60** attempts to lay a mine.

    ``0x00470845`` takes a cell with no unit on it and ``+0x10 == 255`` and
    calls the mine placer, which writes ``+0x10 = 2`` -- a rule the move map
    reads, so this one *is* the script layer's business (``docs/20``,
    ``docs/23`` §7.3).
    """
    w = it.world
    x, y, bw, bh = p.n(0), p.n(1), p.n(2), p.n(3)
    cells = w.ctrlmap()
    tiles: list[tuple[int, int]] = []
    for _ in range(60):
        tx, ty = w.rng(x, bw), w.rng(y, bh)
        # `cmp word [eax + 7], 0xFFFF` -- the cell's unit **link**, so a slot
        # whose unit is dead still keeps the bomber off the tile.
        if not w.in_bounds(tx, ty) or w.unit_at[w.index(tx, ty)] >= 0:
            continue
        if w.effect_state[w.index(tx, ty)] != ctrlmapmod.OBSTACLE_NONE:
            continue
        if ctrlmapmod.place_mine(cells, tx, ty) >= 0:
            tiles.append((tx, ty))
    # The tiles themselves ride on the event after the count: the picture
    # (`docs/42` §8) drops one bomb on each, and re-drawing them there would
    # move the generator a second time.
    it.event("para_bombs", x, y, bw, bh, len(tiles),
             *[c for tile in tiles for c in tile])
    return None


def _c_crush_wall(it: Interpreter, p: Params) -> str | None:
    """``aPlayCrushWallAnimation`` ``0x00415c70`` -- ``docs/42`` §8.2.

    Before it throws any debris the routine calls ``0x0042f410(wall, 1, 0, 1)``,
    which sweeps the whole control map, casts four probes per cell from that
    cell's **own** symbol object -- ``x`` and ``y`` each 200 either way, from
    ``z = 100000`` -- against the wall's standard object, and for every cell a
    probe hits writes the height 0, the field type 1 (`Free Place`) and the
    state byte 2.  The state byte goes back to 1 in the debris sweep
    (``0x00415da4``), so what lasts is **the height and the field type**.

    **The footprint is a query against the scene, and it is arithmetic.**  The
    probe is vertical, so "the ray meets the object" is "the probe lies inside
    the ``xy`` projection of one of its faces"; the wall piece is a ``.lev``
    special object naming a prototype whose mesh is in ``prototyp.bin``; and
    :mod:`inclib.footprint` runs the sweep once and reproduces all nine
    measured footprints cell for cell (``docs/42`` §8.2, ``docs/97`` §50).
    :attr:`LclWorld.object_cells` carries the answer where a caller has the
    meshes to hand, and where it does not the command's own cell is used --
    which is always part of the run when there is one.
    """
    w = it.world
    x, y = p.n(0), p.n(1)
    values = [x, y]
    if w.in_bounds(x, y):
        for cell in w.object_cells.get(w.index(x, y), [w.index(x, y)]):
            w.cell_height[cell] = 0
            w.ctrl_type[cell] = CTRL_TYPE_FREE_PLACE
            values += [cell % w.width, cell // w.width]
    it.event("crush_wall", *values)
    return None


def _c_tile_effect(name: str) -> Callable[[Interpreter, Params], str | None]:
    """The set pieces whose only modelled effect is that they happened.

    ``OpenTube`` and its relatives play an animation on one tile; what they
    change is the scene object, which lives outside this model.  Recording the
    call keeps them diffable instead of silently absent.  ``OpenDoor`` is
    **not** one of them -- it toggles the cell, and has its own handler.
    """

    def handler(it: Interpreter, p: Params) -> str | None:
        it.event(name, p.n(0), p.n(1))
        return None

    return handler


def _c_open_door(it: Interpreter, p: Params) -> str | None:
    """``0x004420c0`` -- **does nothing** when a unit stands on the tile.

    Otherwise it runs ``aDoorOpenSequence`` ``0x00410A20``, which is a
    **toggle** on the low bit of the action point (``docs/26`` §3.4): an odd
    id is a closed door and the call opens it -- ``Free Place``, height 0,
    action point one lower -- and an even one closes it again.  The fog
    rebuild the routine ends with lives outside this model, the way
    ``InsertUnit``'s does.
    """
    x, y = p.n(0), p.n(1)
    w = it.world
    if w.unit_on(x, y) is not None:
        return None
    if w.in_bounds(x, y):
        cell = w.index(x, y)
        ap = w.actpt[cell]
        if ap % 2 == 0:                  # even: 30, 32 -- it is open
            w.cell_height[cell] += interactmod.DOOR_HEIGHT_STEP
            w.actpt[cell] = ap + 1
            w.ctrl_type[cell] = interactmod.FIELD_TYPE_WALL
        else:                            # odd: 31, 33 -- it is closed
            w.ctrl_type[cell] = interactmod.FIELD_TYPE_FREE
            w.actpt[cell] = ap - 1
            w.cell_height[cell] = 0
    it.event("open_door", x, y)
    return None


def _c_actpt_range(name: str) -> Callable[[Interpreter, Params], str | None]:
    """``MoveObjects``/``MoveFireCircles``/``MoveSpores`` -- one routine, three kinds."""

    def handler(it: Interpreter, p: Params) -> str | None:
        it.event(name, p.n(0), p.n(1),
                 len(it.world.cells_with_actpt(p.n(0), p.n(1))))
        return None

    return handler


def _c_record(name: str,
              count: int = 0) -> Callable[[Interpreter, Params], str | None]:
    """A presentation command: recorded with its arguments, never simulated."""

    def handler(it: Interpreter, p: Params) -> str | None:
        it.event(name, *[p.n(i) for i in range(count)])
        return None

    return handler


def _c_record_str(name: str) -> Callable[[Interpreter, Params], str | None]:
    def handler(it: Interpreter, p: Params) -> str | None:
        it.event(name, p.s(0))
        return None

    return handler


def _c_noop(it: Interpreter, p: Params) -> str | None:
    """``PrintAllVars`` and ``Message`` -- a bare call to the empty reporter."""
    return None


def _c_build_visible_map(it: Interpreter, p: Params) -> str | None:
    it.event("build_visible_map",
             it.world.player if p.n(0) == -1 else p.n(0))
    return None


COMMANDS: dict[str, Callable[[Interpreter, Params], "str | None"]] = {
    # flow and variables
    "Goto": _c_goto,
    "SetVarNum": _c_set_var_num,
    "SetVarVar": _c_set_var_var,
    "SetVarRandom": _c_set_var_random,
    "VarAddNum": _c_var_add_num,
    "VarSubNum": _c_var_sub_num,
    "VarAddVar": _c_var_add_var,
    "VarSubVar": _c_var_sub_var,
    # map cells
    "GetActPt": _c_get_actpt,
    "SetActPt": _c_set_actpt,
    "GetCtrlMapType": _c_get_ctrl_type,
    "SetCtrlMapType": _c_set_ctrl_type,
    "GetHeight": _c_get_height,
    "SetHeight": _c_set_height,
    # queries
    "GetTurn": _c_get_turn,
    "GetPlayer": _c_get_player,
    "GetUnits": _c_get_units,
    "GetUnitsInArea": _c_get_units_in_area,
    "GetGroupsInArea": _c_get_groups_in_area,
    "GetUnitsInGroup": _c_get_units_in_group,
    # units
    "InsertUnit": _c_insert_unit,
    "InsertUnitWithGroup": _c_insert_unit_with_group,
    "SetAmmoForUnit": _c_set_ammo_for_unit,
    "LinkChrWithGroup": _c_link_chr_with_group,
    "RoofUnit": _c_roof_unit,
    "GroundUnit": _c_ground_unit,
    "Spores": _c_spores,
    # game control and mission flow
    "SetGameControl": _c_set_game_control,
    "IncGameControl": _c_inc_game_control,
    "EnterNameOfNextMap": _c_enter_name_of_next_map,
    "SetTurnControl": _c_set_turn_control,
    "BuildVisibleMap": _c_build_visible_map,
    # set pieces
    "Platform": _c_platform,
    "Elevator": _c_elevator,
    "Barrier": _c_barrier,
    "FixedStatue": _c_fixed_statue,
    "FootBridge": _c_foot_bridge,
    "FootBridge2": _c_foot_bridge2,
    "Statue": _c_statue,
    "Statue2": _c_statue2,
    "GrowingLand": _c_growing_land,
    "FallingSpores": _c_falling_spores,
    "SetGroundFire": _c_set_ground_fire,
    "ParaBombs": _c_para_bombs,
    "OpenDoor": _c_open_door,
    "OpenTube": _c_tile_effect("open_tube"),
    "OpenPlantTube": _c_tile_effect("open_plant_tube"),
    "OpenFrontDoor": _c_tile_effect("open_front_door"),
    "CrushWall": _c_crush_wall,
    "Bridge": _c_tile_effect("bridge"),
    "FireCircle": _c_tile_effect("fire_circle"),
    "MoveObjects": _c_actpt_range("move_objects"),
    "MoveFireCircles": _c_actpt_range("move_fire_circles"),
    "MoveSpores": _c_actpt_range("move_spores"),
    # presentation: camera, sound, effects, dialogs
    "MoveCamera": _c_record("move_camera", 5),
    "MoveTarget": _c_record("move_target", 2),
    "MovePosition": _c_record("move_position", 3),
    "MoveWorld": _c_record("move_world", 10),
    "RotatingCamera": _c_record("rotating_camera", 3),
    "CreateCameraPath": _c_record("create_camera_path", 5),
    "SaveCamera": _c_record("save_camera"),
    "LoadCamera": _c_record("load_camera"),
    "CreateBGB": _c_record("create_bgb", 8),
    "NewCommands": _c_record("new_commands", 5),
    "SelectNextUnit": _c_record("select_next_unit"),
    "SetVolumeCtrl": _c_record("set_volume_ctrl", 2),
    "CDTrackProgram": _c_record_str("cd_track_program"),
    "ActivateInfo": _c_record_str("activate_info"),
    "ActivateInfoSuccessor": _c_record_str("activate_info_successor"),
    "Dialog": _c_record_str("dialog"),
    "EndDialog": _c_record("end_dialog"),
    "Message": _c_noop,
    "PrintAllVars": _c_noop,
    "?_": _c_record("unit_draw_path", 1),
    "OBJ": _c_record_str("obj"),
    # the balance-table loaders: docs/21 owns them, and `inclib.info` is what
    # applies them.  A mission script never calls one; `Info.lcl` is not run
    # by this model at all, so they are recorded rather than re-implemented.
    "SetUnitInfo": _c_record_str("set_unit_info"),
    "SetWeaponInfo": _c_record_str("set_weapon_info"),
    "SetWeaponInfo2": _c_record_str("set_weapon_info2"),
    "SetEquipInfo": _c_record_str("set_equip_info"),
    "SetCtrlMapInfo": _c_record_str("set_ctrl_map_info"),
    "SetCharismaInfo": _c_record_str("set_charisma_info"),
    # the GUI layout family: pure pass-throughs into `aGUI`'s builders, which
    # no mission script calls.
    "GUI_SetWindow": _c_record("gui_set_window", 4),
    "GUI_SetText": _c_record("gui_set_text", 11),
    "GUI_SetButton": _c_record("gui_set_button", 8),
    "GUI_SetTextButton": _c_record("gui_set_text_button", 7),
    "GUI_SetIcon": _c_record("gui_set_icon", 4),
    "GUI_SetListbox": _c_record("gui_set_listbox", 7),
    "GUI_SetTextOnly": _c_record("gui_set_text_only", 7),
    "GUI_SetTextOnly2": _c_record("gui_set_text_only2", 7),
    "GUI_SetTextbox": _c_record("gui_set_textbox", 1),
    "GUI_LoadBackground": _c_record_str("gui_load_background"),
    "GUI_PrintBackground": _c_record("gui_print_background"),
    "GUI_Render": _c_record("gui_render"),
}


# ---------------------------------------------------------------------------
# Entry points -- docs/20 section 5
# ---------------------------------------------------------------------------

def _slot(letter: str) -> int:
    return ord(letter) - ord("A")


def mission_env(call_type: int, turn: int = 1, player: int = 0,
                x: int = 0, y: int = 0, height_level: int = 0,
                actpt: int = 0, unit_index: int = -1) -> dict[int, int]:
    """What the host writes into the environment array for one call type.

    ``docs/20`` §5 tabulates the whole contract, including the one place the
    engine contradicts itself: the walk (``0x0046e220``) puts the cell's
    **height** in ``_D`` while the warp (``0x0046ef50``) puts its **ActPt**
    there.  This builds the walk's form, which is the ordinary move; no shipped
    mission reads any of ``_B``..``_F`` in ``MoveUnit``, so the difference is
    invisible in the released game and a remake reproduces it per path.
    """
    env = {_slot("A"): call_type}
    if call_type == CALL_NEXT_PLAYER:
        env[_slot("B")] = turn
        env[_slot("C")] = player
    elif call_type == CALL_MOVE_UNIT:
        env[_slot("B")] = x
        env[_slot("C")] = y
        env[_slot("D")] = height_level
        env[_slot("E")] = actpt
        env[_slot("F")] = unit_index
    elif call_type == CALL_ATTACK:
        env[_slot("B")] = x
        env[_slot("C")] = y
    elif call_type == CALL_USE:
        env[_slot("B")] = x
        env[_slot("C")] = y
        env[_slot("D")] = actpt
    elif call_type == CALL_NEXT_TURN:
        env[_slot("B")] = turn
    # InitMap sets none.
    return env


def run(document: dict[str, Any], world: LclWorld,
        env: dict[int, int] | None = None,
        max_steps: int = MAX_STEPS) -> Outcome:
    """Run one invocation of one program against one world."""
    return Interpreter(document, world, env, max_steps).run()

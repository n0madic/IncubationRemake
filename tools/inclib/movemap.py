"""An executable model of ``aBuildMoveMap`` (``0x00430A40``).  See docs/23 §7.

This is the Python side of the three-way fidelity diff the first vertical slice
rests on: GDScript ``core/move_map.gd`` against this, and this against a native
capture taken with ``tools/dbgcall``.  It is written the way
``tools/blob_runtime.py`` is -- exact integer semantics, an explicit hook seam,
no third-party dependencies -- so that a disagreement is a disagreement about
the algorithm and not about the harness.

Three properties are deliberate and must survive refactoring:

**The visited test is ``mp_left == 0``, not a visited set.**  The original
stores the movement points left on arrival in ``cell[+0x0C]``, which starts at
zero, and treats zero as "not yet reached".  A cell entered with exactly zero
points left therefore stays writable and a later, cheaper wave can overwrite
it.  This is *not* Dijkstra and not first-write-wins; it is
first-write-wins-except-zero.  :func:`build` reproduces it.

**``any_friendly_blocked`` says only that the fill never ran.**  It is the
scratch value the *last of eight* directions left behind, and the last four are
the refused diagonals, whose failure path writes it 0 -- so any fill that
executes a single wave clears it, and TRUE can only survive from the write
before the loop.  Measured over 74 native fills: TRUE on exactly the 26 whose
mover had no movement points.  docs/23 §7.6.  Transcribed literally anyway,
because reproducing a constant is cheaper than proving no caller reads it.

**The fill is 4-connected in the cells it reaches, and 8-connected in the
loop.**  ``0x004308C0`` is called with its diagonal flag clear at the only call
site, so directions 4..7 reach nothing -- but the loop still runs them
(``0x00430DC8`` is ``cmp eax, 7``) and they still write the scratch.  Dropping
them agreed with the engine on 71 of 72 captured fills, which is what a
plausible-looking transcription error looks like.  Path *reconstruction*
(``aWalkMoveMap``, docs/23 §8) is 8-connected in cells too, which is a real
asymmetry in the original -- do not "fix" the fill to match it.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Callable, Mapping, Sequence

# --- constants, all from docs/23 §7 and docs/10 §4.5 -----------------------

#: ``cell[+0x00]`` overlay values written by the fill and the warp pass.
STATE_NONE = 0
STATE_REACHABLE = 10
STATE_WARP = 60

#: What the engine's own overlay reset (``aResetMoveOverlay`` ``0x0042EE90``)
#: leaves in ``cell[+0x00]``.  The fill never writes it -- it only ever writes
#: 10 and 60 -- so this model uses :data:`STATE_NONE` for "not marked" and a
#: native capture is mapped onto it.  Keeping the number here is what stops the
#: mapping from looking like a fudge in the comparison code.
STATE_RESET = 1

#: ``cell[+0x07]``; the slot link is 16-bit and 0xFFFF means "no unit".  The
#: portable form uses -1, which is what this module speaks.
NO_UNIT = -1

#: ``docs/21`` §2 -- an impassable field type.
DELAY_IMPASSABLE = 255

#: ``docs/23`` §7.4 -- one map field, the distance a step may climb.
WORLD_UNITS_PER_FIELD = 3200
CLIMB_DIVISOR = 1600
CLIMB_MAX_QUOTIENT = 1

#: ``docs/23`` §7.3 -- the four orthogonal directions, in the order
#: ``0x004308C0`` numbers them.  Directions 4..7 return FALSE because the only
#: call site clears the diagonal flag.
DIR_DELTA = ((0, 1), (-1, 0), (0, -1), (1, 0))

#: How many directions the loop at ``0x00430DC8`` actually runs.  The last four
#: reach no cell, but they are not skippable: their failure path writes the
#: caller's ``anyFriendlyBlocked``.
DIRECTIONS = 8

#: ``docs/23`` §7.2 -- two ping-ponged arrays of 2003 entries; writing entry
#: 2000 is a hard error at ``0x00430DB8``.
QUEUE_HARD_LIMIT = 2000

#: ``docs/23`` §7.1 -- ``special`` values for which the map comes back empty.
SPECIAL_CANNOT_MOVE = (1, 14)
#: ``docs/23`` §7.5 -- the innate warper.
SPECIAL_CAN_WARP = 15

#: ``docs/23`` §7.1 -- ``cell[+0x10]``, the transient obstacle standing on the
#: field.  255 is nothing there.
OBSTACLE_NONE = 255
OBSTACLE_FIRE = 1
OBSTACLE_MINE = 2
OBSTACLE_SHIELD = 3

#: ``docs/22`` §9.1 -- a hidden unit is treated exactly like an empty cell.
VISIBILITY_HIDDEN = 3

#: ``docs/10`` §5.7 -- the aliens' player id, the one a mine does not stop.
PLAYER_ALIEN = 255

#: ``docs/10`` §4.5 -- field types a warp destination may have, and the
#: action-point band it may not (the multiplayer victory points).
WARP_FIELD_TYPES = (0, 1, 8)
WARP_ACTION_POINT_EXCLUDED = range(0x50, 0x5A)
#: ``docs/23`` §7.5 -- the three ranges ``0x00475380`` returns.
WARP_RANGE_JET_PACK = 5
WARP_RANGE_SPECIAL = 7
WARP_RANGE_NONE = 0
#: ``docs/23`` §7.5 -- ``Info.lcl`` annotates equipment 7 "warp & scan".
JET_PACK_EQUIP_ID = 7

#: ``0x0047A410`` -- the eight neighbours a large unit needs clear.
CLEARANCE_DELTA = ((-1, -1), (0, -1), (1, -1), (-1, 0),
                   (1, 0), (-1, 1), (0, 1), (1, 1))
CLEARANCE_FIELD_TYPES = (0, 1)
#: ``docs/21`` §5 -- ``unitinfo[+0x7b]``; 1 is a unit larger than one field.
SIZE_LARGE = 1


class MoveMapError(Exception):
    """Raised when the fill cannot run on the state it was handed."""


def climb_quotient(height_delta: int) -> int:
    """``abs(dh) / 1600`` -- the magic multiply written as the divide it means."""
    value = height_delta if height_delta >= 0 else -height_delta
    return value // CLIMB_DIVISOR


def distance(x0: int, y0: int, x1: int, y1: int) -> int:
    """``aGetDistance`` (``0x0044AE10``): ``floor(sqrt(dx^2 + dy^2))``.

    Euclidean with a floor, in map fields -- not Chebyshev.  ``docs/22`` §4.
    """
    dx = x0 - x1
    dy = y0 - y1
    return int(math.isqrt(dx * dx + dy * dy))


@dataclass(frozen=True)
class Grid:
    """The authored cell arrays the fill reads, row-major, ``width*height`` long."""

    width: int
    height: int
    heights: Sequence[int]
    field_types: Sequence[int]
    action_points: Sequence[int]

    def __post_init__(self) -> None:
        n = self.width * self.height
        for name in ("heights", "field_types", "action_points"):
            got = len(getattr(self, name))
            if got != n:
                raise MoveMapError(
                    f"{name} has {got} entries, expected {n} "
                    f"({self.width}x{self.height})")

    def index(self, x: int, y: int) -> int:
        return y * self.width + x

    def in_bounds(self, x: int, y: int) -> bool:
        return 0 <= x < self.width and 0 <= y < self.height


@dataclass(frozen=True)
class Mover:
    """Everything about the acting unit that the fill reads.

    ``mp`` and ``mp_allowance`` are **inputs**.  The fill spends the unit's
    current ``+0x15`` (docs/23:652 -- ``start[+0x0C] = u->mp``), and the
    allowance from ``0x00475160`` feeds only the ladder-to-ladder step, which
    fires on no shipped cell.  Computing either from equipment is outside this
    model on purpose; supplying them keeps the fill honest about what it uses.
    """

    slot: int
    x: int
    y: int
    player: int
    mp: int
    special: int = 0
    size: int = 0
    has_jet_pack: bool = False
    mp_allowance: int = 0


@dataclass
class MoveMapHooks:
    """The live state the fill consults but the authored map does not carry.

    Supplied as callables so a synthetic case can place fire, a mine, a shield
    or a hidden unit -- none of which occurs on any shipped map, so no corpus
    evidence for those branches exists or can exist.
    """

    #: ``cell[+0x07]`` -- the slot standing on a cell, or ``NO_UNIT``.
    unit_at: Callable[[int, int], int] = lambda x, y: NO_UNIT
    #: ``unit[+0x4F]`` -- 3 is hidden.
    unit_visibility: Callable[[int], int] = lambda slot: 0
    #: ``unit[+0x45]``.
    unit_player: Callable[[int], int] = lambda slot: 0
    #: Whether ``aGetUnitMapElementPtr`` would return a record for the slot.
    #: It returns NULL for an id above 200 ("unit id out of area",
    #: ``0x00477B11``), and ``0x00430C3C`` then **skips the neighbour
    #: entirely** rather than deciding anything about it.  No shipped cell
    #: reaches that arm -- 0 of 1954 unit-bearing cells across the 155
    #: missions name a slot the mission does not place -- so this exists to
    #: keep the two implementations from diverging where the data does not
    #: reach, not because the corpus needs it.
    unit_exists: Callable[[int], bool] = lambda slot: True
    #: ``cell[+0x10]`` -- 255 when nothing stands there.
    obstacle_at: Callable[[int, int], int] = lambda x, y: OBSTACLE_NONE


def hooks_from_arrays(width: int, units: Sequence[int],
                      visibility: Mapping[int, int] | None = None,
                      players: Mapping[int, int] | None = None,
                      obstacles: Sequence[int] | None = None) -> MoveMapHooks:
    """Hooks over plain arrays -- the shape ``map.json`` and the capture use."""
    vis = dict(visibility or {})
    ply = dict(players or {})

    def unit_at(x: int, y: int) -> int:
        return units[y * width + x]

    def obstacle_at(x: int, y: int) -> int:
        if obstacles is None:
            return OBSTACLE_NONE
        return obstacles[y * width + x]

    return MoveMapHooks(
        unit_at=unit_at,
        unit_visibility=lambda slot: vis.get(slot, 0),
        unit_player=lambda slot: ply.get(slot, 0),
        # With no roster supplied every slot is taken to exist, which is what
        # a synthetic case that names no players means.
        unit_exists=(lambda slot: slot in ply) if ply else (lambda slot: True),
        obstacle_at=obstacle_at,
    )


@dataclass
class MoveMapResult:
    """The overlay the fill leaves behind, as a value rather than in the cells."""

    width: int
    height: int
    state: list[int]
    mp_left: list[int]
    any_friendly_blocked: bool
    ret: bool
    #: How many expansion waves ran; the original bounds this by ``u->mp``.
    waves: int = 0
    #: The high-water mark of one wave's queue; ``0x00430DB8`` is a hard error
    #: at :data:`QUEUE_HARD_LIMIT`.
    max_queue: int = 0
    #: ``state`` as the flood left it, before the warp pass overwrote some of
    #: it with :data:`STATE_WARP`.  The original keeps no such copy -- the warp
    #: pass writes over the same byte -- so this is **diagnostic only** and is
    #: deliberately absent from :meth:`to_dict`, which is the shape compared
    #: against the native capture.  The structural invariants need it because a
    #: warp mark can sit on a cell the fill walked through, which would make an
    #: otherwise sound reachable region look disconnected.
    flood_state: list[int] = field(default_factory=list)

    def index(self, x: int, y: int) -> int:
        return y * self.width + x

    def is_reachable(self, x: int, y: int) -> bool:
        return self.state[self.index(x, y)] == STATE_REACHABLE

    def is_warp_target(self, x: int, y: int) -> bool:
        return self.state[self.index(x, y)] == STATE_WARP

    def reachable_cells(self) -> list[int]:
        return [i for i, s in enumerate(self.state) if s == STATE_REACHABLE]

    def warp_cells(self) -> list[int]:
        return [i for i, s in enumerate(self.state) if s == STATE_WARP]

    def to_dict(self) -> dict[str, object]:
        """The diff and trace shape, shared with the GDScript result."""
        return {
            "width": self.width,
            "height": self.height,
            "state": list(self.state),
            "mp_left": list(self.mp_left),
            "any_friendly_blocked": self.any_friendly_blocked,
            "ret": self.ret,
            "waves": self.waves,
            "max_queue": self.max_queue,
        }


def warp_range(mover: Mover) -> int:
    """``0x00475380`` -- docs/10 §4.5 and docs/23 §7.5.

    The Jet Pack path additionally requires movement points left
    (``unit[+0x28] == 1 && unit[+0x15] != 0``), which is why a unit that has
    spent its turn cannot warp with it.
    """
    if mover.has_jet_pack and mover.mp != 0:
        return WARP_RANGE_JET_PACK
    if mover.special == SPECIAL_CAN_WARP:
        return WARP_RANGE_SPECIAL
    return WARP_RANGE_NONE


def build(grid: Grid, mover: Mover, delays: Mapping[int, int],
          hooks: MoveMapHooks | None = None, *,
          pass_friendlies: bool = False,
          any_friendly_blocked: bool = False) -> MoveMapResult:
    """``aBuildMoveMap(u, passFriendlies, &anyFriendlyBlocked, 0)``.

    ``any_friendly_blocked`` is the caller's incoming scratch value; docs/23
    §7.1 leaves it untouched on the ``special`` refusal, which is why it is a
    parameter rather than a local.
    """
    if hooks is None:
        hooks = MoveMapHooks()
    if not grid.in_bounds(mover.x, mover.y):
        raise MoveMapError(
            f"mover at ({mover.x},{mover.y}) is outside {grid.width}x{grid.height}")

    n = grid.width * grid.height
    state = [STATE_NONE] * n
    mp_left = [0] * n

    def result(blocked: bool, waves: int = 0, max_queue: int = 0) -> MoveMapResult:
        return MoveMapResult(grid.width, grid.height, state, mp_left,
                             blocked, True, waves, max_queue, list(state))

    # --- 7.1 refusals, in the original's order ----------------------------
    if mover.special in SPECIAL_CANNOT_MOVE:
        # Returns before touching the caller's scratch.
        return result(any_friendly_blocked)

    blocked = True
    start = grid.index(mover.x, mover.y)

    # **Corrected against the engine.**  docs/23 §7.1 writes the shield refusal
    # before the seeding; a native capture on _C_141 with a shield written into
    # the mover's own cell (tools/movemap_gold.py) comes back with that cell
    # marked 10 and holding the mover's movement points, so the seeding happens
    # first and the refusal returns after it.  The `special` refusal above is
    # the other way round -- it marks nothing -- which is why the two are not
    # interchangeable.
    mp_left[start] = mover.mp
    state[start] = STATE_REACHABLE

    if hooks.obstacle_at(mover.x, mover.y) == OBSTACLE_SHIELD:
        # A unit standing inside a shield cannot move at all.
        return result(False)

    wave: list[tuple[int, int, int]] = [(mover.x, mover.y, mover.mp)]
    waves = 0
    max_queue = 1

    if mover.mp > 0:
        blocked, waves, max_queue = _flood(
            grid, mover, delays, hooks, state, mp_left, wave,
            pass_friendlies, blocked)

    flood_state = list(state)
    _warp_pass(grid, mover, hooks, state)
    out = result(blocked, waves, max_queue)
    out.flood_state = flood_state
    return out


def _flood(grid: Grid, mover: Mover, delays: Mapping[int, int],
           hooks: MoveMapHooks, state: list[int], mp_left: list[int],
           wave: list[tuple[int, int, int]], pass_friendlies: bool,
           blocked: bool) -> tuple[bool, int, int]:
    """The expansion loop of docs/23 §7.2 through §7.4."""
    waves = 0
    max_queue = len(wave)
    # "The outer loop runs at most u->mp waves."
    for _ in range(mover.mp):
        if not wave:
            break
        waves += 1
        nxt: list[tuple[int, int, int]] = []
        for x, y, mp_here in wave:
            here = grid.index(x, y)
            from_type = grid.field_types[here]
            from_height = grid.heights[here]
            for direction in range(DIRECTIONS):
                if direction >= len(DIR_DELTA):
                    # **The loop runs 0..7, not 0..3** (`0x00430DC8` is
                    # `cmp eax, 7`).  `Step` (`0x004308C0`) dispatches through
                    # a jump table whose last four arms begin by testing
                    # `allowDiagonal`, and `aBuildMoveMap`'s only call site
                    # pushes a literal 0 (`0x00430BBD`), so those four always
                    # fail -- which is why a 4-connected fill is right about
                    # *cells*.  They are not a no-op, though: a failed `Step`
                    # takes the caller to `0x00430C64`, which writes the
                    # scratch flag.  Every cell therefore ends its eight
                    # directions with the flag cleared, and that is the whole
                    # reason `anyFriendlyBlocked` is False after any fill that
                    # actually looped.  Dropping these four made the model
                    # agree on 71 of 72 captured fills by luck.
                    blocked = False
                    continue
                dx, dy = DIR_DELTA[direction]
                nx, ny = x + dx, y + dy
                if not grid.in_bounds(nx, ny):
                    # `Step` failed: `to` is never dereferenced on this path,
                    # and the scratch takes the "nothing in the way" value.
                    blocked = False
                    continue
                to = grid.index(nx, ny)
                ok = mp_left[to] == 0
                occupant = hooks.unit_at(nx, ny)
                if occupant != NO_UNIT and not hooks.unit_exists(occupant):
                    # `0x00430C3C` -- a cell naming a slot the unit map has no
                    # record for skips the neighbour outright, without
                    # touching the scratch flag or deciding `ok`.
                    continue
                blocked, ok = _occupancy(hooks, mover, to, nx, ny, ok,
                                         pass_friendlies, blocked)
                if mover.size == SIZE_LARGE and not _clearance(
                        grid, hooks, mover, nx, ny):
                    ok = False
                obstacle = hooks.obstacle_at(nx, ny)
                if obstacle == OBSTACLE_FIRE:
                    ok = False
                if mover.player != PLAYER_ALIEN and obstacle == OBSTACLE_MINE:
                    ok = False
                if not ok:
                    continue

                cost = delays.get(grid.field_types[to], DELAY_IMPASSABLE)
                if grid.field_types[to] == 8 and from_type == 8:
                    # Ladder to ladder: a whole turn's movement, and the height
                    # test is skipped -- which is what a ladder is for.
                    cost += mover.mp_allowance - 1
                elif cost != DELAY_IMPASSABLE:
                    if climb_quotient(grid.heights[to] - from_height) \
                            > CLIMB_MAX_QUOTIENT:
                        cost = DELAY_IMPASSABLE
                if mp_here <= cost or cost == DELAY_IMPASSABLE:
                    continue
                new_mp = mp_here - cost - 1
                if len(nxt) >= QUEUE_HARD_LIMIT:
                    # The original aborts as it writes entry 2000.
                    raise MoveMapError(
                        f"wave queue would reach entry {len(nxt)}; the "
                        f"original aborts at {QUEUE_HARD_LIMIT} (0x00430DB8)")
                mp_left[to] = new_mp
                state[to] = STATE_REACHABLE
                nxt.append((nx, ny, new_mp))
        max_queue = max(max_queue, len(nxt))
        wave = nxt
    return blocked, waves, max_queue


def _occupancy(hooks: MoveMapHooks, mover: Mover, to: int, nx: int, ny: int,
               ok: bool, pass_friendlies: bool,
               blocked: bool) -> tuple[bool, bool]:
    """docs/23 §7.3, transcribed literally including the scratch writes."""
    occupant = hooks.unit_at(nx, ny)
    if (not ok or occupant == NO_UNIT
            or hooks.unit_visibility(occupant) == VISIBILITY_HIDDEN):
        # Nothing in the way -- and a hidden unit counts as nothing, because
        # the AI does not cheat about what it has not spotted.
        blocked = False
    else:
        if not pass_friendlies:
            ok = False
        if hooks.unit_player(occupant) == mover.player:
            blocked = True
        else:
            # `0x00430C60` -- an enemy clears `ok` and **leaves the scratch
            # alone**; only the same-player arm at `0x00430C58` writes it.
            ok = False
    if blocked and occupant == mover.slot:
        # The mover's own cell is always passable.
        blocked = False
        ok = True
    return blocked, ok


def _clearance(grid: Grid, hooks: MoveMapHooks, mover: Mover,
               x: int, y: int) -> bool:
    """``0x0047A410`` -- the large-unit clearance test of docs/23 §7.3.

    All eight neighbours must exist, be empty or hold the mover itself, have
    field type 0 or 1, be at exactly the same height as the candidate, and
    carry no fire.
    """
    here = grid.index(x, y)
    want_height = grid.heights[here]
    for dx, dy in CLEARANCE_DELTA:
        nx, ny = x + dx, y + dy
        if not grid.in_bounds(nx, ny):
            return False
        i = grid.index(nx, ny)
        occupant = hooks.unit_at(nx, ny)
        if occupant != NO_UNIT and occupant != mover.slot:
            return False
        if grid.field_types[i] not in CLEARANCE_FIELD_TYPES:
            return False
        if grid.heights[i] != want_height:
            return False
        if hooks.obstacle_at(nx, ny) == OBSTACLE_FIRE:
            return False
    return True


def _warp_pass(grid: Grid, mover: Mover, hooks: MoveMapHooks,
               state: list[int]) -> None:
    """``0x00430EE0`` -- docs/10 §4.5's five acceptance tests."""
    reach = warp_range(mover)
    if reach == WARP_RANGE_NONE:
        return
    for y in range(grid.height):
        for x in range(grid.width):
            i = grid.index(x, y)
            if state[i] == STATE_REACHABLE:
                # **A sixth test, not in docs/10 §4.5.**  A cell the fill
                # already marked keeps its 10; the warp pass does not overwrite
                # it.  Established natively over three captured warp runs on
                # _C_141, and the test is on `cell[+0x00]` rather than on
                # `cell[+0x0C]`: nine cells marked with zero movement points
                # left -- indistinguishable from unvisited by the fill's own
                # test -- also kept their 10.
                continue
            if hooks.unit_at(x, y) != NO_UNIT:
                continue
            if grid.field_types[i] not in WARP_FIELD_TYPES:
                continue
            if grid.action_points[i] in WARP_ACTION_POINT_EXCLUDED:
                continue
            if hooks.obstacle_at(x, y) in (OBSTACLE_FIRE, OBSTACLE_MINE):
                continue
            if distance(mover.x, mover.y, x, y) > reach:
                continue
            state[i] = STATE_WARP


# --- invariants the corpus can check without an oracle ---------------------


@dataclass
class InvariantReport:
    """Which structural invariants a result satisfies, and why not."""

    failures: list[str] = field(default_factory=list)

    def fail(self, name: str, detail: str) -> None:
        self.failures.append(f"{name}: {detail}")

    @property
    def ok(self) -> bool:
        return not self.failures


def check_invariants(grid: Grid, mover: Mover, delays: Mapping[int, int],
                     result: MoveMapResult,
                     hooks: MoveMapHooks | None = None) -> InvariantReport:
    """The properties of a fill that need no oracle to state.

    Every one of these is a claim about *this* algorithm on *this* corpus, so a
    failure is either a transcription error or a finding about the data.
    """
    report = InvariantReport()
    if hooks is None:
        hooks = MoveMapHooks()
    start = grid.index(mover.x, mover.y)
    flood = result.flood_state or result.state
    marked = [i for i, s in enumerate(flood) if s == STATE_REACHABLE]

    for i in marked:
        if i == start:
            continue
        ft = grid.field_types[i]
        if delays.get(ft, DELAY_IMPASSABLE) == DELAY_IMPASSABLE:
            report.fail("enterable",
                        f"cell {i} marked but field type {ft} has delay 255")
            break

    for i in marked:
        if i == start:
            continue
        spent = mover.mp - result.mp_left[i]
        if not 1 <= spent <= mover.mp:
            report.fail("cost_range",
                        f"cell {i} spent {spent} of {mover.mp}")
            break

    # 4-connected to the start through marked cells.
    seen = {start}
    stack = [start]
    while stack:
        i = stack.pop()
        x, y = i % grid.width, i // grid.width
        for dx, dy in DIR_DELTA:
            nx, ny = x + dx, y + dy
            if not grid.in_bounds(nx, ny):
                continue
            j = grid.index(nx, ny)
            if j in seen or flood[j] != STATE_REACHABLE:
                continue
            seen.add(j)
            stack.append(j)
    stranded = [i for i in marked if i not in seen]
    if stranded:
        report.fail("connected",
                    f"{len(stranded)} marked cells not 4-connected to the start")

    # Every marked cell has an orthogonal predecessor that explains its cost.
    for i in marked:
        if i == start:
            continue
        x, y = i % grid.width, i // grid.width
        cost = delays.get(grid.field_types[i], DELAY_IMPASSABLE)
        found = False
        for dx, dy in DIR_DELTA:
            px, py = x + dx, y + dy
            if not grid.in_bounds(px, py):
                continue
            p = grid.index(px, py)
            if flood[p] != STATE_REACHABLE:
                continue
            if result.mp_left[p] - cost - 1 != result.mp_left[i]:
                continue
            if climb_quotient(grid.heights[i] - grid.heights[p]) \
                    > CLIMB_MAX_QUOTIENT:
                continue
            found = True
            break
        if not found:
            report.fail("predecessor",
                        f"cell {i} (mp_left {result.mp_left[i]}) has no "
                        f"orthogonal predecessor explaining its cost")
            break

    # The fill refuses to write entry 2000, so a wave of exactly
    # QUEUE_HARD_LIMIT entries is legal and only more than that is not.  The
    # test used to be `>=`, which would have failed a wave the fill itself
    # accepts.
    if result.max_queue > QUEUE_HARD_LIMIT:
        report.fail("queue_bound",
                    f"a wave reached {result.max_queue} entries")
    if result.waves > mover.mp:
        report.fail("wave_bound",
                    f"{result.waves} waves for {mover.mp} movement points")
    return report


# --- the shared fixture shape ----------------------------------------------

#: One shape for every move-map comparison, whatever produced it.  The Python
#: reference, the synthetic cases and the native capture all emit this, and one
#: GDScript reader consumes all three -- so a case's inputs reach the two
#: implementations byte-identically by construction rather than by agreement,
#: and the only thing a test file chooses is which oracle boundary it declares.
# ---------------------------------------------------------------------------
# aWalkMoveMap (0x004305E0) -- docs/23 §8
# ---------------------------------------------------------------------------

#: ``cell[+0x00]`` while a reconstructed path stands on it.  A fourth overlay
#: value alongside :data:`STATE_REACHABLE` and :data:`STATE_WARP`, and the only
#: one that survives the routine's own final sweep.
STATE_PATH = 100

#: ``0x00430603`` -- the step budget.  Reaching zero is a failure, not a stop:
#: the sweep does not run and the caller gets FALSE.
WALK_BUDGET = 300

#: ``0x00430A20`` -- the full eight-direction table.  The first four are
#: :data:`DIR_DELTA`; ``aWalkMoveMap`` is the only caller that passes
#: ``allowDiagonal = 1``, which is the asymmetry docs/23 §8 warns about.
WALK_DIR_DELTA = ((0, 1), (-1, 0), (0, -1), (1, 0),
                  (1, -1), (-1, 1), (1, 1), (-1, -1))
FIRST_DIAGONAL = 4

#: ``0x004303E0`` -- the two orthogonal directions that bracket each diagonal,
#: as indices into :data:`WALK_DIR_DELTA`.  Both must be enterable, so a path
#: never cuts a corner past a wall.
CORNER_COMPONENTS = {4: (2, 3), 5: (0, 1), 6: (0, 3), 7: (2, 1)}

#: ``0x00430677`` -- the gradient is compared in sixteenths so that the
#: diagonal tie-break can dock one without crossing a movement point.  The
#: comparison itself is 16-bit (``cmp ax, word [esp+0x14]``), which is why the
#: pointer left in the high half of EAX by ``movzx ax, byte [eax+0xc]`` cannot
#: affect the answer.
GRADIENT_SHIFT = 4
GRADIENT_MASK = 0xFFFF


@dataclass
class WalkResult:
    """What ``aWalkMoveMap`` returns, plus the overlay it leaves behind."""

    ok: bool
    steps: int
    blocked: int
    #: Cell indices in the order the routine marks them: the target first, then
    #: each chosen cell, ending at the source.  Empty when the target could not
    #: be marked at all.
    path: list[int] = field(default_factory=list)
    #: ``cell[+0x00]`` after the routine, which is :data:`STATE_PATH` on the
    #: path and :data:`STATE_RESET` everywhere else -- the routine's own sweep
    #: value, not :data:`STATE_NONE`.  Empty when it returned FALSE, because
    #: then the sweep never ran.
    state: list[int] = field(default_factory=list)
    #: Why it failed, for a diagnostic; ``""`` when it did not.
    reason: str = ""

    def to_dict(self) -> dict[str, object]:
        return {
            "ok": self.ok,
            "steps": self.steps,
            "blocked": self.blocked,
            "path": list(self.path),
        }


def is_enterable(grid: Grid, hooks: MoveMapHooks, delays: Mapping[int, int],
                 x: int, y: int, unit_index: int = NO_UNIT) -> bool:
    """``0x00479C60(x, y, unitIndex)``.

    docs/23 §8 describes this as the routine that "treats ``delay == 255`` as
    not enterable", which is true and incomplete: it also refuses an occupied
    cell and both blocking obstacles.  ``aWalkMoveMap`` passes ``0xFFFF`` as
    the unit index, which matches no slot, so for the corner check the
    occupancy test means "must be empty".
    """
    if not grid.in_bounds(x, y):
        return False
    here = hooks.unit_at(x, y)
    if here != NO_UNIT and here != unit_index:
        return False
    if delays.get(grid.field_types[grid.index(x, y)], DELAY_IMPASSABLE) \
            == DELAY_IMPASSABLE:
        return False
    obstacle = hooks.obstacle_at(x, y)
    if obstacle == OBSTACLE_FIRE:
        return False
    return obstacle != OBSTACLE_MINE


def walk(grid: Grid, result: MoveMapResult, sx: int, sy: int,
         tx: int, ty: int, delays: Mapping[int, int],
         hooks: MoveMapHooks | None = None) -> WalkResult:
    """``aWalkMoveMap(sx, sy, tx, ty, &blocked, &steps)`` -- docs/23 §8.

    Gradient **ascent** from the target back to the source over the movement
    points the fill left in ``cell[+0x0C]``, since the source holds the
    maximum.  ``result`` must be the fill this walk is reading; the original
    reads the cells the fill wrote, and a walk over a stale overlay is exactly
    the mistake the capture's per-walk re-fill exists to avoid.

    Three transcription details a paraphrase loses:

    * acceptance is ``v >= best``, so **later directions win ties** and the
      evaluation order 0..7 is part of the answer;
    * the diagonal dock is ``v > 1 ? v - 1 : 0`` on the *shifted* value, so it
      breaks a tie without ever outranking a whole movement point;
    * the budget is checked **before** each step and a walk that exhausts it
      returns FALSE with the overlay left mid-flight -- the sweep does not run.
    """
    if hooks is None:
        hooks = MoveMapHooks()
    if not grid.in_bounds(tx, ty) or not grid.in_bounds(sx, sy):
        return WalkResult(False, 0, 0, reason="off the map")

    state = [STATE_RESET] * (grid.width * grid.height)
    path = [grid.index(tx, ty)]
    marked = {path[0]}
    steps = 0
    blocked = 0
    budget = WALK_BUDGET
    x, y = tx, ty
    source_unit = hooks.unit_at(sx, sy)

    while (x, y) != (sx, sy):
        if budget <= 0:
            return WalkResult(False, steps, blocked, path,
                              reason="budget exhausted")
        here = grid.index(x, y)
        best = (result.mp_left[here] << GRADIENT_SHIFT) & GRADIENT_MASK
        best_dir = -1
        bx = by = -1
        for direction, (dx, dy) in enumerate(WALK_DIR_DELTA):
            nx, ny = x + dx, y + dy
            if not grid.in_bounds(nx, ny):
                continue
            to = grid.index(nx, ny)
            if climb_quotient(grid.heights[to] - grid.heights[here]) \
                    > CLIMB_MAX_QUOTIENT:
                continue
            if direction >= FIRST_DIAGONAL:
                ax, ay = CORNER_COMPONENTS[direction]
                if not _corner_open(grid, hooks, delays, x, y, ax, ay):
                    continue
            value = (result.mp_left[to] << GRADIENT_SHIFT) & GRADIENT_MASK
            if direction >= FIRST_DIAGONAL:
                value = value - 1 if value > 1 else 0
            if value < best:
                continue
            best = value
            bx, by = nx, ny
            best_dir = direction
        if best_dir < 0:
            # The engine raises CHECK("no direction found") here and returns
            # FALSE without sweeping.
            return WalkResult(False, steps, blocked, path,
                              reason="no direction found")
        steps += 1
        index = grid.index(bx, by)
        path.append(index)
        marked.add(index)
        standing = hooks.unit_at(bx, by)
        if standing != NO_UNIT and standing != source_unit:
            blocked += 1
        budget -= 1
        x, y = bx, by

    if budget == 0:
        # Reaching the source on the very last step still fails: the check is
        # on the budget, not on having arrived.
        return WalkResult(False, steps, blocked, path,
                          reason="budget exhausted")
    for index in marked:
        state[index] = STATE_PATH
    return WalkResult(True, steps, blocked, path, state)


def _corner_open(grid: Grid, hooks: MoveMapHooks, delays: Mapping[int, int],
                 x: int, y: int, first: int, second: int) -> bool:
    """Both orthogonal components of a diagonal must be enterable."""
    for direction in (first, second):
        dx, dy = WALK_DIR_DELTA[direction]
        if not is_enterable(grid, hooks, delays, x + dx, y + dy):
            return False
    return True


CASES_SCHEMA = "incubation.movemap-cases/1"


def make_case(name: str, grid: Grid, units: Sequence[Mapping[str, object]],
              delays: Mapping[int, int], slot: int, pass_friendlies: bool,
              result: "MoveMapResult",
              obstacles: Sequence[int] | None = None,
              walks: Sequence[Mapping[str, object]] | None = None
              ) -> dict[str, object]:
    """One self-contained case: the whole input, the query, and the answer.

    ``walks`` attaches ``aWalkMoveMap`` answers over the *same* fill, so the
    path reconstruction is checked against the identical input rather than
    against a second case that might have drifted.
    """
    n = grid.width * grid.height
    return {
        "name": name,
        "width": grid.width,
        "height": grid.height,
        "cells": {
            "height": list(grid.heights),
            "field_type": list(grid.field_types),
            "action_point": list(grid.action_points),
            "unit": [-1] * n,
            "obstacle": list(obstacles) if obstacles is not None
                        else [OBSTACLE_NONE] * n,
        },
        "delays": {str(k): v for k, v in sorted(delays.items())},
        "units": [dict(u) for u in units],
        "query": {"slot": slot, "pass_friendlies": pass_friendlies},
        "expected": {
            "state": list(result.state),
            "mp_left": list(result.mp_left),
            "any_friendly_blocked": result.any_friendly_blocked,
            **({"walks": [dict(w) for w in walks]} if walks else {}),
        },
    }


def cases_document(oracle: str, source: str,
                   cases: list[dict[str, object]]) -> dict[str, object]:
    return {
        "schema": CASES_SCHEMA,
        "oracle": oracle,
        "source": source,
        "cases": cases,
    }


# ---------------------------------------------------------------------------
# aExecuteMove -- walking the path the walk reconstructed
# ---------------------------------------------------------------------------

#: ``0x0046E645`` / ``0x0046E63B`` -- what a step costs before the field
#: type's delay column is added to it.
STEP_COST_ORTHOGONAL = 1
STEP_COST_DIAGONAL = 2

#: ``docs/10`` §5.10 -- ``unit[+0x50]``, the distance walked this turn, in
#: tenths of a field.  ``0x0046E7B7`` adds these.
STEP_TENTHS_ORTHOGONAL = 10
STEP_TENTHS_DIAGONAL = 15

#: ``docs/26`` §6.1 -- the VictoryPoint band and the two bases it rewrites to.
VICTORY_BAND = range(0x50, 0x5A)
VICTORY_A_LAST = 0x54
VICTORY_A_BASE = 0x51
VICTORY_B_FIRST = 0x55
VICTORY_B_LAST = 0x59
VICTORY_B_BASE = 0x56

#: ``docs/26`` §5 -- the field type that starts a teleport, and the only one
#: ``aExecuteMove`` tests for other than through the delay column.
FIELD_TELEPORT_IN = 9
#: The other half of the pair -- ``0x004701B2``, ``cmp byte [esi+0x0D], 0x0A``.
FIELD_TELEPORT_OUT = 10

#: ``docs/21`` §4 -- the weapon a mine resolves as, 100 damage at 100 hit.
MINE_WEAPON = 36

#: Which cell of a step the delay column is charged for -- **measured**.
#: ``docs/26`` §5 reads two field-type tests for the delay out of
#: ``0x0046EA4B`` and does not say which cells they are, so
#: ``tools/turn_gold.py`` phase 10 wrote a delay-1 type onto the source, the
#: intermediate and the destination of one two-step path and asked the engine
#: what each cost.  Against a baseline of 3:
#:
#: ===============  =====  ==========================================
#: probe            cost   reading it rules out
#: ===============  =====  ==========================================
#: ``plain``          3    --
#: ``delay_source``   3    the cell being **left** is charged
#: ``delay_middle``   4    --
#: ``delay_dest``     4    --
#: ===============  =====  ==========================================
#:
#: The cell being **entered** is charged, and only it: a cell that is entered
#: and then left again costs its delay once, and the cell the walk starts on
#: costs nothing.  The three constants are kept because the reading is what a
#: reader will want to check, not because the value is in doubt.
DELAY_ON_ENTERED = "entered"
DELAY_ON_LEFT = "left"
DELAY_ON_BOTH = "both"
DELAY_CHARGED_ON = DELAY_ON_ENTERED

#: :data:`inclib.lev.FACING_STEPS` inverted -- a step to the facing that takes
#: it.  Kept here rather than imported so this module has no dependency on the
#: file-format side, and asserted equal to it by ``movemap_runtime.py``.
FACING_OF_STEP = {(0, 1): 0, (1, 1): 6, (1, 0): 3, (1, -1): 4,
                  (0, -1): 2, (-1, -1): 7, (-1, 0): 1, (-1, 1): 5}


@dataclass(frozen=True)
class MoveEvent:
    """One thing that happened to the walker on one cell."""

    kind: str
    x: int
    y: int
    #: The action point or obstacle that caused it, or the weapon a mine fired.
    detail: int = 0
    #: What the event carries beyond its cell.  Only ``mine_detonated`` uses
    #: it, and it holds :meth:`inclib.combat.AttackResult.to_dict`.
    payload: dict = field(default_factory=dict)

    def to_dict(self) -> dict[str, object]:
        out: dict[str, object] = {"kind": self.kind, "x": self.x,
                                  "y": self.y, "detail": self.detail}
        if self.payload:
            out["blast"] = self.payload
        return out


@dataclass(frozen=True)
class ExecuteResult:
    """What ``aExecuteMove`` reports, and what it left on the map.

    **The cost is reported, not spent.**  ``docs/23`` §5.3 and ``docs/93`` §11:
    ``u->mp`` is untouched by the call and the caller does
    ``mp = 0 if cost > mp else mp - cost`` afterwards.  This model keeps that
    seam -- :attr:`cost` comes back and :attr:`mp_after` is absent -- because a
    remake that charged inside its own move routine would double-charge the
    AI's path and leave the player's uncharged.
    """

    #: The routine's own return value.  FALSE does **not** mean nothing
    #: happened: a mine ends the walk with the unit moved, its distance
    #: accumulated and its facing turned, and ``aExecuteMove`` still answers
    #: FALSE.  :attr:`steps` is what says how far it got.
    ok: bool
    x: int
    y: int
    #: What argument 5 receives -- **0** on the mine arm, which is not the
    #: cost of the steps that were taken.
    cost: int
    steps: int
    #: The increment to ``unit[+0x50]``, in tenths of a field.
    walked: int
    #: ``unit[+0x46]`` after the walk: the facing of the last step taken.
    facing: int
    #: ``(cell index, new action point)`` for every VictoryPoint claimed.
    action_point_writes: list[tuple[int, int]] = field(default_factory=list)
    events: list[MoveEvent] = field(default_factory=list)
    #: Whether the walk ended on a mine.  ``0x0046EC0F`` gates the whole
    #: detonation block on it, and ``0x0046EC25`` then picks the arm by
    #: ``unitinfo[type].size`` -- which this routine has no table for, so the
    #: block is the caller's (:func:`inclib.ai._detonate`).
    stopped_on_mine: bool = False
    #: The cells an authored mine went off on.  More than one is possible: a
    #: mover of size 1 sweeps its **eight neighbours** rather than the cell it
    #: stopped on.
    detonate: list[tuple[int, int]] = field(default_factory=list)
    #: Set when a mine stopped the walk: ``docs/26`` §6.1 zeroes the mover's
    #: movement points, which the caller applies along with the cost.
    movement_zeroed: bool = False
    #: The cells the walk actually entered, **source first**, in travel order.
    #: Not the reconstructed path: a walk can stop short of it on the budget or
    #: on a mine, and this is what happened rather than what was planned.
    #:
    #: Deliberately **absent from** :meth:`to_dict`.  That document is diffed
    #: against ``MoveResult.to_dict`` and pinned by the native capture in
    #: ``tests/fixtures/movemap/cases_native.json``, which the engine emitted
    #: and which cannot grow a field the engine never had.  It is presentation
    #: data, carried in the AI move event's payload instead.
    route: list[int] = field(default_factory=list)
    #: Whether the walk ended on a teleporter entry.  ``0x0046EA73`` breaks the
    #: walk there and ``0x0046EDEB`` gates the epilogue's
    #: ``aExecuteTeleporter`` call on the same flag, so resolving it is the
    #: caller's (:func:`inclib.ai._teleport`) and :attr:`x`/:attr:`y` are the
    #: entry cell until it runs.  Absent from :meth:`to_dict` for the same
    #: reason as :attr:`route`.
    teleporter: bool = False
    reason: str = ""

    def to_dict(self) -> dict[str, object]:
        return {
            "ok": self.ok, "x": self.x, "y": self.y, "cost": self.cost,
            "steps": self.steps, "walked": self.walked, "facing": self.facing,
            "action_point_writes": [list(w) for w in self.action_point_writes],
            "events": [e.to_dict() for e in self.events],
            "movement_zeroed": self.movement_zeroed,
        }


def _delay_of(grid: Grid, delays: Mapping[int, int], index: int) -> int:
    return delays.get(grid.field_types[index], DELAY_IMPASSABLE)


def execute(grid: Grid, hooks: MoveMapHooks, delays: Mapping[int, int],
            mover: Mover, walked: WalkResult,
            budget: int | None = None) -> ExecuteResult:
    """``aExecuteMove(sx, sy, tx, ty, &cost, 1, 255, 0)`` -- ``0x0046E220``.

    ``walked`` is the :func:`walk` this is following, and its ``path`` is in
    the engine's own order -- target first, source last -- so the steps are
    taken over the reverse of it.  That reversal is where an off-by-one would
    live, which is why it happens here once rather than at every call site.

    Three things happen per step, in this order (``docs/26`` §6.1): the cost
    and the distance accumulate, a VictoryPoint under the arriving unit is
    claimed, and a mine under it goes off -- and a mine ends the walk.
    """
    if not walked.ok or not walked.path:
        return ExecuteResult(ok=False, x=mover.x, y=mover.y, cost=0, steps=0,
                             walked=0, facing=0,
                             reason="no path to follow")
    route = list(reversed(walked.path))
    x, y = route[0] % grid.width, route[0] // grid.width
    if (x, y) != (mover.x, mover.y):
        raise MoveMapError(
            f"the path starts at ({x},{y}) but the mover is at "
            f"({mover.x},{mover.y})")

    cost = 0
    tenths = 0
    steps = 0
    facing = 0
    writes: list[tuple[int, int]] = []
    events: list[MoveEvent] = []
    zeroed = False
    here = route[0]
    entered: list[int] = [route[0]]
    for index in route[1:]:
        nx, ny = index % grid.width, index // grid.width
        dx, dy = nx - x, ny - y
        if (dx, dy) not in FACING_OF_STEP:
            raise MoveMapError(
                f"({x},{y}) -> ({nx},{ny}) is not a step to a neighbour")
        diagonal = dx != 0 and dy != 0
        step = STEP_COST_DIAGONAL if diagonal else STEP_COST_ORTHOGONAL
        if DELAY_CHARGED_ON in (DELAY_ON_ENTERED, DELAY_ON_BOTH):
            step += _delay_of(grid, delays, index)
        if DELAY_CHARGED_ON in (DELAY_ON_LEFT, DELAY_ON_BOTH):
            step += _delay_of(grid, delays, here)
        if budget is not None and cost + step > budget:
            # **The walk is bounded by the mover's real movement points.**
            # Measured: `tools/ai_gold.py`'s plan probes hand the routine a
            # path the level-2 horizon flooded with 30 points and the unit
            # took **one** step of it -- `+0x50` came back 15, one diagonal --
            # while the model walked all seven.  The horizon is a *search*
            # radius (docs/23 §5.1); `0x0040A750` restores `u->+0x15` before
            # it commits, and `aExecuteMove` stops where those points do.
            #
            # `None` keeps the unbounded behaviour, which is what the player's
            # own move wants: the UI never offers a cell the fill did not
            # reach on the unit's real points, so the path is affordable by
            # construction and a budget would be a second, redundant test.
            break
        cost += step
        tenths += STEP_TENTHS_DIAGONAL if diagonal else STEP_TENTHS_ORTHOGONAL
        facing = FACING_OF_STEP[(dx, dy)]
        steps += 1
        x, y, here = nx, ny, index
        entered.append(index)

        action_point = grid.action_points[index]
        if action_point in VICTORY_BAND and mover.player != PLAYER_ALIEN:
            claimed = action_point
            if claimed <= VICTORY_A_LAST:
                claimed = VICTORY_A_BASE + mover.player
            if VICTORY_B_FIRST <= claimed <= VICTORY_B_LAST:
                claimed = VICTORY_B_BASE + mover.player
            writes.append((index, claimed))
            events.append(MoveEvent("victory_point", nx, ny, claimed))

        if grid.field_types[index] == FIELD_TELEPORT_IN:
            # ``0x0046EA73`` -- the walk ends on the entry cell.  The step has
            # already been charged (``0x0046EA42`` subtracts the budget before
            # the test) and the "keep walking" flag is not set on this arm.
            events.append(MoveEvent("teleporter", nx, ny,
                                    grid.action_points[index]))
            return ExecuteResult(ok=True, x=nx, y=ny, cost=cost, steps=steps,
                                 walked=tenths, facing=facing,
                                 action_point_writes=writes, events=events,
                                 movement_zeroed=zeroed, route=entered,
                                 teleporter=True)

        if hooks.obstacle_at(nx, ny) == OBSTACLE_MINE:
            # **Measured, and not what docs/26 §6.1 predicted.**  A mine under
            # the arriving unit ends the walk there, zeroes ``+0x15`` *inside*
            # the routine and makes it return FALSE with **nothing written
            # back through argument 5** -- so the caller's
            # ``mp -= cost`` charges zero, on top of a unit that already has
            # none.  What did **not** happen in the native probe is the
            # ParaBomb: ``aRandom``'s seed was bit-identical either side, the
            # mover's hit points did not move, and the mine was still on the
            # cell afterwards.  **That measurement is the guard, not the
            # rule** (``docs/26`` §6.2): the probe wrote ``+0x10`` onto an
            # ordinary cell and left ``+0x0F`` at 255, so
            # ``aDeleteSpecialObject`` refused and took the routine's FALSE
            # exit.  An authored mine names its object and does go off, which
            # is what :attr:`MoveMapHooks.delete_object` decides -- and its
            # default is the probe's answer, so the capture still agrees.
            events.append(MoveEvent("mine", nx, ny, MINE_WEAPON))
            return ExecuteResult(ok=False, x=nx, y=ny, cost=0, steps=steps,
                                 walked=tenths, facing=facing,
                                 action_point_writes=writes, events=events,
                                 stopped_on_mine=True,
                                 movement_zeroed=True, route=entered,
                                 reason="a mine ended the walk")

    return ExecuteResult(ok=True, x=x, y=y, cost=cost, steps=steps,
                         walked=tenths, facing=facing,
                         action_point_writes=writes, events=events,
                         movement_zeroed=zeroed, route=entered)

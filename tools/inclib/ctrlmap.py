"""The transient objects a control-map cell owns -- ``docs/23`` §7.1 and
``docs/42`` §9.1.

Four placers write the cell bytes ``+0x0E``..``+0x13`` and take a slot in the
**80-entry** special-object array ``[0x004FA828]``:

======  ==========  ====================  ==========================
byte    name        written by            what it is
======  ==========  ====================  ==========================
+0x0E   timer       fire, mine, shield    the countdown / intensity
+0x0F   object      fire, mine, shield    the array slot, 255 = none
+0x10   state       fire, mine, shield    1 fire, 2 mine, 3 shield
+0x11   decal       glow                  the array slot, 255 = none
+0x12   phase       glow                  1 or 2, the ground fire's phase
+0x13   decal state glow                  4 while a glow stands there
======  ==========  ====================  ==========================

``+0x10`` is the one the rules read: the move map refuses a fire outright, a
mine to anyone but the aliens, and a shield to everyone including the unit
standing in it (``docs/23`` §7.1).  ``+0x13`` carries no movement rule, but the
glow it marks becomes a **fire that removes every unit around it** two rounds
later, which is why this module carries both halves of the round tick.

The rules need the slot, not the position, so :func:`place_fire` and its three
neighbours write cell bytes and nothing else.  The **position** each object is
given is :func:`object_position`, which is a transcription of the same
instructions and is what the picture calls: the fire and the glow scatter
themselves inside the cell with two ``aRandom2`` draws each and the mine and
the shield take the cell's object position exactly.  That generator is the
presentation's (``docs/22`` §3.2, seeded from ``GetTickCount``), so it is
handed in rather than kept here.

``aGetSymbolObjectPtr`` (``0x00404C40``) is the other thing left out: every
placer looks the cell's land object up and takes a ``CHECK`` failure exit when
there is none.  Every shipped cell names one, so the lookup is modelled as
always succeeding and this is the only place that says so.

**The model name is a gate, and it is not a formality.**
``aCreateSpecialObject`` resolves the name through ``0x004038F0`` and answers
-1 for one the loaded world set does not carry -- the same rule ``docs/28``
§7.5 records for the blob models.  All nine world sets carry ``A_FIRE1/2/3``,
``A_MINE`` and ``A_SHILD``; **only ``World_D00`` carries ``GLOW1/2``**, and the
two missions that use ``SetGroundFire`` (``_C_116`` and ``_S_007``) are both in
it.  Measured: a glow placed on ``World_A00`` in the live engine writes
nothing at all (``docs/97`` §37).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

# --- the array -------------------------------------------------------------

#: ``aCreateSpecialObject`` ``0x004069C0`` scans ids **0..79** for a free slot
#: (``inc edi / cmp edi, 0x50 / jl``) and answers -1 when it finds none.
SPECIAL_OBJECT_SLOTS = 80
#: ``aDeleteSpecialObject`` ``0x00406960`` accepts **0..80** -- one more than
#: the constructor can hand out (``cmp eax, 0x50 / jg``).  The asymmetry is the
#: engine's; it only matters for the id nothing can occupy.
DELETE_MAX_OBJECT_ID = 80
#: The free marker in the array's ``+0x40`` and in the two cell slot bytes.
NO_OBJECT = 255

# --- the cell bytes --------------------------------------------------------

OBSTACLE_NONE = 255
OBSTACLE_FIRE = 1
OBSTACLE_MINE = 2
OBSTACLE_SHIELD = 3

DECAL_NONE = 255
#: The glow's own state byte value -- ``mov byte [ebp + 0x13], 4``.
DECAL_GLOW = 4

#: ``0x0042FCB0``'s two phases, and the models they name.  Phase 2 is the one
#: ``SetGroundFire`` lays; the round tick decays it to 1 and the next round's
#: sweep ignites it.
GLOW_PHASE_LIT = 1
GLOW_PHASE_FRESH = 2
GLOW_MODELS = {GLOW_PHASE_LIT: "GLOW2.3DI", GLOW_PHASE_FRESH: "GLOW1.3DI"}

#: ``0x0042F95F``/``0x0042F981``/``0x0042F9A3`` -- the fire's model by subtype.
FIRE_MODEL_SMALL = "A_FIRE3.3DI"
FIRE_MODEL_MEDIUM = "A_FIRE2.3DI"
FIRE_MODEL_LARGE = "A_FIRE1.3DI"
MINE_MODEL = "A_MINE.3DI"
SHIELD_MODEL = "A_SHILD.3DI"

#: The field types the fire, mine and shield placers accept
#: (``cmp al, 0 / 1 / 6 / 8``).
PLACER_FIELD_TYPES = (0, 1, 6, 8)
#: The fire placer's **first** gate is the cell's action point, not its field
#: type: ``cmp al, 0x47`` at ``0x0042F894`` is 71, ``ENTRY_POINT_DESTROYED``.
#: A destroyed entry point burns whatever its field type says.
FIRE_ACTION_POINT = 71
#: ``cmp eax, 0x640`` -- the fire refuses a cell more than half a field away in
#: height from the z its caller passes.
FIRE_HEIGHT_WINDOW = 0x640
#: ``mov byte [ebp + 0x0E], 2`` at ``0x0042FBF9`` -- the shield's countdown,
#: written **before** the "already a shield" return, so a second Plasma hit on
#: a shielded cell refreshes it without making a second object.
SHIELD_TIMER = 2

#: ``0x0040D962``..``0x0040D9FF`` -- weapon 40 lays **nine** fires around the
#: target cell, the centre at subtype 4 and the eight neighbours at 3, all at
#: the centre cell's own height.  In call order.
NINE_FIRES = (
    (-1, 0, 3), (-1, -1, 3), (-1, 1, 3),
    (1, 0, 3), (1, -1, 3), (1, 1, 3),
    (0, 0, 4), (0, -1, 3), (0, 1, 3),
)

#: The impact arms of ``aPlayFightAnimation`` that place one (``docs/42`` §9.1).
WEAPON_GROUND_FIRE = 40
WEAPON_MINE = 42
WEAPON_SHIELD = 43

#: ``0x0046E0BF`` -- the destroyed entry point writes its action point first,
#: then burns with subtype 6 at ``cell height - 0xA0``.  Nothing writes the
#: height: the drop is the placer's z argument and reaches only its window
#: test.
ENTRY_POINT_FIRE_SUBTYPE = 6
ENTRY_POINT_FIRE_Z_DROP = 0xA0

#: ``0x004308C0``'s eight directions, in the order it numbers them.  The ground
#: fire is the one caller that passes the diagonal flag **set**
#: (``push 1`` at ``0x00415963``), so all eight reach a cell.
STEP_DELTA = ((0, 1), (-1, 0), (0, -1), (1, 0),
              (1, -1), (-1, 1), (1, 1), (-1, -1))


class CtrlMapError(Exception):
    """Raised when the model is asked for something the engine refuses."""


@dataclass
class CtrlMap:
    """The ten cell columns the placers touch, plus the object array.

    The columns are the caller's own lists, aliased rather than copied, so a
    placer writes through to whichever world handed them over.  The array is
    **derived** state: ``aBuild3DSpecialObjects`` (``0x004079D0``) rebuilds it
    from the same cell bytes after every load, so it is never saved and never
    hashed -- :func:`rebuild_objects` is what a loader calls instead.
    """

    width: int
    height: int
    cell_height: list[int]      # +0x01
    unit_at: list[int]          # +0x07, the unit slot, -1 for none
    action_point: list[int]     # +0x0B
    field_type: list[int]       # +0x0D
    effect_timer: list[int]     # +0x0E
    effect_object: list[int]    # +0x0F
    effect_state: list[int]     # +0x10
    decal_object: list[int]     # +0x11
    decal_phase: list[int]      # +0x12
    decal_state: list[int]      # +0x13
    objects: list[int] = field(default_factory=list)
    #: The prototype names the loaded world set carries, or ``None`` to skip
    #: the check.  ``None`` is for a synthetic world with no world set behind
    #: it; a real one must pass the set, or a ``SetGroundFire`` outside
    #: ``World_D00`` will appear to work.
    models: "frozenset[str] | None" = None

    def in_bounds(self, x: int, y: int) -> bool:
        return 0 <= x < self.width and 0 <= y < self.height

    def index(self, x: int, y: int) -> int:
        return y * self.width + x


def rebuild_objects(cells: CtrlMap) -> list[int]:
    """``aBuild3DSpecialObjects`` ``0x004079D0``, as occupancy only.

    The engine re-runs the placers for every cell whose ``+0x10`` is 1, 2 or 3
    and every cell whose ``+0x13`` is 4, which reassigns the ids in grid order.
    This model keeps the ids the cells already carry -- they are equivalent for
    everything that reads them -- and only marks the slots busy.
    """
    slots = [NO_OBJECT] * SPECIAL_OBJECT_SLOTS
    for i in range(len(cells.effect_state)):
        state = cells.effect_state[i]
        oid = cells.effect_object[i]
        if state in (OBSTACLE_FIRE, OBSTACLE_MINE, OBSTACLE_SHIELD) \
                and 0 <= oid < SPECIAL_OBJECT_SLOTS:
            slots[oid] = state
        if cells.decal_state[i] == DECAL_GLOW:
            oid = cells.decal_object[i]
            if 0 <= oid < SPECIAL_OBJECT_SLOTS:
                slots[oid] = DECAL_GLOW
    cells.objects = slots
    return slots


def create_object(cells: CtrlMap, state: int, model: str) -> int:
    """``aCreateSpecialObject`` ``0x004069C0`` -- the first free slot, or -1.

    Two failures, both the engine's: a full array, and a model the loaded
    world set does not carry (*"unknown object!"*, ``0x004069F4``).
    """
    if cells.models is not None and model not in cells.models:
        return -1
    for oid in range(SPECIAL_OBJECT_SLOTS):
        if cells.objects[oid] == NO_OBJECT:
            cells.objects[oid] = state
            return oid
    return -1


def delete_object(cells: CtrlMap, object_id: int) -> bool:
    """``aDeleteSpecialObject`` ``0x00406960`` -- the guard every cell-based
    detonation is behind (``docs/26`` §6.2).

    True for an id in 0..80, having marked the slot free; False for anything
    else, which is the ``CHECK`` failure the walk's mine arm returns on.
    """
    if not 0 <= object_id <= DELETE_MAX_OBJECT_ID:
        return False
    if object_id < SPECIAL_OBJECT_SLOTS:
        cells.objects[object_id] = NO_OBJECT
    return True


# --- the four placers ------------------------------------------------------


def place_fire(cells: CtrlMap, x: int, y: int, subtype: int, z: int) -> int:
    """``0x0042F840`` -- burning ground, ``+0x10 = 1``.  The object id or -1.

    The one placer that clears what is already on the cell: a mine's object is
    deleted **without** detonating it, and a shield refuses the whole call.
    """
    if not cells.in_bounds(x, y):
        return -1
    i = cells.index(x, y)
    if cells.action_point[i] != FIRE_ACTION_POINT \
            and cells.field_type[i] not in PLACER_FIELD_TYPES:
        return -1
    if abs(cells.cell_height[i] - z) >= FIRE_HEIGHT_WINDOW:
        return -1
    if cells.effect_state[i] != OBSTACLE_NONE:
        if cells.effect_state[i] == OBSTACLE_SHIELD:
            return -1
        if cells.effect_object[i] != NO_OBJECT:
            delete_object(cells, cells.effect_object[i])
    oid = create_object(cells, OBSTACLE_FIRE, fire_model(subtype))
    if oid < 0:
        cells.effect_timer[i] = 0
        cells.effect_state[i] = OBSTACLE_NONE
        return -1
    cells.effect_object[i] = oid
    cells.effect_timer[i] = subtype & 0xFF
    cells.effect_state[i] = OBSTACLE_FIRE
    return oid


def fire_model(subtype: int) -> str:
    """The model the fire placer's switch picks -- ``docs/42`` §9.1."""
    if subtype in (0, 1):
        return FIRE_MODEL_SMALL
    if subtype in (2, 3):
        return FIRE_MODEL_MEDIUM
    return FIRE_MODEL_LARGE


def place_mine(cells: CtrlMap, x: int, y: int) -> int:
    """``0x0042FA70`` -- a mine, ``+0x10 = 2``.

    It neither deletes what stood there nor refuses a shield: the two bytes
    are simply overwritten, and whatever object the cell named is orphaned.
    Transcribed as it is.
    """
    if not cells.in_bounds(x, y):
        return -1
    i = cells.index(x, y)
    if cells.field_type[i] not in PLACER_FIELD_TYPES:
        return -1
    cells.effect_timer[i] = 0
    oid = create_object(cells, OBSTACLE_MINE, MINE_MODEL)
    if oid < 0:
        cells.effect_timer[i] = 0
        cells.effect_state[i] = OBSTACLE_NONE
        return -1
    cells.effect_object[i] = oid
    cells.effect_state[i] = OBSTACLE_MINE
    return oid


def place_shield(cells: CtrlMap, x: int, y: int) -> int:
    """``0x0042FB90`` -- the Plasma Gun's shield, ``+0x10 = 3``.

    ``+0x0E`` is written **before** the "already a shield" return, so a second
    hit on the same cell refreshes the two-round countdown and leaves the one
    object standing.
    """
    if not cells.in_bounds(x, y):
        return -1
    i = cells.index(x, y)
    if cells.field_type[i] not in PLACER_FIELD_TYPES:
        return -1
    cells.effect_timer[i] = SHIELD_TIMER
    if cells.effect_state[i] == OBSTACLE_SHIELD:
        return -1
    oid = create_object(cells, OBSTACLE_SHIELD, SHIELD_MODEL)
    if oid < 0:
        cells.effect_timer[i] = 0
        cells.effect_state[i] = OBSTACLE_NONE
        return -1
    cells.effect_object[i] = oid
    cells.effect_state[i] = OBSTACLE_SHIELD
    return oid


def place_glow(cells: CtrlMap, x: int, y: int, phase: int) -> int:
    """``0x0042FCB0`` -- ``SetGroundFire``'s glow, ``+0x13 = 4``.

    The one placer with no gate on the cell, its own three cell bytes, and no
    write on failure -- which is what happens on every world set but
    ``World_D00``, because the models live only there.  ``phase`` outside 1..2 is the engine's
    *"unknown phase for ground fire object"* abort.
    """
    if not cells.in_bounds(x, y):
        return -1
    if phase not in GLOW_MODELS:
        raise CtrlMapError(f"unknown phase for ground fire object: {phase}")
    i = cells.index(x, y)
    oid = create_object(cells, DECAL_GLOW, GLOW_MODELS[phase])
    if oid < 0:
        return -1
    cells.decal_object[i] = oid
    cells.decal_phase[i] = phase
    cells.decal_state[i] = DECAL_GLOW
    return oid


#: ``push 0x258 / push 0xFFFFFED4`` -- the fire's and the glow's scatter,
#: ``aRandom2(-300, 600)``, drawn twice: the **first** draw is added to the
#: object's y and the second to its x (``0x0042F9F2``..``0x0042FA1A``).
SCATTER_BASE = -300
SCATTER_SPAN = 600


def object_position(origin: "tuple[int, int, int]", state: int,
                    draw: "Callable[[int, int], int] | None" = None,
                    ) -> tuple[int, int, int]:
    """Where a placer puts its object -- ``docs/42`` §9.1.

    ``origin`` is the cell's own object, ``aGetSymbolObjectPtr(cell[+0x05])``
    at ``+0x10``/``+0x14``/``+0x18``.  The mine and the shield take it
    unchanged; the fire and the glow scatter around it with two draws, and
    ``draw`` is the caller's ``aRandom2``.  With no ``draw`` the scatter is
    zero, which is a picture with no generator rather than a wrong one.

    Measured: ``presentation_gold``'s eight ``special_*`` phases read the
    whole 66-byte record back and compare all three fields (``docs/97`` §37).
    """
    x, y, z = origin
    if state not in (OBSTACLE_FIRE, DECAL_GLOW) or draw is None:
        return x, y, z
    # The order is the engine's: the first draw lands on **y**.
    y += draw(SCATTER_BASE, SCATTER_SPAN)
    x += draw(SCATTER_BASE, SCATTER_SPAN)
    return x, y, z


# --- the round tick --------------------------------------------------------


def round_tick(cells: CtrlMap) -> list[int]:
    """``0x0042ED60`` -- one sweep of the whole grid, once per **round**.

    The hand-over ``0x0047D600`` runs it after the turn counter goes up and
    before the ``NEXT TURN`` event (``docs/25`` §4), so it is a round tick and
    not a per-player one.  Three decays, in the order the sweep applies them:

    * a glow at phase 2 becomes one at phase 1 -- a new object, so the old one
      is deleted first;
    * a fire loses one intensity and goes out below 2, its object replaced
      each time;
    * a shield loses one from its countdown and expires at 1.

    A mine is not touched by any of it: it stands until something walks on it.

    Answers the cell indices that changed, so a caller can repaint those and
    not the whole map.  Flat indices, and the same shape
    ``CellObjects.round_tick`` answers -- the two are diffed by name nowhere,
    so they have to agree by construction.
    """
    changed: list[int] = []
    for i in range(len(cells.effect_state)):
        x, y = i % cells.width, i // cells.width
        if cells.decal_state[i] == DECAL_GLOW \
                and cells.decal_phase[i] == GLOW_PHASE_FRESH:
            delete_object(cells, cells.decal_object[i])
            place_glow(cells, x, y, GLOW_PHASE_LIT)
            changed.append(i)
        state = cells.effect_state[i]
        if state == OBSTACLE_FIRE:
            delete_object(cells, cells.effect_object[i])
            if cells.effect_timer[i] <= 1:
                cells.effect_state[i] = OBSTACLE_NONE
                cells.effect_timer[i] = 0
            else:
                place_fire(cells, x, y, cells.effect_timer[i] - 1,
                           cells.cell_height[i])
            changed.append(i)
        elif state == OBSTACLE_SHIELD:
            if cells.effect_timer[i] == 1:
                delete_object(cells, cells.effect_object[i])
                cells.effect_state[i] = OBSTACLE_NONE
                cells.effect_timer[i] = 0
            else:
                cells.effect_timer[i] -= 1
            changed.append(i)
    return changed


def glows_to_ignite(cells: CtrlMap) -> list[tuple[int, int]]:
    """``0x00470AB0`` -- the cells whose glow has reached phase 1.

    Called from the hand-over immediately **before** :func:`round_tick`, so a
    glow laid this round is decayed by the tick and ignited by the sweep a
    round later.  Clears ``+0x13`` and frees the object as it goes; what the
    ignition then does is :func:`ground_fire_victims`.
    """
    out: list[tuple[int, int]] = []
    for i in range(len(cells.decal_state)):
        if cells.decal_state[i] != DECAL_GLOW \
                or cells.decal_phase[i] != GLOW_PHASE_LIT:
            continue
        delete_object(cells, cells.decal_object[i])
        cells.decal_state[i] = DECAL_NONE
        out.append((i % cells.width, i // cells.width))
    return out


def ground_fire_cells(cells: CtrlMap, x: int, y: int) -> list[int]:
    """``aPlayGroundFireAnimation`` ``0x004157B0`` -- the cells it reaches.

    The eight neighbours through ``0x004308C0`` with the diagonal flag set,
    then the centre.  A cell whose ``+0x10`` is a **shield** is skipped, which
    is the only thing that survives standing in one.
    """
    out: list[int] = []
    for dx, dy in STEP_DELTA:
        nx, ny = x + dx, y + dy
        if not cells.in_bounds(nx, ny):
            continue
        out.append(cells.index(nx, ny))
    if cells.in_bounds(x, y):
        out.append(cells.index(x, y))
    return [i for i in out if cells.effect_state[i] != OBSTACLE_SHIELD]


def ground_fire_victims(cells: CtrlMap, x: int, y: int) -> list[int]:
    """The unit slots ``aPlayGroundFireAnimation`` removes.

    It is not damage: the routine hides each unit's object, drops blood and
    debris on it and then calls ``aRemoveUnitElement`` (``0x004779C0``) for
    every one it collected.  There is no roll and no armour --
    ``SetGroundFire`` kills whatever the flames reach.
    """
    out: list[int] = []
    for i in ground_fire_cells(cells, x, y):
        slot = cells.unit_at[i]
        if slot is not None and slot >= 0:
            out.append(slot)
    return out


def ground_effects_tick(cells: CtrlMap,
                        remove_unit: "Callable[[int], None] | None" = None,
                        ) -> dict[str, list]:
    """The hand-over's two ground sweeps, in the order ``0x0047D600`` has them.

    ``0x00470AB0`` first -- every glow that reached phase 1 ignites, and the
    fire removes what it catches -- and then ``0x0042ED60``, which decays the
    glows, the fires and the shields.  Running the ignition first is what gives
    a glow its two-round fuse: laid at phase 2, decayed to 1 by the tick, and
    burnt by the next round's sweep.
    """
    ignited = glows_to_ignite(cells)
    killed: list[int] = []
    for x, y in ignited:
        for slot in ground_fire_victims(cells, x, y):
            killed.append(slot)
            if remove_unit is not None:
                remove_unit(slot)
    changed = round_tick(cells)
    return {"ignited": [cells.index(x, y) for x, y in ignited],
            "killed": killed, "changed": changed}

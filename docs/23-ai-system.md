# The AI turn — orders, movement and target selection

What the computer player does with its turn. Like
[`22`](22-combat-and-visibility.md) this describes **behaviour, not a file
format**: nothing here is stored on disk. Its inputs are, though — the AI
orders in the unit records ([`10` §5.6](10-lev-mission-format.md)), the
movement-cost table in `Info.lcl` ([`21` §2](21-info-lcl-schema.md)) and the
field grid itself — and a remake that loads all of them still has no opponent
without what follows.

Everything is recovered from `Incubation.exe`. Two source modules own it:
`C:\aProject\Project\Sources\Game\GameTools\aAISystem.cpp` is the turn loop and
the eleven order handlers; `C:\aProject\Project\Sources\Game\Modules\aCtrlMap.cpp`
owns the move map and the path walk, which the human player's UI uses too.

`tools/ai_tables.py --check gog_incubation` verifies the jump tables, the
thresholds and the corpus counts this document quotes.

---

## 1. Names

Recovered with `tools/trace_names.py`, which pairs each compiled-out `CHECK`
macro with the `call` it guards ([`22` §1](22-combat-and-visibility.md)). The
name a site pushes is the **callee's**, so these are read off directly:

| Address | Name | From | Role |
|---|---|---|---|
| `0x00409940` | `aAISystemControl` | `aViewPlayer.cpp:2080` | the whole AI turn |
| `0x0040B2D0` | `aAI_SpecialPlayerControl` | `aAISystem.cpp:181` | the pseudo-player 252 pass |
| `0x00430A40` | `aBuildMoveMap` | `aAISystem.cpp:1773`…`1853` (×6) | reachability flood fill |
| `0x0046E220` | `aExecuteMove` | `aAISystem.cpp:2179` | walk the path |
| `0x0046EF50` | `aExecuteWarp` | `aAISystem.cpp:2168` | jump to a warp cell |
| `0x0047B600` | `isArcing` | [`22` §5.5](22-combat-and-visibility.md) | weapon ids 8, 13, 42, 46 |
| `0x004702C0` | `aExecuteBomb` | `aTacTools.cpp:6446` | detonation |
| `0x004792A0` | `aChangeUnitViewDirection` | `aAISystem.cpp:2514` | turn a unit |
| `0x0042F730` | `aGetCtrlMapElementPtr` | many | `GetCellPtr(x, y)` |
| `0x00477AE0` | `aGetUnitMapElementPtr` | many | `GetUnitPtr(i)` |

**`aBuildMoveMap` is `0x00430A40`, not `0x0040A750`.** `0x0040A750` is the
function that *calls* it six times — the classic caller/callee trap this
project documents. `0x00430A40` is the address [`21` §5](21-info-lcl-schema.md)
already cites for the two immobility specials.

The rest of the module has no recovered name and is referred to by address. The
five that matter get a working gloss here, marked as such:

| Address | Size | Working name | Basis |
|---|---|---|---|
| `0x0040A440` | 443 | *fire once* | subtracts the weapon's AP cost and calls `aAttackUnit` |
| `0x0040A750` | 1566 | *plan and execute one action* | builds a move map, picks a cell, calls `aExecuteMove`/`aExecuteWarp` |
| `0x0040A600` | 220 | **the door opener** | steps up to a cell whose action point is 31 — *standard Door — CLOSED* in the game's own legend, [`10` §4.6](10-lev-mission-format.md) — and plays `aDoorOpenSequence` (`0x00410A20`) |
| `0x0040B380` | 110 | *end this unit's turn* | faces a direction, then sets MP to 0 |
| `0x0040ADC0` | 563 | *pick an approach cell* | scans the ring(s) around a target cell |
| `0x0042EE90` | 46 | *reset the overlay* | writes `cell[+0x00] = 1` and `cell[+0x0C] = 0` over the whole grid, and does nothing else |

`0x0040A750` is **one** function, not several: the only run of alignment
padding between `0x0040A750` and the next known entry point `0x0040ADC0` is at
`0x0040ADB8`, its own tail. Its `CHECK` line numbers are not monotonic in
address (1773…1853, then 2168/2179, then 1928…2073) because MSVC reordered the
blocks, not because the boundary is wrong.

**`aInitAISystem` does not exist, and the AI module has no initialiser.**
`aMain.cpp:922` pushes that name for `0x0040B4D0`, and the name is wrong. Three
things settle it.

*The module boundary.* Attributing every function in `0x00409900`–`0x0040D000`
to the `__FILE__` its own `CHECK` sites report gives three contiguous blocks:
`aAISystem.cpp` at `0x00409910`–`0x0040B3EF` (lines 181 … 2514),
`aAmbience.cpp` at `0x0040B3F0`–`0x0040B4CF` (lines 174, 207) and
`aAnimations.cpp` from `0x0040B4D0` on (411, 448, 1364 … 3468). `0x0040B4D0` is
the first function of the animations module, and the alignment padding at
`0x0040B625` is its own tail.

*The globals.* It touches none of the four the AI turn uses. `0x004FAE38` and
`0x004FAE40` are referenced only from functions inside the `aAISystem.cpp`
block; the five `0x0040B4D0` zeroes (`0x004FCEC0`, `0x004FCEC8`, `0x004FCECC`,
`0x004FC018`, `0x004FC01C`) belong to `0x0040BD70`, the 10 KB animation player.

*Elimination.* `aMain` calls into the whole `aAISystem.cpp` block exactly once,
at `0x0044A281`, and that call is `0x0040B360` — the one-line setter for the
"the AI may fire" flag. There is no init call. Meanwhile the animation system
must be initialised somewhere, and `0x0040B4D0` has exactly one caller in the
binary: the site labelled `aInitAISystem`. The hand-written name is attached to
another module's function — a third failure mode for
[`22` §1](22-combat-and-visibility.md)'s caveat, beyond the two it lists.

The AI module needs no init: of its four globals, `0x004FAE3C` is written once
and read nowhere, `0x004FAE5C` belongs to the ambience block and is likewise
never read, `0x004FAE38` is set on entry to every turn, and `0x004FAE40` has
its own setter and getter.

### 1.2 What the module never named

Two function names and eleven order names are the whole of the AI's surviving
vocabulary. The order names are in **both** binaries: `Incubation.exe` holds
them at `0x004CC470`–`0x004CC504` and `0x00469990` pushes each one twice, into
a primary and a secondary list box — the same pair of controls the editor has
([`10` §5.6](10-lev-mission-format.md)), independently confirmed from the game.

The two counters §2 turns on have **no name anywhere, and could not have one.**
The only mechanism that preserves an identifier in these binaries is the
compiled-out `CHECK` macro, and it pushes a *callee's* name, a `__FILE__` and a
`__LINE__` — never a local or a parameter. `pass` and `level` are exactly that:
one parameter reused as a counter and one local. Enumeration agrees: sweeping
both binaries in ASCII and UTF-16 for 34 candidate tokens (`Pass`, `Level`,
`Aggress`, `Phase`, `Radius`, `Horizon`, `Stage`, `Tier`, `Wave`, `Round`,
`Iteration`, `Depth` and their lower-case forms, with `aAISystemControl` as the
positive control) turns up only `aInitPassWord`, `Load Wave`,
`aFreeAllAmbienceWaves`, `unknown phase for ground fire object` and the
options-screen texts. Nothing AI-related.

One near-miss is worth foreclosing. **`aiLevel()` is not this level.**
`0x00460450` — `Game.opt +0x18`, the difficulty setting
([`22` §12](22-combat-and-visibility.md)) — has eleven call sites in
`Incubation.exe` and **not one of them is inside `aAISystem.cpp` or the move
map**. The difficulty changes how many units `InsertUnit` spawns and how damage
rolls ([`20`](20-lcl-language.md), [`22` §7.4](22-combat-and-visibility.md));
it does not change a single thing the computer does with its turn.

---

## 2. The shape of a turn — **[code] `aAISystemControl` `0x00409940`**

```c
BOOL aAISystemControl(int player, int pass, void (*redraw)(void));
```

The third argument is a redraw callback, stashed in `0x004FAE38`; the second is
overwritten immediately and reused as a loop counter, as is the third's slot.
The body is two nested counters around one sweep of the 200-slot unit array:

```c
g_aiPass  = pass;            /* 0x004FAE3C -- written here and read nowhere */
g_redraw  = redraw;          /* 0x004FAE38 */
setAIRunning(1);             /* 0x0040B4C0 -> 0x004FAE5C = 1 */
if (g_redraw) { g_redraw(); g_redraw(); }
aAI_SpecialPlayerControl();

for (pass = 0; pass < 2; pass++) {
    level = 0;  more = TRUE;
    do {
        do {
            repeat = FALSE;
            for (i = 0; i < 200; i++) {
                Unit *u = &units[i];
                if (u->hp == 0)          continue;   /* +0x16 */
                if (u->player != player) continue;   /* +0x45 */
                if (u->mp == 0)          continue;   /* +0x15 */
                if (pass == 0 && weapon[u->weapon].rangeMax <= 1) continue;
                switch (u->order)  ...                /* +0x47, §3 */
            }
        } while (repeat);
        if (level == 5) more = FALSE; else level++;
    } while (more);
}

resetOverlay();                                       /* 0x0042EE90 */
for each own unit with mp != 0:  endUnitTurn(u);      /* 0x0040B380 */
setAIRunning(0);
return TRUE;
```

Three things fall out of this that a remake has to get right.

**`pass` orders ranged units before melee ones.** The gate is
`weaponInfo[u->weapon].rangeMax > 1` — [`21` §4](21-info-lcl-schema.md)'s
`+0x2F`, at `0x0051B2EF + 67 * weaponId`. Pass 0 admits only units whose weapon
reaches further than one field; pass 1 admits everyone. Shooters commit before
the things that have to walk into contact.

**`level` 0…5 is a *search radius*, not a difficulty.** It is handed to
`0x0040A750`, which uses it to choose how much movement allowance to pretend
the unit has when it floods the map (§5). At level 0 the AI only considers
what it can actually reach this turn; by level 5 it plans across the whole map.
The same unit is offered the switch six times per pass, with a wider horizon
each time, and stops acting as soon as one attempt spends its points.

**`repeat` re-runs the sweep whenever some unit ended with zero MP.** It is set
in the common epilogue (§3.3), so a sweep in which anything actually committed
is followed by another one; the sweep that changes nothing ends the level.

`0x004FAE3C` is dead: `0x00409948` is the **only** reference to it anywhere in
`Incubation.exe`, so the second argument is stored and never consulted.

The redraw callback is invoked **twice** in a row at each of the three sites
that use it (`0x0040996F`, `0x00409BDE`, `0x00409C90`): once through the
register holding the loaded pointer and once through the global again. This is
literal in the machine code, not an artefact of the listing.

---

## 3. The eleven orders — **[code] jump table `0x0040A37C`**

`0x00409A0B` is `cmp eax, 0xA` on `unit[+0x47]`; the table has eleven entries.
Values above 10 fall to the same address as case 8. `unit[+0x48]`, the order
parameter, is loaded into `edi` at `0x00409A01` before the dispatch.

| Order | [`10` §5.6](10-lev-mission-format.md) name | Handler | Shipped as primary |
|---|---|---|---|
| 0 | `Berserk` | `0x00409E1A` | 1000 |
| 1 | `Move (ActPt)` | `0x00409FFE` | 6 |
| 2 | `Attack (ActPt)` | `0x00409FFE` — **the same block** | 14 |
| 3 | `Move (Group)` | `0x0040A08D` | 0 |
| 4 | `Attack (Group)` | `0x0040A175` | 3 |
| 5 | `Turn (Wait)` | `0x00409F1C` | 57 |
| 6 | `Range (Wait)` | `0x00409F8D` | 51 |
| 7 | `Defend` | `0x0040A10B` | 103 |
| 8 | `Visibility (Wait)` | `0x00409BC8` — also the default | 427 |
| 9 | `Clever small units` | `0x00409A1B` | 130 |
| 10 | `Disturb` | `0x0040A28B` | 72 |

Orders 1 and 2 share one block outright. The editor's two labels differ, the
code does not.

### 3.1 Each order is itself a table on `level`

Six of the eleven handlers begin with `cmp ebp, 5` and a second jump table
indexed by the level counter. Reading the six tables gives the whole AI in one
grid — each cell names the `0x0040A750` call the level makes, as
`kind@level`, where *kind* is the second argument (§5) and *level* the fourth:

| Order | L0 | L1 | L2 | L3 | L4 | L5 | table |
|---|---|---|---|---|---|---|---|
| 0 `Berserk` | `2@L` | `2@L` | `2@L` | `3@3` | `2@4` | `1@5` | `0x0040A3A8` |
| 1 / 2 `(ActPt)` | `6@L` | `6@L` | `6@L` | `6@L` | `6@4` | `6@L` | `0x0040A3C0` |
| 3 `Move (Group)` | `7@L` | `7@L` | `7@L` | `7@L` | `7@4` | `7@5` | `0x0040A3D8` |
| 7 `Defend` | *fire only* | *fire only* | *fire only* | *fire only* | *fire only* | *defence mode* | `0x0040A3F0` |
| 4 `Attack (Group)` | `7@L` | `7@L` | `7@L` | `7@L` | `7@4` | `1@5` | `0x0040A408` |
| 10 `Disturb` | `2@L` | `2@L` | `2@L` | `2@3` | `2@4` | `2@5` | `0x0040A420` |

`@L` means the live level counter is passed through; a literal means the block
hard-codes it. Levels 0–2 (and often 0–3) share one block in every one of the
six tables — the escalation only bites at levels 3, 4 and 5.

Orders 5, 6, 8 and 9 do not use a level table; they branch on the level
directly (§3.2).

### 3.2 What each order does

Throughout, `fire(u)` is `0x0040A440(u, 8, 0)` (§4) called in a
`while (fire(u)) ;` loop — *shoot until you cannot* — and `plan(u, kind, param,
level)` is `0x0040A750` (§5).

**0 `Berserk`** — the aliens' default, and 1000 of the 1863 shipped units carry
it. Levels 0–2: `fire`, then `plan(u, 2, 0, level)` — close on the best enemy and
shoot. Level 3: `plan(u, 3, 0, 3)`. Level 4: `plan(u, 2, 0, 4)`. Level 5:
`plan(u, 1, 0, 5)`. Kinds 1 and 3 look for a **friendly alien** rather than an
enemy (§5.2), so the last two levels are "if you found nobody to kill, go and
join the pack".

**1 / 2 `Move (ActPt)` / `Attack (ActPt)`** — `plan(u, 6, param, level)`. Kind
6 selects the free cell whose **action point equals the order parameter**
(`cell[+0x0B] == u->+0x48`). Level 4 forces `plan(u, 6, param, 4)` after an
extra `fire` loop. Both orders end with `if (u->acted) endUnitTurn(u)`.

**3 `Move (Group)`** and **4 `Attack (Group)`** — `plan(u, 7, param, level)`.
Kind 7 selects a cell occupied by a unit whose **group id equals the parameter**
(`other->+0x4E == u->+0x48`). Order 4 first calls `0x0040B210(param)`, which
scans the 200 slots for a live unit in that group and, when there is none,
copies `+0x49`/`+0x4A` over `+0x47`/`+0x48` — the secondary-order promotion
[`10` §5.6](10-lev-mission-format.md) describes. Order 4 also fires with
`0x0040A440(u, 9, param)`, the group-restricted variant (§4).

**5 `Turn (Wait)`** — level 0: `fire`, then `plan(u, 2, param, 0)`. Level 1:
`0x0040A6E0(u)`, the countdown — if `u->+0x48` is 0 the secondary order is
promoted, otherwise the parameter is decremented and **MP is set to 0**. Levels
2–5: nothing. So the unit gets one chance to shoot from where it stands, then
sits out the turn.

**6 `Range (Wait)`** — level 0 is identical to order 5's. Level 1 is
`0x0040B250(u)`: scan all 200 slots for a live unit of a *different* player,
compute `aGetDistance` ([`22` §4](22-combat-and-visibility.md)) between it and
this unit, and if the distance is **≤ `u->+0x48`** call `0x0047A810(u->+0x4E)`
— which copies `+0x49`/`+0x4A` over `+0x47`/`+0x48` for **every** unit sharing
the group id. The order parameter is a trigger radius in fields, and tripping
it wakes the whole squad. Unlike order 5 this does not zero MP, so a woken
group acts on the next sweep.

**7 `Defend`** — levels 0–4 only `fire`. Level 5 calls `0x0040A710(u)`, the
end-of-turn defence-mode pass [`21` §4](21-info-lcl-schema.md) documents, and
then `if (u->+0x39 != 0) u->mp = 0`. A defender never moves.

**8 `Visibility (Wait)`** — the handler is the common epilogue (§3.3) and does
nothing for a unit that still has MP, which the outer gate guarantees. The
order is **inert inside the turn loop by construction**: 427 units stand still
until `aBuildVisibleMapForUnit` wakes their group on sight
([`22` §9.3](22-combat-and-visibility.md)). Orders above 10 land here too;
no shipped record holds one.

**9 `Clever small units`** — the only handler with its own logic before the
level dispatch, and the largest of the eleven.

1. **Threat refresh.** For every live unit of another player whose weapon is
   not one of the four arcing ids (`isArcing`, [`22` §5.5](22-combat-and-visibility.md)):
   temporarily add 10 to its MP, run `0x0042FF30` on it — the pass that stamps
   the hit-probability overlay (§6) — and subtract the 10 again. The result is
   a map of every cell some enemy could shoot. *Reading the +10 as "as if they
   had another turn" is interpretation; the arithmetic is literal.*
2. `melee = (weaponInfo[u->weapon].rangeMax == 1)`.
3. Levels outside 0…3 stop here.
4. If `melee` and MP ≥ 2: spend 2 MP, `plan(u, 2, 0, 0)`, refund them, `fire`,
   `endUnitTurn`.
5. **`if (cell(u->x, u->y).state` is in 30…34`)`** — *am I standing where an
   enemy can hit me?* If so and `u->hp < 3`: `plan(u, 10, 0, 2)` and `fire`.
   If `u->hp >= 3`: `fire`, `plan(u, 10, 0, 3)`, `fire`, then defence mode and
   `endUnitTurn`. Kind 10 is the cover score (§5.2).
6. Otherwise: `plan(u, 11, 0, 0)` — **walk to a closed door**: kind 11 looks
   for a cell whose action point is 31, which the game's own legend calls
   *standard Door — CLOSED* ([`10` §4.6](10-lev-mission-format.md)) — then
   `0x0040A600(u)`, which faces the door and plays `aDoorOpenSequence` for
   1 MP, `fire`,
   `0x0040A600(u)` again, and finally a coin flip,
   `aRandom(0, 20, aAISystem.cpp, 316) > 10`. Each side of the flip then
   branches on `melee` again; the four combinations are `plan(u, 10, 0, 2)`
   (cover), `plan(u, 2, 0, 3)` (close on an enemy), a bare defence-mode call,
   and `fire` followed by `plan(u, 10, 0, 2)`. The melee side is the one that
   spends 2 MP up front.

**10 `Disturb`** — `plan(u, 2, 0, level)` at every level, with the level
hard-coded to 3, 4 and 5 in the top three blocks. Functionally *Berserk*
without the friendly-alien fallbacks.

### 3.3 The common epilogue

Handler tails converge on `0x00409BC8` — which is also the order-8 arm and the
out-of-range default, so the three are one piece of code:

```c
if (u->mp == 0) { repeat = TRUE; if (g_redraw) { g_redraw(); g_redraw(); } }
```

Before reaching it most handlers pass through a two-line preamble. Four of the
six level switches default to the shared copy at `0x0040A364`:

```c
if (u->acted /* +0x39 */ != 0) endUnitTurn(u);   /* 0x0040B380: face, then mp = 0 */
```

Orders 7 and 4 have their own. Order 7's (`0x0040A164`) writes `u->mp = 0`
directly instead of calling `endUnitTurn`, so a defender never turns; order 4's
(`0x0040A274`) is the shared form but branches to the loop tail rather than the
epilogue when the unit did nothing. `ai_tables.py`'s `level.default` check
records all six.

`unit[+0x39]` is listed in [`10` §5.2](10-lev-mission-format.md) as runtime
residue with no known meaning. It is the **"this unit has acted"** flag: set to
3 by `0x0040A440` after a shot (`0x0040A577`) and by `0x0040A600` after an
interaction (`0x0040A6C2`), read at five sites in `aAISystemControl` and
nowhere else in the module, cleared by the per-turn stat recompute.

`endUnitTurn` (`0x0040B380`) calls `0x0047A8E0(x, y, 2)` for a facing, applies
it through `aChangeUnitViewDirection` unless the answer is `0xFF`, and then
sets `unit[+0x15] = 0` unconditionally.

### 3.6 The end-of-turn facing — **[code] `0x0047A8E0`**

```c
int aGetDirectionTo(int x, int y, int mode);   /* 0 or 1 or 2; anything else errors */
```

```c
cell = aGetCtrlMapElementPtr(x, y);   if (!cell) return 0xFF;   /* 0x0042F730 */
me   = aGetUnitMapElementPtr(cell->unit /* +0x07 */);
if (!me) return 0xFF;                                           /* 0x00477AE0 */

best = NULL;  bestState = 0;  bestDist = 0xFFFFFFFF;
for (c = ctrlMapBase(); i < ctrlMapCount(); c += 0x17, i++) {    /* 0x0042F650 / 0x0042F660 */
    match = 0;
    switch (mode & 0xFF) {
      case 0: match = (c->state /* +0x00 */ >= 30 && c->state <= 34); break;
      case 1:
      case 2:
        if (c->unit == 0xFFFF) break;
        other = aGetUnitMapElementPtr(c->unit);
        if (other->player /* +0x45 */ == me->player) break;
        if (netGate() && other->player <= 4 && me->player <= 4) break;
        if (mode == 1 && other->visibility /* +0x4F */ != 0) break;
        match = 1;
        break;
    }
    if (!match) continue;
    if (c->unit == 0xFFFF) return 0xFF;        /* only mode 0 can reach this */
    u = aGetUnitMapElementPtr(c->unit);
    if (unitInfo[u->type].species /* +0x79 */ not in {0, 1, 3}) continue;
    d = aGetDistance(c->x /* +0x09 */, c->y /* +0x0A */, x, y);
    if (c->state >= bestState && d < bestDist) {     /* the state byte, +0x00 */
        bestState = c->state;  bestDist = d;  best = c;
    }
}
if (!best) return 0xFF;
return aGetDirection(me->x /* +0x42 */, me->y /* +0x43 */, best->x, best->y);
```

Three things here are the kind a remake invents differently and no structural
check would notice:

* **Mode 2 has no visibility test and mode 1 does.** `endUnitTurn` uses mode 2,
  so a unit finishing its turn **turns towards an enemy it cannot see**. A fog
  test added "for consistency" would be wrong.
* **The choice is a ratchet, not a minimum.** A candidate needs a **state
  byte** `>=` the best so far **and** a distance strictly less than the best so
  far. Once a cell on band 33 has been taken, a nearer cell on 31 cannot
  replace it; and a later candidate at the same distance loses to the earlier
  one, because the distance test is strict. *(Corrected 2026-09-05: the
  pseudocode above had labelled the byte the mode-0 test and the ratchet read
  `actPt`, and both `inclib/combat.py` and `core/combat.gd` read the action
  point `+0x0B` there. The decompile tests `*cell`, the state byte `+0x00`,
  in both places -- which is what makes the ratchet mean anything: with the
  target overlay up, the shooter turns to its **best band**, nearer or not.
  Both twins now take the overlay as a parameter; the captures could not tell
  the two readings apart, every cell reading 1 and every action point on an
  enemy's cell 0. [`43` §4.4](43-battle-hud.md).)*
* **Species 2 does not attract a turn.** The table read is
  `byte[0x51C099 + type * 0x7E]`, which is `SetUnitInfo + 0x79` — the species
  column ([`21` §5](21-info-lcl-schema.md)) — and the accepted values 0, 1 and
  3 are human, alien and machine. Props are skipped.

Verified against the whole-turn capture: with the facing modelled,
`ai_gold.py --check` compares **every field of all 200 unit records** on both
`_C_140` saves, `+0x46` included, and the exemption that used to cover it is
gone. See [`95` §3](95-slice-3-report.md).

---

## 4. Firing — **[code] `0x0040A440`**

```c
BOOL fire(Unit *u, int mode /* 8 or 9 */, int group);
```

```c
if (u->hp == 0) return FALSE;
if (u->mp < weaponInfo[u->weapon].ap /* +0x3C */) return FALSE;
resetOverlay();                           /* 0x0042EE90 */
buildTargetOverlay(u);                    /* 0x0042FF30, see §6 */
pruneObjects(0);                          /* 0x0042FE90 */

best = NULL; bestScore = 0;
for each cell:
    s = cell->state;
    if (s < 30 || s > 34) continue;
    if (mode == 9) {                      /* group-restricted */
        Unit *t = GetUnitPtr(cell->unit);
        if (t->group != group) continue;
    } else if (mode != 8) continue;
    if (s >= bestScore) { best = cell; bestScore = s; }
if (!best || u->mp == 0) return FALSE;

if (g_mayFire /* 0x004FAE40, via 0x0040B370 */) {
    cap = heatCap(u);                                  /* 0x00475340 */
    if (cap != 255 && u->heat /* +0x3E */ >= cap && cap == 0) goto spend;
    aAttackUnit(u->x, u->y, best->x, best->y, 0);      /* 0x0046B450 */
    u->acted = 3;
}
spend:
u->mp = (u->mp > weapon.ap) ? u->mp - weapon.ap : 0;
u->actionState /* +0x41 */ = 4;
if (u->hp > 0) aExecuteFight(u);                       /* 0x0046CCA0 */
u->armourFront = 0x00475490(u);  u->armourRear = 0x004754F0(u);
return TRUE;
```

Two details worth lifting out.

`pruneObjects(0)` (`0x0042FE90`) walks the overlay and **clears every marker on
a cell whose occupant's species is 2** — [`21` §5](21-info-lcl-schema.md)'s
*inanimate object*. The AI does not spend ammunition on barrels and crates. Its
argument is a "keep everything" flag; the AI always passes 0.

The MP subtraction is clamped at zero but the *eligibility* test at the top is
`mp < ap`, so a unit is never left in a state where it owes points.

The heat gate is written as three calls to `0x00475340` and two comparisons,
and it collapses: a cap of 255 disables the mechanic, and any other non-zero
cap reaches the attack whether the unit is over it or not. **The only effect is
that a weapon whose heat cap is 0 is never fired by the AI at all.** Two
shipped weapons have one — 36 `ParaBomb` and 37 `Mine` — and 36 is precisely
the default weapon of unit type 31, the `Parabomb` that §9 detonates on a fuse
instead. Overheating proper is [`22` §8](22-combat-and-visibility.md).

---

## 5. Planning one action — **[code] `0x0040A750`**

```c
BOOL plan(Unit *u, int kind, int param, int level);
```

Three stages: build a reachability map at a horizon set by `level`, score every
cell by `kind`, then move to the winner.

### 5.1 The horizon — **[code] level table `0x0040AD70`**

The level selects one of six `aBuildMoveMap` calls, each of which temporarily
overwrites `unit[+0x15]` and restores it afterwards:

| Level | MP used for the flood fill | may pass friendly units |
|---|---|---|
| 0 | the unit's real MP | no |
| 1 | MP × 2 | no |
| 2 | **30** | **yes** |
| 3 | 50 | no |
| 4 | 100 | no |
| 5 | 250 | no |

Every call is `CHECK`ed, and a failure returns FALSE from `plan` — those six
sites are what `trace_names.py` recovers `aBuildMoveMap` from.

### 5.2 The score — **[code] kind table `0x0040AD88`**

`kind - 1` indexes twelve entries. Cells whose state byte is 0 are skipped
before the dispatch.

| Kind | Selects | Predicate |
|---|---|---|
| 1 | a **friendly alien** to regroup with | `0x0040B080(u, other, 0)`, then `(…, 2)`, then `(…, 255)` |
| 2 | the best **enemy** | `0x0040B000(u, other)` |
| 3 | a friendly alien, one fallback shorter | `0x0040B080(u, other, 0)` then `(…, 255)` |
| 4, 5, 8, 9 | — | no block; fall through to the next cell |
| 6 | a free cell with `cell[+0x0B] == param` | the action-point orders |
| 7 | a cell whose occupant has `group == param` | the group orders |
| 10 | the best **cover** cell | `0x0040B0D0` |
| 11 | a cell with `cell[+0x0B] == 31` | the interaction orders |
| 12 | an enemy not already flagged | `0x0040B040(u, other)` |

**8 and 9 are not missing — they belong to the other consumer.** `0x0040A440`
selects its behaviour with `mode - 8` / `dec` — i.e. a `switch` whose two arms
are the literals **8 and 9** — while the planner's `lea eax, [edx-1]` /
`cmp eax, 0xB` declares a range of **1 … 12**. The two functions are two arms of
one twelve-value selector: the planner implements 1, 2, 3, 6, 7, 10, 11 and 12,
the fire routine implements 8 and 9, and the planner's table reserves their
slots as fall-through. Every one of the 19 planner and 67 fire call sites is
inside `aAISystemControl` and passes a literal, so the whole space is
enumerable: **1, 2, 3, 6, 7, 10, 11** are selected by the order handlers, **8**
(59 sites) and **9** (8 sites) by the fire loops. *That the two switches were
one `enum` in the source is the natural reading of that structure, not a
separate fact.*

That leaves three values with nothing behind them, and they are of two kinds.
**Kind 12 is implemented and never selected** — its arm at `0x0040A99A` filters
enemies through `0x0040B040`, which differs from kind 2's filter only by also
requiring `other->actionState != 1`, i.e. an enemy with no reaction pending.
*"Approach an enemy that cannot shoot back yet"* is the obvious gloss and is
**UNVERIFIED**; nothing selects it. **Kinds 4 and 5 have no code at all** — no
arm in either consumer, no call site anywhere in `Incubation.exe`, and
`iDesigner.exe` contains no `aAISystem.cpp` code to compare against. This is
the same "implemented and unused" residue [`21` §5](21-info-lcl-schema.md)
records for seven of the seventeen `special` values, and it is closed the same
way: by enumeration, not by explanation.

The three unit predicates:

```c
/* 0x0040B000 */  enemy(u, o)  = o->player != u->player && unitInfo[o->type].species != 2;
/* 0x0040B040 */  enemy2(u, o) = enemy(u, o) && o->actionState /* +0x41 */ != 1;
/* 0x0040B080 */  ally(u, o, cap) = o->hp && o != u && o->mp <= cap
                                 && o->player == u->player
                                 && unitInfo[o->type].species == 1;   /* alien */
```

`0x0040B080`'s cap is why kinds 1 and 3 call it up to three times: first look
for an ally that has already spent everything (`cap == 0`), then one nearly
spent (2), then any (255).

**The cover score — `0x0040B0D0(cell, u, *best)`** — is the only place the AI
weighs terrain:

```c
far = 0;
for each of the 200 slots, alive and of a different player:
    d = (int)(sqrt((cell->x - o->x)^2 + (cell->y - o->y)^2) + 0.5);
    if (d > far) far = d;
score = (int)(far * 1.5 + 0.5);
for dir = 0..7:                       /* diagonals allowed */
    if (neighbour exists && neighbour->fieldType == 2 /* Wall */) score++;
```

then three alignment bonuses (+10 when neither coordinate matches, +5 when one
does) and `if (score > *best) { *best = score; return cell; }`.

The distance here is **Euclidean**, computed in x87 — every other distance in
the engine is `aGetDistance` ([`22` §4](22-combat-and-visibility.md)).

**The three bonus terms read past the end of the unit array, and the read
carries no information.** `esi` at `0x0040B1A7` is the loop pointer *after* the
200th slot, so the two bytes are `unitBase + 18266` and `+ 18267`. That is out
of bounds by construction: `aInitUnitMap` (`0x00477750`) asks
`aGetMemory` for `0x4718` = **18200** = 200 × `0x5B` bytes — the allocator is
`MSVCRT.dll malloc`, reached through `[0x005256C8]` — and then clears exactly
`0x11C6` dwords, the same 18200 bytes. The array is 200 slots and not one byte
more.

What the term computes is fully determined all the same. Writing the two bytes
`gx`, `gy`, the three tests partition every candidate cell:

| Condition | Added |
|---|---|
| `x != gx` and `y != gy` | +10 |
| exactly one coordinate matches | +5 |
| both match | 0 |

so the bonus is **+10 everywhere except one map row and one map column**. The
maximiser only compares candidates, so a term that is +10 on all of them
cancels: the *only* possible effect is a 5-point penalty on the cells whose `x`
is `gx` or whose `y` is `gy`, and 10 at their single intersection. No shipped
map is larger than **40 × 40**, so the term degenerates to a pure constant
whenever `gx` and `gy` are both ≥ 40, and even when one is not, 5 points sit
against a score whose range on a 40 × 40 map is 0 … 93 — enough to break a
near-tie, not to reverse a preference. It is reached only by order 9 at levels
2 and 3.

`gx` and `gy` are fixed for the life of an allocation and therefore identical
at every call within a mission, but they are 66 bytes into whatever `malloc`
placed after an 18200-byte block, and `aInitUnitMap` runs again for each
mission (`0x004199DC`, `0x00479152`). **They are a property of the C runtime's
heap history, not of Incubation**, and differ between missions and between
runs; there is no value here to recover. A remake that drops the three terms
entirely is exactly equivalent whenever the two bytes fall outside the map, and
otherwise differs only in near-ties along one arbitrary row and column.

**Measured, once inside a live process, and then bounded.** `ai_gold.py`'s
`cover` phase reads the same two bytes on `_C_140` and gets **168 and 3**. So
this run is the "one of them is not ≥ 40" case the paragraph above allows for:
the bonus is +10 on every candidate except the single map row `y == 3`, where
it is +5. `ai_runtime.py`'s `cover.deflection` then replays every sampled
unit's cover choice twice, once with the flat constant and once with row 3
penalised, and counts the choices that move: **12 of 417**. That is the whole
cost of omitting the three terms on the one heap layout ever observed, and it
is a bound rather than a defect to fix — the bytes differ between runs and
between missions, so no implementation can reproduce them. The deduction above
stands; what is new is its size.

**The approach cell — `0x0040ADC0(target, *best, myUnitIndex)`.** Once a target
cell is chosen the unit has to stand *next to* it. This scans the target's eight
neighbours — and, when `unitInfo[u->type].size == 1` (a large unit), the eight
neighbours of each of those, a second ring. A candidate must be empty, be in
the move overlay (state 10 or 60), differ in height by at most `2` after the
`/1600` divide (§7 — looser than the movement rule's `1`), and have more
remaining MP than the incumbent. A cell already holding the moving unit returns
immediately with a score of 10000.

### 5.3 Committing

```c
if (!best) return FALSE;
if (best->state == 60)                                   /* a warp target */
    steps = u->mp, blocked = 0;
else if (!aWalkMoveMap(u->x, u->y, best->x, best->y, &blocked, &steps))
    return FALSE;
if (steps == 0) return FALSE;
if (blocked == 0 && best->state == 60) aExecuteWarp(u->x, u->y, best->x, best->y, 1);
else                                   aExecuteMove(u->x, u->y, best->x, best->y, …, 255);
```

The `state == 60` test at `0x0040ABC7` is the one [`21` §8](21-info-lcl-schema.md)
already notes as "walk vs jump". `aExecuteMove` and `aExecuteWarp` are the same
two routines the human player's UI drives.

`blocked != 0` — some cell on the path is occupied by another unit — **zeroes
the step count and moves nothing**, so a path that runs through somebody is
abandoned rather than walked. Otherwise the same tail charges for what
happened:

```c
u->acted = 3;
if (u->hp > 0) aExecuteFight(u);            /* 0x0046CCA0 */
if (u->hp == 0) return TRUE;                /* it died on arrival */
if (cost == 0) return TRUE;
u->mp = (cost > u->mp) ? 0 : u->mp - cost;
```

`cost` is the unit's **whole remaining MP** on the warp branch — a jump always
ends the unit's movement — and, on the walk branch, whatever `aExecuteMove`
writes back through the pointer it is handed at `0x0040AC29`.

---

## 6. The target overlay — **[code] `0x0042FF30`, markers written by `0x0042F790`**

This is how the AI decides *what* to shoot, and it is a single number per cell.
For every enemy the acting unit could engage, `0x0042FF30` runs the full
`aGetHitProbability` chain ([`22` §5](22-combat-and-visibility.md)) and stamps
the target's cell with a **band of the resulting hit percentage**:

| Hit chance | Marker written into `cell[+0x00]` |
|---|---|
| ≤ 20 | 30 |
| 21 … 50 | 31 |
| 51 … 70 | 32 |
| 71 … 90 | 33 |
| > 90 | 34 |

**Measured, not read off the listing.** No shipped situation puts a resolvable
pair on both sides of any of the four boundaries — the corpus's 210 reachable
pairs come nearest at 20/28, 48/52, 70/72 and 90/92 — so the table above rested
on the disassembly until `ai_gold.py`'s `bands` phase walked a percentage
across all four inside a live `Incubation.exe`. The lever is the weapon's *hit
quote* (`SetWeaponInfo + 0x30`, [`21` §4](21-info-lcl-schema.md)), which moves
`aGetHitProbability`'s answer and nothing else the overlay reads. Twenty-two
probes, each asking the engine what the chance is and then reading back what it
stamped:

| percent | 1 | 18 | 19 | **20** | **21** | 22 | 48 | 49 | **50** | **51** | 52 | 68 | 69 | **70** | **71** | 72 | 88 | 89 | **90** | **91** | 92 | 99 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| marker | 30 | 30 | 30 | **30** | **31** | 31 | 31 | 31 | **31** | **32** | 32 | 32 | 32 | **32** | **33** | 33 | 33 | 33 | **33** | **34** | 34 | 34 |

Every boundary is inclusive of the value named and exclusive of the next point,
exactly as the table states.

Weapon `special` 6 — *attack the defender's position of the last turn* — swaps
in `+0x51`/`+0x52` before the stamp, exactly as [`21` §4](21-info-lcl-schema.md)
records for the combat path.

`0x0042F790(x, y, value)` is the writer: bounds-checked against the map width
at `0x004FEB78` and height at `0x004FEB74`, indexing `0x004FEB6C` with stride
23. It is the only routine that writes these five values.

Because §4 picks the numerically largest marker, **the AI always shoots at its
highest hit chance**, with no weighting for the target's health, threat or
value. And because order 9 re-runs the same pass from the *enemies'* side, the
same five values double as its danger map.

---

## 7. Reachability — **[code] `aBuildMoveMap` `0x00430A40`**

```c
BOOL aBuildMoveMap(Unit *u, BOOL passFriendlies, BOOL *anyFriendlyBlocked, int unused);
```

A breadth-first flood fill over the field grid, writing its result **into the
cells themselves**:

- `cell[+0x00] = 10` marks a cell as reachable — the overlay
  [`10` §4.5](10-lev-mission-format.md) already names;
- `cell[+0x0C]` holds the **movement points left on arrival**. [`22` §2.2](22-combat-and-visibility.md)
  documents the same byte as the damage a cell's unit just took; the two uses
  never overlap in time.

### 7.1 Refusals before the fill

```c
special = unitInfo[u->type].special;          /* +0x07 */
if (special == 1 || special == 14) return TRUE;    /* empty map; §5 of docs/21 */
*anyFriendlyBlocked = TRUE;
start = GetCellPtr(u->x, u->y);
start[+0x0C] = u->mp;  start[+0x00] = 10;      /* seeded first -- see below */
if (start[+0x10] == 3) { *anyFriendlyBlocked = FALSE; return TRUE; }
queue[0] = { u->x, u->y, u->mp };  n = 1;
if (u->mp <= 0) goto warp;
```

`cell[+0x10]` is `0xFF` in all **184162** shipped cells, because it is created
during play, not authored. It is the **kind of transient obstacle standing on
the field**, and its three values are named by the models their makers insert:

| `+0x10` | Placed by | Model | What it is |
|---|---|---|---|
| 1 | `0x0042F840` (`aCtrlMap.cpp:1483`, `:1495`) | `A_FIRE1/2/3.3DI` | **burning ground**, three intensities |
| 2 | `0x0042FA70` (`aCtrlMap.cpp:1627`) | `A_MINE.3DI` | **a mine** |
| 3 | `0x0042FB90` (`aCtrlMap.cpp:1735`) | `A_SHILD.3DI` | **a shield** — placed by the Plasma Gun's impact arm and turning 51 units a frame ([`42` §9.1](42-mission-presentation.md)) |
| 255 | — | — | nothing there |

Each of the three clears the byte to 255, inserts a symbol object through
`0x004069C0` with the matching kind tag, stores its slot in `+0x0F` and then
writes the value above. A fourth maker, `0x0042FCB0` (`aCtrlMap.cpp:1845`,
`GLOW1/2.3DI`), is the ground fire's *glow* phase and writes `+0x11`, `+0x12`
and `+0x13` instead — its **own** object slot, so a cell can carry a glow and
an obstacle at once *(corrected 2026-09-03: this line said `+0x0E`;
`0x0042FE15` writes `+0x11`, [`97` §37](97-slice-5-report.md))* — which is why `SetGroundFire`
([`20`](20-lcl-language.md)) reaches it and not `0x0042F840`.

The byte is persistent state rather than scratch: `aBuild3DSpecialObjects`
(`0x004079D0`, `a3DObjects.cpp:5062`) walks the whole grid after a load and
re-creates all four object kinds from `+0x10`, `+0x0E`, `+0x12` and `+0x13`.

So the refusal above reads: **a unit standing inside a shield cannot move at
all.**

**The seeding comes before the shield refusal, not after it — [runtime].** An
earlier version of this listing had the two the other way round. Calling
`aBuildMoveMap` inside a live `Incubation.exe` with `cell[+0x10] = 3` written
into the mover's own cell returns an otherwise empty map whose start cell holds
state 10 and the mover's movement points, so the seeding has already happened
when the refusal returns. The `special` refusal is genuinely first: it marks
nothing. See [`93` §3](93-slice-1-report.md) and
`tests/fixtures/movemap/README.md`.

### 7.2 The queue

Two ping-ponged arrays of **2003** four-byte entries `{u8 x, u8 y, u16 mpLeft}`
in a `0x3EE0`-byte stack frame, swapped once per wave. Writing entry **2000**
is a hard error (`0x00430DB8`). The outer loop runs at most `u->mp` waves.

### 7.3 Whether a step is allowed

The loop runs **`dir = 0 … 7`** (`0x00430DC8` is `cmp eax, 7`), not 0…3.
`0x004308C0` dispatches through a jump table at `0x00430A20` whose first four
arms are the orthogonal steps and whose last four begin by testing
`allowDiagonal` — and the only call site pushes a literal `0` (`0x00430BBD`).
Directions 4…7 therefore always fail, which is why the fill is 4-connected
about **cells**. They are not skippable, for a reason §7.6 gives.

```c
for (dir = 0; dir <= 7; dir++) {
ok = FALSE;
if (Step(dir, x, y, &nx, &ny, /*allowDiagonal=*/0)) {
    to = GetCellPtr(nx, ny);
    if (to && to[+0x0C] == 0) ok = TRUE;              /* on the map, not yet reached */
}
if (!ok || to->unit == NO_UNIT
        || GetUnitPtr(to->unit)->visibility /* +0x4F */ == 3) {
    *anyFriendlyBlocked = FALSE;                      /* 0x00430C64 */
} else {
    if (!passFriendlies) ok = FALSE;
    o = GetUnitPtr(to->unit);
    if (o->player == u->player) *anyFriendlyBlocked = TRUE;   /* 0x00430C58 */
    else                        ok = FALSE;    /* 0x00430C60 -- no write */
}
if (*anyFriendlyBlocked && to->unit == startUnitIndex) {
    *anyFriendlyBlocked = FALSE;  ok = TRUE;          /* the mover's own cell */
}
if (unitInfo[u->type].size == 1 && !0x0047A410(nx, ny, startUnitIndex)) ok = FALSE;
if (to[+0x10] == 1) ok = FALSE;                        /* fire */
if (u->player != 0xFF && to[+0x10] == 2) ok = FALSE;  /* a mine */
if (!ok) continue;
}
```

**Corrected against the engine.** An earlier reading of this block had the
enemy arm writing `*anyFriendlyBlocked = FALSE` and had the loop stopping at
four directions. Neither is what `0x00430A40` does, and §7.6 is what the
difference amounts to.

With §7.1's identification the two obstacle tests read plainly: **nobody walks
into fire, and a mine stops everyone except units owned by player 255** — the
test is on the owner, not on who laid the mine, and 255 is the aliens'
([`10` §5.7](10-lev-mission-format.md)).

**The AI does not cheat about what it cannot see.** `visibility == 3` is
[`22` §9.1](22-combat-and-visibility.md)'s *hidden* state, and a hidden unit is
treated exactly like an empty cell — the computer plans its movement through
enemies it has not spotted, and discovers them by walking into them. The third
argument is per-cell scratch, not a summary: the caller's variable holds
whatever the last neighbour examined left in it.

`0x0047A410(x, y, myIndex)` is the **large-unit clearance test**: all eight
neighbours of the candidate must exist, be empty or hold the mover itself, have
field type 0 or 1, be at exactly the same height, and have `+0x10 != 1`. A
`ComBot`, `Tr'Yn` or `Al'Coo` therefore needs a flat, clear 3 × 3 block for
every cell of its path.

**Native, and it did not need a large unit to be native.** `size` is 1 on only
those three types, none of which is on `_C_141`, and reaching a mission that
has one is hours of play. It is a byte in the shipped `SetUnitInfo` table
instead — `unitInfo[type] + 0x7B`, which `0x00430CA6` reads as
`byte [type*126 + 0x51C09B]` — so writing it in the live process turns an
ordinary mover large for the duration of one fill and changes nothing else the
fill reads. Six captured fills
(`tools/movemap_gold.py`): the test **refuses 232 cells** a small mover
reaches from the same squares and **passes 61**, so both arms are exercised
rather than only the refusal. Four of its five conditions decide on the
mission's own geometry — height on 159 candidates, occupancy on 83, the map
edge on 56, field type on 27. The fifth has no natural instance anywhere,
since `+0x10` is 255 in all 184162 shipped cells, so one fire is written
**diagonally** from a candidate: a diagonal neighbour is in the clearance ring
but is never the cell a 4-connected fill steps through. Four captured fills
make that a 2 × 2 — `{large, small}` × `{fire, no fire}` — and the fire
condition is the difference of the differences, not the gap between two movers:

| mover | no fire | fire | lost |
|---|---|---|---|
| large | 29 | 1 | **28** |
| small | 98 | 95 | 3 |

The three the small mover loses are the ordinary `to[+0x10] == 1` test and what
sits behind it. The other 25 are this one.

### 7.4 The cost

```c
cost = ctrlMapInfo[to->fieldType].delay;              /* 0x004FEB80 + 23*type, +0x01 */
if (to->fieldType == 8 && from->fieldType == 8)       /* ladder to ladder */
    cost += mpAllowance - 1;                          /* 0x00475160(u) */
else if (cost != 255) {
    if (abs(to->height - from->height) / 1600 > 1) cost = 255;
}
if (mpLeft <= cost || cost == 255) continue;
newMp = mpLeft - cost - 1;
to[+0x0C] = newMp;  to[+0x00] = 10;
queue[n++] = { nx, ny, newMp };
```

Three rules, all of them checkable:

**A step costs `delay + 1`.** [`21` §2](21-info-lcl-schema.md) already records
that `0x0046E220` subtracts `delay` "plus a per-step constant"; here the
constant is visibly `dec al`. With the shipped `Info.lcl`:

| Field type | `delay` | Cost per step | Shipped cells |
|---|---|---|---|
| 0 `Undefined` | 0 | 1 | 61840 |
| 1 `Free Place` | 0 | 1 | 48292 |
| 2 `Wall` | 255 | impassable | 26891 |
| 3 `Hole` | 255 | impassable | 2241 |
| 4 `Deep Hole` | 255 | impassable | 44653 |
| 5 `Debris` | 1 | 2 | 12 |
| 6 `Poison` | 0 | 1 | 191 |
| 7 `Enormous Obs` | 255 | impassable | **0** |
| 8 `Ladder` | 0 | the unit's whole allowance | **0** |
| 9 `Teleporter Entry` | 0 | 1 | 22 |
| 10 `Teleporter Exit` | 255 | impassable | 20 |

40 % of the shipped grid is impassable. Types 7 and 8 appear on no shipped
cell, so **the ladder rule never fires in the shipped campaign** — a ladder-to-
ladder step costs `delay + mpAllowance`, i.e. an entire turn's movement, and
skips the height test, which is exactly what a ladder is for.

**Measured, not deduced.** Writing field type 8 into a mover's own cell and one
neighbour of a live `_C_141` and then calling the engine's own fill
(`tools/movemap_gold.py`, six fills) gives:

| pair | Δh | allowance | mp | result |
|---|---|---|---|---|
| over a cliff | 5000 | 7 | 12 | reached, 5 points left |
| over a cliff | 5000 | 7 | 7 | reached, 0 points left |
| over a cliff | 5000 | 7 | 6 | **not reached** |
| flat | 0 | 3 | 12 | reached, 9 points left |
| flat | 0 | 3 | 3 | reached, 0 points left |
| flat | 0 | 3 | 2 | **not reached** |

So the step leaves `mp - mpAllowance` and needs `mp >= mpAllowance`, and the
5000-unit drop — three field-widths, which the climb rule blocks outright —
does not stop it. That closes the ladder as **native-runtime** evidence rather
than specification-only; `mpAllowance` itself is [`10` §5.5](10-lev-mission-format.md),
also called natively.

**Climbing is limited to one field-width per step.** The height test is the
magic multiply `0x51EB851F` with `sar edx, 9`, which is a signed divide by
**1600**; `> 1` therefore blocks a step whose height difference is **≥ 3200**
world units — one map field, the 2 m of [`22` §2.2](22-combat-and-visibility.md).
Over the corpus, 40609 of 357854 orthogonal neighbour pairs (11.3 %) fail it.

**Movement is 4-connected.** The diagonal flag is 0 at the only call site.
Path *reconstruction* is 8-connected (§8) — see the warning there.

### 7.5 Warping

The fill ends by calling `0x00430EE0`, which makes a second pass over the whole
grid and marks every cell the unit could warp to with `cell[+0x00] = 60` —
**except a cell the fill has already marked**, which keeps its 10.
[`10` §4.5](10-lev-mission-format.md) lists five acceptance tests; that is a
sixth, established by calling the routine in a live process (thirteen cells over
three captured warp runs). The test is on `cell[+0x00]` and not on
`cell[+0x0C]`: nine cells marked reachable with **zero** movement points left —
which the fill's own visited test cannot tell from unvisited — kept their 10 as
well.
[`10` §4.5](10-lev-mission-format.md) lays out its five acceptance tests and
the three warp ranges `0x00475380` returns — **5** with the `Jet Pack`
(equipment id 7, which `Info.lcl` annotates `* warp & scan`), **7** for a type
whose `special` is 15, and 0 otherwise — and this document adds nothing to it
beyond two observations.

Five of the 1863 placed units carry equipment 7, so the equipment path is live
in the shipped campaign rather than theoretical. And the action-point band the
test excludes, 80…89, is the one the game's own legend heads
***Victorypoints (only Multiplayer)*** ([`10` §4.6](10-lev-mission-format.md)):
**a unit cannot warp onto a victory point.** Those are the same cells
[`10` §4.2](10-lev-mission-format.md) identifies as the multiplayer start
fields, which is what the heading implies.
[`21` §3](21-info-lcl-schema.md)'s equipment table did not list id 7 among the
ids with a decoded effect; it does now.

**The player's jump** *(added 2026-09-03)*: the pad arm at `0x00472F10` calls
`aExecuteWarp(sx, sy, tx, ty, 1)` for a click on a cell the fill marked 60,
and for a mover still alive afterwards writes `+0x15 = 0`, `+0x39 = 5` and
drains the reaction queue at the landing cell (`0x00473046`…`0x0047304E`); a
mover the mine arm killed is deselected. The routine itself fires the
`MoveUnit` script call (`0x0046F196`, var 0x41 written 2) and rebuilds the fog
for the mover's own player, as it does for the computer. `combat.warp_unit`,
`ExecuteWarp` and `World.submit_warp` are the twins
([`97` §31.3](97-slice-5-report.md)).

### 7.6 `anyFriendlyBlocked` carries no information about friendlies

The third argument is not a summary and it is not even the last *interesting*
neighbour: it is whatever the last of **eight** directions left behind, and the
last four are always the refused diagonals, whose failure path writes it 0
(`0x00430C64`). So every cell the fill examines ends by clearing it, and:

> **the flag is FALSE after any fill that ran a single wave.**

It can only come back TRUE from the write at `0x00430A84`, before the loop —
which survives exactly when the loop never runs, i.e. when the unit has no
movement points left.

Measured, not deduced. Across 74 native fills on `_C_141`
(`tools/movemap_gold.py`), the flag is TRUE on 26 and FALSE on 48, and the
split is exactly `u->mp == 0`: thirteen of the mission's fourteen live slots
are spent, and slot 3 — the only one with `mp` 3 — is the only unmutated fill
that comes back FALSE. Every mutated fill, all of which give the mover
movement points, comes back FALSE too.

A caller reading it as "a friendly was in the way" is therefore reading
"the unit has no movement points", which it already knows. **A remake must not
give the flag a meaning.** It is reproduced bit for bit here because
reproducing it is cheaper than auditing the six `aBuildMoveMap` call sites in
`0x0040A750` for whether any of them reads the scratch back — which this
document does not claim to have done.

---

## 8. Reconstructing the path — **[code] `0x004305E0`**

```c
BOOL aWalkMoveMap(int sx, int sy, int tx, int ty, int *blocked, int *steps);
```

Gradient ascent from the target back to the source over `cell[+0x0C]`, since
the source holds the maximum:

```c
*blocked = *steps = 0;
budget = 300;
GetCellPtr(tx, ty)->state = 100;
x = tx; y = ty;
while (x != sx || y != sy) {
    if (budget <= 0) break;
    here = GetCellPtr(x, y);
    best = here[+0x0C] << 4;  bestDir = 0xFF;
    for (dir = 0; dir <= 7; dir++) {                     /* diagonals allowed */
        if (!Step(dir, x, y, &nx, &ny, 1)) continue;
        to = GetCellPtr(nx, ny);
        if (abs(to->height - here->height) / 1600 > 1) continue;
        if (dir >= 4 && !0x004303E0(dir, x, y, 0xFFFF)) continue;
        v = to[+0x0C] << 4;
        if (dir >= 4) v = (v > 1) ? v - 1 : 0;           /* diagonal tie-break */
        if (v < best) continue;
        best = v; bx = nx; by = ny; bestDir = dir;
    }
    if (bestDir == 0xFF) { CHECK("no direction found"); return FALSE; }
    (*steps)++;
    GetCellPtr(bx, by)->state = 100;
    if (cell(bx,by).unit != NO_UNIT && cell(bx,by).unit != cell(sx,sy).unit) (*blocked)++;
    budget--;  x = bx;  y = by;
}
if (budget == 0) return FALSE;
for each cell: if (cell->state != 100) { cell->state = 1; cell[+0x0C] = 0; }
return TRUE;
```

**The asymmetry is deliberate and a remake will get it wrong by accident.** The
flood fill is 4-connected and pays `delay + 1` per orthogonal step; the walk
back is 8-connected, checks corners, and breaks ties in favour of orthogonal
moves by docking one point from every diagonal. Diagonal moves therefore appear
in the final path even though no diagonal was ever costed.

`0x004303E0(dir, x, y, unitIndex)` is the corner check: for each of the four
diagonals it takes the two orthogonal components that bracket it — 4 → {−y, +x},
5 → {+y, −x}, 6 → {+y, +x}, 7 → {−y, −x} — and requires **both** to be
enterable via `0x00479C60`. No cutting corners past a wall.

`0x00479C60(x, y, unitIndex)` is more than the delay test
[`21` §2](21-info-lcl-schema.md) names it for. In full:

```c
if ((u8)x >= width || (u8)y >= height) return FALSE;
c = GetCellPtr(x, y);
if (c->unit != NO_UNIT && c->unit != unitIndex) return FALSE;  /* occupied */
if (Delay(c) == 255) return FALSE;                             /* impassable */
if (c[+0x10] == 1) return FALSE;                               /* fire */
return c[+0x10] != 2;                                          /* a mine */
```

`aWalkMoveMap` passes `0xFFFF`, which matches no slot, so for the corner check
the occupancy test means "must be empty".

**Three transcription details a paraphrase loses.** Acceptance is `v >= best`,
so **later directions win ties** and the evaluation order 0…7 is part of the
answer. The gradient is compared **16-bit** (`cmp ax, word [esp+0x14]`), which
is why the `movzx ax, byte [eax+0xc]` at `0x00430677` leaving the cell pointer
in the high half of `EAX` cannot reach the result. And the budget is tested
*before* each step: a walk that spends all 300 returns FALSE with the overlay
left mid-flight — the final sweep does not run.

**What the asymmetry costs, measured.** A walk to a target the fill never
marked does not stop at "no direction found": every unmarked cell holds zero,
`v >= best` accepts an equal zero, and the ascent wanders until the budget is
gone. That arm is captured natively (`steps` 300, return FALSE). For a target
the fill *did* mark, `tools/movemap_runtime.py --check` reconstructs 4587 paths
over the whole corpus: **2772 of the steps are diagonal**, and **not one path
leaves the highlighted region**. A remake therefore does not have to reconcile
the two connectivities — it has to refuse to offer an unreachable target, which
is what the highlight already expresses.

Cell state **100** is a fourth movement overlay value, alongside 10 and 60. It
survives the final sweep, so after `aWalkMoveMap` the grid holds the chosen
path and nothing else. Every move in the game leaves it behind — the two call
sites of `aWalkMoveMap` are also the only two of `aExecuteMove`, one the
computer's and one the player's — and **none of them shows it**:
[`43` §3.1](43-battle-hud.md) traces what draws the overlay and when.

`0x004308C0(dir, x, y, *ox, *oy, allowDiagonal)` is the shared stepper, and its
direction encoding is fixed by the table at `0x00430A20`:

| dir | Δx | Δy | | dir | Δx | Δy |
|---|---|---|---|---|---|---|
| 0 | 0 | +1 | | 4 | +1 | −1 |
| 1 | −1 | 0 | | 5 | −1 | +1 |
| 2 | 0 | −1 | | 6 | +1 | +1 |
| 3 | +1 | 0 | | 7 | −1 | −1 |

Directions 4…7 return FALSE when `allowDiagonal` is 0. Out-of-range results are
clamped *and* reported as failure, and an index above 7 raises
`"wrong direction"` at `aCtrlMap.cpp:3055`. This is **not** the facing encoding
of [`10` §5.10](10-lev-mission-format.md).

---

## 9. The pseudo-player — **[code] `aAI_SpecialPlayerControl` `0x0040B2D0`**

Runs once, before the main loop, and is three lines:

```c
for (i = 0; i < 200; i++) {
    Unit *u = &units[i];
    if (u->hp == 0)      continue;
    if (u->player != 252) continue;      /* 0xFC */
    if (u->type != 31)    continue;
    if (u->hp == 1) { aExecuteBomb(u->x, u->y); if (u->hp) aRemoveUnitElement(u->x, u->y); }
    else u->hp--;
}
```

Unit type 31 is **`Parabomb`**, and `Info.lcl` gives it `py = 252` and
`HP max = 1` — so a parabomb detonates at the start of the very next AI turn.
`0x004702C0` is `aExecuteBomb` (`aTacTools.cpp:6446`), the same routine
[`21` §5](21-info-lcl-schema.md) cites for `special` 12, *explodes when hit*.
The HP decrement is the fuse for any longer-lived member of the same family;
nothing shipped uses it.

**The fuse has no presentation of its own** (2026-09-05). `0x0040B2D0`'s
whole body is the sweep above: `aExecuteBomb`, `aRemoveUnitElement` and the
unit-array accessor, and no sound or camera routine at all. The fly-past and
the bomb run — `0x00415E90` then `0x004160F0`, [`28` §3](28-effects-and-sound.md)'s
`bomber.wav` and `crush.wav` — belong to the **script** command `ParaBombs`
`0x00470790` ([`20` §7.4](20-lcl-language.md)), which the computer never
runs. What a fuse running out looks and sounds like is one `aExecuteBomb`
blast, weapon 36's.

Player 252 is [`10` §5.7](10-lev-mission-format.md)'s neutral-prop owner. This
is the only routine that acts on it.

---

## 10. The cell state byte, complete

Collecting every band this document and the earlier ones establish for
`cell[+0x00]`:

| Value | Meaning | Written by |
|---|---|---|
| 0 | skipped by the plan scan | — |
| 1 | plain | `0x0042EE90` over the whole grid; the reset sweep in `aWalkMoveMap`; `aExecuteWarp` on a source cell |
| 2 | selected — the LCL area commands act on this | [`20`](20-lcl-language.md) |
| 10 | **reachable by walking** | `aBuildMoveMap` §7 |
| 30 … 34 | **AI target overlay — hit-probability band** | `0x0042FF30` §6 |
| 60 (`0x3C`) | **reachable by warping** | `0x00430EE0` §7.5 |
| 80 … 94 (`0x50`…`0x5E`) | attack scratchpad | [`22` §7.2](22-combat-and-visibility.md) |
| 100 (`0x64`) | **the chosen path** | `aWalkMoveMap` §8 |

Bands 30–34 and 100 are new here; [`10` §4.1](10-lev-mission-format.md) listed
only 1, 2, 10, `0x3C` and the attack band.

---

## 11. What a remake has to implement

```
aAISystemControl(player)
 ├─ aAI_SpecialPlayerControl                    parabomb fuses
 └─ for pass in 0..1:                           ranged units first, then everyone
     └─ for level in 0..5:                      widening search horizon
         └─ repeat until nothing commits:
             └─ for each of 200 units, alive, ours, with MP:
                 switch (unit.order)            11 handlers, §3
                  ├─ plan(unit, kind, param, level)             0x0040A750
                  │   ├─ aBuildMoveMap          4-connected flood, §7
                  │   ├─ score every cell by kind, §5.2
                  │   ├─ 0x0040ADC0             pick the approach cell
                  │   ├─ aWalkMoveMap           8-connected walk back, §8
                  │   └─ aExecuteMove / aExecuteWarp
                  ├─ fire(unit) while it returns TRUE           0x0040A440
                  │   ├─ 0x0042FF30             stamp markers 30..34 by hit %
                  │   ├─ 0x0042FE90             drop inanimate targets
                  │   └─ aAttackUnit            docs/22 §7
                  └─ epilogue: if acted, face and zero MP
```

The pieces that are not obvious from the outside, in order of how badly getting
them wrong will show: the two-pass ranged/melee ordering; the six-level horizon;
that target choice is *only* hit probability; that the flood fill is
4-connected but the path is 8-connected; that a step costs `delay + 1`; and
that a height difference of one field width is a wall.

---

## 12. Verification

`tools/ai_tables.py --check gog_incubation` — every count is `N/N`, and the
tool exits non-zero on an empty corpus.

| Check | What it proves |
|---|---|
| `order.table`, `order.in_text` | the eleven arms at `0x0040A37C`, all inside `.text` |
| `order.shared` | orders 1 and 2 really are one block |
| `order.default` | the `ja` above the table targets the order-8 arm |
| `level.order*` 6 | the six per-order level tables, contents as 3.1 |
| `level.default` | where each level switch's default arm lands, including the two odd ones |
| `plan.levels`, `plan.mp`, `plan.pass` | the horizon table and its six MP overrides and pass flags |
| `plan.kinds`, `plan.unused` | the twelve kinds, and that 4, 5, 8, 9 share one fall-through |
| `dir.table`, `dir.diagonal` | the eight stepper arms, and that exactly 4…7 are gated |
| `corner.table`, `corner.parts` | each diagonal's two orthogonal components |
| `queue.frame`, `queue.stride`, `queue.guard` | `0x3EE0`, 2003 and the 2000-entry error |
| `cost.read`, `cost.offset`, `cost.table`, `cost.ladder` | the `delay` column is read at `0x004FEB81`, matches `Info.lcl`, and the ladder case tests both cells |
| `climb.magic`, `climb.div`, `climb.threshold` | the multiply is `n / 1600`, and `> 1` first bites at 3200 |
| `hit.bands` | the thresholds 20/50/70/90 and the markers 30…34 |
| `warp.equip`, `warp.jetpack`, `warp.special`, `warp.mask` | equipment id 7, range 5, `special` 15, range 7 |
| `arcing` | the same {8, 13, 42, 46} `22` §5.5 fixes |
| `parabomb`, `parabomb.weapon` | `SetUnitInfo` 31 is `Parabomb`, `py` 252, HP 1, `special` 12, species 2, default weapon 36 |
| `heat.zero`, `heat.parabomb` | exactly weapons 36 and 37 have a heat cap of 0, so the AI never fires them |
| `global.write_only` | `0x004FAE3C` has one reference in the whole `.text` |
| `corpus.missions`, `corpus.units`, `corpus.cells` | 155, 1863, 184162 |
| `corpus.primary`, `corpus.secondary`, `corpus.orders_range` | both order histograms, and that no byte is outside 0…10 |
| `corpus.fields` | the field-type histogram, including 0 for types 7 and 8 |
| `corpus.pairs`, `corpus.blocked` | 40609 of 357854 orthogonal pairs are too steep |
| `corpus.actpt31`, `corpus.jetpack`, `corpus.effect_state` | 278 closed doors, 5 Jet Packs, `+0x10` uniformly `0xFF` |
| `legend.entries`, `legend.names`, `legend.control` | the 45 pushes of [`10` §4.6](10-lev-mission-format.md)'s legend, including the four names this document leans on |
| `legend.tested`, `legend.door_sites` | the ten action-point values the engine compares against, and that only the AI tests 31 |
| `door.sequence`, `door.name` | `0x0040A600` calls `0x00410A20`, which two independent sites call a door sequence |
| `obstacle.1/2/3`, `obstacle.glow` | each maker's models and the `+0x10` value it writes; the glow phase writes none |
| `unitmap.alloc`, `unitmap.exact`, `unitmap.cleared` | `0x4718` = 200 × `0x5B` asked for and `0x11C6` dwords cleared |
| `cover.oob` | the two offsets read one slot past the end are `+0x42` and `+0x43` |
| `ailevel.sites`, `ailevel.absent` | all eleven difficulty call sites, none inside the AI or the move map |
| `init.one_caller`, `init.no_ai_init` | `0x0040B4D0` has one caller, and `aMain` reaches the AI module only through the may-fire setter |
| `dead.*` 5 | the five globals with exactly one reference in `.text` |

Thirty-one mutations were applied to prove the checks can fail — one per family,
each caught by the check it targets: a jump-table entry, a level arm, an MP
override, a pass flag, a kind arm, a direction entry, a corner component, a hit
threshold, a hit marker, the queue guard, the magic constant, both warp
constants, an `isArcing` index byte, the ladder test, an `Info.lcl` `delay`,
an `Info.lcl` heat column, a second reference to a dead global, a legend name,
a legend entry, the engine's action-point-31 test, the door-sequence call, a
model name, an obstacle tag, the unit-array size, the cover score's read
offset, `aMain`'s call into the AI module, and four corpus edits (a mission
removed, a unit's order byte bumped, a map flattened, the action-point-31
fields cleared).

---

## 13. Open questions

**None.** The five this document opened are closed above, each in the place its
evidence belongs.

1. **`cell[+0x10]` 1, 2 and 3 are fire, a mine and a shield** — §7.1, named by
   the models `A_FIRE1/2/3.3DI`, `A_MINE.3DI` and `A_SHILD.3DI` that their
   three makers insert, with the ground fire's glow phase as a fourth. The move
   map's three tests then read literally: you cannot move out of a shield, you
   cannot walk into fire, and a mine stops everyone but player 255. `0xFF` in
   every shipped cell because the byte is created during play; it survives a
   save because `aBuild3DSpecialObjects` rebuilds all four objects from it.
2. **The cover score's out-of-bounds read carries no information** — §5.2.
   `aInitUnitMap` allocates exactly 200 × `0x5B` bytes, so the two bytes are 66
   past the end of an `MSVCRT malloc` block. The term they feed is +10 for
   every candidate except one map row and one map column, and a constant
   cancels in a maximiser; on a map of at most 40 × 40 it degenerates to a pure
   constant unless a byte falls below 40. The bytes are heap history, not game
   state — the array is reallocated per mission — so there is no value to
   recover, and a remake that omits the term differs at most in near-ties for
   one alien order.
3. **`aInitAISystem` does not exist** — §1. Attributing every function to the
   `__FILE__` its own `CHECK` sites report puts `0x0040B4D0` in
   `aAnimations.cpp`, not `aAISystem.cpp`; it touches none of the AI's globals;
   `aMain` calls into the AI module exactly once and that call is a one-line
   setter; and the animation init, which must exist, has exactly one caller —
   the site carrying the wrong name. The AI module has no state to initialise.
4. **Kinds 8 and 9 were never missing, and 4, 5 and 12 are residue** — §5.2.
   The planner and the fire routine are two consumers of one twelve-value
   selector: the planner's table reserves 8 and 9 as fall-through because the
   fire routine switches on exactly those literals. All 86 call sites pass
   literals and all lie inside `aAISystemControl`, so the space is enumerable —
   1, 2, 3, 6, 7, 10, 11 are used, 12 is implemented and never selected, and 4
   and 5 have no code in either shipped binary.
5. **The loop's vocabulary was never in the product** — §1.2. `pass` and
   `level` are a parameter and a local, and the only identifier-preserving
   mechanism in these binaries records callee names, files and lines. An
   ASCII + UTF-16 sweep of both binaries with a positive control confirms it.
   The near-miss is foreclosed too: `aiLevel()`, the difficulty setting, is
   never consulted by the AI module or the move map.

The session that closed them also recovered something larger than any of the
five: **the developers' own names for 38 action-point values**, carried in
`Incubation.exe` itself. That belongs to
[`10` §4.6](10-lev-mission-format.md), and this document cites it twice — for
action point 31, which is a closed door, and for the band 80–89, which is the
multiplayer victory points.

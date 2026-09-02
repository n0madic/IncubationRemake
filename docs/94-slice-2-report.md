# Second slice — a mission that can be played

The stage is complete: **`_C_140` is played and won**, headless and in an
exported build, by a squad walked into an evacuation zone across seventeen
turns while the mission's own script counts them, opens two tubes on turn 4 and
inserts alien reinforcements from turn 5.

Like [`93`](93-slice-1-report.md), this is a report on one piece of work and not
a living document. What it decides has been written into
[`92`](92-remake-architecture.md) and into the numbered specs; what stays here
is the evidence, the deviations and the measurements.

---

## 1. What exists now

```
godot/
  core/      39 files      pure GDScript: no Node, no FileAccess, no singleton
    lcl/      5 files      the mission-script interpreter
  game/      12 files      + localization, HUD, fog
  tests/     25 suites     1434 checks
tools/
  inclib/    interact.py new; combat.py, lcl_runtime.py, turn.py extended
  interact_runtime.py new
```

`core/` gained, in the order the stage built them: `execute_move`,
`turn_sequence`, `refresh`, `rotation`, `mission_script`, `game_control`, then
`line_of_sight`, `hit_chance`, `visibility`, `combat`, `reaction`, `interact`,
`crandom`, and `lcl/` — `lcl_program`, `lcl_env`, `lcl_context`,
`lcl_interpreter`, `lcl_outcome`. `World` gained eight commands: move, attack,
use, defend, stand down, spend a stimulant, end turn, and the move query the
first slice already had.

The last two are small and were nearly missed. Nothing in `World` could produce
`action_state == 7` or a spent stimulant, so [Refresh]'s two rewards for them --
`rested = 1` and turning 255 back into the charge -- were **tested and
unreachable from play**. No shipped `.lev` carries either state, so the only
route to those arms is a command.

**What is deliberately absent** is the AI planner. Player 255 receives its turn
and returns it; [`23` §2–§6](23-ai-system.md)'s eleven orders, two passes and six
levels are the next stage's, and [`92` §2](92-remake-architecture.md) named
profiling a complete computer turn as the first thing to do when one exists.

---

## 2. Oracle boundaries, per comparison

| What is compared | Boundary | Evidence |
|---|---|---|
| `aRefreshPlayer`, field by field over 200 slots | **native-runtime** | `turn_gold.py` phase 3, both players |
| The rotation, twelve steps | **native-runtime** | `0x0043B320` + `0x0043B490` inside the live engine |
| `aExecuteMove`, six walks of one path | **native-runtime** | phase 10; the probe's byte is written *between* the walk and the call |
| `aGetHitProbability` + `aCheckLineOfSightEx`, 86 ordered pairs | **native-runtime** | phase 2 |
| `aBuildVisibleMap`, both players' `+0x4F` | **native-runtime** | rides inside the refresh phase |
| `aCheckWeaponDamage`, the gate and its arms | **native-runtime** | phase 7, seed read either side |
| `aAttackUnit`, six shots | **native-runtime** | phase 8, seed and hit points either side |
| `aExecuteUse`, 3 classes × 8 facings | **native-runtime** | phase 9, **gated** since this stage |
| One `NEXT PLAYER` of the real interpreter | **native-runtime** | phase 6: two `aRandom` draws, 1.0 → 847344462.0 |
| The interpreter over 4 missions × 30 cases | executable-Python | `lcl_runtime.py --emit-cases`; corpus-wide `N/N` stays in Python |
| The hand-over, twelve steps of a transcript | executable-Python | `turn_runtime.py --emit-handover-cases`; **no native oracle exists** |
| Reaction fire, the whole queue | specification-only | no shipped `.lev` places a unit on overwatch |
| The interaction arms no probed cell carried | specification-only | built scenes |
| Localization, fog rendering, the HUD | specification-only | properties of this design |
| **`_C_140` played and won** | specification-only | the script's own `SetGameControl (0,1)` |

**Two comparisons have no native oracle at all, and both say so where they
live.** The hand-over `0x0047D600` ends by invoking `aAISystemControl` — the
computer's whole turn — which is not something to start inside a debugger probe;
the strongest check available is two implementations agreeing on identical
documents, and that is worth something only because one was written from the
other. The reaction queue is runtime state: `+0x41` is 0 in all 1826 placed
records across the 155 missions, because a unit only goes on overwatch by being
put there.

---

## 3. What a second implementation caught

The three-sided diff earned its cost five times in this stage. Each of these was
wrong in a way that reads correctly.

**Five LCL predicates took the wrong arguments.** `UnitOnField`, `MechOnField`,
`NoUnitOnField` and `GroupOnField` take **cell coordinates** and ask what is
standing there; the transcription had them scanning the whole map for a match.
`CheckCurrentTurn` is a range on the *turn number* — its arguments are
`(low, high)` — and the transcription tested the current player, which is what
the name suggests. The replay found all five on its first run. No
specification-side check would have: the specification is what was misread.

**`Rotation.slot_qualifies` had no `0x0043B1F0` gate**, so a campaign player who
lost their last unit would have stopped receiving turns. The existing test
asserted the *wrong* rule and was green, because the native rotation capture is
a campaign save where player 0 is alive throughout.

**The two Python rosters disagree from turn 5.** `units_of(bm)` and `LclWorld`
build different record sets out of one `.lev` — `active_units` is "has a name"
and the interpreter's roster is "has hit points" — and `InsertUnit` writes into
the engine's single array. Measured on `_C_140`: nine hand-overs agree and the
tenth does not, when turn 5 inserts the first reinforcement. The hand-over
emitter now **refuses** rather than writing a trace that compares a turn model
against a roster the mission has already changed.

That same difference settled the spawn slot. "One past the highest key" gives 10
on one roster and 12 on the other, which are two different missions after the
first reinforcement; both implementations now take the lowest slot in 0..199
holding no live unit, and both record that the rule is UNVERIFIED.

**`docs/26` §6.1's ParaBomb claim was wrong.** A mine stepped on during a walk
stops the walk and zeroes the movement points — measured — and fires
**nothing**: the generator's seed is bit-identical either side, the mover's hit
points are unchanged, and the mine is still on the cell afterwards. The doc is
corrected in place and the reason is now an open question rather than a
description.

---

## 4. Measurements

Apple M4 Max, Godot 4.7.1. The first four rows are `_C_115` (990 cells) and
carry over from [`93` §5](93-slice-1-report.md); the rest are `_C_140`
(400 cells, 10 units) **with its program attached**, because a hand-over runs
the script twice and the cost of the script is part of the cost of a turn.

| Measurement | Value |
|---|---|
| One complete move map, 990 cells | 139 µs |
| Canonical state hash | 37 µs |
| Save / load, 15.8 KiB | 178 µs / 182 µs |
| Cache verification, full SHA-256 | 10.7 ms |
| **One hand-over** — rotation, refresh, two script runs, fog | **916 µs** |
| The fog pass alone, 10 units | 308 µs |
| One `NEXT PLAYER` of `_C_140`'s program | 64 µs |
| One hit probability, including line of sight | 8.2 µs |
| One resolved shot | 14 µs |
| A complete AI turn | **still does not exist** |

**What these decide.** A hand-over is a millisecond, and two thirds of it is the
fog pass — which is `O(observers × units)` line-of-sight walks and is the only
thing here that grows with the roster. [`23` §2](23-ai-system.md)'s worst case is
two passes over six levels for up to 200 slots; at 139 µs a fill and 8 µs a hit
probability, even a pessimistic few thousand fills and a few hundred thousand
pair evaluations is a second or two of GDScript on a map near the corpus
maximum. **No memoisation, no GDExtension and no native flood fill are
justified yet** — the same conclusion [`93` §5](93-slice-1-report.md) reached,
now with the combat and script layers measured rather than assumed.

The number still missing is the one [`92` §2](92-remake-architecture.md) asked
for first, and it is missing for the same reason it was: there is no AI turn to
profile. Everything it will be built out of is now measured.

---

## 5. Deliberate deviations from the plan

Each of these is a decision, not an omission, and each is recorded where the
code is.

**There is no cell fog, because the game has none.** The plan for this stage
asked for "cells outside vision darkened over the terrain overlay".
`aBuildVisibleMap` writes one byte per *unit* (`+0x4F`) and nothing per cell; a
save carries that byte and no fog map, and the pass recomputes from scratch on
every hand-over. Drawing a cell fog would be a remake decision dressed as
fidelity. What is drawn is the three unit states — full, a contact blip, nothing
— and the blip matters: [`22` §9.3](22-combat-and-visibility.md)'s second pass
shows one per cluster rather than one per alien, which drawing hidden units
faintly would give away.

**Set pieces apply instantly and are not animated.** `Platform`, `Elevator`,
`Barrier`, `FootBridge`, `OpenTube` and their relatives change the cells they
document and record the animation as an event. The event carries its arguments,
so a later stage can play it rather than rediscover that it happened.

**The interaction model is `aExecuteUse` and its gate, not the whole of
[`26`](26-interaction.md).** Teleporters on a *walked path* are modelled
(`ExecuteMove`); the standalone teleporter routine `0x00470150` is not, and
neither is the unit command pad's layout — [`29` §1.1](29-interface-contract.md)
is the next stage's.

**Eight of the sixteen target patterns are not simulated**, and a shot that
reaches one **refuses** rather than marking nothing: the radius that widens with
the shot, the line-of-sight sweep, the whole-map sweep, the 18-cell scatter, the
re-centred explosion and the filtered spores. A model that marked nothing for
them would look like a clean miss. The eight that are simulated are the ones
`_C_140`, `_C_141` and `_C_115` fire.

~~**`aExecuteBomb` is modelled from the documentation and marked
UNVERIFIED.**~~ **— Resolved later, in the model's favour**
([`26` §6.2](26-interaction.md), 2026-09-02). The push's arm carries the
*identical* `aDeleteSpecialObject` guard the walk's does, so it is no weaker;
what the walk probe hit was that guard, because its synthetic mine had the
effect byte and no object. The correction that *does* follow is on the other
side: the walk arm's "nothing fires" is an artefact of the probe, not the
engine's rule, and `core/execute_move.gd` carries a `TODO:` for it.

---

## 6. What the exported build demonstrates

The acceptance list of the stage's plan, all of it inside the exported `.app`:

1. the installation is untouched — `tools/verify_untouched.sh`, before and after;
2. two conversions give byte-identical inventories, `script.json` included;
3. a partial cache is refused, and a cache of the previous converter version is
   refused **by name** (`0.4.0` against `0.5.0`);
4. the refresh, the rotation and the hand-over agree with the native capture on
   `_C_141`, field by field over every live slot;
5. `aExecuteMove` agrees on the final position, the reported cost and the
   distance walked, and the charge stays in the caller;
6. `aBuildVisibleMap` agrees on `+0x4F` for both players;
7. hit probability agrees over 86 ordered pairs, and a shot with a fixed seed
   agrees on damage and on the generator's state afterwards;
8. every entry point of four missions runs, and the game-control slots after a
   native `NEXT PLAYER` agree with the engine's;
9. **`_C_140` is played and won** — the squad in the zone, `SetGameControl (0,1)`
   from the mission's own body, the result on screen;
10. a save taken mid-mission, **with the script's own reinforcements in the
    roster**, round-trips the canonical hash;
11. `core` still has no scene, no filesystem and no singleton, and `game` cannot
    mutate its arrays;
12. typed warnings still fail the build.

---

## 7. How the checks were made to mean something

Ninety-odd mutations were run against the suites across the stage, in batteries
after each layer. The count that matters is not how many were caught but what
the escapes were, because every one named a real gap:

* a reaction check that passed on an implementation which restored **nothing**,
  because the scenario pointed both reactors straight at the mover and
  `aAttackUnit`'s turn-to-face was therefore a no-op;
* a "a body does not hide" check that passed on an implementation which rejects
  `254`, because the body in the way was a *friendly soldier* who could see the
  alien himself — and then, once he was replaced by a crate, because the crate
  was 1600 world units tall against a ray at 3200;
* the `Def` gate, the fog pass and the reaction drain, each wired into `World`
  and unchecked: deleting any of the three left every suite green;
* the fatigue draws, the large-unit distance discount and the diagonal `dz`,
  which no case reached at all;
* four holes in the hand-over transcript — no shipped script refuses, an
  authored `.lev` has every refreshed field at zero already, one seed reaches
  one arm of each branch, and state forced between steps must be recorded or the
  replay asks a different question.

Two mutations are **equivalent** and are documented as such rather than chased:
returning terrain the moment it is met (nothing can raise the code above
terrain), and `SetActPt`'s `& 0xFF` (`MapState` keeps action points in a
`PackedByteArray`, which wraps on assignment). Both stay in the source, because
each states a rule of the *engine* that Godot's containers happen to agree with.

---

## 8. What a review pass found afterwards

Thirteen findings, all of them real and all fixed in place. Three are worth
recording because of *what kind* of mistake they were.

**A 560 KB fixture of extracted retail data was tracked in git.** The commit
that created `tests/fixtures/lcl/cases_lcl.json` added it and the `.gitignore`
line in the same `git add -A`, and gitignore has no effect on an already-tracked
path — so the file's own committed README said "it is gitignored" while it was
not. Untracked now; the blob remains in the local history at `0bcf348`, and
nothing has been pushed anywhere. This is the project's oldest rule and it was
broken by the mechanics of one command.

**Two checks were structurally dead.** `interact_runtime`'s
`census.no_accepted_id_is_unhandled` guarded on `ap not in range(10, 50)` after
a call that returns a value only *inside* that range, so nothing was ever
appended; `movemap_runtime`'s mine tally sat after an early return that the mine
arm is the only thing to trigger. Both are the shape this repository's own rules
name — "a check that examined nothing is not a check that passed" — and both
were written by the person who wrote that rule. The first found a real gap the
moment it started examining anything: action point **10**, the random supply
box, is dispatched by `aExecuteUse` (it rolls into 11, 12 or 13 *before* the
switch) and was in neither the handled set nor the script-only set.

**Four cross-implementation divergences** that no test could see, because each
sat in a place the two sides were never compared: `stunned` read after the
charge was spent (Python wrong, GDScript right); `GetUnits` with the player
operand omitted counting everybody (GDScript wrong); a spawn of an undefined
type named `"type 99"` on one side and `""` on the other; and the event
documents having different *shapes*, so the replay compared event names and
never event arguments. The last one is the instructive one: the class doc
asserted "the same shape … so a disagreement is a document diff", and the
assertion was false, which is why 120 cases' worth of event arguments went
unchecked. They agree now.

The rest were smaller: a loop variable that shadowed the mission name and put
`"turn_start_y"` in a fixture's provenance field; a `hand_over` argument
recorded in a trace but not passed to the oracle that produced it; a Win32
failure classified as a plan refusal, which turned an intermittent Wine launch
into a hard stop the ten retries exist to absorb; an unguarded weapon-table
index; an environment slot dropped silently where the Python twin raises; and a
movement point charged for a `Use` the engine's own pad would never have
offered.

---

## 9. Open questions this stage leaves

1. **The AI planner.** Not started, deliberately. Player 255 takes its turn and
   returns it, so `_C_140`'s reinforcements stand where they spawn. This is the
   next stage and [`23`](23-ai-system.md) specifies it.
2. **The campaign layer.** `EnterNameOfNextMap` writes a name that nothing reads;
   the roster, the deployment screen, the economy and the score are
   [`27`](27-campaign.md)'s and are untouched, which is why
   `_C_115` — whose squad arrives from the campaign — cannot be played.
3. **What seeds the C runtime's generator.** No `srand` has been traced, so both
   implementations start from the standard's 1 and say so. `InsertUnit`'s counts
   depend on it, and `_C_140` draws it from turn 5.
4. ~~**`aExecuteBomb` on the push path**~~ — [`26` §10](26-interaction.md)
   item 7, **closed**: the same guard, read rather than probed. See §5.
5. **The eight unsimulated target patterns**, listed in §5.
6. **The 200-slot spawn rule** is the natural reading of a fixed array and is
   not measured; a capture that inserts a unit and reads back which slot it took
   would close it.
7. **Bodies, animation and sound.** [`40`](40-charisma-model-animation.md),
   [`41`](41-sequence-player.md) and [`28`](28-effects-and-sound.md) are all
   untouched: a unit is still a capsule and a ground marker.

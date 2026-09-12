# Third slice — an opponent that plays

The stage is complete: **the aliens move, close and shoot.** `_C_140` is played
against a live planner in an exported build, the computer's turn is replayed on
screen one action at a time, and defeat — unreachable in every previous slice —
is now an ordinary outcome with a debriefing screen behind it.

It also closes the one measurement [`92` §2](92-remake-architecture.md) has been
asking for since the first day. **A complete computer turn costs 12 ms on
`_C_140` and 264 ms on `_C_132`**, the corpus worst case, and the answer to the
question that number was asked for is unchanged for the third time: no
memoisation, no native flood fill, no GDExtension.

Like [`93`](93-slice-1-report.md) and [`94`](94-slice-2-report.md), this is a
report on one piece of work and not a living document. What it decides has been
written into [`92`](92-remake-architecture.md) and into the numbered specs; what
stays here is the evidence, the deviations and the measurements.

---

## 1. What exists now

```
godot/
  core/      42 files      pure GDScript: no Node, no FileAccess, no singleton
    ai/      12 files      docs/23's planner
    lcl/      5 files      the mission-script interpreter
  game/      13 files      + the AI playback
  tests/     26 suites     1554 checks
tools/
  inclib/    ai.py new (1813 lines); combat.py, movemap.py extended
  ai_runtime.py new        71 checks over 108 missions and 1594 aliens
  ai_gold.py new           twelve native phases, 45 checks
```

`core/ai/` is [`23`](23-ai-system.md) §2–§9 in the order the stage built it:
the target overlay and its prune, the three predicates and the cover score, the
approach cell, the plan, the fire, the eleven order handlers, the sweep itself
and the pseudo-player. `World.submit_end_turn` runs it when the incoming player
is 255 and returns an `AITurnResult` — an ordered list of events, the sweep
count, the generator's state either side, and the refusals the model made
rather than the engine.

**The converter did not change.** `CONVERTER_VERSION` is `0.5.0` on both sides
of this stage, `SaveCodec.SCHEMA_VERSION` is unchanged, and a save taken by the
second slice still loads. The one qualification, stated plainly because the
plan's acceptance item said "no republication": `_C_132` was **added to
`SLICE_MISSIONS`**, so the cache was republished as *content*. The schema did
not move; the inventory did.

---

## 2. Oracle boundaries, per comparison

| What is compared | Boundary | Evidence |
|---|---|---|
| **`aAISystemControl` — the whole computer turn** | **native-runtime** | `ai_gold.py` phases `turn_0` / `turn_2`, on **`_C_140` itself**, turns 1 and 10: all 200 unit records field by field and `aRandom`'s seed either side |
| The three predicates `0x0040B000` / `40` / `80` | **native-runtime** | 90 ordered pairs of live slots |
| The cover score `0x0040B0D0` | **native-runtime** | 60 cells, including the two bytes it reads past the unit array |
| The target overlay `0x0042FF30` + prune `0x0042FE90` | **native-runtime** | call, then read the cell grid back |
| **The five hit-chance bands** | **native-runtime** | 22 probes: the weapon's hit quote written, `aGetHitProbability` asked, the stamped marker read back — one point either side of all four boundaries |
| The approach cell `0x0040ADC0` | **native-runtime** | 10 targets, small and large mover; the `size` byte written as in [`93` §11](93-slice-1-report.md) |
| Fire `0x0040A440`, six shots | **native-runtime** | destructive; reload between probes, seed pinned |
| Plan `0x0040A750`, twelve probes | **native-runtime** | one per reachable kind × level |
| `endUnitTurn` and the four order helpers | **native-runtime** | record dumps before and after |
| The pseudo-player `0x0040B2D0` | **native-runtime** | on `_C_141`, with `type = 31` written |
| Eleven order arms, horizon, bands, spores, approach | executable-Python | `ai_runtime.py --check`, `N/N` over the corpus |
| `core/ai/` against `inclib/ai.py` | executable-Python | `tests/test_ai.gd`, a three-way diff on two missions |
| The AI playback, the debriefing screen | specification-only | properties of this design |

**The bottom row of [`94` §2](94-slice-2-report.md) is gone.** That table said
the hand-over "ends by invoking `aAISystemControl` — the computer's whole turn —
which is not something to start inside a debugger probe". It is, and it was.
The capture reloads a save, runs `aRefreshPlayer(255)` the way the hand-over
does, calls `aAISystemControl(NULL)` and reads back every unit record and the
generator. Both saves are on the demonstration mission itself, so the strongest
evidence in this project's history is also evidence about the thing being shown.

---

## 3. What the native oracle caught

Four engine behaviours that no amount of structural self-consistency would have
produced, and one loading bug that only a second implementation could see.

**`aExecuteMove` is bounded by the mover's real movement points.** The model
walked the whole path; the engine takes as many steps as the unit can pay for.
The plan probes hand the routine a path the level-2 horizon flooded with 30
points — and the unit took **one step**. This was the entirety of the whole-turn
diff: with the walk unbounded, every alien on `_C_140` ended the turn somewhere
else. `movemap.execute` and `core/execute_move.gd` both take a `budget` now, and
the player's own move passes `-1` to keep the unbounded behaviour it needs.

**The player's shot was free.** Not an AI bug, but the AI found it: with the
aliens firing back it became obvious that the squad never ran out of action
points. `aUI.cpp:3516` (`0x004731E4`) subtracts the weapon's AP, writes 3 into
`+0x39` and *then* calls `aExecuteFight`; the second slice had none of the
first two. Fixed in `World.submit_attack`.

**The six-level horizon is not monotone.** [`23` §5.1](23-ai-system.md)'s table
reads as a widening search, and it is — except at level 2, which floods with 30
points **and** passes through friendly units, and level 3, which takes the
permission back. The growing chain is 0, 1, 3, 4, 5, with 1 ⊆ 2 beside it, and
`ai_runtime.py` asserts exactly that shape rather than a single chain. A
related correction: a hidden unit's cell is enterable at **every** level, not
only at 2, because the fill cannot see it at all.

**`UnitTypeTable.from_rows` dropped two columns.** The loading boundary narrows
each cache row to a fixed list — this is where the JSON floats become typed
values once — and `armour_front` / `armour_rear` were not on it. Every type
answered the fallback 0 while `tables/balance.json` carried the real values, so
the remake's aliens did damage the engine's would not. `test_ai.gd` found it on
its first run, comparing unit records after a turn; `test_cache.gd` now asserts
that every column any accessor reads survives the narrowing.

**The five hit-chance bands were never bound by data, and now are.** No
shipped situation puts a resolvable pair one point either side of any of
[`23` §6](23-ai-system.md)'s four boundaries — the corpus's 210 pairs come
nearest at 20/28, 48/52, 70/72 and 90/92 — so the table had been resting on the
disassembly. The `bands` phase walks a percentage across all four inside a live
`Incubation.exe`: it writes the weapon's *hit quote* (`SetWeaponInfo + 0x30`),
which moves `aGetHitProbability`'s answer and nothing else the overlay reads,
then asks the engine what the chance is and reads back the marker
`aBuildTargetOverlay` stamped on the target's cell. Twenty-two probes, and the
boundaries fall out of the data: 20 → 30 and 21 → 31, 50 → 31 and 51 → 32,
70 → 32 and 71 → 33, 90 → 33 and 91 → 34. The column is put back afterwards —
the weapon table is loaded once at start-up and not per save, so a phase that
left it written would poison every phase after it in the same session.

**`--code` cannot be used on this host.** `dbgcall`'s injected executable page
makes `Incubation.exe` fault before the anchor, ten attempts out of ten
(`0xc0000005`). The byte writer for `ai_gold.py` is therefore the game's own
imported `memcpy`, reached through its IAT slot at `0x00525634` with the byte in
a plain `--blob`. Recorded in `CLAUDE.md` so the next capture does not
rediscover it.

---

## 4. Measurements

Apple M4 Max, Godot 4.7.1. The AI rows are new; the rest carry over from
[`94` §4](94-slice-2-report.md) and are re-taken here because the turn now
contains the planner.

| Measurement | `_C_140` (400 cells, 4 live aliens) | `_C_132` (1600 cells, 39 live aliens) |
|---|---|---|
| **A complete computer turn** | **12.2 ms** | **264 ms** |
| Order dispatches in it | 16 | 270 |
| Flood fills / target overlays / hit probabilities | 16 / 28 / 168 | 123 / 241 / 1698 |
| One `plan` (`0x0040A750`), fill included | 237 µs | 575 µs |
| One `fire` (`0x0040A440`), overlay included | 123 µs | 341 µs |
| One flood fill written into the overlay | 65 µs | 150 µs |
| One target overlay | 72 µs | 182 µs |

Carried over, on `_C_140`: one move map 149 µs, the fog pass 326 µs, one hit
probability 8.7 µs, one resolved shot 20 µs, one `NEXT PLAYER` 72 µs. **One
hand-over is now 33 ms** rather than the 916 µs [`94`](94-slice-2-report.md)
measured, and the whole of the difference is the computer's turn inside it. The
comparison is loose in the bench's favour: it averages twenty hand-overs of
which ten came back `OK`, the rest being cheap returns once the mission had
ended, so the true cost of one hand-over that runs a turn is higher again.

**What these decide.** A quarter of a second, once per round, on the heaviest
map the corpus contains — while the player is watching a replay that takes
several seconds anyway. Multiplying the counts by the single-call costs accounts
for roughly three fifths of the turn (`124 × 575 µs + 243 × 341 µs ≈ 154 ms` of
264 ms); the single-call figures are one named unit's, not the mean, so the
remainder is the same work on units in busier positions plus the 2800 slot
visits of fourteen sweeps. Nothing here is dominated by the flood fill: 123
fills are 28 ms, 11 % of the turn. **No memoisation, no native fill, no
GDExtension** — the same conclusion [`93` §5](93-slice-1-report.md) and
[`94` §4](94-slice-2-report.md) reached, now with the thing they were guessing
about actually running.

---

## 5. Deliberate deviations from the plan

**The plan's corpus numbers were wrong and are corrected here.** It said 107
missions and 1790 aliens; the truth is **108 missions with a live alien and 1594
aliens on them**. The plan's figures came from overlapping populations — the
1790 counts every alien record including the dead ones an authored `.lev`
carries. Every `N/N` in `ai_runtime.py` states the corrected numbers.

**The three cover-score terms that read past the unit array are not
implemented, and the cost of leaving them out is now measured.**
[`23` §5.2](23-ai-system.md) shows they carry no information: the bonus is +10
everywhere except one row and one column of the map, and a constant cancels in a
maximiser. The native capture read the same two bytes and they came back **168
and 3** — so §5.2's "both ≥ 40" does not hold for this run, which is what heap
history looks like, and the term is +5 rather than +10 on row 3.
`cover.deflection` replays every sampled unit's cover choice with and without
that penalty: **12 of 417 choices move.** That is a bound and not a defect to
fix — the bytes differ between runs and between missions, so no implementation
can reproduce them.

**Kind 12 is implemented and kinds 4 and 5 are not.** 12 exists in the engine
and is selected by nothing; 4 and 5 have no code in either shipped binary and
stay as failing arms.

**All sixteen target patterns are implemented.** The stage's first pass added
`spores_filtered` and left six refusing; the second read every remaining
handler out of the binary and cross-checked it against Ghidra, which corrected
five claims [`22` §7.2](22-combat-and-visibility.md) had been carrying —
including two families that blast the **shooter's own cell** rather than the
aim point, and one that is bounded by distance where the table said "every unit
on the map". `0x0046AA10` takes **six** arguments and not three; the sixth is
the shooter's facing, and four handlers filter by it. Five families are carried
by no shipped unit at all — a placed unit's weapon is its type's default, and
those five are campaign equipment — so they are reached by a scene built from
one weapon byte, the way [`94`](94-slice-2-report.md) reached reaction fire.

**`0x0047A8E0`'s end-of-turn facing is modelled, and the tolerance that
covered it is gone.** It was left out of the stage's first pass; seven records
per captured turn differed in that byte alone and `ai_gold.py` reported them as
a named exemption. The routine is a sweep of the whole control map for the
nearest enemy, and three of its rules are ones a remake invents differently:
mode 2 -- the one `endUnitTurn` uses -- has **no visibility test**, the choice
is a **ratchet** on the action point byte rather than a minimum, and species 2
does not attract a turn. [`23` §3.6](23-ai-system.md) carries the listing.
`UNMODELLED_FIELDS` is deleted with it: **every field of all 200 records on
both captured turns is now compared**, `+0x46` included, and the capture on
disk confirms the model without a new Wine run.

**The AI turn is atomic and there is no mid-turn save.** `AITurnResult` is a
value; nothing new is persisted, the canonical hash is unchanged, and the
playback reads the event list rather than the world — which is why skipping the
replay is free and cannot desynchronise anything.

---

## 6. What the exported build demonstrates

The acceptance list of the stage's plan, all of it inside the exported `.app`:

1. the installation is untouched — `tools/verify_untouched.sh`, before and
   after;
2. the converter's schema did not move: `CONVERTER_VERSION` unchanged, the
   second slice's save still loads. The cache was republished because
   `_C_132` joined the mission set — content, not schema;
3. **the whole computer turn agrees with the native capture on `_C_140`** — all
   200 unit records field by field and the generator's state, on turns 1 and 10;
4. all eleven order arms are dispatched, ten by shipped data and order 3 by a
   scene built for it; the checks fail on an empty corpus;
5. every one of the 1594 corpus aliens resolves a shot, and **all sixteen
   target patterns are implemented** -- the five no shipped unit carries are
   exercised by a scene built from one weapon byte;
6. plan, fire, overlay, cover score, approach and the pseudo-player agree with
   the native probes;
7. **`_C_140` is played against an opponent that closes and shoots, and defeat
   is reachable** — `SetGameControl (4,1)` when the hero dies, with the
   debriefing screen `Txtmod_d` supplies;
8. the computer's turn is visible: events play one at a time, the camera leads
   them, input is locked, and one key skips without changing the world;
9. the turn terminates — no mission run exceeds the sweep ceiling;
10. `core` still has no scene, no filesystem and no singleton, `game` cannot
    mutate its arrays, and typed warnings still fail the build.

---

## 7. How the checks were made to mean something

Thirty-eight mutations, one per rule the stage added, run against both
implementations. **Seventeen escaped** across four batteries, and every one
named a real hole. All seventeen are closed; the battery now reports
**38 mutations, 0 escapes**.

The Python escapes were all the same shape: *the checks asserted relations, and
a relation survives any table with the same order.*

* **The six horizon values were pinned by nothing.** Changing level 2's 30
  movement points to 40 left every check in `ai_runtime.py` green *and* left the
  native whole-turn capture green, because 30 points already floods a 20×20 map.
  `horizon.reach_census` now records cells reached per level over the whole
  corpus.
* **The band boundaries were checked against themselves.** `target.band_matches`
  recomputed the band with the same table it was checking, which proves only
  that the table is a function.
* **The spores filter — the one thing the new pattern adds — was unchecked.**
  Deleting the neutral-owner test left everything green. The corpus contains
  **806** situations in which a neutral prop stands next to a target a spores
  weapon can aim at, and not one of them is stamped; `spores.no_neutral_is_stamped`
  now says so, over 835 marked cells.
* **The approach cell's climb threshold was not pinned natively.** The capture's
  ten probed targets contain no height step of exactly 2, so 2 → 1 changed
  nothing the engine had been asked about. `approach.census` records 67 256
  candidates scanned and 1 628 accepted, and moves when the threshold does.

The GDScript escapes were **one** shape, and it is a property of the three-way
diff rather than a defect in it. `test_ai.gd` replays two missions; a constant
that does not change the outcome on those two missions cannot be caught by
comparing outcomes on them, and four of the five escapes were exactly the
constants the Python side needed a *corpus census* to bind. `game/` has no
corpus. So `test_ai.gd` gained a `_constants` section that writes
[`23`](23-ai-system.md)'s tables out and compares them directly — the treatment
`CONVERTER_VERSION` already gets in two files — plus `horizon_mp(1, 130) == 4`
for the byte shift, which no table check can see, and a **built scene** for the
spores filter, the way [`94`](94-slice-2-report.md) built one for reaction fire
and this stage built one for order 3.

The eight the last battery found, once §8's open items were implemented, were
one shape again and a different one: **a census that counts *how many* cells a
pattern stamps is blind to the order they are stamped in**. The order decides
the first marker retained when cells overlap; `0x0042F7D0` refuses to overwrite
the attack band, and the resolver itself later walks CtrlMap row-major. The two
unrolled eight-neighbour rings could be permuted,
and the scatter could draw its `x` before its `y`, with every count unchanged.
`pattern.scene_cells` records the sequence and not the size; `test_ai.gd`
replays the generator itself and compares the offsets.
Three more needed a scene rather than a check: the radius thresholds are
pinned by evaluating the table over every range a shipped map can produce, and
the large-occupant re-centre by **opening the gap it exists for** -- a record
whose `+0x42`/`+0x43` already equal the cell it stands on makes the branch
invisible, so the scene writes the `size` column and moves the centre, the
technique [`93` §11](93-slice-1-report.md) used natively.

**What the corpus cannot bind is said out loud — and then measured.**
`band.boundary_windows` records the nearest resolvable pair on each side of
each boundary: even after widening the population from the aliens to every live
attacker, they come nearest at 20/28, 48/52, 70/72 and 90/92, so **no boundary
has a shipped situation one point either side of it.** All four therefore rested
on the listing, with `band.table_is_the_spec_s` as their only guard — until the
`bands` capture (§3) walked a percentage across every one of them.

Two process lessons, both of which produced *wrong green results* before they
were understood:

* A first battery run was killed by a timeout **between mutating a file and
  restoring it**, and the leftover `if false and budget >= 0` in
  `core/execute_move.gd` sat in the tree while four later mutations were
  scored — each reporting extra failures that were not its own. The harness now
  **aborts** when an anchor does not match instead of skipping past it: a tree
  that is not what the battery expects makes every result after it meaningless.
* Running anything else **while the battery runs** invalidates it. Two suite
  runs issued by hand during a background battery reported a mutation as caught
  that in fact escapes, because the tree they read was mid-cycle. A mutation
  battery is a single-writer operation on the whole working tree.

`tools/**/__pycache__` is cleared before every Python run and before the final
clean one, per the rule [`94`](94-slice-2-report.md) left behind.

---

## 8. What a review pass found afterwards

Eleven findings over the whole stage, all real and all fixed in place. Nine of
them are one family, and it is the family a mutation battery cannot reach:
**checks that could not fail.**

* **Four tautologies in the mission suite.** `ended_or_deadlocked` asserted
  `ended or rounds >= TURN_LIMIT` — which is the loop's own exit condition, so
  it restated its guard; `the_script_decided` asserted the same expression
  under a second name; `rested` asserted `rests >= 0` on a counter that starts
  at zero and only ever grows. Replacing that last one with `rests > 0` showed
  what it had been hiding: **the walk never rests at all**, because it needs a
  squad member at fitness 1 with no enemy in reach and those two never meet on
  this map. It is a recorded census now, and the stand-down is checked where it
  can be built deliberately.
* **The stage's own acceptance claim had no check under it.** `_play`'s comment
  says "the `held_fire` run below proves it end to end" — and that run's result
  was discarded, while `_play`'s own arm accepts a deadlock as a pass. A change
  that broke the walk badly enough for `_C_140` never to be won on either run
  left the suite green. `outcome.the_mission_is_completable` is the claim.
* **`approach.large_ring_is_open` computed a number and only printed it.** It
  was `check(..., True, ...)` over a known model-vs-engine disagreement, so
  nothing could turn red — not a regression, and not the day somebody fixes it.
  Turning it into a census immediately showed the documented figure had drifted:
  **8 of 10 probes disagree, not 5.** The number had been wrong in this report
  and in the source comment for as long as the check could not fail.
* **`horizon.hidden_is_empty` asserted the opposite of its name** (it passed on
  a *non*-empty set, and would have been satisfied by one level out of six),
  and **`turn.everyone_spent` asserted the same list as `turn.terminal`**, so
  it could not fail independently and inflated the count by one.

Two are behaviour, and one of them is user-visible:

* **Clicking your own casualty fired at it.** The click path routed every
  `may_command` refusal into the attack branch — but that method also refuses a
  *friendly* record with no hit points, and a dead squad member stays in the
  roster and stays drawn. So a soldier who died during the alien turn could be
  shot at by his own squad, spending action points and draining the reaction
  queue. The branch now asks the question it means: alive, and not the current
  player's.
* **`AIFire.armour_of` diverged from the Python model** for a type the table
  has no row for: Python keeps the unit's own bytes, the port took the
  accessor's fallback of 0 and would have **zeroed a unit's armour after every
  shot it survived**. No mission places such a type and no emitted case carries
  one, so the check is a built scene.

And two are the hand-over seam:

* **The recursive hand-over discarded an AI turn and could not terminate.**
  `Rotation.advance_player` re-selects player 255 when no human slot qualifies,
  so the computer can be handed the turn twice running; the old shape recursed
  and assigned the outer turn's `ai_result` over the inner one, losing the
  earlier turn's events, with nothing bounding the depth. It is a bounded loop
  now, and the two turns are merged in order.
* **`AttackResult.reactions` was written and never read.** `World.submit_attack`
  filled it; the HUD reported only the outcome count, while the sibling move
  reported its reactions. A player whose shot drew return fire was told nothing.

The battery grew to 45 mutations to cover the fixes, and the armour case
escaped it until the scene was built — which is the same lesson §7 records, one
layer down: a check that cannot reach a branch is a check that cannot see it.

---

## 9. Open questions this stage leaves

1. **`_C_140` is not *won* by a scripted squad against the live planner.** The
   run deadlocks: the script's reinforcements from turn 5 plug the corridor to
   the evacuation zone faster than a scripted squad clears it. The mission is
   completable — the same script, the same route, with `ai_may_fire` off, wins
   it — and defeat against the live opponent is reproducible. The suite asserts
   each of the three outcomes for what it is rather than relaxing until one
   passes. What is missing is a squad tactic, not a rule.
2. **The large-mover second ring of `0x0040ADC0` disagrees with the engine** on
   **8 of 10** probes. Both listings read `jle` against the model's `>`, so it
   is not the tie-break; the second ring sees something this transcription does
   not. No shipped unit on `_C_140` is large, so nothing in the demonstration
   reaches it. The count stood at "5 of 10" here until a review pass turned
   `approach.large_ring_is_open` -- a `check(..., True, ...)` that computed the
   number and only printed it -- into `approach.large_ring_disagreements`, a
   census that fails in **both** directions. The old figure had drifted, and
   nothing could say so.
3. **The campaign layer, bodies, animation and sound** are still untouched, as
   they were after [`94`](94-slice-2-report.md).

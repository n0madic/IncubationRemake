# Native turn, sight and hit-probability captures

Four routines called **inside a running `Incubation.exe`**, on mission `_C_141`
loaded from save slot 6 — the same session
[`tools/movemap_gold.py`](../../../tools/movemap_gold.py) established and the
same anchor inside `aGameIntro` (`Incubation.exe+0x4bd6f`). This is the rank-1
oracle ([`docs/92`](../../../docs/92-remake-architecture.md) §5) that
`tools/inclib/turn.py` and `tools/inclib/combat.py` are diffed against.

| Routine | Address | What it pins |
| --- | --- | --- |
| `aGetHitProbability` | `0x0046A270` | the distance rule, the range gate and the accuracy curve, over a grid of ordered enemy pairs |
| `aGetUnitFullHeight` / `aGetUnitEyeHeight` | `0x0047AD70` / `0x0047AD30` | the two height helpers vision and fire measure from |
| `aRefreshPlayer` | `0x004781C0` | what a hand-over restores, diffed field by field over the whole 200-slot unit array |
| `aCheckLineOfSightEx` | `0x0046C460` | the ray fan and the "keep the smallest" rule, over the same ordered pairs |
| `aRecomputeStats` | `0x004759B0` | that `+0x15` **is** written — the correction to [`docs/25`](../../../docs/25-turn-and-round.md) §5 |
| `0x0043B320` + `0x0043B490` | — | twelve steps of the rotation, with the turn state and the twelve game-control slots at `0x00509F18` |
| `0x0043F6E0` (`aRunLCL`) | — | one `NextPlayer` invocation of the real interpreter, with `aRandom`'s seed read either side |
| `aCheckWeaponDamage` | `0x0046D1B0` | the overheat gate, the roll's span and its four arms — this is what corrected [`docs/22`](../../../docs/22-combat-and-visibility.md) §8 |
| `aAttackUnit` | `0x0046B450` | six ordered shots: the hit roll, the damage, the kill, and the overheat roll inside the shot |
| `aExecuteUse` | `0x0046DC60` | three action-point classes swept over all eight facings — **recorded, not gated**: there is no executable interaction model to diff against yet |
| `aExecuteMove` | `0x0046E220` | six walks of one two-step path, differing only in a byte written **between the walk and the call**: the step costs, the distance, the facing, the delay column, a VictoryPoint and a mine |

`aBuildVisibleMap` `0x004798C0` is pinned too, without a phase of its own: the
refresh runs the fog pass, so the `+0x4F` bytes read back after `aRefreshPlayer`
**are** its output. That is also why the "leaves the other players alone"
invariant is stated for every offset *except* `+0x4F` — the strict form was
asserted first and failed on three slots, which is how the exception was found
rather than assumed.

**The whole hand-over `0x0047D600` is deliberately not called.** It ends by
invoking `aAISystemControl` once the current player becomes 255
([`docs/25`](../../../docs/25-turn-and-round.md) §4) — the computer's entire
turn, which is out of this stage's scope and not something to start inside a
debugger probe. `0x0043B320` is the part §3.1 specifies and the part a remake's
turn sits on.

Three of the accessors are `mov al, [g]; ret` and are declared **`u8`**. Read
as `i32` the current player came back as `4436480`: only AL carries the value
and the rest of EAX is the caller's leftovers. That number is not
wrong-looking enough to notice, which is why `dbgcall` grew byte return types
rather than the mask living here.

**The LCL call chain was read off `0x0047D600`, not taken from the plan.**
`0x004402A0` sets an environment variable (**letter first, value second**),
`0x00419A40` returns the loaded mission program's id from `[0x4fd223]`, and
`0x0043F6E0` runs it. The plan's oracle table named `0x004402A0` as "the
program is called"; it is the environment setter, and
[`docs/20`](../../../docs/20-lcl-language.md)'s own table says so.

The sharp part of that phase is the generator. The engine's seed at
`0x00514078` — a **qword**, `fld`/`fst` — is `1.0` when the mission is loaded
and `847344462.0` after `NextPlayer`, which is exactly **two** draws of
`aRandom`, one per `SetVarRandom` in `_C_141`'s body. That pins the
arithmetic and says the interpreter reached both of them. It also explains why
nothing is inserted: the two draws yield 2 and 39 against a threshold of
`> 59`.

**Class 12 leaves the ammunition byte unchanged here, and that is correct.**
`aExecuteUse` on a "full munition" point sets `unit[+0x3D]` to the weapon's
magazine ([`docs/26`](../../../docs/26-interaction.md) §3.1) — it does not add
to it. The probe unit carries a `Standard Assault Rifle`, whose `mun` is 10,
and it was already holding 10. So the byte is identical before and after while
the action point *is* consumed. The check therefore asserts
`ammo == the magazine`, not `ammo increased`: the second form would fail on
correct behaviour, and reading the unchanged byte as a defect is the mistake
this note exists to prevent. A probe that showed the write would need a unit
that has spent a round first.

### What phase 10 settled

The six probes walk the identical reconstructed path — `(2,0)` → `(3,0)`
orthogonal, `(3,0)` → `(4,1)` diagonal — and every mutation is written *after*
the fill and the walk, so nothing about the route can differ between them. That
is not tidiness: the fill refuses to step a non-alien mover onto a mine
([`docs/23`](../../../docs/23-ai-system.md) §7.1), so a mine written before it
would simply be routed around and the arm would never run.

| probe | cost | ends at | `+0x50` | `+0x46` | `+0x15` | returns |
|---|---|---|---|---|---|---|
| `plain` | 3 | (4,1) | 25 | 6 | 5, unchanged | 1 |
| `delay_source` | 3 | (4,1) | 25 | 6 | 5, unchanged | 1 |
| `delay_middle` | **4** | (4,1) | 25 | 6 | 5, unchanged | 1 |
| `delay_dest` | **4** | (4,1) | 25 | 6 | 5, unchanged | 1 |
| `victory` | 3 | (4,1) | 25 | 6 | 5, unchanged | 1 |
| `mine` | **0** | **(3,0)** | **10** | **3** | **0** | **0** |

Four readings come out of that table. The step cost is `base + delay(entered)`
with `base` 1 and 2 — the **cell being left is not charged**, which
[`docs/26`](../../../docs/26-interaction.md) §5's "twice for the delay" could
not decide. The distance is 10 and 15 tenths. The facing is the last step's,
which is the second native confirmation of
[`inclib/lev.py`](../../../tools/inclib/lev.py)'s `FACING_STEPS` — the `mine`
row is the one that proves it, because it stopped on the orthogonal step and
came back holding 3 while every other probe ended on the diagonal holding 6.
And a VictoryPoint at `0x50` walked onto by player 0 becomes `0x51`, for free.

The mine row is the one that contradicts a published claim, and it is written
up in [`docs/26`](../../../docs/26-interaction.md) §6.1: the walk stops, the
movement points are zeroed *inside* the routine, FALSE comes back with a cost
of 0 — and no `ParaBomb` fires. `aRandom`'s seed is bit-identical either side,
the soldier's 11 hit points are untouched, and the mine is still on the cell.

### What the capture does *not* exercise

Stated because a green check over a corpus that never reaches a branch is
exactly the kind of check this repository treats as a bug:

* **`*out == 0xFE`, a body blocking a ray, never occurs.** The 86 rays come
  back 46 clear and 40 blocked by terrain; no unit ever stands between two
  others on this save. So the body-blocking arm of `docs/22` §6.2 is
  implemented and corpus-checked but **not** natively pinned.
* **The squad is one soldier.** Player 0 owns a single live unit here, so
  `refresh.p0` compares 13 fields on one record. The three aliens carry the
  weight of the refresh evidence — they are the records with fatigue, heat and
  a malfunction ladder, which the crates do not have.
* **The rotation has only two members here** — player 0 and the computer, so
  it cycles `0, 255, 0, …` and the multi-slot skip rule is never stretched.
  That is what a campaign save *is* (`solo_flag=1`, `player_count=1`,
  `human_count=1`, `kind=[1,0,0,0]`), so the shape is right; a hot-seat save
  would be needed to exercise more.
* **The twelve game-control slots are all zero** on this save, so their
  capture pins the accessor and the count, not the values.
* **`advancePlayer` returns `TRUE` on all twelve steps.** Its `FALSE` arm —
  "no player is left in the game" — cannot be reached without killing every
  unit on both sides first, so it stays corpus-checked and not natively
  pinned, like the body-blocking ray above.
* **The aliens never attack.** Both carry weapon 22, whose `spores_filtered`
  cover pattern is one of the eight families `inclib/combat.py` refuses rather
  than simulates, so every attack probe is fired by the soldier. That also
  costs the two 99 %-chance pairs: the captured shots run at 52 % and below.
  Deriving the pattern from two observations would have been a guess, and the
  row is left open instead.
* **`special` 12 is not reached.** The guaranteed-hit rule is pinned for
  `special` 13 (`Case`, every crate on this map); 12 (`Barrel`, `Parabomb`)
  carries the same rule in [`docs/22`](../../../docs/22-combat-and-visibility.md)
  §7 but no such unit stands here, and its neighbour explosion — and
  `special` 16's — is not modelled at all.
* **The overheat roll never comes up 30**, so the arm that destroys the
  carrier is not natively pinned. Eight probes reached three of the four arms
  — jam, damage and clear.
* **`InsertUnit` never fires**, so the MSVC `rand()` that `docs/20` §7.4 says
  it draws from is not exercised at all — only `aRandom` is. A capture where
  the two draws cleared `> 59` would need that generator's state as well, and
  it lives in the C runtime rather than in an engine global.
* **Only one entry point of one script is run natively.** The other six labels
  and the other 152 missions stay corpus-checked; `tools/lcl_runtime.py
  --check` is what covers those, at 942 invocations.
* **The mine's detonation never runs** (§6.1's new open question). The stop is
  measured; the shot is measured *not* to have happened, which is a different
  and weaker statement than knowing why. The large-unit eight-neighbour
  trigger `0x0047A4B0` is untouched as well — the mover is a small unit.
* **No teleporter and no ladder is walked.** `_C_141` carries neither, and
  unlike the mine and the VictoryPoint those two cannot be produced by writing
  one byte between the walk and the call: a teleporter needs a paired exit
  with a matching key, and the ladder half is already pinned by
  `movemap_gold.py`'s own fourth phase.
* **The walk is never blocked and never runs out of budget.** All six probes
  report `blocked = 0` and two steps; the arms `aWalkMoveMap` fails on stay
  corpus-checked.
* **The VictoryPoint is pinned on the destination only.** The rule is modelled
  **per step** — every cell the unit arrives on is tested — but the probe
  writes the band onto the last cell of a two-step path, so "a point claimed
  in passing" is a model claim and not a measured one. Writing it onto the
  middle cell instead would settle it and costs one more probe.
* **`aRefreshPlayer(252)` is not captured at all**, deliberately:
  [`docs/25`](../../../docs/25-turn-and-round.md) §7 says 252 is never stored
  in the current-player byte, so it is a call the engine itself never makes.
  An earlier version of this capture pinned the refresh on exactly that player,
  over crate records with nothing to restore, and would have agreed with a
  model that did nothing at all.

## The `.json` file is not in git

A capture embeds the loaded control map and unit array of a shipped mission, so
it is derived from Blue Byte's data for the same reason `tools/out/` is.
`.gitignore` excludes `tests/fixtures/turn/*.json`; this file is committed
instead and pins what the capture contained.

Reproduce with:

```bash
i686-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -municode -static \
    -o dbgcall.exe tools/dbgcall/dbgcall.cpp
# a COPY of the game, never gog_incubation/, with the save staged as slot 6
cp -a /path/to/gog_incubation /path/to/game-copy
mkdir -p /path/to/game-copy/Work/Saves2
cp tests/fixtures/saves/_6_.sav /path/to/game-copy/Work/Saves2/
python3 tools/turn_gold.py --game-copy /path/to/game-copy \
    --dbgcall /path/to/game-copy/dbgcall.exe \
    -o tests/fixtures/turn/_C_141.json
python3 tools/turn_gold.py --check gog_incubation
```

## What the capture pins

* **The save is the one `tests/fixtures/saves/README.md` records**, sha256
  `5e7ddd98…`, on `_C_141` of `World_A00`, 20×20.
* **The AI level of the captured session is 0**, not the 1 the models default
  to. It is an input to the movement allowance (for unit type `0x32`) and to
  the damage roll's span, so the check reads it out of the capture rather than
  assuming it — `movemap_gold.py` learned that the hard way.
* **Wine start-up on this host is intermittent** ([`docs/91`](../../../docs/91-wine-runtime-probes.md) §1).
  A phase that never reaches the anchor is an environment result; the launcher
  retries up to ten times, and a phase can succeed on attempt 1 or on attempt 8.
  The capture that produced this file needed attempt 4 twice. **Do not lower
  `--attempts`**: capping a phase below the rest is the documented way to lose
  a probe that had already been taken once, and doing it cost this capture a
  full re-run.
* **Phases are written as they land and merged on re-run**, so a phase that
  loses all ten attempts costs only itself. A phase that runs but extracts
  nothing is refused rather than written empty — `--dump` results arrive under
  the JSONL key `reads`, not `dumps` (`dbgcall.cpp` line 2640), and reading the
  wrong key once wrote 86 pairs' worth of empty arrays that looked captured.
* **Two of these routines answer through an out-parameter, not a return
  value.** `aGetHitProbability` reports the percentage and the distance that
  way, and `aCheckLineOfSightEx` reports its outcome code that way — its EAX
  is a success flag that is 1 for a clear ray and 1 for a blocked one alike
  (`docs/22` §6.2). Comparing a model against EAX produced 86 confidently
  wrong numbers before the gate caught it, which is what the gate is for.

# Native move-map captures

`aBuildMoveMap` (`0x00430A40`) called **inside a running `Incubation.exe`**, on
mission `_C_141` loaded from save slot 6.  This is the rank-1 oracle
([`docs/92`](../../../docs/92-remake-architecture.md) §5) that
`tools/inclib/movemap.py` and `godot/core/move_map.gd` are diffed against.

## The `.json` files are not in git

A capture embeds the loaded control map and unit array of a shipped mission,
so it is derived from Blue Byte's data for the same reason `tools/out/` is.
`.gitignore` excludes `tests/fixtures/movemap/*.json`; this file is committed
instead and pins what the capture contained.

Reproduce with:

```bash
i686-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -municode -static \
    -o dbgcall.exe tools/dbgcall/dbgcall.cpp
python3 tools/movemap_gold.py --game-copy /path/to/game-copy \
    --dbgcall /path/to/dbgcall.exe -o tests/fixtures/movemap/_C_141.json
python3 tools/movemap_gold.py --check gog_incubation
```

The game copy needs `Work/Saves2/_6_.sav` (the TestVersion executable uses
`Saves2`, [`docs/91`](../../../docs/91-wine-runtime-probes.md) §2).  Never run
it from `gog_incubation/`; the tool refuses a path inside this repository.

## How the mission is reached

Not by patching the executable and not by playing.  The anchor is inside
`aGameIntro` (`Incubation.exe+0x4bd6f`), where the front end has initialised
and `Info.lcl` is loaded but no screen has been built, and the save is loaded
by **calling the game's own routines** — `aSetSaveMode(0)` then
`aLoadGame(6)`.  `aMainController` and the main-menu builder are both *past*
the start-up path this Wine build faults on, so a breakpoint on either is never
reached; `aGameIntro` is before it.  Wine start-up is intermittent on this host
regardless, so the launcher retries.

## The files

| file | what it is |
|---|---|
| `_C_141.json` | the capture: the live state, the units, 74 fills, 37 allowance calls, 9 walks and 2 `aExecuteMove` probes |
| `cases_native.json` | the same, re-expressed in the shared case shape the GDScript side reads |
| `cases_synthetic.json` | `tools/movemap_runtime.py --emit-cases`: the branches no shipped map can reach |
| `cases_slice.json` | the same emitter on `_C_115`, the slice's lead mission |
| `cases_allowance.json` | `movemap_gold.py --emit-allowance-cases`: the `aGetMovePoints` calls |

All five are gitignored. `godot/run_tests.sh` copies the four `cases_*` files
into `godot/generated/movemap/`; an exported test build reads them from there
too, and falls back to `user://movemap/`.  **That order matters**: it used to be
the other way round, and a copy left in `user://` by an earlier session shadowed
a fresh one -- the run stayed green and quietly lost fifty checks.

There is no checked-in `dbgcall` plan. The plan is **generated** from the live
state -- phase 1 dumps the control map and the unit array, and the slots and
mutations phase 2 asks for are derived from what phase 1 found -- so a
hand-written plan would be a copy that could drift.
`tools/movemap_gold.py --emit-plan state|fill` prints one for inspection.

## `_C_141.json`

| field | value |
|---|---|
| size | 162762 bytes |
| sha256 | `9d8b41976444464b51501c11bd0a2b758a3cf9794e28a12ab57302a5d219c06c` |
| mission | `_C_141`, 20x20 |
| save | `Work/Saves2/_6_.sav` sha256 `5e7ddd984b41f8601276f4a852469ffda45b6f2c7a1424751f1f8a5f1024ff06` |
| `Incubation.exe` sha256 | `b07aa2478fbfaf252a585cff180d03b468d5141e0fdb5606bd09f0891024fcc9` |
| breakpoint | `Incubation.exe+0x4bd6f` |
| live unit slots | 14 |
| fills | 74 (28 of the mission as loaded, 46 with a written field) |
| `aGetMovePoints` calls | 37 |
| `aWalkMoveMap` calls | 9 |
| `aExecuteMove` probes | 2 (one over a written ladder pair, one control) |
| AI level `0x00460450` returned | 0 |

The mutated runs write a field the engine itself writes — movement points, the
Jet Pack, a type's `special`, a cell's obstacle byte — through a three-byte
injected `mov [ecx], dl; ret`, and restore it afterwards.  That is what gives a
**native** oracle to branches the shipped campaign never exercises: the
transient obstacle byte is 255 in all 184162 shipped cells, no unit here
carries the Jet Pack, and no type here has `special` 1, 14 or 15.

Fields written: `cell_obstacle` [1, 2, 3], `cell_field_type` [8], `type_special`
[1, 14, 15], `type_size` [1], `unit_equipment` [0, 1], `unit_mp`
[1, 2, 3, 4, 6, 7, 8, 12], `unit_byte` at `+0x19` (FP), `+0x41` (action state),
`+0x42`/`+0x43` (position) and `+0x57` (rested).

`type_size` 1 is the **large unit**.  `Info.lcl` sets it on only `ComBot`,
`Tr'Yn` and `Al'Coo`, none of which is on this mission, and the nine missions
that do place one are hours of play away -- so the byte is written instead, in
the shipped `SetUnitInfo` row at `unitInfo[type] + 0x7B` (`0x00430CA6` reads it
as `byte [type*126 + 0x51C09B]`).  Nothing else the fill reads changes, so the
seven clearance runs isolate `0x0047A410`: 232 cells refused, 61 passed, and a
2 x 2 for the fire condition -- `{large, small}` x `{fire, no fire}`, all four
native, with the fire written **diagonally** from a candidate so that it lands
on a cell the 4-connected fill can never step through. The large mover loses
28 cells to it (29 -> 1) and the small mover 3 (98 -> 95); the 25-cell excess
is the clearance ring's own fire test, and comparing the two movers *with* fire
instead would have measured the whole clearance test and passed with the arm
removed.

`cell_field_type` 8 is the **Ladder**, which no shipped cell in any of the 155
missions carries: writing it onto a mover's own cell and one neighbour is what
gives the ladder-to-ladder step a native oracle instead of a synthetic one.

Two blocks of runs exist for what they *decide*, not for what they write, and
both were added after a review found the capture certifying branches it had
never exercised:

* **The obstacle runs are per owner.** A mine stops everyone except units owned
  by player 255 (docs/23 §7.1), and that is the only reason the fill reads the
  owner at all. The runs used to compute the target neighbour once, for the
  first mover, and then issue the fill for *each* mover in turn -- so the
  alien's mine landed beside somebody else's unit and its fill never met it.
  Deleting the exemption from the model changed nothing here. Each mover now
  gets a walkable neighbour of its own, and the runs carry the cell so the
  checks can ask whether the engine entered it: `mine.alien_passes`,
  `mine.stops`, `fire.stops` for both owners.
* **One fill reaches a hidden unit's cell.** `visibility == 3` makes a unit
  count as empty ground, and the evidence for it used to be that a hidden unit
  *existed* in the roster -- a fact about the save, not about any fill. Making
  hidden units block like every other unit still passed. A mover is now chosen
  that can reach the hidden slot's cell, and the check requires the engine to
  have marked it.

The `unit_byte` writes belong to the `aGetMovePoints` phase only.  Moving a unit
by writing `+0x42`/`+0x43` does **not** update the control map's cell links and
would corrupt a fill; it is safe there because the allowance routine and its
Banner scan read the unit array and nothing else, and every write is undone
before the next call.

## The four phases

| phase | plan | what it asks |
|---|---|---|
| 1 | `gold_state` | load slot 6, dump the control map and the unit array |
| 2 | `gold_fill` | the same load, then 74 `aBuildMoveMap` fills |
| 3 | `gold_extra` | the same load, then 37 `aGetMovePoints` calls and 9 `aWalkMoveMap` walks |
| 4 | `gold_execute` | **reloads before each probe**, then one walked step over a written ladder pair and one over the same pair untouched |

Phase 2's 74 fills are: the mission as loaded (28), a movement-point sweep, the
Jet Pack and the two `special` refusals plus the innate warp, the transient
obstacles **per owner**, the ladder pairs, the large-unit clearance including
its fire 2 x 2, and one fill that reaches a hidden unit.

Phase 4 is the only one that does not restore what it wrote: it moves a unit,
rewrites the cells it walked over and changes the overlay, and writing the
mutated bytes back does not undo any of that.  Reloading the save is the only
restore that covers it.  It also runs **last** and is allowed to fail: it
animates and plays sound, so it is the one plausible hang, and a failure there
must not cost the three phases that already succeeded.  When it does not run
the fixture carries `execute_move: []` and the check says so in words.

Phase 3 re-fills before **every** walk: the walk's own final sweep destroys the
overlay it read, so a second walk over the same fill would read rubble.  One of
the nine asks for a target the fill never marked, which is the failure arm --
the ascent wanders until the 300-step budget is gone and returns FALSE.

## What the capture corrected

Five things were wrong, and only a live call could show any of them --
the last is about the capture itself rather than about the specs:

1. **The start cell is seeded before the shield refusal, not after.**
   [`docs/23`](../../../docs/23-ai-system.md) §7.1 orders them the other way.
   With `cell[+0x10] = 3` written into the mover's own cell the engine returns
   an otherwise empty map whose start cell holds state 10 and the mover's
   movement points.  The `special` refusal is genuinely first: it marks nothing.
2. **The warp pass does not overwrite a cell the fill already marked.**
   [`docs/10`](../../../docs/10-lev-mission-format.md) §4.5 lists five
   acceptance tests; there is a sixth.  Over three warp runs, 13 cells the
   model would have turned into warp targets kept their 10.
3. **The test for it is on `cell[+0x00]`, not on `cell[+0x0C]`.** Nine cells
   were marked reachable with zero movement points left — which the fill's own
   visited test cannot tell from unvisited — and they kept their 10 as well.
4. **Two of the coverage checks were certifying branches nothing exercised.**
   `coverage.obstacle` asserted which obstacle *values* the plan wrote, and
   `coverage.hidden` asserted that a hidden unit existed in the roster. Neither
   looked at an outcome: deleting the alien mine exemption, and separately
   making hidden units block like any other, both left the capture fully green.
   Fixed on both sides -- the planner produces runs that meet those branches,
   and the checks compare what the engine did. Both mutations are red now.
5. **The direction loop runs 0…7, and `anyFriendlyBlocked` is a constant.**
   The model looped over the four orthogonal directions only, which is right
   about *cells* and wrong about the scratch flag: the four refused diagonals
   still take the caller to `0x00430C64`, which clears it, so every cell the
   fill examines ends by clearing it.  Over these 74 fills the flag is TRUE on
   exactly the 26 whose mover has no movement points — the ones where the loop
   never runs — and FALSE on all 48 that ran a wave.  A 4-direction
   transcription agreed with the engine on 71 of the first 72 by luck, and the one
   that disagreed only appeared because the clearance work added a wider fill
   than the capture had held before.  [`docs/23`](../../../docs/23-ai-system.md)
   §7.6.

## Every fill in the file

| # | slot | pf | written fields | reachable | warp | afb |
|---|---|---|---|---|---|---|
| 0 | 0 | 0 | - | 1 | 0 | 1 |
| 1 | 0 | 1 | - | 1 | 0 | 1 |
| 2 | 1 | 0 | - | 1 | 0 | 1 |
| 3 | 1 | 1 | - | 1 | 0 | 1 |
| 4 | 2 | 0 | - | 1 | 0 | 1 |
| 5 | 2 | 1 | - | 1 | 0 | 1 |
| 6 | 3 | 0 | - | 11 | 0 | 0 |
| 7 | 3 | 1 | - | 11 | 0 | 0 |
| 8 | 4 | 0 | - | 1 | 0 | 1 |
| 9 | 4 | 1 | - | 1 | 0 | 1 |
| 10 | 5 | 0 | - | 1 | 0 | 1 |
| 11 | 5 | 1 | - | 1 | 0 | 1 |
| 12 | 6 | 0 | - | 1 | 0 | 1 |
| 13 | 6 | 1 | - | 1 | 0 | 1 |
| 14 | 7 | 0 | - | 1 | 0 | 1 |
| 15 | 7 | 1 | - | 1 | 0 | 1 |
| 16 | 8 | 0 | - | 1 | 0 | 1 |
| 17 | 8 | 1 | - | 1 | 0 | 1 |
| 18 | 9 | 0 | - | 1 | 0 | 1 |
| 19 | 9 | 1 | - | 1 | 0 | 1 |
| 20 | 10 | 0 | - | 1 | 0 | 1 |
| 21 | 10 | 1 | - | 1 | 0 | 1 |
| 22 | 11 | 0 | - | 1 | 0 | 1 |
| 23 | 11 | 1 | - | 1 | 0 | 1 |
| 24 | 16 | 0 | - | 1 | 0 | 1 |
| 25 | 16 | 1 | - | 1 | 0 | 1 |
| 26 | 17 | 0 | - | 1 | 0 | 1 |
| 27 | 17 | 1 | - | 1 | 0 | 1 |
| 28 | 3 | 0 | unit_mp=1 | 4 | 0 | 0 |
| 29 | 3 | 1 | unit_mp=1 | 4 | 0 | 0 |
| 30 | 3 | 0 | unit_mp=2 | 8 | 0 | 0 |
| 31 | 3 | 1 | unit_mp=2 | 8 | 0 | 0 |
| 32 | 3 | 0 | unit_mp=4 | 14 | 0 | 0 |
| 33 | 3 | 1 | unit_mp=4 | 14 | 0 | 0 |
| 34 | 3 | 0 | unit_mp=6 | 20 | 0 | 0 |
| 35 | 3 | 1 | unit_mp=6 | 20 | 0 | 0 |
| 36 | 3 | 0 | unit_mp=8 | 30 | 0 | 0 |
| 37 | 3 | 1 | unit_mp=8 | 30 | 0 | 0 |
| 38 | 4 | 0 | unit_mp=1 | 3 | 0 | 0 |
| 39 | 4 | 1 | unit_mp=1 | 3 | 0 | 0 |
| 40 | 4 | 0 | unit_mp=2 | 8 | 0 | 0 |
| 41 | 4 | 1 | unit_mp=2 | 8 | 0 | 0 |
| 42 | 4 | 0 | unit_mp=4 | 24 | 0 | 0 |
| 43 | 4 | 1 | unit_mp=4 | 24 | 0 | 0 |
| 44 | 4 | 0 | unit_mp=6 | 47 | 0 | 0 |
| 45 | 4 | 1 | unit_mp=6 | 47 | 0 | 0 |
| 46 | 4 | 0 | unit_mp=8 | 70 | 0 | 0 |
| 47 | 4 | 1 | unit_mp=8 | 70 | 0 | 0 |
| 48 | 3 | 0 | unit_mp=4, unit_equipment=1 | 14 | 28 | 0 |
| 49 | 3 | 1 | unit_mp=4, unit_equipment=1 | 14 | 28 | 0 |
| 50 | 3 | 0 | unit_mp=4, type_special=1 | 0 | 0 | 0 |
| 51 | 3 | 0 | unit_mp=4, type_special=14 | 0 | 0 | 0 |
| 52 | 3 | 0 | unit_mp=4, type_special=15 | 14 | 52 | 0 |
| 53 | 3 | 0 | unit_mp=4, cell_obstacle=3 | 1 | 0 | 0 |
| 54 | 3 | 0 | unit_mp=4, cell_obstacle=1 | 13 | 0 | 0 |
| 55 | 4 | 0 | unit_mp=4, cell_obstacle=1 | 14 | 0 | 0 |
| 56 | 3 | 0 | unit_mp=4, cell_obstacle=2 | 13 | 0 | 0 |
| 57 | 4 | 0 | unit_mp=4, cell_obstacle=2 | 24 | 0 | 0 |
| 58 | 3 | 0 | unit_mp=4, cell_obstacle=3 | 14 | 0 | 0 |
| 59 | 4 | 0 | unit_mp=4, cell_obstacle=3 | 24 | 0 | 0 |
| 60 | 4 | 0 | unit_mp=12, cell_field_type=8, cell_field_type=8 | 141 | 0 | 0 |
| 61 | 4 | 0 | unit_mp=7, cell_field_type=8, cell_field_type=8 | 58 | 0 | 0 |
| 62 | 4 | 0 | unit_mp=6, cell_field_type=8, cell_field_type=8 | 47 | 0 | 0 |
| 63 | 3 | 0 | unit_mp=12, cell_field_type=8, cell_field_type=8 | 44 | 0 | 0 |
| 64 | 3 | 0 | unit_mp=3, cell_field_type=8, cell_field_type=8 | 10 | 0 | 0 |
| 65 | 3 | 0 | unit_mp=2, cell_field_type=8, cell_field_type=8 | 6 | 0 | 0 |
| 66 | 2 | 0 | unit_mp=8, type_size=1 | 29 | 0 | 0 |
| 67 | 2 | 1 | unit_mp=8, type_size=1 | 29 | 0 | 0 |
| 68 | 1 | 0 | unit_mp=8, type_size=1 | 3 | 0 | 0 |
| 69 | 7 | 0 | unit_mp=8, type_size=1 | 4 | 0 | 0 |
| 70 | 2 | 0 | unit_mp=8, cell_obstacle=1, type_size=1 | 1 | 0 | 0 |
| 71 | 2 | 0 | unit_mp=8, cell_obstacle=1 | 95 | 0 | 0 |
| 72 | 2 | 0 | unit_mp=8 | 98 | 0 | 0 |
| 73 | 9 | 0 | unit_mp=40 | 308 | 0 | 0 |

## What it still does not cover

* `_C_115`, the slice's lead mission.  Reachability there is compared against
  the executable Python reference, which this capture pins — not against the
  engine directly.  Lifting it would mean driving the campaign to the
  thirteenth mission of the other chain.

Two entries that used to be here are gone, and both went the same way -- by
writing the byte rather than by finding a map that has it. A **Ladder** cell
(field type 8, on none of the 184162 shipped cells) is written into a mover's
own cell and one neighbour; a **large unit** (`size == 1`, on only three unit
types and none of them here) is written into the shipped `SetUnitInfo` row.
Neither needed the mission to contain the thing being tested.

# The presentation capture

`tools/presentation_gold.py` — the engine's own idle starter, `IWorld::Simulate`,
`aFreeCHAnimation` and the seven death and damage creators, called inside a
running `Incubation.exe` under `tools/dbgcall`, with the slot table, the
second Lehmer seed, the live `StdAnimation`, the bound parts and the blob pool
read back. It is the measurement behind
[`docs/42` §4.8.1 and §6](../../../docs/42-mission-presentation.md).

## The `.json` file is not in git

`capture_pose.json` holds memory read out of the retail executable, so it is
excluded like every other capture (`.gitignore` excludes
`tests/fixtures/*/*.json`); this file is committed instead.

Reproduce with a **copy** of the game outside this repository, with
`tests/fixtures/saves/_6_.sav` staged as `Work/Saves2/_6_.sav`, exactly as
`blob_gold.py` needs it:

```bash
python3 tools/presentation_gold.py --game-copy /path/to/copy \
    --dbgcall /path/to/copy/dbgcall.exe
python3 tools/presentation_gold.py --check gog_incubation      # 399 checks
python3 tools/presentation_gold.py --emit-death-cases \
    tests/fixtures/presentation/cases_death.json --root gog_incubation
```

Phases are written as they land and merged on re-run; `--phase NAME` re-takes
one. Wine start-up on this host is intermittent (`docs/91` §1): the phases of
the kept capture reached the anchor on attempts between 2 and 10, and one run
of the tool lost three phases to ten failed attempts each before a second run
took them.

`cases_idle.json` is `--emit-idle-cases`: the `idle_random` phase's two
hundred starter calls with the seed and slot 1's table either side, every
unit record's guard inputs, and the `idle_pose` phase's clock -- what
`godot/tests/test_presentation_native.gd` replays the idle scheduler against.

`cases_death.json` (gitignored like the capture) is what `--emit-death-cases`
writes from it for `godot/tests/test_presentation_native.gd`: per death
phase, the arguments, the seed, everything the creator read and **the
engine's own records**, so the GDScript programs are compared with the pool
`Incubation.exe` left, not with the Python.

## What the forty-one phases hold

The twelve added later on 2026-09-03 for `docs/42` §8 (`docs/97` §32) are
the set pieces' creators: `death_tube_puffs_marine`,
`death_platform_dust_marine`, `death_ground_debris_marine`,
`death_roof_debris_marine`, `death_wall_debris_marine`,
`death_fire_circle_marine`, `death_laser_barrier_marine` and
`..._marine_x` (the same creator along `+y` and along `-x`, because its
direction switch is the only argument that changes the geometry),
`death_statue_beam_marine`, `death_teleport_stream_marine`,
`death_bomber_marine` and `death_para_bomb_marine`. All twelve agreed with
the transcriptions field for field on their first run; `deaths_state` was
re-taken again for `A_DEBRIS`, `A_LASERG`, `L069EE00` and `A_PARAB1`.

The seven `death_*` phases added on 2026-09-03 for `docs/42` §7 (`docs/97`
§31) -- `death_arrows_marine`, `death_landing_dust_marine`,
`death_heal_flash_marine`, `death_poison_flash_marine`,
`death_zoombob_marine` (`(x, y, z, 4, 10, 3)`), `death_trail_marine` and
`death_push_dust_marine` -- have the same shape as the death phases; the
last three take the marine's own object position through `dbgcall`'s
`[$s_m+0x10]` / `+0x14` / `+0x18` reads rather than a tile, and
`deaths_state` was re-taken to resolve handles for `A_ARROW.3DI`,
`A_SKULL.3DI` and the four `A_CROSS*.3DI`. 364 records across the
twenty-six death phases agree field for field; the capture corrected the
poison flash's radius and the trail's per-index delay.

Every phase is its own process and loads the save first (`aSetSaveMode(0)`,
`aLoadGame(6)`). The five death phases added on 2026-09-03 --
`death_kill_fire_marine` (delay 0, the fight's), `death_kill_fire_circle`
(delay 20, `FireCircle`'s), `death_fire_death_marine`,
`death_flying_unit_case` (the case's own `A_BOX.3DI`, which `deaths_state`
resolves a handle for since that re-take) and `death_fire_explosion_alien`
-- have the shape of the fourteen below: a written seed, one call, the pool
read back; 321 records across the nineteen agree field for field.

**`idle_random`** — the whole unit array and object array, then
`aStartIdleAnimation(1, 50)` **two hundred times** with the slot table, the
`StdAnimation` behind slot 1 and `aRandom2`'s seed (`0x00514070`) read after
each, then `aFreeCHAnimation(1)`. Slot 10 is the only unit of type 50; unit 0
is a case (type 32). `--check` replays the seed: the countdown the menu left
ticks down with no draw, every later call draws **exactly once**, the drawn
slot is refused by one of the starter's guards or taken, and the only slot the
guards accept is 3 (`Sgt. Brat`, type 23) — so the type argument never chose
(`docs/42` §6.1). A start is a one-in-two-hundred event and **the kept run saw
none**: 200 calls, every one a tick or a refused draw. The start's own state
(countdown and length 90 for `P0_S0_000`, speed 1.5, one loop) is pinned by
`idle_pose`, which forces it.

**`idle_pose`** — `aFreeCHAnimation(1)`; `memcpy` writes 0 over slot 1's
countdown and the double 139.0 over the seed (its first draw is 3); the
starter takes on its first call. Twenty-one binder calls — `memcpy(p, p, 0)`
over each movement's channel interface minus `0x158` — name the `V100Part`s
the clip binds (20 of 21; `Banner` is not in `P1_002`). Then eight stops,
each reading every bound part whole (`0x170` bytes): after the start; after
45 `Simulate(1.0, 0)` (clock 67.5); after 15 more (90, finished); after 2
more (90, held); after `aFreeCHAnimation(1)`; after one more step; after two.
`--check` pins the clock, the hold (10 of the 20 bound parts end away from
their bind record), the free moving nothing, every bound part's Eng3d record
back at its bind record on the first step after the free, the channel slots (0 / 1 for position / rotation while attached, zero
after), and the `__thiscall` cleanup of `Simulate`.

**`deaths_state`** — the unit array, the control map, the gore level
`0x00512A00` and the output mode `0x00512A78`, the pool handle from
`aResetBlobs`, `aGetModelIndex` for the twenty model names the programs can
pass, and `0x0047AD70`'s height for the three tiles' units. The copy's
`Game.opt` holds gore level **2** and output mode 2.

**`death_*`** (fourteen) — the symbol objects of the three tiles, the pool
reset, `memcpy` writing the seed, the creator called with tile arguments,
and the first 48 pool records read with the seed either side. `--check`
replays `blob_creators.DEATH_PROGRAMS` from the written seed against every
record read (253 across the fourteen) and the draw count. Tiles: the marine (slot 3, player 0), the
`Ray'Ther` (slot 10, the computer's) and a case (slot 0). Calls: the puff
`0x004297F0` on the marine; `0x00420B80` on both units; `0x004298D0` on the
case; `0x004216D0` on the marine; `0x00420D80` and `0x00421360` in modes 0, 1
and 2 from the marine to the `Ray'Ther`; `0x00421C50` on the `Ray'Ther` with
seed 7.0 (the seven-in-ten branch) and 4242.0 (the other, which nests
`BloodFlood` and `FlyingDebris`), and on the marine (the level-2 puff).

What no phase measures: gore levels 1 and 3 and output mode 3's twelve-throw
debris loop, which are transcribed from their instructions and not run.


## `capture_pose.json` — the eight `special_*` phases (2026-09-03)

Slice E's, and the one family here that reads **cells** rather than the blob
pool: the four placers of [`docs/42` §9.1](../../../docs/42-mission-presentation.md)
are not blob creators, so the death phases' shape does not fit them. Each phase
loads the fixture save, reads the whole 20 × 20 control map and the whole
80-slot special-object array `[0x004FA828]` (a **pointer**; each record is 66
bytes and its state byte is `+0x40`), calls one placer with controlled tiles,
and reads both back after every call.

| phase | what it reaches |
|---|---|
| `special_fire` | the nine-fire arm's centre, at the cell's own height |
| `special_fire_out_of_window` | the same call a full `0x640` above — refused |
| `special_fire_over_a_mine` | the mine's object deleted, and no detonation |
| `special_mine` | `+0x0E = 0`, `+0x0F = 0`, `+0x10 = 2` |
| `special_shield` | twice: the second refreshes `+0x0E` and makes no object |
| `special_fire_onto_a_shield` | the fire refuses the cell outright |
| `special_glow` | **nothing** — `World_A00` carries no `GLOW1.3DI` |
| `special_tick` | a fire, a shield and a glow, then two round ticks |

`--emit-special-cases` writes `cases_special.json`, which `test_ctrl_map.gd`
replays against `godot/core/cell_objects.gd`. It is sparse: every cell away from
the idle six (`0, 255, 255, 255, 0, 255`) and every taken slot, before and after
each call, so a model that wrote a cell the engine left alone shows up as an
extra row.

Each step also carries an **`origin`** key — `"m"` or `"a"` for the two tiles
of the capture's own scene, `"g"` for the two `World_D00` phases, which carry
that one alone. It is the checker's own choice written down: deriving it in the
GDScript twin from the phase name once made both D00 cases throw on a missing
key and skip the position check while the suite still reported its full count
(`docs/97` §40.6). A case file without it fails the suite by name.

### The two that run on a second save

`GLOW1/2.3DI` live in `World_D00` alone, so the phases that reach the glow's
own lifecycle load a different mission. The save is built rather than played:

```bash
python3 tools/sav_parse.py tests/fixtures/saves/_6_.sav \
    --wrap gog_incubation/Missions/_C_116.lev \
    --out /path/to/copy/Work/Saves2/_7_.sav
```

`_C_116` is `World_D00`, 34 × 40, and one of the two missions that use
`SetGroundFire`. `special_glow_d00` is the same call the `A00` phase measured
refusing, and here it writes all three bytes; `special_glow_tick_d00` adds two
round ticks and measures the 2 → 1 decay. The wrapped save is **not** a played
one — only its map and what the game derives from it are trustworthy — and it
is gitignored like the rest.

`_C_116` loads with **slot 0 already taken by a state-5 object no cell names**,
so the check and the case file seed the model's array from the capture rather
than deriving it from the cells.

**What is still not measured**: `0x00470AB0`'s ignition. It calls
`aPlayGroundFireAnimation`, which renders, and no `aPlay*` can be called under
the debugger — a boundary of the method rather than a gap in this capture.

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
python3 tools/presentation_gold.py --check gog_incubation      # 182 checks
```

Phases are written as they land and merged on re-run; `--phase NAME` re-takes
one. Wine start-up on this host is intermittent (`docs/91` §1): the phases of
the kept capture reached the anchor on attempts between 2 and 10, and one run
of the tool lost three phases to ten failed attempts each before a second run
took them.

## What the seventeen phases hold

Every phase is its own process and loads the save first (`aSetSaveMode(0)`,
`aLoadGame(6)`).

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

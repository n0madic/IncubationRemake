# Save-game fixtures

Nine real saves were produced by playing the retail game under Wine; these six
are the ones no other file in the set duplicates. They are the only real `.sav`
data this project has ever had, and they closed or narrowed five open questions
in [`docs/11-save-game-format.md`](../11-save-game-format.md)
and [`docs/25-turn-and-round.md`](../25-turn-and-round.md).

## The `.sav` files are not in git

Every save embeds a **byte-identical copy of a shipped `.lev` mission** — 213888
or 241488 bytes of Blue Byte's data — which is why `.gitignore` excludes
`tests/fixtures/saves/*.sav` for the same reason it excludes `tools/out/`.
This file is committed instead: it records what each fixture proves and pins its
digest, so a claim can be re-checked against a regenerated fixture even if the
binaries are gone.

They are working material for the research, not a corpus: no `--check` depends
on them, and the always-run block in `CLAUDE.md` stays green without them.
To use one:

```bash
python3 tools/sav_parse.py tests/fixtures/saves/_31_.sav
python3 tools/sav_parse.py tests/fixtures/saves/_5_.sav --lev /tmp/map2.lev
```

## What each one is

### `_0_.sav` — mission 1, turn 1, clean campaign start

| field | value |
|---|---|
| size | 221578 bytes (20x20 map) |
| mission | `_C_140` |
| turn counter | 1 |
| equipment points | `[100, 0, 0, 0]` |
| commendations | 0 |
| passwords | `0xFF x100` |
| unit-pool records | `[]` |
| ProgramState | `[11, 5, 3]` |
| scoreboard[0] `+0x00`..`+0x1C` | `[0, 0, 0, 0, 0, 0, 0, 0]` |
| LCL slot 0 | 0 |
| sha256 | `d3baf0336aa5e8a8d839b8271d2bc954525f62d2dba963f554b6de8b191e7bde` |

The only fixture from a session that went straight into the campaign: the password slots hold 100 bytes of `0xFF` (zeros put through the involution) and the equipment points read `[100, 0, 0, 0]` with no four-player residue. Empty unit pool, empty scoreboard.

### `_2_.sav` — mission 1, turn 10, scoreboard part-filled

| field | value |
|---|---|
| size | 221578 bytes (20x20 map) |
| mission | `_C_140` |
| turn counter | 10 |
| equipment points | `[100, 2000, 2000, 2000]` |
| commendations | 0 |
| passwords | `INVALID_PASSWORD` |
| unit-pool records | `[]` |
| ProgramState | `[11, 5, 3]` |
| scoreboard[0] `+0x00`..`+0x1C` | `[3, 3, 0, 0, 0, 0, 0, 0]` |
| LCL slot 0 | 0 |
| sha256 | `9d44bd68512ebdab6e42884f9ec98e8908e746b0e36c15a3bbd9e8207d25d07c` |

The highest turn count in the set, and the save that shows scoreboard `+0x00` is **not** the turn counter — it reads 3 at turn 10.

### `_5_.sav` — campaign location screen, 40x40

| field | value |
|---|---|
| size | 249178 bytes (40x40 map) |
| mission | `_C_yyy` |
| turn counter | 0 |
| equipment points | `[100, 2000, 2000, 2000]` |
| commendations | 3 |
| passwords | `INVALID_PASSWORD` |
| unit-pool records | `[0]` |
| ProgramState | `[11, 5, 2]` |
| scoreboard[0] `+0x00`..`+0x1C` | `[0, 25, 0, 3, 0, 3, 0, 119]` |
| LCL slot 0 | 1 |
| sha256 | `4ad1ef9802b62ed050d932cabcead402662914f143644d68e876ff2e3cac7ca3` |

Names `_C_YYY` as the current mission and embeds its 40x40 map, so it is both the other end of the size formula (249178 bytes) and the proof that a map-type-4 screen runs through the mission pipeline. Turn 0. Unit pool occupies bank 0 only. LCL slot 0 still holds the previous mission's result.

### `_31_.sav` — mission-entry snapshot, written by the game

| field | value |
|---|---|
| size | 221578 bytes (20x20 map) |
| mission | `_C_141` |
| turn counter | 0 |
| equipment points | `[100, 2000, 2000, 2000]` |
| commendations | 3 |
| passwords | `INVALID_PASSWORD` |
| unit-pool records | `[0, 31]` |
| ProgramState | `[7, 3, 2]` |
| scoreboard[0] `+0x00`..`+0x1C` | `[0, 25, 0, 3, 0, 3, 0, 119]` |
| LCL slot 0 | 1 |
| sha256 | `2bf72bd0e1ba499f80f9ce7232f1137670c48e84ad6a538b05b8e694981ccda6` |

The single most informative file: mission `_C_141` already loaded, turn counter still 0, unit pool occupying **both** banks, and the previous mission's LCL slot 0 not yet cleared.

### `_6_.sav` — mission 2, turn 1, pool in bank 1

| field | value |
|---|---|
| size | 221578 bytes (20x20 map) |
| mission | `_C_141` |
| turn counter | 1 |
| equipment points | `[100, 2000, 2000, 2000]` |
| commendations | 3 |
| passwords | `INVALID_PASSWORD` |
| unit-pool records | `[31]` |
| ProgramState | `[11, 5, 3]` |
| scoreboard[0] `+0x00`..`+0x1C` | `[0, 25, 0, 3, 0, 3, 0, 119]` |
| LCL slot 0 | 0 |
| sha256 | `5e7ddd984b41f8601276f4a852469ffda45b6f2c7a1424751f1f8a5f1024ff06` |

The state `_31_` becomes once the mission starts: bank 0 cleared, roster in bank 1, LCL slot 0 back to 0.

### `_33_.sav` — the second automatic slot

| field | value |
|---|---|
| size | 221578 bytes (20x20 map) |
| mission | `_C_141` |
| turn counter | 1 |
| equipment points | `[100, 2000, 2000, 2000]` |
| commendations | 3 |
| passwords | `INVALID_PASSWORD` |
| unit-pool records | `[31]` |
| ProgramState | `[7, 3, 6]` |
| scoreboard[0] `+0x00`..`+0x1C` | `[0, 25, 0, 3, 0, 3, 0, 119]` |
| LCL slot 0 | 0 |
| sha256 | `80efeea68e981c299b4eb13971fc24afb2f1bf0d2dacc1f278b8c79d8d701f05` |

Carries the fourth distinct ProgramState triple. Written later in the mission than `_31_`; its trigger is not established.

## Coverage

Between them the six cover both map sizes in the corpus' range, both map types
the campaign uses (1 `Campaign` and 4 `Special`), both branches of the password
involution, both equipment-point layouts `0x0043AD20` can leave, turn counts 0,
1, 2 and 10, all four observed ProgramState triples, and every state of the unit
pool — empty, bank 0, both banks, bank 1.

## What no campaign save can settle

`MissionObjectives` is 28 zero bytes in all nine: `aMultiPlayer.cpp` owns it and
a single-player campaign never fills it. That block needs a `net session` save.


## A wrapped save is not one of these

`sav_parse.py --wrap` writes a save carrying a different mission's `.lev`
between one of these saves' fixed blocks. It is how `presentation_gold.py`
reaches `World_D00`, the one world set with `GLOW1/2.3DI`
([`docs/97` §38.1](../97-slice-5-report.md)):

```bash
python3 tools/sav_parse.py tests/fixtures/saves/_6_.sav \
    --wrap gog_incubation/Missions/_C_116.lev --out /path/to/copy/Work/Saves2/_7_.sav
```

The game loads it and `sav_parse.py` reads it back as `_C_116` on `Level04b`
in `World_D00`, 34 × 40. **It is not a played save**: the prefix's
game-control block, unit pool and player state are `_6_.sav`'s, and only the
map and what the game derives from it are trustworthy in it. Nothing is
committed and no `--check` depends on one.

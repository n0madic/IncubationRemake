# Native AI captures, and the cases derived from them

Two files, both **gitignored**, both derived from Blue Byte data the way
`tools/out/` is. This README is the committed record of what they hold.

| File | Written by | What it is |
| --- | --- | --- |
| `capture_ai.json` | `tools/ai_gold.py --game-copy … --dbgcall …` | twelve phases called **inside a running `Incubation.exe`** |
| `cases_ai.json` | `tools/ai_runtime.py --emit-cases` | two whole AI turns run by `inclib/ai.py`, for `godot/tests/test_ai.gd` to replay |

They were tracked in git until the third slice noticed. The rule is the
project's oldest — extracted retail data is not committed — and
[`docs/94` §8](../../../docs/94-slice-2-report.md) records the same mistake
being made once before with `cases_lcl.json`, by a `git add -A` that added the
file and its `.gitignore` line in the same commit. Here the `.gitignore` line
was simply never written. Both are untracked now; the blobs remain in the local
history at `7ad818a` and nothing has been pushed anywhere.

## What `capture_ai.json` pins

The session is the one [`tools/movemap_gold.py`](../../../tools/movemap_gold.py)
established: the same anchor inside `aGameIntro` (`Incubation.exe+0x4bd6f`),
the same ten-attempt retry loop, and the byte writer reaching the game's own
imported `memcpy` — **not** `--code`, which on this host makes the image fault
before the anchor, ten attempts out of ten.

The saves are `tests/fixtures/saves/_0_.sav` and `_2_.sav`, staged into the
copy as `Work/Saves2/`: `_C_140` at turn 1 and the same mission at turn 10 with
nine script-inserted reinforcements on the board. `_6_.sav` (`_C_141`) is there
too, for the pseudo-player phase, which needs a mission with thirteen player-252
records.

| Phase | Routine | What it pins |
| --- | --- | --- |
| `state_0`, `state_2` | `aLoadGame` | the two boards every other phase starts from, plus the seed and the AI level |
| `predicates` | `0x0040B000` / `0x0040B040` / `0x0040B080` | the three ownership tests, over 90 ordered pairs |
| `cover` | `0x0040B0D0` | the cover score over 60 cells, **and the two bytes it reads past the unit array** |
| `overlay` | `0x0042FF30`, `0x0042FE90` | the target overlay and its prune, read back as cells |
| `bands` | `0x0042FF30` + `0x0046A270` | **the five hit-chance bands**, one point either side of each of [`docs/23`](../../../docs/23-ai-system.md) §6's four boundaries |
| `approach` | `0x0040ADC0` | the approach cell over 10 targets, small mover and large |
| `helpers` | `0x0040B380`, `0x0040A6E0`, `0x0040B210`, `0x0040B250`, `0x0047A810` | the five order helpers, by record dumps either side |
| `fire` | `0x0040A440` | six shots; destructive, so the save is reloaded between probes |
| `plan` | `0x0040A750` | twelve probes, one per reachable kind and level |
| `special` | `0x0040B2D0` | the parabomb fuse pass, on `_C_141` with a type byte written |
| `turn_0`, `turn_2` | `aRefreshPlayer(255)` then `aAISystemControl` | **the whole computer turn**, twice: all 200 unit records field by field and `aRandom`'s seed either side |

`python3 tools/ai_gold.py --check gog_incubation` re-runs `inclib/ai.py` against
all of it — 45 checks — and needs no Wine.

## The band sweep, and why it writes into the weapon table

No shipped situation puts a resolvable hit chance one point either side of any
band boundary: the corpus's 210 pairs come nearest at 20/28, 48/52, 70/72 and
90/92, which `tools/ai_runtime.py`'s `band.boundary_windows` records. So the
`bands` phase makes the situation. It writes the weapon's *hit quote*
(`SetWeaponInfo + 0x30`), which moves `aGetHitProbability`'s answer and nothing
else the overlay reads — not a position, not a facing, not a line of sight —
then asks the engine for the chance and reads back the marker
`aBuildTargetOverlay` stamped on the target's cell.

**The column is put back at the end.** The weapon table is loaded once at
start-up and not per save, so a phase that left it written would poison every
phase after it in the same session — the reload between destructive probes does
not undo it.

## Re-taking a capture

```bash
cp -R gog_incubation/. /somewhere/outside/the/repo/
mkdir -p /somewhere/outside/the/repo/Work/Saves2
cp tests/fixtures/saves/_0_.sav _2_.sav _6_.sav /somewhere/outside/the/repo/Work/Saves2/
i686-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -municode -static \
    -o /somewhere/outside/the/repo/dbgcall.exe tools/dbgcall/dbgcall.cpp
python3 tools/ai_gold.py --game-copy /somewhere/outside/the/repo \
    --dbgcall /somewhere/outside/the/repo/dbgcall.exe
```

`ai_gold.py` **refuses a game directory inside this repository**, which is what
keeps `gog_incubation/` read-only. Phases are written as they land and merged
on re-run, so a bounded run loses at most the phase in flight — and Wine
start-up on this host is intermittent ([`docs/91`](../../../docs/91-wine-runtime-probes.md)
§1), so a phase can reach the anchor on attempt 1 or on attempt 8. **Do not
lower `--attempts` to bound a run**; bound the whole invocation with `timeout`
instead.

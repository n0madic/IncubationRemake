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
| `aRecomputeStats` | `0x004759B0` | that `+0x15` **is** written — the correction to [`docs/25`](../../../docs/25-turn-and-round.md) §5 |

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

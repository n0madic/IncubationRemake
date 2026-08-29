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

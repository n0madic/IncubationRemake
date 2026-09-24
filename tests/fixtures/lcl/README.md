# LCL replay cases

`cases_lcl.json` is **not a capture**. It is the executable model's own answers,
re-expressed for the GDScript side — the same arrangement
[`../turn/README.md`](../turn/README.md) describes for `cases_handover.json`,
and for the same reason: there is no native oracle for a whole mission program.
`tools/turn_gold.py` pins **one** invocation of `_C_141`'s `NEXT PLAYER` inside
the live engine (two `aRandom` draws, seed 1.0 → 847344462.0, no game-control
slot written, the world untouched), and that one pin is carried into
`cases_turn.json` and checked by `godot/tests/test_lcl.gd`. Everything else here
is Python-as-oracle.

Regenerate it with:

```bash
python3 tools/lcl_runtime.py --emit-cases tests/fixtures/lcl/cases_lcl.json \
    --root gog_incubation
```

It is gitignored: it embeds four missions' cell arrays and four parsed scripts,
all derived from Blue Byte data.

> The commit that created it added the file **and** the `.gitignore` line in one
> `git add -A`, and gitignore has no effect on an already-tracked path — so for
> fourteen commits this sentence was false and 560 KB of extracted retail data
> was tracked. `git rm --cached` fixed the tracking; the blob is still in the
> local history at `0bcf348`, and nothing has been pushed. Add the ignore rule
> **before** the first run that writes the file.

## What it holds

Four missions — the ones `tools/remake_convert.py` ships, because those are the
maps the cache has — each with:

* the **parsed script**, so the GDScript side reads the same instruction stream
  Python did rather than re-parsing anything;
* the **world it ran on**: the four cell arrays, the unit roster and the balance
  rows the script can reference -- since schema `/2` (2026-09-24) also each
  type's default weapon, the weapons' magazines and the control-map delays,
  because a spawn fills its magazine and tests the field it lands on
  (`docs/20` §7.4);
* the mission's authored `next_map`, which `LclWorld` starts from and which a
  replay beginning at `""` would disagree with on every case that does not call
  `EnterNameOfNextMap`;
* **30 cases**: six entry points (`docs/20` §5) times five `(turn, player)`
  settings.

Each case carries what the run produced: the outcome kind, line, step count and
dispatch count; the recorded events; the twelve game-control slots; the next
map; the turn-control byte; **both** generators' seeds and call counts; the
cells the run changed, as a delta; and the units it left behind.

## Three things this file is deliberate about

**The world travels with the cases.** The `.lev` a mission ships and the
`map.json` the converter writes are built from the same file but not from the
same *set* of records — `active_units` is "has a name" and the interpreter's
roster is "has hit points", and `_C_140` differs by two slots. A replay that
loaded the map from the cache and the expectations from here would compare two
worlds that disagree about the roster, and would report an interpreter bug that
is really a loading difference.

That same difference settled the spawn slot. "One past the highest key" gives 10
on one roster and 12 on the other, which are two different missions after the
first reinforcement; both implementations now take **the lowest slot in 0..199
holding no live unit**, and both say in their own docstring that the rule is
UNVERIFIED — `docs/20` §7.4 records everything `0x00479cf0` writes and not which
index it writes it to.

**Five turn settings, not one.** At turn 1 alone every case came back with an
empty cell delta and nothing to compare. `_C_140`'s `NEXT TURN` opens two tubes
on turn 4 (`EnvVarGreaterNum (_B,3)`) and its `NEXT PLAYER` inserts
reinforcements from turn 5, so the settings are what make the replay reach the
`InsertUnit` arm, the C runtime's generator and a spawn at all.

**The seed is 1.0 and not 0.** Zero is a fixed point in `aRandom`
(`inclib.rng`), so `SetVarRandom` would return its base on every draw and a
script that branches on one would take the same arm every time.

## What it does not hold

**The other 149 scripts.** The corpus-wide `N/N` stays in Python, where the
other 149 `.lev` files are: `tools/lcl_runtime.py --check gog_incubation` runs
every shipped script once per entry point and fails on an unknown command or
predicate. What this file proves is that the *transcription* agrees, not that
the corpus parses.

It found five wrong predicates on its first run. `UnitOnField`, `MechOnField`,
`NoUnitOnField` and `GroupOnField` take **cell coordinates** and ask what is
standing there; the transcription had them scanning the whole map.
`CheckCurrentTurn` is a range on the *turn number*, not a test on the current
player. All five were wrong in a way that reads correctly, which is exactly what
a diff against a second implementation is for and what no specification-side
check would have caught — the specification is what was misread.

**What the four missions happen not to contain.** `godot/tests/test_lcl.gd`'s
`synthetic.*` block covers those on hand-built programs: the locals' initial
`-1`, `SetVarVar`'s shipped bug, `SetActPt`'s byte mask, `GetUnitsInArea`'s
rectangle, the flag mechanics, the two abort paths and the `Goto` step cap.
Every one of them was added because a mutation of `LclInterpreter` survived the
replay.

# HUD fixture

`cases_hud.json` is written by

```bash
python3 tools/hud_tables.py --emit-cases tests/fixtures/hud/cases_hud.json --root gog_incubation
```

and read by `godot/tests/test_hud.gd`.  It is gitignored like every other
fixture here, because it carries measurements of Blue Byte's art: the element
sizes and anchors of twelve interface libraries and the geometry of
`plate_5.bmp` read off its pixels.

What it holds, and where each table comes from (`docs/43`):

* `overlay` -- the 100-byte state map at `0x00418EA8` and what each cell state
  blits (`mp1` digits, the hit bands `mp[43..47]`, the path frame `mp[51]`,
  the warp marker `mp1[17]`), the unit markers and the far-view flags, the
  zoom gate `0x17700` and the 100 ms blink period.
* `ring` -- the direction ring: dir -> `dir.LIB` element, the two colour tiers,
  the 600 px hit radius, the world offsets of the nine records, facing deltas
  and angles, the three ring modes.
* `pad` -- the 3x2 command pad's click rectangle, (column, row) -> command,
  command -> `ui.LIB` element, keys.
* `panel` -- the unit panel's origin (60, 415), its five blocks' offsets and
  the `uicons` elements they draw.
* `columns` -- the two button columns: rectangle, (column, row) -> interface
  event, event -> `mi.LIB` element, event -> `Txtmod_h` caption id, keys.
* `radar` -- the clip (501, 389, 90, 66), the centre, the scale (default 40,
  step 5, range 20..80, split at x 546), compass positions and sprites.
* `frame` -- the 3D window (60, 34, 520, 340), the four plate strips, the turn
  text position.
* `plate` -- the plate's size, the features measured from its pixels (pad
  sockets, button slots, turn window, panel inset, radar screen) and the ten
  segments the remake cuts it into.
* `libs` -- width, height and anchor of every element of `mp`, `mp1`, `dir`,
  `sm`, `ui`, `mi`, `uicons`, `map`, `mouse`, `inv`, `umun`, `uweapons`.
* `texts` -- the caption ids the interface asks `Txtmod_h` and `Txtmod_g` for.

`--emit-cases` refuses to write when any of the 122 checks fails, so a fixture
on disk is one the binary agreed with.  The suite fails when the file is
missing: `run_tests.sh` copies it into `godot/generated/hud/hud.json`.

## `hud_probe.json`

Written by

```bash
python3 tools/hud_probe.py --game-copy /path/to/copy \
    --dbgcall /path/to/copy/dbgcall.exe -o tests/fixtures/hud/hud_probe.json
python3 tools/hud_probe.py --check tests/fixtures/hud/hud_probe.json --root gog_incubation
```

and read by no suite: it is the native answer to `docs/43` open question 1,
the ground overlay `fcn.00417E70` stepped inside the live game into a private
surface, with the lit pixels of each phase kept so `--check` can decode them
against `mp.LIB` again.  Six phases: the marine unselected on both tick
phases, selected on both, and spent with and without overwatch.  Captured
2026-09-12 on `_6_.sav`.

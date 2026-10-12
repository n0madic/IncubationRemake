# First vertical slice — report

The slice of [`92` §10](92-remake-architecture.md) is complete. This file
records what was built, what each comparison is actually worth, the four things
the runtime evidence corrected in the specs, and the measurements that decide
what the next stage does not need to do.

It is a report on one piece of work, not a living document. The decisions it
promotes have been written into [`92`](92-remake-architecture.md); the open
items have been written into the numbered specs. What stays here is the
evidence and the reasoning.

---

## 1. What exists now

```
godot/                     Godot 4.7.1 project, warnings-as-errors
  core/     14 files       pure GDScript: no Node, no FileAccess, no singleton
  game/     10 files       cache loader, meshes, scenery, overlay, units, camera
  tests/    18 files       headless harness, 13 suites, 402 checks
tools/
  inclib/info.py           Info.lcl -> typed balance tables
  inclib/movemap.py        the executable model of aBuildMoveMap
  inclib/cache.py          manifest, staging, validation, atomic publish
  inclib/convert.py        mission -> portable data
  inclib/check.py          the shared N/N result collector
  info_parse.py            --check: 21 checks
  movemap_runtime.py       --check: 9 checks over 3726 fills, 155/155 missions
  remake_convert.py        --check: 35 checks; --check-cache: 9 checks
  movemap_gold.py          --check: 10 checks against the live engine
  verify_untouched.sh      the installation is byte-for-byte unchanged
tests/fixtures/movemap/    gitignored captures + a committed README
```

The path runs end to end: a read-only installation is converted into a
transactional `user://` cache, the cache is verified and loaded, `_C_115` is
drawn with its scenery and units, a click submits a movement query, and the
result is highlighted. Save, reload and the canonical hash close the loop.

### Running it

The converter is a CLI in this slice ([`92` §9](92-remake-architecture.md)
defers the Python packaging), so a first run is two commands: convert once,
then launch.

```bash
# 1. Convert the read-only installation into the production cache.
#    The output root is Godot's user directory for this project.
python3 tools/remake_convert.py gog_incubation \
    -o "$HOME/Library/Application Support/Godot/app_userdata/Incubation/caches"

# 2a. From the editor's binary, no export needed:
godot --path godot                              # the default mission
godot --path godot -- --mission=_C_141          # any mission in the cache

# 2b. Or from the exported build:
"godot/export/incubation-remake.app/Contents/MacOS/Incubation" -- --mission=_C_100
```

Without step 1 the game prints the command it needs rather than failing
silently. `--mission=` accepts any mission the manifest declares — the slice
converts `_C_115`, `_C_141` and `_C_100`, and `--missions=` on the converter
changes that list. `[` and `]` step between them at run time; the status line
lists what is available.

Controls: click a unit to see where it can go, shift-click to pass through
friendlies, `Q`/`E` rotate the camera in ninety-degree steps, `T` shows the
field-type overlay and `G` the editor's cell markers -- both **off** by
default, see section 10 -- and the zoom takes a wheel, a trackpad two-finger
scroll, a pinch, or `+`/`-`. Handling only the wheel was a bug: a macOS trackpad and a
Magic Mouse send [`InputEventPanGesture`], not `MOUSE_BUTTON_WHEEL_*`, so the
zoom looked dead on exactly the hardware this was written on.
`SliceMain.zoom_delta_for` is a pure function over the event precisely so that
`test_camera.gd` can check every device and direction without a scene tree.

The camera's far limit is the mission's own `camera_height`, and that number is
**not** decoration: raising it to frame the whole map puts the camera above the
ceiling of an interior level, which is presumably why `_C_141` sets it to 12 m
where `_C_115` sets 40 m.

`Q`/`E` turn the short way in both directions. The obvious implementation --
keep the yaw as a counter modulo four and tween to `step * 90` -- unwinds the
whole circle every time that counter wraps, and only on one step out of four,
which is why it survived being looked at. `CameraRig.short_way` picks the
representative of the target nearest the current heading instead, and
`test_camera.gd` checks that four presses are four equal quarter turns with no
travel in the wrong direction.

Two things to run when changing anything under `godot/`:

```bash
bash godot/run_tests.sh                                    # 13 suites, 402 checks
godot --headless --path godot --export-debug macOS export/incubation-remake.app
"godot/export/incubation-remake.app/Contents/MacOS/Incubation" --quit-after 20
```

The second is not ceremony. The shipping preset excludes `tests/`, so a
`class_name` from there used in `game/` stops that file compiling **only** in
the exported build — which happened once, to `game/main.gd`. It loads the test
runner by path now, and `test_isolation.gd` fails if any file under `game/` or
`core/` names a class declared under `tests/`.

---

## 2. Oracle boundaries, stated per comparison

[`92` §10.3](92-remake-architecture.md) item 1 asks that every comparison record
which boundary it reaches. Every suite prints its own; this is the summary.

| What is compared | Boundary | Evidence |
|---|---|---|
| `aRandom`, 64 draws + the raw seed | **native-runtime** | called in a live `Incubation.exe`; agrees with `blob_runtime.ARandom` |
| `aBuildMoveMap` on `_C_141`, 60 fills × 400 cells | **native-runtime** | called in a live `Incubation.exe`; `state`, `mp_left` and the scratch all agree |
| The move map on `_C_115`, 3 units × 2 flags | executable-Python | `inclib/movemap.py`, which the row above pins |
| 18 synthetic cases (obstacles, ladder, clearance, warp, the refusals) | executable-Python | the same reference; **no corpus can reach these** |
| The fill over the whole corpus, 3726 fills | verified-static | eight invariants over the authored `.lev` fields |
| The converted map against `lev_parse.as_dict` | verified-static | every field the two share |
| Scenery, unit and overlay counts and positions | specification-only | against the converted document |
| Isolation, saves, the cache loader, the warnings gate | specification-only | properties of this design, not of the original |

**The lead mission's reachability is rank 2, deliberately.** What is pinned
natively is the *algorithm*, on `_C_141`; what is compared on `_C_115` is the
Python reference's *result*. Lifting `_C_115` to rank 1 would mean driving the
campaign to the thirteenth mission of the other chain, and it is not on the
critical path. The upgrade is a `--poke` of the mission name.

---

## 3. What the live engine corrected

Four things were wrong or unstated, and only a call into the running game could
show it. Each is now in the spec it belongs to.

**1. `docs/23` §7.1 had two steps in the wrong order.** It writes the shield
refusal before the seeding of the start cell. With `cell[+0x10] = 3` written
into the mover's own cell, the engine returns an otherwise empty map whose
start cell holds state 10 and the mover's movement points — so the seeding
happens first. The `special` refusal really is first: it marks nothing.

**2. `docs/10` §4.5 lists five acceptance tests for the warp pass; there is a
sixth.** A cell the fill has already marked keeps its 10 — the warp pass does
not overwrite it. Thirteen cells across three captured warp runs show it.

**3. That sixth test is on `cell[+0x00]`, not on `cell[+0x0C]`.** Nine cells
were marked reachable with zero movement points left — which the fill's own
visited test cannot distinguish from unvisited — and they kept their 10 too.

**4. `docs/92` §2.1 was wrong about `aRandom`.** It called the generator
"easier in 64-bit, because the intermediate product fits". `seed * 62089911.0`
reaches 1.33 × 10¹⁷, past 2⁵³, so the rounding of the double multiply is part of
the sequence and an integer port produces a different stream. Sixty-four
agreeing draws *and* the agreeing raw seed settle the x87 question with it: the
shipped control word gives 53-bit significands, so IEEE doubles are equivalent
here.

### A finding from the corpus, not from the engine

**`pass_friendlies` is not monotone in reachability.** Two units in `_O_055`
reach cells *without* the flag that they cannot reach with it. The fill is
first-write-wins-except-zero, not a shortest-path search: a shorter route
through a friendly reaches an intermediate cell with zero movement points left,
where the longer way round would have arrived with one, and a cell with zero
cannot expand. The hypothesis was stated in the plan as corpus-decidable; the
corpus refuted it, and the counterexample is pinned in
`movemap_runtime.EXPECTED_PASS_FRIENDLIES_VIOLATIONS` rather than asserted away.

---

## 4. How the native capture is taken

This is the part of the slice with no precedent in the repository, so it is
worth stating in full. [`91` §3](91-wine-runtime-probes.md) established that
this Wine build's debug-exception transport is unsuitable for stopping inside a
loaded mission, and the direct-save patch route reaches a playable mission only
by resuming and detaching — after which nothing can call into the process.

The way through is neither:

* **The anchor is inside `aGameIntro`** (`Incubation.exe+0x4bd6f`). By then the
  front end has initialised and `Info.lcl` is loaded, but no screen has been
  built — and, unlike `aMainController` or the main-menu builder, it is reached
  *before* the start-up path this Wine build faults on. Breakpoints on the
  other two are never reached; this one is.
* **The mission is loaded by calling the game's own routines** — `aSetSaveMode(0)`
  then `aLoadGame(6)` — rather than by patching the controller dispatch. No
  `--poke`, no `--resume`, no patched executable, no human playing to reach the
  mission.

The control map then reads back identical to `_C_141.lev` in field type, height
and action point, and differs in exactly four unit links: the squad deploys onto
the action-point-1 cells after the load, which is why the capture feeds the
model the *live* state rather than the file's.

Branches the shipped campaign cannot exercise are reached by writing the field
the engine itself writes, through a three-byte injected `mov [ecx], dl; ret`
called as `__fastcall`, and restoring it afterwards. That is what gives a
**native** oracle to the warp pass, both `special` refusals and all three
transient obstacles — the plan expected all of these to stay synthetic-only.

Wine start-up on this host is intermittent, exactly as [`91` §1](91-wine-runtime-probes.md)
records, so the launcher retries; a run that never reaches the anchor is an
environment result and not evidence.

---

## 5. Measurements

Taken on an Apple M4 Max, Godot 4.7.1, `_C_115` (33 × 30 = 990 cells, 1074
scenery instances, 52 prototypes, 10 textures).

| Measurement | Value |
|---|---|
| Conversion, three missions and two world sets | **1.5 s** |
| Cache size | **1.34 MiB**, 30 files |
| Cache verification, full SHA-256 of every file | **8.7 ms** |
| Cache read + `World.create` | **11.4 ms** |
| Texture decode, 10 PNGs | 9.2 ms |
| Scenery build, 1074 instances over 52 meshes | 9.9 ms |
| Terrain overlay, 990 quads | 0.9 ms |
| **One complete move map, 990 cells** | **138 µs** |
| Canonical state hash | 40 µs |
| Save / load, 15.5 KiB | 157 µs / 457 µs |
| A complete AI turn | **does not exist yet** |

**What these decide.** A move map costs 138 µs. [`23` §2](23-ai-system.md)'s
worst case is two passes over six levels for up to 200 slots, so even a
pessimistic several-thousand fills is under a second of GDScript — and that is
on a 990-cell map, near the corpus maximum of 1600. **No memoisation, no
GDExtension and no native flood fill are justified**, which is what
[`92` §2](92-remake-architecture.md) hoped and could not yet claim. The
measurement to take next is the real AI turn, not this one again.

The full cache verification at 8.7 ms is why it runs on **every** load rather
than once: at that price, "a partial cache is never accepted" is a property and
not a promise about the happy path.

---

## 6. Exit criteria

All eight of [`92` §10.4](92-remake-architecture.md), demonstrated in an
exported build (`godot/export_presets.cfg`, preset *macOS Tests*, which runs the
same 402 checks inside the `.app` against the same `user://` cache).

| Criterion | How it is shown |
|---|---|
| The installation remains byte-for-byte untouched | `bash tools/verify_untouched.sh gog_incubation snap.txt [--check]` — `(path, size, mtime, sha256)` for every file, directory and symlink before and after; `git status` cannot show this because the tree is gitignored. The property is **nothing added or changed**, not "`Work/` is empty": `Work/` is the one place the game itself writes, so the player's own saves live there legitimately and the script lists them by name so a *new* one is obvious |
| Two conversions produce equivalent canonical data | `remake_convert.py --check` — two staging trees, byte-identical inventories and cache ids |
| A partial cache is never accepted, a valid one survives a failed update | `remake_convert.py --check-cache` (the writer) and `test_cache.gd` (the loader) |
| The rendered map, scenery and units agree with the inspection tools | `test_render.gd` and `test_mesh.gd` for the counts, positions and materials; by eye against `lev_parse.py --png` and `prototyp_parse.py --obj` for the picture — `--dev-fixtures` writes both into `godot/generated/inspect/` so the comparison needs no command line |
| Reachable cells and costs agree with their declared oracle | §2 above; every suite prints its own boundary |
| Save/load preserves the canonical hash, negatives fail cleanly | `test_save.gd` — round trip, plus truncated, unknown schema, wrong map and corrupted digest |
| `core` has no scene tree, rendering, audio, filesystem or singleton dependency, and `game` cannot mutate its arrays | `test_isolation.gd` — mutate a snapshot and re-hash; scan every `core/*.gd` for forbidden symbols |
| Typed GDScript warnings fail the build | `test_warnings_gate.gd` — a deliberately violating fixture must fail to load while its typed twin loads |

Two properties of the harness are worth keeping when it moves to gdUnit4: Godot
exits 0 even when the main script fails to load, so `run_tests.sh` gates on a
sentinel line rather than on the exit status; and a suite that ran **zero**
checks is a failure, for the same reason every `--check` CLI here fails on an
empty corpus.

---

## 7. Deliberate deviations from the plan

**gdUnit4 was not used.** [`92` §2](92-remake-architecture.md) named it. It is a
vendored third-party dependency in a repository whose stated discipline is zero
third-party dependencies and whose test suite is a set of `--check` CLIs.
`tests/harness.gd` is about 130 lines and does assert, report and exit code.
Moving to gdUnit4 later is mechanical.

**Warnings are errors project-wide, not only under `core/`.** Godot 4.7's
`debug/gdscript/warnings/directory_rules` can only *exclude* a directory; it
cannot give one a stricter level. Everything here is statically typed, so the
stricter reading costs nothing and satisfies the `core/`-only requirement a
fortiori.

**A `DictRead` helper exists in `core/`.** With `unsafe_call_argument` as an
error, `int(dictionary["k"])` does not compile — which is the point. The
narrowing from `Variant` is allowed in exactly one four-line file, so the place
a type is asserted is always visible.

---

## 8. What is not covered, and cannot be here

* **A Ladder cell.** No shipped cell in any of the 155 missions is field type 8,
  so the ladder-to-ladder step and the movement allowance it consumes are
  exercised only synthetically. The allowance formula (`0x00475160`) is an
  *input* to the fill in this slice, not something computed.
* **A large unit on the lead or capture mission.** The 3 × 3 clearance test is
  covered by the corpus check and by a synthetic case, not natively.
* **`draw_kind`.** [`31` §4.4](31-prototyp-geometry.md) recovers eleven
  rasteriser kinds — masked, additive, subtractive, two flat kinds, a
  half-dead distance switch. The slice draws everything opaque, so some
  surfaces look wrong. Recorded rather than tuned by eye.
* **Face triangulation** is a fan, which assumes each face is convex and planar.
  Faces carry three to eight indices. A bad fan is silent and looks like a
  modelling error, so `prototyp_parse.py --obj` remains the cross-check.
* **Unit bodies.** `SetUnitInfo`'s model column is a one-field ground marker for
  30 of the 36 rows; the living bodies come through Charisma's hard-wired switch
  ([`40` §7.2](40-charisma-model-animation.md)), which is outside the slice. The
  slice draws the real marker plus a capsule sized from the type's own height
  column.
* **Everything the plan excluded**: combat, line of sight and visibility, the AI
  turn, `aWalkMoveMap` and `aExecuteMove`, the turn and the round, LCL
  execution, interaction, the campaign layer, Charisma, the sequence player,
  sound, sprites and any HUD beyond the debug line, the localisation catalogue
  (the seam is respected — no user-facing literal in GDScript — but only
  converter and debug strings exist), multiplayer, importing original `.sav`,
  memoisation and GDExtension.

---

## 9. Open questions this slice leaves

1. **`aWalkMoveMap` is 8-connected while the fill is 4-connected**
   ([`23` §8](23-ai-system.md)). The slice highlights reachability and builds no
   path, so the asymmetry is recorded in `core/move_map.gd` rather than
   resolved. Whoever implements movement has to decide what the remake does
   about a path that leaves the highlighted region.
2. **The movement allowance (`0x00475160`) is an input, not a computation.** The
   equipment chain — Servo, Banner, Heavy Armor, FP, rested — is
   [`25`](25-turn-and-round.md)'s and is unimplemented. A free consistency check
   already exists in the data: five unplaced `Human Soldier (1)` slots in
   `_C_115` carry `action_points` 4 with `[Standard Armor, Servo System]` and 3
   without, which is exactly `mpMax + 1` for equipment 14.
3. **The four D00 missions whose header `clone_count` disagrees with their
   `.3DW`** ([`10` §6.1](10-lev-mission-format.md)). The converter places by the
   parsed `.3DW`, because that is what the engine parses, and writes the
   disagreement into the manifest as a warning. `Level04d` is not one of them,
   so the slice never exercises the warning path on real data.
4. **The campaign has two chains**, `_C_100`…`_C_133`→`_C_YYY` and
   `_C_140`…`_C_17x`, and the playable one starts at `_C_140` — not at `_C_100`,
   whose header carries mission id 1. Noticed while choosing the capture
   mission. [`27`](27-campaign.md) should say so if it does not.

---

## 10. Addendum, 2026-08-29 — four of the open items closed

This report is frozen above; this section records what happened to §8's and
§9's list afterwards, and where the evidence now lives. Nothing above was
rewritten.

### The ladder, and the movement allowance (§8 bullet 1, §9 item 2)

Both are now **native-runtime**, taken in the same capture session as the fill.

`tools/movemap_gold.py` gained a `cell_field_type` mutation, so a mover's own
cell and one neighbour can be turned into field type 8 in the live process and
the engine's own fill asked what the step costs. Six fills, over a 5000-unit
drop the climb rule blocks and over a flat pair, bracket it exactly: the step
leaves `mp - allowance` and needs `mp >= allowance`. [`23` §7.4](23-ai-system.md)
carries the table.

The allowance itself is no longer an input. `aGetMovePoints` (`0x00475160`) is
called 37 times under written equipment, fitness, rested and action-state
bytes, and the model in `tools/inclib/allowance.py` and `core/allowance.gd`
agrees with all 37. Three things the calls settled that reading the code alone
would not have:

* **The Banner reach is floor-Euclidean and strictly below four.** A carrier at
  `(+3, +3)` does not count, which Chebyshev would have made in range. One
  placement decided it.
* **The scan does not skip the carrier**, so a unit carrying its own Banner
  gets the bonus from itself.
* **The AI level is a real input.** `0x00460450` answered **0** in the captured
  session, which takes one off `mpMax` for unit type `0x32` only. A model
  defaulting to 1 disagreed with the engine on exactly one slot — which is how
  the branch was found rather than assumed away.

Over the corpus the computed allowance matches the saved `unit[+0x15]` on 1822
of 1863 placed units. The 41 that differ are two designer values the first turn
refresh would overwrite, pinned in
`movemap_runtime.EXPECTED_ALLOWANCE_OVERRIDES`.

### `draw_kind` (§8 bullet 3)

`game/mesh_builder.gd` implements [`31` §4.4](31-prototyp-geometry.md)'s
"consequences for a remake" table: one surface per `(draw_kind, texture)`, the
two flat kinds and the half-dead distance switch painting the face colour, the
masked kind scissoring a colour-keyed copy of its texture, additive and
subtractive blending for `0x1c` and `0x20`, depth writes off for the four
deferred kinds, and `0x28` emitting nothing at all. `test_mesh.gd` states each
of those as a property of the material.

The slice's own two world sets contain kinds `0x00`, `0x08`, `0x10`, `0x14` and
`0x1c` — so the masked and additive kinds were *already* being drawn opaque,
and the counts are pinned so a new kind is noticed.

**One deliberate deviation.** The original flushes deferred polygons in reverse
submission order; Godot sorts transparent surfaces by depth. Reproducing the
order would mean reproducing the BSP walk the cache flattens away, and depth
sorting is right more often than a fixed order is.

**Corrected 2026-09-02 — the faces are one-sided.** The slice's material
set `CULL_DISABLED`, a choice this report never recorded, and it was wrong:
[`31` §4.2](31-prototyp-geometry.md) now pins that Eng3d's leaf walker draws
a face only when the camera is on the side its plane normal points to, and
that the stored winding puts that side in front under Godot's clockwise
front face. `mesh_builder.gd` culls the back face, and the ear-clipper had
to become orientation-preserving to survive it: `Geometry2D.triangulate_polygon`
normalises the orientation of what it returns and the axis-drop projection
mirrors the outline for half the normals, so an ear could come back wound
against its face — harmless double-sided, a hole one-sided. `test_mesh.gd`
lays the reflex outline in all three planes, facing both ways, wound both
ways, and requires every triangle to follow the polygon's Newell normal, with
a check that the raw triangulation really does flip for some of the twelve.

### Face triangulation (§8 bullet 4)

The manual `--obj` cross-check is retired, and the answer was **not** the green
check it was expected to be. `prototyp_parse.py --check` now decides convexity
and planarity in exact integers over all 236 861 shipped faces:

* **1572 faces have a reflex corner** and 129 name a vertex twice; 700 more
  have no area. A fan is wrong on the first two groups.
* **81 of the reflex faces are in `World_A00`**, which two of the slice's three
  missions use — so this was not a theoretical defect.
* Exact planarity holds for only 144 877 of them, worst deviation 40 864 world
  units. That is *reported*, not gated: a span filler never asked for flatness,
  and a fan and an ear-clip cover the same silhouette either way.
* Faces carry three to **twenty-four** indices, not the three to eight §8 said.

`mesh_builder.gd` ear-clips in the plane of the Newell normal
(`Geometry2D.triangulate_polygon`), falling back to a fan only where no
triangulation exists. `test_mesh.gd` builds a reflex outline whose fan covers
14 square metres against a true area of 10, so the check fails on the old
behaviour.

### The 4/8 asymmetry (§9 item 1)

Resolved by transcribing `aWalkMoveMap` rather than by deciding a policy.
`core/walk_map.gd` and `inclib/movemap.walk` reproduce it; nine native walks on
`_C_141` agree on the return value, the step count, the blocked count and the
whole overlay, including the failure arm.

The question §9 actually asked — what a remake does about a path that leaves
the highlighted region — has a measured answer: **it does not happen.** Over
4587 paths reconstructed across the whole corpus, 2772 steps are diagonal and
**no path visits a cell the 4-connected fill did not mark**, because a cell the
walk can ascend to must carry movement points and only the fill writes those.
What does happen is the other case: asked for a target the fill never marked,
the ascent wanders between cells that all hold zero until the 300-step budget
is gone and returns FALSE. That arm is in the capture too. A remake therefore
has to refuse an unreachable target, which the highlight already expresses; it
does not have to reconcile two connectivities.

### What the code review found afterwards

A multi-agent review of the whole working tree ran after the four closures.
It reported **fifteen findings and six smaller notes; all twenty-one are
fixed**, each with a check behind it. The five that mattered most, because
four of them were silent:

**Two rendering bugs that no check could have caught, both introduced by the
draw-kind work or exposed by it.**

* `vertex_color_use_as_albedo` was set on *every* material while `_surface` set
  the face colour on textured faces too, so Godot multiplied the RGB565 field
  into the sampled texel. docs/31 §4.4 lists the textured kinds' shading as
  "none (decal)" — the engine never reads that field for them. `World_A00`'s
  textured faces carry `(123,125,123)` and `World_D00`'s `(74,76,74)`, so all
  textured scenery was rendering at 0.48× and 0.29× brightness, and a prototype
  whose colour field is `0x0000` — most of the corpus — would render black.
* `TerrainOverlay.TYPE_HUE` was `lev_parse.py`'s ramp **with its first four
  entries missing**, so every field type was painted as the type four along and
  the lookup wrapped at seven instead of eleven. The three converted missions
  hold only types 0, 1 and 2, so *every* overlay cell on *every* one of them was
  the wrong colour — which defeats the only thing the overlay is for, being
  eye-checkable against `lev_parse.py --png`.

**Two ways to lose data.** `cache.collect()` `rmtree`d every subdirectory of
its output root that was not the cache just published — no name pattern, no
manifest check — and nothing rejected `-o gog_incubation`. It now removes only
directories carrying one of its own manifests, and `refuse_unsafe_output`
declines the game installation and this repository outright. Separately,
`publish()` treated an existing `cache_id` as proof the same cache was already
there and discarded the freshly built tree. A first repair replaced the live
directory through two renames, but a process death between them left
`active.json` dangling. Cache ids now include both source and output inventory
digests, so published directories are immutable: changed bytes get a new name,
the new tree is installed with one rename, and publish → pointer → collection is
serialized by one inter-process lock.

**One field modelled twice.** `cell[+0x10]` was both a synthesised `_obstacle`
array *and* `_effect[2]`, which the converter fills from the same offset.
`set_obstacle` wrote only one of them, so a cell could report a mine and a 255
for one documented field, and the canonical hash committed both. `obstacle_at`
and `set_obstacle` are named views on effect slot 2 now, and the save format
lost a redundant `width * height` bytes.

The rest: a corpus check that logged the warp-cell and successful-walk totals
without asserting them (disabling the warp pass entirely still printed
`15/15 passed`); a missing suite file that printed one informational line and
still exited 0; freed scene handles surviving `_build`'s early failure return;
an "empty" move-map result that declared the map's size but carried zero-length
arrays; `run_tests.sh` never removing a stale fixture copy; unquoted Windows
paths in the capture's `cmd /c` line; a Wine timeout escaping the retry loop as
a traceback; a missing `scratch` dump silently defaulting to `False` and then
being asserted as engine ground truth; and `verify_untouched.sh` enumerating
only regular files, so a stray empty directory — the exact hazard CLAUDE.md
names it for — was invisible.

Every one of those now has a check behind it, and the count went from 755 to
774. Two of the new assertions were mutation-tested against the reviewer's own
scenarios: `WALK_BUDGET = 4` turns 4587 successful walks into 2664 and the
suite goes red, and flipping the walk's tie-break from `>=` to `>` moves the
diagonal count from 2772 to 2784 and it goes red again. Both used to pass.

**One guard is still uncovered** — mutation-tested in §11, still not covered by
the standing suite. `core/move_map.gd`'s wave-queue limit was an
`assert`, which Godot strips from an exported release build — the build this
document requires be launched after every change — so a wave of 2000 entries
would have truncated the overlay silently there while `inclib/movemap.py`
raises. It is an explicit `push_error` and an early return now, but nothing
exercises it: the largest wave the whole corpus produces is 49, and reaching
2000 needs a map about a thousand fields across.

### The first look at the picture

The eye-pass this addendum kept listing as pending finally happened, and it
found the thing no check was ever going to: **the two debug layers were on by
default**, so the mission was drawn as a grid of white dots under a coloured
film.

* The dots are `S003_00X.3DI`, the editor's cell marker -- an octagon 320 world
  units across, which the `.lev` carries as the height record's prototype and
  the original **never draws**. The slice built and showed them because
  "the rendered scenery agrees with the inspection tools" reads more honestly
  when the thing being compared is on screen.
* The film is [`TerrainOverlay`]: one translucent quad per cell, two
  centimetres above whatever geometry occupies that cell, coloured by field
  type with action points in amber. On a mission holding only field types 1 and
  2 that is a green wash over the floor with yellow patches on the action
  points -- which is exactly what it is *for*, and exactly wrong as a default.

Both are built as before -- `built_count()` still counts the lattice, so the
inspection-tool comparison is unaffected -- and both are now hidden until
asked for: `T` shows the overlay, `G` the cell markers. `test_render.gd` fails
if either comes back on by default. The movement highlight is a separate mesh
and was never affected.

### One thing this addendum fixed that was not on the list

`tests/` preferred `user://movemap/` over `res://generated/movemap/` when
looking for case files. A copy left in `user://` by an earlier session shadowed
the fresh one, the run silently lost fifty checks, and every suite still
reported "ok". The preference is inverted, and `harness.gd` now carries a
**minimum check count per suite** — the other half of the rule that a suite
running zero checks is a failure.

Counts at the close of this addendum: **16 suites, 775 checks**, in the editor
and in the exported build. (§11 carries them further.)

### Still open from §8 and §9

* ~~**The large-unit clearance natively.**~~ **— closed in §11**, by writing
  the `size` byte instead of finding a mission with a large unit. What follows
  is why it looked out of reach at the time. No unit on `_C_141` is large, and
  unlike the transient obstacles that is not reachable by writing one byte —
  the type's size column lives in `SetUnitInfo`, so it *is* a byte, but a
  three-by-three clearance also needs somewhere on the map that could satisfy
  it. Corpus and synthetic coverage only.
* **The four D00 missions whose `clone_count` disagrees with their `.3DW`**
  (§9 item 3) — unchanged; `Level04d` is not one of them.
* **The campaign's two chains** (§9 item 4) — recorded in
  [`27`](27-campaign.md) during the slice.
* ~~**The picture has not been looked at since the renderer changed.**~~
  **— done, and it looks right**: `_C_115` with `T` and `G` off, and both
  debug layers toggling as intended. What follows is why it was open. Exit
  criterion 4's automated half (`test_render.gd`, `test_mesh.gd`) passes and the
  shipping build starts on all three missions, but its *by eye* half is stale by
  construction: the masked and additive kinds occur in `A00` and `D00`, so those
  surfaces were being drawn wrong before and are now drawn differently. Nothing
  here can assert "looks right".
* **The deferred draw order is a deviation, not a fidelity claim.** The original
  flushes its transparent queue in reverse submission order; this sorts by
  depth. See §10 above for why.
* **Which difficulty the remake assumes is now a visible product parameter.**
  `World.submit_move_query` computes the allowance at
  `Allowance.DEFAULT_AI_LEVEL = 1`, and the captured session ran at 0. It
  changes the base allowance of exactly one unit type (`0x32`), the fixture path
  passes the captured level explicitly, and nothing in the slice picks a
  difficulty — but a campaign layer will have to.

---

## 11. Addendum, 2026-08-29 (second) — the clearance, the walk's charge, and the model bug they exposed

One capture session, two goals, and a third thing that was not on anyone's
list. Counts after it: **16 suites, 799 checks**, `movemap_gold --check`
**41/41** over 74 native fills.

### The 3 × 3 clearance is native (§10's first open item)

It was the last branch of the fill still standing on the disassembly alone, and
the reason given for leaving it there — no large unit on `_C_141`, and the nine
missions that place one are hours of play away — turned out to be the wrong
constraint. `size` is a byte in the shipped `SetUnitInfo` table
(`unitInfo[type] + 0x7B`, which `0x00430CA6` reads as
`byte [type*126 + 0x51C09B]`), so **the mover is made large rather than found
large**, exactly the way the ladder cell and the obstacle byte already were.
Nothing else the fill reads changes: the unit keeps its own movement points,
its `special` and its position.

Which slots to ask for was decided by the model *before* the Wine session, and
that mattered: a run where the test refuses nothing would have satisfied every
check and proved nothing. The planner scores each live slot by how many cells a
large mover loses **and** how many it keeps, and takes the discriminating ones.
Slot 2 at 8 movement points loses 69 and keeps 29.

Seven fills, and the result:

| | |
|---|---|
| cells refused to a large mover that a small one reaches | **232** |
| cells past the mover's own that still pass the test | **61** |
| conditions the mission's own geometry decides in isolation | height 159, occupancy 83, map edge 56, field type 27 |

The fifth condition — no fire — has no natural instance anywhere, since
`+0x10` is 255 in all 184162 shipped cells. It is reached by writing one fire
**diagonally** from a candidate: a diagonal neighbour is inside the clearance
ring but is never a cell the 4-connected fill steps through.

The first version of this compared the large fill with fire against the *small*
fill with fire, called the 94-cell gap the fire arm's doing, and would have
passed with the arm removed — the gap is the whole clearance test. The captured
runs are a 2 × 2 instead, `{large, small}` × `{fire, no fire}`, all four native,
and the arm is the difference of the differences:

| mover | no fire | fire | lost |
|---|---|---|---|
| large | 29 | 1 | **28** |
| small | 98 | 95 | 3 |

Three cells are the ordinary `to[+0x10] == 1` test and its cascade; the other
25 are the clearance ring's own fire condition. The check now fails if those
two losses are equal, which the earlier one could not.

### `aExecuteMove`'s half of the ladder rule (§10's last open item)

Carried as an opportunistic fourth phase, sequenced last, allowed to fail — it
animates, plays sound and runs the Charisma path, so it is the one plausible
hang. It succeeded, and the two halves of the engine **do** disagree:

| probe | field types | reported cost | `u->mp` after |
|---|---|---|---|
| ladder | 8 → 8 | 1 | 5, unchanged |
| control | 0 → 0 | 1 | 5, unchanged |

Against an allowance of 3. So a ladder step is *offered* at the price of a
whole turn's movement by `aBuildMoveMap` and *walked* for the price of one
field by `aExecuteMove`. [`26` §5](26-interaction.md) predicted this from three
field-type reads; it is now measured. The remake's choice stands unchanged —
the move map's rule — but it is now a choice between two measured behaviours.

Two things the same probes settled, both traps:

* **`aExecuteMove` reports the cost and does not spend it.** `u->mp` is
  untouched; [`23` §5.3](23-ai-system.md)'s tail subtracts, in the caller.
  A remake charging inside its own move routine would double-charge the AI path
  and leave the player's uncharged.
* Its arity is **eight**, read off `0x0040AC43`'s `add esp, 0x20`, with the
  cost coming back through argument 5.

### The thing that was not on the list: `anyFriendlyBlocked` is a constant

The wider fills the clearance work added exposed a disagreement in one of 72
runs — and the model was wrong, not the check. The direction loop runs
**`dir = 0…7`** (`0x00430DC8` is `cmp eax, 7`), not 0…3. The last four are the
diagonals `Step` refuses, so they reach no cell — which is why a 4-connected
fill is right about *cells* — but a refused `Step` takes the caller to
`0x00430C64`, **which writes the scratch flag**. Every cell the fill examines
therefore ends by clearing it.

> The flag is FALSE after any fill that ran a single wave. TRUE survives only
> from the write at `0x00430A84`, before the loop.

Measured: TRUE on exactly the 26 of 74 fills whose mover had no movement
points, FALSE on all 48 that ran a wave. A second, smaller error came out of
the same disassembly — the enemy arm at `0x00430C60` clears `ok` and **leaves
the flag alone**, where both the doc and the model had it writing FALSE.

Both are fixed in `inclib/movemap.py` and `core/move_map.gd`, and
[`23` §7.6](23-ai-system.md) is new. The correction changes no cell in any of
the 3726 corpus fills — only the flag — which is precisely why it survived: the
4-direction transcription agreed with the engine on 71 of the 72 captured fills by
luck, and nothing but a wider fill than the capture had ever held would have
caught it.

**A remake must not give the flag a meaning.** It is reproduced bit for bit
because reproducing a constant is cheaper than auditing six call sites for
whether any reads it back.

### The wave-queue guard, exercised by mutation (§10's uncovered guard)

Not coverable by data — the largest wave the corpus produces is 49 and reaching
2000 needs a map about a thousand fields across — so it is mutation-tested once
and recorded here rather than given a test seam:

| side | `QUEUE_HARD_LIMIT` | result |
|---|---|---|
| `inclib/movemap.py` | 4 | 2519 of 3726 fills raise `MoveMapError`, `--check` 11/17, exit 1 |
| `core/move_map.gd` | 4 | 111 failures, 799 → 736 checks, `HARNESS-RESULT: FAILED` |

Both are green again at 2000, and both numbers are against the suite as it
stands after the review below — the first pair was measured before it and is
not what a reader would reproduce. The honest state is *exercised once by
mutation, not covered by the standing suite* — which is better than the *nothing
exercises it* §10 recorded, and is as far as it goes.

### One tooling failure worth recording

The first capture attempt reported the anchor as unreachable ten times in a row
while never having started the target. A Wine update made `cd /d` return a
non-zero exit status even where it works, so the launcher's
`cmd /c 'cd /d "<copy>" && "<dbgcall>" … > log'` short-circuited: no log, no
breakpoint line, and a retry loop confidently reporting the wrong thing. The
fix removes the shell path handling entirely — the working directory is set
from the Unix side, and every name in the command line is a bare filename.
[`91` §1](91-wine-runtime-probes.md) records it, along with the two neighbouring
traps: this `cmd` will not run a **quoted** absolute path, and
`wine explorer /desktop=` detaches the console, which is why the `cmd` wrapper
has to be there at all.

A second, self-inflicted one: phase 4 crashed the whole run on a `§` in a plan
comment, because plans are written as ASCII — and it took phases 1–3 with it,
which was the exact outcome running it last was supposed to prevent. Its guard
now catches every exception, not just `CaptureError`, and it retries as many
times as every other phase: the failure that actually occurs is the intermittent
start-up fault, which costs seconds and wants retrying, while the hang it was
being protected from is already bounded by a timeout.

### What the review found afterwards

A multi-agent review of the working tree ran after the above. **Thirteen
findings, all fixed.** Three mattered, and two of the three are the same shape
as the `anyFriendlyBlocked` bug: a check reporting green on data it never
examined.

**One way to lose data, in the function next to the one this slice hardened
against exactly that.** `remake_convert.py --dev-fixtures` `rmtree`d
`<out>/cache` and `<out>/inspect` by name, with no ownership test — the very
thing `cache.collect()` had just been fixed for, one function over.
Reproduced: a pre-existing `devfix/cache/notes.txt` and
`devfix/inspect/photo.txt` were both gone afterwards, silently. Both
directories now carry an ownership marker (the cache its manifest, the eye
fixtures an explicit one), the refusal happens **before** the conversion rather
than after it, and an empty directory made by hand is still taken over so the
first run works. Four new checks in `--check-cache`, mutation-tested: reverting
to the unguarded `rmtree` turns them red.

**Two false certifications in the capture's own coverage checks.**

* `coverage.obstacle` asserted which obstacle *values* appeared in the plan,
  never that any run's outcome differed. The obstacle runs computed the target
  neighbour once, for the *first* mover, then issued the fill for each mover in
  turn — so the alien's mine was written beside somebody else's unit and its
  fill never met it. **Deleting the `player != 255` exemption from the model
  left the capture at 36/36.** Control: deleting the mine rule outright gave
  34/36, so the mine arm itself was covered and only the exemption — the sole
  reason docs/23 §7.1 makes the owner matter — was not. The neighbour is
  per-mover now, and the checks assert the outcome: `mine.alien_passes`,
  `mine.stops`, `fire.stops` for both owners.
* `coverage.hidden` asserted that a unit with `visibility == 3` existed in the
  roster. That is a fact about the save, not about any fill, and no captured
  fill went near it: **making hidden units block like any other still gave
  36/36**, with the report still printing "the visibility-3 branch is native".
  The planner now picks a mover that can reach a hidden unit's cell and the
  check requires the engine to have marked that cell.

Both mutations now fail. The rest, in one line each: the fill's occupancy
lookup crashed on a cell naming a slot the roster does not hold, where the
engine's own answer (`0x00430C3C`) is to skip the neighbour — transcribed on
both sides, unreachable on shipped data; `verify_untouched.sh` treated any
unrecognised third argument as "take a snapshot", so a typo'd `-check`
overwrote the baseline **and** exited 0; `prototyp_parse.py`'s shape partition
was three sets that were never disjoint by construction and failed with no line
naming the face; `prototyp.py` still said faces carry three to eight indices
against a corpus maximum of 24; `cache_loader.gd` crashed on an `active.json`
that parsed but carried no `cache_id`; `save_codec.gd` hashed an empty body and
made a clean refusal print engine errors; `movemap_runtime.py` derived an
expected count from `fills // 2` rather than counting what it checked; the
capture's phase-1 planning used a hard-coded AI level of 1 where the engine
answers 0; the `aExecuteMove` control step was never constrained to the
ladder's base delay; and a documented `--normalise` mode did all its work and
then raised unconditionally.

Counts after the review: **16 suites, 799 checks**, `movemap_gold --check`
**41/41** over 74 native fills, `--check-cache` 29, `movemap_runtime --check`
18.

### Still open after this

* **The three items §10 left open that this did not touch**: the deferred draw
  order, the difficulty default, and the four D00 `clone_count` mismatches.
  §10's fourth, the by-eye half of exit criterion 4, has since been done and
  passed — `_C_115` with the two debug layers off, and both toggling correctly.
  The draw order sharpened, though: of the kinds the corpus contains, only
  `0x0C` (50 % blend) is order-dependent at all — additive and subtractive
  commute — and while `0x0C` is present in every world-set container (112 faces
  each), it sits on the Charisma models' muzzle markers (the part `M`, a
  one-face black triangle -- *corrected 2026-10-12: this said "shadow quads";
  all 85 `M` parts of the cache's 103 models are that triangle, 0.002 to
  0.16 m across at the weapon's muzzle, [`92` §7.29](92-remake-architecture.md)*)
  and the `A_CROSS*` aim markers, none of which is inside any converted
  mission's closure. The cache
  carries none. Revisit when Charisma models or the aim markers are converted.
* **`_C_115` is still not native.** Reachability on the lead mission is
  compared against the executable model, which this capture pins. Unchanged.

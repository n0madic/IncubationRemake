# Slice 4 — bodies that move

**What this slice set out to do:** give the remake's units Charisma bodies that
stand, walk and shoot; play `_C_140` with them in an exported build; and
measure what a full roster costs per frame.

**What it did:** all of that, plus three corrections to a delivered
specification and one measurement nothing in the repository had written down.

Three slices closed the *rules*. [`93`](93-slice-1-report.md) the map, the fill
and the path; [`94`](94-slice-2-report.md) the turn, fog, combat, reaction,
interaction and the mission script; [`95`](95-slice-3-report.md) the AI
planner. What the remake had no part of was **bodies**: a unit was the genuine
ground-marker quad plus a capsule tinted by player, and the computer's turn
moved nothing on screen but the camera.

---

## 1. What was already there, and was not rewritten

Format research on Charisma was **complete** before this slice: `.cho` and
`.cha` parse 237/237 and 245/245 byte-exact, the quaternion convention is
settled two ways ([`40` §6.1](40-charisma-model-animation.md)), and
`tools/cho_export.py` already posed a skeleton and drew it. The mesh a part
names already resolved through `prototyp.bin`, and `MeshBuilder` already built
one.

So the slice is mostly *binding*: what body does a unit get, what clip plays,
and in what units are the two expressed.

## 2. The four selectors, read by running them

A unit's model and its three gameplay animations come from four sibling
routines in `Incubation.exe` ([`40` §7.2](40-charisma-model-animation.md)).
They are `switch` cascades whose arms are `mov edi, <literal>` followed by an
inline `strcpy`, so the names exist only as the union of the reachable arms —
there is no table to walk.

`tools/inclib/charisma_tables.py` is therefore a **bounded interpreter** over
exactly the instruction forms MSVC emitted for them, with an unknown opcode a
hard error rather than a shorter table. The domain is small enough to
enumerate outright: 70 unit types × 49 weapons × 7 player values.

### 2.1 Three corrections to `docs/40`

| Correction | Consequence if believed as written |
|---|---|
| The model selector `0x0042D070` is **three-level** — type, weapon *and* player | Read as two levels it yields 26 names where the engine registers **104**; every unit of players 1–3 would wear player 0's skin |
| The idle selector has a **randomised arm** (`0x0042DF77`: `frand(0, 10)` against the `5.0` at `0x004B1380`) | The unexplained "`S0` (+ `P4_S1_000`, `PC_F1_011`)" stays unexplained, and a remake picks one name for a coin toss |
| The model filename grammar of §7.1 is too narrow | `PC_ArmL_011` and `PC_ArmR_011` are shipped models it does not match; a registry scan finds 102 of 104 and looks complete |

The hero (unit type `0x17`) is drawn as **type 0 in player 1's colours**, and
the neutral player `0xFC` gets no body at all — which is why `_C_140`'s two
barrels are the capsule fallback and not an omission.

### 2.2 The oracle: two readings that share no code

The strongest check available without running the game is that the enumerated
sets equal, *exactly*, what `fcn.00407e90` registers eagerly at start-up:

```
model selector  -> 104 names   ==   104 aCreateCHModelDescriptor literals
idle selector   ->  30 names   ==    30 aCreateCHAnimationDescriptor literals
```

Name for name, both directions. The interpreter and the registry scan have no
code in common.

### 2.3 Animation coverage is not total, and that is data

Nine unit types get fewer than three families and two get none — the Norc'Yn's
detachable arms, which fits [`40` §6](40-charisma-model-animation.md): a limb
aimed by an `External*Movement` is driven by the game writing a matrix, not by
a clip. The Spider walks with no idle and no fire.

The converter therefore writes an explicit `null` rather than omitting the key,
so a runtime can tell "the engine plays nothing here" from "the converter
dropped it". That distinction was not theoretical: the first draft used
`get("name", "")`, which returns **null** when the key is present with a null
value, and player `0xFC` — the first unit built on `_C_140` — took it straight
to a type error the moment a body was first drawn.

## 3. The finding: bone translations are in 1/16 of a world unit

`docs/40` never states the skeleton's unit relative to the geometry's, and the
two differ. `P0_000`'s **whole skeleton** spans 171 units in z; one of its
torso meshes is 536 units tall. Assembled as they stand, a marine is a 10 cm
pile of 30 cm parts.

Nothing else in the pipeline could have said so. The pose diff passes — both
implementations compute the same skeleton — and each mesh is individually
correct. The mismatch exists only where the two meet.

The factor is measured off the one thing that must be true of a standing
figure, its lowest vertex touching the ground:

| Model | Lowest vertex at scale 16 | Height |
|---|---|---|
| `P0_000` | −0.07 world units | 1.91 m |
| `P0_003` | −0.07 | 1.83 m |
| `P1_000` | −0.07 | 1.91 m |
| `P1_003` | −0.07 | 1.83 m |

−0.07 world units is 0.04 mm, from four independent models, against a
height column implying 1.8 m ([`21` §5](21-info-lcl-schema.md)). Solving for
the scale directly gives **16.01**. The neighbouring integers 15 and 17 miss by
6.6 units, so the value is determined rather than plausible — and the check
requires them to fail, because a 1-unit tolerance against a 3000-unit body
would otherwise accept anything close.

16 is `1 << 4`, the same fixed-point shift [`30`
§2.5](30-eng3d-ascii-formats.md) records for `.3DW` positions.

**Where the engine applies it is UNVERIFIED.** It is not `StdModel`'s scale —
§6.2 shows that defaults to `(1, 1, 1)` and no shipped file changes it — so it
lives in the Charisma-to-Eng3d bridge, which is not decompiled. The number is
verified; its origin is not.

## 4. The oracle boundary, fixed downwards and on purpose

There is **no native oracle for animation**, and the reason is structural:

* `tools/wine_visn/` works because VISN lives in `Eng3d.dll` and is *exported*.
  `Eng3d.dll` has 89 exports and every one is an `E3D_*` renderer entry point —
  no `V100`, no skeleton, no animation. Charisma is statically linked into
  `Incubation.exe`;
* `tools/dbgcall/` reaches code inside a live process, but `V100Part::Update`
  (`0x004A6807`) takes a constructed part with a loaded descriptor and a bound
  movement — pointers, not values. Standing one up is most of a loader.

So the boundary is **rank 2, executable Python** ([`92` §5](92-remake-architecture.md)):
`tools/inclib/pose.py` is the reference and the GDScript sampler is diffed
against it, bone by bone, over all 311 `(model, clip)` pairings the selectors
can produce — 34 010 bone positions across 898 frames, plus every bone's full
local matrix at one frame per pair.

What keeps that honest is that `inclib/pose.py` is not a fresh transcription.
It is the model that draws `tools/out/skeletons/*.png`, the four contact sheets
that are the by-eye proof of [`40` §§5.2, 6](40-charisma-model-animation.md),
and it produced them **byte-identically** before and after being lifted out of
`tools/cho_export.py`.

### 4.1 The tolerance, and two wrong answers on the way to it

| Attempt | Result | What it actually meant |
|---|---|---|
| flat **1e-4** | failed at 1.2e-4 | a real disagreement, and it was the remake's: the sampler returned `PackedFloat32Array`, rounding every intermediate quaternion while Python kept doubles. The original ran on an x87 FPU with 80-bit intermediates. Widening cut it ninefold |
| **relative** bound | failed at 2.1e-5 | measured on a joint coordinate of magnitude 0.0102 inside a body spanning ~10 000 units. That is cancellation, not error — a relative bound measures the wrong thing here |
| flat **1e-3 engine units** | passes | 0.6 micrometres of body |

The bound is four to six orders of magnitude below every error it exists to
catch, and the mutation battery **measures** each one rather than asserting it:

| Mutation | Worst joint displacement |
|---|---|
| `(w, x, y, z)` component order | 1374 units |
| `quat_to_matrix` transposed | 878 units |
| bind translation added on the top-level bone | 126 units (`P0_000`'s root: z 29 → 129, exactly as §6.2 predicts) |
| 0.25-frame hold rule dropped | 119 units |
| hold rule picking the wrong key | 2.7 units |
| `slerp` where the engine uses `squad` | 0.67 units |
| textbook `log`/`exp` (`|v|` instead of `s`) | 0.0094 units |

Even the smallest — the non-textbook logarithm §4.4 warns "still looks right" —
is nine times the tolerance.

### 4.2 The fixture had to be made to test what it claimed

The battery found that **disabling the hold rule changed nothing five evenly
spaced frames could see**, even though 5.2 % of the corpus' segments are
0.25 frames long. A 0.25-frame window inside a 60-frame clip is missed by five
samples essentially always.

The emitter now probes *inside* short segments at `u = 0.5` and `u = 0.75`;
194 of the 311 cases carry one, and both halves of the rule are caught.

A second run of the battery, serially and with `tools/**/__pycache__` cleared,
found two more gaps and both are closed: `inclib.pose.EPS` could be set to 1e-9
with every Python check still green — the Python side was resting on a fixture
it generates itself — and `charisma_cache.f32_bits`, the single-value
encoding, had no check at all.

## 5. The cache

| Document | Contents |
|---|---|
| `tables/charisma.json` | the four decision tables, narrowed to the missions' closure — 24.5 KB, with explicit nulls |
| `models/<name>.json` | parts and the bind pose |
| `animations/<name>.json` | notes and tracks |
| `geometry/units.json` | the unit meshes, **once**, with textures named rather than numbered |

**The no-float rule is extended, not weakened.** [`92` §3.2](92-remake-architecture.md)
is categorical that the cache holds no float; bind matrices and animation keys
genuinely are `f32`. They reach the cache as their own IEEE-754 **bit
patterns** — a `u32` for a single value so a document stays greppable, base64 of
little-endian `f32` for an array. No float is ever formatted, which is the
invariant the rule wanted. The round trip is exact by construction and checked:
290 419 key floats recovered bit for bit.

**The closure is `(type, player)` × *every* weapon**, over placed and unplaced
units alike. A unit's model changes with its weapon — a marine has 16 bodies —
and the weapon byte is written mid-mission by scripts and by
`aToggleWeaponModes`, so closing over the default alone would work until the
first toggle. Unplaced units count because reinforcements are exactly the
bodies that appear later. It costs about 25 KB of table.

**Unit geometry is emitted once, not nine times.** A body is the same mesh in
every world set but a texture *id* is not — `caan0000` is 7 in `A00` and 8 in
`E00` — so the shared document names its textures and each set resolves the
name to its own id. The converter re-parses every emitted mesh from the other
eight sets and compares with the ids masked, because it is the claim the saving
rests on.

**Tracks with no matching part are kept.** [`40` §7](40-charisma-model-animation.md)
measures 17 across the gameplay set. Ignoring them is a *runtime* rule;
stripping them in the converter would mean the exported build never takes that
path on shipped data.

## 6. `core`'s only change

`AIEvent`'s `move` payload gains **`path`**: the cells the walk actually
entered, source first, truncated where it stopped rather than where it was
planned to. `game/ai_playback.gd` had already written the reason on itself —

> a playback that read the world *after* the turn would show the end of it at
> every step, so every event carries what it needs

— and a body cannot walk a route it does not have.

`route` is deliberately **not** in `MoveResult.to_dict()` /
`ExecuteResult.to_dict()`. That document is pinned by
`tests/fixtures/movemap/cases_native.json`, which the engine emitted and which
cannot grow a field the engine never had. The player's own move needs no
contract change at all: `World.submit_move` returns the object.

**The slice's second acceptance criterion was measured, not argued.**
`_C_140`'s canonical hash is
`50d33fa7a150fc13f36256266ad1f3f89d09cd994b7d05f500c51760a2b81fe9` and
`SaveCodec.SCHEMA_VERSION` is 6 — *identical* with `godot/core/` at this commit
and with it reverted.

## 7. Measurements

Taken at the end of S6, **before** the state machine existed, so that the
plan's cut list was still usable if the numbers said so. They did not.

| Mission | Bodies | Parts | Build | Frame | Headroom at 60 Hz |
|---|---|---|---|---|---|
| `_C_140` | 8 | 140 | 7.2 ms total, 0.90 ms each | **2.39 ms** | 7.0× |
| `_C_132` | 40 | 394 | 7.2 ms total, 0.18 ms each | **6.25 ms** | 2.7× |

The library opens in 42 ms. Cost tracks **parts**, not bodies — 17 and 16
microseconds per part per frame — and it is the pose arithmetic in GDScript,
not the node updates.

**That answers the question `docs/92` has asked at every slice.** A
`Skeleton3D` with skinning would not help: there are no skin weights in this
format — a part is rigidly attached to one bone — and the cost is in computing
the pose, which is paid either way. If it ever matters the lever is *how often*
a pose is computed, not how it is applied. Nothing is optimised now, because
2.7× is not a problem to solve.

| Cache | Before | After |
|---|---|---|
| Published size | ~4.3 MiB | **7.4 MiB** |
| Bodies and clips | — | 2.87 MiB against an 8 MiB ceiling the checks enforce |
| Conversion, 5 missions | ~4 s | **5.1 s** |

## 8. Decisions, recorded as decisions

* **30 fps** (`CharismaState.FRAMES_PER_SECOND`). [`40`
  §4.8](40-charisma-model-animation.md) proves 30 fps for cutscenes and proves
  that gameplay advanced one key-time unit per *rendered* frame under a cap
  whose epoch handling doubled it. There is no number to recover.
* **0.16 s per map field walked.** The master clock is still
  `AIPlayback.STEP_SECONDS`; a walk is told how long it has.
* **`M` loops while a unit walks; `S` resumes when nothing else plays.**
  §7.2 marks the playback set-up of `kind` 0 and `kind` 4 UNVERIFIED. `kind ==
  4` and its literal `P0_M2_000` are not implemented at all.
* **The view opens on one unit's cell at 8 m**, not the map centre at the
  authored maximum — which on `_C_140` is inside a support column and above the
  level's roof. See [`92` §7.5.1](92-remake-architecture.md).

## 9. The game fonts, and one trap in them

[`60` §5](60-lib-sprites.md)'s four bitmap fonts are converted and the HUD
draws in `font_2`, the 17 px one. The cache carries an atlas PNG and per-glyph
metrics — 12 KB of image and 64 KB of JSON for all four — and `game/` builds a
Godot `FontFile` from them. Not a `.fnt`: `FontFile.load_bitmap_font` would be
less code and would put another engine's format inside the converted data,
which [`92` §3.2](92-remake-architecture.md) is against.

**The trap is that a glyph's pixels are palette indices, not intensities.**
`font_2` uses only the values 0, 1 and 2, so the obvious `alpha = value / 255`
renders the whole font at 1 % opacity. Everything else still passes: the font
builds, reports 224 glyphs, `has_char` is true for every letter and
`get_string_size("Incubation")` returns a sensible 71 × 20 px. Nothing appears
on screen. Only a screenshot found it, so the suite now asserts that the built
atlas has **ink** — some texel fully opaque — and that assertion fails on the
mutant that reintroduces the bug.

`tools/font_render.py` had documented the same trap in a comment ("using the
raw index as a grey level would render most glyphs near-black") and it was
still walked into. The two non-zero indices are kept in the cache, so a later
slice that establishes what index 2 means — an outline, most likely — needs no
reconversion.

Deliberately absent: cutscenes and the sequence player
([`41`](41-sequence-player.md)), sound and effects
([`28`](28-effects-and-sound.md)), the campaign layer
([`27`](27-campaign.md)), the `J` animation family (no code path references
it), and animation blending (`weight` is written and never read,
[`40` §4.10](40-charisma-model-animation.md)).

## 10. Verification

| Criterion | Result |
|---|---|
| Installation untouched | `verify_untouched.sh`: 1989 entries identical; `Work/` holds only the user's own saves, unchanged |
| `core` delta is the route alone | canonical hash and `SCHEMA_VERSION` identical with `core/` reverted — measured, §6 |
| Every returnable name resolves | 104 models + 91 animations, `N/N`; fails on an empty corpus |
| Pose agrees with Python | 34 010 bone positions, 898 frames, 311 pairings, worst delta inside 1e-3 engine units |
| Every unit type gets a body or a named refusal | 36/36; `_C_140` refuses only its two player-`0xFC` barrels, as the engine does |
| A track with no part is ignored | kept in the cache and counted by the suite, on shipped data |
| `_C_140` plays with bodies | 8 of 10 units bodied, 13–23 parts each; idle, walk and fire drive them |
| Cache size and conversion time | 2.87 MiB of bodies against an 8 MiB ceiling; 5.1 s |
| `core` isolation and typed warnings | unchanged; the warnings gate found `game/charisma/` on its own and rejected four files until every `Variant` cast was typed |
| Game fonts | four converted, 4 × 224 glyphs, descents matching `docs/60` §5 including its space/NBSP exception; the HUD draws in `font_2` |
| Mutation battery | 7 pose + 4 state-machine + 2 font + 9 Python mutants; the three survivors are closed and re-checked |

Regression, all green: the 38-command always-run block,
`bash tools/dbgcall/selftest.sh`, the four-command `docs/40` §12 gate, and
**27 suites, 1588 checks, 0 failures** with `remake_convert --check` at
101/101. The shipping build exports and runs
`_C_140` with no script errors.

## 11. Open questions

None opened by this slice. One is **narrowed**:

* [`40` §11 item 5](40-charisma-model-animation.md), whether the engine applies
  the root `SkeletonNode`'s own matrix, remains open — `0x004842A2` is dead
  code and the pose diff cannot discriminate it, because both implementations
  follow the same rule. It is now bounded by evidence rather than by argument:
  §3's four models stand on the ground to within 0.04 mm under the rule
  `cho_export.py` uses, and a different disposition of the root matrix would
  move the whole figure.

One is **added** to §5.3 rather than to the open list, because it is a number
that is verified with an origin that is not: **where** the engine applies the
16× bone-to-mesh scale. It is not `StdModel`'s scale, so it is in the
Charisma-to-Eng3d bridge, which is not decompiled.

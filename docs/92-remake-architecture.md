# Remake architecture — decisions taken

This repository is groundwork for a remake. This file records the decisions
that have been taken about the remake itself, with the reasoning, so they are
not re-argued from scratch; and what is still open, so it is not forgotten.
§7 is where the numbered specs point when a finding leaves a choice behind.

It is a **living file**, and it is not a specification: nothing here describes
the original game. Everything that does lives in the numbered specs, and this
file only cites them.

---

## 1. Engine — **Godot 4**

Chosen for reasons specific to this project rather than for being the strongest
open-source 3D engine in general.

**The asset pipeline is already most of the way there.** `lib_extract.py` emits
PNG, `visn_decode.py` emits PNG, `prototyp_parse.py --obj` emits geometry,
`cho_export.py` poses skeletons. The distance from what `tools/` produces today
to something rendering in Godot is short in a way it is not for any other
candidate.

**Charisma maps onto Godot's animation model directly.** A `.cho` is a part
hierarchy and a skeleton, a `.cha` is quaternion tracks whose bone names match
the part names ([`40`](40-charisma-model-animation.md)). That is a skinned mesh
plus an `Animation` with rotation tracks, with no impedance mismatch.

**The editor is worth more here than usual.** The first real task is checking a
converted 40×40 grid with heights, its placed scenery and 200 unit slots against
`lev_parse.py --map`. Doing that by eye in a scene view is the difference
between a week and a month.

**Godot's weak spots do not apply.** A turn-based tactical game on a grid of at
most 1600 cells needs no physics, no simulation determinism at frame rate, no
streaming world and no advanced rendering. The original targeted a Pentium.

MIT, no royalties, exports to Windows, Linux and macOS.

**Rejected, and why:** *Bevy* — code-first Rust with an ECS that would suit the
200-unit loop, but no editor, breaking changes every 0.x release, and the whole
asset pipeline hand-built; months not spent on the game. *Fyrox* — has an
editor and is Rust, but the community and documentation are small enough that
any unusual problem is faced alone. *raylib* — a library, not an engine;
choosing it turns the project from a remake into a reimplementation, roughly
tripling the work. *Unreal, Unity, Flax, Defold* — none is open source in the
strict sense, which was a hard requirement.

---

## 2. Language — **GDScript for the game logic**

An earlier draft of this argument led with engine portability. That is not a
real benefit here and is not the reason for anything below.

Three arguments genuinely favour a separate language, and none of them pays for
the cost of two toolchains in a one-person project:

1. **AI performance.** [`23` §2](23-ai-system.md): two passes, six levels, 200
   unit slots, and a move-map flood fill over up to 1600 cells per action. The
   worst case is millions of cell operations per computer turn. That is small
   enough to implement and measure in statically-typed GDScript before adding a
   second language. Memoisation is an available optimisation, not part of the
   initial design: the keys and invalidation rules depend on occupancy, doors,
   terrain state, the acting unit and the movement query's flags, so a stale
   cache is a larger risk than recomputing 1600 cells.
2. **Testing outside the engine.** Weaker than it looks: `godot --headless` with
   gdUnit4 in CI keeps the whole discipline — 100 % corpus coverage stated
   `N/N`, every check mutation-tested.
3. **Type safety at scale.** Seventeen `special` values
   ([`21` §5](21-info-lcl-schema.md)), eleven AI orders, twelve planner kinds,
   hundreds of offsets. Rust would make those exhaustive `match`es; GDScript's
   `enum` + `match` work, but nothing catches a missing arm.

Against them: a GDExtension build per platform and per engine version, two
toolchains and no cross-boundary debugger, marshalling arrays across the
boundary, and hot-reload that stops working. For a solo developer that is a
direct risk to the project shipping at all.

**Decision: GDScript, with the seam kept architectural rather than linguistic.**

The core — grid, units, move map, combat, visibility, AI, the turn — is a module
of `RefCounted` and static classes operating on plain data. **No `get_node`, no
signals into the scene tree, no rendering, no engine singletons.** It is then
testable headless without a single scene.

`game` may submit commands and receive immutable snapshots, value results and
events. It must not receive mutable references to `core`'s internal arrays. A
renderer or UI retaining such a reference would let presentation timing mutate
simulation state outside the turn rules, and would make replay and fidelity
traces unreliable.

**Revisit order — answered, and the answer is "none of it".** The instruction
was to profile a complete representative computer turn first, then consider
memoising the move map with a world/navigation revision in its key, and only
then move **the flood fill alone** into a GDExtension. The turn was profiled by
the third slice ([`95` §4](95-slice-3-report.md)): **12 ms on `_C_140`, 264 ms
on `_C_132`** — the corpus worst case, 39 live aliens on 1600 cells — of which
the 123 flood fills are **11 %**. The move map is not material, so neither step
is taken. This paragraph stays as the standing rule for the next time the
question is asked: no performance threshold or optimisation is a contract
without a measurement.

### 2.1 Integer semantics — the one place to be careful

The original is 32-bit signed integer arithmetic throughout; GDScript integers
are 64-bit. Most of it transfers unchanged — `delay + 1`
([`23` §7.4](23-ai-system.md)), `rank / 12` capped at 15
([`21` §5](21-info-lcl-schema.md)), the height comparison against 3200
([`10` §7](10-lev-mission-format.md)) — because they are ordinary truncating
integer divisions.

What needs deliberate care is anything that relied on 32-bit width: the
compiler's magic multiplies (`0x51EB851F` with `sar edx, 9`, and the `n / 2400`
form in [`22`](22-combat-and-visibility.md)) must be written as the plain
divisions they stand for, not transcribed. Every such site should be checked
against the strongest available oracle (§5).

`aRandom` looked like the opposite case and is not. An earlier version of this
section called a Lehmer generator modulo 2³¹−1
([`22` §3](22-combat-and-visibility.md)) *easier* in 64-bit because the
intermediate product fits. It does not fit: `22` §3 gives the step as
`seed = (double)(int)fmod(seed * 62089911.0, 2147483647.0)`, and that product
reaches 1.33 × 10¹⁷ — **past 2⁵³** — so the rounding of the double multiply is
part of the sequence and an integer port produces a different stream. The
generator stays in `double`, and the RNG state is
`{seed: float, calls: int, sum: int}`. `tools/blob_runtime.py:152` already
carried the correct model; sixty-four draws captured from the running game,
with the raw eight bytes of the seed read back after each one, confirm it and
settle the x87 question with it — the shipped control word gives 53-bit
significands, so IEEE doubles here are equivalent
([`93` §3](93-slice-1-report.md)).

The core therefore owns a small explicit integer-semantics library: at least
`i32`, `u32`, `i16`, `u16`, `u8` and signed division truncated toward zero.
Narrowing happens where the original stores into a field of that width, not
blindly after every expression. Its boundary cases are diffed against native
samples or an executable Python model where one exists. The project uses
statically typed GDScript and enables the typed, unsafe and untyped-declaration
warnings relevant to the core as build errors; this helps, but does not replace
the width helpers or differential tests.

---

## 3. Original-data conversion — **Python stays**

The original-format loaders and converters remain the Python in `tools/`,
extended rather than reimplemented. Writing them in Python is faster and more
pleasant than in GDScript, `inclib` already implements every recovered format,
and each loader already has its relevant corpus checks behind it.

Python's boundary ends at decoded, engine-independent data. It does not create
`ArrayMesh`, `Skeleton3D`, `Animation`, `ImageTexture` or scripted Godot
resources. Godot constructs those runtime objects from the converted files and
metadata. The same Python modules also remain research tools and, for the
behaviours they actually implement, executable comparison oracles (§5); those
roles do not make Python part of the shipped simulation.

### 3.1 Conversion runs on the player's machine

Converted assets are derivative works of Blue Byte's data and cannot be
redistributed, exactly as the original files cannot. `tools/out/` is gitignored
for this reason and the same constraint carries into the remake.

So the remake installs **next to a legal copy** — the GOG release — and converts
from it, the way OpenMW requires Morrowind's data and DevilutionX requires
`diabdat.mpq`. **"Convert once" therefore means once per player, not once per
project.**

Two consequences:

* The conversion step ships with the game. How it is packaged — a system Python
  3, or the converter frozen with PyInstaller or Nuitka — is release
  engineering, deliberately not decided here (§9). Either way the source stays
  Python.
* Nothing in the shipped game reads an original format in the hot path. The
  converter runs once, writes an engine-independent cache, and the game loads
  only that data afterwards.

### 3.2 Conversion boundary and outputs

| Source | Target | Note |
|---|---|---|
| `prototyp.bin` geometry ([`31`](31-prototyp-geometry.md)) | portable mesh data | the bytecode, BSP tree included, is evaluated offline; the exact container is chosen by the vertical slice |
| `.cho` / `.cha` ([`40`](40-charisma-model-animation.md)) | portable hierarchy, bind and animation data | bone names already match part names; Godot builds its skeleton and animations |
| `texture.lib` VISN ([`50`](50-visn-textures.md)) | PNG + metadata | the decoder is byte-exact against the original DLL, 723/723 |
| `.LIB` sprites and fonts ([`60`](60-lib-sprites.md)) | PNG/atlas + metadata | preserves palette, hotspot and glyph metrics needed to build Godot textures and fonts |
| `.lev` grid, units, objects ([`10`](10-lev-mission-format.md)) | versioned logical data | authored map data, not scene geometry |
| `Info.lcl` balance tables ([`21`](21-info-lcl-schema.md)) | versioned logical data | one row per unit type, weapon and equipment |
| `.lcl` mission programs ([`20`](20-lcl-language.md)) | versioned AST data | the AST, not the source text |
| `DATA/TXT` briefings ([`24`](24-briefing-text.md)) | versioned localised data | labels resolved, markup kept as structure |
| `.wav`, `.ogg` | copied unchanged | already standard formats |

The portable containers were deliberately left to the first vertical slice, and
the slice has chosen them. **Decided: JSON plus PNG, with no float anywhere in
the cache.**

The scale is what settles it. The slice's lead mission closes over 53
prototypes, 1176 vertices, 610 faces and 10 of 37 textures — a 1997 game with a
software rasteriser, smaller than one modern character, and 1.34 MiB converted.
At that size glTF costs a binary writer in Python, a second coordinate
convention and an opaque diff for no measurable gain; a Godot `.res` would pin
the player's data to Godot's serialisation for the same reason §7.3 rejects it
for saves; and a packed binary wins threefold on a figure that does not matter
while losing both exit criteria of §10.4, which on JSON are `sha256` and `diff`.

**Determinism is built in rather than tested for afterwards: the cache contains
no float.** Vertices are whole world units, texture coordinates are the raw 8.7
fixed point the record carries, colours are the raw `u16` plus a decoded RGB
triple, heights are `i32`. Float formatting therefore cannot drift. Every file
is written with sorted keys, no spaces and no `NaN`, and **no timestamp appears
anywhere, including in the manifest** — a clock is the easiest way to lose
byte-identical output. Polygons stay polygons: triangulation is a rendering
decision and lives in `game/`, or the cache would stop being decoded,
engine-independent data.

The production cache and the development `res://generated/` fixtures are the
**same byte stream** from the same function, differing only in output root, so
§10.1 item 4's "diff the portable logical data, not the incidental Godot
resource serialization" is satisfied by there being no incidental serialisation
at all. Every production cache has a
manifest carrying at least the source edition/language fingerprint, converter
version and cache-schema version, so incompatible or partial output is rejected
instead of being loaded optimistically.

The production cache lives under `user://`; it is player-owned generated data
and is not expected to appear in the editor's `res://` filesystem or Inspector.
During development the same conversion model can materialise a gitignored
`res://generated/` fixture set as Godot resources, glTF and PNG. Those fixtures
are visible in the Inspector and external tools and exist for inspection and
tests, but are never shipped or committed. Production and development outputs
must describe the same decoded data even when their containers differ.

---

## 4. Layering

```
tools/                Python. Format loaders, converters, and the corpus checks
                      that prove the recovered format claims. Also an
                      executable oracle for only the behaviours it implements.
core/                 GDScript. Grid, units, move map, combat, visibility, AI,
                      the turn. No scene tree, no rendering, no singletons.
game/                 GDScript + Godot. Rendering, camera, input, audio, UI.
                      Depends on core; core never depends on it.
```

The rule that matters is the direction of the arrow: `game` knows about `core`,
`core` knows nothing about Godot beyond `RefCounted` and the built-in types.
That is what keeps the core testable headless, and it is the only part of the
earlier "separate language" proposal that was actually load-bearing.

This three-way layout is the starting point, not a promise that no further
layer will emerge. Split it only when implementation supplies a concrete
ownership or dependency problem. Whatever the directory layout becomes, the
dependency direction and the no-mutable-core-arrays rule remain the contracts.

---

## 5. Fidelity testing

This project has unusually strong evidence available for fidelity work, but it
does not all have the same authority.

No single universal oracle exists. Evidence is used in this order, and every
test records which boundary it actually reaches:

1. **Native runtime output or trace from the original.** This is strongest for
   the exercised input and environment. `tools/wine_visn/` already calls the
   shipped `Eng3d.dll` and reaches 723/723 byte-exact; `tools/dbgcall/` supplies
   the corresponding path for stateful behaviour.
2. **An executable Python behavioural model.** This can be diffed against
   GDScript on shared fixtures, but only for functions that Python really
   implements. It is not promoted to native evidence merely because it agrees
   with a static reconstruction.
3. **Checked static extraction and corpus evidence.** The parsers and table
   tools establish formats, constants, call structure and observed data over
   their stated `N/N` corpora. They do not by themselves execute a turn or prove
   every interaction between recovered rules.
4. **The numbered specification.** This is the implementation contract derived
   from the evidence above, with its `verified-static`, runtime and open-question
   boundaries preserved.
5. **An explicit remake choice or hypothesis.** Where the original cannot settle
   a question, §7 records the chosen behaviour; an untested implementation idea
   remains labelled provisional.

Python therefore helps decode the original and supplies selected data/function
oracles. It is not described as the reference for every rule. Fidelity tests
should prefer comparable input/output or event traces over comparisons of
private object layouts.

**The RNG is known.** `aRandom` is a Lehmer generator whose constants are pinned
([`22` §3](22-combat-and-visibility.md)), so a remake seeded identically can be
compared trace against trace, not just outcome against outcome.

---

## 6. What can be built today

Specified, checked, and ready to build against now: map loading and terrain,
scenery geometry and textures, models and animations, fonts and sprites, the
balance tables, combat resolution, line of sight and fog of war, the computer
opponent, the turn and the round ([`25`](25-turn-and-round.md)), using the world
— doors, supply boxes, levers, pushes, teleporters and mines
([`26`](26-interaction.md)) — the campaign around them: the roster that survives
between missions, the location map and its unlock graph, the equipment-point
economy and the mission-end score ([`27`](27-campaign.md)) — the effects and
sound around all of it: the event → wave table, the weapon fire sound, the
footstep and voice tables and the blob pool with its weapon → effect switches
([`28`](28-effects-and-sound.md)) — the replacement-interface contract
([`29`](29-interface-contract.md)) — the complete story-sequence manifest and
player ([`41`](41-sequence-player.md)) — and every line of mission text. All
packages in [`00`'s game-logic matrix](00-overview.md) are delivered at their
documented verified-static boundaries.

The recovered formats and rules are sufficient to start a first vertical slice:
convert one mission, draw the grid, and light up the reachable cells from
[`23` §7](23-ai-system.md)'s move map. The slice still has to choose and validate
the remake-side data and runtime boundaries described in §10. Its first fidelity
milestone is the moment those reachable cells agree with their declared oracle,
not merely the moment something visually similar appears.

---

## 7. Product decisions

These are the choices no evidence can settle: the specs say what the original
does, and something still has to decide what the remake does about it. They are
recorded here once, with the reasoning, so they are not re-argued — and because
several of the numbered specs already point at this section for them.

### 7.1 Faithful by default, corrections as settings — with one exception

The recurring shape is a defect in the original that a remake could quietly fix.
The rule:

**Reproduce a defect that is part of the output. Never reproduce a defect that
makes a control inert.** A quirk the player perceives is the game; a slider that
does nothing is a bug in the remake's own interface, whatever the original did.

Under the first half, reproduced by default with the correction offered as a
setting:

* the `technical` supply box's guard, which lets an id-16 box be opened by the
  wrong `TS` — §7.8 has the detail;
* weapon 35's fire sound, which never loads because `Info.lcl` spells the file
  `W_BAY0_0` with a zero and never creates the record it patches
  ([`28` §3.1](28-effects-and-sound.md));
* unit type 24's footsteps, scaled by a weapon-band volume id and so twice the
  volume of the identical type's ([`28` §5](28-effects-and-sound.md)).

Under the second half, fixed unconditionally and with no setting:

* the alien scream, scaled by the **human** volume ids
  ([`28` §4.1](28-effects-and-sound.md)). The defect leaves ids 53–55 defined
  and dead, so an "alien voices" control in the remake's audio options would do
  nothing. That is the inert-control case, not a period detail.

One user-facing preset covers the whole first list — `Faithful`, on by default —
not one setting per defect. Internally, however, every compatibility choice has
a stable named flag, for example `technical_box_guard_original`,
`weapon_35_missing_sound` and `unit_24_footstep_volume_original`. Saves, replays
and fidelity tests record the individual flags rather than only the preset name;
this lets the preset grow without silently changing an old session.

### 7.2 The grid — the authored map and the live state are two structures

The question was posed as a choice of container: a `Resource` with typed arrays
against a `PackedByteArray` mirroring the original's 23-byte cell. The right cut
is not by container but by lifetime. (An earlier version of this paragraph cited
[`26` §3.1](26-interaction.md) for a count of live bytes; that subsection holds
the `aExecuteUse` class table and no such count. The working contract is the
explicit field list below, and [`10` §4](10-lev-mission-format.md) documents
eight purely runtime bytes.)

So: two objects, and **struct of arrays, not array of structs**.

* `MapResource` — the immutable authored grid that `core` constructs from the
  converter's engine-independent data: heights, field types, action points and
  object arrays.
* `MapState` — the mutable fields interaction writes, each a `Packed*Array` of
  `width × height`, initialised from the resource: height `+0x01` and field type
  `+0x0D` (doors), the action point `+0x0B` (every pickup, both levers, the
  entry point, a captured VictoryPoint), the unit link `+0x07` (pushes and
  teleports) and `+0x0E`…`+0x11`. Those four are **not four bytes of the same
  kind**: [`23` §7.1](23-ai-system.md) shows `+0x0F` and `+0x11` are slot
  indices into the runtime object array while `+0x0E` and `+0x10` are values.
  All four are carried through verbatim and none of them is interpreted.
  `+0x10` in particular is the transient obstacle — fire, a mine, a shield —
  and is `0xFF` in all 184162 shipped cells because it is created during play,
  so `MapState` synthesises it rather than the converter carrying it.

What this buys that neither original option did: authored input cannot be
accidentally mutated; fidelity diffing against an appropriate oracle runs array
against array, each one mapping 1:1 onto a documented byte offset; and the move
map's flood fill over
up to 1600 cells reads contiguous packed arrays instead of dereferencing a cell
object per step, which is the one hot path [`23`](23-ai-system.md) has.

The save stores the complete mutable map state, not a delta. At most 1600
cells the simpler snapshot is cheap, self-contained and easier to validate and
migrate than dirty tracking. It references an authored-map identity and hash so
the loader can reject a save paired with the wrong converted map. The original's
need to embed a whole `.lev` ([`11`](11-save-game-format.md)) does not constrain
the remake either way.

This is an early working decision because it shapes everything in `core/`.
The vertical slice must validate it before wider implementation makes it costly
to change.

### 7.3 Saves — the remake's format is its own

**Decided now, at no cost: the remake's save format is designed around the
remake's state and is never a superset of the original's.** Writing `.sav` would
be a compatibility promise that permanently pins the state model to another
game's — a fixed slot 32, no field for the camera, a whole `.lev` embedded in
every file ([`11`](11-save-game-format.md)).

**Reading** original saves is a one-way import that constrains nothing, so it is
deferred rather than rejected: worth doing after 1.0, and worth remembering
that it is also the cheapest route into what remains open in
[`11`](11-save-game-format.md) §9 — six campaign saves already exist as
gitignored fixtures and narrowed those questions without settling them, and
finishing the job wants save kinds the retail release cannot produce (among
them a multiplayer one). As a feature it ranks low — someone installing a remake is likely to
start the campaign again.

**The container is decided, and it is a small binary envelope rather than a
Godot `Resource`.** The first vertical slice implemented and tested it
(`godot/core/save_codec.gd`, [`93` §6](93-slice-1-report.md)):

```
  0   4   magic "INCS"
  4   4   schema version
  8  32   sha256 of everything from byte 44 on
 40   4   payload length
 44  32   the authored map's hash
 76  ..   a JSON header: width, height, mission, RNG state, compat flags,
          the camera, and the unit records
     ..   the complete mutable map state, array after array
```

Four properties, each with a negative test behind it: an unknown schema version,
a truncated file, a corrupted digest and a save paired with a different authored
map are all refused **by name**, and none of them half-loads. A round trip
preserves the canonical simulation hash; the camera travels in the file and is
excluded from that hash.

**The turn is in it now**, and the checklist item that said otherwise is
closed. The second slice ([`94`](94-slice-2-report.md)) put the [TurnState] --
counter, both players, the rotation's shape, the difficulty level, the session
kind, the reaction tickets and the hero flags -- and the twelve game-control
slots into the header and into the canonical hash, and the schema version rose
with each change: 3 → 4 for the turn, 5 for the columns combat reads, 6 for the
mission script's own.

**Two generators, not one.** `InsertUnit` draws from the C runtime's `rand()`
and everything else from `aRandom` ([`20` §7.4](20-lcl-language.md)), so the
save and the hash carry both streams. A save that dropped the second would come
back a different mission the moment the next reinforcement fired.

What is still a checklist rather than a decision: the campaign phase has no
representation because the campaign layer does not exist, and migration between
schema versions has a version field but no migration to test. The compatibility
flags are in the hash from the first day so that later ones cannot be added
without changing it.

A Godot `Resource` may be convenient as the in-memory DTO, but `.res` is not the
public on-disk contract: it couples saves to Godot serialization, script paths
and class layout. The external format and migration boundary are selected and
tested separately.

### 7.4 A full roster loses the surplus, but never silently

The original drops survivors that do not fit: `aTransferUnitFromMapToPool`
returns success without adding the unit when all 30 slots are taken, and nothing
tells the player ([`27` §3.4](27-campaign.md)).

Every mechanical fix that was considered — refuse the mission, force a
dismissal, queue the survivor — changes campaign pacing and the equipment-point
economy. So **the rule stays exactly as the original has it**, and what gets
fixed is the silence, which is not a rule at all:

* the mission-end screen lists the survivors who could not be taken;
* deploying with 30 of 30 slots filled, into a mission that can yield recruits,
  warns first.

Both are interface additions. Fidelity is untouched in either direction, which
is why this needs no setting and why it was not really the open question it
looked like.

### 7.5 Camera — the original framing, four ninety-degree steps

There is measured evidence rather than taste here. [`10`
§6](10-lev-mission-format.md) now records it: **all 194 105 3D-object records
in the shipped missions carry yaw only, and 99.5 % of those yaws are exact
quarter turns** — 100 % of the land lattice, 91.6 % of the special objects,
94.8 % of the scene clones. The world is authored on a four-fold symmetry.

So: **four fixed orientations, rotated in 90° steps.** Free rotation would show
faces at angles no one composed; quarter turns cannot. Zoom is free within the
height range the mission header gives ([`10` §3](10-lev-mission-format.md), 1600
units = 1 m), pitch is fixed, and the camera persists across a save — the
original had no field for it and reset the view on load
([`11` §5.6](11-save-game-format.md)), so keeping it is a free improvement
rather than an infidelity.

### 7.5.1 The view opens on the squad, not on the middle of the map

`CameraRig.setup` parked the pivot on the centre cell at the mission's authored
`camera_height`. On `_C_140` the centre cell is inside a support column and the
authored height is 20 m, which is **above the level's roof** — these maps are
interiors — so the first frame of the game was a pillar seen through a ceiling.
The original shows the squad, close.

So the view opens on **one unit's cell** — not the squad's centroid, which is
not a cell anybody stands on and which on `_C_140` lands inside the wall
between four marines — at 8 m rather than at the authored maximum. The maximum
is untouched and the yaw is left to the player. This is where the view starts,
not a new limit, and it changes no hash.

### 7.6 Localisation — the seam stays, and Russian is planned

Only `English` ships in the GOG release, but **a licensed Russian release is
intended as a second data set**, so the language seam is not hypothetical: it
has a known first user.

The decision: the converter takes a language and writes a per-language cache,
and **no user-facing string is a literal in GDScript**. A single
`LocalizationService`, preferably backed by Godot's standard `Translation`
system, resolves both imported original-game strings from `Txtmod_*.lcl`
([`20` §6](20-lcl-language.md)) / `DATA/TXT` ([`24` §1](24-briefing-text.md))
and a separate catalogue of remake-only UI strings such as converter errors,
settings and new warnings. Both use stable keys and an explicit fallback
language. Retrofitting that seam later means finding every literal in the
codebase, which is the expensive kind of change.

**Built in the second slice** (`godot/game/localization.gd`,
[`94` §5](94-slice-2-report.md)), before the first string existed, and with one
addition the decision above did not name: **a miss renders as a visible
marker**, not as an empty string. An empty string looks like a layout bug and
`??hud.end_turn` looks like what it is, which is what lets a check assert that
nothing on screen is missing. The shipped catalogue is keyed by module and
numeric id because that is how `DATA/TXT` is keyed; naming 723 strings would be
a translation of its own.

Three consequences that are cheap now and awkward later:

* **The code page is per language, never hardcoded.** A font is 224 elements
  indexed `codepoint - 32`, one per code point 32…255
  ([`60` §5](60-lib-sprites.md)). The *format* does not change for Russian —
  only which characters the upper half holds. So the converter carries a code
  page per language (cp1252 for English, cp1251 for Russian) and decodes to
  UTF-8 **at conversion time**, so nothing downstream ever sees a byte whose
  meaning depends on a locale.
* **Fonts and sprites are per-language assets, not shared ones.** The glyphs
  themselves live in `Libs/font_*.LIB`, so a localised release ships different
  font libraries — and possibly different UI libraries wherever a button
  carries baked-in text. The converter's cache is keyed by language for those
  too, not only for text.
* **The Japanese path stays unimplemented.** The measure and print passes
  branch on the language name and read big-endian two-byte characters when it
  is `Japanese` ([`24` §4.4](24-briefing-text.md)). Russian is single-byte, so
  nothing here needs that branch; it is recorded, not built.

One thing to establish before a second release is treated as evidence rather
than as content: **whether its `Incubation.exe` is the build these specs are
pinned to.** Every address in `combat_tables.py`, `ai_tables.py`,
`turn_tables.py`, `interaction_tables.py`, `campaign_tables.py`,
`blob_tables.py`, `sav_tables.py` and `trace_names.py` is a virtual address in
the GOG executable. If the localised disc carries the same binary, all of it
transfers and only the data differs; if it carries a different build, that is a
second binary and a separate piece of work — valuable, because a finding
confirmed across two builds is stronger than one, but not free. The corpus
checks have the mirror-image problem: they pin census numbers that are facts
about *this* release (155 `.lev`, 723 textures, 99 waves, 224 glyphs per font),
not about the format, so pointing them at a second release means separating the
structural invariants from the census first.

### 7.7 A ladder step follows the move map's rule

Field type 8, `Ladder`, has **0 cells** in the shipped campaign, and the two
halves of the
engine disagree about what such a step costs: `aBuildMoveMap` charges the
unit's whole movement allowance, while `aExecuteMove` charges the ordinary
`delay + 1` / `delay + 2` ([`26` §5.1](26-interaction.md),
[`23` §7.4](23-ai-system.md)). No data can say which was intended, so this is a
choice rather than a finding. The remake takes **the move map's rule** — a
ladder-to-ladder step costs the whole allowance — because that is the one the
player sees: the map decides which cells light up, so charging anything else
would make the highlighted range a lie. Consequence worth writing down, now
measured natively ([`23` §7.4](23-ai-system.md)): the step needs
`mp >= allowance` and leaves `mp - allowance`, so a unit acting at its full
allowance arrives with nothing left — but one that had *more* than its allowance
does not, and one that had less cannot climb at all.

### 7.8 The `technical` box keeps its bug, behind an option

Action point 16 guards on Battle Fitness (`unit[+0x1A]`) and increments
Technical Skills (`unit[+0x1D]`) — a copy-paste slip pinned byte by
byte in [`26` §3.3](26-interaction.md). The remake **reproduces the original
behaviour by default** and exposes the correction (`TS < 6`) through a
non-faithful compatibility profile,
because the four campaign cells that carry the box were balanced against the
shipped behaviour. Consequences worth writing down so they are not
re-litigated: the guard reads a different stat from the one it increments, and
the increment has **no upper bound** — a unit repeatedly using such a box while
its Battle Fitness is below 6 can push Technical Skills past 6. Both are part
of the default path, not defects to be tidied away. This is the case §7.1
generalises.

### 7.9 No play-by-mail or legacy multiplayer research

The original's `pbm session` mode is named in the binary ([`25` §2](25-turn-and-round.md)) and its passwords are in
the save format ([`11` §5.3](11-save-game-format.md)), but it was barely a
feature in 1997 and the remake will not have one. Consequences worth writing
down so they are not re-litigated: the `pbm session` arm of the turn's skip rule
and of the equipment-point split need no implementation
([`25` §3.1](25-turn-and-round.md), [`25` §4.1](25-turn-and-round.md)), and
neither does the password obfuscation.

The completed game-logic research programme deliberately excluded
`aMultiPlayer.cpp`, `lNetwork.cpp`, `aDPlay.cpp`, and `aMsgTools.cpp` (34
`CHECK` sites plus DirectPlay). A remake would not reuse DirectPlay, and modern
netcode is a product design rather than a binary-parity requirement. Already
recovered and still contractual are the multiplayer map types and `.lev`
fields ([`10` §3](10-lev-mission-format.md)), the `Victorypoints` action-point
band ([`10` §4.6](10-lev-mission-format.md)), and the PBM save layout
([`11`](11-save-game-format.md)). If multiplayer is added later, the remaining
research targets are the PBM turn-exchange `.sav` variant and
`aOutputMissionObjectsForMultiPlayer`, the original state-sync boundary.

---

### 7.5.2 A move that would leave the level is refused, not shortened

The pivot sits on a map field and the eye is up and back from it, so at a wide
zoom it left the level: outside the map looking in, or inside a wall. On
`_C_140` the middle field is a 16 m support column.

**The first fix was to pull the eye in every frame until it was clear.** It
satisfied "the eye is never inside geometry" over all 1600 pivot-and-yaw
combinations of `_C_140` — and it was unusable. Beside a wall the eye collapsed
onto the unit's feet; during a yaw tween the clearance was recomputed every
frame, so the view snapped back out to the ceiling the moment the wall passed.
A continuous clamp on a discrete camera reads as the camera fighting the
player.

So the rule is a **refusal**. A quarter turn that would end with the eye
outside the level does not happen, and neither does a zoom step; the view stays
exactly where it was, which is something a player can understand and work
around. Zooming *in* is always allowed — it can only bring the eye nearer a
pivot that is on the map by definition.

Three deliberate limits:

* **only the eye's own position is tested, not the ground it passes over.**
  Testing the path refuses almost every view on an interior map, because these
  levels have columns and ceilings everywhere and the camera is meant to look
  past them;
* **where no yaw fits at all, every turn is allowed.** Refusing all four would
  trap the player for no gain;
* **following a unit does not re-choose the yaw.** A camera that turned by
  itself whenever the selection moved would be worse than one that occasionally
  looks through a wall. The opening yaw is the single exception, and it is the
  one moment with no previous view to preserve.

The rule reads the map's **own cell heights** — the same data the simulation
uses — rather than a collision mesh built from 1642 scenery instances, which
would be a second and disagreeing description of the level. It never touches
`_zoom`, so a save still round-trips the zoom the player chose.

Neither the crowded-pivot case nor the zoom refusal occurs anywhere on
`_C_140`: a field near a corner fails for one yaw and the **opposite** yaw
always fits. They are exercised on a synthetic map instead — a pivot ringed by
100 m walls, and a one-sided wall that refuses one yaw while another fits — and
the suite says so, so that the corpus checks are not read as covering them.

### 7.5.3 The view is handed back with the turn, and the squad can be cycled

The replay of the computer's turn leads the camera to every alien it shows.
Nothing led it back, and the view has **no pan** — the only two things that
move the pivot are a selection and the framing done at load. So a replay that
ended in the far corner handed the turn back with the whole squad off screen
and nothing on screen to click: the game accepted input, rendered at full
rate, and could not be played. It reads exactly like a freeze, and it was
reported as one.

Measured rather than argued: driving `SliceMain` from a script, ending each
turn and projecting every squad member into the viewport, `_C_140` reaches
that state from **turn 4** on — 0 of 4 inside the frame, then 1 of 4. With the
hand-back in place it is 4 of 4 on every turn of the same run.

Two things close it, and both are the engine's own:

* **the hand-back.** When the computer's turn ends the pivot goes to the first
  unit the current player may command. The zoom and the yaw are not touched —
  those are the player's, on Q, E and the wheel — so this moves the pivot and
  nothing else. It is the remake's decision, consistent with the focus path
  [`29` §3](29-interface-contract.md)'s command 2 provides; that the engine
  runs that command on hand-over is **UNVERIFIED**;
* **the cycle**, on TAB: select the next unit the player owns and look at it.
  [`29` §3](29-interface-contract.md)'s command **14** (`0x00453CF0`), which
  the engine binds to a key and which this remake did not have at all. Without
  a pan it is the only way to reach a squad member the camera is not already
  pointing at, so a hand-back that shows *one* unit is not enough on its own.

Both go through `World.may_command` — `0x00477DF0`, which `0x00453CF0` walks —
and not through the player byte. A dead squad member stays in `unit_slots()`
and the fog pass leaves an own corpse fully visible, so the weaker test would
cycle to a body the mouse refuses to select and hand the camera back to it.

A pan is still not implemented. ~~The original does not need one either: it
drives the view from the selection, which is what these two restore.~~
*(Corrected 2026-09-02: [`42` §2](42-mission-presentation.md) read the camera
out of `aMI.cpp`. The original pans on a middle-button drag, rotates freely
on a right-button drag, keeps a view quadrant of its own, flies the camera to
every unit before it walks, tracks it while it walks, and places it behind a
computer shooter or its victim. The hand-back above stays a remake decision:
the engine's hand-over `0x0047D600` calls no camera routine, which is now
verified rather than UNVERIFIED. The four-orientation decision of §7.5 stands
— the engine's own quadrant `0x00510700` supports it; the rest of the camera
is planned in `docs/97`'s next addendum.)*

### 7.5.4 The rotation never hands the interface a turn the computer holds

Reported as "the enemy turn hangs and I can select and move an enemy unit",
and both halves were one bug.

`World.submit_end_turn` looped on [code]TurnResult.ai_turn[/code]. The engine's
own loop, [`25` §4.1](25-turn-and-round.md), is
`do { ... } while (g_currentPlayer == 255 && result == 1)` — on the **player**,
not on whether the planner ran. The two differ in exactly one place, and it is
the first press of the button in every mission: `0x0047D600` runs
`aAISystemControl` only `if (g_turn != 0)`, so at turn zero the computer is
handed the turn and does nothing with it. Looping on the planner stopped there
and returned to the interface with player 255 holding the turn.

What that allowed was not cosmetic. `World.may_command` — `0x00477DF0` — asks
whether a unit's owner *is the current player*, so with 255 holding it the
aliens became selectable and the player could spend their turn for them, while
the interface waited for a press that would only end a turn that was not
theirs.

The engine has a second line of defence the remake did not: `0x0047D600` sets
**view state 2** the moment the rotation reaches 255, and only view state 0
accepts commands. There are no view states here, so `SliceMain` refuses
commands while the computer holds the turn. With the loop fixed that should be
unreachable through the rotation; it stays for the stopped hand-over, where
every player is out and no mission end is behind it.

### 7.5.5 What is drawn is a fresh fog pass; what is decided is not

An enemy that walked into the squad's sight stayed a blip until the turn
changed, because `Visibility.build` ran only in the hand-over.

The engine's answer is stranger and better, and it is in
[`22` §9.4](22-combat-and-visibility.md): every player command **probes** the
fog — save all 200 `+0x4F` bytes, rebuild, read, restore — and the restore
covers the unit byte but not the 3D object's draw flag that
`aSetVisibleStateForUnit` writes beside it. The picture follows the probe; the
rules do not.

`Visibility.states_for` is that probe, and it is a query: it puts every byte
back, so nothing about it reaches the canonical hash, the planner or the
resolver. `UnitsView.build` draws from it instead of from the stored byte.
Replaying `_C_140` to its end under two policies gives the same outcome, the
same turn and the same survivors as before the change, which is the point —
only the picture moved.

**The permanent rebuilds, which this then closed.** The first revision of
[`22` §9.4](22-combat-and-visibility.md) counted **eight** call sites and named
three of them permanent, because that is what radare2's `axt` reports after
`aa`; a `.text` byte sweep for the encoded `call` finds **19**, and every one
of the extra eleven disassembles into a real instruction. The corrected table
is in §9.4 and `combat_tables.py`'s `fog.sites` now pins it exactly.

Of the **fifteen** permanent sites, five are the door (two), `InsertUnit`,
the `BuildVisibleMap` command and `special` 9, and they were implemented
first:

* **the door** — `aDoorOpenSequence` (`0x00410A20`) rebuilds on both arms and
  refuses while the computer holds the turn. It lives in `World.submit_use`
  and **not** in `core/interact.gd`: `interact_runtime`'s native capture
  replays `aExecuteUse` alone, which calls `aBuildVisibleMap` nowhere, so a
  model that folded the animation into the routine would disagree with the
  engine it was measured against. `_C_140` carries two closed doors, so this
  is reachable in the mission the slice plays;
* **`InsertUnit` and the `BuildVisibleMap` command** — `LclInterpreter`
  already recorded both as `build_visible_map` events and performed neither.
  `World._run_mission_script` acts on them, which is the same split the fog
  already had: the interpreter owns four cell fields and no derived state;
* **`special` 9** — `0x0046F210`'s `case 4`, in `Combat.hatch`; see §7.5.7.

> **The count was wrong here, and this is the correction.** This paragraph
> used to say "three of the fifteen … the other **twelve**", while listing
> eight addresses. Five sites were implemented and ten were not; the twelve
> came from counting mechanisms on one side of the subtraction and sites on
> the other, and it silently dropped `0x00457926` and `0x004781C6` from the
> enumeration entirely.

**The remaining ten, resolved.** Three more are now implemented, one is a
reclassification, and six are recorded with the reason each is not:

| Site | What it is | Here |
|---|---|---|
| `0x00412905` | `aPlayElevatorSequence` | **implemented** in `World._run_mission_script`, for the **rider's** player |
| `0x004490A9` | the load path | **implemented** at the end of `World.load_save` |
| `0x0047DCCF` | `aNextPlayerHandling`'s one-shot | **implemented** as `World._first_hand_over`, campaign only, for a literal player 0 |
| `0x004781C6` | `refreshCurrentPlayer` | **reclassified**: `0x004781C0` is a four-instruction forwarder — `push ebp; call aBuildVisibleMap` — with one caller. It *is* `Visibility.build`, not a mechanic beside it |
| `0x0040D6BD` | weapon 46's impact arm | **recorded**: it spawns a `Spider` for the firing player ([`22` §9.4.2](22-combat-and-visibility.md)), and no placed unit in the 155-mission corpus carries a weapon above 29. Reachable only through the campaign armoury, which this remake does not have |
| `0x004130E6` | `aPlayPlatformSequence` | **recorded**: it rebuilds for the unit the *interface* has selected (`0x00471F70`), and `core` owns no selection — that is `game`'s. Guessing the rider instead would be a different rule, not the engine's |
| `0x004149C7` | the **spore hatch** `0x004147D0` — *not* `FixedStatue`, which was a wrong routine boundary ([`22` §9.4.3](22-combat-and-visibility.md)) | **recorded**: the site is not a bare rebuild. It follows `aDeleteLand` and an `aGenerateUnitElement` that spawns a unit of the type the LCL command supplies — `Spores`' third argument, or the constant 50 from `MoveSpores`. Only two commands reach it, neither is implemented here, and `Spores` is used by one shipped mission (`_C_174`) that this remake does not convert |
| `0x0046F144` | `aExecuteWarp` | **recorded**: `MoveMap` computes the warp overlay and nothing consumes `STATE_WARP` — there is no execute path to hang it on yet |
| `0x00457926` | `aMissionControl`'s GUI build | **recorded**: four interface-driven call sites. `game` redraws its HUD without asking `core`, and folding this in would make a draw mutate the rules |
| `0x00478DE4` | `aTransferUnitFromPoolToMap` | **recorded**: the unit pool is the campaign layer's ([`27`](27-campaign.md)), which this remake does not have |

Two of the three implemented are inert on `_C_140` and one is not reachable
from it at all: replaying the mission to its end through `core` gives a
byte-identical canonical hash with the elevator arm and the one-shot on and
off (`4b0d4bd7…` either way), because its script drives no elevator and its
first hand-over's own rebuild immediately supersedes the one-shot's. The load
path is exercised by `test_turn.gd`'s `save.the_load_rebuilds_the_fog`, which
is a *behavioural* change: a save's stored `+0x4F` bytes are not the ones the
loaded mission plays with.

### 7.5.5.1 The hero counter, which was the real gap

Chasing the remaining ten turned up something bigger than any of them.
`aRemoveUnitElement` (`0x004779C0`) — the routine every removal in the engine
goes through, `aKillUnit` included — increments a per-player byte at `+0x24`
when the unit it removes is a **hero** and the turn counter is non-zero.
[`22` §9.5](22-combat-and-visibility.md) has it instruction by instruction.

That byte is what the LCL predicate `HeroKilled` reads. `TurnState`
carried the field, `LclInterpreter` read it, and **nothing wrote it**, with a
comment saying only a save could set one. 75 of the 156 shipped scripts call
`HeroKilled`, and `_C_140` — the mission this remake plays — makes it half of
the defeat condition.

`UnitState.remove` is now the one place a unit leaves the map, and every
removal path goes through it: the resolver's kill, `Interact`'s bomb and its
push into a hole, the parabomb, `Combat.hatch`'s carrier and `LclContext.kill`
(which is `KillUnit`, the barrier and the fixed statue). `inclib/combat.py`
and `inclib/lcl_runtime.py` grew the same function.

**This one is not inert.** The same `_C_140` replay ends on turn 9 with 17
survivors instead of turn 11 with 19: the squad's hero dies, `HeroKilled (0)`
finally answers true, and the mission's own defeat condition fires. The
canonical hash moves from `4b0d4bd7…` to `258596e3…`, and a mutation that
disables only the counter puts it back exactly — which is how the change was
attributed to the counter and not to the two fog sites beside it.

**One deliberate difference from the engine.** The probe wakes no AI group.
The engine's can: `aBuildVisibleMapForUnit` promotes the secondary order of a
group it sees, and orders are not in the buffer the restore covers. A query
that promoted an order would be a command, so `states_for` passes the empty
`wake` callable that `for_unit` already documented for exactly this.

### 7.5.6 The contact blip is the engine's own geometry

A detected-but-unseen unit was drawn as a flat red disc this remake invented.
The original draws `A_BLIB.3DI` — `a3DObjects.cpp` line 3838 resolves the name
through `aGetNumberOfPrototype` at `0x00407056` — and the geometry says what it
is: 28 vertices spanning z 730..6337 in a 1550-wide footprint, a beam about
3.5 m tall standing on the cell.

It is named by no placement, so the converter asks for it by name for every
world set, exactly as it already did for the unit marker `A_MK_0B.3DI`. That
is a change to the emitted document, so `CONVERTER_VERSION` is **0.8.0** and
the cache has to be republished.

### 7.5.7 `special` 9 — the one arm that rewrites the roster

[`21` §5](21-info-lcl-schema.md) lists seventeen values of the unit type's
`special` column and one dispatcher, `0x0046F210`. Sixteen of the values were
already modelled or already unreachable; **9** was neither, and it is the one
that also moves the fog, which is how it surfaced.

`Squee'Coo` (type 57, its only shipped carrier, in 19 of the 155 missions and
in none of the five this remake plays) that is **hit and not killed**, left
with five hit points or fewer, by a weapon whose `type` column is 1, 2 or 4, is
removed and replaced **on its own cell** by a neutral `Squee'Ther` (type
`0x36`) that inherits its AI group — and the fog is then rebuilt for the player
holding the turn, permanently.

Four details are the engine's and each would be easy to get wrong:

* the sweep is over **cells marked `0x5C`**, not over the outcomes that dealt
  damage. `aPlayFightAnimation` (`0x0040BD70`) walks the whole cell array and
  calls the dispatcher for every cell whose marker byte is a hit; a kill writes
  `0x5D` and is skipped, and a shielded cell writes `0x5B` and is skipped too,
  even though its occupant is alive and frail;
* the carrier is **removed, not killed** — `aRemoveUnitElement` (`0x004779C0`)
  frees the record and clears the cell — so its slot is free again and the
  replacement usually takes it. That routine also counts a hero (§7.5.5.1), so
  the hatch goes through `UnitState.remove` like every other removal;
* `aGenerateUnitElement` is called with its `exact` flag **set**, so the
  replacement never searches a neighbouring cell the way an `InsertUnit` does.
  That flag is the only difference between the two callers, so
  `UnitState.generate` takes it as an argument and `LclContext.spawn` became a
  one-line delegate rather than a second copy of the routine;
* there is **no** `!= 0xFF` guard here, unlike the door: the hatch rebuilds the
  fog during the computer's turn as well.

**Where the boundary is.** This belongs to `aPlayFightAnimation`, which runs
*after* `aAttackUnit` returns, so a `dbgcall` capture of `aAttackUnit` can
never contain it and `test_combat_native.gd` is not where it is checked. It is
folded into `Combat.attack` because that is the single funnel all three
shooters reach, and the boundary is written into the docstring so a future
capture of a `Squee'Coo` mission is not read as disproving a correct model.

### 7.10 Gameplay animation plays at 20 fps, and that is now mostly measured

**Revised.** This section said 30 fps and called it a free choice, on the
grounds that the original's gameplay rate was whatever the machine managed.
[`40` §4.8](40-charisma-model-animation.md) now carries a third link that
constrains it: `aExecuteMove`'s two walk helpers cross a map field in exactly
**six** calls of the gameplay frame routine, and that routine is the one the
skip controller caps at a nominal **20 fps**. Since gameplay advances key time
by one unit per rendered frame, the walk was paced against 20 fps, and the rate
and the field time are **one** choice rather than two.

The remake therefore fixes **20** in `CharismaState.FRAMES_PER_SECOND` and
*derives* the field time from it. Cutscenes keep the 30 fps that is proven
outright; they are a different clock.

What the old pair reproduced is worth recording, because it is why the bodies
sprinted: 30 fps with a hand-picked 0.16 s per field is, to within rounding,
the engine's **epoch bug** — the limiter does not reset its epoch on the branch
that waits, so the cap was enforced every other frame and a field took ~0.15 s.
Following the bug is not the same as following the original.

One neighbouring quantity is still a decision, and is named rather than folded
into an expression:

* **`WALK_SECONDS_PER_STEP` = `FRAMES_PER_FIELD / FRAMES_PER_SECOND` = 0.3 s.**
  Derived, not chosen. What *is* chosen is that
  `AIPlayback.STEP_SECONDS` became a **floor** rather than the whole rule: an
  event may ask for longer, and a move asks for its walk, because at the
  engine's own pace a move of more than one field outlasts the old fixed
  window and the next event's rebuild would cut the walk in half. `skip()`
  still means "stop drawing" rather than "stop simulating".
* **`M` loops while a unit walks and `S` resumes when nothing else plays.**
  [`40` §7.2](40-charisma-model-animation.md) marks the playback set-up of
  `kind` 0 and `kind` 4 UNVERIFIED — the interface slots `+0x44`, `+0x2C` and
  `+0x34` are not decompiled — so these are chosen, not recovered. `kind == 4`
  and its one fixed literal `P0_M2_000` are not implemented at all.

What is **not** a choice, and is measured, is the bone-to-mesh scale of 16
([`40` §5.3](40-charisma-model-animation.md)) and the `BREAK` note that stops a
combat animation ([`40` §9](40-charisma-model-animation.md)).

## 8. Standing constraints

These follow from the repository's own rules and apply to the remake as well:

* **`gog_incubation/` is read-only.** Nothing in the pipeline writes into it,
  including the converter running on a player's machine.
* **No converted asset is ever committed.** Not to this repository and not to
  the remake's.
* **No original format is parsed in the hot path.** The converter is the only
  thing that reads them, and it runs once per installation.


---

## 9. What is still open

The product choices in §7 are the current defaults, and the architecture is not
frozen. A decision changes only when implementation or a new observation
supplies a better fact, and this file records the change and its reason.

**The first vertical slice is done** ([`93`](93-slice-1-report.md)). The six
things it was to validate have been settled and written back into this file:
the converted-data container and schema (§3.2), the Godot materialisation path
(§3.2), the save representation (§7.3), the fidelity trace shape (the
`incubation.movemap-cases/1` document one reader consumes from three
producers), cache invalidation (the source fingerprint is the set of files the
converter actually read, and the whole inventory is verified on every load), and
the practical `game`/`core` boundary (`core` returns fresh dictionaries of
scalars and duplicates every packed array, because a `Packed*Array` returned
from a function aliases the original in Godot 4.7).

The slice also measured what §2 could only hope: **one complete move map over
990 cells costs 138 µs**, so memoisation, a native flood fill and GDExtension
are all unjustified for the AI loop. The complete AI turn it could not measure
was measured by the third slice, and agrees — see below.

What the slice deliberately did not settle is listed in
[`93` §8 and §9](93-slice-1-report.md). **Four of those items were closed
afterwards** and are recorded in [`93` §10](93-slice-1-report.md):

| Item | Where it went |
|---|---|
| The ladder step, and the movement allowance as an *input* | native, [`23` §7.4](23-ai-system.md) and [`10` §5.5](10-lev-mission-format.md); `core/allowance.gd` computes it |
| `draw_kind` recovered but not implemented | `game/mesh_builder.gd`, per [`31` §4.4](31-prototyp-geometry.md)'s table |
| Face triangulation assumed convexity; the cross-check was manual | [`31` §4.3.1](31-prototyp-geometry.md) counts 1572 reflex faces; the mesh builder ear-clips and `prototyp_parse.py --check` pins the counts |
| The 4/8-connectivity asymmetry, recorded but unresolved | `core/walk_map.gd` transcribes `aWalkMoveMap`, pinned natively; [`23` §8](23-ai-system.md) reports 2772 diagonal steps and **no** path leaving the highlighted region |

**The second vertical slice is done too** ([`94`](94-slice-2-report.md)): the
turn, movement execution, line of sight, the fog pass, combat, reaction fire,
interaction and the mission-script interpreter, with `_C_140` played and won in
an exported build. What it settled and this file now carries: the difficulty
level is [TurnState]'s own field and enters the canonical hash (§7.9 below), the
save schema carries **both** generators because `InsertUnit` draws from the C
runtime's and not from `aRandom`, and the set pieces apply their state change
instantly while recording the animation as an event.

Three things it left open were named here because they are architectural rather
than research. **The first of the three is now closed.**

**The third vertical slice is done** ([`95`](95-slice-3-report.md)):
[`23`](23-ai-system.md)'s planner in full — the target overlay, the cover score,
the approach cell, the plan, the fire, the eleven order arms, the two-pass
six-level sweep and the pseudo-player — with `_C_140` played against an opponent
that closes and shoots, and **defeat reachable for the first time**. It settled
four things this file now carries:

* **§2's oldest measurement is taken.** A complete computer turn costs **12 ms**
  on `_C_140` and **264 ms** on `_C_132`, the corpus worst case by live aliens
  times cells. Flood fills are 11 % of it. The conclusion §2 reached on a guess
  and [`93` §5](93-slice-1-report.md) and [`94` §4](94-slice-2-report.md)
  reached on parts is now reached on the whole: **no memoisation, no native
  flood fill, no GDExtension.**
* **The computer's turn is a value, and `game` replays it.** `core` decides the
  whole turn in one call and returns an ordered event stream; the playback walks
  it with a timer and never reads the world, which is what makes skipping the
  replay free and unable to desynchronise anything. No new persisted state, and
  the canonical hash is unchanged.
* **`aExecuteMove` is bounded by the mover's movement points**, measured
  natively. Both implementations take a budget; the player's own move passes the
  unbounded sentinel, which is the behaviour the interface needs.
* **A stage can leave the converter alone.** This was the first with no
  `CONVERTER_VERSION` bump and no schema change — the second slice's save still
  loads — which is the shape the pipeline was designed for.

Of the other two, **the campaign layer** ([`27`](27-campaign.md)) is untouched,
which is why `_C_115` cannot be played even though it converts and draws; and
**bodies, animation and sound** ([`40`](40-charisma-model-animation.md),
[`41`](41-sequence-player.md), [`28`](28-effects-and-sound.md)) are still a
capsule and a ground marker.

Nothing remains from that list. The large-unit clearance was the last one, and
[`93` §11](93-slice-1-report.md) closed it: an earlier edition of this
paragraph said it "cannot be reached by writing a single byte", and it can —
the `size` column lives at a fixed offset in `SetUnitInfo`'s static table, so
writing that byte and calling the engine's own fill turns a mission with no
large unit into one that exercises the 3×3 clearance. The same technique
reaches `aExecuteUse`'s action points and the ladder cells no shipped map
contains.

The numbered specs also retain their own research questions:

* the numbered specs' own **Open questions** sections. Of the items still open
  there, the ones a remake would actually notice are the sprite libraries'
  transparent index and out-of-sprite anchors ([`60`](60-lib-sprites.md)),
  whether the engine applies the root `SkeletonNode`'s own matrix
  ([`40`](40-charisma-model-animation.md)), what the dialogue numbers select
  ([`27`](27-campaign.md)), and the fourth `SetCtrlMapInfo` column
  ([`26`](26-interaction.md)). The rest are names for behaviour that is already
  fully specified, or fields a converter carries through unchanged.

The exact Python packaging technology is deferred. The architectural part is
not: the converter must have a diagnosable first-run flow, never write into the
original installation, reject an unsupported source, produce its cache
transactionally and leave the previous valid cache usable after failure.

---

## 10. First vertical slice — **delivered**

> **Status: complete.** [`93`](93-slice-1-report.md) is the report: what was
> built, the oracle boundary each comparison actually reaches, the four things
> the live engine corrected in the specs, the measurements, and the exit
> criteria with how each is shown. The requirements below are kept verbatim,
> because they are what that report is a report against.
>
> It ran on `_C_115` (33 × 30, the smallest shipped map on which the climbing
> rule decides anything, and the strictest test of a `width`/`height`
> transposition since neither side is 40), with `_C_100` as a second entry and
> `_C_141` as the mission the native oracle was captured on.

The first slice proves one narrow path end to end rather than building a
framework for the whole remake. Use one representative campaign mission whose
terrain, objects, unit placement and reachability are already well covered by
the numbered specs.

### 7.11 Effects and sound — seven decisions, one since retracted

Recorded here rather than only in [`97`](97-slice-5-report.md), because each is
a choice the remake is committed to and not a finding.

**The effect clock is the gameplay clock.** A blob ticks once per displayed
frame in the original, and a `aPlay*Sequence` runs its loop against the same
tick. §7.10 established that frame as 20 fps for gameplay, so the blob pool and
the set-piece queue run at `CharismaState.FRAMES_PER_SECOND` and the bodies,
the particles and the lifts cannot drift apart. It is an **inference from a
measurement**, not a second measurement: what was measured is the gameplay
frame, and what is asserted is that the blob tick is that frame.

**The engine's trig tables ship in the cache; they are not regenerated.**
`TRIG.IMG` and `ATN.IMG` are one content across all 21 world sets, and the
converter copies them into `tables/trig.json` rather than letting GDScript
build them from the formula. [`70`](70-img-tables.md)'s first open question is
that the generation rounding is unknown and `img_tables.py` can only show the
formula agrees to **within one unit** — and one unit of a 4096-unit circle is
one unit of every angle built on it, which is the size of the thing
[`28` §7.4.2](28-effects-and-sound.md)'s orientation sweep measured. 12 KiB of
cache buys exactness against the engine; a formula would buy a number that is
almost right. This is why `CONVERTER_VERSION` moved to 0.11.0.

**The sprite blend is additive, on the strength of a name.** `Eng3d` exports
three zoom-bob entry points — `alpha_plus`, `alpha_minus` and `masked` — and
`a3DEngine.cpp` resolves all three at start-up, but **only `alpha_plus` is
ever called** ([`28` §7.3](28-effects-and-sound.md)). The other two import
slots are written by the resolver and read by nothing, so the entry point's
name is the only evidence there is. "Plus" is read as a saturating add, with
depth writing off. A native frame capture is what would settle it.

**~~Music plays the `Track` family.~~ Music plays `Arack`, and it is no longer
a decision.** This entry was a choice for exactly as long as it took to read the
right file. `music/` ships `Track02…20` and `Arack02…14`, byte-identical for
02–08 and different from 09 on — and `Incubation.exe`'s **import descriptor**
names `audio.dll` where the 1997 build named `WINMM.dll`, taking the nine
`winmm` entry points from it, while nothing at all imports `sound.dll`.
`audio.dll` is the shim built with `Arack`. See
[`28` §6.1](28-effects-and-sound.md); the remake plays what the game plays, and
this is kept in the list as a **retracted** decision rather than deleted,
because the useful lesson is that "the selector is inside a shim no tool reads"
was an assumption about where the answer lived.

**The sound pool is twenty slots, and a full pool drops.** [`28` §1.1](28-effects-and-sound.md)
shows the loader hands out a twenty-first buffer the play routine then refuses,
so slot 20 is allocated, filled, freed and never heard; sizing at twenty makes
that a counted drop instead of a silent allocation. The **drop itself is
reproduced** under §7.1's first half: a crowded turn losing a sound is output
the player perceives.

**Two of the compatibility flags are presentation and live outside
`World.compat_flags`.** §7.1 says every compatibility choice gets a stable
named flag, and it does — but `compat_flags` is item 6 of
`CanonicalHash.compute`, and `weapon_35_missing_sound` and
`unit_24_footstep_volume_original` change what is **heard** and no rule. An
audio preset that moved the simulation's hash would be a worse defect than
either of the two it reproduces, so the audio layer holds them under those
exact names. `technical_box_guard_original` stays in `core`, where it belongs,
because it does change the simulation. The rule this refines: **a flag lives
with the thing it changes.**

**The blob pool runs the shipped DirectDraw path's effects, not the
accelerated one's.** Kind 59's arm asks `0x00461E80` what display mode the
output system is in and spawns a **second** emitter only for one answer —
mode 3, the configuration whose surface comes from `Eng3d.dll`'s ordinal 67,
`_E3DCARD_open_3dcard_screen`, rather than from `aCreateMainDDObject`
([`97`](97-slice-5-report.md) §23.3). `BlobHooks.emitter_mode` is 0, so the
remake does not spawn it. That is now a decision with a reason rather than an
unset field: the mode a player without the accelerator got is the one being
reproduced, and it is also the mode a retail `Incubation.exe` runs at under
Wine, which is where every arm in this layer was measured. Behaving like mode
3 instead is a `compat_flags`-shaped option — one visible extra effect on one
kind — and would want the flag rather than a changed default.

### 10.1 Conversion

1. Point the converter at a read-only copy or installation of the supported GOG
   release; identify the edition and language without modifying it.
2. Decode only the mission and the transitive assets needed to display it. Emit
   portable geometry, images and versioned logical data plus a manifest with
   source fingerprints, converter version, cache-schema version and an asset
   inventory.
3. Write into a staging directory, validate every declared output and atomically
   publish it under `user://` only after completion. A killed or failed run must
   leave no cache that the game accepts as complete.
4. In development, materialise the same decoded result into a gitignored
   `res://generated/` fixture set so the map, mesh, skeleton and animation can be
   inspected. Diff the portable logical data, not the incidental Godot resource
   serialization.

### 10.2 Simulation boundary

1. Load the authored map into `MapResource` and initialise a separate complete
   `MapState` without exposing its mutable arrays to `game`.
2. Spawn the mission's initial units and expose immutable views sufficient to
   render the grid and occupancy.
3. Submit a select/movement-query command for one unit. Compute the move map
   without memoisation and return a value result containing the reachable cells
   and costs.
4. Let `game` render the terrain, placed scenery and units, then highlight that
   result. Scene nodes never become the authoritative position, occupancy or
   movement state.

### 10.3 Fidelity and persistence

1. Compare conversion results with the existing corpus/parser checks and compare
   reachability with the strongest oracle actually available for that case.
   Record whether the comparison is native-runtime, executable-Python,
   verified-static or specification-only.
2. Seed the RNG explicitly even if this slice does not consume it, establishing
   the state shape used by later trace comparisons.
3. Save a complete simulation snapshot, including the complete mutable map
   state, reload it and require an identical canonical state hash. Camera state
   may be included separately and must not affect that simulation hash.
4. Reject a truncated save, a save with an unknown schema version and a save
   whose authored-map hash does not match.

### 10.4 Measurements and exit criteria

Capture conversion time, cache size, Godot materialisation/load time, one full
move-map time and a representative complete AI-turn time as soon as it exists.
These measurements decide whether a different container, memoisation or a native
flood fill is justified.

The slice is complete when all of the following are demonstrated in an exported
build, not only in the editor:

* the original installation remains byte-for-byte untouched;
* two conversions of the same input produce equivalent canonical data;
* a partial cache is never accepted and a valid cache survives a failed update;
* the rendered map, scenery and initial units agree with the existing inspection
  tools for the selected mission;
* reachable cells and costs agree with their declared oracle boundary;
* save/load preserves the canonical simulation-state hash and the negative save
  cases fail cleanly;
* `core` has no scene-tree, rendering, audio, filesystem or engine-singleton
  dependency, and `game` cannot mutate its internal arrays;
* typed GDScript warnings selected for the core fail the build.

Only after this slice should the chosen portable containers and save schema be
promoted from provisional implementation choices into decisions in this file.
They have been: §3.2 for the container, §7.3 for the save.

Two facts about the original that the slice's rendering work established, and
that a later stage would otherwise rediscover:

* **Units are not drawn from `SetUnitInfo`'s model column.** Thirty of the
  thirty-six rows name `A_MK_0B.3DI`, which is four vertices and one face — a
  box ±1600 on X and Y at Z = 80, a one-field ground marker. Six inanimate types
  have a real model. The living bodies come through Charisma's hard-wired switch
  ([`40` §7.2](40-charisma-model-animation.md)).
* **There is no terrain surface in a `.lev`.** The ground lattice's prototype
  `S003_00X.3DI` is an octagon 320 world units across — a fifth of a metre, an
  editor marker for the cell centre, not a 3200-wide tile. The visible ground is
  the `.3DW` clones plus the special objects; the lattice only carries the
  height. Nothing has to be generated to fill the steps between heights, and
  those steps are correct rather than missing walls.

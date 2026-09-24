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
| a localised installation (§7.6) | `lang/<Name>/…` mirroring the neutral paths | the language-dependent subset only, byte-identical files dropped; names as an overlay in `lang/<Name>/names.json` |

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

The production cache normally lives under `user://`; it is player-owned generated
data and is not expected to appear in the editor's `res://` filesystem or
Inspector. During development the same conversion model can materialise a
gitignored `res://generated/` fixture set as Godot resources, glTF and PNG.
Those fixtures remain uncommitted. **Android is the explicit distribution
exception:** its export includes only `res://android_payload/cache`, rebuilt
from the supplied retail installation by `make android-cache`; the existing
startup fallback verifies that manifest before using it. Thus an installed APK
carries the full campaign and Instant Action data without first-run conversion
or a download, while inspection/test-only generated files remain out
of the package. The staging cache carries a build-only `.gdignore` marker, and
the Android export plugin writes every manifest entry as a raw file: PNG/WAV
cache entries therefore remain the exact manifest bytes rather than becoming
Godot imported resources.
Production and development outputs must describe the same decoded data even when
their containers differ.

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

### 5.1 Where an executable Python model is required, and where it is not (2026-09-04)

§5's rank 2 says Python "supplies **selected** data/function oracles" and is
"not described as the reference for every rule". Six slices later that sentence
needs a rule that can be applied to the seventh, because the twin is real work:
about **13 200** lines of `inclib` -- `combat`, `ai`, `lcl_runtime`,
`blob_creators`, `movemap`, `campaign`, `sound`, `interact`, `turn`, `ctrlmap`,
`eng3d`, `pose`, `allowance`, `script` and `rng` -- transcribe behaviour that
`core/` also implements, in about 29 900 lines of GDScript, and the
`*_runtime.py` check drivers over them are more.

**The criterion.** An executable Python model is required where a
specification's claim is **arithmetic that has to be run over the whole
corpus**. Where the claim is **structural**, a parser check plus a native
capture is the whole of it, and no twin is written.

**The rule, from this slice on: no new Python twin for a new subject.** The
existing ones stay. Nothing here changes the parsers, `convert.py`, the
`*_tables.py` binary readers or the `dbgcall` gold tools -- none of those has a
GDScript counterpart and none is duplicated work.

Three things the existing models carry that `core/` cannot, and that are the
reason they are frozen rather than retired:

* **The corpus.** `movemap_runtime` runs 3726 fills, 4587 paths and 4587 walks;
  `ai_runtime` 108 missions; `turn_runtime` 1863 units; `lcl_runtime` 942
  invocations. The Godot suites run against **six** converted missions, because
  `--dev-fixtures` is six. These are different orders of coverage, not the same
  check twice.
* **An oracle that needs no Wine.** Every fixture is gitignored
  (`.gitignore`: `tests/fixtures/*/*.json`; only the `README.md` beside each is
  in git). A Python-emitted fixture regenerates from the corpus alone; a native
  one needs Wine, an intermittent start ([`91` §1](91-wine-runtime-probes.md))
  and a copy of the game. Of the 34 suites, 11 take an executable-Python oracle
  and 8 a native one -- and on a fresh clone with the game installed, only the
  first 11 rebuild their own fixtures.
* **Measurement.** Line coverage of a transcribed arm (383 of 385,
  [`97` §21](97-slice-5-report.md)) and the mutation batteries are Python-side;
  Godot has no coverage tool. The battery mutates Python and re-runs the whole
  check set, which reaches the remake wherever a suite reads a re-emitted
  fixture -- [`97` §12](97-slice-5-report.md) records a re-run that found a
  defect in `BlobPool` rather than in the model.

**First application: the sequence player** ([`41`](41-sequence-player.md)). Its
claims are structural -- a compiled manifest, a lifecycle, a 30 fps clock --
and `seq_parse.py --check` already pins them over 130/130 files with 75 checks.
So the seventh slice writes the player in GDScript with a specification-only or
native suite, and **no `inclib/seq_runtime.py`**.

**Where retirement would be cheap, if it is ever wanted.** A subject that has a
native capture and no corpus dimension: the blob pool (`test_blob` and
`test_blob_native` stand on the same material) and the campaign, once
`campaign_gold.py` exists. Neither is proposed here; both are named so a later
reader does not have to re-derive the shortlist.

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
  volume of the identical type's ([`28` §5](28-effects-and-sound.md));
* `aExecuteBomb` omitting `Bea'Coo`'s special-16 death ring, although the
  ordinary attack resolver runs it ([`22` §7.3](22-combat-and-visibility.md)).
  Under `Faithful`, the `beacoo_mine_death_blast` correction flag is absent and
  keeps the omission; with the preset off, every `Bea'Coo` death produces the
  same ring.

Under the second half, fixed unconditionally and with no setting:

* the alien scream, scaled by the **human** volume ids
  ([`28` §4.1](28-effects-and-sound.md)). The defect leaves ids 53–55 defined
  and dead, so an "alien voices" control in the remake's audio options would do
  nothing. That is the inert-control case, not a period detail.

And one place where the **picture** beats the **listing** (2026-09-07): the
ground overlay's hit-point digit over a unit ([`43` D12](43-battle-hud.md)).
The bytes draw it over every current-player unit with points left; the
original, watched, draws none over a fresh squad. Until the gate the reading
misses is found, the remake draws none — the observed original is the
original, and a mark nobody has ever seen in play is not a period detail to
keep.

One user-facing preset covers the whole first list — `Faithful`, on by default —
not one setting per defect. Internally, however, every compatibility choice has
a stable named flag, for example `technical_box_guard_original`,
`weapon_35_missing_sound` and `unit_24_footstep_volume_original`. Corrections
whose absence is the original rule use a positive flag instead; the first is
`beacoo_mine_death_blast`. Saves, replays and fidelity tests record the
individual flags rather than only the preset name; this lets the preset grow
without silently changing an old session.

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

**A campaign save is a container over this one** ([§7.13](#713-the-campaign--twelve-decisions-2026-09-04) D10): `SaveCodec` refuses a
blob whose map name is not the world's, which is exactly right for a mission
save and exactly wrong for a campaign that outlives one, so the campaign
document is its own and a mission in progress rides inside it as an opaque
blob. The **flat-write defect** [`11` §5.7](11-save-game-format.md) records —
the pool's second row losing its last slot to a 5460-byte write over a
`[5][31]` array — therefore does **not** reproduce here, and saying so
explicitly matters: under §7.1's faithful-by-default rule it would otherwise
read as a defect this remake keeps. It is not reproduced because the remake's
save is its own format and stores the two rows as two lists.

**The header carries the picture's own state beside the simulation, outside
the canonical hash.** The camera was the first such field; since 2026-09-06
the scenery's pose record is the second ([`42` §8.3](42-mission-presentation.md)):
the joint triples the door's family turned away from the `.lev`'s and the
cells whose objects a crush wall or a footbridge freed, which the original
keeps by embedding the special-object records in its `.sav` and which a
remake save without them showed authored again on a load. `core` writes and
reads it back as an opaque dictionary (`World.restored_scenery`), and `game`
is what puts it on the scene.

The camera was **first** and was for a long time the emptier of the two: the
field was in the header and in the codec's own checks from the beginning, and
every writer in `game` passed `{}` into it, so "the camera persists across a
save" held of the format and not of the game. Both halves are wired since
2026-09-06 -- `CameraRig.state()` into the blob, `apply_state` after the
load's redraw -- and `test_effects.gd`'s `resume.*` writes a real slot file
and reads the view back out of it. A field a format defines and nothing fills
is worth checking for: it passes every test the codec has.

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

**The schema numbers, brought up to date** — the narrative above stopped at 6
while the constant had reached 9, which is the shape of a version field nobody
can read. `SaveCodec.SCHEMA_VERSION` continued 7 when the kill counter `+0x53`
joined the unit record ([`22` §7.5](22-combat-and-visibility.md)), 8 when the
cell placers of [`42` §9.1](42-mission-presentation.md) gave `MapState` the
glow's `+0x12` and `+0x13` and made an authored mine detonate under a walker,
and **9** with the campaign slice: `TurnState` gained the three per-mission
counters the scoreboard reads — `mission_kills`, `mission_lost`,
`mission_lost_to_enemy` — so that the debriefing stops summing survivors, a sum
that lost every kill made by a unit which later died. Those three are in the
save and **out** of the canonical hash, so D7 holds. The reason for 9 is
recovered from the commit that made it (`Slice 6: the campaign scoreboard has
no unknown fields`) and not reconstructed from the number.

10 and 11 are in `save_codec.gd`'s own note (the derived-stat recompute's
`recruit_ammo`, then the scenery's poses beside the camera). **12**
(2026-09-24) put the special-object table `[0x004FA80C]` into `MapState`:
`GrowingLand`, `FallingSpores` and `Spores` refuse above 140 records and search
it, and `CrushWall`, both footbridges and `GroundUnit` change it, so it is
simulation -- hashed, saved, carried by the journal's deltas -- and the loader
pins in `test_campaign.gd` moved with it, once and on purpose. **A schema-11
save is still read**, the one exception to "refused by name": its table is
rebuilt from the `.lev`, less the objects on the cells the scenery record lists
as emptied and plus the objects it lists as inserted, because those two lists
are everything a schema-11 run could have done to the table. What that cannot
recover, it does not guess: a platform deck's move is not a table change the
remake models ([`20` §10 item 12](20-lcl-language.md)).

`CampaignCodec.SCHEMA_VERSION` is a different field with its own history, and
the shell slice raised it 1 → **2**: the container document gained the stamp a
slot row shows, and the campaign state moved under its own key so a header read
never has to know what is beside it. The stamp is **two fields**, `saved_at` in
Unix seconds and `saved_at_text` as the writer's own clock said it. Two rather
than one because `core` may not call `Time` at all
(`godot/tests/test_isolation.gd`), so the offset that turns the first into the
second is not available on that side: the number orders slots, the string is
what a row shows, and `game/` is the only place that reads a clock.

What is still a checklist rather than a decision: migration between schema
versions has a version field but no migration to test. The compatibility
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

So: **four fixed orientations, ~~rotated in 90° steps~~.** Free rotation would show
faces at angles no one composed. Zoom is free within the
height range the mission header gives ([`10` §3](10-lev-mission-format.md), 1600
units = 1 m), ~~pitch is fixed~~, and the camera persists across a save — the
original had no field for it and reset the view on load
([`11` §5.6](11-save-game-format.md)), so keeping it is a free improvement
rather than an infidelity.

*(Corrected 2026-09-02, model A of [`97` §28](97-slice-5-report.md).)* The
engine's four orientations are its **view quadrant** `0x00510700`, and
[`42` §2.3](42-mission-presentation.md) read what a quadrant is: the eye goes
to a corner of a `(dist + 6) × dist` rectangle about the unit — 14 × 8 m for
the "on the unit" view, about 30° off the x axis — at `(height + 3)` metres
over its head. The four corners are the discrete orientations this decision
keeps; they are **not** quarter turns, and Left and Right step round the rectangle
by mirroring the offset. Pitch is no longer fixed: it is whatever the
engine's placement gives, and the placements differ (§2.3's table). The
statistic above still holds and still matters — the scenery is authored for
quarter turns and the engine's own player looked at it from 30° off axis —
so the quadrant placements remain available on Left/Right. As of 2026-09-10,
right-drag also turns the view freely at a fixed eye, with eight angle units
per pixel and pitch limited to +/-90 degrees. Option/Alt plus primary drag
or a two-finger pan gesture provides trackpad access. Free look applies
immediately; scripted placements retain the engine's flight (`0x0040EEE0`).
The remake reconstructs a look target and saves optional `look_angles` to
preserve yaw at the vertical poles; the original stores angles independently.

### 7.5.1 The view opens on the squad, not on the middle of the map

`CameraRig.setup` parked the pivot on the centre cell at the mission's authored
`camera_height`. On `_C_140` the centre cell is inside a support column and the
authored height is 20 m, which is **above the level's roof** — these maps are
interiors — so the first frame of the game was a pillar seen through a ceiling.
The original shows the squad, close.

So the view opens on **one unit's cell** — not the squad's centroid, which is
not a cell anybody stands on and which on `_C_140` lands inside the wall
between four marines — ~~at 8 m rather than at the authored maximum~~. The maximum
is untouched and the yaw is left to the player. This is where the view starts,
not a new limit, and it changes no hash.

*(2026-09-02: the opening is now the engine's own "on the unit" placement,
`0x004529D0(8, 7, 0)` from quadrant 0 with the free-position search and the
box clamp — [`42` §2.3](42-mission-presentation.md). The 8 m was a remake
number chosen against a roof drawn from above; what the engine does near a
map edge is in `97` §28.)*

### 7.6 Localisation — the GOG base and language packs laid over it

Only `English` ships in the GOG release, and the engine's whole notion of a
language is **a directory name**: a command-line switch (`-english`,
`-german`, `-french`, `-japanese`, `-spanish`, `-italian`; parser `0x004494C0`
in `aMain.cpp`) becomes a 1-based code in `[0x50DC1C]` (default 1), the jump
table at `0x44A4D8` turns the code into a name literal (`English` 1, `German`
2, `French` 3, `Japanese` 7, `Spanish` 8, `Italian` 9; codes 4–6 fall to
`"unknown"`), the setter `0x453DC0` stores it and `aGetLanguage` `0x453DF0`
returns it — only ever to fill the `%s` of three `wsprintf` templates
(`%sTXT\%s\Briefing\%s.txt`, `%s%s\Info\%s.txt`, `TXT\%s\GUI\%s`). Fonts,
`Info.lcl`, `Menu_*.lcl`, the interface `.LIB`s, the speech and the `.lev`
unit names are loaded by literal name, so a localised release **replaced them
in place**. `-debugx` forces `English`. GOG launches `Launcher.exe -english
-directx`, so the repository's `-english` is a no-op. All of it is pinned
byte by byte by `tools/language_tables.py --check` (`make check-formats`);
the table is `inclib/language.py` ([`24` §1](24-briefing-text.md)).

**The second release is in hand.** The licensed Russian release (1C/Snowball,
the *Wilderness* edition "Второй десант", `Version.gcl` 1.50e) was diffed
file by file against the GOG tree on 2026-09-13, by hand and with no automated
check behind the following:

* **Localised, at the same paths, in cp1251**: `DATA/TXT/English/{GUI,
  Briefing,Info}` (116 briefings, 9 banks, 4 info files; id sets identical
  except `Txtmod_a` ends at 298 — the credits' `END` — where GOG runs to
  339), `DATA/Info.lcl` (names only), `Libs/font_0..3.LIB` (224 Cyrillic
  glyphs), `Libs/{buttons,options,uicons,sm,dir}.LIB` (same element counts),
  `Graphics/Title.bmp` (**the Wilderness title**; there is no
  `Install/Title.bmp`), 9 `Graphics/Briefing/*.bmp`, every `Briefing/*.wav`,
  227 of 332 `Waves/`, `Video/Seq_4/Textures/*`, and every `Missions/*.lev`
  (unit names; **eight maps also in an older authored state**: `_C_140`,
  `_C_142`, `_C_144`, `_C_149`, `_C_159`, `_C_166`, `_C_167`, `_M_019` differ
  in cells, objects or record stats beyond the names).
* **Not localisation**: seven `Missions/_C_1xx.lcl` differ in *logic*
  (`_C_154` rewritten, `_C_153` unit counts, `_C_142/156/157` variables) —
  GOG carries the patches. The code is in **`Incubation.dll`, another
  build**, so the "same build?" question below is answered: no. It carries
  "Солдат %d" for `0x00478A47`'s "Soldier %d". No `music/`.
* `Txtmod_a.lcl` ends with a DOS end-of-file mark (`0x1A`) *inside* the
  obfuscated stream after `[END]`; the parser now treats bytes after the
  final `[END]` as one unreachable-tail warning ([`20` §6](20-lcl-language.md)).
* The GOG English text holds no byte in 0x80–0x9F (only `§` 0xA7), so
  decoding it through a code page changes no English string.

**The decision: the GOG root is the only source of gameplay data; a
localisation is a language pack.** `remake_convert.py --language-pack
Russian=<root>` converts the language-dependent subset out of a second tree
and lays it over the cache under `lang/<Name>/`, **mirroring the neutral
relative paths** (`lang/Russian/text/gui.json`, `lang/Russian/fonts/…`,
`lang/Russian/art/…`, `lang/Russian/audio/…`, `lang/Russian/names.json`).
One cache holds every language; switching needs no second cache; exports
bundle the packs. Consequences:

* **Every file list is the base's.** The pack tree is asked for a
  counterpart of each base briefing, bank, font, plate, library and wave; a
  missing one is a warning and the neutral copy serves -- for the art,
  which is looked up by name out of `art/index.json` rather than by path,
  the pack's index is completed with the neutral entries it lacks
  (`_complete_art_index`; `pack.art.index_complete` pins it on a synthetic
  pack one briefing picture short). A pack file the base
  does not have is never baked, and a case-drifted pack filename lands under
  the base's cache name. Every pack file byte-identical to its neutral twin
  is dropped (1 539 of the Russian pack's 1 941; 402 stay).
* **The pack reader never opens** a mission script, `WorldSet/`, `CHData/`,
  `Video/`, an executable or the music. `Seq_4`'s localised textures are a
  documented limitation: the cutscene's title card stays the base language's.
* **The guard.** `Info.lcl` is compared as `BalanceTables.to_dict()` with the
  four name columns blanked; any other field differing refuses the pack with
  the file and field named (`key`, the `Data.txt` page letter, is *not* a
  name column — the 1C release keeps the base's letters). A `.lev` lends a
  unit name **only to a record that is otherwise byte-identical** (`+0x56`,
  the stale animation handle, excepted); a slot whose record differs keeps
  the base's name and the file is named in one warning with its byte count.
  That is what lets the eight older Russian maps contribute their names
  while their cells, objects and stats stay out. The plan had a whole-file
  refusal here; the eight maps made it a per-record rule, and the rule was
  confirmed as the decision on 2026-09-13 (six slots keep the base's names:
  `_C_142` 3 and 4, `_C_166` 8, 13 and 15, `_M_019` 0).
* **Names are an overlay, and enter no hash.** `lang/<N>/names.json` carries
  the pack's unit, weapon, equipment and cell-type names by id and its unit
  names by mission and slot. `CachePaths.apply_balance_names` writes them
  over `tables/balance.json` once, in `SliceMain._ready`, before any
  `World.create` — `UnitState.generate` fills spawned names from
  `types.description` — and `apply_unit_names` over each `map.json` at both
  `World.create` sites. `UnitState.hash_into` and the campaign digest skip
  `name`, so a switch moves no canonical hash and orphans no save; a save
  keeps the names it was made with ("Солдат 1" under English), exactly as
  the original's `.sav` would.
* **The code page is per language and reaches the fonts.** A font is 224
  elements indexed `byte - 32`; the cache now writes both `byte` and the
  Unicode `codepoint` it stands for under the release's page
  (`inclib.language.codepoint`; undefined bytes decode to their own value),
  and `GameFont` registers by code point. Text is decoded through the same
  rule, so a briefing byte and its glyph cannot disagree. cp1252 for German,
  French, Spanish and Italian is **UNVERIFIED** — table rows only; the
  Japanese two-byte path stays unimplemented ([`24` §4.4](24-briefing-text.md)).
* **Per-id text fallback.** `Localization` loads the pack catalogue *and*
  the neutral one; an id the pack's bank lacks reads the neutral entry before
  the `??` marker. The Russian `Txtmod_a` 299..339 therefore never renders
  and the credits stop at `END`; the rule is general.
* **Briefings need no layout work**: the cache holds spans, `BriefingText`
  wraps at render time with the loaded faces, so Cyrillic wraps by
  construction.
* **Remake-own strings get a column**: `Localization.LANGUAGES` is
  `["English", "Russian"]` and a suite pins every `OWN` key in every column.
  The recruit name format left `core`: `Roster.recruit_name_format` defaults
  to the engine's literal and `CampaignHost` sets it from
  `roster.recruit_name` wherever a `CampaignState` comes to exist.

**Choosing and switching.** `CachePaths` (`game/cache_paths.gd`) is built from
the manifest's inventory — no filesystem probe — and answers, per file, the
pack path or the neutral one; every loader in `game/` takes it instead of a
bare directory. Precedence at boot: the restart's own choice parked on the
root `Window`'s metadata (consumed once) → `--language=` → `settings.language`
(empty means the base; no schema bump) → the base. A language the cache lacks
falls back to the base with a warning. The options screen's language line
becomes a row when the manifest names more than one language and the player
is out of a mission; stepping it writes the setting and **reloads the scene**
(`SliceMain._restart`: audio shut down over its frames, the agent's parked
reply drained, then `reload_current_scene` through `reload_hook`). Mid-mission
the line stays a line, gated like the difficulty, because the reload would
drop the unsaved mission. `/state` gains `language`. `FIRST_RUN_HINT` and the
fatal-error overlay stay English: they render before a catalogue exists.

**The recipe** (outside `make test`, like `--check-campaign`):

```
unshield -O -d <scratch>/iwm_ru x ".../iso_ru/IWM_files/data1.cab"
python3 tools/remake_convert.py gog_incubation --campaign-maps --instant-action-maps \
    --language-pack Russian=<scratch>/iwm_ru/ProgramFiles \
    --plate Russian:wilderness_title=<scratch>/iwm_ru/ProgramFiles/Graphics/Title.bmp \
    --plate Russian:title=".../iso_ru/Incubation_files/Incubation/Graphics/Title.bmp" \
    -o "<caches>"
godot --path godot -- --language=Russian --agent-port=8787
```

`make android-cache LANGUAGE_PACKS="--language-pack Russian=… --plate …"`
folds the packs into the payload key; without it the APK ships the base
language only.

**What is checked where.** `language_tables.py --check`: the switch chain.
`remake_convert.py --check`: a synthetic German pack built out of the base
tree — the mirror, the dedup, the per-id bank warning, the per-record `.lev`
guard, the `Info.lcl` refusal, the same-root refusal, the fonts' code points.
`--check-cache`: the prefixed reader, both guards on hand-built data, the
merge. `test_cache.gd`: `CachePaths` and both overlays; `test_game_ui.gd`:
every `OWN` key in every column, Russian without markers, the per-id
fallback; `test_shell.gd`: the row with 1 vs 2 languages, the switch through
`reload_hook`, `--language=`.

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
  those are the player's, on Left, Right and the wheel — so this moves the pivot and
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

~~A pan is still not implemented.~~ *(2026-09-02: the middle-drag pan of `42`
§2.5 is in, on the engine's numbers.)* ~~The original does not need one either: it
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

**Revised 2026-09-03** ([`97` §34.2](97-slice-5-report.md)): the default is
now the engine's, which is to move no camera at all on hand-over. The
measurement above stands and is why the behaviour survives -- behind
`SliceMain.COMPAT_CAMERA_RETURNS` -- rather than why it is the default. The
reason is the presentation plan's principle: where the remake and the
original differ, the original is the standard, and a player who cannot see
their squad can still reach it with the cycle key.

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

**Revised 2026-09-03** ([`97` §34.2](97-slice-5-report.md)): the default is
now the engine's, which is that the probe's wake **sticks**. The reading
below is unchanged -- the save and restore cover `+0x4F` and not the
promoted orders, and that is a defect -- but reproducing it costs the
player no control, so it is reproduced. `World.COMPAT_FOG_PROBE_QUIET`
restores the quiet probe this section used to describe.


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
| `0x004149C7` | the **spore hatch** `0x004147D0` — *not* `FixedStatue`, which was a wrong routine boundary ([`22` §9.4.3](22-combat-and-visibility.md)) | **recorded**: the site is not a bare rebuild. It follows `aDeleteLand` and an `aGenerateUnitElement` that spawns a unit of the type the LCL command supplies — `Spores`' third argument, or the constant 50 from `MoveSpores`. Only two commands reach it. `Spores` -- one shipped mission, `_C_174`, which the cache carries -- is implemented since 2026-09-24 with its three-in-fifteen draw, its box search and its fog rebuild for player 0 ([`20` §7.4](20-lcl-language.md)); `MoveSpores` has no shipped call |
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
Following the bug is not the same as following the original. *(The bug is
measured now, 2026-09-13 — [`40` §4.8](40-charisma-model-animation.md):
sixty limiter calls take 1622 ms inside the live executable, 27 ms a call,
so six frames of a field are 0.16 s on a host that renders for free; the
decision above stands.)*

One neighbouring quantity is still a decision, and is named rather than folded
into an expression:

* **`WALK_SECONDS_PER_STEP` = `FRAMES_PER_FIELD / FRAMES_PER_SECOND` = 0.3 s.**
  Derived, not chosen. What *is* chosen is that
  `AIPlayback.STEP_SECONDS` became a **floor** rather than the whole rule: an
  event may ask for longer, and a move asks for its walk, because at the
  engine's own pace a move of more than one field outlasts the old fixed
  window and the next event's rebuild would cut the walk in half. `skip()`
  still means "stop drawing" rather than "stop simulating".
* ~~**`M` loops while a unit walks and `S` resumes when nothing else plays.**~~
  **Revised 2026-09-03.** [`42` §1.2](42-mission-presentation.md) decompiled
  the start slot: `M` loops (`+0x44(100000)`) at speed **2.0**, `F` plays once
  at **6.0** to its `BREAK` note and is resumed past it by the fight routine,
  `S` plays once at **1.5** and is a scheduler's, not a loop's ([`42` §6](42-mission-presentation.md)).
  `CharismaState` carries the three speeds and the resume; the idle scheduler
  is the next slice's. `kind == 4` and its one fixed literal `P0_M2_000`
  (speed 1.0) are not implemented at all.

What is **not** a choice, and is measured, is the bone-to-mesh scale of 16
([`40` §5.3](40-charisma-model-animation.md)) and the `BREAK` note that stops a
combat animation ([`40` §9](40-charisma-model-animation.md)).

### 7.11 Effects and sound — nine decisions, one since retracted

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

**A seeker whose target is gone is removed, not left standing** *(2026-09-24,
a deliberate divergence)*. Kinds 26, 27 and 61 find their target through
`aGetUnitMapElementPtr`, whose null for a dead unit aborts the arm
([`28` §7.7.1](28-effects-and-sound.md)) — but only after the wrapper has
taken the tick's `life`, so the round freezes where it is and hangs in the air
until its life runs out, a hundred ticks for weapon 11's arcs. Weapon 11 makes
it the ordinary case: the first round to arrive raises the flag, the death
stage lands every casualty on the mirror (§7.17), and the other arcs' rounds
are left standing for five seconds as motionless rods. `BlobPool.drops_orphaned_seekers`
deletes such a record on the tick its arm reports the missing target. It is
off by default, so `test_blob.gd`'s per-tick diff still steps the engine's
arm; only the mission's pool turns it on. Not a `compat_flags` option: the
frozen round is output no player would choose.

**Nor is a seeker drawn before its arm has turned it** *(2026-09-24, a
deliberate divergence)*. The creators of kinds 26, 27 and 61
(`aBlob_CreateGrenade` `0x00426070`, `aBlob_EnergyCannon` `0x004264A0`) push a
**zero** rotation; the arm points the record along its step on every tick. The
engine's sweep draws a record before it updates it — `0x0041E43D` (the draw,
gated on `delay == 0` and class 0/1) ahead of `0x0041E44B` (`aBlob_Update`) —
so every round's first drawn frame, and the frame each of weapon 11's delayed
rounds comes due, shows the rod at the muzzle along engine +Y whatever the
line of fire: across it for a target east or west, backwards for one south.
That was one frame at the original's rate and is a twentieth of a second per
round at the remake's twenty ticks, six times an arc. `BlobModels` holds a
seeker back until `Blob.dispatched`, which `BlobPool.tick_all` sets the first
time the arm runs. Measured live on `_C_168` (weapon 11 against the aliens
at (2..4, 6..7)): in flight every record's `rot_z` tracks its step, and only
the rounds still at the spawn point carry `(0, 0, 0)`.

**A shot's play-out does not wait for effects that have left the map**
*(2026-09-24, a deliberate divergence)*. The engine's play-out spins until
`0x004FE640` reaches zero ([`42` §4.9](42-mission-presentation.md)). A fire
explosion's kind-75 fragments fly off the world within a few ticks, because
the engine gives each child the parent's *position* as its velocity. They keep
that count up for all seven generations of the cascade anyway
([`28` §7.7.2](28-effects-and-sound.md)). On `_C_174`, Mine Thrower Enhanced's
eighteen blasts filled the pool and left about two seconds with nothing
visible moving and the interface locked, which read as a hang.
`ShotSequence._settled` asks `ShotHost.pool_live_on_map` instead, and the scene
answers it with `BlobPool.live_on_map`: the same classes the sweep counts, less
any record outside the map's footprint widened by its longer side on every
side, or further than that above or below the ground. The records are **not**
deleted. They tick on and hold their pool slots as the engine's do, so
`test_blob.gd`'s per-tick diff and a crowded pool's drops are unchanged. Only
the moment the shot hands control back moves. The bounded 20-frame pool stage
and the set-piece sequences still read the engine's counter. Not a
`compat_flags` option: the empty wait is output no player would choose.

### 7.12 The environment's objects — three decisions and one correction (2026-09-03)

Slice E of the presentation plan ([`97` §37](97-slice-5-report.md)) put the
four cell placers of [`42` §9.1](42-mission-presentation.md) into `core`. Three
things about that are the remake's and one is a correction to what this
document said before.

**The obstacle byte is a rule; the object's position is a picture — but it is
still the engine's.** `core` draws nothing: it writes `+0x0E`..`+0x13` and
takes a slot in the 80-entry array, because those decide movement and the
mine's detonation. Where the object *goes* is
`CellObjects.object_position`, which the picture calls with the presentation's
own generator — the mine and the shield take the cell's object position
exactly and the fire and the glow scatter around it with `aRandom2(-300, 600)`
twice. *(Revised 2026-09-03, [`97` §38.4](97-slice-5-report.md): this
paragraph first said the picture put each object at its cell's centre and that
the centre was the remake's. The eight `special_*` phases read every record's
position back and the arithmetic is the engine's, origin included — the cell's
**corner**, not its centre.)*

**The 80-slot array is derived and is neither hashed nor saved.**
`aBuild3DSpecialObjects` `0x004079D0` rebuilds it from the same cell bytes
after every load, so `MapState.rebuild_objects()` runs at both loading
boundaries. Storing it would be storing the same fact twice, and the two would
drift the way the obstacle byte once did (§7.2).

**A placer model the world set does not carry is a refusal, not a warning.**
`MapState` gates on the geometry document's `special_models`, so a
`SetGroundFire` outside `World_D00` writes nothing — which is what the engine
does, measured. A world built with no model list skips the gate, and that is
right for a synthetic test map and wrong for a mission.

**Corrected:** the entry point (`docs/26`, action point 70) used to drop the
cell's height by `0xA0` and write `6` into the obstacle byte. Neither is the
engine's: the `- 0xA0` is the fire placer's z argument and reaches only its
height window, the `6` is the fire's subtype, and the byte the placer writes is
`1`. `SaveCodec.SCHEMA_VERSION` went to 8 with the two new effect columns and
the mine detonation, and both `CONVERTER_VERSION`s to 0.15.0.

**A fifth placer, and it is the mission's target (2026-09-07).** The
victory-point marker placer `0x00431E30` ([`42` §9.3](42-mission-presentation.md))
stands a static `A_MK_*` object on every cell whose action point is 80..89 —
the red *A* on `_C_102`'s two `UnitOnField` cells — and the remake had none of
it. The same split as above: `MapState.rebuild_markers` is the occupancy (the
first free slot after the cells' own objects, at load and after a walk's
claim; `+0x14` is derived and neither hashed nor saved), and `SpecialObjects`
draws the marker **from the action-point plane alone**, keyed by the cell
rather than by the slot, because the mirror the picture reads gets a claim as
an action-point delta and nothing else. The converter asks every world set for
all ten models, since a capture can turn any letter into any player's;
`CONVERTER_VERSION` 0.25.0.

---

### 7.13 The campaign — thirteen decisions (2026-09-04)

The sixth slice's, and the first place this document has had to decide
anything about a layer that outlives a mission. [`98`](98-slice-6-report.md)
reports the slice; these are the choices no evidence settles.

| # | Decision | Why |
|---|---|---|
| D1 | The **campaign number** is the first field of the campaign's state, and it selects the seed, the first mission, the map and the band of locations | all four are switches on it in `aInitGameControl`'s campaign arm ([`27` §2.1, §6.6](27-campaign.md)) |
| D2 | Pool row 0 is live and row 1 is an **explicit snapshot**, living until the debriefing ends; *replay* is a debriefing button | [`27` §3.5](27-campaign.md) as corrected, and [`27` §8](27-campaign.md) item 4 allows "the same thing with an explicit snapshot" |
| D3 | The campaign map is `_C_XXX`/`_C_YYY` through the **existing renderer**, and its `.lcl` is not run | [`27` §8](27-campaign.md) permits a remake's own map; there is already a renderer, and a campaign map's script is the original front end's |
| D4 | Deployment cells come from `MapState`, with no parallel list | [`29` §1.2](29-interface-contract.md): the action-point byte is cell state a mission can rewrite, and a second list would drift from it |
| D5 | ~~Dialogue locations open, are **named**, and play nothing~~ **Closed 2026-09-08** (§7.19): they play framed over `plate_7`, the intro plays once, both endings play | the sequence player is [`41`](41-sequence-player.md)'s, delivered in the ninth slice |
| D6 | The 3↔6 upgrade crossing is reproduced as it is | [`27` §2.4](27-campaign.md): shipped behaviour, and §7.1's default |
| D7 | `CanonicalHash` does not move; the campaign carries its own digest | otherwise every hash the first five slices pinned changes. Verified rather than assumed: three mission hashes measured on the commit before the slice are pinned as literals in `test_campaign.gd` |
| D8 | A recruit's voice is drawn from a **deterministic** stream, not the engine's `GetTickCount`-seeded one | a save has to reproduce. The engine's `aRandom(1, 6)` here comes from `0x004638E0`, which is seeded from the clock ([`28` §3.2](28-effects-and-sound.md)). The same holds for a unit `aGenerateUnitElement` spawns for a player other than 255 ([`20` §7.4](20-lcl-language.md)): `World.speech` is its stand-in, seeded 1.0 and not saved; no shipped script spawns for such a player |
| D9 | The converter's `--check` stays on six missions; a full campaign bake is `--check-campaign` | `--check` runs **three** full conversions; the campaign set is fifteen times the slice's maps — 26 s and 86 MiB against 4 s and 42 MiB before slice 9; 30 s and 200 MiB against 23 s and 153 MiB after it, the cutscenes being in every selection (§7.19 I12) |
| D10 | The campaign save is a container **over** `SaveCodec`, and the file write lives in `game/` | `SaveCodec` refuses a blob whose map name is not the world's, which is right for a mission and wrong for a campaign; and `core/` never touches the filesystem |
| D11 | Equipment points, tech level and skill level are **campaign** state; entering a mission does not apply the header | [`27` §4, §5.2](27-campaign.md) as corrected — the header's fields are the single-mission front end's |
| D12 | `tables/campaign.json` carries **lists of records**, not objects keyed by id | a JSON object's key is a string and the cache must carry integers; `inclib/info.py` set the precedent, and `tables/balance.json`'s `equipment` — which has no id 2, so a position is not an id — is the trap |
| D13 | *Try Again* undoes the debriefing's **payout** as well as the mission: after the engine's own five lines — `0x0043BBD0` takes the mission's kills, losses, lost-to-an-enemy count and score back off the campaign halves and the death medals (`0x0043B860`'s one per unit lost to an enemy) off the commendation counter — the remake also takes back the equipment points and commendations that slots 10 and 11 paid (what landed, the purse being capped) | the engine's `0x0045E9CB` is `aCopyUnitPool(1, 0)` + `0x0043BBD0` ([`27` §6.6](27-campaign.md)), which restores the roster and the scoreboard and leaves the payout where it landed — and the button is offered after a win too, so a replayed win pays its bonus twice. A free purse on a button meant as a do-over is the one thing the rollback is inconsistent about; the remake finishes the thought (`CampaignHost.replay`). *(Rewritten 2026-09-13: this row used to say the engine restores the roster "and nothing else"; the scoreboard rollback the remake carried as its own decision is the engine's.)* |

### 7.14 An arm's spawn request is run in a mission, and the pool ticks before the queue (2026-09-04)

Two decisions the `ParaBombs` set piece forced, both about the seam between
the blob pool and everything that watches it.

**A mission runs an arm's spawn request; the diff still records it.**
`BlobKinds._spawn` is the arms' own `aBlob_Create*` call, and `BlobHooks`
answered it by writing the request down and returning success. That is exactly
what an oracle wants — `test_blob.gd` compares the request and
`blob_runtime.py` records the same one, arm for arm — and it is not what a
game wants: the child effect never reached the pool, so an arm that throws
debris threw nothing and the *arrived* flag of [`42` §4.6](42-mission-presentation.md)
had nothing to raise it. `game/fx/game_blob_hooks.gd` is a subclass that runs
the creator **inline**, where the arm calls it, so it draws from the one
`aRandom2` stream at that moment and its record lands in the first free slot —
which `aCheckInBlobObjects` `0x0041E3D0` visits later in the same sweep when
the slot is above the one being ticked, and not at all when it is below.
`BlobPool.tick_all` walks by index for that reason. The base class is
untouched, so the oracle's contract is untouched. It holds the pool through
`weakref`: the pool owns its hooks, so a strong pointer back is a reference
cycle, and Godot counts references rather than collecting them. The run then
ends with `ERROR: N resources still in use at exit` — the leaked objects'
scripts — which `run_tests.sh` gates on, and exits non-zero with all 3150
checks green. That exit status is how this one was found.

**Thirteen creator addresses are reachable from an arm and all thirteen are
transcribed** ([`97` §49](97-slice-5-report.md)). Twelve of them were reached
from nowhere else in the game — no weapon switch names them and no set piece
calls them — so nothing had needed them before `GameBlobHooks` ran a request,
and a request found no program and made nothing, which is what the whole layer
used to do. They were not read off the disassembly and left there: two capture
families step every arm that asks for one, with the second generator's seed
written and the pool read wide enough to hold the child, and both twins are
compared against the records the engine left. That found six more corrections
in four arms — including an arm that drew once too often, which is wrong about
**every other arm's** record in the same frame, the sweep sharing one
`aRandom2`.

**The pool ticks before the sequence queue, and the picture is drawn after
both.** Every `aPlay*Sequence` is a loop whose body does its work, calls the
frame tick `0x0040B6F0` and reads what the tick left on the next instruction —
the bomb run `0x004160F0` asks `0x0042B480` immediately after its tick. A
queue advanced before the pool reads the previous frame's answer, so a sound
chosen by a flag lands a frame after the thing that raised it. `Main._process`
therefore runs `_tick_effects`, then the queue, then `_draw_effects` — which
also puts a record spawned by this frame's sequence on the screen in this
frame rather than the next. The order is verified by reading: `Main` is a
scene node and no suite instantiates it.

### 7.15 The shell — what makes six slices reachable (2026-09-04)

Six slices built a game that no person could start. `campaign.start_new()` had
exactly one caller in the whole project — the outside driver, which the shipping
preset excluded (§7.16 replaced it on 2026-09-06) — so a built game went
straight into `_C_140`, `campaign.state`
stayed `null`, and the campaign layer of §7.13 was reachable only from a test
driver. There was no menu, no chain to choose, one save file on `F5`, and no
options screen at all.

The shell is **the remake's own design and could not be anything else**.
[`90` §2.1](90-binaries-and-source-layout.md) records, on `aMenuSystem.cpp`'s
row of the runtime-module map, that the original's front-end flow is
deliberately outside the replacement contract, and
[`29` §1.2](29-interface-contract.md) puts save and load among the
"application-level actions, not map edits" that a replacement interface need
not reproduce. So there is no engine behaviour to diff against here, and
`godot/tests/test_shell.gd` declares `specification-only` — the strongest
boundary this subject admits. The one concrete number the contract does let
slip is that `0x0041DA20` owns "save/load UI and its **three** load slots";
eight is this remake's choice and a deliberate divergence, recorded here rather
than left to look like a misreading.
What is reused instead is the *data*: not one caption is a literal, and the
handful the original never had to say go through
[Localization]'s own-string half rather than into the code.

The six decisions, referred to by these labels from the code:

| | Decision |
| --- | --- |
| **S1** | Saves are **24 numbered slots**, paged twelve at a time and each nameable, with metadata, plus a separate quick save on `F5`/`F9`. |
| **S2** | Options carry **only what is actually connected**; §7.1 makes an inert control a defect of the remake's own. |
| **S3** | The layout is the remake's own, built on `CampaignScreen` — the same plates, font, `buttons.LIB` faces and localisation seam. The campaign chooser is two cards: `Graphics/Title.bmp` for *Incubation: Time Is Running Out* and `Install/Title.bmp` for *Incubation: The Wilderness Missions*, converted by the same BMP-to-PNG cache path; these product identities come from the distribution because the original never showed both products in one selector. |
| **S4** | ~~The intro (`Video/Seq_1`, logical id 0) is a **named empty step**, `_play_intro()`, for the sequence player to fill.~~ **Closed 2026-09-08** (§7.19 I3): the gate at mission control's entry plays it once, off `CampaignState.intro_pending`; `_play_intro()` no longer exists. |
| **S5** | Direct entry to a level is **kept and supported**, not a side effect: `--mission=`, the new `--campaign=`, and the outside driver (the agent server since §7.16). |
| **S6** | The authority for difficulty is `CampaignState.difficulty`; `GameSettings` holds only the default for the next campaign. |

**Twenty-four numbered slots, and the quick save is not one of them.** `F5`/`F9`
keep a file of their own beside them, so a reflex quick save cannot cost the
player a slot they meant to keep. It was eight — which is what `aLoad.cpp`'s
own screen holds — and the shipped screen is a picture of eight rows where this
one is a listbox, so the count is the remake's to choose; a campaign of 75
missions is long enough to want more than one save per chapter, and an unwritten
slot costs nothing at all. Twelve fit between the list's origin and the action
row, and the rest are **paged** by the listbox's own two arrows, exactly as the
shipped *Instant Action* `Leveloptions` list — a shipped listbox has no scroll
bar.
Its captions are not the `_S_XXX` stems: `aBuildMissionTxtSys` at
`0x00419BA0` parses characters 3..5 as an id in `Mission.lcl`, prefixes the
resolved item with `#_S_XXX`, and the row painter at `0x0044D690` skips that
seven-byte prefix.  The remake follows the same lookup while retaining the
stem as the launch key and as the visible fallback for a custom map whose id
the shipped bank does not define.
Starting one retains a local-mode `CampaignState`, populated from the selected
map's `tech_level`, `skill_level` and player equipment points.  That is not a
campaign: Back from deployment returns to the HQ, the result to the level
catalogue, and no campaign score or location is advanced.
**It opens in the HQ over an empty pool, not on the deployment screen**
*(2026-09-13)*. `aInitGUI` `0x004542A1` branches on the game mode: a campaign
enters mission control's gate `0x00456FC0(-1)` -- the map -- and every other
mode opens `0x004578C0`, `Menu_b` window 0, whose *deploy units* gadget
`0x004579A3` keeps off while the pool is empty. The map's header is the whole
economy -- `_S_004` gives 1500 points at tech 10 and skill 12 -- and the HQ is
where it is spent: the Unit Menu hires through the Recruit window
(`0x0045B7F8`, outside mode 1), and the Upgrade Menu sells the band
`0..tech_level` (`0x0045BF2A`'s non-campaign arm, [`27` §5.2](27-campaign.md)).
The remake used to seed four rank-12 recruits with the light gun and go straight
to deployment, so *Spaceport*'s ten Pyr'Coo and six Ee'Ther were met with four
pistols and 1500 unspent points; the four `Human Soldier` records `_S_004.lev`
carries at zero HP are free slots the engine skips ([`10` §5](10-lev-mission-format.md)),
not a squad. The mission is built before the HQ goes up, as the `.lev` is
loaded before `aInitGUI` runs, and the HQ frames the mission's own scene;
*Deploy units* takes the entry snapshot, and Back from deployment restores the
pool and rebuilds the mission under the HQ.
**The Recruit window's rows are presets** *(2026-09-13)*: the 23 numbers the
category arms list are ids `0x00476260` builds a ready-made type-0 soldier
from ([`27` §3.2](27-campaign.md)) — name, weapon, equipment, EP, FP and a
markup — not `Info.lcl` unit types, which is how the window came to hire a
type-1 soldier that stood on the map as a capsule. The table is decoded from
the executable by `campaign_tables.py` (`preset.*`), carried in
`tables/campaign.json` as `recruits` (`CONVERTER_VERSION` 0.42.0), and hired
through `CampaignState.recruit_preset`, which reuses the purse-less halves of
the two buy routines (`Upgrade.apply_weapon`/`apply_equipment`). The row is
priced per preset and gated on the purse where the engine gates it — the row
painter `0x00455C00`, red and disabled above the purse — with the refusal
spoken as well. `UnitState.resale` carries `+0x5A` where the engine's cache
differs from `aEnlargeUnitPool`'s derivation: a preset's whole price, and
the kit value `0x004776E0` writes after a weapon purchase; zero means derived,
so no shipped record's hash moves.
Retaining the state is what
makes ordinary Save, Save As, quick-save and the two undo slots work without a
new codec: `CampaignCodec` already persists the mode, mission and roster, while
the nested `SaveCodec` blob persists the battle.  Loading restores the
Instant Action result route from the saved mode only after the nested battle
has passed its own validation.
The ceiling is not a round number: `HudTables.SLOT_UNDO_MISSION`, `SLOT_REMIND`
and `SLOT_UNDO_TURN` are 31, 32 and 33 and write files in the same directory,
so the numbered slots stop below them or an autosave becomes a row the player
can load by surprise and overwrite by accident.
A row is built from
`CampaignCodec.decode_header`, which reads the campaign, the mission, the score
and the stamp without unrolling the roster, the scoreboard or the mission blob:
a page of rows must not cost a page of campaigns, and only the twelve on show
are read at all. A slot this build cannot read is
**shown carrying its refusal**, never hidden — a save that vanished because the
schema moved would look exactly like a slot the player never used, which is
§7.4's rule applied to a list. Refusals are always named through the codec that
issued them, because `CampaignCodec.Result` and `SaveCodec.Result` do not agree
numerically: `TRUNCATED` is 3 in the first and 1 in the second.

**Every list turns under the wheel and under a trackpad.** The shipped screens
are paged by a listbox's own two arrows -- there is no scroll bar in the
original anywhere -- and those arrows are kept, turning a whole page as they
always did. Beside them `CampaignScreen.scroll_rows_for` answers the wheel and
the pan gesture, one **row** a notch, because a wheel that jumped a page would
be a different control wearing the same input. It is the sibling of
`SliceMain.zoom_delta_for` and is pure and static for the same reason: a
`WHEEL_UP`/`WHEEL_DOWN` mouse and a macOS trackpad send different event
classes, and a list answering only the first looks unscrollable on exactly the
hardware this is developed on. A pan too small to have moved a row is carried
rather than dropped, so a slow drag still moves. Four screens answer:
*Instant Action*'s type-2 single-player catalogue -- present only in a cache
published with `--instant-action-maps`, and the main menu **drops the entry**
where the cache carries none, the way it drops *Load game* with nothing to
load (§7.1) -- the save slots, the HQ
roster and the briefing's
text box -- whose `scroll` had **no caller in the project at all**, so the six
overlong `A0` blocks it exists for could not be read past the box. A screen
answers only when it has more than a page to show, and the default is **no**:
the location map and the deployment screen are drawn around a hole and the
wheel there is the camera's zoom, which a list stealing the event would have
taken away. The map's no-picture fallback list is deliberately left out — it
exists only for a cache published without `--campaign-maps`, it holds one row
per open location, and it is on the screen whose wheel is the zoom.

**A save is named before it is written**, which is the one thing on this screen
the original's own does not do — its rows are eight pictures and it has no
field. Clicking a row in save mode opens a `LineEdit` on that row rather than
writing at once; `Enter` writes, an empty field writes the row the screen would
have shown anyway (the campaign, the mission, the score and the stamp), and
leaving the field **cancels**. Cancelling and not committing is the whole
difference from the Upgrade Menu's rename box: a rename can be undone by typing
again, and a save overwrites a file. The name rides in the container's
document beside the stamp and **not** in `CampaignState`, which is digested —
so naming a slot cannot move the campaign's own hash. `CampaignCodec`'s
`SCHEMA_VERSION` deliberately stays at **2** for it: the version is there to
refuse a container this build cannot *read*, a document without the key is a
save with no name, and bumping it would have thrown away every slot a player
already had to gain nothing.

**The map's *Save game* opens this screen.** It used to write the quick save
and say nothing at all — the one file `F9` overwrites without asking — so the
button the campaign map offers for saving looked broken *and* cost the player
whatever `F5` had put there. It goes into the shell over the map exactly as the
map's *Options* button does, and `Back` from it returns to the map because
`ShellHost.entry` is the screen the shell was opened at. The world it writes is
gated on `SliceMain.in_mission()` and not on `world != null`: the map stands
over the **last** mission's view and that world is still in memory, so a
between-missions save used to carry a finished mission's blob.

**Only connected options exist.** The original has eight option icons and
`Txtmod_h` 50–58 are their hover hints. Three of them — the speaker position,
the cursor and animation level, the animation resolution — have nothing behind
them in this remake, and §7.1 classes a control that does nothing as a defect
in the remake's own interface rather than a period detail. They are
**absent**, not disabled. The speech volume was the fourth until the unit
speech of [`99` §8](99-slice-7-report.md) shipped; **it is a row again since
2026-09-13**, scaling unit speech and nothing else, which is exactly
`Game.opt +0x14`'s reach — `0x0047B660` is its only reader
([`20` §8](20-lcl-language.md)). A briefing's voice-over stays on FX, as it is
in the original. The channel is a key on the cue (`AudioTables.CHANNEL_KEY`)
and not its volume-control id: speech's `-1` is shared with three cues that
ride FX. The same rule removes `Network Game` and
`Load PBM Game` from the main menu (§7.9 puts multiplayer outside the
programme) and leaves `Load Game` out until a slot holds something. The
language is shown as a line while the cache carries one language, and as a
selector when the manifest names more than one (§7.6) — a selector with a
single entry would be an inert control; mid-mission it stays a line, because
the switch reloads the scene.

**The `Faithful` caption still promises one thing it does not control**, and
that is a gap rather than a decision. §7.1's two audio flags live in
`AudioEvents.COMPAT_FLAGS`, while the `beacoo_mine_death_blast` correction now
lives in `World.compat_flags`, reaches a running mission immediately, and is
stored in saves and canonical hashes. It is added only when `Faithful` is off,
so a saved world without the newer flag retains the original rule.
`technical_box_guard_original` is the remaining missing flag: §7.8's
`technical` box keeps its bug unconditionally, so the toggle still does not
reach that one rule. Named here so the next person meets it as a known hole and
not as a surprise. What is
connected: the three volumes, the difficulty, the gore level of `Game.opt`'s dword
10 — no mission of the 92 writes `unit_draw_path`, so it is a live control and
not a default something overrides — and the `Faithful` preset over the audio
flags plus the `Bea'Coo` mine-death rule. Music and FX are sliders over the
settings file's -40..0 dB range in 1 dB steps: their percentage changes beside
the thumb, and each step is applied and persisted immediately. The enumerated
settings keep the original's click-to-step fields. Their track is the same
composed
`buttons.LIB` field as those values, and the grabber is its small green arrow,
scaled nearest-neighbour to the field's green interior and inset four pixels
from its end caps, so the direct control does not import Godot's default theme
into the plate or cover the frame at 0/100%.

**The authority for difficulty is `CampaignState.difficulty`.** This is the
decision the §7.13 slice left implicit and it has a hard reason: `ai_level` is
item 5 of `CanonicalHash.compute`, so writing difficulty into a running mission
would move the hash of a game in progress and a slot saved before the change
would stop matching the world it restores. The campaign's own digest already
carries `difficulty`, so changing it *there* is a lawful change of campaign
state. The options screen therefore writes the campaign's value only while the
player is on the campaign map — which is what `Txtmod_h` 58 says aloud, *Set
Difficulty Level (only in main map during campaign)* — writes the settings
file's default anywhere else, and shows no difficulty row at all inside a
mission. `GameSettings` holds the default for the **next** campaign and never
the live value. Its default is `Allowance.DEFAULT_AI_LEVEL`, the same 1 that
`TurnState.ai_level` starts at, because the two are one engine setting
(`0x00460450`) and defaulting them differently would have moved every
campaign-built world's canonical hash the first time one was written into the
other.

**All three ways in stay open**, and that is checked by a suite rather than
tried by hand: `SliceMain.boot_choice` is static and pure so a build's command
line does not have to be injected to test it. `--mission=NAME` builds a mission
immediately and never raises the shell — an unknown name still warns and falls
back, as it always did; `--campaign=N` is new and enters a chain's map past the
menu; the outside driver runs the sixth slice's scenarios unedited. The shell
must not become a compulsory door.

**A load lands on the fog pass's answer, and only then is a round trip exact.**
Measuring criterion 5 turned up a property nothing had written down. The engine
ends every load with `aBuildVisibleMap(aGetCurrentPlayer())` (`aLoad.cpp:1649`,
[`22` §9.4](22-combat-and-visibility.md)) and `World.load_save` reproduces it,
while a hand-over rebuilds the fog only when it refreshed — deliberately, so a
hand-over a script stopped leaves the same player looking at the same world. A
save taken while those two disagree therefore comes back with the pass applied,
at exactly the state the pass produces, and from there every trip is
byte-identical. It converges rather than drifting, and it is the engine's own
behaviour rather than a defect in the codec. Both halves are pinned in
`test_shell.gd`, the second against the pass run directly rather than against
the first load.

**Two defects the end-to-end walk found, both older than this slice.** A screen
freed from inside one of its own button signals leaves a corpse: Godot locks an
object while it is emitting, so `free` fails, the plate stays alive off the
tree and the next screen is stacked on it. `remove_child` and then `queue_free`
is the fix, and the same shape was in all seven `refresh()` methods — one click
on the difficulty row silently took the two volume rows above it away. And
"a mission is being played" is **not** `world != null`: the campaign map sits
over the last mission's view, so a shell raised from the map offered *Continue*
and *Save game* on the grounds that a finished `_C_140` was still in memory.
`SliceMain.in_mission()` answers the narrow question and `ShellHost.behind` the
wider one.

**The screens are laid out in the plate's units, not in the window's pixels
(2026-09-04, after the first play).** This was the change the slice most needed
and did not have. Nothing set a content scale, so a "pixel" of a layout written
for a 640x480 plate *was* a window pixel: on a 2560x1600 backing the game's own
17 px bitmap font came out about two millimetres tall and nothing moved when
the window did. `canvas_items` with a 640x480 base fixes it -- chosen over
`viewport` because the 2D layer is then scaled by a transform while the 3D view
still renders at the window's real resolution, so the mission keeps its detail
while the interface grows; and `expand` over `keep` because a 16:9 window
should show more world rather than black bars. Two consequences had to be
followed through: an `HBoxContainer` sizes children from their minimum, and a
`buttons.LIB` face plus a caption like *Enter Location* is ~144 of the plate's
640 units, so a row of five ran 116 units off the right edge of its own frame
-- the action row now divides the width it has and gives each button an
explicit rectangle. And the HUD's hint line and the developer line wrap instead
of being cut; the developer line stopped naming every cached map, which on a
640-unit screen was a wall of text across the playing field.

**One font decides for the whole interface, and the readable one is the
default (2026-09-04).** The HUD carried the shipped bitmap face and the
developer line carried nothing, so the same screen showed a hard-edged 2x
bitmap beside a smooth vector one -- a difference nobody chose. `font_2` is a
17 px bitmap out of the `.LIB` atlas (docs/60): it cannot be antialiased and
cannot be scaled, so past the 640x480 base it is drawn at hard-edged multiples.
`SliceMain.interface_font()` is now the single answer for the HUD, the floating
numbers and all eleven plates, and `GameSettings.game_font` chooses which face
it is. **The default is the readable one**, which is the one place in this
remake where fidelity is traded for comfort by default -- a deliberate change
of default and not an omission, made because the alternative is text the player
cannot read; the period face is one click away in the options. Three sizes go
with it, all in plate units: the hints at 10, because Godot's default 16 put
three wrapped lines of key legend across half the playing field; the developer
line at 9, because it is a diagnostic; and the action row's captions at 13,
because five buttons divide 640 units and *Enter Location* was being clipped to
*Enter Locati*. The briefing body follows the same decision -- it was drawn in
`font_0`, an **8 px** bitmap, so a briefing came out as legible headings over
body text nobody could read.

**Every refusal on the deployment screen is spoken (2026-09-04).** This is what
actually stopped the campaign being playable, and it is section 7.4 exactly: a
landing cell clicked with no soldier picked did nothing, and *Continue* on an
empty map did nothing, so a player who did not already know that a name has to
be clicked before a position could not start a campaign and had no way to find
out. The original needs no words because its screen is a picture of the map
with the squad standing on it; a pair of lists does. `World`'s own refusal
names are turned into sentences one for one, and a name with no line comes back
as the missing marker rather than as a blank. *(The screen is gone since
2026-09-13 — §7.23 — and the sentences moved to the HUD's caption line.)*

**One shipped Charisma part has no name.** `PC_011.cho`'s part 2 is authored
with an empty name and the mesh `PC_011_`, and Godot refuses an empty node name
(`Condition "p_name.is_empty()" is true`). It is authored data and not a
converter defect -- `cho_parse.py` reads the same empty string out of the file.
The geometry is real and is drawn, under a positional name; what an unnamed
part cannot do is be driven by an animation track, because a track binds by
name and will never match it. Unit type 61 selects that model and `_C_118` is
the one shipped mission that places one, which is why the wider mission
catalogue reached it and the six-mission set never had.

**What a review of the finished slice found (2026-09-04).** Six defects, all
in the shell's own seams rather than in what it drives, and two of them were
the same mistake twice. `ESC` at the boot menu took the plate down over
nothing and was then dead itself -- no shell, no plate, no mission -- leaving
the window's close button as the only way out; `ShellHost.behind` is the
question and `back_from()` was already asking it, so `_toggle_shell` now does
too. `interface_font()` was read two lines *before* `settings.load_from_disk()`,
so a saved choice of the shipped face reached every plate and not the HUD --
the exact inconsistency that function exists to prevent. Switching the font
back the other way left the bitmap `FontFile` attached in both the HUD and the
floating texts, which then drew a 17 px bitmap scaled to 10 rather than the
vector face; a `remove_theme_font_override` was missing in one and an early
return made the other a complete no-op. `_campaign_difficulty_writable()` was
**unreachable**: the shell cannot be raised over a campaign plate, so the one
place `Txtmod_h` 58 says the difficulty is editable was the one place the
player could not get to -- the campaign map now carries an *Options* button,
and with it `Back` had to learn to leave the shell from the screen it was
**opened at** rather than funnelling through a menu that offered to start a
new campaign over the one being played. The `load_slot` comment claimed a
refused load could be backed out of, which it cannot: the campaign and the
world are both already replaced by the time [SaveCodec] can check the blob at
all, and the comment now says so.

**And the driver's screenshots were frozen.** Every capture after the first in a
session came back byte-identical to it, because `root.get_texture()` inside
`_process` reads a framebuffer the renderer has not necessarily redrawn -- so a
transition that had happened in the tree looked, in the picture, like a screen
that had not changed. `RenderingServer.force_draw(false)` before the read fixes
it. Worth recording because it cost a wrong diagnosis: the first reading of
"the old plate is still up" was the driver's camera, not the game. The call now
lives in `AgentSession.capture_png` (§7.16), which is the **one** place a frame
is read, so `GET /shot` and the `shot` verb cannot drift apart.

**The four screens the original draws as pictures (2026-09-04).** The shell
made the campaign reachable; it did not make it *look* like the game. Four of
its screens were lists where the original has a picture, and the fix in each
case was to stop inventing a layout and read the one the shipped data already
carries.

| Screen | Was | Is |
|---|---|---|
| the location map | a column of buttons on a full plate | the chain's own `.lev` behind a frame, one dot per open location |
| the briefing | a 520x300 text box, pictures 30 units off the right edge | docs/24 §7.1's box `84, 77, 280, 276`, pictures at the programme's own `x, y` under the text, as the frame draws them; a programme row the block reaches drops beneath it and shrinks to clear the action row (`BriefingScreen.settle_pictures`, 2026-09-21) |
| the tips | a third button on the same screen | the same screen with `C0` in the `230`-wide box and the tip programme's pictures |
| deployment | two lists, names against `x, y` pairs | the mission's own view with a dot on every free landing cell *(since 2026-09-13, §7.23: no screen at all — the battle interface on turn 0)* |

Four decisions behind that, and the first is the one the rest hang off.

**A plate with a window in it, not a plate over a picture.** The shipped plates
are opaque 8-bit bitmaps with no alpha, so a hole cannot be painted — it has to
be *left*. `CampaignScreen.plate_window()` names a rectangle in the plate's own
640x480 units and the base class then draws the plate as **four strips** around
it, each an `AtlasTexture` of the plate's own pixels put back where they came
from. What shows through is the root viewport, which is where the 3D already
is. `plate_1`'s interior was measured off the bitmap rather than guessed: the
frame's metal highlights stop at x 34 and y 36 and the bottom band starts at
412, and the window stops short of that band at 392 so a screen has somewhere
inside its own frame to write a line that is not over the picture. `_root` and
`_body` became `MOUSE_FILTER_IGNORE` for the same reason — a [Control] stops
mouse events by default, and the clicks that land in the window have to reach
the pick behind it.

**The map's picture is a world of its own, and it is not `world`.** `_C_XXX`
and `_C_YYY` are ordinary `.lev` files, so the mission renderer draws them
unchanged — but half of `game` reads `world != null` as *a mission is being
played*, and conflating the two was already a defect once (§7.15's
`in_mission()`). So the backdrop is `_backdrop_world` with a root and a rig of
its own, built with **no script, no `run_init_map`, no effects and no
`apply_world`**: a campaign map's `.lcl` is the original front end's and this
remake's flow is its own (D3). Two 3D scenes cannot share a root, so opening
the map frees the mission's scene and `_build` frees the backdrop; the view is
computed from the map's own span rather than read from the script that is not
run.

**The dots are 3D and the clicks go through the pick the game already has.**
The alternative was to `unproject_position` each cell and move a [Button]
there every frame, which needs the window-pixel to plate-unit conversion the
`canvas_items` stretch introduces and is a second implementation of "which
cell is that". A [Sprite3D] with `fixed_size` and `no_depth_test` stands on
the cell — which is what a location **is**, docs/27 §2.1's action point — and
`SliceMain.cell_under` answers the click, generalised from the mission's own
`_cell_under` to any camera over any world. The marker art is the shipped
`map.LIB`: 0 red for a battle, 2 blue for an upgrade, 3 yellow for a dialogue.
A location the chain enables but its map has no cell for — docs/27 §2.5 names
two on `_C_XXX` — is skipped rather than drawn at the origin.

**`B0` is not on the briefing screen.** docs/24 §7.1's eight call sites are the
whole set, and the short conditions block is asked for by the unit-selection
and map screens; this screen asks for `A0` and `C0` and nothing else. So the
action row is three, as the original's is: *Back*, a toggle whose caption is
`Txtmod_b` 31 or 32 — the bank carries *Tips* and *Briefing* for exactly this
— and *Continue*. The title stays *Briefing* on both. The toggle is absent
where the file has no `C0` at all, which 25 of the 116 do not.

Two defects fell out of the change rather than being looked for. Backing out
of a deployment **cost the campaign a soldier per cell already clicked**:
`aTransferUnitFromPoolToMap` takes the record out of the pool, and the map
screen now frees the mission's whole scene, so the units were simply gone —
`CampaignHost.abandon_mission()` is `aCopyUnitPool(1, 0)`, the same call the
debriefing's *replay* makes, and it also puts `campaign.screen` back, which
the old *Main Map* arm never did. And a dot stayed on a cell somebody was
already standing on, which §7.1 counts as a control whose only answer is a
refusal; the picture is laid out from the **free** landings now. The
deployment screen also picks the next soldier itself, so the one refusal a
player could not diagnose — a cell clicked with nobody selected — is left for
the case it actually means, an empty squad.

*End game* — `Txtmod_b` 18, which the original puts on this bar beside *Save
game* — **asks first**. It drops a campaign that may never have been saved, and
`Txtmod_d` 60/61/62 is the question and its two answers: the bank carries
*Back to the Main Menu without saving? / Yes / No* for exactly this button. The
first press swaps the action row for those two and writes the question where
the location's name goes; the second does it. A click that cannot be undone
and says nothing is what §7.4 forbids, and this is the only button on any of
these plates that can.

**And `_build`'s head became a teardown.** Freeing the mission's scene was
only ever the first half of building the next one, so it reset what `_build`
was about to overwrite and no more. The map screen calls it and then leaves
the game with **no world for as long as the map is up**, with `_process` still
running every frame — and `_sprites` and `_models` are children of the scene
that was just freed, so the first frame after would have called a method on a
freed instance. `_clear_mission()` now clears everything a frame touches: the
two effect nodes, the pool and its carry, the triggers, the sequence queue,
the camera director, the walk cameras, the footstep cues, the pending
reactions, the drawn terrain and the last query.

The HUD is a mission's and nothing else's. It used to be left up under every
plate, which cost nothing while a plate covered the whole screen and shows
through the moment one has a window in it. The driver gained `press CAPTION`
and `map_click X Y` for the same reason a driver cannot click a plate
coordinate any more: the buttons are laid out in the plate's units and the
window is not.

**A second pass over the four, and the shipping build (2026-09-04).** What the
first pass delivered was the shape; four things it did not deliver were the
reasons a player could read it.

**The map's camera is the original's location preset (corrected
2026-09-10).** This was a computed view for one pass -- a distance from the
box of open locations and a height from the map's own span -- on the belief
that the original's was set up by a front-end script this remake does not run.
It is not: `_C_XXX.lcl` and `_C_YYY.lcl` set no camera at all (four
`CreateBGB` fires and a `CDTrackProgram`, and nothing else). The first static
reading then stopped one call too early and called the six initial immediates
the final camera. `aMissionControl.cpp` immediately calls `0x0045D130` with
`missionId + 50`; its 71-byte selector chooses one of thirteen authored eyes
for locations 59..129, or a default, while the target stays
`(56800, 56800, 0)` (docs/27 §2.6, pinned by `campaign_tables.py --check`).
The computed view still put the eye nowhere the original does, but the fixed
initial eye was wrong too: after `_C_143` it hid location 95 below the frame.
The full preset table keeps all 156 open-location instances in both campaigns
inside the frame without requiring the player to rotate it.
Two things came with it: the window the plate leaves clear is the engine's own
3D viewport, `(65, 57)` by 518 x 306, and the plate is `plate_3` -- the one
shipped plate with a picture frame inset in it, whose dark interior is exactly
that rectangle. The window had been measured off `plate_1`'s frame, which is a
different plate and 570 x 356. The deployment screen keeps the **mission's**
viewport instead, `(60, 34)` by 520 x 340 (`0x00419D90`), because that is what
it is a picture of.

**The projection is the engine's too (2026-09-05).** For one pass it was not:
the rig's camera was a plain `Camera3D` at Godot's default 75-degree field of
view with its axis through the middle of the render, and the engine's is
neither. Eng3d's perspective is a **constant, not an angle** -- `0x00403460`
computes the focal length from the 3D window's width alone,
`_ftol(width * 10/13)` through the double at `0x004B1010`, and hands it to
`_E3D_init_3d_screen` as its fifth argument, where the DLL keeps it beside its
reciprocal (`Eng3d.dll+0x14FE8`, whose own initialiser is 256) because that
reciprocal is the divide a projection is. So 398 for the map's 518-wide window
and 400 for the mission's 520, against Godot's implied 313 at 75 degrees --
everything had been too wide. And the **axis is the window's centre**, which
is not the render's: the 3D fills 640 x 480 with the plate drawn as four
strips around the hole, so the map's centre is (324, 210) and thirty pixels of
it do not cancel. `CameraRig.frame_projection` carries both as a frustum --
the height gives the focal length, the offset moves the axis -- and
`test_shell.gd` checks the **agreement** rather than the constants: a point
through Godot's own frustum matrix has to land where
`centre + coord * focal / depth` puts it, to within a hundredth of a pixel,
for both windows. The zoom divisor `0x004FA500` that would replace 10/13 is
written by five sites, none of them on the mission or map path, and is a
parameter here rather than an assumption (docs/27 §2.6.2).

**And the map turns.** `0x004558F0` was named as the routine that swings the
eye and its height clamp measured, with the delta left **UNVERIFIED** -- docs
/27's fourth open question, now closed in §2.6.1. It is a pointer drag:
`0x00455560` runs while the screen id is 6 and the button byte is set,
doubling the horizontal travel into the turn and multiplying the vertical by
-50 into the height, with the cursor warped back to the drag's anchor every
frame so what is read is travel and not displacement. Two halves of it read
backwards and the port has both: the step **decays by halving** when the
request is the smaller, which is what the frame callback's own zero call is
for and why a released drag coasts to rest in about ten frames; and the eye
that is rotated is the **constant** one, because `aSetCameraPosition` writes no
global back -- rotating the eye the last frame left makes the map accelerate
away. `CameraRig.swing_map` is the routine and `_tick_backdrop_swing` the
zero call. What the remake does not copy is the cursor capture: the map is a
screen with buttons on it, and stealing the pointer to turn a picture would
take the buttons with it, so the drag is the middle button as in a mission and
`Q`/`E` stand in for a keyboard.

**The city burns.** `_C_XXX.lcl` and `_C_YYY.lcl` each light four buildings
with `CreateBGB (n, 7_fire, ...)`, and that plus a `CDTrackProgram` is the
whole of their `InitMap`. The command was recorded by the interpreter and read
by nothing -- the fifth slice left it out because none of its six missions
calls it -- so the backdrop, built with no script at all, was a still city. It
now runs **that one arm** of the map's own program and takes the `create_bgb`
events out of the outcome; nothing else about the script is used, and no turn,
no simulation and no set piece applies. `game/fx/bgb_emitters.gd` is the
twenty-slot table and `0x0041E1A0`'s cadence (docs/28 §8.2, pinned by
`blob_tables.py`'s `bgb.*`), and `BlobPrograms.main_map_fire` is
`aBlob_CreateMainMapFire` -- three draws and one constructor call. The map gets
a pool and a sprite cloud of its own, on the same 20 fps clock a mission's runs
at; a mission gets the same table, so the other ten shipped calls now have
somewhere to land.

**All seven creators, and the track (2026-09-05).** The first pass carried
type 7 alone and counted the rest in a `BgbEmitters.unmade` tally -- which was
reporting a **non-defect**. `CreateBGB` has *two* jump tables and no type is
in both: `0x0041E120` at registration, `0x0041E300` in the sweep. Five of the
sweep's seven entries are one `mov eax, 1 / ret`, so types 2..6 tick to
nothing in the original as well, and their whole effect is the object
registration makes once. The tally was counting faithful silence as a gap.
All six missing creators are now transcribed -- they share one constructor and
differ by a model, a kind and, for type 2, a coin that picks which way the
warning light sweeps -- and `BgbEmitters.register` takes the hooks so the
one-shots are made where the command makes them, which is also **not** behind
the animation-level gate the tick is. What is left of the tally is
`BgbEmitters.refused`, and only a type above 7 can reach it: that is the
`invalid creator` assert, and nothing else. `_C_102`'s two warning lights are
the first shipped call other than the maps' fires that this remake answers.
The map's `CDTrackProgram` plays as well, out of the **same** `INIT MAP` run
its emitters come from rather than out of the cache's playlist row, which is
what makes the two halves of that block one thing.

**And the dots are picked on the screen, not on the ground.** `cell_under`
crosses the pointer's ray with each cell's own height, which is the right
answer under a mission's camera and a fragile one under this: the authored
presets include shallow views across the campaign maps' steep height changes,
so one pixel of pointer movement can cover much of a field and a dot two pixels
across became unclickable the moment the camera became faithful. The markers
are overlay sprites -- `no_depth_test`, `fixed_size`, drawn after the world --
so what the player aims at is the sprite: `MapMarkers.cell_at` answers with
the nearest projected marker inside ten plate units, and the ray pick answers
for the ground the dots do not cover. Both screens use it, and on the
deployment screen it also means a click a hair off a landing dot lands on it.

**The dots are depth-tested — no, they are not, and that was measured.** A dot
drawn over whatever tower stood in front of its cell looks as if it were
floating somewhere of its own, so honouring the depth buffer was tried. It
hides them: a campaign map's visible ground is the `.3DW` clones and a
location's height is the **control map's**, so the dot sits under the street
it belongs to, and campaign 1's three open locations disappeared entirely.
`no_depth_test` stays, which is also what the original does — these are
overlay sprites drawn after the world. What answers *which* dot is which is
the ring: `map.LIB` 7, the shipped 17x17 the original rings the pointed-at
location with, moved rather than one per cell, and taken down when the pointer
leaves the picture. The name moved with it, from the bottom band — where it
shared a line with the purse and a row of button captions — to the top of the
window, over the sky.

**Deployment is from above.** *(The screen this paragraph describes is gone
since 2026-09-13, §7.23; what survives is the camera.)* `aSelectUnits`
deploys top-down and so does this:
the screen opens in docs/42 §2.4's map view over the deployment area, and the
mission's own view keys work under it — `2` for the eyes, `3` for the map,
`4` for the ordinary angled view, Left/Right to turn, the wheel to zoom and
the middle button to drag.
Before the first soldier is placed there is no unit to frame, so the engine's
own *on the unit* placement is made over the landing cell instead; after one
is placed it frames the soldier. The camera half of `_screen_input` is a short
**named** list rather than a fall-through: a screen is up, and everything it
does not name still belongs to the screen. Turning is the mission's and not
the map's — the map's eye is the selected location preset above while the
rig's quadrant is still 0, so a mission turn there would jump rather than
pivot. The original *does* turn that view separately: `0x004558F0` swings the
selected base eye about the target by an angle it accumulates and decays,
clamping the height into `[-9600, 19200]`; docs/27 §2.6 records the right-button
drag that feeds it.

**`ESC` over a mission has a way out that is not quitting the program.** The
pause menu offered *Continue*, *Save game*, *Options* and *Exit Program*, so
the only route back to a chain chooser or a save slot was to shut the game
down. *Main Menu* (`Txtmod_a` 100) drops the mission and the campaign, which
is why it asks the same `Txtmod_d` 60 the map's *End game* asks — and both now
go through one seam in [CampaignScreen]: `pending`, `needs_confirming()` and
`_show_actions()`, because the second of them was written by copying the
first. It is absent at the boot menu, where this screen **is** the main menu.

**And a way out that is not dropping the campaign** (2026-09-09). *Main Menu*
was the only one, and it takes the campaign with it: a mission left by
accident cost the chain, and the three reserved autosave slots that still held
it -- 31, 32 and 33 -- are deliberately off the slot list, so there was
nothing to load it back from. The pause menu of a **campaign** mission now
carries *Main Map* (`Txtmod_b` 140) directly after *Save game*: the
sortie is abandoned, the squad comes back into the pool and the chain goes on
from its location map. It is the deployment screen's own button one screen
further on, and it is written once -- `SliceMain._leave_mission_for_map()`,
called by both. It asks first, and with the **remake's own** question
(`shell.abandon_mission`): `Txtmod_d` 60 is the shipped data's only question
and it names the main menu. It is absent for a mission entered past the
campaign. *Instant Action* retains its local state so the ordinary container
can save it, but has no campaign map to go back to; bare `--mission=` has
neither state nor a map;
that is a field of the screen's rather than `paused`, because `paused` cannot
tell the two apart.

**The cascade moved left, and the exits stand apart.** `Menu_a.lcl`'s table
steps 30 right and 40 down from `(280, 80)` and ends lower, at `(425, 300)`;
it was written for the original's own menu window, and this shell draws it on
the framed plate, where a 190-wide button on the block's last coordinate
reaches 615 against a bevel at 621. A seventh row stepped once more put two
buttons 4 units apart and 620 out, over the frame. Two changes, both the
remake's own and both applied to every menu drawn from this block:

* the whole cascade is moved left by **a quarter of a button** (47.5), which
  keeps the block's shape -- its start, step, descent and the lead a short
  menu takes -- and takes the right-hand end off the frame;
* the trailing exits -- *Main Menu* and *Exit Program*, or *Exit Program*
  alone at the boot menu -- are pushed down by **half the block's step**,
  because every row above them does something inside the game and they leave
  it. The block makes the same distinction in the same direction: its own last
  row sits lower than the step alone would put it, and for any menu that fits
  the block's six rows this gap lands the last row on exactly that `y` of 300.
  A seventh goes to 340, 40 below the row above it.

The break is read off the entries rather than counted, so a confirmation --
which has neither exit in it -- lays out flat.

**The shipping build is built again.** Godot 4.7.2's export templates are
installed (they were 4.7.1 against a 4.7.2 engine, which is why this was on
the open list), and both presets export: the shipping one and `macOS Tests`,
which runs the suites inside a real build against the published cache — all 92
campaign maps. That run found what the editor's cannot: **the warnings gate is
the editor's**, and it now says so. Two of its six settings are at the
engine's own default, so `project.binary` omits them and reading them with a
wrong fallback reported the gate as off; and the compiler that turns those
levels into errors has already run, so the deliberately violating fixture --
shipped as source by that preset -- compiles at load under the runtime's own
levels and is accepted. The four levels that are not at the default are still
checked in both worlds.

That run also reported `ERROR: 103 resources still in use at exit`, which the
editor's does not, and the first reading of it -- that an exported build holds
the `class_name` table to the end -- was wrong. **It was one `static var`.**
A shipping build made to `load()` all 140 scripts and quit reported nothing;
disabling the suites' own script-loading probe changed nothing; running the
suites one at a time put the whole of it on the twenty-third,
`test_presentation_native.gd`, whose `static var _cached_geometry` was the only
static variable in the project. A script that declares one is kept for the
life of the process, and a kept script keeps every script it names -- 103 of
them from there, the transitive closure of that file. `@static_unload` does
**not** lift it while the run still holds an instance; moving the variable onto
the suite does, and the exported run is now clean of both the error and the
123 leaked `GDScript`/`GDScriptNativeClass` instances beside it. It is a
second way into the same failure the reference-cycle rule guards, and
`CLAUDE.md` carries it beside that one.

**The test build says what it is.** It ran all thirty-two suites inside
`_ready`, which is a black frozen window for the length of the run and was
reported as a hang. The runner is now three pieces -- `begin_run`,
`run_suite_at`, `finish_run` -- and the exported build steps them **one suite
per frame** behind a caption that names the build and counts them off.
`tests/main.gd`'s headless entry still calls `run_all`, which is those three
composed.

**The campaign's own two maps are in every cache.** `_C_XXX` and `_C_YYY` are
not missions -- they are the screen the missions are chosen from -- and they
arrived only with `--campaign-maps`, so the default six-mission cache that
every developer has opened the location map onto nothing. Every selection
carries them now, an explicit `--missions` included; they are 40x40 `A00` maps
and cost 1.1 MiB over a set that already has an `A00` mission, which is
what moved the two cache ceilings by one MiB each. The degradation stays for a
cache made before this: with no picture behind it the map screen draws its
plate whole and offers the open locations as a list of rows, which is what the
screen was before the picture existed. A hole cut for a picture that is not
there is a black rectangle where the frame should be.

**A deployment with nobody to deploy is not a screen** *(and since 2026-09-13
there is no screen either way — §7.23; the skip below is the same arm, taken
at the mission's entry)*. Campaign 2 starts with
an empty pool -- `aCreateUnitPoolForCampaign(2)` is a bare return -- and
`_C_140` places its own squad, which the debriefing then recovers into the
pool. The deployment screen still opened: a roster of nobody, a map of dots
nobody could stand on, and one button. It is skipped where the pool is empty
**and** the mission ships a player-0 squad of its own. Where the pool is empty
and the mission has no squad either it still opens, because then there really
is nothing to start and the screen is what says so.

**The converter learned five more plates.** `Graphics/*.bmp` — `Title`,
`Credits`, `Ship`, `MsgScr`, `Bluebyte` — sat beside `Graphics/GUI` and
`Graphics/Briefing` and were baked by nothing, so 103 of the installation's 108
BMPs reached the cache. All 108 do now, through the existing writer;
`CONVERTER_VERSION` is 0.17.0. `Title` is the shell's backdrop and `Credits` is
there for a screen this slice does not build; the other three come along
because the loop is one loop, and are named as having no consumer rather than
left to look intentional.

---

### 7.16 The control server — a socket instead of a directory (2026-09-06)

Automatic driving used to go through `godot/tour.gd`: a `SceneTree` script
outside `game/`, excluded from the shipping preset, that waited for
`cmd-0001.txt`, ran its lines and wrote `res-0001.json` beside it. The protocol
worked and drove three slices. What it could not do is answer a question **now**:
a reply was a file written after a batch finished, so "what does the screen look
like in the middle of this walk" and "is the computer's turn still being
replayed" were questions with no way to ask them, and the file numbering made
the conversation sequential by construction.

The cost of replacing it was low and worth naming, because it is what made the
decision easy: no script in the repository ever wrote a command file (the
protocol had prose in `docs/97` §42 and `CLAUDE.md`, and no client), nothing
under `godot/tests/` named the driver, and the transport was about forty lines
of a 1091-line file. The verb table, the snapshot builder and the screenshot
did not depend on it at all.

| # | Decision |
|---|---|
| **A1** | The file protocol is **removed**, not kept beside the socket. A second door to the same verbs, in a file no suite and no export exercises, is exactly the shape of rot the warnings gate exists to prevent. |
| **A2** | The server attaches to an **ordinary** launch, by `--agent-port=N`. What is driven is then the build a player runs, not a driver-shaped copy of it. |
| **A3** | It therefore lives under `game/` — `game/agent/` — and is covered by the warnings gate, `test_isolation` and `runner.gd`'s `game_loads` sweep, none of which ever scanned the repository root. |
| **A4** | It **ships** with the game and is inert: nothing listens without the flag, the bind is `127.0.0.1` only, and a port that cannot be taken is a warning rather than a refusal to start. |
| **A5** | The request parser, the routing decision and the two command-line flags are **static and pure**, on `SliceMain.boot_choice`'s precedent, so `tests/test_agent.gd` pins them with no socket, no window and no game. |

**A2 reverses `docs/97` §42.1's own rule** that `game/` gains nothing for the
driver's benefit. That rule was right for a file the export excluded; it stops
applying the moment the driver *is* `game/`. About 850 lines moved across and
still read `SliceMain`'s private members — which compiles cleanly, because the
reference is typed.

**The routes.**

| Route | Answered |
|---|---|
| `GET /health` | immediately, before a world exists; `booted` is what a client waits on |
| `GET /state` | immediately, **including while a `POST /command` is running** |
| `GET /shot` | immediately; the body is `image/png`, and `?save=NAME` files it under `--agent-dir=` and returns `X-Agent-Shot` |
| `GET /help` | `AgentSession.VERBS` |
| `POST /command` | when the batch finishes, which may be hundreds of frames later |

The concurrency is the whole point and it falls out of one ordering inside
`AgentBridge._process`: poll the socket and answer every read **first**, then
step the session. A parked `POST` is a connection held open in the server's
table; everything else is answered in the frame it landed. One batch runs at a
time — a second `POST /command` is `409` with `Retry-After` — and reads never
queue behind one.

**What replaced the two watchdogs.** The driver gave up after 900 frames
without a world and after twenty minutes without a command file. Neither
belongs in a game: a running game must not exit because nobody talked to it.
The boot limit became `/health`'s `booted` flag and the client's `wait-up`, and
the silence limit became the caller's own `timeout` around the process.

The boot **gate** inside a batch is a different thing and had to keep a limit of
its own. A batch waits for a world so that a click sent the moment the port
answers does not run against nothing — but a command can take the world down
legitimately (`ui` with no argument closes the campaign map; `location N` can
name a mission the cache does not carry), and the first pass gated on that
condition for ever. The batch then never finished, its socket stayed open, and
every later command — `quit` included — was answered 409 with no way back. The
gate is now lifted for the rest of the batch as soon as the game is up, given
up on after `BOOT_LIMIT` frames with a line in the reply's log, and never
re-applied within a batch. What is
still bounded is per-connection: a half-read request is dropped after two
minutes, a body over 1 MiB is `413`, a header block over 16 KiB is `431`, and a
ninth simultaneous connection is `503`.

**`VERBS` is the one source of truth.** The driver's header table had drifted
to sixteen entries of about thirty and nothing noticed, because nothing read
it. The constant is now what `run_line` dispatches through, what `GET /help`
prints, and what `test_agent.gd` compares — set for set — against the handler
table. A verb with no help line, or a help line with no verb, fails the run.

**`--agent-dir=` moves the screenshots and nothing else.** A driven session
writes its saves and its settings into the live `user://`, exactly as a played
one does. That was already true of the file driver; it is now true of any launch
carrying the flag, which is a wider blast radius and is said here rather than
discovered.

**And it writes what a played session writes.** `screen save` reached
`CampaignHost.save(world)` directly until 2026-09-07 — the simulation and
nothing else, unstamped, with no scenery poses, no camera and no regard for a
set piece half drawn. It goes through `SliceMain._save_mission_to` now, which
is the seam `F5`, the slot screen and the turn's autosave already shared, so
a driven save is byte-comparable with a played one and is **refused** while
the sequence queue is running ([`42` §8.3](42-mission-presentation.md)). A
verb that writes a different file from the button it stands in for measures
its own path and not the game's.

**What driving it found the same day.** Played through the server, *Recall
position* stayed dark on a slot `F1` had just written. `_slot_holds_this_mission`
reads a slot's header **once** and remembers the answer -- the interface asks it
every frame, so the cache is filled long before any save -- and only
`_autosave` was recording what it wrote. Every writer records now
(`SliceMain._save_mission_to`), and the suite pins it
(`test_effects.gd`, `resume.the_slot_knows_its_mission`). A cache whose one
invalidation path is the writer is only correct while every writer knows about
it, which is an argument for having one writer rather than for adding a second
line.

**The snapshot answers a number that moves** (2026-09-07). `picture.scenery`
is `Scenery.built_count()`, which counts the lattice's cell markers and the
scene's `.3DW` clones as well as the special objects, and which is a constant
for the life of a mission -- so a crush wall or a footbridge that took its
object away moved nothing anything outside the game could read, and the one
question a driven set-piece session asks had no answer. `picture` now carries
`scenery_objects` (`Scenery.object_count()`, the search's own answer summed
over the map) and `scenery_removed` (`removed_count()`, cells `aDeleteLand`
has freed) beside it. On `_C_129` played to turn 3 the three `CrushWall`
calls read 113 -> 112 -> 111 -> 110 objects and 0 -> 1 -> 2 -> 3 removed, one
per call, and the save that follows carries `removed: [556, 616, 708]` --
(16,18), (16,20) and (18,23), the three cells the script names. Reloaded, the
scene is rebuilt to its full 1040 and the record replayed back to 110 / 3.

**Screenshots still need a window.** `RenderingServer.force_draw(false)` is
carried over from §7.15 and is in exactly one place, `AgentSession.capture_png`.
Under `--headless` there is no renderer and `GET /shot` answers `503` rather
than a zero-byte PNG, which a client would otherwise file as an empty picture.

**What the existing GDScript servers do, and why none of it was taken.** The
two that come up — `xaltaq/GDHTTPServer` and `fbcosentino/godot-rest-api-server`
(itself over `deep-entertainment/GodotTPD`) — are Godot 3 code, and their
shapes are worth naming as decisions rather than as omissions:

* **A dedicated accept thread**, polled with a 100 ms sleep. Refused. A reply
  here has to be a *frame's* truth: `/state` is read after `SliceMain._process`
  and `/shot` forces a draw, both of which are the main thread's. Answering
  from a thread would either need a hand-off back to it or would report a
  frame nobody drew.
* **Route parameters** (`users/:name/slots/:n`) and a signal per method. Not
  needed for five fixed routes, and `route` being one static function with a
  table of five is what makes it a suite's subject.
* **Keep-alive.** Neither has it either. `Connection: close` is kept, because
  the parked-connection rule already gives long commands what keep-alive would
  be for, and a persistent connection would have to be reconciled with the
  one-batch-at-a-time policy.
* **CORS.** Deliberately absent, but that is not the defence it looks like:
  omitting `Access-Control-Allow-Origin` stops a page **reading** the answer,
  not sending the request, so while the flag is set any page the player has
  open could fire a `text/plain` `POST /command` or an `<img src=".../shot">`
  at `127.0.0.1`. What actually closes it is two lines: a request carrying an
  `Origin` header is answered **403** -- a browser stamps it on exactly those
  requests and no client of this server sends one -- and `?save=` is put
  through `AgentSession.safe_shot_name`, so a name off the network cannot walk
  out of `--agent-dir=`. Both were found by review after the first pass shipped
  the wrong claim.
* Their two documented weaknesses are the two things measured here. GDHTTPServer
  "doesn't buffer incomplete lines across multiple `get_data()` calls
  efficiently" and has **no timeout at all**; `parse_request` is a pure function
  over the whole accumulated buffer, so fragmentation is not a case it can get
  wrong, `tests/test_agent.gd` sends a body in two writes over a real socket to
  prove it, and `IDLE_MSEC` / `MAX_HEAD` / `MAX_BODY` / `MAX_CONNS` bound the
  four ways a peer could otherwise sit on the game's frame.

### 7.17 The picture is a lagging mirror (2026-09-07)

`core` resolves a whole command -- and the whole computer turn -- before it
returns, so the world `game` reads always stands at the **end** of the last
one. Three slices of presentation defects came from that, and each was fixed by
a mechanism that hid one field of that world until the animation caught up:
eighteen of them by the seventh slice, with `AIPlayback.casualties_of` walking
**five** payload shapes to find out who a turn had killed and a sixth one set
piece away. [`100`](100-slice-8-report.md) removes the cause.

| | Decision |
|---|---|
| M1 | **The picture reads a lagging clone.** `SliceMain._shown` is advanced one event delta at a time; `SliceMain.world` is read to submit a command, to ask whether one is allowed, and for the flow gates that are about the rules. `World.clone()` is not `save()`/`load_save()`: that pair ends in a permanent fog rebuild and cannot carry `special_models` or `next_map`. |
| M2 | **A boundary goes where the original drew a frame.** The engine's tick `0x0040B6F0` sits inside the mutating routines ([`28` §1.4](28-effects-and-sound.md)), so everything between two ticks is one visible change. The blocking loop does not transfer; that atomicity does. |
| M3 | **The journal is opt-in.** `World.enable_journal`; a world without one pays one boolean test per [MapState] setter. `AIContext.journal` is null when `AISystem.run` is driven from a case file, so `cases_ai.json` is unchanged, and the three kinds a routine marks itself are not stamped twice. |
| M4 | **The fog is computed for the watching seat**, over the mirror, per event, with each walker answered at the cell its body is drawn on. `turn.current_player` is 255 while the computer holds the turn, and a pass for 255 is the aliens' own view of the map. |
| M5 | **One `reaction` event per shot.** The engine's drain calls `aAttackUnit` per reactor, each with its own blocking animation. The planner's own `reactions` event stays for the case file; it is a different document. |
| M6 | **The invariant replaces the per-family checks.** After the last delta of a command the mirror's canonical hash equals the truth's. A field no delta carried fails there and nowhere else, whatever mechanic introduced it; the drain resynchronises rather than drawing a world nobody can name. |
| M7 | **The picture-only mechanisms stay, and are re-documented.** `suppress`/`reveal` hide with no state behind them, `lift`/`shift` interpolate between the shown-before and the shown-after of a set piece, `hide_now` is the frame the object leaves. None of them compensates `core` any more. |
| M8 | **The pacing is the computer's; a player's command runs at the picture's own speed** (2026-09-07, second pass). `EventPlayback.play` takes the gap between two shown events as an argument: `end_turn` passes 0.45 s of free picture, `_play_command` passes zero. The first shown event is presented inside `play()`, a presenter's hold runs under the animation and not after it, and a shown event whose presenter queued nothing is quiet and costs nothing. What is *watched* — the progress bar, the skip key, the agent's `replay` — is the mirror's seat being 255, never "a playback is running", because the player's own commands run through the same playback ([`100` §3.1](100-slice-8-report.md)). |

**The alien that attacked as a green beam is fixed unconditionally.** Half of
it was the engine's -- the fog the rules read is rebuilt at the hand-over and
at nothing between ([`22` §9.4](22-combat-and-visibility.md)) -- but the
probe that carries the picture ahead of the rules is per *command*, and the
computer's turn is one command. Reproducing that faithfully leaves a contact
beam swinging its claws for a whole turn, which reads as a bug rather than as a
period detail, so §7.1's first half does not apply.
`PictureFog.beams_until_hand_over` restores the original's timing for the
checks; it is a **picture** flag and not a `World.compat_flags` entry, because
a compatibility flag that moved the canonical hash would be a worse defect than
the one it reproduces. **It stays internal — decided 2026-09-13.** Offering it
would put the beam back into §7.1's first list, and the beam is the case that
list's rule excludes: a contact that attacks for a whole turn reads as the
remake's bug, not the period's. And the flag restores only the *timing*: with
it on, the radar and the overlay still read the same answer as the bodies, so
a setting built on it would promise the original's fog and deliver half of it. The radar and the ground overlay now read the same
answer as the bodies, which drops the engine's own stored-byte asymmetry
([`99` §205](99-slice-7-report.md)) -- a deliberate deviation, so that an alien
appears everywhere in one frame.

---

### 7.18 A cheat system, for walking a level rather than playing it (2026-09-08)

Testing a mission end to end means reaching its later turns, and the shipped
game gives no way past its own difficulty. The remake adds one. It is the
remake's own -- the 1997 engine has nothing like it -- so this section is the
whole of its specification and `godot/tests/test_cheats.gd` the whole of its
verification.

| | Decision |
|---|---|
| C1 | **`Cheats` is a rule modifier, not simulation state.** It follows `World.ai_may_fire` ([`23` §1](23-ai-system.md)'s engine debug global) literally: outside `CanonicalHash`, outside `SaveCodec`, and carried by `World.clone()` **as the same object** -- one `Cheats` exists per session, `SliceMain` hands it to every world it builds, and a snapshot in the clone would freeze at clone time and diverge from the truth on the next toggle. Two worlds differing only in which switches are on are the same state, so a save taken with one on restores to a world whose hash matches -- and a save can neither carry a switch into a session that did not ask for it nor clear one the session did. |
| C2 | **Four switches and one action.** `god` (no damage from a weapon or an explosion, and no stun), `ammo` (no ammunition, no heat, no overheat roll, no jam -- and, in the base, an open armoury: the Upgrade screen lists every weapon whatever the base's tech band and waives the skill requirement, raising the soldier's skills to it without spending TP; the price is still paid and the equipment half is untouched), `kill` (the shot connects and kills -- except the non-lethal modes: weapon 47, the Enhanced Laser's second mode, connects and converts, and weapon 45 connects and stuns, so a mission that needs its target alive, `_C_173`, stays playable), `moves` (the movement points come back after a move, a shot, a use **or** a warp -- `aExecuteWarp`'s call site zeroes them outright, so it is the fourth charge and not an exception), and `nuke` -- a one-off that kills every unit no human seat controls. `nuke` is deliberately not a switch: it has no state to be in. |
| C3 | **"Mine" is `turn.player_kind[unit.player] == KIND_HUMAN`**, so the aliens' player 255 is outside the array and can never be protected, and the switches hold in a two-human session as well as in the campaign. `Cheats.controlled` is the single test; the four questions the rules ask (`shielded`, `armed`, `lethal`, `tireless`) are static and null-tolerant, which is what lets every seam default its argument to `null` and change no existing caller. |
| C4 | **The shield borrows the Damage Absorber's own mechanism.** `applyDamage` is still called with the damage argument **zeroed** rather than skipped ([`22` §7.5](22-combat-and-visibility.md)), so the generator lands exactly where it would have and a cheated world's picture and truth stay in step. Both weapons and mines go through it; `Combat.apply_damage` itself is untouched. |
| C5 | **The one-shot kill is written after the roll, not as damage 255.** `applyDamage` subtracts armour from any damage and refuses `IMMUNE_UNIT_TYPE 0x23` outright, so a large number is not a kill. The hit is forced with the `GUARANTEED_HIT_SPECIALS` idiom and the remaining health taken off after the call -- and never off a unit `god` protects, so the two switches held together do not make friendly fire lethal. |
| C6 | **The refund is the allowance, not the value before the charge, and it runs before the command's journal boundary** so the pad draws it in the same delta as the rest of the command. `Allowance.for_unit` is what a hand-over would have given, so a unit that stood down, is out of fitness or carries an action state that zeroes the allowance still gets nothing: the switch makes an action free, it does not lift the rules that say the unit may not act. |
| C7 | **Scripted deaths are not blocked, and that is the point.** `god` answers everything a weapon reaches a unit with -- the shot, the mine -- under a walk, under a warp landing **and** under a crate pushed onto one ([`26` §6.2](26-interaction.md), the arm whose own header warns it can kill the pusher) -- the ground fire weapon 40 lays ([`42` §9.1](42-mission-presentation.md), which removes rather than damages, so the shield there is the removal not happening) and the shooter's own gun destroying itself at the heat cap ([`22` §7.3](22-combat-and-visibility.md)'s roll of exactly 30, downgraded to the damaged-weapon arm it shares an instruction with). The mission script's own `KillUnit` and a walk into a hole are **not** intercepted: a level being tested has to let its own scripted deaths happen, or the thing under test is not the level. `nuke` leaves [`21` §5](21-info-lcl-schema.md)'s species 2 standing for the same reason -- barrels and cases are scenery, not enemies. |
| C8 | **Three ways in, and the typed one is hidden.** A rolling key buffer cannot work: the classic letter keys issue command-pad and interface actions while arrows move the camera, so typing a code would act on the mission on the way. `` ` `` opens a silent line that owns the keyboard instead (`ESC` cancels it rather than raising the shell); nothing is drawn while a code is typed and nothing is drawn for a code that matches nothing. `--cheats=god,ammo` is the launch entry a level is actually walked with, and the control server's `cheat NAME [on|off]` is the scripted one. `GET /state` reports which switches are on -- above its `world == null` return, so a scenario that fails before a mission is built says so too. **Opening the line is behind every input guard** and `nuke` is refused under a playback: it is the one code that writes the world, and resynchronising the mirror mid-replay would leave `EventPlayback` landing the deltas of a turn that has been overwritten. |

### 7.19 The screens between the screens -- intros, cutscenes, briefings and the holds (2026-09-08)

Everything the original shows *between* missions and the map was missing: the
boot splash, the four-part intro, the six dialogue cutscenes, the two endings,
the credits, the briefing's typewriter and voice-over, the loading screen and
the base's fly-in. The game ships **no video**: every cutscene is a real-time
Charisma scene in `Video/<dir>/` ([`41`](41-sequence-player.md)), every splash
a 640x480 plate already in the cache, and every transition a hard cut with
one of three `Sleep` holds. So this is a converter pass, a GDScript player,
five small screens and wiring -- and a set of corrections to `41`, `27`, `24`,
`28` and `20` that the wiring forced. [`101`](101-slice-9-report.md) is the
report.

| | Decision |
|---|---|
| I1 | **Cutscene music comes from the `Track` family**, missions and the front end keep the measured `Arack` ([`28` §6.1](28-effects-and-sound.md)). The parts' programs name CD tracks 9..19 and the shipped shim's `Arack` stops at 14, so the shipped build plays five of the twelve cutscenes in silence; `Track` covers all eleven. It is a separate namespace in the cache, `audio/music/track/<n>.ogg`, behind the same `--no-music` flag. |
| I2 | **Transitions are the original's**: hard cuts and the three measured holds -- 1500 ms after the logo (`0x0044BCF1`), 1000 ms after a sequence (`0x004571D1`), 4000 ms after the animated extro (`0x0045718C`) -- no fades. The holds are a countdown in `SliceMain._process`, so the agent's `wait` sees them and a suite steps them. |
| I3 | **The gate is `0x00456FC0`'s and runs at mission control's entry**: mission id 1 with the intro flag plays logical id 0 full screen and clears the flag; id 180 is the static extro; id 255 the animated one; anything else the map. The flag is `CampaignState.intro_pending`, set by `start_new` for chain 1 only (`0x00450997`) and inside the save -- a loaded game never re-arms it, as `[0x00510D48]`'s one setter is never called with 1 on the load path. |
| I4 | **`_C_YYY` is a mission row** (id 255) beside `_C_180` (id 180), so `advance()` past `_C_133` lands on an ending and the campaign ends after the credits. [`27` §6.6](27-campaign.md) is corrected: it is not a hand-over to campaign 2. |
| I5 | **A cutscene renders in the main world, not a `SubViewport`**: the player is a `Node3D` under `Main` with a camera of its own (`Camera3D.environment` for the black), drawn through the plate's hole the way the map is; the map's root and the mission's are hidden meanwhile. Full screen for the intro and id 255, framed over `plate_7` for the dialogue locations, exactly the two rectangles `0x004570CE..0x0045710F` write. |
| I6 | **The camera bone's forward axis is measured, not assumed**: over all 130 shots at four frames the mean joint of the drawn parts lies along the bone's engine +Y (Godot -Z after `WorldSpace.engine_matrix`) in 514 of 520 poses; the roll is left as the bone gives it and is the one thing [`41` §7](41-sequence-player.md) still holds open. The focal before a `Focus` note is the construction value `_ftol(width * 10/13)`, 492 or 398, and it carries across a part's shots; `Focus` is the seven-preset table scaled by the window's height over 480. |
| I7 | **One key or click ends the whole sequence**, as `0x00457180` does; `BREAK` notes are not read. The framed screen shows *Please Wait...* (text 0 at (320, 210)) until the first frame lands, which is what `0x00456F30` paints behind the window. |
| I8 | **The splash, the credits, the static extro and the message screen are `CampaignScreen`s** on the shipped plates with no literal caption: `Txtmod_a` 5 at (290, 420) on the title, 7 and 8 at (450, 410) and (250, 410) on the credits, `Txtmod_b` 4 at (450, 430) on the ship, `Txtmod_b` 0 centred at (320, 65) on `MsgScr`. `MessageScreen` is shown for two drawn frames before the map or a mission is built, so the build is a picture rather than a frozen frame; it is raised where `aPrintMessageScreen`'s two callers raise it -- mission control's entry and the debriefing's exit -- and not, deliberately, for the mission build itself, which the original does not announce. **The credits are not only their two buttons** -- corrected 2026-09-10 by [`101` §14](101-slice-9-report.md): `Menu_a.lcl` carries the buttons and the *roll* is in the executable, `fcn.0044BD90` walking `Txtmod_a` 161..339 up the plate's dark half at 20 units a second. It is the one screen drawn through a [SubViewport]: a plate unit is a fraction of a pixel in a real window, and text and rules that each round it their own way tremble against each other -- `docs/101` section 14 records the five passes that tried to avoid one. |
| I9 | **Menu music is `"2,3,4,5,6,7"`, the credits `"8"`, the debriefing `"7,3,2"`**, all `Arack`, each started with the `_play_map_music` guard so a rebuilt screen does not restart the track. Mission control's own `"5,4,2,5"` is read and **not played**: the map's `INIT MAP` starts `_C_XXX.lcl`'s `CDTrackProgram` immediately after it and that is what is heard, so the remake plays the map's alone. The five programs join every cache's playlists under `frontend/<name>`. |
| I10 | **The briefing types at one glyph a frame, 20 a second**, blipping `textbeep.wav` on every word's end (`fcn.0043ECF0`, `0x0043E3C1`); the campaign's briefing page types, the page recalled by `B` over a mission does not. **The deployment screen carries no briefing box** — the slice put one there and it is removed (2026-09-09, [`24` §7.1](24-briefing-text.md)): `0x0044EEDA` is `Menu_a` window 10 `:Leveloptions;` gadget 22, the multiplayer *Infos* button, and no `aActivateBriefingInfo` site is in `SelectUnits`'s arm. The voice-over `MB1xxAIF.WAV` plays with the page and stops with it. **Corrected 2026-09-09, having been exactly backwards:** `0x0043B1F0` is not a briefing switch but a multiplayer predicate — `[0x00509F08] && gameMode() in {2, 4} or (3 with more than one human)` — and a campaign is mode 1, so it is always false there. The mission-start `A0` popup is the arm taken when it is **true**, so a campaign never shows it and the slice's popup is removed; the map's `B0` is the arm taken when it is false, so a campaign **does** draw it, on the key `B`, which `0x00451240` maps to mission control's action `0xb` ([`24` §7.1](24-briefing-text.md)). |
| I11 | **The upgrade base's fly-in** starts on the first waypoint looking at the target and flies down the rest, a leg ending within 3200 on every axis. **Read whole 2026-09-09** ([`27` §2.7](27-campaign.md), which closes its §10 item 8): 20 units a frame was only the *first* frame, the velocity approaching `_ftol(direction x 800)` by `(want - velocity) / n` with `n` falling 40 to 5 per leg, the last leg counting itself down to a tenth, the frame limited to 20 a second by `0x0047F2E0(10, 20)`, and any key or click landing it. It is also a **transition the player watches**: `0x00417510` paints `plate_7` and blocks in the flight, and mission control raises the Upgrade Menu only when it returns. The slice ran the flight behind the menu, where it could not be seen. |
| I12 | **The always-run check grew, and by a known amount.** `remake_convert.py --check` is three conversions and each went from 4 s to 34 s -- the twelve texture sets' VISN decode in pure Python is 20 s of it -- and the six-mission cache from 42.6 to 152.7 MiB (38 MiB of cutscene documents, 11 of their textures, 34 of voice-over waves, 20 of tracks). The ceilings moved with the numbers written down and the "music is 95 % of the growth" check became "the flag changes exactly the music files", because it no longer is. **Most of the time is back since 2026-09-09**: a VISN record decodes to exactly one PNG, so `convert_textures` keys the decoded bytes by the record's own and the three conversions decode each record once between them. The whole `--check` is **40 s** where it was 102, and the memo pays inside a single conversion too, records being shared between texture sets: one cold conversion is **23 s** where it was 34, and `--check-campaign` **30 s** where it was 57. |
| I13 | **The cutscene tracks are the cutscenes' soundtracks, and that is measured** (2026-09-09, [`28` §6.1](28-effects-and-sound.md)). Choosing the `Track` family was recorded as a decision because it is the only one covering 9..19; the two families turn out to hold different kinds of thing from 09 on. Every `Track` file is cut to the picture of the part that asks for it, two to seven seconds longer; every `Arack` file is a loop two to four times as long. `Video/` ships no wave, so a cutscene's speech and effects are **in its CD track** -- and the shipped build, which can only reach `Arack` 02..14, is missing five cutscenes' dialogue rather than merely their music. |
| I14 | **A camera-less frame is black.** The 1000 and 4000 ms holds destroy the player before the map's backdrop exists, so Godot painted its default light slate for the whole hold and a grey screen flashed between the intro and the location map. `rendering/environment/defaults/default_clear_color` is black project-wide, which also covers the boot frame before the splash. |
| I15 | **A volume row steps down and wraps from the floor to full.** It stepped up and wrapped max to floor, so one click on a row already at full volume dropped it to `VOLUME_MIN` -- -40 dB, inaudible -- and sixteen more were needed to climb back; the row read `-40.0 dB`, which does not say "silent" to anyone. That is how a session reports a cutscene as having no sound while its track is playing. The row now reads a percentage and the click at the floor restores full. |
| I16 | **An upgrade base's landing pad is not empty.** `0x00417510` starts `P0_M2_000` on every one of player 0's living units before it flies, and each `upgrade_N.lev` places two or three marines, so the transition the player watches is a squad marching down the pad ([`27` §2.7.1](27-campaign.md)). The slice built the backdrop with no bodies at all, on a comment true of `_C_XXX`/`_C_YYY` and of nothing else. The clip is `docs/40` §7.2's **kind-4 literal**, which no selector's closure names and which was therefore not in any cache: `CONVERTER_VERSION` is 0.31.0 for it. The march is the clip's own root motion -- 3017.7 skeleton units over 452 frames, 1.33 m a second at the front end's 20 -- and not a movement command, because no `upgrade_N.lcl` has one. |
| I17 | **A pending hold does not raise a screen over a newer one.** The three `Sleep`s block in the original, so nothing can overtake one; here `hold`'s callback fired after a screen had already gone up and replaced it. `show_campaign_screen` and `open_shell` drop the countdown. It was found through the control server, whose `wait` counts frames while a hold counts drawn seconds -- a player cannot reach the state, because the screen is black and has nothing to click during a hold. |
| I18 | **The strength panel `0x0045FA00` is faithfully absent, and that is now read rather than assumed** ([`24` §7.1](24-briefing-text.md)). `0x0041A980` draws nothing when `0x005106D4` is clear, the full `A0` briefing when it is set and the network predicate holds, and the panel when it is set and the predicate does not. The flag's **only** writer in the image is the arm the map's `B` takes when its own gate fails, and that gate is `0x0043B700() == 1` -- a **count** of the human players, not a flag. One human never arms it, so the panel is the hot-seat shape and the remake has no way to reach it. |
| I19 | **The boot splash is shown once, not on every launch** (2026-09-09). `aGameIntro` `0x0044BCA0` holds the logo 1500 ms, puts the title plate up and waits for a key or a click on *Start Game* — every time the process starts. The two plates cost a second and a half; the wait is unbounded and is paid on every run of a game the player is in the middle of. So `SliceMain.shell_entry` reads `GameSettings.seen_splash` and opens the menu instead, and `_show_splash` writes the flag when the **title** plate goes up rather than at boot, so a run killed on the logo is not counted as one the player saw. Deleting `settings.json` brings it back. It is the same trade `game_font` makes and it is the second one made deliberately. |
| I20 | **The tips page is shown whole; only the briefing types** (2026-09-09). In the original both pass `animate = 0` — the briefing at `0x00456DCB` and the tips at `0x00456D81` — and both reveal a glyph a frame. The tips are a reference page the player opens to look one thing up and closes again, often for the second or third time, and typing them out is a wait for text with no reveal to give; the briefing is the page the reveal is *for*. Going back to `A0` after `C0` does not restart it either, so one visit settles the screen. |
| I21 | **A click or a key finishes the briefing's reveal, and the voice-over keeps reading** (2026-09-09). At one glyph a frame a full `A0` is long enough that a player who has read it once is waiting rather than reading, and the original offers no way out but the whole of it. `BriefingScreen.skip_typing` puts the rest of the block up at once; the buttons take their own clicks first, so *Continue* still leaves the page. The voice is the host's, played under `SliceMain.VOICE_TAG` and stopped when the page is left, so it goes on over the finished text exactly as it would have over the typing one — which is what makes this a change to the reveal and not to the briefing. |
| I22 | **Cutscene `Track` soundtracks follow FX volume, not Music.** I13 establishes that each file is the whole mix -- dialogue and effects as well as music -- so Music at zero must not make the story inaudible. Mission, map and front-end `Arack` tracks remain on Music; briefing voices and the static extro were already on FX. |

The two things it settled outside its own scope: `_play_intro()` (S4) is gone
-- the gate at `show_campaign_screen`'s entry is where the intro lives, and it
is not a step -- and D5 is closed. The two it opened, I6's roll and I11's
pacing, are **both closed since 2026-09-09** and neither needed a Wine
capture: the roll is measured against the scenes' own vertical, down to a
median of exactly zero over 2547 poses ([`41` §7](41-sequence-player.md)), and
the pacing was in `0x00417000` all along, behind a frame limiter the first
reading did not follow ([`27` §2.7](27-campaign.md)).

### 7.20 A shooter aims, and the octant stays the facing (2026-09-09)

The engine turns a shooter with `aChangeUnitViewDirection` into **one of
eight** headings — step 3 of `aAttackUnit` ([`22` §7.1](22-combat-and-visibility.md)),
`fcn.0046A6E0`'s table `0, 0xC00, 0x800, 0x400, 0x600, 0xE00, 0x200, 0xA00`,
the octant chosen by `direction()`'s `|dy/dx|` thresholds of 0.5 and 1.5. The
shot itself is laid along the **exact** line to the target, so the barrel and
the round disagree, and in the original they disagree by as much as **33.69
degrees**.

That number is measured rather than read, and it corrects a comment this
project had delivered in both twins (`tools/inclib/combat.py` and
`godot/core/combat.gd`), which said "the four axis-aligned sectors span 53
degrees and the diagonals 37". The two thresholds are not each other's
reciprocals, so the sectors come in **three** sizes, not two — swept a full
turn: facings 0 and 2, the two along y, **67.38°** each; facings 1 and 3,
along x, **53.13°**; the four diagonals **29.75°**. They sum to 360 as
convincingly as the wrong pair did, which is why it survived being looked at.

| | Decision |
|---|---|
| A1 | **The octant is untouched everywhere the rules read it.** `unit.facing` stays exactly what `Combat.direction` answers — the rear-shot arc of [`22` §7.4](22-combat-and-visibility.md), the ground marker, the direction ring, `CanonicalHash` and the save. The aim is the **picture's** and nothing else asks it a question, so a session that aims and one that does not hash the same. |
| A2 | **What turns is the waist, for the length of the `F` clip.** `UnitsView.aim_twist` is the remainder the octant left, in engine angle units and wrapped the short way round; `CharismaBody` turns every part in one subtree about that joint's own position and leaves the rest of the pose alone. Hips and legs stand still; torso, arms, head and the weapon part `M` turn. It is a deliberate divergence from the original, which turns nothing. |
| A3 | **The joint is found geometrically, not by name.** The shipped skeletons are not one rig — a marine hangs both arms off the **neck** (`Bip01 R Arm` ← `Bip01 Hals`), which no naming convention would have told anyone. Walk the chain from the top-level bone down to `M` and the chain down to the **lowest meshed joint of the bind pose** (a foot), and take the first bone at which the two part company: for `P0_000` that is `Bip01 Wirbelsäule`, the joint directly above where the legs branch off. Resolved once per `CharismaModel`, which outlives the bodies built from it. |
| A4 | **A model with no `M` does not aim.** 89 of the 114 shipped models carry the muzzle part ([`42` §4.6](42-mission-presentation.md)); the rest keep the engine's own octant and nothing is invented for them. |
| A5 | **The aim is held against a rebuild**, which is the half that was a defect rather than a divergence. A shot whose target dies rebuilds the bodies from the mirror *in the middle of the clip* (`SliceMain._land_current_delta`), and a **reaction's** mirror never carries the octant at all — `Reaction.drain` puts the reactor's facing back before the event is marked, faithfully ([`25` §6](25-turn-and-round.md)). So an overwatcher snapped round to where it had been looking while its own shot was still playing. `UnitsView` keeps the aim per slot, the rebuild prefers it to the world's facing, and it is dropped when the clip is — by `rest`, by the auto-rest of a type with no `F`, and by a rebuild that finds nothing to carry. |

---

### 7.21 Touch input (2026-09-11)

This is a **remake input binding**, not a claim about the retail executable.
The Android/iPad input path preserves the plate, command pad, direction letters,
camera arithmetic and command rules. A short tap replaces one mouse click, on
release: shooting still has no additional confirmation, while walking still
requires the original direction ring. `Menu` is the only persistent new battle
control, in the top-left corner before the hint line, using the shipped field art.

`Options / Controls` cycles `Auto`, `Touch`, `Mouse`, persisted in the existing
settings document; a missing or invalid mode defaults to Auto. Auto starts from
`DisplayServer.is_touchscreen_available()` and latches on a real touch. Physical
mouse and trackpad input keep their existing bindings and do not switch the UI
back. Explicit Mouse disables touch gestures/help but still accepts short taps.

| Touch | Binding |
|---|---|
| one-finger drag | mission/deployment pan, **direct manipulation**; free look in the eyes view; campaign map's existing swing |
| pinch | zoom through the existing rig |
| two-finger twist | **one quadrant per 25 degrees** of continued turn in battle/deployment; continuous map swing |
| parallel two-finger drag | free look in battle/deployment; map swing on the campaign map |
| hold for 0.45 s | existing hover information; persistent local equipment/menu tooltip |
| drag a list/volume slider | scroll rows/change volume without activating a row |
| tap during enemy playback | existing skip operation, without changing the resolved world |
| Menu / Android Back | existing Escape menu route; inside the shell it is the shell's own *Back*, and it leaves the application only from the boot menu, where there is nothing behind and nowhere back |

`TouchInputController` owns raw touch events before GUI dispatch. Automatic
mouse-from-touch emulation is disabled; the adapter sends a completed tap through
`Viewport.push_input`, so GUI priority and the existing command handlers remain
authoritative. Movement beyond 8 viewport units, a second finger, or a hold
cancels the prospective click. Pair motion is classified once per frame because
platforms deliver the two fingers separately; otherwise parallel motion can
momentarily look like a pinch. The first gesture type locks until all fingers
lift. Twist recognition starts at 8 degrees and pinch recognition at 15 percent
distance change, in that order: two fingers turning about their centre cannot
hold their separation to better than a few per cent, and at the first pass's
15 degrees against 8 per cent almost every turn was classified as a pinch
before it had turned far enough to say otherwise. A pair already reading as a
pinch or a parallel drag becomes a twist after all once it has turned 20
degrees: the first reading used to be final, so a turn that opened with a few
per cent of separation change -- which is most of them -- stayed a pinch until
both fingers lifted. A battle quadrant is
requested at 18 degrees, measured from the separation at the **last** quadrant
rather than from the one the pair began with, so a finger that keeps turning
keeps stepping; the first pass latched after one, which -- with
`CameraRig.may_rotate_to` free to refuse that one -- read as a turn that only
worked one way round.

Three touch bindings are deliberate **divergences** from the original's own
behaviour, each because the original is a *pointer's* rule and a finger is not
a pointer:

* **The one-finger pan is direct manipulation.** The original's pan is
  `pixels * 400` engine units along the view's forward and right
  ([`42` §2.5](42-mission-presentation.md)) and moves the *camera* with the
  pointer, so the picture slides the other way; at 3200 units to a field, eight
  pixels of travel move the world a whole field. Under touch the shift is
  measured instead — `CameraRig.ground_point` meets the ray with the horizontal
  plane the finger came down on (the cell's own floor, held for the whole drag,
  because the target's height is a soldier's head and not the ground), and
  `CameraRig.pan_units` carries the difference back. The field the finger lands
  on is under it when it stops, to within 2 px. At the map's edge the box
  refuses the pair as one displacement, so the controller offers the two
  components separately rather than letting a diagonal drag along the border
  stick.
* **A drag in the eyes view looks rather than pans.** The pan moves eye and
  target together, so in docs/42 §2.4's first-person view a finger drag walked
  the camera off the soldier it belongs to -- and one direction parked it
  behind him, looking at the back of his head, six thousand units from where it
  started. The original allows exactly the same thing through `0x004037D0`, but
  a mouse reaches it only through a middle drag nobody makes in first person,
  while a finger drag is *the* gesture. Under touch it calls
  `CameraRig.look_by`, which rewrites the target alone and leaves the eye where
  the view put it -- the same call the two-finger parallel drag already makes.
* **The ground overlay's hover gate is off.** `GroundSprites.refresh` draws the
  movement dots and the target bands only while the pointer stands on a legal
  cell ([`43` §3](43-battle-interface.md)); a finger stands nowhere, so
  selecting a soldier showed no reachable set at all and a destination had to be
  guessed at. Under touch the gate is lifted and the set is the selection's own.
* **The synthetic pointer leaves the screen when the finger does.** A `Button`
  wears its hover face until a motion moves off it, and the faces composed out
  of `buttons.LIB` draw `hover` and `pressed` with the *same* lit picture — so
  the list row a finger last touched went on looking exactly as selected as the
  row that was, and running a finger down a list read as several selections at
  once.

Screen/world/playback/modal changes, resize, focus loss and suspension cancel
pending input. Resume discards old finger IDs without treating old releases as
new clicks. A tooltip survives release; the next tap only dismisses it. The
adapter does not add save data, simulation state or original-table constants.

Validation is split deliberately:

* `tests/test_touch.gd` is in the ordinary `run_tests.sh` harness: gesture
  classification, cancellation, one-turn limit, settings compatibility and mode
  precedence. Existing camera, HUD and shell suites remain required.
* `tests/touch_integration.gd` drives **actual viewport events** in a loaded game:
  GUI, held hints, sliders, list rebuilds, real unit/target picking, direction ring,
  campaign selection/map/briefing/deployment, movement, end turn and disk-backed
  save/load, plus the three divergences above: the pan's 2-pixel drift, the
  reachable set drawn with no pointer anywhere, no row left lit after a swipe,
  and the eyes view keeping its eye through three drags with the soldier never
  entering his own picture. It uses isolated `user://inc-touch-integration-*` settings/saves --
  absolute macOS temp paths made the screenshot check fail on Linux for an
  environment reason rather than a real one.
  Run `godot --headless --fixed-fps 60 --path godot --script
  res://tests/touch_integration.gd -- --mission=_C_140` and require
  `TOUCH-INTEGRATION: ... 0 failures`, with no runtime errors. Without `--headless`
  it also captures the 4:3 and 16:10 HUD to `user://inc-touch-*.png`.
* **Physical Android/iPad input, software keyboard presentation and gesture feel
  are UNVERIFIED.** Viewport injection on macOS is not a mobile-device run.
  HUD redesign and new background-save behavior are outside this change.

The root [`Makefile`](../Makefile) is the command-line entry point for the
retail corpus, fixture generation, cache/Godot tests and exports. `make
test-touch` runs the viewport-level touch integration test; `make
build-macos`, `build-windows`, `build-linux` and `build-android` use Godot debug
templates by default; `EXPORT_MODE=release` selects the release template. The
Android preset carries ARMv7 and ARM64; release keystore credentials remain
local (Godot's export credentials or the `GODOT_ANDROID_KEYSTORE_RELEASE_*`
environment settings). `make build-ios` deliberately refuses to
start until a real Apple Team ID is configured locally and full Xcode is
installed; neither a fabricated signing identity nor a provisioning profile is
kept in this repository. Every build goes to ignored `godot/export/`.
`make build-android` first brings all campaign and Instant Action data in
ignored `godot/android_payload/cache` up to date, then requires every cache
manifest entry's size and SHA-256 to agree with the individual file embedded in
the resulting APK. The payload is a build **product**, not a step: it is
converted again only when the converter's own sources change, when the
`Makefile` changes, or when the arguments it was built with differ from the
ones recorded beside it -- a minute and 200 MiB that used to be paid on every
export. `make android-cache-force` rebuilds it regardless. The stamp is a file
of its own rather than the cache's manifest, because the converter refuses to
replace a `cache/` directory that does not look like one of its own, so
deleting the manifest to force a rebuild leaves a payload nothing will
overwrite.

### 7.22 The battle interface — four decisions the backlog's Stage 3 asked for (2026-09-12)

The third stage of the backlog (`102`, retired 2026-09-13) named three things as
decisions for the project owner. Read against the binary, two of them were
not decisions at all, and the third is settled here so the backlog can drop
it. [`43`](43-battle-hud.md) and [`28` §2.5](28-effects-and-sound.md) carry
the evidence; this is the record of what the remake does.

1. **There is no clickable map to grow, because there never was one.**
   `aMI.cpp` is the mission's *map interface* module — the two button columns,
   the radar and the view placers — and its three "unplayed" cues were the
   columns' press and hover tick and the map-view placer's `select.wav`,
   mislabelled as a map click, a compass and a view nobody reaches. All ten
   interface cues are played now, each from the widget the routine belongs to:
   `click_2` on a column button and on a pad socket, `click_1` when the pointer
   lands on a lit slot of either, `select.wav` from whichever placer the view
   mode reaches (the unit and map placers; the eyes and the overview are
   silent). The radar stays a radar: a click on its screen steps the scale, as
   the original's does, and nothing else on it is clickable in either.
2. **The four widget clicks are not panned.** The original pans them by the
   pointer's x through the *speaker position* option; the remake has no such
   control (§7.1) and which speaker the shipped `+1` puts a left-column click
   in is unverified. A pan played on a guess would be worse than none.
3. **The far view is reached through the *Overview map* button, not by
   zooming.** Mode 0 stands at `0x23A50`, above the `0x17700` gate, in the
   original and in the remake alike, and the flags are drawn there. The zoom
   stays clamped to the mission's authored ceiling. Whether the original's
   own height keys (`0x004037D0`, ±2000 a press) can climb past that box is
   not read; the button is the route the original itself provides, and the
   remake offers no second one.
4. **The plate that says the aliens are moving is a declared divergence.**
   The original's between-players screen `0x0047C2C0` reaches only two of its
   seven arms in a single-human campaign: state 0, which dismisses itself by
   posting its own click and shows for one frame, and state 2, whose arm
   prints no caption at all ([`43` §7.3](43-battle-hud.md)). Every caption the
   routine carries is a multi-player caption. The remake's plate with the
   progress bar and the words is therefore the remake's own — kept because a
   silent screen for the length of a computer turn reads as a hang — and not
   a screen the original has that the remake lacks.

Two closures of the same day that are not decisions, only recorded here so
§7 stays the one place: the plate is set in **one font**, `font_0`, the
handles traced ([`43` D7](43-battle-hud.md)); and the campaign map draws
`fcn.00418F40`'s own picture — the white ring on every open location and the
band badge over the pointed-at one — instead of dots coloured by kind
([`43` D6](43-battle-hud.md), [`27` §2.6.3](27-campaign.md)).

### 7.23 Deployment is the battle interface on turn 0 (2026-09-13)

Reported by the project owner: *"in the original the units are placed in the
game itself — the deployment is done in play mode and the game starts from
the end-turn button; in the remake it is a separate window, and there are
some nuances with the start of the turn."* The nuance was the remake's own:
its deployment screen pressed *Next player* **for** the player from its
*Continue*, so the first `NEXT TURN` — the platform ride `_C_106` opens with
— fired out of a button that said nothing about a turn.

[`43` §5.5](43-battle-hud.md) reads `aPI.cpp`, and the remake now does what
it says. A mission opens on turn 0 with the HUD up and the camera over the
landing zone; the unit panel shows the roster's first record and the left
and right halves of its band pick the previous and the next; a click on a
landing dot places the soldier **facing the quadrant of the screen the click
was in** (left-bottom 4, left-top 6, right-top 5, right-bottom 7 — the fifth
argument of `aTransferUnitFromPoolToMap`, which [`27` §3.4](27-campaign.md)
had missed); a click on a placed pool candidate takes him back; and the
player presses *Next player* — Enter — themselves. The dots are the ground
overlay's states 70…73, on every landing cell whether or not somebody stands
on it, exactly as `markDeploymentCells` leaves them. `SelectUnitsScreen` is
deleted; the pause menu's abandon entry is the way off a turn-0 map, and in
*Instant Action* it is captioned *Back* and lands in the HQ.

What the remake keeps of its own, each named where it is made:

1. **The refusals stay spoken, on the HUD's caption line** (§7.4). The
   original's place interface says nothing because a click that does nothing
   does nothing; the remake writes a standing line into the (60, 22) label
   — the button captions win while the pointer is on one — with the hint,
   `pool_empty`, and every refusal name of `World.deploy_from_pool`,
   `World.recall_from_map` and `CampaignHost.recall`.
2. ***Next player* over an empty map is refused, not obeyed.** The original
   hands over and the player loses by wipeout on turn 1 ([`27` §6](27-campaign.md)'s
   `turnCounter() > 0` gate is what lets the empty map through). The remake
   keeps the player on turn 0 and says `need_one`. The button stays lit —
   a dark button would be the silence §7.4 removes — but the press is not
   heard: the refusal is made before `click_2`, which is the sound of a
   press the interface obeyed.
3. **The roster keeps its gaps.** The original compacts the pool on every
   placement (`aRemoveUnitFromUnitPool`, `0x00478DEE`) and indexes the
   compacted row; the remake's selection is a roster slot and the original's
   index is its position among the occupied slots, which answers the same
   for every wrap and clamp `game/deployment.gd` transcribes. A take-back
   is where the two orders part: the original appends the record to the end
   of the compacted pool, the remake returns it to the first free slot, so
   the cycling order after a take-back can differ.
4. **A turn-0 save loads back into the place interface**, or onto turn 1
   through `0x0041A073`'s silent arm when the pool is empty and the game is
   a campaign (`gameMode() == 1`; *Instant Action* takes the interface over
   an empty pool) — the two arms a load's re-entry into `aInitBattleGround`
   takes. The old rule, that a
   loaded turn-0 world "owes its opening hand-over" and gets one at once, is
   withdrawn: the hand-over is owed, and *Next player* pays it. Slots 31
   and 33 are written as the interface goes up, with the pool still full —
   where the retail `_31_.sav` is written (`43` §5.5) — so *Undo mission*
   deploys again and hands over again, `NEXT TURN` included. The corner
   this leaves — a manual turn-0 save taken after everybody was placed
   lands on turn 1 with no `NEXT TURN` — is the reading's own answer and is
   an open question of `43`.

"Deployment is from above" below stands for the camera alone: the map view
over the landing zone is `aInitBattleGround`'s counter-0 arm, and the three
view buttons keep framing the zone, or the first soldier placed, while the
counter is 0. The paragraphs of §7.15 that describe the deployment *screen*
— its window, its dots on the free cells only, its *Main Map* button, the
skip "with nobody to deploy" — are superseded by this section and by
[`43` §5.5](43-battle-hud.md); the skip itself is unchanged and is
`0x0041A073`'s arm, now taken at the mission's entry rather than in front
of a screen.

### 7.24 Coplanar faces recede — by observation where there is one, by the reading where there is none (2026-09-21)

The iris on `_C_154`'s landing platform flickered: `LEVEL09A.005` paints it
as five blade faces and a square backing on **one** plane, and Godot's depth
buffer let a different set of blades win every frame. The original has no
depth buffer, and [`31` §4.7](31-prototyp-geometry.md) reads its span
buffer as "the first face drawn wins", which for the iris means two blades
over a dark disc — and the retail game, watched, shows **all five** over
the backing. The reading is missing a mechanism ([`31` §9 item
8](31-prototyp-geometry.md)); the picture is the picture.

Three decisions carry that into the remake.

**The fact is the converter's, the rule is the mesh builder's.** The tree
that fixes the order never reaches Godot — the cache flattens it — so
`tools/inclib/overdraw.py` derives, per face, how many layers of coplanar
faces lie over it, and the converter writes it as the face field `overdraw`
(absent when zero; 218 faces of 236 861 carry one). A face wholly inside an
earlier coplanar face is on top of it, as observed; two faces that overlap
only in part are layered by the walk order, first in front, as read and
not yet observed either way. Overlap is polygon intersection in the plane
above 64 square units, so wall tiles that share an edge are not touched,
and only the opaque kinds take part: the deferred kinds insert no span and
draw here with the depth write off, where two coplanar additive flames add
in either order. `prototyp_parse.py --check` pins the census (361 same-leaf
pairs, 14 across leaves on their own plane, 47 across leaves on another, 6
with one face inside the other) and the face count. `CONVERTER_VERSION`
0.44.0.

**A losing layer recedes sixteen world units along its face normal.**
`MeshBuilder.receded` moves a marked face `overdraw × 16` units (1 cm per
layer) along the stored winding's Newell normal, which is the side the
material's back-face cull hides. The winner stays exactly where the data
put it; the losers sit behind it. The step is sized for the depth buffer
the project renders with — `gl_compatibility`, 24 bits, not reversed, near
plane 0.05 m — which resolves about 5 mm at the far corner of a 40 × 40
map; four units held at the deployment camera and would have fought again
from across the map. One centimetre is still far too close to read as a
step.
`render_priority` was not an option — Godot 4 applies it to transparent
surfaces only — and neither was a shader offset, which would move every
face. `test_mesh.gd` pins the direction, the step, a two-face build and the
depth of the cached `World_A00`'s marks.

**The camera-dependent pairs are left as listed.** The 47 pairs whose order
the walk decides per camera side get the tree's own order; they are part of
[`31` §9 item 8](31-prototyp-geometry.md), and none has been seen
flickering yet.

### 7.25 The renderer stays `gl_compatibility` — measured against Mobile (2026-09-22)

`project.godot` has named `gl_compatibility` since Slice 1 with no reason
written down. The Mobile renderer (Metal on Apple, Vulkan elsewhere) was tried
on this date: one line changed, the same five scenes captured under both
(`_C_154` at the deployment camera and two quadrant turns, `_C_115` with and
without the field-type overlay and the lattice, `_C_129` on turn 0, the
shell, the campaign map, the upgrade and credits screens, and an *Instant
Action* computer turn on `_S_004` for an additive muzzle glow), and a probe
scene that renders known `Color8` values through an unshaded material and
reads the frame back. Only Metal was exercised; the Vulkan targets were not.

**What is the same.** Opaque geometry is pixel-identical at a 5 % fuzz on
every mission view — the `_C_154` iris §7.24 was tuned on holds under both
depth buffers — and so are the 2D screens and both `SubViewport`s (the
upgrade screen's turning soldier with `own_world_3d`, the credits roll).

**What Mobile changes, and why it is not taken.** The original blends in
place on the framebuffer's own RGB565 values: the additive kind is a
saturating per-channel add of the texel, the subtractive kind the same
subtract, the translucent flat fill an exact half-and-half
([`31` §4.4](31-prototyp-geometry.md), kinds `0x1c`, `0x20`, `0x0c`), and
the Glide build sets `grAlphaBlendFunction(ONE, ONE, ...)` on the same
gamma-encoded surface. Compatibility stores
sRGB and blends in that space, which is the same arithmetic; Mobile blends
in linear light and no material flag reaches the framebuffer. The probe,
red channel, a texel of value *v* over a background of 40:

| *v* | add, GL | add, Mobile | 40 % alpha, GL | 40 % alpha, Mobile |
|---|---|---|---|---|
| 74 | 114 | 85 | 53 | 57 |
| 128 | 168 | 134 | 75 | 89 |
| 200 | 240 | 203 | 104 | 136 |
| 255 | 255 | 255 | 126 | 172 |

GL is `40 + v` and `0.4 v + 0.6 × 40` exactly; Mobile is up to 46 levels
off in either direction, and the muzzle glow on `_S_004` read as a tighter,
dimmer halo. The second deviation is at the dark end: Mobile keeps its
colour buffer in linear light with the tonemap white pinned at 2.0, so a
sRGB value below about 31 lands on a ladder — 0, 6, 13, 18, 22, 31 for
inputs 1, 4, 11, 16, 21, 31 — and the whole picture's blacks come up. The
`hdr_2d` viewport setting was tried and is not the knob: it changes what
`Viewport.get_texture()` reads back (the `/shot` route would hand out linear
data) and nothing else here.

**What was kept.** `vertex_color_is_srgb` is now set on the two materials
that read a vertex colour as albedo (`MeshBuilder`'s flat kinds and the
terrain overlay). It is inert under Compatibility; under Mobile the overlay
washed out without it, and with it the flat colour means the same thing
under any renderer.

**One pre-existing deviation the probe found in the shipped renderer, and
its correction.** An opaque texel of value 11 rendered as 5 under
Compatibility, 16 as 11, 21 as 17, 31 as 29, exact from 62 up — through
`albedo_texture`, `albedo_color`, a raw `ALBEDO` in a custom shader, a
`Sprite3D` and a `SubViewport` alike, while the 2D canvas and the clear
colour draw the byte as it is. The mechanism, pinned to within one level on all 256 values: the
GLES3 scene shader converts the fragment's colour with its polynomial
`srgb_to_linear` (`c·(c·(c·0.305306011 + 0.682171111) + 0.012522878)`) and
the output is encoded with the simplified `linear_to_srgb`
(`max(1.055·c^(1/2.4) − 0.055, 0)`), and the two are not inverses of one
another below about a quarter grey. The RGB565 expansions the converter
writes (`0, 8, 16, 24, 33, 41, …`, six-bit greens) were reaching the frame
as `0, 1, 11, 21, 31, 39, …` — every dark surface in every mission a few
levels too dark, since Slice 1.

`game/palette_curve.gd` undoes it at the loading boundary: a 256-entry
table, the byte whose round trip lands nearest the wanted value, applied to
every texture of a bank in `MeshBuilder.load_textures` (before the colour
key, which the table's `0 → 0` keeps exact) and to a flat face's vertex
colour in `_surface`. Against the measured table the round trip is exact on
234 of 256 values and one level off on the rest (`41 → 40`, `57 → 56` among
the red/blue expansions), below the quantisation the original's own 16-bit
framebuffer imposed; the mission views now read `8, 16, 24, 33, 40, 49, 56,
66, 74` where they read `1, 11, 21, 31, 39, 48, 56, 66, 74`. The pass costs
168 ms on `World_A00`'s 45 textures (2.9 M texels) on this host, the same
order as the colour-key pass beside it. It is inert under any other
renderer, where the byte already arrives unchanged. `test_mesh.gd` pins the
measured head of the table, the model's agreement with it and the round
trip; `tests/probes/palette_curve_probe.gd` is the windowed oracle that
re-measures both — **the constants are Godot 4.7.2's shader source**, and an
engine upgrade re-runs the probe before trusting the table. Not covered: the
`Sprite3D` marks of the ground overlay and the campaign map, whose textures
are the `Art` bank the 2D interface shares, so a remap there would put the
2D screens off by the same amount the other way.

### 7.26 The laser barrier, re-read from its listing (2026-09-22)

Reported on `_C_158`: the lever at `(9, 16)` toggles the barrier on `(17,
19)` off and on again in one script run, and the beam came a second or two
after its sound. A `/state` timeline of the pull showed the shape: `lever.wav`,
then `lbarrier.wav` the instant the script returned, then the `MovePosition`
flight, then the beam — spawned one frame before the flight *to* it and dead
(kind 1, life 9; kind 51, life 16) before that flight landed — then a second
`lbarrier.wav` over an empty forty-frame stage. Three defects, one root: the
`barrier_on` arm had been transcribed from a misreading of
`aPlayLaserBarrier` `0x00413560` ([`42` §8](42-mission-presentation.md),
corrected in place):

* The off arm writes the emitter's joint and returns at `0x00413668`, before
  the `lbarrier.wav` site at `0x0041379F`. `barrier_off` was aliased to the
  same cue and is now silent; `test_sound.gd` pins it.
* The on arm creates the beam and its sound with no tick between, runs the
  per-victim effects, and then flies **once** — `test ebp, ebp` at
  `0x004137FE`: to the emitter's marker with nobody in the beam, else to the
  middle victim's, `victims[n / 2]` at `0x00413926` — and holds on the pool
  loop. There is no forty-frame stage: the `mov ecx, 0x28` is the `rep stosd`
  clearing the forty-slot victim array at `[esp+0x44]`. `SetpieceCamera`'s
  arm now has that shape (lead with beam, kills and sound; one flight; the
  pool), `SetpieceDriver` gives it `POOL_ONLY_FRAMES` beside the crush wall
  and the ground fire, and `BARRIER_FRAMES` is gone.
* The victims were never on the event — `game` re-walked the beam and found
  nobody, since `core` had already removed them — so no `BloodFlood`, no
  `FlyingDebris`, no flight to the middle one. Both interpreters now carry
  them as `slot, x, y` in beam order behind the leading `x, y, dir, count`,
  the statue's pattern (`docs/97` §41.1); `test_lcl.gd` runs a beam through
  three units and a wall.

`SequenceQueue` learned one rule for it: a cue-less stage marked
`holds_sound` passes a held sound on instead of ending it, so the barrier's
flight — a stage inside the routine, between the beam that starts the sound
and the pool wait the routine returns from — no longer cuts `lbarrier.wav`
off. `_check_routine_sounds` in `test_effects.gd` is the check that would
have caught the cut.

The emitter's own turn moved with it: it was written the moment the script
returned, before the `MoveCamera` flight the same script had queued ahead of
it; it is now a one-frame step on the same queue, so the camera arrives and
then the emitter turns, as the routine order has it.

The **stutter** reported with it is the beam's first frame, and it is a
first-use cost, not a per-beam one: the same lever pulled three times in one
session (`/state` polled at 4 ms) hitched on the first pull's spawn frame —
30–90 ms from run to run, against the 8 ms frames around it, before and
after the fix alike — and on neither of the two that followed, where the
worst frame anywhere in the window was the ordinary 13–15 ms. The first pull is the first use of
`A_LASERG.3DI` in the mission: `BlobModels` builds the mesh into its cache
and the driver compiles the material's shader on the first draw. Left as it
is (§9): a warm-up would have to draw, not merely build, and the cost is one
frame once per mission.

### 7.27 The defeat offers *Load Game* (2026-09-22)

The engine's debriefing after a lost mission has one button, *Try Again*,
which puts the mission back to its briefing (D13). A player who would rather
return to a save made a few turns in had to retry, open the pause menu and
load from there. The remake's defeat screen adds *Load Game* beside *Try
Again* — the main menu's own caption (`Txtmod_a` 104), the shell's own slot
list in load mode raised over the debriefing the way the map's *Save* raises
it, *Back* returning to the debriefing and a loaded slot replacing the
campaign as it does from the pause menu. **The defeat only**: a won mission
keeps the engine's two buttons, and *Instant Action*'s report keeps its two,
since a save is not the way past a mission that has been passed and Instant
Action has no campaign to come back to. `test_shell.gd` pins the three
screens' rows; the route was driven on `_C_100` through `gamecontrol 4 1`.

---

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
level is [TurnState]'s own field and enters the canonical hash (§7.14 below,
which settles who writes it), the
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

Of the other two, **the campaign layer** ([`27`](27-campaign.md)) was untouched
at the time, which is why `_C_115` could not be played even though it converted
and drew; and **bodies, animation and sound**
([`40`](40-charisma-model-animation.md), [`41`](41-sequence-player.md),
[`28`](28-effects-and-sound.md)) were still a capsule and a ground marker.

> **Both are now done.** Bodies and sound came with the fourth and fifth slices
> ([`96`](96-slice-4-report.md), [`97`](97-slice-5-report.md)), and the sixth
> ([`98`](98-slice-6-report.md)) built the campaign: `_C_115` and `_C_141` are
> played from a roster, which is what the missing deployment was blocking. Only
> **31 of the 75** shipped campaign missions place a player-0 squad of their
> own; the other 44 needed the roster to exist before they could start at all.

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
  there, the one a remake would actually notice is whether the engine applies
  the root `SkeletonNode`'s own matrix ([`40` §11 item 5](40-charisma-model-animation.md)),
  bounded rather than answered by [`96` §11](96-slice-4-report.md). The rest are
  names for behaviour that is already fully specified, or fields a converter
  carries through unchanged.

  *(2026-09-12: three items this bullet named have been closed where they
  stand and are struck here rather than quietly dropped — the sprite libraries'
  transparent index and out-of-sprite anchors, closed by
  [`60` §6](60-lib-sprites.md) on 2026-09-05; what the dialogue numbers select,
  closed by [`27` §10 item 1](27-campaign.md); and the fourth `SetCtrlMapInfo`
  column, closed by [`26` §10 item 1](26-interaction.md) as dead data nothing
  in `.text` reads.)*

The exact Python packaging technology is deferred. The architectural part is
not: the converter must have a diagnosable first-run flow, never write into the
original installation, reject an unsupported source, produce its cache
transactionally and leave the previous valid cache usable after failure.

Open about localisation (§7.6, 2026-09-13):

* **The readable vector font's Cyrillic coverage** is verified by screenshot
  of the Russian shell, not by a suite; a glyph the default face lacks would
  show as a box.
* **`Graphics/Incubation.bmp`** (4 bpp) in the Russian tree — identity
  unknown; nothing reads it.
* **`brieftext.FontMetrics.width`** is cp1252-only and unused by the
  converter ([`24`](24-briefing-text.md) open questions).
* **`Video/Seq_4/Textures`** of the Russian release differ from the base's
  and are not carried: the cutscene's title card stays the base language's.
* **cp1252 for German, French, Spanish and Italian** is a table row with no
  data behind it (`inclib/language.py`, `UNVERIFIED`).
* **The Russian cutscene soundtracks are dubbed and not carried.** A
  cutscene's speech is in its CD track ([`28` §6.1](28-effects-and-sound.md)),
  and the 1C discs re-recorded tracks 09..19: the envelope of each against the
  GOG `music/Track*.ogg` correlates at 0.2–0.4 where the music-only `Track03`
  correlates at 0.97 (measured 2026-09-13 on the `.iso` images' audio tail).
  That tail holds the first 2048 of every 2352 bytes of each audio sector —
  13 % of the samples are gone — so it is evidence, not a source. Carrying
  them needs a raw (`.bin/.cue`) rip of the discs and a `lang/<N>/music/`
  arm in the pack converter, which today reads the music from the base only
  by design. Deferred by the user, 2026-09-13.

Open about the picture (§7.25, 2026-09-22):

* ~~**Compatibility darkens a texel below 31.**~~ **Closed the same day**:
  the GLES3 polynomial decode against the simplified encode, corrected by
  `game/palette_curve.gd` (§7.25). Still open under it: the `Sprite3D` marks
  drawn from the shared `Art` bank are not corrected, and the correction's
  constants are the engine version's.
* **Mobile was exercised on Metal only.** Vulkan on Windows, Linux and
  Android and Metal on iOS were not run; §7.25's tables are from one host.
* **A model blob's first draw hitches once per mission.** The laser barrier's
  first beam cost a ~30–90 ms frame on this host and its repeats none
  (§7.26): `BlobModels` builds the `.3DI` mesh into its cache and the
  Compatibility driver compiles the material's shader at the first draw. A
  warm-up at mission load would have to draw every model the world set
  carries, not merely assemble it; not done, the cost being one frame once.

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
  box ±1600 on X and Y at Z = 80, one cell of the victory-point marker atlas
  ([`42` §9.3](42-mission-presentation.md)). Six inanimate types have a real
  model. The living bodies come through Charisma's hard-wired switch
  ([`40` §7.2](40-charisma-model-animation.md)). *(2026-09-07: the remake
  had drawn the column's quad under every living unit as well — a grey `B`
  and a white frame — on the belief that the engine draws it; the original
  shows none under a marine, and `UnitsView` builds the column only for a type
  the selector gives no body, which is what a barrel is. The capsule stands
  in past both.)*
* **There is no terrain surface in a `.lev`.** The ground lattice's prototype
  `S003_00X.3DI` is an octagon 320 world units across — a fifth of a metre, an
  editor marker for the cell centre, not a 3200-wide tile. The visible ground is
  the `.3DW` clones plus the special objects; the lattice only carries the
  height. Nothing has to be generated to fill the steps between heights, and
  those steps are correct rather than missing walls.

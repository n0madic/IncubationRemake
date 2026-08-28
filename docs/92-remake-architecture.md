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

**Revisit order:** first profile a complete representative computer turn. If the
move map is material, consider memoisation with an explicit world/navigation
revision in its key. If it is still too slow, move **the flood fill alone** into
a GDExtension. Not the core. No performance threshold or optimisation is a
contract until the first vertical slice supplies a measurement.

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

`aRandom` is the opposite case: a Lehmer generator modulo 2³¹−1
([`22` §3](22-combat-and-visibility.md)) is *easier* in 64-bit, because the
intermediate product fits and Schrage's method is unnecessary.

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

The exact portable mesh and binary-data containers are deliberately selected by
the first vertical slice (§10), because they must be tested in an exported Godot
build rather than chosen from format names alone. Every production cache has a
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
is not by container but by lifetime, because package C established that **six of
the twenty-three bytes are live state and seventeen are map data**
([`26` §3.1](26-interaction.md)).

So: two objects, and **struct of arrays, not array of structs**.

* `MapResource` — the immutable authored grid that `core` constructs from the
  converter's engine-independent data: heights, field types, action points and
  object arrays.
* `MapState` — the mutable fields interaction writes, each a `Packed*Array` of
  `width × height`, initialised from the resource: height `+0x01` and field type
  `+0x0D` (doors), the action point `+0x0B` (every pickup, both levers, the
  entry point, a captured VictoryPoint), the unit link `+0x07` (pushes and
  teleports) and the four effect bytes `+0x0E`…`+0x11` (mines).

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

The remake save contract is not yet fixed. Before it is treated as public it
should consider a schema version, map/cache identity and hash, full mutable map
state, campaign and turn phase, RNG state, the active compatibility flags,
optional presentation state such as the camera, integrity checking, atomic
writes and migration tests. This is a checklist for implementation, not a claim
that every item or representation is already decided.

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
would make the highlighted range a lie. Consequence worth writing down: a unit
may climb a ladder only from a full allowance and arrives with nothing left.

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

The product choices in §7 are the current defaults, but the remake has not yet
started and the architecture is not frozen. In particular, the first vertical
slice still has to validate the converted-data containers and schema, Godot
materialisation path, save representation, fidelity trace shape, cache
invalidation and the practical `game`/`core` boundary. A decision changes only
when implementation or a new observation supplies a better fact, and this file
records the change and its reason.

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

## 10. First vertical slice

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

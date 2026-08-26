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
   worst case is millions of cell operations per computer turn — on the order of
   a second or two in statically-typed GDScript. Acceptable for a turn-based
   game, and most of it disappears with memoisation: the original rebuilds the
   move map for every action because in 1997 memory was the scarcer resource.
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

**Revisit trigger:** if profiling shows a computer turn taking longer than about
two seconds *after* the move map is memoised, move **the flood fill alone** into
a GDExtension. Not the core.

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
against the Python reference.

`aRandom` is the opposite case: a Lehmer generator modulo 2³¹−1
([`22` §3](22-combat-and-visibility.md)) is *easier* in 64-bit, because the
intermediate product fits and Schrage's method is unnecessary.

---

## 3. Asset pipeline — **Python stays**

The loaders and converters remain the Python in `tools/`, extended rather than
reimplemented. Writing them in Python is faster and more pleasant than in
GDScript, `inclib` already implements every format, and each one already has a
corpus check behind it.

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
  converter runs once, writes a cache, and the game loads only its own data
  afterwards.

### 3.2 What the converter emits

| Source | Target | Note |
|---|---|---|
| `prototyp.bin` geometry ([`31`](31-prototyp-geometry.md)) | `ArrayMesh` | the bytecode, BSP tree included, is evaluated offline into static meshes |
| `.cho` / `.cha` ([`40`](40-charisma-model-animation.md)) | `Skeleton3D` + `Animation` | bone names already match part names |
| `texture.lib` VISN ([`50`](50-visn-textures.md)) | `ImageTexture` | the decoder is byte-exact against the original DLL, 723/723 |
| `.LIB` sprites and fonts ([`60`](60-lib-sprites.md)) | `Texture2D`, `BitmapFont` | hotspots are already extracted |
| `.lev` grid, units, objects ([`10`](10-lev-mission-format.md)) | a custom `Resource` | logical data, not geometry; visible in the inspector |
| `Info.lcl` balance tables ([`21`](21-info-lcl-schema.md)) | a custom `Resource` | one row per unit type, weapon, equipment |
| `.lcl` mission programs ([`20`](20-lcl-language.md)) | a custom `Resource` | the AST, not the source text |
| `DATA/TXT` briefings ([`24`](24-briefing-text.md)) | a custom `Resource` | labels resolved, markup kept as structure |
| `.wav`, `.ogg` | copied unchanged | already standard formats |

The cache lives under `user://`. During development it is convenient to have a
second branch that emits glTF and PNG so a model can be opened in Blender and
checked by eye; that is a debugging aid, not the production path.

---

## 4. Layering

```
tools/                Python. Format loaders, converters, and the corpus checks
                      that prove them. Also the executable reference for the
                      specs -- see 5.
core/                 GDScript. Grid, units, move map, combat, visibility, AI,
                      the turn. No scene tree, no rendering, no singletons.
game/                 GDScript + Godot. Rendering, camera, input, audio, UI.
                      Depends on core; core never depends on it.
```

The rule that matters is the direction of the arrow: `game` knows about `core`,
`core` knows nothing about Godot beyond `RefCounted` and the built-in types.
That is what keeps the core testable headless, and it is the only part of the
earlier "separate language" proposal that was actually load-bearing.

---

## 5. Fidelity testing

Three assets this project has that most remakes do not:

**The Python implementation is the reference.** Every rule the remake encodes
already exists as a checked implementation in `tools/`. The GDScript core can be
diffed against it on the same fixtures — 155 `.lev`, 237 `.cho`, 245 `.cha`,
723 textures, 26072 geometry records — instead of against someone's memory of
how the game felt.

**The original runs.** `tools/wine_visn/` already calls the shipped `Eng3d.dll`
under Wine and reaches 723/723 byte-exact. The same harness shape works for
behaviour: the original beside the remake as an oracle.

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
player ([`41`](41-sequence-player.md)) — and every line of mission text.  All
packages in [`91`](91-game-logic-research-plan.md) are delivered at their
documented verified-static boundaries.

A first vertical slice needs nothing that is not already done: convert one
mission, draw the grid, and light up the reachable cells from
[`23` §7](23-ai-system.md)'s move map. That is the first moment at which the
remake is demonstrably the same game.

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

One setting covers the whole first list — `Faithful`, on by default — not one
per defect.

### 7.2 The grid — the authored map and the live state are two structures

The question was posed as a choice of container: a `Resource` with typed arrays
against a `PackedByteArray` mirroring the original's 23-byte cell. The right cut
is not by container but by lifetime, because package C established that **six of
the twenty-three bytes are live state and seventeen are map data**
([`26` §3.1](26-interaction.md)).

So: two objects, and **struct of arrays, not array of structs**.

* `MapResource` — what the converter writes once and nothing ever mutates: the
  authored grid, its heights, field types, action points and object arrays.
* `MapState` — only the six fields interaction writes, each a `Packed*Array` of
  `width × height`, initialised from the resource: height `+0x01` and field type
  `+0x0D` (doors), the action point `+0x0B` (every pickup, both levers, the
  entry point, a captured VictoryPoint), the unit link `+0x07` (pushes and
  teleports) and the four effect bytes `+0x0E`…`+0x11` (mines).

What this buys that neither original option did: a save is the delta, not a copy
of the map — the reason the original's `.sav` has to embed a whole `.lev`
([`11`](11-save-game-format.md)) is precisely that it lacks this split;
fidelity diffing against the Python reference runs array against array, each one
mapping 1:1 onto a documented byte offset; and the move map's flood fill over
up to 1600 cells reads contiguous packed arrays instead of dereferencing a cell
object per step, which is the one hot path [`23`](23-ai-system.md) has.

This is the only decision here that has to be taken before code, because it is
the shape everything in `core/` operates on.

### 7.3 Saves — the remake's format is its own

**Decided now, at no cost: the remake's save format is designed around the
remake's state and is never a superset of the original's.** Writing `.sav` would
be a compatibility promise that permanently pins the state model to another
game's — a fixed slot 32, no field for the camera, a whole `.lev` embedded in
every file ([`11`](11-save-game-format.md)).

**Reading** original saves is a one-way import that constrains nothing, so it is
deferred rather than rejected: worth doing after 1.0, and worth remembering that
it is the one feature whose implementation would also close three of
[`11`](11-save-game-format.md)'s four open questions, since all three want real
save files. As a feature it ranks low — someone installing a remake is likely to
start the campaign again.

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
and **no user-facing string is a literal in GDScript** — every one comes from
the resource built out of `Txtmod_*.lcl` ([`20` §6](20-lcl-language.md)) and
`DATA/TXT` ([`24` §1](24-briefing-text.md)). That costs nothing today, because
every path in the original already carries a language component. Retrofitting
it means finding every string in the codebase, which is the expensive kind of
change.

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
behaviour by default** and exposes the correction (`TS < 6`) as a setting,
because the four campaign cells that carry the box were balanced against the
shipped behaviour. Consequences worth writing down so they are not
re-litigated: the guard reads a different stat from the one it increments, and
the increment has **no upper bound** — a unit repeatedly using such a box while
its Battle Fitness is below 6 can push Technical Skills past 6. Both are part
of the default path, not defects to be tidied away. This is the case §7.1
generalises.

### 7.9 No play-by-mail

The original's `pbm session` mode is named in the binary ([`25` §2](25-turn-and-round.md)) and its passwords are in
the save format ([`11` §5.3](11-save-game-format.md)), but it was barely a
feature in 1997 and the remake will not have one. Consequences worth writing
down so they are not re-litigated: the `pbm session` arm of the turn's skip rule
and of the equipment-point split need no implementation
([`25` §3.1](25-turn-and-round.md), [`25` §4.1](25-turn-and-round.md)), and
neither does the password obfuscation. Network multiplayer remains a separate
question, still out of scope for the same reason as
[`91` §9](91-game-logic-research-plan.md).

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

---

## 9. What is still open

**Nothing at the architecture level.** Every decision the earlier drafts left
open is settled in §7, and the questions that remain are research, not choices:

* the numbered specs' own **Open questions** sections. Of the items still open
  there, the ones a remake would actually notice are the sprite libraries'
  transparent index and out-of-sprite anchors ([`60`](60-lib-sprites.md)),
  whether the engine applies the root `SkeletonNode`'s own matrix
  ([`40`](40-charisma-model-animation.md)), what the dialogue numbers select
  ([`27`](27-campaign.md)), and the fourth `SetCtrlMapInfo` column
  ([`26`](26-interaction.md)). The rest are names for behaviour that is already
  fully specified, or fields a converter carries through unchanged.

Release engineering — how the converter is packaged and invoked on the player's
machine — is deliberately not tracked here. It is a detail of shipping, not of
architecture, and settling it early would buy nothing.

# Remake architecture — decisions taken

This repository is groundwork for a remake. This file records the decisions
that have been taken about the remake itself, with the reasoning, so they are
not re-argued from scratch; and the decisions that are still open, so they are
not forgotten.

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

* The conversion step ships with the game. Whether that means requiring a system
  Python 3 or shipping the converter frozen with PyInstaller or Nuitka is
  **open — see §7.1**. Either way the source stays Python.
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
([`26`](26-interaction.md)) — and every line of mission text.

Blocked on [`91`](91-game-logic-research-plan.md): the campaign layer (B),
effects and sound (D+E), the interface contract (F), the sequence player (G).

A first vertical slice needs nothing that is not already done: convert one
mission, draw the grid, and light up the reachable cells from
[`23` §7](23-ai-system.md)'s move map. That is the first moment at which the
remake is demonstrably the same game.

---

## 7. Open decisions

1. **Whether the remake reads original save games.** [`11`](11-save-game-format.md)
   specifies the format from the writer and reader chains, but three of its four
   open questions want one real save file. Reading them is achievable; writing
   them is a compatibility promise that would constrain the remake's own state.
2. **The logical grid's representation.** A `Resource` with typed arrays is
   inspector-friendly; a `PackedByteArray` mirroring the original's 23-byte cell
   is closer to the spec and cheaper to validate against it. Package C has now
   settled what a cell has to carry at runtime: besides the authored `+0x0B`
   action point and `+0x0D` field type, interaction mutates the **height**
   `+0x01` (doors), the **field type** (doors), the **action point** itself
   (every pickup, both levers, the entry point and a captured VictoryPoint), the
   **unit link** `+0x07` (pushes and teleports) and the four **effect** bytes
   `+0x0E`..`+0x11` (mines). Six of the twenty-three bytes are live state, not
   map data — see [`26` §3.1](26-interaction.md).
3. **Camera and projection.** The original is a Glide-era 3D scene at 640×480
   with a camera height expressed in metres ([`10` §3](10-lev-mission-format.md),
   1600 units = 1 m). How closely to reproduce its framing — and whether to
   allow free rotation the original did not have — is a design question, not a
   research one. One constraint is settled: **the original does not persist the
   camera.** Its save format has no field for it and loading returns the view to
   its default ([`11` §5.6](11-save-game-format.md)), so keeping the camera
   across a save is a free improvement rather than a fidelity question.
4. **Localisation.** Only `English` ships in the GOG release, but every path is
   built with a language component ([`24` §1](24-briefing-text.md)) and the GUI
   strings live in `Txtmod_*.lcl` ([`20` §6](20-lcl-language.md)). Keeping that
   seam costs nothing now and cannot be retrofitted cheaply.

**Decided, not open: a ladder step follows the move map's rule.** Field type 8,
`Ladder`, has **0 cells** in the shipped campaign, and the two halves of the
engine disagree about what such a step costs: `aBuildMoveMap` charges the
unit's whole movement allowance, while `aExecuteMove` charges the ordinary
`delay + 1` / `delay + 2` ([`26` §5.1](26-interaction.md),
[`23` §7.4](23-ai-system.md)). No data can say which was intended, so this is a
choice rather than a finding. The remake takes **the move map's rule** — a
ladder-to-ladder step costs the whole allowance — because that is the one the
player sees: the map decides which cells light up, so charging anything else
would make the highlighted range a lie. Consequence worth writing down: a unit
may climb a ladder only from a full allowance and arrives with nothing left.

**Decided, not open: the `technical` supply box keeps its bug, behind an
option.** Action point 16 guards on Battle Fitness (`unit[+0x1A]`) and
increments Technical Skills (`unit[+0x1D]`) — a copy-paste slip pinned byte by
byte in [`26` §3.3](26-interaction.md). The remake **reproduces the original
behaviour by default** and exposes the correction (`TS < 6`) as a setting,
because the four campaign cells that carry the box were balanced against the
shipped behaviour. Consequences worth writing down so they are not
re-litigated: the guard reads a different stat from the one it increments, and
the increment has **no upper bound** — a unit repeatedly using such a box while
its Battle Fitness is below 6 can push Technical Skills past 6. Both are part
of the default path, not defects to be tidied away. The same rule applies to
any other original-behaviour bug package C or a later package turns up:
reproduce, document, and offer the fix as a setting rather than silently
diverging.

**Decided, not open: no play-by-mail.** The original's `pbm session` mode is
named in the binary ([`25` §2](25-turn-and-round.md)) and its passwords are in
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

# Incubation — file format documentation

Reverse-engineering notes for **Incubation: Time Is Running Out** (Blue Byte,
1997) and its *Wilderness Missions* add-on, produced from the GOG release in
`gog_incubation/` as groundwork for a remake.

The game directory is treated as strictly read-only. Everything produced here
lives in `docs/` (specs) and `tools/` (Python parsers and extractors).

---

## 1. What the game is built from

Two separate engines, with their own file families:

- **The game/editor layer** — Blue Byte's own `aLIB` and game modules. Source
  tree visible in the binaries as `C:\aProject\...`. Owns `.lev`, `.lcl`,
  `.LIB`, `.pal`.
- **Eng3d + Charisma** — the 3D renderer (`Eng3d.dll`, source
  `D:\PRO\3DLIB\eng3d\`) and the model/animation system called **Charisma**
  (hence `CHData` = Charisma Data, `.cho` = object, `.cha` = animation). Owns
  `.3DW`, `.3DI`/`.dir`, `.din`, `prototyp.bin`, `texture.lib` (VISN), `.cho`,
  `.cha`.

The C++ RTTI of the Charisma engine survives in the shipped binaries, which is
why its class names (`V100ModelDesc`, `KeyFramedAnimationDesc`,
`LinearVectorMovementDesc`, …) are known exactly rather than guessed.

Reconstructed original source layout, runtime-module map, and research method:
[`90-binaries-and-source-layout.md`](90-binaries-and-source-layout.md).
The bounded Wine work — direct save loading, debugger limitations and the first
successful native per-tick blob sample — is recorded separately in
[`91-wine-runtime-probes.md`](91-wine-runtime-probes.md).
Decisions taken about the remake itself — engine, language, asset pipeline, and
the product decisions the specs leave behind:
[`92-remake-architecture.md`](92-remake-architecture.md).
The first vertical slice it describes in §10 is **delivered**; what was built,
what each comparison is worth, what the live engine corrected and what it
measured are in
[`93-slice-1-report.md`](93-slice-1-report.md).
The second is delivered too — the turn, combat, visibility, interaction and the
mission-script interpreter, with `_C_140` played and won in an exported build:
[`94-slice-2-report.md`](94-slice-2-report.md).
So is the third — [`23`](23-ai-system.md)'s planner, so the aliens move, close
and shoot, with a whole computer turn taken from the live engine and the
measurement §2 of `92` had been waiting for since the first day:
[`95-slice-3-report.md`](95-slice-3-report.md).
And so is the fourth — the **bodies**: Charisma models, skeletons and the
three gameplay animation families, so units stand, walk and shoot instead of
being capsules. It corrected three statements in a delivered spec (the model
selector is three-level, the idle selector has a randomised arm, and the model
filename grammar was too narrow) and measured one thing nothing had written
down — bone translations are in 1/16 of a world unit:
[`96-slice-4-report.md`](96-slice-4-report.md).
And so is the fifth — everything that is **not a rule**: the sound layer, the
450-slot blob pool with all 74 update arms diffed tick by tick against
`tools/blob_runtime.py`, the sprite atlas, the three weapon switches, the
set-piece driver and the terrain diff that finally makes a door *move* rather
than silently change its cell's height. Its own finding is `RoofUnit`'s drop
rate — one whole map field per displayed frame — which neither
[`20`](20-lcl-language.md) nor [`28`](28-effects-and-sound.md) carried:
[`97-slice-5-report.md`](97-slice-5-report.md).

Its §14 and §15 are a later pass over what it left open, and they closed two
questions in **other** documents: the shipped build plays the **`Arack`** music
family, read out of `Incubation.exe`'s import descriptor rather than out of the
MCI shim ([`28` §6.1](28-effects-and-sound.md)), and the composition order of a
jointed prototype's three angles is whatever its opcode's `call` names — the two
the shipped data reaches both build `RzRxRy` ([`30` §2.5](30-eng3d-ascii-formats.md)
open question 7), and a later reading of the **call graph** says the stronger
thing: `_E3D_init_matrix_RyRxRz` is resolved into `0x004FA4A0` like 85 other
ordinals and **nothing in `.text` calls or loads that slot at all**. The same
pass corrected `30` §2.5's own "exact matrix, if you want bit-identical
results", which was not: the builder negates each angle before it indexes the
table and its chained triple products shift at every step, and taking the
listed form literally misses four of eight cases the routine was called with
inside a running process. The same pass gave the blob layer its **first native oracle**:
`tools/blob_gold.py` calls each effect creator inside a running
`Incubation.exe`, and the pool it reads back agrees with the static tables
field for field.

Its **§16** is a later pass over the four things §15 left open, and three of
them had a wrong premise. The one worth reading outside the slice is that
`aRandom` is **two generators**, not one: `0x004638E0` is its body byte for
byte over a second seed, it carries eleven times the call sites, and the
engine seeds it from `GetTickCount()` where it seeds `aRandom` to the constant
1.0 — so a mission's *outcome* repeats and its *effects* never do. That is
[`22` §3.2](22-combat-and-visibility.md), and it opened `22`'s first open
question: three unit-pool routines draw from the clock-seeded stream, which is
simulation. The same pass established that a blob's origin is the placed
object's position and that no creator reads the terrain height at all
([`28` §7.6.1](28-effects-and-sound.md)).

**The sixth slice is the campaign** — both chains, the location map, the two
roster banks, deployment onto the action-point cells, the mission end with its
score and payouts, the economy and six screens on the shipped art:
[`98-slice-6-report.md`](98-slice-6-report.md). It is the slice that made the
content reachable rather than one that added a system to a game that already
worked: of the 75 shipped campaign missions **only 31 place a player-0 squad of
their own**, so the other 44 could not start at all until a roster existed.

It corrected three delivered documents. `aInitGameControl` has **two arms** and
a campaign runs the one [`27` §4](27-campaign.md) did not quote, so the
equipment points, the tech level and the skill level are campaign state that a
mission entry never touches — and the tech level, whose global has exactly four
`.text` references in the whole image, **does not grow**: it is 1 from the
first mission to the fortieth ([`27` §5.2](27-campaign.md)). The unit pool's
row 0 is the **live** roster and row 1 the **mission-entry snapshot**, not the
other way round, which four fixture saves settle and
[`11` §5.7](11-save-game-format.md) had read correctly all along
([`27` §3.5](27-campaign.md)). And the campaign scoreboard's four "unknown"
fields are the campaign halves of four pairs, which the debriefing's own
`Txtmod_d` headings — *"In Mission"* and *"In Campaign"* — name aloud
([`11` §5.5](11-save-game-format.md)).

**The seventh slice is the battle interface** — the plate, the two button
columns, the unit panel, the command pad, the radar and, on the ground, the
digits and bands the original blits after the frame:
[`99-slice-7-report.md`](99-slice-7-report.md), on the reading in
[`43-battle-hud.md`](43-battle-hud.md), the one pixel layout the programme had
left out on purpose. It corrected four delivered documents: the move map is
**not** the terrain tile coloured ([`97` §45.2](97-slice-5-report.md)) but a
sprite pass with no depth test; the game's own blitter sits inside the range
[`60` §1](60-lib-sprites.md) had given to LibMaker's writer, and its
`cmp al, 0` closes both of `60`'s open items; interface events 12 and 14 were
the other way round in [`29` §1.2](29-interface-contract.md); and
`aGetDirectionTo` reads the cell's **state byte**, not its action point, in
its mode-0 test and its ratchet ([`23` §3.6](23-ai-system.md)) — a mislabelled
line both executable models had inherited.

---

## 2. Format inventory

| Format | Count | Role | Status | Tool | Spec |
|---|---|---|---|---|---|
| `.lev` | 155 | Missions: field grid, units, scenery placement | **Solved structurally**; grid, units and ground lattice decoded, some fields open | `lev_parse.py` | [10](10-lev-mission-format.md) |
| `.sav` | 6 (gitignored fixtures) | Save games — campaign and play-by-mail | **Solved** from the writer and reader chains and confirmed against six real saves (`tests/fixtures/saves/`, not in git); nine blocks, one of them a complete `.lev` image | `sav_tables.py --check`, `sav_parse.py` | [11](11-save-game-format.md) |
| `.lcl` / `.gcl` | 176 + 2 | Mission scripts, GUI layout, unit/weapon balance tables | **Solved**, interpreter semantics read from the binary. 177 parse; `DATA/Version.gcl` is a bare version string, not a script | `lcl_decode.py`, `lcl_parse.py` | [20](20-lcl-language.md), [21](21-info-lcl-schema.md) |
| `.txt` (briefings, info) | 120 | Briefings, victory/defeat conditions, tips, the in-game database, event and error text; same XOR 0xFF obfuscation as `.lcl` | **Solved**, 120/120. Both readers and the line breaker are reproduced, the layout against the shipped fonts included; the label set the game can ask for is enumerated from the call sites | `brief_parse.py` | [24](24-briefing-text.md) |
| `.3DW` | 42 | ASCII scene: which prototypes are placed where | **Solved** | `3dw_parse.py` | [30](30-eng3d-ascii-formats.md) |
| `.dir` (3DI) | 42 | ASCII build-time index (never read by the engine) | **Solved** | `dir3di_parse.py` | [30](30-eng3d-ascii-formats.md) |
| `.din` | 42 | Binary index into `prototyp.bin` / `texture.lib` | **Solved** (two distinct layouts) | `din_parse.py` | [30](30-eng3d-ascii-formats.md) |
| `.cho` | 237 | Charisma models: parts, skeletons, mesh references | **Solved**, 237/237 byte-exact | `cho_parse.py` | [40](40-charisma-model-animation.md) |
| `.cha` | 245 | Charisma keyframed animations and event notes | **Solved**, 245/245 byte-exact | `cha_parse.py` | [40](40-charisma-model-animation.md) |
| `texture.lib` (VISN) | 21 | Compressed textures, DCT-based codec | **Solved**, 723/723 **byte-exact vs the original DLL** | `visn_decode.py` | [50](50-visn-textures.md) |
| `.LIB` (shape) | 58 | 2D sprites: UI, icons, fonts, cursors | **Solved**, visually verified | `lib_extract.py` | [60](60-lib-sprites.md) |
| `.pal` | 24 | 256-colour palettes (Windows BMP carriers) | **Solved** | `inclib/palette.py` | [60](60-lib-sprites.md) |
| `.IMG` | 42 | Fixed-point atan / sin-cos lookup tables | **Solved** | `img_tables.py` | [70](70-img-tables.md) |
| `Game.opt` | 0 (created on first run) | Player options | **Solved** — a raw 108-byte dump of one `.data` block; every field named from the options screen's own help lines, every default re-executed from `aInitOptions`, and the two dead dwords closed by enumeration | `combat_tables.py --check` (six `opt.*` checks) | [20 §7.6](20-lcl-language.md) |
| `prototyp.bin` | 21 | 3D prototype geometry — a bytecode program, not a mesh struct | **Solved**, 26072/26072 records | `prototyp_parse.py` | [31](31-prototyp-geometry.md) |
| `OBJECT.TYP` | 1 | Config for the object exporter — **the tool that never shipped** | **Solved** (213 bytes, one file, full grammar). Read by nothing; it explains two corpus-wide uniformities and reclassifies eight opcodes as unselected exporter settings | `typ_parse.py` | [30 §2.11](30-eng3d-ascii-formats.md) |
| `.bmp` | 118 | Briefing art, backgrounds, install screens; the briefing program names 89 of them | **Solved**. 108 are under `Graphics/` and the other 10 are installer plumbing; the converter baked 103 of the 108 until the shell slice added the five top-level screens (`Title`, `Credits`, `Ship`, `MsgScr`, `Bluebyte`), so it is **108 of 108** now | `inclib/bmp.py` | [24 §8](24-briefing-text.md), [98 §6](98-slice-6-report.md), [92 §7.15](92-remake-architecture.md) |
| `.wav` | 407 | Speech, SFX | Standard RIFF/WAVE, 8-bit 22050 Hz mono. **125 of the 407 end one byte past their own `RIFF` size** (407/407 scanned): the `data` chunk is odd, the writer added the pad byte RIFF requires and did not count it. Every player reads them; a strict loader warns | — | [97 §43](97-slice-5-report.md) |
| `.ogg` | 32 | Music (GOG re-encode of the CD audio) | Standard Ogg Vorbis | — | — |
| `Rec_0.dat` | 1 | Orphaned file under `DATA/Misc/` | **Dead data** — no shipped binary references it | — | see below |

`Install/*` (InstallShield `.ins`, `.lid`, `.cab`) is installer plumbing and out
of scope.

### Behaviour, not formats

Eight specs in the set describe no file at all.
[`22-combat-and-visibility.md`](22-combat-and-visibility.md) is the arithmetic
between the files: how `Info.lcl`'s stat columns and `.lev`'s unit and cell
records turn into a resolved shot and into fog of war.
[`23-ai-system.md`](23-ai-system.md) is the opponent: what the eleven AI orders
in a `.lev` unit record actually do, how the move map is flooded and costed,
and how a target is chosen.
[`25-turn-and-round.md`](25-turn-and-round.md) is the frame around both: who
moves and in what order, what a hand-over restores, how overwatch and its
interrupt queue work, and what ends a turn.
[`26-interaction.md`](26-interaction.md) is what a unit does with the map it is
standing on: the twenty action-point classes `aExecuteUse` dispatches, doors,
crates, levers, teleporters and mines, and the one thing the computer player
does with any of it.
[`27-campaign.md`](27-campaign.md) is what holds a *campaign* together: the
squad that survives between missions, the campaign map's location model, the
79-arm unlock graph that decides what is playable next, the equipment-point
economy, and the score a finished mission pays.
[`28-effects-and-sound.md`](28-effects-and-sound.md) is what any of that looks
and sounds like: the twenty DirectSound buffers and the volume-control
indirection, the event → wave table, the 450-record blob pool — an Eng3d `object_3d` with
eight fields bolted on — its single fifteen-argument constructor, the 78-arm
update switch and the one texture atlas half the game's effects are drawn from, and the three compiler-generated switches that
turn a weapon id into a muzzle effect, an impact effect and an impact sound.
[`29-interface-contract.md`](29-interface-contract.md) is the information and
operation boundary a replacement UI needs: its selected-unit view, battle
commands, deployment transfer, map-intent boundary, and the LCL layouts/text it
must localise.
[`41-sequence-player.md`](41-sequence-player.md) is the compiled story-sequence
manifest and player lifecycle: logical ids, successive video parts, actors,
cameras, timing, completion, and the campaign trigger boundary.
These eight behaviour specs exist because a loader
that reads every byte of every format still cannot play a turn — nor be played
against, nor be played through. `combat_tables.py`, `ai_tables.py`,
`turn_tables.py`, `interaction_tables.py`, `campaign_tables.py`,
`blob_tables.py`, `interface_tables.py`, `seq_parse.py` and `trace_names.py` are
their checks.

The game-logic research programme is complete at its documented
**verified-static** boundaries:

| Package | Subject | Delivered spec | Checker | Boundary |
|---|---|---|---|---|
| A | turn and round | [25](25-turn-and-round.md) | `turn_tables.py` | rotation, refresh, overwatch, hand-over |
| C | interaction and set-pieces | [26](26-interaction.md) | `interaction_tables.py` | player/AI use, movement interactions, action-point classes |
| B | campaign | [27](27-campaign.md) | `campaign_tables.py` | roster, location graph, economy, mission end |
| D+E | effects and sound | [28](28-effects-and-sound.md) | `blob_tables.py` | event mappings, blob contract, sound lifetime |
| F | replacement-interface contract | [29](29-interface-contract.md) | `interface_tables.py` | information and operation boundary, not pixel layout |
| G | sequence player | [41](41-sequence-player.md) | `seq_parse.py` | compiled manifest, lifecycle, 30 fps timing, triggers |
| H | mission presentation | [42](42-mission-presentation.md) | `presentation_tables.py`, `presentation_gold.py` | the camera, the animation drivers and their speeds, the shot's nine stages, the idle scheduler, set-piece staging, the scenery state byte |
| I | battle interface | [43](43-battle-hud.md) | `hud_tables.py` | the plate's layout and its pieces, the ground overlay's state table, the direction ring, the pad's gates, the columns' events, the panel's blocks, the radar — pixel layout, which F left out |

Multiplayer and play-by-mail are deliberately outside this programme; the
preserved boundary and rationale are in [`92` §7.9](92-remake-architecture.md).

**`DATA/Misc/Rec_0.dat` is dead data.** No executable or DLL in the release
contains the string `Rec_`, and `Incubation.exe` contains no `.dat` literal at
all — the game builds every data path it uses from `%s.lev`, `%s.lcl`, `%s.cho`
and friends. Structurally the file is an 82 632-byte stream of variable-length
records with a recurring 16-byte pattern, consistent with a recorded event or
input log ("Rec" = recording), but since nothing loads it the question is moot
for a remake. Checked across all 11 executables and DLLs.

---

## 3. Highlights

**`.lev` had no prior art.** A survey of ModdingWiki, the XeNTaX archives,
GitHub, and the Battle Isle / Incubation fan communities found no public
documentation of the mission format; the one recent technical project in this
space lists it explicitly as unsolved. The layout in
[`10-lev-mission-format.md`](10-lev-mission-format.md) was recovered here by
disassembling `iDesigner.exe` with radare2, and it is confirmed by an exact
size identity that holds for all 155 shipped files:

```
file_size = 864 + 23 * width * height + 203824
```

**`.sav` is the only format the game itself writes**, and the one that had no
corpus for most of this project's life — the shipped `Work/Saves/` tree ships
empty. What pinned the layout anyway is that `aSaveGame` and `aLoadGame` are
both in the binary and must agree, which fixes every offset exactly; 69 checks
assert that agreement. Six real saves, produced by playing the retail game
under Wine and kept gitignored in `tests/fixtures/saves/`, have since confirmed
the layout and settled or narrowed several field meanings.
[`11-save-game-format.md`](11-save-game-format.md) also settles three things
that were invisible from the read-only formats: play-by-mail is a real shipped
mode with its passwords stored (obfuscated) in the file, the roster block is
`aUnit[5][31]` of which the save persists 60 records, and the save carries a
**build number** that makes any two builds refuse each other's files.

**`.lcl` is the mission logic — and the game balance.** The scripts are only
obfuscated with XOR 0xFF and decode to well-commented source. The interpreter's
full 108-entry command table is in `Incubation.exe`, and its semantics were
recovered from the decompiled interpreter rather than inferred.
[`20-lcl-language.md`](20-lcl-language.md) is the language reference a remake
needs; [`21-info-lcl-schema.md`](21-info-lcl-schema.md) is the schema of
`DATA/Info.lcl`, i.e. every weapon, unit, equipment and terrain stat in the
game.

**Cross-format validation works, and it is what makes the specs trustworthy.**
Three independent examples:

- The `.lcl` scripts name map coordinates and compare against action-point
  values; reading those exact cells out of the `.lev` grid reproduces the
  values. That is how the cell record's height and action-point fields were
  pinned down rather than guessed — and it also settled the width/height
  ordering in the header.
- Every movement track in a `.cha` animation targets a bone that exists in that
  animation's own skeleton (6524/6524), and 98.2% also exist in a same-family
  `.cho` model. The 116 misses are authoring helpers (`Dummy01`, `Shadow`,
  spare finger bones) kept in the animation but never exported as parts.
- Every VISN record's bitstream ends 0 or exactly 2 bytes before its indexed
  end, and none reads past it — a per-record checksum over ~15 MB of entropy
  coding.
- A `.lev` cell's height equals the `z` of the land object on that field in
  184162 of 184162 cells — two independently decoded structures agreeing on the
  same quantity.

**Frame rate is proven, not assumed.** Cutscenes run at exactly 30 fps: the
sequence player multiplies its millisecond delta by the float `0.03` held at
`Incubation.exe:0x004B157C` (0.03 frames/ms), and that constant has exactly two
`fmul` references in the whole binary. Gameplay advances animation by one
key-time unit per rendered frame. See
[`40-charisma-model-animation.md`](40-charisma-model-animation.md).

**The strongest check is running the original code.** Wine 11 executes 32-bit
x86 PE on arm64 macOS, so the shipped `Eng3d.dll` can be loaded and called
directly. Diffing its output against our decoder gives **723/723 byte-exact**
for both VISN entry points, plus 87/87 on synthesised records that exercise
paths the retail data never touches. That is not "looks right" — it is the
original decoder agreeing bit for bit. See
[`../tools/wine_visn/README.md`](../tools/wine_visn/README.md).

**Pictures are the next best check.** Decoded `prototyp.bin` records render as a
recognisable city skyline and a human torso; a `.cho` skeleton posed by a `.cha`
animation is an unmistakable humanoid walking. That last one validates the
quaternion component order, the matrix convention and the parent chain
simultaneously — none of which can be checked structurally.

**`.cho` files contain no geometry.** Models reference their meshes *by name*,
and 8509 of 8617 distinct names resolve verbatim into the world set's
`prototyp.dir`. The geometry itself lives in `prototyp.bin` — which turned out
not to be a mesh structure at all, but a **bytecode program the engine executes
in place**, complete with a BSP tree for painter's-order sorting. See
[`31-prototyp-geometry.md`](31-prototyp-geometry.md).

---

## 4. Tools

All tools are Python 3, dependency-free, and live in `tools/`. Shared code is in
`tools/inclib/`:

| Module | Purpose |
|---|---|
| `inclib/binio.py` | Little-endian `Reader` with the length-prefixed-string convention |
| `inclib/png.py` | Minimal PNG writer (indexed and truecolour) |
| `inclib/palette.py` | `.pal` loader |
| `inclib/liblib.py` | `.LIB` shape-library parser |
| `inclib/lev.py` | `.lev` battle-map parser |
| `inclib/pe.py` | PE reader: sections, resources, and reads by virtual address |

Corpus checks — every tool has one, and they are the acceptance criterion for
each spec:

```bash
python3 tools/lev_parse.py    gog_incubation --check     # 155/155
python3 tools/lib_extract.py  gog_incubation --check     #  58/58
python3 tools/img_tables.py   gog_incubation             #  42/42
python3 tools/verify_3d_indices.py --root gog_incubation # .3DW/.dir/.din
python3 tools/lcl_decode.py   gog_incubation -o out/lcl  # 178 files
python3 tools/combat_tables.py --check gog_incubation    # 27 checks, 48/48 patterns
python3 tools/trace_names.py   --check gog_incubation    # 324 + 146 names
python3 tools/sav_tables.py   --check gog_incubation    # 69 checks
python3 tools/sav_parse.py    gog_incubation --selftest # 31 map sizes
python3 tools/typ_parse.py    --check gog_incubation     # 18 checks
python3 tools/ai_tables.py    --check gog_incubation     # 77 checks
python3 tools/pe_exports.py   --check gog_incubation     # 6 engine listings
```

Outputs (sprites, map renders, textures) are written under `tools/out/`.

---

## 5. Method and its limits

Every spec here is backed by a parser that runs over 100% of that format's
corpus. Coverage numbers are stated per format. Where a field's meaning is
inferred rather than proven, it is marked **UNVERIFIED** and the observed value
distribution is given instead of an invented name — an honest "u32 at +0x10,
always 0 across all 155 files" is more useful to a remake than a plausible
guess that turns out wrong.

Because several of these files are raw `fwrite` dumps of C structs from an MSVC
debug build, they contain uninitialised memory: `0xCD` fill bytes and stale heap
pointers appear inside otherwise meaningful records. Those are called out
per-format and must not be interpreted as data.

### What is still open

Each spec ends with an **Open questions** section, and closed entries are kept
in place with the evidence that closed them rather than deleted. **32 items are
still open:**

| Spec | Open | What they are |
|---|---|---|
| [10](10-lev-mission-format.md) | 4 | five unit bytes with no accessor in either binary, one all-zero block field, one vestigial header byte, one runtime-only array |
| [11](11-save-game-format.md) | 3 | fifteen offsets that no code compares against a literal and the hard-coded slot 32 — both narrowed by five real campaign saves but not named; the third needs a multiplayer save. ViewPlayer is now **closed**: the block's 1024-byte remainder is the loaded `vp.pal`. The **scoreboard is closed too** ([`98` §5](98-slice-6-report.md)): its four "unknown" fields are the campaign halves of four pairs — kills, units lost, units lost to an enemy and score, each `+0x00`/`+0x08`/`+0x10`/`+0x18` beside its `+0x04`/`+0x0C`/`+0x14`/`+0x1C` — written by `0x0043B810`, `0x0043B8D0`, `0x0043B860` and the scorer, and printed under `Txtmod_d`'s own "In Mission" / "In Campaign" headings. The slot question is narrowed to 32 and 33: slot 31 is the mission-entry snapshot |
| [20](20-lcl-language.md) | 0 | all eleven closed; one residual **UNVERIFIED** note lives inside item 5 (whether `GUI_SetButton`'s `PressDown` values 1 and 2 were meant to differ) |
| [22](22-combat-and-visibility.md) | 0 | all five closed; the residue is *unnamed*, not unknown — the difficulty levels are pictures and the `special` enumerators are integer literals, and neither binary holds a matching string. The fourth was closed by **correcting its premise**: the fog rebuild at `0x004149C7` is the spore hatch's, not `FixedStatue`'s, and the type it spawns is an LCL argument (§9.4.3). The fifth — what the unit pool draws the clock-seeded stream for — is a **speech set** (§3.2): `aRandom(1, 6)` into `unit[+0x55]`, which no rule reads |
| [23](23-ai-system.md) | 0 | all five closed; `+0x10` is fire / a mine / a shield, named by the models their makers insert; the cover score's out-of-bounds read is heap history and cancels in the maximiser; `aInitAISystem` does not exist; the planner and the fire routine share one twelve-value selector; and the loop's counters are a local and a parameter, which no mechanism in these binaries could have preserved |
| [24](24-briefing-text.md) | 0 | nothing open; three mechanisms are implemented and unexercised (`{#2}`, the `#` indent, the Japanese two-byte path) and two things are dead (the `{:OC}` read, and `Errors.txt`/`Campaign.txt`, which no code can name) |
| [25](25-turn-and-round.md) | 2 | the `pbm session` mode that no literal selects (deliberately not traced — the remake has no play-by-mail), and one multiplayer session flag. The post-load sweep `0x004783D0` is **closed** (§5.1): it overwrites seven of a `.lev`'s unit bytes at load, and the remake runs it |
| [26](26-interaction.md) | 3 | `_C_156`'s keyless teleporter exit, the `technical` box's guard bug, what `Batteries` was going to do, and the unexercised large-unit mine ring. **Both mine questions are closed** (§6.2): every cell-based `aExecuteBomb` call site -- the two in `aExecuteMove`, one in `aExecuteWarp`, and the push's -- is guarded by `aDeleteSpecialObject(cell[+0x0F])`, which accepts object ids 0..80 and takes its `CHECK` failure exit otherwise, and that exit *is* the FALSE the probe measured. The probe's synthetic mine carried `+0x10 = 2` with no object, a combination `0x0042FB30` shows the engine never produces -- it writes the id and the effect byte in adjacent instructions and writes `0xFF` instead when the object cannot be made. So an **authored** mine does fire, the push arm is no weaker than the walk's, and the large-unit ring's selector is read too (`unitinfo[+0x7B] == 1` at `0x0046EC25`) -- what is left of item 8 is that nothing has run it. Five checks in `interaction_tables.py`; the remake's walk arm detonates too -- an authored mine names an object and passes the guard, and a hand-written one still does not ([`97` §37.5](97-slice-5-report.md)). The dead fourth `SetCtrlMapInfo` column is **closed**, and the ladder rule is now a **decision**, not a question ([`92` §7.7](92-remake-architecture.md)) |
| [27](27-campaign.md) | 2 | why upgrade locations 3 and 6 load each other's map, and the fourteen named locations with no cell. The dialogue-number → `Video/` mapping and presentation flag are now **closed** by [`41`](41-sequence-player.md); all 30 `setMissionResult` sites are also enumerated and classified. [`98`](98-slice-6-report.md) corrected three things rather than opening any: the two pool rows are the live roster and an entry snapshot (§3.5), the tech and skill levels are **campaign** state that a mission entry does not touch (§4, §5.2), and §5.2's **UNVERIFIED** limit pair is closed — `0x00510A34` and `0x00510A35` are the low and high ends of one range, the high being the tech level |
| [28](28-effects-and-sound.md) | 1 | whether the eleven unreachable kinds were ever reachable. The seeker question is **closed** (§7.7.1, 2026-09-01) and closed statically: the target is the object named by `[unit_map[record + 0x54] + 0x4B]`, the step subtracts `ftol(D · −240)` with `D` the **un-normalised** direction service rather than a unit vector, and the orientation call takes the record's next position rather than the target — after which the two seekers reproduce all 18 stepped transitions and no stepped arm disagrees. The **service hooks are closed** (§7.4.2): all five were called inside a running `Incubation.exe` and four are reproduced exactly, so the remake's orientation service is `0x00403AA0`'s own arithmetic in a 4096-unit circle rather than the invented `atan2` it had been. A later pass closed the fifth as well: Eng3d's three-angle matrix builder is `_E3D_init_matrix_RzRxRy`, ordinal 13, and is reproduced 8/8 once its **negated** angle indices, its floor-rounding 64-bit products and its per-step shifting of triple products are all right — three properties that are in the DLL and not in the caller, and that [`30` §2.5](30-eng3d-ascii-formats.md)'s static reading of the same routine had wrong. The 78 kind values and all 74 distinct per-tick arms are now transcribed into the executable reference in `blob_runtime.py`, and **all 74 have been stepped inside a running `Incubation.exe`** and reproduce its records field for field (§12 item 1): 24 with records a creator built, and the other 50 with a donor record whose kind and life bytes were rewritten — `+0x44` is the jump-table index and `+0x45` the lifetime, so two adjacent bytes make a donor record any kind, short-lived enough to reach its own terminal branch, and no creator is needed to reach an arm. That second family measures the arm and not the arguments a creator would pass it, and the fixture keeps the two lists apart. That capture found errors in **fourteen** of the seventy-four arms and one in `_ftol` itself, none of which any static reading had: kind 11 does not delete itself; kind 8 — and **only** kind 8 — draws `aRandom(0, 0xFFF)` rather than `0x1000`, a correction this project then over-applied to three more arms; three arms damp their velocity by a twentieth, a fifth and a third rather than by the tenth and sixth they had been given; kind 76 moves **twice** while it lives; kinds 14 and 37 turn their delta through Eng3d's three-angle matrix, which they had not been doing at all; and `_ftol`'s invalid conversion returns **zero**, not `INT_MIN`, because the caller keeps `eax` of an `fistp qword`. **How much of each arm that comparison reached is measured too** (§12 item 1, `docs/97` §21): the replay is line-traced and executes **383 of the 385** transcribed arm lines, 73 of 74 arms entirely, after a second sweep vector, eight one-arm probes and one plan that writes engine state outside the pool. Kind 59's six lines were once counted unreachable "on a byte a service returns, which no record field can set"; the byte is the **output system's** mode id at `0x00512A78`, so writing that global for the length of one plan runs the branch, and the arm reproduces the engine there too — the extra emitter is a **3D-accelerator** effect, present only in the configuration whose surface comes from `Eng3d.dll`'s ordinal 67, `_E3DCARD_open_3dcard_screen`, rather than from `aCreateMainDDObject` (`docs/97` §23.3). All five of that switch's display modes are pinned field by field, and two of their fields are **read rather than named from their values** (§23.4): `0x00512A9C` is the scanline stride in bytes — the 320x200 mode reserves 640 of them for a 320-byte row, so it cannot be `width * bpp`, and the pixel plot `0x00463C40` halves it on its sixteen-bit arms and not on its eight-bit one — and `0x00512A60` is bytes per pixel, index 2 of a six-way output-info getter whose jump-table order is not its code order. Where the stride *comes from* is read too (§23.5): `0x00432C30` returns the **address of a static block** rather than an object -- aLIB's DirectDraw module state -- whose `+0x18` is a `DDSURFACEDESC`, identified by the `dwSize = 0x6C` both lock helpers write into it before handing its address to vtable slot `+0x64`, `IDirectDrawSurface::Lock`, under the error label `"DD_Lock"`; so `+0x28` is `lPitch` and the pointer they return is `lpSurface`, both fields of a public ABI, and it is `lPitch` for **two** of the four display modes -- mode 0 never rewrites the global and mode 3 has Eng3d fill it. The two lines left are a **deliberate divergence** — kind 41's arm is `mov eax, 0x200 / cdq / idiv [esi+0x48]` with no test in front of the divide, so a record with no `vx` kills the original outright, which a poked record demonstrated. And the ten creators that had "a residue of fields with no named mechanism" are **transcribed** now (§7.6.1, `docs/97` §22): all ten reproduce the engine's records field for field from the measured seed, with their draw counts checked against `aRandom2`'s seed either side of the call, which reaches the records past the twelve a capture reads back. Four shapes came out of it that no draw-stream fit could express — a draw with a counter added *inside* the `_ftol`, a position that reads a different axis' direction ratio, a creator that calls another creator before placing anything, and a constructor that silently drops a record whose `life` is zero. All **thirteen** of their constants are read back out of the shipped executable by `blob_tables.py`, which needs no capture: nine doubles in the `0x004B12xx` block, three subtracted immediates, and two divisors that appear in the bytes only as reciprocal multiplies and are recovered by replaying them (`docs/97` §23.1). The one axis assignment that had been fitted rather than read is read now, off the creator's own frame (§23.2). kind 15 also has one native Wine sample ([91](91-wine-runtime-probes.md)). What the kinds *are* is **closed** — every one is named by its creators, classed, and its spawn list decoded; so are the sprite atlas (there are no colour parameters: the palette is baked into one 8×8 texture), the sound gating (a sound's lifetime is its blocking sequence's), the `explosion.wav` / `explosion2.wav` split (an overheat catastrophe against ordnance impact) and the four `object_3d` fields two arms write — they are the **joint angles** of the model's sub-objects, read by seven Eng3d render opcodes and by nothing in the exe |
| [29](29-interface-contract.md) | 0 | the hand-over routine `0x004312D0` is now decoded as the deployment-marker build/reset dispatch |
| [30](30-eng3d-ascii-formats.md) | 9 | authoring-side meanings of `.dir` metadata, tokens the shipped readers skip, two raised by the leaked exporter config (§2.11) — what `SORT_OBJECT` selected and whether `DETAIL_METHODE`'s numbering is the engine's — and one shipped `.lev` that names a world set which does not exist. The stale-worlds item is now **closed**: no mission loads either file. `SORT_OBJECT`'s last candidate is **eliminated** (2026-09-02): the check-in list *is* chosen by the record — `0x00404C79` tests `flags` bit 0 — but that bit is clear in all 701 records of `Video/Dialog_03`, the only container whose config sets `SORT_OBJECT`, and set in just two records elsewhere, so the item is now unknowable rather than untraced |
| [31](31-prototyp-geometry.md) | 1 | what a Voodoo did with Glide blend factor `0xf`. Runtime confirmation is **closed as not needed** — the item it was wanted for was settled by reading the code |
| [40](40-charisma-model-animation.md) | 6 | enumerator names, the `J` animation family, the four synthetically-validated reader branches, and whether the −Y authored forward (§5.4) is reconciled by a rotation or by a mirror |
| [42](42-mission-presentation.md) | 0 | none. The two it carried for a day — the glow's lifecycle and what a ground-fire removal costs — are closed in §12 with their evidence (`97` §38), and the six before them too: the pose after detach is measured (bind on the next step, the last frame held before it), the clip length is the first movement's last key time, state 3 is the shield, the four set pieces are transcribed, the start slot's class is `KeyFramedAnimationInterface`, and the starter's type search never advances so the draw decides |
| [41](41-sequence-player.md) | 0 | nothing open; the manifest, the lifecycle, the 30 fps clock and the trigger are pinned to the image, and speech/subtitles are closed **negatively** — the player carries no scheduler and no `Video/` directory holds a wave or a text file. Two residual items are *decisions*, not unknowns: the camera ids `9..19` belong to the 3D scene, and presentation/input live outside the module |
| [43](43-battle-hud.md) | 0 | all closed. Two went on the same day: the callback pointer `fcn.0047D600` stores is read only by `aAISystemControl`, so no blocking animation redraws the ground overlay (§3.1); and the watched player's screen is a seven-arm state machine on `[0x005229D4]` whose captions come from `txtmod_g` (`_ViewPlayers`) and `txtmod_h`, of which **the computer's turn is state 2 and prints nothing at all** — `alarm.wav` is the network game's "it is your turn" alert, gated on the game mode `[0x00509EE8]` being 2 (§7.3). The three things reading could not settle are decisions with the reading that would settle them named — the magnifier's `Data` info page, the campaign map's band-coloured rings, the two plate fonts' handles |
| [60](60-lib-sprites.md) | 0 | none, since 2026-09-05: the blitter is `fcn.004475D0` in the module's own range and keys index 0 for every library, and the anchors are read only by the callers that subtract them — the overlay, the panel, the radar, the cursor — never by the columns or the pad ([`43` §3.4](43-battle-hud.md)) |
| [70](70-img-tables.md) | 1 | the rounding rule that generated the sine table |

Almost all of these are open **in principle**, not merely untraced. Three
recurring reasons: there is no corpus (the residue of [`11`](11-save-game-format.md)
is narrowed but not settled by the six campaign saves we have; settling it
wants a multiplayer save, which the retail release cannot produce); there are no symbols (enumerator names, the `J` family — no
code references it at all); the authoring tool never shipped, so `class_code`,
`type_code` and `EDITORDETAIL` have no recoverable meaning; or the field is zero
in every shipped file, which no amount of data can characterise. Each entry
states what was tried, so effort is not spent twice.

Nothing in this list blocks a remake: every one is either a name for behaviour
that is already fully specified, or a field a remake can carry through
unchanged.

---

## 6. Prior art

The formats were surveyed for existing documentation before any work started.
Findings:

- **[Sonatix/Incubation-HD-Renderer](https://github.com/Sonatix/Incubation-HD-Renderer)**
  (2026, MIT) — the one substantial technical source. Contains a VISN codec
  specification recovered by disassembling `Eng3d.dll`, plus descriptions of
  `.LIB`, `.pal`, `.dir`/`.din`, and `.3DW`. It was used as a starting lead for
  the VISN work; the implementation here was written from scratch and is now
  validated directly against the original DLL rather than against any prose, so
  the dependency is discharged. Two of its claims turned out to be wrong — see
  [`50-visn-textures.md`](50-visn-textures.md).
- **LCL Decode** (Kay Ove, early 2000s, Java) on the `scayra.free.fr` fan
  archive — the XOR 0xFF obfuscation and a field-level description of
  `DATA/Info.lcl`.
- Nothing at all for `.lev`, for the `.cho`/`.cha` payloads, for
  `prototyp.bin`'s contents, or for the `.IMG` tables.
- ModdingWiki's "Battle Isle / History Line library format" is an **older,
  unrelated** DOS-era format and does not apply.

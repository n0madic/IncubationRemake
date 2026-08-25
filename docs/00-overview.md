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

Reconstructed original source layout: [`90-binaries-and-source-layout.md`](90-binaries-and-source-layout.md).
Plan for the runtime work that remains — the turn, interaction, the campaign,
effects and sound, the interface contract and the sequence player:
[`91-game-logic-research-plan.md`](91-game-logic-research-plan.md).
Decisions taken about the remake itself — engine, language, asset pipeline and
what stays open: [`92-remake-architecture.md`](92-remake-architecture.md).

---

## 2. Format inventory

| Format | Count | Role | Status | Tool | Spec |
|---|---|---|---|---|---|
| `.lev` | 155 | Missions: field grid, units, scenery placement | **Solved structurally**; grid, units and ground lattice decoded, some fields open | `lev_parse.py` | [10](10-lev-mission-format.md) |
| `.sav` | 0 (written by the game) | Save games — campaign and play-by-mail | **Solved structurally** from the writer and reader chains; nine blocks, one of them a complete `.lev` image. No sample exists to parse | `sav_tables.py --check`, `sav_parse.py` | [11](11-save-game-format.md) |
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
| `.bmp` | 118 | Briefing art, backgrounds, install screens; the briefing program names 89 of them | Standard Windows BMP | — | [24 §8](24-briefing-text.md) |
| `.wav` | 407 | Speech, SFX | Standard RIFF/WAVE | — | — |
| `.ogg` | 32 | Music (GOG re-encode of the CD audio) | Standard Ogg Vorbis | — | — |
| `Rec_0.dat` | 1 | Orphaned file under `DATA/Misc/` | **Dead data** — no shipped binary references it | — | see below |

`Install/*` (InstallShield `.ins`, `.lid`, `.cab`) is installer plumbing and out
of scope.

### Behaviour, not formats

Four specs in the set describe no file at all.
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
does with any of it. The four exist because a loader that reads every byte of
every format still cannot play a turn — nor be played against.
`combat_tables.py`, `ai_tables.py`, `turn_tables.py`, `interaction_tables.py`
and `trace_names.py` are their checks.

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

**`.sav` is the only format the game itself writes**, and the only one with no
corpus at all — the shipped `Work/Saves/` tree is empty. What replaces the
corpus is that `aSaveGame` and `aLoadGame` are both in the binary and must
agree, which pins every offset exactly; 69 checks assert that agreement.
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
python3 tools/combat_tables.py --check gog_incubation    # 24 checks, 48/48 patterns
python3 tools/trace_names.py   --check gog_incubation    # 324 + 146 names
python3 tools/sav_tables.py   --check gog_incubation    # 69 checks
python3 tools/sav_parse.py    gog_incubation --selftest # 31 map sizes
python3 tools/typ_parse.py    --check gog_incubation     # 18 checks
python3 tools/ai_tables.py    --check gog_incubation     # 77 checks
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
in place with the evidence that closed them rather than deleted. **35 items are
still open:**

| Spec | Open | What they are |
|---|---|---|
| [10](10-lev-mission-format.md) | 4 | five unit bytes with no accessor in either binary, one all-zero block field, one vestigial header byte, one runtime-only array |
| [11](11-save-game-format.md) | 3 | fifteen offsets that no code compares against a literal and the hard-coded slot 32 — both narrowed by five real campaign saves but not named; the third needs a multiplayer save. ViewPlayer is now **closed**: the block's 1024-byte remainder is the loaded `vp.pal` |
| [20](20-lcl-language.md) | 0 | all eleven closed; one residual **UNVERIFIED** note lives inside item 5 (whether `GUI_SetButton`'s `PressDown` values 1 and 2 were meant to differ) |
| [22](22-combat-and-visibility.md) | 0 | all three closed; the residue is *unnamed*, not unknown — the difficulty levels are pictures and the `special` enumerators are integer literals, and neither binary holds a matching string |
| [23](23-ai-system.md) | 0 | all five closed; `+0x10` is fire / a mine / a shield, named by the models their makers insert; the cover score's out-of-bounds read is heap history and cancels in the maximiser; `aInitAISystem` does not exist; the planner and the fire routine share one twelve-value selector; and the loop's counters are a local and a parameter, which no mechanism in these binaries could have preserved |
| [24](24-briefing-text.md) | 0 | nothing open; three mechanisms are implemented and unexercised (`{#2}`, the `#` indent, the Japanese two-byte path) and two things are dead (the `{:OC}` read, and `Errors.txt`/`Campaign.txt`, which no code can name) |
| [25](25-turn-and-round.md) | 3 | the `pbm session` mode that no literal selects (deliberately not traced — the remake has no play-by-mail), one multiplayer session flag, and one interface routine that belongs to package F |
| [26](26-interaction.md) | 5 | the dead fourth `SetCtrlMapInfo` column, `_C_156`'s keyless teleporter exit, the `technical` box's guard bug, what `Batteries` was going to do, and the ladder rule no shipped cell exercises |
| [30](30-eng3d-ascii-formats.md) | 10 | authoring-side meanings of `.dir` metadata, tokens the shipped readers skip, and two raised by the leaked exporter config (§2.11): what `SORT_OBJECT` selected — the one item here with an untraced lead — and whether `DETAIL_METHODE`'s numbering is the engine's |
| [31](31-prototyp-geometry.md) | 2 | what a Voodoo did with Glide blend factor `0xf`; runtime rasteriser confirmation |
| [40](40-charisma-model-animation.md) | 5 | enumerator names, the `J` animation family, the four synthetically-validated reader branches |
| [60](60-lib-sprites.md) | 2 | which out-of-bounds sprite anchors are deliberate; which index the blitter keys for the 34 libraries with no index 0 |
| [70](70-img-tables.md) | 1 | the rounding rule that generated the sine table |

Almost all of these are open **in principle**, not merely untraced. Three
recurring reasons: there is no corpus (three of `11`'s four, which need one
save the retail release does not ship); there are no symbols (enumerator names, the `J` family — no
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

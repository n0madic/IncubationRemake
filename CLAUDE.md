# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Reverse-engineering of the file formats of **Incubation: Time Is Running Out** (Blue Byte, 1997), as groundwork for a remake. It is not an application — it is a set of format specifications (`docs/`) and the parsers that prove them (`tools/`).

`gog_incubation/` is the retail game, and is **strictly read-only**. `Work/Saves/`
under it is where the game writes save files; it ships empty. Never run the game
and never write there yourself — but if a save appears there because the user
played, that is the sample `tools/sav_parse.py` exists to read, and three of
`docs/11`'s open questions close the moment one does. It is gitignored. Never write into it, never "fix" a file in it, and be careful with `cd` — a shell whose working directory drifts into it will silently create directories there.

## Commands

All tools are Python 3 with **no third-party dependencies** (the PNG writer is hand-rolled in `tools/inclib/png.py`). Run them from the repo root.

### Corpus checks — the test suite

There is no pytest suite. Each format's test is its parser consuming **100% of that format's files**. Run all of them after any change to `tools/`:

```bash
python3 tools/lcl_parse.py        gog_incubation --check      # 177/177
python3 tools/lev_parse.py        gog_incubation --check      # 155/155
python3 tools/lib_extract.py      gog_incubation --check      #  58/58
python3 tools/visn_decode.py      gog_incubation --check      # 723/723
python3 tools/prototyp_parse.py   --check --root gog_incubation   # 26072/26072
python3 tools/cho_parse.py        --check gog_incubation      # 237/237
python3 tools/cha_parse.py        --check gog_incubation      # 245/245
python3 tools/cha_parse.py        --verify-convention gog_incubation
python3 tools/font_render.py      --check gog_incubation
python3 tools/img_tables.py       gog_incubation
python3 tools/verify_3d_indices.py --root gog_incubation      # 31 check kinds
python3 tools/combat_tables.py    --check gog_incubation      # 27 checks, 48/48 patterns
python3 tools/trace_names.py      --check gog_incubation      # 324 + 146 names
python3 tools/sav_tables.py       --check gog_incubation      # 69 checks
python3 tools/sav_parse.py        gog_incubation --selftest   # 31 map sizes
python3 tools/typ_parse.py        --check gog_incubation      # 18 checks
python3 tools/ai_tables.py        --check gog_incubation      # 77 checks
python3 tools/brief_parse.py      --check gog_incubation      # 55 checks
python3 tools/turn_tables.py      --check gog_incubation      # 85 checks
python3 tools/interaction_tables.py --check gog_incubation    # 109 checks
python3 tools/campaign_tables.py    --check gog_incubation    # 237 checks
python3 tools/blob_tables.py        --check gog_incubation    # 252 checks
python3 tools/charisma_selftest.py                            # no corpus; synthetic
```

All exit 0. A non-zero exit is a regression. Every one of them also **fails on an empty corpus** — a check that examined nothing is not a check that passed, so a mistyped root cannot come out green.

`.sav` had **no corpus** for most of this project's life — the shipped
`Work/Saves/` tree is empty — so its two checks stand in for one. Six real saves
now exist in `tests/fixtures/saves/`, made by running the retail game under Wine
(`wine explorer /desktop=inc,640x480 Incubation.exe -english`, from a **copy** of
the game, never from `gog_incubation/`). The `.sav` files are gitignored because
each embeds a whole shipped `.lev`; the committed `README.md` beside them records
what each pins. Nothing in the always-run block depends on them. `sav_tables.py` verifies the layout against the writer
and reader chains in `Incubation.exe`; `sav_parse.py --selftest` wraps a corpus
`.lev` in the save's fixed blocks and requires the round trip and a
byte-identical extraction. `sav_parse.py FILE` is the only tool here that has
never seen real data; it is deliberately outside the always-run block and exits
non-zero when there is nothing to parse.

`--verify-convention` and `charisma_selftest.py` are the two that guard *meaning* rather than structure: the first gates on the quaternion-component hypothesis still explaining ≥80 % of tracks, the second asserts decoded key values and times. Structure-only checks pass unchanged when components are permuted, so do not remove either.

**CLI inconsistency to watch for:** the game root is a positional argument for `lcl_parse`, `lev_parse`, `lib_extract`, `visn_decode`; but it is the *argument to* `--check` for `cho_parse`, `cha_parse`, `font_render`, `combat_tables`,
`sav_tables`, `typ_parse`, `ai_tables`, `brief_parse`, `turn_tables`,
`interaction_tables`, `campaign_tables`, `blob_tables` and `trace_names`; and `--root` for `prototyp_parse` and `verify_3d_indices`.
`sav_parse` takes it positionally but only with `--selftest`. Check `--help` rather than guessing.

### Asset extraction

```bash
python3 tools/lib_extract.py gog_incubation -o tools/out/sprites    # 2296 sprite PNGs
python3 tools/visn_decode.py gog_incubation -o tools/out/textures   # 723 texture PNGs
python3 tools/lcl_decode.py  gog_incubation -o tools/out/lcl        # deobfuscated scripts
python3 tools/lev_parse.py   gog_incubation --png -o tools/out/maps
python3 tools/cho_export.py  --samples gog_incubation               # posed skeletons
```

`tools/out/` is gitignored — it holds extracted game assets, which must not be committed.

### Single-file inspection

Most tools take one file plus `--json`. `tools/lev_parse.py FILE --map` prints an ASCII terrain map; `tools/prototyp_parse.py --opcodes` dumps the geometry bytecode dispatch table.

## Architecture

### Two engines, two format families

The game is built from two separate codebases, visible in the assert strings left in the binaries:

- **Game/editor layer** (`C:\aProject\...`, Blue Byte's own `aLIB`) — owns `.lev`, `.lcl`, `.LIB`, `.pal`.
- **Eng3d + Charisma** (`D:\PRO\3DLIB\eng3d\`) — the renderer and the model/animation system. `CHData` = *Charisma* data. Owns `.3DW`, `.dir`/`.din`, `prototyp.bin`, `texture.lib`, `.cho`, `.cha`.

`docs/90-binaries-and-source-layout.md` reconstructs the original source tree; it is the fastest way to find which module owns a format.

### How the formats reference each other

This chain is the thing that requires reading several docs to see, and it is what a remake's loader has to walk:

```
Missions/_C_105.lev
  ├─ header names world set "B00" and scene "Level02b"
  │     └─ WorldSet/World_B00/Worlds/LEVEL02B.3DW
  │           └─ [CLO] blocks name prototypes
  ├─ land + special object records name/index prototypes
  │     └─ WorldSet/World_B00/Objects/prototyp.din  (binary index)
  │           └─ prototyp.bin  (geometry bytecode)
  │                 └─ texture ids → TEXTURES/texture.din → texture.lib (VISN)
  ├─ unit records carry a type id
  │     └─ DATA/Info.lcl  SetUnitInfo table  (docs/21)
  └─ Missions/_C_105.lcl  drives the mission (docs/20)

CHData/Objects/*.cho  → mesh names → the same prototyp.din
CHData/Animations/*.cha → bone names must match the .cho part names
```

Two consequences worth internalising: **`.cho` contains no geometry** (it references meshes by name), and **`prototyp.bin` is not a mesh structure** — it is a bytecode program the engine executes in place, including a BSP tree.

### Code layout

`tools/inclib/` is the shared library; `tools/*.py` are thin CLIs over it. Reuse `inclib`, don't duplicate:

- `binio.Reader` — little-endian primitives plus `lpstring()` (u32 length + exactly that many bytes, no NUL), the convention Charisma uses throughout
- `png` — dependency-free indexed and truecolour PNG writing
- `palette`, `liblib`, `lev`, `charisma`, `prototyp`, `visn` — one module per format family
- `pe` — PE sections, resources, and typed reads **by virtual address**, so the addresses the docs quote can be used directly

Parsers raise a typed error (`ParseError`, `LevError`, `LibError`, `PaletteError`, `VisnError`) instead of returning partial results, so a corpus check cannot pass by silently skipping files. Keep that property.

## Working rules specific to this project

**Every spec claim needs a corpus check behind it.** A field table that no parser validates against all files is a guess. State coverage as `N/N`.

**Mark uncertainty explicitly.** The docs use **UNVERIFIED** plus the observed value distribution. `u8 at +0x12, set on 44 of 184162 cells, no correlation found` is a good spec line; a plausible-sounding invented name is a bug that costs someone days later.

**These files are raw `fwrite` dumps of C structs from an MSVC debug build.** Uninitialised heap (`0xCD` fill) and stale pointers appear inside otherwise meaningful records. Consequences that have already bitten this project:

- **Never find an array's end by scanning for a `0xCDCDCDCD` sentinel.** Read the count field. Doing otherwise once produced a completely fictitious "fixed 40×40 lattice" claim from leftover memory that looked like valid records.
- Ignore fields documented as runtime scratch; do not interpret them.

**Prefer the decompiled binary over pattern-matching bytes.** Nearly every *call site* pushes the **callee's** name and its own source line on the error path, which makes named routines easy to find — but mind the direction:

```bash
r2 -e bin.relocs.apply=true gog_incubation/iDesigner.exe
> aaa
> izz~aSaveCtrlMap        # find the trace string
> axt <addr>              # find the function referencing it
> pdf @ fcn.XXXXXXXX
```

**`izz` + `axt` lands on the *caller*, not the named function.** The macro is `CHECK(Foo(...))` and the string `"Foo"` is pushed at the call site, so the function containing the string is the one that *calls* `Foo` — `aCheckLineOfSight` appears seven times inside `0x0046C460`, which is `aCheckLineOfSightEx`. Run `python3 tools/trace_names.py <binary>` instead: it pairs every push block with the `call` it guards and prints a 324-entry symbol table for `Incubation.exe`. The names are hand-written, so a few are wrong (the tool votes across call sites; `--all` shows the losers), and a programmer occasionally pastes their *own* function's name — which is itself usable evidence.

Ghidra (`/opt/homebrew/Cellar/ghidra/*/libexec/support/analyzeHeadless`) gives C pseudocode; use one Ghidra *project directory per binary* or concurrent runs deadlock on the project lock. Cross-check the two: Ghidra's symbol resolution can fold a `base + offset` access into a separate symbol and make live data look dead — verify against the raw disassembly when the conclusion matters.

**`strings` thresholds silently truncate.** `strings -n 5` once dropped `Goto`, `OBJ` and `?_` from an extracted command table, and nothing downstream noticed. Use `-n 2` when extracting a table.

**Runtime verification is available and is the strongest evidence.** Wine 11 runs 32-bit x86 PE on arm64 macOS, and `i686-w64-mingw32-gcc` is installed, so the original DLLs can be called directly. `tools/wine_visn/` does this for the texture codec and reaches 723/723 byte-exact; its README explains the build. That harness found a real bug (a macroblock-count truncation) that no amount of structural self-consistency checking could have caught.

## Documentation

`docs/00-overview.md` is the entry point and carries the format inventory table with per-format status and coverage. Numbered by family: `10` `.lev`, `11` `.sav` (the only format the game writes; it embeds a whole `.lev`), `20`/`21` LCL and the game-balance schema, `22` combat and visibility, `23` the AI turn, `25` the turn and the round, `26` interaction and set-pieces, `27` the campaign layer and `28` effects and sound (**behaviour, not file formats**), `24` the briefing and info text markup, `30`/`31` Eng3d ASCII formats and `prototyp.bin`, `40` Charisma, `50` VISN, `60` sprites/fonts, `70` lookup tables, `90` binaries.

`docs/91-game-logic-research-plan.md` is the plan for the runtime work that remains — package A (the turn and the round) is **delivered** as `docs/25`, package C (interaction and set-pieces) as `docs/26`, package B (the campaign layer) as `docs/27` and packages D+E (effects and sound) as `docs/28`; the interface contract and the sequence player are not; `docs/92-remake-architecture.md` records the remake's own decisions — Godot 4, GDScript for the game logic, the Python pipeline converting on the player's machine — and the ones still open. Neither is a spec: they cite the numbered docs and state no findings of their own.

Every doc ends with an **Open questions** section. **39 items remain open** across the set (`10`: 4, `11`: 3, `20`: 0, `22`: 0, `23`: 0, `24`: 0, `25`: 3, `26`: 4, `27`: 4, `28`: 2, `30`: 10, `31`: 1, `40`: 5, `60`: 2, `70`: 1); the rest are marked closed in place, each with the evidence. Keep those sections honest — when you close an item, move it into the body with the evidence, and when you find a new unknown, add it.

Most of what remains is open *in principle*, not merely untraced: no symbols (enumerator names, the `J` animation family), an authoring tool that never shipped (`class_code`, `type_code`, `EDITORDETAIL`), or all-zero fields that no amount of data can characterise. Before spending effort on one, read what the entry already says was tried.

Documentation and all code comments are in **English**. Conversation with the user is in Russian.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Reverse-engineering of the file formats of **Incubation: Time Is Running Out** (Blue Byte, 1997), as groundwork for a remake. It is not an application — it is a set of format specifications (`docs/`) and the parsers that prove them (`tools/`).

`gog_incubation/` is the retail game, and is **strictly read-only**. `Work/`
under it is where the game writes save files and options; it ships empty, but
the user's own saves may be there from playing and are theirs to keep — the
rule is that *nothing here writes into it*, not that it stays empty.
`tools/verify_untouched.sh` lists what `Work/` holds so a new file is obvious.
Never run the game from here and never write here yourself — but a save that
appeared because the user played is the sample `tools/sav_parse.py` exists to
read, and three of `docs/11`'s open questions close the moment one does. The
tree is gitignored. Never "fix" a file in it, and be careful with `cd` — a
shell whose working directory drifts into it will silently create directories
there.

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
python3 tools/blob_tables.py        --check gog_incubation    # 259 checks
python3 tools/blob_runtime.py       --selftest               # 78 kinds, 74 arms
python3 tools/pe_exports.py         --check gog_incubation   # 6 engine listings
python3 tools/interface_tables.py   --check gog_incubation    # 39 checks
python3 tools/seq_parse.py          --check gog_incubation    # 75 checks, 130/130
python3 tools/charisma_selftest.py                            # no corpus; synthetic
python3 tools/dbgcall_patches.py    gog_incubation --selftest # 15 checks
python3 tools/info_parse.py         --check gog_incubation   # 21 checks
python3 tools/lcl_runtime.py        --check gog_incubation   # 34 checks, 942 invocations
python3 tools/turn_runtime.py       --check gog_incubation   # 57 checks, 1863 units
python3 tools/combat_runtime.py     --check gog_incubation   # 84 checks, LOS/hit/damage/reaction
python3 tools/interact_runtime.py   --check gog_incubation   # 59 checks, aExecuteUse
python3 tools/movemap_runtime.py    --check gog_incubation   # 27 checks, 3726 fills, 4587 paths, 4587 walks
python3 tools/ai_runtime.py         --check gog_incubation   # 71 checks, 108 missions
python3 tools/remake_convert.py     gog_incubation --check   # 59 checks
python3 tools/remake_convert.py     --check-cache            # 29 checks
bash   godot/run_tests.sh                                    # 26 suites, 1554 checks
```

The last five belong to the remake (`docs/93` and its addendum). `run_tests.sh` needs Godot 4.7
and gates on the harness's sentinel line rather than on the exit status, because
Godot exits 0 even when the main script fails to load. It also needs its inputs
present -- a suite whose fixture is missing **fails**, deliberately, the same way
every `--check` here fails on an empty corpus:

```bash
python3 tools/remake_convert.py  gog_incubation --dev-fixtures godot/generated
#   ^ also writes godot/generated/inspect/: lev_parse --png per mission and
#     prototyp_parse --obj per prototype, for the by-eye half of criterion 4.
#     It carries a .gdignore -- Godot would otherwise import all 91 as resources.
python3 tools/movemap_runtime.py --emit-cases tests/fixtures/movemap --root gog_incubation
python3 tools/turn_gold.py       --emit-cases tests/fixtures/turn/cases_turn.json --root gog_incubation
python3 tools/turn_runtime.py    --check gog_incubation \
    --emit-handover-cases tests/fixtures/turn/cases_handover.json
python3 tools/movemap_gold.py    --emit-allowance-cases tests/fixtures/movemap/cases_allowance.json
python3 tools/movemap_gold.py    --selftest-process-scope
python3 tools/lcl_runtime.py     --emit-cases tests/fixtures/lcl/cases_lcl.json --root gog_incubation
python3 tools/ai_runtime.py      --emit-cases tests/fixtures/ai/cases_ai.json --root gog_incubation
```

The native case file comes from an existing capture:
`python3 tools/movemap_gold.py --emit-cases tests/fixtures/movemap/cases_native.json --root gog_incubation`.
All of them are gitignored; `tests/fixtures/movemap/README.md` and
`tests/fixtures/turn/README.md` record what each one holds -- including why the
hand-over trace is the one case file whose oracle is **executable Python and
not the engine**, and the single-unit-array limit its emitter refuses to write
past. `run_tests.sh` copies them into `godot/generated/movemap/` and
`godot/generated/turn/`, which the
suites look at **before** `user://movemap/` -- the other order once let a stale
copy shadow a fresh one and quietly shrink the run, which is why `harness.gd`
also carries a minimum check count per suite. Two more are outside the
always-run block because they need Wine and a copy of the game:
`python3 tools/movemap_gold.py --check gog_incubation` re-runs the executable
model against the native capture (41 checks over 74 fills, 37 allowance calls,
9 walks and 2 `aExecuteMove` probes: the fill, the ladder, the large-unit
clearance, the movement allowance, the path walk and the walk's own charge),
and re-taking that capture needs `--game-copy`.

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
byte-identical extraction. `sav_parse.py FILE` reads a real save cleanly now that
the six fixtures exist — `tests/fixtures/saves/_6_.sav` comes back as `_C_141`
on `Level01e` of `World_A00`, 20x20, with its embedded `.lev` at +7541 — but it
stays outside the always-run block because those files are gitignored, and it
exits non-zero when there is nothing to parse.

`--verify-convention` and `charisma_selftest.py` are the two that guard *meaning* rather than structure: the first gates on the quaternion-component hypothesis still explaining ≥80 % of tracks, the second asserts decoded key values and times. Structure-only checks pass unchanged when components are permuted, so do not remove either.

**CLI inconsistency to watch for:** the game root is a positional argument for `lcl_parse`, `lev_parse`, `lib_extract`, `visn_decode`; but it is the *argument to* `--check` for `cho_parse`, `cha_parse`, `font_render`, `combat_tables`,
`sav_tables`, `typ_parse`, `ai_tables`, `brief_parse`, `turn_tables`,
`interaction_tables`, `campaign_tables`, `blob_tables`, `interface_tables`,
`info_parse`, `movemap_runtime`, `movemap_gold`, `turn_runtime`,
`combat_runtime`, `interact_runtime`, `lcl_runtime` and `trace_names`; and `--root` for `prototyp_parse` and `verify_3d_indices`.
`remake_convert` takes it positionally **and** wants `--check` as a bare flag.
`sav_parse` takes it positionally but only with `--selftest`, `seq_parse`
takes it positionally with `--check` as a bare flag, and `dbgcall_patches`
takes either the root or a path to `Incubation.exe`, positionally. Check `--help` rather than guessing.

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
- `palette`, `liblib`, `lev`, `charisma`, `prototyp`, `visn`, `lcl` — one module per format family; `lcl` holds the script codec, tokenizer, parser and AST, and `lcl_parse.py` / `lcl_decode.py` are thin CLIs over it
- `rng` — the two generators the engine draws from: `ARandom` (`0x00463870`, the Lehmer one, pinned by a 64-draw native capture) and `CRandom` (the C runtime's, which only `InsertUnit` uses). `godot/core/rng.gd` is `ARandom`'s twin
- `script`, `lcl_runtime`, `turn`, `combat`, `interact` — the LCL cache document, and the executable models of the interpreter (docs/20), the turn (docs/25), combat/visibility/reaction (docs/22, docs/25 §6) and interaction (docs/26)
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

**Runtime verification is available and is the strongest evidence.** Wine 11 runs 32-bit x86 PE on arm64 macOS, and `i686-w64-mingw32-gcc` is installed, so the original code can be called directly. There are two harnesses for this, and they answer different questions:

- `tools/wine_visn/` loads `Eng3d.dll` **out of process** and calls its VISN entry points, reaching 723/723 byte-exact. Use it when a routine depends only on its arguments. Its README explains the build. It found a real bug (a macroblock-count truncation) that no amount of structural self-consistency checking could have caught.
- `tools/dbgcall/` runs `Incubation.exe` or `iDesigner.exe` **under a debugger**, stops at a breakpoint, and calls functions **inside the live process**, so the engine's own globals are already initialised. That is the only way to exercise code that depends on engine state rather than on its arguments alone. A call is written as a C-like declaration plus an invocation — `__cdecl i32 aCheckLineOfSight(ptr,i32,i32) = Incubation.exe+0x46C460`, then `aCheckLineOfSight(%esi, 12, 7)` — arguments may read registers, target memory and earlier results, and a batch emits JSONL for the Python side to check. It **verifies the declared signature** against the callee's actual stack cleanup, so a wrong arity is an error rather than a confident wrong number, and `--probe` turns the same measurement into a way to recover an unknown convention and arity. It can also **patch the running process instead of a copy of the file**: `--code` allocates an executable page and `--poke ADDR:EXPECTED=>NEW` writes over code or data only if the live image still holds `EXPECTED`, with `{&buf}` and `{rel32 EXPR}` holes filled in at write time — so a hook is installed on the shipped `Incubation.exe` at runtime, and `--resume` leaves it in place. Read [`tools/dbgcall/README.md`](tools/dbgcall/README.md) before using it; it also records why `Eng3d.dll` can only be addressed as `Module+RVA` (the loader relocates it on every run), and the three Wine settings `Incubation.exe` needs to start at all.

Both are outside the always-run block: they build binaries and need Wine on Linux/MacOS. After changing the debugger harness run its own check, `bash tools/dbgcall/selftest.sh` (68 checks, exits non-zero on any mismatch).

Two tools drive the debugger harness for the remake's oracles, and they share
one session: `tools/movemap_gold.py` (the fill, the ladder, the allowance, the
path walk) and `tools/turn_gold.py` (the hand-over refresh, the lone stat
recompute, line of sight and hit probability). `turn_gold.py` **imports**
`run_plan` and the capture constants from `movemap_gold.py` rather than copying
them. Both need a **copy** of the game with `tests/fixtures/saves/_6_.sav`
staged as `Work/Saves2/_6_.sav`, and both refuse a game directory inside this
repository:

```bash
python3 tools/turn_gold.py --game-copy /path/to/copy --dbgcall /path/to/copy/dbgcall.exe
python3 tools/turn_gold.py --check gog_incubation     # re-run the models against it
```

`tools/ai_gold.py` is the third, and the one that pins a **whole computer
turn**: `python3 tools/ai_gold.py --game-copy /path --dbgcall /path/dbgcall.exe`
captures twelve phases on `_C_140` -- two saves, turn 1 and turn 10 -- and
`python3 tools/ai_gold.py --check gog_incubation` re-runs `inclib/ai.py`
against them (45 checks: the three predicates over 90 ordered pairs, the cover
score over 60 cells, the target overlay, the approach cell, seven helpers, six
fires, twelve plans, the parabomb fuse, and `aAISystemControl` itself with all
200 unit records and `aRandom`'s seed compared field by field). The twelfth is
the **band sweep**: it writes the weapon's hit quote (`SetWeaponInfo + 0x30`)
one point either side of each of `docs/23` §6's four boundaries, asks
`aGetHitProbability` what the chance is and reads back the marker
`aBuildTargetOverlay` stamped, so the band table is measured rather than read
off the listing. It puts the column back -- the weapon table is loaded once at
start-up and not per save, so a phase that left it written would poison every
phase after it. **It must not
use `--code`**: on this host an injected executable page makes `Incubation.exe`
fault before the anchor, ten attempts out of ten, so the byte writer is the
game's own imported `memcpy` reached through its IAT slot with the byte in a
plain `--blob`.

`tests/fixtures/turn/README.md` records what the capture holds; `--check` is
114 checks over 86 unit pairs (hit probability **and** line of sight), the
refresh of every player that owns a live unit, the records those refreshes must
leave alone, the fog pass, the lone stat recompute, and twelve steps of the
rotation with the twelve game-control slots beside it, and one `NextPlayer`
invocation of the real interpreter with `aRandom`'s seed read either side,
the overheat gate with its roll, six ordered shots,
`aExecuteUse` swept over all eight facings — **replayed through
`inclib/interact.py` in order and without reloading**, because the phase itself
does not reload — and six `aExecuteMove` walks of
one path that differ only in a byte written between the walk and the call.
`python3 tools/turn_gold.py --emit-cases tests/fixtures/turn/cases_turn.json`
turns the capture into the fixture `godot/tests/test_turn_native.gd` reads. **Wine start-up
on this host is intermittent** (`docs/91` §1): a phase can reach the anchor on
attempt 1 or on attempt 8, and one that never does is an environment result
rather than a failure — which is why both tools retry ten times. **Do not lower
`--attempts` to bound a run** — a phase capped below the rest loses probes it
had already taken once, which `docs/91` §1 warns about and which cost one
capture a full re-run. Bound the whole invocation with `timeout` instead; phases
are written as they land and merged on re-run, so a bounded run loses at most
the phase in flight.

## The remake

`godot/` is the remake itself: a Godot 4.7 project whose `core/` is pure
GDScript with no scene tree, no filesystem and no engine singleton, and whose
`game/` renders what `core` decides. It is not a second repository and is not
built by any of the format tools; `docs/92` records its architecture,
`docs/93` reports the first vertical slice that established it, and `docs/94`
the second — the turn, combat, visibility, interaction and the mission-script
interpreter, with `_C_140` played and won in an exported build.

`core/lcl/` is a **subdirectory**, and both `godot/tests/runner.gd` and
`test_isolation.gd` scan `core/` recursively for that reason: a scan that
stopped at the top level would exempt every file in it from the warnings gate
and the isolation sweep.

`docs/93` §10 and §11 are dated addenda recording what the slice left open and
what later closed it: §10 the ladder step and the movement allowance (both
native), `draw_kind`, face triangulation and the 4/8-connectivity asymmetry;
§11 the 3x3 large-unit clearance (native, by writing the `size` byte rather
than by finding a mission with a large unit), `aExecuteMove`'s half of the
ladder rule, a mutation test of the wave-queue guard, and the model bug the
first of those exposed -- the fill's direction loop runs 0..7, and
`anyFriendlyBlocked` is therefore a constant (docs/23 §7.6).

Six things about it that are easy to trip over:

* **Warnings are errors, project-wide.** A script with an untyped declaration
  or an unsafe call argument does not *load*, so a broken file makes the suites
  that never touch it still report success unless something checks. `tests/`
  therefore loads every script under `core/` and `game/` explicitly, and
  `tests/fixtures/violations/` holds a deliberately invalid file that must stay
  invalid. Godot 4.7's `directory_rules` can only exclude a directory, never
  give one a stricter level.
* **`Packed*Array` returned from a function aliases the original.** Writing
  through the returned handle writes through to the source. Every accessor in
  `core/` therefore returns `duplicate()`, and `tests/test_isolation.gd` mutates
  a snapshot and re-hashes the world to keep it that way.
* **The cache is JSON and holds no float.** `JSON.parse_string` produces a
  `float` for every number, so the narrowing to typed arrays happens once at the
  loading boundary and the canonical hash never sees the parsed form — a hash
  over parsed floats would be stable and wrong.
* **The output root is not a scratch directory.** `remake_convert.py -o` is
  refused for the game installation and for this repository, and the collector
  removes only directories carrying one of its own manifests — it used to
  delete every subdirectory it found under `-o`, which turns a mistyped path
  into data loss.
* **`CONVERTER_VERSION` is written down twice**, in `tools/inclib/cache.py` and
  in `godot/game/cache_loader.gd`, and a mismatch makes the loader refuse the
  cache — which is what it is for. Change the emitted document and you must bump
  both **and** republish `user://caches`; the suites read the published cache,
  not only `godot/generated`.
* **A mutation battery must clear `tools/**/__pycache__` before its final run.**
  Write-mutate-restore completes inside one filesystem mtime tick, so CPython
  accepts the stale bytecode and the *mutated* module keeps running after the
  source is restored. It reported a clean tree as 112/114 once.
* **Published cache directories are immutable and content-addressed.** Their id
  includes the source and output inventories. Publish, pointer switch and
  collection share one inter-process lock; do not reintroduce an in-place
  replacement of the directory `active.json` names.

```bash
python3 tools/remake_convert.py gog_incubation -o "$(...)/caches"   # publish
python3 tools/remake_convert.py gog_incubation --dev-fixtures godot/generated
bash tools/verify_untouched.sh gog_incubation snap.txt [--check]
godot --path godot -- --mission=_C_141        # run one of the converted maps
```

`docs/93` has the two-command first run. **After changing anything under
`godot/`, export and launch the shipping build as well as running the suites**:
that preset excludes `tests/`, so a `class_name` from there used in `game/`
breaks only the exported build, and it has done so once.

## Documentation

`docs/00-overview.md` is the entry point and carries the format inventory table with per-format status and coverage. Numbered by family: `10` `.lev`, `11` `.sav` (the only format the game writes; it embeds a whole `.lev`), `20`/`21` LCL and the game-balance schema, `22` combat and visibility, `23` the AI turn, `25` the turn and the round, `26` interaction and set-pieces, `27` the campaign layer, `28` effects and sound, `29` the interface contract (**behaviour, not file formats**), `24` the briefing and info text markup, `30`/`31` Eng3d ASCII formats and `prototyp.bin`, `40` Charisma, `41` the sequence player, `50` VISN, `60` sprites/fonts, `70` lookup tables, `90` binaries.

The runtime-research package matrix is in `docs/00-overview.md`; packages A through G are **delivered** as `docs/25` through `docs/29` and `docs/41`. The permanent module map and research method are in `docs/90-binaries-and-source-layout.md`. `docs/92-remake-architecture.md` records the remake's own decisions — Godot 4, GDScript for the game logic, the Python pipeline converting on the player's machine, and the nine product decisions in its §7 that the numbered specs point at; nothing architectural is left open there.

Every doc ends with an **Open questions** section — `21` gained an explicit empty one, having previously had none at all and so been skipped by the tally. **38 items remain open** across the set (`10`: 4, `11`: 3, `20`: 0, `21`: 0, `22`: 0, `23`: 0, `24`: 0, `25`: 2, `26`: 6, `27`: 2, `28`: 2, `29`: 0, `30`: 10, `31`: 1, `40`: 5, `41`: 0, `60`: 2, `70`: 1); the rest are marked closed in place, each with the evidence. Keep those sections honest — when you close an item, move it into the body with the evidence, and when you find a new unknown, add it.

Most of what remains is open *in principle*, not merely untraced: no symbols (enumerator names, the `J` animation family), an authoring tool that never shipped (`class_code`, `type_code`, `EDITORDETAIL`), or all-zero fields that no amount of data can characterise. Before spending effort on one, read what the entry already says was tried.

Documentation and all code comments are in **English**. Conversation with the user is in Russian.

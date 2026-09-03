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
python3 tools/combat_tables.py    --check gog_incubation      # 56 checks, 48/48 patterns
python3 tools/trace_names.py      --check gog_incubation      # 324 + 146 names
python3 tools/sav_tables.py       --check gog_incubation      # 69 checks
python3 tools/sav_parse.py        gog_incubation --selftest   # 31 map sizes
python3 tools/typ_parse.py        --check gog_incubation      # 18 checks
python3 tools/ai_tables.py        --check gog_incubation      # 77 checks
python3 tools/brief_parse.py      --check gog_incubation      # 55 checks
python3 tools/turn_tables.py      --check gog_incubation      # 85 checks
python3 tools/interaction_tables.py --check gog_incubation    # 114 checks
python3 tools/campaign_tables.py    --check gog_incubation    # 237 checks
python3 tools/blob_tables.py        --check gog_incubation    # 458 checks
python3 tools/blob_runtime.py       --selftest               # 78 kinds, 74 arms
python3 tools/pe_exports.py         --check gog_incubation   # 6 engine listings
python3 tools/interface_tables.py   --check gog_incubation    # 39 checks
python3 tools/charisma_tables.py    --check gog_incubation    # 40 checks
python3 tools/presentation_tables.py --check gog_incubation   # 687 checks, docs/42
python3 tools/seq_parse.py          --check gog_incubation    # 75 checks, 130/130
python3 tools/charisma_selftest.py                            # no corpus; synthetic
python3 tools/dbgcall_patches.py    gog_incubation --selftest # 15 checks
python3 tools/info_parse.py         --check gog_incubation   # 21 checks
python3 tools/lcl_runtime.py        --check gog_incubation   # 58 checks, 942 invocations
python3 tools/turn_runtime.py       --check gog_incubation   # 61 checks, 1863 units
python3 tools/combat_runtime.py     --check gog_incubation   # 148 checks, LOS/hit/damage/reaction/experience/jam/warp/placers
python3 tools/interact_runtime.py   --check gog_incubation   # 79 checks, aExecuteUse, the heal, the entry point's fire
python3 tools/movemap_runtime.py    --check gog_incubation   # 31 checks, 3726 fills, 4587 paths, 4587 walks
python3 tools/ai_runtime.py         --check gog_incubation   # 84 checks, 108 missions
python3 tools/remake_convert.py     gog_incubation --check   # 190 checks, 6 missions
python3 tools/remake_convert.py     --check-cache            # 29 checks
bash   godot/run_tests.sh                                    # 33 suites, 2773 checks
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
python3 tools/charisma_tables.py gog_incubation \
    --emit-pose-cases tests/fixtures/charisma/cases_pose.json
python3 tools/ai_runtime.py      --emit-cases tests/fixtures/ai/cases_ai.json --root gog_incubation
#   ^ the case file carries each move's `path` and, since 2026-09-02, the walk's
#     `seen_source` / `seen_destination` (docs/42 §3.2, the two writing passes'
#     answers); `test_ai` names the missing key and this command when it reads
#     an older file.
python3 tools/blob_tables.py     --emit-sound-cases tests/fixtures/sound/cases_sound.json \
    --root gog_incubation
python3 tools/blob_runtime.py    --emit-cases tests/fixtures/blob/cases_blob.json \
    --root gog_incubation
python3 tools/presentation_gold.py --emit-death-cases tests/fixtures/presentation/cases_death.json \
    --root gog_incubation
python3 tools/presentation_gold.py --emit-idle-cases tests/fixtures/presentation/cases_idle.json \
    --root gog_incubation
python3 tools/presentation_gold.py --emit-special-cases tests/fixtures/presentation/cases_special.json \
    --root gog_incubation
#   ^ the seventh native suite's fixture (`test_ctrl_map.gd`): the cells and
#     the 80-slot object array the engine left after each of the four cell
#     placers of docs/42 §9.1 and two round ticks, replayed by
#     `godot/core/cell_objects.gd`.  One of the eight phases is the refusal
#     that matters most -- the capture is on `World_A00`, which carries no
#     `GLOW1/2.3DI`, so `SetGroundFire`'s placer writes nothing at all.
#   ^ the sixth native suite's fixtures (`test_presentation_native.gd`): the
#     engine's own records for the ten death creators of docs/42 §4.8.1,
#     replayed by `game/fx/blob_programs.gd`, and the idle starter's two
#     hundred calls of docs/42 §6, replayed by `game/charisma/idle_scheduler.gd`;
#     both need the capture below.
```

The last two are the fifth slice's, and `blob_runtime.py --emit-cases` still
runs with **no game root at all**: it is a transcription of `aBlob_Update`, not
a reader, which is exactly why it can be an oracle for a layer the corpus
cannot exercise. `--root` changes exactly one thing — the orientation service
becomes `0x00403AA0`'s **measured** arithmetic (`docs/28` §7.4.2) and the
shipped `TRIG.IMG`/`ATN.IMG` ride along in the fixture so the GDScript twin
reads the same numbers. Without it the fixture says `"orient": "substitute"`,
both twins fall back to the older invented helper, and `test_blob.gd` **fails**
on that field: the fallback exists so a root-free run still produces a
consistent oracle, not so it can pass unnoticed.

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

`charisma_tables.py` is the fourth slice's: it enumerates the four name
selectors of `docs/40` §7.2 by **interpreting** the `switch` cascades in
`Incubation.exe`, and its strongest check is that the result equals, exactly,
the 104 models and 30 idle animations `fcn.00407e90` registers eagerly -- two
readings of the same binary that share no code. It also pins the bone-to-mesh
scale of 16 (`docs/40` §5.3) and the pose of all 311 (model, clip) pairings.
It emits the Godot pose fixture too, with the root **positional**:
`python3 tools/charisma_tables.py gog_incubation --emit-pose-cases tests/fixtures/charisma/cases_pose.json`.

`--verify-convention` and `charisma_selftest.py` are the two that guard *meaning* rather than structure: the first gates on the quaternion-component hypothesis still explaining ≥80 % of tracks, the second asserts decoded key values and times. Structure-only checks pass unchanged when components are permuted, so do not remove either.

**CLI inconsistency to watch for:** the game root is a positional argument for `lcl_parse`, `lev_parse`, `lib_extract`, `visn_decode`; but it is the *argument to* `--check` for `cho_parse`, `cha_parse`, `font_render`, `combat_tables`,
`sav_tables`, `typ_parse`, `ai_tables`, `brief_parse`, `turn_tables`,
`interaction_tables`, `campaign_tables`, `blob_tables`, `interface_tables`,
`info_parse`, `movemap_runtime`, `movemap_gold`, `turn_runtime`,
`combat_runtime`, `interact_runtime`, `lcl_runtime` and `trace_names`; and `--root` for `prototyp_parse` and `verify_3d_indices`.
`remake_convert` takes it positionally **and** wants `--check` as a bare flag;
`charisma_tables` takes it as the argument to `--check` but **positionally**
for `--emit-pose-cases`, which is the one tool that does both.
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
- `eng3d` — the engine's fixed-point geometry: the shipped `TRIG.IMG`/`ATN.IMG`
  tables, the 4096-unit angle helper, the Q14 matrix and `0x00403AA0`'s
  orientation. `godot/game/fx/eng3d_geometry.gd` is its twin
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

`tools/blob_gold.py` is the fourth, and it is **outside the always-run block**
because its check needs a capture. Its `--check` fails without one, on purpose;
the thirty creator arities it depends on are pinned in `blob_tables.py` instead
(`creators.arity_table`), so a change to the switch tables is caught whether or
not anybody has Wine. It is the one that reaches the part of the
effect layer no static reading does: the **creators** of `docs/28` §7.6. It
resets the pool, calls a creator with controlled tile arguments inside the live
process and reads the records back, so what a shot looks like stops being the
remake's invention. Three things it records that are easy to get wrong:
`aGetMemory` writes a **handle**, not a pointer (the block address is
`[0x0050DE54 + 74*handle]`, which is what both the constructor and
`aDrawZoomBlobs` compute, and the heap address itself moves between runs);
`--code` makes `Incubation.exe` fault before the anchor on this host, so the
table read is the only route; and `--probe` **cannot** recover a `__cdecl`
arity, so the thirty arities come from each caller's own `add esp, K` and are
pinned whether or not a capture ever runs. What the capture found is
`docs/97` §15.5 **as corrected by §16**, and three of §15.5's four headline
findings had a wrong premise -- read them together. The engine's own pool
agrees with the static tables field for field. The origin is the **placed
object's** position (`aGetSymbolObjectPtr`'s `+0x10/+0x14/+0x18`), not the
tile and not the floor -- no creator reads the control map's height at all,
which is what settles "absolute z" against "floor plus a constant" for all
thirty rather than for the one a probe touches. Placement is **not one law**:
some creators lay their blobs along the line to the target (one lays eight
evenly down it, which is a tracer) and some in a burst around the source, and
which is which is pinned per creator. And the velocities are **not**
`aRandom`'s: its seed is unmoved either side of all thirty and no creator's
closure calls it. They come from a second entry point at `0x004638E0` --
`aRandom`'s body byte for byte over the seed at `0x00514070`, seeded from
`GetTickCount()` where `aRandom` is seeded to 1.0, so the effects were never
meant to repeat run to run (`docs/22` §3.2). With **that** seed read either
side the draw count is exact, and most creators draw nothing.
`python3 tools/blob_gold.py --check gog_incubation` re-runs the models against
the capture (**259 checks**); taking one needs `--game-copy` and Wine. It also carries the
**`hooks` phase**, which is what closed `docs/28` §12 item 1: all five service
routines an update arm reaches outside its own record, called in the live
process and swept — twenty deltas through the orientation helper, forty through
the geometry one, eight rotations, eighty-one object ids and every named unit
slot. `tools/inclib/eng3d.py` reproduces **all five** exactly and `--check`
compares them answer for answer. The last to fall was Eng3d's three-angle
matrix builder, and the three things that had to be right together are all in
`Eng3d.dll` rather than in the caller: it **negates** each angle before it
indexes the table, its products are 64-bit and floored where `0x004039F0`'s
twelve bytes away are 32-bit and truncated toward zero, and its chained triple
products shift at **every** step. The five runtime function pointers are named
too — `Incubation.exe` resolves them by ordinal written out as **decimal
text**, so `push 0x004BF9F8` is the string `"13"` and `Eng3d.dll`'s export
table finishes the sentence. It also carries the two **tick** families, which is what closed the second
half of `docs/28` §12 item 1 — the arms themselves, stepped in the engine.
`ticks_*` calls the engine's own frame sweep `aCheckInBlobObjects`
`0x0041E3D0`; `arms_*` calls `aBlob_Update` `0x0041E500` per record, and
exists because the sweep hands every record whose class is not 2 or 3 and
whose `delay` has run out to Eng3d's `0x00403CC0`, which faults outside an
open render frame — a class-2 pool that spawns a **model** blob therefore
dies a few sweeps in rather than at once, which is what `aBlob_CreateLaser`
`0x00428200` does through its kind-71 arm (`docs/97` §19.2). 24 of the 74
arms are populated by a creator a weapon switch selects and **all 24
reproduce the engine's record field for field**; the last two to fall were
the seekers, arms 25 and 58, whose step is `docs/28` §7.7.1 and whose target
is the object named by `[unit_map[record + 0x54] + 0x4B]`. The **`poked_*`**
family reaches the other fifty, which no creator fills: `+0x44` is the
jump-table index and `+0x45` is `life`, so writing **two adjacent bytes** into
a donor record through the game's own imported `memcpy` makes it a record of
any kind with a lifetime short enough to reach its own terminal branch, and
`aBlob_Update` is then called per record per round with the pool read back
after **every call** so a fault costs only the arms after it. The `life` half
exists because a mutation battery caught kind 76's `life <= 4` branch being
transcribed and never run. All fifty reproduce the engine too --
after ten of them were fixed (`docs/97` §20), which is what that experiment
was for. So **74 of 74 arms are stepped and agree**, 24 with a creator's
record and 50 with a donor's; the second is weaker in one way and no other,
in that the arm is measured and the arguments a creator would pass it are
not. **How much of each arm that reached is measured too** (`docs/97` §21):
the comparison is line-traced and runs **377 of the 385** transcribed arm
lines, 73 of 74 arms entirely, after a second sweep vector (`life` 12, `aux`
10, fourteen rounds) and eight one-arm probes were chosen against the first
measurement -- one vector is one point of an arm's input space, and the
kind-76 defect a battery once found was a branch nothing had executed. The
**two** lines left are pinned **by source text** in `COVERAGE_UNCOVERED`, and
they are one **deliberate divergence** -- kind 41's arm is
`mov eax, 0x200 / cdq / idiv [esi+0x48]` with nothing in front of the divide,
so a record with no `vx` kills the original. A poked record did exactly that,
which is how it was found and why the sweep vector no longer writes `vx`. The
guard in `blob_runtime` and `blob_kinds.gd` is the **port's**.
Kind 59's six were there too, called unreachable because the byte
`0x00461E80` returns is in no record. It is the **output system's** mode id at
`0x00512A78` (`docs/97` §23.3), so the `mode_59` phase writes that global
through the game's own `memcpy`, steps the arm under it and puts it back --
the extra emitter is a **3D-accelerator** effect, present only in the
configuration whose surface comes from `Eng3d.dll`'s ordinal 67,
`_E3DCARD_open_3dcard_screen`, rather than from `aCreateMainDDObject`. Its three readings of the global, before the write,
after it and after the restore, are what say the branch could run at all.
`--check` also reads **all thirteen creator constants back out of the shipped
executable** -- but in `blob_tables.py`, not here, because that check needs no
Wine: nine doubles in the `0x004B12xx` block, three subtracted immediates, and
two divisors that are *not in the bytes at all* and are recovered by replaying
the reciprocal multiply the compiler left instead of them. The same file also
pins the **output system** the emitter branch reads (`docs/97` §23.4): all five
display modes field by field, and what two of their fields *are* --
`0x00512A9C` is the scanline stride in **bytes**, which the 320x200 mode
proves by reserving 640 of them for a 320-byte row and the pixel plot
`0x00463C40` confirms by halving it on its sixteen-bit arms and not on its
eight-bit one; `0x00512A60` is bytes per pixel. Neither was read off a symbol
-- there is none -- so neither is left named by its value. The stride's
*source* is named by a public ABI rather than by its value either
(`docs/97` §23.5): `0x00432C30` returns the **address of a static block**,
aLIB's DirectDraw module state, whose `+0x18` is a `DDSURFACEDESC` -- both
lock helpers write `dwSize = 0x6C` into it, hand its address to vtable slot
`+0x64` (`IDirectDrawSurface::Lock`) and push `"DD_Lock"` on the failure arm
-- so `[obj + 0x28]` is `lPitch` and the pointer they return is `lpSurface`.
It is `lPitch` for **two** of the four display modes: mode 0 never rewrites
the global and mode 3 has Eng3d fill it.

**The ten creators that had no named mechanism are transcribed** (`docs/97`
§22): `tools/inclib/blob_creators.py` carries all ten as programs read out of
their own instructions, and `native.creator_program_records` replays each from
the measured seed and reproduces every field of every record the engine left,
with the draw count checked against `aRandom2`'s seed either side of the call
-- which reaches the records past the twelve a capture reads back. Three
read-only phases feed them: `units` (the whole unit array, for `+0x4B`),
`origins` (the control map, the standard object array, both unit heights) and
`symbols` (the two objects the cells name). The last exists because
`aGetSymbolObjectPtr` `0x00404C40` and `aGetStdObjectPosition` `0x00405100`
are **two different tables** -- the source tile names symbol 139 while the
standard object standing there is id 0, and their `+0x18` differ by 160. Between them the two families found errors in **fourteen** of the
seventy-four arms and one in `_ftol`: kind 11 does **not** delete itself (the
`aDeleteBlobObject` two instructions past its arm is the *wrapper's* expiry
path), kind 8 draws `aRandom(0, 0xFFF)`, not `0x1000` -- and **only** kind 8,
a correction this project then over-applied to kinds 0, 2 and 29, which the
poked pass caught -- `_seek` was steering on a normalised direction the engine
never computes, three arms damp by a twentieth, a fifth and a third where the
model had a tenth, a tenth and a sixth, kind 76 moves **twice** while it lives,
kinds 14 and 37 turn their delta through `0x004039A0` and had
no turn at all, and `_ftol`'s invalid conversion is a **zero** rather than
`INT_MIN` because the caller keeps `eax` of an `fistp qword`. **The suites still
print `executable-Python`** — the transitive claim is per arm and the fixture
carries the list; do not let a suite label the layer `native-runtime`.
`--probe-startup N` is the other new mode and needs no plan of its
own: it runs one plan N times with a single attempt each and reports how often
Wine reached the anchor (`docs/91` §1.1). **One creator per plan**:
a plan that dies takes every creator sharing its process with it, and the
deaths are Wine's own access violation before the anchor rather than anything
the plan contains. Phases are written as they land and merged on re-run, and
`--check` pins the coverage so a thinner capture fails rather than reporting
less.

`tools/ai_gold.py` is the third, and the one that pins a **whole computer
turn**: `python3 tools/ai_gold.py --game-copy /path --dbgcall /path/dbgcall.exe`
captures twelve phases on `_C_140` -- two saves, turn 1 and turn 10 -- and
`python3 tools/ai_gold.py --check gog_incubation` re-runs `inclib/ai.py`
against them (47 checks, `+0x4F` diffed with the rest since 2026-09-02 and the slots it moves on pinned: the three predicates over 90 ordered pairs, the cover
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
198 checks over 86 unit pairs (hit probability **and** line of sight), the
refresh of every player that owns a live unit, the records those refreshes must
leave alone, the fog pass, the lone stat recompute, and twelve steps of the
rotation with the twelve game-control slots beside it, and one `NextPlayer`
invocation of the real interpreter with `aRandom`'s seed read either side,
the overheat gate with its roll, six ordered shots,
`aExecuteUse` swept over all eight facings — **replayed through
`inclib/interact.py` in order and without reloading**, because the phase itself
does not reload — and six `aExecuteMove` walks of
one path that differ only in a byte written between the walk and the call.
Three phases added on 2026-09-02 reload per probe and write through the
game's own `memcpy` (`movemap_gold.MEMCPY_DECL`, shared by all four gold
tools): `reveal` (the shooter's and target's reveals with both written
hidden, a jammed control, the engine's own relocation `0x0047AD90`, and one
step by a computer mover with the *Enemy Move* dword written on and off),
`conversion` (weapon 47 with the byte written and the seed written to one
that clears its always-at-the-cap overheat roll, and the absorber's `+0x33`
gate) and `platform` (`aPlayPlatformSequence` with a rider); a fourth,
`experience` (2026-09-03), kills the one-point alien four times with the
shooter's `+0x17`/`+0x18`/`+0x53` written to the caps, which is what measures
the kill award of `docs/22` §7.5 (`inclib.combat.award_kill`). Their scene is
chosen with the model and the `--check` pins what the engine itself changed,
so a capture on which nothing moved cannot pass as agreement (`docs/97`
§28.7).
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

`game/charisma/` is the fourth slice's: the model, the clip, the track
sampler, `V100Part::Update`, the body and its state machine. `core/lcl/` is a
**subdirectory**, and both `godot/tests/runner.gd` and
`test_isolation.gd` scan `core/` *and* `game/` recursively for that reason: a scan that
stopped at the top level would exempt every file in it from the warnings gate
and the isolation sweep.

`docs/97` reports the fifth -- the world that answers back: the sound layer,
the 450-slot blob pool with all 74 update arms diffed tick by tick against
`tools/blob_runtime.py`, the sprite atlas, the three weapon switches, the
set-piece driver at 20 fps and the terrain diff that finally makes a door
*move*. Its own finding is `RoofUnit`'s drop rate -- one whole map field per
displayed frame, `0x00411E26` -- which neither `docs/20` nor `docs/28` carried;
its correction is to `docs/92` §7.1's accounting of which volume ids the alien
scream's defect left dead. **The suites still print `executable-Python`**, and
must keep doing so: they compare GDScript against Python, not against the
engine. `docs/97` §17 and §18 raised what is *behind* that diff — all five
blob service hooks are measured and reproduced, and **all 74 arms** have been
stepped inside a running `Incubation.exe` and agree field for field (§19
closed the last two of the 24 a weapon can reach, §20 the other 50) — but
that is a **transitive, per-arm** claim carried in the fixture's `native_arms`
list, not a label on the layer -- two lists now, `native_arms` and
`poked_arms`, because a donor record with a rewritten kind byte measures the
arm and not the arguments a creator would give it.

`docs/97` §14 is a later pass over the loose ends that report listed: the model
half of the pool now draws and its joints move, footsteps sound, a unit rides
the lift it stands on, and the exit leak is fixed by not quitting in the same
frame the stream is released. It closed two open questions in **other**
documents -- `docs/28` §12.3 (the shipped build plays the **`Arack`** music
family, read out of `Incubation.exe`'s import descriptor, which names
`audio.dll` where the 1997 build named `WINMM.dll`; nothing imports
`sound.dll`) and `docs/30` §2.5 item 7 (the joint opcodes name their matrix
builder in a `call`; the two the shipped data reaches both build `RzRxRy`) --
and found that the footstep **period is one global** at `0x004FAECC` that one
arm does not write, so type 54 inherits the last walker's. The one item it
scaled down rather than closed is the 81 creators' own placement arithmetic:
30 of them are reachable by firing a weapon, holding 43 of the 116 constructor
calls, and their arguments come from the un-validated hooks above -- so the
reach is **measured and pinned** instead, and closing it wants a `dbgcall`
capture of the live pool.

`docs/96` reports the fourth -- the bodies: Charisma models, skeletons and the
three gameplay animation families, `_C_140` played with bodies that walk and
shoot. Its two corrections to a delivered spec are that the model selector is
**three-level** (type, weapon *and player*) and that the idle selector has a
**randomised arm**; its own finding is that bone translations are in 1/16 of a
world unit while mesh vertices are in world units.

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
godot --path godot --script res://tour.gd --resolution 1280x800 -- \
    --dir=/some/scratch/dir --mission=_C_140   # drive the game from outside
```

`docs/93` has the two-command first run.

`godot/tour.gd` is how the game is played without a player (`docs/97` §42).
It is a `SceneTree` driver beside `shot.gd`, excluded from the shipping preset,
and **the directory it is given is the whole protocol**: it waits for
`cmd-0001.txt`, runs the lines in it, writes `res-0001.json` beside it and
waits for `cmd-0002.txt`. Write each command file with `mv` from a
neighbouring name so a half-written one is never read. The lines are
`key NAME`, `click X Y`, `click_unit SLOT`, `walk_to X Y`, `cell X Y`,
`chance A B`, `wait N`, `idle [MAX]`, `shot NAME`, `note TEXT` and `quit`; every reply
carries the turn, every unit, the selection's fill and warp cells, the
sequence on the queue, the blob pool **by kind**, the overlay, the camera and
the status line, so a screenshot and the numbers behind it come from the same
frame. Keys and clicks go in through `Viewport.push_input`, so the game's own
`_unhandled_input` and `_pick` run -- what is synthetic is the hand, not the
path. It needs a **window**: screenshots come from the viewport's texture and
`--headless` has no renderer, so run it with a `timeout` rather than headless.

`tools/presentation_gold.py` is the fifth gold tool and, like `blob_gold.py`,
is **outside the always-run block**: its `--check` reads a capture that is
gitignored (`tests/fixtures/presentation/README.md` records what it holds) and
fails without one (**712 checks** since 2026-09-03, when the nine shipped
`CrushWall` call sites joined it -- one process each, on saves wrapped from
`_C_129`, `_C_142` and `_O_061` with `sav_parse.py --wrap` and staged as
slots 8, 9 and 10, reading the whole 900-cell control map either side of
`0x0042F410` so the footprint is measured cell by cell (`docs/97` §41.7) --
and, before them, the four cell
placers of `docs/42` §9.1 joined it -- ten `special_*` phases that read the
**whole** control map and the **whole** 80-slot array `[0x004FA828]` before and
after every call, so what is compared is every cell, every slot **and every
object's position** rather than the one the placer was aimed at (`docs/97` §37
and §38). Two of the ten run on a **second save**, built with
`sav_parse.py --wrap` from `_C_116.lev` because `GLOW1/2.3DI` live in
`World_D00` alone -- and, before them, the eleven
set-piece creators of `docs/42` §8 joined it -- the tube's puffs, the
platform's dust, the ground unit's and the roof unit's debris, the crush
wall's, the fire circle's ring, the laser barrier, the statue's beam, the
teleporter's stream, the bomber and one para bomb, twelve phases and 239
records, all field for field on the first run (`docs/97` §32) -- and five more death
phases -- `KillFire` with both delay arguments, `FireDeath`, `FlyingUnit` on
the case's tile and `FireExplosion` -- joined the fourteen, and seven
unit-animation creators of `docs/42` §7 -- the marker's arrows, the landing
dust, the two flash circles, the zoom bob, the jump's trail and the push's
dust, the last three called at the marine's own object position through
`[$s_m+0x10]`-style reads -- joined those: 364 records across twenty-six
calls, all field for field, `docs/97` §31). Sixty phases, one process each, at `docs/91`'s anchor
with the fixture save: `idle_random` calls the engine's idle starter two
hundred times with `aRandom2`'s seed read either side of every call and
replays the draws, which is what pinned that the starter's **type search never
advances** (`0x0040616C` compares unit 0's type two hundred times) and that
every call past the countdown draws one slot; `idle_pose` writes the countdown
and the seed through the game's own imported `memcpy`, starts the one
candidate on the first call and reads every part the clip binds at eight stops
-- reached through the animation's own movement list, since the Charisma
bridge hands the renderer only the root part's record -- which is what measured
the clock at **1.5** a step, the last frame held while the finished clip stays
attached, and the bind pose back on the first step after `aFreeCHAnimation`
(`docs/42` §6); and fourteen `death_*` phases call the seven death and damage
creators of `docs/42` §4.8.1 with controlled tiles and a written seed and
replay `blob_creators.DEATH_PROGRAMS` against the pool they left, field for
field. The idle clip's speed of 1.5, the walk's 2.0 and the fight's 6.0 are the
same start call with a different literal (`docs/42` §1.2), and `docs/40` §4.8's
"the speed is always 1.0" was the constructor's initialiser, not the game. **Do
not use `--code`** here either: the byte writer is the game's imported
`memcpy`, as in `ai_gold.py`.

## Documentation

`docs/00-overview.md` is the entry point and carries the format inventory table with per-format status and coverage. Numbered by family: `10` `.lev`, `11` `.sav` (the only format the game writes; it embeds a whole `.lev`), `20`/`21` LCL and the game-balance schema, `22` combat and visibility, `23` the AI turn, `25` the turn and the round, `26` interaction and set-pieces, `27` the campaign layer, `28` effects and sound, `29` the interface contract (**behaviour, not file formats**), `24` the briefing and info text markup, `30`/`31` Eng3d ASCII formats and `prototyp.bin`, `40` Charisma, `41` the sequence player, `42` the mission's presentation layer — the camera, the animation drivers and what a turn looks like (**behaviour, not a file format**), `50` VISN, `60` sprites/fonts, `70` lookup tables, `90` binaries.

The runtime-research package matrix is in `docs/00-overview.md`; packages A through G are **delivered** as `docs/25` through `docs/29` and `docs/41`; package H, the mission's presentation layer, is `docs/42`. The permanent module map and research method are in `docs/90-binaries-and-source-layout.md`. `docs/92-remake-architecture.md` records the remake's own decisions — Godot 4, GDScript for the game logic, the Python pipeline converting on the player's machine, and the nine product decisions in its §7 that the numbered specs point at; nothing architectural is left open there.

Every doc ends with an **Open questions** section — `21` gained an explicit empty one, having previously had none at all and so been skipped by the tally. **34 items remain open** across the set (`10`: 4, `11`: 3, `20`: 0, `21`: 0, `22`: 0, `23`: 0, `24`: 0, `25`: 2, `26`: 3, `27`: 2, `28`: 1, `29`: 0, `30`: 9, `31`: 1, `40`: 6, `41`: 0, `42`: 0, `60`: 2, `70`: 1); the rest are marked closed in place, each with the evidence. Keep those sections honest — when you close an item, move it into the body with the evidence, and when you find a new unknown, add it.

Most of what remains is open *in principle*, not merely untraced: no symbols (enumerator names, the `J` animation family), an authoring tool that never shipped (`class_code`, `type_code`, `EDITORDETAIL`), or all-zero fields that no amount of data can characterise. Before spending effort on one, read what the entry already says was tried.

Documentation and all code comments are in **English**. Conversation with the user is in Russian.

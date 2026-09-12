# AGENTS.md

## What this repository is

Reverse-engineering of the file formats of **Incubation: Time Is Running Out**
(Blue Byte, 1997), plus a Godot remake built on the result. It is not one
application: `docs/` holds the format and behaviour specifications, `tools/`
holds the Python parsers that prove them, and `godot/` is the remake.

`gog_incubation/` is the retail game and is **strictly read-only**. Never run
the game from here and never write here yourself. `Work/` under it is where the
retail game writes saves and options; it ships empty, but the user's own saves
may be there and are theirs to keep — the rule is that *nothing here writes into
it*, not that it stays empty. `tools/verify_untouched.sh gog_incubation snap.txt
[--check]` lists what it holds so a new file is obvious. Be careful with `cd`: a
shell whose working directory drifts into that tree will silently create
directories there. The tree is gitignored; never "fix" a file in it.

## Commands

`make help` lists everything. All tools are Python 3 with **no third-party
dependencies** (the PNG writer is hand-rolled in `tools/inclib/png.py`); run them
from the repo root.

| Command | What it does |
|---|---|
| `make check-formats` | every format's corpus check — the test suite (read-only, ~40 tools) |
| `make check-cache` | verify the published remake cache |
| `make test-godot` | the Godot harness (`godot/run_tests.sh`; needs Godot 4.7 and fixtures) |
| `make test` | all three of the above |
| `make fixtures` | rebuild the gitignored Godot test fixtures from the retail data |
| `make test-touch` | the viewport-level touch integration run (headless) |
| `make build-macos\|windows\|linux\|android\|ios` | export a target; `make build` is the host |
| `make android-cache[-force]` | the Android payload cache (a build product, ~1 min / 200 MiB) |

Overrides: `GAME_ROOT=`, `GODOT=`, `PYTHON=`, `EXPORT_MODE=debug|release`.

**There is no pytest suite.** Each format's test is its parser consuming **100 %
of that format's files**, and every check **fails on an empty corpus** — a check
that examined nothing is not a check that passed, so a mistyped root cannot come
out green. All exit 0; a non-zero exit is a regression. Run `make check-formats`
after any change under `tools/`.

**Do not maintain the check list twice.** The `Makefile` is the list. A check
added to a tool and not to `check-formats` is a check nothing runs.

**Two checks guard *meaning* rather than structure, and must not be removed:**
`cha_parse.py --verify-convention` gates on the quaternion-component hypothesis
still explaining ≥80 % of tracks, and `charisma_selftest.py` asserts decoded key
values and times ([`docs/40` §6.1](docs/40-charisma-model-animation.md)). Structure-only
checks pass unchanged when components are permuted.

**The game root's argument position varies per tool** — positional, the argument
*to* `--check`, or `--root`; `charisma_tables.py` uses both, depending on the
mode. Read `--help` rather than guessing, or copy the invocation out of the
`Makefile`.

### Asset extraction and inspection

```bash
python3 tools/lib_extract.py gog_incubation -o tools/out/sprites    # sprite PNGs
python3 tools/visn_decode.py gog_incubation -o tools/out/textures   # texture PNGs
python3 tools/lcl_decode.py  gog_incubation -o tools/out/lcl        # deobfuscated scripts
python3 tools/lev_parse.py   gog_incubation --png -o tools/out/maps
python3 tools/cho_export.py  --samples gog_incubation               # posed skeletons
```

`tools/out/` is gitignored — extracted game assets must never be committed.

Most tools also take one file plus `--json`. `lev_parse.py FILE --map` prints an
ASCII terrain map; `prototyp_parse.py --opcodes` dumps the geometry bytecode
dispatch table. Inspection aids with no corpus check: `3dw_parse.py` (`.3DW`
scenes), `dir3di_parse.py` / `din_parse.py` (Eng3d ASCII and binary indexes),
`pe_resources.py` (PE dialogs and string tables — `iDesigner.exe` names most
record layouts there) and `charisma_dump.py` (assumption-free `.cho`/`.cha`
chunk walker).

### Publishing a cache for the remake

```bash
python3 tools/remake_convert.py gog_incubation --campaign-maps \
    --instant-action-maps -o "<user caches dir>"
python3 tools/remake_convert.py gog_incubation --dev-fixtures godot/generated
```

`--campaign-maps` and `--instant-action-maps` **belong together**: the first
replaces `--missions` with all 92 campaign maps (a mission the cache lacks stops
the campaign where it stands), the second adds the ten `_S_*` maps *Instant
Action* lists. Two heavier checks stay out of `make test` because they are slow
or need gitignored inputs: `remake_convert.py gog_incubation --check-campaign`
and `campaign_runtime.py --check-saves tests/fixtures/saves`.

### Running the remake

```bash
godot --path godot -- --mission=_C_141
godot --path godot -- --mission=_C_141 --cheats=god,ammo,kill,moves
godot --path godot --resolution 1280x800 -- --mission=_C_140 --agent-port=8787
python3 tools/agent_client.py wait-up
python3 tools/agent_client.py cmd "click_unit 0" idle
```

Other entry points: `--campaign=N`, `--sequence=N`, `--credits`; with no flag the
game starts from its shell. Cheats are also reachable in-game on the backquote
line. See [`docs/93` §1](docs/93-slice-1-report.md) for the two-command first run
and [`docs/92` §7.18](docs/92-remake-architecture.md) for the cheat switches.

## Architecture

### Two engines, two format families

- **Game/editor layer** (`C:\aProject\...`, Blue Byte's own `aLIB`) — owns
  `.lev`, `.lcl`, `.LIB`, `.pal`.
- **Eng3d + Charisma** (`D:\PRO\3DLIB\eng3d\`) — the renderer and the
  model/animation system. `CHData` = *Charisma* data. Owns `.3DW`, `.dir`/`.din`,
  `prototyp.bin`, `texture.lib`, `.cho`, `.cha`.

[`docs/90`](docs/90-binaries-and-source-layout.md) reconstructs the original
source tree and is the fastest way to find which module owns a format.

### How the formats reference each other

A remake's loader has to walk this chain:

```
Missions/_C_105.lev
  ├─ header names world set "B00" and scene "Level02b"
  │     └─ WorldSet/World_B00/Worlds/LEVEL02B.3DW → [CLO] blocks name prototypes
  ├─ land + special object records name/index prototypes
  │     └─ WorldSet/World_B00/Objects/prototyp.din  (binary index)
  │           └─ prototyp.bin  (geometry bytecode)
  │                 └─ texture ids → TEXTURES/texture.din → texture.lib (VISN)
  ├─ unit records carry a type id → DATA/Info.lcl SetUnitInfo table (docs/21)
  └─ Missions/_C_105.lcl  drives the mission (docs/20)

CHData/Objects/*.cho    → mesh names → the same prototyp.din
CHData/Animations/*.cha → bone names must match the .cho part names
```

Two consequences worth internalising: **`.cho` contains no geometry** (it
references meshes by name), and **`prototyp.bin` is not a mesh structure** — it
is a bytecode program the engine executes in place, including a BSP tree.

### Code layout

`tools/inclib/` is the shared library; `tools/*.py` are thin CLIs over it. Reuse
`inclib`, don't duplicate:

- `binio.Reader` — little-endian primitives plus `lpstring()` (u32 length + that
  many bytes, no NUL), the convention Charisma uses throughout
- `png` — dependency-free indexed and truecolour PNG writing
- `palette`, `liblib`, `lev`, `charisma`, `prototyp`, `visn`, `lcl` — one module
  per format family (`lcl` holds the script codec, tokenizer, parser and AST)
- `eng3d` — the engine's fixed-point geometry: the shipped `TRIG.IMG`/`ATN.IMG`
  tables, the 4096-unit angle helper, the Q14 matrix, `0x00403AA0`'s orientation
- `rng` — `ARandom` (`0x00463870`, Lehmer), which serves **two streams**: the
  game's, seeded to 1.0, and `0x004638E0`'s over a separate `GetTickCount()`
  seed, which the effect layer draws from; plus `CRandom` (the C runtime's,
  used only by `InsertUnit`)
- `pe` — PE sections, resources and typed reads **by virtual address**, so the
  addresses the docs quote can be used directly
- `script`, `lcl_runtime`, `turn`, `combat`, `interact`, `ai`, `blob_*` — the
  executable models of the interpreter, the turn, combat, interaction and effects

Parsers raise a typed error (`ParseError`, `LevError`, `LibError`,
`PaletteError`, `VisnError`) instead of returning partial results, so a corpus
check cannot pass by silently skipping files. **Keep that property.**

## Working rules specific to this project

**Every spec claim needs a corpus check behind it.** A field table no parser
validates against all files is a guess. State coverage as `N/N` in the doc.

**Mark uncertainty explicitly.** The docs use **UNVERIFIED** plus the observed
value distribution. `u8 at +0x12, set on 44 of 184162 cells, no correlation
found` is a good spec line; a plausible-sounding invented name is a bug that
costs someone days later.

**These files are raw `fwrite` dumps of C structs from an MSVC debug build.**
Uninitialised heap (`0xCD` fill) and stale pointers appear inside otherwise
meaningful records:

- **Never find an array's end by scanning for a `0xCDCDCDCD` sentinel. Read the
  count field.** Doing otherwise once produced a completely fictitious "fixed
  40×40 lattice" claim out of leftover memory that looked like valid records.
- Ignore fields documented as runtime scratch; do not interpret them.

**Prefer the decompiled binary over pattern-matching bytes**, and read
[`docs/90` §4–§5](docs/90-binaries-and-source-layout.md) before using `r2` or
Ghidra — it carries the method, the `izz`+`axt` direction trap (the string is
pushed at the *call site*, so you land on the caller), `trace_names.py`, the
`strings` threshold hazard and the Ghidra project-lock rule.

**No new Python twin for a new subject** ([`docs/92` §5.1](docs/92-remake-architecture.md)).
An executable model in `inclib` is written where a spec's claim is arithmetic
that has to run over the whole corpus; where the claim is structural, a parser
check plus a native capture is the whole of it and the rule goes straight into
GDScript. The existing models are frozen, not retired.

### Runtime verification

Running the original code is the strongest evidence available, and Wine 11 runs
32-bit x86 PE on arm64 macOS (`i686-w64-mingw32-gcc` is installed). Two
harnesses answer different questions:

- `tools/wine_visn/` loads `Eng3d.dll` **out of process** and calls its entry
  points. Use it when a routine depends only on its arguments.
- `tools/dbgcall/` runs `Incubation.exe` or `iDesigner.exe` **under a debugger**,
  breaks, and calls functions **inside the live process**, so the engine's own
  globals are initialised. It verifies a declared signature against the callee's
  real stack cleanup, and can patch the running image. Read
  [`tools/dbgcall/README.md`](tools/dbgcall/README.md) first; after changing it
  run `bash tools/dbgcall/selftest.sh`.

Five "gold" tools drive `dbgcall` to capture oracles. All are **outside**
`make test`: each needs Wine plus a **copy** of the game (they refuse a game
directory inside this repository), and each `--check` fails without a capture.

| Tool | Subject | Capture |
|---|---|---|
| `movemap_gold.py` | the fill, the ladder, the allowance, the path walk | `--game-copy` + `_6_.sav` staged as `Work/Saves2/` |
| `turn_gold.py` | the hand-over, line of sight, hit probability, interaction | imports `run_plan` from `movemap_gold` — same session |
| `ai_gold.py` | a whole computer turn on `_C_140` | **must not use `--code`** (see below) |
| `blob_gold.py` | the effect pool's creators and all 74 update arms | one creator per plan; `--probe-startup N` reports reachability |
| `presentation_gold.py` | the death, idle, unit-animation and set-piece creators | one process per phase |

Three operational rules that have each cost a re-run:

- **Wine start-up on this host is intermittent** ([`docs/91` §1](docs/91-wine-runtime-probes.md)):
  a phase may reach the anchor on attempt 1 or on attempt 8, and one that never
  does is an environment result, not a failure. **Do not lower `--attempts`** to
  bound a run — bound the whole invocation with `timeout` instead. Phases are
  written as they land and merged on re-run.
- **`--code` makes `Incubation.exe` fault before the anchor on this host.** Where
  a capture needs to write a byte, use the game's own imported `memcpy`
  (`movemap_gold.MEMCPY_DECL`, shared by all the gold tools) with a plain
  `--blob`.
- **A phase with no records is not always a refusal.** An argument the capture
  filled wrongly produces a faithful zero that verifies nothing. The tools pin
  what a capture does not reach (`NATIVE_FAULTS`, `PROGRAM_ARGS_STALE`,
  `BURST_UNCAPTURED`, `COVERAGE_UNCOVERED`, `*_UNCAPTURED`) so a thinner capture
  fails rather than reporting less.

Fixtures live in `tests/fixtures/`, are **all gitignored**, and each directory's
committed `README.md` records what it holds. `tests/fixtures/saves/` holds six
real saves made by running the retail game under Wine from a **copy**
(`wine explorer /desktop=inc,640x480 Incubation.exe -english`); `.sav` is the
only format the game writes and each save embeds a whole `.lev`.

## The remake

`godot/` is a Godot 4.7 project whose `core/` is pure GDScript — no scene tree,
no filesystem, no engine singleton — and whose `game/` renders what `core`
decides. [`docs/92`](docs/92-remake-architecture.md) is its architecture and the
place every product decision is recorded; the nine slice reports are
[`docs/93`](docs/93-slice-1-report.md) through [`docs/101`](docs/101-slice-9-report.md).
`core/campaign/` plus `game/campaign_host.gd` and `game/screens/` are the
campaign; `game/charisma/` the bodies; `game/fx/` the effect pool;
`game/sequence/` the cutscenes; `game/agent/` the control server;
`game/touch_input_controller.gd` the mobile input path
([`docs/92` §7.21](docs/92-remake-architecture.md)).

**The suites print `executable-Python`, and must keep doing so.** They compare
GDScript against the Python models, not against the engine. Where a layer has
also been stepped inside the running original, the claim is **per item** and
lives in the fixture's own list (e.g. `native_arms` / `poked_arms`) — never a
label on the layer.

### Rules that have each broken a run here

Each of these is explained where it was found; the one-liner is what to act on.

- **Warnings are errors, project-wide.** A script with an untyped declaration or
  an unsafe call argument does not *load*, so a broken file lets suites that
  never touch it still report success. `tests/` therefore loads every script
  under `core/` **and** `game/` recursively, and
  `godot/tests/fixtures/violations/` holds a deliberately invalid file that must stay
  invalid. The gate is the **editor's**: the exported build runs the engine's
  default levels, so the violating fixture compiles there.
- **`Packed*Array` returned from a function aliases the original.** Every
  accessor in `core/` returns `duplicate()`; `test_isolation.gd` keeps it so.
- **The cache is JSON and holds no float.** `JSON.parse_string` produces a
  `float` for every number, so the narrowing to typed arrays happens once at the
  loading boundary — the canonical hash must never see the parsed form.
- **`CONVERTER_VERSION` is written down twice**, in `tools/inclib/cache.py` and
  `godot/game/cache_loader.gd`, and a mismatch makes the loader refuse the cache.
  Change the emitted document and you must bump **both** and republish the cache
  — the suites read the published one, not only `godot/generated`.
- **Published cache directories are immutable and content-addressed.** Publish,
  pointer switch and collection share one inter-process lock; never reintroduce
  an in-place replacement of the directory `active.json` names.
- **The output root is not a scratch directory.** `remake_convert.py -o` refuses
  the game installation and this repository, and the collector removes only
  directories carrying one of its own manifests.
- **The picture reads a *lagging mirror*, not the world.** `core` resolves a whole
  command before it returns; `game` advances a clone one event delta at a time.
  Every reader of what is on screen goes through `SliceMain.shown()`; the truth
  is read only to submit a command and to ask whether one is allowed
  ([`docs/100`](docs/100-slice-8-report.md)).
- **Nothing may be left alive at exit.** `run_tests.sh` fails the run on every
  leak line Godot prints *after* the last check (`resources still in use`,
  `ObjectDB instances were leaked`, `RID(s) ... leaked`). Re-run with `--verbose`
  to have them named.
- **A reference cycle between two `RefCounted`s fails the suites** — Godot never
  collects one. Hold back-pointers through `weakref` and read them back with an
  **assignment** (`var x: T = ref.get_ref()`); `as T` is `UNSAFE_CAST`, and
  warnings are errors.
- **A `static var` anywhere keeps its whole dependency tree loaded**, and **only
  the exported build says so**. There is no `static var` in the project; keep it
  that way.
- **A one-off `godot --script` run needs `--import` in front of it.** Without it
  the run executes the *previously imported* version of an edited file, which
  silently invalidates an A/B bisection. `run_tests.sh` does the import step.
- **A mutation battery must clear `tools/**/__pycache__` before its final run.**
  Write-mutate-restore completes inside one filesystem mtime tick, so CPython
  keeps running the *mutated* module after the source is restored.

### The agent control server

`--agent-port=N` on an **ordinary** launch raises it, so what is driven is the
shipping build. It lives in `godot/game/agent/`, ships inside the export, is
inert without the flag and binds `127.0.0.1` only (`--agent-port=0` takes a free
port and prints it). `--agent-dir=` moves the screenshot files and **nothing
else** — a driven session writes its saves and settings into the live `user://`,
exactly as a played one does. It needs a **window**: screenshots come from the
viewport's texture, so run it with a `timeout` rather than `--headless`.

| Route | Answer |
|---|---|
| `GET /health` | liveness before a world exists; `booted` is what `wait-up` polls |
| `GET /state` | the snapshot, answered in the frame it lands even while a command runs |
| `GET /shot` | the current frame as `image/png`; `?save=NAME` files it too |
| `GET /help` | `AgentSession.VERBS` — the one source of truth for the verb table |
| `POST /command` | a batch of verbs; one batch at a time, a second is **409** |

Keys and clicks go in through `Viewport.push_input`, so the game's own
`_unhandled_input` and `_pick` run — what is synthetic is the hand, not the path.
See [`docs/92` §7.16](docs/92-remake-architecture.md).

## Documentation

[`docs/00-overview.md`](docs/00-overview.md) is the entry point and carries the
format inventory with per-format status and coverage, plus the package matrix.
Numbered by family: `10` `.lev`, `11` `.sav`, `20`/`21` LCL and the game-balance
schema, `22` combat and visibility, `23` the AI turn, `24` briefing markup,
`25` the turn and the round, `26` interaction and set-pieces, `27` the campaign,
`28` effects and sound, `29` the interface contract, `30`/`31` Eng3d ASCII
formats and `prototyp.bin`, `40` Charisma, `41` the sequence player, `42` the
mission's presentation layer, `43` the battle interface, `50` VISN, `60`
sprites and fonts, `70` lookup tables, `90` binaries and research method, `91`
Wine probes, `92` remake architecture, `93`–`101` the slice reports. Several of
them (`22`–`29`, `41`, `42`, `43`) specify **behaviour, not file formats** — a
loader that reads every byte still cannot play a turn; `docs/00` groups them and
names each one's checker.

**Every doc ends with an Open questions section, and they are kept honest.**
When you close an item, move it into the body with the evidence and mark it
closed in place; when you find a new unknown, add it. Before spending effort on
one, read what the entry already says was tried — most of what remains is open
*in principle* (no symbols, an authoring tool that never shipped, all-zero
fields no amount of data can characterise).

Documentation and all code comments are in **English**. Conversation with the
user is in Russian.

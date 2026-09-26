# Tools

Python 3 parsers and extractors for the Incubation file formats. **No third-party
dependencies** — everything, including PNG writing, is implemented against the
standard library so the tools run anywhere.

The game directory is read-only. All output goes to `tools/out/`.

## Layout

```
inclib/          shared library code
  formats
    binio.py       little-endian Reader; the u32-length-prefixed string convention
    png.py         minimal PNG writer (8-bit indexed and 24-bit truecolour)
    bmp.py         8-bit Windows BMP decoder for the shipped screen art
    palette.py     .pal loader (Windows BMP colour tables)
    liblib.py      .LIB shape-library parser
    lev.py         .lev battle-map parser
    lcl.py         LCL codec, tokenizer, parser and AST
    info.py        DATA/Info.lcl balance tables as typed records
    brieftext.py   briefing and info text reader (docs/24)
    language.py    the languages the engine knows
    visn.py        VISN texture codec
    prototyp.py    prototyp.bin geometry decoder (command streams, meshes)
    overdraw.py    which of two coplanar faces of one prototype the engine shows
    charisma.py    shared primitives for the .cho/.cha streams
    charisma_tables.py  the four Charisma name selectors (docs/40 7.2)
    pose.py        V100Part::Update: a track, a bone, a matrix
    pe.py          PE reader: sections, resources, and reads by virtual address
  engine arithmetic
    eng3d.py       the engine's fixed-point geometry (TRIG/ATN tables, Q14 matrix)
    rng.py         ARandom's two streams, and CRandom
    footprint.py   0x0042F410: the control-map cells a placed object stands on
    ctrlmap.py     the transient objects a control-map cell owns
    allowance.py   aGetMovePoints (docs/10 5.5)
  executable models
    lcl_runtime.py the LCL interpreter (docs/20)
    combat.py      line of sight, visibility and combat (docs/22)
    movemap.py     aBuildMoveMap (docs/23 7)
    ai.py          the computer's turn (docs/23)
    turn.py        the turn and the hand-over (docs/25)
    interact.py    aExecuteUse and its gate (docs/26)
    campaign.py    the campaign layer (docs/27)
    sound.py       the sound layer (docs/28)
    blob_creators.py  the blob creators no recipe explained (docs/28 7.6.1)
  remake cache
    cache.py       manifest, staging, validation, atomic publish; CONVERTER_VERSION
    convert.py     one mission and its transitive assets as portable data
    script.py      one mission script as portable data
    charisma_cache.py  bodies and clips as portable data
    check.py       the result collector the pipeline --check CLIs share

lcl_decode.py         decode/encode .lcl and .gcl scripts
lcl_parse.py          tokenize and parse LCL into an AST (semantics: docs/20)
lev_parse.py          inspect .lev missions; ASCII maps and PNG renders
lib_extract.py        extract .LIB sprites to PNG
font_render.py        render text with the bitmap fonts; validate font metrics
img_tables.py         verify the .IMG fixed-point tables against their formulas
3dw_parse.py          parse .3DW ASCII scenes
dir3di_parse.py       parse .dir (3DI) ASCII indices
din_parse.py          parse .din binary indices
prototyp_parse.py     decode prototyp.bin geometry; OBJ/PNG export
verify_3d_indices.py  cross-check .3DW / .dir / .din / container addressing,
                      and which scenes the mission headers actually load
visn_decode.py        decode VISN textures to PNG
wine_visn/            harness that runs the ORIGINAL Eng3d.dll under Wine and
                      diffs it against our decoder (723/723 byte-exact)
cho_parse.py          parse Charisma .cho models
cha_parse.py          parse Charisma .cha animations
cho_export.py         pose a Charisma skeleton; OBJ line segments + PNG sheets
charisma_dump.py      generic chunk walker for .cho/.cha exploration
charisma_selftest.py  exercise the .cho/.cha reader paths the corpus never takes
pe_resources.py       dump PE dialog templates and string tables
trace_names.py        recover function names from the compiled-out error macro
combat_tables.py      decode the combat/LOS tables in Incubation.exe (docs/22)
sav_tables.py         verify the save-game layout against the writer/reader chains
sav_parse.py          parse a save game; extract its embedded .lev (docs/11)
blob_runtime.py       headless reference runtime for all 78 blob update kinds
typ_parse.py          parse OBJECT.TYP, the lost exporter's config (docs/30 2.11)
ai_tables.py          decode the AI turn: orders, move map, targeting (docs/23)
brief_parse.py        parse the briefing/info text markup and lay it out (docs/24)
turn_tables.py        decode the turn: rotation, hand-over, refresh, overwatch (docs/25)
interaction_tables.py decode using the world: doors, boxes, levers, pushes,
                      teleporters, mines (docs/26)
campaign_tables.py    decode the campaign: the unit pool, the location map and
                      its unlock graph, the economy, mission end (docs/27)
blob_tables.py        decode effects and sound: the DirectSound buffers, the
                      event -> wave table, the blob pool and its 78 update
                      kinds, the sprite atlas, the object_3d joint buffer, and
                      weapon -> effect (docs/28)
interface_tables.py   decode the replacement-UI contract: LCL layouts/text,
                      battle commands, deploy transfer/hand-over overlay, and
                      map intent boundary
                      (docs/29)
seq_parse.py          verify and print the hard-coded sequence manifest: logical
                      ids, video parts, actors, camera/rate and corpus; the
                      per-arm checks pin each part's directory, stems and camera
                      to aSetSeqPlayerVideoPart itself (docs/41)

info_parse.py         read DATA/Info.lcl as the game-balance tables (docs/21)
charisma_tables.py    extract and check the Charisma name selectors (docs/40 7.2)
presentation_tables.py pin the mission's presentation layer to Incubation.exe (docs/42)
hud_tables.py         verify the battle interface against the game and its art (docs/43)
language_tables.py    pin the engine's language switch chain
pe_exports.py         list the shipped binaries' PE export tables against the
                      committed listings
exports/              those listings, one .lst per original library
verify_untouched.sh   snapshot the game installation and prove nothing under it
                      was added or changed

lcl_runtime.py        run an executable model over the corpus (--check):
turn_runtime.py         the LCL interpreter (docs/20), the turn (docs/25),
combat_runtime.py       combat and visibility (docs/22), interaction (docs/26),
interact_runtime.py     the move map and the AI turn (docs/23), the campaign
movemap_runtime.py      (docs/27)
ai_runtime.py
campaign_runtime.py
remake_convert.py     convert missions and their assets into the remake's cache
                      (docs/92 10.1)
verify_embedded_cache.py  require an Android APK to carry every byte its embedded
                      cache declares (run by make build-android)

movemap_gold.py       native captures through dbgcall -- each needs Wine and a
turn_gold.py            copy of the game, and each --check fails without a
ai_gold.py              capture; see dbgcall/README.md, "The gold tools"
blob_gold.py
presentation_gold.py
hud_probe.py
dbgcall/              call functions inside a live Incubation.exe or
                      iDesigner.exe under Wine (C++ debugger harness)
dbgcall_patches.py    generate dbgcall --poke/--code arguments for Incubation.exe
wine_control/         inc_control.exe: read a running game's memory from outside

agent_client.py       drive a running remake build over its control server:
                      state, screenshot and commands, answered while a command
                      is still running (docs/92 7.16)
```

## Corpus checks

Each format's check is its parser consuming 100% of that format's files, and
every check fails on an empty corpus. These are the acceptance criteria for the
specs in `docs/`; run them after any change under `tools/`:

```bash
make check-formats
```

The `Makefile`'s `check-formats` target is the one list of checks and their
invocations — the game root's argument position varies per tool, so copy an
invocation from there rather than guessing. A few inspection aids have no
corpus check: `3dw_parse.py`, `dir3di_parse.py`, `din_parse.py`,
`pe_resources.py` and `charisma_dump.py`.

## Extracting assets

```bash
python3 tools/lib_extract.py gog_incubation -o tools/out/sprites   # 2296 PNGs
python3 tools/font_render.py font_2 "Incubation" -o tools/out/fonts/sample.png
python3 tools/lib_extract.py gog_incubation/Libs/mouse.LIB --hotspots \
        -o tools/out/hotspots --game-root gog_incubation   # anchor points marked
python3 tools/lev_parse.py   gog_incubation --png -o tools/out/maps
python3 tools/visn_decode.py gog_incubation -o tools/out/textures
python3 tools/lcl_decode.py  gog_incubation -o tools/out/lcl
python3 tools/cho_export.py  --samples gog_incubation                # tools/out/skeletons

# one mesh out of prototyp.bin, as OBJ and as an orthographic PNG
python3 tools/prototyp_parse.py --name CITY.003 \
    --obj tools/out/meshes/city_003.obj \
    --png tools/out/meshes/city_003.png --png-axis xz \
    gog_incubation/WorldSet/World_A00/Objects/prototyp.din
```

## Inspecting a single file

```bash
python3 tools/lev_parse.py gog_incubation/Missions/_C_105.lev
python3 tools/lev_parse.py gog_incubation/Missions/_C_105.lev --map
python3 tools/lev_parse.py gog_incubation/Missions/_C_105.lev --objects
python3 tools/lev_parse.py gog_incubation/Missions/_C_105.lev --json
python3 tools/lcl_decode.py gog_incubation/Missions/_C_105.lcl --stdout
python3 tools/lib_extract.py gog_incubation/Libs/mouse.LIB --json
python3 tools/prototyp_parse.py --list gog_incubation/WorldSet/World_A00/Objects/prototyp.din
python3 tools/prototyp_parse.py --json --name A_50A.3DI \
    gog_incubation/WorldSet/World_A00/Objects/prototyp.din
python3 tools/prototyp_parse.py --opcodes

# a save game, and the .lev image inside it
python3 tools/sav_parse.py gog_incubation/Work/Saves/_0_.sav
python3 tools/sav_parse.py gog_incubation/Work/Saves/_0_.sav --json
python3 tools/sav_parse.py gog_incubation/Work/Saves/_0_.sav --lev tools/out/save0.lev
python3 tools/sav_tables.py --layout
python3 tools/typ_parse.py gog_incubation/Video/Dialog_03/Objects/OBJECT.TYP

# the AI's order and level tables, planner horizons and hit-probability bands
python3 tools/ai_tables.py --orders gog_incubation
python3 tools/ai_tables.py --json   gog_incubation

# a mission briefing: its labels, its objective/tip program, and the wrapped text
python3 tools/brief_parse.py gog_incubation/DATA/TXT/English/Briefing/_C_105.txt
python3 tools/brief_parse.py gog_incubation/DATA/TXT/English/Briefing/_C_105.txt \
        --label A0 --layout 280
python3 tools/brief_parse.py gog_incubation/DATA/TXT/English/Briefing/_C_105.txt --json

# the player rotation, the game modes and the hand-over's switch
python3 tools/turn_tables.py --rotation gog_incubation
python3 tools/turn_tables.py --json     gog_incubation

# the twenty interaction classes, their effects and their corpus counts
python3 tools/interaction_tables.py --classes gog_incubation
python3 tools/interaction_tables.py --json    gog_incubation

# the campaign's unlock graph: which locations open once mission N is next
python3 tools/campaign_tables.py --locations gog_incubation
python3 tools/campaign_tables.py --json      gog_incubation

# every sound the engine names, and the blob and weapon-effect tables
python3 tools/blob_tables.py --waves gog_incubation
python3 tools/blob_tables.py --blobs gog_incubation
python3 tools/blob_tables.py --kinds  gog_incubation
python3 tools/blob_tables.py --joints gog_incubation
python3 tools/blob_tables.py --json  gog_incubation
```

## Bounded Wine runtime probes

[`docs/91-wine-runtime-probes.md`](../docs/91-wine-runtime-probes.md) records
the artifact hashes, direct-save controller path, failed debugger controls and
the first successful native per-tick sample.

`dbgcall_patches.py` generates the arguments that reproduce it. Nothing is
written to disk: the patches go into the running process through
[`dbgcall`](dbgcall/README.md)'s `--code` and `--poke`, each site is checked
against the loaded image before it is replaced, and `--resume` leaves them in
place while the game plays on.

```bash
python3 tools/dbgcall_patches.py gog_incubation --selftest      # 15 checks
python3 tools/dbgcall_patches.py gog_incubation \
    --mode direct-save-6 --trace-blob-kind 15 --plan > kind15.plan
```

The self-test is the reason to trust the generator: it reassembles every stub
at the tail-padding address the earlier patched builds used and requires the
bytes to be identical to what those confirmed builds contained. `--plan`
writes a dbgcall plan file, which is where a set this size belongs;
`--command` prints a whole `wine` line instead, and with no flag the arguments
come out one per line, for `mapfile -t A < <(...)`. Run it from a **copy** of
the game — the direct-save mode expects slot 6 in the TestVersion directory
`Work/Saves2`.

For a graphical `--resume` run, use the virtual-desktop `cmd /c` recipe in
[`docs/91-wine-runtime-probes.md`](../docs/91-wine-runtime-probes.md#51-launch-context-ab-2026-08-27):
passing the long command directly to `explorer` can lose its arguments, while
plain Wine can fail in the display path even after every poke succeeds.

`inc_control.exe PROCESS readmem ADDRESS LENGTH` (built by
`wine_control/build.sh`) reads the trace buffer from outside while the game is
still running.

`Work/Saves/` ships empty, so those four are shown for when a real save exists;
`sav_parse.py` exits non-zero rather than pretending to have checked something.

## Conventions

- Diagnostics go through `logging`; parsed data goes to stdout.
- Parsers raise a typed error (`ParseError`, `LevError`, `LibError`, …) rather
  than returning partial results, so a corpus check cannot pass by silently
  skipping files.
- Fields whose meaning is not established are exposed under a neutral name
  (`unknown_03`) and documented as UNVERIFIED in `docs/` rather than given an
  invented label.

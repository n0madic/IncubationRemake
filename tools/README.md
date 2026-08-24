# Tools

Python 3 parsers and extractors for the Incubation file formats. **No third-party
dependencies** — everything, including PNG writing, is implemented against the
standard library so the tools run anywhere.

The game directory is read-only. All output goes to `tools/out/`.

## Layout

```
inclib/          shared library code
    binio.py       little-endian Reader; the u32-length-prefixed string convention
    png.py         minimal PNG writer (8-bit indexed and 24-bit truecolour)
    palette.py     .pal loader (Windows BMP colour tables)
    liblib.py      .LIB shape-library parser
    lev.py         .lev battle-map parser
    visn.py        VISN texture codec
    prototyp.py    prototyp.bin geometry decoder (command streams, meshes)
    pe.py          PE reader: sections, resources, and reads by virtual address

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
verify_3d_indices.py  cross-check .3DW / .dir / .din / container addressing
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
```

## Corpus checks

Each tool can validate itself against 100% of its format's corpus. These are the
acceptance criteria for the specs in `docs/`; run them after any change.

```bash
python3 tools/lcl_decode.py       gog_incubation -o tools/out/lcl   # 178 files
python3 tools/lcl_parse.py        gog_incubation --check            # 177/177
python3 tools/lev_parse.py        gog_incubation --check            # 155/155
python3 tools/lib_extract.py      gog_incubation --check            #  58/58
python3 tools/img_tables.py       gog_incubation                    #  42/42
python3 tools/font_render.py     --check gog_incubation            #   4/4 fonts
python3 tools/verify_3d_indices.py --root gog_incubation            # 42 x3 + 21 x2
python3 tools/prototyp_parse.py   --check --root gog_incubation      # 26072/26072
python3 tools/visn_decode.py      gog_incubation --check            # 723/723
python3 tools/cho_parse.py        --check gog_incubation            # 237/237
python3 tools/cha_parse.py        --check gog_incubation            # 245/245
python3 tools/cha_parse.py --verify-convention gog_incubation        # quaternion order
python3 tools/combat_tables.py   --check gog_incubation             # 48/48 weapon patterns
python3 tools/trace_names.py     --check gog_incubation             # 324 + 146 names
python3 tools/charisma_selftest.py                                   # synthetic reader paths
```

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
```

## Conventions

- Diagnostics go through `logging`; parsed data goes to stdout.
- Parsers raise a typed error (`ParseError`, `LevError`, `LibError`, …) rather
  than returning partial results, so a corpus check cannot pass by silently
  skipping files.
- Fields whose meaning is not established are exposed under a neutral name
  (`unknown_03`) and documented as UNVERIFIED in `docs/` rather than given an
  invented label.

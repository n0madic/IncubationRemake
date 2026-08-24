# Eng3d scene and index formats: `.3DW`, `.dir`, `.din`, and container addressing

Scope: the four file types owned by the Eng3d 3D engine (`D:\PRO\3DLIB\eng3d\` in the
shipped debug paths) that describe *scenes* and *index containers*:

| Format         | Encoding | Purpose                                                            |
|----------------|----------|--------------------------------------------------------------------|
| `.3DW`         | ASCII    | Scene/world: list of object clones placed in a level                |
| `.dir`         | ASCII    | Human-readable directory of a container (`3DI` magic)               |
| `.din`         | binary   | Machine-readable directory of the same container                    |
| `prototyp.bin` | binary   | Container addressed by `prototyp.dir` / `prototyp.din`              |
| `texture.lib`  | binary   | Container addressed by `texture.dir` / `texture.din`                |

The *payload* format inside `prototyp.bin` records and `texture.lib` blobs is out of
scope here; this document only specifies how the directories address them.

Tools (all in `tools/`, Python 3, sharing `tools/inclib/binio.py`):

* `3dw_parse.py` — strict `.3DW` parser, `--json` output, CLI over files/dirs
* `dir3di_parse.py` — `.dir` parser (both flavours)
* `din_parse.py` — `.din` parser (both flavours)
* `verify_3d_indices.py` — corpus validator, cross-checks and coverage summary

---

## 1. Corpus and coverage

Data root: `gog_incubation/`.

| Type                     | Files | Records                                    |
|--------------------------|-------|--------------------------------------------|
| `.3DW`                   | 42    | 1125 `[CLO]` blocks total                  |
| `prototyp.dir`           | 21    | 26 072 rows total                          |
| `texture.dir`            | 21    | 723 rows total                             |
| `prototyp.din`           | 21    | 26 072 records total                       |
| `texture.din`            | 21    | 723 records total                          |
| `prototyp.bin`           | 21    | —                                          |
| `texture.lib`            | 21    | —                                          |

The 21 directory pairs of each kind are: 9 world sets
(`WorldSet/World_{A..I}00/{Objects,TEXTURES}/`) and 12 cutscene sets
(`Video/{Dialog_02,03,07,09,14,15,16,Extro,Seq_1,3,4,5}/{Objects,Textures}/`).

Note the file-name case differs between trees: `WorldSet` uses `prototyp.*` /
`TEXTURES/texture.*`, `Video` uses `Prototyp.*` / `Textures/Texture.*`. Tools must
match case-insensitively.

### Verifier output (`python3 tools/verify_3d_indices.py`)

```
corpus: 42 .3DW, 42 .dir, 42 .din under gog_incubation
checks:
  OK  3dw.clo_name_eq_prototyp         42/42
  OK  3dw.grp_matches_clo              42/42
  OK  3dw.parse                        42/42
  OK  3dw.proto_dir_present            42/42
  OK  3dw.proto_refs_resolve_anywhere  42/42
  OK  din.orphan                       1/1
  OK  din.paired                       42/42
  OK  din.parse                        42/42
  OK  dir.index_is_row                 42/42
  OK  dir.parse                        42/42
  OK  pair.count_matches               42/42
  OK  pair.kind_matches                42/42
  OK  pair.names_match                 42/42
  OK  prototyp.bin_present             21/21
  OK  prototyp.din_fits_engine_cap     21/21
  OK  prototyp.dir_col4_eq_bin_u32     21/21
  OK  prototyp.first_offset_zero       21/21
  OK  prototyp.offsets_in_range        21/21
  OK  prototyp.offsets_increasing      21/21
  OK  texture.covers_container         21/21
  OK  texture.din_fits_engine_cap      21/21
  OK  texture.din_index_is_row         21/21
  OK  texture.dir_eq_din_offsets       21/21
  OK  texture.entry_magic_visn         21/21
  OK  texture.first_offset_zero        21/21
  OK  texture.lib_present              21/21
  OK  texture.offsets_increasing       21/21
  OK  texture.tiles_container          21/21

2 note(s) about the shipped data (not parser failures):
  gog_incubation/WorldSet/World_A00/Worlds/LEVEL03A.3DW: 27 PROTOTYP names absent from its own world set (resolvable in another world set: True); e.g. ['LEVEL03A.000', 'LEVEL03A.001', 'LEVEL03A.002']
  gog_incubation/WorldSet/World_A00/Worlds/LEVEL03B.3DW: 27 PROTOTYP names absent from its own world set (resolvable in another world set: True); e.g. ['LEVEL03B.000', 'LEVEL03B.001', 'LEVEL03B.002']

all checks passed
```

The two notes are a data finding, not a parser failure — see 2.6.

**Coverage: 42/42 `.3DW`, 42/42 `.dir`, 42/42 `.din` parsed with a strict grammar
(unknown token ⇒ `ParseError`); 21/21 `prototyp.bin` and 21/21 `texture.lib`
addressing models validated.**

---

## 2. `.3DW` — ASCII scene/world file

Location: `gog_incubation/WorldSet/World_*/Worlds/*.3DW` (42 files).
Loaded by the game as `World_%s\Worlds\%s.3dw` (format string in `Incubation.exe`
and `iDesigner.exe`, next to `aBuild3DW` / `aParseLandscapeFile`).

**Line endings: bare `LF` (0x0A), no `CR`.** This differs from `.dir`, which is CRLF.

### 2.1 Grammar

```ebnf
file        = "3DW" LF , coord_system , group , { clone } , "[END3DW]" LF ;
coord_system= "[COORD_SYSTEM]" SP ident LF ;
group       = "[GRP]" SP text LF , { SP name LF } , "ENDGRP" LF ;
clone       = "[CLO]" SP name LF , clone_body , "ENDCLO" LF ;
clone_body  = "PROTOTYP"     SP name       LF
            , "ROTATION"     SP int SP int SP int LF
            , "POSITION"     SP int SP int SP int LF
            , "TYP"          SP ident      LF
            , "EDITORDETAIL" SP int        LF ;
```

Blank lines may appear between top-level blocks and are ignored. Keys inside a
`[CLO]` block appear in the fixed order shown above in all 1125 blocks; the parser
does not depend on the order but does require all five keys to be present.

### 2.2 Annotated example (`WorldSet/World_H00/Worlds/LEVEL08A.3DW`)

```
3DW                                                    <- magic line
[COORD_SYSTEM] X_RIGHT_Z_INFRONT_Y_DOWN                <- handedness declaration
                                                       <- blank separator
[GRP] OBJECTE_D:\GFX\HICOL\WORLD_H\OBJECTS\LEVEL08A.3DW <- group header, see 2.4
 LEVEL08A.000                                          <- member, leading space
 LEVEL08A.001
 LEVEL08A.002
 LEVEL08A.003
ENDGRP

[CLO] LEVEL08A.000                                     <- clone (instance) block
PROTOTYP LEVEL08A.000                                  <- prototype name -> prototyp.dir
ROTATION 0 0 0                                         <- 3 integers
POSITION 8957 -928 9537                                <- 3 integers, world units
TYP OBJECT                                             <- clone class
EDITORDETAIL 0                                         <- editor-only detail level
ENDCLO
...
[END3DW]
```

### 2.3 Field table

| Token                 | Arity | Observed values (42 files / 1125 clones)                      | Confidence |
|-----------------------|-------|---------------------------------------------------------------|------------|
| `3DW`                 | —     | always exactly `3DW`                                          | verified   |
| `[COORD_SYSTEM]`      | 1     | `X_RIGHT_Z_INFRONT_Y_DOWN` in all 42 files                    | verified (value); never parsed, but the frame it names is exactly what the loader converts away from — see 2.5, 2.8 |
| `[GRP]` header        | 1     | `OBJECTE_<DOS path to the authoring .3DW>`, 36 distinct values | see 2.4    |
| `[GRP]` member        | 1     | prototype name; leading single space is the field delimiter   | verified   |
| `ENDGRP`              | 0     | always present exactly once                                   | verified   |
| `[CLO]` name          | 1     | clone name; equals the block's `PROTOTYP` in 1125/1125 cases  | **this is the name the engine actually uses** — see 2.5 |
| `PROTOTYP`            | 1     | prototype name, resolved through `prototyp.dir`               | present in every block but **skipped by the loader** — see 2.5 |
| `ROTATION`            | 3 int | `0 0 0` in 1125/1125 blocks                                   | read positionally; scaled `<< 4` into a 4096-unit circle, so the file unit is a **256-unit circle**. Forwarded to the engine **unswapped**, so the triple is `(about X, about depth axis, about vertical axis)` — the **third** component is the yaw. See 2.5 |
| `POSITION`            | 3 int | full integer range, e.g. `8957 -928 9537`                     | order is `X Y Z` with Y **down**; scaled `<< 4`, and the components are **swapped and Y negated** on load — see 2.5 |
| `TYP`                 | 1     | `OBJECT` in 1125/1125 blocks                                  | **never parsed by the engine or the editor** — see 2.5, 2.8, 2.10 |
| `EDITORDETAIL`        | 1 int | `0` in 1125/1125 blocks                                       | **never parsed — by the engine *or* by the editor**; authoring metadata whose writer never shipped, see 2.5, 2.8, 2.10 |
| `ENDCLO`              | 0     | one per `[CLO]`                                               | verified   |
| `[END3DW]`            | 0     | last non-empty line of every file                             | verified   |

### 2.4 `[GRP]` header value

All 42 files use the shape `OBJECTE_<path>`; 36 distinct values, e.g.

```
OBJECTE_C:\EDITOR\OBJECTS\LEVEL09A.3DW
OBJECTE_D:\GFX\HICOL\WORLD_H\OBJECTS\LEVEL08A.3DW
OBJECTE_E:\BI4\BACKUPS\HICOL\WORLD2\OBJECTS\LEVEL02A.3DW
OBJECTE_V:\ANB\MARKO\WORLDD\OBJECTS\LEVEL04A.3DW
OBJECTE_Q:\GIERTO~1\NEWMAP\MAP2.3DW
```

`OBJECTE` is German plural for "objects", so the value most likely reads
"group name = `OBJECTE`, authored from `<path>`".

**Status: this stays a consumer's choice, and here is why that is safe.** No
shipped binary reads the `[GRP]` line at all (see 2.5 and 2.7 — the sweep in 2.7
now covers UTF-16 as well, so dialog resources are included), so no code can
settle the split. What the data does settle is that a naive "split at the first
`_`" is *always* correct here even though underscores occur inside the paths:

* all 36 distinct values begin with the literal prefix `OBJECTE_` (36/36);
* what follows is always a DOS path beginning `<drive letter>:\` (36/36), so the
  first `_` can never fall inside the path portion.

A parser that wants the two halves can therefore strip the constant prefix
`OBJECTE_`; a parser that does not care should keep the raw string, which is
what `3dw_parse.py` does. A writer may emit anything — the runtime ignores it.

### 2.5 What the engine's loader actually does

The runtime parser is `aParseLandscapeFile` in `Incubation.exe` (identified by
its own trace string `aParseLandscapeFile (tmp)`; the same routine exists in
`iDesigner.exe`). It reads the whole file into memory and walks it with
`strtok`, so **the format is a flat token stream, not a line-oriented one** —
newlines and spaces are interchangeable delimiters.

The loop is:

```
for each token:
    if token == "[END3DW]" : stop after this iteration
    if token == "[CLO]":
        name   = next token                    <- the [CLO] argument
        skip 3 tokens                          <- "PROTOTYP", its value, "ROTATION"
        rot    = (atoi, atoi, atoi)            <- the three ROTATION integers
        skip 1 token                           <- "POSITION"
        pos    = (atoi, atoi, atoi)            <- the three POSITION integers
        place_clone(name,
                    pos[0] << 4,               // -> engine slot 0
                    pos[2] << 4,               // -> engine slot 1   (note: pos[2])
                    pos[1] * -16,              // -> engine slot 2   (note: pos[1], negated)
                    (short)(rot[0] << 4),      // -> engine slot 0   (NOT swapped)
                    (short)(rot[1] << 4),      // -> engine slot 1
                    (short)(rot[2] << 4))      // -> engine slot 2
```

`place_clone` is `FUN_00404f80 @ 0x00404f80` in `Incubation.exe`. It appends a
64-byte record to the engine's *linear clone list* (`DAT_004fa818`, capacity 151):

| offset | contents                                                        |
|--------|-----------------------------------------------------------------|
| `+0x08` | prototype index (from `FUN_004038f0(name)`, i.e. the `[CLO]` argument) |
| `+0x0c` | cull radius, fetched via `E3D_get_prototype_collision_radius`   |
| `+0x10` `+0x14` `+0x18` | position, engine slots 0/1/2                     |
| `+0x1c` | pointer to an external angle array, set to `0` for `.3DW` clones |
| `+0x20` `+0x22` `+0x24` | `int16` angles, engine slots 0/1/2                |

Five consequences a remake must respect:

1. **The prototype is looked up by the `[CLO]` argument, not by the `PROTOTYP`
   line.** The `PROTOTYP` keyword and its value are skipped outright. In all
   1125 shipped blocks the two names are identical, so the difference never
   shows — but a writer that puts the real name only on the `PROTOTYP` line
   would produce a file the engine cannot load.
2. **`TYP` and `EDITORDETAIL` are never read.** The loader jumps straight from
   the last `POSITION` integer back to scanning for the next `[CLO]`. They are
   editor metadata. Likewise `[GRP]`/`ENDGRP` is a redundant table of contents
   the runtime ignores entirely.
3. **Both `POSITION` and `ROTATION` are scaled by 16 on load** (`<< 4`), so file
   units are 1/16 of engine world units. For scale: one battle-map field is 3200
   engine units (see [`10-lev-mission-format.md`](10-lev-mission-format.md) §6.1),
   hence 200 `.3DW` units per field.
4. **`POSITION` is converted between two different coordinate systems.** The
   file is `X_RIGHT_Z_INFRONT_Y_DOWN` (see the `[COORD_SYSTEM]` line); the engine
   works in `X right, Y in front, Z up`. The loader therefore does more than
   negate one axis — it *reorders*:

   ```
   engine.slot0 =  file.X          (right)
   engine.slot1 =  file.Z          (in front / depth)
   engine.slot2 = -file.Y          (up)
   ```

   The earlier wording "negated into an internally Y-up representation" was
   wrong on the second half: the engine's vertical axis is slot **2**, not slot 1.
5. **`ROTATION` is *not* reordered.** All three angles go straight to slots
   0/1/2 in file order. The file's rotation triple is therefore already written
   in **engine axis order**, unlike `POSITION`. See the next block.

Because the rotation components are scaled `<< 4` and then truncated to `short`
before being stored, and the engine's angle unit is a **4096-unit circle** (see
[`70-img-tables.md`](70-img-tables.md)), a `.3DW` rotation value of 256 is a
full turn: the file uses a **256-unit circle**. No shipped file exercises this
— every clone is `0 0 0` — so it is derived from the code alone.

#### Rotation component order — the third component is the yaw

Every shipped clone is `0 0 0`, so this is derived entirely from code. Four
independent lines converge:

1. **The loader's slot mapping (above).** `POSITION`'s `file.Y` (declared
   *down*) lands negated in slot 2, so **slot 2 is the vertical axis**, and
   `ROTATION` is forwarded to the same slots without reordering.

2. **The matrix builders.** The prototype's draw program (an opcode list at
   prototype `+0x32`, dispatched by `FUN_0040508c @ Eng3d.dll:0x0040508c`)
   reaches the clone through the global `0x00414084` and reads its angle array:

   ```asm
   0x00405f1a  mov  ebx, [0x414084]       ; the clone record
   0x00405f20  mov  esi, [ebx + 0x1c]     ; external angle array, or NULL
   0x00405f27  lea  esi, [ebx + 0x20]     ; ... else the inline three int16
   0x00405f2a  add  esi, eax              ; opcode-supplied byte offset
   0x00405f2c  mov  bx, [esi]             ; slot 0  -> ebx
   0x00405f2f  mov  cx, [esi + 2]         ; slot 1  -> ecx
   0x00405f33  mov  dx, [esi + 4]         ; slot 2  -> edx
   0x00405f3c  call 0x00411bf6            ; = E3D_init_matrix_RzRxRy
   ```

   `fcn.00411bf6` is the body of the export `_E3D_init_matrix_RzRxRy`
   (thunk at `0x004020ac`), `fcn.00411a93` the body of `_E3D_init_matrix_RyRxRz`
   (thunk at `0x004020c8`); a nearby opcode at `0x00405f4c` calls the latter with
   the same slot→register mapping. Setting two of the three angles to zero in
   either builder gives:

   | non-zero angle | resulting matrix                    | axis held fixed |
   |----------------|--------------------------------------|-----------------|
   | slot 0         | `[1,0,0; 0,c,-s; 0,s,c]`             | component 0     |
   | slot 1         | `[c,0,-s; 0,1,0; s,0,c]`             | component 1     |
   | slot 2         | `[c,-s,0; s,c,0; 0,0,1]`             | component 2     |

   (these are the *stored* nine values; see below for how they are applied —
   which axis each angle leaves fixed is unaffected by the transpose).
   The three cases are identical in both builders, signs included. So **slot k
   rotates about component k**, independently of which builder a prototype
   selects.

3. **The fast path.** When slots 0 and 1 are both zero the handler at
   `0x00406049` skips the general builder and calls `fcn.00411a59`, which emits
   exactly `[c,-s,0; s,c,0; 0,0,1]` from the slot-2 angle alone — a hand-written
   "rotation about component 2 only" special case.

4. **Unit facing.** `Incubation.exe` turns a unit's 8-way facing code into an
   angle with `FUN_0046a6e0 @ 0x0046a6e0` — a plain `switch` returning
   `{0, 0xc00, 0x800, 0x400, 0x600, 0xe00, 0x200, 0xa00}`, i.e. multiples of
   512 in the 4096-unit circle, 45 degrees apart — and writes it through
   `FUN_004051e0(obj, 0, 0, angle)` (the rotation setter for the unit array;
   call sites inside `FUN_0046e220` and `FUN_004792a0`) — i.e. into **slot 2**,
   with slots 0 and 1 left at zero. Ground units only ever yaw, which pins
   slot 2 as the yaw axis from the gameplay side. The same is visible in the
   `.lev` special-object array: only the third rotation component is ever
   non-zero there, and its values are dominated by multiples of 1024 (90 degree
   steps) — e.g. `_C_116.lev` has 64 special objects, all with
   `rot = (0, 0, k*1024)` bar one.

**Conclusion:** in `ROTATION a b c`, `c` is the **yaw** (rotation about the
vertical axis), `a` is rotation about the world X axis and `b` rotation about
the horizontal depth axis. A remake placing rotated scenery needs `c`.

##### The exact matrix, if you want bit-identical results

`E3D_init_matrix_RzRxRy(a0, a1, a2, dest)` (`fcn.00411bf6`) writes nine `int32`
Q14 values. With `s_k = sin(a_k)`, `c_k = cos(a_k)` (4096-unit circle, `TRIG.IMG`,
peak 16383) the stored order is:

```
M[0] = c1*c2 + s0*s1*s2     M[1] = -c0*s2            M[2] = s0*c1*s2 - s1*c2
M[3] = c1*s2 - s0*s1*c2     M[4] =  c0*c2            M[5] = -s0*c1*c2 - s1*s2
M[6] = c0*s1                M[7] =  s0               M[8] =  c0*c1
```

(every product is `(x*y) >> 14`). The matrix is **applied transposed** —
`_E3D_c_rotate_coordinate` / `fcn.0041123c` computes

```
out[j] = ( sum_i  M[3*i + j] * v[i] ) >> 14
```

Two caveats for a remake:

* **The composition order is prototype data, not a format constant.** Which of
  the two builders runs is decided by the opcode list inside the `prototyp.bin`
  record, so `.3DW` alone does not fix it. Both agree on the single-axis cases
  above, which is what the yaw question needed.
* The opcode also supplies the `add esi, eax` byte offset, so a prototype may
  read a *different* three-angle window out of an external animation array. The
  slot semantics stated here are the loader's, which is offset-independent.

### 2.6 Cross-checks that hold across the corpus

* `[GRP]` member list is byte-identical, in order, to the sequence of `[CLO]` names
  (42/42 files). The group is therefore a redundant table of contents.
* `[CLO] <name>` equals `PROTOTYP <name>` in all 1125 blocks — the corpus contains no
  case of two clones of the same prototype, so *clone name* and *prototype name*
  cannot be distinguished from data alone. The format clearly allows them to differ.
* Every `PROTOTYP` name resolves to a row in some `prototyp.dir` (42/42 files).
  **Finding:** `World_A00/Worlds/LEVEL03A.3DW` and `LEVEL03B.3DW` reference 27
  prototypes each that are *not* in `World_A00/Objects/prototyp.dir` — they are in
  `World_C00/Objects/prototyp.dir`. These two `.3DW` files are stale leftovers
  shipped in the wrong world set; `World_C00/Worlds/` carries the live copies.

### 2.7 Which tokens exist as literals in the binaries

**Method (revised).** The earlier sweep used `strings -n 3`, which sees only
ASCII. Windows dialog templates, menus and string tables live in `.rsrc` as
**UTF-16LE**, so an ASCII-only sweep cannot prove that an editor does not name a
keyword in its UI. The sweep was therefore redone over **all 29 shipped `.exe`
/ `.dll` files**, searching each token in *both* encodings (raw byte search for
the ASCII form and for the `t\0o\0k\0e\0n\0` UTF-16LE form), with no minimum
run length.

Result — the complete `.3DW`-related literal inventory:

| Token | ASCII | UTF-16 | Where |
|---|---|---|---|
| `[CLO]`      | 1 each | none | `Incubation.exe`, `iDesigner.exe` |
| `[END3DW]`   | 1 each | none | `Incubation.exe`, `iDesigner.exe` |
| `.3dw`       | 3 / 2  | none | `World_%s\Worlds\%s.3dw`, the file dialog filter `*.3dw`, and `xxx.3dw` |
| `[COORD_SYSTEM]`, `[GRP]`, `ENDGRP`, `ENDCLO`, `PROTOTYP `, `ROTATION`, `TYP `, `EDITORDETAIL`, `OBJECTE`, `X_RIGHT`, `Y_DOWN`, `INFRONT` | **none** | **none** | — |
| `[DIRECTORY]`, `ENDDIR`, `[END3DI]`, `.dir`, `.DIR` | **none** | **none** | — (see 4.3) |

(`POSITION` does occur, but only inside `glide.dll` / `glide2x.dll` /
`glide3x.dll`, as part of the 3Dfx Glide API — unrelated.)

Three consequences:

* the runtime reads `.3DW` positionally after `[CLO]`, as 2.5 shows from the
  decompiled parser;
* **`iDesigner.exe` is not the `.3DW` authoring tool.** Its 675 UTF-16 resource
  strings are the mission editor's UI (`Save Land`, `Load Land`, `Select World`,
  `Select 3D Graphic Object`, `Group`, …) and contain no `.3DW` keyword.
  `Editor.exe` has essentially no wide strings and no `[CLO]`. The tool that
  wrote these files — the one whose authoring paths appear in `[GRP]` — did not
  ship;
* the keyword inventory in this document is complete **with respect to the
  shipped data and the shipped binaries**; the unshipped authoring tool may
  accept more. A remake's writer should keep the exact line order shown in 2.1.

The `[LOCAL]`, `[REMOTE]`, `[GROUP]`, `[LCL]`, `[END]` literals found nearby in
`Incubation.exe` / `iDesigner.exe` belong to the `.lcl` script format, not to `.3DW`;
they are listed here only to exclude them.

### 2.8 `TYP`, `EDITORDETAIL` and `[COORD_SYSTEM]` — closed as authoring-only

All three ship with exactly one value (`OBJECT`, `0`,
`X_RIGHT_Z_INFRONT_Y_DOWN`), none is read by the loader (2.5), and none exists
as a literal in any shipped binary in either encoding (2.7). There is nothing
left in the shipped product that could discriminate an alternative value.

* **`TYP`.** The engine *does* keep five separate clone arrays, allocated side by
  side by `FUN_004046a0 @ Incubation.exe:0x004046a0` (five `FUN_0044af30`
  tracked-allocation calls) with the debug labels `aInit3DObjects (Objects-CLONELIST)` (`0x3C75` bytes, stride `0x4D`,
  200 slots), `aInitObjects (Land-CLONELIST)` (`0x26EE`, stride `0x42`),
  `aInitObjects (World-CLONELIST)` (`0x25C0`, stride `0x40`, 151 slots),
  `aInitObjects (Symbol-CLONELIST)` (`0x2ABDE`) and
  `aInitObjects (Special-CLONELIST)` (`0x14E2`); a sixth,
  `aInitBlobObjects (Blob-Objects-CLONELIST)`, lives elsewhere. These names look
  like candidate `TYP` values, but they are **allocation trace labels, not a
  keyword table** — they are passed as the third argument of the tracked
  allocator, exactly like `aParseLandscapeFile (tmp)`. `aParseLandscapeFile`
  writes unconditionally into the *World* list via `FUN_00404f80`, and there is
  no dispatch on any string. So `TYP` cannot have selected between them at
  runtime in the shipped build. **Only `OBJECT` is attested; treat any other
  value as unknown, and note the World clone list holds at most 151 entries**
  (`0x96 < count` rejects in `FUN_00404f80`; the largest shipped scene,
  `World_E00/Worlds/LEVEL05A.3DW`, has 60).
* **`EDITORDETAIL`.** `0` in 1125/1125 blocks, skipped by the loader, and — see
  2.10 — skipped by `iDesigner.exe`'s copy of the same loader as well. The name
  reads as an editor display-detail level; nothing shipped can confirm it,
  because the tool that *wrote* `.3DW` files did not ship.
  **Safe to write as `0` and ignore on read.**
* **`[COORD_SYSTEM]`.** Never parsed. Its value is nevertheless load-bearing
  *documentation*: it is what identifies the file frame as Y-down, which is the
  half of the conversion in 2.5 that a remake must reproduce. A remake should
  emit the same string and hard-code the conversion.

### 2.9 The four World D00 `.lev` clone-count mismatches are harmless

The `.lev` mission file stores a scene clone count in block 1 at `+0x290` (see
[`10-lev-mission-format.md`](10-lev-mission-format.md) §6.1). It matches the
number of `[CLO]` blocks in the referenced scene for 150 of the 154 resolvable
pairs; the four exceptions are all in World D00 and all have the larger value in
the `.lev`:

| Mission | Scene | Count in `.lev` | `[CLO]` blocks in the `.3DW` |
|---|---|---|---|
| `_C_116` | `Level04b` | 45 | 17 |
| `_C_117` | `Level04c` | 53 | 17 |
| `_C_118` | `Level04g` | 42 | 13 |
| `_S_007` | `Level04a` | 47 | 16 |

**Nothing is missing from the shipped data, and the engine never reads the
stored count.** Both halves are provable:

* **The shipped World D00 set is internally complete.** `World_D00` contains
  exactly 16 / 17 / 17 / 13 prototypes named `LEVEL04A.*` / `LEVEL04B.*` /
  `LEVEL04C.*` / `LEVEL04G.*` in its `prototyp.dir` and `prototyp.din`, and the
  four `.3DW` files place *all* of them — the name sets are equal, not merely
  subsets. There are no dangling prototype references anywhere in the corpus
  (`3dw.proto_refs_resolve_anywhere` 42/42). The scenes and the container were
  re-exported together, with the geometry merged into fewer, larger chunks; only
  the mission files kept the older number.
* **`+0x290` is write-only.** Block 1 is the 0x2D4-byte global at
  `Incubation.exe:0x004FA528`, saved and restored verbatim; `+0x290` is
  therefore the address `0x004FA7B8`, which is the **live clone counter** that
  `FUN_00404f80` increments while parsing a `.3DW`. The mission loader
  `FUN_00407c70` reads block 1 back into that global — and then, before it can
  matter, calls `FUN_00407640` (`aParseLandscapeFile`). That function calls
  `FUN_00404a90()`, which sets `0x004FA7B8 = 0`, **before it places any clone** —
  the call sits between the file-open/allocate preamble and the `strtok` loop.
  The clone list is then refilled from the `.3DW`, and every consumer
  (`FUN_00403da0(clone_list, 0x004FA7B8, 0x40)` — the render check-in — and
  `FUN_00404ca0`, the by-index accessor) uses the refreshed value.

There is also no way for a mission to reference an individual scene clone: the
clone array is not saved in the `.lev` (only its count was), and the LCL
commands that move geometry (`MoveObjects` / `MoveFireCircles` / `MoveSpores`,
`FUN_0046fc90`) address **map grid cells**, not clone indices.

**What a remake should do: ignore `.lev` block 1 `+0x290` entirely and take the
clone count from the `.3DW`.** The mismatch is a stale editor counter, visible
only to a tool that compares the two files.

### 2.10 The editor reads `.3DW` and cannot write one

`iDesigner.exe` carries its own compiled copy of `aParseLandscapeFile`
(`0x004065f0`, same trace strings `aParseLandscapeFile (tmp)` and
`aOpenExistingFile`, same source file `a3DObjects.cpp`). It is **token-for-token
the same reader** as the game's, verified against raw disassembly rather than
only the decompiler:

* the `strtok` delimiter set is the literal at `0x00476430` — `20 0A 0D 09 00`,
  i.e. space, LF, CR, TAB — confirming that the format is a flat token stream;
* the outer loop compares only two literals, `[END3DW]` (`0x00476424`,
  `strncmp` length 8) and `[CLO]` (`0x0047641c`, length 5);
* inside a `[CLO]` block there are exactly eleven `strtok` calls
  (`0x004067a7`, `…d6`, `…e2`, `…ee`, `0x004067fa`, `0x0040680e`, `0x00406824`,
  `0x0040683a`, `0x00406846`, `0x0040685c`, `0x00406870`) with `atoi` applied to
  the 5th, 6th, 7th, 9th, 10th and 11th — the same *name; skip 3; three ints;
  skip 1; three ints* shape as 2.5, and the same `(X, Z, −Y)` reorder and `<< 4`
  scale on the way into the placement call.

So `TYP` and `EDITORDETAIL` are skipped by the editor for exactly the reason
they are skipped by the game: the reader never looks at them.

**And `iDesigner.exe` contains no `.3DW` writer.** This is a self-checking
negative: emitting the format requires the literals `3DW`, `[COORD_SYSTEM]`,
`[GRP]`, `ENDGRP`, `[CLO]`, `PROTOTYP`, `ROTATION`, `POSITION`, `TYP`,
`EDITORDETAIL`, `ENDCLO` and `[END3DW]`. A sweep of all 35 PE files shipped in
the game directory, in **ASCII and UTF-16LE**, finds `EDITORDETAIL`, `ENDCLO`,
`ENDGRP` and `COORD_SYSTEM` **zero times anywhere**, and finds `[CLO]` /
`[END3DW]` only in `Incubation.exe` and `iDesigner.exe` — precisely the two
literals each one's *reader* compares against, and nowhere else. The editor's
own `.3DW` handling is read-only: it loads `World_%s\Worlds\%s.3dw` when a map
is opened (`0x00406b80`) and never writes one back.

**Consequence for `EDITORDETAIL` (and `TYP`, and `[COORD_SYSTEM]`): the tool
that authored `.3DW` files never shipped.** The `[GRP]` headers name it
indirectly — `OBJECTE_C:\EDITOR\OBJECTS\LEVEL09A.3DW`, `…D:\GFX\HICOL\…` (2.4)
— but that program is not in the product, so the tokens' editor-side semantics
are **unknowable from the shipped data**, not merely untraced. A remake writes
`TYP OBJECT` and `EDITORDETAIL 0` and reads neither.

---

## 3. `.dir` — ASCII directory (`3DI`)

Two flavours share one envelope. **Line endings: CRLF.**

```ebnf
file   = "3DI" CRLF , "[DIRECTORY]" CRLF , { row CRLF } ,
         "ENDDIR" CRLF , "[END3DI]" CRLF ;
row    = name , WS+ , number , { WS+ , number } ;
```

Fields are whitespace separated. In `texture.dir` the name is padded with TABs to a
column; in `prototyp.dir` a single space is used. Split on any run of whitespace.

The flavour is identified by column count (name + 4 numbers = prototyp, name + 5 =
texture) rather than by file name, which makes the parser independent of the
`prototyp`/`Prototyp` casing split.

### 3.1 `prototyp.dir` (21 files, 26 072 rows)

```
3DI
[DIRECTORY]
A_50A.3DI 0 0 8 935
A_FIRE2.3DI 0 1 6 3276
A_50B.3DI 0 2 8 860
CITY.000 0 3 2 128449
...
ENDDIR
[END3DI]
```

| # | Field           | Type | Evidence                                                                                                 | Confidence |
|---|-----------------|------|----------------------------------------------------------------------------------------------------------|------------|
| 0 | `name`          | str  | 7–47 chars; matches `prototyp.din` name 26 072/26 072                                                     | verified   |
| 1 | `type_code`     | int  | `0` in 26 072/26 072 rows                                                                                 | verified value; **build-time only, safe to ignore** — see 3.4 |
| 2 | `index`         | int  | equals the 0-based row position in 21/21 files                                                            | verified   |
| 3 | `class_code`    | int  | 0–11; see 3.3                                                                                             | meaning UNVERIFIED, but **build-time only, safe to ignore** — see 3.4 |
| 4 | `bin_first_u32` | int  | **equals the first little-endian `u32` of the record at that prototype's `prototyp.din` offset inside `prototyp.bin` — 26 072/26 072 records across all 21 containers** | verified relationship; the value is the **bounding / cull radius** (see 5.2) |

### 3.2 `texture.dir` (21 files, 723 rows)

```
3DI
[DIRECTORY]
al040000		2 0 0 31154 869585208
al050000		2 1 31154 31990 869663706
alc-0000		2 2 63144 33246 872585750
...
ENDDIR
[END3DI]
```

| # | Field        | Type | Evidence                                                                              | Confidence |
|---|--------------|------|---------------------------------------------------------------------------------------|------------|
| 0 | `name`       | str  | 4–11 chars, TAB padded; matches `texture.din` name 723/723                            | verified   |
| 1 | `type_code`  | int  | `2` in 723/723 rows                                                                    | verified value; **build-time only, safe to ignore** — see 3.4 |
| 2 | `index`      | int  | equals the 0-based row position in 21/21 files, and equals the `.din` `index` field    | verified   |
| 3 | `offset`     | int  | byte offset into `texture.lib`; equals `.din` offset 723/723                            | verified   |
| 4 | `size`       | int  | byte size in `texture.lib`; equals `.din` size 723/723; entries tile the file exactly   | verified   |
| 5 | `timestamp`  | int  | corpus range 843 058 272 … 887 378 212 = 1996-09-18 … 1998-02-13 UTC                    | **confirmed to be a `time_t` wall-clock stamp** — see 3.5; which event it stamps is UNVERIFIED |

### 3.3 `prototyp.dir` column 3 (`class_code`) — observed clustering

Value distribution over all 26 072 rows, and the same distribution split by tree:

| value | count (all) | WorldSet | Video | Representative names (World_A00)                        |
|-------|-------------|----------|-------|----------------------------------------------------------|
| 0     | 7 248       | 625      | 6 623 | `A_57A.3DI`, `CLS.3DI`, `CHESS1.3DI`; **all** Video rows   |
| 1     | 532         | 532      | 0     | `LEVEL01B.000`, `LEVEL01D.000` — level geometry chunks     |
| 2     | 595         | 595      | 0     | `CITY.000` … — city/landscape geometry chunks              |
| 3     | 4           | 4        | 0     | —                                                         |
| 4     | 72          | 72       | 0     | `A_BLIB.3DI`, `A_MINE.3DI`, `A_SHILD.3DI`, `A_SPLAT1.3DI`  |
| 5     | 51          | 51       | 0     | `L100EX00.3DI`, `L107EX00.3DI` (level-exit markers)        |
| 6     | 27          | 27       | 0     | `A_FIRE1/2/3.3DI`                                          |
| 7     | 57          | 57       | 0     | `L109EX00.3DI`, `A_PANEL.3DI`                              |
| 8     | 363         | 363      | 0     | `A_50A.3DI`, `A_51A.3DI` … (the `A_5xx` family)            |
| 9     | 147         | 147      | 0     | `A_BLUT0..5.3DI` (blood)                                   |
| 10    | 16 974      | 16 974   | 0     | `PR_004_OBERKOERPER`, `PC_023_SPHERE01` (character parts)  |
| 11    | 2           | 2        | 0     | —                                                         |

The clustering by name family is strong, so the column is clearly *some* per-object
classification. **What it means is unknown.** Two things are established negatively:

* it is not stored in the first 64 bytes of the corresponding `prototyp.bin` record
  (checked byte-, `u16`- and `u32`-wise at every offset 0..63 for the first 400
  records of `World_A00`);
* it is a property of the *prototype*, not of the container: for all 9 977 distinct
  prototype names in the corpus, `(class_code, bin_first_u32)` is identical in every
  `prototyp.dir` that lists the name (0 names with conflicting values).

No name is invented for it in the tooling; `dir3di_parse.py` calls it `class_code`
and the docstring marks it unverified.

### 3.4 The `.dir` is unreachable from any shipped binary

`class_code` and `type_code` have no runtime meaning, and this can be shown
rather than assumed. Three independent arguments, any one of which is
sufficient:

1. **No shipped binary can name a `.dir` file.** The substrings `.dir` and
   `.DIR` do not occur in *any* of the 29 shipped `.exe`/`.dll` files, in ASCII
   **or** in UTF-16LE (2.7). Neither do `prototyp.dir`, `texture.dir`,
   `[DIRECTORY]`, `ENDDIR` or `[END3DI]`. There is no filename, no format
   string, and no section keyword — so no code path can open one, and no editor
   dialog mentions one.
2. **The engine's own reader deliberately reads the `.din` instead.** The
   startup path (`_E3D_init_3d_engine`) opens `PROTOTYP.BIN`, `PROTOTYP.DIN`,
   `TEXTURE.DIN`, `TRIG.IMG`, `ATN.IMG` and nothing else (4.3). Its wording
   `ERROR: to many textures in DIR-File` is legacy text left over from an older
   design; the file it is reading at that point is `TEXTURE.DIN`.
3. **The information is not even carried into the binary index.** A
   `prototyp.din` record is `name_len / name / NUL / offset` (4.1). There is no
   field for `type_code` or `class_code`, so even a hypothetical consumer
   reading the `.din` could not see them.

**Verdict: `type_code` and `class_code` are build-time authoring metadata. A
remake can ignore both, and a remake that writes containers can emit `0` for
`type_code` in `prototyp.dir` and `2` in `texture.dir` and anything for
`class_code` — nothing reads them.** The `class_code` clustering documented in
3.3 remains an interesting handle on the asset taxonomy (it correlates exactly
with several `prototyp.bin` payload properties, see
[`31-prototyp-geometry.md`](31-prototyp-geometry.md) §6.2), but it is a
description of the authoring pipeline, not of the runtime.

### 3.5 `texture.dir` column 5 — a real wall-clock timestamp

Read as seconds since the Unix epoch the 723 values land in
**1996-09-18 … 1998-02-13 UTC**. That brackets the game's development (it
shipped in 1997); the handful of entries dated after release is consistent with
a post-release patch build, though nothing here proves that. Four properties of the distribution rule out coincidence:

* **2-second granularity.** 694 of 723 values are even. All 29 odd values sit in
  a single container, `Video/Seq_4/Textures`. Even values are what a FAT
  directory entry gives (DOS stores seconds/2), so 20 of the 21 containers were
  stamped from a FAT filesystem and one from something finer. Numbers that did
  not encode a time would be even about half the time, not 96% of the time.
* **Working-hours clustering.** Bucketing by hour-of-day (UTC): hours
  20:00–23:00 and 01:00–05:00 are completely empty, hour 06:00 holds a single
  entry, and there is a broad peak from 07:00 to 17:00 (62, 82, 112, 28, 19, 56,
  84, 19, 120, 50, 28 entries) tailing off through 18:00–19:00. The one late
  bucket is 18 entries at 00:00 UTC — around 01:00–02:00 CET, i.e. a single
  night session. Blue Byte was on CET/CEST, so this is a working day plus
  overtime. Arbitrary 32-bit numbers would be roughly uniform across all 24
  buckets.
* **Not a write-order stamp.** The values are *not* monotonic with `index` in
  any of the 21 containers, and a single container can span 500 days. So the
  column is a per-entry property carried in from outside, not the moment the
  entry was appended.
* **Per-container, not per-asset.** Of the texture blobs that appear
  byte-identically in more than one container, 55 carry the same stamp
  everywhere and 89 do not — e.g. `boal0000` is the same blob in 10 cutscene
  containers with 10 different stamps, each within that cutscene's own export
  session.

**Conclusion: the column is a `time_t`, almost certainly the modification time
of that container's copy of the source texture at build time.** Which exact
event it records ("source file mtime" vs "export time") cannot be separated
from the data, so that half stays UNVERIFIED. Either way it is build metadata:
the engine never reads the `.dir` (3.4), a remake should ignore the column, and
a remake that writes one can emit any plausible `time_t`.

---

## 4. `.din` — binary directory

Two structurally different layouts share the `.din` extension. Distinguish them by
the first four bytes (`DBIN` ⇒ texture flavour, otherwise prototyp flavour). All
integers are little-endian.

### 4.1 `prototyp.din` — headerless, variable-length records

```
struct PrototypDinRecord {          // repeated until EOF, no header, no count
    uint32 name_len;                // does NOT include the terminator
    char   name[name_len];          // ASCII, no embedded NUL
    uint8  terminator;              // always 0x00
    uint32 offset;                  // byte offset into prototyp.bin
};
```

Worked example, `World_A00/Objects/prototyp.din` first 0x14 bytes:

```
09 00 00 00  41 5F 35 30 41 2E 33 44 49  00  00 00 00 00   0B 00 00 00 ...
^^ len=9     ^^ "A_50A.3DI" (9 bytes)    ^^ ^^ offset=0     ^^ next len=11
                                         NUL
```

**The trailing NUL is *not* counted in `name_len`.** Evidence: parsing
`name_len` + `name_len` bytes + 1 NUL + `u32` repeatedly lands exactly on EOF for
all 21 files (26 072 records, 0 bytes left over) and the byte at the terminator
position is `0x00` in all 26 072 records. Counting the NUL inside the length would
desynchronise on the very first record.

`Reader.lpstring()` from `inclib.binio` is deliberately *not* used here because it
does not consume the terminator; `din_parse.py` reads `u32` + `take(n)` + an explicit
NUL check, which doubles as per-record validation.

Observed name lengths: 7 … 47 characters.

**Compiled limits (`Eng3d.dll` `fcn.00401054`, the `PROTOTYP.DIN` reader called
from `_E3D_init_3d_engine`):**

| Limit | Value | Where |
|---|---|---|
| maximum `name_len` | **65535** (`0xFFFF`, inclusive) | scratch buffer `Win_Alloc(0xFFFF)` at `0x0040106e`; guard `cmp eax,0xFFFF / jbe` at `0x00401316`, whose failure branch emits `… Maximal namelength exceeded!` (`0x0040133f`) |
| maximum record count | **2499** | `cmp edi, 0x9C4 / jl` at `0x00401453`; `>= 2500` emits `3DENGINE STARTUP: Error: too many prototypes` |

So the `Maximal namelength exceeded!` guard is not a tight field width — it is
just the size of the name scratch buffer. The per-record storage is
`Win_Alloc(name_len + 1)` at `0x004016a0`, i.e. the name is kept NUL-terminated
on the heap, one allocation per record. **Names are effectively unbounded for a
remake's purposes** (longest shipped: 47).

The record-count cap is much closer to the shipped data: the largest container,
`World_E00`/`World_F00`, holds 2294 records against a limit of 2499.

The reader is a **two-pass** scan: pass 1 (`0x0040128e`…`0x00401448`) walks the
whole file counting records, using only `name_len` to skip forward — which is an
independent confirmation of the record layout above, including that the
terminator is *not* counted in `name_len` (pass 1 skips `name_len` bytes and
then exactly `5` more: `0x004013de`). Pass 2 (`0x004014c1`…) re-reads and stores.

### 4.2 `texture.din` — `DBIN` header, fixed 25-byte records

```
struct TextureDinHeader {           // 8 bytes
    char   magic[4];                // "DBIN"
    uint32 count;                   // number of records
};
struct TextureDinRecord {           // 25 bytes, count of them
    uint32 index;                   // 0-based, equals the row position
    char   name[13];                // NUL padded
    uint32 offset;                  // byte offset into texture.lib
    uint32 size;                    // byte size in texture.lib
};
```

Worked example, `World_A00/TEXTURES/texture.din`:

```
44 42 49 4E              "DBIN"
3D 00 00 00              count = 61
00 00 00 00              index = 0
61 6C 30 34 30 30 30 30 00 00 00 00 00   "al040000" + 5 NUL   (13 bytes)
00 00 00 00              offset = 0
B2 79 00 00              size   = 31154
01 00 00 00              index = 1
61 6C 30 35 30 30 30 30 00 00 00 00 00   "al050000"
B2 79 00 00              offset = 31154
F6 7C 00 00              size   = 31990
...
```

The index-first vs index-last ambiguity is resolved by the file size:
`World_A00/TEXTURES/texture.din` is 1533 bytes = `8 + 61*25`. An index-last layout
would require a 12-byte header and give 1537. The identity
`file_size == 8 + 25*count` is asserted by `din_parse.py` and holds for 21/21 files,
which validates the whole record hypothesis corpus-wide.

**The layout is also read straight off the engine's reader**, `Eng3d.dll`
`fcn.00401ae0` (called from `_E3D_init_3d_engine @ 0x00401efb`):

```
0x00401b72  read u32          -> must equal 'DBIN'   (0x00401b8e, else "wrong filetype")
0x00401bf4  read u32 count    -> global 0x00484a5c
0x00401c13  if count > 300    -> "Internal Error: not enough textureslots!"
  per record:
0x00401c5c  read u32 index
0x00401c84  slot = 0x00415b4c + (index << 5)          // 32-byte slot, INDEXED BY index
0x00401c8d  read 13 bytes     -> slot + 0x13          // the name, verbatim
0x00401ca5  read u32          -> slot + 0x04          // offset
0x00401cd6  read u32          -> slot + 0x08          // size
            slot+0x00 = 0; slot+0x0c = 0; slot+0x10 = 0xFFFF; slot+0x12 = 0
```

This confirms the field order and sizes directly, and adds three facts:

* **`index` is a genuine key, not decoration.** It is used as the slot number
  (`index << 5`), so a `.din` may in principle carry records out of order or with
  gaps. In the shipped data it always equals the row position (723/723).
* **Compiled cap: 300 textures per container** (`cmp esi/ebx, 0x12C / jle`, at
  both `0x00401c13` and `0x00401a0a`, the latter emitting the legacy-worded
  `3DENGINE STARTUP: ERROR: to many textures in DIR-File`). The slot table at
  `0x00415b4c` is exactly `300 * 32 = 0x2580` bytes and ends precisely where the
  prototype table `0x004180cc` begins. Largest shipped container: 62 textures.
* **The name field is 13 bytes with no room for a guaranteed terminator.** The
  slot stride is 32 and the name occupies `+0x13 … +0x1F`. Lookup
  (`_E3D_get_texture_index_of_texture_name` → `fcn.00401948`) compares with
  `Win_strcmp(slot + 0x13, wanted)`, i.e. **NUL-terminated**. A 13-character name
  is therefore only terminated by the *next* slot's first byte, which the reader
  happens to zero (`slot+0x00 = 0`). It works in this engine but only by
  accident of adjacency.

  **Practical answer: treat the field as 12 characters plus a mandatory NUL.**
  Shorter names must be NUL-padded (the reader copies the raw 13 bytes and never
  terminates them itself). Longest shipped name is 11 characters, so all 723
  records have at least two NULs; `din_parse.py` requires `name[12] == 0`, which
  is the conservative reading and holds for 723/723.

`DBIN` also appears as an immediate constant in `Eng3d.dll` / `ENG3DFX.DLL` next to
the `TEXTURE.DIN` filename and the message
`3DENGINE STARTUP: Error: wrong filetype` — i.e. the engine checks this magic.

### 4.3 `.dir` vs `.din` consistency

For all 42 pairs: identical record count, identical names, identical order
(`pair.count_matches`, `pair.names_match` 42/42). For texture pairs the `offset` and
`size` values are identical too (723/723). For prototyp pairs the `.dir` carries no
offset at all — the offset only exists in the `.din`.

Consequence for a remake: **the `.din` is the authoritative index**; the `.dir` is a
build-time report. This is corroborated by the binaries: `Eng3d.dll` / `ENG3DFX.DLL`
contain only the literals `PROTOTYP.BIN`, `PROTOTYP.DIN`, `TEXTURE.DIN` (plus
`TRIG.IMG`, `ATN.IMG`). Neither DLL contains `PROTOTYP.DIR`, `TEXTURE.DIR`,
`[DIRECTORY]`, `ENDDIR` or `[END3DI]`. The engine's error message
`3DENGINE STARTUP: ERROR: to many textures in DIR-File` is legacy wording — the file
it is reading at that point is `TEXTURE.DIN`. `texture.lib` itself is opened by
`Incubation.exe` (string `texture.lib` next to `Win_Read_File`), not by the engine
DLL.

---

## 5. Container addressing

### 5.1 `texture.lib`

* No global header. The file is a bare concatenation of blobs.
* Entry *i* occupies `[offset_i, offset_i + size_i)`.
* Offsets are strictly increasing and the entries **tile the file with no gaps and
  no padding**: `offset_{i+1} == offset_i + size_i` for all entries, `offset_0 == 0`,
  and `offset_last + size_last == filesize` — 21/21 containers.
* Every entry starts with the ASCII magic `VISN` — 21/21 containers, all 723 entries
  probed. The `VISN` bytes at file offset 0 are therefore entry 0's own magic, not a
  container header. (`VISN` is also present as an immediate in `Eng3d.dll` /
  `ENG3DFX.DLL`.)
* All offsets are even (723/723).

Entry directory for `texture.lib` = the `.din` record list: `(name, offset, size)`
with `index` == position. Look-up is by name; the engine exposes
`E3D_pre_load_texture_by_name`.

### 5.2 `prototyp.bin`

* No global header: record 0 starts at byte 0 (21/21 containers).
* Only *offsets* are stored, never sizes. Record *i* implicitly runs to `offset_{i+1}`
  (and the last record to EOF). Offsets are strictly increasing in 21/21 containers
  and every offset is inside the container.
* All offsets are even (26 072/26 072).
* The last record's implied length (`filesize - offset_last`) ranges 348 … 2714 bytes
  across the 21 containers, i.e. plausible record sizes — there is no evidence of a
  trailer after the last record, but **this is not proven**; confirming it requires
  the payload decoder.
* **`prototyp.dir` column 4 == the first little-endian `u32` of the record**, verified
  for 26 072/26 072 records in 21/21 containers. This is the strongest available
  handle for validating a `prototyp.bin` decoder.

**That first `u32` is the bounding / cull radius.** The first eight `u32`s of
`A_50A.3DI` (offset 0, 708 bytes long) are:

```
935  -390  390  -737  519  -577  254  0
```

i.e. the radius followed by three `(min, max)` pairs — an axis-aligned bounding
box. The box reading is confirmed by `_E3D_get_part_info` (`Eng3d.dll`
`0x004063d8`), which hands out `(+0x04, +0x0c, +0x14)` as one vector and
`(+0x08, +0x10, +0x18)` as the other. The radius reading is confirmed by
`Eng3d.dll:0x00404BE9` (the view-box cull in `E3D_object_3d_check_in`, which
expands the clone's position by `*prototype` in all six directions) and
`0x00405118`. An earlier objection — that `935` does not reconcile with the box
corners — was based on a wrong model: it is a sphere radius over the
**vertices**, not over the box. See
[`31-prototyp-geometry.md`](31-prototyp-geometry.md) for the corpus check.

Note that `_E3D_get_prototype_collision_radius` (`0x004063cd`) reads a
*different* field, at `+0x26` of the record header, which happens to hold the
same value in all 26 072 shipped records — which is why the two looked like one
field. `Incubation.exe`'s `FUN_00404f80` caches that one into the clone record
at `+0x0c` when a `.3DW` clone is created.

Decoding the rest of the record belongs to the `prototyp.bin` payload track.

---

## 6. Section / keyword inventory

### Found in the shipped data

| Format  | Tokens                                                                                          |
|---------|--------------------------------------------------------------------------------------------------|
| `.3DW`  | `3DW`, `[COORD_SYSTEM]`, `[GRP]`, `ENDGRP`, `[CLO]`, `PROTOTYP`, `ROTATION`, `POSITION`, `TYP`, `EDITORDETAIL`, `ENDCLO`, `[END3DW]` |
| `.3DW` values | `X_RIGHT_Z_INFRONT_Y_DOWN` (coord system), `OBJECT` (TYP), `OBJECTE_<path>` (group header) |
| `.dir`  | `3DI`, `[DIRECTORY]`, `ENDDIR`, `[END3DI]`                                                       |
| `.din`  | `DBIN` (texture flavour only)                                                                     |
| containers | `VISN` (per `texture.lib` entry)                                                              |

A first-token census over all 42 `.3DW` files finds *exactly* these 12 tokens and
nothing else, so the data-side inventory is complete.

### Found in the binaries

| Literal                     | Where                                              |
|-----------------------------|----------------------------------------------------|
| `[CLO]`, `[END3DW]`         | `Incubation.exe`, `iDesigner.exe` only — absent from `Editor.exe` and from all engine DLLs |
| `World_%s\Worlds\%s.3dw`    | `Incubation.exe`, `iDesigner.exe`                  |
| `aBuild3DW`, `aParseLandscapeFile (tmp)`, `aInsertWorldObject`, `aWriteUnitInto3DWorld`, `parseerror` | `Incubation.exe`, `iDesigner.exe` |
| `PROTOTYP.BIN`, `PROTOTYP.DIN`, `TEXTURE.DIN`, `TRIG.IMG`, `ATN.IMG` | `Eng3d.dll`, `ENG3DFX.DLL` |
| `DBIN`, `VISN` (immediates) | `Eng3d.dll`, `ENG3DFX.DLL`                          |
| `texture.lib`               | `Incubation.exe`                                    |
| `3DENGINE STARTUP: ERROR: to many textures in DIR-File`, `… Error: wrong filetype`, `… Error: too many prototypes`, `… Maximal namelength exceeded!` | `Eng3d.dll`, `ENG3DFX.DLL` |
| `.3DI`, `%c%03d%c%s.3DI`, `L%03dEX00.3DI` | `Incubation.exe`, `iDesigner.exe`     |

**No additional section keywords for these four formats exist in any shipped
binary.** In particular the binaries contain *no* literal — **ASCII or UTF-16LE**
— for `[DIRECTORY]`, `ENDDIR`, `[END3DI]`, `.dir`, `.DIR`, `[GRP]`,
`[COORD_SYSTEM]`, `ENDGRP`, `ENDCLO`, `PROTOTYP`, `ROTATION`, `TYP`, `EDITORDETAIL`,
`OBJECTE`, `X_RIGHT`, `Y_DOWN` or `INFRONT`. This is the basis for the claims in
2.5, 2.7, 2.8, 3.4 and 4.3 that the runtime reads `.3DW` positionally after
`[CLO]` and ignores the ASCII `.dir` entirely.
(`POSITION` occurs only inside the three Glide DLLs, as part of the 3Dfx API.)

Extraction (binaries are read-only inputs, outputs went to a scratch directory):

* ASCII pass — `strings -n 3 gog_incubation/<binary>`;
* UTF-16LE pass — a raw byte search for `(?:[\x20-\x7e]\x00){3,}`, because
  `strings` on macOS has no `-el` and Windows resource strings (dialog captions,
  menus, string tables) are UTF-16LE and invisible to an ASCII-only scan;
* token pass — a direct byte search for each token in both encodings, with no
  minimum run length, over **all 29 shipped `.exe` and `.dll` files**, not just
  the ten listed above. That is what makes the negative results above complete
  rather than merely "not found in the files we looked at".

---

## 7. Tool usage

```sh
# Parse one world, structured JSON
python3 tools/3dw_parse.py --json gog_incubation/WorldSet/World_H00/Worlds/LEVEL08A.3DW

# Summarise every world
python3 tools/3dw_parse.py gog_incubation/WorldSet

# Directories
python3 tools/dir3di_parse.py --json gog_incubation/WorldSet/World_A00/TEXTURES/texture.dir
python3 tools/din_parse.py    --json gog_incubation/WorldSet/World_A00/TEXTURES/texture.din

# Full corpus validation (exit code 0 == all checks passed)
python3 tools/verify_3d_indices.py --root gog_incubation
```

All parsers raise `inclib.binio.ParseError` on any deviation from the layouts above;
the `.3DW` parser is strict by default (`--lenient` downgrades unknown tokens to
warnings).

---

## 8. Open questions / unverified

Everything that was closed since the last revision is now folded into the body,
with the addresses that prove it. What is listed here is what is genuinely still
open.

1. **`prototyp.dir` column 3 (`class_code`) — the *meaning* of the 12 values.**
   Its runtime relevance is closed (there is none — see 3.4, it is build-time
   metadata a remake can ignore), and its correlation with the payload is
   documented in [`31-prototyp-geometry.md`](31-prototyp-geometry.md) §6.2. What
   the numbers 0…11 *named* in the authoring pipeline is unknown and cannot be
   recovered from the shipped product: the tool that assigned them did not ship,
   and the value never reaches a binary. Distribution in 3.3. No name invented.

2. **`type_code` — likewise.** `0` for prototyp, `2` for texture, constant
   corpus-wide, unreachable from any binary (3.4). The `0`/`2` split across the
   two flavours is the only hint that it is a kind discriminator; nothing
   confirms it.

3. **`texture.dir` column 5 — which event the timestamp records.** That it *is*
   a `time_t` is now established (3.5: 2-second granularity, working-hours
   distribution, per-container rather than per-asset). Whether it is the source
   file's mtime or the moment of export cannot be separated from the data.

4. ~~**`EDITORDETAIL` — its editor-side meaning.**~~ **Closed as unknowable —
   see 2.10.** `iDesigner.exe` turned out to *read* `.3DW` with a token-for-token
   copy of the game's parser, which skips `EDITORDETAIL` for the same reason the
   game does, and it contains no writer: `EDITORDETAIL`, `ENDCLO`, `ENDGRP` and
   `COORD_SYSTEM` occur **zero times in all 35 shipped PE files in both ASCII
   and UTF-16LE**, while `[CLO]` / `[END3DW]` occur only as the two literals the
   readers compare. The `.3DW` authoring tool did not ship, so the token's
   editor-side meaning is not recoverable from the product rather than merely
   untraced. A remake writes `0`.

5. **`TYP` — whether values other than `OBJECT` were ever accepted.** The
   loader never reads the token and no other value ships or appears as a literal
   (2.8). The five `*-CLONELIST` names are allocation trace labels, not a
   keyword table, so they are *not* evidence of other `TYP` values. Unknowable
   from the shipped product.

6. **`[COORD_SYSTEM]` alternatives.** One value ships, the engine never parses
   the line, no alternative identifier exists in any binary (2.8). Unknowable.

7. **`ROTATION` — the composition order for a general three-axis rotation.**
   Which component is the yaw is closed (2.5: the third). But *which* matrix
   builder runs — `E3D_init_matrix_RzRxRy` (`fcn.00411bf6`) or
   `E3D_init_matrix_RyRxRz` (`fcn.00411a93`) — is selected by the opcode list
   inside the `prototyp.bin` record, not by the `.3DW`, and every shipped clone
   is `0 0 0`. Both builders agree on every single-axis case, so this only
   matters for a scene that rotates about two or three axes at once — which no
   shipped scene does. Settling it belongs to the `prototyp.bin` payload track.

8. **`texture.din` name field — 13 chars without a terminator.** Resolved
   *practically* (4.2: treat it as 12 + NUL, because lookup uses `strcmp` and a
   13-character name is only terminated by the neighbouring slot's zero byte).
   Whether the original tool would ever emit 13 characters is unknown; longest
   shipped name is 11.

9. ~~**Trailer after the last `prototyp.bin` record.**~~ **— CLOSED: there is
   no trailer.** The payload decoder now exists and settles it. Every record's
   part-info stream ends **exactly at the record's last byte in all 26 072
   records**, including the last record of each of the 21 containers, so the
   final record does reach EOF with nothing after it. See
   [`31-prototyp-geometry.md`](31-prototyp-geometry.md) §3.2.

10. **Stale worlds.** `World_A00/Worlds/LEVEL03A.3DW` and `LEVEL03B.3DW`
    reference prototypes that live in `World_C00`. Reported by the verifier as a
    note, not a failure (2.6). Whether the shipping game ever loads them is a
    question for the `.lev`/campaign track. Note this is a *different* defect
    from the World D00 count mismatch, which is closed in 2.9.

### Closed since the previous revision

| Was | Now |
|---|---|
| `ROTATION` component order | **Closed** — the third component is the yaw; 2.5 |
| `POSITION` axis handling | **Corrected** — the loader *reorders*, it does not merely negate; 2.5 |
| `prototyp.dir` col 4 | **Closed** — bounding/cull radius; 5.2 and `31-…` |
| Is the `.dir` read at runtime? | **Closed** — no, by three independent arguments; 3.4 |
| `texture.dir` last column | **Closed as a `time_t`**; 3.5 |
| `Maximal namelength exceeded!` cap | **Closed** — 65535, the size of the name scratch buffer; 4.1 |
| `prototyp.din` record-count cap | **Found** — 2499 (shipped max 2294); 4.1 |
| `texture.din` record layout | **Confirmed from the reader**, not just from the file size; 4.2 |
| `texture.din` capacity caps | **Found** — 300 textures per container (shipped max 62); 4.2 |
| `[GRP]` header split | **Closed as a consumer's choice**, with a rule that is safe on 36/36; 2.4 |
| `TYP` / `EDITORDETAIL` / `[COORD_SYSTEM]` runtime effect | **Closed** — none, proven over all 29 binaries in both encodings; 2.7, 2.8 |
| `EDITORDETAIL`'s editor-side meaning | **Closed as unknowable** — the editor reads `.3DW` and cannot write one; the authoring tool never shipped; 2.10 |
| Four World D00 `.lev` count mismatches | **Closed as harmless** — nothing is missing and the count is never read; 2.9 |

# `prototyp.bin` — the Eng3d geometry payload

Scope: the record format inside `prototyp.bin`, the container addressed by
`prototyp.dir` / `prototyp.din` (addressing itself is specified in
`docs/30-eng3d-ascii-formats.md`). This is the file that holds the actual
vertices, polygons, texture coordinates and collision data for every character
part, every prop and every piece of level scenery in the game.

**Method: the layout below was read out of `Eng3d.dll` (Ghidra decompilation
cross-checked with radare2 disassembly), not inferred from byte patterns.**
Every field table cites the virtual address of the instruction that reads it
(image base `0x400000`). The corpus numbers then come from running the parser
over 100 % of the shipped data.

The rasteriser semantics in §4.4 are read out of **both** shipped builds of the
renderer — `Eng3d.dll` (software) and `ENG3DFX.DLL` (Glide / 3dfx) — which have
the same table structure and can be cross-checked against each other. Glide
argument order and enum values were taken from a real Glide 2.x `glide.h`
(`GR_COMBINE_*`, `GR_BLEND_*`, `GR_COLORCOMBINE_*`), not from memory.

Tools:

* `tools/inclib/prototyp.py` — reusable decoder (`load_container`, `parse_record`,
  `to_obj`, `render_png`)
* `tools/prototyp_parse.py` — CLI: `--check` (corpus mode), `--list`, `--json`,
  `--obj`, `--png`, `--opcodes`

---

## 1. Coverage

```
$ python3 tools/prototyp_parse.py --check --root gog_incubation
corpus: 21 prototyp.bin containers under gog_incubation
records parsed:              26072/26072
byte-exact record coverage:  26069/26072 (120 bytes unaccounted in total)
records with overlaps:       0
face vertex indices in range:26072/26072
face plane indices in range: 26072/26072
header bbox == vertex bbox:  1881/26072 exact, 26072/26072 within +/-2 units
face-tree back-pointer ok:   26072 (mismatch 0)
collision stream reuses the render vertex/plane blocks: 52498 ok, 0 mismatched
header bbox contains verts:  26072/26072
height == -bbox_min[2]:      26072/26072
collision_radius==cull_radius   26072/26072
depth_bias non-zero:         532/26072
texture ids within texture.din count: 236861/236861
unexplained bytes inside faces: 0
totals: 317331 vertices, 236861 faces, coordinate range [-5537103, 5537104], max texture id 59
...
NOTE: records with unreferenced slack bytes (3):
  WorldSet/World_E00/Objects/prototyp.din[1846] L068EE00.3DI: 48 bytes
  WorldSet/World_F00/Objects/prototyp.din[1838] L068EF00.3DI: 48 bytes
  WorldSet/World_G00/Objects/prototyp.din[2103] L026EG00.3DI: 24 bytes

all checks passed
```

**26 072 / 26 072 records in 21 / 21 containers decode.** Byte accounting is
exact — every byte of a record is claimed by exactly one structure — for
26 069 records. The three exceptions carry 24 or 48 bytes of unreferenced slack
*inside* a vertex block (the block's `u16` count is smaller than the data that
follows it); nothing else in the record points at those bytes. This is an
exporter artifact, not an undecoded structure — see §1.1.

### 1.1 The three records with slack bytes

Decoding the slack as `i32` triples, exactly as the vertex block that precedes
it, produces well-formed vertices in the same coordinate quantisation as the
record's real ones, and they are *geometrically coherent*:

```
L068EE00.3DI  offset 0x1e4, 48 bytes = 4 vertices
  ( 160, -1280,  1440)   ( 160, -1280, -4800)
  (-160, -1280, -4800)   (-160, -1280,  1440)     -> a planar rectangle, y = -1280

L068EF00.3DI  identical record, identical slack

L026EG00.3DI  offset 0x210, 24 bytes = 2 vertices
  ( 1760, -3040, 160)    (-1760, -3040, 160)      -> a single edge
```

Four coplanar corners of a rectangle and a symmetric vertex pair are not random
padding. The reading that the exporter **decremented the block's `u16` count
after deleting a polygon, without rewriting the block**, is therefore supported
by the data itself, not just by the absence of a pointer. Nothing in the record,
in `prototyp.dir`/`.din`, or in any engine code path reaches those bytes.

Cross-format validation:

* Every `.cho` model mesh name resolves to a decoded record and the mesh sizes
  are physically sensible: `*_HAND_*` 6–8 vertices, `*_FUSS_*` (foot) 6–16,
  `*_OBERKOERPER` (torso) 16, `*_KOPF` (head) 12–56, level chunks up to 417.
  8 548 of 8 617 distinct mesh names resolve (`docs/40` reports 8 509 — the
  difference is only the counting method: this check matches case-insensitively
  and first-wins across all 21 containers).
* Every face's texture id is `< count` of the sibling `texture.din`
  (236 861 / 236 861 faces).

---

## 2. Record layout

A record is a fixed 0x32-byte header followed by three self-relative **command
streams** plus the data blocks those commands point at. The engine reads
`prototyp.bin` into one allocation (`Win_Read_File` inside `FUN_00401054`) and
stores `base + din_offset` per prototype into the table at `0x4180cc`
(`add eax,ecx` at `0x401690`, stored by `FUN_00401010` @ `0x401049`). **Nothing is relocated or fixed up** — every
internal pointer is a self-relative `i32`, so a decoder can work on the raw
bytes.

### 2.1 Header

All values little-endian. Note `0x22`, `0x26`, `0x2a`, `0x2e` are *not*
4-aligned; x86 does not care.

| Offset | Type  | Name               | Read by                                                  | Confidence |
|--------|-------|--------------------|----------------------------------------------------------|------------|
| `0x00` | `i32` | `cull_radius`      | `0x404be9` (view-box cull), `0x405118` (scratch-buffer choice against 24 000 / 80 000) | verified   |
| `0x04` | `i32` | `bbox_min[0]`      | `0x4063e2`                                                | verified   |
| `0x08` | `i32` | `bbox_max[0]`      | `0x4063f3`                                                | verified   |
| `0x0c` | `i32` | `bbox_min[1]`      | `0x4063e5`                                                | verified   |
| `0x10` | `i32` | `bbox_max[1]`      | `0x4063f6`                                                | verified   |
| `0x14` | `i32` | `bbox_min[2]`      | `0x4063e8`                                                | verified   |
| `0x18` | `i32` | `bbox_max[2]`      | `0x4063f9`                                                | verified   |
| `0x1c` | `i32` | `depth_bias`       | `0x404e1c`, added to the camera-space depth before the object sort key is squared (see 2.5) | verified |
| `0x20` | `u16` | `flags`            | `0x404e4b` (bit 0), `0x404e91` (bit 1), `0x40665e` (bit 2) | verified (see 2.2) |
| `0x22` | `i32` | `height`           | `0x4063c9`, returned by `_E3D_get_clone_height`            | verified   |
| `0x26` | `i32` | `collision_radius` | `0x4063d4`, returned by `_E3D_get_prototype_collision_radius` | verified |
| `0x2a` | `i32` | `collision_program`| `0x4067ac`: `lea esi,[esi+0x2a]`, `cmp dword [esi],0`, `add esi,[esi]` | verified |
| `0x2e` | `i32` | `partinfo_program` | `0x406399`: `add esi,0x2e`, `add esi,[esi]` (`_E3D_get_part_info`) | verified |
| `0x32` | —     | render program     | `0x405144`: `add esi,0x32` (`FUN_0040508c`, the draw loop) | verified   |

`0x2a` and `0x2e` are self-relative: the target is `0x2a + value` /
`0x2e + value`. `0x2a == 0` means **this prototype has no collision geometry**;
the collision routine bails out at `0x4067b2`.

Worked example, `World_A00/Objects/prototyp.bin` record 0 = `A_50A.3DI`,
708 bytes at offset 0:

```
0x00  935          cull_radius            (== prototyp.dir column 4)
0x04  -390   390   bbox x
0x0c  -737   519   bbox y
0x14  -577   254   bbox z
0x1c  0            depth_bias
0x20  0x0000       flags
0x22  577          height                 (== -bbox_min[2])
0x26  935          collision_radius
0x2a  628  -> 0x29e   collision program
0x2e  648  -> 0x2b6   part-info program
0x32  render program
```

### 2.2 `flags` (`u16` @ `0x20`)

| Bit | Meaning                                                                  | Read at    | Shipped counts |
|-----|--------------------------------------------------------------------------|------------|----------------|
| 0   | queue the clone in the second draw list (`0x414034` instead of `0x41403c`) | `0x404e4b`, and `0x404c79` in `_E3D_object_3d_check_in` itself | 2 records      |
| 1   | after check-in, also walk the clone's runtime sub-object list (`clone+0x70`) | `0x404e91` | 23 597 records |
| 2   | use the alternate bounding-box test in the collision entry                | `0x40665e` | 2 records      |

Observed values: `0` (2 473), `2` (23 597), `5` (2). No other bit is ever set.

### 2.3 Scalars, cross-checked against the decoded geometry

| Relation                                          | Holds for       |
|---------------------------------------------------|-----------------|
| header bbox **contains** the decoded vertex bbox   | 26 072 / 26 072 |
| header bbox equals it exactly                      | 1 881           |
| header bbox differs by at most 1 unit per side     | 19 866          |
| header bbox differs by at most 2 units per side    | 26 072          |
| `height == -bbox_min[2]`                           | 26 072 / 26 072 |
| `collision_radius == cull_radius`                  | 26 072 / 26 072 |
| `\|cull_radius - max \|v\|\| < 1`                    | 22 127          |
| `\|cull_radius - max \|v\|\| <= 2`                   | 25 970          |
| `cull_radius > max \|v\|` for the remaining 102     | 102 / 102 (never smaller) |
| `depth_bias == 0`                                  | 25 540          |
| `depth_bias == cull_radius`                        | 532 (all of them the `prototyp.dir` class-3 code `1` rows) |

So `cull_radius` is a **bounding-sphere radius about the record origin**, padded
outwards. The 102 records where it exceeds the static vertex extent by more than
2 units are 98 multi-part records (whose parts rotate at runtime, so the radius
has to cover the swept volume) plus 4 single-part ones; the radius is never too
small, which is what a cull radius must guarantee.

### 2.4 `depth_bias` (`i32` @ `0x1c`) — the object sort key

`_E3D_object_3d_check_in` (`FUN_00404bd0`) rotates the clone's position into
camera space and then builds the sort key that `_E3D_draw_sorted_objects` orders
the draw list by. At `0x404e17`:

```
eax = *(i32 *)(record + 0x1c)      ; 0x404e1c  depth_bias
eax += clone_cam[1]                ; 0x404e1f  camera-space depth (forward axis)
key  = eax * eax                   ; 0x404e22
key += clone_cam[0] * clone_cam[0] ; 0x404e28
key += clone_cam[2] * clone_cam[2] ; 0x404e30
store 64-bit key at clone+0x14/+0x18
```

So the key is the **squared camera distance with the forward component pushed
out by `depth_bias`**. A positive bias makes the object sort as if it were that
many units further away, so it is painted **earlier** — i.e. behind everything
else at the same real distance.

That is exactly what the shipped values do: the 532 records with a non-zero bias
are precisely the `prototyp.dir` class-1 rows, they are the `LEVEL*.NNN` level
scenery chunks, and their bias equals their own `cull_radius`. The level shell is
therefore always sorted one bounding-sphere radius behind the props and
characters standing in it — the correct behaviour for a painter's-order engine
with no z-buffer.

`depth_bias` is **our** name for the field, chosen to describe the verified use.
The exporter's own term is not in the shipped product, and that is now settled
rather than deferred — see §2.4.1.

#### 2.4.1 Why the exporter's name is unrecoverable

The obvious place to look was the level editor, since the neighbouring fields
`height` and `collision_radius` *are* named by the engine's exports
(`_E3D_get_clone_height`, `_E3D_get_prototype_collision_radius`). Four searches,
all negative:

1. **No export names it.** `Eng3d.dll` exports 74 `_E3D_*` / `_E3DCARD_*`
   symbols; none reads or writes record `+0x1c`. The only reader of `+0x1c` in
   either renderer is the sort-key site `0x00404e1c` inside
   `_E3D_object_3d_check_in`, which is internal. (The near-miss
   `_E3D_get_prototype_collision_radius` reads `+0x26`, not `+0x1c` — a single
   `mov eax,[eax+0x26]` at `0x004063d4`. §6.1.)
2. **No keyword in `iDesigner.exe`.** `bias`, `zbias`, `depth`, German `tiefe`,
   `priorit`, `sort` swept in **ASCII and UTF-16LE** over the whole image
   including the 16 dialog templates and the menu resource
   (`python3 tools/pe_resources.py gog_incubation/iDesigner.exe --dialogs`):
   the only hit is the button caption *"Windowmode (16Bit ColorDepth)"*.
3. **No keyword anywhere else in the product.** The same sweep over all 35
   shipped PE files matches `depth_bias`-shaped text only inside third-party
   Glide/3Dfx code — `_grDepthBiasLevel@4`, `_grTexLodBiasValue@8` and the
   thunk name `set_depth_bias_level_` in `ENG3DFX.DLL`, `glide*.dll` and
   `3DfxSpl*.dll`. Those are the Voodoo *z-buffer* bias register, an unrelated
   concept: they never touch a `prototyp.bin` record, and the software build
   `Eng3d.dll` has no z-buffer at all.
4. **The editor is not the exporter.** `iDesigner.exe` never opens
   `prototyp.bin`, `prototyp.dir` or `prototyp.din` — it holds no such path
   string, and its only prototype-related identifiers
   (`aCreatePrototypeWithOuid`, `aGetNumberOfPrototype`,
   `aRefreshObjectControlPrototypes`, `get number of prototyp_name`) are
   tracked-allocation labels and Eng3d API names, the same family as
   `aParseLandscapeFile (tmp)`. It reaches prototype geometry only through
   `Eng3d.dll`, which loads the container for it. The same conclusion falls out
   of `docs/30` §2.10: the editor cannot even write a `.3DW`, so it is certainly
   not what produced the binary geometry container.

**Closure: the exporter did not ship, so the field's authoring-side name and the
intent behind the 532 chosen values are unrecoverable.** What is recoverable is
complete on the engine side: the arithmetic (above), which records carry a
non-zero value (§6.2), and that the value equals `cull_radius` in every one of
them. A remake reproduces the behaviour exactly by reading `+0x1c` and adding it
to the rotated depth; nothing depends on knowing what the artists called it.

### 2.5 Coordinate system

Prototype-local coordinates are `i32` triples in the same order as the header
bbox fields. **The third component is the vertical axis, positive up**:

* `height` (`_E3D_get_clone_height`) is exactly `-bbox_min[2]` in all 26 072
  records — i.e. how far the object reaches below its origin;
* projecting component 0 against component 2 yields upright objects
  (`tools/out/meshes/city_003.png` is a recognisable skyline; the same mesh
  projected 0-against-1 is a flat ground plan).

**This contradicts the `[COORD_SYSTEM] X_RIGHT_Z_INFRONT_Y_DOWN` line in the
`.3DW` files** (`docs/30` §2.3, open question 6), which would make component 1
vertical. Either the `.3DW` `POSITION` triple uses a different axis order from
the prototype vertices, or the coord-system identifier does not describe the
runtime frame. The evidence above is about prototype-local space only; resolving
the world-space convention belongs to the `.3DW` / level track.

---

## 3. Command streams

All three streams share one grammar and one dispatch table
(`Eng3d.dll:0x41408c`, 40 slots). The interpreter, verbatim from `0x405147`
(the draw loop; `0x4063a0` and `0x4067b6` are byte-identical copies):

```
esi = record + 0x32                    ; or 0x2a/0x2e + *(i32*)(record + 0x2a/0x2e)
loop:
    ebx = *(i16 *)esi                  ; opcode, already multiplied by 4
    esi += 2
    if (ebx < 0) goto done             ; the terminator is only the i16
    push esi
    eax = *(i32 *)esi                  ; operand
    esi += eax                         ; handlers that take a payload get it here
    call *(void **)(0x41408c + ebx)
    pop esi
    esi += 4
    goto loop
done:
```

So a **command is 6 bytes**: `i16 op` (a byte offset into the table, i.e.
`slot * 4`) followed by `i32 operand`. The list ends at the first negative
`i16`, and **the terminator occupies 2 bytes, not 6.** Shipped streams use
`0xFFFF` as the terminator.

The operand's meaning depends on the slot:

* `payload` — self-relative offset (from the operand field's own address) to a
  data block inside the record;
* `anim` — byte offset into the object's joint-angle buffer
  (`object[0x1c]`, or the inline area at `object + 0x20` when that pointer is
  null; see `0x405fd3`), which lives in the runtime `object_3d`
  ([`30`](30-eng3d-ascii-formats.md) §2.12), not in `prototyp.bin`. The shipped
  streams use three values — `0`, `6` and `12`, i.e. three consecutive `i16`
  Euler triples;
* `imm` — a plain immediate the handler reads out of `EAX`;
* `unused` — the handler ignores it (shipped values are `-1` or `0`).

### 3.1 Opcode table

`slot = i16 / 4`. Names are derived from the handler code; slots that never
occur in the shipped data are marked.

| Slot | Stream `i16` | Handler   | Name                   | Operand   | Occurrences (all streams) |
|------|--------------|-----------|------------------------|-----------|---------------------------|
| 0    | `0x00`       | `0x41139e`| `load_vertices`        | payload   | 26 249 |
| 1    | `0x04`       | `0x410ea7`| `load_planes`          | payload   | 26 249 |
| 2    | `0x08`       | `0x410f7b`| `load_shades`          | payload   | 0 |
| 3    | `0x0c`       | `0x410ffa`| `load_uvbase`          | payload   | 0 |
| 4    | `0x10`       | `0x4110ea`| *unnamed*              | payload   | 0 |
| 5    | `0x14`       | `0x405199`| `draw_faces`           | payload   | 26 072 |
| 6    | `0x18`       | `0x405f7e`| `matrix_identity`      | unused    | 2 |
| 7    | `0x1c`       | `0x405fb7`| `matrix_set_a8ac`      | unused    | 147 |
| 8    | `0x20`       | `0x405fcd`| `joint_rotate_1`       | anim      | 0 |
| 9    | `0x24`       | `0x405ffc`| `joint_rotate_3`       | anim      | 1 959 |
| 10   | `0x28`       | `0x406071`| `joint_rotate_3_alt`   | anim      | 367 |
| 11   | `0x2c`       | `0x405eb0`| `matrix_none`          | unused    | 4 |
| 12   | `0x30`       | `0x405ed6`| `matrix_set_a8ac_b`    | unused    | 294 |
| 13   | `0x34`       | `0x405eec`| `matrix_from_angle`    | anim      | 0 |
| 14   | `0x38`       | `0x405f1a`| `matrix_from_angles_b` | anim      | 3 918 |
| 15   | `0x3c`       | `0x405f4c`| `matrix_from_angles`   | anim      | 734 |
| 16   | `0x40`       | `0x4062ad`| `part_push`            | payload   | 639 |
| 17   | `0x44`       | `0x406313`| `part_pop`             | payload   | 639 |
| 18   | `0x48`       | `0x4060f0`| `joint_place`          | anim      | 639 |
| 19   | `0x4c`       | `0x40621b`| `lod_switch_0`         | payload   | 0 |
| 20   | `0x50`       | `0x406222`| `lod_switch_1`         | payload   | 0 |
| 21   | `0x54`       | `0x406229`| `lod_switch_2`         | payload   | 0 |
| 22   | `0x58`       | `0x406230`| `lod_switch_3`         | payload   | 0 |
| 23   | `0x5c`       | `0x40624e`| `distance_cull_0`      | unused    | 0 |
| 24   | `0x60`       | `0x406255`| `distance_cull_1`      | unused    | 0 |
| 25   | `0x64`       | `0x40625c`| `distance_cull_2`      | unused    | 0 |
| 26   | `0x68`       | `0x406263`| `distance_cull_3`      | unused    | 0 |
| 27   | `0x6c`       | `0x406287`| `emit_part_transform`  | imm       | 26 285 |
| 28   | `0x70`       | `0x40619f`| `select_detail`        | unused    | 26 072 |
| 29   | `0x74`       | `0x40616e`| `draw_flat_bank`       | unused    | 0 |
| 30   | `0x78`       | `0x406173`| `switch_prototype`     | imm       | 0 |
| 31   | `0x7c`       | `0x4061d2`| `select_late_pass`     | unused    | 2 |
| 32   | `0x80`       | `0x4052ee`| `nop` (bare `ret`)     | unused    | 2 |
| 33   | `0x84`       | `0x4060eb` → `0x4116ff` | `world_vertices` | payload | 26 249 |
| 34   | `0x88`       | `0x4060e6` → `0x4117f3` | `world_planes`   | payload | 26 249 |
| 35   | `0x8c`       | `0x405ebb`| `matrix_clone`         | unused    | 47 194 |
| 36   | `0x90`       | `0x405f89`| `matrix_clone_compose` | unused    | 23 597 |
| 37   | `0x94`       | `0x4061d7`| `select_bank_4`        | unused    | 0 |
| 38   | `0x98`       | `0x405ee1`| `matrix_none` (dup of slot 11) | unused | 0 |
| 39   | `0x9c`       | `0x405fc2`| `matrix_none` (dup of slot 11) | unused | 0 |

**Slot 4 (`0x4110ea`) is a single `c3` — a stub.** It is the fifth loader slot
in the vertices / planes / shades / uv-base group; the byte at that address is
`ret`, nothing else. (`0x4110eb`, the code Ghidra folds into it, is the 16-bit
normal-rotation helper that `load_planes` uses, reached only by a direct call.)

**Slots 19–22** (`0x40621b`, `0x406222`, `0x406229`, `0x406230`) all fall through
to the common body at `0x4061dc`. They compute
`depth - cull_radius` (`0x4061dc`: `[0x414068] - [[0x414080]]`), walk a threshold
list from one of the four tables `0x4142b0`, `0x4142c0`, `0x4142d0`, `0x4142e0`
(`0x4061f1`), pick the matching entry from the payload, and **switch execution to
that prototype's render program** (`[0x4180cc + 4*index]`, `0x406203`) — a
distance-based level-of-detail swap. Each table holds four `i32` thresholds, all
four initialised to `50 000 / 100 000 / 200 000 / 0x07ffffff`
(`0x4142b0` …), and `_E3D_change_distance_methode_switch_table(table, slot,
value)` (`0x40626a`, bounds-checked `< 4` on both indices) rewrites them at
runtime.

**Slots 23–26** (`0x40624e`, `0x406255`, `0x40625c`, `0x406263` → `0x406237`)
use the same four tables but only compare `depth - cull_radius` against
`table[0]`; if it is greater or equal they `jmp 0x405170`, which **abandons the
rest of the command stream** — a plain distance cull.

Slots 19–26 are therefore not dead code but **one build-time choice with eight
encodings**: two families of four, one table per family member. All eight are
`0` in the corpus because the exporter was always run with the same setting —
`DETAIL_METHODE 1`, the surviving directive documented in
[`30-eng3d-ascii-formats.md`](30-eng3d-ascii-formats.md) §2.11. That the
directive's `1` is the same index as the engine's `methode` is **UNVERIFIED**:
if it were, `distance_cull_1` or `lod_switch_1` should appear, and neither
does.

**Slots 38 and 39** are byte-identical to slot 11 (`mov dword [0x414060],
0x41a8d0; ret`) — they reset the current matrix to the engine's identity matrix.

**Slots 29, 31 and 37** select rasteriser banks; see §4.5.

What the important ones do:

* **`load_vertices`** (`0x4114b4`, integer path) reads `u16 count` then
  `count × (i32 x, i32 y, i32 z)`, `add esi,0xc` per vertex, transforms them by
  the current matrix plus the clone position and projects into the screen-vertex
  arrays at `0x4869ac` (16 B/vertex) and `0x484a68` (8 B/vertex), indexed from
  the base in `0x414040`.
* **`load_planes`** (`0x410ea7`) reads `u16 count` then
  `count × (i16 nx, i16 ny, i16 nz)`, `add esi,6` per plane. It rotates each
  normal, dots it with the object-to-camera vector, and `stosd`s **one `i32`
  per plane** into `0x48a830` (indexed from `0x414044`). That array is the plane
  side test used by the face tree. Normals are `1/16384` fixed point
  (`shrd eax,edx,0xe`).
* **`load_shades`** (`0x410f7b`) is `load_planes` for lighting. It reads
  `u16 count` → `[0x414050]`, then `count × (i16 nx, i16 ny, i16 nz)`, rotates
  each by the current matrix (`0x410fac`…`0x410fd8`, same `shrd …,0xe`
  `1/16384` normals), dots it with the light vector at `0x41a960/64/68`, and
  writes **one `i16` per entry** into `0x48cf48 + 2 × index`, based at
  `[0x414048]` — **the third `part_push` index base** (`0x410f92`). Those `i16`
  are exactly what the gouraud draw kind interpolates. No shipped record uses
  the opcode, so no shipped record carries a shade block.
* **`load_uvbase`** (`0x410ffa`) is an **environment-map UV generator**. It reads
  `u16 count` → `[0x41405c]`, base `[0x41404c]`, then per entry
  `3 × i32` (a direction), rotates it by the matrix at `0x41a864`, converts the
  two resulting angles with `0x41223f` (the `_E3D_calc_angle_dx_dy` arctangent),
  masks each to 12 bits and shifts left 2 (`and eax,0xfff; shl eax,2` at
  `0x4110a6`/`0x4110cb` — a full circle mapped onto `0…16383`), and stores them
  as `(u16 u, u16 v)` into `0x48d71c + 4 × index`. Draw kind `0x24` reads that
  array. Never used by shipped data.
* **`draw_faces`** enters the face BSP walker (§4).
* **`part_push` / `part_pop`** open and close a sub-object scope; see §5.
* **`joint_*`** and **`matrix_from_angle*`** set the current transform. Their
  angles live in the runtime object's joint buffer, i.e. outside this container
  — a static decoder can ignore them and gets the rest pose. `joint_rotate_1`
  and `matrix_from_angle` read one angle, the rest read a triple.
* **`select_detail`** (`0x40619f`) compares the clone depth against
  `4 × cull_radius` and `5 × cull_radius` and jumps to one of three span-filler
  banks — `0x407d01`, `0x407d34`, `0x407d67`. That is the perspective-correct /
  affine choice; see §4.5.
* **`world_vertices` / `world_planes`** are the collision-stream twins of slots
  0 and 1: same payload format, but they produce world-space output instead of
  screen-space. **They point at the very same blocks**: over the whole corpus the
  ordered list of `world_vertices` payload targets equals the ordered list of
  `load_vertices` targets in 26 072 / 26 072 records (52 498 command pairs, zero
  mismatches). This is the strongest internal consistency check available.

### 3.2 Layout of a whole record

```
0x00                     header (0x32 bytes)
0x32                     render program       -> ends with i16 < 0
<payload blocks>         vertex blocks, plane blocks, part blocks, face tree
                         (interleaved in the order the render program lists them)
0x2a + [0x2a]            collision program    -> ends with i16 < 0
(0x2e + [0x2e]) - 4      i32 self-relative back-pointer to the face-tree root
0x2e + [0x2e]            part-info program    -> ends with i16 < 0, at EOF
```

The back-pointer is read at `0x4067d1`, immediately after the collision stream
terminates, and yields the root of the same face tree the render program draws.
It matches the render program's `draw_faces` payload in **26 072 / 26 072**
records.

The part-info stream ends exactly at the record's last byte in all 26 072
records, including the last record of each of the 21 containers. **This settles
open question 13 of `docs/30`: there is no trailer after the final record.**

In 135 records `[0x2a]` is `0` (collision disabled) even though the collision
stream is still physically present in the file, immediately before the
back-pointer. **Those 135 are exactly the multi-part records (§5)** — the
implication holds in both directions with no exception in 26 072 records, and
the two properties are read from different places in the record (`+0x2A` versus
a walk of the command stream for `part_push`), so the coincidence is real. The
parser locates the stream by starting at the first byte after the last claimed
data block, and cross-checks against `0x2a + [0x2a]` when that field is
non-zero.

**What the engine does with `[0x2a] == 0`** (`0x4067af`): `cmp dword [esi],0`
followed by `je 0x4067e7`, and `0x4067e7` is `mov eax,0; ret` — the collision
entry point returns *no collision* immediately. It does not fall back to the
bounding box and it never reaches the face-tree back-pointer at `0x4067d1`. So
the field is a plain per-prototype "this object is not solid" switch, and the
collision stream that follows is dead data. The 135 records that carry it are
`A_FIRE1/2/3.3DI` (animated flames), `A_PANEL.3DI` and the `L1xxEX00.3DI` /
`L045EA00.3DI` animated level fittings — which do read as decoration you are
meant to walk through. But the exact biconditional above says the object's role
is not what selected the zero: **the exporter emitted no collision program for
any record with sub-objects**, and those records simply happen to be the
animated fittings. The engine imposes no capability limit that would force this
(`part_push` is in the same dispatch table the collision stream uses), so it is
an exporter policy, not an engine constraint. See §9 item 6.

---

## 4. Face data

### 4.1 The BSP tree

`draw_faces` points at a node. `FUN_004051a1` @ `0x40519f`:

```
tag = *(i16 *)p; p += 2
if (tag < 0)  interior_node(p)          ; FUN_004051b8 @ 0x4051b8
else          leaf(p, count = tag)      ; FUN_004051fc @ 0x4051fc
```

**Interior node** (offsets from `p`, i.e. after the tag):

| Offset | Type  | Field                                                            |
|--------|-------|------------------------------------------------------------------|
| `0x00` | `i16` | `plane_index`, signed, magnitude is a **1-based** index into the plane array (`0x48a82c` = `0x48a830 - 4`); a negative index negates the test |
| `0x02` | `i32` | `plane_d`                                                        |
| `0x06` | `i16` | self-relative offset (from `p`) to the *far* child                |
| `0x08` | —     | the *near* child, inline                                          |

Both children are recursed through the same tag dispatch. The engine swaps near
and far when `plane_value - plane_d < 0` (`0x4051eb`) -- the same test §4.2
pins as "the camera is on the side the normal points to". Which order that
is follows from where the children's geometry lies, and the corpus answers:
over the 22 126 interior nodes of the root-scope prototypes, the *far* child's
vertices sit on the plane's **front** side and the inline child's on its
**back** in 22 111 (11 ties, 4 the other way, all four in sequence models;
`tools/inclib/overdraw.py`'s census, pinned by `prototyp_parse.py --check`,
2026-09-21). So with the camera in
front the front-side child is drawn first, and with it behind the back-side
child is: the walk is **front to back**, and the span buffer of §4.5 --
whose stored spans hide what comes later -- is what makes that a correct
hidden-surface method. *(Until 2026-09-21 this paragraph called it a
back-to-front painter's walk; §9 item 3's reading of `0x40DAF0` had already
said otherwise and the two were never reconciled. The consequence for a
remake is §4.7.)* The builder does not split polygons: a face straddling a
node's plane sits whole in one child (4 954 nodes have a near-side vertex
past a far-side one), and a face lying *on* the plane may sit in either.

**Leaf**: `tag` face records back to back.

### 4.2 Face record

Read by `FUN_004051fc` (`0x405203`…`0x405250`) and the draw routines. The
walker adds `size` to advance, so a decoder never has to know a routine's
payload format to traverse the list.

| Offset | Type  | Field           | Read at    |
|--------|-------|-----------------|------------|
| `0x00` | `u16` | `draw_kind`     | `0x40523b` — byte offset into the active draw-routine table |
| `0x02` | `i16` | `plane_index`   | `0x405203` — signed, 1-based; `0` means "always draw" |
| `0x04` | `i32` | `plane_d`       | `0x40522d` — face is drawn when `plane_value - plane_d < 0` |
| `0x08` | `u16` | `size`          | `0x40524c` — total byte size of this face record |
| `0x0a` | `u16` | `colour`        | `0x40f050` (`mov ax, word [edx-2]` after `add edx,0xc`) |
| `0x0c` | `u16` | `vertex_count`  | `0x40f05b` |
| `0x0e` | `u16 × n` | `vertex_index` | `0x40f06e` — `add bx, word[edx]` on top of the base in `0x414040` |
| …      | —     | per-kind payload | see 4.3 |

The `colour` field is a **16-bit RGB565** value: the flat filler copies it to
`0x445088`, duplicates it into both halves of a dword, and — when the screen is
15-bit — converts it with `and 0xffc0ffc0 / and 0x1f001f / shr 1` at `0x4088f3`,
the standard 565 → 555 squeeze. It is `0` on most textured faces (the texture
supplies the colour) and carries real colours on flat ones; 285 distinct values
occur.

**The side test is a back-face cull, and its sign is pinned** *(added
2026-09-02, for the remake's roof question in [`97` §28.5](97-slice-5-report.md))*.
Three readings that have to agree, and do:

* **What `plane_value` is.** `E3D_object_3d_check_in` subtracts the camera's
  position from the object's (`0x00404BF4`..`0x00404C00`, the camera at
  `0x41a7e0/e4/e8`), stores the difference at `0x41b8dc/e0/e4` (`0x00404C62`),
  rotates it by the camera matrix into the display-list node's first three
  words (`0x00404D8B`..`0x00404DBC`), and the draw loop copies those to
  `0x414064/68/6c` (`0x004050C4`) before the prototype runs. So the vector
  `load_planes` dots each rotated normal with is **object minus camera**, in
  camera space, and `plane_value = n · (object − camera) / 16384`.
* **What `plane_d` is.** The face's own plane, `plane_d == −n · v / 16384`
  for its vertices `v`, **in the frame the engine tests it in**. Two things
  had to be read before the corpus said so cleanly. A face inside a
  `part_push` scope keeps its plane in the *part's* coordinates: `joint_place`
  (`0x004060F0`) rotates the part translation by the current matrix and
  **adds it into** `0x414064/68/6c` — the very position the side test dots
  the normal with — so the part's origin, not the object's, is what a part
  face is measured from (§5). And the stored normal is the exact one
  **truncated to 14 bits**: its magnitude is 16 381 on 7 153 faces, 16 382 on
  53 657, 16 383 on 170 216 and 16 384 on 5 835, never above, while
  `plane_d` was computed before the truncation. Measured that way, 230 940 of
  236 861 faces have `plane_d` inside the span their vertices give (± 2
  units), and every one of the other 5 921 lands in it under a rotation of
  the stored normal of at most **0.018°** — which at the radii these faces
  sit at (the sequence models' planets and their 5.5-million-unit space
  sphere) is a miss of up to 908 units; outside the sequence models' `Video/`
  containers the worst is 60, on `L096EE00.3DI`.
  An earlier revision of this bullet called those faces "a parallel plane
  offset by up to 13 518 units, cause UNVERIFIED": the 13 518 was a part face
  measured in the wrong frame, and the rest was the normal's precision.
  So the engine's side test **is** a cull on the face's own plane, and the
  remake's `CULL_BACK` differs from it only inside a sliver 0.018° wide.
  The ground lattice `S003_00X.3DI` reads `n = (0, 0, 16383)`, `plane_d =
  −80`, on every face — a floor at `z = 80`, normal up.
* **What the leaf walker does** (`0x00405203`..`0x00405230`): a negative
  index negates the value, and the face is drawn when `plane_value − plane_d
  < 0`, i.e. `n · (object − camera) + n · v < 0`, i.e. **`n · (vertex −
  camera) < 0`: the face is drawn only when the camera is on the side its
  plane normal points to.** The lattice fixes the sign without a renderer: a
  floor is seen from above, and only from above. Index `0`, "always draw",
  occurs on **no shipped face**.

And the winding agrees with it: the Newell normal of the stored vertex order
is **against** the plane normal on 236 160 faces, zero on the 700 that have no
area, and with it on exactly one — a sliver in `MODEL_D02_RUTHERFORD_KOPF`
whose Newell normal is `(−9, 50, 7)` against a plane of magnitude 16 384. So a
renderer that takes the indices as stored and culls the back face under a
clockwise-front convention draws exactly the side the engine draws.
`prototyp_parse.py --check` pins every count in this paragraph, the
lattice's plane, the 0.02° bound with its worst miss, and that no normal is
longer than 16 384.

The consequence the remake was waiting on (`97` §28.5): a ceiling is a face
whose plane normal points **down**, drawn from below and culled from above —
which is why the original's player looks into a roofed room from ten metres
over the unit's head. World_A00 carries 957 near-horizontal faces facing down
and 2 234 facing up across its prototypes; over the playable floor of
`_C_140` there are four, all facing down, at `z = 32 000`.

### 4.3 Draw kinds — payload layout

The `u16` at `0x00` is a byte offset into whichever draw-routine table is
active (§4.5). Every table is a variant of the same 11 slots, so the *payload
layout* is a property of the slot only.

| Slot   | First-table routine | Trailing payload after the index array          | Shipped faces |
|--------|---------------------|--------------------------------------------------|---------------|
| `0x00` | `0x40f050`          | none                                             | 3 467         |
| `0x04` | `0x40f1d6`          | `i16 shade × n`, then **`u16 ramp`**              | 0             |
| `0x08` | `0x40f3f4`          | `(i16 u, i16 v) × n`, then `u32 texture`         | 4 027         |
| `0x0c` | `0x410837`          | none                                             | 1 010         |
| `0x10` | `0x41061b`          | `(i16 u, i16 v) × n`, then `u32 texture`         | 220 156       |
| `0x14` | `0x40f86e`          | `(i16 u, i16 v) × n`, then `u32 texture`         | 2 673         |
| `0x18` | `0x41037d`          | `(i16 u, i16 v) × n`, then `u32 texture`         | 0             |
| `0x1c` | `0x40fc67`          | `(i16 u, i16 v) × n`, then `u32 texture`         | 5 517         |
| `0x20` | `0x40fff2`          | `(i16 u, i16 v) × n`, then `u32 texture`         | 11            |
| `0x24` | `0x40f622`          | **`u32 texture` only** — no `(u, v)`             | 0             |
| `0x28` | `0x410b12`          | bare `ret`                                       | 0             |

`size - (0x0e + 2n)` matches the table exactly for every one of the 236 861
shipped faces (`unexplained bytes inside faces: 0`).

### 4.3.1 Face shape — what a remake may assume about the polygon

`vertex_count` runs from 3 to **24**, not to 8:

| corners | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 24 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| faces | 82403 | 145706 | 4898 | 2519 | 198 | 1103 | 9 | 5 | 2 | 1 | 4 | 2 | 11 |

The engine fills a polygon by walking its edges, so it never needed the two
properties a triangulating renderer does. Both are decidable in exact integers
over the placed vertices, and `tools/prototyp_parse.py --check` reports them:

* **Planarity is approximate, not exact.** 144 877 of 236 861 faces are exactly
  planar in integer world units; the worst out-of-plane deviation is 40 864
  units (about 25 m, on `MODEL_EXTRO_6_SCHIFFSKORPER_DECKEL`). This is
  *reported* rather than gated — the corpus is authored on an integer grid, and
  a span filler never asked for flatness.
* **Convexity is not universal, and this one matters.** **1572** faces have a
  reflex corner and **129** name the same vertex slot twice; 700 more have a
  Newell normal of zero, i.e. no area at all. The three counts partition the
  corpus with the 234 589 a triangle fan handles correctly. The reflex faces are
  mostly dialogue and sequence models, but **81 are in `World_A00`**, which the
  playable campaign's first missions use.

A **fan from vertex 0 is therefore wrong on 1572 shipped faces**: it emits a
triangle outside the outline and misses one inside. `godot/game/mesh_builder.gd`
ear-clips in the plane of the Newell normal instead. The counts above are pinned
in `prototyp_parse.py` so that a change in them is a visible change rather than
a silent one.

Two corrections to earlier readings of this table:

* **Slot `0x04` has a two-byte tail after the shades.** After the `fild
  word[edx]` loop at `0x40f226` the routine does `mov ax, word [edx]` /
  `mov eax, [eax*4 + 0x43b088]` / `mov [0x445094], eax` (`0x40f236`…`0x40f240`):
  one more `u16` selecting a **colour ramp** from the table at `0x43b088`.
  The full tail is `2n + 2` bytes. Code-verified; no shipped face exercises it.
* **Slot `0x24` carries no `(u, v)` pairs.** `0x40f622` reads the index array
  once for the vertices, rewinds exactly `2n` bytes (`sub edx,ecx` twice at
  `0x40f662`), reads the *same* index array a second time to look each vertex's
  `(u16 u, u16 v)` up in the generated array at `0x48d71c`, and then takes the
  texture id straight after it (`mov ebx,[edx]; add edx,4` at `0x40f688`). The
  tail is therefore `4` bytes, not `4n + 4`. Code-verified; no shipped face
  exercises it. Slot `0x18` by contrast really does read `4n + 4`
  (`0x4103cf`…`0x4103e7`), also code-verified and also unexercised.
* **Slot `0x0c` has no conditional tail.** The `mov esi,[edx]; add edx,4` at
  `0x41089b` that §9 previously flagged is the *queue copy loop* — `edx` there
  walks the array of vertex pointers at `[0x415a54 + 4n]` while copying nine
  dwords per vertex into the deferred-polygon queue, not the face payload. Slot
  `0x0c` consumes exactly `0x0e + 2n` bytes, always.

**Texture ids** index the sibling `texture.din` of the same world set. All
236 861 shipped faces reference an id below that container's entry count; the
largest id seen anywhere is 59.

### 4.4 Draw kinds — rasteriser semantics

Two builds of the same renderer shipped: `Eng3d.dll` (software) and
`ENG3DFX.DLL` (Glide / 3dfx). Both have the identical 11-slot table structure at
the same relative addresses, so each slot can be read twice. Three of the
software rasterisers are additionally **named by Blue Byte's own exports**:
`_E3D_draw_zoom_bob_masked` / `_alpha_plus` / `_alpha_minus` (`0x4024a0`,
`0x402480`, `0x402490`) push a polygon into the same deferred queue with the same
deferred rasteriser pointers that draw kinds `0x14`, `0x1c` and `0x20` use.

| Slot | Name | What it does | Software evidence | Glide evidence |
|------|------|--------------|-------------------|----------------|
| `0x00` | `flat_00` | **Opaque flat fill** with the face `colour` (RGB565). Drawn immediately, through the span routine the opaque kinds share. | filler `0x40888f`: `rep stosd` of the doubled colour; visibility via `0x40daf0` | class `[0x411064]`, texture `-1` (`0x40aa2a`); `grColorCombine(SCALE_OTHER, ONE, LOCAL_CONSTANT, OTHER_CONSTANT)` @ `0x4028a8` |
| `0x04` | `gouraud_04` | **Ramp-shaded fill.** Per-vertex `i16` intensities are interpolated across the span and used as an index into a 1-D colour ramp (`ax = word[ebx+ebx]`, `0x40aac8`), the ramp base coming from the trailing `u16`. Not RGB interpolation. | setup `0x408655`, filler `0x40aa07` | class 5; `grColorCombine(LOCAL, OTHER_ALPHA, LOCAL_ITERATED, OTHER_CONSTANT)` @ `0x4028c8` = iterated RGB |
| `0x08` | `texture_08` | **Opaque textured, affine (never perspective-corrected).** Fixed rasteriser pair regardless of distance. | pair `[0x415078]=0x4083aa` setup, `[0x41507c]=0x409733` filler (`0x40f470`); `0x409733` contains no `fdiv` | drawn immediately, default opaque state |
| `0x0c` | `flat_0c` | **50 % translucent flat fill.** `dst = ((dst >> 1) & 0x7bef7bef) + ((colour >> 1) & 0x7bef7bef)` — an exact half-and-half RGB565 blend (`0x4089bb`, `0x408a24`). Deferred to the transparent pass; goes through the span routine only the deferred kinds use. | deferred fn `0x410b05` → `[0x415064]`, `[0x41506c]=0x408960` (16-bit) / `0x40c94e` (15-bit); visibility `0x40e363` | class 1: `grAlphaBlendFunction(ONE, ONE, ONE, ZERO)` + `grDepthMask(0)` @ `0x4028e8` (hardware approximates 50 % with additive) |
| `0x10` | `texture_10` | **Opaque textured, perspective-corrected when near.** The dominant kind (93 % of all faces). | pair `[0x41508c]`/`[0x415090]`; near bank uses `0x408b38` (10 `fdiv`), mid/far `0x409733` (none) | drawn immediately, default opaque state |
| `0x14` | `texture_14` | **Colour-keyed ("masked") texture.** `if (texel == 0) skip pixel; else dst = texel` (`0x40adf0`: `test ax,ax; je`). Key is RGB565 `0x0000`. Deferred. | deferred fn `0x40fc5a` (= `_E3D_draw_zoom_bob_masked`'s, `0x410e60`) → `[0x415080]`/`[0x415084]` = `0x40b065` near / `0x40ac8c` far | class 4: `grChromakeyMode(1)` + `grChromakeyValue(0)` @ `0x4029c0` |
| `0x18` | `texture_18` | **Distance-switched, and half-dead.** After loading `(u,v)` and the texture it scans the vertices (`0x410403`): if **any** has camera-space `[+0xc] < [0x415034]` (`0x4cbebc20` ≈ `1.0e8` as a float) it takes the textured path `call [0x415078]; call [0x415088]` (`0x410415`), otherwise it jumps to `0x410b92`, the **flat** pair `call [0x415064]; call [0x415068]`. But `[0x415088]` is written by nothing in the DLL — the bulk copy at `0x40eeae` is its only initialiser and gives it `0x407d00`, a bare `ret` — so the textured branch draws nothing and only the flat fallback ever paints. The Glide build sidesteps the question entirely: `texture = -1`, material class 1 (flat additive). Intent **UNVERIFIED**; 0 shipped faces. | `0x410403`…`0x410421`; scan for writers of `0x415088` finds none | `0x40be3a`: `mov [edi+8], -1`; `0x40be49`: class 1 |
| `0x1c` | `texture_1c` | **Additive ("alpha plus") texture.** Saturating per-channel RGB565 add: `dst += texel` with carry detection `and edx,0x10820` and an OR-mask table at `0x445850` to clamp each field to max (`0x40ba52`…`0x40ba7c`). `texel == 0` is skipped. Deferred. | deferred fn `0x40ffe5` = `_E3D_draw_zoom_bob_alpha_plus`'s (`0x410ce4`) → `[0x415094]` = `0x40b8dd` (16-bit) / `0x40cb26` (15-bit) | class 2: `grAlphaBlendFunction(ONE, ONE, ONE, ZERO)` + `grDepthMask(0)` @ `0x402938` |
| `0x20` | `texture_20` | **Subtractive ("alpha minus") texture.** Saturating per-channel RGB565 subtract, coded as `dst + ~texel` with the same `0x10820` carry mask but an **AND**-mask table at `0x44d850` clamping each field to 0 (`0x40c23a`…`0x40c25a`). `texel == 0` is skipped. Deferred. | deferred fn `0x410370` = `_E3D_draw_zoom_bob_alpha_minus`'s (`0x410da2`) → `[0x415098]` = `0x40c0b3` / `0x40d31a` | class 3: `grAlphaBlendFunction(ZERO, 0xf, ONE, ZERO)` + `grColorCombine(SCALE_OTHER, ONE, LOCAL_CONSTANT, OTHER_TEXTURE, **invert=1**)` + `grDepthMask(0)` @ `0x402970`. `0xf` is `GR_BLEND_ALPHA_SATURATE` / `GR_BLEND_PREFOG_COLOR`; the `invert=1` (inverted texture) is the hardware analogue of the software subtract. |
| `0x24` | `texture_24` | **Environment-mapped texture.** Carries no `(u,v)` of its own: it re-reads the vertex index array (`sub edx,ecx` twice at `0x40f662`) and fetches the generated `(u16 u, u16 v)` for each vertex from `0x48d71c` — the array `load_uvbase` fills from rotated normals. It then calls `0x410b14`, which walks consecutive vertices and adds `0x4000` wherever the u or v difference exceeds `±0x2000`, i.e. fixes the seam where the generated angle wraps. Otherwise identical to `0x08` (affine, opaque). 0 shipped faces. | `0x40f679`, `0x40f69c`, `0x410b14` | drawn immediately, default opaque state |
| `0x28` | `none_28` | **Bare `ret`** — draws nothing. | `0x410b12` | `0x40c5c6` |

The Glide "material class" is the `i32` each `ENG3DFX` draw routine stores at
queue-entry `+0x10`; the frame flush at `0x40c648` then runs one pass per class,
issuing the state calls above before each. Class 6 is a second, later, flat pass
(see §4.5). Glide argument order and enum values were checked against a real
Glide 2.x `glide.h`.

**Consequences for a remake, per face:**

| Draw kind | Texture | Blend | Pass | Shading |
|-----------|---------|-------|-----------------|---------|
| `0x00` | no  | opaque | immediate | flat `colour` |
| `0x04` | no  | opaque | immediate | ramp-indexed per-vertex |
| `0x08` | yes | opaque | immediate | none (decal) |
| `0x0c` | no  | 50 % blend | deferred | flat `colour` |
| `0x10` | yes | opaque | immediate | none (decal) |
| `0x14` | yes | alpha-test, key = `0x0000` | deferred | none |
| `0x1c` | yes | additive, `0x0000` transparent | deferred | none |
| `0x20` | yes | subtractive, `0x0000` transparent | deferred | none |
| `0x24` | yes (env, generated) | opaque | immediate | none |
| `0x18` | (see §4.4) | flat fallback only | immediate | flat `colour` |
| `0x28` | — | draws nothing | — | — |

Kinds `0x0c`, `0x14`, `0x1c` and `0x20` are **queued and drawn after all opaque
geometry**. Each appends its `n` transformed vertices (36 bytes each) to the
buffer at `0x4683e8` followed by a 36-byte trailer — `n`, the face `colour`, the
texture pointer, the scratch buffer, the two rasteriser pointers and the deferred
filler address (`0x410cb5`…`0x410cee` for the exported `zoom_bob` twin of the
same code). `_E3D_flush_transparent_polygons` (`0x410bac`, exported) then walks
the buffer **backwards** from the write pointer (`sub esi,0x24` at `0x410bdb`),
so the deferred polygons are drawn in **reverse submission order**, restores the
globals from each trailer and calls its filler. In `ENG3DFX.DLL` the whole frame
is queued instead, and the flush at `0x40c648` replays it in **material-class
order**
`0 → 5 → 4 → 6 → 1 → 2 → 3`, i.e. opaque flat, gouraud, chroma-keyed, late flat,
flat additive, texture additive, texture subtractive.

### 4.5 Which table, and which span filler

Two independent selections apply.

**(a) The table — a clipping requirement, not a quality level.** Four tables of
11 entries live at `0x41413c`, `0x414168`, `0x414194`, `0x4141c0`;
`FUN_0040508c` reads `al = byte [clone + 0x10]` (`0x4050b4`), stores it at
`0x414070` and indexes the pointer array `0x41412c` with it (`0x405106`). That
byte is built by `_E3D_object_3d_check_in`: cleared at `0x404ce5`, `|= 1` at
`0x404d51` when the object crosses the screen-x boundary and `|= 2` at
`0x404e13` when it crosses the depth limits. So the four tables are
**no clip / 2-D clip / 3-D clip / both**, and the four variants of each slot
differ only in which clipper they call before the fill — e.g. for `flat_00`:
`0x40f050` calls none, `0x40f0af` calls `0x4072d1`, `0x40f115` and `0x40f172`
copy the full six-dword camera-space vertex and call `0x406e90`.

Each of the four tables has a `+0xb0` twin at `0x4141ec`, `0x414218`,
`0x414244`, `0x414270` in which **all eleven entries are the flat routine of
that clip variant**. Opcode 29 (`0x40616e` → `0x405170`) adds `0xb0` to the
active table pointer `[0x41402c]` once (latched by `[0x414088]`), so it means
"render this prototype untextured". The Glide build has the same structure
(`0x4101ec` …).

**(b) The span fillers — a distance-driven perspective/affine choice.** Five
setter blocks each rewrite five function pointers:

| Setter | Selected by | `[0x41508c]`/`[0x415080]` setup | `[0x415090]` (kind `0x10`) | `[0x415084]` (kind `0x14`) | `[0x415068]` (kind `0x00`) |
|--------|-------------|------|------|------|------|
| `0x407d01` | `select_detail`, `depth < 4 × cull_radius` | `0x407fb5` | `0x408b38` **perspective** | `0x40b065` **perspective** | `0x40888f` |
| `0x407d34` | `select_detail`, `< 5 × cull_radius`       | `0x407fb5` | `0x409733` affine | `0x40b065` perspective | `0x40888f` |
| `0x407d67` | `select_detail`, farther                    | `0x4083aa` | `0x409733` affine | `0x40ac8c` affine | `0x40888f` |
| `0x407d9a` | **opcode 31**                               | `0x407fb5` | `0x409e72` affine | `0x40ac8c` affine | `0x409d97` |
| `0x407dcd` | **opcode 37** (never used)                  | `0x407fb5` | `0x40a4e3` affine | `0x40ac8c` affine | `0x40888f` |

`0x408b38` and `0x40b065` are the only fillers containing `fdiv` (10 and 7
respectively); every other filler steps `u` and `v` linearly with
`add ebp,ecx / adc bl,cl`, i.e. is affine. So **perspective correction is applied
only to kinds `0x10` and `0x14`, only within 4–5 bounding-sphere radii of the
camera**.

Opcode **31** (`select_late_pass`, the two class-11 records `L096EE00.3DI` and
`L096EF00.3DI`) swaps in a bank whose fillers use a *third* span-visibility
routine, `0x40e872`, instead of the occluding `0x40daf0`, and which skips
one-pixel spans (`cmp ecx,1; jg` at `0x409e38`). In the Glide build the same
opcode (`0x408e62` → `0x40a99b`) sets the flat material class to **6** instead of
0, and class 6 is flushed *after* the chroma-keyed pass at `0x40c6ce`. Both
builds therefore agree that opcode 31 means "draw this prototype in a late,
non-occluding pass", and `0x40e872` is now read: it is `0x40e363` duplicated
instruction for instruction onto its own scratch block, so the software pixel
path is the deferred kinds' path exactly (§9 item 3). Opcode 37's bank is
unreachable from shipped data and its Glide counterpart (`0x40a9a6`) is a bare
`ret`.

The three span-visibility routines are cleanly split by use: **`0x40daf0`** is
called only by the fillers of the opaque kinds (`0x40888f`, `0x40aa07`,
`0x408b38`, `0x409733`), **`0x40e363`** only by the fillers of the deferred kinds
(`0x408960`, `0x40ac8c`, `0x40b065`, `0x40b8dd`, `0x40c0b3` and their 15-bit
twins), and **`0x40e872`** only by the opcode-31 bank. The bodies have since been
read, and they confirm the natural reading: `0x40daf0` is the only one of the
three that allocates s-buffer nodes (14 sites bumping the arena cursor
`0x44FBB8` by `0x1C`), so it **inserts** spans and occludes; `0x40e363` and
`0x40e872` never allocate and only **test** against the existing list. And
`0x40e872` is `0x40e363` copied instruction for instruction onto a second
24-byte scratch block. See §9 item 3 for the full comparison.

### 4.6 Texture coordinates and the V origin — **settled**

`(u, v)` are 8.7 fixed point in texels; the observed range is `0 … 32767` and
`docs/50` establishes that every shipped VISN texture is a 256 × 256 page of
RGB565, so `u / 128` is the texel column and `u / 32768` the normalised
coordinate.

The addressing is explicit in the rasteriser:

1. The draw routine writes the two `i16` into the working vertex as floats:
   `fild word[esi]` → vertex `+0x18` (**u**), `fild word[esi+2]` → vertex `+0x1c`
   (**v**) — `0x410664`…`0x41066c`, 36-byte vertex stride.
2. The setup routine biases both by `+0x4800000` on the float bit pattern
   (`0x407fe0`, `0x407fe7`) — an exponent bump of 9, i.e. `× 512` — then
   `fistp`s them, so the resulting 32-bit interpolator carries the texel
   coordinate in its **high 16 bits** (`u × 512 / 65536 = u / 128`, confirmed by
   the `sar eax,0x10` / `shl edx,0x10` split at `0x40812e`).
3. **u** goes into the edge array at `+0xc00` and **v** into the one at `+0x1800`
   (`0x408326`, `0x40832c`, from `[0x445804]` and `[0x445808]`, which are
   `fistp`ed from vertex `+0x18` and `+0x1c` at `0x4080de` / `0x4080f2`).
4. In the filler, `+0xc00` steps the **low byte** `bl` and `+0x1800` the **high
   byte** `bh` of the texel index (`0x4097f8`, `0x40982a`), and the texel is
   fetched with `mov ax, word [ebx+ebx]` (`0x409877`).

So the texel address is `texture_base + 2 × (v × 256 + u)`: **`v` is the row
index and `u` the column index**, both wrapping mod 256.

Row 0 is the **top** of the picture: the VISN decoder writes the picture's first
row at offset 0 of the same buffer, and our byte-exact reimplementation of it
(`docs/50`, verified against the shipped DLL under Wine) produces upright
images — `tools/out/textures/_contact_sheet.png` shows faces the right way up,
skies above cityscapes, and legible left-to-right text.

**Therefore V counts down from the top of the texture.** OBJ puts V at the
bottom, so `tools/prototyp_parse.py --obj` writing `u / 32768` and
`1 - v / 32768` is **correct** and was left unchanged.

### 4.7 Coplanar faces of one prototype — what the code says and what the screen shows

Two faces of one prototype can share a plane exactly and overlap in area:
`LEVEL09A.005` in `World_I00` paints an iris on a wall with five blade faces
(12, 13, 17, 18, 19) and a square backing (14) that contains all five, all
ten of the leaf's faces on plane 2 at `plane_d 2512`, listed 11..20, every
vertex at local `x = 2512`, one draw kind, one texture, one winding. A depth
buffer has no answer for that -- the blades z-fight the backing -- so what
the engine shows has to be read off the rasteriser, and then checked against
the screen.

**What the code says.** `0x40DAF0`, the span routine the opaque kinds fill
through (§4.5), keeps one linked list per scanline of `0x1C`-byte nodes
`{x0 @+0, x1 @+4, z0 @+8, z1 @+0xC, next @+0x10, prev @+0x14, tag @+0x18}`;
the initialiser `0x40DA20` links a head sentinel at `0x44FBC0 + 0x1C·y` to a
tail at `0x454FC0 + 0x1C·y` and seeds the per-line cursor at `0x43FC78 + 4·y`.
`tag` is `[0x44FBBC]`, which `draw_faces` increments once per program
(`0x405199`), so it names the object -- or the `part_push` scope -- being
drawn. The global has eleven references in the DLL: that increment, nine
reads in the three span routines, and one more increment at `0x410BCD`, at
the head of the routine that flushes the deferred queue (`0x410BAC`, walking
the 36-byte entries from `[0x4683E8]`) -- once per pass, so the deferred
kinds share a tag among themselves and never the opaque faces' own. On an
overlap the routine first compares the incoming span's tag with the stored
node's (`0x40DC20`..`0x40DC29`): **equal tags skip the depth test**
(`je 0x40dc43`) and fall into the coverage arms, where the stored span keeps
every pixel it has and the new one is trimmed to what is left (`0x40DC43`..
`0x40DC6B`: fully inside, the run list stays empty and the filler's `je`
after the call skips the line; overhanging, the covered pixels go out as a
positive "skip" run and only the rest is inserted). Only spans of
*different* tags reach the depth compare at `0x40DC2B`..`0x40DC3D`, which is
on the nearest end of the incoming span less a magnitude-dependent slack
(`[0x45A3CC]` table), so even there a coplanar newcomer is behind. The leaf
walker draws its faces as listed (`0x405232`..`0x405254`, `edx += size`).
Combined with the front-to-back walk of §4.1, the reading is: **of two
overlapping coplanar faces of one prototype, the one the walk reaches first
is the one seen** -- for the iris, blades 12 and 13, then the backing, and
17..19 never.

**What the screen shows** (2026-09-21, the retail game, the same wall from
two camera quadrants): **all five blades, over the backing's black texels.**
No sequential order under any first-wins or last-wins rule produces that,
because the backing sits fourth of ten in the list; the reading above
therefore misses something, and what it misses is §9 item 8. The Glide
build settles nothing here: it sets `grDepthBufferMode(WBUFFER)`,
`grDepthBufferFunction(LESS)` and never calls `grDepthBiasLevel` (the thunk
at `0x40270C` has no caller), so its own answer for an exact tie is the
hardware's.

**What the remake does** ([`92` §7.24](92-remake-architecture.md)): a face
wholly inside an earlier coplanar face is drawn over it, as observed; two
faces that overlap only in part are layered by the walk order, as read,
which no observation has yet confirmed or refuted.

Counted over the corpus, on polygon intersection with an area above 64
square units, opaque kinds only (`tools/inclib/overdraw.py`, pinned by
`prototyp_parse.py --check`): **361 overlapping pairs in one leaf**, 14
across leaves on their own plane, 47 across leaves on another plane, **6
with one face inside the other** -- the iris's five and one in
`MODEL_D07_SHEEDEL` -- giving **218 faces** that lie under at least one
other. The deferred kinds are left out: they insert no span, and 867 of the
1 291 pairs the same count finds with them in are the sequence models'
additive flame quads, which add in either order. Coplanarity here is the
exact key `(plane_index, plane_d)`; 25 further overlapping pairs whose
`plane_d` differ by 1..8 units are all in the sequence models, where the
plane was rounded at a five-million-unit radius.

The remake carries the derivation as a face field, `overdraw` -- how many
layers of coplanar faces cover this one -- and its mesh builder recedes each
layer by sixteen world units along the face normal.

### 4.8 How the Glide build samples a texture — **[code]** *(2026-10-12)*

The software renderer reads one texel per pixel (§4.6: `mov ax, word
[ebx+ebx]`, the index wrapping mod 256). `ENG3DFX.DLL` hands each texture
page to Glide through **one** `guTexAllocateMemory` call (`0x402508`, in
`_E3DCARD_set_texture_page_size`'s body at `0x4025C0`), and every texture
property of the page is an argument there. Read against Glide 2.x's own
`glide.h` (the `sst1` tree; the 15-argument prototype, `GR_TEXTUREFILTER_*`,
`GR_TEXTURECLAMP_*`, `GR_LOD_*`, `GR_ASPECT_*`, `GR_TEXFMT_*`):

| Argument | Pushed | Meaning |
|---|---|---|
| `tmu` | `0` | TMU 0 |
| `odd_even_mask` | `3` | `GR_MIPMAPLEVELMASK_BOTH` |
| `format` | `[0x482108]` = `0xa` | `GR_TEXFMT_RGB_565` |
| `mm_mode` | `1` | `GR_MIPMAP_NEAREST` -- moot, see the LODs |
| `small_lod`, `large_lod` | `[0x4820FC]`, `[0x482100]`, both `0` | `GR_LOD_256`: **one** level, no mip chain |
| `aspect` | `[0x482104]` = `3` | `GR_ASPECT_1x1` |
| `s_clamp`, `t_clamp` | `1`, `1` | `GR_TEXTURECLAMP_CLAMP` |
| `minfilter`, `magfilter` | `1`, `1` | `GR_TEXTUREFILTER_BILINEAR` |
| `lod_bias`, `trilinear` | `0`, `0` | none |

The LODs are `0` on the branch for the default page size `0x20000` bytes
(`[0x410B24]`, 256 × 256 × 2) and `1` -- a 128 × 128 page -- otherwise; the
only way to change the size is `_E3DCARD_set_texture_page_size`, ordinal
87, which `Incubation.exe` never binds (§10.1). `grTexFilterMode`,
`grTexMipMapMode`, `grTexClampMode` and `grTexLodBiasValue` are imported and
**called from nowhere** in the DLL, so nothing overrides the allocation's
state. Every shipped `(u, v)` lies inside its page (`0 … 32767`, §4.6), so
the clamp changes nothing a face reaches; the filter changes what every
textured pixel looks like.

What this does not settle is the **picture**: no frame of the Glide build
has been observed (the bundled nGlide path does not reach a game frame under
Wine on this host, [`91` §6](91-wine-runtime-probes.md)), and the chroma key
of kind `0x14` (`grChromakeyMode`, two call sites) is applied by the
hardware to a filtered texel, whose edge the code cannot show. The remake's
smoothed sampling ([`92` §7.28](92-remake-architecture.md)) is therefore its
own option, not a reproduction of this build.

**The same build fogs one screen.** `_E3DCARD_set_fogging_linear` is a
stub in `Eng3d.dll` -- ordinals 70, 71 and 72 all export `0x4024C0` -- and
real in `ENG3DFX.DLL` (`guFogGenerateLinear`, `grFogTable`,
`grFogColorValue`). `Incubation.exe` reaches it through `0x00462030`, which
returns at once unless the display mode `[0x00512A78]` is 3, the
accelerator's, and its only caller is `aCreateBattleMap` `0x00457590`, the
campaign map's screen: black, linear, from 640 000 to 1 440 000 units
(`push 0x15F900; push 0x9C400; push 0; push 0; push 0` at `0x0045764F`). No
call on the battle view was found (**UNVERIFIED** beyond that one caller).

---

## 5. Sub-objects (`part_push` / `part_pop`)

`part_push` (`0x4062ad`) takes a 24-byte payload of six `i32`:

| Index | Field                  | Destination global |
|-------|------------------------|--------------------|
| 0..2  | translation `(x, y, z)`| `0x4142f0/f4/f8`   |
| 3     | vertex index base      | `0x414040`         |
| 4     | plane index base       | `0x414044`         |
| 5     | **shade index base**   | `0x414048`         |

Index 5 is the base for the `i16` shade array at `0x48cf48` that `load_shades`
(dispatch slot 2) writes — `lea edi, [ecx + ecx + 0x48cf48]` with
`ecx = [0x414048]` at `0x410f92`/`0x410f98`. No shipped record uses slot 2, so
the array is never populated, but the base is maintained for it exactly as the
vertex and plane bases are.

It also pushes the current matrix and position on a small stack; `part_pop`
(`0x406313`) restores them and zeroes the bases. `part_pop`'s operand points
back at the *same* 24-byte block, so those bytes are shared.

Inside a scope, `load_vertices` writes at the scope's vertex base and face
vertex indices are relative to it, so `global_slot = base + raw_index`. The
translation is applied at runtime by `joint_place` (`0x4060f0`) together with a
joint rotation read from the clone's animation buffer; at rest the rotation is
identity, so a static decoder can just add the translation.

Applying it is what makes the geometry check pass: with the translation, the
decoded vertex bounds fall inside the header bbox for **26 072 / 26 072**
records (max deviation 2 units); without it, the 135 multi-part records are off
by up to 3 680 units — exactly their part translations.

135 records use this mechanism (639 `part_push` commands across the three
streams, 213 in each). They are exactly the records whose `prototyp.dir`
`class_code` is 5, 6 or 7 (51 + 27 + 57 = 135).

---

## 6. What this settles in `docs/30`

*(reported here; `docs/30` itself is owned by another track and was not edited)*

### 6.1 `prototyp.dir` column 4 — **resolved: bounding/cull radius**

Column 4 is the record's first `u32`, which the engine uses as a
**bounding-sphere radius**:

* `FUN_00404bd0` @ `0x404be9` adds/subtracts it around the clone's position when
  testing against the view box, and again around the rotated depth;
* `FUN_0040508c` @ `0x405118` compares it against 24 000 and 80 000 to pick one
  of three scratch buffers.

The arithmetic objection recorded in `docs/30` §5.2 ("935 does not reconcile
with the bounding box") is resolved: the value is a sphere radius derived from
the *vertices*, not from the box corners. It is within 1 unit of `max |v|` in 22 127
records and within 2 units in 25 970; in the remaining 102 the stored radius
is always **larger**, never smaller (98 of those are the multi-part records,
whose parts sweep at runtime).

`_E3D_get_prototype_collision_radius` reads a **different** field, `i32` at
`+0x26`. In the shipped data the two are equal in 26 072 / 26 072 records, which
is why the export tools could not tell them apart.

### 6.2 `prototyp.dir` column 3 (`class_code`) — still an authoring tag, but constrained

No field in `prototyp.bin` equals `class_code`. It is an authoring-side
category. What the decoded records now prove about it:

| class | n      | mean verts | mean faces | matrix opcode in the render program | sub-parts |
|-------|--------|-----------|-----------|--------------------------------------|-----------|
| 0     | 7 248  | 16.8      | 14.0      | `matrix_clone_compose` (6 623) / `joint_rotate_3` (625) | no |
| 1     | 532    | 31.4      | 15.2      | `joint_rotate_3`                     | no |
| 2     | 595    | 28.3      | 17.3      | `joint_rotate_3`                     | no |
| 3     | 4      | 221.0     | 185.0     | `joint_rotate_3_alt`                 | no |
| 4     | 72     | 14.0      | 9.0       | `joint_rotate_3`                     | no |
| 5     | 51     | 22.1      | 13.2      | `joint_rotate_3`                     | **yes** |
| 6     | 27     | 20.0      | 9.0       | `joint_rotate_3`                     | **yes** |
| 7     | 57     | 31.0      | 22.0      | `joint_rotate_3`                     | **yes** |
| 8     | 363    | 12.4      | 8.5       | `joint_rotate_3_alt`                 | no |
| 9     | 147    | 6.0       | 1.0       | `matrix_set_a8ac`                    | no |
| 10    | 16 974 | 8.9       | 6.5       | `matrix_clone_compose`               | no |
| 11    | 2      | 24.0      | 18.0      | `select_late_pass` + `matrix_identity` + `nop` | no |

Hard correlations:

* **classes 5, 6 and 7 are exactly the 135 sub-object records** — no other class
  contains one, and every one of them is in 5/6/7.
* `flags` bit 1 is set exactly for classes 10 and the `Video` half of class 0
  (23 597 records); every other class has `flags == 0` except class 11
  (`flags == 5`).
* `depth_bias != 0` exactly for the 532 class-1 records, where it equals
  `cull_radius`.
* Only 8 distinct render-program shapes exist over the whole corpus, and each
  class maps into one or two of them.

That is enough to say `class_code` is a *category the exporter used*, correlated
with the animation/matrix opcode and with whether the object has parts, but it
is **not** derivable from the container and no name is invented for it.

### 6.3 Open question 13 — resolved

There is no trailer after the last record of a container: the part-info program
ends on the record's final byte for all 26 072 records, and the last record of
each of the 21 containers is no exception.

### 6.4 Open question 6 (`POSITION` axis order) — new evidence

Prototype-local space has the **third** component as the vertical axis
(positive up), not the second (see §2.5). This is evidence that the `.3DW`
`X_RIGHT_Z_INFRONT_Y_DOWN` label does not describe the frame the geometry is
authored in; it does not by itself decide the `.3DW` `POSITION` order.

---

## 7. Link to the rest of the data

* **`.3DW` clones.** `[CLO] … PROTOTYP <name>` resolves through
  `prototyp.dir`/`prototyp.din` (index = row) to the record specified here.
  `POSITION` places it; `cull_radius` and the bbox are what the engine tests
  against the view frustum.
* **`.cho` models.** Each `V100PartDesc.mesh` name is a prototype name; the part
  draws that record. 8 548 of 8 617 distinct mesh names in the 237 `.cho` files
  resolve into a `prototyp.din` somewhere in the corpus, and the resolved meshes
  have sizes appropriate to their names (see §1).
* **`texture.lib` / VISN.** Each textured face's trailing `u32` is an index into
  the world set's `texture.din`, hence into `texture.lib`, hence into a VISN
  256 × 256 picture (`docs/50`).

---

## 8. Tool usage

```sh
# whole-corpus validation (exit code 0 when everything checks out)
python3 tools/prototyp_parse.py --check --root gog_incubation

# what is in one container
python3 tools/prototyp_parse.py --list gog_incubation/WorldSet/World_A00/Objects/prototyp.din

# one record, structured
python3 tools/prototyp_parse.py --json --name A_50A.3DI \
    gog_incubation/WorldSet/World_A00/Objects/prototyp.din

# export geometry (OBJ) and an orthographic preview (PNG)
python3 tools/prototyp_parse.py --name CITY.003 \
    --obj tools/out/meshes/city_003.obj \
    --png tools/out/meshes/city_003.png --png-axis xz \
    gog_incubation/WorldSet/World_A00/Objects/prototyp.din

# the opcode / draw-kind tables
python3 tools/prototyp_parse.py --opcodes
```

Samples committed under `tools/out/meshes/`:

| File                         | What it is                                             |
|------------------------------|--------------------------------------------------------|
| `a_50a_3di.*`                | 9 vertices, 11 faces — the smallest worked example      |
| `city_003.*`                 | city block, side view — a recognisable skyline          |
| `city_003_top.png`           | the same mesh from above — a flat ground plan           |
| `level01d_001.*`             | level chunk, flat-coloured faces show the RGB565 decode |
| `l060ea00_3di.*`             | a prone figure prop                                     |
| `pr_004_oberkoerper.*`       | a character torso referenced by a `.cho` model          |

---

## 9. What is still open

Everything a remake needs in order to *render* a face correctly is now in §4.
What remains is either outside this container or unreachable from shipped data.

1. ~~**Joint angle encoding.**~~ **— CLOSED, and the buffer is written by the
   host, not through an export.** The encoding was never Charisma's, and it is
   not unknown: `joint_rotate_3` (`0x406002`) reads three consecutive `i16` and
   passes them straight to `0x411bf6`, the `RzRxRy` builder that masks each
   with `0xFFF` and indexes `TRIG.IMG` — so they are **Euler angles in the
   4096-unit circle**, the same convention as the `.lev` object rotations
   (`docs/30` §2.5, `docs/70`). `joint_rotate_1` and `matrix_from_angle` read
   one.

   The buffer is `object[0x1c]`, or the inline area at `object + 0x20` when
   that pointer is null, and it lives in the runtime `object_3d`
   (`docs/30` §2.12). Exactly one Eng3d export hands it out —
   `_E3D_get_object_joint_data_ptr` (ordinal 59), whose whole body is
   `lea eax, [eax + 0x40]; ret` — and there is no `_E3D_set_joint_*` anywhere
   in the 89-entry export table. Both hosts resolve that ordinal and **neither
   ever calls it**: `Incubation.exe` binds it into `0x004FA40C` and
   `iDesigner.exe` into `0x004AC56C`, and a byte-level scan of each `.text` for
   those addresses returns one hit each, the binding store itself. (For
   contrast, `_E3D_hide_object` gets 2 hits in `Incubation.exe` and
   `_E3D_init_3d_engine` 3.) See §10 for how the ordinals were mapped.

   **No setter is needed, because the host owns the record.** It writes the
   fields directly:

   * `0x00404F80`, the world-object builder, nulls the pointer at `+0x1C` and
     writes **triple 0** (`+0x20`/`+0x22`/`+0x24`) from the `.lev` record's
     rotation. So the 1 959 `joint_rotate_3`, 367 `joint_rotate_3_alt` and
     their part-info twins — every one of which uses operand `0` — execute
     against angles the game does supply. `joint_rotate_3 anim=0` **is** how a
     placed object gets its heading.
   * `aBlobs.cpp` does the same for a particle, and two of its update arms
     write **triples 1 and 2** (operands `6` and `12`) every tick: kind 42 for
     `A_PANEL.3DI`'s one part, kind 54 for `A_FIRE3.3DI`'s two. See
     [`28` §7.8](28-effects-and-sound.md), where this is checked.

   What no host writes is triples 1 and 2 of a **world** object, and 135
   shipped records have a part at operand `6` (78 of them a second at `12`) —
   29 distinct prototypes, 21 of which the missions place, 1 276 times in all:
   the animated fittings of §5. The
   list they live in comes from `aGetMemory`, which is `malloc` and does not
   clear, so what those parts do depends on what the allocation left; the block
   is taken once at level load and never reused, so in practice it is the zeros
   a fresh `malloc` hands back and the parts draw at the rest pose. That is
   what `--obj` exports, and it is **UNVERIFIED** in the only way that would
   settle it, which is running the game.

2. ~~**Draw kind `0x18`'s intent.**~~ **— CLOSED as unrecoverable; the
   behaviour is fully defined.** Its payload really is a full textured face
   (`0x4103cf`…`0x4103e7`) and it switches on camera distance, but the filler
   pointer its near branch calls (`[0x415088]`) is **written by nothing in the
   DLL** — not by any internal routine and not by any of the 89 exports, whose
   binding table §10.1 now enumerates in full — and it defaults to a bare `ret`.
   So in the software build only the flat fallback ever paints, and the Glide
   build independently forces `texture = -1` and material class 1.

   Both builds are therefore deterministic and a remake can reproduce them
   exactly. What cannot be recovered is *why* the slot was left unwired, and no
   shipped artefact can supply it: 0 faces use the kind, so there is no data to
   infer from, and the intent would have lived in the exporter or the source.
   **UNVERIFIED**, and unresolvable here.

3. ~~**The exact pixel path of the opcode-31 bank.**~~ **— CLOSED in engine
   terms.** The three span-visibility routines have now been read rather than
   inferred from their callers, and the answer is simpler than expected:

   | Routine | Instructions | s-buffer node allocations | Scratch block |
   |---|---|---|---|
   | `0x40DAF0` | 576 | **14** (`add dword [0x44FBB8], 0x1C`) | `0x44F850` |
   | `0x40E363` | 366 | **0** | `0x44F868` |
   | `0x40E872` | 366 | **0** | `0x44F880` |

   * **`0x40E872` is `0x40E363`, duplicated.** Disassembled with addresses and
     global references normalised, the two are identical **instruction for
     instruction, 366 of 366, zero differences**; the only substantive change is
     the 24-byte scratch block, `0x44F850 + k * 0x18`. Whatever the opcode-31
     bank does to spans, it is *exactly* what the deferred kinds do — the code
     was cloned so the late pass owns its own interpolator state and can be
     interleaved with the deferred pass without clobbering it.
   * **`0x40DAF0` is the only one that writes to the s-buffer.** All fourteen
     node allocations in the group are its; neither of the other two ever bumps
     the arena cursor. So the split is not "three quality levels", it is
     **occluding versus non-occluding**: the opaque kinds insert their spans and
     thereby hide what comes later, while the deferred kinds and the opcode-31
     bank clip *against* the existing list without adding to it — they can be
     hidden, but they cannot hide anything.

   That is fully consistent with the Glide build, where the same opcode moves
   the prototypes into material class 6 and the flush replays class 6 after the
   chroma-keyed pass (§4.5). Both builds therefore mean the same thing by
   opcode 31, and a remake has a complete specification.

   What remains genuinely unrecoverable is the *artistic* intent for
   `L096EE00.3DI` / `L096EF00.3DI` — why those two level chunks were authored as
   a non-occluding late pass. No shipped artefact records that.

4. **Glide destination blend factor `0xf`** in the alpha-minus state block
   (`0x402976`). `0xf` is `GR_BLEND_ALPHA_SATURATE` / `GR_BLEND_PREFOG_COLOR` in
   Glide 2.x. The *software* build settles what the kind means (saturating
   subtract, §4.4); what the Voodoo hardware did with that particular factor is
   not established here.

5. ~~**The exporter-side name and intent of `depth_bias`.**~~ **— CLOSED as
   unrecoverable, with the sweep that proves it in §2.4.1.** Four searches
   (no export reads `+0x1c` outside the sort-key site; no keyword in
   `iDesigner.exe` in ASCII or UTF-16LE including all 16 dialog templates; no
   keyword in any of the 35 shipped PE files except third-party Glide z-bias
   symbols, which are an unrelated concept; and the editor is not the exporter
   — it never opens `prototyp.*` at all). The exporter did not ship, so the
   authoring-side name cannot be recovered from the product. The engine side is
   complete, and nothing a remake does depends on the name.

6. ~~**Why 135 records set `collision_program = 0`.**~~ **— CLOSED, and it was
   never a per-object choice.** The correlation is exact, both ways, over the
   whole corpus:

   > `collision_program == 0` **if and only if** the record contains at least
   > one `part_push` scope — **135 of 26 072 records, zero exceptions in either
   > direction**.

   The two facts are independently derived, which is what makes the biconditional
   evidence rather than an artefact: `collision_program` is the `i32` at `+0x2A`,
   while the part count comes from walking the command stream for opcode 16.
   Neither is computed from the other.

   So the zero is not an artist deciding an object should be walk-through; it is
   the **exporter declining to emit a collision program for any multi-part
   record**. The earlier reading — that the affected objects are all animated
   decoration — is a *consequence*: the shipped multi-part records happen to be
   the animated flames, panels and level fittings. Had a solid object been built
   from sub-objects, it would have come out non-solid too.

   Engine behaviour is unchanged and already verified (§3.2): the collision
   entry returns "no collision" immediately and the stream that follows is dead
   data. A remake reproducing the original's collisions must reproduce this,
   including the consequence that multi-part props are not solid.

   Reproduce with `python3 tools/prototyp_parse.py --check --root gog_incubation`
   and comparing `part_count` against `collision_program` in the `--json` output.

7. ~~**Runtime confirmation was not obtained.**~~ **— CLOSED as not needed.**
   §10 assessed a harness and now records why nothing here depends on one: the
   item it was wanted for — the three span-visibility routines and the
   opcode-31 bank, item 3 — was closed by reading them instead, and the only
   thing still open (item 4) is a question about Voodoo silicon that no
   software-build harness could answer. The pixel path is specified from two
   independently compiled renderers that agree; a harness would confirm rather
   than decide. *(Item 8, added 2026-09-21, is the first question here that
   a frame read out of the live process would decide.)*

8. **Why the iris shows five blades.** §4.7 reads `0x40DAF0` as "same
   tag, no depth test, the stored span wins" and the leaf walker as
   in-order, which for `LEVEL09A.005` predicts two blades over the backing;
   the retail game shows five. Everything on the static path has been
   re-read against that: the leaf order (`0x405232`), the run-list signs
   (negative draws, positive skips, empty skips the line -- `0x40890B`..
   `0x40894D`), the tag's eleven references, the per-polygon texture hook
   `0x40ED90`, the frame-start initialiser `0x404AA9`, the two draw lists
   and the sort `0x404FC0` between them, the face records byte for byte.
   None of it reorders faces inside a leaf or exempts a span from the
   same-tag arm. The mechanism is therefore on a path not read here -- the
   2-D/3-D clip table variants (§4.5 (a)), which a 52-metre chunk almost
   always draws through, are the first candidates. The way to settle it is
   a frame read out of the live process under `tools/dbgcall`: the software
   back buffer is `[Eng3d.dll+0x14FAC]`, `[Eng3d.dll+0x14FBC]` bytes per row,
   and a save on `_C_154` with the camera on the wall would show which faces
   the engine painted, in what order, by poking one face's texture id at a
   time. Until then the remake follows the observation for a face inside
   another and the reading for a partial overlap (§4.7), and the 47 pairs
   whose lowest common ancestor splits on some other plane -- whose walk
   order follows the camera -- take the tree's own order: `L060EA00`,
   `LEVEL01D.002` and `MAP2.006` in `World_A00`, `L072E*` in `E00`/`F00`,
   `L013EH00` in `H00`, and eighteen sequence models.

9. **What the Glide build's frame looks like.** §4.8 reads its texture
   state -- bilinear, clamped, one LOD -- from the allocation call, but the
   frame is unobserved: what the Voodoo chroma key (`grChromakeyMode`) does
   to a bilinear-filtered edge of a kind `0x14` grille, and what the 16-bit
   framebuffer's dither adds, cannot be read from `ENG3DFX.DLL`. Tried
   2026-10-12 on Wine 11.17: the bundled nGlide loads (`glide2x.dll`,
   `ENG3DFX.DLL`) and then stops where [`91` §6](91-wine-runtime-probes.md)
   recorded, `NtUserChangeDisplaySettings` returning -2 and
   `GL_INVALID_FRAMEBUFFER_OPERATION`, with no game window. A Windows host
   with nGlide, or a real Voodoo, would answer it.

---

## 10. On running the real rasteriser

`tools/wine_visn` proves the shipped `Eng3d.dll` can be driven under Wine on
this host, and the obvious next step would be to rasterise one face of a known
draw kind and read the pixels back. It was assessed and **not attempted**, for a
reason that is worth recording:

* the seven `_E3D_c_draw_*` exports that would have made this a ten-line harness
  — `_E3D_c_draw_polygon`, `…_transparent`, `…_gouraud_polygon`,
  `…_texture_polygon`, `…_perspective_texture_polygon`,
  `…_texture_polygon_transparent`, `…_texture_polygon_masked` — are **`ret`
  stubs in the shipped software build**: `0x402273` calls `0x410e72`, `0x402287`
  calls `0x410e74`, and so on into a run of ten single-byte `c3`s at
  `0x410e71`…`0x410e7a`. They were compiled out. (Their *names* are still
  evidence, and §4.4 uses them.)
* the internal fillers can be called directly, but only after `~15` globals are
  set up that no export writes individually (framebuffer `0x414fac`, pitch
  `0x414fbc`, bit depth `0x414fb0`, the s-buffer state at `0x43b478`, the clip
  window, the working vertex array and the pointer bank at `0x415064`);
* the alternative — driving the whole public pipeline (`_E3D_init_3d_engine` →
  `_E3D_init_3d_screen` → `_E3D_object_3d_check_in` → `_E3D_draw_sorted_objects`)
  — additionally needs the undocumented **clone structure**. The 8-argument
  `_E3D_init_3d_screen` is **no longer a blocker**; see §10.1.

Weighed against that, the static evidence in §4.4 is unusually strong: every
slot is read in **two independently compiled renderers** that agree, three of
them are labelled by Blue Byte's own export names, the Glide constants were
checked against a real `glide.h`, and the software pixel operations are simple
enough to read exactly (`dst>>1 + colour>>1`, `test ax,ax; je`, saturating add
with an OR-mask table, saturating subtract with an AND-mask table). A harness
would confirm rather than decide.

**What a harness would still be worth doing for.** The previous revision named
the three span-visibility routines and the opcode-31 bank here, on the grounds
that reading the assembly had not produced a confident answer. That is no
longer true: §9 item 3 is closed, and it was closed by reading them —
`0x40E872` turned out to be `0x40E363` duplicated instruction for instruction,
and only `0x40DAF0` writes to the s-buffer, which settles the split as
occluding versus non-occluding. **Nothing in this document now depends on a
harness.** The one remaining open item, the Glide destination blend factor
`0xf` (§9 item 4), is a question about *Voodoo hardware* rather than about this
code, so a software-build harness could not answer it either.

### 10.1 How the hosts bind Eng3d — by ordinal, and how to undo it

The earlier revision recorded that `Incubation.exe` "resolves every Eng3d export
dynamically … so the decompilation contains no named call site". The first half
is right and the second is now false, because the binding is **by ordinal**, and
ordinals are recoverable exactly.

`FUN_00401000` (`a3DEngine.cpp`) does, 86 times:

```asm
push  0x4bfb90            ; the literal string "1"
call  [atoi]              ; -> 1
push  eax                 ; MAKEINTRESOURCE(1): GetProcAddress by ordinal
push  [hEng3d]
call  [GetProcAddress]
mov   [0x4fa4e8], eax     ; the global for ordinal 1
```

and on failure prints `"Function Id N not found!"`. That is why neither host
contains a single `_E3D_*` string. Pairing each `atoi` literal with the `mov
dword [g], eax` that follows it gives the complete **ordinal → global** map;
`Eng3d.dll`'s export table gives **ordinal → name**. Composing them names every
Eng3d entry point in the host, after which a byte-level scan of `.text` for each
global's address counts its call sites — one hit means "bound, never called".

`Incubation.exe` binds ordinals **1–86 contiguously**. Ordinals 87–89
(`_E3DCARD_set_texture_page_size`, `_E3D_decode_picture_halve_size`,
`_E3D_get_engine_version`) are never bound: they were added to the DLL after the
host was built. Selected results:

| Ord | Export | Global | Call sites |
|---|---|---|---|
| 1 | `_E3D_init_3d_engine` | `0x4FA4E8` | 2 |
| 3 | `_E3D_init_3d_screen` | `0x4F9F14` | 2 |
| 9 | `_E3D_object_3d_check_in` | `0x4FA510` | 3 |
| 10 | `_E3D_draw_sorted_objects` | `0x4FA46C` | 2 |
| 17 | `_E3D_get_part_info` | `0x4FA48C` | **0** |
| 33 | `_E3D_c_draw_polygon` | `0x4FA4AC` | **0** |
| 36 | `_E3D_c_draw_texture_polygon` | `0x4F8524` | **0** |
| 53 | `_E3D_init_vision` | `0x4FA484` | 2 |
| 54 | `_E3D_decode_picture` | `0x4FA498` | 1 |
| 55 | `_E3D_get_number_of_sub_objects` | `0x4FA474` | **0** |
| 56 | `_E3D_add_sub_object` | `0x4FA504` | 1 |
| 57 | `_E3D_replace_sub_object` | `0x4F9F44` | **0** |
| 58 | `_E3D_remove_sub_object` | `0x4F8528` | 1 |
| 59 | `_E3D_get_object_joint_data_ptr` | `0x4FA40C` | **0** |

The zeroes corroborate §4.4 and open item 1 independently: the game never calls
the `_E3D_c_draw_*` entry points (they are `ret` stubs), never queries part or
sub-object counts, never replaces a sub-object, and never touches joint data.

**`_E3D_init_3d_screen`'s eight arguments** follow from the export body
(`0x401ff8`), which shuffles them into registers for `0x404730`, and from what
`0x404730` stores. Defaults in the DLL image are given in brackets:

| # | Meaning | Global |
|---|---|---|
| 1 | viewport **x** [0] | `0x414FA0` |
| 2 | viewport **y** [0] | `0x414FA4` |
| 3 | viewport **width** [320] | `0x414FD8`, and `width − 1` → `0x414FC0` |
| 4 | viewport **height** [200] | `0x414FDC`, and `height − 1` → `0x414FC4` |
| 5 | **focal length** [256] | `0x414FE8`; `1/f` → `0x414FF0` |
| 6 | **pitch**, bytes per scanline [640] | `0x414FBC` |
| 7 | **framebuffer base** | `0x414FA8` |
| 8 | **s-buffer span-node arena** — both s-buffer initialisers (`0x40DA20`, `0x40EF02`) copy it into the allocation cursor `0x44FBB8`, which `0x40DAF0` bumps by `0x1C` per inserted span (§9 item 3). The game passes the first dword of a 74-byte record in the table at `0x50DE54`; which field that is was not traced | `0x414FB4` |

`0x414FAC`, the framebuffer pointer the fillers actually use, is then derived:
`base + y * pitch + x * 2` — confirming 16 bits per pixel and confirming
arguments 1, 2, 6 and 7 against each other. The game's own call
(`fcn.00403460`, `0x4034C8`) passes width in argument 3 and a focal length
computed from that same width — `width * 10/13`, or `width / n` on the other
branch — which is a third independent check on the ordering.

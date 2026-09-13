# `.LIB` + `.pal` — 2D sprite libraries and palettes

**Status: fully solved, corpus-validated, visually verified.**

`Libs/*.LIB` are the game's 2D "shape libraries" — every cursor, icon, font
glyph, medal, minimap tile and UI element. They pair with a same-named `.pal`
file in `Graphics/` that supplies the 256-colour palette.

Corpus: **58/58 shape libraries parse and extract** (2296 sprites) with
`tools/lib_extract.py`. The 21 remaining `.lib` files in the game are
`texture.lib` VISN containers, an unrelated format — see
[`50-visn-textures.md`](50-visn-textures.md).

---

## 1. Evidence

The format is Blue Byte's own `aLIB` library (`C:\aProject\aLIB\aLibTools.cpp`).
Two debug format strings in `Incubation.exe` describe it directly:

```
Type:%d / Entries:%d
%d/[%d]_%d_(W_%d,H_%d) (dX_%d,dY_%d)
```

**`aLibTools.cpp` is the *writer*, not the reader.** Partitioning `.text` by the
`__FILE__` each function pushes ([`90` §2.1](90-binaries-and-source-layout.md))
bounds the module at `0x00445DC0`…`0x00447BF2`, and the 28 callee names it
pushes are an authoring tool end to end: `LibMaker`, `aLoadBitmap`,
`aLoadBitmapInfos`, `aCreateWinFont`, `aPrintWinText`, `aCreateBitmap`,
`FrameRect`, `GetWindowDC`, `WriteFile`, `aWriteFile`, `aOpenFile`. The element
accessor that returns a sprite's pixel pointer — `0x00446180`, which computes
`lib + data_offset + element[i].data_offset` — has exactly **two callers, both
inside a dialog procedure** (`0x00444E00`, which calls `GetDlgItem` and
`SendMessageA`).

So the retail `Incubation.exe` ships **LibMaker**, the tool that built these
libraries out of bitmaps, the same way it ships the map editor
([`10` §4.6](10-lev-mission-format.md)) and the mission-script template. That
is worth knowing twice over: it names the writer responsible for the
uninitialised `delta_y` documented in §2, and it means the *game's* sprite
drawing is somewhere else entirely — see §2's transparency question.

*(Narrowed 2026-09-05 by [`43` §3.4](43-battle-hud.md): "somewhere else
entirely" was too strong. The **game's own blitter is inside this range** --
`fcn.004475D0(lib, index, dst, pitch, x, y)`, with 79 callers across the
interface, the ground overlay and the panel, and the two anchor readers
`0x00446200`/`0x00446220` beside it. `aLibTools.cpp` holds the writer and the
reader both; what the `__FILE__` partition bounded was the file, not the
tool.)*

The game still ships the authoring tool: `Incubation.exe -debugx` opens a
developer menu with a **Librarytool** entry (`aLibTool.cpp`) that opens and
saves these files. It does *not* open `texture.lib`.

---

## 2. Layout

```
Header (20 bytes)
    u32 library_type    always 0xFF - a hardcoded literal, not a discriminator
    u32 element_count
    u32 used_size       20 + 36*element_count + sum(element data_size)
    u32 table_offset    always 20
    u32 data_offset     20 + 36*element_count

Element table: element_count records of 36 bytes each

Pixel blob: raw 8-bit palette indices, elements concatenated in index order
```

### Element record (36 bytes)

| Offset | Type | Meaning |
|---|---|---|
| `+0x00` | `u32` | `element_type` — always `2` in shipped data |
| `+0x04` | `u32` | `width` |
| `+0x08` | `u32` | `height` |
| `+0x0C` | `u32` | **Runtime scratch slot.** On disk this holds leftover heap pointers (values such as `0x81CCB500`, `0x00069648`). It is uninitialised memory and must be ignored. |
| `+0x10` | `u32` | `data_offset` — byte offset into the pixel blob, cumulative |
| `+0x14` | `u32` | `index` — the record's own 0-based index |
| `+0x18` | `u32` | `data_size` — always exactly `width * height` |
| `+0x1C` | `i32` | `delta_x` — **anchor point**, X, measured from the sprite's top-left (see §2.1) |
| `+0x20` | `i32` | `delta_y` — **anchor point**, Y, same origin |

### 2.1 `delta_x` / `delta_y` are the anchor point

The pair is the sprite's **anchor (hot spot), measured in pixels from its
top-left corner**. The engine blits so that the anchor lands on the caller's
position, i.e. `top_left = position - (delta_x, delta_y)`.

This was settled empirically on `Libs/mouse.LIB`, where the meaning is visible:
marking `(delta_x, delta_y)` on each of the eleven cursors puts the mark exactly
on the fingertip of the pointing hand, on the tip of each of the eight
directional arrows, and on the centre of the magnifier's lens. No other reading
of the field produces that.

Reproduce it with:

```bash
python3 tools/lib_extract.py gog_incubation/Libs/mouse.LIB --hotspots \
        -o tools/out/hotspots --game-root gog_incubation
```

The font case (§5) is the same convention seen from a different anchor: for a
glyph the caller's position is the pen point on the baseline, so `delta_y` is
the ascent and `top = baseline - delta_y`. `delta_x` is 0 for every glyph
because the pen x *is* the left edge.

**But the field is not uniformly meaningful, and one third of the corpus stores
garbage in it.** Classifying all 58 shape libraries by what their anchors look
like:

| Class | Libraries | What the values are |
|---|---|---|
| Anchor inside the sprite | 9 (`mouse`, `map`, `inv`, `dir`, `mp1`, `sm`, `uequip`, `uweapons`, `font_3`) | a genuine hot spot, as in §2.1 |
| Anchor outside the sprite | 15 (`buttons`, `mi`, `medal`, `addons`, `loadsave`, `font_0`–`font_2`, …) | plausible **screen placement** — `buttons`, `mi` and `medal` cluster around x 267–320, y 249–259, i.e. near the edges of a 320 x 240 display |
| **Uninitialised** | **34** (the 33 `Libs/Items/item_*.LIB` plus `options.LIB`) | not data — see below |

In all 34 — the 33 `Libs/Items/item_*.LIB` plus `options.LIB`, which behaves
like them here and in the transparency measurement below — `delta_x` is a
constant 310 but **`delta_y` is uninitialised memory**: it differs from file to
file with values like
`758384216`, `1947469400`, `1526466297`, `-1714682119`, `-1960573191`. That is
the same failure mode as the documented `runtime_ptr` field at `+0x0C` — the
writer serialised a struct without clearing it.

A remake must therefore **range-check both components before using them**, and
must not assume a library's anchors mean anything at all. `tools/lib_extract.py`
exposes the raw values without interpreting them.

Pixel data is **uncompressed**: `data_size == width * height` holds for every
one of the 2296 elements in the corpus. There is no RLE and no transparency
mask.

**Transparency is keyed on palette index `0`, but only 24 of the 58 shape
libraries contain that index at all.** A previous revision stated "index 0 is
the transparent colour" as a flat fact; measured over the corpus it holds for
24 libraries and is vacuous for the other 34 — the 33 `Libs/Items/*` libraries
and `options.LIB` have no index-0 pixel anywhere. Their backgrounds are a
different index entirely, and a large one: `item_e0` is 85.3 % index 15,
`item_w0` 80.2 % index 1, `item_w13` 85.3 % index 254, and in each case the
paired palette maps that index to near-black.

Which index (if any) the blitter keys for those is **UNVERIFIED**, and three
sweeps narrow *where* the answer is not:

* **The drawing code is not in `aLibTools.cpp`.** That module is LibMaker, the
  writer (§1), and its pixel accessor's only callers are an editor dialog.
* **It is not DirectDraw colour-keying.** `aDDraw.cpp` (`0x00432DA7`…`0x00434448`)
  pushes `DirectDrawCreate`, `CreateSurface`, `CreateClipper`, `SetClipper`,
  `SetCooperativeLevel`, `SetDisplayMode`, `GetPixelFormat`, `GetAttachedSurface`
  and **`DD_Lock`** — and no `SetColorKey` and no `Blt`. The game locks the
  surface and copies pixels itself, so transparency is whatever its own inner
  loop does.
* **That loop is not findable by its idiom.** Sweeping all of `.text` for the
  classic `mov r8, [mem]; test r8, r8; jz` skip pattern and attributing each hit
  to its module returns **zero hits in `aLibTools.cpp` and `aDIB.cpp`** and one
  in `aDDraw.cpp`, which is a string comparison. Whatever the copy loop looks
  like, it is not that.

Settling it therefore means finding the drawing path in another module — the
GUI and screen-tool modules are the candidates — which belongs to the interface
work, the replacement-interface contract ([`29`](29-interface-contract.md)), not to this
document. The better route may be the writer rather than the reader: LibMaker
is in the binary and can be read.

*(Settled 2026-09-05, [`43` §3.4](43-battle-hud.md): the drawing path was in
**this** module after all. `fcn.004475D0` is the blitter, its inner loops skip
source index 0 with `cmp al, 0` (`0x0044772D`) for every library, and the
idiom sweep above missed it because the test is on `al` after a byte load, not
`test r8, r8` on the loaded register. §6's two items are closed on it.)*

`lib_extract.py` therefore writes a `tRNS` entry **only for libraries that
actually contain index 0** and writes the rest fully opaque, rather than
emitting an entry pointing at a colour the image never uses. `--check` lists
both groups.

Some files carry 1–3 padding bytes after the pixel blob, which is why
`used_size` is the authoritative content length rather than the file size.

---

## 3. `.pal` palettes

A `.pal` file is a plain **Windows BMP**. The bitmap content is a tiny dummy
thumbnail (1x1 up to 100x80) that the game never displays; the payload is the
256-entry BGRA colour table in the BMP header, at file offset 54 for the
standard 40-byte `BITMAPINFOHEADER`.

`Graphics/mouse.pal` is the one exception: its table has 254 entries, so a
loader must derive the entry count from `pixel_offset - 14 - dib_header_size`
rather than assuming 256, and pad the remainder.

Most palettes pair with libraries **by basename** (`mouse.LIB` ↔ `mouse.pal`;
`medal`/`uicons` match the differently cased `Medal.pal`/`UIcons.pal`). The
whole `Libs/Items/` set does not, and the pairing there does not have to be
guessed — **the game builds both names from the same id**, side by side:

```asm
0x00458B98   push str."%sItems\Item_e%d.lib"
0x00458BB2   push str."%sItems_e.pal"          ; unconditional

0x00458809   push str."%sItems\Item_w%d.lib"
0x0045882B   add  eax, -13
0x0045882E   cmp  eax, 3
0x00458831   ja   0x458891                     ; -> "%sItems_w.pal"
             jump table: 13 -> "%sItm_w_13.pal"  14 -> "%sItm_w_14.pal"
                         15 -> "%sItm_w_15.pal"  16 -> "%sItm_w_16.pal"
```

So `Item_e<N>.lib` always uses `Items_e.pal`, and `Item_w<N>.lib` uses
`Itm_w_<N>.pal` for **N ∈ {13, 14, 15, 16}** and `Items_w.pal` otherwise.
`lib_extract.py` encodes exactly that; before it did, 40 of the 58 libraries
fell back to a greyscale ramp and the six `Graphics/items_*.pal` /
`itm_w_*.pal` files were read by no tool at all.

Seven libraries still resolve no palette, and that is correct rather than a
gap: `font_0`–`font_3` are loaded through `aCreateLibFont` (`aLIB\aFont.cpp`,
`0x00439D66`) and `addons`, `addons2`, `uicons2` through `aLoadShapeLibrary`
with no palette call beside them — all of them inherit whatever screen palette
the current BMP set. `--check` now lists them instead of falling back silently.

---

## 4. Tooling

- `tools/inclib/liblib.py` — library parser
- `tools/inclib/palette.py` — `.pal` loader
- `tools/inclib/png.py` — dependency-free PNG writer
- `tools/lib_extract.py` — CLI

```bash
python3 tools/lib_extract.py gog_incubation --check           # 58/58
python3 tools/lib_extract.py gog_incubation -o tools/out/sprites
python3 tools/lib_extract.py gog_incubation/Libs/mouse.LIB --json
```

Extraction of the whole corpus yields 2296 PNGs. Spot-checking the mouse cursor,
UI icons, font glyphs, medals and weapon icons against the game's appearance
confirms both the pixel layout and the palette pairing.

---

### 4.1 `library_type` is a constant, not a format selector

`aCreateShapeLibrary` (`Incubation.exe` `FUN_00446260`, the writer behind the
LibTool dev menu) builds the 20-byte header on its stack and writes it in one
call:

```c
local_7c = 0xff;                        /* library_type */
local_78 = 0;                           /* element_count, filled in later */
FUN_00438bf0(handle, &local_7c, 0x14);  /* write the 20-byte header */
```

The `0xFF` is an immediate in the writer — there is no code path that produces
another value, and no loader branch was found that tests it. The debug string
`Type:%d / Entries:%d` prints it, which is what made it look like a variable.
The same applies to the per-element `element_type`, constant `2`.

A remake can write `0xFF` / `2` unconditionally and ignore both on read.

---

## 5. Fonts — solved

`Libs/font_0.LIB` … `font_3.LIB` are proportional bitmap fonts. Each holds
exactly **224 elements**, one per **byte** from 32 to 255 of the release's
code page — cp1252 for the GOG release, cp1251 for the 1C Russian one, whose
four fonts have the same 224-element shape with Cyrillic glyphs in the upper
half (verified by hand 2026-09-13, no automated check):

```
element_index = byte - 32
```

The remake's cache writes both `byte` (the element's byte) and `codepoint`
(the Unicode code point that byte stands for under the release's page,
`inclib.language.codepoint`; an undefined byte maps to its own value), and
`GameFont` registers glyphs by the code point
([`92` §7.6](92-remake-architecture.md)).

`delta_y` is the glyph's **ascent**: the top pixel row sits at
`baseline - delta_y`. Within a font, `height - delta_y` is a constant — the
**descent**, the rows reserved below the baseline for `p g q j` and `_`:

| Font | Glyphs | Descent | Cap height (`A`) |
|---|---|---|---|
| `font_0` | 224 | 3 | 10 px |
| `font_1` | 224 | 2 | 10 px |
| `font_2` | 224 | 3 | 17 px |
| `font_3` | 224 | 2 | 8 px |

A renderer must derive the descent per font rather than assume a value.

`delta_x` is a left side bearing and is **0 for every glyph except the two
blank ones** — space (index 0) and NBSP (index 128, cp 160) — which carry
`delta_x = 3`. Those two are also the only glyphs exempt from the
constant-descent rule.

Verified with `python3 tools/font_render.py --check gog_incubation` (exits 0;
896 glyphs across the four fonts, zero violations) and visually by rendering
text: `tools/out/fonts/_sample.png` shows all four fonts on a correct baseline
with descenders and the underscore hanging below it.

The fonts ship without a companion `.pal`, so glyph pixel values are indices
into a caller-supplied palette. Rendering them against a greyscale ramp
produces near-black text.

### 5.1 A glyph has **two** ink levels — **[code] `0x00447900`**

*(Added 2026-09-08.)* The four faces use exactly the values 0, 1 and 2 —
`font_3` only 0 and 1 — and the blitter maps the value **straight onto the
caller's colour array** rather than treating it as an intensity. Its 16-bit
path, the one every shipped display mode but the first runs
([`97` §23.4](97-slice-5-report.md)), is a four-arm ladder:

```c
/* 0x00447AD6 */  for (each source pixel p) {
                      if (p == 0 || p == 3 || p == 4) continue;   /* skipped */
                      *dst = (p == 1) ? colour[0] : colour[1];
                  }
```

The 8-bit path at `0x00447A23` writes the same ladder out in full, `1 ->
colour[0]`, `2 -> colour[1]`, `3 -> colour[2]`, anything else `colour[3]`.

So **index 1 is the glyph's body and index 2 is its antialiasing.** What
settles that it is coverage rather than an outline is the ramps
`aPrintGUITextBox` supplies (`0x0043E458` and `0x0043E47A`): the body ramp is
`0x94B2, 0x528A, 0x0841, 0` and the alert one `0xF800, 0x6000, 0x0800, 0`, so
`colour[1]` is **0.55** of `colour[0]` in the first and **0.39** in the second
— a mid-tone in each, on the pixels that sit diagonally against a stem:

```
font_0 'o'          font_0 'M'          # index 1     o index 2
o###o               ##...##
#o.o#               ##o.o##
#...#               #o#o#o#
#o.o#               #.o#o.#
o###o               #.....#
```

Painting every non-zero index solid — which both `tools/font_render.py` and
the remake's `GameFont` did until this was read — fattens every stem by a
pixel and fills the counters of `a`, `o` and `e`, which is why the remake's
text read as a different, blobbier face than the original's.

**All three ramps are now measured, and there are two fractions, not one.**
`{#0}` is `0xFFFF, 0x632C, 0, 0` and `{#2}` is `0xF800, 0x6000, 0x0800, 0` —
both 12/31 — while `{#1}` is `0x94B2, 0x528A, 0x0841, 0`, which is 10/18
([`24` §4.2](24-briefing-text.md)). The remake bakes the fraction into the
atlas, so it builds each face twice and the briefing renderer binds the pair
carrying the body ramp's own shade to the theme's italic slots, `{#1}` spans
being written `[i]`; the shade is written **opaque**, because the original
stores `colour[1]` into the frame buffer and never blends. `interface_tables.py`'s
`font.*` checks read the ladder, the eight colour writes, both markup ramps and
all sixteen writes of the default one back out of the executable.

`tools/font_render.py` writes index 0 transparent, index 1 white and index 2
the default ramp's shade.

```bash
python3 tools/font_render.py font_2 "Incubation" -o out.png
python3 tools/font_render.py --check gog_incubation
```

---

## 6. Open questions

**None.** Both items this section carried are closed by
[`43` §3.4](43-battle-hud.md) (2026-09-05):

1. ~~Which of the 15 "anchor outside the sprite" libraries carry a deliberate
   screen placement~~ — **closed: none of those are read.** The anchors
   `+0x1C`/`+0x20` are read only by `0x00446200`/`0x00446220`, and only the
   callers that subtract them before the blit consult them: the ground overlay
   (`fcn.00417E70`), the unit panel's icons, the radar's marks and the cursor.
   The button columns (`mi`) and the command pad (`ui`) blit at their slot's
   top-left and never read theirs, and no shipped path reads `buttons`' or
   `medal`'s either. The out-of-range values are uninitialised memory, as §2
   suspected, and the pixels are unaffected.

2. ~~**Which palette index the blitter keys as transparent for the 34 libraries
   that contain no index 0**~~ — **closed: index 0, always.** The blitter is
   `fcn.004475D0` in this very range, and its inner loops test `cmp al, 0`
   (`0x0044772D`) on every source byte for every library; the 16-bit path then
   maps through the remap table `fcn.00447BB0` sets. The 34 libraries with no
   index 0 are therefore simply opaque, which is exactly how `lib_extract.py`
   writes them. `hud_tables.py --check` pins the test and the arithmetic.

   The search this entry once described — not `aLibTools.cpp`, which is
   LibMaker the writer; not DirectDraw colour-keying, `aDDraw.cpp` having
   neither `SetColorKey` nor `Blt`; not the `test r8, r8; jz` idiom — ended
   where it was pointed: the copy loop is `fcn.004475D0`, reached from the
   interface ([`43` §3.4](43-battle-hud.md)), which is where §2 expected a
   drawing path to be.

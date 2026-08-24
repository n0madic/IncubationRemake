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

Which index (if any) the blitter keys for those is **UNVERIFIED** — the sprite
blitter is hand-written assembly in `aDDraw.cpp`/`aDIB.cpp` with no trace
strings, and nothing in the shipped data settles it. `lib_extract.py` therefore
writes a `tRNS` entry **only for libraries that actually contain index 0** and
writes the rest fully opaque, rather than emitting an entry pointing at a colour
the image never uses. `--check` lists both groups.

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
exactly **224 elements**, one per cp1252 code point from 32 to 255:

```
element_index = codepoint - 32
```

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
produces near-black text; `tools/font_render.py` writes a flat white with index
0 transparent instead.

```bash
python3 tools/font_render.py font_2 "Incubation" -o out.png
python3 tools/font_render.py --check gog_incubation
```

---

## 6. Open questions

1. Which of the 15 "anchor outside the sprite" libraries carry a deliberate
   screen placement and which are simply more uninitialised memory that happens
   to fall in a plausible range. The `buttons` / `mi` / `medal` clustering
   around the edges of a 320 x 240 screen is suggestive but not proof, and no
   shipped code path was traced that reads those particular values.
   **UNVERIFIED.** Note this only affects placement convenience: the sprite
   pixels themselves are unambiguous.

2. **Which palette index the blitter keys as transparent for the 34 libraries
   that contain no index 0** (the 33 `Libs/Items/*` and `options.LIB`). Index 0
   is right for the other 24 and is what `lib_extract.py` uses there. The
   blitter itself is hand-written assembly in `aDDraw.cpp`/`aDIB.cpp` with no
   trace strings to locate it by, and no shipped data distinguishes "keyed on a
   different index" from "drawn fully opaque". §2. **UNVERIFIED**; the tool
   writes those libraries opaque rather than guessing.

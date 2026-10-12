# `VISN` — the 3D texture codec

**Status: fully solved and byte-exact against the game's own decoder.**
All 723 records in all 21 containers decode to output that is identical, byte for
byte, to what the shipped `Eng3d.dll` produces when it is loaded and called
directly — through both the full-size and the half-size entry point. Mode 0,
escape widths 1–12 and the whole quality range, none of which occur in retail
data, were verified the same way against synthesised records.

`VISN` is Blue Byte's own still-image codec, used for every texture the Eng3d
renderer maps onto 3D geometry — world scenery in `WorldSet/*/TEXTURES/` and
cutscene backdrops and character portraits in `Video/*/Textures/`.

It is **JPEG with a different entropy layer**. The transform, the quantisation
tables, the zigzag order and the AAN scale factors are all standard JPEG /
IJG components; only the bitstream syntax, the container and the colour
back-end are custom — and they are considerably *simpler* than JPEG's.

Corpus: **21 containers, 723 records, 100 % decoded** with
`python3 tools/visn_decode.py gog_incubation --check` (exits 0), and **723 / 723
byte-identical to `Eng3d.dll`'s own output** with
`python3 tools/wine_visn/visn_compare.py gog_incubation --build-dir DIR`. The
reusable codec lives in `tools/inclib/visn.py`; the harness that calls the
original decoder lives in `tools/wine_visn/`.

---

## 0. Provenance and how to read this document

The specification was first published by the **Incubation-HD-Renderer**
project (MIT licence), which recovered it by disassembling `Eng3d.dll`:

> <https://github.com/Sonatix/Incubation-HD-Renderer> — file `VISN-FORMAT.md`

No code from that project was copied. `tools/inclib/visn.py` is an independent
implementation written from the prose specification, and every constant table
in it was **re-extracted first-hand from the shipped `Eng3d.dll`** at the byte
offsets named below rather than transcribed.

Each section is tagged:

| Tag | Meaning |
|---|---|
| **[CONFIRMED]** | Independently verified here, against the shipped data or the shipped DLL bytes. |
| **[CONFIRMED via runtime]** | Verified by *executing* `Eng3d.dll` and diffing its output against ours. The strongest tag in this document. |
| **[INFERRED]** | Not directly read out of the binary, but the only reading consistent with all 723 records decoding cleanly. |
| **[PRIOR ART]** | Taken on the prior art's word. Not verified here. |

**The caveat this document used to open with is now closed.** Earlier revisions
warned that the decoder had never been compared against the game's own, because
`Eng3d.dll` is 32-bit Windows code. It has now been run: Wine 11 executes 32-bit
x86 PE code on arm64 macOS through its wow64 layer, so the DLL can be loaded and
its exports called directly. Every claim below that was previously **[PRIOR ART]**
about decoder *behaviour* — the inverse transform, the colour back end, the
mode-0 geometry — has been either confirmed or corrected against the real thing.
See §10.6 onwards, and `tools/wine_visn/`.

---

## 1. Where the decoder lives — **[CONFIRMED]**

The codec is in `Eng3d.dll`, not `Incubation.exe`, and it is exported by name.
All four exports and the original source-module name are present as literal
strings in the shipped DLL:

```
E3D_init_vision
E3D_decode_picture
E3D_decode_picture_halve_size
E3D_convert_picblock_from_64kcolor_to_32kcolor
devision.asm
```

Reference binary: `gog_incubation/Eng3d.dll`, 666 507 bytes,
MD5 `2bb3bc9fb8b766837779dd1faf09fe8d` — **byte-identical to the binary the
prior art analysed**, so the two analyses are of the same artefact.

`SRC\devision.asm` tells you the codec is hand-written 32-bit assembly, which is
why the arithmetic details below (floor shifts, a truncated constant, an
uncorrected typo) matter: there is no compiler between the spec and the bytes.

### The four exports and how to call them — **[CONFIRMED via runtime]**

| Export | Address | Ordinal |
|---|---|---|
| `_E3D_init_vision` | `0x004023d8` | 53 |
| `_E3D_decode_picture` | `0x004023e8` | 54 |
| `_E3D_convert_picblock_from_64kcolor_to_32kcolor` | `0x004024d0` | 84 |
| `_E3D_decode_picture_halve_size` | `0x004024f8` | 88 |

Although the codec body is hand-written assembly using a register convention,
**the exports themselves are ordinary cdecl functions.** Each is a thunk that
moves stack arguments into registers and calls the real routine:

```
_E3D_decode_picture @ 0x4023e8
        push ebx / push esi / push edi
        mov eax, [esp+0x18]        ; arg3 -> EAX   destination stride, in pixels
        mov edi, [esp+0x14]        ; arg2 -> EDI   destination buffer
        mov esi, [esp+0x10]        ; arg1 -> ESI   the VISN record
        call 0x41263c              ; which does `cmp dword [esi], 'VISN'`
        pop edi / pop esi / pop ebx
        ret                        ; plain ret, so the caller cleans up: cdecl
```

```c
void _E3D_init_vision(int pixel_format);   /* 0x565 or 0x555 */
void _E3D_decode_picture(const void *record, void *dst, int stride_pixels);
void _E3D_decode_picture_halve_size(const void *record, void *dst, int stride_pixels);
```

`_E3D_init_vision`'s argument is split at `0x413a2d` into the nibbles `5`, `6`,
`5`, which become the R, G and B **field widths** — so `0x565` really does select
RGB565 and `0x555` RGB555, and the value is a pixel-format descriptor rather than
an opaque magic number.

None of these returns anything usable: the body is wrapped in `pushal`/`popal`,
so `EAX` on return is merely the stride handed back. A harness must therefore
detect success structurally, not from a return code.

The third argument is genuinely the **destination pitch in pixels**, not the
picture width: it is cached at `0x0041a988`, and `0x41a98c` = `2 * stride` is
used as the row step (`add edi, [0x41a98c]` at `0x4137fb`). Confirmed at runtime
by decoding the same record correctly at strides 200, 256, 320 and 512.

---

## 2. Container layout — **[CONFIRMED]**

`texture.lib` is a **plain concatenation of VISN records** with no container
header, no padding and no alignment. The table of contents is a sibling file:
`texture.dir` (ASCII) or `texture.din` (binary), which hold the same data.

Verified across all 21 containers: every indexed extent starts exactly where
the previous one ended, the first starts at 0, and the last ends exactly at
end-of-file. **Zero gaps, zero overlaps, zero trailing bytes.**

### The 21 containers

| Location | Containers | Records |
|---|---:|---:|
| `WorldSet/World_{A,B,C,D,E,F,G,H,I}00/*/texture.lib` | 9 | 384 |
| `Video/{Dialog_02,03,07,09,14,15,16, Extro, Seq_1,3,4,5}/*/Texture.lib` | 12 | 339 |
| **Total** | **21** | **723** |

Per container: A00 61, B00 39, C00 39, D00 37, E00 46, F00 47, G00 38, H00 41,
I00 36; Dialog_02 23, Dialog_03 17, Dialog_07 19, Dialog_09 15, Dialog_14 15,
Dialog_15 22, Dialog_16 16, Extro 55, Seq_1 62, Seq_3 12, Seq_4 42, Seq_5 41.

**The prior art's count of 723 (384 + 339) is confirmed exactly**, by two
independent derivations: the record counts declared in the `.din` headers, and
a scan finding a `VISN` magic at every indexed offset.

Filename case is inconsistent in the retail tree — `TEXTURES/texture.lib` in
`World_A00` and `Video/Extro`, `Textures/Texture.lib` elsewhere. Tools must
match case-insensitively.

### `.din` addressing — **[CONFIRMED]**

Only the fields VISN addressing needs are documented here; the general
`.dir` / `.din` specification is in
[`30-eng3d-ascii-formats.md`](30-eng3d-ascii-formats.md).

```
"DBIN"                       4 bytes
u32  count
count x 25-byte entries:
    u32   index              0-based, equals the entry's own position
    char  name[13]           NUL-padded, cp1252
    u32   offset             byte offset of the record within texture.lib
    u32   size               byte length of the record
```

File size is exactly `8 + 25 * count` in all 21 files.

The ASCII `.dir` carries the same rows as
`name \t\t type index offset size mtime`. All **723 rows were cross-checked
between `.dir` and `.din`: names, indices, offsets and sizes agree exactly**,
with `type == 2` for every VISN record.

**Finding — non-ASCII record names.** Five records in
`Video/Seq_4/Textures/Texture.din` (indices 37–41) have names beginning with
byte `0xE4`, i.e. `ä` in cp1252: `ärn60000` … `ärn60004`. They coexist with a
separate `arn60000` … `arn60004` set in the same container, so `ä` and `a` are
**distinct** names and must not be folded together. Decode names as cp1252, and
sanitise separately for the filesystem. `tools/visn_decode.py` maps them to
`_rn6000x.png`; no collisions result in any container.

---

## 3. Record header — **[CONFIRMED]**

10 bytes, little-endian:

| Offset | Size | Field | Observed in retail |
|---|---|---|---|
| `+0x00` | 4 | magic `"VISN"` | all 723 |
| `+0x04` | `u16` | `width` in pixels | `256` in all 723 |
| `+0x06` | `u16` | `height` in pixels | `256` in all 723 |
| `+0x08` | `u8` | `quality`, 1..100, IJG scale | `93` (`0x5D`) in all 723 |
| `+0x09` | `u8` | `mode` | `2` in all 723 |
| `+0x0A` | .. | bitstream | |

`mode` selects the macroblock geometry:

| Mode | Sampling | Macroblock | Blocks per macroblock |
|---|---|---|---|
| `0` | 4:2:0 | 16 x 16 | 6 — Cb, Cr, Y0, Y1, Y2, Y3 |
| `2` | 4:4:4 | 8 x 8 | 3 — Cb, Cr, Y |

Macroblock counts are `width >> 4` by `height >> 4`, **doubled in both axes for
mode 2**, giving 8-pixel macroblocks: 32 x 32 = 1024 macroblocks and 3072 blocks
for a 256 x 256 picture.

That only modes 0 and 2 exist is now **[CONFIRMED]**, from the three-entry
dispatch table at `0x41a97c`:

```
[0] = 0x00412749   mode 0, 4:2:0
[1] = 0xFFFFFFFF   invalid
[2] = 0x00412868   mode 2, 4:4:4
```

`[0x41a994]` is loaded from `table[mode]` and called; mode 1 would jump to
`0xFFFFFFFF`. **[CONFIRMED]** that no shipped record uses anything but mode 2.

### The macroblock count truncates — **[CONFIRMED via runtime]**

The engine reads the dimensions and shifts them right by four
(`Eng3d.dll` @ `0x41267d`), then mode 2 doubles both (@ `0x412873`). The result is
`2 * (width >> 4)`, which is **not** the same as `width >> 3`: at 24 pixels wide
the engine lays down two 8-pixel macroblocks and never writes the last 8 columns.

This was a real bug in `tools/inclib/visn.py`, which used `width >> 3`. It is
invisible at 256 x 256 — the only size retail ships — and was found only by
rewriting the header dimensions and comparing against the DLL. Now fixed;
sizes 16 x 16 up to 256 x 256, square and not, agree byte for byte over the
region the engine actually writes.

Both inner loops are `dec`/`jne` do-whiles, so a macroblock count of **zero wraps
to 2³²−1** and the engine runs away through memory. An 8 x 8 picture therefore
crashes the real decoder. `tools/inclib/visn.py` rejects any dimension below 16
rather than emulating that.

Mode 0 **is** implemented, and verified byte-exact against the DLL — see §10.7.

The prior art notes a hard 256 x 256 limit enforced by the engine's texture page
and Glide's `GR_LOD_256`. The **codec** imposes no such limit: the DLL decodes
16 x 16, 32 x 32, 64 x 32, 128 x 128 and 240 x 240 pictures correctly when the
header says so. Any 256 x 256 restriction lives in the texture-page and Glide
layers, not here, and remains **[PRIOR ART]**.

---

## 4. Bitstream mechanics — **[CONFIRMED]**

The payload is a sequence of **16-bit little-endian words**, with bits consumed
**MSB-first** through a 32-bit shift register.

```
init    :  buf = (word0 << 16) | word1        # word 0 in the high half
           count = 32
refill  :  buf |= (word << 16) >> count       # logical shift
           count += 16                        # only valid while count <= 16
read(n) :  v   = buf >> (32 - n)
           buf = (buf << n) & 0xFFFFFFFF
           count -= n
```

Because two whole words are pre-read, the decoder always runs up to 32 bits
ahead of the bits it has actually used. An encoder must pad the tail with spare
words.

This is confirmed strongly and indirectly: see §10 — every one of the 723
records is consumed to within 0 or 2 bytes of its indexed length, with **no
record ever reading past its own end**. A single misread bit anywhere in a
30 KB record would desynchronise the Huffman decoder and destroy that property.

---

## 5. Picture prologue — two Huffman tables — **[CONFIRMED]**

Immediately after the initial fill, two code-length tables are read:

1. **table A** — used by the **chroma** (Cb, Cr) blocks,
2. **table B** — used by the **luma** (Y) blocks.

Each is encoded as:

```
12 bits : N = number of symbols            (retail always writes 0x81 = 129)
then N code lengths, delta-coded mod 16, through a fixed meta-code:
    meta 0x00..0x0F : running = (running + meta) & 0xF ; emit running
    meta 0x10       : read 5 more bits = k ; emit k symbols of length 0 (unused)
running starts at 0
```

Meta symbol `0x10` does **not** disturb `running` — **[CONFIRMED]**, read straight
off the table reader at `Eng3d.dll` @ `0x412d16`. That routine is worth quoting,
because it settles three separate questions at once:

```
0x412d2d   mov eax, ebp / sub ch, 0xc / shl ebp, 0xc / shr eax, 0x14
                                  ; N really is a 12-bit field
0x412d39   mov edx, eax / sub dh, dh
                                  ; DL = symbols still to emit, DH = `running`
0x412d73   add dh, al / and dh, 0xf / mov [edi], dh / inc edi / dec dl
                                  ; running = (running + meta) & 0xF; emit it
0x412dc0   ...read 5 bits into AL...
0x412de2   sub dl, al             ; the run counts against the symbol total
0x412de4   sub ah, ah
0x412de6   mov [edi], ah / inc edi / dec al / jne 0x412de6
                                  ; emit exactly AL zero lengths -- DH untouched
```

So the escape emits `k` zeros, charges `k` against the symbol count, and leaves
`running` alone. The 12-bit width of `N` is likewise **[CONFIRMED]** rather than
inferred, though note that the loop counter is only the 8-bit `DL`, so in practice
`N` is used modulo 256.

**`k == 0` is malformed, and now we know exactly how.** The emit loop is a
do-while: with `AL == 0` it writes one zero, decrements to `0xFF`, and goes round
another 255 times — 256 zero lengths, while `DL` is unchanged. The stream
desynchronises. `tools/inclib/visn.py` rejects `k == 0`, which is the right call;
it is not a no-op in the original.

**Confirmed by measurement over the whole corpus** — all 21 containers, 723
records, **1446 tables**: every table declares exactly `N = 129` symbols, every
table emits exactly 129 lengths, and all 17 meta symbols (`0x00`..`0x10`) are
exercised somewhere in the data.

**Edge case — the empty table.** In **6 of the 1446 tables every symbol has
length 0**, i.e. the table is empty. These belong to pictures in which that
plane's blocks all have `nAC == 0`, so no symbol is ever decoded from the table.
A decoder must build such a table without erroring rather than rejecting it as
malformed.

### The fixed meta-code — **[CONFIRMED]**

17 code lengths, read directly from **`Eng3d.dll` @ `0x19D98`**:

```
2, 2, 3, 4, 8, 8, 9, 9, 8, 8, 8, 8, 8, 5, 4, 3, 4
```

Its Kraft sum is exactly 1.0, i.e. it is a complete prefix code. Note it
contains **9-bit codes**, so a meta-decoder cannot be a pure 8-bit lookup.

### Canonical assignment — **[CONFIRMED]**

The textbook JPEG / DEFLATE convention:

```
count[len] for len = 1..15         (0 = symbol unused, >15 = error)
first[1] = 0 ;  first[len+1] = (first[len] + count[len]) << 1
symbols take codes in increasing symbol order within each length
```

**Correction to the prior art.** It states that keeping every code ≤ 8 bits
means the long-code bit-tree "is never used". That is sound advice *for a new
encoder*, but it is **not true of the retail data**: Blue Byte's own encoder
emits codes up to the full 15 bits. Measured maximum code length over **all
1446 tables in the corpus**:

| Max code length | 0 | 2 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Tables | 6 | 2 | 1 | 8 | 3 | 12 | 24 | 22 | 67 | 235 | 413 | 492 | 161 |

**1414 of 1446 tables (97.8 %) contain codes longer than 8 bits**, and 161 use
the full 15. **A decoder that implements only an 8-bit lookup table will fail on
the retail game.** `tools/inclib/visn.py` uses a 256-entry lookup for codes up
to 8 bits and a canonical bit-walk above that.

The `& 0xF` in the delta-coding caps every length at 15 by construction, which
is why 15 is also the format's hard maximum.

---

## 6. Block syntax — **[CONFIRMED]**

Blocks appear in macroblock raster order; within a macroblock, in stream order:

* mode 2 (8 x 8): **Cb, Cr, Y**
* mode 0 (16 x 16): **Cb, Cr, Y0, Y1, Y2, Y3** — **[CONFIRMED via runtime]**, see §10.7

Each block:

```
6 bits  : nAC        number of AC coefficients that follow, 0..63
12 bits : DC + 0x800 subtract 0x800 for the signed DC, -2048..2047
nAC symbols, one coefficient each, at zigzag scan positions 1..nAC
```

* **The DC is raw.** It is not quantised, not dequantised and not predicted from
  the previous block. It is written straight into scan position 0.
* **Zeros are explicit** (symbol `0x3A`). There is no run-length coding and no
  EOB marker — `nAC` alone terminates the block.

### The coefficient alphabet (129 symbols)

| Symbol | Meaning |
|---|---|
| `0x00`..`0x74` | literal, `value = symbol - 0x3A` (−58 .. +58), no extra bits |
| `0x75`..`0x80` | escape, `n = symbol - 0x74` (1..12) extra bits follow, read as a **signed** (two's-complement) `n`-bit value |

then

```
coefficient[ NATURAL_ORDER[scan] ] = (value * qtab[scan]) >> 14
```

with an **arithmetic (floor)** shift, matching the x86 `sar`.

Measured over the whole corpus (**2 221 056 blocks** = 723 x 3072, exactly as
the mode-2 geometry predicts): `nAC` spans its full 0..63 range. Over
`World_A00` specifically (187 392 blocks) 27.2 % of blocks have `nAC == 0` and
0.6 % have `nAC == 63`, with an observed DC range of 0 .. 2016.

**Corpus-wide escape usage**: only widths 7..11 ever occur —
7 x 43 940, 8 x 218 656, 9 x 59 009, 10 x 8 021, 11 x 53. Widths 1..6 and 12
are never used by Blue Byte's encoder, but all twelve are now
**[CONFIRMED via runtime]** against synthesised records: 68 cases covering every
width at the edges of its signed range agree byte for byte, and every one of them
was checked to be observable (the same record with a zero coefficient produces
different pixels), so the two's-complement sign rule is tested and not merely
assumed. A 1-bit escape does encode exactly `{0, −1}`.

The field widths themselves are read off the block reader at `0x412a22`:
`sub ch, 6` / `shr eax, 0x1a` for **`nAC` = 6 bits**, then `sub ch, 0xc` /
`shr eax, 0x14` for **`DC` = 12 bits**. **[CONFIRMED]**

### The high-water-mark detail

The prior art notes that the real decoder does not clear each block, but keeps a
per-plane coefficient buffer and only zeroes the tail left over from the
*previous* block of that plane.

**This is exactly equivalent to using a freshly zeroed block, and
`tools/inclib/visn.py` does the simple thing.** Proof by induction: assume that
after block *k* every position above `nAC_k` is zero. Block *k+1* zeroes
positions `nAC_{k+1}+1 .. nAC_k`; positions above `nAC_k` are already zero by
hypothesis; so after the clear, every position above `nAC_{k+1}` is zero, which
is precisely the state of a fresh array. The base case is the zero-initialised
buffer. The mechanism is a speed optimisation in the original, not an
observable behaviour.

---

## 7. Quantisation — **[CONFIRMED]**, including the typo

The base tables are the **standard JPEG Annex K** tables, read directly out of
`Eng3d.dll` in raster order:

* **`0x19E30`** — luma, begins `16 11 10 16 24 40 51 61`
* **`0x19E70`** — chroma, begins `17 18 24 47 99 99 99 99`

Both match the Annex K tables exactly. The JPEG zigzag order is also shipped,
in both directions:

* **`0x19DAC`** — `ZIGZAG[raster] = scan`, the standard JPEG zigzag
* **`0x19DEC`** — `NATURAL_ORDER[scan] = raster`, IJG's `jpeg_natural_order`

Verified to be exact inverses of one another.

Scaling is plain IJG, and the AAN prescale is folded into the stored table:

```
q     = header byte 8, clamped to 1..100
scale = (100 - q) * 2   if q > 50   else   5000 / q
value = clamp((base[i] * scale + 50) / 100, 1, 255)     # i in RASTER order
qtab[ ZIGZAG[i] ] = value * AAN_SCALES[i]               # stored in SCAN order
```

### The AAN scale table and Blue Byte's typo — **[CONFIRMED]**

`Eng3d.dll` **@ `0x19EB0`**, 64 x `u32`, raster order. It is IJG's
`jpeg_aanscales`, i.e. `round(S[u] * S[v] / 16384)` for
`S = {16384, 22725, 21407, 19266, 16384, 12873, 8867, 4520}`:

```
16384, 22725, 21407, 19266, 16384, 12873,  8867,  4520,
22725, 31521, 29692, 26722, 22725, 17855, 12299,  6270,
21407, 29692, 27969, 25172, 21407, 16819, 11585,  5906,
19266, 26722, 25172, 22654, 19266, 15137, 10426,  5315,
16384, 22725, 21407, 19266, 16384, 12873,  8867,  4520,
12873, 17855, 16819, 15137, 12873, 10114,  6967,  3552,
 8867, 12299, 11585, 10426,  8867,  6967,  4799,  2446,
 4520,  6270,  5906,  5315,  4520,  3552,  2446,   124     <-- typo
```

The last entry should be **1247**. The shipped table holds **124** — a dropped
final digit. Every other one of the 64 entries matches IJG's table exactly,
which is what makes it a typo rather than a design choice.

> **Correction to the prior art.** It says "the formula gives 1246". 1246 is what
> *truncation* gives; but the rest of the shipped table is unambiguously
> **rounded** (31521, 12299, 6270, 5906, 6967, 3552, 4799 are all round-half-up
> results and all differ from the truncated values). Under the same rounding the
> last entry is 1247. So the typo is **1247 → 124**, not 1246 → 124. This does
> not change any decoder behaviour; it is a correction to the description.

**Reproduce `124` verbatim. Do not "fix" it.** This was tested, not assumed:
substituting the correct 1247 and re-decoding **changed the output of every one
of the first 15 records of `World_A00`**. It affects only scan position 63, the
highest-frequency coefficient — but 0.6 % of blocks carry a coefficient there,
which is thousands of blocks per container. At `q = 93` the shipped value gives
`qtab[63] = 14 * 124 = 1736` for both luma and chroma; the "fixed" value would
give 17 458, a factor of ten too much high-frequency energy.

---

## 8. Inverse transform — **[CONFIRMED via runtime]**

The AAN fast IDCT, i.e. the IJG `jpeg_idct_ifast` family, int32, with the
"all AC in this column/row are zero → replicate the DC" shortcut. Coefficients
arrive already multiplied by `quant * aanscale >> 14`, i.e. prescaled.

Fixed-point constants at `CONST_BITS = 8`, `MULTIPLY(x,c) = (x * c) >> 8`:

| Constant | Value |
|---|---|
| √2 = 1.414213562 | `362` |
| 1.847759065 | `473` |
| 1.082392200 | `277` |
| −2.613125930 | `−669` |

* **Pass 1 runs down the columns and does not descale.**
* **Pass 2 runs along the rows and shifts right by 3.**
* Shifts are **arithmetic (floor)**, which matters for negative values.
* There is **no level shift and no clamping** in the IDCT. The `+128` rides in
  the DC coefficient — the encoder simply never subtracts it, so a mid-grey
  block carries a DC of about `128 * 8 = 1024` and the output lands in 0..255 on
  its own. Clamping happens in the colour tables.

The `nAC == 0` case therefore collapses to a constant block of `DC >> 3`, which
`tools/inclib/visn.py` exploits — 27 % of all blocks.

All four constants are visible verbatim in the routine at `Eng3d.dll` @
`0x41301f` — `imul eax, eax, 0x16a` (362), `0x1d9` (473), `0x115` (277),
`0xfffffd63` (−669) — each followed by `sar ..., 8`. The pass-2 stores are
`sar edi, 3` / `sar edx, 3` immediately before writing, with **no clamping and no
level shift anywhere in the routine**. That absence matters: it is what makes an
out-of-range picture crash the real decoder rather than saturate (§9).

Byte-exactness over all 723 records, and over synthetic records at every quality
from 1 to 100, rules out any rounding difference: a single misplaced round-half
in the transform would show up somewhere in 2.2 million blocks.

---

## 9. Colour conversion — **[CONFIRMED via runtime]**

Fully table-driven, producing **RGB565** — exactly what the engine consumes.
Per pixel, with the planes in stream order Cb, Cr, Y:

```
yi  = clamp(Y,  0, 256)          # note the upper bound is 256, not 255
cbi = clamp(Cb, 0, 256)
cri = clamp(Cr, 0, 256)

pixel = Rtab[ yi + dR(cri) ]
      | Gtab[ yi + dGcb(cbi) + dGcr(cri) ]
      | Btab[ yi + dB(cbi) ]
```

The chroma deltas are IJG's integer YCbCr coefficients,
`delta(i) = (FIX * (i - 128) + 32768) >> 16` with an arithmetic (floor) shift:

| Delta | FIX | Note |
|---|---|---|
| `dR` from Cr | `+91881` | `round(1.40200 * 65536)` |
| `dB` from Cb | `+116129` | `trunc(1.77200 * 65536)` — **truncated, not rounded** |
| `dGcb` from Cb | `−22554` | `−round(0.34414 * 65536)` |
| `dGcr` from Cr | `−46802` | `−round(0.71414 * 65536)` |

Each channel table already holds its value **shifted into its RGB565 field**, so
the three lookups are simply OR'd. For an index `i`:

```
i < 0          -> 0
0 <= i <= 255  -> ((i * 31) // 255) << 11   (R)    full-range scaling,
                  ((i * 63) // 255) <<  5   (G)    NOT a bit shift
                  ((i * 31) // 255)         (B)
256 <= i <= 383 -> saturated (31 / 63 / 31, shifted)
i > 383        -> 0
```

Two oddities worth restating because they look like bugs and are not: the input
clamp really is `0..256` inclusive, and indices above 383 wrap to **zero (black)**
rather than saturating. Given the delta ranges the reachable index range is
−227 .. +483, so the `> 383` branch is genuinely reachable.

### There is no clamp instruction — the tables *are* the clamp — **[CONFIRMED]**

The description above is behaviourally exact, but the engine reaches it by a
different route than a reader would guess, and the difference has teeth.

`_E3D_init_vision` builds **eight** tables, each 512 dwords laid out so that the
name refers to entry 0 and 128 entries sit *below* it — an index range of
**−128 .. +383**, and no more:

* three channel tables (`0x4931b4` red, `0x4939b4` green, `0x4941b4` blue), built
  at `0x413a74` as `((i * max) // 255) << shift` for `i` in `0..255`, with the
  128 entries below zeroed and the 128 above filled by `rep stosd` with the last
  value computed — i.e. **saturated**;
* five composite tables (`0x4949b4`, `0x4951b4`, `0x4959b4`, `0x4961b4`,
  `0x4969b4`), built at `0x413b5a`, likewise flat below and above their range.

The composite tables hold *byte offsets*, not values, which is why the whole
conversion is three loads and two `or`s with no arithmetic at all:

```
eax = Ytable[y]              ; = y * 4, so eax is an offset into a channel table
ebx = CrTable1[cr]           ; = channel_base + delta * 4
ecx = CbTable1[cb] + CrTable2[cr]
edx = CbTable2[cb]
pixel = [eax+ebx] | [eax+ecx] | [eax+edx]
```

`Ytable` is built with slope 1.0 from index 0, so it saturates at 0 below and at
256 above — **that is where `clamp(Y, 0, 256)` actually comes from.** The chroma
tables are built from index −128 with the IJG slope, giving
`delta(i) = (FIX * (i − 128) + 32768) >> 16` saturated outside `0..255`. And the
three channel tables sit contiguously in memory, so index `384..511` of one is
index `−128..−1` of the next — all zeros. **That is where "index > 383 → black"
comes from.** It is table adjacency, not a designed branch, and it only holds up
to 511.

**Consequence: the engine never bounds-checks the sample.** A picture whose Y,
Cb or Cr leaves −128 .. +383 makes it index outside the tables and read unrelated
memory, or fault. This is not hypothetical — see §10.9. `tools/inclib/visn.py`
clamps instead, so it agrees with the DLL everywhere inside that window and stays
safe outside it, where the DLL's behaviour is undefined.

**PNG output is our own addition.** The codec's native output is RGB565;
`VisnImage.to_rgb888()` expands it to 24-bit by bit replication
(`r8 = (r5 << 3) | (r5 >> 2)`, `g8 = (g6 << 2) | (g6 >> 4)`). That choice is not
part of the format. A remake should consume `VisnImage.pixels` (RGB565) directly.

That `_E3D_init_vision` takes `0x565` or `0x555` is **[CONFIRMED]**: `0x413a2d`
splits the argument into three nibbles and uses them as field widths and shifts
when building the channel tables. **The order is B, G, R from the most
significant nibble down** — blue takes the high nibble at shift 0, green the
middle nibble at shift = high, red the low nibble at shift = middle + high.
Both shipped descriptors are nibble-symmetric, so nothing in the corpus
distinguishes this from the R, G, B reading; the disassembly does, and
`pixel_format_fields()` implements it. An asymmetric descriptor such as `0x655`
would come out channel-swapped under the wrong reading. All 723 records were decoded
with `_E3D_init_vision(0x565)`.
`_E3D_convert_picblock_from_64kcolor_to_32kcolor` converts RGB565 → RGB555 for
15-bit displays; it is **[PRIOR ART]**, still not exercised or implemented here.

### 9.1 The exact 24-bit picture, and why RGB565 derives from it — **[CONFIRMED]** *(2026-10-12)*

The tables are where precision is lost: every channel index `i` (the clamped
`Y` plus its delta) is scaled to a 5- or 6-bit field, `(i * max) // 255`.
`convert_exact()` in `tools/inclib/visn.py` stops one step earlier and keeps
`clamp(i, 0, 255)` -- the remake's own reading, not something the game ever
computed. Over all 723 records (47 382 528 pixels) it holds **11 946**
distinct colours per page on average against the tables' **1 868**, and
differs from the bit-replicated RGB565 by 2.6 levels per channel on average,
8 at most; the gain is in the dark gradients the 5-bit red and blue band.

Because `table(i) = ((clamp(i, 0, 255) * max) // 255) << shift` for every
`i` up to 383, the engine's RGB565 is **a function of the exact picture**
wherever no index passes 383 -- the one place the tables' adjacency paints
black instead of saturating. No shipped record reaches it.
`visn_decode.py --check` pins the derivation (`derive_rgb565()`) on
**723/723** records, so a cache can carry only the exact picture and still
draw the original's quantised one bit for bit (docs/92 section 7.29).

---

## 10. Verification performed here

### 10.1 Container and index — **[CONFIRMED]**

| Check | Result |
|---|---|
| Containers found | 21 |
| Records declared by `.din` headers | **723** (384 WorldSet + 339 Video) |
| `.din` file size equals `8 + 25 * count` | 21 / 21 |
| `VISN` magic present at every indexed offset | 723 / 723 |
| Gaps / overlaps / trailing bytes | **0** |
| `.dir` rows agreeing with `.din` (name, index, offset, size) | **723 / 723** |
| Records that are 256 x 256, quality 93, mode 2 | 723 / 723 |

### 10.2 DLL tables — **[CONFIRMED]**

Every constant table the specification describes was located as a literal byte
sequence in `Eng3d.dll` and matches: meta code lengths (`0x19D98`), zigzag
(`0x19DAC`), natural order (`0x19DEC`), Annex K luma (`0x19E30`), Annex K chroma
(`0x19E70`), AAN scales (`0x19EB0`, ending in the `124` typo).

### 10.3 Decode — **[CONFIRMED]**

```
$ python3 tools/visn_decode.py gog_incubation --check
containers : 21
records    : 723
decoded    : 723
failed     : 0
elapsed    : 26.7s (37 ms/record)
slack bytes: 0->430, 2->293
overrun words: 0->723
```

**The slack figure was the strongest evidence here before the DLL could be run,
and it is still the sharpest check on the entropy layer specifically.**
"Slack" is `record_size − bytes_the_bitstream_pulled in`. Across all 723 records
it is either **0 bytes (430 records) or exactly 2 bytes (293 records)** — that
is, one spare 16-bit pad word — and **no record ever read a single byte past its
own end** (`overrun words: 0->723`).

That is a per-record checksum over the entire entropy layer. It requires the
16-bit-LE MSB-first packing, the 32-bit pre-read, the meta-code, the
delta-coding-mod-16, the `0x10` run escape, the canonical assignment including
15-bit codes, the 6-bit `nAC`, the 12-bit DC and the whole escape alphabet to
all be simultaneously correct, for 723 independent bitstreams totalling ~15 MB.
Any single error would make the decoder finish at an essentially random offset.

It does **not** validate the dequantiser, the IDCT or the colour stage, none of
which feed back into bitstream position. Those three are settled instead by
§10.6, which diffs our output against the DLL's.

### 10.4 Visual — **[CONFIRMED]**

All 723 records were decoded to PNG in `tools/out/textures/`, plus a 126-texture
contact sheet at `tools/out/textures/_contact_sheet.png`. The results are
unambiguously correct images: cutscene character portraits with natural skin
tones and hair, sunset and cloud skies, legible in-game text, alien creature
skins, and architectural and machinery textures. There are no channel swaps, no
chroma displacement, no block-boundary discontinuities and no ringing beyond
what JPEG at quality 93 explains.

Skin tones and the smooth sky gradients are the sensitive tests here: a wrong
YCbCr constant, a swapped Cb/Cr, a wrong IDCT descale or an off-by-one in the
colour tables all produce immediately visible damage in exactly those images.

### 10.5 Running the real decoder — method

`Eng3d.dll` is 32-bit Windows code, but Wine 11 runs 32-bit x86 PE binaries on
arm64 macOS through its wow64 layer, so it can simply be loaded and called. The
harness in `tools/wine_visn/` is a small `i686-w64-mingw32` console program that
`LoadLibrary`s the shipped DLL, calls `_E3D_init_vision(0x565)`, then decodes a
batch of records and writes the raw RGB565 out for a Python driver to diff.

Three deliberate guards, because a harness that reports "match" when both sides
produced nothing is worse than no harness at all:

1. **Liveness probe.** `_E3D_get_engine_version` is `mov eax, 0x64; ret`. It is
   called first, and the run aborts unless it returns 100 — proving the load,
   the `GetProcAddress` and the call path all work before anything is blamed on
   the codec.
2. **Poison fill.** The destination is filled with `0xA5` before every record,
   and the harness reports how many bytes changed. A record where the DLL wrote
   nothing is counted as a failure, never as a match.
3. **Guard region.** 256 KiB past the end of the picture is also poisoned and
   checked, so an overrun is caught rather than silently tolerated.

All 723 records go through **one** process, so the whole corpus costs about six
seconds of Wine time.

### 10.6 Byte-exactness — **[CONFIRMED via runtime]**

| Check | Records | Result |
|---|---:|---|
| `_E3D_decode_picture` vs `VisnImage.pixels` | 723 | **723 byte-exact, 0 mismatches** |
| `_E3D_decode_picture_halve_size` vs our model | 723 | **723 byte-exact, 0 mismatches** |
| Records where the DLL wrote nothing | 723 | 0 |
| Writes past the end of the picture | 723 | 0 |

This is the whole corpus, not a sample: all 21 containers, every record, both
entry points. It covers the dequantiser, the inverse transform and the colour
back end — the three stages the bitstream-consumption argument in §10.3 cannot
reach.

**One genuine bug was found this way**, and only this way: the macroblock count
truncation described in §3. It is invisible at 256 x 256, so nothing in
§10.1–10.4 could have caught it.

### 10.7 Mode 0 (4:2:0) — **[CONFIRMED via runtime]**

No shipped record uses mode 0, so it was reconstructed by reading the mode-0
colour stage at `Eng3d.dll` @ `0x4132d3` and then **synthesising** mode-0 records
and feeding them to the DLL. `tools/wine_visn/visn_synth.py` is a minimal encoder
written for exactly this.

The colour stage renders the macroblock as four quadrants. Their sample-buffer
addresses and destination offsets give the layout directly:

| Call | Y block | Chroma quadrant | Destination |
|---|---|---|---|
| 1 | `0x491efc` = Y0 | `+0x00` → row 0, col 0 | `dst` |
| 2 | `0x4920fc` = Y2 | `+0x80` → row 4, col 0 | continues (8 rows down) |
| 3 | `0x491ffc` = Y1 | `+0x10` → row 0, col 4 | `dst + 0x10` = 8 pixels right |
| 4 | `0x4921fc` = Y3 | `+0x90` → row 4, col 4 | continues |

So **Y0, Y1, Y2, Y3 tile the 16 x 16 macroblock in plain raster order.** And each
quadrant routine loads *one* Cb/Cr pair, then applies it to four luma samples —
`[esi]`, `[esi+4]`, `[esi+0x20]`, `[esi+0x24]` — writing them as two pixels at
`[edi]` and two at `[edi + 2*stride]`. **Chroma upsampling is 2 x 2 pixel
replication, phase-aligned to the top-left. There is no interpolation.**

Both rules were then confirmed against the DLL, byte for byte, on five synthetic
pictures: single- and multi-macroblock, square and not, with flat chroma and with
chroma that varies inside the macroblock.

**The probes were checked for the ability to fail.** Re-decoding them under the
two plausible wrong hypotheses changes the output, so agreement is meaningful:

| Case | Distinct chroma values | Pixels changed by swapping Y1/Y2 | Pixels changed by bilinear chroma |
|---|---:|---:|---:|
| y-quadrants 16 x 16 | 2 | 128 | 0 |
| y-grid 64 x 64 | 2 | 2048 | 0 |
| y-grid 64 x 32 | 2 | 1024 | 0 |
| chroma-detail 16 x 16 | 16 | 92 | 95 |
| chroma-grid 32 x 32 | 53 | 496 | 556 |

The flat-chroma cases are correctly insensitive to the upsampling rule — constant
chroma upsamples identically however you do it — which is precisely why the two
chroma-detail cases had to exist.

### 10.8 `_E3D_decode_picture_halve_size` — **[CONFIRMED via runtime]**

It is **not** a reduced transform and **not** a decimation. The routine at
`0x413814` runs the ordinary full 8 x 8 inverse transform and then, per output
pixel, averages the 2 x 2 group of **Y, Cb and Cr samples** — `sar eax, 2` on the
sum of four, arithmetic so it floors — before the same colour lookup as the
full-size path.

The averaging is therefore in the YCbCr domain, ahead of the tables. That is
observably different from averaging finished RGB565 pixels: averaging the output
of the full-size decode instead reproduces only about 65 % of pixels. The
mode-2 macroblock loop is identical except that the destination advances by 4
pixels instead of 8 (`shl eax, 2` at `0x412967` against `shl eax, 3` at
`0x41288a`).

Output geometry, read off the poison map: a 256 x 256 record produces 128 rows of
128 pixels written into the **top-left corner at the destination's full stride**,
so the last byte touched is `127 * 512 + 255` = `0xFEFF`. The caller supplies a
full-width buffer and gets a quarter-area picture in the corner of it.

Modelled in `halve_reference()` in `tools/wine_visn/visn_compare.py` and
confirmed byte-exact on all 723 records.

### 10.9 Quality, size and stride — **[CONFIRMED via runtime]**

Every shipped record is 256 x 256 at quality 93, so three whole axes of the format
had never been exercised. Rewriting the header in memory, and synthesising
records, covers them:

| Axis | Tested | Result |
|---|---|---|
| Quality, retail records re-quantised | 1 .. 100 | byte-exact for q ≥ 90; **the DLL faults for q ≤ 88** |
| Quality, synthetic records | 1, 2, 5, 10, 25, 49, 50, 51, 52, 75, 90, 93, 99, 100 | **14 / 14 byte-exact**, all non-flat |
| Picture size | 16², 32², 64², 128², 240², 64x32, 128x256, 200x136, 250², 256² | byte-exact over the region the engine writes |
| Destination stride | 200, 256, 320, 512 | byte-exact |
| Escape widths | 1 .. 12, at the edges of each signed range | **68 / 68 byte-exact** |

The quality result deserves unpacking, because the crash is informative rather
than a nuisance. Re-quantising a *retail* record at a lower quality makes the
coefficients grow; by q = 88 the samples leave the colour tables' −128 .. +383
window (§9) and the DLL indexes outside them. Wine reports the fault at
`0x0089379e`, which with the DLL loaded at `0x00880000` is **`0x0041379e` — inside
the mode-2 colour stage at `0x413595`**, exactly as predicted.

The boundary is not arbitrary either: our decoder's sample range for the first
record of `World_A00` reaches 409 at q = 88 and 376 at q = 89, against a table
limit of 383.

The same mechanism explains the only pixel that has ever disagreed. At q = 90 one
record differed in **1 pixel out of 65 536** — and that record contains **exactly
one** sample outside the window, `Y = −136`, at exactly that pixel. The DLL reads
8 dwords below its Y table, landing in the saturated tail of the adjacent blue
channel table; we clamp and emit black. Outside the window the DLL's behaviour is
an out-of-bounds read, so this is a divergence in a regime where the original is
simply wrong, not a defect in either decoder.

Synthetic records avoid the whole problem because their coefficients are chosen
to stay in range, which is why quality 1 — the `5000 / q` branch of the IJG
formula that retail data can never reach — is verifiable at all.

### 10.10 A quirk worth recording: the stride patch is self-modifying code

The engine caches the destination stride at `0x0041a988` (initial value 256). Ask
for a different one and `_E3D_decode_picture` calls `0x413570`, which does this:

```
mov eax, [0x41a98c]          ; 2 * stride
mov [0x4133bd], eax          ; <- writes into the CODE section
add eax, 4
mov [0x413443], eax
add eax, 4
mov [0x4134c9], eax
add eax, 4
mov [0x41354f], eax
```

Those four addresses are the immediate operands of `mov [edi + 0x200], ebp`,
`[edi + 0x204]`, `[edi + 0x208]` and `[edi + 0x20c]` inside the mode-0 colour
stage. `Eng3d.dll`'s `BEGTEXT` section is not writable, so on any loader that
honours page protection this store faults — confirmed, at `0x00413576` writing to
`0x004133bd`.

The mode-2 path does not need it: it takes its row step from a variable
(`add edi, [0x41a98c]` at `0x4137fb`). Seeding the stride cache directly, so the
patch is never attempted, lets mode 2 decode byte-exact at strides 200, 320 and
512. Asking for `PAGE_EXECUTE_READWRITE` instead does not work on arm64 macOS,
which refuses RWX mappings.

None of this affects the game, which only ever uses a 256-pixel texture page.

### 10.11 What is still NOT verified

Everything this section used to list has since been done; the entries are kept
with their outcome so the order of work stays legible.

| Was unverified | Now |
|---|---|
| `_E3D_init_vision(0x555)` and `_E3D_convert_picblock_from_64kcolor_to_32kcolor` | Both implemented and byte-exact; §11 item 9 |
| Mode 0 beyond four synthetic sizes, and mode 0 through `halve_size` | Five more sizes and all five records through `halve_size`, byte-exact; §11 item 11 |
| Pictures wider or taller than 256 | Eleven sizes up to 1024 x 1024 and 8192 x 16, byte-exact; §11 item 8 |
| The prior art's encoder, repack path and PSNR figures | **Still not verified**, and out of scope: this project needs a decoder, not a re-encoder |

---

## 11. Open questions / unverified

Ten of the eleven questions this section used to list are now closed, and the
eleventh is closed as unverifiable from artefacts we have. What closed them was
running `Eng3d.dll` itself; see §10.5 onwards.

### Closed

1. **Byte-exactness against the game's own decoder.** **CLOSED —
   [CONFIRMED via runtime].** All 723 records agree byte for byte through
   `_E3D_decode_picture`, and all 723 through `_E3D_decode_picture_halve_size`.
   Closing it also turned up one real bug in `tools/inclib/visn.py` (§3).

2. **Mode 0 (4:2:0).** **CLOSED — [CONFIRMED via runtime].** Y0..Y3 tile the
   16 x 16 macroblock in raster order; chroma is upsampled by 2 x 2 pixel
   replication phase-aligned to the top-left, with no interpolation. Implemented
   in `tools/inclib/visn.py` and verified against the DLL on synthetic records,
   including cases proven able to distinguish the alternatives (§10.7).

3. **The `0x10` run escape.** **CLOSED — [CONFIRMED].** "Emit `k` zeros, charge
   `k` against the symbol count, leave `running` alone" is exactly what
   `0x412dc0` does. `k == 0` is malformed: the do-while emits 256 zeros and
   desynchronises (§5).

4. **Escape widths 1–6 and 12.** **CLOSED — [CONFIRMED via runtime].** All twelve
   widths verified at the edges of their ranges, 68 / 68 byte-exact, every case
   observable (§6).

5. **Field widths.** **CLOSED — [CONFIRMED].** `N` is 12 bits (`0x412d2d`), the
   run length 5 bits (`0x412ddf`), `nAC` 6 bits and `DC` 12 bits (`0x412a22`).
   One caveat: the table reader's symbol counter is the 8-bit `DL`, so `N` is
   effectively used modulo 256.

6. **Quality other than 93.** **CLOSED — [CONFIRMED via runtime].** The IJG
   scaling, including the `5000 / q` branch and the q = 50/51 boundary, agrees
   byte-exact at 14 qualities from 1 to 100. Note that the *real decoder* cannot
   survive re-quantising a retail record below q ≈ 89 — not a formula
   disagreement but an unclamped table index (§10.9).

7. **`_E3D_decode_picture_halve_size`.** **CLOSED — [CONFIRMED via runtime].**
   Full 8 x 8 transform, then a 2 x 2 arithmetic-mean of the Y/Cb/Cr *samples*
   before the usual colour lookup — neither a reduced transform nor a
   decimation, and not equivalent to averaging the finished RGB565 pixels.
   Byte-exact on all 723 records (§10.8).

### Closed since the previous revision

8. **The 256 x 256 limit is not in the codec.** **CLOSED — [CONFIRMED via
   runtime].** Sizes above 256 have now been tested, and the codec has **no
   upper bound at all**. Eleven mode-2 pictures, each decoded by the shipped DLL
   and diffed against `tools/inclib/visn.py`, are **11/11 byte-exact**:

   | | | |
   |---|---|---|
   | 256 x 256 (control) | 272 x 272 | 320 x 240 |
   | 512 x 256 | 256 x 512 | 512 x 512 |
   | 1024 x 1024 | 2048 x 16 | 16 x 2048 |
   | 4096 x 16 | 8192 x 16 | |

   4096 x 16 is worth singling out: mode 2 doubles the macroblock counts, so it
   lays down **512 macroblock columns**. Nothing truncates at 256, which rules
   out the 8-bit counter that the table reader's `DL` (item 5) might have led
   one to expect elsewhere in the codec.

   The only floor is the documented one: both dimensions must be at least 16,
   because the macroblock counts are `size >> 4` and the inner loops are
   `dec`/`jne` do-whiles that underflow at zero. So the 256 x 256 limit is
   entirely the engine's texture page and Glide's `GR_LOD_256`, which remains
   **[PRIOR ART]**.

   Getting there needed one thing the earlier revision had not noticed. A
   destination stride other than 256 makes `_E3D_decode_picture` call
   `0x413570`, which **patches its own code** with `2 * stride` — and Eng3d's
   `BEGTEXT` section is not writable, so under Wine that either faults or hangs.
   Seeding the stride cache at `0x41A988` (`VISN_POKE_STRIDE`) skips the patch.
   That is sound for mode 2 and *only* for mode 2: the patched immediates are
   read exclusively by the mode-0 colour stage. Letting the patch actually run
   (`VISN_WRITABLE_TEXT`) still hangs on this host, which is why item 11's
   mode-0 sizes stop at 256 wide.

   Reproduce with `python3 tools/wine_visn/visn_probe.py --build-dir DIR
   --only size`.

9. **The RGB555 path.** **CLOSED — [CONFIRMED via runtime].** Both entry points
   are implemented in `tools/inclib/visn.py` and verified against the DLL:

   | Path | Call | Result |
   |---|---|---|
   | Direct 15-bit decode | `_E3D_init_vision(0x555)` then `_E3D_decode_picture` | **723/723 byte-exact** |
   | Post-conversion | our RGB565 output through `_E3D_convert_picblock_from_64kcolor_to_32kcolor` | **724/724 byte-exact**, 2 degenerate flat pictures counted and reported |

   The `0x555` argument is a pixel-format descriptor whose nibbles are the
   field widths in **B, G, R order** from the top down (`0x413A2D`, §6);
   `pixel_format_fields()` decodes it, and `channel_tables()` rebuilds the
   per-channel quantisation tables from it, so other formats of the same shape
   would follow.

   **The two paths are not interchangeable, and that is the practically
   important part.** Decoding directly at 555 quantises green with
   `(v * 31) / 255`, whereas decoding at 565 and shifting green down gives
   `((v * 63) / 255) >> 1`. Those disagree on **65 of the 256** green sample
   values (`green_disagreement()` enumerates them). Measured over **all 723
   shipped records**: **716 of 723 differ**, on **7.29 %** of pixels
   (3 451 970 of 47 382 528). The seven that agree are the flat and
   near-flat pictures whose samples happen to miss all 65 disputed greens.

   *(An earlier revision quoted 176 records and 5.42 %. That was one
   container's worth of records reported as if it were the corpus; the numbers
   above are the full 723 and supersede it.)*

   So a remake targeting a 15-bit surface must decide which of the two the
   original used for the case it is reproducing, rather than treating "convert
   afterwards" as a shortcut. Both are available:

   ```python
   from inclib.visn import decode_record, convert_64k_to_32k
   direct    = decode_record(blob, pixel_format=0x555).pixels
   converted = convert_64k_to_32k(decode_record(blob).pixels)
   ```

   Reproduce the verification with:

   ```sh
   python3 tools/wine_visn/visn_compare.py gog_incubation --build-dir DIR --pixel-format 0x555
   python3 tools/wine_visn/visn_compare.py gog_incubation --build-dir DIR --op convert
   ```

10. **Whether the same codec appears in Extreme Assault** — **closed as
    unverifiable here.** The claim is plausible on provenance grounds alone:
    *Extreme Assault* (Blue Byte, 1997) shipped the same `Eng3d` renderer, and
    this container is an Eng3d format, not an Incubation one. But settling it
    means diffing that game's texture library against this decoder, and we do
    not have that game. Nothing in the artefacts we do have can decide it, so it
    is recorded as an untested community claim and left there rather than
    repeated as fact. It has no bearing on a remake of *Incubation*.

11. **Mode 0 beyond the synthetic cases.** **CLOSED — [CONFIRMED via runtime].**
    Both halves are now measured.

    * **Wider geometry.** Five further mode-0 pictures — 16 x 16, 64 x 32,
      128 x 96, **64 x 240** and **256 x 256** — are **5/5 byte-exact**. The
      tall, narrow 64 x 240 separates the row and column counts and the
      256 x 256 case is a full page, so the macroblock raster order and the
      destination stride are exercised well past the original four cases. They
      stop at 256 wide for the reason given in item 8: mode 0 is precisely the
      stage that reads the self-patched stride immediates, so 256 is the only
      stride safe to use without letting the DLL rewrite its own code.

    * **Through `halve_size`.** All five mode-0 records were run through
      `_E3D_decode_picture_halve_size` and came back **5/5 byte-exact against
      the full-size picture**. That confirms at runtime what §11's dispatch
      table said statically: both entry points dispatch on the mode byte through
      `0x41A97C`, only the mode-2 slot (`0x41A984`) is rewritten on entry, and
      the mode-0 slot is the constant `0x412749` — so **asking for half size on
      a 4:2:0 record silently returns the full-size picture**. A remake must
      reproduce that, not "fix" it.

    Reproduce with `python3 tools/wine_visn/visn_probe.py --build-dir DIR
    --only mode0size` and `--only halve0`.

## 12. Tools

| Path | Purpose |
|---|---|
| `tools/inclib/visn.py` | Reusable codec: bitstream, Huffman, dequant, IDCT, colour, `.din` index reader. Modes 0 and 2. A remake can call `decode_record()` directly. |
| `tools/visn_decode.py` | CLI: `--list`, `--check`, `-o DIR`, `--contact-sheet PNG`. |
| `tools/wine_visn/` | The runtime harness that makes this document's strongest claims checkable — see its [README](../tools/wine_visn/README.md). |
| &nbsp;&nbsp;`visn_harness.c` | 32-bit Windows program that loads the shipped `Eng3d.dll` and calls its real decoder. |
| &nbsp;&nbsp;`build.sh` | cross-compiles it with `i686-w64-mingw32-gcc`. |
| &nbsp;&nbsp;`visn_compare.py` | diffs the DLL's output against ours over the shipped corpus. |
| &nbsp;&nbsp;`visn_synth.py` | minimal VISN *encoder*, for building records retail data never contains. |
| &nbsp;&nbsp;`visn_probe.py` | diffs the DLL against ours on those synthetic records. |

```bash
# enumerate records without decoding
python3 tools/visn_decode.py gog_incubation --list

# decode everything, write nothing, report counts (exit 0 on full success)
python3 tools/visn_decode.py gog_incubation --check

# decode all 723 records to PNG, one directory per container
python3 tools/visn_decode.py gog_incubation -o tools/out/textures

# tiled sample for eyeballing
python3 tools/visn_decode.py gog_incubation --contact-sheet tools/out/textures/_contact_sheet.png
```

`decode_record()` returns a `VisnImage` whose `.pixels` is the RGB565 buffer the
engine itself would receive; `.to_rgb888()` is a convenience for PNG output.
`.bytes_read` and `.overrun_words` expose the consumption accounting used by
`--check`.

To reproduce the byte-exactness result you need `i686-w64-mingw32-gcc` and a Wine
able to run 32-bit PE code (Wine 11 does this on arm64 macOS unaided):

```bash
export WINEPREFIX=/path/to/prefix WINEDEBUG=-all
BUILD=/tmp/visnharness

tools/wine_visn/build.sh "$BUILD"
cp gog_incubation/Eng3d.dll gog_incubation/ENGWLIB.DLL "$BUILD/"

# all 723 records, both entry points, then the synthetic probes
python3 tools/wine_visn/visn_compare.py gog_incubation --build-dir "$BUILD"
python3 tools/wine_visn/visn_compare.py gog_incubation --build-dir "$BUILD" --op halve
python3 tools/wine_visn/visn_probe.py --build-dir "$BUILD"
```

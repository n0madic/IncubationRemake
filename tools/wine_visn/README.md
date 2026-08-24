# `tools/wine_visn` — running the game's own VISN decoder

This directory holds a small harness that loads the shipped `Eng3d.dll` and calls
its real VISN entry points, so that `tools/inclib/visn.py` can be diffed against
the decoder Blue Byte actually shipped rather than against a prose description.

It is what closes the main open question in
[`docs/50-visn-textures.md`](../../docs/50-visn-textures.md): **all 723 shipped
records decode byte-for-byte identically**, for both the full-size and the
half-size entry point.

| File | Purpose |
|---|---|
| `visn_harness.c` | 32-bit Windows console program: loads `Eng3d.dll`, calls `_E3D_init_vision` / `_E3D_decode_picture` / `_E3D_decode_picture_halve_size`, dumps the raw RGB565 output |
| `build.sh` | cross-compiles the harness with `i686-w64-mingw32-gcc` |
| `visn_compare.py` | driver: feeds shipped records through the harness and diffs against our decoder |
| `visn_synth.py` | minimal VISN *encoder*, for building records that exercise paths retail data never uses |
| `visn_probe.py` | driver: synthesises records (mode 0, escape widths 1..12, the whole quality range, sizes past one texture page) and diffs those |

## Requirements

* `i686-w64-mingw32-gcc` (mingw-w64 cross compiler)
* Wine capable of running 32-bit x86 PE code — Wine 11 does this on arm64 macOS
  through its wow64 layer, no Rosetta or x86 host needed
* a Wine prefix, and `Eng3d.dll` plus `ENGWLIB.DLL` copied next to the harness

## Build and run

```sh
export WINEPREFIX=/path/to/prefix          # any prefix; nothing special is needed
export WINEDEBUG=-all                      # Wine is very chatty otherwise
BUILD=/tmp/visnharness                     # build artefacts stay out of the repo

tools/wine_visn/build.sh "$BUILD"
cp gog_incubation/Eng3d.dll gog_incubation/ENGWLIB.DLL "$BUILD/"

# 1. liveness self-test: load the DLL and call a known-constant export
( cd "$BUILD" && wine visn_harness.exe Eng3d.dll )

# 2. all 723 shipped records, full size
python3 tools/wine_visn/visn_compare.py gog_incubation --build-dir "$BUILD"

# 3. the same through _E3D_decode_picture_halve_size
python3 tools/wine_visn/visn_compare.py gog_incubation --build-dir "$BUILD" --op halve

# 4. synthetic records: every group (108 cases)
python3 tools/wine_visn/visn_probe.py --build-dir "$BUILD"

# ...or one group at a time
python3 tools/wine_visn/visn_probe.py --build-dir "$BUILD" --only size
```

`visn_probe.py --only` takes one of:

| Group | What it settles |
|---|---|
| `mode0` | mode 0's Y sub-block layout and chroma upsampling |
| `escape` | escape widths 1..12 at the edges of their signed ranges |
| `quality` | the IJG scaling formula across quality 1..100 |
| `mode0size` | mode 0 at sizes past the original four, up to 256 x 256 |
| `halve0` | mode 0 through `_E3D_decode_picture_halve_size` (it is *not* halved) |
| `size` | mode 2 above one texture page, up to 1024 x 1024 and 8192 x 16 |

`size` runs one harness invocation per width, because the destination stride is
a property of the whole job — and it seeds the stride cache
(`VISN_POKE_STRIDE`) rather than let the DLL patch its own code. That is sound
for mode 2 only, which is why `mode0size` stays at stride 256.

`visn_compare.py` also takes `--containers PAT`, `--limit N`, `--stride N`,
`--patch-quality Q` and `--patch-size WxH`; the last two rewrite the record
header in memory so the engine can be pushed outside the single configuration
retail data uses. The game directory is never written to.

## The calling convention

The exported symbols are **ordinary cdecl functions**, despite the internals
being hand-written assembly with a register convention. Each export is a thunk
that moves stack arguments into registers before calling the real body:

```
_E3D_decode_picture  @ 0x4023e8
        push ebx / push esi / push edi
        mov eax, [esp+0x18]     ; arg3 -> EAX  destination stride, in pixels
        mov edi, [esp+0x14]     ; arg2 -> EDI  destination buffer
        mov esi, [esp+0x10]     ; arg1 -> ESI  the VISN record
        call 0x41263c
        pop edi / pop esi / pop ebx
        ret                     ; plain ret, so the caller cleans up: cdecl
```

```c
void _E3D_init_vision(int pixel_format);                      /* 0x565 or 0x555 */
void _E3D_decode_picture(const void *record, void *dst, int stride_pixels);
void _E3D_decode_picture_halve_size(const void *record, void *dst, int stride_pixels);
```

There is **no usable return value**: the body is wrapped in `pushal`/`popal`, so
`EAX` on return is just the stride handed back. The harness therefore detects
success structurally — it pre-fills the destination with a poison byte and
reports exactly which bytes changed, plus a guard region past the end that must
stay untouched. A run in which the DLL silently did nothing shows up as
"DLL wrote nothing" rather than as a spurious match.

## Two traps worth knowing

**The colour tables are not bounds-checked.** Y, Cb and Cr index saturating
lookup tables that span index −128..+383, and the engine does not clamp before
indexing them. A picture whose samples leave that window makes the real decoder
read outside its tables and fault. This is why re-quantising a retail record
below quality 89 crashes the DLL: the coefficients grow until the samples leave
the window. Our Python clamps instead, so it survives where the DLL does not.

**Changing the stride needs writable code.** The engine caches the destination
stride at `0x0041a988` (initial value 256). If a decode asks for a different one
it calls `0x413570`, which *patches its own code*, storing `2 * stride` into the
immediate operands of four instructions in the mode-0 colour stage. `Eng3d.dll`'s
`BEGTEXT` section is not writable, so that store faults on any loader that
honours page protection. Set `VISN_POKE_STRIDE=N` to seed the cache directly and
skip the patch — mode 2 reads its row step from a variable
(`add edi, [0x41a98c]`) and so decodes correctly at any stride.
`VISN_WRITABLE_TEXT=1` asks for `PAGE_EXECUTE_READWRITE` over the code section
instead, but arm64 macOS refuses to hand out RWX mappings, so it does not help
there.

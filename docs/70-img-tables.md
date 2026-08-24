# `.IMG` — fixed-point lookup tables

**Status: fully solved. Both tables regenerate from a formula and match the
shipped bytes to within 1 unit.**

Despite the extension, `WorldSet/World_*/IMG/*.IMG` are not images. They are two
static maths tables used by the Eng3d renderer. All 42 files are copies of just
**two distinct blobs**, byte-identical across every world set — they carry no
per-world content and a remake can simply generate them.

Verified with `python3 tools/img_tables.py gog_incubation` (exits 0).

---

## Angle convention

The engine uses a **4096-unit circle** (binary degrees): a full turn is 4096, a
quarter turn 1024. Both tables follow that convention, and this is confirmed in
the machine code, not merely inferred: every sine lookup masks its index with
`& 0xFFF`, and the `atan2` routine reduces its result with `& 0xFFF` after
adding `0x800` (half turn) or subtracting from `0x400` (quarter turn).

Both tables are loaded verbatim from disk into two adjacent globals by the same
function (`Eng3d.dll` `FUN_00401748` / `ENG3DFX.DLL` `fcn.00401748`), which
reports `3DENGINE STARTUP: cannot read <path>` on failure. The debug symbols in
the DLLs name them **`trig_table`** and **`atn_table`**.

## `ATN.IMG` — arctangent

1025 entries of `u16`, values `0 .. 512`.

```
ATN[i] = round( atan(i / 1024) * 4096 / (2*pi) )     for i in 0..1024
```

Indexed by a ratio scaled to 1024, returning an angle in engine units over the
first octant (0..512 = 0°..45°). Callers reduce the general case to this octant
by swapping and negating the operands, the standard `atan2` construction.

All 1025 entries match exactly.

**The 1025th entry is real, not padding.** The engine's `atan2`
(`Eng3d.dll` @ `0x412... `, decompiled around the `atn_table` access) computes:

```c
lo = min(|x|, |y|);  hi = max(|x|, |y|);
angle = atn_table[ ((lo << 14) / hi) >> 4 ];   // == (lo/hi) * 1024
if (|y| <= |x|)      angle = 0x400 - angle;    // reflect about 45 degrees
if ((x ^ y) < 0)     angle = -angle;
if (y < 0)           angle += 0x800;           // half turn
return angle & 0xFFF;
```

When `lo == hi` (exactly 45 degrees) the index is exactly 1024, so the final
entry is reachable. This also confirms the input scale of 1024 and the
4096-unit output.

## `TRIG.IMG` — sine, with a cosine window

5120 entries of `int16` (stored as `u16`), Q14-style fixed point with a peak of
**16383**.

```
TRIG[i] = trunc( sin(2*pi*i / 4096) * 16383 )        for i in 0..5119
```

The table is 4096 + 1024 entries long so that cosine needs no wrap-around
check:

```
sin(a) == TRIG[a]
cos(a) == TRIG[a + 1024]        for a in 0..4095
```

The trailing 1024 entries repeat the first quarter period; that repetition was
verified entry by entry (max deviation 1).

**Confirmed in the machine code.** Both renderers address the cosine window as
a *separate base pointer* at `trig_table + 0x800` (0x800 bytes = 1024 entries of
2 bytes), with the index masked to `0..4095` exactly as for sine:

```
Eng3d.dll     movsx eax, word [eax + eax + 0x48EEC0]   ; trig_table + 0x800
ENG3DFX.DLL   movsx eax, word [eax + eax + 0x48C620]   ; trig_table + 0x800
```

So indices do reach 5119 and **all 5120 entries are used**. The `movsx`
(sign-extending load) also confirms the entries are **signed int16**, not
unsigned.

> Worth noting how this was nearly missed: the Ghidra decompilation of
> `Eng3d.dll` shows every sine access as `trig_table[i & 0xFFF]` and none
> beyond, because it resolved the `+0x800` base into a *different* symbol. Read
> naively, that suggests the last 1024 entries are dead. The raw disassembly
> shows otherwise. When a decompiler's symbol resolution is doing the reasoning
> for you, check the instructions.

The shipped table was generated with single-precision floats, so individual
entries deviate from the exact formula by at most 1 unit. `tools/img_tables.py`
allows exactly that tolerance and fails on anything larger, which is what makes
the check meaningful rather than vacuous.

---

## Open questions

1. The exact rounding rule Blue Byte used to *generate* the sine table is
   unknown — truncation at scale 16383 is the best fit (3073 of 5120 entries
   exact, the rest off by one), but no rule reproduces the table bit-for-bit.
   This is a property of a 1997 build tool that no longer exists and is very
   likely unrecoverable. Since the table is data, a remake should ship the
   original bytes if bit-exact behaviour matters, and otherwise generate its
   own — a one-unit difference in a Q14 sine is far below the engine's own
   fixed-point noise floor.

*(The former question 2 — whether `ATN[1024]` is ever indexed — is closed: it
is, in the exactly-45-degree case. See above.)*

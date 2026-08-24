# `.sav` — the save game

**Status:** structure complete, 0 sample files. Every claim below is checked
against `Incubation.exe` by `tools/sav_tables.py --check`.

This is the only format the *game* writes. Everything else in `docs/` is
produced by an authoring tool and only read at run time, so the corpus can
prove it; here there is no corpus — the shipped `Work/Saves/` tree is empty.
What replaces it is that the writer and the reader are both in the binary and
must agree, which pins every offset and size exactly. `.lev` was recovered from
the same position before a single byte of a `.lev` had been read.

`tools/sav_parse.py` implements the layout and is ready for the first real
save; it is deliberately **not** in the always-run corpus block, because a
check with nothing to examine is not a check that passed.

---

## 1. What the format is

`aSaveGame` (`0x00448AD0`, `aLoad.cpp:1309`) is a linear chain of eight block
writers between an open and a close. Seven of the eight do exactly one
`WriteFile` of a fixed `.data` address; the eighth, `aSaveBattleMap`, is itself
a chain of six (§6):

```c
aOpenFile(&h, "Work\\Saves\\_0_.sav")   /* aLoad.cpp:1309 */
aSaveGameFileHeader(h)                  /* aLoad.cpp:1319 */
aSaveGameControl(h)                     /* aLoad.cpp:1329 */
aSaveViewPlayer(h)                      /* aLoad.cpp:1339 */
aSaveUnitPool(h)                        /* aLoad.cpp:1349 */
aSaveBattleMap(h)                       /* aLoad.cpp:1359 */
aSaveProgramState(h)                    /* aLoad.cpp:1369 */
aSaveLCL(h)                             /* aLoad.cpp:1379 */
lSaveMissionObjectives(h)               /* aLoad.cpp:1389 */
CloseHandle(h)
```

`aLoadGame` (`0x00448E60`, `aLoad.cpp:1544`–`1649`) is the same chain in the
same order with the same sizes, `aLoadFile` instead of `aWriteFile`. That
symmetry is what turns a write trace into a file format.

There is **no magic number, no length field and no version in the file
header.** The version stamp is a single byte buried in block 2 (§5.4), and the
only thing that makes the file parseable at all is that every block but one is
a compile-time constant size.

Consequences that a remake's loader has to accept:

- These are `fwrite` dumps of C globals from an MSVC debug build, so the same
  warnings as `.lev` apply: uninitialised tails, stale pointers, `0xCD` fill.
  The comment block (§5.1) is a clear case — only the string is written, the
  other 200-odd bytes are whatever the buffer held.
- The file is opened with `OPEN_ALWAYS`, **not** `CREATE_ALWAYS`
  (`0x004389B0`), and nothing calls `SetEndOfFile`. Saving a small map over a
  slot that previously held a large one leaves the old tail in place. A parser
  must compute the expected size and stop there; it must not trust the file
  length. Only `size_on_disk >= computed_size` can be asserted.

---

## 2. Where the files live

The name is built by `aBuildSaveName(slot, buf)` at `0x00449340` and then
prefixed with directory id 6 by `0x004632B0`:

```c
wsprintfA(dir, aIsSaves2() ? "Saves2" : "Saves");     /* 0x0043BEE0 */
switch (saveMode) {                                    /* [0x0050C76C] */
  case 4:        wsprintfA(out, "%s\\Scenario\\_%d_.sav", dir, slot); break;
  case 2: case 3:wsprintfA(out, "%s\\PBM\\_%d_.sav",      dir, slot); break;
  default:       wsprintfA(out, "%s\\_%d_.sav",           dir, slot); break;
}
```

The shipped tree corroborates it exactly — `Work/Saves/`, `Work/Saves2/`, each
with `Pbm/` and `Scenario/` — and those four directories are the only thing in
the retail release that touches this format at all.

### 2.1 The five modes — **[text] `Txtmod_f.lcl`**

`saveMode` is a private global with a single writer, `aSetSaveMode`
(`0x00448770`). Its five values are not guesswork: the save/load screen puts
the mode straight through a jump table (`0x00448410`) into a GUI text id, and
`DATA/TXT/English/GUI/Txtmod_f.lcl` names them.

| mode | text id | label in `Txtmod_f.lcl` | directory |
|---|---|---|---|
| 0 | 10 | `Load` | `Saves\` |
| 1 | 11 | `Save` | `Saves\` |
| 2 | 12 | `Load play by mail` | `Saves\PBM\` |
| 3 | 13 | `Save play by mail` | `Saves\PBM\` |
| 4 | 18 | `Scenario` | `Saves\Scenario\` |

**Play-by-mail is a real, shipped game mode** with no other trace in the
documentation. The same text module carries its password prompts —
`%:014 "Enter a new password:"`, `%:015 "Enter the password:"`,
`%:016 "Password"`, `%:017 "Password incorrect"` — and the passwords
themselves live in the save file (§5.3).

### 2.2 `Saves` versus `Saves2` — **[code] `0x004499B9`**

`0x00509A40` selects the directory and has exactly one writer, reached once
during start-up. The test is:

```c
aFindFileOnFixedDrives(buf, "Incubation\\aWin.dll");   /* 0x00438F20 */
aSetSaves2(found ? 1 : 0);                             /* 0x0043BED0 */
```

`0x00438F20` walks drive letters `A`..`Z`, keeps those whose `GetDriveTypeA` is
`DRIVE_FIXED`, and tests `<drive>:\Incubation\aWin.dll`. So `Saves2` is chosen
when a *second, installed* copy of the game is present on a fixed disk — the
CD-run-alongside-an-install case. In the GOG release no such path exists, so
`Work\Saves\` is always used and `Work\Saves2\` is dead. Documented because the
directory ships and would otherwise look like an unexplained duplicate.

> The preceding test in the same function searches for
> `Incubation\Incubation.exe` and its `test eax, eax` is followed by an
> **unconditional** `jmp` (`0x0044997B`), skipping a bail-out at `0x0044997D`.
> That is a patched conditional — the original install/CD check — and it is
> the only such patch on this path. UNVERIFIED whether GOG or Blue Byte made
> it; it does not affect the format.

---

## 3. Top-level layout

| Offset | Size | Block | Source global | Writer |
|---|---|---|---|---|
| `0` | 261 (`0x105`) | Comment | `0x0050C240` | `aSaveGameFileHeader` `0x00448D10` |
| `261` | 720 (`0x2D0`) | GameControl | `0x00509D18` | `aSaveGameControl` `0x0043BC30` |
| `981` | 1100 (`0x44C`) | ViewPlayer | `0x005229D0` | `aSaveViewPlayer` `0x0047DBE0` |
| `2081` | 5460 (`0x1554`) | UnitPool | `0x0051F2A0` | `aSaveUnitPool` `0x00479220` |
| `7541` | `864 + 23·W·H + 203824` | **BattleMap — a complete `.lev` image** | see §6 | `aSaveBattleMap` `0x00419820` |
| … | 12 (`0xC`) | ProgramState | `0x004FEA50` | `aSaveProgramState` `0x0042E910` |
| … | 109 (`0x6D`) | LCL variables | `0x0050B850` | `aSaveLCL` `0x004406B0` |
| … | 28 (`0x1C`) | MissionObjectives | `0x00512590` | `lSaveMissionObjectives` `0x0045FF90` |

Only the `.lev` image varies, and only with the map dimensions, which it
carries itself. So the whole file size is determined:

```
sav_size = 212378 + 23 * width * height
```

where `height` is the `u32` at `sav + 7541 + 0x357` and `width` the `u32` at
`sav + 7541 + 0x35B` (`docs/10` §3). For the corpus' 20×20 … 40×40 maps that
is 221578 … 249178 bytes.

The 7541-byte prefix is fixed, so **the map dimensions are readable at a
constant offset** and a parser needs no back-and-forth.

---

## 4. The slot directory

The save/load screen keeps an in-memory directory at `0x0050C778`, stride
`0x84` = 132:

| Offset | Type | Meaning |
|---|---|---|
| `+0x00` | `u32` | 1 = slot occupied, 0 = free |
| `+0x04` | `char[128]` | the comment the player typed |

`aScanSaveSlots` (`0x004488B0`) walks it from `0x0050C778` to `0x0050D6F0`,
i.e. **30 slots**. For each, it builds the name, tries to open the file, and
either copies the file's own comment block in and sets the flag, or copies GUI
text 1 in and clears it — `Txtmod_f.lcl` `%:001` is `-- Empty --`, which is
what an unused slot shows on the screen. `aSaveGame` sets `+0x00` to 1 before writing.

Two loose ends, recorded as observed rather than explained:

- `aGetGameComment` (`0x00448A30`) bounds-checks `0 <= slot <= 39`, ten slots
  past what the scanner refreshes. The extra records exist in `.data`; nothing
  refreshes them.
- `0x00448A50` deletes **slot 32** specifically, hard-coded, and clears
  `0x0050D7F8`. Its only caller is `0x00419E75`, in the same block as three of
  the five `aSaveGame` call sites. Slot 32 is therefore an internal staging
  slot rather than a player-visible one, but the code carries no name for it,
  so it is left at that. **UNVERIFIED.**

---

## 5. The fixed blocks

### 5.1 Comment — 261 bytes at `0`

A NUL-terminated ASCII string in a `char[261]` buffer. 261 = `MAX_PATH + 1`,
the same buffer size the engine uses for every path (§2). Only the string and
its terminator are written; the remainder is stale heap and must be ignored.

This is the only block the save/load screen reads on its own — `aScanSaveSlots`
opens each file, reads exactly these 261 bytes, and closes it again.

### 5.2 GameControl — 720 bytes at `261`

`aGameControl.cpp`. One C struct reached through a bank of one-line accessors
at `0x0043AD00`–`0x0043BF20`; as with the `.lev` header, the addresses those
accessors touch give the offsets directly. Thirty distinct offsets are
referenced. The ones whose meaning is established:

| Offset | Type | Meaning | Accessor |
|---|---|---|---|
| `+0x0105` | `u8` | UNVERIFIED | `0x0043B280` |
| `+0x0108` | `u32[4]` | per-player "slot in use" | `0x0043B930` |
| `+0x0118` | `u8` | **max player index** | `0x0043B310` |
| `+0x0119` | `u8` | previous player (copied from `+0x011A`) | `0x0043B2D0` |
| `+0x011A` | `u8` | **current player**; `0xFF` = none | `0x0043B2C0` |
| `+0x011B` | `u8` | UNVERIFIED | — |
| `+0x016B` | `char[4][25]` | **player passwords** — see §5.3 | `0x0043B660` |
| `+0x01D0` | `u8` | **game mode**, 1…4; anything else raises `"GameControl undefined"` | `0x0043B740` |
| `+0x01D1` | `u8` | UNVERIFIED | `0x0043B760` |
| `+0x01D2` | `u8` | **version stamp** — see §5.4 | `0x0043BEF0` |
| `+0x0230` | `struct[4]`, stride 40 | **campaign scoreboard** — see §5.5 | `0x0043BA00` |

The remaining referenced offsets (`+0x0000`, `+0x01D4`, `+0x01E4`, `+0x01E8`,
`+0x01EC`, `+0x01F0`, `+0x01F4`, `+0x01F8`, `+0x01FC`, `+0x0200`) are read and
written only inside `aGameControl.cpp` and are left **UNVERIFIED**; a name
guessed from an access pattern is worse than no name.

`0x0043BD20` copies the whole 720 bytes to `0x00509A48` and `0x0043BD40` copies
them back. That mirror is runtime scratch — an undo buffer — and is not part of
the file.

### 5.3 Play-by-mail passwords — **[code] `0x0043BCC0`**

Four 25-byte slots at `+0x016B`, addressed as `+0x016B + player*25`
(`0x0043B660`, which rejects an out-of-range player with `"invalid param"`).

They are obfuscated on the way out and back in by the same involution, called
immediately before and immediately after the `WriteFile`:

```c
for (p = base; p < base + 100; p += 25)
    if (strcmp(p, "INVALID_PASSWORD") != 0)
        for (i = 0; i < 25; i++) p[i] = ~p[i];
```

So an unset slot is stored as the literal ASCII `INVALID_PASSWORD`, and a set
one as the bitwise complement of its 25 bytes. The sentinel is compared as a
C string *before* the flip, which is why it survives in plaintext.

This is the same "obfuscate, don't encrypt" reflex as the `.lcl` scripts
(`docs/20` §2) — a different operation, the same intent.

### 5.4 The version gate — **[code] `0x00448F3E`**

`aSaveGameControl` stamps the running build number into the blob just before
writing it:

```c
gameControl[+0x01D2] = *(u8*)0x00522ED0;    /* 0x0043BC49 */
```

and `aLoadGame` refuses the file between blocks 2 and 3:

```c
if (build >= 150 && aGetGameMode() != 1 && saved_build != build)
    return FALSE;                            /* 0x00448F68 */
```

Two escapes: builds below 150 skip the check entirely, and game mode 1 is
exempt. The refusal is silent — `aLoadGame` returns `FALSE` with no trace
call, unlike every other failure path in the function.

For a remake this is the only field that behaves like a format version, and it
is a *build* number, not a format revision: any two builds refuse each other's
saves regardless of whether the layout changed.

### 5.5 The campaign scoreboard — `+0x0230`

Four records of 40 bytes. `0x0043B990` resets one by writing nine dwords —
`+0x00`…`+0x1C` to 0 and `+0x20` to 1 — so at least the first 36 bytes are
live and the last 4 are padding.

`+0x20` is the **mission result**, and the end-of-mission scorer at
`0x0043BA10` maps it to a base score:

| result | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| base score | −100 | 0 | +100 | +200 | +300 |

anything else raises `"unknown missionresult"`. The final score is
`record[+0x00] * difficultyMul − 2 * record[+0x08] + base`, where
`difficultyMul` is 1, 2 or 3 from the difficulty setting (`docs/20` §7.6) and
applies only in game mode 1. The meaning of `+0x00` and `+0x08` individually is
**UNVERIFIED**.

### 5.6 ViewPlayer — 1100 bytes at `981`

`aViewPlayer.cpp`. Written and read as one opaque block; the file format
imposes nothing on it beyond its size. Not decoded here — it is camera and
per-player view state, not game state a loader has to understand to place a
unit. **UNVERIFIED** in full.

### 5.7 UnitPool — 5460 bytes at `2081`

The persistent squad roster, `docs/10` §5.11: 91-byte unit records at
`0x0051F2A0`, indexed `(player * 31 + slot) * 0x5B`, 30 usable slots per
player.

`aInitUnitPool` (`0x00478600`) settles the array's true shape, which the
accessors alone could not:

```asm
edx = 0x51F2A0
loop:  ecx = 682;  edi = edx;  edx += 0xB05       ; row stride 2821 = 31 * 91
       rep stosd                                  ; 2728 bytes
       stosw                                      ; + 2 = 2730 = 30 * 91
       cmp edx, 0x5229B9 ; jl loop
```

Row stride 2821 = 31 records, of which 30 are cleared; total span
`0x5229B9 − 0x51F2A0` = 14105 = **5 rows exactly**. So the array is
`aUnit pool[5][31]` — five players, 31 slots each with the last one unused —
and `sizeof` is 14105 bytes.

**The save writes 5460 of them.** 5460 = `2 * 30 * 91`, the count of *usable*
slots for two players — but the array's rows are 31 records apart, so a flat
5460-byte write from the base does not line up with them:

| records | what they are | saved? |
|---|---|---|
| 0…29 | player 0, slots 0…29 | yes |
| 30 | player 0's unused 31st slot | yes |
| 31…59 | player 1, slots 0…28 | yes |
| 60 | **player 1, slot 29** | **no** |
| 61…154 | player 1's unused slot, players 2…4 | no |

The writer and the loader use the same constant, so a save round-trips and the
bug is invisible in normal play — but **player 1's last roster slot does not
survive a save**, and players 2–4 have no persistent roster at all. Whether
those players can hold one is a runtime question the shipped data cannot answer
(`max player` is a save-file field, §5.2), so the consequence is recorded and
not extrapolated.

A remake should size this block from the two constants that agree — 5460 — and
treat the ragged tail as the original's behaviour, not as something to fix in
the parser.

### 5.8 ProgramState — 12 bytes

`aController.CPP`. Three `u32` at `0x004FEA50`, `0x004FEA54`, `0x004FEA58`,
each with its own getter/setter in `0x0042E890`–`0x0042E910`. Meanings
**UNVERIFIED**.

### 5.9 LCL variables — 109 bytes

The mission script's local variable bank, `docs/20` §4.1: `0x0050B850`,
**28 × `int32`** = 112 bytes, cleared to `-1` by `0x0043FC70`, indexed `_A`…`_Z`
plus two more.

The save writes and reads **109**. 109 = `27 * 4 + 1`, so variables 0…26 are
persisted whole and variable 27 keeps only its lowest byte; its upper three
bytes are left at whatever the running process already had. This is the same
class of mistake as §5.7 and, like it, is symmetric between writer and reader,
so it never shows up as a corrupt file.

Recorded here because a remake that stores 28 clean variables and a remake
that reproduces the original's behaviour will diverge on any mission that uses
slot 27 — and `docs/20` §4.1 shows the parameter classifier does accept it.

### 5.10 MissionObjectives — 28 bytes

`aMultiPlayer.cpp`, `0x00512590`. Seven distinct offsets are referenced:
`+0x00`, `+0x01`, `+0x02` (`u8`), `+0x04`, `+0x06` (`u16`), `+0x08`, `+0x18`.
Meanings **UNVERIFIED**. The `l` prefix on `lSaveMissionObjectives` is the
multiplayer module's own convention, not a typo.

---

## 6. The embedded `.lev` — 7541 …

`aSaveBattleMap` (`0x00419820`) writes exactly the block sequence that
`docs/10` §2 documents as the `.lev` file format, from the same globals, in the
same order:

| Sub-block | Size | Source | Writer |
|---|---|---|---|
| Header | 864 (`0x360`) | `0x004FCED0` | inline, `aBattleMap.cpp:2984` |
| CtrlMap | `23 · W · H` | `[0x004FEB6C]` | `aSaveCtrlMap` `0x00430FB0` |
| UnitMap | 18200 (`0x4718`) | `[0x005229C4]` | `aSaveUnitMap` `0x004791E0` |
| 3D objects 1 | 724 (`0x2D4`) | `0x004FA528` | `aSave3DObjects` `0x00407B20` |
| 3D objects 2 | 9900 (`0x26AC`) | `0x00404C70(0)` | same |
| 3D objects 3 | 175000 (`0x2AB98`) | `0x00404C40(0)` | same |

The CtrlMap size is computed as `(n*24) − n` = `23n` from the cell count at
`[0x004FEB70]`, which the header just supplied — so the block is
self-describing exactly as it is in a standalone `.lev`.

That is six writes, which is why `aSaveBattleMap` is the one link in §1's chain
that is not a single `WriteFile`.

**So a save contains a byte-identical `.lev` image**, and every field table in
`docs/10` applies to it unchanged: the cell grid, the 200 unit slots, the two
object arrays. The difference is only in *what* is in it — a `.lev` on disk is
the mission's initial state, the copy inside a `.sav` is its state at the
moment of saving, with the runtime fields `docs/10` marks as scratch now
carrying live values (`+0x4F` visibility, `+0x3E`/`+0x40` heat and
malfunction, the `0x50`–`0x5E` attack scratchpad — `docs/22`).

A parser can therefore slice bytes `7541 … 7541 + 864 + 23·W·H + 203824` out of
a save and hand them to `tools/lev_parse.py` unchanged. `sav_parse.py` does
exactly that.

---

## 7. Directory ids — **[code] `0x00462EE0`**

Not part of the format, but §2 needs id 6 and the table is free. Fifteen
`char[261]` buffers at `0x00512FF0`, stride `0x105`, each holding the game root
with a subdirectory appended at start-up:

| id | buffer | suffix | id | buffer | suffix |
|---|---|---|---|---|---|
| 0 | `0x00512FF0` | `Graphics\` | 8 | `0x00513818` | `Waves\` |
| 1 | `0x005130F5` | `Fonts\` | 9 | `0x0051391D` | `Missions\` |
| 2 | `0x005131FA` | `Temp\` | 10 | `0x00513A22` | `WorldSet\` |
| 3 | `0x005132FF` | `Misc\` | 11 | `0x00513B27` | `WorldDesc\` |
| 4 | `0x00513404` | `Libs\` | 12 | `0x00513C2C` | `CHData\` |
| 5 | `0x00513509` | `Data\` | 13 | `0x00513D31` | `Video\` |
| 6 | `0x0051360E` | **`Work\`** | 14 | `0x00513E36` | `Briefing\` |
| 7 | `0x00513713` | *(none)* | | | |

Id 7 is the only one the initialiser never appends to: it is the bare game
root. `0x00463150` dispatches on the id through a jump table and `0x004632B0`
concatenates a relative name onto the chosen buffer.

---

## 8. Verification

Two tools, because there are two things to be wrong about: what the binary
does, and whether the parser implements it.

`tools/sav_tables.py --check gog_incubation` reads `Incubation.exe` and runs
**69 checks**. It recovers the writer and reader chains from the machine code
— the guarded-call names, and the `push imm` operands at every
`aWriteFile`/`aLoadFile` — so the addresses and sizes come out of the binary
rather than out of this document:

- the writer chain — eight block writers, in order, from `aSaveGame`;
- the loader chain — the same eight, in the same order, from `aLoadGame`;
- every block's source address and size, on both sides;
- writer and loader agree on all eight fixed blocks;
- the battle-map sub-chain, its six sizes, and the `23 = n*24 − n` stride;
- the size identity, `212378 + 23·W·H`;
- the three filename format strings, the `Saves`/`Saves2` pair, and that both
  the mode and the `Saves2` flag have exactly one writer each;
- directory id 6 resolves to `Work\`, and all fifteen buffers and suffixes;
- the password span, stride, slot bound and `INVALID_PASSWORD` sentinel, and
  that the flip brackets the write;
- the version stamp's offset and the loader's `>= 150` gate;
- the slot directory's base, stride, 30-slot scan and 40-slot accessor bound;
- the unit-pool row stride, row count, and the resulting shortfall (§5.7);
- the LCL bank's 28 entries against the 109 bytes written (§5.9);
- the scoreboard's stride and that four records land exactly on the block end;
- the mode → text-id jump table against `Txtmod_f.lcl`'s five labels.

`tools/sav_parse.py gog_incubation --selftest` checks the parser instead. No
save exists, but the largest block of one does: a save is a `.lev` image with
7541 bytes of fixed prefix and 149 of fixed suffix. The self-test wraps a
corpus mission in those blocks, reads it back, and requires every field to
survive and the extracted `.lev` to be **byte-identical** to the original. It
does this once per distinct map size — **31 of them across all 155 missions**,
which is every size a save can have, since nothing else changes the layout.

The self-test asserts its layout constants against the literals in §3 before
building anything. Without that it would be circular: a wrong constant would
move the field and the expectation together and the round trip would still
pass.

Both tools were mutation-tested: **12 perturbations** of `sav_tables.py` and
**10** of `sav_parse.py` — sizes, offsets, strides, block order, a swapped
width/height pair — every one of the 22 detected. Both fail on an empty root.

`tools/sav_parse.py FILE` is the part that has never run against real data.
`--lev OUT.lev` extracts the embedded battle map so `lev_parse.py` can validate
it independently; that alone covers about 95 % of the bytes in a save. It is
deliberately **not** in the always-run corpus block: with `Work/Saves/` empty
it exits non-zero and says why, rather than reporting a pass over nothing.

## 9. Open questions

1. **ViewPlayer's 1100 bytes** (§5.6). Not decoded. It is one opaque block with
   20 distinct offsets already visible from absolute-displacement accesses
   scattered through `aViewPlayer.cpp` (`0x0047BC00`–`0x0047EB70`); walking
   those accessors would settle the block the same way the `.lev` header's bank
   settled it. Left open deliberately — it is view state, and a remake will not reuse the original's
   camera representation.

2. **Ten GameControl offsets** (§5.2) and **three ProgramState dwords** (§5.8)
   and **seven MissionObjectives offsets** (§5.10). All are read and written
   only within their own module and never compared against a literal, so
   nothing in the binary distinguishes them. With no sample file there is no
   value distribution either. These need one real save to move.

3. **Slot 32** (§4). Deleted by name from one call site; no code names it.

4. **`0x00509A40`'s second consumer.** The `Saves2` flag is read only by
   `aBuildSaveName`. If a second installed copy was meant to share anything
   else, no trace of it survives.

Items 1–3 are open for want of a sample, not for want of analysis; item 4 is
closed in the sense that it has been enumerated — there is no second consumer.

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

  Two runs of a campaign mission corroborate the shape without naming it: the
  game wrote `_31_.sav` by itself as the mission started and `_33_.sav` later,
  both with an **empty comment** and both with the automatic ProgramState pair
  `(3, …)` rather than the manual `(5, …)` (§5.8). So 31, 32 and 33 are one
  group of internal slots, of which the code deletes exactly the middle one.

  **Slot 31 is the mission-entry snapshot.** A campaign advancing from one
  mission to the next writes it 27 seconds after the player's own save on the
  location screen and 36 seconds before their first save inside the new
  mission, and everything in it says "the mission has loaded but has not
  started":

  - it carries the **new** mission (`_C_141`) and its map, not the old one;
  - its **turn counter is 0** — no hand-over has happened yet
    ([`25` §3](25-turn-and-round.md));
  - LCL slot 0 still holds the **previous** mission's result, which the new
    mission clears ([`20` §7](20-lcl-language.md));
  - its unit pool holds the roster in **both** banks (§5.7), catching the copy
    mid-flight.

  Slot 33 is written later in the mission and its previous-state value varies;
  what triggers it is not established. Which of the three the deletion at
  `0x00448A50` is aimed at, and what the states are called, still needs the
  controller state machine — package B/F. **UNVERIFIED.**

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
| `+0x0000` | `char[]` | **current mission name** — `_C_140` in the sample saves, the same string the embedded `.lev` header carries at its `+0x105` | — |
| `+0x0105` | `u8` | **turn counter**, wrapping at 200 ([`25` §3](25-turn-and-round.md)) | `0x0043B280` |
| `+0x0108` | `u32[4]` | **player kind**; `0` = the slot is not in the game, `1` = a human player | `0x0043B6E0` |
| `+0x0118` | `u8` | **player-slot count** — 1 in campaign mode, 4 otherwise | `0x0043B310` |
| `+0x0119` | `u8` | previous player (copied from `+0x011A`) | `0x0043B2D0` |
| `+0x011A` | `u8` | **current player**; `0xFF` = the computer side | `0x0043B2C0` |
| `+0x011B` | `char[4][20]` | **player names** | `0x0043B600` |
| `+0x016B` | `char[4][25]` | **player passwords** — see §5.3 | `0x0043B660` |
| `+0x01D0` | `u8` | **game mode**: 1 `campaign`, 2 `net session`, 3 `local session`, 4 `pbm session`; anything else raises `"no gametype selected"` ([`25` §2](25-turn-and-round.md)) | `0x0043B740` |
| `+0x01D1` | `u8` | **Campaign number** — `1` selects `Missions/_C_XXX.lev` as the campaign map, `2` selects `_C_YYY.lev` ([`27` §2.1](27-campaign.md)) | `0x0043B760` |
| `+0x01D2` | `u8` | **version stamp** — see §5.4 | `0x0043BEF0` |
| `+0x01D4` | `u32[4]` | **equipment points** per player; the add clamps at 10000 | `0x0043B010` |
| `+0x01E4` | `u8[4]` | **commendations** per player ([`20` §7](20-lcl-language.md) slot 11) | `0x0043B0F0` |
| `+0x01F0` | `u32` | **solo flag** — set when the human count is `<= 1`; it is what puts the computer into the rotation ([`25` §3](25-turn-and-round.md)) | `0x0043B1E0` |
| `+0x0200` | `u32[12]` | the **LCL game-control slots** ([`20` §7](20-lcl-language.md)) | `0x0043B160` |
| `+0x0230` | `struct[4]`, stride 40 | **campaign scoreboard** — see §5.5; the field at its `+0x20` is the per-player end state, `5` = out of the rotation | `0x0043BA00`, `0x0043B930` |

**The block carries residue from earlier menu visits, and a loader must expect
it.** `0x0043AD20` runs after every game-mode change and has two arms: the
campaign one writes player 0 alone, the other writes all four. In saves from a
session that visited the multiplayer setup before starting a campaign, the
equipment points read `[100, 2000, 2000, 2000]` — player 0's campaign value over
three slots the four-player arm had filled — and the password slots carry the
sentinel (§5.3). In saves from a session that went straight into the campaign,
the same fields read `[100, 0, 0, 0]` and 100 bytes of `0xFF`. Nothing clears
what the previous arm left, so fields belonging to players who are not in the
game are not meaningful.

Five referenced offsets remain: `+0x01E8`, `+0x01EC`, `+0x01F4`, `+0x01F8` and
`+0x01FC`. Five real campaign saves give them their first observed values —
`0`, `1`, `0`, `0`, `0` — all four of the zeros being exactly what
`0x0043AD20`'s campaign arm writes, so the sample constrains them without
naming them. Two of them (`+0x01F4`, `+0x01F8`) have accessors whose
setters are called only from `aMenuSystem.cpp`'s session setup, so they are
multiplayer options rather than turn state; `+0x01F8` is read eleven times and
one of those readers picks between the two arms of the first hand-over's
equipment-point split ([`25` §4.1](25-turn-and-round.md)). None of the six is
ever compared against a literal, so nothing in the binary distinguishes them.
All are left **UNVERIFIED** — a name guessed from an access pattern is worse
than no name.

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

Real saves show both sides of the involution. Three saves from a session that
went straight into the campaign hold **100 bytes of `0xFF`** — the slots were
still all-zero, did not match the sentinel, and were therefore complemented.
Four saves from a session that had passed through the multiplayer setup first
hold the literal `INVALID_PASSWORD` in plaintext, because `0x0043AD20` installs
the sentinel there and the comparison then exempts it from the flip.

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
| base score | 0 | +100 | +200 | +300 | −100 |

anything else raises `"unknown missionresult"`.

> **Corrected.** An earlier revision of this table read the five `mov ebx, imm32`
> arms in *address* order and so had them rotated by one. The compiler's jump
> table at `0x0043BBB8` gives the order above, and it is the one that matches
> how the results are *written* ([`27` §6.2](27-campaign.md)): `0x0043B990`
> resets `+0x20` to **1**, so 1 is "nothing happened" and scores nothing;
> `0x0047D8D1` stamps **5** on every human player as soon as *any* of LCL slots
> 0–4 is set, and `0x0047D924` then puts 2/3/4 back for each player whose own
> slot carries 1/2/3 — so a win passes through 5 and is overwritten, while slot
> 4 (the computer's) set alone leaves the 5 standing, which is the defeat. The
> −100 the real save below shows is a defeat, which fits either reading of that
> one row; the jump table and the writers together settle the rest. The final score is
`record[+0x00] * difficultyMul − 2 * record[+0x08] + base`, where
`difficultyMul` is 1, 2 or 3 from the difficulty setting (`docs/20` §7.6) and
applies only in game mode 1.

**The record is four `(this mission, whole campaign)` pairs**, and the
end-of-mission screen names them. `0x0045E3CE` builds two rows through the
accessor, four fields each, and labels them with `Txtmod_d.lcl`'s GUI text 30
and 31 — `"In Mission"` and `"In Campaign"`:

```c
row(text(30), rec[+0x00], rec[+0x08], rec[+0x10], rec[+0x18]);   /* In Mission  */
row(text(31), rec[+0x04], rec[+0x0C], rec[+0x14], rec[+0x1C]);   /* In Campaign */
```

The four column headings are consecutive slots in the same file — 20 `"Kills"`,
21 `"Losses"`, 22 `"Commendations"`, 23 `"Result"`:

| Statistic | This mission | Whole campaign | Status |
|---|---|---|---|
| **Kills** | `+0x00` | `+0x04` | confirmed |
| **Losses** | `+0x08` | `+0x0C` | confirmed |
| third column | `+0x10` | `+0x14` | **UNVERIFIED** — see below |
| **Result**, the score | `+0x18` | `+0x1C` | confirmed |

Confirmed against a real campaign: a save carrying `[0, 25, 0, 3, 0, 3, 0, 119]`
in those eight fields, and the defeat screen reached from it, showing *In
Mission* Kills 0 / Losses 0 / Result −100 and *In Campaign* Kills 25 /
Losses 3 / Result 19. Both totals line up, and 19 is 119 + (−100): the campaign
score accumulates the mission scores.

So the scorer's formula reads, in words, **`kills * difficulty - 2 * losses +
base(result)`** — and `−100` for a defeat with no kills and no losses is
exactly what it produces.

The third column is left open. The label list makes `"Commendations"` the
natural reading and the observed pair `(0, 3)` agrees with the commendation
count shown at the top of the same screen, but that count is drawn from
GameControl `+0x01E4` (§5.2), the cell renders blank in the sample, and the
campaign's losses happen to be 3 as well — so the value does not distinguish
the candidates.

Nine real saves give record 0 its first observed values. `+0x20` is `1`
throughout, the value `0x0043B990` resets it to. `+0x04` steps up only at a
mission boundary — `0` during the first mission, `25` from the moment the
second is entered, `31` six turns into it — while `+0x00` is `0` at mission
entry and rises during play. `+0x0C`, `+0x14` and `+0x1C` took the values `3`,
`3` and `119` when the first mission ended and did not move again. So the
record accumulates per-mission statistics, but which statistic each field holds
is still **UNVERIFIED**: `+0x00` is not simply the turn counter (a save at turn
10 showed `3`).

### 5.6 ViewPlayer — 1100 bytes at `981`

`aViewPlayer.cpp`. Written and read as one opaque block; the file format
imposes nothing on it beyond its size.

A displacement-aware sweep of `.text` (`tools/turn_tables.py`) finds **18
distinct offsets across 73 reference sites, every one inside
`aViewPlayer.cpp`**, in two clusters with 1024 unaddressed bytes between them:

| Offset | What the code does with it |
|---|---|
| `+0x000` | the hand-over re-entry latch ([`25` §4.1](25-turn-and-round.md)) |
| `+0x004` | the view state, `0`…`3`, set by the hand-over's four switch arms |
| `+0x00C`…`+0x028` | two screen rectangles, initialised to `(0,0,520,340)` and `(60,34,520,340)` |
| `+0x02C` | a buffer from `aGetMemory` / `aDestroyMemory` |
| `+0x030` | an `aCreateTransformColorTable` handle |
| `+0x034` | the `vp.lib` shape-library handle |
| `+0x038` | the `vp.pal` palette handle |
| `+0x03C`…`+0x43B` | **`PALETTEENTRY palette[256]`** — see below |
| `+0x43C`, `+0x448` | two counters |
| `+0x440`, `+0x444` | sound-buffer handles passed to `aDirectSoundPlay` |

**The 1024-byte span is the palette.** It is never addressed by an absolute
displacement because the loader is handed `&block[0x3C]` in a register. Five
real saves settle it: the span is 256 four-byte records, and in every one of
them the fourth byte is `0x04` — Win32's `PC_NOCOLLAPSE` — so it is a
`PALETTEENTRY[256]`. Its RGB triples equal the shipped
`Graphics/vp.pal` ([`50`](50-visn-textures.md) is the texture codec; the palette
format is `docs/60`'s) in **255 of 256** entries. The exception is index 255,
black in the file and `(71, 191, 239)` in every save — a runtime override, and
`255` is the literal the loader is passed at `0x0047BFCE`.

So the whole block is **presentation state**: window rectangles, four resource
handles, the loaded palette, two sound handles, and two bytes of turn
bookkeeping that the turn itself owns ([`25` §4.1](25-turn-and-round.md)).

How little it carries is worth stating outright. Across **seven** real saves —
two different missions, both map sizes in the corpus' range, the campaign
location screen as well as battles, five different turn counts and deliberately
different camera positions — **1099 of the 1100 bytes are byte-identical**. The
one exception is `+0x448`, which holds `0` or `21`.

**The camera is not in this block, and not in the save at all.** The byte
comparison shows it, and loading the save confirms it: the view returns to its
default position. A remake owes the format nothing for camera persistence.

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

**Real saves confirm the indexing, and show the campaign using the two rows as
two banks rather than as two players.** In a campaign that had carried one
surviving soldier out of its first mission, the roster record appears at flat
index **0** on the location screen, at index **31** once the next mission is
running, and at **both** in the mission-entry snapshot (§4). Index 31 is
`(1 * 31 + 0)`, exactly what the formula above predicts for the second row.
Both copies carry `+0x45 = 0` — the same owning player — so the campaign is not
using row 1 as "player 1's roster" but as a **working copy for the mission in
progress**, with row 0 as the between-missions bank.

That sharpens the flat-write bug above: the row that loses its last slot to the
5460-byte write is row 1, the one a campaign mission actually runs on. One
campaign's saves cannot say whether multiplayer uses the rows differently, so
this is recorded as observed and not extrapolated.

**The code says the same thing.** `aCopyUnitPool` (`0x00478910`) copies one
whole usable row — 2730 bytes — and has exactly two call sites: `0x0045A914`
calls `aCopyUnitPool(0, 1)` when a mission starts and `0x0045E9D9` calls
`aCopyUnitPool(1, 0)` when the debriefing screen is left. Row 0 is the bank,
row 1 is the mission's working copy, so the inference above is confirmed from
the binary — see [`27` §3.5](27-campaign.md).

A remake should size this block from the two constants that agree — 5460 — and
treat the ragged tail as the original's behaviour, not as something to fix in
the parser.

### 5.8 ProgramState — 12 bytes

`aController.CPP`. Three `u32` at `0x004FEA50`, `0x004FEA54`, `0x004FEA58`,
each with its own accessor in `0x0042E890`–`0x0042E910`. The accessors give the
**shape** even though the values have no names:

| Routine | Effect |
|---|---|
| `0x0042E8C0(v)` | `prev = cur; cur = v` — enter a state, remembering the one left |
| `0x0042E8E0()` | `cur = prev` — return to it |
| `0x0042E8B0()` | read `prev` |
| `0x0042E8F0(v)` / `0x0042E900()` | set / get the third dword, which is independent of the pair |

So `+0x04` is the **current** controller state and `+0x08` the **previous** one,
with a one-deep push and pop. Seven real saves give the first observed values:

| Save | `+0x00` | current | previous |
|---|---|---|---|
| four manual saves taken inside a battle | 11 | 5 | 3 |
| one manual save taken on the location screen | 11 | 5 | 2 |
| the automatic `_31_` | 7 | 3 | 2 |
| the automatic `_33_` | 7 | 3 | 5 |

Two readings survive that sample and it cannot separate them: *current* may be
the screen, or it may be the save operation itself — every manual save shows
`5` and every automatic one `3`, whatever screen it was taken from. What the
numbers **name** needs the controller state machine, which is package B/F
([`91`](91-game-logic-research-plan.md)). Left **UNVERIFIED**.

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

All 28 bytes are **zero in every one of the five sample campaign saves**, which
is consistent with the owning module: a single-player campaign never fills it.
A campaign save can therefore never characterise this block — only a `net` or
`local session` one could, and that is package H's ground
([`91` §9](91-game-logic-research-plan.md)).

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

**Real saves exist now, outside the repository.** Six of them, produced by
playing the retail game under Wine, are kept in `tests/fixtures/saves/` and are
what this document's §4, §5.2, §5.3, §5.5, §5.6, §5.7 and §5.8 cite. The `.sav`
files themselves are gitignored — each embeds a byte-identical copy of a shipped
`.lev` — but
[`tests/fixtures/saves/README.md`](../tests/fixtures/saves/README.md) is
committed and records what each one pins, with digests.

## 9. Open questions

1. ~~**ViewPlayer's 1100 bytes**~~ (§5.6). **Closed.** A displacement sweep
   partitions the addressed part — 18 offsets across 73 sites, all inside
   `aViewPlayer.cpp` — and five real saves settle the 1024-byte remainder: it
   is `PALETTEENTRY[256]`, matching `Graphics/vp.pal` in 255 of 256 entries
   with index 255 overridden at run time. The block is presentation state from
   end to end and a remake reuses none of it.

2. **Five GameControl offsets** (§5.2, down from eleven — [`25`](25-turn-and-round.md)
   closed the turn counter, the player kinds, the player names, the equipment
   points, the commendations, the solo flag and the LCL slot array, and a real
   save identified `+0x0000` as the mission name, and [`27` §1](27-campaign.md)
   identified `+0x01D1` as the campaign number) and **three ProgramState
   dwords** (§5.8) and **seven MissionObjectives offsets** (§5.10). All are read
   and written only within their own module and never compared against a
   literal, so nothing in the binary distinguishes them. Sample saves now give
   the first two groups a value distribution but not a meaning; the
   MissionObjectives block is all-zero in a campaign save and can only move on a
   multiplayer one.

3. **Slot 32** (§4). Deleted by name from one call site; no code names it. A
   real run shows the game writing slots 31 and 33 by itself, so the three form
   one internal group — which of them is which is still open.

4. **`0x00509A40`'s second consumer.** The `Saves2` flag is read only by
   `aBuildSaveName`. If a second installed copy was meant to share anything
   else, no trace of it survives.

Item 1 closed once a sample existed. Items 2 and 3 are narrowed by the same
sample but not settled: what remains needs either a multiplayer save or a name
the binaries do not contain. Item 4 is closed in the sense that it has been
enumerated — there is no second consumer.

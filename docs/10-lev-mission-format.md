# `.lev` — Battle map / mission format

**Status: structurally solved and corpus-validated. Field semantics solved down
to the individual unit stat; the remaining gaps are listed in §9.**

`Missions/*.lev` holds one playable mission: the field grid, the units placed on
it, and the 3D scenery objects. It is the format the shipped level editor
(`iDesigner.exe`) reads and writes, and it has no published prior art — the
layout below was recovered for this project by disassembling `iDesigner.exe` and
`Incubation.exe` and cross-checking against the shipped data, the `.lcl` mission
scripts and `DATA/Info.lcl`.

Corpus: **155/155 files parse and pass every structural invariant** with
`tools/lev_parse.py --check`.

---

## 1. Where the layout comes from

`aSaveBattleMap` (`iDesigner.exe`, `fcn.00410260`, original source
`C:\aProject\Designer\Sources\Game\BattleMap\aBattleMap.cpp`) writes the file as
five consecutive raw `fwrite` calls with no chunk headers of any kind:

```
aWriteFile(fh, g_header,  0x360)   ; 864 bytes
aSaveCtrlMap(fh)                   ; -> aWriteFile(fh, ctrlmap, 23 * cellCount)
aSaveUnitMap(fh)                   ; -> aWriteFile(fh, unitmap, 0x4718)
aSave3DObjects(fh)                 ; -> three more aWriteFile calls
```

`Incubation.exe` reads it back with the mirror-image routine `fcn.00407c70`,
which is the more useful of the two: it is followed by the fix-up passes that
reveal which stored fields are real data and which are runtime residue.

The cell stride is computed in the binary as `(n*24) - n` = **23**
(`fcn.0041bdf0`; the game's cell accessor `fcn.0042f730` uses the same `0x17`).
The unit block is a flat `0x4718` = **18200** bytes (`fcn.004366f0`).
`aSave3DObjects` (`fcn.00406ad0`) writes `0x2D4` = **724** bytes, then `0x26AC`
= **9900**, then `0x2AB98` = **175000**. The element strides of the last two
arrays come from their accessors: `fcn.00404990` computes `((i<<5)+i)*2` = **66
bytes**, `fcn.00404960` computes `((i*8-i)*5)*2` = **70 bytes** — giving 150 and
2500 slots.

Because everything except the cell grid is fixed size, the file size is fully
determined by the map dimensions. This identity holds for all 155 files and is
the parser's primary integrity check:

```
file_size = 864 + 23 * width * height + 203824
```

---

## 2. Top-level layout

| Offset | Size | Block |
|---|---|---|
| `0x000` | 864 (`0x360`) | Header |
| `0x360` | `23 * W * H` | CtrlMap — the field grid |
| `0x360 + 23*W*H` | 18200 (`0x4718`) | UnitMap — 200 slots x 91 bytes |
| … + 18200 | 724 (`0x2D4`) | 3D objects, block 1 — scene header |
| … + 724 | 9900 (`0x26AC`) | 3D objects, block 2 — 150 slots x 66 bytes |
| … + 9900 | 175000 (`0x2AB98`) | 3D objects, block 3 — 2500 slots x 70 bytes |

Observed map sizes range from 20x20 to 40x40, including non-square maps such as
40x38 and 40x15; the width/height fields in the header are authoritative.

Because these are raw struct dumps, **uninitialised memory is visible in the
file**. MSVC debug builds fill fresh heap with `0xCD`, and `0xCDCD` appears at
the tail of every cell record and inside unit and object records. Those bytes
carry no meaning and must not be interpreted.

Just as importantly, **the two object arrays are not self-terminating**. The
authoritative element counts live in block 1 (`+0x288`, `+0x28C`). Records past
those counts are stale leftovers from earlier edits of the same map and look
perfectly valid — scanning for a `0xCDCDCDCD` sentinel over-reads them.

---

## 3. Header (864 bytes)

The header is a single global (`0x4AF030` in iDesigner.exe) that is only ever
copied wholesale, so no `base + offset` accesses exist. The individual fields
are reached through a bank of one-line accessor functions at
`0x410760`–`0x410880` in `aBattleMap.cpp`; the addresses those accessors touch
give the offsets directly. Every byte range that is non-zero anywhere in the
corpus corresponds to one of them, so **the header is now fully accounted for**.

| Offset | Type | Meaning | Accessor | Confidence |
|---|---|---|---|---|
| `0x000` | string | Name of the **next** mission (e.g. `_C_101`) | — | confirmed |
| `0x105` | string | This mission's own name (e.g. `_C_100`) | `0x410760` | confirmed |
| `0x20A` | `u32[4]` | **Equipment points**, one per player | `0x4107F0`/`0x410800` | confirmed |
| `0x21A` | `u32` | **Skill level** — dialog range `[0,12]` | `0x410820`/`0x410830` | high |
| `0x21E` | `u32` | **Tech level** — dialog range `[0,9]` | `0x410840`/`0x410850` | high |
| `0x222` | `u8` | **Map type**, see below | `0x4107B0`/`0x4107C0` | confirmed |
| `0x223` | `u8` | **Mission id** (campaign number) | — | high |
| `0x224` | `u32` | **Camera height**, world units (`metres * 1600`) | `0x410860`/`0x410870` | confirmed |
| `0x244` | string | `.3DW` scene name (e.g. `Level01e`) | `0x4107E0` | confirmed |
| `0x349` | string | WorldSet folder suffix (e.g. `A00` → `WorldSet/World_A00/`) | `0x4107D0` | confirmed |
| `0x353` | `u32` | LCL program slot — **runtime residue**, see below | `0x410770` | confirmed |
| `0x357` | `u32` | **height** — number of rows | `0x410780` | confirmed |
| `0x35B` | `u32` | **width** — number of columns | `0x410790` | confirmed |
| `0x35F` | `u8` | Unused; default `'a'` (0x61) | `0x4107A0` | UNVERIFIED |

Everything else in the 864 bytes is zero in all 155 files.

> Note the order: rows come first, columns second. The 40x38 maps make this
> unambiguous; the many square maps do not.

The `.lev` name field at `0x000` is not an identity: `_C_100.lev` begins with
the string `_C_101` because that is the *next* map. Use `0x105`, or the filename.

### Where the names come from

`iDesigner.exe` dialog resource 160, **"Level Information"** (opened from
*Edit → Edit Map Information*, dialog proc `0x422230`), is the direct evidence.
Its init routine `fcn.00422440` fills the controls from the accessors above:

| Control | Caption | Accessor | Header field |
|---|---|---|---|
| 1490 (`0x5D2`) | `Equipmentpoints [0,3000]` | `fcn.004107F0` | `0x20A` |
| 1494 (`0x5D6`) | `Techlevel [0,9]` | `fcn.00410840` | `0x21E` |
| 1495 (`0x5D7`) | `Skills [0,12]` | `fcn.00410820` | `0x21A` |
| 1380 / 1381 / 1509 | `Single Player` / `Deathmatch` / `Cooperative Mode` | `fcn.004107B0` | `0x222` = 2 / 3 / 5 |

The Techlevel/Skills assignment is settled by the control coordinates in the
dialog template (label `Techlevel` at y=33 sits next to edit 1494 at y=31;
`Skills` at y=46 next to edit 1495 at y=44), not by resource order.

The write-back path at `0x4222DE` clamps the equipment-points box to `[0,3000]`,
stores it into slot 0 and then **zeroes slots 1..3** — which is exactly what the
corpus shows: 46 files have a non-zero slot 0, and only 10 older files have
non-zero slots 1..3.

Dialog 120, **"Edit levelstruct"**, supplies the map-type names through its radio
buttons `Campaign` / `Single` / `Multi` / `Special` / `COOP`, and labels control
1469 `camera height (meter)`. The corresponding writer `fcn.0042B0F0` calls
`fcn.00410860(value * 0x640)`, i.e. **one metre = 1600 world units**, so one map
field (3200 units) is two metres.

Map type distribution over the corpus, and how it matches the filename prefixes:

| `0x222` | Name | Files | Prefixes |
|---|---|---|---|
| 1 | Campaign | 77 | `_C_*` |
| 2 | Single | 10 | `_S_*` |
| 3 | Multi (deathmatch) | 25 | `_M_*` |
| 4 | Special | 18 | `upgrade_*`, `_C_XXX`, `_C_YYY`, `_I_001` |
| 5 | COOP | 25 | `_O_*` |

**Type 4 is not a mission at all — it is a non-battle screen.** All 18 are
`40x40`; `_C_YYY` (scene `Map2`) is the campaign location map, `_C_XXX` (scene
`City`) a city view, `_I_001` (scene `Logowall`) the logo screen, and the
sixteen `upgrade_*` reuse ordinary battle scenes as backdrops for the upgrade
and recruit screens, carrying the 2–3 figures shown on them. Only `_C_XXX` and
`_C_YYY` place no units at all.

A save taken while the campaign location screen was open confirms this from the
running game: it names `_C_YYY` as the current mission and embeds its `40x40`
map exactly as a battle save embeds a battle
([`11` §6](11-save-game-format.md)). The engine has one mission pipeline and
runs its menus through it.

`0x223` runs 1, 2, 3, … for `_C_100`, `_C_101`, `_C_102` … up to 34 for
`_C_133`, then 40 for `_C_140`, i.e. mission number minus 99. Non-campaign maps
mostly carry 0.

### Fields that are runtime residue

`0x353` is written on every load: the editor's map-load routine
(`iDesigner.exe` `fcn.0040ffa0`) calls
`fcn.00422570(&header[0x353], "<mapname>.lcl")`, which loads the mission script
into a slot of the editor's LCL program table and stores the slot index there.
Its shipped value is 54 in 153 files and 52/37 in two others — an artefact of
editor state, not map data. A remake should ignore it.

`0x35F` has exactly one reader, `fcn.004107A0`, called once from the same
map-load routine `fcn.0040ffa0` with its result discarded. Its default is `'a'`; shipped values include ASCII `a 1 2 3 4 8 T U`
and a scatter of non-ASCII bytes. Treat as unused.

---

## 4. CtrlMap — the field grid (23 bytes per cell)

`W * H` records in row-major order. Record `i` describes the cell at
`x = i % width`, `y = i // width`.

The decisive source is `aInitCtrlMap` (`Incubation.exe` `fcn.0042ec20`), which
writes every meaningful byte of a fresh cell record; the remaining fields are
named from `fcn.0042ed60` (the per-turn cell-effect tick), `fcn.0042f410` and
`fcn.0042f7d0`.

| Offset | Type | Meaning | Confidence |
|---|---|---|---|
| `+0x00` | `u8` | Cell state. `1` in every shipped cell. At runtime the engine also writes `2` ("selected" — the LCL area commands act on `== 2`), `10`, `0x3C` and `0x64` as movement overlays (§4.5), and `30`–`34` as the AI's target overlay, one band per hit-probability bracket ([`23` §6](23-ai-system.md)). The band `0x50`–`0x5E`, which `fcn.0042f7d0` refuses to overwrite, is the **attack scratchpad**: `0x50`–`0x55` mark the cells a weapon covers and `0x5A`–`0x5D` record what happened there, see [`22` §7.2](22-combat-and-visibility.md). [`23` §10](23-ai-system.md) tabulates every band | confirmed |
| `+0x01` | `i32` | **Height**, world units. Identical to the `z` of the linked land object — 184162/184162 cells | confirmed |
| `+0x05` | `u16` | **Land-object link** — index into block 3. Equals `y*width + x` in every shipped file | confirmed |
| `+0x07` | `i16` | **Unit link** — index into the UnitMap, `0xFFFF` when the field is empty | confirmed |
| `+0x09` | `u8` | **x** | confirmed |
| `+0x0A` | `u8` | **y** | confirmed |
| `+0x0B` | `u8` | **Action point id**, `0` = none | confirmed |
| `+0x0C` | `u8` | **Damage the unit on this cell took** in the attack just resolved; written by `fcn.0046b450` alongside the `+0x00` result marker and cleared with it by `fcn.0042ee90`. `0` in all cells. See [`22` §7.3](22-combat-and-visibility.md) | confirmed |
| `+0x0D` | `u8` | **Field type**, see §4.1 | confirmed |
| `+0x0E` | `u8` | Effect countdown (frames). `0` in all cells | high |
| `+0x0F` | `u8` | Effect object — slot in the engine's runtime dynamic-object array (81 slots, `fcn.00404c00`), `0xFF` = none. `0xFF` in all cells | high |
| `+0x10` | `u8` | Effect state (`1`, `3` at runtime), `0xFF` = idle. `0xFF` in all cells | high |
| `+0x11` | `u8` | Decal object — slot in the same runtime array, `0xFF` = none. `0xFF` in all cells | high |
| `+0x12` | `u8` | Decal state (`2` at runtime). `0` on all but 44 cells of `_C_116.lev`, which are leftover runtime state | high |
| `+0x13` | `u8` | Decal state (`4` at runtime), `0xFF` = idle. `0xFF` in all cells | high |
| `+0x14` | `u8` | **Deployment-field ordinal**, `0xFF` = not a deployment field | high |
| `+0x15`..`+0x16` | 2 bytes | Uninitialised padding (`0xCDCD` or `0x0000`) — **ignore** | confirmed |

The old spec split `+0x01` into an `i16` height and an unexplained `i16` at
`+0x03`. That was wrong: `fcn.0042f410` writes `*(int*)(cell + 1) = landobj->z`
as a single 32-bit store, and `fcn.0042ef10` does `*(int*)(cell + 1) += 0xC80`
when it raises a field by one tile. The 1844 cells that showed `0xFFFF` at
`+0x03` are exactly the 1844 cells whose 32-bit height is **negative**.

### 4.1 Field types

The nine byte values observed are indexes into an 11-entry table that
`Incubation.exe` builds from the shipped `DATA/Info.lcl` via the
`SetCtrlMapInfo` command (handler `fcn.00440f30`, table at `0x4FEB80`, stride
23, `fcn.0042f690` bounds-checks `> 10`). `Info.lcl` therefore names them
outright:

```
SetCtrlMapInfo ( 0, 0,   0,   0,  "Undefined");
SetCtrlMapInfo ( 1, 1,   0,   0,  "Free Place");
SetCtrlMapInfo ( 2, 2, 255, 255,  "Wall");
SetCtrlMapInfo ( 3, 3, 255,   0,  "Hole");
SetCtrlMapInfo ( 4, 4, 255,   0,  "Deep Hole");
SetCtrlMapInfo ( 5, 5,   1,   0,  "Debris");
SetCtrlMapInfo ( 6, 6,   0,   0,  "Poison");
SetCtrlMapInfo ( 7, 7, 255,  40,  "Enormous Obs");
SetCtrlMapInfo ( 8, 8,   0,   0,  "Ladder");
SetCtrlMapInfo ( 9, 9,   0,   0,  "Teleporter Entry");
SetCtrlMapInfo (10,10, 255,   0,  "Teleporter Exit");
```

The third column is read by `fcn.0042f6b0` and tested `!= 0xFF` on the movement
path, so `255` means **impassable**; [`23` §7.4](23-ai-system.md) calls it the
`delay` and gives the per-step cost it produces. **The fourth column is dead
data.** It lands at record `+0x02`, and a displacement-aware sweep of `.text`
finds three references to `+0x00` and two to `+0x01` — the positive control —
and none at all to `+0x02` or `+0x03`; the three routines that take a pointer
to the record read `+0x01` twice and `+0x03`, the name. See
[`26` §10](26-interaction.md).

| Value | Name | Cells | Files |
|---|---|---|---|
| 0 | Undefined | 61840 | 112 |
| 1 | Free Place | 48292 | 149 |
| 2 | Wall | 26891 | 137 |
| 3 | Hole | 2241 | 3 |
| 4 | Deep Hole | 44653 | 65 |
| 5 | Debris | 12 | 1 |
| 6 | Poison | 191 | 2 |
| 7 | Enormous Obs | 0 | 0 |
| 8 | Ladder | 0 | 0 |
| 9 | Teleporter Entry | 22 | 7 |
| 10 | Teleporter Exit | 20 | 7 |

Independently, the editor's *Edit → Select Field Type* menu (menu resource 106)
offers a seven-item palette whose handlers (`iDesigner.exe` `0x4111D5` switch)
assign exactly these values:

```
Free Place [.]       -> 1        Teleporter Entry [T] -> 9
Wall [#]             -> 2        Teleporter Exit [X]  -> 10
Hole [v]             -> 4        Debris [;]           -> 5
Posion [P]           -> 6
```

Note the editor's `Hole [v]` button writes **4** (`Deep Hole`), not 3. `Info.lcl`
is the authority for the semantics, because it is the table the engine indexes.

The same menu confirms the editing modes and hence the cell fields:
`Set Land`, `Set Units`, `Set Action Points`, `Set CtrlMap Types`,
`Set CtrlMap Height`.

The LCL commands `SetCtrlMapType` / `GetCtrlMapType` read and write this byte:
`SetCtrlMapType`'s handler (`Incubation.exe` `fcn.00442a80`) is literally
`*(u8*)(GetCell(x,y) + 0xD) = type`.

### 4.2 Deployment fields (`+0x14`)

Cells that carry an action-point id in the range 80–85 (`0x50`–`0x55`) are
numbered consecutively in row-major order at `+0x14`; every other cell holds
`0xFF`. The game's own legend calls that band **VictoryPoints** and marks it
*"only Multiplayer"* (§4.6); the ordinal below is the observed use of the same
cells. Corpus-wide this holds for all 307 marked cells, with no ordering
violations, and only ids 80–85 (plus five cells with id 0) appear on them.

The multiplayer maps make the meaning plain: `_M_010` … `_M_036` carry exactly
four marked cells (`_M_018`, `_M_019`: two), spread across the map — the player
start fields. Campaign maps carry contiguous blocks of them (`_C_133`: a 3x3
patch at the map edge; `_C_166`: 4x3 patches on both flanks) — the squad
deployment zone.

### 4.3 How height and action points were confirmed

The `.lcl` mission scripts give independent ground truth. `Missions/_C_105.lcl`
declares four terminals:

```
GetActPt (_A_Term1,16,5);    * Terminal 1
GetActPt (_B_Term2,20,21);   * Terminal 2
GetActPt (_C_Term3,19,21);   * Terminal 3
GetActPt (_D_Term4,15,28);   * Terminal 4
```

and later branches on `VarCmpNum (_A_Term1,34)`. Reading `_C_105.lev` at those
four coordinates (with `width` = the field at `0x35B` = 40) gives `+0x0B` =
`0x22` = **34** on all four cells and `0` on ordinary cells. The same four cells
carry `+0x01` = 1950/1951 while flat floor cells carry `0`.

This test also settles the width/height ordering: using the `0x357` value as the
width puts the terminals on the wrong cells.

### 4.4 Unit links

Cross-checking every cell whose `+0x07` is not `0xFFFF` against the referenced
unit's own coordinates: 1863 cells agree exactly. The 128 that do not are cells
occupied by **multi-field units** — large aliens whose footprint covers several
cells while the unit record stores only its origin. This is expected behaviour,
not a parse error. A remake must model unit footprints accordingly; the type
table byte at `Info.lcl` column 14 (`1` for `Tr'Yn`, `Al'Coo`, `ComBot`) is what
the engine tests for it.

### 4.5 Movement overlays — cell state `10`, `0x3C` and `0x64`

When a unit is selected, `fcn.00430a40` (the range builder, used by the UI and
by the AI alike) seeds the unit's own cell with **`10`** (`0x00430AFA`) and then
floods outwards, writing the same `10` into `+0x00` of every further cell it can
*walk* to (`0x00430D81`, inside the expansion loop). It then calls
`fcn.00430EE0` (`0x00430E75`), which makes a second pass over the whole grid and
writes **`0x3C`** into `+0x00` on every cell the unit can **warp** to. Both are
transient overlays; neither ever reaches a `.lev`.

`fcn.00430ee0` accepts a cell only when all of these hold:

| Test | Cell field |
|---|---|
| the field is empty | `+0x07 == 0xFFFF` |
| field type is Undefined, Free Place or Ladder | `+0x0D` ∈ {0, 1, 8} |
| not a VictoryPoint (§4.6) | `+0x0B` ∉ `0x50`–`0x59` |
| no effect running | `+0x10` ∉ {1, 2} |
| within the warp range | `fcn.0044ae10(...) <= range` |

The **warp range** is `fcn.00475380(unit)`:

* **5** if the unit carries equipment id 7 and has movement points left
  (`unit[+0x28] == 1 && unit[+0x15] != 0`). `Info.lcl` names that equipment
  itself, and annotates it with the developers' own word for the mechanic:

  ```
  SetEquipInfo (7, "Jet Pack",  190, 4,0,0,3,0,0, 4, "G", 6);   * warp & scan
  ```

* **7** if the unit's type has `SetUnitInfo` **special** `== 15`
  (`unitinfo[type * 0x7E + 0x07]`). Exactly one shipped type qualifies:
  **`Ray'Coo`** (type 64) — the innate warper.
* **0** otherwise, in which case `fcn.00430ee0` returns immediately and no
  cell is marked.

A third value joins them once a destination has been chosen. `fcn.004305e0`
walks the map back from the target to the unit, marking each cell of the
resulting path with **`0x64`** (100) and then resetting every cell that is not
on it to state `1` with `+0x0C` cleared — so after it runs the grid holds the
path and nothing else. [`23` §8](23-ai-system.md) works through the walk, and
[`23` §7](23-ai-system.md) through the fill's cost and passability rules.

This is what the AI's `MoveUnit` selector byte tests; see
[`20-lcl-language.md`](20-lcl-language.md) §5.

---

### 4.6 The action-point legend — **[code] `0x0046838D`…`0x00468787`**

`Info.lcl` never names an action point and the editor's own field is a plain
number, so until now `+0x0B` was documented only as "the scripts'
general-purpose per-tile store" ([`21` §8](21-info-lcl-schema.md)). It is not
only that: **`Incubation.exe` carries the developers' own names for 38 of its
values**, as a list of literals pushed one after another from `0x0046838D` to
`0x00468787`. Seven of the 45 pushes are section headings, so the block is a
legend for a picker, not a lookup table — the retail binary ships a map editor
(the same cluster fills two AI-order list boxes, §5.6, and `0x0041CDD5` /
`0x0041CEF2` are its "+5" and "+1" buttons for this very field, guarded at 249
and 254).

| Value | The developers' name | Cells in the corpus |
|---|---|---|
| 0 | *empty* | 179083 |
| | ***Placefields*** | |
| 1 | placefield of player 0 | 1620 |
| 2 | placefield of player 1 | 574 |
| 3 | placefield of player 2 | 573 |
| 4 | placefield of player 3 | 558 |
| | ***Supplyboxes*** | |
| 10 | random | 1 |
| 11 | nothing | 2 |
| 12 | full munition | 160 |
| 13 | equipmentpoints 50 | 169 |
| 14 | light/heavy weapon | 7 |
| 15 | condition | 8 |
| 16 | technical | 4 |
| 17 | equipmentpoints 20 | 93 |
| 18 | equipmentpoints 10 | 40 |
| | ***Doors*** | |
| 30 | standard Door — OPEN | 17 |
| 31 | standard Door — CLOSED | 278 |
| 32 | jammed Door — OPEN | **0** |
| 33 | jammed Door — CLOSED | 8 |
| | ***BUTTONS & LEVERS*** | |
| 34 | button a | 28 |
| 35 | button b | 2 |
| 36 | lever up | 70 |
| 37 | lever down | 1 |
| | ***EQUIPMENT*** | |
| 38 | absorber | 13 |
| 39 | crowbar | 3 |
| 40 | cooler | 6 |
| 42 | explosionpack | 5 |
| | ***MISC*** | |
| 70 | entry point | 209 |
| 71 | destroyed entry point | 1 |
| | ***Victorypoints (only Multiplayer)*** | |
| 80 | VictoryPoint A — neutral | 72 |
| 81 | VictoryPoint A — player 1 | 189 |
| 82 | VictoryPoint A — player 2 | 1 |
| 83 | VictoryPoint A — player 3 | 1 |
| 84 | VictoryPoint A — player 4 | 1 |
| 85 | VictoryPoint B — neutral | 57 |
| 86 … 89 | VictoryPoint B — player 1 … 4 | **0** |

Value 41 is skipped and 5–9, 19–29, 41, 43–69, 72–79 and 90+ are not in the
legend at all — those are the range the scripts use freely, which is why the
corpus also holds runs like 50–69, 90–99, 100–133 and 210–216, one cell each.

**Comparisons are not the only way the engine reads this byte.** Sweeping
`.text` for every *comparison* against `cell[+0x0B]` gives the table below;
`aExecuteUse` reaches twenty further values through a **jump table** instead,
which no comparison sweep can see. [`26` §3.1](26-interaction.md) reads that
table out and is the authority on which ids the engine acts on.

| Value | Where | What it does |
|---|---|---|
| 1..8 | `0x004190B9`, `0x004191F5` | a range test in the editor's map pass |
| 1..4 | `0x00431118` | the deployment pass — the four placefields |
| 10 | `0x0046DD28` | `aExecuteUse` rerolls the random supply box ([`26` §3](26-interaction.md)) |
| 10..49 | `0x0047A5BD` | `aGetUseTarget` — the band the Use button accepts ([`26` §2](26-interaction.md)) |
| 10..70 | `0x00418BDC` | `aBattleMap.cpp`'s draw pass flags an interactable cell |
| **31** | `0x0040A65F`, `0x0040A9CD` | **the AI, and nothing else** — see [`23` §3.2](23-ai-system.md) |
| 33, 32 | `0x0047A5CD`, `0x0047A5D8` | the two jammed-door exceptions in the same predicate |
| 70 | `0x0047B463` | entry point — the demolition predicate ([`26` §2](26-interaction.md)) |
| 71 | `0x004418F5`, `0x00441A03` | `InsertUnit` refuses to spawn here ([`21` §8](21-info-lcl-schema.md)) |
| 80..89 | `0x00418340`, `0x00430F4D` | the editor; and the warp exclusion band (§4.5) |
| 80..89 | `0x0046E99F`, `0x0046E9D4` | **VictoryPoint capture** on the movement path ([`26` §6.1](26-interaction.md)) |
| non-zero | `0x0041813F`, `0x0041D010`, `0x004313F4`, `0x00442440`, `0x00455695` | five "is anything here" tests, in five different modules |
| 249, 254 | `0x0041CDD5`, `0x0041CEF2` | not values — the editor's `+= 5` and `+= 1` overflow guards |

The previous revision listed `0x00455695` as a comparison against 12,
*full munition*. It is not: the instruction there is `mov al, [ecx+0x0B]`
followed by `test al, al`, a plain non-zero test in `aMissionControl.cpp`'s
cursor path. `tools/interaction_tables.py`'s `sweep.*` checks now enumerate all
**44** instructions in `.text` that touch this byte, with the module each
belongs to.

Two entries settle questions the other documents had left open. **71 is
"destroyed entry point"**, which is exactly why `InsertUnit` refuses it. And
**31 is "standard Door — CLOSED"**, tested at two sites that are both inside
the AI turn: `0x0040A600` steps up to such a cell and plays `aDoorOpenSequence`
(`0x00410A20`), and the AI's planner has a whole selector for finding one.
**The computer opens doors; the jammed pair 32/33 it never touches.** Nor, it
turns out, does it touch anything else: `aExecuteUse` has exactly one caller
and it is in the interface ([`26` §7](26-interaction.md)).

The `0x50`–`0x59` band §4.5 excludes from warp targets is therefore
**VictoryPoints**, not deployment fields. §4.2's reading of `+0x14` is
unaffected — its evidence is the multiplayer start layouts, and the same cells
being both the start areas and the scoring areas is what the heading
*"only Multiplayer"* implies.

Three gaps in the legend close from the code rather than from the picker.
**Id 41, which the legend skips, is *Batteries*** — `aExecuteUse` handles it
and `Events.txt` label `EB` names it; its arm changes nothing, so it is a
pickup that was authored and left inert. **Ids 86–89 are written on capture,
never authored**, which is why the census finds none. And **id 32 is
unreachable**: the Use predicate refuses it outright, so *jammed Door — OPEN*
exists only as the state a jammed door reaches once it has been pried open.
[`26` §3.1](26-interaction.md) has the full class table with what each id does.

---

## 5. UnitMap — 200 slots x 91 bytes

A fixed array of 200 slots, always written in full. The record is the engine's
**live** unit struct, not a reduced on-disk form: `aLoadBattleMap` reads the
block straight into the runtime array and its only fix-up pass
(`fcn.00407aa0` -> `fcn.00479ae0`) re-spawns the 3D model and overwrites
`+0x4B`. Nothing else is re-derived — in particular **the stored stats are
authoritative and may disagree with the current `DATA/Info.lcl`**. They do:
40 placed `Pyr'Coo` carry `hp` 4 / `mp` 6 while `Info.lcl` now says 6 / 5,
because the maps were saved before that unit was rebalanced. A remake must use
the record, not the type table, for a placed unit.

**A slot holds a unit that is actually on the map when `+0x16` is non-zero.**
That is the test `GetUnits`' implementation uses (`Incubation.exe`
`fcn.00477bf0`: iterate 200 records of stride `0x5B`, count those with
`rec[0x16] != 0 && rec[0x45] == player`), and it is also what
`aLoadBattleMap`'s re-spawn pass `fcn.00407aa0` uses. Corpus-wide, `+0x16 != 0`
coincides **exactly** with "some cell links to this slot" — 1863 slots each way,
zero exceptions — while 615 further slots carry a leftover name and are not
placed. The old "empty slot = zero first name byte" rule is the weaker of the
two predicates.

### 5.1 Where the field names come from

`iDesigner.exe` dialog resource 112, **"Select and Build Unit Object"** (81
controls), is a labelled picture of this record. Its init routine
`fcn.0042f620` fills every control from a 91-byte staging copy of the record at
`0x4C4E38`, and the write-back `fcn.0042fae0` reads them back into the same
buffer; five helpers fill the list boxes (`fcn.0042ff70` weapons,
`fcn.00430070` orders, `fcn.004302f0` equipment, `fcn.004303c0` unit types,
`fcn.004304c0` speech). Because the buffer base is known, **every
`DAT_004C4Exx` the dialog touches gives an offset directly.**

The mapping is anchored by the fields whose meaning was already established from
the engine — `+0x15`, `+0x16`, `+0x3D`, `+0x3F`, `+0x42`, `+0x43`, `+0x44`,
`+0x45`, `+0x46`, `+0x4C` and `+0x4E` — every one of which lands on the control
the dialog template labels for it. As in §3, control identity is resolved by
**coordinates in the dialog template**, never by resource order: e.g. the
static `FP` at (73,45) sits next to edit 1217 at (88,45), which
`fcn.0042f620` loads from `DAT_004C4E51` = `+0x19`.

### 5.2 Record layout

| Offset | Type | Meaning | Evidence | Confidence |
|---|---|---|---|---|
| `+0x00` | `char[20]` | **Name**, NUL-padded (`Ray'Ther`, `Human Soldier (1)`, `Chainsaw Steele`, `Barrel`, …). Defaults to the type's description, copied by `fcn.00479ba0` | dialog edit 1211 | confirmed |
| `+0x15` | `u8` | **MP** — remaining action/movement points. Recomputed each turn by `fcn.00475160` (§5.5) | edit 1294; `fcn.0040a440` subtracts the weapon's AP cost | confirmed |
| `+0x16` | `u8` | **HP** — hit points; `0` = slot not placed | edit 1213 | confirmed |
| `+0x17` | `u8` | **EP** — experience points. **Rank = EP / 12** (`fcn.00475120`, floor 3); max HP = type HP max + EP/12, capped at 15 (`fcn.00475240`) | edit 1215 | confirmed |
| `+0x18` | `u8` | **TP** — a pool of **skill points, counted in twelfths**. Buying a weapon or a piece of equipment subtracts `12 x` the number of skill points it raises (`fcn.004755D0`, `fcn.00475680`), and the combat resolver shows the change as `+0x18 / 12` (`fcn.0046B450`). Non-zero on 19 shipped units | edit 1216 | high |
| `+0x19` | `u8` | **FP**. `255` on every unit whose type has `FP max` = 255 (1793/1793, no exceptions); the 70 human-type units carry designer values 3–10. `fcn.00475160`: FP `0` forces MP to 1, FP `1` forces MP to 2. It is also read by the damage resolver: a defender at FP `0` takes two extra damage rolls and one at FP `1` takes one ([`22` §7.4](22-combat-and-visibility.md)) | edit 1217 | confirmed |
| `+0x1A` | `u8` | Skill **CON** — *Battle Fitness* | edit 1219; `fcn.0047a600`/`fcn.0047a6e0` | confirmed |
| `+0x1B` | `u8` | Skill **LW** — *Light Weapon Proficiency* | edit 1220; same | confirmed |
| `+0x1C` | `u8` | Skill **HW** — *Heavy Weapon Proficiency* | edit 1221; same | confirmed |
| `+0x1D` | `u8` | Skill **TS** — *Technical Skills* | edit 1222; same | confirmed |
| `+0x1E` | `u8` | Skill **MS** — *Medical Skills* | edit 1223; `fcn.0047a6e0` | confirmed |
| `+0x1F` | `u8` | Skill **LS** — *Leadership Skills*. Not exposed by the dialog | `fcn.0047a6e0` writes `SetEquipInfo`'s `LS` column here | confirmed |
| `+0x21`..`+0x35` | `21 x u8` | **Equipment**, one byte per `SetEquipInfo` id, `1` = carried. See §5.4 | `fcn.004302f0`; six engine readers | confirmed |
| `+0x36` | `u8` | **Front armour**, cached. Used when the attacker is *not* firing along the defender's own facing ([`22` §7.4](22-combat-and-visibility.md)) | recomputed by `fcn.00475490` (§5.4) | confirmed |
| `+0x37` | `u8` | **Rear armour**, cached. Used when the attacker's facing is within one octant of the defender's own — a 135° rear arc | recomputed by `fcn.004754F0` (§5.4) | confirmed |
| `+0x38` | `u8` | **Decorations awarded** — campaign state, see §5.11. `0` in every shipped record | — | confirmed |
| `+0x39` | `u8` | **"this unit has acted"** — set to `3` by the AI's fire routine (`fcn.0040A440`) and its interaction routine (`fcn.0040A600`), read by `aAISystemControl`'s epilogue to decide whether to end the unit's turn ([`23` §3.3](23-ai-system.md)); cleared by the stat recompute `fcn.004759E0`. `0` in every shipped record | — | confirmed |
| `+0x3A` | `u8` | **Damage absorption** — `4` when equipment 18 (`Damage Absorber`) is carried, else `0` (`fcn.00475580`). Exactly the two units that carry it hold `4`; six further records hold stale 123/126 | — | confirmed |
| `+0x3D` | `u8` | **Ammo** left in the magazine | edit 1231 (`MUN`); `fcn.0046b450` subtracts the weapon's *mun per fight* | confirmed |
| `+0x3E` | `u8` | **Weapon heat**, see §5.12; incremented by one per attack up to the weapon's cap, and the overheat roll fires when it reaches it ([`22` §8](22-combat-and-visibility.md)). `0` in every shipped record | — | confirmed |
| `+0x3F` | `u8` | **Weapon id** — index into `Info.lcl`'s `SetWeaponInfo` table | edit 1239 (`WeaponLink`) | confirmed |
| `+0x40` | `u8` | **Weapon malfunction state** — `0` none, `2` or `5` jammed; non-zero blocks firing, see §5.12. Written only by `aCheckWeaponDamage` ([`22` §8](22-combat-and-visibility.md)). `0` in every shipped record | — | confirmed |
| `+0x41` | `u8` | Runtime **action state**; `5` and `6` zero the unit's MP (`fcn.00475160`), `1` marks a pending reaction (§5.12), `7` means the unit **stood down without acting** — `fcn.00478570` sets it from the UI (`aUI.cpp`) and zeroes MP in the same breath, and the next turn refresh pays it back as `+0x57`. Reset to 0 by the turn refresh `fcn.004781C0`; `0` in every shipped record | `fcn.0040A440`/`fcn.0040A600` write 1/3/4 | high |
| `+0x42` | `u8` | **x** | edit 1252 (`Pos`) | confirmed |
| `+0x43` | `u8` | **y** | edit 1253 | confirmed |
| `+0x44` | `u8` | **Unit index** — equals the slot index | edit 1256 (`ID`) | confirmed |
| `+0x45` | `u8` | **Owning player**, see §5.7 | edit 1254 (`Player`) | confirmed |
| `+0x46` | `u8` | **Facing**, 0–7, see §5.10 | edit 1255 (`Direction`) + the 3x3 button pad | confirmed |
| `+0x47` | `u8` | **Primary AI order**, 0–10, see §5.6 | list box 1287; `switch (unit[0x47])` in `fcn.00409940` | confirmed |
| `+0x48` | `u8` | **Primary order parameter** | edit 1289 (`Param`) | confirmed |
| `+0x49` | `u8` | **Secondary AI order** | list box 1288 | confirmed |
| `+0x4A` | `u8` | **Secondary order parameter** | edit 1290 (`Param`) | confirmed |
| `+0x4B` | `u8` | Runtime 3D-object slot — overwritten on load by `fcn.00479ae0` | — | confirmed |
| `+0x4C` | `u8` | **Unit type id** — index into `Info.lcl`'s `SetUnitInfo` table, see §5.9 | list box 1234 | confirmed |
| `+0x4D` | `u8` | `0` none, `1` **unit-pool candidate**, `2` **hero** | check boxes 1374/1396; `fcn.0046f7e0`, `fcn.00478f20` test it non-zero | confirmed |
| `+0x4E` | `u8` | **AI group id** | edit 1313 (`Group`); `fcn.0040b210` scans it; `InsertUnitWithGroup`/`GetUnitsInGroup` | confirmed |
| `+0x4F` | `u8` | **Visibility state**: `0` visible, `1` seen only by a scanner, `3` hidden. Runtime; recomputed from scratch by `aBuildVisibleMap` (`fcn.004798c0`) / `aBuildVisibleMapForUnit` (`fcn.004794b0`) on every pass, see [`22` §9](22-combat-and-visibility.md) | `aSetVisibleStateForUnit` (`fcn.00479370`) is its only writer; it sets the 3D object's flag to 1/3/2 in the same breath | confirmed |
| `+0x50` | `u8` | **Distance walked this turn**, in tenths of a field: `aExecuteMove` adds 10 per orthogonal step and 15 per diagonal one (`0x0046E7B7`), and the start-of-turn refresh zeroes it ([`25` §5.1](25-turn-and-round.md)). Read by unit `special` 4 ([`21` §5](21-info-lcl-schema.md)), where the threshold "2 or less" means "has not moved". Non-zero on 4 shipped units (20, 35, 40, 55) — mid-turn state the editor saved | — | confirmed |
| `+0x51` | `u8` | **x at the start of the current turn** — copied from `+0x42` by the turn refresh `fcn.004781C0`, initialised to the spawn cell by the unit-creation helper `fcn.00477830`. Read *instead of* `+0x42` by `fcn.0042FF30`/`fcn.0046A270` when the attacker's weapon has `special` 6, which `Info.lcl` glosses as "attack the defender's position of the last turn" | — | confirmed |
| `+0x52` | `u8` | **y at the start of the current turn** | same | confirmed |
| `+0x55` | `u8` | **Speech** — voice sample set, 0–12, see §5.8 | list box 1470 (`Select Speech`); `switch` in `fcn.0047b660` | confirmed |
| `+0x56` | `u8` | Runtime **sound-channel back-reference**; `fcn.00477970` stores the channel index, `fcn.00477980` clears it, `fcn.00477990` reads it back to stop the sound. Residue: 177 shipped records carry 1, 2, 4 or 5, at most four per file | — | high |
| `+0x57` | `u8` | **Rested** — set by `fcn.004781C0` to `unit[0x41] == 7`, i.e. "did not act last turn"; grants one extra MP while FP > 1 (`fcn.00475160`). `0` on all but 4 shipped units (value 16) | — | high |
| `+0x58` | `u8` | **Stimulant** — `1` for equipment 3 (`Light Stimulant`), `2` for equipment 4 (`Heavy Stimulant`), `0` for neither (`fcn.00475320`). Exactly the three units carrying a Light Stimulant hold `1`. `255` means **spent this turn**: `fcn.004785B0` pays the value into `+0x15` and stamps `255`, and the refresh turns it back into `0` ([`25` §8](25-turn-and-round.md)) | — | confirmed |
| `+0x59` | `u8` | **Reaction ticket** — per-player sequence number, see §5.12. `0` on all but 7 shipped units (76–84) | — | confirmed |
| `+0x5A` | `u8` | **Cached resale value, in tens of credits** — campaign state, see §5.11. `0` on all but two shipped records (both `5`) | — | confirmed |

`+0x51`/`+0x52` equal `+0x42`/`+0x43` on 1859 of the 1863 placed units and
differ on four — which is what a "position last turn" field looks like in a map
saved mid-session, and not what a duplicate of `x`/`y` would look like. The
previous revision listed them as duplicated coordinates.

Remaining offsets are **UNVERIFIED** and behave like uninitialised memory:
`+0x20`, `+0x3B`, `+0x3C`, `+0x53`, `+0x54`. All are zero on at least 1855 of
the 1863 placed units, and no accessor was found for any of them in either
binary. See §9 item 2 for the sweeps that bound this list.

### 5.3 Skills

The six skill bytes at `+0x1A`..`+0x1F` are settled from the consumer side.
`fcn.0047a6e0(equipId, unit, apply)` — "how many skill points is this unit short
of using this equipment, and optionally raise it" — copies the six skill columns
of the 42-byte `SetEquipInfo` record straight onto the unit:

```
equip +0x23 CON -> unit +0x1A      equip +0x26 TS -> unit +0x1D
equip +0x24 LW  -> unit +0x1B      equip +0x27 MS -> unit +0x1E
equip +0x25 HW  -> unit +0x1C      equip +0x28 LS -> unit +0x1F
```

`fcn.0047a600` does the same for a weapon's four skill columns
(`SetWeaponInfo` `+0x33`/`+0x34`/`+0x35`/`+0x36` -> unit `+0x1B`/`+0x1C`/
`+0x1D`/`+0x1A`). The dialog labels the first five CON/LWS/HWS/TS/MS; the
player-facing names come from the GUI text table
(`DATA/TXT/English/GUI/Txtmod_b.lcl` slots 160–165): *Battle Fitness*,
*Light Weapon Proficiency*, *Heavy Weapon Proficiency*, *Technical Skills*,
*Medical Skills*, *Leadership Skills*.

### 5.4 Equipment (`+0x21`..`+0x35`)

Twenty-one bytes, one per `SetEquipInfo` id, `0` or `1`. The editor's
equipment list box (control 1366, filled by `fcn.004302f0`) walks the
`SetEquipInfo` table at stride 42 for indices 0..20 and prefixes entry *k* with
its "carried" marker when `(&DAT_004C4E59)[k] == 1` — base `0x4C4E59` is record
`+0x21`. The zeroing pass `fcn.0042fe90` clears the same 21 bytes
(`0x4C4E59`..`0x4C4E6D`) when the editor starts a new unit.

The previous revision called `+0x22`..`+0x34` "state flags" and stopped there;
that range was neither the array's start nor its end — `+0x21` (`Scan Module`)
is set on two shipped units, and `+0x35` is equipment id 20, which `Info.lcl`
does not define.

Over all 1863 placed units every one of the 39123 bytes is 0 or 1, 81 are set,
and **only ids that `Info.lcl` actually defines are ever set** — id 2 (absent
from `Info.lcl`) and id 20 (past its last entry) are zero everywhere.

The engine's readers name individual slots, and each one matches `Info.lcl`:

| Slot | `Info.lcl` name | Engine reader |
|---|---|---|
| `+0x21` (0) | Scan Module | `fcn.004794b0`: reveals hostiles within 6 fields as visibility `1` |
| `+0x22` (1) | Long Range Scan | `fcn.004794b0`: same, within 8 fields |
| `+0x26` (5) | Target System | `fcn.004752e0`: doubles the weapon's hit quote, capped at 100 |
| `+0x27` (6) | Ammo Pack | `fcn.004752a0`: doubles the weapon's magazine size |
| `+0x29` (8) | Banner | `fcn.0046fad0`: +1 MP to friendly units within 4 fields |
| `+0x2A` (9) | Explosion Pack | `fcn.0046f7e0`: enables weapon `special` 2 on a neighbour |
| `+0x2B` (10) | Light Armor | front 3 / rear 2 |
| `+0x2C` (11) | Standard Armor | front 4 / rear 2 |
| `+0x2D` (12) | Attack Armor | front 5 / rear 0 |
| `+0x2E` (13) | Heavy Armor | front 6 / rear 4, and **−1 MP** |
| `+0x28` (7) | Jet Pack | `fcn.00475380`: warp range **5** (§4.5), plus the scan side effect below |
| `+0x2F` (14) | Servo System | `fcn.00475160`: **+1 MP** |
| `+0x30` (15) | Small Medic Kit | `fcn.004753c0`: heal strength **1** |
| `+0x31` (16) | Large Medic Kit | `fcn.004753c0`: heal strength **3** |

The **writer settles the base beyond argument**: `fcn.004755D0(unit, id, &cost)`
— "give this unit equipment `id`" — ends with `*(u8 *)(unit + 0x21 + id) = 1`,
then charges `12 x` the skill points the item requires against `+0x18` and calls
the derived-stat recompute. It also enforces the mutually exclusive groups by
zeroing the neighbours first:

| Group | Bytes cleared | Items |
|---|---|---|
| scanners | `+0x21`, `+0x22` | Scan Module, Long Range Scan |
| stimulants | `+0x24`, `+0x25` | Light / Heavy Stimulant |
| armour | `+0x2B`..`+0x2E` | Light / Standard / Attack / Heavy Armor |
| medic kits | `+0x30`, `+0x31` | Small / Large Medic Kit |

and it sets `+0x22` as a side effect of equipment 7, the `Jet Pack` — which is
exactly what `Info.lcl`'s comment on that line says: *"warp & scan"*.

`fcn.004753c0` is worth naming carefully, because its shape invites a wrong
reading. It returns `3` when `+0x31` is set and `1` when `+0x30` is set — the
two **medic kits**, not any kind of movement equipment — and its only real
consumer, `fcn.0047b4c0`, uses it to decide whether the *heal* command is
offered: it takes the cell in front of the unit (`fcn.004308c0` on `+0x46`),
resolves the occupant, checks it belongs to the same player, and returns true
when that unit's `+0x16` is below its maximum (`fcn.00475240`). The UI's
command-availability switch `fcn.00472570` maps that to command `4`.
Movement equipment is `fcn.00475380`, a different routine (§4.5).

`fcn.004759E0` is the derived-stat recompute the whole equipment system funnels
through. It rewrites, in order, `+0x3A`, `+0x16`, `+0x15`, `+0x19`, `+0x58`,
`+0x36`, `+0x37`, `+0x3D`, and clears `+0x41`, `+0x3E`, `+0x40`, `+0x39` — which
is where the three remaining equipment-derived bytes come from:

| Byte | Derived from | Reader |
|---|---|---|
| `+0x3A` | equipment 18 `Damage Absorber` -> 4, else 0 | `fcn.00475580` |
| `+0x58` | equipment 3 `Light Stimulant` -> 1, equipment 4 `Heavy Stimulant` -> 2, else 0 | `fcn.00475320` |
| `+0x3D` | the weapon's magazine size, doubled by equipment 6 | `fcn.004752A0` |

Both hold in the corpus with no exceptions: the two units carrying a Damage
Absorber are exactly the two with `+0x3A` = 4, and the three carrying a Light
Stimulant are exactly the three with `+0x58` = 1.

Armour comes from `fcn.00475490` (front) and `fcn.004754F0` (rear): if the unit
type's armour column is not `255` it is used verbatim, otherwise it is derived
from the four armour equipment slots:

| Carried | front (`0x00475490`) | rear (`0x004754F0`) |
|---|---|---|
| Heavy Armor (`+0x2E`) | 6 | 4 |
| Attack Armor (`+0x2D`) | 5 | 0 |
| Standard Armor (`+0x2C`) | 4 | 2 |
| Light Armor (`+0x2B`) | 3 | 2 |
| **none** | **0** | **0** |

Two corrections to a previous revision. The no-armour default is **0 / 0**, not
"front 1": both routines end in the same idiom, `(-(uint)(rec[+0x2B] != 1) &
mask) + k`, which yields `k` for Light Armor and **0** otherwise. All 64 placed
units whose type declares `255` and that carry no armour item hold `+0x36 = 0`
and `+0x37 = 0`, so the corpus agrees. And `255` is **not** "exactly the human
types": `Info.lcl` declares front `255` on ten types — the four Human Soldiers,
`Dr. Reich`, `Cpt. Rutherford`, `Sgt. Bratt`, `Major Rutherford`, **`Concrete
Block` (35) and `Norc'Yn` (61)** — and rear `255` on twelve, adding `Norc'Yn`
62 and 63. Reading `255` verbatim as an armour value would make a scenery prop
and an alien effectively invulnerable.

The result is cached in `+0x36`/`+0x37`, and the engine rewrites those two bytes
after every fight and whenever a unit is created (`fcn.00479ba0`), so a remake
should treat them as a cache and recompute.

### 5.5 The action-point formula

`fcn.00475160` is the single source of a unit's MP, and it is now fully
readable:

```
mp  = SetUnitInfo[type].mpMax          # unit type 0x32 has a difficulty tweak
mp += 1  if equipment 14 (Servo System)
mp += 1  if a friendly unit carrying equipment 8 (Banner) is within 4 fields
mp -= 1  if equipment 13 (Heavy Armor)
if   FP == 0: mp = 1
elif FP == 1: mp = 2
elif unit[0x57] == 1: mp += 1
if mp > 200: mp = 0                    # underflow guard
if unit[0x41] in (5, 6): mp = 0
```

FP itself is a per-turn stamina pool, topped up by the start-of-turn refresh
`fcn.004781C0` toward the cap `fcn.00475120` returns — **the unit's rank,
`EP / 12`, with a floor of 3**. That routine is what restores everything the
formula above reads, and it is written out in full in
[`25` §5](25-turn-and-round.md).

### 5.6 AI orders (`+0x47`/`+0x48`, `+0x49`/`+0x4A`)

The editor's two "Primary Order" / "Secondary Order" list boxes
(`fcn.00430070`, controls 1287 and 1288) insert eleven strings at indices 0–10,
and the engine's AI turn loop `fcn.00409940` switches on the same byte:

| Value | Order | Units carrying it as primary |
|---|---|---|
| 0 | `Berserk` | 1000 |
| 1 | `Move (ActPt)` | 6 |
| 2 | `Attack (ActPt)` | 14 |
| 3 | `Move (Group)` | 0 |
| 4 | `Attack (Group)` | 3 |
| 5 | `Turn (Wait)` | 57 |
| 6 | `Range (Wait)` | 51 |
| 7 | `Defend` | 103 |
| 8 | `Visibility (Wait)` | 427 |
| 9 | `Clever small units` | 130 |
| 10 | `Disturb` | 72 |

No shipped record holds a value outside 0–10 in either slot.

**What each order actually does** is [`23` §3](23-ai-system.md): every handler
is itself a switch on a search-radius counter that `aAISystemControl` widens
from 0 to 5, and the eleven arms plus their six level tables are read out
there. Order 8 does nothing at all inside the turn loop, orders 1 and 2 share
one block, and order 6's parameter is a trigger radius in fields.

The parameter is order-specific. Two uses are readable:

- `Attack (Group)` passes it to `fcn.0040b210`, which scans the 200 unit records
  for a live unit whose `+0x4E` equals it — i.e. **a group id**. If the group is
  gone the handler promotes the secondary order into the primary slot.
- the wait handler `fcn.0040a6e0` (reached from the same loop) treats it as a
  **countdown**: while it is non-zero the unit's MP is set to 0 and the counter
  decremented; when it reaches 0 the pair `+0x49`/`+0x4A` is copied over
  `+0x47`/`+0x48`. The secondary order is therefore "what to do after the
  primary one expires", not a simultaneous second order.

The `(ActPt)` orders name a cell action point (cell `+0x0B`); of the 22 shipped
order slots holding one, 20 name an action point that exists on that map. All
three `Attack (Group)` slots name group 81, which no unit on their map belongs
to — the fallback in `fcn.00409940` quietly promotes the secondary order there.

The visibility pass corroborates the enum from a third direction:
`aBuildVisibleMapForUnit` (`fcn.004794b0`) wakes an AI unit's group
(`fcn.0047a810(unit[0x4E])`) exactly when it becomes visible and its order is
5, 6 or 8 — the three "wait" orders. Waking is the same promotion as the
countdown above: `fcn.0047a810` copies `+0x49`/`+0x4A` over `+0x47`/`+0x48` for
**every** unit sharing that group id, so one alien spotting a squad turns the
whole group's standing order into its follow-up in a single step. See
[`22` §9.3](22-combat-and-visibility.md).

### 5.7 The owning player (`+0x45`)

`GetUnits`' implementation compares this byte for plain equality, so `255` is a
**stored value**, not a wildcard. Corpus distribution over the 1863 placed
units:

| Value | Units | What carries it |
|---|---|---|
| 0 | 86 | Human player 0 — `Human Soldier (1)`, all named humans |
| 1 | 2 | Human player 1 |
| 252 | 181 | Neutral props — `Barrel`, `Case`, `Concrete Block` |
| 255 | 1594 | Computer / aliens — every `'Ther`, `'Coo`, `'Yn` |

The values are defaults from `Info.lcl`'s `SetUnitInfo` column 4 and match it
per unit name: `Human Soldier (2..4)` are declared with 1/2/3, the props with
252, the aliens with 255.

### 5.8 The unit pool, heroes and speech

`+0x4D` is written by the dialog's two check boxes: `1` for *Unitpool
candidate*, `2` for *Hero*. The engine only tests it for non-zero — in
`fcn.0046f7e0` (weapon `special` 5: "copy the attacked unit into the unit pool
if its unit-pool flag is set") and in the two recruitment paths that call
`fcn.00478c10`. That function copies the **whole 91-byte record** into a pool
array at `0x51F2A0`, 31 slots per player, stride `0x5B`, and rolls a random
1..6 into the copy's `+0x55`.

Corpus: `+0x4D` is 1 on ten named soldiers (`Ramone`, `Casso`, `Bakee`, `Lee`,
`Mendel`, `Rock`, `Austin`, `Knox`, `Wayne`) and 2 on exactly three units —
`Sgt. Bratt`, `Major Rutherford` and the `Scout` type instance named
`Chainsaw Steele`.

`+0x55` selects the voice sample set. The editor's *Select Speech* list box
(`fcn.004304c0`) inserts thirteen entries at indices 0–12, and `fcn.0047b660`
switches on the same byte to pick the sample directory (skipping AI-owned units
and unit type 20, `ComBot`):

| 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| undefined | normal_1 | normal_2 | cool_1 | mimosa_1 | rambo_1 | rambo_2 | female_1 | undefined | undefined | hero_1 | female_2 | spidy |

All 34 shipped non-zero values are in range, and they are carried only by named
humans — `Sgt. Bratt` has `hero_1`, `Major Rutherford` `female_2`.

### 5.9 The type table

`Info.lcl` declares the unit types the `+0x4C` byte indexes:

```
SetUnitInfo (id, "name", "model.3DI", player, mpMax, hpMax, fpMax,
             frontArmour, rearArmour, weapon, special, species, exp,
             size, height, "letter");
```

The handler `fcn.00441590` writes them into a 126-byte-stride table at
`0x51C020`; see [`21-info-lcl-schema.md`](21-info-lcl-schema.md) for the field
layout. `fcn.00479ba0` is the "make a unit of this type" helper: it copies the
description into the name, sets `+0x4C`, `+0x16` from `hpMax`, `+0x3F` from the
default weapon, and `+0x36`/`+0x37` from the armour derivation above.

Sample: `Ray'Ther` = 50, `Gore'Ther` = 51, `Dec'Ther` = 52, `Gore'Coo` = 67,
`Chainsaw Steele` = 25 (the `Scout` entry), `Barrel` = 30/33/34, `Case` = 32,
`Concrete Block` = 35, `Human Soldier (1)` = 0.

### 5.10 Facing (`+0x46`)

`fcn.00479ae0` re-spawns each placed unit and passes `fcn.0046a6e0(rec[0x46])`
as the model rotation. That function is a plain 8-way lookup:

| `+0x46` | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| angle | 0 | 3072 | 2048 | 1024 | 1536 | 3584 | 512 | 2560 |

**A full turn is 4096 engine units**, so 1024 = 90° and 512 = 45°. This is the
same unit as the rotation fields of the 3D object records.

### 5.11 The campaign roster — where EP and TP actually move

The same 91-byte record is used a second time, for the **persistent squad**
that survives between missions. That array is static, not heap-allocated, which
is what makes it readable: because the slot index is scaled at run time, every
field access compiles to an absolute displacement `0x51F2A0 + offset`, so a
whole-image sweep for those displacements enumerates *every* accessor of the
persistent copy. There are 100 of them.

```
roster base   0x0051F2A0
record stride 0x5B                    (the unit record above)
slot address  0x51F2A0 + (player * 31 + slot) * 0x5B
usable slots  30 per player           (fcn.004789b0 scans 0 .. 0x1D)
array shape   aUnit[5][31]            (fcn.00478600, see below)
sizeof        14105 bytes             (0x51F2A0 .. 0x005229B9)
```

The array's **outer** bound does not follow from the accessors — every one of
them scales by 31 and stops there. It comes from `fcn.00478600`, which clears
the roster before a load:

```asm
edx = 0x51F2A0
loop:  ecx = 682;  edi = edx;  edx += 0xB05      ; row stride 2821 = 31 * 0x5B
       rep stosd                                 ; 2728 bytes
       stosw                                     ; + 2 = 2730 = 30 * 0x5B
       cmp edx, 0x5229B9 ; jl loop
```

Rows are 2821 bytes apart and 2730 of each are cleared — 31 slots per row, 30
of them usable, which is exactly what the accessors say. The span
`0x5229B9 − 0x51F2A0` = 14105 is **five** of those rows. So the roster is
`aUnit[5][31]`, five players' worth.

This matters for saves: the save file's roster block is 5460 bytes = `2*30*0x5B`
— the count of *usable* slots for two players, which does not line up with rows
that are 31 records apart. See
[`11-save-game-format.md`](11-save-game-format.md) §5.7 for what that costs.

Everything below is in `aMissionControl.cpp` unless stated otherwise.

**Recruiting** (`fcn.004789b0`) takes the first slot with `+0x16 == 0`, names it
`"Soldier %d"`, and seeds

```c
rank        = (gameMode == 1) ? 0 : globalRank;   /* fcn.0043b740 / fcn.0043b0d0 */
rec[+0x17]  = rank * 12;        /* EP */
rec[+0x18]  = rank * 12;        /* TP */
rec[+0x19]  = max(rank, 3);     /* FP */
```

which is the same `rank * 12` seeding the in-mission spawn `fcn.00479cf0` does
(see [`21-info-lcl-schema.md`](21-info-lcl-schema.md) §8) — the two fields
coincide at creation and diverge afterwards.

**TP is credited in exactly one place, and always by 12.** The Mission Control
screen has an *award decoration* button (gadget 5). Its handler is case 3 of
`fcn.0045a770` (`aMissionControl.cpp` line 7674):

```c
if (rec[+0x18] == 144) return;              /* 0x0045add8 */
aInsertStrIntoTxtSys(0x6E, rec);            /* the "decorated" message */
rec[+0x38] += 1;                            /* 0x0045ae61 */
rec[+0x18] += 12;                           /* 0x0045ae82 .. 0x0045ae93 */
aDecDecorations(player);                    /* fcn.0043b120 */
```

and the button-enable pass `fcn.00458270` greys it out when any of

```c
fcn.00475550(rec) <= rec[+0x38]     /* decorations already at the EP tier */
rec[+0x18] > 0x77                   /* 119 — i.e. TP already 10 points */
rec[+0x4D] == 2                     /* heroes cannot be decorated */
```

`fcn.00475550` is the **decoration allowance**, derived from EP alone:

| `+0x17` (EP) | 0–39 | 40–59 | 60–99 | ≥ 100 |
|---|---|---|---|---|
| decorations allowed | 0 | 1 | 2 | 3 |

Note that the two caps disagree: the button stops at 119, so the handler's
`== 144` guard is unreachable in normal play; 120 (10 skill points) is the
attainable maximum.

**TP is spent** on the equipment screen `fcn.0045a170` (`GUI_Menu_b.LCL`),
which prints `rec[+0x18] / 12` into text slot `0x9C` and greys out any item
whose skill cost exceeds it (`rec[+0x18] < fcn.0047a600(item, rec, 0) * 12`).

**`+0x38` — decorations awarded.** Written only by the handler above, read only
by the button-enable pass. Campaign state; zero in every shipped `.lev`.

**`+0x5A` — cached resale value, in tens of credits.** After every weapon
purchase (`aBuyWeapon`, `fcn.00475680`) the screen recomputes

```c
rec[+0x5A] = fcn.004776e0(rec);
/* = (weaponinfo[rec[+0x3F] * 0x43] + carried-equipment bonuses + 50) / 10 */
```

and when the soldier is dismissed (`aRemoveUnitFromUnitPool`, `fcn.00478b70`)
the screen refunds `rec[+0x5A] * 10` credits through `fcn.0043b010`. Money
lives at `0x00509EEC[player]` and is capped at 10000; the decoration pool lives
at `0x00509EFC[player]`.

**A cheat menu writes TP too.** `fcn.00454fb0` is the Mission Control key
handler. Typing `i` then `x` fills `0x00510DF4` and arms `0x00510DF0`; the
digits then fire:

| Key | Effect |
|---|---|
| `1` | `fcn.004313e0` — set `+0x00` to 3 on every cell whose `+0x0B` is set |
| `2` | `fcn.0043b0a0(0, 500)` — set player 0's credits to 500 |
| `3` | `fcn.004786e0(0)` — set `+0x18` to **120** on all 30 alive slots |
| `4` | skip to the next mission |

None of this ever writes a `.lev`: the roster is campaign state. The shipped
maps' TP values (10, 20, 52, 146, 176, 196, 244 — mostly not multiples of 12,
and several above the reachable 120) come from the **editor's free-form edit
control 1216**, not from any runtime crediting rule.

### 5.12 Weapon heat, malfunctions and the reaction queue

Three more fields that are zero in every shipped map but are live at run time.
They are grouped here because they interlock.

**`+0x3E` — weapon heat.** `fcn.00475340(unit)` returns the heat **limit**:

```c
limit = weaponinfo[unit[+0x3F] * 0x43 + <col>];      /* 0x0051B2FA */
if (unit[+0x34] == 1 && limit != 0xFF) limit *= 2;   /* equipment 19, "Cooler" */
```

`0xFF` means the weapon does not heat, and the whole mechanic is skipped. The
combat resolver `fcn.0046B450` raises the counter by one per shot while it is
below the limit (`0x0046C2C7`…`0x0046C2E1`), and slams it straight to the limit
for weapon id `0x2F` (`0x0046B5EE`). The turn refresh `fcn.004781C0` cools it
back down by 2 or 1 per turn, clamped at 0 (`0x00478345`…`0x00478356`), and the
stat recompute `fcn.004759E0` zeroes it.

That the **Cooler doubles the limit** is what identifies the field: it is the
only reading under which equipment 19's name and the `× 2` agree.

**`+0x40` — malfunction state.** When the heat reaches the limit, the resolver
calls `aCheckWeaponDamage` (`fcn.0046D1B0`), which rolls `aRandom(0, heat)`
(`fcn.00463870`, see [`22` §3](22-combat-and-visibility.md)) and branches on the
result. Because the *span* of the roll is the weapon's own heat limit, a weapon
capped below 31 can never reach the last row, and the Cooler — which doubles the
limit — widens the range of bad outcomes rather than narrowing it:

| Roll | Effect spawned (`fcn.0040F420(x, y, kind)`) | `+0x40` |
|---|---|---|
| 0–10, weapon class ∉ {0, 2, 3, 4} | kind 2 | `2` |
| 0–10, weapon class ∈ {0, 2, 3, 4} | kind 3 | `5` |
| 21–24 | kind 3 | `5` |
| 30 | kind 1, and **the unit is removed from the map** — `aRemoveUnitElement` (`fcn.004779c0`) takes it off its cell, after which the cell's **effect** slot is released (`+0x10` → `0xFF`, `+0x0E` → `0`) | n/a |
| anything else | none | `0` |

Non-zero `+0x40` **blocks firing**: `fcn.004753E0`, the "can attack" gate the UI
consults, returns 0 outright when it is set, and the HUD `fcn.00417E70` branches
on it when drawing the unit's status. `fcn.004759E0` clears it.

**`+0x59` — reaction ticket.** `fcn.00478500` marks a unit as having a pending
reaction (`unit[+0x41] = 1`) and stamps it with a **per-player monotonic
counter** at `0x00517F50[player]` (dword, stride 4, pre-incremented):

```c
unit[+0x41] = 1;
unit[+0x59] = ++counter[unit[+0x45]];
```

`fcn.0046CCA0` then drains the queue. It walks the tickets from **1 upward**,
resolving the reaction of the unit that holds each — a *first*-in-first-out
interrupt queue, and only in game mode 1; every other mode ignores the ticket
and scans the slots in index order. The turn refresh `fcn.004781C0` clears
`+0x59`, and **decrements** `+0x3E` by one — or by two for weapon ids 4, 6 and
41 — rather than clearing it. The full mechanic, including what does *not*
clear `+0x41`, is [`25` §6](25-turn-and-round.md).

> An earlier revision of this paragraph said the drain took the highest ticket,
> last in first out. That mistook the pass that finds the highest live ticket —
> which only bounds the walk — for the selection itself.

---

## 6. 3D object blocks

Three blocks. All three hold records with the **same prefix layout** — that is
how the engine's add-helpers `fcn.00404ae0` (land), `fcn.00404f80` (scene
clones) and `fcn.00404e30` (special) write them:

| Offset | Type | Meaning |
|---|---|---|
| `+0x00`, `+0x04` | `2 x u32` | Stale runtime pointers — ignore |
| `+0x08` | `u32` | Prototype index into the world set's `prototyp.din` — **runtime** value |
| `+0x0C` | `u32` | Handle derived from the prototype — runtime |
| `+0x10` | `i32` | **x**, world units |
| `+0x14` | `i32` | **y**, world units |
| `+0x18` | `i32` | **z**, world units |
| `+0x1C` | `u32` | Always written as `0`; `0` in 100% of records |
| `+0x20` | `u16` | Rotation, first component (always 0 in shipped data) |
| `+0x22` | `u16` | Rotation, second component (always 0 in shipped data) |
| `+0x24` | `u16` | Rotation, third component; 4096 = 360°, **not** wrapped |

Blocks differ only in their tails: 64 bytes for the scene clones, 66 for the
special objects (`+0x40`, `+0x41`), 70 for the land lattice
(`+0x40`, `+0x44`, `+0x45`).

Rotation values accumulate rather than wrapping — the corpus contains 0, 1024,
… 16384, 25600 and negative values such as `0xFC00` (−1024). Read them modulo
4096.

Two facts about the shipped values, measured over all three arrays of the 153
missions in `Missions/` — 194 105 object records in total:

* **Rotation is yaw only.** The first two components are zero in every single
  record, which is what makes `+0x24` the heading (§9 item 6). `lev_parse.py
  --check` enforces this as an invariant, 155/155.
* **The world is built on quarter turns.** 193 076 of the 194 105 records
  (99.5 %) have a yaw that is a multiple of 1024 modulo 4096: **181 337 of
  181 337** land-lattice records, **10 289 of 11 238** special objects and
  **1 450 of 1 530** scene clones. The finer values (100, 200, 300, …) are a
  minority confined to the two hand-placed arrays. A remake can rely on the
  four-fold symmetry this implies — see
  [`92` §7.5](92-remake-architecture.md).

The three rotation slots are filled in file order by the `.3DW` scene loader:
`fcn.00407640` parses a `[CLO]` block's `ROTATION a b c` triple and calls
`fcn.00404f80(name, …, a*16, b*16, c*16)`, which stores them at `+0x20`,
`+0x22`, `+0x24`. **Which model axis each one turns is still not established**
— see §9.

### 6.1 Block 1 — the scene header (724 bytes)

Written from the global at `0x4FA528` (`fcn.00407400` returns its size `0x2D4`).
The tail of the struct carries the three array counts, which is what makes the
rest of the file parseable:

| Offset | Type | Meaning | Confidence |
|---|---|---|---|
| `+0x000` | `u32` | **Deployment-ring placed** flag. `fcn.004721A0` builds the ring (below) and then sets it to 1; `fcn.00471AD0` clears it; the HUD and mouse handlers (`fcn.00450E80`, `fcn.00450EA0`, `fcn.00450F10`, `fcn.00417E70`) gate on it. Runtime state — `0` in every file | high |
| `+0x004` | `10 x 64` | Ten 3D-object records: the squad-**deployment ring** (`fcn.00406C00` indexes them with stride `0x40`) | high |
| `+0x284` | `u32` | `0` in every file; no accessor found | UNVERIFIED |
| `+0x288` | `u32` | **Land object count** — number of valid records in block 3 | confirmed |
| `+0x28C` | `u32` | **Special object count** — number of valid records in block 2 | confirmed |
| `+0x290` | `u32` | **Scene clone count** — `[CLO]` blocks loaded from the `.3DW` | high |
| `+0x294` | `64` | One more 3D-object record — the `CLS.3DI` **selection marker**, see below | confirmed |

Validation:

- `+0x288 == width * height` in **155/155** files.
- `+0x28C` exactly delimits the block-2 records whose `+0x40` is `69`: every
  slot below the count has it (11410 records), every slot above is either MSVC
  fill or a stale leftover.
- `+0x290` equals the number of `[CLO]` blocks in the referenced `.3DW` file in
  **150 of the 154** files whose scene file could be located. The four
  exceptions are all in world set `D00`.

The ten records at `+0x004` are the squad-deployment ring that
`fcn.00406AA0` builds at runtime — it places ten `SOLD00.3DI` clones on a circle
of radius 3550/2366 world units around a point. `fcn.004721A0` calls it with the
land object under the cursor and then sets `+0x000` to 1; `fcn.00471AD0` sets it
back to 0. Their shipped contents are runtime residue: 128 records carry
`0xFFFFFFFF` as the prototype, the rest a scatter of unrelated prototypes
(`A_50A.3DI`, `PR_005_BOX01`, …), and most of the 1550 slots are all-zero.

The 64 bytes at `+0x294` are an **eleventh 3D-object record** of the same shape,
which is why the block is 724 = `0x294 + 0x40` bytes long. `fcn.00406FC0`, the
scene-init routine, fills it:

```c
marker->x = 0;  marker->y = 0;  marker->z = 0xFFE79600;   /* -1600000 */
marker->rotX = marker->rotY = marker->rotZ = 0;
marker->prototype = LookupPrototype("CLS.3DI");
AddObjectToScene(marker);
```

That explains the last two unknown fields outright:

- `+0x29C` is the record's **prototype index** for `CLS.3DI`, so its 16 distinct
  shipped values (0, 44, 65, 68, 75, 76, …) are just that model's slot in each
  world set's `prototyp.din`. It is a runtime index and must be re-resolved on
  load, exactly like block 2's `+0x08`.
- `+0x2AC` is the record's **z**, and the constant is `-1600000` exactly —
  **−1000 m** at 1600 world units per metre. The marker is simply parked a
  kilometre below the map when it is not in use.

Corpus check: `+0x294`, `+0x298`, `+0x2A0`, `+0x2A4`, `+0x2A8`, `+0x2B0` and the
three rotation halfwords at `+0x2B4` are zero in all 155 files, and `+0x2AC` is
`-1600000` in all 155 — exactly the shape of a freshly initialised record.

### 6.2 Block 2 — special objects (150 slots x 66 bytes)

These are the map's **own** scenery objects: geometry the designer placed in the
editor on top of whatever the `.3DW` scene already contains. The engine draws
and collides them in the same loops as the `.3DW` clones (`fcn.00453490` walks
this array with stride `0x42` and then the clone array with stride `0x40`).

They are *not* what the LCL commands `Platform`, `Elevator` and friends move —
`Platform`'s handler (`fcn.004422b0` -> `fcn.00412a00`) goes through the cell
grid and displaces **land** objects via the cell's `+0x05` link. Nor are they
what a cell's `+0x0F` / `+0x11` fields index; those point into a separate
81-slot runtime array (`fcn.00404c00`).

| Offset | Type | Meaning | Confidence |
|---|---|---|---|
| `+0x08`..`+0x24` | | Common 3D-object prefix, §6 | confirmed |
| `+0x40` | `u8` | **Prototype letter** — `69` = `'E'` in all 11410 records | confirmed |
| `+0x41` | `u8` | **Prototype number**, 128 distinct values | confirmed |

The last two bytes are the object's real identity. `aLoadBattleMap`'s fix-up
pass `fcn.00404d30` reads `*(u16*)(rec + 0x40)` for every record and hands it to
`fcn.00407540`, which rebuilds a filename and re-resolves the prototype index:

```c
if (number >= 100 && number <= 129)
    sprintf(name, "L%03dEX00.3DI", number);          // shared object set
else
    sprintf(name, "L%03d%c%s.3DI", number, letter, worldSet);
rec->prototype = LookupPrototype(name);              // overwrites +0x08
```

**Validated: all 11410 records across all 155 files resolve to a name that
exists in the referenced world set's `prototyp.din`, with zero misses.** The
naming scheme is corroborated by `Info.lcl`, which gives `Concrete Block` the
model `L084EE00.3DI` — `L` + `084` + `E` + world set `E00`.

The writer side confirms the scheme from the other direction: `fcn.00404e30`,
which appends a special object, derives the two bytes from the model name with
`fcn.00407430` — `param_2[0] = name[4]` (the letter after the three digits) and
`param_2[1] = atoi(name+1)`.

Because the engine recomputes `+0x08`, the stored value is stale: it matches the
`.din` index in only 7633 of the 11410 records. **Use `+0x40`/`+0x41`, not
`+0x08`.**

`x` and `y` sit on the 3200 lattice in 100% of records; `z` does not (10194 of
11410 are multiples of 3200, the rest are intermediate heights).

### 6.3 Block 3 — the land lattice (2500 slots x 70 bytes)

**One record per battle-map field**, in the same row-major order as the CtrlMap.

| Offset | Type | Meaning | Confidence |
|---|---|---|---|
| `+0x08`..`+0x24` | | Common 3D-object prefix, §6 | confirmed |
| `+0x40` | `u32` | Always `1`; `fcn.00404aa0` pre-sets it for all 2500 slots | confirmed |
| `+0x44` | `u8` | **grid x** | confirmed |
| `+0x45` | `u8` | **grid y** | confirmed |

Validated over all 155 files and 184162 land records:

- record count (block 1 `+0x288`) equals `width * height` — 100%
- `x`, `y` are exact multiples of 3200 — 100%
- `+0x44` == `x / 3200` and `+0x45` == `y / 3200` — 100%
- the land object at index `cell[+0x05]` has exactly the cell's grid
  coordinates — 100%
- `land.z == cell[+0x01]` (the cell height) — 100%

Each file uses exactly **one** prototype for its whole lattice: this is the
floor tile the editor creates in `aInitCtrlMap` from the model name
`S003_00X.3DI`. The `+0x08` value is a runtime index and differs per file; it is
not re-resolved on load, so it is only meaningful inside a matching runtime
prototype table.

> The previous version of this document claimed a fixed 40x40 or 50x50 lattice
> independent of the field grid, and up to 30 distinct prototypes. That was an
> artefact of scanning for a `0xCDCDCDCD` sentinel instead of reading the count
> in block 1 — the extra records are stale leftovers from earlier edits of the
> same map.

---

## 7. Units and scale

One map field is **3200 world units**; the constant appears literally in the
engine (`mov edi, 0xC80`), in the land lattice spacing, and in
`fcn.0042ef10`'s "raise this field by one tile" (`cell.height += 0xC80`).

One metre is **1600 world units**, from the editor's `camera height (meter)`
control, whose writer multiplies by `0x640`. So one field is 2 m x 2 m, and
shipped camera heights of 12–40 m correspond to 19200–64000 units.

Cell heights are in the same world units as land-object `z` — they are literally
the same value (§6.3). A cell height of 1950 is 1.22 m, i.e. a knee-high step;
the flat floor is 0.

Rotations use 4096 units per full turn (§5.10).

---

## 8. Tooling

- `tools/inclib/lev.py` — the parser library.
- `tools/lev_parse.py` — CLI.

```bash
python3 tools/lev_parse.py gog_incubation --check          # 155/155
python3 tools/lev_parse.py gog_incubation/Missions/_C_105.lev
python3 tools/lev_parse.py gog_incubation/Missions/_C_105.lev --map
python3 tools/lev_parse.py gog_incubation/Missions/_C_105.lev --objects
python3 tools/lev_parse.py gog_incubation/Missions/_C_105.lev --json
python3 tools/lev_parse.py gog_incubation --png -o tools/out/maps
```

`--check` verifies structural invariants, not just the file size: land count
equals `W * H`, land objects sit on the 3200 lattice with matching grid bytes,
every cell's land link points at a land object with the cell's coordinates and
the same height, every special object carries the `'E'` prototype letter, every
placed unit's equipment bytes are 0/1 with AI orders in 0..10, a speech id in
0..12 and a unit-pool flag in 0..2, and block 1's marker object sits at its
parked position with the deployment-ring flag clear.

The summary view prints the decoded per-unit stats — AI orders and their
parameters, group, EP/rank, TP, FP, the six skills, the carried equipment by
name, hero / unit-pool flag and the speech set — and `--json` exposes all of
them plus the raw equipment array.

The `--png` renderer colours by field type, modulates brightness by height, and
marks units red and action points yellow. `--map` uses the editor's own terrain
glyphs (`.` free, `#` wall, `v`/`V` hole, `;` debris, `P` poison, `T`/`X`
teleporters), with `S` for deployment fields.

---

## 9. Open questions

The unit record and the three object blocks are now decoded field by field; what
is left is small and mostly unfalsifiable from the shipped data.

1. ~~**Where unit record `+0x18` ("TP") is *credited*.**~~ **— CLOSED.** The
   crediting path is the *award decoration* button on the Mission Control
   screen, and it adds exactly **12** each time, capped by the soldier's EP
   tier. Full trace in §5.11. The premise that raised this item — "most shipped
   values are not multiples of 12" — was the wrong place to look: those values
   are editor input (dialog edit 1216), not runtime state. The campaign roster
   at `0x0051F2A0` starts every soldier at `rank * 12` and moves in steps of 12
   thereafter; the only other writer is a cheat key that sets 120 outright.

2. **The unit bytes with no reader at all.** The list was eleven; **six are now
   closed** and five remain.

   | Offset | Now |
   |---|---|
   | `+0x38` | decoration count (§5.11) |
   | `+0x3E` | weapon heat (§5.12) |
   | `+0x40` | weapon malfunction state (§5.12) |
   | `+0x59` | reaction ticket (§5.12) |
   | `+0x5A` | cached resale value (§5.11) |
   | `+0x50` | distance walked this turn, tenths of a field ([`25` §5.1](25-turn-and-round.md)) |
   | `+0x20`, `+0x3B`, `+0x3C`, `+0x53`, `+0x54` | **still open** |

   Two things had hidden the five. First, the *mission* unit array is
   heap-allocated: accesses go through the accessor `fcn.00477AE0` and carry no
   recognisable displacement, so earlier sweeps had nothing to grep for. The
   persistent **campaign roster** is a static array, so every access to it
   compiles to an absolute `0x51F2A0 + offset`; sweeping the whole image for
   those 91 displacements gives 100 sites over 25 distinct fields, which is what
   settled `+0x38` and `+0x5A`. Second, Ghidra's decompilation **misses byte
   writes that its type recovery folds away** — `+0x3E` shows one write in the
   pseudocode and four in the raw disassembly, and the three it drops are the
   ones that explain the field. Both sweeps were therefore re-run against
   `pdf @@f` output rather than the C.

   For the five that remain, the same two sweeps — the roster displacement sweep
   and a raw-disassembly sweep restricted to functions that touch at least three
   of the unit record's unambiguous offsets — return **no site at all**. Every
   apparent hit belongs to a different structure that happens to share an
   offset. That is the strongest negative evidence available short of source.
3. **Block 1 `+0x284`** is zero in all 155 files and no accessor touches it. Like
   any all-zero field it cannot be characterised from the data, and the code is
   silent, so it stays open.
4. **Header `+0x35F`** is written with a default of `'a'` and read exactly once,
   with the result discarded (`fcn.004107A0`, called from `fcn.0040FFA0`). It is
   vestigial in this build. Settling it would need an earlier build of the editor
   or its source.
5. **The scene-clone array itself is never saved.** Only its count reaches the
   `.lev` (block 1 `+0x290`); the objects are re-parsed from the `.3DW` on every
   load. Any remake must read the `.3DW` — see
   [`30-eng3d-ascii-formats.md`](30-eng3d-ascii-formats.md).
6. ~~**The axis assignment of object rotations `+0x20` and `+0x22`.**~~
   **Closed: `+0x24` (the third component) is the yaw**; `+0x20` and `+0x22`
   are the two remaining axes and are zero in every shipped record.

   The concern that raised this item was sound — the same loader *does* permute
   the position triple (`.3DW` `POSITION x y z` becomes record `x`, `z`, `−y`),
   so file order alone proves nothing about the rotation triple — but the
   consumer is reachable after all, by two independent routes:

   * **Unit facing, entirely inside `Incubation.exe`.** `fcn.0046A6E0` maps an
     8-way heading to an angle (`0`, `0xC00`, `0x800`, `0x400`, `0x600`,
     `0xE00`, `0x200`, `0xA00` — every value a multiple of `0x200` = 4096/8,
     i.e. exact 45-degree steps), and both of its callers (`fcn.0046E220`,
     `fcn.004792A0`) feed it straight into the third slot:

     ```c
     angle = fcn_0046A6E0(direction);
     fcn_004051E0(objectId, 0, 0, (short)angle);   /* +0x20=0, +0x22=0, +0x24=angle */
     ```

     A heading is a yaw by definition, and it is always written to `+0x24`.

   * **The transform itself, inside `Eng3d.dll`.** The indirect call does land in
     `Eng3d.dll`, but the receiving code is recoverable there: at `0x00405F27`
     / `0x00405F59` / `0x00405FDA` it takes `lea esi, [ebx + 0x20]` — the
     rotation triple — and calls the matrix builders `fcn.00411BF6`
     (`RzRxRy`) and `fcn.00411A93` (`RyRxRz`), which are the routines that read
     the sine table. See
     [`30-eng3d-ascii-formats.md`](30-eng3d-ascii-formats.md) §2.5 for the
     full chain and the resulting axis convention.

   Which of `+0x20` and `+0x22` is pitch and which is roll is still
   **UNVERIFIED** — no shipped record sets either, and the two matrix builders
   differ only in composition order, which nothing in the shipped data selects.

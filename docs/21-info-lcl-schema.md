# `DATA/Info.lcl` — the game database schema

`DATA/Info.lcl` is an LCL program (see `docs/20-lcl-language.md`) with no
labels: the host runs it once at start-up and every statement in it is a
side-effecting *load* into one of the engine's global tables. Between them
those tables are the whole of *Incubation*'s balance data — control-map cell
types, equipment, weapons, units and sound volumes.

**Provenance.** Every field offset, table base, record stride and bound in this
document was read out of `Incubation.exe`'s command implementations
(`aLCL_Com.cpp`), located by decompilation and confirmed against the raw
disassembly. Field *names* come from `Info.lcl`'s own column headers (the
authors left aligned two-line headers above each table) and, where the engine
displays a field, from the GUI text slot it is written into. Where the two
agree the field is marked **confirmed**; where only the header names it, the
name is the authors' own but the meaning is **UNVERIFIED**.

Argument indices below are *per kind*: the interpreter puts numeric arguments
into one array and string arguments into another, each in its own order (see
`docs/20-lcl-language.md` §4.3). `num[k]` therefore means "the k-th *numeric*
argument", counting from 0. In practice each of these commands has a fixed
argument shape, so the "argument N" column (1-based, counting every argument)
is what you match against the file.

---

## 1. Table summary

| Command | Handler | Table base | Stride | Max index | Records |
| --- | --- | --- | --- | --- | --- |
| `SetCtrlMapInfo` | `0x00440f30` → `0x0042f6f0` | `0x004feb80` | 23 (`0x17`) | 10 | 11 |
| `SetEquipInfo` | `0x00441480` | `0x00517bb0` | 42 (`0x2a`) | 20 | 21 |
| `SetWeaponInfo` | `0x004412a0` | `0x0051b2c0` | 67 (`0x43`) | 50 | 51 |
| `SetWeaponInfo2` | `0x004413f0` | `0x0051b2c0` | 67 (`0x43`) | 50 | *(same records)* |
| `SetUnitInfo` | `0x00441590` | `0x0051c020` | 126 (`0x7e`) | 100 | 101 |
| `SetVolumeCtrl` | `0x00441050` → `0x00437500` | `0x00504638` | 4 | 120 | 121 |
| `SetCharismaInfo` | `0x00441780` | `0x00518368` | 120 (`0x78`) | 100 | 101 |

An out-of-range index is reported and the statement is dropped — the program
continues. `SetWeaponInfo`, `SetEquipInfo` and `SetUnitInfo` additionally refuse
to overwrite a record whose in-use byte is already set (`SetWeaponInfo_WeaponType
in use!`, `SetEquipInfo_EquipType in use!`, `SetUnitInfo_UnitType in use!`), so
**the first definition of an id wins** and a duplicate is silently ignored.
`SetWeaponInfo2` has no such guard: it patches fields of a record
`SetWeaponInfo` already created.

---

## 2. `SetCtrlMapInfo` — control-map cell types

```
SetCtrlMapInfo (index, type, delay, cover, "name");
```

`Info.lcl` heads the table itself:

```
*        index   type    delay   cover(%) comment
SetCtrlMapInfo ( 2,  2,   255, 255, "Wall");
SetCtrlMapInfo ( 7,  7,   255, 40,  "Enormous Obs");
```

23-byte record at `0x004feb80 + index*23`:

| Offset | Size | Argument | Field | Status |
| --- | --- | --- | --- | --- |
| +0x00 | 1 | 2 (`num[1]`) | `type` | read by `0x0042f6d0(cell)`, which returns it for the cell's control-map type byte |
| +0x01 | 1 | 3 (`num[2]`) | **`delay` — movement cost**; one step costs `delay + 1` | confirmed: `0x0046e220`, the unit-walk routine, subtracts `record[+0x01]` (plus a per-step constant) from the mover's remaining movement points at every step; `0x0042f6b0` returns it and `0x0046fc90` / `0x0046ff20` / `0x00479c60` treat **255 as "not enterable"**. `aBuildMoveMap` reads it at `0x00430D10` and the per-step constant is visibly `dec al`, so the cost of entering a field is `delay + 1` — see [`23` §7.4](23-ai-system.md), which also covers the ladder-to-ladder case and the height limit |
| +0x02 | 1 | 4 (`num[3]`) | `cover` percentage | **never read — in either shipped binary.** See 2.1 below; the name is the authors', taken from the `Info.lcl` header comment, and the field is dead code |
| +0x03 | 20 | 5 (`str[0]`) | name | read by exactly one caller — the debug/cheat overlay at `0x0041af01`, which prints `"ElementType: (%d)-%s"` |

`index` is 0..10 and the shipped file sets `type == index` for all eleven, so
the two are interchangeable in practice. The eleven types are: `Undefined`,
`Free Place`, `Wall`, `Hole`, `Deep Hole`, `Debris`, `Poison`, `Enormous Obs`,
`Ladder`, `Teleporter Entry`, `Teleporter Exit`.

The per-cell type byte is `cell+0x0d`, written by `SetCtrlMapType (x,y,type)`
(`0x00442a80`) and read by `GetCtrlMapType (var,x,y)` (`0x00442ac0`).

### 2.1 `cover` — authored, and dead in both shipped binaries

The level editor has now been traced, and it does not read the column either.
The searches, so the negative is checkable:

*`Incubation.exe`.* Scanning the whole image for a 32-bit little-endian operand
pointing anywhere into `0x004feb80 … 0x004fec6d` (the full 11-record extent)
finds exactly **five** references, and not one of them is a `+0x02` form:

| Site | Operand | Meaning |
|---|---|---|
| `0x0042f6ab` | `+0x00` | `0x0042f690` returns the whole record pointer |
| `0x0042f6c5` | `+0x01` | `0x0042f6b0` returns `delay` |
| `0x0042f6e5` | `+0x00` | `0x0042f6d0` returns `type` |
| `0x0042f712` | `+0x00` | `0x0042f6f0` — the writer behind `SetCtrlMapInfo` |
| `0x00430d12` | `+0x01` | `delay` read inlined into a move-cost caller |

The one routine that hands out a whole-record pointer (`0x0042f690`) has three
callers and none of them adds 2.

*`iDesigner.exe`.* The editor keeps its own copy of the table at
`0x004b0cd8 + index*0x17`, written by `SetCtrlMapInfo` through
`0x00423ec0` → `0x0041ab80` from the same four arguments in the same order —
which independently corroborates the record layout above. The same whole-image
operand scan over `0x004b0cd8 … 0x004b0dd5` finds exactly **five** references in
the entire binary:

| Site | Operand | Meaning |
|---|---|---|
| `0x0041ab3b` | `+0x00` | `fcn.0041ab20(type)` returns the whole record pointer |
| `0x0041ab55` | `+0x01` | `fcn.0041ab40(cell)` returns `delay` for a cell |
| `0x0041ab75` | `+0x00` | `fcn.0041ab60(cell)` returns `type` for a cell |
| `0x0041aba2` | `+0x00` | `fcn.0041ab80(index, src)` — the writer |
| `0x0041bb52` | `+0x01` | `delay` read inlined into the move-cost routine `fcn.0041b880` |

There is **no `0x004b0cda` operand anywhere in the image**, and the single
caller of the whole-record getter — `fcn.00410b60 @ 0x00410db9`, the editor's
status overlay — does `add eax, 3` and prints `"Type: %s"`, i.e. it jumps
straight from the record base to the name at `+0x03`. That is the same shape as
the game's own overlay (`"ElementType: (%d)-%s"`, `0x0041af01`).

*No label either.* `cover` and German `deckung` (case-insensitive) were swept in
**ASCII and UTF-16LE** over all 35 PE files shipped in the game directory: the
only hits are inside the third-party Glide DLLs (`glide.dll`, `glide2x.dll`,
`glide3x.dll` — Voodoo coverage/anti-aliasing terminology). Neither Blue Byte
binary contains the word, and the editor's own terrain UI exposes only
*"Set CtrlMap Types"* and *"Set CtrlMap Height"* (menu resource 106) with a
seven-entry *"Select Field Type"* list — no cover control.

**Closure: `cover` is authored metadata that no shipped binary reads.** A remake
must still round-trip the byte to reproduce `Info.lcl`, but nothing consumes it.
The percentages in the shipped file (`255` for `Wall`, `40` for `Enormous Obs`,
…) look like a to-hit modifier that was designed and never wired up; that
reading is **UNVERIFIED** and no behaviour is claimed for it.

---

## 3. `SetEquipInfo` — equipment

```
SetEquipInfo (id, "Name", cost, CON, LW, HW, TS, MS, LS, tech, "key", icon);
```

12 arguments. `Info.lcl`'s header, with the six skill columns named on stacked
lines:

```
*                        CON  LW  HW  TS  MS  LS
*        id  Name        Cost Skills          Tech Key Icon
SetEquipInfo (7, "Jet Pack", 190, 4,0,0,3,0,0, 4, "G", 6);   * warp & scan
```

42-byte record at `0x00517bb0 + id*42`:

| Offset | Size | Argument | `num`/`str` | Field |
| --- | --- | --- | --- | --- |
| +0x00 | 1 | — | — | in-use flag, set to 1 |
| +0x02 | 30 | 2 | `str[0]` | name |
| +0x20 | 1 | 3 | `num[1]` | **cost** in equipment points |
| +0x21 | 1 | 10 | `num[8]` | **tech** level required |
| +0x22 | 1 | 12 | `num[9]` | **icon** index |
| +0x23 | 1 | 4 | `num[2]` | skill **CON** |
| +0x24 | 1 | 5 | `num[3]` | skill **LW** (light weapons) |
| +0x25 | 1 | 6 | `num[4]` | skill **HW** (heavy weapons) |
| +0x26 | 1 | 7 | `num[5]` | skill **TS** (technical skill) |
| +0x27 | 1 | 8 | `num[6]` | skill **MS** (medical skill) |
| +0x28 | 1 | 9 | `num[7]` | skill **LS** (leadership) |
| +0x29 | 1 | 11 | `str[1][0]` | **key** — first character only |

Note the odd write order: the loader stores the six skills contiguously at
+0x23..+0x28 but puts tech and icon *before* them at +0x21/+0x22, which is why
the argument order and the memory order differ.

`Info.lcl` carries a commented-out C declaration of an earlier version of this
struct (`char szName[24]; BYTE byCost; BYTE byCON; BYTE byLW; BYTE byHW; BYTE
byTS; BYTE byMS; BYTE byLSHP;`). The field *names* match; the offsets do not —
the shipped layout has a 30-byte name at +0x02. Trust the offsets above.

Shipped ids: 0, 1, 3..19. Id 2 is missing.

### What the engine does with each item

The record carries no behaviour column: an item's effect is hard-coded against
its **id**, which the engine reads as `unit[+0x21 + id]` in the carried-equipment
bitmap ([`10` §5.4](10-lev-mission-format.md)). Fifteen ids have a decoded
effect; the pairing is exact in every case, in that the shipped name and the
coded effect agree.

Three of them — 17, 18 and 19 — carry **tech 99**, and no shipped `.lev`
header sets a tech level above 12, so those three can never be bought: each
exists only as a pickup off the map ([`26` §3.1](26-interaction.md)). Id 9,
`Explosion Pack`, is both — tech 9, reachable on eleven maps, and also a
pickup.

| id | Name | Effect | Code |
| --- | --- | --- | --- |
| 0 | `Scan Module` | reveals units without line of sight within `distance < 6`, as a contact only | `0x004794B0` |
| 1 | `Long Range Scan` | the same to `distance < 8`; fully reveals inside 6 | `0x004794B0` |
| 3 | `Light Stimulant` | sets `unit[+0x58] = 1` | `0x00475320` |
| 4 | `Heavy Stimulant` | sets `unit[+0x58] = 2` | `0x00475320` |
| 5 | `Target System` | doubles the weapon's hit quote, capped at 100 | `0x004752E0` |
| 6 | `Ammo Pack` | **doubles the magazine** — `aGetMaxAmmo` returns the weapon's `mun` column shifted left by one while it is carried | `0x004752A0` |
| 7 | `Jet Pack` | **warping** — `0x00475380` returns a range of 5 while the unit has movement points left, which `0x00430EE0` turns into the `0x3C` overlay. `Info.lcl` annotates the line itself `* warp & scan`; 5 of the 1863 placed units carry it | `0x00475380`, [`10` §4.5](10-lev-mission-format.md) |
| 8 | `Banner` | doubles the hit chance of **every friendly unit within `distance < 4`** | `0x0046FAD0` |
| 9 | `Explosion Pack` | enables weapon `special` 2 on a neighbour (`0x0046F7E0`), and is what **demolishes an entry point**, action point 70 ([`26` §2](26-interaction.md)) | `0x0046F7E0`, `0x0047B410` |
| 10–13 | the four armours | raise the cached front/rear armour `unit[+0x36]`/`+0x37` | `0x00475490`, `0x004754F0` |
| 15 | `Small Medic Kit` | **heal power 1** — the heal command restores that many hit points, to the target in front or to the carrier, and the kit is **not consumed** | `0x004753C0`, `0x00470890` |
| 16 | `Large Medic Kit` | the same, **heal power 3**; the larger kit wins when both are carried | `0x004753C0` |
| 17 | `Hydraulic Crowbar` | **the key to jammed doors** — without it action point 33 is not offered at all ([`26` §2](26-interaction.md)) | `0x0047A5D2` |
| 18 | `Damage Absorber` | four charges in `unit[+0x3A]`; each spent charge nullifies one hit entirely | `0x00475590`, `0x004755B0` |
| 19 | `Cooler` | doubles the weapon's heat cap — which also widens the overheat roll | `0x00475340` |

[`22`](22-combat-and-visibility.md) works through the combat ones.

---

## 4. `SetWeaponInfo` / `SetWeaponInfo2` — weapons

Both write the same 67-byte record at `0x0051b2c0 + id*67`. `SetWeaponInfo`
creates it; `SetWeaponInfo2` fills in five more fields.

```
SetWeaponInfo (id, "Name", rangeMin, rangeMax, hit, dmg, defMod,
               LW, HW, TS, CON, ap, type, tech, mun, heat, cost,
               special, param);
SetWeaponInfo2 (id, "WaveName", toggle, munPerFight, icon, "key");
```

`Info.lcl`'s headers:

```
*                          Range   Hit Dmg Def LW.HW.TS.CON  Tech      Cost  Param
*        n  Name           min-max (%)     Mod Skills     AP Type  Mun Heat  Special
SetWeaponInfo ( 0, "Light Combat Gun", 1,10, 3, 2, 1, 0,0,0,0, 1, 1, 0, 7, 2, 10, 0, 0);

*        n     WaveName    Weapon  Mun/  Icon  Key
*                          Toggle  Fight
SetWeaponInfo2 (0, "W_LCG_0", 0,   1,    0,    "A");
```

### Record layout

| Offset | Size | Cmd | Argument | Field | Status |
| --- | --- | --- | --- | --- | --- |
| +0x00 | 1 | 1 | — | in-use flag, set to 1 | confirmed |
| +0x01 | 36 | 1 | 2 (`str[0]`) | display name | confirmed (GUI text 120) |
| +0x25 | 9 | 2 | 2 (`str[0]`) | **wave name** — `"%s.wav"` sound file | confirmed (`wsprintf("%s.wav", &weapon[+0x25])` in `0x0040bd70`) |
| +0x2e | 1 | 1 | 3 (`num[1]`) | **range min** | confirmed (range check in `0x0046a270`; GUI text 124 `"%d-%d"`) |
| +0x2f | 1 | 1 | 4 (`num[2]`) | **range max** | confirmed (same) |
| +0x30 | 1 | 1 | 5 (`num[3]`) | **hit quote** — displayed as *Accuracy* `%d%%`, but it is a rating, not a probability: the chance of hitting is `100 - ((101 - quote) / range max) * distance` | confirmed (GUI text 126, labelled `"Accuracy:"`; consumed by `0x004752E0` and `0x0046A270`, see [`22` §5](22-combat-and-visibility.md)) |
| +0x31 | 1 | 1 | 6 (`num[4]`) | **damage** — the base of the damage roll, scaled to 100/70/50 % by the target-cell marker | confirmed (GUI text 128 `"Damage:"`; value 254 renders as a special string; read by `0x0046B450`, see [`22` §7.2](22-combat-and-visibility.md)) |
| +0x32 | 1 | 1 | 7 (`num[5]`) | **defence-mode flag** — *not* a modifier | settled, see below |
| +0x33 | 1 | 1 | 8 (`num[6]`) | skill **LW** | header only |
| +0x34 | 1 | 1 | 9 (`num[7]`) | skill **HW** | header only |
| +0x35 | 1 | 1 | 10 (`num[8]`) | skill **TS** | header only |
| +0x36 | 1 | 1 | 11 (`num[9]`) | skill **CON** | header only |
| +0x37 | 1 | 1 | 13 (`num[11]`) | **type** 0..4 | confirmed (area-effect checks compare it to 2 and 3 in `0x0046b450`) |
| +0x38 | 1 | 1 | 14 (`num[12]`) | **tech** level | header only |
| +0x39 | 1 | 1 | 15 (`num[13]`) | **mun** — magazine size; `255` means the weapon never consumes ammo, and the subtraction below is skipped | confirmed: a new unit's ammo byte (`unit+0x3d`) is initialised from it (`0x00479cf0`); the `!= 255` guard is in `0x0046B450` |
| +0x3a | 1 | 1 | 16 (`num[14]`) | **heat** — the heat *cap*, doubled by equipment 19 (`Cooler`). `255` disables the mechanic. Reaching it triggers the overheat roll | confirmed (`0x00475340`; see [`10` §5.12](10-lev-mission-format.md) and [`22` §8](22-combat-and-visibility.md)) |
| +0x3b | 1 | 1 | 18 (`num[16]`) | **special** 0..6; the dispatcher `0x0046F7E0` decodes 1, 3, 4 and 5, `0x0046A270` decodes 6, and only 2 has no shipped carrier — see *`special` 1 is the bayonet* below | confirmed (`== 6` in `0x0046f7e0` and in `0x0046A270`, where it swaps the target cell for unit `+0x51`/`+0x52`; `!= 1` in `0x0042ff30`) |
| +0x3c | 1 | 1 | 12 (`num[10]`) | **AP** — action points per shot | confirmed: subtracted from `unit+0x15` before firing (`0x0040a440`); GUI text 130 `"Action Pts:"` |
| +0x3d | 1 | 2 | 3 (`num[1]`) | **weapon toggle** — the id of this weapon's other firing mode; an involution over all 42 records, 26 fixed points and 8 pairs. `aToggleWeaponModes` (`0x0047a8c0`) is `unit[+0x3f] = weapon[+0x3d]`, and the engine only ever reverts, never toggles into a mode. See [`25` §7](25-turn-and-round.md) | confirmed |
| +0x3e | 1 | 1 | 17 (`num[15]`) | **cost** in equipment points | confirmed (GUI text 122 `"Equipment Pts:"`; compared against the player's points before purchase in `0x00457da0`) |
| +0x3f | 1 | 1 | 19 (`num[17]`) | **param** — replacement weapon id for `special` | confirmed: `unit+0x3f = weapon[+0x3f]` when the special fires (`0x0046f7e0`) |
| +0x40 | 1 | 2 | 6 (`str[1][0]`) | **key** — first character; `'#'` suppresses | confirmed (`0x00432bd0` skips the entry when it is `'#'`) |
| +0x41 | 1 | 2 | 4 (`num[2]`) | **mun per fight** — ammo consumed per attack, unless `mun` is 255 or the attacker's unit type is `0x42` | confirmed: `unit[0x3d] -= weapon[0x41]` after an attack (`0x0046b450`) |
| +0x42 | 1 | 2 | 5 (`num[3]`) | **icon** index | header only |

The name field is 36 bytes because the wave name starts at +0x25; the shipped
names are all shorter.

### The wave name overruns `range min` for eight shipped weapons

`SetWeaponInfo2` copies `strlen(name) + 1` bytes — the terminating nul
included — to +0x25, and the next field, `range min`, begins at +0x2e. A wave
name of exactly **9** characters therefore puts its nul on +0x2e and zeroes the
`range min` that `SetWeaponInfo` set earlier in the same file. Eight shipped
weapons hit it:

| id | Weapon | Wave name | `range min` in `Info.lcl` | in memory |
| --- | --- | --- | --- | --- |
| 14 | Enhanced Laser Gun | `W_LSRXA_0` | 1 | 0 |
| 17 | Explosives | `explosion` | 1 | 0 |
| 20 | Claws | `AW_CLAW_0` | 1 | 0 |
| 21 | Giant Claws | `AW_CLAW_0` | 1 | 0 |
| 27 | Mega Claws | `AW_CLAW_0` | 1 | 0 |
| 28 | – | `AW_CLAW_0` | 0 | 0 |
| 29 | Shock Weapon | `AW_CLAW_0` | 1 | 0 |
| 47 | Laser Enhanced | `W_LSRXB_0` | 1 | 0 |

The range test is `min <= distance <= max`, so a min of 0 instead of 1 only
changes behaviour at distance 0 — attacking your own tile — which the rest of
the engine forbids anyway. It is invisible in play. It matters only if a remake
loads `Info.lcl` and expects the resulting table to match the file: for these
eight ids it does not. No other string field in any of these tables overflows
(the longest unit description is 17 of 100 bytes, the longest model file name
12 of 13, the longest equipment name 17 of 30, the longest weapon name 22 of
36).

### `Def Mod` (+0x32) is the defence-mode flag — **[code] `0x004753e0`, `0x0040a710`**

The header calls it *Def Mod* and earlier editions of this document could not
make the engine's only test (`== 1 || == 4`) look like a modifier. It is not
one. The field gates **defence mode** — the game's overwatch stance, in which a
unit that ends its turn with action points left holds fire until an enemy comes
into view.

Two sites read it:

* **`0x004753e0(unit)` — "may this unit go into defence mode?"** Requires
  `unit[+0x15] >= 2` (action points), `unit[+0x40] == 0`, `unit[+0x3d] != 0`
  (ammo) and `unit[+0x41] != 1` (not already in defence mode); the return value
  is then `weapon[+0x32] & 1`. It is called from `0x00472570`, `aUI.cpp`'s
  command-availability switch, for UI command id 2 — the **Def** button.
* **`0x0040a710(unit)` — the automatic end-of-turn pass.** `0x00409940` walks
  all 200 units and calls it for every one that still has `>= 2` action points.
  It tests `weapon[+0x32] == 1 || == 4`; on a match it calls `0x00478500`,
  which sets `unit[+0x41] = 1`, bumps a per-player defence-order counter at
  `0x00517f50[player]` and stores that ordinal in `unit[+0x59]`. It also sets
  `unit[+0x39] = 3` and, if the unit was already in state 1, zeroes its action
  points.

`unit[+0x41] == 1` is then what the reaction-fire scan looks for; the ordinal in
`+0x59` orders the reactions, **lowest first**, and only in game mode 1. What
clears the state — and what does not — is [`25` §6](25-turn-and-round.md).

**Shipped values are only 0 and 1.** Weapons with 1 are ids 0, 1, 2, 3, 4, 6,
10, 14, 16 and 29 — the aimed direct-fire guns (combat guns, assault rifle,
sniper rifle, double fire, rapid-fire MG, high-energy laser, enhanced laser,
light plasma gun, shock weapon). Every flamethrower, mine thrower, explosive,
claw and melee weapon has 0. Value 4 is accepted by the automatic pass but not
by the UI eligibility test (`4 & 1 == 0`), and never occurs in the data — so
the two tests only disagree on values the shipped file never uses. A remake
should treat the field as a flag: **non-zero (in practice 1) = this weapon can
be put on overwatch.**

### Enumerations, quoted from `Info.lcl`

`type`:

| Value | Meaning |
| --- | --- |
| 0 | nature (claws, fist, spores, …) |
| 1 | projectile (rifle, machine gun, …) |
| 2 | explosive (grenades, missile, …) |
| 3 | energy (laser, plasma, flame thrower, …) |
| 4 | steel (sword, bayonet, …) |

`special`:

| Value | Meaning |
| --- | --- |
| 0 | normal |
| 1 | weapon changes in close combat into the weapon named by `param` (one-field attackers only) |
| 2 | weapon changes id if a unit with an energy pack stands next to the attacker *(marked untested by the authors)* |
| 3 | after each fight the weapon id is changed |
| 4 | set the defender's player id to the attacker's and zero all its action points |
| 5 | copy the attacked unit into the unit pool if its unit-pool flag is set |
| 6 | attack the defender's position of the last turn |

### `special` 1 is the bayonet — **[code] `0x0046F7E0`**

The dispatcher `aAttackUnit` calls three times, with the **phase** as its
fourth argument: `0` before the shot (`0x0046B5C7`), `2` on each unit the shot
hit (`0x0046BE1C`) and `1` at the very end (`0x0046C325`). Phase 0 owns
`special` 1 and 2, phase 1 owns 1 and 3, phase 2 owns 4 and 5.

```c
/* phase 0, 0x0046F9C1 -- the swap */
if (!target) return;
d = aGetDistance(a->x, a->y, t->x, t->y);      /* 0x0044AE10 */
if (unitInfo[a->type].size == 1) d--;          /* docs/22 §5.1 */
if (unitInfo[t->type].size == 1) d--;
if (d != 1) return;
if (abs(cellA->height - cellT->height) / 160 >= 16) return;
a->weapon = weapon[a->weapon].param;           /* 0x0046FAB1 */

/* phase 1, 0x0046F8E8 -- the revert */
if (a->weapon == 30 || a->weapon == 31 || a->weapon == 32)
    a->weapon = weapon[a->weapon].param;
```

Four consequences, and the first is the one a player notices:

* **the round is not spent.** The revert runs at `0x0046C325`, *after* the
  ammunition subtraction of [`22` §7.5](22-combat-and-visibility.md) — and the
  subtraction reads `unit[+0x3F]`, which is the bayonet, whose `mun` is 255.
  So a stab costs nothing, exactly as the shipped table intends;
* **everything else in the shot is the bayonet's too**: `hit` 100 over
  `range max` 1 (a flat chance), damage 3/3/5, `type` 4, heat cap 255. The
  chance the interface *displayed* before the shot is still the gun's —
  `0x0046A270` is not on this path;
* **the stab is drawn as a stab.** `aAttackUnit` calls `aPlayFightAnimation`
  `0x0040BD70` at `0x0046C186` — *inside* the window, before the subtraction
  and before the revert — so every switch the presentation dispatches on
  `unit[+0x3F]` takes the bayonet's arm: the `F` selector `0x0042E220` answers
  `P0_F1_001` (`PR_F1_001` for the `PR` class) where the gun's key answers an
  `F0`, and `SetWeaponInfo + 0x25` names `W_BAYO_0`, a wave no other weapon
  uses. `charisma_tables.py` enumerates the selector over the whole domain
  and pins both halves — `a stab plays its own clip` names the `F1` family and
  `stabs that change the clip` counts the 108 `(type, player, gun)` triples the
  swap moves;
  `combat_tables.py`'s `close.animation_precedes_the_revert` pins the call's
  position. *(Added 2026-09-09. The remake had read the order the other way
  round and fired a burst at contact range.)*;
* **an empty gun still stabs.** The subtraction reads the bayonet's `mun` of
  255, so the shot costs nothing and there is nothing for an empty magazine to
  refuse. The engine says the same from the other side: its weapon selector
  `0x0042FF30` gives a jammed or empty `special` 1 weapon its `param`
  ([`23` §2](23-ai-turn.md)), which is how a computer unit keeps fighting with
  a spent gun. A remake that gates the player's shot on the **held** weapon's
  magazine — as this one did until 2026-09-09 — refuses exactly the one shot
  such a unit can still make;
* **a reaction never reaches either arm.** `0x0046B592` and `0x0046C319` read
  `aAttackUnit`'s fifth argument, the flag [`25` §6](25-turn-and-round.md)'s
  drain passes as 1, and jump past the call. A unit on overwatch shoots
  whatever walks into the next cell.

The three shipped pairs are 1↔31, 2↔30 and 16↔32; `param` names the partner in
both directions, which is how one field serves both. `combat_tables.py`'s
`close.*` checks pin the call sites, the phases, the gate, the ordering
against the subtraction and all four constants; `test_combat.gd`'s
`close.*` are the model's.

**The executable model is `godot/core/combat.gd` and not `inclib/combat.py`**
([`92` §5.1](92-remake-architecture.md)): the claim is structural, no corpus
run can exercise it — a swap needs two units standing next to each other,
which is runtime state and not a field in any file — and the Python twin is
frozen. What stands behind the rule is the byte pins above and the six shots
of `tests/fixtures/turn/cases_turn.json`, every one of them fired by a
`special` 1 gun from nine fields or more, which is the engine agreeing that
nothing happens at range.

> The row for `+0x3b` above previously called 6 "the one value with a decoded
> effect". Five of the seven are decoded: 1, 3 (phase 1), 4, 5 (phase 2) and 6.
> Only 2 — the energy-pack swap the authors themselves marked untested — has
> no shipped carrier.

`damage`: 0–200 base hit-point damage; **254** forces exactly one hit point of
damage; 255 reserved.

The authors also note: *"Large units need special weapons with a range of 2
fields!!!"*

### Accuracy formula

The `hit` field is not a percentage; it feeds a range-falloff. The combat code (`0x0046a270`) computes, for a shot at distance `d`:

```
accuracy = 100 - ((101 - hit) / rangeMax) * d          (integer division)
```

so a low `hit` with a short `rangeMax` degrades quickly, while the Sniper Rifle
(`hit` 20, `rangeMax` 30) stays accurate far out. The GUI nevertheless prints
the raw field as `"%d%%"` next to the label *Accuracy*. **The formula is read
from the code; the interpretation of `hit` as its parameter is confirmed by the
range check that precedes it in the same function.**

---

## 5. `SetUnitInfo` — units

```
SetUnitInfo (id, "Desc", "FileName", py, mpMax, hpMax, fpMax,
             frontArmour, rearArmour, weapon, special, species,
             exp, size, height, "key");
```

16 arguments. `Info.lcl` header:

```
*     n   Desc   FileName   Py  MP  HP  FP  Front   Rear    Weapon  Special Exp   Height
*                               max max max Armour  Armour  default   Species Size  Key
SetUnitInfo (20, "ComBot", "A_MK_0B.3DI", 0, 5, 20, 255, 10, 5, 12, 0, 3, 30, 1, 70, "X");
```

126-byte record at `0x0051c020 + id*126`:

| Offset | Size | Argument | `num`/`str` | Field | Status |
| --- | --- | --- | --- | --- | --- |
| +0x00 | 1 | 4 | `num[1]` | **py** — owning player | confirmed by the enum below |
| +0x01 | 1 | 5 | `num[2]` | **MP max** — movement points | confirmed: `0x00475160` returns it as the unit's movement allowance, with modifiers (see below) |
| +0x02 | 1 | 6 | `num[3]` | **HP max** — hit points | confirmed: `0x00479ba0`, the type-init routine, sets `unit[+0x16]` from it, and `0x00475240` returns it as the maximum — plus `rank/12`, capped at 15, for anything but the computer player |
| +0x03 | 1 | 7 | `num[4]` | **FP max** — read **only as a flag** | see below |
| +0x04 | 1 | 8 | `num[5]` | **front armour**, 255 = derive from equipment | confirmed: `0x00475490` |
| +0x05 | 1 | 9 | `num[6]` | **rear armour**, 255 = derive from equipment | confirmed: `0x004754f0` |
| +0x06 | 1 | 10 | `num[7]` | **default weapon** id | confirmed: copied into `unit+0x3f` when a unit is created (`0x00479cf0`) |
| +0x07 | 1 | 11 | `num[8]` | **special** 0..16. Four values steer the combat resolver: `12` explodes when hit (`Barrel`, `Parabomb`), `13` is destroyed by any hit (`Case`), `16` explodes when killed (`Bea'Coo`), `10` is immune to all but weapon types 2 and 3 and is carried by nothing shipped. See [`22` §7.3](22-combat-and-visibility.md) | confirmed (`== 0x10` test in the death handler, `0x0040bd70`) |
| +0x08 | 100 | 2 | `str[0]` | **description** — also the default unit name | confirmed: used verbatim when `InsertUnit` is given `""` |
| +0x6c | 13 | 3 | `str[1]` | **model file name** (`.3DI`) | confirmed: `0x00479ba0` passes `&unitinfo[+0x6c]` to `0x004052b0` together with the unit's 3D handle `unit[+0x4b]` |
| +0x79 | 1 | 12 | `num[9]` | **species** — `0` human (9 types), `1` alien (19), `2` inanimate object (6), `3` machine (2). Species 2 is permanently visible and awards no experience ([`22` §9.2](22-combat-and-visibility.md)) | confirmed (compared against 0/1/2/3 throughout, e.g. `0x0040bd70`, `0x00440a20`) |
| +0x7a | 1 | 13 | `num[10]` | **exp** — experience awarded for a kill | confirmed: on a kill `0x0046b450` passes it to `0x0047afd0` / `0x0047b090` / `0x0047b100`, the promotion bookkeeping |
| +0x7b | 1 | 14 | `num[11]` | **size** — 0 small, 1 large; `1` on exactly `ComBot`, `Tr'Yn` and `Al'Coo`. A large unit spills past its own field, so combat subtracts one field of distance per large participant ([`22` §5.1](22-combat-and-visibility.md)) | confirmed (large-unit path checks, e.g. `0x0040bd70`) |
| +0x7c | 1 | 15 | `num[12]` | **height**, in 160-world-unit levels | confirmed: `0x0047ad70` returns `unitinfo[+0x7c] * 0xa0` as the unit's world height and `0x0047ad30` returns `… * 0xa0 / 2 + 800` as its aim point; shipped values 4 (Spider) … 100 (Norc'Yn), 18 for a human. Line of sight uses the first for vision and the second for fire ([`22` §6](22-combat-and-visibility.md)) |
| +0x7d | 1 | 16 | `str[2][0]` | **key** — first character | header only |

#### Column 11, `special`, is an enumerator with a single dispatcher — **[code] `0x0046F210`**

`+0x07` is not a flag but a small enumerator, and almost all of it goes through
one hook:

```c
BOOL specialHook(Unit *u, Unit *other, int phase);      /* 0x0046F210 */
```

which returns immediately when the type's `special` is 0 and otherwise switches
on a *phase* supplied by the caller. The binary contains exactly six calls to
it, and each pushes its phase as a literal, so all six are read off rather than
inferred:

| Phase | Caller | When |
| --- | --- | --- |
| 0 | `aAttackUnit` `0x0046B96D` | the attacker, before its shot is marked out |
| 1 | `aAttackUnit` `0x0046C332` | the attacker, after the shot — **no case handles it** |
| 2 | `0x0042FF30` | building the weapon list, i.e. "may this unit attack" |
| 3 | `aExecuteMove` `0x0046EE3F` | after a move completes |
| 4 | `aPlayFightAnimation` `0x0040DA52` | the target, as damage lands |
| 5 | `0x004759B0` | the per-turn stat refresh |

Four more values are handled outside the hook, in `aBuildMoveMap`
(`0x00430A40`), the combat resolver (`0x0046B450`) and `aExecuteBomb`.
All seventeen values, with the shipped carriers:

| `special` | Shipped carriers | Effect | Where |
| --- | --- | --- | --- |
| 0 | 21 types | nothing | — |
| 1 | `Cy'Coo` | zeroes its own cached armour `+0x36`/`+0x37` when it attacks, **and cannot move** — `aBuildMoveMap` returns an empty map for it | phase 0; `0x00430A64` |
| 2 | `Ee'Ther` | **HP restored to the type maximum every turn** | phase 5 |
| 3 | *none* | spawns up to four units of the **next** type id on its four orthogonal neighbours, each gated by its own random draw | phase 3 |
| 4 | *none* | may attack only while its per-turn counter `unit[+0x50]` is 2 or less | phase 2 |
| 5 | *none* | no handler | — |
| 6 | `Tr'Yn` | places three units of type `0x34` around itself every turn, at offsets picked from its facing — the extra body cells of a unit bigger than one field | phase 5 |
| 7 | *none* | morphs into the next unit type (`aChangeUnitInfo(type + 1)`) | phase 3 |
| 8 | *none* | morphs into the previous unit type | phase 3 |
| 9 | `Squee'Coo` | below 6 HP and **hit but not killed** by a weapon of type 1, 2 or 4: removed and replaced by a neutral unit of type `0x36` that inherits its AI group, and the fog is then rebuilt for the current player. Phase 4's caller sweeps cells marked `0x5C`, so a kill (`0x5D`) and a shielded cell (`0x5B`) both miss it; `aGenerateUnitElement` is called with its `exact` flag set, so the replacement takes the carrier's own cell or none. See [`22` §9.4](22-combat-and-visibility.md) | phase 4 |
| 10 | *none* | immune unless the weapon's type is 2 or 3 | `0x0046B450` |
| 11 | *none* | no handler | — |
| 12 | `Barrel` x3, `Parabomb` | **explodes when hit** — damage forced to 255 and the eight neighbours marked for a secondary blast | `0x0046B450`, `aExecuteBomb`, `aPlayFightAnimation` |
| 13 | `Case` | destroyed by any hit — damage forced to 255 | `0x0046B450`, `aPlayFightAnimation` |
| 14 | `War'Coo`, `Norc'Yn` x3 | **cannot move** — `aBuildMoveMap` returns an empty map | `0x00430A70` |
| 15 | `Ray'Coo` | **can warp**: `0x00430EE0` marks every free, walkable field within distance 7 with cell state `0x3C`, the warp overlay of [`10` §4.5](10-lev-mission-format.md). Equipment id 7, the `Jet Pack`, is the other way to reach the same code, at range 5 | `0x00430E5C` |
| 16 | `Bea'Coo` | **explodes when killed** — the eight neighbours are marked for a secondary blast | `0x0046B450`, `0x0040DCCD` |

Seven values (3, 4, 5, 7, 8, 10, 11) are implemented and unused: no shipped
`SetUnitInfo` line carries them, so a remake needs them only for mod
compatibility. Phase 1 is the reverse case — a call site with no handler.

The values have **no names**: this is a hand-written `switch` on an integer
literal in three separate modules, and neither binary contains a matching
string. [`22` §7.3](22-combat-and-visibility.md) works through the combat ones.

#### Column 7, `FP max`, is a flag — **[code] `0x00475120`**

```
unsigned getMaxFP(unit) {
    if (unitinfo[type].fpMax == 255) return 255;       // no fitness system
    fp = unit[+0x17] / 12;                             // rank, from EP at +0x17
    return fp < 3 ? 3 : fp;
}
```

The stored number is **never used as a value** — only the test against 255
matters. The shipped file sets it to **0 for every human unit** (ids 0–3, 21,
22, 23, 26) and **255 for everything else**, so aliens, machines and objects
have no fitness and humans get `max(3, rank/12)`.

The runtime counter it bounds is `unit[+0x19]`. `0x004781c0`, the start-of-turn
refresh, tops it up by +1 normally, +2 when `0x0046fad0` finds a friendly
`Banner` carrier (equipment 8) within four fields, and one more on top if the
unit stood down last turn — clamping to the maximum, so at most +3 in a turn
([`25` §5](25-turn-and-round.md)). `0x00475160` then overrides the unit's
movement points from it — **0 → MP 1, 1 → MP 2**, otherwise the type's MP with
modifiers. It is the "exhausted soldier moves slower" mechanic.

> An earlier revision of this paragraph read `0x0046fad0` as "an enemy is
> adjacent". It is the Banner test — same player, alive, equipment 8, distance
> under 4 — which is what [`10` §5.5](10-lev-mission-format.md) already said.

#### Columns 8 and 9: armour with an escape value — **[code] `0x00475490`, `0x004754f0`**

A stored 255 means "this unit type has no innate armour; derive it from what
the soldier is wearing". Both routines then look at four equipment flags on the
unit record:

| Condition | front (`0x00475490`) | rear (`0x004754f0`) |
| --- | --- | --- |
| `unit[+0x2e] == 1` | 6 | 4 |
| `unit[+0x2c] == 1` | 4 | 2 |
| `unit[+0x2d] == 1` | 5 | **0** |
| `unit[+0x2b] == 1` | 3 | 2 |
| none of the above | 0 | 0 |

(The tests are in that order and the first match wins.) The rear value of 0 for
`+0x2d` is what the code says; it is either deliberate — a piece of equipment
that armours only the front — or an oversight. Recorded as observed.

The results are cached in the unit record at `unit[+0x36]` (front) and
`unit[+0x37]` (rear) when the unit is created and whenever its equipment
changes. Every alien and machine in `Info.lcl` carries fixed numbers here
(`Ray'Ther` 0/0, `Gore'Ther` 100/0, `Tr'Yn` 9/1, …); every human carries
255/255.

`py` values, from `Info.lcl`:

| Value | Meaning |
| --- | --- |
| 0..3 | human players 1..4 |
| 252 | destroyable equipment (explosive barrels, crates, …) |
| 254 | invalid player |
| 255 | computer AI |

`species` (confirmed by the shipped values and by the engine's use of it):
0 = human, 1 = alien, 2 = inert object, 3 = machine. `UnitOnField` matches only
species 0 and 1; `MechOnField` matches only species 3.

`special`, quoted from `Info.lcl` (the authors' `(x)`/`(_)` marks tested versus
untested):

| Value | Meaning |
| --- | --- |
| 0 | normal |
| 1 | loses armour during a fight + no movement |
| 2 | refresh all hit points after a turn |
| 3 | produces new units when it moves, with the producer's id + 1 (50 % chance) |
| 4 | target delay time |
| 5 | frees "thousands of sweet little aliens" when it dies *(untested)* |
| 6 | produces new units (type Dec'Ther) after a turn |
| 7 | increments its id after moving |
| 8 | decrements its id after moving |
| 9 | sets its id to 54 when it first loses hit points (angry alien); projectile, steel and explosive weapons only |
| 10 | can only be destroyed by weapons of type 2 and 3 (explosive and energy) |
| 11 | jumps randomly across its possible move area *(untested)* |
| 12 | killed by the first attack, and attacks the neighbouring fields |
| 13 | killed by the first attack |
| 14 | no movement |
| 15 | bounce bounce |
| 16 | attacks neighbouring fields when dying |

Cross-checks that fix the field order beyond doubt:

* `ComBot` (id 20) has `weapon = 12`, and weapon 12 is `"Combot Weapon"`.
* `Ray'Ther` (id 50) has `weapon = 20` = `"Claws"`; `Tr'Yn` (58) has 27 =
  `"Mega Claws (Tr'Yn)"`; `Squee'Coo` (57) has 23 = `"Sting Thrower"`.
* `Squee'Coo` has `special = 9` — "set id to 54 when it first loses hit
  points" — and unit 54 is `Squee'Ther`.
* `Barrel`/`Parabomb` (30/31) have `special = 12`, `Case` (32) has 13, and
  `Norc'Yn` (61) has `special = 14` with `MP max = 0`.

---

## 6. `SetVolumeCtrl` — per-sound volume — settled

```
SetVolumeCtrl (index, volume);
```

`int32[121]` at `0x00504638`; index 0..120, out of range hits the
`invalid volume ctrl id` path (`0x00437500`) and the statement is dropped.

### How the index reaches a sound

`SetVolumeCtrl` only writes the table. The **reader** is `0x00437480`, called
from the sound-buffer loader `0x00436b60`. That loader's signature is

```
aDirectSoundLoadSoundBuffer(&handleOut, "file.wav", flags, baseAttenuation, volumeCtrlId)
```

— the **fifth argument is the volume-control index**, and every call site in
the engine passes a literal. `0x00437480` turns the stored percentage into a
DirectSound attenuation:

```
attenuation = volume * 20 - 2000 + baseAttenuation
```

so 100 means "no attenuation beyond the player's master setting", which is why
almost every shipped entry is 100. A `volumeCtrlId` of `-1` means "not volume
controlled" and is what the GUI click sounds, the speech player
(`0x0047bb89`) and a few one-offs pass.

### The index space

`Info.lcl` documents it in its own comments, and a sweep of all 62 call sites of
the loader wrapper `0x004176c0` plus the 18 direct calls to `0x00436b60`
confirms the mapping exactly. Two ranges:

* **0 … 50 — weapon sounds, indexed by weapon id.** `0x0040c7f8` (in the fire
  handler `0x0040bd70`) formats `"%s.wav"` from `weapon[+0x25]`, the wave name
  `SetWeaponInfo2` stores, and passes the **weapon id itself** as the volume
  index. That is what `Info.lcl`'s `* see weapons` comment on entry 0 means.
* **50 … 102 — named sounds**, one index per effect.

Every index the code was observed to use, with the wave file and `Info.lcl`'s
own label:

| Index | Wave file(s) seen in code | `Info.lcl` comment |
| --- | --- | --- |
| 0–49 | *(weapon wave names, by weapon id)* | `see weapons` |
| 50–58 | `SP_HUM_0.wav` (50) | `SP_HUM_0/1/2`, `S_HUM_0/1/2` |
| 59, 60, 61 | `S_ALI_0.wav`, `S_ALI_1.wav`, `S_ALI_2.wav` | same |
| 62 | — | `mhuman.wav` human walk |
| 63 | `explosion.wav` | `explosion.wav` |
| 64 | `jammed.wav` | `jammed.wav` |
| 65 | `damage.wav` | `damaged.wav` |
| 66 | `box.wav` | `box.wav` |
| 67 | `door.wav` | `door.wav` |
| 68 | `lever.wav` | `lever.wav` |
| 69 | `jump.wav` | `jump.wav` |
| 70 | `drop.wav` | `drop.wav` |
| 71 | `tube.wav`, `planttube.wav` | `tube.wav` |
| 72 | `air_current.wav` | `air_current.wav` |
| 73 | `skill.wav` | `skill.wav` |
| 74 | `platform.wav`, `stone.wav`, `firecircle.wav` | `platform.wav` |
| 75 | `platform2.wav` | `platform2.wav` |
| 76 | `elevator.wav` | `elevator.wav` |
| 77 | `elevator2.wav` | `elevator2.wav` |
| 78 | `bridge2.wav` | `bridge.wav` |
| 79 | `drawbridge.wav` | `drawbridge.wav` |
| 80 | `ricochet.wav` | `ricochet.wav` |
| 81 | `explosion2.wav` | `explosion2.wav` |
| 82 | `crush.wav` | `crush.wav` |
| 83 | `alien_scream.wav` | `alien_scream.wav` |
| 84 | `stonefire.wav`, `gfire.wav` | `gfire.wav` |
| 85 | `heal.wav` | `heal.wav` |
| 86 | `crushwall.wav` | `crushwall.wav` |
| 87 | `bomber.wav` | `crushwall.wav` bomber |
| 88 | `bomber.wav` | `crushwall.wav` push barrel |
| 89 | `crush.wav` | `crush.wav` exploding para bomb |
| 90–93 | — | `mcombot`, `mdecther`, `malien`, `msqueether` walk loops |
| 94 | `mine.wav` | `mine.wav` defuse mine |
| 95 | `aexplosion.wav` | `aexplosion.wav` acid explosion |
| 96 | `click_1/2/5.wav`, `select.wav`, `textbeep.wav` | gui-sounds |
| 97 | `teleport.wav` | teleporter start |
| 98 | `teleport2.wav` | teleporter end |
| 99 | `msqueether.wav` | spore splash |
| 100 | `bridge2.wav` | stone bridge |
| 101 | `lbarrier.wav` | laser barrier |
| 102 | `moveland.wav` | move land |

Indices 103–120 exist in the array but no shipped entry sets them and no call
site uses them.

### Not every shipped entry is 100

An earlier edition of this document said all 103 shipped entries set volume
100. They do not — seven are deliberately different:

| Index | Volume | `Info.lcl` label |
| --- | --- | --- |
| 62 | 50 | human walk |
| 90 | 80 | combot walk |
| 91, 92, 93 | 50 | decther / alien / squee'ther walk |
| 96 | 70 | gui-sounds |
| 102 | 101 | move land |

The movement loops are quieted and the GUI is quieted; 102's `101` is a
one-over-nominal value, which the attenuation formula turns into +20 hundredths
of a dB — almost certainly a typo for 100, and inaudible either way.

---

## 7. `SetCharismaInfo` — six names, and nothing reads them

```
SetCharismaInfo (id, "s0", "s1", "s2", "s3", "s4", "s5");
```

Never used by shipped data. The loader `0x00441780` bounds-checks `id` to
0..100 and copies the six string arguments into a 120-byte record at
`0x00518368 + id*120`, at +0x00, +0x14, +0x28, +0x3c, +0x50 and +0x64 (20 bytes
each, `strcpy`, so a name longer than 19 characters overruns the next field the
way `SetWeaponInfo2`'s wave name does, §4).

**Nothing in either shipped binary reads that table.** The editor has now been
traced, so this is closed as a double negative rather than deferred.

*`Incubation.exe`.* The 101 records span `0x00518368 … 0x0051b2c0` — and
`0x0051b2c0` is exactly where the next table (`SetWeaponInfo`'s) begins, which
independently confirms the extent. Scanning the whole image for a 32-bit
little-endian operand pointing anywhere into that span yields **six** code
operands, all of them the `lea`s that address the six `strcpy` destinations
inside `0x00441780` itself: `0x004417b4` (+0x00), `0x004417c3` (+0x14),
`0x004417eb` (+0x28), `0x00441810` (+0x3c), `0x00441838` (+0x50), `0x0044184a`
(+0x64). Every other match in the image is a false positive — bytes inside a
`call rel32` displacement (`0x0048666c`, `0x0048ea45`) or a `.data` constant.

*`iDesigner.exe`.* The editor implements the **same command with the same
record shape**: dispatcher arm at `0x00427431`, handler `0x00424710`, `id`
bounds-checked to 0..100, six 20-byte names copied by inline `strcpy` into
`0x004c8ed8 + id*0x78`. The identical whole-image operand scan over
`0x004c8ed8 … 0x004cbe30` again yields exactly **six** hits, all inside
`0x00424710`: `0x00424744`, `0x00424753`, `0x0042477b`, `0x004247a0`,
`0x004247c8`, `0x004247da`. So the editor writes the table and never reads it
either.

*No label anywhere.* `charisma` (case-insensitive) was swept over both binaries
in **ASCII and UTF-16LE**, over all 16 dialog templates and the menu
resource (`python3 tools/pe_resources.py <exe> --dialogs --grep charisma`), and over
all 176 decoded `.lcl`/`.gcl` files. The only hits are the middleware's own
identifiers (`InitCharisma`, `aPrepareCharismaModels`, `CHARISMA - CreateModel`,
the `StdCharisma::…` C++ RTTI and error strings), the LCL keyword itself, and
one credits line (`Txtmod_a.lcl` string 179, *"Charisma 3D Animation System"*).
Nothing names a field.

**Closure: authored but dead in both shipped binaries.** The record is written
by two independent 1998 builds and read by neither; no shipped `.lcl` calls the
command, so there is no corpus evidence either. The six roles are not
recoverable from the shipped product and **no name is invented for them**. A
remake can ignore the command entirely — parse it, bounds-check `id`, discard.

What the shipped engine *does* use for Charisma is a different mechanism: the
one-byte speech-set id at `unit[+0x55]`, written by `LinkChrWithGroup` and
switched on at `0x0047b896` to pick a directory and file prefix under
`Waves/Speech/`. See `docs/20-lcl-language.md` §7.4.

---

## 8. Related runtime record layouts

Recovered incidentally, and useful for a remake. All offsets confirmed from the
LCL command implementations.

### Map cell — **stride `0x17` (23 bytes)**; `GetCellPtr(x,y)` is `0x0042f730`

The array base is `0x0042f650` and the element count `0x0042f660`; the several
commands that scan the whole map (`Spores`, `Statue2`, `FootBridge2`,
`GrowingLand`, `MoveObjects` and friends — `docs/20` §7.4) walk it with a
stride of `0x17`, which is what fixes the record size.

| Offset | Size | Field | Evidence |
| --- | --- | --- | --- |
| +0x00 | 1 | **cell state / overlay** | `0x0046ef50` sets it to 1 on the source cell of a jump move; the AI's move dispatcher compares it against `0x3c` (`0x0040abc7`) to choose walk vs jump. Every band it takes is tabulated in [`23` §10](23-ai-system.md) |
| +0x01 | 4 | height, in units of 160 (`0xa0`) per level | `GetHeight` divides by 160, `SetHeight` multiplies |
| +0x05 | 2 | object/element index | `SetHeight` uses it to update a second record; `0x00404c40` resolves it |
| +0x07 | 2 | unit index, `0xffff` = empty | `NoUnitOnField`, `UnitOnField` |
| +0x09 | 1 | **the cell's own x** | every whole-map scan reads it instead of computing it (`0x0046fc30`, `0x0046ff20`, `0x00413500`) |
| +0x0a | 1 | **the cell's own y** | same |
| +0x0b | 1 | **action point** (`ActPt`) | `GetActPt`/`SetActPt`. `Incubation.exe` carries the developers' names for 38 of its values and the engine hard-codes ten — `31` is *standard Door — CLOSED*, which the AI's `0x0040A600` opens; `71` is *destroyed entry point*, which is why `InsertUnit` refuses it; `80`–`89` are the multiplayer victory points, which refuse a warp target. Full legend: [`10` §4.6](10-lev-mission-format.md) |
| +0x0c | 1 | **scratch, two uses** | the damage this cell's unit just took ([`22` §2.2](22-combat-and-visibility.md)); and, while a move map is up, the **movement points left on arrival** — `aBuildMoveMap` writes it and `0x004305E0` climbs the gradient back to the mover ([`23` §7](23-ai-system.md)) |
| +0x0d | 1 | control-map type | `GetCtrlMapType`/`SetCtrlMapType` |
| +0x0f, +0x10 | 1+1 | a transient obstacle — object slot and **kind** (`0xff` = none) | `Platform` and `GrowingLand` move/clear them via `0x00404c00` / `0x00406960`. The kind is `1` burning ground (`A_FIRE1/2/3.3DI`), `2` a mine (`A_MINE.3DI`), `3` a shield (`A_SHILD.3DI`), named by the models their three makers insert; `aBuildMoveMap` then refuses to move a unit standing in a shield, refuses entry into fire, and refuses entry into a mine unless the mover's player is `255`. `0xff` in every shipped cell because the byte is created during play. See [`23` §7.1](23-ai-system.md) |
| +0x13 | 1 | unknown, `0xff` = free | `SetGroundFire` refuses a cell whose `+0x13` is not `0xff` |
| +0x14 | 1 | unknown, `0xff` = free | `MoveObjects`/`GrowingLand` require it |

`ActPt` doubles as the scripts' general-purpose per-tile store *outside* the 38
values the engine's own legend names ([`10` §4.6](10-lev-mission-format.md)).
Value `71` (`'G'`) is special to the engine: `InsertUnit` refuses to spawn on a
cell whose `ActPt` is 71 — the legend calls it *destroyed entry point*, which is
exactly the refusal. Control-map type **4** (`Deep Hole`) is what `Platform`,
`FootBridge`, `FootBridge2` and `GroundUnit` write into a cell they have
emptied, and **2** (`Wall`) is what `FallingSpores` and `GrowingLand` write
into one they have filled.

### Unit — record stride `0x5b`, up to 200 units; `GetUnitPtr(i)` is `0x00477ae0`

The whole record is built on the stack by `0x00479cf0` (the spawn routine both
`InsertUnit` and `InsertUnitWithGroup` call) and then copied into the array, so
the offsets below are all readable from that one function plus the accessors
that later use them.

| Offset | Size | Field | Evidence |
| --- | --- | --- | --- |
| +0x00 | ~22 | name | `0x00479cf0` copies the caller's string, or the unit type's description (`unitinfo[+0x08]`) when it is empty |
| +0x15 | 1 | remaining action points | weapon AP is subtracted from it (`0x0040a440`); zeroed by several set pieces |
| +0x16 | 1 | **current hit points** | `0x00479ba0` sets it from `unitinfo[+0x02]` (HP max); "is this unit alive" tests throughout are just `!= 0` |
| +0x17 | 1 | **experience points**; rank = `EP / 12` | `0x00475120` (`unit[+0x17] / 0xC`, floored at 3) and `0x00475240` (max HP = type HP + `unit[+0x17]/12`, capped at 15). `0x00479cf0` seeds it with `rank * 12` from `InsertUnit`'s fourth argument |
| +0x18 | 1 | **skill-point pool, in twelfths** — *not* the rank | `0x004755D0` spends it: `unit[+0x18] -= 12 * pointsNeeded`, alongside the equipment write `unit[0x21 + equipId] = 1`. `0x00479cf0` seeds it with the same `rank * 12`, so a recruit starts with one skill point per rank to spend |
| +0x19 | 1 | **fitness points** | bounded by `0x00475120` (see §5, column 7); `0x004781c0` regenerates +1 or +2 per turn; `0x00475160` forces MP to 1 at value 0 and to 2 at value 1 |
| +0x1a … +0x1f | 6 | skills **CON, LW, HW, TS, MS, LS** | `0x0047a6e0` raises them to the maximum of their current value and the equipment record's `+0x23 … +0x28` (§3), accumulating the delta that `0x004755d0` charges to `+0x18` |
| +0x21 … +0x35 | 21 | **equipment carried**, one byte per `SetEquipInfo` id 0..20 | `0x004755d0` toggles `unit[0x21 + equipId]`; the four armour flags fall out as `+0x2b` = Light Armor (id 10), `+0x2c` = Standard Armor (11), `+0x2d` = Attack Armor (12), `+0x2e` = Heavy Armor (13) |
| +0x36 | 1 | **effective front armour** | cached from `0x00475490` (§5, columns 8/9) |
| +0x37 | 1 | **effective rear armour** | cached from `0x004754f0` |
| +0x3d | 1 | ammo | initialised from weapon `mun`, decremented by `mun per fight` |
| +0x3f | 1 | current weapon id | initialised from the unit type's default weapon (`unitinfo[+0x06]`) |
| +0x41 | 1 | **action state** | `1` = a reaction is pending (`0x00478500`, which also stamps the reaction ticket `+0x59`); `7` = **stood down without acting** — `0x00478570` sets it *and* zeroes MP, and the turn refresh `0x004781C0` rewards it with `+0x57 = 1` (one extra MP next turn). `5`/`6` suppress movement entirely (`0x00475160`) |
| +0x42 | 1 | x | area scans |
| +0x43 | 1 | y | area scans |
| +0x45 | 1 | player | `UnitOnField`, `InsertUnit` |
| +0x47 | 1 | **primary AI order**, 0…10 | the AI turn loop `0x00409940` switches on it (`cmp eax, 0xa` at `0x00409a0b`, jump table at `0x0040a37c`); `NewCommands` writes it (`0x0047a850`). The names come from the editor's list box — see `docs/10-lev-mission-format.md` §5.6 |
| +0x48 | 1 | **primary order parameter** | loaded into the switch's companion register at `0x00409a01` and handed to the order handlers; `0x0040b210` reads it as a group id for order 4, `0x0040a6e0` as a wait countdown |
| +0x49 | 1 | **secondary AI order** | `0x0040a6e0` and `0x00409940`'s order-4 fallback copy `+0x49`/`+0x4a` over `+0x47`/`+0x48` when the primary order expires |
| +0x4a | 1 | **secondary order parameter** | same |
| +0x4b | 1 | 3D model instance handle | `0x00479ba0` passes it to `0x004052b0` together with `unitinfo[+0x6c]`, the `.3DI` name; every animation routine moves the unit through it |
| +0x4c | 1 | unit type id (index into the `SetUnitInfo` table) | every `unitinfo[type*0x7e]` access |
| +0x4d | 1 | **unit-pool flag** — `InsertUnit`'s fifth argument | non-zero means this unit may be captured into the player's unit pool: weapon `special` 5 (`0x0046f7e0`) and the two capture paths `0x00478f20` and `0x00463380` all test it before calling `0x00478c10`. `0` at all 413 shipped call sites |
| +0x4e | 1 | group id | `InsertUnitWithGroup` writes it, `GetUnitsInGroup` and `GroupOnField` read it |
| +0x51, +0x52 | 2 | the unit's x/y **at the start of the turn** | `0x004781c0` copies `+0x42`/`+0x43` into them each turn; weapon `special` 6 ("attack the defender's position of the last turn") reads them |
| +0x55 | 1 | **speech-set id** | written by `LinkChrWithGroup`; selects the `Waves/Speech/<n>/<PREFIX>` set — see `docs/20-lcl-language.md` §7.4 |
| +0x59 | 1 | defence-order ordinal | `0x00478500` stores the per-player counter `0x00517f50[player]` here when the unit enters defence mode, which orders reaction fire |

---

## 9. Open questions

**None.** Every column of all five `Set*Info` commands is recovered and checked
against the corpus by `tools/info_parse.py --check`, and the four this document
once carried as UNVERIFIED are closed in place above: column 7 (`FP max`) is a
flag rather than a value (§5), `SetVolumeCtrl`'s index space is settled (§6),
`SetCharismaInfo`'s six names are read by nothing (§7), and the runtime record
offsets in §8 all have a reader named beside them.

This section exists so the zero is explicit. `CLAUDE.md` states that every
numbered document ends with an **Open questions** section and tallies what is
left across the set; a document with nothing open and no section is
indistinguishable from one that was never asked, and it was silently skipped by
the tally for exactly that reason.

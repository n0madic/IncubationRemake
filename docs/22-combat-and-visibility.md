# Combat, line of sight, and visibility

How a shot is resolved and what a unit can see. This is the first document in
the set that describes **behaviour** rather than a file format: nothing here is
stored on disk, but every input is — the game-balance tables in
[`21`](21-info-lcl-schema.md), the unit and cell records in
[`10`](10-lev-mission-format.md) — and a remake that loads all of those still
cannot fire a shot without what follows.

Everything is recovered from `Incubation.exe`. Source module
`C:\aProject\Project\Sources\Game\GameTools\aTacTools.cpp` owns the combat
half, `aUnitMap.cpp` the visibility half.

`tools/combat_tables.py --check gog_incubation` decodes the static tables and
checks the derived arithmetic; `tools/trace_names.py` recovers the function
names §1 relies on.

---

## 1. Reading the binary: the trace-macro convention

Blue Byte's error macro survives in the release build as three pushes and a
call to a **stub**:

```
0x0046b5f2   call 0x46d1b0                     ; the thing being checked
0x0046b5fa   test eax, eax
0x0046b5fc   jne  ok
0x0046b5fe   push "…\GameTools\aTacTools.cpp"  ; __FILE__
0x0046b603   push 1623                         ; __LINE__
0x0046b608   push "aCheckWeaponDamage"         ; a hand-written name
0x0046b60d   call 0x453e00                     ; -> `ret`, nothing else
```

`0x00453E00` is a single `ret`: the reporter was compiled out, its arguments
were not. A four-argument form adds a message and a `printf` template
(`"%s\n\n  Line %d\n  File %s"`), which is how `"LOS building failed"` and
`"incorrect ai level!"` reach the binary.

**The name is the callee's, not the enclosing function's.** The decisive case
is `0x0040104B`, which pushes `LoadLibrary` — a Win32 import, not a Blue Byte
function. Sweeping the pattern over `.text` and pairing each site with the
`call` it guards names **324 functions** in `Incubation.exe` and 146 in
`iDesigner.exe`:

```
call X ; [add esp,imm] ; test eax,eax ; jcc  ->  push FILE; push LINE; push NAME
```

`tools/trace_names.py` performs the sweep. Two consequences:

- **`izz` + `axt` finds the *caller*, not the function.** `aCheckLineOfSight`
  is pushed seven times inside `0x0046C460` — but `0x0046C460` is
  `aCheckLineOfSightEx`, which *calls* `aCheckLineOfSight` (`0x0046C720`)
  seven times. Every combat address this project had attributed from a trace
  string was one call too high.
- **The name is hand-written, so it is sometimes wrong.** `0x0046EF50` is
  called `aExecuteWarp` at `aAISystem.cpp:2168` and `aExecuteMove` at
  `aUI.cpp:3375`; `0x0042F730` collects `aGetCtrlMapElementPtr` (71),
  `aGetCtrlMapElmentPtr` (2), `aGetCtrlElementPtr` (2) and
  `aGetHexMapElementPtr` (1). Majority over the call sites settles all 23
  ambiguous targets; `--all` shows the losing names.

A copy-paste of the **enclosing** function's name also happens, and it is
informative rather than noise. `0x0046CCA0` reports `aExecuteFight` at two
sites where the disassembly shows the failing callee is `0x0046B450`
(`call 0x46b450; je error`), and `0x0046B450` is independently named
`aAttackUnit` from `aUI.cpp:3516`. Combined with the call graph — `0x0046CCA0`
sits in `aTacTools.cpp` beside `aAttackUnit`, calls it, and shares its callers
with `aExecuteMove` and the rest of the `aExecute*` family — `0x0046CCA0` is
`aExecuteFight`.

### 1.1 Names used in this document

| Address | Name | Sites | Role |
|---|---|---|---|
| `0x0046CCA0` | `aExecuteFight` | own-name ×2 | order executor; drives the attack |
| `0x0046B450` | `aAttackUnit` | 1 | one attack: mark, roll, damage, bookkeeping |
| `0x0046A270` | `aGetHitProbability` | 1 (out-of-line) | range, distance, accuracy, LOS -> hit % |
| `0x0046AA10` | — (unnamed) | 0 | marks the cells a weapon covers |
| `0x0046C960` | — (unnamed) | 0 | applies damage to one unit |
| `0x0046C460` | `aCheckLineOfSightEx` | 2 | 1/2/4 rays, takes the best |
| `0x0046C720` | `aCheckLineOfSight` | 7 | one ray |
| `0x0046D400` | — (unnamed) | 0 | ray step setup |
| `0x0046D1B0` | `aCheckWeaponDamage` | 1 | overheat: jam or destroy |
| `0x00479370` | `aSetVisibleStateForUnit` | 8 | writes unit `+0x4F` |
| `0x004794B0` | `aBuildVisibleMapForUnit` | 5 | one observer's view |
| `0x004798C0` | `aBuildVisibleMap` | 9 | the whole player's view |
| `0x0047ABD0` | `aGetGradientsOfUnitView` | 1 | facing -> unit vector |
| `0x004792A0` | `aChangeUnitViewDirection` | 4 | writes unit `+0x46` |
| `0x0042F730` | `aGetCtrlMapElementPtr` | 71 | cell by (x, y) |
| `0x00477AE0` | `aGetUnitMapElementPtr` | 41 | unit by index |
| `0x00463870` | — (`aRandom`) | 0 | the RNG, §3 |
| `0x0044AE10` | — (`aGetDistance`) | 0 | `(int)sqrt(dx²+dy²)` |

`aGetHitProbability` is the one entry the sweep itself does not attribute. The
string is pushed once, at `0x0046B38E`, and the compiler moved that error block
out of line — so it is not textually adjacent to the `call` it belongs to. The
jump into it is unambiguous:

```
0x0046b2f2   call 0x46a270
0x0046b2f7   add  esp, 0x1c        ; 7 arguments
0x0046b2fa   test eax, eax
0x0046b2fc   je   0x46b38e         ; -> push "aGetHitProbability"
```

`tools/trace_names.py` requires adjacency and therefore leaves 506 of 2030
sites unattributed rather than guessing; this is one of them. `add esp, 0x1c`
also fixes the argument count at seven, which is how §5's signature is known.

---

## 2. The tables everything reads

### 2.1 Static bases of the `Info.lcl` tables — **[code] confirmed**

`Info.lcl` is parsed into fixed-stride arrays in `.data`. Every consumer
compiles to `base + id*stride + field`, which pins both the base and the stride
from the *reading* side. Both land exactly on the bases
[`21`](21-info-lcl-schema.md) derived from the *writing* side — the command
handlers — so the two halves of the schema now agree independently:

| Table | Base | Stride | Anchor |
|---|---|---|---|
| `SetWeaponInfo` | `0x0051B2C0` | `0x43` (67) | `[id*0x43 + 0x51B2EE]` and `+0x51B2EF` are the pair the range test compares against, i.e. `+0x2E` *range min* and `+0x2F` *range max* |
| `SetUnitInfo` | `0x0051C020` | `0x7E` (126) | `[id*0x7E + 0x51C09A]` is the kill award, which [`21`](21-info-lcl-schema.md) places at `+0x7A` |
| unit record | — | `0x5B` (91) | `0x0046FAD0` and the visibility passes walk the unit array with `add ptr, 0x5B` |

Weapon bytes are written below as `weapon[+off]` using
[`21`](21-info-lcl-schema.md)'s offsets, unit-type bytes as `unitType[+off]`,
unit bytes as [`10` §5.2](10-lev-mission-format.md)'s.

The unit array has **200 slots**: `0x0046FAD0`, `0x004794B0` and `0x004798C0`
all loop exactly 200 times over it.

### 2.2 The control-map cell

Combat operates on the same 23-byte cell record the `.lev` file stores, laid
out in [`10` §4](10-lev-mission-format.md). `aGetCtrlMapElementPtr(x, y)`
returns it, `0x0042F650` returns the array base and `0x0042F660` its length.
Two bytes gain meaning here:

- **`+0x00`** — [`10`](10-lev-mission-format.md) already records that
  `0x0042F7D0` refuses to overwrite a cell whose state is in `0x50`–`0x5E`.
  That band is the **attack scratchpad**: `0x50`–`0x55` are written by the
  target-pattern pass (§7.2) and `0x5A`–`0x5D` by the resolver (§7.3).
- **`+0x0C`** — listed there as an unidentified runtime flag. It receives the
  **damage this cell's unit took** from the attack just resolved
  (`cell[0x0C] = dealt`, or `0` when the damage was 255).

Heights in `+0x01` are world units: **1 map field = 3200 = 2 m**.

---

## 3. `aRandom` — **[code] `0x00463870`**

A Lehmer generator in `double`, with four arguments. Ghidra recovers none of
them; the disassembly gives all four:

```c
int aRandom(int base, int span, int line, const char *file);
```

```c
static double seed;                                     /* 0x00514078 */

int aRandom(int base, int span) {
    seed = (double)(int)fmod(seed * 62089911.0, 2147483647.0);
    return (int)(base + span * (seed * (1.0 / 2147483647.0)));
}
```

The three constants live at `0x004B1530`, `0x004B1538` and `0x004B1540`; the
last is exactly `1/(2³¹−1)`, so the normalised draw is in `[0, 1)` and the
result is **`base .. base+span−1`**. `aRandom(0, 100)` is a percentile roll.
The signature is `(base, span)` and not `(min, max)`, which changes what every
call below means.

Two counters — `0x00514080` calls, `0x00514084` running sum — are updated on
every draw and **read by nothing**. Byte-scanning `.text` for their addresses
finds three references each, and every one lies inside `aRandom` or
`aRandomize`: the read in `mov edx, [0x514084]; add edx, eax; mov [0x514084],
edx` is the accumulate's own. Nothing outside `0x00463820..0x004638D5` touches
them, so they cannot be feeding a debug overlay or a log. `iDesigner.exe` ships
the same generator at `0x0042D980`, counters at `0x004C4BF0`/`0x004C4BF4`, with
the same result. Balance instrumentation whose consumer was cut.

The `line`/`file` arguments are the same debug pair as §1 and are ignored.

### 3.1 Seeding — **[code] `0x00463820`**

All four globals live in the **uninitialised tail of `.data`** in both binaries
— past the end of the section's raw data, so the loader zeroes them — which is
what makes the next paragraph a statement about the shipped product rather than
about one build.

```c
void aRandomize(double seed) {          /* 0x00463820 */
    *(double *)0x00514078 = seed;
    *(int *)0x00514080 = 0;             /* call count  */
    *(int *)0x00514084 = 0;             /* running sum */
}
```

This matters for a remake, because **the seed starts at 0 and 0 is a fixed
point of the generator**: `fmod(0 * 62089911, 2147483647)` is 0 forever,
so an unseeded `aRandom(base, span)` returns `base` on every call. Three
callers seed it:

| Caller | Seed |
|---|---|
| `aInitMenuSystem` (`0x0044B220`) | the constant **1.0** |
| `aInitBattleGround` (`0x00419D90`) | `(double)GetTickCount()`, but only when the game mode is 1, 3 or 4 |
| `0x004494C0` | — |

`aInitBattleGround` builds the 64-bit integer as `eax:ebx` and `ebx` is zeroed
at the top of the function and never reassigned, so the value really is the
32-bit tick count. In the modes it does not cover, the menu's fixed 1.0 stands
and **a mission plays out identically every time it is loaded**.

`iDesigner.exe` has **no seeder at all**: the only two references to its seed
(`0x004C4BE8`) are `aRandom`'s own `fld`/`fst`, and the global is in the
uninitialised tail of `.data`. The editor's generator therefore never leaves
zero, and every `aRandom(base, span)` in it returns `base`.

---

## 4. Distance — **[code] `aGetDistance` `0x0044AE10`, inlined at `0x0046A2CE`**

```c
int aGetDistance(int x0, int y0, int x1, int y1) {
    return (int)sqrt((double)((x0-x1)*(x0-x1) + (y0-y1)*(y0-y1)));
}
```

`ftol` truncates and the argument is non-negative, so this is
`floor(sqrt(...))` in **map fields**. Euclidean, not Chebyshev: a diagonal of 1
is distance 1, a diagonal of 3 is distance 4.

---

## 5. Hit probability — **[code] `aGetHitProbability` `0x0046A270`**

```c
BOOL aGetHitProbability(Unit *att, Unit *def, int weaponId,
                        int unused, BOOL applyLOS,
                        int *outHitPercent, int *outDistance);
```

Returns `FALSE` when the target is out of range, with `*outHitPercent = 0`;
otherwise `TRUE` and `*outHitPercent` in `0..100`.

### 5.1 Distance

```c
Cell *ca = aGetCtrlMapElementPtr(att->x, att->y);          /* unit +0x42/+0x43 */
Cell *cb = aGetCtrlMapElementPtr(def->x, def->y);
if (weapon[+0x3B] == 6)                                    /* special 6 */
    cb = aGetCtrlMapElementPtr(def->lastX, def->lastY);    /* unit +0x51/+0x52 */

d = aGetDistance(ca->x, ca->y, cb->x, cb->y);
if (unitType(att)[+0x7B] == 1) d--;
if (unitType(def)[+0x7B] == 1) d--;

dh = abs(ca->height - cb->height);
if (dh > 2400 && d == 1) d = dh / 2400 + 1;
```

`weapon[+0x3B] == 6` is the *"attack the defender's position of the last
turn"* special that [`21`](21-info-lcl-schema.md) glosses from `Info.lcl`.
This is its only consumer, and it confirms both the special and the meaning of
unit `+0x51`/`+0x52`.

`unitType[+0x7B]` is `SetUnitInfo`'s **size** column ([`21` §5](21-info-lcl-schema.md)),
`1` for exactly three shipped types — `ComBot`, `Tr'Yn` and `Al'Coo` — and `0`
for the other 33. A large unit spills past its nominal field, so the engine
subtracts one field of distance for each large participant. The same byte is
what the explosion handler tests (§7.2, weapon 17) before re-centring on a
unit's own cell.

The `dh > 2400` rule only fires at `d == 1`: two adjacent cells whose floors
are more than 1.5 m apart count as further apart than one field. The division
is a compiler magic multiply (`0x1B4E81B5`, `sar edx,8`); `combat_tables.py`
emulates it instruction by instruction and confirms it equals `dh / 2400 + 1`
over the full height range the 155-file `.lev` corpus contains.

### 5.2 Range gate

```c
if (d < weapon[+0x2E] || d > weapon[+0x2F]) { *outHitPercent = 0; return FALSE; }
```

Straight `min <= d <= max`. This is the check the eight weapons with a
9-character wave name (see [`21`](21-info-lcl-schema.md)) reach with `min = 0`
instead of `1`.

The gate also protects the division in §5.4 from a zero `range max` — except
at `d == 0`, which needs `range min == 0` as well. Weapon 28 (`"-"`, "No
Weapon") is the only shipped weapon with `0,0`, so **firing weapon 28 at the
attacker's own cell divides by zero**. It has no target pattern (§7.2) and
cannot be selected, so the path is unreachable in the shipped game.

### 5.3 Accuracy — **[code] `0x004752E0`**

```c
int acc = weapon[+0x30];                    /* the "Hit (%)" column */
if (acc > 99) acc = 100;
else if (att->equip[5]) {                   /* unit +0x26, "Target System" */
    acc *= 2;
    if (acc > 100) acc = 100;
}
```

Equipment 5 is `"Target System"` in `Info.lcl`, and unit `+0x26` is `+0x21 + 5`
in the 21-byte equipment bitmap of [`10` §5.4](10-lev-mission-format.md) — the
pairing is exact.

### 5.4 The curve

```c
hit = 100 - ((101 - acc) / weapon[+0x2F]) * d;      /* integer division, in that order */
```

The slope is truncated **before** it is multiplied by the distance, which makes
every weapon with `acc + rangeMax > 101` flat at 100 %
(`tools/combat_tables.py --hit-curve`):

| id | Weapon | acc | max | slope | hit at 1 | at max |
|---|---|---|---|---|---|---|
| 0 | Light Combat Gun | 3 | 10 | 9 | 91 | 10 |
| 2 | Standard Assault Rifle | 4 | 20 | 4 | 96 | 20 |
| 3 | Sniper Rifle | 20 | 30 | 2 | 98 | 40 |
| 7 | Flame Thrower | 100 | 4 | 0 | 100 | 100 |
| 10 | High Energy Laser | 90 | 40 | 0 | 100 | 100 |

Truncation also makes the `Target System` a no-op on most weapons: doubling
`acc` from 3 to 6 leaves `(101−acc)/10` at 9. It changes the outcome only when
the doubling crosses a step of the divisor.

The GUI prints `weapon[+0x30]` verbatim after the label `"Accuracy:"` with a
`%` sign, so the number the player sees is a rating, not a probability.

### 5.5 Line of sight

Skipped entirely when `applyLOS` is false. Otherwise:

```c
int zoff = isArcing(weaponId) ? 3200 : 0;               /* 0x0047B600 */
int mode = (att->player == 0xFF && att->order != 9) ? 0 : 1;

aCheckLineOfSightEx(ca->x, ca->y, eyeHeight(att) + zoff + ca->height,
                    cb->x, cb->y, eyeHeight(def) + zoff + cb->height,
                    mode, &block);
if (hit < block) { *outHitPercent = 0; return TRUE; }
hit -= block;
```

`isArcing` (`0x0047B600`) is a jump table returning 1 for exactly weapon ids
**8, 13, 42, 46** — the `Grenade Launcher`, the `Mine Thrower Enhanced`, and
the B mode of each. Raising **both** endpoints by one field lifts the whole ray
over low obstacles without changing its slope. That is the entire
indirect-fire mechanic.

`block` is 0, 254 or 255 (§6) and `hit` never exceeds 100, so any obstruction
zeroes the chance. The subtraction is not a partial cover penalty: cover in
this engine is binary.

`mode` is the one place the engine gives itself a discount: a **neutral** unit
(`player == 0xFF`) whose primary order is not 9, `Clever small units`
([`10` §5.6](10-lev-mission-format.md)), gets the single-ray form. Everything
the player controls, and every alien on the "clever" order, gets the two- or
four-ray form.

Heights: `eyeHeight` = `0x0047AD30` = `unitType[+0x7C] * 160 / 2 + 800`, and
the full standing height `0x0047AD70` = `unitType[+0x7C] * 160`. A null unit
pointer yields 2400.

---

## 6. Line of sight — **[code] `0x0046C460`, `0x0046C720`, `0x0046D400`**

### 6.1 `aCheckLineOfSightEx(x0,y0,z0, x1,y1,z1, mode, *out)`

Runs `aCheckLineOfSight` up to four times with different **rounding biases**
and keeps the smallest result (all four slots start at `0xFF`):

| mode | rays |
|---|---|
| `0` | one, **target → source**, bias `0.5` |
| `!= 0`, one human player and not a network game | two, source → target, biases `0.4` and `0.6` |
| `!= 0`, otherwise | four: source → target and target → source, each at `0.4` and `0.6` |

The bias is added to the ray coordinate before it is truncated to a cell index,
so `0.4` and `0.6` walk the *same* geometric line but break ties on opposite
sides of it. Taking the minimum means **a target is visible if any sampled walk
is clear** — which is how the engine lets you shoot past a corner without
tracing a cone.

### 6.2 `aCheckLineOfSight(x0,y0,z0, x1,y1,z1, bias, *out)`

```c
*out = 0;
if (x0 == x1 && y0 == y1) return TRUE;          /* same cell: always clear */

setupStep(x0,y0,z0, x1,y1,z1, &dx, &dy, &dz);
if (dz > 4000.0 || dz < -4000.0) { *out = 0xFF; return TRUE; }   /* too steep */

x = x0; y = y0; z = z0;
for (steps = 0; steps <= 1000; steps++) {
    x += dx; y += dy; z += dz;
    cx = (int)(x + bias); cy = (int)(y + bias);
    if (cx == x1 && cy == y1) return TRUE;      /* reached the target cell */
    Cell *c = aGetCtrlMapElementPtr(cx, cy);
    if (z < c->height) *out = 0xFF;             /* terrain blocks */
    if (c->unit != 0xFFFF) {
        Unit *u = aGetUnitMapElementPtr(c->unit);
        if (u->x == c->x && u->y == c->y &&                    /* the unit's own cell */
            z <= fullHeight(u) + c->height && *out < 0xFF)
            *out = 0xFE;                        /* a body blocks */
    }
}
```

Three outcomes, and they are *codes*, not costs:

| `*out` | meaning |
|---|---|
| `0` | clear |
| `0xFE` (254) | a unit stands in the way |
| `0xFF` (255) | terrain is in the way, or the slope exceeds ±4000 per field |

Terrain wins: once `0xFF` is set the unit test cannot lower it. The walk does
not stop at a block — it runs to the target cell and reports the worst thing it
met. The unit test only fires on a unit's *own* cell, so a unit that spans
several fields blocks only from the one it stands on.

`dz` is per **field stepped**, so the ±4000 gate is a slope limit of
`4000/3200 = 1.25`, about 51°. Both tests compare the ray's height against
`cell height + something`, i.e. everything is measured from the same ground
datum.

### 6.3 `setupStep` — **[code] `0x0046D400`**

```c
slope = (x1 != x0) ? fabs((double)(y1-y0) / (x1-x0)) : 1.0;
sy = (y1 > y0) ? slope : (y1 == y0) ? 0.0 : -slope;
sx = (x1 > x0) ? 1.0   : (x1 == x0) ? 0.0 : -1.0;
m  = max(fabs(sy), fabs(sx));
*dx = sx / m;  *dy = sy / m;                       /* one whole field on the dominant axis */
*dz = (z1 != z0) ? (double)(z1 - z0) / aGetDistance(x0,y0,x1,y1) : 0.0;
```

A plain DDA. Note that `dz` is divided by the **Euclidean** distance while the
walk advances along the **dominant axis**, so on a perfect diagonal the ray
climbs about 1.41× more slowly than its endpoints imply and arrives low. The
last argument of `setupStep` selects `(z1>>3) - (z0>>3)` instead of `z1 - z0`;
line of sight always passes 0, and no other caller exists.

---

## 7. Resolving an attack — **[code] `aAttackUnit` `0x0046B450`**

```c
BOOL aAttackUnit(int x, int y, int tx, int ty, int silent);
```

`(x, y)` is the attacker's cell, `(tx, ty)` the aim point. If a unit stands on
the aim point, the aim point is replaced by **that unit's own** `+0x42`/`+0x43`
— which matters for units that occupy more than one field.

### 7.1 Before the shot

1. `aCheckWeaponDamage` (§8) may jam or destroy the weapon. If it leaves
   `unit[+0x40] != 0`, or the attacker's HP is 0, the function returns without
   firing.
2. The attacker turns to face the target: `aChangeUnitViewDirection` writes
   `unit[+0x46]` with `direction(x, y, tx, ty)` (§7.4).
3. `0x0046AA10` marks every cell the weapon covers.

### 7.2 The target pattern — **[code] `0x0046AA10`**

A two-level switch on the weapon id: an index byte at `0x0046B420 + weaponId`
selects one of 28 handlers listed at `0x0046B3B0`. `combat_tables.py` decodes
both tables, so all **48/48** weapon ids are accounted for. Each handler writes
a **marker byte** into cell `+0x00`, and the marker fixes the damage the
resolver will use:

| marker | damage at that cell |
|---|---|
| `0x50` | `weapon[+0x31]` — full |
| `0x51` | `(weapon[+0x31] * 70 + 1) / 100` |
| `0x52` | `(weapon[+0x31] * 50 + 1) / 100` — **never written by anything**, see §12 |
| `0x53` | 100, flat — written by a secondary explosion, not by a weapon |
| `0x54` | none; the roll is rigged so the cell always resolves as a hit |
| `0x55` | none; always hits, and **the target loses the rest of its turn** |

The sixteen distinct patterns, with `Info.lcl` names
(`combat_tables.py --patterns`):

| Handler | Weapon ids | Pattern |
|---|---|---|
| `0x46ABC0` | 0–4, 6, 10, 14–16, 20, 21, 23–25, 27, 29–32, 47 | the aim cell, `0x50`. Twenty-one direct-fire weapons |
| `0x46AE0B` | 8, 12, 26, 36 | aim cell `0x50` + all eight neighbours `0x51` |
| `0x46ABD5` | 17 `Explosives` | the same, but each neighbour is re-centred on the unit standing there |
| `0x46ACCD` | 22 `Spores` | the same, filtered to targets whose owner is not `0xFC` |
| `0x46B1C7` | 5, 41 | every unit within a radius of the aim point, `0x50`. The radius widens with the shot: 1 at range ≤ 2, 2 at 3–25, 3 beyond |
| `0x46AF38` | 9 `Plasma Gun` | every unit with line of sight from the aim point, `0x50` |
| `0x46B0D8` | 11 `Multi-target Destroyer` | every *special object* of type 30–34, `0x50` |
| `0x46AED2` | 44 `Multi-target Destroyer B` | every unit on the map, `0x50` |
| `0x46AD9F` | 13 `Mine Thrower Enhanced` | 18 cells at `aRandom(-2, 5)` offsets around the aim point, `0x50` |
| `0x46AB0A` | 7 `Flame Thrower` | the aim cell, `0x51` |
| `0x46AA66` | 40 `Flame Thrower B` | the eight neighbours `0x51`, then the aim cell `0x51` |
| `0x46ADE5` | 42 `Mine Thrower B` | the aim cell, `0x51`, with a null object id |
| `0x46ADF8` | 46 `Mine Thrower Enhanced B` | the aim cell, `0x50`, with a null object id |
| `0x46B0C3` | 43 `Plasma Gun B` | the aim cell, `0x54` |
| `0x46AEBD` | 45 `High Energy Laser B` | the aim cell, `0x55` — the stun mode |
| `0x46AB9A` | 18, 19, 28, 33, 34, 35, 37, 38, 39 | **no pattern at all**: reports an error and returns `FALSE` |

The last row is *almost* the set of ids `Info.lcl` never defines — that set is
{18, 19, 33, 34, 35, 38, 39}. The two extras are 28 (`"-"`, the placeholder
"No Weapon") and 37 (`Mine`), which exist as table entries but can never be
fired.

`0x0046AA10` is also called by `aExecuteBomb` (`0x004702C0`), which is how a
planted bomb reuses a weapon's blast pattern.

`SetWeaponInfo` accepts ids up to 50 ([`21` §1](21-info-lcl-schema.md)), but the
dispatch bounds-checks `id > 0x2F` and reports an error, so **weapon ids 48–50
can be defined and can never be fired**. `Info.lcl` defines none of them.

### 7.3 Per-cell resolution

The resolver sweeps the whole cell array, and repeats the sweep when a
secondary explosion added `0x53` markers. For every cell whose marker is in
`0x50..0x59` and which holds a unit:

```c
/* the raw call is `push &dist; push &hit; push 0; push 0; push weaponId;
   push target; push attacker` at 0x0046BA67..0x0046BA75 -- applyLOS is 0 */
chance = aGetHitProbability(attacker, target, weaponId, /*applyLOS=*/FALSE)
         ? that                                    /* 0..100 */
         : weapon[+0x30];                          /* out of range: the raw rating */
if (bannerNearby(attacker)) chance *= 2;           /* 0x0046FAD0 */

damage = <from the marker, table above>;
roll   = aRandom(0, 100);                          /* 0..99, drawn before `chance` */
if (chance + 10 < roll) { cell[0] = 0x5A; continue; }        /* miss */
```

Markers `0x54` and `0x55` overwrite both `chance` and `roll` after this point
(`0/1` and `1/0` respectively), which is what makes them always resolve as a
hit regardless of range, cover or accuracy.

Three things worth stating plainly, because none is guessable from the data
files:

- **Line of sight is not re-checked here.** `applyLOS` is false, so a target
  the marking pass accepted is hit without a second cover test.
- **A target outside the weapon's range still resolves**, using the raw
  `Hit (%)` column as the chance. That is how splash reaches past `range max`.
- **The `+10` bonus is unconditional.** A weapon at 0 % still connects on a
  roll of 0..9, i.e. 11 % of the time.

`bannerNearby` (`0x0046FAD0`) walks the 200 unit slots and returns true if any
unit is alive, belongs to the **same player**, carries equipment 8
(`"Banner"`, unit `+0x29`), and is within `aGetDistance < 4` of the attacker.
In a network game the owner test is replaced by `player < 5`. It **doubles the
hit chance**.

Special cases applied before the roll, keyed on `unitType[+0x07]` of the
**target**:

`+0x07` is `SetUnitInfo`'s **special** column, an enumerator 0..16 whose
seventeen values are tabulated in [`21` §5](21-info-lcl-schema.md). Four of them
steer the resolver:

| `special` | Shipped carriers | Effect |
|---|---|---|
| 10 | *none* | immune unless the weapon's type (`weapon[+0x37]`) is 2 or 3. Unreachable in the shipped game |
| 12 | `Barrel` ×3, `Parabomb` | damage forced to 255, guaranteed hit, and the eight neighbours are marked `0x53` — **it explodes when hit** |
| 13 | `Case` | damage forced to 255, guaranteed hit |
| 16 | `Bea'Coo` | on death, marks the eight neighbours `0x53` — **it explodes when killed** |

Two more reach combat indirectly: `1` (`Cy'Coo`) throws its own cached armour
away when it attacks, and `9` (`Squee'Coo`) turns into a different unit type
when a hit takes it below 6 HP.

and two more: a target of unit type `0x42` hit by a type-2 weapon takes a flat
1000 — which is passed to the damage routine as a `u8` and therefore arrives as
**232** — and a cell whose effect state (`+0x10`) is 3 takes nothing.

After the roll the marker is rewritten: `0x5A` miss, `0x5B` resolved,
`0x5C` hit and survived, `0x5D` hit and killed. A `0x5D` cell has its unit
removed at the end of the sweep.

The `0x55` (stun) path is separate: no damage is rolled, but unless the target
spends a `Damage Absorber` charge, `0x0046CC80` sets its action state
(`+0x41`) to 5 and its MP (`+0x15`) to 0 — the unit loses the rest of the turn.

### 7.4 Damage — **[code] `0x0046C960`**

```c
BOOL applyDamage(Unit *def, u8 damage, u8 attackerFacing, u8 *outDealt);
```

```c
if (def->type == 0x23) { *outDealt = 0; return TRUE; }      /* one immune unit type */
if (damage == 0xFE)    { def->hp -= 2 (floor 0); *outDealt = 2; return TRUE; }

switch (aiLevel()) {                       /* 0x00460450 = Game.opt +0x18 */
  case 0: d = aRandom((damage+1)/2, damage);     break;
  case 1: d = aRandom((damage+1)/2, damage + 1); break;
  case 2: d = aRandom((damage+1)/2, damage + 2); break;
  default: "incorrect ai level!";
}

if (def->fp == 0) { d += aRandom(0, damage+1); d += aRandom(0, damage+1); }
else if (def->fp == 1) d += aRandom(0, damage+1);

armour = frontal(attackerFacing, def->facing) ? def->armourRear   /* +0x37 */
                                              : def->armourFront; /* +0x36 */
a = armour ? aRandom(armour/2, armour) : 0;
if (a < armour/2) a = aRandom(armour/2, armour);            /* unreachable, see below */
d = (d > a) ? d - a : 0;

if ((humanPlayers > 1 || gameMode == 2) && !isNetworkTurn()) d = d * 3 / 4;

if (d < def->hp) def->hp -= d; else def->hp = 0;
*outDealt = d;
```

**Damage 254 is a sentinel, and it is in the shipped data.** Weapon 14,
`Enhanced Laser Gun`, has `damage = 254` in `Info.lcl`, which
[`21`](21-info-lcl-schema.md) already notes renders as a special string in the
GUI instead of a number. Mechanically it takes the second early return above:
exactly **2 HP, ignoring the roll, fatigue, armour and the difficulty level**.
Its pattern is a single cell at `0x50`, so the 254 always arrives intact.

Points that only the code gives:

- **The difficulty level widens the damage roll upward; it does not scale it.**
  The floor `(D+1)/2` is identical at every level, only the span grows by one.
  `aiLevel()` reads `Game.opt` `+0x18`, the options screen's eighth row,
  labelled *"Set Difficulty Level"* — see [`20` §7.6](20-lcl-language.md). It is
  forced to 1 in any multi-player or network game, so **the difficulty setting
  only exists in single player**. The damage span is not its only consumer:
  `0x00460450` has eleven call sites in six functions — `0x0046C960` (this
  roll), `0x0047AFD0` (the experience award), `0x00475160` (the movement-point
  recompute, but only for unit type `0x32`), `0x0043BA10`, `0x004418C0`, and
  `0x00451A70` six times in the UI. Only the first is in this document's
  scope.
- **Fatigue is a damage multiplier on the receiving end.** A defender at
  `FP == 0` takes two extra `aRandom(0, D+1)` rolls — up to roughly three times
  the damage of a rested one; `FP == 1` takes one. This is the mechanical
  reason the game punishes acting on empty fatigue.
- **The armour reroll is dead code.** `aRandom(armour/2, armour)` cannot return
  less than `armour/2`, so the guard on the second roll is false for every
  armour value below 171. Shipped values are 0–6.
- **Armour is a subtraction of a random magnitude in
  `armour/2 .. 3*armour/2 − 1`,** not a percentage.

`frontal()` compares the attacker's facing — set to point at the target in
§7.1 — against the defender's facing and its two neighbouring octants
(`0x0046A930`, `0x0046A9A0`). If the attacker is firing **in the same
direction the defender is looking**, the defender is being shot in the back and
the thinner **rear** armour applies. The three matching octants make the rear
arc 135° wide.

Direction codes (`0x0046A760`, computed from the shooter to the target, with
`|dy/dx|` thresholds at 0.5 and 1.5 — `0x004B15E0` and `0x004B15D8`) and their
unit vectors, independently confirmed by `aGetGradientsOfUnitView`:

```
   7   2   4          0 = ( 0,+1)   1 = (-1, 0)   2 = ( 0,-1)   3 = (+1, 0)
   1   *   3          4 = (+1,-1)   5 = (-1,+1)   6 = (+1,+1)   7 = (-1,-1)
   5   0   6
```

### 7.5 After the shot

| Effect | Code |
|---|---|
| ammo | `if (weapon[+0x39] != 255 && attacker type != 0x42) unit[+0x3D] -= weapon[+0x41]` |
| heat | `if (maxHeat != 255 && unit[+0x3E] < maxHeat) unit[+0x3E]++` |
| damage absorber | equipment 18 fills `unit[+0x3A]`; a hit that would land spends one charge (`0x004755B0`) and **nullifies the damage entirely** |
| experience | on a kill, unless the victim is species 2 (an inanimate object), its `unitType[+0x7A]` goes to `0x0047AFD0` / `0x0047B090` / `0x0047B100` |
| dead marker | a unit reduced to 0 HP has `+0x16` set to `0xFF` before removal |
| script | `aRunLCL` is entered with LCL variables `0x41 = 3`, `0x42 = tx`, `0x43 = ty` |

`maxHeat` (`0x00475340`) is `weapon[+0x3A]`, doubled when the unit carries
equipment 19 (`"Cooler"`, unit `+0x34`). `255` disables heat for that weapon.

---

## 8. Overheating — **[code] `aCheckWeaponDamage` `0x0046D1B0`**

Called once per attack, before firing. It does nothing unless the weapon is
exactly at its heat cap:

```c
if (unit[+0x3E] != maxHeat(unit)) return TRUE;
switch (aRandom(0, unit[+0x3E])) {
  case 0 ... 10:
        if (weapon[+0x37] is 0, 2, 3 or 4) { effect "damage.wav";  unit[+0x40] = 5; }
        else                               { effect "jammed.wav";  unit[+0x40] = 2; }
        break;
  case 21 ... 24:
        effect "damage.wav"; unit[+0x40] = 5; break;
  case 30:
        effect "explosion.wav"; the unit is removed from the map; break;
  default:
        unit[+0x40] = 0;                      /* clears a previous jam */
}
```

The roll is `aRandom(0, heat)`, so the *span* of outcomes is the weapon's own
heat cap. A weapon capped at 10 never rolls above 10 and can never destroy its
carrier; a cap of 31 or more can. The `Cooler` (equipment 19) doubles the cap
and therefore **widens the range of bad outcomes** — the item is not purely
protective.

This settles the two runtime bytes [`10` §5.12](10-lev-mission-format.md)
records: `+0x3E` is the heat counter, `+0x40` the malfunction state, `2` and
`5` its only values, and a non-zero value blocks firing.

The effect routine is `0x0040F420(x, y, kind)`, `kind` 1 explosion / 2 jam /
3 damage, which also plays the matching `.wav`.

---

## 9. Visibility — **[code] `0x004798C0`, `0x004794B0`, `0x00479370`**

### 9.1 `aSetVisibleStateForUnit(unit, state)` — the only writer of `+0x4F`

```c
if (unit->hp == 0) return FALSE;             /* a dead slot has no state */
Obj3D *o = object(unit->objectSlot);         /* unit +0x4B */
if (o->flag == 0) return FALSE;
switch (state) {
  case 0: o->flag = 1; unit[+0x4F] = 0; break;   /* fully visible */
  case 1: o->flag = 3; unit[+0x4F] = 1; break;   /* scanner contact */
  case 3: o->flag = 2; unit[+0x4F] = 3; break;   /* hidden */
  case 2: /* nothing at all */               break;
}
```

The three states are exactly the ones [`10` §5.2](10-lev-mission-format.md)
lists for `+0x4F`, and the 3D-object flag written alongside is what makes the
model solid, ghosted or absent. `state == 2` is accepted and ignored — there
is no fourth state.

### 9.2 `aBuildVisibleMap(player)` — the whole fog pass

```c
for (each of the 200 unit slots u with hp != 0) {
    bool always = u->player == player
                || unitType(u)[+0x79] == 2
                || u->type == 0x3D || u->type == 0x3E || u->type == 0x3F;
    aSetVisibleStateForUnit(u, always ? 0 : 3);          /* reset to hidden */
}
for (each own living unit u)
    aBuildVisibleMapForUnit(u, u->x, u->y, &sawSomething);
```

Everything is hidden first and then revealed, so visibility is recomputed from
scratch on every call — there is no incremental fog state to persist. Three
unit types (`0x3D`, `0x3E`, `0x3F`) and everything of **species 2** are
permanently visible. `unitType[+0x79]` is `SetUnitInfo`'s *species* column
([`21` §5](21-info-lcl-schema.md)): `0` human, `1` alien, `2` inanimate object,
`3` machine. Species 2 covers the six scenery types — `Barrel`, `Parabomb`,
`Case`, `Concrete Block` — which are drawn as part of the map and therefore
never hidden, and which for the same reason award no experience (§7.5).

### 9.3 `aBuildVisibleMapForUnit(observer, x, y, *sawSomething)`

```c
scan = observer->equip[0] ? 1 : 0;          /* +0x21, "Scan Module" */
if (observer->equip[1]) scan = 2;           /* +0x22, "Long Range Scan" */

for (each of the 200 unit slots u with hp != 0) {
    if (u->type == 0x3D || u->type == 0x3E) { visible(u); continue; }
    if (u->player == observer->player)      continue;
    if (unitType(u)[+0x79] == 2)            continue;

    aCheckLineOfSightEx(obsCell, fullHeight(observer) + obsCell->height,
                        uCell,   fullHeight(u)        + uCell->height,
                        /*mode=*/1, &block);
    if (block < 0xFF) {                     /* clear, or only a body in the way */
        *sawSomething = 1;
        aSetVisibleStateForUnit(u, 0);
        if (u->player == 0xFF && u->order in {5, 6, 8})
            alertGroup(u->group);           /* 0x0047A810 */
    } else if (u[+0x4F] != 0) {             /* out of sight: try the scanner */
        int d = aGetDistance(obs, u);
        if ((scan >= 1 && d < 6) || (scan == 2 && d < 8))
            aSetVisibleStateForUnit(u, (scan == 1) ? 1 : (d < 6 ? 0 : 1));
    }
}
```

Four things this settles:

- **Vision is not the same test as fire.** It uses `fullHeight` for both
  endpoints where shooting uses `eyeHeight`, and it accepts `block == 0xFE`:
  **a unit standing in the way blocks a shot but not the sight of it.**
- **The two scanners are `Scan Module` (range < 6) and `Long Range Scan`
  (range < 8).** Inside 6 fields the long-range scanner reveals the unit fully
  (state 0); between 6 and 8 it gives a contact (state 1); the plain module
  only ever gives a contact.
- **Seeing a neutral unit whose order is 5, 6 or 8 wakes its whole AI group.**
  `0x0047A810` copies `+0x49`/`+0x4A` (the secondary order and its parameter)
  over `+0x47`/`+0x48` for every unit sharing the group id — which is what the
  secondary order in [`10` §5.6](10-lev-mission-format.md) is *for*.
- The pass has no field of view: a unit sees in all directions.
  `aGetGradientsOfUnitView` exists and returns the facing's unit vector, but no
  visibility code calls it — `aMI.cpp` does, for the camera.

A second pass then re-examines every unit still hidden (`+0x4F == 3`) and
neutral (`player == 0xFF`): if **none** of its eight neighbouring cells holds a
unit that is already a scanner contact (`0x00479410`), it is promoted to a
contact itself. The effect is to show one blip per cluster instead of one per
alien.

---

## 10. What a remake has to implement

The whole chain, in order, for one attack:

```
aExecuteFight
 └─ aAttackUnit(x, y, tx, ty)
     ├─ aCheckWeaponDamage           heat -> jam / destroy
     ├─ aChangeUnitViewDirection     attacker turns to face the target
     ├─ 0x0046AA10                   mark covered cells 0x50..0x55
     └─ for each marked cell holding a unit:
         ├─ aGetHitProbability       distance, range gate, accuracy curve
         │   └─ aCheckLineOfSightEx  1/2/4 rays -> 0 / 254 / 255
         │       └─ aCheckLineOfSight
         ├─ aRandom(0,100) <= chance + 10
         ├─ 0x0046C960               damage roll, fatigue, armour, HP
         └─ aSetVisibleStateForUnit

aBuildVisibleMap(player)             once per turn and after every move
 └─ for each own unit: aBuildVisibleMapForUnit
     └─ aCheckLineOfSightEx  +  the two scanner ranges
```

---

## 11. Verification

`tools/combat_tables.py --check gog_incubation` — all counts are `N/N`:

| Check | What it proves |
|---|---|
| `aoe.dispatch` 48/48 | every weapon id resolves through the two-level jump table |
| `aoe.markers` 16/16 | every handler writes only markers this document lists |
| `aoe.no_pattern` | the marker-less handler serves exactly {18, 19, 28, 33, 34, 35, 37, 38, 39} |
| `arc.weapons` | `0x0047B600` returns 1 for exactly {8, 13, 42, 46} |
| `octant.*` 17 | the two neighbour tables are a consistent, symmetric octant relation |
| `const` 10/10 | every `.rdata` constant quoted above matches the binary |
| `const.bias` 3/3 | the three inline doubles really are 0.4, 0.5 and 0.6 |
| `magic.div` | the emulated magic multiply equals `n / 2400 + 1` over the corpus height range |
| `marker.written` | over the whole `.text`, only `0x50`, `0x51`, `0x53`, `0x54`, `0x55` are ever written into a cell |
| `rng.*` 3 | the RNG constants form a Lehmer generator with scale `1/(2³¹−1)` |
| `hit.monotonic`, `hit.bounded` 40/40 | the hit curve is non-increasing and never exceeds 100 for every shipped weapon at every in-range distance |
| `info.wave_overrun` | exactly eight weapons have a 9-character wave name, matching [`21`](21-info-lcl-schema.md) |
| `opt.io` | `aSaveOptions` and `aLoadOptions` both transfer `0x6C` bytes from `0x005129D8`, i.e. `Game.opt` is one `.data` block |
| `opt.rows`, `opt.difficulty` | the eight option rows resolve to help lines 50/51/52/57/55/54/56/58, and row 7 — `aiLevel` — is 58 |
| `special.sites` | the eleven `.text` sites that touch `unitType[+0x07]` are exactly the ones [`21` §5](21-info-lcl-schema.md) accounts for |
| `rng.private` 2/2 | in both `Incubation.exe` and `iDesigner.exe`, every reference to the RNG's four globals lies inside `aRandom`/`aRandomize` |

`tools/trace_names.py --check gog_incubation` re-derives the symbol table and
asserts the ten names §1.1 depends on.

---

## 12. Open questions

**None.** The three that this document opened are closed below, each in the
place the evidence belongs, and nothing new was left hanging.

1. **`aiLevel()` is the options screen's *"Set Difficulty Level"* row** —
   `Game.opt` `+0x18`, cycled by `0x00460780`, tooltip text 58 in
   `Txtmod_h.lcl`. Its three settings have **no names in the shipped product**:
   the control is a skull icon from `Libs/options.LIB` with one, two or three
   lit pips (sprites 23/24/25), and sprite 26 is the blank tile drawn when the
   game state disables the row — which is what text 58 means by *"only in main
   map during campaign"*. The whole 108-byte blob is now laid out in
   [`20` §7.6](20-lcl-language.md). Nothing further is recoverable, because
   there is nothing further: the levels were never given names.
2. **The `special` enumerators are decoded by behaviour, all seventeen of
   them** — [`21` §5](21-info-lcl-schema.md). One dispatcher (`0x0046F210`)
   with five phases covers 1, 2, 3, 4, 6, 7, 8 and 9; `aBuildMoveMap` covers 14
   and 15; the resolver covers 10, 12, 13 and 16. Seven values are implemented
   and carried by no shipped unit type. The *names* remain unrecoverable — the
   code is a hand-written `switch` on integer literals in three modules and
   neither binary holds a matching string — but nothing about the behaviour is
   open any more.
3. **The `aRandom` counters are provably private to the generator** — §3, both
   binaries. Not "no reader was found": every reference in `.text` was
   enumerated and they all lie inside `aRandom`/`aRandomize`.

Three dead paths are **closed**, not open — the code is understood and the
answer is that nothing reaches them:

- **The `0x52` marker (50 % damage) is never written.** The resolver has a case
  for it; sweeping every `0x0042F7D0` call site in `.text` finds markers
  `0x50`, `0x51`, `0x53`, `0x54` and `0x55` and no `0x52`
  (`combat_tables.py`'s `marker.written`). A cut damage tier.
- **The armour reroll in `0x0046C960` never runs** for any armour value below
  171, and the shipped range is 0–6 (§7.4).
- **`aAttackUnit`'s second special-unit hook does nothing.** `0x0046C332` calls
  `0x0046F210` with phase 1, and the dispatcher's `case 1:` is an empty
  `break` — a hook that was wired up and never filled in.

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

The computer player that drives all of this — which enemy it shoots at, where
it walks, and what the eleven AI orders in a `.lev` mean — is
[`23-ai-system.md`](23-ai-system.md).

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

A third failure mode is a name attached to a function in a **different source
module** altogether. `aMain.cpp:922` guards a call to `0x0040B4D0` with the name
`aInitAISystem`, but that function's own `CHECK` reports `aAnimations.cpp:411`,
it touches none of the AI's globals, and `aMain` never calls the AI module's
init because there is none — [`23` §1](23-ai-system.md) works it through. When a
name and a `__FILE__` disagree, the `__FILE__` is the one to trust: it is
`__FILE__`, not a string someone typed.

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

### 3.2 The second stream — **[code] `0x004638E0`, seed `0x00514070`**

Eleven `nop`s after `aRandom`'s `ret` there is a **second entry point**, and it
is not a variant or a wrapper. Its body is `aRandom`'s **byte for byte** —
same multiplier, same modulus, same x87 sequence — over a different seed
global, and without the two counters:

```
0x00463870..0x004638B4   aRandom          seed 0x00514078, then count and sum
0x004638E0..0x00463924   the same code    seed 0x00514070, then `pop ecx; ret`
```

Sixty-two of the sixty-nine shared bytes are identical. The seven that differ
are the low byte of the seed address in the opening `fld` and the closing
`fst`, the two `call rel32` displacements (same targets, different origins),
and the two bytes where `aRandom` goes on to its counters while this one
returns.

**It is the busier of the two by a factor of eleven** — 372 call sites against
`aRandom`'s 32 — and the split between them is close to, but not exactly, the
line between simulation and presentation:

| | counted, `0x00463870` | uncounted, `0x004638E0` |
|---|---|---|
| call sites | 32 | 372 |
| calling functions | 17 | 75 |
| who calls it | `aAISystemControl`, `aAttackUnit`, `aCheckWeaponDamage`, `aExecuteUse`, `aComputeMissionObjectives` | `aBlobs.cpp` entire, the animation drivers (`aPlayFightAnimation`, `aPlayJumpAnimaion`, `aPlayFootBridgeSequence`) |
| seeded with | **1.0**, a constant | **`GetTickCount()`** |

Both seeds are written in the same six instructions inside `0x004494C0`:

```
    eax = GetTickCount();
    fild qword [esp+0x1c];          /* (double) of it */
    seed_uncounted(that);           /* 0x00463850 -> 0x00514070 */
    aRandomize(1.0);                /* 0x00463820 -> 0x00514078 */
```

So §3.1's finding — *a mission plays out identically every time it is loaded*
— has a second half: **the effects were never meant to repeat.** A shot does
the same damage every run and does not look the same, by construction. The
uncounted stream has its own seeder at `0x00463850`, which writes the qword as
two dwords and has exactly one caller.

**Nineteen of the seventy-five callers are outside `aBlobs.cpp`**, and three of
those are in the unit pool — `aEnlargeUnitPool`, `aAddUnitToUnitPool`,
`aGenerateUnitElement` — with a fourth, `0x004160F0`, drawing from **both**.
That looked like simulation reaching a clock-seeded generator, which is the one
combination §3.1's determinism argument does not cover. It is not.

**All three unit-pool sites roll a voice.** Each pushes `(1, 6)`, truncates
with `__ftol` and stores one **byte**, and the byte is `unit[+0x55]` — the
speech-set id of [`20` §7.4](20-lcl-language.md), which of the shipped
`Waves/Speech/` sets the soldier talks with. Two of the three address it
outright as `mov byte [reg + 0x0051F2F5]`, which is the persistent roster at
`0x0051F2A0` plus `0x55`, so the field is read off the encoding rather than
guessed from the value. [`10` §5.8](10-lev-mission-format.md) already recorded
that the byte was rolled; the generator is the missing half, and it is the
presentation one. `aGenerateUnitElement` does not roll at all for unit type
24: it writes a fixed 12, `spidy`.

Two consequences. Nothing in the rule set reads `+0x55`, so the determinism
argument stands; but the roster **is saved**
([`11` §5.11](11-save-game-format.md)), so a wall-clock-seeded byte does reach
the save file, and a remake must keep it out of a canonical hash rather than
out of the save.

**`0x004160F0` draws from both streams because it does both jobs.** It is in
`aAnimations.cpp`. Twice from the **counted** stream it picks a candidate spawn
tile — retried up to five times and tested by the placement helper, which is
simulation — and once from the **uncounted** one it takes an argument for a
routine inside `aBlobs.cpp`, which is an effect. The split is kept inside the
function, argument by argument. `docs/20` §7.4 has `InsertUnit`'s spawn count
coming from the C runtime's `rand`, so a third generator is in that picture
too, and it is on the same side of the line: a count, not a rule.

All of it is pinned by `tools/blob_tables.py`'s `random.*` checks — the
byte-identity, both seeds, both seeders, the two site counts, the two caller
sets, the nineteen that cross the line, the one that mixes, the three pool
sites with their arguments and their store, the fixed set for type 24, and
what each of `0x004160F0`'s draws is handed to — and none of them needs a
capture.

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
([`10` §5.6](10-lev-mission-format.md), [`23` §3.2](23-ai-system.md)), gets the
single-ray form. Everything
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
   **Weapon 47 fires at its cap**: inside the same `maxHeat != 255` gate,
   `cmp byte [esi+0x3F], 0x2F` at `0x0046B5DF` writes `maxHeat` into
   `unit[+0x3E]` (`0x0046B5EE`) *before* the overheat check, so every shot
   of `Laser Enhanced` rolls `aRandom(0, 40)` and fifteen of the forty
   outcomes damage it first. Measured: the first native probe of it rolled a
   2 and fired nothing (`tools/turn_gold.py`, `weapon47`).
2. **The shooter is revealed**: `aSetVisibleStateForUnit(attacker, 0)` at
   `0x0046B643` (`aTacTools.cpp:1662`), right after that test — a hidden
   unit is seen the moment it fires, whatever the shot then does. Measured
   with both parties written hidden first, and with the shooter's weapon
   written jammed as the control: the jammed shot reveals neither
   (`turn_gold.py`, `attack_hidden` / `attack_jammed`).
3. The attacker turns to face the target: `aChangeUnitViewDirection` writes
   `unit[+0x46]` with `direction(x, y, tx, ty)` (§7.4).
4. `0x0046AA10` marks every cell the weapon covers.

### 7.2 The target pattern — **[code] `0x0046AA10`**

```c
BOOL aBuildTargetPattern(int weaponId, int aimX, int aimY,
                         int shooterX, int shooterY, int shooterFacing);
```

**Six arguments, not three.** The two call sites settle them: the shot
resolver at `0x0046B6AC` pushes the shooter's `+0x42`, `+0x43` and `+0x46`
after the aim point, and `aExecuteBomb` (`0x00470318`) passes one value for
all three because weapon 36 reads none of them. Six of the sixteen handlers
read the last three, and the prologue makes them awkward to see: it loads the
aim into `ebx`/`ebp` and then **overwrites the argument slots** with the two
`aGetCtrlMapElementPtr` results, so a handler that wants the shooter reloads
from a slot that no longer holds what its offset suggests.

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
| `0x46ABD5` | 17 `Explosives` | **the shooter's own cell** `0x50`, then its eight neighbours `0x51` — only those holding a unit, and a **large** occupant is stamped on its own `+0x42`/`+0x43` instead of on the stepped cell |
| `0x46ACCD` | 22 `Spores` | **the shooter's own cell** `0x50`, then its eight neighbours `0x51` — only those holding a unit whose owner is not `0xFC` |
| `0x46B1C7` | 5, 41 | every unit within a radius of the aim point whose octant **from the shooter** is exactly the shooter's facing and whose `aGetHitProbability` resolves in 1…253, `0x50`. The radius widens with the shot: 1 at range ≤ 2, 2 at 3–25, 3 beyond |
| `0x46AF38` | 9 `Plasma Gun` | every unit the **shooter** has line of sight to, within the **three-octant arc** around its facing and `aGetDistance ≤ 4` of the aim point, `0x50` |
| `0x46B0D8` | 11 `Multi-target Destroyer` | every cell whose action point is 30–34, under the same arc and the same `≤ 4`, `0x50` |
| `0x46AED2` | 44 `Multi-target Destroyer B` | every unit within `aGetDistance < 4` of the aim point, `0x50`, each stamped with **its own** cell's object id |
| `0x46AD9F` | 13 `Mine Thrower Enhanced` | 18 cells at `aRandom(-2, 5)` offsets around the aim point, `0x50` — and then **falls through** into `0x46ADE5`, so the aim cell is stamped `0x51` as well |
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

**Five corrections this table carried until the third slice implemented the
handlers**, each cross-checked between the raw listing and Ghidra:

* **weapons 17 and 22 blast the shooter's own cell**, not the aim cell. Both
  handlers reload their coordinates from the argument slots the prologue
  overwrote with the *shooter's*, so the aim point is read and then never
  used. For `Explosives` that is the weapon working as its name says — a
  charge goes off where it is planted;
* **weapon 44 is not "every unit on the map"**: `aGetDistance < 4` of the aim
  point bounds it, and each cell is stamped with its own object id rather than
  the aim cell's;
* **weapon 13 falls through** into weapon 42's arm; so does weapon 40 into
  weapon 7's, which is where "the eight neighbours, then the aim cell" comes
  from;
* the two unrolled eight-neighbour handlers write their neighbours in **two
  different orders**, and neither is `dy`-then-`dx`. `0x0046AE0B` writes
  (−1,0) (−1,−1) (−1,+1) (0,−1) (+1,−1) (+1,+1) (+1,0) (0,+1); `0x0046AA66`
  writes (−1,0) (−1,−1) (−1,+1) (+1,0) (+1,−1) (+1,+1) (0,+1) (0,−1). The
  order is the order the damage rolls come out in, so it is not a set;
* **weapon 13 draws its `y` offset before its `x` offset.** The two `aRandom`
  calls carry source lines 978 and 977 in that order, so the compiler
  evaluated the arguments right to left; and the draws happen for all eighteen
  iterations whether or not the cell is on the map, because the write is
  bounds-checked and the draw is not.

All sixteen are implemented in `inclib/combat.py` and `godot/core/combat.gd`;
`ai_runtime.py`'s `pattern.*` checks census them over the corpus and, for the
five families no shipped unit carries, over a scene built by writing one
weapon byte.

`SetWeaponInfo` accepts ids up to 50 ([`21` §1](21-info-lcl-schema.md)), but the
dispatch bounds-checks `id > 0x2F` and reports an error, so **weapon ids 48–50
can be defined and can never be fired**. `Info.lcl` defines none of them.

### 7.3 Per-cell resolution

The resolver sweeps the whole cell array, and repeats the sweep when a
secondary explosion added `0x53` markers. For every cell whose marker is in
`0x50..0x59` and which holds a unit — **which is revealed first**,
`aSetVisibleStateForUnit(target, 0)` at `0x0046BA22` (`cpp:1988`), before the
roll and so on a miss as well as a hit; `aExecuteBomb` does the same at
`0x004703A9` — the shot resolves as:

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

**A hit that connects then meets the absorber, and weapon 47's arm**
(`0x0046BD29`..`0x0046BDEB`, measured 2026-09-02 by `tools/turn_gold.py`'s
`conversion` phase):

```c
/* 0x0046BD73: a hit with damage */
if (absorberCharges(target)) {            /* 0x00475590: equip[18] ? unit[+0x3A] : 0 */
    damage = 0;                           /* xor ebp, ebp -- the argument, not the call */
    spendAbsorber(target);                /* 0x004755B0: --unit[+0x3A], behind the same flag */
}
applyDamage(target, damage, attackerFacing, &dealt);   /* 0x0046BD9D, and it still rolls */
if (unit->weapon == 0x2F && !absorberCharges(target) && target->hp) {   /* 0x0046BDAD */
    target->player = unit->player;        /* 0x0046BDCB */
    target->mp     = aGetMovePoints(target);   /* the Banner scan reads the NEW side */
    target->actionState = 0;              /* 0x0046BDE7, after the points were asked */
    aBuildVisibleMapForUnit(target, target->x, target->y, &saw);   /* 0x0046BDEB, §9.3 */
}
```

Four things that settles. The charges are read **behind `+0x33`**, which is
equipment slot 18 (`+0x21 + 18`, [`10` §5.4](10-lev-mission-format.md)): a
record whose equipment array does not carry the absorber has no charges
whatever the byte holds — the six placed aliens on `_C_119.lev` with a stale
123 or 126 there are refreshed only at their first hand-over, after the
human's first turn, and a shot in that turn goes through them (a probe with
`+0x3A` written to 5 and `+0x33` clear lost three hit points; with `+0x33`
written to 1 it lost none and one charge). A spent charge **zeroes the
argument and not the call**: `applyDamage` still runs and draws its dice
over a span of nothing, so the generator moves exactly as it does for a
landed hit — the seed read after the probe said two draws, and a model that
skipped the call said one. The charge test is asked **again** after the
spend, so a target whose last charge just went is converted on the same
shot. And the movement points are asked before the action state is cleared,
so a stunned target converts with none this turn. No shipped unit carries
weapon 47; the probe wrote the byte, the engine changed `+0x45` to 0 and
cleared `+0x41`, and the converted alien's own pass then revealed the two
other aliens it could see.

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
| damage absorber | equipment 18 fills `unit[+0x3A]`; a hit that would land spends one charge (`0x004755B0`) and **nullifies the damage** — by zeroing the argument, so `applyDamage` still rolls — and only while `+0x33` (equipment slot 18) is set: `0x00475590` returns 0 without it (§7.3). **`aExecuteBomb` never asks**: no call to either routine in `0x004702C0`, `applyDamage` is reached straight from the roll (`0x004704C9`) with the heading `0xFF` no octant's arc holds, so a mine meets the front armour |
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
switch (aRandom(0, 40)) {                 /* 0x0046D1D6 pushes 0x28 */
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

~~The roll is `aRandom(0, heat)`, so the *span* of outcomes is the weapon's own
heat cap. A weapon capped at 10 never rolls above 10 and can never destroy its
carrier; a cap of 31 or more can. The `Cooler` (equipment 19) doubles the cap
and therefore **widens the range of bad outcomes** — the item is not purely
protective.~~

**Corrected.** The span is the constant **40**, not the heat cap:
`0x0046D1D6` pushes `0x28` and `0x0046D1D8` pushes `0`. The cap appears only
in the gate on the line above. `0x0046D1E2` then rejects a roll above **30**
and `0x0046D1ED` indexes a 31-entry table at `0x0046D3D4` into the jump table
at `0x0046D3C4`, which is where the four arms come from:

| arm | rolls | at |
|---|---|---|
| 0 | 0–10 | `0x0046D1FA` — jam or damage, by weapon type |
| 1 | 21–24 | `0x0046D29B` — damage |
| 2 | 30 | `0x0046D2D8` — the carrier is destroyed |
| 3 | 11–20, 25–29, **and every roll above 30** | `0x0046D3B8` — `unit[+0x40] = 0` |

So **every weapon that can overheat at all can also be destroyed by it**, and
the `Cooler` does not widen the outcome range — it only makes the gate harder
to reach, which makes it purely protective after all. The `> 30` early-out
lands on the *same* instruction as arm 3, so it clears a previous jam rather
than leaving it standing.

Pinned natively (`tools/turn_gold.py`): eight probes at the cap, and the
model's roll, arm and resulting `+0x40` agree with the engine on all eight,
with the seed read after every call to confirm exactly one draw each. A ninth
probe one below the cap draws nothing and changes nothing, which is the gate.

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
scratch on every call — there is no incremental fog state to persist. The
contact promotion of §9.3 is the **per-unit** routine's tail and not this
one's, so a player with no living unit rebuilds to "all hidden" with no blips.
Three
unit types (`0x3D`, `0x3E`, `0x3F`) and everything of **species 2** are
permanently visible. `unitType[+0x79]` is `SetUnitInfo`'s *species* column
([`21` §5](21-info-lcl-schema.md)): `0` human, `1` alien, `2` inanimate object,
`3` machine. Species 2 covers the six scenery types — `Barrel`, `Parabomb`,
`Case`, `Concrete Block` — which are drawn as part of the map and therefore
never hidden, and which for the same reason award no experience (§7.5).

### 9.3 `aBuildVisibleMapForUnit(observer, x, y, *sawSomething)`

The observer is `observer`, **standing on `(x, y)`** — the cell is an
argument, and the routine reads the observer's record for nothing but its
player, its scanners and its height. `aBuildVisibleMap` passes the unit's own
cell; `aExecuteMove` passes the walk's destination before the first step. And
it **writes**: this is the only visible-map pass the engine has, there is no
query form, and every one of its six call sites changes `+0x4F` for good
(a byte sweep of the `call` encoding, the way §9.4's nineteen were found; `axt` after `aa` reports one of the six):

| Site | Caller | Observer, cell | Note |
|---|---|---|---|
| `0x004799D3` | `aBuildVisibleMap` §9.2 | each own unit, its cell | the whole pass |
| `0x0046E330` | `aExecuteMove` | the mover, the **destination** | before the first step; the *answer* is dropped when the destination's `+0x0C` is over 6 ([`42` §3.2](42-mission-presentation.md)), the writes never |
| `0x0046E385` | `aExecuteMove` | the mover, the **source** | computer movers only (`cmp byte [unit+0x45], 0xFF` at `0x0046E367`) |
| `0x0046EE55` | `aExecuteMove` | the mover, the arrival cell | after the walk, before the `MoveUnit` event, only while the mover lives |
| `0x0046BDEB` | `aAttackUnit` | the **converted** unit, its cell | weapon 47's arm (§7.3): the target's `+0x45` becomes the shooter's, its points are asked again, and it looks around for its new side. No shipped unit carries weapon 47 (§7.2); measured with the byte written (`turn_gold.py`, `weapon47`), modelled in both twins |
| `0x0047AF53` | `0x0047AD90`, `aUnitMap.cpp:5663` | the moved unit, its new cell | a unit relocated cell to cell — the map's link, `+0x42`/`+0x43`, the 3D object, then the pass. Its one caller is the platform ride (`0x00412F9A`, [`20` §7.4](20-lcl-language.md)), which relocates every rider this way **before** it copies the cells; measured directly and through the ride (`turn_gold.py`, `relocate` / `platform`), modelled as `Platform.relocate` / `Platform.ride` and `interact.relocate_unit` / `platform_ride` |

`aSetVisibleStateForUnit` itself has fifteen callers: **six** inside this
routine (the five of the sight and scanner arms and the promotion's at
`0x00479861`) and three inside `aBuildVisibleMap`, `aExecuteMove`'s mode-3
self-reveal (`0x0046E4BB`), the shooter and the target in `aAttackUnit`
(§7.1, §7.3), the target in `aExecuteBomb` (`0x004703A9`), and one in
`aAnimations.cpp` (`0x00411660`, the spawn of §9.4.2). The remake's `core`
carries every one of these that a turn can reach; what pins them is
`tools/ai_gold.py --check`, which since 2026-09-02 diffs `+0x4F` on all 200
records after both captured computer turns — the engine reveals four human
units in one and two in the other by walking, and a model without the walk's
passes fails on exactly those slots — and `tools/turn_gold.py --check`, whose
six `aExecuteMove` probes compare `+0x4F`, `+0x47` and `+0x48` of every live
record after each walk (nothing changes there: the player's mover sees nothing
new from its two-step path, so that capture pins the absence of a write rather
than one), and whose `reveal` phase, since later the same day, writes both
parties hidden and reads what each writer left: the shooter and its target
go to 0 and a jammed shot moves neither; a human relocated next to an alien
through `0x0047AD90` reveals it; a computer mover walking one step from a
cell the human sees comes out at 0 with the *Enemy Move* option written on
and — by its own arrival pass's promotion — at **1** with it written off,
while the human it saw is 0 either way.

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
alien. **It is this routine's own tail** — `0x00479786`..`0x00479861`, before
the `ret` at `0x0047989A` — and not `aBuildVisibleMap`'s, so every per-unit
pass runs it, `aExecuteMove`'s three included: a computer mover that walks
with the option off, and so is never marked visible, comes out of its own
arrival pass as a contact. Both models once kept the loop at the end of the
whole fog pass, where that walk left the mover hidden; the `mode3_off` probe
is what moved it (2026-09-02).

---

### 9.4 Nineteen rebuilds, of which four are **probes**

`aBuildVisibleMap` (`0x004798C0`) is called from **19** places, and the split
between them is the part a remake has to reproduce. Two helpers make it
visible:

| Address | What it does |
|---|---|
| `0x00479AA0` | copies all 200 units' `+0x4F` into the byte buffer at `0x51F1D8` |
| `0x00479AC0` | copies them back |

A call bracketed by that pair is a **question**; a call outside it changes the
fog for good.

> **The enumeration needed a byte sweep, not radare2.** `axt` after `aa`
> reports eight of the nineteen — it has no xref for a site in a function its
> analysis never reached — and an earlier revision of this section was written
> from that eight and got the shape of the rule wrong. `combat_tables.py`'s
> `fog.sites` sweeps the whole `.text` for the encoded `call` and compares an
> exact set; each of the nineteen was then confirmed by disassembling it.

| Address | Routine | Rebuilds for | Kind |
|---|---|---|---|
| `0x0040D6BD` | `aPlayFightAnimation`, `aAnimations.cpp:2752` — weapon 46's impact arm (§9.4.2) | current player | permanent |
| `0x00410C6A` | `aDoorOpenSequence` — the panel drops | current player | permanent |
| `0x00410D60` | `aDoorOpenSequence` — the panel rises | current player | permanent |
| `0x00412905` | `aPlayElevatorSequence`, `cpp:8215` | the rider's own player | permanent |
| `0x004130E6` | `aPlayPlatformSequence`, `cpp:8694` | the **selected** unit's player | permanent |
| `0x004149C7` | `0x004147D0`, `aAnimations.cpp:10602` — the **spore hatch**, not the statue (§9.4.3) | literal player 0 | permanent |
| `0x004419B6` | the `InsertUnit` handler | current player | permanent |
| `0x00441F55` | the `BuildVisibleMap` command | current player | permanent |
| `0x004490A9` | `aLoad.cpp:1649` | current player | permanent |
| `0x00457926` | the mission-control GUI build, `aMissionControl.cpp:4571` | current player | permanent |
| `0x0046F144` | `aExecuteWarp` (`0x0046EF50`) | **the warping unit's** `+0x45` | permanent |
| `0x0046F3A8` | `0x0046F210` `case 4`, `special` 9 ([`21` §5](21-info-lcl-schema.md)) | current player | permanent |
| `0x004781C6` | `refreshCurrentPlayer`, `aUnitMap.cpp:1240` | its own argument | permanent |
| `0x00478DE4` | `aTransferUnitFromPoolToMap` | current player | permanent |
| `0x0047DCCF` | `aNextPlayerHandling`, once per session, campaign only (§9.4.1) | literal player 0 | permanent |
| `0x0047CBED` | `aViewPlayer.cpp:1051` | own player | **probe** |
| `0x0047CF8B` | `aViewPlayer.cpp:992` | own player | **probe** |
| `0x0047CFB5` | `aViewPlayer.cpp:998` | `0x0043B2D0` | **probe** |
| `0x00481FE3` | `lNetwork.cpp:1461` | own player | **probe** |

`0x0043B2C0` is `aGetCurrentPlayer` (`0x00509E32`, the byte
[`25` §4](25-turn-and-round.md) rotates); `0x00436980` is the *own* player of
the network session, `-1` when there is none.

**Three of the fifteen do not rebuild for the player holding the turn**, and
the instruction immediately before each `call` is what says so.
`combat_tables.py`'s `fog.argument` pins all eighteen of those instructions.

* the **elevator** takes the rider's byte — `mov cl, byte [eax+0x45]` at
  `0x00412901`, where `eax` came from `aGetUnitMapElementPtr(cell[+0x07])` on
  the elevator's own tile at `0x004126B5`. An empty tile skips the call
  entirely (`je` at `0x004128FD`);
* the **platform** looks like the same thing and is not. `eax` there comes
  from `0x00471F70` (`0x00413098`), which is a three-line accessor over the
  globals `0x005162F8`/`0x005162FC`/`0x00516300` — the unit the *interface* has
  selected. A platform moved under somebody while a different unit is selected
  rebuilds for the selected one;
* the **spore hatch** and `aNextPlayerHandling` push a literal `0`
  (`0x004149C5`, `0x0047DCCD`).

### 9.4.1 The one-shot at the top of the hand-over

`0x0047DCA7`..`0x0047DCD4` runs once per session and is easy to miss, because
the hand-over's *own* rebuild is elsewhere and conditional:

```c
if (g_5229D0 == 0) {                    /* 0x0047DCAC */
    g_5229D0 = 1;
    resetPlayerRecords();               /* 0x0043B770 */
    if (gameMode() == 1)                /* 0x0043B740 -> 0x00509EE8; campaign */
        aBuildVisibleMap(0);            /* 0x0047DCCF */
}
```

`0x0043B770` walks the four player records of 40 bytes from `0x00509F48`.
**Its pointer runs at `record + 8`**, not at the record — it starts at
`0x00509F50` and the first store is `[eax-8]` — so the loop bound
`0x00509FF0` is `0x00509F48 + 40·4 + 8` and the six stores land on `+0x00`,
`+0x08`, `+0x10` and `+0x18` (all zero), `+0x20` (set to **1**) and `+0x24`
(a **byte**, zero). It then writes 0 into the turn counter and clears
game-control slots 10 and 11.

So the one-shot **does** clear the hero counter of §9.5 — `mov byte
[eax+0x1c], bl` at `0x0043B78C` is `record[+0x24] = 0`, at the same width the
counter is incremented — and a campaign's first turn starts on a fog pass for
player 0 rather than on the `+0x4F` bytes the `.lev` authored. A network
session gets neither.

**The latch is saved.** `0x00509F50`'s neighbour `0x005229D0` is not a
run-time-only global: `aSaveViewPlayer` (`0x0047DBE0`) and `aLoadViewPlayer`
(`0x0047DC20`) transfer `0x44C` bytes starting at it, so a save taken after
the first hand-over comes back with the one-shot already spent and the reset
does not run again over the loaded records. `0x0047BCD0` — two instructions,
`mov dword [0x005229D0], 0; ret` — is what puts it back for a new mission.

### 9.4.2 `aPlayFightAnimation`'s arm that spawns a unit

The impact switch in [`28` §8.1](28-effects-and-sound.md) is keyed on the
attacker's **weapon id** biased by 7 (`lea eax,[edx-7]` at `0x0040D4DF`), and
seventeen of its arms create a blob. One does something else: weapon **46**,
`Mine Thrower Enhanced`, selects `0x0040D65C`, which calls
`aGenerateUnitElement(aGetCurrentPlayer(), 0x18, "Spidy", 0, 0, x, y, 0)` —
unit type 24, `Spider` — then `aBlob_CreateLandingDust` and the permanent
rebuild at `0x0040D6BD`. The enhanced mine thrower does not lay a mine; it
lands a unit for the firing player.

**No shipped `.lev` can reach it.** Across the 155-mission corpus the placed
units carry weapon ids 0..29 only — nothing in 30..47, which is the half the
campaign armoury hands out — so the arm is reachable in a campaign and not
from authored data. `combat_tables.py`'s `spidy.arm`, `spidy.spawn`,
`spidy.unreachable` and `spidy.armoury_half` pin both halves of that.

### 9.4.3 The `0x004149C7` rebuild is the spore hatch, not `FixedStatue`

> **The routine boundary was wrong.** An earlier revision of this document
> attributed
> `0x004149C7` to `aPlayStatueSequence` and left the type it spawns open,
> because `[esp+0x40]` "cannot be resolved statically". The offset resolves
> perfectly well; it was measured against the wrong prologue.
> `aPlayStatueSequence` **is** `0x00414000` — its wrapper `0x00442370` pushes
> that name on the error path — but that routine **ends at `0x00414346`**,
> with its own jump table at `0x00414348` and the next routine at
> `0x00414360`. [`28` §2](28-effects-and-sound.md) had the split right all
> along: `aPlayStatueSequence 0x00414000` plays `stonefire.wav`, and
> `0x004147D0 (from 0x0046FC30 / 0x0046FC90)` plays `msqueether.wav`.

`0x004147D0` has no recoverable name — no `CHECK` call site pushes one for it —
so it is identified by what reaches it. Its frame is `sub esp, 0x24` plus
**three** saved registers, so the settled `esp` is `ret - 0x30` and the
arguments are at `+0x34`, `+0x38`, `+0x3C`; both epilogues free exactly `0x30`,
against `0x38` for `0x00414000`. `aGetCtrlMapElementPtr([esp+0x34],
[esp+0x38])` at `0x004147FF` fixes arguments 1 and 2 as `(x, y)`. At
`0x0041499F` exactly one push is in flight, so `[esp+0x40]` is `base + 0x3C` —
**argument 3**:

```c
aGenerateUnitElement(0xFF,            /* push 0xff  @0x004149B1 */
                     arg3,            /* push edx   @0x004149B0 -- the type */
                     (char *)0x004FA524,
                     0, 0, x, y, 0, &local);
aBuildVisibleMap(0);                  /* @0x004149C7 */
```

Nine arguments cleaned with `add esp, 0x24`, the same shape as the Spidy site
of §9.4.2, where `push 0x18` against `Spider` in `SetUnitInfo` is what pins
argument 2 as the unit type.

**Two call sites reach it, both LCL commands** ([`20`
§7.4](20-lcl-language.md)'s ActPt-range family):

| Command | Path | The type it spawns |
|---|---|---|
| `Spores (actPtMin, actPtMax, unitType)` | `0x00441FF0` → `0x0046FC30` → `0x004147D0` | the script's **third argument**, straight through (`push ebp` at `0x0046FC63`) |
| `MoveSpores (actPtMin, actPtMax)` | `0x00442570` → `0x0046FC90(…, 2)` → `0x004147D0` | the constant **50** (`push 0x32` at `0x0046FE14`) — `Ray'Ther` |

`0x0046FC30` sweeps the whole CtrlMap — 23 bytes a cell, `add esi, 0x17` — and
fires on every cell whose **action-point id** `+0x0B` ([`10`
§4.6](10-lev-mission-format.md)) falls in `[actPtMin, actPtMax]`. `0x0046FC90`
is one routine behind three commands, `MoveObjects` / `MoveFireCircles` /
`MoveSpores` with kind 0 / 1 / 2; only kind 2 reaches the hatch, and kind 1
reaches `0x004131C0`, the fire circle — which is exactly what the `FireCircle`
command itself calls, so the kinds and the names agree.

**What the corpus can actually hatch.** Three `Spores` calls ship, all in
`_C_174.lcl`: line 77 `Spores(100,102,66)`, line 93 `Spores(120,121,66)` and
line 99 `Spores(120,121,65)` — `Bea'Coo` twice and `Bea'Ther` once. The tags
they harvest are laid down by the same script: 100..102 by its `GrowingLand`
calls, and 120 by the `FallingSpores` on line 87 ([`20`
§7.4](20-lcl-language.md)). `MoveObjects`,
`MoveFireCircles` and `MoveSpores` are used **0 times** in the 177 shipped
scripts, so the constant-50 path is reachable only from a script nobody wrote,
and `Ray'Ther` is a possibility rather than an observation.

**And `FixedStatue` spawns nothing.** Sweeping `0x00414000`..`0x00414346` for
near calls finds neither `aGenerateUnitElement` nor `aBuildVisibleMap`; what it
does find is `aRemoveUnitElement` at `0x004142EC` — the statue *petrifies* a
unit, which is why §9.5's counter is in its call graph and a spawn is not. Nor
does anything reach `0x004147D0`, `0x0046FC30` or `0x0046FC90` through a
pointer: none of the three appears as a little-endian dword anywhere in the
image, so the two `call` sites above are the whole of it.

`combat_tables.py` pins all of this: `spore.frame` 10/10 (both prologues, both
epilogues, and the `aGetCtrlMapElementPtr` call), `spore.spawn` 8/8,
`spore.callers`, `spore.no_pointer` 3/3, `spore.arm` 23/23, `spore.dispatch`
10/10 (each handler and the name the dispatcher compares `0x36` bytes before
it), `spore.statue` 3/3, `spore.corpus_spores`, `spore.corpus_unused` 3/3 and
`spore.unit_type` 3/3.

### 9.5 The other thing `aRemoveUnitElement` does: the hero counter

`aRemoveUnitElement` (`0x004779C0`) is the routine every removal goes through
— `aKillUnit` (`0x00472920`) is a network message plus this call, and twenty
sites reach it. *(Corrected 2026-09-02: it carries no death sequence. What is
drawn when a unit dies — the object hidden in the same frame, a blood, debris
or fire effect chosen by species and class, the death scream — lives in
`aPlayFightAnimation`, [`42` §4.8](42-mission-presentation.md).)* Its middle third is not removal at all:

```c
al = unit[+0x4D];                      /* 0x00477A34 */
if (al >= 2 && getTurnCounter() != 0) {          /* 0x00477A3B, 0x0043B280 */
    rec = playerRecord(unit[+0x45]);             /* 0x0043BA00 */
    rec[+0x24]++;                                /* one byte: 0x00477A5C */
}
```

* `+0x4D` is [`10` §5.4](10-lev-mission-format.md)'s pool flag — 0 none, 1
  unit-pool candidate, 2 hero — and the test is `cmp al, 2` / `jb`, a **bound**
  and not an equality;
* the gate is the **turn counter** at `0x00509E1D`, the same byte
  [`25` §3.1](25-turn-and-round.md) uses to recognise the first hand-over, so a
  hero taken off the map before the first one does not count;
* `playerRecord` is `lea eax,[eax+eax*4]` then `lea eax,[eax*8 + 0x00509F48]`
  — base `0x00509F48`, stride 40 — the array §9.4.1's reset walks;
* the counter is **one byte**, incremented with `inc cl`, so it wraps at 256.

**What reads it is the LCL predicate `HeroKilled`.** `0x004409E0` is four
instructions — `playerRecord(g_50BEF8)[+0x24] != 0` — and its single caller is
`0x00444BA3`, immediately after the dispatcher compares the command name
against the string `"HeroKilled"` at `0x004C5818`
([`20` §7.4](20-lcl-language.md)). 75 of the 156 shipped scripts ask — including all
five the remake converts, and `_C_140`, where it is half of the defeat
condition. A remake that carried the
field and never wrote it answers *no hero has died* for the whole campaign.
`combat_tables.py`'s `hero.counter`, `hero.call`, `hero.predicate` and
`hero.predicate_name` pin the twelve bytes and the one call site.

#### The probe, and the half of it that is not put back

`0x00481F00` (`lNetwork.cpp:1461`) — which `aViewPlayer.cpp`'s command
dispatcher `0x0047DE90` calls at four sites, one of them immediately before
`aUI_MoveUnit` — is

```c
saveVisibility();                       /* 0x00479AA0 */
if (g_523FFC == 0)                      /* not a network session */
    aBuildVisibleMap(ownPlayer());
else
    fcn_00482210();
... look at cell (x, y) ...
restoreVisibility();                    /* 0x00479AC0 */
```

It answers "what is standing there, as the player can see it": 1 for a visible
unit, 2 for a special cell, 0 for neither. `0x0047C2C0` uses the same pattern
twice for the computer's turn.

**But the restore covers only half of what the pass wrote.** §9.1's
`aSetVisibleStateForUnit` writes the unit byte `+0x4F` *and* the 3D object's
`+0x40` — 1 solid, 3 blip, 2 absent — and the 200-byte buffer holds only the
first. The object flags keep the probe's answer. That is what makes an alien
appear the moment the squad walks into sight of it, while the AI and the
resolver go on reading a fog that the *permanent* sites moved.

Whether the asymmetry was intended is **UNVERIFIED** — it is equally consistent
with an oversight — but it is what the code does, and a remake that restored
both would freeze the picture until the turn changed, while one that restored
neither would let a probe rewrite the state the AI plans against.

#### The door, which is where "a use changes what the rules see" lives

The rebuild a use produces is **not** `aExecuteUse`'s: that routine calls
`aBuildVisibleMap` nowhere. It belongs to `aDoorOpenSequence` (`0x00410A20`),
the animation the use path drives, and it has two arms because a door is a
toggle:

```c
if (cell[+0x0B] & 1) {              /* odd ActPt: the door is closed */
    cell[+0x0D] = 1;  cell[+0x01] = 0;              ebx = -100;   /* opens */
} else {
    cell[+0x0D] = 2;  cell[+0x01] += 0xC80;         ebx = +100;   /* closes */
}
...
if (ebx <  0 && currentPlayer() != 0xFF) aBuildVisibleMap(currentPlayer());
if (ebx >  0 && currentPlayer() != 0xFF) aBuildVisibleMap(currentPlayer());
```

Both arms rebuild, each on its own side of the sign, and **both refuse while
the computer holds the turn** — a door the computer opens leaves the fog until
the hand-over. `combat_tables.py`'s `door.fog` pins the six bytes that say so.

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
     and, for a cell whose marker is 0x5D:
         └─ aKillUnit
             └─ aRemoveUnitElement   free the record; count the hero (§9.5)

aBuildVisibleMap(player)             15 permanent sites; probed per command (§9.4)
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
| `opt.defaults` | re-executing `aInitOptions`' default block yields exactly the eleven values [`20` §7.6](20-lcl-language.md) tabulates |
| `opt.dead`, `opt.name_field` | every `.text` reference to `Game.opt` +0x08 and +0x10 is enumerated — one each, both the `aInitOptions` write itself — and the player name at +0x2C has its copy and its getter |
| `special.sites` | the eleven `.text` sites that touch `unitType[+0x07]` are exactly the ones [`21` §5](21-info-lcl-schema.md) accounts for |
| `rng.private` 2/2 | in both `Incubation.exe` and `iDesigner.exe`, every reference to the RNG's four globals lies inside `aRandom`/`aRandomize` |
| `fog.sites` | the `.text` sweep finds exactly the 19 `aBuildVisibleMap` call sites §9.4 tabulates — a twentieth is a failure |
| `fog.saves`, `fog.restores` | and exactly the three save and six restore sites that make four of them probes |
| `door.fog` 6/6 | `aDoorOpenSequence`'s two arms, their opposite sign tests, and the `!= 0xFF` guard both carry |
| `hatch.arm` 12/12, `hatch.call` 2/2 | every immediate of `0x0046F210`'s `case 4` — `special` 9, the five-hit-point bound, the weapon types {1, 2, 4}, the replacement's type and player, the inherited group — and the two calls that follow it |
| `fog.argument` 18/18 | the instruction before each of the other ten permanent `call`s, which is what says **whose** fog each one moves (§9.4) |
| `fog.player_record` 8/8 | `0x0043BA00`'s two `lea`s and the reset loop's six instructions: base `0x00509F48`, stride 40, four records, a pointer at `record + 8`, and `+0x24` cleared as a byte |
| `fog.view_player_block` 3/3 | both sides of the `0x44C`-byte block at `0x005229D0`, i.e. the one-shot latch is saved and restored, and the two-instruction reset that starts a new mission |
| `hero.counter` 12/12 | the whole of §9.5 — the `+0x4D` bound, the turn-counter gate, the byte-wide increment, and the predicate's `setne` |
| `hero.call` 3/3, `hero.predicate` | the counter's two calls, and that `0x004409E0` has exactly one caller |
| `hero.predicate_name` | the string that caller compares immediately before it is `"HeroKilled"` |
| `spidy.arm`, `spidy.spawn` 4/4 | weapon 46's impact arm is `0x0040D65C`, and it pushes type `0x18` with the name `"Spidy"` (§9.4.2) |
| `spidy.unreachable`, `spidy.armoury_half` | no placed unit in the corpus carries weapon 46, and none carries anything above 29 |
| `spore.frame` 10/10 | `0x004147D0` saves three registers and frees `0x30`, `0x00414000` saves four and frees `0x38` — the boundary §9.4.3 turns on |
| `spore.spawn` 8/8 | the nine-argument `aGenerateUnitElement` at `0x004149BD`, including `mov edx,[esp+0x40]` and `push 0xff` |
| `spore.callers`, `spore.no_pointer` 3/3 | `0x004147D0` is called from exactly `0x0046FC66` and `0x0046FE18`, and neither it nor its two callers appears as a dword anywhere in the image |
| `spore.arm` 23/23 | both paths byte for byte: `Spores`' three argument globals and the CtrlMap sweep, and the three `Move*` kinds with `push 0x32` on kind 2 |
| `spore.dispatch` 10/10 | each of the five commands calls the handler this document names, and the string the dispatcher loads `0x36` bytes earlier is that command's name |
| `spore.statue` 3/3 | `aPlayStatueSequence` calls neither `aGenerateUnitElement` nor `aBuildVisibleMap`, and does call `aRemoveUnitElement` |
| `spore.corpus_spores`, `spore.corpus_unused` 3/3 | the three shipped `Spores` calls parse to exactly `(100,102,66)`, `(120,121,66)`, `(120,121,65)` in `_C_174.lcl`, and the `Move*` trio is unused |
| `spore.unit_type` 3/3 | 50, 65 and 66 are `Ray'Ther`, `Bea'Ther` and `Bea'Coo` in `Info.lcl` |

`tools/trace_names.py --check gog_incubation` re-derives the symbol table and
asserts the ten names §1.1 depends on.

---

## 12. Open questions

**None.**

1. ~~**What the unit pool draws the uncounted stream for.**~~ **Closed** —
   §3.2. All three sites do the identical thing: `aRandom(1, 6)`, `__ftol`,
   and one **byte** store, and the byte is `unit[+0x55]` — the **speech-set
   id** [`20` §7.4](20-lcl-language.md) and [`21` §5](21-info-lcl-schema.md)
   already decode, which of the shipped `Waves/Speech/` voice sets the
   recruited soldier talks with. [`10` §5.8](10-lev-mission-format.md) already
   recorded that the value was rolled; what was missing was *which generator*,
   and it is the presentation one. Nothing in the rule set reads the byte, so
   §3.1's determinism argument is not disturbed.

   Two details worth keeping. `aGenerateUnitElement` **does not roll for unit
   type 24**: it writes a fixed 12, which is `spidy`, the only non-human set in
   that table. And the roster the other two write into is **saved**
   ([`11` §5.11](11-save-game-format.md)), so a clock-seeded byte does reach
   the save file — a remake must keep it out of a canonical hash rather than
   out of the save.

   The fourth caller, `0x004160F0`, is not a counter-example either. It is in
   `aAnimations.cpp` and does two jobs: it draws **twice from the counted
   stream** for a candidate spawn tile, retried up to five times and tested by
   the placement helper — simulation, on the gameplay generator — and **once
   from the uncounted one** for an argument it hands to a routine inside
   `aBlobs.cpp` — an effect, on the presentation generator. One function doing
   both jobs is not one function mixing generators: the split is kept inside
   it, argument by argument. Fourteen checks in `blob_tables.py`.

The question this section used to carry — what type `FixedStatue`'s sequence
spawns — is closed in §9.4.3, and the honest form of the close is that the
premise was wrong: the site belongs to the spore hatch, `FixedStatue` spawns
nothing, and the type is `Spores`' own third argument or the constant 50.

The three questions this document opened are closed below, each in the place
the evidence belongs.

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
   enumerated and they all lie inside `aRandom`/`aRandomize`. §3.2 sharpens
   this rather than disturbing it: the second stream does not keep counters at
   all, which is the one behavioural difference between two otherwise
   byte-identical bodies.

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

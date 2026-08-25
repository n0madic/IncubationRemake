# Interaction and set-pieces — using the world

[`10` §4.6](10-lev-mission-format.md) recovered the developers' own names for
38 action-point values, so we know what every cell *is*. This document is the
other half: what happens when a unit uses one.

**Everything below is one function and its gate.** `aExecuteUse` `0x0046DC60`
— its own `CHECK` site names `aTacTools.cpp`, line 4879 — is a single `switch`
over the cell's action-point byte, so the list of interaction classes is not
inferred: it is read straight out of the compiler's own tables, a 60-byte index
table at `0x0046E1DC` and an 18-entry jump table at `0x0046E194`.

Two bytes of the cell record carry interaction, and a remake needs both:
`+0x0B`, the **action point** ([`10` §4.6](10-lev-mission-format.md)), and
`+0x0D`, the **field type** ([`10` §4.1](10-lev-mission-format.md)).
Teleporters and ladders are field types, not action points; doors, boxes,
levers and entry points are action points. A third carrier, the runtime
effect object at `+0x10` ([`23` §7.1](23-ai-system.md)), makes a cell a mine.

**On names.** Ten of the routines below carry the developers' own `CHECK` name
(`tools/trace_names.py`, [`22` §1](22-combat-and-visibility.md)):
`aExecuteUse`, `aExecuteTeleporter`, `aExecuteMove`, `aExecuteWarp`,
`aExecuteBomb`, `aBuildMoveMap`, `aDoorOpenSequence`, `aPlayUseLeverSequence`,
`aPlayDestryoEntrypointSequence` and `aPlayDestroyMineSequence`. Every other
identifier in the C blocks is a **descriptive label, not a recovered symbol**,
and each is given with its address so the label never has to be trusted.

The *scripted* half of interaction — `Platform`, `Elevator`, `Bridge`,
`OpenDoor`, `Statue`, `FootBridge`, `Barrier`, `CrushWall` — is a set of LCL
commands and is specified in [`20` §7.3](20-lcl-language.md). This document
does not repeat it; it describes what the engine does **without** a script, and
where the two meet.

---

## 1. The unit command pad — **[code] `0x00472120`**

Use is one of six unit commands. `0x00472120(column, row)` maps a position on
a 3 x 2 button pad onto a command id; the routine is one `sub`/`dec` ladder per
axis with a three-instruction leaf per cell, so the whole pad is readable:

| | row 0 | row 1 |
|---|---|---|
| **column 0** | `1` mark reaction fire ([`25` §6](25-turn-and-round.md)) | `3` spend a stimulant ([`25` §8](25-turn-and-round.md)) |
| **column 1** | `2` heal — the two medic kits, [`21` §3](21-info-lcl-schema.md) | `7` stand down ([`25` §8](25-turn-and-round.md)) |
| **column 2** | `5` toggle weapon mode ([`25` §7](25-turn-and-round.md)) | **`8` use** |

`0x00472570` decides whether a command is offered and `0x00473250` executes it.
Move and attack are not on the pad — they are map clicks
([`20` §5](20-lcl-language.md) names their two host paths).

### 1.1 What Use costs

`0x00473250`'s arm for command 8 is short enough to quote:

```c
case 8:                                     /* 0x004734C0 */
    aExecuteUse(u);                         /* 0x0046DC60 */
    if (u->hp == 0) { Deselect(); return 1; }   /* it may have killed him */
    if (u->mp != 0) u->mp -= 1;
    u->acted = 3;                           /* unit[+0x39], docs/10 §5.2 */
    return 1;
```

**A use costs exactly one movement point**, whatever it was — opening a door,
picking a box up, pulling a lever, pushing a barrel four fields, blowing an
entry point. The `hp == 0` test is not defensive: a unit can die inside its own
use, by pushing a crate onto a mine or by stepping into a blocked teleporter
(§5), and a dead unit is not charged.

### 1.2 What Use requires

Two gates in `0x00472570`, before any target is looked at:

| Gate | Where | Rule |
|---|---|---|
| species | `0x00472697` | `unitinfo[type].species != 3`. Species 3 is **machine** ([`21` §5](21-info-lcl-schema.md)); the two machine types may not use anything. Stand down carries the same gate |
| movement | `0x004726A5` | `unit[+0x15] != 0` — a unit with no movement points left cannot use |

---

## 2. What may be used — **[code] `0x0047A530`** and three more predicates

The Use button lights when **any** of four predicates accepts the situation.
All four look at the same cell — the one **directly in front of the unit**,
found with `0x004308C0(facing, x, y)`, the neighbour-by-direction helper. There
is no reach and no selection: a unit uses what it is facing.

| # | Predicate | Accepts |
|---|---|---|
| 1 | `0x0047A530` | an **empty** cell whose action point is in `10 … 49`, with two exceptions below |
| 2 | `0x0047B250` | a cell holding a **pushable object** — §4 |
| 3 | `0x0047B410` | a cell whose action point is **70**, when the unit's `FP` byte `+0x19` is non-zero and it carries equipment 9 (`Explosion Pack`) |
| 4 | `0x0047B480` | a cell whose `+0x10` is `2` — a **mine** |

Predicate 1 is the interesting one, and it is four comparisons:

```c
int useTarget(unitIndex, int *outX, int *outY)          /* 0x0047A530 */
{
    cell = CellInFront(u);
    if (cell == NULL || cell->unit != 0xFFFF) return -1;
    ap = cell->actionPoint;                             /* 0x0047A5BD */
    if (ap < 10 || ap > 49)                   return -1;
    if (ap == 33 && u->equip[17] != 1)        return -1;  /* jammed, closed */
    if (ap == 32)                             return -1;  /* jammed, open   */
    *outX = cell->x; *outY = cell->y;
    return ap;
}
```

Three things fall out of it.

**The band is 10 … 49, not the set the switch handles.** Ids 19–29, 34, 35 and
43–49 are *offered* to the player and have no engine effect at all: pressing
Use on them does nothing but fire the LCL `Use` event (§6). That is the
mechanism behind buttons and every mission-specific gadget.

**Equipment 17 is the key to jammed doors.** `unit[+0x32]` is equipment slot
17, `Hydraulic Crowbar` ([`10` §5.4](10-lev-mission-format.md),
[`21` §3](21-info-lcl-schema.md)); without it a *jammed Door — CLOSED* is not
usable. The corpus agrees: action point 39, the crowbar pickup, appears in
`_C_141` and `_C_142`, and `_C_142` is also one of the two missions carrying
jammed doors.

**A jammed door opens once.** Id 32, *jammed Door — OPEN*, is refused
unconditionally, and the toggle (§3) turns 33 into 32 when it opens. A jammed
door can therefore be pried open and never closed again — which is exactly why
[`10` §4.6](10-lev-mission-format.md)'s census finds **0** cells with id 32:
the value only ever exists at runtime.

---

## 3. The dispatch — **[code] `0x0046DC60`**

```c
BOOL aExecuteUse(Unit *u)                               /* 0x0046DC60 */
{
    cell = CellInFront(u);                                     /* 0x004308C0 */
    if (cell == NULL)              return 0;
    if (cell->unit != 0xFFFF)      return pushObject(u);        /* 0x0046D530, §4  */
    if (cell->effectState == 2)    return defuseMine(u);        /* 0x0046DB80, §4.1 */
    if (cell->actionPoint == 10)                               /* random box */
        cell->actionPoint = aRandom(11, 3);
    switch (cell->actionPoint) { … }                           /* §3.1 */
    …the LCL Use event, §6…
}
```

Note the two early returns: **a push and a mine defuse never reach the LCL
event.** Only the action-point classes do.

`aRandom(base, span)` returns `base … base+span−1`
([`22` §3](22-combat-and-visibility.md)), so the *random* supply box, id 10,
rolls into exactly three outcomes — **11, 12 or 13**: nothing, full munition,
or 50 equipment points. The roll is written back into the cell before the
switch runs, so the box's identity is fixed the moment it is opened. Only one
cell in the corpus carries id 10, and it is in `_C_XXX.lev`, the editor's
template map: **no shipped mission contains a random box.**

### 3.1 The class table

The `switch` biases by −11 and bounds at 59, so it covers ids **11 … 70**;
everything outside, and every id inside that the index table sends to slot 17,
falls to the default arm at `0x0046E126`, which is the LCL event and nothing
else. Seventeen arms handle twenty ids:

| id | Legend name ([`10` §4.6](10-lev-mission-format.md)) | Text | Cell becomes | Effect | Cells |
|---|---|---|---|---|---|
| 11 | nothing | `E0` | 0 | — (and no voice line) | 2 |
| 12 | full munition | `E1` | 0 | `unit[+0x3D]` = the weapon's magazine, doubled by equipment 6 | 160 |
| 13 | equipmentpoints 50 | `E2` | 0 | game-control slot 10 += 50 | 169 |
| 14 | light/heavy weapon | `E3` | 0 | `LW` and `HW` += 1, each capped at 6 | 7 |
| 15 | condition | `E4` | 0 | `CON` += 1, capped at 6 | 8 |
| 16 | technical | `E5` | 0 | `TS` += 1 — **guarded on `CON`**, see §3.3 | 4 |
| 17 | equipmentpoints 20 | `E6` | 0 | game-control slot 10 += 20 | 93 |
| 18 | equipmentpoints 10 | `E7` | 0 | game-control slot 10 += 10 | 40 |
| 30 | standard Door — OPEN | — | 31 | the toggle, §3.4 | 17 |
| 31 | standard Door — CLOSED | — | 30 | the toggle | 278 |
| 32 | jammed Door — OPEN | — | 33 | the toggle — unreachable, §2 | 0 |
| 33 | jammed Door — CLOSED | — | 32 | the toggle, with a crowbar | 8 |
| 36 | lever up | — | 37 | `aPlayUseLeverSequence(…, 0, …)` | 70 |
| 37 | lever down | — | 36 | `aPlayUseLeverSequence(…, 1, …)` | 1 |
| 38 | absorber | `E8` | 0 | equipment 18 + `unit[+0x3A] = 4` (four charges) | 13 |
| 39 | crowbar | `E9` | 0 | equipment 17 | 3 |
| 40 | cooler | `EA` | 0 | equipment 19 | 6 |
| **41** | *(absent from the legend)* | `EB` | 0 | **nothing** — §3.2 | 1 |
| 42 | explosionpack | `EC` | 0 | equipment 9 | 5 |
| 70 | entry point | — | 71 | `0x0042F840(x, y, 6, height − 0xA0)` sets the cell on fire ([`23` §7.1](23-ai-system.md)), then `aPlayDestryoEntrypointSequence` | 209 |

The `Text` column is a two-character label into
`DATA/TXT/<lang>/Info/Events.txt` ([`24` §7](24-briefing-text.md)). The arm
hands the two characters to the shared pickup sequence `0x00410780`, which
opens the file by its literal name `"Events"`, draws the box through
`aActivateInfo` `0x0043E740` and plays `box.wav`. Twelve of the thirteen also
play unit speech event 9 (`0x0047B660`); **id 11 does not** — "Found nothing"
gets no voice line.

The four equipment ids the pickups grant are 9 `Explosion Pack`, 17 `Hydraulic
Crowbar`, 18 `Damage Absorber` and 19 `Cooler`. Three of them — 17, 18, 19 —
require **tech level 99** in `SetEquipInfo` ([`21` §3](21-info-lcl-schema.md))
and no shipped mission header sets a tech level above 12, so those three cannot
be bought at all: the map is the only way to get them. Game-control slot 10 is
the mission's equipment-point bonus ([`20` §5.3](20-lcl-language.md)).

**The two ids the picker legend calls buttons — 34 and 35 — are not in the
table.** They are inside `0x0047A530`'s band, so the button lights and the
LCL event fires, but the engine writes nothing. Every button in the game is
therefore script state: `_O_003.lcl` keeps a button's position in an unrelated
cell through `GetActPt`/`SetActPt` and never touches the button itself.

### 3.2 Action point 41 is *Batteries*

The picker legend skips 41 ([`10` §4.6](10-lev-mission-format.md) notes the
gap), but the switch handles it and `Events.txt` names it:

```
{:EB}Examine...
Found Batteries
  +1 Batteries
```

Its arm shows the message, plays the voice line and clears the cell — and
touches no unit field at all. **Batteries is a pickup that was authored, wired
up and left inert.** One cell in the corpus carries it, in `_C_148.lev`.

### 3.3 The *technical* supply box is a copy-paste bug — **[code] `0x0046DF3B`**

The three implant boxes share one shape, and the third one's guard was not
updated. Byte for byte:

```
id 15, "condition"            id 16, "technical"
8a 43 1a  mov al,[ebx+0x1A]   8a 43 1a  mov al,[ebx+0x1A]   <-- CON
3c 06     cmp al,6            3c 06     cmp al,6
0f 83 …   jae skip            0f 83 …   jae skip
fe c0     inc al              fe 43 1d  inc byte [ebx+0x1D] <-- TS
88 43 1a  mov [ebx+0x1A],al
```

`+0x1A` is `CON` (*Battle Fitness*) and `+0x1D` is `TS` (*Technical Skills*)
([`10` §5.3](10-lev-mission-format.md)). The box therefore raises Technical
Skills — which is what its own text says, *"+1 Technical skills"* — but only
while the unit's **Battle Fitness** is below 6, and it can push `TS` past 6
without limit. Id 14 does its two skills correctly, each guarded on itself.

The behaviour is the one described here; the intent is plainly `TS < 6`. Four
cells in the corpus carry id 16, and the remake's call is settled: reproduce
the original by default, expose the correction as a setting
([`92` §7](92-remake-architecture.md)).

### 3.4 Doors — **[code] `0x00410A20`**

One toggle serves all four door ids, and it keys on the **low bit** of the
action point:

```c
if ((cell->actionPoint & 1) == 0) {         /* even: 30, 32 -> it is open */
    cell->height      += 0xC80;             /* one tile, docs/10 §4 */
    cell->actionPoint += 1;                 /* 30 -> 31, 32 -> 33 */
    cell->fieldType    = 2;                 /* Wall */
    landObject->z     += cell->height;
} else {                                    /* odd: 31, 33 -> it is closed */
    cell->fieldType    = 1;                 /* Free Place */
    cell->actionPoint -= 1;                 /* 31 -> 30, 33 -> 32 */
    cell->height       = 0;
    landObject->z      = 0;
}
```

A door is a wall panel that rises out of the floor: closing it raises the cell
by exactly one tile and makes it a `Wall`; opening it drops the cell to height
0 and makes it a `Free Place`. Nothing in the toggle distinguishes the jammed
pair from the standard pair — the difference lives entirely in
`0x0047A530` (§2). Opening also rebuilds the visible map
([`22` §9](22-combat-and-visibility.md)) — but only when the current player is
not the neutral pseudo-player — because a door that opens changes what everyone
can see.

`0x00410A20` has exactly three callers: the AI (§7), the LCL `OpenDoor` command
([`20` §7.3](20-lcl-language.md)), and the player's Use arm through the
one-line wrapper `0x0046D170`.

---

## 4. Pushing an object — **[code] `0x0046D530`**

When the cell in front holds a **unit**, Use pushes it. `0x0047B250` decides
whether it may move:

* the occupant's **type** must be one of `30`, `32`, `33`, `34`, `35` —
  `Barrel`, `Case`, `Barrel`, `Barrel`, `Concrete Block`
  ([`21` §5](21-info-lcl-schema.md)). `31`, `Parabomb`, sits in the middle of
  that run and is **not** in the list;
* the destination must not be a `Wall`, must not be higher than the source
  cell, and must be empty;
* for a **diagonal** push (facings 4–7, [`10` §5.10](10-lev-mission-format.md))
  the two flanking neighbours are tested as well; for an orthogonal push only
  the straight one is.

The executor then slides the object one cell at a time, re-testing before each
step, up to **four cells**:

```c
for (n = 4; n > 0; n--) {
    if (!canPush(x, y, u->facing)) break;      /* 0x0047B250 */
    …move the object one cell, four interpolation frames…
    if (destination->effectState == 2) {           /* a mine */
        …free the mine object, aExecuteBomb(x, y)… /* 0x004702C0 */
        break;
    }
    if (fieldType(destination) == 4 || fieldType(destination) == 3) {
        …50 steps of z -= 0x140, then removeUnit(x, y)…  /* it falls in */
        break;
    }
}
```

So an object can be pushed onto a mine (which detonates as a weapon-36
`ParaBomb` shot centred on the cell) or into a `Hole` / `Deep Hole`, where it
falls out of the world. Both are ordinary ways to clear a barrel, and both can
kill the pusher — which is what §1.1's `hp == 0` test is for.

### 4.1 Defusing a mine — **[code] `0x0046DB80`**

When the cell in front carries a mine (`+0x10 == 2`), Use removes it: the
runtime effect object is freed, `+0x10` goes back to `0xFF`, `+0x0E` to 0, and
`aPlayDestroyMineSequence` runs. Nothing explodes, and the LCL event does not
fire. Mines that are *stepped* on rather than defused are §6.1.

The push and the defuse are the two branches `aExecuteUse` takes before it ever
looks at the action point, which is why neither reaches the script.

---

## 5. Teleporters — **[code] `0x00470150`**

Teleporters are **field types**, 9 (`Teleporter Entry`) and 10
(`Teleporter Exit`), and they are not a use at all: `aExecuteMove` breaks out
of its walk the moment the unit steps onto a cell of field type 9
(`0x0046EA73`) and calls `aExecuteTeleporter`.

The pairing rule is the one thing a remake has to get right, and it is four
instructions:

```c
key = entry->actionPoint;                       /* 0x00470199 */
for (i = 0; i < cellCount; i++)                 /* row-major, stride 23 */
    if (cells[i].fieldType == 10 && cells[i].actionPoint == key) break;
if (i == cellCount) return 1;                   /* no exit: nothing happens */
if (cells[i].unit != 0xFFFF) {                  /* the exit is blocked */
    addLoss(u);           /* 0x0043B8D0 -- the scoreboard's Losses pair */
    removeUnit(entry->x, entry->y);             /* 0x004779C0 */
    u->hp = 0;                                  /* the traveller dies */
    return 1;
}
…move the unit link, update u->x/u->y, aPlayTeleporterSequence…
```

**An entry and an exit are paired by their action-point byte**, and the exit is
found by a linear scan from cell 0 — so with two exits sharing a key, the one
earliest in row-major order wins. The action point is being used purely as a
name here, which is why the teleporter maps carry ids 100–108, well outside
every band the legend names.

**Stepping into a teleporter whose exit is occupied kills the traveller.** The
loss is booked into the scoreboard's Losses pair ([`11` §5.5](11-save-game-format.md))
through `0x0043B8D0`.

### 5.1 The corpus, and one authoring bug

Seven shipped maps carry teleporters: 22 entries and 20 exits.

| Map | entry key → exit key |
|---|---|
| `_C_156` | 101 ×2 → 101, 102 → 102, 103 → 103, **104 → none** |
| `_C_157` | 100 → 100, 101 → 101 |
| `_C_161` | 101 → 101, 102 → 102 |
| `_C_162` | 101 … 108, all eight paired |
| `_C_164` | 101 → 101, 102 ×2 → 102 |
| `_O_051` | 100 → 100 |
| `_O_052` | 101 → 101 |

**21 of the 22 entries reach an exit.** The exception is `_C_156`'s key-104
entry: the map has a fourth exit cell, but its action point was left at 0, so
the scan finds nothing and the entry is inert. Two entries sharing one exit
(`_C_156` key 101, `_C_164` key 102) is legal and works — the rule is
many-to-one.

Field type 8, `Ladder`, has **0 cells in the shipped campaign**, so the
ladder-to-ladder rule that [`23` §7.4](23-ai-system.md) reads out of
`aBuildMoveMap` never fires. `aExecuteMove` reads the field type exactly three
times — twice for the movement delay and once for the `== 9` teleporter test —
so it has no ladder case of its own. **UNVERIFIED:** a ladder step should
therefore be *offered* only from a full movement allowance and then be charged
like any other step. The inference is from an enumerated absence — three field
type reads, none of them 8 — not from observation, and with no ladder cell in
the corpus nothing can exercise it. See §10 item 5.

---

## 6. The LCL `Use` event — **[code] `0x0046E126`**

Every action-point class, handled or not, ends in the same four calls:

```
SetEnvVar('A', 4);                  /* call type Use, docs/20 §5 */
SetEnvVar('B', cellX);
SetEnvVar('C', cellY);
SetEnvVar('D', cell->actionPoint);  /* 0x0046E152 -- read HERE */
RunMissionProgram();
```

[`20` §5](20-lcl-language.md) tabulates the call-type contract. What it does
not say, and what a remake will get wrong by default, is **when `_D` is read**:
`0x0046E152` loads `cell[+0x0B]` *after* the switch has already rewritten it.
A script that sees `_D == 37` was triggered by a lever that read 36 a moment
earlier.

Two independent lines of evidence:

* the load sits at `0x0046E152`, past the last case arm (`0x0046E126`), and
  every arm that changes the cell does so before jumping there;
* `_O_066.lcl` pairs two levers per elevator and mirrors them:

  ```
  >EnvVarCmpNum (_B,11); &EnvVarCmpNum (_C,11); &EnvVarCmpNum (_D,36);
      Elevator (11,10,0,7);
      SetActPt (12,11,36);        * the partner lever, set to what _D showed
  <
  ```

  If `_D` were the pre-mutation value the two levers would end in opposite
  states after one pull. They do not, because the used lever has already become
  37 and the partner is being set to 36 — the same state, seen from the other
  side.

Across all 153 shipped mission scripts, `:Use` compares `_D` against **exactly
four values: 34, 35, 36 and 37** — the two buttons the engine ignores and the
two levers it toggles. Nothing else is ever tested, and the sections issue 226
`SetActPt` calls, which is how missions keep gadget state that the engine has
no opinion about.

### 6.1 Interaction on the movement path

Two more things happen while walking, both inside `aExecuteMove`
(`0x0046E220`).

**Mines.** After each step the engine looks for `+0x10 == 2`. A **small** unit
(`unitinfo[type].size == 0`, [`21` §5](21-info-lcl-schema.md)) only sets off
the mine it is standing on; a **large** one sets off a mine on any of its eight
neighbours, through `0x0047A4B0`. Either way the unit's movement points are
zeroed and the mine resolves as a shot from weapon **36**, `ParaBomb`
(`aExecuteBomb` `0x004702C0` → `0x0046AA10`) — 100 damage at 100 hit
([`21` §4](21-info-lcl-schema.md)).

**VictoryPoints.** Stepping onto a cell in the band 80–89 claims it:

```c
if (ap >= 0x50 && ap <= 0x59 && u->player != 0xFF) {
    if (ap <= 0x54) cell->actionPoint = 0x51 + u->player;   /* A: 81 … 84 */
    if (cell->actionPoint >= 0x55 && cell->actionPoint <= 0x59)
                    cell->actionPoint = 0x56 + u->player;   /* B: 86 … 89 */
}
```

That closes [`10` §4.6](10-lev-mission-format.md)'s last gap: ids 86–89,
*VictoryPoint B — player 1 … 4*, have **0 cells** in the corpus because they
are written on capture and never authored. Player 255, the neutral
pseudo-player ([`23` §9](23-ai-system.md)), captures nothing.

---

## 7. What the computer does — **[code] `0x0040A600`**

The AI's entire interaction with the world is thirty lines.

[`23` §2](23-ai-system.md) calls `0x0040A600` *the door opener*; that is the
whole of it, and it has no `CHECK` name of its own:

```c
BOOL doorOpener(Unit *u)                        /* 0x0040A600, aAISystem.cpp */
{
    if (u->hp == 0 || u->mp < 2) return 0;
    for (dir = 0; dir <= 7; dir++) {            /* all eight neighbours */
        cell = Neighbour(dir, u->x, u->y);
        if (cell && cell->actionPoint == 31) {  /* standard Door — CLOSED */
            u->facing = Heading(u->x, u->y, cell->x, cell->y);  /* 0x0046A760 */
            aDoorOpenSequence(cell->x, cell->y, u->x, u->y);
            u->acted = 3;
            u->mp   -= 1;
            return 1;
        }
    }
    return 0;
}
```

**The computer opens standard closed doors and uses nothing else.** It picks up
no supply box, pries open no jammed door, pulls no lever, pushes no crate,
defuses no mine and blows no entry point. This is an enumerated claim, not an
impression, and it is checked in two links: `aExecuteUse` has exactly **one**
caller in the whole image, `0x004734EA` inside the command executor
`0x00473250` (`ai.no_use`), and that function has exactly two callers,
`0x00471324` and `0x0047E4F2`, both inside `aUI.cpp` / `aViewPlayer.cpp`
(`gate.callers`, `gate.callers_are_interface`). Neither link passes through the
AI module.

**§6.1 is the exception, and it is not a use.** Mines, teleporters and
VictoryPoints live in `aExecuteMove`, which both hosts share
([`20` §5](20-lcl-language.md)), so a computer unit that walks onto a mine sets
it off, one that walks onto a teleporter entry is teleported, and one that
walks onto a VictoryPoint claims it — the AI's own move map does not exclude
any of them. What it never does is press the Use button.

Two differences from the player worth reproducing: the door opener scans **all
eight** neighbours where the player is restricted to the cell it faces, and it
needs **two** movement points to try while spending one.

---

## 8. What a remake must implement

1. The 3 x 2 command pad and its two gates (§1). Use costs one movement point
   and sets the "has acted" byte.
2. `0x0047A530`'s band `10 … 49`, the crowbar exception for id 33, the flat
   refusal of id 32, and the three extra target predicates (§2).
3. The twenty-id class table (§3.1) — including the `technical` box's guard bug
   and `Batteries`' inertness. Both are **decided**: the remake reproduces them
   by default and offers the `technical` correction as a setting
   ([`92` §7](92-remake-architecture.md)).
4. The random box: `aRandom(11, 3)`, resolved and written back before the
   effect runs (§3).
5. The door toggle as a parity rule on the action point, with the one-tile
   height change and the field-type flip (§3.4).
6. The four-cell push with its mine and hole outcomes (§4).
7. Teleporter pairing by action-point key, first match in row-major order, and
   death on a blocked exit (§5).
8. The `Use` event with `_D` read **after** the mutation (§6) — otherwise every
   lever in the game drives its set piece backwards.
9. Mines and VictoryPoints on the movement path (§6.1).
10. The AI's single interaction (§7).

Everything the LCL side does — the platforms, elevators, statues, bridges,
barriers and the `CrushWall` — is already specified in
[`20` §7.3](20-lcl-language.md) and needs no work here.

---

## 9. Verification

`tools/interaction_tables.py --check gog_incubation` runs **109 checks** and
fails on an empty corpus, on a corpus with no mission scripts, and on one
without `Events.txt`.

| Group | What it pins |
|---|---|
| `use.*` | the module the arm belongs to, the switch's bias and span, all 60 index bytes, all 18 jump-table entries, the derived class map, and that buttons and the script bands reach the default arm |
| `case.*` | every arm decoded structurally — its `Events.txt` label, its speech event, the byte it writes back, the unit fields it touches, the equipment-point delta, the skill guards and increments (the `technical` bug included), the ammo refill, `Batteries`' inertness and the entry point's fire |
| `lcl.*` (binary) | the call type, the four environment slots, and that `_D` is loaded past the last arm |
| `gate.*` | the pad decoded by following its six leaves, the species and movement gates, the four target predicates, the one-point cost, the "has acted" store, and the two callers of the command executor with the modules they sit in |
| `target.*` | the `10 … 49` band, the crowbar slot, id 32's refusal, the entry-point requirements, the mine test, the five pushable types and the diagonal rule |
| `door.*`, `push.*`, `telep.*` | the parity rule, the one-tile rise, the field-type flip, the three callers; the four-cell limit, the hole types and the fall; the pairing key, the exit field type, the scan stride and the death on a blocked exit |
| `move.*` | the VictoryPoint band and its two bases, the neutral player, the mine radius column, the mine's weapon, and the step cost as delay plus 1 or 2 |
| `ai.*` | the AI's one action point, its eight directions, its two-point minimum, and the enumeration that nothing in `aAISystem.cpp` reaches `aExecuteUse` |
| `ctrlinfo.*` | which `SetCtrlMapInfo` columns the engine reads — and that the fourth is dead, with the first two as the positive control |
| `sweep.*` | all 44 instructions in `.text` that touch `cell[+0x0B]`, and their distribution over the nine modules that own them |
| `corpus.*` | every handled action point counted over all 155 missions, the absences (id 32, ids 86–89, ladders), the random box's confinement to the template map, the crowbar/jammed-door mission, and the teleporter pairing with its one authored exception |
| `lcl.*` (corpus) | 153 `:Use` sections, the four values `_D` is ever compared against, and the 226 `SetActPt` calls beside them |
| `text.*` | all thirteen `Events.txt` labels resolve and name their pickup |

**Every one of the 109 checks has been shown to fail.** 112 mutations — 96
single-byte or single-dword pokes into a copy of `Incubation.exe`, 16 edits to
a copy of the corpus — were each run against the full check set; all 112 were
detected, and the union of the check names they tripped is all 109.

---

## 10. Open questions

1. **What the fourth `SetCtrlMapInfo` column was for.** `Info.lcl` gives
   `Wall` 255, `Enormous Obs` 40 and 0 for everything else. The value lands at
   record `+0x02` and **nothing in `.text` reads it**: a displacement-aware
   sweep finds three references to `+0x00` and two to `+0x01` — the positive
   control — and none to `+0x02` or `+0x03`. It is dead data in this build.
   [`10` §4.1](10-lev-mission-format.md) carried it as UNVERIFIED; it is now
   closed as unreadable rather than unknown.
2. **Why `_C_156`'s fourth teleporter exit has no key.** The cell is field type
   10 with action point 0, and no entry carries key 0, so both are inert. It
   looks like an unfinished pair, but the mission plays without it and nothing
   distinguishes "left unfinished" from "deliberately disabled".
3. **Whether the `technical` box's guard was ever noticed.** The text says
   *"+1 Technical skills"* and the code raises `TS`, so the effect is right;
   only the cap is on the wrong stat. Four cells in the whole campaign carry
   it, which is few enough that it could plausibly never have been reported.
4. **What `Batteries` was going to do.** Action point 41 has a legend gap, a
   text entry, a voice line and an arm that changes nothing. No unit field, no
   equipment id and no game-control slot is written, and no other code in
   either binary tests 41. Whatever it was meant to charge does not exist in
   this build.
5. **The ladder rule on the player's side is untested.** `aBuildMoveMap`
   charges a ladder-to-ladder step the whole movement allowance
   ([`23` §7.4](23-ai-system.md)) while `aExecuteMove` charges it like any
   other step; with **0** ladder cells shipped, no data can say which the
   designers intended. A remake should pick the map's rule, because that is the
   one the player sees.

# The campaign layer — pool, locations, chaining, mission end

**Status: the rules are decoded and checked. `tools/campaign_tables.py --check`
runs 237 checks against the binary and the shipped data; every one has been
shown to fail under a mutation of the byte, token or file it covers.**

This is the delivered package B in [`00`'s game-logic matrix](00-overview.md). It is **behaviour,
not a file format**: nothing here describes bytes on disk that another document
does not already own. Where the storage matters it is cited —
[`10` §5.11](10-lev-mission-format.md) for the roster record,
[`11` §5.2/§5.5/§5.7](11-save-game-format.md) for what a save keeps.

Two things the frame gives a remake. First, **the campaign map is itself a
`.lev`**, and a "location" is an action point on it — the same cell field
[`10` §4.6](10-lev-mission-format.md) tabulates for doors and crates. Second,
**the campaign graph is in the code, not in the data**: a 79-arm `switch`
hard-codes which locations open after which mission.

---

## 1. Where the campaign's state lives

| State | Where | Owner |
|---|---|---|
| Which campaign (1 or 2) | `GameControl + 0x1D1`, `0x0043B760` / `0x0043B750` | [`11` §5.2](11-save-game-format.md) |
| Where you are in it | the `.lev` header's mission id at `+0x223`, mirrored in `0x00510C58` | [`10` §3](10-lev-mission-format.md) |
| The current map's name | `GameControl + 0x0000`, `0x0043B150` | [`11` §5.2](11-save-game-format.md) |
| The roster | `aUnit[5][31]` at `0x0051F2A0` | [`10` §5.11](10-lev-mission-format.md) |
| Equipment points | `u32[4]` at `0x00509EEC`, capped at 10000 | [`25` §3](25-turn-and-round.md) |
| Commendations | `u8[4]` at `0x00509EFC` | [`20` §7](20-lcl-language.md) |
| Kills / losses / score | the scoreboard at `GameControl + 0x230` | [`11` §5.5](11-save-game-format.md) |
| Difficulty | `0x005129F0`, `0x00460450` | [`20` §7.6](20-lcl-language.md) |
| Skill and tech level | `0x00509F00` / `0x00509F04` — §5.2 below | this document |

`GameControl + 0x1D1` was left **UNVERIFIED** in [`11` §5.2](11-save-game-format.md).
It is the **campaign number**: its setters sit in `aMenuSystem.cpp` beside the
four `aCreateUnitPoolForCampaign` calls, and its only game-side reader
(`0x004575E3`) uses it to pick which campaign map to load — §2 below. That item
is now closed there.

### 1.1 The screen the campaign runs in

`Menu_b.lcl`'s selector table is the campaign's state machine
([`20` §5.3](20-lcl-language.md)): the engine writes `0x0050BF70` and the script
jumps to the matching label.

| `_A` | Label | What it is |
|---|---|---|
| 0 | `MainMenu` | the HQ screen — roster, equipment points, save, quit |
| 1 | `Briefing` | [`24`](24-briefing-text.md) |
| 2 | `UpGrade` | buy weapons and equipment — §5.3 |
| 3 | `WaitForPlayers` | multiplayer, out of scope |
| 4 | `SelectUnits` | pick who deploys |
| 5 | `ItemList` | |
| 6 | `MainMap` | the campaign map — §2 |
| 7 | `Dialog` | |
| 8 | `Sequence` | the video screen — §2.3 |
| 9 | `Recruit` | hire — §5.4. The `Menu_b.lcl` selector table labels this row `09_Sequence` and jumps to `Recruit`; the annotation is a copy-paste slip, the jump is right |
| 10 | `Map` | |
| 11 | `SlideShow` | |

### 1.2 The text banks

Nine `aInitTextSystem(bank, file)` calls fix which `.lcl` text table each id
resolves against. This matters because the campaign reads plain integers out of
these banks (§3.1), and a remake that guesses the bank gets the wrong strings.

| Bank | File | Loaded by |
|---|---|---|
| 0 | `Txtmod_a.lcl` | `aMenuSystem.cpp` |
| 0 | `Txtmod_b.lcl` | `aMissionControl.cpp` |
| 0 | `Txtmod_d.lcl` | `aMissionEnd.cpp` |
| 0 | `Txtmod_e.lcl` | `aBattleSystem.cpp` |
| 0 | `Txtmod_g.lcl` | `aViewPlayer.cpp` |
| 1 | `Campaign.lcl` | `aMissionControl.cpp` |
| 2 | `Txtmod_f.lcl` | `aLoad.cpp`, `aPassWord.cpp` |
| 3 | `Txtmod_h.lcl` | `aMain.cpp` |
| 4 | `Mission.lcl` | `aMain.cpp` |

**Bank 0 is the per-screen bank** — five modules load a different file into it —
and banks 1–4 are loaded once and stay. Three of the calls pass the bank in a
register the prologue has just cleared rather than as a literal; the checker
verifies the `xor` in those three cases.

---

## 2. The campaign map — **[code] `0x004575E3`, `0x00431420`**

### 2.1 A location is an action point

`Missions/_C_XXX.lev` is campaign 1's map and `Missions/_C_YYY.lev` is
campaign 2's. Both are ordinary `.lev` files of map type 4, and the campaign
number picks between them:

```c
switch (campaignNumber()) {                       /* 0x0043B760 */
  case 1: strcpy(GameControl.mapName, "_C_xxx"); break;   /* 0x00457603 */
  case 2: strcpy(GameControl.mapName, "_C_yyy"); break;   /* 0x004575F5 */
}
aCreateBattleMap(3);                              /* 0x00417BD0 */
```

Their cells carry **location ids** in the action-point byte `+0x0B`: 49 of them
in `_C_XXX`, 47 in `_C_YYY`, and the two sets are disjoint. `Campaign.lcl`
names every one of the 96 — its 110 text entries are the location table. The
fourteen it names that have no cell are id 0 (`undefined`), twelve dialogue ids
and 130, `Epilogue`.

| Band | Meaning | `_C_XXX` | `_C_YYY` |
|---|---|---|---|
| 1–8 | upgrade locations | 8 | — |
| 10–27 | dialogue locations | 6 have cells (10, 11, 15, 21, 22, 23) | — |
| 50–88 | campaign 1 battles | 35 (50–84) | — |
| 90–129 | campaign 2 battles | — | 40 |
| 210–216 | upgrade locations | — | 7 |

> Loading the campaign map overwrites the `.lev` header, mission id included,
> so `aMissionControl.cpp` keeps the id in `0x00510C58` across the load and
> writes it back afterwards (`0x00457664`). A remake that keeps the campaign
> position outside the map header does not need that dance.

### 2.2 `location = missionId + 50`

The whole of the relationship is one addition, and it appears twice —
`0x004541D5` (screen entry) and `0x00455486` (the debug skip-a-mission key):

```c
location = getMissionId() + 50;      /* add eax, 0x32 */
```

The inverse is a table. `aMapName` `0x0045C200` switches on `location - 51`
over 79 arms and copies out a mission basename:

```
location  51 -> "_C_100"    55 -> "_C_105"    58 -> "_C_104"
          52 -> "_C_101"    56 -> "_C_106"    59 -> "_C_108"
          …                 57 -> "_C_107"    …
          90 -> "_C_140"    …                129 -> "_C_179"
```

The order is not `location - 50`: `_C_104` and `_C_105` are crossed, and so are
their mission ids (8 and 5). **The two tables are exact inverses, and the check
replays the round trip over all 75 shipped campaign missions.** One exception:

* **`_C_180` carries mission id 180**, which is outside both switches. It is
  the epilogue, reachable only as `_C_179`'s next map (§6.6), and no location
  names it.

Two further facts a remake should not rediscover the hard way:

* **Locations 85, 86 and 87 name `_C_134`, `_C_135` and `_C_136`, which the
  release does not ship.** `aCreateLocationMap` has no arm for mission ids
  35–39 either — those fall through to `"unknown missionid"`. Three missions
  were cut and the table was not.
* **`aMapName`'s default arm returns TRUE without writing the caller's
  buffer.** Locations 88 and 89 reach it, so a caller would proceed with a
  stale name. Nothing in the shipped data reaches it: neither id has a cell.

### 2.3 What clicking a location does — **[code] `0x0045C7D0`**

`aLocationHandling` is a 216-entry switch (an index table at `0x0045CF8C` over
a 24-entry jump table at `0x0045CF2C`). It has exactly three kinds of arm:

| Locations | Arm | Effect |
|---|---|---|
| 1–8, 210–216 | 15 distinct | `aPlayLocationAnimation_Upgrade(id)` — §2.4 |
| 10–23 | 6 distinct | the dialogue screen `0x00456FC0(n)`, selector `08_Sequence` |
| 51–88, 90–129 | **one shared arm** | `aMapName(location)` → `GameControl.mapName`, then the briefing |
| everything else | the default | nothing happens |

The battle arm is a single generic handler: every battle location does the same
thing, which is why the campaign graph (§2.4) rather than the handler carries
the structure.

The dialogue arms pass these numbers:

| Location | 10 | 11 | 12–15 | 16–21 | 22 | 23 |
|---|---|---|---|---|---|---|
| number | 2 | 3 | 7 | 1 | 14 | 15 |

[`41` §2](41-sequence-player.md) closes what the number selects.  Logical ids
2 and 3 are `Dialog_02` and `_03`; id 7 chains `Dialog_07` then `_09`; id 14 is
`Dialog_14`; id 15 chains `_15` then `_16`; id 1 selects animated
`Video/Extro`.  The mission-id special cases are also exact:
mission 1 selects logical id 0 when its availability flag is set, mission 180
selects value 16 (intercepted by the static extro screen before the sequence
player), and mission 255 selects id 1.  `0x00510DC0` is the
presentation variant: non-zero chooses the full 640×480 viewport and skips the
framed-screen background callback; zero chooses the 518×306 viewport at
(65,57).  It does not alter the sequence manifest.

### 2.4 Upgrade locations are maps of their own

```c
aDestroyBattleMap();                                    /* 0x00417D30 */
wsprintf(GameControl.mapName, "upgrade_%d", id);        /* 0x00417541 */
aCreateBattleMap(3);
```

So upgrade location *N* loads `Missions/upgrade_N.lev`, and all **15/15**
shipped `upgrade_*.lev` are accounted for. With one wrinkle worth pinning:

* **Locations 3 and 6 load each other's map.** Location 3 (*Fight Position*)
  passes 6 and location 6 (*Assembly Camp*) passes 3; the other thirteen are
  1:1. Nothing in the data corrects it, so it is the shipped behaviour.

### 2.5 The unlock graph — **[code] `0x00431420`**

`aCreateLocationMap(missionId)` is the campaign graph. It clears every cell's
state byte (`0x00431E00`) and then calls one setter per location it opens:

```c
BOOL 0x00431350(int actionPoint, int enabled)
{
    for (each cell) {
        if (cell[+0x0B] != actionPoint) continue;
        if (already found) error("double location!!");
        cell[+0x00] = enabled ? 3 : 1;
    }
}
```

so a location id must be unique across the map, and an *open* location is a
cell in state 3. The switch has **79 arms, mission ids 1…79**; ids 35–39 raise
`"unknown missionid"`. Every arm passes `1`; nothing ever closes a location.

Read it as *"the map as it looks when mission N is the one to play next"*:
every arm enables `N + 50`, its own location, plus the upgrade and dialogue
locations that become available at that point. Five arms are shared by two
mission ids each — **21/22, 43/44, 54/55, 59/60 and 69/70** — and those are the
campaign's route choices, the pairs `Campaign.lcl` labels *Path A* / *Path B*
and *Route A* / *Route B*.

`python3 tools/campaign_tables.py --locations gog_incubation` prints the whole
graph; the first rows read

```
mission  map       location  unlocks
      1  _C_100          51  1 'Supply Shuttle Alpha', 10 'First Action', 51 'Secure the Halls'
      2  _C_101          52  1 'Supply Shuttle Alpha', 52 'Enter Another Hall'
      3  _C_102          53  1 'Supply Shuttle Alpha', 4 'Battlefield', 11 "Rutherford's Office",
                             53 'Way to the Power Station', 54 'Street Fight Area'
```

Every location any arm enables is required to be a cell of the right campaign
map, and the checker verifies both directions. Campaign 2's two sets match
exactly. Campaign 1's do not, by two cells: **`_C_XXX` carries locations 21 and
50 that no arm ever opens**, and `Campaign.lcl` names them *TEST EXTRO* and
*&lt;&lt;Invalid Location&gt;&gt;* — leftovers, and pinned as such.

---

## 3. The unit pool

The storage is [`10` §5.11](10-lev-mission-format.md)'s: `aUnit[5][31]` at
`0x0051F2A0`, 91-byte records, slot address `0x51F2A0 + (player*31 + slot)*0x5B`,
30 usable slots per row. What follows is the runtime around it.

### 3.1 A new campaign's squad — **[code] `aCreateUnitPoolForCampaign` `0x00478710`**

```c
BOOL aCreateUnitPoolForCampaign(int campaign)
{
    if (campaign == 2) return TRUE;               /* nothing to do */
    aEnlargeUnitPool(0);  aEnlargeUnitPool(0);  aEnlargeUnitPool(0);
    saved = getTextBank();  setTextBank(3);     /* Txtmod_h.lcl */
    strcpy(pool[0][0].name, getText(60));        /* "Bratt" */
    strcpy(pool[0][1].name, getText(61));        /* "West"  */
    strcpy(pool[0][2].name, getText(62));        /* "Maxon" */
    …the sixteen field writes below…
    if (saved != -1) setTextBank(saved);
}
```

**Campaign 2 seeds nothing** — the call is a bare `return TRUE`. Whatever the
pool holds when campaign 2 starts is what campaign 2 runs on.

The sixteen writes, decoded from the block at `0x0047883B`–`0x004788A5`:

| Slot | Name | `+0x17` EP | `+0x18` TP | Skills | `+0x4C` type | `+0x4D` | `+0x55` speech |
|---|---|---|---|---|---|---|---|
| 0 | **Bratt** | 17 | 0 | LW 1, LS 2 | **23** | **2 = hero** | 10 |
| 1 | **West** | 12 | 0 | MS 2 | 0 | 1 | 3 |
| 2 | **Maxon** | 12 | 12 | HW 1 | 0 | 1 | 4 |

West also starts carrying equipment 15, `Small Medic Kit` (`+0x30 = 1`, i.e.
`+0x21 + 15` — [`10` §5.4](10-lev-mission-format.md)). Unit type 23 is
`Info.lcl`'s `"Sgt. Bratt"`; the other two keep the type `aEnlargeUnitPool`
gave them. EP 17 puts Bratt at rank 1 and the other two at exactly rank 1 as
well ([`10` §5.11](10-lev-mission-format.md): rank = EP / 12).

### 3.2 Recruiting — **[code] `aEnlargeUnitPool` `0x004789B0`**

`aEnlargeUnitPool(player)` takes the first slot of the row whose `+0x16` (HP)
is zero — a zero HP byte *is* the free-slot marker, the same convention
[`10` §5](10-lev-mission-format.md) uses for an unplaced unit — and seeds it:

```c
rank = (gameMode() == 1) ? 0 : skillLevel();      /* 0x0043B740 / 0x0043B0D0 */
sprintf(rec.name, "Soldier %d", slot + 1);
rec[+0x4C] = player;                              /* unit type */
rec[+0x17] = rank * 12;                           /* EP */
rec[+0x18] = rank * 12;                           /* TP */
rec[+0x19] = (rank < 3) ? 3 : rank;               /* FP */
rec[+0x1A..+0x1F] = 0;                            /* the six skills */
rec[+0x21..+0x35] = 0;                            /* equipment */
rec[+0x38] = 0;                                   /* decorations */
rec[+0x3F] = 0;                                   /* weapon 0 */
rec[+0x45] = player;
rec[+0x4D] = 1;                                   /* pool candidate */
rec[+0x5A] = (weapon[rec[+0x3F]].cost + 50) / 10; /* cached resale value */
rec[+0x55] = aRandom(1, 6);                       /* speech set */
recomputeUnitStats(rec);                         /* 0x004759E0 */
```

**`unitType = player` is deliberate, not a slip.** `Info.lcl` names unit types
0…3 `Human Soldier (1)` … `(4)`, one per player slot, differing only in the
model variant column — so a recruit gets the soldier model of the side that
hired them.

Two smaller notes. The routine's player bound is `cmp; jg` where its two
siblings (`0x004788C0` free-slot count, `0x00478960` used-slot count) use
`dec eax` first, so `aEnlargeUnitPool` admits `player == playerSlots()` where
they stop one short; no shipped path passes that value. And the seeding is the
**only** game-side reader of the skill level (§5.2).

### 3.3 Dismissing — **[code] `aRemoveUnitFromUnitPool` `0x00478B70`**

Shifts records `slot+1 … 30` down one and zeroes record 30's HP byte. That is
what the 31st slot is *for*: it is the scratch the compaction shifts into, which
is why the array is `[5][31]` with 30 usable
([`11` §5.7](11-save-game-format.md)). The Recruit screen refunds
`rec[+0x5A] * 10` equipment points in the same breath
([`10` §5.11](10-lev-mission-format.md)).

### 3.4 Deploying, and what survives a mission

Two routines move a record between the roster and the map, and they are not
symmetric.

**`aTransferUnitFromPoolToMap(player, slot, x, y)` `0x00478D10`** — places the
record on the map through `aUI_SetUnit` (`0x00472780`, `aUI.cpp`), rebuilds
visibility, then removes the slot from the pool. It refuses `slot > 30`. Its
only caller is the deploy screen, `aPI.cpp` — which is what identifies that
module ([`90` §2](90-binaries-and-source-layout.md)).

**`aTransferUnitFromMapToPool(player, x, y)` `0x00478F20`** — the survival gate:

```c
u = unitOn(x, y);                     /* error "no unit on field" if none */
if (u[+0x4D] == 0)          return TRUE;   /* not a pool candidate -- dropped */
if (!aAddUnitToUnitPool(player, u)) return TRUE;   /* pool full -- dropped */
aKillUnit(u.x, u.y);
```

So **a unit survives a mission only if `+0x4D` is non-zero** — 1 *pool
candidate* or 2 *hero*, the two check boxes the editor exposes
([`10` §5](10-lev-mission-format.md)) — and **only if there is a free slot.**
Both failures are silent: the routine returns TRUE and the unit is simply gone.
A remake that wants to warn the player has to add the warning itself.

`aTransferAllUnitsFromMapToPool(player)` `0x00478E50` walks every cell, filters
on `u[+0x45] == player`, recomputes the unit's stats and calls the above. It has
exactly one caller: the debriefing screen, and only in game mode 1 (§6.1).

### 3.5 The two banks — **[code] `aCopyUnitPool` `0x00478910`**

`aCopyUnitPool(from, to)` copies 2730 bytes — `30 * 91`, one whole usable row.
It has exactly **two** call sites and they are the two directions:

| Site | Call | When |
|---|---|---|
| `0x0045A914` (`aMissionControl.cpp`) | `aCopyUnitPool(0, 1)` | entering a mission |
| `0x0045E9D9` (`aMissionEnd.cpp`) | `aCopyUnitPool(1, 0)` | leaving it |

**Row 0 is the between-missions bank and row 1 is the mission's working copy.**
[`11` §5.7](11-save-game-format.md) inferred exactly this from real saves and
recorded that one campaign's saves could not settle it; the two call sites do.
That also sharpens the flat-write bug recorded there: the row that loses its
last slot to the save's 5460-byte write is row 1, the working copy.

`aAddUnitToUnitPool(player, unit)` `0x00478C10` copies the record verbatim into
the first free slot and, **only** when there is more than one human player or
the mode is `net session`, re-randomises `+0x55` (speech). In the campaign it
never fires, so a soldier keeps their voice.

One `aMissionControl.cpp` site (`0x0045C0DE`) **sorts** the row: `0x00478630`
is a bubble sort over the 30 slots that swaps whole 91-byte records, descending
by `+0x17` (EP), and skips any pair where either `+0x16` is zero. Which screen
that is is package F's to say; what matters here is that the roster's slot order
is not stable.

---

## 4. Rank, experience and skill points

[`10` §5.11](10-lev-mission-format.md) already owns this: rank = EP / 12, the
decoration button is the only thing that credits TP and always by 12, the
allowance is derived from EP alone, TP is spent on the equipment screen, and
the cheat menu writes both. Two things package B adds.

**Where `rank` comes from when a recruit is seeded.** `0x0043B0D0` reads a
global that the front end fills from the `.lev` header's **Skills** field
(`+0x21A`, dialog range `[0,12]` — [`10` §3](10-lev-mission-format.md)):

```c
for (p = 0; p < playerSlots(); p++)
    setEquipmentPoints(p, header.equipmentPoints[p]);   /* 0x00419B00 */
setTechLevel(header.techLevel);                          /* +0x21E -> 0x00509F04 */
setSkillLevel(header.skillLevel);                        /* +0x21A -> 0x00509F00 */
```

So a mission's *Skills* number is the rank new recruits start at, **and it is
overridden to 0 in campaign mode** — the campaign always hires green.

**The cheat key that maxes skill points.** `0x004786E0(player)` sets `+0x18` to
120 on every occupied slot of a row; [`10` §5.11](10-lev-mission-format.md)
records it as Mission Control's `i x 3`. 120 is ten skill points, which is the
attainable maximum the decoration button stops at.

---

## 5. Equipment points

### 5.1 The pool

`u32[4]` at `0x00509EEC`, with three accessors that between them define the
rules:

| Routine | Rule |
|---|---|
| `0x0043AFF0(p)` | read |
| `0x0043B010(p, n)` | add, **clamped at 10000** |
| `0x0043B060(p, n)` | spend — **refuses if `points < n`**, so a purchase never goes negative |
| `0x0043B0A0(p, n)` | set |

Both `add` and `spend` first require `playerKind[p] != 0`, so an empty slot
cannot hold money.

### 5.2 The tech level gates the catalogue

`0x00509F04` holds the mission's tech level, from the header's `+0x21E`. Six of
its seven readers are in `aMenuSystem.cpp`; the seventh, `0x0045BF4B`, stores it
into `0x00510A35` beside a companion byte at `0x00510A34` — a limit pair the
item screens read. **UNVERIFIED**: which of the pair is the skill limit and
which the tech limit is not pinned here, and belongs to package F. The item
tables carry the requirement:
`SetEquipInfo`'s `+0x21` and `SetWeaponInfo`'s tech column
([`21` §3, §4](21-info-lcl-schema.md)). No shipped header sets either level
above 12, which is what makes the three tech-99 items unbuyable
([`21` §3](21-info-lcl-schema.md)).

### 5.3 Buying and selling

Weapons and equipment are priced in equipment points — weapon cost at
`+0x3E` of the 67-byte weapon record, equipment cost at `+0x20` of the 42-byte
record ([`21`](21-info-lcl-schema.md)). The Upgrade screen:

* **equipment** — spends `equip[id].cost` (`0x0045A9E9`), after a guard on the
  unit's carried-equipment bitmap;
* **weapon** — **refunds the weapon being replaced** (`0x0045AAC7`, add) and
  then spends the new one (`0x0045AAF0`), so a swap costs the difference;
* after every weapon purchase it recomputes `+0x5A`, the cached resale value
  ([`10` §5.11](10-lev-mission-format.md)).

### 5.4 The price of a soldier

```c
cost = weapon[0].cost + 50;                       /* 0x0045B821, 0x0045B826 */
if (equipmentPoints(currentPlayer) < cost) return;
spendEquipmentPoints(currentPlayer, cost);
aEnlargeUnitPool(currentPlayer);
```

`Info.lcl` prices weapon 0, `Light Combat Gun`, at **10**, so **a recruit costs
60 equipment points** — and the same `+ 50` markup appears in the resale
formula, so dismissing a fresh recruit refunds exactly what they cost. The
checker cross-checks the constant in the binary against the number in
`Info.lcl`.

---

## 6. The end of a mission

### 6.1 What the debriefing screen does

`aMissionEnd.cpp`'s screen builder, in order:

1. `aPrintMessageScreen`, then `0x0045EB10`;
2. **in game mode 1 only**, `aTransferAllUnitsFromMapToPool(0)` — §3.4;
3. `0x0043BA10`, the scorer and payout — §6.2;
4. builds the GUI from `Txtmod_d.lcl` (bank 0) and `AddOns2.Lib`.

### 6.2 The score and the payout — **[code] `0x0043BA10`**

For every player slot that is in the game:

```c
switch (missionResult(player)) {                  /* scoreboard +0x20 */
  case 1: base =    0;  break;
  case 2: base = +100;  break;
  case 3: base = +200;  break;
  case 4: base = +300;  break;
  case 5: base = -100;  break;
  default: error("unknown missionresult");
}
if (skipRuleGate())      base = 0;                /* 0x0043B1F0 -- see below */
mul = 1;                                          /* and stays 1 unless… */
if (gameMode() == 1)                              /* 0x0043BAC8 */
    mul = (int[]){1, 2, 3}[difficulty()];         /* difficulty 0, 1, 2 */

score          = kills * mul - 2 * losses + base;
record[+0x18]  = score;                           /* this mission */
record[+0x1C] += score;                           /* the campaign */

if (gameMode() == 1 && missionResult(player) != 5) {
    if (gc[10]) equipmentPoints[player] += gc[10];
    if (gc[11]) commendations [player] += gc[11];
}
```

`0x0043B1F0` is **not** the solo flag, despite reading it first.
[`25` §3.1](25-turn-and-round.md) decodes it as the gate in front of the
player-skip rule, and it is true **only in a `net session` or `pbm session`
with one human player**. So in the campaign it is false and the base score
always applies — the difficulty multiplier and the base are both live, and a
campaign mission scores `kills * difficulty − 2 * losses + base(result)`. The
same predicate is what keeps the equipment-point hand-out from firing in the
campaign ([`25` §4.1](25-turn-and-round.md)); a remake that models it as "solo"
would get both wrong.

### 6.3 Where the mission result comes from

`setMissionResult` is `0x0043B960(player, value)`, and a full `.text` sweep
finds **30** call sites. All thirty are classified in §6.4; the thirteen a
campaign can reach are these.

**The reset.** `0x0043B990` clears a player's scoreboard record and writes
`+0x20 = 1`, so **1 means "nothing happened"** — the value an abandoned mission
keeps, and the reason it scores nothing.

**Inside the hand-over** (`0x0047D600`, [`25` §4](25-turn-and-round.md)), after
the `NEXT PLAYER` event has run the mission script — and only when the turn
counter is past zero, the same "not during deployment" guard the wipeout test
below uses. It is the body of what [`25` §4](25-turn-and-round.md) calls
`missionEnded()`, which is inlined rather than a routine of its own:

```c
if (gc[0] || gc[1] || gc[2] || gc[3] || gc[4]) {   /* 0x0047D88B, an OR chain */
    for (p = 0; p < 4; p++) setMissionResult(p, 5);          /* 0x0047D8D1 */
}
for (i = 0; i <= 4; i++) {                                   /* 0x0047D901 */
    player = (i == 4) ? 0xFF : i;
    if (!playerKind(player) && player != 0xFF) continue;
    switch (gc[i]) {                              /* the LCL outcome slots */
      case 0: break;                              /* leave it alone        */
      case 1: setMissionResult(i, 2); ended = 1; break;      /* +100 */
      case 2: setMissionResult(i, 3); ended = 1; break;      /* +200 */
      case 3: setMissionResult(i, 4); ended = 1; break;      /* +300 */
      default: error("unknown missionresult");    ended = 1;
    }
}
if (ended) return 0;                              /* the mission is over   */
if (!advancePlayer()) {                                      /* 0x0047D996 */
    for (p = 0; p < 4; p++) setMissionResult(p, 5);          /* 0x0047D9A7 */
    return 0;
}
```

**The gate is an OR over all five slots, not a test of slot 4.** That is the
whole of the win/lose rule, and it works by overwriting: *any* outcome makes
every player a 5 first, and then each player's own slot puts 2/3/4 back. So a
player whose slot 0–3 is set wins; a player whose slot is clear when someone
else's is set keeps the 5. **Slot 4 is the computer's**, so "the computer
achieved its objective" is exactly "no human slot overwrites the 5" — the
defeat.

The second stamp is one shared block, `0x0047D9A3`, reached from **both** of the
hand-over's two "nobody can take a turn" exits — `advancePlayer` failing
(`0x0047D996`) and `aSearchFirstPlayer` failing (`0x0047D61C`). That is what
[`25` §4](25-turn-and-round.md) writes as `allPlayersOut()`: four calls, one per
player slot.

**Two more, in the in-battle command dispatcher** `0x0041DA20`
(`aBattleSystem.cpp`), a ten-arm switch on a command id:

* **Command 1, give up.** `if (humanCount() == 1 || 0x0043B1F0()) goto simple;`
  — mode 1 gives one player slot ([`25` §2](25-turn-and-round.md)), so the
  campaign always takes the simple arm, which stamps result **5** on every
  human (`0x0041DB86`). The other arm is the multiplayer scorer of §6.4.
* **Command 2, end the turn.** Its four arms are keyed on `gameMode() - 1`;
  modes 1 and 3 share one (`0x0041DD61`):

  ```c
  if (livingUnits(currentPlayer) <= 0 && turnCounter() > 0)   /* 0x00477BF0 */
      setMissionResult(currentPlayer, 5);                     /* 0x0041DD8E */
  ```

  `0x00477BF0(player)` counts the UnitMap slots with non-zero HP owned by that
  player, so this is the **wipeout defeat**, and it is an engine rule rather
  than a script one. The `turnCounter() > 0` clause keeps it from firing during
  deployment, before anyone has been placed.

So the campaign has one scripted outcome path and three engine ones: the LCL
slots grade a win or hand the computer the mission, giving up forfeits, being
wiped out forfeits, and a rotation with nobody left in it forfeits.

### 6.4 All thirty setter sites

The sweep is enumerated rather than sampled, because "the rest are
multiplayer's" was a guess an earlier revision of this document made and could
not support:

| Sites | Where | Reached when |
|---|---|---|
| `0x0047D8D5` `E1` `ED` `F9` | `handOver` | any outcome slot set — **campaign** |
| `0x0047D93C` `49` `56` | `handOver` | the win-grade map — **campaign** |
| `0x0047D9A7` `B3` `BF` `CB` | `handOver` | `advancePlayer` or `aSearchFirstPlayer` failed — **campaign** |
| `0x0041DB86` | command 1 | giving up, one human — **campaign** |
| `0x0041DD8E` | command 2, modes 1 and 3 | wiped out — **campaign** |
| `0x0041DC79` | command 2, mode 4 | the same test on the `pbm session` arm |
| `0x0041DB45` `B58` | command 1 | ─ |
| `0x00453C04` `C17` | `aMI.cpp` `0x00453900` | ─ |
| `0x0047D44D` `460` | `aViewPlayer.cpp` `0x0047D270` | ─ |
| `0x0047D827` `83A` | `handOver` | ─ |
| `0x0047E144` `157` | `aViewPlayer.cpp` `0x0047DE90` | ─ |
| `0x00481203` `216` | the DirectPlay message dispatcher `0x004810C0` | ─ |
| `0x00454C8D` `99` `A5` `B1` | `aMissionControl.cpp` `0x004543A0` | behind a network flag |

The twelve marked ─ are **one idiom**, six copies of it, and the checker
requires each pair to bracket exactly one call to the routine that supplies the
value:

```c
for (p = 0; p < humanCount(); p++) {
    setMissionResult(p, 5);
    setMissionResult(p, 0x0045FDB0(p));      /* aMultiPlayer.cpp scores it */
}
```

`0x0045FDB0` is `aMultiPlayer.cpp`'s — legacy multiplayer, out of scope
([`92` §7.9](92-remake-architecture.md)). Each of the six copies is network
code by one of two mechanical tests, and the checker asserts both:

* **two** sit on an arm the enclosing routine reaches only when
  `humanCount() != 1` — `0x0041DB45` (command 1, tested at `0x0041DB0D`) and
  `0x0047D827` (inside `handOver`, tested at `0x0047D80B`). Mode 1 gives one
  player slot ([`25` §2](25-turn-and-round.md)), so a campaign takes the other
  branch;
* **four** are preceded, within 48 bytes and on the same basic block, by a call
  into `aDPlay.cpp` for the local network player index (`0x00436980` or
  `0x004369A0`), whose result they feed to `0x0047BC60` before the loop.

> **UNVERIFIED**, and worth stating plainly: the second test says these four
> arms *are* network code, not that a campaign cannot reach them. They carry no
> game-mode test of their own — only `0x0043B1F0`, which is false in the
> campaign (§6.2) and therefore does **not** skip the loop. Tracing their entry
> conditions back to a mode would need the deliberately unresearched legacy
> multiplayer session flow. What can be said without it: `0x0045FDB0` returns 4 unconditionally
> when `humanCount() == 1`, because its "is any other human still alive" loop
> has no other human to look at — so a campaign reaching one of these arms would
> award **+300** for nothing. That is a consequence, not a proof; it is recorded
> so that if a remake ever sees a stray +300 it knows where to look.

The last four needed a sweep of their own. They sit behind
`0x00481A60()`, an accessor for `0x00524008`, and that word has exactly four
references in the image: the accessor pair, one initialiser that zeroes it in a
block of siblings (`0x00480C97`), and **one writer, `0x004812A2`, inside
`0x004810C0` — the routine whose first act is a DirectPlay receive**. Nothing
else can set it, so the four stamps are unreachable without the network.

One module is not named. `0x004810C0` and its initialiser sit in
`0x00480000`–`0x00483000`, where **no `.cpp` string exists at all**; the
`__FILE__` map puts the range inside `aWinTools.cpp`'s span, but a span is an
upper bound ([`90` §2](90-binaries-and-source-layout.md)). What the code does —
a DirectPlay receive, then a switch over message ids — identifies it even though
the map cannot.

### 6.5 Two corrections to documents that already touch this

* **[`11` §5.5](11-save-game-format.md)'s result-to-score table was shifted by
  one.** It read the five `mov ebx, imm32` arms in *address* order; the
  compiler's jump table at `0x0043BBB8` does not use that order. §6.2's table is
  the jump table's, and §6.3 shows it is the one that matches how the results
  are written — reset 1 scores nothing, the three LCL win grades score
  +100/+200/+300, and the defeat 5 scores −100. The real save quoted in `11`
  §5.5 shows a −100 mission, which fits either reading of that one row; the
  jump table and the writers together settle the rest. Corrected there.
* **[`20` §7](20-lcl-language.md)'s slots 10 and 11 pay out under two
  conditions the slot table did not state**: game mode 1, and a mission result
  that is not 5. A player who was eliminated collects neither the equipment
  points nor the commendations the mission's script awarded. Recorded there.
* **Slot 4 is not read on its own.** An earlier revision of this section — and
  the note it put in [`20` §7](20-lcl-language.md) — said `0x0047D8C3` reads
  slot 4 and stamps 5 when it is set. It does not: `0x0047D8C3` is the *last*
  test of a short-circuit OR over slots 0–4 (§6.3), and the stamp is what
  happens when **any** outcome slot is set. The behaviour that follows for slot
  4 is the same — nothing overwrites the 5 — but the mechanism was wrong, and
  the wrong mechanism would have made a remake miss that a *win* also passes
  through result 5 for an instant. Corrected in both places.

### 6.6 Which mission comes next

The debriefing screen has four buttons (`0x0045EA50`). Two of them carry
campaign state:

```c
/* 0x0045E986 -- go on */                   /* 0x0045E9CB -- back to the map */
setCurrentPlayer(0);                        setCurrentPlayer(0);
strcpy(GameControl.mapName,                 aCopyUnitPool(1, 0);
       levHeader + 0x000);                  …
```

`levHeader + 0x000` is the `.lev` header's **next-map name**
([`10` §3](10-lev-mission-format.md)) — so the chain is static data, one link
per mission file, and the LCL command `EnterNameOfNextMap`
([`20` §7.3](20-lcl-language.md)) writes that same field at run time when a
mission wants to branch. Both are checked against the corpus: every non-empty
header field and all 74 `EnterNameOfNextMap` arguments name a shipped mission.

`_C_133`'s next map is `_C_YYY` — the campaign-2 map — which is how one
campaign hands over to the other.

**A clean campaign start enters the second chain, at `_C_140`.** The two chains
are `_C_100`…`_C_133`→`_C_YYY` and `_C_140`…`_C_17x`, and it is `_C_100` whose
header carries mission id 1 — so the obvious reading, that a new game begins
there, is wrong. The evidence is a save the game wrote itself:
`tests/fixtures/saves/_0_.sav` is "the only fixture from a session that went
straight into the campaign", with untouched password slots and no four-player
residue in its equipment points, and the mission it names is **`_C_140`**
(`tests/fixtures/saves/README.md`). Noticed while choosing a mission for the
first vertical slice's native capture ([`93` §9](93-slice-1-report.md)), which
is why `_C_141` — the second mission actually played — is the one the capture
runs on.

---

## 7. Two disproved premises from the campaign research

The campaign research started with two plausible premises. Both turned out to
be misreadings of the shipped material, and saying so is the finding:

* **`aPassWord.cpp` is not mission passwords.** It is the **play-by-mail
  password entry screen**: it loads `LoadSave.lib` and `loadsave.pal`, and its
  comparison reads `0x0043B650(player)` = `GameControl + 0x16B + player*25`,
  which is exactly the four 25-byte slot array
  [`11` §5.3](11-save-game-format.md) already documents, sentinel
  `INVALID_PASSWORD` included. There are no level codes in this game.
  Play-by-mail is out of scope ([`92` §7.9](92-remake-architecture.md)).
* **`aDataBase.cpp` has nothing to do with the campaign.** 0.7 KB, one `CHECK`
  site, and its only recovered symbol is `aCreateMainDDObject` — DirectDraw
  setup.

`Info/Campaign.txt` is likewise not the location table
([`24` §7.2](24-briefing-text.md) already calls it placeholder data). The real
one is `DATA/TXT/English/GUI/Campaign.lcl`, text bank 1.

---

## 8. What a remake has to implement

1. **Campaign state**: campaign number, current mission id, the roster's two
   rows, equipment points, commendations, the four-player scoreboard,
   difficulty. Everything else is derived.
2. **The location map** as data: `location = missionId + 50`, the 79-arm unlock
   graph, and the location → mission-file table. `campaign_tables.py --json`
   emits all three; a converter can bake them out rather than re-deriving them.
3. **The roster rules**: seed a new campaign with Bratt/West/Maxon exactly as
   §3.1 gives them; hire for 60 points; sort by EP descending; carry over only
   units with `+0x4D != 0`, and drop when the 30 slots are full. That choice is
   **decided** in [`92` §7.4](92-remake-architecture.md): the rule stays, but
   the silence does not — the mission-end screen names the survivors that were
   lost, and deploying with a full roster warns first.
4. **The two banks**: copy row 0 → row 1 on entry and row 1 → row 0 on exit, or
   model the same thing with an explicit snapshot.
5. **Mission end**: the result-to-score table of §6.2, the difficulty
   multiplier in campaign mode only, and the two payouts gated on result ≠ 5.
6. **Chaining**: the header's next-map field, overridable by
   `EnterNameOfNextMap`.

What it does **not** need: the campaign map as a 3D `.lev` at all. `_C_XXX` and
`_C_YYY` carry the location cells and their world positions, but a remake is
free to draw its own map as long as the ids match.

---

## 9. Verification — `tools/campaign_tables.py`

```bash
python3 tools/campaign_tables.py --check     gog_incubation   # 237 checks
python3 tools/campaign_tables.py --locations gog_incubation   # the unlock graph
python3 tools/campaign_tables.py --json      gog_incubation   # the decoded tables
```

**237 checks, and 223 mutations trip every one of them.** The checker fails on
an empty corpus, on a root that holds only the executable, and
on a root missing any of `Campaign.lcl`, `Txtmod_h.lcl` or `Info.lcl`. It reads
no save game: nothing in `tests/fixtures/saves/` is on this path.

What each group covers:

| Group | Checks |
|---|---|
| `corpus.*` | the corpus is present and the expected size |
| `location.*` | `+50`, and the five `.lev` header accessors by the address they touch |
| `mapname.*` | the 77-entry table, the round trip over 75 missions, the three cut missions, the buffer-less default |
| `locmap.*` | 79 arms, the five gaps, the five shared branch arms, every arm naming its own location, the setter's stride/offset/states |
| `cells.*` | every enabled location exists as a cell of the right campaign map, and the two maps are disjoint |
| `labels.*` | `Campaign.lcl` names every location cell |
| `campaign.*` | the two map names, the campaign-number offset, its readers |
| `upgrade.*` | the `sprintf`, the 15-arm location→map table (the crossed 3/6 pair included), the 15 shipped maps |
| `handling.*` | the 216-entry dispatch, the one battle arm, the dialogue numbers, the default |
| `bank.*` | the nine `aInitTextSystem(bank, file)` pairs and the files behind them |
| `squad.*` | the three names resolved out of `Txtmod_h.lcl`, all sixteen field writes, the hero's type name in `Info.lcl` |
| `recruit.*` | the seeding, every store by the record offset it targets, the four player unit types |
| `money.*`, `cost.*` | the array, the cap, the no-debt guard, the five cost sites, the 60-point recruit cross-checked against `Info.lcl` |
| `level.*` | skill and tech levels and where they come from |
| `payout.*` | the five-arm score table read through the jump table, the multipliers, the two gates |
| `result.*` | the reset value, the five-slot OR gate, the defeat stamp on all four players, the three win grades, all 30 setter sites classified, and the two mechanical tests that put the twelve multiplayer ones on network code |
| `rotation.*` | both "nobody can take a turn" exits and the shared block they land in |
| `battle.*` | the ten-arm command dispatcher, giving up, the four end-turn mode arms and the wipeout test |
| `end.*` | the survival gate, the owner filter, both copy directions, the next-map hand-off, the four buttons |
| `chain.*` | every next-map name and every `EnterNameOfNextMap` argument resolves |

---

## 10. Open questions

1. ~~**What the dialogue numbers select.**~~ **Closed** — §2.3 and
   [`41` §2](41-sequence-player.md) give the complete logical-id → successive
   directory mapping, including the `_07 → _09` and `_15 → _16` transitions.
2. **Why locations 3 and 6 load each other's upgrade map.** Pinned as observed
   (§2.4). Whether it is an authoring slip or deliberate cannot be settled from
   the shipped data: both maps exist, both are reachable, and no text names
   which is which.
3. ~~**The other 27 `setMissionResult` sites.**~~ **Closed** — §6.4. All
   thirty are enumerated and classified: thirteen a campaign reaches, one on
   the `pbm session` arm, twelve that bracket `aMultiPlayer.cpp`'s scorer and
   are each guarded by `humanCount() == 1` or the solo flag, and four behind a
   flag whose only writer is the DirectPlay message dispatcher. Closing it
   changed the spec twice over: it added three engine-side defeats the campaign
   really has (giving up, being wiped out, a rotation with nobody left) and it
   corrected §6.3's gate from "slot 4 is set" to "any outcome slot is set".

   One level up, a different thing is settled and worth stating so it is not
   mistaken for an open question: **which condition a given mission treats as a
   win is the script's business, not the engine's.** 152 of the 153 shipped
   scripts carry the same *"Reset game control variables for saving the
   winconditions"* block and then set the slots from their own predicates, so
   there is no engine rule to recover — only 153 individual answers, which
   [`20` §7](20-lcl-language.md) gives the vocabulary for.

4. **The unused location bands.** `Campaign.lcl` names 110 locations; only 96
   have cells. The remainder are dialogue ids 12–14, 16–20 and 24–27, and
   location 130, *Epilogue* — which is what `_C_180` would be if its mission id
   were 80 instead of 180. Nothing reads them.
5. ~~**`0x00510DC0` and the dialogue screen's mission-id special cases.**~~
   **Closed** — §2.3.  The ids select logical sequence 0, the intercepted
   static extro screen, and logical sequence 1; the flag selects full-screen
   versus framed presentation and the background callback.

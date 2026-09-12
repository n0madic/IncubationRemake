# The campaign layer — pool, locations, chaining, mission end

**Status: the rules are decoded and checked. `tools/campaign_tables.py --check`
runs 485 checks against the binary and the shipped data; every one has been
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

#### Which plate each window sits on — **[code] `0x00510A38`**

*(Added 2026-09-08.)* Only two of the twelve load a plate of their own. Pairing
each write of the window selector `0x00510A38` with the `aLoadGUIBackGround`
call beside it:

| window | plate |
|---|---|
| 2 `UpGrade` (`0x0045BFC8`) | **`plate_6`**, loaded at `0x0045BFBB` |
| 6 `MainMap` (`0x004576B3`) | `plate_3`, loaded at `0x004576C2` |
| 8 `Sequence` (`0x00457054`) | `plate_7` |
| 0, 1, 4, 5, 9, 10, 11 | **none** — they inherit |

What they inherit is `plate_3`: `aInitGUI` loads it once at `0x00454245` on the
way into Mission Control, and every window above that loads none keeps it. That
is the one shipped plate with a picture frame inset, which is why the HQ, the
Unit Menu, the Item List, the briefing and the Recruit window all show the 3D
scene behind their frame — the same rectangle §2.6 measures for the map,
`(65, 57)` by 518x306.

`plate_6` is the exception in kind as well as in count: it is not a frame but a
set of painted panels, and their black interiors are the layout. Measured off
the bitmap: the model window at `(63, 134)` 249x128, the item window at
`(399, 136)` 186x127, and **six** boxes between them across `x` 316..398, split
by bright separators at `y` 89/145/188/232/273/314/354. Six, not the five the
shipped screenshot fills — one per skill of `+0x1A..+0x1F` plus the fitness
`+0x19`, which is exactly what the hover hints `Txtmod_b` 160..165 name.

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
`Video/Extro`.  The remake plays them framed over `plate_7` since the ninth
slice ([`92` §7.19](92-remake-architecture.md)).  The mission-id special cases are also exact:
mission 1 selects logical id 0 when its availability flag is set, mission 180
selects value 16 (intercepted by the static extro screen before the sequence
player), and mission 255 selects id 1.  `0x00510DC0` is the
presentation variant: non-zero chooses the full 640×480 viewport and skips the
framed-screen background callback; zero chooses the 518×306 viewport at
(65,57).  It does not alter the sequence manifest.  That rectangle is not the
sequence's own — it is the campaign screens' 3D window, §2.6.

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

### 2.6 The screen the map is drawn in — **[code] `0x00453F80`, `0x00457590`**

A remake needs three things this section did not carry: which plate, which
rectangle of it the 3D goes in, and where the camera stands. All three are
constants in `aMissionControl.cpp`, and `campaign_tables.py --check` pins
them.

| What | Where | Value |
|---|---|---|
| the plate | `aInitGUI` `0x00454245`, again `0x004576C2` | `GUI\plate_3.bmp` |
| the 3D window | `0x0040B670` at `0x00454102`, centre `0x0040B6B0` at `0x00454118` | `(65, 57)`, 518 × 306 |
| the camera's initial eye | `0x00510BB8/BC/C0`, three `mov dword` immediates at `0x004541B2/BC/C6` | `(−19088, 98112, 9088)`; replaced by the current-location preset below |
| the camera's target | `0x00510BC4/C8/CC`, `mov eax, 0xDDE0` at `0x0045414B` spent twice, then the prologue's zeroed `ebx` | `(56800, 56800, 0)` |

The initial eye is not the eye the player normally sees. Immediately after
writing it, the screen computes `location = missionId + 50` and calls
`0x0045D130(location, &eye.x, &eye.y, &eye.z)` at `0x004541D9`. The helper
clears the map-angle accumulator and selects one of thirteen authored eyes
through a 71-byte table for locations 59..129; locations outside the table and
the unused 85..89 gap take its default arm:

| Current location | Eye `(x, y, z)` |
|---|---|
| default; 50..58; 85..89 | `(−19072, 98096, 9088)` |
| 59..65 | `(−19072, 98096, 19088)` |
| 66..69 | `(79968, 140032, 19088)` |
| 70 | `(15248, −18944, 18848)` |
| 71..76 | `(101984, −16800, 19184)` |
| 77..80 | `(−15072, 104672, 19200)` |
| 81..83 | `(14320, 132016, 18592)` |
| 84 | `(56912, 143168, 3984)` |
| 90..96 | `(73664, −27904, 19200)` |
| 97..100 | `(−21072, −21840, 19136)` |
| 101..104 | `(143104, 53360, 19200)` |
| 105..115 | `(121856, 0, 19200)` |
| 116..119 | `(74176, −27792, 19200)` |
| 120..129 | `(−3776, −4736, 14336)` |

`0x00457695` later loads the selected eye and the shared target and hands all
six coordinates to `aSetCameraPosition` `0x00403560` when the map is raised.
They are not clamped by the unit-camera box of
[`42` §2.1](42-mission-presentation.md); several authored eyes deliberately stand outside
the map. The target stays at field (17.75, 17.75), height 0, for both chains.

This table is not merely cosmetic. Replaying the exact projection over both
campaign maps puts all **156** `(current mission, open location)` pairs emitted
by `aCreateLocationMap` inside the untouched `(65,57)..(583,363)` frame, with
the marker's ten-pixel picking radius still inside it. For `_C_143`'s successor
`_C_145`, current location 95 selects `(73664, −27904, 19200)` and shows both
95 (*Next Antenna*) and 211 (*The old Fort*) immediately. A fixed initial eye
puts 95 below the frame and incorrectly makes manual rotation necessary.

The 518 × 306 viewport at (65, 57) is the one §2.3 reads as the sequence
screen's. It is the **campaign screens'** generally: `0x00454102` sets it on
the way in, `0x004559FA` sets it again on every frame the map is up, and the
dark interior of `plate_3.bmp` is exactly that rectangle.

`Menu_b.lcl`'s `:MainMap` block is the rest of the screen, and like
`Menu_a.lcl`'s `:MainMenu` it is a flat table rather than a program: window
`(0, 0, 640, 480)`; `Txtmod_b[140]` at (320, 26) in `font_2`, centred; and
three buttons on one row at y = 402, six tiles wide — *End game*
(`Txtmod_b` 18) at x = 60, *Save game* (19) at x = 232 and *Enter Location*
(141) at x = 408.

Two things that are **not** where a remake would look for them:

* **The campaign maps' own `.lcl` sets no camera.** `_C_XXX.lcl` and
  `_C_YYY.lcl` are ordinary mission scripts whose `InitMap` arm holds four
  `CreateBGB (n, 7_fire, x, y, z, live, random, gamma)` calls — the burning
  buildings on the map — and one `CDTrackProgram ("5.3.4.2")`. Nothing else.
  Every other arm is empty except `_C_YYY`'s `NextPlayer`, which counts
  players and sets a win condition that no one reads.
* **The map's own frame callback moves the camera.** `0x00457570`, registered
  with `0x0043E5D0` at `0x004576A6`, calls `0x004558F0` once a frame — §2.6.1.

#### 2.6.1 What turns the map, and by how much — **[code] `0x004558F0`**

`0x004558F0(surface, stride, turn, rise)` is called from two places inside the
map's own loop: `0x00454E6C` with the pair of deltas below, and `0x00454EEF`
with **two zeros**. The second is what makes the first work.

**The request is a pointer drag with the *right* button held.** `0x00455560`
runs only while the screen id `0x00510A38` is 6 and the button byte
`0x00511B09` (set through `0x0045EFD0`, read through `0x0045F000`) is 1, and it
writes the two globals the call site above spends:

```c
0x00510C44 = 2   * (cursor.x - anchor.x);   /* 0x0045558C: shl eax, 1     */
0x00510C48 = -50 * (cursor.y - anchor.y);   /* 0x0045559A: neg/shl/sub/lea/shl */
0x0045EEF0();    /* SetCursorPos back to the anchor */
```

**Which button that byte is** *(2026-09-10)*. The message pump `0x0040B6F0`
peeks its own messages and dispatches `0x0202`..`0x0206` through the five-entry
table at `0x0040BD58`; the two setters it calls are one instruction each —
`0x0045EFC0` writes `0x00511B08` and `0x0045EFD0` writes `0x00511B09` — and the
prologue's `xor ebx, ebx` (`0x0040B6FA`) and `mov ebp, 1` (`0x0040B70E`) are
what make the register each arm pushes the pressed state:

| message | arm | setter → byte | pushes |
|---|---|---|---|
| `WM_LBUTTONUP` `0x0202` | `0x0040B7BB` | `0x0045EFC0` → `0x00511B08` | `ebx` = 0 |
| `WM_LBUTTONDBLCLK` `0x0203` | `0x0040B7A2` | `0x0045EFC0` → `0x00511B08` | `ebp` = 1 |
| `WM_RBUTTONDOWN` `0x0204` | `0x0040B789` | `0x0045EFD0` → `0x00511B09` | `ebp` = 1 |
| `WM_RBUTTONUP` `0x0205` | `0x0040B7B3` | `0x0045EFD0` → `0x00511B09` | `ebx` = 0 |
| `WM_RBUTTONDBLCLK` `0x0206` | `0x0040B789` | `0x0045EFD0` → `0x00511B09` | `ebp` = 1 |

So the byte the map's drag gates on is the **right** button's, and the left
button's own state lives one byte below it, read through `0x0045EFE0` by five
sites of which none is the location click `0x0045C7D0`. A remake that puts the
turn on any other button leaves the one gesture that changes this screen
unreachable; the remake's `main.gd` had it on the middle button alone until
2026-09-10, and the map looked frozen.

`0x0045EF30` and `0x0045EF40` are `cursor − anchor`, and `0x0045EEF0` warps
the cursor back onto the anchor with `SetCursorPos`, so what the routine reads
is **travel since the last frame** and never a growing displacement. The −50
is five instructions and no immediate — `neg ecx / shl ecx, 2 / sub ecx, eax /
lea ecx, [ecx+ecx*4] / shl ecx, 1` — so `campaign_tables.py` replays them
rather than reading a constant that is not there.

**The turn's units are Eng3d's 4096ths.** The step goes into the accumulator
`0x00510C50`, whose **low word** (`0x00455960`, `mov word [esp+0xc], cx`) is
handed to `0x004039A0` as the **third** of three angles with the other two
zero — a rotation about z. So 2 units per pixel is one 2048th of a turn per
pixel, and about 180 pixels of drag is a quarter turn. The rise is in world
units and is added to the eye's own height, clamped into `[−9600, 19200]`
(`cmp eax, 0x4B00` at `0x00455991`, `cmp eax, 0xFFFFDA80` at `0x004559A7`).

**The step has inertia, and it decays.** `0x0045593A`:

```c
step = (abs(request) > abs(step)) ? request : step / 2;   /* toward zero */
angle += step;
```

A larger request replaces the step; anything smaller **halves** it. That is
why the frame callback's own zero call matters: it is what brings a released
drag to rest, in about ten frames, and a port that only ran the routine while
the pointer moved would stop the map dead instead.

**The eye it turns is the selected base eye.** `aSetCameraPosition`
`0x00403560` hands its six arguments to Eng3d and writes none of the globals
back, so each frame rotates the eye selected by `0x0045D130` by the accumulated
angle:

```c
eye.xy = target.xy + Rz(angle) * (selectedEye.xy - TARGET.xy);
eye.z  = clamp(eye.z + rise, -9600, 19200);
```

Only the height carries forward. Reading it the other way — nudging the eye
the last frame left — makes the map accelerate away, and is the mistake the
accumulator invites.

Three sites clear the accumulator and all three are entries rather than
frames: `0x004541F7` (the screen's initialiser, which also clears the step at
`0x00454203`), `0x004554C9` (the map being raised) and `0x0045D134` (the
camera-preset helper).

#### 2.6.2 The perspective is a constant, not a field of view — **[code] `0x00403460`**

The 3D window says where the picture goes; it does not say how wide the lens
is, and a remake has to know. `0x00403460` — the wrapper the map calls at
`0x00455A16` and a mission at `0x00417E39` — computes the **focal length from
the window's width alone** and hands it to `Eng3d.dll`'s
`_E3D_init_3d_screen` (ordinal 3) as its fifth argument:

```c
focal = (0x004FA500 != 0) ? width / 0x004FA500
                          : (int)(width * 10.0/13.0);   /* 0x004B1010 */
```

Inside the DLL that value lands at `Eng3d.dll+0x14FE8` — whose own initialiser
is **256** — with `1/focal` computed beside it at `+0x14FF0`, which is the
divide a perspective projection is. So a camera-space point lands at

```
screen = window centre + coord * focal / depth
```

and the constant is 10/13 rather than an angle. For the map's 518-wide window
that is 398; for a mission's 520 (`0x00419D90`, `(60, 34)` by 520 × 340) it is
400. The zoom divisor `0x004FA500` is written by five sites, with 0 and with
4, none of them on the mission or map path — the fours are in the dialogue
screens — so 10/13 is what a played game sees.

The **centre** is the window's, not the screen's: `0x00404730` stores the
window's origin and extent and works from them, so the axis of the map's view
passes through (324, 210) of a 640 × 480 picture and not through (320, 240).
A remake that draws its 3D full-screen behind a plate with a hole in it has to
carry that thirty-pixel offset, because nothing else cancels it.

#### 2.6.3 The map's own markers — **[code] `fcn.00418F40`** *(2026-09-05)*

The location dots are drawn by `aMissionControl.cpp`'s own overlay pass,
`fcn.00418F40`, a sibling of the mission's ground overlay
([`43` §3](43-battle-hud.md)) over the same projection and blitter: **every
state-3 cell** — an open location — gets `map[7]`, the 17x17 ring; the cell
under the pointer gets `map[15]`, `map[12]` or `map[9]` and the selected one
`map[14]`, `map[11]` or `map[8]`, the three chosen by the location's
action-point band (1..8 or 210..217; 10..24; 50..129), with the location's
name written beside it. ~~The remake's dots are coloured **by kind** and ring
the hovered one ([`98` §6](98-slice-6-report.md)); changing
`CampaignMapScreen.marks_for` to the band table touches `test_shell` and
`test_campaign` and is recorded as a decision of the seventh slice
([`43` §11 D6](43-battle-hud.md)), not done there.~~ **Done 2026-09-12**
([`43` D6](43-battle-hud.md)). The ladder at `0x004190BF`..`0x004190F2`
(pointer) and `0x004191FB`..`0x0041922E` (selected) reads, in order: 1..8 →
15 / 14, 210..217 → 15 / 14, 10..24 → 12 / 11, 50..129 → 9 / 8, and an id
outside every band raises nothing (`or esi, -1` in front of each ladder). The
three 50x43 elements are **badges** — a picture in a coloured frame with a
leader line ending in a ring, anchored at `(38, 34)` so the ring stands on
the cell: the blue-framed base for the upgrade band, the green-framed pair
for the dialogue band, the red-framed marine for the battle band, the twin
with the filled ring for the location whose screen is up (`[0x00510C3C]`,
the id `aMapName` is asked for). The bands are exactly the kind table's
partition (`campaign.json`: upgrades 1..8 and 210..216, dialogues 10..23,
battles 51..129). The remake now draws `map[7]` on every open location and
the band's pointer badge over the hovered one; the selected twin is not shown
because a click enters the location at once. `map[0..3]`, the coloured dots,
belong to the mission's far view and the deployment screen, not to this map.

### 2.7 An upgrade base looks where its own script says — **[code] `0x00417510`, `0x00417000`** *(2026-09-08)*

The four windows over an upgrade location — HQ, the Unit Menu, the Item List
and the Upgrade Menu — sit over a **still frame of that base's own scene**,
and the view is neither the map's location preset of §2.6 nor anything computed:
it is where a scripted fly-in came to rest.

`aPlayLocationAnimation_Upgrade` `0x00417510` destroys the battle map, writes
`upgrade_%d` into the current-map name, builds it with `aCreateBattleMap(3)`,
paints `GUI\plate_7.bmp` into both buffers and hands the scene to
`0x00417000`. That routine renders into the **location map's** 3D window
(`(65, 57)` by 518x306, the same rectangle §2.6 measures) and walks a camera
path:

```c
aGetCameraPath(0, 0, &tx, &ty, &tz, &done);      /* the look-at target */
for (;;) {
    if (!aGetCameraPath(0, 1, &wx, &wy, &wz, &done)) break;   /* exhausted */
    …step the eye toward (wx, wy, wz) until within 3200 on every axis…
    aSetCameraPosition(ex, ey, ez, tx, ty, tz);
}
aSetCameraPosition(ex, ey, ez, tx, ty, tz);      /* one last, at the end */
```

The step *(read whole 2026-09-09; the 2026-09-08 reading below it had only its
first frame)* is an **exponential approach**, not a constant:

```c
n = 40;  from = eye;                       /* per leg, 0x004171C9 */
for (;;) {
    if (|eye - wp| <= 3200 on all three axes) break;        /* next leg */
    speed = 800;                                            /* 0x004171DE */
    if (this is the last waypoint)                          /* aGetCameraPath's
                                                               own out-flag */
        speed = manhattan(eye, wp) * 800 / manhattan(from, wp);
        if (speed < 80) landed = 1;                         /* 0x0041729E */
    d = direction(eye, wp);                                 /* 0x0046D400 */
    want = _ftol(d * speed);
    v   += (want - v) / n;                  /* first frame: v = want / n */
    if (n > 5) n--;                                         /* 0x00417316 */
    eye += v;
    aSetCameraPosition(eye, target);  frame();              /* 0x0040B6F0 */
    if (*(char *)0x004FCBDC) landed = 1;    /* any key or click */
}
```

Four things in that are easy to get wrong, and the earlier reading got two:

* **`n` is a smoothing divisor, not the step.** It starts at 40 on every leg
  and falls by one a frame to a floor of five, so the eye accelerates from
  `800/40` = 20 units a frame toward 800. "20 units a frame" was the first
  frame only.
* **`0x0046D400` does not answer a unit vector.** The two horizontal
  components are divided by the **larger** of them, so the dominant axis is
  exactly one; the vertical is `(wp.z >> 3) - (eye.z >> 3)` over the
  horizontal distance `0x0044AE10` returns — and *(corrected 2026-09-09)* that
  distance is taken on **shifted coordinates too**. The helper has two arms
  and the flight asks for the shifted one (`push 1` at `0x004172B1`, the last
  of its ten arguments); that arm runs `sar 3` over all six numbers —
  `0x0046D4EC`, `D4EF`, `D4F2`, `D4F5`, `D4FB`, `D504` — before
  `0x0044AE10(eye.x >> 3, eye.y >> 3, wp.x >> 3, wp.y >> 3)`. The two eighths
  cancel, so the vertical is the plain gradient: a leg that rises as far as it
  runs rises at one. Shifting only the rise divides by eight times the
  distance and the eye barely climbs at all — on `upgrade_8`, whose first
  waypoint is 12000 units **under** the ground, the whole eleven-second
  flight then happens at street level instead of lifting the eye to a −37°
  overhead sweep.
* **Each coordinate is shifted on its own.** `sar` floors, so
  `(a >> 3) - (b >> 3)` is not `(a - b) >> 3` wherever the two operands'
  remainders cross. Nine of the fifteen bases open on a waypoint with a
  negative coordinate in it — 1, 2, 4, 6, 8, 211, 212, 215 and 216 — so a
  port whose shift does not floor the way `sar` does is wrong on most of
  them.
* **Only the last leg ends the flight.** The others end on the 3200 arrival
  test on all three axes (`0x004171FF`, `0x00417212`, `0x00417224`); the last
  one counts `800 × remaining / leg` down and lands under 80 — a tenth of the
  leg — so the eye comes to rest **near** the last waypoint rather than on it.
* **The loop's frame is the front end's.** `0x0040B6F0` ends on
  `0x0047F2E0(10, 20)` at `0x0040B82D`, a limiter that busy-waits on
  `GetTickCount` until `1000/20` ms have passed. So the flight runs at
  **20 frames a second** — the same clock [`24` §5](24-briefing-text.md)'s
  typewriter does — and the eight shipped bases' flights last **2.9 to 12.8
  seconds**. §10 item 8 is closed.

`0x0040B6F0` also sets `0x004FCBDC` on `WM_KEYDOWN`, `WM_CHAR` and
`WM_LBUTTONDOWN`, and the loop reads it: **any key or click lands the flight
early**, exactly as one dismisses a cutscene.

The first `aSetCameraPosition` (`0x00417167`) puts the eye **on the first
waypoint**, so the flight starts there and not where `aCreateBattleMap(3)`
left the camera.

The path is the script's. Every `Missions/upgrade_N.lcl`'s whole `INIT MAP` is
three to five `CreateCameraPath` lines and nothing else: one `mode 0` giving
the target and two to four `mode 1` waypoints, each stored **shifted left by
four** ([`20` §10 item 2](20-lcl-language.md) has the record — five paths of
140 bytes at `0x004FCBE8`, nine waypoints maximum). So the eye ends near the
**last** waypoint, looking at the target. For location 1 the last waypoint is
`(7260, 3637, 1625) x 16` and the target `(4542, 6545, 125) x 16`; replaying
the law above puts the rest about 1600 units short of it in the horizontal and
5300 short in the height, because the landing countdown stops the flight at a
tenth of the leg.

**The flight is what the player watches, not something behind a menu.**
`0x00417510` paints `plate_7` and then *blocks* in `0x00417000`; mission
control raises the Upgrade Menu only when it returns. So entering an upgrade
location plays a framed arrival sequence in the same window and on the same
plate a dialogue cutscene uses ([`41` §3](41-sequence-player.md)), and the
menu follows it.

Two things then keep it there. The arm that called the animation reads the
camera straight back out with `aGetCameraPosition` `0x00403780` into
`0x00510D2C`..`0x00510D40`, and `0x00455A40`'s zero arm pushes those same six
into `aSetCameraPosition` on **every** Mission Control frame. Nothing in the
fifteen upgrade arms calls `0x004558F0`, so unlike the location map a base
does not turn: the drag is the map's alone.

On the way out `0x00417000` puts the 3D window back to a mission's
`(60, 34)` by 520x340.

### 2.7.1 The base's own marines — **[code] `0x00417510`, `0x004055E0`** *(2026-09-09)*

**A landing pad the flight crosses is not empty.** Between
`aCreateBattleMap(3)` and the blocking call into `0x00417000`, `0x00417510`
walks the unit array and starts one animation on every unit it finds:

```c
for (id = aGetFirstUnitOfPlayer(0);            /* 0x00477C20 */
     id != 0xFFFF;
     id = aGetNextUnitOfPlayer(0, id)) {       /* 0x00477C60 */
    rec = aGetUnitPtr(id);                     /* 0x00477AE0, refuses a dead slot */
    if (rec) aStartAnimation(id + 7, rec, 4);  /* 0x004055E0 */
}
```

Both iterators are `aUnitMap.cpp`'s own and both test the same two bytes of
the 91-byte record: `+0x16` (hit points, [`10` §5](10-lev-mission-format.md) —
zero means the slot holds nobody) non-zero, and `+0x45` (the owning player)
equal to the argument, which is `0` at both call sites. The animation **slot**
is the unit id plus seven.

`kind == 4` is the one arm of `aStartAnimation` that names its clip as a fixed
literal instead of asking a selector
([`40` §7.2](40-charisma-model-animation.md), fourth row): `P0_M2_000` at
`0x004C030C`. Its playback arm `0x00405B88` — the fifth entry of the second of
that routine's two jump tables, `0x00405C94` — is three calls and a start:

| site | call | what |
|---|---|---|
| `0x00405BDE` | `vtable+0x44(100000)` | the loop count |
| `0x00405BE8` | `vtable+0x2C(1.0f)` | the speed, against a mission walk's 2.0 ([`42` §1.2](42-mission-presentation.md)) |
| `0x00405BF2` | `vtable+0x34(aRandom2(0, 10))` | the clip's **starting time**, drawn |
| `0x00405C0E` | `vtable+0x08()` | start |

The draw is `aRandom2` `0x004638E0`, the `GetTickCount`-seeded generator of
[`22` §3.2](22-combat-and-visibility.md) — so three marines started in the same
frame are deliberately out of step, and the effect was never meant to repeat
run to run. It is outside every hash and outside the save.

**Nothing moves the units.** No `upgrade_N.lcl` contains a movement command at
all — their whole `INIT MAP` is the three to five `CreateCameraPath` lines
above — and the march is the clip's own: `P0_M2_000` is 452 frames long and
carries its top-level bone `Bip000` from `(0, 0, 0)` to
`(3.4, -3017.7, 0.96)`, i.e. 3017.7 skeleton units down engine -Y, which is
the direction every movement clip strides in
([`40` §7.2](40-charisma-model-animation.md)). At the front end's 20 frames a
second and one clip unit a frame the clip runs 22.6 seconds and then loops, and
a flight lasts about half of that, so what the player sees is a squad walking
away down the pad while the camera comes down behind them.

Corpus, all fifteen maps:

| upgrade | marines | | upgrade | marines |
|---|---|---|---|---|
| 1, 2, 4, 8 | 3 | | 210, 211, 212, 215, 216 | 3 |
| 3, 5, 6, 7 | 2 | | 213, 214 | 2 |

Every one of the 39 is type 0, weapon 0, player 0 — the plain unarmed marine —
with facings spread over 0, 1, 2, 3, 4, 6 and 7. `upgrade_6` carries a fourth
player-0 record with **zero hit points** and `upgrade_4` six player-255 records
with the same, and neither iterator reaches any of them: that is what the
hit-point test is for, and it is why "two or three" rather than "three".
`campaign_tables.py` reads all of it — both iterators, the player argument, the
three record fields, the kind, the slot bias, the arm's own three constants,
the literal and its address — and checks the corpus against them.

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
recomputeUnitStats(rec);                         /* 0x004759E0, at 0x00478B4A */
```

**The closing recompute is not decoration.** `0x004759E0` is the *full*
derived-stat rewrite, not the hand-over's short `0x004759B0`
([`25` §5](25-turn-and-round.md)), and none of the fields it writes is seeded
above: `+0x16` hit points, `+0x15` movement, `+0x19` fitness, `+0x36`/`+0x37`
armour, `+0x3A` absorber charges, `+0x58` stimulant and — the one that matters
here — `+0x3D`, the magazine, taken from `0x004752A0` for the weapon 0 the line
above gave them. A recruit therefore leaves this routine already loaded.

**`unitType = player` is deliberate, not a slip.** `Info.lcl` names unit types
0…3 `Human Soldier (1)` … `(4)`, one per player slot, differing only in the
model variant column — so a recruit gets the soldier model of the side that
hired them.

Two smaller notes. The routine's player bound is `cmp; jg` where its two
siblings (`0x004788C0` free-slot count, `0x00478960` used-slot count) use
`dec eax` first, so `aEnlargeUnitPool` admits `player == playerSlots()` where
they stop one short; no shipped path passes that value. And the seeding is the
**only** game-side reader of the skill level (§5.2).

#### The Recruit window's five categories are written-out lists — **[code] `0x004561C9`** *(2026-09-08)*

The window `0x00456640` builds offers five category buttons and five candidate
rows, and the rows are **not** a base plus four. `0x0045615F` clears the five
slots at `0x00510A14` to −1 and disables the five row gadgets, and
`0x004561C9`'s jump table (`0x00456624`) then fills the chosen category's, one
`mov dword [0x510A14 + 4k], imm32` per row, each behind its own affordability
test — an unaffordable type is left at −1 and its gadget stays off. Reading
every write in the five arms gives **twenty-three**, not twenty-five:

| button | `Txtmod_b` | unit types |
|---|---|---|
| 0 *Light Units* | 181 | 0, 1, 2, 3 |
| 1 | 182 | 10, 11, 12, 13, 14 |
| 2 *Heavy Units* | 183 | 20, 21, 22, 23 |
| 3 | 184 | 30, 31, 32, 33, **35** |
| 4 *Commanders* | 185 | 40, 41, 42, 43, 44 |

Two of them fill four slots and leave the fifth at −1, and category 3's fifth
is **35, not 34**. Against `Info.lcl`'s declared 0–3, 20–26, 30–35 and 50–68
that means *Light Units* offers four, category 3 offers five, *Heavy Units*
offers four — type 24 is declared and never listed — and categories 1 and 4
offer nothing at all.

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
record on the map through `aUI_SetUnit` (`0x00472780`, `aUI.cpp`), **runs the
full derived-stat recompute on the placed record** (`0x004759E0`, called at
`0x00478DD1` from the pointer `aGetUnitPtr` `0x00477AE0` returns for the id the
new cell carries), rebuilds visibility, then removes the slot from the pool. It
refuses `slot > 30`. Its only caller is the deploy screen, `aPI.cpp` — which is
what identifies that module ([`90` §2](90-binaries-and-source-layout.md)).

**That recompute is what fills the magazine.** A roster record's `+0x3D` comes
from nowhere else on the deployment path — `aUI_SetUnit` copies the record
verbatim — so a remake that skips it deploys a squad with an empty weapon.
`_C_100` is where that shows first and worst: it places no player-0 unit of its
own ([`98` §2](98-slice-6-report.md)), so *every* marine in the campaign's
opening mission comes out of the pool. *(Found 2026-09-06 by the remake, which
had transcribed only the short `0x004759B0`; see [`25` §5](25-turn-and-round.md)
for why the two are easy to confuse.)*

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
on `u[+0x45] == player`, recomputes the unit's stats — the **full**
`0x004759E0` again, at `0x00478EA1` — and calls the above. It has exactly one
caller: the debriefing screen, and only in game mode 1 (§6.1).

So a survivor reaches the pool **healed to their ceiling and reloaded**: the
recompute writes `+0x16` from `0x00475240`, `+0x3D` from `0x004752A0` and
zeroes the heat, the jam and the action state. The fixture saves show the
result rather than the rule — `_31_.sav`'s pool record for Sgt. Bratt reads
`hp 11` with `ep 73` (`min(15, 5 + 73/12)` = 11, his exact ceiling) and
`ammo 10` beside `weapon 2`, whose `mun` is 10.

### 3.5 The two banks — **[code] `aCopyUnitPool` `0x00478910`**

`aCopyUnitPool(from, to)` copies 2730 bytes — `30 * 91`, one whole usable row.
It has exactly **two** call sites and they are the two directions:

| Site | Call | When |
|---|---|---|
| `0x0045A914` (`aMissionControl.cpp`) | `aCopyUnitPool(0, 1)` | entering a mission |
| `0x0045E9D9` (`aMissionEnd.cpp`) | `aCopyUnitPool(1, 0)` | leaving it |

**Row 0 is the live roster and row 1 is the mission-entry snapshot.**
*(Corrected 2026-09-04; see [`98` §4](98-slice-6-report.md).)* This section
first read the two call sites as "row 0 the between-missions bank, row 1 the
mission's working copy". The first half is right and the second is not, and
the four fixture saves that carry a pool settle it:

| Save | Moment | Row 0 | Row 1 |
|---|---|---|---|
| `_5_.sav` | the campaign map | Sgt. Bratt | — |
| `_31_.sav` | the entry snapshot for `_C_141` | Sgt. Bratt | Sgt. Bratt |
| `_6_.sav`, `_33_.sav` | inside `_C_141` | **empty** | Sgt. Bratt |

Inside a mission row 0 is *empty*, because `aTransferUnitFromPoolToMap` took
the records out of it, and row 1 still holds the squad. So the working copy is
the **map**, `aCopyUnitPool(0, 1)` on entry is a snapshot, and
`aCopyUnitPool(1, 0)` on the debriefing's *back to the map* button restores
the **pre-mission** roster — which makes that button a replay rather than a
step forward. `docs/11` §5.7's own reading, "mission-entry snapshot", was the
right one.

One thing the saves do not explain: `_5_.sav` is on the map screen with row 1
**empty**, though neither debriefing button clears it. What clears it is not
traced; that the snapshot does not outlive the debriefing is what the save
shows, and it is why *replay* belongs to the debriefing screen — which is
where `0x0045E9CB` physically puts it.

The flat-write bug `docs/11` §5.7 records is unaffected: the row that loses
its last slot to the save's 5460-byte write is row 1, whatever it is called.

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

`0x00509F04` holds **the campaign's** tech level. *(Corrected 2026-09-04, with
§4; see [`98` §3](98-slice-6-report.md).)* It was written here as "the
mission's tech level, from the header's `+0x21E`", and that is the front
end's path rather than a campaign's: the whole image contains **four** `.text`
references to the global — `0x0043ADAB` (the multiplayer init arm, writing 4),
`0x0043AEBB` (the campaign arm, writing **1**), and the setter's and getter's
own. So a campaign's tech level is 1 from beginning to end, which is the value
all six fixture saves carry, including three taken inside `_C_141` whose own
header says 0.

Six of the getter's seven readers are in `aMenuSystem.cpp`; the seventh,
`0x0045BF4B`, stores it into `0x00510A35` beside a companion byte at
`0x00510A34`. **That pair is now pinned** — the §5.2 that stood here marked it
UNVERIFIED and guessed at "skill limit and tech limit", and it is neither:

```c
/* 0x0045BF44 */  byte [0x00510A34] = 0;                 /* the low limit  */
/* 0x0045BF4B */  byte [0x00510A35] = getTechLevel();    /* the high limit */
```

`0x0045AF21` reads the two as **one word** — `al` the low and `ah` the high —
and hands them to the list builders. There are **four**, not two: a backward
stepper and a forward one per half.

| | backward | forward | stride | record byte |
|---|---|---|---|---|
| equipment | `0x0047A090` | `0x0047A000` | 42 | `+0x20` |
| weapons | `0x0047A1B0` | `0x0047A120` | 67 | `+0x38` |

Each skips a record whose name is empty — compared against the `.bss` buffer
`0x004FA524` — and accepts one whose requirement byte satisfies
`low <= b <= high`. The item tables carry that byte: `SetEquipInfo`'s and
`SetWeaponInfo`'s tech column ([`21` §3, §4](21-info-lcl-schema.md)).

#### The third test is the one that shapes the shop

*(Corrected 2026-09-08, twice over. This section first said the catalogue at
tech 1 was **14 of 42** weapons, then **13**; both were wrong. What settled it
was a screenshot of the original's Item List at a tech level high enough for
fourteen weapons, holding nothing but human ones.)*

The **forward** stepper has an exclusion its backward twin does not, three
instructions past the range:

```c
/* 0x0047A18B */  if (record + 0x38 >= 0x0051B834) continue;  /* id < 20 */
```

`0x0051B834` is `0x0051B2F8 + 20 * 67`, so a weapon is in the catalogue only
while `id < 20`; the equipment walk is bounded the same way by where its loop
stops, `0x00517F43 = 0x00517BD1 + 21 * 42`. The backward twin needs no such
test because its caller starts it at **18** (`0x0045AF71` and `0x0045B023`,
`push 0x12`) and it only ever walks down.

So the shop is weapons **0..17** and equipment **0..20**, and ids 18 and 19
carry no `SetWeaponInfo` line at all. That is the sixteen human weapons plus
the Combot's gun and `Explosives`, both tech 99 and refused by every shipped
level — and it is why the ten alien weapons (20..29), the bayonets and bombs
(30..37), the eight `B`-variant duplicates (40..47) and `Info.lcl`'s `"-"`
placeholder (28, `* (x) No Weapon`) never appear. **At tech 1 the catalogue is
5 of 42 weapons and 7 of 19 items.** `campaign_tables.py`'s
`catalogue.*_id_bound` and `catalogue.*_wraps_from` read all four numbers back
out of the executable.

One shipped row is caught by the name compare rather than by either bound:
weapon **35**, which `Info.lcl` gives a `SetWeaponInfo2` line — model
`W_BAY0_0`, icon 0, key `*` — and no `SetWeaponInfo` line at all, so the
`.bss` table's name field for it stays zero. And no shipped header sets either
level above 12, which is what makes the three tech-99 items unbuyable
([`21` §3](21-info-lcl-schema.md)).

#### The limits are the **upgrade location's** in a campaign — **[code] `0x0045BF2A`, `0x0045C7D0`**

The write quoted above is one of two arms. `0x0045BF2A` branches on
`0x0043B740`, and only the arm a campaign does *not* take reads the tech level:

```c
/* 0x0045BF2A */  if (gameMode() == 1) {              /* the campaign arm */
                      byte[0x510A34] = byte[0x510C5C];
                      byte[0x510A35] = byte[0x510C5D];
                  } else {
                      byte[0x510A34] = 0;
                      byte[0x510A35] = getTechLevel();
                  }
```

`0x00510C5C`/`0x00510C5D` are written by **fifteen** sites inside
`aPlayLocationAnimation` `0x0045C7D0`, one per upgrade arm and each right
after its fly-in returns — so **each upgrade base sells its own band of tech
levels** rather than everything up to the campaign's one, and the campaign
tech level gates nothing at all. The arm a location reaches is
`0x0045CF8C`'s index into `0x0045CF2C`, which is the same switch §2.4 reads
for the map, so the pairing is exact:

| location | map | band | | location | map | band |
|---|---|---|---|---|---|---|
| 1 | `upgrade_1` | **0–0** | | 210 | `upgrade_210` | 0–0 |
| 2 | `upgrade_2` | 0–3 | | 211 | `upgrade_211` | 0–1 |
| 3 | `upgrade_6` | 0–5 | | 212 | `upgrade_212` | 0–2 |
| 4 | `upgrade_4` | **1–1** | | 213 | `upgrade_213` | 0–3 |
| 5 | `upgrade_5` | **9–9** | | 214 | `upgrade_214` | **3–3** |
| 6 | `upgrade_3` | 0–4 | | 215 | `upgrade_215` | 0–4 |
| 7 | `upgrade_7` | **0–9** | | 216 | `upgrade_216` | 0–9 |
| 8 | `upgrade_8` | 0–2 | | | | |

**Two pairs of arms share one body.** Locations 1 and 210 both enter
`0x0045CB26` and 7 and 216 both enter `0x0045CDAB`: the compiler tail-merged
the identical bodies, and the two arms that lost their own reach it with a
far `0F 85` jump rather than falling through. Reading an arm's bytes forward
from its entry therefore walks into the **next** location's body, which is
how this table first gave location 1 the band of 2 and location 7 the band of
8 — the second of those made base 7 sell seven weapons where the engine sells
sixteen. `Binary._arm_body` resolves the `CHECK` macro's own `jne` instead,
and `upgrade.shared_body_*` pins the two merges.

Three encodings appear: the literal (`mov byte [addr], imm8`), `bl` — which
the dispatcher's own `xor ebx, ebx` at `0x0045C7E0` holds at zero for every
arm — and an `al` a `mov al, imm8` in the same arm set, which is how location
5 writes 9 into both ends at once. **Three bands do not start at zero**, and
that is the part a "high limit only" reading loses: locations 4, 5 and 214
sell one tech level each and nothing below it, so a base can stock nothing a
recruit is able to use.

#### The *Item List* paints every row it is given — **[code] `0x00459D10`**

Window 5 carries no scroll gadget and the engine paints its rows itself, in a
loop that ends only when the forward stepper runs out: each row is laid at
`x` 80, then 330, and the wrap test `x > 500` starts a new line with `y += 35`.
So there is no page and no cap — a catalogue wide enough simply runs down the
plate. Equipment is the widest half at ids 0..20, which is eleven lines of two.


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

#### The other half of the price is skill points — **[code] `aBuyWeapon` `0x00475680`, `aBuyEquipment` `0x004755D0`**

*(Added 2026-09-08. Every claim in the three subsections below is read back out
of the shipped executable by `campaign_tables.py`'s `buy.*` checks — the two
record strides and skill fields, the four exclusive ranges with the widths of
their clearing writes, the Jet Pack's grant, the toggle, and the `short * 12`
epilogue.)*
Equipment points are only half of what a purchase costs. Both routines end the
same way:

```c
short = f(id, unit, /*apply=*/1);   /* 0x0047A600 weapons, 0x0047A6E0 equipment */
unit[+0x18] -= short * 12;          /* eax*3 << 2 */
*out        =  short * 12;
recomputeUnitStats(unit);           /* 0x004759E0 */
```

`0x0047A600` and `0x0047A6E0` walk the item's skill requirements against **this
soldier's own** `+0x1A..+0x1F`, sum `max(0, needs - has)` over them and, with
the third argument set, raise each skill to the requirement. So the *Skills*
number beside a catalogue row is **not a column of the table**: the same rifle
reads 3 for a recruit and 0 for the veteran who already trained on it, and what
it costs is that shortfall in skill points — twelve of `+0x18` each
([`10` §5.11](10-lev-mission-format.md)). The Item List prints the soldier's
own `+0x18 / 12` beside it (`0x0045A170`, text slot `0x9C`).

The two routines read their requirements from different offsets and compare
them in different orders, which is why they are two routines and not one:

| | record | requirement bytes | compared in the order |
|---|---|---|---|
| weapon | `0x0051B2C0 + id*67` | `+0x33..+0x36` | LW, HW, TS, CON |
| equipment | `0x00517BB0 + id*42` | `+0x23..+0x28` | LW, HW, TS, CON, LS, MS |

#### `aBuyEquipment` is a **toggle**, and it clears whole groups

Three things the screen does that "spend and set a flag" would miss:

* an item **already carried** is switched **off** (`0x004755F2` writes 0 into
  `unit[+0x21 + id]` and returns) — and the caller has already spent the cost
  at `0x0045A9E9`, so a second click removes the item *and charges for it*;
* buying one member of a group clears the others — `id <= 1` the two scanners
  (`0x0047561D`), `3 <= id <= 4` the stimulants (`0x0047562D`),
  `10 <= id <= 13` the four armours (`0x00475611`) and `15 <= id <= 16` the
  medic kits (`0x0047563D`); so a soldier carries one of each at a time;
* the **Jet Pack also grants Long Range Scan** — `id == 7` writes
  `unit[+0x22] = 1` (`0x00475603`), which is `Info.lcl`'s own `* warp & scan*`
  annotation made good. The other direction is the screen's rather than the
  routine's: with the Jet Pack carried, a purchase of `Scan Module` is skipped
  entirely at `0x0045A9B6`, **before** the purse is touched.

The toggle-off path returns without the closing recompute, so an armour
removed that way leaves `+0x36`/`+0x37` stale.

#### *Undo* is the whole visit — **[code] `0x0045B507`**

Gadget 18 restores 91 bytes from `0x00510E00` over the soldier's record and
calls `0x0043BD40`, which copies 720 bytes from `0x00509A48` over the live
economy block at `0x00509D18` — the equipment points, the decoration pool and
the two levels. Both halves of that snapshot are taken where the window is
**built**, `0x0045C054` with `0x0043BD20` beside it, so *Undo* reaches back to
the moment this soldier was selected and not to the last purchase. That is
also why *Buy Item* and *Undo* share a position: `Menu_b.lcl` writes gadget 0
and gadget 18 both at `(405, 384)`.

**Which of the two the position shows is decided per catalogue row, not per
visit.** The item window's refresh -- `0x00457B00` for equipment and
`0x00457DA0` for a weapon, each called from the two catalogue arrows, from the
*Buy Item* arm, from *Undo* and from the window's build -- runs three tests
over the row that is up and, when all three pass, **enables gadget 0 and
disables gadget 18** (`0x00457CFD`/`0x00457D07`, `0x004580D9`/`0x004580E3`):

| test | weapons | equipment |
|---|---|---|
| not already carried | `0x00458037`, the row against the record's `+0x3F` | `0x00457C51`, the flag at `+0x21 + row` |
| price fits the purse | `0x00458061`, the record's `+0x3E` | `0x00457C85`, the record's `+0x20` |
| skills within reach | `0x004580D5`, `0x0047A600`'s shortfall x 12 against `+0x18` | `0x00457CF9`, `0x0047A6E0`'s |

A failing test disables gadget 0 and **leaves gadget 18 alone**, so the *Undo*
half is a flag with writers of its own: *Buy Item* enables it as the first
instruction of its arm, before the purchase is even attempted (`0x0045A970`),
*Commend Unit* enables it past the decrement (`0x0045AEC3`), and the window's
build disables it (`0x0045C075`). *Undo* itself writes neither. Two
consequences a "show *Undo* once anything has changed" reading gets wrong:
stepping off a purchase onto another row the soldier can still afford puts
*Buy Item* back, and a row that fails while nothing has been bought leaves
**both** gadgets disabled.

The price test is the **full** price even for a weapon swap, which
`0x0045A970` then charges only the difference of -- it refunds the carried
weapon before it spends. The two are consistent only read together: the
greying is what keeps the cheaper arithmetic out of reach.

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

`_C_133`'s next map is `_C_YYY`, and that is **not** a hand-over to campaign 2
*(corrected 2026-09-08)*: `_C_YYY.lev`'s header carries mission id **255**, the
value `0x00456FC0`'s gate reads as the animated `Video/Extro` (§2.3), after
which `0x00457180` sleeps 4000 ms and raises the credits — so `_C_YYY` *as a
mission* is chain 1's ending, the way `_C_180` (id 180, the static extro) is
chain 2's. The same file is campaign 2's location map when it is loaded as a
map. The converter therefore keeps `_C_YYY` as a mission row beside `_C_180`.

**There are two clean starts, and the campaign number picks between them.**
*(Sharpened 2026-09-04; see [`98` §2](98-slice-6-report.md).)* The two chains
are `_C_100`…`_C_133`→`_C_YYY` and `_C_140`…`_C_179`→`_C_180`, and
`aInitGameControl`'s campaign arm ends by switching on the campaign number:

```c
switch (campaignNumber()) {                    /* 0x0043B760 */
  case 1: strcpy(GameControl.mapName, "_C_100"); break;   /* 0x0043AF57 */
  case 2: strcpy(GameControl.mapName, "_C_140"); break;   /* 0x0043AF2A */
  default: error("...", aGameControl.cpp);
}
```

so `_C_100`, whose header carries mission id 1, is campaign **1**'s start and
`_C_140` is campaign **2**'s. What this section said before — that a clean
start enters the second chain — was a reading of one save:
`tests/fixtures/saves/_0_.sav` is "the only fixture from a session that went
straight into the campaign" and the mission it names is `_C_140`
(`tests/fixtures/saves/README.md`). That shows **that session** chose campaign
2, not that the other start does not exist. All six fixtures carry
`campaign = 2` at `GameControl + 0x1D1`, which is consistent with both.

It is also what makes §3.1's seed campaign 1's: campaign 2 seeds nothing, and
its opening squad is the four units `_C_140.lev` places itself — Sgt. Bratt
`+0x4D = 2` and Rock, Austin and Knox `+0x4D = 1` — which reach the pool at its
debriefing. Noticed while choosing a mission for the first vertical slice's
native capture ([`93` §9](93-slice-1-report.md)), which is why `_C_141` — the
second mission actually played — is the one the capture runs on.

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
4. **The roster rules**: seed a new **campaign 1** with Bratt/West/Maxon
   exactly as §3.1 gives them (campaign 2 seeds nothing and takes its squad
   off `_C_140`'s own map); hire for 60 points; sort by EP descending; carry over only
   units with `+0x4D != 0`, and drop when the 30 slots are full. That choice is
   **decided** in [`92` §7.4](92-remake-architecture.md): the rule stays, but
   the silence does not — the mission-end screen names the survivors that were
   lost, and deploying with a full roster warns first.
5. **The two banks**: copy row 0 → row 1 on entry and row 1 → row 0 on exit, or
   model the same thing with an explicit snapshot.
6. **Mission end**: the result-to-score table of §6.2, the difficulty
   multiplier in campaign mode only, and the two payouts gated on result ≠ 5.
7. **Chaining**: the header's next-map field, overridable by
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
| `level.*` | skill and tech levels and where they come from — including that the tech-level global has exactly **four** `.text` references (the two `aInitGameControl` arms and the setter/getter), which is what says a campaign's cannot move, and the two init arms' own immediates and first-mission strings |
| `catalogue.*` | the purchase filter of §5.2: the two limit writes at `0x0045BF44`/`0x0045BF4B`, and both iterators' record stride, name offset and empty-string buffer |
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
2. ~~**Which upgrade location writes which tech band.**~~ **Closed** — §5.2's
   table. `aPlayLocationAnimation` `0x0045C7D0` switches on the location
   through `0x0045CF8C`/`0x0045CF2C`, and each of the fifteen upgrade arms
   writes its own pair right after the fly-in returns: a literal, a `bl` that
   the dispatcher's own `xor ebx, ebx` at `0x0045C7E0` holds at zero, or an
   `al` a `mov al, imm8` in the same arm set. The bands run from `[0, 0]` at
   location 210 to `[0, 9]` at 216, and two of them are a single level that is
   **not** zero — location 4 sells tech 1 alone and location 5 tech 9 alone,
   so those two bases stock nothing a recruit could otherwise buy. The remake
   now gates on the entered base's band.
3. **Why locations 3 and 6 load each other's upgrade map.** Pinned as observed
   (§2.4). Whether it is an authoring slip or deliberate cannot be settled from
   the shipped data: both maps exist, both are reachable, and no text names
   which is which.
4. ~~**The other 27 `setMissionResult` sites.**~~ **Closed** — §6.4. All
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
5. ~~**What turns the campaign map's camera, and by how much.**~~ **Closed** —
   §2.6.1. The request is a pointer drag read with the cursor warped back to
   its anchor every frame (`0x00455560`, gated on screen id 6 and the button
   byte `0x00511B09`): the horizontal travel doubled into `0x00510C44`, the
   vertical multiplied by −50 into `0x00510C48`. The units follow from where
   the angle goes — the accumulator's low word is `0x004039A0`'s third angle,
   so Eng3d's 4096ths, and the rise is world units into the measured
   `[−9600, 19200]` band. It also settled two things that read backwards: the
   step **decays by halving** rather than clamping, which is what the frame
   callback's own zero call is for, and the eye that is rotated is the
   constant one, because `aSetCameraPosition` writes no global back. No
   capture was needed; the earlier entry's guess that `0x00461E60` fed the
   delta was wrong — that routine returns the scanline stride, and it is the
   call's *second* argument.

8. ~~**The fly-in's frame.**~~ **Closed** (2026-09-09) — §2.7, and it took the
   step law with it.  `0x00417000` ends its frame on `0x0040b6f0`, the front
   end's own frame function, and that ends on `0x0047f2e0(10, 20)` at
   `0x0040b82d` — a limiter that busy-waits on `GetTickCount` until
   `1000 / 20` ms have passed.  So the flight runs at **20 frames a second**,
   the same clock the briefing's typewriter does.

   Reading the loop for the limiter also showed that "20 units a frame" was
   only its first frame.  The velocity approaches `_ftol(direction × 800)` by
   `(want − velocity) / n`, with `n` reset to 40 on every leg and falling by
   one a frame to a floor of 5 — so the eye accelerates from 800/40 = 20 units
   a frame toward 800, and the flights over the eight shipped bases last
   **2.9 to 12.8 seconds**.  `campaign_tables.py` pins all six constants and
   the limiter; `test_sequence.gd` flies a path and requires it to land.
6. **The unused location bands.** `Campaign.lcl` names 110 locations; only 96
   have cells. The remainder are dialogue ids 12–14, 16–20 and 24–27, and
   location 130, *Epilogue* — which is what `_C_180` would be if its mission id
   were 80 instead of 180. Nothing reads them.
7. ~~**`0x00510DC0` and the dialogue screen's mission-id special cases.**~~
   **Closed** — §2.3.  The ids select logical sequence 0, the intercepted
   static extro screen, and logical sequence 1; the flag selects full-screen
   versus framed presentation and the background callback.

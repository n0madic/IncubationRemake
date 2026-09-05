# 43 — The battle interface: the plate, the ground overlay, the ring, the panel and the radar

**Status: delivered — behaviour, not a file format.** This document is what
[`29`](29-interface-contract.md) deliberately left out: the pixel layout of
the mission's own screen and the rules behind every mark on it, read out of
`Incubation.exe` (`aBattleMap.cpp`, `aUI.cpp`, `aMI.cpp`, `aUnitInfos.cpp`)
and out of `Graphics/GUI/plate_5.bmp` and the interface `.LIB`s. Every table
below is pinned by `tools/hud_tables.py --check gog_incubation` (**122
checks**), and `--emit-cases` hands the same tables to `godot/tests/test_hud.gd`,
which holds the remake's `game/hud/hud_tables.gd` to them. The remake's side
is the seventh slice, [`99`](99-slice-7-report.md).

Conventions: addresses are `Incubation.exe`'s virtual addresses; a cell is
the 23-byte control-map record of [`10` §4](10-lev-mission-format.md) with
its **state byte** at `+0x00` ([`23` §10](23-ai-system.md)); a unit is the
91-byte record of [`10` §5](10-lev-mission-format.md). Screen coordinates
are the 640x480 the plate is drawn in.

## 1. Sources and what each one settled

| Routine | File | What it is |
|---|---|---|
| `fcn.0041A980` | `aBattleMap.cpp` | one redraw of the frame: plate strips, window, turn text, the overlay, the radar, the options bar |
| `fcn.00417E70` | `aBattleMap.cpp` | the **ground overlay** — digits, bands, frames, unit marks, the direction ring's letters |
| `fcn.004714B0` | `aUI.cpp` | the **click handler** for the window — select, attack, raise the ring |
| `fcn.00471AD0` | `aUI.cpp` | the **ring click** — move, warp or turn, then the facing |
| `fcn.00473680`, `0x00472570`, `0x00472330`, `0x00473250` | `aUI.cpp` | the **command pad**: hit test, availability gate, redraw, executors |
| `fcn.004756D0` and `0x00474220`, `0x00474850`, `0x00474AF0`, `0x00474DD0`, `0x00475A60` | `aUnitInfos.cpp` | the **unit panel** and its five blocks |
| `fcn.00451240`, `0x00451490`, `0x00451A70`, `0x00451770`, `0x00451D50`, `0x004518E0` | `aMI.cpp` | the **button columns**: hit test, slot→event, event→sprite, event→caption, redraw, hover |
| `fcn.00451E50`, `0x00451E00`, `0x00452390`, `0x004533BD` | `aMI.cpp` | the **radar**, its coordinate map, its zoom click, its default scale |
| `fcn.004475D0`, `0x00446200`, `0x00446220` | `LibMaker.cpp` range | the **sprite blitter** and the two anchor readers |
| `fcn.0047F190` | — | the four tick counters; `[0x00523068]` steps every 100 ms and its bit 0 is every blink |
| `aChangeUnitViewDirection` `0x004792A0`, `aGetDirectionTo` `0x0047A8E0` | `aBattleSystem.cpp` | the facing written by the ring and the facing chosen after a shot |

Two things about the reading itself. Every jump table (`0x00418E68`,
`0x00418F1C`, `0x00451524`/`0x00451548`, `0x00451D0C`, `0x004518A0`,
`0x0047275C`, `0x004720F8`) was decoded from its bytes with
`inclib.pe.PEFile`, because r2's `case N` labels drift by one on a
`dec eax` switch. And the arms' immediates were read at their own
instructions rather than pattern-matched: the overlay's `mp1` element goes
through `edi` and its `mp` element through `[ebp-0x10]`, and the two are
easy to swap on a listing.

## 2. The frame — `fcn.0041A980`

* **The plate is `plate_5.bmp`**, 640x480, drawn as four strips around the
  3D window: `(0, 0, 640, 34)`, `(0, 374, 640, 106)`, `(0, 34, 60, 340)`,
  `(580, 34, 60, 340)` (pushes at `0x0041AAA6`, `0x0041AADD`, `0x0041AB4B`,
  `0x0041ABB9`; 374 and 580 are derived from the window). The window is
  **`(60, 34)` by 520x340**, written to `[0x004FE330..3C]` at `0x0041A49E`
  and read back by `0x00419D90` — the same rectangle
  [`92` §7.15](92-remake-architecture.md) found for the deployment view.
* **The turn** is written right-aligned at **(560, 22)** (`0x0041B20B`) as
  `"%d"`, or `"%d/%s"` when `SetTurnControl` set a par
  ([`20` §13 item 4](20-lcl-language.md): `0x0043BE70` is the flag,
  `0x0043BDE0` the value, `0x0043BDD0` its text) — red `0xF800` from three
  turns before the par (`0x0041B1D1`). The number is `[0x004FE388]`, which
  the redraw fills from the turn getter `0x0043B280` — `g_turn` at
  `0x00509E1D`, [`25` §4](25-turn-and-round.md) — at `0x0041A0C6`, and
  `fcn.00419D80` initialises to −1; so the groove reads **0** until the first
  hand-over, and the remake's counter, the same `g_turn`, shows the same.
* **The overlay and the radar are drawn from here directly** (`fcn.00417E70`
  with the window rectangle and the hover cell, `fcn.00451E50`); the
  columns, the pad and the panel redraw through their own callers.
* **The options bar** (`0x00460ED0`, `options.LIB`) slides in when the pointer
  is below y 449, at y 450 with nine icons at x 10, 45, …, 290 and the
  captions `Txtmod_h` 50..58 (*Toggle Speaker Position* … *Set Difficulty
  Level (only in main map during campaign)*). Every one of those is a
  control the remake's options screen already carries ([`92`
  §7.15](92-remake-architecture.md)); the bar itself is not drawn — decision
  D5 below.
* **The pointer** is `mouse.LIB`: element 0 the hand, 1 pressed, 10 the
  magnifier (`0x0045F0F0`). The eight arrows (2..9) are never drawn by the
  mission's own frame — they belong to the front end's scrolling.
* **The view never hides the plate** — corrected 2026-09-05, after a first
  pass read [`42` §2.4](42-mission-presentation.md)'s "hidden and redrawn" as
  "not drawn in the eyes view". `fcn.0041A980` does not read the view mode
  `[0x005106D8]` **at all** (no reference to it lies inside the routine), so
  the plate is drawn through view mode 1 as through any other. What does
  suppress it is one call: `0x0041AA8F` jumps the four strips when
  `0x004604D0` returns 1, and that routine returns 2 whenever the output
  system's mode is 3 (the 3D accelerator, [`97` §23.3](97-slice-5-report.md))
  and otherwise the `aOptions.cpp` global `[0x005129F8]`, written at
  `0x004601B4` and cycled through 1, 2 and 3 by the options bar. So the
  full-screen 3D view is an **option**, not a camera mode; the remake does
  not offer it and keeps the plate up everywhere.

## 3. The ground overlay — `fcn.00417E70`

Called once per redraw with the window `(60, 34, 520, 340)`, the hover cell
`[0x004FE368/6C]` (set by the pick `0x0041D960` on every mouse move) and a
font. **It is a pass of 2D blits after the 3D frame**: each cell's ground
object (`cell[+0x05]` through `aGetSymbolObjectPtr`) is projected with
`fcn.00403960`, and an element of `mp1.LIB` or `mp.LIB` is blitted through
`fcn.004475D0` at *projected point + window origin − element anchor*
(`fcn.00446200/220` read `+0x1C`/`+0x20`). No depth test exists anywhere in
it: a marked field is never hidden by what stands in front of it.
[`97` §45.2](97-slice-5-report.md) read this as the terrain tile being
coloured and drew the remake's move map as depth-tested quads on that
premise; both are corrected there.

### 3.1 Cells

The state byte selects an arm: `state - 1` indexes the 100-byte map at
`0x00418EA8`, whose value indexes the 16 arms at `0x00418E68`.

| `+0x00` | Meaning ([`23` §10](23-ai-system.md)) | Blit |
|---:|---|---|
| 1 | plain | nothing |
| **10** | reachable by walking | **`mp1[cell+0x0C]`** — the movement points left on arrival, as the element index (0..14 exist; `mp_max` never exceeds 13) |
| 27 | target near | `mp[17]` |
| **30…34** | the target overlay's hit bands ([`23` §6](23-ai-system.md)) | **`mp[43…47]`**, five 25x16 frames |
| 35 / 36 / 37 | special object / empty ground / any unit | `mp1[20]` / `mp1[21]` / `mp1[19]` |
| **50** | the selected unit's own cell (`0x00472990` writes it) | `mp[51]`, the 20x20 corner frame |
| **60** | reachable by warping | `mp1[17]` |
| 70…73 | deployment cells | `mp1[18]` |
| **100** | the chosen path (`aWalkMoveMap`) | `mp[51]` — never seen in play, below |

**Nothing shows the path** (2026-09-05, replacing this section's first
answer, which said state 100 was the computer's own and had the remake draw
an alien's steps). `aWalkMoveMap` `0x004305E0` is the only writer of it — it
marks the whole reconstructed path and resets every other cell to 1
([`23` §8](23-ai-system.md)) — and its two call sites are also the **only**
two call sites of `aExecuteMove` `0x0046E220`:

| Mover | marks | walks | a redraw in between |
|---|---|---|---|
| `fcn.0040A750`, the computer's — `aAISystemControl` `fcn.00409940` calls it nineteen times | `0x0040AB95` | `0x0040AC43` | **none** |
| `fcn.00472D40`, `aUI.cpp`'s move command — the player's click, through `fcn.00471AD0` ← `fcn.0041B6E0` | `0x00472DCA` | `0x00472E61` | `0x0041A980` twice (`0x00472E2E`, `0x00472E38`), **before** the walk |

So the state belongs to **both sides**, and the first reading's error was the
dispatcher: `fcn.0047DE90` is reached from `0x0047C2C0` only past
`cmp eax, 2` on the mode global `[0x00509EE8]` (`0x0047C985`, through
`fcn.0043B740`) — the same global whose value 2 gates the message
`fcn.00472D40` sends at its own head, and the same one `fcn.004738F0` asks
about to decide whether the current player is the local one. It is the
**network** command path, along which a second human's move arrives; the
computer's move never passes through it.

And nothing draws the mark while a body walks. The ground overlay
`fcn.00417E70` has exactly four call sites — `0x0041AD8B` in the HUD redraw,
`0x004567A5` and `0x004568BD` in `aMissionControl`, `0x0047CC8E` — and none
is inside `aExecuteMove`. The computer's walk paints its path nowhere at all;
the player's is painted into the one frame before the body sets off, over a
window the walk's own frames re-render. **Neither is visible in play**, which
is what the original shows, so the remake draws nothing along a walk and
`GroundSprites` produces no state 100.

**The indirect call is traced too** (2026-09-05, closing this section's own
first open question). `fcn.0047D600` pushes `0x0047C2C0` at `0x0047D68F` and
hands it to `aAISystemControl` as its third argument; `fcn.00409940` stores
that argument in `[0x004FAE38]` (`0x00409956`) and calls it at `0x00409971`,
`0x00409BE0` and `0x00409C92`. Those four instructions are **every**
reference to the global in the image, and `0x0047C2C0`'s own address is
written exactly once — in that one push. The frame routine is therefore
reachable only from inside the computer's turn, between its commands, and
never from a blocking animation. `aExecuteMove` holds no indirect call at
all, and over the binary's whole call graph (2246 nodes) the 754 functions
reachable from it by direct calls include neither `fcn.00417E70` nor
`fcn.0041A980` nor `fcn.0047C2C0`; the computer's mover `fcn.0040A750`
reaches the overlay by no route (810 nodes), and the player's `fcn.00472D40`
by exactly one — `0x00472D40` → `0x0041A980` → `0x00417E70`, the redraw
before the walk.

So the player's marked path is on screen for that single redraw and is gone
with the walk's first rendered frame; the computer's is never drawn at all.
`hud_tables.py`'s ten `path.*` checks pin the readings out of the bytes —
the two movers' calls, the redraw's position, the network gate, the
callback's confinement and the overlay's four call sites. The transitive
half is a call-graph result rather than a byte check: the tool has no
function boundaries, and an approximation that guessed them merged uncalled
routines into their neighbours and produced a path that does not exist.

Two gates sit in front of the table:

* **States 10 and 60 are drawn only while the pointer is over a legal cell**
  — `var_34h` is set at `0x00417F23` when the hover cell's own state is 10
  or 60 (`0x00417ED7`, `0x00417EDB`), and arms 1 and 12 return without a
  blit when it is clear (`0x00418254`, `0x00418263`). The fill is therefore
  **invisible until the pointer is on it**, which is what a screenshot of the
  original shows and what the remake's tour scenario has to hover for.
* **The hovered cell blinks and takes the frame.** With its state 10 or in
  30..73 its own digit is dropped on every odd 100 ms tick
  (`test byte [0x00523068], 1` at `0x00418329`) and `mp[48]`, the 19x19 frame,
  is blitted over it (`0x00418334`); a hovered cell with a *visible* unit on
  it takes the frame alone. The hover is redirected to a unit's anchor cell
  (`+0x42/+0x43`) unless the cell's state is 35.

### 3.2 Units

For every live unit (`+0x16 != 0`) at its anchor cell, in the **near view**
(camera height below `0x17700`, see §3.3) and for **the current player's**
units only (`0x0043B2C0`), with no state-35 marker on the cell:

* the element is the hit points as a digit, `mp[min(hp, 15)]`
  (`0x004186D3`, `0x00418708`) — **only while `+0x15` is non-zero**
  (`0x004186AF` jumps the whole digit block to `0x00418710` when the unit has
  no movement points left), so the numbers stand over the units that have not
  finished their turn and go out one by one; `+0x41 == 1` (on overwatch)
  replaces it with `mp[49]` (`0x00418710`), else `+0x40 != 0` (a jammed
  weapon) with `mp[50]` (`0x00418727`) — and those two are written past that
  jump, so a spent unit still shows them;
* `+0x41 == 5` (panic) adds `mp[54]` as the frame layer (`0x0041872F`);
* a unit with points left standing on a state-100 cell alternates the two
  path frames `mp[51]`/`mp[52]` on the tick (`0x004186BA`, `0x004186EC`,
  `0x004186C3`) — the same arm as §3.1's marks, unreachable in play for the
  same reason, and not reproduced.

### 3.3 The far view

Above camera height **`0x17700`** (`0x00418343`, `0x00418439`) the digits are
replaced by flags from `map.LIB`: a visible unit (`+0x4F == 0`) draws
`map[owner]` for players 0..3 and `map[4]` for 255; a **detected** one
(`+0x4F == 1`) draws `map[6]` — **at element 4's anchors**, an engine quirk
(`0x00418580` reads element 4's deltas for element 6) the remake reproduces;
a unit whose cell is in the attack scratchpad 80..94 blinks `map[5]` on the
per-draw counter `[0x004FE264]`. **Victory points** appear here too: a cell
whose action point `+0x0B` is 80..89 blits `mp[+0x0B − 63]` = 17..26, the
letters A and B in grey, red, white, blue and yellow (`0x00418358`).

The remake's camera never gets there in play: `CameraRig.zoom_by` refuses an
eye outside the map's box, whose ceiling is the mission's authored
`camera_height` — 19 200 to 64 000 over the cache's eight maps, all below
`0x17700` = 96 000. The flags are implemented and pinned by `test_hud.gd`
(`GroundSprites.refresh(..., far = true)`), not played.

### 3.4 The blitter and the anchors — closes [`60` §6](60-lib-sprites.md)

`fcn.004475D0(lib, index, dst, pitch, x, y)`: the element record is
`lib + [lib+0x0C] + 36·index` (`0x004475E4`, `0x004475EA`), its pixels at
`lib + [lib+0x10] + [element+0x10]` (`0x004475F0`, `0x004475FB`), and the
inner loop skips **palette index 0** (`cmp al, 0` at `0x0044772D`) in every
library — so the 34 libraries whose index 0 is never used are simply
opaque, and [`60` §6](60-lib-sprites.md) item 2 is closed. Item 1 closes
with it: the anchors `+0x1C/+0x20` are read **only** where a caller calls
`0x00446200/220` before the blit — the ground overlay, the panel's icons,
the radar's marks, the cursor — while the columns and the pad blit their
`mi`/`ui` elements at their slot's top-left and never read theirs. The 16-bit
path goes through the remap table `fcn.00447BB0` sets (`[0x0050C230]`; index
255 maps to 0) and the clip `fcn.00447B20` sets (`[0x0050C220..2C]`).

The libraries and their handles: `aInitBattleMap` `0x00417790` loads `mp`
→ `[0x004FD234]`, `mp1` → `[0x004FD640]`, `map` → `[0x004FDA4C]`, `dir` →
`[0x004FDE58]`; `aInitMapInterface` `0x00450A80` loads `mi` → `[0x0050FEA0]`
and `sm` → `[0x005102AC]`; `0x00473A20` loads `uicons`, `inv`, `uweapons`,
`umun`, `uequip` → `[0x00517B98..A8]`; `aInitUI` `0x004710E0` loads `ui` →
`[0x0051632C]`. Each is passed as `push &handle` beside its name.

## 4. The click and the direction ring

### 4.1 The click handler — `fcn.004714B0(x, y)`

In order: nothing before turn 1; the **pad** first (`fcn.00473680` with the
hit code 42, then `fcn.00471310`); outside the window `[0x00516754..60]`
nothing; the cell is stored in `[0x005162E0/E4]`; then by the cell's state:

* **60** — mode 3 (warp) into `[0x00516310]`, ring built on the cell
  (`fcn.004721A0`), sound `[0x0051630C]`;
* **10** — mode 1 (move), the ring built on the cell;
* otherwise the cell is redirected to the unit anchor standing on it, and
  * **30…37** — `fcn.00473080` fires at the cell, then
    **`aGetDirectionTo(sel, 0)`** turns the shooter to its best band
    (`fcn.004735D0`) and `0x00472990` reselects it;
  * the **selected unit itself** — mode 2 (turn in place), the ring built
    on its own cell;
  * **another own unit with `+0x15 != 0`** — the old selection is dropped
    (`0x00472B10`, which turns it to its nearest target) and the new one
    made: `0x00472990` resets every cell to 1, runs `aBuildMoveMap`, runs
    `aBuildTargetOverlay` `0x0042FF30` and writes 50 on the unit's cell;
    speech `0x0047B660`; the arrows `0x00473920`. **A unit with no movement
    points cannot be selected** — `0x00471CB6` returns before any of it;
  * an empty cell — deselect.

`[0x005162F4] = (distance > 30) + 1` is written and never read.

### 4.2 The ring — `fcn.00406AA0`, `fcn.00406CA0`, the letters in `fcn.00417E70`

Ten 64-byte records at `[0x004FA52C]` (the `.lev`'s runtime block,
[`10` §6.1](10-lev-mission-format.md)) hold nine positions around the clicked
cell's **object** — `x, y, z` of `aGetSymbolObjectPtr`'s record — with
`z − 500`:

| d | offset | letter (`dir.LIB`) | facing |
|---:|---|---|---:|
| 0 | `(0, +0xDDE)` | 0 **N** | 0 |
| 1 | `(−0xDDE, 0)` | 2 **W** | 1 |
| 2 | `(0, −0xDDE)` | 1 **S** | 2 |
| 3 | `(+0xDDE, 0)` | 3 **E** | 3 |
| 4…7 | `(±0x93E, ∓0x93E)` | 4 · | 4…7 |
| 8 | `(0, 0)` | 5 **X** | cancel |

(the letter table is the jump table `0x00418F1C`, whose arms load `ebx`;
0xDDE straight and 0x93E diagonal at `0x00406AFE`/`0x00406B34`.) The facing
→ neighbour cell is `fcn.004308C0`'s table — [`Interact.FACING_DX/DY`] in
the remake — and the facing → 4096-unit angle the object turns to is
`fcn.0046A6E0`'s: `0, 0xC00, 0x800, 0x400, 0x600, 0xE00, 0x200, 0xA00`.

`dir.LIB` has three tiers of six: plain, **+6 green** (hovered), **+12
yellow** (blocked). A record is *blocked* when its neighbour cell is off
the map, holds a unit, carries an action point in 10..70 or a mine
(`+0x10 == 2`). Per draw (`0x00418C51`..`0x00418D60`): the hovered record
is green — or blinks green when blocked — and a non-hovered blocked one
blinks yellow on the tick; a hovered record more than 20 px from the
pointer (`0x00418CE0`) is green too. Every letter is clamped to
`[ox − 4, ox + w − 9] × [oy − 4, oy + h − 9]` of the window (`0x00418CB9`).
The hit test `fcn.00406CA0(mx − ox, my − oy, 600, 600, &hit, &dist)` is the
**nearest record within 600 px** (`0x00418A3D`), which on a 640-wide screen
is simply the nearest; a change of hovered record plays `[0x00516304]`.

### 4.3 The ring click — `fcn.00471AD0`

On the button's release: record 8 cancels the mode. Otherwise **mode 1**
runs `fcn.00472D40` = `aExecuteMove(…, &cost, 1, facing)` (the facing is the
seventh argument; `mp −= cost`, `+0x39 = 3`, reactions through
`0x0046CCA0`); **mode 3** runs `fcn.00472F10` = `aExecuteWarp` (`mp = 0`,
`+0x39 = 5`); **mode 2** runs nothing. Then, in every mode,
`fcn.004735D0(dst, facing)` → **`aChangeUnitViewDirection(x, y, facing, 1)`**
writes `+0x46` and turns the object (`0x00479345`, `fcn.0046A6E0`); unit
types 61..63 refuse (`0x00479330`). **No point is charged and no visibility
rebuilt.** The unit is reselected at its destination (`0x00472990`); with
`+0x15 == 0` it is deselected instead (`0x00471CB6` → `0x00471E00(0)`),
else speech and `0x004533D0`.

### 4.4 `aGetDirectionTo` reads the state byte — corrects [`23` §3.6](23-ai-system.md)

`0x0047A8E0(x, y, mode)`: mode 0 accepts a cell whose **state byte**
`cell[+0x00]` is 30..34 (`0x1D < *cell < 0x23`), and the ratchet compares
**the same byte** (`bVar9 <= *cell`) before the strict distance test.
`23` §3.6's pseudocode had labelled that byte `actPt`, and both models —
`inclib/combat.py` and `core/combat.gd` — read the action point `+0x0B` in
both places until 2026-09-05. The captures could not tell: with no overlay
every cell reads 1 and every action point on an enemy's cell reads 0, and
either way the ratchet degenerates to the nearest. Both twins now take the
overlay bytes as a parameter (the AI passes its context's `state`, the
interface the selection's bands), `test_hud.gd` pins that a farther target
on band 33 beats a nearer one on 31, and all the gold checks still pass.

### 4.5 The selection is a global, and the hand-over does not touch it (2026-09-05)

Reported as *"in the original, when the computer's turn ends one of my
soldiers is selected; in the remake nobody is"*. It is not a hand-over
routine. The selected slot lives in **`[0x005162F0]`** — `0xFFFF` for none —
with its cell cached beside it in `[0x005162E8]`/`[0x005162EC]`, and the whole
image writes it in five places:

| site | writes | what it is |
|---|---|---|
| `0x00471220` | `0xFFFF` | `fcn.004710E0`, called once, from `aInitBattleGround` `0x0041A54C` |
| `0x00472320` | `0xFFFF` | the arm of `fcn.004721F0` that finds the side has no live unit at all |
| `0x00472CFB` | `0xFFFF` (out of `cx`) | `fcn.00472CC0`, the tail every player command runs — §4's "a unit that has spent its movement is dropped after its command". Its four callers are `aUI.cpp`'s command executors, reached from the click, the ring and `0x00471310`, and from the network pump for a remote player's command |
| `0x0047225B`, `0x00472305` | a slot | the two that select one |

Seven instructions in the whole `.text` name `0x005162F0` — those five and the
two reads at `0x00471E49` and `0x004721F0` — and `hud_tables.py` counts them
rather than trusting one cross-reference listing. **Neither `fcn.0047D600` nor
`fcn.0047DC60` is among them**, so the marine the player last had is still
selected when the computer is done: the global simply survives the turn. That
is the whole mechanism.

There is a **second** word beside it. `0x005162F0` is what has been *asked
for*; `0x005162F8` is the selection the interface is actually on, with its
cell in `0x005162FC`/`0x00516300`, and it is written by the select itself
(`fcn.00472990` at `0x00472A90`). `fcn.00471E00` compares the two
(`0x00471E49`, `0x00471E56`) and runs the select only when they differ. Its
own resets are the same shape: `fcn.004712A0`, once, from the same mission
init, and the two command tails `fcn.00472B10` and `fcn.00472CC0` — again
nothing on the turn's path.

The other half is what happens when it *is* empty. `fcn.004721F0(mode)` is
the one routine that moves the selection, and its **first** branch runs before
it looks at its mode: if the slot is `0xFFFF` it takes `fcn.00477CE0`'s answer
and returns. Everything reaches it through `fcn.00471E00(mode)`, which refuses
twice first — `0x0043B280`, no selection before the first hand-over, and
`fcn.00477BF0(side)`, none for a side with no live unit.

`fcn.00477CE0(side)` is **two passes over the 200-record array**, and the
second one drops a test the first makes:

1. the lowest-numbered unit with `+0x16 != 0` (alive), `+0x45 == side` and
   `+0x15 != 0` (movement left);
2. failing that, the lowest-numbered one with only the first two;
3. failing that, `0xFFFF`.

The second pass is why the original still has somebody selected at the end of
a turn on which everything has moved. The modes are `fcn.00477EC0` (0) and
`fcn.00477D40` (1), the two cycles. Two places ask for a selection without a
click: `aInitBattleGround` `0x0041A738`, `mode 1`, at the start of the first
turn — and the turn-counter gate above means it does nothing there, so a
mission opens with **nothing** selected until the first hand-over — and the
**`SelectNextUnit` script command**, `fcn.00441270` → `fcn.00471E00(0)`,
which the LCL dispatcher reaches by name at `0x0044438D` and which **no
shipped `.lcl` uses**, so it changes nothing in the shipped game. The remake matches that: on `_C_140` the reply reads
`selected -1` at turn 0 and `selected 2` at turn 1.

**And the camera follows the selection** — which closes
[`42` §2.6](42-mission-presentation.md)'s "the engine's select camera is not
traced". It is not a camera routine of its own: every caller that gets a `1`
back from `fcn.00471E00` calls **`fcn.004533D0`**, which re-applies the
*current view mode* on `fcn.00471F70`'s cell — the cell the select just wrote
into `0x005162FC`/`0x00516300`. Five sites do it: `aInitBattleGround`
`0x0041A754`, `SelectNextUnit` `0x0044127E` (a tail `jmp`), the drop of a
spent unit `0x0047149B`, the click `0x004717E8` and the ring `0x00471C42`.

| `[0x005106D8]` | placer | what it does |
|---:|---|---|
| 0 | `fcn.00453410` → `fcn.004532A0` | the map's centre at height `0x23A50` — no unit in it |
| 1 | `fcn.00451150` → `fcn.00452E90` | the map view on the unit's cell |
| 2 | `fcn.004510A0` → `fcn.004529D0(x, y, 8, 7, 0)` | **on the unit**, and the same `(8, 7, 0)` [`42` §2.3](42-mission-presentation.md) had recorded for the cycle alone |
| 3+ | `fcn.00450F60` → `fcn.00453150` | the normal view on the unit's cell |

Mode **2 is what a mission opens in** (`fcn.00452940` writes it), so selecting
a unit puts the camera on it at `(8, 7, 0)` unless the player has changed the
view. Modes 1, 2 and 4 all fall back to `fcn.00450F60` when there is no
selection to centre on.

**At the start of a mission** `aInitBattleGround` does both at once: `0x0041A738`
asks `fcn.00471E00(1)` for a selection and, when the turn counter is exactly 1
(`0x0041A74D`), applies `fcn.004510A0` — the unit view on the unit it just
selected. The counter-0 arm beside it is the other entry: view mode 2 with no
placement (`fcn.00452940`) and the camera on the landing zone
(`fcn.00452420`, the first control-map cell in `'F'..'I'`).

> **UNVERIFIED — which of the two arms a fresh mission takes.** The controller
> enters `aInitBattleGround` as one request (`fcn.0042E690` case 7) and it
> leaves the game in state 3, whose per-frame case is `fcn.004543A0` — and
> that is what increments the counter, so a first entry would find it at 0 and
> take the landing-zone arm, with the counter-1 arm reached only on a re-entry
> such as a load. **The shipped game nevertheless opens a mission with a unit
> selected and the camera on it**, which is a report from play rather than
> something read here, and it is the counter-1 arm that describes it. The
> remake does that; if the ordering turns out otherwise, this is the paragraph
> to correct.

**In the remake** the selection *is* dropped, for the length of the replay
only: the watched screen has no panel, no pad and no overlay to show it on
(§7). `SliceMain._resume_selection` puts it back where the turn comes back to
the player — both paths, the replay's end in `_on_ai_step` and the
nothing-to-replay path in `end_turn` — and it is the engine's rule twice over:
the same unit if the computer left it alive and able to move
(`_selection_before_turn`, which is `[0x005162F0]` carried over the window),
and `SliceMain.first_friendly_slot`, both of `fcn.00477CE0`'s passes,
otherwise, and `SliceMain._frame_units` selects the same unit it opens the
view on at mission load. **The camera goes with the selection**, through
`select_unit`, because that is what a select does above;
`COMPAT_CAMERA_RETURNS` is a different thing — the remake's own camera return
with *no* selection behind it — and stays off by default. Which of the four
placers the remake uses is still its own choice
([`92` §7.5.3](92-remake-architecture.md)): `CameraRig.focus_on` flies the
target onto the unit and keeps the eye's offset, so a selection re-centres the
view without discarding how the player had arranged it.

## 5. The interface

### 5.1 The command pad — `aUI.cpp`

Click rectangle `x 404..494, y 382..478`; column `(x − 404) / 30`, row
`(y − 382) / 48` (`0x004736A0`..`0x004736EB`). `0x00472120(col, row)` gives
the command, and `0x00472570(col, row)` the sprite — or −1, drawn as `ui[0]`,
the empty socket. `ui.LIB` is seven pairs, dim then bright (hover is
element + 1):

| (col, row) | command | `ui` | gate `0x00472570` | executor `0x00473250` | key (remake) |
|---|---:|---:|---|---|---|
| (0, 0) | 1 **Def** | 2 | `0x004753E0`: `mp ≥ 2`, `+0x40 == 0`, `+0x3D != 0`, `+0x41 != 1`, `weapon[+0x32] & 1` | `0x00478500` — `+0x41 = 1`, ticket; mp zeroed if already waiting | D |
| (1, 0) | 2 **heal** | 4 | `0x0047B4C0` and `+0x15 ≥ 1` | `0x00470890` — `mp − 1`, `+0x39 = 3` | H |
| (0, 1) | 3 **stimulant** | 8 | `+0x58` not 0 and not 255, and a point | `0x004785B0` | S |
| (2, 0) | 5 **weapon mode** | 6 | `0x00475430`: `toggle != id`, `+0x3D ≥ toggle[+0x41]`, `+0x15 ≥ toggle[+0x3C]` | `0x0047A8C0` — `+0x3F = weapon[+0x3D]` | W |
| (1, 1) | 7 **rest** | 10 | `+0x39 == 0` and species ≠ 3 | `0x00478570` — `+0x41 = 7`, `mp = 0` | R |
| (2, 1) | 8 **use** | 12 | species ≠ 3, a point, and a target (`0x0047A530`: AP 10..49 but 32/33, or `0x0047B250`/`0x0047B410`/`0x0047B480`) | `aExecuteUse` — `mp − 1`, `+0x39 = 3` | U |

Sockets are blitted at `(404 + 30·col, 382 + 48·row)` top-left
(`0x00472330`). The hint for the socket under the pointer is `Txtmod_h`
**40, 43, 41, 42, 44, 45** for commands 1, 2, 3, 5, 7, 8 (`0x004720F8`), at
(60, 22). The key column here and in §5.2 is the **remake's** binding
(`main.gd`); the original's keyboard translator was not read in this pass,
and nothing in this document claims a key of the original's.

### 5.2 The button columns — `aMI.cpp`

Two click columns, `x 11..49` and `594..632`, `y 66..345`, row
`(y − 66) / 31` (`0x00451240`); the sprites are blitted at
`(11 | 594, 66 + 31·row)` (`0x00451D50`, +0x247 for the right column) with
`mi[31]` in an empty or unavailable slot and element + 1 under the pointer.
`0x00451490(col, row)` gives the interface event of `0x00453900`
([`29` §1.2](29-interface-contract.md)); `0x00451A70(event)` the sprite;
`0x00451770(event)` the caption written at (60, 22):

| column, row | event | `mi` | caption (`Txtmod_h`) | what it does | key (remake) |
|---|---:|---:|---|---|---|
| left 0 | 8 | 6 | 26 *Remind position* | save slot 32 (`0x0041DA20` cmd 5) | F1 |
| left 1 | 7 | 8 | 27 *Recall position* | load slot 32 (cmd 6) | F2 |
| left 2 | 6 | 2 | 24 *Save game* | the save dialog `0x00448770(1)` | F3 |
| left 3 | 5 | 4 | 25 *Load game* | the load dialog `0x00448770(0)` | F4 |
| left 4 | 11 | 14 | 31 *Briefing for current mission* | `0x0043B150`, `0x0043EAB0` | B |
| left 5 | 15 | 33 | 39 *Undo last turn* | load slot 33 (cmd 7), offered while `0x00449400(33)` | Backspace |
| left 6 | 16 | 35 | 46 *Undo mission* | load slot 31 (cmd 8), offered while the slot exists | — |
| left 7 | — | 31 | — | empty | — |
| left 8 | 9 | 16 | 29 *Give up!* | `0x0047BC60(player)` removes every unit of the player | — |
| right 0 | 1 | 20 | 38 *Overview map* | camera mode 0, free (`0x00453410`) | 1 |
| right 1 | 3 | 24 | 36 *Set free view* | view mode 4, the map (`0x00450F60`) | 3 |
| right 2 | 4 | 26 | 35 *Set user view* | view mode 2, `0x004529D0(8, 7, 0)` | 4 |
| right 3 | 2 | 28 | 34 *Set unit view* | view mode 1, the eyes (`0x00452E90`) | 2 |
| right 4 | 12 | 10 | 30 *Jump to the next unit* | `0x00471E00(1)`: the next own unit **with points** (`0x00477D40`) | Tab |
| right 5 | 14 | 22 | 37 *Jump to visible enemy* | `0x00453CF0`: the camera to the next unit of another player with `+0x4F == 0` (`0x00477DF0`) | T |
| right 6 | 13 | 18 | 32 / 33 *(De)activate magnifying glass* | toggles `[0x005106CC]`; with it on, a click on a visible alien opens its **info page** (`0x00432AB0` → `0x00432B20` → `0x0043E850("Data", …, key)`, the mode-2 info activator of [`24` §7.2](24-briefing-text.md)) | — (`H` is the pad's heal; the button is dark, D4) |
| right 7 | — | 31 | — | empty | — |
| right 8 | 10 | 12 | 28 *Next player* | `0x0041DA20` cmd 2 — **end turn** | — |

Also from `0x00450D62/0x00450E75`: `Left`/`Right` turn the camera one step,
`Space` runs the camera path, and a **right-button release** turns the
camera a step — left of x 320 one way, right of it the other. The captions'
own text (*Set viewing direction* … *Center camera on unit*, ids 20..23) is
the four hints the camera keys never show on a button.

**Corrections to [`29` §1.2](29-interface-contract.md).** Event 14 is
*Jump to visible enemy* — a camera move, walked with `0x00477DF0`, the
"first live unit **not** of the current player and fully visible" — and
event 12 is the one that selects the next own unit; `29`'s table had 14 as
"cycle the selected friendly unit", and `core/world.gd`'s `may_command`
credited its tests to `0x00477DF0`. `0x00477D40`'s three are `+0x16` alive,
`+0x45` equal to the player it is passed and `+0x15` not zero
(`0x00477D79..8D`; that `0x00471E00(1)` passes the current player was not
read) — the first two are `may_command`'s, the third `may_select`'s, and
the hidden test `may_command` also makes is the remake's own.
Event 10 is *Next player*, the end of the turn.

### 5.3 The unit panel — `aUnitInfos.cpp`

`0x00473960` restores the plate under it (`0x004758F0`) and calls
`0x004756D0(unit, dst, pitch, 60, 415, 0, font, font)`, which computes and
draws (helpers: `0x00475240` hit-point cap = type base + `xp/12`, capped at
15; `0x00475340` heat cap, doubled by a Cooler; `0x004752A0` magazine,
doubled by Double Munition; `0x00475550` tier: `xp < 40 → 0, < 60 → 1,
< 100 → 2, else 3`):

* **Name** at (60, 397), white `0xFFFF` over `0x632C`, followed by a status
  word (`0x00474C40`): `Txtmod_h` 70 *In panic* at `fp == 0`, 71 *Light
  panic* at 1, 72 *Weapon is hot* with no heat left and rounds to fire, 73
  *Out of ammo!* with none.
* **Hit points** `0x00474DD0(x, y + 10)`: `uicons[11]` at the origin; the
  class icon 12 marine / 13 alien / 26 robot at (+28, +3) less its anchor;
  rear armour as rungs `uicons[9]` at (+14, +2 − 3k), front armour at
  (+42, +23 − 3k), at most ten and every second past ten; the rank
  `xp / 12` at (+53, −7), red at 0 or 1, `-` for an alien; `hp/max` at
  (0, +32), red at or below half; the absorber's charges `+0x3A` as
  `uicons[10]` dots at (+48 − 4k, +28).
* **Experience** `0x00474850(x + 75, y − 10)`: `uicons[8]`; one rung per
  twelve experience points four pixels apart; a pair of dots per twelve
  training points; the tier's `uicons[18]` discs seven apart; decorations
  `uicons[16 − k]`.
* **Weapon** `0x00474220(x + 145, y)` — not for aliens, and not for the
  alien weapons 17..37 (`0x0047432D`): `uicons[7]`; the name from the weapon
  record (`+0x01`) after it; `uweapons[weapon+0x42]` at (+33, +7) less its
  anchor; `umun[weapon+0x37]` — **the munition icon is the weapon type**,
  five types for five icons — at (+23, +27) less its anchor; `ammo/max` (or
  `-/-` for a bottomless magazine) at (+w₇ − 7, +36), red at 0; the heat at
  (+14, +36) in orange `0xFCA0`; the malfunction, or `2*` for an alternate
  mode, at (+37, +36); the **heat wedge** from (+43, +19): `heat · 30 / cap`
  columns rising from one pixel to sixteen, red with the green climbing eight
  a column, blue when a Cooler doubled the cap; lamp `uicons[25]` (id < 40)
  or `[24]` at (−22, +31) when the weapon has a toggle; the state icon
  `uicons[21..23]` at (+26, +24) for malfunction 1, 2 and 3..5.
* **Action points** `0x00474AF0(x + 235, y + 15)`: `uicons[17]` and the
  number centred at (+11, +14), white over `0x7BEF`.
* **Inventory** `0x00475A60(x + 275, y − 10)`: one `inv.LIB` element per
  equipment flag `+0x21 + id`: ids 0, 1, 5, 6, 14, 17, 3, 4, 15, 16, 7, 9
  → elements 0..11, each blitted less its anchor.

### 5.4 The save slots the interface owns

`0x0041DA20`'s commands 5..8 save and load slots **32** (*Remind/Recall
position*), **33** (*Undo last turn* — written at every hand-over to the
player) and **31** (*Undo mission* — written at the mission's start), the
same slots [`11`](11-save-game-format.md) found hard-coded. The remake's
`CampaignHost` writes them beside its eight and its quick slot, and the
three buttons are lit only while the slot exists (`0x00449400`) — which in
an *Instant Action* game, with no campaign to write, is never.

**One guard here is the remake's, not the engine's.** Nothing deletes a slot
file, so an autosave taken in another mission outlives it and "the file
exists" would offer it — *Undo mission* dropping the player into a mission
they are not playing, which the mission blob's own map check cannot catch
because the world is rebuilt from the save's own campaign state. The remake
reads each slot's header once and lights the three buttons only for a save
whose mission is the one being played (`main.gd`, `_slot_holds_this_mission`).
The original's files have the same staleness by construction.

## 6. The radar — `fcn.00451E50`

Clipped to **`(501, 389)` by 90x66** (`0x00451E72`), the green screen
painted on the plate (measured at `(503, 392)` by 89x63, one pixel past the
clip on the right). `0x00451E00(cx, cy)` maps radar coordinates to the
screen: `ox = cx · 90 / scale + 501`, `oy = 455 − cy · 66 / scale`, with the
**scale** `[0x005106DC]` = how many fields the width spans — **40** by
default (`0x004533BD`), stepped by 5 within **20..80** by a click on the
screen: x ≥ 546 up (a wider view), else down (`0x00452390`, the two arrows
painted beside the screen). The picture is centred on the selected unit
(its coordinates subtracted) and **turned about (546, 422)** by the camera's
yaw (`0x00403AA0` of eye → target); the four compass letters `sm[6..9]` (N, S,
W, E) stand at (546, 397), (546, 447), (521, 422), (571, 422) before the
turn (written by `0x00450C65..83`). Every live unit with `+0x4F == 0`: own →
`sm[4]` on the state-50 cell (the selection) else `sm[mp == 0 ? 1 : 0]`;
another player's (not 0xFC) → `sm[2]` on a state-1 cell, `sm[3]` on a marked
one; `+0x4F == 1` → `sm[5]`. The lamp at (616, 453) is `sm[11]` while any
enemy is visible, `sm[10]` while one is only detected. With no selection the
screen shows the compass alone.

## 7. The watched player's turn — `aViewPlayer.cpp`

**While another player moves, the battle interface is not on screen.**
`fcn.0047C2C0` is the frame `aAISystemControl` calls through the pointer
`fcn.0047D600` hands it (§3.1), and what it draws is `aViewPlayer.cpp`'s own
screen. `aInitViewPlayer 0x0047BCF0` — the engine names itself, pushing
`"aInitViewPlayer (Render_BMP)"` at `0x0047BD5A` — allocates a whole-screen
bitmap (`0x00461E90(2)·(3)·(4)`: the display's width, height and bytes per
pixel), loads **`GUI\plate_5.bmp`** into it at `0x0047BDB1`, and
`fcn.0047D090` copies **the plate's own four strips** back over the frame —
`fcn.0044B1B0(src, dst, src pitch, dst pitch, bytes, rows)` at `0x0047D0C9`,
`0x0047D13A`, `0x0047D1A8` and `0x0047D240`, with 34, 106, 340 and 340 rows,
the same three heights `fcn.0041A980` pushes for its own strips (§2) — twice
a frame, once per buffer (`0x0047D026`, `0x0047D045`). So no column icon, no
pad face, no unit panel, no radar mark and **no turn number** is on screen
while the computer plays: the **bare plate** is, and one thing on top of it.

What it prints depends on **which** screen it is: `fcn.0047C2C0` is a
seven-arm state machine, and the computer's turn is one arm of it that prints
nothing at all. §7.3 reads all seven.

`vp` is *view player*. `vp.LIB` and its own `vp.pal` are loaded at
`0x0047BF52`/`0x0047BFDA` into `[0x00522A04]` and `[0x00522A08]`, and
`0x00463A60` builds a remap table from the palette into `[0x00522E0C]`. Two
waves come with them — `progress.wav` into `[0x00522E10]` and `alarm.wav`
into `[0x00522E14]`, the two [`28` §2.1](28-effects-and-sound.md) already
lists as `aViewPlayer.cpp`'s.

### 7.1 The bar — `fcn.0047DA00`

Twenty-two capsules on row **406** from x **59**, one element width (15)
apart, through `fcn.004475D0` with **no anchor subtracted**: `vp[0]` is the
lit capsule and `vp[1]` the dark one, both 15x34.

| | |
|---|---|
| gate | `0x0043B280` — the turn counter `0x00509E1D` must not be 0 |
| gate | `0x0043B240` — `(solo == 0) ? [0x00509F0C] : 0` must be 0 |
| side | `0x0043B2C0` — the seat `[0x00509E32]`, passed in by `fcn.0047D090` |
| divisor | `fcn.00477BF0(side)` — units with `+0x16 != 0` and `+0x45 == side` |
| numerator | `fcn.00477FB0(side)` — the same, and `+0x15 != 0x00475160(unit)` |
| fill | `acted · 21 / live` (`0x0047DA3E`), and **0** when nothing has acted |
| drawn | `max(fill, [0x00522E18]) + 1` capsules lit |
| sound | `progress.wav` whenever `fill` differs from the last frame's |

Both sweeps walk the 200-record unit array at stride 91 from
`fcn.00477AD0`. The numerator's test is the unit's current movement `+0x15`
against `0x00475160`'s own allowance ([`25` §5](25-turn-and-round.md)), so the
bar is **the fraction of the side's live units that have already spent
movement** — a progress bar for the turn, not a pool of action points. One
capsule therefore burns from the first frame of every computer turn, which is
what a shipped screenshot of the moment the aliens take over shows.

`[0x00522E18]` is zeroed once, at `0x0047C0CF` in the init, and not per turn,
so the engine's *second* computer turn opens on one frame of the previous
one's last fill and one stray `progress.wav`. The remake resets it instead.

### 7.2 In the remake — `game/hud/turn_progress.gd`

`core` decides the whole computer turn in one call and the world holds its end
from the first rebuild ([`23` §2](23-ai-system.md)), so neither count can be
read straight off it: every alien's movement is already spent before the first
of them is drawn moving. `TurnProgress.tally` takes the engine's own two
predicates and masks them with **what the replay has already played**
(`AIPlayback.played_slots`, the events `[0, index)`); a casualty the replay is
still holding on its feet (`AIPlayback.pending_casualties`) stays in the
divisor, because the divisor is the side as the turn started. The side is the
replay's own (`AIPlayback.player`) and **not** `world.turn.current_player`:
the computer's turn runs inside `World.submit_end_turn` and hands over again
by itself, so the seat is back on the marines before the first event is drawn.

`MissionHud.refresh` takes the same switch to the rest of the interface — the
panel is refreshed with no selection and the columns, the pad, the radar and
the turn number are hidden, which is the bare plate above. `tour.gd`'s reply carries the lit
count as `hud.progress` and the tick as `hud.progress_stepped`, and
`hud.radar_marks` reads 0 while the radar is off screen.

**`progress.wav` ticks with the bar** (2026-09-05). The conversion's wave
closure was the `aAnimations.cpp` call sites plus the id-96 interface set
([`28` §6](28-effects-and-sound.md)), and this screen is the one place outside
both that names a wave, so a cache built before this section was silent under
the whole computer turn. `sound.VIEW_PLAYER_CUES` now carries both of the
screen's waves and `wanted_waves` copies them; `tables/sound.json` gained a
`view_player` block, `CONVERTER_VERSION` went 0.17.0 → 0.18.0 in its two
places, and the published cache was re-made. Neither wave has a
volume-control id — the original plays them with `aDirectSoundPlay(handle, 0)`
and nothing from the volume table — so both are `NO_SCALING`.

The remake plays it exactly where the original does: `TurnProgress.refresh`
answers whether the fill moved, `MissionHud.progress_stepped` carries that up,
and `Main._play_progress` plays `AudioTables.view_player_cue("progress")`.
The interface itself makes no sound; it reports and the caller decides.
`alarm.wav` is copied and never played — see §7.3.

### 7.3 The screen the bar is drawn on (2026-09-05)

`fcn.0047C2C0` is not an overlay on the battle screen. It is a **whole game
state**: `fcn.0044AAE0`'s dispatcher runs it as one arm, and `fcn.0047D600`
hands it to `aAISystemControl` at `0x0047D6A0` as the per-frame callback
(`push 0x0047C2C0` at `0x0047D68F`) — which is why the computer's turn is
drawn on it at all.

Everything it prints hangs off its own state `[0x005229D4]`
(`fcn.0047DBD0` reads it, `fcn.0047DBC0` writes it) through a seven-entry jump
table at `0x0047D064`. Text comes from **two** banks of `aTxtSys.cpp`, set
active with `fcn.00471090` and fetched with `fcn.00470FE0`: slot **0** is
`txtmod_g.lcl`, whose header names it `_ViewPlayers` and is opened by
`aInitViewPlayer` itself, and slot **3** is `txtmod_h.lcl`, `aMain`'s shared
bank (`0x00449CB7`).

| state | set at | what it is | what it prints |
|---:|---|---|---|
| 0 | `0x0047DDE5`, `0x0047C138` | a turn opens — the hand-over pause | `g:12` *Turn* + the number, or `g:20` *Prepare for battle* before the first; the player's line; `h:125` *(Press left mouse button to continue)* |
| 1 | `0x0047DE3C` | the game is over | `g:22` *End of game*, or `g:25` *Mission completed* / `g:26` *Mission failed* when the mode is 1 |
| **2** | `0x0047D656` | **the computer's turn** | **nothing** |
| 3 | `0x0047DDD2` | a network peer's turn | `h:129` *Waiting for* + `h:128` *Player*, over the map |
| 4 | — | reached by no writer found | — |
| 5 | `0x0047E198` | the game was stopped | `h:126` *Game stopped by* + `h:128` |
| 6 | `0x0047E03D` | the game was cancelled | `h:127` *Game canceled by* + `h:128` |

State 0's two lines are centred in the 3D window at **(320, 190)** and
**(320, 160)**, and the *press to continue* line at (320, 220); each is
skipped when its buffer is still the empty string at `0x004FA524`. The
composition templates are `"%s %d"`, `"%s (%s %d)"`, `"%s (%s %d) - %s"` and
`"%s %s (%s %d)"`, so the player's line reads *Andreas (Player 2)* — or
`h:132` **"Scay'Ger (Computer)"** when `fcn.004822F0` says the next seat is
the computer's.

**But not in a single-player mission.** `0x0047C48E` sends mode **1** to
`0x0047C549`, which copies the *Turn* line across and leaves the player's
buffer as the empty string, so neither of those captions is reachable alone —
they are the multi-player hand-over's. And the pause dismisses itself:
`0x0047C3FF` posts `WM_LBUTTONDOWN` (`0x201`) to the game's own window at
`0x0047C425` when there is exactly one player and `fcn.0043B1F0` is zero. A
mission played alone therefore shows this screen for one frame, which is why
the shipped game never seems to have a *press to continue* between turns.

**State 2 prints nothing**, and that is read rather than assumed: its arm runs
`0x0047CF5D`…`0x0047D016`, rebuilds the visible map, draws the battle map
through `fcn.00417E10` and contains **no `aPrintLibText` call** in its 185
bytes. The arm states 2, 3 and 4 share leaves at once unless the mode is 2
(`cmp eax, 2 / jne 0x0047CB3E` at `0x0047C98A`), so every caption above is a
multi-player caption. State 3 is the one that does print over the map: after
the ground overlay `fcn.00417E70` at `0x0047CC8E` it puts *Waiting for
&lt;name&gt; (Player N)* on **row 54** in the acting side's own colour, chosen
by a four-arm switch on `[0x00509E32]` (`0x0047D080`) and packed as RGB565 at
`0x0047CD3F`.

**`alarm.wav` is the network game's "it is your turn" alert.** It sounds at
`0x0047DE0B` on exactly one path: the hand-over `fcn.0047DC60` sets state 0
(`0x0047DDE5`), and then `fcn.0043B740` — the game mode byte `[0x00509EE8]`,
written by `fcn.0043B730` — must be **2** *and* the turn counter must not be
zero. Mode 1 is the single-player campaign, so a mission played alone never
reaches it; 3 and 4 are the other two multi-player forms and are
**UNVERIFIED**. That the mode-2 screen is the network one is the captions'
own doing: the same bank prints *SYSTEM: Out of Sync*, *Lost connection* and
*(Press F12 to chat; F5-F8 to toggle receiver; ESC to abort the network
game)*. The remake copies the wave — the closure is what the *game* can
reach — and plays it nowhere, because it has no network game to be in.

## 8. The remake's layout — `game/hud/`, `game/overlay/`, `game/screens/plate.gd`

**The plate is a layout, not a picture.** The canvas is `canvas_items` with
`expand`, so it is always ≥ 640 by ≥ 480 of the plate's units at one uniform
scale and the surplus is *units*, not a stretch. `plate_5` is cut into ten
pieces, pinned by `hud_tables.py` against the bitmap (`PLATE_SEGMENTS`):

| piece | region | anchor | kind |
|---|---|---|---|
| top left | (0, 0, 200, 34) | top-left | fixed |
| top band | (200, 0, 64, 34) | — | tiled across the extra width |
| top right (with the turn window 525..590 × 7..24) | (264, 0, 376, 34) | top-right | fixed |
| left column (slots at x 17..40) | (0, 34, 60, 340) | top-left | fixed |
| left filler | (0, 205, 60, 1) | — | one row, extruded down the extra height |
| right column (slots at x 600..623) | (580, 34, 60, 340) | top-right | fixed |
| right filler | (580, 205, 60, 1) | — | one row, extruded down the extra height |
| bottom left (panel inset from x 42) | (0, 374, 300, 106) | bottom-left | fixed |
| bottom band (inside the inset 42..397) | (300, 374, 40, 106) | — | tiled across the extra width |
| bottom right (pad sockets 401..487, radar 503..591) | (340, 374, 300, 106) | bottom-right | fixed |

On 4:3 every piece is where it was cut from; the **3D window is what is
left** — `(60, 34)` by `W − 120` by `H − 140` (`HudTables.window_for`) — and
the camera keeps the original's focal length 400 (`_ftol(520 · 10 / 13)`)
for any width, so a 16:9 screen shows more world at the same scale
(`CameraRig.frame_projection`'s `focal_width`). The pad, the radar and the
turn window ride the bottom-right and top-right pieces; the panel the
bottom-left; the columns their own. The plate's pieces **stop** mouse
input, unlike the campaign screens' strips.

**The ground overlay** (`GroundSprites`) is one `Sprite3D` per mark with
`fixed_size`, `no_depth_test`, nearest filtering and an alpha cut, its
`pixel_size` `1 / 400` so one texel is one plate unit, and the anchor
applied as `offset = (−dx, dy − height)` — a non-centred `Sprite3D` grows
right and **up**, measured with the generated mesh and pinned in
`test_hud.gd`. The cell states are translated from `MoveMapResult` and
`World.target_bands` to the engine's values (`GroundSprites.cell_states`),
so the table consulted is the engine's own. **The ring is 2D**
(`DirectionRing`), for the clamp; under the stretch the camera's
`unproject_position`, the mouse and the layer all speak plate units, which
`tour.gd`'s `visible_rect` reports.

**Fonts.** The turn, the hints and the panel's name are the 13 px `font_0`;
the panel's numbers the 10 px `font_3`, the one face that fits its rows; the
debriefing keeps the interface font setting (`font_2` or the readable
face). The four fonts' rows are the same 13/13/20/10 the cache's
`fonts/index.json` measures.

## 9. Verification

```bash
python3 tools/hud_tables.py --check gog_incubation          # 194 checks
python3 tools/hud_tables.py --emit-cases tests/fixtures/hud/cases_hud.json --root gog_incubation
bash godot/run_tests.sh                                       # test_hud.gd
```

`--check` pins: the 100-byte state map and the 16 arms with each arm's
immediate at its instruction; the hover gate, the blink tests, the zoom
gate, the unit-marker immediates; the ring's letter table, tiers, radius,
geometry and clamp; the facing-delta and angle dispatch tables; the four
tick periods; the click handler's states, modes and calls; the ring click's
calls and the `mp == 0` test; `aChangeUnitViewDirection`'s refusals and its
`+0x46` write; the pad's rectangle, strides, sprites, gates and draw
origin; the panel's origin, blocks, offsets and helpers; the columns'
rectangle, three dispatch tables, caption position and draw; the radar's
clip, centre, scale, coordinate map, compass table, lamp and zoom click;
the window's four writes, the strips, the turn text and the par calls; the
blitter's element arithmetic, its transparency test and which callers read
anchors; the four loaders' names and handles; fourteen libraries' counts and
twelve elements' shapes; forty-three caption ids in `Txtmod_h` and
`Txtmod_g`; the plate's size, its dark window, the radar screen, the pad
sockets, the slot columns, the turn window and the panel inset measured
from the pixels, and that the ten pieces tile the frame; and the watched
player's screen of §7 — `vp.lib` and its handle, `plate_5.bmp` loaded whole,
`progress.wav` and its handle, the four strips the watcher paints back and
their row counts, the two gates, the two unit sweeps with their
`+0x15`/`+0x16`/`+0x45` reads and the allowance call, the `· 21 / live`
arithmetic, the previous fill and where it is zeroed, x 59 and row 406 in
both runs, the 21/22 limits, elements 0 and 1, the width helper and that
both runs blit through one blitter with no anchor; and the screen itself of
§7.3 — the state global and its two accessors, the seven-arm switch and that
the state is its only index, the two text banks at their slots, twenty string
ids at their own pushes with the fetch each reaches, the four `wsprintf`
templates, state 0's two centred lines and its solo arm with the
`WM_LBUTTONDOWN` it posts, the write that opens the computer's turn and the
callback `aAISystemControl` is given, that state 2's arm contains no
`aPrintLibText` at all, the mode gate in front of every caption, state 3's
overlay call and caption row, the four-arm colour switch and its RGB565
packing, both sound buffers with the alarm's mode-and-turn gate and the bar's
own play site, and the eleven captions read back out of the shipped banks; and the selection of §4.5 — all five writes to `[0x005162F0]`, that the reset has one caller, that `fcn.004721F0` fills an empty selection before it reads its mode, the two cycle modes, `fcn.00471E00`'s two gates, `aInitBattleGround`'s single mode-1 ask, `fcn.00477CE0`'s two passes with the movement test present in the first and absent from the second, its `0xFFFF`, that neither hand-over routine calls any of them, the reference count of `[0x005162F0]` over the whole `.text`, the four view-mode placers of the select camera with the `(8, 7, 0)` mode 2 opens in, and that the five sites that re-apply the view all reach `fcn.004533D0`. It fails on an empty corpus.

`test_hud.gd` (**329 checks**): every table above against the fixture; the
layout on 640x480, 853x480, 640x512 and 1120x480 — no overlap, fixed pieces
their own size, the window the remainder, every widget on the canvas, 4:3
the plate to the pixel; the anchor sign; every library's anchors and sizes
against the fixture; the cell-state translation; the live overlay with and
without a legal hover, its far view, and that no mark is depth tested; the
ring's records; the radar's arithmetic and its scale's bounds; the
selection rules (`may_select`, `submit_rotate`); the state-byte facing; the
progress bar's geometry, segments, elements and fill arithmetic against the
same fixture, and the live interface swapping for it -- one capsule at the
opening, eleven at half the side, all twenty-two at the end, the panel, the
columns, the pad and the radar's marks gone while it is up and back when the
seat is; and the interface itself — the turn text with and without a
par, every caption shipped, the panel naming its unit, the pad's gate at the
press, the events raised, the report.

`test_game_ui.gd` carries the hand-back of §4.5 on a real `_C_140` — the
first unit is the lowest-numbered one of the side, a previous selection the
computer left alive and able to move comes back, a dead or spent one falls
back to the first, a side that has moved everything still hands one back and
that one is a unit a click could **not** select, and a side with nothing alive
hands back none — and the bar's two counts: the turn
opens at zero with the whole side in the divisor, a unit that has spent
movement is not counted until its own event has been played, a played unit
that did not move is never counted, a casualty leaves the divisor unless the
replay is still holding it, and the side is the replay's rather than the
world's seat.

`tour.gd` gained `markers`, `hud event|pad|ring|radar N`, and `hud`,
`markers` and `visible_rect` in every reply.

## 10. Corrections to other documents (2026-09-05)

* [`97` §45.2](97-slice-5-report.md) — the move map is **not** the terrain
  tile coloured; it is a sprite pass after the frame with no depth test (§3).
* [`60` §1](60-lib-sprites.md) — the `0x00445DC0..0x00447BF2` range holds
  the game's own blitter and anchor readers, not only LibMaker's writer;
  §6 items 1 and 2 are closed (§3.4).
* [`29` §1.2](29-interface-contract.md) — events 12 and 14 (§5.2).
* [`23` §3.6](23-ai-system.md) — the state byte (§4.4).
* [`10` §5.12 and §6.1](10-lev-mission-format.md) — "the HUD" is the ground
  overlay `fcn.00417E70`, and the ten records at `+0x004` are the
  **direction ring**, not a deployment ring (§4.2).
* [`27` §2.6](27-campaign.md) — the campaign map's own marker pass is
  `fcn.00418F40`: every state-3 cell gets `map[7]`, the hovered one
  `map[15 / 12 / 9]` and the selected one `map[14 / 11 / 8]` by the location's
  action-point band (1..8 or 210..217 / 10..24 / 50..129), with its name
  written beside it. The remake's dots-by-kind stay as they are (decision D6).

## 11. Decisions

* **D1 — the ring is the rotation.** The plan's "choose a direction by
  clicking a cell" is the original's own mechanism, reproduced: a reachable
  or warp cell raises the ring, a letter completes the move and the facing,
  the selected unit clicked again turns in place.
* **D2 — selection refuses a unit with no points and drops one that runs
  out**, as `0x004714B0` and `0x00471AD0` do; the keyboard cycle skips them
  too (`0x00477D40`).
* **D3 — the plate adapts, the original's does not.** Pieces, bands and
  fillers (§8); the window takes the surplus; the focal length stays 400.
* **D4 — the magnifier button is present and never lit.** Its effect is an
  info page out of `Data.txt` for the clicked alien's type (§5.2, through
  the activator [`24` §7.2](24-briefing-text.md) already documents), which
  the cache does not carry and this slice does not change the converter to
  carry; the caption still names it, and no key is bound to it.
* **D5 — the options bar is the options screen.** Its nine controls are the
  shell's; the bar's slide-in is not drawn.
* **D6 — the campaign map keeps its dots by kind.** `fcn.00418F40`'s
  band-coloured rings are recorded in §10 for a later pass; changing
  `CampaignMapScreen.marks_for` touches `test_shell` and `test_campaign`
  and is outside this slice.
* **D7 — two plate fonts.** `font_0` for the band texts and `font_3` for the
  panel's numbers, chosen by the rows they have to fit; the handles the
  panel is passed are not traced to a library name and do not need to be.
* **D8 — the campaign screens stay on `place_on_plate`.** `PlateLayout`
  gives them a path to fixed pieces later; they are outside this slice.
* **D9 — the far view's `map[6]` at `map[4]`'s anchors** is reproduced as
  the engine has it, quirk included.
* **D10 — only the overlay's `units` arm is transcribed.** `0x0042FF30`
  dispatches on the weapon (`AIOverlay.arm_of`), and the arms behind weapons
  40, 42, 43 and 46 stamp the states **35**, **36** and **37** — a special
  object, empty ground, any unit (§3.1) — rather than a hit band. The player's
  bands and the computer's come from the same [AIOverlay] and therefore share
  its one transcription: those arms are recorded as a refusal rather than
  invented, so a weapon that aims at ground shows no marks until the arm is
  read. Nothing in the shipped set needs it to fire: an enemy is still shot by
  clicking the unit itself.
* **D11 — both of the screen's waves are copied, one is played.** The
  conversion's closure was the `aAnimations.cpp` call sites plus the id-96
  interface set ([`28` §6](28-effects-and-sound.md)), and `aViewPlayer.cpp` is
  the one place outside both that names a wave — so `progress.wav` had no file
  in the cache and the whole computer turn was silent. `sound.VIEW_PLAYER_CUES`
  now carries both, `CONVERTER_VERSION` went 0.17.0 → 0.18.0 in its two places
  and `user://caches` was republished with `--campaign-maps`. `alarm.wav` is
  copied and played by nothing: the closure is what the **game** can reach, and
  a remake with no network game is not a reason to leave a named wave out of
  the cache (§7.3).

## Open questions

**None.**

Two questions were opened and closed on the same day. The first: whether a
blocking animation reaches the ground overlay through the callback pointer
`fcn.0047D600` stores. It does not, and the evidence is in §3.1 — the
pointer's only reader is `aAISystemControl`, and `aExecuteMove` reaches no
redraw at all.

The second: what the watched player's screen prints, and when `alarm.wav`
sounds. Both are in §7.3. The screen is a seven-arm state machine on
`[0x005229D4]` with two text banks behind it; **the computer's turn is state
2 and its arm contains no `aPrintLibText` call at all**, so the captions the
function carries are the hand-over's, the end of the game's and the network
game's. `alarm.wav` is the network alert, gated on the game mode being 2. One
thing named in the old entry is still untraced and is **not** an open question
about this document: the second bitmap `[0x00522A00]`, which
`aInitViewPlayer` fills and three routines read — it is a render target of the
screen's own and nothing about the interface's layout depends on it.

Everything else this document could not settle by reading is a decision
above, with the reading that would settle it named beside it:
the magnifier's page (D4) wants the `Data` info bank in the cache, the
campaign map's rings (D6) want a pass over `CampaignMapScreen`, and the
plate fonts (D7) would be settled by the two handles `0x00473960` passes
into `0x004756D0`.

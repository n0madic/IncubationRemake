# Mission presentation — the camera, the animation drivers and what a turn looks like

**Status: decoded from `Incubation.exe` and pinned by
`tools/presentation_tables.py --check`; one runtime measurement in
`tools/presentation_gold.py`. Everything that is an inference and not a
measurement is marked UNVERIFIED in place.**

This document is the behaviour layer above [`40`](40-charisma-model-animation.md)
(the animation *data* and the sampler) and [`28`](28-effects-and-sound.md)
(the effects and the sounds): what the original game **does on screen** during
a mission — how the camera is placed and flown, how a walk, a shot, a death, a
jump and every set piece are staged frame by frame, when a unit idles, and how
the computer's turn is shown. None of it is a file format. All of it is code in
`aMI.cpp`, `aAnimations.cpp`, `a3DEngine.cpp`, `a3DObjects.cpp` and
`aTacTools.cpp`, read out of the shipped executable.

It exists because [`29`](29-interface-contract.md) contains **no camera at
all**, and because three earlier documents drew conclusions from that absence:
[`92` §7.5.3](92-remake-architecture.md) ("the original does not need a pan
either: it drives the view from the selection"), [`22` §9.5](22-combat-and-visibility.md)
("`aKillUnit` is a death sequence plus this call") and
[`97` §26.3](97-slice-5-report.md) ("the object goes at once, and Charisma has
no death clip to play instead"). All three are corrected here and in place.

Conventions: addresses are virtual addresses in the GOG `Incubation.exe`;
world units are `1600 = 1 m`, a map field is `3200`, a height level `0xA0`; a
full turn of an engine angle is 4096. "One frame" is one call of the frame tick
`0x0040B6F0`, capped at a nominal 20 fps ([`40` §4.8](40-charisma-model-animation.md)).

---

## 1. The frame loop and the clocks

### 1.1 The frame tick

Every `aPlay*` routine is blocking and runs its own loop whose body calls
`0x0040B6F0` once per displayed frame ([`28` §1.4](28-effects-and-sound.md)).
That routine pumps the message queue, applies the skip controller
`0x0047F2E0(10, 20)`, renders the 3D view (`0x00417E10`), and draws the
**animation overlay** selected by the global `0x004FAE80`, which every driver
sets through `0x0040B660(type)` before its loop:

| Type | Drawn by the tick | Set by |
|---|---|---|
| 0 | the fight caption at (80, 54) plus the **floating texts** of §4.5, each rising 2 px per frame and fading over 15 frames (`0x004FC0A0` counts down from 15) | `aPlayFightAnimation` after the impact |
| 3 | one centred caption `0x004FCB54` in colour `0x004FCBD4/D6` | the orbit animations of §7 |
| 4 | nothing extra | the projectile flight, every set piece |
| 5 | a text box | the supply-box pickup |
| 6, 8 | no HUD redraw at all | the campaign camera path |

### 1.2 The animation clock and its speeds

Gameplay animation advances one key-time unit per rendered frame:
`IWorld::Simulate(1.0f, 0)` at `0x00407104` inside the 3D-view refresh
`0x00406FC0` ([`40` §4.8](40-charisma-model-animation.md)). **The speed factor
is not 1.0.** `StdAnimation`'s constructor writes 1.0 into `+0x64`
(`0x004A0BAD`), which is what `40` §4.8's scan found — but every gameplay start
goes through the animation interface's start slot (`+0x2C`) with a speed
argument, and that is where the number comes from:

| Clip | Started by | Speed literal | Loops | Evidence |
|---|---|---|---|---|
| `M` walk | `0x004055E0` selector 0, `0x0040599C` | **2.0** (`push 0x40000000`) | `+0x44(100000)` at `0x00405992` | decompiled |
| `F` fight | `0x004055E0` selectors 1–3, `0x00405B17` | **6.0** (`push 0x40C00000`) | 1 | decompiled; the `BREAK` callback is registered right after |
| `S` idle | `0x004060B0`, `0x004063E3` | **1.5** (`push 0x3FC00000`) | 1 | decompiled **and measured**: the live `StdAnimation` reads `speed = 1.5, length = 90, loops = 1` for `P0_S0_000`, and its clock reads 67.5 after 45 `Simulate(1.0)` steps (§6.3) |
| `M2` (`P0_M2_000`) | `0x004055E0` selector 4, `0x00405BE8` | 1.0 | `+0x44(100000)` | decompiled; the start time is `aRandom2(0, 10)` through `+0x34` |

Consequences that change earlier readings:

* A walk clip (20 key units, one field of stride, `40` §5.4) cycles in **10
  frames**, and a field is walked in 6, so the feet cover 1.67 fields per
  cycle — not the 3.3 that `40` §4.8 item 3c computed at speed 1.0.
* An `F` clip reaches its `BREAK` note (17–36 key units) in **3 to 6 frames**,
  0.15–0.3 s, not 0.85–1.8 s. The spin `int(len / 6) / 3` that `40` §4.8 left
  UNVERIFIED as to intent is now legible: `len / 6` is the clip's length *in
  frames at speed 6*, and the combat routine waits a third of it before it goes
  on to the camera and the caption (§4.1).
* An idle clip plays in two thirds of its length; the slot that holds it is
  kept for the whole length (§6).

~~The declared length the engine reads (`+0x60`) is the descriptor's, which is
**not** always the last key time: `PC_S0_000` declares 90 and carries keys to
127. A remake that takes the last key as the length overruns the engine by 37
units on that clip.~~ **That paragraph was wrong, and the way it was wrong
is recorded in §6.3**: the measured 90 belonged to `P0_S0_000`, not to
`PC_S0_000`, because the starter never animates the unit it is asked for.
What the engine reads is now decompiled and pinned: `KeyFramedAnimation::Init`
`0x004A0A01` asks the animation for its **first movement** (its own slot
`0x0C`, index 0), casts it to `IMovement` and calls slot `0x2C` — which for
every keyframed movement class (`0x004A8873` for a vector track, `0x004A97A4`
for a rotation) indexes the **last key** through `+0x74` (count) and `+0x78`
(the array) and calls the key's slot `0x14`, `fld dword [key + 4]`: its
time — and stores the answer at `+0x60`. So the length is the first movement's
last key time; there is no declared-length field at all. In the corpus every
movement of a clip ends at the same time (112/112 of the clips that carry
movements; 112 of the 113 under `CHData/Animations` do),
so "the last key time" and "the first movement's" are the same number
everywhere, and `PC_S0_000` is 127 as its keys say. `presentation_tables.py`
pins the chain and the vtable slots; `presentation_gold.py` pins the value
against the corpus for the clip it animates.

### 1.3 The 3D-view refresh, once per frame

`0x00406FC0(advance)`, called by the render with `advance = 1`:

1. the idle scheduler of §6 for slots 1, 2, 4 and 5;
2. `Simulate(1.0)` and the model update, **only while the camera is below
   96 000 units (60 m)** — above that the bodies freeze;
3. the unit objects: state byte `+0x40` of the 77-byte object record — `1`
   draws the model through the Charisma bridge (`0x0042C770` → the Eng3d
   check-in with prototype `0x8FFFFFFF`), **`3` replaces the model by
   `A_BLIB.3DI` and spins it by 50 angle units per frame** (the "knocked down"
   state `FixedStatue` puts a unit in, `20` §7.4), `5` draws nothing (the state
   every death and every hidden walk uses);
4. the 81-slot special-object array of §9 with its five rotation states;
5. the blob sweep `aCheckInBlobObjects` `0x0041E3D0`.

---

## 2. The camera

### 2.1 State and primitives (`a3DEngine.cpp`)

| Global | Meaning |
|---|---|
| `0x004FA430/34/38` | camera position x, y, z |
| `0x004FA43C/40/44` | look-at target x, y, z |
| `0x004FA428/2A/2C` | camera angles, `i16`, 4096 per turn |
| `0x004FA490` | camera lock; every primitive refuses with *"move locked camera!"* while it is set |
| `0x005106D8` | **view mode**: 0 none/script, 1 through the unit's eyes, 2 on the unit, 4 map |
| `0x00510700` | **view quadrant** 0…3, the orientation the unit camera is placed relative to |
| `0x00510760…0x00510774` | the box every computed position is clamped into (`0x00453420`): `0x00453320` fills it with 800 on every low side, `(width − 1) × 3200` and `(height − 1) × 3200` on x and y, and the header's camera height (`0x004FD0F4`, [`10`](10-lev-mission-format.md) `+0x224`, world units) on z. **This is the height cap that bites** — see §2.3 |

* `0x00403560(px, py, pz, tx, ty, tz)` sets position and target and rebuilds
  the direction — **43 call sites**, every animation driver among them.
* `0x00403600(dx, dy, dz)` turns the camera by three angle deltas and clamps
  the first to `[-1024, 1024]`: **pitch is limited to ±90°**.
* `0x004037D0(dx, dy, dz, ax, ay, az)` moves and turns at once.
* `0x00403780(&px…&tz)` reads all six back; `0x00403750` the position only.

### 2.2 The flight — `0x0040EEE0(px, py, pz, tx, ty, tz)`

The routine every camera move in the mission goes through (45 call sites). It
is a blocking loop, one frame per iteration, and an **exponential ease-out**
in integer arithmetic:

```
if |newPosZ - curPosZ| > 0x7D00 (20 m):  set the camera at once, return   ; 0x0040EF27
fast = any of the six |delta| >= 500                                        ; computed once, 0x0040EFC0…
loop:
    if all six |delta| <= 30: stop                                           ; 0x0040F020…
    step = delta / 3  if fast  else  delta / 6     (truncating, 0x55555556 / 0x2AAAAAAB)
    camera += step;  aSetCameraPosition;  frame tick
```

The 20 m test is on the **camera height** (the third argument against the
third value read back; the offsets are pinned). The fast/slow choice is made
before the loop, not per frame. Beyond the position the target moves the same
way, so a look-at that jumps does so at the same rate. There is no wall-clock
term: the flight is as long as the number of frames the remaining distance
needs, typically 8–12.

### 2.3 Placing the camera on a unit — `0x004529D0(x, y, dist, height, mode)`

`aMI.cpp`'s unit camera. Reads the unit on the cell and its object (position
`+0x10/14/18`), the unit's view gradients (`0x0047ABD0`, `gx`, `gy` in −1…1)
and the type's height (`0x0047AD70`: `unitInfo[type + 0x1C] × 160`).

**Mode 1 — behind the unit, along its facing** (`0x00452B69`):

```
pos.x = obj.x - gx * dist * 1600 - (axis-aligned ? gx * 3200 : 0)
pos.y = obj.y - gy * dist * 1600 - (axis-aligned ? gy * 3200 : 0)
pos.z = obj.z + unitHeight + height * 1600
target = (obj.x, obj.y, obj.z + unitHeight)
```

*(Corrected 2026-09-02, from the listing rather than the first skim.)* The
flight's **target is the object plus the unit's height** (`0x0051071C`); the
`obj.z + 1600` of the first reading is the *look point the search is given*,
below. The cap that follows — `if (cameraHeight × 1600 < pos.z) pos.z =
cameraHeight × 1600` — compares against `0x00419B90`, which returns the
header's camera height **already in world units** (`0x004FD0F4` is the loaded
header's `+0x224`), so it multiplies units by 1600 and **can never bite**; the
cap that does is the box clamp of §2.1, whose z ceiling is the same header
value unscaled. "Axis-aligned" is `gx == 0 || gy == 0`. Mode 1 then goes
straight to the free-position search: the search is **not** mode 0's alone.

**Mode 0 — relative to the view quadrant** (`0x00452C1E`, jump table
`0x00452E80`): `(dist + 6) × 1600` along **x** and `dist × 1600` along **y**
— always in that order — with the signs by quadrant:

| quadrant | x | y |
|---|---|---|
| 0 | + | + |
| 1 | + | − |
| 2 | − | − |
| 3 | − | + |

`pos.z = obj.z + unitHeight + (height + 3) × 1600`, the dead cap, then the
**box clamp** of §2.1 (which is where the height is actually limited), then
the near-axis rule: `if (|Δx| < 9600 || |Δy| < 9600) pos.z += |Δx| − 12 800`,
with the deltas measured **after** the clamp. It goes both ways: with the
offset intact only the teleporter's `(5, 5, 0)` reaches it (`|Δy| = 8000`),
and there it is a **raise** of 4800 (`|Δx| = 17 600`); near the map's east or
west edge the clamp pulls `|Δx|` under 12 800 and it is a **reduction** — on
`_C_140` the first marine stands two fields from the east edge and the "on
the unit" view of §2.4 comes out 3227 east, 12 800 north and 6427 up, a
steep close view rather than the 19 m one. So the four orientations the engine's
player saw are the **corners of a `(dist + 6) × dist` rectangle** — for the
"on the unit" view a 14 × 8 m one, about 30° off the x axis — and not
quarter turns; [`92` §7.5](92-remake-architecture.md) is corrected
accordingly.

Both modes end in the **free-position search** `0x00453510`, given the
position and a look point of `obj + 1 m`: up to **70** tries, each rotating
the offset around the look point by `±51 × n` angle units alternately
(`0x004039A0` on `(0, 0, ±51n)`), then clamping into the box, until the line
from the position to the look point and to the look point + 2400 (1.5 m)
crosses no scenery (`0x00453490` walks the special-object and clone arrays
with `0x00403FF0`). A position nothing clears is left as it was — the
out-parameters are only written on success.

Both modes end in the flight of §2.2 with the mouse hidden (`0x0045F270`) and a
full redraw. The call sites and their arguments, all pinned:

| Caller | `(dist, height, mode)` | When |
|---|---|---|
| `aExecuteMove` `0x0046E552` | `(6, 4, 0)` | before a visible walk when the mover is off screen or the camera is low (§3.2) |
| cycle command 14 `0x00453D42/DA5` | `(8, 7, 0)` | Tab: the next own unit |
| GUI event 4 `0x00451141` | `(8, 7, 0)` | the "on the unit" view; sets mode 2 |
| `aPlayFightAnimation` `0x0040C3F9` | `(9, 5, 1)` | computer shooter, empty target cell |
| `aPlayFightAnimation` `0x0040C416` | `(5, 3, 1)` | computer shooter, a unit on the target cell — **behind the victim** |
| `aPlayFightAnimation` `0x0040C37x` | `(5, 2, 1)` | shooter and target on one cell |
| `aPlayGroundFireAnimation` `0x00415B30` | `(9, 7, 1)` | |
| `aExecuteTeleporter` `0x00470254` | `(5, 5, 0)` | |
| `aExecuteBomb` `0x00470309` | `(5, 2, ·)` | |
| LCL handlers `0x00482194`, `0x00482204` | `(6, 5, 1)` | after `aSetCameraPosition(…, 1600)` |

### 2.4 The three views the interface switches between

`aMI.cpp`'s 16-arm input translator (`29` §1.2) reaches three camera commands:

* **event 2 → `0x00451150` → view mode 1, the unit's eyes** (`0x00452E90`):
  the camera at `obj + gradient × 800`, `z = obj.z + unitHeight + 640`, the
  target one field ahead along the facing at `−320`; a flight; the HUD hidden
  and redrawn (`0x0041A980`).
* **event 4 → `0x004510A0` → view mode 2, on the unit**: `0x004529D0(8, 7, 0)`.
* **event 3 → `0x00450F60` → view mode 4, the map** (`0x00453150`,
  `0x00453270`): the camera **24 000 units (15 m) above the cell**, target
  the cell + 0xC80 in y, a flight.

Mode 0 is what a script leaves behind. Mode 4 disables the walk follow and the
fight camera; mode 1 turns a walk into a first-person ride (§3.2).

### 2.5 Free control

In the main loop `0x0041C010`, on `WM_MOUSEMOVE`:

* **right button held → `0x00451000`: free rotation** by `Δmouse × 8` angle
  units per axis (pitch clamped by §2.1);
* **middle button held → `0x004511A0`: pan** by `Δmouse × 40` units along the
  view's own axes — `0x0050FE64/68/6C` are the vector `(0, −10, 0)` turned by
  the camera's angles, written by the free rotation above (`0x00451060`), so
  the two components are the forward direction scaled by ten and a pixel of
  drag is **400** units;
* keys 3 and 4 → `0x004037D0(0, 0, ±2000, …)`: height by 1.25 m.

`92` §7.5.3's "the original does not need a pan" was written without this.
The quadrant global of §2.1 is what supports its four-orientation decision; the
free rotation and the pan are what it did not know about.

### 2.6 What moves the camera without the player asking

Everything in §3–§8. The only thing that does **not** is the hand-over:
`0x0047D600` sets script variables and the view state and calls no camera
routine, so the remake's "hand the view back to the first own unit"
(`92` §7.5.3, marked UNVERIFIED there) is the remake's own and not the engine's.

---

## 3. A walk — `aExecuteMove` `0x0046E220`

### 3.1 The step

Six frames per field, position interpolated by sixths with `+0xA0` in z
([`40` §4.8](40-charisma-model-animation.md) 3c), the `M` clip started once for
the whole path (`0x004055E0(3, unit, 0)`, slot 3, speed 2.0, 100 000 loops) and
stopped at its end (`0x00405D40`), the footstep sound started and stopped around
it. **The facing is written and the object's rotation set in the same
instruction pair** (`aChangeUnitViewDirection` `0x004792A0` → `0x004051E0`):
there is no turn animation; a body snaps to each new heading. Types 61…63
(the Norc'Yn and its arms) are never rotated.

### 3.2 Who watches, and from where

The walk takes a **mode byte**, decided at the top of the routine:

| Mover | Visible | Mode | Frames | Camera |
|---|---|---|---|---|
| own unit | — | 1 | yes | `aPlaySelectUnitAnimation3` `0x0040EDB0`: the position stays, the **target flies to the unit** (view modes 2, 3 only) |
| computer, option *Enemy Move* off (`Game.opt +0x1C`, `20` §9) | — | 0 | **none** — the unit is moved cell by cell with no frame drawn |
| computer, option on | at the source | 3 | yes | if the unit is in sight (`0x00453050`: a clear line from the camera to the object + 3200) and the camera's own z is above 12 800 → `aPlaySelectUnitAnimation3`; else view mode 4 → `0x00453150` on the unit's cell; else `0x004529D0(6, 4, 0)` |
| computer, option on | only at the destination | 2 | yes | a flight of the **eye** to the unit's own object plus its height and of the **target** to the destination's object plus its height − 160, then **the ride** |

"Seen" is `0x004794B0` — `aBuildVisibleMapForUnit(observer, x, y, &saw)` of
[`22` §9.3](22-combat-and-visibility.md), the **mover** standing on the asked
cell: one line of sight (`0x0046C460`, mode 1) from that cell to each live
unit of another player, both ends at cell height plus the type's
`0x0047AD70` height, any code under 255 setting the flag; the beacon types
`0x3D`/`0x3E` are marked visible and skipped, species-2 objects are skipped.
*(Corrected 2026-09-02: this paragraph first had the other units observing
the cell. The endpoints are the same, so the answer is; the observer is not,
and it matters for what the call writes.)* **The call writes**: it is the
one visible-map pass the engine has, every unit it sees goes to `+0x4F = 0`
and a computer unit on orders 5, 6 or 8 wakes its group there and then — so
an enemy the mover *would* see from its destination is revealed, and its
group woken, before the first step is taken, and a walk cut short still
leaves those marks. It is asked for the destination first (`0x0046E330`,
into `local_4c`) and then, for a computer mover only (`cmp byte
[unit+0x45], 0xFF` at `0x0046E367`), for the source (`0x0046E385`), and the
destination's **answer** — not its writes — is discarded when the destination
cell's `+0x0C` is over 6 (`0x0046E357`, `cmp byte [cell+0x0C], 6 / jbe`).
That byte is the move map's "movement points left on arrival"
([`23` §7](23-ai-system.md), [`29` §1.2](29-interface-contract.md)) and it is
**alive at this point**: `aWalkMoveMap` stamps the destination `100` first
and its closing sweep zeroes only the cells that are not. The mechanism is
pinned; the intent behind the number is an inference (a unit with points to
spend will act again, so its arrival is not the end of what it does). Since
the AI fills at the horizon levels of `23` §7, a computer unit routinely
arrives with more than six points left, and then — unless it was seen where
it started — walks in mode 0, with no frame drawn. The *Enemy Move* option
is `0x00460510`. Mode 3 has one write of its own: it opens with
`aSetVisibleStateForUnit(unit, 0)` (`0x0046E4BB`), so a computer unit seen
where it starts is marked visible before it moves; mode 2 has none. After the
walk the same pass is run a third time from the arrival cell (`0x0046EE55`),
before the `MoveUnit` event, whenever the mover is still alive. The remake's
`core` runs all three passes and the mode-3 write inside its own
`aExecuteMove` ([`97` §28.6](97-slice-5-report.md)); the mode byte is then
decided by the presentation from the two answers the walk reports.

During every frame of a step in modes 1 and 3 (`0x0040EBB0`), when the view
mode is neither 0 nor 4, the camera's **position is kept and its target is set
to the unit's position plus its height** — the view tracks the walker. In mode
2, and in mode 1 or 3 when the view mode is 1 (the eyes), the step is
`0x0040EA30` instead: **the camera rides on the unit** at head height looking
at the object of the move's **final destination** cell (`aExecuteMove`'s own
third and fourth arguments, not the step's next cell) plus the unit's height,
and the unit's own object is hidden (state 5) for the duration — the enemy that
comes out of the fog is seen from its own eyes.

### 3.3 The rest of the step

Per step: the walked-distance byte (`25` §5.1), the mine test (`26` §6.1), the
cell marker rewrite, the reaction drain, a teleporter cell (type 9) ending the
path, the visibility rebuild, and the six script variables `0x41…0x46` followed
by the mission hook `0x0043F6E0` — none of which draws anything. The jump
(`aExecuteWarp`) is §7.1.

---

## 4. A shot — `aPlayFightAnimation` `0x0040BD70(sx, sy, tx, ty, reaction, xp)`

The fifth argument is `aAttackUnit`'s own fifth argument, i.e. the **reaction
flag** of [`25` §6](25-turn-and-round.md) (pinned at `0x0046C186`); the sixth
is the experience the shot earned. `aExecuteBomb` calls it with the bomb's cell
as both source and target and `xp = -1`. The stages, in order:

### 4.1 The clip

`0x004055E0(slot, attacker, selector)`: slot 3 for a normal shot, **slot 6 for
a reaction**; selector 3 when the target is adjacent (`0x0044AE10`, the
Euclidean distance in cells, `== 1`) and 1 otherwise — both resolve through the
same `F` selector, so the distinction has no visible effect. Speed 6.0, stop at
`BREAK`. Then `int(length / 6) / 3` frames are spun (`0x0040BEC9`).

### 4.2 The caption

Text bank 3 is `txtmod_h.lcl` (`0x00449CB7`); ids used here: 10 *Missed*,
17 *received*, 18 *experience points*, 19 *Paralyzed*. For the player's own
unit with `xp > 0` the caption is `"%s %s %d %s"` = *`<name>` received `<xp>`
experience points*; for a computer unit or a reaction it is the empty string
`0x004FA524` (never written; 0 bytes) — **no caption**.

### 4.3 The camera

For the **player's own** shot nothing moves. For a **computer** shooter
(`unit + 0x45 == 0xFF`, `reaction == 0`):

1. project the shooter and the target (`0x00403960`), require the screen y in
   21…99 and a clear line from the camera (`0x00453050`);
2. shooter and target on one cell → `0x004529D0(5, 2, 1)`;
3. else if either is not visible or the view mode is 4: with the target within
   three cells (`0x0044AE10 < 4`) and no more than 0x12C0 apart in height —
   `(9, 5, 1)` behind the shooter when the target cell is empty, `(5, 3, 1)`
   **behind the victim** when it is not; otherwise a flight to `shooter −
   direction × 3200` (5600 for large types, `unitInfo + 0x7B`) at `z =
   shooter.z + unitHeight + 1600`, looking at the target + its height.

For a **reaction** (`reaction != 0`): a coin toss `aRandom2(0, 10) < 5` (in a
network game: whose unit it is) chooses **behind the mover looking at the
reactor** (under 5) or **behind the reactor looking at the mover** (5 and
over). *(Corrected 2026-09-02 from the listing at `0x0040C08E`; the first
reading had the two numbers transposed.)* The camera stands `2400` back from
the unit it is behind along the line's horizontal direction (`0x0046D400`,
components 1 and 2), at that unit's z plus the **reactor's** height minus
`4800 × ` the line's third component, its slope — `5600` and `8000` for a
**large** unit behind (`unitInfo + 0x7B` of the one the camera stands behind).
The height is then raised by `0x00453730` to no less than the cell under the
position plus the unit on it (or 3200 with no unit record), nor than any of
its four neighbours' heights under 16 000, plus 800; the look-at is the other
unit's object plus the reactor's height; then a flight. `docs/28` §12 item 1's
"`aRandom2` is what the effects draw from" holds for the camera as well: this
draw is not `aRandom`'s. The coin's `5.0` is the double at `0x004B11D0`.

### 4.4 The floating texts

The whole cell array is scanned for [`22` §7.3](22-combat-and-visibility.md)'s
markers, up to 16 entries (`0x004FBFF4` bounds them):

| Marker | Text | Type |
|---|---|---|
| `0x5A` miss | *Missed* | 0 |
| `0x5B` hit, no damage | `"0"`; *Paralyzed* when the target's `+0x41 == 5` and the weapon is 45 | 1 |
| `0x5C` damage | `"%d"` of `cell + 0x0C` | 2, or 4 for species 2 |
| `0x5D` killed | the empty string | 3, or 5 for species 2 |

Colour `0x5ACB`. After the impact they are projected to the screen
(`0x00403960`) and drawn by the tick in type 0: **up two pixels a frame,
fading over 15 frames.** The highest type over all targets is the shot's
*severity* (1 hit, 2 damage, 3 kill) and selects the voice below.

### 4.5 The sounds

The weapon's own wave (`"%s.wav"` from `SetWeaponInfo + 0x25`), the secondary
wave by weapon id (`ricochet.wav` @80, `explosion2.wav` @81, `aexplosion.wav`
@95 — `28` §8.1), and one voice by severity and the target's species: 2 →
`S_HUM_n` / `S_ALI_n` round robin (`28` §4.1); **3 → the death scream
`SP_HUM_n`, ids 0x32…0x34 for humans and 0x35…0x37 for aliens, `explosion.wav`
for species 3**; unit types 0x16 and 0x19…0x1A are silent.

### 4.6 The projectile

The muzzle switch of `28` §8.1 spawns the effect, the weapon wave is played,
the overlay type is 4, and the routine **waits up to 100 frames for the flag
`0x004FE63C`**, the *projectile arrived* flag: every projectile creator clears
it and thirteen update arms set it when their record lands — kinds 1, 15, 25,
26, 27, 28, 32, 45, 47, 49, 69, 71, 74 (pinned by arm). Weapons 0x0F, 0x11, 0x14,
0x15, 0x1B, 0x1E…0x20, 0x24, 0x25 skip the wait.

### 4.7 The impact

The impact switch of `28` §8.1 at the target cell, plus the three arms that
change the map rather than the pool: weapon 40 sets nine cells on fire
(`0x0042F840` ×9), 42 lays a mine (`0x0042FA70`), 46 spawns a Spider
(`22` §9.4.2).

### 4.8 Blood and death — the part `22` §9.5 and `97` §26.3 had wrong

`aKillUnit` `0x00472920` is a network message and `aRemoveUnitElement`. **The
visible death is here**, per floating-text entry:

| Entry type | What is drawn |
|---|---|
| 2 damage | `aBlob_CreateBloodFlood` `0x00420D80(shooter cell, target cell, 0)` — the blood flies **from the shooter towards the target**; `0x00421360` for types with the `+0x7B` flag |
| 3 killed | **the object is hidden at once** (`0x00405320(obj, 5)`); then unit class `unitInfo + 0x00 == 0x10` → `aBlob_CreateKillFire` `0x00423AD0`; else by severity and species: severity 1 → `BloodFlood` mode 1 or `aBlob_CreateFireExplosion` `0x00429A80` for species 3; severity 2 → `aBlob_CreateFireDeath` `0x0042B1D0`; severity 3 → `BloodFlood` mode 2 and `aBlob_CreateFlyingDebris` `0x004216D0`, or `0x00420B80` / `0x00421C50` by species |
| 5 killed, species 2 | hidden; class 0x0C → `aBlob_CreateFlyingUnit` `0x00429700(x, y, size × 2)` **plus** `FireExplosion` and `explosion2.wav` — the barrel flies; class 0x0D → `0x004298D0` |

Four of those creators — `0x00420B80`, `0x00421360`, `0x00421C50`,
`0x004298D0` — carry no developer name (`blob_tables.py` lists them as
`None`); the others are the named creators `28` §7.6 lists without a
trigger. This is their trigger, and §4.8.1 is what they build.

#### 4.8.1 The death creators, transcribed and measured

`tools/inclib/blob_creators.py` carries seven of them as programs read out
of their own instructions (`DEATH_PROGRAMS`), and `presentation_gold.py`'s
`deaths` phases call each one inside the running engine with controlled
tiles and a seed written through the game's own `memcpy`, then read the pool
back and replay the program from that seed: every record field for field,
and the draw count against the seed the call left. The four names below that
are not developer names are this project's.

| Creator | Name | Builds |
|---|---|---|
| `0x004297F0` | `death_puff` | one class-2 record, kind 59, life 20, drifting `aRandom2(−1000, 2000)` sideways with `aux = aRandom2(5, 20)` — the bloodless substitute |
| `0x00420B80(x, y)` | `death_blood_burst` | fifteen pairs of `A_BLUT4` (kinds 17 and 43, life 15) rising from the tile, `vz = aRandom2(500, 500)` and the same plus 1 600, paired by the `delay` they share — the severity-3 death of species 1 |
| `0x00420D80(sx, sy, tx, ty, mode)` | `aBlob_CreateBloodFlood` | the damage effect: from the **target's** object, in mode 0 twelve `A_BLUT4` (kind 17, life 8) scattered ±800 and starting 1 280 along the direction from the target to the shooter (`0x0046D400` with its shift flag, the doubles at `0x004B1248..58`: 16 × the horizontal terms, 160 × the vertical, −1 280 for the step), mode 1 fifteen on the spot, mode 2 thirty-five scattered ±4 800 |
| `0x00421360(sx, sy, tx, ty, mode)` | `death_blood_spray_large` | the same spray with kind 50, life 8, 4 / 15 / 35 records and 48 × the horizontal terms — the one used for units flagged at `+0x7B` |
| `0x004216D0(x, y)` | `aBlob_CreateFlyingDebris` | splats `A_SPLAT1..5` thrown from the tile (kind 18, life 50), each trailed by four blood pieces `A_BLUT1, A_BLUT1, A_BLUT2, A_BLUT3` (life 30) — twelve throws in output mode 3, five otherwise — then five lower splats |
| `0x00421C50(x, y)` | `death_species_burst` | for types 50, 51 and 56: seven times in ten (`aRandom2(0, 10) <= 6.0`, compared as a double) two `A_SPLAT5`, two class-2 bursts (kind 51, life 16) and the type's own three pieces `A_50A/B/C` (`A_51*`, `A_56*`) each with a four-piece blood trail; otherwise, and for every other type, a mode-1 `BloodFlood` and `FlyingDebris` on the tile. Type 57's arm (`A_57A` four times) is in the switch and unreachable |
| `0x004298D0(x, y)` | `death_barrel_burst` | ten tumbling `A_BDEBI1` / `A_BDEBI0` (kind 5, life 100) from the object's own position, rotations `aRandom2(0, 4096)` on all three axes — the class-0x0D death beside `aBlob_CreateFlyingUnit`'s class-0x0C one |

**The gore level.** `0x004604A0` returns dword 10 of `Game.opt` (`0x00512A00`,
[`20` §8](20-lcl-language.md)), which the LCL `?_` command writes and the
options screen does not. Six reads in four routines — `death_blood_burst`,
`aBlob_CreateBloodFlood`, `death_species_burst` and the killing teleporter
`0x00416840` — and one rule: at level **1** every death is the puff; at
level **2** a unit whose player byte `+0x45` is not `0xFF` (not the
computer's) gets the puff and the computer's units bleed; at level **3**
everything bleeds. `BloodFlood` applies it per record — kind 60, rotation 5
and a drawn `aux` for the puff-style record, kind 17 for the blood, with the
level-2 blood keeping level-1's wider `aRandom2(−200, 400)` spread where
level 3 draws `aRandom2(0, 50)`. `20` §8 read this global as "the
unit-drawing path"; it is the blood switch.

**What the capture measured.** Fourteen calls, one process each, from a
written seed: the puff on the marine's tile; `death_blood_burst` on the
marine's and on the `Ray'Ther`'s; `death_barrel_burst` on a case's;
`FlyingDebris` on the marine's; `BloodFlood` and the large spray in all three
modes from the marine's tile to the `Ray'Ther`'s; `death_species_burst` on
the `Ray'Ther` with a seed that takes the seven-in-ten branch, with one that
takes the other, and on the marine. Every record the pool held — **253** across
the fourteen — matches the program field for field, and every call's draw
count matches the seed it left. The game copy's `Game.opt` holds gore level
**2** and output mode 2, so what is measured is level 2 on both sides of its
rule (the marine's deaths came back as the puff, the computer's as blood),
the five-throw debris loop, and both branches of the species coin including
the nested `BloodFlood` and `FlyingDebris`; the level-1 and level-3 arms and
the twelve-throw loop of output mode 3 are transcribed from their
instructions and not run. Four of the five doubles are told from a
neighbouring value by the capture (`deaths.constants_discriminated`); the
vertical term's 160 is not, because both tiles stand at the same height and
the two units are the same height, so the term is zero on every record — it
is read back out of the executable by `blob_tables.py` instead.

### 4.9 The end

Overlay type 0; at least 20 frames and until the pool is empty
(`0x004FE640`, the live-blob count the sweep maintains); then
**`aContCHAnimation` `0x004054D0` resumes the `F` clip past `BREAK`** and the
routine spins until the clip has played out (`0x00405460` reports its
remaining frames), the pool is empty and the caption has faded; then
`aStopCHAnimation` and the sound buffers are freed. Unit type 0x37 and
animation slot 0x0B skip the resume.

So one shot is: aim in 3–6 frames, hold while the round flies (≤ 100 frames),
the numbers rise for 20+ frames, the arm comes down. A remake that holds a
fixed 0.35 s and never resumes the clip (`97` §24.2) reproduces none of the
three timings.

---

## 5. Being hit, dying — summary

There is no hit clip and no death clip ([`40` §7.2.1](40-charisma-model-animation.md)).
Being hit is the floating number, the blood and the pain voice; dying is the
object hidden in the same frame as its number appears, an effect by species
and class in its place, and the death scream. A unit destroyed by its own
weapon's overheat (`aPlayWeaponExplosionAnimation` `0x0040F420`, kind 1) gets
`FireExplosion` and `BloodFlood` on its own cell, is hidden, and the camera
orbits it (§7.5).

---

## 6. Idle — a scheduler, not a loop

### 6.1 The four slots

`0x00406FC0` runs `0x004060B0(slot, type)` every frame for slots **1, 2, 4
and 5** (`type = −1`, except slot 1 in mission `_C_118`, which asks for type
61 — the boss). `0x004060B0`:

1. returns at once when the option *Cursor and animation level*
   (`Game.opt + 0x20`, `20` §9) is 1;
2. if the slot's countdown `0x004FA83C + 0x4C × slot` is positive, decrements
   it and returns — **the countdown is in frames**;
3. otherwise frees whatever the slot held (`0x00406000`), picks a unit —
   `aRandom2(0, 200)` as a unit index — and requires it alive (`+0x16`),
   unflagged (`+0x4F`), not already animating (`+0x56 == 0`), with an idle
   clip the selector of §6.4 is willing to name and a model handle on its
   object. **The type argument is dead.** The search that should find the
   first live unit of the asked type reads unit 0's type byte once and
   compares that same byte two hundred times (`0x0040616C`: `cmp eax, ebp /
   je / inc ecx / cmp ecx, 200 / jl`, with no reload inside the loop), so it
   matches only when unit 0 is of the asked type and otherwise falls through
   to the draw. The one shipped use — slot 1 asking for the boss, type 61,
   in `_C_118` — works because that mission's unit 0 *is* the boss
   (`_C_118.lev`, unit 0, type 61). Measured in §6.3: every call past the
   countdown draws exactly once, and the argument never chose;
4. resolves its `S` clip (`0x0042DDF0`), adds it to the model, **starts it at
   speed 1.5**, reads the length back (§1.2), and sets the countdown to that
   length.

So at any moment **at most four units are idling**, chosen at random; a unit
plays its clip once, in two thirds of the length, and the slot then holds the
finished animation until the countdown ends and frees it. The
remake's "every body loops `S`" (`92` §7.10) is not what the engine does.

### 6.2 What a unit holds when no slot is on it

**Measured** (§6.3), and the code agrees with the measurement:

* while the clip plays, `IWorld::Simulate(1.0)` advances the animation's
  clock by 1.5 a step and writes the bound parts' Eng3d records — the
  position at `+0x10` and the 3×3 rotation at `+0x1C` of the record at
  `V100Part + 0xD0`;
* at the clip's length the clock clamps and `finished` goes to 1, and the
  records **stop changing**: the body holds the clip's **last frame** for as
  long as the slot keeps the finished animation attached — the rest of the
  countdown, a third of the length;
* `aFreeCHAnimation` `0x00406000` → `StdModel::RemoveAnimation` `0x0049F228`
  (the model's virtual slot 2) → the animation's detach walker `0x0049C45D`
  → each movement's detach `0x0049B308` → `V100Part::DetachMovement`
  `0x004A675A` **zeroes the part's channel slot** (`part + 0xC0 + 4 × ch`).
  The free itself moves nothing;
* on the **next** `Simulate`, `V100Part::Update` `0x004A6807` finds no
  movement in the channel and writes the **bind matrix** (`40` §6): every
  part the clip had moved is back at its bind pose, and stays there.

So: the idle plays once; for the remaining third of the countdown the body
holds the clip's last frame; when the slot is freed the next frame puts it
back in the bind pose. For 42 of the 99 (model, `S`) pairings the last frame
is more than one bone unit from bind (`PC_S0_008`: 38 units, 0.6 m at the
hands), so the return is a visible snap — and that is the original. For
`P0_S0_000`, the clip the measurement animates, the last frame differs from
bind in the records of **10 of its 20 bound parts** (`pose.parts_away_from_bind_at_the_end`).

The chain above is what §12 item 1 once called undecompiled; it is now read
and the measurement stands on its own regardless.

### 6.3 The measurement

`tools/presentation_gold.py` drives the engine inside a running
`Incubation.exe` (`docs/91`'s anchor, the fixture save `_6_.sav`, `_C_141`)
in two phases; `tests/fixtures/presentation/README.md` records what each
holds.

**`idle_random`** calls the starter two hundred times, asking for type 50,
with `aRandom2`'s seed and the slot table read after every call and the unit
array read once. The countdown the menu left ticks down first with no draw.
Every call after it moves the seed by **exactly one** Lehmer step, and the
replay — `int(200 × u)` from the measured seed — names the slot the engine
drew; every drawn slot is empty, dead, hidden (`+0x4F`), a neutral case the
selector refuses, or the one marine the guards accept, and the slot table
fills only on that one. The save has exactly one candidate: slot 3
(`Sgt. Brat`, type 23, weapon 2 → `P1_002`, idle `P0_S0_000`). The unit of
the type asked for, slot 10 (`Ray'Ther`), is refused by `+0x4F` — and would
not have been reached anyway, because unit 0 is a case (type 32). A start is
a one-in-two-hundred chance a call and the phase does not always see one;
the replay of every call is what it pins.

**`idle_pose`** makes the start deterministic: the slot's countdown and the
seed are written through the game's own imported `memcpy` (seed 139, whose
first draw is 3), the starter takes on its first call, and the live
`StdAnimation` reads `time 0, length 90, speed 1.5, loops 1, finished 0`
with the countdown 90. The parts the clip binds are then reached through the
animation itself — the movement list at `+0x38`, each movement's channel
interface at `+0x3C`, the `V100Part` `0x158` below it — and read whole at
eight stops: after the start, after 45 `Simulate(1.0, 0)` steps (clock
67.5), after 15 more (90, finished), after 2 more (still 90), after
`aFreeCHAnimation`, and after one and two further steps. 20 of the clip's
21 movements bind (the 21st names `Banner`, a part `P1_002` does not have);
the rotation tracks take channel 1 and the position tracks channel 0. The
records the steps write are the ones §6.2 describes: unchanged by the
start, changed by the steps, identical at 90 and at 92, untouched by the
free, back at the bind record on the first step after it, and still there
on the second; the channel slots are non-zero throughout and zero after the
free.

The earlier capture this section described animated slot 3 as well — the
starter had drawn it on its hundredth call — while the tool believed it had
started slot 10's `PC_S0_000`; the "declared length 90 against keys to 127"
of §1.2 was that mistake, and it is struck through there rather than
deleted.

## 7. The other unit animations

### 7.1 The jump — `aPlayJumpAnimaion` `0x00411460`

The body is turned to face the landing cell (`0x004051E0` with the angles of
`0x00403AA0`); the flight is a **parabola**: `steps = max(|dx|, |dy|) / 480`,
`vz = +(steps / 2) × 160` falling by 160 per frame, position by `delta /
steps`; every frame the camera **keeps its position and looks at the flying
unit**. A player's unit leaves a trail (`0x00423670`: a `ZoomBob` and four
sprites of kind 11 per frame) and raises landing dust `0x004227C0` at both
ends, with `jump.wav` @69 and `drop.wav` @70; a computer unit screams
`S_ALI_n` instead of the trail. The routine waits for the pool to empty.

### 7.2 The push — `0x0046D530`

A flight to the pusher; **four frames per cell** with a dust puff
(`0x0042A6E0`: a sprite of row 4, kind 10, life 20, random velocity) each
frame; a hole swallows the object in 50 steps of `z −= 320`; a mine under it
detonates (`26` §4).

### 7.3 The selection marker — `0x00422D40`

**Four `A_ARROW.3DI` model blobs** of kind 14, life 15, placed 90° apart at a
radius of 4800 (9600 for large types) around the unit — this is `28` §8's
"arrow marker" in `aUI.cpp`, the ring of arrows around the selected unit. The
skill, jam, overheat and `RotatingCamera` orbits of §7.5 raise it too; heal and
poison raise a `FlashCircle` (`0x00423030`, `0x004232E0`) instead.

### 7.4 The reaction-fire jam — `0x004104A0`

Called from the drain (`25` §6) when the reactor cannot fire: the arrows, a
flight to the unit, `jammed.wav`, the centred caption *Weapon runs hot!* (id 6)
or *Out of ammo!* (id 7, when `+0x3D == 0`), and the orbit below.

### 7.5 The orbits — skill, heal, poison, overheat, `RotatingCamera`

Six routines share one shape: read the camera, raise the arrows, fly to a
point beside the unit, set a centred caption (overlay type 3), then **40
frames** during which the camera's offset from the unit is rotated by a fixed
step each frame (`0x004039A0`), then fly back:

| Routine | Start offset from the unit | Step per frame | Caption |
|---|---|---|---|
| skill `0x00410190` (from `aAttackUnit`) | `(0, +0xC80, height + 0xC80)` | +100 | *increased skill level* `"%s %d"` |
| heal `0x0040FBE0` | `(0, +0x1900, height + 0xC80)` | −40 | `"%s: %s %d"` with *increased hit points by* |
| poison `0x0040F8F0` | `(0, +0x1900, height + 0xC80)` | −40 | *Fightingpower reduced!* |
| overheat `0x0040F420` | flight to the unit first | +100 | ids 14/15/16: *Technical problems with weapon* / *Weapon jammed* / *Weapon damaged*; kind 1 also hides the unit with `FireExplosion` + `BloodFlood` |
| jam `0x004104A0` | `(0, +0xC80, height + 0xC80)` | +100 | ids 6/7 |
| `RotatingCamera` `0x0040FF30` (LCL) | `(0, +0xC80, h)` | +100 | none |

`+100 × 40 = 4000` of 4096: very nearly a full turn; `−40 × 40 = 1600`: a
140° sweep the other way. Text ids are `txtmod_h.lcl`'s.

---

## 8. Set pieces — every one moves the camera and most spawn effects

Every `aPlay*Sequence` follows one shape: read the camera, **fly to the
object**, start its wave, run its frames, wait for the pool, fly back. The
frame counts and steps are [`28` §14](28-effects-and-sound.md)'s; what is new
here is the camera and the effects each one adds:

| Routine | Camera | Effects | Notes |
|---|---|---|---|
| `aDoorOpenSequence` `0x00410A20` | flight to the door from a point above the unit, **suppressed only when the two extra tiles are −1** — the LCL wrapper; the player's Use and the AI's opener pass real tiles | none | `door.wav` looped; 10 frames; flight back |
| tubes `0x00410F10` / `0x00411150` / `0x004112E0` | none | `0x00423770` smoke at frame 10 (`OpenTube` only) | 19 frames |
| `aPlayElevatorSequence` `0x004125D0` | flight to the lift; **`aSetCameraPosition` every frame** | none | rider and cell move per frame |
| `aPlayPlatformSequence` `0x00412A00` | flight to the block; camera set every frame; `0x004234C0` dust per frame | | |
| `Bridge` `0x00410DA0` | none | none | 80 frames of `+0x26` |
| `FootBridge` `0x00414A70`, `FootBridge2` `0x00415110` | flight to the block; camera set every frame | none | **the block tilts and the units on it tumble** — §8.1: a tilt drawn once from `aRandom2(−2, 4)` turns the *block* every frame, and every rider turns by a fixed ±25/±12 a frame by its index |
| `aPlayLaserBarrier` `0x00413560` | flight to the beam, then to the middle victim | the beam `0x00428990`; `0x0042AB40` and `0x0042A9D0` on every unit killed | 40 frames |
| statues `0x00413A40` / `0x00414000` | flight to 32 000 (20 m) above | `FireDeath` on every unit in the path, `0x00428BF0` beam | the "knocked-down" state 3 of §1.3 |
| `FireCircle` `0x004131C0` | flight to the cell (when asked) | `KillFire` on the eight neighbours, `0x00422F00` | |
| `aPlayGroundFireAnimation` `0x004157B0` | free-position search, then `(9, 7, 1)` on the unit | units hidden, `BloodFlood`, `FlyingDebris`, `TubeSmoke` | |
| `aPlayCrushWallAnimation` `0x00415C70` | none | `0x004238C0` on every cell | |
| `RoofUnit` `0x00411B00` | flight to the drop | `0x00422460`, landing dust | `28` §13's drop rate |
| `GroundUnit` `0x00411FB0` | flight | `0x00422610`, a `L110EX00.3DI` object inserted, dust | 8 + 6 frames of rise |
| teleporters `0x004164F0` / `0x00416840` | camera target follows the effect (`0x0042B4B0`) | `0x0042A120`; the unit hidden at frame 40, moved at frame 10 | |
| bomber `0x00415E90`, para bomb `0x004160F0` | target follows the bomber / the bombs (`0x0042B4B0`) | `0x0042A8E0` at −320 000; `0x0042B070` per bomb | ends on the *arrived* flag of §4.6 |
| `MoveWorld` `0x0040F230` | set every frame | none | `0x00407E30` translates the world |
| lever `0x00416AD0` | flight to +0xC80 | none | |
| mine `0x00416DE0`, entry point `0x00416CF0` | none | `SmallFireExplosion`, `FireExplosion` | |
| supply box `0x00410780` | flight to +4000 | none | overlay type 5 (a text box) |

### 8.1 Four of them, line by line

The statue, the footbridge, the ground unit and the teleporters were once
skimmed; they are transcribed here and their constants pinned by
`presentation_tables.py` (`setpiece.*`).

**`aPlayRotateStatueSequence` `0x00413A40(x, y)`** — `stone.wav` at volume
74 and `stonefire.wav` at 84 are opened; the nearest special object within a
10 000-unit box of the statue's object is found (`0x00406F20`); the camera
flies to 32 000 units (20 m) above its own position, looking at the object;
`stone.wav` starts, looping. **Thirteen frames** turn the object's rotation
word `+0x2A` by `+0x50` (80 units, 7°) each; a fourteenth writes the
original value `+0x400` (90°) — the statue quarter-turns and settles. The
statue's cell then flips its `+0x0B` bit and the beam runs along the axis
that bit selects: up to **five** cells each way from the statue (a cell of
field type 2 stops it), and for every unit on the way the object is hidden
(`0x00405320(obj, 5)`), `aBlob_CreateFireDeath` `0x0042B1D0` fires on its
tile and the unit is remembered; `0x00428BF0` draws the beam from the
statue's cell to the last cell reached, each way. The beam is `2 × cells − 1`
class-2 dots (kind 62, life 7, aux 25) along the line at height 3 200 and
six sparks (kind 62, life 7, velocities `aRandom2(−3000, 6000)` sideways and
800 up, rotations alternating `(3, 0)` and `(0, 2)`). `stonefire.wav`
plays once, the frame loop runs until the pool is empty, and the remembered
units are removed from the map (`0x0043B8D0`, `aRemoveUnitElement`
`0x004779C0`). `aPlayStatueSequence` `0x00414000(x, y, dir)` is the same
without the turn: the direction argument picks the axis and the sign, the
walk is up to **nine** cells, one beam, one unit remembered.

**`aPlayFootBridgeSequence` `0x00414A70(x, y, frames, wave)`** — `bridge2.wav`
at 78 or 100 by the wave argument; the 3×3 cells around the block are set to
field type 4, any effect object on them freed, and every unit on them
listed; the camera flies to the nearest special object within 5 000 units.
A tilt is drawn **once**, `aRandom2(−2, 4)`, 0 becoming −1. Every frame for
`frames` frames: the block's rotation words `+0x24 += 25 × tilt` and
`+0x22 += 17 × tilt`, its `z −= 3 360`; the camera position `z −= 2 400` and
its target `z −= 3 360`; every rider is placed 3 200 lower than the frame
before but drawn 160 above that (`aGetStdObjectPosition` / `0x004050A0`), and
its rotation words `+0x22` and `+0x24` gain **+12 / +25** for an even-indexed
rider and **−12 / −25** for an odd one (`0x00405180` reads the triple,
`0x004051E0` writes it) — the same rider keeps turning the same way,
cumulatively. Afterwards the special object is freed (`0x00406C30`), every
rider is removed from the map and, if it was the selected unit, the
selection cleared (`0x00471FA0`); the camera flies back and is set. **`FootBridge2`
`0x00415110(group, frames)`** finds the two cells whose `+0x0B` group byte
matches, clears the group byte and the effect on each, and looks for its
camera object in a `500 × 500 × 12 800` box 160 to the side and 4 800
below the first cell's object, then the second's; the frame loop is the
same.

**`GroundUnit` `0x00411FB0(x, y, ux, uy)`** — the unit at `(ux, uy)` is moved
to the ground cell's object and placed **3 200 below its top minus its
height**, 160 higher than that; `alien_scream.wav` (for an odd object id)
and `crush.wav` are opened; the camera flies to the unit; four frames wait
if the scream played; `crush.wav` starts; the unit's field is rebuilt
(`0x0046A760`, `0x004792A0`); `0x00422610` throws twenty `A_DEBRIS` and four
`A_SPLAT1` (kind 29, life 50, velocities `aRandom2(−200, 300)` ×2 and 300
up, no rotation, `delay = aRandom2(0, 4)`; a third draw, `aRandom2(40, 140)`
or `(40, 100)`, is taken and never converted) from 1 600 above the object,
and a
`L110EX00.3DI` object is inserted at the cell (`0x00404E30`). **Eight
frames** raise the unit by 1 120 each, drawn 1 280 above the accumulated
height, with the camera set on it every frame; **six frames** then carry it
a fifth of the way per frame from the ground cell to its own cell in x, y
and z (`/5`, truncating), and it is finally set 160 above its cell.
`aBlob_CreateLandingDust` `0x004227C0` lands it; the loop runs until the pool
is empty.

**`aPlayTeleporterSequence` `0x004164F0(sx, sy, tx, ty, unit)`** —
`teleport.wav` at 97 and `teleport2.wav` at 98; `0x0042A120` builds the
stream: **two hundred** class-2 records, kind 65, life 70, one every 16
units of height from the source object's z, scattered `aRandom2(−1600,
3200)` around the target object in x and y and given a velocity that
carries each toward the target's height plus 3 200 (`aux 5, delay = i /
10`). The countdown runs from **70**: between 40 and 10 the camera target
follows the first live record of the pool (`0x0042B4B0`); at **40** the
unit's object is hidden (state 5); at **10** `teleport2.wav` plays, the unit
is moved to the target object and its object shown again (state 1); the
loop runs until the pool is empty. **`0x00416840(x, y)`** is the teleporter
that *kills*: `0x0042A2F0`, `teleport.wav`, `SP_HUM_0.wav`; after **ten**
frames the object is hidden and — by the gore level of §4.8.1 — either the
bloodless puff `0x004297F0` (levels 1 and 2) or `aBlob_CreateFlyingDebris`
`0x004216D0` (level 3) marks the spot.

---

## 9. The environment that moves by itself

### 9.1 The special-object state byte

The cell-owned objects (`cell + 0x0F`, the 81-slot array `0x004FA828`,
`26` §6.1) carry a **state byte at `+0x40`** and a subtype at `+0x41`, written
by `aCreateSpecialObject` `0x004069C0`'s last two arguments, and the refresh
of §1.3 animates them every frame:

| State | Per frame | Who creates it |
|---|---|---|
| 1 | joint triples 1 and 2 (`+0x2A`, `+0x30`) get a random heading each — two flame billboards | the fire placer `0x0042F840` (`A_FIRE1/2/3.3DI`, `SetGroundFire` phase 3, weapon 40) |
| 2 | triple 0 turns by +51 (4.5°) | mines `0x0042FA70` (`A_MINE.3DI`), subtype from `cell + 0x0E` |
| 3 | +25 / +51 / +102 by subtype 1 / 2 / other | the **shield** placer `0x0042FB90` (`A_SHILD.3DI`, [`23` §7.1](23-ai-system.md)); it writes subtype 2 into `cell + 0x0E` first, so a shield turns by 51 (4.5°) a frame |
| 4 | triple 0 turns by `aRandom2(0, 4096)` | the glow placer `0x0042FCB0` (`GLOW1/2.3DI`, `SetGroundFire` phases 1–2) |
| 5 | drawn, static | — |
| 0xFF | dead | `aDeleteSpecialObject` |

So a mine turns slowly, a shield turns at the same pace, a glow flickers by
turning at random, a fire's two billboards face a new way every frame. The
shield placer has two callers: the object seeding at load (`0x004079D0`) for
a cell whose kind byte is 3 — none shipped — and `aPlayFightAnimation`'s
weapon-43 arm (`Plasma Gun`, `Info.lcl`), which places one on the target
cell before `aBlob_CreatePlasmaBallImpact`; `23` §7.1 has what the shield
does to movement. This is the only scenery animation the
mission view has besides the blob-driven joints of `28` §7.8 and the drawbridge
of `28` §14.

### 9.2 The emitters

`CreateBGB` (`28` §8.2) is the other source of ambient motion; nothing here
changes what `28` says about it.

---

## 10. The computer's turn

The AI calls the same routines with the same blocking loops: a visible walk is
followed or ridden (§3.2, gated by the *Enemy Move* option), a shot places the
camera behind the shooter or the victim (§4.3), a door flies the camera to
itself (§8), and **every change to the map happens on screen in the frame it
happens**, because the sequence that changes it is the one drawing. The
redraw callback the AI is handed (`0x0047C2C0`, `23` §2) draws the turn banner
and the HUD; it moves no camera.

---

## 11. What the remake does today, against this

Measured against `godot/game` at the time of writing (slice 5 + `97` §24–§27):

| | Original | Remake |
|---|---|---|
| camera moves | flight §2.2 everywhere | ~~a snap of the pivot; one 0.18 s yaw tween~~ the flight, on the engine's six integers (`97` §28) |
| unit camera | behind / by quadrant, clear-line search | ~~pivot on the cell~~ §2.3 transcribed, the quadrant kept discrete; the search over the map's heights |
| walk | target tracks the unit; enemy ride | ~~no camera during a walk~~ §3.2's modes, the ride included |
| views | eyes / unit / map; right-drag rotate; middle-drag pan | ~~four yaws, zoom; no pan~~ eyes / unit / map on 1, 2, 3; the pan; no free rotation, by decision |
| fight camera | behind shooter / victim; reaction coin toss | ~~none~~ §4.3, both arms, the flight beside the clip rather than after it |
| clip speeds | 2.0 / 6.0 / 1.5 / 1.0 | 1.0 everywhere |
| shot | 9 stages, clip resumed past `BREAK` | clip to `BREAK` + 0.35 s hold |
| captions, damage numbers | drawn, rising, fading | none |
| blood, death | per species and class, object hidden at once; seven creators measured (§4.8.1) | 0.7 s linger, then gone |
| idle | 4 slots, random unit, once, snap to bind | every body loops |
| jump | parabola, trail, dust | teleport on rebuild |
| selection | four arrow blobs | cell highlight |
| own / AI door | flight, 10 frames, flight back | instant swap + sound |
| set pieces | camera + effects | 7 animated without either, 18 instant |
| fires, glows, mines | state-byte rotation | not created |
| AI terrain | changes in the event's frame | all applied before the replay |
| script camera | seven commands | events with no action |

The plan that follows from this table is the remake's business and is recorded
in `docs/97`'s next addendum, not here. *(The camera rows were closed on
2026-09-02 by [`97` §28](97-slice-5-report.md); the others stand.)*

---

## 12. Open questions

None. The one this section carried on 2026-09-02 — *the walk's pre-walk
visibility pass writes, and the remake's does not* — was closed the same day
in §3.2 and [`97` §28.6](97-slice-5-report.md): `core` now runs the three
passes of `aExecuteMove` as the writing passes they are, from the destination,
from the source for a computer mover, and from the arrival cell, plus mode 3's
self-reveal. The entry's own claim that "the arrival rebuild makes the same
marks" was wrong for `core`, which had no arrival pass at all; what made the
gap invisible was that nothing compared `+0x4F` after a computer turn. It is
compared now — `tools/ai_gold.py --check` diffs the byte on all 200 records
after both captured turns, where the engine reveals four and two human units
by walking, and the model without the passes fails on exactly those slots.
The six closed before it stand in the body, each with its evidence:

1. *The part matrices after detach* — **measured** (§6.2, §6.3): the bound
   parts' Eng3d records hold the last frame while the finished clip stays
   attached, are untouched by the free, and are back at their bind records
   on the first `Simulate` after it; the channel slots read zero. The hop
   through Charisma's component manager is read too — the detach walker
   `0x0049C45D` runs each movement's `0x0049B308`, which calls
   `V100Part::DetachMovement`.
2. *Which descriptor field is the declared length* — there is none (§1.2):
   `0x004A0A01` stores the first movement's last key time, pinned through
   the vtables to `fld dword [key + 4]`; the "90 against 127" was a
   different clip's 90 (§6.3).
3. *State 3 of the special-object byte* — the shield placer `0x0042FB90`
   (§9.1), which `23` §7.1 already named; two callers, both pinned.
4. *The four skimmed set pieces* — transcribed in §8.1 and pinned.
5. *The class behind the start slot* — `KeyFramedAnimationInterface`,
   implemented by `KeyFramedAnimation`'s sub-object at `+80` (RTTI, vtable
   `0x004B1DDC`): slot `0x2C` writes the speed at `+0x64` and re-runs the
   update, `0x24` reads the length at `+0x60`, `0x18` rewinds the time at
   `+0x58` (§1.2, pinned).
6. *Why the starter took on its hundredth call* — because it drew slot 3
   then (§6.1, §6.3): the type search never advances, every call past the
   countdown draws once, and the save has one candidate.

What the section once listed as unnamed — the four death creators — is
named, transcribed and measured in §4.8.1.

# 99 — Slice 7 report: the battle interface

**Date:** 2026-09-05. **Scope:** the plan's four stages, delivered as one
piece — the research pass and its checker ([`43`](43-battle-hud.md),
`tools/hud_tables.py`), the ground overlay in place of the green move map,
the direction ring as the rotation, the plate as an adaptive layout, the
unit panel, the command pad, the button columns and the radar. The remake's
mission screen was three lines of text over a full-screen 3D view
(`game/hud.gd`, `game/highlight.gd`); it is now the original's screen.

## 1. What was read, and what it changed

The reading is [`43`](43-battle-hud.md) and its checker is
`tools/hud_tables.py --check gog_incubation` (**194 checks**, in the
always-run block). Four things came out of it that no earlier document had:

* **The move map is a sprite pass, not coloured terrain.** `fcn.00417E70`
  projects every marked cell and blits a `mp1.LIB` digit — the movement
  points left on arrival — or a `mp.LIB` frame *after* the 3D frame, with no
  depth test. [`97` §45.2](97-slice-5-report.md) had read the opposite and
  the remake's depth-tested green quads were built on it. **And the digits
  are drawn only while the pointer is over a legal cell**: the fill is
  invisible until hovered, which is what a screenshot of the original shows.
* **The game's blitter is `fcn.004475D0`**, inside the range
  [`60` §1](60-lib-sprites.md) had assigned to LibMaker's writer. Its inner
  loop skips palette index 0 in every library, and its anchors are read only
  by the callers that subtract them — which closes both of `60`'s open
  questions at once and leaves the set at **32**.
* **Interface events 12 and 14 were the other way round** in
  [`29` §1.2](29-interface-contract.md): 12 selects the next own unit **with
  movement points** (`0x00477D40`), 14 puts the camera on the next visible
  enemy (`0x00477DF0`). `core/world.gd`'s `may_command` credited its tests
  to the wrong walker.
* **`aGetDirectionTo` reads the cell's state byte**, not its action point, in
  its mode-0 test and in its ratchet ([`23` §3.6](23-ai-system.md)). The
  pseudocode had one label wrong and both executable models — `inclib/combat.py`
  and `core/combat.gd` — inherited it. The captures could not tell the two
  apart; both twins now take the overlay bytes as a parameter, the AI passing
  its context's, the interface the selection's bands, and `test_hud.gd` pins
  that a farther target on band 33 beats a nearer one on 31. Every gold check
  still passes (`ai_runtime` 84, `ai_gold` 47, `turn_gold` 198,
  `combat_runtime` 148).

Smaller readings that went straight into the code: the ring's nine records
and their `dir.LIB` tiers, the `+0x46` write that costs nothing, the
selection rule (no points, no selection; none left, deselected), the pad's
six gates and the executor behind each, the columns' three dispatch tables
with their captions and keys, the panel's five blocks with every `uicons`
element and offset, the radar's coordinate map and its zoom click, the
100 ms blink, the far view's `map.LIB` flags at the zoom gate, and that
`aPrintLibText`'s y is the glyphs' **bottom** — which is what puts the turn
inside its groove and the name above the class icon.

## 2. What was built

| | Before | Now |
|---|---|---|
| ground | `Highlight`: depth-tested green quads on reachable cells | `GroundSprites`: `mp1` digits gated on the hover, `mp[43..47]` bands on the enemies in range, `mp[48]` frame under the pointer, `mp[51]` on the own cell, HP digits / 49 / 50 / 54 over own units, `map.LIB` flags in the far view, VP letters |
| rotation | none; a unit faced its last step | the direction ring on a reachable or warp cell (move, then face), or on the selected unit itself (turn in place); `RotateCommand` / `World.submit_rotate`; the shooter turns to its best band after a shot |
| selection | any own unit; kept at 0 points | `World.may_select`: no points, no selection; deselected when a command leaves none; `Tab` skips them too |
| frame | none | `plate_5` cut into ten pieces, corners fixed, bands and fillers tiled, the 3D window the remainder (`(60, 34)` by `W − 120` by `H − 140`); focal 400 at any width; hidden in the eyes view |
| panel | name, MP/HP/FP/ammo as text | the original's five blocks on `uicons`/`uweapons`/`umun`/`inv`, the status word from `Txtmod_h` 70..73, the heat wedge, the mode lamp, the rank, `hp/max` |
| pad | keys `D`/`H`/`U` | six `ui.LIB` sockets, lit by the engine's gates at every refresh and again at the press; `S` stimulant, `W` weapon mode (new `ToggleWeaponCommand`), `R` rest connected |
| columns | keys `1`/`2`/`3`/`Tab`/`Space`/`F5`/`F9` | eighteen `mi.LIB` slots with the sixteen events: the four views, save/load, remind/recall (slot 32), give up, next player, briefing, next unit, visible enemy (`T`), undo turn (slot 33, `Backspace`) and undo mission (slot 31), each captioned from `Txtmod_h` on hover |
| radar | none | the map around the selection turned with the camera, `sm.LIB` marks by side and state, the compass, the lamp, the scale stepped by a click on the screen |
| turn | `Turn: N` in a text line | `"%d"` at (560, 22), `"%d/%s"` red near a `SetTurnControl` par |
| picking | Godot's `project_ray_*` | `CameraRig.ray_through`: Godot's ray ignores the frustum offset and landed a cell away on this camera; found by the tour, pinned in `test_hud.gd` |

Files: `game/hud/{hud_tables,mission_hud,button_columns,command_pad,unit_panel,radar,direction_ring}.gd`,
`game/overlay/ground_sprites.gd`, `game/screens/plate.gd`,
`core/{rotate_command,toggle_weapon_command}.gd`, `World.{submit_rotate,
may_toggle_weapon, submit_toggle_weapon, may_stand_down, may_take_stimulant,
may_use, may_defend, may_select, target_bands, facing_to_target,
max_hit_points}`, `WeaponTable.{icon, name_of}`, `CameraRig.{frame_projection
(focal_width), ray_through, projection_of}`, `Combat.end_turn_facing(states)`,
`inclib/combat.end_turn_facing(states=)`; `main.gd` rewired; `hud.gd` and
`highlight.gd` removed. `tour.gd` gained `markers`, `hud event|pad|ring|radar N`
and reports `hud`, `markers` and `visible_rect`.

> **2026-09-06.** `godot/tour.gd` is gone: the verbs and the reply document
> moved to `godot/game/agent/` behind the control server of
> [`docs/92` §7.16](92-remake-architecture.md), reached by `--agent-port=` on an
> ordinary launch. Every command named in this report still exists under that
> name; what changed is the transport, and this report is left describing the
> drive as it happened.

## 3. Verification

```
python3 tools/hud_tables.py --check gog_incubation      194/194
python3 tools/hud_tables.py --emit-cases tests/fixtures/hud/cases_hud.json --root gog_incubation
bash godot/run_tests.sh                                  36 suites, 3751 checks, 0 failures
```

The whole always-run block passes (41 commands, exit 0 each), `ai_gold`,
`turn_gold` and `combat_runtime` included after the facing correction.
`test_hud.gd` (**329 checks**) holds `HudTables` to the fixture table for
table, lays the plate out on 640x480, 853x480, 640x512 and 1120x480, pins the
anchor sign, the cell-state translation, the live overlay with and without a
hover, the ring, the radar's arithmetic, the selection rules, the state-byte
facing, the ray round trip and the interface's captions and report.
`test_render.gd` now pins the overlay's *absence* of a depth test where it
pinned its presence.

**Played, through `tour.gd`, at 1280x960, 1920x1080 and 1280x1024** (visible
rectangles 640x480, 853x480, 640x512): the plate lays out with the columns at
the edges and the window taking the surplus; a click on a marine selects it
and the panel names it (`Sgt. Bratt`, `10/10`, `Standard Assault Rifle`, the
disc's `3`) with 20 icons; a click on a reachable cell raises the ring
(mode 1, nine records); a hover over the destination shows every digit (4 of
4) and the frame; `hud ring 0` walks the unit to the cell and faces it north
(`facing 0`, `mp 2`, still selected); `hud pad 1` puts it on overwatch and
the pad darkens; `hud event 2` hides the plate for the eyes view; the radar
steps to 50 fields; `hud event 10` ends the turn, the computer moves, the
turn reads `1`. Two defects the drive found and this slice fixed: the pick's
ray (above) and the hover being undone every frame by a pointer poll.

**Not done: a Wine screenshot of the original.** The game copy starts
(`wine explorer /desktop=inc,640x480 Incubation.exe -english` from a copy
under the scratchpad; Vulkan initialises in its log), but `screencapture`
in this session has no screen-recording permission ("could not create image
from display"), so no picture could be taken. `gog_incubation/` was read
only. The blit tables were cross-checked against the binary's bytes instead
(§1); the one thing a screenshot would have added is the two panel fonts'
identity, which is decision D7 in [`43` §11](43-battle-hud.md).

## 4. Decisions

Every reading the slice could not settle is a decision in
[`43` §11](43-battle-hud.md) with the reading that would settle it named:
the magnifier's info page (its button is present and dark — the `Data` bank
is not in the cache), the campaign map's band-coloured rings
(`fcn.00418F40`, recorded in [`27` §2.6.3](27-campaign.md)), the two plate
fonts, the options bar (its nine controls are the shell's), the campaign
screens staying on `place_on_plate`, and D10, the target overlay's one
transcribed arm (§5). Two were closed. §6's second reading of the ground
overlay opened a third and closed it the same day — whether a blocking
animation redraws the overlay through the callback pointer `fcn.0047D600`
stores; it does not, and [`43` §3.1](43-battle-hud.md) carries the trace.
The set stands at 32.

Outside the plan and left as it was: the pale bracket under every body is
the unit's **own ground object**, built from its type's model column
(`UnitsView`'s `marker`, a one-field box at z 80) and part of the 3D scene --
it looks like the overlay's `mp[51]` corner frames and is not one of them,
which is worth knowing when reading a screenshot; the developer status line stays inside the window
under the top band; and the `T` key that toggled the field-type overlay
moved to `Y`, `T` being the original's *Jump to visible enemy*.

## 5. What a review pass found (2026-09-05)

A multi-agent review of the branch read the slice against the documents and
the binary; every suite was green throughout, so none of it was visible to
the test run. Ten defects were confirmed and all ten are fixed:

* **The ring rebuilt the bodies and dropped the walk it had just started.**
  `_complete_ring` ran `_after_command` a second time — `move_selected` runs
  it already — and that frees every body and clears the walk list, so a
  partial walk teleported and the reaction count was overwritten with
  nothing. Only the turn in place refreshes now; no band reads the shooter's
  facing (`core/hit_chance.gd` has none), and the turn after a move is free
  (§4.3 of [`43`](43-battle-hud.md)).
* **The interface's buttons bypassed the replay guard.** `_unhandled_input`
  returns while the computer's turn is being replayed, but a `TextureButton`
  is pressed through the GUI stage; *Next player* mid-replay ended a second
  turn and *Load* freed the scene the replay was still stepping. Both
  availability gates now refuse while `AIPlayback` runs.
* **The undo slots could restore another mission.** Nothing deletes slot 31
  or 33 and the buttons were lit by a bare file-exists test. They now read
  the slot's header once and light only for this mission
  ([`43` §5.4](43-battle-hud.md)).
* **`World.target_bands` was a second transcription of `aBuildTargetOverlay`
  and dropped its exclusions** — the never-target and immune types, the two
  weapon overrides, the fitness gate and the arm dispatch. On shipped data it
  banded a `Norc'Yn` and a Concrete Block, offered the shot and turned the
  shooter towards them. It is now [AIOverlay]'s own build, the routine the
  computer's plan calls, and `facing_to_target` reads the bytes it leaves
  rather than a dictionary written back into an array (decision D10).
* **`tour.gd`'s `walk_to` stopped walking** when the ring went behind the
  click, and its key table still bound `T` to the field-type overlay. Both
  are fixed, the ten new keys are bound, and the reply carries `walking`
  because the world moves in one call and the picture does not: reading the
  endpoint alone is what let the first defect through the drive.
* **The radar lit its lamp with nothing selected** and counted a props unit
  as an enemy. `0x00451FE3` returns before the marks *and* both lamps, and
  `0x004521AE` skips player 0xFC; the suite accepted "four marks or five",
  which is how it passed.
* **`Combat.end_turn_facing` swallowed a wrong-sized overlay** where the
  Python twin raises; it now says so.
* **The mission-result test had lost its call** with the old HUD's body, and
  the panel's movement number was centred without its shadow.

Six of the ten are driven as well as checked: the walk now survives the
ring (`walking` is true four frames in and false by sixty), `walk_to` walks
again and ends facing its direction of travel, the radar shows four compass
letters and no lamp with nothing selected, `key Y` reaches the field-type
overlay, and **the replay guard is driven** — on `_C_129`, whose computer
turn does replay, *Next unit*, *Undo last turn*, *Next player* and a unit
click all land inside a running playback and leave the world hash, the turn
and the selection untouched. That is the item this report first recorded as
reviewed only: `_C_140`'s first computer turn replays nothing, and the
answer was to drive a mission whose does. The remaining two are pinned by the
suites (the mission-result block and the state-size diagnostic).

The two candidates the review raised and withdrew are worth recording: the
radar and the overlay reading the stored `+0x4F` while the bodies read the
fog pass is the engine's own asymmetry (`aSetVisibleStateForUnit` saves and
restores one of the two), and *Give up!* leaving the interface up is
unreachable in the shipped set, every one of the 110 mission scripts carrying
a no-units defeat rule — the remake implements neither of `0x0041DA20`'s own
result-5 writes, so a **user-authored** map without that rule would leave the
interface running after a surrender.

## 6. What playing it found (2026-09-05)

Nine defects the suites and the driver both missed, reported from the
screen. Six were the reading and not the code, one is the one race in the
replay, one is a whole screen this slice had not read at all (§6.1), and the
ninth is a global the reading had not looked for (§6.2).

* **The plate vanished in the eyes view.** §2 of [`43`](43-battle-hud.md) had
  the first-person view drawing no plate, from
  [`42` §2.4](42-mission-presentation.md)'s "the HUD hidden and redrawn".
  `fcn.0041A980` never reads the view mode; the strips are skipped only when
  `0x004604D0` returns 1, which is an `aOptions.cpp` setting. Both documents
  are corrected and the plate now stays up in every view.
* **A green digit stood over every squad member for ever.** The hit-point
  digit is gated on `+0x15` (`0x004186AF`): it marks the units that still
  have movement points and goes out as they spend them, which is why a walked
  unit kept a mark the original does not draw. The overwatch and jam marks
  are written past that jump and stay, which the fix reproduces.
* **The side of the frame striped on a portrait screen.** The vertical filler
  was a 12-row slice of the column's rim, so its pattern repeated every 12
  units of extra height. It is one row now (y 205, through a socket), which
  extrudes seamlessly; `hud_tables.py` and `test_hud.gd` both refuse a filler
  taller than one row.

* **Every step of a walk was marked on the floor** — and then, after a first
  fix moved the marks from the player to the computer, every step of an
  alien's. Both were wrong: state 100 is written by *both* movers, and the
  routine the first fix took for the computer's dispatcher is the **network**
  one. Nothing draws the mark while a body walks either. The overlay
  produces no state 100 at all now, `GroundSprites.cell_states` has no path
  argument left, and the corrected chain is pinned by seven new `path.*`
  checks in `hud_tables.py` — ten with the callback's trace
  ([`43` §3.1](43-battle-hud.md)).
* **A unit the computer was about to kill vanished as its turn opened and
  came back a second before it died.** Not a reading — a race in the replay.
  `core` decides the whole turn in one call, so the world has already lost
  every casualty when `end_turn` rebuilds the bodies; only the event that
  killed one put it back, through `UnitsView.mark_dying`. The whole list is
  held from the start of the playback now
  (`AIPlayback.pending_casualties`), and each event re-marks its own through
  the same extractor — which also found a payload the per-event code had no
  arm for at all: a **para bomb**'s payload *is* its blast, so anything it
  killed vanished at the start of the turn and never came back.
* **And the para bomb had no picture either**, which the hold turned from a
  disappearance into a body that stood to the end of the turn: the only
  caller of [method UnitsView.hide_now] is a shot's death stage, and the
  computer's `parabomb` arm was sound alone. It is a blast now, through the
  presenter the walk's mine and the jump's landing already use. The sound it
  played was wrong as well: `aAI_SpecialPlayerControl` `0x0040B2D0` calls
  `aExecuteBomb` and `aRemoveUnitElement` and **no sound routine at all**,
  so the fly-past and the crump it started belong to the script command
  `ParaBombs` `0x00470790` and not to a fuse running out. `AudioEvents`
  keeps the pair for the script and no longer claims it for the computer
  ([`23` §9](23-ai-system.md)).

* **Every unit trod one step on the spot before setting off.** The camera
  flies to the walker before the first field and the walk waits for it
  ([`42` §3.2](42-mission-presentation.md)); the remake started the `M` clip
  and its first footstep with the walk record, so both ran through the
  flight over a body that had not moved. `aExecuteMove` starts them at
  `0x0046E577`, the join every camera arm reaches, and
  [method UnitsView.start_walk] now does the same — with the footstep frames
  counted from the walk's own clock rather than from the tick that crosses
  the flight's end, which was worth a spurious step of its own
  ([`42` §3.1](42-mission-presentation.md)).

`test_hud.gd` gained the two checks that would have caught the first and the
second of these, and the digit gate was mutation-tested: removing it fails
`hud.overlay.no_digit_without_points`. `test_game_ui.gd` gained four for the
casualty hold, over all five payload shapes, and two more for the para
bomb's own event — that it is shown at all, and that its death stage is what
takes its dead off the screen.

**Both of the last two are driven**, on the cache's other missions rather
than on `_C_140` — the sixth mission of the six is what the earlier passes
were missing:

* `_C_129` replays a computer turn in which an alien **walks**, and no
  `mp[51]`/`mp[52]` is drawn on any cell at any frame of it; the player's own
  `walk_to` on `_C_140` draws none either, and the single frame that does
  appear on selection is state 50's, on the selected unit's own cell.
* `_C_132` kills a marine on its first computer turn: slot 46 reports
  `hp == 0` in the world and stands in `picture.dying` from the **first**
  frame of the replay until the stage that kills it — `shot.pool`, 84 polls
  in, where [method UnitsView.hide_now] takes it away and `dying` goes
  empty. Removing the one call that holds it puts `dying` back to `[]` on
  that first frame and fills it on the next — the defect, reproduced by
  mutation and gone with the fix.

The tread is driven as well: on `_C_140`, with the camera parked on one
marine and another one walked, the reply shows `walking` true and the body's
clip **not** playing for the first two frames, then both together; putting
the cycle start back where it was makes the clip play from the first frame
over a body that has not moved.

* **The computer's turn had no bar.** The eighth, from a shipped
  screenshot: while the aliens move, the original shows twenty-two red
  capsules across the panel and nothing else — no column icon, no pad face,
  no unit panel, no radar mark, no turn number. That screen is
  `aViewPlayer.cpp`'s, not the battle interface's: `aInitViewPlayer` loads
  `plate_5.bmp` whole and `fcn.0047D090` copies the plate's **four strips**
  back over the frame (34, 106, 340 and 340 rows, the interface's own three
  heights), and `fcn.0047DA00` lights `acted · 21 / live + 1`
  of the capsules — the fraction of that side's live units that have already
  spent movement. Read, pinned by seventeen byte checks and built:
  [`43` §7](43-battle-hud.md), `game/hud/turn_progress.gd`. Its wave
  `progress.wav` was outside the cache's closure and is now inside it, with
  the alert `alarm.wav` beside it (§8).

The bar is driven: on `_C_129`, ending turns until the aliens act, the reply
shows `hud.progress` at **1** on the first frame of the replay and 2, 3, 4 as
they move, with `hud.panel_icons`, `hud.radar_marks` and `hud.turn_text`
empty throughout and the interface back the moment the replay ends. The screenshot beside those
numbers is the plate with one lit capsule, which is the shipped frame.

The plate's own visibility is driven too, and was the third thing this pass
found a way to reach: with `key 3`, `key 2` and `key 1` walking the camera
through the map, unit and first-person views, every reply carries
`hud.visible` true with the panel's twenty icons and the radar's marks still
drawn. Nothing of §6 is left checked by reading alone.

## 6.1 The two things §7 first left open, closed the same day

**The bar now ticks.** The conversion's wave closure was the `aAnimations.cpp`
call sites plus the id-96 interface set, and `aViewPlayer.cpp` is the one
place outside both that names a wave — so the whole computer turn was silent.
`sound.VIEW_PLAYER_CUES` carries both of the screen's waves, `wanted_waves`
copies them, `tables/sound.json` gained a `view_player` block, and
`CONVERTER_VERSION` went **0.17.0 → 0.18.0** in `tools/inclib/cache.py` and
`godot/game/cache_loader.gd` with `user://caches` republished
(`--campaign-maps`, all 92). Neither wave is scaled by the volume table: the
original plays them with `aDirectSoundPlay(handle, 0)`, so both are
`NO_SCALING`. `TurnProgress.refresh` answers whether the fill moved —
`0x0047DA5F`'s own compare — `MissionHud.progress_stepped` carries it up and
`Main._play_progress` plays it; the interface still makes no sound of its own.

**And the screen the bar sits on was read.** It is not an overlay on the
battle interface but a **whole game state**: `fcn.0044AAE0` runs it as one
arm and `fcn.0047D600` hands it to `aAISystemControl` as the per-frame
callback. Seven arms on `[0x005229D4]`, two text banks (`txtmod_g`, whose
header names it `_ViewPlayers`, and `aMain`'s shared `txtmod_h`), twenty
string fetches over eighteen sites. **The computer's turn is state 2 and its arm holds no
`aPrintLibText` call at all** — every caption the function carries belongs to
the hand-over, the end of the game or the network game, which the arm states
2, 3 and 4 share leaves at once unless the mode is 2. So the remake printing
nothing there is now measured rather than assumed. `alarm.wav` is the network
"it is your turn" alert, gated on the game mode `[0x00509EE8]` being 2 and the
turn counter being non-zero; it is copied and played by nothing. Two things
this pass got wrong on the first reading and the byte checks caught: state 1
is written at `0x0047DE3C`, not by the init, and **"Scay'Ger (Computer)" is a
multi-player caption** — mode 1 takes its own arm at `0x0047C549`, leaves the
player line empty and posts `WM_LBUTTONDOWN` to dismiss its own pause, which
is why the shipped game shows no hand-over screen when it is played alone.
Twenty-four new byte checks in `hud_tables.py`, one of which reads the eleven
captions back out of the shipped banks so the ids cannot mean whatever a
document says they mean. [`43` §7.3](43-battle-hud.md); docs/43's open questions are
now **none**, and the set is at **32**.

## 6.2 The ninth: the turn came back with nobody selected (2026-09-05)

Reported from play: *in the original, when the computer's turn ends one of my
soldiers is selected; here it is done by hand.* The reading is
[`43` §4.5](43-battle-hud.md) and there is no hand-over routine in it — the
selected slot is a global `[0x005162F0]` that **five** instructions in the
whole image write, none of them on the turn's path, so the marine the player
last had simply survives the computer's turn. The other half is
`fcn.004721F0`'s first branch, which refills an empty selection from
`fcn.00477CE0` before it even reads its mode: two passes over the unit array,
the second dropping the movement test the first makes, which is why the
original still has somebody selected at the end of a turn on which everything
has moved.

The remake drops the selection for the length of the replay — the watched
screen has nothing to draw it on — and `SliceMain.resumed_slot` puts it back
at both hand-back points: the same unit when the computer left it alive and
able to move, and `SliceMain.first_friendly_slot` otherwise. It moves no
camera, because the engine's hand-over calls none.

Two things the first reading of this got wrong and the checks corrected:
`0x00472CFB` **clears** the selection rather than setting one — it is
`fcn.00472CC0`, the tail every player command runs, so three sites clear it
and two set it — and `aInitBattleGround` is not the only caller that asks for
a selection without a click: the `SelectNextUnit` script command is the other,
and no shipped `.lcl` uses it. The count is a check of its own now: exactly
seven instructions in `.text` name `0x005162F0`, which is what "the hand-over
does not touch it" actually rests on.

Fourteen new byte checks in `hud_tables.py` (four mutations bite), three in
`test_hud.gd` against the fixture and fourteen in `test_game_ui.gd` over a
real `_C_140` — including the two branches a drive cannot stage, the previous
marine dead and the previous marine spent, and the second pass, driven by
zeroing every marine's movement and requiring the answer to be a unit a click
could **not** select.

A second report the same day — *"in the original a unit is selected **and the
camera centres on it**, both at level start and after the computer's turn"* —
sent this back to the binary and found two more things. **The engine's select
camera is traced after all**: every caller that gets a `1` back from
`fcn.00471E00` calls `fcn.004533D0`, which re-applies the current view mode on
the cell the select just wrote, and mode 2 — the one a mission opens in — is
`fcn.004529D0(x, y, 8, 7, 0)`, the placement [`42` §2.3] had recorded for the
cycle alone. So a selection moving the camera is the engine's behaviour, not a
remake decision, and the hand-back now does it; [`42` §2.6] and
[`97` §28.3](97-slice-5-report.md) are corrected in place. And **a mission
opens with a unit selected**: `aInitBattleGround` `0x0041A738` asks for one and
`0x0041A74D` puts the camera on it with `fcn.004510A0`. Which of that routine's
two arms a *fresh* mission takes is the one thing here taken from the report
rather than read — the state machine suggests the counter is still 0 at that
point — and it is marked **UNVERIFIED** in [`43` §4.5](43-battle-hud.md) with
the paragraph to correct if it turns out otherwise.

Driven on `_C_140` with the replay gated rather than waited out: at load,
`selected 2` with the camera target on its own cell (18, 1); marine 5 picked
by hand; `replay True` with `selected -1` while the computer moved; and
**`selected 5`** with the camera back on cell (17, 0) when it handed back.

## 7. What is left

Known and not done, so that it is not forgotten:

* **The far view is pinned, not played.** The `map.LIB` flags switch in
  above camera height `0x17700`; the remake's zoom is clamped to the
  mission's authored `camera_height` (19 200..64 000 in the cache), so only
  `test_hud.gd` reaches them ([`43` §3.3](43-battle-hud.md)).
* **The turn reads `0` during the first player turn.** The remake's counter
  is the engine's `g_turn`, zeroed at start and stepped by the hand-over
  ([`25` §4](25-turn-and-round.md)); the plate prints the same byte
  (`0x0043B280` cached at `[0x004FE388]` by the redraw, [`43`
  §2](43-battle-hud.md)), so the original's groove reads `0` too until the
  first hand-over. It is now visible where the text line did not draw
  attention to it.
* **`_may_command_now` tests the current player against the one computer id**
(255) rather than asking whether the seat is human. `TurnState` can describe
more than one human seat (`human_count`), but nothing in the remake creates a
second one, so the test is sufficient today; a multi-seat session would let
one seat end another's turn. It predates this slice.
* **Classic keyboard bindings — closed 2026-09-11.** `hud_tables.py` now
  interprets both keyboard switches and the Windows message translators. The
  remake uses the resulting original keys, including `G` for the magnifier;
  only original `Esc` → *Give up* remains a declared divergence because
  `Esc` opens the menu.
* **The two panel fonts (D7) and the block offsets were checked by reading,
  not by eye** — the Wine screenshot could not be taken (§3).
* **The magnifier's page (D4) and the campaign map's band rings (D6)** are
  decisions with the reading named, not implementations.
* Nothing from §6 is left; the para bomb's own residue was closed the same
  day (§6's last bullet).


---

## 8. The mission's own sound *(2026-09-05)*

Reported as "the level has no sound: units speak when they are picked, clicks
on the action points and on the turn are voiced". Both halves were real and
both were **missing rather than wrong** — nothing in the remake had ever
reached them.

**The clicks.** [`28` §2.5](28-effects-and-sound.md) is new: four of the five
id-96 waves belong to the mission interface, and no widget names one. They are
loaded once by `aInitBattleGround` and handed to `aUI.cpp` and `aMI.cpp` as
handles, so a play site names a **global** and the wave is two hops away. Ten
sites, read out of the bytes at each site's own `mov`. The finding worth
carrying: **`select.wav` is the camera's, not the click's** — it is played from
inside the two view placers, which `fcn.004533D0` runs after every successful
select, so the noise a player hears when they pick a marine belongs to the view
being re-applied. The remake plays it from `select_unit` for that reason and
not from `_pick`.

**The voices.** [`28` §4.2.1](28-effects-and-sound.md) reads `fcn.0047B660`
whole: a ten-case category switch, four cursors (two of which are **shared**,
so arguments 2 and 7 interleave), three drawing arms on `aRandom2` — the
presentation generator, never the simulation's — a twelve-case set switch, and
`0x0047BB6E`, which asks the filesystem whether the name exists. **A miss is
silence**, and it is not an edge case: `MANO` ships four indices where the arm
draws six, so a fit marine says nothing to two selections in six. Sixteen call
sites in four groups; the selection's argument depends on the marine's own hit
points and fitness. Two whole shipped categories, about fifty files, are
unreachable — no arm prints `06` at all, and `07` is printed only by an
argument nothing pushes.

**The cache grew.** The 233 speech files are in the closure since
`CONVERTER_VERSION` 0.19.0, copied whole rather than by reachable name because
the original builds a name and asks the directory. 5.4 MiB; the two size
ceilings in `remake_convert.py` were raised with the reason recorded.

Not done, and deliberate:

* **`hover_button` is pinned and not played.** The button columns have no
  hover state in the remake, so the second of the two `click_1` ticks has
  nowhere to come from. `hover_cell` is played, gated the way the original
  gates it — only while a command is armed, which is exactly the window the
  ring is up in.
* **`map_click`, `compass` and `view_map` are pinned and not played.** They
  belong to `aMI.cpp`'s map interface, which the seventh slice draws as a
  radar and not as a clickable map.
* **Speech rides the FX volume.** The original scales it by the options
  record's own speech field ([`20` §8](20-lcl-language.md)) and by nothing
  else. The options screen still has no speech row, which [`92`
  §7.1](92-remake-architecture.md) permits — that rule is about controls that
  do nothing, not about settings that have no control.

## 9. What a second play found (2026-09-06)

Five things reported from the screen. Two are the original's own behaviour and
one of those is a rule the remake had never carried; two are the remake's, and
one is a gap.

* **A shot at an adjacent target hung for five seconds.** The muzzle stage
  waits up to [constant `ShotSequence.WAIT_FRAMES`] frames — a hundred, five
  seconds at the sequence's twenty a second — for the *arrived* flag
  ([`42` §4.6](42-mission-presentation.md)), and the remake raised it early
  only when the muzzle made **nothing**. That is not the engine's test. All
  three burst creators open with `cmp steps, 0 / jle` and the point-blank arm
  writes the flag's **1** *before* it goes on to fill the pool with zoom bobs
  and sparks at the target (`0x0042420D`, `0x0042456A`, `0x00424AC3`, against
  the flight's zero at `0x0042407B`, `0x0042455E`, `0x00424AB9`); twelve
  creators carry that shape, which `presentation_tables.py`'s
  `arrived.creator_writes` has counted all along. `BlobTriggers` now reports
  the write and `ShotHost.muzzle` applies it, so a stab lands in its own
  frame. The `made == 0` fallback stays for the remake's own refusals — a
  creator the constructor table cannot build is not a creator that decided
  nothing was in flight.
* **A marine next to an alien fired, and could miss.** The original stabs:
  weapon `special` 1 swaps the gun for its bayonet for the length of the shot
  and back again afterwards, which is why the stab has a flat chance and
  spends no ammunition. The rule was read off `0x0046F7E0` and is written up
  in [`21` §6](21-info-lcl-schema.md) with a new step 0 in
  [`22` §7.1](22-combat-and-visibility.md); `Combat.close_combat_swap` and
  `close_combat_revert` are the model, `combat_tables.py`'s eleven `close.*`
  checks are the binary's, and `test_combat.gd`'s are the model's. Two things
  in it are easy to get backwards and both are pinned: the revert runs
  **after** the ammunition subtraction, which is the whole of "a stab is
  free", and a **reaction reaches neither arm** — a unit on overwatch shoots
  whatever walks up to it.
* **A cloaked alien walking into view stayed a beam until the turn ended.**
  Mostly faithful: the fog pass runs on the hand-over and not in between
  ([`22` §9.4](22-combat-and-visibility.md)), so an alien that comes out of an
  unseen cell is a contact for the whole of its walk in the original too. The
  remake's own half was `aExecuteMove`'s **mode 3** (`0x0046E4BB`): a computer
  mover that can see somebody from the cell it starts on marks *itself*
  visible **before the first step**, and the replay's visibility hold was
  overriding that with the pre-turn answer for the length of the event. The
  hold now forces [constant `Visibility.FULL`] for a mover whose event carries
  `seen_source`, rather than releasing the slot — releasing would hand it the
  **end** of the turn, and a walker that shows itself and then leaves the room
  ends the turn hidden. **The same mechanism has a second arm**, and the same
  hold was hiding it: `aAttackUnit` marks the shooter visible at `0x0046B643`
  the moment its weapon is cleared to fire
  ([`22` §7.1](22-combat-and-visibility.md)), so an alien that walks up
  under cover and then attacks was a beam swinging its claws — and, being a
  beam, a shot with no body for the fight clip to play on.
  `SliceMain._event_reveals_its_actor` carries both writes and nothing else;
  a jammed shot reveals nobody, which is why the test is the attack's own
  `fired`.
* **Overwatch spends nothing, and that is the original.** `0x00478500` stamps
  `+0x41` and `+0x39`, hands out a ticket and charges no points; only a
  *second* press zeroes what movement is left ([`25` §6](25-turn-and-round.md)).
  No change.
* **And the bayonet broke a suite, which is the finding under the finding.**
  `test_mission.gd` plays `_C_140` twice with a scripted player, and its
  `_fight` fired while the unit had any movement point left. That terminated
  only because the magazine ran out -- so the squad shot for two turns, went
  dry and then walked. A free close-range weapon removes that stop, and the
  held-fire run spent all 200 rounds stabbing the reinforcement queue and
  never reached the evacuation zone. The policy now keeps the one point back
  that the caller's own comment has always said it does
  ([constant `MOVE_RESERVE`]); the magazine had been doing the reserve's job
  by accident. Diagnosed by A/B, twice -- and the first A/B was wrong, because
  a Godot run started without `--import` reads the *previous* import of an
  edited script and reported the change as innocent. Run the import step
  before every one-off run.
  **The first policy that fixed it cost coverage, and the second does not.**
  A flat one-point reserve in `_fight` bought the walk back and ended the live
  run around round 5, before `_C_140` inserts anything, so its mid-mission
  save had nothing to carry. Four policies were measured against the same two
  runs, and the one in the suite is *fight the opening, walk after it*: up to
  and including the first insertion turn a squad member spends everything on
  what is in front of it, and from the turn after that it takes its step first
  and prefers a cell the fill's own `mp_left` says still pays for a round.
  The held-fire run wins, the live run lives to turn 6, and both take a
  mid-mission save -- so the `or ended` escape that had made
  `save_taken_mid_mission` unfalsifiable is gone. The other three are recorded
  with their numbers in `_step`'s own comment. The suite is **4128 checks**
  against 4050 before this pass.
* **Opening a supply box says nothing. Fixed.** The arm hands two characters
  to `0x00410780`, which draws `DATA/TXT/<lang>/Info/Events.txt` through
  `aActivateInfo` and plays `box.wav` ([`26` §3](26-interaction.md)); the
  remake played the sound and showed no box. It is a cache-schema change, so
  it was asked about first: `inclib.convert.convert_info_events` now writes
  `text/info/events.json` as spans, `CONVERTER_VERSION` is 0.23.0 in both
  places, `InfoText` **reads** the action-point-to-label map out of the same
  document -- `InteractionTables.cases()`'s own decoding of the switch, so
  neither side transcribes it and `remake_convert --check` compares the
  baking with docs/26 §3 pair by pair -- and `MissionHud`
  draws the box at [`24` §7.2](24-briefing-text.md)'s own `230, 200, 180, 400`
  with the original's own hold on the mission input. **The hold is two
  halves.** The keyboard's is `SliceMain._unhandled_input`; the mouse's cannot
  be, because a Godot `Control` answers a click before `_unhandled_input` sees
  it and the plate's own buttons would have gone on working behind the
  message. `0x0041B6E0` is explicit about this: its keyboard shortcut lookup
  `0x00450D50` is called at `0x0041BA96`, *before* the flag test at
  `0x0041BB44`, and the interface's own **mouse** hit test `0x00450F10` at
  `0x0041BB5F`, *after* it -- so a click on a button does nothing while a box
  is up. `MissionHud._info_shield` is that: a full-rect `Control` with
  `MOUSE_FILTER_STOP`, added last so it picks in front of every widget, and it
  is also what takes the message down. The original dismisses on the right
  button alone (cases `0x204`/`0x206` -> `0x0043F130`); this answers any of
  them, which takes nothing away because the left click the original swallows
  here does nothing at all. Two neighbours went with it: the two `message_only` arms were
  silent where the original clicks, and the voice line was played for every
  successful use rather than for the twelve arms that have one.
* **A reaction shot did not reveal its shooter in the replay.** The `reactions`
  event is emitted for the unit that *drew* the fire, so the visibility hold
  was keyed on the mover and the overwatch shooters kept their pre-turn
  answer -- a hidden alien that answered the squad's own walk stayed a contact
  beam. `SliceMain._event_reveals` now returns the slots an event revealed
  rather than a flag, and a `reactions` event names every reactor whose attack
  `fired`; a jam reveals nobody. `core` already made the write
  (`Reaction.drain` fires through `Combat.attack`, `0x0046B643`), so this was
  presentation only.

## 10. The doors were never drawn (2026-09-06)

Reported from play: every doorway an empty frame, the hand cursor still
answering on it, the door "opening" with a cut-off hum and the camera tipped
up. Three things, one root and one wrong model.

* **The root.** `Scenery._place` built each prototype's **root scope** alone.
  `L100EX00.3DI` — the door of 45 missions, and `L108EX00`/`L111EX00` with it —
  has no root geometry: all sixteen vertices belong to its two parts, so the
  mesh had no surfaces, the object was never registered, and
  `test_effects`'s door check passed on the lattice marker standing on the
  same cell. Six more part-carrying prototypes lost their parts the same way
  (`L045EA00`, `L101EX00`, `L109EX00`, `L115EX00`, `L004ED00`, `L068EE00`, …).
  `MeshBuilder.assemble` is the body-plus-pivots tree `BlobModels` already
  built, now shared; `built_count` on `_C_140` equals clones + specials +
  lattice, which `test_render` could not see on `_C_115`.
* **The model.** [`26` §3.4](26-interaction.md) and [`97` §7](97-slice-5-report.md)
  had the panel *rising out of the floor* by `0xC80`. The listing says the
  `z` written is the object the cell's `+0x05` names — its land-lattice slot,
  the marker whose z is the cell height — and the ten frames add ±100 to the
  panel's `+0x2A` and `+0x30`, the z angles of joints 6 and 12. The leaves
  swing 88° about the hinges at the frame's outer edges. The corpus agrees
  302/302 (`interaction_tables.py`, five new `door.*`/`corpus.door_*`
  checks), and the remake now poses the leaves from the cell's parity, paints
  the swing over the ten frames, and moves only the marker with the height.
* **The camera.** The flight's target stood at the *cell's* height — 3200 on
  a closed door — where `0x00410C10` reads the **panel's** z (`[esi+0x18]`,
  twice) for both ends. `extra["object"]` is the panel's authored position.
* **The cache.** The special objects' joint words are authored data — 28
  non-door records pose a part too — so `map.json` carries `joints` and
  `CONVERTER_VERSION` is 0.24.0 in both places.

Not settled: the hum. `door.wav` is 0.68 s, looped and killed on the tenth
tick as the listing has it, so 0.5 s of it plays and stops — in both. One
measurable difference remains: the engine starts the flight, then the wave,
then ticks the ten frames, so the leaves turn *while* the camera is still on
its way; the remake waits for the flight first, and its ten frames and hum
come after. Named, not changed.

### 10.1 The door was one of a family (2026-09-06)

Asked whether anything else on the levels was drawn wrong the way the door
was, the answer came from one sweep rather than from a list: every word
write at `+0x20..+0x30` of a register in `Incubation.exe` — 149 sites —
sorted by function. Nine more routines turn the object beside the cell's
marker, all through the door's own `aGetSymbolObjectPtr` / `0x00406F20` pair,
and the remake drew none of them: the supply box's lid, the lever's handle,
the three tubes' hatches, the bridge's halves, the barrier's emitter, and
the crush wall's and the footbridge's own fall before `aDeleteLand`. They are
in [`42` §8.3](42-mission-presentation.md) with their sites, steps and frame
counts, pinned by `interaction_tables.py` (`family.*`, 155 checks now) with
three corpus rules beside the door's — the lever's 69 records, the barrier's
13 seeded emitters, the three bridges. What was clean: no object carries a
pitch or a roll, no placed prototype is empty, and the draw kinds on the
levels are all handled.

The remake's side is one generalisation of the door: `Scenery.paint_joint`
and `paint_pose`, absolute and computed from the authored transform every
frame, `remove_objects` for the two that are freed, the lever's pose
derived from its action point as the door's is from its parity, and two new
set pieces — `lever` and `pickup` — carrying the flights `docs/42`'s table
always listed for them and never had. `test_effects` checks the lever, a box
and a tube on `_C_140` and the crush wall on `_C_129`, and the three camera
arms on the recording double.

Four things that pass left open in the morning were closed the same
evening, and three of the four turned on replaying `0x00406F20`'s search on
the shipped maps instead of reading the routine. The rotating statue's
find is `L014EH00` with one part, not the partless `L012EH00` — the survey
had checked `FixedStatue`'s cells, whose routine writes no word, and the
rotating one is reached only by `Statue2 (110,112)` on `_C_178`; the remake
turns it now, thirteen frames of `+0x50` then the start plus `0x400`
([`42` §8.3](42-mission-presentation.md)). `FootBridge2`'s block is the
`L069EI00` on one of the group's two cells, so the interpreter — both twins
— puts the matched cells on the event before it clears the byte, and the
same replay found `FootBridge2 (139,30,12)` naming a tag no cell carries
([`20` §8.5](20-lcl-language.md)). Both footbridges' riders are killed by
`core`, as `aRemoveUnitElement` kills them, with their slots on the event
and their fall in the picture (`test_lcl` and `lcl_runtime.py` carry the
`foot_bridge.*` twins, 67 checks now). And the scenery's poses travel with
the save: `Scenery.pose_record` beside the camera in the mission blob,
schema 11, restored after the load's redraw — which also gave the two load
paths the redraw they never had, so a resumed mission shows its raised and
opened cells before the first command rather than after it.

Five loose ends of that evening were closed the next day, and two of them
were corrections rather than additions. The riders **tumble** now, `+0x24`
by 25 a frame and `+0x22` by 12 with the sign from the rider's index, drawn
through one generalisation of the body's own facing rule
(`UnitsView.tumble`, `WorldSpace.charisma_offset`) — and reading that loop
closely enough to draw it found the drop itself wrong: it re-reads the
rider's object every frame and writes it back 160 above the `0xC80` it
subtracted, so the fall is `0xBE0`, not the map field the site alone says
([`42` §8.1](42-mission-presentation.md)). The **camera** now goes into the
save and comes back out of it, a field that had been write-only since the
first save. What a save cannot hold is a fall it is in the middle of, and
the answer is not to serialise it: the original's sequences run inside the
command and reach no input at all, so a save is refused while the queue is
running and the turn's autosave waits for it. `_resume_loaded_mission` has
a suite of its own at last (`test_effects.gd`, `resume.*`) — a real slot
file written and read back with poses, camera and refusal in it. And the
46 checks added since the last mutation battery have been through one:
one mutation per check, all 46 detected ([`26` §9](26-interaction.md)).

**Driving the real build found the one thing no suite had**
(2026-09-07). `_C_129` was played to turn 1 through the control server and
the load seam checked from outside: the camera comes back where the save
holds it, and a save taken *after* a load carries the same two hatch rows
as the one taken before it, which is `pose_record` reading the scene. The
refusal was caught the same way -- `screen save` answers `true` with the
queue idle and `false` with the tube's sequence on it. What the run
exposed is a defect of its own: **only the autosave recorded what it
wrote.** `_slot_holds_this_mission` reads a slot's header once and
remembers it, and the interface asks every frame, so a slot cached before
`F1` wrote it stayed cached as whatever was on disk -- *Recall position*
was dark on a slot the player had just written, and *Undo mission* would
have offered a mission they were not in. The bookkeeping moved into
`_save_mission_to`, where every writer passes, and `resume.*` pins it --
with the cache **poisoned first**, because a check that lets it miss reads
the header the save is about to write and passes either way.

A code review of the whole change found the one thing neither the suites nor
the driven build had: **all of this is written per cell, and the engine
writes per object.** A `.3DW` scene clone is in no table `0x00406F20` reads
and the converter places the clones first, so `Scenery.objects_on` answered
with the level's own geometry wherever the two share a field -- the door's
flight aimed at a clone on `_C_142`, and on `_C_163` the second footbridge
tilted, dropped and then **deleted** one, into the save's `removed` list
where every load would delete it again. Clones are indexed and excluded
now; `clones.*` pins it on the fixture's own shared field and fails without
the exclusion; and the residue is measured rather than argued -- each of the
400 cells the family reaches, by a call's coordinates or by its own action
point, carries exactly one special object, so per cell is per object on the
shipped maps
([`26` §9](26-interaction.md), `corpus.setpiece_cells_carry_one_object`).
The review's fourth finding was latent and is fixed with it: `build()` did
not clear `_authored_joints` or `_removed_cells`, which is harmless only
while every mission gets a fresh `Scenery`.

The same run settled the deferral: the turn-1 autosave (*Undo last turn*)
is written four seconds after the hand-over that queued the two `OpenTube`
sequences, and the record inside it carries both hatches at 969 -- so the
save was taken after the queue drained rather than in the middle of it, and
the turn did not go unsaved for having a set piece at its start.

### 10.2 What playing the footbridge found (2026-09-07)

The five items left open after the review were closed by pinning three and
playing two, and playing them found a defect neither the suites nor the
earlier driven runs could reach.

**The two witnesses are pinned in the corpus.** `_C_142` and `_C_163` are
not in the six-mission development set and adding them would have been a
fixture for one case; the scenes themselves answer instead.
`interaction_tables.py` reads each mission's `.3DW` through
`inclib.convert.parse_3dw_clones` -- split out of the converter's own
reader so that a check does not have to invent a `SourceReader` -- and
`corpus.family_cells_share_fields_with_clones` counts **eleven** family
cells over **nine** missions where the level's geometry stands on the same
field as the object `0x00406F20` finds, with
`corpus.the_clone_is_not_where_the_object_is` pinning the two by prototype
and height (`_C_142` (14,14) `LEVEL01D.004` at z 0; `_C_163` (19,16)
`LEVEL09C.002` at z **-13 760**). Both are mutation-killed by a rewritten
`POSITION` line in a copy of the scene -- one that moves a clone off its
cell, one that changes only its height.

**The fixture guard stopped being the test.**
`clones.fixture_has_a_shared_cell` asked whether `instances_on` held more
than `objects_on` plus the marker, which is the same question as the checks
after it: reverting the exclusion made the *guard* fail first and took the
rest out of the run with an early return, so the mutation that proves the
mechanism reported a missing fixture. `Scenery.clones_on(cell)` now answers
from the index `build()` fills and no later call touches, and the guard is
"a clone here, and an instance of the wall's prototype here". Reverting the
exclusion now fails seven checks by name and the guard passes.

**The snapshot answers a number that moves.** `picture.scenery` is
`built_count()` and is constant for a mission; `scenery_objects` and
`scenery_removed` are new beside it ([`92` §7.16](92-remake-architecture.md)),
and they are what made both live runs below readable from outside.

**The `MoveUnit` hook was simulated and never presented.** `_C_107` is the
one shipped map that can be reached in a minute with a footbridge under a
squad: the hook is unconditional, the fourth `FootBridge` argument is a
rider threshold of 1, and its five deployment cells are on the walkway the
bridge is in. Entered through chain 1 with two marines deployed and walked
onto (16,18) and (15,18), the bridge killed them, turned its nine cells into
deep holes -- and drew nothing. `core` had handed the outcome back on
`MoveResult.script_result` since the second slice and **`game` read that
field nowhere**; `_C_129`'s own `MoveUnit` section is empty, so no fixture
had asked. `move_selected` and `warp_selected` present it now, behind the
hold the mine and the teleporter already used. The same play then reads 37
objects / 0 removed before and **36 / 1** after, runs `move.after_walk`,
`setpiece.flight`, `foot_bridge`, `setpiece.back` with both riders held past
their death, and the save carries `removed: [736]`. This is a behaviour
change beyond the five items, in the same class as the agent `save` verb
last round, and is named here for that reason.

**What is pinned by what.** `test_effects.gd`'s `move_script.*` builds a
one-command program (`FootBridge (2, 3, 30, 0)`, threshold zero so the mover
is its own rider), attaches it to `TestFixtures.tiny_world()`, walks unit 0
in and checks both halves of the seam: `core` emits the event with the mover
on it and kills it, and `_present_script` puts the fall on the queue and
holds the body. **No suite calls `move_selected` or `warp_selected`**, so
the one line that was missing is pinned by the live run alone, and
`warp_selected`'s half has not been seen live at all.

**The crush wall's removal, live.** `_C_129` entered through the campaign
with two marines deployed and three turns ended: the three `CrushWall`
calls fire on turn 3, each behind its own `script.camera` flight, and the
snapshot steps 113 -> 112 -> 111 -> 110 objects against 0 -> 1 -> 2 -> 3
removed. The save carries `"scenery": {"joints": [[642, 6, 969, 0, 0],
[680, 6, 969, 0, 0]], "removed": [556, 616, 708]}` -- the two open hatches
and the three crushed cells -- and a quick load rebuilds the scene to its
full 1040 and replays the record back to 110 objects and 3 removed, with all
three cells *Free Place*. The earlier attempt failed because the squad died
before turn 3; walking it away from the tubes is all it took.

**The riders were never drawn falling, and the first reading of that was
wrong.** The bodies could not be caught mid-fall at any sampling rate, and
this report first put that down to the drop -- `0xBE0` a set-piece frame is
0.95 of a map field at 20 fps. A review pass said otherwise and a second live
run settled it: a screenshot taken the instant the walk returned, with the
bridge still level and the camera still where it was, shows **both marines
already gone**. `_after_command` runs `UnitsView.build`, which frees every
unit node and will not redraw an `hp == 0` record that nothing is holding;
the riders die inside `submit_move` with only their slots on the event, and
`AIPlayback.casualties_of` reads markers, so it holds nobody. The mover is a
rider too, so its walk went with it -- it vanished at its start cell.
`_mark_dying_by_script` now runs beside `_mark_dying_by_mine`, **before**
`_after_command`, on both call sites. The false lead was the map's own
aliens: two of them stand on the same walkway three cells further along, so
every screenshot of the bridge has two armoured bodies on it whether the
riders are there or not.

With the hold in place the fall was then watched: a single batch that orders
the walk and then shoots every drawn frame catches both marines tipped over
on the dropping deck, leaning opposite ways -- the ±25/±12 by index, drawn.
Polling `/state` for the stage and *then* posting the shots is too slow to
see it; the walk and the shots have to be one batch.

`move_script.the_riders_are_held` and `move_script.the_held_rider_is_the_mover`
pin the hold, and `move_script.the_living_are_drawn` /
`.the_dead_are_dropped` / `.the_held_dead_are_drawn` pin the rebuild rule the
ordering depends on, on the fixture's own world and geometry. The ordering
itself -- that the hold happens before `_after_command` -- is still only
pinned by playing it.

**Still open after this pass** -- and closed in §10.3 the same day. The
computer's own `MoveUnit` hook: `AISystem.run` does not go through
`World.submit_move`, so whether `core` runs `aRunLCL` for a computer move at
all is unverified -- and `_C_106`'s aliens can walk onto its six bridges.
`warp_selected`'s script presentation is wired and unplayed. And
`_present_script` answers nothing at all without an audio system and an
event table, which is a coupling the picture does not need; it is
pre-existing, it was met while writing the suite, and it is left as an
observation rather than changed under this pass.

### 10.3 The computer's hook, the jump, the sound gate -- and a platform that never moved (2026-09-07)

Three items from §10.2's closing paragraph, closed, and one defect the
player saw while they were being closed.

**The computer's `MoveUnit` was never fired.** The engine answer came first
and is unambiguous: `aRunLCL` `0x0046EEFD` is inside `aExecuteMove`, after
the alive gate `0x0046EDDC`, the teleporter, the closing visibility pass and
the six environment writes, with no test of the player anywhere between;
`aExecuteWarp`'s tail is the same shape ending at `0x0046F1D6`; and the
planner's `0x0040A750` tail calls those routines. So in the original every
computer walk and jump runs the mission's `MoveUnit`, and on `_C_106` that
is six `FootBridge` calls under alien traffic. In the remake `AISystem.run`
never went through `World.submit_move`, and `AIPlan` called
`ExecuteMove.execute` with no script in reach -- so `core` fired the hook
for the player and **never** for the computer. `AIContext` now carries the
script (`mission_script`; `script` is `Object`'s own property, which the
first draft found out from the parser), `World.submit_end_turn` hands it
over, and `AIPlan._run_move_hook` fires it where the routine does -- after
`ExecuteMove.execute`, behind `is_alive()`, before the event is emitted and
before the caller's charge and `Reaction.drain` -- through the same
`MissionScript.env` the player's path builds. The jump's arm runs it after
the fog rebuild `0x0046F144`, as the engine does, and both put the outcome
on the event under `script`. `inclib/ai.py` is frozen and does not fire it,
so the `cases_ai.json` replay builds its context with no script and is
byte-for-byte what it was (`ai_script.no_script_no_key` pins the payload
shape); the seam is pinned by driving `AIPlan.commit` and
`AIPlan.execute_warp` directly on the fixture world with the `FootBridge`
program attached (`ai_script.*`, nine checks), because a whole `AISystem.run`
may never choose the bridge cell.

The replay's half: `AIPlayback.casualties_of` gained the fifth shape a death
comes in -- the riders under `payload.script` -- so the hold taken once
before the first frame covers a script kill the way it covers a shot's;
`_mark_dying_by_script` on the player's path reads them through the same
`script_riders_of`, so the two paths cannot disagree about who fell.
`_play_event_body` presents the outcome after the walk (and after the jump),
holds the walk for it as it does for a mine, and keeps the event on screen
for the set piece's frames (`_script_seconds`). Watched on `_C_131` -- the
one shipped map whose `MoveUnit` does anything under a warping unit --
through a new snapshot field, `picture.script` (`ran`, the event names and a
running `count` of outcomes presented): the player's jet-pack jump raised it
by one with `events: []`, and the replay of the first alien turn raised it
by one per computer walk shown, with the note naming each mover.

**`warp_selected`.** The corpus has no stage for it: the jet pack is a
tech-4 item in a campaign whose tech level is 1 throughout ([`27` §5.2](27-campaign.md)),
the two footbridge maps place no warping unit, `_C_163`'s `FootBridge2` is
turn-gated, and the one shipped pairing of a jet pack with a live `MoveUnit`
is `_C_131`, whose hook reorders aliens and draws nothing. So the picture's
half is pinned on a fixture instead, end to end -- a one-point marine with
the pack jumping three fields onto the bridge cell, past its walk and inside
the pack's five (`warp_script.*`, nine checks) -- and the hook's firing on a
real jump is what `_C_131` showed above.

**`_present_script` without a sound layer.** It now gates only on an empty
outcome: the cues are `[]` when there is no event table and the one bare
`play_cues` is guarded, so the set pieces queue whether or not anything can
name their sounds. `warp_script.the_fall_is_on_the_queue_without_sound` is
the run with `_audio` and `_events` both null, and `move_script.the_events_reach_the_picture`
-- which was `shown >= 0` -- now compares the cue count with the table's own.

**The platform never moved.** While `_C_106` was being played for its
bridges the player saw a unit hanging in the air, and the screenshots agree:
after the first turn's `Platform (19,2,2,11)` the three marines stand in
mid-air over the destination's hole with the deck still docked at the ledge
eleven fields north. `aPlayPlatformSequence`'s loop adds `0x140` a frame to
every object it finds on the block (the marker through `aGetSymbolObjectPtr`
`0x00412BA7`, the special object through `0x00406F20` `0x00412BF7`), to
every rider and to the camera target ([`20` §7.4](20-lcl-language.md) step 2);
the remake ran the flight, the dust and the sound and translated nothing,
and `core` had relocated the riders the instant the command ran. Now
`Scenery.shift_objects` draws the block's objects a frame's travel on and
`Scenery.move_objects` re-keys them under the destination cells at the end
-- with each object's authored transform set so the destination cell's own
height delta lands it where the ride left it, which `platform.the_terrain_diff_leaves_it_there`
pins -- `UnitsView.shift` carries the riders across (a horizontal `lift`,
re-applied after a rebuild and dropped at the end), and `SetpieceCamera`'s
target travels with the deck. The riders are held at the source from the
moment the sequence is queued, not from its first painted frame, because the
camera's flight runs first. Watched on `_C_106`: the marines ride the deck
south and step off onto the hex platform where the state has them. Eighteen
checks under `platform.*`, on `_C_129`'s geometry; `_C_106` is not in the
dev fixtures.

**What playing `_C_106` did not show.** In three runs of four turns each the
aliens never put two units on one bridge block: the two Gore'Thers walk
north along `x = 28` two fields a turn, and the squad on the platform is
dead by turn 4. "Not observed", not "does not happen" -- the hook itself is
proven on `_C_131` and on the fixture.

**The save carries the ride** (closed the same day). A save taken after a
platform ride reloaded the deck at its authored place: `Scenery.build`
reads the map document, and `pose_record` carried joints and removals but
not moves. The original's `.sav` embeds the special-object records with
their positions ([`11`](11-save-game-format.md)); the remake's record now
has a third list, `moves`, one `[home, dx, dy]` row per cell whose objects a
ride carried away, in fields -- per cell and not per object, since a ride
moves the deck and the cell's marker together. `restore_poses` replays the
moves **first**, because the joint rows and the removed cells name where
things stand now, and takes the terrain snapshot so the moved object's
authored transform absorbs the destination's height delta; a second restore
finds the home cell empty and carries nothing, so twice is once.
`platform.the_record_carries_the_move` and its six neighbours pin it on
`_C_129`'s geometry, `scenery.restored.moves` pins the codec's round trip.

**Left open.** The control-map copy of `0x00413049`..`0x0041306C` moves `+0x0E`, `+0x0F`
and `+0x10` -- the effect fields -- beside the type, which neither twin
copies. Every shipped cell carries `0xFF` / `0` there, so on a shipped save
the copy moves nothing; whether the measured `platform` phase ever had them
set is not something the capture was asked.

---

## 11. The magnifying glass (2026-09-08)

Asked for as a feature -- *there was a button with a magnifying glass in the
original that gave information about things in the game* -- and it turned out
to be decision **D4** of [`43` §11](43-battle-hud.md) with its stated blocker
already gone. D4 said the button stays dark because its page is a block of
`Data.txt` and the cache carried no `Data` bank; the sixth slice's Upgrade
Menu put one there (`text/info/data.json`), and nothing since had gone back
to the button.

What was missing was therefore the **reading**, and [`43` §5.2.1](43-battle-hud.md)
is it: the mode `[0x005106CC]` and the cursor `0x0045F030(10 | 0)`, the gate
inside `aUI.cpp`'s click at `0x0047156D` that takes the whole click and
returns, `0x00432AB0`'s three tests -- the cell's occupant at `+0x07`, the
owner `+0x45 == 0xFF` and the visible byte `+0x4F == 0` -- and `0x00432B20`'s
label out of the 126-byte type table at `0x0051C09D` with the family digit
`'0'`, in the box `230, 200, 180, 300`. Seven checks in
`tools/interface_tables.py` (79 now, from 72) pin every one of those against
the shipped bytes.

Three things the reading settled that a plausible implementation would have
got wrong:

* **The unit path makes no `#` test.** The two item paths refuse a record
  whose letter is `#` before they open the file (`0x00432B86`, `0x00432BE4`);
  this one does not, so the ComBot's `X` -- which has no `X0` block -- and a
  `#`-keyed unit both reach `0x0043E850` and come back as the `{:**}` retry's
  *No information available.* Refusing them instead would have shown nothing
  at all and read as a broken button.
* **A contact is not an alien.** `+0x4F` must be **0**, so the beam of
  [`22` §9.3](22-combat-and-visibility.md) cannot be looked at -- which is
  the whole point of the second pass that makes it a beam.
* **The click is swallowed.** With the mode on, nothing is selected, nothing
  is attacked and nothing is deselected, and a click that finds no alien is
  silent. There is no caption for a miss anywhere in `Txtmod_h`.

**The page has a heading, and it took a second reading to find it.** The first
pass drew the paragraph alone; a screenshot of the original showed a name over
it. `0x0043E850`'s eighth argument is a string copied into `0x0050B4D4`, the
mode-2 painter draws it unless it is the blank buffer at `0x004FA524`, and the
unit path passes the **unit record** — whose `+0x00` is its `char[20]` name.
It is one frame with room made above the text (`0x0043ED87`: `x - 6`,
`y - 24`, `w + 6`, the measured height plus 20), not a bar of its own, which is
how the remake draws it. The same reading says the *item* pages can carry a
heading too — `0x00432B93` chooses between the record's name and the blank
buffer on a flag — which the Upgrade Menu's *i* does not use yet.

**What the shipped `Data.txt` does and does not hold.** The reference
screenshot also carried a stats block (*-hit points: 7*, *-armor: 100/100*,
…) and a longer description than this copy's. Neither is composed by the
engine: `0x0043E850` sets its four extra values to −1 and the painter draws
the title and the block and nothing else. They are **text**, in that
edition's own `Data.txt`; the GOG English file has one paragraph per block and
no numbers, and the remake shows what the player's copy carries.

Three deliberate differences, all in D4: the remake draws no cursor of its own,
so the pointer takes Godot's crosshair -- `0x0045F030`'s **windowed** arm
(`IDC_CROSS`), not the cursor library's frame 10; the box does not take
itself down after five seconds the way a pickup's message does
([`24` §7.2](24-briefing-text.md)), that timeout being there so a crate opened
by mistake cannot hold the mission, and a page the player asked for is not
that; and the button **stays lit while the mode is on**. The third was asked
for after the first drive -- with only the cursor and the hover caption saying
so, the mode is invisible to a player who is not hovering the button -- and
the reading says plainly that the original does not do it: besides the toggle
and the click, only `0x00451230` and the caption chooser `0x00451815` read
`[0x005106CC]`, and the sprite chooser `0x00451A70` takes the event alone. So
the lit face is the shipped **hover** one (`element + 1`, what `0x00451D50`
blits under the pointer) rather than a tint of the remake's own
(`ButtonColumns.lit_element`, four checks in `game_ui`).

One thing the remake asks differently and on purpose: the engine reads the
**cell's** occupant, and `SliceMain.magnifier_slot` asks the body first
(`_unit_under`, the ordinary click's own pick) and the cell second. Two picks
that disagreed would magnify one alien while the click before it had selected
another.

`game_ui` gained twenty checks for it -- the label, the two fallbacks, the
box's own height bound, the button's availability, the toggle, and the pair of
byte tests over every record `_C_140` has.

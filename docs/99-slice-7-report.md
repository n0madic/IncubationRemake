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
* **The key column of [`43` §5](43-battle-hud.md) is the remake's**, not
  the original's: the keyboard translator was not read. `H` is the pad's
  heal; the magnifier (dark, D4) has no key.
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

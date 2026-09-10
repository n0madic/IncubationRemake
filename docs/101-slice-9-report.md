# Slice 9 report — intros, cutscenes, briefings and the transitions between screens

*2026-09-08.  The ninth vertical slice of the remake (`godot/`).  Its
decisions are [`92` §7.19](92-remake-architecture.md); this report records what
was found, what was corrected in delivered documents, what was measured and
what is left.*

## 0. What was there, and what this slice did

The remake played missions and the campaign, and showed nothing between them:
the boot dropped the player on the menu, a new campaign 1 opened on the map
with `_play_intro()` an empty step ([`92` §7.15 S4](92-remake-architecture.md)),
a dialogue location opened, was named and played nothing (D5), `_C_133`'s
successor was read as a hand-over to campaign 2, and neither ending, the
credits, the briefing's typewriter or voice-over, the loading screen nor the
base's fly-in existed.

The game ships no video.  Every cutscene is a real-time Charisma scene in
`Video/<dir>/` — twelve directories, 130 (model, animation) pairs — and every
splash is a 640x480 plate the cache already carried.  So the slice is a
converter pass (`convert_sequences`, `convert_frontend`), a GDScript player
(`game/sequence/`), five small screens (`game/screens/`), the wiring in
`main.gd` and `campaign_host.gd`, and the corrections below.  It was played
through the agent server: the splash, the title, the menu, the intro (full
screen, `Seq_1`'s station and planet), `Dialog_02` framed over `plate_7`, the
gate at a new campaign 1's first map, the 1000 ms hold, the deployment
screen's `B0` typing and the mission-start `A0` box.

## 1. Oracle boundaries

`tools/seq_parse.py --check` is **verified-static** over the executable: 144
checks, 75 of them new — the tail's four calls, the separator set, the wrap,
every program's one track and terminator with its file present, the `"Cam"`
literal and the per-pair index reset, the `10/13` construction focal, the
Focus byte and jump tables with their seven presets and default, every
`Switch` resolving to a `Cam` node and every model carrying `Cam1`, and the
front end's five CD programs, three holds, splash, credits flag, static
extro, message screen, gate, intro flag, exit arms, viewports and typewriter.
`remake_convert.py --check` (338) diffs the cache against that reading
verbatim.  `godot/tests/test_sequence.gd` is **specification-only** and
consumes the same manifest: the clock, the shot and part advance, the program
announcement, the gate, the holds, the dismissal, the boot flag and the camera
axis measurement.  There is deliberately **no `inclib/seq_runtime.py`**
([`92` §5.1](92-remake-architecture.md)): the rule is arithmetic over one clock
and one table.

## 2. Correction — `"9,30"` is a CD track program, not a camera path

[`41` §2 and §4](41-sequence-player.md) read the string every arm loads as
"the authored sequence-camera path `9..19`" with the `30` "matching the 30 fps
proof".  The shared arm tail `0x00467DD5` copies it to `0x00514288`, calls
`MCI_STOP`, `MCI_OPEN cdaudio`, the `CDTrackProgram` parser `0x0042C040` and
the list player `0x0042BC10`.  The parser's `strtok` set is `" .,|;:*+/"`
(`0x004C2768`), a token above the disc's track count is `-1`, and `0x0042BC10`
wraps a negative entry to the first — so each part loops one CD track and the
`30` is a terminator.  `Seq_5`'s empty string keeps `Seq_4`'s track 11.
[`20` §7.3](20-lcl-language.md) had read the dot alone.

**Consequence for the shipped build**: the `Arack` family the GOG shim plays
stops at 14 ([`28` §6.1](28-effects-and-sound.md)), so `Dialog_09`, `_14`,
`_15`, `_16` and the animated `Extro` play in silence.  The remake plays the
cutscenes from `Track`, which runs to 20 (I1).

## 3. Correction — the cameras are parts named `Cam<n>`, and `Focus` is a table

The note dispatcher of `0x0047F6A0` builds `"Cam" + itoa(index)` and looks the
part up by name; `Switch n` writes the index, and installing a pair resets it
to 1 (`0x0048023B`).  All 113 models carry `Cam1` (`Model_D09` carries
`Cam1..Cam8` — an earlier scan had truncated the list to six), and all 55
`Switch` notes resolve.  `Focus f` maps `_ftol(f) - 24` through a 177-entry
byte table at `0x00480670` to seven presets — 24→400, 28→500, 35→613, 50→877,
85→1477, 135→2350, 200→3500, everything else 765 — then scales by the viewport
height over 480 (f32 reciprocals at `0x004B1690`/`0x004B1694`; the
`[ebp+0xC]` halving arm is never taken by the sequence player).  `Fade n`
exists (`0x0048059C`) and no clip uses it.

Two things the plan had assumed and the reading overturned: the focal before
the first note is **not 765** but the construction value `_ftol(width *
10/13)` — 492 full screen, 398 framed, `fmul qword [0x004B1570]` in both
branches of `aCreateSeqPlayer` — and it **carries across a part's shots**,
because the pair installer writes the camera index and not `[esi+0x58]`.

## 4. Measurement — the camera bone's forward axis

Charisma has no camera record ([`40` §10.1](40-charisma-model-animation.md)),
so which local axis a `Cam<n>` part looks along is not in the data.  Over all
130 shots at four frames each (520 poses), the mean joint of the drawn parts
lies along the bone's **engine +Y** — Godot -Z after `WorldSpace.engine_matrix`
— in **514 of 520**, mean cosine 0.90; ±X and ±Y of the Godot frame score
0.46..0.54 and +Z 0.01.  So the bone's frame is the camera's in Godot's own
convention and `SequencePlayer.CAMERA_BASIS_FIX` is the identity.  A first
guess — the 3D Studio MAX convention, look down local -Z — scored 0.53 and
was replaced by the measurement the same hour, which is what the check is
for.  The **roll** about that axis is what a joint centroid cannot see and is
[`41` §7](41-sequence-player.md)'s one open item.

## 5. Correction — `_C_YYY` as a mission is chain 1's ending

[`27` §6.6](27-campaign.md) said `_C_133`'s next map `_C_YYY` "is how one
campaign hands over to the other".  `_C_YYY.lev`'s header carries mission id
**255**, and `0x00456FC0`'s gate (`sub ecx, 0xB3; sub ecx, 0x4B`) reads 255 as
logical id 1 — the animated `Video/Extro` full screen — after which
`0x00457180` sleeps 4000 ms and raises the credits flag `0x0044BC60(1)`.
`_C_179 → _C_180` (id 180) is the other ending, the static `Ship.bmp` with
`Briefing/extro.wav` and `Menu_b`'s window 11 whose one live button is
`Txtmod_b` 4 *Continue* at (450, 430).  The converter now keeps `_C_YYY` as a
mission row beside `_C_180` (76 rows), so `CampaignHost.advance()` lands on it
and `at_an_ending()` is true; the campaign ends after the credits.

## 6. Findings — the front end's own constants

* **The intro gate** `[0x00510D48]` has **one** setter, `0x0045D3E0`, called
  with 1 from the new-campaign start's campaign-1 arm (`0x00450997`), with 0
  from its other arm, at menu init (`0x0044B329`, `esi = 0`) and after any
  sequence (`0x004570B6`).  Loading a save never re-arms it.  It is
  `CampaignState.intro_pending`, inside the save's document and digest.
* **The programs are longer than the plan's dwords**: the menu and the load
  screen play `"2,3,4,5,6,7"` (three dwords at `0x004CA1E0`, of which the plan
  had seen only `"6,7"`), the debriefing `"7,3,2"` (`0x004CAE2C`), the credits
  `"8"`, mission control `"5,4,2,5"` — **one** program, whose `"2,5"` at
  `0x004CA7B4` is its second dword and not a second variant.  Mission control's
  is not heard: the map's `INIT MAP` starts `_C_XXX.lcl`'s own program right
  after it (I9).
* **`aPrintMessageScreen`** (`0x0045F290`) shows `MsgScr.bmp` whole with text 0
  of the loaded bank — *Please Wait...* — in `Font_2` centred at (320, 65),
  colours `0xF79E`/`0x632C`; both callers, mission control's entry
  (`0x00454007`, `ebx = 0`) and the debriefing's exit (`0x0045D42B`, `push
  0`), pass id 0.  The framed sequence's background callback `0x00456F30`
  draws the same id 0 at (320, 210): a loading caption, not the location's
  name the plan had guessed.
* **The exit** `0x00457180` is reached from the GUI loop's `WM_LBUTTONDOWN`
  (`cmp di, 0x201` at `0x004555E6`) and key arms while window 8 is up; one
  input ends the whole sequence.  Its id-255 arm sleeps 4000 ms and sets the
  credits flag **without** destroying the player or holding a second time.
* **The typewriter** adds one to each of the four limits per printed frame
  (`fcn.0043ECF0`, caps 5000/50000); the blip is `textbeep.wav`, the third
  buffer `aInitGUI` loads.  `animate` per call site: the mission-start `A0`
  is **1** (whole) and gated on the briefing flag `0x0043B1F0`; the briefing
  page, the tips, the deployment `B0` are 0 (typed); the map's `B0` is 0 and
  drawn only while the flag is **off** — it is the fallback for a player who
  turned briefings off, and the remake, which has no such option, does not
  draw it ([`24` §7.1](24-briefing-text.md)).
* **The fly-in** (`0x00417000`) opens on the first waypoint looking at the
  target (`0x00417167`), steps `_ftol(800 * d) / 40` = 20 units a frame along
  the unit direction and ends a leg within 3200 on every axis
  (`0x004171FF..0x00417224`).  Its frame pacing was **not** measured and is
  [`27` §10 item 8](27-campaign.md).

## 7. Measurements

| | before | after |
|---|---|---|
| `seq_parse.py --check` | 75 | **160** (§13.4 and §13.5 added seven; §13.11 six more) |
| `remake_convert.py --check` | 251 | **341**, in 40 s since the texture decode is memoised (§12.6) |
| `remake_convert.py --check-campaign` | 44, 26 s, 85.9 MiB | **88**, 30 s, 199.5 MiB (ceiling 210 MiB) |
| one six-mission conversion | 4 s, 42.6 MiB | **23 s, 153 MiB** (34 s before the decode memo of §12.6; 38 MiB cutscene documents, 11 MiB their textures, 34 MiB voice-over waves, 20 MiB `Track09..19`) |
| six-mission cache without music | 16.5 MiB | **105.7 MiB** |
| `run_tests.sh` | 39 suites, 4820 checks | **40 suites, 5009 checks** |
| `test_sequence.gd` | — | 90 checks, specification-only |
| camera axis, in front of the lens | — | 514 / 520 poses along engine +Y; the roll's median is 0.000° over 2547 (§13.4) |

The cache ceilings moved with those numbers written down, and the
`--no-music` check changed shape: music is no longer most of the difference
between the two caches, so the check became "every path in one cache and not
the other is under `audio/music/`, and exactly two tables differ".

## 8. Divergences

* **I1**, the `Track` family for the cutscenes: the shipped build is silent
  through five of them.  A decision, recorded.
* **The message screen is not shown for the mission build itself** — the
  original announces mission control's entry and the debriefing's exit and
  not `aLoadBattleMap` — and it is shown for two drawn frames rather than for
  the build's length, which is what makes the build a picture.
* ~~**The map's `B0`** is not drawn (§6): the remake has no briefing switch.~~
  **Wrong, and corrected in §12.**
* ~~**The mission-start `A0` box** ... grows past 199 units.~~ **The box should
  not be there at all; corrected in §12.**
* ~~**The fly-in's pacing** (§6) and **the camera roll** (§4).~~ **Both closed
  in §12.**
* **The info box's own height** is a divergence, and a small one. The height
  `aActivateBriefingInfo` stores has one reader in the whole image,
  `0x0043F032`, which pushes it into the frame draw `0x0043F430` — so it is
  the height of the drawn *rectangle* and clips nothing, and a block longer
  than its box runs past the frame's bottom edge. The remake grows the frame
  to hold its text instead: the same words, inside a border rather than
  through it.

## 9. Verification

```bash
python3 tools/seq_parse.py --check gog_incubation            # 146/146
python3 tools/remake_convert.py gog_incubation --check         # 338/338
python3 tools/remake_convert.py --check-cache                  # 29/29
bash godot/run_tests.sh                                        # 40 suites, 4973 checks
timeout 300 godot --path godot --resolution 1280x800 -- --agent-port=8787
python3 tools/agent_client.py cmd "shot title" "key SPACE" "wait 5" "shot menu"
python3 tools/agent_client.py cmd "sequence 0" "wait 90" "shot intro"
python3 tools/agent_client.py cmd "sequence 2 framed" "wait 40" "shot dialog"
python3 tools/agent_client.py cmd "campaign 1" "ui map" "wait 5" "shot gate"
python3 tools/remake_convert.py gog_incubation --check-campaign  # 88/88, 30 s, 199.5 MiB
```

The `--sequence=N` launch flag is the fourth way in beside `--mission=`,
`--campaign=` and the agent, and `boot_choice` pins it.

Three flows were then driven **through the game's own buttons** rather than
the agent's debugging entries, because `screen advance` and `ui map` bypass
the gate and `campaign N` skips the *Please Wait* coroutine:

* *Start Campaign* → *Campaign 1* → the message screen → the gate → the
  full-screen intro (`Seq_1`, `Animation_1_1`, 30.7 frames a second measured
  over five seconds of `/state`) → a key → `holding` true for the 1000 ms →
  the location map.
* `_C_179` won → the debriefing's own *Continue* → *Please Wait* → the map
  entry's gate on `_C_180` → the static extro (`Ship`, *Continue* at
  540,430) → the credits (*Exit Game*, *Back*) → *Back* → the main menu.
* `_C_133` won → *Continue* → the gate on `_C_YYY` (id 255) → the full-screen
  `Extro` → a key → `holding` true for the 4000 ms → the credits.

And the briefing page over the map holds `audio/briefing/_c_100.wav` in the
pool while it is up and releases it on *Back*, read out of `/state`'s
`sounds`, which is now written with no world behind it for that reason.

## 10. What this slice did not do

* ~~**Compare the intro against the original under Wine**~~ — **neither wanted
  that capture in the end.** The fly-in's pacing was in `0x00417000` (§12.3)
  and the camera's roll is measurable from the scenes themselves (§13.4).
* **A `SubViewport` for the framed presentation.** The main-world route (I5)
  renders at the window's full resolution and was preferred; the plan's
  `own_world_3d` note stands as the alternative if two 3D scenes ever have to
  coexist.
* ~~**Run the `macOS Tests` export.**~~ **Done on 2026-09-09** (§12.7): the
  preset exported and the build ran the suites against the published cache --
  40 suites, 4986 checks, 0 failures, and no `resources still in use` line
  (re-run on the 0.31.0 cache after §13).
  So neither a `static var` nor a `RefCounted` cycle came in with the slice,
  which is the one thing the editor's `run_tests.sh` cannot say.
* **The fourth `Focus` arm.** `[ebp+0xC]` halves the preset and scales by
  1/240; no caller of the sequence player passes it, so it is read and not
  reproduced.

## 11. Open questions

None. Both of the slice's own — the camera bone's roll and the fly-in's frame
— closed on 2026-09-09; see §12.

---

## 12. Addendum, 2026-09-09 — three reports and six answers

The player reported three things: the intro had no sound at all, a grey screen
flashed on the way from it to the location map, and the *Supply Shuttle Alpha*
location opened straight onto the Upgrade Menu where the original flies a
camera over the shuttle. Chasing them closed the slice's two open questions
and corrected two of its own findings.

### 12.1 The intro was inaudible, not silent — and `Track` is measured now

The music was playing the whole time: `/state` showed
`program:track:9,30`, track 9, `playing: true`. What it did not show until now
was the volume, and that was `-4000` hundredths of a decibel — `VOLUME_MIN`,
1 % of amplitude. The options row said `-40.0 dB`, which does not read as
*silent* to anyone, and `_step_volume` stepped **up** and wrapped maximum to
floor: one click on a music row already at full volume dropped it there, and
sixteen more were needed to climb back. The row now reads a percentage and the
cycle runs downward, so the click at the floor restores full volume and a
curious click at full costs 2.5 dB. `GET /state` carries `music` — source,
family, track, playing, volume — because a snapshot that lists only the wave
pool cannot see a silent cutscene.

Measuring the tracks to be sure they were the right ones settled I1, which had
been a *decision*: from 09 up, `Track` and `Arack` are not the same kind of
thing. Every `Track` file is cut to the picture of the part that asks for it,
two to seven seconds longer; every `Arack` file is a loop two to four times as
long. `Video/` ships no wave, so a cutscene's **speech and effects are in its
CD track**, and the shipped build is not merely quieter for the five it cannot
reach — it is missing their dialogue. [`28` §6.1](28-effects-and-sound.md)
carries the table.

### 12.2 The grey flash was Godot's clear colour

`_drop_sequence` destroys the player, and at the intro no map backdrop exists
yet, so for the whole 1000 ms hold there is no camera and Godot paints
`default_clear_color` — a light slate. It is black project-wide now, which
also covers the boot frame before the splash.

### 12.3 The shuttle: the fly-in is a transition, and its law was misread

`aPlayLocationAnimation_Upgrade` `0x00417510` paints `plate_7` into both
surfaces and then **blocks** in `0x00417000`; mission control raises the
Upgrade Menu only when it returns. The slice ran the flight behind the menu's
opaque `plate_6`, where nothing could be seen, and `SCREEN_UPGRADE` was not
even in the list of screens that start it. Entering an upgrade location now
plays the flight in the map's own 518x306 window behind `plate_7` — the framed
presentation a dialogue cutscene uses — and the menu follows it; any key or
click lands it, which is `0x004FCBDC`, the flag the front end's frame function
sets on `WM_KEYDOWN`, `WM_CHAR` and `WM_LBUTTONDOWN`.

Reading the loop for that flag also closed §11's second question and corrected
the step. `0x0040B6F0` ends on `0x0047F2E0(10, 20)`, a limiter that busy-waits
on `GetTickCount` until `1000/20` ms have passed, so the flight runs at
**20 frames a second**. And 20 units a frame was only the *first* frame:

| | |
|---|---|
| target velocity | `_ftol(direction x 800)` (`0x004171DE`) |
| direction | horizontals over the larger of them; vertical `(goal.z >> 3) - (eye.z >> 3)` over the horizontal distance (`0x0046D400`) |
| approach | `velocity += (want - velocity) / n`, `n` 40 down to 5 per leg |
| leg ends | within 3200 on every axis |
| flight ends | last leg only, `800 x remaining / leg` under 80 |

So the eye accelerates from 800/40 = 20 toward 800, and the eight shipped
bases' flights last **2.9 to 12.8 seconds**. `campaign_tables.py` pins all six
constants and the limiter (468 checks since §13.8 pinned the direction helper's shifted arm);
`test_sequence.gd` flies a path and
requires it to land.

### 12.4 The camera roll, measured against the scenes

There is no roll field to find, so what is measured is the worlds themselves:
every cutscene is built with a sky above it, and a bone frame carrying a
quarter or a half turn would hold that world on its side. Over 260 poses the
camera's own up lies within 46° of the world's in **240**, a share of 0.92 — a
number a quarter turn puts at zero. `test_sequence.gd` re-measures it beside
the forward axis. A *small* roll was left here as indistinguishable; **§13.4
measures it** — per pose rather than as a share — and the median over 2547 of
them is exactly zero.

### 12.5 `0x0043B1F0` is a multiplayer predicate — both briefing boxes were backwards

The slice read it as "the briefing flag" and got both of its arms the wrong way
round. It answers `[0x00509F08] && (gameMode() in {2, 4} or (3 with more than
one human))`, and a campaign is `gameMode() == 1`, so **it is false in every
campaign**. The two call sites are exact complements:

* the location map's `B0` needs `humans == 1 && !predicate`, so a campaign
  **does** draw it — it is mission control's action `0xb`, which
  `0x00451240` maps the key **`B`** to;
* the mission-start `A0` popup is the arm taken when the predicate is **true**,
  so a campaign **never** shows it.

The popup is behind a second gate besides — `0x005106D4`, whose only setter in
the image is the arm the map's `B` takes when *its* gate fails. So it is one
feature with three shapes, and **§13.5 reads the third**: one human presses
`B` on the map and reads the short briefing there, a network session arms the
flag and gets the full one on the mission's first frame, and a hot seat arms it
and gets the strength panel instead. The remake now draws the map's `B0` on `B` and
no longer opens a campaign mission on a popup, which also disposes of §8's
"the `A0` box grows past 199" — there is no box.

### 12.6 `--check` is 40 seconds again

A VISN record decodes to exactly one PNG, and `--check` runs three whole
conversions in one process over texture sets that overlap. `convert_textures`
keys the decoded PNG by the record's own bytes, so each record is decoded and
compressed once per process. The whole check is **40 s** where it was 102.

It pays inside one conversion as well, because the twelve cutscene texture
sets and the mission sets share records: a single cold conversion is **23 s**
where it was 34, and `--check-campaign` -- 92 maps in one process -- is
**30 s** where it was 57, at the same 204263 KiB.

### 12.7 What this addendum leaves

* **The `macOS Tests` export** is run at the end of this pass rather than left
  out of it; §10's entry stands corrected there.
* ~~**The campaign arm of `0x0041A980`**~~ — **closed in §12.11.**
* ~~A **small camera roll** cannot be measured from the data~~ — **closed in
  §12.9**: it can, and it is zero.

---

## 13. A second pass, 2026-09-09

Four of the five things §12 left open, and two reports from play.

### 13.1 An upgrade base's marines

**Reported:** *"in the original the transition to Supply Shuttle Alpha has a
different sequence — soldiers walking to the shuttle; in the remake it is just
an empty pad with a shuttle."* Correct, and the cause is a comment that was
true of one thing and applied to another.

`_build_backdrop` carried "the campaign maps place no units at all — `_C_XXX`
and `_C_YYY` are 200 free slots each", which is true of the two **chain** maps
and of neither of the fifteen **upgrade** maps: every one of those places two
or three living player-0 marines, 39 in all, and `0x00417510` starts an
animation on each of them before it begins the flight. [`27`
§2.7.1](27-campaign.md) has the reading — both halves of `aUnitMap.cpp`'s
iterator pair, the `+0x16`/`+0x45` test, the `id + 7` animation slot and the
`kind == 4` arm's own four calls.

Three things in it were easy to get wrong and are pinned rather than assumed:

* the clip is a **fixed literal**, `P0_M2_000` at `0x004C030C`, which **no
  selector's closure names** — so the converter, which walks the three
  selectors, had never emitted it. `CONVERTER_VERSION` is **0.31.0** for that
  one file, and `remake_convert.py --check` now reads the literal back out of
  the shipped executable and requires the cache to carry it;
* the starting time is `aRandom2(0, 10)`, the **clock-seeded** generator
  ([`22` §3.2](22-combat-and-visibility.md)) — three marines started in one
  frame are deliberately out of step, and the effect is outside every hash;
* nothing **moves** the units. No `upgrade_N.lcl` has a movement command; the
  march is the clip's own root motion, 3017.7 skeleton units over 452 frames,
  which at the front end's 20 a second is **1.33 m of drawn ground a second** —
  an ordinary walking pace, and two thirds of a map field.

`game/backdrop_bodies.gd` is the whole of it and `_C_XXX`/`_C_YYY` take the
same path to a no-op, so there is no branch on the kind of map. It reuses
`CharismaLibrary`'s three-level selector and `UnitsView.face`, which became a
public static for it rather than being copied.

### 13.2 The fly-in test ran a second copy of the law

`test_sequence._fly` transcribed the stepping loop instead of calling it, so a
drift inside `SliceMain._fly_step`'s own arithmetic was the one thing it could
not see. The step is now `SliceMain.fly_advance`, static and pure — state in,
state out — with `_fly_step` reduced to the waypoint bookkeeping that needs a
rig and a screen, and the suite driving the production copy.

### 13.3 A hold could raise a screen over a newer one

`hold`'s callback fired after another screen had already gone up. The
original's `Sleep` blocks, so nothing can overtake one; `show_campaign_screen`
and `open_shell` now drop the countdown, and `test_sequence` checks that a
cancelled hold never fires. This is the cause of the one live-run anomaly §12
recorded and could not explain: the control server's `wait` counts **frames**
while a hold counts **drawn seconds**, so a `location 1` sent during the
post-intro hold raised a screen the hold then replaced. A player cannot reach
it — during a hold the screen is black with nothing to click.

### 13.4 The camera roll is zero, and measurable

§12.4 measured the *forward* axis and left the roll to a Wine capture, on the
grounds that a few degrees would move neither of the two shares it had. It
does not need one. The roll of a single pose is a number: the world up with
the forward component removed, and the signed angle from it to the bone's own
engine +Z. Over all 130 shots at nine frames each — 2547 poses, the
near-vertical ones dropping out because every roll there is the same picture —
the **median is 0.000°**, 74 % are within half a degree and 97 % within ten,
with a real tail of a few dozen deliberately banked shots.

So the bones are authored upright and there is no hidden convention. The remake
never decided it either way: `SequencePlayer` takes the bone's whole basis and
`CAMERA_BASIS_FIX` is the identity, so whatever roll is authored is drawn.
`seq_parse.py --check` pins the three numbers ([`41` §7](41-sequence-player.md)).

### 13.5 The strength panel is unreachable, and now for a stated reason

§12.7 named `0x0045FA00`'s per-player panel as something with no equivalent.
Reading its gate whole settles it as **faithful absence** rather than a gap
([`24` §7.1](24-briefing-text.md)):

```c
/* 0x00453961, the map's `B` */          /* 0x0041B5FE, the mission's first frame */
if (humans() == 1 && !predicate())       if (!flag)            /* nothing */
     draw B0;                            else if (predicate()) draw A0;
else flag = 1;                           else                  aDrawStrength();
```

`humans()` is `0x0043B700` and it is a **count**, not a flag: it walks the
player-kind slots at `0x00509E20` and returns how many hold 1. `0x005106D4`'s
only writer in the whole image is the `else` above. One human never arms it, so
the panel is the **hot-seat** shape — two or more humans on one machine, where
the flag is set and the network predicate is still false — and the remake has
no way to be more than one human. `seq_parse.py --check` pins the flag's single
writer, its reader, its clear and `0x0041A980`'s branch.

### 13.6 A review pass over the whole slice

`/code-review` over the working set found seven defects, all in this slice's
own code and none of them caught by an existing check. They are recorded here
because five are the same shape -- a path that is only reached when something
is *missing*, which no shipped cache and no ordinary play ever produces.

1. **The animated extro replayed itself.** `_finish_sequence` freed the player
   but left the `SequenceScreen` in the tree with its input live, so a second
   key press during the four-second hold emitted `DONE` again and re-entered
   the arm with an empty kind — and `opening_sequence()` arms itself from
   mission id 255 every time, unlike the intro's once-only flag. The credits
   could not be reached while the player kept pressing keys. The guard is a
   `return` when nothing is playing, which is what the original's blocking
   `Sleep` gives for free.
2. **That hold showed the mission the player had just left.**
   `_drop_sequence` gives `_scene_root` its visibility and its camera back,
   and the gate reaches `play_sequence` before `_clear_mission()` — so the
   four seconds the specification calls black were the previous battlefield.
   The mission now comes down before an opening sequence plays, exactly as it
   already did for the static extro.
3. **A campaign screen raised with no campaign crashed** — a regression from
   §12's own work. Three screens gained `campaign.state.mission` reads for the
   briefing document; the gate above them is guarded and simply does not run,
   so the arm below it was reached with no state. `CampaignHost.current_mission()`
   is the guarded read, beside `map_mission()`.
4. **A missing pair ended the part.** `_install_shot` answered `false` both
   for "the part has run out" and for "the cache has no such clip", so one
   hole in the middle of a five-shot part silently dropped the last three. A
   hole is now noted and skipped.
5. **It bounded itself on one list and indexed two.** The pairs come from one
   stem list and cannot differ, which is why the invariant is worth stating:
   `remake_convert.py --check` requires it of every part and the player bounds
   itself on the shorter of the two.
6. **`--sequence=N` for a cutscene the cache lacks left no screen at all.**
   `boot_choice` cannot catch it — whether an id *plays* is the cache's answer
   — so the boot arm falls back to the menu the way `--campaign=` does.
7. **The map's word blip carried a real volume id where the other two carried
   the GUI's own.** It sounded the same, entry 0 of the shipped table being
   100, and would have fallen silent on a cache without that id. The three
   copies are one seam now, `BriefingText.blip_cue()`.

One thing it found that was not a defect: `seq_parse.focus_preset()` was
called by nothing and `manifest_document`'s docstring claimed its `pe`-less
fallback agreed with `FOCUS_CORPUS` and that `--check` said so. Neither was
true and no caller took that branch, so both are gone rather than checked.

Each of the seven has a check now, and the suites are 40 by 5009.

### 13.8 The fly-in flew along the ground — **[code] `0x0046D400`** *(2026-09-09)*

Reported from the picture: the arrival flights differ from the original, and
the *Power Station Supply Base* — location 8, `upgrade_8` — dives under the
buildings where the original sweeps round from above.

The path was right and the step law was right. What was wrong was one divisor
inside `SliceMain.fly_direction`. `0x0046D400` takes **ten** arguments and the
last one, the `push 1` at `0x004172B1`, chooses between two arms; the arm the
flight takes shifts *all six* coordinates right by three (`0x0046D4EC`,
`D4EF`, `D4F2`, `D4F5`, `D4FB`, `D504`) before it asks `0x0044AE10` for the
horizontal distance. The port shifted the two heights and divided them by the
**whole** run, so every vertical component came out eight times too small.

What that looks like is not subtle. `upgrade_8`'s script opens the eye at
`(2042, -627, -750) × 16` — 12000 units under a map whose every cell is at
height 0 — and asks for three waypoints climbing to 36000. Stepped with the
eight-times-too-small rise the eye reaches 2436 by frame 40 and is still at
4472 at frame 100, a metre or two off the street, looking level (−0.4° to
−3.1°) the whole way; a contact sheet of twelve frames through the remake's
own agent shows exactly that — walls, a walkway edge-on, and the last frames
looking *up* at the sky between two blocks. With the shift where the original
has it the same path is at 13763 by frame 100 and −14.6°, and ends at −37°:
the overhead sweep the report describes.

Three checks, and a fourth that had to be corrected:

* `upgrade.fly_direction_arm` — `6a 01` at `0x004172B1`. Without it the six
  shifts would be pinned on an arm nothing reaches.
* `upgrade.fly_direction_shifts_all_six` — the opcode, the `sar` reg field and
  the count at each of the six sites.
* `upgrade.fly_flat_distance_call` — that `0x0046D508` still reaches
  `0x0044AE10`.
* `fly.height_is_in_eighths` said the vertical of an 8000-up-8000-across leg
  is an eighth. It is **one**; the two eighths cancel. It is now
  `fly.the_run_is_in_eighths_too`, and beside it
  `fly.upgrade_8_lifts_the_eye_out` runs the base's own first leg and requires
  the two candidate divisors to differ before comparing, and
  `fly.each_coordinate_is_shifted_on_its_own` pins the flooring — `sar`
  floors, so `(a >> 3) - (b >> 3)` is not `(a - b) >> 3` wherever the
  operands' remainders cross. It is put on a negative coordinate, which is
  where GDScript's `>>` also has to floor as `sar` does: nine of the fifteen
  bases open on a waypoint carrying one (1, 2, 4, 6, 8, 211, 212, 215, 216).

All fifteen bases were re-flown through the corrected law: none dives, three
(`upgrade_2`, `upgrade_8`, `upgrade_211`) still open below zero because their
own first waypoint is, and the flights last between four and twenty seconds.

**What this does not settle:** those three still spend the first second or two
under the ground plane, and by the disassembly the original starts there too —
the first `aSetCameraPosition` of the first frame uses `waypoint 0 + v`. How
that *looks* in the original — whether Eng3d draws the terrain from beneath at
all — is **UNVERIFIED**; it wants a Wine capture of the same seconds.


### 13.9 Nothing may be left alive at exit — **[remake]** *(2026-09-09)*

Reported from the run's own tail: `WARNING: 1 RID of type "CanvasItem" was
leaked` and `WARNING: 2 ObjectDB instances were leaked at exit`, in both the
editor run and the export. They had been noted and let stand, because
`run_tests.sh` gates on `ERROR:` lines and these are warnings.

**The leak.** `CampaignScreen._draw_plate` handles a cache with no plate art
by painting a dark backing — but only for a screen that wants the whole plate;
a screen with a window in it must leave the hole clear, or the backing would
cover the very thing the window exists to show. It built the `ColorRect`
*first* and parented it only in the whole-plate arm, so every windowed screen
built without art left one behind: the node, its theme owner (the second
object) and its `CanvasItem` RID. Four screens do that — the deployment
screen, the HQ, the Recruit window and the Item List — and the suites raise
one of them, which is why the count was exactly one. The fix is to ask the
question before building the node.

**Two gates, because the two catch different things.**

* `run_tests.sh` now fails on `ERROR: N resources still in use at exit`,
  `WARNING: N ObjectDB instances were leaked` and
  `WARNING: N RID(s) of type "X" ... leaked` alike. It is the only place that
  can see them — they are printed after the last check — but it names the
  process, not the culprit.
* `test_game_ui`'s `no_state.a_screen_owns_everything_it_builds` names the
  culprit and runs inside the exported build too: it builds each of the eight
  campaign screens, frees it, and requires
  `Performance.OBJECT_ORPHAN_NODE_COUNT` back at its baseline. `free()` is
  immediate, so the count is exact.

Both were checked by putting the defect back: the suite failed with
`select_units left 1, hq left 1, recruit left 1, items left 1`, and the script
printed `run_tests.sh: the run left something behind:` with the two warning
lines under it and took its failure branch. (What was measured there is the
output; that the branch ends in `exit 1` is read off the script.)

**A second bug the new check found, and it is not a leak.** The loop raises
all eight campaign screens, and raising the debriefing with no campaign state
threw on `campaign.state.scoreboard[0]` — the same unguarded read as §13.6's
third finding, in the one arm that pass missed. It is now
`CampaignHost.mission_board()`, guarded the way `current_mission()` is, and
the eight-screen loop covers it from here on.

The suites are 40 by **5009**, in the editor and in the `macOS Tests` export,
with nothing held at exit in either.

**What this leaves.** The script's gate covers the editor run, which is the
one in the always-run block. The export prints the same lines but is started
by hand and nothing gates it — today's run was read by eye and was clean. The
second layer does run inside the export, so what is uncovered is only a leak
that none of the eight screens makes; closing it properly wants a wrapper
around the `.app`, which is its own piece of work.


### 13.10 Three things the reveal and the splash cost the player *(2026-09-09)*

Reported from play, and all three are the remake choosing against the
original on the same ground `game_font` chose on — recorded as
[`92` §7.19](92-remake-architecture.md) I19, I20 and I21 rather than made
quietly.

* **The splash is shown once.** `aGameIntro` waits for a click on *Start Game*
  every launch. The two plates cost a second and a half; the click is
  unbounded and paid on every run. `SliceMain.shell_entry` is a static, pure
  decision on `GameSettings.seen_splash`, so a suite pins both arms, and
  `_show_splash` writes the flag when the **title** plate goes up — a run
  killed on the logo showed the player nothing to skip. Deleting
  `settings.json` brings it back.
* **The tips are shown whole.** Both pages pass `animate = 0` in the original
  and both type. The tips are a reference page opened to look one thing up;
  the briefing is the page the reveal is for. Returning to `A0` after `C0`
  does not restart it either — `BriefingText.show_block` only restarts a
  typewriter that is already running.
* **A click or a key finishes the briefing's reveal.** `skip_typing` is a
  public method and the input handler is two lines over it, because a screen
  built off the tree is routed no input at all and the suite has to reach the
  seam directly. The voice-over is the host's, under `SliceMain.VOICE_TAG`,
  and is not touched: it reads on over the finished text.

Six checks: both arms of `shell_entry`, the flag's default and its round trip
through the settings file, the skip (and that a second skip is not the
screen's to take), and that `C0` does not type and `A0` does not type again
after it. Confirmed in the running game as well — first launch on the title
plate with the flag written, second straight to the menu; the briefing
half-typed, then whole one frame after a click; the tips whole three frames
after *Tips*.

**What this leaves.** Nothing: the deployment screen's `B0` box, named here as
untouched, turned out not to belong on that screen at all and is gone (§13.11).


### 13.11 The deployment screen never had a briefing box — **[code] `0x0044DCD0`** *(2026-09-09)*

Reported from play: the victory and defeat conditions typed over the landing
view, a screen "that was not there before and I do not remember in the
original". Both halves of that are right, and the mistake is this slice's.

`docs/24` §7.1's table has one row per `aActivateBriefingInfo` call site with
the screen named beside it, and `0x0044EEDA`'s said *unit selection*. The
screen was **named, not read**. The site is inside `aMenuSystem`'s gadget
dispatcher `0x0044DCD0`, whose outer switch is on `[0x50FDF8]` — and that
global is `Menu_a`'s `_A_WindowSelector`, not `Menu_b`'s. What settles which
is a **writer**: `0x0044D2F4` pushes `GUI\Menu_a.LCL` and `0x0044D37C` sets
the global to 7, `Menu_a`'s `07_MainMenu`. (The arm count agrees — 17 arms
against `Menu_a`'s 00..16 and `Menu_b`'s 00..11 — but counting is not
reading.) Window **10** is `:Leveloptions;`, its arm is `0x0044EB52`, and the
gadget whose index reaches the `B0` block is **22**:
`GUI_SetButton (22_gdtID, 0_fntID, 135_WinText, …)`, commented `* infos` in
`Menu_a.lcl`. It is the **multiplayer level-options screen**, on the
DirectPlay path this remake does not have — the same `0x0044DCD0` the slice's
own plan had already set outside its scope.

`SelectUnits` is a `Menu_b` window, and of the eight `aActivateBriefingInfo`
sites in the image exactly one is inside the dispatcher: this one. So the
deployment screen draws no briefing box in the original, and it draws none
here now.

Five checks in `seq_parse.py`, because a wrong attribution is what this cost:
the writer that names `Menu_a`, the dispatcher's switch and its bound, window
10's own gadget switch, the index table's entry for gadget 22 reaching
`0x0044EEBD`, and **the list of all eight call sites** — so a ninth cannot
appear, and none can be attributed to a screen from memory again. In the
suites, `deploy.no_briefing_box_over_the_map` counts the `BriefingText`
children the built screen has, which is zero.

`seq_parse --check` is 160 where it was 153 — the sixth check settles the
other two rows the remake draws, the briefing screen's `A0` and the tips'
`C0`, by the same kind of evidence: the routine that carries them pushes
`GUI\Menu_b.LCL` at `0x00456D17` and loads it before either call.

**Not part of this.** The line under the view — *pick a soldier, then a
landing position* — is the remake's own and stays: it is §7.4's spoken
refusal, declared, and the original does not need it because its screen is a
picture of the map with the squad standing on it.


### 13.7 What this pass leaves

* ~~**Whether the marines keep marching behind the menus**~~ — **they do, in
  both.** It was read out of `0x00455A40(0)` pushing the camera on every
  Mission Control frame and left unmeasured; a frame of the original's *Item
  List* settles it — the three are on the pad, mid-stride, short of the
  shuttle — and the same screen in the remake shows them walking the same way
  and arriving. So the animation is not stopped when the flight returns. What
  that compares is two pictures rather than the engine's own frame, so the
  *rate* behind the menus is still checked only against the eye.
* **The march's own pace is read, not compared.** 1.33 m a second follows from
  the clip, the speed literal and the 20 fps limiter, each measured; that the
  original looks the same at the same moment is not checked against a frame of
  it. The *direction* is checked -- `test_game_ui` requires the step and the
  facing to agree to within a cosine of 0.9, which is the one thing a
  screenshot could not have shown: a metre of travel at forty thousand units
  of depth is a pixel, and the first version of that check had the composition
  wrong and read exactly -1.


## 14. The credits screen has a roll — **[code] `fcn.0044BD90`** *(2026-09-10)*

§6 and [`92` §7.15 I8](92-remake-architecture.md) read the credits as *two
buttons on a plate*, because that is all `Menu_a.lcl`'s `:Credits;` block
carries (two `GUI_SetButton` calls, `Txtmod_a` 7 and 8). The remake drew
exactly that, and the screen came out as `Credits.bmp` with a black right-hand
half and nothing in it — which is what a player reported.

**The roll is in the executable, not in the script.** `0x0044C050`, the
routine that loads the plate and builds window 15, also writes
`[0x0050FE1C] = 410` (`0x0044C092`) and clears the delay counter
`[0x0050FE20]`; the menu's draw loop `fcn.0044B5E0` then calls `fcn.0044BD90`
on every frame the window selector `[0x0050FDF8]` is 15 (`0x0044B691`, the
call at `0x0044B6A1`). That function is the roll:

* it clips to `fcn.00447B20(0, 0, 640, 400)` — which is why the lines pass
  **behind** the buttons' row at 410 rather than over it;
* it walks `Txtmod_a` from string **161** (`mov dword [var_20h], 0xA1`) through
  `0x00470FE0`, one `wsprintf("%s")` per line, and stops on a line equal to
  `"END"` (`0x004C4868`). The shipped bank has the terminator at **339**, so
  the roll is 178 lines;
* each line's **first character is a code**, read as a five-arm `switch` on
  `byte - '0'` whose jump table is at `0x0044C03C`; the rest of the line is
  what is printed, right-aligned (`Format` 2) at *x* **600**;
* at the end of the frame it decrements `[0x0050FE1C]` by one
  (`0x0044C026`), gated on the delay counter, which nothing in the image ever
  sets above zero. Nothing resets the position: the original's credits scroll
  away and do not come back.

| Code | Arm | Font | `cX`/`cA` | Rules | Advance |
|---|---|---|---|---|---|
| `0` title | `0x0044BE91` | 1 | `0xFFFF`/`0x632C` | two, *y*+1 and *y*+3, `0x94B2` | 15 |
| `1` heading | `0x0044BF42` | 1 | `0x94B2`/`0x3186` | one, *y*+1, `0x632C` | 15 |
| `2` name, last of its group | `0x0044BFB8` | 0 | `0xFFFF`/`0x632C` | none | 30 |
| `3` | `0x0044BFE8` | — | — | none | 15 |
| `4` name | `0x0044BFB8` | 0 | `0xFFFF`/`0x632C` | none | 15 |

The advance is the **printed line's** own code (`cmp al, 0x32` at
`0x0044BFF1`), so a `2` is what opens the gap in front of the next heading —
`%:162,"2"` is a bare code with no text, an empty group end. A rule is
`fcn.00463D80` case 0: a row of pixels running **left** from *x* 599 for
exactly the width `aGetLibTextLength` measured, i.e. an underline under the
line above it. The shipped bank's 178 lines use codes 0, 1, 2 and 4 only; the
silent arm is unreached.

**The speed is measured, not chosen.** The function's own first call is
`fcn.0047F2E0(20, 20)` — aLIB's frame-rate controller, whose assert names it
*skip controller* (`C:\aProject\aLIB\aWinTools.cpp`) and which busy-waits on
`GetTickCount` at `0x0047F359` until `1000/20` ms have passed. One unit a
frame at 20 frames a second is **20 plate units a second**, and the whole roll
is 3750 units — a little over three minutes.

**These calls pass literal RGB565.** `0xFFFF`, `0x632C`, `0x94B2` and `0x3186`
are the values `0x0043E680` resolves the `GUI_SetText` ramp *indices* to
([`20` §7.4](20-lcl-language.md) — entries 3 and 8 are the two greys); here
they reach `aPrintLibText` already resolved. It is the one call site in the
front end that does, and it does not retro-fit the UNVERIFIED note on the
other screens' `cX`/`cA` columns, which really are indices.

**Two divergences, both stated.** The first is a **group the original does not
have**: a heading and a name saying who made the remake, spliced in after
`Txtmod_a` 161's *Credits* and the empty group end that follows it. It is
written in the roll's own grammar (`"1"` and `"2"` codes, so it is underlined
and spaced like every other group) and comes from `Localization.OWN` rather
than from a literal -- the same seam as every other string `game/` writes that
the original never had to say ([`92` §7.6](92-remake-architecture.md)). It is
the **only** invented text on the screen. It was at the end, which is the
polite place for it; the roll is three minutes long and nobody waits, so it is
the first group instead, with the screen's own heading still above it.

The second: only `cX` is drawn. The engine's font bitmaps
store pixel values 0..4 and `aPrintLibText` writes `cX` for value 1 and `cA`
for value 2 ([`20` §7.4](20-lcl-language.md)); the converted faces are one
colour a glyph, so `font_color` carries `cX` and the second entry of each
line's ramp is read and not rendered.

**Making it move without shimmering took six passes, and only the last one is
a fix rather than a trade.** What the port has that the original does not is a
window of arbitrary size: the plate is stretched over it, so a plate unit is a
*fraction* of a pixel, and every glyph, rule and box lands on its own
sub-pixel offset -- which then changes as the roll moves. The five attempts
that stayed inside that coordinate system each traded one tremble for
another:

1. **A hard rectangle, moved continuously.** One plate unit at 1280x800 is
   five thirds of a pixel, so each rule covered two pixel rows at one offset
   and one at the next: the underlines blinked their way up the screen.
2. **A four-row alpha ramp (`0, 1, 1, 0`) under `TEXTURE_FILTER_LINEAR`**,
   fading a quarter of a unit either side of the engine's own row, so that
   coverage changes continuously with position. The blinking went and this
   stayed -- it is still how a rule is drawn. The fade started at half a unit
   and had to come down: the engine leaves a whole unit of air between a rule
   and the cap height of the name below it.
3. **Rounding the travel to a whole window pixel**, the obvious port of `dec
   dword [0x0050FE1C]`, and wrong twice over: a window pixel is half a
   *rendered* pixel on a display with a backing store, and a step thirty
   times a second is a visible shudder under every name where the ramp hides
   it on the rules.
4. **A whole canvas pixel with the face's sub-pixel positioning off**, so
   that the text server's own rounding becomes a no-op. Better, and still not
   still.
5. **Positioning the roll instead of anchoring it.** An anchor is a fraction
   of the parent, so the roll's *y* went through a divide and a multiply in
   32-bit float, and the error of that round trip changes with the value:
   a line whose position happened to sit near the half-pixel rounded up on
   one step and down on the next while its neighbours did not, so **some**
   names twitched and the rest were still. That is a real defect and the fix
   stands; what was left afterwards was a smaller tremble on all of them.
6. **A [SubViewport] the size of the clip in real pixels.** The roll is laid
   out on *its* pixels, steps a whole one of them, and reaches the screen as
   a picture drawn in the same place every frame with different contents.
   Nothing can shimmer against anything else because there is only one thing.
   The viewport is 2134x1112 for a 768x400 clip on this display, and the
   picture is drawn back at 1:1 in rendered pixels, so it is a copy rather
   than a resampling.

One trap on the way in, worth naming because the screen came up **empty** and
the roll was working perfectly: a [TextureRect] keeps its texture's own size
by default, so `stretch_mode` alone does nothing. The viewport's picture was
drawn at 2134x1112 in the corner of a 768x400 clip and every right-aligned
line sat off the edge of it. `expand_mode = EXPAND_IGNORE_SIZE` is the other
half of the stretch.

Two things the port has to get right that the engine does not, both found by
measuring a frame rather than by reading: `aPrintLibText` prints from the
glyphs' **bottom**, so a [Label] bottom-aligned in its own box hangs its
descent below the anchor and every rule hung off that box lands a descent too
low -- measured as 3.8 units of air above the rule and 0.6 below, where the
engine leaves 1 and 3. The box is dropped by the face's declared descent.
Taking the block's height less its ascent instead -- which looks more
principled -- is wrong, because a [Label]'s block carries the theme's line
spacing: it came out five units too large and put the rule through the
heading.

**What changed.** `godot/game/screens/credits_screen.gd` carries the walk, the
code table and the roll; the layout is a pure `roll_layout()` so `test_shell`
pins it without a clock (27 checks: the 178 lines, the terminator, every
line's code, the title's two rules, the 15/30 advances, the 3750-unit height,
the 410 start, the 20-unit speed, and the tail -- that it is appended without
moving a shipped line, that its heading is underlined like the bank's own and
that both of its strings come from the remake's catalogue, and the underline's fade staying inside the air the original leaves). `seq_parse.py --check` pins the fourteen
constants above out of the executable and is **174** checks where it was 160.
Nothing in the cache changed: `text/<language>.json` has carried the whole
`Txtmod_a` bank since the shell slice, so no `CONVERTER_VERSION` bump and no
republish. **Two debugging entries lead to it.** `--credits` on a bare launch opens the
roll with no campaign behind it, and the agent's `ui credits` raises it over
whatever is up -- both because the only way there in the game is to finish a
chain, and three minutes of moving text cannot be judged by winning one first.
*Back* leaves for the menu either way, exactly as it does after an ending.

Driven through the control server's **debugging entries** rather
than by winning a chain: `campaign 1` starts the state, `enter _C_YYY` writes
the mission and `ui map` runs mission control's entry gate — then a key ends
the animated extro and the 4000 ms hold raises the screen. The roll comes up
the dark half of the plate with its headings underlined and passes behind
*Back* and *Exit Game*.

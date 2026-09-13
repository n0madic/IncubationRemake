# Sequence player

Scope: the complete static contract of `aSeqPlayer.cpp` needed to play the
shipped 3D sequences.  The `.cho` / `.cha` grammars and the 30 fps proof are in
[`40`](40-charisma-model-animation.md); this document specifies how the game
assembles those files into scenes and advances between them.

Artifact: GOG `Incubation.exe`, PE32/i386, preferred base `0x00400000`, SHA-256
`b07aa2478fbfaf252a585cff180d03b468d5141e0fdb5606bd09f0891024fcc9`.
All addresses below are virtual addresses in that image.  The result is
**verified-static**; the original executable was not run.

**Corrected 2026-09-08** (the ninth slice, [`101`](101-slice-9-report.md)):
the "camera/rate string" of §2 and §4 is a **CD track program**, the cameras
are parts named `Cam<n>` chosen by the `Switch` note, `Focus` is a preset table
scaled by the viewport height, and a part's pairs play **one after another**.
The corrections are in place below; the earlier reading is quoted where it
was wrong so the change is visible.

## 1. There is no sequence-description file

`Video/<part>/` contains four resource groups:

* `Objects/Prototyp.{bin,din,dir}` — Eng3d meshes;
* `Textures/Texture.{lib,din,dir}` and `IMG/{ATN,TRIG}.IMG` — rendering data;
* one or more `Model_*.cho` files — Charisma scene models;
* matching `Animation_*.cha` files — their keyframed timelines and event notes.

The missing fifth file is deliberate: **the scene manifest is compiled into
`aSetSeqPlayerVideoPart` (`0x00465CC0`)**.  It constructs four strings for each
pair — model path/name and animation path/name — stores them in a 40-byte
`PlayerSequence` list node, copies the list into the 3D player, and supplies a
**CD track program** such as `"13,30"` (§4).  Thus a replacement should
externalise the table in §2; it must not search the directory and guess
pairings.

The list order is **playing order**: a part's pairs are *shots*, played one
after another, not actors that start together.  The 3D player (`0x0047F6A0`)
answers return code 6 when the current pair's clip has ended and the update
installs the next pair (`0x0047FD00`) in the same call; the clock is a
per-frame delta whose epoch is rewritten on every update (`0x00465ACF`), so
every shot starts at frame 0.  Each pair is one scene -- one model whose parts
are the actors *and* the cameras -- and its ordinary Charisma notes (`Switch
N`, `Focus N`, including the authored spelling and whitespace variants) are
read by the player's own note dispatcher (§4), not by a second timeline.
`BREAK` is not read here at all: `0x0042C5D0`, the note-stop callback, has one
caller, the combat routine ([`40` §9](40-charisma-model-animation.md)).

## 2. Complete logical-id and video-part table

The number passed to `aCreateSeqPlayer` is a **logical sequence id**.  Only
`0, 1, 2, 3, 7, 14, 15` are valid; the compressed 16-entry switches at
`0x0046588C` and `0x00467FC4` reject every other value.  A video part is one row
within that logical id.  Completion automatically increments the part index.

| logical id | part | directory | pair stems (played in order) | CD program |
|---:|---:|---|---|---|
| 0 | 0 | `Seq_1` | `1_1..1_15` | `9,30` |
| 0 | 1 | `Seq_3` | `3_1..3_34` | `10,30` |
| 0 | 2 | `Seq_4` | `4_0, 4_1, 4_3, 4_4` | `11,30` |
| 0 | 3 | `Seq_5` | `5_0, 5_1, 5_2, 5_3, 5_7, 5_9, 5_10` | empty |
| 1 | 0 | `Extro` | `Extro_1..Extro_8` | `19,30` |
| 2 | 0 | `Dialog_02` | `D02` | `12,30` |
| 3 | 0 | `Dialog_03` | `D03_1..D03_9` | `13,30` |
| 7 | 0 | `Dialog_07` | `D07` | `14,30` |
| 7 | 1 | `Dialog_09` | one `Model_D09`, animations `D09_1..D09_18` | `15,30` |
| 14 | 0 | `Dialog_14` | `D14` | `16,30` |
| 15 | 0 | `Dialog_15` | `D15_1..D15_11` | `17,30` |
| 15 | 1 | `Dialog_16` | `D16_1..D16_21` | `18,30` |

For an ordinary stem `X`, the pair is `Model_X.cho` plus `Animation_X.cha`.
`Dialog_09` is the sole exception: its 18 animations all drive the same model.

Two arms are laid out in the reverse of their part order — the `Dialog_09` arm
precedes the `Dialog_07` one, and the `Dialog_16` arm precedes the `Dialog_15`
one — so a program string cannot be attributed by address adjacency alone.  Each
arm ends with `mov edi, <program>` followed by `jmp 0x00467DD5`, the shared tail
that copies the pair list and starts the CD program, so the string belongs to
the arm it *terminates*: `0x0046755D` closes `Dialog_09` with `15,30`, and
`0x00467689` closes `Dialog_07` with `14,30`.  `0x0046755D` is unreachable from
the `Dialog_07` arm, whose entry is `0x00467567`, past that jump.

The hard-coded table also explains eleven files that directory enumeration
would get wrong: `Dialog_16/Model_D16_01..09.cho` are ignored in favour of the
unpadded `D16_1..9` models, and the misspelled
`Seq_3/Animaton_3_6.cha` / `Animmation_3_18.cha` are never loaded.  The selected
manifest contains **130 pairs -- 113 distinct models and 130 animations** --
across **12/12** directories.

## 3. Lifecycle and state machine

The public surface and its private update are:

| address | operation |
|---|---|
| `0x004653E0` | `aCreateSeqPlayer(x, y, width, height, logicalId)` |
| `0x004658A0` | return the active flag |
| `0x004658B0` | update/render one frame into the supplied surface |
| `0x00465B70` | `aStartSeqPlayer()` |
| `0x00465C00` | `aDestroyPlayer()` |
| `0x00465CC0` | load the current video part |

Create refuses a second active player, sets `active=1`, `running=0`,
`newPart=0`, creates the viewport, selects the resolution-dependent rectangle,
initialises the pure 3D engine with that part's `Objects`, `Textures`, and `Img`
roots, and stores `logicalId`.  The mission-control caller at `0x0045711F`
passes `(x,y,w,h,id)`; the full-screen path is `0,0,640,480`, and the framed
path is `65,57,518,306`.  It also constructs the player's camera object
(`V100Camera` "Main camera"/"Film", `0x0047F3C0`, through `0x004652C0`) with a
**focal length of `_ftol(width * 10/13)`** -- `fmul qword [0x004B1570]` in both
branches, the same rule as `_E3D_init_3d_screen`'s -- so a sequence opens at
492 pixels full screen and 398 framed until a `Focus` note says otherwise.

Start refuses an inactive or already-running player, sets `running=1`, resets
`part=0`, and loads part zero.  Loading a part clears the previous actor list;
parts that change directories first shut down and reinitialise the pure 3D
engine.  It then creates the actors, resets the list iterator, installs the
first pair's model and animation in the renderer, increments `part`, and sets
`newPart=1` when a non-empty CD program is installed.  "Non-empty" is
literal: the tail compares the installed string against the zero-initialised
global `0x004FA524`, and the `Seq_5` arm is the one that loads exactly that
global, so `Seq_5` is the only part that does not raise `newPart` -- and the
only one that starts no CD program, which leaves `Seq_4`'s track playing.
Installing a pair (`0x0047FD00`) resets the camera index to 1
(`mov dword [esi+4], 1` at `0x0048023B`) and does **not** touch the focal
length, which therefore carries across a part's shots.

The update at `0x004658B0` does nothing until both active and running are true.
On `newPart`, it resets the wall-clock epoch.  Every update computes
`dt = (GetTickCount() - epoch) * 0.03`, i.e. animation frames at **30 fps**, and
passes that delta plus the target surface to the 3D player (`0x0047F6A0`).
Return code `6` means the current pair's clip ended: advance to the next
node, install its four strings and update again.  Past the list end, call
`aSetSeqPlayerVideoPart`; if no next part exists, update returns false and the
GUI exits the sequence screen.  Other renderer return codes keep the current
part running.

### 3.1 One update of the 3D player, and where a frame-0 note lands

*(2026-09-13; closes §7 item 2, verified-static.)* `0x0047F6A0(surface, dt)`
is one update of the player, and its body runs in this order:

1. **the ended test** — the pair's `KeyFramedAnimationInterface` (reached by
   `__RTDynamicCast` at `0x0047F6F3`) is asked whether its clip has ended;
   if so, or if the ended flag `+0x30` is already up, the update returns `6`
   **without drawing** — so the pair's last picture is the one the previous
   update drew at the clamped end time;
2. **`IWorld::Simulate(dt, 0)`** on the `"Film"` world — vtable slot `0x40`
   at `0x0047F76B`, the same slot the mission's 3D-view refresh calls at
   `0x00407112` ([`42` §1.3](42-mission-presentation.md));
3. the viewport, the **`Cam<n>` lookup** by the index `+0x04` holds *now*
   (§4.2), and the render — slot `0x38` at `0x0047F82D`.

Simulate is where the notes go off. Installing a pair (`0x0047FD00`) wraps
two member functions in `PlayerCallback` objects (`0x00480760`) and registers
them on the world through slot `0x50`: kind 1 is the **note dispatcher
`0x00480300`** (the `Switch`/`Focus`/`Fade` reader of §4.2–4.3) and kind 0 is
`0x00480730`, which does nothing but raise the ended flag `+0x30`. The install
starts the clip through the interface's slot `0x2C` at speed 1.0
(`0x00480178`); nothing rewinds it because `KeyFramedAnimation::Init`
(`0x004A0B99`) left the clock at 0. The world is a `StdWorld` (vtable
`0x004B32A4`; slot `0x40` is `Simulate` `0x00497BA2`, slot `0x50` the
registrar `0x00497D1A`, which files `{kind, actor, callback}` at `+0x24`),
and one step of its Simulate is three calls in order: `0x004980C7` asks every
registered entry's event source for the events inside the step
(`call [eax+0x28]` at `0x0049817A` — `0x004A1220`, [`40`
§9](40-charisma-model-animation.md)'s collector, with that entry's kind),
`0x00497FF1` advances the animations, and `0x004986A7` dispatches each
collected event through the callback's slot `0x0C` at `0x00498770` —
`PlayerCallback`'s trampoline `0x004807A0` into the member function. The
collector's window is
`(start, end]` **except while the clock reads exactly 0.0**: a note at
`t <= start` is skipped only when the current time differs from
`[0x004B31C8]` (`fcomp` at `0x004A16C0`), so at time 0 the window is
`[0, end]` and a frame-0 note is collected by the first Simulate after the
install. That Simulate precedes the render in the same update, and the
render reads the camera index the dispatcher has just written.

So the answer to "does the original draw one frame through `Cam1` before a
frame-0 `Switch`" is **no**: the note fires inside the pair's first update,
before that update's picture. The remake's `SequencePlayer._install_shot`
fires the frame-0 notes at install and then poses, which is the same order.
`seq_parse.py --check` pins the chain (`notes.simulate_before_render`,
`notes.simulate_is_the_missions_slot`, `notes.simulate_collects`,
`notes.start_at_speed_one`, `notes.callbacks`,
`notes.zero_start_is_inclusive`).

One small thing the same read turned up, recorded rather than chased: the
epoch `0x005142A0` is rewritten at the **end** of every update
(`0x00465ACF`), and the second update a pair change makes in the same GUI
frame (`0x00465A62`) computes its `dt` from that previous epoch. A new pair's
first Simulate therefore advances by roughly one frame interval, so the
engine's first drawn pose of a pair sits at about one key unit, not at 0.
The remake draws frame 0; the difference is one 30 fps frame of pose and no
note.

Destroy stops the renderer, restores the render bounds, clears `running` and
`active`, destroys the viewport and actor list, and exits the pure 3D engine.
Calling it inactive is an error.  Mission control calls it on leaving the
screen (`0x004571AE`) and then returns to the campaign/map flow.

## 4. The CD program, the cameras, the Focus table, sound and input

### 4.1 `"13,30"` is a CD track program, not a camera path

*(Corrected 2026-09-08.  This section used to read the string as "the authored
sequence-camera path `9..19`" with `30` "matching the 30 fps proof".  Neither
half survives the tail.)*

The shared arm tail `0x00467DD5` copies the string to `0x00514288`
(`mov edi, 0x514288` at `0x00467F15`), calls `0x0042BE50` (`MCI_STOP`) and
`0x0042BD80` (`MCI_OPEN cdaudio`), then `0x0042C120`, then
**`0x0042C040(0x514288)`** at `0x00467F33` -- the `CDTrackProgram` parser of
[`20` §7.3](20-lcl-language.md), whose `strtok` separators are the nine bytes
at `0x004C2768`, `" .,|;:*+/"` -- and finally `0x0042BC10`, which plays the
list's current entry.  A token above the disc's track count (`[0x004FE688]`)
parses to `-1`, and `0x0042BC10` **wraps the cursor to entry 0 on a negative
entry**, so `"9,30"` loops CD track 9 for ever and the `30` is a deliberately
out-of-range terminator.  The 30 fps clock is proven by `0.03` at
`0x004B157C` alone.

Every non-empty program is one track and the terminator, tracks 9..19, one
per part, and `Seq_5`'s empty string keeps `Seq_4`'s track 11 playing.  The GOG
release's `Arack` family stops at 14 ([`28` §6.1](28-effects-and-sound.md)), so
the shipped build is **silent** through `Dialog_09` (15), `Dialog_14` (16),
`Dialog_15` (17), `Dialog_16` (18) and `Extro` (19); the `Track` family runs to
20 and covers all eleven, which is what the remake plays for the cutscenes
([`92` §7.19](92-remake-architecture.md)).

### 4.2 The cameras are parts named `Cam<n>`

The note dispatcher of `0x0047F6A0` pushes the literal `"Cam"` (`0x004CD388`,
at `0x0047F7BB`), appends the current camera index with `itoa` and
`String::AppendSubstring` (`0x0047F7C0..0x0047F7EA`) and looks the part up by
that name; `Switch n` writes the index.  The player's own `V100Camera` "Main
camera" is the object that gets attached to it.  Corpus: **all 113 models carry
`Cam1`**, `Model_D09` carries `Cam1..Cam8`, and **all 55 `Switch` notes** name
a `Cam<n>` node of their own model (`seq_parse.py --check`, `notes.*`).

### 4.3 `Focus f` is a focal length in pixels for a 480-row screen

At `0x004804BB` the dispatcher reads `f` with `atof`, computes `_ftol(f) - 24`
and, when that is in `0..176` (an *unsigned* compare at `0x004804E8`, so
anything under 24 takes the default too), indexes the byte table at
`0x00480670` and jumps through the eight-entry table at `0x00480650`:

| `f` | 24 | 28 | 35 | 50 | 85 | 135 | 200 | anything else |
|---|---|---|---|---|---|---|---|---|
| focal at 480 rows | 400 | 500 | 613 | 877 | 1477 | 2350 | 3500 | **765** |

The result is then multiplied by the viewport's height over 480 --
`[ebp+0x40]` compared against 480 and 240, the **f32** reciprocals `1/240` at
`0x004B1690` and `1/480` at `0x004B1694` -- and stored at `[ebp+0x58]`; the
`[ebp+0xC]` arm halves the preset first and uses `1/240`, and the sequence
player never takes it (its constructor receives `push 0` for that argument).
The shipped clips ask for 24, 28, 35, 43 and 50 and nothing else (138 notes;
the most common, 43, is the default 765).  `Fade n` (`0x0048059C`, 0..100)
exists in the dispatcher and no shipped clip uses it.

### 4.4 Sound and input

There is **no speech or subtitle scheduler in `aSeqPlayer.cpp`**.  None of the
12 video directories contains a wave or text file, and the manifest nodes carry
only the four model/animation strings.  Dialogue/info boxes remain the LCL
mechanism described in [`20` §5.2](20-lcl-language.md) and [`24`](24-briefing-text.md),
not timed sequence subtitles.  The one sequence-adjacent soundtrack is the
epilogue: mission control's separate `0x00457430` path loads `ship.bmp` and
plays `Briefing/extro.wav` in a static extro screen; it bypasses
`aCreateSeqPlayer`.  A replacement should play that wave there, not derive
audio timing from the `Video/Extro` animations.

The GUI owns presentation and input.  Its screen-8 arm calls the update each
frame, scales/blits either the full-screen or framed viewport, and treats a
renderer/update failure as completion.  The framed presentation installs a
background callback (`0x00456F30`, at `0x00457047`) that paints `plate_7` and
text 0 of the loaded bank -- *Please Wait...* -- at (320, 210).  **One key or
click ends the whole sequence**, not a part: the GUI loop's `WM_LBUTTONDOWN`
arm (`0x004555E6`, `cmp di, 0x201`) and its key arm both call `0x00457180`
while window 8 is up, and that routine destroys the player.  Its two exits are
mission id 255 -- `Sleep(4000)` and the credits flag `0x0044BC60(1)`, with no
destroy of its own -- and everything else: `aDestroyPlayer`, `Sleep(1000)`,
back to mission control's map (`0x00457590`).  Those holds and the front end
around them are [`92` §7.19](92-remake-architecture.md)'s.

## 5. Trigger side

[`27` §2.3](27-campaign.md) establishes the campaign mapping: locations
`10, 11, 12..15, 16..21, 22, 23` pass logical ids
`2, 3, 7, 1, 14, 15` respectively to `0x00456FC0`.  Logical id `0` is the
special four-part `Seq_1/3/4/5` intro path; id `1` selects the animated
`Video/Extro` scene despite there being no `Dialog_01`.  Value `16` is not a
sequence-player id: `0x00456FC0` intercepts it and enters the separate static
extro screen described in §4.  The directory mapping and the otherwise
unexplained `Dialog_09`/`Dialog_16` transitions are now closed by §2.

### 5.1 The credits screen is a roll, and it is in the executable

Both endings hand over to window 15, `Menu_a.lcl`'s `:Credits;` block, which
carries two `GUI_SetButton` calls and nothing else.  The credits themselves
are drawn by `fcn.0044BD90`, which the menu's draw loop `fcn.0044B5E0` calls
on every frame the window selector `[0x0050FDF8]` is 15 (`0x0044B691`).

`0x0044C050` writes the scroll position `[0x0050FE1C] = 410` before the loop
starts; the walk clips to `(0, 0, 640, 400)`, reads `Txtmod_a` from string
**161** until one equals `"END"` (339 in the shipped bank, so 178 lines),
prints each right-aligned at *x* 600, and decrements the position by one at
the end of the frame (`0x0044C026`).  Its first call is `fcn.0047F2E0(20, 20)`
-- aLIB's frame-rate controller, which busy-waits on `GetTickCount` until
`1000/20` ms have passed -- so the roll moves **20 units a second**.

Every line's first character is a code, a five-arm `switch` on `byte - '0'`
with its jump table at `0x0044C03C`; the rest of the line is printed.

| Code | Font | `cX`/`cA` | Rules | Advance |
|---|---|---|---|---|
| `0` title | 1 | `0xFFFF`/`0x632C` | two, *y*+1 and *y*+3, `0x94B2` | 15 |
| `1` heading | 1 | `0x94B2`/`0x3186` | one, *y*+1, `0x632C` | 15 |
| `2` name, last of its group | 0 | `0xFFFF`/`0x632C` | none | 30 |
| `3` | — | — | none | 15 |
| `4` name | 0 | `0xFFFF`/`0x632C` | none | 15 |

The advance is the printed line's own code (`cmp al, 0x32`, `0x0044BFF1`), so
a `2` opens the gap in front of the next heading; `%:162,"2"` is an empty
group end that exists for exactly that.  A rule is `fcn.00463D80` case 0 -- a
row of pixels running **left** from *x* 599 for the width `aGetLibTextLength`
measured, an underline under the line above it.  Nothing resets the position:
the roll scrolls away and does not come back.

The remake appends a heading and a name of its own after the bank's last
line, in the same grammar; that is a deliberate divergence and is recorded in
[`101` §14](101-slice-9-report.md), not here -- the shipped roll is 178 lines
and ends at `Txtmod_a` 338.

These calls pass **literal RGB565** rather than the ramp indices
[`20` §7.4](20-lcl-language.md) documents for `GUI_SetText`; `0x632C` and
`0x3186` are what `0x0043E680` resolves indices 3 and 8 to.

## 6. Mechanical verification

```sh
python3 tools/seq_parse.py --check gog_incubation
python3 tools/seq_parse.py gog_incubation
python3 tools/seq_parse.py --json gog_incubation
```

The checker is fail-closed over the executable dispatch/lifecycle/timing
anchors, the exact 12-directory corpus, every selected model/animation pair,
all expected ignored lookalikes, and full parsing of all 130 selected `.cha`
files through the existing Charisma parser.  Since 2026-09-08 it also pins
§4: the tail's four calls and the copy to `0x00514288`, the separator set, the
wrap in `0x0042BC10`, every program parsing to one track in 9..19 plus the
terminator with its `Track%02d.ogg` present; the `"Cam"` literal, the
per-pair index reset and the `10/13` construction focal; the Focus table read
out of the byte and jump tables with its seven presets, default, bounds and
reciprocals; every `Switch` resolving to a `Cam` node and every model carrying
`Cam1`; and the front end around the sequences (`FRONTEND`: the five CD
programs, the three holds, the splash, the credits flag, the static extro, the
message screen, the gate and the intro flag, the exit's two arms, the two
viewports and the briefing's typewriter), and since 2026-09-10 the credits
roll of §5.1 -- the window gate and the per-frame call, the 410 start and the
one-unit step, the 20 fps limiter, the clip, the first string id and the
terminator, the five-arm jump table, the two advances, the three printing
arms with their fonts and colours, and the underlines' own call.  `--manifest` prints the two
documents the converter copies into the cache.  Current result: **174/174
checks, 12/12 directories, 130/130 animations**.

Four checks per arm carry §2, because file existence alone would be satisfied
by any table recovered by listing `Video/`:

* `arm.<dir>.strings` — the `push <template>` instructions, by address, with the
  template text each pushes;
* `arm.<dir>.camera` — the `mov edi, <camera>` that closes the arm, by address;
* `arm.<dir>.contiguous` — no other arm's `jmp` to the tail lies between the
  arm's first push and its camera load, which is what makes the pairing above a
  proof rather than an assumption;
* `arm.<dir>.bound` — the `cmp reg, imm8` closing a looping arm, against the
  last stem index.  Unrolled arms have no bound and are pinned instead by one
  push pair per stem, which is what fixes `Seq_4`'s and `Seq_5`'s gaps.

Native rendering, pixel output, DirectX device behaviour, and interactive skip
timing remain outside the verified-static claim.

## 7. Open questions

1. ~~**The camera bone's roll.**~~ **Closed** (2026-09-09) — measured against
   the scenes themselves.  Which of a `Cam<n>` part's local axes the authoring
   tool looked along is not in the data ([`40`
   §10.1](40-charisma-model-animation.md)), so both halves of the convention
   are measurements.

   The **forward** axis: over all 130 shots at four frames each (520 poses)
   the mean joint of the drawn parts lies along the bone's engine +Y in 514,
   with a mean cosine of 0.90, and every other axis is near 0.5.

   The **roll** about it: every shipped cutscene is a built world with a sky
   above it, so a bone frame carrying a quarter or a half turn would hold that
   world on its side or upside down, and a joint centroid would never notice.
   The lens' own up is therefore compared with the scene's: over 260 poses
   (130 shots at two frames) the camera's +Y after
   `WorldSpace.engine_matrix` lies within 46° of the world's up in **240**, a
   share of 0.92.  A quarter turn puts that share at zero and a half turn puts
   it below it, so the bone's frame carries neither, and the remake takes the
   bone's engine +Z as up unchanged.  `test_sequence.gd` re-measures both
   (`camera.joints_in_front_of_the_lens`, `camera.up_is_the_world_s_up`).

   **The small roll is measured too** *(2026-09-09)*, and the crude 46° test
   above was only ever a check that the frame carries no quarter or half turn.
   The roll of one pose is a number, not a share: take the world up with the
   forward component removed — what an unrolled camera's own up would be —
   and the signed angle from it to the bone's own engine +Z.  Over all 130
   shots at **nine** frames each, 2547 poses (the near-vertical ones, where
   every roll is the same picture, drop out):

   | | |
   |---|---|
   | median roll | **0.000°** |
   | within 0.5° | 1884 / 2547 (74 %) |
   | within 2° | 2174 / 2547 (85 %) |
   | within 10° | 2461 / 2547 (97 %) |
   | extremes | −90.6° … +24.6° |

   So the bone is authored **upright**, exactly, in the median pose, and the
   tail is a real and small set of deliberately banked shots rather than a
   convention this project has failed to find.  Nothing in the remake decides
   it either way: `SequencePlayer` takes the bone's whole basis
   (`CAMERA_BASIS_FIX` is the identity), so whatever roll is authored is what
   is drawn, and the only thing that had to be right is the forward axis
   above.  `seq_parse.py --check` pins the three numbers
   (`camera.roll_median_is_zero`, `camera.roll_is_mostly_none`,
   `camera.roll_tail_is_small`), so this needs no Wine capture and never did.

2. ~~**Whether a note at frame 0 fires before the pair's first frame is
   drawn.**~~ **Closed** (2026-09-13) — §3.1. It does: one update of
   `0x0047F6A0` is Simulate, then the `Cam<n>` lookup, then the render, and
   the note collector keeps a `t <= start` note while the clock reads exactly
   0, so the frame-0 `Switch` is applied inside the pair's first update and
   before its picture. No frame is drawn through `Cam1`; the remake's
   install-time firing is the engine's order. Verified-static, pinned by
   `seq_parse.py`'s `notes.*` checks; the `presentation_gold.py` phase this
   entry asked for is not needed.

Two things are **closed** that this section used to call decisions:
~~"what the camera ids `9..19` select"~~ -- they are CD tracks (§4.1), not
camera ids; and ~~"presentation and input live outside this module"~~ -- they
do, and they are now specified in §4.4 and [`92`
§7.19](92-remake-architecture.md) rather than left to the GUI.

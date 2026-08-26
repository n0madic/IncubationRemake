# Sequence player

Scope: the complete static contract of `aSeqPlayer.cpp` needed to play the
shipped 3D sequences.  The `.cho` / `.cha` grammars and the 30 fps proof are in
[`40`](40-charisma-model-animation.md); this document specifies how the game
assembles those files into scenes and advances between them.

Artifact: GOG `Incubation.exe`, PE32/i386, preferred base `0x00400000`, SHA-256
`b07aa2478fbfaf252a585cff180d03b468d5141e0fdb5606bd09f0891024fcc9`.
All addresses below are virtual addresses in that image.  The result is
**verified-static**; the original executable was not run.

## 1. There is no sequence-description file

`Video/<part>/` contains four resource groups:

* `Objects/Prototyp.{bin,din,dir}` — Eng3d meshes;
* `Textures/Texture.{lib,din,dir}` and `IMG/{ATN,TRIG}.IMG` — rendering data;
* one or more `Model_*.cho` files — Charisma scene models;
* matching `Animation_*.cha` files — their keyframed timelines and event notes.

The missing fifth file is deliberate: **the scene manifest is compiled into
`aSetSeqPlayerVideoPart` (`0x00465CC0`)**.  It constructs four strings for each
actor — model path/name and animation path/name — stores them in a 40-byte
`PlayerSequence` list node, copies the list into the 3D player, and supplies a
camera/rate string such as `"13,30"`.  Thus a replacement should externalise
the table in §2; it must not search the directory and guess pairings.

The list order is actor order.  All actors in a part start together.  Their
ordinary Charisma notes (`Switch N`, `Focus N`, including the authored spelling
and whitespace variants) remain part of each `.cha` and are handled by the
shared animation engine, not by a second sequence timeline.

## 2. Complete logical-id and video-part table

The number passed to `aCreateSeqPlayer` is a **logical sequence id**.  Only
`0, 1, 2, 3, 7, 14, 15` are valid; the compressed 16-entry switches at
`0x0046588C` and `0x00467FC4` reject every other value.  A video part is one row
within that logical id.  Completion automatically increments the part index.

| logical id | part | directory | loaded actor stems | camera/rate |
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
one — so a camera string cannot be attributed by address adjacency alone.  Each
arm ends with `mov edi, <camera>` followed by `jmp 0x00467DD5`, the shared tail
that copies the actor list and installs the camera, so the string belongs to the
arm it *terminates*: `0x0046755D` closes `Dialog_09` with `15,30`, and
`0x00467689` closes `Dialog_07` with `14,30`.  `0x0046755D` is unreachable from
the `Dialog_07` arm, whose entry is `0x00467567`, past that jump.

The hard-coded table also explains eleven files that directory enumeration
would get wrong: `Dialog_16/Model_D16_01..09.cho` are ignored in favour of the
unpadded `D16_1..9` models, and the misspelled
`Seq_3/Animaton_3_6.cha` / `Animmation_3_18.cha` are never loaded.  The selected
manifest contains **130 actor entries and 130 animations** across **12/12**
directories.

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
path is `65,57,518,306`.

Start refuses an inactive or already-running player, sets `running=1`, resets
`part=0`, and loads part zero.  Loading a part clears the previous actor list;
parts that change directories first shut down and reinitialise the pure 3D
engine.  It then creates the actors, resets the list iterator, installs the
first actor's model and animation in the renderer, increments `part`, and sets
`newPart=1` when a non-empty camera string is installed.  "Non-empty" is
literal: the tail compares the installed string against the zero-initialised
global `0x004FA524`, and the `Seq_5` arm is the one that loads exactly that
global, so `Seq_5` is the only part that does not raise `newPart`.

The update at `0x004658B0` does nothing until both active and running are true.
On `newPart`, it resets the wall-clock epoch.  Every update computes
`dt = (GetTickCount() - epoch) * 0.03`, i.e. animation frames at **30 fps**, and
passes that delta plus the target surface to the 3D player (`0x0047F6A0`).
Return code `6` means the current actor/list item ended: advance to the next
node, install its four strings and update again.  Past the list end, call
`aSetSeqPlayerVideoPart`; if no next part exists, update returns false and the
GUI exits the sequence screen.  Other renderer return codes keep the current
part running.

Destroy stops the renderer, restores the render bounds, clears `running` and
`active`, destroys the viewport and actor list, and exits the pure 3D engine.
Calling it inactive is an error.  Mission control calls it on leaving the
screen (`0x004571AE`) and then returns to the campaign/map flow.

## 4. Camera, sound, subtitles, and input boundaries

The second element of every non-empty camera string is `30`, matching the
independent `0.03 frames/ms` playback proof.  The first element selects the
authored sequence-camera path (`9..19`).  These paths belong to the 3D scene;
they are not `aGetCameraPath(0..4)` from `aAnimations.cpp`, which is a separate
gameplay-camera helper.

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
renderer/update failure as completion.  Mouse/keyboard dismissal and the
subsequent one-second transition delay live in mission control, outside the
sequence player.  Package G does not require reproducing those widgets.

## 5. Trigger side

[`27` §2.3](27-campaign.md) establishes the campaign mapping: locations
`10, 11, 12..15, 16..21, 22, 23` pass logical ids
`2, 3, 7, 1, 14, 15` respectively to `0x00456FC0`.  Logical id `0` is the
special four-part `Seq_1/3/4/5` intro path; id `1` selects the animated
`Video/Extro` scene despite there being no `Dialog_01`.  Value `16` is not a
sequence-player id: `0x00456FC0` intercepts it and enters the separate static
extro screen described in §4.  The directory mapping and the otherwise
unexplained `Dialog_09`/`Dialog_16` transitions are now closed by §2.

## 6. Mechanical verification

```sh
python3 tools/seq_parse.py --check gog_incubation
python3 tools/seq_parse.py gog_incubation
python3 tools/seq_parse.py --json gog_incubation
```

The checker is fail-closed over the executable dispatch/lifecycle/timing
anchors, the exact 12-directory corpus, every selected model/animation pair,
all expected ignored lookalikes, and full parsing of all 130 selected `.cha`
files through the existing Charisma parser.  Current result: **75/75 checks,
12/12 directories, 130/130 animations**.

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

Nothing is open at the replacement-contract boundary: the manifest, the
lifecycle, the timing and the trigger are all pinned to the image, and the
speech/subtitle question is closed negatively in §4.

Two things are **decided rather than unknown**, and are recorded here so the
absence of an entry is not mistaken for an oversight:

1. **What the camera ids `9..19` select** is a property of the 3D scene, not of
   `aSeqPlayer.cpp`.  The player passes the string through; the path itself
   lives in the Eng3d side and belongs to [`30`](30-eng3d-ascii-formats.md) /
   [`31`](31-prototyp-geometry.md) if it is ever wanted.  A remake that supplies
   its own camera never needs it.
2. **Presentation and input** — the scaling blit, the dismissal key and the
   one-second transition delay — live in the GUI and mission control, outside
   this module, and are deliberately out of package G's scope (§4).

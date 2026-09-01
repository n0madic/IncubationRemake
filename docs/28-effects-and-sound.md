# Effects and sound

The two subsystems that make a shot look and sound like something: **`aBlobs.cpp`**,
the particle and debris system, and **`aDSound.cpp`** plus its three
`aAnimations.cpp` wrappers, the sound layer. They are documented together
because they fire from the same place — `aPlayFightAnimation` and the
`aPlay*Sequence` routines create a blob and load a wave in the same few
instructions — and because a remake needs both to reproduce one event.

Everything here is checked by `tools/blob_tables.py --check` (407 checks).

**What this document does not own.** The animation *selection* rules — which
Charisma animation plays for moving, firing or standing, and what the `BREAK`
note does — are [`40` §7.2 and §9](40-charisma-model-animation.md). The tables
this document reads are [`21`](21-info-lcl-schema.md)'s: `SetVolumeCtrl`, the
weapon record and its wave-name field at `+0x25`, the unit record's type byte
and the unit-info record's species byte. The damage resolver that decides
*whether* an effect fires is [`22` §7](22-combat-and-visibility.md); the
set-piece sequences that own several of the call sites below are
[`26`](26-interaction.md) and [`20` §7.3](20-lcl-language.md), and the
`CreateBGB` emitter is [`20` §7.3](20-lcl-language.md) as well. Music volume and
the speaker-position option are [`20` §8](20-lcl-language.md).

---

## 1. The sound layer

### 1.1 Twenty buffers, and a twenty-first that can never play

`aDSound.cpp` keeps a fixed array of DirectSound buffer records at
`0x0050491C`, stride **152 bytes**. Four routines address it, and they do not
agree on how many slots there are:

| Routine | Address | Bound | Slots |
|---|---|---|---|
| `aDirectSoundLoadSoundBuffer` | `0x00436B60` | `cmp cl, 0x14` / `ja` | 0…20 |
| `aDirectSoundPlay` | `0x00436EF0` | `cmp eax, 0x13` / `jg` | 0…**19** |
| `aDirectSoundSet` | `0x00436FD0` | `cmp eax, 0x14` / `jg` | 0…20 |
| `aDirectSoundKillSoundBuffer` | `0x004370D0` | `cmp eax, 0x14` / `jg` | 0…20 |

The loader will hand out slot 20 when the first twenty are busy, and the play
routine then rejects it with `invalid soundbufferid`. **Slot 20 is allocated,
filled, freed — and never heard.** A remake should size the pool at twenty.

Record layout, from the loader's own stores:

| Offset | Field |
|---|---|
| `+0x00` | in use — non-zero marks the slot taken |
| `+0x04` | the wave's full path, copied in |
| `+0x68` | `LPDIRECTSOUNDBUFFER` |
| `+0x6C` | `DSBUFFERDESC`: `dwSize = 0x14`, `dwFlags = 0xE2` |
| `+0x88` | frequency, as last set |
| `+0x8C` | volume, as last set |
| `+0x90` | pan, as last set |

`aDirectSoundSet(what, slot, value)` writes one of the three: `what` 0 is
frequency (vtable `+0x3C`), 1 volume (`+0x40`), 2 pan (`+0x44`).

### 1.2 The idiom, and the three wrappers

Every in-game sound is one sequence: **load a named wave into a free slot, play
it, kill the slot.** `aAnimations.cpp` owns thin forwarders for all three, and
they are what the effect code calls:

| Wrapper | Address | Forwards to | Call sites |
|---|---|---|---|
| `aAnimationCreateSoundBuffer` | `0x004176C0` | `aDirectSoundLoadSoundBuffer` | 62 |
| `aAnimationSoundPlay` | `0x00417710` | `aDirectSoundPlay` | 58 |
| `aDirectSoundKillBuffer` | `0x00417750` | `aDirectSoundKillSoundBuffer` | 55 |

`aDirectSoundLoadSoundBuffer` has seventeen call sites of its own. One is the
wrapper's own forwarding call; the other **sixteen** are outside
`aAnimations.cpp` — the interface clicks, the speech player, the briefing
voice-over (§2.1).

The loader's signature, recovered from its stores and from every call site:

```
aAnimationCreateSoundBuffer(int *slotOut, const char *path,
                            int flags /* always 2 */,
                            int baseVolume, int volumeCtrlId)
```

`path` is always built by `0x004632B0(dirId, name)`, which is
`sprintf(buf, "%s%s", directory(dirId), name)`; every sound in this document
passes **dirId 8**, `Waves\`. `baseVolume` is always the global FX volume,
`0x00460440` → `0x005129E4`, the options field [`20` §8](20-lcl-language.md)
documents.

### 1.3 The volume-control table, and the exact attenuation

`volumeCtrlId` selects a percentage from the 121-entry table at `0x00504638`
that `SetVolumeCtrl` fills ([`21` §1](21-info-lcl-schema.md)). `0x00437480`
turns the pair into a DirectSound attenuation:

```
if (baseVolume < -2000)            return -10000;          // silence
attenuation = baseVolume + 20 * percent - 2000;
if (attenuation > 0) attenuation = 0;
return attenuation;
```

So a percentage of 100 leaves the base volume untouched and every point below
that costs **0.2 dB**. An id of `-1` means "no scaling": the base volume is
passed through unchanged. Any other value outside 0…119 is rejected at load
with `invalid volume ctrl id`.

The bound is inconsistent by one, again: the setter and the scaler accept ids
0…**120** (`cmp eax, 0x78` / `jg`), the load path only 0…**119**
(`cmp eax, 0x78` / `jge`). `Info.lcl` stops at 102, so nothing shipped hits it.

`Info.lcl` defines **103 ids, 0…102**. All but seven are 100 %:

| id | % | id | % |
|---|---|---|---|
| 62 (`mhuman.wav`) | 50 | 92 (`malien.wav`) | 50 |
| 90 (`mcombot.wav`) | 80 | 93 (`msqueether.wav`) | 50 |
| 91 (`mdecther.wav`) | 50 | 96 (interface) | 70 |
| | | 102 (`moveland.wav`) | **101** |

Id 102 is over unity. The formula clamps the result at 0, so the effect is
nothing — it is a typo, not a boost.

---

### 1.4 What starts a sound, and what stops it — the sequences block

Every `aPlay*Sequence` and `aPlay*Animation` routine is **blocking**: it does
not queue an animation and return, it runs the animation itself in a loop whose
body calls the frame tick `0x0040B6F0` once per displayed frame (70 call sites
across the game — it pumps the message queue and draws). `aDoorOpenSequence`'s
tail is the shape all of them have:

```c
aAnimationCreateSoundBuffer(&slot, "Waves\door.wav", 2, fxVolume, 67);
aAnimationSoundPlay(slot, 1);                 /* 1 = DSBPLAY_LOOPING */
for (n = 10; n; n--) { move the door; frameTick(); }
aDirectSoundKillBuffer(slot);
```

So the answer to "on which frame does a sound play" is structural rather than
tabulated: **a sound's lifetime is its sequence's.** It is started at a fixed
point in the routine's straight-line code and killed when the routine returns.
Measured in frame ticks issued ahead of it, **39 of the 58 play sites fire
before the routine's first tick**, 9 after one, 6 after two and 4 after three —
never more. (A tick inside a preceding `do/while` runs its loop count times, so
those small numbers are a lower bound on the wall-clock frame, not the frame
itself; what is exact is that no sound waits on a counter or a threshold.)

The second argument is the DirectSound play flag: **1 = `DSBPLAY_LOOPING`, 0 =
one-shot.** Nine sites loop, and they are all machinery whose sequence outlasts
its sample: `MoveWorld`, `aDoorOpenSequence`, `Bridge`,
`aPlayElevatorSequence`, `aPlayPlatformSequence`,
`aPlayRotateStatueSequence`, the land mover `0x00414360`, the bomber
`0x00415E90` and the teleporter effect `0x00416470`. The other 49 fire once.


## 2. The event → wave table

The 62 `aAnimationCreateSoundBuffer` sites, grouped by the routine that owns
them. `@n` is the volume-control id; `@(computed)` marks the three sites that
build the id at run time (§3, §4.1 and §5). Regenerate with
`python3 tools/blob_tables.py --waves gog_incubation`.

| Routine | Waves |
|---|---|
| `aPlayFightAnimation` `0x0040BD70` | `%s.wav` @(computed); `ricochet.wav` @80; `explosion2.wav` @81; `aexplosion.wav` @95; `S_HUM_0.wav` @(computed); `explosion2.wav` @81 |
| `aStartWalkAnimationSound` `0x0040E640` | (computed) @(computed) |
| `MoveWorld` `0x0040F230` | `platform.wav` @74; `platform2.wav` @75 |
| `aPlayWeaponExplosionAnimation` `0x0040F420` | `damage.wav` @65; `jammed.wav` @64; `explosion.wav` @63 — see §2.3 |
| `aPlayPoisonAnimation` `0x0040F8F0` | `jammed.wav` @64 |
| `aPlayHealAnimation` `0x0040FBE0` | `heal.wav` @85 |
| `RotatingCamera` `0x0040FF30` | `skill.wav` @73 |
| `0x00410190` (from the resolver `0x0046B450`) | `skill.wav` @73 |
| `0x004104A0` (from `0x0046CCA0`, [`25` §6](25-turn-and-round.md)) | `jammed.wav` @64 |
| `0x00410780` (the pickup sequence, [`26`](26-interaction.md)) | `box.wav` @66 |
| `aDoorOpenSequence` `0x00410A20` | `door.wav` @67 |
| `Bridge` `0x00410DA0` | `drawbridge.wav` @79 |
| `OpenTube` `0x00410F10` | `tube.wav` @71; `air_current.wav` @72 |
| `OpenPlantTube` `0x00411150` | `planttube.wav` @71 |
| `OpenFrontDoor` `0x004112E0` | `tube.wav` @71 |
| `aPlayJumpAnimaion` `0x00411460` | `jump.wav` @69; `drop.wav` @70; `S_ALI_2.wav` @61; `S_ALI_1.wav` @60; `S_ALI_0.wav` @59 |
| `RoofUnit` `0x00411B00` | `alien_scream.wav` @83; `crush.wav` @82; `drop.wav` @70 |
| `GroundUnit` `0x00411FB0` | `alien_scream.wav` @**-1**; `crush.wav` @**-1** |
| `aPlayElevatorSequence` `0x004125D0` | `elevator.wav` @76; `elevator2.wav` @77 |
| `aPlayPlatformSequence` `0x00412A00` | `platform.wav` @74; `platform2.wav` @75 |
| `aPlayRotateStatueSequence` `0x004131C0` | `firecircle.wav` @74 |
| `Barrier` `0x00413560` | `lbarrier.wav` @101 |
| `aPlayRotateStatueSequence` `0x00413A40` | `stone.wav` @74; `stonefire.wav` @84 |
| `aPlayStatueSequence` `0x00414000` | `stonefire.wav` @84 |
| `0x00414360` (from the move routine `0x0046FC90`) | `moveland.wav` @102 |
| `FallingSpores` `0x00414550` | `drop.wav` @70 |
| `0x004147D0` (from `0x0046FC30` / `0x0046FC90`) | `msqueether.wav` @99 |
| `aPlayFootBridgeSequence` `0x00414A70` | `bridge2.wav` @100; `bridge2.wav` @78 |
| `aPlayFootBridgeSequence` `0x00415110` | `bridge2.wav` @100 |
| `aPlayGroundFireAnimation` `0x004157B0` | `gfire.wav` @84 ×2 |
| `aPlayCrushWallAnimation` `0x00415C70` | `crushwall.wav` @86 |
| `0x00415E90` (the bomber, from `0x00470790`) | `bomber.wav` @87 |
| `0x004160F0` (the para bomb, from `0x00470790`) | `crush.wav` @89 |
| `0x00416470` (from the teleporter `0x0046D530`) | `bomber.wav` @88 |
| `aPlayTeleporterSequence` `0x004164F0` | `teleport.wav` @97 |
| `0x0041658C` | `teleport2.wav` @98 |
| `0x00416840` (from `0x00470150`) | `teleport.wav` @97; `SP_HUM_0.wav` @50 |
| `aPlayUseLeverSequence` `0x00416AD0` | `lever.wav` @68 |
| `aPlayDestryoEntrypointSequence` `0x00416CF0` | `explosion2.wav` @81 |
| `aPlayDestroyMineSequence` `0x00416DE0` | `mine.wav` @94 |

**`Info.lcl`'s own comments label ids 87 and 88 `crushwall.wav`; the binary
loads `bomber.wav` for both.** The comments are the authors' notes, not the
binding — where the two disagree, the call site above is the evidence.

### 2.1 The seventeen direct sites

| Wave | @ | Where |
|---|---|---|
| `click_1.wav`, `click_2.wav`, `click_5.wav`, `select.wav` | 96 | `aBattleSystem.cpp` |
| `click_1.wav`, `click_2.wav`, `textbeep.wav` | 96 | `aGameControl.cpp` / `aGUI.cpp` |
| `click_3.wav` | -1 | `aBattleMap.cpp`, `aMultiPlayer.cpp` |
| `click_4.wav`, `click_3.wav` | -1 | `aLoad.cpp` |
| `%smb%daif.wav` | -1 | `aMissionControl.cpp` — the briefing voice-over |
| `%sextro.wav` | -1 | `aMissionControl.cpp` |
| `%sSpeech\%s\%s%02d%02d.wav` | -1 | `aUnitMap.cpp` — unit speech |
| `progress.wav`, `alarm.wav` | -1 | `aViewPlayer.cpp` |

Id 96 — the one the authors labelled *gui-sounds* — is the only interface id,
and it is the only place a non-`-1` id appears outside `aAnimations.cpp`.

### 2.2 Case, and what a remake on a case-sensitive filesystem must do

All 50 literal wave names resolve against the shipped `Waves/` directory
**case-insensitively**, 50/50. Ten of them do not match the shipped file's
case, so a naive open fails on anything but Windows:

`alarm.wav`, `bridge2.wav`, `explosion2.wav`, `firecircle.wav`, `lbarrier.wav`,
`moveland.wav`, `planttube.wav`, `progress.wav`, `teleport.wav`, `teleport2.wav`
— shipped as `Alarm.WAV`, `Bridge2.wav`, `explosion2.WAV`, `firecircle.WAV`,
`lbarrier.WAV`, `moveland.WAV`, `planttube.WAV`, `progress.WAV`, `teleport.WAV`,
`teleport2.WAV`.

---

### 2.3 `explosion.wav` and `explosion2.wav` are two different events

They look like a pair and are not. `aPlayWeaponExplosionAnimation` `0x0040F420`
has exactly **four** callers and all four are `aCheckWeaponDamage` `0x0046D1B0`,
the overheat roll [`22` §8](22-combat-and-visibility.md) documents — so its
three sounds are the three outcomes of a weapon at its heat cap:

| Wave | @ | Outcome |
|---|---|---|
| `jammed.wav` | 64 | the weapon jams (`unit[+0x40] = 2`) |
| `damage.wav` | 65 | the weapon is damaged (`unit[+0x40] = 5`) |
| **`explosion.wav`** | **63** | **the weapon destroys its carrier** — the unit is removed from the map |

`explosion2.wav` @81 is unrelated: it is the **impact sound** of the throwing
weapons in §8.1's third switch, and the sound the destroyed entry point makes.
One is a catastrophic misfire, the other is ordnance landing. A remake needs
both, and needs them on different events.


## 3. The weapon's own fire sound

`aPlayFightAnimation` builds the attacker's sound at `0x0040C7C4`:

```
wsprintf(buf, "%s.wav", &weaponTable[weapon].waveName);   // 0x0051B2C0 + id*0x43 + 0x25
aAnimationCreateSoundBuffer(&slot, path(8, buf), 2, fxVolume, weapon);
```

The **volume-control id is the weapon id itself** — `push edi`, the same
register that indexes the weapon record. That is what `Info.lcl`'s header
comment *"see weapons"* on ids 0…49 means, and it is why the shipped table
leaves all fifty at 100 %.

### 3.1 Weapon 35 has a fire sound that cannot load

`Info.lcl` line 226 is

```
SetWeaponInfo2 (35, "W_BAY0_0", 35, 1, 0, "*");
```

Two independent defects on one line:

* the shipped file is **`W_BAYO_0.wav`** — a capital letter O, not a zero — so
  the name resolves to nothing and the load fails;
* **no `SetWeaponInfo (35, …)` exists.** [`21` §1](21-info-lcl-schema.md)
  records that `SetWeaponInfo2` patches a record `SetWeaponInfo` created; for
  id 35 there is none, so this writes into an all-zero record.

41 weapons are defined by `SetWeaponInfo` and 42 by `SetWeaponInfo2`. Every
other wave name resolves, 41/41.

---

## 4. Voices

### 4.1 The pain voice

`aPlayFightAnimation` reads the target's unit type (`unit[+0x4C]`), looks up its
**species** in the unit-info record (`unitInfo[type].species`, `+0x79`,
[`21` §5](21-info-lcl-schema.md)) and picks a scream from a three-entry
round-robin. Species 0 (human) and 1 (alien) have one each; every other species
is silent.

| Species | Waves | Cursor |
|---|---|---|
| 0 human | `S_HUM_0/1/2.wav` @56/57/58 | `0x004FC018` |
| 1 alien | `S_ALI_0/1/2.wav` @56/57/58 | `0x004FC01C` |

Each cursor advances 0 → 1 → 2 → 0 on every use, so the three variants cycle
rather than being chosen at random. A second set, `SP_HUM_0/1/2.wav` @50/51/52,
shares the **human** cursor.

**The alien scream is scaled by the human volume ids.** Ids 59, 60 and 61 —
which `Info.lcl` labels `S_ALI_0/1/2` — are used only by the fall sequence
(`aPlayJumpAnimaion`); the combat path passes 56, 57, 58 for both species. Ids
**53, 54 and 55 are defined by `Info.lcl` and named by no call site at all.**
This is the one audio defect the remake fixes unconditionally rather than
reproduces — see [`92` §7.1](92-remake-architecture.md) for why.

### 4.2 Speech

Unit speech is **not this document's**: the selector is `unit[+0x55]`, the
speech-set id `LinkChrWithGroup` writes, and
[`20` §7.4](20-lcl-language.md) already gives the complete twelve-entry mapping
from that id to a directory and a filename prefix. What is added here is the
audio-side anchoring: the two sites that build
`%sSpeech\%s\%s%02d%02d.wav` (`0x0047BB12`, `0x0047BB4F`), the fact that they
pass volume id `-1` — speech is never scaled by the `SetVolumeCtrl` table, only
by its own options field ([`20` §8](20-lcl-language.md)) — and that the ten
shipped directories `1`…`9`, `A` hold 252 files between them.

---

## 5. Footsteps

`aStartWalkAnimationSound` `0x0040E640` switches on the mover's **unit type**
(`unit[+0x4C]`, 0…68) through a 69-entry index table at `0x0040E938` and a jump
table at `0x0040E8F4`. Eight distinct arms; each sets a wave, a volume id and a
step period written to `0x004FAECC`. `aStopWalkAnimationSound` `0x0040E9E0`
ends it.

| Wave | @ | Period | Unit types |
|---|---|---|---|
| `mhuman.wav` | 62 | 4 | 0–6, 21, 22, 23, 25, 26 |
| `mdecther.wav` | **45** | 2 | 24 |
| `mcombot.wav` | 90 | 8 | 20 |
| `mdecther.wav` | 91 | 2 | 52, 65, 66 |
| `msqueether.wav` | 93 | — | 54 |
| `malien.wav` | 92 | 7 | 59 |
| `malien.wav` | 92 | 5 | 50, 51, 53, 55–58, 60, 64, 67, 68 |
| *(silent)* | — | — | 39 types: 7–19, 27–49, 61–63 |

### 5.1 The period is one global, and one arm does not write it

The wave and the volume id are per arm; **the period is not**. Six of the seven
sounding arms end with `mov dword [0x004FAECC], imm32` — one global, written
with the arm's own literal. The `msqueether` arm, unit type 54, writes its wave
and its volume id and **leaves the period alone**, so a Squeether walks at
whatever period the last walker set.

`0x004FAECC` is past the end of `.data`'s raw bytes, in the tail the loader
zero-fills, so before anything has walked the period is **zero** and a
Squeether's step never repeats. Both halves are reproduced rather than smoothed
over, which is why a remake's "start walk sound" cannot be a pure function of
the unit type: `tools/inclib/sound.py`'s `WalkPeriod` is that global as state,
and `blob_tables.py` pins the six stores, the address, the zero start and an
ordered carry-over trace.

**Unit type 24 scales its footsteps by volume id 45.** Every other footstep uses
one of the four ids `Info.lcl` labels for walking (62, 90, 91, 92, 93); 45 is
inside the 0…49 band that belongs to weapon 45. The two ids differ by one bit
(`0x2D` against `0x5B`), and the shipped consequence is audible: id 91 is 50 %,
id 45 is 100 %, so that one unit type walks twice as loud as its twin. Recorded
as a defect, not a rule.

---

## 6. Ambience is a stub, and ten waves are dead

`aAmbience.cpp` exists — `aInitAmbience` `0x0040B3F0`, `aFreeAllAmbienceWaves`
`0x0040B470`, five buffer-id slots at `0x004FAE60`…`0x004FAE70`. It never plays
anything, and this is enumerated rather than inferred:

* each of the five slots has **one or two** code references in the whole image,
  and they are the initialiser writing `-1` and the free routine reading it
  back. Nothing ever stores a loaded buffer id there.
* the one call the ambience path makes, at `0x0040B439`, lands on `0x0042C490`,
  which is `mov eax, 1; ret`. (That address is a COMDAT-folded `return TRUE`
  shared by several functions, so it does not identify one of them — but the
  call from the ambience path demonstrably does nothing.)
* the ten shipped `amb_a_0…4.wav` / `amb_b_0…4.wav` files are named by **no
  string anywhere in the image**, checked with a positive control (`door.wav`,
  which the same search does find).

Fourteen shipped waves are named by nothing at all: the ten ambience files,
`bridge.wav`, `splash.wav`, and the weapon sounds `W_CHS_0.wav` and
`W_HSR_0.wav` — which no `SetWeaponInfo2` line references either.

**Music** is MCI CD audio (`cdaudio`, `aCDRom.cpp`), selected per mission by the
`CDTrackProgram` playlist [`20` §7.3](20-lcl-language.md) and attenuated by
`aSetCDVolume` `0x0042C330` from the options record [`20` §8](20-lcl-language.md).
The GOG release ships the tracks as `music/Track02…20.ogg` and
`music/Arack02…14.ogg` and intercepts MCI in `audio.dll`; that substitution is
packaging, not engine.

### 6.1 Which of the two families the shipped build plays — `Arack`

`music/` carries the score twice, and it is not a duplicate: measured pairwise,
**02–08 are byte-identical and 09–14 differ**, and the shipped `CDTrackProgram`
playlists reach track 13. So which family plays is audible, and for most of this
project's life it was an open question, on the grounds that the selector lives
inside an MCI shim no tool here read.

It never needed the shim's code. **`Incubation.exe`'s import descriptor names
`audio.dll` where the 1997 build named `WINMM.dll`**, importing exactly the nine
`winmm` entry points the game used — `mciSendCommandA` and `mciGetErrorStringA`
for the CD, and the seven `mixer*` calls the options screen moves — and there is
no `winmm` descriptor at all. That DLL is an ogg-winmm shim built with the
format string `%s\Arack%02d.ogg`. `sound.dll` is byte-for-byte the same shim
built with `%s\Track%02d.ogg`, and **no import descriptor anywhere in the tree
names it**.

| | `audio.dll` | `sound.dll` |
|---|---|---|
| Format string | `%s\Arack%02d.ogg` | `%s\Track%02d.ogg` |
| Imported by | `Incubation.exe` (and the three trace builds) | nothing |

So the shipped release plays **`Arack`**, and the `Track` family — which alone
runs on to 20 — is the one nothing reaches. `blob_tables.py` pins all of it:
the import descriptor and its nine entry points, the absence of a `winmm`
descriptor, the sweep that finds no other importer of `sound.dll`, each DLL's
own format string, the twelve tracks the shipped playlists name, and the
02–08 / 09–14 divergence itself.

---

## 7. Blobs

### 7.1 The pool

`aInitBlobs` `0x0041DE40` allocates one block of **`0x9B08` = 39 688 bytes**
labelled `aInitBlobObjects (Blob-Objects-CLONELIST)`. Every walk over it uses
`cmp esi, 0x1C2` and `add edi, 0x58`: **450 records of 88 bytes**, plus one
spare record's worth of slack. A create call that finds no free slot returns
`-1` and the effect is silently dropped.

### 7.2 A blob is an Eng3d object with eight fields bolted on

`0x00420950` is the only way a blob is made — 116 call sites, all inside
`aBlobs.cpp`. Its arguments map one-for-one onto the record:

```
newBlob(const char *model, int class,
        int x, int y, int z,
        short a6, short a7, short a8,
        byte kind, byte life,
        int p11, int p12, int p13,
        byte a14, byte delay)
```

**The record is not a flat struct.** Bytes `+0x04 … +0x43` are an Eng3d
`object_3d`, the same 64-byte record `0x00404F80` builds for a world object;
`aCheckInBlobObjects` hands the renderer `blob + 4` and nothing else.  That is
what fixes the layout, and it is why the blob's own fields start at `+0x44`:

| Blob | Object | Field | Set by the constructor |
|---|---|---|---|
| `+0x00` | — | in use — non-zero marks the slot taken | yes, last |
| `+0x04` | `+0x00` | *(Eng3d's)* | no |
| `+0x0C` | `+0x08` | **prototype index**, from `0x004038F0(model)` | arg 1 |
| `+0x10` | `+0x0C` | cached collision radius | **no** |
| `+0x14`, `+0x18`, `+0x1C` | `+0x10`, `+0x14`, `+0x18` | **position** | args 3, 4, 5 |
| `+0x20` | `+0x1C` | **joint-angle pointer** — zeroed, so the inline buffer is used (§7.8) | yes |
| `+0x24`, `+0x26`, `+0x28` | `+0x20`, `+0x22`, `+0x24` | **class-dependent**, see below | args 6, 7, 8 |
| `+0x2A`, `+0x2C`, `+0x2E` | `+0x26`, `+0x28`, `+0x2A` | **joint angles of part 1** (§7.8) | no |
| `+0x30`, `+0x32`, `+0x34` | `+0x2C`, `+0x2E`, `+0x30` | **joint angles of part 2** (§7.8) | no |
| `+0x44` | — | **kind** — selects the update arm (§7.4, §7.7) | arg 9 |
| `+0x45` | — | **life** in ticks; `0xFF` never expires; a zero argument aborts the call before anything is allocated | arg 10 |
| `+0x48`, `+0x4C`, `+0x50` | — | **three per-kind parameters**, velocity for every ballistic kind | args 11, 12, 13 |
| `+0x54` | — | **class-dependent**, see below | arg 14 |
| `+0x55` | — | **delay** — ticks to wait before the blob starts | arg 15 |
| `+0x56` | — | **class** | arg 2 |

`aGetMemory` is `malloc` and `aInitBlobs` clears only each record's `+0x00`, so
every field the constructor does not set holds whatever the slot's previous
occupant left. Only `+0x10` matters, and nothing on the blob path reads it:
`E3D_object_3d_check_in` (Eng3d ordinal 9) reads `+0x08` and the position, and
culls against the **prototype's** own radius, not this cached copy.

**Class decides both how the blob is drawn and what three of its fields mean.**

| Class | Drawn by | `+0x24` | `+0x26` | `+0x28` | `+0x54` |
|---|---|---|---|---|---|
| 0, 1 | `E3D_object_3d_check_in` — a `.3DI` model | rotation x | rotation y | rotation z | free per-kind counter |
| 2, 3 | `aDrawZoomBlobs` — a textured quad (§7.3) | **atlas row** | **atlas column** | *unused* | **sprite half-size** |

Classes 2 and 3 pass a model argument that is never read; all 54 of those calls
pass the same scratch buffer `0x004FA524`, which is a leftover, not data. Of the
116 calls, 55 pass class 0, 5 class 1, 52 class 2 and 2 class 3; two build the
class at run time. Only classes 0 and 1 look the model up, and a lookup that
fails aborts the call (§7.5).

### 7.3 The zoom bob — one texture, sixty-four sprites

A class 2 or 3 blob has no geometry. `aDrawZoomBlobs` `0x0041E490` sends it to
`E3D_draw_zoom_bob_alpha_plus` (Eng3d ordinal 63) as a camera-facing quad, and
every parameter of its appearance comes from two bytes and a size:

```
drawZoomBob(x, y, z, row, col, unused, size)      /* 0x004040A0 */
    quad half-extent = size * 160                 /* world units: 1600 = 1 m */
    u0 = col * 32   u1 = u0 + 31
    v0 = row * 32   v1 = v0 + 31
    texture = the handle in 0x004F9F70
```

`Eng3d` exports three zoom-bob entry points — `alpha_plus`, `alpha_minus` and
`masked`, ordinals 63, 64 and 65 — and `a3DEngine.cpp` resolves all three at
start-up. **Only `alpha_plus` is ever called**: the other two import slots are
written by the resolver and read by nothing. So every sprite in the game is
drawn the same way, and the entry point's name is the only evidence there is
for what that way is.

That handle is set twice, at `0x0040301E` and `0x00403270`, from
`E3D_get_texture_index_of_texture_name("anim")` (ordinal 66). **`anim` is a
256×256 texture present in all nine world sets** — an **8 × 8 grid of 32 × 32
sprites**, which is exactly what the `u1 = u0 + 31` and the `<< 5` say it must
be.

Each **row of the atlas is one flip-book**: a fire puff, an expanding ring, a
red burst, a green cloud, a grey smoke puff, a white spark star, a green glow,
a red spiky burst. So a sprite blob is *(which animation, which frame, how
big)*, and the update arms advance the **column**. That is why the update writes
`+0x26` far more often than `+0x24`.

There are no colour parameters anywhere in the blob system, and there never
were: **the palette is baked into `anim`.** Across the 54 sprite calls the row
takes seven of the eight possible values (0, 1, 3, 4, 5, 6, 7 — row 2 is unused
by any call), the starting column is 0 at every call but one (which starts at
3), and the half-size takes ten values from 3 to 40 — 0.3 m to 4 m.

Which row a creator picks lines up with what the picture shows, which is the
cheapest sanity check available: the fire effects take row 0, the spore and
sting weapons row 3, dust and smoke row 4, every laser row 5.

`+0x28` — the third orientation word — is read by nothing on this path.
`aDrawZoomBlobs` loads it and never uses it.

Extract the atlas with
`python3 tools/visn_decode.py gog_incubation/WorldSet/World_A00/TEXTURES/texture.lib -o out`.

### 7.4 The update

`0x0041E500(blob)` runs once per blob per frame:

1. if `delay` (`+0x55`) is non-zero, decrement it and return — the blob is not
   live yet;
2. if `life` (`+0x45`) is zero, or `z` (`+0x1C`) has gone negative, delete the
   blob;
3. unless `life == 0xFF`, decrement it;
4. `switch (kind)` — `cmp eax, 0x4D`, then a 78-entry jump table at
   `0x00420814` holding **74 distinct arms**; kinds above 77 fall to the
   default.

The first bounded native sample is now recorded in
[`91`](91-wine-runtime-probes.md): a Standard Assault Rifle tracer reached the
kind-15 arm at `Incubation.exe + 0x20734`; an inline trampoline captured the
live `ESP`, `ESI` blob pointer and all 88 pre-arm bytes, then returned through
the displaced instructions without stopping the game. This confirms this one
dispatch and record instance, not every service hook used by the other arms.

The ballistic arms share one rule worth quoting because a remake has to match
it to make debris look right:

```
x += vx;  y += vy;  z += vz;
vz += (life > 10) ? -640 : -32;          // 0xFFFFFD80 / -0x20
```

so a blob falls hard while it is young and drifts once it is nearly spent.

### 7.4.1 Executable arm rewrite

The per-tick switch is now transcribed as an executable, headless reference in
[`tools/blob_runtime.py`](../tools/blob_runtime.py). `HANDLERS` covers all 78
kind values and has 74 distinct callables, matching the jump table's 74
distinct destinations (21/24, 23/40, 48/53 and 66/70 are aliases). The
reference preserves the wrapper order and field widths, the Lehmer/x87 RNG, every
direct position/velocity/rotation/counter write, the life-gated branches, the
self-morph (49 -> 7), explicit deletion arm (11), and the recovered
constructor address and argument list. `python3 tools/blob_runtime.py
--selftest` checks the mutation/RNG/spawn profile of every kind plus terminal
and conditional branches that morph, delete or create children.

The original's global `0x4FE63C` signal and the pool deletion call at
`0x0041E320` are deliberately separate in the API: a tick reports
`delete_requested` for the former and `deleted` for the latter. A
`BlobHooks` adapter supplies the services that are outside the 88-byte record
(unit-map/position lookup for seekers, model lookup, orientation helpers and
constructor allocation) and records their arguments. The default adapter is
deterministic and never executes the retail binary.

This closes the static transcription gap without overstating native parity:
the arms themselves are a transcription and the diff against them compares two
transcriptions. What the *services* do is no longer open — see §7.4.2.

### 7.4.2 The five services, measured

`tools/blob_gold.py`'s `hooks` phase calls all five inside a running
`Incubation.exe` with a mission loaded and reads what they write. Their
arities are their **callers'** `add esp, K`, the same reading the creators'
are: `0x00403AA0` nine, `0x0046D400` ten, `0x004039A0` three, `0x00405100`
four, `0x00477AE0` one.

| routine | what it is | reproduced? |
| --- | --- | --- |
| `0x00403AA0` | source and target → `(pitch, yaw)` | **yes**, 20/20 |
| `0x0046D400` | source and target → three doubles | **yes**, 40/40 |
| `0x00405100` | object id → its position | **yes**, table and gate measured |
| `0x00477AE0` | unit id → its record address | **yes**, stride measured |
| `0x004039A0` | a vector through Eng3d's 3-angle matrix | recorded, **not** reproduced |

`tools/inclib/eng3d.py` is the portable half and `godot/game/fx/eng3d_geometry.gd`
its twin; both read the shipped `TRIG.IMG` and `ATN.IMG` rather than
regenerating them, because [`70` §5](70-img-tables.md)'s first open question is
that the generation rounding is unknown and one unit of a 4096-unit circle is
one unit of every angle built on it.

**`0x00403AA0` is the one the remake had been standing in for, and the
substitute was wrong twice.** The real routine works in the **4096-unit
circle**, not in 65536ths, and its pitch is measured **from level** rather than
from the horizontal plane by trigonometry:

```c
yaw   = ANGLE(dx, dy);                 /* [0x004FA4E0], out of ATN.IMG      */
M     = matrix(0, yaw);                /* 0x004039F0, Q14, truncate to zero */
flat  = M * delta >> 14;               /* Eng3d's transform, arithmetic sar */
pitch = ANGLE(flat[1], flat[2]) - 0x400;
```

`ANGLE(a, b)` is measured from `+b` toward `+a`, so it is 0 along `+y` and
1024 along `+x`; `ANGLE(0, 0)` is 0 and `ANGLE(a, 0)` is 1024. Three details
that a reimplementation gets wrong by default and the capture settles:

* the **two shifts round differently inside one call**. The matrix builder
  uses `cdq / and edx, 0x3FFF / add / sar 14` — toward zero — and Eng3d's
  transform uses a plain `sar 14` — toward negative infinity. A delta of
  `(-1, -1, -1)` answers 512 with the second and 0 with the first.
* the engine's **identity rotation is not one**: `TRIG.IMG`'s peak is 16383
  over a denominator of 16384, so a coordinate of 1000 comes back 999 and a
  delta of length 1 rounds away entirely. That is why `0x00403AA0` answers a
  pitch of −1024 (straight up) for a purely horizontal delta of one unit.
* the routine's **seventh argument is dead**. All twenty sweeps leave the
  buffer handed to it exactly as it was zeroed.

**`0x0046D400` is not a normalised direction.** Its first two outputs are
divided by whichever of `|dx|` and `|dy|` is larger — so one of them is always
exactly ±1 — and the third by the **truncated integer** 2D distance
`0x0044AE10` returns, which is `trunc(sqrt(dx² + dy²))` and not the exact
length: `(5, 3)` comes back 5. Two behaviours a remake would otherwise invent
a guard for and must not:

* it **divides by zero unguarded**. A zero horizontal delta gives `NaN` in the
  first two components and `±inf` or `NaN` in the third, and the caller gets
  them.
* its **tenth argument, the `>> 3` flag, does not reach the first two
  components**. The shift is applied inside the branch that computes the
  vertical only, so a caller passing 1 still gets the unshifted horizontal
  ratio.

**The two lookups.** `0x00405100` indexes an array at `[0x004FA804]` with
stride 77, gates on `+0x40`, delegates through `+0x45` and otherwise copies
`+0x10/+0x14/+0x18` — the placed object's position of §7.6.1, and every
in-range answer in the save is a whole 3200-unit map field.  `0x00477AE0`
indexes `[0x005229C4]` with stride 91 — the unit record — and returns the
record's address, or 0 after a CHECK for an id of `0xFFFF`, an id above 200 or
a dead unit. The dead-unit path was swept live and **does not block the
process**.

Both guards are `cmp eax, 0xC8` with a *strictly greater* branch, so **id 200
is admitted and the arrays hold 200 entries, 0 through 199**. The sweep's last
object comes back with a position that is neither a tile nor a multiple of the
map field. Nothing shipped passes 200; a remake that clamps at `<= 200`
inherits the bug silently, which is why it is pinned.

### 7.5 Models

Thirty `.3DI` prototype names appear in the constructor calls. They are not
blob-specific assets — they are ordinary entries in the world object index, so
they resolve through the same `prototyp.dir` chain as scenery
([`31`](31-prototyp-geometry.md)). Twenty-six are present in **all nine** world
sets. Four are not:

| Model | Present in |
|---|---|
| `A_PARAB1.3DI` | `World_E00`, `World_F00` |
| `A_SPOTL.3DI` | `World_E00` |
| `L049EE00.3DI` | `World_E00` |
| `L069EE00.3DI` | `World_E00` |

Who uses them:

* `A_SPOTL.3DI` is `aBlob_CreateSpot`'s and `L049EE00.3DI` is the second
  `aBlob_CreateCreateFire`'s — the models `CreateBGB` types 5 and 6 create, and
  those two types are, as [`20` §7.3](20-lcl-language.md) records, never used by
  a shipped script;
* `L069EE00.3DI` is `aBlob_CreateBomber`'s, reached from the bomber fly-past
  sequence `0x00415E90`;
* `A_PARAB1.3DI` is the para bomb's, used by `aBlob_CreateParaBomb` and by
  `0x0042B070` under the para-bomb sequence `0x004160F0`.

The last two matter: the bomber and the para bomb are ordinary scripted events,
not dead code, and **their models exist in one and two world sets
respectively.** A mission in any other world set that triggers them gets a
failed lookup, and the constructor **aborts**: `0x004209A0` reports
`unknown object!\n'%s'` through the trace macro and returns `-1` without
touching the pool. The effect simply does not appear. A remake should treat the
pairing (effect, world set) as a constraint rather than assume the model is
always there.

### 7.6 The creators

**Eighty-one** functions call the constructor; **57 of them carry a developer
name**, recovered the way [`90`](90-binaries-and-source-layout.md) describes —
the caller pushes the callee's name on the error path. The names are
descriptive and are the best short description of each effect that exists:
`Explosion2`, `FireExplosion`, `SmallFireExplosion`, `PlasmaExplosion2`,
`SporeExplosion`, `ShockWave`, `FireWheel`, `FireCircle`, `FlashCircle`,
`FlameStream`, `TracerBullet`, `Laser`, `LaserBarrier`, `LaserHit2`, `Needles`,
`Grenade`, `ParaBomb`, `SpidyMines`, `SporeCannon`, `EnergyCannon`,
`PlasmaBallImpact`, `SporeSparks`, `PlasmaSparks`, `StingSparks`,
`SparkingPlug`, `SparkingRain`, `HittingBlobs`, `BloodFlood`, `FlyingDebris`,
`BarrelDebris`, `LandingDust`, `TubeSmoke`, `Smoke2`, `Spores`, `KillFire`,
`CreateFire`, `FireDeath`, `MainMapFire`, `WarningLight`, `ComputerLight`,
`Spot`, `ZoomBob`, `Bomber`, `FlyingUnit`, `Flash`, `DoubleFire`.

Several names appear at more than one address — `aBlob_CreateLaser` at four,
`aBlob_CreateTracerBullet` at three — which is what C++ overloads look like
once the linker is done. **Key everything by address, not by name.**

`python3 tools/blob_tables.py --blobs gog_incubation` prints every one of the
116 calls with its model, class, kind and lifetime. Sixty-two distinct kind
values are used, all within the switch's 0…77; classes are 0…3; the 91 calls that pass a
literal lifetime range from 4 ticks to `0xFF`, and 25 compute one.

---

### 7.6.1 Where a creator's origin and randomness come from

Two things about the creators were guessed for a long time and are now read
rather than assumed. Both readings are static and cover **all thirty**
creators a shot can reach; the native capture (`tools/blob_gold.py`) is the
second reading of each.

**The origin is the placed object's position, and the floor never enters it.**
Every one of the thirty opens the same way:

```
    eax = aGetCtrlMapElementPtr(y, x);      /* CHECK, refuse if null */
    dx  = *(u16 *)(eax + 5);                /* the symbol on the cell */
    eax = aGetSymbolObjectPtr(dx);          /* CHECK, refuse if null */
    x = eax->[0x10];  y = eax->[0x14];  z = eax->[0x18] + K;
```

so a blob starts at the **object standing there**, not at the tile and not at
the ground. The control map's height dword sits at `+1` of the cell and is
read by **no creator at all** — checked by sweeping every `mov r32, [base+1]`
in all thirty bodies, of which there are none. That closes a question the
capture alone could not: every occupied tile in the captured save is at height
zero, where "absolute z" and "floor plus a constant" are the same number. They
are neither. `blob_gold.py`'s z probe writes a height under the creator's own
tile and confirms `z` does not move.

**The velocities are random, and the generator is not `aRandom`.** Reading
`aRandom`'s seed either side of all thirty creators shows it **never moves**,
and no creator's closure contains a call to it. What they draw from is
[`22` §3.2](22-combat-and-visibility.md)'s second entry point, `0x004638E0`:
`aRandom`'s body byte for byte over the seed at `0x00514070`, without the call
counters. Twenty-six of the thirty carry a call to it somewhere in their
closure — up to 52 sites in one.

Reading *that* seed either side turns "random" into a number, because the
generator is a pure function of its seed: the advance names how many draws the
creator took, and the draws are then a known sequence. On the captured tile
most creators take **none** — `aBlob_CreateSpores` (`0x00420A50`) lays its
twelve blobs on a ring, 36° apart at a radius of about 640, and is the same
twelve every time — while `aBlob_CreateFireWheel` (`0x004228F0`) takes
**ninety** for its twelve records and is different every time.

Which is by design, and §3.2 of `22` shows where: the effects stream is seeded
from `GetTickCount()` at start-up while the gameplay stream is seeded to the
constant 1.0. **A shot does the same damage every run and does not look the
same.** A remake that wants byte-identical effect trajectories has to seed the
effects stream itself; one that wants the original's behaviour must not.

---

### 7.6.2 The arithmetic on top of the draws

§7.6.1 established *which* generator a creator draws from and *how many* times.
What §7.6.1 left `UNVERIFIED` was the arithmetic in between — an affine fit
over the captured velocities matched none of the fourteen creators that draw.
**That marker is retired by this section**: the fit was wrong, not the
arithmetic.

**The shape is the generator's own.** A drawn field is
`scale * int(base + span * fraction)` — `aRandom(base, span)`, truncated,
sometimes times a constant. `0x0042ACF0`'s vertical is 32 times it, which is
why a fit that only looked for `base + span * f` could not see it.

**The draw-to-field order is per creator and runs both ways.** MSVC evaluates
`__cdecl` arguments right to left, so a creator that passes its draws straight
into `0x00420950` consumes them in **reverse** field order — `0x004228F0`
draws `vz`, then `vy`, then `vx` — while one that parks them in locals first
does not: `0x00425810` draws `vx`, `vy`, `vz`. A single global rule was the
first fit's other mistake.

Three creators reproduce **every varying field of every captured record** from
the seed alone, and a fourth its velocities:

| creator | cycle | fields, in draw order |
| --- | --- | --- |
| `0x004228F0` | 3 | `vz` = `(400, 800)`, `vy` = `(-100, 200)`, `vx` = `(-100, 200)` |
| `0x004294E0` | 3 | `vz` = `(200, 300)`, `vx` = `(-300, 600)`, `vy` = `(-300, 600)` |
| `0x004295D0` | 6 | the same three, then `rot_z`, `rot_y`, `rot_x`, each `(0, 4096)` |
| `0x00425810` | 3 | `vx`, `vy`, `vz`, all `(-320, 640)` — its *positions* are not on a cadence |

A drawn rotation is `aRandom(0, 4096)`: the **4096-unit circle** of
[`70`](70-img-tables.md) again, the same one §7.4.2's orientation helper
answers in and §7.8's joint angles are masked to.

**The remaining creators have no per-record recipe to fit, and that is the
answer rather than a gap.** Their draw stream is not consumed at a fixed rate:
three of them build records of several *kinds* in one call (`kind`,
`class_id` and `model` all vary across the twelve read back), and others
retry — `0x00429A80`'s first record does not sit at draw 0 while its second
sits at draw 4. No cycle length exists for a fit to find, which is exactly why
the blanket affine fit failed and would have kept failing.

`tools/blob_gold.py` pins the recipes and replays each one against every
captured record; a creator is listed only if **every** field that varies is
explained, because a partial recipe over twelve records is a coincidence
waiting to be pinned and one creator produced exactly such a coincidence over
four.

### 7.7 The seventy-eight kinds

The switch's 74 arms are short pieces of particle arithmetic with no names in
either binary. What makes them tractable is that **every kind is named by the
creators that pass it**, and those creators do have the developers' names. The
complete table is
`python3 tools/blob_tables.py --kinds gog_incubation`; what follows is how to
read it.

**Where a kind comes from.** 62 of the 78 are passed as a literal at one or
more of the 116 constructor calls. Two calls build one in a register, and both
are a two-way choice:

| Call | Idiom | Produces |
|---|---|---|
| `aBlob_CreateNeedles` `0x004246F9` | `setne al; add eax, 0x49` | kind **73** or **74** |
| `aBlob_CreateGrenade` `0x00426463` | `sete cl; add ecx, 0x1A` | kind **26** or **27** |

One more is reached by a blob changing its own kind: `aBlob_CreateFlameStream`'s
arm (kind 49) writes `kind = 7` and `life = 6` into its own record at
`0x0041E89C` — the flame turns into a short-lived remnant. That is the only
`+0x44` write in the whole update.

**Eleven kinds are unreachable** — 2, 4, 21, 28, 30, 35, 45, 48, 53, 56 and
76. No call passes them, no computed site can produce them and nothing morphs
into them; their arms are dead code. (48 and 53 share the switch's default arm,
so they would do nothing even if reached.)

**What an arm does** falls into a small vocabulary, and the read/write sets say
which parts apply:

| Behaviour | How it shows |
|---|---|
| move | writes `+0x14/+0x18/+0x1C` from `+0x48/+0x4C/+0x50` |
| gravity | subtracts from `+0x50` — the split at `life == 10` in §7.4 |
| animate | advances the atlas column `+0x26` (class 2/3) |
| spin | adds to a rotation word `+0x24/+0x26/+0x28` (class 0/1) |
| grow or shrink | writes `+0x54`, the sprite half-size |
| swap model | calls `0x004038F0` again and rewrites `+0x0C` — kinds 16 and 17 |
| spawn | calls another creator, or the constructor directly |
| self-delete | calls `aDeleteBlobObject` `0x0041E320` — kind 11 |

**The spawn graph** is the part a remake most needs, because one trigger can
cascade into four or five effects. Twenty-three kinds spawn something:

| Kind | Created by | Spawns |
|---|---|---|
| 3 | `aBlob_CreateFlyingUnit` | `aBlob_CreateBarrelDebris` |
| 6, 15, 69, 73, 77 | grenades, tracers, needles, spidy mines | `aBlob_CreateZoomBob` |
| 56 | *(unreachable)* | `aBlob_CreateZoomBob` |
| 11 | double fire, tracer | *deletes itself* |
| 19 | `aBlob_CreateHittingBlobs` | `aBlob_CreateHittingBlobs` |
| 22 | `aBlob_CreateSporeCannon` | `aBlob_CreateSporeSparks` |
| 25 | `aBlob_CreateParaBomb` | `aBlob_CreateBarrelDebris` |
| 26 | *(computed)* | `aBlob_CreateZoomBob`, `aBlob_CreateHittingBlobs` |
| 32 | `aBlob_CreateTracerBullet` | `aBlob_CreateStingSparks` |
| 36 | `aBlob_CreateFireWheel` | `aBlob_CreateHittingBlobs` |
| 44, 62, 67, 75 | fire wheel, fire circle, the fire explosions | `aBlob_CreatePlasmaSparks` |
| 47 | `aBlob_CreateSpores` | `0x00429390` |
| 52 | `aBlob_CreateBomber` | `aBlob_CreateParaBomb` |
| 59, 75 | the ground-fire emitter, the fire explosions | the constructor directly |
| 71 | `aBlob_CreateLaser` | `aBlob_CreateLaserHit2` |
| 73, 74 | *(computed — needles)* | `0x00428F70` |

**Three kinds ask the unit map where something is.** Kinds 26, 27 and 61
(`aBlob_EnergyCannon`) call `aGetUnitMapElementPtr` `0x00477AE0`, then
`aGetStdObjectPosition` `0x00405100`, then `0x0046D400` — which is a pure
geometry helper: it subtracts coordinates and calls the squared-distance
routine `0x0044AE10`, and it has 37 callers, 30 of them blob creators. So the
three arms **steer toward a unit and nothing more**: across all three, every
store is through the blob pointer, so the unit map is read and never written.
Damage stays where [`22` §7](22-combat-and-visibility.md) puts it — blobs are
cosmetic.

Four arms are the exception to "particle arithmetic": kinds 26, 27 and 61 are
500–600 bytes of seeking, and kind 42 (`aBlob_CreateComputerLight`) and kind 54
(`aBlob_CreateCreateFire`) do nothing but pose their model's sub-objects
(§7.8).

### 7.8 Four `object_3d` fields the arms write: the joint angles

`+0x2A`, `+0x2C`, `+0x2E` and `+0x34` — object offsets `+0x26`, `+0x28`, `+0x2A`
and `+0x30` — are written by exactly two update arms and read by nothing in
`Incubation.exe`. They are **joint angles**: the rotation of the model's
articulated sub-objects, consumed by the renderer, not by the game.

**The reader is in `Eng3d.dll`.** Seven of its render-opcode handlers begin
with the same idiom — a twelve-byte sequence that appears seven times in
`Eng3d.dll`, seven times in `ENG3DFX.DLL` and **nowhere in `Incubation.exe`,
`iDesigner.exe` or `Editor.exe`**:

```
mov  esi, [ebx + 0x1c]      ; ebx = the object being drawn (0x00414084)
test esi, esi
jne  +3
lea  esi, [ebx + 0x20]      ; null pointer -> the inline buffer
add  esi, eax               ; eax = the opcode's operand, a byte offset
mov  bx, [esi]              ; three consecutive i16 -> a rotation matrix
mov  cx, [esi + 2]
mov  dx, [esi + 4]
```

Five of the seven read a triple like this; `joint_rotate_1` and
`matrix_from_angle` read one angle and zero the other two.

So `object_3d + 0x1c` is a **pointer to a joint-angle buffer**, `+0x20` is the
**inline buffer** used when that pointer is null, and the prototype's own
bytecode says which triple to use: the operand `prototyp.bin` marks `anim`
([`31`](31-prototyp-geometry.md) §3.1) is a byte offset into it. Both hosts
always write null — `0x0040501B` for a world object, `0x00420A24` for a blob —
so the inline area is always the one the engine reads.

**The shipped data uses three triples, and only three.** Over all nine world
sets the `anim` operand takes the values `0`, `6` and `12` and nothing else:

| Triple | `anim` | Object | Blob | What writes it |
|---|---|---|---|---|
| 0 | `0` | `+0x20`/`+0x22`/`+0x24` | `+0x24`/`+0x26`/`+0x28` | the constructor, args 6–8 — the object's own rotation |
| 1 | `6` | `+0x26`/`+0x28`/`+0x2A` | `+0x2A`/`+0x2C`/`+0x2E` | kind 42, kind 54 |
| 2 | `12` | `+0x2C`/`+0x2E`/`+0x30` | `+0x30`/`+0x32`/`+0x34` | kind 54 |

Eighteen bytes of triples in the thirty-two the record has after `+0x20`. The
angles are binary degrees in the 4096-unit circle — the handler masks each with
`0xFFF` and indexes `TRIG.IMG` ([`70`](70-img-tables.md)), the same convention
as a `.lev` object's rotation.

**Which makes the two arms legible.** Both animate a model with sub-objects,
and each writes exactly the triples its own model asks for:

* **kind 42**, `aBlob_CreateComputerLight`, model `A_PANEL.3DI` — one
  `part_push` / `joint_place 6` / `part_pop`, so one moving part. The arm
  copies the first and third of the object's own three angles into that part's
  triple and sets the middle one to `0x400` (a quarter turn) or `0x1000` (a
  whole one, i.e. zero under the mask) on a 50/50 roll. The panel's plate flips
  between edge-on and face-on every tick: that is the flicker.
* **kind 54**, `aBlob_CreateCreateFire`, model `A_FIRE3.3DI` — two parts, at
  `joint_place 6` and `joint_place 12`. The arm gives each part's third angle a
  fresh `rand(0, 0x1000)` every tick, so both flame billboards spin to a random
  heading each frame.

For contrast, **kind 41** (`aBlob_CreateWarningLight`, `A_FLIGHT.3DI`) has no
parts at all, and its arm adds `0x200 / life` to triple 0's third angle — the
whole object turns. Same mechanism, one triple lower.

**The last 36 bytes are a union.** The joint reading is not the only one: two
other handlers, `matrix_clone` and `matrix_clone_compose`, take `+0x1c … +0x3f`
as an inline 3×3 `i32` matrix instead. No shipped render program uses both
readings, and the split is exactly the split between characters and scenery —
16 974 programs (1 886 prototypes) take the matrix, 2 326 (1 448 prototypes)
take the joint angles. Two independent placements confirm which is which:
every prototype the missions place as a special object is joint-family, bar the
two `L096E?00.3DI` records that carry no transform opcode at all; and of the
1 985 meshes the 114 `.cho` models name, **1 877 are matrix-family and not one
is joint-family** (the other 108 name no record in these containers). Nine
matrix-family prototypes are named by no `.cho` — one unused `PS_M0_024_*` set.
So the matrix form is the Charisma track's
([`40`](40-charisma-model-animation.md)); neither host writes it, and one
Eng3d export, `_E3D_get_object_joint_data_ptr` (ordinal 59), whose entire body
is `lea eax, [eax + 0x40]; ret`, says where a *clone's* joint array lives —
immediately past the embedded 64-byte object. The full field table is in
[`30`](30-eng3d-ascii-formats.md) §2.12.

`blob_tables.py --joints` prints all of this; 35 checks pin it.

---

## 8. What triggers a blob

**Almost nothing outside `aAnimations.cpp` does.** Of the callers of all 81
creators, exactly **two** sit in another module:

| Site | Module | Reaches |
|---|---|---|
| `0x00473942` | `aUI.cpp` | `0x00422D40` — the arrow marker |
| `0x0046D85F` | `aTacTools.cpp` | `0x0042A6E0` |

Everything else is either `aAnimations.cpp` — overwhelmingly
`aPlayFightAnimation` — or `aBlobs.cpp` itself, where an update arm spawns a
secondary blob (a `HittingBlobs` becomes a `SparkingRain`, a `ZoomBob` is
attached to fourteen different effects).

This is the single most useful structural fact in this document for a remake:
**effects are not driven by the simulation, they are driven by the animation
routines**, and the simulation only calls those.

### 8.1 Weapon → effect, from the compiler's own tables

`aPlayFightAnimation` contains three switches on the attacker's weapon id. All
three are read here out of the index and jump tables rather than inferred, and
every arm's call is pinned to its address.

| Switch | Weapon ids | Index table | Jump table |
|---|---|---|---|
| muzzle blob | 2…47 | `0x0040E5A4` | `0x0040E524` |
| impact blob | 7…46 | `0x0040E614` | `0x0040E5D4` |
| impact sound | 0…44 | `0x0040E4F4` | `0x0040E4C8` |

The impact sound has only four outcomes: `ricochet.wav` @80 for the
conventional guns, `explosion2.wav` @81 for the throwers, `aexplosion.wav` @95
for the spore weapons, and silence.

A selection, with `Info.lcl`'s names — the complete table is
`tools/blob_tables.py --blobs`:

| id | Weapon | Muzzle | Impact | Sound |
|---|---|---|---|---|
| 2 | Standard Assault Rifle | `TracerBullet` | — | `ricochet.wav` |
| 4 | Double Fire | `DoubleFire` | — | `ricochet.wav` |
| 7 | Flame Thrower | `FlameStream` | — | — |
| 8 | Mine Thrower | `Grenade` | `FireExplosion` + `SparkingPlug` + `Explosion2` | `explosion2.wav` |
| 9 | Plasma Gun | `EnergyCannon` | `PlasmaExplosion2` | — |
| 13 | Mine Thrower Enhanced | `SpidyMines` | `0x00429180`, `0x00429C30` | `explosion2.wav` |
| 14 | Enhanced Laser Gun | `Laser` | `LaserHit2` | — |
| 17 | Explosives | `FireExplosion` + `SparkingPlug` + `Explosion2` + `ShockWave` | — | — |
| 23 | Sting Thrower | `TracerBullet` | `SporeExplosion` | `aexplosion.wav` |
| 36 | ParaBomb | — | `ShockWave` + `FireExplosion` | — |
| 44 | Multi-target Destroyer | `Grenade` | `FireWheel` | `explosion2.wav` |

Weapons 15, 20, 21, 27 and 30–32 — the melee weapons — select an arm that
creates no blob at all.

### 8.2 `CreateBGB`, the scripted emitter

The LCL command is [`20` §7.3](20-lcl-language.md)'s and its record layout is
documented there. What belongs here is the two switches that turn a `type` into
a blob:

| `type` | On registration (`0x0041DF10`) | On the tick (`0x0041E1A0`) |
|---|---|---|
| 1 | nothing | `aBlob_CreateSmoke2` |
| 2 | `aBlob_CreateWarningLight` | — |
| 3 | `aBlob_CreateComputerLight` | — |
| 4 | `aBlob_CreateCreateFire` (`A_FIRE3.3DI`) | — |
| 5 | `aBlob_CreateSpot` (`A_SPOTL.3DI`) | — |
| 6 | `aBlob_CreateCreateFire` (`L049EE00.3DI`) | — |
| 7 | *(out of range: nothing)* | `aBlob_CreateMainMapFire` |

Types 2…6 create their object once, at registration; types 1 and 7 are emitters
that spawn one blob every `live` ticks, gated by `rand(0, random)`.

---

## 9. What a `.cha` note does *not* do

[`40` §9](40-charisma-model-animation.md) establishes that the only note verb in
a gameplay animation is `BREAK`, and that it registers a
`StopAnimationAtNoteEventCallback`. This document adds the negative that a
remake needs: **`0x0042C5D0`, the routine that registers a note callback, has
exactly one caller in the whole image** (`0x00405B54`, the animation-start entry
`40` §7.2 describes). No note ever fires a sound and no note ever creates a
blob. Effects are placed by explicit code in the `aPlay*` routines, frame by
frame, not by markers in the animation data.

---

## 10. What a remake has to implement

1. A twenty-slot sound pool, or none at all — the original's cap is what makes
   a crowded turn drop sounds, and reproducing that is a choice, not an
   obligation.
2. The volume-control indirection: **every sound carries an id, and the id
   scales it by `Info.lcl`'s percentage.** The formula in §1.3 is exact.
3. A sound's lifetime is its sequence's (§1.4): start it when the sequence
   starts, stop it when the sequence ends, and loop the nine that loop.
4. The event → wave table of §2, the weapon fire sound of §3, the overheat
   trio of §2.3, the species round-robin of §4.1 and the footstep table of §5.
   Together they are the whole audible game except speech and music.
5. Case-insensitive wave lookup, or the ten renames in §2.2.
6. A blob pool with the record of §7.2 and the update of §7.4. The complete
   per-tick reference is [`tools/blob_runtime.py`](../tools/blob_runtime.py);
   integrate its 88-byte field semantics and `BlobHooks` boundary rather than
   re-deriving the 74 arms in the scene layer.
7. **The sprite path is cheap and worth doing exactly**: one 256×256 atlas,
   8 × 8 tiles, `(row, column, half-size × 160)` per particle, one blend mode
   for all of them, column advanced by the arm (§7.3). Roughly half the
   constructor calls — 54 of 116 — are that and nothing else.
8. The spawn graph of §7.7 — one trigger cascades, and a remake that only
   implements the first blob will look thin.
9. The three weapon switches of §8.1. Nothing else decides what a shot looks
   like.
10. **Joint angles for the two model effects (§7.8).** A remake's model format
    needs a per-part rotation a particle can write each tick, or the computer
    panel stops flickering and the fire stops moving. Three Euler triples per
    object is all the original has, and only two effects use more than the
    first.
11. Nothing for ambience.

The three audible defects above are **decided**, not left to be inherited by
accident ([`92` §7.1](92-remake-architecture.md)): weapon 35's unloadable fire
sound (§3.1) and unit type 24's doubled footsteps (§5) are reproduced by
default, behind one `Faithful` setting; the alien scream's human volume ids
(§4.1) are **fixed unconditionally**, because that defect leaves ids 53–55 dead
and would make an "alien voices" control do nothing.

---

## 11. Verification

```bash
python3 tools/blob_tables.py --check  gog_incubation   # 407 checks
python3 tools/blob_tables.py --waves  gog_incubation   # the event -> wave table
python3 tools/blob_tables.py --blobs  gog_incubation   # the blob and weapon tables
python3 tools/blob_tables.py --kinds  gog_incubation   # the 78 update kinds
python3 tools/blob_tables.py --joints gog_incubation   # the joint-angle buffer
python3 tools/blob_tables.py --json   gog_incubation
python3 tools/blob_runtime.py --selftest                 # all 78 update values
```

407 checks, all against the shipped binary and corpus; the tool exits non-zero
on an empty corpus and on a root that holds only `Incubation.exe`.

**Mutation testing.** A harness perturbs every leaf *and every key* of every
pinned constant in the tool and re-runs the whole check set: **3 314
mutations**. Nine checks are never tripped by any of them, and all nine are
relations over decoded data rather than equalities with a pin — "every literal
wave name resolves", "every volume id the code uses is defined in `Info.lcl`",
"every weapon arm's call lands on a blob creator", "the classes are 0…3",
"every sprite row is inside the grid". They would catch a wrong *corpus*, which
no constant mutation can simulate. **Every other check name has been shown to
fail.** The mutations no check notices are constants the prose quotes but no
check consumes — an address a section heading names, a duplicate of a value
that is checked through a derived table — and dictionary keys that are
positional rather than pinned.

What the checks anchor: the four slot bounds and the buffer record; the volume
formula's four constants and the 103 `SetVolumeCtrl` ids; all 62 wave call
sites with their names and volume ids, and the 17 direct ones; the case table;
the weapon wave field, format and volume-id register; the nine voice arms and
their two cursors; the eight footstep arms with their types, waves, ids and
periods; the five ambience slots' reference counts; the blob pool geometry, the
`object_3d` embedding against the world-object builder that shares it, all
fifteen constructor argument-to-offset stores, all 116 calls' model, class,
kind and lifetime, and every sprite call's atlas row, column and size; the
atlas itself — its name, its Eng3d ordinals, its 32-texel tile and its size in
all nine world sets; the 78-entry update table, the gravity constants, the
spawn graph, the two computed kinds, the one self-morph and the eleven
unreachable kinds; the 81 creators and their 57 recovered names; every play
site's loop flag and frame position and the four overheat callers; the three
weapon switches, arm by arm and call by call; both `CreateBGB` switches; the
single note-callback registration; and — 35 of the 252 — the joint buffer:
the reader's idiom in both renderer builds and its absence from all three
hosts, the seven handler slots the dispatch table gives it cross-checked
against our own opcode table, the angle mask and the two `TRIG.IMG` windows,
the null pointer both builders write, the one export that hands the buffer out
and its four-byte body in both builds, every `anim` operand in every shipped
render and part-info stream, the matrix/joint partition of the corpus against
both the `.lev` placements and the `.cho` mesh names, and each of the three
arms' model, its `joint_place` operands and the component of the triple every
store lands on.

---

## 12. Open questions

1. ~~**Native validation of the service hooks.**~~ **Closed** — §7.4.2.
   All five were called inside a running `Incubation.exe`: `0x00403AA0` and
   `0x0046D400` over twenty deltas each, `0x004039A0` over eight rotations,
   and the two lookups swept over their id ranges. Four of the five are
   reproduced exactly in portable arithmetic and checked against the capture
   answer for answer (`tools/blob_gold.py`, 161 checks); the remake's
   orientation service is the measured routine on both sides of its own diff.

   **What that does and does not license.** The service *return data* is
   measured, so a trajectory is no longer built on an invented helper — but
   the seventy-four arms are still a transcription compared against a
   transcription, so `test_blob.gd` keeps printing `executable-Python` and
   nothing in the blob layer claims `native-runtime`. Claiming otherwise would
   need the arms themselves stepped in the engine, which is a different
   capture.

   **One residue, named rather than rounded off.** Eng3d's own three-angle
   matrix builder behind `0x004039A0` is *recorded* and not reproduced: no
   ordering of `Rz Rx Ry` with either rounding matches all eight captured
   cases, and its two Eng3d entry points are runtime function pointers rather
   than imports, so a static read of them is a second capture's work. What is
   established about it is in the fixture and in §7.4.2's rounding note.

2. **Whether the eleven unreachable kinds were ever reachable.** §7.7 shows no
   call site can select them in the shipped build. Whether they are cut effects
   or arms for a debug path is not recoverable: the arms carry no strings and
   nothing else references them.

3. ~~**Which music family the GOG release plays.**~~ **Closed** — §6.1. The
   import descriptor settles it without reading the shim: `Incubation.exe`
   imports the nine `winmm` entry points from `audio.dll`, which is the shim
   built with `Arack`, and nothing in the tree imports the `Track` build. Eleven
   checks.

## 13. What the fifth slice added here

Two things belong in this document rather than only in the slice report.

**`RoofUnit`'s drop rate, which neither this document nor [`20`](20-lcl-language.md)
carried.** `0x00442030`'s animation routine `0x00411B00` runs its drop as a
loop at `0x00411DF3`: a frame tick (`0x0040B6F0`), then `sub eax, 0xC80` at
`0x00411E26`, then `aChangeStdObjectPosition` with `z + 0xA0`, repeating while
the falling object is above the floor. **A falling unit descends one whole map
field — 3 200 world units — per displayed frame**, from the `height · 1600` the
command's third argument names. The shipped heights of 20 to 65 are therefore
10 to 33 frames. `blob_tables.py` pins the step, the draw offset, the tick and
the "one map field" identity.

**§4.1's defect and [`92` §7.1](92-remake-architecture.md)'s justification for
fixing it do not quite agree, and the fix is still right.** `92` says the
alien scream's defect "leaves ids 53–55 defined and dead". It does not: 53–55
carry a *second* `SP_HUM_0/1/2` label in `Info.lcl` and are unnamed by any call
site before the correction **and after it**. What the correction does is make
the alien scream read 59/60/61 — the ids `Info.lcl` labels `S_ALI_0/1/2` — so
that an "alien voices" control moves something. That is still the
inert-control case; only the accounting of which ids were dead was wrong.

## 14. What closing the fifth slice's own loose ends added

Three things, and two of them close questions this document had left open.

**The music family (§6.1, open question 3).** Read out of the import table
rather than out of the shim: the shipped build plays `Arack`.

**The step period is one global (§5.1).** Six arms write `0x004FAECC` and the
seventh does not, so `aStartWalkAnimationSound` is not a pure function of the
unit type and a Squeether inherits. The address is in the zero-filled tail of
`.data`, so its start value is 0 and the first Squeether of a mission has no
period at all.

**Which matrix builder the joint opcodes use** — which is
[`30` §2.5](30-eng3d-ascii-formats.md)'s open item rather than this document's,
and §7.8 is where it was needed. `joint_rotate_3` (`Eng3d.dll+0x405FFC`) and
`joint_place` (`Eng3d.dll+0x4060F0`) both call `E3D_init_matrix_RzRxRy` at
`+0x411BF6`; `joint_rotate_3_alt` and `matrix_from_angles` call the other one,
`+0x411A93`, and no shipped joint prototype uses either of those. So the
composition order of a part's three angles is settled for every prototype the
game actually draws. Three checks.

**The set-piece frame counts and per-frame steps now have a second reading
here.** [`20` §7.4](20-lcl-language.md) recovered them from the four animation
routines and this document quoted the numbers; a quoted number is not a pin,
and a mutation battery over all six found that nothing checked them. They are
decoded now — the loop counter's `mov imm32` proved to be a counter by the
`dec` that follows it, and the `lea`/`shl` pair the compiler emitted for each
step:

| | Routine | Frames | Step |
|---|---|---|---|
| `OpenDoor` | `0x00410A20` | `mov ebp, 0xA` at `+0x2DC` | — |
| `Bridge` | `0x00410DA0` | `mov ebx, 0x50` at `+0x11F` | `lea ×3` then `shl 2` = **12** |
| `Elevator` | `0x004125D0` | the command's `steps` | `lea ×5`, `lea ×5`, `shl 5` = **800** |
| `Platform` | `0x00412A00` | `lea ×5` then `shl 1` = `dist * `**10** | `lea ×5` then `shl 6` = **0x140** |

The same technique gives §7.3's sprite half-extent: `and eax,0xff; lea
eax,[eax+eax*4]; shl eax,5` at `0x004040F0` is the `size * 160` this document
already stated, and only the shift had been pinned.


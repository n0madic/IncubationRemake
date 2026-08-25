# Research plan — the game logic

The file formats are finished: every entry in [`00`](00-overview.md)'s inventory
is **Solved** and has a parser that consumes 100 % of its corpus. What is not
finished is the *runtime* — the rules that turn those files into a game.

This document is the plan for closing that gap. It is a **living file**: when a
package is done, its row moves to "delivered" and the questions move into the
spec it produced, with the evidence, the way every other doc in this set does
it. It is not a spec and states no findings of its own; everything here is
either measured (the module map) or a question.

**Scope.** Packages **A, C, B, D+E, F, G** below. Multiplayer and play-by-mail
(**H**) are explicitly out of scope — see §9. **A, C, B and D+E are
delivered**; F and G are not.

---

## 1. How much is left, measured

`trace_names.py` recovers 324 function names from `Incubation.exe`. **90 of them
appear somewhere in `docs/`; 234 do not.** The measure is rough — a doc can
describe a function by address without naming it — but the order is right: the
part of the engine that *reads data* is described, the part that *plays* mostly
is not.

The sharper measure is the module map below. Every function in the release
build pushes its own `__FILE__` on the error path, so mapping those pushes
partitions the 702 KB of `.text` into the original source modules. The span of
a module is taken from its first `CHECK` site to the next module's first, so it
is an upper bound that also absorbs any neighbouring function with no `CHECK`
site at all.

| Module | First site | Span | Sites | State |
|---|---|---|---|---|
| `aBlobs.cpp` | `0x0041DE5B` | 53.7 KB | 263 | the pool, the constructor, the update switch and every trigger described — [`28` §7, §8](28-effects-and-sound.md); the 74 update arms are named only by their kind ids |
| `aAnimations.cpp` | `0x0040B5AD` | 48.5 KB | 458 | the door and set-piece sequences described — [`20` §7.3](20-lcl-language.md), [`26`](26-interaction.md); every sound and effect it fires — [`28` §2, §8](28-effects-and-sound.md); the frame stepping itself is not decoded |
| `aMissionControl.cpp` | `0x00453F9A` | 37.1 KB | 138 | the campaign map, the roster screens and the location dispatch described — [`27`](27-campaign.md); the screen layouts are package F's |
| `aTacTools.cpp` | `0x0046A463` | 25.8 KB | 183 | described — [`22`](22-combat-and-visibility.md), [`26`](26-interaction.md) |
| `aMenuSystem.cpp` | `0x0044B238` | 22.1 KB | 100 | **dark** — package F |
| `a3DObjects.cpp` | `0x004046C1` | 20.7 KB | 226 | partly — [`30`](30-eng3d-ascii-formats.md), [`31`](31-prototyp-geometry.md); package C touches it |
| `aSeqPlayer.cpp` | `0x0046543A` | 20.0 KB | 18 | **dark** — package G |
| `aLCL_Com.cpp` | `0x004407D5` | 18.9 KB | 52 | described — [`20` §7](20-lcl-language.md) |
| `aUnitMap.cpp` | `0x0047776B` | 17.4 KB | 112 | described — [`22` §5](22-combat-and-visibility.md), [`26` §2](26-interaction.md), [`27` §3](27-campaign.md) (the roster lives here, not in `aMissionControl.cpp`) |
| `aBattleSystem.cpp` | `0x00419DB9` | 16.2 KB | 44 | the hand-over's refresh entry described — [`25` §5](25-turn-and-round.md) |
| `aUnitInfos.cpp` | `0x00473A41` | 15.3 KB | 24 | **dark** — package F |
| `aCtrlMap.cpp` | `0x0042EBAB` | 14.4 KB | 31 | described — [`10`](10-lev-mission-format.md), [`23`](23-ai-system.md), [`26`](26-interaction.md) |
| `a3DEngine.cpp` | `0x0040104B` | 13.6 KB | 106 | partly — [`31`](31-prototyp-geometry.md) |
| `aViewPlayer.cpp` | `0x0047BD0B` | 13.3 KB | 54 | described — [`25` §4](25-turn-and-round.md) |
| `aMI.cpp` | `0x00450AC8` | 12.8 KB | 33 | **dark** — package F (map interface) |
| `aUI.cpp` | `0x00471101` | 10.3 KB | 45 | **dark** — package F (unit interface) |
| `aGUI.cpp` | `0x0043BF5B` | 10.2 KB | 76 | text box described — [`24`](24-briefing-text.md); package F |
| `aBattleMap.cpp` | `0x004177BA` | 9.5 KB | 52 | loading described — [`10`](10-lev-mission-format.md) |
| `aAISystem.cpp` | `0x00409984` | 6.7 KB | 21 | described — [`23`](23-ai-system.md) |
| `aMissionEnd.cpp` | `0x0045D40A` | 6.4 KB | 27 | described — [`27` §6](27-campaign.md) |
| `aLoad.cpp` | `0x00447BF2` | 6.3 KB | 44 | described — [`11`](11-save-game-format.md) |
| `aDSound.cpp`, `aCDRom.cpp`, `aAmbience.cpp` | — | — | 20 | described — [`28` §1, §6](28-effects-and-sound.md); `aAmbience.cpp` turns out to be a stub |
| `aPassWord.cpp` | `0x0046246C` | 3.9 KB | 9 | identified — the play-by-mail password screen, [`27` §7](27-campaign.md); **out of scope**, §9 |
| `aPI.cpp` | `0x00463411` | 1.6 KB | 8 | identified — the **Place Interface**, the deploy screen ([`90` §2](90-binaries-and-source-layout.md)); its rules are package F's |
| `aMultiPlayer.cpp`, `lNetwork.cpp`, `aDPlay.cpp`, `aMsgTools.cpp` | — | — | 34 | **out of scope** — §9 |

`aBlobs.cpp` and `aAnimations.cpp` are the two largest modules in the game.
When this plan was written neither was described by a single line anywhere in
`docs/`; [`28`](28-effects-and-sound.md) now covers what each of them *does*,
though not every one of `aBlobs.cpp`'s 74 update arms.

---

## 2. The method

Every package below uses the procedure that produced [`22`](22-combat-and-visibility.md),
[`23`](23-ai-system.md) and [`24`](24-briefing-text.md). It is stated once here
so no package has to repeat it.

1. **Name the functions.** `trace_names.py <binary>` for the symbol table, then
   the `__FILE__` map above to fix which module a function belongs to. When a
   name and a `__FILE__` disagree, the `__FILE__` wins ([`22` §1](22-combat-and-visibility.md)).
2. **Enumerate, do not search.** A claim of the form "nothing else touches this"
   is only acceptable as a sweep of every reference in `.text`, with a positive
   control proving the sweep can find something. Selector values are recovered
   by enumerating call sites that pass literals, not by guessing enum names.
3. **Anchor to data.** Every claim that can be, is checked against 100 % of a
   corpus and stated `N/N`. Where there is no corpus — package A has none — the
   binary itself is the corpus: pin the constants, the tables and the call sites.
4. **Ship a checker.** One tool per package, `--check <root>`, failing on an
   empty corpus, mutation-tested: each check must be shown to fail when the byte
   or token it covers is changed.
5. **Write the spec, keep the unknowns.** A doc with an **Open questions**
   section, `UNVERIFIED` on anything inferred, no invented names.

---

## 3. Package A — the turn and the round — **delivered**

> **Delivered** as [`25-turn-and-round.md`](25-turn-and-round.md) with
> `tools/turn_tables.py --check` (85 checks, 102 mutations, 0 missed). Questions 1–5 are
> answered there; question 6 is answered in
> [`11` §5.6](11-save-game-format.md), where the block belongs. What stayed
> open moved into `25`'s own Open questions section: the `pbm session` mode no
> literal selects, one multiplayer session flag, `unit[+0x50]`'s missing reader,
> and one interface routine that belongs to package F. The section below is kept
> as written so the plan can be read against what it produced.

**Why first.** [`23`](23-ai-system.md) describes the computer's half of a turn
and [`22`](22-combat-and-visibility.md) describes what a shot does. Nothing
describes the frame around them: whose turn it is, what a turn restores, what
ends it. Without this a remake has combat and an opponent but no game.

**Modules.** `aViewPlayer.cpp`, `aBattleSystem.cpp`, `aGameControl.cpp`,
`aUnitInfos.cpp`.

**Known entry points.** `aNextPlayerHandling` `0x0047DC60`,
`aSearchFirstPlayer` `0x0043B410`, `aChangeUnitInfo` `0x00479BA0`,
`aToggleWeaponModes` `0x0047A8C0`, `aSaveViewPlayer` / `aLoadViewPlayer`
`0x0047DBE0` / `0x0047DC20`.

**Questions.**

1. Player order: who moves first, how many players a battle has, how the
   pseudo-players (252, 255 — [`23` §9](23-ai-system.md)) fit into the rotation.
2. What hand-over restores: movement points, the "has acted" flag `unit[+0x39]`,
   heat, the action state.
3. **Reaction fire.** The action state at `unit[+0x41]` is read by the AI's
   target filters ([`23` §5.2](23-ai-system.md)) and by planner kind 12, and the
   AI writes 4 into it after firing — but who sets and clears the value 1, "a
   reaction pending", is not known. This is the mechanic a remake
   is most likely to get wrong.
4. Weapon modes: `aNextPlayerHandling` calls `aToggleWeaponModes` for units
   whose weapon id is ≥ 20 and differs from a byte in its own `SetWeaponInfo`
   record — the exact rule, and what a "mode" is, are open.
5. End of turn and end of round: what advances the round counter, and what the
   LCL mission program sees of it ([`20` §5](20-lcl-language.md)).
6. **ViewPlayer's 1100 bytes** — [`11`](11-save-game-format.md) opens this as a
   save-game question. It is the same subject: `aViewPlayer.cpp` owns both the
   turn hand-over and that block, so package A should close a `11` item too.

**Corpus.** None directly; `.lev` gives the starting state and `Info.lcl` the
per-unit constants, so the checks are binary-side plus a replay of the
turn-start arithmetic against every unit type in the corpus.

**Deliverable.** `docs/25-turn-and-round.md`, `tools/turn_tables.py --check`.

---

## 4. Package C — interaction and set-pieces — **delivered**

> **Delivered** as [`26-interaction.md`](26-interaction.md) with
> `tools/interaction_tables.py --check` (109 checks, 112 mutations, 0 missed,
> all 109 check names shown to fail).
> Questions 1, 2, 3 and the direct half of 4 are answered there; question 5
> turned out to be unanswerable from this corpus — field type 8, `Ladder`, has
> **0 cells** in all 155 shipped missions — and is restated as `26`'s fifth
> open question rather than dropped. The package also closed two items that
> belong to other docs: [`10` §4.1](10-lev-mission-format.md)'s fourth
> `SetCtrlMapInfo` column (dead data, by an enumerated sweep) and five
> equipment ids in [`21` §3](21-info-lcl-schema.md). The section below is kept
> as written so the plan can be read against what it produced.

**Why second.** It closes `.lev`. [`10` §4.6](10-lev-mission-format.md) recovers
the developers' own names for 38 action-point values — doors, crates, buttons,
levers, teleporters, entry points — so we know what every cell *is*. What
happens when a unit uses one is written down for exactly one case: the door,
because the AI opens doors ([`23`](23-ai-system.md)).

**Modules.** `aCtrlMap.cpp`, `a3DObjects.cpp`, `aAnimations.cpp`,
`aGameControl.cpp`.

**Known entry points.** `aPlayTeleporterSequence`, `aPlayUseLeverSequence`,
`aPlayDestroyMineSequence`, `aPlayDestryoEntrypointSequence` (the typo is the
developers'), `aDoorOpenSequence` `0x00410A20`, and the three obstacle makers
`0x0042F840` / `0x0042FA70` / `0x0042FB90` already decoded in
[`23` §13](23-ai-system.md).

**Questions.**

1. One entry per action-point class: cost in movement points, preconditions,
   what changes in the cell record, what animation and sound fire.
2. Crates and supply: what a crate gives, whether it is consumed, how it
   interacts with the equipment ids in [`21` §3](21-info-lcl-schema.md).
3. Teleporters: the entry/exit pairing rule, and whether the AI can use them
   (the move map says no — [`23` §7.3](23-ai-system.md) — which is worth
   confirming from the player side).
4. Levers, buttons and the objects they drive — the LCL commands `Bridge`,
   `OpenFrontDoor`, `OpenPlantTube` ([`20` §7.3](20-lcl-language.md)) are the
   scripted half; the direct half is not described.
5. Ladders and height: [`23` §7.4](23-ai-system.md) has the AI's rule (a
   ladder-to-ladder step costs the whole allowance); the player's rule is
   assumed identical and has not been checked.

**Corpus.** 155 `.lev` files: every action-point value, its counts and its
neighbourhood are already extractable, so each rule can be stated against the
cells that actually exist.

**Deliverable.** `docs/26-interaction.md`, extending `tools/lev_parse.py` or a
new `tools/interaction_tables.py --check`.

---

## 5. Package B — the campaign layer — **delivered**

> **Delivered** as [`27-campaign.md`](27-campaign.md) with
> `tools/campaign_tables.py --check` (237 checks, 223 mutations,
> 0 missed, every check name shown to fail).
> Questions 1–5 are answered there, and so is the follow-on the first revision
> of `27` had to leave open: **all 30 `setMissionResult` sites are now
> enumerated and classified** ([`27` §6.4](27-campaign.md)), which turned up
> three engine-side defeats the campaign really has and corrected the
> document's own reading of the win/lose gate. Question 6 turned out to rest on a wrong
> premise and is answered by correcting it: **`aPassWord.cpp` is the
> play-by-mail password screen**, not mission passwords — its comparison reads
> the four 25-byte slots [`11` §5.3](11-save-game-format.md) already documents,
> so there are no level codes in this game and the module is package H's, which
> is out of scope (§9). The package also closed items belonging to three other
> docs: [`11` §5.2](11-save-game-format.md)'s `+0x01D1` (the campaign number),
> [`11` §5.5](11-save-game-format.md)'s mission-result score table (it was
> rotated by one — read from the arms' addresses rather than the compiler's
> jump table), [`11` §5.7](11-save-game-format.md)'s open reading of the two
> roster rows, and the gate on [`20` §7](20-lcl-language.md)'s game-control
> slots 10 and 11. `aPI.cpp` and `aDataBase.cpp` are identified in
> [`90` §2](90-binaries-and-source-layout.md) as a side effect, which settles
> §7's item 3. The section below is kept as written so the plan can be read
> against what it produced.

**Why third.** Needed for the second mission, not the first. A remake can ship a
skirmish against the AI without any of it.

**Modules.** `aMissionControl.cpp`, `aMissionEnd.cpp`, `aDataBase.cpp`,
`aLoad.cpp`, `aPassWord.cpp`.

**Known entry points.** `aCreateUnitPoolForCampaign`, `aAddUnitToUnitPool`,
`aCopyUnitPool`, `aEnlargeUnitPool`, `aLoadUnitPool`, `aInitPassWord`,
`aCreateLocationMap`.

**Questions.**

1. The unit pool: where it lives, what carries between missions, how it is
   seeded and grown.
2. Experience and rank. [`21` §5](21-info-lcl-schema.md) records that maximum
   HP gains `rank/12` capped at 15 for anything but the computer — where rank
   comes from, and what else it affects, is open.
3. Equipment points: the `.lev` header carries `Equipmentpoints [0,3000]`
   ([`10` §3](10-lev-mission-format.md)); the spending rules on the Upgrade and
   Recruit screens are not described.
4. Mission chaining: how the campaign map decides what is unlocked, and what
   `Campaign.lcl` and the location ids in `Info/Campaign.txt`
   ([`24` §7.2](24-briefing-text.md)) have to do with it — note that
   `Campaign.txt` is placeholder data no code can name, so the ids live
   somewhere else.
5. Mission end: victory and defeat evaluation, the debriefing screen, what is
   written back to the pool.
6. **Mission passwords** — `aPassWord.cpp` is nine `CHECK` sites and about
   3.9 KB. Small, self-contained, and a nice first result for this package.

**Corpus.** 155 `.lev` headers, `Info.lcl`, the campaign `.lcl` scripts. Three
of [`11`](11-save-game-format.md)'s four open items need one real save game —
those stay open until a save exists, but the *runtime* rules do not depend on
having one.

**Deliverable.** `docs/27-campaign.md`, `tools/campaign_tables.py --check`.

---

## 6. Packages D + E — effects and sound — **delivered**

> **Delivered** as [`28-effects-and-sound.md`](28-effects-and-sound.md) with
> `tools/blob_tables.py --check` (252 checks, 3 314 mutations; every check name
> shown to fail except nine relations over decoded data, which no constant
> mutation can simulate — see [`28` §11](28-effects-and-sound.md)).
> All four questions are answered there. Question 3 was answered twice over:
> the animation state machine is [`40` §7.2](40-charisma-model-animation.md)'s
> and already existed, and its remaining half is a *negative* — the `.cha`
> event notes drive neither blobs nor waves, because the one routine that
> registers a note callback has a single caller in the whole image and it
> registers the `BREAK` stop. Effects are placed by explicit code in
> `aAnimations.cpp`, and a sound's lifetime is its blocking sequence's.
> Question 2's "colours" turned out to be a category error: **there are no
> colour parameters.** A class 2 or 3 blob is a quad textured from one 256×256
> atlas called `anim`, an 8 × 8 grid of 32 × 32 sprites, and its whole
> appearance is *(row, column, half-size)* — the palette is in the texture.
> The structural key was that a blob **is** an Eng3d `object_3d` with eight
> fields bolted on, which reattributed four "scratch" offsets to Eng3d and put
> the 64-byte record where it belongs, in
> [`30` §2.12](30-eng3d-ascii-formats.md). Every one of the 78 update kinds is
> now named by the creators that pass it, classed, and its spawn graph decoded;
> eleven are unreachable. What stayed open moved into `28`'s own Open questions
> section: the per-tick constants of the 74 arms (readable, not transcribed)
> and whether the eleven unreachable kinds ever were. The four "scratch" fields
> were closed in a follow-up: they are the **joint angles** of the model's
> articulated sub-objects, read by seven Eng3d render opcodes at a byte offset
> the prototype's own bytecode supplies, written by the two arms whose models
> have parts ([`28` §7.8](28-effects-and-sound.md),
> [`30` §2.12](30-eng3d-ascii-formats.md)). That also falsified
> [`31`](31-prototyp-geometry.md) §9 item 1's conclusion that the joint buffer
> is never filled — the host fills it directly, because the host owns the
> record — and corrected slot 13 of the opcode table, which takes an `anim`
> operand. The package also corrected
> [`40` §7.2](40-charisma-model-animation.md) — the animation selectors switch
> on the unit's *type* and *weapon* bytes, not on a "state" and a "type" — and
> [`30`](30-eng3d-ascii-formats.md), where `_E3D_object_3d_check_in` is
> ordinal **9**, not 12. Three shipped defects it turned up are recorded rather
> than smoothed over: `Info.lcl`'s weapon 35 has an unloadable wave name and no
> `SetWeaponInfo` record at all, unit type 24's footsteps are scaled by a
> weapon-band volume id, and the alien scream is scaled by the human ids. The
> section below is kept as written so the plan can be read against what it
> produced.

**Why together.** They fire from the same places: an animation frame triggers
both a blob and a wave.

**Modules.** `aBlobs.cpp` (53.7 KB, 263 sites), `aAnimations.cpp` (48.5 KB, 458
sites), `aDSound.cpp`, `aAmbience.cpp`, `aCDRom.cpp`.

**The free map.** All 57 `aBlob_*` functions are named by the developers
and the names are descriptive: `Explosion2`, `FireExplosion`,
`SmallFireExplosion`, `PlasmaExplosion2`, `SporeExplosion`, `ShockWave`,
`FireWheel`, `FireCircle`, `FlashCircle`, `FlameStream`, `TracerBullet`,
`Laser`, `LaserBarrier`, `LaserHit2`, `Needles`, `Grenade`, `ParaBomb`,
`SpidyMines`, `SporeCannon`, `EnergyCannon`, `PlasmaBallImpact`, `SporeSparks`,
`PlasmaSparks`, `StingSparks`, `SparkingPlug`, `SparkingRain`, `HittingBlobs`,
`BloodFlood`, `FlyingDebris`, `BarrelDebris`, `LandingDust`, `TubeSmoke`,
`Smoke2`, `Spores`, `KillFire`, `CreateFire`, `FireDeath`, `MainMapFire`,
`WarningLight`, `ComputerLight`, `Spot`, `ZoomBob`, `Bomber`, `FlyingUnit`,
`Flash`. The work is to attach each to its trigger, not to guess what it is.

**Questions.**

1. Which weapon, impact, death or event calls which blob — the mapping from
   [`21` §4](21-info-lcl-schema.md)'s weapon table and
   [`22` §7](22-combat-and-visibility.md)'s resolver into `aBlobs.cpp`.
2. The blob's own parameters: lifetime, particle counts, colours, the model or
   texture each uses.
3. The animation state machine in `aAnimations.cpp`: which Charisma animation
   ([`40`](40-charisma-model-animation.md)) plays for walking, turning, firing,
   being hit, dying, and how the `.cha` event notes drive the blobs and waves.
4. Sound: the event → wave mapping. `SetVolumeCtrl` is settled
   ([`21` §6](21-info-lcl-schema.md)) and the weapon table carries wave names;
   `aAnimationSoundPlay`, `aStartWalkAnimationSound`, `aStopWalkAnimationSound`
   and the ambience layer are not described. Music is Ogg and needs no work
   beyond the playlist.

**Corpus.** 407 `.wav`, 245 `.cha`, the weapon and unit tables. Every wave name
in `Info.lcl` can be resolved against the shipped files — a check of the same
kind as [`24`](24-briefing-text.md)'s picture-name resolution.

**Deliverable.** `docs/28-effects-and-sound.md`, `tools/blob_tables.py --check`.
This package is the one that can be done incrementally alongside development:
each blob closed is one effect the remake can implement.

---

## 7. Package F — the GUI runtime, only as far as a new interface needs

**Deliberately bounded.** The remake will draw its own interface. What it must
not reinvent is the *information* the original interface carried and the
*rules* those screens enforce. Layout, fonts and button art are already
extractable ([`60`](60-lib-sprites.md), [`24` §4.1](24-briefing-text.md)) and
are reference material, not a specification to reproduce.

**In scope.**

1. `aUI.cpp` — the unit interface: which numbers the panel shows, and where each
   comes from. That is the contract a remake's HUD has to satisfy.
2. `aMI.cpp` — the map interface: cursor modes, what a click does in each mode,
   what the overlays mean (the AI's own overlays are already decoded —
   [`23` §6, §10](23-ai-system.md)).
3. `aPI.cpp` — 1.6 KB, eight sites. **Identified**: the Place Interface, the
   deploy screen ([`90` §2](90-binaries-and-source-layout.md),
   [`27` §3.4](27-campaign.md)). What remains is its rules, not its identity.
4. The screens that carry *logic* rather than layout: unit selection, Upgrade,
   Recruit — shared with package B.
5. `Menu_*.lcl` and `Txtmod_*.lcl` as the source of screen structure and every
   user-visible string ([`20` §5.3, §6](20-lcl-language.md)) — enough to build a
   localised interface without hard-coding English.

**Out of scope.** `aMenuSystem.cpp`'s 22 KB of front-end flow, `aGadgets.cpp`,
list boxes, the mouse driver, and pixel-exact reproduction of any screen.

**Deliverable.** `docs/29-interface-contract.md` — deliberately a *contract*,
not a spec of the original UI.

---

## 8. Package G — the sequence player

**Why it is in scope.** The dialogue scenes are not video files. `Video/Dialog_*`
holds `.cha` animations and an `IMG` directory, so the cutscenes are the same
Charisma engine driving the same models — which means a remake can play the
original scenes rather than replace them, and that is most of the game's
atmosphere.

**Modules.** `aSeqPlayer.cpp` (20 KB, 18 sites), `a3DEngine.cpp`.

**Known entry points.** `aCreateSeqPlayer` `0x004653E0`, `aStartSeqPlayer`
`0x00465B70`, `aSetSeqPlayerVideoPart` `0x00465CC0`, `aDestroyPlayer`
`0x00465C00`.

**Questions.**

1. What a "sequence" is made of: the scene description, the camera path
   (`aGetCameraPath`), the actor list, the timeline.
2. How `Video/<name>/` is laid out and which file drives the rest — the same
   kind of chain-walk [`00`](00-overview.md) documents for missions.
3. What "video part" means, and how speech (`.wav`) and subtitles
   ([`24`](24-briefing-text.md)'s info boxes) are synchronised to it.
4. Which sequences exist and what triggers each — the LCL `Sequence` and
   `Dialog_N` entry points ([`20` §5.2](20-lcl-language.md)) are the trigger
   side and are already described.

**Corpus.** The twelve `Video/*` directories — seven `Dialog_*`, four `Seq_*`
and `Extro`. Every one
must load through the resulting parser — the usual `N/N`.

**Deliverable.** `docs/41-sequence-player.md`, `tools/seq_parse.py --check`.

---

## 9. Out of scope — H, multiplayer and play-by-mail

`aMultiPlayer.cpp`, `lNetwork.cpp`, `aDPlay.cpp` and `aMsgTools.cpp` — about
34 `CHECK` sites over four modules, plus DirectPlay itself. Skipped
deliberately: a remake would not reuse DirectPlay, and a modern netcode design
is a product decision rather than a reverse-engineering one.

What is already covered and does not need this package: the multiplayer map
types and their `.lev` fields ([`10` §3](10-lev-mission-format.md)), the
Victorypoints action-point band ([`10` §4.6](10-lev-mission-format.md)), and the
play-by-mail save layout ([`11`](11-save-game-format.md)).

What it would cost to add later: the turn-exchange format for PBM, which is a
`.sav` variant and therefore mostly a re-read of [`11`](11-save-game-format.md);
and `aOutputMissionObjectsForMultiPlayer`, which is the state-sync contract.

---

## 10. Order, and what unblocks what

| # | Package | Deliverable | Depends on | Unblocks |
|---|---|---|---|---|
| 1 | ~~**A** turn and round~~ **delivered** | [`25`](25-turn-and-round.md), `turn_tables.py` | — | a playable battle; [`11`](11-save-game-format.md)'s ViewPlayer item partly closed |
| 2 | ~~**C** interaction~~ **delivered** | [`26`](26-interaction.md), `interaction_tables.py` | A (action costs) | mission objectives that use doors, crates, levers |
| 3 | ~~**B** campaign~~ **delivered** | [`27`](27-campaign.md), `campaign_tables.py` | A, C | mission 2 onward |
| 4 | ~~**D + E** effects and sound~~ **delivered** | [`28`](28-effects-and-sound.md), `blob_tables.py` | — (independent) | the game's feel |
| 5 | **F** interface contract | `29` | A, B | a UI that shows the right numbers |
| 6 | **G** sequences | `41`, `seq_parse.py` | — (independent) | the story scenes |

**A, C and B are the critical path, and all three are delivered**, as is the
independent D+E. G is independent and can be
picked up whenever someone wants a change of subject; F is best done after A and
B, because most of its content is *their* content displayed.

**Development need not wait.** Loading, terrain, models, animations, textures,
fonts, sprites, balance tables, combat, visibility, the AI and all mission text
are specified and checked today. A remake can be built against those while this
plan is worked through — see [`92`](92-remake-architecture.md) for the engine,
language and pipeline decisions that work rests on.

---

## 11. Definition of done, per package

A package is finished when, and only when:

- its spec exists in `docs/`, ends with an **Open questions** section, and every
  inferred claim is marked `UNVERIFIED` with its observed distribution;
- its tool runs `--check <root>`, states coverage as `N/N`, and **fails on an
  empty corpus**;
- every check has been shown to fail under a mutation of the byte, token or file
  it covers;
- [`00`](00-overview.md)'s inventory and open-question table, `CLAUDE.md`'s
  command list and `tools/README.md` are updated in the same change;
- and this file's row is moved to delivered, with the questions that turned out
  to be unanswerable restated in the spec rather than dropped.

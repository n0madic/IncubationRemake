# Binaries, engines, and the original source layout

Background material for the format specs: what each shipped binary is, and what
the original Blue Byte source tree looked like. All of it is recovered from
strings and RTTI left in the release build.

---

## 1. Executables and libraries

| File | Role |
|---|---|
| `Incubation.exe` | The game. Contains the LCL interpreter and its full command table. |
| `iDesigner.exe` | The real level editor. Reads and writes `.lev`; source tree `C:\aProject\Designer\`. Built **1998-05-04**. |
| `Editor.exe` | **Not part of this game.** Its PE header is stamped **1992-06-19**, six years before the game shipped, and it shares no source paths with the rest. It is unrelated leftover, which settles the community observation that it "is not the working editor". |
| `Eng3d.dll` | The software 3D renderer. Source `D:\PRO\3DLIB\eng3d\` (`cinit3d.c`, `cglide.c`, `wineng3d.c`). Also contains the VISN texture codec (original module `SRC\devision.asm`). |
| `ENG3DFX.DLL` | The 3dfx/Glide variant of the renderer. |
| `ENGWLIB.DLL`, `NewToolsR.dll`, `BGLWin.dll`, `BGLWinR.dll`, `aWin.dll` | Support libraries. `BGLWin` exposes `CBGLDialog`; `NewTools` is the container/utility library (`bbdlist`, `bbdynarray`, `bbstring`, `bbrandom` — source `D:\Projects\NewTools\`). No public documentation exists for any of these. |
| `glide*.dll`, `3DfxSpl*.dll` | nGlide wrapper shipped by GOG, not original. |
| `audiere.dll`, `libogg`, `libvorbis*` | GOG's CD-audio replacement layer. |
| `Settings.exe` | **Not original.** Stamped **2013-04-16** and built almost entirely of GIF resources — the GOG-era configuration front end. It contains none of Blue Byte's code and nothing about the game's own options. |

`Incubation.exe -debugx` opens Blue Byte's internal developer menu, with entries
**Debug A**, **Librarytool**, **Systeminfos**, **MapDesigner**. `Librarytool`
(`aLibTool.cpp`) opens and saves `Libs/*.LIB` shape libraries — see
[`60-lib-sprites.md`](60-lib-sprites.md).

### 1.1 The exported surface (what a Wine harness can call)

Every `.exe` has an **empty export directory** — game logic is reachable only
at internal addresses (`tools/trace_names.py` names 324 of them).  All
directly callable engine entry points live in `Eng3d.dll`: 89 `_E3D_*`
cdecl exports covering collision (`_E3D_check_collision*`,
`_E3D_get_face_equation_of_collided_faces`), the software rasterizer
(`_E3D_c_draw_*_polygon`), fixed-point math (`_E3D_fsin/_E3D_fcos`,
`_E3D_calc_angle_dx_dy`) and the VISN codec (`_E3D_init_vision`,
`_E3D_decode_picture[_halve_size]`).  `ENG3DFX.DLL` is the same set minus
`_E3D_get_engine_version`; `NewToolsR.dll`/`aWin.dll` export the `BB::`
utility classes (three RNG generators, containers, `String`).
Committed listings cover only these six original libraries
([`tools/exports/`](../tools/exports/README.md)), verified by
`pe_exports.py --check gog_incubation`; the `winmm` shims, GOG wrappers and
CRT are deliberately not listed.  The headless harness built on this
surface is `tools/wine_visn/`.

---

## 2. Original source tree

Reconstructed from assert/error strings embedded in the binaries.

```
C:\aProject\
    aLIB\                       Blue Byte's platform layer
        aBmpTools.cpp  aCDRom.cpp   aDDraw.cpp   aDIB.cpp
        aDPlay.cpp     aDSound.cpp  aFile.cpp    aFont.cpp
        aGadgets.cpp   aLibTools.cpp aMem.cpp    aMisc.cpp
        aMouse.cpp     aOutSys.cpp  aScrTools.cpp aWinTools.cpp
    Project\Sources\Game\
        Main\           aMain.cpp
        Modules\        a3DEngine.cpp  a3DObjects.cpp  aAmbience.cpp
                        aBattleMap.cpp aBlobs.cpp      aCtrlMap.cpp
                        aGUI.cpp       aInfo.cpp       aLCL.cpp
                        aLCL_Com.cpp   aMI.cpp         aOptions.cpp
                        aPI.cpp        aSeqPlayer.cpp  aTxtSys.cpp
                        aUI.cpp        aUnitInfos.cpp  aUnitMap.cpp
        GameTools\      aAISystem.cpp  aAnimations.cpp aDataBase.cpp
                        aGameControl.cpp aMsgTools.cpp aMultiPlayer.cpp
                        aTacTools.cpp  lNetwork.cpp
        Objects\        aBattleSystem.cpp aLoad.cpp    aMenuSystem.cpp
                        aMissionControl.cpp aMissionEnd.cpp
                        aPassWord.cpp  aViewPlayer.cpp
        Dialogs\        aEdit.cpp  aLibTool.cpp  aNew.cpp  aSelectObject.cpp
    Designer\Sources\Game\
        Main\           aMain.cpp
        BattleMap\      aBattleMap.cpp      <- writes .lev
        Objects\        aBattleSystem.cpp

D:\PRO\3DLIB\eng3d\             cglide.c  cinit3d.c  wineng3d.c
D:\Projects\NewTools\           bbdlist  bbdynarray  bbrandom  bbslist  bbstring
```

The mapping from module to format is direct and useful when hunting for a
loader: `aCtrlMap.cpp` and `aUnitMap.cpp` own the two big `.lev` arrays,
`aLCL.cpp`/`aLCL_Com.cpp` own the script language, `aLibTools.cpp` owns `.LIB`,
`a3DObjects.cpp` owns the scenery blocks.

### 2.1 Runtime-module map

Every release-build function pushes its own `__FILE__` on an error path.
Mapping those pushes partitions the 702 KB `.text` section into the original
modules. A span runs from a module's first `CHECK` site to the next module's
first site, so it is an upper bound and may absorb neighbouring functions with
no `CHECK` of their own.

| Module | First site | Span | Sites | Recovered replacement boundary |
|---|---:|---:|---:|---|
| `aBlobs.cpp` | `0x0041DE5B` | 53.7 KB | 263 | pool, constructor, update switch and triggers — [28 §7–§8](28-effects-and-sound.md) |
| `aAnimations.cpp` | `0x0040B5AD` | 48.5 KB | 458 | set-pieces, animation-triggered effects and sound — [26](26-interaction.md), [28](28-effects-and-sound.md) |
| `aMissionControl.cpp` | `0x00453F9A` | 37.1 KB | 138 | campaign map, roster screens and location dispatch — [27](27-campaign.md) |
| `aTacTools.cpp` | `0x0046A463` | 25.8 KB | 183 | combat and interaction — [22](22-combat-and-visibility.md), [26](26-interaction.md) |
| `aMenuSystem.cpp` | `0x0044B238` | 22.1 KB | 100 | campaign/roster rules recovered; original front-end flow deliberately outside the replacement contract |
| `a3DObjects.cpp` | `0x004046C1` | 20.7 KB | 226 | scenery and prototype contract — [30](30-eng3d-ascii-formats.md), [31](31-prototyp-geometry.md) |
| `aSeqPlayer.cpp` | `0x0046543A` | 20.0 KB | 18 | compiled manifest, lifecycle, timing and triggers — [41](41-sequence-player.md) |
| `aLCL_Com.cpp` | `0x004407D5` | 18.9 KB | 52 | LCL runtime commands — [20 §7](20-lcl-language.md) |
| `aUnitMap.cpp` | `0x0047776B` | 17.4 KB | 112 | visibility, interaction and campaign roster — [22](22-combat-and-visibility.md), [26](26-interaction.md), [27](27-campaign.md) |
| `aBattleSystem.cpp` | `0x00419DB9` | 16.2 KB | 44 | turn hand-over refresh — [25 §5](25-turn-and-round.md) |
| `aUnitInfos.cpp` | `0x00473A41` | 15.3 KB | 24 | balance records and selected-unit fields — [21](21-info-lcl-schema.md), [29](29-interface-contract.md) |
| `aCtrlMap.cpp` | `0x0042EBAB` | 14.4 KB | 31 | mission cells, AI and interaction — [10](10-lev-mission-format.md), [23](23-ai-system.md), [26](26-interaction.md) |
| `a3DEngine.cpp` | `0x0040104B` | 13.6 KB | 106 | prototype/scene boundary — [31](31-prototyp-geometry.md), [41](41-sequence-player.md) |
| `aViewPlayer.cpp` | `0x0047BD0B` | 13.3 KB | 54 | turn and player-view state — [25](25-turn-and-round.md) |
| `aMI.cpp` | `0x00450AC8` | 12.8 KB | 33 | replacement map-event boundary — [29](29-interface-contract.md) |
| `aUI.cpp` | `0x00471101` | 10.3 KB | 45 | selected-unit fields and command pad — [29](29-interface-contract.md) |
| `aGUI.cpp` | `0x0043BF5B` | 10.2 KB | 76 | text box and layout source — [24](24-briefing-text.md), [29](29-interface-contract.md) |
| `aBattleMap.cpp` | `0x004177BA` | 9.5 KB | 52 | mission loading — [10](10-lev-mission-format.md) |
| `aAISystem.cpp` | `0x00409984` | 6.7 KB | 21 | AI turn — [23](23-ai-system.md) |
| `aMissionEnd.cpp` | `0x0045D40A` | 6.4 KB | 27 | mission result and campaign transfer — [27 §6](27-campaign.md) |
| `aLoad.cpp` | `0x00447BF2` | 6.3 KB | 44 | save/load — [11](11-save-game-format.md) |
| `aDSound.cpp`, `aCDRom.cpp`, `aAmbience.cpp` | — | — | 20 | sound contract; `aAmbience.cpp` is a stub — [28 §1, §6](28-effects-and-sound.md) |
| `aPassWord.cpp` | `0x0046246C` | 3.9 KB | 9 | play-by-mail password screen; deliberately out of scope — [27 §7](27-campaign.md), [92 §7.9](92-remake-architecture.md) |
| `aPI.cpp` | `0x00463411` | 1.6 KB | 8 | Place Interface and deploy transfer — [29](29-interface-contract.md) |
| `aMultiPlayer.cpp`, `lNetwork.cpp`, `aDPlay.cpp`, `aMsgTools.cpp` | — | — | 34 | multiplayer/PBM deliberately out of scope — [92 §7.9](92-remake-architecture.md) |

Three modules that carry no format have been identified by what calls them, and
are recorded here so the next reader does not have to:

* **`aPI.cpp` is the Place Interface** — the deploy screen. It is the only
  caller of `aTransferUnitFromPoolToMap` (`0x00478D10`) and one of two callers
  of `aTransferUnitFromMapToPool`, so it is where a roster slot becomes a unit
  on the battle map ([`27` §3.4](27-campaign.md)). At 1.6 KB and eight `CHECK`
  sites it is the smallest of the interface modules; its replacement contract
  is in [`29`](29-interface-contract.md).
* **`aPassWord.cpp` is the play-by-mail password screen**, not mission
  passwords: its comparison reads `GameControl + 0x16B + player*25`, the four
  25-byte slots [`11` §5.3](11-save-game-format.md) documents, sentinel
  `INVALID_PASSWORD` included ([`27` §7](27-campaign.md)).
* **`aDataBase.cpp`** is 0.7 KB with one `CHECK` site, and that site names
  `aCreateMainDDObject` — DirectDraw setup. It has nothing to do with game
  data.

**`aLibTools.cpp` is LibMaker — an authoring tool, not a loader.** The module's
own `CHECK` sites push `LibMaker`, `aLoadBitmap`, `aLoadBitmapInfos`,
`aCreateWinFont`, `aPrintWinText`, `aCreateBitmap`, `FrameRect`, `GetWindowDC`
and `WriteFile`: it is the tool that *built* the `.LIB` sprite libraries out of
bitmaps, and it shipped inside the retail executable the same way the map editor
did ([`10` §4.6](10-lev-mission-format.md)). Its element accessor, which returns
a sprite's pixel pointer, has two callers and both are inside a dialog
procedure. The game's own sprite drawing is elsewhere —
[`60` §2](60-lib-sprites.md) bounds the search.

**A caution that follows from the same evidence.** A module whose *name* matches
a format may own the **writer** rather than the reader, and its accessors will
then have only editor-side callers. Check the callee names a module pushes
before assuming it is on the game's path.

**And a caution about the spans themselves.** A module's extent here runs from
its first `CHECK` site to the next module's first, so it is an *upper bound*
that also swallows any neighbouring function with no `CHECK` site at all
(§2.1). Modules with few sites over a large
span — `aSeqPlayer.cpp` (18 sites, 20 KB) is the worst — will therefore claim
code that is not theirs. The action-point legend at `0x0046838D`
([`10` §4.6](10-lev-mission-format.md)) falls inside `aSeqPlayer.cpp`'s span and
is certainly not part of the sequence player. Treat an attribution as evidence
only when the address is close to a real site of that module, or when the module
is dense.

---

## 3. The Charisma engine

`CHData` = **Charisma** data. The engine's C++ RTTI survives in
`Incubation.exe` and `iDesigner.exe`, so its class model is known exactly:

- Interfaces: `ICharisma`, `IStorable`, `IStorableClass`, `IComponent`,
  `IComponentClass`, `IComponentDesc`, `IModel`, `IPart`, `IMovement`,
  `IAnimation`, `IAnimatable`, `ICamera`, `IWorld`, `IObject`, `IKeyBase`,
  `IExtraData`, `IEventCallback`, `IByteInputStream`
- Serializable descriptors (`StorableClass<T>`): `V100ModelDesc`,
  `V100PartDesc`, `SkeletonDesc`, `SkeletonNode`, `KeyFramedAnimationDesc`,
  `{Linear,Bezier}{Vector,Rotation,Float}MovementDesc`, and the matching
  `{Linear,Bezier}{Vector,Rotation,Float}Key` classes
- Runtime components (`ComponentClass<T>`): `V100Model`, `V100Part`,
  `V100Camera`, `StdAnimation`, `KeyFramedAnimation`,
  `{Linear,Bezier,External}{Vector,Rotation,Float}Movement`
- Support: `Note` + `NoteComparator` (animation event markers),
  `BBDList<T>` (doubly-linked list), `String@BB`

Part names in the models are 3ds Max Biped bone names (`Bip000`, …), so the
character models were authored in 3ds Max and exported with a custom plug-in.

See [`40-charisma-model-animation.md`](40-charisma-model-animation.md).

---

### 3.1 Which binaries are actually worth analysing

PE timestamps separate the original build from everything bundled later:

| Binary | Compiled | Relevance |
|---|---|---|
| `Incubation.exe` | 1998-05-11 | the game — authoritative for every runtime question |
| `iDesigner.exe` | 1998-05-04 | the level editor — authoritative for authoring-side questions |
| `Eng3d.dll` / `ENG3DFX.DLL` | 1998 build | the renderer, in two independently compiled variants |
| `Editor.exe` | **1992-06-19** | unrelated leftover |
| `Settings.exe` | **2013-04-16** | GOG wrapper |

Only the first three rows can answer anything about the file formats. This is
worth knowing before spending time: two of the five executables in the release
directory are dead ends, and one of them (`Editor.exe`) has a name that invites
exactly the wrong assumption.

## 4. Research method

The runtime specifications use the same fail-closed procedure:

1. **Name functions, then verify module ownership.** Run `trace_names.py` for
   the surviving function-name strings and use the `__FILE__` map above to
   resolve ownership. When a name and `__FILE__` disagree, `__FILE__` wins.
2. **Enumerate rather than search.** A claim that nothing else touches a value
   requires a sweep of every relevant `.text` reference plus a positive
   control. Selector values come from enumerated call sites, not guessed enum
   names.
3. **Anchor claims to data.** Check every claim that permits it against 100% of
   the shipped corpus and state the result as `N/N`. Where no data corpus
   exists, treat the identified binary, constants, tables, and call sites as
   the corpus.
4. **Ship a checker.** Each package has a checker that fails on a missing or
   empty corpus. Checks are mutation-tested against the byte, token, or file
   that carries them; relational checks that no single constant mutation can
   simulate are identified explicitly in their specs.
5. **Preserve evidence boundaries.** Each spec ends with **Open questions**,
   marks inferred claims `UNVERIFIED`, retains negative results, and separates
   `verified-static` conclusions from native-runtime behaviour that was not
   observed.

The completed package-to-spec/checker matrix is maintained in
[`00` §2](00-overview.md). This method is permanent project guidance, not a
claim that every original routine must be transcribed before a replacement can
be implemented.

One regression in the sequence-player research is the standing example for
check design. An early checker pinned camera strings in `.rdata` and selected
files on disk, so it stayed green when two dispatch arms were assigned each
other's cameras. The corrected checks bind each arm's `push` instructions,
closing `mov edi, <camera>`, loop bound, and jump to the shared tail. Existence
checks prove that ingredients are present; they do not prove the mapping
between them. See [`41` §2 and §6](41-sequence-player.md).

## 5. Analysis notes

`iDesigner.exe` is the highest-value target for further work: it is the only
binary that both reads *and writes* `.lev`, and its save path is small and easy
to follow. The `.lev` layout in [`10-lev-mission-format.md`](10-lev-mission-format.md)
came from `fcn.00410260` (`aSaveBattleMap`) and the three helpers it calls.

Reproducing that analysis:

```bash
r2 -e bin.relocs.apply=true gog_incubation/iDesigner.exe
> aaa
> izz~aSaveCtrlMap        # locate the trace string
> axt <addr>              # find the function that references it
> pdf @ fcn.00410260      # aSaveBattleMap
```

The binaries are MSVC-built with assert strings intact, so nearly every function
pushes its own name and source line on the error path. That makes
`izz~<name>` + `axt` a reliable way to find any named routine.

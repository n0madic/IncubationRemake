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

### 2.1 Which binaries are actually worth analysing

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

## 4. Analysis notes

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

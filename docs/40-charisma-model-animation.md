# Charisma model and animation formats: `.cho` and `.cha`

Scope: the two file types owned by **Charisma**, the scene-graph/animation engine
layered on top of Eng3d (hence `CHData` = Charisma Data, `.cho` = Charisma Object,
`.cha` = Charisma Animation).

| Format | Encoding | Purpose                                                            |
|--------|----------|--------------------------------------------------------------------|
| `.cho` | binary   | Model: part list, mesh references, bind-pose skeleton               |
| `.cha` | binary   | Animation: timed event notes, per-part keyframe tracks, skeleton    |

Both are serialised C++ object graphs produced by `iDesigner.exe` (the in-house
model designer) and consumed by `Incubation.exe`. The models are 3ds Max Biped
exports: bone names such as `Bip01 Becken`, `Bip01 Wirbelsäule`, `Bip01 L Fuß`
are the German-localised Max Biped skeleton.

**`.cho` files contain no geometry.** A part references its mesh *by name*; the
vertex/face data lives in the Eng3d containers (`prototyp.bin`, addressed by
`prototyp.dir` / `.din`) documented in `30-eng3d-ascii-formats.md`. See §8.

**This document is derived from the engine's own `Load` methods.** Charisma's
C++ RTTI survives in `Incubation.exe`, so every class name below is exact and
every field is followed by the address of the function that reads it. Anything
that is still an inference is flagged **UNVERIFIED**; §11 lists what remains.

Tools (all in `tools/`, Python 3, sharing `tools/inclib/binio.py` and
`tools/inclib/charisma.py`):

* `charisma_dump.py` — generic class-token/chunk walker (exploration + debugging)
* `cho_parse.py` — `.cho` parser, `--json`, `--check ROOT`
* `cha_parse.py` — `.cha` parser, `--json`, `--check ROOT`, `--notes ROOT`,
  `--cross-check ROOT`, `--verify-convention ROOT`
* `cho_export.py` — pose a skeleton and export OBJ line segments + PNG sheets
* `charisma_selftest.py` — synthesises streams that take the four reader
  branches the shipped corpus never uses (§10.2)

---

## 1. Corpus and coverage

Data root: `gog_incubation/`. Files are found by extension anywhere below it
(note the stray `CHData/Animations/PS_M0_024.cho`, which is a model living in the
animation directory).

| Type   | `CHData/` | `Video/*/` | Total |
|--------|-----------|------------|-------|
| `.cho` | 115       | 122        | **237** |
| `.cha` | 113       | 132        | **245** |

Both parsers consume every file **to the exact byte**; a single trailing or
missing byte is a hard error (`expect_eof`). This is the proof that the grammar
below is total, not merely plausible.

```
$ python3 tools/cho_parse.py --check gog_incubation
parsed 237/237 files

$ python3 tools/cha_parse.py --check gog_incubation
parsed 245/245 files
```

Aggregate record counts: 17 397 parts and 17 397 skeleton nodes across the
models; 7 246 movement tracks and **903 689 keyframes** across the animations.

---

## 2. Serialisation scheme

### 2.1 Primitives

All integers are little-endian. These are the engine's four stream readers:

| Notation    | Reader address | Meaning                                        |
|-------------|----------------|------------------------------------------------|
| `u16`       | `0x004af7c8`   | 2 bytes                                        |
| `u32`       | `0x004af7ec`   | 4 bytes                                        |
| `f32`       | `0x004af810`   | IEEE-754 single                                |
| `lpstring`  | `0x004af837`   | `u32 length` + exactly *length* bytes, **no NUL**, cp1252 |

`lpstring` builds the `String@BB` class from `d:\Projects\NewTools\bbstring.cpp`;
the NUL is appended in memory, never written to the file. Text is cp1252:
`Bip01 Wirbelsäule`, `Bip01 L Fuß`.

### 2.2 Two registries, only one of which reaches the file

`StdCharisma::RegisterComponentClass` (`0x00498b3b`) fills two name→factory
tables, and the RTTI of `Incubation.exe` spells both out as template
instantiations, so the lists are exhaustive:

**`StorableClass<T>` — 17 classes.** These, and only these, can appear as a
class-name record in the stream. `StorableManager::LoadStorableObject`
(`0x004af552`, called from `0x004af4ed` which reads the name first) looks the
name up here, constructs the object and calls its `Load`:

```
BezierFloatKey    BezierFloatMovementDesc      KeyFramedAnimationDesc
BezierRotationKey BezierRotationMovementDesc   SkeletonDesc
BezierVectorKey   BezierVectorMovementDesc     SkeletonNode
LinearFloatKey    LinearFloatMovementDesc      V100ModelDesc
LinearRotationKey LinearRotationMovementDesc   V100PartDesc
LinearVectorKey   LinearVectorMovementDesc
```

**`ComponentClass<T>` — 14 classes.** These are **never serialised**. A
descriptor stores the *name* of the runtime component it should build as a plain
`lpstring` field of `StdComponentDesc` (§2.4), and the engine instantiates it
through this second registry:

```
V100Model  V100Part  V100Camera  StdAnimation  KeyFramedAnimation
LinearVectorMovement  LinearRotationMovement  LinearFloatMovement
BezierVectorMovement  BezierRotationMovement  BezierFloatMovement
ExternalVectorMovement ExternalRotationMovement ExternalFloatMovement
```

There is **no numeric back-reference** for a class name that has already
appeared: `V100PartDesc` is spelled out 17 397 times across the corpus, once per
part. The only economy in the format is that a homogeneous array hoists the
element class name out of the loop (§2.5).

If a name is not in the storable registry the loader reports
`StorableManager::LoadStorableObject : Storable class <name> has not been
registered.` — this is the error string visible in both binaries.

### 2.3 A record is an inheritance chain

Every `*Desc` class writes **its own fields first and then delegates to its base
class**. So one record on disk is the concatenation of one `u16 version` + body
per level of the C++ hierarchy. The four chains that occur:

```
V100ModelDesc          -> StdModelDesc     -> StdComponentDesc
V100PartDesc                                -> StdComponentDesc
KeyFramedAnimationDesc -> StdAnimationDesc -> StdComponentDesc
<Interp><Chan>MovementDesc -> KeyFramedMovementDesc -> StdMovementDesc -> StdComponentDesc
```

`Load` / `Save` sit at vtable slots 2 and 3 of every storable class:

| Class | `Load` | `Save` |
|-------|--------|--------|
| `SkeletonNode`               | `0x0048432c` | `0x0048448e` |
| `SkeletonDesc`               | `0x0048471d` | `0x004849c0` |
| `StdComponentDesc`           | `0x0049a9c4` | `0x0049ac2e` |
| `StdMovementDesc`            | `0x0049b4e7` | `0x0049b7f9` |
| `StdAnimationDesc`           | `0x0049cba6` | `0x0049ce47` |
| `StdModelDesc`               | `0x004a021f` | `0x004a0482` |
| `KeyFramedAnimationDesc`     | `0x004a1dde` | `0x004a2481` |
| `KeyFramedMovementDesc`      | `0x004a26d5` | `0x004a2f17` |
| `V100PartDesc`               | `0x004a70fd` | `0x004a71e0` |
| `V100ModelDesc`              | `0x004a77bd` | `0x004a783a` |
| `LinearFloatMovementDesc`    | `0x004a82f2` | `0x004a8622` |
| `LinearFloatKey`             | `0x004a879c` | `0x004a8822` |
| `LinearVectorMovementDesc`   | `0x004a91ae` | `0x004a94f0` |
| `LinearVectorKey`            | `0x004a9683` | `0x004a972d` |
| `LinearRotationMovementDesc` | `0x004aa0b7` | `0x004aa3fd` |
| `LinearRotationKey`          | `0x004aa59a` | `0x004aa656` |
| `BezierFloatMovementDesc`    | `0x004ab01e` | `0x004ab368` |
| `BezierFloatKey`             | `0x004ab4f6` | `0x004ab5a0` |
| `BezierVectorMovementDesc`   | `0x004ac022` | `0x004ac3a4` |
| `BezierVectorKey`            | `0x004ac57d` | `0x004ac693` |
| `BezierRotationMovementDesc` | `0x004ad0f9` | `0x004ad499` |
| `BezierRotationKey`          | `0x004ad83e` | `0x004ad8fa` |

### 2.4 `StdComponentDesc` — the tail of every descriptor

`StdComponentDesc::Load` @ `0x0049a9c4`:

```
u16      version          # rejected unless 0
lpstring componentClass   # a name in the ComponentClass registry
lpstring instanceName     # node / track / model name
u16      kind             # component category
u32      childCount
childCount × LoadStorableObject()   # nested IComponentDesc children
```

This is the block that earlier drafts of this document mis-read as a separate
"component record". It is not: `componentClass` is a *string field*, not a
class-name record, and `kind` is a `u16` followed by a `u32` count — not a `u32`
followed by `u16` padding. The byte spans are identical, the meaning is not.

#### `kind` is a class tag, not authored data

`kind` is not something the artist chose: **each abstract base class's
constructor stores a literal into the field, and `Load` merely overwrites it
with the same value read back from the file.** The five assignment sites are the
proof — every one of them is `mov dword [eax + 0x1c], <imm>`, where `+0x1c` is
the same slot `StdComponentDesc::Load` writes at `0x0049aa77` (`this - 0x18`,
and `this = object + 0x34`):

| Constructor        | Address (`Incubation.exe`) | Address (`iDesigner.exe`) | `kind` | Occurrences |
|--------------------|----------------------------|---------------------------|--------|-------------|
| `StdComponentDesc` | `0x0049a6ab`               | `0x004576ec`              | 7      | 0 (always overwritten) |
| `StdModelDesc`     | `0x004a00bc`               | `0x00463b29`              | 0      | 237         |
| `V100PartDesc`     | `0x004a708a`               | `0x0045e6ca`              | 1      | 17 397      |
| `StdAnimationDesc` | `0x0049ca43`               | `0x00454073`              | 2      | 245         |
| `StdMovementDesc`  | `0x0049b462`               | `0x00452a92`              | 3      | 7 246       |

So the enumeration has **five** members, not four: value 7 is
`StdComponentDesc`'s own "unspecified" default, which never reaches a file
because every concrete descriptor's base overrides it. A remake can ignore the
field on load and re-derive it from the class on save.

The field is otherwise **dead**. Across the whole of `Incubation.exe` there are
exactly two instructions that touch `this - 0x18`: the store in
`StdComponentDesc::Load` (`0x0049aa77`) and a load in `StdComponentDesc::Save`
(`0x0049ac86`) that writes it straight back out. No comparison, no switch, no
runtime consumer. The labels *model / part / animation / movement* below are
ours; the binaries carry no strings for them.

#### `childCount` — nested descriptors

`childCount` is 0 in all 25 125 shipped records, but the element type is *not*
unknown, so the parser no longer refuses it. The loop at `0x0049aab6` reads each
child through the ordinary name-first `LoadStorableObject` (`0x004af4ed`) and
then hands the result to `__RTDynamicCast` at `0x0049aabf` with the target type
descriptor at `0x004f6a10`, whose RTTI name is `.?AVIComponentDesc@@` (the
source descriptor at `0x004f6a30` is `.?AVIStorable@@`). A failed cast aborts the
load.

The element is therefore **any storable class that derives from
`IComponentDesc`** — the nine `*Desc` classes, and only those:

```
V100ModelDesc  V100PartDesc  KeyFramedAnimationDesc
LinearFloatMovementDesc   LinearVectorMovementDesc   LinearRotationMovementDesc
BezierFloatMovementDesc   BezierVectorMovementDesc   BezierRotationMovementDesc
```

`SkeletonDesc`, `SkeletonNode` and the six `*Key` classes are storable but are
not `IComponentDesc`s, so they are rejected. `tools/inclib/charisma.py`
implements exactly this rule (`COMPONENT_DESC_CLASSES`); `charisma_selftest.py`
exercises it on a synthesised stream, since nothing in the corpus does (§10.2).

### 2.5 Homogeneous storable arrays

Used for `SkeletonNode` lists and for keyframe lists:

```
u32  count
if count != 0:
    u32  elemNameLen
    byte elemName[elemNameLen]     # written ONCE for the whole array
count × {
    u16  elementVersion            # 0 in every element of every file
    ...  element body
}
```

Byte-level proof (`P0_F0_000.cha`, first movement): the array header at `0x62`
reads `56 00 00 00` = 86, the name `LinearVectorKey` runs `0x6a..0x78`, the
element version sits at `0x79`, and key 0's `f32` time starts at `0x7b` with its
`vec3` at `0x7f`. Key 1's `vec3` is at `0x91` — a stride of exactly 18 bytes
(`2 + 4 + 12`).

The alternative shape — a full `LoadStorableObject` per element, so the class
name is repeated — is what `SkeletonDesc::Load` version 0 and
`KeyFramedMovementDesc::Load` version 0 do. Neither occurs in the shipped data;
both are implemented anyway because the code shows them exactly.

### 2.6 Stream header

Every `.cho` and `.cha` begins with `u32 streamVersion`, value `1` in all 482
files.

---

## 3. `.cho` — model

```
u32  streamVersion                  # 1

LoadStorableObject:
    lpstring "V100ModelDesc"

V100ModelDesc::Load @ 0x004a77bd:
    u16  version                    # rejected unless 0

  StdModelDesc::Load @ 0x004a021f:
    u16  version                    # rejected unless 0
    u32  partCount
    partCount × LoadStorableObject()      # each one a V100PartDesc, §3.1
    u16  hasSkeleton                # 1 in all 237 files
    if hasSkeleton: LoadStorableObject()  # SkeletonDesc, §5

  StdComponentDesc::Load @ 0x0049a9c4:    # §2.4
    u16 0 ; "V100Model" ; <model name> ; u16 kind=0 ; u32 childCount=0
EOF
```

### 3.1 `V100PartDesc`

`V100PartDesc::Load` @ `0x004a70fd`:

```
u16      version           # rejected unless 0
lpstring meshName          # geometry name, "" for a pure bone

StdComponentDesc::Load:
    u16 0 ; "V100Part" ; <part name> ; u16 kind=1 ; u32 childCount=0
```

The part name is the animation binding key: it matches a `SkeletonNode` name in
the same file and a `*Movement` target in the `.cha` files (§7).

`meshName` is the geometry reference, upper-case by convention and usually
`<model>_<part>` — e.g. part `Unterkoerper` of `P0_000` carries mesh
`P0_000_UNTERKOERPER`. 8 617 distinct mesh names occur in the corpus;
8 656 of the 17 397 parts have a non-empty mesh, the rest are pure bones.
`V100Part::ConstructPart` (`0x004a5e23`) resolves it through the Eng3d prototype
table and reports `V100Part::ConstructPart : Prototyp <name> for part <part> not
found!` when it cannot.

### 3.2 Verified invariants (237/237 files)

| Check                                                     | Result |
|-----------------------------------------------------------|--------|
| `partCount` equals the number of `SkeletonNode`s           | 237/237 |
| the set of part names equals the set of skeleton node names| 237/237 |
| exactly one node whose parent is not another node          | 237/237 |
| that node's parent string is literally `ROOT`              | 237/237 |
| skeleton matrix bottom row is `(0, 0, 0, 1)`               | 17 397/17 397 |
| every matrix element within ±1e6                           | 17 397/17 397 |

Part counts range from 1 to 275 (median 43); meshed parts from 1 to 130.

### 3.3 Annotated head of `CHData/Objects/P0_000.cho`

```
0x0000  01 00 00 00                 streamVersion = 1
0x0004  0d 00 00 00 "V100ModelDesc"
0x0015  00 00                       V100ModelDesc.version = 0
0x0017  00 00                       StdModelDesc.version  = 0
0x0019  26 00 00 00                 partCount = 38
0x001d  0c 00 00 00 "V100PartDesc"
0x002d  00 00                       V100PartDesc.version = 0
0x002f  00 00 00 00                 meshName = ""            (pure bone)
0x0033  00 00                       StdComponentDesc.version = 0
0x0035  08 00 00 00 "V100Part"      componentClass
0x0041  06 00 00 00 "Bip000"        instanceName
0x004b  01 00                       kind = 1
0x004d  00 00 00 00                 childCount = 0
0x0051  0c 00 00 00 "V100PartDesc"  ... 37 more parts ...
...
0x097e  01 00                       hasSkeleton = 1
0x0980  0c 00 00 00 "SkeletonDesc"
0x0990  01 00                       SkeletonDesc.version = 1
0x0992  26 00 00 00                 nodeCount = 38
0x0996  0c 00 00 00 "SkeletonNode"  hoisted element class name
0x09a6  00 00                       node[0].version = 0
0x09a8  06 00 00 00 "Bip000"        node[0].name
0x09b2  04 00 00 00 "ROOT"          node[0].parent
0x09ba  <64 bytes>                  node[0].matrix (16 × f32, row-major)
...
0x17e0  00 00                       StdComponentDesc.version = 0
0x17e2  09 00 00 00 "V100Model"     componentClass
0x17ef  06 00 00 00 "P0_000"        instanceName (the model name)
0x17f9  00 00                       kind = 0
0x17fb  00 00 00 00                 childCount = 0
0x17ff  EOF
```

---

## 4. `.cha` — animation

```
u32  streamVersion                  # 1

LoadStorableObject:
    lpstring "KeyFramedAnimationDesc"

KeyFramedAnimationDesc::Load @ 0x004a1dde:
    u16  version                    # 1 in 242 files, 0 in 3 files
    if version == 1:
        u32  noteCount
        noteCount × Note            # §4.1

  StdAnimationDesc::Load @ 0x0049cba6:
    u16  version                    # rejected unless 0
    u32  movementCount
    movementCount × LoadStorableObject()   # each a *MovementDesc, §4.2
    u16  hasSkeleton                # 1 in all 245 files
    if hasSkeleton: LoadStorableObject()   # SkeletonDesc, §5

  StdComponentDesc::Load:
    u16 0 ; "KeyFramedAnimation" ; <animation name> ; u16 kind=2 ; u32 childCount=0
EOF
```

The note list is the only version-gated field at the animation level: the three
`version == 0` files (`P0_J0_005.cha`, `PC_S0_005.cha`, `PC_S0_010.cha`) omit
both `noteCount` and the notes. `PC_S0_010.cha` also has `movementCount == 0`.

### 4.1 `Note` — timed event marker

```
f32      time
lpstring text
```

`Note` is *not* a storable class (it has no `StorableClass<Note>` in the RTTI,
only `Note` and `NoteComparator`, held in a `BBDList<Note>`), so it carries
neither a class name nor a version — the loaders at `0x004a1dde` and
`0x004a26d5` read the two fields inline. §9 lists the event vocabulary.

### 4.2 Movement tracks

A movement is one animated channel of one part. Its record is the four-level
chain from §2.3:

```
LoadStorableObject:
    lpstring "<Interp><Channel>MovementDesc"

<Interp><Channel>MovementDesc::Load           # e.g. 0x004aa0b7
    u16  version                              # 0 or 1
    if version == 1:
        u32 keyCount
        if keyCount: lpstring keyClass        # must be this class's own key type
        keyCount × { u16 keyVersion ; f32 time ; f32 value[N] }

  KeyFramedMovementDesc::Load @ 0x004a26d5
    u16  version                              # 0, 1, 2 or 3
    version 0: u32 keyCount ; keyCount × LoadStorableObject()  # name per key
               u32 noteCount ; noteCount × Note
    version 1: u32 keyCount ; if keyCount: lpstring keyClass ; keyCount × key
               u32 noteCount ; noteCount × Note
    version 2: u32 keyCount ; if keyCount: lpstring keyClass ; keyCount × key
    version 3: (nothing — the derived class already read the keys)

  StdMovementDesc::Load @ 0x0049b4e7
    u16      version                          # rejected unless 0
    u32      weight                           # 100 in all 7246 movements, dead (§4.10)
    lpstring targetName                       # the animated part / bone
    lpstring channelName                      # "Position" | "Rotation matrix" | "Visibility"
    u32      attributeCount                   # 0 in all 7246 movements
    attributeCount × { lpstring key ; lpstring value }

  StdComponentDesc::Load
    u16 0 ; "<Interp><Channel>Movement" ; "<target>.<channel>" ; u16 kind=3 ; u32 childCount=0
```

Because the derived class and its base can *both* carry the key array, the two
version fields are not independent — only three combinations occur:

| derived `version` | `KeyFramedMovementDesc.version` | where the keys live | note list? | Movements |
|-------------------|---------------------------------|---------------------|-----------|-----------|
| 1                 | 3                               | derived class       | no        | 7 130     |
| 0                 | 2                               | `KeyFramedMovementDesc` | no    | 73        |
| 0                 | 1                               | `KeyFramedMovementDesc` | yes (count 0) | 43 |

This closes what earlier drafts called the "version-0 movement descriptors with
a `u16 subVersion` and a mystery trailer": the `subVersion` is simply the base
class's own version field, and the "extra `u32` = 0" of the `subVersion == 1`
form is the base class's per-track `noteCount`. `KeyFramedMovementDesc` version
0 (per-key class names) and the `attributeCount` string pairs never occur in
shipped data but are implemented, because the reader is unambiguous.

### 4.3 Key classes

Every key body is `u16 version` (rejected unless 0) followed by `f32 time` and
*N* further floats. The strides are read straight out of each `Load`:

| Key class           | `Load`       | Stride | Payload after `time`                        | Corpus |
|---------------------|--------------|--------|---------------------------------------------|--------|
| `LinearFloatKey`    | `0x004a879c` | 10     | `f32` value                                 | 0      |
| `LinearVectorKey`   | `0x004a9683` | 18     | `vec3` position                             | 978    |
| `LinearRotationKey` | `0x004aa59a` | 22     | `quat (x, y, z, w)`                         | 5 633  |
| `BezierFloatKey`    | `0x004ab4f6` | 18     | `f32` value, `f32` in-tan, `f32` out-tan    | 272    |
| `BezierVectorKey`   | `0x004ac57d` | 42     | `vec3` value, `vec3` in-tan, `vec3` out-tan | 175    |
| `BezierRotationKey` | `0x004ad83e` | 22     | `quat (x, y, z, w)`, **no tangents**        | 188    |

`LinearFloatKey` never occurs in the shipped data; its 10-byte stride is no
longer inferred by symmetry — `LinearFloatKey::Load` reads a `u16` and exactly
two floats.

### 4.4 Interpolation

**Every `GetValue` starts with the same two tests.** Before any interpolation
happens the engine compares the segment length against `0.25` and, if the
segment is that short or shorter, returns one of the two keys outright — the
first if `u <= 0.5`, the second otherwise. Both constants are floats in
`.rdata`: `0x004b38e0` = `0.25` and `0x004b38f4` = `0.5`. The comparisons are
`fcomp dword [0x004b38e0]` / `fcomp dword [0x004b38f4]` in all five
implementations (`0x004a8bb1`/`0x004a8c5b`, `0x004a9af4`/`0x004a9b4e`,
`0x004aaa24`/`0x004aaadf`, `0x004ab95d`/`0x004aba93`,
`0x004acad4`/`0x004acb48`), and both are inclusive on the "hold" side.

This is not academic: **46 406 of the corpus' 896 443 key intervals (5.2 %) are
0.25 frames or shorter**, and the smallest positive interval that occurs is
exactly 0.25. A remake that uses a 1e-6 epsilon here interpolates 5 % of the
segments the engine holds. (`tools/cho_export.py` used to; it now uses
`inclib.charisma.HOLD_DT` / `HOLD_PICK`.)

The parameter itself is `u = (now − t[i]) / (t[i+1] − t[i])`, computed *before*
the hold test and with only a zero-*numerator* guard (`0x004ac9c5` for Bezier
rotation, `0x004a99e5` for linear rotation).

Each `*Movement` component then implements `GetValue`, and those functions
define the semantics of the key payloads:

| Movement class           | `GetValue` | Behaviour |
|--------------------------|------------|-----------|
| `LinearVectorMovement`   | `0x004a8b72` | componentwise lerp `v0 + (v1 - v0)·u` |
| `LinearRotationMovement` | `0x004a9a9a` | `slerp(q0, q1, u)` then quat→matrix |
| `BezierFloatMovement`    | `0x004aa9df` | cubic Bezier, see below |
| `BezierVectorMovement`   | `0x004ab918` | cubic Bezier per component |
| `BezierRotationMovement` | `0x004aca7a` | Shoemake `squad`, see below |

**Bezier tangents.** For a segment between key *i* and key *i+1* with
`dt = t[i+1] − t[i]` and normalised parameter `u`, the engine builds

```
P0 = value[i]
P1 = value[i]   + outTangent[i]   · dt/3
P2 = value[i+1] + inTangent[i+1]  · dt/3
P3 = value[i+1]
result = P3·u³ + 3·P2·u²·(1−u) + 3·P1·u·(1−u)² + P0·(1−u)³
```

So the file order after `time` is **value, in-tangent, out-tangent** (the
earlier inference was right), the in-tangent of a key is used when the key ends
a segment and the out-tangent when it starts one, and the tangents are
**slopes in value units per time unit** — the engine multiplies by `dt/3`
itself. This is the 3ds Max Bezier controller convention.

**Bezier rotation** carries no tangents in the file because the engine derives
them at load time. `BezierRotationMovementDesc::Load` allocates 0x38 bytes per
key (13 floats) although only 5 come from the file, and then calls `0x004ad53e`,
which walks the track and hands each key its predecessor and successor
quaternion to `0x004ad7ab`. `GetValue` (`0x004aca7a`) then evaluates
`squad(q[i], s[i], s[i+1], q[i+1], u)` — `0x004aef75` is Shoemake's `squad`
verbatim, `slerp(slerp(p,q,u), slerp(a,b,u), 2·u·(1−u))`, with the `1.0` and
`2.0` at `0x004b3c78` / `0x004b3c80`. The Bezier rotation *key* payload is
therefore exactly a `LinearRotationKey`; the curve shape is a runtime
construction.

#### The control quaternion — transcribed

`0x004ad7ab` writes the **same** value into both of the key's control slots
(`+0x18` and `+0x28`), so `a[i] == b[i] == s[i]`; there is one control
quaternion per key, not two. It comes from `0x004af0d1`:

```
s[i] = q[i] · exp( −0.25 · ( log(q[i]⁻¹ · q[i−1]) + log(q[i]⁻¹ · q[i+1]) ) )
```

— Shoemake's spline-control formula, with the `−0.25` being the float at
`0x004b3c84`. The four primitives are:

| Primitive       | Address      | What the disassembly actually does |
|-----------------|--------------|------------------------------------|
| `a · b`         | `0x004aecb0` | Hamilton product on `(x, y, z, w)` |
| `q⁻¹`           | `0x004aed3f` | `(−x, −y, −z, w) / (x²+y²+z²+w²)`, bare conjugate if the norm is 0 |
| `log q`         | `0x004aefd1` | `s = x²+y²+z²` ; `k = atan2(s, w)/s` (0 if `s == 0`) ; → `(x·k, y·k, z·k, 0)` |
| `exp v`         | `0x004af04b` | `s = x²+y²+z²` ; `k = sin(s)/s` if `s > 1e-05` (`0x004b3c58`) else `1` ; → `(x·k, y·k, z·k, cos s)` |

**`log` and `exp` are not the textbook functions.** There is no `fsqrt`
anywhere in either routine — verified against the raw disassembly, not only
Ghidra: the engine uses the *squared* vector norm `x²+y²+z²` where the standard
formulas use `|v|`. For the small rotations between adjacent keys the two agree
to first order (`atan2(s,w)/s → 1` and `|v| ≈ θ`), which is why the resulting
spline still looks right — but a remake that "corrects" the formula will not
match the engine. The consequence is visible: the derived controls are not unit
quaternions, and the interpolated result ranges over `‖q‖ ∈ [1.000, 1.042]`
across the whole corpus. That is harmless, because `0x004827b0` divides by the
squared norm (§6.1).

The boundary rules in `0x004ad53e` are: the first key uses its *successor* as
its predecessor, and the last key uses its *predecessor* as its successor. A
single-key track sees `(0,0,0,0)` on both sides (the loop's zero-initialised
locals), which `log`/`exp` turn into the identity, so the control equals the key.

`tools/cho_export.py` now evaluates real `squad` instead of degrading to slerp.
This affects 188 of the 7 246 tracks. Validation over all 188:

* at `u = 0` and `u = 1` the result equals the key **exactly** (max error 0.0),
  so key poses are unchanged;
* between keys it differs from slerp by a bounded amount — median 8.3e-3, p99
  6.3e-2, max 0.246 per component;
* densely sampled (600 samples per track) the curve is continuous and smooth,
  max step 0.052 between adjacent samples, and no non-finite value occurs.

**Slerp** is `0x004aedc7` — Shoemake's `SlerpQuat` from *Graphics Gems*,
including the perpendicular-construction branch for nearly opposite
quaternions. Its component indices are `x=0, y=1, z=2, w=3`, an independent
confirmation of the order established in §6.1.

### 4.5 Channels

| `channelName`     | Movement classes                                  | Count |
|-------------------|---------------------------------------------------|-------|
| `Rotation matrix` | `LinearRotation*`, `BezierRotation*`              | 5 821 |
| `Position`        | `LinearVector*`, `BezierVector*`                  | 1 153 |
| `Visibility`      | `BezierFloat*`                                    | 272   |

There is no scale channel anywhere in the corpus, and the engine has no scale
channel either: `V100Part` holds exactly three movement slots, looked up by name
against three fixed strings (`0x004a6598`, globals `DAT_005242e0..f0`).

### 4.6 Verified invariants (245/245 files)

| Check                                                        | Result |
|--------------------------------------------------------------|--------|
| key times are non-decreasing within every track               | 7 246/7 246 |
| every track's first key is at `time == 0`                     | 7 246/7 246 |
| `instanceName == targetName + "." + channelName`              | 7 246/7 246 |
| movement target is a node of the file's own skeleton          | 6 524/6 524 distinct |
| rotation key is unit-length within 1e-4                       | 741 720/745 319 (99.52 %) |
| position magnitudes within ±1e6                               | all |
| `weight` is 100, `attributeCount` and `childCount` are 0      | all |

Rotation quaternion norms: 741 720 keys are unit within 1e-4, 2 430 within 1 %,
and 1 169 (0.16 %) deviate by more than 1 %. The worst case is `Hand_L` in
`P0_J0_005.cha` with a norm of 0.7070 (= 1/√2) held constant over many keys —
i.e. individual tracks were exported un-normalised, not a layout error. The
engine is immune to this: its quaternion→matrix routine divides by the squared
norm (§6.1), so an un-normalised key still produces a proper rotation. A remake
must do the same, or normalise on load.

### 4.7 Time base

All key times start at 0. **94.5 %** of the 903 689 key times are exact
integers, and the animation lengths cluster on round values (60, 90, 20, 100,
120, …) with a range of 0 … 1410. Time is therefore counted in **frames**, as
exported from 3ds Max; note times such as `t = 20` in a 60-frame animation are
frame numbers.

The Charisma layer never converts, and it does not need to: the caller hands it
a delta *already expressed in key-time units*. §4.8 follows that delta all the
way out to the two call sites that produce it and settles the frame rate.

### 4.8 Playback rate — **30 fps for cutscenes; render-rate for gameplay**

This was the last open question, and it is now closed by code. The chain has
three links.

**1. The per-animation speed factor is always 1.0.**
`StdAnimation::Update` (`0x004a0c50`) is the whole time advance:

```
this[+0x58] += this[+0x64] * dt          # currentTime += speed * dt
clamp to the total length, set the finished flag at this[+0x80]
this[+0x5c] = MapTime(this[+0x58])       # 0x004a1b57, fmod / ping-pong / reverse
```

`this[+0x64]` is the speed factor. A scan of the **entire** `.text` of
`Incubation.exe` for writes to that slot — every addressing form, including SIB
— finds exactly one instruction: `0x004a0bad`, `mov dword [eax + 0x64],
0x3f800000`, i.e. the constant `1.0f`, inside `StdAnimation::SetAnimationDesc`
(`0x004a0a01`). Nothing in the game, in a `.cha`, or in an LCL script ever
changes it. Whatever `dt` is, animation time advances by exactly `dt`.

The same initialiser fixes the rest of the playback state, which a remake needs:

| Offset | Meaning | Initial value |
|--------|---------|---------------|
| `+0x58` | current time (unmapped, monotonic) | 0 |
| `+0x5c` | mapped time actually sampled | 0 |
| `+0x60` | length from the descriptor (last key time) | from `IAnimationDesc` |
| `+0x64` | **speed factor** | `1.0` |
| `+0x68` | play range start | 0 |
| `+0x6c` | play range end | `+0x60` |
| `+0x70` | loop count | 1 |
| `+0x74` | reverse flag | 0 |
| `+0x78` | ping-pong flag | 0 |
| `+0x80` | finished flag | 0 |

Total playback length is `(end − start) · loops`, doubled when ping-pong is set
(`0x004a1b01`), with a `1e-6` floor on the range (`0x004a1ac2`).

**2. `dt` reaches every animation through `IWorld::Simulate`.**
`StdWorld::Simulate(float dt, int flush)` is `0x00497ba2`, vtable slot `0x40` of
`IWorld` (`0x004b32a4`). It sub-steps `dt`, accumulates world time at `+0x0c`,
and ticks all components. Slot `0x40` is called from exactly **four** sites in
the whole executable (`0x00407112`, `0x00407384`, `0x00437047`, `0x0047f76b`);
`0x00437047` dispatches on an unrelated global (`0x00504984`, the GUI table), so
**three** reach the Charisma world, and they fall into the two cases below.

**3a. Cutscenes: `dt = elapsed_ms × 0.03` — exactly 30 fps.**
The sequence player (`aSeqPlayer.cpp`, `fcn.004658b0`) reads `GetTickCount()`,
takes the delta in milliseconds, converts it with `fild` and multiplies by the
float at `0x004b157c` = `0.03` (`fmul` at `0x0046596c` and `0x00465a4c`), then
passes the result down to `fcn.0047f6a0`, which forwards it to
`IWorld::Simulate` at `0x0047f76b` (`push 0; push <dt>; call [edx + 0x40]`).

`0.03` frames per millisecond is `30` frames per second. The constant occurs
nowhere else in the executable. **Every `.cha` under `Video/` plays at exactly
30 fps**, wall-clock, frame-rate independent.

**3b. Gameplay: `dt = 1.0` per rendered frame.**
The in-game 3D object view (`a3DObjects.cpp`) calls
`IWorld::Simulate(1.0f, 0)` — `push 0; push 0x3f800000; call [eax + 0x40]` — at
`0x00407104` (inside `fcn.00406fc0`, the 3D-view refresh) and at `0x00407382`
(`fcn.00407370`), each immediately followed by the world's render slot
(`[edx + 0x38]`). One key-time unit per rendered frame: **gameplay animation
speed is the render rate**, and there is no constant to find because there is no
conversion.

The render rate is bounded, not fixed. `aWinTools.cpp` line 841 provides a
"skip controller", `fcn.0047f2e0(minFps, maxFps)`, which busy-waits on
`GetTickCount()` until `1000 / maxFps` ms have passed. Its call sites:

| Caller | Args | Nominal cap | Context |
|--------|------|-------------|---------|
| `0x0040b831` in `fcn.0040b6f0` | `(10, 20)` | 20 fps | `aAnimations.cpp` per-frame routine — the gameplay 3D animation loop |
| `0x0044bdb0` | `(20, 20)` | 20 fps | `fcn.0044bd90` |
| `0x00454596` | `(10, 30)` | 30 fps | menu / intro state machine, state 1 |
| `0x00454d12`, `0x00454edc` | `(10, 25)` | 25 fps | menu / intro state machine, states 2 and 3 |

Two caveats a remake should know rather than copy:

* the "skip" half of the controller is dead — `0x00522eec` is written 0 on both
  paths and its only reader (`fcn.0047f3b0`) therefore always sees 0, so frames
  are never dropped, only delayed;
* the limiter does not reset its epoch (`0x00522ee8`) on the branch that waits,
  only on the branch that does not (`0x0047f390`), so the wait is enforced on
  every *other* call. The effective cap is roughly twice the nominal one. This
  is an engine bug, not a design.

**3c. A walk is six of those frames per map field.** This is the measurement
that turns the gameplay rate from a free choice into a constrained one, and it
is in `aExecuteMove` (`0x0046E220`, `aTacTools.cpp`) rather than in the
animation code. Its two per-step helpers, `0x0040EA30` and `0x0040EBB0`, are
built the same way:

```
delta = (to - from) / 6            ; 0x2AAAAAAB, the signed magic for /6
counter = 6
do  { set the object's position; position -= delta; fcn.0040B6F0() }
while (--counter)
```

`fcn.0040B6F0` is the gameplay frame routine — the one the table above shows
being capped at `(10, 20)`. So **one map field is six rendered frames**, and by
3b it is also six key-time units of whatever clip is playing. A `.cha`
movement clip is 20 frames long and strides one field (§5.4), so the engine
walks a unit **3.3× further per cycle than the clip's own stride** — the feet
do not track the ground, and did not in 1997 either.

**Conclusion for a remake.** Key times are frames (§4.7). Play `Video/*.cha` at
**30 fps** — proven. For gameplay the original ties playback to the render loop
at one frame per rendered frame; the loop that renders a walk is capped at a
nominal **20 fps**, and a field is six of those frames, so 20 fps and 0.3 s per
field are one choice and not two. 30 fps is defensible for consistency with the
cutscenes, but then a field must be 0.2 s: picking 30 fps *and* a field time
from taste is how a remake ends up reproducing the engine's **epoch bug**
instead of its design — the limiter does not reset its epoch on the branch that
waits, so the effective cap is roughly 40 fps and a field roughly 0.15 s. The
20/25/30 spread in the table is a property of the 1997 main loop, not of the
animation data.

One related constant, recorded because it looks like a rate and is not:
`fcn.004055e0` stores `animationLength × (1/6)` (float at `0x004b116c`,
`fmul` at `0x00405b26`) into `DAT_004fa844[slot]`, and the combat routine
`fcn.0040bd70` spins the frame loop for `int(that) / 3` iterations
(`0x0040bec9`). That is a fixed *delay* while the animation plays and stops
itself at its `BREAK` note (§9), not a length conversion. **UNVERIFIED** as to
intent.

### 4.9 Annotated head of `CHData/Animations/P0_F0_000.cha`

```
0x0000  01 00 00 00                 streamVersion = 1
0x0004  16 00 00 00 "KeyFramedAnimationDesc"
0x001e  01 00                       KeyFramedAnimationDesc.version = 1
0x0020  02 00 00 00                 noteCount = 2
0x0024  00 00 a0 41                 note[0].time = 20.0
0x0028  05 00 00 00 "BREAK"         note[0].text
0x0031  00 00 88 41                 note[1].time = 17.0
0x0035  05 00 00 00 "BREAK"
0x003e  00 00                       StdAnimationDesc.version = 0
0x0040  14 00 00 00                 movementCount = 20
0x0044  18 00 00 00 "LinearVectorMovementDesc"
0x0060  01 00                       LinearVectorMovementDesc.version = 1
0x0062  56 00 00 00                 keyCount = 86
0x0066  0f 00 00 00 "LinearVectorKey"
0x0079  00 00                       key[0].version = 0
0x007b  00 00 00 00                 key[0].time  = 0.0
0x007f  <12 bytes>                  key[0].value = (-0.00573, 0.04639, 29.14)
0x008b  00 00                       key[1].version
0x008d  00 00 00 3f                 key[1].time  = 0.5
...
0x0685  03 00                       KeyFramedMovementDesc.version = 3
0x0687  00 00                       StdMovementDesc.version = 0
0x0689  64 00 00 00                 weight = 100
0x068d  06 00 00 00 "Bip000"        targetName
0x0697  08 00 00 00 "Position"      channelName
0x06a3  00 00 00 00                 attributeCount = 0
0x06a7  00 00                       StdComponentDesc.version = 0
0x06a9  14 00 00 00 "LinearVectorMovement"      componentClass
0x06c1  0f 00 00 00 "Bip000.Position"           instanceName
0x06d4  03 00                       kind = 3
0x06d6  00 00 00 00                 childCount = 0
0x06da  ... next movement ...
...
0x7f3b  00 00                       StdComponentDesc.version = 0
0x7f3d  12 00 00 00 "KeyFramedAnimation"
0x7f53  09 00 00 00 "P0_F0_000"
0x7f60  02 00                       kind = 2
0x7f62  00 00 00 00                 childCount = 0
0x7f66  EOF
```

---

### 4.10 `weight` — loaded, saved, never read

`StdMovementDesc::Load` reads a `u32` immediately after its version and stores
it at `this - 0x28` (`0x0049b537`). Its value is 100 in all 7 246 movements.

An exhaustive scan of both executables for instructions addressing that slot
finds **exactly two** in each:

| Binary | Write | Read |
|--------|-------|------|
| `Incubation.exe` | `0x0049b537` (`StdMovementDesc::Load`) | `0x0049b82b` (`StdMovementDesc::Save`) |
| `iDesigner.exe`  | `0x00452b67` (`Load`)                  | `0x00452e5b` (`Save`)                  |

The only read writes the value straight back to the stream. No runtime component
consumes it: the runtime `StdMovement` (`0x0049ae07` and its methods) copies the
descriptor pointer and the target/channel strings and nothing else.

So `weight` is **round-trip metadata**. Its position is proven, and its runtime
effect is proven to be *none*. What it was intended to mean (the class name and
the value 100 both suggest a percentage blend weight for layered animation) is
not recoverable from the shipped artefacts — that would need the Charisma
source or a build in which the blending path was live. A remake should preserve
the value on save and otherwise ignore it.

---

## 5. `SkeletonDesc` / `SkeletonNode` — the bind pose

Identical in both file types; a `.cha` embeds a copy of the skeleton it was
authored against.

`SkeletonDesc::Load` @ `0x0048471d`:

```
u16  version                       # 1 in all 482 files
version 0: u32 count ; count × LoadStorableObject()       # class name per node
version 1: u32 count ; if count: lpstring "SkeletonNode"  # class name hoisted
                       count × <node body>
then: SkeletonDesc::BuildSkeleton @ 0x00484b08
```

`SkeletonNode::Load` @ `0x0048432c`:

```
u16      version       # rejected unless 0
lpstring name          # matches a V100Part instance name
lpstring parent        # another node's name, or "ROOT" for the root
f32      matrix[16]
```

The hierarchy is expressed **by parent name**, not by index or by nesting.
`BuildSkeleton` resolves it into pointers (`+0x58` = parent, `+0x5c` = children)
and reports `SkeletonDesc::BuildSkeleton : More than one root node!` if two
nodes claim `ROOT`. Exactly one node per file does.

### 5.1 Matrix convention — proven, not inferred

`SkeletonNode::Load` fills the matrix with an explicit
`for row in 0..3 { for col in 0..3 { M(row, col) = ReadF32() } }` loop over the
element accessor `0x00482a72`, which computes `flat[row * 4 + col]`. The storage
is therefore **row-major**, in the order `m00 m01 m02 m03 m10 … m33`.

The point transform `0x004826d0` computes

```
out.x = m[0]·x + m[1]·y + m[2]·z + m[3]
out.y = m[4]·x + m[5]·y + m[6]·z + m[7]
out.z = m[8]·x + m[9]·y + m[10]·z + m[11]
```

so the convention is **`M · v` on column vectors** with the translation in the
fourth *column*:

```
| r00 r01 r02 tx |
| r10 r11 r12 ty |
| r20 r21 r22 tz |
|  0   0   0   1 |
```

Row 3 is `(0, 0, 0, 1)` in all 37 071 nodes. Matrix multiply is `0x00482ab3`,
plain row-major `A · B`.

**Rows 0–2 are *not* generally orthonormal**, and a remake must not assume they
are. Measured over all 37 071 nodes (17 397 in the 237 `.cho`, 19 674 in the
245 `.cha`), `max |R·Rᵀ − I|` exceeds `0.1` on **253 nodes across 108 files** —
`P0_001.cho:Hand_R` is `0.193`, `P0_002.cho:Box02` is `0.332` — and **six
matrices are singular**:

```
Video/Seq_3/Model_3_16.cho      b1,  c1     det = 0
Video/Seq_3/Model_3_22.cho      c1a         det = 0
Video/Seq_3/Animation_3_16.cha  b1,  c1     det = 0
Video/Seq_3/Animation_3_22.cha  c1a         det = 0
```

Most of the rest carry deliberate non-uniform scale. So **inverting a bone
matrix by transposing it is wrong on those nodes**, and decomposing one to a
quaternion is wrong on the singular six. Invert properly, or carry the matrix
through unchanged. A previous revision stated the orthonormality as fact; it was
never machine-checked, and neither `cho_parse --check` nor `cha_parse --check`
validates it today.

### 5.2 Matrix space — parent-relative

`SkeletonNode::GetWorldMatrix` (`0x004842a2`) walks from a node up the parent
chain accumulating `result = node.matrix · result`, and the runtime part
hierarchy does the same one level at a time: `StdPart::GetWorldMatrix`
(`0x0049db84`) computes `parentWorld · local`. So the 16 floats of a
`SkeletonNode` are a **parent-relative local transform**, not an object-space
one:

```
world(bone) = M_parent … · M_self          (each M applied as M · v)
```

One caveat about the top of the chain. `0x004842a2`'s loop condition is
`node->parent != NULL`, so it stops *before* multiplying the root node's own
matrix; the root's local transform is excluded there. That matters, because the
root matrix is not identity in most models — only 48 of 237 have an identity
root, the rest carry a z ≈ 100 translation and a real rotation, i.e. the
model's overall placement. `0x004842a2` is dead code in the shipped binary (no
caller); the live path is the `StdPart` one, which starts from the model's own
transform. `tools/cho_export.py` *includes* the root's local matrix, which only
shifts the whole figure and is invisible in a normalised contact sheet.
**Whether the engine applies the root node's matrix or replaces it with the
model's placement transform is UNVERIFIED.**

Example — `Bip01 L Bein` of `P0_000` yields `t = (-1.67e-5, 2.83e-5, 13.217)`, a
pelvis→leg offset of 13.2 units along +Z; `Fuss_L` yields
`t = (8.30, 6.54, 0.77)`, a foot offset from the lower leg. Z is up (Max's
default for Biped).

The visual proof is `tools/out/skeletons/P0_000.png`: reconstructing the bind
pose with this rule produces a recognisable humanoid biped.

---

### 5.3 Bone translations are in 1/16 of a world unit

**Found in slice 4, and stated nowhere above.** A `SkeletonNode`'s translation
and a mesh's vertices are not in the same unit. `P0_000`'s whole skeleton spans
171 units in z while one of its torso meshes is 536 units tall, so a body
assembled from the two as they stand is a 10 cm pile of 30 cm parts.

The factor is measured off the one thing that must be true of a standing
figure — its lowest vertex touches the ground. Solving

    min over meshed parts of ( s * z_bone + z_meshmin ) = 0

gives **16.01** for `P0_000`, and at exactly 16 the lowest vertex of `P0_000`,
`P0_003`, `P1_000` and `P1_003` sits at **−0.07 world units** — 0.04 mm, from
four independent models — with body heights of 1.83 m and 1.91 m against the
1.8 m their type's own height column implies (`docs/21` §5). `PC_000` lands at
+9.3. The neighbouring integers 15 and 17 miss by 6.6 units, so the value is
determined and not merely plausible.

16 is `1 << 4`, the same fixed-point shift [`30` §2.5](30-eng3d-ascii-formats.md)
records for `.3DW` positions.

**Where the engine applies it is UNVERIFIED.** It is not `StdModel`'s scale —
§6.2 shows that defaults to `(1, 1, 1)` and no shipped file changes it — so it
lives in the Charisma-to-Eng3d bridge, which is not decompiled. The number is
verified; its origin is not.

Checked by `python3 tools/charisma_tables.py --check gog_incubation`.

### 5.4 A model is authored facing engine **−Y**

**Found while fixing the remake's bodies, which walked backwards.** Nothing in
a `.cho` or a `.cha` names a forward axis, and no structural check can supply
one: a pose is exactly as self-consistent facing either way. The movement
clips supply it, because a walk cycle *walks*.

`P0_M0_000` carries `P0_000`'s top-level bone **−3238 world units in y and −57
in x** over its 20 frames — 3200 is one map field ([`10` §5.11](10-lev-mission-format.md))
— and over every `(model, movement clip)` pairing the selectors can produce,
**94 of 99 stride** and every one of those heads within **1.9°** of −Y. The
five that do not move at all are creature clips. The shortest real stride is
0.43 of a field and the longest 3.54; 87 land on a whole field, so the
quantisation is the human set's and not a rule of the format.

Two independent readings agree with it: in the bind pose the weapon hand sits
at `y = −1266` and both feet put their toes ahead of their ankles, all in −y.

**The consequence for a renderer** is that `docs/10` §5.10's facing table
cannot be applied to a body as a plain rotation. With a −Y forward there is no
angle convention that sends all eight facings the right way — taken directly it
agrees on the two facings along x and is mirrored in y on the other six. **Half
a turn minus the tabulated angle** agrees on all eight, and is the only such
correction:

| facing | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| angle (§5.10) | 0 | 3072 | 2048 | 1024 | 1536 | 3584 | 512 | 2560 |
| step (`aExecuteMove`) | +y | −x | −y | +x | +x−y | −x+y | +x+y | −x−y |
| body yaw | 2048 | 1024 | 0 | 3072 | 512 | 2560 | 1536 | 3584 |

**Where the engine does this is UNVERIFIED**, for the same reason §5.3's scale
is: it is in the Charisma-to-Eng3d bridge, which is not decompiled. A **mirror
in y** fits the eight facings equally well and is not excluded by anything
measured here; the remake uses the rotation because a mirror also swaps the
body left for right, and the marine carries its weapon in `Hand_R`. One
screenshot of the original showing the weapon in the **left** hand settles it
the other way.

The remake carries this as `WorldSpace.charisma_yaw_basis` and
`CharismaBody.AUTHORED_FORWARD`, checked by `godot/tests/test_charisma.gd`;
the corpus half is `_check_stride` in `tools/charisma_tables.py`.

A second consequence, and the reason the stride was measured at all: a
movement clip is **not** animated in place, so a renderer that moves the unit
itself has to take the clip's own travel back out or the body slides a field
out of its square on every loop.

---

## 6. Runtime: how a track drives a bone

`V100Part::Update` (`0x004a6807`, vtable slot 4 of `V100Part`) is the whole
animation-to-scene-graph binding, and it is short enough to state exactly. A
part holds three movement slots, filled by matching a movement's `channelName`
against three fixed strings (`0x004a6598`). Per frame:

```
if part has no parent:  return                          # 0x004a6866
topLevel = (part.parent has no parent)                  # 0x004a68ae, 0x004a68d1

if no "Position" track is bound:
    translation = bindMatrix.translation                # 0x004828cd
else:
    translation = positionTrack.GetValue(t)
    if not topLevel:
        translation += bindMatrix.translation           # 0x004828ff ADDS
    else:
        # second branch, §6.2
        translation = translation * model.scale         # 0x0049fc6a
        translation += ownerAnimation.offset            # 0x0049c5ac

local = identity
if a "Rotation matrix" track is bound:
    local = rotationTrack.GetValue(t)                   # quat -> matrix, §6.1
else:
    local = bindMatrix with its translation column zeroed   # 0x004828c1
local.translation = translation
SetLocalMatrix(local)

visible = true
if a "Visibility" track is bound:
    visible = visibilityTrack.GetValue(t) > 0
```

Three consequences a remake must get right:

* the **rotation channel replaces** the bind rotation completely (and the bind
  translation is stripped before the track's translation is applied);
* for an ordinary bone the **position channel is an offset added to** the bind
  translation, not an absolute position;
* for the model's **top-level bone** the position channel is *absolute* — the
  bind translation is not added at all (§6.2).

The corpus agrees: over the 1 153 position tracks, the first key's magnitude is
below 1e-3 in **80.3 %** of tracks (median 0.0000), while `firstKey − bindTranslation`
is never near zero (median 40.85). Position tracks are deltas from the bind pose.

(That statistic covers the ordinary-bone branch; §6.2 covers the top-level bone,
where the bind translation is not involved at all. 401 of the 1 153 position
tracks target a direct child of the skeleton root, 104 target the root bone
itself, and 648 target deeper bones.)

`External*Movement` components exist for exactly this slot: game code calls
`0x0042cd80` to install an external `Rotation matrix` movement on a named part
and then writes a 4×4 into it directly — that is how turret aiming overrides an
animation.

### 6.1 Quaternion component order — **`(x, y, z, w)`**

**Settled by code**, two independent functions.

`0x004827b0` builds a matrix from the four floats of a rotation key. Writing the
stored floats as `q0 q1 q2 q3` and `s = 2 / (q0² + q1² + q2² + q3²)` (or 0 if the
norm is 0), it produces, in the same row-major `M · v` layout as a
`SkeletonNode` matrix and with a zero translation column:

```
m[0]  = 1 − s·(q1² + q2²)      m[1]  = s·(q0·q1 + q3·q2)   m[2]  = s·(q0·q2 − q3·q1)
m[4]  = s·(q0·q1 − q3·q2)      m[5]  = 1 − s·(q0² + q2²)   m[6]  = s·(q0·q3 + q1·q2)
m[8]  = s·(q1·q3 + q0·q2)      m[9]  = s·(q1·q2 − q0·q3)   m[10] = 1 − s·(q0² + q1²)
```

`q3` is the only component that appears in none of the three diagonal terms, so
`q3` is the scalar `w` and the order is `(x, y, z, w)`. `(w, x, y, z)` would put
`w` on the diagonal, which no rotation matrix does — it is not merely less
likely, it is impossible.

The second, independent witness is the slerp at `0x004aedc7`: it is Shoemake's
`SlerpQuat` from *Graphics Gems* transcribed verbatim, and that code's
`Quat` struct is `{x, y, z, w}` with the perpendicular fallback
`(−p.y, p.x, −p.w, p.z)` — exactly the index pattern in the binary.

**Trap.** The matrix above is the **transpose** of the textbook `R(q)` under the
engine's own row-major `M · v` reading — equivalently it is `R(q*)`. A remake
that feeds these four floats to a stock quaternion-to-matrix routine will rotate
every bone the wrong way. Use the formula as written; it is implemented as
`inclib.charisma.quat_to_matrix`.

**Independent data check.** `python3 tools/cha_parse.py --verify-convention
gog_incubation` converts the first key of every rotation track under four
hypotheses and compares the 3×3 against that bone's bind-pose rotation in the
animation's own embedded skeleton (Frobenius norm < 1e-3):

```
rotation tracks bound to a bone: 5821 in 245 files
  (x, y, z, w) file order, engine formula      5112  ( 87.82%)
  (x, y, z, w) transposed                       116  (  1.99%)
  (w, x, y, z) w first                           42  (  0.72%)
  (w, x, y, z) transposed                         0  (  0.00%)
files where every rotation track's first key equals the bind pose: 138/245
```

The 116 transposed hits are all also direct hits (symmetric or identity
matrices), so the transposed hypothesis has **zero exclusive** matches, and the
`(w, x, y, z)` hypothesis explains 0.72 % of the data against 87.82 %. The
remaining ~12 % of tracks are animations that simply do not start in the bind
pose; 138 of the 245 files match on *every* rotation track.

### 6.2 The top-level bone takes a different position path

Earlier drafts recorded a "second position branch, taken when a flag on the
owning model is set, exercised by no shipped data". Both halves of that were
wrong. The condition is structural, and it fires for **every model**.

**The condition.** `V100Part::Update` opens with two virtual calls on the part's
own `V100Part` sub-object (vtable `0x004b1f44`, reached through the virtual-base
table entry `+0x10`):

* slot 4 → `0x0049d2ad`: `return part[-0xb4] == 0`, i.e. *has no parent*. If the
  part has no parent, `Update` returns immediately (`0x004a6866`).
* slot 8 → `0x0049d2df`: `return part[-0xb4]`, i.e. *the parent*. The branch
  selector is that parent's own slot 4 (`0x004a68d1`) — **"my parent has no
  parent"**.

`part[-0xb4]` is the parent pointer, set by `StdPart::ConstructPart`
(`0x0049cfb4`). That function also enforces the naming rule that makes the
condition legible: the root part must be named `ROOT` (the global `String` at
`0x00524080`, built from the literal `"ROOT"` at `0x004832a2`) and must have a
null parent, and no other part may carry that name — the two error strings are
`StdPart::ConstructPart : Root part does not have root part name.` and
`StdPart::ConstructPart : Non-root part has same name as root part.`

No `.cho` contains a part called `ROOT`: `V100Model::ConstructModel`
(`0x004a7228`, `V100Model.5` slot 0, vtable `0x004b2244`) allocates a synthetic 0x40-byte part
descriptor and names it `"ROOT"` (`0x004a729b`). The file's own root bone — the
one whose `SkeletonNode.parent` string is literally `ROOT` (§3.2) — becomes that
part's child. So:

> **`topLevel` is true for exactly one bone per model: the one whose `.cho`
> parent string is `ROOT`.** The synthetic `ROOT` part itself is skipped by
> `Update` because it has no parent.

**The operation.** For that bone the bind translation is *not* added. Instead
(`0x004a6a71` onwards) the part queries the `"StandardModel"` interface (the
global `String` at `0x005242b8`, `.?AV` dynamic-cast) on its owning component.
`StdModel` implements it at vtable `0x004b3784`:

| Slot   | Address      | Meaning |
|--------|--------------|---------|
| `+0x0c` | `0x0049fc2d` | `GetFlag()` → `model[+0x70]` |
| `+0x10` | `0x0049fc49` | `SetFlag(v)` |
| `+0x14` | `0x0049fc6a` | `GetScale(out)` → `model[+0x74 .. +0x7c]`, a `vec3` |
| `+0x18` | `0x0049fc9e` | `SetScale(x, y, z)` |

and then:

```
t = positionTrack.GetValue(now)
if model implements "StandardModel":
    if model.GetFlag() != 0:  t.x = 0 ; t.y = 0          # 0x004a6b05, stores 0x004a6b10/17
    t.x *= scale.x ; t.y *= scale.y ; t.z *= scale.z     # 0x004a6b53 onwards
t += ownerAnimation.GetOffset()                          # 0x004a6b91 -> 0x0049c5ac
```

`ownerAnimation` is the object at `StdMovement[+0x38]` (the movement's second
constructor argument, `0x0049aeb5`); its slot `+0x24` is `0x0049c5ac`, which
returns the `vec3` at `animation[+0x44 .. +0x4c]`.

**Defaults.** `StdModel`'s constructor (`0x0049ed2c`) leaves the flag 0 and
writes `(1.0, 1.0, 1.0)` into the scale (`0x0049ed68`…`0x0049ed98`); the
animation's offset vector is zero-initialised. Nothing in a `.cho` or `.cha` can
change either — they are set, if at all, by the game through
`SetScale`/`SetFlag`. So with stock data the whole branch reduces to

```
top-level bone: local translation = positionTrack.GetValue(now)      (absolute)
other bones:    local translation = bindTranslation + track value    (relative)
```

`tools/cho_export.py` implements this (`MODEL_SCALE`, `ANIM_OFFSET`). It changes
the root placement of every animated model — for `P0_000` the root drops from
z ≈ 129 to z ≈ 29 — and the contact sheets stay correct.

### 6.3 Exporter

`tools/cho_export.py` reimplements §5.2 and §6 in Python and writes the result
as Wavefront OBJ line segments (vertices = joints, `l` = bones) plus an
orthographic PNG contact sheet.

```
python3 tools/cho_export.py --samples gog_incubation
```

Samples live in `tools/out/skeletons/`:

| File | What it shows |
|------|----------------|
| `P0_000.png` | bind pose of the human marine — a recognisable biped |
| `P0_000__P0_M0_000.png` | 12 frames of the walk cycle |
| `P0_000__P0_F0_000.png` | 12 frames of the fire animation |
| `PC_000__PC_F0_000.png` | 12 frames of an alien (non-humanoid rig) |

If the quaternion order, the matrix layout, the translation semantics or the
parent chain were wrong, these would come out collapsed, inside out or
scrambled. They do not.

---

## 7. Cross-format binding

The binding chain the remake must reproduce:

```
.cha  Movement.targetName ──┐
                            ├─→ .cho  V100Part.instanceName ─→ V100PartDesc.meshName
.cho  SkeletonNode.name  ───┘                                       │
                                                                    ↓
                                          prototyp.dir/.din → prototyp.bin geometry
```

`python3 tools/cha_parse.py --cross-check gog_incubation`:

```
models: 237   animations: 245
distinct movement targets: 6524
  present in the animation's own skeleton: 6524 (100.00%)
  present in a model of the same family:   6408 (98.22%)
  animations with every target resolved:   221/245
```

"Same family" means the same `P<n>` filename prefix for `CHData/`
(`P0_F0_000.cha` ↔ `P0_*.cho`) or the same directory for `Video/`
(`Video/Dialog_03/Animation_D03_1.cha` ↔ `Video/Dialog_03/Model_D03_*.cho`).

The 116 unresolved names are all authoring helpers that the exporter kept in the
animation but did not emit as model parts: `Banner` (15), `Dummy01..03` (12),
`Shadow`, `Line00`, `Zopf`, and a handful of extra Biped finger/toe bones
(`Bip01 L Finger0`, `Bip01 R Zeh02215`, …). This is an authoring artefact, not a
parse failure — a runtime that ignores tracks with no matching part behaves
correctly.

### 7.1 The name registry in `iDesigner.exe`

`iDesigner.exe` embeds the authoritative asset list next to the format strings
`aCreateCHModelDescriptor`, `%s\%s.cho` (dir `Objects`) and `%s\%s.cha`
(dir `Animations`). Extracting every `P<x>[_<F|J|M|S><n>]_<nnn>` token yields
132 names; **132/132** resolve to a shipped `CHData/Objects/*.cho` or
`CHData/Animations/*.cha`.

Filename grammar: `P<class>[_<family><variant>]_<index>`, where `<class>` is the
unit class (`P0`…`P5`, `PC`, `PR`, `PS`).

**Amended (slice 4).** That grammar is right for the *animations* and too
narrow for the *models*: `0x0042D070` returns `PC_ArmL_011` and `PC_ArmR_011`,
and both are shipped `CHData/Objects/*.cho`. The middle segment is a word, not
a letter plus a digit. A registry scan built on the narrow form finds 102 of
the 104 models the engine registers and looks complete.

### 7.2 What the family letter selects

The names are not built at runtime — there is no `"%s_%c%d_%03d"` anywhere.
`Incubation.exe` contains 92 complete animation names as string literals, and
they are handed out by three sibling lookup functions, each a two-level `switch`
on the unit's **type** byte (`unit[+0x4c]`) and its **weapon** byte
(`unit[+0x3f]`) — the two fields [`21` §7](21-info-lcl-schema.md) names. Earlier
editions of this document called them *state* and *type*: `0x0042da40` bounds
`unit[+0x4c]` at `0x44`, the top unit-type id, and special-cases `0x17`, the
hero's type, which only makes sense for the unit type; and `unit[+0x3f]` is the
weapon id `aToggleWeaponModes` writes ([`25` §7](25-turn-and-round.md)).

| Selector | Families it returns | Names | Reached from |
|----------|---------------------|-------|--------------|
| `0x0042da40` | `M0` | 28 | `fcn.004055e0` case 0 |
| `0x0042ddf0` | `S0` (+ `P4_S1_000`, `PC_F1_011`) | 30 | `fcn.004060b0` |
| `0x0042e220` | `F0` (+ `F1` variants) | 33 | `fcn.004055e0` cases 1, 2, 3 |

(A fourth sibling, `0x0042d070`, returns *model* names — `P0_000` … `PR_016` —
not animations.)

### 7.2.1 Amendments from slice 4 — the selectors, enumerated

`tools/charisma_tables.py` reads these four routines by **interpreting** them:
a bounded interpreter over exactly the instruction forms MSVC emitted for the
cascades, with an unknown opcode a hard error. Enumerating the whole domain
(type `0..0x45`, weapon `0..0x31`, player `{0,1,2,3,4,0xFC,0xFF}`) corrects two
statements above and adds a third.

**1. The model selector is three-level, not "the same shape".** `0x0042D070`
switches on the unit type (`+0x4C`), then the weapon (`+0x3F`), then the
**player** (`+0x45`):

```
0042D070  mov  al, [ecx+0x45]      ; player
          cmp  al, 0xFC
          jne  0x42d088
          xor eax, eax ; ret       ; player 0xFC -> nothing is written
0042D088  mov  al, [ecx+0x4C]      ; unit type
          cmp  al, 0x17            ; the hero
          jne  0x42d09d
          mov  byte [esp+8], 0     ; type  <- 0
          mov  byte [esp+0x10], 1  ; player <- 1
```

Level-1 index bytes at `0x0042D788` and jump table at `0x0042D71C`; level 2 at
`0x0042D840` / `0x0042D7D0`; level 3 is a jump table per weapon arm from
`0x0042D870` upwards. The `P0_`/`P1_`/`P2_`/`P3_` prefixes are the **owner's
skin**, the neutral player `0xFC` gets no body at all, and unit type `0x17` —
the hero — is drawn as type 0 in player 1's colours whatever player owns it.
Player `0xFF`, which the shipped missions do use, is *not* refused.

Read as two levels the routine yields 26 distinct names. Read as three it
yields **104**, which is exactly the number of `aCreateCHModelDescriptor`
calls in `fcn.00407e90` — and exactly the same *set*, name for name. That
agreement between two unrelated readings of the binary is the check the tool
gates on.

**2. The idle selector is not a pure function.** One arm, at `0x0042DF77`:

```
0042DF77  push 0xa ; push 0
          call 0x4638e0            ; aRandom's float entry, frand(0, 10)
          fcomp qword [0x4b1380]   ; = 5.0
          fnstsw ax ; test ah, 0x41
          jne  0x42dfbc            ; draw <= 5.0  -> PC_F1_011
          mov  edi, str.PC_S0_011  ; draw >  5.0  -> PC_S0_011
```

This is the explanation of the unexplained parenthetical above: `S0`
"(+ `P4_S1_000`, `PC_F1_011`)". The idle of one alien is a coin toss, and a
remake needs a **presentation** random draw to reproduce it — not the
simulation's, which a save hash covers.

**3. Animation coverage is not total.** Nine unit types get fewer than three
families, and the gaps are the engine's, not a reading error:

| Type | Unit | Families it gets |
|------|------|------------------|
| 24 | Spider | `M` only |
| 52 | Dec'Ther | `M`, `S` |
| 55 | Cy'Coo | `F` only |
| 60 | War'Coo | `F` only |
| 61 | Norc'Yn | `S` only — and its "idle" is the `F1` name |
| 62, 63 | Norc'Yn left and right arm | **none** |
| 65 | Bea'Ther | `M`, `S` |
| 66 | Bea'Coo | `M`, `S` |

Types 62 and 63 are bodies with no clip of any family, which fits §6: a limb
aimed by an `External*Movement` is driven by the game writing a matrix into it,
not by an animation. So "`S` … is always playing" is true of most units and not
of all, and a runtime must hold the bind pose rather than assume three clips.

Counts: the model selector returns 104 names, `M` 28, `S` 30, `F` 33 — the
last three as stated above — and every one of the 137 resolves to a shipped
file. 29 of the 33 `F` clips carry a `BREAK` note; the other four end at their
own duration.

`fcn.004055e0(slot, unit, kind)` in `a3DObjects.cpp` is the "start animation"
entry point, and `kind` picks both the selector and the playback settings:

| `kind` | Name source | Started by | Playback set-up |
|--------|-------------|------------|-----------------|
| 0 | `0x0042da40` → **`M`** | `aTacTools.cpp` `fcn.0046e220` at `0x0046e581` — the unit-movement routine | calls interface slots `+0x44`, `+0x2c`; not decompiled, **UNVERIFIED** |
| 1, 2, 3 | `0x0042e220` → **`F`** | `aAnimations.cpp` `fcn.0040bd70` at `0x0040be88` — the combat routine, whose four leading arguments are the attacker's and the target's map coordinates | registers a `StopAnimationAtNoteEventCallback` on the note text `"BREAK"` (`0x0042c5d0`), i.e. the animation halts at its `BREAK` marker |
| 4 | fixed literal `"P0_M2_000"` (`0x004c030c`) | `aAnimations.cpp` `fcn.00417510` at `0x00417636` | calls slots `+0x44`, `+0x2c`, `+0x34` with `rand(0, 10)`; the slots are not decompiled, **UNVERIFIED** |
| — | `0x0042ddf0` → **`S`** | `a3DObjects.cpp` `fcn.004060b0`, called from the 3D-view refresh `fcn.00406fc0` for slots 1, 2, 4, 5 | the idle animation that plays whenever nothing else does |

So the letters are settled by their call sites, not by guesswork:

* **`S`** — the *idle / standing* animation. It is the only family the engine
  pre-registers at start-up: the 30 `aCreateCHAnimationDescriptor` calls in
  `fcn.00407e90` (`a3DObjects.cpp`, from line 0x1421) are exactly the 30 names
  this selector can return, because one of them is always playing.
* **`M`** — the *movement* animation, started from the tactical move routine.
* **`F`** — the *combat* animation, started from the fire routine and stopped at
  its `BREAK` note.
* **`M2`** — one special-case name reached only through `kind == 4`.
* **`J`** — **no code path references any `_J<n>_` name**; the substring does not
  occur in either executable. The three shipped files `P0_J0_000.cha`,
  `P0_J0_005.cha` and `P0_J0_006.cha` are unreferenced leftovers. What the letter
  stood for is not recoverable from the binaries. **UNVERIFIED.**

The remaining 104 `aCreateCHModelDescriptor` calls in `fcn.00407e90` register
the models (`P0_000` … `PS_031`) — which is why the model list and the S-family
animation list are the two things loaded eagerly.

---

## 8. Geometry: where it is *not*

`.cho` files carry no vertex, face, UV or material data. This is established, not
assumed:

* the parser consumes 237/237 files to EOF with the grammar in §3, which
  contains no float array other than the 16-float skeleton matrices;
* the size distribution matches — 255 B to 47 KB, median 7 KB, for models with
  up to 130 meshed parts, far too small for geometry;
* the mesh names *do* resolve elsewhere: of the 8 617 distinct `meshName`
  values, **8 509 (98.7 %)** appear verbatim inside
  `WorldSet/World_*/Objects/prototyp.dir` and the `Video/*/Objects/` equivalents.
  The 108 that do not are all `MODEL_*` names from the single template file
  `CHData/Objects/Model.cho`.

The mesh payload format inside `prototyp.bin` is out of scope here — it is
covered by `30-eng3d-ascii-formats.md` and the container work.

---

## 9. Note / event vocabulary

202 notes across 245 files, 58 distinct raw strings. The text is a small
newline-separated command script (CRLF), so the raw strings over-count; splitting
on newlines gives **21 distinct command lines** built from three verbs:

| Verb            | Occurrences | Where                     | Meaning                                    |
|-----------------|-------------|---------------------------|--------------------------------------------|
| `BREAK`         | 35          | 33 in `CHData/`, 2 `Video/` | gameplay animation break/interrupt point   |
| `Focus <n>`     | 140         | `Video/` only             | camera focal length (24, 28, 35, 43, 50)   |
| `Switch <n>`    | 55          | `Video/` only             | cut to camera *n* (1…8)                    |
| `Keys für Bewegung` | 2       | `Video/Dialog_09`         | German author's comment, not a command     |

Full list of command lines, most frequent first:

```
Focus 43 (48)   BREAK (35)      Focus 35 (27)   Focus 43.0 (21)
Switch 2 (14)   Switch 1 (13)   Focus 28.0 (11) Switch 3 (9)
Switch 4 (9)    Focus 50.0 (9)  Focus 50 (8)    Focus 24.0 (5)
Switch 5 (4)    Focus 28 (4)    Switch 7 (3)    Focus 35.0 (3)
Switch 8 (2)    Focus 43..0 (2) Focus 24 (2)    Switch 6 (1)
Keys für Bewegung (2)
```

The values are written inconsistently by hand (`Focus 43`, `Focus 43.0`,
`Focus 43..0`), and one note in `P0_F1_001.cha` is the empty string — a parser
must tolerate free text. Reproduce it as: split on CR/LF, trim, ignore blanks,
match `BREAK` / `Focus <float>` / `Switch <int>`, ignore anything else.

`BREAK` is the only verb that appears in gameplay animations, so it is the only
one the in-game animation system needs; `Focus`/`Switch` drive the cutscene
camera. The cameras themselves are `V100Camera` *components* (§10), not
records in these files.

**What `BREAK` does is now proven, not inferred.** When the combat routine
starts an `F` animation (§7.2, `kind` 1–3), `fcn.004055e0` builds the literal
`String "BREAK"` (`0x004c0268`) and passes it to `fcn.0042c5d0`, which allocates
a `StopAnimationAtNoteEventCallback` (vtable `0x004b138c`, constructed at
`0x0042c3a0`) and registers it on the animation. The animation therefore stops
itself the moment playback passes that note. `0x004a1220` is what makes it
happen: it walks the interval just advanced and fires the callbacks of the notes
inside it. It is a **note/event collector**, not the time advance — earlier
drafts of this document called it `KeyFramedAnimation::Update` and read the
frame rate out of it; the real advance is `0x004a0c50` (§4.8).

Regenerate with `python3 tools/cha_parse.py --notes gog_incubation`.

---

## 10. Classes and code paths with no data behind them

### 10.1 `V100Camera`, `StdAnimation`, `External*Movement`

These three (five, counting all the `External*`) were previously listed as
"registered in the RTTI but absent from the data, layout unknown". There is no
layout to recover: **they are `ComponentClass` entries, not `StorableClass`
entries** (§2.2), so they are never written to a file at all.

The only way any of them can appear in a `.cho` or `.cha` is as the
`componentClass` string of a `StdComponentDesc` (§2.4) — i.e. a `V100PartDesc`
whose part builds a `V100Camera` instead of a `V100Part`, or a
`LinearRotationMovementDesc` whose track drives an `ExternalRotationMovement`
instead of a `LinearRotationMovement`. The record layout in every such case is
the one already documented.

Our parsers would **not** accept one, though, and the distinction matters.
`inclib/charisma.py`'s `read_component_desc` accepts any of the 14 names when
called with no expectation, but `cha_parse.py` (`0x0049B4E7`'s counterpart,
line 288) always passes `expected_class=DESC_TO_COMPONENT[desc_class]`, i.e. it
enforces the 1:1 descriptor-to-component pairing. A
`LinearRotationMovementDesc` naming `ExternalRotationMovement` — the very
example above — raises `CharismaError`. That is deliberate: the pairing holds
in 245/245 shipped files, and loosening it to match this paragraph would give
up a real invariant for a file that does not exist. A remake that meets one
should widen the check rather than assume the layout differs.

The cutscene `Switch <n>` / `Focus <n>` notes therefore do not reference camera
objects stored in these files; the cameras are built elsewhere (the sequence
player) and the notes address them by index.

### 10.2 Reader branches the corpus never takes

Four branches of the engine's own `Load` methods have no shipped data behind
them. All four are implemented — the reader code is unambiguous — and
`tools/charisma_selftest.py` synthesises streams that take them, parses those
streams back and checks the result, so the code is executed rather than merely
written:

| Branch | Reader | Why no data |
|--------|--------|-------------|
| `SkeletonDesc` version 0 — one `LoadStorableObject` per node | `0x0048471d` | all 482 files use version 1 (hoisted class name) |
| `KeyFramedMovementDesc` version 0 — one `LoadStorableObject` per key, plus a per-track note list | `0x004a26d5` | 7 130 tracks use `(1, 3)`, 73 use `(0, 2)`, 43 use `(0, 1)` |
| `StdMovementDesc` attribute pairs — `u32 count` + `count × {lpstring, lpstring}` | `0x0049b4e7` | `attributeCount` is 0 in all 7 246 movements |
| `StdComponentDesc` children — `childCount × LoadStorableObject()`, each required to cast to `IComponentDesc` | `0x0049a9c4`, cast at `0x0049aabf` | `childCount` is 0 in all 25 125 records |

```
$ python3 tools/charisma_selftest.py
...
selftest: all paths exercised
```

The selftest also checks the negative: a child whose class *is* storable but is
not an `IComponentDesc` (it uses `SkeletonNode`) must be refused, which is what
the engine's `__RTDynamicCast` does. **These four paths are validated against
synthesised data only — no shipped file confirms them.**

---

## 11. Open questions / unverified

Closed in this revision, each with the address that proves it:

| Item | Where it is now documented | Proof |
|------|---------------------------|-------|
| **Frame rate** | §4.8 | speed factor is `1.0` and written once (`0x004a0bad`); cutscenes convert with `0.03` frames/ms = 30 fps (`0x004b157c`, `0x0046596c`, forwarded at `0x0047f76b`); gameplay passes a literal `1.0` per rendered frame (`0x00407104`, `0x00407382`) |
| **Bezier rotation controls** | §4.4 | `0x004ad53e` → `0x004ad7ab` → `0x004af0d1`, with `log`/`exp` at `0x004aefd1` / `0x004af04b`; implemented and validated on all 188 tracks |
| **The 0.25 / 0.5 hold rule** | §4.4 | `0x004b38e0` / `0x004b38f4`, compared in all five `GetValue`s; 5.2 % of intervals are affected |
| **`weight`** | §4.10 | written at `0x0049b537`, read only by `Save` at `0x0049b82b`; same two sites in `iDesigner.exe` — no runtime consumer exists |
| **`kind`** | §2.4 | constructor-assigned class tag, five values including the never-shipped `7`; five `mov dword [eax+0x1c], imm` sites listed |
| **Second position branch** | §6.2 | condition is `parent has no parent` (`0x0049d2ad` / `0x0049d2df`), i.e. the bone whose `.cho` parent is `ROOT`; scale and flag come from `StdModel` via the `"StandardModel"` interface (`0x0049fc2d`, `0x0049fc6a`) — **it is exercised by every model**, contrary to the previous revision |
| **`StdComponentDesc` child element type** | §2.4, §10.2 | `__RTDynamicCast` to `.?AVIComponentDesc@@` (`0x004f6a10`) at `0x0049aabf`; the parser now accepts children |
| **Animation family letters** | §7.2 | three selector functions (`0x0042da40` `M`, `0x0042ddf0` `S`, `0x0042e220` `F`) and their call sites in `aTacTools.cpp` / `aAnimations.cpp` / `a3DObjects.cpp` |
| **`BREAK` semantics** | §9 | `StopAnimationAtNoteEventCallback` registered on the literal `"BREAK"` at `0x0042c5d0` for every combat animation |

Closed in **slice 4**, by enumerating the selectors rather than reading them
(`tools/charisma_tables.py --check`, 40 checks):

| Item | Where it is now documented | Proof |
|------|---------------------------|-------|
| **What the model selector switches on** | §7.2.1 | three levels — type `+0x4C`, weapon `+0x3F`, **player** `+0x45`; index/jump tables at `0x0042D788`/`0x0042D71C`, `0x0042D840`/`0x0042D7D0` and `0x0042D870`+. Read two-level it gives 26 names; read three-level, exactly the 104 `fcn.00407e90` registers |
| **The `S0` parenthetical** | §7.2.1 | `0x0042DF77` draws `frand(0, 10)` from `0x004638E0` and compares it against the `5.0` at `0x004B1380`: the arm returns `PC_S0_011` or `PC_F1_011` |
| **The model filename grammar** | §7.1 | too narrow as written — `PC_ArmL_011` and `PC_ArmR_011` are shipped models the selector returns |
| **Bone-to-mesh scale** | §5.3 | 16, measured from four models' feet landing at −0.07 world units; 15 and 17 miss by 6.6 |
| **Which types get which families** | §7.2.1 | nine types get fewer than three; types 62 and 63 get none, which fits §6's `External*Movement` limbs |

One further entry is **closed, but kept written out** because a remake still has
to act on it rather than merely read it:

* **Gameplay playback rate is not a constant.** §4.8 proves the cutscene rate
   exactly (30 fps) and proves that gameplay advances one key-time unit per
   rendered frame, but the *rendered* rate is whatever the 1997 main loop
   achieves under a skip controller whose nominal caps are 20 fps in-game and
   25/30 fps in menus, and whose epoch handling doubles the effective cap
   (`0x0047f2e0`). There is no single number to recover here — the original had
   none. A remake must choose one; 30 fps is the consistent choice. This is
   **resolved as far as the shipped artefacts allow**, not open in the sense of
   "not looked at".

Still genuinely open — **six items**:

1. **What `weight` was for.** §4.10 proves the field is never read at runtime by
   either binary. Its *intent* — the class name and the constant value 100 both
   fit a percentage blend weight for layered animation — cannot be settled from
   the shipped artefacts. It would take the Charisma source, an `iDesigner` UI
   string set that mentions it (there is none), or a build in which the blending
   path is live. **UNVERIFIED.**

2. **The symbolic names of the `kind` enumerators.** The values, their five
   assignment sites and the fact that nothing reads them are all proven (§2.4).
   The enumerator identifiers are not in either binary — no strings, no
   debug data. `model` / `part` / `animation` / `movement` / `unspecified` are
   our labels. **UNVERIFIED**, and unresolvable without symbols.

3. **The `J` animation family.** No code in either executable references a
   `_J<n>_` name (§7.2); three `.cha` files use it and nothing loads them. The
   expansion of the letter is not recoverable from the binaries. **UNVERIFIED.**

4. **The four never-exercised reader branches** (§10.2) are validated against
   synthesised streams only. They match the reader code instruction for
   instruction, but no shipped file confirms them.

5. **Whether the engine applies the root `SkeletonNode`'s own matrix**, or
   replaces it with the model's placement transform (§5.2). §6.2 narrows this —
   the root bone's *translation* is taken from its Position track, not from the
   bind pose — but the disposition of the root node's rotation when no rotation
   track is bound is still inferred. `0x004842a2` (which would answer it) is
   dead code in the shipped binary. **UNVERIFIED.**

6. **Whether the −Y authored forward (§5.4) is reconciled by a rotation or by a
   mirror in y.** The eight facings determine the *result* — the body's yaw is
   half a turn minus `docs/10` §5.10's angle — and that is measured. Both a
   plain rotation and a y-mirror produce it, and they differ by swapping the
   body left for right, which no measurement here separates because a biped is
   near-symmetric. The bridge that would answer it is not decompiled. **The
   discriminator is cheap and known**: the marine's weapon is parented under
   `Hand_R`, so one screenshot of the original showing it in the left hand says
   mirror. **UNVERIFIED.**

---

## 12. Tool reference

```
# walk a file, dump every class record with the raw bytes between them
python3 tools/charisma_dump.py gog_incubation/CHData/Objects/P0_000.cho

# every length-prefixed string, class names flagged
python3 tools/charisma_dump.py --all-strings <file>

# class-name census with the two bytes before/after each occurrence
python3 tools/charisma_dump.py --census gog_incubation --ext .cha

# prove there is no numeric class registry
python3 tools/charisma_dump.py --registry gog_incubation

# model: text summary / JSON / corpus coverage + invariants
python3 tools/cho_parse.py gog_incubation/CHData/Objects/P0_000.cho
python3 tools/cho_parse.py --json <file>
python3 tools/cho_parse.py --check gog_incubation

# animation: text summary / JSON / coverage / events / binding / conventions
python3 tools/cha_parse.py gog_incubation/CHData/Animations/P0_F0_000.cha
python3 tools/cha_parse.py --json <file>
python3 tools/cha_parse.py --check gog_incubation
python3 tools/cha_parse.py --notes gog_incubation
python3 tools/cha_parse.py --cross-check gog_incubation
python3 tools/cha_parse.py --verify-convention gog_incubation

# the four name selectors, enumerated by interpreting them; 33 corpus checks
python3 tools/charisma_tables.py --check gog_incubation
python3 tools/charisma_tables.py --names gog_incubation
python3 tools/charisma_tables.py --json  gog_incubation
# the pose fixture the remake's GDScript sampler is diffed against
python3 tools/charisma_tables.py gog_incubation \
    --emit-pose-cases tests/fixtures/charisma/cases_pose.json

# pose a skeleton: OBJ line segments per frame + orthographic PNG sheet
python3 tools/cho_export.py gog_incubation/CHData/Objects/P0_000.cho
python3 tools/cho_export.py gog_incubation/CHData/Objects/P0_000.cho \
    --anim gog_incubation/CHData/Animations/P0_M0_000.cha --frames 12
python3 tools/cho_export.py --samples gog_incubation

# exercise the four reader branches the corpus never takes (§10.2)
python3 tools/charisma_selftest.py
```

`--check` exits non-zero if any file fails to parse to exact EOF, so both
commands work as regression gates; `charisma_selftest.py` exits non-zero if any
synthesised path fails. The four-command gate for any change to the parsers is:

```
python3 tools/cho_parse.py  --check gog_incubation          # 237/237
python3 tools/cha_parse.py  --check gog_incubation          # 245/245
python3 tools/cha_parse.py  --verify-convention gog_incubation
python3 tools/charisma_selftest.py
```

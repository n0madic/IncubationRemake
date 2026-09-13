# Slice 5 — a world that answers back

**What this slice set out to do:** make a shot sound and look like something;
make the lift move, the tube open, the door slide and the alien fall from the
ceiling with a scream; play the mission's own music. Play `_C_140`, `_C_141`
and `_C_115` in an exported build with sound and effects, and measure what a
full effect pool costs per frame.

**What it did:** the sound layer entire, the blob pool entire — all 78 update
kinds diffed against the Python reference tick by tick — the sprite path, the
three weapon switches, the set-piece driver and the re-render that closes the
slice's headline visible defect. It also recovered one constant neither
delivered specification carried, and it reports two things it did **not** do.

Four slices closed the *rules* and the *bodies*. [`93`](93-slice-1-report.md)
the map, the fill and the path; [`94`](94-slice-2-report.md) the turn, fog,
combat, reaction, interaction and the mission script; [`95`](95-slice-3-report.md)
the AI planner; [`96`](96-slice-4-report.md) the Charisma bodies. What the
remake had none of was everything that is **not a rule**: there was no audio
call site anywhere in `godot/`, no particle system, and a door that changed its
cell's height by `0xC80` and produced no visible change at all.

---

## 1. The structural fact the whole slice rests on

[`28` §8](28-effects-and-sound.md):

> **effects are not driven by the simulation, they are driven by the animation
> routines**, and the simulation only calls those.

Of the callers of all 81 blob creators, exactly **two** sit outside
`aAnimations.cpp` and `aBlobs.cpp`. Nothing in the original reads a blob back.
Damage stays in the resolver; blobs are cosmetic.

Two consequences decided the slice's shape:

1. **The `core/` delta is zero, and it is measured.** `git diff --stat
   godot/core/` is empty, `SaveCodec.SCHEMA_VERSION` is still 6, and `_C_140`'s
   canonical hash is still
   `50d33fa7a150fc13f36256266ad1f3f89d09cd994b7d05f500c51760a2b81fe9` — the
   value [`96` §](96-slice-4-report.md) recorded. `core` already emitted every
   event this slice needed; three call sites in `game` stopped discarding them.
2. **No `.cha` note starts a sound or creates a blob.** `0x0042C5D0`, the
   note-callback registrar, has exactly one caller in the whole image
   ([`28` §9](28-effects-and-sound.md)). The timings are carried by the
   drivers, not by the animation data — so a driver is what was written.

---

## 2. Where the blob pool lives, and why

This was the slice's one consequential architectural call, and it is not close.

A blob is deterministic integer arithmetic over an 88-byte record drawing from
`aRandom`. In `core/` it would be covered by the canonical hash and diffable
against Python with the machinery that already exists. **Three arguments put it
in `game/` instead:**

* [`28` §8](28-effects-and-sound.md) again: effects are created by the
  animation routines, which `core` does not have — it applies everything
  instantly. A pool in `core` would need a tick `core` has no concept of.
* **The hash.** Particle draws depend on the frame rate and on whether the
  player skipped a replay. A pool in `core` drawing from `world.rng` would put
  the frame rate into `CanonicalHash`'s item 5, and would force a save-schema
  bump — for state **no rule reads**. Giving it a separate stream inside `core`
  fixes the hash and breaks the fidelity claim the other way: a separate stream
  is not what the original has, so there would be no reason for it to be in
  `core` at all.
* The original treats effects as optional: a constructor that finds no free
  slot returns `-1` and the effect silently does not appear
  ([`28` §7.1](28-effects-and-sound.md)).

**Determinism is therefore bought explicitly rather than inherited:**
`BlobPool.trace_digest()` hashes every live record in slot order, and
`test_effects.gd` requires the same seed and the same events to give the same
digest while a different seed gives a different one. The pool is seeded from
the mission name and never from `World.rng`.

---

## 3. The sound layer

`tools/inclib/sound.py` is new and is the executable model of
[`28` §§1–5](28-effects-and-sound.md). It opens no file and reads no binary:
`tools/blob_tables.py` owns the extraction and hands it the tables, so the two
readings stay independent and a mutation of one is not absorbed by the other.
`blob_tables.py --check` grew from **259 checks to 345**, of which 82 compare
the model against decoded data rather than against a second pin.

What it holds, and what pins it:

| Rule | Pinned by |
|---|---|
| Twenty buffers, and a twenty-first that can never play | the four routines' own bounds, which differ by one |
| `att = base + 20·percent − 2000`, clipped at 0, silence below −2000 | the four constants at their own sites, swept over 26 base volumes × 7 percentages |
| 103 `SetVolumeCtrl` ids, seven of them not 100 % | `Info.lcl`, read by `blob_tables.py` and compared id by id |
| The 62 call sites partitioned into 43 remake events | every site's owning routine, bounded by the nearest call entry |
| Nine looping play sites, reached by thirteen loads | **derived** from `PLAY_SITES`, not pinned separately |
| The weapon's own fire sound, scaled by its **own id** | 42 `SetWeaponInfo2` rows, 41 of which resolve |
| Two voice cursors, `SP_HUM_*` sharing the human one | the nine voice arms and their two cursor addresses |
| Eight footstep arms over 69 unit types, 39 silent | the 69-entry index table and its jump table |

### 3.1 Case is resolved once, at conversion time

Ten of the fifty literal wave names do not match the shipped file's case, so a
naive open fails on anything but Windows. The converter resolves them **once**
and writes every wave into `audio/waves/` under the lower-cased name the
document uses. The runtime never does a case-insensitive search, so the hazard
cannot recur. A check counts both populations: 50 names pushed at a load call
site (the doc's own figure) and **58** once the voice and footstep names the
arms build in a register are included — which is the set the conversion has to
resolve, and the wider one.

### 3.2 The three audible defects, decided rather than inherited

[`92` §7.1](92-remake-architecture.md)'s rule is *reproduce a defect that is
part of the output; never reproduce a defect that makes a control inert*.

* **Weapon 35's fire sound** never loads: `Info.lcl` spells the file
  `W_BAY0_0` with a zero for the letter O, and patches a record no
  `SetWeaponInfo` ever created. Reproduced by default. The converter emits it
  as a **named warning** with a null entry, not as a silent gap.
* **Unit type 24's footsteps** are scaled by volume id 45 — inside the
  weapon band, one bit from the 91 its twin uses — so that one type walks at
  100 % where its twin walks at 50 %. Reproduced by default.
* **The alien scream** is scaled by the *human* volume ids. Fixed
  unconditionally: the combat path now passes 59/60/61, the ids `Info.lcl`
  labels `S_ALI_0/1/2`.

**One correction to `92` §7.1's own wording.** It justifies the alien fix by
saying the defect "leaves ids 53–55 defined and dead". It does not: 53–55 are a
*second* `SP_HUM_0/1/2` label and stay unnamed under either setting. The fix is
still right — an "alien voices" control that moved nothing would be inert — but
it is the 59/60/61 ids that make it work, not 53–55. `sound.py` records the
three ids as permanently unnamed and a check asserts it.

---

## 4. The blob pool, and the gate

`game/fx/` is the port of `tools/blob_runtime.py`: the 88-byte record, the
delay/life/dispatch wrapper, and all **74** arms behind a 78-entry `match`
whose four aliases (21/24, 23/40, 48/53, 66/70) are written as aliases.

`blob_runtime.py` gained `--emit-cases`, which writes 78 kinds × **12
scenarios** — 936 cases, 3 900 ticks. `tests/test_blob.gd` replays them and
compares **111 384 field and flag values**, every spawn with its arguments, and
`aRandom`'s call count and seed after every single tick.

**The gate was demonstrated, not assumed.** Changing one arm's gravity constant
by one unit — `0x64` to `0x63` in kind 0 — makes the suite fail and name the
field and the tick:

```
FAIL blob.ticks: 780 cases, 3276 ticks, 111384 field and flag comparisons,
  247 spawns; kind 0 profile tick 0: vz 401 != 400; kind 0 profile tick 1:
  z 1901 != 1900; ... (and 57 more)
```

Two scenarios exist only to close branches both sides would otherwise have
agreed on by never running: `emitter_special` reaches kind 59's
`emitter_mode == 3` arm, and `zero_velocity` reaches kind 41's division guard.

### 4.1 Two port hazards worth recording

* **Python's `round()` is half-to-even; GDScript's `roundi` is half-away-from
  zero.** The seek step reaches the half-integers whenever a distance divides
  evenly. `BlobHooks.round_half_even` is written explicitly and checked on
  every half-integer either side of zero, with a check that it *differs* from
  `roundi`. Half-to-even is also the right answer: it is what an x87 store does
  under the default rounding mode.
* **`IncRandom` exposes only the truncated draw**, and kind 62 compares the
  raw x87 value against the literal `5.0` — the fractional part decides whether
  a spark burst happens. `core` is not changing, so the raw value is recovered
  from the seed the draw left behind, which is the same number the original
  multiplied.

---

## 5. The oracle boundary, stated down

**Nothing in this slice is `native-runtime`, and both suites print
`executable-Python`.**

[`28` §12 item 1](28-effects-and-sound.md) records that the return data of the
original's orientation, geometry and target-map helpers — `0x004039A0`,
`0x00403AA0`, `0x0046D400`, `0x00405100`, `0x00477AE0` — has never been
validated against a native trace. Every arm that calls one is therefore
compared against **the same deterministic adapter on both sides**, implemented
twice: `CaseHooks` in Python and `BlobHooks` in GDScript, each a pure function
of its arguments and two small tables.

So `test_blob.gd` checks that 74 arms were transcribed correctly. It does
**not** check that a particle follows the trajectory the original's particle
followed. Both fixtures carry that sentence in their own `oracle` field.

The one service that *is* natively pinned is the generator: `aRandom` is
[`91`](91-wine-runtime-probes.md)'s routine and `core/rng.gd` its twin, so the
draw counts and seeds compared every tick are anchored even though the hooks
are not.

---

## 6. The finding: `RoofUnit`'s drop rate

The three demo missions need seven set-piece frame counts.
[`20` §7.4](20-lcl-language.md) gives five (`Elevator` is `steps` frames of
±800, `Platform` `dist·10` frames of ±0x140, `Bridge` 80 frames of ±12,
`FootBridge`/`FootBridge2` take theirs as an argument) and
[`28` §1.4](28-effects-and-sound.md) quotes `aDoorOpenSequence`'s own
`for (n = 10; n; n--)`. **`RoofUnit`'s was in neither.**

It is one instruction. The drop loop at `0x00411DF3` reads:

```
    call frameTick                  ; 0x0040B6F0
    z -= 0xC80                      ; 0x00411E26
    aChangeStdObjectPosition(type, x, y, z + 0xA0)
    if (z > floor) loop
```

**The falling unit drops a whole map field — 3 200 world units — per displayed
frame.** `RoofUnit (x, y, height, unitType)` starts at `height · 1600`, so the
count is `height · 1600 / 3200`; the shipped heights of 20 to 65 give 10 to 33
frames, half a second to 1.65 seconds at 20 fps. Four checks pin it, including
one that the loop really is paced by the frame tick.

---

## 7. The re-render: the headline defect

`Scenery.build` ran **once per mission** and `TerrainOverlay.build` once more,
so `Interact.toggle_door` writing a field-type flip and `DOOR_HEIGHT_STEP` into
`MapState` produced no visible change at all until `[` or `]` rebuilt the
mission.

Closing it needed no new concept in `core`. `game` keeps the last terrain
snapshot it drew, and `TerrainDiff` compares two immutable views:

> **`game` renders `f(authored, MapState)`. The diff exists only to say which
> cells to redraw, never to hold state.**

`Scenery` records each instance's **authored** transform and each cell's
**authored** height — from the `.lev`'s own lattice records, not from the state
at build time — and offsets by the difference. Three properties follow and are
each checked: applying twice is applying once, closing a door returns the panel
exactly where it started, and a save resumed with a door already open draws it
open on the first frame.

What moves is settled by the corpus rather than by reading
[`26` §3.4](26-interaction.md) literally. Its decompile says the toggle writes
`landObject->z`, and [`10` §6.3](10-lev-mission-format.md) says the land record
is a 320-unit editor marker. But `_C_140`'s two closed doors each carry a
**special object** `L100EX00.3DI` — a full-tile-wide panel spanning z 36…3673 —
and §3.4's own prose says *a door is a wall panel that rises out of the floor*.
So every object standing on the cell takes the height delta, which the rule
above gives for free with no special case.

**Corrected 2026-09-06.** The panel does not move, and it was never drawn. The
`landObject` of §3.4's decompile is the object the cell's `+0x05` names, and
that word is the cell's **land-lattice slot** — the 320-unit marker whose z is
the cell height in every shipped record; the toggle keeps that invariant and
nothing else. The panel is the object `0x00406F20` finds beside the marker,
and the ten frames the sequence runs add `mov ebx, ±100` to its joint words
`+0x2A` and `+0x30` — the z angles of parts 6 and 12 — so its two leaves swing
88° about the hinges at the frame's outer edges. The `.lev` says the same: all
302 door objects in the corpus carry `(0, 0, ∓1000)` when their cell ships
open and zeros when it ships closed. And the reason nobody saw a panel rise
is that `Scenery` built each prototype's **root scope** alone, and
`L100EX00.3DI` has no root geometry — all sixteen vertices belong to its two
parts — so the mesh had no surfaces, the object was never registered, and the
door test above passed on the lattice marker standing on the same cell. The
scenery now assembles every object as body plus part pivots
(`MeshBuilder.assemble`, shared with `BlobModels`), poses the parts by the
record's authored joints (in the cache since `CONVERTER_VERSION` 0.24.0), and
on a door cell turns the leaves by the cell's parity while the marker alone
takes the height delta; the ten frames paint the swing. The flight aims at
the **panel's** z rather than the cell's, which on a closed door is a tile
higher and had the camera looking up at the lintel.

---

## 8. The set-piece driver

`SequenceQueue` is the generalisation of `AIPlayback`, which already had a
`_hold` a step could lengthen. A blocking `aPlay*Sequence` becomes a queued
step of *n* frames at **20 fps** — the same clock the bodies use
([`92` §7.10](92-remake-architecture.md)), which is the whole point: the
original's blob tick and its sequence loop are both "once per displayed frame",
and that frame is the one that was measured, so a set piece and a walking body
cannot drift apart.

Three rules the queue enforces rather than observes:

* **A sound's lifetime is its sequence's** ([`28` §1.4](28-effects-and-sound.md)).
  Every sound a step starts is killed when the step ends, never when the sample
  runs out. Nine of the fifty-eight play sites loop and all nine are machinery
  whose sequence outlasts its sample.
* **`skip()` means stop drawing, never stop simulating.** Every remaining step
  is painted at its own last frame — which is the state the world has held
  since `core` returned — and every queued sound is killed.
* **A queued cell is not redrawn by the diff** while its sequence runs.
  Snapping it to the finished state would show the end of the lift before the
  lift.

Sequences the converted missions do not reach — the statue, the barrier, the
crush wall, the ground unit and thirteen more — apply their state change with
their sound and no motion, and are **named** in `SetpieceDriver.INSTANT` rather
than merely absent: an event that is silently unhandled and one that is
deliberately instant look identical from outside.

### 8.1 A bug this found in its own first draft

`core` spells its two event streams differently and both are legitimate: a
mission script's events serialise as `[name, values]` **pairs**
(`LclOutcome.to_dict`, so the document matches `inclib.lcl_runtime`'s) and the
computer's are `{"kind": …}` dictionaries. Reading only one of them yields an
empty name and no cue — which is a perfectly plausible answer, so **every
set-piece sound was silently missing and nothing said so**. `AudioEvents.as_event`
now normalises all three shapes and a check covers each.

---

## 9. Measurements

| | Before | After |
|---|---|---|
| Cache, with music | 7 476 KiB | **31 428 KiB** |
| Cache, without music | 7 476 KiB | **10 255 KiB** |
| Conversion time | ~7 s | ~8 s |
| Waves in the cache | 0 | 81 (of 99 shipped) |
| Music tracks | 0 | 5 (the union of five playlists) |
| `blob_tables.py --check` | 259 | **384** |
| `remake_convert.py --check` | 101 | **181** |
| Godot suites / checks | 27 / 1 678 | **31 / 1 854** |

The last three rows are as of §14, which closed the slice's own loose ends;
they were 345, 169 and 30 / 1 811 when §1–§13 were written, and 367,
181 and 30 / 1 842 at the end of §14.

**95 % of the cache's growth is music**, which is why it is behind
`--no-music`, why the manifest records which of the two caches it is, and why
the size check names **two** ceilings rather than one.

### 9.1 The frame cost of a full pool

Taken before the model-blob path existed, because that is the only time the
answer is useful — the plan's cut list is keyed to this number.

| | |
|---|---|
| Pool tick, 450 live blobs | **1 117 µs** (2.48 µs a blob) |
| Sprite rebuild, 450 camera-facing quads | **655 µs** |
| Per displayed frame (tick at 20 fps, rebuild at 60) | **1 028 µs** |
| Headroom against a 16 667 µs frame | **16.2×** |

**The frame budget forced no cut.** That is the useful reading of the number,
and it is narrower than "nothing was cut": the pool ticks and updates every
model blob correctly at full occupancy with sixteen times the budget spare, so
the plan's first cut — *keep only the sprite path* — was never **forced**. Two
items from that list were still taken, as scope rather than as cost, and §11
names them. §14.1 took them back and re-measured.

---

## 10. Deviations from the plan, all deliberate

1. **Audio compatibility flags live in `game/audio/`, not `World.compat_flags`.**
   The plan said they go where `canonical_hash.gd` already carries them; but
   that array is item 6 of `CanonicalHash.compute`, and the acceptance criteria
   require the hash and the save schema to be unchanged. `weapon_35_missing_sound`
   and `unit_24_footstep_volume_original` change what is heard and no rule, so
   they are held by the audio layer under [`92` §7.1](92-remake-architecture.md)'s
   stable names. `technical_box_guard_original` stays in `core`, where it
   belongs, because it changes the simulation.
2. **The sprite atlas reaches the cache through the existing per-set texture
   path**, not as a separate `textures/anim.png`. `anim` is an ordinary VISN
   record, so adding its id to each set's closure reuses the whole VISN → PNG
   chain and turns "byte-identical in all nine sets" into a *check*. Measured:
   256×256, a 31 309-byte PNG, identical across A00, C00 and D00.
3. **Effect models join `geometry/<set>.json`**, not a separate
   `geometry/effects.json`. They are ordinary world-object prototypes. The four
   that exist in one or two world sets are recorded as `absent_effects` — a
   constraint, not an error — and the existing completeness check subtracts
   them so a *real* missing prototype still fails.
4. **Music uses the `Track` family** — see the open question below.
5. **`slot_tag` is the pool slot index**, not the record's address. Kinds 25
   and 56 branch on the low byte of the record pointer to mirror an animation;
   the slot index is the same kind of fact and is reproducible.
6. **The sound pool is twenty slots**, [`28` §1.1](28-effects-and-sound.md)'s
   own advice. The drop behaviour itself *is* reproduced, and drops are counted.

---

## 11. What was not done, and what is still open

* ~~**Unit speech** ([`20` §7.4](20-lcl-language.md)) — 233 files, out of scope
  by the plan.~~ **Closed on 2026-09-05** — [`99` §8](99-slice-7-report.md).
  The 233 files are in the cache's closure, `game/audio/speech_player.gd` plays
  them and the set is the unit record's own `+0x55`. Speech rides the FX volume,
  as the original scales it by the options record's speech field; the options
  screen still has no speech row, which [`92` §7.1](92-remake-architecture.md)
  permits.
* **Ambience** — [`28` §6](28-effects-and-sound.md) proves the subsystem never
  plays anything. The ten `amb_*.wav` and four other unreferenced waves are
  excluded from the cache, and a check asserts none of them is in it.
* ~~**`CreateBGB`**~~ — **closed on 2026-09-04.** It was 14 calls in the whole
  corpus and none in the five converted missions; the campaign maps are now in
  every cache and their `InitMap` is four `7_fire` emitters each, so the
  command has a consumer. `game/fx/bgb_emitters.gd` is the twenty-slot table
  and `0x0041E1A0`'s cadence, and `BlobPrograms.main_map_fire` is
  `aBlob_CreateMainMapFire` `0x0042A660`. **All seven creators followed on
  2026-09-05**, together with the finding that the command has *two* jump
  tables and no type is in both: types 2..6 make their object at registration
  and tick to a bare return, so the tally that had counted them as unmade was
  reporting the engine's own silence as a gap.
* ~~**Model blobs and joint angles are not drawn**~~ — **closed in §14.1.**
  The text below is what the slice reported; the pool's model half now draws,
  and the panel flickers.
* **(as reported)** Model blobs and joint angles are not drawn (§7.5 and
  §7.8) — the plan's
  cut list items 1 and 2, taken as **scope**, not because the frame budget
  demanded it: §9.1 measured sixteen times the headroom. The pool creates,
  ticks and deletes every class-0 and class-1 blob correctly, resolves its
  model against the world set and cancels it when the set lacks it — but what
  reaches the screen is the sprite path. So the computer panel does not
  flicker, the fire does not spin, and a laser bolt is its sparks rather than
  its geometry. 54 of the 116 constructor calls are sprites, so about half the
  effects are visible.
* ~~**Footsteps are modelled and not heard**~~ — **closed in §14.2.** The
  reasoning below still holds; what changed is that the frame counter was put
  where the walk is, in `game/`, rather than asked of `core`.
* **(as reported)** Footsteps are modelled and not heard — the plan's cut list item 5, and
  the one cut with a structural reason rather than a scope one. The eight arms,
  their waves, their volume ids and their periods are checked against all 69
  unit types in both presets, and `AudioEvents.footstep` answers correctly. But
  a step is 2 to 8 frames apart and `core` hands over a **whole path at once**:
  the event a footstep needs does not exist, and the phase that would supply it
  is `CharismaState`'s. Wiring it is a change to the body's walk, not to the
  audio layer, which is why it was left where the plan left it.
* **The creators' argument arithmetic** — **almost closed between 2026-09-11
  and 2026-09-12, and the figure this bullet used to carry is stale.** §14.5
  measured the gap (30 of the 81 creators and 43 of the 116 constructor calls
  reachable by firing a weapon, 27 of those 43 carrying a literal lifetime);
  §14.5.1–§14.5.5 then transcribed and captured it. Counted against
  `blob_tables.creators.reachable`'s own thirty on 2026-09-12: **25 of the
  thirty are replayed against `blob_gold.py`'s capture** in
  `test_blob_native` — 22 rows of `BlobTriggers.WEAPON_PROGRAMS` plus the three
  typed seams `SPORE_EXPLOSION`, `GRENADE_ARC` and `FLAME_STREAM`, and
  `weapon_programs.routed_are_measured` is what keeps that list and the routing
  table equal.
  ~~**The other five are driven by arms of their own and are replayed nowhere**:
  the shock wave `0x00422B80` and the spore cannon `0x004268B0`, which build
  their own records and are checked structurally in `test_effects`, and the
  tracer `0x004247C0`, the needles `0x00424250` and the flash `0x00423D80`,
  which still go down the constructor-table arm one record per `call`. All five
  have a `blob_gold` phase behind them, and for the last three the burst delta,
  the lifetimes and both point-blank branches are measured — what is not is the
  spread of the records inside one call. Beside them, the arc of weapon 11 — a
  property of `_6_.sav` rather than of the arm
  ([`28` §12 item 2](28-effects-and-sound.md)).~~ **Closed 2026-09-12,
  evening — §51.** All thirty are programs of `BlobPrograms` and all thirty
  are replayed (303 records); the constructor-table arm is gone. And the arc
  was not a property of the save: weapon 11's handler marks on the **state
  byte**, the target overlay's band, and it runs on two captured shots
  (§51.2).
* **(as reported)** The three weapon switches are
  transcribed and pinned, so a shot fires the **right effects, of the right
  kinds, for the right lifetimes, from the right atlas tiles**. But the 81
  creators' own placement and velocity arithmetic is transcribed nowhere in
  this repository, so `BlobTriggers` supplies a straight line at a chosen
  speed. That is the remake's own, it is said so in the file, and closing it is
  its own piece of work.
* ~~**A unit an elevator carries pops rather than rides.**~~ — **closed in
  §14.3**, and not by the suppression this paragraph considered.
* **(as reported)** A unit an elevator carries pops rather than rides. `RoofUnit`'s alien is
  held out of the picture until its drop ends (§13's criterion), but a unit
  standing on a moving lift is rebuilt at its finished height by
  `_units.build` while the scenery under it interpolates. The same suppression
  would hide it and the same hook would show it, but hiding a unit the player
  is watching move is worse than letting it arrive early. Recorded, not fixed.
* ~~**The exported build leaks four objects at exit**~~ — **closed in §14.4.**
  The diagnosis below was right about *where* and wrong about *what could be
  done*: `_exit_tree` is too late, not powerless.
* **(as reported)** The exported build leaks four objects at exit — the Ogg music stream, its
  packet sequence and both playbacks. Established as the music path by running
  the same build against a `--no-music` cache, where the leak does not occur.
  `AudioSystem._exit_tree` stops the players and drops every cached stream and
  the report persists, so the reference is the audio server's rather than the
  scene tree's. Cosmetic — it is one warning at process exit and the streams
  are released on any ordinary mission change — but **unresolved**.

### 11.1 `93` §11's deferred-draw-order trigger, answered

[`93` §11](93-slice-1-report.md) deferred the draw order of the engine's
translucent kinds and asked to come back to it "when the Charisma models or the
aim markers are converted". Both now are, so the trigger has fired.

**Nothing needs to change.** Of the 26 blob models `World_A00` carries, the
draw kinds used are `0x08`, `0x10`, `0x14` and `0x1C` only — additive and
subtractive commute, and masked is a scissor rather than a blend, so none of
the three is order-dependent. The one kind that *is* — `0x0C`, the translucent
flat fill — **appears on no blob model and on no face in A00's converted
closure**. The sprite path adds no ordering problem of its own either: every
zoom bob is additive with depth writing off, which is the same treatment
`mesh_builder.gd` already gives the engine's own deferred kinds.

The trigger is therefore closed with numbers rather than re-deferred.

### 11.2 A new open question for `docs/28` — closed in §14.6

`music/` ships two families, `Track02…20` and `Arack02…14`. Measured pairwise,
**02–08 are byte-identical and 09–14 differ.** Shipped playlists reach track
13, so the choice matters for 9–13 — and it looked unfalsifiable on this
slice's corpus, whose five missions reach only track 7. The slice recorded
`Track` as a choice.

**It was not a choice and the corpus was never the place to look.** §14.6 reads
the import table: the shipped build plays `Arack`. The open question this
section opened in `docs/28` §12 is closed in the same pass that opened it,
which is worth saying plainly rather than quietly deleting.

---

## 12. The mutation battery, and the two bugs it found

Every constant this slice added to `blob_tables.py` and `inclib/sound.py` was
perturbed one at a time and the whole check set re-run: **53 mutations, 40
caught, 13 unread** — the caught figure by subtraction, since every target
lands in exactly one of the two lists. `tools/**/__pycache__` is cleared before every run,
including the final one on the restored tree — write-mutate-restore completes
inside one filesystem mtime tick, so CPython otherwise keeps running the
*mutated* module after the source is back.

**The battery found two bugs in itself before it found anything else**, and
both are worth recording because both made a green result meaningless:

* it read `proc.stdout`, and `blob_tables.py` configures `logging` with no
  handler of its own, so **every check line goes to stderr**. First run: 0 of
  53 caught, on a check set that catches 40 — a result that was not believed
  precisely because it was too clean a failure;
* it counted a mutation as caught only when a `FAIL` line was named. A
  perturbed constant that puts the model out of range makes the tool *raise*,
  and a non-zero exit with a traceback is the check set noticing just as much
  as a named failure is.

**And the re-run found a real bug in the remake.** `BlobPool` resolved a model
name through `BlobHooks.MODELS` — the *diff's* three-name deterministic table —
so every class-0 muzzle effect was refused. Weapon 2's muzzle is two model
blobs, `A_LINE5.3DI` and `A_CASE.3DI`, and the trigger reported making **zero**
effects, which is a perfectly plausible answer for a weapon with no muzzle arm.
`BlobHooks.model_index` now carries the world set's own prototypes; the
deterministic table remains the fallback, which is what keeps the Python diff
reproducible. The fix also implements [`28` §7.5](28-effects-and-sound.md)'s
constraint for real, and a check asserts it: `A_PARAB1.3DI` on `World_A00`
is **cancelled**, not drawn as a hole.

### 12.1 The thirteen pins no check reads, and why

Named rather than left implicit, on the precedent of §11's own nine.

| Pins | Why nothing here reads them |
|---|---|
| `DOOR_SEQUENCE_FRAMES`, `ELEVATOR_STEP`, `PLATFORM_STEP`, `PLATFORM_FRAMES_PER_FIELD`, `BRIDGE_FRAMES`, `BRIDGE_STEP` | Read out of the LCL handlers by [`20` §7.4](20-lcl-language.md) and quoted here for the driver. `blob_tables.py` has no **second** reading of them, so a check would compare a pin with itself. `tests/test_effects.gd` pins each against the shipped commands' own arguments. |
| `ATLAS_SIZE` | Derived — `ATLAS_TILE * ATLAS_GRID` — so there is no literal to perturb, and both factors are caught. |
| `ATLAS_HALF_EXTENT_SCALE` | Consumed by the cache document and by the sprite path; pinned on the GDScript side, where `HALF_EXTENT_SCALE / 1600 == 0.1` is checked. |
| `COMPAT_WEAPON_35`, `COMPAT_FOOTSTEP_24` | Flag **names**, whose only independent reading is [`92` §7.1](92-remake-architecture.md)'s prose. |
| ~~`MUSIC_FORMAT`~~ | **Now caught** — §14.6 gave it three independent readings: the shim's own format string, the shipped playlists, and the family's file range. |
| `INTERFACE_WAVES[entry]` | The sampled perturbation lands on a digit inside a name the containment check tolerates. The set itself is checked against the seventeen direct sites. |

`ROOF_UNIT` and `PAIN_CURSOR_MODULUS` were both in this list until the last
pass. The second turned out to be a battery artefact: perturbing the modulus
puts the voice cursor past the end of its own three-entry table, so the tool
*raises* rather than reporting, which is the check set noticing just as much as
a named failure is.

**The first was recorded as fixed here and was not.** It gained a containment
check — the drop, the draw offset and the frame tick must lie inside the routine
whose address it is, bounded by the next call entry — and that check catches a
wrong *function* and tolerates a wrong *byte*, which is exactly what the battery
perturbs. §14 caught the discrepancy and added the check that does the job:
`roof.is_a_routine` requires the address to be the target of a call. Recorded
rather than quietly corrected, because "a check was added" and "the mutation is
caught" are not the same claim and this section had conflated them.

---

## 13. Verification

```bash
python3 tools/blob_tables.py --check gog_incubation        # 407 checks
python3 tools/blob_runtime.py --selftest                   # 78 kinds, 74 arms
python3 tools/remake_convert.py gog_incubation --check     # 181 checks
bash godot/run_tests.sh                                    # 31 suites, 1860 checks
```

Plus the whole always-run block (38 commands, all green), the exported shipping
preset — which excludes `tests/`, so a `class_name` from there used in `game/`
breaks only it — and `_C_140` played in that build.

Both new suites **fail rather than shrink** when their fixture is absent, both
refuse a stale fixture **by name** through its schema string, and both are in
`harness.gd`'s minimum-check table.

`core` is still without a scene tree, a filesystem or an engine singleton;
`tests/fixtures/violations/` still does not compile; typed warnings still fail
the build — which caught four real errors in this slice's own files before any
of them ran.

---

## 14. Closing the slice's own loose ends

§11 listed what the slice left open and §11.2 opened one new question. This
section is a **later pass over that list**, taken as a whole. Six items, of
which four are now closed, one is closed and turned out to close two open
questions in other documents as well, and one is measured rather than closed.

Two of the closures needed no new research and one needed none at all — it
needed the right file read. That is the pattern worth carrying forward: three
of the six were open because of an assumption about where the answer lived, not
because the answer was absent.

### 14.1 The model half of the pool draws, and its joints move

The pool always ticked its class-0 and class-1 blobs correctly; what it did not
do was put them on screen. `game/fx/blob_models.gd` does, and the interesting
part is not the drawing — it is that a **single mesh cannot** show what
[`28` §7.8](28-effects-and-sound.md) describes.

A jointed prototype's sub-objects live in their own `part_push` scope with
their own `joint_place` operand, and the arms of kinds 42 and 54 rotate those
scopes rather than the object. So the converter now emits, **for a prototype
that has parts and only for one that has parts**, each part's joint-buffer
offset, its `part_push` translation, and the vertex slots it owns:

```json
"parts": [{"anim": 6, "translation": [0, -64, 0], "vertices": [4, 5, 6, 7]}]
```

`MeshBuilder.build_scope` splits a prototype on that ownership — a face belongs
to the part its first corner does, which is exactly how the engine's index base
works, so no face straddles a scope — and `BlobModels` builds a node per scope:
the root under the blob's own rotation triple, one child per part under the
triple its `anim` operand names. `A_PANEL.3DI`'s plate flips edge-on and face-on every tick and
`A_FIRE3.3DI`'s two billboards take a fresh heading -- **pinned by the suite
rather than seen in a demo mission**, because neither kind is reachable from
the three weapon switches the demo missions exercise. What is visibly on
screen is the model half of a shot: weapon 2's muzzle is `A_LINE5.3DI` and
`A_CASE.3DI`, and those were drawn by nothing before this.

**And it closed [`30` §2.5](30-eng3d-ascii-formats.md)'s last open item.** That
document had left the *composition order* of a general three-angle rotation
open, "because the composition order is prototype data, not a format constant".
It is prototype data — and the opcode names its builder in a `call rel32`.
`joint_rotate_3` and `joint_place`, the two the shipped joint programs reach,
both call `E3D_init_matrix_RzRxRy` at `Eng3d.dll+0x411BF6`. The order was never
unknowable; it was one instruction away, in a binary the question did not think
to look in. Three checks pin the seven handlers' targets.

What remains a **choice**, and is written down as one in `WorldSpace`, is the
handedness of that composition carried across into Godot's column-vector
convention — the engine transforms row vectors. Every single-axis case is exact
either way, and every shipped joint animation is single-axis per part.

**The re-measured frame cost**, on the same worst case §9.1 used:

| | Sprite half | Model half |
|---|---|---|
| Pool tick, 450 live | 1 098 µs | 1 480 µs |
| Rebuild | 656 µs (450 quads) | 5 083 µs (450 nodes) |
| First build (mission load, not a frame) | — | 5 157 µs |
| Per displayed frame (tick at 20 fps, rebuild at 60) | **1 022 µs** | **5 576 µs** |
| Headroom against 16 667 µs | **16.3×** | **3.0×** |

The two are measured apart because a blob is a sprite **or** a model, never
both, so neither number is ever paid twice. The model half is five times the
sprite half and still fits three times over; §9.1's 1 028 µs is superseded for
the sprite path only and is **not** the whole-pool figure any more.

### 14.2 Footsteps are heard, and the period turned out to be a global

The slice's reasoning was right and its conclusion was one layer off. A step is
2 to 8 frames apart, `core` hands over a whole path at once, and the phase must
therefore come from the presentation — but not from `CharismaState`. It comes
from **`UnitsView`, which already owns the walk**: `start_walk` takes a period,
`_advance_walk` counts frames at the body clock, and `steps_taken()` answers
which slots put a foot down. Nothing in `units.gd` knows a wave from a volume
id; `main.gd` turns each slot into the cue its type set up. `core` is untouched.

**And reading `aStartWalkAnimationSound` properly to supply that period found
something the table had flattened.** Six of the seven sounding arms end with
`mov dword [0x004FAECC], imm32` — **one global**. The `msqueether` arm, unit
type 54, writes its wave and its volume id and leaves the period alone, so a
Squeether walks at whatever the previous walker set. And `0x004FAECC` is past
the end of `.data`'s raw bytes, in the tail the loader zero-fills, so before
anything has walked the period is **zero** and the first Squeether of a mission
gets one step and no repeat.

So the call is not a pure function of the unit type, and modelling it as one
would have quietly given type 54 a period it does not have.
`inclib/sound.WalkPeriod` is that global as state, `AudioEvents.footstep` is
its GDScript twin, and an ordered trace of nine walks is emitted into the sound
fixture and replayed by `tests/test_sound.gd`. Written up as
[`28` §5.1](28-effects-and-sound.md); five checks.

The first step fires **with** the walk animation rather than at the first period
boundary. That is a reading of a routine whose caller is not decompiled, it is
said so in `units.gd`, and the alternative would make the shortest shipped path
— one field, six frames, against periods of 2 to 8 — silent for some types.

### 14.3 A unit on a moving lift rides it

Not by the suppression §11 considered, which would have hidden a unit the
player is watching. `UnitsView.lift(slot, world_units)` holds one unit's node
away from where the world says it stands; `_carry_rider` decays that offset
from `from - to` to zero across the sequence, in step with the same
interpolation `_paint_setpiece` gives the cell's objects. The passenger is
captured at the **start** of the sequence, `drop_lifts()` puts everyone back
when the queue drains or the replay is skipped, and — like the suppression — the
offset is re-applied after a rebuild, because a rebuild recreates every node.

`roof_unit` is the one animated set piece whose unit is not a passenger: it is
the cargo, and it stays suppressed.

**A bug in the first draft, worth recording because it is the same shape as the
one §8.1 found.** `_apply_lifts` wrote `position.y` for **every** child on every
lifted frame, so any set piece anywhere on the map put a walking body back on
its start cell's floor — a walk and a script sequence do run in the same
playback. It now touches only the slots in the lift table, and
`tests/test_effects.gd` asserts it.

### 14.4 The exit leak: `_exit_tree` was too late, not powerless

The slice's diagnosis was right about where — the Ogg music path, established
by running the same build against a `--no-music` cache — and wrong about what
could be done. Reproduced outside this repository in a twenty-five-line
project: an `AudioStreamPlayer` that has played an Ogg leaks four objects at
exit if the process quits in the same frame the stream is released. Loading the
stream and never playing it leaks nothing. Playing it, releasing it and then
running a handful of frames leaks nothing. **Six process frames were enough.**

So the holder is the audio server, it lets go on its next mix, and `_exit_tree`
cannot help because by then there is no frame left to run. The fix is to stop
quitting in the same frame: `get_tree().auto_accept_quit = false`, and a close
request runs `AudioSystem.shutdown()` — release everything, then let the tree
run for `SHUTDOWN_WAIT_MS` — before `quit()`. The wait is wall-clock and twice
the measured threshold rather than a frame count tuned to one driver; it is
spent once, on the way out. `release()` stays on `_exit_tree` as the belt to
that brace.

### 14.5 The creators: measured, not closed

This is the one item that was **scaled down rather than finished**, and it is
named here rather than left to be inferred.

Transcribing the 81 creators' own placement and velocity arithmetic is a slice
of its own, and the count says why: 30 of the 81 are reachable by firing a
weapon at all, they hold 43 of the 116 constructor calls, and each is roughly a
kilobyte of x86 whose position arguments come from five service helpers that
[`28` §12.1](28-effects-and-sound.md) recorded, at the time, as **not natively
validated** — since measured, §17.1.
Transcribing them would produce trajectories that look authoritative and cannot
be checked — the failure mode this repository's rules exist to prevent.

What was done instead:

* **the reach is measured and pinned** — `creators.reachable` (30 of 81),
  `creators.reachable_calls` (43 of 116) and `creators.reachable_lifetimes`
  (27 of 43), so the size of the gap is a number rather than a paragraph;
* **the trajectories' *timing* stopped being invented.** A muzzle blob now
  crosses to what was shot at in exactly the lifetime its own call site
  passes — extracted data, alongside the kind and the class — instead of at a
  chosen constant speed. A fixed speed made short shots overshoot and long ones
  expire in mid-air. The two cases with no lifetime to divide by, an immortal
  blob and a computed one, keep the constant and say so.

The path to closing it properly is a `dbgcall` capture — fire a shot in the
live process, read the pool back, and diff the records — which is the pattern
`turn_gold.py` and `ai_gold.py` already use. That would validate the hooks and
the creators in one pass, and it is the only thing that would.

**2026-09-06: the thirteenth creator, and where a shot actually comes from.**
`aBlob_CreateTracerBullet` `0x004247C0` — the muzzle switch's **default** arm
and the creator fourteen weapons select, so the one an ordinary shot uses — is
transcribed, `inclib/blob_creators.py` `_c004247C0`. Its three constants are
read back out of the shipped executable by `blob_tables.py` (`TRACER_STEP` at
`0x004B1280`, the casing's ±128 at `0x004B1288` and `0x004B1290`, and
`TRACER_UNIT` recovered by replaying the reciprocal multiply at `0x00424A9A`,
there being no `2240` in those bytes at all), and every site is inside the
creator. What it corrected in this remake: the casing is thrown a **third of
the round's delta behind** the muzzle at the muzzle's own height — the machine
gun drops its own by `dz` and that formula had been carried across — and the
streak lives `max(|dx|, |dy|) / 2240 - 1` frames while travelling its whole
delta each of them, so a point-blank shot makes no streak at all, the
constructor dropping a record with no life.

The finding that reaches past the effect layer is **the origin**. `0x004249AF`
tests the shooter's `+0x56` — docs/42 §6's "already animating" byte, which a
fight animation sets — and where it is set `0x0042C660` writes the world
position of a *named part of the shooter's Charisma model* over all three
source coordinates: the part's own translation plus the object's, scaled by the
16 of docs/40 §5.3. The name is the creator's seventh argument and all five
call sites push the same one-character string, `"M"` (`0x004C10D8`), which 89
of the 114 shipped `.cho` models carry a part for. (Corrected below: there are
**seven** sites, not five, and one of them pushes `"MM"`; the earlier count of
"32 of 39" was of a world set's `.3DI` prototypes, which are geometry and not
the skeleton the part name lives in.) So a shot leaves the **barrel**, and
the body's axis at eye height (`0x0047AD30`) is the fallback for a body that is
not animating. The claim it replaces was **this remake's own**, written into
`SliceMain._muzzle_of`'s comment — "the creator … never touches a weapon's
position or a model's joint" — and told to the player as fact; §15.5 says only
that the origin is the placed object's position rather than the tile or the
floor, which stands. The remake reads the same part of the same model now.

What stays open is the half that was open before: none of this is **measured**.
The records are read out of the instructions, not back out of a live pool, and
closing that still wants the `dbgcall` capture above.

**2026-09-06, later: a shot is a burst.** Reported from play — the original's
own sound is a burst and the remake drew one round. `_c004247C0`'s loop is
`args[4]` rounds and its constructor's last field is `(index * args[5]) & 0xFF`,
the record's `delay`, and neither number is in any table this slice extracted:
both are pushed at the **call site**, so they belong to the weapon's arm rather
than to the creator. Two other muzzle creators have the same seven-argument
signature and the same loop, `aBlob_CreateNeedles` `0x00424250` and
`aBlob_CreateFlash` `0x00423D80`, and the set of burst sites is exactly the set
of muzzle sites whose caller cleans seven dwords.

An ordinary rifle shot is therefore **ten** tracers and ten cases leaving one
frame apart; the two starting guns' default arm pushes five; weapon 16 fires
three two frames apart; weapon 12 fires two bursts of nine, its second call
naming the part `"MM"` rather than `"M"`. All fourteen immediates and the
`mov ebx, 1` at `0x0040CC41` that supplies the other three steps are read back
from the binary by `blob_tables.py` (`weapon.muzzle_burst`, `MUZZLE_BURSTS`,
546 checks), the blob document carries `[rounds, stagger]` beside each creator
(`CONVERTER_VERSION` 0.20.0) and `BlobTriggers._fire` runs the loop. Only the
tracer's per-round scatter is transcribed, so the other two creators repeat
their records on the spot — the right count and the right timing over a spread
that is still nobody's measurement. `_muzzle_of` still knows only `"M"`, so
weapon 12's second barrel fires from the first.

**2026-09-06, third pass: the other two burst creators, and the second
barrel.** `aBlob_CreateNeedles` `0x00424250` and `aBlob_CreateFlash`
`0x00423D80` are transcribed beside the tracer, so all three seven-argument
creators are now programs (`inclib/blob_creators.py`, thirteen in all). They
share a prologue — two symbol objects, two unit heights, the joint override,
`0x0046D400`'s direction and a length that is the wider horizontal span over
the creator's own spacing minus one — and `_burst_prologue` is that
prologue once. What differs:

* the **spacing and the step are one number** in each, as they are for the
  tracer: 1600 for the flash (`0x004B1270`, divide at `0x00424058`), 2400 for
  the needles (`0x004B1278`, the cell `BEAM_STEP` names, divide at
  `0x00424540`). All four are read back out of the shipped executable;
* the flash's round is **one class-2 record**, row 6, column `aRandom2(0, 7)`,
  kind 69, carrying the round's delta as its velocity;
* the needle's round is **nine**: the delta is divided by eight and laid down
  as an accumulator, so the nine sit at one eighth, two eighths … nine
  eighths of it, growing (`aux` is `10 - k`), and the **last** is kind 73
  where the other eight are 74;
* both take a **different branch point-blank**. A span inside one spacing
  writes the length back to zero and sets the *arrived* flag rather than
  clearing it, and then the flash runs `rounds` zoom bobs jittered
  `aRandom2(-1600, 3200)` **around the target** while the needles run one zoom
  bob and `0x00428F70`'s twenty plasma sparks there. Their round loops still
  run and still draw; every record is dropped by the constructor for a zero
  life.

The remake mirrors all three (`game/fx/blob_triggers.gd`: `BURST_SHAPES` is
the step, the spacing and the two scatter spans per creator, and `_needles`
is the nine-record round). That fixed a defect nothing had noticed: the
needles' single constructor call computes its kind, so the document carries
`null` there and `_create` refused it — **weapon 16 made no muzzle effect at
all** in the remake until its creator was transcribed. The two point-blank
branches are mirrored too, and so is the tracer's per-round zoom bob: all
three are **nested creators**, whose constructor calls belong to
`0x00423720` and `0x00428F70` rather than to the muzzle creator, so the
muzzle table cannot carry them. `BlobTriggers` hands them back as requests
(`take_programs`) and the mission host runs them through the same
`BlobPrograms` seam a set piece uses, on the one generator stream. Without
that a point-blank shot from weapon 16 or 29 showed **nothing at all**: the
round loop's records are dropped for a zero life, and the branch that
replaces them was not there.

The **joint** is the second finding of this pass and it corrects the
2026-09-06 entry above, which said "all five call sites push the same
one-character string". They do not: **one of the tracer's own five**,
`0x0040D230` — weapon 12's second call — pushes `"MM"`. (Counting all three
burst creators there are seven such sites; the other two push `"M"`.) Exactly one shipped
model carries a part by that name (`P0_020.cho`) against 89 of 114 for `"M"`,
so weapon 12 fires its two bursts from two barrels. `tables/blobs.json`
carries the name per call (`weapon_muzzle_joint`, `CONVERTER_VERSION`
0.21.0), `BlobTriggers` resolves it per creator, and `SliceMain._muzzle_of`
now takes the **shooter's slot** rather than looking the cell up in the
end-of-turn world, where a reinforcement may already have recycled it.

**What is still not measured, and why.** The three burst creators were the
one part of the pool a capture had never reached, and the reason was in
`blob_gold.py` rather than in Wine: `argument_vector` fills every argument
past the fourth with **zero**, and the fifth is the round count — so all
three ran an empty loop, left no records and drew nothing, which is why they
sit in `DRAW_SITES_NOT_TAKEN`. A `burst_*` phase that calls each with the
numbers its own arm pushes is written and wired
(`BURST_ARGS`, `BURST_READ_RECORDS` at 44 slots, `creator_plan`'s record
window). It has not run: on 2026-09-06 this host reached the anchor **0 times
out of 10** with `--probe-startup`, using the `state` plan that had landed
before, so `Incubation.exe` exits before the breakpoint for reasons that are
`docs/91` §1's and not the plan's. `NATIVE_FAULTS` and `BURST_UNCAPTURED`
pin exactly that, and `native.creator_program_records` counts the three as a
named gap rather than reporting a pass it has not earned. Seven of
`blob_creators.py`'s constants moved into
`CREATOR_CONSTANTS_UNDISCRIMINATED` for the same reason.

**A process note.** The 2026-09-06 entry above reported "all checks green"
without running `blob_gold.py --check`, which is outside the always-run block
and which the tracer's transcription had already broken — it had been
reporting the tracer as *not captured* since that pass. The rule the block
exists for applies to the tools outside it too: a transcription added to
`PROGRAMS` is a claim `blob_gold` is the judge of.

**2026-09-11/12: the weapon creators, inside the remake and measured.**
Everything above is about the **Python** transcriptions. In `godot/` the
thirty were still built from their constructor table -- one record per `call`,
with a trajectory of [`BlobTriggers._velocity`](../godot/game/fx/blob_triggers.gd)'s
own over the record's own lifetime -- so a creator whose loop lays sixty
records came out as **one sprite**. The Pyr'Coo's weapon 26 is the worst case
of it and is what was reported from play: its muzzle `aBlob_CreateSmokeTrail`
`0x00425810` holds a single constructor call at `0x00425C5D`, so the whole
shot was one class-2 kind-46 sprite with an eight-tick line from the shooter's
eye height down to the target's floor -- a weak puff diving into the ground,
which is exactly what a player sees. Its impact
`aBlob_CreateSporeExplosion` `0x00429F40` was the same defect again, one
sprite where the engine makes twenty-seven.

**Thirteen of the thirty were transcribed in GDScript on 2026-09-11** and
every one of them is diffed against the engine's own pool; four more followed
on the 12th, and the dated block below says which of those four a capture
judges. They live in
`godot/game/fx/blob_programs.gd` beside the death and set-piece programs, and
`BlobTriggers.WEAPON_PROGRAMS` is both the routing table and the list of what
is measured -- an entry is added only once `test_blob_native.gd`'s
`weapon_programs` phase replays it against `blob_gold.py`'s capture. The seam
is deliberately **not** the nested-creator one (`_ask_tile` →
`spawn_program`): a muzzle's records are what `BlobTriggers.in_flight` waits
on, so a program is run synchronously with the pool's own generator handed
over and handed back, and its records go through `_place` like every other
record the class makes. Three of the thirteen (`0x004227C0`, `0x00429A80`,
`0x0042A9D0`) were already in `BlobPrograms` and had simply never been reached
from a weapon switch; eight were ported from `inclib/blob_creators.py`; and
two are new transcriptions, `0x00429F40` and `0x00420A50`.

What the switch tables say the thirteen cover: **weapons 4, 8, 9, 10, 13, 14,
17, 22, 23, 25, 26, 36, 37, 42, 43, 45, 46** in one end or the other, beside
the four burst/spore creators `BlobTriggers` already transcribed for weapons
2, 3, 5, 6, 12, 16, 18, 19, 24, 25, 28, 29, 33, 34, 35, 38, 39, 41 and the two
starting guns. **Twelve creators were still on the constructor-table arm** --
`0x004228F0`, `0x00425400`, `0x00425CA0`, `0x00426070`, `0x00426B70`,
`0x00427C80`, `0x00428200`, `0x00428570`, `0x004294E0`, `0x004295D0`,
`0x00429C30` and `0x0042ACF0`.

**2026-09-12: four more, and the reason two of them looked like refusals was
wrong.** Every arm of both weapon switches was disassembled and its pushes
read right to left -- a static reading that needed no Wine. Two registers the
**dispatcher** sets carry into every muzzle arm and are the source of most of
it: `0x0040CC3C` is `xor edi, edi` and `0x0040CC41` is `mov ebx, 1`, four
instructions ahead of the jump at `0x0040CC5F`. So an arm that pushes a bare
`ebx` past the four coordinates is pushing **1** and one that pushes `edi` is
pushing 0 -- neither is a tile number, which is what `argument_vector` had
been filling those slots with. `blob_gold.SWITCH_ARGS` now carries the real
tail for **eight** creators: `0x004228F0` and `0x00429C30` take a literal 0,
`0x00425CA0`, `0x00428200` and `0x00428570` the dispatcher's 1, `0x00425400`
both registers, `0x00427C80` a literal 4 at weapon 7's arm and 10 at weapon 40's, and `0x00426070`
the pair `(0xA, 0xFF)` weapon 44's arm pushes. `0x00425400` and `0x00427C80`
had been called "creators that refused the captured tile"; they were handed a
zero where the arm pushes a round count and a type, and the zero is the
faithful nothing `CLAUDE.md` warns about.

Four of the twelve are transcribed and routed now. Three are diffed field for
field against the capture on the first run -- `aBlob_SparkingPlug`
`0x0042ACF0` (30 records, 90 draws), `aBlob_CreatePlasmaBallImpact`
`0x004294E0` (40, 120) and `aBlob_CreateExplosion2` `0x004295D0` (15, 90) --
each with the arguments its own arm pushes, which the capture already held.
The fourth, `aBlob_CreateSpidyMines` `0x00426B70`, is transcribed but
**replayed by nothing**: `0x00420950` refuses a class-0 record whose model
name the `models` phase cannot resolve, and that phase predates
`A_MINE1/2.3DI` joining `CREATOR_MODELS`.
`blob_gold.PROGRAM_MODELS_UNCAPTURED`, `MODEL_NAMES_UNCAPTURED` and
`test_blob_native.WEAPON_PROGRAMS_UNCAPTURED` are what say so.

It found one thing no other creator had shown, and the first reading of it
was **wrong**. What the capture shows is that the round leaves 160 units
higher than the symbol object plus the unit's height, and the standard object
standing on that tile happens to be exactly 160 higher than the symbol one
(§22.2), so "the shooter comes from the standard table" fitted every record.
It is not a table at all: both creators do

```
call 0x0047AD30          ; the unit's height
add  eax, 0xA0           ; 0x00425D9A, 0x00426C6A
add  ecx, eax            ; over the *symbol* object's own z
```

and the standard object each of them reads at `0x00404BD0` is only for the
joint's part list at `+0x45`. A sum of 160 cannot tell 0 + 160 from 160 + 0;
the bytes can, and **exactly two `call 0x0047AD30` sites in the whole of
`.text` are followed by `add eax, 0xA0`** -- these two.
`blob_tables.creators.lift_sites` is that count as a check, and
`PROJECTILE_LIFT` is the constant, read back out of the shipped executable at
both sites.

So the remake is not approximating anything here: `Inputs.source_std`,
`has_source_std`, `throw_point()`'s fallback and `blob_gold._std_object` are
**gone**, and `throw_point()` is the placed object plus the height plus 160.
The 160-unit divergence this report claimed as known and accepted did not
exist as described and does not exist now.

**Eight creators were still on the constructor-table arm**: `0x004228F0`,
`0x00425400`, `0x00425CA0`, `0x00426070`, `0x00427C80`, `0x00428200`,
`0x00428570` and `0x00429C30`. All eight have the right arguments in
`SWITCH_ARGS` now and all eight were asked for again the same day; **Wine
reached the anchor 0 times in 80 attempts**, the rate `docs/91` §1 records at
its bad end, and the `models` phase lost its ten as well.

### 14.5.1 The eight, transcribed without a capture (2026-09-12)

All eight are now transcribed, and **six of them are diffed against the engine
anyway** -- which is the finding, because the phases in hand were written off
as worthless the same day. `PROGRAM_ARGS_STALE` said "the records these hold
are a fall-through arm's". For six of the eight that was a guess about the
tail rather than a reading of the body:

| Creator | Arity | What the corrected tail turned out to be |
|---|---|---|
| `0x004228F0` `aBlob_CreateFireWheel` | 3 | dead -- the frame loads `[esp+4]` and `[esp+8]` and no third slot |
| `0x00429C30` (no trace name) | 3 | dead, the same way |
| `0x00425CA0` `aBlob_CreateGrenade` | 5 | dead -- `[esp+0x5C]` is read nowhere |
| `0x00426070` `aBlob_CreateGrenade` | 6 | arg5 dead; the **sixth** is the type |
| `0x00428200` `aBlob_CreateLaser` | 5 | dead, and its slot reused as scratch for the flight length |
| `0x00428570` `aBlob_CreateLaser` | 5 | dead |
| `0x00425400` `aBlob_CreateTracerBullet` | 6 | **live**: a round count and a stagger |
| `0x00427C80` `aBlob_CreateFlameStream` | 5 | **live**: a ring count and a shape switch |

A creator whose tail is dead was called correctly all along, so its phase is
the engine's answer to the call its arm makes. Four of those six replay field
for field -- `0x004228F0`, `0x00429C30`, `0x00428200` and `0x00428570` -- and
two are held back only by a model name the `models` phase predates
(`A_MINE1.3DI`, `A_LASER.3DI`). `PROGRAM_ARGS_STALE` is down to the two whose
tail is live, which is exactly the pair that had no records in the capture at
all.

The seven-dot laser's diff earned its keep on the first run:
`0x0046D400` sits **inside** `0x00428570`'s loop at `0x00428883`, where
`0x00428200`'s single call sits in front of its own, so its dots do not share
one velocity. Read as one they put the third dot's `vz` four units out and the
fifth's `z` two. Nothing static would have caught that.

**What stands behind a transcription with no capture** is new and needs no
Wine: `blob_tables.creators.shape_matches_call_sites` runs every program on
synthetic inputs and requires each record it builds to match a constructor
call site -- class, kind, literal lifetime, model and the three sprite
parameters -- with `shape_reaches_call_sites` requiring the converse, that
every call site inside a transcribed creator is reached. 889 records over 41
sites. A fifteen-push argument list reversed one slot out lands a kind where a
lifetime belongs, and that is where it shows; a mutation of one lifetime
immediate fails both halves.

It also found a **cache hole**. `0x00426070` copies `A_LASER.3DI` into a stack
buffer before it calls the constructor, exactly as `aBlob_CreateTubeSmoke`
does with `A_EXPL03/04`, so its one call site carries no model and no cache
built from the call sites alone carried the name -- while all nine world sets
ship it. Every one of the six records a weapon-11 or weapon-44 shot makes
would have been refused. `BLOB_MODEL_MOV_SITES` carries it now and
`CONVERTER_VERSION` is 0.38.0.

And it found a **defect in the routing**, not in a creator: `0x00426070`
stores the target cell's unit id as its record's `aux`, kind 26 is arm 25 --
the seeker of `docs/28` §7.7.1 -- and `_run_weapon_program` had never filled
`Inputs.target_unit`, so every shot from the multi-target destroyer would have
homed on slot 0. `effects.triggers.grenade_arc_aux_is_the_target_slot` is the
check.

**One transcription is deliberately not the creator.**
`aBlob_CreateFlameStream` opens each ring by reading the three doubles its
inner loop wrote last and scaling them by `-960`; on the *first* ring the
inner loop has not run and those slots are the frame's own uninitialised
locals. Zero stands in, and the argument for it is in
`blob_creators.FLAME_RING0_DIVERGENCE`: the point-blank arm at `0x00428093`
zeroes exactly those three doubles, so zero is read out of the routine rather
than chosen; that stack residue read as an IEEE double is mostly denormal or
NaN and `_ftol` answers 0 for both is a second and **unmeasured** reason; and
ring 0's first record in a capture is what would settle it.
`PROGRAM_DIVERGENT` and `WEAPON_PROGRAMS_DIVERGENT` are the pin.

**Three corrections to this document's own §15.5/§16 material fell out of
it.**

* `aBlob_CreateSmokeTrail` lays a **ring of six every `0x3C0` along the line
  of fire**, `trunc((max(|dx|, |dy|) - 0xC80) / 0x3C0) + 1` rings plus the one
  at the muzzle, each record at its ring's point *plus* its own three
  `aRandom2(-0x140, 0x280)` draws -- so the same numbers are both a
  displacement and a velocity -- with `delay` the ring index over four. It
  writes **1** over the *arrived* flag at `0x00425AD6`, unconditionally and
  ahead of the loop, so a smoke trail is not something the shot stage waits
  on; the remake had been waiting out the lone sprite's eight ticks.
* `aBlob_CreateSporeExplosion`'s type is the **fourth** argument, not the
  third: the prologue's `sub esp, 0x18` plus four pushes puts the return
  address at `[esp+0x28]` and the read is at `[esp+0x38]`. Weapon 26's arm
  `0x0040D55E` pushes 0, which is nine rings of three; weapons 23 and 25 push
  1, which is three. `rot_y` is a flag rather than a draw, off below the fifth
  ring and 4 from it up; `aux` is a draw with twice the ring index added
  **inside** the conversion; `delay` is the ring index.
* **Ten creators resolve the muzzle part themselves.** `0x0042C660` writes the
  world position of a named part of the shooter's Charisma model over the
  three source coordinates, and §14.5 above had it that the name is the
  creator's *seventh argument* -- which is true of the three burst creators
  and of nothing else. All thirteen `call 0x0042C660` sites in `.text` were
  swept: `0x00424D20`, `0x00425400`, `0x00425810`, `0x00425CA0`, `0x004264A0`,
  `0x00426B70`, `0x00426F90`, `0x00427C80`, `0x00428200` and `0x00428570`
  push `"M"` (`0x004C10D8`) inside their own bodies, so the document's
  `weapon_muzzle_joint` is empty for them and every one of those effects had
  been leaving the body axis at eye height instead of the barrel.
  `BlobTriggers.CREATOR_JOINTS` is that sweep, and `PC_006` -- the Pyr'Coo's
  model, and the three-level selector's answer for type 56 at every weapon and
  player -- does carry a part named `M`, so this is a real move for the unit
  the defect was reported on.

**Wine reached the anchor on this host again, and the capture is richer for
it.** `docs/91` §1 had recorded 0 of 10; `--probe-startup 3` answered 1 of 3
on 2026-09-11, and every plan landed. Five phases that had never been taken
now hold records: the shock wave's re-take with the type its callers push
(`SWITCH_ARGS`, which had been handing `0x00422B80` a tile number), all three
`burst_*` phases, and the spore explosion's nine rings. `blob_gold.py`'s
`NATIVE_FAULTS`, `BURST_UNCAPTURED` and `PROGRAM_ARGS_STALE` are **all empty**
for the first time, and the pins moved with them: 25 of 30 creators produce
222 records, 15 advance the second generator, `SHOCKWAVE_RADIUS` and the
stinger ring's four constants joined `CREATOR_CONSTANTS_DISCRIMINATED`, and
**arm 13 moved out of the poked fifty into the native twenty-five** -- it had
been poked only because nothing a weapon selects appeared to fill kind 13,
which was the corrected argument's doing and not the engine's. One thing the
re-take exposed at once: `A_EXPL05.3DI` was missing from `CREATOR_MODELS`, so
the sixty records the engine makes were all refused on the Python side, a
class-0 spawn whose name the `models` phase does not carry being
unconstructable (docs/28 §7.5).

**Three more model sets reach the cache the same way, and one of them is named
by no call site at all.** A creator's model is normally the string its one
constructor call pushes, and that is what `CREATOR_MODELS` reads. Two families
break it, so both were added to every world set's geometry by hand:

* the three models an **update arm** swaps in later, which no creator's call
  site names because the swap happens a tick or more after construction
  (`CONVERTER_VERSION` 0.33.0);
* `A_EXPL03.3DI` and `A_EXPL04.3DI`, because `aBlob_CreateTubeSmoke`
  `0x00423C20` picks one of the two **by index** and copies the chosen name
  into a stack buffer — its single constructor call site therefore carries no
  model at all, and the flash an ignited ground fire leaves ([`42` §9.1](42-mission-presentation.md))
  would have been half-refused (`CONVERTER_VERSION` 0.34.0).

The general rule the two share: **a model reached through an index or through a
later swap is invisible to a reading of constructor arguments.** A creator whose
model the cache does not carry is refused by `0x00420950` and compared by
nothing, which is what `PROGRAM_MODELS_UNCAPTURED` and `MODEL_NAMES_UNCAPTURED`
pin in `blob_gold.py`.

**What the seam had to learn to be worth the transcriptions.** A creator's
two ends are not one point each, and the first cut of the runner passed one.

* **The object and the standing unit's height stay apart.** The engine reads
  the placed object through `aGetSymbolObjectPtr` and the height through
  `0x0047AD30`, and the creators read the two differently: the span a beam's
  length is counted in is over the two *objects* (`0x00425A8A` takes
  `[edi+0x10]`/`[ecx+0x10]`), `aBlob_CreateLineFire`, the spore explosion and
  the stinger ring open at the object's own z with no height at all, and only
  the ones that go through `Inputs.source_point()` want the sum.
  `SliceMain._muzzle_of` had been handing over the sum alone, so those three
  started at eye height rather than on the floor and the blizzard shot aimed
  some 2400 units high. `_object_of` is the other half and `_fire` resolves
  both.
* **The joint replaces the source, for every creator that asks for one.**
  `0x00425810` loads the object's three coordinates plus the height into
  `[esp+0x1C]`/`[esp+0x18]`/`[esp+0x14]` at `0x00425996`, then hands those
  three addresses to `0x0042C660` at `0x00425A2E`; everything it reads as its
  source afterwards is the part. Four of the ten `CREATOR_JOINTS` creators are
  `WEAPON_PROGRAMS` entries -- `0x00424D20`, `0x00425810`, `0x004264A0`,
  `0x00426F90` -- so `Inputs.source_point()` answers `source_joint` where one
  was resolved. The **span** is the exception and stays on the raw objects:
  `0x00425A8A` reads `[edi+0x10]` and `[ecx+0x10]`, which are two fresh
  `aGetSymbolObjectPtr` results (`0x0042587C` and `0x00425A56`) rather than
  the overwritten slots. Nothing diffs the joint against the engine -- every
  capture was taken with nothing animating, which is `0x0042C660`'s own
  fallback -- so it is asserted in `test_effects.gd` and confirmed in play.
* **A tile-shaped creator reads the cell, not the arguments.**
  `aBlob_CreateLandingDust` `0x004227C0` and `aBlob_CreateFireExplosion`
  `0x00429A80` open with `Inputs.object(x, y)`, which answers `Vector3i.ZERO`
  for a tile the map does not carry -- so weapons 42 and 46's impact and
  weapons 8, 17, 36 and 37's fire explosion laid their whole effect at the
  **world origin** while every suite stayed green. Nothing could see it: the
  replay check builds its own `tiles`, and `test_effects` counts records
  without looking at where they are. `test_blob_native.gd`'s
  `impact_creators.*` is the check that bites -- weapon 42's whole impact
  driven through `BlobTriggers.impact` against the `0x004227C0` phase -- and
  it was written by breaking the fill first: `0.x: 0 is not 60800`.

**Confirmed in the running game**, which is what the report was about.
*Instant Action* → *Spaceport* (`_S_004`, ten Pyr'Coo), a marine deployed at
(14, 18) two cells from one of them, and the computer's turn read one frame at
a time: **72 kind-46 records in a frame** where the pool used to hold one per
shot, their ring points marching along the line of fire from the shooter to
the marine and descending with the terrain, and **27 kind-50 records** at the
impact. Reading the pool during the computer's turn needs a *single* batch --
`hud event 10` followed by `wait`/`blobs` pairs -- because `blobs` is a POST
and one batch runs at a time.

### 14.5.2 The capture that closed them, and the arms that call twice (2026-09-12, afternoon)

§14.5.1 ended on five creators nothing had ever compared against the engine
and one deliberate divergence. All six are closed, and the instrument was the
one §14.5.1 said had answered 0 of 80 that morning: **Wine**.

**The intermittency, measured twice in one day and in both directions.**
`--probe-startup 3` answered 0 of 3 at the start of the afternoon, on the same
host with nothing changed but the hour. The capture was started anyway, because
`docs/91` §1 says the unit of loss is the plan and phases merge: `blob_models`
reached the anchor on attempt 1, and the eight creators `SWITCH_ARGS` had
corrected landed in one to six tries each, with one (`0x00428570`) losing all
ten and landing on a second invocation. **Do not read a probe as a verdict on
the run.**

**A stale failure entry, which is the direction of error a pin exists to
prevent.** `NATIVE_FAULTS` reported `models` as unlanded while that plan's own
answer sat in the same document. Five additive phases -- `models`, `hooks`,
`units`, `origins`, `symbols` -- recorded a failure and never cleared it on the
next success, unlike every per-creator phase, which pops its name. Fixed in
`capture`; all five now pop.

**What the diff found: one real error, in the one creator that had been
transcribed with a divergence.** `aBlob_CreateFlameStream` `0x00427C80`
reproduced the engine's twelve records in every field but one. Eleven of the
twelve disagreed on `aux`, the sprite's half-size, and the differences were
`0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4` -- `ceil(n / 3)`. The bias on the size
draw is not `ring / 3`:

```
0x00427F25  mov byte [esp + 0x30], 2      ; ahead of both loops
...
0x004280DC  call 0x4638E0                 ; aRandom2(0, 5)
0x004280E1  mov ecx, [esp + 0x3c]         ; the counter
0x004280E5  mov eax, 0x55555556           ; / 3
0x004280EA  and ecx, 0xff                 ; **a byte**
0x00428100  fild dword [esp + 0x40]
0x00428104  faddp st(1)                   ; added before the truncation
0x00428106  call 0x4AE7B6                 ; _ftol
...
0x00428174  mov dl, byte [esp + 0x6c]     ; the same slot, post-frame
0x00428181  inc dl                        ; once per **record**
0x00428183  mov byte [esp + 0x30], dl
```

A byte counter that opens at **two** and steps once per record, so the bias
steps inside a ring as much as between rings. Read as the ring index it was
right for the call's first record and wrong for every other one -- a shape that
fits one sample and no more, which is exactly what a capture is for.

**And ring 0's uninitialised read came back zero.** The transcription's
stand-in matched the engine field for field, which is a measurement of *the
anchor's* stack and not of the shipped path's: a plan calls the creator from
`dbgcall`'s breakpoint and a shot calls it from `aPlayFightAnimation`, and the
three doubles at `[esp+0x4C]`, `[esp+0x54]` and `[esp+0x5C]` hold whatever each
caller left. `PROGRAM_DIVERGENT` is empty and
`blob_creators.FLAME_RING0_DIVERGENCE` now says exactly that -- with one
correction to its own argument: `_ftol` answers `0x80000000` for a NaN, not 0,
so the "denormal or NaN, both truncate to zero" half was wrong. The zero rests
on the point-blank arm at `0x00428093` writing those same three slots, and on
the residue at that depth being small integers and pointers, which are tiny as
doubles.

**The rest closed without a correction.** `0x00425400` (weapon 23's spray) and
the three the model re-take unblocked -- `0x00425CA0`, `0x00426070`,
`0x00426B70` -- all reproduce the engine's records as transcribed. Twenty-one
program constants left `CREATOR_CONSTANTS_UNDISCRIMINATED` at once, and not one
of them to a better instrument: nine were waiting on a model handle and twelve
on an argument. Arms **31** and **47** moved from `POKED_ARMS` to
`NATIVE_ARMS`, so kind 32 and kind 49 are now stepped from a creator's own
records rather than from a donor's.

Every creator either weapon switch routes is now replayed against the engine.
`WEAPON_PROGRAMS_UNCAPTURED`, `WEAPON_PROGRAMS_STATIC` and
`WEAPON_PROGRAMS_DIVERGENT` are all empty and stay in the file, because a
thinner capture has to put a name back rather than quietly compare less.

#### The arms that call their creator more than once

The switch tables say which arm a weapon takes and which creators the arm
calls. They cannot say **how many times control reaches a call**, and for five
weapons the answer is not one. `aPlayFightAnimation` runs at `0x0046C186` --
after `aBuildTargetPattern` marked the cells (`0x0046B6AC`) and after the
resolver rewrote those marks and killed what it killed -- and nothing between
the two resets `cell[+0x00]`, so four of these arms simply **walk the control
map and read the shot's own outcome back**:

| Weapon | Arm | Creator | Band | Unit on the cell? | Per call |
|---|---|---|---|---|---|
| 9 muzzle | `0x0040CF65` | `aBlob_EnergyCannon` `0x004264A0` | `0x50`–`0x5E` | required | `k / 3` as the 5th argument |
| 9 impact | `0x0040D590` | `aBlob_CreatePlasmaExplosion2` `0x0042AF10` | `0x50`–`0x5E` | required | the cell |
| 11 muzzle | `0x0040D077` | `aBlob_CreateGrenade` `0x00426070` | `0x50`–`0x5E` | required | `k` as the 6th argument -- **the arc** |
| 41 muzzle | `0x0040D269` | `aBlob_CreateTracerBullet` `0x004247C0` | `0x5A`–`0x5D` | not tested | `(9, 1, "M")` |
| 44 muzzle | `0x0040D0FD` | `aBlob_CreateGrenade` `0x00426070` | — | — | five rounds, `mov [esp+0x14], 5` |

`k` is the running count of cells the walk has **matched**, in control-map
order -- `y * width + x`, which is `0x0042F730`'s index and the remake's
`MapState.index_of`. `aBlob_CreateGrenade` reads that sixth argument as the arc:
0 to 5 pick one of the six fixed vectors at `0x00426484`, `0xFF` is the
proximity round that draws its own scatter, and 6 upwards fall through to the
wider scatter -- so a seventh target is thrown at, not dropped. That is the
*Multi-target Destroyer* doing what its name says, and the remake fired **one**
round on the first arc.

The unit test matters and is not decoration, but a `0x5D` cell still passes it.
`aPlayFightAnimation` runs at `0x0046C186`; the killed-cell removal sweep starts
only at `0x0046C1CF` and reaches `aRemoveUnitElement` at `0x0046C1F9`. The bomb
resolver has the same order: animation at `0x004705F5`, removal from
`0x00470618`. Weapons 9 and 11 therefore fire at every marked cell that held a
unit, including a killed target; weapon 41 takes the band without the test.

`blob_tables.MULTI_TARGET_ARMS` decodes all five out of the shipped executable
-- the band from the two `cmp al, imm8`, the unit test from the
`cmp word [edi+7]`, the walk from the two accessor calls and the `add r32,
0x17`, the literal count from the `mov`/`dec`/`jne` -- and requires each arm to
be the one its weapon's switch entry names. The cache carries the result as
`weapon_multi_target` and `BlobTriggers._fire` walks it, filtering the shot's
own outcome list by band and unit test. The cell list is `core`'s, out of
`AttackResult.outcomes`, sorted into control-map order: the picture never
recomputes a pattern.

**Two things this does not close.** The five weapons are the five arms; nothing
here has been seen in the running game this pass. And an empty pattern makes
nothing, which is the engine's answer and also what every caller with no attack
result behind it now gets -- a set piece that fires weapon 11 would show no
grenade at all. *Both are taken up in §14.5.3: two of the five arms — weapon
11's and weapon 41's — were fired as shots inside the engine, alongside weapon
7, whose arm is not one of the five, and the empty-pattern case turns out to
have no engine counterpart at all.*

### 14.5.3 The shipped call site, and six stale tick phases (2026-09-12, evening)

§14.5.2 closed every creator the two weapon switches route to, and left four
things named. Three of them are closed here and the fourth is narrower.

**Six tick phases were answering a call the tools no longer make.** The
`SWITCH_ARGS` tail — the literals a muzzle arm pushes where `argument_vector`
had been putting a tile number — postdates the first capture, and nothing
re-took a *tick* phase when its creator's arguments were corrected. Comparing
each stored `args` against the vector this run would pass finds six:
`ticks_0x004228F0`, `arms_0x00425CA0`, `arms_0x00426070`, `arms_0x00428200`,
`ticks_0x00428570` and `ticks_0x00429C30`. `capture` now re-takes exactly
those, the same predicate `state` and `models` already used, and only a
success assigns — a re-take that does not land leaves the phase in hand.

Two of the six came back **identical** — `arms_0x00425CA0` and
`ticks_0x00428570` — which is the result `PROGRAM_ARGS_STALE` produced for the
creators and for the same reason: a corrected tail that the body never loads is
not a lost phase. Four changed, and one of them is the one that mattered. `aBlob_CreateGrenade` `0x00426070`
was re-taken with weapon 44's `0xFF`, so its pool holds **kind 27** — the
proximity round — while its `arms_` phase still held the kind-26 records the
old tile number made. That is why arm 26 was reachable and unstepped while arm
25 was stepped and no longer reachable. With the tick phase re-taken, arm 26
steps from a creator's own records, `TICK_ARMS_SEEN` and the reachable set are
**the same twenty-seven**, and arm 25 moves to `POKED_ARMS`, where the probe
family reaches it. `tests/fixtures/blob/cases_blob.json` had never been
re-emitted after arms 31 and 47 moved either, so the Godot suite was still
asserting 25 and 49; it now carries 27 and 47.

**The flame stream's first ring was measured in the frame that matters.**
`0x00427C80` opens each ring by reading three doubles at `[esp+0x4C]`,
`[esp+0x54]` and `[esp+0x5C]`; on ring 0 the inner loop has not run and those
are the frame's own uninitialised locals. §14.5.2 reported the engine agreeing
with a stand-in of zero — but a plan calls the creator from `dbgcall`'s anchor,
and the shipped path calls it from `aPlayFightAnimation`. Arithmetic on the
prologue puts the three slots at the caller's `esp - 0x48`, `- 0x40` and
`- 0x38`, which is `S - 0x5C` to `S - 0x44` in the animation's own frame — and
the last thing to write there on the weapon-7 path is the sound-buffer chain
under `0x00436B60`, entered from `0x004176C0` at `0x0040CC15`. Residue, not a
constant of the creator.

`blob_gold.py` has a `fight_` phase now, and it fires a **real shot**:

```
--poke 0x40cc38:8b442444=>6a075890     ; the muzzle switch's weapon read
--poke 0x41e3d0:5657=>c390             ; aBlobsTick, stubbed to ret
aSetSaveMode(0) / aLoadGame(6) / aResetBlobs()
aAttackUnit(19, 6, 18, 4, 0)
aGetUnitMapElementPtr(0) --read [pool]:1056
```

`aAttackUnit` builds the target pattern, resolves the shot and calls
`aPlayFightAnimation` at `0x0046C186`, which dispatches the muzzle switch and
reaches `0x0040D014`. Neither poke is in the creator's way. The first rewrites
`mov eax, [esp+0x44]` — the switch's own read of the weapon id — to
`push imm8 / pop eax / nop`, four bytes for four, so everything before the
switch runs unchanged and the attacker keeps its own weapon everywhere else.
The second matters more than it looks: the animation pumps frames and a flame
record lives two ticks, so **without** it the pool is empty when `aAttackUnit`
returns. That was measured before it was fixed — zero records with `aRandom2`
advanced by 160 draws, far more than the creator's forty, which is what said
the empty pool was a sweep and not a refusal. The 160 counts nothing in
particular: the stubbed run drew 177, *more* rather than fewer, and the impact
arms draw from the same generator. The records are what prove the creator ran.

All twelve records the read window covers reproduce the program field for
field, ring 0's five included. Mutating the stand-in to `(0.01, 0, 0)` fails
`fight.records` on twenty-three fields, so the check is the claim and not a
restatement of it. **The three doubles are zero on the shipped path.** What
stays open is narrower and stays written down: the residue is a history, so the
zero is this attacker's, this weapon's and this branch of the sound code's
answer — the `0x0040CBF2` branch that skips the sound buffer leaves a different
routine's locals at that depth.

Two more weapons went through the same phase, which is the first time any of
§8.1.3's walking arms has been run *as a shot* rather than decoded:

| Phase | Arm | Creator | Records | Draws | What it adds |
|---|---|---|---|---|---|
| `fight_07` | `0x0040D014` | `0x00427C80` | 12 | 40 | ring 0 in `aPlayFightAnimation`'s frame |
| `fight_11` | `0x0040D077` | `0x00426070` | 6 | 0 | the walk's first cell, arc 0 |
| `fight_41` | `0x0040D269` | `0x004247C0` | 12 | 36 | **nine** rounds, the count the arm pushes |

`fight_41` is the useful correction: `BURST_ARGS` had taken the tracer bullet
at ten rounds, which is the *default* arm's literal at `0x0040D43A`; weapon
41's own arm pushes `9, 1, 0x4C10D8`, and the burst had never been diffed at
that count. It is now.

What the save cannot show is a band with two cells in it. Each walk ran
**once** — six grenade records is one call of `0x00426070`, thirty-six draws is
one call of `0x004247C0` at nine rounds — so the arc argument was zero
throughout. *Why* the band held one cell is not measured: the poke redirects
the muzzle switch and nothing ahead of it, so `aBuildTargetPattern` and the
resolver ran for the attacker's own weapon and the band these arms walked is
that weapon's pattern. And the shot is point-blank besides, which zeroes the
arc's offset and makes all seven arcs identical. `docs/28` §12 item 2 carries
what would discriminate.

**And a trigger handed no cell list should make nothing.** The remake's
`BlobTriggers._fire` returns zero when the pattern is empty, and until now the
justification was that the engine's walk over an empty band makes nothing
either — true but beside the point, because it says nothing about whether such
a caller exists. It does not. `aPlayFightAnimation` has exactly two call sites,
`0x0046C186` and `0x004705F5`, and both sit in a routine that has already
called `aBuildTargetPattern` (`0x0046B6AC`, `0x00470318`). The band is cleared
by `aClearTargetPattern` `0x00431070` — walk the map, write `1` over every
state byte in `0x50`–`0x5E` — whose **only** caller is `aBuildTargetPattern`'s
own first instruction at `0x0046AA17`. So the wipe is at the start of the next
build, never after an animation: no shipped path dispatches a walking arm over
an empty band, and none over a stale one. Three new checks in `blob_tables.py`
pin it, and all three were mutation-tested.

### 14.5.4 The weapon in the unit record (2026-09-12, night)

§14.5.3's phase poked the muzzle switch's own read of the weapon id, which
reaches a muzzle arm without disturbing anything ahead of it and is exactly
the wrong instrument for the four questions it left. Everything before the
switch — `aBuildTargetPattern`, the resolver, the sound, and the *impact*
switch — still ran for the attacker's own weapon, so a walking arm read a band
some other weapon had marked.

`unit[+0x3F]` is the current weapon id ([`21` §11](21-info-lcl-schema.md)). A
one-byte `memcpy` into the attacker's own record before the shot makes the
whole attack that weapon's, and that is what the `shot_` phases do:

```
--poke 0x41e3d0:5657=>c390          ; aBlobsTick -> ret
u = aGetUnitMapElementPtr(0)
memcpy($u+0x3f, &wp, 1) --read $u+0x3f:1
end = aResetBlobs()     --read <aRandom2 seed>
hit = aAttackUnit(19, 6, tx, ty, 0)
aGetUnitMapElementPtr(0) --read [pool]:3872 --read <aRandom2 seed>
c0 = aGetCtrlMapElementPtr(0,0) --read $c0:9200
```

Three things changed with it. The read covers **forty-four** records rather
than twelve, so a muzzle creator's whole output is compared instead of a
window onto it. The byte is read back through the same pointer it was written
to, because a `memcpy` that missed would measure the wrong shot while looking
exactly like the right one. And the control map is read *after* the shot, so
the cells a walking arm was handed are measured rather than guessed.

| Phase | Weapon | Cells in the band | Calls | Records compared |
|---|---|---|---|---|
| `shot_07` | 7, flame stream | 1 | 1 | **20** — every record it lays |
| `shot_07_nosound` | 7, the other branch | 1 | 1 | 20 |
| `shot_09` | 9, blizzard shot | **2** | **2** | 4 |
| `shot_11` | 11, grenade | 0 | 0 | 0 — see §51.2: the handler reads the state byte, and a bare load has no overlay |
| `shot_11_band` | 11, two cells stamped by hand (§51.2) | **2** | **2** | 12, the second at **arc 1** |
| `shot_11_overlay` | 11, two cells stamped by `aBuildTargetOverlay` (§51.2) | **2** | **2** | 12, the second at arc 1 |
| `shot_41` | 41, tracer burst | 1 | 1 | 27 |
| `shot_44` | 44, proximity round | 5 | **5 rounds** | 30 |

**Ring 0 is settled on both branches.** `0x0040CBF2` decides whether
`aAnimationCreateSoundBuffer` runs, and it is the sound-buffer chain under
`0x00436B60` that last writes at the depth the flame stream's first ring reads
three doubles out of. Forcing `je 0x0040CC38` to `jmp` — one byte, and it
changes neither the unit nor the weapon — takes the other branch. Both
reproduce all twenty records field for field, so the three slots hold zero
either way. Mutating the stand-in to `(0.01, 0, 0)` fails the check on both.

**And the branch each phase took is read, not asserted.** The phase used to
record only that the capture had *asked* for the other branch — its own `skip`
argument written down, which is no evidence at all that the byte landed. Every
shot plan now reads `0x0040CBF2` back out of the running image after
`aAttackUnit` returns, and `shot.branch_is_measured` compares the two bytes
against what that phase asked for: `74 44` on the shipped path, `eb 44` where
the gate was forced. The two phases therefore cannot drift into being the same
run under two names, and the guarantee no longer rests on `dbgcall`'s
`--poke ADDR:EXPECTED=>NEW` refusing to write over unexpected bytes — that
stays as the second guard.

All six were re-taken with the read in place on 2026-09-12, so
`SHOT_BRANCH_UNMEASURED` is empty and the check speaks for every shot rather
than for none: `shot_07`, `shot_09`, `shot_11`, `shot_41` and `shot_44` each
read `74 44` back out of `0x0040CBF2`, and `shot_07_nosound` read `eb 44`.
The gate the flame stream's second phase ran down is therefore measured and no
longer inferred from the fact that a poke was requested. Wine needed three
attempts for `shot_07` and nine for `shot_07_nosound`, which is [`91`
§1](91-wine-runtime-probes.md)'s start-up again and not a property of the
plans.

The **value** is measured; its **provenance** is not. Two readings fit: two
routines that both leave zeros at that depth, or a depth neither reaches, in
which case what is read is older still — `aAttackUnit`'s own frame, which is
the same on both branches. Nothing here distinguishes them, and that is what
the pin now says.

**The walk is measured.** `shot_09`'s band holds two cells, (18, 9) and
(18, 10), and its arm left four records — two calls of a creator that lays
two — each pair carrying its own cell's coordinates. Both reproduce. And
each record's `aux` is the occupant the arm read: 4 and 17, the units standing
on those two tiles **before** the shot, while the post-shot map shows `+0x07`
cleared on both. That settles the order in the direction §8.1.3 already
argued: `aAttackUnit` never calls `aKillUnit`, its only `aRemoveUnitElement`
call is at `0x0046C1F9` after the animation, and the arm therefore fires at
cells whose occupant the sweep is about to remove. `inclib/blob_creators.py`
said the opposite in a docstring; it was wrong and is corrected.

**Weapon 44 is not a walk, and now that is measured too.** Five marked cells
and five creator calls look alike until the records are read: all thirty carry
the same `aux`, one aim point, five rounds each with its own scatter draw.
The five cells are only what `every_unit` left for the resolver; the arm has
no band test at all.

**Weapon 41 needed a second measurement to pass, and the failure was the
useful part.** Its burst came out low on `z`, `rot_x` and `vz` because
`aBlob_CreateTracerBullet` lifts its aim by the height of *the cell's own*
occupant, and the `origins` phase had only ever asked `0x0047AD30` about the
two units the fixed argument vector uses. It asks about every live unit now —
unit 4 stands 1600 high where unit 1 stands 2400 — and the burst reproduces.

**Weapon 11 cannot be exercised from this save, and that is measurable rather
than arguable.** Its pattern handler `0x0046B0D8` does not look for units: it
marks a cell whose `+0x0B` action point is in 30..34, the multiplayer victory
points of [`10` §4.6](10-lev-format.md). The same map read that gives the band
gives the histogram — 389 cells at 0, six at 1, two at 12, two at 17, one at
39 — and **none** in the band. So weapon 11 marks nothing whatever it is aimed
at, its walk never runs, and the arc argument stays at zero. The phase is kept
with a row of zeroes and a `hit` of 1, and the check accepts an empty band only
for the weapon whose histogram explains it.

**The draw-count check is gone.** It measured the whole attack's Lehmer steps,
which move with the roll, so it could only ever say the seed after was
reachable from the seed before. What reaches past the read window now is the
read window: forty-four records instead of twelve.

### 14.5.5 The aim point, measured (2026-09-12, night)

§14.5.4 replayed each walked cell with an aim point built from a **rule** —
tile times 3200 at height zero. It matched the two objects the `symbols` phase
had resolved and it matched every record, but it was a rule: this map is flat,
this is one save, and a raised cell would have needed the call the plan could
not make, because a plan is static and the walked cells are only known after
the shot.

The way out is to stop asking about cells and read the array instead.
`aGetSymbolObjectPtr` `0x00404C40` is eleven instructions and its arithmetic is
in them:

```
8b 4c 24 04     mov ecx, [esp+4]
a1 b0a74f00     mov eax, [0x004FA7B0]      ; the count
81 e1 ffff0000  and ecx, 0xFFFF
3b c8 / 7e 03   cmp ecx, eax / jle         ; refused above the count
8d 04 cd ...    lea eax, [ecx*8]
2b c1           sub eax, ecx               ; 7 * id
8b 0d 20a84f00  mov ecx, [0x004FA820]      ; the base
8d 04 80        lea eax, [eax+eax*4]       ; 35 * id
8d 04 41        lea eax, [ecx+eax*2]       ; base + 70 * id
```

Not `OBJECT_TABLE`'s 77-byte records — those belong to `aGetStdObjectPosition`
`0x00405100`, which answers a different z for the same tile, and reading one
and calling it the other is the mistake §7.4 already names. The `symbols`
phase now reads `[0x004FA820]` for 400 records in one go, so **every cell on
the map has a measured object**, and `_cell_inputs` aims each walked cell at
its own `+0x05` instead of at a formula. All the records still reproduce —
which is the point: the rule was right here, and is no longer load-bearing.

Five checks hold the reading, and they bite in two different places:

| Check | Bites at | What it catches |
|---|---|---|
| `weapon.symbol_object_service` (`blob_tables`) | check time | the service's own bytes, and the base, stride and bound decoded back out of them |
| `symbols.table_matches_the_disassembly` | check time | the capture's copy of those three against that decode |
| `symbols.table_is_the_service's` | parse time | the two ids the service *was* called for, against the array's entries for the same ids |
| `symbols.read_covers_the_array` | parse time | the read width against `[0x004FA7B0]`, the highest id the service accepts |
| `symbols.covers_the_map` | parse time | every object id a cell *names*, against the ids the capture measured |

The parse-time checks cannot fail on stored numbers — they are *about* how the
bytes were divided — so they were exercised by re-parsing the capture's own stored
rows with the constants mutated: at stride 77 the array's entry for id 139
comes back `(-855638016, -2133996083, -2147483486)` against the service's
`(60800, 19200, 0)`, and a read width of 380 does not come to the bound. That
matters, because an earlier version of `parse_symbols` did `out.update(called)`
and folded the service's answers **into** the array, which made
`table_is_the_service's` compare a value with a copy of itself: a check that
would have passed at any stride. The service's answers are stored beside the
array now. The two check-time checks were mutation-tested in the ordinary way:
stride 71, the base moved to `OBJECT_TABLE`, the count cell moved four bytes;
and the aim point itself with its z lifted by 160.

**The bound is compared with `jle`, so the id equal to it is accepted**, and
the read was one entry short of it: `[0x004FA7B0]` is 400 and the plan read
ids 0–399. Nothing on `_6_.sav` names id 400, so no replay ever reached the
gap — but the one that did would have fallen back to the capture's fixed
target and been compared against a program aimed elsewhere. The read is
`SYMBOL_READ_IDS = SYMBOL_IDS + 1` now, the phase's re-take predicate follows
the plan's width rather than the map's cell count (or the wider read would
never have landed), and the 2026-09-12 capture holds **401** entries with id
400 measured. `symbols.covers_the_map` states the property a replay actually
needs — every id a cell names has a measured position — instead of counting
entries, and `_cell_inputs` raises rather than substituting when one is
missing, which `shot.cells_are_measured` pins.

One precision worth keeping: `cmp ecx, eax / jle` accepts `id == count`, so
`[0x004FA7B0]` is the last id the service answers for and not a number of
records. The read covers ids 0 to 399, which is one per cell of this 20×20
map and every id a cell can name; `SYMBOL_IDS` is derived from the captured
map's own dimensions, and a larger map fails `read_covers_the_array` rather
than reading short in silence.

### 14.6 Which music family plays: `Arack`, read out of the import table

§11.2 called this unfalsifiable on this corpus and recorded `Track` as a
choice. It was neither.

**`Incubation.exe`'s import descriptor names `audio.dll` where the 1997 build
named `WINMM.dll`**, importing exactly the nine `winmm` entry points the game
used: `mciSendCommandA` and `mciGetErrorStringA` for the CD, and seven `mixer*`
calls for the options screen. There is no `winmm` descriptor at all. That DLL
is an ogg-winmm shim built with `%s\Arack%02d.ogg`; `sound.dll` is the same
shim built with `%s\Track%02d.ogg`, and **nothing in the tree imports it**.

The corpus could not settle it and was never going to — the answer was in the
loader's own table, one directory the question had not thought to read. The
converter now copies the `Arack` family, `docs/28` gained a §6.1 for it and
closed its own open question 3, and eleven checks pin the chain end to end:
the descriptor, its nine entry points, the missing `winmm` descriptor, the
sweep that finds no importer of `sound.dll`, each DLL's format string, the two
families' 02–08 / 09–14 divergence, and that every track the shipped playlists
name exists in the family the shim plays.

**The converted cache's bytes do not change** — the five missions reach only
track 7, and 02–08 are byte-identical between the families — but the manifest's
source fingerprint names different files, so the cache id moves and the cache
is republished. That is the content-addressing working as designed.

### 14.7 What this pass cost

| | §1–§13 | §14 |
|---|---|---|
| `blob_tables.py --check` | 345 | **367** |
| `remake_convert.py --check` | 169 | **181** |
| Godot suites / checks | 30 / 1 811 | **30 / 1 842** |
| `CONVERTER_VERSION` | 0.9.0 | **0.10.0** |
| Open questions closed | — | `28` §12.3, `30` §2.5 item 7 |
| `godot/core/` delta | zero | **still zero** |

The version bump is because the emitted documents changed twice — the geometry
document gained `parts` for the prototypes that have them, and the sound
document gained the step period's initial value. Both in both places, and
`user://caches` republished.

### 14.8 The battery, re-run

**74 mutations, 63 caught, 11 missed** — against §12's 53 / 40 / 13, with
`tools/**/__pycache__` cleared before every run and before the final one.

Every pin §14 added is read by a check: the import descriptor and both shim
format strings, the two families' range and their divergence point, the step
period's global address and its zero start, the carry-over trace, the seven
matrix builders, the two jointed effect models and the unjointed contrast, and
all three reach figures.

Three entries left §12.1's missed list, and each for a different reason worth
distinguishing:

* **`MUSIC_FORMAT`** — because §14.6 gave it three independent readings.
* **`ROOF_UNIT`** — because §12.1's claim about it was wrong and the re-run
  said so.
* **`UNJOINTED_EFFECT_MODEL`** — because the check that named it *skipped*
  when the model was absent. A check that passes on a missing input is not a
  check; it now fails.

Two more were rewritten mid-pass after the battery showed them agreeing with
themselves: `music.families_diverge_at` derived both sides of its comparison
from `MUSIC_TRACK_LO`, and `walk.period_carries` seeded the global with a type
whose period was the one already in force. Both now read the shipped tree.

The eleven that remain are §12.1's own list minus those three, unchanged and
for the reasons that table gives.

---

## 15. The eleven unread pins, and the creators

§14.8 left eleven pins that no check read and §14.5 left the creators measured
rather than closed. This section is the pass over both.

### 15.1 Nine of the eleven had a second reading available

The reason six of them were unread was recorded in §12.1 as "read out of the
LCL handlers by [`20` §7.4](20-lcl-language.md) and quoted here for the driver;
`blob_tables.py` has no **second** reading of them, so a check would compare a
pin with itself". That was true of the file and not of the binary. The four
animation routines `docs/20` names carry the numbers as instructions, and
instructions decode:

* **`OpenDoor`** — `mov ebp, 0xA` at `0x00410CFC`, counted down by the `dec` at
  `0x00410D17`. Ten frames.
* **`Bridge`** — `mov ebx, 0x50` at `0x00410EBF` with its `dec` at
  `0x00410ED1`; and the step is `lea edi,[edi+edi*2]` then `shl edi,2`, which
  is 3 × 4 = **12**.
* **`Elevator`** — `lea eax,[esi+esi*4]`, `lea esi,[eax+eax*4]`, `shl esi,5`:
  5 × 5 × 32 = **800**.
* **`Platform`** — the frame count is `lea` ×5 then `shl 1` = `dist * `**10**,
  and the step is `lea` ×5 then `shl 6` = **0x140**, on both axes.

Two decoders do the work and both **fail loud**: `lea_scale` answers `None`
unless the base and the index are the same register (otherwise the instruction
is an address computation and not a multiply), and `shl_scale` answers `None`
unless the bytes are `C1 /4 ib` or `D1 /4`. A mutated site reads as "not the
instruction I expected", never as a wrong multiplier. Each site is also
required to lie inside the routine `docs/20` names, and that routine is
required to be the target of a call — the pair of checks `roof.is_a_routine`
and `roof.sites_inside` learned to make together in §14.

**`ATLAS_HALF_EXTENT_SCALE` was the same story one layer down.** `SIZE_SCALE`
already existed with its shift pinned; the `160` at the bottom of the file was a
second, unread copy, and the factor of five in `lea eax,[eax+eax*4]` at
`0x004040F0` had never been read at all. Both are now one constant with both
factors decoded.

**`ATLAS_SIZE` was not underchecked — it was dead.** The file defined it twice:
`= 256` near the other atlas constants and `= ATLAS_TILE * ATLAS_GRID` fourteen
hundred lines later. The second shadowed the first, so perturbing the literal
changed nothing and the battery was right to call it unread. Deleting the dead
one leaves a derived constant whose two factors are both checked against the
`anim` record's own header in every world set, and `sound.atlas_grid_squares`
— which had become `ATLAS_TILE * ATLAS_GRID == ATLAS_SIZE`, a definition
compared with itself — now reads the two `shl …,5` the draw path applies to the
row and the column bytes.

### 15.2 The two compatibility flag names — and the gap the check found

§12.1's reason for these was "flag **names**, whose only independent reading is
[`92` §7.1](92-remake-architecture.md)'s prose". There is a better one: the
remake spells the same two strings by hand, and a rename on one side alone
gives the player a preset that toggles nothing. So `blob_tables.py` reads
`godot/game/audio/*.gd` and requires both names to appear.

**It failed the moment it was written, and it was right to.** The remake did
not spell them. `AudioEvents` carried a single `_faithful` boolean, and
[`97` §10](97-slice-5-report.md) and `92` §7.1's "every compatibility choice
gets a stable named flag" were satisfied on the Python side and nowhere here.
`AudioEvents` now carries `COMPAT_WEAPON_35` and `COMPAT_FOOTSTEP_24` by name,
each independently settable, with `is_faithful()` derived from them rather than
from the constructor's argument, and `unknown_compat_flags()` reporting any
name the **cache document** declares that this build does not carry. Five suite
checks, including that turning the footstep flag off leaves the weapon flag on.

That is the second time in this slice a check written to close a battery miss
found a real defect rather than confirming an absence — the first was
`effects.unjointed_*` skipping on a missing model.

### 15.3 `INTERFACE_WAVES` — containment was the flaw, not the sample

The battery's perturbation turns `click_5.wav` into `click_6.wav`, and the check
asked whether the model's five names were a **subset** of every direct site's
name. A perturbed name that is still some other direct site's name stays inside
the set. Filtering the sites by `INTERFACE_VOLUME_ID` and asking for **equality**
derives the tuple from the binary instead, and re-pins 96 in the same breath.

### 15.4 The creators: `tools/blob_gold.py`

§14.5 named the closing path — "a `dbgcall` capture: fire a shot in the live
process, read the pool back, and diff the records" — and this is that tool.

Three things had to be settled before a plan could be written, and each was a
place the obvious guess was wrong:

1. **`aGetMemory` writes a handle, not a pointer.** `aInitBlobs` passes
   `&0x004FE638`, and it is tempting to read that as the block address. Both
   the constructor `0x00420950` and `aDrawZoomBlobs` show otherwise: each does
   `eax = [0x004FE638]; esi = [0x0050DE54 + eax*74]`, which is only arithmetic
   that makes sense if the first value is a small index into a table of 74-byte
   entries. It is 22 in the shipped build. A plan that read at the handle would
   have read at address 22 and burned every Wine attempt for nothing.
2. **`--code` is unusable on this host**, exactly as `ai_gold.py` records: a
   nineteen-byte stub that did nothing but the dance above made
   `Incubation.exe` fault before the anchor, six attempts out of six, where the
   same plan without it reached the anchor on attempt two. So the address is
   reached through the table instead, and confirmed twice per run — by the
   handle, and by `aResetBlobs`'s return value, which is the block's end after
   it has walked 450 records of 88 bytes.
3. **`--probe` cannot recover a `__cdecl` arity.** The creators are `__cdecl`,
   the caller cleans up, and the callee's `ret` pops nothing whatever the
   arity — which the harness's own README states as an honest limit. The
   arities come from the **callers** instead: each arm's `add esp, K` after the
   `call` is exact, every creator that is called from more than one site has
   sites that agree, and the thirty run from **2 to 7 dwords**. That table is
   pinned whether or not a capture ever runs.

Two bugs in the tool's own first drafts are worth recording, because both
produced a result that looked like a finding:

* the read was hung on a second `aResetBlobs()`, which **wipes the pool before
  the read**. Every creator came back with zero records — indistinguishable
  from the CHECK-abort path, and a perfectly plausible answer for a creator
  called on an empty cell;
* every phase is its own process, and only the first one loaded the save. The
  other phases ran the creators against no map at all, and every one of them
  took the abort path. Same symptom, different cause, and the first hid the
  second.

### 15.5 What the capture found

> **Four of the findings below are superseded by [§16](#16-the-four-items-15-left-and-what-three-of-them-turned-out-to-be)**
> — the velocities, the elevation, the placement law and the coverage. Three
> of the four had a wrong premise. The section is kept as written because what
> was believed and why is part of the record; read §16 beside it.

The tool works, and what came back is more than a confirmation.

**The engine agrees with the static tables, field for field.** For every
creator that produced records, the `(class, kind, lifetime)` of each record is
compared against what `blob_tables.py` read out of the compiler's own index and
jump tables. The two share no code — one is a disassembly, the other is a
running process — and they agree. That is the first time anything in the blob
layer has been checked against the engine rather than against a second reading
of the same bytes, and the suite that replays it prints **`native-runtime`**.

**The origin is the shooter's tile.** Every record stands at `tile * 3200`
world units, which is precisely what `BlobTriggers.muzzle_point` already
answered. It was an assumption; it is a measurement now.

**And the placement law is not "at the tile".** Some creators offset their
blobs — `0x00425CA0` by (−400, −800), `0x00426070` by (−960, −1920) — and every
one of those offsets is **collinear with the line from the source tile to the
target tile**. `0x00428570` lays eight blobs evenly down that line, from the
shooter to nearly a field and a half away, with `z` falling 2 400 → 1 743 as it
goes: a tracer, drawn as one call. The check is an integer cross product, so no
fraction has to be named and no rounding enters it.

**The elevation is a constant the creator carries, not the ground —
provisionally.** Every tile the capture used stands at height 0 and the blobs
still come out between 0 and 3 679 units up, so the number is the creator's and
not the terrain's. What that does *not* separate is "absolute" from "the floor
plus a constant", because at height zero the two are the same number. The tool
grew a phase for it — one creator called again on a tile the control map says is
raised — and **that phase has not landed**: Wine did not reach the anchor for it.
So the question is open, the capability to close it is in the tool, and the
check that would read it is conditional on the phase existing rather than
passing in its absence.

**A missing edge in the call graph, found by a disagreement that was not one.**
Two creators produced a `(class 2, kind 50, life 8)` record their own
constructor calls could not explain. They call *other* creators, and the
records those leave are in the same pool; the check now follows one level of
nesting, which is enough for every creator in the capture as it stands — an
empirical claim about the ones that ran, not about all thirty, and a second
level showing up would be a finding rather than a failure. The lesson is the
same one §12 recorded: a check that looks like it has caught the engine
disagreeing with the disassembly is far more likely to have caught the check.

~~**What is still ours** is the per-blob velocity. It is drawn from `aRandom`
*inside* the creator, so replaying one exactly needs the engine's generator
state at the moment of the shot — which is a different capture, of a whole
shot rather than of a creator call. `BlobTriggers` paces a blob by its own
recorded lifetime instead, which is extracted data rather than a chosen
constant.~~ **Nothing is, since §51.1.** The draws are `0x004638E0`'s, the
seed is read either side of every creator, and the last creator paced by a
chosen constant was transcribed on 2026-09-12.

**The capture as it stands holds 15 of the 30 creators**, 13 of which produced
records and two of which refused the tile they were given — 104 records in all.
Wine reached the anchor for some phase groups and not for others, which
[`91` §1](91-wine-runtime-probes.md) already records as an environment result
rather than a failure: phases are written as they land and merged on re-run,
`--check` reports the coverage, and the fixture is gitignored like every other
capture here. Two merge passes at ten attempts each added nothing to the first
pass's fifteen, so the remaining groups are where this host's Wine will not go
today, not where the tool stops working.

### 15.6 What this pass cost

| | §14 | §15 |
|---|---|---|
| `blob_tables.py --check` | 367 | **384** |
| `blob_gold.py --check` | — | **new** |
| Godot suites / checks | 30 / 1 842 | **31 / 1 854** |
| Battery: mutations / caught | 74 / 63 | **98 / 98** |
| `godot/core/` delta | zero | **still zero** |

### 15.7 The battery's own window, three times wrong

The last "unread pin" of §14.8 was not a pin. `INTERFACE_WAVES` opens its tuple
on the same line as its name and the sampler started at the line **after** the
assignment, so no entry of it was ever reachable. Widening that window is what
makes the check written in §15.3 catch it — and the widening broke the sampler
outright, in a way that reported success:

1. starting **after** the assignment line put every one-line structure's
   entries out of reach;
2. starting **on** it made the "next top-level statement" test fire on the
   assignment itself, so **all fourteen** sampled tables stopped being built.
   The run printed `0 missed` and a smaller total, because a target that is
   never built is never missed. Only the count showed it — 83 where the
   previous run had 88;
3. and the sampler only ever perturbed **decimal** literals, while the address
   tables are written entirely in hex. Those it did report, as fifteen lines of
   "no sampled entry" — visible, at least, but read as a property of the tables
   rather than of the sampler.

The window is now bounded by **bracket depth**, which is what it should always
have been, with two additions: a hex literal is perturbed where there is one,
and a table written entirely in strings has a string perturbed instead. All
fourteen tables now produce a real mutation — including `PAIN_WAVES`,
`DEAD_WAVES` and `SECOND_HUMAN_WAVES`, which had never been perturbed at all.
The run on the finished tree is **98 mutations, 98 caught, 0 missed**,
with no "no sampled entry" line left: every pin this slice added, and
every table it samples, is read by a check. (True when written and
**superseded by §16.6**, which found three more ways this battery could report
nothing about a pin, and ends at 159 of 159.)

The lesson is one this document has now recorded three times in three different
shapes — the `__pycache__` staleness, the stdout-versus-stderr read, and this.
**A test harness reporting a clean result about work it did not do is the
default failure of test harnesses**, and the only defence that has actually
worked here is reading the *count* beside the colour.

**One process note, because it cost a check.** The mutation battery rewrites
the files it perturbs, and an edit made to `tools/blob_tables.py` **while it was
running** was lost when the battery restored its own copy of the tree. The two
arity checks came back silently short and only the check count showed it. The
rule is the same shape as the `__pycache__` one already recorded: do not touch
a file the battery is walking, and read the count, not the colour.

---

## 16. The four items §15 left, and what three of them turned out to be

> **Superseded in part by §17.** Three of the residues this section names have
> since been closed and one was not a question: the draw arithmetic (§16.1's
> `UNVERIFIED` — see §17.2), the Wine group-boundary alignment (§16.6's
> "unexplained" — see §17.3), the unit-pool thread §16 handed to `docs/22`
> (§17.4), and `docs/28` §12 item 1, which §16.7 records as still open and
> §17.1 closes. Read the two together; nothing below is retracted, but its
> open list is out of date.

§15.5 ended with four things open: the velocities, the elevation, the
coverage, and the depth of the creators' call graph. Three of the four had a
**wrong premise**, and the corrections belong here rather than in a quiet edit
of the paragraph that made them. §15.5 stands as written; where it is
superseded, it is superseded by this section.

### 16.1 The velocities are not `aRandom`'s — there are two generators

§15.5 said the per-blob velocity "is drawn from `aRandom` *inside* the
creator, so replaying one exactly needs the engine's generator state at the
moment of the shot — which is a different capture, of a whole shot rather than
of a creator call."

The first clause is false, which makes the rest of it moot. The capture now
reads `aRandom`'s seed (`0x00514078`, a qword double) immediately before and
immediately after every creator call, and it **never moves** — not for one of
the thirty. A static sweep of each creator's whole closure finds no `call` to
`aRandom` either. Two readings sharing no code, both negative.

What the disassembly then shows is a **second entry point eleven `nop`s
later**. `0x004638E0` is `aRandom`'s body byte for byte — same multiplier,
same modulus, same x87 sequence — over the seed at `0x00514070`, and without
the call counter and running sum. Sixty-two of the sixty-nine shared bytes are
identical; the seven that differ are the seed address in the opening `fld` and
the closing `fst`, two `call rel32` displacements, and the two bytes where
`aRandom` goes on to its counters while this one returns.

**It is the busier of the two by a factor of eleven** — 372 call sites against
32, 75 calling functions against 17 — and the two are seeded differently in
the same six instructions of `0x004494C0`:

```
    eax = GetTickCount();
    fild qword [esp+0x1c];
    seed_uncounted(that);        /* 0x00463850 -> 0x00514070 */
    aRandomize(1.0);             /* 0x00463820 -> 0x00514078 */
```

So [`22` §3.1](22-combat-and-visibility.md)'s finding — a mission plays out
identically every time it is loaded — has a second half nobody had looked for:
**the effects were never meant to repeat.** A shot does the same damage every
run and does not look the same, by construction.

With the *right* seed read either side, "random" becomes a number, because the
generator is a pure function of its seed. On the captured tile most creators
draw **nothing at all** — `aBlob_CreateSpores` (`0x00420A50`) lays twelve
blobs on a ring 36° apart at a radius of about 640 and lays the same twelve
every time — while `aBlob_CreateFireWheel` (`0x004228F0`) takes **ninety**
draws for its twelve records. **Fourteen of the thirty draw** on the captured
tile, from 3 to 203 times; the other sixteen draw nothing at all and are
reproducible from the fixture alone. The count is now pinned per creator
beside the static one: `blob_tables.py`'s `CREATOR_DRAW_SITES` says how many calls to the
generator a creator's closure *contains*, and `blob_gold.py`'s `CREATOR_DRAWS`
says how many it *made*. A creator with sites and no draws has them on a
branch this tile does not take, which is a result and not a discrepancy.

What is **not** claimed is the arithmetic on top of the draws. A velocity that
is `aRandom(base, span)` outright is a straight line in the drawn fraction and
can be solved for; **none of the twelve drawing creators solves**, which is
consistent with them drawing an angle and laying down `R·cos` — and that is
recorded as UNVERIFIED rather than guessed at. The solver is handed a
synthetic creator whose velocities *are* draws and is required to recover
them, because a fitter that never fires is indistinguishable from a broken
one; that is `native.fitter_solves_a_known_case`, and it is the check that
makes the empty census mean something.

`docs/22` gained §3.2 for the generator itself, `docs/28` gained §7.6.1, and
`blob_tables.py` gained thirteen `random.*` checks that need no capture at all.

One thing this opened rather than closed: nineteen of the seventy-five callers
of the uncounted stream are outside `aBlobs.cpp`, and three of those are the
**unit pool** — `aEnlargeUnitPool`, `aAddUnitToUnitPool`,
`aGenerateUnitElement` — which is simulation, seeded from the wall clock. One
function draws from both streams. That is now [`22` §12](22-combat-and-visibility.md)'s
one open question.

### 16.2 The elevation: neither hypothesis was right

§15.5 offered "absolute" against "the floor plus a constant" and said the
phase that would separate them had not landed because Wine did not reach the
anchor.

Both parts were wrong. The phase never *ran*: the capture's `state` predated
the control-map read, so it carried no `heights`, the tile-finder returned
`None`, and the probe was skipped in silence. That is the second time in this
document a check has reported nothing rather than failing, and the fix is the
same shape — the recapture predicate now asks whether the phase carries the
field rather than trusting a version number.

And the answer is neither hypothesis. Every one of the thirty creators opens:

```
    eax = aGetCtrlMapElementPtr(y, x);     /* CHECK */
    dx  = *(u16 *)(eax + 5);               /* the symbol on the cell */
    eax = aGetSymbolObjectPtr(dx);         /* CHECK */
    x = eax->[0x10];  y = eax->[0x14];  z = eax->[0x18] + K;
```

The origin is the **placed object's own position**, and the control map's
height dword at `+1` is read by **no creator at all** — swept for across all
thirty bodies, of which none contains the read. So the floor cannot enter,
whatever the ground is doing, and this is settled for all thirty rather than
for the one a probe touches.

The probe still runs, as the other reading: rather than hunting the map for a
raised tile — there is none a creator will act on, since every unit in the
save stands at height zero — it **writes** one map field into the control
map's height under the creator's own tile, through the game's imported
`memcpy`, and calls the creator again unchanged. `z` does not move.
[`93` §11](93-slice-1-report.md) settled the large-unit clearance the same way,
by writing the `size` byte rather than finding a mission with a large unit.

A third defect fell out of building it: `heights_from` was reading the cell's
height as **one byte** where `movemap_gold` has always read a signed dword, so
a tile at 8 320 came back as 128. It had never been exercised, because the
phase that would have used it never ran.

### 16.3 The placement law is not one law

§15.5's "on the line of fire" was true of the fifteen creators the first
capture held and is **not** true of all thirty. The ones a shared process had
been losing include creators that lay their blobs in a **burst around** the
source tile, collinear with nothing.

The check is now a per-creator census — `line` or `scatter`, pinned per
address in `blob_gold.PLACEMENT_LAW` and mirrored in
`test_blob_native.gd`'s `SCATTER_PLACEMENT` — so a creator that starts
scattering, or stops, fails on both sides. The cross product is unchanged;
what changed is that its answer is now data rather than a law. **Four of the
twenty-three producers scatter**: `0x00424D20`, `0x00425810`, `0x00427410`
and `0x0042A9D0`, the last of them putting its record some nineteen map
fields off the line.

### 16.4 Coverage: one creator per plan, and the cause is still unknown

§15.5 attributed the missing fifteen to this host's Wine. The pattern said
otherwise: the capture held creators 1–5, 11–15 and 21–25 — groups 0, 2 and 4
entire, groups 1, 3 and 5 empty — reproduced across three invocations of ten
attempts each, and a start-up that fails independently does not land on group
boundaries. The obvious conclusion was a *faulting creator* taking its whole
plan down with it.

That conclusion is also wrong, and one creator per plan is what showed it. A
plan still fails now and then, and what the log says when it does is
`exception 0xc0000005 at 0x7bf2123d` inside a Wine system DLL, **before the
anchor** — before a single line of the plan has run, and so independent of
what the plan contains. `docs/91` §1's start-up intermittency, exactly as
originally attributed; the group-boundary alignment stays **unexplained**.

One creator per plan is still right, for the reason that survives either
explanation: a plan that dies takes down every creator sharing its process, so
five per plan turns one bad start into a fifth of the capture and one per plan
turns it into one retryable creator. Failures are recorded in the fixture with
what the harness said, kept *out* of `phases` so a re-run retries them.

**The capture in hand holds all thirty**, with no failures left: one pass took
twenty-five and lost five to Wine, and one merge pass took the five.
Twenty-three of the thirty produced records — 198 in all — and seven refused
the tile they were given, which is a measurement of which tile a creator will
act on and not a hole. Coverage, producers and record count are all pinned, so
a thinner capture fails rather than quietly reporting less.

### 16.5 The call graph: one level is enough, and now that is a statement

§15.5's "one level of nesting is enough for every creator in the capture as it
stands" was an empirical claim about the fifteen that had run. The walk is now
a **fixed point** rather than one hop, and the interesting part is that it
terminates after one for all thirty — which is a static fact, pinned in
`blob_tables.CREATOR_NESTED` (eight creators have an edge; the deepest chain
is one long) and checked as `creators.nesting_is_flat`. No capture involved,
and the claim covers thirty rather than fifteen.

### 16.6 Two pins the battery found unread, and what they were

The battery over the finished tree named ten misses, all in
`tools/blob_gold.py`, and they split into two different problems rather than
one.

**Nine of them shape a plan and nothing else** — the pool table and its
stride, the two seed globals and their width, `memcpy`'s and `rand`'s import
slots, how many `rand()` outputs bracket a call. `--check` replays a stored
capture and never renders a plan, so those nine were exercised only by
*taking* a capture, which needs Wine and is therefore outside every battery
this project runs. The fix is not to accept the boundary: the four plans are
now rendered with fixed arguments and **hashed**, so a perturbed constant
changes the text the tool would send and the digest says so. Three checks,
no Wine, no second copy of the addresses.

**The tenth was `CREATOR_EXTENT`, and it is a different animal.** It is a scan
*bound*: widening it by a byte changes no answer, so no perturbation of it can
fail, and that is a property of the constant rather than a gap in the checks.
What was missing beside it was the **measurement** — how far a creator's body
actually reaches to call another. It is 1 349 bytes, `0x00424250` calling
`0x00428F70` at `0x00424795`, and the window has to clear it. The reach and
the site are pinned; the bound is checked against them; and `GROUP_SIZE`, the
one remaining constant of the same kind, is now marked in the battery as a
capture *policy* rather than a measurement, because no check can honestly
assert its value.

**Then the battery found two more silences in itself.** Adding a line for
every listed pin it could not build a target for turned up eight names, and
three of them were real blind spots: `BASE_SWEEP_LO/HI/STEP` are one
*tuple-unpacking* assignment, which the single-name matcher could not see, and
`RANDOM_UNCOUNTED_OUTSIDE` and `MUSIC_SHIM_IMPORTS` are multi-line tuples that
belonged in the sampled path. The other five were honest: `ATLAS_NAME` does
not exist, and `ATLAS_SIZE` and `ATLAS_HALF_EXTENT_SCALE` are **derived** from
constants that are themselves mutated and caught. A separate hole in the same
place: `perturb()` returned `None` for an **empty** container, so
`NATIVE_FAULTS = []` and `AFFINE_IN_DRAWS = []` — whose emptiness *is* the
finding — were skipped without a word. It now inserts an element into an empty
container, and an unbuilt target is printed either way.

Reaching those turned up one last unread pin, `BASE_SWEEP_STEP`, and it is a
sampling density: the attenuation identity holds for *every* base volume, so
no step can make it false. What a coarser step can do is stop the sweep short
of full scale — 101 ends at −81 instead of 0 — and that is what is asserted
now, so the density is load-bearing for a property the sweep actually needs.

Two constants are left deliberately outside the battery, each with its reason
written beside it: `CREATOR_EXTENT`, a scan bound whose measurement is pinned
separately, and `GROUP_SIZE`, a capture policy no check can honestly assert.

The run on the finished tree is **159 mutations, 159 caught, 0 missed**, with
no "not found", "no perturbation" or "no sampled entry" line left — the three
different ways this battery has now been caught saying nothing.

This is the fourth, fifth and sixth time this document has recorded the same
shape of finding. The first three were the harness reporting a clean result
about work it did not do; these are the harness reporting a real gap, and the
temptation being to write the gap down as a boundary instead of closing it.

### 16.7 What this pass cost, and where it leaves the layer

| | |
|---|---|
| `blob_tables.py --check` | 384 -> **407**, all static, no capture needed |
| `blob_gold.py --check` | 49 -> **115** |
| `godot/run_tests.sh` | 1 854 -> **1 860** checks, 31 suites |
| The capture | **30 of 30** creators, 0 failures, 198 records |
| `core/` delta | **zero**, as every slice since the first |
| Documents corrected | `22` (§3.2 new, §12's first open question), `28` (§7.6.1 new, §12 item 1 sharpened), `97` (§15.5 superseded by §16), `00`, `CLAUDE.md` |

The oracle boundary is unchanged and still honest: the creators are
`native-runtime`, the arms are `executable-Python`, and `docs/28` §12 item 1 —
the service hooks the *arms* read — remains open. What moved is that three of
the four things §15 called open were answered by reading the binary rather
than by more Wine, and the fourth was answered by asking the harness for a
smaller unit of work.


---

## 17. Closing §16's own residue — the service hooks, the draws, the host

Dated addendum, September 2026. §16 ended by naming four things it had not
settled. Three of them turned out to rest on a premise that was wrong, and the
fourth was not a question.

### 17.1 The five service hooks were never called; now they have been

`docs/28` §12 item 1 had stood since the layer was first written: the
orientation, geometry and target-map helpers an update **arm** reaches outside
its own record return data nobody had measured, so no trajectory built on them
could be called native-verified. §16 sharpened the item without moving it — the
*creators* were captured, and the creators only show what a helper answered.

`tools/blob_gold.py` gained a `hooks` phase. It declares all five with the
arity each one's callers clean up, hands them scratch buffers, and sweeps them
inside a running `Incubation.exe` with `_6_.sav` loaded: twenty deltas through
`0x00403AA0` and forty (twenty × two shift modes) through `0x0046D400`, eight
rotations through `0x004039A0`, eighty-one ids through `0x00405100` and every
named unit slot through `0x00477AE0`, plus the five runtime function pointers
read as values and as the first bytes of what they point at. **It landed on
attempt 1.**

Four of the five are now reproduced exactly, in `tools/inclib/eng3d.py` and its
GDScript twin `godot/game/fx/eng3d_geometry.gd`, and checked answer for answer
against the capture. `docs/28` §7.4.2 is the specification; three findings are
worth repeating here because each corrects something the remake was doing:

**The remake's `orient()` was wrong in the unit and wrong in the pitch.** It
was an `atan2` over a 0..0xFFFF turn — a *documented substitute*, chosen
honestly because nothing better existed. The real routine works in the
**4096-unit circle** and takes its pitch from the delta *after* turning it flat
with a Q14 matrix, minus a quarter turn. Twenty of twenty pairs now reproduce.

**Two shifts round differently inside one call.** The matrix builder divides
toward zero (`cdq / and edx, 0x3FFF / add / sar 14`) and Eng3d's transform
divides toward negative infinity (a plain `sar 14`). Exactly one of the twenty
deltas — `(-1, -1, -1)` — separates them, and it answers 512 one way and 0 the
other. A sweep that had not included a delta of length one would have pinned
the wrong rule and passed.

**`0x0046D400` divides by zero on purpose.** `NaN` and `±inf` are ordinary
answers from it, and its `>> 3` flag does not reach the two components a reader
would expect it to. Neither is a thing a reimplementation invents; both had to
be seen.

The sweep also found an off-by-one in the shipped engine: both lookups guard
with `cmp eax, 0xC8` and a *strictly greater* branch, so **id 200 is admitted
and the arrays hold 200 entries**. Nothing shipped passes 200. It is pinned so
that a remake clamping at `<= 200` does not inherit it silently.

**What did not move.** The arms are still a transcription compared against a
transcription, so `test_blob.gd` still prints `executable-Python` and the blob
layer still claims no `native-runtime` anywhere. And one of the five —
Eng3d's three-angle matrix builder behind `0x004039A0` — is *recorded* and not
reproduced: no ordering of `Rz Rx Ry` with either rounding matches all eight
captured cases. It is named in the document rather than smoothed over.

### 17.2 The draw arithmetic was `aRandom` all along; the fit was wrong

§16.1 established which generator the creators draw from and how many times,
and left the arithmetic on top `UNVERIFIED` because an affine fit matched none
of the fourteen creators that draw. Two things were wrong with the fit, and
neither is exotic:

* **the draw-to-field order is per creator and runs both ways.** MSVC evaluates
  `__cdecl` arguments right to left, so a creator that passes its draws
  straight into the constructor consumes them in reverse field order
  (`0x004228F0` draws `vz`, `vy`, `vx`) and one that parks them in locals first
  does not (`0x00425810` draws `vx`, `vy`, `vz`). A single global rule cannot
  fit both;
* **some creators scale the truncated draw.** `0x0042ACF0`'s vertical is 32
  times it, and a fit looking only for `base + span·f` cannot see a factor.

With those two admitted, three creators reproduce **every varying field of
every captured record** from the seed alone and a fourth its velocities, and a
drawn rotation turns out to be `aRandom(0, 4096)` — the same 4096-unit circle
§17.1's orientation helper answers in. `docs/28` §7.6.2 has the table.

The remaining creators have **no per-record recipe to fit**, and that is the
answer rather than a gap: their stream is not consumed at a fixed rate. Three
build records of several kinds in one call; others retry, so `0x00429A80`'s
first record does not sit at draw 0 while its second sits at draw 4. No cycle
length exists for a fit to find. The blanket affine fit failed for a reason
that would have made it keep failing.

The discipline that keeps this honest: a creator is pinned **only** if every
field that varies across its records is explained. Allowing partial recipes
produced a coincidence immediately — a creator with four records "explained" a
field as `800 · int(18 + 7f)` — which is what four samples and a free scale
factor will do.

### 17.3 The Wine alignment was not a phenomenon

§16.6 recorded the group-boundary alignment of the first blob capture as
**unexplained**. It is not a thing to explain. `blob_gold.py --probe-startup 16`
runs one identical plan sixteen times with a single attempt each: **two reached
the anchor**, the fourteen failures are all pre-anchor, in two shapes, and
their positions carry no period.

So the loss unit *is* the group, every loss is therefore a whole group, and
"aligned with group boundaries" is a tautology rather than an observation. What
remains is three of six groups losing all ten of their attempts, which at that
rate is ordinary. `docs/91` §1.1 carries the sequence, and the measurement is a
re-runnable mode rather than a number written down once — the rate is a
property of the host and the day, and the `hooks` phase of the same tool landed
first try.

### 17.4 The unit pool rolls a voice

§16 handed `docs/22` a new open question: three routines in `aUnitMap.cpp` draw
from the **clock-seeded** stream, which is the one combination §3.1's
determinism argument does not cover.

All three do the identical thing — `aRandom(1, 6)`, `__ftol`, one byte — and
the byte is `unit[+0x55]`, the **speech-set id** `docs/20` §7.4 and `docs/21`
§5 already decode. Two of the three address it as
`mov byte [reg + 0x0051F2F5]`, which is the persistent roster plus `0x55`, so
the field comes off the encoding and not off the value. `docs/10` §5.8 already
said the byte was rolled; the generator was the missing half, and it is the
presentation one. `aGenerateUnitElement` does not roll for unit type 24 at all:
it writes a fixed 12, `spidy`.

The fourth caller, `0x004160F0`, draws from **both** streams because it does
both jobs — the counted one for a candidate spawn tile, the uncounted one for
an effect argument. The split `docs/22` §3.2 describes is kept inside it.

One consequence worth carrying: the roster **is saved**, so a wall-clock-seeded
byte reaches the save file. A remake keeps it out of the canonical hash, not
out of the save.

### 17.5 What this pass cost

| | |
|---|---|
| `blob_tables.py --check` | 407 -> **423**, all static |
| `blob_gold.py --check` | 115 -> **161** |
| `godot/run_tests.sh` | 1 860 -> **1 865** checks, 31 suites |
| New capture phase | `hooks`, five services, one attempt |
| New module | `tools/inclib/eng3d.py` and `godot/game/fx/eng3d_geometry.gd` |
| `CONVERTER_VERSION` | 0.10.0 -> **0.11.0**, `tables/trig.json` added, cache republished |
| `core/` delta | **zero** |
| Mutation battery | 205 mutations, **205 caught**, 0 missed |
| Open questions | 39 -> **37** (`22` 1 -> 0, `28` 2 -> 1) |

The battery found two of its own blind spots again, and both were the same
shape as §16.6's: a constant that is *described* rather than *read*.
`SINE_SCALE` is never multiplied by anything, because the table is loaded and
not generated, and `COSINE_OFFSET` shifts a table index by one, which moves no
captured angle. Neither is excluded; both now have a property a perturbation
breaks — the table's peak **is** the scale, and the cosine window **is** the
sine table a quarter turn along.

It also cost a run. Editing a walked file while the battery is running is
silently destructive: the restore is a whole-file write, so it discards the
edit, and every number taken during the window is meaningless — one run
reported twenty-four pins as missed that the previous run had caught. The rule
is that a running battery holds an exclusive lock on the files it walks **and**
on the fixtures its checks read.

The oracle boundary moved for the first time in this layer: the orientation
service is the engine's own arithmetic on both sides of the diff, where it had
been an invented substitute on both sides. The arms did not move and are not
claimed to have.

**Still open, and stated as such.** Eng3d's three-angle matrix builder is
recorded and not reproduced. Eleven of the fourteen drawing creators have no
per-record recipe because their stream is not consumed at a fixed rate — that
is a measurement, not a fit waiting to be found, but it does mean their
trajectories remain the remake's own. And the two Eng3d entry points behind
`0x004039A0` are runtime function pointers whose targets were read as bytes and
not identified as exports; naming them wants a second capture or a walk of
`Eng3d.dll`'s own export table.

*(§18 closes all four of those, and one of them by doing exactly what the last
sentence above suggested.)*

## 18. The four residues, closed — 2026-09-01

§17 ended on four things it could not do. Three of them were not hard; they
were mis-stated. The fourth was hard and is now done, and it found two bugs.

### 18.1 The three-angle matrix builder — 8/8, and three reasons it had failed

`0x004039A0` is a marshaller. `Incubation.exe` reads three signed words out of
the caller's structure, calls **ordinal 13** of `Eng3d.dll` to build the
matrix, calls **ordinal 15** to push the vector through it, and returns 1. All
the arithmetic is in the DLL, and every attempt to reproduce it from the
caller was reasoning about the wrong file.

Three properties had to be right **together**, and getting any one of them
wrong reproduces at most three of the eight captured cases:

1. **The angles are negated before they index the table.** The body opens
   `neg ebx / neg ecx / neg edx` and only then masks with `0xFFF`. Because the
   products floor, negating before is not negating after: four of the eight
   differ by exactly one unit on that alone.
2. **Its products floor; `0x004039F0`'s truncate.** This builder uses a 64-bit
   `imul` with `shrd eax, edx, 14`; its neighbour twelve bytes away uses a
   32-bit `imul` and the `cdq / and edx, 0x3FFF` idiom. Two roundings inside
   one call was already §17.1's finding for `0x00403AA0`; there are three
   sites of it, not two.
3. **The chained triple products shift at every step**, `sh(sh(s·s)·s)`.
   Shifting once at the end puts the entries six orders of magnitude out.

And `_E3D_c_rotate_coordinate` reads the matrix **by column**. That last one
also explains a thing that had looked fine: `orient` reproduced twenty
captured pairs while *both* halves of its Q14 step were transposed, because a
transposed read of a transposed build cancels — and `0x00403AA0` passes
`matrix(0, -yaw)`, the `neg eax` at `0x00403ACF`, which is the third sign that
was silently absorbing the error. Adding a second builder is what made it
visible. `tools/inclib/eng3d.py` and `godot/game/fx/eng3d_geometry.gd` are the
two transcriptions; 8/8 against the capture.

**This corrects a delivered spec.** [`30` §2.5](30-eng3d-ascii-formats.md)
already carried "the exact matrix, if you want bit-identical results" — the
same nine expressions, read statically out of `fcn.00411bf6` — and taken
literally it misses four of the eight. The static reading had the shape right
and the arithmetic wrong, which is the class of error a capture exists to
catch. It is corrected in place.

### 18.2 The two entry points — named without a capture at all

§17 said naming them "wants a second capture or a walk of `Eng3d.dll`'s own
export table". It wanted neither. `Incubation.exe` resolves them with
`GetProcAddress` and the ordinal written out as **decimal text**, so
`push 0x004BF9F8` is the string `"13"` and the caller names them itself:

| Global | Ordinal | Export |
|---|---|---|
| `0x004FA4E4` | 13 | `_E3D_init_matrix_RzRxRy` |
| `0x004F84D4` | 15 | `_E3D_c_rotate_coordinate` |
| `0x004FA4E0` | 27 | `_E3D_calc_angle_dx_dy` |
| `0x004F84D8` | 28 | `_E3D_fsin` |
| `0x004FA4DC` | 29 | `_E3D_fcos` |

Three readings agree and none shares a step with the others: the literal in
the caller, the export table in the callee, and the captured thunk bytes,
which occur exactly once in the shipped DLL and at that export's own RVA —
with all five pointers minus their RVAs giving one module base.

A free result came with it. Ordinal 14 is `_E3D_init_matrix_RyRxRz`; the
start-up resolver asks for it like it asks for 86 of the DLL's 89 exports and
stores it in `0x004FA4A0` — and **nothing in `.text` calls or even loads that
slot**. [`30` §2.5](30-eng3d-ascii-formats.md) item 7 concluded from the joint
opcodes that both builders the shipped data reaches build `RzRxRy`; the call
graph says the stronger thing.

### 18.3 The eleven creators — five, three, three, and a fitter with two bugs

The residue was "eleven of the fourteen drawing creators have no per-record
recipe". Two of the reasons for that were bugs in the solver, not properties
of the engine:

* it had **no scale**. The engine truncates with `ftol` and *then* shifts, so
  a column is `scale * int(base + span·f)`; `0x0042ACF0`'s loop is thirty
  iterations of `aRandom(5, 10) << 5` and two `aRandom(-10, 20) << 4`, which
  is also exactly the ninety draws the seed delta counts. It carries a full
  recipe now, confirmed twice over — by the fit and by the disassembly.
* its **stride loop broke out of itself** the first time an offset ran past
  the end of the draw list, so nothing past stride 1 at a low offset was ever
  tried. The empty result that produced had been quoted as a measurement.

And two shapes were being looked for in the wrong place, because they are not
draws:

* **the loop counter.** Three creators stagger `delay` as `index / k` — a
  signed divide, `cdq / sub eax, edx / sar eax, 1` for k = 2.
* **the direction service.** Three take their velocity from `0x0046D400` and
  a fixed 1600. §17.1's finding that that routine is *not normalised* leaves a
  signature nothing else makes: **every** one of their 33 records carries
  `|vx|` or `|vy|` equal to 1600 exactly, and none of `0x0042ACF0`'s drawn
  velocities ever lands on it. So closing the service closed half of this.

What is left is a residue of ten creators rather than eleven whole ones, and
`native.draws_unstructured` now pins the list by name — it used to compare the
tuple against its own de-duplication, which is true of every tuple without
repeats, so deleting an entry passed silently.

### 18.4 The arms, stepped inside the engine

This is the one that was actually hard, and it is the one that paid.

`tools/blob_gold.py` gained two phase families. Both load the save, reset the
pool, run one creator and read all twelve 88-byte records; then `ticks_*`
calls **the engine's own frame sweep**, `aCheckInBlobObjects` `0x0041E3D0`,
eight times, and `arms_*` calls `aBlob_Update` `0x0041E500` per record
instead. The second exists because the sweep hands every non-sprite record to
Eng3d's `0x00403CC0` before ticking it, and outside an open render frame that
faults — deterministically, on the first sweep, for any creator whose records
are class 0. The check-in is not part of the arm, so skipping it is the more
precise measurement of the two.

Twenty-three creator pools landed, eight rounds each. The model is re-seeded
from the **measured** second-generator seed at the start of every round: the
engine walks the pool by ascending index and so does the transcription, so the
prefix of the stream is the same and a slot that drew in an earlier round
cannot drift the comparison.

| | |
|---|---|
| Arms a shot can populate at all | **24** of 74 |
| Reproduce the engine's record field for field | **22** |
| Stepped and disagreeing | **2** |
| Untouched by any measurement | **50** |

**Two real errors, both invisible to any amount of re-reading.**

* **Kind 11 does not delete itself.** [`28` §7.7](28-effects-and-sound.md)'s
  arm table listed it as the one self-deleting arm and this transcription
  followed the table. `0x004207B6` ends `mov eax, 1 / ret`; the
  `aDeleteBlobObject` call at `0x004207F8` two instructions later is the
  **wrapper's** expiry path, which every arm falls past and none enters. The
  engine's record kept moving, gravity-bitten and spinning, where the model
  had already removed it. Removal is the wrapper's, always.
* **Kind 8 draws `aRandom(0, 0xFFF)`, not `0x1000`.** Three literals at
  `0x00420543`, `0x0042055B` and `0x00420576`. One unit high on about a
  quarter of the draws, in a rotation word — the exact shape of defect that
  survives every structural check ever written for it.

**The two that disagree are named rather than rounded off.** Arms 25 and 58
(kinds 26 and 61) are seekers: their arm asks the unit map where its target is
and the capture's adapter answers nothing. Feeding them the save's own unit
positions does not reproduce the engine's first tick either, so what the engine
handed them is **UNVERIFIED** and `_seek`'s arithmetic is not cleared by this
capture. That is a new, specific open item where there had been a vague one.

**Two things about the comparison that had to be got right, and one that
nearly was not.** A freed slot is reused *within the same round* — the engine
walks slots in ascending order, so a blob that spawns while slot 1 is being
ticked lands in slot 1 the moment slot 1 is freed later in that round, and
often with the same kind, since a kind-75 emitter spawns more kind 75.
Comparing on compares two unrelated records. The tell is **life**: the wrapper
decrements it by exactly one per tick and holds it only at the immortal
`0xFF`, so a record whose life is neither `was` nor `was - 1` is not the
record that was there before. That rule is honest in both directions — an arm
that wrongly deletes early still fails, because the engine's record for its
slot *is* a continuation, and that is how kind 11 was caught rather than
excused. And because a stopping rule that stopped too eagerly would report 24
of 24 in silence, the check hands the same machinery a model started one unit
wrong and requires it to say so.

**The boundary the suites print does not move.** `test_blob.gd` still says
`executable-Python`, because that suite compares GDScript against Python and
not against the engine. The stronger statement is *transitive* and per arm:
for those 22, the engine agrees with the Python here and the Python agrees
with the GDScript there. The fixture carries both lists and the suite names
which — a blanket `native-runtime` label would be exactly the overclaim this
project exists to avoid.

### 18.5 What tested the new pins

An **in-memory** mutation battery rather than a file-walking one: each new
constant in `blob_gold.py`, `blob_runtime.py` and `inclib/eng3d.py` is
perturbed in the loaded module and `--check` is required to fail. 109
mutations, 97 caught. The twelve that are not are all **capture-plan**
constants — the RNG entry points the plans read, the group size, the start-up
probe's own numbers — which a run against a finished capture structurally
cannot exercise, because they are only used while *taking* one. Doing it in
memory also sidesteps the hazard §17 recorded at the cost of a whole run:
nothing on disk is written, so nothing on disk can be clobbered.

Three of the misses were real and were fixed rather than excused, and one was
a check that checked nothing: `native.draws_unstructured` compared its tuple
against its own de-duplication, so deleting a creator passed silently. The
two recipe families and the tick coverage are now pinned by count as well as
by name, and `TICK_FIELDS` is pinned against the whole record `parse_records`
reads — a field quietly dropped from the diff is a field the engine is no
longer consulted about, and no count would have moved.

### 18.6 What §18 left open

*(Two of these four closed on 2026-09-01; see §19.)*

* ~~**`_seek` is not cleared.**~~ Closed — [`28` §7.7.1](28-effects-and-sound.md).
* ~~**Fifty arms have never been stepped.** ... reaching them wants writing
  records into the pool directly, which is a different and more invasive
  experiment.~~ Closed — it is one byte, and ten of the fifty were wrong; §20.
* ~~**Ten creators keep a residue** of fields with no named mechanism, per
  §18.3.~~ Closed — they wanted reading, not fitting; §22.
* ~~One creator's pool, `0x00428200`'s, had to go through `arms_*` rather than
  the sweep even though its own records are sprites: one of its arms spawns a
  model blob.~~ Right in substance, wrong in the attribution, and it does have
  a static answer — §19.2.

| | |
|---|---|
| `blob_gold.py --check` | 161 -> **195** |
| `run_tests.sh` | 1870 -> **1875** |
| Open questions | 37 -> **38** — the four residues all lived inside closure texts rather than in numbered questions, so closing them moved nothing; §18.4 **found** one, and `28` gains it as item 3 |

## 19. 2026-09-01 — the seekers, and why one pool killed the sweep

Two of §18.6's four are closed, and **neither needed a new capture**. Both
were answerable from the arms' own instructions plus the two phases already
taken, which is the same pattern §18 itself ran into: the premise was wrong,
not the effort insufficient.

### 19.1 The seekers reproduce the engine — arms 25 and 58

[`28` §7.7.1](28-effects-and-sound.md) carries the finding in full. In short,
`_seek` was wrong in three separate places, and the capture could not have
told them apart because all three are wrong on the very first tick:

1. the steer comes from `0x0046D400`, whose first two components are divided
   by whichever of `|dx|` and `|dy|` is larger — **not** a unit vector. The
   old model normalised by the true distance;
2. the orientation call takes the record's **next position**, not the target,
   so a seeker points along its own path;
3. the arrival writes `life = 0` only; the global word is each arm's, and
   kind 27's sits inside the arrival branch while kinds 26 and 61 raise it for
   a spent life too.

The target was found by elimination rather than by reading it: replaying the
18 stepped transitions against the 15 object positions this save holds leaves
exactly one that reproduces the engine's next record, on every one of the 18.
That is `seek.target_is_unique`, and the narrower thing still open — nobody
read the `[unit + 0x4B]` byte — is stated as item 3's residue rather than
folded away.

**`TICK_ARMS_UNRESOLVED` is now empty**, and every stepped arm agrees. The
suites still print `executable-Python`: 24 of 74 is what the fixture's
`native_arms` says, and it is still a transitive claim per arm.

### 19.2 The pool that killed the sweep is `aBlob_CreateLaser`

`0x00428200` is `aBlob_CreateLaser`, and it builds **two** kinds, not one:
kind 70 at `0x004284D3` and kind 71 at `0x00428544`, both class 2, both life
20. The twelve records the plan reads are all kind 70 — the kind 71 records
sit past the window — which is why the pool looked like a sprite pool whose
arm somehow spawned geometry. It does not: kind 70's arm (`0x0041F427`,
shared with kind 66) draws `aRandom(3, 10)` into `+0x54` and returns.

**Kind 71's arm** (`0x0041F448`) is the one that spawns, and it calls
`aBlob_CreateLaserHit2` `0x0042A9D0`, which builds a class **0** record with
`A_SPARK.3DI` at `0x0042AB17`. The sweep's own test at `0x0041E432` skips
Eng3d's `0x00403CC0` for class 2 and 3 and for any record whose `delay` is
still counting, so the model record is handed to the renderer on the sweep
*after* it appears — the fourth, which is exactly where `ticks_0x00428200`
faults.

Two checks fall out of that and are worth keeping in mind rather than
guessing again: every pool whose `ticks_` phase survived all eight sweeps
holds only class-2 records, and every pool that faulted on the *first* sweep
holds class 0 or 1. "Try the sweep and fall back" stays the rule, but the
fallback is now explained rather than superstitious.

## 20. 2026-09-01 — the other fifty arms, and the ten defects in them

§18.6's second residue said reaching the fifty arms no creator fills "wants
writing records into the pool directly, which is a different and more invasive
experiment". It is a **one-byte** experiment: `+0x44` is the jump-table index,
so a donor record with a foreign kind in it is a record of that kind as far as
`aBlob_Update` is concerned.

`tools/blob_gold.py` gained the `poked_*` family. One donor pool
(`aBlob_SparkingPlug` `0x0042ACF0` — the one reachable creator that fills
twelve **class-0** slots with a model handle, so a model-posing arm has
something to dereference), then two adjacent bytes of six records rewritten
through the game's own imported `memcpy` — `+0x44` is the jump-table index and
`+0x45` is `life` — then `aBlob_Update` per record per round with the pool and
the second generator's seed read back after **every call** rather than once per
round. Nine plans, eight rounds, 50 arms, **397** single-arm comparisons. No
plan faulted.

The `life` half of that write is there because a mutation battery caught what
the first attempt could not see. With the donor's own `life` of 30 and four
rounds, kind 76's `life <= 4` branch is never entered: perturbing its divisor
changed nothing and the check stayed green. A poked `life` of six over eight
rounds crosses that gate and reaches `life == 0`, where the terminal arms
spawn, morph and hand the record back — and `poked.life_written` and
`poked.rounds_per_phase` pin both numbers, so a thinner capture fails rather
than checking less.

What it measures is the **arm**; the record it is handed is a donor's, so the
arguments a creator would have passed are not measured. That is a weaker claim
than §18.4's and the fixture keeps the two lists apart for exactly that reason.

### 20.1 Ten of the fifty disagreed, and nine of them were this file's fault

| Arm | Kind | What was wrong | What it is |
|---|---|---|---|
| 0, 2, 28 | 0, 2, 29 | the rotation draws were `aRandom(0, 0xFFF)` | `0x1000` — **only** kind 8's arm pushes `0xFFF` |
| 13 | 13 | velocity damped by a tenth | a **twentieth**: `sar edx, 3` after `0x66666667` |
| 19 | 19 | damped by a tenth | a **fifth**: `sar edx, 1` |
| 57 | 60 | damped by a sixth | a **third**: `0x55555556` with no shift |
| 72 | 76 | one move; `+0x28` set to 2; `z += vz/3` | **two** moves while `life > 4`; `+0x24` set to 2; `z −= vz/3` |
| 14 | 14 | no rotation at all | the delta is spun about the vertical by `0x004039A0` through `life·20` or `(life−22)·10` |
| 36 | 37 | an orientation call and nothing else | the same spin at a fixed `0x66`, subtracted rather than added |

The tenth is kind 27, the seeker, and it is §20.2 — an arm this file had
right and a helper it did not.

The first row is a **regression this project introduced**, and it is worth
saying so plainly. §18.4 found that kind 8's arm draws `aRandom(0, 0xFFF)` and
the correction was copied to all four arms that share the wording; three of
them push `0x1000` and are two hundred bytes apart in the binary. Nothing could
catch it, because no creator fills kinds 0, 2 or 29 — until something stepped
them.

The last two rows are the interesting ones. Kinds 14 and 37 are the **only**
arms that call `0x004039A0`, Eng3d's three-angle matrix, and §17 had just
finished measuring that service without noticing that two arms depend on it.
Both spin the horizontal delta to a point held in the velocity slots and place
the record at the point plus (kind 14) or minus (kind 37) the turned delta.

### 20.2 And `_ftol` returns the **low dword**

The fiftieth arm to fall was kind 27, a seeker, and it fell for a reason worth
recording. Its donor record sits exactly on its target's column, so
`0x0046D400` answers `NaN, NaN, ±inf` — the `hooks` phase measured those three
deltas and they are genuinely degenerate. The model steered by `INT_MIN`; the
engine steered by **nothing**.

MSVC's `_ftol` is an `fistp` to a **qword** and returns the pair in `edx:eax`,
and every caller here keeps `eax`. x87's 64-bit integer indefinite is
`0x8000000000000000`, whose low dword is zero. So the invalid conversion is a
zero, not an `INT_MIN`, and the branch that `docs/28` §7.7.1 had marked
**UNVERIFIED** is now measured — by an arm nothing had ever run.

### 20.3 Both twins, and what the suites print

`tools/blob_runtime.py` and `godot/game/fx/blob_kinds.gd` carry all ten fixes;
`BlobHooks` gained a `rotate` service beside `orient` and `direction`, and
`orient` now takes a **source point** rather than the record, because kinds 14
and 37 orient from the point in their velocity slots and not from where they
are.

The boundary the suites print does **not** move: `test_blob.gd` still says
`executable-Python`, because it compares GDScript against Python. What changed
is the transitive claim behind it, which is now the whole table:

| | |
|---|---|
| Arms stepped inside `Incubation.exe` | **74 of 74** |
| …with records a creator built | 24 (`native_arms`) |
| …with a donor record, kind byte rewritten | 50 (`poked_arms`) |
| Stepped and disagreeing | **0** |

### 20.4 The unit-map slot, at a second point

§19.1 identified the seekers' target by elimination at one value of `+0x54`.
The poked kind-27 record carries the donor's, which is **0**, and sweeping the
same fifteen object positions leaves object 0 — uniquely. Two points is not a
reading of `[unit + 0x4B]`, and `docs/28` §12 item 3's residue still says so,
but it is two rather than one.

### 20.5 One more service had to be measured first

Two of the fifty disagreed on the second capture and neither was a
transcription bug. Kinds 16 and 17 are the **swap-model** arms: they call
`0x004038F0` with a name and store the answer straight into `+0x0C`. The
adapter answered with an index into its own three-name list, the engine with a
real handle, and the diff was a diff of the adapter.

That is the same shape as the seekers' target, and it gets the same treatment:
a small `models` phase asks the engine's own lookup for each of the three names
after loading the save, and the check resolves through **that**. `A_BLUT5.3DI`
is 105, `A_BLUT6.3DI` 106, `A_HIT2.3DI` 144. `poked.model_handles` pins that
all three resolve, so a capture without the phase fails rather than comparing
invented numbers.

The rule this is the second instance of: **a field an arm copies out of a
service is not evidence about the arm until the service is measured.** Getting
it wrong in the other direction — "the arm is broken" — would have cost a day.

| | |
|---|---|
| `blob_gold.py --check` | 195 -> **215** |
| `run_tests.sh` | 1875 -> **1876** |
| Mutation battery over the ten fixes | 11 mutants, 11 caught |
| Open questions | 38 -> **37** (`28` item 3 closes; its residue is named in place) |

## 21. 2026-09-01 — how much of each arm the engine actually ran

§20 ends with "all fifty reproduce the engine". That sentence is true and it
is about *records*, not about arms: an arm is a function with branches, a
poked record is **one point of its input space**, and a branch no input
reached was compared against nothing. The defect §18.5's mutation battery
found in kind 76 was exactly that shape — a `life <= 4` branch that a donor's
`life` of 30 cannot reach in four rounds — and it was found by luck rather
than by looking.

So the capture now measures its own reach.

### 21.1 The instrument, and why it is honest as a proxy

`tools/blob_gold.py` installs a line tracer **around the comparison itself**
(`ArmLines`) rather than around a run of its own: a second run would exercise
a different set of inputs and say nothing about the one that agreed with the
engine. For each of the 74 arms it records which lines of
`tools/blob_runtime.py`'s transcription the replay executed.

It is **Python line coverage** and the code says so. The arms are a
transcription and the lines are the transcription's, not the engine's basic
blocks. It is a fair proxy for one specific reason: the same replay it
measures is the one that reproduces the engine's records field for field, so
a line the replay ran is a line the engine ran. The converse does not hold —
a line no input reached might be right and might be wrong, which is the whole
point of naming it.

The first pass reached **341 of 385** lines. Three vectors closed most of the
rest:

| Vector | What it is for |
|---|---|
| `life 6`, 8 rounds (the original) | the terminal branches of a short-lived record |
| `life 12`, `aux 10`, 14 rounds, all fifty arms | `life == 10` **and** `life == 0` in one plan — eight rounds cannot do both — plus kind 74's `aux == 10` |
| eight one-arm probes | branches a uniform vector cannot reach at all: an `aux` naming a **dead** unit slot, a life of sixty, a record standing on its own target, a record with position and velocity zeroed |

The dead unit slot is not invented. `[unit + 0x4B]` is read now (§22.1
below and `docs/28` §7.7.1), and slot 14 of `_6_.sav` names an object
`aGetStdObjectPosition` refuses — which is the only way to reach the three
seekers' `target_missing` return from a record field.

**377 of 385**, 72 of 74 arms complete. `coverage.arm_lines`,
`coverage.arms_complete` and `coverage.uncovered_lines` pin all three, the
last **by source text rather than line number**, so an edit elsewhere in the
file does not break a pin for a reason that has nothing to do with it.

### 21.2 The eight that remain, and the one that is a divergence

Neither group is a thin capture.

**Arm 56** (kind 59, the emitter) has a six-line branch gated on a byte
`0x00461E80` returns. It is not in the record, so **no vector written into a
record can reach it**. Named rather than left implied. *§23.3 reaches it by
writing what the byte comes from, and identifies what that is.*

**Arm 39** (kind 41) is the interesting one, and it was found the hard way.
The second sweep vector originally also wrote `vx = 0`, because that is the
sole gate on kind 41's other branch. The plan died: `poked_v1_04` reached the
anchor, measured three arms, and then `Incubation.exe` faulted on the fourth
call. The arm is four instructions:

```
0x0041E55A  mov  eax, 0x200
0x0041E55F  cdq
0x0041E560  idiv dword [esi+0x48]     ; the record's vx
0x0041E563  add  word [esi+0x28], ax
```

There is **no test in front of the divide**. A record with no `vx` raises #DE
and takes the process with it. The guard in `blob_runtime._kind_41` — and in
`blob_kinds.gd` — is therefore the **port's**, not the engine's: a deliberate
divergence, where the original faults and the port carries on and says so
through an event. The comment in both files used to read "a division by zero
in the original too, so the arm is written to notice rather than to crash",
which is right about the arithmetic and wrong about what the original does
with it.

The write was removed from the sweep vector because a plan that faults costs
the arms after it, not because the answer was unwelcome; the reading is kept
as `seek.dividing_arm_has_no_guard`, which pins all four instruction bytes.

**The rule this is the third instance of**: *a branch that has never been
executed is not a transcription, it is a guess with good handwriting.* Ten of
the fifty arms were wrong when they were first stepped (§20.1); kind 76's
divisor was wrong until a longer life reached it; and kind 41's guard was
invented. Every one of them read plausibly.

## 22. 2026-09-01 — the ten creators, read instead of fitted

`docs/28` §7.6.1's last standing residue was: *ten creators keep a residue of
fields with no named mechanism.* The mechanism was there all along. What was
missing was the decision to stop searching the draw stream for it.

### 22.1 What "no mechanism" actually meant

A *recipe* is a fit: field `f` of record `i` is `scale * ftol(base + span *
draw[cycle*i + slot])`. That shape describes a creator that builds one kind of
record in a fixed loop and nothing else. Five of the fourteen drawing creators
fit it. The other ten did not, and the reasons were **all** properties of the
creators rather than of the data:

* one adds the loop counter to its draw — `call 0x004638E0 / fadd qword
  [esp+0x2C] / _ftol`, the addend being the ring index converted with `fild`,
  so `aux` climbs by two a ring on top of the draw. (The addition is inside
  the conversion; for this creator's positive range that is the same number as
  adding after it, and a mutant that moves it is not caught. The shape is what
  defeated the fit, not the rounding.);
* two **call another creator** before they place anything of their own, so
  their first two hundred draws are that creator's and the twelve records the
  capture reads back are entirely its;
* one places its two records **perpendicular** to the line of fire — the `x`
  term reads the *`y`* direction ratio and the `y` term reads the `x`. No
  axis-by-axis recipe can express a term that reads a different axis;
* one builds records of three kinds in two loops with different laws;
* and the constructor `0x00420950` **silently drops a record whose `life` is
  zero** — `mov al, [esp+0x28] / test al, al / je` — so one creator's first
  three records never exist and the pool starts with its second loop. A fit
  looking for "the first record" was looking at the fourth.

### 22.2 The programs

`tools/inclib/blob_creators.py` transcribes all ten, instruction by
instruction, out of the disassembly and the doubles at `0x004B12xx`. Each is a
function of the arguments the capture passed, the inputs the engine read
before it drew anything, and a draw source.

Those inputs are **measured**, by two read-only phases this closure added:

* `origins` — the whole control map, the standard object array as the records
  hold it, and `0x0047AD30`'s height for both argument tiles;
* `symbols` — the two objects the cells at `+5` name, through
  `aGetSymbolObjectPtr` `0x00404C40`.

The second exists because of a trap worth recording: `aGetSymbolObjectPtr` and
`aGetStdObjectPosition` are **two different tables**. The cell at the
capture's source tile names symbol 139 while the standard object standing
there is id 0, and symbol 139's `+0x18` is 0 where object 0's is 160. Feeding
a creator the position service's answer produces a plausible number and the
wrong z on every record it places.

**That gap of 160 then explained something it had nothing to do with**, which
is the second half of the lesson: §14.5's projectile finding read the two
creators' own `add eax, 0xA0` as this table difference, because on this one
capture the two are the same number. A coincidence between two measured
quantities is not evidence that one causes the other, and the way out was to
count the instruction rather than to fit the record. That is `docs/97` §20.5's rule for the
third time: a field copied out of a service is not evidence until the service
is measured.

### 22.3 What the check is, and what it reaches

`native.creator_program_records` replays each program from the **measured**
second-generator seed and compares every record the capture read back, field
for field. `native.creator_program_draws` and
`native.creator_program_seed_delta` compare the number of draws each program
takes against `aRandom2`'s seed either side of the call.

The second is the one that matters, because the capture reads only the pool's
first twelve records and two of these creators fill those twelve entirely
with a *nested* creator's output. The seed delta covers **every** record the
program builds, seen or not: a beam one dot too long takes a different number
of draws.

| Creator | Draws | Records dropped for a zero life | What it is |
|---|---|---|---|
| `0x00424D20` | 25 | 1 | machine gun: five bursts of two tracers, two casings and a puff |
| `0x00425810` | 90 | 0 | smoke trail: rings of six along the line of fire |
| `0x004264A0` | 3 | 0 | blizzard shot: two seekers, name chosen by a float compare |
| `0x00426F90` | 200 | 0 | green laser: sparks at the target, then a dotted beam |
| `0x00427410` | 203 | 0 | blue laser: the same, aimed at a scattered point |
| `0x00427810` | 7 | 3 | plasma beam: three heads and a trail of pairs |
| `0x00429180` | 144 | 0 | line fire: streaks, each with its own drawn speed |
| `0x00429A80` | 108 | 0 | smoke column: nine rings of three, rising |
| `0x0042A9D0` | 200 | 0 | sparks: one emitter and fifty sparks |
| `0x0042AF10` | 6 | 0 | blizzard hit: a flash and two tumbling shards |

All ten reproduce the engine's records exactly and all ten take exactly the
number of draws the seed says. `CREATOR_DRAWS_UNSTRUCTURED` and
`DRAWS_UNSTRUCTURED_PIN` are **empty**.

### 22.4 Which constants this capture actually pins

A program's constants are **read** out of the disassembly, so none is a guess.
That is not the same as saying the capture tests them. Perturbing each by one
and replaying — `native.creator_constants_discriminated` does exactly this, in
`--check`, so the claim is a measurement rather than an assurance — leaves
seven of the thirteen changing a captured record or a draw count and **six
that change nothing**:

| Constant | Why this capture cannot see it |
|---|---|
| `HEAD_SPEED` | belongs to the three records the constructor drops for a zero `life` |
| `DOT_SPEED` | belongs to records past the twelve a capture reads back — the nested creator fills them |
| `BEAM_BASE`, `BEAM_UNIT`, `TRAIL_UNIT` | divide a span of 6400; an off-by-one does not move the quotient |
| `HEAD_STEP` | shifts an orientation target by one unit, which does not move a 4096th |

This is the arm-line coverage of §21 one level down, and it gets the same
treatment: named, pinned, and measured in `--check` rather than asserted.

What it is **not** is a list waiting on a second capture. §23.1 works through
the six one at a time and finds that four of them cannot be discriminated by a
perturbation test at any span, and closes all six a different way: the value
is read back out of the shipped executable at a named address.

### 22.5 One thing this did not close — *closed in §23.2*

The velocities of three of them come from the direction service and a flat
speed; the positions of one come from the *perpendicular* of that direction.
Which of the service's three doubles is which axis was read off the stack for
nine of the ten, and for `0x00424D20` the argument pushes interleave with the
FPU loads so densely that the assignment was, when this section was written,
fixed by **matching against the capture** instead — over twelve records, four
record kinds and three bursts, which leaves one assignment standing but is a
fit and not a reading.

It is a reading now. §23.2 walks the frame.

| | |
|---|---|
| `blob_gold.py --check` | 215 -> **252** |
| Arm lines executed against the engine | 341 -> **377** of 385 |
| Creators with no named mechanism | 10 -> **0** |
| Open questions | unchanged at **37**; `28` §12 item 3's residue is closed in place |

## 23. 2026-09-01 — the three residues, and what each one actually needed

§21 and §22 each ended by naming what they had *not* closed. Three items:
six creator constants no captured record exercises, one creator whose
component-to-axis mapping was fitted rather than read, and six arm lines
behind a branch no record can select. They needed three different
instruments, and only one of them was another capture.

### 23.1 The six constants — the instrument was wrong, not missing

§22.4 listed six constants that `native.creator_constants_discriminated`
cannot tell from a neighbour and said they were "shrinkable by a capture with
a second pair of tiles". Working through them one at a time says otherwise.

| Constant | What a ±1 perturbation does | Would another capture see it? |
|---|---|---|
| `HEAD_STEP` | shifts an orientation *target* by one unit; the answer is in 4096ths of a circle | **no**, at any span — the result is quantised |
| `BEAM_UNIT`, `BEAM_BASE`, `TRAIL_UNIT` | move an integer quotient only when the dividend sits on the boundary | **almost never**, at any span |
| `HEAD_SPEED` | rides on three records `0x00420950` drops for a zero `life` | only with a target far enough that `count >= 2` |
| `DOT_SPEED` | rides on records past the twelve a read window holds | only with a wider read window |

So four of the six are not a thin capture at all: a perturbation test is the
wrong instrument for a divisor or for a value that is quantised before it is
stored, and no amount of Wine changes that.

The right instrument is static, and it is the one this project already uses
for the creator arities — pinned in `blob_tables.py` "whether or not anybody
has Wine". `CREATOR_CONSTANT_SITES` names, for every one of the thirteen, the
address in the shipped `Incubation.exe` that holds it and how that address
holds it:

* **nine names are doubles** in the constant block at `0x004B12xx` — eleven
  sites, because two names read a negative cell and its positive twin — and
  the check requires an `fmul qword [cell]` for each to exist **inside the
  creator the transcription attributes it to**, bounded by the next creator's
  entry, so a site cannot be silently credited to the routine after it;
* **three sites are subtracted immediates** — `lea ecx, [eax - 0xC80]` at
  `0x004272A0`, `lea ecx, [eax - 0x960]` at `0x004279DA`,
  `add esi, 0xFFFFF380` at `0x00425AAC`;
* **two are not in the bytes at all.** `0x00426F90` divides by 2400 as
  `mov eax, 0x1B4E81B5 / imul ecx / sar edx, 8` and `0x00425810` divides by
  960 as `mov eax, 0x88888889 / imul esi / add edx, esi / sar edx, 9`. There
  is no `0x960` and no `0x3C0` to grep for. The check takes the divisor the
  multiplier implies — the compiler chose `ceil(2 ** (32 + shift) / d)` — and
  then **replays** the sequence, the multiply, the two-term form's add, the
  shift and the `shr`/`add` sign fixup, over 85715 dividends either side of
  zero, requiring it to equal a truncating divide for every one of them;
* **one is a code sequence**: `TRACER_LEAN`'s 200 is `lea`/`lea`/`shl` over a
  `sar`, `5 * 5 * 32 >> 2`, read out of the four instructions.

One correction the table forced: `DOT_SPEED` and the positive half of
`CASING_SPEED` are **the same cell**, `0x004B12B0`, read by two different
creators. Thirteen Python names stand over twelve distinct cells. The names
stay one-per-use, because "does this capture exercise this use" is the
question the discrimination check answers and it is a different question from
"is this the number the binary holds".

`native.creator_constants_discriminated` is unchanged and still says seven of
thirteen. That is the honest reach of the capture and it should keep saying
so. What has changed is that the other six are no longer standing on nothing.

### 23.2 The machine gun's axes — read off the stack

`0x00424D20` places its two tracers **perpendicular** to the line of fire:
the `x` term reads the `y` ratio and the `y` term the `x`. §22.5 recorded
that the assignment had been fixed by matching records rather than read,
because the argument pushes interleave with the FPU loads.

They interleave; they do not hide anything. The frame settles to one baseline
after the `add esp, 0x28` at `0x00424FE4` and the `add esp, 0x24` at
`0x004250E5` — call it `S` — and `0x00424FC6` handed the direction service
its three out-pointers relative to that same baseline, at `S+0x20`, `S+0x28`
and `S+0x38`. Every term then names its component out loud: each is an
`fld qword [esp+disp]`, and `disp` minus the stack depth at that instruction
is the slot.

| Site | `disp` | depth | slot | component | role |
|---|---|---|---|---|---|
| `0x00425100` | `0x2C` | `0x0C` | `S+0x20` | `d0` | `lean`, into **y** |
| `0x0042511A` | `0x54` | `0x2C` | `S+0x28` | `d1` | `spread` ×`-640`, into **y** |
| `0x0042513A` | `0x54` | `0x2C` | `S+0x28` | `d1` | `lean`, into **x** |
| `0x00425152` | `0x50` | `0x30` | `S+0x20` | `d0` | `spread` ×`+640`, into **x** |
| `0x0042519F` | `0x20` | `0x00` | `S+0x20` | `d0` | `lean`, into **y** |
| `0x004251C1` | `0x54` | `0x2C` | `S+0x28` | `d1` | `spread` ×`+640`, into **y** |
| `0x004251E1` | `0x54` | `0x2C` | `S+0x28` | `d1` | `lean`, into **x** |
| `0x004251F9` | `0x50` | `0x30` | `S+0x20` | `d0` | `spread` ×`-640`, into **x** |

Two properties fall straight out of the table and both are checked rather
than asserted: inside one record a coordinate's two terms name **different**
components — which is what "perpendicular" means and what an axis-by-axis
recipe cannot write — and the second record is the first with its two spread
cells **exchanged**, not negated. The transcription already had all of this
right; what it did not have was a reason other than the records.

`TRACER_AXIS_TERMS` pins the eight sites and `TRACER_AXIS_BLOCKS` digests the
two blocks they were read out of, so a change anywhere in those 304 bytes —
including one the term table has no column for — re-opens the reading instead
of passing under it.

### 23.3 Kind 59's other half — the byte is the display mode

Six of the eight uncovered arm lines were arm 56's, and §21.2 disposed of
them as "gated on a byte `0x00461E80` returns... no vector written into a
record can reach it". True, and incomplete: nobody had asked what the byte
*is*.

`0x00461E80` is two instructions.

```
0x00461E80  mov eax, dword [0x00512A78]
0x00461E85  ret
```

`0x00512A78` is the **output system's** mode id. `0x00461310` is
`aCreateOutputSystem` — `trace_names.py` gets that name from a call site's own
`CHECK` push — and it takes a mode argument `0..11`, configures the display
through a five-case jump table and writes this global as its last act. What
each case writes and what it calls to make the surface:

| mode | surface created by | width × height | bytes/pixel | stride |
|---|---|---|---|---|
| 0 | nothing; windowed metrics from `GetSystemMetrics` | 640 × 480 | 1 | 640 |
| 0 | nothing | 320 × 200 | 1 | **640** |
| 1 | `aCreateMainDDObject` `0x00432CD0` | 640 × 480 | 1 | 640 |
| **2** | `aCreateMainDDObject` `0x00432CD0` | 640 × 480 | 2 | 1280 |
| **3** | `Eng3d.dll` ordinal 67 | 640 × 480 | 2 | 1280 |

Every cell of that table is read out of the instruction that carries it and
checked by `output.mode_table` — the immediate of a `mov r32, imm32` where a
register is stored, the immediate of the store where it is not — and
`output.mode_stores` requires each to be stored into the global its column
names, with each case's whole byte range digested so the register a pinned
store writes is still the one the pinned load filled. The last two columns were interpretations when §23.3 was first
written; §23.4 is the reading that replaced them.

And the routine called is now named. `[0x004FA514]` is zero in the shipped
file because `0x00401000` (`a3DEngine.cpp`, line 436) fills it at start-up:
it asks `Eng3d.dll` for the export whose ordinal is written out as the
**decimal string `"67"`** — the same `GetProcAddress`-by-decimal-text idiom
that names the five blob service hooks — and ordinal 67 of `Eng3d.dll` is
`_E3DCARD_open_3dcard_screen`. Mode 3 is the **3D accelerator** path: the
`E3DCARD` family (ordinals 67–82, 86–87) is the card layer, and if that
ordinal cannot be resolved the start-up code frees `Eng3d.dll` and reports
`"Function Id 67 not found!"`. Which card it is remains an inference — the
game ships `3DfxSpl*.dll` — but which *layer* does not.

So the effect is real and conditional: **kind 59 spawns a second emitter only
when the game is running on a 3D accelerator.** Wine runs it at mode 2, plain
DirectDraw, which is exactly why eight targeted vectors and two sweeps left
those six lines cold. That is not something any record could have revealed.

Reaching it needed the same move `docs/93` §11 used for the large-unit
clearance — write the state the branch reads. The `mode_59` plan takes the
global's reading, writes 3 into it through the game's own imported `memcpy`,
steps kind 59's arm at two donor slots under the two sweep vectors, and
writes the mode back. The restored value is a **pinned** one and not the
number just read — a plan's text is fixed before its own read happens — so
`mode.global_readings` pins the reading taken before the write as well, and a
host running some other display mode fails that check rather than quietly
having its mode replaced. Three checks, and the middle one is what makes
the other two mean anything:

* `mode.global_readings` — `[2, 3, 2]`: the mode before the write, after it,
  and after the restore. The middle value is the proof the branch *could*
  run; without it an agreeing arm would only show that both sides skipped it.
* `mode.arms_stepped` / `mode.arms_agree` — arm 56 runs and reproduces the
  engine's record field for field on the branch.
* `native.faults` stays empty, which is its own small correction: a plan that
  failed on one run and landed on the next used to keep its failure entry
  forever. The creator loop already cleared it; this one does now too.

The plan cost sixteen attempts across three invocations: ten that never
reached the anchor, then one that landed on its second — and the phase that
one produced was **thrown away**, because its first reading came back `2`
where the plan restored `0`. The restore had been written against an assumed
mode. Re-pinning it to the measured one and re-capturing landed on the fourth
attempt of the third invocation, and that is the phase in the fixture. The
attempts themselves are `docs/91` §1 again, an environment result rather than
a finding; the discarded phase is not, and is the reason
`mode.global_readings` pins all three readings rather than only the middle
one.

**Coverage:** 377 → **383 of 385**, 72 → **73 of 74** arms complete. The two
that remain are kind 41's, and they are a *divergence* rather than a gap: the
engine faults where the port returns, so there is nothing to compare.

**One product question this raises, and it is not decided silently.** The
remake's `blob_hooks.gd` reports mode 0, so it never spawns the second
emitter. That now has a reason rather than a default: the shipped DirectDraw
path — the one Wine runs and the one a player without the accelerator got —
does not spawn it either. Making the remake behave like mode 3 is a
`compat_flags`-shaped choice, not a bug fix, and it belongs in `docs/92` §7
if it is ever taken.

### 23.4 What `0x00512A9C` actually is

The mode table above had two columns named from their values: a number that
looked like a pitch because it was `width × 2` in the sixteen-bit modes, and a
byte that looked like bytes-per-pixel because it was 1 or 2. This project has
been bitten twice by a name arrived at that way — the fictitious 40×40 lattice
and kind 41's invented guard — so the interpretation was marked and left. Here
is the reading.

**It cannot be `width × bytes-per-pixel`.** The 320×200 case *initially*
writes a stride of **640** for a 320-pixel row at one byte a pixel
(`0x0046141F`, and the width is the `mov ecx, 0x140` at `0x004613CA`). A
derived quantity would say 320. A row that reserves more bytes than it holds
is a stride and nothing else, and this single row of the table is what rules
the alternative out — `output.stride_is_not_derived` computes it from what was
read, not from the pin beside it.

"Initially" matters and sharpens rather than weakens the point: the lock
below overwrites this global from the surface on every call, so what
`aCreateOutputSystem` leaves here is the author's own starting value — and
even *his* is not `width × bpp`.

**It is used as one, in both pixel sizes.** `0x00463C40` is the pixel plot. It
takes six arguments at `+4 +8 +0x0C +0x10 +0x14 +0x18`, and the roles are
read from what the arms do with them rather than from any symbol: `+4` is
added last and is the base, `+0x14` is the one multiplied and `+0x0C` the one
it multiplies — so `+0x0C` is the row and `+8`, added unscaled, the column.
`0x00463CC0` next door confirms which way round that is: it walks a
horizontal run and it is `[esp+8]` that its loop increments. The three arms
then disagree about the multiplied number in exactly the way a byte count
requires:

| arm | what it does with the stride | the store |
|---|---|---|
| format 0 | `imul` by the row, add the column | `mov byte [base + that]` |
| format 1 | `shr 1`, then `imul` by the row, add the column | `mov word [base + that*2]` |
| format 2 | the same, with the colour converted RGB565 → RGB555 | `mov word [base + that*2]` |

The eight-bit arm uses the number whole and indexes bytes; the sixteen-bit
arms **halve** it and index words. Both reach the same address only if it
counts **bytes per row**. `output.plot_arithmetic` decodes all three — it
finds the `imul`, follows its register back to the `mov r32, [esp+disp]` that
loaded it, notes any `shr r32, 1` between them and reads the store's operand
size and index scale — and nothing in that decoding is matched against an
expected displacement.

**And it arrives with the surface, not with the mode.** `0x004617B0` is the
lock: it sets a "locked" flag at `0x00512AA4`, puts the surface pointer in
`0x00512A98` and this number beside it in `0x00512A9C`, taking it from
`[obj + 0x28]` of the object `0x00432C30` returns; `0x00461880` is the unlock
and clears all three. Callers pass the pair around together — `0x00447F60`
keeps the lock's return value in `ebp` and hands `(ebp, stride)` to every
draw; `aFont.cpp`'s `0x00439BE0` stores the pair into a font record and its
renderer feeds both to the plot.

**And `+0x28` is `DDSURFACEDESC.lPitch`** — see §23.5, which is the half this
section originally left open.

Two neighbours fall out named as well:

* **`0x00512A60` is bytes per pixel.** `0x00461E90` is a six-way
  output-info getter — no symbol names it; its own error string for an index
  above five is `"unknown infotype"` — whose other five arms are the x and y
  offsets, the width, the height and one more, and `0x00512A60` is the only
  one of the six that masks its dword down to a byte. It is **index 2**, and
  that had to be read out of the jump table at `0x00461EE8`: the table's order
  is not the arms' order in the code, and taking the code order would have
  called it index 5. Then `0x004479DC` does `push 2 / call / cmp eax, 1 /
  jne` — a caller branching on "is this one byte a pixel" — and the far side
  of that branch, `0x00447A70`, multiplies a clipped horizontal extent by the
  same byte. A number you branch on being 1 and then multiply a pixel count
  by is a bytes-per-pixel.
* **`0x00512AA0` is the pixel format**, read by `0x00461E70` and switched on
  by the plot: 0 is eight-bit palettised, 1 a sixteen-bit word written as it
  comes, 2 a sixteen-bit word converted 565 → 555 (`and 0x1F` for blue, the
  rest shifted down one and masked to `0x7FE0`, which is precisely dropping
  green's low bit). Modes 1 and 2 do **not** hard-code it: they read it from
  the created surface at `[obj + 0xCC]`, so it is what the driver reported.
  Mode 3 hard-codes 1 and mode 0 hard-codes 0.

None of this needs Wine, so it lives in `blob_tables.py --check` beside the
creator arities and constants, in the always-run block.

### 23.5 `+0x28` is `DDSURFACEDESC.lPitch`

§23.4 read what the stride *means* and said plainly that it had not read
where it comes *from*: the lock takes it from `[obj + 0x28]` of whatever
`0x00432C30` returns, and nothing in this project had a reading of that
object's layout.

**There is no object.** `0x00432C30` is two instructions —
`mov eax, 0x004FEC80 / ret` — so it returns the **address of a static block**,
and the block is aLIB's DirectDraw module state: every routine that touches it
pushes `C:\aProject\aLIB\aDDraw.cpp` on its error path. `+0x00` is the
`LPDIRECTDRAW` that `DirectDrawCreate` fills (`0x00432D76` pushes the address
itself), `+0x04` the interface `QueryInterface` returns into `0x004FEC84`, and
`+0x18` — `0x004FEC98` — is a **`DDSURFACEDESC`**.

Three readings identify it, and the first is the one that cannot be
coincidence:

* both lock helpers write **`dwSize = 0x6C`** into `0x004FEC98` before using
  it. 0x6C is 108, `sizeof(DDSURFACEDESC)` — the v1 structure; `DDSURFACEDESC2`
  is 0x7C;
* both then push its address as argument 2 of a call through **vtable slot
  `+0x64`**. Slot 0x64 is index 25 — IUnknown's three, then
  `AddAttachedSurface` through `IsLost` — which is
  `IDirectDrawSurface::Lock`, the same slot in the v1, v2 and v3 interfaces;
* the label each helper pushes on its failure arm is the string **`"DD_Lock"`**.

So the two numbers are fields of a **public ABI**, not readings of an unknown
layout. `+0x28` is `0x004FEC98 + 0x10` — `DDSURFACEDESC.lPitch`, documented as
the distance in bytes to the start of the next line, which is exactly what
§23.4's arithmetic concluded independently. And the pointer both helpers
return, `0x004FECBC`, is `+0x24` — `DDSURFACEDESC.lpSurface` — which is what
`0x00512A98` gets. The pair `(base, stride)` that callers hand around together
is the pair the API hands back together.

**Neither field is written by any instruction in the image.** A scan of
`.text` for the two absolute addresses finds *no* reference to `lPitch` at all
and `lpSurface` only in the two `mov eax, [0x004FECBC] / ret` the helpers end
on. That is what you expect of a structure DirectDraw fills and would look
inexplicable otherwise, so `ddraw.fields_are_filled_by_directdraw` asserts it.

**The scope is narrower than "the stride is a DirectDraw pitch", and the
checks say so.** `0x004617B0` dispatches four ways on the display mode
through the jump table at `0x00461864`, and `ddraw.lock_arms` classifies each
arm from its own bytes:

| mode | arm | where the stride comes from |
|---|---|---|
| 0, windowed | `0x00461844` | **unchanged** — the arm stores only the base, from the 32-byte table at `0x004FF6F4` |
| 1, DirectDraw 8-bit | `0x004617EE` | `lPitch` |
| 2, DirectDraw 16-bit | `0x004617EE` | `lPitch` |
| 3, 3D card | `0x004617D0` | an Eng3d entry point, called through `0x004FA420`, fills it through a pointer argument |

Mode 0 never rewriting it is why §23.4's headline row survives at all: the
320×200 case's 640-for-a-320-byte-row is not merely the author's starting
value, it is the value that mode's frames actually use.

One qualification stays: which surfaces the two helpers lock — the one the
module holds at `+0x0C`, and entry *n* of the twenty-byte table at
`0x004FEDE8` — is **not** claimed here. That needs a reading of
`CreateSurface`/`GetAttachedSurface`, which this project does not have, and
naming them "primary" and "back" would be exactly the kind of guess with good
handwriting §23.4 was written against.

Five checks, no Wine, in the always-run block; **43 mutants, 43 caught**.

One thing the battery over these pins found, and it was in the *check* rather
than in the reading: perturbing the jump-table address made the arm decoder
read an address outside the image, and `PEFile` raised where it should have
answered "not the instruction I expected". A battery that stops on an
exception is a battery that reports a smaller number, and `Binary.mapped`
exists precisely so it does not. Every read added here goes through a guard
now, and the digests through one shared helper. **222 mutants, 222 caught.**

| | |
|---|---|
| `blob_gold.py --check` | 252 -> **259** |
| `blob_tables.py --check` | 423 -> **445** |
| Arm lines executed against the engine | 377 -> **383** of 385 |
| Arms with every line executed | 72 -> **73** of 74 |
| Creator constants read back out of the binary | 0 -> **13** of 13 |
| Output-system fields read rather than inferred | **2** (`0x00512A9C`, `0x00512A60`), and `0x00512A9C`'s source named as `DDSURFACEDESC.lPitch` |
| Mutation battery over the new pins | **265** mutants, 265 caught |
| Open questions | unchanged at **37** |

## 24. 2026-09-02 — the shot the player can see, and the shot that answers it

§11 and §14 own shot presentation. This is a later pass over the part of it the
**player reports as missing**: firing and being fired at read as "nothing
happened". Four distinct defects, all found by reading the code and all in
`game/`, and one latent fifth. None of them is a spec gap — the specs were
right and the presentation did not follow them.

| What was missing on screen | Cause |
|---|---|
| The player's own shot ends in a snap | `UnitsView.animate` stopped the clip at its `BREAK` note and `rest()`ed the body **in the same call**, so the pose the engine holds was posed and then overwritten before a frame was drawn |
| Enemy return fire | Reaction fire had **no presentation at all** at any of the three sites that drain it — no animation, no blobs, no sound. The HUD counted the shots and nothing drew them |
| The computer's shots cut off | `_play_event_body` returned `0.0` for a `"fire"` event, so `AIPlayback` held `STEP_SECONDS = 0.45 s` while the shipped `F` clips reach `BREAK` at 17–36 frames — 0.85 to 1.8 s at 20 fps — and the next event's rebuild freed the state mid-clip |
| The target does not react | `_present_ai_event`'s `"fire"` arm played the weapon and impact cues but **no pain scream**, so a marine shot by an alien made no sound at all |
| *(latent)* | the same arm read the weapon out of `world.unit_view(slot)`, which is the **post-turn** record: an alien killed by reaction fire after its own shot came back as an empty view and the arm returned with no presentation whatever |

**There is no hit or death animation to add, and none was invented.**
[`40` §7.2 / §7.2.1](40-charisma-models-and-animation.md) is explicit that the
engine references exactly `M`, `S`, `F` and the one `M2` literal. Being hit is
the pain-voice round robin plus the impact blob ([`28` §4.1, §8.1](28-effects-and-sound.md));
dying is `aKillUnit` removing the record ([`22` §9.5](22-combat-and-visibility.md)).
The honest fix for "no reaction at the target" is the missing scream and the
missing impact on the paths that lacked them.

### 24.1 One presenter, and what it owns

`SliceMain._present_attack(shooter, sx, sy, tx, ty, weapon, attack)` is now the
only thing in the remake that shows a shot — the player's, the computer's, and
every reaction on either turn. It fires the shooter's body, spawns the muzzle
and impact blobs through `BlobTriggers`, plays `AudioEvents.for_attack` and one
pain scream per outcome that dealt damage, and **returns how long the body is
occupied** so a caller can wait for it. The three layers are independent: a
body animates whether or not there is an audio server behind it, which is also
what lets a headless suite drive it.

Two things about its arguments are decisions rather than mechanics.

`(sx, sy)` — where the shot came *from* — is **passed in, not read back out of
the world**. The computer's playback runs after its turn is decided, so the
shooter may have moved or died since; the event carries the cell it fired from
and that is what the muzzle blob uses. For the same reason the weapon comes
from the event's `note`. That is the fifth defect above, closed by
construction rather than by a guard.

*(Corrected 2026-09-09.)* The note used to be written as `str(unit.weapon)`
"at the moment the trigger is pulled", which reads the **gun** for a
close-combat stab and was wrong twice over: the swap is already reverted by
the time `Combat.attack` returns, so that expression names the gun whether it
is evaluated before the call or after it, and the byte the engine's animation
dispatches on is the **bayonet's** — `aPlayFightAnimation` runs at
`0x0046C186`, inside the swap's window ([`21` §6](21-info-lcl-schema.md)).
Both `World.submit_attack` and `AIFire` now write `AttackResult.
presented_weapon`, the byte the record held while the animation ran, and the
picture selects the `F` clip, the wave and the muzzle from it — so a marine at
contact range plays `P0_F1_001` with `W_BAYO_0` instead of a burst of a rifle
whose round it never spent.

`AttackResult.from_dict` is new in `core/`, and it deliberately does **not**
read `reactions`: the document shape is pinned to
`inclib.combat.AttackResult.to_dict()`, and the computer emits what it drained
as its own `reactions` event.

### 24.2 The hold is the remake's, and is said to be

`CharismaState` now owns the whole shot, the hold included:
`HOLD_SECONDS = 0.35` is how long the `BREAK` pose stands before the idle
resumes, and `is_busy()` stays true through it, so a caller that rests the body
when it goes false rests it at the *end* of the shot.

*(Superseded 2026-09-02 by [`42` §4](42-mission-presentation.md): the engine
plays the `F` clip at speed **6.0**, holds at `BREAK` while the projectile
flies — up to 100 frames on the *arrived* flag — draws the damage numbers for
at least 20 frames and then **resumes the clip past `BREAK`**. There is an
engine sequence behind the hold; it is not a constant.)*

**There is no engine number behind that 0.35.** `fcn.004055E0`'s callback halts
the clip at the note and leaves it there; what puts `S` back is the 3D-view
refresh, and that refresh rate is not recovered — [`40` §7.2](40-charisma-models-and-animation.md)
marks the `kind` 0 / `kind` 4 playback set-up UNVERIFIED. It is **not** the
`int(len / 6) / 3` spin of [`40` §4.8](40-charisma-models-and-animation.md):
that one runs *while* the clip plays toward `BREAK` and is three or four
iterations, not a wait after it. The hold lives in the state and not in
`UnitsView` for a structural reason — a view holding the pose on its own clock
would report a length covering only the clip, and the computer's next event
would rebuild the state part way through the hold.

The same edit fixed a real bug beside it. `_enter` set `_running = true`
unconditionally, so `fire()` on one of the seven types with no `F` clip
(Spider 24, Dec'Ther 52, Norc'Yn 61, Bea'Ther 65, Bea'Coo 66, and types 62 and
63) left the state running with a null clip: `advance()` answered "still
running" for ever and the body never came back to its idle. `_running` is now
`clip != null`, and `UnitsView.animate` rests on the **mode** rather than on an
edge of `is_busy()` — an edge never fires for a body that was never busy for a
frame.

### 24.3 Return fire is shown where `core` resolved it

`World.submit_move` drains a whole move's reactions in one call at the *end* of
the move, and the walk that follows is only the picture. So the player's return
fire is **queued** and drained from `_process` when the picture has caught up:
nothing walking, and no body still shooting. That is the second remake choice
in this pass, and the alternative — showing the return fire on the frame the
command was issued, over a body still walking toward where it was shot — would
be a picture of something that did not happen.

The condition is a **state** test and not an edge, deliberately: a move that
was refused or that walked no steps still drains reactions in `core`, and an
edge on a walk ending would never fire for it. `_after_command` clears the
queue, because a new command supersedes what was waiting.

The computer's turn needs no queue — its `"reactions"` event is already
sequenced by the playback — so `_play_event_body` shows it at once and returns
the longest reactor's clip as the hold.

### 24.4 Deviations from the plan

Two, both deliberate.

* The plan's `_present_attack(shooter, tx, ty, weapon, attack)` would have read
  the shooter's cell out of the world. That is right for the player's shot and
  a regression for the computer's, whose old arm already used the event's own
  cell — hence the seven-argument form above.
* The plan said `units.gd` needed no change. It needed one: its `was_firing and
  not is_busy()` edge is exactly what leaves a null-`F` body in `FIRE` for ever,
  and the plan's own suite check for that case cannot pass without it.

### 24.5 Verification

| | |
|---|---|
| `godot/run_tests.sh` | 31 suites, 1878 -> **1912** checks, 0 failures |
| `test_charisma` | 37 -> **57** checks: the reported length, the held pose, the null-`F` state, and one shot end to end through `UnitsView` |
| `test_game_ui` | 57 -> **71** checks: the queue, the two waits, the drain, and both computer events |
| `remake_convert.py --check` | 181/181 |
| `remake_convert.py --check-cache` | 29/29 |
| Shipping export | built headless and launched; no script error |

`test_game_ui`'s reaction checks are driven by **`core`'s own drain**: no
shipped `.lev` places a unit on overwatch and none starts an alien within a
field of the first marine, so the suite moves one alien beside a squad member
and puts it on overwatch, and everything after that is `Reaction.drain`'s
answer. What it cannot reach is `_after_command`'s clearing of the queue —
that call rebuilds the units, redraws the terrain and refreshes the status
line, so it needs a HUD, an overlay and the mission geometry a headless suite
has none of. The queue it clears is checked; the clearing is not.

The whole chain was also driven **in a real scene** — a temporary
`SceneTree` driver over `game/main.tscn`, with the audio, the blob pool and the
camera alive — because every suite runs with `_audio`, `_events` and
`_triggers` null. One move drew one reaction: `pending=1` while the walk ran,
the drain reached `_present_reactions` -> `_present_attack` -> `play_cues` when
it ended, and `pending=0` after. That is the one place the audio path of a
reaction has been executed at all.

**Not performed:** the by-eye pass. Whether the marine now *looks* like it
shoots, whether the alien is heard on its own turn, and whether a computer
`"fire"` event runs to its `BREAK` without the next event cutting it off are
four things a suite cannot answer and this pass did not watch. What is
established is that the state machine reaches the end of the clip, holds the
pose for `HOLD_SECONDS` and only then rests; that every one of the three
reaction sites now presents; and that the two computer events report a length
at least as long as their clip.

## 25. 2026-09-02 — what play found that the suites could not

§24 fixed four defects a reading of the code had named. Played, the shot still
read as nothing happening, and the report that came back named four things
instead: only one soldier's weapon showed anything, the others "stood in the
idle pose, resetting the animation at the moment of the shot", overwatch fired
without animating, and a killed unit did not disappear until the next turn.

All four are real, all four were measured rather than guessed, and **three of
them are defects §24 could not have found**, because each one is invisible to a
suite that drives one unit through one command.

### 25.1 A killed unit stayed on screen

`aKillUnit` (`0x00472920`) is two calls: the death sequence and
`aRemoveUnitElement`, which deletes the 3D object. The remake's
`UnitState.remove` clears the map cell and **keeps the record** — correctly, as
the hero counter and the win conditions read it — and `UnitsView.build` drew
every record it found, gated only on the fog. So a dead unit stood on its cell
until some later rebuild happened to drop it, which for a unit killed on the
player's own turn is the next hand-over.

Measured in a running scene before the fix: the shot reports `marker: 93`
(killed) and `hp = 0`, and the alien's node was still in the picture 1.5 s
later. `UnitsView.build` skips `hp == 0` now, and the same run shows the node
gone in the frame the shot resolves.

### 25.2 Every command restarted every animation

`_after_command` rebuilds the whole units view, which frees every node and
builds a fresh `CharismaState` — idle at frame 0. Measured before the fix: a
marine standing well away from the action had its idle clock read **18.99
frames before the command and 0.0 after it**. Ten bodies snapped at once, every
time the player did anything, which is exactly the reported "resetting the
animation at the moment of the shot"; and a reaction shot in flight was thrown
away by the next rebuild, which is **a candidate** for overwatch firing without
animating -- that one was not measured, only reasoned about.

`CharismaState.playback()` and `resume()` carry the clip and the playhead
across a rebuild. **`MOVE` is refused deliberately**: the walk itself lives in
`UnitsView` and a rebuild clears it, so a movement clip carried over would loop
on the spot for ever — the idle is what a body with no walk plays. The clock is
presentation and not world state, so carrying it is not a scene node becoming
authoritative.

### 25.3 The muzzle switch has a default arm, and the two starting guns reach it

The one that made shots invisible. [`28` §8.1](28-effects-and-sound.md) read the
muzzle switch out of its index and jump tables — 2…47 — and the compiler's
bound check is `add eax, -2 / cmp eax, 0x2D / ja 0x0040D42C`. Weapons **0 and
1**, `Light Combat Gun` and `Advanced Combat Gun`, fall past the table to the
default arm, and that arm is not a join point: it calls
`aBlob_CreateTracerBullet` (`0x004247C0`), the same creator weapon 2 uses.

So in the remake the two guns the campaign starts with fired nothing at all,
while a marine carrying the Standard Assault Rifle fired a visible tracer —
which is precisely the "only one weapon shows anything" that was reported.

`blob_tables.py` pins the `ja` target, the call target, that the target is a
known creator, and that every id the table carries is at or above its first, so
a table read without its default cannot come back green. `BlobTriggers.creators`
falls back to `<switch>_default` for an id the table does not carry.
`test_effects.gd`'s `triggers.out_of_range` **required zero blobs** before this
— a suite check that had encoded the gap — and now requires the tracer.

The other two switches' defaults were read the same way and make no blob, so
weapons 0…6 having no impact effect is the engine's answer and not a second
gap.

### 25.4 What is data rather than a defect

Two measurements worth writing down, because they bound what any further work
can achieve.

**The combat clips differ enormously in how much they move.** Sampled through
`inclib/pose.py` for every `(type, weapon, player)` the converted missions
contain, the largest joint displacement between the clip's own frame 0 and its
`BREAK` note, converted to metres through the ×16 bone-to-world bridge:

| weapon | clip | at `BREAK` | clip peak |
|---|---|---|---|
| 0 | `P0_F0_000` | 1.02 m | 1.06 m @ f20 |
| 1 | `P0_F0_001` | 0.71 m | 0.91 m @ f60 |
| 2 | `P0_F0_002` | 0.43 m | 0.57 m @ f30 |
| 6 | `P0_F0_006` | 0.24 m | 0.24 m @ f28 |
| 8 | `P0_F0_008` | 0.26 m | 0.26 m @ f20 |
| 10 | `P0_F0_010` | 0.22 m | 0.22 m @ f20 |
| 11 | `P0_F0_011` | **0.14 m** | 0.14 m @ f18 |

The idle clips move *more* than several of these — `P0_S0_000` carries a hand
1.25 m over its 90 frames — so a shot with one of the heavy weapons is a
smaller movement than the pose it interrupts. That is the shipped data, and the
engine truncates it at the note besides: `P0_F0_002` stops at frame 20 of 76
and never reaches its own peak at 30.

**Most weapons have no impact effect.** The impact switch names a creator for
13 of the 40 ids it covers, and its default makes none, so nothing appears at
the target for the Assault Rifle and for every other conventional gun — only
the `ricochet.wav` the sound switch selects. There is no hit, flinch or death
animation to add either: [`40` §7.2.1](40-charisma-models-and-animation.md) is
that the engine references exactly `M`, `S`, `F` and one `M2` literal.

### 25.5 Verification

| | |
|---|---|
| `godot/run_tests.sh` | 31 suites, 1912 -> **1926** checks, 0 failures |
| `blob_tables.py --check` | 445 -> **449** |
| `blob_runtime.py --selftest` | 78 kinds, 74 arms |
| `remake_convert.py --check` / `--check-cache` | 181/181, 29/29 |
| Shipping export | rebuilt headless, launched, no script error |

`CONVERTER_VERSION` is **0.12.0**: `tables/blobs.json` carries
`weapon_muzzle_default` now, so both copies of the constant were bumped and the
cache republished.

The three fixes were each measured in a running scene, not only in the suites:
the Light Combat Gun makes 2 muzzle blobs where it made 0, a killed alien's
node leaves the picture in the frame the shot resolves (10 nodes -> 9), and a
bystanding marine's idle clock reads 18.96 before the command and 18.96 after
it.

**Still not performed:** the by-eye pass. Whether the shot now *reads* as a
shot is the one question none of this answers, and §25.4 is the reason to
expect it to remain modest for the heavy weapons.

## 26. 2026-09-02 — three more from play

§25's fixes were played back, and the report that came from that is the reason
this section exists: with the shot now visible, three further things were.

### 26.1 Ammunition went negative and the unit kept firing

`aAttackUnit` does not check. Its spend is
`mov al, [esi+0x3D] / sub al, dl / mov [esi+0x3D], al` at `0x0046C308` — an
**8-bit** subtraction with no clamp and no test, so in the engine the count
wraps rather than refusing. The refusal is the **caller's**, and the engine's
own weapon selector `0x0042FF30` is where it lives: a unit whose weapon is
jammed or empty gets its `special` 1 fallback weapon, or **no weapon at all**.

That routine has been in the remake since the third slice, as
`AIOverlay.effective_weapon` — but only the computer went through it. The
player's call site, `World.submit_attack`, had no gate of any kind, so a marine
fired for ever and its count went past zero.

`submit_attack` now refuses on exactly [method Combat.attack]'s own **spend**
condition — the weapon's `mun` column is not 255, the unit's type is not
`0x42`, and the count is below `mun_per_fight` — so the subtraction can no
longer be reached with too little to spend, whatever the magazine size. Both
models keep the *signed* count deliberately rather than reproducing the byte
wrap: past zero is unreachable now, and a negative would be visible as a
defect where 250-something would look like a refill. The instruction is
recorded in both twins so the deviation is a decision and not an oversight.

### 26.2 The computer's units arrived, then walked to where they already were

`_on_ai_step` rebuilds before it plays the event — deliberately, since the
rebuild is what creates the state the animation drives — and the rebuild puts
every unit where the world says it is, which after a turn `core` has already
resolved is the **end** of that turn. `UnitsView.start_walk` did not write a
position, and `_advance_walk` writes one on the frame *after*. So an alien
appeared at its destination for a frame, jumped back to its source and walked
to it.

`start_walk` places the node on its route's first cell and faces it along the
first step, before any frame is drawn.

### 26.3 A casualty vanished before the shot that killed it

§25.1's fix — the picture drops a unit with no hit points — is right, and it
put the removal in the wrong place in the *order*. The rebuild that drops a
casualty runs **before** the event that killed it is presented, always for the
computer's replay and by one call for the player's own shot, so a marine
disappeared and the sound of what killed it arrived afterwards.

`UnitsView.linger(slot, seconds)` keeps a dead unit drawn for a moment, and
`main.gd` holds every casualty of a shot **before** the rebuild — the player's
own outcomes, the reactions a move or a shot drew, and the computer's `"fire"`
and `"reactions"` events alike. `animate` counts the hold down and drops the
node itself, so nothing waits for another rebuild.

`DEATH_LINGER_SECONDS = 0.7` is **the remake's number and there is no engine
number behind it**: `aKillUnit` is a network message and `aRemoveUnitElement`,
the object goes at once, and Charisma has no death clip to play instead
([`40` §7.2.1](40-charisma-models-and-animation.md)). What the engine gives is
the *order*, and that is what the hold restores. *(Corrected 2026-09-02: the
object does go at once, but not into nothing — `aPlayFightAnimation` hides it
and spawns a blood, debris, fire or flying-unit effect by species and class,
with a death scream: [`42` §4.8](42-mission-presentation.md).)*

### 26.4 Verification

| | |
|---|---|
| `godot/run_tests.sh` | 1926 -> **1934** checks, 0 failures |
| `combat_tables.py` / `combat_runtime.py` / `ai_runtime.py` | all pass, 84/84 and 71/71 |
| `remake_convert.py --check` | 181/181 |

Live, in a running scene: a marine with no rounds is refused with `no
ammunition` and its count stays at 0; with ten rounds it fires and has nine;
the alien it killed is still drawn immediately after the shot and 0.3 s later,
and gone by 1.1 s.

The suites pin the same three: `ammo.an_empty_weapon_does_not_fire` and
`ammo.and_the_count_stays_at_zero` with `ammo.exactly_enough_still_fires` for
the other side of the boundary, `walk.starts_on_its_first_cell`, and
`rebuild.a_casualty_is_held` / `rebuild.and_then_it_goes`.

## 27. 2026-09-02 — the jump had two halves, and §26.2 fixed one

Played again, the computer's units still "sometimes" arrived before they
walked. §26.2 was right about the cause and wrong about its extent: placing the
body on its route's first cell in `UnitsView.start_walk` closes the **one-frame
flash** at the moment a move event plays, and there are two longer windows it
cannot reach.

The root of all three is the same architectural fact, and it is not a defect:
`core` decides the whole turn in one call ([`94`](94-slice-4-report.md)), so
from the instant `submit_end_turn` returns, the world holds every unit at the
position it *ends* the turn on. Every rebuild during the replay therefore draws
a unit that has not walked yet at the place it is about to walk to.

* **Window one, the whole of the first `STEP_SECONDS`.** `AIPlayback.play()`
  does not take a step; the first one waits for the timer. `end_turn` calls
  `_after_command("")` straight after `play()`, so for the first 0.45 s of the
  computer's turn every unit stands at its destination. This is the one that
  reads as "it was already there".
* **Window two, every event before a unit's own.** A unit that walks at event
  seven is drawn at its destination through events one to six — seconds, on a
  turn with several actors — and only then jumps back and sets off.

The events already carry what is needed: `AIPlan` emits a move with the
**source** in `x`/`y` and the destination in `tx`/`ty`.
`AIPlayback.pending_starts()` walks the events still to come and returns, per
slot, the source of its **next** move or warp; `UnitsView.hold_at` draws those
slots on those cells whatever the world says. It is the same contract
[`92`](92-remake-architecture.md)'s `lift` and `suppress` have -- the world is
never consulted about it and never told, a rebuild re-applies rather than
resets, and the hold is released when the replay ends, including when it is
skipped.

`UnitsView.fire` faces a body from the cell it is **drawn** on for the same
reason, so a computer unit that shoots before it moves aims from where the
player can see it standing.

### 27.1 Verification

Measured in a running scene, because no suite can reach it: `_C_140` played to
turn 2, where the computer moves four units, sampling every drawn unit that
still owed a move on every frame of the replay and comparing its node against
the source its own event carries.

| | |
|---|---|
| before | worst offset **4.0 m**, four units at their destinations |
| after | **526 placements sampled, worst offset 0.0 m** |

The suites pin the part that is a function of its arguments:
`AIPlayback.starts_in` over a hand-made event list -- the source is the event's
own `x`/`y`, a warp counts, a unit that moves twice is held at the start of its
**next** move, and nothing is held once the last event has played -- and
`UnitsView.hold_at` drawing a unit on a cell the world does not put it on, then
releasing it. 31 suites, 1934 -> **1945** checks.

The two call sites -- one in `end_turn` beside `play()`, one in `_on_ai_step`
before its rebuild -- are covered by the live measurement and not by a suite:
`end_turn` needs the HUD, the overlay and the mission geometry that a headless
run has none of.

## 28. 2026-09-02 — the camera, on the engine's own six integers

[`42` §11](42-mission-presentation.md) measured the remake's camera against
the engine's and found nothing in common: a pivot snapped to a cell, one yaw
tween, no pan, no camera during a walk or a shot. This addendum is the
camera half of the plan that table asked for, under **model A** of
[`92` §7.5](92-remake-architecture.md): the tactical orientation stays
discrete, everything else the engine does is added.

### 28.1 What the rig is now

`game/camera_rig.gd` holds what `a3DEngine.cpp` holds — an **eye** and a
**target** in engine units — and moves them the way `0x0040EEE0` does:

* the six deltas eased by a third each frame when any starts at 500 or more,
  by a sixth otherwise, the choice made once; stopped when all six are
  within 30; set at once when the eye's height would change by more than
  0x7D00. Truncating division, one step per gameplay frame, the remainder
  carried like the effects'. `flight_frames` pre-computes the length so a
  walk or a hold can wait for exactly it, because the engine's flight
  **blocks** and everything that follows one starts after it;
* `0x004529D0` as `place_on_unit`: mode 1 behind the unit along its facing
  with the axis-aligned extra field, mode 0 on the current quadrant's corner
  of the `(dist + 6) × dist` rectangle, the box clamp, the near-axis rule,
  and the free-position search in **both** modes — the listing joins mode 1
  to it at `0x00452E11`, which the first reading of `42` §2.3 missed;
* `0x00453510` as `free_position`: up to 70 tries of `±51 × n` about the
  look point, each clamped into the box, given up unchanged;
* the eyes view, the map view, the ride and the tracking write of §2.4 and
  §3.2, and the middle-drag pan of §2.5 at 400 units a pixel of the
  original's width.

The quadrant `0x00510700` is the rig's `_quadrant`, and Q and E step it: the
current offset's magnitudes with the next sign pair, flown. **The eye's
azimuth is quantised at every placement** — the quadrant table, a facing, or
the search's own 51-unit steps — and the one thing that leaves it off the
grid is the walk's tracking, which keeps the eye still and moves the target
with the walker as the engine does. The next placement flies it back.

The engine's box is what caps the height. `0x004529D0`'s own cap compares
`pos.z` against `0x00419B90() × 1600`, and `0x00419B90` returns the loaded
header's `+0x224`, which [`10`](10-lev-mission-format.md) had already pinned
as world units — so it multiplies units by 1600 and never bites. The box
initialiser `0x00453320` is pinned instead: 800 on every low side, a field
in from the far edges, the header value on z.

### 28.2 What decides, and what it decided differently from the doc

`game/camera_director.gd` is `42`'s call-site table and mode tables over a
`World`: `(8, 7, 0)` on TAB, `(6, 4, 0)` before a computer walk when the eye
is low or the walker is out of sight, `(5, 2, 1)`, `(9, 5, 1)` and
`(5, 3, 1)` for a computer shooter by §4.3's decision, the far shot one field
back along the line at a metre over the head, and the reaction's coin. Four
things the listing said that the document did not, all now in `42` and
pinned by `presentation_tables.py` (390 → **425** checks):

* the flight's target after a placement is the object **plus the unit's
  height**; `obj + 1 m` is the look point the search is given;
* the near-axis rule goes **both ways**: `pos.z += |Δx| − 12 800` after the
  clamp. Intact, only the teleporter's `(5, 5, 0)` reaches it and it raises
  by 4800; near the map's east or west edge the clamp pulls `|Δx|` under
  12 800 and it lowers — on `_C_140` the first marine is two fields from
  the east edge, and the opening view comes out 3227 east, 12 800 north and
  6427 up, a steep close view. That is what the engine's player saw there
  too, and it is not corrected;
* the reaction camera is **2400 back** along the line's horizontal direction
  and `4800 × slope` in height, not "4800 back and 2400 up"; both heights
  are the reactor's and the size is the unit the camera stands behind;
* the walk's mode reads `0x004794B0` — one line of sight per other-player
  unit to the asked cell, at `0x0047AD70` heights — at the destination and
  then at the source. *(As delivered, `World.is_seen_at` was that call as a
  query on the post-turn world, and the destination's `+0x0C > 6` test was
  not transcribed; §28.5 and §28.6 corrected both — the call is a writing
  pass, `core` runs it at the moment of the move, and the event carries its
  two answers.)*

Two caveats of the post-turn probe, both accepted: a marine that **died**
later in the computer's turn is not among the observers any more, so a walk
that only it saw comes out mode 0; and an AI `reactions` event names only the
mover's cell, so a mover the world has since lost — killed by that very
reaction — is framed as a cell with no height and no size.

The per-event `focus_on` in `_on_ai_step` is gone with the rest: it flew the
player to every alien's cell, hidden ones included, which was a leak of the
fog through the camera.

### 28.3 The remake's own decisions, named

* **A selection** flies the target to the unit with the eye's offset kept.
  *(Corrected 2026-09-05: the engine's select camera **is** traced —
  `fcn.004533D0` re-applies the current view mode on the new selection's cell,
  and mode 2, the one a mission opens in, is `(8, 7, 0)` on the unit
  ([`43` §4.5](43-battle-hud.md)). That a selection moves the camera is
  therefore the engine's; which of the four placers the remake uses is still
  its own. The hand-over calling no camera routine stands, and is a separate
  thing — the remake's `COMPAT_CAMERA_RETURNS` moves the view with **no**
  selection behind it.)*
* **The clear-line test** runs over the map's heights, sampled a quarter
  field at a time, where `0x00453490` walks the special-object and clone
  arrays. Same data policy as every other guard here, same blind spot: a
  roof that is scenery and not a height is not an obstacle to it.
* **Keys 1, 2, 3** for the eyes, unit and map views; `docs/29` records the
  GUI events and no key. The HUD stays up through the eyes: `0x00452E90`'s
  `0x0041A980(1)` then `(0)` is a hide-and-redraw pulse round the flight,
  not a state.
* **A computer jump** still gets the target flown to its landing cell when
  the fog draws the warper. The engine's jump camera follows the parabola
  (`42` §7.1) and is a later phase; without this interim an alien vanished
  from one place and appeared in another with no camera move at all.
* **The zoom** scales the offset by 1.15 a notch, never under 6400 units;
  the engine's height keys move by 2000 and there is no third key here. It
  is applied at once, like the pan: for one revision it went through the
  20-fps flight loop and lagged a sixth of the way per frame behind the
  wheel (corrected 2026-09-02).
* **The shot's flight runs beside the clip** rather than after it. The
  engine plays the clip to `BREAK`, sets the caption, *then* flies (`42`
  §4); the remake's shot is still the three-stage one of §24 and the
  nine-stage sequencing is the next phase. The hold reported to the
  playback covers flight plus clip.
* **The free right-drag rotation** is left out, by the decision itself.

### 28.4 Verification

31 suites, 1945 → **2057** checks, `camera` 26 → 143, `mesh` 28 → 44
(the later-the-same-day closures of §28.5 included): the flight's five
rules and its frame count, every placement number of §2.3 on a flat map
with the search on a walled one, the box, the three views, the pan and its
refusal, the walk's mode table with all four pre-walk cameras and the tracking that
waits for them, both arms of
the shot's near test and the far flight, both arms of the coin with the
slope and floor terms, the probe in `core`, and the level-bounds and
hand-back checks carried over to the new state. `shot.gd` gained `--eyes`
and `--map` and prints the rig's state; the opening, the map and the eyes
view of `_C_140` were looked at and match their numbers.

**Not looked at in a running game**, and left to the by-hand pass CLAUDE.md
asks for on the exported build: a computer walk tracked and an alien
emerging shown from its own eyes, a computer shot from behind the shooter
or the victim, a reaction on either turn, Q and E round the rectangle, the
pan, and a skip landing where the flight would have stopped.

### 28.5 Open — and closed the same day

Three items this section listed at delivery were closed later on 2026-09-02;
what each found is recorded here because two of them corrected a delivered
reading rather than merely filling one in.

**The roof — closed, and it was a material question after all.** Eng3d
culls back faces: [`31` §4.2](31-prototyp-geometry.md) now pins the sign of
the leaf walker's side test from the binary (the vector is object minus
camera, `0x00404BF4`), from the corpus (`plane_d = −n·v/16384` on 230 016
of 236 861 faces as first measured; §28.6 closes the other 6 845 — a part
face's plane is in its part's frame and the rest is the 14-bit normal's
precision, so the engine's test is a cull on the face's own plane) and from
the one face whose visible side is known without
a renderer (the ground lattice, normal up, `plane_d = −80`), and the stored
winding is against the plane normal on every face with an area but one.
`mesh_builder.gd` culls the back face and its ear-clipper is now
orientation-preserving, which it had to become — `Geometry2D.triangulate_polygon`
normalises its output and the axis-drop mirrors half the outlines, so under
`CULL_BACK` some ears were holes. So the engine's heights **are** usable on
an interior as they are: a ceiling faces down and is culled from above, which
is why the original's player looks into a roofed room from ten metres over
the unit's head. Over `_C_140`'s floor there are four such faces, all at
`z = 32 000`, above the map view's eye, which is why that map looked the
same either way; `_C_141` has 31 facing down between `z = 17 064` and
`32 000`. **The witness is the map view over `_C_141`'s cell (9, 9)**
(`shot.gd --mission=_C_141 --map --at=9,9`, the `--at` added for it): with
the faces double-sided the frame is the underside of a ceiling slab and
nothing else; one-sided, it is the room under it — crates, girders and two
units. The opening and map views of `_C_140` were taken again as well and
the lattice floor is still there — the arbiter of the winding convention,
since a wrong one removes the floor rather than the roof.

**The `+0x0C > 6` test — transcribed.** The byte is the fill's movement
points left on arrival, and `aWalkMoveMap` stamps the destination `100`
**before** its closing sweep zeroes every cell that is not, so the value is
alive when `0x0046E357` compares it with 6: over six, the destination's
answer is discarded. The discard is `core`'s since §28.6
(`ExecuteMove.ARRIVAL_POINTS_LIMIT`), and `CameraDirector.walk_mode` takes
the two flags already decided. The mechanism is that instruction; the intent
behind the number stays an inference. One consequence worth knowing: the
AI's fills run at the horizon levels of [`23` §7](23-ai-system.md), so a
computer unit routinely arrives with far more than six points left — on the
fixture's two turns every move does (18, 18, 44, 47) — and the original then
shows no arrival at all, mode 0, the unit simply being where it went. The
remake still walks the body (the walk is presentation, §28.3); only the
camera follows the engine's rule.

**The died-observer probe — closed by moving it.** `0x004794B0` is
`aBuildVisibleMapForUnit(observer, x, y, &saw)` of [`22` §9.3](22-combat-and-visibility.md),
and [`42` §3.2](42-mission-presentation.md) had its observer backwards: the
**mover** looks from the cell, and the flag is "it would see an enemy from
there". The answer is the same either way round (one line per enemy, the
same two endpoints), but the timing was not: `main.gd` asked the post-turn
world, which has lost every observer that died later in the turn. Both
twins now ask at the moment of the move and carry `seen_source` and
`seen_destination` on the event; `test_ai.gd` diffs them against the Python
fixture, which makes a second transcription the oracle for the first. (At
first the asking was a query with the writes taken out; §28.6 made it the
writing pass it is.) The reaction camera's mover inputs follow the mover's
**slot** as well (`_inputs_of`), not whoever stands on the cell in the
post-turn world.

**Opened by the third, and closed in §28.6:** the engine's pre-walk call is
the *writing* pass, and `core` asked the question only.

### 28.6 The three left open — closed, 2026-09-02

**`0x004794B0` writes, and now `core` does too.** `aBuildVisibleMapForUnit`
is the engine's only visible-map pass — six call sites, all writing, no query
form ([`22` §9.3](22-combat-and-visibility.md) now tables them) — and
`aExecuteMove` runs it three times per walk: from the destination before the
first step, from the source for a computer mover, and from the arrival cell
afterwards, with mode 3 opening on `aSetVisibleStateForUnit(unit, 0)` for
the walker itself. Both twins carry all four writes inside their own
`aExecuteMove` (`ExecuteMove.execute`, `combat.look_before_walk` /
`look_after_walk`), which is also where the walk's position apply moved to,
so that the arrival pass sees the unit where it arrived. The shooter's and
the target's reveals inside `aAttackUnit` (`0x0046B643`, `0x0046BA22`), the
bomb's (`0x004703A9`) and the warp's full rebuild (`0x0046F144`) went in
with them. The query form (`seen_from`, `World.is_seen_at`) is gone.

What made the gap invisible was that nothing compared `+0x4F` after a
computer turn. `tools/ai_gold.py --check` now does, on all 200 records after
both captured turns and after every plan and fire probe, and passes — the
engine reveals four human units by walking in turn 1 and two in turn 10,
and a model with the passes silenced fails on exactly those slots, which is
the discrimination the check needed. The shooter's and target's reveals are
pinned by their instructions only: every unit those probes fire at was
already visible. `tools/turn_gold.py --check` compares `+0x4F`, `+0x47` and
`+0x48` of every live record after each of its six `aExecuteMove` probes
(120 checks now); the player's two-step walk there reveals nothing new, so
that half pins an absence. The GDScript side has the same six comparisons in
`test_turn_native.gd`, fourteen synthetic checks in `test_execute_move.gd`
(the destination pass reveals and wakes a group, the discard drops the flag
and never the writes, a computer mover asks the source and is itself marked
visible, a human mover is not asked) and seven in `test_combat.gd` (the two
reveals, a jam revealing nothing, the bomb's).

It corrected the entry that opened it: "the arrival rebuild makes the same
marks" was wrong for `core`, which had no arrival pass at all. And it moved
one decision: the `+0x0C > 6` discard of the destination's answer is
`aExecuteMove`'s, so it is `core`'s now (`ExecuteMove.ARRIVAL_POINTS_LIMIT`)
and the move event carries the two flags as the routine's own locals; `mp_left`
left the event and `CameraDirector.walk_mode` takes two booleans.

**The 6 845 faces were two things, neither of them a parallel plane.** The
924 with parts were measured in the wrong frame: `joint_place`
(`Eng3d.dll` `0x004060F0`) adds the rotated part translation into the
position the side test dots the normal with, so a part face's `plane_d` is in
the part's own coordinates, and in that frame every one of them is in span.
The other 5 921 are the normal's precision: the stored normal is the exact
one truncated to 14 bits (magnitude 16 381..16 384, never above) and
`plane_d` was computed before the truncation, so on the sequence models'
planets and their 5.5-million-unit space sphere a rotation of at most 0.018°
puts every one back in span — a miss of up to 908 units there and of 60 at
most on a world prototype. So the engine's side test **is** a cull on the face's own
plane, and `CULL_BACK` differs from it only inside that sliver.
[`31` §4.2](31-prototyp-geometry.md) is corrected and
`prototyp_parse.py --check` pins both counts, the 0.02° bound with its
worst miss, and that no normal is longer than 16 384.

**The suites:** 2057 → **2075** checks; `camera` 143 → 135 (the query's
five checks and the limit's three moved out), `execute_move` +14, `combat`
+7, `turn_native` +6. Still to do by hand in the exported build: what §28.4
lists, on a map with ceilings such as `_C_141`.

### 28.7 The two left after that — measured, 2026-09-02

§28.6 left the shooter's and target's reveals, the mode-3 self-reveal,
weapon 47's arm and `0x0047AD90` pinned by instruction only. Three new
phases of `tools/turn_gold.py` reach all of them inside the live game, each
probe reloading the save and writing what makes the write observable through
the game's own `memcpy` (the writer now lives in `movemap_gold`, once, for
the four gold tools):

* **`reveal`** — both parties written hidden, then `aAttackUnit`: the shooter
  and its target come out at 0; the same shot with the shooter's `+0x40`
  written jammed moves neither. Then the human is moved next to the alien
  with the engine's **own** relocation `0x0047AD90` (which is also what the
  platform ride uses, so the setup measures it), and the alien walks one
  step twice, differing only in the *Enemy Move* dword at `0x005129F4`: with
  it on the alien comes out at 0, with it off at **1**. The human it saw is
  0 either way.
* **`conversion`** — the human's weapon byte written to 47 and the seed
  written to one the model says clears the overheat roll: the alien's
  `+0x45` becomes 0, `+0x41` is cleared, and its own pass reveals the two
  other aliens. Then `+0x3A` written to 5 with `+0x33` clear (three hit
  points lost, five charges kept) and with `+0x33` set (none lost, four
  kept).
* **`platform`** — the human relocated to a clear centre and
  `aPlayPlatformSequence(13, 9, east, 3)`: the rider at `(16, 9)`, every
  cell's height, type and link as the model's, the source a deep hole, the
  alien in sight of the new cell revealed.

**Six things the first capture said the model had wrong**, all fixed in both
twins and each with a synthetic check beside the native one:

1. The **contact promotion** is `aBuildVisibleMapForUnit`'s own tail
   (`0x00479786`..`0x00479861`), not `aBuildVisibleMap`'s. Every per-unit
   pass runs it, `aExecuteMove`'s three included — which is what leaves the
   option-off walker a contact — and a player with no living unit rebuilds
   to "all hidden" with no blips. `test_render.gd` looks at the slice world
   as the aliens' player for that reason: its authored units are all theirs.
2. **Weapon 47 fires at its heat cap** (`0x0046B5DF`), so every shot rolls
   the overheat table first; the first probe rolled a 2 and fired nothing,
   which is why the seed is now written.
3. The absorber's charges are read **behind equipment slot 18**
   (`0x00475590`): the six placed aliens on `_C_119.lev` with a stale
   `+0x3A` absorb nothing in the engine and used to absorb everything in the
   remake until their first refresh — after the human's first turn.
4. A spent charge **zeroes the damage argument and still calls
   `applyDamage`**, which rolls; the seed said two draws where the model
   made one.
5. **`aExecuteBomb` never asks the absorber** — no call to either routine —
   and hands `applyDamage` the heading `0xFF`, so a mine meets the front
   armour. The model spent a charge the engine does not and derived a heading
   from the centre.
6. **`0x0047AD90` is `core`'s**, not the presentation's: a script command
   reaches a permanent write. `Platform.ride` relocates every rider and lets
   it look around **before** the cell copy, in the engine's x-outer order,
   which is the one command whose fog pass the interpreter performs rather
   than records; the closing rebuild for the *selected* unit's player
   (`0x004130E6`) is the `platform` event, keyed on `World.selected_slot`,
   which the presentation now keeps in step with its own selection.

What is pinned by instruction rather than by capture, still: the pass-order
question on the ride — the capture's geometry agrees with copy-then-pass as
well, and `--check` says so in its report line rather than pretending
otherwise; the conversion asking `aGetMovePoints` *before* clearing `+0x41`
(the probe's alien was not stunned); and weapon 47 being reachable at all,
since no shipped unit carries it.

**The suites:** 2075 → **2128** checks; `combat` +12, `combat_native` +33
(the nine probes replayed field for field, cells included), `execute_move`
+3, `lcl` +4 (the ride, and a ride whose destination is occupied: the
refused rider keeps its cell's link rather than being orphaned -- a review
caught both twins clearing it), `core_loads` +1 (`platform.gd`).
`turn_gold --check` 120 → 172, `combat_runtime --check` 84 → 100. Still to
do by hand in the exported build: what §28.4 lists.

---

## 29. 2026-09-03 — the shot, whole: experience, nine stages, and what the second reading corrected

`docs/42` §11 listed what the remake still did differently from
`aPlayFightAnimation`, and the first row of it was not presentation at all:
**`core` awarded no experience**. `UnitState.ep` was read by the fitness cap
and written by nothing, so the caption of `42` §4.2 and the skill orbit of
§7.5 had nothing to show. This section closes that row and the shot's own,
in the order the plan runs them: tools first, then the picture.

### 29.1 The kill award, read and measured

`docs/22` §7.5 named three addresses and no formula. Read out of them
(`combat_tables.py` now pins forty-six instruction sites and three
single-precision constants):

* `0x0047AFD0(unit, exp)` returns the gain as a float. In the **campaign**
  (`0x0043B740` == 1) it is the victim type's `exp` byte unchanged. In a
  session the difficulty picks a multiplier — `aiLevel()` 0, 1, 2 select
  4, 3, **1**, anything else keeps the 2 the routine starts with — and the
  attacker's own experience bends it: below 72 the gain is
  `(m − m·e/72) × exp` (the `0x38E38E39 / sar 4` reciprocal is a divide by
  72), from 72 to 108 it is `exp`, above 108 it is half — or **nothing**
  when the byte is exactly 1, because `cmp cl, 1` reads the *argument's* low
  byte. The ladder is transcribed and pinned, never measured: the fixture
  save is a campaign.
* `0x0047B090` adds the gain to the skill-point pool `+0x18`, capped at
  144, **unless** `ep + gain` would itself reach 144, in which case it
  returns without touching the pool; `0x0047B100` adds it to `+0x17`, capped
  at 144; `0x0047AF90` adds one to the kill counter `+0x53`, saturating at
  255. The caller gates the block on **the damage argument** (`test ebp,
  ebp / jle` at `0x0046BF47` — what `applyDamage` was handed, zero after an
  absorber charge), skips species 2 and a victim of the attacker's own
  player, and sums `_ftol(gain)` into `aAttackUnit`'s return value — the
  sixth argument of `aPlayFightAnimation`, the caption's number.
* After the animation, if the attacker is alive, its pool's level
  (`+0x18 / 12`) rose over the value saved at entry (`0x0046B588`) and its
  species is 0, the skill orbit `0x00410190` plays with the difference.

`inclib.combat` carries all of it (`experience_gain`, `award_training`,
`award_experience`, `count_kill`, `award_kill`, `skill_levels_raised`);
`AttackResult` gained `xp` and `skill_raised`; `CombatUnit` and `UnitState`
gained `ep`/`tp`/`kills` where they lacked them (the save schema is 7).
`combat_runtime.py` exercises every arm synthetically — 100 → **117** checks.
And the campaign arm is **measured**: `turn_gold.py`'s new `experience` phase
kills the one-point alien four times, as loaded and with the shooter's
`+0x17`, `+0x18` and `+0x53` written to the caps, and the engine moves
exactly the bytes the model moves — ep 73 → 74, tp 13 → 14, kills 13 → 14;
144 stays 144 and the pool is left alone; 143 → 144; 254 → 255. The three
bytes joined `PROBE_RECORD_FIELDS`, so the reveal and conversion probes now
pin that nothing died on them either. `turn_gold --check` 172 → **197**.

The player-record counters the block also moves (`0x0043B8D0`,
`0x0043B860` on the victim's player, `0x0043B810` on the attacker's) are the
debriefing's and are left as a `TODO` in both twins.

### 29.2 The shot as the engine plays it

`_present_attack` used to start the clip, fly the camera beside it, spawn
the muzzle and impact together, and hold a fixed 0.35 s (§24.2). It is now a
[ShotSequence] on the [SequenceQueue] — nine steps in `aPlayFightAnimation`'s
order, each with the engine's frame count where the engine has one:

1. the `F` clip at speed **6.0** to its `BREAK` note, then `int(len/6)/3`
   frames (`0x0040BEC9`);
2. the caption *"<name> received N experience points"* for the player's own
   unit with `xp > 0`, the empty string otherwise;
3. the camera of §28 — **after** the clip now, which closes the deviation
   §28.3 recorded;
4. the weapon's wave, the overheat cue and **one** voice by the shot's
   severity and the last marked unit's species; the muzzle switch; the
   creator's write over the arrived flag;
5. up to **100 frames** until the flag, unless the weapon's muzzle arm skips
   the wait (`WAIT_SKIPPED_WEAPONS`, measured off the arms: 15, 17, 20, 21,
   27, 30–32, 36, 37);
6. the impact switch, the deaths (§29.3), the floating texts projected to
   the screen, overlay 0 — the texts rise 2 px a frame and fade over 15;
7. up to **20 frames** until the pool is empty;
8. `aContCHAnimation` — the clip resumed past its note, for the frames it
   has left, unless the type is 0x37;
9. the play-out until the pool is empty, the fade is over and the clip has
   stopped; then the idle.

`CharismaState` got the engine's three speeds (`M` 2.0, `F` 6.0, `S` 1.5),
`frames_to_break`, `spin_frames` and `resume_past_break`; `HOLD_SECONDS` is
gone. The queue got `enqueue_until(name, bound, predicate)` for the spins
the engine leaves open-ended, and the bound is always the engine's — 100
and 20 — except for the camera's flight and the final play-out, where the
engine has none and `SAFETY_FRAMES` (300) is **the remake's** safety net,
named as one. The new `FloatingTexts` overlay draws the caption at (80, 54)
and the numbers in colour `0x5ACB` (RGB565, a mid grey — §23.4 has the
format); its scale from 640×480 to the viewport is the remake's factor and
says so. The replay's `AIPlayback.advance` takes a `busy` flag: while a
shot, a walk, a set piece or a flight is on screen the event timer does not
run, so an event waits for the picture rather than for a number.

**The casualty is hidden by the shot**, in step 6, the way `0x00405320(obj,
5)` hides it; `DEATH_LINGER_SECONDS` (0.7 s, §26.3) is gone with the hold.
`UnitsView.mark_dying` keeps the body through the rebuild and
`hide_now` removes it in the death stage; a new command clears stale marks.

### 29.3 What the second reading corrected

Three things in `docs/42` were wrong, and each is now pinned by
`presentation_tables.py` (425 → **472** checks):

* **The death switch branches on the weapon, not on the severity.** The
  slot the sweep fills with the severity (`[esp+0x1C]`) is zeroed at
  `0x0040CC49`, just before the muzzle switch, and the muzzle arms write
  the value the death switch reads at `0x0040DD05`: 3 for the four sniper
  arms (weapons 15, 30, 31, 32), 1 for five (9, 11, 17, 22, 44), 2 for
  weapon 40 — `FireDeath` — and 0, the switch's default, for every other
  weapon. Read off the jump table and the byte index by
  `_muzzle_arm_writes`, alongside the wait flag the same arms clear. The
  severity still selects the voice (§4.5); it never selected the death.
* **The arrived flag is set by fourteen arms and cleared by one.** The
  nearest-arm-start attribution of §4.6 missed kind 2, which falls into
  kind 49's tail, and kind 61, whose seeker runs straight into kind 28's
  arm at `0x004204D2`; and it counted arm 45, which writes **`ebp`** — the
  zero the sweep keeps as `aRandom2`'s base — i.e. it *clears* the flag on
  every tick. `blob_runtime.py` had it right all along (fourteen
  `_request_delete` sites and one `global_signal_clear`); the pin is now by
  control flow, `TickResult` carries `global_signal_clear` in both twins,
  and `BlobPool.arrived` applies the arms' writes in slot order. The
  creators' own writes are inventoried too: eight literal 1s, six literal
  0s and twelve `steps <= 0` stores.
* **The damage arm reads the last marked unit, not a stale local.** r2
  labels `[ebp+0x45]` and `[ebp+0x4C]` as stack slots; they are the
  player and type of the unit the sweep looked at last (`[esp+0x34]`), one
  local for the whole switch. So a multi-target shot sprays every damaged
  unit by the last one's player and size — reproduced, and the large spray
  `0x00421360` is reached by a large **target**, as `42` §4.8 said.

Two smaller ones: the end loop waits **at most** 20 frames while the pool
lives (`0x0040E256`..`0x0040E262`), not "at least 20"; and the reaction
drain of `42` §3.3 is not per step — `0x0046CCA0` has five callers and none
is inside `aExecuteMove`, so `core`, which follows `25` §6, stands.

### 29.4 The death creators, all ten measured

`presentation_gold.py` grew five phases: `KillFire` `0x00423AD0` with its
third argument 0 (the fight) and 20 (`FireCircle`), `FireDeath`
`0x0042B1D0`, `FlyingUnit` `0x00429700` on the case's tile — whose record
is the victim type's own `.3DI`, `A_BOX.3DI`, and whose count is pinned so
a model the set does not carry cannot pass as agreement on nothing — and
`FireExplosion` `0x00429A80` as the death switch calls it. All 321 records
across the nineteen calls agree field for field; 182 → **228** checks. The
third argument of `FireExplosion` is pushed by all thirteen callers and read
by none. `Pool.spawn` now refuses a class-0/1 record whose model does not
resolve, as `0x00420950` does.

`godot/game/fx/blob_programs.gd` is the GDScript twin of all ten programs,
and `tests/test_presentation_native.gd` replays the **engine's** records
against it from `--emit-death-cases` — the sixth native suite, 100 checks,
every record of every case. The live pool receives the records through
`BlobPrograms.spawn_into`, drawing from the pool's own generator.

### 29.5 The voice, corrected

`docs/28` §4.1 said ids 53–55 were "named by no call site". They are the
**alien death scream's**: the fight's severity-3 arm loads them with `mov
edi, imm` rather than a `push`, which the site scanner did not read.
Humans die to `SP_HUM_n` @50–52 off the human cursor, aliens to the same
waves @53–55 off the alien cursor, a machine to `explosion.wav` @63, an
object silently. `sound.py` carries `VoiceCursors.death`, `AudioEvents`
`death_voice`, the voices document its two new keys (the converter is
**0.13.0**, both copies), and `blob_tables --check` 449 → **455**.

### 29.6 Decisions of the remake, named

* `SAFETY_FRAMES` = 300, the bound on the two open-ended spins;
* `FloatingTexts.scale()`, 640×480 to the viewport;
* `World.gore_level` defaults to **2**, the game copy's `Game.opt`; the LCL
  `?_` command writes it, as in the engine;
* `SliceMain.DISPLAY_MODE` = 2: the debris loop reads the output mode, and
  the remake plays the software 640×480 mode's arm;
* the animation-slot-0x0B exception to the resume is not reproduced: the
  remake has no animation slot table, and no shipped unit reaches it.

### 29.7 Verification

`bash godot/run_tests.sh`: 31 → **32** suites, 2128 → **2295** checks;
`charisma` 29 → 67 (the speeds, the resume), `effects` 88 → 121 (the
open-ended steps, the flag, the nine stages on a recording host), `game_ui`
→ 110 (a kill through the real pool: the dead record found by its cell,
blood in the pool), `combat_native` → 72, `presentation_native` 100 (new). The suite
minimums in `harness.gd` were raised to match. `remake_convert --check`,
`--check-cache`, and the whole always-run block pass with `__pycache__`
cleared; `user://caches` republished at 0.13.0.

Still to do by hand in the exported build: a shot with its numbers, a
death with blood at level 2, the caption on a kill (`docs/42` §11's rows for
idle, jump, selection, set pieces, environment, AI terrain and the script
camera stand).

---

## 30. 2026-09-03 — the idle is a scheduler, and the bodies stand still between its picks

`docs/42` §6 measured what the engine does with a body nobody is walking or
firing: **nothing**, until one of four slots draws it. The remake looped
every body's `S` clip from the first frame (`92` §7.10's "chosen, not
recovered"), which is not what the original looks like — its map is mostly
still, with one to four figures moving at any moment and each of them
snapping back to its bind pose when its slot lets go.

`game/charisma/idle_scheduler.gd` is `0x004060B0` for the four slots the
refresh runs it on: a positive countdown counts down and nothing else;
otherwise the slot frees what it held, draws `aRandom2(0, 200)` as a unit
index, and takes the unit only if it is alive, its `+0x4F` is 0 (the
**stored** byte, not the display pass — the engine reads the record), it is
not animating, the selector names an idle clip and it has a body; then the
clip plays once at speed 1.5 and the countdown is its length in frames. The
type argument is dead as §6.1 says: it takes unit 0 without a draw when
unit 0 is of the asked type, which is `_C_118`'s boss and nothing else.
`CharismaState` gained `start_idle`, `detach_idle` and `is_idling`; its
default and its `rest()` are the **bind pose**, the last frame is held once
the clip has played out, and the free snaps to bind on the next step. The
selector's randomised arm (`0x0042DF77`) is rolled **per start** off the
pool's own generator — the one `aRandom2` stream the creators, the fight's
coin and the scheduler share in the engine — rather than once per rebuild
off Godot's. Above the camera eye's z of 96 000 the bodies are not
simulated while the slots still run (`0x00406FC0` reads the third output of
`0x00403750`, the position getter; pinned).

**Measured.** `presentation_gold --emit-idle-cases` turns the `idle_random`
phase into a fixture of all two hundred starter calls with the seed and
slot 1's table either side, plus the guard inputs of every unit record, and
`test_presentation_native.gd` replays it call for call: the countdown ticks
draw nothing (91), every later call draws exactly once (109), every draw
is refused by the guard the engine refused it with or takes the one
candidate — the drawn unit, the seed after and the countdown after agree on
all 200 — and the forced start of `idle_pose` runs on the cache's own
`P0_S0_000`: length 90, the clock at 67.5 after 45 steps, at 90 after 60,
held two steps later, bind after the free. `test_render` drives 600 frames
of a `_C_140` map and finds at most four bodies idling and at least one
start.

**The remake's own, named:** the *Cursor and animation level* option is
`IdleScheduler.enabled`; the shared generator's seed is the mission's, as
the pool's already was (the engine seeds `GetTickCount()`).

`bash godot/run_tests.sh`: 2295 → **2317** checks; `presentation_native`
100 → 114, `charisma` 67 → 72, `render` 17 → 19.

## 31. 2026-09-03 — the selection, the jump, the push and the orbits; three rules `core` had not got

Slice C of the presentation plan (`docs/42` §7). What it found is in three
groups: seven more creators measured, three gameplay rules the remake was
missing, and one reading that the plan had wrong.

### 31.1 Seven creators, measured before code

`tools/inclib/blob_creators.py` carries seven more programs read out of
their own instructions — the selection marker `0x00422D40`, the landing dust
`0x004227C0`, the heal and poison flash circles `0x00423030` / `0x004232E0`,
`aBlob_CreateZoomBob` `0x00423720`, the jump's trail `0x00423670` and the
push's dust `0x0042A6E0` — and `tools/presentation_gold.py` has a `death_*`
phase for each: a written `aRandom2` seed, one call with controlled
arguments, the pool read back. The position creators take the marine's own
object through `dbgcall`'s `[$s_m+0x10]` reads, so the arguments are the
engine's and not the model's. `--check` is 228 → **291**; 364 records across
the twenty-six phases agree field for field, the draw count by the seed
either side. Two of the seven were wrong as first transcribed and the
capture corrected them:

* the poison flash's four skulls sit at the **flash** radius (`mov edi,
  0x640` / `0x1900` at `0x004233BF` / `0x004233B0`), not the marker's 4800;
  the reading had taken the heal circle's neighbour for the marker's;
* the trail's four sprites are delayed **by their index** — `push esi`, the
  loop counter, is the constructor's last argument — so a trail lasts four
  frames longer than a single puff.

The rings are the engine's table arithmetic and not a division of the
circle: each offset is the previous one turned by the step through
`0x004039A0`, and the arrows are aimed along the line from the object to
themselves by `0x00403AA0`. The heal flash's three crosses load their model
names by `mov edi, str` rather than `push`, which is why `blob_tables.py`'s
constructor reader had never listed them (`BLOB_MODEL_MOV_SITES`, 30 → 34
models, all in all nine world sets) and why the geometry cache had no
`A_CROSS*.3DI` at all — `CONVERTER_VERSION` 0.13.0 → **0.14.0**, and the
`.3DI` reader meets its first draw kind `0x0C` (the half-blended flat fill of
`docs/31` §4.4) in the shipped effect models. `blob_tables.py` reads all six
new radius and turn constants back out of the creators (`mov r32, imm32` and
`mov word [esp+d], imm16` sites, 455 → 456); `presentation_tables.py` pins
the seven creators' literals and call counts (472 → **533**).

`godot/game/fx/blob_programs.gd` has the seven twins, `Inputs` gained the
type sizes and the Eng3d tables, and `test_presentation_native.gd` replays
the engine's records for all twenty-six phases (114 → 149 checks).

### 31.2 The marker is a flash on a selection, not a ring re-raised per frame

The plan assumed `aUI.cpp` restarts the four arrows every fifteen frames.
It does not. `0x00473920` — gate on the animation level (`0x004604D0`) and a
selected unit (`word [0x5162F8] != 0xFFFF`), then `0x00422D40` — has three
callers: the select routine `0x00471E00` (`0x00471F4C`) and the command pad
`0x004714B0` (`0x00471A49`, `0x00471A72`, after the pad's own refresh). The
frame loop `0x0041C010`–`0x0041D2A0` calls neither it nor the creator; the
four orbits raise the arrows themselves. So the marker is raised **once on a
selection and once after every pad command**, lives kind 14's fifteen ticks,
and is gone until the next click. `main.gd` does exactly that
(`_raise_marker` from `select_unit` and `_after_command`), and
`presentation_tables.py` pins the three sites and the loop's zero.

### 31.3 Three rules `core` was missing

All three are pinned by bytes in `presentation_tables.py` (`heal.*`,
`warp.*`, `drain.*`), transcribed in `inclib/interact.py` and
`inclib/combat.py`, checked by `interact_runtime.py` (59 → **73**) and
`combat_runtime.py` (117 → **126**), and twinned in `core/` with the same
checks in `test_combat.gd` (160 → 192).

**The heal command** (`docs/29` §1.1 button 2, `0x00470890` under the pad
arm at `0x004733BB`). Refused with no movement points. The power is
`0x004753C0`: 3 with a Large Medic Kit (`+0x31`, equipment 16), else 1 with
a Small one (`+0x30`, equipment 15), else 0. The ceiling is `0x00475240`: the
type's hit points for a computer unit, else the type's plus `ep / 12` capped
at **15** — and `0x0047B180` writes `hp + power` only while that stays under
the ceiling, else the ceiling itself, which pulls a record *above* the cap
down to it. The unit in front (`0x004308C0`) is healed when it is under its
ceiling and the healer's own player's; otherwise — off the map, empty, full,
or somebody else's — the healer heals itself, and only that arm answers 0,
when the healer is at its own ceiling. The pad then takes one movement point
if the command answered 1 and there was one to take, and writes `+0x39 = 3`
**either way** — the store at `0x004733F3` is after the join of both
branches. `aPlayHealAnimation(x, y, |delta|)` follows on both arms.
`World.submit_heal` and `Interact.heal_command` are the twins; the remake
has no network, so the arm that relaxes the owner test to players 0..3 is
named and not taken. **The pad's offer is its own gate**: `case 2` of
`0x00472570` shows the button only past `0x0047B4C0` — a kit, and either a
patient in front under its ceiling and of the same player or the healer
itself under its own — and `+0x15 >= 1` (`0x0047262D`). The command behind
it charges a point even when it heals nothing, so a remake that skipped the
gate would sell a press the original never offers; `World.may_heal` and
`Interact.may_heal` are the gate's twins and `main.gd` asks it first, as it
asks `may_use` before a `Use`.

**The player's jump** (`aExecuteWarp` `0x0046EF50` under the pad arm at
`0x00472F10`). `core` had the fill's warp marks and the computer's
`execute_warp`, but no command a player could submit onto a warp cell. The
routine relinks the record and rebuilds the fog for the mover's own player;
it also fires the `MoveUnit` script call itself (`0x0046F196`: var 0x41
written 2, then x, y and the cell's action point, then the hook) — the same
call as a walk's, which `World.submit_warp` makes. The pad's arm, for a
mover still alive, zeroes the movement points, writes `+0x39 = 5` and
drains the reaction queue at the landing cell; a mover the mine arm killed
(no shipped cell carries one) is deselected instead. `combat.warp_unit`
and `ExecuteWarp` are the twins; a click on a cell the last query marked as
a warp target now jumps.

**The drain's jam arm** (`docs/25` §6). After a reaction shot that fired, a
magazine at zero (`+0x3D`) or a heat counter equal to `0x00475340`'s cap
plays the jam orbit `0x004104A0` and clears the reactor's ticket
(`mov byte [esi + 0x59], 0`) — in **both** of the drain's loops, the
campaign's by ticket and the other modes' by slot (`0x0046CE0E`,
`0x0046D090`; `docs/25` §6.1). `core` never cleared the ticket, so a reactor with an empty
magazine kept its place in the queue. `Reaction.drain` and
`combat.drain_reactions` now report `jammed` per shot and clear it.

### 31.4 The sequences

Three new drivers on the `SequenceQueue`, each over the same narrow host
the shot uses (`ShotHost` grew the camera, geometry and body methods they
need) so that `test_effects.gd` runs them on a recording double:

* **`OrbitSequence`** — the six orbits of `docs/42` §7.5 and the jam of
  §7.4: raise (the arrows, or a flash circle), fly to the start offset
  (`(0, +0xC80, h + 0xC80)`; `(0, +0x1900, h + 0xC80)` for heal and poison;
  `(0, +0xC80, h)` for `RotatingCamera`), the centred caption (overlay 3)
  and the wave, forty frames turning the eye's offset by +100 or −40 through
  `0x004039A0` with the camera set each frame, and the flight back to the
  six numbers read at the start. `test_camera.gd` runs the skill and the
  heal orbit on a real rig with the cache's tables: 4000 and 2496 of 4096
  swept, the radius kept, the eye back where it began. The overheat orbit's
  kind is `0x0040F420`'s own — 1 the carrier destroyed (text 14, and the
  unit hidden behind `FireExplosion` and `BloodFlood(x, y, x, y, 0)`), 2 a
  jam (15), 3 damage (16) — read off the `dec eax / je` ladder at
  `0x0040F5A4`, not off `docs/42`'s row order, which listed them as if the
  ids ran with the severity. The skill and overheat orbits are queued
  **ahead** of the shot's nine stages, where `aAttackUnit` plays them.
* **`JumpSequence`** — `0x00411460`: the body turned to the landing cell,
  the source object lifted by `0x0047AD30(0)` = 2400, `steps = max(|dx|,
  |dy|) / 480` frames along `0x0046D400`'s direction times 480 with `vz =
  (steps / 2) * 160 + dz` falling 160 a frame, the target on the flyer and
  the eye kept, the trail at `z + 0x640` each frame for the player's unit,
  the landing dust at both ends with `jump.wav` and `drop.wav`; a computer
  unit draws `aRandom2(0, 3)` once for `S_ALI_n` and raises no dust at the
  source (the dust call at `0x004117A1` is on the player's arm alone). The
  replay's interim `focus_on` for a computer warp is gone — and with it its
  `Fog.is_drawn` test, on purpose: `aExecuteWarp` plays the jump whenever
  its fifth argument is 1 (`0x0046EFE2`), which the computer's call passes,
  and neither it nor `0x00411460` reads `+0x4F`. A hidden alien's jump is
  therefore an invisible flyer the camera's target follows, which is what
  the remake does too: a slot the fog gives no node has nothing to place,
  and only the target moves.
* **`PushSequence`** — `0x0046D530`: the flight to `0x0047AD30(pusher)` =
  half the height plus 800 above the pusher, looking at the same height
  above the pushed object; four frames a cell moving the object by a third
  of what is left with a dust puff at its position each frame, then the
  snap to the cell at `+0xA0`; a hole's fifty steps of `z −= 320`; the pool
  waited for, and no flight back.

The jump's and the push's arithmetic is **read, not measured**: both
routines render inside the frame loop and cannot be called under `dbgcall`,
which is the same limit `docs/42` §4's nine stages have.

### 31.5 What the corpus says about the poison sweep

`0x004706A0(player)` — two fitness points off every one of the player's
units standing on a control-type-6 cell, with the poison orbit — has one
caller, `aInitBattleGround` `0x00419D90` (`0x0041A6D1`), which the main
loop and the main controller run at mission start; the hand-over does not
call it. Four placed units in the whole corpus stand on a type-6 cell at
start, all in `_C_118` and all the computer's (slots 0, 34, 35, 36), and the
sweep at start runs for `aGetCurrentPlayer()` (`0x0043B2C0` at
`0x0041A6C6`, `docs/22` §9), who at mission start is human. The sweep is
therefore unreachable in the shipped game and is **not modelled**; the
poison orbit and its flash circle are implemented and measured for the
`FlashCircle` the plan asked for, and nothing calls them yet.

### 31.6 The remake's own, named

* `JumpSequence.POOL_WAIT_FRAMES` and `PushSequence.POOL_WAIT_FRAMES` = 60:
  the engine spins until the pool is empty with no bound; the remake's
  bound is longer than any record the two leave lives.
* `FloatingTexts.set_centred_caption` centres overlay 3's text over the
  viewport with the label's alignment; the original centres by the text's
  pixel width in a 640-wide frame.
* The heal's keyboard binding (H) and the warp's click on a marked cell —
  the pad's buttons are not drawn; `docs/29` §1.1's command ids are what
  they map to.
* `OrbitSequence` plays no wave of its own for the overheat: the shot's
  cues already carry `AudioEvents.overheat_cue`, and the engine's orbit
  would play the same file a second time from inside `aAttackUnit`.

### 31.7 Counts

`presentation_gold --check` 228 → 291; `blob_tables` 455 → 456;
`presentation_tables` 472 → 538; `interact_runtime` 59 → 77;
`combat_runtime` 117 → 126; `bash godot/run_tests.sh` 2317 → **2464**
checks (`combat` 160 → 197, `effects` 115 → 173, `camera` 135 → 147,
`game_ui` 114 → 124, `presentation_native` 114 → 149).

### 31.8 Left open

* The jump's and the push's frames are unmeasured (§31.4) — a capture would
  need a hook that steps the routine outside the frame loop.
* `RotatingCamera` is wired in `OrbitSequence` but not yet driven from the
  LCL event; slice F's script cameras take it.
* ~~The alien's jump scream is drawn from the pool's stream as the engine
  draws it, but which of the three waves each draw picks is read off the
  `je` ladder at `0x00411950` (0 → `S_ALI_0`, 1 → `S_ALI_1`, 2 →
  `S_ALI_2`) and not heard under Wine.~~ **Closed 2026-09-13** —
  `presentation_gold.py`'s `jump_scream` phase: the uncounted stream's live
  seed read at the anchor, three hundred `aRandom2(0, 3)` values as the x87
  returned them and the seed after each; `inclib.rng.ARandom` reproduces
  every one from the seed read first, every value lies in `[0, 3)`
  (0.0072 to 2.9994 in the capture), the truncated draw takes all three
  arms (86 / 103 / 111) and the `jne` to `0x004117A9` — the join the
  player's arm reaches after its landing dust, the head of the flight loop,
  with no wave loaded — is unreachable because the seed is kept below the
  modulus. The ladder's
  three targets are decoded from the displacements and each arm's
  `push <id>` and wave-name push are read back: 59 `S_ALI_0`, 60 `S_ALI_1`,
  61 `S_ALI_2`. Audio itself is not capturable from this shell; the draw and
  the ladder are the whole of the claim, and both are measured now.

## 32. 2026-09-03 — the set pieces get their camera and their effects (D-a)

Slice D-a of the presentation plan: the rows of `docs/42` §8 that the
cached missions reach. Eleven more creators measured, four sequences that
were instant made animated, and the camera each one moves.

### 32.1 Eleven creators, measured before code

`tools/inclib/blob_creators.py` carries all eleven as programs read out of
their own instructions, and `tools/presentation_gold.py` has a `death_*`
phase for each (twelve phases: the laser barrier is taken twice, along
`+y` and along `-x`, because its direction switch is the only argument
that changes the geometry). **All twelve agreed field for field on the
first run** — 239 more records, `--check` 291 → **399**:

| Creator | What it leaves |
|---|---|
| tube puffs `0x00423770` | fifteen **pairs** of class-2 sprites at the object, kind 10, life 20, aux 10, each pair delayed by its index |
| platform dust `0x004234C0` | four sprites at the block's corners, 4800 out and 1600 up, kind 10, life 12 |
| ground-unit debris `0x00422610` | twenty `A_DEBRIS` and four `A_SPLAT1`, kind 29, life 50, thrown 300 up; the third draw is taken and **discarded** (`fstp st(0)`) |
| roof-unit debris `0x00422460` | the same twenty and four, kind **0**, with that third draw kept as the vertical: `aRandom2(40, -100)`, a span the wrong way round, so the pieces fall |
| crush-wall debris `0x004238C0` | thirty sprites scattered ±1600 (seven draws each) and five `A_DEBRIS` of kind 5, life 100, spun by three draws of 0..4095 |
| fire-circle ring `0x00422F00` | 150 flames on a ring of a field's radius, each offset the previous turned by **60**, a field *below* the object, delayed `i / 8` |
| laser barrier `0x00428990` | three dots one field back along the line, then three `A_LASERG.3DI` per count a field further; no draw |
| statue beam `0x00428BF0` | `2 × cells − 1` dots stepping 1600 along the line at z 3200, then six sparks with rotations alternating `(0, 3)` and `(2, 0)` |
| teleporter stream `0x0042A120` | two hundred records one every 16 units up, each with a **point** near the target in its velocity slots; four draws, every one converted with its addend inside |
| bomber `0x0042A8E0` | one `L069EE00.3DI` flying a field a tick along the direction; it clears the *arrived* flag |
| para bomb `0x0042B070` | one `A_PARAB1.3DI` dropped from 48000, its life the fall from 35200 at 800 a tick |

`blob_tables.py` reads thirteen more constants back out of the creators
(three doubles and ten immediates, through four new site encodings — `cmp`
with an 8- and a 32-bit immediate, `add r32, imm8`, and a signed `push`);
`presentation_tables.py` pins each creator's record counts, kinds and
lives, and the camera sites of the six sequences below (533 → **583**).
`godot/game/fx/blob_programs.gd` has the eleven twins and
`test_presentation_native.gd` replays the engine's records for all
**thirty-eight** phases (149 → 209 checks).

### 32.2 The camera, and four sequences that were instant

`game/setpiece/setpiece_camera.gd` is a layer over `SetpieceDriver`: the
same frame counts, with the camera and the creators each routine adds
around them. It takes the same `ShotHost` the shot and the orbits use, so
`test_effects.gd` runs every one of them on the recording double.

* **`OpenDoor`** — a flight from the opener's head (`0x0047AD70` twice) to
  the panel at the same height, ten frames, a flight back. It runs for the
  player's own Use and for the computer's opener, both of which pass real
  tiles; the LCL wrapper passes `-1` and gets no camera, which is the
  routine's own test (`cmp esi, -1`) and is checked as such.
* **The three tubes** — `OpenTube`, `OpenPlantTube`, `OpenFrontDoor`:
  **nineteen** frames (`cmp esi, 0x13`), no flight, and `OpenTube` alone
  raises its puffs on the tenth (`cmp esi, 0xA`). They were `INSTANT`.
* **`Elevator` and `Platform`** — the eye kept, one flight of the target to
  the block, then the target set on it every frame; the platform raises
  `0x004234C0` at the block each frame.
* **`RoofUnit`** — the target flown to the drop's start, the debris there,
  five lead frames, then the fall with the target on the body and the body
  drawn 160 above its z, the landing dust, the pool waited for.
* **`GroundUnit`** — the body placed 3200 below the ground cell's top less
  its own height, the debris 1600 above the object, **eight** frames of
  1120 up drawn 1280 higher, **six** frames carrying it a fifth of the way
  to its own cell, the dust. It was `INSTANT`.

`SetpieceDriver.ANIMATED` is now eleven kinds and `INSTANT` fourteen; the
two lists are still disjoint and still checked.

### 32.3 The remake's own, named

* `SetpieceCamera.POOL_WAIT_FRAMES` = 100, as the jump's and the push's:
  the engine spins with no bound.
* The tube's **object rotation** (`add word [edi + 0x26], 0x33` a frame) is
  not drawn: the remake's scenery has no per-object rotation yet. The cell's
  state flips as it did, and the puffs are there.
* `RoofUnit`'s four-frame wait for an odd type's scream is not taken — the
  sound layer plays the cue without holding the picture.
* The `L110EX00.3DI` object `GroundUnit` inserts is in no cached world set,
  so nothing is inserted; the debris and the dust are.

### 32.4 Counts

`presentation_gold --check` 291 → 399; `blob_tables` 456 (four new site
encodings, thirteen more constants); `presentation_tables` 538 → 583;
`bash godot/run_tests.sh` 2464 → **2590** (`effects` 173 → 238,
`presentation_native` 149 → 209).

### 32.5 Left open

The rows of `docs/42` §8 no cached mission reaches are still `INSTANT` and
still say so: the statue and its beam, the laser barrier, the crush wall,
the teleporters, the bomber and the para bombs, the fire circle. Their
**creators are measured and their twins are in `blob_programs.gd`** — what
is missing is the driver that walks each routine's own frames, which is
slice D-b.

## 33. 2026-09-03 — the rest of the set pieces (D-b)

The rows of `docs/42` §8 no cached mission reaches. Their creators were
already measured in §32; this is the driver that walks each routine's own
frames, so `SetpieceDriver.ANIMATED` is now **eighteen** kinds and
`INSTANT` eight.

| Sequence | Frames | What the picture does |
|---|---|---|
| `Statue` `0x00413A40` | 13 + 1 | a flight to `push 0x7D00` = 32000 above the camera's own position looking at the statue; the object's rotation word turned by +80 a frame and then written its original plus a quarter turn; the beam: `FireDeath` on each unit in the path, hidden, and `0x00428BF0` from the statue to the last cell each way; the pool |
| `Statue2` `0x00414000` | 1 | the same without the turn: one axis, one beam, up to nine cells |
| `barrier_on` `0x00413560` | 40 | the beam `0x00428990` along the direction, a flight to it, forty frames, `BloodFlood` and `FlyingDebris` on every unit it killed, the pool |
| `FireCircle` `0x004131C0` | 10 | `KillFire` with delay **20** on the eight neighbours (`cmp ebx, 7`), a flight, the ring `0x00422F00`, ten frames (`mov esi, 0xA`), the pool |
| `CrushWall` `0x00415C70` | pool | `0x004238C0` on each cell, then the pool |
| `ParaBombs` `0x004160F0` | *arrived* | the bomber in from `mov edi, 0xFFFFC180` = -16000, **y 0** (`xor ebx, ebx`) at **320000** -- the routine has two height arms and its `flightpath` argument picks them (`0x00415F59`: 0 → `0x4E200`, 1 → `0x13880`, anything else its own *unknown flightpath* assertion), and the four shipped calls all pass 0 -- one `0x0042B070` per tile, ending on the flag of §4.6 |
| `teleporter` `0x004164F0` | 70 | the stream `0x0042A120`, the camera target on the pool's first live record between frame 40 and frame 10, the traveller hidden at 40 and shown at 10 |

**The paths are re-walked in `game` from the terrain**, not carried on the
event: which cells the beam crossed is a fact about the map that the
picture may read, and the statue's axis is the cell's own `+0x0B` bit 0
after the routine flips it (`0x00413C31`) -- 0 fires along y, 1 along x. The **para
bombs' tiles are the exception** and are now on the event — they come from
the mission's own generator, and drawing them again in the picture would
move the seed a second time. Both interpreter twins append them after the
count (`lcl_runtime.py` and `core/lcl/lcl_interpreter.gd`); the change is
additive and `lcl_runtime --check` is unchanged at 34.

### 33.1 Left open

* **The statue's beam kills nobody in `core`.** Both interpreter twins'
  `Statue` and `Statue2` arms emit `[x, y]` and change no unit: the hide,
  the `FireDeath` and the `aRemoveUnitElement` of `docs/42` §8.1 are not
  modelled, so `SetpieceCamera` draws the beam and no victim. The picture
  is right about where the beam goes and silent about who is under it.
  That is a core gap of §31.3's class and is **not** closed here.
* **The statue's `+0x0B` bit is never flipped in `core`.** The routine
  flips it and the *result* picks the beam's axis, so a second `Statue` on
  the same cell alternates; neither twin writes the byte, so the remake
  fires along the same axis every time.
* **The bomber's target triple is UNVERIFIED.** Its entry is read
  (`-16000, 0, 320000`); where it flies to comes from two of the routine's
  own locals that were not traced, and the picture aims it at the box's
  cell.
* **The teleporter's rule is still not in `core`.** `aExecuteMove` breaks
  out at field type 9 and calls `aExecuteTeleporter` (`docs/26` §5): the
  exit is found by scanning for a field type 10 with the same action point,
  an occupied exit kills the traveller and books a loss, and otherwise the
  unit is relinked. Both twins record the event and **change nothing**, so
  the sequence above has no traveller to move on the 21 shipped entries
  that do pair. That is a sixth core gap of the same class as §31.3's
  three, and it is not closed here.
* `CrushWall` is given its own cell only; the routine runs its creator on
  every cell of the wall, and which those are is not on the event.
* The statue's own object rotation is applied to the record `core` holds,
  not drawn — the same limit the tube's has (§32.3).

## 34. 2026-09-03 — the script's camera, and two decisions revised to the engine's

### 34.1 The camera commands (`docs/42` §2.4)

`game/setpiece/script_camera.gd` drives the six the mission scripts use,
each read out of its own handler and each a **flight** through
`0x0040EEE0`, queued like every other driver so a script that moves the
camera twice shows both moves:

| Command | What it sets |
|---|---|
| `MoveCamera (fx, fy, tx, ty, h)` `0x00441AA0` | the eye on the first tile's object at `h * 1600`, the target on the second's at z 0 — 230 uses |
| `MoveTarget (x, y)` `0x00441C40` | the eye kept, the target on that object at z 0 |
| `MovePosition (x, y, h)` `0x00441D00` | the target kept, the eye on that object at `h * 3200` |
| `RotatingCamera (x, y, h)` `0x00440FC0` | the orbit of §7.5 around the tile at `h * 160` |
| `SaveCamera` / `LoadCamera` `0x00441B90` / `0x00441C00` | all six numbers pushed to and popped from the scene's own stack, the engine's `0x0050C088` |

`OrbitSequence` grew a cell argument for the one orbit that has no unit.
`MoveWorld` is deliberately not here: it translates the scene
(`0x00407E30`), which is the scenery's business. The mode the rig is left
in is `View.SCRIPT`, which is mode 0 — "what a script leaves behind".
`test_lcl.gd` runs all six on a recording host.

### 34.2 Two decisions revised, both to the engine, both behind a flag

The plan's principle is that the original is the standard, so two of
`docs/92` §7's choices are revised:

* **§7.5.5, the fog probe.** `0x00481F00` saves every `+0x4F`, rebuilds the
  fog for the current player, and restores the bytes — but **not** the
  orders `alert_group` promotes, so every player command wakes the groups
  that player can see and they stay woken. This remake called that a bug
  and declined to reproduce it; it reproduces it now, in
  `World.probe_fog()` called once from the start of every player command
  where `aViewPlayer.cpp`'s dispatcher calls it. The wake is the pass's
  **own** line-of-sight arm -- `Visibility.probe` runs `_pass` with it and
  puts every `+0x4F` back afterwards -- so a scan blip and the beacons the
  pass marks without a sight wake nobody, and only the computer's own units
  (`player == 0xFF`) are promoted. `Visibility.states_for` stays a pure
  query, which is what the player *sees*.
  `World.COMPAT_FOG_PROBE_QUIET` restores the quiet probe.
* **§7.5.3, the camera on hand-over.** The engine's hand-over calls no
  camera routine (`docs/42` §2.6), so neither does this any more.
  `SliceMain.COMPAT_CAMERA_RETURNS` restores the remake's own return to the
  first friendly unit, which is what made 4 of 4 of the squad visible when
  the turn came back instead of 0 of 4. The measurement stands; the default
  does not.

Both flags are in the world's `compat_flags`, so both reach the canonical
hash and a save records which game it was.

### 34.3 The para bombs' tiles

`ParaBombs` draws sixty candidate tiles from the mission's generator and
keeps the free ones. Both interpreter twins now put those tiles on the
event after the count, because the picture drops one bomb on each and
re-drawing them there would move the seed a second time. Additive in both;
`lcl_runtime --check` is unchanged at 34.

## 35. 2026-09-03 — the computer's door, and the terrain in the event's own frame

`docs/42` §10's row: the terrain a computer turn changed was applied in
`core` when the event happened and drawn **all at once** before the replay
started, so a door the computer walked through opened at the top of the
replay and everything else caught up at the end.

Two halves, and the first is a rule rather than a picture.

**The AI's `open_door` did not open the door.** Both twins stopped at the
facing, the movement point and the *acted* flag, on the reading that
`aDoorOpenSequence` is a set piece; but `0x0040A600` **calls** that sequence
at `0x0040A6B5` and keeps its answer, so in the engine the panel goes down.
Both twins now call `toggle_door` at the cell -- the same routine the
player's Use reaches -- and neither rebuilds the fog, because both of the
sequence's rebuild sites are guarded by `aGetCurrentPlayer() != 0xFF` and
the computer holds the turn. `ai_runtime --check` is unchanged at 71 and
`ai_gold --check` at 47, so nothing the capture measured moved;
`test_ai.gd` checks the flip, the height, the field type and the event.

**The cells ride on the event.** `AIEvent`'s payload carries the indices the
event changed, and `_on_ai_step` paints exactly those before the event's
body plays -- **unless** the event queues a set piece of its own, which owns
the cells it animates: painting the door to its final height and then
running its ten frames would snap it open, snap it shut and animate it open
again. The whole-map redraw at the end of the replay stays, so a list that
is short costs nothing.

Two things a review caught in the first cut of this, both fixed: the
context's `grid` is a **copy** of the world's cells, so writing only the
world left the guard reading "closed" and a second unit beside the same
door toggled it shut again; and the beam walk of `barrier_on` looped for
ever on a direction outside the eight, because the out-of-range answer is
the zero step.

### 35.1 The turn banner, read and not built

`0x0047C2C0` is **not** a banner. It blanks the whole frame
(`0, 0, 639, 479`), then draws centred text at (320, 160/190/200/220) with
`"%s %d"`, `"%s (%s %d)"`, `"%s (%s %d) - %s"` and `"*** %s %s ***"` from
`Txtmod` ids 12, 20, 22, 25, 26, 125, 127 and 132, over a seven-arm switch
on `0x0047DBD0`'s answer. It is the **between-players screen**, and the
remake's HUD line is not a smaller version of it. Building it is a piece of
interface work rather than a presentation one, and it is left open with
this reading written down rather than half-built.

## 36. 2026-09-03 — where the presentation plan stands

> **Superseded the same day by [§41](#41-2026-09-03--the-three-rule-gaps-and-the-four-presentation-tails).**
> This list was written before slice E was built (§37–§38) and before the three
> core gaps and the four presentation tails below it were closed. It is kept as
> written rather than edited, because the items it names are what §37 onwards
> answer one by one. §41.6 has the list as it stands now.

Slices A through D and most of F of the mission-presentation plan are in.
What is **not**, with the reason:

* **Slice E, the environment (`docs/42` §9).** The special-object state byte,
  its four animated states and the four placers are read and pinned, and
  nothing is built. The blocking question is not the picture: it is that the
  three arms which change the map -- weapon 40's nine fires, weapon 42's
  mine, weapon 43's shield -- live in `aPlayFightAnimation`, the
  **presentation** routine, and not in `aAttackUnit`. Where they go in a
  remake whose `core` owns no drawing is a design decision of the same
  weight as `docs/92` §7's, and it wants the project owner rather than a
  guess. The converter's model list, `CONVERTER_VERSION` and the republish
  ride on that answer.
* **The teleporter's rule** (§33.1) and **the statue's kills** (§33.1) --
  two more core gaps of §31.3's class, both read and neither modelled.
* **`CrushWall`'s cells**: the routine runs its creator on every cell of the
  wall and only the command's own cell is on the event.
* **The between-players screen** `0x0047C2C0` (§35.1): read, not built.
* **The jump's and the push's frames** are transcribed and not measured
  (§31.4); both routines render inside the frame loop and fault under
  `dbgcall`, which is `docs/42` §4's own limit.
* **The skill orbit has no campaign gate.** `0x00410190` opens with
  `0x0043B740 == 1` and this does not test it; the remake is campaign-only
  today, so it is named here rather than added.
* **Slice G's by-hand pass** has not been run: everything above is checked
  by the suites and the captures, and nobody has watched it.

Everything that *is* in is green: the whole always-run block, the four gold
captures (`presentation_gold` 399, `blob_gold` 259, `ai_gold` 47,
`turn_gold` 197, `movemap_gold` 41) and `bash godot/run_tests.sh` at 32
suites and **2632** checks.


---

## 37. 2026-09-03 — the environment, and the three weapons that change the map (E)

Slice E of the presentation plan: the four **cell placers** of
[`42` §9.1](42-mission-presentation.md), the rules they write, the round tick
that takes them back, and the objects the picture draws for them. The division
the slice was built on is the one the instructions settle, not one this project
chose: an arm that writes `cell[+0x10]` is a rule and goes into `core`, an arm
that only fills an object slot is a picture. Reading the four placers put the
mine and the shield on the first side and the ground fire's *glow* on the
second.

### 37.1 What was wrong before it

Four things, all of them `core`'s:

1. **Weapons 40, 42 and 43 changed nothing.** `aPlayFightAnimation`'s impact
   switch selects an arm per weapon id, and three of the forty arms place a
   transient object: 40 calls the fire placer **nine** times around the target
   (`0x0040D962`…`0x0040D9FF`), 42 lays a mine (`0x0040D76A`), 43 a shield
   (`0x0040D5F8`). `MapState.EFFECT_SHIELDED` was *read* by the move map and
   written by nobody.
2. **`ParaBombs` drew its sixty tiles and wrote none of them.** `0x00470845`
   lays a mine on every tile with no unit and `+0x10 == 255`.
3. **The entry point burned wrong.** `execute_use`'s id-70 arm wrote
   `+0x10 = 6` — not a value the byte takes — and subtracted `0xA0` from the
   cell's **height**. `0x0046E0BF` writes the action point 71 first and then
   calls `aMakeFire(x, y, 6, cellHeight - 0xA0)`; the 6 is the fire's
   *subtype*, the placer writes `+0x0E = 6`, `+0x0F = id` and `+0x10 = 1`, and
   the `- 0xA0` never leaves the placer's own half-a-field window test. Nothing
   writes the height.
4. **Nothing ever cleared any of it**, because nothing had written any of it.
   `0x0047D600` runs `0x00470AB0()` and `0x0042ED60()` between the turn counter
   going up and the `NEXT TURN` event, so the decay is a **round** tick.

### 37.2 The four placers, read

| routine | writes | gate |
|---|---|---|
| `0x0042F840` fire | `+0x0E` subtype, `+0x0F` id, `+0x10 = 1` | action point **71** *or* field type ∈ {0,1,6,8}; `abs(cellHeight − z) < 0x640`; refuses a cell whose `+0x10` is 3 and **deletes** any other object there |
| `0x0042FA70` mine | `+0x0E = 0`, `+0x0F`, `+0x10 = 2` | field type only; deletes nothing, refuses nothing |
| `0x0042FB90` shield | `+0x0E = 2` **first**, `+0x0F`, `+0x10 = 3` | field type; returns early when `+0x10` is already 3 — so a second Plasma hit refreshes the countdown and makes no second object |
| `0x0042FCB0` glow | `+0x11` id, `+0x12` phase, `+0x13 = 4` | none at all; writes nothing on failure |

The fire placer's first gate is the cell's **action point**, not a prototype
letter: `cmp al, 0x47` at `0x0042F894` is 71, `ENTRY_POINT_DESTROYED`. That is
why a destroyed entry point burns whatever its field type says, and it is the
one line that makes item 3 above a two-part correction rather than one.

Weapon 40's nine calls are a 3 × 3 block on the target cell: the centre at
subtype **4** and the eight neighbours at **3**, every one of them passed the
**centre** cell's height, so a neighbour half a field or more above or below it
does not catch. Subtype selects the model — 0/1 `A_FIRE3`, 2/3 `A_FIRE2`,
otherwise `A_FIRE1` — so the centre burns biggest and longest.

The target cell is the one `aAttackUnit` adjusted: `0x0046B535`…`0x0046B57A`
replaces arguments 2 and 3 with the standing unit's own `+0x42`/`+0x43` before
anything else, and `0x0046C050` reloads argument 2 into `ebx` for the call. So
the placers land where the *victim* stands, not on the raw aim point — and they
run whether the shot hit, missed or found nothing, because the impact switch
reads no outcome.

### 37.3 The round tick, and the ground fire that kills

`0x0042ED60` sweeps every cell once per round:

| `+0x10` / `+0x13` | what one round does |
|---|---|
| glow at phase 2 | the object is deleted and a phase-1 glow made in its place |
| fire | the object is deleted; `+0x0E ≤ 1` puts it out (`+0x10 = 255`), otherwise it is re-placed one subtype lower |
| shield | `+0x0E == 1` deletes it and clears the cell, otherwise `+0x0E` and the **object's** subtype both go down one |
| mine | nothing — a mine stands until something walks on it |

So a weapon-40 centre burns four rounds and its ring three; a shield lasts two,
turning at 51 units a frame and then at 25.

`0x00470AB0` runs **first**, and it is the other half of `SetGroundFire`: every
cell whose glow has reached phase 1 has its object freed, `+0x13` cleared and
`aPlayGroundFireAnimation` `0x004157B0` played on it. That routine is not only
an animation. It collects the eight neighbours through `0x004308C0` **with the
diagonal flag set** (`push 1` at `0x00415963`) plus the centre, skips any cell
whose `+0x10` is a shield, hides each unit's object, drops blood and debris on
it, and then calls `aRemoveUnitElement` `0x004779C0` for every one of them.
There is no roll and no armour: **a ground fire kills whatever it reaches.**
The fuse is two hand-overs — laid at phase 2, decayed to 1 by the tick, burnt
by the next round's sweep.

`aRemoveUnitElement` bumps the hero counter, frees the 3D object, clears the
cell link and — with its own last instruction, `0x00477ABD` — zeroes the hit
points. Both twins do exactly that. §38.2 first read this the other way round;
§40.1 corrects it with the instruction.

### 37.4 `SetGroundFire` works in one world set

The capture found this rather than the listing. `special_glow` calls
`0x0042FCB0(x, y, 2)` in the live engine on the fixture save and the engine
writes **nothing at all** — no cell byte, no array slot. `aCreateSpecialObject`
resolves the model name through `0x004038F0` and answers -1 for one the loaded
world set does not carry, exactly as `28` §7.5 records for the blob models, and
the fixture save is on `World_A00`.

Reading the nine containers: every set carries `A_FIRE1/2/3`, `A_MINE` and
`A_SHILD`; **only `World_D00` carries `GLOW1.3DI` and `GLOW2.3DI`**. The two
missions that use `SetGroundFire` — `_C_116` and `_S_007` — are both `D00`. It
is a designed pairing, not an accident, and it means the command is inert in
any set it was not written for.

The model gate is therefore part of both models: `CtrlMap.models` /
`MapState.special_models()`, filled from the geometry document's new
`special_models` list. A world built without it will let a `SetGroundFire`
appear to work where the engine does nothing.

### 37.5 The mine on a walked path now fires

[`26` §6.2](26-interaction.md) closed the question in 2026-09-01 and the remake
carried a `TODO:` because the fix needed a `core` change. It is taken now, and
it needed no new decision: every cell-based detonation runs
`aDeleteSpecialObject(cell[+0x0F])` and fires only when it answers non-zero,
and the placers now write `+0x0F` beside `+0x10`. The native probe's synthetic
mine — the effect byte on an ordinary cell with no object — still returns FALSE
and still detonates nothing, so `movemap_gold.py --check` is unchanged at
41/41. `MoveMapHooks` gained `delete_object` and `detonate` whose **defaults
are the probe's answer**, which is what keeps a capture taken before they
existed honest.

The push arm and the defuse were brought onto the same guard, and both twins
free the array slot.

### 37.6 What was measured

`presentation_gold.py` gained eight phases, one process each, at `91`'s anchor
with the fixture save. Each loads the mission, reads the **whole** control map
and the **whole** 80-slot array `[0x004FA828]`, calls one placer with
controlled tiles, and reads both back — so what is compared is not the cell the
placer was aimed at but every cell and every slot:

| phase | what it reaches |
|---|---|
| `special_fire` | the nine-fire arm's centre, at the cell's own height |
| `special_fire_out_of_window` | the same call a full window above — refused, nothing written |
| `special_fire_over_a_mine` | a fire on a mine: the mine's object deleted, no detonation |
| `special_mine` | `+0x0E = 0`, `+0x0F = 0`, `+0x10 = 2` |
| `special_shield` | twice — the second refreshes `+0x0E` and makes no second object |
| `special_fire_onto_a_shield` | the fire refuses the cell outright |
| `special_glow` | §37.4: nothing, because `A00` has no `GLOW1` |
| `special_tick` | a fire, a shield and a glow, then two round ticks |

`--check` is **544/544** (was 399), and `inclib/ctrlmap.py` reproduces the
engine field for field on the first run. `--emit-special-cases` turns the same
capture into `tests/fixtures/presentation/cases_special.json`, which the new
`test_ctrl_map.gd` replays: 34 checks at oracle **`native-runtime`**, the third
suite in the project to earn that label.

The static side: 41 new pins in `presentation_tables.py` (**624/624**) — the
impact switch's three arms by weapon id, the nine call sites with the subtype
each pushes, every cell write of all four placers, the tick's extinguish
threshold and its shield decrement, the ignition sweep, and the two calls the
hand-over makes. New model checks: `combat_runtime` **147/147**,
`interact_runtime` **79/79**, `lcl_runtime` **43/43**, `turn_runtime`
**60/60**, `movemap_runtime` **29/29**.

### 37.7 What the picture does, and what is the remake's

`game/special_objects.gd` draws what the cells say and turns it every displayed
frame, on the same 20 fps clock the effects use: the fire's two flame
billboards take a fresh `aRandom2(0, 4096)` heading each, a mine turns +51, a
shield +25/+51/+102 by its subtype, a glow a fresh random heading. It owns no
state but the last snapshot it drew — an object exists exactly while a cell
says it does — and it draws through [BlobModels], which was made reusable
(`place`, `keep_only`) rather than copied: a special object is a record of the
same shape with the same three joint triples.

*(The paragraph that stood here said the positions were the remake's, because
the rules need the slot and not the position. That was true of `core` and
wrong about the picture: §38.4 measured them.)*

**All four things this section first listed as open are closed in §38.**

### 37.8 Storage, and the versions

`MapState` went from four effect columns to **six**: the glow lives in `+0x11`,
`+0x12` and `+0x13`, and a model that stopped at `+0x11` could carry its slot
index and neither its phase nor the byte that says it is there. The converter
emits `effect4` and `effect5`, the canonical hash covers them, and both
`CONVERTER_VERSION`s went to **0.15.0** with `SaveCodec.SCHEMA_VERSION` to
**8** — the mine detonation changes `core` behaviour, which is what that
version is for. `user://caches` was republished.

`+0x12` is the byte `10` §4 recorded as *"set on 44 of 184162 cells, no
correlation found"*. It is the glow's phase; with `+0x13` at 255 on every
shipped cell those 44 are inert leftovers of the editor, and the entry can stop
saying no correlation was found.

The 80-slot array is **derived**, not stored: `aBuild3DSpecialObjects`
`0x004079D0` rebuilds it from the same cell bytes after every load, so
`MapState.rebuild_objects()` runs at both loading boundaries and the array is
neither hashed nor saved.


### 37.9 What a second reading of the wiring caught

Four things the suites above could not have, because they exercise the models
and not the game:

1. **The picture would never have appeared.** `_redraw_terrain_now` returned
   early when `TerrainDiff` reported nothing, and `TerrainDiff` deliberately
   does not look at the effect planes — they change what stands on a cell, not
   what the cell is. A mine, a shield and the round tick's decay change nothing
   else, so the objects synced only when something *also* moved or died.
   `SpecialObjects.sync` runs before that return now and answers the cells it
   touched, which join the overlay's rebuild: a mine's tint was as stale as its
   model.
2. **The computer never detonated.** The clearing went into
   `ExecuteMove.execute` and the shot was left to the caller;
   `World.submit_move` fired it and `AIPlan` did not. The aliens are the
   **only** mover the fill lets into a mine cell, so that was the rule's main
   consumer rather than an edge. Both twins fire it now and both put a
   `mine_detonated` event on the walk — which the Python one had to do *after*
   the relink, because `aExecuteBomb` marks cells and reads whoever is standing
   on them. `ai_runtime.check_mine` walks an alien onto a placed mine and the
   blast kills it; `test_ai._a_mine_under_an_alien` is the GDScript half.
3. **The blast had no picture.** `_present_mine` draws it as the shot it is:
   `aExecuteBomb` calls `aPlayFightAnimation(x, y, x, y, ...)` with source and
   target on the bomb's own cell, and that routine's `sx == tx && sy == ty` arm
   reads no shooter and takes weapon 36. The mover is passed as the slot
   because the stages need a body to hold the camera on, and it *is* the unit
   standing there.
4. **The warp landed on mines for free.** `0x0046F088`..`0x0046F109` carries
   the identical guard, and both twins said "not simulated: no shipped cell
   carries one" — true of the authored maps and no longer the whole story.
   `aExecuteWarp` detonates before it rebuilds the fog, and the rebuild is
   behind the same `+0x16` gate: a mover the mine just killed rebuilds nothing.

And one narrower: `CombatWorld.ctrlmap()` used to materialise `action_point`
and `field_type` as zeros for a world that had not filled them. Field type 0 is
one the placers accept, so that world would have burned everywhere; it raises
now, which is what `interact._require_cells` already existed to do.


---

## 38. 2026-09-03 — closing slice E's four loose ends

§37.7 listed four. All four are closed; two of them by measurement that had
looked out of reach, and one of the answers is not what the entry assumed.

### 38.1 The glow's own lifecycle — measured, on a second save

The obstacle was that `GLOW1/2.3DI` live in `World_D00` alone and every save in
`tests/fixtures/saves` is on `_C_140` or `_C_141`. The way round it is a tool
this project already had most of: `sav_parse.py --selftest` wraps a corpus
`.lev` in a save's fixed blocks and requires a byte-identical round trip, so
the same wrap makes a **loadable** save for any mission. `--wrap` is that,
promoted to a command: `_C_116.lev` — a `D00` mission, and one of the two that
use `SetGroundFire` — in `_6_.sav`'s prefix and suffix.

```bash
python3 tools/sav_parse.py tests/fixtures/saves/_6_.sav \
    --wrap gog_incubation/Missions/_C_116.lev --out /path/to/copy/Work/Saves2/_7_.sav
```

It reads back as `_C_116` on `Level04b` in `World_D00`, 34 × 40, and the game
loads it. Two phases run on it:

* **`special_glow_d00`** — the placer the `A00` phase measured *refusing* here
  writes `+0x11 = 1`, `+0x12 = 2`, `+0x13 = 4`, and its object lands at the
  cell's own object plus the two-draw scatter. The same call, the same
  arguments, the opposite answer, and the only difference is the world set:
  that is what a name gate looks like from the outside.
* **`special_glow_tick_d00`** — the glow and then two round ticks. The engine
  leaves `+0x12 = 1` after the first and `1` after the second, so the 2 → 1
  decay is measured and its idempotence with it.

`inclib/ctrlmap.py` reproduces both on the first run. What stays unstepped is
`0x00470AB0`'s **ignition**, and not for want of a save: it calls
`aPlayGroundFireAnimation`, which renders, and every `aPlay*` is out of reach
of the debugger harness for that one reason (`97` §19.2). That is a standing
boundary of the method, not a question about this routine.

The capture also found something the `A00` phases could not: `_C_116` loads
with **slot 0 already taken, by a state-5 object no cell names** — the static
kind `0x00431F45` makes. `rebuild_objects` derives occupancy from the cells, so
it cannot see one, and seeding the model's array from the capture rather than
rebuilding it is what the check and the case file now do. The `A_MK_*` caveat
`ctrlmap.py` carried in prose is a measured fact.

The before-state of the very cell the phases use reads `+0x12 = 1` with
`+0x13 = 255` — one of the 44 leftovers `10` §4 records, on the mission that
record names. The identification in §37.8 is confirmed from the other side.

### 38.2 "Removed" and "dead" — read, and they are the same state

*(This section originally concluded the opposite, on a reading of
`aRemoveUnitElement` that stopped one instruction short. §40.1 has the
instruction and the correction; what follows is the corrected text.)*

`aGetLiveUnitCount` `0x00477BF0` walks the 200 records at stride 91 and counts
`[record + 0x16]` — the **hit points** — against `[record + 0x45]`. The map
link is not read. That much stands.

But `aRemoveUnitElement` **does** write `+0x16`: `0x00477ABD` is
`mov byte [esi+0x16], 0`, the last instruction before it returns 1, with `esi`
the unit record it has held since `lea esi, [ecx + edx*2]` at `0x00477A38` —
the same record `aExecuteWarp` reads `+0x16` from at `0x0046F133` to decide
whether the mover it just walked onto a mine is still alive. So removal kills.
Fifteen of its twenty call sites reach it with the victim alive — the set
pieces of `aAnimations.cpp`, the teleporter, the hatch, the para bomb, the
battle system's own object sweep, the two interface sweeps and
`aPlayGroundFireAnimation` — and at all fifteen this write is the death: there
is no roll and no armour on any of those paths. §40.1 has the table. The ground
fire is the one that had nothing standing in for it in this remake, which is
why it is the site the correction changes.

Both twins now carry the write inside `remove` itself rather than at the call
sites, which is where the engine has it: every other caller — the hatch, the
push into a hole, the LCL `KillUnit`, the para bomb that survived its own
blast — used to set the hit points beside the call and no longer needs to.

### 38.3 The large-unit mine ring — implemented, both twins

`0x0046EC0F` gates the whole detonation block on "a mine stopped the walk", and
`0x0046EC25` then picks the arm by `unitinfo[type].size`:

* a **small** mover detonates the cell it stopped on (`0x0046EDAF`);
* a mover of **size 1** sweeps its eight neighbours through `0x004308C0` with
  the diagonal flag set and detonates every mine among them (`0x0046ECA4`) —
  and the cell it stopped on is *not* one of them.

Each cell is behind the same `aDeleteSpecialObject` guard, and the ring stops
the moment the mover's `+0x16` reaches zero (`0x0046ECB0`). Both twins carry
it. Reading it moved the whole block from `run`/`execute_move` — which has no
type table — to its caller, which is where the engine has it too.

No shipped map places a large unit next to a mine, so the `size` byte is
written to reach it, the move `93` §11 made for the large-unit clearance:
`ai_runtime.check_mine` and `test_execute_move._the_large_unit_ring` both mine
the stop cell **and** one neighbour and require the ring to take the neighbour
and leave the stop cell's mine standing.

### 38.4 The positions are the engine's, not the remake's

§37.7 called them a remake decision because the capture read the array's state
bytes. It read the whole 66-byte record all along — the position is at
`+0x10`/`+0x14`/`+0x18` — so what was missing was the origin, the seed and a
transcription. All three are there now: the eight phases read
`aGetSymbolObjectPtr(cell[+0x05])` for every tile they use and write
`aRandom2`'s seed before **every** call, and `ctrlmap.object_position` is the
arithmetic — the mine and the shield take the cell's object position exactly,
the fire and the glow scatter with `aRandom2(-300, 600)` twice, the **first**
draw on y and the second on x.

Every placement in every phase agrees, position and draw count, and
`test_ctrl_map` replays the same comparison in GDScript. `special_objects.gd`
now calls the shared arithmetic instead of putting each object at its cell's
centre.

### 38.5 What the counters moved to

`presentation_gold --check` **603** (was 544; 51 phases), `combat_runtime`
**148**, `ai_runtime` **84**, `turn_runtime` **61**, `movemap_runtime` **28**,
`presentation_tables` **627**, and the Godot suites **33 / 2713**.
*(§40 moved them again: `blob_tables` **458**, `turn_gold` **198**,
`presentation_tables` **644**, and the Godot suites **33 / 2727**; and §41
once more: `lcl_runtime` **58**, `movemap_runtime` **31**,
`presentation_tables` **687**, `presentation_gold` **712** and the Godot
suites **33 / 2757**.)*


---

## 39. 2026-09-03 — what a second review of slice E found

Fifteen findings over the working tree. Five are worth a paragraph because each
is a rule read out of the binary or a reading reversed; the rest were one-line
fixes and are listed after them.

### 39.1 The presentation list is rebuilt from the final cell array

`ShotSequence._deaths` and `Main._shot_voice` both model the same engine local
— `[esp+0x34]`, "the last unit the sweep looked at" — and once disagreed about
its order. The later loop at `0x0040DA83` does walk the arrays at
`0x004FBFF8`, `0x004FBE54` and `0x004FBE72`, but those arrays do **not** retain
`aMarkTargetCells`' write order. `aPlayFightAnimation` has already rebuilt
them: `0x0040C519` gets the CtrlMap base, `0x0040C549` accepts final markers
`0x5A..0x5D`, `0x0040C569/72` writes their coordinates, and `0x0040C78B`
advances by the cell stride `0x17` before looping at `0x0040C79C`.

Both consumers therefore use the final **row-major CtrlMap order**, including
cells introduced by a secondary explosion on a repeat pass. Append order of
`AttackResult.outcomes` is not sufficient: a repeat can discover a lower-index
cell after the first pass appended a higher one. `SliceMain._shot_targets`
sorts once by `y * width + x`, and hands the same list to the voice and death
switches. `combat_tables.py`'s `presentation.result_sweep` pins the source
array, marker band, coordinate stores, 23-byte stride and back edge.

### 39.2 Three unit types are silent

`0x0040CBDF` reads the target's `+0x4C` and clears the play flag for types
**22, 25 and 26** (`cmp al, 0x16 / je`, `cmp al, 0x18 / jbe`,
`cmp al, 0x1A / ja`) — `docs/42` §4.5 records it and neither twin gated on it.
All three have species 0, so the species test alone let Cpt. Rutherford, the
Scout and Major Rutherford scream where the engine says nothing.

The gate is at `0x0040CBF2`, **past** the round robin that picked the wave, so
the cursor still moves and only the play is skipped — the same shape the
species arm already had. Both twins take the type now, three pins in
`presentation_tables.py`, and `test_sound` asserts that a muted call still
advances the cursor.

### 39.3 The idle guard was rolling the branch twice

`docs/42` §6.1 gates the pick on "an idle clip the selector is willing to name"
and then item 4 resolves it. The remake asked `idle_clip_for` for both, and
that selector **draws** for a type whose entry has branches — so the guard
approved one clip and the start played another, and the seed moved twice.

The capture measured **one** draw per call past the countdown, and its
candidate has no branch, so it does not settle whether the engine's own guard
draws. `has_idle_clip` is the reading that spends the roll once, at the start:
it answers whether any arm names a clip without drawing. That is a choice under
uncertainty and it is written down as one, in the function's own comment.

### 39.4 The detonation had to move inside `aExecuteMove`

Slice E put the mine's cell writes in `ExecuteMove.execute` and left the shot
to the caller. That is one instruction's worth of ordering away from the
engine and it matters: `0x0046EDDC` reads the mover's `+0x16` **after** the
bomb and returns without the closing visibility pass when the bomb killed it.
Firing from the caller ran that pass on a mover the mine was about to kill, and
the pass *writes* — it reveals what the mover sees and wakes groups — so the
two orders are two canonical hashes.

Reading it also moved the whole block, in both twins, to where the type table
is: that is what made the large-unit ring of §38.3 implementable at all. And
the computer never detonated: `World.submit_move` consumed the result and
`AIPlan` did not, so the one mover the fill lets *into* a mine cell was the one
that walked over them for free.

### 39.5 The picture could not have appeared

`_redraw_terrain_now` returned early when `TerrainDiff` reported nothing, and
`TerrainDiff` deliberately ignores the effect planes — they change what stands
on a cell, not what the cell is. A mine, a shield and the round tick's decay
change nothing else, so the objects synced only when something *also* moved or
died. `SpecialObjects.sync` runs before that return now and answers the cells
it touched, which join the overlay's rebuild.

Two more of the same kind: the teleporter's traveller was **freed** rather than
hidden (`hide_unit` destroys the node and `show_unit` could not undo it, so the
body never came back), and `_saved_cameras` and the floating texts outlived a
mission change — a script that saved a camera without loading it handed its
coordinates to the next mission's first `LoadCamera`.

### 39.6 The rest

`emit_death_cases` warned and continued on a missing phase, which could write a
case file thin enough to pass the Godot minimums while `--check` failed on the
same capture; it refuses now, as `emit_special_cases` always did.
`_death_replays` was called without `type_models`, so the constant-
discrimination sweep ran with `FlyingUnit` building no record at all.
`objects.full_array_writes_255` asserted a byte that was already 255 before the
call. `CombatWorld.ctrlmap()` fabricated `action_point` and `field_type` as
zeros — and field type 0 is one the placers accept, so a world that never
filled them would have burned everywhere; it raises now, which is what
`interact._require_cells` already existed to do. The warp's mine arm was
"named here and not simulated" in three places and is implemented in all
three. `MapState`'s `+0x12`/`+0x13` had arrived as `effect4`/`effect5` beside
the older `decal0`/`decal1`, which nothing read: the duplicates are gone. The
new suite had no minimum check count, and `SCHEMA_VERSION` 8 had no line
saying what raised it.

## 40. 2026-09-03 — what a third review of slice E found

Fifteen findings. Five of them changed a rule rather than a picture, and the
first is a correction to a conclusion §38.2 reached the day before.

### 40.1 `aRemoveUnitElement` kills — the reading was one instruction short

§38.2 concluded that "off the map" and "dead" are different states, because
`aGetLiveUnitCount` `0x00477BF0` counts `[record + 0x16]` and the removal was
read as leaving that byte alone. The count is right; the removal is not.
`0x00477ABD` is

```asm
mov byte [esi + 0x16], 0
```

the **last** instruction before `aRemoveUnitElement` returns 1, with `esi` the
unit record it has held since `lea esi, [ecx + edx*2]` at `0x00477A38` — the
same record `aExecuteWarp` reads `+0x16` from at `0x0046F133` to decide whether
the mover it just walked onto a mine is still alive. Removal kills.

**Which matters at more than half of its twenty call sites.** The twenty were
resolved to routines through `trace_names.py`'s symbol table:

| Arrive with the victim already dead | Arrive with it alive |
|---|---|
| `aAttackUnit` `0x0046C1F9` | `aAI_SpecialPlayerControl` `0x0040B316` — the para bomb that survived its own blast |
| `aCheckWeaponDamage` `0x0046D34C`, `0x0046D95C` | `aAnimations.cpp`'s set pieces: the statues `0x00413459`, `0x00413F5E`, `0x00413FA4`, `0x004142EC`, the laser barrier `0x00413903`, the foot bridge `0x00414F9C`, `0x00415663` |
| `aExecuteBomb` `0x0047063F` | `aPlayGroundFireAnimation` `0x00415B8D` |
| `aKillUnit` `0x00472920` at `0x0047296E` | `aExecuteTeleporter` `0x00470208` |
| | the hatch arm inside `0x0046F210`, at `0x0046F2FB` |
| | `aBattleSystem.cpp:3999` `0x0041CA5E` — the object that clears the unit standing on its own cell, beside the `"kill object: %d"` trace |
| | `aUI_KillUnit` `0x004783D0` at `0x00478420` and `0x00478465` |
| | `lKillPlayerUnits` `0x0047BC60` at `0x0047BCA0` |

**Five and fifteen.** The four this section first left unclassified are the
last three rows: `aUI_KillUnit` sweeps the two hundred slots and removes every
one whose `+0x45` is not `0xFF` and whose type's species does not match its
argument (`0x004783FE` is the gate, `cmp byte [esi], 0xFF`), and
`lKillPlayerUnits` sweeps them removing every unit of one player whose `+0x16`
is **non-zero** — its gate, `0x0047BC74`, is the hit points themselves, so it
says in as many words that what it removes is alive. Both push their own name
on the failure arm rather than the callee's, which is the paste this project's
notes warn about and is what identifies them.

At the five, `applyDamage` has already zeroed the hit points and the dead
marker `0xFF` has been written over them (`0x0046BF49`), so the write is
redundant. At the fifteen it **is** the death: there is no roll and no armour
on any of those paths. The ground fire is one of them and not the only one,
which is what makes carrying the write inside `remove` the right shape rather
than a special case — every one of the fifteen the remake models had been
zeroing the hit points by hand beside its own call, except the ground fire,
which had nothing. `aExecuteTeleporter` writes them a second time itself, at
`0x00470232`, immediately after the call returns.
`presentation_tables`' `remove_unit.*` pins the twenty addresses, the split and
the two gates, so the classification cannot rot.

Both twins now carry it **inside** `remove` / `remove_unit_element`, which is
where the engine has it. The hatch, the push into a hole, the LCL `KillUnit`
and the para bomb that survived its own blast each used to set the hit points
beside the call and no longer do. `turn_runtime`'s `handover.ground.removal_*`
check is inverted with them, `docs/22` §9.5 gains the instruction, and
`docs/42` §12 item 2 is rewritten in place.

### 40.2 The two `MoveUnit` calls were outside the mover's alive gate

`0x0046EDDC` in `aExecuteMove` and `0x0046F133` in `aExecuteWarp` are the same
three instructions — `mov al, [record+0x16] / test al, al / je <epilogue>` —
placed immediately after the mine's `aExecuteBomb` and immediately before
everything that follows it: `aBuildVisibleMapForUnit`, the six
`aSetLCLVariable` writes and `aRunLCL` (`0x0046EEFD` and `0x0046F1D6`). In both
routines the epilogue is a bare `mov eax, 1 / ret`.

`ExecuteWarp` already honoured the gate for the fog rebuild, which is inside
it. The `MoveUnit` call is the **caller's** in this remake, and `World` fired it
unconditionally on both paths — so a mover the mine under its landing or its
stop cell had just killed ran a mission-script handler the engine runs nothing
of. That is not a picture — `MoveUnit` is the hook a mission script uses to notice
where a unit has got to. Both are gated now, and `test_execute_move` walks an alien
onto a mine (the fill refuses a mined cell to everybody else, `move_map.gd`)
with one hit point and a weapon 36 the shared fixture does not carry, searching
the seed rather than writing one down.

### 40.3 The mute covers the explosion, and the Python twin had no gate at all

`docs/42` §4.5's three silent types are gated at `0x0040CBDB`, and **every** arm
of the cascade reaches it: the machine's explosion jumps there from
`0x0040C9AC` exactly as the screams do from `0x0040C9E6` and its neighbours. So
a type-26 machine dies silently. `AudioEvents.death_voice` applied the mute only
on the human/alien arm and returned the explosion before it;
`inclib.sound.VoiceCursors.death` took no type id at all, so the model answered
`SP_HUM_n` where the engine says nothing and the fixture could not express the
difference. Both are fixed, the case emitter carries a type id per call — two of
the eleven muted, one of them on a `death` step of species 3 — and
`blob_tables` pins the machine's silence and that the cursor still moves.

### 40.4 `_ftol` is a service, and one of its callers was `int()`

`blob_creators.ftol` was a bare `int(value)` where `blob_runtime._ftol` and
`eng3d_geometry.gd` both answer **zero** for a NaN or an infinity — x87's
64-bit indefinite is `0x8000000000000000` and every caller keeps `eax`
(§20). Two creators can produce one: `_c00428990` when its direction falls
through `LASER_DIRECTIONS`' `(0, 0)` default, which makes the target the
source, and `_c0042A8E0` when source and target share a column. The GDScript
twin answered 0 and the Python one raised. The function now lives in
`inclib/eng3d.py`, where its twin already was, and both callers use it.

### 40.5 Three checks that could not fail, and one case file that could not

`turn_gold`'s `pass_before_copy_is_the_order_measured` asserted the literal
`True` — the diff it computed went into the message and nowhere else, so
breaking the replay left `--check` green. It asserts the diff now, under a name
that says what the probe proves: the two orders agree on this scene, which
means the probe does **not** discriminate them and the engine's order is what
the phase pins. `conversion_probes` wrote its phase even when no seed cleared
weapon 47's overheat roll, and nothing pinned the probe's presence, so the two
absorber probes alone passed as a captured `conversion`; `reveal` had exactly
such a pin and `conversion` now does too. And `presentation_gold`'s
`emit_special_cases` checked only that a phase existed where `check_special`
pins `len(placed) == len(calls)`, so `zip` could truncate silently — it refuses
now, like its sibling.

### 40.6 The picture

The Godot suite exited 1 on a tree whose harness printed `HARNESS-RESULT: OK`:
`test_ctrl_map._positions` derived the origin key from the phase name, and the
two `World_D00` phases carry only `"g"`, so both threw on a missing key and
skipped the `.position` check while the suite still reported its full count.
The emitter writes the key **per step** now — it is the checker's own choice,
written down rather than re-derived — and `_model_columns` gets the D00
dimensions it was missing on the same line.

Five more, each a thing that could not appear:

* `SetpieceCamera`'s ground-unit carry read `st["step"]`, which only frame 1
  wrote, and `SequenceQueue.skip()` paints every remaining step once at its
  **last** frame — so a key press during a `GroundUnit` threw and the body was
  never placed or settled. `ScriptCamera` had the same shape twice: a skipped
  `LoadCamera` never popped, leaking a view onto the stack for every later
  `LoadCamera` in the mission, and a skipped `MoveCamera` left the view alone.
  Both are guarded by a once-flag now, not by the frame number.
* The mine's casualties were never marked dying — they are in the event's own
  `blast` and not in the command's outcomes — so the rebuild freed their nodes
  before `_present_mine` queued the explosion and the body vanished a frame
  before the shot that killed it. Same on the computer's replay.
* A jump onto a mine presented nothing at all: `WarpResult.blast` reached no
  presenter on either path.
* An overheat that destroyed its own reactor left the shooter unmarked — the
  outcome writes `hp = 0` and the shooter is in nobody's outcome list — so the
  orbit that hides it flew to a fallback position.
* `UnitsView.animate` returned on `frozen` before the walk loop. The 60 m rule
  of `docs/42` §1.3 freezes **Charisma**; `aExecuteMove` still steps the unit
  field to field, and `_picture_busy()` gates on `is_walking()` — so above
  `FREEZE_HEIGHT` the computer's replay and the pending reaction fire stalled
  rather than merely freezing bodies.

And one that is a deliberate reproduction rather than a fix: `MainShotHost.muzzle`
set `arrived` from the weapon alone and never reconsidered, so a shot whose
creator made nothing burned the full hundred frames of `WAIT_FRAMES`. **A
creator writes `0x004FE63C` before it allocates**, so a full pool leaves the
flag where the creator put it and the engine really does wait. That is now read
for all of them rather than for three (§40.7). That is kept. The
wait is cut short only when the refusal is one the engine could not have had:
a computed kind the switch does not name, or a model this world set does not
carry.

### 40.7 The three things §40 left open, read

**The mine's blast is drawn before the reactions, and the engine says so.**
`aExecuteBomb` `0x004702C0` ends by calling `aPlayFightAnimation` `0x0040BD70`
itself, at `0x004705F5` — the blast's picture is the routine's own, not its
caller's. Both commands reach `aExecuteBomb` from **inside** their own routine:
the walk at `0x0046ECA4` and `0x0046EDAF` (the pair `0x0046EC25` picks between
by the mover's `size` — the ring and the stop cell, docs/26 §6.2 item 8) and
the jump at `0x0046F109`. Neither draws a fight of its own. And `aExecuteFight`
— what drains the reactions — is the **caller's**, run only after
`aExecuteMove` has returned (docs/23 §5.3). So the explosion is over before the
first reaction shot is fired, and `game` now queues it in that order on both
paths; it had the reactions first on the walk, and the jump had copied that.
The computer's replay was already right, because `AIPlan.execute_warp` carries
the blast inside its own `warp` event and the reactions are a later one.
`presentation_tables`' `bomb.*` pins the five call counts.

**The last four `aRemoveUnitElement` sites are live removals.** §40.1's table
now has all twenty. `aUI_KillUnit` `0x004783D0` — which pushes its own name at
`0x00478436` rather than the callee's — sweeps the two hundred slots and
removes every one whose `+0x45` is not `0xFF` and whose type's species does not
match its argument, twice over (`0x00478420` and `0x00478465`).
`lKillPlayerUnits` `0x0047BC60` sweeps them for one player and gates on
`0x0047BC74`, `mov al, [esi-0x2D] / test al, al` — `esi` is the record plus
`0x43`, so the byte is `+0x16`, the hit points: the loop's own condition is
that the unit is **alive**. `0x0041CA5E` is `aBattleSystem.cpp:3999`, beside
the `"kill object: %d"` trace, taking the unit off the cell an object is being
placed on. Five arrive dead, fifteen alive.

**Every creator writes the flag before it allocates — all twenty-six.** The
address `0x004FE63C` appears **42** times in `.text`: thirteen inside
`aBlob_Update` (twelve stores of 1 and arm 45's `mov [flag], ebp`, the clear),
and twenty-nine outside — twenty-six stores and three reads, one of which,
`0x0042B480`, is the flag's whole two-instruction getter. Of the twenty-six
stores, **twenty-five** precede the first `call 0x00420950` — the blob
constructor, the 116-site allocator — in their own function. Twenty-three of
those are unambiguous against the named-symbol boundaries outright; the other
two, `0x0042B0E3` and `0x0042B490`, are in unnamed creators that begin
immediately behind a `ret` (`0x0042B0CF`, and the getter at `0x0042B480`),
verified byte by byte.

The single store that follows an allocation is `0x0042420D`, inside
`aBlob_CreateTracerBullet`'s record loop, and it writes **1** — a tracer has
nothing to arrive — so it cannot be the reason anybody waits at any pool state.
`0x004287D3`, the one this report flagged as sitting on a branch, is on the
`steps > 0` arm of `aBlob_CreateLaser`'s count; its other arm at `0x004287E8`
writes the same computed `steps <= 0`, and **both** are ahead of that
function's first constructor call. So the reproduction stands as written: a
full pool leaves the flag down and the engine waits its hundred frames.
`presentation_tables`' `arrived.creator_stores_are_the_table_ones`,
`arrived.only_one_store_follows_an_allocation` and their two neighbours pin the
whole inventory, so a creator that started writing the flag late would fail.

---

## 41. 2026-09-03 — the three rule gaps and the four presentation tails

§36 listed what the mission-presentation plan had left. §37 and §38 built
slice E; this section closes three of the four remaining **rule** gaps of
§31.3's class and all four **presentation** tails, and says exactly what the
fourth rule gap needs.

### 41.1 The statue's beam, in `core`

`Statue` `0x00442310` and `Statue2` `0x004424B0` both reach
`aPlayRotateStatueSequence` `0x00413A40` — `Statue2` through `0x00413500`,
which sweeps the control map and calls it once per cell whose action-point
byte falls in the command's inclusive range. Both twins recorded an event and
killed nobody. Reading the routine settled three things at once, two of them
corrections to [`42` §8.1](42-mission-presentation.md):

* **The axis is the action-point byte's bit 0, after a toggle.** `0x00413C31`
  is `mov al, [ebx+0x0B] / test al, 1 / dec al` on odd and `inc al` on even,
  and `0x00413C5A` reads the *result*: 0 walks `+y`, 1 walks `+x`. So the same
  statue alternates its axis call to call, and the byte it flips is the one
  `aExecuteTeleporter` keys on and `FootBridge2` clears.
* **The reach is six cells each way, not five.** `0x00413C97` is
  `cmp dword [esp+0x3c], 6`, the counter starts at zero and is advanced only
  after the cell survives the null and field-type-2 tests, so distances 1..6
  are examined. `presentation_tables`' pin had the right bytes under the wrong
  name (`setpiece.statue.path_5_x2`); it is `path_6_x2` now. `FixedStatue`'s
  own sequence `0x00414000` is **ten** (`0x00414164`, `cmp eax, 0x0A`), which
  is what `STATUE_REACH` already said and what §8.1's "nine" did not.
* **One victim per arm, not one per cell.** `[esp+0x24]` is set to 1 before
  the null test and cleared **only** on the no-unit branch, so `0x00413D67`
  re-enters the loop only when the cell was empty; a cell holding a unit ends
  that arm. Hence exactly two `0x0043B8D0`/`aRemoveUnitElement` pairs
  (`0x00413F4E`, `0x00413F94`) and exactly two `aBlob_CreateFireDeath` calls.

`LclInterpreter._statue`/`_statue_walk` and `inclib.lcl_runtime._statue` are
the twins. They write the toggled byte, walk both arms, emit one `statue`
event carrying the axis, both endpoints and both step counts, and then a
`statue_kill` per victim in the engine's order — forward arm first. The kill
goes through the same `UnitState.remove` / `LclWorld.kill` every other set
piece uses, so the hero counter and the `+0x16` write of §40 come along.
The scoreboard's Losses pair is still not carried, the same way `FixedStatue`
and `Barrier` do not carry it.

The endpoint the beam is drawn to is the cell that **stopped** the walk — a
wall cell, the victim's cell, or the sixth. Walking off the map leaves the
engine holding a null cell pointer at `0x00413D77`, which would fault; the
remake draws to the last cell it did reach instead. That is the one place
this deviates from the instructions and it is a fault the original cannot
reach on a bounded map.

The picture consumes the event rather than re-deriving it. `core` puts
**fifteen** numbers on `statue` — the cell, the axis, each arm's endpoint and
step count, and each arm's victim as `slot, x, y` with `-1, -1, -1` for an arm
that found nobody — because by the time `_setpiece_extra` runs the byte it
would read has already been toggled and the victims are already off the map.
`statue2` left `SetpieceDriver.ANIMATED` for `INSTANT` with `statue_kill`: the
batch form is a loop, and the animation belongs to the `statue` events emitted
inside it. Its **sound alias went with it** — `AudioEvents.EVENT_ALIASES` used
to map `statue2` to `statue`'s cues, which was right while the marker was the
only event a batch produced and would now play `stone.wav` once more than the
engine does.

`test_lcl.gd` gained ten checks over a 9×9 synthetic world — the toggle in
both directions, the axis following the new bit, the kill each way, the
victims leaving their cells, the unit off the axis spared, the second unit on
an arm spared, the wall stop, the sixth cell in reach and the seventh out of
it, and `Statue2` running the sequence on every matched cell — and
`lcl_runtime.py --check` gained the **same table** as twelve `statue.*` checks
of its own, because the GDScript suite compares GDScript against GDScript and
the Python twin had nothing asserting it (43 → 55).

### 41.2 The teleporter, in `core`

[`26` §5](26-interaction.md) has had the four instructions since the
interaction package; neither twin acted on them. `aExecuteMove` breaks out at
`0x0046EA73` (`mov al, [esi+0x0D] / cmp al, 9 / je`) **after** charging the
step — `0x0046EA42` subtracts the budget before the test — and does not set
the "keep walking" flag, so the walk ends on the entry cell. The epilogue then
runs, in this order: the mover's alive gate `0x0046EDDC`, the
`aExecuteTeleporter` call `0x0046EE03`, the gate **again** at `0x0046EE30`,
and only then `aBuildVisibleMapForUnit` from `+0x42`/`+0x43`. So the closing
visibility pass and the caller's `MoveUnit` event both see the **exit** cell,
and a traveller a blocked exit killed gets neither.

`ExecuteMove._teleport` and `inclib.ai._teleport` carry the rule:
key = the entry's `+0x0B`, exit = the first cell in a row-major sweep with
field type 10 and a matching key, no exit and nothing happens, an occupied
exit removes the traveller from the **entry** cell. `MoveResult.teleporter` /
`ExecuteResult.teleporter` carry the break out of the walk and are kept out of
both `to_dict`s, which the native capture pins. The engine's own
`mov byte [esi+0x16], 0` at `0x00470232` is redundant beside
`aRemoveUnitElement` (§40) and is not repeated. The
`0x004529D0(x, y, 5, 5, 0, 1)` between the two link writes is the **camera**
— `aMI.cpp`, *invalid cameratargetposition* — not a rule.

The picture follows: `main.gd._present_teleport` queues
`aPlayTeleporterSequence`'s seventy frames on the **entry** cell with the exit
as the stream's target, on the player's walk and on the computer's, before the
reaction drain for the same reason the mine's blast goes there. The traveller
is suppressed at frame 40 and, at 10, **placed on the exit's own object** and
shown -- `0x00416554` moves the unit there before it shows it, and the walk's
last step had left the body standing on the entry cell, so a sequence that
only flipped `visible` put it back where it started. `teleporter_blocked`
draws the stream with the sound table's `warp` (`0x00416840`) and nobody to
move. The computer's walk aims its opening camera flight at the **path's own
last cell** rather than at the event's `tx`/`ty`, which are the same cell on
every walk but this one: after `_teleport` the event reports the exit, and the
camera has to fly to where the body is about to walk.

**One ordering nit, stated rather than hidden:** the walk is played by
`UnitsView` and the set piece by `SequenceQueue`, so the stream starts while
the body is still walking to the entry cell, where the engine finishes the
walk and only then enters the sequence. The mine's blast has had exactly this
overlap since §29 and it is the same seam — the two clocks are independent by
design (`92` §2) — so it is named here rather than papered over with a delay
number nothing measured.

`movemap_runtime`'s corpus sweep now counts the arm rather than excusing it:
**17** of its 4587 walks end on a teleporter entry
(`execute.corpus_teleporter_stops`), which is the first time any check
exercised field type 9 at all — and `teleporter.corpus_entries` /
`teleporter.corpus_unpaired` walk all 155 maps with the **model's own** scan
and reproduce [`26` §5.1](26-interaction.md)'s table: 22 entries, of which
exactly one, `_C_156`'s at (39, 9) with key 104, reaches no exit. `test_execute_move.gd` gained six checks on a
corridor with an entry on (2, 1) and an exit on (5, 1): the arrival, the event
order, the cell link, the `MoveUnit` event's view of the exit, the inert
unpaired entry — `_C_156`'s key-104 authoring bug — and the blocked exit's
kill.

### 41.3 The skill orbit's gate, and the bomber's target triple

`0x00410190` opens with `call 0x0043B740 / cmp eax, 1 / jne` — the game-mode
getter of [`25` §2](25-turn-and-round.md), 1 being the campaign. The skill
orbit is the **only** one of the four with that gate (`0x0040F420`,
`0x004104A0` and `0x0040FC50` all open on something else), and `main.gd` now
reads `TurnState.mode` for it.

The bomber's target triple was marked UNVERIFIED in §32 because "where it
flies to comes from two of the routine's own locals that were not traced".
Both halves turned out to be readable and neither is a tile:

* the **creator** takes six literals — `0x00415EE1` pushes
  `aBlob_CreateBomber(-320000, -320000, 320000, 48000, 48000, 320000)` — so
  the fly-past is a fixed diagonal across the scene and reads no cell;
* the **camera** is a separate call, and the untraced locals are its own:
  `0x00415F2C` reads all six of the camera's numbers back through
  `0x00403780` before the flight-path switch picks the eye, and `0x00415FB4`
  sets position `(-16000, 0, 320000)` with **the target it just read**.

So the bomber aims the camera nowhere: it slides the eye onto the flight path
and keeps looking at whatever the scene was already looking at. The remake was
spawning the creator at the camera's entry point and aiming it at the box's
cell; it now passes the literals and calls `set_camera(eye, camera_target())`.

**Correction, 2026-09-09: `0x00415FB4`'s target is the loop's *starting*
value, not the fly-past's.** The sentence above stopped at the set before the
loop and read `0x00416014` as putting the six numbers back; it is the same
`0x00403560` again, **inside** the loop, and the loop runs it every frame.
`0x00415FE6` calls `0x0042B4B0(&x, &y, &z, &slot)` — the pool's first live
record, the helper the teleporter's camera uses — and `0x00416014` then sets
position `(-16000, 0, 320000)` with **that** as the target. So the fly-past
*tracks the plane*, and the eye's z is the bomber's own (`0x4E200` on both
`0x00415F9D` and the creator's literals), which is what makes it a fly-past
seen level with the aircraft. `0x00415FB4` is never drawn — no `0x0040B6F0`
stands between it and the loop — so its only effect is the target the loop
starts from. Nor does the routine restore anything: `0x00470790` reads the
camera at its top and never writes it back, and neither routine flies home.

**And the bomb run has a camera of its own, at ground level.**
`0x004160F0`'s first loop `0x004162D6`..`0x00416322` is the same shape with
two differences that are the whole look of the strike: the eye is
`push 0xC80 / push 0 / push 0` = `(0, 0, 3200)` — the world's own corner, one
field up — and the target's z is clamped, `cmp eax, 0x1F40 / jge` taking 8000
when the bomb is higher, so the camera watches the bombs come **down** rather
than craning at the sky they fall out of. That loop ends at the first landing
(`0x00416336`, `while (!arrived)`); `0x00416364`'s loop, which plays the
remaining crumps and runs `while (live)`, sets no camera at all, so the view
holds where the first bomb came down. The remake had neither: it set the
fly-past's eye once with a ground target and left it there for both routines,
which showed the whole strike from 320 000 up — reported as *a falling
container that multiplies, seen from above*. `SetpieceCamera`'s `para_bombs`
arm now tracks in both stages and `test_effects` pins all three views.

**And two sound defects went with it** *(2026-09-09)*, both reported from the
same minefield.

* **A looping cue did not loop.** `AudioStreamWAV` repeats only when its own
  `loop_mode` says so and the shipped waves carry no loop points, so every one
  of the nine `DSBPLAY_LOOPING` sites of [`28` §1.4](28-effects-and-sound.md)
  was heard **once** and then went quiet under a sequence that ran on. The
  bomber is where it shows -- `bomber.wav` against a fly-past of
  `0x0042A8E0`'s 150 ticks -- but the door, the lift, the platform and the
  drawbridge were all as short. `AudioSystem` now keeps a looping copy of a
  wave beside the one-shot (the same wave may be asked for both ways) with
  `loop_end` **counted** from the sample's own bytes: a zero one is a loop of
  no length rather than all of it. `test_sound` pins the arithmetic for both
  widths, both channel counts and the compressed format it refuses.
* **The bomb run has three buffers and the remake gave every bomb its own.**
  `0x00416271` is `mov edi, 3` and the loop at `0x00416276` creates
  `crush.wav` three times; `0x004163A1` advances the index on every raised
  *arrived*, free buffer or not. `aDirectSoundPlayBuffer` `0x00436EF0` is
  `IDirectSoundBuffer::Play(0, 0, flags)` and nothing else -- no `Stop`, no
  `SetCurrentPosition` -- so a play into a buffer that is still sounding does
  nothing at all and that crump is **dropped**. Sixty mines landing three
  ticks apart were sixty voices layered on each other; they are now the first
  three and whatever the sample's own length lets through after them.
  `SetpieceCamera.crump` is the ring, `ShotHost` gained `play_cues_slots` and
  `sound_playing` for it, and `test_effects` runs six landings against three
  buffers and then frees one.

### 41.4 `CrushWall`'s footprint — read, and why it is not in `core`

"`0x004238C0` on every cell" hid a mechanism, transcribed in
[`42` §8.2](42-mission-presentation.md): `0x00415D6D` calls
`0x0042F410(wallObject, 1, 0, 1)`, which sweeps the control map and casts
**four probes** per cell from that cell's own symbol object — `x ± 200`,
`y ± 200`, from `z = 100000` — against the wall object. A cell any probe hits
has its object dropped to z 0, its height set to 0, its field type set to
**1 (`Free Place`)** and its state byte set to 2; `0x00415D87` then sweeps for
state 2, throws the debris and puts the byte back to 1.

That makes a crushed wall walkable floor over a **geometry-derived** set, and
it is the one gap of the four that this pass does not close. `core/` holds no
meshes by decision ([`92` §2](92-remake-architecture.md)), so the footprint
has to come from outside it, and there are exactly two honest routes:

1. a `presentation_gold` phase on wrapped saves of `_C_129`, `_C_142` and
   `_O_061` — the three missions holding all nine shipped `CrushWall` calls —
   reading the whole control map before and after each call, the way the ten
   `special_*` phases of §37 do. `0x00406F20` and `0x0042F410` do not render,
   so unlike `aPlayCrushWallAnimation` itself they are callable under
   `dbgcall`. That gives 9/9 and says whether a map-data proxy exists;
2. failing a proxy, the footprint belongs on `MapResource` from the converter,
   which means a `CONVERTER_VERSION` bump in both places and a republish —
   a slice-sized item, not a tail.

What is done here is the reading and the pins
(`setpiece.crush_wall.*`, `special.probe.*`). **§41.7 then took route 1 and
measured all nine**, which is what settles which half can be closed.

### 41.5 The between-players screen — the engine skips it here

§35.1 read `0x0047C2C0` as the between-players screen and left it unbuilt.
Reading its **case 0**, the arm a mission hand-over takes, closes it instead
of building it:

```c
if (humanPlayerCount() == 1 && !multiHumanSession()) {  /* 0x0047C3FF */
    SendMessage(hwnd, WM_LBUTTONDOWN, 0, 0);
    return 1;                                           /* nothing is drawn */
}
```

`0x0043B700` is [`25` §2](25-turn-and-round.md)'s own human-player count --
the slots at `0x00509E20` whose kind is exactly 1 -- and `0x0043B1F0` is
`0x00509F08` non-zero **and** the game mode among 2, 3 and 4, which is to say
a network, local or play-by-mail session. With one human player the routine
posts its own left-button-down and returns before the first line. The remake is a one-human campaign, so **not** having
the screen is the faithful behaviour, and the HUD line it was being compared
against was never a smaller version of it. The hot-seat and session arms —
cases 2 to 6, and the `Txtmod` ids 125, 127 and 132 they read out of a
different active text module — stay unbuilt because the remake has no
hot-seat; that is a `docs/29` item, not a presentation one.

### 41.6 The jump's and the push's frames

Unchanged and unchangeable by this method: both routines render inside their
frame loop and fault under `dbgcall`, the same boundary `0x00403CC0` has
(§19.2). They are transcribed from their instructions and pinned in
`presentation_tables`, and there is nothing to build.

### 41.7 `CrushWall`, measured — all nine shipped call sites

§41.4 named two routes and this took the first. Nine `presentation_gold`
phases, one process each: the mission is wrapped into `_6_.sav`'s fixed blocks
by `sav_parse.py --wrap` and staged as its own slot (8, 9 and 10 for `_C_129`,
`_C_142` and `_O_061` — all three are `World_A00`'s `Level01d`), the phase
finds the wall the way `0x00415D00` does and calls
`0x0042F410(wall, 1, 0, 1)` with the **whole** 900-cell control map read
either side. `aPlayCrushWallAnimation` itself is not called: everything after
the mark renders, which is `docs/42` §4's own limit, but the two calls that
decide the footprint do not.

What a marked cell does is exactly three bytes:

| | before | after |
|---|---|---|
| `+0x00` state | 1 | 2 — and back to 1 in the debris sweep (`0x00415DA4`) |
| `+0x01` height | 3280 | **0** |
| `+0x0D` field type | 2 | **1**, `Free Place` |

Nothing else in the 23-byte record moves, on any of the twenty marked cells.

The footprints are in [`42` §8.2](42-mission-presentation.md). Every one is a
**straight run of two or three cells** with the command's own cell in it, and
the runs **tile** the wall: `_C_129`'s column at x 16 is five identical cells
that split 2 + 3, `_O_061`'s row at y 19 is seven that split 2 + 2 + 3. ~~That
split is the finding. It is not in the `.lev`: `0x00406F20` walks the
**standard object** array at `[0x004FA80C]` with stride 66 and count
`[0x004FA7B4]`, which is neither the map's 900-entry land lattice (one object
per cell, prototype and all) nor `LEVEL01D.3DW`'s 27 `[CLO]` blocks — the wall
pieces are objects the engine builds when it expands the scene's prototypes,
and no reader of the shipped files can separate them.~~ **Wrong, and corrected
in §50 on 2026-09-12.** The standard-object array *is* the `.lev`'s
special-object table — [`99` §10.1](99-slice-7-report.md) had already read
`0x00406F20` that way — and each of the nine calls has its wall piece standing
on its own cell as a `.lev` record. The split is the prototype: `L040EA00`
spans two fields and `L041EA00` three.

So the honest division, and what is built:

* **The rule is in `core`.** `LclInterpreter._crush_wall` and
  `inclib.lcl_runtime._c_crush_wall` write height 0 and field type 1, and the
  event carries the cells they changed. That is a real change from "the event
  records that it happened and nothing moves": a crushed wall is now walkable
  where the command names it, and the picture throws `0x004238C0` on exactly
  the cells `core` changed rather than on a cell it assumed.
* **The deficit is one or two cells per call**, named and measured rather than
  guessed, and `presentation_gold --check` pins all nine footprints cell by
  cell (603 → **712** checks) so a remake that ever grows a footprint source
  has an oracle waiting for it.
* ~~**The source, if it is ever wanted, is the converter** projecting the
  scene's standard objects onto the control map — the same thing `0x0042F410`
  does, and now transcribed. It is a slice of its own and it is not started.~~
  **Built 2026-09-12, §50.** It is not a slice: the probe is vertical, so the
  sweep is a crossing-number test against the special object's faces, and
  `inclib/footprint.py` reproduces all nine footprints cell for cell. `core`
  crushes the whole run.

~~None of the three missions is among the five the converter ships, so nothing
in the remake reaches `CrushWall` today; the rule is there for when one does.~~
**Superseded by §44**, which added `_C_129` to the converter's set for its
crush wall.

**One consequence worth naming.** The cell now has a real 3280 → 0 height drop,
and `_paint_setpiece` interpolates a set piece's cell over its frames -- so the
crushed cell *sinks* across the pool wait rather than snapping. The engine does
neither: `0x0042F410` writes the cell's height to 0 **before** the frame loop
and the loop drops the **block object** 480 and turns it 102 a frame until the
pool empties, then frees it with `aDeleteLand`. The remake has no separate
block node -- `Scenery` draws the cell -- so sinking the cell over the same
open-ended wait is the remake's reading of that fall, and it is the same
mechanism the lift and the door already use. Named here rather than left to be
discovered.

The capture is also a `docs/91` §1 data point: eight of the nine phases reached
the anchor on attempt 1 or 2, and `crush_wall_o_061_11_23` failed all ten
attempts of one run and then reached it on attempt 1 of the next. That is Wine
start-up, not the plan.

### 41.8 The walk and its own epilogue

One seam this pass also closed rather than only naming. `aExecuteMove`'s step
loop **blocks**, so the mine's `aExecuteBomb` (`0x0046EDAF`) and the
teleporter's `aExecuteTeleporter` (`0x0046EE03`) are drawn after the last step.
In the remake the body is walked by `UnitsView` and the set pieces by
`SequenceQueue`, two clocks that are independent by design
([`92` §2](92-remake-architecture.md)), so both were starting while the body
was still on its way to the cell they belong to — the blast since §29 and the
teleporter's stream since §41.2.

`SliceMain._hold_for_walk` is the stage that joins them: an `enqueue_until`
whose bound is the walk's **own** length in frames and whose predicate is
`UnitsView.is_walking`, which is true from `start_walk` onwards, the camera
flight's delay included. It is queued only when the walk's events carry
something to serialise (`_walk_has_epilogue`), so a plain walk does not hold
the queue for nothing, and it is on the player's path and the computer's
alike. The reaction drain needed nothing: `_drain_pending_reactions` has
always waited on the same `is_walking`.

### 41.9 Where the plan stands now

Slices A through F are in, and every item §36 listed is closed except one:
**slice G**, the by-hand pass in an exported build, has still not been run.
~~`CrushWall`'s footprint is measured and pinned (§41.7) with its remaining
half — a converter that projects scene objects onto the control map — named
and deliberately not started.~~ **The remaining half landed 2026-09-12, §50.**
Slice G is still the one thing §36 listed that has not been run.

Green after this pass, with the counters that moved: `lcl_runtime` at **58**
checks (twelve `statue.*` and three `crush_wall.*`, the twins of
`test_lcl.gd`'s), `movemap_runtime` at **31** (the walks that stop on an entry,
and `docs/26` §5.1's 22-entry table re-derived by the model's own scan rather
than by hand — the one unpaired entry it finds is `_C_156`'s key 104),
`presentation_tables` at **687**, `presentation_gold` at **712** (the nine
`CrushWall` footprints) and `bash godot/run_tests.sh` at 33 suites and
**2757** checks. The whole always-run block, `dbgcall/selftest.sh` and all
five gold captures (712, `blob_gold` 259, `turn_gold` 198, `ai_gold` 47,
`movemap_gold` 41) are green.

---

## 42. 2026-09-03 — slice G: the pass in a running build

The last item of the presentation plan. §41.9 left it as the one thing not
done, and this is it: the shipping export rebuilt and launched, and every row
of `docs/42` §11 that a player can reach looked at **in a running game** rather
than in a suite.

**What the hand is.** Nobody can sit at this keyboard, so the hand is
synthetic and the report says so wherever it matters. What is *not* synthetic
is the path: every key and every click below is pushed into the viewport with
[`Viewport.push_input`](../godot/game/agent/agent_session.gd), so `SliceMain._unhandled_input`,
`_pick`, `_may_command_now`, `_cell_under` and everything under them run
exactly as they do under a mouse. The synthetic part is which pixel is clicked
and when. The one question this pass therefore still does not answer is
§25.5's — whether a shot *reads* as a shot to a person watching it — and that
stays open on purpose.

### 42.1 The harness: `godot/tour.gd`

> **Superseded 2026-09-06.** The command-file protocol described below was
> replaced by the HTTP control server of [`docs/92` §7.16](92-remake-architecture.md);
> `godot/tour.gd` is deleted and its verbs, snapshot and screenshot live in
> `godot/game/agent/`, reached by `--agent-port=` on an ordinary launch. What
> this section records is the pass **as it was driven**, and it is left as it
> was written -- only the link above, which pointed at the deleted file, now
> names the code that carries it.

A `SceneTree` driver beside `shot.gd`, on the precedent of §24.5's temporary
one, and excluded from the shipping preset the same way:

```bash
godot --path godot --script res://tour.gd --resolution 1280x800 -- \
    --dir=/some/scratch/dir --mission=_C_140
```

**The directory is the protocol.** The driver waits for `cmd-0001.txt`, runs
its lines, writes `res-0001.json` beside it and waits for `cmd-0002.txt`; a
sender writes each command file with `mv` so a half-written one is never read.
The commands are `key NAME`, `click X Y` (a left click on the centre of a map
cell, projected with the rig's own camera), `click_unit SLOT`, `walk_to X Y`
(the reachable cell nearest a place — the harness's convenience, delivered as
a click on a highlighted square and, since the seventh slice put the direction
ring behind that click, an answer to the ring with the direction of travel;
`hud ring N` is for a scenario that chooses the facing itself),
`chance A B`, `wait N`,
`idle [MAX]`, `shot NAME`, `note TEXT` and `quit`.

Every reply carries the state the pass reports on -- the turn and the player,
every unit's slot, owner, cell, hit points and weapon, the selection's fill and
its warp cells, the sequence on the queue with its frames left, the blob pool
**by kind**, the overlay's caption and entry count, the camera's eye, target
and quadrant, and the status line. That is what makes a screenshot checkable:
the picture and the numbers behind it come out of the same frame.

It reads `SliceMain`'s own members rather than asking for new accessors:
`game/` gains nothing for this file's benefit, and `main.gd` was not touched.

A screenshot is the viewport's own image, not the desktop's: this host does
not grant Screen Recording to the terminal, so `screencapture` returns
*"could not create image from display"* and the pictures below are all
`root.get_texture().get_image()`.

### 42.2 The shipping export

Rebuilt from the current tree with `--export-release "macOS"` (templates
4.7.1) and launched twice, on `_C_140` and on `_C_132`, for 120 s and 60 s:
the window comes up, the mission builds and **stderr is empty** -- no script
error, which is the check §24.5 introduced and the reason the export is
rebuilt on every change. `tour.gd` joined `shot.gd` in the preset's
`exclude_filter`, so the shipping `.pck` does not carry the driver.

One thing to know for next time: the macOS exporter **removes
`export/incubation-slice.command`**, the console wrapper, on every export. It
is generated content in a gitignored directory and was written back by hand
after each of the two exports here.

### 42.3 What was looked at

All of it through the input path, with the reply's numbers quoted from the
same frame as the picture.

| # | Row of `docs/42` §11 | Mission | What the running build did |
|---|---|---|---|
| 1 | selection | `_C_140` | `TAB` selects slot 2 and the pool holds **exactly four blobs of kind 14** -- the four `A_ARROW` markers of §7.3 -- with five cells in the fill and `Sgt. Bratt MP 3 HP 10 FP 5 ammo 10` on the HUD |
| 2 | walk, walk camera | `_C_140` | a click on a highlighted cell walks the body, spends the movement points, moves the camera's target and changes the world hash |
| 3 | idle | `_C_140` | the scheduler's counters climb -- `idle_starts` 5 → 108 and `idle_frees` 2 → 106 over four turns of one session -- and between commands the `playing` list holds **one to three** slots. It is not a count of the four idle slots: `is_playing` answers for any clip, so the five slots seen during a computer turn are walkers |
| 4 | shot, its stages | `_C_140` | `sequence: shot.clip` → pool kind 11 (the muzzle) and 15 (the round) → kind 17 ×12 at the target with `overlay.entries: 1, fading: true`. The number drawn is a **`0`**: `chance 4 -> 6` reads **88 %**, the shot hits, and the alien's four hit points do not move -- armour, not a miss |
| 5 | fight camera | `_C_140` | the eye is behind the shooter for the shot and stays there while the round flies. It is set rather than flown -- `flying: false` four frames in -- which is §4.3's near arm |
| 6 | computer turn | `_C_140` | `playback: true` with `walking: true`, the HUD line *"the aliens are moving -- advances 6 (any key skips the replay)"*, and the camera flown to the walker |
| 7 | captions, experience | `_C_132` | `chance 46 -> 25` reads **92 %** on a one-hit-point alien; the click kills it and the caption reads **"Cpt. Rutherford received 1 experience points"** for six frames -- §4.2's caption over slice A's experience model |
| 8 | blood, death | `_C_132` | `dying: [25]` while the round flies, then **kind 17 ×15 and kind 18 ×4** on the victim's cell at `gore_level` **2**, gone four samples later |
| 9 | jump | `_C_132` | the fill draws **59 warp cells** beside the walk's; a click on one runs `jump.fly` then `jump.pool` with kinds 9 ×20, 10 ×16 and 50 ×4, and the marine is in the air with the trail behind him |
| 10 | statue beam | `_C_178` | `Statue2 (110,112)` from the mission's own `NextTurn`: three cells carry those action points, and each fires `statue` (17 frames) → `setpiece.pool` with **kind 62 ×24 and ×28** → `setpiece.flight`. Each cell's beam is drawn along one axis, and the three differ; the **alternation turn to turn** that §41.1's `+0x0B` toggle predicts was not checked here -- that wants the same cell on two consecutive turns |
| 11 | script camera, `CrushWall` | `_C_129` | turn 3 runs `script.camera` (the `MoveCamera` flight) → `crush_wall` → `setpiece.pool` with kinds 10 and 5 (the debris of `0x004238C0`), three times, once per call |
| 12 | own door | `_C_103` | `U` with the marine facing the door at (5,8) -- shut on the first press, open again on the second: `setpiece.flight` (the camera down to the door's own place) → **`open_door`** → `setpiece.back`, the eye returning to within a few world units of where it left. The HUD reads `door`, one movement point is spent, and the **fill is the proof the rule ran**: (5,8) drops out of it while the panel is up and comes back, with (4,8) behind it, when a second `U` opens it |
| 13 | mission result | `_C_140`, `_C_178`, `_C_129` | the report draws -- *"Mission Report / Mission failed / You were defeated! / Turns 9"* on `_C_140`, and turns 2 and 3 on the two one-hero missions |

Rows 10, 11 and 12 needed missions the slice set does not carry. The published
cache was widened twice -- to seven for `_C_178` and `_C_129`, then to six for
`_C_103` -- and the five-mission cache was **republished after each**. It came
back at the same content-addressed id both times,
`1-0.15.0-English-4b78eb1431e2-be2eb4bcf223`, and the suites are green on it.

### 42.4 What could not be reached, and the one that could after a second look

Not "not done": **not reachable by hand in a converted mission**, with the
reason in each case. A scan of every shipped `Missions/*.lev` for a *placed*
player-0 unit against its `.lcl`'s commands is what settles it -- **37 of the
138** mission files place a squad at all.

* **`OpenTube`, `Elevator`, `MovePosition`, `MoveTarget`, `RoofUnit`.**
  `_C_115` and `_C_141` carry them, and neither places its squad: their five
  player-0 records are unplaced and the campaign roster fills them, so the
  turn never comes back to the player and their scripts cannot be triggered
  from a keyboard. (`_C_141`'s `RoofUnit` waits on turn 10, which that mission
  never reaches on its own.)
* **`_C_140`'s own `OpenTube` pair.** Its `NextTurn` opens them only when
  `GetActPt (9,11)` is **30**; the shipped cell holds **31**, and nothing in
  this mission's `Use` handler writes it -- it is the campaign that does.
* **`SetGroundFire`, `ParaBombs`.** `_C_116`, `_S_007`, `_C_110` and `_C_111`
  are the only missions that call them, and none places a squad.
* **The map-changing weapons (40, 42, 43).** The two playable missions' units
  carry weapons 1, 2, 3 and 15; no shipped starting squad in them carries a
  Flamer, a mine layer or the Plasma Gun, so the fires, the mine and the shield
  of §37 cannot be produced by firing.

**The door was the exception, and it is now row 12.** `_C_140` carries two
(the cells at (9,11) and (12,14) hold action point 31), and its squad
**cannot get to them**: the fill out of the starting corner is five cells
wide, and over seven turns of walking west the aliens killed three of the four
marines before any of them was within reach. A door is a *cell* whose action
point is one of 30..33 (`Interact.DOOR_IDS`), not an object, so the same scan
that found the squads found the doors: **`_C_103` starts two cells from one**,
with two marines and the nearest alien seven cells off. It was converted, the
door was worked by hand -- it ships **open** (action point 30), so the first
`U` shuts it and the second opens it again -- and the five-mission cache was
republished afterwards, to the same id again.

Getting the marine to *face* the door is the one thing the harness cannot do
in a single click, and that is the game's rule rather than a gap: a walk sets
the facing from its **last step**, so the sequence is a step east to (7,8) and
a step west back to (6,8), which leaves `facing: 1` and one movement point for
the `U`.

### 42.5 Three things the pass showed that no suite says

* **The damage number is a mid grey on a dark scene, and is nearly
  invisible.** `FloatingTexts.TEXT_COLOUR` is `0x5ACB` read as RGB565 --
  (90, 89, 90) -- and the code already marks it **UNVERIFIED as a colour**
  because whether the engine's text drawer takes that word as a pixel or as a
  palette index is not read. In the two shots where the number is on screen it
  takes a zoom to find. That is not a defect to fix by choosing a nicer
  colour; it is a reason the word wants reading, and the note stays.
* **A run of shots that changes nothing has two different reasons in it.**
  Twelve shots left the type-51 alien's four hit points untouched, and the
  `chance` probe is what separated them: marine 4, at **88 %**, hit and drew a
  `0` -- armour ate the damage -- while marines 2, 3 and 5 read **0 %**, having
  no line of sight to that cell, and fired anyway, which is what the original
  lets a player do. Without the probe the whole run looked like one broken
  attack, which is why the harness grew one.
* **A mission whose script keeps running after the squad is dead keeps
  playing its set pieces.** `_C_178`'s statue and `_C_129`'s crush wall both
  fired *under* the "Mission failed" report, because `NextTurn` still runs.
  That is the engine's shape too -- the report is drawn by the interface, not
  by the interpreter -- and it is worth knowing before somebody calls it a
  bug.

### 42.6 Verification

| | |
|---|---|
| `bash godot/run_tests.sh` | 33 suites, **2757** checks, 0 failures, on the republished five-mission cache |
| Shipping export | rebuilt headless; launched on `_C_140` and `_C_132`; stderr empty |
| `remake_convert.py --check-cache` | 29/29, after the two widenings and the two republishes; the restored cache id is byte-identical to the one before the pass |
| `tools/verify_untouched.sh` | **1989 entries identical** against the snapshot taken before the pass; `Work/` unchanged |

Nothing in `core/` or `game/` changed for this pass. `godot/tour.gd` is new,
`godot/export_presets.cfg` gained `tour.gd` in the shipping preset's
`exclude_filter`, and this section and `docs/42` §11's closing note are the
only other edits.

### 42.7 Where the plan stands now

**Slices A through G are done**, and the plan's list is complete: the door,
which the first pass could not reach, was reached on a sixth mission. The
plan's slice G also asked for
`docs/92` §7.10 to stop calling the clip speeds a choice; §7.10 was already
revised for that on 2026-09-03, when `42` §1.2's start slot gave `M` 2.0, `F`
6.0 and `S` 1.5, so nothing was owed there. The presentation plan's list is
closed, with two things named rather than quietly dropped: `CrushWall`'s remaining one or
two cells per call, which want a converter that projects the scene's standard
objects onto the control map (§41.7), and the by-eye question of §25.5, which
no automated pass can answer.

---

## 43. 2026-09-03 — the pad byte 125 of the shipped waves do not count

Slice G's play turned up a warning the suites never see, because no suite opens
a real wave:

```
WARNING: File size 40056 is larger than the expected size 40055.
     at: load_from_buffer (scene/resources/audio_stream_wav.cpp:684)
         [0] _stream_for (res://game/audio/audio_system.gd:268)
         ...
         [4] <anonymous lambda> (res://game/shot_sequence.gd:180)
```

### 43.1 What it is

`sp_hum_1.wav` and `sp_hum_2.wav` -- the pain voices of `docs/28` §4.1, played
from the shot's fifth stage. Both are **one byte** longer than their header
says, and so are fourteen more of the eighty-one waves the cache carries.

The cause is in the shipped data, and it is the same in every case. A RIFF
`data` chunk of odd length must be followed by a pad byte; these files have
one. What the writer did **not** do is count it: the `RIFF` size stayed at
`36 + data`, so the file ends one byte past `RIFF size + 8`. Godot's loader
compares those two numbers and warns.

A scan of the whole installation says how general it is -- **125 of the 407
shipped `.wav` files**, 407/407 examined, every one of them for that reason
(the last chunk is `data` and its length is odd in all 125), and no other
difference anywhere: the deltas are exactly 0 (282 files) and 1 (125 files).

**Nothing is wrong with the sound.** Decoded either way, the two buffers give
identical frames, mix rate, format, channel count and loop mode; the sample is
whole, and every other player reads these files without a word.

### 43.2 The fix, and the two that were rejected

`AudioSystem.with_pad_counted` corrects the **header in memory** -- it writes
the length the buffer actually has into the `RIFF` size field -- and
`_stream_for` hands the result to `AudioStreamWAV.load_from_buffer` instead of
calling `load_from_file` on the path. Nothing in the cache is touched, so the
converter's byte-identical inventory still holds.

It corrects **only the exact one-byte case**. A buffer that is not RIFF, is
too short to hold a header, is shorter than its header claims, or is two or
more bytes over goes to the loader unchanged, so a genuinely damaged file
still reports itself rather than being quietly repaired.

Two other routes were tried or considered and are recorded here so they are not
tried again:

* **Trim the pad byte instead.** Measured: it silences the warning and
  produces an *error* -- the loader walks chunks with `pos += size + (size &
  1)` and then seeks past the end of its own shorter buffer
  (`file_access_memory.cpp:101`). Worse than what it fixes.
* **Re-encode the waves to Ogg in the converter.** No. The pipeline has **no
  third-party dependencies** and runs on the player's machine, so it would
  need an external encoder (`ffmpeg`, `oggenc`) as a new hard requirement; the
  whole wave set is ~2.6 MiB, so there is nothing to save; the samples are
  8-bit 22050 Hz and a lossy pass would change what the player hears, against
  this project's rule that the original is the gold standard; and `.wav`
  decodes to PCM once while Ogg costs CPU on every shot. The music is already
  Ogg, which is where the megabytes actually are. A cosmetic warning is not a
  reason to stop shipping the game's own bytes.

### 43.3 Verification

| | |
|---|---|
| every cached wave, old path | **16** warnings over 81 files |
| every cached wave, through `with_pad_counted` | **0** warnings, 81/81 opened, no errors |
| `bash godot/run_tests.sh` | 33 suites, 2757 → **2766** checks, 0 failures |
| `test_sound` | 43 → **52**: the corrected header, the untouched sample, the caller's buffer not written through, and the five shapes that must be left alone |

`docs/00`'s `.wav` row carries the corpus fact now, since it is a property of
the shipped data rather than of the remake.

---

## 44. 2026-09-03 — `_C_129` joins the shipped set, for its crush wall

`docs/42` §8's `CrushWall` was the last set piece the build could not show:
§42 had to widen the cache by hand to reach it, and put it back afterwards.
That is a poor place to leave the one rule this project measured cell by cell
in the engine (§41.7), so the mission is now part of the slice.

### 44.1 Which mission, and why that one

Three shipped missions call `CrushWall` -- `_C_129`, `_C_142` and `_O_061` --
and those are exactly the three `presentation_gold.py` takes its nine
footprints on. `_C_129` is the one that can be *played* to it:

* its `NextTurn` fires **three** of them, each behind a `MoveCamera`, on the
  plain condition `EnvVarCmpNum (_B,3)` -- so three presses of SPACE reach it,
  with no action point to arrange and no cell to stand on;
* it **places a hero**, which `_C_115` and `_C_141` do not (their squads come
  from the campaign roster, so their turn never returns to the player);
* its world set `A00` is already converted; only the scene `Level01d` and its
  29 prototypes are new.

`SLICE_MISSIONS` is therefore six. As in `docs/95` §1, this is a **content**
republication and nothing else: `CONVERTER_VERSION` stays `0.15.0`, the schema
does not move, and the cache id changes because the inventory does.

### 44.2 One check fired, and it was right to

`cache.size_with_music` failed at **37006 KiB against a 33 MiB ceiling**. The
growth had a name before the number was touched: `_C_129` is the first mission
in the set to ask for a **sixth** CD track, and one track is about 4 MiB. The
silent cache moved by its 29 prototypes alone -- 10528 KiB, comfortably inside
its own 13 MiB ceiling -- which is what `cache.music_is_the_growth` says too.
The music ceiling is now 37 MiB, the comment records why, and the tripwire is
still a tripwire.

### 44.3 Seen in the build

Played through `tour.gd` on the published six-mission cache, with the new
`cell X Y` probe reading the control map either side:

| | before turn 3 | after |
|---|---|---|
| (16, 18) | height **3280**, field type **2 (Wall)** | height **0**, field type **1 (Free Place)** |
| (16, 20) | height 3280, field type 2 | height 0, field type 1 |
| (18, 23) | height 3280, field type 2 | height 0, field type 1 |

Those are the same three sites, and the same two transitions, that the engine
itself left in `presentation_gold`'s capture (§41.7). On the way the queue runs
`script.camera` → `crush_wall` → `setpiece.pool` with the debris of
`0x004238C0` (kinds 10 and 5) in it, three times, once per call.

### 44.4 Verification

| | |
|---|---|
| `remake_convert.py --check` | 181 → **190** (six missions instead of five) |
| `remake_convert.py --check-cache` | 29/29 |
| `bash godot/run_tests.sh` | 33 suites, **2766** checks, 0 failures on the republished cache |
| Shipping export | rebuilt and launched; stderr empty |
| the mission itself | `_C_129 (6/6) 30x30 A00/Level01d`, and the crush wall reached by pressing SPACE three times |

`tour.gd` gained `cell X Y` for this -- the control map's height, field type,
action point and unit for one cell, which is how a terrain change is read back
by hand rather than inferred from a screenshot.

---

## 45. 2026-09-03 — two things play found that no suite could

Both came out of running the build rather than the suites, and both are the
kind of defect a headless check cannot see: one needs a real
`AudioStreamPlayer`, the other needs a camera.

### 45.1 A slot's `finished` connected twice

```
ERROR: Signal 'finished' is already connected to given callable
       'Node(AudioSystem)::_on_slot_finished' in that object.
       [0] play_cue (res://game/audio/audio_system.gd:168)
```

`play_cue` armed the slot's end with `CONNECT_ONE_SHOT`, and one-shot means
*disconnected when the signal fires* -- **not** when the sound stops.
`AudioStreamPlayer.stop()` emits nothing, so every cue that
[method AudioSystem.stop_slot] or [method AudioSystem.stop_tag] cut short --
which is every sound a sequence owns, `docs/28` §1.4's rule -- left its
connection armed. The next cue the pool handed that slot connected the **same**
bound callable a second time, and Godot refused it. The louder the fight, the
more often the pool recycles a slot, so the error arrived from inside the shot
sequence.

[method AudioSystem.arm_slot_end] is now the one place that decides it: the
pending connection is dropped before a new one is made, and a *looping* cue
landing on a slot disarms it outright -- otherwise the loop would have been
freed under its own sequence at the moment the previous sample would have
ended. Five checks in `test_sound` hold the four transitions, and they need no
audio device: connecting a signal does not touch the server.

### 45.2 The move map was drawn over the world

The green cells came out in sheets that cut through crates and through the
lower half of any unit standing between the eye and a marked field. It looked
like several layers of overlay; it was one mesh with `no_depth_test = true`,
set in the first slice so the marking would read on dark, unshaded 1997
scenery.

The engine does not draw it that way, and `docs/10` §4.5 says why: the marking
is a **state byte on the cell**, so the original colours the terrain tile
itself and whatever stands in front of a marked field hides it. Two frames of
the same view, one with the flag and one without, settle the legibility
worry the flag was there for -- with depth testing on, the quads are just as
visible (they are unshaded, alpha 0.72, and lifted 0.06 off the floor) and the
alien in the middle distance stops being cut in half.

`Highlight` therefore depth-tests. `test_render` pins both halves of that --
depth-tested **and** unshaded -- because "paint it over everything" looks like
a rendering preference and is not one.

*(Corrected 2026-09-05 by [`43` §3](43-battle-hud.md): the premise was wrong.
The marking **is** a state byte on the cell, but the original does not colour
the terrain tile -- `fcn.00417E70` projects each marked cell and blits a
`mp1.LIB` digit or a `mp.LIB` frame through `fcn.004475D0`, **after** the 3D
frame and with no depth test, so a marked field is never hidden by what stands
in front of it. `aSetStateOfStdObject` and `aChangeStdObjectProtoype` are not
called from the battle map at all. The depth-tested quads this section
introduced were built on that misreading and were replaced by the ground
overlay of `game/overlay/ground_sprites.gd`; `test_render.gd` now pins the
opposite of what it pinned here.)*

### 45.3 Verification

| | |
|---|---|
| `bash godot/run_tests.sh` | 33 suites, 2766 → **2773** checks, 0 failures |
| `test_sound` | 52 → **57**: the four arming transitions and the double-arm that used to error |
| `test_render` | 19 → **21**: the highlight depth-tests and is unshaded |
| in the build | `_C_129` selected, eyes and unit views: the marine is drawn on top of its own marked cell, and no quad crosses the machinery |

---

## 46. 2026-09-03 — why the rounds flew sideways

Reported from play: *"выстрелы выглядят странно — как снаряды летящие часто
боком"*. They were, and the reason is one field.

### 46.1 What the pool said

`tour.gd` grew `blobs` and `watch N` for this -- every live blob's fields, on
every drawn frame -- because what a projectile is doing is not readable from a
screenshot. One shot of weapon 3 on `_C_132`:

```
blob kind 15 class 0 model 24 at (38400, 54400, 1000) v (800, -600, 350) rot (0, 0, 0) life 16
blob kind 11 class 0 model 8  at (38400, 54400, 1000) v (640, -480, 280) rot (0, 0, 0) life 20
```

Model 24 in `World_C00` is **`A_LINE5.3DI`**, the tracer streak, and model 8 is
`A_CASE.3DI`, the ejected casing -- the right models, the right kinds, a
straight flight. And a rotation of **zero**, which for a shaped model is not a
neutral value: the streak is drawn along whatever axis it was authored on, so
every shot on any other bearing crossed the screen sideways. Kind 15's update
arm is a move and a death and never touches the rotation, so the zero survives
the whole flight.

*(One false step on the way, recorded because it was nearly a wrong fix: model
24 is `A_PANEL.3DI` in `tables/blobs.json`'s alphabetical list, which made this
look like a model-index mismatch. It is not -- `BlobHooks.model_index` is built
from the **world set's own** prototype order, and 24 is `A_LINE5.3DI` there.
The list in the tables is not the index space.)*

### 46.2 What the engine does, from its own capture

`tests/fixtures/blob/cases_native.json` already held the answer.
`0x00424D20`'s burst -- two tracers and two casings -- carries
**`(65528, 0, 2344)` on every record**, and `0x00403AA0` answers **2344** for
that burst's own direction. So the creator orients once per call and stamps the
triple on everything it makes; the casings keep it although their velocities
point elsewhere. The line's own angle is 2350 and two calls record 2344 and
2379, so the burst is oriented on the line **plus the creator's spread**.
`docs/28` §7.6.3 now carries this.

### 46.3 The fix

`BlobTriggers._create` gives every class-0 or class-1 blob the triple
[method BlobTriggers._facing] computes -- `BlobHooks.orient`, which is
`0x00403AA0`'s measured arithmetic -- for the shot's own line. Sprites are
untouched: for a class-2 or class-3 blob those same words are the atlas row and
column, not a rotation.

What stays the remake's is the **spread** the creators put on the line before
they orient, and the per-blob speed §14.5 already named. The line itself is the
engine's, the arithmetic on it is the engine's, and the triple is now stamped
per call as the engine stamps it.

Measured after the fix, the same shot:

```
blob kind 15 class 0 model 24 ... v (800, -600, 350) rot (65317, 0, 1443)
```

and `inclib.eng3d.orient((0,0,0), (800,-600,350))` is `(-219, 1443)` --
`65317` is `-219` as a word. The two sides agree without sharing code.

### 46.5 The half that was still wrong: the sign of the drawn angle

The field was now written and the rounds still flew across their path, which
put the fault on the other side of the seam -- in what `game/` does with the
word. Three measurements settle it, and none of them is a screenshot:

* **An Eng3d model is authored along engine +Y.** `A_LINE5.3DI` is 1600 units
  long in Y against 242 in X and 160 in Z; `A_LASERG.3DI` is 3200 in Y;
  `A_CASE.3DI` is 192 in Y. Read straight out of the converted geometry.
* **`0x00403AA0` measures a bearing from +Y toward +X**: it answers 0 for
  `(0, 3200)`, 1024 for `(3200, 0)`, 2048 for `(0, -3200)`. So a model turned
  by its own bearing must rotate *against* the sense of a positive rotation,
  which takes +X toward +Y.
* **`E3D_init_matrix_RzRxRy` negates all three angles** before it indexes the
  table -- `neg ebx / neg ecx / neg edx`, §18.1's first of the three properties
  that had to be right together. `WorldSpace.joint_basis` reproduced the
  builder's *order* and not that negation: it carried a minus on the Y term,
  which is the axis flip of `(x, z, -y)`, and none on X or Z.

With the negation restored, `joint_basis(0, 0, bearing)` sends the model's
forward -- Godot `-Z`, the image of engine +Y -- along that bearing on every
cardinal and on the pitched sample, dot product 1.000. Before it, the streak
was mirrored about the +Y axis, which is "sideways" for every bearing off the
axis and right on it.

**A fourth thing agrees, and it was measured a slice earlier.**
[method WorldSpace.charisma_yaw_basis] is `2048 - yaw`, found by making
`docs/10` §5.10's facing table come out right for all eight facings: that is
this same negation plus the half turn a Charisma body's **-Y** forward needs.
Two authored forwards, one sign.

**Left open deliberately:** [method WorldSpace.yaw_basis], which places
*scenery* and unit nodes, still takes the engine word as a positive rotation.
The same argument says it should not, but scenery orientation was accepted by
eye in the first slice and turning every crate and door in the game on the
strength of an inference is not a change to make quietly. It wants its own
check -- an asymmetric object with a known yaw, against the original -- and
until then it is named here and nowhere else.

**Closed on 2026-09-04 by §47**, and by something better than the screenshot
that sentence asked for.

### 46.6 Verification

| | |
|---|---|
| `bash godot/run_tests.sh` | 33 suites, 2773 → **2775** checks, 0 failures |
| `test_effects` | 276 → **278**: every model blob of a muzzle carries the shot's own triple and no sprite does, and a bearing sends a model's +Y forward onto itself |
| in the build | the streak lies along the line from the shooter to the target, checked against both cells' own projections rather than by eye |

~~**Still open, and now visible in play**: the thirty creators a weapon selects
are transcribed nowhere, so their spread, their per-blob speeds and their exact
pitch are the remake's stand-ins. Closing that is a `blob_gold.py` capture of
those thirty~~ — **taken, 2026-09-11/12.** §14.5.1–§14.5.5 are that capture;
twenty-five of the thirty were replayed against it that night and the last
five joined them in §51.1, which also explains the two yaws quoted above.

## 47. 2026-09-04 — the same sign, in the half that places the world

§46.5 left `WorldSpace.yaw_basis` alone on purpose. It places every piece of
scenery and every unit node, the argument for changing it was an inference, and
the check it wanted was named as "an asymmetric object with a known yaw,
against the original". That check turned out to be unnecessary: the engine
answers the question itself, and the answer is measured end to end.

### 47.1 Where a placed object's heading actually goes

The obvious reading is that the renderer builds an object's matrix from its
rotation triple and then runs the prototype. It does not, and that matters,
because the two matrix builders `Eng3d.dll` exports **disagree** on a pure yaw:
`_E3D_init_matrix_RzRxRy` (`+0x411BF6`) opens with `neg ebx / neg ecx / neg edx`
and `_E3D_init_matrix_RyRxRz` (`+0x411A93`) does not. Which one a heading
reaches is therefore the whole question, and it is not a property of the
renderer — it is a property of *the prototype's own bytecode*.

`_E3D_object_3d_check_in` (`+0x404BD0`) reads only `+0x10/+0x14/+0x18`: it
culls against the view box and never touches the rotation. The triple is read
by seven opcode handlers in the range `+0x405EEC`..`+0x4060F0`, all of which
open the same way:

```asm
mov  ebx, [0x414084]      ; the object being drawn
mov  esi, [ebx + 0x1c]    ; its joint buffer
test esi, esi
jne  ...
lea  esi, [ebx + 0x20]    ; ...or the record's own triple, when there is none
add  esi, eax             ; plus the opcode's anim offset
```

So `+0x1C` — which `docs/10` §6 records as "always written as `0`", in 100 % of
records — is the *joint buffer pointer*, and `+0x20` is the inline default the
handlers fall back to. A placed object's heading is a joint angle at anim
offset 0, and the opcode that reads it is written into the prototype.

### 47.2 Which opcode, over the whole corpus

Measured, not assumed, across all 155 shipped `.lev` and all 26 072 prototypes:

| | |
|---|---|
| special objects with a heading | 6 333 |
| …whose prototype rotates at anim offset 0 | **6 332** |
| …and does so with an opcode that negates | **6 332 of 6 332** |
| the exception | one `L096EF00.3DI` record, which the engine draws unturned |
| scene clones with a heading | **0 of 1 125** — the `.3DW` `ROTATION` is zero in every `[CLO]` |
| the ground lattice | one prototype, `S003_00X.3DI`, checked once |

The clones are worth a line of their own: `docs/10` §9 item 5 says the array is
never saved and is re-parsed from the `.3DW`, and the converter does read the
`.3DW` (`convert.scene_clones`), so the `.lev`'s own scene-object rotations —
which `docs/10` §6 counts as 1 450 of 1 530 on quarter turns — are stale
runtime state that nothing in the remake reads. Not one shipped clone is
turned at all.

And the render stream — the only one of a prototype's three that draws —
carries exactly three of the seven rotation opcodes, at exactly three anim
offsets:

| opcode | builder | anim offset | occurrences |
|---|---|---|---|
| `joint_rotate_3` (9) | `+0x411A59` fast path, else `+0x411BF6` | 0 | 1 959 |
| `joint_rotate_3_alt` (10) | `+0x411A59` fast path, else `+0x411A93` | 0 | 367 |
| `joint_place` (18) | `+0x411BF6` | 6 and 12 | 213 |

`matrix_from_angles` (15), the one opcode that goes straight to the
non-negating builder with no fast path, appears in **no render stream at all**.

The fast path is `or ax, cx / je` at `+0x40601E` and `+0x406093`: when the
first two components of the triple are zero — which they are in all 194 105
shipped records, `lev_parse.py --check` 155/155 — the handler leaves the
three-angle builders alone entirely. It is worth reading rather than assuming
an equivalence, because it is the path **every** shipped object takes.
`+0x411A59` writes

```
[  cos  -sin   0 ]
[  sin   cos   0 ]
[   0     0    1 ]
```

straight out of the two tables at `0x48E6C0` and `0x48EEC0` and **does not
negate**; `+0x41204F` then composes the parent matrix with a Z rotation it
builds *again* from the same two tables with the same signs — it never reads
`+0x411A59`'s output at `0x41A864` at all, so the pair is one rotation written
twice. With an identity parent `+0x41204F` produces `+0x411A59`'s own matrix
entry for entry, and both answer what `+0x411BF6` answers for a pure yaw
(checked over the shipped `TRIG.IMG`, direction identical, the two roundings
differing by at most one unit in 1600).

So **every rotation the renderer applies negates its angle**. There is no
residue: the three anim offsets `BlobModels._triple_basis` honours, 0, 6 and
12, are the three that exist, and no drawn rotation reaches `+0x411A93`.

### 47.3 The engine agreeing with itself

The sweep below runs `eng3d.matrix3`, which is the `+0x411BF6` model rather
than the fast path a shipped object actually takes. §47.2's reading of
`+0x411A59` and `+0x41204F` is what makes that substitution legitimate, and it
is why that paragraph reads the two routines instead of asserting an
optimisation.

The chain above ends at `_E3D_init_matrix_RzRxRy`, which §18.1 reproduces 8/8
inside a running `Incubation.exe`. Run the shipped `TRIG.IMG` through it for
`docs/10` §5.10's eight facing angles and ask where an object's authored +Y
lands:

| facing | angle | +Y turns to | the step `aExecuteUse` takes |
|---|---|---|---|
| 0 | 0 | `(0, +1599)` | `(0, +1)` |
| 1 | 3072 | `(-1600, 0)` | `(-1, 0)` |
| 2 | 2048 | `(0, -1600)` | `(0, -1)` |
| 3 | 1024 | `(+1599, -1)` | `(+1, 0)` |
| 4 | 1536 | `(+1131, -1132)` | `(+1, -1)` |
| 5 | 3584 | `(-1132, +1131)` | `(-1, +1)` |
| 6 | 512 | `(+1131, +1131)` | `(+1, +1)` |
| 7 | 2560 | `(-1132, -1132)` | `(-1, -1)` |

Eight of eight. With the angle taken positively, six of the eight are wrong and
the two that agree are the two a sign cannot move. Neither of the two tables is
the remake's: `FACING_ANGLES` is `fcn.0046A6E0`'s switch and `FACING_STEPS` was
confirmed natively by sweeping `aExecuteUse` over all eight facings
(`inclib/lev.py`).

### 47.4 What changed, and what did not

`WorldSpace.yaw_basis` negates. `WorldSpace.charisma_yaw_basis` was
`yaw_basis(2048 - yaw)` and is now `yaw_basis(yaw + 2048)`; those are the same
angle modulo a full turn, so **no body moved** — the old formula was fitted
against `docs/10` §5.10 while `yaw_basis` turned the wrong way, and it had been
silently absorbing the error. The reason improved with it: a correction shaped
like `2048 - yaw` looks like a reflection, and the earlier note had to argue a
mirror away with the marine's `Hand_R`; a *half turn* is exactly what a model
authored facing **-Y** wants when the geometry around it is authored along
**+Y**, and there is nothing left for a mirror to explain.

What moved is scenery, and only half of it. Negating a yaw maps 1024 to 3072
and leaves 0 and 2048 alone, so of the 99.5 % of records on quarter turns
(`docs/10` §6) exactly half were a half turn out. The shipped world is built of
walls, floor tiles and crates that are symmetric end for end, which is why a
slice of looking at it did not catch this and why the by-eye check §46.5 asked
for would have been a poor instrument anyway.

Three stale claims went with it, all of them ones this measurement contradicts:

* `world_space.gd` said `test_charisma.gd` pins `engine_matrix` with "an engine
  yaw against `yaw_basis`". No test does; what pins it is the bone sweep, every
  bone's full local matrix at one frame against `cha_parse.py`'s.
* it also said no shipped joint prototype uses `joint_rotate_3_alt` or
  `matrix_from_angles`. `joint_rotate_3_alt` is used 367 times, all at anim
  offset 0, and is saved only by its fast path. Slots 14, 15 and 18 do appear
  in the collision and part-info streams — with the render stream's own counts,
  1959 / 367 / 213, which says those are the same instructions under a
  different dispatch table rather than three more uses; **what those tables
  dispatch them to was not read here**, and is `docs/31`'s question. The claim
  that was wanted, and that holds, is about anim offset 0 in a render stream.
* `docs/10` §9 item 6 named three call sites reading `[ebx + 0x20]` and left
  which builder they reach open. All seven are enumerated above.

### 47.5 Verification

| | |
|---|---|
| `bash godot/run_tests.sh` | 33 suites, 2775 → **2778** checks, 0 failures |
| `test_effects` | 278 → **280**: a heading equals the joint triple's third component, and turns geometry the way `Eng3dGeometry`'s measured builder does |
| `test_charisma` | +1: `facing.eng3d_forward_walks_forwards`, an object's +Y against the step, all eight |
| `verify_3d_indices.py` | 31 → **39** check kinds: the 6 332 headings, the 1 125 clones, the lattice, the eight facings, and the one prototype that has a heading and no opcode |
| mutation | the sign put back: 4 checks fail, `2` of `8` on both arithmetic ones — the two a sign cannot move |

`_C_140` was looked at afterwards -- in the editor project through
`shot.gd`, not in an exported build -- and that is all the looking is
worth: 481
scenery instances as before, the pipe runs continuous, the crates flush, and
nothing came apart. It is not evidence for the sign — half the shipped geometry
is symmetric end for end, which is the whole reason the wrong sign survived a
slice — and it is recorded as a sanity check and not as a verification.

**Not done, and named:** the four checks above say nothing about whether the
*converted* geometry carries its prototype's parts in the order the engine
draws them. That is the by-eye half of `docs/93` §10.4 and it is unchanged.

## 48. 2026-09-04 — the zoom bob's six arguments, stepped

`aBlob_CreateZoomBob` `0x00423720` is the one creator an arm can reach that
[`blob_programs.gd`](../godot/game/fx/blob_programs.gd) transcribes, and
wiring the arms' spawn requests to the creator programs for the first time
(§7.14 of [`92`](92-remake-architecture.md)) made its argument count
load-bearing. It did not survive the first look: the callee reads **six**
arguments — `x` at `+0x04`, `y` at `+0x08`, `z` at `+0x0C`, `row` at `+0x10`,
`aux` at `+0x14`, `life` at `+0x18` — and all fourteen of its call sites clean
six dwords, but **five of the seven arm requests carried five**. Both twins
had the same shortfall, which is why the arm capture never saw it: it compared
the stepped record's own fields and the request *list*, GDScript against
Python, and never a request against the engine's push block.

Reading the push blocks settled three of the five and got two wrong. What
settled all seven was **stepping the arms inside `Incubation.exe`**: a donor
pool, one record poked to each kind, one `aBlob_Update` per record, and the
child read back out of the pool — its `rot_x` is the `row` argument, its `aux`
the fifth and its `life` the sixth. Two runs, at a poked `life` of 6 and of 1,
so both sides of every guard were reached.

| kind | row | aux | life | when |
|---|---|---|---|---|
| 6 | 4 | 10 | 8 | every tick |
| 15 | 1 | `aRandom2(5, 15)` | **8** | `life == 0` |
| 26 | 0 | 30 | 16 | `life == 0` |
| 56 | **7** | `aRandom2(2, 5)` | **7** | **every tick** |
| 69 | 6 | `aRandom2(5, 15)` | **8** | `life == 0` |
| 73 | 1 | `aRandom2(5, 15)` | **8** | `life == 0` |
| 77 | **0** | `aRandom2(5, 10)` | **8** | every tick |

The bold entries are what the twins had wrong. Three are the missing `life`.
The other two are the ones a static reading could not have got right:

* **Kind 77's `row` is `push ebp`, and `ebp` is the sweep's own zero**
  (`xor ebp, ebp` at `0x0041E50A`, the same register arm 45 writes over the
  *arrived* flag). Both twins had a literal 5 — the `push 5` two instructions
  earlier, which is `aRandom2`'s base.
* **Kind 56's arm has no `life` test at all.** Both twins guarded its spawn
  with `if life == 0`, so the arm dropped one zoom bob at the end of a
  record's life where the engine drops one on **every** tick — and with three
  coordinate jitters of `aRandom2(-50, 100)` that the twins did not draw
  either, which is one draw against four on the shared `aRandom2` stream.
  `0x00420037`'s `vz` step is the tail the arm shares with the wrapper's
  success path, which is what makes the arm read like a guarded branch when it
  is not.

The jitters are not the same arithmetic in the two arms, and that is the
engine's: kind 56 adds the coordinate to the draw with `fiadd` and truncates
the sum (`0x0041FFD6`), while kind 77 truncates first and adds through
`movsx ecx, ax` (`0x0041F78A`). That one was **by the bytes and not by the
measurement** when this was written — the two forms differ only when a draw's
fractional part straddles an integer, and the three deltas the trace showed
(+38, +45, +27) are the same either way. §49 measured it: a written seed puts
every jitter on the side where the two readings differ, and the engine chose.

`blob_tables.py` gained two checks: `arm_spawn.arity`, which compares every
`_spawn` request's value count against the `add esp, K` at every call site of
that creator — thirteen creators, and it is what would have caught this — and
`zoom_bob.pushes` / `zoom_bob.unconditional`, which pin the sixteen bytes the
table above rests on and the three arms that carry no `life` read. A third,
`arm_spawn.args_needed`, holds the **other** end of the same request against
the same `add esp, K`: `blob_programs.gd`'s `ARGS_NEEDED` is what
`GameBlobHooks` refuses a short call by, and an entry raised above the real
arity would turn every request for that creator into a counted refusal with
every other check still green.
`BlobPrograms.ARGS_NEEDED` refuses a short request rather than indexing past
the end of its array, which is what the defect did while it lasted.


## 49. 2026-09-04 — what a creator is *given*

§48 fixed five wrong arguments to one creator and closed with two loose ends:
twelve creator addresses an update arm can reach that no program anywhere
carried, and a jitter arithmetic settled by reading bytes rather than by
measuring. Both are closed here, by the same experiment.

### 49.1 The gap, and why nothing had noticed it

Three families of creators exist. [`28` §8.1](28-effects-and-sound.md)'s
weapon switches name **thirty**, measured by `blob_gold.py` (§15, §22);
[`42`](42-mission-presentation.md)'s deaths, unit animations and set pieces
name **twenty-nine**, measured by `presentation_gold.py` (§31, §32, §37). The
third family is an update arm's own `aBlob_Create*` call, `docs/28` §7.1 —
**thirteen** addresses, twelve of them reached from nowhere else in the game.

Nothing in the remake had ever run one. `BlobHooks.spawn` records a request
and returns success, which is what an oracle wants and what a game must not
do; `GameBlobHooks` (§7.14 of [`92`](92-remake-architecture.md)) runs it, and
found twelve addresses with no program behind them. And no capture measured
them either: the **poked** family steps an arm with a donor record and reads
`READ_RECORDS = 12` slots, which is the donor's own — a child lands past them
and was never in the window. So an arm's arguments to its creator were the one
part of the effect layer that neither a capture nor a twin diff looked at, and
§48's five wrong ones are what that costs.

### 49.2 The two families

`blob_gold.py` gained `zoom_bob_*` (the seven arms that ask for the zoom bob,
each under two seeds) and `spawn_*` (the other fourteen). Three things about
them are the experiment rather than the plumbing:

* **A pool per entry.** Reset, donor, one poked record, then eight rounds.
  The poked family shares one pool across six records, which is right when
  the record is what is measured and wrong here: one arm's brood can be a
  hundred records (`0x0042A7A0`), the window fills, and every later child
  lands past its end. The first run of this family did exactly that and went
  quiet from round two onward.
* **A written seed.** `aRandom2`'s seed is written through the game's own
  `memcpy` before **every** call and read back on the same line. That is what
  turns a measurement of an arm into a measurement of an *arithmetic*: under
  6.0 every jitter both zoom-bob arms take is negative with a fraction, which
  is the only place `fiadd` and `movsx` disagree; under 2.0 every one is
  positive, which is the same arms where the two readings agree. The check
  computes **both** candidates from the seed and requires them to differ
  before comparing the engine against either, so a seed that drifted could
  not pass by comparing a value with itself.
* **A window of forty-four records.** The donor's thirty plus room for a
  brood. A brood bigger than that is compared as the prefix it is, with the
  generator's seed after the call accounting for the rest.

Two arms needed a seed of their own, and `SPAWN_SEED_OVERRIDES` is the same
shape as `poke_probes`' targeted vectors. Kind 52 drops its para bomb only
when `aRandom2(0, 8)` rolls a zero, which neither sweep seed does, so it gets
1.0 — the reason `0x0042B150` is reached at all. Kind 62's spark burst is
behind `aRandom2(0, 10) > 5.0`, and 6.0's first draw is 1.73: its branch had
not run **and its jitter had not been measured** while the note beside it said
otherwise. 19.0 rolls 5.49 and then three negative fractional jitters, which
takes the branch and discriminates the arithmetic in one call.

### 49.3 What it found: four more arms, six corrections

| kind | what the child said |
|---|---|
| 32 | the sting sparks are spawned on **every** tick; `0x0041F577`'s branch guards the *arrived* flag write alone |
| 59 | the emitter takes **two** velocity draws and a literal zero, and the first draw is its `aux` — the ordinary branch by the child (`0x00420162`), the special one by the same three bytes (`0x00420101`) and by its draw count |
| 59 | so the arm drew a value it does not draw, which put every arm after it in the sweep one step out of the shared stream |
| 62 | its plasma-spark jitter is `fiadd` (`0x0041E8EA`), not truncate-then-add |
| 62 | its terminal emitter's 800 is the **vertical** and its 20 the `aux` (`0x0041E95A`), with the sweep's zero for both horizontals |
| 67 | the same `fiadd` jitter (`0x0041EE98`) |

Every one is invisible to a diff of the record's own fields, which is what
every earlier check of this layer was. Kind 59's extra draw is the one worth
staring at: an arm that draws once too often is correct about its own record
and wrong about **every other arm's** in the same frame, because the engine
keeps one `aRandom2`.

### 49.4 The jitter, measured

Four arms add a draw to a coordinate and three arithmetics were claimed for
them. The engine's answer, on a seed that discriminates:

| arm | site | reading |
|---|---|---|
| 56 | `0x0041FFD6` | `fiadd` — the coordinate joins the draw, the **sum** truncated |
| 62 | `0x0041E8EA` | `fiadd` |
| 67 | `0x0041EE98` | `fiadd` |
| 77 | `0x0041F78A` | `movsx ecx, ax` — the **draw** truncated, then added |

`0x0042A7A0` is a fifth case and the plain one: `add esi, ebx` after `_ftol`,
truncate-then-add, inside the creator rather than the arm.

### 49.5 The twelve, transcribed

`tools/inclib/blob_creators.py` and `godot/game/fx/blob_programs.gd` carry all
thirteen now (`0x0042A9D0` was already the weapon family's; the arm registry
delegates to it rather than transcribing it twice), plus `0x0042ADD0`, the
sparking rain only `0x0042A410` calls. Four things in them are easy to get
wrong and are measured:

* `0x00428F70` is called with **five** dwords and reads four. The fifth is
  the sibling sparks' `life` and this one draws its own; the compiler uses the
  *fourth* argument's slot as the scratch its three `fild`s load from, which
  is what makes the omission look like a use.
* `0x0042ADD0`'s `speed` is a two-value enumeration and the third value is a
  `CHECK` — `"unknown speed"`, and nothing made. 0 is a life of 30 with the
  sideways draws as they come, 1 a life of 5 with both doubled.
* `0x00429430` draws **nothing**: two records whose velocities are the
  caller's own turned a quarter turn either way and cut to a fifth by the
  compiler's reciprocal multiply, which truncates toward zero.
* `0x0042B150` is **not** `0x0042B070`. The arm's para bomb reads no object,
  has no ceiling and does not touch the *arrived* flag; the set piece's does
  all three.

### 49.6 What is checked, and where

`blob_gold.py --check` is **268 checks**: `spawn.arms_stepped` (21 arms),
`spawn.creators_reached` (13), `spawn.arms_disagree` (none),
`spawn.jitter_discriminated` (all four arms, on calls where the two candidate
readings actually differ) and `spawn.seed_overrides`, which reads the
overrides back out of the capture rather than out of the table beside it.
`blob_tables.py`'s `spawn.jitter_forms` pins the same four arms' twelve
instructions, which needs no capture at all.

One branch stays outside all of that and is worth naming: kind 59's **special**
emitter runs only under an output mode `mode_59` writes, and that plan is a
poked one whose window holds no child. What is measured there is the branch's
*cost* — `mode.special_draws` reads `aRandom2`'s seed either side of every
call and finds seven draws against the ordinary four, which is the "two
velocities and an `aux`, not three velocities" half — and what says where the
three go is `spawn.emitter_vz_is_ebp`: both sites are the same `call _ftol` /
`push eax` / `push ebp`, and the ordinary one of the two *is* compared against
a child. `test_blob_native.gd`
replays the **GDScript** side of the same capture — `BlobKinds.tick` for the
arguments and `BlobPrograms.run` for the records — so the remake's own path is
compared against the engine rather than against Python. `blob_tables.py` pins
the scratch name to the two `push` sites that hand it to the constructor, and
`test_effects.gd` requires every address `BlobKinds` can ask for to have a
program.

---

## 50. 2026-09-12 — `CrushWall`'s footprint, projected

§41.7 measured all nine shipped footprints inside the running engine and then
called the *source* of the split underivable: the object `0x00406F20` answers
with is a **standard object**, the array at `[0x004FA80C]`, and that array was
read as something the engine builds when it expands the scene's prototypes.
The remaining half — a converter that projects the scene's standard objects
onto the control map — was named as a slice of its own and deliberately not
started.

It is not a slice. It is one read of an array this project had already
identified.

### 50.1 What the standard-object array actually is

[`99` §10.1](99-slice-7-report.md) says it in as many words: *"the engine's
object search `0x00406F20` walks the special-object table at `[0x4FA80C]` and
nothing else, so a clone is not a thing any set piece can find, turn or free"*.
`Scenery` has excluded `.3DW` clones from `objects_on` since 2026-09-07 for
exactly that reason. §41.7's own wording — "neither the map's 900-entry land
lattice nor `LEVEL01D.3DW`'s 27 `[CLO]` blocks" — rules out the two things it
is not and never asks what is left, which is the `.lev`'s **special objects**.

They are there, and they are the wall:

| Mission | `CrushWall` | The special object standing on that cell | yaw |
|---|---|---|---|
| `_C_129` | (16, 18) | `L040EA00` | 1024 |
| `_C_129` | (16, 20) | `L041EA00` | 1024 |
| `_C_129` | (18, 23) | `L040EA00` | 0 |
| `_C_142` | (22, 11) | `L040EA00` | 1024 |
| `_O_061` | (16, 23) | `L040EA00` | 0 |
| `_O_061` | (11, 23) | `L040EA00` | 0 |
| `_O_061` | (11, 19) | `L040EA00` | 0 |
| `_O_061` | (13, 19) | `L040EA00` | 0 |
| `_O_061` | (14, 19) | `L041EA00` | 2048 |

Nine calls, nine records, on the command's own cell every time. And the two
prototypes are the two footprint lengths §41.7 measured: `L040EA00`'s vertices
run from local `x` −4 817 to 1 583, which is **6 400 units = two fields**, and
`L041EA00`'s from −8 017 to 1 583, **9 600 = three**. Both are 1 500 deep in
`y` and stand 80..3 280 high, which is the 3 280 the marked cells drop from.

### 50.2 The sweep is arithmetic

`0x0042F410` casts four probes per cell from the cell's own symbol object at
`z = 100000` **straight down**. A vertical ray meets a mesh exactly when the
probe's `(x, y)` lies inside the `xy` projection of one of its faces — so the
BSP tree, the plane arithmetic and `0x0042F300` itself are not needed to
answer the question the sweep asks. `inclib/footprint.py` is that: each vertex
through the engine's own three-angle matrix (`eng3d.rotate`, `0x004039A0`),
translate by the record's position, drop `z`, crossing-number against the four
probes.

It reproduces **all twenty cells of the nine footprints**, cell for cell,
against `docs/42` §8.2's table — which is the engine's own answer, captured
under `dbgcall` on 2026-09-03 and not this module's. `interaction_tables.py`'s
`corpus.crush_wall_footprints` holds that comparison and is mutation-killed by
replacing `eng3d.rotate` with the identity (one cell moves, the check fails).

Two smaller findings came with it:

* the probe geometry — `81 c2 c8 00 00 00` twice and `81 e9 c8 00 00 00`
  twice, which the byte pins alone could not tell from the four corners —
  **cannot be discriminated by measurement**: both give the same nine
  footprints, because every wall piece is 1 500 units deep against a 400-unit
  probe span. So it was read: each probe loads one coordinate of the symbol
  object (`+0x10` x, `+0x14` y) and offsets it while the other is loaded
  plain — `(x−200, y)`, `(x+200, y)`, `(x, y−200)`, `(x, y+200)`, the
  **cross**, pinned at the four load sites as `special.probe.{1..4}_*`
  (verified-static, 2026-09-12);
* two special objects **do** cover one cell on the shipped maps — railings and
  pillars sharing a field, ten cells on `_C_129` and nine on `_O_061` — but
  never on a wall piece and never on a cell any `CrushWall` names, so
  `footprint_index`'s "first placed wins" decides nothing in play
  (`corpus.crush_wall_cells_carry_one_object`).

### 50.3 Where it runs, and what it changed

The projection runs **once, in the converter**, and neither runtime holds a
mesh: `mission_document` emits `cells` beside every special object (a
`CONVERTER_VERSION` bump, 0.39.0 → **0.40.0**, in `cache.py` and
`cache_loader.gd` both, and a republished cache). `MapResource` builds a
`cell -> run` index at load — outside `authored_hash`, which digests the grid a
save has to agree with and not what stands on it — and `World` hands it to
`LclContext`. `LclInterpreter._crush_wall` and `inclib.lcl_runtime._c_crush_wall`
then write height 0 and field type 1 on **every cell of the run** and put them
all on the event.

`game` needed nothing: `SetpieceCamera` has thrown one `0x004238C0` per cell of
the event since the set pieces landed (`camera.crush_wall.one_per_cell`), and
`aDeleteLand`'s single free is still `remove_objects` on the command's cell,
which is where the one object stands.

~~**One residual, named rather than closed.** `core` now finds the run by *any*
covered cell, the way `0x00406F20`'s box search would; `game` still finds the
wall's node by the **command's** cell (`remove_objects`, `paint_pose`). On all
nine shipped calls the record stands on the command's cell, so the two agree
— but a script naming the *far* cell of a run would crush the cells and leave
the node standing.~~ **Closed the same day.** `SliceMain._block_cell` already
walked `FootBridge2`'s group for the cell that carries the block; it now walks
a `crush_wall` event's footprint the same way (`SetpieceDriver.footprint_cells`),
so the node is found by any cell of the run — `family.wall.node_found_by_any_footprint_cell`
names (16, 19) and gets the record on (16, 18).

A map document with no `special_objects` — every synthetic map the suites build
— leaves the index empty and every reader falls back to the cell it was given,
which is exactly what the model did before. That is why
`crush_wall.off_the_map_changes_nothing` and the synthetic case either side of
it did not move.

### 50.4 Verification

`interaction_tables.py --check` at **161** checks (`corpus.crush_wall_calls`,
`corpus.crush_wall_footprints`, `corpus.crush_wall_cells_carry_one_object`),
`lcl_runtime.py --check` with two new `crush_wall.*` cases, `make
check-formats` green, and `bash godot/run_tests.sh` at 41 suites and **5 459**
checks with the cache republished at 0.40.0 — `family.wall.footprints` reads
the three `_C_129` runs back out of the cache through `MapResource` and
`crush_wall.the_whole_footprint_becomes_floor` drives them through the
interpreter.

**What this closes.** [`102` §1.1](102-remake-backlog.md), and §41.9's "named
and deliberately not started". What it does *not* close is the general
statement §41.7 reached for: this projects **special objects**, which is what
`0x00406F20` searches. Nothing here reads a `.3DW` clone or an expanded
prototype, because the engine's own search does not either.

## 51. 2026-09-12 — the last five creators, and the byte weapon 11 reads

[`102` Stage 2](102-remake-backlog.md) held two items about the picture: five
of the thirty weapon creators were not replayed against the capture, and
weapon 11's arc had never run. Both are closed here, and the second turned out
to be a reading error in the pattern layer rather than a property of a save.

### 51.1 Thirty of thirty

§11's bullet counted 25 of `blob_tables.creators.reachable`'s thirty replayed
in `test_blob_native` and named the other five: the tracer `0x004247C0`, the
needles `0x00424250` and the flash `0x00423D80`, still on `BlobTriggers`'
constructor-table arm — one record per `call`, the spread inside a call the
remake's own — and the shock wave `0x00422B80` and the spore cannon
`0x004268B0`, built as records of their own and checked structurally in
`test_effects`. Every one of the five already had a phase in the capture, so
what was missing was the program on the Godot side and the row that replays
it.

`BlobPrograms` now carries `tracer_bullet`, `flash` and `needles` — twins of
`inclib/blob_creators.py`'s `_c004247C0`, `_c00423D80` and `_c00424250`,
sharing `_burst_prologue` the way the Python does — and `spore_cannon`, which
has no Python twin because the landing dust `0x004227C0` set that precedent
(`test_blob_native.IMPACT_CREATOR`: a program the suite replays directly
against the engine needs no second reading between them; `blob_gold`'s
`CREATOR_PROGRAMS_EXPECTED` stays at 28). The three bursts are routed as
`BlobTriggers.BURST_TYPED`,
because their tail differs per weapon the way the three typed seams' does:
the fifth and sixth arguments are the round count and the stagger the muzzle
switch's own arm pushes, which `bursts()` already read out of the document.
The spore cannon is a plain row. The shock wave stays on the tile seam
(`_ask_tile` → `SliceMain.spawn_program`), because `_run_weapon_program`
stands the *summed* point in for the object when a caller passes `NO_POINT`,
and the ring is placed on the object; it is replayed all the same, and
`_check_routed_are_measured` counts it beside the typed seams.

What that removed from `BlobTriggers` is the whole constructor-table arm:
`_create`, `_by_creator`, `_facing`, `_casing_velocity`, `_velocity`,
`_needles`, `_burst_*`, `_spore_*`, both `_point_blank_*` branches, the
`_ask` seam the point-blank bobs went out through, and thirty-odd constants.
The nested creators a burst runs — the tracer's zoom bob every round, the
flash's ten bobs and the needles' bob plus twenty sparks at point blank — are
spawned by the program into the same pool, in the engine's own draw order,
which is where the capture shows them; they used to come back as requests and
were counted separately.

`test_blob_native.weapon_programs.*` replays all thirty: 303 records
(`CAPTURED_RECORDS` gained 30 + 27 + 10 + 12 + 1 — the shock wave's phase is
the capture's twelve-record window onto sixty, so the prefix is what is
compared, and the comment says so), every seed advance, and the routing table
against the judged list. All five reproduced field for field on the first
run, and each was then mutation-killed on the same check: `TRACER_STEP` off by
one fails on `0x004247C0.0.y`, the needles' last kind swapped fails on
`0x00424250.8.kind`, `SPORE_LIFE_BIAS` off by one on `0x004268B0.0.life`,
`FLASH_AUX` on `0x00423D80.0.aux`, `SHOCKWAVE_RADIUS` on `0x00422B80.0.vx`.

Two readings the replay corrected on the way. `triggers.model_points_along_the_shot`
used to require every model blob of a burst to carry the *line's* triple; the
creator asks `0x00403AA0` once a round from the muzzle to the muzzle plus the
round's own scattered delta, and the streak and its case carry that — which is
why the capture's yaws are 2344 and 2379 against the line's 2350 (§46 noted the
numbers without the reason). And the spore cannon's point-blank branch was
guarded with `life <= 0 → nothing`; `lea ebp, [edx + eax - 2]` at `0x00426A8E`
and `push ebp` at `0x00426B33` have no test between them but the flag's own
`setle`, and `0x00420950` reads the life argument as a byte, so a life of −2 is
0xFE. It is transcribed that way and named as such in
`spore.point_blank_life_is_the_byte`; the capture is a far shot and settles
nothing about it, and no shot reaches the case — the span is over the two
objects and any two tiles are 3200 apart, so life is at least two.

### 51.2 Weapon 11 marks on the state byte, not the action point

[`28` §12 item 2](28-effects-and-sound.md) said the arc had never run because
`0x0046B0D8` marks a cell whose `+0x0B` action point is in 30..34 and
`_6_.sav` has none. The plan was a `--wrap`ped save with such cells. The
cheaper measurement was to write two action points into the live map through
the imported `memcpy` — the way the weapon byte already goes in — and fire.
The handler marked nothing.

The listing says why. `0x0046B0D8` steps the control map by `0x17` in `edi`
and tests `mov al, [edi] / cmp al, 0x1E / jb / cmp al, 0x22 / ja` — the
**state byte** `cell[+0x00]`, not `+0x0B`. That band on that byte is the
target overlay's hit-probability band of [`23` §6](23-ai-system.md): what
`aBuildTargetOverlay` `0x0042FF30` stamps on every enemy the unit could
engage, for the player's selection (`0x00472990`) and the computer's `fire`
alike. So the *Multi-target Destroyer* throws one grenade at every enemy the
shooter's own overlay banded within four fields of the aim, along its facing —
which is what the name says — and a shot straight after `aLoadGame`, with no
selection and no overlay, marks nothing whatever it is aimed at. The mislabel
is the one [`23` §3.6](23-ai-system.md)'s pseudocode had put on
`aGetDirectionTo` and that was corrected there on 2026-09-05
(`combat.FACING_STATE_BAND`); it had survived in the pattern handler's row of
[`22` §7.2](22-combat-and-visibility.md), in `inclib/combat.py`, in
`core/combat.gd` and in every `blob_gold` comment about weapon 11.

Three phases now stand behind it, all in `blob_gold`:

| Phase | What it does | Band before the shot | Marked | Records |
|---|---|---|---|---|
| `shot_11` | fires after the load, nothing else | (11, 9) at 32 — an own-side unit's cell, nine tiles from the aim; which pass stamped it before the save is **UNVERIFIED** | none | 0 |
| `shot_11_band` | writes 32 into `cell[+0x00]` of (8, 15) and (9, 18), reads each back | those two, plus (11, 9) | (8, 15), (9, 18) | 12 compared |
| `shot_11_overlay` | writes MP 10 and visibility 0 on the two aliens, runs `aBuildTargetOverlay` on the attacker, reads the map before and after it | (8, 18) and (7, 19) at **34** — over 90 %, stamped by the engine | (8, 18), (7, 19) | 12 compared |

Every shot plan now reads the whole control map **before** the attack as well
as after it, so `shot.band_*` reasons from the state bytes the handler had
to mark on rather than from what it left — and after the shot the marked cells
have been rewritten to the attack band, so the census could not be taken then.
`shot.band_written_*` checks the memcpy's read-back against the pre-shot map,
and `shot.overlay_*` requires the overlay to have stamped cells the load did
not carry, which the first overlay phase failed: `aBuildTargetOverlay` answered
0 because unit 0 has no MP left in this save and the routine refuses under the
weapon's AP cost, and the second answered 1 and stamped nothing because the
two aliens are hidden. Both gates are `inclib/ai.py`'s own, and the plan writes
the three bytes that pass them.

The arc is measured, on both sides: the second cell of each walk is replayed
at arc 1 and all twelve records reproduce — in `blob_gold` for the Python
twin, and in `test_blob_native.arc_shots.*` for `BlobPrograms.grenade_arc`,
whose arc-1 arm the bare `0x00426070` phase (arc 0xFF, the proximity round)
had never reached. Replaying both cells at arc 0 fails `shot.records` with 72
disagreements and `arc_shots.records` on `shot_11_band.6.x`. `SHOT_RESULTS`
carries the two rows as `[2, 2, 12, 1, 0]`.

**What changed in the models.** `inclib/combat.py`'s `_arc_sweep` reads
`states` — the overlay — instead of `world.action_point`; `mark_cells` and
`attack_unit` take it, the AI's `fire` passes its context's, and a human shot
without one has it built for the shooter the way the select does.
`core/combat.gd` does the same through `PatternContext.states`,
`World._overlay_for` builds it only for the one weapon that reads it, and
`Reaction.drain` takes a callable for the reactor's. A caller with weapon 11
and no overlay is refused rather than read as the reset value, because the
engine has no such caller — and both production paths are driven:
`test_combat.multi_target.*` puts weapon 11 through `World.submit_attack` on
a synthetic map with three aliens and gets the two near the aim marked, and
`ai_runtime.pattern.special_objects_shot_builds_its_overlay` puts it through
`attack_unit` with no `states` and gets the banded cell.
`ai_runtime.pattern.scene_*` now arranges the
family through the overlay — `_C_132`'s own alien 0 at (25, 14) bands (18, 16)
and the pattern marks it — where it used to hunt the corpus for a mission with
an action point in the band and found two cells nothing ever fired at.
`test_ai.pattern.special_objects_*` refuses without the overlay and marks the
stamped cell ahead of the shooter and not the one behind it.

### 51.3 Verification

`blob_gold --check` 327/327 (the three weapon-11 rows, `shot.records` over
every walked cell), `ai_runtime --check` 86/86, `make check-formats` green;
`test_blob_native` 30/30 with `weapon_programs.compared` at 303 and
`arc_shots.compared` at 24, `test_effects` 689, `test_ai` 75 with the two new
pattern checks, `test_combat` 272 with `multi_target.*`, and
`bash godot/run_tests.sh` at 41 suites and **5 471** checks, no leaks. Wine
took four captures to land the seven shot phases —
`shot_11_band` refused ten attempts in one run and landed on the second in the
next, and two shots that had landed faulted inside a sprite blit at
`0x00447AF2` once and landed cleanly on the retry — which is
[`91` §1](91-wine-runtime-probes.md)'s start-up again and not a property of
the plans.

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

* **Unit speech** ([`20` §7.4](20-lcl-language.md)) — 233 files, out of scope
  by the plan.
* **Ambience** — [`28` §6](28-effects-and-sound.md) proves the subsystem never
  plays anything. The ten `amb_*.wav` and four other unreferenced waves are
  excluded from the cache, and a check asserts none of them is in it.
* **`CreateBGB`** — 14 calls in the whole corpus and none in the five
  converted missions.
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
* **The creators' argument arithmetic** — still open, and **§14.5 measures
  exactly how open**: 30 of the 81 creators and 43 of the 116 constructor calls
  are reachable by firing a weapon, and 27 of those 43 carry a literal
  lifetime, which is what now paces a tracer. The rest of the paragraph stands.
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

**What is still ours** is the per-blob velocity. It is drawn from `aRandom`
*inside* the creator, so replaying one exactly needs the engine's generator
state at the moment of the shot — which is a different capture, of a whole
shot rather than of a creator call. `BlobTriggers` paces a blob by its own
recorded lifetime instead, which is extracted data rather than a chosen
constant.

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
* **Ten creators keep a residue** of fields with no named mechanism, per
  §18.3.
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

# The blob per-tick cases

`tools/blob_runtime.py` — the executable transcription of `aBlob_Update`'s
delay/life/dispatch wrapper and all 74 of its jump-table arms — run over every
one of the 78 kind values, written out as the tick-by-tick trace
`godot/tests/test_blob.gd` replays field for field.

This is the fixture the fifth slice's gate rests on. If the GDScript pool does
not reproduce this file, nothing built on top of it is worth building.

## The `.json` file is not in git

`cases_blob.json` is about 3 MiB of decoded state derived from
`Incubation.exe`, so it is excluded like every other capture;
`.gitignore` excludes `tests/fixtures/*/*.json` and this file is committed
instead.

Reproduce with:

```bash
python3 tools/blob_runtime.py --emit-cases tests/fixtures/blob/cases_blob.json \
    --root gog_incubation
```

It still *runs* with **no game root** — `blob_runtime.py` is a transcription,
not a reader, and that is exactly why it can be an oracle for a layer the
corpus cannot exercise. `--root` changes one service: the orientation helper
becomes `0x00403AA0`'s measured arithmetic and the shipped `TRIG.IMG`/`ATN.IMG`
ride along in the document so the GDScript twin reads the same numbers. Emit it
without a root and the document says `"orient": "substitute"` and
`test_blob.gd` **fails** on that field — the fallback is there so a root-free
run is consistent, not so it can pass unnoticed. `godot/run_tests.sh` copies it to `godot/generated/blob/blob.json`; a
missing fixture makes the suite **fail** rather than shrink.

## The oracle boundary is executable-Python, and deliberately not stronger

`docs/28` §12 item 1 used to record that the return data of the original's
orientation, geometry and target-map helpers — `0x004039A0`, `0x00403AA0`,
`0x0046D400`, `0x00405100`, `0x00477AE0` — had **not** been validated against a
native trace. All five have been swept now (`cases_native.json`'s `hooks`
phase), and the orientation one is the engine's arithmetic on both sides. The
rest are still a *deterministic adapter* that both sides implement, `CaseHooks` in Python and
`BlobHooks` in GDScript:

* `random(base, span)` is `ARandom`, which *is* natively pinned
  (`docs/91`, and `core/rng.gd` is its twin);
* `lookup_model(name)` is the position of the name in a fixed three-entry
  table, or −1;
* `target_position` is one fixed point, or `null`;
* `rotate`/`matrix3` are the retail `_E3D_init_matrix_RzRxRy` and
  `_E3D_c_rotate_coordinate`, and the document carries the eight
  `(vector, angles, expected)` triples the native sweep put through
  `0x004039A0` under `eng3d.rotations`; `test_blob.gd` re-runs them through
  the GDScript twin while `blob_gold.py` compares the same eight against the
  engine, so neither half stands in for the other;
* `orient` **is** the retail routine, `0x00403AA0`, when the fixture was
  emitted with a game root — measured over twenty deltas inside a live
  `Incubation.exe` and reproduced from the shipped trig tables
  (`docs/28` §7.4.2). It was the invented substitute until that sweep, and the
  substitute was wrong in the unit *and* in the pitch.

So this file checks that the 74 arms were transcribed correctly, GDScript
against Python. It is **not** a diff against the engine, and the document's
`oracle` field says so in as many words.

What has changed underneath it is that all five services are measured *and
reproduced* now (`0x004039A0` included — it is `_E3D_init_matrix_RzRxRy`,
ordinal 13 of `Eng3d.dll`), and that **all 74 arms have been stepped inside a
running `Incubation.exe`** by `cases_native.json`'s phases and reproduce its
records field for field. The document carries three lists so this suite can
name which is which:

* `native_arms` — the 24 a weapon switch's creators fill, stepped by the
  `ticks_*` and `arms_*` phases with the records those creators built;
* `poked_arms` — the other 50, stepped by the `poked_*` phases with a **donor**
  record whose `+0x44` was rewritten. The jump-table index is one byte, so no
  creator is needed to reach an arm; what that measures is the arm, and not
  the arguments a creator would have passed it. The sweep is run at **two**
  input vectors and eight further one-arm probes fill in branches a uniform
  vector cannot reach, so the agreement is not a property of one record;
* `unresolved_arms` — **empty**. The last two to leave it were the seekers
  (arms 25 and 58), which disagreed until `_seek` stopped normalising a
  direction the engine never computes (`docs/28` §7.7.1).

The claim is *transitive and per arm* — the engine agrees with the Python
there, the Python agrees with the GDScript here — and never a label on the
layer. Ten of the fifty were wrong when they were first stepped; `docs/97`
§20.1 lists them.

**And the claim now says how much of each arm it covers.** `arm_lines_covered`
and `arm_lines_total` carry the figure the capture earned — **383 of 385**
transcribed arm lines executed by the comparison itself, 73 of the 74 arms
entirely — and `test_blob.gd` checks both, so a re-emit that lost a vector
lowers the number rather than keeping the wording. The two that remain are
named in `tools/blob_gold.py`'s `COVERAGE_UNCOVERED` and are one **deliberate
divergence**: kind 41's arm divides by the record's `vx` with no test in front
of it, and the original dies where this port returns (`docs/97` §21.2).

Kind 59's six were there until `mode_59` reached them. Its branch is gated on
the **output system's** mode global rather than on the record, so the plan
writes that global in the live process, steps the arm and puts it back
(`docs/97` §23.3). It is a poked plan, so its window holds the arm's record
and not the emitter the branch asks for: what the seed either side measures
there is the **count**, seven draws against the ordinary four, and the
arguments those three draws become are pinned as bytes instead
(`blob_tables.py`'s `spawn.emitter_vz_is_ebp`).

## What one run held

936 cases, 3900 ticks: 78 kinds × 12 scenarios.

| Scenario | What it exercises |
|---|---|
| `profile` | the same non-terminal starting state `blob_runtime.py --selftest` uses, eight ticks deep, so the two agree about what a meaningful path is |
| `delayed` | `+0x55` counted down before life is even looked at |
| `expiring` | life reaching zero and the wrapper deleting rather than dispatching |
| `below_floor` | `z < 0` deleting, which is the other half of the same branch |
| `immortal` | `life == 0xFF` never decremented |
| `class_zero` | a model blob rather than a sprite, so the rotation words are rotations and `+0x54` is a counter |
| `no_target` | the three seekers with the unit map answering nothing |
| `no_model` | kinds 16 and 17 with a model lookup that fails |
| `spawn_refused` | a constructor that finds no free slot and returns −1 — `docs/28` §7.1's silent drop |
| `mirrored` | the low byte of the record pointer, which kinds 25 and 56 branch on |
| `emitter_special` | `0x00461E80`'s returned byte, which kind 59 branches on — without it both sides agree about that branch by never running it |
| `zero_velocity` | a record with no velocity at all, so an arm that only *moves* is distinguished from one that does nothing |

Each tick records the whole 24-field record plus the wrapper's eight result
flags, the spawn list with its arguments, the model lookups, and `ARandom`'s
call count and seed — so a divergence names the field and the tick, not just
the case.

The header also carries what the port has to *not* do: `arm_of_kind` (78 kinds
onto 74 arms), the four alias pairs, and the eleven unreachable kinds, which
the suite asserts are named by no creator in the port.

## `cases_native.json` — the creators, run in the engine

`docs/28` §7.6's thirty reachable creators, called inside a live
`Incubation.exe` with `_6_.sav` loaded, with the pool read back after each —
plus, since `docs/97` §18, **the arms themselves**. Twenty-three creator pools
carry a `ticks_<creator>` or `arms_<creator>` phase holding nine rounds of the
first twelve records as **raw hex** (not parsed: a blob that frees slot 3
would otherwise hide slots 4 through 11 from every later round) and the second
generator's seed beside each. `ticks_*` calls the engine's own frame sweep
`aCheckInBlobObjects`; `arms_*` calls `aBlob_Update` per record, and exists
because the sweep hands every non-sprite record to Eng3d's `0x00403CC0`, which
faults outside an open render frame.
Written by `tools/blob_gold.py --game-copy`, read by
`tools/blob_gold.py --check gog_incubation` and by
`godot/tests/test_blob_native.gd`. Gitignored, like every capture here.

Its `phases` map holds:

* `state` — the pool's memory-manager handle, `aResetBlobs`'s return value and
  the block base derived from it, every live unit's tile, and every cell's
  height. The base is a **heap address and moves between runs**, which is why
  nothing downstream uses it as an address: the plan reads the pool through
  `[0x0050DE54 + 74*handle]`, and the base is recorded only so the two
  readings can be checked against each other.
* one entry per creator, `"0xXXXXXXXX"` — the arguments it was called with,
  the records it left, and **both generators' seeds either side of the call**
  (`seed_before`/`seed_after` for `aRandom`, `seed2_*` for the uncounted
  stream at `0x00514070`).
* `raised` — the z probe: the same creator on the same tile with the control
  map's height dword **written** under it, and the cell read back so a write
  that did not land is visible rather than silently answering the question.
* `scatter` — one creator run **twice in one process** with `rand()` calls
  bracketing each, which says whether its scatter is state at all and rules
  out the C runtime as the source.
* `units` — the whole 200-slot unit array, read for one byte of each record:
  `+0x4B`, the object id a seeking arm steers at (`docs/28` §7.7.1). A
  read-only phase of its own and **not** a field added to `state`, because
  that phase also yields the pool's base, which is a heap address that moves
  between runs and whose low byte two arms branch on.
* `origins` and `symbols` — what a creator reads before it draws: the control
  map, the standard object array as the records hold it, both unit heights,
  and the two **symbol** objects the argument tiles name. The two object
  lookups are different tables and answer differently, which is why the second
  phase exists (`docs/97` §22.2).
* `hooks` — the five services of `docs/28` §12 item 1, called directly: twenty
  deltas through the orientation helper and forty through the geometry one,
  eight rotations, eighty-one object ids and every named unit slot, plus the
  five runtime function pointers read both as values and as the first bytes of
  what they point at. The three geometry helpers write only into buffers the
  plan owns and the two lookups write nothing, so all of it fits in one
  process.

  Two conventions in it. Non-finite doubles are stored as the **strings**
  `"nan"`, `"inf"` and `"-inf"`: `0x0046D400` divides by zero unguarded, and
  `json.dump`'s bare `NaN` is not JSON — Godot's parser refuses the whole
  document, which is how a suite stopped loading once. And the sweep
  deliberately **omits the invalid ids**: the out-of-range and dead-unit paths
  go through the engine's CHECK reporter, and a plan that puts a message box up
  never reaches its next line. Those branches are read statically instead;
  there is nothing in them to measure.
* `zoom_bob_*` and `spawn_*` — **what a creator is given** (`docs/97` §49).
  Every arm that asks a creator for something, stepped with `aRandom2`'s seed
  **written** before each call and the pool read forty-four records wide. The
  shape is one `entries` list per plan, each entry a pool of its own: `start`
  (the snapshot after the poke), `steps` (one per `aBlob_Update`, each with
  `pool`, `seed`, the already-parsed `born` records that appeared in it, and
  `full` when the window has no free slot left), `written` (every value a seed
  write left in the generator), and the plan's `kinds`, `seeds`, `vectors`,
  `slot` and `rounds`.

  A pool per entry rather than one per plan, because a brood can be a hundred
  records and a shared window loses every child after the first big one. Three
  creators make more than the window holds; those are compared as the prefix
  they are, with the seed after the call accounting for the rest. Two arms
  carry a seed of their own (`SPAWN_SEED_OVERRIDES`): their spawn is behind a
  roll neither sweep seed passes.
* `models` — `0x004038F0`'s handle for every model name the swap arms and the
  creators can ask for, the six the arm-called creators add included. A
  creator's record carries the handle, so a transcription that guessed one
  would be comparing an invented index against a measured one.
* `failures` — creators whose plan the harness refused, with what it said.
  They are kept **out** of `phases`, so a re-run retries them; a creator that
  faults is a result and is not the same thing as one that refuses a tile.

**What the capture holds** (2026-09-11, after the re-takes below). All thirty
creators, no plan left unlanded. **Twenty-five** produce records, **222** in
all; five refuse the tile. **Fifteen** draw from the uncounted stream, between
3 and 203 times; the rest draw nothing. Five of the twenty-five scatter rather
than placing along the line of fire. All five numbers are pinned in
`blob_gold.py`, so a thinner capture fails rather than reporting less.

It grew because three lists of "not reached on this host" emptied on
2026-09-11, Wine having started answering again: the shock wave `0x00422B80`
was re-taken with `A_EXPL05.3DI` in `CREATOR_MODELS` (60 records, and its arm
13 moved from `POKED_ARMS` to `NATIVE_ARMS`), all three `burst_*` phases
landed, and `aBlob_CreateSporeExplosion` `0x00429F40` was re-taken with the
**type** its weapon switch pushes rather than the tile coordinate the first
plan passed -- 27 records where the fall-through had left none.
`NATIVE_FAULTS`, `BURST_UNCAPTURED` and `PROGRAM_ARGS_STALE` were all empty
after that run.

**2026-09-12: two of the three filled again, and that is a measurement too.**
Every arm of both weapon switches was disassembled and its pushes read, which
corrected the tail of **eight** more creators in `SWITCH_ARGS` -- the muzzle
dispatcher sets `edi` to 0 and `ebx` to 1 four instructions before its jump,
so an arm pushing either past the four coordinates is pushing a literal and
not a tile number. `capture` asked for all eight again and Wine reached the
anchor **0 times in 80 attempts**, which `NATIVE_FAULTS` records: that list is
about which plans landed and nine of them did not.

**Six of the eight turned out not to need the re-take at all.** A corrected
tail is only worth a phase if the callee *reads* it, and for six of them the
slot `argument_vector` had been filling is one the body never loads --
`0x004228F0` and `0x00429C30` read `[esp+4]` and `[esp+8]` and nothing else,
`0x00425CA0`, `0x00428200` and `0x00428570` read their fifth argument nowhere,
and `0x00426070`'s type is its **sixth**. So the phases already in hand are
the engine's answer to the call those arms make, and four of the six replay
field for field today; the fire wheel and `0x00429C30` are diffed straight
against the capture's records, and the two lasers were -- the seven-dot one
after its per-dot direction was corrected, which the diff caught.
`PROGRAM_ARGS_STALE` is down to `0x00425400` and `0x00427C80`, the two whose
tail is genuinely live (a round count and a ring count), and which had no
records in the capture at all.

The `models` phase is short as well: `A_EXPL03.3DI`, `A_LASER.3DI`,
`A_MINE1.3DI` and `A_MINE2.3DI` joined `CREATOR_MODELS` and its re-take lost
its ten attempts too, which `MODEL_NAMES_UNCAPTURED` and
`PROGRAM_MODELS_UNCAPTURED` name -- the last of which now holds `0x00425CA0`
and `0x00426070`, whose transcription is complete and whose only obstacle is a
model handle. `PROGRAM_DIVERGENT` is a fifth pin and a different kind:
`0x00427C80`'s first ring reads uninitialised stack, so its transcription is
knowingly not the creator there. Re-run with Wine and all of it but that one
empties; nothing else has to change.

**2026-09-12, the same afternoon: every one of those five pins is empty.**
`--probe-startup 3` answered 0 of 3 a few hours after the 0-of-80 above, on
the same host with nothing changed but the hour, and the capture was started
anyway because the unit of loss is the plan. `blob_models` reached the anchor
on attempt 1 and the eight creators landed in one to six tries each, one of
them needing a second invocation. `NATIVE_FAULTS`, `PROGRAM_ARGS_STALE`,
`PROGRAM_MODELS_UNCAPTURED`, `MODEL_NAMES_UNCAPTURED` and `PROGRAM_DIVERGENT`
are all empty and all five stay in the file: a thinner capture has to put a
name back rather than quietly compare less.

Two things came out of it that reading could not have.

*The diff found a transcription error, in the creator that had been written
with a divergence.* `0x00427C80` matched the engine in every field but `aux`,
and in eleven of its twelve records — the sprite's half-size is biased by a
**byte counter that opens at two and steps once per record** (`0x00427F25`,
`0x00428181`), not by the ring index over three. A shape that fits one sample
and no more.

*And the divergence itself came back zero.* Ring 0's three uninitialised
doubles held zero in the anchor's frame, so the stand-in matched — which is a
measurement of `dbgcall`'s stack and not of the shipped path's, because a shot
calls the creator from `aPlayFightAnimation` and the slots hold whatever that
caller left.

**The `fight_` phases settle that, and they are new here.** Each one fires a
real shot: `aAttackUnit(19, 6, 18, 4, 0)` builds the target pattern, resolves
it and calls `aPlayFightAnimation`, so the creator runs from its shipped call
site with the animation's own frame underneath. Two pokes make the run
readable — the muzzle switch's weapon read at `0x0040CC38` rewritten to `push
imm8 / pop eax / nop`, and `aBlobsTick` `0x0041E3D0` stubbed to `ret`, without
which the pool is empty by the time the call returns. Weapon 7's twelve
records reproduce field for field, **ring 0's five included**, so the three
doubles are zero on the shipped path too; weapon 11 and weapon 41 go through
§8.1.3's walking arms, and weapon 41 at the **nine** rounds its own arm pushes
rather than the ten `burst_0x004247C0` was taken with. These
phases poke the muzzle switch only, so the band their walking arms read was
marked for the attacker's *own* weapon.

**The `shot_` phases are the ones that fire properly.** They write the weapon
into `unit[+0x3F]` instead, so the pattern family, the range test, both
switches and the sound are all the fired weapon's; they read forty-four
records rather than twelve, so a muzzle creator's whole output is compared;
and they read the control map afterwards, so the cells a walking arm was
handed are measured. Weapon 9's band holds **two** cells and its arm makes two
calls, one per cell — the walk, in the engine — and each record's `aux` is the
occupant the arm read, which the post-shot map has already cleared. Weapon
44's thirty records all carry the same `aux`: five rounds at one aim point,
not a walk. Weapon 7 reproduces all twenty records on **both** branches of
`0x0040CBE2`, so ring 0's three doubles are zero whether or not the
sound-buffer chain has run underneath. Weapon 11 marks nothing on this map —
its handler wants an action point in 30..34 and the map carries none — so its
arc stays unexercised, and the histogram that says why is in the phase.

**`symbols` answers for the whole map now, not for two tiles.** A walking arm
aims at a cell the argument tiles never named, and a plan cannot ask
`aGetSymbolObjectPtr` about a cell nobody knows until after the shot — so the
phase reads the array that service indexes, `[0x004FA820] + id * 70`, bounded
by `[0x004FA7B0]`, all four hundred records in one go. Every cell therefore
has a *measured* object instead of the tile-times-3200 rule that stood in for
it. The two ids the service is still called for are kept beside the array
rather than folded into it — folding them in is what made an earlier version
of that comparison check a value against a copy of itself — so
`symbols.table_is_the_service's` can compare them; the read width must come to
`[0x004FA7B0]`, the highest id the service accepts; and the base, the stride
and the bound are decoded from the service's own instructions by
`blob_tables`' `weapon.symbol_object_service`.

Six tick phases were also re-taken: their stored arguments predated
`SWITCH_ARGS`, so they answered a call the tools no longer make. Two came
back identical and four changed — most consequentially `arms_0x00426070`,
which had been stepping the grenade's kind-26 arm while its creator phase held
kind 27.

A third pin moved without a phase: `NATIVE_FAULTS` had been reporting `models`
as unlanded while that plan's answer sat in the same document. Five additive
phases recorded a failure and never cleared it on the next success; all five
now pop their name in `capture`.

**A creator with no records is a result, not a gap.** Every one of them opens
by looking up the cell it was given and its occupant, and refuses through the
trace macro when there is nothing there. Which creators refuse on which tile
is part of what the capture measures.

**One creator per plan.** With five, the capture came back holding creators
1–5, 11–15 and 21–25 — three whole groups present and three whole groups
empty, reproduced across three invocations of ten attempts each. That looked
like a faulting creator taking its process down with it, and it is not: with
one creator per plan a plan still fails occasionally, and the log says
`exception 0xc0000005 at 0x7bf2123d` inside a Wine system DLL **before the
anchor** — before any line of the plan has run. That is `docs/91` §1's
start-up intermittency, and why the groups aligned the way they did stays
unexplained. One per plan is right either way: a plan that dies takes down
every creator sharing its process, so five per plan turns one bad start into
a fifth of the capture.

**The velocities are not `aRandom`'s, and they are not unreplayable.** An
earlier version of this file said both. `aRandom`'s seed is read either side
of every creator and **never moves**, and no creator's closure contains a call
to it. The generator they draw from is a second entry point at `0x004638E0` —
`aRandom` byte for byte over the seed at `0x00514070`, without the call
counters, and seeded from `GetTickCount()` where `aRandom` is seeded to 1.0.
That is why a shot does the same damage every run and does not look the same.
With the second seed read either side, the draw count is exact: most creators
take **none** on the captured tile and are reproducible from this file alone;
`0x004228F0` takes ninety, and what is reproducible there is the count and the
sequence, given the seed. `docs/28` §7.6.1 and `docs/22` §3.2 carry it.

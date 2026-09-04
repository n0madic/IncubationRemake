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

**What one capture held.** All thirty creators, no plan left unlanded: one
pass took twenty-five and lost five to Wine, a merge pass took the five.
Twenty-three produced records, 198 in all; seven refused the tile. Fourteen
drew from the uncounted stream, between 3 and 203 times; sixteen drew nothing.
Four of the twenty-three scatter rather than placing along the line of fire.
All five numbers are pinned in `blob_gold.py`, so a thinner capture fails
rather than reporting less.

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

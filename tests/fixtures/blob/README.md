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
python3 tools/blob_runtime.py --emit-cases tests/fixtures/blob/cases_blob.json
```

It needs **no game root** — `blob_runtime.py` is a transcription, not a reader,
and that is exactly why it can be an oracle for a layer the corpus cannot
exercise. `godot/run_tests.sh` copies it to `godot/generated/blob/blob.json`; a
missing fixture makes the suite **fail** rather than shrink.

## The oracle boundary is executable-Python, and deliberately not stronger

`docs/28` §12 item 1 records that the return data of the original's
orientation, geometry and target-map helpers — `0x004039A0`, `0x00403AA0`,
`0x0046D400`, `0x00405100`, `0x00477AE0` — has **not** been validated against a
native trace. Every arm that calls one of them is therefore compared against a
*deterministic adapter* that both sides implement, `CaseHooks` in Python and
`BlobHooks` in GDScript:

* `random(base, span)` is `ARandom`, which *is* natively pinned
  (`docs/91`, and `core/rng.gd` is its twin);
* `lookup_model(name)` is the position of the name in a fixed three-entry
  table, or −1;
* `target_position` is one fixed point, or `null`;
* `orient` is the portable fixed-point helper in `blob_runtime.BlobHooks`,
  **not** the retail routine.

So this file checks that the 74 arms were transcribed correctly. It does not
check that a particle follows the trajectory the original's particle followed.
The document's own `oracle` field says so in as many words, and the suite
prints the boundary rather than letting a reader assume the stronger one.

## What one run held

780 cases, 3276 ticks: 78 kinds × 10 scenarios.

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

Each tick records the whole 24-field record plus the wrapper's eight result
flags, the spawn list with its arguments, the model lookups, and `ARandom`'s
call count and seed — so a divergence names the field and the tick, not just
the case.

The header also carries what the port has to *not* do: `arm_of_kind` (78 kinds
onto 74 arms), the four alias pairs, and the eleven unreachable kinds, which
the suite asserts are named by no creator in the port.

## `cases_native.json` — the creators, run in the engine

`docs/28` §7.6's thirty reachable creators, called inside a live
`Incubation.exe` with `_6_.sav` loaded, with the pool read back after each.
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

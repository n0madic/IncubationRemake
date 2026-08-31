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
  the block base derived from it, and every live unit's tile. The base is a
  **heap address and moves between runs**, which is why nothing downstream uses
  it as an address: the plan reads the pool through
  `[0x0050DE54 + 74*handle]`, and the base is recorded only so the two readings
  can be checked against each other.
* one entry per creator, `"0xXXXXXXXX"` — the arguments it was called with, and
  the records it left in the pool.

**A creator with no records is a result, not a gap.** Every one of them opens
by looking up the cell it was given and its occupant, and refuses through the
trace macro when there is nothing there. Which creators refuse on which tile is
part of what the capture measures.

**Velocities are drawn from `aRandom` and are not replayed exactly.** What is
replayed is what is deterministic: the placement (`tile * 3200` world units),
the per-creator `z`, the record count, and the class, kind and lifetime of each
record — the last three being the same fields `blob_tables.py` reads out of the
compiler's tables statically, which is the cross-validation this capture exists
for.

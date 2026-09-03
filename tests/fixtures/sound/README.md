# The sound-layer cases

`tools/inclib/sound.py` run over the shipped tables, written out as the trace
`godot/tests/test_sound.gd` replays. This is the twin of the arrangement
`tests/fixtures/charisma/` uses: a Python model that `--check` has already
verified against the binary, and a GDScript implementation that has to produce
the same answers from the same inputs.

## The `.json` file is not in git

`cases_sound.json` embeds the shipped `SetVolumeCtrl` table, the wave names of
all 62 call sites and every weapon's own wave name, so it is derived from Blue
Byte's data for the same reason `tools/out/` is. `.gitignore` excludes
`tests/fixtures/*/*.json`; this file is committed instead.

Reproduce with:

```bash
python3 tools/blob_tables.py --emit-sound-cases \
    tests/fixtures/sound/cases_sound.json --root gog_incubation
```

`godot/run_tests.sh` copies it to `godot/generated/sound/sound.json`, which the
suite reads. A missing fixture makes the suite **fail** rather than shrink.

## The oracle boundary is executable-Python, and only that

Every expectation in the file is produced by `tools/inclib/sound.py`.
`blob_tables.py --check` compares that module against the binary — the 20-slot
pool bound, the four attenuation constants, the 103 `SetVolumeCtrl` ids, all 62
call sites and their partition into events, the nine looping play sites, the
eight footstep arms, the two voice cursors and the weapon-id-is-volume-id
rule — so the model is anchored. Nothing here is a native runtime trace, and
the document's own `oracle` field says so.

## What one run held

| Section | Cases | What it pins |
|---|---|---|
| `attenuation` | 182 | `docs/28` §1.3's formula over 26 base volumes × 7 percentages, including the silence gate either side of −2000 and the clip at 0 |
| `scaled` | 416 | every one of the 103 defined ids plus `-1`, at four base volumes |
| `pool` | 28 | 23 loads into 20 slots — three dropped — three kills, `kill_looping` and the live count |
| `voices` | 16 | both cursors interleaved, `SP_HUM_*` sharing the human one, species 2 silent; each call carries the **`type_id`** it was made with, two of them muted (`docs/42` §4.5), one on a `death` of species 3 so the machine's explosion is gated too |
| `footsteps` | 138 | all 69 unit types, `Faithful` and corrected — 39 silent, type 24's id 45 against 91 |
| `weapons` | 84 | all 42 `SetWeaponInfo2` rows, `Faithful` and corrected; weapon 35 resolves to nothing in the first |
| `catalogue` | 40 events | the 59 non-computed call sites, each with its wave, volume id and loop flag |
| `case_map` | 81 | the lower-cased name the cache file carries → the shipped name |
| `playlists` | 7 | `CDTrackProgram`'s five shipped programs plus a malformed one and an empty one |

The three computed sites — the weapon's own fire sound, the pain voice and the
footstep — are deliberately **absent** from `catalogue`: they have their own
sections, because the original builds their name or their volume id at run time
and a table entry for them would be a fiction.

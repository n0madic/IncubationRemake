# Campaign-layer cases

The oracle is **executable Python**, not the engine
([`docs/92`](../92-remake-architecture.md) §5 rank 2):
[`tools/inclib/campaign.py`](../../tools/inclib/campaign.py) is the model of
[`docs/27`](../27-campaign.md) and `godot/core/campaign/` is its
GDScript twin, so `godot/tests/test_campaign.gd` compares two implementations
of one specification and prints `executable-Python`.

What is stronger than that lives elsewhere and is what the model was built
against:

* `python3 tools/campaign_runtime.py --check gog_incubation` diffs the model's
  rule constants against the immediates
  [`tools/campaign_tables.py`](../../tools/campaign_tables.py) reads out of
  `Incubation.exe`, the recruit price against `Info.lcl`, and the location
  graph against the cells of `_C_XXX` / `_C_YYY`.
* `python3 tools/campaign_runtime.py --check-saves tests/fixtures/saves` diffs
  it against the six real saves — 88 checks, and the ones that matter are the
  two pool rows (§2.2 of the slice-6 plan) and the campaign economy.

Regenerate with:

```bash
python3 tools/campaign_runtime.py --emit-cases \
    tests/fixtures/campaign/cases_campaign.json --root gog_incubation
```

`run_tests.sh` copies it to `godot/generated/campaign/campaign.json`, which the
suite looks at **before** `user://campaign/`; a missing file makes the suite
report the gap rather than the run silently shrinking.

| Key | What it pins |
| --- | --- |
| `seed` | the two campaigns' opening state — campaign 1's Bratt/West/Maxon and campaign 2's empty pool, with `EP = 100`, `tech = 1`, `skill = 0` for player 0 alone (`0x0043AE76`) |
| `squad_fields` | the sixteen field writes of [`docs/27`](../27-campaign.md) §3.1, straight out of `0x0047883B`..`0x004788A5` |
| `scores` | 45 cases: five mission results by three difficulties by three kill/loss shapes |
| `payouts` | the slot 10/11 hand-out, gated on campaign mode **and** on the result not being defeat |
| `sorts` | `0x00478630`'s bubble sort, including the case that makes it more than `sorted()`: a free slot is a wall, because the pass skips any pair either side of which has zero HP |
| `economy` | start, recruit, dismiss and the 10000 cap — a recruit costs 60 and dismissing one refunds 60, which is the `+50` markup appearing in both formulas |
| `banks` | the five states of the two rows: row 0 live, row 1 the mission-entry snapshot, and the snapshot gone by the time the map screen is drawn |
| `survival` | `+0x4D` and the full-pool refusal, both of which are silent in the engine and named here ([`docs/92`](../92-remake-architecture.md) §7.4) |
| `tables` | the location graph as lists of records with integer ids (D12) |
| `chain` / `mission_ids` / `script_overrides` | every header's next map, every mission id, and all 74 `EnterNameOfNextMap` arguments |
| `deployment_cells` | `action_point == 1` on all 75 campaign missions — 73 carry them, and the two that do not are `_C_131`, which places its own squad, and `_C_180`, the epilogue |

The file is gitignored (`tests/fixtures/`); this page is not.

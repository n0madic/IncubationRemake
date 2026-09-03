# Slice 6 — the campaign

*2026-09-04.*

## 0. What was there, and what this slice did

Five slices had built the rules ([`93`](93-slice-1-report.md) the map and the
path, [`94`](94-slice-2-report.md) the turn, combat and the mission script,
[`95`](95-slice-3-report.md) the AI), the bodies ([`96`](96-slice-4-report.md))
and the world that answers back ([`97`](97-slice-5-report.md)). There was no
campaign. [`92` §9](92-remake-architecture.md) said so plainly — "`_C_115`
cannot be played even though it converts and draws" — and
[`94` §9](94-slice-2-report.md) named the reason: the squad comes from a roster
that did not exist.

Measured on the corpus before starting: of the 75 shipped campaign missions,
**only 31 place a player-0 squad of their own**. The other 44 do not start at
all without deployment. So the campaign is not a wrapper around a game that
already works; it is the thing that makes three fifths of the shipped content
reachable.

What this slice delivers: both campaign chains, the location map, the two
roster banks, deployment onto the action-point cells, the mission end with its
score and payouts, the chain to the next mission, the economy, six screens on
the shipped art, and a quick save that survives a change of mission.

Five findings came out of it, and three of them correct documents that were
already delivered. They are §2 through §6.

| | |
|---|---|
| New tools | `tools/inclib/bmp.py`, `tools/inclib/campaign.py`, `tools/campaign_runtime.py` |
| New cache categories | `tables/campaign.json`, `text/briefing/*.json`, `art/`, `ui/` |
| New `core` | `core/campaign/` — `campaign_state`, `roster`, `score_record`, `campaign_map`, `mission_end`, `campaign_codec` |
| New `game` | `campaign_host`, `art`, `briefing_text`, `screens/` (six) |
| Checks | `campaign_runtime --check` **481**, `remake_convert --check-campaign` **37**, `campaign_tables --check` 237 → **253**, `remake_convert --check` 190 → **220**, suites 33 → **34**, 2778 → **3133** |
| `CONVERTER_VERSION` | 0.15.0 → 0.16.0 |
| `SaveCodec.SCHEMA_VERSION` | 8 → 9 |

---

## 1. Oracle boundaries

| Layer | Oracle | Rank ([`92` §5](92-remake-architecture.md)) |
|---|---|---|
| the rule constants — pool stride, slots, the resale markup, the base scores, the hero type and flag, the seed's sixteen field writes | the immediates `campaign_tables.py` reads out of `Incubation.exe` | **verified-static**, two readings sharing no code |
| the recruit price | `Info.lcl`'s weapon 0, cross-checked against `0x0045B821`'s `+ 50` | verified-static |
| the location graph and the chain | the cells of `_C_XXX`/`_C_YYY`, every header's next-map field, all 74 `EnterNameOfNextMap` arguments | verified-static, 100 % of the corpus |
| the two pool rows, the campaign economy, the scoreboard's pairs | **six real saves** the retail game wrote | the strongest available; there is no `dbgcall` capture of this layer |
| `core/campaign/` against `inclib/campaign.py` | the fixture `campaign_runtime.py --emit-cases` writes | **executable-Python**, and `test_campaign.gd` prints exactly that |

There is no native capture of the campaign layer and this report does not
pretend otherwise. `campaign_gold.py` is named in [`27` §10](27-campaign.md)'s
successor list as the next step, not this one's: the layer is pinned statically
at 253 checks and confirmed by six saves the game itself produced, which is
rank 3 evidence, and the routines a capture would call
(`aCreateUnitPoolForCampaign`, `aEnlargeUnitPool`, `aCopyUnitPool`,
`0x00478630`, `0x0043BA10`) touch no engine global a static reading cannot
already see.

---

## 2. Finding — `aInitGameControl` has two arms, and the campaign's is a different one

[`27` §4](27-campaign.md) quoted a block that reads a mission header and writes
the equipment points, the tech level and the skill level. That block is real,
and a campaign never runs it.

`0x0043AD20` opens by asking `gameMode()` and branching:

```asm
0x0043AD27  call 0x0043B740            ; gameMode()
0x0043AD2C  cmp  eax, 1
0x0043AD2F  je   0x0043AE76            ; the campaign's own arm
0x0043AD35  jbe  0x0043AE52            ; error, aGameControl.cpp
0x0043AD3B  cmp  eax, 4
0x0043AD3E  ja   0x0043AE52
            ; modes 2..4 -- net, local and pbm sessions -- fall through here
```

The fall-through is the arm [`27`](27-campaign.md) described: player count 4,
`EP = 2000` each, tech 4, skill 6, three commendations apiece. The campaign's
arm at `0x0043AE76` is:

```c
playerCount = 1;                             /* 0x0043AE76 */
for (p = 0; p < playerCount; p++) {          /* so p = 0 only */
    equipmentPoints[p] = 100;                /* 0x0043AE96 */
    techLevel          = 1;                  /* 0x0043AEBB */
    commendations[p]   = 0;                  /* 0x0043AEC2 */
    resetScoreboard(p);                      /* 0x0043AECF */
}
skillLevel = 0;                              /* 0x0043AF06 */
switch (campaignNumber()) {                  /* 0x0043AF1F */
  case 1: strcpy(GameControl.mapName, "_C_100"); break;   /* 0x0043AF57 */
  case 2: strcpy(GameControl.mapName, "_C_140"); break;   /* 0x0043AF2A */
  default: error("...");
}
```

Three things follow.

**There are two clean starts, not one.** [`27` §6.6](27-campaign.md) read a
single save — `_0_.sav`, which names `_C_140` — as evidence that a new game
begins in the second chain. The save shows that *that session* chose campaign
2. The switch above shows both starts exist and the campaign number picks
between them, which is why D1 makes it the first field of the campaign's state.

**The loop bound is the player count, and the player count is 1.** The plan
for this slice derived `EP = (100, 2000, 2000, 2000)` and `com = [3, 3, 3, 3]`
from real saves and attributed the 2000s to the campaign overwriting slot 0 of
a four-player default. That is the right observation with the wrong mechanism:
the campaign writes **player 0 alone** and never touches slots 1..3, and
`_0_.sav` — the one taken on a session that went straight into the campaign —
reads `EP = [100, 0, 0, 0]`, `com = [0, 0, 0, 0]`. The 2000s in the other five
are the multiplayer arm's leftovers from earlier in the same process.

**Campaign 2 has no seed and does not need one.**
`aCreateUnitPoolForCampaign(2)` is a bare `return TRUE`
([`27` §3.1](27-campaign.md)), so the pool it starts with is empty. Its opening
squad is the four units `_C_140.lev` places itself — Sgt. Bratt with
`+0x4D = 2` and Rock, Austin and Knox with `+0x4D = 1` — which reach the roster
at that mission's debriefing. Driven, this is exactly what happens: `campaign 2`
opens with a roster of zero and the debriefing recovers four.

---

## 3. Correction — the tech level is the campaign's, and it does not grow

[`27` §5.2](27-campaign.md) said "`0x00509F04` holds **the mission's** tech
level, from the header's `+0x21E`", and the slice plan carried an open question
about how the level rises over forty missions.

It does not rise. The whole image holds **four** instruction-level references
to the global:

| Address | What it does |
|---|---|
| `0x0043ADAB` | the multiplayer init arm's `mov byte [0x509F04], 4` |
| `0x0043AEBD` | the campaign init arm's `mov byte [0x509F04], 1` |
| `0x0043AF95` | `setTechLevel`'s own store |
| `0x0043AFA1` | `getTechLevel`'s own load |

`setTechLevel` has five call sites and all five are in `aMenuSystem.cpp`
functions — `0x0044D740`, `0x0044DCD0` (twice), `0x0044FCE0` and `0x0044FDF0`
— and three of them feed it `0x00419B70`, the mission header's `+0x21E`. Not
one is in `aMissionControl.cpp` or `aBattleMap.cpp`. That is the
single-mission and multiplayer front end, which is what the header's economy
fields are for: ten campaign `.lev` carry non-zero values (`_C_100`, `_C_101`,
`_C_143`, `_C_145`…`_C_150`, `_C_168`) and the other 67 carry zeros.

The decisive check is empirical rather than structural: **`_C_141`'s header
says `tech = 0`, and the three fixture saves taken inside `_C_141` say
`tech = 1`.** A mission entry that applied the header would read 0.

So the tech level is 1 for the whole of a campaign, and the purchase catalogue
at tech 1 is the whole of a campaign's catalogue. `campaign_tables.py` pins the
four references, the two init-arm immediates and the five setter sites, so a
change to any of them fails a check rather than passing quietly.

### 3.1 And the pair at `0x00510A34` is not what §5.2 guessed

The same section marked **UNVERIFIED** which of `0x00510A34`/`0x00510A35` is
the skill limit and which the tech limit. Neither. They are the two ends of one
range:

```c
/* 0x0045BF44 */  byte [0x00510A34] = 0;                 /* the low limit  */
/* 0x0045BF4B */  byte [0x00510A35] = getTechLevel();    /* the high limit */
```

`0x0045AF21` reads them as a single word — `al` low, `ah` high — and hands both
to the catalogue builders `0x0047A090` (equipment, 42-byte stride) and
`0x0047A1B0` (weapons). Each walks its table backwards, skips a record whose
name is empty, and accepts one whose requirement byte satisfies
`low <= b <= high`.

At tech 1 that is **14 of 42 weapons and 7 of 19 items** — the numbers
`test_game_ui.gd` now pins. It also admits the ten alien weapons, whose
requirement is 0 and whose names are not empty, priced at zero; nothing in
either builder excludes them, so the Upgrade screen shows them. That is the
shipped filter, and it is shown rather than quietly corrected
([`92` §7.1](92-remake-architecture.md)).

---

## 4. Correction — row 0 is the live roster and row 1 the entry snapshot

[`27` §3.5](27-campaign.md) named the two pool rows from the two
`aCopyUnitPool` call sites alone: "row 0 the between-missions bank, row 1 the
mission's working copy". The first half is right. The second is backwards, and
four fixture saves settle it:

| Save | Moment | Row 0 | Row 1 |
|---|---|---|---|
| `_5_.sav` | the campaign map | Sgt. Bratt | — |
| `_31_.sav` | the entry snapshot for `_C_141` ([`11` §4](11-save-game-format.md)) | Sgt. Bratt | Sgt. Bratt |
| `_6_.sav`, `_33_.sav` | inside `_C_141` | **empty** | Sgt. Bratt |

The deciding row is the negative one. Inside a mission row 0 is *empty*,
because `aTransferUnitFromPoolToMap` removes each record from it as it places
the unit, and row 1 still holds the squad. The mission's working copy is the
**map**. So:

* `aCopyUnitPool(0, 1)` at `0x0045A914` is a **snapshot** taken on entry;
* deployment draws from row **0**;
* survivors return to row **0** at the debriefing;
* `aCopyUnitPool(1, 0)` at `0x0045E9D9` restores the **pre-mission** roster,
  which makes that button a **replay** and not a step forward.

[`11` §5.7](11-save-game-format.md)'s own phrase, "mission-entry snapshot", was
the correct reading all along; both documents now agree.

One detail does not follow from the saves and changes where a button lives.
`_5_.sav` is on the map screen with row 1 **empty**, though neither debriefing
button clears it. What clears it is not traced. The consequence is unambiguous
even so: the snapshot does not outlive the debriefing, so *replay* belongs to
the debriefing screen — which is exactly where `0x0045E9CB` physically puts it.

---

## 5. Finding — the scoreboard has no unknown fields

[`11` §5.5](11-save-game-format.md) left `+0x04`, `+0x0C`, `+0x14` and `+0x24`
uninterpreted, and the slice plan proposed carrying them forward unnamed. All
four are named now, and the structure is the point: the record is **four
pairs**, each "this mission" beside "the campaign".

The debriefing reads it in two passes — `0x0045DF24`…`0x0045DF4B` take
`+0x1C/+0x14/+0x0C/+0x04`, `0x0045E3D0`…`0x0045E3FA` take
`+0x18/+0x10/+0x08/+0x00` — and `Txtmod_d` 30 and 31 are the two column
headings it prints them under: **"In Mission"** and **"In Campaign"**. The
shipped text confirms the shape independently of the listing.

| Pair | Mission | Campaign | Written by |
|---|---|---|---|
| kills | `+0x00` | `+0x04` | `0x0043B810`, the **shooter's** record, on a kill whose players differ |
| units lost | `+0x08` | `+0x0C` | `0x0043B8D0`, the **victim's**, from all eleven death paths |
| lost to an enemy | `+0x10` | `+0x14` | `0x0043B860`, the victim's, beside `0x0043B810` |
| score | `+0x18` | `+0x1C` | the scorer `0x0043BA10` |
| heroes lost | `+0x24` | — | `aRemoveUnitElement` `0x00477A4E`; `HeroKilled` `0x004409E0` reads it |

Two things made these hard to find. The seventeen callers of the record
accessor `0x0043BA00` are **all reads** bar `aRemoveUnitElement`'s — the three
incrementers address the array directly, so a sweep of the accessor finds
nothing. And `+0x08` is the half the scorer doubles, not `+0x10`: a
friendly-fire death and a set-piece death cost a player exactly what an enemy
kill does.

`0x0043B8D0`'s eleven callers are every death path in the game: the six
set-piece killers (`aPlayRotateStatueSequence` twice, `aPlayLaserBarrier`,
`aPlayStatueSequence`, `aPlayFootBridgeSequence` twice), `aAttackUnit`,
`aCheckWeaponDamage`, `aExecuteTeleporter` and `aExecuteBomb`.

All six fixture saves agree field for field: 25 kills, three units lost, all
three of them to an enemy, 119 points over the campaign.

**One divergence, declared.** `0x0043B810` carries no player bound where its two
siblings do, so an alien killer — player 255 — makes the engine write
`40 * 255` bytes past the array. That is an out-of-bounds write rather than a
rule, and the remake bounds it.

### 5.1 What this changed in the remake

The host had been summing survivors at the debriefing, which loses every kill
made by a unit that later died. `TurnState` now carries the three per-mission
counters and `core` increments them where the engine does — `UnitState.remove`
is `aRemoveUnitElement`, which all eleven death paths reach, and `Combat`'s
kill site is `0x0046BF84`. They are in the save (`SaveCodec` 8 → 9) and
**outside** the canonical hash, which is what keeps D7.

### 5.2 And it closed a reconciliation the plan asked for

The plan recorded that the fixtures showed `result = 1` with `score = -100` for
all four players, which §6.2 cannot produce, and asked which of the two
readings was wrong. Neither: the exploratory read used a bad offset. At the
measured offsets all six saves carry `result = 1` and `score = 0`, and there is
no `-100` anywhere. The jump table at `0x0043BBB8` confirms
[`27` §6.2](27-campaign.md)'s base scores unchanged.

---

## 6. Finding — the BMP corpus is not uniform where it matters

The plan expected all 118 shipped `.bmp` to put their pixels at `+1078`. They
do not: `biClrUsed` runs from 0 (a full 256-entry table) down to 17, so
`bfOffBits` ranges 122…1078 and **44 of the 118** would have been misread.
`inclib/bmp.py` reads the file header's own field. Everything else is uniform:
`BM`, a 40-byte `BITMAPINFOHEADER`, 8 bpp, `BI_RGB`, one plane, bottom-up.

Two libraries had no palette, and the answer was measured rather than eyeballed.
`AddOns.Lib` and `AddOns2.Lib` have no `.pal` because the screen that draws them
has already set one: `aInitGUI` loads `GUI\plate_1.bmp` at `0x0044B290` and the
library at `0x0044B2C4`, and the debriefing does the same 0x38 bytes apart at
`0x0045D492` and `0x0045D4C9`. A BMP carries its own 256-entry table, so the
plate's is theirs. `uicons2.LIB` has none because it has **no reader**: the
string appears nowhere in `Incubation.exe`, `iDesigner.exe` or `Eng3d.dll`, in
no format string that could build it, and in no shipped `.lcl`. It is recorded
as unreferenced rather than given an invented palette.

---

## 7. Measurements

| | |
|---|---|
| Campaign missions with a placed player-0 squad | **31 of 75** |
| Campaign missions with `action_point == 1` cells | **73 of 75** — the exceptions are `_C_131`, which places its own squad, and `_C_180`, the epilogue |
| Deployment cells per mission | 1…10, median 6 — never more than the header's ten-record ring |
| Full campaign bake | **92 maps** (75 missions + 2 campaign maps + 15 upgrade screens), 31 scenes, 9 world sets, **25.9 s**, **85.9 MiB**, 826 files |
| Six-mission slice bake | 4 s, 41.9 MiB with music, 15.2 MiB without |
| Catalogue at tech 1 | 14 of 42 weapons, 7 of 19 items (at tech 0: 12 and 2) |
| Interface art | 7 plates, 96 briefing pictures, 21 interface libraries (410 sprites) and 33 item libraries (990) |
| Briefings | 116, of which **116** carry all three of `A0`/`B0`/`C0` |

The bake number is what decided D9. `remake_convert --check` runs **three**
full conversions; at fifteen times the slice that is a minute and a half of
always-run work for a question — "does the whole campaign convert" — that one
conversion answers. `--check-campaign` is that one conversion, 37 checks.

The two cache ceilings moved 37 → 42 MiB and 13 → 17 MiB, and the growth has a
name: the interface art is a **one-off** ~8 MiB step and not a slope, because
the location graph, the briefings and the sprites are the same whichever
missions were asked for.

---

## 8. Divergences

| # | What the original does | What this does | Why |
|---|---|---|---|
| 1 | draws a recruit's voice from `0x004638E0`, seeded from `GetTickCount` ([`28` §3.2](28-effects-and-sound.md)) | draws from a deterministic stream of the campaign's own | a save has to reproduce (D8) |
| 2 | drops a survivor that is not a pool candidate, and one the full roster cannot hold, in silence | names both on the debriefing screen | [`92` §7.4](92-remake-architecture.md), extended to deployment's four refusals as well |
| 3 | `0x0043B810` writes past the scoreboard array for an alien killer | bounds the write | an out-of-bounds write is not a rule (§5) |
| 4 | wraps briefing text with `aCreateGUITextBox`'s measuring loop for a 1997 box | wraps with Godot's, for this box | `inclib/brieftext.layout` reproduces the original exactly and is checked against the corpus; copying its wrap positions into a different box width would be wrong rather than faithful |
| 5 | loses the pool's 30th slot of row 1 to the save's flat 5460-byte write ([`11` §5.7](11-save-game-format.md)) | does not | the remake's save is its own format ([`92` §7.3](92-remake-architecture.md)); stated explicitly so it is not read as a defect kept under §7.1 |
| 6 | caches the resale value in `+0x5A` | derives it | the engine rewrites the cache at every point that could invalidate it, so it is never independently true; storing it would put a derived number into the canonical hash, and `map.json` carries no column to load it from |

---

## 9. Verification

| Criterion | Result |
|---|---|
| 1. New campaign in both chains | **met** — `campaign 1` seeds Bratt/West/Maxon at `_C_100`; `campaign 2` opens at `_C_140` with an empty pool and one open location, 90 |
| 2. Campaign map, the right locations open, clicks route by kind | **met** — drawn on `_C_XXX`/`_C_YYY` through the existing renderer; `unlock_graph[1] = [1, 10, 51]` and `unlock_graph[40] = [90]` |
| 3. Deployment; `_C_141` and `_C_115` played | **met** — four deployed onto `_C_141`'s six cells and three onto `_C_115`'s, both reaching turn 1 with the mission script running |
| 4. Mission end: score, payouts, survivors, both refusals named | **met** — a won debriefing reports an outstanding success, score 200, total 200, purse 100 → 350, four recovered; `test_game_ui.gd` pins that both refusals are named |
| 5. Chain and replay | **met** — *go on* takes the header's next map with `EnterNameOfNextMap` overriding it; *replay* restores the snapshot |
| 6. Economy survives a change of mission | **met** — 60 to hire, `+0x5A * 10` back, a swap costs the difference, the 10000 cap, no negative purse, EP-descending sort; and nothing in `_build` or `World.create` writes to the campaign's state |
| 7. Four screens on the original art, catalogue filtered and its locked half visible | **met** — six screens; 14/42 and 7/19 pinned |
| 8. Quick save and load across a change of mission | **met** — a save on turn 1 of `_C_141` came back in a **fresh process** with the same roster and the same `World` hash `78577782c3c3` |
| 9. `run_tests.sh` green, 34 suites, `campaign_runtime --check` in the always-run block, existing checks unchanged | **met with two deliberate increases** — see below |
| 10. The installation is untouched | **met** — `verify_untouched.sh` |

Criterion 9's two increases are intended and named here rather than hidden.
`campaign_tables --check` went 237 → **253**: the sixteen new checks pin the
tech-level finding of §3 and the catalogue filter of §3.1, which would otherwise be a claim in a document with
nothing verifying it. `remake_convert --check` went 190 → **220**: the campaign
categories are emitted on every conversion, so checking them belongs in the
check that runs. `brief_parse` (55), `sav_tables` (69) and `--check-cache` (29)
are unchanged.

```bash
python3 tools/campaign_runtime.py  --check gog_incubation          # 481
python3 tools/campaign_runtime.py  --check-saves tests/fixtures/saves  # 160
python3 tools/campaign_tables.py   --check gog_incubation          # 253
python3 tools/remake_convert.py    gog_incubation --check          # 220
python3 tools/remake_convert.py    gog_incubation --check-campaign  # 37
bash   godot/run_tests.sh                                          # 34 suites, 3133
```

### 9.1 Mutation battery

28 mutations of `inclib/campaign.py`, one token each, with
`tools/**/__pycache__` cleared before every run. **28 killed, 0 survived.**

Five survived the first pass and all five were the same defect: the check read
the constant it was checking, so mutating `EQUIPMENT_POINT_CAP`,
`RESALE_SCALE` or `DIFFICULTY_MULTIPLIER` moved the expectation with it. They
are literals now. The other two survivors were the type bounds the three
scoreboard counters share (`<= 30`, `!= 24`), which had no check at all;
`check_counters` covers them, the friendly-fire skip, and the bounded
out-of-bounds write.

### 9.2 One defect the battery did not find, and what did

`CampaignHost.replay()` called `ScoreRecord.reset()` — which is
`resetScoreboard` `0x0043B990`, the **whole** record — so pressing *Try Again*
wiped the campaign score along with the mission's. The battery could not see
it: it mutates `inclib/campaign.py`, and this was in `game/`. What found it was
reading `advance()` and `replay()` against §5's pairing and noticing that
`advance()` zeroed two of the four mission halves by hand. `reset_mission()`
is the routine that was missing, both twins carry it, and both suites pin the
difference. Driven end to end: `_C_140` won for 200, `_C_141` for 100 (total
300), *Try Again* → total 200 and the roster restored.

---

## 10. What this slice did not do

* **The sequence player** ([`41`](41-sequence-player.md)). Dialogue locations
  open, are named from `Campaign.lcl`, and play nothing (D5). Six of them have
  cells in `_C_XXX`.
* **`campaign_gold.py`.** §1 says why: the layer is pinned statically and
  confirmed by six real saves, and a native capture is the next step rather
  than this one's.
* **A save-slot screen**, multiplayer and play-by-mail
  ([`92` §7.9](92-remake-architecture.md)); importing original `.sav`
  ([`92` §7.3](92-remake-architecture.md) — deferred, not rejected).
* **Winning a mission by playing it.** The scorer is exercised through
  `SetGameControl`, which is the same act a mission script performs, and
  through 45 fixture cases covering five results by three difficulties by
  three kill/loss shapes. Playing `_C_140` to a win end to end is
  [`94`](94-slice-2-report.md)'s demonstration and was not repeated here.

---

## 11. Open questions

1. **What clears the entry snapshot.** `_5_.sav` is on the map screen with pool
   row 1 empty, and neither debriefing button writes it. §4 shows the
   consequence is not in doubt — the snapshot does not outlive the debriefing —
   but the instruction that clears it is not traced. It matters only to a
   remake that wanted to offer *replay* somewhere else.
2. ~~**Whether the Upgrade screen filters further than the tech range.**~~
   **Closed**, and statically. The first draft of this section said a
   screenshot would be needed; it is not, because `0x0047A090` and
   `0x0047A1B0` are not list *builders* — each is a "yield the previous
   acceptable id" iterator that the screen loops. It walks its table backwards
   by one record, skips one whose name is empty, and returns the first whose
   requirement byte satisfies `low <= b <= high`, writing that index into the
   caller's out-parameter. There is no list to filter afterwards and no second
   predicate anywhere on the path, so what the screen shows is exactly what
   the range admits.

   [`21` §4](21-info-lcl-schema.md) settles the last link: the byte the
   iterator reads is the weapon record's `+0x38`, which that table already
   names as the tech level, and the equipment record's `+0x21`, likewise. So
   the ten alien weapons — tech 0, non-empty name, cost 0 — do appear on the
   original's Upgrade screen. `campaign_tables.py` pins both iterators' stride,
   name offset and empty-string buffer, and the two limit writes.

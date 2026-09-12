# 102 — the remake's backlog, staged

*What is left to build, verify or decide in the remake, in the order it is
worth doing. Compiled 2026-09-12 by sweeping every **Open questions** /
**What is left** section of `92`–`101` and the behaviour specs behind them,
after the closed items were struck where they stood.*

This file is a **plan, not a spec**. Every entry names the document that owns
the finding; that document stays the place the evidence lives, and closing an
entry means writing the close **there** and deleting the entry here — never
striking it, because a backlog with a strikethrough in it has started being a
second history. Nothing is recorded here that is not already recorded somewhere
else — a second copy of a finding is how the two drift apart.

**Closed since this file was written (2026-09-12), and Stage 1 with it.**
`CrushWall`'s footprint, built in [`97` §50](97-slice-5-report.md) and
corrected in [`42` §8.2](42-mission-presentation.md); `_may_command_now`'s seat
test, in [`99` §7](99-slice-7-report.md); and the large-mover second ring, in
[`95` §9 item 2](95-slice-3-report.md) — which turned out to be a defect in the
*replay* rather than in the model, so nothing about `0x0040ADC0` changed, and
whose tie-break is measured natively by `approach_tie` the same day. The
stages below keep their numbers; **nothing the player can feel is open.**

**What is deliberately absent.** Items that are closed, items the remake has
decided not to implement (legacy multiplayer and `pbm session`,
[`25` §11](25-turn-and-round.md) and [`92` §7.9](92-remake-architecture.md);
ambience, which the original's subsystem never plays,
[`28` §6](28-effects-and-sound.md)), and items no amount of work can settle
(the eleven unreachable blob kinds, [`28` §12 item 3](28-effects-and-sound.md);
the jump's and the push's frames, which render inside the frame loop and fault
under `dbgcall`, [`97` §41.6](97-slice-5-report.md); the five cutscenes whose
speech and effects live in a CD track the GOG release does not ship,
[`101` §12.1](101-slice-9-report.md) and [`28` §6.1](28-effects-and-sound.md)).
Those classes are not a backlog.

---

## Stage 2 — the picture, where it is measurably wrong

### 2.1 Five weapon creators are not replayed against the capture

**Owner:** [`97` §11 and §14.5.1–§14.5.5](97-slice-5-report.md).
Counted against `blob_tables.creators.reachable`'s own thirty on 2026-09-12,
**25 are replayed against `blob_gold.py`'s capture** in `test_blob_native` —
22 rows of `BlobTriggers.WEAPON_PROGRAMS` plus the three typed seams. The other
five are not, and they divide:

* the tracer `0x004247C0`, the needles `0x00424250` and the flash `0x00423D80`
  still go down the **constructor-table arm**, one record per `call`, so the
  spread inside a call is the remake's own. Their burst delta, their lifetimes
  and both point-blank branches are measured;
* the shock wave `0x00422B80` and the spore cannon `0x004268B0` build their own
  records and are checked **structurally** in `test_effects` — a weaker claim
  than a field-for-field replay, and one nothing currently states as such.

All five already have a `blob_gold` phase behind them, so the capture is not
the missing half.

**What closes it:** a row in `WEAPON_PROGRAMS` — or, for the two builders, a
`test_blob_native` phase of their own — so that
`weapon_programs.routed_are_measured` covers all thirty. Keep the rule that a
row joins the table only once the suite replays it.

### 2.2 Weapon 11's arc has never run

**Owner:** [`28` §12 item 2](28-effects-and-sound.md). Its handler
`0x0046B0D8` marks a cell whose `+0x0B` action point is in 30..34, and
`_6_.sav`'s map carries none — so the arm marks nothing whatever it is aimed
at and the walk never runs. This is a property of the save, not of the arm.

**What closes it:** a save with cells in that band, two of them at least six
tiles from the shooter so the point-blank gate does not zero the offset.
`sav_parse.py --wrap` builds one from any `.lev`.

## Stage 3 — interface

### 3.1 The map interface is a radar, not a clickable map

**Owner:** [`99` §8](99-slice-7-report.md). `map_click`, `compass` and
`view_map` are pinned and **not played**, because the seventh slice draws
`aMI.cpp`'s map interface as a radar. Three sound ids with no consumer are the
symptom; the decision behind them is whether the remake ever grows the
clickable map. That is a [`92` §7](92-remake-architecture.md) decision first
and interface work second.

*(**Not here, and why: the between-players screen `0x0047C2C0`.**
[`97` §35.1](97-slice-5-report.md) left it "read, not built", which reads like
missing interface work. It is not: [`43` §7.3](43-battle-hud.md) reads its seven
arms, and a single-human campaign reaches only state 0 — which dismisses itself
by posting its own `WM_LBUTTONDOWN` and so shows for one frame — and state 2,
whose 185-byte arm contains no `aPrintLibText` call at all. Every caption the
routine carries is a multi-player caption. The remake's own *the aliens are
moving* plate is therefore a **declared divergence** to record in
[`92` §7](92-remake-architecture.md), not a screen that is missing.)*

### 3.2 The hit-point digit's gate

**Owner:** [`43` Open questions item 1](43-battle-hud.md). The listing draws
`mp[min(hp, 15)]` over a current player's unit while `+0x15` is non-zero, and
two frames of real play show none over unselected squad members.

**What closes it:** a `dbgcall` probe at the anchor reading `+0x15` of the
player's units and the three element slots `0x00417E70` leaves for their
cells — or a frame of the original at a hand-over with an untouched unit.

### 3.3 The far view is pinned, not played

**Owner:** [`99` §7](99-slice-7-report.md). The `map.LIB` flags switch in above
camera height `0x17700`; the remake's zoom is clamped to the mission's authored
`camera_height` (19 200..64 000 in the cache), so only `test_hud.gd` reaches
them. Decide whether the remake lets the player out to that height at all —
that is a [`92` §7](92-remake-architecture.md) decision, not a defect.

### 3.4 Two readings that were never checked against a picture

**Owner:** [`99` §7](99-slice-7-report.md), [`43`](43-battle-hud.md). The two
panel fonts (D7) and the block offsets were checked by **reading**, because
the Wine screenshot could not be taken; the magnifier's page (D4) and the
campaign map's band rings (D6) are decisions with the reading named rather
than implementations. Group them: one Wine session with screen-recording
permission answers all four.

---

## Stage 4 — verification debt

Nothing here is known to be broken. Each is a claim that rests on reading
where the project's own rules prefer a measurement.

### 4.1 The exported build's leak gate is ungated

**Owner:** [`101` §13.9](101-slice-9-report.md). `run_tests.sh` fails the run on
every leak line, and `test_game_ui`'s `a_screen_owns_everything_it_builds` names
the culprit inside the export too — but the **export itself** is started by
hand and nothing gates it; the 2026-09-09 run was read by eye. What is
uncovered is a leak none of the eight campaign screens makes.

**What closes it:** a wrapper around the `.app` that runs the suites and reads
its own tail, which §13.9 names as its own piece of work.

*(**Not here, and why: the Ogg music path's four objects.** They are closed —
[`97` §14.4](97-slice-5-report.md): the holder is the audio server, it lets go
on its next mix, and the fix is
`auto_accept_quit = false` plus `AudioSystem.shutdown()` and a wall-clock wait
before `quit()`.)*

### 4.2 The by-hand pass has not been re-run in nine slices

**Owner:** [`97` §36 / §42](97-slice-5-report.md). Slice G ran once, on
2026-09-03. Slices F through the ninth, the campaign, the shell, the touch
path and the Instant Action mode have landed since, each verified by suites
and captures. Nobody has played the result end to end.

**What closes it:** a session through the agent server on a shipping build,
with the screenshots filed. It is the cheapest item in this file per defect
found — [`99` §8](99-slice-7-report.md), [`101` §12](101-slice-9-report.md) and
[`101` §13.10](101-slice-9-report.md) were all opened by *play*, not by a suite.

### 4.3 The march's pace is read, not compared

**Owner:** [`101` §13.7](101-slice-9-report.md). 1.33 m a second follows from
the clip, the speed literal and the 20 fps limiter, each measured; that the
original looks the same at the same moment is not checked against a frame of
it. The *direction* is checked.

### 4.4 `_C_140` is not won by a scripted squad against the live planner

**Owner:** [`95` §9 item 1](95-slice-3-report.md). The run deadlocks: the
script's reinforcements from turn 5 plug the corridor faster than the squad
clears it. The mission is completable and defeat is reproducible; the suite
asserts each of the three outcomes for what it is. What is missing is a squad
tactic, not a rule — which makes this a **test-side** item and not a Stage 1
one.

### 4.5 The alien's jump scream picks a wave by reading, not by hearing

**Owner:** [`97` §31.8](97-slice-5-report.md). Which of `S_ALI_0/1/2` each draw
takes is read off the `je` ladder at `0x00411950` and not heard under Wine.
Cheap, and it is here only so it is not forgotten.

---

## Stage 5 — decisions waiting on the project owner

Not work until they are answered, and they are cheap to answer.

* **`beams_until_hand_over`** — offered to the player, or an internal flag for
  the checks? It is internal today.
  [`100` Open questions item 2](100-slice-8-report.md).
* **The far view** — see 3.3; the same shape of question.
* **The map interface** — see 3.1: a radar, or the original's clickable map?
* **A speech row in the options screen.** The original scales speech by the
  options record's own field; the remake rides the FX volume and has no row.
  [`92` §7.1](92-remake-architecture.md) permits it — that rule is about
  controls that do nothing, not about settings with no control — so this is a
  decision, not a defect ([`99` §8](99-slice-7-report.md)).

---

## Stage 6 — research, only if a symptom ever points at it

These are open *in principle*. None blocks anything, and each entry's own
document records what was already tried — read that before spending an hour.

| Item | Owner | Why it is last |
|---|---|---|
| What seeds the C runtime's generator | [`94` §9 item 3](94-slice-2-report.md) | no `srand` traced; both implementations start from the standard's 1 and say so |
| The 200-slot spawn rule | [`94` §9 item 6](94-slice-2-report.md) | the natural reading of a fixed array; a capture that inserts a unit and reads back its slot would close it |
| What clears the entry snapshot | [`98` §11 item 1](98-slice-6-report.md) | matters only to a remake that wanted to offer *replay* somewhere else |
| The root `SkeletonNode`'s own matrix | [`40` §11 item 5](40-charisma-model-animation.md), [`96` §11](96-slice-4-report.md) | `0x004842A2` is dead code; the four models stand on the ground to within 0.04 mm under the rule in use |
| Where the 16× bone-to-mesh scale is applied | [`96` §5.3](96-slice-4-report.md) | the number is verified, the origin is in the Charisma-to-Eng3d bridge, which is not decompiled |
| `_C_156`'s fourth teleporter exit, the `technical` box's cap, `Batteries` | [`26` §10](26-interaction.md) | engine oddities the remake reproduces faithfully |
| Why locations 3 and 6 load each other's upgrade map | [`27` §10 item 3](27-campaign.md) | pinned as observed; unresolvable from shipped data |

---

## Not a backlog item, but a standing rule

**Open lists go stale in place.** This sweep found six.
[`92` §9](92-remake-architecture.md) still named three closed research items;
[`94` §9](94-slice-2-report.md) and
[`95` §9](95-slice-3-report.md) still listed the planner, the campaign layer,
the bodies and the target patterns; [`97` §11](97-slice-5-report.md) still
carried unit speech and a creator count four days out of date;
[`99` §7](99-slice-7-report.md) still said a mission opens on turn 0 — and its
own *classic keyboard bindings* bullet said **closed** in bold without being
struck, which is the same drift one step short of complete. All six are struck
where they stand as of 2026-09-12. The convention that prevents it
is [`20` §10](20-lcl-language.md)'s: **strike the item, keep the evidence in
place, and point at where it closed** — never delete, and never leave it
looking open.

---

## Open questions

**None.** This file *is* the list; an item that belongs here belongs in one of
the six stages above, and an item that turns out to be closed is struck in the
document that owns it and deleted from here — a backlog with a strikethrough in
it has started being a second history.

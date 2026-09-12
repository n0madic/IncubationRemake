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

**Closed since this file was written (2026-09-12), and Stages 1 and 2 with
it — and most of Stage 3 the same evening, see its own heading.** Stage 1: `CrushWall`'s footprint, built in [`97` §50](97-slice-5-report.md)
and corrected in [`42` §8.2](42-mission-presentation.md); `_may_command_now`'s
seat test, in [`99` §7](99-slice-7-report.md); and the large-mover second ring,
in [`95` §9 item 2](95-slice-3-report.md) — which turned out to be a defect in
the *replay* rather than in the model, so nothing about `0x0040ADC0` changed,
and whose tie-break is measured natively by `approach_tie` the same day.
Stage 2, the same evening, in [`97` §51](97-slice-5-report.md): the last five
weapon creators are programs replayed against the capture, so all thirty are
(§51.1); and weapon 11's arc has run — twice, in `shot_11_band` and
`shot_11_overlay` — because its handler reads the **state byte**, the target
overlay's band, and not the action point it had been read as; the pattern
models on both sides are corrected ([`28` §12 item 2](28-effects-and-sound.md),
[`22` §7.2](22-combat-and-visibility.md)). The stages below keep their
numbers; **nothing the player can feel is open.**

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

## Stage 3 — interface

*Three of its four entries closed on 2026-09-12, and Stage 3 is what is left
of the fourth.* 3.1 turned out not to be a decision: `aMI.cpp` is the
mission's *map interface* module and its three "unplayed" cues were the
columns' press, the columns' hover tick and the map-view placer, mislabelled
([`28` §2.5](28-effects-and-sound.md), [`92` §7.22](92-remake-architecture.md));
all ten interface cues are played. 3.3 was played all along through the
*Overview map* button ([`43` §3.3](43-battle-hud.md)). Of 3.4, D4 had closed
on 2026-09-08, D6 is implemented and D7 is closed by tracing the handles
([`43` D6, D7](43-battle-hud.md)). 3.2's probe ran and moved the question
([`43` Open questions item 1](43-battle-hud.md)).

### 3.2 The hit-point digit — a frame, in two output modes

**Owner:** [`43` Open questions item 1](43-battle-hud.md). The overlay
routine is no longer suspect: `tools/hud_probe.py` steps `fcn.00417E70`
inside the live game and it blits `mp[hp]` over an unselected unit with
points on both tick phases, nothing over a spent one, `mp[49]` over
overwatch, and the selection's `mp[51]`/`mp[52]` blink with the digit on the
odd tick (`tests/fixtures/hud/hud_probe.json`, 23/23). What the two frames
showed — no digit on a unit's cell, digits on the empty cells of the fill —
is therefore compositing, and the one candidate the frames support is a body
drawn after the overlay, or an overlay drawn with depth in the accelerated
output mode.

**What closes it:** a frame of the original at a hand-over with an untouched
unit, in the software and in the accelerated output mode. `screencapture`
still has no screen-recording permission from the shell that runs Wine, so
it is a frame taken by hand. Until then D12 keeps the remake's picture on the
frames.

### 3.4 The panel's block offsets were never checked against a picture

**Owner:** [`43` §5.3](43-battle-hud.md), [`99` §7](99-slice-7-report.md).
The five blocks' offsets are read off the listing and drawn at those numbers
(with the eight-unit shift of the trailing blocks the remake's own); the same
frame 3.2 wants would confirm them.

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

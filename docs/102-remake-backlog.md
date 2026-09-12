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


### 4.4 The alien's jump scream picks a wave by reading, not by hearing

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

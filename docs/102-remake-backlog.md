# 102 — the remake's backlog, staged

*What is left to build, verify or decide in the remake, in the order it is
worth doing. Compiled 2026-09-12 by sweeping every **Open questions** /
**What is left** section of `92`–`101` and the behaviour specs behind them,
after the closed items were struck where they stood.*

This file is a **plan, not a spec**. Every entry names the document that owns
the finding; that document stays the place the evidence lives, and closing an
entry means writing the close **there** and deleting the entry here — never
striking it, because a backlog with a strikethrough in it has started being a
second history.

**Stages 1 through 5 are empty as of 2026-09-13.** Stages 1 and 2 (the
footprint, the seat test, the large-mover ring, the last weapon creators and
weapon 11's arc) closed on 2026-09-12 in [`97` §50–§51](97-slice-5-report.md),
[`99` §7](99-slice-7-report.md) and [`95` §9](95-slice-3-report.md). Stage 3
(the interface) closed the same evening except the hit-point digit and the
panel's block offsets, and those two were closed **by decision** on 2026-09-13
([`43` Open questions](43-battle-hud.md)): the overlay routine is measured, the
remake's picture matches the frames, and no frame of the original is going to
be taken for them. Stage 4 (verification debt) closed on 2026-09-13: the
export's leak gate is `make test-export` ([`101` §13.9](101-slice-9-report.md)),
the march's pace is a measured limiter ([`101` §13.7](101-slice-9-report.md)),
the jump scream is a `presentation_gold` phase
([`97` §31.8](97-slice-5-report.md)), the end-to-end by-hand pass has been
played by the project owner through the whole campaign, the shell, the touch
path and Instant Action ([`97` §36](97-slice-5-report.md)), and `_C_140`'s
scripted win is a non-item — the mission is won only by flanking, which a fixed
route does not do ([`95` §9 item 1](95-slice-3-report.md)). **Nothing the
player can feel is open**, and nothing below is worth an hour unless a symptom
points at it.

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

## Stage 5 — decisions and inputs waiting on the project owner

**Empty since 2026-09-13.** The three that were here are struck where they
lived, with the reason beside each: [`99` §8](99-slice-7-report.md),
[`100`](100-slice-8-report.md) open question 2, and
[`101` §13.7](101-slice-9-report.md).

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

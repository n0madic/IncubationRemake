# 100 — Eighth slice: the picture is a lagging mirror

*2026-09-07.*

The seventh slice closed its own list and left one architectural fact standing:
`core` resolves a whole command — and the whole computer turn — before it
returns, so the world `game` reads is always at the **end** of the last one.
Every presentation defect of the last three slices was a consequence, and every
fix was a mechanism that hid one field of that world until the animation caught
up. This slice removes the cause instead.

---

## 1. What was there: eighteen holds, one bug

Before this slice `game` compensated with eighteen separate mechanisms. They
are listed here because the report of what replaced them is only readable
against what it replaced.

| Hidden | Mechanism |
|---|---|
| position | `UnitsView.hold_at` / `_held_at`, fed by `AIPlayback.pending_starts` |
| fog | `UnitsView.hold_visibility` / `_held_visibility`, `SliceMain._seen_before_turn`, `_visibility_hold`, `visibility_hold_in`, `_event_reveals` |
| the identity of a slot | `SliceMain._views_before_turn`, `UnitsView.mark_dying(slot, view)`, `held_view` |
| death | `UnitsView._dying`, `mark_dying`, `is_dying`, `dying`, `clear_dying`; `SliceMain._mark_dying`, `_mark_dying_payload`, `_mark_dying_slots`, `_mark_dying_by`, `_mark_dying_by_script`, `_mark_dying_by_mine`; `AIPlayback.casualties_of` with its **five shapes**, `casualties_in`, `pending_casualties`, `all_casualties`, `script_riders_of` |
| terrain | `SliceMain._drawn_terrain`, `_redraw_event_cells`, and the refusal in `_redraw_terrain` |
| turn progress | `AIPlayback.played_slots` / `played_in`, passed to `TurnProgress.tally` |
| the watching seat | `AIPlayback.player()` |
| the order inside one command | `_hold_for_walk`, `STAGE_AFTER_WALK`, `_walk_has_epilogue`, `_pending_reactions`, `_queue_reactions`, `_drain_pending_reactions` |
| a unit that does not exist yet | `UnitsView.suppress` for a `RoofUnit`'s alien |

Every new mechanic added another. `casualties_of` is the clearest measure of
the cost: five different payload shapes had to be walked to find out who a turn
had killed, and a sixth was one new set piece away.

## 2. The mirror

`SliceMain._shown` is a clone of the world, taken when the mission is built and
advanced **one event delta at a time**. Every reader of what is on screen —
the bodies, the fog, the terrain, the interface, the radar, the ground overlay,
the click pick, the camera director and the agent's snapshot — goes through
`SliceMain.shown()`. `SliceMain.world` is read to submit a command, to ask
whether one is allowed (`may_*`, the movement query, the target bands) and for
the flow gates that are about the rules rather than the picture (the mission's
end, the auto end-turn, the autosave).

`World.clone()` is not `save()` and `load_save()`. That pair needs the same
`MapResource`, ends in a permanent `aBuildVisibleMap` that would move the
mirror's fog, and carries neither `special_models` nor `next_map` nor the
selection. The clone copies the simulation and **shares** the four read-only
tables. Its `script_program` is `null`: the mirror resolves nothing.

**The delta** is what one boundary wrote:

```
{cells: {index: {height, field_type, action_point, unit, effect[6]}},
 objects?: PackedByteArray,
 units: {slot: view | {}},        # {} is a slot the turn took off the map
 turn, game_control, rng, crand}
```

The cell half is exact: every write goes through a `MapState` setter, and the
setters keep a dirty set when `MapState.track_writes` is on. The unit half is a
diff of `UnitState.view()` against the views taken at the previous boundary — a
`UnitState` has thirty-eight fields written directly and no setter to hook, so
the diff is the honest price of the design and is stated as such.

`EventJournal` is **opt-in** (`World.enable_journal`). A world without one pays
one boolean test per setter and nothing else, which is why `test_ai` and
`test_mission` — which replay whole missions — are unaffected, and why
`cases_ai.json` is unchanged.

**The standing check** is the whole of the fidelity argument: after the last
delta of a command,

```
shown.canonical_hash_hex() == world.canonical_hash_hex()
```

A field nobody thought to carry — a slot a mission script refilled, a unit
weapon 47 converted, the hero counter — fails there deterministically, whatever
mechanic introduced it. That one invariant replaces the per-family checks the
holds needed. `SliceMain._check_mirror` makes the same comparison at the
playback's drain and resynchronises rather than drawing a world nobody can
name; the count is reported in the agent's snapshot rather than swallowed.

## 3. Where a boundary goes: the frame-tick rule

The original has no simulation/presentation split at all. Its frame tick
`0x0040B6F0` sits **inside** the mutating routines — 70 call sites,
[`28` §1.4](28-effects-and-sound.md) — so the picture reads the state of the
moment for free, and everything written between two ticks is one visible
change. The blocking loop does not transfer; that atomicity does:

> **An event boundary goes wherever the original would have drawn a frame
> between two writes.**

| Command | Events, in order |
|---|---|
| a walk | `move_begin` (the two opening visibility passes and mode 3's self reveal, all before the first step), `move`, `mine`, `teleport`, `script`, `reaction` ×N |
| a shot | `fire`, `reaction` ×N |
| a jump | `warp`, `mine`, `script`, `reaction` ×N |
| a use, a heal, a rotation, overwatch, a stimulant | one event each, **after** the charge |
| the end of a turn | `ground`, `script` (NEXT TURN), `script` (NEXT PLAYER), `hand_over`, the computer's own events, `hand_over`, … |
| a command's fog probe | `fog_probe` |

Three of these are corrections to what the plan assumed, and they are the
engine's:

* **the mine and the teleporter come before the arrival pass.** `_detonate`
  (`0x0046EDAF`) and `_teleport` (`0x0046EE03`) run before the closing
  `aBuildVisibleMapForUnit` (`0x0046EE55`), so the pass's writes ride into the
  next boundary rather than into the walk's;
* **one `reaction` per shot, not one `reactions` per drain.** The engine's
  drain calls `aAttackUnit` per reactor and each carries its own blocking fight
  animation. The planner still emits its own `reactions` event for the case
  file — that is a different document, and `EventJournal.SELF_MARKED` keeps the
  journal from stamping it twice;
* **the residue rides on the last event.** A command charges its movement points
  after the routine that moved the unit, so `EventJournal.take` folds whatever
  was written after the last mark into it — or, for a command that changed
  something and drew nothing, into one `sync` event the playback applies
  without presenting.

`EventPlayback` (formerly `AIPlayback`) plays that list: it presents an event,
holds for as long as the presentation asks, and lands the delta as it advances
past it. The `busy` gate is doing the whole of the work the hold stages used
to: a walk, a shot, a set piece or a camera flight keeps the event on screen,
so the mine waits for the last step and the return fire waits for the shot,
with no stage of the remake's own to serialise them. `skip()` still means
*stop drawing*: it lands every delta that is left, in order.

**The player's commands go through the same playback.** That was planned as a
later stage and turned out to be forced: once the picture reads the mirror,
a command that did not walk its own events would leave the mirror behind. One
consumer, one order, and `_after_command` runs at the drain rather than in the
frame the button was pressed.

### 3.1 One presenter per kind (2026-09-07, second pass)

The first delivery of this report claimed the presenters were written. They
were not: `_play_event_body` still had the seventh slice's five arms — `move`
reading a `payload.events` the journal never carries, `warp` reading a blast
the journal marks separately, `fire`, `parabomb` and a `reactions` list no
journal event has — while `SHOWN_KINDS` listed the journal's own kinds. Every
kind without an arm cost a 0.45 s empty wait and drew nothing: return fire,
the mine under a walker, the teleporter's stream and the turn's own set
pieces were not shown at all, and the reaction batch of the old design was
still alive beside the playback, with nothing calling it. The suites were
green because they pinned the old API. §8 records what that cost. The table
below is what is there now, and `game_ui`'s `presenters.*` checks pin that
each arm queues something or answers a hold.

| Kind | Presenter | Hold |
|---|---|---|
| `move_begin`, `hand_over`, `fog_probe`, `sync`, the refusals and the ring's rotation | none — the delta lands in the same frame as the next shown event | — |
| `ground` | **added 2026-09-09.** It was listed here as a kind with no picture, and it has one: `aPlayGroundFireAnimation` `0x004157B0` per ignited glow ([`42` §9.1](42-mission-presentation.md)). Left as bookkeeping, `_C_116`'s red patches went out in silence | the set piece's pool |
| `move` | camera mode from the event's `seen_source` / `seen_destination` (mode 1 for the player's own), then the walk along the event's `path` | flight + steps × 0.3 s |
| `mine` | `_present_blast` on the event's cell with the payload's blast — weapon 36/37, no shooter | the shot's frames |
| `teleport` | the stream on the entry with the exit as target, the traveller hidden at 40 and shown at 10 | 70 frames |
| `warp` | the jump: trail and waves for the player's, a scream for the computer's | the jump's frames |
| `fire` | `_present_attack` with the weapon from the event's note | the shot's frames |
| `reaction` | `_present_attack` as a reaction, from the event's own cell at the mover in the payload; the jam orbit when the payload says so | the shot's frames |
| `parabomb` | `_present_blast` on the fuse's cell; the payload is the blast | the shot's frames |
| `door` | `open_door` on the queue with the flight from the opener's head | 10 frames |
| `fire_heat_blocked` | the jam's wave | 0 |
| `script` | `_present_script`: the hook's set pieces and camera moves, one after another | their frames, summed |
| `use`, `heal` | queued by the command that submitted them, before the playback started | 0 — the picture's `busy` holds the event |

**Where a delta lands early.** Three presenters have a moment of their own and
land the event's delta from inside the sequence, through
`SliceMain._land_current_delta`: the shot's death stage before it takes the
body (`ShotHost.hide_unit`), so the mirror loses the victim in the frame the
blood appears and the target band over its cell goes with it; the teleporter
at frame 10, before it shows the traveller on the exit; the roof unit on the
first frame of its fall. Everything else lands when the playback moves past
the event.

**The pacing is the computer's.** `EventPlayback.play` takes a `gap`: the
seconds of free picture between two shown events. `end_turn` passes
`STEP_SECONDS` (0.45 s), so a 39-alien turn can be followed; `_play_command`
passes zero, so a player's command runs at the picture's own speed — the
first shown event is presented *inside* `play()`, in the frame the button was
pressed, the hold a presenter asks for runs under the animation rather than
after it, and the next event follows in the frame the picture stands free.
There is no floor: a shown event whose presenter answered zero and left the
picture free is **quiet** and costs nothing, which is what a `script` event
whose hook drew nothing, or a `door` with no queue, comes out as. The
`pacing.replay.*` checks of `charisma` and the `playback.*` checks of
`game_ui` pin the five rules.

**What is watched is the mirror's seat, not the playback.** With the player's
commands in the playback, "a playback is running" stopped meaning "the
computer holds the turn": the progress bar, the *press key to skip* note,
the key itself and the agent's `replay` are all keyed on
`shown().turn.current_player == 255` now, which the mirror holds from the
hand-over that opened the computer's turn to the one that closed it. A
player's own command darkens the pad and the columns for its length — the
original's `aPlayFightAnimation` takes the input with it — and nothing else.

**A set piece reads the state after its event, and the picture waits for
the queue** (2026-09-07, third pass). `_queue_setpiece` reads where the cell
is going -- the height a block travels to, whether a door is opening or
closing (`_paint_setpiece` turns the leaves by the sign of `to - from`), the
alien a roof unit inserted, the riders a platform relocated -- so it lands
the event's delta first (`EventPlayback.apply_current`). Queued against the
mirror's closed cell a door had `to == from`, turned its leaves the closing
way and snapped open when the delta landed at the end: the regression the
player reported as *opens, then closes, then stands open*. The bodies and
the terrain do **not** follow the landing: `_flush_picture` defers while
the queue runs, so the footbridge's riders still fall dead in the mirror and
the platform's passengers still ride from where they were, and the queue's
drain flushes. The player's `use` is therefore presented by the `use` arm
and not by `use_in_front` any more, because the landing needs a playback to
land into; the push reads the pushed record off the mirror **before** it.

**Correction, 2026-09-09: the queue's drain flushed only what nobody had
already paid for.** A presenter that lands its delta at a moment of its own
(`_land_current_delta`, the death stage) forces a flush from **inside** its
sequence: the bodies are rebuilt, the terrain is not -- the set piece owns
its cells -- and `_picture_stale` is cleared on the way out, so the drain's
`_flush_picture` returned at its first line and the deferred repaint was
simply lost. It came back only when some later, unrelated delta asked for
another one. Reported on `_C_110`, whose `ParaBombs` mines are the one thing
that changes a cell **and** kills the unit standing on it in the same event:
`core` cleared the cell, the mirror agreed, and `A_MINE.3DI` went on standing
there after the blast. The terrain repaint is owed on a flag of its own now
(`_terrain_stale`, the shape `_overlay_stale` already had) and
`_drain_deferred_repaints` pays both the frame the queue empties;
`test_game_ui`'s `death.the_repaint_is_owed` and `death.the_drain_pays_it`
are on the same forced flush the death stage makes.

**One rebuild per frame.** `_apply_event` used to free and rebuild every body,
run a fog pass, diff the terrain and redraw the overlay per delta, and the
quiet events between two shown ones land several in one frame. It marks the
picture stale now and `_flush_picture` pays once: at the top of `_process`,
before a presenter reads the picture, and inside `_land_current_delta`.

## 4. The fog, and the alien that stayed a beam

The reported defect: an alien walks out of the fog into the squad's sight and
stays a **contact beam** ([`22` §9.1](22-combat-and-visibility.md)'s
`+0x4F == 1`) until the turn changes — attacking as a beam, which is a marker
with no body for the fight clip to play on.

Half of that is the engine's. The fog the *rules* read is rebuilt at the
hand-over and at nothing in between ([`22` §9.4](22-combat-and-visibility.md)),
so in the original the alien is a contact for the whole of its walk too. What
the player *sees* follows the per-command probe, whose restore covers the unit
byte and not the 3D object's draw flag, so the picture runs ahead of the rules
by exactly one probe ([`92` §7.5.5](92-remake-architecture.md)). But the probe
is per **command**, and the computer's turn is one command.

The other half was the remake's: the replay overrode the pass with a snapshot
taken *before* the turn began, so nothing could change for its whole length.

`PictureFog` answers the question once, for the whole picture:

* the pass runs over the **mirror**, per event, so it moves as the turn is
  drawn;
* it is computed for the **watching seat** — the human player who handed the
  turn over. `turn.current_player` is 255 while the computer holds it, and a
  pass for 255 is the aliens' own view of the map;
* each walking body is answered at **the cell it is drawn on**, through a new
  `at` argument on `Visibility.states_for` that moves only the observed
  position and puts it back before returning. So the alien comes out of the fog
  in the frame it comes out of the fog;
* the engine's own three reveals are kept and forced: mode 3's self reveal
  (`0x0046E4BB`), the shooter's (`0x0046B643`) and the same one reached through
  the reaction drain. They are read off the event, not off the byte, because a
  jammed shot reveals nobody;
* `PictureFog.beams_until_hand_over` restores the original's timing. It is a
  **picture** flag and not a `World.compat_flags` entry: it moves nothing the
  canonical hash covers, and a compatibility flag that changed a hash would be
  a worse defect than the one it reproduces.

**The radar and the ground overlay now read the same answer** as the bodies and
the click pick. They used to read the stored `+0x4F` while the bodies read a
fresh pass, which is the engine's own asymmetry
([`99` §205](99-slice-7-report.md)) — a deliberate deviation, recorded here:
with one source there is one frame in which an alien appears everywhere, and
the alternative was a radar branch of its own for the computer's turn, when the
mirror's stored bytes are the aliens' view.

## 5. What went, and what stayed

**Gone**: every mechanism in §1's table except the last, together with
`AIPlayback`'s casualty extractor and its five shapes.

**Stayed**, and re-documented rather than removed:

* `UnitsView.suppress` / `reveal` — a picture-only hide with no state behind
  it: the camera riding on a unit, and the teleporter's window between frames
  40 and 10;
* `UnitsView.lift` / `shift` — interpolation between the shown-before and the
  shown-after of a set piece, not compensation for a `core` that moved
  something early;
* `UnitsView.hide_now` — the frame the object leaves the picture,
  `0x00405320(obj, 5)`. What changed is what it means: the delta that killed
  the unit has just landed;
* the camera's hand-back, the selection's carry-over, and the gates that hold
  the mission's end, the auto end-turn and the autosave until nothing is being
  drawn. Those are legitimate waits for the picture, not races.

## 6. The suites

`test_journal.gd` is the thirty-eighth suite. It pins the clone's independence
in both directions, the delta's shape and that building one draws from no
generator, that a world with no journal records nothing, the hash invariant
after a move, a rotation, a fog probe, two end-turns and a shot, the boundary
order, one `reaction` event per resolved shot, and the two facts the whole
design rests on: before a `move` delta the mirror still has the mover on its
source cell, and before a `fire` delta it still has the victim.

The suites that pinned the holds were rewritten onto the mirror rather than
deleted: `game_ui`'s `replay.*` became `mirror.*` and `fog.*`, `effects`'
rider checks now assert that the mirror keeps a body the truth has lost, and
`hud`'s progress checks read the tally off the world they are given.

**38 suites, 4382 checks, 0 failures** at the first delivery; **38 suites,
4420 checks, 0 failures** after the second pass of §3.1, which rewrote the
twenty `game_ui` checks that pinned the old API (`shot.*` onto the playback,
`walk.*` onto the `mine` event) and added `playback.*`, `presenters.*`,
`commands.*`, `hud.a_players_own_command_is_not_watched`, `overlay.*`,
`death.*` and `picture.*`; **38 suites, 4431 checks, 0 failures** after the
third, which added `use.a_set_piece_reads_the_state_after_its_event`,
`picture.the_flush_waits_for_the_queue` and `ring.*` -- the last walking a
`_C_140` marine one field through `move_selected(x, y, facing)` and
requiring the journal empty behind the playback and the mirror's facing the
ring's with no resync -- and, from a review of the working tree, three
more: `fog.the_hand_over_reads_the_mirrors_seat`,
`playback.a_second_play_lands_the_first` and `sync.*` (§8).

**The journal's cost, measured** (§8's first open question). A headless
probe ran six computer turns per mission, three runs each, with and without
`enable_journal`, on this machine:

| Mission | Six turns, no journal | Six turns, journal | Worst turn, no journal | Worst turn, journal | Events |
|---|---|---|---|---|---|
| `_C_140` | 101 ms | 113 ms | 29 ms | 32 ms | 102 |
| `_C_132` | 244 ms | 285 ms | 237 ms | 264 ms | 76 |

The unit diff adds about 11 % to the corpus worst case, 27 ms on a 237 ms
turn, and is not worth a cache.

**Two mutations, both shown failing and reverted**, at the first delivery.

* *The delta drops its `units` half.* Ten checks fall across two suites: the
  hash invariant after a move, a rotation, a fog probe, an end turn and a shot;
  the sync event; the destination pin; the unit diff's packed members; and both
  footbridge riders. It is the invariant doing exactly the work it is for.
* *The fog ignores where a body is drawn* (`Visibility.states_for` skips its
  `at` overrides). One check falls, and its message is the reported bug in two
  numbers: `got 1, want 0` -- **1 is the contact beam**, 0 is the body.

The second needed a fixture of its own to be worth anything. Pointed at
`_C_140`'s opening turn it passed **with the mutation in**, because every alien
there is already fully visible and an override changes nothing. The check now
builds a 7x7 map with a wall of forty height levels between a marine and one
alien, so the plain pass really does answer *contact* and the overridden pass
really does answer *body*.

**Ten more at the second pass**, one per rule of §3.1, each shown failing
and reverted with the file diffed against its backup: no step inside
`play()`; the gap ignored; the gap applied to the player; the 0.45 s floor
back on `asked`; the busy test in front of `_elapsed += delta`; the
`reaction` arm removed; `_watching` keyed on `is_running()` again; the band
filter removed from `cell_states`; `hide_unit` without the landing; and the
rebuild back inside `_apply_event`. All ten fell on the check written for
them (M3 and M5 also on the `commands.*` checks, M8 and M9 on `death.*`
too), and after each the file compared equal to its backup.

**Three more at the third pass**, for the two regressions the player
reported and the fix behind them: the ring's rotation submitted after the
walk's playback again (`ring.the_turn_is_inside_the_playback` and
`ring.the_mirror_turns_with_the_truth` fall); `_queue_setpiece` reading the
mirror before its delta (`use.a_set_piece_reads_the_state_after_its_event`
falls); and `_flush_picture` no longer deferring while the queue runs
(`picture.the_flush_waits_for_the_queue` falls). The first was run three
ways, because the first two answers were not the one wanted: with the call
*removed* both `ring.*` fall; with a second call *added* below the playback
only the journal check falls, the rotation in front still turning the
mirror -- and the ring check's first draft chose its facing as the unit's
own plus four, which a unit standing with its back to its target walks
into by itself, so the facing is the walk's *way back* now; with the call
*moved* below the playback both fall again, the second on `_desyncs`.
After each the file compared equal to its backup.

**Three more from the review** (§8): the `hand_over` seat read off the
truth again (`fog.the_hand_over_reads_the_mirrors_seat` falls); `play()`
replacing a running list without ending it
(`playback.a_second_play_lands_the_first` falls); and the journal's
baseline dropped, so an unmarked command's residue is called empty again
(`sync.a_bare_generator_write_is_one_sync_event` falls, and the hash
check behind it). All three fell on the check written for them, and after
each the file compared equal to its backup.

## 7. Two things the mirror made straightforward, and one it exposed

**The turn progress bar reads the mirror alone.** `TurnProgress.tally` used to
take the slots the replay had played and the casualties it was holding on their
feet, because the truth had spent every point and lost every body before the
first frame. Both arguments are gone: the world it is handed is the picture's,
so a unit it shows as spent is one whose action has been drawn.

**The skill orbit now follows its shot.** `_present_shot_orbits` queued both
orbits ahead of `ShotSequence`, which is right for the overheat's
(`aCheckWeaponDamage` is step 1 of `aAttackUnit`,
[`22` §7.1](22-combat-and-visibility.md)) and wrong for the skill's:
[`22` §7.5](22-combat-and-visibility.md) plays `0x00410190` **after**
`aPlayFightAnimation` returns, if the shooter is alive and its pool's level
rose over the value saved at entry (`0x0046B588`). Queued together, the player
was told about a promotion before the shot that earned it. It is now
`_present_overheat_orbit` before the shot and `_present_skill_orbit` after it,
with a destroyed shooter earning none.

## 8. Open

**What the first delivery claimed and had not done** (2026-09-07, second
pass). The plan's stages 3 and 4 — one presenter per journal kind, and the
removal of the reaction batch and the walk's hold stage — were reported as
done here, in [`92` §7.17](92-remake-architecture.md) and in `CLAUDE.md`,
with the suites green. They were not: the presenters were the seventh
slice's, keyed on payload shapes the journal never produces, so on the first
live run every player action waited 0.45 s of empty frame under a red
*AI turn* line, return fire and the walker's mine were never drawn, the aim
stayed over a dead alien until the command drained, and the computer's turn
waited the asked hold a second time after every animation. The suites did not
see it because twenty of them pinned the old API. §3.1 is what closed it;
the lesson is the one the plan's own last step states — a slice whose suites
are green on a broken game has not been played, and the live run is not
optional.

* **The turn progress bar.** `TurnProgress.tally` still takes the `played` and
  `doomed` lists the holds fed it; with the mirror both are empty and the
  "acted" count is therefore always zero during a replay. The tally should
  derive it from the mirror instead — a unit whose movement points differ from
  its allowance has acted, as far as the picture has been shown. Not done here.
* **The skill orbit still plays before its shot.** `_present_shot_orbits` is
  queued ahead of `ShotSequence`, which is right for the overheat orbit
  (`aCheckWeaponDamage`, §7.1 step 1) and wrong for the skill one:
  [`22` §7.5](22-combat-and-visibility.md) plays `0x00410190` **after**
  `aPlayFightAnimation`, if the shooter is alive and its level rose.
* **A `script` event with two animated set pieces** lands its whole delta at
  the first of them. No shipped hook does that — `_C_106`'s six bridges are six
  separate hooks — but the rule is worth stating.
* **Nothing has been played live.** The suites are green and the mirror's
  invariant holds inside them; `_C_106`'s platform, `_C_129`'s tube and the
  fog correction have not been watched on screen. *Second pass:* see §9.
* `aPlayPlatformSequence`'s fog rebuild is for the unit the *interface* has
  selected, and `core` owns no selection. Unchanged by this slice and
  unimplementable under it.

**Three findings of a review of the working tree, closed** (2026-09-07,
third pass). None broke a single-player game; each was a rule stated and
not kept.

* **The `hand_over` delta set the fog's seat off the truth.** `_apply_event`
  asked `_watching_seat()`, which reads `world.turn`, and the truth's
  rotation has already run past the computer's turn to the *next* human
  seat by the time the replay is drawn -- so with two humans the whole
  computer's turn would have been drawn through the second one's fog. It
  asks `_seat_of(_shown)` now: the mirror holds 255 with the seat that
  handed over as `previous_player`, and the closing hand-over lands the next
  seat when it is drawn.
* **`EventPlayback.play()` over a running playback replaced its list.** The
  deltas that had not landed were lost and the first command's finish never
  ran; unreachable from the keyboard, which the playback holds, and reachable
  from the agent's direct calls. A second `play` now skips the first --
  every delta lands and its finish runs -- before the new list is taken.
* **A command that marked no event dropped its scalar residue.** With no
  last event to compare the residue against, `_is_empty_delta` answered
  *empty* on the cells and units alone, so a generator or a game-control
  slot moved by an unmarked command never reached the mirror -- reachable
  under `COMPAT_FOG_PROBE_QUIET`, which suppresses the `fog_probe` event a
  player's command otherwise always marks. The journal keeps the scalar half
  of the state as of its last `take` and compares against that; the residue
  becomes the `sync` event it always should have been.

## 9. The live run (2026-09-07, second pass)

Driven through the agent server on the shipping build (`--agent-port`),
polling `/state` every 30 ms; the saves and settings under `user://` were
backed up first with a SHA-256 manifest and verified untouched afterwards.

* **A player's shot on `_C_140`.** The first snapshot after the click, 42 ms
  later, already shows `shot.clip` on the queue and `playback` running; the
  body's `firing` follows on the next drawn frame. `replay` is false
  throughout, the radar keeps its marks, `progress` is 0 and `note` is
  empty. The whole shot is 2.35 s on screen; at the drain `pending` is 0,
  `shown_hash == hash` and `desyncs` is 0.
* **A player's walk on `_C_129`.** `walking` from the first snapshot, no
  note, radar shown; the walk spent the last point and the computer's turn
  followed by itself.
* **The computer's turn on `_C_140`.** `replay` true, the radar hidden and
  the bar lit from the first snapshot to the last, `note` reading *the
  aliens are moving — advances N (any key…)* and cleared at the drain;
  two walks in 1.55 s, and the longest stretch with nothing on screen is
  the 0.45 s gap itself. On `_C_129` the same turn shows the computer's own
  shots one after another with the same gap.
* **`_C_129`'s tube.** `OpenTube` is drawn as a `script` event of the
  turn's own program — `script.camera` then `open_tube`, twice — and the
  mirror is level after it.
* **The three quiet pad commands** (stimulant, weapon mode, stand down)
  were found to skip the playback: their events stayed on the journal and
  the pad drew a mirror one command behind. They go through
  `_play_command` now, like every other command.
* **The ring's facing moved the truth under the picture.** `_complete_ring`
  submitted the rotation *after* `move_selected` had started the walk's
  playback, so the `rotate` event landed on the journal behind events the
  playback had already taken; at the walk's drain `_check_mirror` found the
  facing changed and resynchronised -- the warning the player saw on every
  walk. A turn in place was never played at all, and stood one command
  behind. The facing is the command's now (`move_selected(x, y, facing)`,
  `warp_selected`, `rotate_selected`), written before the playback takes the
  events, and lands as the walk's last quiet event, which is when the body
  turns. Found with `World.mirror_diff`, which the resync warning and the
  agent's `mirror_diff` field now carry: a hash that says *different* names
  nothing.
* **A door, watched** (third pass). On the `_C_101` save's turn 10 a marine
  walked one field to (13,12), was turned west by the ring and used the door
  at (12,12) twice: `setpiece.flight`, `open_door`, `setpiece.back` on the
  queue in that order, the playback running under all three, `pending` 0
  from the first snapshot -- the `use` delta lands when the lid is queued --
  `mirror_diff` empty and `desyncs` 0 at the drain, no note and no bar. The
  leaves were captured three times inside `open_door` on a closing use, at
  frames 301, 318 and 336 through the flight's own view from the opener's
  head: wide open, half shut, shut -- one direction, no snap back -- and
  stood where they had turned; the second use opened them again. One thing
  the run found is the
  **screenshot's**, not the game's: a `shot` taken in the frame of a
  rebuild shows no bodies and an empty plate, while the snapshot of the same
  frame counts the three bodies and the panel's texts. `capture_png` forces
  a draw in the middle of the frame, before the nodes the rebuild made this
  frame have reached the renderer; the next frame's capture is whole.
* **The supply box's ammunition.** The engine's arm *sets* the count to the
  weapon's magazine (`0x00410780`, action point 12), so a full magazine
  shows no change; and the panel drew the mirror's count until the lid's
  frames were over. With the `use` delta landing when the lid is queued the
  panel shows the new count in the frame the box opens. Checked headless
  through the journal: the count reaches the mirror and the hash is level.

Two more observations from the same run. On turns 1–3 of `_C_140` the
first snapshot of the computer's turn shows the playback running with
`replay` false: the turn's own `NEXT TURN` / `NEXT PLAYER` `script` events
come **before** the first `hand_over`, so the mirror still holds the player's
seat while they are drawn, which is the intended reading of *watched* and not
the old defect. And once, on the first `_C_140` session, `shown_hash`
differed from `hash` with `pending` 0 and nothing drawn — the truth had moved
outside a command after a few selections; it was level again at the next
drain and did not reproduce on `_C_129` or on `_C_140` after its first turn,
and `World.save` writes no fog, so the writer is not named. A mission torn
down mid-turn (`ESC`, *Main Menu*) also left the playback running over a
null world; `EventPlayback.cancel` drops it in `_clear_mission` now.

**Not staged live**, and honest about it: no alien on overwatch was found
within the turns played, so the return fire after a walk is pinned by
`commands.the_reaction_waits_for_the_walk` and not by a frame trace; no
shot killed its target on `_C_140` (six hits on the alien at (18,2) left
it at 4 points, which was not looked into, and the marines were converted
on turn 9), so the band leaving the victim's cell at the death stage is
pinned by `death.*` and `overlay.*` alone; and the mine under a walker on
`_C_106` was not reached.

**One thing the run could not name.** The undo-turn autosave, slot 33 of
the live `user://saves`, was rewritten twice, 31 seconds apart, while a
mutated copy of the suites ran and none of this session's games was
open; a clean run with
`CampaignHost.save` instrumented to report any write into the default
directory wrote nothing, and every suite that saves points its host at
`user://tests/`. The writer is not found. The three driven sessions of the
third pass were opened on that slot and closed without ending a turn, and
the manifest taken before them verified byte for byte after each.

## Open questions

1. ~~Whether the delta's unit diff is worth its cost on the corpus worst case
   (`_C_132`, 264 ms of planning).~~ **Closed 2026-09-07**, §6: 27 ms on a
   237 ms turn.
2. Whether `beams_until_hand_over` should be offered to the player at all, or
   stay an internal flag for the checks. It is internal today.

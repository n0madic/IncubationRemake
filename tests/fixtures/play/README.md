# The by-hand passes

One directory per pass, named by its date, holding the screenshots a driven
session of the **shipping export** filed through the agent server
(`--agent-port=`, [`docs/92` §7.16](../../../docs/92-remake-architecture.md))
and the process's own log. The pictures are of Blue Byte's art, so the
directories are gitignored (`tests/fixtures/play/*/`); this file is committed
and records what each pass drove and what it found. The pass itself is
reported in the slice document named beside it.

A pass is not a suite: it is the cheapest item per defect found
(the backlog's *verification debt* — `docs/102`, retired 2026-09-13 — as
it stood that day — three of the ninth slice's findings were opened by
play, not by a check), and it answers
the one question no check does — whether the whole thing plays end to end.
Every screenshot's numbers come from the same frame as its picture: the
`/state` snapshot is read in the batch that files the shot.

Take one with:

```bash
make build-macos
"godot/export/Incubation-remake.app/Contents/MacOS/Incubation - Remake" \
    --resolution 1280x800 -- --agent-port=8787 --agent-dir=/some/dir
python3 tools/agent_client.py wait-up
python3 tools/agent_client.py cmd "press Start Campaign" "wait 5" "shot 01"
```

Two rules a pass has each cost a re-run: a driven session writes the **live**
`user://` — back up `saves/` and `settings.json` first and put slots 31–33
back afterwards, because every turn rewrites them; and `click_screen` takes
**canvas** units, which at 1280×800 is a 768×480 canvas scaled by 1.667, not
the 640×480 plate scaled by two.

## 2026-09-13 — the whole game, nine slices after the last pass

Reported in [`docs/101` §15](../../../docs/101-slice-9-report.md). Build
`36d5e32` plus the working tree of that day (debug export, so the developer
status line is on), cache `1-0.41.0-English-892e1299ddb5-3401aa12f66e`,
settings as found (Hard, gore 3, faithful on, music off, FX 100 %).

| shots | what was driven | what the frame's numbers said |
|---|---|---|
| `01`–`03` | the menu, the options page, the campaign choice | `shell.screen` `menu` → `options` → `campaign_select`; the music program `arack:2,3,4,5,6,7` on track 2 |
| `04`–`08` | chain 1 picked, the intro (`Seq_1`, three clips), skipped with a key, the campaign map | `sequence.kind: intro`, `Animation_1_2` → `_1_3`; then `CampaignMapScreen`, location 51, open `[1, 10, 51]`, 100 EP |
| `09`–`10` | the Unit Menu, *Recruit unit* (the campaign's direct hire, 60 EP), *Undo* | roster 3 → 4 (`Soldier 4`, exp 0) → 3; EP 100 → 40 → 100 |
| `11`, `28_march_0..7` | upgrade base 1's fly-in, from the first waypoint | `FlyInScreen`; the two visible marines of `upgrade_1`'s three walking the pad toward the shuttle, one frame every 0.2 s |
| `12`, `13` | the Upgrade Menu and the Item List over the landed pad | `UpgradeScreen` (Bratt, Light Combat Gun 7/7, *Buy Item* disabled on an owned weapon), `ItemListScreen` (Scan Module 50 / skills 2, Light Armor 10 / skills 1) |
| `29`–`30` | location 10, a framed dialogue | `sequence.kind: dialogue`, `Dialog_02/Animation_D02` |
| `32`–`35` | location 51's briefing typing, the voice-over, *Tips*, back to the whole page | `sounds: ["audio/briefing/_c_100.wav"]`; the page whole after 600 frames |
| `36`, `17`–`18` | the deployment screen, three marines on three landing dots | slots 6, 9, 11 at (11,9), (12,10), (11,10), roster empty |
| `19`–`20` | turn 1: Bratt selected, a walk with the ring's facing | `9 reachable, 0 warp, mp 3`; after the walk `(10,11)` facing 5, 1 MP |
| `37_shot_a..e` | Maxon's 55 % shot on the one alien with a line | the caption *Maxon received 1 experience points* (docs/42 §4.2) before the muzzle (§4.6), the camera unmoved for the player's own shot (§4.3), alien 5 dead, ammo 7 → 6 |
| `38`–`41`, `44` | the in-mission shell, *Save game* into an empty slot, *Load Game* a turn later | the slot row `Campaign 1 _C_100 0 2026-09-13 01:02:16`; the load answers `loaded slot 20` with the world hash **the same** as at the save (`5cb0b439e781`) |
| `21`–`23` | the first attempt's computer turn: Bratt, deployed forward, killed on turn 1 | `the aliens are moving -- advances 5`; then `Mission failed / You were defeated!` — `_C_100.lcl`'s `HeroKilled(0)` → `SetGameControl(4, 1)`, the debriefing with *Try Again* alone, Result −102 |
| `42`–`43`, `auto*` | ten turns of holding the pocket: the aliens (order 8) never come, no marine ever has a line | the stalemate is the map's, not the game's — the squad is walled in and the scouts' `walk_to` shuffles between (10,10) and (11,10) |
| `45`–`48` | `cheat nuke`, the turn ended, the won debriefing | `9 killed`; *Mission completed / This mission was successful / Turns 11*; kills 10, losses 0, result 130; *Continue* and *Try Again* |
| `49` | *Continue* | the map with location **52** and mission `_C_101`, EP 100 |
| `50`–`51` | *End game* → *Yes* | the confirmation, then the menu |
| `52`–`57` | Instant Action: *Bug Race*, four soldiers deployed by dots, two computer turns. **Route changed 2026-09-13**: the level now opens in the HQ over an empty pool (`aInitGUI` `0x004542A1`), and the squad is hired and armed there before *Deploy units* raises this screen; these frames predate that | `_S_070`, 30×30, 29 units; `fires 9` with the beam, `advances 5`, `opens a door 8` with the flight down to the door, the lid, and the eye's return |
| `58`–`62` | the ending through the debugging entries (`campaign 1`, `enter _C_YYY`, `ui map`): the animated extro, the 4000 ms hold, the credits roll | `Animation_Extro_2` → `_3`; then *Back* / *Exit Game* over the roll, the remake's own heading first |
| `game.log` | the process's whole output | four lines; **nothing** printed at exit — no leak, no error |
| `second-session/ft_*`, `lt_a` | a second launch, base 1's fly-in **timed** by polling `/state` from the click to `UpgradeScreen` — twice by a ring click (once with three `shot`s during the flight), once by `location 1` | `FlyInScreen` at 0.5–0.7 s, `UpgradeScreen` at **11.3–11.5 s**: 10.8 s of flight, which is `fly_advance`'s 217 steps at 20 a second for `upgrade_1`'s three waypoints |
| `second-session/adv*` | Bug Race again, three computer turns filed every 10–12 frames | `fires 9` from behind the shooter with the bolt and the burst on the marines; `opens a door 8` with the flight down, the lid and the return; `fires 8` from the player's own view with both ends on screen (docs/42 §4.3's first test passing) |

**What it found. No defect.** One reading was chased to a conclusion: the
first session's three visits to base 1 saw the flight **end early** — the eye
at the shuttle within about 1.5 s twice, the Upgrade Menu up within 3.5 s once
— where later sessions measured **10.8 s** six times, the law's own length
(217 steps at 20 a second for `upgrade_1`'s waypoints), including replays of
all three of the first session's preambles (`second-session/v3_*` is the last,
visit 3's own batch). The only thing in the code that shortens a flight is a
key or a mouse press (`FlyInScreen._unhandled_input`, the original's
`0x004fcbdc`), and no driver verb that runs during a flight pushes one. The
code is correct and the reading does not reproduce, so it is a one-off
mis-timing or a stray desktop keypress — closed, not carried as a question
([`docs/101` §15](../../../docs/101-slice-9-report.md)).

Four things worth knowing before someone calls one of them a defect:

* **A click during a hold is dropped**, not queued: the ring clicked in the
  second after a dialogue's key did nothing, and the same click a second
  later opened the briefing. That is the hold doing its job.
* **The mission report panel is never seen in a campaign.** `_check_mission_end`
  raises the debriefing in the frame the panel would show, so the panel is
  Instant Action's; a frame filed in that gap (`22_turn2`) shows the map with
  no interface and no bodies — the rebuild frame `agent shot` is known to
  catch — and the next frame is the debriefing.
* **The march is out of the landed camera's view.** A second visit to base 1
  found the pad empty at the flight's end: the marines walk from
  `(20..21, 10..12)` toward the shuttle at the look-at target and the last
  waypoint looks past them, so the squad is seen from the first waypoint and
  not from the last. The first visit, filed from the flight's start, has them.
* **A computer walk can look at a wall.** `56_instant_t2` — filed during
  `advances 5` — is a frame of nothing but wall texture. That is
  [`docs/42` §3.2](../../../docs/42-mission-presentation.md)'s **mode 2**: a
  mover seen only at its destination is watched *from its own eyes*, the eye
  riding on the unit at head height with the unit's object hidden, so an alien
  walking a corridor out of the fog shows the corridor's wall. The three
  turns filed frame by frame in the second session drew fires and a door and
  no mode-2 walk, so the frame stands on the rule rather than on a second
  picture.

The touch path was not driven: it needs a touch screen, and
`make test-touch` is its check.

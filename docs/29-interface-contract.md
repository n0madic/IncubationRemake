# Interface contract

**Status: the interface information and state boundaries needed by a remake
are decoded and checked by `tools/interface_tables.py --check`.** This is the
delivered package F in [`00`'s game-logic matrix](00-overview.md). It is a contract for a new
interface, not a request to copy the 640x480 layout, mouse driver, widgets,
fonts, or button art of the original.

The contract deliberately joins data that have different owners: unit and map
state come from [`10`](10-lev-mission-format.md), [`21`](21-info-lcl-schema.md),
and the behavioural packages; the source of visible screen structure and
language is [`20`](20-lcl-language.md). A UI reads that state and asks those
systems to perform actions. It must not reimplement combat, movement, the
roster, or campaign progression locally.

---

## 1. What a replacement must present

### 1.1 Battle HUD

`aUI.cpp` refreshes the selected-unit panel through the shared renderer
`0x004756D0` (`0x004739E9`). The renderer's actual view model is narrower than
the whole UnitMap record and is now checked at its reads:

* name (`unit +0x00`), HP (`+0x16`) and computed maximum HP;
* movement points (`+0x15`), FP (`+0x19`), front/rear armour (`+0x36/+0x37`)
  and computed rank;
* experience, training points and decorations (`+0x17/+0x18/+0x38`);
* the six skills (`+0x1A…+0x1F`) and carried equipment (`+0x21…+0x35`);
* equipped weapon (`+0x3F`), ammunition (`+0x3D`), heat (`+0x3E`) and
  malfunction state (`+0x40`), plus the weapon record's derived values.

Unit type `+0x4C` selects `Info.lcl`'s `SetUnitInfo`; weapon, equipment, and
their requirements resolve through the same database. Position, facing and
owner are selection/map state used elsewhere by `aUI.cpp`, not numbers drawn
by this panel. A replacement may show them, but they are not part of the
recovered original panel. All presentation values are authoritative state,
not cached screen text.

The HUD must also expose each available action and its disabled reason. A
command must be sent to the game only after its normal semantic gate accepts
it. For example, **Use** is unavailable to species 3 (machine), without a
valid target, or with no movement points; if it succeeds and the unit survives,
it spends exactly one movement point and marks `unit[+0x39]` (the acted flag)
as 3. The runtime action-state byte is a separate field, `unit[+0x41]`. Those
gates and all target classes are specified in [`26` §1.2–§4](26-interaction.md).

`aUI.cpp` maps its 3×2 command pad to six operations. The positions and ids are
useful only as an interoperability check; a replacement may use different
buttons or hotkeys:

| Pad position | Id | Operation | Owner of the rule |
|---|---:|---|---|
| column 0, row 0 | 1 | reaction fire / Def | [`25` §6](25-turn-and-round.md) |
| column 0, row 1 | 3 | spend stimulant | [`25` §8](25-turn-and-round.md) |
| column 1, row 0 | 2 | heal with a medic kit | [`21` §3](21-info-lcl-schema.md) |
| column 1, row 1 | 7 | stand down | [`25` §8](25-turn-and-round.md) |
| column 2, row 0 | 5 | toggle weapon mode | [`25` §7](25-turn-and-round.md) |
| column 2, row 1 | 8 | use the cell in front of the unit | [`26` §1–2](26-interaction.md) |

The numeric id is an internal protocol, not a label a remake must display.
The map's pending-command selector is a separate context: there, `1` means
walk and `3` means warp; it must not be confused with the command-pad `3`
(stimulant).
The normal availability gate (`0x00472570`) must be evaluated again when the
button is activated; a stale enabled state must not mutate the authoritative
unit.

### 1.2 Map interaction

*The camera of the mission view — its placement on a unit, its flight, the
three views, the mouse control and what it does during a walk, a shot and a
set piece — is not part of this contract and was not in it; it is decoded in
[`42`](42-mission-presentation.md), 2026-09-02.*

The replacement keeps one selected unit and one explicit intent. The following
are contract names for the modes a new map UI needs; they are not claims that
the original stored an enum with these names:

| Intent mode | Click result | Existing operation |
|---|---|---|
| select | select the unit on the cell, or clear selection | unit-map lookup; refresh the HUD |
| move | request a legal walk destination | `aExecuteMove` (`0x0046E220`), with the path/cost rules in [`23` §8](23-ai-system.md) |
| warp | request a legal jump destination | `aExecuteWarp` (`0x0046EF50`), selected by the warp-destination overlay described in [`23` §7.5, §10](23-ai-system.md) |
| attack | request a legal target cell | `aAttackUnit` (`0x0046B450`), the resolver in [`22` §7](22-combat-and-visibility.md) |
| use | invoke Use against the unit's current facing cell (the clicked cell is not a new target) | `aExecuteUse` (`0x0046DC60`), with the target gate in [`26` §2](26-interaction.md) |
| rotate | change the selected unit's facing | `aChangeUnitViewDirection` (`0x004792A0`), which writes `unit +0x46` |

A click in any mode is a request, not a direct grid edit. The operation owns
legality, costs, animation, and side effects; the UI refreshes its selection
and overlays from the result. The map can have its own pointer graphics and
overlays.

`aMI.cpp` has a 16-arm input-event translator (`0x00453900`). Both input paths
(`0x00450D62`, `0x00450E75`) feed it, and its returned command is passed to the
BattleSystem consumer `0x0041DA20`. The original event numbers are an internal
GUI protocol, but their complete boundary is:

| GUI event | Translator result |
|---:|---|
| 1 | clear/reset the current map interaction (`0x00453410`), return 0 |
| 2 | execute the selected-unit/map focus path (`0x00451150`), return 0 |
| 3 | initialise or refresh the placement/map path, return 0 |
| 4 | execute the alternate selected-unit/map path (`0x004510A0`), return 0 |
| 5, 6 | return BattleSystem command 4, 3 |
| 7, 8 | return BattleSystem command 6, 5 |
| 9 | run the mode-dependent give-up/mission-end path, return 1 |
| 10 | return BattleSystem command 2 |
| 11 | open briefing/info when allowed, otherwise set its pending flag; return 0 |
| 12 | select the **next own unit with movement points** (`0x00471E00(1)`, walked with `0x00477D40`); return 0 |
| 13 | toggle the map-view flag/cursor presentation; return 0 |
| 14 | put the camera on the **next visible enemy** (`0x00453CF0`, walked with `0x00477DF0`); return 0 |
| 15, 16 | return BattleSystem command 7, 8 |
| anything else | return 9 |

*(Corrected 2026-09-05 by [`43` §5.2](43-battle-hud.md): this table had 12 as
"finish the current player's interaction and advance" and 14 as "cycle the
selected friendly unit". `0x00453CF0` walks `0x00477DF0`, whose test is a live
unit **not** of the current player with `+0x4F == 0` -- event 14 is *Jump to
visible enemy*, a camera move -- and it is event 12's `0x00471E00(1)` that
selects the next own unit, one **with points left**. Event 10 is *Next
player*, the end of the turn. The captions `Txtmod_h` 30 and 37 say the same.)*

Commands `1…8` are then owned by `0x0041DA20`: give-up/session handling,
save/load UI and its three load slots. Those are application-level actions,
not map edits. A replacement interface therefore need not reproduce event
numbers 1…16, but it must produce the same named action or BattleSystem command
at this boundary. The checker pins the jump table, all seven direct command
returns, the four direct action calls, both producers and the consumer.
The mode-dependent chains of events 3, 9 and 11–13 and the default return are
pinned separately, so every arm has a semantic instruction anchor in addition
to its jump-table address.

AI overlays remain data views, not commands: the move map, targeting map, and
their meanings are already specified in [`23` §6, §7.5, §8, §10](23-ai-system.md).
For a replacement that wants to show the same affordances, the transient cell
state has this minimum interpretation:

| Cell state | Meaning for a view |
|---:|---|
| `10` | reachable by walking; `cell +0x0C` is movement points left on arrival |
| `60` (`0x3C`) | reachable by a warp/jump |
| `30…34` | AI target/danger band: hit chance `≤20`, `21…50`, `51…70`, `71…90`, `>90` |
| `70…73` | deployment marker for player `0…3`; this is a transient `cell[+0x00]` state, not an action-point id |
| `100` (`0x64`) | the path selected by path reconstruction; highlight only while the request is active |

Values `80…94` are combat scratchpad markers, not a user-facing overlay. These
states are rebuilt by the movement/targeting operations; the UI must discard
them after a turn, selection, or resolver result changes rather than persisting
its own copy. The deployment markers are likewise rebuilt by the hand-over
routine below and cleared by the placement/reset paths.

#### Hand-over deployment overlay — **[code] `0x004312D0`**

The refresh at `0x00419D50` calls `0x004312D0` once for the incoming player,
after `refreshPlayer` (`0x004781C0`). The routine is a small dispatch on the
turn counter, not a second player-refresh or a hidden UI model. The names in
the pseudocode are descriptive contract names, not recovered symbols:

```c
int refreshDeploymentOverlay(u8 player)        /* 0x004312D0 */
{
    if (getTurnCounter() == 0)                 /* 0x0043B280 -> 0x00509E1D */
        markDeploymentCells(player);           /* 0x004310F0 */
    else
        resetCellOverlay();                    /* 0x0042EE90 */
    return 1;                                   /* both binary arms */
}
```

`turn == 0` is normally the initial hand-over in a mission, and is true again
after the counter wraps at 200. The branch is defined only by the byte value,
not by a separate first-turn flag.
`markDeploymentCells` scans every 23-byte CtrlMap record. Its normal branch
marks a cell when `cell[+0x0B] == player + 1`; when the mode/solo gate
(`0x0043B1F0`, true for the shipped net/pbm one-human case; [`25` §3.1](25-turn-and-round.md))
is true, it instead marks every **empty** deployment field whose action-point
id is `1…4` (`cell[+0x07] == 0xFFFF`). A matching cell receives
`cell[+0x00] = player + 0x46`. For player indices `0…3` this yields marker
`70…73`; other byte values do not produce an `aPI.cpp`-accepted marker. Every
other cell is reset to state `1`. Thus `cell[+0x0B]` remains the action-point
id (`1…4`), while
`cell[+0x00]` carries the temporary player marker consumed by `aPI.cpp`.

`resetCellOverlay` clears the per-cell transient scratch value (`cell[+0x0C]`,
used for attack damage or move-map MP depending on the active operation) and writes
state `1` to all records, preserving coordinates, action-point ids, and unit
links. This is why the replacement UI should derive its deployment affordance
from the authoritative CtrlMap state and must not persist a parallel list of
placefields.

### 1.3 Deployment

The Place Interface (`aPI.cpp`) makes roster/map transfer explicit:

1. Select a roster slot or a deployed pool candidate.
2. A deployed unit can return only from a cell whose state marker
   `cell[+0x00]` is **70…73** (a player-specific deployment marker), and only when
   `unit[+0x4D] >= 1`; it then calls
   `aTransferUnitFromMapToPool`.
3. Placing a roster entry calls `aTransferUnitFromPoolToMap(player, slot, x, y)`.
   That routine creates the map unit, rebuilds visibility, and removes the
   roster slot.

The transfer routines own capacity and survival semantics: a non-candidate or
full pool silently drops a returning unit ([`27` §3.4](27-campaign.md)). A
replacement may show a warning, but it must not pretend that the original
state was retained.

### 1.4 Campaign screens

`Menu_b.lcl` supplies the screen set: HQ, briefing, Select Units, Upgrade,
Item List, campaign map, dialogue, sequence, Recruit, map, and slide show.
The relevant logical operations are already fixed:

* Recruit costs weapon 0 plus 50 (60 shipped EP), uses the first free slot,
  and dismissal refunds the cached resale value.
* Upgrade equipment spends its price; a weapon replacement first refunds the
  old weapon then charges the new one. Skill requirements are in twelfths and
  the screen's text field displays `TP / 12`.
* The candidate roster can be sorted, so selection must track a record/slot at
  the moment of action rather than a stale visual row.

The details and their evidence are [`27` §3–5](27-campaign.md). A replacement
is free to arrange these screens differently; it is not free to duplicate the
economy in a button handler.

---

## 2. Localized screen source

The complete UI source is three layout programs and nine English text tables:

| Resource | Contract |
|---|---|
| `DATA/GUI/Menu_a.lcl` | front-end layouts; networking is out of remake scope |
| `DATA/GUI/Menu_b.lcl` | campaign and roster screens |
| `DATA/GUI/Menu_c.lcl` | quit and decoration screens |
| `DATA/TXT/English/GUI/{Campaign,Mission,Txtmod_*}.lcl` | 868 user-visible localized entries |

`Menu_*.lcl` contains 29 windows and 299 GUI-builder calls. `WinText` is a
text id in the currently selected text bank, not an English string. Load the
matching language table and resolve the id at render time; do not hard-code the
English extracted during research. The LCL selector `_A` chooses a named
layout routine; the full selector tables and builder argument meanings remain
in [`20` §5–6](20-lcl-language.md).

---

## 2.1 How a gadget is drawn — **[code] `aPrintGadget` `0x0043A030`**

*(Added 2026-09-08. Pinned by `interface_tables.py`'s `gadget.*` checks.)*

`Menu_*.lcl`'s builders name a `Library` column and a `Width`, and neither is
what it looks like. `Library` is a **sprite index into `buttons.LIB`**, not a
library id, and `Width` is not a pixel count: it is the number of pieces
*including* the two caps.

`aPrintGadget` switches on the gadget's type byte (`gadget + 0x63` in the
staging record, `0x00508C23` in the live one), and the two types the campaign
windows use are:

| Type | Built by | Drawn as |
|---|---|---|
| 3 | `GUI_SetButton` `0x0043CD10`, `GUI_SetTextButton` `0x0043CFF0` | `base + 0`, then `Width - 2` copies of `base + 2`, then `base + 1` |
| 4 | `GUI_SetIcon` `0x0043D110` | `base`, alone |

The pieces are laid **edge to edge with no overlap** — the painter's cursor is
`edi += width_of(piece)` at `0x0043A360` and the measurer `0x0043A9D0` repeats
the same sum, which is how the engine knows how wide a gadget is. So:

* `GUI_SetButton (..., 0_Library, ..., 6_Width, ...)` is `27 + 4×31 + 18` =
  **169** units, from `buttons.LIB` 0, 2 and 1;
* `GUI_SetTextButton (..., 6_Library, ..., 5_Width)` — the Upgrade Menu's name
  field — is `32 + 3×32 + 32` = **160** by 32, from `buttons.LIB` 6, 8 and 7.

**`base + 1` is the right cap and `base + 2` is the fill**, which is the
opposite of what the sprite order suggests; drawing `base + 1` repeatedly
gives a row of round caps and not a button.

### The second trio is the **pointer's**, not a press

`0x0043A06D` compares the gadget's own id with `0x00509A30` and, when they
match, draws `base + 3`, `base + 5` and `base + 4` instead — and an icon draws
`base + 1` instead of `base` (`0x0043A259`, `inc dl`).

`0x00509A30` is written by `0x0043A8B0`, which hit-tests the **cursor**
(`0x0043A650`), stores the answer and repaints the gadget that was lit
alongside the one that now is. No mouse button is read anywhere in it. So the
lit faces are a **hover highlight**: `buttons.LIB` 0/1/2 against 3/4/5, and the
icon pairs 44/45, 48/49, 50/51 and 52/53 — in each pair the second is the same
picture with its lamp lit.

### A list is a listbox, and a setting is a small field

`Menu_a.lcl`'s *Leveloptions* is the shape every list in the game has:
`GUI_SetListbox (0..9, fntID, WinText, Library, 060_x, 120 + 22i_y, 8_Width)`
— ten rows of 22, composed exactly as a button is (`0x0043D610` builds the
same type-3 gadget), from **three different bases**: 12 for the top row, 18
for every row between and 24 for the last, each a trio of 32×22 pieces with
its own lit twin three along. It is paged by `GUI_SetIcon (10, 30_Library,
320, 120)` and `(11, 32_Library, 320, 155)`; a shipped listbox has no scroll
bar.

A **setting** in that window is two gadgets, not one: a right-aligned caption
(`GUI_SetText ... 2_Format`) and, beside it, the changeable value on its own
`GUI_SetButton`/`GUI_SetTextButton (..., 6_Library, ..., 2_Width)` — 64 units
of the name field's pieces. Only the value is a gadget.

### `Format`, not `cX`, is `GUI_SetText`'s alignment

`GUI_SetText (txtID, fntID, WinText, x, y, Style, cX, cA, cB, cC, Format)`
carries two columns that look like they could be the alignment, and it is the
**eleventh**. `0x0043C7D0` stores it at `+0x20` of the text record and
`0x0043C940` hands it to the printer, whose `0x00439777` reads:

```c
if (format == 1) x -= width / 2;   /* centred */
if (format == 2) x -= width;       /* right   */
```

`cX` is the seventh column, a `word` at `+0x18`, and the printer takes it as a
separate argument. The two agree in 72 of `Menu_*.lcl`'s 121 calls, which is
why reading the wrong one is nearly invisible: the Upgrade Menu's item name
(`0_cX` but `1_Format`, at x 500 — the item window's own centre) and the Item
List's two counters (`1_cX` against `0_Format` and `2_Format`) are the places
it shows.

The `fntID` column matters as much. Of the 89 `GUI_SetButton` calls in the
three menu programs, **81 name font 0 and 8 name font 1 — none names font 2**;
of the 121 `GUI_SetText` calls, 68 name font 0 and the 28 that name font 2 are
the window titles. A screen that draws everything in `font_2` is drawing at
roughly twice the size the coordinates were written for.

### The two sounds — **[code] `aInitGUI` `0x0043BF30`, `aPlayGUIClickSound` `0x0043E5E0`**

`aInitGUI` loads exactly two waves into two buffers: `click_1.wav` into
`0x0050B2A0` and `click_2.wav` into `0x0050B2A4`. `aPlayGUIClickSound(0)`
plays the first and `(1)` the second, and the four screens that call it pass
both.

The first one is also the **pointer's**. `0x0043C500` calls the hit-test, and
when the gadget under the cursor has *changed* it plays `click_1.wav` directly
— panned by `320 - pointer_x`, so the click follows the cursor across the
screen. Nothing reads a mouse button on that path.

### The Upgrade Menu's *i* — `0x00510A54`

Gadget 16 of the Upgrade window toggles one global between 0 and 1
(`0x0045B4BC`) and redraws the item panel. While it reads 1, `0x00458BFE`
**does not load the item's shape library**, so the item window has no picture;
what takes its place is the item's own **description**.

`0x00458B2D` (equipment) and `0x004587A6` (a weapon) call `0x00432B70` /
`0x00432BD0` with the rectangle `(405, 140)` by `170 × 110` — the item
window's interior. Both wrappers:

1. read a **letter out of the record** — `+0x29` of the 42-byte equipment
   record (`0x00517BD9` at id 0), `+0x40` of the 65-byte weapon one
   (`0x0051B300`). `Info.lcl` writes it as the last string of `SetEquipInfo`
   and `SetWeaponInfo2`, and `inclib.info` parses it as `key`;
2. **refuse when it is `#`** (`0x00432B86`, `0x00432BE4`);
3. open `DATA/TXT/<language>/Info/Data.txt` at that letter plus a digit naming
   the family — `0` a unit (`0x00432B20`), `1` equipment, `2` a weapon — and
   title the page with the record's own name.

So `Scan Module`'s `key` of `A` is block `A1`, *Returns the number of units in
close proximity.* The file holds 54 blocks: `A0..P0` for units, `A1..S1` for
the nineteen items and `A2..P2` for the sixteen human weapons — plus `**`,
`*1` and `*2`, which is where everything else lands.

**`#` is the engine's refusal and no shipped record uses it.** *(Corrected
2026-09-08. This section said the alien weapons "carry `#` and have no page",
and they do not.)* Every record without a page of its own — the ten alien
weapons, the eight `B`-variant duplicates, the Combot's gun, `Explosives`, and
`Info.lcl`'s own placeholder row 28 `"-"` (`* (x) No Weapon`) — carries `*`,
which is a letter like any other: the wrapper does not refuse it, the family
digit is appended as usual and the bank answers block `*2` with *No
information available.* So the `#` arm at `0x00432B86`/`0x00432BE4` is
reachable only by data the game does not ship, and a remake that refuses on
`#` alone still shows the right page for every shipped record — by asking for
it, not by skipping it.

What `Txtmod_b` 166..173 are for is therefore still **UNVERIFIED**. They name
regions of this window (*Squad information*, *Item to purchase*, *Soldier
profile*, *Soldier's weapon information*, *Inventory*, *Action points*, *Total
skill points, skill points available and commendations*, *Unit to upgrade*),
which is what a hover help would say, but nothing has been found that draws
them.

---

## 3. Required integration boundary

```
UI input -> selected intent -> existing game operation -> authoritative state
      ^                                                       |
      +---------------- localized view model ----------------+
```

The UI reads immutable presentation data plus the current authoritative game
state. It requests named operations and waits for their result before changing
selection or presenting a cost. This keeps save/load, AI turns, mission end,
and a future renderer independent of the UI.

## Open questions

None for the replacement interface. The original HUD view model and all 16
`aMI.cpp` event arms are now pinned at their operation boundary; their pixel
rendering and raw input encoding are intentionally outside the contract --
and are, since 2026-09-05, the subject of [`43`](43-battle-hud.md), which
reads the layout the remake now draws.
`PressDown`'s original values 1 and 2
have no recoverable behavioural distinction ([`20` §5.4](20-lcl-language.md));
they are layout metadata outside this contract. Likewise, the map event
numbers are not raw mouse messages a new interface needs to preserve; only the
intent transition and operation result are contractual.

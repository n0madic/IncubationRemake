# The turn and the round

[`22`](22-combat-and-visibility.md) describes what a shot does and
[`23`](23-ai-system.md) describes the computer's half of a turn. This document
is the frame around them: **who moves, in what order, what a hand-over
restores, and what ends a turn.**

It states only what those documents do not. Where a rule already lives
somewhere — the movement-point formula in [`10` §5.5](10-lev-mission-format.md),
the twelve LCL game-control slots in [`20` §7](20-lcl-language.md), who may go
on overwatch in [`21`](21-info-lcl-schema.md), the save-block offsets in
[`11` §5.2](11-save-game-format.md) — this document links to it rather than
repeating it.

Verified by `tools/turn_tables.py --check`, 85 checks.

---

## 1. The developers' vocabulary

The code and the mission scripts use one word for the whole rotation and
another for one player's slice of it:

- a **turn** is one pass through every player. The counter is a single byte;
  the LCL call type `05` is `NEXT TURN` and the predicate that reads the
  counter is `CheckCurrentTurn` ([`20` §5](20-lcl-language.md)).
- a **NextPlayer** is one player's slice. LCL call type `01`; the routine is
  `aNextPlayerHandling`.

This document uses their words. A "round" in the sense a boardgamer would mean
it is what they call a turn.

**Modules.** The state lives in `aGameControl.cpp`; the driver is
`aViewPlayer.cpp`; the per-unit refresh is `aUnitMap.cpp`; the reaction queue is
`aTacTools.cpp`; the computer's own turn is `aAISystem.cpp`
([`23`](23-ai-system.md)).

**A naming caveat.** `aGameControl.cpp` is almost entirely one-line accessors,
and a one-line accessor is never wrapped in `CHECK`, so it never pushes its own
name. `tools/trace_names.py` recovers exactly four names from the module —
`aDecDecorations`, `aSearchFirstPlayer`, `aSaveGameControl`, `aLoadGameControl`.
Everything else here is named by address. No name is invented.

---

## 2. Game mode — **[code] `0x00433DC0`**

Four things about a turn depend on one byte, and the binary names all four
values itself. `0x00433DC0` formats the mode into a diagnostic line through a
five-arm jump table at `0x00433FC8`:

| Mode | The word the binary prints | Player slots | Set at |
|---|---|---|---|
| 0 | `undefined` | — | never |
| 1 | `campaign` | 1 | 4 sites, one beside `aCreateUnitPoolForCampaign` and the literal `"_C_100"` |
| 2 | `net session` | 4 | 1 site, immediately before `aInitDirectPlay` |
| 3 | `local session` | 4 | 2 sites |
| 4 | `pbm session` | 4 | never as a literal — see below |

Anything outside `1..4` reaches `"no gametype selected"` in `0x0043AD20`, the
routine that lays the player slots out and that runs after every mode change.

**Mode 4 is never set from a literal.** Three of the ten call sites push a
register instead (`0x0044A337`, `0x0044F869`, `0x0044F95B`) — they restore a
saved mode rather than choosing one. So the *name* `pbm session` is the
binary's, but no reachable path in this build is shown to select it. That is
consistent with [`11` §5.3](11-save-game-format.md): the play-by-mail passwords
are in the save format and their accessors exist, and package H is out of
scope ([`91` §9](91-game-logic-research-plan.md)).

Two mode-dependent behaviours matter below: the reaction queue is ordered by
ticket **only in mode 1** (§6), and only mode 2 asks DirectPlay which player
this machine is (§4).

---

## 3. The state a turn runs on — **[code] `0x0043AD00`–`0x0043BF20`**

All of it is inside the 720-byte block `aSaveGameControl` writes.
[`11` §5.2](11-save-game-format.md) tabulates it as file offsets; this section
gives the accessors and what the turn does with them. Read the two together —
the offset column there is the authority, the behaviour column here.

| Accessor | Reads / writes | Role in the turn |
|---|---|---|
| `0x0043B280` / `0x0043B290` / `0x0043B2A0` | the **turn counter**, one byte | get / set / advance. §4 |
| `0x0043B6E0` / `0x0043B6A0` | **player kind**, `u32[4]` | `0` = the slot is not in the game |
| `0x0043B700` | — | counts the slots whose kind is exactly `1`: the **human** players |
| `0x0043B310` | **player-slot count** | the rotation's upper bound |
| `0x0043B2C0` / `0x0043B2E0` | **current player** | the setter admits `0..4` and `255`, nothing else |
| `0x0043B2D0` | **previous player** | copied from the current one by the advance |
| `0x0043B600` / `0x0043B5C0` | **player name**, four 20-byte slots | display only |
| `0x0043B740` / `0x0043B730` | **game mode** | §2 |
| `0x0043B010` / `0x0043B060` / `0x0043B0A0` | **equipment points**, `u32[4]` | the add clamps at **10000** |
| `0x0043B0F0` / `0x0043B120` | **commendations**, `u8[4]` | [`20` §7](20-lcl-language.md) slot 11 pays into it |
| `0x0043B1E0` / `0x0043B1D0` | the **solo flag** | see below |
| `0x0043B160` / `0x0043B180` / `0x0043B1A0` | the twelve **LCL slots** | [`20` §7](20-lcl-language.md) owns these |
| `0x0043B930` / `0x0043B960` | per-player **end state** | `5` = out of the rotation |

**The turn counter wraps at 200.** `0x0043B2A0` is five instructions:

```c
u8 turn = ++g_turn;                 /* 0x00509E1D */
if (turn == 200) g_turn = 0;
```

`0x0043B770`, which runs once when a game starts, zeroes it along with LCL
slots 10 and 11 and the four end-state records. So `turn == 0` means "no
hand-over has happened yet", and that is exactly the test the hand-over uses to
recognise the first one (§4).

Real saves show the full range of that. A save taken on the campaign location
screen and the snapshot the game writes as the next mission loads both carry
`0`; the player's first save inside that mission carries `1`; later saves in the
same mission carry `6` and `10` ([`11` §4](11-save-game-format.md)). A campaign
therefore runs the counter from 1 upward per mission and resets it between
them — the 200-wrap is a guard, not a mechanic anything reaches.

**The solo flag** (`0x00509F08`) is what puts the computer into the rotation:
when the last human slot has moved, the advance hands the turn to player `255`
only if this flag is set (§3.1). Three sites store it, and between them they
define it:

| Site | Writes | When |
|---|---|---|
| `0x0043AF0B` | `1` | `0x0043AD20`'s **campaign** arm |
| `0x0043AE2A` | `0` | `0x0043AD20`'s arm for the other three modes |
| `0x0043B1D5` | `1` | `0x0043B770`, at game start, if the human count is `<= 1` |

So it means *"the computer side plays"*: always in the campaign, and in the
other modes only when one human turned up. The reference sweep in
`turn_tables.py` finds no reference to it — or to any of the seven other turn
globals — outside `aGameControl.cpp`.

**Per-player end state.** Four 40-byte records; the field at `+0x20` of each is
what `0x0043B930` returns. `5` means the slot no longer takes turns, and the
rotation skips it. The other values (2, 3, 4) are written after the mission
ends from LCL slots 0–4 — that is [`20` §7](20-lcl-language.md)'s table and
package B's subject, not this document's.

### 3.1 The rotation — **[code] `0x0043B320`, `aSearchFirstPlayer` `0x0043B410`**

```c
BOOL advancePlayer(void)                     /* 0x0043B320 */
{
    g_previousPlayer = g_currentPlayer;
    if (g_currentPlayer == 255) {            /* the computer has just moved */
        if (aSearchFirstPlayer()) return TRUE;
        g_currentPlayer = 255;  return TRUE;
    }
    while (g_currentPlayer < g_playerCount - 1) {
        g_currentPlayer++;
        if (kind[g_currentPlayer] == 0)          continue;   /* empty slot   */
        if (endState[g_currentPlayer] == 5)      continue;   /* out          */
        if (!0x0043B1F0())                       return TRUE;
        if (g_turn == 0)                         return TRUE;
        if (countLiveUnits(g_currentPlayer))     return TRUE;  /* 0x00477BF0 */
    }
    if (g_soloFlag) { g_currentPlayer = 255; return TRUE; }   /* the computer */
    if (aSearchFirstPlayer()) return TRUE;
    CHECK_FAIL("none players in game, but program works on!");
    return FALSE;
}
```

`aSearchFirstPlayer` is the same loop from slot 0. Three consequences:

**Player `255` is a full member of the rotation, `252` is not.** `255` is the
alien side ([`10` §5.7](10-lev-mission-format.md)); it takes its turn after the
last human slot, and only when the solo flag is set. `252`, the neutral-prop
owner, is never stored in the current-player byte — the setter would reject it,
and nothing passes it. It is acted on once per computer turn by
`aAI_SpecialPlayerControl` ([`23` §9](23-ai-system.md)), which is not a turn of
its own.

**A player with no units left is skipped, but only from the second turn on.**
The `g_turn == 0` escape means the very first hand-over never skips anybody,
which matters because units can be placed by the mission script after the map
loads. `0x0043B1F0` is the gate in front of the whole skip rule:

```c
BOOL 0x0043B1F0(void) {
    if (!g_soloFlag) return FALSE;
    if (g_mode == 2 || g_mode == 4) return TRUE;
    return g_mode == 3 && humanCount() > 1;
}
```

Read against the table above, that is true **only in a `net session` or
`pbm session` with one human player**: the campaign fails the mode test, and
the `local session` arm cannot fire at all, because the flag is only ever set
when the human count is at most one. So a shipped single-player campaign never
skips a player, and never reaches the arithmetic §4.1 guards with the same
predicate.

**In the campaign the rotation has two members.** Mode 1 gives one player slot
(§2) and sets the solo flag outright, so the cycle is player 0, player 255,
player 0, …

---

## 4. The hand-over — **[code] `0x0047D600`**

One function decides whose turn is next, raises both LCL events and starts the
computer's turn. It returns `0..3` and `aNextPlayerHandling` dispatches on that.

```c
int handOver(int arg)                              /* 0x0047D600 */
{
    int result = 1;
    if (arg == 0) {
        if (!anyPlayerLeftThisTurn()) {            /* 0x0043B490, below */
            if (g_turn == 0) 0x0045FF00(humanCount);   /* mission objectives */
            advanceTurn();                         /* 0x0043B2A0 -- turn++   */
            0x00470AB0();  0x0042ED60();
            aRunLCL(_A, 5);  aRunLCL(_B, g_turn);  /* NEXT TURN, docs/20 §5  */
            if (!runProgram()) return 0;
        }
        if (g_turn != 0) {
            0x0045FF60();
            aRunLCL(_A, 1);                        /* NEXT PLAYER            */
            aRunLCL(_B, g_turn);
            aRunLCL(_C, g_currentPlayer);
            if (!runProgram()) return 0;
            if (missionEnded()) return 0;          /* LCL slots 0..4, docs/20 */
                                                   /* inlined at 0x0047D88B;
                                                      decoded in 27 §6.3      */
        }
        if (!advancePlayer()) { allPlayersOut(); return 0; }
    } else {
        if (!aSearchFirstPlayer()) { allPlayersOut(); return 0; }
        if (g_mode == 2 && g_turn == 0) result = 3;
    }

    refreshCurrentPlayer();                        /* 0x00419D50, §5 */

    if (g_currentPlayer == 255) {                  /* the computer's turn */
        setViewState(2);
        arg = (g_mode == 2) ? ownNetworkPlayer() : 0xFE;
        if (g_turn != 0)
            aAISystemControl(255, arg, 0x0047C2C0);    /* docs/23 §2 */
    } else if (g_mode == 2 && g_currentPlayer != ownNetworkPlayer()
               && result != 3) {
        result = 2;
    }
    return result;
}
```

Reading the order of that body settles two things a remake would otherwise
guess at:

**A turn advances when nobody is left to move, not at a fixed point.**
`0x0043B490` applies the same skip rule as §3.1 to the slots *after* the current
one, with two extra clauses: it answers *no* outright when the current player is
already `255` — the computer moves last — and when no later slot qualifies it
answers with the solo flag, because the computer still owes a turn. When it says
no, the counter goes up and `NEXT TURN` fires.

**The two LCL events differ in what they carry.** `NEXT TURN` sets only `_B`;
`NEXT PLAYER` sets `_B` and `_C`. That is exactly the contract
[`20` §5](20-lcl-language.md) tabulates, and `0x0047D600` is the site it names
for both. Only one shipped mission reads the counter back:
`_C_153.lcl` gates two reinforcement waves on
`CheckCurrentTurn (3,15)` and `CheckCurrentTurn (15,25)` — 2 sites in 176
scripts.

**The AI runs as player 255 with a magic second argument.** In every mode but
`net session` it is `0xFE`; [`23` §2](23-ai-system.md) established that
`aAISystemControl` stores that argument and never reads it, so the value is
inert — but a remake reproducing the signature should know where it comes from.

### 4.1 `aNextPlayerHandling` — **[code] `0x0047DC60`**

The public entry point. It has four call sites, all in `aViewPlayer.cpp`, and
three parts:

```c
BOOL aNextPlayerHandling(void)
{
    for (i = 0; i < 200; i++)                      /* every slot, every owner */
        revertWeaponMode(&units[i]);               /* §7 */

    do {
        if (g_reentry) {                               /* ViewPlayer +0x00 */
            result = handOver(0);                      /* advance          */
        } else {
            g_reentry = 1;
            resetGameControl();                        /* 0x0043B770 */
            if (g_mode == 1 && !aBuildVisibleMap(0)) return FALSE;
            0x00480BC0();
            if (0x0043B1F0()) shareOutEquipmentPoints();
            result = handOver(1);                      /* search from slot 0 */
        }
    } while (g_currentPlayer == 255 && result == 1);

    switch (result) {
        case 0:  setViewState(1);  ... shut the battle down ...  break;
        case 1:
        case 3:  setViewState(0);  break;              /* this machine plays */
        case 2:  setViewState(3);  return TRUE;        /* a remote player    */
    }
    return TRUE;
}
```

The loop is what lets the computer take its turn without returning to the
interface: while the current player is `255` and the hand-over reported a normal
turn, it goes round again.

`ViewPlayer +0x00` is a re-entry latch — zero on the first call and one
afterwards — and `ViewPlayer +0x04` is the view state the switch sets. The
literals are `3` (`0x0047DDD2`), `0` (`0x0047DDE5`) and `1` (`0x0047DE3C`,
pushed from `ebx`); the AI arm inside `0x0047D600` sets `2`.

**The equipment-point hand-out** runs on the first hand-over only, and only
when `0x0043B1F0` is true — so **never in the campaign**, where the pool comes
from the mission and the roster instead ([`10` §5.11](10-lev-mission-format.md)).
It takes player 0's pool and splits it:

```c
pool = equipmentPoints[0];                          /* 0x0043AFF0(0) */
share = 0x0043B270() ? (int)(pool * (1.0 + 0.1 * humans) / humans)
                     : pool / humans;               /* humans = 0x0043B700() */
if (share < 500) share = 500;
for (i = 0; i < playerSlots; i++) setEquipmentPoints(i, share);
```

The floating-point arm hands out *more* in total the more humans there are —
`1.0` and `-0.1` are both in the constant pool — while the integer arm is a
straight split. The cap on the receiving side is **10000** (`0x0043B010`).
The floor, the cap and both floating-point constants are pinned by
`turn_tables.py`; what the pool means between missions is package B's.

---

## 5. What a hand-over restores — **[code] `0x004781C0`**

`0x00419D50` is two calls: the refresh below for the incoming player, then
`0x004312D0` for the same player. The refresh has exactly one caller.

```c
void refreshPlayer(u8 player)                    /* 0x004781C0 */
{
    aBuildVisibleMap(player);                    /* 0x004798C0 */
    for (p = 0; p < 4; p++) reactionCounter[p] = 0;   /* 0x00517F50, §6 */

    for (each of the 200 slots owned by player and alive) {
        /* --- fitness ------------------------------------------------- */
        if (u->fp != 255) {                            /* +0x19 */
            cap = maxFP(u);                            /* 0x00475120 */
            if (u->fp != cap) {
                if (u->action == 7 && u->fp + 1 < cap) u->fp++;   /* rested */
                if (bannerNearby(u)) {                 /* 0x0046FAD0 */
                    if (u->fp + 2 < cap) u->fp += 2; else u->fp = cap;
                } else if (u->fp != 0) {
                    if (u->fp + 1 < cap) u->fp++; else u->fp = cap;
                }
            }
        }
        /* --- per-turn bookkeeping ------------------------------------ */
        if (u->stimulant == 255) u->stimulant = 0;     /* +0x58, §8 */
        u->turnStartX = u->x;  u->turnStartY = u->y;   /* +0x51, +0x52 */
        u->walked     = 0;                             /* +0x50, below */
        u->rested     = (u->action == 7);              /* +0x57 */
        recomputeStats(u);                             /* 0x004759B0 */
        u->action     = 0;                             /* +0x41 */
        /* --- heat ----------------------------------------------------- */
        if (weapon[u->weapon].heat != 255) {           /* +0x3A */
            if (u->weapon == 4 || u->weapon == 6 || u->weapon == 41) {
                if      (u->heat > 1) u->heat -= 2;    /* +0x3E */
                else if (u->heat)     u->heat -= 1;
            } else if (u->heat)       u->heat -= 1;
        }
        u->ticket = 0;                                 /* +0x59 */
        revertWeaponMode(u);                           /* §7 */
        /* --- weapon malfunction --------------------------------------- */
        u->malfunction = ladder[u->malfunction];       /* +0x40 */
    }
}
```

Five things here are new or correct an earlier reading:

**Heat falls by one a turn — by two for weapon ids 4, 6 and 41.** The compiler
wrote it as three successive `sub eax, n; je`, so the ids are the running sums
`4`, `4+2`, `6+35`. They are *Double Fire*, *Rapid Fire Machine Gun* and its
alternate mode — the three rapid-firing guns. A weapon whose `heat` column is
`255` never cools because it never heats ([`21` §4](21-info-lcl-schema.md)).
[`10` §5.12](10-lev-mission-format.md) said `+0x3E` was *cleared* here; it is
decremented.

**Malfunction decays on a fixed ladder,** written as five independent tests in
ascending order so no value falls twice in one turn:

| was | becomes |
|---|---|
| 1 | 0 |
| 2 | 1 |
| 3 | 0 |
| 4 | 3 |
| 5 | 4 |

With [`10` §5.12](10-lev-mission-format.md)'s outcomes — a light jam is `2`, a
heavy one `5` — a light jam costs two turns and a heavy one three.

**Movement points are not restored here.** They are not stored: `0x00475160`
computes them on demand from the type, the equipment, the fitness and the
action state, which is [`10` §5.5](10-lev-mission-format.md)'s formula. What
this routine restores is everything that formula reads.

**Fitness moves by at most three in one turn** — one for having stood down,
then one or two for the Banner — and snaps to the cap rather than overshooting.
`0x0046FAD0` is the *Banner* test ([`10` §5.5](10-lev-mission-format.md)): a
unit of the same player, alive, carrying equipment 8, within four fields.
[`21`](21-info-lcl-schema.md)'s gloss of it as "an enemy is adjacent" is wrong
and is corrected there.

**The reaction counters are zeroed before the units are walked**, so ticket
numbering restarts every hand-over.

### 5.1 `unit[+0x50]` is the distance walked this turn

The refresh zeroes it; `aExecuteMove` is the only other routine in either
unit-owning module that writes it, and it does so once per step:

```c
u->walked += (direction >= 4 && direction <= 7) ? 15 : 10;   /* 0x0046E7B7 */
```

Directions `4`…`7` are exactly the four **diagonal** headings —
[`10` §5.10](10-lev-mission-format.md)'s angle table gives `0`…`3` as multiples
of 1024 (90°) and `4`…`7` as odd multiples of 512 (45°). So the field counts
**tenths of a field walked since the hand-over**, with the classic 1 : 1.5
diagonal cost, and it is reset rather than accumulated across turns.

Checked against a real save (§10): four computer units that had each taken one
diagonal or two orthogonal steps held exactly 15, 15, 20 and 20 — 4 of 4 — and
every unit that had not moved held 0.

That also makes its one consumer readable. [`21` §5](21-info-lcl-schema.md)
records that unit `special` `4` "may attack only while `unit[+0x50]` is 2 or
less"; since the smallest step adds 10, the threshold is not a distance budget
at all — it is **"has not moved this turn"**. No shipped unit type carries
`special` 4, so nothing in the retail game exercises it.

---

## 6. Reaction fire

[`21` §4](21-info-lcl-schema.md) settles who may go on overwatch: the weapon's
`Def Mod` column must be `1` or `4`, the unit must have two movement points, no
malfunction, ammunition, and not already be waiting. Two sites call
`0x00478500` and no others: the AI's end-of-unit pass `0x0040A710` and one arm
of `aUI.cpp`'s command switch — the **Def** button. Both are deliberate acts;
nothing puts a unit on overwatch by accident.

What is new here is the **queue**.

```c
u->action = 1;                                   /* 0x00478500 */
u->ticket = ++reactionCounter[u->player];        /* 0x00517F50 + 4*player */
```

`0x0046CCA0` is called with the unit that just moved or fired, five times in the
binary: twice from the AI (`0x0040A5AC` after a shot, `0x0040AC80` after a move)
and three times from `aUI.cpp`. It has two branches.

**In `campaign` mode it fires in ticket order, lowest first.** One pass finds
the highest live ticket; then `ebx` starts at **1** and counts up, scanning all
200 slots for the enemy unit holding that ticket, resolving its shot, and
incrementing. So the unit that went on overwatch *first* shoots first — a
first-in-first-out interrupt queue.

> [`10` §5.12](10-lev-mission-format.md) previously described this as taking
> the highest ticket, last-in-first-out. That reading mistook the
> maximum-finding pass for the selection. It is corrected there.

**In every other mode the ticket is ignored** and the 200 slots are scanned in
index order. The tickets are still written; only the drain differs.

A reaction fires when all of these hold, in this order:

| Condition | Field / routine |
|---|---|
| the reactor is alive and owned by another player | `+0x16`, `+0x45` |
| it is waiting | `+0x41 == 1` |
| it has ammunition | `+0x3D != 0` |
| its heat is below the limit | `+0x3E < 0x00475340(u)` |
| the shot has a chance | `0x0046A270` returns non-zero **and** the chance is `> 0` ([`22` §5](22-combat-and-visibility.md)) |
| a friendly `Banner` carrier is within four fields, **or** the mover is inside the reactor's 135° front arc | `0x0046FAD0` / `0x004790F0` |

then `aAttackUnit(reactorX, reactorY, moverX, moverY, 1)` — the fifth argument
marks the shot a reaction.

That last row is the one worth stating twice. `0x004790F0` takes the heading
from the reactor to the mover (`0x0046A760`) and its two neighbouring octants,
and returns true only if the reactor's own facing `+0x46` is one of the three —
a **135° front arc**, the same shape [`22` §7.4](22-combat-and-visibility.md)
uses for rear armour. A unit on overwatch covers the way it is looking, and the
`Banner` is what lifts that restriction: with a friendly carrier of equipment 8
within four fields (`0x0046FAD0`, the same test the fitness top-up uses —
[`10` §5.5](10-lev-mission-format.md)) the arc check is skipped and the unit
reacts in any direction. The reactor's facing is saved before the shot and
restored after it through `aChangeUnitViewDirection`, so a unit on overwatch
does not end up staring at whatever it last shot at. If the mover dies the
drain returns immediately.

**Nothing in the drain clears `+0x41`.** A sweep for every store into that
offset over the whole routine finds none. A unit stays on overwatch, firing at
each enemy that moves past, until either the hand-over clears it (§5) or it runs
out of ammunition or overheats — and only then is its **ticket** cleared, along
with a call to `0x004104A0`. This is the single most remake-relevant rule in
this document, and the one an implementation is most likely to get wrong by
clearing the flag after the first shot.

---

## 7. Weapon modes — **[code] `aToggleWeaponModes` `0x0047A8C0`**

`Info.lcl`'s `SetWeaponInfo2` header calls its second column **Toggle**, and
[`21` §4](21-info-lcl-schema.md) records it at record offset `+0x3D`. The
routine is one line:

```c
u->weapon = weapon[u->weapon].toggle;            /* +0x3F <- +0x3D */
```

**The column is an involution over all 42 shipped weapons.** Twenty-six are
fixed points; the other sixteen form eight pairs:

| Base | Alternate | Weapon | What differs |
|---|---|---|---|
| 6 | 41 | Rapid Fire Machine Gun | 2 AP and 2 rounds a shot instead of 1 and 1 |
| 7 | 40 | Flame Thrower | `range min` 2 instead of 1, 2 rounds a shot, its own wave file |
| 8 | 42 | Mine Thrower | no damage, no accuracy — it lays rather than fires |
| 9 | 43 | Plasma Gun | no damage |
| 10 | 45 | High Energy Laser | different skill requirement, no defence mode |
| 11 | 44 | Multi-target Destroyer | `range min` 4, more damage, 3 rounds a shot |
| 13 | 46 | Mine Thrower Enhanced | no damage, no accuracy |
| 14 | 47 | Enhanced Laser Gun | damage 1 instead of the special value 254 |

Two corpus facts make "the pair is one physical weapon" more than a reading:
both members carry the **same `icon` column, equal to the base weapon's id**
(8/8), and every alternate's **`key` column is `*`** while every base has a
distinct letter `G`…`N` (8/8). The alternate has no hotkey of its own because
it is not a separate item on the weapon list.

**The engine only ever reverts.** Three sites call the routine, and each first
checks that the weapon id is at least **20**:

| Site | When |
|---|---|
| `0x0047DC8A` | `aNextPlayerHandling`, over all 200 slots, before the hand-over |
| `0x0047836E` | the refresh, over the incoming player's units |
| `0x00477616` | unit creation |

In every pair the base is at most 14 and the alternate at least 40, so the
`>= 20` gate selects exactly the alternate member (8/8). A unit that ends its
turn in an alternate mode is put back on the base weapon; a unit on the base
weapon is left alone. Only the player's own `aUI.cpp` command (`0x00473427`)
switches *into* a mode, and it does not survive the hand-over.

No shipped `.lev` places a unit on an alternate weapon (0 of 1863).

---

## 8. Standing down, stimulants, and ending a unit's turn

Three one-screen routines complete the per-unit picture.

**`0x00478570` — stand down.** `u->action = 7; u->mp = 0`. Spending the rest of
the turn deliberately is worth one extra point of fitness at the next refresh
(§5) and sets `+0x57`, which [`10` §5.5](10-lev-mission-format.md)'s formula
turns into one extra movement point while fitness is above 1.

**`0x004785B0` — spend a stimulant.** `+0x58` holds 1 for a *Light Stimulant*
and 2 for a *Heavy* one ([`10` §5.4](10-lev-mission-format.md)):

```c
if (u->stimulant == 0 || u->stimulant == 255) return FALSE;
u->stimulant = 255;
u->mp += u->stimulant;                          /* the old value */
```

`255` means **spent this turn**, and the refresh turns it back into `0` — so a
stimulant is not consumed, it is a once-a-turn button. That closes what `255`
means in that field.

**`0x0040B380` — end a unit's turn.** The computer's per-unit epilogue
([`23` §3.3](23-ai-system.md)): point the unit at whatever `0x0047A8E0(x, y, 2)`
suggests, then zero its movement points.

---

## 9. What a remake has to implement

```
startBattle:
    turn = 0;  currentPlayer = none
    playerCount = (mode == campaign) ? 1 : 4
    soloFlag = (humanCount <= 1)

nextPlayer:
    if no player remains after currentPlayer:
        if turn == 0: initialiseMissionObjectives()
        turn = (turn + 1) % 200
        runMissionScript(NEXT_TURN, turn)
    if turn != 0:
        runMissionScript(NEXT_PLAYER, turn, currentPlayer)
        if missionEnded(): stop
    currentPlayer = advance()            # §3.1; may become 255
    refreshPlayer(currentPlayer)         # §5
    if currentPlayer == 255: runAI(255)  # docs/23
    else: handControlToTheInterface()
```

The pieces a remake must not simplify:

1. **The computer is a player in the rotation**, not a phase after the players.
2. **A skipped player is skipped by the rule in §3.1**, and never on turn 0.
3. **Overwatch persists.** It is cleared by the hand-over, by running out of
   ammunition or by overheating — not by firing (§6).
4. **The reaction queue is first-in-first-out** in the campaign.
5. **Alternate weapon modes do not survive the hand-over** (§7).
6. **Heat, malfunction and fitness each move by a fixed step per turn** (§5) —
   none of them resets.

---

## 10. Verification

`python3 tools/turn_tables.py --check gog_incubation` — **85 checks**, all
passing, over `Incubation.exe`, `DATA/Info.lcl`, 155 `.lev` and 176 `.lcl`.
(`lcl_parse --check` reports 177 because it also takes `.gcl`; the two counts
enumerate different sets by design.)
It exits non-zero on an empty corpus, on a corpus without `Info.lcl` and on one
without missions.

What the checks cover:

- **The accessor bank.** The block base and size, the 200-turn wrap and its
  reset, the player-slot counts per mode, the current-player setter's `0..4`
  plus `255`, the name stride, the equipment-point cap and floor, the
  scoreboard's base/stride/limit, the three solo-flag writers, and a sweep
  proving eight turn globals are referenced only from `aGameControl.cpp` — with
  a positive control that the same sweep does find a global outside it.
- **The mode names**, read out of `0x00433DC0`'s jump table, plus the
  distribution of literals across the ten setter sites.
- **The rotation.** Both callers of the advance, `aSearchFirstPlayer`'s start
  and bound, and the `255` the exhausted rotation stores.
- **The hand-over.** The four call sites and that they are all in
  `aViewPlayer.cpp`, the switch guard and its four-entry table, the view states
  the arms set, and the five `aRunLCL` sites with their slot and call type.
- **ViewPlayer.** The block base and size as `aSaveViewPlayer` pushes them, and
  a displacement-aware sweep giving the exact set of 18 offsets across 73 sites
  — all inside `aViewPlayer.cpp`, with 1024 bytes never addressed absolutely.
- **Weapon modes.** The column and gate at every revert site, the toggle body
  including the 67-byte record stride, the involution over all 42 weapons, the
  eight pairs, the one-member-per-pair rule, the shared icon, the `*` key, and
  that no shipped unit starts on an alternate.
- **Reaction fire.** The guard, the two fields written, the counter bank, the
  `{1, 4}` defence values and their corpus distribution, the drain's mode gate,
  its starting ticket and its two `inc`s and terminator, its five callers, and
  the sweep showing it never stores into `+0x41`.
- **The refresh.** Its single caller, the ticket bank, every field it writes
  with the value where there is one, the heat guard and the three decay ids,
  the malfunction ladder, stand-down, the stimulant, and the fitness cap
  including the compiler's `/12` magic constant.
- **The corpus.** 155 missions, 176 scripts, the two `CheckCurrentTurn` sites
  and the file they are in, the fitness cap replayed over all 1863 placed
  units, and that every one of them ships with `+0x41 = 0`.

**Mutation-tested.** 102 mutations, **0 missed** — 91 single bytes or dwords in
`Incubation.exe`, plus edits to `Info.lcl`'s toggle, icon, key, defence and
`FP max` columns, to a unit record in a `.lev`, to `_C_153.lcl`'s
`CheckCurrentTurn` bound and to its name, and to the mission and script sets.
Every check has been shown to fail under a mutation of the byte, column or file
it covers.

---

## 11. Open questions

1. **Mode 4, `pbm session`, is named but not reachable in this build.** The
   binary's own word for it is recovered (§2) and the play-by-mail passwords are
   in the save format ([`11` §5.3](11-save-game-format.md)), but all three sites
   that could select it push a register. Whether a menu path reaches it, or
   whether it survives only in the save loader, would need the register traced
   back. **Deliberately not traced:** the remake does not implement
   play-by-mail ([`92` §7](92-remake-architecture.md)) and package H is out of
   scope ([`91` §9](91-game-logic-research-plan.md)), so this stays a recorded
   fact about the binary rather than work to do. Nothing else in this document
   depends on it: mode 4 changes only the skip rule's gate (§3.1) and the
   equipment-point split (§4.1), and a campaign reaches neither.

2. **`0x0043B270`, the flag that switches the equipment-point hand-out to
   floating point.** Its setter has three call sites, all in `aMenuSystem.cpp`'s
   session setup, two of them passing a register; it has eleven readers. It is a
   multiplayer session option, and the campaign reaches neither arm of the
   hand-out, so what it is called and what the player sets it to belong to
   packages F and H. **UNVERIFIED.**

3. ~~**`unit[+0x50]`.**~~ **Closed** — §5.1. It is the distance walked this
   turn in tenths of a field, written by `aExecuteMove` and read by unit
   `special` `4`. The shipped `.lev` values 20, 35, 40 and 55 that
   [`10`](10-lev-mission-format.md) recorded are therefore leftover mid-turn
   state saved by the editor. Each is a reachable sum of 10s and 15s — `20` is
   two orthogonal steps and `35` is two orthogonal plus one diagonal, both
   uniquely; `40` and `55` each have two decompositions, so the step mix behind
   them is not recoverable from the value alone.

4. **`0x004312D0`**, the second half of `0x00419D50`, is called once per
   hand-over with the incoming player and is not described. It is interface
   state rather than turn state — package F.

The ViewPlayer block is **not** listed here. §10's sweep partitions it and the
result is tabulated where it belongs, in
[`11` §5.6](11-save-game-format.md) — fourteen fields at the front, four at the
back, and 1024 bytes reached only through a base register. That residue stays
[`11`](11-save-game-format.md)'s open item, not a second copy of it here.

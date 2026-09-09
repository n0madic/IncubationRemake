# Briefing and info text — `DATA/TXT`

The 120 `.txt` files under `DATA/TXT/<language>/` hold every word the game
shows outside the GUI string tables: mission briefings, victory and defeat
conditions, tips, the in-game database of units and weapons, event messages
and error boxes. They carry the same XOR-0xFF obfuscation as `.lcl`
([`20`](20-lcl-language.md)) and, on top of it, a markup of about six tokens.

The vocabulary is not reconstructed — the developers left it in the product.
`Info/Errors.txt` opens with a note to translators:

```
Translate only the text opened by {:xn} and closed by {*}. (xn=label, e.g. M0)
Ignore all formatcommands like {...},@ and #.
```

So `{:xy}` is a **label**, `{*}` closes it, and the brace forms are **format
commands**. Everything below uses their words.

Two readers in `C:\aProject\Project\Sources\Game\Modules\aGUI.cpp` consume the
syntax, and the difference between them is the whole of the format:
`aGetGUITextBoxString` pulls **one field**, `aCreateGUITextBox` lays out **one
block**. A label is neither a field nor a block by its syntax — it is whichever
its consumer asks for.

`tools/brief_parse.py --check gog_incubation` reproduces both readers and the
line breaker, and verifies 55 claims against 100 % of the corpus and against
the constants in `Incubation.exe`.

---

## 1. Where the files are

| Path | Files | Read by |
|---|---|---|
| `DATA/TXT/<lang>/Briefing/<mission>.txt` | 116 | the briefing, objectives and tip screens |
| `DATA/TXT/<lang>/Briefing/default.txt` | (1 of the 116) | the editor, as the template for a new briefing |
| `DATA/TXT/<lang>/Info/Data.txt` | 1 | the in-game database of units, weapons and equipment |
| `DATA/TXT/<lang>/Info/Events.txt` | 1 | `Examine...` results |
| `DATA/TXT/<lang>/Info/Campaign.txt` | 1 | **nothing** — no code names it (§7.2) |
| `DATA/TXT/<lang>/Info/Errors.txt` | 1 | **nothing** — no code names it (§7.2) |

Both path templates are built with `wsprintfA` — **[code]** `0x004C4000`
`"%sTXT\%s\Briefing\%s.txt"` and `0x004C4688` `"%s%s\Info\%s.txt"` — with the
language name coming from `aGetLanguage` (`0x00453DF0`). Only `English` ships
in the GOG release; localised releases exist and put their files under the same
template.
The mission name is the `.lev`/`.lcl` stem, so `Missions/_C_105.lev`,
`Missions/_C_105.lcl` and `DATA/TXT/English/Briefing/_C_105.txt` are one
mission's three files.

### 1.1 Obfuscation

Identical to `.lcl`: the whole file is bitwise NOT, and the decoded stream
starts with a `0x01` marker. `tools/lcl_decode.py` already reads them.

Both format strings and the fallback name are lower-case (`default.txt`) while
the shipped file is `Default.txt`, and the four `Info` names differ in case from
their files too (`campaign`, `Data`, `Events`) — the original ran on a
case-insensitive filesystem, so a remake on a case-sensitive one has to fold
case when resolving these names.

**119 of the 120 are obfuscated; `Default.txt` ships as plain text** with
neither marker nor cipher, and the loader accepts it — `aCreateGUITextBox`
runs the buffer through the same conditional deobfuscator (`0x00438E30`) that
`.lcl` loading uses. That is not an accident: §9 shows the editor creating new
briefings by copying `default.txt` verbatim, so a freshly authored briefing is
plain until someone re-saves it.

`brief_parse.py`'s `corpus.roundtrip` re-encodes every file and requires the
shipped bytes back, 120/120.

---

## 2. The markup

| Token | Name | Meaning |
|---|---|---|
| `{:xy}` | label | names the text that follows; `x` and `y` are any two bytes |
| `{*}` | — | ends the block |
| `{§n}` | format command | select font *n* |
| `{#n}` | format command | select colour ramp *n* |
| `@` | — | hard line break |
| `#` | — | indent this line to `x + 100` |
| `\|` | — | ends a **field** (§6) |

Nothing else is markup. Text outside a label block is never displayed, which is
what makes the `*` lines and the `Briefing` / `========` headers in the shipped
files work as comments — they are not syntax, just unreachable text.

The corpus contains 1234 labels, 442 `{*}`, 2347 `@`, 1700 font commands
(901 `{§0}`, 799 `{§1}`) and 627 colour commands (302 `{#0}`, 325 `{#1}`), and
exactly one brace form that is none of the above: the literal `{...}` inside
the Errors.txt note quoted above.

A typical block, from `_C_105.txt`:

```
{:A0}
{§1}Mission Description:{§0}@
{#1}
@I don't like back-shooting, but that seems to be the Gore'Ther's only soft spot.
 If we run into others, they're going to get it the same way. ...@

{#0}
@@{§1}Victory Conditions:{§0}@@
...
{*}
```

---

## 3. Finding a label — **[code]** `0x0043DDA0` `aFindGUITextBoxTag`

```c
int aFindGUITextBoxTag(int box, int *offset, char c1, char c2)
{
    *offset = -1;
    if (c1 == '#') return 0;                  /* "no label": start at 0 */
    for (i = 0; i < size; i++)
        if (buf[i] == '{' && buf[i+1] == ':' && buf[i+2] == c1 && buf[i+3] == c2) {
            *offset = i + 5;
            return 1;
        }
    return 0;
}
```

Three consequences a remake has to keep:

* **The closing brace is never checked.** Neither reader looks at `buf[i+4]`;
  both step a fixed five bytes. `{:A0X` would work exactly like `{:A0}`.
* **The first match wins.** A duplicated label makes the second copy
  unreachable — §8 has the one place in the corpus where that happens.
* **A missing label is a failure, not an empty result.** `aCreateGUITextBox`
  frees the buffer it just loaded and returns 0 (`0x0043DD66`), and the info
  activator at `0x0043E850` then retries the same file with the key `**`.

---

## 4. Laying a block out — **[code]** `0x0043D820` `aCreateGUITextBox`

The routine opens the file (`aOpenFile`, `aGetFileSize`, `aGetMemory`,
`aLoadFile` — `aGUI.cpp` lines 2036, 2054, 2064, 2074), deobfuscates it, finds
the label, and then walks the text once, recording the offset at which each
line starts. It never copies the text: the printer re-walks the same buffer.

```c
i = label_offset; brk = i; pen = 0; font = 0;
while (i < size) {
    c = buf[i];
    if (c <= 0x20 && c != '\r' && buf[i-1] > 0x20) brk = i + 1;   /* word start */
    if (c == '{' && buf[i+1] == '*') break;                       /* end of block */
    if (buf[i] == '@') { line(i); brk = i; pen = 0; i++; }        /* hard break */
    c = buf[i];
    if (c < 0x20) { i++; continue; }                              /* CR, LF, TAB */
    if (c == '{') {
        if (buf[i+1] == '#') { i += 4; continue; }                /* colour: no width */
        if (buf[i+1] != '\xa7') { i += 2; continue; }
        font = buf[i+3] - '0'; aSetFont(font); i += 4; continue;
    }
    if (pen + charWidth(font, c) > width - 8) { line(brk); i = brk; pen = 0; }
    else pen += charWidth(font, c);
    i++;
}
```

* **Wrapping happens at the last word start**, which is recorded one byte after
  a whitespace that followed a non-whitespace. **Carriage return is the one
  control character that does not count as whitespace** — so a CRLF in the
  source contributes a break candidate through its LF only.
* **`{§n}` changes the measurement, `{#n}` does not.** The colour command is
  skipped without consulting the font, which is why a colour change never moves
  a line break.
* A word wider than the whole box does not hang the loop: each overflow
  consumes one character and starts a line, so a too-long word degenerates into
  one character per line rather than looping. No shipped block does this.
* The total height reported back to the caller is `lineHeight * lines`.
* **A run of `@` starts `ceil(n / 2)` lines, not `n`.** The hard-break arm
  advances `i` and then falls straight into `c = buf[i]`, so the character
  after a break is taken unconditionally — a second `@` is an ordinary
  character, adds its own width to the pen and starts nothing. The printer
  never draws it (`0x0043E300` compares `bl` against `0x40` and jumps to the
  loop tail), so it is invisible either way. *(Drawn out 2026-09-08; the loop
  above always said it.)* This is not a curiosity: **every shipped heading
  relies on it.** `{§1}Mission Description:{§0}@` with the body's own `@` on
  the next source line is two line starts, and the second is the blank line
  under the heading that every briefing in the game has. A reader that treated
  a break as a flag rather than a count printed the whole block as a slab.
  `brief_parse.py`'s `corpus.break_lines` pins the total over all 120 files —
  **1811 lines from 2347 `@`** — and `corpus.break_runs` the rule itself.

### 4.1 The fonts — **[code]** `0x00439E20` `aGetFont`, `0x00439D60`

`aGetFont` knows exactly two ids and returns `-1` for everything else:

| Command | Handle | Library | Metrics |
|---|---|---|---|
| `{§0}` | `0x005057E8` | `Libs/font_0.LIB` | line height 12, space width 4, tracking 1 |
| `{§1}` | `0x005057EC` | `Libs/font_1.LIB` | the same |

Both are built by `aCreateLibFont(handle, path, 12, 4, 1)` at `0x00439D60` and
`0x00439DA1` (`C:\aProject\aLIB\aFont.cpp` lines 1625 and 1635). The width of
one character is `aGetCharWidth` (`0x00439B10`):

```c
c <  0x20 -> 0
c == 0x20 -> space_width + tracking          /* 5 */
else      -> glyph[c - 0x20].width + tracking
```

The glyph widths come from the shipped shape libraries ([`60`](60-lib-sprites.md)),
224 glyphs each, so the line breaking is reproducible exactly — `brief_parse.py
FILE --label A0 --layout 280` prints the wrapped text a player would see.

Only `{§0}` and `{§1}` appear in the corpus (1700/1700). Any other digit would
set the box's font to `-1`.

### 4.2 The colours — **[code]** `0x0043E445`

`{#n}` swaps the four RGB565 colours the glyph blitter uses:

| Command | Colours | Corpus |
|---|---|---|
| `{#0}` | the four the activator installed — `0xFFFF`, `0x632C`, `0`, `0` for every text box in the game | 302 |
| `{#1}` | `0x94B2`, `0x528A`, `0x0841`, `0` — green-grey | 325 |
| `{#2}` | `0xF800`, `0x6000`, `0x0800`, `0` — red | **0** |

`{#2}` is implemented and no shipped file uses it. Any other digit is ignored
and leaves the colours alone.

The four are not four shades of one outline. **The blitter maps a glyph's
pixel value straight onto this array** — `0x00447ADD`, the 16-bit path: a 1
takes `colour[0]` and everything else `colour[1]`, with 0, 3 and 4 skipped
([`60` §5.1](60-lib-sprites.md)) — and the shipped faces use only the values 1
and 2. So `colour[0]` is the ink and `colour[1]` is what the glyph's
**antialiasing** is drawn in. The fraction is 12/31 for `{#0}` and `{#2}` and
10/18 for `{#1}`.

Where the `{#0}` four come from is worth writing down, because they are not in
the box: `0x0043D891` copies them out of the descriptor handed to
`aCreateGUITextBox` at `+0x1C..+0x22`, and all four activators fill the one
global descriptor `0x0050B2B4` with the same immediates. `interface_tables.py`
reads all sixteen writes back — two of the activators store a zeroed register
rather than an immediate for the two zero entries.

### 4.3 The indent

A **bare `#`** in the text moves the pen to `x + indent` (`0x0043E19C`), and all
four activators set the indent to **100** (`0x0043E7AC`, `0x0043E8BB`,
`0x0043E9EB`, `0x0043EB27`). The corpus uses it **once**, and that once is
inside the Errors.txt translator note, i.e. never inside a block. It is a
working mechanism with no shipped data behind it.

### 4.4 Japanese

Both the measure and the print pass compare the language against `"Japanese"`
(`0x004C4144`) and, when it matches, read a **big-endian two-byte character**
(`buf[i] << 8 | buf[i+1]`), test it with `0x004807C0` and advance two bytes;
the line height becomes a fixed 12 regardless of the font record. No Japanese
data ships in this release, so the path is present, complete and unexercised.

---

## 5. Printing a block — **[code]** `0x0043E0A0` `aPrintGUITextBox`

The printer walks the same buffer from the recorded first line, advancing the
pen by one glyph at a time, dropping to the next line whenever the cursor
reaches a recorded line start, and stopping at `{*}`. Characters below `0x20`
and `@` are skipped; `{§n}` and `{#n}` are re-interpreted, so the format
commands are handled twice — once for metrics, once for appearance.

Two counters, and a limit for each, make the **typewriter effect**: the printer
counts glyphs and spaces drawn, compares each against a limit, and stops when
one is reached. `-1` means "no limit". When a space is drawn and the word
counter is below `0x0050B298`, the printer plays a sound (`0x0043E3AC` →
`0x00436EF0`) — one blip per word. `aActivateBriefingInfo`'s sixth argument
picks between the two states: non-zero installs `-1` in all four limits (the
whole block appears at once), zero installs `1` in two of them (the block is
revealed progressively).

**The rate** *(2026-09-08)*: `fcn.0043ECF0`, the box's per-frame print, adds
**one** to each limit that is not `-1` after every print (`0x0043F0AB`,
`0x0043F0C3`, `0x0043F0DA`, `0x0043F0F1`; caps 5000 for three of them and
50000 for the glyph count), so one more glyph and one more word are allowed
per printed frame — the front end's frame, 20 a second — and the blip is
`textbeep.wav`, the third buffer `aInitGUI` loads beside the two clicks
(`0x0043BFC4`). Which call sites animate is in §7.1's table.

---

## 6. Reading a single field — **[code]** `0x0043DE90` `aGetGUITextBoxString`

```c
int aGetGUITextBoxString(int box, char c1, char c2, char *out)
{
    if (!aFindGUITextBoxTag(box, &at, c1, c2)) return 0;
    for (n = 0; buf[at] != '@' && buf[at] != '|' && buf[at] != '#'; at++, n++)
        if (n == 200) { CHECK("unknow command"); return 0; }   /* aGUI.cpp:2557 */
    out[n] = 0;
    return 1;
}
```

The value is raw: no format command is interpreted, no whitespace is trimmed,
and the 200-byte cap is a hard failure rather than a truncation. The longest
field in the corpus is 59 bytes.

This is the reader that makes `{:xy}` a *field* rather than a *block*, and the
`|` in the shipped files exists only for it.

---

## 7. Who asks for what

Every text box in the game is box **2** (`0x0043ECE0` is a six-byte function
that returns the constant), so a briefing and an info box can never be open at
the same time.

### 7.1 The briefing screens — **[code]** `0x0043EAB0` `aActivateBriefingInfo`

```c
aActivateBriefingInfo(mission, x, y, width, height, animate, c1, c2)
```

If `TXT\<lang>\Briefing\<mission>.txt` does not exist it silently falls back to
`TXT\<lang>\Briefing\default.txt` (`0x0043EB64`).

All eight call sites pass literals, so the set of labels the game will ever ask
a briefing file for is **enumerable, and it is exactly three**:

| Call site | Label | Box `x, y, w, h` | `animate` | Screen |
|---|---|---|---|---|
| `0x0041B629` | `A0` | 100, 100, 387, 199 | 1 (whole) | mission start — **multiplayer only**, see below |
| `0x004577DB`, `0x0045783F` | `A0` | 190, 107, 387, 199 | — | in-mission recall |
| `0x0047CEE8` | `A0` | 100, 100, 387, 199 | — | in-mission recall |
| `0x00456DE0` | `A0` | 84, 77, 280, 276 | 0 (types) | the briefing screen |
| `0x0044EEDA` | `B0` | 220, 120, 200, 500 | 0 (types) | `Menu_a` window 10 `:Leveloptions;`, gadget 22 — the multiplayer *Infos* button, **corrected 2026-09-09**; see below |
| `0x00453990` | `B0` | 220, 100, 200, 300 | 0 (types) | the map screen, on the key `B` — the campaign's arm |
| `0x00456D96` | `C0` | 84, 77, 230, 276 | 0 (types) | the tips screen |

**`0x0043B1F0` is a multiplayer predicate, and this paragraph used to have it
backwards** *(corrected 2026-09-09)*. It answers `[0x00509F08] && (gameMode()
== 2 || gameMode() == 4 || (gameMode() == 3 && humans > 1))`, and a campaign is
`gameMode() == 1` (§6.2 of [`27`](27-campaign.md) and the twelve sites it
enumerates), so **the predicate is false in every campaign**. The two call
sites above are its two arms and they are exact complements:

* the map's `B0` (mission control's action `0xb`) needs `humans == 1 &&
  !predicate` — the campaign's case, so a campaign **does** draw it;
* the mission-start `A0` popup is the arm `0x0041a980` takes when the
  predicate is non-zero — so a campaign **never** does.

The popup is behind a second gate besides, and reading it whole is what settles
the strength panel too *(2026-09-09)*. The flag is `0x005106D4`: `0x004538E0`
reads it, `0x004538F0` clears it, and **its only writer in the whole image** is
`0x004539C1` — the arm the map's `B` takes when its own gate fails. So the two
routines are one feature with three outcomes:

```c
/* 0x00453961, the map's `B` */                 /* 0x0041B5FE, the mission's first frame */
if (humans() == 1 && !predicate())              if (!flag)            /* nothing at all */
     draw B0 at (220,100,200,300);              else if (predicate()) draw A0 at (100,100,387,199);
else flag = 1;                                  else                  aDrawStrength(0x0045FA00);
```

`humans()` is `0x0043B700`, and it is a **count and not a flag**: it walks the
player-kind slots at `0x00509E20`, bounded by `0x0043B310`'s player count at
`0x00509E30`, and returns how many hold `1`. That distinction is the whole of
it. One human on a machine with no network never arms the flag, so a campaign
draws neither the popup nor the panel; a network session arms it and gets the
full briefing; and **the panel is the hot-seat shape** — two or more humans on
one machine, where the flag is armed and the network predicate is still false.

The key is `B` itself: `0x00451240` maps the character to action `0xb` through
the jump table at `0x004513E4`, whose fifteenth arm is `mov esi, 0xb`.

The remake follows the one-human arm — `B` on the location map draws the `B0`
box — and has no way to be more than one human, so it draws no mission-start
popup and no strength panel, and there is nothing to arm the flag with. That is
faithful absence rather than a gap ([`92` §7.19](92-remake-architecture.md)).
`seq_parse.py --check` pins all of it: both halves of the `B` gate, the flag's
single writer with its reader and its clear, and `0x0041A980`'s branch into
`0x0045FA00`.

**`0x0044EEDA` is not the deployment screen** *(corrected 2026-09-09)*. The row
above said "unit selection" and it was a guess: the site is inside
`aMenuSystem`'s gadget dispatcher `0x0044DCD0`, whose outer switch is on
`[0x50FDF8]` — and that global is **`Menu_a`'s** `_A_WindowSelector`, not
`Menu_b`'s. What says so is a writer rather than the arm count: `0x0044D2F4`
pushes `GUI\Menu_a.LCL`, loads it, and `0x0044D37C` sets the global to **7**,
which is `Menu_a`'s `07_MainMenu`. Window **10** is therefore
`:Leveloptions;`, its arm is `0x0044EB52`, and the gadget that reaches the
`B0` activation is **22** — `GUI_SetButton (22_gdtID, …135_WinText…)`, which
`Menu_a.lcl` comments `* infos`. So the short briefing appears there on the
*Infos* button of the **multiplayer level-options screen**, on the DirectPlay
path.

`SelectUnits` is a `Menu_b` window and **no `aActivateBriefingInfo` site lies
in its arm at all**: of the eight call sites in the image, exactly one is
inside the dispatcher and it is this one. `seq_parse.py --check` pins the
whole chain — the writer that names `Menu_a`, the dispatcher's switch, window
10's own gadget switch, the index table's entry for 22, and the list of eight
sites — because this is the second thing in this document to have been
attributed to a screen by name instead of by arm.

The files' own comments name them: `A0` is the *full briefing*, `B0` the *short
briefing (only the victory and defeat conditions)*, `C0` the *tips*. Every one
of the 116 briefings has `A0` and `B0`; 91 have `C0`.

Laid out against the shipped fonts, **`B0` fits its box in 116/116 files and
`C0` in 91/91**, while `A0` overflows the 280×276 briefing box in 6 of 116 — so
only the full briefing ever needs the scroll bar.

### 7.2 The info boxes

| Routine | Address | Mode | Used for |
|---|---|---|---|
| `aActivateInfo` | `0x0043E740` | caller's | the pickup sequence `0x00410780` ([`26` §3](26-interaction.md)) and the `ActivateInfo` LCL command ([`20` §6](20-lcl-language.md)), which no shipped script uses |
| — | `0x0043E850` | 2 | `Data.txt` (three call sites) and `Campaign.txt`; **this is the one that retries with `{:**}`** |
| `aActivateDialogInfo` | `0x0043E980` | 3 | the dialogue screens |

`Data.txt`'s labels are letter + digit, and the digit is the category: the three
call sites at `0x00432B56`, `0x00432BBD` and `0x00432C1A` pass `'0'`, `'1'` and
`'2'` for units, weapons and equipment, with the letter taken from a per-record
table at `0x0051C09D`. Hence `{:A0}` = *Ray'Ther*, `{:B0}` = *Gore'Ther*, and so
on, and `{:**}`, `{:*1}`, `{:*2}` are the three *"No information available."*
fallbacks — of which only `{:**}` is ever asked for, the retry at `0x0043E910`
pushing two literal stars whatever the family digit was.

The `'0'` site is the **battle interface's magnifying glass**, not a screen:
`0x00432B20` is reached from the click handler while event 13's mode is on, and
its box is `230, 200, 180, 300` ([`43` §5.2.1](43-battle-hud.md)). The two item
sites refuse a record whose letter is `#` before they open the file
(`0x00432B86`, `0x00432BE4`); **the unit site makes no such test**, so a `#` and
a letter with no block both come back as the `{:**}` retry.

`Events.txt` uses `E0`…`EC` and is opened by the literal `"Events"`
(`0x004C1304`) at `0x004107AC`. The pickup sequence's call is fully literal
too — `aActivateInfo("Events", 230, 200, 180, 400, c1, c2, 0)`, the four
numbers pushed at `0x004107A2`, `0x0041079D`, `0x00410798` and `0x00410793` —
so the box is **180 wide at (230, 200)**, and its 400 of height is a layout
bound rather than a drawn rectangle, exactly as the 500 of the `B0` box above
is on a 480-line screen. The eighth argument is 0, so the block is revealed a
word at a time (§5).

**What takes it down, and what it holds up.** `0x0050B2B0` is *a text box is
open*; while it is set, the mission's input handler returns at `0x0041BB44`
without doing anything, so nothing else in the mission answers. The mouse
dispatch of the same routine biases by `0x201` and bounds at 5, and its cases
`0x204` and `0x206` — `WM_RBUTTONDOWN` and `WM_RBUTTONDBLCLK` — call
`0x0043F130`, which kills box 2 and clears the flag. **The right button is
the only thing that closes it**; `0x0043F250` clears the same flag as part of
the mission teardown at `0x0041A830`. The remake answers *any* mouse button,
which takes nothing away: the left click the original swallows here does
nothing at all. It also **takes the box down after five seconds** of its own
accord (`MissionHud.INFO_AUTO_HIDE_SECONDS`, stepped by the host's frame),
which the original does not: with the mission held behind it, a crate opened
by mistake stops the game until the box is noticed and pressed. The dismissal
stays exactly as it is; the timeout is the floor under it, and it does not run
while a screen the player opened covers the mission. **It applies to a box
that arrived by itself and not to one that was asked for**: the magnifier's
page ([`43` §5.2.1](43-battle-hud.md)) is opened by a click on a chosen alien
and is prose to read, so it stands until it is dismissed, exactly as the
original's does.

**Two of the four info files are unreachable in this build.** `Data` and
`Events` are the only info file names that exist in `Incubation.exe` as
standalone strings; `Errors` and `Campaign` do not (the only `campaign` in the
image is `0x004C33EC`, the session-type word that sits beside `net session`,
`local session` and `pbm session`). The same scan finds `Data` and `Events`, so
this is an enumerated absence rather than a failed search. The only routes that
could pass a name at runtime are the two LCL commands `ActivateInfo`
(`0x00441070`) and `ActivateInfoSuccessor` (`0x00441110`), and
[`20` §6](20-lcl-language.md) records **no call site for either in any shipped
script** — `info.lcl_sites` re-checks that over all 178 decoded scripts. Consistently, the two files read as placeholders: `Campaign.txt` says
*"Upgrade location 1."*, *"Battle location 23."* for all 49 of its labels, and
neither file's text appears anywhere else in the shipped data.

`aActivateDialogInfo`'s one hard-coded site (`0x0045C6B0`) asks for
`Info\dialog_1.txt` (`0x004CADC4`), and no `dialog_*.txt` ships either.

`Errors.txt` is still the most valuable of the four, because it is where the
developers wrote down what the markup is called.

---

## 8. The briefing program — **[code]** `0x00456950`, `aMissionControl.cpp`

The bottom of every briefing file is a table the authors label *Briefing
Program 10-40* and *Tip Program 50-90*:

```
PIC {:00}br_100_0| X {:01}430| Y {:02}100| DESC1 {:03}Destroy all Scay'Ger.|
PIC {:10}Bratt|    X {:11}457| Y {:12}220| DESC1 {:13}Corporal Bratt must survive.|
```

`PIC`, `X`, `Y` and `DESC1` are decoration: only the labels matter. The screen
builds the two label characters arithmetically — `c1 = '0' + row`, `c2 = '0' +
column` — and reads each with `aGetGUITextBoxString`:

| Column | Read as | Consumer |
|---|---|---|
| 0 | picture name | `%sBriefing\%s.bmp` → `aPrintBitmap` (`aMissionControl.cpp:3462`) |
| 1 | X | `atoi` |
| 2 | Y | `atoi` |
| 3, 4, 5 … | description lines | printed under the picture until one is missing |

The base row is 0 for the objectives screen and **5** for the tips screen,
selected by `0x00510BAC` at `0x00456983` — exactly the `10-40` / `50-90`
numbering in the authors' comments. The row loop stops at the first **missing
picture**; a missing X or Y does not stop it (the engine keeps whatever the
register held), and no shipped file omits one, so that path is never exercised.

The corpus holds **198 entries across 75 files** — rows 0/1/2 for objectives and
5/6/7/8 for tips — every one with all four columns, every coordinate inside
640×480, and the longest field 59 bytes against the 200-byte cap. The remaining
41 briefing files carry no program at all.

**Two authoring bugs are visible in the shipped data**, and both follow from
the rules above rather than from any guess:

* `_C_132.txt` gives the tip picture the name `No` — there is no
  `Graphics\Briefing\No.bmp`, so the load fails and the release build, whose
  `CHECK` macro is compiled out, draws nothing.
* `_C_180.txt` writes `{:13}` where the third row's description should be
  `{:23}`. Because the first match wins (§3), row 2 shows row 1's text
  *"...and after."* and the intended *"Kill all Scay'Ger."* is unreachable.

The last thing the routine does is read the label `OC` into a scratch buffer
(`0x00456CC7`) and return whether it was found. No file defines `{:OC}`, so the
call always fails — and the GUI dispatcher discards the return value
(`0x0043C65A`: `test eax, eax; je; call eax`, the result unused). It is dead.

---

## 9. Where `Default.txt` comes from

The retail `Incubation.exe` still contains the Map Designer, and its window
procedure (`0x00437560`) implements the menu item **`Edit &Briefing File`** —
one of 38 items in the menu resource, alongside `Set Action Points` and
`Edit &LCL Program`, and the same authoring UI that [`10`](10-lev-mission-format.md)
reads dialog 120 from. The handler:

1. builds `TXT\<lang>\Briefing\<mission>.txt` and tests it (`0x00438980`);
2. if it is missing, says *"No briefingfile found!\nCreate defaultfile."*,
   copies `TXT\<lang>\Briefing\default.txt` over it, and says
   *"Defaultbriefingfile not found!"* if even that is absent;
3. runs `NotePad.exe <path>`.

That is the whole authoring story for this format: a text file edited in
Notepad, seeded from a template. It also explains why `Default.txt` is the one
file in the corpus that is not obfuscated, and why the loader has to accept
both forms.

---

## 10. Verification

`tools/brief_parse.py --check gog_incubation` — **55 checks**, all against
either 100 % of the corpus or a named address in `Incubation.exe`:

* the corpus shape (120 files, 116 + 4), the obfuscation and a byte-exact
  re-encode of every file;
* the token vocabulary, with the counts above, and the assertions that the only
  non-token brace form is the note in `Errors.txt` and the only duplicate label
  is `_C_180`'s;
* every `A0`/`B0`/`C0` block present and closed (323/323);
* the 198 program entries: coordinates, the 200-byte cap, and every picture
  name resolved against `Graphics/Briefing` except the one named above;
* the layout of all 323 blocks against the shipped `font_0.LIB` and
  `font_1.LIB`, and the box each is displayed in;
* the two info file names that exist in the binary, the two that do not (with
  the positive control that the same scan finds the first two), the four
  shipped stems and the dialogue box's missing file;
* and, in the binary, the label scan, the three field terminators, the 200-byte
  limit, the eight markup comparisons, the two font slots with their library
  names and metrics, the two colour ramps, the indent, the box id, the three
  path templates, the `**` fallback, and all eight briefing call sites with
  their literal geometry and labels.

Mutation-tested: 34 single-byte or single-token mutations of the binary, the
text files, the bitmaps and the font libraries, each detected by the check that
covers it. The check fails on an empty corpus.

---

## Open questions

**None.** The format is fully specified: every token is decoded, both readers
are reproduced byte for byte, the line breaker is reproduced against the
shipped fonts, and the set of labels the game can ask for is enumerated from
the call sites rather than inferred from the data.

Three things are *unexercised* rather than unknown, and each is closed with the
evidence:

1. **`{#2}`, the red colour ramp** — implemented at `0x0043E458`, used by no
   shipped file (0 of 627 colour commands).
2. **The `#` indent** — implemented at `0x0043E19C` with an indent of 100 set
   by all four activators; the corpus's single bare `#` is inside a comment.
3. **The Japanese two-byte path** — complete in both the measure and the print
   pass (§4.4); this release ships only `English`.

Two are dead:

* the `{:OC}` read at the end of the briefing screen (§8), whose return value
  the GUI dispatcher discards; and
* `Errors.txt` and `Campaign.txt` themselves (§7.2) — shipped, placeholder
  data that no code in `Incubation.exe` can name.

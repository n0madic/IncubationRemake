# LCL — the Incubation mission-scripting language

Reference for the little interpreted language used by Blue Byte's *Incubation*
(1997) for mission logic, GUI layout and localised text tables.

**Scope and provenance.** This document is derived from three evidence sources:

1. **The interpreter itself**, recovered by decompiling `Incubation.exe`. The
   original sources were `C:\aProject\Project\Sources\Game\Modules\aLCL.cpp`
   (core) and `aLCL_Com.cpp` (command implementations); those path strings
   survive in the release binary's assertion sites, which is how the command
   implementations were identified. Every claim tagged **[code]** cites the
   function address it was read from.
2. **The shipped corpus** — all 176 `.lcl` files under `gog_incubation/`,
   decoded with `tools/lcl_decode.py` and parsed with `tools/lcl_parse.py`.
   All counts come from a single AST pass over those files.
3. **`Incubation.exe`'s string pool** — the command-name table and the
   diagnostic messages.

The key functions are:

| Address | Role |
| --- | --- |
| `0x0043f540` | `aInitLCL` — load and de-obfuscate a program |
| `0x0043f6e0` | **the interpreter's main loop** |
| `0x0043ff00` | token reader |
| `0x0043fc90` | parameter-list parser |
| `0x0043fc10` | reset the parameter arrays (per statement) |
| `0x0043fc70` | reset the local-variable array (per invocation) |
| `0x00440200` | skip whitespace |
| `0x00440130` | skip to the next CRLF (comment skipper) |
| `0x00440e00` | `Goto` |
| `0x00442de0` | command dispatcher (93 commands + `%`) |
| `0x00444820` | predicate dispatcher (14 predicates) |
| `0x004402a0` | host API: set an environment variable |
| `0x00453e00` | the diagnostic reporter — **an empty stub in the release build** |

Anything not readable from the code or from the corpus is marked
**UNVERIFIED**, and §10 lists every remaining such point.

> **Note on the diagnostics.** All of `aLCL.cpp`'s error strings
> (`Unknown command: %s / Line %d`, `Unknown label: Line: %d`,
> `Unknown oder damaged condition: %s / Line %d`, `LCL_Vars:%d,…`, …) are
> present in `.data` but **referenced by nothing** in the shipped
> `Incubation.exe` or `iDesigner.exe`: the reporter `0x00453e00` compiles to
> `ret`. They are debug-build residue. They are still useful as labels for the
> corresponding code paths, but they tell you nothing about release behaviour,
> and `LCL_Vars` in particular is *not* evidence about array sizes.

---

## 1. File inventory and loading

`.lcl` files are plain ASCII (Windows-1252 in practice — the corpus contains
German umlauts and typographic apostrophes).

| Location | Files | Role |
| --- | --- | --- |
| `Missions/` | 153 | One mission script per map (`_C_*` campaign, `_O_*`/`_S_*`/`_M_*` other modes, `upgrade_*` upgrade maps). |
| `WorldDesc/` | 10 | `A00`–`J00`: object catalogues, one per world. Their own banner says *"!!! Only for Debugversions !!!"*. |
| `DATA/GUI/` | 3 | `Menu_a.lcl`, `Menu_b.lcl`, `Menu_c.lcl` — GUI window layouts. |
| `DATA/TXT/English/GUI/` | 9 | `Txtmod_a…h.lcl`, `Campaign.lcl`, `Mission.lcl` — localised text tables. |
| `DATA/Info.lcl` | 1 | Global game database — see `docs/21-info-lcl-schema.md`. |
| **Total** | **176** | |

### 1.1 Obfuscation — **[code] `0x00438e30`**

The loader reads the whole file, then calls a two-way scrambler with
marker `0x01` and key `0xFF`:

* **Decode** (what the game does): *if the first byte is `0xFE`*, shift the
  buffer left by one and XOR every byte with `0xFF`; the length drops by one.
  If the first byte is anything else the file is used verbatim.
* **Encode**: prepend `0xFE`, XOR the rest with `0xFF`.

So `0xFE` is the "this file is scrambled" marker and it is **removed** from the
executed buffer — the program text starts at the first real character. The ten
`WorldDesc/*.lcl` ship unscrambled. `tools/lcl_decode.py` implements exactly
this.

### 1.2 Limits — **[code] `0x0043f540`, `0x0044af30`**

* A program file may be at most **29 999 bytes** (`0x752f`) — this is the
  `LCL to large (%d)` path. The largest shipped file is 24 145 bytes.
* At most **101** programs may be loaded at once (`0x0044af30` scans ids
  0..100 for a free slot), but the interpreter refuses to run any id above
  **99**, so a program that lands in slot 100 is loadable and never executable.
* The per-program record is 74 bytes (`0x4a`) at `0x0050de50`: `+0` in-use flag,
  `+4` buffer pointer, `+8` length.

### 1.3 The line ending matters — **[code] `0x00440130`**

The comment skipper advances until it sees the two-byte sequence `\r\n`. A file
with bare `LF` line endings would run off the end of the buffer on its first
comment and abort. All 176 shipped files use CRLF; a remake's editor must
preserve that.

---

## 2. Execution model — a single linear pass with one condition flag

This is the most important thing to get right, and it is not what the shape of
the language suggests. **[code] `0x0043f6e0`**

The interpreter holds exactly two pieces of state:

* `pos` — a cursor into the program buffer, starting at **0**;
* `flag` — one boolean, initialised to **true**.

and loops:

```
flag = true;  pos = 0;  reset_local_vars();       // 0x0043fc70
loop {
    skip_whitespace();                            // 0x00440200
    switch (buffer[pos]) {

      case '>':  pos++; name = read_token(); parse_params();
                 flag = eval_predicate(name);              break;
      case '&':  pos++; name = read_token(); parse_params();
                 flag = flag & eval_predicate(name);       break;
      case '|':  pos++; name = read_token(); parse_params();
                 flag = flag | eval_predicate(name);       break;
      case '<':  pos++; flag = true;                       break;
      case '#':  pos++; flag = (flag != 1);                break;

      case '*':  skip_to_end_of_line();                    break;
      case ':':  pos++; read_token();      /* label: no effect on flag */ break;
      case '[':  pos++; if (read_token() == "END") stop;   break;

      default:   name = read_token(); parse_params();
                 if (flag) dispatch_command(name);         break;
    }
}
```

Consequences, all of which a correct remake must reproduce:

* **There is no skipping and no block structure.** Every construct is *parsed*
  on every pass, whatever the flag says; only the final `dispatch_command` is
  gated. Conditional "regions" are an illusion produced by `>` … `<`.
* **Conditions cannot nest**, and there is nothing to nest: `>` *assigns* the
  flag rather than pushing anything.
* **`&` and `|` fold strictly left to right, with no precedence.** A chain
  `>A &B |C &D` evaluates as `((((A) & B) | C) & D)`. This settles the question
  the corpus could not: `&` does **not** bind tighter than `|`.
* **Predicates are always evaluated**, even when the flag is already false —
  there is no short-circuit.
* **`<` is unconditional**: it sets the flag true regardless of what it was.
* **`[END]` is not gated by the flag.** An `[END]` reached inside a false
  region still stops the program. No shipped script does this: the parser's
  "`[END]` inside an unclosed conditional" diagnostic fires zero times over the
  176-file check.
* **A label does not touch the flag**, and neither does a comment.
* **Execution starts at byte 0**, not at `[LCL]`. `[LCL]` is simply a `[`
  directive whose name is not `END`, so it is ignored; everything before it is
  executed too. Nineteen files carry a banner before the header (the ten
  `WorldDesc/*.lcl`, `Campaign.lcl`, `Mission.lcl` and seven `Txtmod_*.lcl`)
  and every line of every one of them is a `*` comment, so this is harmless in
  practice — but a generator must keep it that way.

### 2.1 `#` is `else`, not a comment — **[code] `0x0043f6e0`, case `'#'`**

`#` consumes one character and sets `flag = (flag != 1)` — a logical NOT. Inside
a `>` … `<` region that is exactly an **else** branch, and the shipped scripts
*use it as one*. `Missions/_O_066.lcl:195`:

```
>VarCmpNum (_F,36);
 |VarCmpNum (_G,36);
 ... five more '|' terms ...
	SetVarNum (_K,1);
 	#SetVarNum (_K,0);
<
```

Read as a comment this sets `_K` to 1 when any term matches and leaves `_K`
alone otherwise; read as `else` it sets `_K` to 1 or 0. The next region is
`>VarGreaterNum (_K,0);`, which only makes sense with a definite 0. The same
pattern in `Missions/_C_115.lcl:75`:

```
>NoUnitOnField (6,15);
 |NoUnitOnField (12,7);
  SetActPt (0,1,101);
# SetActPt (0,1,100);
<
GetActPt (_O,0,1);
```

— the elevator logic immediately below tests `_O == 101`, so the else branch
must write 100. All **eight** `#` sites in the corpus are the last statement of
a region and are immediately followed by `<`.

Outside a region `#` would flip the standing true flag to false and so disable
every statement until the next `>`, `<` or `#`. No shipped file does that.

### 2.2 Errors abort the invocation

Every failure path in the main loop is "report, then `return 0`": a malformed
token, an unparsable parameter list, an unknown command name, an unknown
predicate name, a `Goto` to a missing label. There is no per-line recovery —
the run of that program stops there. Because the reporter is an empty stub in
the release build, the failure is completely silent; the host simply gets a
zero return and carries on. The earlier reading of these diagnostics as
"skip the line and continue" was wrong.

Two consequences worth noting:

* Parameter lists are parsed **before** the flag is consulted, so a syntax
  error inside a false region still kills the program.
* A newline inside any token — including inside a string literal — is a hard
  error (**[code] `0x0043ff00`**, cases `'\n'`/`'\r'`). Tokens must close on
  the line they open on; whitespace *between* tokens may include newlines.

### 2.3 `Goto` — **[code] `0x00440e00`**

`Goto` is an ordinary entry in the command table (it is *not* a parser
keyword). It is therefore gated by the flag like any other command. Its
implementation:

```
pos = 0;
loop {
    skip_whitespace();
    if (buffer[pos] != ':') { skip_to_end_of_line(); continue; }
    pos++;
    if (read_token() == target) { skip_to_end_of_line(); return; }
}
```

So a jump **restarts the scan from byte 0 of the file and takes the first
match**, and only a `:` that is the first non-blank character of a line counts
as a label. Duplicate labels are reachable only in their first occurrence.
A missing label falls off the end of the buffer and aborts the program.

Note that `Goto` does not touch the condition flag either — it is left at
whatever the guarding `>` set it to, which is why the standard dispatcher
(`>cond; Goto(x); <`) closes each line with `<`.

---

## 3. Lexical structure

### 3.1 Tokens — **[code] `0x0043ff00`**

One routine reads every name, number and string. It fills a buffer (max 100
characters) and stops at the **first** of

```
(   )   ,   :   ;   ]
```

outside a string literal, **consuming** that character. `"` toggles an
in-string state and also sets a "this token was quoted" flag; while quoted, the
six terminators above are ordinary text. Spaces and tabs before the first
quote are skipped, so `Foo ( a , b )` reads the same as `Foo(a,b)`. `\n` or
`\r` anywhere inside a token is a hard error.

That single rule explains several things the corpus alone left open:

* **Label terminators.** `:Name;` and `:Name:` both work because the name
  simply ends at the first terminator — and so would `:Name,`, `:Name)` or
  `:Name]`. The corpus uses `;` (952 labels) and `:` (150, including
  `:MoveUnit:` in 149 of the 153 missions).
* **`[END]`** is `[`, then a token that ends at `]`.
* **The `;;` of a text entry** is not a special terminator: the first `;` is
  eaten as the string token's terminator, the second one ends the parameter
  list (§6).

### 3.2 Parameter lists — **[code] `0x0043fc90`**

With the cursor just past the command name:

```
reset_param_arrays();                    // 0x0043fc10
loop {
    skip_whitespace();
    if (buffer[pos] == ')') pos++;
    if (buffer[pos] == ';') { pos++; return; }
    tok = read_token();
    classify_and_store(tok);
}
```

so a parameter list runs to the first `;` at a token-start position, and `,`,
`)` and `(` are all just token terminators. Three separate arrays receive the
arguments, **each with its own running index**:

| Kind | Test | Storage | Capacity |
| --- | --- | --- | --- |
| variable | unquoted, first char `_` | slot index `tok[1] - 'A'`, must be 0..27 | 21 entries at `0x0050bea0` |
| number | unquoted, `tok[0] < ':'` and `!= ';'` (digits, `+`, `-`) | `atoi(tok)` | 21 entries at `0x0050bef8` |
| string | anything else | copied verbatim | 11 slots × 100 bytes at `0x0050b8c0` |

This is why the command reference below indexes arguments **per kind**:
`SetVarNum (_E, 1)` puts slot `E` in `var[0]` and `1` in `num[0]`;
`InsertUnit (255, 50, "", 0, 0, 9, 7, 2)` puts seven values in `num[0..6]` and
the empty name in `str[0]`.

Further consequences:

* **`atoi` is the number parser**, so leading zeros are decimal (`01` is 1, not
  octal), a leading `-` works, and everything from the first non-digit onward
  is ignored. That is the whole mechanism behind the `_Annotation` convention
  (§3.4): `01_Calltype` is `atoi("01_Calltype") == 1`.
* **A missing argument reads as `-1`**, because `0x0043fc10` fills both numeric
  arrays with `-1` and all eleven string slots with `""` before every statement.
  This gives the short command forms a defined meaning — e.g. the two-argument
  `SetActPt (x,y)` stores `(byte)(-1) = 255`.
* An unquoted token whose first character is a letter becomes a **string**
  argument. That is how `Goto (EndGame)` passes its label name.

### 3.3 Comments

`*` opens a comment that runs to the end of the line — **[code] `0x00440130`**,
which scans for the CRLF pair. Because it is handled by the main loop's
`switch`, `*` is only a comment introducer where the loop is looking for the
*next construct*: at a line start, or right after `;`, `<`, `>`, `(`, `)` etc.
There are zero occurrences in the corpus of `*` in the middle of an argument
list, so a tokenizer may treat it as a comment wherever it looks for a token
and needs no special handling elsewhere. `*` inside a string literal is
ordinary text (`SetWeaponInfo2 (23,"AW_SP2",23,1,0,"*");`).

Trailing comments are common and decorative banners (`**[Use]**`, rows of
`***`) exploit the same rule.

**`#` is not a comment.** See §2.1.

### 3.4 The `_Name` annotation convention

Both variable references and numeric literals may carry a trailing
`_HumanReadableLabel` that the interpreter ignores — see §3.2 for why.

```
EnvVarCmpNum (_A_Calltype,01);                  ← env slot A, annotated "Calltype"
GetActPt      (_A_Term1,16,5);                  ← local slot A, annotated "Term1"
GUI_SetListbox(0_gdtID,0_fntID,11_WinText,12_Library,130_x,130_y,12_Width);
EnvVarCmpNum (_A_WindowSelector,02_First Player);   ← the label may contain spaces
```

`DATA/GUI/Menu_a.lcl:37` proves the annotation is dead text:

```
>EnvVarCmpNum(_A_WindowSelector,16_Credits);   Goto(Campaign);   <
```

The annotation says `Credits`, the jump goes to `Campaign` (line 36 carries
`15_Credits` and jumps to `Credits`).

### 3.5 Overall shape

```
<anything, ignored — but executed, so keep it to '*' comments>
[LCL]
  <dispatcher statements>
[END]

:Label;
  <statements>
[END]
```

Every one of the 176 files contains exactly one `[LCL]`, and 1122 `[END]`
tokens in total. `[END]` ends the *invocation*, not the file; text after the
last `[END]` is simply never reached. No GOG file carries anything after its
final `[END]`; the 1C Russian release's `Txtmod_a.lcl` (verified by hand
2026-09-13, no automated check) ends `[END]\x1a` — a DOS end-of-file mark
*inside* the obfuscated stream. The parser reports bytes after the final
`[END]` that are all whitespace or C0 controls as one warning
("N unreachable byte(s) after the final [END]") rather than a syntax error,
and does **not** strip them in the codec, so `decode(encode(x)) == x` holds;
`lcl_parse.py --check` carries the synthetic case.

### 3.6 Literals

**Strings** are `"`-delimited with **no escape sequences**. They may contain
`*`, `#`, `<`, `>`, `'`, spaces and non-ASCII bytes, but not a newline.

**Numbers** are decimal integers, possibly signed, possibly with cosmetic
leading zeros. Observed range across the corpus: `-2112` … `16280`. There is no
hexadecimal form (zero occurrences of `0x`). Values are stored as 32-bit ints
by the parser but most commands truncate them to a byte.

---

## 4. Variables

Two arrays, both addressed with the same `_X` syntax, distinguished by which
command family touches them.

| Array | Base | Size | Read by | Written by |
| --- | --- | --- | --- | --- |
| **Local / program vars** | `0x0050b850` | **28 × int32** | `VarCmpNum`, `VarCmpVar`, `VarGreaterNum`, `VarLowerNum` | `SetVarNum`, `SetVarVar`, `SetVarRandom`, `VarAddNum`, `VarAddVar`, `VarSubNum`, `VarSubVar`, and every `Get*` |
| **Environment vars** | `0x0050bf70` | ≥ 27 × int32 | `EnvVarCmpNum`, `EnvVarGreaterNum`, `EnvVarLowerNum` | host only, via `0x004402a0` |

### 4.1 Array size — settled — **[code] `0x0043fc70`, `0x0043fc90`**

`0x0043fc70` clears **28** dwords starting at `0x0050b850`, and the parameter
classifier accepts a slot index of `0..27` (`tok[1] - 'A' <= 0x1b`). 28 slots
× 4 bytes = `0x70`, which lands exactly on the string-parameter array at
`0x0050b8c0`. So the local array is **28 entries**: `_A` … `_Z` plus two
otherwise-unreachable slots for `_[` and `_\`.

**The save game persists only 109 of those 112 bytes.** `aSaveLCL`
(`0x004406b0`) and `aLoadLCL` (`0x004406f0`) both use `0x6D`, so a save
round-trips and nothing looks corrupt — but `109 = 27 * 4 + 1`, which means
slots 0…26 survive whole and slot 27 keeps only its lowest byte, the upper
three carrying over from whatever was in memory. Since the corpus never goes
past `_Y` this is invisible in the shipped campaign; see
[`11-save-game-format.md`](11-save-game-format.md) §5.9.

The corpus's use of `_A` … `_Y` (25 slots) is therefore entirely in bounds. The
`LCL_Vars:%d,…` format string with its 15 conversions is debug-build residue
from `PrintAllVars`, which compiles to a bare call to the empty reporter in the
release build; it carries no information about the array.

The environment-variable setter `0x004402a0` takes the slot **letter** and
range-checks `letter - 'A'` against `0..26`, i.e. `_A` … `_Z` are all valid.
Reads go through the same 0..27 classifier as locals.

### 4.2 Locals are reset per invocation — **[code] `0x0043f6e0`**

`0x0043fc70` is called once, before the loop, on **every** program run. It
fills all 28 slots with **`-1`**, not 0. Local variables therefore do **not**
persist between invocations of a mission script, and a read before the first
write yields `-1`. Persistent per-mission state is what the map's per-cell
"action point" store is used for (`GetActPt`/`SetActPt`, §7.4).

### 4.3 Only the first one or two variable arguments are used

Every variable-touching command reads `var[0]` (and `VarCmpVar`, `VarAddVar`,
`VarSubVar` also `var[1]`). They index the local array directly with no bounds
check at use time — the check happened during parsing.

---

## 5. Entry points

The host writes a **call type** into environment slot `_A` and runs the
program. **[code]** — the calls to `0x004402a0` in the release binary give the
complete contract:

| Call type | Label | Environment variables the host actually sets |
| --- | --- | --- |
| 1 | `NextPlayer` | `_B` = turn, `_C` = player |
| 2 | `MoveUnit` | `_B` = the unit's x, `_C` = its y, `_D` = the cell's height field / 160 ("z-position in 10 cm" in the corpus comments), `_E` = the cell's ActPt, `_F` = the cell's unit index |
| 3 | `Attack` | `_B` = attack x, `_C` = attack y |
| 4 | `Use` | `_B` = use x, `_C` = use y, `_D` = the cell's ActPt |
| 5 | `NextTurn` | `_B` = turn |
| 6 | `InitMap` | *(none)* |
| *(free)* | *(free)* | set by the `Dialog` command — see §5.2 |

The call sites are `0x004195a0` (InitMap), `0x0047d600` (NextPlayer and one
NextTurn path), `0x004543a0` (the other NextTurn path), `0x0046b450`
(`aAttackUnit`, Attack), `0x0046dc60` (`aExecuteUse`, Use) and `0x0046e220`
(`aExecuteMove`) / `0x0046ef50` (`aExecuteWarp`) for MoveUnit. The names are
`tools/trace_names.py`'s; see [`22` §1](22-combat-and-visibility.md).

This matches the comment block that 153 mission scripts carry verbatim (it is
also embedded in `Incubation.exe` as the mission-editor template):

```
* Environment variable _A select between NEXT PLAYER (01),MOVE UNIT (02),
* ATTACK (03),USE (04),NEXT TURN (05),INIT MAP (06),DIALOG (100...255).
>EnvVarCmpNum(_A_Calltype,01);  Goto(NextPlayer); <
>EnvVarCmpNum(_A_Calltype,02);  Goto(MoveUnit);   <
>EnvVarCmpNum(_A_Calltype,03);  Goto(Attack);     <
>EnvVarCmpNum(_A_Calltype,04);  Goto(Use);        <
>EnvVarCmpNum(_A_Calltype,05);  Goto(NextTurn);   <
>EnvVarCmpNum(_A_Calltype,06);  Goto(InitMap);    <
>EnvVarCmpNum(_A_Calltype,100); Goto(Dialog_0);   <
```

#### The two `MoveUnit` call sites

There are **two** `MoveUnit` call sites in the engine and they **disagree about
`_D`**: `0x0046e220` fills `_B`…`_F` as tabulated, while `0x0046ef50` fills
only `_B`…`_D` and puts the destination cell's *ActPt* in `_D` rather than the
height. They are two different kinds of move:

* **`0x0046e220` — the walk.** The unit steps from tile to tile along a path,
  paying each cell's control-map `delay` (`0x0042f690` field `+0x01`) out of
  its movement points. This is the ordinary move.
* **`0x0046ef50` — the warp.** `aExecuteWarp` in the AI code, `aExecuteMove` in
  the UI code. It teleports the unit straight from the source tile to the
  destination in one step, optionally playing the jump animation
  (`0x00411460`), and never touches a path. **Warp** is the developers' own
  word for it: `Info.lcl` annotates the equipment that grants it,

  ```
  SetEquipInfo (7, "Jet Pack",  190, 4,0,0,3,0,0, 4, "G", 6);   * warp & scan
  ```

  and the range builder that marks its legal destinations is
  `0x00475380` → `0x00430ee0`. See
  [`10-lev-mission-format.md`](10-lev-mission-format.md) §4.5.

Which one runs:

* **From the UI** (`0x00471ad0`, `aUI.cpp`): the pending-command global at
  `0x00516310` selects. Command **1** → `0x00472d40` → the walk; command
  **3** → `0x00472f10` → the jump. `0x00472570` is the availability check that
  decides whether command 3 is offered at all.
* **From the AI** (`0x0040a750`, `aAISystem.cpp`): the warp path is taken at
  `0x0040abe6` when the byte at offset `+0x00` of the destination cell record
  equals `0x3c`, otherwise the walk at `0x0040ac43`. **`0x3c` is the
  warp-destination overlay** — the marker the range builder `0x00430ee0` paints
  onto every cell the selected unit may warp to, exactly as `10` marks the cells
  it may walk to. The AI is therefore not testing a property of the terrain; it
  is reading back the overlay the range pass has just written, which is why
  nothing in the LCL surface touches the byte. Full conditions and range table
  in [`10-lev-mission-format.md`](10-lev-mission-format.md) §4.5.

No shipped mission reads any of `_B`…`_F` in `MoveUnit`, so the `_D`
inconsistency is invisible in the released game; a remake should reproduce it
per-path rather than pick one.

**Fall-through.** If the dispatcher matches nothing, the flag is left true by
the final `<` and execution simply continues into whatever follows — which in
the standard layout is `[END]` and then the (usually empty) `Dialog_0` body.

### 5.1 What shipped scripts actually read

| Routine | Env slots read |
| --- | --- |
| dispatcher | `A` (1102 reads) |
| `NextTurn` | `B` (342) |
| `Use` | `B` (152), `C` (152), `D` (79) |
| `NextPlayer` | `B` (153) |
| `MoveUnit`, `Attack`, `InitMap`, `Dialog_0` | none |

**Label sets in `Missions/`:** 152 files have exactly
`Dialog_0, Use, Attack, MoveUnit, NextTurn, NextPlayer, InitMap`; `_C_103.lcl`
adds `EndGame`, reached by `Goto(EndGame)`.

### 5.2 `Dialog_N` — settled: there is no fixed mapping — **[code] `0x00441190`, `0x0043e980`, `0x0043f130`**

The "DIALOG (100…255)" range in the header comment is a *convention*, not a
rule the engine enforces. The `Dialog` command takes the call type to use as an
ordinary argument:

```
Dialog (index, species, x, y, w, h, callType, "infoFile", "s1", "s2");
```

`0x0043e980` stores `callType` in a global; when the info box is dismissed,
`0x0043f130` checks that the box was opened in dialog mode and that the stored
call type is not `-1`, and if so writes it into env slot `_A` and runs the
current mission program. `EndDialog` (`0x00441290`) stores `-1` first, so no
callback happens. The engine's own non-LCL dialogs pass `-1` too.

Since `Dialog` is never used by shipped data, **no shipped mission is ever
entered with a call type above 6**, and the ubiquitous `Dialog_0` body is dead
code. A remake needs a general "call type → label" dispatch, not a `100 + N`
formula.

### 5.3 GUI entry points

`DATA/GUI/Menu_*.lcl` use the same mechanism with `_A` selecting a *window*:

| File | Labels |
| --- | --- |
| `Menu_a.lcl` | `Provider`, `Session`, `First_Player`, `Wait_For_Players`, `Join`, `Error`, `MainMenu`, `Error_Player`, `Error_Session`, `Leveloptions`, `ReadMe`, `ArenaMode`, `GameIntro`, `DemoMessage`, `Credits`, `Campaign` |
| `Menu_b.lcl` | `MainMenu`, `Briefing`, `SelectUnits`, `UpGrade`, `ItemList`, `MainMap`, `Dialog`, `Sequence`, `Recruit`, `Map`, `SlideShow` |
| `Menu_c.lcl` | `MainMenu`, `ExitObject`, `Decoration` |

`Menu_a.lcl` uses selectors 0–3 and 5–16 (no 4), `Menu_b.lcl` 0–11, `Menu_c.lcl`
0–2. The engine sets these directly (`_DAT_0050bf70 = N` at ~40 sites). The
banner in `Menu_a.lcl` calls slot `_A` "the LCL-Public-Variable
`LCLenv.nVar[0]`", corroborating the `letter - 'A'` indexing.

### 5.4 Data-only programs

`Info.lcl`, `Campaign.lcl`, `Mission.lcl`, `Txtmod_*.lcl` and all
`WorldDesc/*.lcl` have **no labels**: one unlabelled routine ended by a single
`[END]`, executed once for its side effects.

---

## 6. Text-resource entries — **[code] `0x00442c40` → `0x00470e60`**

```
%:000,"Please Wait...";;
%:001:"Subterranean";;
%:121,"Equipment Pts:";	;
```

`%` is an ordinary entry in the command table, not special syntax: the token
reader stops the name at the `:`, the parameter parser then takes `000` as
`num[0]` and `"Please Wait..."` as `str[0]`, the first `;` is consumed as that
string's token terminator and the second `;` ends the parameter list. That is
why the separator after the index is free (`,` 724 sites, `:` 132, `;` 12 —
all just token terminators) and why the entry needs **two** semicolons. The one
site where a tab sits between them (`Txtmod_b.lcl:167`) is fine: the whitespace
skipper eats it.

868 entries in total (724 + 132 + 12, which now adds up — the previous
revision's `,` count included 31 commented-out lines), across `Campaign.lcl`
(110), `Mission.lcl` (57), `Txtmod_a` (321), `_b` (145), `_d` (32), `_f` (42),
`_g` (9), `_h` (152). The 1C Russian release's banks carry the same id sets
except `Txtmod_a`, whose last id is 298 (the credits' `END`) against GOG's
339 — the remake's per-id fallback to the base text exists for it
([`92` §7.6](92-remake-architecture.md)).

The store, `0x00470e60(index, text)`:

* index must be **< 400**;
* entries live in a pointer array per text bank; on the **first** write for an
  index, the string is allocated out of a bump arena and the arena top advances
  by `strlen + 1`;
* on **every** write, the text is copied into that same buffer, with a guard
  that refuses to write past the start of the next entry's string.

So for a duplicate `%:NNN`: **the later entry wins, but it must not be longer
than the first one** — otherwise the copy aborts (and, being an LCL command
failure, kills the rest of the text program). This is exactly the shipped
idiom, which always shrinks:

```
%:107,"0000000";; %:107,"";;      * a 7-char placeholder for layout, then blanked
%:011,"--------------------------------------------";; %:011;"";;   * ignore it
```

No duplicate in the corpus grows a string, so no shipped file trips the guard.

---

## 7. Command reference

### 7.1 The table has 108 entries

Two dispatchers hold the whole language:

* `0x00442de0` — **94** entries: 93 commands plus the `%` text entry;
* `0x00444820` — **14** predicates.

Both are a `switch` on the first character followed by `strcmp` chains, so
lookup is by exact, case-sensitive name, and an unmatched name makes the
dispatcher return "not found", which aborts the invocation (§2.2).

107 of the 108 names sit in one contiguous string block at
`0x004c5308`–`0x004c58c0`; `Message` alone lives apart at `0x004c3ff8`. Three
block names are shorter than the four-character default minimum of `strings`
and `rabin2 -z`, which is why a string-pool survey undercounts the table:

* **`OBJ`** (3 chars, `0x004c54d0`) — it **is** implemented (`0x00442b10`),
  contrary to the earlier reading. See §7.5.
* **`?_`** (2 chars, `0x004c536c`, handler `0x00440d50`).
* **`%`** (1 char, `0x004c57f8`, handler `0x00442c40`) — the text-entry
  introducer is an ordinary command, see §6.

### 7.2 How to read the table

* **Kind** — `C` = command, `P` = predicate (valid after `>`, `&`, `|`). The two
  sets are disjoint: an AST pass over all 176 files confirms that every name
  used after `>`/`&`/`|` is one of the 14 and none of the 14 is ever used as a
  body statement.
* **Handler** — the address in `Incubation.exe` that implements it.
* **num / str / var args** — which entries of each parameter array the handler
  reads, i.e. the command's real signature *per kind* (§3.2). A dash means it
  reads none of that kind. Because the arrays are pre-filled with `-1` / `""`,
  a command called with fewer arguments than it reads still runs.
* **Argc seen / Uses / files** — from the corpus AST. `—` means the command
  never appears in shipped data. `%` shows `—` because the parser models text
  entries as their own node type rather than as calls; there are 868 of them
  (§6).

### 7.3 Full table

| Name | Kind | Handler | num args | str args | var args | Argc seen | Uses / files |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `%` | C | `0x00442c40` | 0 | 0 | - | — | — |
| `?_` | C | `0x00440d50` | 0 | - | - | 1 | 1 / 1 |
| `ActivateInfo` | C | `0x00441070` | 0..4 | 0..2 | - | — | — |
| `ActivateInfoSuccessor` | C | `0x00441110` | 0..4 | 0..2 | - | — | — |
| `Barrier` | C | `0x004423d0` | 0..5 | - | - | 6 | 164 / 7 |
| `Bridge` | C | `0x00441f00` | 0..1 | - | - | 2 | 2 / 2 |
| `BuildVisibleMap` | C | `0x00441f40` | 0 | - | - | 1 | 6 / 2 |
| `CDTrackProgram` | C | `0x004408a0` | - | 0 | - | 1 | 111 / 111 |
| `CheckCurrentTurn` | P | `0x004409a0` | 0..1 | - | - | 2 | 2 / 1 |
| `CreateBGB` | C | `0x004425f0` | 0..7 | - | - | 8 | 14 / 5 |
| `CreateCameraPath` | C | `0x00440ff0` | 0..4 | - | - | 5 | 61 / 15 |
| `CrushWall` | C | `0x00440d10` | 0..1 | - | - | 2 | 9 / 3 |
| `Dialog` | C | `0x00441190` | 0..6 | 0..2 | - | — | — |
| `Elevator` | C | `0x00442590` | 0..3 | - | - | 4 | 58 / 10 |
| `EndDialog` | C | `0x0043f110` | - | - | - | — | — |
| `EnterNameOfNextMap` | C | `0x00441020` | - | 0 | - | 1 | 74 / 74 |
| `EnvVarCmpNum` | P | `0x004408b0` | 0 | - | 0 | 2 | 1683 / 156 |
| `EnvVarGreaterNum` | P | `0x004408f0` | 0 | - | 0 | 2 | 214 / 74 |
| `EnvVarLowerNum` | P | `0x004408d0` | 0 | - | 0 | 2 | 83 / 34 |
| `FallingSpores` | C | `0x00441f60` | 0..6 | 0 | - | 8 | 1 / 1 |
| `FireCircle` | C | `0x004424f0` | 0..1 | - | - | 2 | 34 / 7 |
| `FixedStatue` | C | `0x00442370` | 0..2 | - | - | 3 | 21 / 5 |
| `FootBridge` | C | `0x00442650` | 0..3 | - | - | 4 | 7 / 2 |
| `FootBridge2` | C | `0x004426d0` | 0..2 | - | - | 3 | 31 / 1 |
| `GameControlCmpNum` | P | `0x004407b0` | 0..1 | - | - | — | — |
| `GetActPt` | C | `0x004429f0` | 0..1 | - | 0 | 3 | 195 / 56 |
| `GetCtrlMapType` | C | `0x00442ac0` | 0..1 | - | 0 | 3 | 11 / 7 |
| `GetGroupsInArea` | C | `0x00442970` | 0..4 | - | 0 | — | — |
| `GetHeight` | C | `0x00442850` | 0..1 | - | 0 | 3 | 12 / 7 |
| `GetPlayer` | C | `0x004429d0` | - | - | 0 | — | — |
| `GetTurn` | C | `0x00442830` | - | - | 0 | 1 | 1 / 1 |
| `GetUnits` | C | `0x00441a80` | 0 | - | 0 | 2 | 387 / 152 |
| `GetUnitsInArea` | C | `0x00442930` | 0..4 | - | 0 | 5,6,7 | 55 / 28 |
| `GetUnitsInGroup` | C | `0x004429b0` | 0 | - | 0 | 2 | 58 / 47 |
| `Goto` | C | `0x00440e00` | - | 0 | - | 1 | 1104 / 156 |
| `GroundUnit` | C | `0x00442150` | 0..4 | - | - | 5 | 98 / 7 |
| `GroupOnField` | P | `0x00440a00` | 0..2 | - | - | 3 | 26 / 11 |
| `GrowingLand` | C | `0x00442010` | 0 | 0 | - | 2 | 5 / 3 |
| `GUI_LoadBackground` | C | `0x00442c10` | - | 0 | - | — | — |
| `GUI_PrintBackground` | C | `0x0043cbf0` | - | - | - | — | — |
| `GUI_Render` | C | `0x0043ccc0` | - | - | - | — | — |
| `GUI_SetButton` | C | `0x00442c60` | 0..7 | - | - | 7,8 | 80 / 3 |
| `GUI_SetIcon` | C | `0x00442ce0` | 0..3 | - | - | 4 | 32 / 2 |
| `GUI_SetListbox` | C | `0x00442d10` | 0..6 | - | - | 7 | 20 / 1 |
| `GUI_SetText` | C | `0x00442bb0` | 0..10 | - | - | 11 | 115 / 3 |
| `GUI_SetTextbox` | C | `0x00442dd0` | 0 | - | - | 1 | 1 / 1 |
| `GUI_SetTextButton` | C | `0x00442ca0` | 0..6 | - | - | 7 | 11 / 2 |
| `GUI_SetTextOnly` | C | `0x00442d50` | 0..6 | - | - | 7 | 10 / 1 |
| `GUI_SetTextOnly2` | C | `0x00442d90` | 0..6 | - | - | 7 | 1 / 1 |
| `GUI_SetWindow` | C | `0x00442b80` | 0..3 | - | - | 4 | 29 / 3 |
| `HeroKilled` | P | `0x004409e0` | 0 | - | - | 1 | 75 / 75 |
| `IncGameControl` | C | `0x00440790` | 0..1 | - | - | — | — |
| `InsertUnit` | C | `0x004418c0` | 0..6 | 0 | - | 7,8 | 413 / 76 |
| `InsertUnitWithGroup` | C | `0x004419d0` | 0..6 | 0 | - | 8 | 14 / 5 |
| `LinkChrWithGroup` | C | `0x00440cc0` | 0..1 | - | - | 2 | 1 / 1 |
| `LoadCamera` | C | `0x00441c00` | - | - | - | — | — |
| `MechOnField` | P | `0x00440b40` | 0..2 | - | - | — | — |
| `Message` | C | `0x00440880` | - | 0 | - | — | — |
| `MoveCamera` | C | `0x00441aa0` | 0..4 | - | - | 5 | 230 / 59 |
| `MoveFireCircles` | C | `0x00442550` | 0..1 | - | - | — | — |
| `MoveObjects` | C | `0x00442530` | 0..1 | - | - | — | — |
| `MovePosition` | C | `0x00441d00` | 0..2 | - | - | 3 | 189 / 32 |
| `MoveSpores` | C | `0x00442570` | 0..1 | - | - | — | — |
| `MoveTarget` | C | `0x00441c40` | 0..1 | - | - | 2 | 19 / 6 |
| `MoveWorld` | C | `0x00441e50` | 0..9 | - | - | 10 | 1 / 1 |
| `NewCommands` | C | `0x004410e0` | 0..4 | - | - | 5 | 17 / 6 |
| `NoUnitOnField` | P | `0x00440c70` | 0..1 | - | - | 2 | 86 / 13 |
| `OBJ` | C | `0x00442b10` | - | 0..2 | - | 3,6 | 681 / 10 |
| `OpenDoor` | C | `0x004420c0` | 0..1 | - | - | 2 | 29 / 7 |
| `OpenFrontDoor` | C | `0x00441ec0` | 0..1 | - | - | 2 | 17 / 9 |
| `OpenPlantTube` | C | `0x00441e10` | 0..1 | - | - | 2,3 | 71 / 15 |
| `OpenTube` | C | `0x00441dd0` | 0..1 | - | - | 2 | 117 / 40 |
| `ParaBombs` | C | `0x00442270` | 0..5 | - | - | 7 | 4 / 2 |
| `Platform` | C | `0x004422b0` | 0..3 | - | - | 4 | 122 / 14 |
| `PrintAllVars` | C | `0x00440800` | - | - | - | — | — |
| `RoofUnit` | C | `0x00442030` | 0..3 | - | - | 4 | 49 / 8 |
| `RotatingCamera` | C | `0x00440fc0` | 0..2 | - | - | 3 | 1 / 1 |
| `SaveCamera` | C | `0x00441b90` | - | - | - | — | — |
| `SelectNextUnit` | C | `0x00441270` | - | - | - | — | — |
| `SetActPt` | C | `0x00442a40` | 0..2 | - | - | 2,3 | 341 / 42 |
| `SetAmmoForUnit` | C | `0x00441710` | 0..1 | - | - | 2 | 1 / 1 |
| `SetCharismaInfo` | C | `0x00441780` | 0 | 0..5 | - | — | — |
| `SetCtrlMapInfo` | C | `0x00440f30` | 0..3 | 0 | - | 5 | 11 / 1 |
| `SetCtrlMapType` | C | `0x00442a80` | 0..2 | - | - | 3 | 47 / 7 |
| `SetEquipInfo` | C | `0x00441480` | 0..9 | 0..1 | - | 12 | 19 / 1 |
| `SetGameControl` | C | `0x00440770` | 0..1 | - | - | 2 | 751 / 152 |
| `SetGroundFire` | C | `0x00442730` | 0..5 | - | - | 6 | 14 / 2 |
| `SetHeight` | C | `0x004428b0` | 0..2 | - | - | 3 | 31 / 7 |
| `SetTurnControl` | C | `0x004418b0` | 0 | - | - | 1 | 10 / 10 |
| `SetUnitInfo` | C | `0x00441590` | 0..12 | 0..2 | - | 16 | 36 / 1 |
| `SetVarNum` | C | `0x00440730` | 0 | - | 0 | 2 | 15 / 5 |
| `SetVarRandom` | C | `0x004407d0` | - | - | 0 | 2 | 113 / 11 |
| `SetVarVar` | C | `0x00440750` | 1 | - | 0 | 2 | 1 / 1 |
| `SetVolumeCtrl` | C | `0x00441050` | 0..1 | - | - | 2 | 103 / 1 |
| `SetWeaponInfo` | C | `0x004412a0` | 0..17 | 0 | - | 19 | 41 / 1 |
| `SetWeaponInfo2` | C | `0x004413f0` | 0..3 | 0..1 | - | 6 | 42 / 1 |
| `Spores` | C | `0x00441ff0` | 0..2 | - | - | 3 | 3 / 1 |
| `Statue` | C | `0x00442310` | 0..1 | - | - | — | — |
| `Statue2` | C | `0x004424b0` | 0..1 | - | - | 2 | 1 / 1 |
| `UnitOnField` | P | `0x00440a20` | 0..2 | - | - | 3 | 114 / 49 |
| `VarAddNum` | C | `0x00440d60` | 0 | - | 0 | 2 | 8 / 2 |
| `VarAddVar` | C | `0x00440d80` | - | - | 0..1 | 2 | 4 / 2 |
| `VarCmpNum` | P | `0x00440910` | 0 | - | 0 | 2 | 727 / 150 |
| `VarCmpVar` | P | `0x00440970` | - | - | 0..1 | 2 | 12 / 11 |
| `VarGreaterNum` | P | `0x00440950` | 0 | - | 0 | 2 | 99 / 38 |
| `VarLowerNum` | P | `0x00440930` | 0 | - | 0 | 2 | 169 / 32 |
| `VarSubNum` | C | `0x00440db0` | 0 | - | 0 | — | — |
| `VarSubVar` | C | `0x00440dd0` | - | - | 0..1 | — | — |

`EndDialog`'s dispatcher entry is a thunk at `0x00441290` that tail-calls
`0x0043f110`.

### 7.4 Recovered argument roles

Everything in this section is read from the handler; corpus confirmation is
noted where it exists. Roles that remain guesses are called out.

#### Map cell access

`GetCellPtr(x, y)` is `0x0042f730`. The cell fields the language touches:

| Command | Handler | Meaning |
| --- | --- | --- |
| `GetActPt (var, x, y)` | `0x004429f0` | `var = cell(x,y)[+0x0b]` |
| `SetActPt (x, y, value)` | `0x00442a40` | `cell(x,y)[+0x0b] = (byte)value` |
| `GetCtrlMapType (var, x, y)` | `0x00442ac0` | `var = cell(x,y)[+0x0d]` |
| `SetCtrlMapType (x, y, type)` | `0x00442a80` | `cell(x,y)[+0x0d] = (byte)type` |
| `GetHeight (var, x, y)` | `0x00442850` | `var = cell(x,y).height / 160` |
| `SetHeight (x, y, level)` | `0x004428b0` | `cell(x,y).height = level * 160`, and the linked object record is updated too |

The **action point** byte is the scripts' general-purpose persistent per-tile
store — the only state that survives between invocations, since local variables
do not (§4.2). `Missions/_C_105.lcl` pins the argument order by reading and
writing the same tile:

```
GetActPt (_A_Term1,16,5);     * Terminal 1 moves A and B
...
SetActPt (16,5,35);           * Terminal 1: a->b
```

Cells `(0,0)` and `(0,1)` are used across many missions as pure flag storage.
Two values are meaningful to the engine rather than to scripts: **71** (`'G'`)
makes `InsertUnit` refuse to spawn on that cell, and the `Use`/`MoveUnit` entry
points receive the target cell's ActPt in `_D`/`_E`.

The two-argument `SetActPt (x, y)` form occurs exactly once
(`_C_120.lcl:66`, `SetActPt (14,16);`) and writes `(byte)(-1)`, i.e. **255**,
because the missing third argument reads as `-1` (§3.2). Given the neighbouring
lines it is almost certainly a dropped argument rather than intent.

#### Units

**`InsertUnit (player, type, "name", rank, ?, x, y, maxCount)`** —
**[code] `0x004418c0`**, 413 uses. The full algorithm:

1. Look up cell `(x, y)`. If its ActPt is 71, do nothing at all.
2. If `maxCount == 0`, spawn exactly **one** unit. Otherwise draw a count that
   depends on the AI-difficulty setting (`0x00460450`, 0/1/2; anything else is
   the `incorrect ai level!` path):
   * easy (0): `rand() % (maxCount - 1)` when `maxCount >= 3`, else
     `rand() % maxCount`
   * normal (1): `rand() % maxCount`
   * hard (2): `rand() % maxCount + 1`
3. Spawn that many units via `0x00479cf0`, then rebuild the current player's
   visible map.

So `maxCount` is an exclusive upper bound on easy and normal and an inclusive
one on hard: `InsertUnit (…, 1)` spawns **nothing** except on hard, while
`InsertUnit (…, 0)` always spawns exactly one. The corpus uses counts 0–9,
most often 3 (125 sites), 2 (83), 4 (62), 0 (60) and 5 (46). §7.6 sums what
that is worth per difficulty over the 75 campaign missions.

**The `rand()` call is unconditional whenever `maxCount` is not zero** — read
off the branch at `0x0044194E`, where all three level arms (`0x00441942`,
`0x0044195C` and the easy arm's own `call` before its `dec esi`) reach
`call [0x5255FC]` with no guard in front of any of them. So the arms whose only
possible answer is 0 — `maxCount == 1`, and the short forms' `-1` — still
consume one draw. This matters because the stream is shared: `_C_116` fires its
six short call sites on turn 8 and another `InsertUnit` on every turn after, so
a model that short-circuited those arms would desynchronise from turn 9
onward. `inclib/lcl_runtime.py` and `godot/core/lcl/lcl_interpreter.gd` did
exactly that until 2026-09-10; `lcl_runtime.py --check`'s
`insert.draws_even_when_barren` now pins it, and `insert.bounds_hold` /
`insert.bounds_reached` hold the draw against a second reading of the same
instructions (`insert_count_bounds`).

The easy arm's `maxCount >= 3` is `cmp esi, 2 / jle` at `0x0044194E`, which
jumps into the normal arm below 3 rather than testing separately.

`0x00479cf0(player, type, name, rank, arg5, x, y, exact=0, &outIndex)`:

* with `exact == 0` — which is what both LCL commands pass — the target cell
  must pass `0x00479C60(x, y, 0xFFFF)`: on the map, no unit, a field whose
  delay is not 255, and `+0x10` neither 1 (fire) nor 2 (a mine). Otherwise the
  routine tries the **8 neighbouring cells** in `0x004308C0`'s direction
  order — `(0,+1)`, `(−1,0)`, `(0,−1)`, `(+1,0)`, then the diagonals
  (`push 1` at `0x00479D56`) — and takes the first that passes. With
  `exact != 0` neither test is made;
* if `name` is `""` the unit's name is taken from the unit type's description
  string (`SetUnitInfo` argument 2) — which is why every shipped `InsertUnit`
  passes `""`;
* `player` → `unit[+0x45]`; `rank * 12` → **both** `unit[+0x17]` (experience
  points, from which the rank is `EP / 12`) and `unit[+0x18]` (the skill-point
  pool, in twelfths), so a spawned unit starts with one spendable skill point
  per rank — the promotion screen adds another 12 to each;
* `arg5` → `unit[+0x4d]`, the **unit-pool flag**: when it is non-zero the unit
  can be captured into the player's pool, which is what weapon `special` 5
  ("copy the attacked unit into the unit pool if its unit-pool flag is set",
  `0x0046f7e0`) and the two capture paths `0x00478f20` and `0x00463380` test
  before calling `0x00478c10`;
* `+0x3F` is the type's default weapon (`unitinfo[+0x06]`, `0x00479EC4`), and
  then `0x00479F20` calls `0x004759E0`, the **full** derived-stat rewrite:
  hit points to their ceiling, movement, fitness, armour and the weapon's
  magazine. A remake that set only the weapon and the magazine — this
  document's reading until 2026-09-24 — spawns every alien with fitness 0,
  which the allowance reads as exhaustion: `_C_168`'s waves crawled one field
  a turn and never struck. **`0x004759E0` asks `aGetMovePoints` for `+0x15`
  before it writes `+0x19`**, and the record is a stack local nothing clears,
  so the first allowance reads an uninitialised fitness byte (and `+0x41`).
  That is an engine bug; the remake supplies the fitness the same call writes
  a moment later;
* after the rewrite, a unit of any player but 255 gets a voice in `+0x55`:
  a fixed **12** (`spidy`) for type 24, otherwise `aRandom2(1, 6)`
  (`0x00479F49`..`0x00479F6A`) — the clock-seeded stream, for which the remake
  keeps a deterministic stand-in as it does for a recruit (`92` D8). Every
  shipped `InsertUnit` and `InsertUnitWithGroup` is player 255's, so no script
  reaches the draw;
* after the insert, `0x0047A8E0(x, y, 1)` — the nearest **visible** enemy
  ([`23` §3.6](23-ai-system.md)) — and, when that finds nobody, mode 2, any
  enemy; a hit is written through `aChangeUnitViewDirection` `0x004792A0`,
  which leaves types 61..63 unturned. So a spawned unit faces the enemy, not
  facing 0.
* **the slot** is `aInsertUnit` `0x00477830`'s, called with a slot of `-1`
  (`0x00479F6E`) -- as every insertion in the game calls it (`0x00472829`,
  `0x004728CC`, `0x0041C25C`): walk the array from slot 0 and take the first
  whose **`+0x16` is 0** (`0x004778B2`, `mov al, [edi+0x16]; test al, al;
  je`) -- the hit points alone, so a named record whose hit points are 0 is
  free and is overwritten whole. The walk stops at 200, and the one test
  after it is `cmp ebx, 0xC7; jne` (`0x004778C5`): a lowest free slot of
  **199 is refused** (`-1`, and `0x00479CF0` returns 0 with nothing written),
  while an array with **no** free slot leaves the walk at 200, which is not
  199, so the record is written at **slot 200 -- one past the end of the
  array**, into whatever the heap holds there (`aGetUnitMapElementPtr`'s own
  bound, `cmp eax, 0xC8; jle` at `0x00477B0A`, admits 200 too). The insert
  ends in `0x00407AA0` (`0x00477962`), which rebuilds the standard objects
  and renumbers every placed unit's `+0x4B`. **Measured 2026-09-26**
  (`tools/turn_gold.py` phase 15, `spawn`, 5/5 arrangements on `_C_141`):
  as loaded the spawn takes slot 12, a `Human Soldier (1)` record with
  `+0x16 = 0`; with slot 0's `+0x16` cleared it takes 0; with every free slot
  below 198 filled it takes 198; below 199 it refuses; with all 200 filled it
  writes slot 200. In every case no other record changes but its `+0x4B`.

Corpus values agree: argument 1 is always `255` (computer) in `InsertUnit` and
`0` in `InsertUnitWithGroup (0,21,"Dr.Reich",…)`; argument 4 ∈ {0,1,2,4,255}
(rank); argument 5 is always `0` — so **no shipped mission ever spawns a
capturable unit**, and the non-zero behaviour is unexercised by the data even
though the code path is clear; arguments 6–7 span 0–38 (tile coordinates);
argument 8 ∈ 0–9 (the spawn count).

#### Short and long forms

Because the parameter arrays are pre-filled with `-1`, calling a command with
fewer arguments than the handler reads is well-defined rather than undefined —
the missing values are `-1`. The corpus does this in five places:

| Command | Short form | Sites | Effect |
| --- | --- | --- | --- |
| `SetActPt` | 2 of 3 | 1 | writes ActPt = 255 |
| `InsertUnit` | 7 of 8 | 6 | `maxCount = -1`: `rand() % -1` is 0, so **no unit is spawned** on easy or normal, and exactly one on hard |
| `GetUnitsInArea` | 5 of 6 | 1 | `y2 = -1`, so the rectangle is empty and the count is 0 |
| `GUI_SetButton` | 7 of 8 | 3 | the eighth field (`PressDown`) reads as `-1` |
| `OpenPlantTube` | 3 of 2 | 1 | the third argument is simply ignored |

`GetUnitsInArea` also occurs with 7 arguments (2 sites) and `ParaBombs` always
with 7 where the handler reads 6; the extra argument is parsed and discarded.

**`InsertUnitWithGroup (player, type, "name", rank, ?, x, y, group)`** —
**[code] `0x004419d0`**. Identical, except it spawns exactly one unit and then
writes `group` into `unit[+0x4e]` — the field `GetUnitsInGroup` and
`GroupOnField` read.

**`SetAmmoForUnit (x, y)`** — **[code] `0x00441710`**. Despite the name it takes
a *tile*, not a unit, and sets that unit's ammo byte to **0**. One use.

**`GetUnits (var, player)`** — **[code] `0x00441a80`**. Counts the player's
units. `255` is the computer. The corpus comment states the same contract:
*"Get numbers of units for each player. Save numbers in `_A` (p0), `_B` (p1),
`_C` (p2), `_D` (p3) and `_E` (com)."*

**`GetUnitsInArea (var, player, x1, y1, x2, y2)`** — **[code] `0x00442930` →
`0x00478000`**. Counts live units whose `(x, y)` lies in the inclusive
rectangle and whose player matches; a `player` of `-1` matches any. The
7-argument form seen in the corpus passes one extra argument that the handler
never reads; the 5-argument form leaves `y2 = -1`, so it matches nothing.

**`GetGroupsInArea (var, group, x1, y1, x2, y2)`** — **[code] `0x00442970` →
`0x004780a0`**. The same loop, matching `unit[+0x4e] == group` instead of the
player. Despite the name it counts **units of a group**, not groups. Never used
in shipped data (one commented-out line in `_C_171.lcl:140`).

**`GetUnitsInGroup (var, group)`** — **[code] `0x004429b0`**.

#### Predicates

| Predicate | Handler | Semantics |
| --- | --- | --- |
| `EnvVarCmpNum (_X, n)` | `0x004408b0` | `env[X] == n` |
| `EnvVarLowerNum (_X, n)` | `0x004408d0` | `env[X] < n` |
| `EnvVarGreaterNum (_X, n)` | `0x004408f0` | `env[X] > n` |
| `VarCmpNum (_X, n)` | `0x00440910` | `local[X] == n` |
| `VarLowerNum (_X, n)` | `0x00440930` | `local[X] < n` |
| `VarGreaterNum (_X, n)` | `0x00440950` | `local[X] > n` |
| `VarCmpVar (_X, _Y)` | `0x00440970` | `local[X] == local[Y]` |
| `CheckCurrentTurn (lo, hi)` | `0x004409a0` | `lo <= turn <= hi` |
| `HeroKilled (player)` | `0x004409e0` | the player record's "hero killed" byte (`+0x24`) is non-zero — **written by `aRemoveUnitElement`**, see below |
| `GroupOnField (group, x, y)` | `0x00440a00` | a unit of that group stands on the tile |
| `UnitOnField (player, x, y)` | `0x00440a20` | a unit stands there whose species is **not** 2 (object) or 3 (machine) and whose owner matches: `0..3` a human player, `255` the computer, **`254` = any player** |
| `MechOnField (player, x, y)` | `0x00440b40` | same, but species **must** be 3; `254` = any |
| `NoUnitOnField (x, y)` | `0x00440c70` | the cell's unit index is `0xffff` |
| `GameControlCmpNum (slot, n)` | `0x004407b0` | `gameControl[slot] == n` |

The `254` = "any player" escape in `UnitOnField`/`MechOnField` is not used by
the corpus, which always passes 0 or 255.

**`HeroKilled` is the one predicate whose byte no LCL command writes.**
`0x004409E0` reads `playerRecord(arg)[+0x24]` and answers `!= 0`; the only
thing in the binary that moves that byte is `aRemoveUnitElement`
(`0x004779C0`), which increments it when the unit it is taking off the map has
`+0x4D >= 2` — a **hero** — and the turn counter is non-zero. The full
disassembly, the player-record arithmetic and the corpus checks are in
[`22` §9.5](22-combat-and-visibility.md). 75 of the 156 shipped scripts call
it, `_C_140` among them, where it is half of the defeat condition — so a model
that carries `+0x24` and never writes it answers *no hero has died* for a whole
campaign.

#### Game-control slots — **[code] `0x0043b160` / `0x0043b180` / `0x0043b1a0`**

`SetGameControl (slot, value)`, `IncGameControl (slot, delta)` and
`GameControlCmpNum (slot, value)` all address one array of **12 int32s** at
`0x00509f18`; slot must be 0..11 or the call is a no-op.

Only seven slots are read anywhere in the engine:

| Slot | Role | Evidence |
| --- | --- | --- |
| 0–3 | end-of-game state for human players 0–3 | `0x0047d924`: value 1/2/3 maps the player to mission result 2/3/4 — the three win grades, worth +100/+200/+300 ([`27` §6.2](27-campaign.md)); 0 means "nothing happened" and leaves the reset value 1, which scores nothing. Confirmed in a real save: slot 0 holds `1` on the campaign location screen after a won mission and is back to `0` once the next mission is running ([`11` §4](11-save-game-format.md)) |
| 4 | the computer's outcome — **non-zero is the player's defeat**. The hand-over gates on a short-circuit **OR over slots 0–4** (`0x0047d88b`…`0x0047d8c3`): if *any* of them is set, every human player is stamped mission result **5**, and the loop above then puts 2/3/4 back for each player whose own slot is set. So a set slot 4 with no human slot set leaves the 5 standing — result 5 scores −100 and forfeits the slot 10/11 payout ([`27` §6.3](27-campaign.md)) | same loop, index 4 |
| 10 | **equipment-point bonus**, added to the player's pool at end of mission | `0x0043ba10` adds it to the per-player value the GUI prints into text slot 107, under the label in slot 106 (`"Equipment Points:"`); item pickups add 50/20/10 to it directly (`0x0046dc60`). **The add happens only in game mode 1 and only when the player's mission result is not 5** — [`27` §6.2](27-campaign.md) |
| 11 | **commendations awarded**, added to the per-player commendation counter at end of mission; a non-zero value also selects which post-mission screen runs | same loop (`0x0043ba10`) writes `0x00509efc[player] += gc[11]`; that counter is printed into text slot 109, under the label in slot 108 (`"Commendations:"`; `0x00458270`) and spent one at a time to promote a unit (`0x0045a770`); `0x0045d3f0` branches on the **slot** (not the counter) at `0x0045D5FB`, in campaign mode only, between two builders `0x0045E620` / `0x0045DC60`. Gated the same way as slot 10. The slot is not the counter's only source: `0x0043B860` adds one per unit lost to an enemy, at the death ([`27` §6.2](27-campaign.md)); the debriefing prints the counter as `%d(+%d)`, the standing total and the slot's award (`0x0045E38F`) |
| 5–9 | **unused** — nothing in the binary reads them | |

That settles slot 11: the missions that set `SetGameControl (11,1)` (13 sites)
or `(11,2)` (one site, `_C_107.lcl`, *"Mission complete when all men are on the
winning platform"*) award one or two **commendations** for completing a
non-kill objective. The reset block that 152 missions carry —
*"Reset game control variables for saving the winconditions"* — clears slots 0
and 4.

#### Platforms, doors and set pieces

Every one of these is a thin wrapper that reads the numeric parameter array and
calls one animation routine in `aTacTools.cpp` / the animation module. The
release binary keeps the routines' assertion strings, which name them. All the
argument roles below were read from the wrapper plus the routine it calls, and
cross-checked against the annotated call sites in the corpus.

##### World scales

The animation routines mix three coordinate scales; a remake needs all three.

| Quantity | Value | Read from |
| --- | --- | --- |
| One map tile | **3200** world units | `Platform` moves `dist·10` frames of `0x140` each per tile (`0x00412a00`) |
| One height level (the unit `GetHeight`/`SetHeight` speak) | **160** (`0xa0`) | `0x00442850` / `0x004428b0` |
| `Elevator` step | **800** world units = 5 height levels | `0x004125d0` |
| `RoofUnit` drop height | `h · 1600` | `0x00442030` |
| `MovePosition` camera height | `h · 3200` | `0x00441d00` |
| `MoveCamera` camera height | `h · 1600` | `0x00441aa0` |
| `RotatingCamera` / `SetGroundFire` height | `h · 160` | `0x00440fc0`, `0x00442730` |
| `MoveWorld`, `CreateBGB`, `FallingSpores` coordinates | script value **× 16** | `0x00441e50`, `0x004425f0`, `0x00441f60` |

##### Two different direction encodings — a trap

Four commands take a compass direction 0..3, and **they do not all use the same
mapping**:

| Command | 0 | 1 | 2 | 3 | Evidence |
| --- | --- | --- | --- | --- | --- |
| `Platform` | north (−y) | west (−x) | south (+y) | east (+x) | `0x00412a00`; `_C_105.lcl`'s `* move a, south` comments |
| `Elevator` | up (+z) | down (−z) | *(no move)* | *(no move)* | `0x004125d0`; `_C_115.lcl` `* 6/15 down - 12/7 up` |
| `Barrier` | **south (+y)** | west (−x) | **north (−y)** | east (+x) | `0x00413560` |
| `FixedStatue` | **south (+y)** | west (−x) | **north (−y)** | east (+x) | `0x00414000` (raw disassembly at `0x0041412c`–`0x00414142`) |

`Barrier`'s and `FixedStatue`'s mapping is the inverse of `Platform`'s on the
north/south axis. The corpus confirms it independently: `_C_166.lcl` fires
`Barrier (8,0,0,…)`, `(28,0,0,…)` and `(30,0,0,…)` — direction 0 from row
`y = 0`, which can only trace *southwards*.

##### The moving set pieces

**`Platform (x, y, dir, dist)`** — **[code] `0x004422b0` → `0x00412a00`**,
*aPlayPlatformSequence*. `(x, y)` is the platform's **current centre tile**;
`dist` is the distance to travel **in tiles**. The routine

1. collects the 3×3 block of cells centred on `(x,y)` — **x outer, y inner**
   (`0x00412AAA`) — and every unit standing on them;
2. animates for `dist·10` frames, translating the units, the camera target,
   every effect object on the block's cells (`cell[+0x0F]`, `0x00412D9C`)
   and **the special object its search finds** by `±0x140` per frame along
   `dir`. The search is `0x00406F20` in a 5000-unit box around the **centre
   cell's marker** (`0x00412BF7`), and the translation is written into that
   object's record in the special-object table (`0x00412D00`/`0x00412D03`),
   so after the ride the record stands `dist · 3200` further on -- measured,
   see the table paragraph under the ActPt-range family below. With no object
   in the box the animation is skipped (`je 0x412eba`) and steps 3-5 still
   run;
3. relocates every rider `dist` tiles along `dir` through `0x0047AD90`
   (`0x00412F9A`), one at a time: the map's unit index, `+0x42`/`+0x43`, the
   3D object, and then a **writing** visibility pass from the new cell
   ([`22` §9.3](22-combat-and-visibility.md)) — before any cell is copied,
   so the pass sees the destination block's old heights;
4. copies each source cell's `+0x0F` (effect object), `+0x10` (obstacle),
   `+0x0E` (countdown) and `+0x0D` (field type) to the cell `dist` tiles away,
   then writes the source cell's `+0x0F` = 0, `+0x10` = `0xFF`, `+0x0E` = 0,
   `+0x0C` = 0, unit index `0xFFFF` and control-map type **4** (`Deep Hole`)
   (`0x00413011`..`0x0041307F`). **The height `+0x01` is not copied** --
   corrected 2026-09-26: this step read "object/height/type" until then, and
   neither capture could tell, both blocks being at height 0 on `_C_141` and
   on `_C_105`. `presentation_gold.py`'s `land_table_platform_height` raises
   the first `_C_105` ride's source block to 1600 before the call: after it
   the source cells are still at 1600 and the destination cells still at 0,
   9/9 each, while the field types moved;
5. rebuilds the fog for the **selected** unit's player (`0x004130E6`,
   [`22` §9.4](22-combat-and-visibility.md)), and for nobody when nothing is
   selected.

Steps 3 and 4 were measured on 2026-09-02 (`tools/turn_gold.py`, the
`platform` phase: a rider carried three tiles east arrived where the model
said, every cell's height, type and link agreed, and the alien it could see
from there was revealed). The remake carries them as `Platform.ride`, which
[the interpreter](../godot/core/lcl/lcl_interpreter.gd) calls directly — the
one command whose fog pass it performs rather than records, because a pass
deferred past the copy would read the wrong heights — and step 5 as the
`platform` event `World.run_script` acts on with the selection the
presentation keeps in `World.selected_slot`.

`Missions/_C_105.lcl` proves the reading arithmetically — every pair of calls
is a there-and-back:

```
Platform (20,10,2,4);   * move a, south      Platform (20,14,0,4);   * move a, north
Platform (17,17,0,7);   * move b, north      Platform (17,10,2,7);   * move b, south
Platform (17,20,2,6);   * move c, south      Platform (17,26,0,6);   * move c, north
```

`20,10` +4 south = `20,14`; `17,17` −7 north = `17,10`; `17,20` +6 south =
`17,26`. **Argument 4 is a distance, not a platform id**, and arguments 1–2 are
the platform's position *before* the move. (An earlier edition of this document
read argument 4 as a platform identifier because the three values happened to
be distinct per platform; that was wrong.)

**`Elevator (x, y, dir, steps)`** — **[code] `0x00442590` → `0x004125d0`**,
*aPlayElevatorSequence*. One cell. `dir` 0 raises, 1 lowers, anything else does
not move. Each of the `steps` frames adds `±800` to the object's z, the cell's
height field and the standing unit's z, so the total change is
`steps · 800` world units = `steps · 5` height levels. `_C_115.lcl` reads the
same tiles back with `GetHeight` and compares against 30/50, consistent with
7 steps = 35 levels and 15 steps = 75 levels.

**`MoveWorld (camX, camY, camZ, tgtX, tgtY, tgtZ, frames, dx, dy, dz)`** —
**[code] `0x00441e50` → `0x0040f230`**. Every argument **except `frames`** is
shifted left by 4 (× 16) before the call. Sets the camera to
`(camX,camY,camZ)` looking at `(tgtX,tgtY,tgtZ)`, then runs `frames` frames,
each translating the whole world by `(−dx,−dy,−dz)` and the camera position by
the same amount (the target stays put). The single shipped call is
`_C_132.lcl:91` `MoveWorld (5105,16280,3250,4755,4257,0,84,0,100,0);`.

**`CreateBGB (id, type, x, y, z, live, random, gamma)`** — **[code]
`0x004425f0` → `0x0041df10`**, *aEnterBGBCreator*. Registers a background
effect emitter in a 20-slot table (`id` 0..19, 28-byte records at
`0x004fe408`). `x`, `y`, `z` are shifted left by 4. `live` is written to both
`+0x10` and `+0x11`, `random` to `+0x12`, `gamma` to `+0x18`. `type` 0 is an
error; types 2..6 create their object immediately (`0x0042a4c0`, `0x0042a760`,
`0x0042a520`, `0x0042a5a0`, `0x0042a560`); types 1 and 7 are driven by the
per-frame ticker `0x0041e1a0`, which `aCheckInBlobObjects` `0x0041e3d0` calls
once per registered slot before it walks the blob pool.  (`0x0041e140` is the
**teardown** beside it — it frees each slot's sound handle at `+0x14` and
clears the type — and this entry named it as the ticker until 2026-09-05.)
Type 3 additionally uses `gamma << 10` as a rotation. Every argument name comes from the corpus's own annotations, e.g.
`_S_005.lcl`:

```
CreateBGB (1_id,2_warninglight,2400_x,2600_y,260_height,0_live,0_random,0_gamma);
CreateBGB (0_id,7_fire,1670_x,4777_y,330_height,30_live,40_random,0_gamma);
```

Observed `type` values and their corpus labels: **1** = smoke, **2** =
warning light, **3** = computer light, **7** = fire. 4, 5 and 6 are implemented
but unused.

**`FootBridge (x, y, frames, minUnits)`** — **[code] `0x00442650` →
`0x00414a70`**, *aPlayFootBridgeSequence*. The wrapper first counts the units
standing in the 3×3 block around `(x,y)` (`0x0046fba0`) and **runs the sequence
only if that count is greater than `minUnits`**, calling it as
`(x, y, frames, 0)`. The routine sets all nine cells' control-map type to 4
(`Deep Hole`) -- freeing a fire, mine or shield on any of them first
(`0x00414B96`..`0x00414BBF`: `aDeleteSpecialObject` on `+0x0F`, then
`+0x0F` = 0, `+0x10` = `0xFF`, `+0x0E` = 0) -- and plays a `frames`-step
collapse of the object `0x00406F20` finds in a 5000 × 5000 × 5000 box
around the **command cell's own marker** (`cell[+0x05]` through
`aGetSymbolObjectPtr`, `0x00414C4F`..`0x00414CA4`), which it frees with
`aDeleteLand` at the end (`0x00414F49`).
The one shipped call is `_C_107.lcl:76` `FootBridge (16,18,30,1);` — the bridge
gives way once a second man steps onto it, in the mission whose own comment is
*"Mission complete when all men are on the winning platform"*.

**`FootBridge2 (actPt, frames, turn)`** — **[code] `0x004426d0` →
`0x00415110`**. The wrapper compares the **current turn number**
(`0x0043b280`, the same call `GetTurn` uses) against argument 3 and does
nothing unless they are equal. The routine then collapses **every cell whose
ActPt equals `actPt`**: control-map type 4, ActPt cleared, object destroyed,
`frames` steps of falling animation, and every unit standing on a matched
cell is taken off the map afterwards (`0x00415663`, `aRemoveUnitElement` —
which kills, [`42` §12](42-mission-presentation.md)). `_C_163.lcl` schedules
31 of these, `FootBridge2 (112,30,3);` … — always 30 frames, turns 3..12.
Thirty name a tag two cells carry; the thirty-first, `(139,30,12)`, names
none — §8.5.

**`Barrier (x, y, dir, onActPt, offActPt, seedActPt)`** — **[code]
`0x004423d0` → `0x00413560`**, *aPlayLaserBarrier*. A **toggle** keyed on the
emitter tile's ActPt:

* the wrapper writes `seedActPt` into `cell(x,y).ActPt` **only if that ActPt is
  currently 0** — i.e. it initialises the barrier's state on first use;
* if `ActPt == onActPt` the routine sets `ActPt = offActPt` and hides the beam
  object (`+0x2a = 0x800`) — the barrier switches **off**;
* otherwise it sets `ActPt = onActPt`, shows the beam, traces from `(x,y)` in
  direction `dir` until it leaves the map or hits a cell of control-map type 2
  (`Wall`), builds a beam of that length (`0x00428990`), **kills every unit in
  the beam** (`0x0043b8d0`) and points the camera at the middle one.

All 164 shipped calls use `onActPt = 90` and `offActPt = 91`. Seeding with 90
means the barrier is considered *on* at first sight, so the first call switches
it off; seeding with 91 (or with anything else) means the first call switches it
on. See §8.4 for the seven `9o` typos, which land in the second class.

**`FixedStatue (x, y, dir)`** — **[code] `0x00442370` → `0x00414000`**.
Walks up to **10** cells from `(x,y)` in direction `dir`, stopping at a wall
(control-map type 2) or off-map; the first unit found in the path is knocked
down (`0x00405320`) and killed after the animation. This is the fixed
statue/spike trap.

**`Statue (x, y)`** — **[code] `0x00442310` → `0x00413a40`**,
*aPlayRotateStatueSequence*. Runs the rotating-statue sequence on one tile.
Never used by shipped data.

**`Statue2 (actPtMin, actPtMax)`** — **[code] `0x004424b0` → `0x00413500`**,
*aPlayStatueSequence*. Despite the name it is the **batch form of `Statue`**:
it walks the whole cell array and calls `0x00413a40` (i.e. `Statue`) on every
cell whose ActPt lies in `[actPtMin, actPtMax]`. One shipped call,
`_C_178.lcl:61` `Statue2 (110,112);`.

**`CrushWall (x, y)`** — **[code] `0x00440d10` → `0x00415c70`**,
*aPlayCrushWallAnimation*. Nine shipped calls, all plain tiles.

**`Bridge (x, y)`** — **[code] `0x00441f00` → `0x00410da0`**. A **toggle** on
the drawbridge object standing on `(x,y)`: 80 frames of ±12 per frame on the
object's rotation field `+0x26`, the sign chosen by whether that field is
currently zero. Sound `drawbridge.wav`.

**`OpenTube (x, y)`** / **`OpenPlantTube (x, y[, ignored])`** /
**`OpenFrontDoor (x, y)`** — **[code] `0x00441dd0` → `0x00410f10`**,
`0x00441e10` → `0x00411150`, `0x00441ec0` → `0x004112e0`. Tile only.
`OpenPlantTube`'s handler reads two numeric arguments; the one three-argument
call site passes a third that is parsed and discarded.

**`OpenDoor (x, y)`** — **[code] `0x004420c0` → `0x00410a20`**,
*aDoorOpenSequence*. **Does nothing if a unit is standing on the tile**
(`cell+0x07 != 0xffff`). The two extra parameters the routine takes (a second
tile to look at) are passed as `-1, -1` by the LCL wrapper, which suppresses
the camera move.

**`RoofUnit (x, y, height, unitType)`** — **[code] `0x00442030`**. If the tile
is free (`0x00479c60`), spawns one unit of type `unitType` for the computer
player there and plays the drop-from-the-ceiling animation
(`0x00411b00`) starting `height · 1600` world units up. Shipped calls use
heights 20–65 and alien types 50/52/57/58/67/68.

**`GroundUnit (x1, y1, x2, y2, unitType)`** — **[code] `0x00442150`**. If both
tiles are free, spawns one computer unit of type `unitType` at `(x2, y2)`,
plays the burst-from-the-ground animation `0x00411fb0(x1,y1,x2,y2)` and sets
`cell(x1,y1)`'s control-map type to **4** (`Deep Hole`) — the hole the alien
came out of. All 98 shipped calls use adjacent tile pairs and unit type 50
(`Ray'Ther`).

**`SetGroundFire (x, y, height, w, h, tries)`** — **[code] `0x00442730`**.
Makes `tries` attempts; each picks a random tile with
`x' ∈ [x, x+w)`, `y' ∈ [y, y+h)` (`0x00463870`, see below), and if that cell
has `+0x13 == 255`, control-map type 0 or 1, and a height of exactly
`height · 160`, sets it alight (`0x0042fcb0(x', y', 2)` — the *glow* phase,
`GLOW1/2.3DI`; the flames proper are `0x0042f840`, `A_FIRE1/2/3.3DI`, and are
what sets `cell[+0x10] = 1`, see [`23` §7.1](23-ai-system.md)).

**A glow blocks nobody, and two rounds later it kills.** The command writes
`+0x11`, `+0x12` and `+0x13` and no obstacle byte, so nothing about movement
changes. The hand-over's round tick `0x0042ED60` decays the glow from phase 2
to phase 1; the *next* round's sweep `0x00470AB0` frees it and plays
`aPlayGroundFireAnimation` `0x004157B0`, which removes — with no roll and no
armour — every unit on the cell and its eight neighbours that is not standing
on a shield. [`42` §9.1](42-mission-presentation.md) has the table.

**And it only works in `World_D00`.** `GLOW1.3DI` and `GLOW2.3DI` are in that
one prototype container of the nine, so `aCreateSpecialObject` answers -1
anywhere else and the placer writes nothing at all. Both missions that use the
command — `_C_116` and `_S_007` — are `D00` missions; measured in the live
engine both ways ([`97` §37.4](97-slice-5-report.md) and
[§38.1](97-slice-5-report.md)): the same call writes nothing on `World_A00`
and all three bytes on `_C_116`, and the round tick then decays the glow from
phase 2 to phase 1 and leaves it there.
`_C_116.lcl` uses `SetGroundFire (12,29,0,1,1,255);` — a 1×1 area with 255
tries, i.e. "set this one tile on fire, retrying until it takes" — and
`_S_007.lcl` `SetGroundFire (12,13,0,9,14,5);` scatters five fires over a
9 × 14 block.

**`ParaBombs (x, y, w, h, a, b [, c])`** — **[code] `0x00442270` →
`0x00470790`**. Runs the bomber fly-past (`0x00415e90(b)` then
`0x004160f0(x, y, w, h, a)`), then makes **60** attempts at a random tile in
the `w × h` block anchored at `(x, y)`; every attempt that lands on a cell with
no unit and `+0x10 == 255` **lays a mine** there (`0x0042fa70`, which inserts
`A_MINE.3DI` and sets `cell[+0x10] = 2`). Earlier editions of this document
glossed that call as cratering the tile; the model name settles it, and the
move map's rule agrees — a mine blocks every mover except player 255
([`23` §7.3](23-ai-system.md)). The corpus always passes
seven arguments where the handler reads six; the seventh is discarded.
**Arguments 5 and 6 (`a`, `b`) are UNVERIFIED** — observed values are `a = 20`
in all four call sites and `b = 0`; they reach `0x004160f0`'s fifth parameter
and `0x00415e90` respectively, neither of which was traced.

##### The camera commands

Two host helpers underlie all of them: `0x00403780` reads the current camera as
six integers `(posX, posY, posZ, tgtX, tgtY, tgtZ)` and `0x0040eee0` sets it
from the same six.

**`MoveTarget (x, y)`** — **[code] `0x00441c40`**. Keeps the camera position and
points it at the **object standing on tile `(x,y)`** — the cell's object link
`+0x05` resolved through `0x00404c40`, then that object's world `+0x10`/`+0x14`
with z = 0.

**`MovePosition (x, y, h)`** — **[code] `0x00441d00`**. The mirror image: keeps
the current target and moves the camera *to* that object's world x/y at
z = `h · 3200`.

**`MoveCamera (fromX, fromY, toX, toY, h)`** — **[code] `0x00441aa0`**. Sets
both at once: the camera goes to the object on `(fromX, fromY)` at
z = `h · 1600` and looks at the object on `(toX, toY)` at z = 0. 230 uses, the
most-used camera command.

**`RotatingCamera (x, y, h)`** — **[code] `0x00440fc0` → `0x0040ff30`**. Passes
`(x, y, h · 160)`. One shipped call, `_C_106.lcl:44`
`RotatingCamera (16,37,80);` immediately under the comment *"move camera around
Dr. Reich"* — and Dr. Reich was just inserted on tile `(16,37)`. So arguments
1–2 are the tile to orbit and argument 3 is the camera height in height levels.

**`SaveCamera ()` / `LoadCamera ()`** — **[code] `0x00441b90` / `0x00441c00`**.
Push/pop all six parameters through globals at `0x0050c088`.

**`CreateCameraPath (a, b, x, y, z)`** — **[code] `0x00440ff0` →
`0x00416ed0`**. Not traced; see §10.

**`FireCircle (x, y)`** — **[code] `0x004424f0` → `0x004131c0`**. Starts the
ring-of-fire effect on one tile. 34 uses.

##### The ActPt-range family

Five commands do not take coordinates at all: they scan the whole cell array
and act on every cell whose **ActPt** falls in a range. This is how the scripts
address a *set* of tiles that the level designer tagged in the editor.

| Command | Handler → routine | Effect on each matching cell |
| --- | --- | --- |
| `Spores (actPtMin, actPtMax, unitType)` | `0x00441ff0` → `0x0046fc30` → `0x004147d0` | **hatches three cells in fifteen**: `ARandom(0, 15)` and `cmp eax, 2` / `jg`, drawn for every matching cell in map order. A hatch needs a special object inside `5000 × 5000 × 9600` of the cell's marker (`0x00406F20`) and does nothing without one; with one, the object's footprint becomes free floor at height 0 (`0x0042F410(obj, 1, 0, 1)`), the object is freed (`aDeleteLand`), the cell loses its ActPt and height, a computer unit of type `unitType` is generated there — the script's third argument, passed straight through to `aGenerateUnitElement`'s second ([`22` §9.4.3](22-combat-and-visibility.md)) — the fog is rebuilt for player 0, and the splash `0x0042B3B0` (30 sprites, kind 68, life 40) and `msqueether.wav` play (corrected 2026-09-24 from the listing; it was read as "every cell hatches") |
| `Statue2 (actPtMin, actPtMax)` | `0x004424b0` → `0x00413500` | runs the `Statue` sequence |
| `FootBridge2 (actPt, frames, turn)` | `0x004426d0` → `0x00415110` | collapses it (exact match, not a range) |
| `MoveObjects (actPtMin, actPtMax)` | `0x00442530` → `0x0046fc90(…,0)` | moves the object one tile in a random direction |
| `MoveFireCircles (…)` / `MoveSpores (…)` | `0x00442550` / `0x00442570` | the same routine with kind 1 / 2. Kind 1 then runs `0x004131c0`, the same fire-circle sequence `FireCircle` itself calls; kind 2 runs `0x004147d0` with the **constant** unit type 50, `Ray'Ther` (`push 0x32` at `0x0046fe14`) |
| `GrowingLand (actPt, "model.3DI")` | `0x00442010` → `0x0046ff20` | every matching cell tries up to **eight** times (`cmp ecx, 8`) to grow into one of its **four** neighbours, `ARandom(0, 4)` through the jump table at `0x00470140` (0 up, 1 left, 2 down, 3 right). The neighbour must carry no unit, be enterable (`0x0042F6B0`), carry no victory-point marker (`+0x14`) and no ActPt; a fire, mine or shield on it is freed. It is marked `0xFF`, tagged, given the model at its marker (`aInsertLandObject`) and raised with its marker to 1600; the mark keeps it from growing again in the same call, and only after the sweep do the marked cells become type 2 (`Wall`) (corrected 2026-09-24; it was read as "a random free neighbour of eight") |

The three shipped `Spores` calls are `Spores(100,102,66)`, `Spores(120,121,66)`
and `Spores(120,121,65)`, all in `_C_174.lcl`; unit types 65 and 66 are
`Bea'Ther` and `Bea'Coo`, so the "spores" hatch aliens on the tagged tiles.
The routine they share, `0x004147d0`, plays `msqueether.wav` and ends on a
permanent fog rebuild for a literal player 0 — it is the site
[`22` §9.4.3](22-combat-and-visibility.md) works through, and the reason that
document's own reading of it as `FixedStatue`'s was wrong. The 100..102 cells
`Spores(100,102,66)` harvests are the `.lev`'s own: thirteen `L016EH00` spores
stand on them from the start. `GrowingLand` is called with ActPt 100/101/102
and the model `L022EH00.3DI` in `_C_176`, `_O_053` and `_S_073` -- not in
`_C_174` -- and refuses to run at all once the special-object table holds
**more than 140** records (`0x00407410`, `cmp eax, 0x8C` / `jg`). That is a
real bound: `_O_053` and `_S_073` start with 125 and 129 records, and
`_C_176`'s growth doubles every turn.

The table is `[0x004FA80C]`, counted by `[0x004FA7B4]`. `aLoadFile` reads the
`.lev`'s special-object records and their count straight into it
(`0x00407C94`); `aInsertLandObject` `0x00404E30` appends (`GroundUnit`,
`FallingSpores`, `GrowingLand`) and `aDeleteLand` `0x00406C30` removes
(`Spores`, `CrushWall`, `FootBridge`, `FootBridge2`) -- and nothing else
reachable from a script writes the count; the one other writer is
`aBattleSystem.cpp`'s dispatcher `0x0041C010` (inserts at `0x0041C2C7` and
`0x0041CB5D`, a delete at `0x0041CAD8`), whose role is **UNVERIFIED**. The
remake keeps it in `MapState`, hashed and saved (save schema 12,
[`92` §7.3](92-remake-architecture.md)).

**What the table does, read live** (2026-09-26, `tools/presentation_gold.py`'s
`land_table_*` phases; the four readings item 12 below left open):

* **The load.** `0x00407C70` reads the `.lev`'s 724-byte block 1 into
  `0x004FA528` -- whose `+0x28C` is `[0x004FA7B4]` -- and then the whole
  9 900-byte block 2 (150 × 66) into the buffer `[0x004FA80C]` points at
  (`0x00404C70(0)`); the fix-up `0x00404D30` re-resolves each counted
  record's prototype. Every loadable shipped mission (all but `_I_001`,
  whose `World_Z00` the release lacks) was wrapped into `_6_.sav` and loaded
  with `aLoadGame`: the count is the `.lev`'s on **152/152**, every counted
  record's position, rotation, joints and prototype bytes are the `.lev`'s,
  and the block past the count is the file's byte for byte.
* **`Platform` moves the record** (step 2 above). `_C_105`'s six rides, in
  script order: each moves exactly one record -- the `L024EB00` platform its
  search finds, records 8, 8, 7, 7, 44, 44 -- by `dist · 3200` along `dir`
  (`+0x10`/`+0x14` only), and the return ride of each pair finds the record
  where the first ride left it, which only a moved table can answer. 6/6.
  **`MoveWorld` does not touch it**: its per-frame `0x00407E30` translates
  the `.3DW` clone array `[0x004FA818]`, counted by `[0x004FA7B8]` (stride
  `0x40`), and nothing else (static; no shipped call site but `_C_132:91`).
* **A run-time object's footprint is its own cell.** `aInsertLandObject`
  places the record at the marker it is given (`FallingSpores` at z 32 000
  under an effect-stream heading, `0x004146D3`; `GroundUnit`'s `L110EX00` at
  the hole's marker, heading 0, `0x0041237D`; `GrowingLand` at the grown
  cell's marker, `0x00470064`), and the sweep `0x0042F410(object, 1, 0, 1)`
  that `Spores` runs on what it finds marks exactly that cell: inserted live
  on `_C_174` and swept, three `L016EH00` spores at headings 0, 700 and
  2348, one `L110EX00` and one `L022EH00` each mark their own cell and no
  other, 5/5; and `inclib.footprint` gives the same one cell for each of the
  three models at **all 4 096** headings -- no vertex of the three meshes
  lies more than 2 263 units from its origin (`L022EH00`'s corners; the spore
  1 628, the hole 1 697), and the nearest probe a neighbouring cell casts is
  3 000 away.
* **`FootBridge`'s search is anchored on the command cell's marker**
  (above): on `_C_107` the marker of (16,18) is `(51200, 57600, 0)`, the
  cell's origin at its height; the search finds record 5, the `L025EB00`
  bridge, and the collapse frees exactly it -- the count drops by one and
  the records above it move down in order (`aDeleteLand`'s compaction).

Two limits of the table the listing shows and no shipped mission reaches:
`aInsertLandObject` refuses only a count **above** 150 (`cmp eax, 0x96;
jle`, `0x00404E37`), so a table at exactly 150 takes a 151st record past its
buffer; and it increments the count **before** resolving the model
(`0x00404E74`), so an "unknown object" leaves a counted record behind it.
`GrowingLand` and `FallingSpores` stop at 140 (above), well short of both.

**`FallingSpores (x, y, w, h, count, actPt, "model.3DI", height)`** —
**[code] `0x00441f60` → `0x00414550`**. Note the argument order: the string
sits *between* the sixth and seventh numeric arguments, and because the two
kinds are stored in separate arrays (§3.2) that is exactly `num[0..6]` plus
`str[0]`. `count` drops of `model.3DI` land on random tiles with
`x' ∈ [x, x+w)`, `y' ∈ [y, y+h)` -- the row drawn **before** the column
(`0x00441F98`, `0x00441FB9`). A drop is skipped once the special-object table
holds more than 140 records, and on a cell `0x00479C60` refuses (off the map,
a unit, not enterable, a fire or a mine). Otherwise the model is inserted at
32 000 under a heading from the effect stream (`aRandom2(0, 0xFFF)`) and falls
onto the marker, 1 600 on the first frame and 480 more on each after; the
landing dust `0x004227C0` and `drop.wav` follow, the sound killed three frames
in. The cell becomes type 2 (`Wall`) with ActPt `actPt`, and the cell and its
marker take the height `height · 16`. The routine then blocks until the
animation queue is empty. One shipped call,
`_C_174.lcl:87`:

```
FallingSpores (21,7,11,13,5,120,"L016EH00.3DI",40);
```

— five drops in the block `x ∈ 21..31`, `y ∈ 7..19`, tagged ActPt 120, which is
exactly the range the next `Spores (120,121,66)` harvests.

##### The random helper — **[code] `0x00463870`**

Several of the routines above draw random coordinates through
`0x00463870(base, span, __LINE__, __FILE__)`, which returns
`base + floor(span · rand01)` — a uniform integer in `[base, base+span-1]`.
This is *not* the C library `rand()` (that is the import at `0x005255fc`,
which `InsertUnit` uses). A `span` of 1 therefore always returns `base`, which
is what makes `SetGroundFire (x,y,h,1,1,255)` a 255-attempt retry on one tile.
`SetVarRandom (_X, n)` is the same helper with `base = 0`, so it yields a
uniform value in `0 … n-1`.

#### Miscellaneous

| Command | Handler | Semantics |
| --- | --- | --- |
| `Goto (Label)` | `0x00440e00` | §2.3 |
| `SetVarNum (_X, n)` | `0x00440730` | `local[X] = n` |
| `SetVarVar (_X, _Y)` | `0x00440750` | **broken as shipped** — `local[var[0]] = local[num[1]]`. It indexes the local array with the second *numeric* argument instead of the second *variable* argument. See §8.2 |
| `SetVarRandom (_X, n)` | `0x004407d0` | `local[X] = 0x00463870(0, n)` — a uniform integer in `0 … n-1`. The call passes an explicit base of 0, so the result is never negative and never reaches `n` |
| `VarAddNum` / `VarSubNum` | `0x00440d60` / `0x00440db0` | `local[X] ±= n` |
| `VarAddVar` / `VarSubVar` | `0x00440d80` / `0x00440dd0` | `local[X] ±= local[Y]` |
| `GetTurn (_X)` | `0x00442830` | current turn number |
| `GetPlayer (_X)` | `0x004429d0` | current player id |
| `BuildVisibleMap (player)` | `0x00441f40` | recompute fog of war; `-1` means the current player |
| `EnterNameOfNextMap ("name")` | `0x00441020` | copies the string into the "next map" buffer. Always a mission basename (`"_C_101"`, …) |
| `CDTrackProgram ("a.b.c")` | `0x004408a0` | a CD-audio playlist — `"3.5.4"`, `"9.12.7.5.6"`. Called once per mission, in `InitMap`. The parser `0x0042C040` splits with `strtok` on the nine separators at `0x004C2768`, `" .,|;:*+/"` — the missions write dots, the front end and the sequence player commas (`"2,3,4,5,6,7"`, `"9,30"`) — and a token above the disc's track count becomes `-1`, which the player `0x0042BC10` answers by **wrapping to the first entry**; so `"9,30"` loops track 9 ([`41` §4.1](41-sequence-player.md), 2026-09-08) |
| `SetTurnControl (n)` | `0x004418b0` | one argument into `0x0043be00`; **role UNVERIFIED**, observed values {8, 11, 12, 15, 20, 28, 35}, one call per mission in ten missions |
| `SetVolumeCtrl (index, volume)` | `0x00441050` | `int32[121]` at `0x00504638`, index 0..120. The index space is settled — see `docs/21-info-lcl-schema.md` §6 |
| `LinkChrWithGroup (group, chr)` | `0x00440cc0` | writes `chr` into `unit[+0x55]` for every live unit whose group id (`unit[+0x4e]`) is `group`. `unit[+0x55]` selects the unit's **speech set** — see the speech-set table below |
| `NewCommands (a, b, c, d, e)` | `0x004410e0` | five bytes into `0x0047a850`; **roles UNVERIFIED**. Two observed shapes: `(n,0,0,0,0)` with `n` ∈ 100..106 (12 sites) and `(n,1,m,7,0)` with `n` ∈ 5..6, `m` ∈ 110..112 (3 sites) |
| `SaveCamera ()` / `LoadCamera ()` | `0x00441b90` / `0x00441c00` | push/pop the six camera parameters through globals at `0x0050c088` |
| `SelectNextUnit ()` | `0x00441270` | advances the unit selection |
| `MoveObjects (actPtMin, actPtMax)` / `MoveFireCircles (…)` / `MoveSpores (…)` | `0x00442530` / `0x00442550` / `0x00442570` | the same call `0x0046fc90(min, max, kind)` with kind 0 / 1 / 2 — see the ActPt-range family above. **None of the three is used by any shipped script** |
| `ActivateInfo ("file", x, y, w, h, mode, "c1", "c2")` | `0x00441070` | opens the info/briefing box on `TXT\<lang>\Info\<file>.txt`; `mode` is `num[4]`, `c1`/`c2` are the first characters of `str[1]`/`str[2]` |
| `ActivateInfoSuccessor (…)` | `0x00441110` | the same shape, routed to `0x0043ec20` |
| `Dialog (…)` / `EndDialog ()` | `0x00441190` / `0x00441290` | §5.2 |
| `GUI_LoadBackground ("file")` | `0x00442c10` | load a background bitmap |
| `GUI_PrintBackground ()` / `GUI_Render ()` | `0x0043cbf0` / `0x0043ccc0` | blit / present |
| `PrintAllVars ()` | `0x00440800` | debug-only; a bare call to the empty reporter in the release build |
| `Message ("text")` | `0x00440880` | debug-only; same |
| `?_ (n)` | `0x00440d50` → `0x004604b0` | sets `0x00512a00` to `n` for `1 <= n <= 3`. That global is **dword 10 of the 108-byte `Options\Game.opt` blob** (`0x005129d8`, saved/loaded whole by `0x004602e0` / `0x00460390`), defaults to 3 (`0x004601be`) and is read by four renderers through `0x004604a0`; ~~it selects the unit-drawing path (1 = every unit the cheap way, 2 = only non-computer units, 3 = the full way)~~ — it is the **gore level**: the four readers are the death and damage creators of [`42` §4.8.1](42-mission-presentation.md) and the killing teleporter, and at 1 every death is a bloodless puff, at 2 only the computer's units (`+0x45 == 0xFF`) bleed, at 3 everything does. **`?_` is its only writer in the shipped binary** — the options screen does not expose it and no string in either binary names it, so its user-facing name is not recoverable from these files |

#### The `GUI_*` layout commands — **[code] `0x0043c7a0` … `0x0043e030`**

The eleven `GUI_*` commands are pure pass-throughs from the numeric parameter
array into `aGUI`'s builders. `DATA/GUI/Menu_[abc].lcl` annotate every argument
(§3.4); the names below are the authors' own and the roles were confirmed
against the builders.

| Command | Handler → builder | Arguments |
| --- | --- | --- |
| `GUI_SetWindow` | `0x00442b80` → `0x0043c7a0` | `x, y, w, h` |
| `GUI_SetText` | `0x00442bb0` → `0x0043c7d0` | `txtID, fntID, WinText, x, y, Style, cX, cA, cB, cC, Format` |
| `GUI_SetButton` | `0x00442c60` → `0x0043cd10` | `gdtID, fntID, WinText, Library, x, y, Width, PressDown` |
| `GUI_SetTextButton` | `0x00442ca0` → `0x0043cff0` | `gdtID, fntID, WinText, Library, x, y, Width` |
| `GUI_SetIcon` | `0x00442ce0` → `0x0043d110` | `gdtID, Library, x, y` |
| `GUI_SetListbox` | `0x00442d10` → `0x0043d190` | `gdtID, fntID, WinText, Library, x, y, Width` |
| `GUI_SetTextOnly` / `GUI_SetTextOnly2` | `0x00442d50` / `0x00442d90` → `0x0043d2b0` / `0x0043d3d0` | `gdtID, fntID, WinText, x, y, Width, Height` |
| `GUI_SetTextbox` | `0x00442dd0` → `0x0043e030` | one argument |
| `GUI_LoadBackground` | `0x00442c10` → `0x0043ca50` | `"file"` — loads the bitmap *and* its palette |

What the builders actually do with them:

* **`GUI_SetWindow (x, y, w, h)`** stores `x` at `0x00509ff8` and `y` at
  `0x00509ffc`; **every subsequent gadget and text position is added to those**
  (`0x0043c940`, `0x0043cd10`, `0x0043d110`). `w`/`h` go to `0x0050a000` /
  `0x0050a004`. All 29 shipped calls are `GUI_SetWindow (0,0,640,480)`, so the
  origin is always (0,0).
* **`txtID` / `gdtID`** is the slot index. Text slots are 36-byte records at
  `0x0050a008` (`0x0043c7d0` refuses to overwrite a slot whose in-use flag is
  set); the drawing pass `0x0043ca20` walks them all.
* **`fntID`** indexes a font-handle table at `0x0050b26c` (stride 4). Observed
  values 0..4.
* **`WinText`** is passed to `0x00470fe0`, the text-table lookup — i.e. it is a
  `%:NNN` id in the corresponding `Txtmod_*.lcl` (§6).
* **`Library`** is stored verbatim in the gadget record and is the index of the
  gadget's graphic in the loaded GUI sprite library. `GUI_SetIcon`'s **second**
  argument is this, not a font id.
* **`Width`** is a byte; observed values 2..11. It is the gadget's width in
  library tiles, not pixels.
* **`PressDown`** is the gadget record's `+0x0f`; observed 1 (77 sites) and 2
  (3 sites). The three seven-argument `GUI_SetButton` calls leave it at `-1`
  (§7.4). **Its exact effect is UNVERIFIED.**
* **`Format`** is the horizontal alignment, read in `0x00439610`: **0** = `x`
  is the left edge, **1** = centre (`x -= textWidth/2`), **2** = right
  (`x -= textWidth`). Confirmed by the corpus: every `Format 1` text sits at
  `x = 320` on a 640-wide screen.
* **`cX, cA, cB, cC`** are **colour indices**, not literal colours. Each is
  passed through `0x0043e680`, a switch that maps 1..8 to RGB565 values and
  everything else to `0xffff`:

  | Index | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | other |
  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
  | RGB565 | `0xce59` | `0xa514` | `0x632c` | `0x06e0` | `0x0320` | `0xf800` | `0x6000` | `0x3186` | `0xffff` |

  The four values are the **glyph palette**: the font bitmaps store pixel
  values 0..4, and `0x00447900` writes `cX` for pixel value 1, `cA` for 2,
  `cB` for 3 and `cC` for 4 (0 is transparent). `cB` and `cC` are truncated to
  a byte on the way through `0x00439610`, and are 0 in every shipped call.
  Shipped combinations: `(cX,cA)` ∈ {(0,2), (0,3), (1,3), (2,8)}.
* **`Style`** is stored at record `+0x14` and handed to `0x00439610` as its
  fifth parameter — **which never reads it**. It is 0 in all 115 shipped
  `GUI_SetText` calls. Treat it as reserved.

#### Speech sets — `unit[+0x55]`, written by `LinkChrWithGroup`

`LinkChrWithGroup (group, chr)` tags a unit group with a speech-set id; the
combat code (`0x0047b250`, around `0x0047b896`) switches on that id to build a
file name with the format string `"%sSpeech\<dir>\<prefix>%02d%02d.wav"`
(`0x004cce9c`), where the two `%02d` are an event category and an index. The
mapping is a hard-coded switch and matches the shipped `Waves/Speech/` tree
exactly:

| `chr` | directory | prefix | shipped files |
| --- | --- | --- | --- |
| 1 | `1` | `MANO` | 26 |
| 2 | `2` | `MANO` | 25 |
| 3 | `3` | `MACO` | 28 |
| 4 | `4` | `MAMI` | 25 |
| 5 | `7` | `MARA` | 26 |
| 6 | `9` | `Mrd` | 18 |
| 7 | `A` | `feno` | 26 |
| 8, 9 | — | — | fall through to the default: no speech |
| 10 | `6` | `BRNO` | 26 |
| 11 | `5` | `Rrd` | 27 |
| 12 | `8` | `spdy` | 6 — category forced to 0 and the index drawn at random from 0..4 |

The single shipped call is `Missions/_C_106.lcl:43`:

```
InsertUnitWithGroup (0,21,"Dr.Reich",0,0,16,37,5);
LinkChrWithGroup (5,4);   ** Voice Dr.Reich - mimosa
```

— group 5 is the group `InsertUnitWithGroup` just created, and `chr` 4 is the
`MAMI` set in `Waves/Speech/4`.

The five database loaders — `SetWeaponInfo`, `SetWeaponInfo2`, `SetUnitInfo`,
`SetEquipInfo`, `SetCtrlMapInfo` — have their own document:
**`docs/21-info-lcl-schema.md`**.

### 7.5 `OBJ` is implemented — **[code] `0x00442b10`**

`OBJ ("file.3DI", "Category", "Description")`, 680 uses across the ten
`WorldDesc/*.lcl` files, is a real command:

```c
if (strncmp(str[1], filterString, strlen(filterString)) == 0) {
    wsprintf(buf, "<%s> - %s", str[0], str[2]);
    SendMessage(listboxHandle, LB_ADDSTRING, 0, buf);
}
```

It compares its second argument (the category) against a global filter string
at `0x0050bf84` and, on a match, appends `"<file> - description"` to the list
box whose `HWND` sits at `0x0050bf58`.

**Both globals are set by the shipped `Incubation.exe`.** `0x00465140`, from
`C:\aProject\Project\Sources\Game\Dialogs\aSelectObject.cpp`, is the
object-picker dialog's refresh routine: it clears the list box
(`LB_RESETCONTENT`), stores the `HWND` and the category filter in those two
globals, formats `"<world>.lcl"` and runs it through `aInitLCL`
(`0x0043f540`) — so every `OBJ` line in that world's `WorldDesc/*.lcl` whose
category matches is appended. It has fourteen call sites (`0x004648d9` …
`0x00464fc0`), one per category button, and the button strings are exactly the
categories the data uses:

`Equipment` (`0x004cb428`), `PART_A` … `PART_F` (`0x004cb420` … `0x004cb3f8`).

That settles what consumed `WorldDesc/*.lcl`: the built-in *Select Object*
dialog. Two data quirks follow from the comparison being a case-sensitive
`strncmp` of the button string's length:

* `A00.lcl`'s six `Symbolobject` entries match no button, so they are
  unreachable;
* `E00.lcl`'s `PART_a` and `I00.lcl`'s `Part_A` (one entry each) are likewise
  unreachable — a `PART_A` filter does not match them.

The earlier claim that the list-box handle is never set, and the older claim
that no shipped binary implements `OBJ` at all, were both wrong.

---

### 7.6 `Options\Game.opt` — the whole 108-byte blob — **[code] `0x004602E0`, `0x00460390`, `0x00460ED0`, `0x00460520`**

`?_` above writes one dword of a file that is otherwise a raw `fwrite` of a
single `.data` block:

```c
BOOL aSaveOptions(void) { WriteFile(h, (void *)0x005129D8, 0x6C); }   /* 0x004602E0 */
BOOL aLoadOptions(void) { ReadFile (h, (void *)0x005129D8, 0x6C); }   /* 0x00460390 */
```

So `Game.opt` **is** `0x005129D8 .. 0x00512A43`, byte for byte, and
`aInitOptions` (`0x00460020`) writes the defaults into the same block when the
file is missing. Eleven `i32` fields and a 64-byte name:

| Offset | Address | Default | Range | Meaning |
| --- | --- | --- | --- | --- |
| +0x00 | `0x005129D8` | `1` | `+1`, `-1` | **Speaker position** — the sound pan is multiplied by it, so `-1` swaps left and right (`0x00460990` sets `aDirectSoundSet(pan = value * 1000)`) |
| +0x04 | `0x005129DC` | `25000` | `0`, `10000`, `25000`, `50000` | **Music volume** — the only field that reaches `aSetCDVolume` (`0x0042C330`) |
| +0x08 | `0x005129E0` | `0` | — | **dead** — written once by `aInitOptions` and never read or written again |
| +0x0C | `0x005129E4` | `-512` | `0`, `-512`, `-1024`, `-10000` | **FX volume**, DirectSound attenuation in hundredths of a dB (`-10000` is silence). `0x00460440` returns it and every animation/sound routine passes it as the buffer volume |
| +0x10 | `0x005129E8` | `-512` | — | **dead** — same as +0x08 |
| +0x14 | `0x005129EC` | `-512` | the same four | **Speech volume** — `0x00460480` returns it and only the speech routine `0x0047B660` reads it |
| +0x18 | `0x005129F0` | `0` | `0`, `1`, `2` | **Difficulty level** — see below |
| +0x1C | `0x005129F4` | `1` | `0`, `1` | **Enemy Move on/off** — `0x00460740` toggles it as `x = (x != 1)`; read only by `aExecuteMove` (`0x0046E220`), where a non-zero value selects animation mode 3 instead of 2 |
| +0x20 | `0x005129F8` | `2` | `1`, `2`, `3` | **Cursor and animation level** — `0x004604D0`, forced to 2 in one game mode; seven readers in the 3D-object and UI code |
| +0x24 | `0x005129FC` | `2` | `1`, `2` | **Animation resolution** — `0x004604F0`, read by `aCreateSeqPlayer` among others |
| +0x28 | `0x00512A00` | `3` | `1`..`3` | the gore level `?_` writes (above): 1 no blood, 2 the computer's units only, 3 all |
| +0x2C | `0x00512A04` | GUI text 198 | 64 bytes | **player name**, returned by `0x00461300` |

`0x2C + 64 = 0x6C`, exactly the size written.

**The options screen names eight of them itself.** `0x00460520` hit-tests the
screen into a row index 0..7 and dispatches to eight cyclers; `0x00460D7F`
switches on the same index through a jump table at `0x00460EAC` to pick the
help line from `Txtmod_h.lcl`:

| Row | Cycler | Field | Text id | Label in `Txtmod_h.lcl` |
| --- | --- | --- | --- | --- |
| 0 | `0x00460990` | +0x00 | 50 | `"Toggle Speaker Position"` |
| 1 | `0x00460A10` | +0x04 | 51 | `"Set Music Volume"` |
| 2 | `0x00460B10` | +0x0C | 52 | `"Set FX Volume"` |
| 3 | `0x00460C30` | +0x14 | 57 | `"Set Speech Volume"` |
| 4 | `0x00460820` | +0x20 | 55 | `"Select Cursor and Animation Level"` |
| 5 | `0x00460740` | +0x1C | 54 | `"Enemy Move on/off"` |
| 6 | `0x00460900` | +0x24 | 56 | `"Select Animation Resolution"` |
| 7 | `0x00460780` | +0x18 | 58 | `"Set Difficulty Level (only in main map during campaign)"` |

Text 53, the unqualified `"Set Difficulty Level"`, is not reachable from this
switch. Nothing on this screen touches +0x08, +0x10, +0x28 or +0x2C, which is
why `?_` had to exist at all.

`combat_tables.py --check` guards the whole blob, not just its I/O: `opt.io`
requires both routines to transfer `0x6C` bytes from `0x005129D8`, `opt.rows`
and `opt.difficulty` pin the eight help lines, `opt.defaults` re-executes
`aInitOptions`' straight-line default block (`0x004600AC`..`0x004601C8`) and
requires exactly the eleven values in the table above, and `opt.dead`
**enumerates** every `.text` reference to +0x08 and +0x10 rather than reporting
a failed search: one each, `0x0046019A` and `0x0046018A`, both the
`aInitOptions` write itself. The player name at +0x2C has two, the default copy
at `0x0046013A` and the getter at `0x00461301`. So "dead" here means *provably
write-once*, and every one of the 108 bytes is accounted for.

**The rows carry no text.** Each state is a 30x30 icon from `Libs/options.LIB`,
which is why searching the binaries for level names finds nothing:

| Field | Sprite indices | What the icons show |
| --- | --- | --- |
| +0x00 | 6, 7 | a speaker captioned `L R`, mirrored between the two states |
| +0x04 | 2, 3, 4, 5 | musical notes with a row of pips |
| +0x0C | 8, 9, 10, 11 | a speaker with sound arcs and a row of pips |
| +0x14 | 19, 20, 21, 22 | a hand/speaker with a row of pips |
| +0x18 | 23, 24, 25 | **a skull with one, two or three lit pips** |
| +0x1C | 15, 16 | a motion trail with two green arrows |
| +0x20 | 12, 13, 14 | a mouse cursor with a row of pips |
| +0x24 | 17, 18 | a filmstrip captioned `HI LO` |
| — | 26 | the blank tile drawn over a row the current game mode disables |

**Difficulty** (+0x18) is therefore a three-position control whose settings have
**no names anywhere in the shipped product** — one, two or three pips on a
skull. `0x00460450` returns it, forcing `1` in any multi-player or network game,
so **the difficulty setting only exists in single player**. The cycler
`0x00460780` is blocked, and sprite 26 drawn instead, whenever the game state is
3 — which is what text 58 means by *"only in main map during campaign"*.

#### What the difficulty reaches — all eleven call sites

`0x00460450` has eleven call sites in six functions, and every one of them is
now decoded. An earlier revision of this section said the damage roll was "the
one that is fully decoded"; that has not been true for some time.

| Function | Sites | What the level changes | Spec |
| --- | --- | --- | --- |
| `0x0046C960` `applyDamage` | 1 | **widens the damage roll upward** — the floor `(D+1)/2` is identical at every level and only the span grows, by one point per step | [`22` §7.4](22-combat-and-visibility.md) |
| `0x004418C0` `InsertUnit` | 1 | **how many units one spawn command produces** — `maxCount` is an exclusive bound on easy and normal and an inclusive one on hard | §7.4 above |
| `0x00475160` `aGetMovePoints` | 1 | **one point of movement, for one unit type** — only `0x32`, `Ray'Ther`, and only on easy | [`10` §5.5](10-lev-mission-format.md) |
| `0x0047AFD0` (the kill award) | 1 | the experience multiplier 4/3/1 — but **only outside the campaign**: `gameMode() == 1` returns the victim's `exp` byte before the level is read | [`22` §7.5](22-combat-and-visibility.md) |
| `0x0043BA10` (the mission score) | 1 | the fragging multiplier `{1, 2, 3}` in `kills * mul − 2 * losses + base(result)` | [`27` §6.2](27-campaign.md) |
| `0x00451A70` (the options screen) | 6 | draws the skull row and steps it | this section |

Two things the level does **not** reach are worth stating as plainly as the
six that it does, because both are easy to assume:

* **The computer's turn.** `0x00460450` has no call site inside `aAISystem.cpp`
  or the move map. The AI plans, targets, approaches and fires identically at
  every level — [`23` §1](23-ai-system.md) enumerates the negative evidence.
* **What a unit *is*.** `applyDamage` takes the roll into `unit[+0x16]` and
  nothing else; ranks, skills, armour, weapons and equipment come from the
  `.lev` record and from `SetUnitInfo`, neither of which the level is an input
  to. `InsertUnit`'s rank is argument 4, and it is a **number literal at all
  314 campaign call sites** (`census.rank_is_a_literal`) — there is no variable
  through which the setting could reach one.

#### What it is worth, counted — **[check] `lcl_runtime.py --check`**

The two censuses below run over **the same 75 missions** (the shipped `.lev`
files whose header type is 1), because the claim they support is that a
mission's opposition comes from two places and the difficulty reaches exactly
one of them.

**Placed by the `.lev` itself** — fixed, and no input to it is the difficulty:

| Player | Placed units | |
| --- | --- | --- |
| 255 | **872** | the aliens, ~11.6 per mission; three missions place none |
| 252 | 144 | neutral props |
| 0 | 37 | the missions that ship their own squad |

**Spawned by `InsertUnit`** — 314 call sites, whose `maxCount` distribution is
6 × `-1` (the short forms), 50 × `0`, 14 × `1`, 78 × `2`, 85 × `3`, 45 × `4`,
25 × `5`, 6 × `6`, 3 × `7`, and one each of `8` and `9`. Summing each site's
possible range **once per site**:

| | easy (0) | normal (1) | hard (2) |
| --- | --- | --- | --- |
| fewest | 50 | 50 | **314** |
| most | 430 | 596 | 860 |
| mean of a uniform draw | 240 | 323 | **587** |

**These are per-site sums, not a played game.** A call site sits inside a
turn-gated region (`>EnvVarGreaterNum (_B,2);`) that may fire on many turns or
on none, so the table says what the difficulty is worth *per spawn command*,
not how many aliens a campaign produces. Read that way the shape is clear
enough: hard is worth 1.8x normal and 2.4x easy across the same scripts, and
the floor is most of the difference — hard's `+1` means every one of the 314
sites spawns at least one unit, where easy and normal guarantee only the 50
that pass `maxCount == 0`.

---

## 8. Defects in the shipped corpus, re-analysed

`tools/lcl_parse.py --check` parses **176/176** files and reports 12
diagnostics. With the interpreter in hand, most of them turn out to be
*harmless* — which is a useful correction: an earlier reading of this corpus
concluded that a missing `<` killed a branch, and that is not what happens.

| File:line | Problem | Actual effect |
| --- | --- | --- |
| `_C_114.lcl:59` | `&EnvVarLowerNum (_B,8);` with no preceding `>` | **None.** The flag is true after the previous `<`, so `&pred` behaves exactly like `>pred`. |
| `_C_120.lcl:220` | new `>` region opened while the previous is unclosed | **None.** `>` assigns the flag outright; the second region is entered normally. |
| `_C_128.lcl:57` | same | **None** — see below. |
| `_C_150.lcl:108` | same | **None.** |
| `_C_152.lcl:104` | same | **None.** |
| `_C_154.lcl:110` | same | **None.** |
| `_O_060.lcl:128` | same | **None.** |
| `_C_169.lcl:158` | a surplus `<` | **None.** Sets an already-true flag to true. |
| `_O_050.lcl:119` | `InsertUnit (255,67,"";0,0,25,22,0);` — `;` typed for `,` | **None.** The `;` was already consumed as the string token's terminator, so it never reaches the "end of parameter list" test; all eight arguments arrive. |
| `_S_074.lcl:119` | identical typo (near-duplicate file) | **None.** |
| `J00.lcl:23` | unterminated string in an `OBJ` line | **Fatal** — the token reader treats the newline inside the literal as an error and aborts the program at that point, so the *Select Object* dialog (§7.5) lists nothing after line 23 for world `J00`. It costs nothing in play, only in the level-design tooling. **`lcl_parse.py` deliberately diverges here**: it reports the bad literal, abandons that argument list at the line boundary and resumes on line 24, so the 118 objects declared after the bad line — including `L009EF00.3DI` "Facade" on line 24 — stay inspectable. An earlier revision of the parser instead swallowed line 24 into line 23's argument list behind a warning, silently dropping that object; the file now yields 126 statements, not 125. |
| `Txtmod_b.lcl:167` | `%:121,"Equipment Pts:";\t;` — a tab between the two `;` | **None.** The whitespace skipper eats it. |

### 8.1 The `_C_128.lcl` "dead branch" is not dead

```
>EnvVarCmpNum (_B,1);
 MoveCamera (5,21,2,21,8);
  OpenTube (2,21);
>EnvVarCmpNum (_B,3);        ← the '<' for the first region was forgotten
 MoveCamera (22,31,22,34,8);
  OpenTube (22,34);
<
```

Under the real flag machine, the second `>` simply reassigns the flag, so the
turn-3 camera move happens exactly as intended. An earlier version of this
document inferred a "skip forward to the next `<`" model from this site and
concluded the branch was unreachable; that inference was wrong. The only real
consequence of the missing `<` is that the *first* region's body ends where the
second `>` begins rather than at a `<` — which is what the author wanted anyway.

### 8.2 A thirteenth defect, in the interpreter rather than the data

`SetVarVar` — **[code] `0x00440750`** — is:

```asm
mov  eax, [0x50befc]              ; num[1]  -- the second NUMERIC argument
mov  edx, [0x50bea0]              ; var[0]  -- the first VARIABLE argument
mov  ecx, [eax*4 + 0x50b850]      ; local[num[1]]
mov  [edx*4 + 0x50b850], ecx      ; local[var[0]] = that
```

Every sibling (`VarCmpVar` `0x00440970`, `VarAddVar` `0x00440d80`,
`VarSubVar` `0x00440dd0`) reads the second operand from `0x0050bea4` = `var[1]`.
`SetVarVar` alone reads `0x0050befc` = `num[1]`. Called the way its name
implies — with two variable references — `num[1]` is the reset value `-1`, so
the source becomes `local[-1]`, the dword four bytes below the array at
`0x0050b84c`, which nothing else in the binary writes.

The corpus contains exactly one `SetVarVar`, `Missions/_C_112.lcl:95`:

```
SetVarVar (_O,_A);
```

so that line copies an out-of-bounds word into `_O` rather than `_A`. It is
guarded by nothing and its result is read a few lines later, which makes
`_C_112.lcl` behave unpredictably in a way no amount of reading the script
would reveal. A remake reimplementing `SetVarVar` "correctly" will not
reproduce the original — but since the original's behaviour is undefined, doing
it correctly is the right call; this is recorded so the divergence is a
decision rather than an accident.

### 8.3 One defect that is invisible to a parser

`Missions/_C_100.lcl:77` tests `_E_computer` where line 62 assigned `_E_com`.
Harmless — the annotation after the slot letter is ignored — but a good example
of how the convention hides a naming slip.

### 8.4 A fourteenth defect: `9o` in `_C_166.lcl`

Seven `Barrier` calls in `Missions/_C_166.lcl` (lines 63–69) type the letter
`o` for a zero in their last argument:

```
Barrier (8,14,2,90,91,9o);
```

The number parser is `atoi` (§3.2), so `9o` reads as **9**, not 90 or 91. The
tokenizer accepts it without complaint — `o` is not one of the six terminators
— and `lcl_parse.py` records `raw: "9o", value: 9`.

The effect is nil. The argument is `Barrier`'s ActPt seed, written only when
the tile's ActPt is still 0, and the routine's test is `ActPt == onActPt`
(90). A seed of 9 fails that test exactly as a seed of 91 would, so the first
call switches the barrier on — which is what the six correctly-typed calls
immediately above (`…,90,91,91`) do. The typo would only have mattered if the
author had meant `90`.

### 8.5 A fifteenth: `FootBridge2 (139,30,12)` in `_C_163.lcl`

The last of the mission's 31 `FootBridge2` calls (line 131, turn 13) names
tag 139. No cell of `_C_163.lev` carries it: the bridge tags on the map run
101..133 with 117 and 126 unused, and **130** — the block at (16,12)/(16,13)
— is the one tag no call names. `0x004426d0` finds no cell, sets nothing and
plays nothing, so that bridge stands through the mission. The effect on play
is nil beyond one bridge fewer; `interaction_tables.py` pins it
(`corpus.footbridge2_typo`, 2026-09-06).

---

## 9. Tooling

`tools/lcl_decode.py` implements the `0xFE` / XOR-`0xFF` scrambler.
`tools/lcl_parse.py` is a tokenizer and parser producing an AST.

```bash
# Human-readable dump of one script
python3 tools/lcl_parse.py gog_incubation/Missions/_C_105.lcl

# AST as JSON
python3 tools/lcl_parse.py gog_incubation/Missions/_C_105.lcl --json

# Parse every .lcl in the game; report failures and diagnostics
python3 tools/lcl_parse.py --check gog_incubation

# ... plus command usage statistics
python3 tools/lcl_parse.py --check gog_incubation --stats
```

Current corpus coverage: **176/176**.

AST node types: `program` → `routine` → (`statement` | `conditional` |
`text_entry`). A `conditional` holds `terms` (each an op `>`/`&`/`|` plus a
predicate `statement`), a `body`, and an `else_body` holding the statements
after a `#`. Arguments are classified as `string`, `number`, `var`, `name` or
`empty`, with the `_Annotation` preserved separately in `label`.

The region/`else_body` shape is a **convenience view**. The normative semantics
are the flag machine of §2, and an evaluator should implement that directly:
regions are not blocks, and an interpreter that skips over a false region will
diverge from the original on the six files with an unbalanced `<`.

---

## 10. Open questions

Everything the previous editions listed here has been settled except the
following. Each entry states the observed value set, so an implementation can
carry the field through without inventing a meaning.

1. ~~**`ParaBombs` arguments 5 and 6.**~~ **— CLOSED.** `0x00442270` →
   `0x00470790`, which drives two routines:

   * **Argument 5 is the number of bombs.** `0x004160F0(x, y, w, h, count)`
     runs `count` iterations; each picks a random cell inside the rectangle
     with the uniform generator `0x00463870`, retries up to **5 times** until
     `0x00479C60` accepts the cell, then resolves the cell's object and calls
     `0x0042B070` with a random value in 0..199 (`0x004638E0`) — a per-bomb
     timing offset, which is what makes the strikes land staggered rather than
     together. All four shipped call sites pass 20, i.e. 20 bombs.
   * **Argument 6 selects the bomber's fly-past length.** `0x00415E90(mode)`
     plays `bomber.wav`, builds the fly-past volume, and then branches: `0`
     gives a pass ending at **320000** world units, `1` a short pass ending at
     **80000** (200 m and 50 m at 1600 world units per metre). Any other value
     is rejected outright. All four shipped sites pass 0, the long pass.

2. ~~**`CreateCameraPath (a, b, x, y, z)`**~~ **— CLOSED.** `0x00440FF0` →
   `0x00416ED0`, now traced:

   * `a` is a **camera-path id, 0..4** (five paths; the routine rejects
     anything else). Each path is a 140-byte (`0x8C`) record.
   * `b` is a **mode**: `0` resets the path's waypoint count to zero and stores
     `(x, y, z)` as the path's **look-at target**; `1` **appends** `(x, y, z)`
     as the next waypoint and increments the count, rejecting the call once the
     count reaches **9**. No other value is accepted.
   * `x, y, z` are world coordinates and are stored **shifted left by 4**, i.e.
     scaled by 16 — the same file-unit-to-world-unit factor the `.3DW` loader
     applies (see [`30-eng3d-ascii-formats.md`](30-eng3d-ascii-formats.md)
     §2.5).

   Record layout: `count` at `+0x00`, nine `(i32 x, i32 y, i32 z)` waypoints at
   `+0x08` with stride `0x0C`, look-at target at `+0x80`/`+0x84`/`+0x88`.
   This matches the corpus exactly: `a` is only ever `0`, and `b` is `0` on the
   first call of each group and `1` on the rest.

3. ~~**`NewCommands (a, b, c, d, e)`**~~ **— CLOSED.** `0x004410E0` →
   `0x0047A850`, now traced. It is a **broadcast of AI orders to a whole unit
   group**: it walks all 200 unit slots (stride `0x5B` = the 91-byte unit
   record) and, for every unit that is alive (`+0x16 != 0`) **and** whose group
   id `+0x4E` equals `a`, writes

   ```
   unit[+0x47] = b     primary AI order
   unit[+0x48] = e     primary order parameter
   unit[+0x49] = d     secondary AI order
   unit[+0x4A] = e     secondary order parameter
   ```

   So `a` is the target group, `b`/`d` are the primary and secondary orders,
   and `e` is a single parameter written into **both** order slots.

   **Argument `c` is never referenced** — the routine ignores its third
   parameter entirely. It is `0` at every shipped call site, so nothing depends
   on it.

   The order and parameter offsets agree independently with the `.lev` track's
   decoding of the unit record (see
   [`10-lev-mission-format.md`](10-lev-mission-format.md) §5), which named
   `+0x47`/`+0x48` and `+0x49`/`+0x4A` as the primary and secondary
   order/parameter pairs from the editor's own dialog labels.

4. ~~**`SetTurnControl (n)`**~~ **— CLOSED, and it enforces nothing.**
   `0x004418B0` → `0x0043BE00`:

   ```c
   turnLimitActive = 1;                      /* 0x00509FE8 */
   turnLimitValue  = n;                      /* 0x00509FEC */
   wsprintfA(turnLimitText, "%d", n);        /* 0x00509FF0 */
   ```

   The three globals have exactly four accessors (`0x0043BDD0` returns the
   formatted text when the flag is set, `0x0043BDE0` returns the value,
   `0x0043BE30` clears the flag, `0x0043BE70` returns the flag), and the value
   reader has **one caller**: the HUD formatter in `fcn.0041A980`, which prints
   `"%d"` when no limit is set and `"%d/%s"` — current turn over the target —
   when one is.

   **Nothing compares the current turn against it.** `SetTurnControl` is purely
   a display hint: it puts a par turn count on the interface. A mission's actual
   time pressure is implemented in the script, with `CheckCurrentTurn` and
   `SetGameControl`. This explains the observed values {8, 11, 12, 15, 20, 28,
   35}: they are per-mission par counts shown to the player, one per mission.

5. ~~**`GUI_SetButton`'s `PressDown`**~~ **— CLOSED, and it does what its name
   says.**

   First, a correction: the field is at gadget record **`+0x69`**, not `+0x0F`.
   `GUI_SetButton`'s implementation `0x0043CD10` builds the staging record on
   its stack and stores its eighth argument at record offset `+0x69`
   (`local_f`, against the record base `local_78`); the registration routine
   `0x00439E40` copies it as a dword to the live gadget at `0x00508C29`. The
   byte at `+0x0F` is not a field at all — it is the top byte of the dword at
   `+0x0C`, which is a drawing parameter passed to `0x00447B20`.

   The renderer branches on it directly:

   | `+0x69` | Effect |
   |---|---|
   | `0` | label drawn at the gadget's `y`, colour taken from `+0x18` |
   | non-zero | label drawn at **`y + 2`** — shifted down two pixels — and the colour taken from `+0x20` instead |

   So it renders the button in its **pressed** state. Both shipped values 1 and
   2 take the same non-zero branch, so nothing in the engine distinguishes
   them; the three seven-argument calls leave the field at `-1`, which is also
   simply non-zero. **UNVERIFIED:** whether 1 and 2 were meant to differ.

   Everything else in the `GUI_*` surface is settled — see §7.4.
6. **`GUI_SetText`'s `Style`** — **closed as reserved.** Stored at text-record
   `+0x14` and passed to the renderer, which never reads it; `0` in all 115
   shipped calls. A remake must carry the argument through and may ignore its
   value. Only the *intended* meaning is unrecoverable, and no shipped artefact
   can supply it.
7. **`SetCharismaInfo`'s six strings** — **closed as dead in both shipped
   binaries.** `Incubation.exe` writes six 20-byte names into
   `0x00518368 + id*120` (`0x00441780`) and `iDesigner.exe` writes the same six
   names into `0x004c8ed8 + id*0x78` (`0x00424710`); a whole-image operand scan
   over each table's full 101-record extent finds exactly six references in each
   binary, all of them the writes themselves. No reader, no shipped caller, and
   no label in either binary in ASCII or UTF-16LE. The six roles are not
   recoverable from the shipped product and none is invented — see
   `docs/21-info-lcl-schema.md` §7.
8. **`SetCtrlMapInfo`'s `cover` column** (record `+0x02`) — **closed as dead in
   both shipped binaries.** Five references to the table in `Incubation.exe` and
   five in `iDesigner.exe`, none of them a `+0x02` form; the editor's terrain UI
   has no cover control; the word appears in neither binary in either encoding.
   See `docs/21-info-lcl-schema.md` §2.1.
9. **`?_`'s user-facing name** — **closed as an unnamed developer switch.**
   Fully characterised otherwise (§7.4): it is dword 10 of `Options\Game.opt`,
   defaults to 3, selects the unit-drawing path, and `?_` is its only writer.
   The setter `0x004604b0` has exactly one caller in the whole image — the `?_`
   handler `0x00440d50` — so the options screen provably cannot reach the
   global; the two animation-flavoured option labels in the GUI text
   (`Txtmod_h.lcl` strings 55 *"Select Cursor and Animation Level"* and 56
   *"Select Animation Resolution"*) therefore belong to other `Game.opt` dwords,
   not to this one — §7.6 now identifies which, and names every other field of
   the blob from the options screen's own help lines. `iDesigner.exe` implements the identical command
   (`0x0042c2f0`: clamp 1..3, store to `0x004c3570`) and never reads its copy
   either, and its resources contain no matching label. Nothing in the shipped
   product names it; the name is unrecoverable and none is invented.

   **The shipped install does not run at the default.** `?_` has exactly one
   call site in the whole corpus, and it is not in a `.lcl` at all —
   `DATA/user.gcl`, a plain-text script that `main` runs at startup
   (`aInitLCL`, `aMain.cpp:1002`, `0x0044A1CA`), consists of nothing but

   ```
   [LCL]
   ?_(2);
   [END]
   ```

   So a stock installation selects unit-drawing path **2** ("only non-computer
   units"), not the built-in default of 3. This was invisible for as long as
   the tooling walked only `.lcl`: the command table used to show `?_` as never
   appearing in shipped data.
10. ~~**The AI's `MoveUnit` branch condition**~~ **— CLOSED.** The byte at
    destination-cell `+0x00` compared against `0x3c` at `0x0040abc7` is the
    **warp-destination overlay**, written by the range builder `0x00430ee0`
    immediately before the AI reads it — the counterpart of `10`, which the same
    pass writes on cells that can be *walked* to. The warp range comes from
    `0x00475380`: **5** for a unit carrying equipment 7 (`Jet Pack`, which
    `Info.lcl` itself annotates `* warp & scan`) with movement points left,
    **7** for a unit whose `SetUnitInfo` **special** column is 15 — the single
    shipped type being `Ray'Coo` — and **0** otherwise, in which case no cell is
    marked and the branch can never be taken. §5 and
    [`10-lev-mission-format.md`](10-lev-mission-format.md) §4.5.
11. **`InsertUnit` argument 5** — **closed.** It is the unit-pool flag
    (`unit[+0x4d]`, §7.4 and `docs/21` §8), and both of its non-zero meanings are
    read by the engine: `1` marks a unit-pool candidate and `2` a hero
    (`fcn.0046f7e0`, `fcn.00478f20`, and the Mission Control screen's
    `rec[+0x4D] == 2` tests at `0x00458449` / `0x0045958d` / `0x0045ac1a`). That
    it is `0` at all 413 shipped call sites means no *mission script* exercises
    it — the flag is set from the editor instead — not that the behaviour is
    unverified.
12. ~~**The special-object table beyond its count** *(opened 2026-09-24)*. The
    remake models `[0x004FA80C]` as `{model, x, y, z}` records (§7.4's
    `Spores` / `GrowingLand` notes). Four readings are **UNVERIFIED**:
    (a) the load's count equals the `.lev`'s special-object count -- read off
    `aLoadFile`'s destination `0x004FA528`, whose tail holds `[0x004FA7B4]`,
    and not read back from a live process; (b) an object `Platform` or
    `MoveWorld` carries keeps its authored position in the table -- the engine
    moves the record, the remake moves only the picture; (c) the footprint of
    an object inserted at run time (a spore, a hole) is taken to be its own
    cell, since the converter projects footprints for `.lev` records only; and
    (d) `FootBridge`'s search is anchored on the command cell's marker. None
    changes a shipped mission's outcome that we know of; each is a place a
    live read with `dbgcall` would settle it.~~ **Closed 2026-09-26** by
    `tools/presentation_gold.py`'s `land_table_*` phases (§7.4, the paragraph
    after the table's own): (a) the count and the records are the `.lev`'s on
    152/152 loadable missions; (c) a run-time spore, hole or growth marks its
    own cell and nothing else, 5/5 live and 4 096/4 096 headings by
    `inclib.footprint`; (d) `FootBridge` searches around the command cell's
    marker and frees the `L025EB00` it finds. (b) closed **against the
    remake**: `Platform` moves the found record `dist · 3200` in the table,
    6/6 on `_C_105`, and `MoveWorld` leaves the table alone (it moves the
    `.3DW` clones). The same capture corrected `Platform`'s step 4: the ride
    does not carry the cell height. **The remake follows** (changed
    2026-09-27): (a), (c) and (d) already matched --
    `MapState.from_resource` loads the converter's records in table order,
    `LclContext.footprint_of` falls back to the record's own cell for a
    run-time record, and `_foot_bridge` searches `marker(x, y)` in a
    5000-unit box. `Platform.ride` now moves the record its search finds
    (`MapState.move_land_object`), leaves both cells' heights alone and
    carries `+0x0E`..`+0x10` with the type; `_foot_bridge` frees a fire,
    mine or shield on the block first. `test_lcl.gd`'s
    `synthetic.platform_*` and `foot_bridge.frees_a_fire_on_the_block`
    pin them, each mutation-checked against the old rule. Not followed: the
    source cell's `+0x0C` and its unit link (`0xFFFF`) are not cleared,
    because the remake keeps a refused rider's link (§7.4 step 3).
    `inclib.lcl_runtime` follows the cell half too (the height stays, the
    three effect bytes move, `FootBridge` frees the block's objects); it
    carries no special-object table, so the record move is the remake's
    alone.

### Settled since the previous edition

| Was open | Now |
| --- | --- |
| `Platform` arguments 1–2 (destination or source?) and argument 4 | Settled: `(x,y)` is the platform's **current** centre tile and argument 4 is the **distance in tiles**, not a platform id (§7.4, `0x00412a00`, arithmetic on `_C_105.lcl`). |
| Argument roles of the animation and set-piece commands | Settled for `Barrier`, `Elevator`, `Platform`, `MoveWorld`, `CreateBGB`, `FootBridge`, `FootBridge2`, `OpenDoor`, `OpenFrontDoor`, `OpenTube`, `OpenPlantTube`, `CrushWall`, `GrowingLand`, `FixedStatue`, `Statue`, `Statue2`, `RotatingCamera`, `FireCircle`, `SetGroundFire`, `Spores`, `FallingSpores`, `MoveTarget`, `MovePosition`, `MoveCamera`, `RoofUnit`, `GroundUnit`, `Bridge`, `MoveObjects`/`MoveFireCircles`/`MoveSpores`, `LinkChrWithGroup` (§7.4). |
| Two different direction encodings | Found: `Platform` is 0=N,1=W,2=S,3=E; `Barrier` and `FixedStatue` are 0=S,1=W,2=N,3=E (§7.4). |
| `InsertUnit` argument 5 (`unit[+0x4d]`) | Settled: the unit-pool capture flag (§7.4). |
| `GUI_*` argument roles | Settled except `PressDown` and `Style` (§7.4). |
| `SetVolumeCtrl` index space | Settled: `docs/21-info-lcl-schema.md` §6 — indices below 50 are weapon ids, 50..102 are named sounds, and the code-derived mapping matches `Info.lcl`'s own comments. |
| `SetWeaponInfo`'s "Def Mod" | Settled: the defence-/overwatch-mode flag (`docs/21` §4). |
| `SetUnitInfo` columns 5, 6, 7, 8, 9, 13, 15 | Settled: `docs/21` §5. |
| What consumed `WorldDesc/*.lcl` | Settled: the *Select Object* dialog in the shipped `Incubation.exe` (`aSelectObject.cpp`, `0x00465140`) — §7.5. |
| Which `MoveUnit` host path runs when | Settled for both hosts: the UI selects on its pending-command global, the AI on the warp-destination overlay `0x3c` (§5, item 10). |
| `?_`'s behaviour and storage | Settled (§7.4); only the name is missing. |
| `SetVarRandom`'s distribution | Settled: `0x00463870(0, n)` = uniform in `0 … n-1`. |
| The special-object table's load, `Platform`'s and `FootBridge`'s use of it, and a run-time object's footprint (item 12) | Settled live, 2026-09-26 (§7.4, `presentation_gold.py` `land_table_*`). |
| Which slot `InsertUnit` fills | Settled live, 2026-09-26: the lowest `+0x16 == 0`, refused at 199, slot 200 when full (§7.4, `turn_gold.py` phase 15). |

Two things earlier editions had no way to see turned up on the way:
`SetVarVar` is broken in the shipped interpreter (§8.2), and eight weapon
records in `Info.lcl` end up in memory with a `range min` of 0 rather than the
value in the file (`docs/21-info-lcl-schema.md` §4).

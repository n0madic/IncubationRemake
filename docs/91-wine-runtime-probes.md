# Wine runtime probes

This note records the bounded runtime work performed against the original
32-bit `Incubation.exe` under Wine on macOS. It is an evidence log and a
reproduction guide, not a claim that Wine is an authoritative oracle for every
game subsystem.

The useful outcome is twofold:

1. a patched copy can enter a real campaign save without traversing the intro,
   main menu and campaign-map screens; and
2. a per-tick blob arm can be sampled without `winedbg`, while preserving the
   scratch registers used by the probe, executing the arm's displaced
   instructions and returning to the original control flow.

The original executable was never modified in place.

**The patched copies are historical.** Both results were first obtained by
writing a derived `.exe`; they are now reproduced by patching the running
process instead, with `tools/dbgcall_patches.py` generating the arguments and
`tools/dbgcall/` applying them. Nothing about the evidence changed — §6 of
that generator's self-test reassembles every stub at the address the patched
builds used and requires byte-identical output, which is what carries the
confirmed run below across to the runtime route. What changed is that there is
no derived artifact to hash and keep, and that each site is checked against the
**loaded** image rather than the file.

---

## 1. Artifacts and environment

| Artifact | SHA-256 | Role |
|---|---|---|
| `gog_incubation/Incubation.exe` | `b07aa2478fbfaf252a585cff180d03b468d5141e0fdb5606bd09f0891024fcc9` | Original PE32/i386 TestVersion executable; patch source |
| `Work/Saves2/_6_.sav` | `5e7ddd984b41f8601276f4a852469ffda45b6f2c7a1424751f1f8a5f1024ff06` | Started second-level save used by the probe |
| `Incubation-trace-load-save-6-v7.exe` | `cc057ce697cd7b8f8e80ed693e86116f90a1299c89be563bacef0edab55d02e8` | First confirmed direct-save build (historical) |
| `Incubation-trace-load-save-6-kind15-inline-v2.exe` | `add1dc7b603e80060b42d41d8960cc0d1e17176c44e3da4ffb42434addcd60ee` | Direct-save build with the successful kind-15 inline probe (historical) |

The confirmed run used Wine 11.0 on an Apple M4 Max host and a 640×480 Wine
virtual desktop. Wine startup itself is intermittent on this host: a failed
`wineserver` connection followed by an unchanged successful retry is an
environment result, not evidence about game control flow. The same goes for an
access violation at a Wine address before the anchor is reached — one capture
session saw the start-up fault five times across four phases and every phase
went through on a retry, so **every phase that runs a plan must retry**, and a
phase capped at fewer attempts than the rest lost a probe it had already
taken once.

**`cd /d` under this Wine's `cmd` returns a non-zero exit status even where it
works.** A launcher written as `cmd /c 'cd /d "<dir>" && <program> > log'`
therefore short-circuits and runs *nothing*: no log is written, no breakpoint
line appears, and the retry loop reports the anchor as unreachable when the
target was never started. It worked before a Wine update and stopped after
one, silently. Two further traps in the same line: this `cmd` will not run a
command whose name is a **quoted** absolute path (`"Z:\...\prog.exe"` is "not
recognised"), and `wine explorer /desktop=` detaches the console, so a `cmd`
wrapper and its `>` redirect are how output reaches a file at all.

The launcher that works sets the working directory from the **Unix** side —
Wine maps it to the current drive — and leaves the command line free of paths
entirely: `subprocess.Popen(["wine", "explorer", "/desktop=...", "cmd", "/c",
"prog.exe args > name.log 2>&1"], cwd=game_copy)`. That removes the `cd`, the
quoting and the space-in-path hazard in one move.

The executable used its preferred base `0x00400000` in the observed runs. The
addresses below are therefore written both as image-relative anchors and as
the observed VAs where useful.

---

## 2. Direct loading of save slot 6

The TestVersion executable does not use the retail `Work/Saves` directory.
`aBuildSaveFilename` `0x00449340` selects `Work/Saves2` through the TestVersion
flag read by `0x0043BEE0`, and formats a slot as `%s\\_%d_.sav`. Putting the
fixture only in `Work/Saves` reproduces the campaign shell but does not load the
saved mission.

`tools/dbgcall_patches.py --mode direct-save-6` preserves the original
controllers and changes only their dispatch:

1. the known intro bypass enters the real main-menu builder;
2. the state-4 menu run call is redirected to a stub;
3. that stub selects ordinary campaign-save mode, sets program state 11 and
   recursively calls `aMainController`;
4. `aRunLoadSave` is redirected to a second stub which calls
   `aLoadGame(6)`, sets state 16 and recursively calls `aMainController` again.

The stubs used to live in the executable's tail padding, because a patched
file has nowhere else to put them. They are now `--code` pages, and the calls
inside them are `{rel32 ...}` holes filled in once the page has an address.

The recursive calls are required because these controllers do not sit inside
one outer dispatch loop. Merely writing states 11 and 16 leaves the old screen
visible; reproducing the callbacks' recursive transition loads `_6_.sav`
directly into playable mission `_C_141`, turn 1.

This path was confirmed interactively: the saved level appeared, units could
be selected and several weapon shots completed. Earlier variants which showed
`End of game`, the first campaign location, or a main-menu stall are
superseded.

---

## 3. Why `winedbg` is not the tracing transport

Three debugger experiments failed before producing a valid gameplay-arm
sample:

| Probe | Observation | Classification |
|---|---|---|
| attach `winedbg` to a running direct-save build | repeated bogus WOW64 context, including `EIP=0xFFF40D6C`, `ESP=0x0458FF44`; `continue` returned to the same fault | Wine/debugger transport failure |
| spawn the executable under `winedbg` | a pre-map absolute breakpoint was disabled as an invalid address; continuing without it terminated the process | Wine/debugger transport limitation |
| custom i386 client using `DEBUG_ONLY_THIS_PROCESS` | before the requested arm, Wine reported an unhandled write fault at `0x0044B1CE`, the client disappeared and Wine started its emergency `winedbg` | the same Debug API path is unreliable, independent of the `winedbg` UI |

An `INT3` at the common `aBlob_Update` entry `0x0041E500` also proved too broad:
the front end itself owns blobs, so it stops on a real menu effect before the
direct-save transition. Moving the trap to kind 32 avoided the menu, but shots
from the saved unit did not select that overload. This was retained as a
negative control rather than reinterpreted as a missing effect.

None of these observations establishes anti-debugging in the game. They
establish that this Wine/WOW64 exception transport is unsuitable for the
runtime evidence gate. Static specifications and deterministic reference tests
remain the primary oracle; Wine is used for bounded observations.

### 3.1 A route that does work — **[runtime]**

The conclusion above is about stopping *late*. There is a way to reach a loaded
mission with the debugger still attached, and the first vertical slice used it
to call `aBuildMoveMap` sixty times inside a live `Incubation.exe`
([`93` §4](93-slice-1-report.md), `tools/movemap_gold.py`):

* **Anchor inside `aGameIntro`, at `Incubation.exe+0x4bd6f`.** By then the front
  end has initialised and `Info.lcl` is loaded, but no screen has been built.
  Crucially it is reached *before* the start-up path this Wine build faults on:
  breakpoints at `aMainController` (`0x0042E690`) and at the main-menu builder
  (`0x0044C170`) are never reached, and the log shows a first- and last-chance
  `0xC0000005` at a Wine DLL address on the way there. This one is reached.
* **Load the mission by calling the game's own routines**, not by patching the
  controller dispatch: `aSetSaveMode(0)` then `aLoadGame(6)`. No `--poke`, no
  `--resume`, no patched executable, and no human playing to the mission.

After the load, `aGetCtrlMapElementPtr(0,0)` returns an allocated map whose
9200 bytes match `_C_141.lev` in field type, height and action point and differ
in exactly four unit links — the squad deploying onto the action-point-1 cells.
Both large reads need the `--read` cap raised from 4096 (9200 bytes of control
map, 18200 of unit array); it is now 262144.

Two things this does **not** overturn: Wine start-up on this host stays
intermittent, so the launcher retries and a run that never reaches the anchor is
an environment result; and a *patched* copy faulted at the same Wine DLL address
in every attempt, which is a further reason the unpatched image plus called
routines is the route to prefer.

---

## 4. Successful inline sample: tracer kind 15

The weapon tables in [`28`](28-effects-and-sound.md) map Standard Assault Rifle
to the `aBlob_CreateTracerBullet` overload at `0x004247C0`. Its constructor
calls create:

- the moving tracer at `0x00424BD2`, `kind = 15`; and
- a casing at `0x00424C5D`, `kind = 11`.

Kind 15 dispatches to `Incubation.exe + 0x20734`, observed VA `0x00420734`,
file offset `0x1FB34`. Its first two instructions are:

```asm
mov edx, [esi + 0x48]
mov ebp, [esi + 0x14]
```

The inline probe replaces those six bytes with a jump to executable tail
padding at `0x004B0900`. The trampoline:

1. records the live `ESP` and blob pointer `ESI`;
2. writes `0x00420734` as an **arm marker** (not a debugger-captured EIP);
3. increments a hit counter;
4. preserves the scratch registers used for the copy;
5. copies the complete 88-byte blob before this arm mutates it;
6. restores those registers, executes the two displaced instructions and jumps
   back to `0x0042073A`.

The hit-counter increment changes the incoming arithmetic flags before the
trampoline saves and restores them. This arm does not consume those incoming
flags: the displaced instructions are `mov`s and `add ebp, edx` at
`0x00420740` establishes fresh flags before any later conditional use. The
runtime continuation result therefore applies to this arm; a generalised
trampoline must either preserve flags before instrumentation or prove the same
property for its selected arm.

The trace buffer was `0x00524F00..0x00524F77`, in the last page of the
writable virtual tail of `.data`. Static xrefs reach only through
`0x00524334`, and a pre-shot runtime read confirmed
`0x00524F00..0x00524F6F` (the first 112 bytes) were zero; the final eight
bytes of the 120-byte range were not included in that baseline read. An
earlier candidate at `0x004FA500` looked zero in the file but held live
pointers after loading; it was rejected before the arm executed. File padding
is therefore not accepted as free runtime storage without a live negative
control.

That whole hazard is now avoidable: the buffer is a `--buf` on a page
`VirtualAllocEx` returned, which is nobody else's by construction, and the
trampoline reaches its fields as `{&trace+4}`, `{&trace+8}` and so on. The
negative control above is what a page of one's own makes unnecessary — it is
kept here because it is why the rule exists.

### 4.1 Observed record

After several Standard Assault Rifle shots, the buffer contained:

| Field | Value |
|---|---:|
| live `ESP` | `0x0022EE54` |
| live `ESI` / blob pointer | `0x019E42A8` |
| arm marker | `0x00420734` |
| hit count | `230` (`0xE6`) |
| blob kind `+0x44` | `15` |
| blob life `+0x45` | `0` in the last captured tick |
| position `+0x14/+0x18/+0x1C` | `(16376, 33886, 1750)` |
| velocity `+0x48/+0x4C/+0x50` | `(595, 2192, -47)` |
| class `+0x56` | `0` |

The hit counter remained `230` on a later read after the tracer lifetime had
ended. The same game process remained alive and visible, and the user had
completed multiple shots after the trampoline began executing. This closes the
representation, dispatch and continuation gates for this one arm.

**Evidence boundary:** this is one runtime-confirmed arm out of 74 distinct
arms. It validates the blob layout, the kind-15 dispatch and the feasibility of
non-exception inline capture. It does not yet validate every arm or the
original return values of the orientation, geometry and target-map service
hooks used by other arms.

---

## 5. Reproduction

Nothing is written to disk. `tools/dbgcall_patches.py` reads the original
image, gates it on SHA-256, checks that every site still holds the bytes it
declares, and prints the arguments; `dbgcall` applies them to the live process
at the entry point and `--resume` leaves them in place.

```bash
python3 tools/dbgcall_patches.py gog_incubation --selftest      # 15 checks

i686-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -municode -static \
    -o dbgcall.exe tools/dbgcall/dbgcall.cpp

python3 tools/dbgcall_patches.py gog_incubation \
    --mode direct-save-6 --trace-blob-kind 15 --plan > kind15.plan
```

The plan holds the four patches, the three stubs and the trace buffer, each
with a line saying what it is for. Run it from a **copy** of the game, never
from `gog_incubation/`:

For a headless call, the command above is sufficient. A resumed graphical game
needs the Wine virtual desktop, and the tested Wine build does not reliably
forward a long debugger command line when `dbgcall.exe` is passed directly to
`explorer`. Use `cmd /c` so both the arguments and the working directory reach
the debugger:

```bash
WINEDLLOVERRIDES="krnl386.exe16=d" \
  wine explorer /desktop=incdbg,640x480 cmd /c \
  'cd /d Z:\path\to\game-copy && Z:\path\to\dbgcall.exe \
     Incubation.exe --bp rva:0xae890 --resume --plan kind15.plan -- -english \
     > Z:\path\to\dbgcall.log 2>&1'
```

The copy must contain `Work/Saves2/_6_.sav`. In the live A/B run, the plain
route applied every poke but then hit Wine's display failure, while this
`cmd /c` route left a visible 640×480 `Incubation.exe` with the saved level
loaded. A confirmed patched binary shows the same plain-route display failure,
so the former is an environment confounder, not a live-patch failure.

### 5.1 Launch-context A/B (2026-08-27)

The distinction is now reproducible with the same original image and the same
three direct-save pokes:

| Route | Observable result | Classification |
|---|---|---|
| `wine dbgcall.exe ... --resume` | breakpoint at `0x004AE890`, all pokes accepted, then `NtUserChangeDisplaySettings -2` and framebuffer `0x506`; no `Incubation.exe` remained | Wine display failure; not a patch failure |
| confirmed `Incubation-trace-load-save-6-v7.exe` in the same plain route | the identical display errors | negative control for the live-patch hypothesis |
| `wine explorer /desktop=incdbg,640x480 cmd /c 'cd /d ... && dbgcall ...'` | log recorded PID `888`, breakpoint `0x004AE890`, all pokes, and detach; `inc_control ... info` saw `hwnd=001000A2`, visible `640x480` window; the user confirmed the saved level loaded | working graphical route |

Passing the long command directly as `explorer`'s target was not a valid
control: on this Wine build it lost the harness arguments (one attempt logged
`Unterminated "{" in byte pattern`) and hid the debugger's console. Keeping
the plan in a file and invoking it through `cmd /c` preserves both argument
boundaries and the game's relative `Work/Saves2` working directory.

`--command` prints the same thing as one long command line instead, and with
no flag the arguments come out one per line, for `mapfile -t A < <(...)`.

What the harness prints is the record of the run — the page each stub landed
on, and the bytes each site held before it was patched:

```
[+] breakpoint hit at Incubation.exe+0xae890 on thread 628
[+] buf trace at 0x01510000, 256 bytes
[+] code tramp at 0x01540000, 61 bytes
[+] poke at Incubation.exe+0x20734: 8b56488b 6e14 -> e9c7f811 0190
```

Without `--resume` the target is killed at the breakpoint, which is the cheap
way to confirm the sites and the displacements without starting a session.

The `buf trace` line is what makes the buffer readable afterwards: unlike the
old fixed `0x00524F00`, the address is chosen per run, so it has to be taken
from that line and handed to
`tools/wine_control/inc_control.exe PID readmem ADDR LEN`, which reads it from
outside while the game is still running.

`tools/wine_control/inc_probe.exe` is the minimal Win32 Debug API experiment
described in §3. It builds successfully but is not a working transport on the
tested Wine configuration; it is kept as the negative control.

The three INT3 modes the old generator offered are gone. `dbgcall --bp` plants
breakpoints properly, and §3 is the record of why an INT3 in the gameplay path
is the wrong instrument here regardless of who writes it.

## 6. Separate DirectDraw/WineD3D A/B

The renderer failure was tested independently from the kind-15 patch. Every
run below used a fresh copy of the original image in an isolated Wine prefix;
the working game process in the main prefix was left untouched.

| Route | Observation | Classification |
|---|---|---|
| `WINE_D3D_CONFIG=renderer=gl` | OpenGL initialised, then repeated `GL_INVALID_FRAMEBUFFER_OPERATION (0x506)` from `glClear` and `NtUserChangeDisplaySettings ... -2` | Wine/macOS OpenGL failure |
| `WINE_D3D_CONFIG=renderer=vulkan` | The 16-bit primary requested by the game was rejected: `Failed to find Vulkan swapchain format for WINED3DFMT_B5G6R5_UNORM` | Wine Vulkan format gap |
| Vulkan plus `+0x32d61` `mov edi,16` → `mov edi,32` | The 32-bit swapchain was created, so the format error disappeared; the direct-save route then emitted `Unhandled location WINED3D_LOCATION_DRAWABLE` and faulted at a Wine address ending in `+0xDA48`. `csmt=0` and a valid NVIDIA PCI-ID override did not change it | partial diagnostic only; not a safe game patch |
| `WINE_D3D_CONFIG=renderer=gdi` (alias `no3d`) | A visible 640×480 window remained up with no FBO or display-mode errors; Wine explicitly logged `Disabling 3D support`. The kind-15 buffer stayed zero, so no playable 3D or arm sample was established | stable 2D/logic diagnostic route, not a gameplay renderer |
| `-3dfx` | The bundled nGlide `glide*.dll` path still reaches D3D9. With the default renderer it reproduces the OpenGL failure; with Vulkan it gives either `3Dfx card not detected` or the same `DRAWABLE` fault | not a DirectDraw bypass |

The 32-bit experiment is deliberately a runtime argument probe, not a
replacement executable: it changes only the value passed to the game's
`SetDisplayMode` call at VA `0x00432D61` (RVA `0x32D61`). It does not convert
the game's RGB565 surfaces, which is why it cannot be promoted to a fix.

### 6.1 Native DirectDraw wrappers

To test a layer outside WineD3D, the following 32-bit wrappers were placed next
to the game and selected with `WINEDLLOVERRIDES=ddraw=n`: cnc-ddraw 7.1.0
(OpenGL and GDI profiles, including its Windows-ME build), DXGL 0.5.27, D7VK
2.1, and dxwrapper 1.8 with `Dd7to9=1`. Each process spun without creating an
`Incubation` window and produced the same host-side
`rosetta error: LDT ... not supported`; no wrapper run reached a game frame.
This is a wrapper/Wine-on-Apple-Silicon negative control, not evidence that the
game rejects DirectDraw. DDrawCompat was not treated as a positive candidate
because its own documentation excludes Wine as a supported environment.

The bounded conclusions are therefore:

1. `renderer=gdi` is the only isolated route that cleanly removes both the
   WineD3D FBO and display-mode errors, but it disables the 3D path needed for
   a gameplay trace.
2. Vulkan plus the 32-bit probe removes one format mismatch but exposes a
   second, unimplemented `DRAWABLE` path and is crash-prone.
3. The confirmed playable route remains the original Wine renderer through
   `explorer /desktop ... cmd /c`; renderer substitution is not yet a valid
   replacement for a Windows run.

## 7. Next runtime slice

`tools/dbgcall_patches.py --trace-blob-kind KIND` already takes the arm as a
parameter; what it does not have is a second entry in its `BLOB_ARMS` table.
Adding one is not mechanical — the jump has to displace whole instructions,
and whether the arm consumes the incoming flags is a property of that arm —
so it stays one arm and one input per run. For each new sample, retain:

- the original artifact hash and the generator's self-test result;
- kind, creator, constructor call, arm RVA and displaced bytes;
- a zero-buffer control before the trigger;
- live registers and the complete pre-arm blob;
- a post-trigger continuation check; and
- the exact boundary being validated, especially for service-hook arms.

The debugger failures above should not be retried without a changed Wine build
or a different Windows environment.

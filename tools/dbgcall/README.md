# dbgcall

Calls functions inside a live 32-bit Windows process. It runs the target under
a debugger, waits for a breakpoint, then calls whatever you name, with
arguments of your choosing, and reports what came back.

Nothing here is specific to this game or to Wine: it is an ordinary Win32
debugger, and any 32-bit x86 target will do.

It is the runtime counterpart to `tools/wine_visn/`. That harness calls a
codec DLL out of process; this one calls an arbitrary function *inside*
`Incubation.exe` or `iDesigner.exe`, with the engine's own globals already
initialised — which is the only way to exercise code that depends on engine
state rather than on its arguments alone.

A batch run emits JSONL, so a set of calls can be checked against a Python
model the same way every other claim in this repository is: `N/N`, or
it is a guess.

## Build

```bash
i686-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -municode -static \
    -o dbgcall.exe tools/dbgcall/dbgcall.cpp
```

Both trailing flags matter:

- `-municode` — the entry point is `wmain`; without it the link fails with
  `undefined reference to WinMain`.
- `-static` — otherwise the exe needs `libstdc++-6.dll` and `libgcc_s_dw2-1.dll`
  beside it. Under Wine a missing one produces exit code 53 and **no output at
  all**, which looks like a harness bug rather than a link problem.

x86 only: the file refuses to compile as x64, and rejects a native x64 target
at runtime.

## Addresses

`--sig` and `--call` are both repeatable, so one command line can declare
several functions and call them in the order written — a plan file is for
when that list gets long, not a requirement for calling more than one
function:

```bash
dbgcall.exe game.exe --bp rva:0x1565 \
    --sig "i32 add(i32,i32) = rva:0x14b0" \
    --sig "__stdcall i32 sub(i32,i32) = rva:0x14fe" \
    --call "x = add(1,2)" --call "sub(\$x,3)"
```

Several `--bp` may be given: the first anchor the target reaches wins and the
rest are removed. That covers a build whose path is not certain — a renderer
chosen at runtime, or a module that may never load — in one run instead of
several.

```
0x004014b0                absolute runtime VA
rva:0x14b0                RVA of the main image
Eng3d.dll+0x5678          module + RVA
[Incubation.exe+0x1255e8] an expression: an import thunk's slot here,
                          [[%esi]+0x10] for a virtual method
```

The fourth form is for a function whose address only the running process
knows. It is evaluated per call, so a vtable slot is read after whatever the
previous call did to the object.

The third form is not a convenience — for this game it is the only workable
one. `Eng3d.dll` appears in **neither** EXE's import table; it is brought in by
`LoadLibrary` at runtime. Its preferred image base is `0x00400000`, exactly
where the EXE already sits, so the loader relocates it on every single run.
`NewToolsR.dll`, `aWin.dll` and `ENGWLIB.DLL` all share a preferred base of
`0x10000000`, so at most one of them keeps it. An address read off a static
disassembly of any of these is meaningless until the debugger has watched the
module load.

Module bases come from `CREATE_PROCESS_DEBUG_EVENT` and
`LOAD_DLL_DEBUG_EVENT`. Names come from `GetFinalPathNameByHandleW` on the
event's file handle, falling back to `GetMappedFileNameW` and only then to
`lpImageName` — which is famously NULL or stale and must never be the primary
source. A breakpoint in a module that has not loaded yet is retried on every
subsequent load event, so `--bp Eng3d.dll+0x1234` works even though that
memory does not exist when the process starts.

## Declaring and calling

A **declaration** is a C-like signature with a name and an address. It is
self-contained, so it can be pasted into a doc, kept in a file, or written on
the command line unchanged:

```
__cdecl i32 aCheckLineOfSight(ptr,i32,i32) = Incubation.exe+0x46C460
```

Every call names a declaration — there is no second, address-and-arguments
form. One way to say a thing is enough, and the declaration is the half worth
keeping, because it is also what you write down in a doc.

A **call** names it, with expressions for the arguments:

```
aCheckLineOfSight(%esi, 12, 7)
hp = aGetUnitHitPoints(%esi)
```

A binding before the parameter list makes the result available as `$hp` to
later calls.

The two are told apart by where the `=` sits: after the parameter list it
introduces an address, so the line is a declaration; before it, it names a
binding, so the line is a call. That one rule is why declarations and calls
share a single file format with no directive keywords.

```bash
dbgcall.exe game.exe --bp rva:0x1565 \
    --sig "__thiscall f32 GetRange(ptr,i32) = Eng3d.dll+0x5678" \
    --call "GetRange(%esi, 3)"
```

Types: `i32 u32 ptr i64 u64 f32 f64 str wstr void bytesN`.

`this` under `__thiscall` is an **explicit** first parameter. The harness has
no notion of a class, and an implicit `this` would break the arity check that
gives the signature most of its value.

### Structs by value

`bytesN` is a struct passed by value. On x86 that needs no machinery: the
struct is simply its bytes on the stack, rounded up to whole slots, with no
hidden pointer and no register involved. Give the bytes as hex, or `*SOURCE`
to take them from the target — a `--buf` / `--blob` by name, or any
expression, so a struct sitting inside a live object can be passed straight
through:

```bash
--sig "i32 dot(bytes12,bytes12) = rva:0x1234"
--call "dot(010000000200000003000000, *other)"
--call "dot(*[%esi+0x40], *scratch)"
```

A length that does not match the declaration is an error, so a struct whose
size you guessed wrong fails loudly rather than shifting every argument after
it.

For `__fastcall` a `bytesN` argument is never register-eligible. MSVC will put
a 4-byte struct in ECX, but guessing wrong there is worse than making the
caller write `u32`.

A function that *returns* a struct by value needs no new syntax. MSVC passes a
hidden pointer as an implicit first argument and returns it in EAX, so declare
that pointer explicitly and hand it a `--buf`:

```bash
--sig "ptr makevec(ptr,i32,i32,i32) = rva:0x5678"
--buf out:12 --call "makevec(&out, 1, 2, 3)" --dump out
```

### Conventions

| convention | registers | stack | cleanup |
| --- | --- | --- | --- |
| `__cdecl` (default) | — | all args | caller |
| `__stdcall` | — | all args | callee |
| `__thiscall` | ECX = arg0 (`this`) | rest | callee |
| `__fastcall` | ECX, EDX | rest | callee |

`__fastcall` follows the MSVC rule: the first two arguments of dword size or
smaller, scanned left to right, take ECX and EDX. A 64-bit or `f64` argument
is never register-eligible, and it does not consume a register either — a
later small argument still takes it. (`f32` is a dword but still travels on
the stack; MSVC never passes floating point in the integer registers.)

Callee-side cleanup needs no compensation. The stub stops the thread on an
INT3 immediately after the call and nothing ever resumes on that stack.

## Signature verification

The stub records ESP either side of the `call`, so the difference is exactly
the immediate in the callee's `ret K` — how many argument bytes it popped.
That is checked against the declaration:

| declared | expected delta | what it catches |
| --- | --- | --- |
| `__cdecl` | `0` | a function that is really `__stdcall` |
| callee-cleaning | declared argument bytes | **a wrong arity** |

A mismatch is a reported error, not a confident wrong number. This is the
difference between a signature as a convenience and a signature as a claim
with a check behind it. `--no-verify-sig` downgrades it to a note.

Honest limit: under `__cdecl` the caller cleans up, so the delta is zero for
any arity and arity cannot be checked there at all.

`--probe` turns the same measurement into a tool. It calls the function as
`__cdecl` — safe for a wrong guess, because our stub never reuses that stack —
and reports what the observed cleanup implies:

```
[0] rva:0x14fe(10, 3) = 7    [eax=0x00000007 esp+8]
      callee popped 8 bytes -> __stdcall family with 2 dword slot(s)
```

For a binary with no symbols that recovers both the convention and the arity.

With no convention stated the call is made as `__cdecl`, which is safe for a
wrong guess. State one and it is kept, so `__thiscall` and `__fastcall` can be
probed too — they need a sensible ECX, which only you can supply, but once
they have one the reported delta gives their real arity:

```
[0] method(0x00403004, 5) = 7005    [eax=0x00001b5d esp+4]
      called as __thiscall, callee popped 4 bytes -> 1 stack slot(s); the
      signature declares 1
```

## Argument expressions

Integral and pointer arguments are expressions, evaluated by the debugger
before the stub is written. The injected code never sees anything but final
numbers.

| form | meaning |
| --- | --- |
| `0x1234` | literal |
| `Eng3d.dll` | a loaded module's base address |
| `%esi` | register in the frozen breakpoint context |
| `$name` | EAX of an earlier call, bound by `name = call(...)` |
| `&name` | address of a `--buf` / `--blob` buffer |
| `[expr]` | dword read from target memory, at call time |
| `expr+0x10` | offset arithmetic |

So the object a method needs is usually right there: `method(%esi, 3)`, or
`method([%ebp+8], 3)`, or `method([[%esi+0x8]+0x24], 3)` for a field two hops
in. An argument may contain commas inside brackets, and a string argument may
be quoted — `slen("A,B")`.

`%reg` always means the snapshot taken at the breakpoint, never "after the
previous call". Results live under `$` precisely so the two cannot be
confused.

`i64`, `u64`, `f32`, `f64` and string arguments must be literals — an
expression evaluates to a single dword.

Buffers cover out-parameters and structs:

```
--buf out:64          zeroed buffer, allocated once for the whole run
--blob hdr:00112233   buffer holding those bytes
--zero out            clear it before this call
--dump out            hex dump it after this call
--read [%esi+0x40]:16 read 16 bytes at that address after this call
```

Buffers keep whatever a call left in them, so one call can fill a buffer and
the next read it. `--zero` is explicit for the same reason the signature rules
are strict: an automatic wipe between calls silently breaks a chain, and a
silently broken chain still prints plausible numbers.

## Batches

Repeat `--call`, once per invocation:

```bash
dbgcall.exe game.exe --bp rva:0x1565 \
    --sig "i32 los(ptr,i32,i32) = rva:0x46c460" \
    --call "los(%esi, 0, 0)" --call "los(%esi, 1, 2)" \
    --out jsonl -o los.jsonl
```

Past a handful, put them in a file. A plan holds declarations and calls in
the same syntax, one per line, so the command line does not grow with the
batch:

```
# plan.txt
__cdecl    i32 aCheckLineOfSight(ptr,i32,i32) = Incubation.exe+0x46C460
__thiscall i32 aGetUnitHitPoints(ptr)         = Incubation.exe+0x41A2E0

hp = aGetUnitHitPoints(%esi)
aCheckLineOfSight(%esi, 12, 7)
```

```bash
dbgcall.exe game.exe --bp rva:0x1565 --plan plan.txt
```

A call line may carry per-call options after it — `--dump`, `--read`,
`--zero`, `--probe`. `--plan` is repeatable, so a stable file of declarations
and a generated file of calls can be passed together.

The declaration table pairs naturally with the symbol table
`tools/trace_names.py` recovers: it has the names and the addresses, and a
signature is the column it is missing.

**There is deliberately no sweep or range syntax.** Ranges over more than one
argument need a rule for whether they multiply or advance in lockstep, and
another for what unequal lengths mean — a small language living inside the
harness, duplicating what the Python side of this repository already does, and
does better. Generate the lines:

```python
with open("plan.txt", "w") as f:
    f.write("i32 los(ptr,i32,i32) = Incubation.exe+0x46C460\n")
    for x in range(40):
        for y in range(40):
            if passable(x, y):          # a range could not express this
                f.write(f"los(%esi, {x}, {y})\n")
```

Throughput is roughly 400 calls/second under Wine on Apple silicon, so a
1600-call grid takes a few seconds.

Output is text for a single call and JSONL for a batch, overridable with
`--out text|jsonl`. Rows are flushed as they are produced: a batch that dies
on call 37 still hands back the first 36.

## Resuming instead of killing

By default the target is killed once the batch finishes. `--resume` instead
puts the thread back exactly where the breakpoint caught it — the whole frozen
context, floating point included — clears kill-on-exit, and detaches, so the
game carries on running:

```
[+] resuming the target at Incubation.exe+0xae890 and detaching
```

That is what makes "call this and watch what happens on screen" possible. Be
honest with yourself about what it means, though: the calls you just made ran
with the engine's real state, and anything they mutated stays mutated. Use it
to observe an effect, not to claim the run was side-effect free. A call that
faulted is never resumed.

## How a batch works

The target thread is hijacked at the breakpoint and **never resumed**. Each
call restores the whole frozen context, points EIP at the stub, and runs.

Two details are what make a long batch trustworthy rather than plausible:

- **The full context is restored, not just EIP.** Otherwise `and esp,-16;
  sub esp,N` walks ESP down the stack a little further on every call, and a
  few hundred calls later it is somewhere it should not be.
- **`CONTEXT_FLOATING_POINT` is part of the snapshot.** Every float return
  pops ST(0). If the balance is off anywhere, the x87 tag word fills up after
  eight calls and every later float comes back indefinite. Restoring the FPU
  state per call closes that off deterministically. The self-test runs eight
  float calls in a row for exactly this reason.

**The stub's code page is append-only.** The obvious design — one stub,
rewritten with fresh immediate operands per call — is self-modifying code, and
it silently breaks under an emulating Wine on arm64: the first version gets
translated, and rewriting those bytes reuses the stale translation, so every
call in a batch runs with the first call's arguments. `FlushInstructionCache`
does not help. So the code depends only on the *shape* of a call (slot count,
which registers are used, whether ST(0) is captured), one copy is emitted per
distinct shape at its own address, and the per-call arguments live in a
separate data page the stub reads. This was found by the self-test, not by
reasoning — a batch whose results were all identical.

## Failure modes

| situation | behaviour |
| --- | --- |
| module never loads | at exit, the unresolved address and the list of modules that did load |
| breakpoint never hit | said explicitly, rather than a silent exit |
| a call faults | the row is reported and the batch stops; `--continue-on-fault` carries on and marks every later row `tainted`, because the target's state is now suspect. A faulted target is never resumed, even with `--resume` |
| a call never returns | `--call-timeout` (default 5000 ms) gives up; the batch cannot continue, since the thread is stopped somewhere unknown |
| an argument expression fails | that row reports `arg-error` and the batch moves on |

One thing no code can fix: if the breakpoint sits in the middle of a mutation,
every call sees half-updated state. Pick a quiescent point.

## Limits

- `--probe` still cannot *guess* `this`; it only keeps a convention you state.
- `--resume` leaves the stub's pages and any `--buf` behind in the target.
  Freeing them would be wrong: the game may still hold a pointer into one.

## Verifying a change

There is no corpus for this tool. Its check is `selftest.sh`, which builds a
purpose-built 32-bit target (`selftest_target.c`) and a DLL
(`selftest_lib.c`) deliberately linked at image base `0x00400000` so the
loader must relocate it, just like `Eng3d.dll`. It reads every function
address back out of the built images, then exercises all four conventions,
every argument width, structs by value, the expression forms, buffers, module
resolution, deferred and multiple breakpoints, batches, plan files, signature
verification, `--probe`, `--resume`, and the fault and timeout paths:

```bash
bash tools/dbgcall/selftest.sh    # 51 passed, 0 failed
```

It exits non-zero on any mismatch. Run it after any change to the stub
emitter, the call layout or the debug loop.

## Against the real game

The self-test proves the mechanism; this proves it on shipped code, with an
answer that was already known independently.

### iDesigner.exe

`iDesigner.exe` loads `Eng3d.dll` through `LoadLibrary` at startup, and the
loader has to relocate it — in this run to `0x018d0000`, nowhere near the
`0x00400000` it asks for. The harness plants a breakpoint at
`_E3D_init_vision`'s entry when the module appears, then calls the real VISN
decoder:

```
# visn.plan
void initv(i32)          = Eng3d.dll+0x23d8
void decode(ptr,ptr,i32) = Eng3d.dll+0x23e8

initv(1381)
decode(&rec, &dst, 256) --dump dst
```

```bash
wine dbgcall.exe iDesigner.exe --bp Eng3d.dll+0x23d8 \
    --blob "rec:$(xxd -p -c0 record.bin)" --buf dst:131072 \
    --plan visn.plan --out jsonl -o visn.jsonl
```

```
[+] iDesigner.exe at 0x00400000
[+] breakpoint at ENG3D.DLL+0x23d8 (0x018d23d8)
[+] breakpoint hit on thread 284
[=] 2 ok, 0 failed, of 2 call(s)
```

The 131072 bytes the DLL wrote are **byte-identical** to what
`tools/inclib/visn.py` produces for the same record — the same equality
`tools/wine_visn` establishes for all 723 records, reached here through a
live game process instead of a purpose-built loader. `esp_delta` came back 0
on both calls, confirming the cdecl thunks that `tools/wine_visn/README.md`
describes.

### Incubation.exe

The game only loads the 3D engine when a mission starts, so waiting for it
means clicking through the menu. There is no need to: the breakpoint goes at
the EXE's own entry point, and the harness loads the DLL itself, through the
import thunk the loader has already filled in.

```
# inc.plan
__stdcall i32 LoadLib(str) = [Incubation.exe+0x1255e8]
void initv(i32)            = Eng3d.dll+0x23d8
void decode(ptr,ptr,i32)   = Eng3d.dll+0x23e8

h = LoadLib("ENG3D.DLL")
initv(1381)
decode(&rec, &dst, 256) --dump dst
```

```bash
WINEDLLOVERRIDES="krnl386.exe16=d" wine dbgcall.exe Incubation.exe \
    --bp rva:0xae890 --blob "rec:$(xxd -p -c0 record.bin)" \
    --buf dst:131072 --plan inc.plan --out jsonl -o inc.jsonl -- -english
```

```json
{"i":0,"call":"LoadLib","args":["ENG3D.DLL"],"eax":"0x01650000","esp_delta":4,"status":"ok"}
{"i":1,"call":"initv","args":["1381"],"eax":"0x00000565","esp_delta":0,"status":"ok"}
{"i":2,"call":"decode","args":["&rec=0x01610000","&dst=0x01620000","256"],"esp_delta":0,"status":"ok"}
```

Again byte-identical over all 131072 bytes. Three things worth noting:

- `LoadLib`'s `esp_delta` of 4 is the harness confirming `LoadLibraryA` is
  `__stdcall` with one dword argument, from the callee's own `ret 4`.
- `Eng3d.dll+0x23d8` in calls 1 and 2 resolved against a module that did not
  exist when the run started. The load event arrives while call 0's stub is
  still on the stack, and the module table takes it in mid-batch.
- Nothing here required the game to render a frame, open a window, or reach
  its menu.

### Environment notes

None of these are about the harness; all three bite a plain `wine
Incubation.exe` just as hard.

- **Windows version.** The game and the editor check for Windows 95 and exit
  silently otherwise. Set it for that binary alone rather than for the whole
  prefix:
  `wine reg add 'HKCU\Software\Wine\AppDefaults\Incubation.exe' /v Version /d win95 /f`
- **`rosetta error: LDT ... not supported`.** `Incubation.exe` statically
  imports the shipped `audio.dll`, which drags in Wine's 16-bit kernel
  (`krnl386.exe16`); that needs an LDT entry, which Rosetta refuses on arm64.
  It happens before the EXE's entry point, so no breakpoint in the image is
  ever reached. `WINEDLLOVERRIDES="krnl386.exe16=d"` disables the 16-bit
  layer and the game starts. `iDesigner.exe` does not import `audio.dll` and
  needs none of this.
- **`wine explorer /desktop=...` is not usable as a wrapper here.** It does
  not pass the harness's arguments through, and it swallows the console, so
  a failure looks like silence.

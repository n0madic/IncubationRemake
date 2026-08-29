#!/usr/bin/env bash
#
# Self-test for the x86 target function harness.
#
# There is no corpus for this tool, so its check is a purpose-built 32-bit
# target that exercises every calling convention, argument width, expression
# form and failure mode. Addresses are read back out of the built images, so
# the test does not rot when the targets are edited.
#
# Requires i686-w64-mingw32-gcc/g++ and a 32-bit-capable Wine.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${TMPDIR:-/tmp}/tfh_selftest.$$"
mkdir -p "$out"
trap 'rm -rf "$out"' EXIT

CXX=${CXX:-i686-w64-mingw32-g++}
CC=${CC:-i686-w64-mingw32-gcc}
OBJDUMP=${OBJDUMP:-i686-w64-mingw32-objdump}
WINE=${WINE:-wine}

echo "[*] building harness"
"$CXX" -std=c++17 -O2 -Wall -Wextra -municode -static \
    -o "$out/dbgcall.exe" "$here/dbgcall.cpp" || exit 1

echo "[*] building test DLL"
# Preferred base 0x00400000 collides with the EXE, so the loader must
# relocate it -- the same situation as the game's Eng3d.dll.
"$CC" -O1 -shared -Wl,--image-base,0x400000 \
    -o "$out/selftest_lib.dll" "$here/selftest_lib.c" || exit 1

echo "[*] building test target"
"$CC" -O1 -o "$out/target.exe" "$here/selftest_target.c" || exit 1

# --- address helpers -------------------------------------------------------

image_base() {
    echo $(( 16#$("$OBJDUMP" -p "$1" | awk '/^ImageBase/ { print $2 }') ))
}

# data_rva <image> <symbol>  ->  0xNNNN, for a symbol in .data
data_rva() {
    local image=$1 sym=$2 val secvma base
    # objdump -t prints "... (nx 0) 0xVALUE _symbol", and VALUE is relative
    # to the symbol's section.
    val=$("$OBJDUMP" -t "$image" |
          awk -v s="_$sym" '$NF == s { print $(NF-1) }' | head -1)
    secvma=$("$OBJDUMP" -h "$image" | awk '$2 == ".data" { print $4 }')

    if [ -z "$val" ]; then
        echo "[!] data symbol not found in $image: $sym" >&2
        exit 1
    fi

    base=$(image_base "$image")
    printf '0x%x' $(( val + 0x$secvma - base ))
}

# rva <image> <symbol>  ->  0xNNNN
rva() {
    local image=$1 sym=$2 vma base
    vma=$("$OBJDUMP" -d "$image" |
          sed -n "s/^0*\([0-9a-f]*\) <_\{0,1\}@\{0,1\}$sym\(@[0-9]*\)\{0,1\}>:.*/\1/p" |
          head -1)

    if [ -z "$vma" ]; then
        echo "[!] symbol not found in $image: $sym" >&2
        exit 1
    fi

    base=$(image_base "$image")
    printf '0x%x' $(( 0x$vma - base ))
}

# va <image> <symbol>  ->  0xNNNN, the address the image loads that symbol at
va() {
    printf '0x%x' $(( $(image_base "$1") + $(rva "$1" "$2") ))
}

# code_bytes <image> <symbol> <n>  ->  hex of the symbol's first n bytes, so a
# --poke's expected bytes are read out of the image rather than written down
# and left to rot.
code_bytes() {
    "$OBJDUMP" -d "$1" |
        awk -v s="<_$2>:" '
            index($0, s) { grab = 1; next }
            grab && NF == 0 { exit }
            grab {
                sub(/^[^:]*:\t/, "")
                sub(/\t.*/, "")
                gsub(/ /, "")
                printf "%s", $0
            }' |
        cut -c1-$(( $3 * 2 ))
}

exe="$out/target.exe"
dll="$out/selftest_lib.dll"

gobj=$(printf '0x%x' $(( $(image_base "$exe") + $(data_rva "$exe" g_obj) )))

# Breakpoint in the EXE, reached after the DLL is already loaded.
bp="rva:$(rva "$exe" t_ready)"

# Breakpoint inside the dynamically loaded DLL, which does not exist when the
# process starts -- this is the deferred-resolution path.
bp_dll="selftest_lib.dll+$(rva "$dll" tl_ready)"

# Declarations every named test shares. One syntax, one file: a line with
# `= ADDRESS` after the parameter list is a declaration, anything else is a
# call.
cat > "$out/decls.txt" <<EOF
# convention  return  name              parameters              address
              i32     add(i32,i32)                            = rva:$(rva "$exe" t_add)
              i32     zero()                                  = rva:$(rva "$exe" t_zero)
              u8      bytefn(i32)                             = rva:$(rva "$exe" t_byte)
              i8      sbytefn(i32)                            = rva:$(rva "$exe" t_byte)
              i32     dirtyfn(i32)                            = rva:$(rva "$exe" t_byte)
              f32     fmul(f32,f32)                           = rva:$(rva "$exe" t_fmul)
              f64     dmul(f64,f64)                           = rva:$(rva "$exe" t_dmul)
              u64     add64(u64,u64)                          = rva:$(rva "$exe" t_add64)
              i32     slen(str)                               = rva:$(rva "$exe" t_slen)
              i32     vec(bytes12,i32)                        = rva:$(rva "$exe" t_vec)
              i32     odd(bytes5)                             = rva:$(rva "$exe" t_odd)
__stdcall     i32     stdsub(i32,i32)                         = rva:$(rva "$exe" t_stdsub)
__fastcall    i32     fast3(i32,i32,i32)                      = rva:$(rva "$exe" t_fast3)
__fastcall    i32     fastmix(i32,f64,i32,i32)                = rva:$(rva "$exe" t_fastmix)
__thiscall    i32     method(ptr,i32)                         = rva:$(rva "$exe" t_method)
              i32     dllmul(i32,i32)                         = selftest_lib.dll+$(rva "$dll" tl_mul)
__stdcall     i32     dllstd3(i32,i32,i32)                    = selftest_lib.dll+$(rva "$dll" tl_std3)
              void    fill(ptr,i32,i32)                       = selftest_lib.dll+$(rva "$dll" tl_fill)
              i32     sum(ptr,i32)                            = selftest_lib.dll+$(rva "$dll" tl_sum)
              void    spin()                                  = selftest_lib.dll+$(rva "$dll" tl_spin)
              i32     nosuch(i32)                             = nosuch.dll+0x1000
EOF

pass=0
fail=0

harness() {
    local breakpoint=$1
    shift
    (cd "$out" && WINEDEBUG=-all "$WINE" dbgcall.exe target.exe \
         --bp "$breakpoint" --out jsonl --plan decls.txt "$@" 2>/dev/null)
}

# run NAME EXPECTED BP -- <harness args>
# EXPECTED is the `result` fields joined by '|'.
run() {
    local name=$1 expect=$2 breakpoint=$3
    shift 3

    local log got
    log=$(harness "$breakpoint" "$@")

    got=$(printf '%s' "$log" |
          sed -n 's/.*"result":"\([^"]*\)".*/\1/p' |
          tr -d '\r' | paste -sd'|' -)

    if [ "$got" = "$expect" ]; then
        echo "PASS  $name -> $got"
        pass=$((pass + 1))
    else
        echo "FAIL  $name"
        echo "      expected: $expect"
        echo "      got:      $got"
        printf '%s\n' "$log" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

# run_status NAME STATUS BP -- <args>: assert a non-ok status appears.
run_status() {
    local name=$1 status=$2 breakpoint=$3
    shift 3

    local log
    log=$(harness "$breakpoint" "$@")

    if printf '%s' "$log" | grep -q "\"status\":\"$status\""; then
        echo "PASS  $name -> $status"
        pass=$((pass + 1))
    else
        echo "FAIL  $name: expected status $status"
        printf '%s\n' "$log" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

# run_grep NAME PATTERN BP -- <args>: assert the output matches.
run_grep() {
    local name=$1 pattern=$2 breakpoint=$3
    shift 3

    local log
    log=$(cd "$out" && WINEDEBUG=-all "$WINE" dbgcall.exe target.exe \
              --bp "$breakpoint" --out jsonl --plan decls.txt "$@" 2>&1)

    if printf '%s' "$log" | grep -q "$pattern"; then
        echo "PASS  $name"
        pass=$((pass + 1))
    else
        echo "FAIL  $name: expected output matching /$pattern/"
        printf '%s\n' "$log" | sed 's/^/      /'
        fail=$((fail + 1))
    fi
}

# --- conventions -----------------------------------------------------------

run "cdecl    add(1,2)"            1002 "$bp" --call "add(1, 2)"

# A callee that sets only AL.  Declaring the width is the whole point: the
# upper 24 bits of EAX are the caller's leftovers, so an i32 declaration here
# reports a large number rather than 254 -- which is how a player id once came
# back as 4436480 instead of 0.
run "u8       only AL is the result"   254  "$bp" --call "bytefn(0)"
run "i8       AL, sign-extended"       -2   "$bp" --call "sbytefn(0)"

# The sensitivity probe for the two above: the *same* callee read as i32 must
# NOT come back as 254, or the masking is untested and EAX merely happened to
# be clean.
dirty_out=$(harness "$bp" --call "dirtyfn(0)")

if [ "$dirty_out" != "254" ]; then
    echo "PASS  u8       the upper EAX bits really are dirty"
    pass=$((pass + 1))
else
    echo "FAIL  u8       EAX was already clean, so the mask is untested"
    fail=$((fail + 1))
fi
run "cdecl    fmul(2.5,4)"         10   "$bp" --call "fmul(2.5, 4)"
run "cdecl    dmul(2.5,4)"         10   "$bp" --call "dmul(2.5, 4)"
run "cdecl    add64(2^32,5)"       4294967301 "$bp" \
    --call "add64(4294967296, 5)"
run "cdecl    slen(LEVEL02B)"      8    "$bp" --call "slen(LEVEL02B)"
run "cdecl    zero()"              0    "$bp" --call "zero()"
run "stdcall  stdsub(10,3)"        7    "$bp" --call "stdsub(10, 3)"
run "fastcall fast3(1,2,3)"        123  "$bp" --call "fast3(1, 2, 3)"

# a -> ECX, c -> EDX, the double and d on the stack.
run "fastcall fastmix"             1234 "$bp" --call "fastmix(1, 2.0, 3, 4)"
run "thiscall method(+5)"          7005 "$bp" --call "method($gobj, 5)"

# A quoted string keeps its commas.
run "cdecl    slen(\"A,B\")"       3    "$bp" --call 'slen("A,B")'

# --- structs by value ------------------------------------------------------

# Vec3{1,2,3} is 01000000 02000000 03000000 little-endian; three whole slots.
run "byval    vec3 by value"       1020304 "$bp" \
    --call "vec(010000000200000003000000, 4)"

# Five bytes occupy two slots, the second zero-padded.
run "byval    5 bytes, padded"     15 "$bp" --call "odd(0101010101)"

run_grep "byval    a wrong length is caught" "bytes were given" "$bp" \
    --call "vec(0102, 4)"

# *EXPR reads the struct straight out of the target. g_obj.base is 7000 =
# 0x1b58, so its four bytes are 58 1b 00 00 and odd4 returns
# 0x58 + 0x1b * 2 = 142.
run "byval    *expression from memory" 142 "$bp" \
    --sig "i32 odd4(bytes4) = rva:$(rva "$exe" t_odd4)" \
    --call "odd4(*$gobj)"

# *name passes a buffer's current contents by value, so a struct the target
# filled in can be handed straight back.
run "byval    *buffer contents"    1020304 "$bp" \
    --blob v3:010000000200000003000000 --call "vec(*v3, 4)"

# --- signature verification ------------------------------------------------

run_status "verify   wrong arity is caught" sig-mismatch "$bp" \
    --sig "__stdcall i32 bad(i32) = rva:$(rva "$exe" t_stdsub)" \
    --call "bad(10)"

run_status "verify   stdcall declared cdecl is caught" sig-mismatch "$bp" \
    --sig "i32 wrongcc(i32,i32) = rva:$(rva "$exe" t_stdsub)" \
    --call "wrongcc(10, 3)"

run "verify   --no-verify-sig keeps going" 7 "$bp" \
    --no-verify-sig \
    --sig "i32 wrongcc(i32,i32) = rva:$(rva "$exe" t_stdsub)" \
    --call "wrongcc(10, 3)"

run_grep "probe    stdcall reports 8 bytes popped" '"esp_delta":8' "$bp" \
    --call "stdsub(10, 3)" --probe

# A stated convention is kept, so __thiscall can be probed too: `this` reaches
# ECX and the callee survives to report its own cleanup.
run_grep "probe    thiscall keeps its convention" '"esp_delta":4' "$bp" \
    --call "method($gobj, 5)" --probe

run_grep "probe    fastcall keeps its convention" '"esp_delta":4' "$bp" \
    --call "fast3(1, 2, 3)" --probe

# --- expressions -----------------------------------------------------------

# [gobj] is g_obj.base == 7000.
run "expr     [addr] deref"        7000000 "$bp" --call "add([$gobj], 0)"
run "expr     [addr]+offset"       7003000 "$bp" --call "add([$gobj]+3, 0)"

# add(1,2) = 1002, then add(1002,0) = 1002000.
run "expr     \$binding chain"     "1002|1002000" "$bp" \
    --call "first = add(1, 2)" --call "add(\$first, 0)"

run_grep "expr     a bad expression is reported" '"status":"arg-error"' "$bp" \
    --call "add(\$nosuchbinding, 0)"

run_grep "expr     a literal-only parameter is named" "needs a literal" "$bp" \
    --call "dmul(%esi, 1.0)"

# An address that is itself an expression, naming a module: this is the shape
# an import thunk's slot or a vtable entry takes. g_addptr holds &t_add.
run "expr     call through a pointer" 1002 "$bp" \
    --sig "i32 viaptr(i32,i32) = [target.exe+$(data_rva "$exe" g_addptr)]" \
    --call "viaptr(1, 2)"

# [target.exe+0] is the "MZ" of the PE header, so the pointer read there
# points nowhere; the guard rejects it instead of jumping into it.
run_status "expr     a bogus function pointer is caught" unmapped "$bp" \
    --sig "i32 bogus(i32) = [target.exe+0x0]" --call "bogus(1)"

# --- buffers ---------------------------------------------------------------

# tl_fill writes seed..seed+n-1; ten bytes from seed 1 come to 55.
# `void` emits no result field, so only the sum shows up.
run "buffer   fill then sum"       55 "$bp" \
    --buf scratch:10 \
    --call "fill(&scratch, 10, 1)" --call "sum(&scratch, 10)"

run_grep "buffer   --dump shows what the callee wrote" \
    '01020304 05060708 090a' "$bp" \
    --buf scratch:10 --call "fill(&scratch, 10, 1)" --dump scratch

# --- module resolution -----------------------------------------------------

run "module   dll+rva, relocated"  305   "$bp" --call "dllmul(3, 5)"
run "module   stdcall inside dll"  10203 "$bp" --call "dllstd3(1, 2, 3)"
run "module   breakpoint in dll"   705   "$bp_dll" --call "dllmul(7, 5)"

run_status "module   unknown module is reported" unresolved "$bp" \
    --call "nosuch(1)"

# --- several anchors -------------------------------------------------------

# The first --bp names a module that never loads; the run still works.
run "bp       an unresolvable anchor is skipped" 1002 "$bp" \
    --bp "nosuch.dll+0x1000" --call "add(1, 2)"

# The target calls tl_ready() before t_ready(), so the DLL anchor wins even
# though the EXE one is listed first.
run_grep "bp       the anchor reached first wins" \
    "breakpoint hit at selftest_lib.dll" "$bp" \
    --bp "$bp_dll" --call "add(1, 2)"

run_grep "bp       none reached is reported per anchor" "never resolved" \
    "nosuch.dll+0x1000" --bp "alsomissing.dll+0x20" --call "add(1, 2)"

# A target that wedges before the anchor: alive, no further debug event, no
# plan line run.  The wait before the first breakpoint used to be INFINITE, so
# this hung the whole run rather than failing it.  The outer `timeout` is not
# belt and braces -- without it a regression here hangs the self-test itself.
#
# WEDGE_TIMEOUT_MS=0 reproduces the old infinite wait, which is how this case
# was shown to be sensitive rather than merely green: with the bound disabled
# it reports "still hanging" and fails.
wedge_out=$(cd "$out" && WINEDEBUG=-all timeout 60 "$WINE" dbgcall.exe \
                target.exe --bp "$bp" --out jsonl --plan decls.txt \
                --anchor-timeout ${WEDGE_TIMEOUT_MS:-1500} \
                --call "add(1, 2)" -- --wedge 2>&1)
wedge_rc=$?

if [ $wedge_rc -eq 124 ]; then
    echo "FAIL  bp       a wedged start-up is given up on: still hanging"
    fail=$((fail + 1))
elif printf '%s' "$wedge_out" | grep -q "the anchor was not reached"; then
    echo "PASS  bp       a wedged start-up is given up on"
    pass=$((pass + 1))
else
    echo "FAIL  bp       a wedged start-up is given up on: no message"
    printf '%s\n' "$wedge_out" | sed 's/^/      /'
    fail=$((fail + 1))
fi

# --- batches ---------------------------------------------------------------

run "batch    repeated --call"     "7|1007|2007" "$bp" \
    --call "add(0, 7)" --call "add(1, 7)" --call "add(2, 7)"

# Eight float calls in a row: if the x87 stack were not restored from the
# frozen context between calls, its tag word would fill up and the later
# results would come back as indefinite.
run "batch    8 float calls"       "3|6|9|12|15|18|21|24" "$bp" \
    --call "fmul(1,3)" --call "fmul(2,3)" --call "fmul(3,3)" \
    --call "fmul(4,3)" --call "fmul(5,3)" --call "fmul(6,3)" \
    --call "fmul(7,3)" --call "fmul(8,3)"

# --- plan files ------------------------------------------------------------

cat > "$out/plan.txt" <<EOF
x = add(1, 2)
method($gobj, 5)
dllmul(3, 5)
add(\$x, 0)
EOF

run "plan     calls reference declarations" "1002|7005|305|1002000" "$bp" \
    --plan "$out/plan.txt"

# A plan carries its own declarations, so the command line does not grow
# with the batch. This is also how a grid is covered now that the harness
# has no sweep syntax: generate an irregular domain a range could not state.
python3 - "$out/grid.txt" "$(rva "$exe" t_add)" <<'PY'
import sys
path, addr = sys.argv[1], sys.argv[2]
with open(path, "w") as f:
    f.write(f"i32 grid(i32,i32) = rva:{addr}\n")
    for x in range(5):
        for y in range(5):
            if x <= y:
                f.write(f"grid({x}, {y})\n")
PY

run "plan     generated grid" \
    "0|1|2|3|4|1001|1002|1003|1004|2002|2003|2004|3003|3004|4004" \
    "$bp" --plan "$out/grid.txt"

echo 'fill(&scratch, 10, 1) --dump scratch' > "$out/flags.txt"

run_grep "plan     per-call options after a call" \
    '01020304 05060708 090a' "$bp" --buf scratch:10 --plan "$out/flags.txt"

# --- failure modes --------------------------------------------------------

# sum(NULL, 10) dereferences a null pointer.
cat > "$out/fault.txt" <<EOF
sum(0, 10)
add(1, 2)
EOF

fault_out=$(harness "$bp" --plan "$out/fault.txt")

if printf '%s' "$fault_out" | grep -q '"status":"fault"' &&
   [ "$(printf '%s' "$fault_out" | grep -c '^{')" = "1" ]; then
    echo "PASS  fault    a faulting call stops the batch"
    pass=$((pass + 1))
else
    echo "FAIL  fault    expected exactly one row, with status fault"
    printf '%s\n' "$fault_out" | sed 's/^/      /'
    fail=$((fail + 1))
fi

cont_out=$(harness "$bp" --continue-on-fault --plan "$out/fault.txt")

if printf '%s' "$cont_out" | grep -q '"status":"fault"' &&
   printf '%s' "$cont_out" | grep -q '"tainted":true' &&
   printf '%s' "$cont_out" | grep -q '"result":"1002"'; then
    echo "PASS  fault    --continue-on-fault keeps going, marking rows tainted"
    pass=$((pass + 1))
else
    echo "FAIL  fault    --continue-on-fault did not recover and taint"
    printf '%s\n' "$cont_out" | sed 's/^/      /'
    fail=$((fail + 1))
fi

run_status "timeout  a call that never returns is given up on" timeout "$bp" \
    --call-timeout 1500 --call "spin()"

# --- injected code and patches ---------------------------------------------

# An executable page of our own, called like any other function. The address
# form `&name` is what makes a buffer callable.
#   mov eax,[esp+4]; mov ecx,[esp+8]; imul eax,ecx; ret
run "code     an injected cdecl function" 42 "$bp" \
    --code "mulfn:8b4424048b4c24080fafc1c3" \
    --sig "i32 mulcode(i32,i32) = &mulfn" --call "mulcode(6, 7)"

# `a1 <addr32>` is mov eax,[addr]: the hole holds a buffer's address, which
# is not known until the run allocates it.
run "code     {EXPR} is a buffer's address" 42 "$bp" \
    --blob "answer:2a000000" \
    --code "readfn:a1{&answer}c3" \
    --sig "i32 readcode() = &readfn" --call "readcode()"

# A hole is a whole expression, not just a name: a trampoline reaches the
# fields of its trace buffer this way.
run "code     {EXPR} does arithmetic" 42 "$bp" \
    --blob "answer:000000002a000000" \
    --code "readfn:a1{&answer+4}c3" \
    --sig "i32 readcode() = &readfn" --call "readcode()"

# `e9 <rel32>` is a near jmp: the hole is relative to its own end, so it
# depends on where the code was written as well as where it points.
run "code     {rel32} reaches into the image" 3004 "$bp" \
    --code "tramp:e9{rel32 $(va "$exe" t_add)}" \
    --sig "i32 viatramp(i32,i32) = &tramp" --call "viatramp(3, 4)"

# Patching live data, checked against what is actually there: g_obj.base is
# 7000 (0x1b58) until this says otherwise.
run "poke     data, against the bytes it replaces" 10005 "$bp" \
    --poke "$gobj:581b0000=>10270000" --call "method($gobj, 5)"

# The whole point: divert a function in the shipped image to a trampoline,
# at runtime, without a patched copy of the file.
#   mov eax,1000000; ret
run "poke     a function is diverted to injected code" 1000000 "$bp" \
    --code "alt:b840420f00c3" \
    --poke "$(va "$exe" t_add):$(code_bytes "$exe" t_add 5)=>e9{rel32 &alt}" \
    --call "add(1, 2)"

run_grep "poke     refuses bytes that are not there" "not the expected" "$bp" \
    --poke "$gobj:deadbeef=>00000000"

run_grep "poke     refuses a change of length" "must preserve length" "$bp" \
    --poke "$gobj:581b0000=>0000"

# A run with no --call in it is a complete job when it has a --poke.
run_grep "poke     with no call is a whole run" "poke at" "$bp" \
    --poke "$gobj:581b0000=>10270000"

# The same three setup options in a plan file, spelled exactly as on the
# command line. The hole in the last one contains a space, which is the case
# a plan file has to survive without the shell's quotes.
cat > "$out/patch.txt" <<EOF
--code alt:b840420f00c3
--poke $(va "$exe" t_add):$(code_bytes "$exe" t_add 5)=>e9{rel32 &alt}
--buf  spare:16

i32 patched(i32,i32) = rva:$(rva "$exe" t_add)
patched(1, 2)
EOF

run "plan     setup options in a plan file" 1000000 "$bp" \
    --plan "$out/patch.txt"

printf -- '--dump nosuch\n' > "$out/bad_call_opt.txt"
run_grep "plan     a call option on its own line is refused" \
    "belongs to a call" "$bp" --plan "$out/bad_call_opt.txt"

printf 'zero() --buf x:4\n' > "$out/bad_setup_opt.txt"
run_grep "plan     a setup option after a call is refused" \
    "line of its own" "$bp" --plan "$out/bad_setup_opt.txt"

# A patch outlives the debugger: the target's own last line prints
# t_method(&g_obj, 1), which is 7001 unmodified and 10001 after this.
poked_out=$(cd "$out" && WINEDEBUG=-all "$WINE" dbgcall.exe target.exe \
    --bp "$bp" --poke "$gobj:581b0000=>10270000" --resume 2>/dev/null)

if printf '%s' "$poked_out" | grep -q " 10001 "; then
    echo "PASS  poke     a patch survives --resume"
    pass=$((pass + 1))
else
    echo "FAIL  poke     expected the resumed target to print 10001"
    printf '%s\n' "$poked_out" | sed 's/^/      /'
    fail=$((fail + 1))
fi

# --- resuming --------------------------------------------------------------

# Without --resume the target is killed at the breakpoint, so its own later
# output never appears. With it, the thread goes back where it was caught and
# the program runs to completion.
killed_out=$(cd "$out" && WINEDEBUG=-all "$WINE" dbgcall.exe target.exe \
    --bp "$bp" --plan decls.txt --call "add(1, 2)" 2>/dev/null)

resumed_out=$(cd "$out" && WINEDEBUG=-all "$WINE" dbgcall.exe target.exe \
    --bp "$bp" --plan decls.txt --call "add(1, 2)" --resume 2>/dev/null)

if ! printf '%s' "$killed_out" | grep -q "1002 2.000000" &&
   printf '%s' "$resumed_out" | grep -q "1002 2.000000"; then
    echo "PASS  resume   --resume lets the target run on"
    pass=$((pass + 1))
else
    echo "FAIL  resume   expected the target to finish only with --resume"
    printf 'killed:\n%s\nresumed:\n%s\n' "$killed_out" "$resumed_out" |
        sed 's/^/      /'
    fail=$((fail + 1))
fi

# --- diagnostics -----------------------------------------------------------

run_grep "errors   argument count is checked" "parameter" "$bp" \
    --call "add(1)"

run_grep "errors   an unknown function name is reported" \
    "No function declared" "$bp" --call "notdeclared(1)"

run_grep "errors   a signature needs an address" \
    "self-contained" "$bp" --sig "i32 noaddr(i32)" --call "noaddr(1)"

run_grep "errors   a signature needs a name" \
    "needs a function name" "$bp" --sig "i32(i32)" --call "x(1)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]

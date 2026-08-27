#!/usr/bin/env python3
"""Generate ``dbgcall`` --poke/--code arguments for ``Incubation.exe``.

The patches here used to be written into a copy of the executable. They are
the same patches; what changed is when they are applied. ``dbgcall`` stops the
real ``Incubation.exe`` at its entry point, writes them into the live process,
checks each site against the *loaded* image first, and ``--resume`` leaves them
in place. So there is no patched build to name, hash and keep track of, and
the byte check happens where relocations have already been applied.

Two consequences for what is written below:

* Stubs are no longer squeezed into the executable's tail padding. They go on
  pages ``--code`` allocates, and the calls inside them are ``{rel32 ...}``
  holes ``dbgcall`` fills in once it knows where the page landed. Tail padding
  that reads as zero in the file can hold live pointers once the image is
  loaded, which cost this project a rejected trampoline site already.
* There are no INT3 patches. ``dbgcall --bp`` plants breakpoints properly.

``--selftest`` reassembles every stub at the tail-padding address the earlier
patched builds used and requires the bytes to be identical to what those
builds contained. That is what carries the evidence from the confirmed run
(``docs/91-wine-runtime-probes.md``) across to this generator.
"""

from __future__ import annotations

import argparse
import hashlib
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib.pe import PEFile  # noqa: E402


EXPECTED_SHA256 = "b07aa2478fbfaf252a585cff180d03b468d5141e0fdb5606bd09f0891024fcc9"

# The entry point of Incubation.exe: the earliest quiescent stop, before any
# of the code below has had a chance to run.
ENTRY_BP = "rva:0xae890"

# Routines the stubs call, named as in docs/91 and tools/trace_names.py.
A_MAIN_CONTROLLER = 0x0042E690
A_SET_PROGRAM_STATE = 0x0042E8F0
A_SET_SAVE_MODE = 0x00448770
A_LOAD_GAME = 0x00448E60
A_START_CAMPAIGN_INIT = 0x00450950
A_MAIN_MENU_BUILDER = 0x0044C170

# Controller states, as aMainController dispatches them.
STATE_LOAD_SAVE = 11
STATE_MISSION = 16

# Save modes taken by aSetSaveMode.
SAVE_MODE_CAMPAIGN = 0
SAVE_MODE_LOAD = 2


# ----------------------------------------------------------------------
# A byte string with holes in it, in the form dbgcall accepts
# ----------------------------------------------------------------------

@dataclass(frozen=True)
class Hole:
    """Four bytes dbgcall fills in when it writes the surrounding bytes."""

    expr: str
    rel32: bool = False

    def render(self) -> str:
        return "{rel32 %s}" % self.expr if self.rel32 else "{%s}" % self.expr


@dataclass
class Code:
    """Machine code as literal bytes and holes, assembled in either direction.

    ``render`` produces what goes on a dbgcall command line; ``at`` resolves
    the holes for a known load address, which is only used by ``--selftest``.
    """

    parts: list = field(default_factory=list)

    def __iadd__(self, other: bytes | Hole | "Code") -> "Code":
        if isinstance(other, Code):
            self.parts.extend(other.parts)
        else:
            self.parts.append(other)
        return self

    @property
    def size(self) -> int:
        return sum(4 if isinstance(p, Hole) else len(p) for p in self.parts)

    def render(self) -> str:
        return "".join(
            p.render() if isinstance(p, Hole) else p.hex() for p in self.parts)

    def at(self, base: int, env: dict[str, int]) -> bytes:
        out = bytearray()
        for p in self.parts:
            if isinstance(p, Hole):
                v = resolve(p.expr, env)
                if p.rel32:
                    v -= base + len(out) + 4
                out += (v & 0xFFFFFFFF).to_bytes(4, "little")
            else:
                out += p
        return bytes(out)


def resolve(expr: str, env: dict[str, int]) -> int:
    """Evaluate the subset of dbgcall's expressions these patches use."""
    total = 0
    for term in expr.split("+"):
        term = term.strip()
        if term.startswith("&"):
            name = term[1:]
            if name not in env:
                raise KeyError(f"no such buffer in this patch set: {name}")
            total += env[name]
        else:
            total += int(term, 0)
    return total


# --- the handful of instructions the stubs are made of ----------------------

def call(target: int | Hole) -> Code:
    return Code([b"\xe8", target if isinstance(target, Hole)
                 else Hole(f"{target:#x}", rel32=True)])


def jmp(target: int | Hole) -> Code:
    return Code([b"\xe9", target if isinstance(target, Hole)
                 else Hole(f"{target:#x}", rel32=True)])


def push_imm8(v: int) -> Code:
    return Code([bytes((0x6A, v))])


def add_esp(v: int) -> Code:
    return Code([bytes((0x83, 0xC4, v))])


def mov_eax_imm(v: int) -> Code:
    return Code([b"\xb8" + v.to_bytes(4, "little")])


def ret() -> Code:
    return Code([b"\xc3"])


def nops(n: int) -> Code:
    return Code([b"\x90" * n])


def raw(hexbytes: str) -> Code:
    return Code([bytes.fromhex(hexbytes)])


def rel32(expr: str) -> Hole:
    return Hole(expr, rel32=True)


def concat(*pieces: Code) -> Code:
    out = Code()
    for p in pieces:
        out += p
    return out


# ----------------------------------------------------------------------
# Patch sites and stubs
# ----------------------------------------------------------------------

@dataclass(frozen=True)
class Poke:
    """One patch: an address, the bytes that must be there, and what replaces
    them. The two are the same length; nothing here ever moves code around."""

    va: int
    expected: bytes
    replacement: Code
    note: str

    def arg(self) -> str:
        return f"{self.va:#010x}:{self.expected.hex()}=>{self.replacement.render()}"


@dataclass(frozen=True)
class Stub:
    name: str
    code: Code
    legacy_va: int      # where the patched builds put it, for --selftest
    note: str

    def arg(self) -> str:
        return f"{self.name}:{self.code.render()}"


@dataclass(frozen=True)
class Trace:
    name: str
    size: int


@dataclass
class PatchSet:
    pokes: list[Poke] = field(default_factory=list)
    stubs: list[Stub] = field(default_factory=list)
    traces: list[Trace] = field(default_factory=list)

    def __iadd__(self, other: "PatchSet") -> "PatchSet":
        self.pokes += other.pokes
        self.stubs += other.stubs
        self.traces += other.traces
        return self

    def args(self) -> list[str]:
        out: list[str] = []
        for t in self.traces:
            out += ["--buf", f"{t.name}:{t.size}"]
        for s in self.stubs:
            out += ["--code", s.arg()]
        for p in self.pokes:
            out += ["--poke", p.arg()]
        return out

    def plan(self) -> str:
        """The same options as a dbgcall plan file, which is where they
        belong once there are more than a couple: a plan holds setup options
        spelled exactly as on the command line, so nothing has two spellings
        and the shell never sees a line this long."""
        lines = ["# generated by tools/dbgcall_patches.py -- do not edit"]

        for t in self.traces:
            lines += ["", f"--buf  {t.name}:{t.size}"]

        for st in self.stubs:
            lines += ["", f"# {st.note}", f"--code {st.arg()}"]

        for pk in self.pokes:
            lines += ["", f"# {pk.note}", f"--poke {pk.arg()}"]

        return "\n".join(lines) + "\n"


# --- main-menu: enter the real menu builder instead of the intro ------------

MAIN_MENU_SITE = 0x0044BD6F
MAIN_MENU_EXPECTED = bytes.fromhex(
    "e8 ac 31 01 00 50 e8 96 31 01 00 50 e8 80 07 ff ff 83 c4 08")


def main_menu_poke() -> Poke:
    return Poke(
        MAIN_MENU_SITE, MAIN_MENU_EXPECTED,
        concat(
            call(A_MAIN_MENU_BUILDER),  # the real MainMenu builder
            raw("eb0d"),                # keep the original successful return
            nops(13)),
        "GameIntro enters the main menu builder")


# --- first-campaign: the older experiment, kept because docs/91 cites it ----

CAMPAIGN_TRIGGER_SITE = 0x0044A366
CAMPAIGN_TRIGGER_EXPECTED = bytes.fromhex(
    "75 26 68 d8 60 4c 00 68 53 04 00 00 68 18 2b 4c 00")

CAMPAIGN_INIT_CALL_SITE = 0x0044BBEE
CAMPAIGN_INIT_CALL_EXPECTED = bytes.fromhex("e8 0d 47 00 00")


def first_campaign() -> PatchSet:
    return PatchSet(pokes=[
        Poke(
            CAMPAIGN_TRIGGER_SITE, CAMPAIGN_TRIGGER_EXPECTED,
            # Force GameIntro's state-2 arm and write 2 to the state global.
            raw("7417c70508fe500002000000eb1a2b4c00"),
            "GameIntro takes its state-2 arm"),
        Poke(
            CAMPAIGN_INIT_CALL_SITE, CAMPAIGN_INIT_CALL_EXPECTED,
            # Start Campaign's own init, so state 0x10 arrives with campaign
            # context instead of without it.
            call(A_START_CAMPAIGN_INIT),
            "state-2 arm calls Start Campaign's init"),
    ])


# --- direct-save-6: straight into a saved mission ---------------------------
#
# These controllers do not sit inside one outer dispatch loop, so writing the
# states alone leaves the old screen up. Each stub reproduces the callback's
# recursive transition, which is what actually loads the save.

MENU_RUN_CALL_SITE = 0x0042E7FC
MENU_RUN_CALL_EXPECTED = bytes.fromhex("e8 7f cd 01 00")

LOAD_SAVE_RUN_SITE = 0x00447F50
LOAD_SAVE_RUN_EXPECTED = bytes.fromhex("e8 0b 00 00 00 b8 01 00 00 00 c3")

SAVE_SLOT = 6


def direct_save(slot: int = SAVE_SLOT) -> PatchSet:
    menu_to_load = Stub(
        "menu_to_load",
        concat(
            push_imm8(SAVE_MODE_CAMPAIGN),
            call(A_SET_SAVE_MODE),
            add_esp(4),
            push_imm8(STATE_LOAD_SAVE),
            call(A_SET_PROGRAM_STATE),
            add_esp(4),
            call(A_MAIN_CONTROLLER),
            mov_eax_imm(1),             # MenuSystem's success contract
            ret()),
        0x004B08C0,
        "MenuSystem run -> the LoadSave controller")

    load_save = Stub(
        "load_save",
        concat(
            push_imm8(slot),
            call(A_LOAD_GAME),
            add_esp(4),
            push_imm8(STATE_MISSION),
            call(A_SET_PROGRAM_STATE),
            add_esp(4),
            call(A_MAIN_CONTROLLER),
            mov_eax_imm(1),             # aRunLoadSave's success contract
            ret()),
        0x004B08A0,
        f"aRunLoadSave -> aLoadGame({slot}) and the mission controller")

    return PatchSet(
        stubs=[menu_to_load, load_save],
        pokes=[
            main_menu_poke(),
            Poke(
                MENU_RUN_CALL_SITE, MENU_RUN_CALL_EXPECTED,
                call(rel32("&menu_to_load")),
                "the state-4 menu run call goes to the stub"),
            Poke(
                LOAD_SAVE_RUN_SITE, LOAD_SAVE_RUN_EXPECTED,
                concat(jmp(rel32("&load_save")), nops(6)),
                "aRunLoadSave goes to the stub"),
        ])


# --- blob arm tracing -------------------------------------------------------
#
# One arm and one input per run, as docs/91 §6 requires. Adding an arm here is
# data, but its displaced bytes have to be read off the disassembly: the jump
# needs whole instructions, and whether the arm consumes the incoming flags is
# a property of that arm, not of this generator.

@dataclass(frozen=True)
class BlobArm:
    kind: int
    va: int
    displaced: bytes
    blob_dwords: int
    note: str


BLOB_ARMS = {
    15: BlobArm(
        kind=15,
        va=0x00420734,
        displaced=bytes.fromhex("8b 56 48 8b 6e 14"),
        blob_dwords=22,     # one 88-byte blob
        note="the moving tracer created by aBlob_CreateTracerBullet"),
}

TRACE_SIZE = 256
TRACE_BLOB_OFFSET = 0x20


def trace_blob_arm(arm: BlobArm) -> PatchSet:
    tramp = Stub(
        "tramp",
        concat(
            raw("8925"), Code([Hole("&trace")]),          # mov [trace+0], esp
            raw("8935"), Code([Hole("&trace+4")]),        # mov [trace+4], esi
            raw("c705"), Code([Hole("&trace+8")]),        # the arm marker,
            raw(f"{arm.va.to_bytes(4, 'little').hex()}"), # not a captured EIP
            raw("ff05"), Code([Hole("&trace+0xc")]),      # hit counter
            raw("9c50515657"),                            # flags + scratch
            raw("bf"), Code([Hole(f"&trace+{TRACE_BLOB_OFFSET:#x}")]),
            raw("b9"), Code([arm.blob_dwords.to_bytes(4, "little")]),
            raw("f3a5"),                                  # copy the blob
            raw("5f5e59589d"),                            # restore
            Code([arm.displaced]),                        # displaced insns
            jmp(arm.va + len(arm.displaced))),
        0x004B0900,
        f"kind {arm.kind}: {arm.note}")

    return PatchSet(
        traces=[Trace("trace", TRACE_SIZE)],
        stubs=[tramp],
        pokes=[Poke(
            arm.va, arm.displaced,
            concat(jmp(rel32("&tramp")), nops(len(arm.displaced) - 5)),
            f"kind-{arm.kind} arm -> the trampoline")])


MODES = {
    "none": PatchSet,
    "main-menu": lambda: PatchSet(pokes=[main_menu_poke()]),
    "first-campaign": first_campaign,
    "direct-save-6": direct_save,
}


# ----------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------

def check_against_image(patches: PatchSet, exe: PEFile) -> None:
    """Every site must still hold what it is declared to hold.

    dbgcall repeats this against the running process, which is the check that
    counts. Doing it here as well means a mistyped address is a message from
    this script rather than a failed run under Wine.
    """
    for p in patches.pokes:
        actual = exe.bytes_at(p.va, len(p.expected))
        if actual != p.expected:
            raise SystemExit(
                f"{p.va:#010x} holds {actual.hex(' ')}, "
                f"not the expected {p.expected.hex(' ')}")
        if p.replacement.size != len(p.expected):
            raise SystemExit(
                f"{p.va:#010x}: replacement is {p.replacement.size} bytes, "
                f"expected {len(p.expected)}")


# What the confirmed patched builds in docs/91 contained, at the tail-padding
# addresses they used. Reassembling the stubs there must reproduce these
# exactly; otherwise this generator is not emitting the code that ran.
LEGACY_TRACE_VA = 0x00524F00

LEGACY_STUBS = {
    "menu_to_load": "6a00e8a97ef9ff83c4046a0be81fe0f7ff83c404e8b7ddf7ffb801000000c3",
    "load_save": "6a06e8b985f9ff83c4046a10e83fe0f7ff83c404e8d7ddf7ffb801000000c3",
    "tramp": (
        "8925004f520089350"
        "44f5200c70508"
        "4f52003407420"
        "0ff050c4f52009c5051565"
        "7bf204f520"
        "0b916000000f3a55f5e59589d8b56488b6e14e9fdfdf6ff"),
}

LEGACY_POKES = {
    MENU_RUN_CALL_SITE: "e8bf200800",
    LOAD_SAVE_RUN_SITE: "e94b890600909090909090",
    0x00420734: "e9c7010900" "90",
    MAIN_MENU_SITE: "e8fc030000eb0d" + "90" * 13,
    CAMPAIGN_TRIGGER_SITE: "7417c70508fe500002000000eb1a2b4c00",
    CAMPAIGN_INIT_CALL_SITE: "e85d4d0000",
}


def selftest(exe: PEFile) -> int:
    """Reassemble everything at the legacy addresses and compare."""
    checks = 0
    failures = 0

    everything = PatchSet()
    everything += direct_save()
    everything += first_campaign()
    everything += trace_blob_arm(BLOB_ARMS[15])

    env = {s.name: s.legacy_va for s in everything.stubs}
    env["trace"] = LEGACY_TRACE_VA

    check_against_image(everything, exe)
    checks += len(everything.pokes)
    print(f"[+] {len(everything.pokes)} sites hold their declared bytes")

    for s in everything.stubs:
        got = s.code.at(s.legacy_va, env).hex()
        want = "".join(LEGACY_STUBS[s.name].split())
        checks += 1
        if got != want:
            failures += 1
            print(f"[!] stub {s.name} at {s.legacy_va:#010x}\n"
                  f"    got  {got}\n    want {want}")
        else:
            print(f"[+] stub {s.name} matches the confirmed build")

    for p in everything.pokes:
        got = p.replacement.at(p.va, env).hex()
        want = LEGACY_POKES[p.va]
        checks += 1
        if got != want:
            failures += 1
            print(f"[!] poke at {p.va:#010x}\n"
                  f"    got  {got}\n    want {want}")
        else:
            print(f"[+] poke at {p.va:#010x} matches the confirmed build")

    print(f"\n{checks - failures}/{checks} checks passed")
    return 1 if failures else 0


# ----------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("exe", type=Path,
                    help="the original Incubation.exe, or the game root")
    ap.add_argument("--mode", choices=sorted(MODES), default="direct-save-6")
    ap.add_argument("--slot", type=int, default=SAVE_SLOT,
                    help="save slot for --mode direct-save-6 (default 6)")
    ap.add_argument("--trace-blob-kind", type=int, metavar="KIND",
                    help=f"install a tracing trampoline on a blob arm; "
                         f"known: {sorted(BLOB_ARMS)}")
    ap.add_argument("--plan", action="store_true",
                    help="print a dbgcall plan file instead of arguments")
    ap.add_argument("--command", action="store_true",
                    help="print a whole wine command line instead of the "
                         "arguments on their own")
    ap.add_argument("--explain", action="store_true",
                    help="also print what each patch does, on stderr")
    ap.add_argument("--selftest", action="store_true",
                    help="reassemble every stub at the address the confirmed "
                         "patched builds used and compare the bytes")
    args = ap.parse_args()

    exe_path = args.exe / "Incubation.exe" if args.exe.is_dir() else args.exe

    if not exe_path.is_file():
        raise SystemExit(f"no such executable: {exe_path}")

    image = exe_path.read_bytes()
    digest = hashlib.sha256(image).hexdigest()
    if digest != EXPECTED_SHA256:
        raise SystemExit(f"unexpected source SHA-256: {digest}")

    exe = PEFile(exe_path)

    if args.selftest:
        return selftest(exe)

    patches = PatchSet()

    if args.mode == "direct-save-6":
        patches += direct_save(args.slot)
    else:
        patches += MODES[args.mode]()

    if args.trace_blob_kind is not None:
        arm = BLOB_ARMS.get(args.trace_blob_kind)
        if arm is None:
            raise SystemExit(
                f"no arm recorded for kind {args.trace_blob_kind}; "
                f"known: {sorted(BLOB_ARMS)}. Adding one needs its VA and "
                f"the whole instructions the jump displaces.")
        patches += trace_blob_arm(arm)

    if not patches.pokes:
        raise SystemExit("nothing to patch: give a --mode or --trace-blob-kind")

    check_against_image(patches, exe)

    if args.explain:
        for s in patches.stubs:
            print(f"code {s.name}: {s.note}", file=sys.stderr)
        for p in patches.pokes:
            print(f"poke {p.va:#010x}: {p.note}", file=sys.stderr)

    if args.plan:
        print(patches.plan(), end="")
        return 0

    out = patches.args()

    if args.command:
        print(" ".join(shlex.quote(a) for a in
                       ["wine", "dbgcall.exe", "Incubation.exe",
                        "--bp", ENTRY_BP, "--resume"] + out +
                       ["--", "-english"]))
    else:
        print("\n".join(out))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""The four Charisma name selectors of ``docs/40`` §7.2, read out of the code.

`Incubation.exe` picks a unit's model and its three gameplay animations with
four sibling routines that are pure `switch` cascades over the unit's own
bytes.  They are not tables a reader can walk: MSVC compiled each one into a
two- or three-level index-byte-plus-jump-table cascade whose arms are
``mov edi, <string literal>`` followed by an inline ``strcpy``.  The names only
exist as the union of the reachable arms.

**So the arms are enumerated by running them.**  :class:`Emulator` is a bounded
interpreter over exactly the instruction forms these four functions use, and an
opcode it does not know is a hard error -- a selector that changed shape stops
the tool rather than quietly yielding a shorter table.  The domain is small
enough to enumerate outright: unit type ``0..0x45``, weapon ``0..0x31``, player
``{0, 1, 2, 3, 0xFC}``, one past each of the routines' own bounds checks so the
guards themselves are exercised.

Two facts this recovered that ``docs/40`` §7.2 does not state, both of them
load-bearing for a remake's cache:

* **the model selector is three-level.** ``0x0042D070`` switches on the unit
  type (``+0x4C``), then the weapon (``+0x3F``), then the *player*
  (``+0x45``) -- the `P0_`/`P1_`/`P2_`/`P3_` prefixes are the player's skin.
  Player ``0xFC``, the neutral player of ``docs/10`` §5.7, returns nothing at
  all, and unit type ``0x17`` -- the hero -- is drawn as type 0 with player 1's
  skin.  A two-level reading of this function yields 26 names where the engine
  registers 104.
* **the idle selector is not a pure function.**  One arm (``0x0042DF77``)
  draws ``frand(0, 10)`` from ``0x004638E0`` and compares it against the ``5.0``
  at ``0x004B1380``, so it returns one of two names.  That is the explanation of
  ``docs/40`` §7.2's unexplained "(+ ``P4_S1_000``, ``PC_F1_011``)".  The
  emulator forks there and records both outcomes with their condition, so the
  extracted table holds a *distribution* where the engine has one.

The independent witness for all of it is ``fcn.00407e90``, which eagerly
registers every model and every idle animation at start-up: the union of what
the model selector can return must be exactly the set of names that function
passes to ``aCreateCHModelDescriptor``, and likewise for the idle selector and
``aCreateCHAnimationDescriptor``.  Two unrelated readings of the same binary
agreeing is the strongest oracle available without running the game.
"""

from __future__ import annotations

import re
import struct
from dataclasses import dataclass, field, replace
from typing import Any, Iterable, Iterator

from .pe import PEFile

# --- the four selectors ------------------------------------------------------

#: ``0x0042D070`` -- model name.  Three-level: type, weapon, player.
MODEL_SELECTOR = 0x0042D070
#: ``0x0042DA40`` -- the ``M`` movement animation, ``fcn.004055e0`` case 0.
MOVE_SELECTOR = 0x0042DA40
#: ``0x0042DDF0`` -- the ``S`` idle animation, from the 3D-view refresh.
IDLE_SELECTOR = 0x0042DDF0
#: ``0x0042E220`` -- the ``F`` combat animation, ``fcn.004055e0`` cases 1-3.
FIRE_SELECTOR = 0x0042E220

SELECTORS: dict[str, int] = {
    "model": MODEL_SELECTOR,
    "move": MOVE_SELECTOR,
    "idle": IDLE_SELECTOR,
    "fire": FIRE_SELECTOR,
}

#: ``docs/40`` §7.2 -- the one name reached only through ``kind == 4``, a fixed
#: literal at ``0x004C030C`` rather than anything a selector returns.
KIND4_LITERAL_VA = 0x004C030C

#: ``aRandom``'s float entry (``docs/22`` §8; ``tools/campaign_tables.py`` names
#: it too).  ``push hi; push lo; call`` returns a double in ST(0).
RANDOM_ROUTINE = 0x004638E0

#: ``fcn.00407e90`` in ``a3DObjects.cpp`` -- the eager registration pass whose
#: ``push <literal>`` operands are the independent witness for the two tables.
REGISTRATION_FUNCTION = 0x00407E90
REGISTRATION_LIMIT = 0x1600

#: The unit fields the selectors read, from ``docs/21`` §7.
UNIT_TYPE_OFFSET = 0x4C
UNIT_WEAPON_OFFSET = 0x3F
UNIT_PLAYER_OFFSET = 0x45

#: The routines' own bounds, plus one so the guard itself is exercised.
TYPE_LIMIT = 0x46
WEAPON_LIMIT = 0x31
#: ``docs/10`` §5.7 -- the four playable players, the two special ones, and
#: ``4``: one past the model selector's own third-level bound, so the guard is
#: exercised rather than assumed.  ``0xFF`` has to be here because the shipped
#: missions use it and it is **not** refused -- only ``0xFC`` is.
PLAYERS: tuple[int, ...] = (0, 1, 2, 3, 4, 0xFC, 0xFF)
#: The hero's unit type; ``0x0042D070`` rewrites it to (type 0, player 1).
HERO_TYPE = 0x17
#: The neutral player, for which the model selector returns nothing.
NEUTRAL_PLAYER = 0xFC

#: ``docs/40`` §7.1 gives the grammar as ``P<class>[_<family><variant>]_<index>``
#: with the family one of ``F``/``J``/``M``/``S``.  That is too narrow for the
#: *model* names: ``0x0042D070`` returns ``PC_ArmL_011`` and ``PC_ArmR_011``, and
#: both are shipped ``CHData/Objects/*.cho``.  The middle segment is therefore a
#: word, not a letter-plus-digit, and a scan built on the documented grammar
#: silently finds 102 of the 104 registered models.
NAME_GRAMMAR = re.compile(r"^P[0-9A-Z](?:_[A-Za-z][0-9A-Za-z]*)?_[0-9]{3}$")

#: Addresses the emulator maps to synthetic memory rather than to the image.
_UNIT_BASE = 0x10000000
_OUT_BASE = 0x11000000
_STACK_TOP = 0x12000000
_SYNTHETIC_MASK = 0xFF000000
_RETURN_ADDRESS = 0x13000000


class SelectorError(Exception):
    """Raised when a selector cannot be read the way this module reads it."""


# ---------------------------------------------------------------------------
# Outcomes
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Branch:
    """One randomised decision an outcome depended on.

    ``value < threshold`` is the branch the engine takes when the comparison
    at ``site`` succeeded; the tool records the condition rather than a
    probability so the remake can reproduce the draw instead of guessing it.
    """

    site: int
    low: int
    high: int
    threshold: float
    taken_below: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "site": f"{self.site:#010x}",
            "random": [self.low, self.high],
            "threshold": self.threshold,
            "taken": "below_or_equal" if self.taken_below else "above",
        }


@dataclass(frozen=True)
class Outcome:
    """What one selector call produced: a name, or nothing."""

    name: str | None
    branches: tuple[Branch, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"name": self.name}
        if self.branches:
            out["branches"] = [b.to_dict() for b in self.branches]
        return out


# ---------------------------------------------------------------------------
# The interpreter
# ---------------------------------------------------------------------------

_REGS = ("eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi")
#: 8-bit register encodings 0..7: al cl dl bl ah ch dh bh.
_REGS8 = (("eax", 0), ("ecx", 0), ("edx", 0), ("ebx", 0),
          ("eax", 8), ("ecx", 8), ("edx", 8), ("ebx", 8))

_MASK = 0xFFFFFFFF


@dataclass
class _State:
    """A register file, a stack and where execution is."""

    eip: int
    regs: dict[str, int] = field(default_factory=dict)
    stack: dict[int, int] = field(default_factory=dict)
    #: ``(zf, cf, sf, of)``; ``None`` where the last operation left it unknown.
    flags: tuple[bool, bool, bool, bool] = (False, False, False, False)
    #: A pending symbolic comparison from the FPU, forked on at the next jcc.
    pending: Branch | None = None
    #: The FPU's single modelled slot: the random draw's arguments.
    fpu: tuple[int, int] | None = None
    branches: tuple[Branch, ...] = ()

    def copy(self) -> "_State":
        return replace(self, regs=dict(self.regs), stack=dict(self.stack))


class Emulator:
    """Runs one selector over one unit and returns every reachable outcome.

    The interpreter is deliberately narrow.  It knows the instruction forms
    MSVC 4 emitted for these four `switch` cascades and nothing else, and it
    raises :class:`SelectorError` on anything it does not know rather than
    guessing -- the whole value of the tool is that it cannot come out green
    against a function it misread.
    """

    def __init__(self, pe: PEFile) -> None:
        self.pe = pe

    # -- memory ------------------------------------------------------------

    def _read8(self, state: _State, addr: int) -> int:
        addr &= _MASK
        if addr & _SYNTHETIC_MASK in (_UNIT_BASE, _OUT_BASE, _STACK_TOP & _SYNTHETIC_MASK):
            return state.stack.get(addr, 0)
        return self.pe.u8(addr)

    def _read32(self, state: _State, addr: int) -> int:
        addr &= _MASK
        if addr & _SYNTHETIC_MASK in (_UNIT_BASE, _OUT_BASE, _STACK_TOP & _SYNTHETIC_MASK):
            return int.from_bytes(
                bytes(state.stack.get(addr + i, 0) for i in range(4)), "little")
        return self.pe.u32(addr)

    def _write8(self, state: _State, addr: int, value: int) -> None:
        state.stack[addr & _MASK] = value & 0xFF

    def _write32(self, state: _State, addr: int, value: int) -> None:
        for i in range(4):
            state.stack[(addr + i) & _MASK] = (value >> (8 * i)) & 0xFF

    # -- register access ---------------------------------------------------

    @staticmethod
    def _get8(state: _State, code: int) -> int:
        name, shift = _REGS8[code]
        return (state.regs[name] >> shift) & 0xFF

    @staticmethod
    def _set8(state: _State, code: int, value: int) -> None:
        name, shift = _REGS8[code]
        mask = ~(0xFF << shift) & _MASK
        state.regs[name] = (state.regs[name] & mask) | ((value & 0xFF) << shift)

    # -- ModRM -------------------------------------------------------------

    def _modrm(self, state: _State, addr: int) -> tuple[int, int, int | None, int]:
        """Decode one ModRM byte.

        Returns ``(reg, length, effective_address, rm)``; ``effective_address``
        is ``None`` when the operand is a register.
        """
        modrm = self.pe.u8(addr)
        mod, reg, rm = modrm >> 6, (modrm >> 3) & 7, modrm & 7
        length = 1
        if mod == 3:
            return reg, length, None, rm
        base = 0
        index = 0
        if rm == 4:                                   # SIB
            sib = self.pe.u8(addr + 1)
            length += 1
            scale, idx, sib_base = sib >> 6, (sib >> 3) & 7, sib & 7
            if idx != 4:
                index = state.regs[_REGS[idx]] << scale
            if sib_base == 5 and mod == 0:
                base = struct.unpack_from("<i", self.pe.bytes_at(addr + length, 4))[0]
                length += 4
            else:
                base = state.regs[_REGS[sib_base]]
        elif rm == 5 and mod == 0:
            base = struct.unpack_from("<i", self.pe.bytes_at(addr + 1, 4))[0]
            length += 4
        else:
            base = state.regs[_REGS[rm]]
        if mod == 1:
            base += struct.unpack_from("<b", self.pe.bytes_at(addr + length, 1))[0]
            length += 1
        elif mod == 2:
            base += struct.unpack_from("<i", self.pe.bytes_at(addr + length, 4))[0]
            length += 4
        return reg, length, (base + index) & _MASK, rm

    # -- flags -------------------------------------------------------------

    @staticmethod
    def _sub_flags(a: int, b: int, bits: int) -> tuple[bool, bool, bool, bool]:
        mask = (1 << bits) - 1
        a &= mask
        b &= mask
        result = (a - b) & mask
        sign = 1 << (bits - 1)
        overflow = bool(((a ^ b) & (a ^ result)) & sign)
        return (result == 0, a < b, bool(result & sign), overflow)

    @staticmethod
    def _logic_flags(result: int, bits: int) -> tuple[bool, bool, bool, bool]:
        mask = (1 << bits) - 1
        result &= mask
        return (result == 0, False, bool(result & (1 << (bits - 1))), False)

    @staticmethod
    def _condition(code: int, flags: tuple[bool, bool, bool, bool]) -> bool:
        zf, cf, sf, of = flags
        if code == 0x4:                                   # jz
            return zf
        if code == 0x5:                                   # jnz
            return not zf
        if code == 0x2:                                   # jb
            return cf
        if code == 0x3:                                   # jae
            return not cf
        if code == 0x6:                                   # jbe
            return cf or zf
        if code == 0x7:                                   # ja
            return not cf and not zf
        if code == 0xC:                                   # jl
            return sf != of
        if code == 0xD:                                   # jge
            return sf == of
        if code == 0xE:                                   # jle
            return zf or sf != of
        if code == 0xF:                                   # jg
            return not zf and sf == of
        raise SelectorError(f"unsupported condition code {code:#x}")

    # -- the loop ----------------------------------------------------------

    def run(self, entry: int, unit: dict[int, int], *,
            step_limit: int = 20000) -> list[Outcome]:
        """Every outcome of calling *entry* with a unit holding *unit* bytes."""
        start = _State(eip=entry)
        start.regs = {name: 0 for name in _REGS}
        start.regs["esp"] = _STACK_TOP - 0x40
        start.regs["ecx"] = _UNIT_BASE
        # [esp] return address, [esp+4] arg0 = unit, [esp+8] arg1 = out buffer.
        self._write32(start, start.regs["esp"], _RETURN_ADDRESS)
        self._write32(start, start.regs["esp"] + 4, _UNIT_BASE)
        self._write32(start, start.regs["esp"] + 8, _OUT_BASE)
        for offset, value in unit.items():
            start.stack[_UNIT_BASE + offset] = value & 0xFF

        outcomes: list[Outcome] = []
        seen: set[tuple[str | None, tuple[Branch, ...]]] = set()
        work = [start]
        steps = 0
        while work:
            state = work.pop()
            while True:
                steps += 1
                if steps > step_limit:
                    raise SelectorError(
                        f"selector {entry:#010x} did not terminate in "
                        f"{step_limit} steps")
                done, forked = self._step(state)
                if forked is not None:
                    work.append(forked)
                if done is not None:
                    key = (done.name, done.branches)
                    if key not in seen:
                        seen.add(key)
                        outcomes.append(done)
                    break
        return outcomes

    def _terminal_name(self, state: _State) -> str | None:
        """The name ``edi`` points at where the inline ``strcpy`` begins."""
        text = self.pe.cstring(state.regs["edi"] & _MASK)
        if text is None:
            raise SelectorError(
                f"selector copied from {state.regs['edi']:#010x}, not a string")
        return text

    def _step(self, state: _State) -> tuple[Outcome | None, _State | None]:
        """Execute one instruction.  Returns ``(outcome, forked_state)``."""
        eip = state.eip
        op = self.pe.u8(eip)

        # The four routines all end the same two ways: an inline `strcpy` of
        # the literal `edi` points at (returning 1), or `xor eax, eax; ret`
        # (returning 0 with nothing written).  Recognising the `repne scasb`
        # that opens the copy means the string machinery never has to be
        # modelled -- `edi` already holds the answer.
        if op == 0xF2 and self.pe.u8(eip + 1) == 0xAE:
            return Outcome(self._terminal_name(state), state.branches), None
        if op == 0xC3:
            return Outcome(None, state.branches), None

        if 0x50 <= op <= 0x57:                            # push r32
            state.regs["esp"] = (state.regs["esp"] - 4) & _MASK
            self._write32(state, state.regs["esp"], state.regs[_REGS[op - 0x50]])
            state.eip = eip + 1
            return None, None
        if 0x58 <= op <= 0x5F:                            # pop r32
            state.regs[_REGS[op - 0x58]] = self._read32(state, state.regs["esp"])
            state.regs["esp"] = (state.regs["esp"] + 4) & _MASK
            state.eip = eip + 1
            return None, None
        if op == 0x6A:                                    # push imm8
            value = struct.unpack_from("<b", self.pe.bytes_at(eip + 1, 1))[0]
            state.regs["esp"] = (state.regs["esp"] - 4) & _MASK
            self._write32(state, state.regs["esp"], value & _MASK)
            state.eip = eip + 2
            return None, None
        if op == 0x68:                                    # push imm32
            state.regs["esp"] = (state.regs["esp"] - 4) & _MASK
            self._write32(state, state.regs["esp"], self.pe.u32(eip + 1))
            state.eip = eip + 5
            return None, None
        if 0xB8 <= op <= 0xBF:                            # mov r32, imm32
            state.regs[_REGS[op - 0xB8]] = self.pe.u32(eip + 1)
            state.eip = eip + 5
            return None, None
        if op == 0x90:                                    # nop
            state.eip = eip + 1
            return None, None

        if op in (0x88, 0x8A, 0x89, 0x8B, 0x33, 0x2B, 0x3B, 0x38, 0x84, 0x0B):
            return self._modrm_op(state, eip, op)
        if op in (0xC6, 0xC7, 0x80, 0x83, 0x81, 0xF6, 0xF7, 0xC1, 0xFF, 0xDC):
            return self._group_op(state, eip, op)
        if op == 0x25:                                    # and eax, imm32
            state.regs["eax"] &= self.pe.u32(eip + 1)
            state.flags = self._logic_flags(state.regs["eax"], 32)
            state.eip = eip + 5
            return None, None
        if op == 0x3C:                                    # cmp al, imm8
            state.flags = self._sub_flags(self._get8(state, 0),
                                          self.pe.u8(eip + 1), 8)
            state.eip = eip + 2
            return None, None
        if op == 0x3D:                                    # cmp eax, imm32
            state.flags = self._sub_flags(state.regs["eax"],
                                          self.pe.u32(eip + 1), 32)
            state.eip = eip + 5
            return None, None
        if op == 0xEB:                                    # jmp short
            state.eip = eip + 2 + struct.unpack_from(
                "<b", self.pe.bytes_at(eip + 1, 1))[0]
            return None, None
        if op == 0xE9:                                    # jmp near
            state.eip = eip + 5 + struct.unpack_from(
                "<i", self.pe.bytes_at(eip + 1, 4))[0]
            return None, None
        if 0x70 <= op <= 0x7F:                            # jcc short
            delta = struct.unpack_from("<b", self.pe.bytes_at(eip + 1, 1))[0]
            return self._branch(state, op & 0xF, eip + 2, eip + 2 + delta)
        if op == 0x0F and 0x80 <= self.pe.u8(eip + 1) <= 0x8F:
            delta = struct.unpack_from("<i", self.pe.bytes_at(eip + 2, 4))[0]
            return self._branch(state, self.pe.u8(eip + 1) & 0xF,
                                eip + 6, eip + 6 + delta)
        if op == 0xE8:                                    # call rel32
            target = eip + 5 + struct.unpack_from(
                "<i", self.pe.bytes_at(eip + 1, 4))[0]
            return self._call(state, eip + 5, target)
        if op == 0xDF and self.pe.u8(eip + 1) == 0xE0:    # fnstsw ax
            # The status word is only ever read to test C0/C3 straight after a
            # compare, so the pending symbolic comparison is simply carried.
            state.eip = eip + 2
            return None, None

        raise SelectorError(
            f"unsupported opcode {op:#04x} at {eip:#010x} in this selector")

    def _modrm_op(self, state: _State, eip: int,
                  op: int) -> tuple[Outcome | None, _State | None]:
        reg, length, addr, rm = self._modrm(state, eip + 1)
        end = eip + 1 + length

        def read8() -> int:
            return self._get8(state, rm) if addr is None else self._read8(state, addr)

        def read32() -> int:
            return state.regs[_REGS[rm]] if addr is None else self._read32(state, addr)

        if op == 0x88:                                    # mov r/m8, r8
            value = self._get8(state, reg)
            if addr is None:
                self._set8(state, rm, value)
            else:
                self._write8(state, addr, value)
        elif op == 0x8A:                                  # mov r8, r/m8
            self._set8(state, reg, read8())
        elif op == 0x89:                                  # mov r/m32, r32
            value = state.regs[_REGS[reg]]
            if addr is None:
                state.regs[_REGS[rm]] = value
            else:
                self._write32(state, addr, value)
        elif op == 0x8B:                                  # mov r32, r/m32
            state.regs[_REGS[reg]] = read32()
        elif op == 0x33:                                  # xor r32, r/m32
            state.regs[_REGS[reg]] ^= read32()
            state.flags = self._logic_flags(state.regs[_REGS[reg]], 32)
        elif op == 0x0B:                                  # or r32, r/m32
            state.regs[_REGS[reg]] |= read32()
            state.flags = self._logic_flags(state.regs[_REGS[reg]], 32)
        elif op == 0x2B:                                  # sub r32, r/m32
            other = read32()
            state.flags = self._sub_flags(state.regs[_REGS[reg]], other, 32)
            state.regs[_REGS[reg]] = (state.regs[_REGS[reg]] - other) & _MASK
        elif op == 0x3B:                                  # cmp r32, r/m32
            state.flags = self._sub_flags(state.regs[_REGS[reg]], read32(), 32)
        elif op == 0x38:                                  # cmp r/m8, r8
            state.flags = self._sub_flags(read8(), self._get8(state, reg), 8)
        elif op == 0x84:                                  # test r/m8, r8
            state.flags = self._logic_flags(read8() & self._get8(state, reg), 8)
        else:                                             # pragma: no cover
            raise SelectorError(f"unsupported ModRM opcode {op:#04x}")
        state.eip = end
        return None, None

    def _group_op(self, state: _State, eip: int,
                  op: int) -> tuple[Outcome | None, _State | None]:
        reg, length, addr, rm = self._modrm(state, eip + 1)
        end = eip + 1 + length

        if op == 0xC6:                                    # mov r/m8, imm8
            value = self.pe.u8(end)
            if addr is None:
                self._set8(state, rm, value)
            else:
                self._write8(state, addr, value)
            state.eip = end + 1
            return None, None
        if op == 0xC7:                                    # mov r/m32, imm32
            value = self.pe.u32(end)
            if addr is None:
                state.regs[_REGS[rm]] = value
            else:
                self._write32(state, addr, value)
            state.eip = end + 4
            return None, None
        if op == 0x80:                                    # group 1, r/m8
            imm = self.pe.u8(end)
            current = self._get8(state, rm) if addr is None \
                else self._read8(state, addr)
            if reg != 7:
                raise SelectorError(f"unsupported 8-bit group-1 /{reg}")
            state.flags = self._sub_flags(current, imm, 8)
            state.eip = end + 1
            return None, None
        if op in (0x83, 0x81):                            # group 1
            if op == 0x83:
                imm = struct.unpack_from("<b", self.pe.bytes_at(end, 1))[0] & _MASK
                end += 1
            else:
                imm = self.pe.u32(end)
                end += 4
            current = state.regs[_REGS[rm]] if addr is None \
                else self._read32(state, addr)
            if reg == 7:                                  # cmp
                state.flags = self._sub_flags(current, imm, 32)
                state.eip = end
                return None, None
            if reg == 0:                                  # add
                result = (current + imm) & _MASK
            elif reg == 1:                                # or
                result = current | imm
            elif reg == 4:                                # and
                result = current & imm
            elif reg == 5:                                # sub
                result = (current - imm) & _MASK
            else:
                raise SelectorError(f"unsupported group-1 /{reg}")
            state.flags = self._logic_flags(result, 32) if reg in (1, 4) \
                else self._sub_flags(current, imm, 32)
            if addr is None:
                state.regs[_REGS[rm]] = result
            else:
                self._write32(state, addr, result)
            state.eip = end
            return None, None
        if op == 0xF6 and reg == 0:                       # test r/m8, imm8
            imm = self.pe.u8(end)
            current = self._get8(state, rm) if addr is None \
                else self._read8(state, addr)
            state.flags = self._logic_flags(current & imm, 8)
            state.eip = end + 1
            return None, None
        if op == 0xF7 and reg == 2:                       # not r/m32
            if addr is None:
                state.regs[_REGS[rm]] = ~state.regs[_REGS[rm]] & _MASK
            else:
                self._write32(state, addr, ~self._read32(state, addr) & _MASK)
            state.eip = end
            return None, None
        if op == 0xC1:                                    # shift group
            count = self.pe.u8(end) & 0x1F
            current = state.regs[_REGS[rm]] if addr is None \
                else self._read32(state, addr)
            if reg == 5:
                result = current >> count
            elif reg == 4:
                result = (current << count) & _MASK
            else:
                raise SelectorError(f"unsupported shift /{reg}")
            if addr is None:
                state.regs[_REGS[rm]] = result
            else:
                self._write32(state, addr, result)
            state.eip = end + 1
            return None, None
        if op == 0xFF and reg == 4:                       # jmp r/m32
            if addr is None:
                raise SelectorError("indirect jump through a register")
            state.eip = self._read32(state, addr)
            return None, None
        if op == 0xDC and reg == 3:                       # fcomp qword [m]
            if addr is None or state.fpu is None:
                raise SelectorError(f"unmodelled FPU compare at {eip:#010x}")
            threshold = self.pe.f64(addr)
            low, high = state.fpu
            state.fpu = None
            # `fcomp` sets C0 when ST(0) < operand and C3 when equal; the
            # cascade tests `ah & 0x41` straight afterwards, so the pending
            # branch is "the draw came out at or below the threshold".
            state.pending = Branch(site=eip, low=low, high=high,
                                   threshold=threshold, taken_below=True)
            state.eip = eip + 1 + length
            return None, None
        raise SelectorError(f"unsupported group opcode {op:#04x}/{reg} at {eip:#010x}")

    def _call(self, state: _State, after: int,
              target: int) -> tuple[Outcome | None, _State | None]:
        if target != RANDOM_ROUTINE:
            raise SelectorError(
                f"selector called {target:#010x}, which is not aRandom")
        low = self._read32(state, state.regs["esp"])
        high = self._read32(state, state.regs["esp"] + 4)
        state.fpu = (low, high)
        state.eip = after
        return None, None

    def _branch(self, state: _State, code: int, fall: int,
                taken: int) -> tuple[Outcome | None, _State | None]:
        if state.pending is None:
            state.eip = taken if self._condition(code, state.flags) else fall
            return None, None
        # A conditional over the random draw: both arms are real, so one is
        # followed and the other is handed back to the work list.  `jne` is
        # taken when `ah & 0x41` is non-zero, i.e. when the draw came out at or
        # below the threshold.
        if code not in (0x4, 0x5):
            raise SelectorError(
                "the random arm is tested with something other than je/jne")
        below = state.pending
        above = replace(below, taken_below=False)
        other = state.copy()
        state.pending = None
        other.pending = None
        if code == 0x5:                                   # jne
            state.eip, other.eip = taken, fall
            state.branches += (below,)
            other.branches += (above,)
        else:                                             # je
            state.eip, other.eip = taken, fall
            state.branches += (above,)
            other.branches += (below,)
        return None, other


# ---------------------------------------------------------------------------
# Enumerating the domain
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class SelectorKey:
    """The unit bytes a selector reads."""

    type_id: int
    weapon: int
    player: int


def unit_bytes(key: SelectorKey) -> dict[int, int]:
    return {
        UNIT_TYPE_OFFSET: key.type_id,
        UNIT_WEAPON_OFFSET: key.weapon,
        UNIT_PLAYER_OFFSET: key.player,
    }


def iter_keys(*, types: Iterable[int] | None = None,
              weapons: Iterable[int] | None = None,
              players: Iterable[int] | None = None) -> Iterator[SelectorKey]:
    for type_id in (range(TYPE_LIMIT) if types is None else types):
        for weapon in (range(WEAPON_LIMIT) if weapons is None else weapons):
            for player in (PLAYERS if players is None else players):
                yield SelectorKey(type_id, weapon, player)


class SelectorTables:
    """The four selectors, enumerated over their whole domain."""

    def __init__(self, pe: PEFile) -> None:
        self.pe = pe
        self.emulator = Emulator(pe)
        self.tables: dict[str, dict[SelectorKey, tuple[Outcome, ...]]] = {}
        for name, entry in SELECTORS.items():
            self.tables[name] = {
                key: tuple(self.emulator.run(entry, unit_bytes(key)))
                for key in iter_keys()
            }

    def names(self, selector: str) -> set[str]:
        """Every name *selector* can return, anywhere in its domain."""
        return {outcome.name
                for outcomes in self.tables[selector].values()
                for outcome in outcomes
                if outcome.name is not None}

    def lookup(self, selector: str, key: SelectorKey) -> tuple[Outcome, ...]:
        return self.tables[selector].get(key, ())

    def to_dict(self) -> dict[str, Any]:
        """The portable form: one entry per key that returns anything."""
        out: dict[str, Any] = {}
        for selector, table in self.tables.items():
            entries: dict[str, Any] = {}
            for key, outcomes in sorted(
                    table.items(),
                    key=lambda kv: (kv[0].type_id, kv[0].weapon, kv[0].player)):
                if not any(o.name for o in outcomes):
                    continue
                entries[f"{key.type_id},{key.weapon},{key.player}"] = \
                    [o.to_dict() for o in outcomes]
            out[selector] = {
                "address": f"{SELECTORS[selector]:#010x}",
                "names": sorted(self.names(selector)),
                "entries": entries,
            }
        return out


# ---------------------------------------------------------------------------
# The independent witness: fcn.00407e90's eager registration
# ---------------------------------------------------------------------------

def registered_names(pe: PEFile, *, start: int = REGISTRATION_FUNCTION,
                     limit: int = REGISTRATION_LIMIT) -> set[str]:
    """Every ``P*`` literal ``fcn.00407e90`` pushes.

    ``docs/40`` §7.2: the models and the idle animations are the two things the
    engine loads eagerly, one ``aCreateCHModelDescriptor`` /
    ``aCreateCHAnimationDescriptor`` call each.  Scanning the ``push imm32``
    operands of that one function is a reading of the binary that shares no
    code with the emulator, which is what makes it worth having.
    """
    found: set[str] = set()
    body = pe.bytes_at(start, limit)
    for offset in range(len(body) - 4):
        if body[offset] != 0x68:                          # push imm32
            continue
        value = int.from_bytes(body[offset + 1:offset + 5], "little")
        text = pe.cstring(value) if pe.va_to_off(value) is not None else None
        if text and NAME_GRAMMAR.match(text):
            found.add(text)
    return found


#: The three gameplay families of ``docs/40`` §7.2, plus the unreferenced ``J``.
FAMILY_SEGMENT = re.compile(r"^[FJMS][0-9]$")


def split_registered(names: Iterable[str]) -> tuple[set[str], set[str]]:
    """Split registered names into models and animations.

    An animation carries a family segment (``P0_M0_000``); everything else --
    ``P0_000`` and the two ``PC_Arm?_011`` limbs -- is a model.  Splitting on
    the segment's *shape* rather than on the number of segments is what keeps
    the limbs on the model side, where the selector puts them.
    """
    models: set[str] = set()
    animations: set[str] = set()
    for name in names:
        parts = name.split("_")
        is_anim = len(parts) == 3 and FAMILY_SEGMENT.match(parts[1]) is not None
        (animations if is_anim else models).add(name)
    return models, animations

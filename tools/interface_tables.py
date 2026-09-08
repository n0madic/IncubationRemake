#!/usr/bin/env python3
"""Verify the interface contract in ``docs/29`` against the game and its data.

This is deliberately not a GUI renderer.  It verifies the information and
state transitions a replacement UI must preserve: the three menu programs and
their localized text resources, the six battle commands, the deployment
transfer gate and hand-over overlay, and the map-interface event dispatch.

Every ``--check`` run must inspect a non-empty binary and the complete layout
and text corpus; an empty or partial corpus is a failure, not zero work.

Usage::

    python3 tools/interface_tables.py --check gog_incubation
    python3 tools/interface_tables.py --json gog_incubation
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from inclib import lcl  # noqa: E402
from inclib.pe import PEError, PEFile  # noqa: E402

LOG = logging.getLogger("interface_tables")

GAME_EXE = "Incubation.exe"
MENU_FILES = ("Menu_a.lcl", "Menu_b.lcl", "Menu_c.lcl")
TEXT_FILES = ("Campaign.lcl", "Mission.lcl", "Txtmod_a.lcl", "Txtmod_b.lcl",
              "Txtmod_d.lcl", "Txtmod_e.lcl", "Txtmod_f.lcl", "Txtmod_g.lcl",
              "Txtmod_h.lcl")
EXPECTED_SCREENS = {
    "Menu_a.lcl": ("Provider", "Session", "Join", "Error", "Error_Player",
                    "Error_Session", "First_Player", "MainMenu",
                    "Wait_For_Players", "Leveloptions", "ReadMe", "ArenaMode",
                    "GameIntro", "DemoMessage", "Credits", "Campaign"),
    "Menu_b.lcl": ("MainMenu", "Briefing", "SelectUnits", "UpGrade",
                    "ItemList", "MainMap", "Dialog", "Sequence", "Recruit",
                    "Map", "SlideShow"),
    "Menu_c.lcl": ("MainMenu", "ExitObject", "Decoration"),
}
EXPECTED_GUI_COMMANDS = {
    "GUI_SetWindow": 29, "GUI_SetText": 115, "GUI_SetButton": 80,
    "GUI_SetTextButton": 11, "GUI_SetIcon": 32, "GUI_SetListbox": 20,
    "GUI_SetTextOnly": 10, "GUI_SetTextOnly2": 1, "GUI_SetTextbox": 1,
}
EXPECTED_TEXT_ENTRIES = 868

# aUI.cpp: (column, row) -> command.  The body at 0x00472120 contains six
# ``mov eax, imm32`` arms; no naming is inferred from the button artwork.
COMMAND_PAD_ARMS = {
    (0, 0): (0x00472175, 1), (0, 1): (0x0047216F, 3),
    (1, 0): (0x00472169, 2), (1, 1): (0x00472163, 7),
    (2, 0): (0x0047215D, 5), (2, 1): (0x00472157, 8),
}
USE_ARM_CALL = 0x004734EA
EXECUTE_USE = 0x0046DC60
USE_MP_LOAD = 0x00473553
USE_MP_STORE = 0x0047355C
USE_ACTED_STORE = 0x0047355F

# aUI.cpp's selected-unit refresh calls the shared aUnitInfos renderer.  These
# reads define the actual numeric panel; coordinates, owner and facing belong
# to selection/input state and are not fields rendered by this routine.
HUD_REFRESH_CALL = 0x004739E9
HUD_RENDERER = 0x004756D0
HUD_HP = 0x004756D8
HUD_AMMO = 0x00475715
HUD_FP = 0x00475718
HUD_ARMOUR_FP_RANK = 0x00475764
HUD_HP_CURRENT = 0x00475789
HUD_PROGRESS = 0x004757CA
HUD_WEAPON = 0x00475806
HUD_WEAPON_STATE = 0x0047584B
HUD_HEAT = 0x0047585C
HUD_AMMO_CURRENT = 0x0047587B
HUD_MP = 0x004758A9
HUD_SKILLS_CALL = 0x004758D6
HUD_SKILLS_RENDERER = 0x00475A60

# aPI.cpp: a clicked unit must carry a deployment state marker in 70..73.  The
# underlying CtrlMap action-point ids are 1..4; the selected pool index is
# transferred only through these calls.
# --- how a gadget is drawn (docs/29, the campaign windows of docs/27) -------
#: `aPrintGadget`, `aGadgets.cpp`. Type 3 is a composed button, type 4 a
#: single icon; the type byte lives at `gadget + 0x63` of the staging record
#: and at `0x00508c23` of the live one.
PRINT_GADGET = 0x0043A030
#: The measurer `aSetGadget` uses, whose arithmetic the painter repeats.
GADGET_WIDTH = 0x0043A9D0
#: **Which piece is which.** The unlit arm draws `base + 0`, then `Width - 2`
#: copies of `base + 2`, then `base + 1`; the lit arm draws `base + 3`,
#: `base + 5` and `base + 4`. These are the `add cl, K` immediates that pick
#: them, in drawing order, for the lit arm and then the unlit one.
#: The lit arm adds its immediate with `add cl, K`; the unlit one draws the
#: left cap with no add at all, adds 2 for the fill and reaches the right cap
#: with an `inc dl`.
GADGET_LIT_PIECES = ((0x0043A2EF, 3), (0x0043A347, 5), (0x0043A3A4, 4))
GADGET_UNLIT_LEFT = 0x0043A4D2
GADGET_UNLIT_FILL = 0x0043A535
GADGET_UNLIT_RIGHT = 0x0043A593
#: `mov dl, byte [esi + 0x508c28]` then `sub edx, 2` -- the fill count.
GADGET_FILL_COUNT = (0x0043A31F, 0x0043A328)
#: The icon arm: `base` normally, `inc dl` to `base + 1` when it is lit.
GADGET_ICON_LIT = 0x0043A259
#: The pointer's gadget. `0x0043a8b0` hit-tests the cursor, writes the answer
#: here and repaints the one that was lit and the one that now is -- so the
#: second trio is a **hover** face and no mouse button is involved.
GADGET_HOVER_GLOBAL = 0x00509A30
GADGET_HOVER_COMPARE = 0x0043A06D
GADGET_HOVER_HITTEST_CALL = 0x0043A8E6
GADGET_HOVER_HITTEST = 0x0043A650
GADGET_HOVER_STORE = 0x0043A8F7
#: The gadget builders and the type byte each writes.
GADGET_BUILDERS = {
    "GUI_SetButton": (0x0043CD10, 0x0043CDBA, 3),
    "GUI_SetTextButton": (0x0043CFF0, 0x0043D095, 3),
    "GUI_SetIcon": (0x0043D110, 0x0043D14E, 4),
}
#: **`Format`, not `cX`, is the alignment.** `GUI_SetText`'s eleventh argument
#: reaches `0x00439777`, which subtracts half the measured width at 1 and the
#: whole of it at 2; `cX` is the seventh and is a separate word the printer
#: takes as its own argument.
TEXT_ALIGN_CENTRE = 0x00439777
TEXT_ALIGN_RIGHT = 0x0043978E
#: The two GUI sounds `aInitGUI` loads, and the two arms of
#: `aPlayGUIClickSound` `0x0043E5E0` that play them.
GUI_SOUND_NAMES = ("click_1.wav", "click_2.wav")
GUI_SOUND_LOADS = (0x0043BF3A, 0x0043BF7F)
GUI_SOUND_BUFFERS = (0x0050B2A0, 0x0050B2A4)
GUI_SOUND_ARMS = (0x0043E61A, 0x0043E5EC)
#: `0x0043C500` plays the first one when the gadget under the pointer has
#: **changed**, panned by the cursor's x.
GUI_HOVER_SOUND_SITE = 0x0043C5C8
GUI_HOVER_PAN = 0x0043C5B9

# --- the bitmap font's two ink levels -- docs/60 5 ---------------------------
#: The glyph blitter is `0x00447900`, and it maps a source pixel **straight
#: onto the caller's colour array** rather than treating it as an intensity.
#: The 16-bit path -- the one every shipped display mode but the first runs
#: (docs/97 23.4) -- is a four-arm ladder: 0, 3 and 4 are skipped, **1** takes
#: `colour[0]` and **everything else** takes `colour[1]`.  Since the four
#: shipped faces use only 0, 1 and 2, that second arm is index 2, and index 2
#: is a glyph's antialiasing.
FONT_INK_SOLID_TEST = 0x00447ADD        # `cmp ah, 1`
FONT_INK_SOLID_LOAD = 0x00447AF9        # `mov ax, word [ebp + 0x20]`
FONT_INK_SHADE_ARM = 0x00447AEC         # the fall-through, `xor eax, eax`
FONT_INK_SHADE_LOAD = 0x00447AEE        # `mov ax, word [ebp + 0x24]`
#: The 8-bit path writes the ladder out in full: ``(the `cmp ah, imm8`, the
#: value, the `mov ah, byte [ebp + disp]` its branch reaches, disp)``.
FONT_INK_8BIT_ARMS = ((0x00447A2A, 1, 0x00447A4E, 0x20),
                      (0x00447A2F, 2, 0x00447A47, 0x24),
                      (0x00447A34, 3, 0x00447A40, 0x28))
#: `aPrintGUITextBox`'s own ramps -- four `mov dword [esp + slot], imm32` in a
#: row, one arm of the `{#n}` switch each.  `colour[1]` is 0.55 of `colour[0]`
#: in the body ramp and 0.39 in the alert one, which is what says the second
#: ink level is coverage and not an outline.
FONT_RAMP_SLOTS = (0x14, 0x20, 0x24, 0x28)
FONT_RAMPS = {"alert": (0x0043E458, (0xF800, 0x6000, 0x0800, 0x0000)),
              "body": (0x0043E47A, (0x94B2, 0x528A, 0x0841, 0x0000))}
#: Ramp 0 restores *the box's own* colours, which ``docs/24`` recorded as
#: unknowable from the file because ``0x0050A45C`` is filled at run time.  It
#: is knowable: ``0x0043D891`` copies the four out of the descriptor handed to
#: ``aCreateGUITextBox``, at ``+0x1C..+0x22``; the briefing's and the info
#: page's descriptor is the one global ``0x0050B2B4``; and all four of its
#: writers put the same immediates in it.  Keys are the four colour globals,
#: values ``(the four `mov word` sites' address fields, the immediate)``.
FONT_RAMP_DEFAULT_SITES = {
    0x0050B2D0: ((0x0043E78A, 0x0043E89D, 0x0043E9CD, 0x0043EB05), 0xFFFF),
    0x0050B2D2: ((0x0043E794, 0x0043E8A7, 0x0043E9D7, 0x0043EB0F), 0x632C),
    0x0050B2D4: ((0x0043E79D, 0x0043E8B0, 0x0043E9E0, 0x0043EB18), 0x0000),
    0x0050B2D6: ((0x0043E7A6, 0x0043E8B7, 0x0043E9E7, 0x0043EB21), 0x0000),
}
#: Two of the four writers store a **register** for the two zero entries --
#: ``mov word [addr], si`` -- so the immediate is not in the bytes there.  The
#: register is zero: each of those two functions clears it before the block,
#: and these are the ``xor esi, esi`` that do it.
FONT_RAMP_DEFAULT_REG = b"\x66\x89\x35"
FONT_RAMP_DEFAULT_IMM = b"\x66\xc7\x05"
FONT_RAMP_ZEROING = (0x0043E856, 0x0043E986)
#: ``0x0043D897`` / ``0x0043D8A2`` / ``0x0043D8AD`` -- ``mov dx, word
#: [eax + disp]``, the descriptor offsets the box's ramp is copied from.  The
#: first is a ``dword`` read a few bytes earlier and is not in this list.
FONT_RAMP_DESCRIPTOR_READS = ((0x0043D897, 0x1E), (0x0043D8A2, 0x20),
                              (0x0043D8AD, 0x22))
#: ``push 0x0050B2B4`` in ``aActivateBriefingInfo`` -- the descriptor itself.
FONT_RAMP_DESCRIPTOR_PUSH = 0x0043EB99
FONT_RAMP_DESCRIPTOR = 0x0050B2B4
#: ``cmp bl, 0x40`` / ``je`` in ``aPrintGUITextBox``: the printer draws no
#: ``@`` at all.  Its measuring half steps *past* a break unconditionally, so
#: a second ``@`` in a run is an ordinary character and starts no line --
#: which is the blank line under every shipped heading.  That half is pinned
#: by ``brief_parse.py`` against the whole corpus rather than here, because it
#: is a transcription (``inclib.brieftext.layout``) and not one instruction.
FONT_BREAK_SKIP = 0x0043E300

#: The Upgrade Menu's *i*: a two-state toggle, and the item picture is loaded
#: only while it reads 0 (`0x00458bfe`). At 1 `aPrintInfo` `0x0043ECF0` draws
#: the info box the Upgrade window opens at `0x004577D5`.
INFO_MODE_GLOBAL = 0x00510A54
INFO_MODE_ARM = 0x0045B4BC
INFO_MODE_LIMIT = 0x0045B4C2
INFO_MODE_PICTURE_GATE = 0x00458BFE
PRINT_INFO = 0x0043ECF0
INFO_ACTIVATE_CALL = 0x004577DB
INFO_ACTIVATE = 0x0043EAB0
#: `aActivateBriefingInfo(text, 190, 107, 387, 199, 1, 65)` -- the box.
INFO_BOX_PUSHES = (0x004577D0, 0x004577CE, 0x004577C9, 0x004577C4)
INFO_BOX = (190, 107, 387, 199)

#: The magnifying glass -- interface event 13 (``docs/43`` section 5.2).  The
#: mode is one dword, and the arm that toggles it is already pinned as
#: ``MAP_EVENT_TARGETS[12]``; what is pinned here is what the mode *does*.
MAGNIFIER_FLAG = 0x005106CC
#: ``0x00453925``/``0x00453943`` push the cursor the mode asks for, and both
#: arms hand it to ``0x0045F030`` (``MAP_EVENT_COMPLEX_CALLS["event13.cursor"]``
#: pins the first call; the second is here).
MAGNIFIER_OFF_STORE = 0x00453927
MAGNIFIER_ON_STORE = 0x00453945
MAGNIFIER_CURSOR_PUSHES = ((0x00453925, 0), (0x00453943, 10))
MAGNIFIER_CURSOR_CALL = 0x0045394F
MAGNIFIER_CURSOR = 0x0045F030
#: The click: ``aUI.cpp``'s selection routine asks ``0x00451230`` for the mode
#: and, while it is on, hands the picked cell to ``0x00432AB0`` and returns.
MAGNIFIER_READ = 0x00451230
MAGNIFIER_CLICK_GATE_CALL = 0x0047156D
MAGNIFIER_CLICK_CALL = 0x00471583
MAGNIFIER_CLICK = 0x00432AB0
#: ``0x00432AB0``'s three tests: the cell's occupant at ``+0x07`` (``0xFFFF``
#: is none), the owner at ``+0x45`` being the computer's 255, and the visible
#: state at ``+0x4F`` being 0.
MAGNIFIER_CELL_UNIT = 0x00432AC7
MAGNIFIER_OWNER_TEST = 0x00432AFA
MAGNIFIER_VISIBLE_TEST = 0x00432B00
MAGNIFIER_PAGE_CALL = 0x00432B08
MAGNIFIER_PAGE = 0x00432B20
#: ``0x00432B20``: the letter out of the 126-byte unit-type table at
#: ``0x0051C09D``, the family digit ``'0'``, and the box.
MAGNIFIER_LETTER_TABLE = 0x0051C09D
MAGNIFIER_LETTER_READ = 0x00432B35
MAGNIFIER_LETTER_STRIDE = 0x00432B30
MAGNIFIER_PAGE_PUSHES = (0x00432B51, 0x00432B4C, 0x00432B47, 0x00432B42,
                         0x00432B3D, 0x00432B27)
#: ``"Data"``, 230, 200, 180, 300, ``'0'``.
MAGNIFIER_PAGE_BOX = (0x004C2F14, 230, 200, 180, 300, 0x30)
MAGNIFIER_ACTIVATE_CALL = 0x00432B56
MAGNIFIER_ACTIVATE = 0x0043E850
#: ``0x0043E910`` -- the label ``0x0043E850`` retries with, two literal stars,
#: whatever family the caller asked for.
MAGNIFIER_FALLBACK = 0x0043E910
#: The heading.  ``0x0043E850``'s eighth argument is a **string**: it is copied
#: out of ``[esp + 0x28]`` into ``0x0050B4D4``, and the box painter's mode-2 arm
#: draws a name above the text unless it equals the blank buffer at
#: ``0x004FA524`` -- which is what ``0x00432B93`` passes when the caller asks
#: for no heading.  The unit path passes the **record**, whose ``+0x00`` is its
#: ``char[20]`` name (``docs/10`` §5.2), so a unit's page always has one.
MAGNIFIER_TITLE_ARGUMENT = 0x0043E92F
MAGNIFIER_TITLE_BUFFER = 0x0050B4D4
MAGNIFIER_TITLE_STORE = 0x0043E95F
MAGNIFIER_TITLE_TEST = 0x0043ED47
MAGNIFIER_NO_TITLE = 0x004FA524
MAGNIFIER_NO_TITLE_PUSH = 0x00432B93

PLACE_MARKER_LO = 0x00463437
PLACE_MARKER_HI = 0x00463440
PLACE_CANDIDATE = 0x00463485
PLACE_TO_POOL_CALL = 0x004634C7
PLACE_FROM_POOL_CALL = 0x004635AB
TRANSFER_TO_POOL = 0x00478F20
TRANSFER_FROM_POOL = 0x00478D10

# The call at 0x00419D69 is the interface-side half of a hand-over.  It
# chooses the first-hand-over deployment build while the turn counter is zero;
# subsequent calls clear the transient cell overlay.
HANDOVER_CALL_SITE = 0x00419D69
HANDOVER_ROUTINE = 0x004312D0
HANDOVER_TURN_CALL = 0x004312D0
HANDOVER_BUILD_CALL = 0x004312DE
HANDOVER_RESET_CALL = 0x004312EC
TURN_COUNTER_GETTER = 0x0043B280
TURN_COUNTER = 0x00509E1D

# markDeploymentCells (0x004310F0), including the special multiplayer gate.
MARK_ROUTINE = 0x004310F0
MARK_GATE_CALL = 0x0043110F
MARK_GATE = 0x0043B1F0
CTRL_MAP_BASE = 0x0042F650
CTRL_MAP_COUNT = 0x0042F660
MARK_BASE_CALL = 0x004310F2
MARK_COUNT_CALL = 0x004310FB
MARK_EMPTY_SENTINEL = 0x0043110A       # mov ebp, 0xffff
MARK_AP_LOAD = 0x00431118            # mov al, [esi+0x0b]
MARK_AP_LO = 0x0043111B             # cmp al, 1
MARK_AP_HI = 0x0043111F             # cmp al, 4
MARK_EMPTY_TEST = 0x00431123        # cmp word [esi+7], ebp
MARK_SPECIAL_AP_LOAD = 0x00431135   # mov dl, [esi+0x0b]
MARK_ADD_NORMAL = 0x0043112B        # add al, 0x46
MARK_ADD_SPECIAL = 0x00431145      # add al, 0x46
MARK_STATE_STORE = 0x0043114B       # mov byte [esi], 1 (fallback)
MARK_CELL_STRIDE = 0x0043114E       # add esi, 0x17

# resetCellOverlay (0x0042EE90) clears damage and restores cell state 1.
RESET_ROUTINE = 0x0042EE90
RESET_BASE_CALL = 0x0042EE93
RESET_COUNT_CALL = 0x0042EE9E
RESET_DAMAGE_STORE = 0x0042EEA7
RESET_STATE_STORE = 0x0042EEAA
RESET_CELL_STRIDE = 0x0042EEAD

# aMI.cpp's only 16-arm interface event dispatcher.  This is an input event
# protocol, not a promise to reproduce the original mouse driver or layout.
MAP_EVENT_DISPATCH = 0x00453900
MAP_EVENT_TABLE = 0x00453CB0
MAP_EVENT_TARGETS = (
    0x00453C56, 0x00453C82, 0x00453C65, 0x00453C91,
    0x004539D5, 0x00453A16, 0x00453AD9, 0x00453AE6,
    0x00453B3F, 0x00453AF3, 0x00453961, 0x00453B00,
    0x0045391C, 0x00453B30, 0x00453A98, 0x00453A57,
)
MAP_EVENT_RETURNS = {
    5: (0x00453A09, 4), 6: (0x00453A4A, 3),
    7: (0x00453AD9, 6), 8: (0x00453AE6, 5),
    10: (0x00453AF3, 2), 15: (0x00453ACC, 7),
    16: (0x00453A8B, 8),
}
MAP_EVENT_DIRECT_CALLS = {
    1: (0x00453C56, 0x00453410),
    2: (0x00453C82, 0x00451150),
    4: (0x00453C91, 0x004510A0),
    14: (0x00453B30, 0x00453CF0),
}
MAP_EVENT_COMPLEX_CALLS = {
    "event3.place": (0x00453C6E, 0x00452420),
    "event3.refresh": (0x00453C73, 0x00450F60),
    "event9.mode": (0x00453B3F, 0x0043B740),
    "event9.alternate": (0x00453C44, 0x004536E0),
    "event11.briefing": (0x0045398A, 0x0043B150),
    "event11.activate": (0x00453990, 0x0043EAB0),
    "event12.ui": (0x00453B19, 0x00471E00),
    "event12.advance": (0x00453B21, 0x004533D0),
    "event13.cursor": (0x00453931, 0x0045F030),
}
MAP_EVENT_DEFAULT = 0x00453CA0
MAP_EVENT_FROM_INPUT = (0x00450D62, 0x00450E75)
MAP_EVENT_CONSUMER_CALL = 0x0041BA9F
MAP_COMMAND_CONSUMER = 0x0041DA20


def walk(nodes):
    for node in nodes:
        if isinstance(node, lcl.Statement):
            yield node
        elif isinstance(node, lcl.Conditional):
            yield from (term.call for term in node.terms)
            yield from walk(node.body)
            yield from walk(node.else_body)


def call_target(pe: PEFile, call_va: int) -> int | None:
    if pe.u8(call_va) != 0xE8:
        return None
    return call_va + 5 + pe.i32(call_va + 1)


class Checker:
    def __init__(self) -> None:
        self.passed = self.failed = 0
        self.failures: list[str] = []

    def equal(self, name, got, want, detail="") -> None:
        ok = got == want
        if ok:
            self.passed += 1
            LOG.info("  ok    %-28s %s", name, detail or got)
        else:
            self.failed += 1
            self.failures.append(name)
            LOG.error("  FAIL  %-28s got %r want %r", name, got, want)

    def check(self, name, ok, detail="") -> None:
        self.equal(name, bool(ok), True, detail)


def read_program(path: Path):
    return lcl.parse_bytes(path.read_bytes(), str(path))


def corpus(root: Path):
    gui = root / "DATA" / "GUI"
    text = root / "DATA" / "TXT" / "English" / "GUI"
    programs = {name: read_program(gui / name) for name in MENU_FILES
                if (gui / name).is_file()}
    texts = {name: read_program(text / name) for name in TEXT_FILES
             if (text / name).is_file()}
    return programs, texts


def run_checks(root_name: str) -> Checker:
    root = Path(root_name)
    ck = Checker()
    try:
        pe = PEFile(root / GAME_EXE)
    except (OSError, PEError) as exc:
        ck.check("binary.open", False, str(exc))
        return ck
    programs, texts = corpus(root)

    ck.equal("corpus.menu_files", tuple(sorted(programs)), MENU_FILES,
             "3/3 Menu_*.lcl")
    ck.equal("corpus.text_files", tuple(sorted(texts)), TEXT_FILES,
             "9/9 localized GUI tables")
    ck.equal("corpus.text_entries",
             sum(isinstance(n, lcl.TextEntry)
                 for p in texts.values() for r in p.routines for n in r.body),
             EXPECTED_TEXT_ENTRIES, "868 localized entries")

    gui_commands = Counter()
    for name, program in programs.items():
        screens = tuple(r.name for r in program.routines if r.name)
        ck.equal(f"layout.{name}.screens", screens, EXPECTED_SCREENS[name])
        for routine in program.routines:
            for statement in walk(routine.body):
                if statement.name.startswith("GUI_"):
                    gui_commands[statement.name] += 1
    ck.equal("layout.gui_commands", dict(sorted(gui_commands.items())),
             dict(sorted(EXPECTED_GUI_COMMANDS.items())))

    ck.equal("battle.command_pad", {
        pos: (pe.u8(va), pe.u32(va + 1))
        for pos, (va, _command) in COMMAND_PAD_ARMS.items()
    }, {pos: (0xB8, command) for pos, (_va, command) in COMMAND_PAD_ARMS.items()},
             "six command ids")
    ck.check("battle.use_executor", call_target(pe, USE_ARM_CALL) == EXECUTE_USE,
             "command 8 calls aExecuteUse")
    ck.equal("battle.use_mp_load", pe.u8(USE_MP_LOAD + 2), 0x15,
             "unit movement points at +0x15")
    ck.equal("battle.use_mp_store", pe.u8(USE_MP_STORE + 2), 0x15,
             "one point is written back")
    ck.check("battle.use_acted",
             pe.u8(USE_ACTED_STORE + 2) == 0x39 and pe.u8(USE_ACTED_STORE + 3) == 3,
             "unit acted flag (+0x39) becomes 3")
    ck.equal("hud.refresh", call_target(pe, HUD_REFRESH_CALL), HUD_RENDERER,
             "aUI selected-unit refresh calls the shared panel renderer")
    ck.check("hud.vitals",
             pe.bytes_at(HUD_HP, 3) == b"\x8A\x46\x16"
             and pe.bytes_at(HUD_AMMO, 3) == b"\x8A\x56\x3D"
             and pe.bytes_at(HUD_FP, 3) == b"\x8A\x46\x19"
             and pe.bytes_at(HUD_HP_CURRENT, 3) == b"\x8A\x4E\x16",
             "HP, FP and ammunition are panel inputs")
    ck.check("hud.defence_rank",
             pe.bytes_at(HUD_ARMOUR_FP_RANK, 9)
             == b"\x8A\x4E\x19\x8A\x56\x37\x50\x33\xC0"
             and pe.bytes_at(HUD_ARMOUR_FP_RANK + 9, 3) == b"\x8A\x46\x36",
             "FP, rear/front armour and computed rank")
    ck.check("hud.progress",
             pe.bytes_at(HUD_PROGRESS, 3) == b"\x8A\x56\x38"
             and pe.bytes_at(HUD_PROGRESS + 5, 3) == b"\x8A\x4E\x17"
             and pe.bytes_at(HUD_PROGRESS + 12, 3) == b"\x8A\x46\x18",
             "decorations, experience and training points")
    ck.check("hud.weapon",
             pe.bytes_at(HUD_WEAPON, 3) == b"\x8A\x46\x3F"
             and pe.bytes_at(HUD_WEAPON_STATE, 3) == b"\x8A\x4E\x40"
             and pe.bytes_at(HUD_HEAT, 3) == b"\x8A\x56\x3E"
             and pe.bytes_at(HUD_AMMO_CURRENT, 3) == b"\x8A\x46\x3D",
             "weapon id, malfunction, heat and current ammunition")
    ck.check("hud.movement_skills",
             pe.bytes_at(HUD_MP, 3) == b"\x8A\x46\x15"
             and call_target(pe, HUD_SKILLS_CALL) == HUD_SKILLS_RENDERER,
             "movement points and the equipment/skill subpanel")

    ck.equal("deploy.marker_lower", pe.u8(PLACE_MARKER_LO + 2), 70)
    ck.equal("deploy.marker_upper", pe.u8(PLACE_MARKER_HI + 2), 73)
    ck.check("deploy.pool_candidate", pe.bytes_at(PLACE_CANDIDATE, 4) == b"\x80\x78\x4d\x01",
             "map unit needs unit[+0x4d] >= 1 before it returns to pool")
    ck.equal("deploy.from_map", call_target(pe, PLACE_TO_POOL_CALL), TRANSFER_TO_POOL)
    ck.equal("deploy.to_map", call_target(pe, PLACE_FROM_POOL_CALL), TRANSFER_FROM_POOL)

    ck.check("deploy.handover_callsite",
             call_target(pe, HANDOVER_CALL_SITE) == HANDOVER_ROUTINE,
             "0x00419D50 passes the incoming player to 0x004312D0")
    ck.check("deploy.handover_turn",
             call_target(pe, HANDOVER_TURN_CALL) == TURN_COUNTER_GETTER
             and pe.u8(TURN_COUNTER_GETTER) == 0xA0
             and pe.u32(TURN_COUNTER_GETTER + 1) == TURN_COUNTER
             and pe.u8(TURN_COUNTER_GETTER + 5) == 0xC3,
             "dispatch reads the turn counter at 0x00509E1D")
    ck.check("deploy.handover_branch",
             pe.bytes_at(HANDOVER_ROUTINE + 5, 4) == b"\x84\xC0\x75\x13",
             "turn == 0 builds; non-zero turn resets")
    ck.equal("deploy.handover_build", call_target(pe, HANDOVER_BUILD_CALL),
             MARK_ROUTINE, "zero-turn deployment marker build")
    ck.equal("deploy.handover_reset", call_target(pe, HANDOVER_RESET_CALL),
             RESET_ROUTINE, "later-turn cell overlay reset")
    ck.check("deploy.marker_scan",
             call_target(pe, MARK_BASE_CALL) == CTRL_MAP_BASE
             and call_target(pe, MARK_COUNT_CALL) == CTRL_MAP_COUNT
             and call_target(pe, MARK_GATE_CALL) == MARK_GATE,
             "marker pass scans CtrlMap and applies the multiplayer gate")
    ck.check("deploy.marker_rules",
             pe.bytes_at(MARK_AP_LOAD, 3) == b"\x8A\x46\x0B"
             and pe.bytes_at(MARK_AP_LO, 2) == b"\x3C\x01"
             and pe.bytes_at(MARK_AP_HI, 2) == b"\x3C\x04"
             and pe.bytes_at(MARK_SPECIAL_AP_LOAD, 3) == b"\x8A\x56\x0B"
             and pe.bytes_at(MARK_ADD_NORMAL, 2) == b"\x04\x46"
             and pe.bytes_at(MARK_ADD_SPECIAL, 2) == b"\x04\x46"
             and pe.bytes_at(MARK_STATE_STORE, 3) == b"\xC6\x06\x01"
             and pe.bytes_at(MARK_CELL_STRIDE, 3) == b"\x83\xC6\x17",
             "action-point ids 1..4 become player markers 70..73")
    ck.check("deploy.marker_empty",
             pe.bytes_at(MARK_EMPTY_SENTINEL, 5) == b"\xBD\xFF\xFF\x00\x00"
             and pe.bytes_at(MARK_EMPTY_TEST, 4) == b"\x66\x39\x6e\x07",
             "special branch requires an empty unit link")
    ck.check("deploy.overlay_reset",
             call_target(pe, RESET_BASE_CALL) == CTRL_MAP_BASE
             and call_target(pe, RESET_COUNT_CALL) == CTRL_MAP_COUNT
             and pe.bytes_at(RESET_DAMAGE_STORE, 3) == b"\x88\x5E\x0C"
             and pe.bytes_at(RESET_STATE_STORE, 3) == b"\xc6\x06\x01"
             and pe.bytes_at(RESET_CELL_STRIDE, 3) == b"\x83\xC6\x17",
             "reset clears cell damage and restores state 1")

    # --- the gadget painter -------------------------------------------------
    for order, (va, piece) in enumerate(GADGET_LIT_PIECES):
        # `add cl, imm8` for the caps and the fill, in drawing order.
        ck.check(f"gadget.lit_piece{order}",
                 pe.bytes_at(va, 3) == b"\x80\xc1" + bytes([piece]),
                 f"{va:#x}: piece base + {piece}")
    ck.check("gadget.unlit_left",
             pe.bytes_at(GADGET_UNLIT_LEFT, 2) == b"\x8a\x96"
             and pe.u32(GADGET_UNLIT_LEFT + 2) == 0x00508C24
             and pe.bytes_at(GADGET_UNLIT_LEFT + 6, 2) != b"\x80\xc2",
             f"{GADGET_UNLIT_LEFT:#x}: the base itself, with nothing added")
    ck.check("gadget.unlit_fill",
             pe.bytes_at(GADGET_UNLIT_FILL, 3) == b"\x80\xc2\x02",
             f"{GADGET_UNLIT_FILL:#x}: add dl, 2")
    ck.check("gadget.unlit_right",
             pe.bytes_at(GADGET_UNLIT_RIGHT, 2) == b"\xfe\xc2",
             f"{GADGET_UNLIT_RIGHT:#x}: inc dl -- base + 1")
    ck.check("gadget.fill_count",
             pe.bytes_at(GADGET_FILL_COUNT[0], 2) == b"\x8a\x96"
             and pe.u32(GADGET_FILL_COUNT[0] + 2) == 0x00508C28
             and pe.bytes_at(GADGET_FILL_COUNT[1], 3) == b"\x83\xea\x02",
             "the fill is drawn Width - 2 times, edge to edge")
    ck.check("gadget.icon_lit",
             pe.bytes_at(GADGET_ICON_LIT, 2) == b"\xfe\xc2",
             f"{GADGET_ICON_LIT:#x}: inc dl -- an icon lights with base + 1")
    ck.check("gadget.hover_is_the_pointer",
             pe.bytes_at(GADGET_HOVER_COMPARE, 6)
             == b"\x8b\x15" + GADGET_HOVER_GLOBAL.to_bytes(4, "little")
             and call_target(pe, GADGET_HOVER_HITTEST_CALL)
             == GADGET_HOVER_HITTEST
             and pe.bytes_at(GADGET_HOVER_STORE, 5)
             == b"\xa3" + GADGET_HOVER_GLOBAL.to_bytes(4, "little"),
             "the lit trio follows the cursor, not a button press")
    for command, (entry, site, kind) in GADGET_BUILDERS.items():
        ck.check(f"gadget.type_{command}",
                 entry < site and pe.bytes_at(site, 3) == b"\xc6\x44\x24"
                 and pe.u8(site + 4) == kind,
                 f"{command} builds a type-{kind} gadget")
    ck.check("gadget.text_align",
             pe.bytes_at(TEXT_ALIGN_CENTRE, 3) == b"\x8b\x44\x24"
             and pe.bytes_at(TEXT_ALIGN_CENTRE + 4, 3) == b"\x83\xf8\x01"
             and pe.bytes_at(TEXT_ALIGN_CENTRE + 0xF, 2) == b"\xd1\xe9"
             and pe.bytes_at(TEXT_ALIGN_RIGHT, 3) == b"\x83\xf8\x02",
             "GUI_SetText's Format column: 1 centres, 2 right-aligns")
    for index, name in enumerate(GUI_SOUND_NAMES):
        site = GUI_SOUND_LOADS[index]
        ck.check(f"gui.sound_{index}_name",
                 pe.bytes_at(site, 1) == b"\x68"
                 and pe.cstring(pe.u32(site + 1), 32) == name,
                 f"{site:#x}: push \"{name}\"")
        ck.check(f"gui.sound_{index}_arm",
                 pe.bytes_at(GUI_SOUND_ARMS[index], 5)
                 == b"\xa1" + GUI_SOUND_BUFFERS[index].to_bytes(4, "little")
                 or pe.bytes_at(GUI_SOUND_ARMS[index], 6)
                 == b"\x8b\x0d" + GUI_SOUND_BUFFERS[index].to_bytes(4, "little"),
                 f"aPlayGUIClickSound({index}) plays {name}")
    ck.check("gui.hover_sound",
             pe.bytes_at(GUI_HOVER_SOUND_SITE, 6)
             == b"\x8b\x0d" + GUI_SOUND_BUFFERS[0].to_bytes(4, "little")
             and pe.bytes_at(GUI_HOVER_PAN, 5) == b"\xbe\x40\x01\x00\x00",
             "the pointer crossing a gadget plays click_1.wav, panned by x")
    ck.check("font.ink_solid_is_colour_0",
             pe.bytes_at(FONT_INK_SOLID_TEST, 3) == b"\x80\xfc\x01"
             and pe.bytes_at(FONT_INK_SOLID_LOAD, 4) == b"\x66\x8b\x45\x20",
             "a glyph pixel of 1 takes the caller's first colour")
    ck.check("font.ink_shade_is_colour_1",
             pe.bytes_at(FONT_INK_SHADE_ARM, 2) == b"\x33\xc0"
             and pe.bytes_at(FONT_INK_SHADE_LOAD, 4) == b"\x66\x8b\x45\x24",
             "every other pixel -- index 2 in the shipped faces -- takes the "
             "second, so the second level is antialiasing and not an outline")
    for test, value, load, disp in FONT_INK_8BIT_ARMS:
        ck.check(f"font.ink_8bit_{value}",
                 pe.bytes_at(test, 3) == bytes((0x80, 0xFC, value))
                 and pe.bytes_at(load, 3) == bytes((0x8A, 0x65, disp)),
                 f"the 8-bit path sends {value} to colour[{(disp - 0x20) // 4}]")
    def u16(va: int) -> int:
        return int.from_bytes(pe.bytes_at(va, 2), "little")

    zeroed = all(pe.bytes_at(va, 2) == b"\x33\xf6"
                 for va in FONT_RAMP_ZEROING)
    for global_va, (sites, want) in sorted(FONT_RAMP_DEFAULT_SITES.items()):
        written = []
        for site in sites:
            head = pe.bytes_at(site - 3, 3)
            if head == FONT_RAMP_DEFAULT_IMM:
                written.append(u16(site + 4))
            elif head == FONT_RAMP_DEFAULT_REG and want == 0 and zeroed:
                written.append(0)
            else:
                written.append(-1)
        ck.equal(f"font.ramp_default_{global_va:#x}", tuple(written),
                 (want,) * len(sites),
                 "every writer of the briefing text box's descriptor")
    ck.check("font.ramp_is_the_descriptor's",
             all(pe.bytes_at(site, 2) == b"\x66\x8b"
                 and pe.u8(site + 3) == disp
                 for site, disp in FONT_RAMP_DESCRIPTOR_READS)
             and pe.u8(FONT_RAMP_DESCRIPTOR_PUSH) == 0x68
             and pe.u32(FONT_RAMP_DESCRIPTOR_PUSH + 1) == FONT_RAMP_DESCRIPTOR,
             "aCreateGUITextBox copies +0x1C..+0x22 of its argument")
    ck.check("font.break_is_never_drawn",
             pe.bytes_at(FONT_BREAK_SKIP, 5) == b"\x80\xfb\x40\x0f\x84",
             "aPrintGUITextBox skips `@` instead of printing it")

    for name, (site, colours) in sorted(FONT_RAMPS.items()):
        written = []
        for index in range(len(FONT_RAMP_SLOTS)):
            at = site + 8 * index
            written.append((pe.u8(at + 3), pe.u32(at + 4))
                           if pe.bytes_at(at, 3) == b"\xc7\x44\x24" else (-1, -1))
        ck.equal(f"font.ramp_{name}", tuple(written),
                 tuple(zip(FONT_RAMP_SLOTS, colours)),
                 "aPrintGUITextBox's four colours for this ramp")

    def pushed(va: int) -> int:
        """``push imm8`` or ``push imm32`` at *va*."""
        head = pe.u8(va)
        if head == 0x6A:
            return pe.u8(va + 1)
        if head == 0x68:
            return pe.u32(va + 1)
        return -1

    ck.check("gadget.info_box",
             call_target(pe, INFO_ACTIVATE_CALL) == INFO_ACTIVATE
             and tuple(pushed(va) for va in INFO_BOX_PUSHES) == INFO_BOX,
             f"aActivateBriefingInfo box {INFO_BOX}")
    ck.check("gadget.info_mode",
             pe.bytes_at(INFO_MODE_ARM, 5)
             == b"\xa1" + INFO_MODE_GLOBAL.to_bytes(4, "little")
             and pe.bytes_at(INFO_MODE_LIMIT, 3) == b"\x83\xf8\x02"
             and pe.bytes_at(INFO_MODE_PICTURE_GATE, 5)
             == b"\xa1" + INFO_MODE_GLOBAL.to_bytes(4, "little"),
             "the Upgrade Menu's *i* is a 0/1 toggle that hides the picture")

    flag = MAGNIFIER_FLAG.to_bytes(4, "little")
    ck.check("magnifier.mode",
             pe.bytes_at(MAGNIFIER_OFF_STORE, 10)
             == b"\xc7\x05" + flag + (0).to_bytes(4, "little")
             and pe.bytes_at(MAGNIFIER_ON_STORE, 10)
             == b"\xc7\x05" + flag + (1).to_bytes(4, "little")
             and pe.bytes_at(MAGNIFIER_READ, 5) == b"\xa1" + flag,
             f"event 13 toggles [{MAGNIFIER_FLAG:#010x}]")
    ck.equal("magnifier.cursor",
             tuple(pushed(va) for va, _shape in MAGNIFIER_CURSOR_PUSHES)
             + (call_target(pe, MAGNIFIER_CURSOR_CALL),),
             tuple(shape for _va, shape in MAGNIFIER_CURSOR_PUSHES)
             + (MAGNIFIER_CURSOR,),
             "cursor 10 while the mode is on, 0 when it goes off")
    ck.check("magnifier.click",
             call_target(pe, MAGNIFIER_CLICK_GATE_CALL) == MAGNIFIER_READ
             and call_target(pe, MAGNIFIER_CLICK_CALL) == MAGNIFIER_CLICK,
             "the selection routine asks for the mode and hands over the cell")
    ck.check("magnifier.tests",
             pe.bytes_at(MAGNIFIER_CELL_UNIT, 4) == b"\x66\x8b\x40\x07"
             and pe.bytes_at(MAGNIFIER_OWNER_TEST, 4) == b"\x80\x78\x45\xff"
             and pe.bytes_at(MAGNIFIER_VISIBLE_TEST, 3) == b"\x8a\x48\x4f"
             and call_target(pe, MAGNIFIER_PAGE_CALL) == MAGNIFIER_PAGE,
             "the cell's unit, owner 255, +0x4F zero")
    ck.equal("magnifier.page",
             tuple(pushed(va) for va in MAGNIFIER_PAGE_PUSHES)
             + (call_target(pe, MAGNIFIER_ACTIVATE_CALL),),
             MAGNIFIER_PAGE_BOX + (MAGNIFIER_ACTIVATE,),
             f"Data{MAGNIFIER_PAGE_BOX[1:5]}, family digit '0'")
    ck.check("magnifier.letter",
             pe.bytes_at(MAGNIFIER_LETTER_STRIDE, 5) == b"\xc1\xe2\x06\x2b\xd0"
             and pe.bytes_at(MAGNIFIER_LETTER_READ, 7)
             == b"\x8a\x04\x55" + MAGNIFIER_LETTER_TABLE.to_bytes(4, "little"),
             f"type * 126 + {MAGNIFIER_LETTER_TABLE:#010x}")
    ck.check("magnifier.heading",
             pe.bytes_at(MAGNIFIER_TITLE_ARGUMENT, 4) == b"\x8b\x7c\x24\x28"
             and pe.bytes_at(MAGNIFIER_TITLE_STORE, 5)
             == b"\xbf" + MAGNIFIER_TITLE_BUFFER.to_bytes(4, "little")
             and pe.bytes_at(MAGNIFIER_TITLE_TEST, 10)
             == b"\xbd" + MAGNIFIER_NO_TITLE.to_bytes(4, "little")
             + b"\xb8" + MAGNIFIER_TITLE_BUFFER.to_bytes(4, "little")
             and pushed(MAGNIFIER_NO_TITLE_PUSH) == MAGNIFIER_NO_TITLE,
             "the eighth argument is the name drawn over the box")
    ck.check("magnifier.fallback",
             pe.bytes_at(MAGNIFIER_FALLBACK, 4) == b"\x6a\x2a\x6a\x2a",
             "0x0043E850 retries with {:**} and no family digit")

    ck.check("map.event_switch",
             pe.bytes_at(MAP_EVENT_DISPATCH + 0x0F, 3) == b"\x0f\x87\x8b",
             "events 1..16 use the compiler jump table")
    ck.equal("map.event_targets",
             tuple(pe.u32(MAP_EVENT_TABLE + 4 * i) for i in range(16)),
             MAP_EVENT_TARGETS, "16 input-event arms")
    ck.equal("map.event_returns", {
        event: (pe.u8(va), pe.u32(va + 1))
        for event, (va, _result) in MAP_EVENT_RETURNS.items()
    }, {event: (0xB8, result)
        for event, (_va, result) in MAP_EVENT_RETURNS.items()},
             "events 5-8, 10, 15 and 16 return commands 2-8")
    ck.equal("map.event_actions", {
        event: call_target(pe, va)
        for event, (va, _target) in MAP_EVENT_DIRECT_CALLS.items()
    }, {event: target for event, (_va, target) in MAP_EVENT_DIRECT_CALLS.items()},
             "events 1, 2, 4 and 14 execute their actions directly")
    ck.equal("map.event_complex", {
        name: call_target(pe, va)
        for name, (va, _target) in MAP_EVENT_COMPLEX_CALLS.items()
    }, {name: target
        for name, (_va, target) in MAP_EVENT_COMPLEX_CALLS.items()},
             "events 3, 9 and 11-13 keep their operation chains")
    ck.check("map.event_default",
             pe.u8(MAP_EVENT_DEFAULT) == 0xB8
             and pe.u32(MAP_EVENT_DEFAULT + 1) == 9,
             "unknown events return command 9")
    ck.check("map.event_boundary",
             all(call_target(pe, va) == MAP_EVENT_DISPATCH
                 for va in MAP_EVENT_FROM_INPUT)
             and call_target(pe, MAP_EVENT_CONSUMER_CALL) == MAP_COMMAND_CONSUMER,
             "input translation feeds the BattleSystem command consumer")
    return ck


def report_json(root: str) -> None:
    root_path = Path(root)
    pe = PEFile(root_path / GAME_EXE)
    programs, texts = corpus(root_path)
    gui_commands = Counter()
    for program in programs.values():
        for routine in program.routines:
            for statement in walk(routine.body):
                if statement.name.startswith("GUI_"):
                    gui_commands[statement.name] += 1
    marker_lo = pe.u8(PLACE_MARKER_LO + 2)
    marker_hi = pe.u8(PLACE_MARKER_HI + 2)
    action_point_lo = pe.u8(MARK_AP_LO + 1)
    action_point_hi = pe.u8(MARK_AP_HI + 1)
    print(json.dumps({
        "screens": {name: [r.name for r in p.routines if r.name]
                    for name, p in programs.items()},
        "text_entries": sum(isinstance(n, lcl.TextEntry)
                            for p in texts.values() for r in p.routines for n in r.body),
        "gui_commands": dict(sorted(gui_commands.items())),
        "command_pad": {f"{x},{y}": pe.u32(va + 1)
                        for (x, y), (va, _command) in COMMAND_PAD_ARMS.items()},
        "use_executor": call_target(pe, USE_ARM_CALL),
        "deploy_markers": list(range(marker_lo, marker_hi + 1)),
        "deploy_action_points": list(range(action_point_lo, action_point_hi + 1)),
        "map_event_targets": [pe.u32(MAP_EVENT_TABLE + 4 * i)
                               for i in range(16)],
    }, indent=2, sort_keys=True))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", metavar="ROOT")
    parser.add_argument("--json", metavar="ROOT")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    if args.json:
        report_json(args.json)
        return 0
    if not args.check:
        parser.error("one of --check or --json is required")
    ck = run_checks(args.check)
    total = ck.passed + ck.failed
    if ck.failed:
        LOG.error("%d/%d checks failed", ck.failed, total)
        return 1
    LOG.info("%d/%d checks passed", ck.passed, total)
    return 0


if __name__ == "__main__":
    sys.exit(main())

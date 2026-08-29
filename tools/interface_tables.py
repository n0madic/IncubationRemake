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

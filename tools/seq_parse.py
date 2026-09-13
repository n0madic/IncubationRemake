#!/usr/bin/env python3
"""Inventory and verify Incubation's hard-coded sequence-player manifest.

The game has no sequence-description file.  ``aSetSeqPlayerVideoPart`` at
0x00465CC0 selects one of the entries below, constructs the model/animation
filenames, and hands the resulting list to the Charisma/3D runtime.  See
``docs/41-sequence-player.md``.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cha_parse  # noqa: E402
from inclib import charisma as chamod  # noqa: E402
from inclib import pose as posemod  # noqa: E402
from inclib.pe import PEFile  # noqa: E402

MANIFEST_SCHEMA = "incubation.sequences/1"

# Every arm of aSetSeqPlayerVideoPart ends by loading its CD-program string
# into edi and jumping here; the tail copies the actor list, starts the CD
# program and increments the part counter.  The last arm falls through instead.
TAIL = 0x00467DD5

# The zero-initialised global the Seq_5 arm loads as its CD program.  It sits
# past .data's raw bytes, so it is an empty string at load time -- and it is the
# very sentinel the tail compares the installed string against, which is why
# Seq_5 is the one part that does not raise newPart and keeps Seq_4's track.
EMPTY_STRING = 0x004FA524
EMPTY_STRING_COMPARE = 0x00467E94

# --- the CD program (docs/41 section 4, corrected 2026-09-08) ----------------
# The tail copies the arm's string to this global and hands it to the
# ``CDTrackProgram`` parser ``0x0042C040`` (after ``MCI_STOP`` ``0x0042BE50``
# and ``MCI_OPEN cdaudio`` ``0x0042BD80``), then starts the list with
# ``0x0042BC10``.  Nothing about it reaches the camera.
CD_PROGRAM = {
    "copy_target": 0x00514288,
    "copy_mov": 0x00467F15,          # mov edi, 0x514288
    "stop_call": 0x00467EE8,         # call 0x0042BE50   (MCI_STOP)
    "stop": 0x0042BE50,
    "open_call": 0x00467EF7,         # call 0x0042BD80   (MCI_OPEN cdaudio)
    "open": 0x0042BD80,
    "parse_call": 0x00467F33,        # call 0x0042C040   (CDTrackProgram)
    "parse": 0x0042C040,
    "start_call": 0x00467F3B,        # call 0x0042BC10   (play list entry)
    "start": 0x0042BC10,
    "separators_va": 0x004C2768,
    # ``0x0042BC10``: a list entry below zero wraps the cursor to 0 and plays
    # the first entry again, so ``"9,30"`` loops track 9 for ever and ``30`` is
    # a deliberately out-of-range terminator (the parser turns a token above the
    # CD's track count into -1).
    "wrap_bytes": bytes.fromhex(
        "a120e84f00" "8b0c858ce64f00" "85c9" "7d0b" "85c0" "7422" "33c0"
        "a320e84f00"),
}
#: ``strtok``'s separator set at ``0x004C2768``.  ``docs/20`` section 7.3 read
#: the dot alone; the engine accepts all nine.
CD_SEPARATORS = " .,|;:*+/"
#: What every non-empty program in the manifest is: one track and the 30 that
#: falls off the end of the CD.  The tracks a sequence names, 9..19, are
#: covered by the ``Track`` family alone (``music/Track09..19.ogg``); the
#: ``Arack`` family the shipped build plays stops at 14 (``docs/28`` 6.1).
CD_TERMINATOR = 30
CD_TRACK_RANGE = (9, 19)
CD_FAMILY = "Track"
CD_FILE_FORMAT = "Track%02d.ogg"
MUSIC_DIR = "music"

# --- the camera: parts named Cam<n>, a preset table for Focus ----------------
# ``0x0047F6A0``'s note dispatcher builds the literal ``"Cam"`` + itoa(index)
# and looks the part up by name; ``Switch n`` writes the index.  The index is
# reset to 1 when a pair is installed (``0x0048023B``), and the focal length is
# **not**: it carries across the shots of a part.
CAMERA = {
    "literal_push": 0x0047F7BB,     # push 0x4CD388 ("Cam")
    "literal_va": 0x004CD388,
    "index_reset": 0x0048023B,      # mov dword [esi+4], 1  in the pair installer
    "index_reset_bytes": bytes.fromhex("c746040100" "0000"),
    "default_index": 1,
    # The focal before any note: the player is constructed with
    # ``_ftol(width * 10/13)`` -- ``fmul qword [0x4B1570]`` in both branches
    # of ``aCreateSeqPlayer`` -- which is the same rule as the mission's
    # ``_E3D_init_3d_screen``: 492 pixels for the 640-wide full screen, 398 for
    # the 518-wide framed window.
    "focal_ratio_va": 0x004B1570,
    "focal_ratio_muls": (0x004654C2, 0x0046552D),
    "focal_ratio": 10.0 / 13.0,
}

# --- where a frame-0 note lands relative to the pair's first picture ---------
# ``0x0047F6A0`` is one update of the 3D player, in this order: the ended
# test (return 6), ``IWorld::Simulate(dt)`` -- vtable slot ``0x40`` on the
# ``"Film"`` world, the same slot the mission's refresh calls at
# ``0x00407112`` -- then the ``Cam<n>`` lookup and the render (slot ``0x38``).
# Simulate is where the notes are collected and dispatched: ``0x0047FD00``
# registers ``0x00480300`` (the note dispatcher) as callback kind 1 and
# ``0x00480730`` (the ended flag) as kind 0, and starts the clip through the
# animation interface's slot ``0x2C`` at speed 1.0, which rewinds nothing --
# ``KeyFramedAnimation::Init`` ``0x004A0B99`` left the clock at 0.  The
# collector ``0x004A1220`` takes a note at ``t <= start`` only while the
# clock reads exactly 0.0 (``fcomp dword [0x4B31C8]`` at ``0x004A16C0``), so
# a frame-0 note fires inside the first Simulate after the install -- before
# the first render of the pair, and never on a picture of its own.
NOTE_ORDER = {
    "simulate_call": 0x0047F76B,     # call [edx+0x40]  (Simulate dt)
    "simulate_bytes": bytes.fromhex("ff5240"),
    "render_call": 0x0047F82D,       # call [edx+0x38]  (render), later
    "render_bytes": bytes.fromhex("ff5238"),
    "mission_simulate": 0x00407112,  # the same slot in the 3D-view refresh
    "mission_bytes": bytes.fromhex("ff5040"),
    "start_call": 0x00480178,        # push 1.0 ; mov ecx, ebx ; call [edi+0x2C]
    "start_bytes": bytes.fromhex("680000803f" "8bcb" "ff572c"),
    "note_callback_push": 0x004801A0,   # push 0x00480300
    "note_callback": 0x00480300,
    "ended_callback_push": 0x004801D0,  # push 0x00480730
    "ended_callback": 0x00480730,
    "zero_compare": 0x004A16C0,      # fcomp dword [0x4B31C8]
    "zero_va": 0x004B31C8,
    "switch_push": 0x00480490,       # push "Switch", inside the dispatcher
    # ``StdWorld``'s vtable (RTTI ``.?AVStdWorld@@``): slot 0x40 is
    # ``Simulate(dt, flag)`` ``0x00497BA2`` and slot 0x50 the callback
    # registrar ``0x00497D1A`` (list at ``+0x24`` of {kind, actor, cb}).
    # One step of Simulate is three calls in this order: ``0x004980C7``
    # collects -- ``eventSource->slot 0x28`` at ``0x0049817A`` on every
    # registered entry, i.e. ``0x004A1220`` with that entry's kind --
    # ``0x00497FF1`` advances the animations, ``0x004986A7`` dispatches
    # every collected event through ``cb->slot 0x0C`` at ``0x00498770``,
    # which is ``PlayerCallback``'s trampoline into the member function.
    "world_vtable": 0x004B32A4,
    "simulate": 0x00497BA2,
    "register": 0x00497D1A,
    "step_calls": ((0x00497C0C, 0x004980C7), (0x00497C2A, 0x00497FF1),
                   (0x00497C36, 0x004986A7)),
    "collect_call": 0x0049817A,      # call [eax+0x28]
    "collect_bytes": bytes.fromhex("ff5028"),
    "dispatch_call": 0x00498770,     # call [edx+0x0C]
    "dispatch_bytes": bytes.fromhex("ff520c"),
    "trampoline": 0x004807A0,        # PlayerCallback slot 0x0C
    "trampoline_bytes": bytes.fromhex("8b542404" "8bc1" "8b4c2408" "51"
                                      "8b4804" "52" "ff5008"),
}
# ``Focus f`` at ``0x004804BB``: ``_ftol(atof(arg)) - 24`` indexes the byte
# table below when it is in 0..176 (an unsigned compare, so anything below 24
# takes the default too); the byte selects one of eight arms through the jump
# table, seven of which load a preset and the eighth the default.  The result is
# then scaled by the viewport height over 480 -- ``[ebp+0x40]`` is compared
# against 480 and 240 and multiplied by the **f32** reciprocals at
# ``0x004B1690`` (1/240) and ``0x004B1694`` (1/480); the ``[ebp+0xC]`` arm
# halves the preset first and uses 1/240, and the sequence player never takes
# it (its constructor gets ``push 0`` for that argument in both branches).
FOCUS = {
    "note_push": 0x004804BB,        # push "Focus"
    "bias": 24,
    "table_size": 177,
    "byte_table": 0x00480670,
    "jump_table": 0x00480650,
    "compare": 0x004804E8,          # cmp eax, 0xB0 ; ja default
    "arms": (0x004804FE, 0x00480505, 0x0048050C, 0x00480513, 0x0048051A,
             0x00480521, 0x00480528),
    "default_arm": 0x0048052F,
    "default": 765,
    "presets": (400, 500, 613, 877, 1477, 2350, 3500),
    "reference_height": 480,
    "half_height": 240,
    "recip_240": 0x004B1690,
    "recip_480": 0x004B1694,
    "half_scale": 0x004B1688,       # 0.5, the [ebp+0xC] arm
    "store": 0x00480597,            # mov [ebp+0x58], eax
    "fade_push": 0x0048059C,        # push "Fade" -- present, used by no clip
}
#: The presets the shipped clips ask for, ``f -> focal at 480``.  Measured over
#: the 130 selected clips (2026-09-08): 24, 28, 35, 43 and 50 and nothing else.
FOCUS_CORPUS = {24: 400, 28: 500, 35: 613, 43: 765, 50: 877}
FRAME_RATE = 30

# --- the front end around the sequences (docs/92 section 7.19) ---------------
# What mission control and the menu system do *between* the screens: the CD
# programs they start, the three ``Sleep`` holds, the boot splash, the gate
# that picks a sequence from the mission id and the flag that plays the intro
# once.  Every string here is copied to the stack as immediates by the
# compiler -- ``"2,3,4,5,6,7"`` is three dwords -- so the pins are the string
# addresses and the call sites, not a ``push <string>``.
FRONTEND = {
    "cd_programs": {
        # ``aMenuSystem.cpp``: the main menu and the load screen share one
        # program; the credits play track 8; mission control's entry plays
        # ``"5,4,2,5"`` (one program -- the ``"2,5"`` at 0x4CA7B4 is its
        # second dword) and the debriefing ``"7,3,2"``.
        "menu": ("2,3,4,5,6,7", 0x004CA1E0, 0x0044B398),
        "load": ("2,3,4,5,6,7", 0x004CA1E0, 0x0044F5C6),
        "credits": ("8", 0x004BFA98, 0x0044C083),
        "mission_control": ("5,4,2,5", 0x004CA7B0, 0x0045406E),
        "debriefing": ("7,3,2", 0x004CAE2C, 0x0045D671),
    },
    # ``push imm32`` immediately before ``call [Sleep]``.
    "holds_ms": {
        "logo": (1500, 0x0044BCF1),           # aGameIntro, after BlueByte.bmp
        "after_sequence": (1000, 0x004571D1),  # 0x00457180, the ordinary exit
        "after_extro": (4000, 0x0045718C),     # 0x00457180, mission id 255
    },
    "splash": {
        "logo_bmp": ("BlueByte.bmp", 0x004CA33C),
        "title_bmp": ("title.bmp", 0x004CA330),
        "menu_a": ("GUI\\Menu_a.LCL", 0x004CA320),
        "window": 13,                  # Menu_a's 13_GameIntro
        "text": ("Txtmod_a", 5),      # GUI_SetTextOnly2 05_WinText
        "at": (290, 420), "size": (60, 30), "font": 1,
    },
    "credits": {
        "window": 15,                  # Menu_a's Credits block, 0x0044C0B8
        "plate": "credits",
        "exit": ("Txtmod_a", 7, (450, 410)),
        "back": ("Txtmod_a", 8, (250, 410)),
        # ``0x0044BC60`` writes this flag and the main loop reads it; the
        # animated extro (after its 4000 ms hold) and the static extro's
        # *Continue* both call it with 1.
        "flag": 0x0050FE00,
        "flag_store": 0x0044BC64,
        # **The roll.**  ``Menu_a.lcl``'s Credits block carries the two
        # buttons and nothing else, but the menu's draw loop 0x0044B5E0 calls
        # 0x0044BD90 on every frame the window selector is 15, and that walks
        # ``Txtmod_a`` from 161 until a line reads *END*.  Every constant here
        # is read at the instruction that writes or pushes it.
        "roll": {
            "walk": 0x0044BD90,
            # ``cmp dword [0x0050FDF8], 0xF`` then the call two instructions
            # on: the roll is drawn only while the credits window is up.
            "window_gate": 0x0044B691,
            "gate_bytes": bytes.fromhex("833df8fd50000f" "750f"),
            "call_site": 0x0044B6A1,
            # ``mov dword [0x0050FE1C], 0x19A`` -- the first line's y.
            "position": 0x0050FE1C,
            "start": 410,
            "start_store": 0x0044C092,
            # ``dec dword [0x0050FE1C]`` at the end of a frame, gated on the
            # delay counter 0x0050FE20, which nothing ever sets above zero.
            "step_site": 0x0044C026,
            "delay": 0x0050FE20,
            # ``fcn.0047F2E0(20, 20)`` -- aLIB's frame-rate controller, which
            # busy-waits on GetTickCount until 1000/20 ms have passed.  One
            # step a frame at 20 frames a second is 20 units a second.
            "fps": 20,
            "fps_pushes": 0x0044BD9C,
            "fps_call": 0x0044BDB0,
            "rate_limiter": 0x0047F2E0,
            # ``fcn.00447B20(0, 0, 640, 400)`` -- the clip, which is why the
            # roll passes behind the buttons' row at 410 rather than over it.
            "clip": (0, 0, 640, 400),
            "clip_pushes": 0x0044BDB8,
            "clip_call": 0x0044BDC4,
            # ``mov dword [var_20h], 0xA1`` -- the first string id.
            "first_id": 161,
            "first_id_store": 0x0044BDA4,
            "terminator": ("END", 0x004C4868),
            "terminator_load": 0x0044BE38,
            # The five-arm switch on ``byte - '0'``.
            "switch_table": 0x0044C03C,
            "arms": (0x0044BE91, 0x0044BF42, 0x0044BFB8, 0x0044BFE8,
                     0x0044BFB8),
            # ``cmp al, 0x32`` -- a group end steps 30 and everything else 15.
            "advance_test": 0x0044BFF1,
            "advance_bytes": bytes.fromhex("750583c01eeb"),
            "advance_group": 30,
            "advance_line": 15,
            # The three printing arms, each ten pushes into aPrintLibText:
            # (format 2, 0, 0, cA, cX, 0, y, x=600, text, font).
            "print": 0x00439610,
            "text_x": 600,
            "prints": {
                "title": (0x0044BF1E, bytes.fromhex(
                    "6a026a006a00682c63000068ffff00006a00578d4c2445"
                    "6858020000516a01")),
                "heading": (0x0044BF97, bytes.fromhex(
                    "6a026a006a00688631000068b29400006a00578d442445"
                    "6858020000506a01")),
                "name": (0x0044BFB8, bytes.fromhex(
                    "6a026a006a00682c63000068ffff00006a00578d4c2445"
                    "6858020000516a00")),
            },
            "colours": {"title": (0xFFFF, 0x632C),
                        "heading": (0x94B2, 0x3186),
                        "name": (0xFFFF, 0x632C)},
            "fonts": {"title": 1, "heading": 1, "name": 0},
            # ``fcn.00463D80`` case 0 -- a row of pixels running *left* from
            # x 599 for the width aGetLibTextLength measured.  The title
            # underlines twice, at y+1 and y+3; a heading once, at y+1.
            "rule": 0x00463D80,
            "rule_x": 599,
            "rule_calls": (0x0044BEDE, 0x0044BF16, 0x0044BF8F),
            "rule_colours": {"title": 0x94B2, "heading": 0x632C},
            "measure": 0x00439C60,
            "print_tail": 0x0044BFD7,
            "print_call": 0x0044BFE0,
        },
    },
    "static_extro": {
        "window": 11,                  # Menu_b's 11_SlideShow
        "plate": "ship",
        "wave": "extro.wav",
        "continue": ("Txtmod_b", 4, (450, 430)),
        "continue_call": 0x0045BD8E,   # call 0x0044BC60 with 1
        "entry": 0x00457430,
    },
    "message_screen": {
        # ``aPrintMessageScreen`` 0x0045F290: MsgScr.bmp whole, Font_2, text
        # id 0 (*Please Wait...*) centred at (320, 65).  Both callers --
        # mission control's entry 0x00454007 and the debriefing's exit
        # 0x0045D436 -- pass id 0.
        "plate": "msgscr",
        "bmp": ("MsgScr.bmp", 0x004CAFD8),
        "font": ("Font_2.lib", 0x004CAF90),
        "text": ("Txtmod_b", 0),
        "at": (320, 65), "align": 1,
        "colours": (0xF79E, 0x632C),
        "callers": (0x00454007, 0x0045D436),
    },
    "sequence_caption": {
        # The framed presentation's background callback 0x00456F30 draws the
        # same id 0 at (320, 210) -- a loading caption, not the location's name.
        "text": ("Txtmod_b", 0), "at": (320, 210),
        "colours": (0xFFFF, 0x632C),
        "callback": 0x00456F30, "install": 0x00457047,
    },
    "gate": {
        # ``0x00456FC0(-1)``: mission id 1 with the intro flag -> logical id 0
        # full-screen; 180 -> the static extro (value 16); 255 -> logical id 1
        # full-screen; anything else -> no sequence, back to the map.
        "entry": 0x00456FC0,
        "mission_id_global": 0x00510C58,
        "full_screen_global": 0x00510DC0,
        "bytes_at": 0x00456FD2,
        "bytes": bytes.fromhex(
            "8b0d580c5100" "0bf6" "49" "7427" "81e9b3000000" "7413"
            "83e94b" "753a" "b801000000" "8bf0" "a3c00d5100" "eb2c" "b801"),
        "ids": {"intro": 1, "static_extro": 180, "animated_extro": 255},
        "logical": {"intro": 0, "animated_extro": 1},
    },
    "intro_flag": {
        # ``[0x00510D48]`` has one setter, 0x0045D3E0.  It is called with 1
        # from the new-campaign start 0x00450950 (and with 0 on its other
        # arm), with 0 at menu init 0x0044B329 (esi is zero there) and with 0
        # after any sequence at 0x004570B8.  Loading a save never re-arms it.
        "global": 0x00510D48,
        "setter": 0x0045D3E0,
        "set_one": 0x00450997,         # push 1 ; call setter
        "set_zero": (0x00450A11, 0x004570B6),
        "menu_init_call": 0x0044B329,
        "read": 0x00457004,
    },
    "exit": {
        # ``0x00457180``: mission id 255 -> Sleep(4000), credits flag, return
        # 0 (no destroy, no second hold); otherwise destroy, Sleep(1000),
        # back to mission control's map.  Reached from WM_LBUTTONDOWN (0x201)
        # and the key path of the GUI loop while window 8 is up.
        "entry": 0x00457180,
        "extro_compare": 0x00457180,   # cmp [0x510C58], 0xFF
        "click_site": 0x00455600, "key_site": 0x004557A0,
        "click_message": 0x201, "window": 8,
    },
    "windows": {"full": (0, 0, 640, 480), "framed": (65, 57, 518, 306)},
    "briefing": {
        # docs/24 section 7.1; ``animate`` is the sixth argument and 0 means
        # the typewriter.
        "mission_start": ("A0", (100, 100, 387, 199), 0x0041B629),
        # The location map's, on mission control's action ``0xb`` --
        # ``0x00451240`` maps the character ``B`` to it and ``0x00453900``'s
        # arm calls ``aActivateBriefingInfo`` with ``animate = 0``.  Its gate
        # is ``0x0043b700() == 1 and not 0x0043b1f0()``: exactly one human
        # player, and not the network predicate, which reads the mode byte
        # ``0x00509ee8`` and the flag ``0x00509f08``.  Both hold in every
        # single-player campaign, so this box is not behind a switch.
        "map_short": ("B0", (220, 100, 200, 300), 0x00453990),
        "map_short_key": "B",
        "map_short_action": 0x0B,
        # ``0x0045130b``'s ``jmp dword [edx*4 + 0x4513e4]`` and the arm that
        # slot fifteen points at, ``mov esi, 0xb``.
        "map_short_dispatch": (0x0045130E, 0x004513E4),
        "map_short_arm": 0x004513A4,
        # ``0x0043b1f0`` -> ``0x0043b1e0`` -> ``[0x00509f08]``.
        "map_short_gate": (0x0043B1F0, 0x0043B1E0, 0x00509F08),
        # The gate's *other* half, and the one that decides what a campaign
        # sees: ``0x0043b700`` counts the player slots at ``0x00509e20`` that
        # hold 1 -- the human players -- over ``[0x00509e30]`` of them.  It is
        # a **count**, not a flag, which is what makes "exactly one human" the
        # condition rather than "single player".
        "map_short_humans": (0x0043B700, 0x00509E20, 0x00509E30),
        # The arm the same key takes when that gate fails: ``0x004539c1`` sets
        # ``0x005106d4`` to 1 and draws nothing.  It is the flag's **only**
        # writer in the image (``0x004538e0`` reads it, ``0x004538f0`` clears
        # it), and the mission's first frame ``0x0041a980`` then draws one of
        # two things -- the full ``A0`` briefing when the network predicate
        # holds, and otherwise ``0x0045fa00``'s per-player strength panel.
        # So the panel is the **hot-seat** shape: two or more humans on one
        # machine with no network.  One human never arms the flag, which is
        # why a campaign draws neither.
        "start_flag": 0x005106D4,
        "start_flag_setter": 0x004539C1,
        "start_flag_reader": 0x004538E0,
        "start_flag_clear": 0x004538F0,
        "strength_panel": 0x0045FA00,
        "strength_panel_site": 0x0041B66F,
        # **Not the deployment screen.**  The ninth slice drew this box over
        # the unit-selection view because docs/24 section 7.1's table named
        # that screen without reading the arm.  ``0x0044eeda`` is inside
        # ``aMenuSystem``'s gadget dispatcher ``0x0044dcd0``, whose outer
        # switch is on ``Menu_a``'s window selector ``[0x50fdf8]``: window
        # **10** is ``:Leveloptions;`` and the gadget that reaches this arm
        # is **22**, the button ``Menu_a.lcl`` comments ``* infos``.  That is
        # the multiplayer level-options screen -- the DirectPlay path -- and
        # ``SelectUnits`` is a ``Menu_b`` window whose arm calls
        # ``aActivateBriefingInfo`` nowhere at all.
        "level_options_short": ("B0", (220, 120, 200, 500), 0x0044EEDA),
        # The chain that says so, read rather than counted.
        "menu_dispatch": 0x0044DCD0,
        "menu_window": 0x0050FDF8,
        "menu_window_bound_site": 0x0044DCDB,   # ``cmp eax, 0x10``
        "menu_window_count": 17,                # ``Menu_a``'s 00.._16
        "menu_window_table": 0x0044FB7C,
        # ``[0x50fdf8] = 7`` right after the loader pushes ``GUI\Menu_a.LCL``:
        # what pins the selector to ``Menu_a`` by a **writer** rather than by
        # the arm count.  7 is ``Menu_a``'s ``07_MainMenu``.
        "menu_a_name": "GUI\\Menu_a.LCL",
        "menu_a_name_site": 0x0044D2F4,
        "menu_a_main_menu_site": 0x0044D37C,
        "menu_a_main_menu": 7,
        # Window 10's arm and its own switch: 23 gadget ids through a byte
        # index table into a jump table.
        "level_options_window": 10,
        "level_options_arm": 0x0044EB52,
        "level_options_gadget_bound_site": 0x0044EB59,   # ``cmp edi, 0x16``
        "level_options_gadget_max": 22,
        "level_options_index_table": 0x0044FC74,
        "level_options_jump_table": 0x0044FC3C,
        "level_options_infos_gadget": 22,
        "level_options_infos_arm": 0x0044EEBD,
        # Every ``aActivateBriefingInfo`` call site in the image, so a future
        # reader cannot attribute one to a screen from memory.  Only one of
        # them is inside the dispatcher at all.
        "activate": 0x0043EAB0,
        "activate_sites": (0x0041B629, 0x0044EEDA, 0x00453990, 0x00456D96,
                           0x00456DE0, 0x004577DB, 0x0045783F, 0x0047CEE8),
        # These two **are** `Menu_b`'s, and by the same kind of evidence the
        # `Infos` box above is not: the routine that carries them pushes
        # ``GUI\Menu_b.LCL`` at ``0x00456d17`` and loads it, and both calls
        # follow inside it.  Read rather than named, after `0x0044eeda` was
        # attributed to a screen by name and turned out to be somewhere else.
        "screen": ("A0", (84, 77, 280, 276), 0x00456DE0),
        "tips": ("C0", (84, 77, 230, 276), 0x00456D96),
        "menu_b_name": "GUI\\Menu_b.LCL",
        "menu_b_name_site": 0x00456D17,
        # ``fcn.0043ECF0``: every printed frame adds one to each of the four
        # limits (-1 is unlimited; the caps are 5000 and 50000), so a glyph
        # and a word appear per frame; a space below the word limit plays
        # ``textbeep.wav`` (0x0043E3C1 -> 0x00436EF0).
        "per_frame": 1,
        "advance": 0x0043F0AB,
        "caps": (5000, 50000),
        "blip": ("textbeep.wav", 0x004C4404),
        "voice_format": "%smb%daif.wav",
        "voice_format_va": 0x004CA8D8,
    },
}


@dataclass(frozen=True)
class Arm:
    """Where ``aSetSeqPlayerVideoPart`` builds one video part.

    ``model_pushes`` and ``animation_pushes`` are ``(push va, string va, text)``:
    one entry for an arm that formats ``%d`` in a loop, one per stem for an arm
    the compiler unrolled.  ``cd_mov`` is the ``mov edi, <string>`` that
    closes the arm and loads its **CD track program** -- ``"9,30"`` is not a
    camera path but the argument the shared tail hands to the ``CDTrackProgram``
    parser (see ``CD_PROGRAM``).  The program therefore belongs to the arm
    *preceding* the tail jump, which is what the ``contiguous`` check proves:
    no other arm's jump to ``TAIL`` lies between the arm's first push and its
    string load.
    ``count_cmp`` is the ``cmp reg, imm8`` that closes a looping arm; unrolled
    arms have none and are pinned by their per-stem pushes instead.
    """

    model_pushes: tuple[tuple[int, int, str], ...]
    animation_pushes: tuple[tuple[int, int, str], ...]
    cd_mov: int
    cd_string: int
    count_cmp: int | None = None


@dataclass(frozen=True)
class Part:
    directory: str
    stems: tuple[str, ...]
    cd_program: str
    arm: Arm

    def model(self, stem: str) -> str:
        if self.directory == "Dialog_09":
            return "Model_D09.cho"
        return f"Model_{stem}.cho"

    def animation(self, stem: str) -> str:
        return f"Animation_{stem}.cha"


def numbered(prefix: str, first: int, last: int) -> tuple[str, ...]:
    return tuple(f"{prefix}_{i}" for i in range(first, last + 1))


# Logical id passed to aCreateSeqPlayer -> successive video parts.  IDs not
# present here are rejected by the executable's compressed 0..15 switch.
SEQUENCES: dict[int, tuple[Part, ...]] = {
    0: (
        Part("Seq_1", numbered("1", 1, 15), "9,30", Arm(
            ((0x00465D8A, 0x004CBFF8, "%sSeq_1\\Model_1_%d.cho"),),
            ((0x00465DB8, 0x004CBFD0, "%sSeq_1\\Animation_1_%d.cha"),),
            0x00465E68, 0x004CBFB8, 0x00465E5B)),
        Part("Seq_3", numbered("3", 1, 34), "10,30", Arm(
            ((0x00465F58, 0x004CBF68, "%sSeq_3\\Model_3_%d.cho"),),
            ((0x00465F86, 0x004CBF40, "%sSeq_3\\Animation_3_%d.cha"),),
            0x004660BC, 0x004CBF28, 0x00466029)),
        Part("Seq_4", ("4_0", "4_1", "4_3", "4_4"), "11,30", Arm(
            ((0x004661A0, 0x004CBED8, "%sSeq_4\\Model_4_0.cho"),
             (0x0046627F, 0x004CBE88, "%sSeq_4\\Model_4_1.cho"),
             (0x0046639B, 0x004CBE38, "%sSeq_4\\Model_4_3.cho"),
             (0x00466476, 0x004CBDE8, "%sSeq_4\\Model_4_4.cho")),
            ((0x004661CC, 0x004CBEB0, "%sSeq_4\\Animation_4_0.cha"),
             (0x004662AB, 0x004CBE60, "%sSeq_4\\Animation_4_1.cha"),
             (0x004663C7, 0x004CBE10, "%sSeq_4\\Animation_4_3.cha"),
             (0x004664A2, 0x004CBDC0, "%sSeq_4\\Animation_4_4.cha")),
            0x004665FC, 0x004CBDA8)),
        Part("Seq_5", ("5_0", "5_1", "5_2", "5_3", "5_7", "5_9", "5_10"), "", Arm(
            ((0x004666E0, 0x004CBD58, "%sSeq_5\\Model_5_0.cho"),
             (0x00466804, 0x004CBD08, "%sSeq_5\\Model_5_1.cho"),
             (0x00466922, 0x004CBCB8, "%sSeq_5\\Model_5_2.cho"),
             (0x00466A40, 0x004CBC68, "%sSeq_5\\Model_5_3.cho"),
             (0x00466B1B, 0x004CBC18, "%sSeq_5\\Model_5_7.cho"),
             (0x00466C39, 0x004CBBC8, "%sSeq_5\\Model_5_9.cho"),
             (0x00466D14, 0x004CBB78, "%sSeq_5\\Model_5_10.cho")),
            ((0x0046670C, 0x004CBD30, "%sSeq_5\\Animation_5_0.cha"),
             (0x00466830, 0x004CBCE0, "%sSeq_5\\Animation_5_1.cha"),
             (0x0046694E, 0x004CBC90, "%sSeq_5\\Animation_5_2.cha"),
             (0x00466A6C, 0x004CBC40, "%sSeq_5\\Animation_5_3.cha"),
             (0x00466B47, 0x004CBBF0, "%sSeq_5\\Animation_5_7.cha"),
             (0x00466C65, 0x004CBBA0, "%sSeq_5\\Animation_5_9.cha"),
             (0x00466D40, 0x004CBB50, "%sSeq_5\\Animation_5_10.cha")),
            0x00466E9A, EMPTY_STRING)),
    ),
    1: (Part("Extro", numbered("Extro", 1, 8), "19,30", Arm(
        ((0x00467CB3, 0x004CB7BC, "%sExtro\\Model_Extro_%d.cho"),),
        ((0x00467CE1, 0x004CB78C, "%sExtro\\Animation_Extro_%d.cha"),),
        0x00467DD0, 0x004CB770, 0x00467DC3)),),
    2: (Part("Dialog_02", ("D02",), "12,30", Arm(
        ((0x00466F5B, 0x004CBB24, "%sDialog_02\\Model_D02.cho"),),
        ((0x00466F87, 0x004CBAF8, "%sDialog_02\\Animation_D02.cha"),),
        0x00467065, 0x004CBAE0)),),
    3: (Part("Dialog_03", numbered("D03", 1, 9), "13,30", Arm(
        ((0x004670D6, 0x004CBABC, "Video\\Dialog_03\\Model_D03_%d.cho"),),
        ((0x004670F9, 0x004CBA84, "Video\\Dialog_03\\Animation_D03_%d.cha"),),
        0x004671E8, 0x004CBA68, 0x004671DB)),),
    7: (
        Part("Dialog_07", ("D07",), "14,30", Arm(
            ((0x0046757F, 0x004CB9A0, "%sDialog_07\\Model_D07.cho"),),
            ((0x004675AB, 0x004CB974, "%sDialog_07\\Animation_D07.cha"),),
            0x00467689, 0x004CB95C)),
        Part("Dialog_09", numbered("D09", 1, 18), "15,30", Arm(
            ((0x0046732E, 0x004CBA08, "%sDialog_09\\Model_D09.cho"),),
            ((0x00467388, 0x004CB9D8, "%sDialog_09\\Animation_D09_%d.cha"),),
            0x0046755D, 0x004CB9BC, 0x00467448)),
    ),
    14: (Part("Dialog_14", ("D14",), "16,30", Arm(
        ((0x004676FF, 0x004CB940, "%sDialog_14\\Model_D14.cho"),),
        ((0x0046772B, 0x004CB914, "%sDialog_14\\Animation_D14.cha"),),
        0x00467809, 0x004CB8FC)),),
    15: (
        Part("Dialog_15", numbered("D15", 1, 11), "17,30", Arm(
            ((0x00467B1A, 0x004CB828, "%sDialog_15\\Model_D15_%d.cho"),),
            ((0x00467B48, 0x004CB7F4, "%sDialog_15\\Animation_D15_%d.cha"),),
            0x00467C37, 0x004CB7D8, 0x00467C2A)),
        Part("Dialog_16", numbered("D16", 1, 21), "18,30", Arm(
            ((0x0046794F, 0x004CB898, "%sDialog_16\\Model_D16_%d.cho"),),
            ((0x0046797D, 0x004CB864, "%sDialog_16\\Animation_D16_%d.cha"),),
            0x00467AF2, 0x004CB848, 0x00467A5F)),
    ),
}

EXPECTED_IDS = (0, 1, 2, 3, 7, 14, 15)
EXPECTED_DIRS = {
    "Dialog_02", "Dialog_03", "Dialog_07", "Dialog_09", "Dialog_14",
    "Dialog_15", "Dialog_16", "Extro", "Seq_1", "Seq_3", "Seq_4", "Seq_5",
}

# The per-directory resource roots the arms hand to aInit3DEnginePure when a
# part changes directory.
RESOURCE_STRINGS = {
    0x004CBFA4: "%sSeq_3\\Objects\\",
    0x004CBF90: "%sSeq_3\\Textures\\",
    0x004CBF80: "%sSeq_3\\Img\\",
    0x004CB8E4: "%sDialog_16\\Objects\\",
    0x004CBA50: "%sDialog_09\\Objects\\",
}


class Checks:
    def __init__(self) -> None:
        self.total = 0
        self.failures: list[str] = []

    def check(self, name: str, condition: bool, detail: str) -> None:
        self.total += 1
        if not condition:
            self.failures.append(f"{name}: {detail}")


def parts() -> list[Part]:
    return [part for chain in SEQUENCES.values() for part in chain]


def push_ok(pe: PEFile, push_va: int, string_va: int, text: str) -> bool:
    """The instruction at ``push_va`` pushes exactly ``text``'s address."""
    return (pe.bytes_at(push_va, 5) == b"\x68" + struct.pack("<I", string_va)
            and pe.cstring(string_va) == text)


def jumps_to_tail(pe: PEFile, lo: int, hi: int) -> bool:
    """Is there a ``jmp TAIL`` — an arm boundary — in ``[lo, hi)``?"""
    window = pe.bytes_at(lo, hi - lo)
    for offset in range(len(window) - 4):
        if window[offset] != 0xE9:
            continue
        rel = struct.unpack_from("<i", window, offset + 1)[0]
        if lo + offset + 5 + rel == TAIL:
            return True
    return False


def check_arms(pe: PEFile, ck: Checks) -> None:
    """Pin every arm to its directory, its stems, its camera and its bound.

    This is the check the manifest actually rests on: the file-existence check
    below would pass for any table derived by listing ``Video/``, and pinning
    the camera strings alone would not notice two of them being swapped.
    """
    for part in parts():
        arm, tag = part.arm, part.directory
        pushes = arm.model_pushes + arm.animation_pushes
        ck.check(f"arm.{tag}.strings",
                 all(push_ok(pe, *push) for push in pushes),
                 "a model/animation template is not pushed where expected")
        ck.check(f"arm.{tag}.unrolled",
                 (len(arm.model_pushes) == len(arm.animation_pushes)
                  and len(arm.model_pushes) in (1, len(part.stems))),
                 f"{len(arm.model_pushes)} pushes for {len(part.stems)} stems")

        program = ("" if arm.cd_string == EMPTY_STRING
                   else pe.cstring(arm.cd_string))
        ck.check(f"arm.{tag}.cd_program",
                 (pe.bytes_at(arm.cd_mov, 5)
                  == b"\xbf" + struct.pack("<I", arm.cd_string)
                  and program == part.cd_program),
                 f"CD program at 0x{arm.cd_mov:08X} is {program!r}, "
                 f"not {part.cd_program!r}")

        first_push = min(va for va, _, _ in pushes)
        ck.check(f"arm.{tag}.contiguous",
                 (first_push < arm.cd_mov
                  and not jumps_to_tail(pe, first_push, arm.cd_mov)),
                 "another arm ends between this arm's pushes and its program")

        if arm.count_cmp is None:
            continue
        cmp_bytes = pe.bytes_at(arm.count_cmp, 3)
        last = int(part.stems[-1].rsplit("_", 1)[1])
        ck.check(f"arm.{tag}.bound",
                 cmp_bytes[0] == 0x83 and cmp_bytes[2] == last,
                 f"loop bound at 0x{arm.count_cmp:08X} is {cmp_bytes.hex()}, "
                 f"not cmp reg, {last}")



# ---------------------------------------------------------------------------
# The CD program, the camera and the Focus table
# ---------------------------------------------------------------------------

def activate_sites(pe: PEFile, target: int) -> list[int]:
    """Every ``call rel32`` in ``.text`` that reaches *target*.

    A screen's briefing box is attributed by the **arm** that calls it, and
    the ninth slice got one wrong by trusting a table row instead; the list is
    pinned so a new site cannot appear unnoticed.
    """
    lo, size, rawptr, rawsize = pe.section(".text")
    blob = pe.data[rawptr:rawptr + rawsize]
    out: list[int] = []
    for off in range(len(blob) - 5):
        if blob[off] != 0xE8:
            continue
        rel = struct.unpack_from("<i", blob, off + 1)[0]
        if lo + off + 5 + rel == target:
            out.append(lo + off)
    return out


def call_target(pe: PEFile, va: int) -> int | None:
    """The absolute target of the ``call rel32`` at ``va``, or None."""
    code = pe.bytes_at(va, 5)
    if code[0] != 0xE8:
        return None
    return va + 5 + struct.unpack("<i", code[1:])[0]


def parse_cd_program(text: str, track_count: int = 99) -> list[int]:
    """``0x0042C040``: ``strtok`` over :data:`CD_SEPARATORS`, ``atoi`` per token,
    and a token above the CD's track count becomes ``-1``.

    ``track_count`` defaults past every real disc so the manifest's ``30``
    survives as a number; the game's own value is ``[0x4FE688]`` at run time,
    which is why ``"9,30"`` on a 20-track disc is ``[9, -1]`` and the wrap in
    ``0x0042BC10`` makes it a loop of track 9.
    """
    tokens: list[str] = []
    current = ""
    for ch in text:
        if ch in CD_SEPARATORS:
            if current:
                tokens.append(current)
            current = ""
        else:
            current += ch
    if current:
        tokens.append(current)
    out: list[int] = []
    for token in tokens:
        digits = ""
        for ch in token:
            if not ch.isdigit():
                break
            digits += ch
        value = int(digits) if digits else 0
        out.append(value if value <= track_count else -1)
    return out


def cd_track_of(program: str) -> int:
    """The one track a manifest program loops, or -1 for the empty string."""
    tracks = parse_cd_program(program)
    return tracks[0] if tracks else -1


def check_cd_program(pe: PEFile, root: Path, ck: Checks) -> None:
    """The tail plays the string as a CD program; every program is one track."""
    cd = CD_PROGRAM
    ck.check("cd.copy",
             pe.bytes_at(cd["copy_mov"], 5)
             == b"\xbf" + struct.pack("<I", cd["copy_target"]),
             "the tail no longer copies the string to 0x514288")
    for name in ("stop", "open", "parse", "start"):
        ck.check(f"cd.{name}_call",
                 call_target(pe, cd[f"{name}_call"]) == cd[name],
                 f"0x{cd[name + '_call']:08X} does not call 0x{cd[name]:08X}")
    ck.check("cd.separators", pe.cstring(cd["separators_va"]) == CD_SEPARATORS,
             f"separators are {pe.cstring(cd['separators_va'])!r}")
    ck.check("cd.wrap",
             pe.bytes_at(cd["start"], len(cd["wrap_bytes"])) == cd["wrap_bytes"],
             "0x0042BC10 no longer wraps a negative entry to index 0")
    programs = {part.cd_program for part in parts() if part.cd_program}
    parsed = {program: parse_cd_program(program) for program in programs}
    ck.check("cd.one_track_each",
             all(len(v) == 2 and v[1] == CD_TERMINATOR
                 and CD_TRACK_RANGE[0] <= v[0] <= CD_TRACK_RANGE[1]
                 for v in parsed.values()),
             f"programs parse to {parsed}")
    ck.check("cd.tracks_distinct",
             len({v[0] for v in parsed.values()}) == len(parsed),
             "two parts loop the same track")
    ck.check("cd.seq_5_silent",
             [p.cd_program for p in parts() if p.directory == "Seq_5"] == [""],
             "Seq_5 no longer keeps Seq_4's track")
    missing = [CD_FILE_FORMAT % v[0] for v in parsed.values()
               if not (root / MUSIC_DIR / (CD_FILE_FORMAT % v[0])).is_file()]
    ck.check("cd.track_files", not missing,
             f"missing {MUSIC_DIR}/{missing}")
    ck.check("cd.terminator_out_of_range",
             parse_cd_program("9,30", track_count=20) == [9, -1],
             "a token above the track count must become -1")


def check_camera(pe: PEFile, ck: Checks) -> None:
    """``Cam<n>`` by name, index 1 per pair, focal ``width * 10/13`` at start."""
    cam = CAMERA
    ck.check("camera.literal",
             pe.bytes_at(cam["literal_push"], 5)
             == b"\x68" + struct.pack("<I", cam["literal_va"])
             and pe.cstring(cam["literal_va"]) == "Cam",
             "the note dispatcher no longer builds the name from \"Cam\"")
    ck.check("camera.index_reset",
             pe.bytes_at(cam["index_reset"], 7) == cam["index_reset_bytes"],
             "installing a pair no longer resets the camera index to 1")
    ratio = pe.f64(cam["focal_ratio_va"])
    ck.check("camera.focal_ratio", abs(ratio - cam["focal_ratio"]) < 1e-12,
             f"0x{cam['focal_ratio_va']:08X} holds {ratio}")
    ck.check("camera.focal_ratio_used",
             all(pe.bytes_at(va, 6)
                 == b"\xdc\x0d" + struct.pack("<I", cam["focal_ratio_va"])
                 for va in cam["focal_ratio_muls"]),
             "aCreateSeqPlayer no longer multiplies the width by 10/13")


def check_note_order(pe: PEFile, ck: Checks) -> None:
    """A frame-0 note fires in the first Simulate, before the pair's first render."""
    order = NOTE_ORDER
    ck.check("notes.simulate_before_render",
             pe.bytes_at(order["simulate_call"], 3) == order["simulate_bytes"]
             and pe.bytes_at(order["render_call"], 3) == order["render_bytes"]
             and order["simulate_call"] < order["render_call"],
             "0x0047F6A0 no longer simulates the film before it renders it")
    ck.check("notes.simulate_is_the_missions_slot",
             pe.bytes_at(order["mission_simulate"], 3) == order["mission_bytes"],
             "0x00407112 no longer calls slot 0x40 on the world")
    ck.check("notes.start_at_speed_one",
             pe.bytes_at(order["start_call"], 10) == order["start_bytes"],
             "the pair installer no longer starts the clip at speed 1.0")
    ck.check("notes.callbacks",
             pe.bytes_at(order["note_callback_push"], 5)
             == b"\x68" + struct.pack("<I", order["note_callback"])
             and pe.bytes_at(order["ended_callback_push"], 5)
             == b"\x68" + struct.pack("<I", order["ended_callback"])
             and order["note_callback"] < order["switch_push"]
             < order["ended_callback"],
             "the note dispatcher and the ended flag are no longer the two callbacks")
    ck.check("notes.simulate_collects",
             pe.u32(order["world_vtable"] + 0x40) == order["simulate"]
             and pe.u32(order["world_vtable"] + 0x50) == order["register"]
             and all(pe.u8(site) == 0xE8
                     and (site + 5 + pe.i32(site + 1)) & 0xFFFFFFFF == target
                     for site, target in order["step_calls"])
             and pe.bytes_at(order["collect_call"], 3) == order["collect_bytes"]
             and pe.bytes_at(order["dispatch_call"], 3) == order["dispatch_bytes"]
             and pe.bytes_at(order["trampoline"], 18) == order["trampoline_bytes"],
             "StdWorld::Simulate no longer collects, advances and dispatches "
             "through the registered callbacks")
    ck.check("notes.zero_start_is_inclusive",
             pe.bytes_at(order["zero_compare"], 6)
             == b"\xd8\x1d" + struct.pack("<I", order["zero_va"])
             and struct.unpack("<f", pe.bytes_at(order["zero_va"], 4))[0] == 0.0,
             "the collector no longer keeps a note at t <= start while the clock is 0")


def default_focal(width: int) -> int:
    """The focal length a player starts with: ``_ftol(width * 10/13)``."""
    return int(width * CAMERA["focal_ratio"])


def focus_table(pe: PEFile) -> dict[int, int]:
    """``f -> focal at 480 rows`` for every ``f`` the byte table covers."""
    arms = {va: preset for va, preset in zip(FOCUS["arms"], FOCUS["presets"])}
    arms[FOCUS["default_arm"]] = FOCUS["default"]
    jump = [pe.u32(FOCUS["jump_table"] + 4 * i) for i in range(8)]
    table = pe.bytes_at(FOCUS["byte_table"], FOCUS["table_size"])
    return {FOCUS["bias"] + i: arms[jump[table[i]]] for i in range(len(table))}


def scaled_focal(preset: int, height: int) -> int:
    """``_ftol(preset * height / 480)``; exactly the preset at 480 rows."""
    if height == FOCUS["reference_height"]:
        return preset
    return int(preset * (height * (1.0 / FOCUS["reference_height"])))


def check_focus_table(pe: PEFile, ck: Checks) -> None:
    ck.check("focus.note_push",
             pe.bytes_at(FOCUS["note_push"], 1) == b"\x68"
             and pe.cstring(pe.u32(FOCUS["note_push"] + 1)) == "Focus",
             "the dispatcher no longer matches \"Focus\"")
    ck.check("focus.fade_present",
             pe.bytes_at(FOCUS["fade_push"], 1) == b"\x68"
             and pe.cstring(pe.u32(FOCUS["fade_push"] + 1)) == "Fade",
             "the Fade note is gone")
    ck.check("focus.compare",
             pe.bytes_at(FOCUS["compare"], 7)
             == b"\x3d" + struct.pack("<I", FOCUS["table_size"] - 1) + b"\x77\x40",
             "the byte table is no longer bounded at 176")
    arms_ok = all(pe.bytes_at(va, 5) == b"\xb8" + struct.pack("<I", preset)
                  for va, preset in zip(FOCUS["arms"], FOCUS["presets"]))
    ck.check("focus.arms", arms_ok
             and pe.bytes_at(FOCUS["default_arm"], 5)
             == b"\xb8" + struct.pack("<I", FOCUS["default"]),
             "one of the eight preset arms changed")
    jump = [pe.u32(FOCUS["jump_table"] + 4 * i) for i in range(8)]
    ck.check("focus.jump_table",
             set(jump) == set(FOCUS["arms"]) | {FOCUS["default_arm"]},
             f"jump table is {[hex(v) for v in jump]}")
    table = focus_table(pe)
    ck.check("focus.corpus_values",
             all(table[f] == preset for f, preset in FOCUS_CORPUS.items()),
             f"{ {f: table[f] for f in FOCUS_CORPUS} }")
    ck.check("focus.seven_plus_default",
             sorted(set(table.values())) == sorted(set(FOCUS["presets"])
                                                   | {FOCUS["default"]}),
             f"table reaches {sorted(set(table.values()))}")
    named = {f for f, v in table.items() if v != FOCUS["default"]}
    ck.check("focus.named_entries", named == {24, 28, 35, 50, 85, 135, 200},
             f"non-default entries at {sorted(named)}")
    recip_240 = struct.unpack("<f", pe.bytes_at(FOCUS["recip_240"], 4))[0]
    recip_480 = struct.unpack("<f", pe.bytes_at(FOCUS["recip_480"], 4))[0]
    ck.check("focus.reciprocals",
             abs(recip_240 * 240 - 1.0) < 1e-6 and abs(recip_480 * 480 - 1.0) < 1e-6,
             f"1/240 reads {recip_240}, 1/480 reads {recip_480}")
    ck.check("focus.store",
             pe.bytes_at(FOCUS["store"], 3) == b"\x89\x45\x58",
             "the focal is no longer stored at [ebp+0x58]")
    ck.check("focus.scaling", scaled_focal(765, 480) == 765
             and scaled_focal(765, 240) == 382 and scaled_focal(400, 960) == 800,
             "the height scaling changed")


# ---------------------------------------------------------------------------
# The notes: Switch n names Cam<n>, every model has Cam1
# ---------------------------------------------------------------------------

def parse_note_lines(text: str) -> list[tuple[str, Any]]:
    """``docs/40`` section 9's rule: split on CR/LF, trim, ignore blanks, match
    ``BREAK`` / ``Focus <float>`` / ``Switch <int>`` / ``Fade <int>``, ignore
    the rest.  The value is read as ``atof``/``atoi`` do -- the longest numeric
    prefix -- so ``Focus 43..0`` is 43."""
    out: list[tuple[str, Any]] = []
    for raw in text.replace("\r", "\n").split("\n"):
        line = raw.strip()
        if not line:
            continue
        verb, _, arg = line.partition(" ")
        arg = arg.strip()
        if verb == "BREAK" and not arg:
            out.append(("BREAK", None))
        elif verb == "Focus":
            out.append(("Focus", _atof(arg)))
        elif verb == "Switch":
            out.append(("Switch", _atoi(arg)))
        elif verb == "Fade":
            out.append(("Fade", _atoi(arg)))
        else:
            out.append(("ignored", line))
    return out


def _atoi(text: str) -> int:
    digits = ""
    for ch in text:
        if not ch.isdigit():
            break
        digits += ch
    return int(digits) if digits else 0


def _atof(text: str) -> float:
    head = ""
    seen_dot = False
    for ch in text:
        if ch.isdigit():
            head += ch
        elif ch == "." and not seen_dot:
            head += ch
            seen_dot = True
        else:
            break
    return float(head) if head.strip(".") else 0.0


def check_camera_roll(video: Path, ck: Checks) -> None:
    """How far a ``Cam<n>`` bone is rolled about its own forward axis.

    ``docs/41`` §7 measured the *forward* axis (engine +Y, 514 of 520 poses)
    and left the roll open, on the grounds that a mean-of-the-parts argument
    cannot see a rotation about the axis it measures.  It can be measured
    directly instead: take the world up with the forward component removed --
    what an unrolled camera's own up would be -- and the signed angle from it
    to the bone's own engine +Z.

    Over all 130 shots at nine times each, the **median is exactly zero** and
    three quarters of the poses are within half a degree, so the bone is
    authored upright and the roll is not a hidden convention.  The tail is
    real and small: a few dozen poses carry a deliberate bank, and a handful
    look near enough to straight up or down that the projection is
    ill-conditioned.  The remake needs no decision either way -- it takes the
    bone's whole basis (``CAMERA_BASIS_FIX`` is the identity), so whatever
    roll is authored is what it draws.
    """
    rolls: list[float] = []
    for part in parts():
        base = video / part.directory
        for stem in part.stems:
            model = chamod.parse_model_file(str(base / part.model(stem)))
            anim = chamod.parse_animation_file(str(base / part.animation(stem)))
            if model.skeleton is None:
                continue
            cams = [n.name for n in model.skeleton.nodes
                    if n.name.startswith("Cam")]
            span = anim.duration or 1.0
            for k in range(9):
                posed = posemod.pose_model(model, anim, span * k / 8.0)
                for cam in cams:
                    m = posed.world.get(cam)
                    if m is None:
                        continue
                    roll = _roll_degrees(m)
                    if roll is not None:
                        rolls.append(roll)
    rolls.sort(key=abs)
    n = len(rolls)
    if not n:
        ck.check("camera.roll", False, "no camera poses")
        return
    median = sorted(rolls)[n // 2]
    within = sum(1 for r in rolls if abs(r) <= 0.5)
    tail = sum(1 for r in rolls if abs(r) <= 10.0)
    ck.check("camera.roll_median_is_zero", abs(median) < 1e-6,
             f"median roll {median:.3f} deg over {n} poses")
    ck.check("camera.roll_is_mostly_none", within * 100 >= n * 70,
             f"{within}/{n} poses within half a degree")
    ck.check("camera.roll_tail_is_small", tail * 100 >= n * 95,
             f"{tail}/{n} poses within ten degrees")


def _roll_degrees(m) -> float | None:
    """The signed roll of one posed bone, or None where it cannot be defined.

    The matrix is row-major, so the bone's own axes are its columns: engine +Y
    is the forward the corpus measured, engine +Z the bone's own up.
    """
    fwd = _unit((m[1], m[5], m[9]))
    own = _unit((m[2], m[6], m[10]))
    up = (0.0, 0.0, 1.0)
    along = sum(a * b for a, b in zip(up, fwd))
    flat = tuple(up[i] - along * fwd[i] for i in range(3))
    if math.sqrt(sum(c * c for c in flat)) < 1e-6:
        # Looking straight up or down: every roll is the same picture.
        return None
    flat = _unit(flat)
    cosine = max(-1.0, min(1.0, sum(a * b for a, b in zip(own, flat))))
    turn = (flat[1] * own[2] - flat[2] * own[1],
            flat[2] * own[0] - flat[0] * own[2],
            flat[0] * own[1] - flat[1] * own[0])
    sign = 1.0 if sum(a * b for a, b in zip(turn, fwd)) >= 0.0 else -1.0
    return sign * math.degrees(math.acos(cosine))


def _unit(v) -> tuple[float, float, float]:
    length = math.sqrt(sum(c * c for c in v)) or 1.0
    return (v[0] / length, v[1] / length, v[2] / length)


def check_notes(video: Path, ck: Checks) -> None:
    switches = focuses = ignored = breaks = 0
    unresolved: list[str] = []
    no_cam1: list[str] = []
    values: set[int] = set()
    for part in parts():
        base = video / part.directory
        for stem in part.stems:
            model = chamod.parse_model_file(str(base / part.model(stem)))
            anim = chamod.parse_animation_file(str(base / part.animation(stem)))
            names = ({n.name for n in model.skeleton.nodes}
                     if model.skeleton else set())
            if "Cam1" not in names:
                no_cam1.append(f"{part.directory}/{stem}")
            for note in anim.notes:
                for verb, value in parse_note_lines(note.text):
                    if verb == "Switch":
                        switches += 1
                        if f"Cam{value}" not in names:
                            unresolved.append(f"{part.directory}/{stem}: Cam{value}")
                    elif verb == "Focus":
                        focuses += 1
                        values.add(int(value))
                    elif verb == "BREAK":
                        breaks += 1
                    else:
                        ignored += 1
    ck.check("notes.switch_count", switches == 55, f"{switches} Switch notes")
    ck.check("notes.switch_resolves", not unresolved,
             f"Switch notes naming no Cam node: {unresolved[:5]}")
    ck.check("notes.cam1_everywhere", not no_cam1,
             f"models without Cam1: {no_cam1[:5]}")
    ck.check("notes.focus_values", values == set(FOCUS_CORPUS),
             f"Focus values {sorted(values)}")
    ck.check("notes.focus_count", focuses == 138, f"{focuses} Focus notes")
    ck.check("notes.other", (breaks, ignored) == (2, 2),
             f"{breaks} BREAK and {ignored} ignored lines (two German comments)")
    ck.check("notes.grammar",
             parse_note_lines("Focus 43..0\r\nSwitch 2\r\n")
             == [("Focus", 43.0), ("Switch", 2)]
             and parse_note_lines("Keys f\u00fcr Bewegung")
             == [("ignored", "Keys f\u00fcr Bewegung")],
             "the note grammar changed")



def check_credits_roll(pe: PEFile, roll: dict[str, Any], ck: Checks) -> None:
    """The credits' scrolling roll -- ``fcn.0044BD90``, read instruction by
    instruction.

    The roll is the half of the credits screen ``Menu_a.lcl`` does not carry:
    the block writes two buttons and the walk that puts 178 lines up the
    plate's dark side is in the executable alone.
    """
    ck.check("frontend.credits.roll.gate",
             pe.bytes_at(roll["window_gate"], len(roll["gate_bytes"]))
             == roll["gate_bytes"]
             and call_target(pe, roll["call_site"]) == roll["walk"],
             "the menu loop no longer runs the roll while window 15 is up")
    ck.check("frontend.credits.roll.start",
             pe.bytes_at(roll["start_store"], 10)
             == b"\xc7\x05" + struct.pack("<I", roll["position"])
             + struct.pack("<I", roll["start"]),
             f"the roll no longer starts at {roll['start']}")
    ck.check("frontend.credits.roll.step",
             pe.bytes_at(roll["step_site"], 6)
             == b"\xff\x0d" + struct.pack("<I", roll["position"]),
             "the roll no longer steps one unit a frame")
    ck.check("frontend.credits.roll.rate",
             pe.bytes_at(roll["fps_pushes"], 4)
             == bytes([0x6A, roll["fps"], 0x6A, roll["fps"]])
             and call_target(pe, roll["fps_call"]) == roll["rate_limiter"],
             f"the roll no longer asks for {roll['fps']} frames a second")
    clip = roll["clip"]
    ck.check("frontend.credits.roll.clip",
             pe.bytes_at(roll["clip_pushes"], 12)
             == b"\x68" + struct.pack("<I", clip[3])
             + b"\x68" + struct.pack("<I", clip[2]) + b"\x57\x57"
             and call_target(pe, roll["clip_call"]) == 0x00447B20,
             f"the roll's clip is no longer {clip}")
    ck.check("frontend.credits.roll.first_id",
             pe.bytes_at(roll["first_id_store"], 8)
             == b"\xc7\x44\x24\x20" + struct.pack("<I", roll["first_id"]),
             f"the walk no longer opens at string {roll['first_id']}")
    mark, mark_va = roll["terminator"]
    ck.check("frontend.credits.roll.terminator",
             pe.cstring(mark_va) == mark
             and pe.bytes_at(roll["terminator_load"], 5)
             == b"\xbe" + struct.pack("<I", mark_va),
             f"the walk no longer stops on {mark!r}")
    arms = tuple(pe.u32(roll["switch_table"] + 4 * i) for i in range(5))
    ck.check("frontend.credits.roll.switch", arms == roll["arms"],
             f"the five arms of the code digit changed: {arms}")
    ck.check("frontend.credits.roll.advance",
             pe.bytes_at(roll["advance_test"], 2) == b"\x3c\x32"
             and pe.bytes_at(roll["advance_test"] + 10,
                             len(roll["advance_bytes"]))
             == roll["advance_bytes"]
             and pe.bytes_at(roll["advance_test"] + 17, 3)
             == bytes([0x83, 0xC0, roll["advance_line"]]),
             f"a group end no longer steps {roll['advance_group']} and a line "
             f"{roll['advance_line']}")
    for name, (va, block) in roll["prints"].items():
        cx, ca = roll["colours"][name]
        ck.check(f"frontend.credits.roll.print.{name}",
                 pe.bytes_at(va, len(block)) == block
                 and struct.pack("<I", ca) in block
                 and struct.pack("<I", cx) in block
                 and struct.pack("<I", roll["text_x"]) in block
                 and block[-1] == roll["fonts"][name],
                 f"the {name} arm's font, colours or x changed")
    # The three arms share one tail: the font handle by index, then the print
    # itself.  Only the name arm falls into it; the other two jump.
    ck.check("frontend.credits.roll.print.tail",
             call_target(pe, roll["print_tail"]) == 0x00439E20
             and call_target(pe, roll["print_call"]) == roll["print"],
             "the roll no longer prints through aPrintLibText")
    ck.check("frontend.credits.roll.rules",
             all(call_target(pe, va) == roll["rule"]
                 for va in roll["rule_calls"])
             and pe.bytes_at(roll["rule_calls"][0] - 6, 5)
             == b"\x68" + struct.pack("<I", roll["rule_x"]),
             "the underlines no longer run left from x "
             f"{roll['rule_x']}")


def check_frontend(pe: PEFile, ck: Checks) -> None:
    """The strings, holds, gate and flag of the front end around the sequences."""
    fe = FRONTEND
    for name, (text, va, call_va) in fe["cd_programs"].items():
        ck.check(f"frontend.cd.{name}",
                 pe.cstring(va) == text
                 and call_target(pe, call_va) == CD_PROGRAM["parse"],
                 f"{name}: {pe.cstring(va)!r} at 0x{va:08X}, call at "
                 f"0x{call_va:08X}")
    for name, (ms, va) in fe["holds_ms"].items():
        ck.check(f"frontend.hold.{name}",
                 pe.bytes_at(va, 5) == b"\x68" + struct.pack("<I", ms)
                 and pe.bytes_at(va + 5, 2) == b"\xff\x15",
                 f"{name}: no push {ms} before a Sleep at 0x{va:08X}")
    splash = fe["splash"]
    ck.check("frontend.splash.strings",
             pe.cstring(splash["logo_bmp"][1]) == splash["logo_bmp"][0]
             and pe.cstring(splash["title_bmp"][1]) == splash["title_bmp"][0]
             and pe.cstring(splash["menu_a"][1]) == splash["menu_a"][0],
             "aGameIntro's bitmap or script names changed")
    ck.check("frontend.credits.flag",
             pe.bytes_at(fe["credits"]["flag_store"], 5)
             == b"\xa3" + struct.pack("<I", fe["credits"]["flag"]),
             "0x0044BC60 no longer writes the credits flag")
    check_credits_roll(pe, fe["credits"]["roll"], ck)
    ck.check("frontend.static_extro.continue",
             call_target(pe, fe["static_extro"]["continue_call"]) == 0x0044BC60
             and pe.bytes_at(0x0045BD86, 2) == b"\x6a\x01",
             "the slide show's Continue no longer raises the credits")
    ck.check("frontend.static_extro.wave",
             pe.cstring(0x004CA91C) == "%s" + fe["static_extro"]["wave"],
             "the extro wave path changed")
    msg = fe["message_screen"]
    ck.check("frontend.message.strings",
             pe.cstring(msg["bmp"][1]) == msg["bmp"][0]
             and pe.cstring(msg["font"][1]) == msg["font"][0],
             "aPrintMessageScreen's plate or font changed")
    ck.check("frontend.message.callers",
             all(call_target(pe, va) == 0x0045F290 for va in msg["callers"])
             and all(pe.bytes_at(va - 1, 1) == b"\x50" for va in msg["callers"]),
             "the two message-screen call sites moved")
    ck.check("frontend.message.text_zero",
             pe.bytes_at(0x0045D42B, 2) == b"\x6a\x00"
             and pe.bytes_at(0x00453F86, 2) == b"\x33\xdb",
             "the message screen's text id is no longer 0 at both callers")
    ck.check("frontend.message.layout",
             pe.bytes_at(0x0045F35C, 5) == b"\x68" + struct.pack("<I", 320)
             and pe.bytes_at(0x0045F35A, 2) == b"\x6a\x41"
             and pe.bytes_at(0x0045F353, 5) == b"\x68" + struct.pack("<I", 0xF79E),
             "the message screen's caption moved")
    cap = fe["sequence_caption"]
    ck.check("frontend.caption.install",
             pe.bytes_at(cap["install"], 5)
             == b"\x68" + struct.pack("<I", cap["callback"]),
             "the framed background callback is no longer installed")
    ck.check("frontend.caption.layout",
             pe.bytes_at(0x00456F8F, 5) == b"\x68" + struct.pack("<I", 320)
             and pe.bytes_at(0x00456F8A, 5) == b"\x68" + struct.pack("<I", 210)
             and pe.bytes_at(0x00456F94, 2) == b"\x6a\x00",
             "the framed caption's position or text id changed")
    gate = fe["gate"]
    ck.check("frontend.gate.bytes",
             pe.bytes_at(gate["bytes_at"], len(gate["bytes"])) == gate["bytes"],
             "0x00456FC0's mission-id arms changed")
    flag = fe["intro_flag"]
    ck.check("frontend.intro_flag.setter",
             pe.bytes_at(flag["setter"], 10)
             == b"\x8b\x44\x24\x04\xa3" + struct.pack("<I", flag["global"])
             + b"\xc3",
             "0x0045D3E0 is no longer the flag's setter")
    ck.check("frontend.intro_flag.set_once",
             pe.bytes_at(flag["set_one"], 2) == b"\x6a\x01"
             and call_target(pe, flag["set_one"] + 2) == flag["setter"]
             and all(pe.bytes_at(va, 2) == b"\x6a\x00"
                     and call_target(pe, va + 2) == flag["setter"]
                     for va in flag["set_zero"])
             and call_target(pe, flag["menu_init_call"]) == flag["setter"]
             and pe.bytes_at(flag["menu_init_call"] - 1, 1) == b"\x56",
             "the intro flag's writers moved")
    ck.check("frontend.intro_flag.read",
             pe.bytes_at(flag["read"], 5)
             == b"\xa1" + struct.pack("<I", flag["global"]),
             "the gate no longer reads the intro flag")
    ex = fe["exit"]
    ck.check("frontend.exit.extro",
             pe.bytes_at(ex["extro_compare"], 10)
             == b"\x81\x3d" + struct.pack("<I", gate["mission_id_global"])
             + struct.pack("<I", 0xFF),
             "the exit no longer tests mission id 255")
    ck.check("frontend.exit.sites",
             all(call_target(pe, va) == ex["entry"]
                 for va in (ex["click_site"], ex["key_site"])),
             "the GUI loop's two exit call sites moved")
    ck.check("frontend.exit.click",
             pe.bytes_at(0x004555E6, 5) == b"\x66\x81\xff\x01\x02",
             "the click arm no longer tests WM_LBUTTONDOWN")
    ck.check("frontend.windows",
             pe.bytes_at(0x004570EF, 5) == b"\xb8\x41\x00\x00\x00"
             and pe.bytes_at(0x004570F4, 5) == b"\xb9\x39\x00\x00\x00"
             and pe.bytes_at(0x004570F9, 5) == b"\xba\x06\x02\x00\x00"
             and pe.bytes_at(0x0045710F, 5) == b"\xbf\x32\x01\x00\x00"
             and pe.bytes_at(0x004570D2, 5) == b"\xba\x80\x02\x00\x00"
             and pe.bytes_at(0x004570E8, 5) == b"\xbf\xe0\x01\x00\x00",
             "the two viewports changed")
    br = fe["briefing"]
    ck.check("frontend.briefing.advance",
             pe.bytes_at(br["advance"], 6)
             == b"\x40\xa3" + struct.pack("<I", 0x0050B4D0)
             and pe.bytes_at(0x0043F0A4, 5)
             == b"\x3d" + struct.pack("<I", br["caps"][0])
             and pe.bytes_at(0x0043F0BB, 5)
             == b"\x3d" + struct.pack("<I", br["caps"][1]),
             "the typewriter's per-frame increment changed")
    # The map's B0 arm, the key it is reached by and the gate in front of it.
    dispatch, table = br["map_short_dispatch"]
    ck.check("frontend.briefing.map_short_action",
             pe.u32(dispatch) == table
             and pe.bytes_at(br["map_short_arm"], 5)
             == b"\xbe" + struct.pack("<I", br["map_short_action"]),
             "0x00451240's key table no longer carries mission control's 0xb")
    predicate, reader, flag = br["map_short_gate"]
    ck.check("frontend.briefing.map_short_gate",
             pe.bytes_at(predicate, 5)
             == b"\xe8" + struct.pack("<i", reader - predicate - 5)
             and pe.bytes_at(reader, 6) == b"\xa1" + struct.pack("<I", flag)
             + b"\xc3",
             "0x0043b1f0 is no longer the network predicate over 0x00509f08")
    # `0x0043b700` is a loop, not a getter: `cmp dword [edi], 1` over the slot
    # table, `inc ebx` on a match, bounded by `0x0043b310`'s player count.
    humans, slots, count = br["map_short_humans"]
    ck.check("frontend.briefing.map_short_humans",
             pe.bytes_at(humans + 0x10, 5)
             == b"\xbf" + struct.pack("<I", slots)
             and pe.bytes_at(humans + 0x15, 3) == b"\x83\x3f\x01"
             and pe.bytes_at(0x0043B310, 5)
             == b"\xa1" + struct.pack("<I", count),
             "0x0043b700 no longer counts the human players")
    ck.check("frontend.briefing.map_short_gate_is_one_human",
             pe.bytes_at(0x00453966, 3) == b"\x83\xf8\x01"
             and call_target(pe, 0x00453961) == humans,
             "the B0 gate no longer compares the human count with 1")
    # The other arm, and the two things the flag it sets can draw.  This is
    # what says the strength panel is unreachable with one human: the only
    # writer of the flag is the arm one human never takes.
    ck.check("frontend.briefing.start_flag_single_writer",
             pe.bytes_at(br["start_flag_setter"], 10)
             == b"\xc7\x05" + struct.pack("<I", br["start_flag"])
             + struct.pack("<I", 1)
             and pe.bytes_at(br["start_flag_reader"], 6)
             == b"\xa1" + struct.pack("<I", br["start_flag"]) + b"\xc3"
             and pe.bytes_at(br["start_flag_clear"], 10)
             == b"\xc7\x05" + struct.pack("<I", br["start_flag"])
             + struct.pack("<I", 0),
             "0x005106d4's writer, reader or clear moved")
    ck.check("frontend.briefing.strength_panel_is_the_other_arm",
             call_target(pe, br["strength_panel_site"]) == br["strength_panel"]
             and call_target(pe, 0x0041B606) == 0x0043B1F0
             and pe.bytes_at(0x0041B60B, 4) == b"\x85\xc0\x74\x55",
             "0x0041a980's flag arm no longer branches on the network "
             "predicate into 0x0045fa00")
    ck.check("frontend.briefing.blip",
             pe.cstring(br["blip"][1]) == br["blip"][0]
             and pe.bytes_at(0x0043BFC4, 5)
             == b"\x68" + struct.pack("<I", br["blip"][1]),
             "the word blip is no longer textbeep.wav")
    ck.check("frontend.briefing.voice",
             pe.cstring(br["voice_format_va"]) == br["voice_format"],
             f"voice-over format is {pe.cstring(br['voice_format_va'])!r}")
    # Where `0x0044eeda` actually lives: `Menu_a` window 10, gadget 22.
    ck.check("frontend.briefing.menu_selector_is_menu_a",
             pe.cstring(pe.u32(br["menu_a_name_site"] + 1))
             == br["menu_a_name"]
             and pe.bytes_at(br["menu_a_main_menu_site"], 10)
             == b"\xc7\x05" + struct.pack("<I", br["menu_window"])
             + struct.pack("<I", br["menu_a_main_menu"]),
             "0x50fdf8's writer no longer follows the Menu_a load, so the "
             "window numbering below is not pinned to Menu_a")
    ck.check("frontend.briefing.menu_dispatch_switches_on_the_window",
             pe.bytes_at(br["menu_dispatch"], 5)
             == b"\xa1" + struct.pack("<I", br["menu_window"])
             and pe.bytes_at(br["menu_window_bound_site"], 3)
             == b"\x83\xf8" + bytes([br["menu_window_count"] - 1])
             and pe.bytes_at(br["menu_dispatch"] + 0x18, 3) == b"\xff\x24\x85"
             and pe.u32(br["menu_dispatch"] + 0x1B)
             == br["menu_window_table"],
             "aMenuSystem's dispatcher no longer switches on Menu_a's window")
    ck.check("frontend.briefing.level_options_is_window_ten",
             pe.u32(br["menu_window_table"]
                    + 4 * br["level_options_window"])
             == br["level_options_arm"]
             and pe.bytes_at(br["level_options_gadget_bound_site"], 3)
             == b"\x83\xff" + bytes([br["level_options_gadget_max"]])
             and pe.bytes_at(br["level_options_arm"] + 0x18, 3)
             == b"\xff\x24\x85"
             and pe.u32(br["level_options_arm"] + 0x1B)
             == br["level_options_jump_table"],
             "window 10's arm or its gadget switch moved")
    ck.check("frontend.briefing.the_infos_gadget_draws_b0",
             pe.u32(br["level_options_jump_table"] + 4 * pe.u8(
                 br["level_options_index_table"]
                 + br["level_options_infos_gadget"]))
             == br["level_options_infos_arm"]
             and call_target(pe, br["level_options_short"][2])
             == br["activate"],
             "gadget 22 no longer reaches 0x0044eebd's B0 activation")
    ck.check("frontend.briefing.the_briefing_screen_is_menu_b",
             pe.cstring(pe.u32(br["menu_b_name_site"] + 1))
             == br["menu_b_name"]
             and br["menu_b_name_site"] < br["tips"][2] < br["screen"][2],
             "the routine that draws A0 and C0 no longer loads Menu_b.LCL "
             "ahead of them")
    sites = tuple(sorted(activate_sites(pe, br["activate"])))
    ck.check("frontend.briefing.activate_sites",
             sites == tuple(sorted(br["activate_sites"])),
             f"aActivateBriefingInfo is called from {len(sites)} sites: "
             + ", ".join(f"0x{va:08X}" for va in sites))
    inside = tuple(va for va in sites
                   if br["menu_dispatch"] <= va < br["menu_window_table"])
    ck.check("frontend.briefing.only_one_site_is_in_the_menu_system",
             inside == (br["level_options_short"][2],),
             "the deployment screen is a Menu_b window and the dispatcher "
             "reaches aActivateBriefingInfo from the Infos gadget alone; "
             f"sites inside it: {[hex(v) for v in inside]}")
    ck.check("frontend.briefing.map_b0",
             pe.bytes_at(0x00453974, 4) == b"\x6a\x30\x6a\x42"
             and pe.bytes_at(0x00453978, 1) == b"\x50"
             and pe.bytes_at(0x00453970, 4) == b"\x85\xc0\x75\x4d"
             and call_target(pe, br["map_short"][2]) == 0x0043EAB0,
             "the map's B0 call changed (animate is eax, which is zero there)")
    for name, (_label, box, va) in ((k, v) for k, v in br.items()
                                    if isinstance(v, tuple) and len(v) == 3
                                    and isinstance(v[1], tuple)):
        ck.check(f"frontend.briefing.{name}",
                 call_target(pe, va) == 0x0043EAB0,
                 f"0x{va:08X} no longer calls aActivateBriefingInfo")


def frontend_document(pe: PEFile | None = None) -> dict[str, Any]:
    """``tables/frontend.json`` -- what the remake's shell needs of FRONTEND."""
    fe = FRONTEND
    windows = fe["windows"]
    return {
        "schema": "incubation.frontend/1",
        "holds_ms": {k: v[0] for k, v in fe["holds_ms"].items()},
        "cd_programs": {k: v[0] for k, v in fe["cd_programs"].items()},
        "cd_separators": CD_SEPARATORS,
        "splash": {
            "logo_plate": "bluebyte", "title_plate": "title",
            "text": list(fe["splash"]["text"]),
            "at": list(fe["splash"]["at"]), "size": list(fe["splash"]["size"]),
            "font": fe["splash"]["font"],
        },
        "credits": {
            "plate": fe["credits"]["plate"],
            "exit": {"text": list(fe["credits"]["exit"][:2]),
                     "at": list(fe["credits"]["exit"][2])},
            "back": {"text": list(fe["credits"]["back"][:2]),
                     "at": list(fe["credits"]["back"][2])},
        },
        "static_extro": {
            "plate": fe["static_extro"]["plate"],
            "wave": "audio/briefing/" + fe["static_extro"]["wave"],
            "continue": {"text": list(fe["static_extro"]["continue"][:2]),
                         "at": list(fe["static_extro"]["continue"][2])},
        },
        "message_screen": {
            "plate": fe["message_screen"]["plate"],
            "font": "font_2",
            "text": list(fe["message_screen"]["text"]),
            "at": list(fe["message_screen"]["at"]),
            "colours": list(fe["message_screen"]["colours"]),
        },
        "sequence_caption": {
            "text": list(fe["sequence_caption"]["text"]),
            "at": list(fe["sequence_caption"]["at"]),
            "colours": list(fe["sequence_caption"]["colours"]),
        },
        "gate": {
            "intro": {"mission_id": fe["gate"]["ids"]["intro"],
                      "logical_id": fe["gate"]["logical"]["intro"],
                      "full_screen": True, "once": True},
            "static_extro": {"mission_id": fe["gate"]["ids"]["static_extro"]},
            "animated_extro": {
                "mission_id": fe["gate"]["ids"]["animated_extro"],
                "logical_id": fe["gate"]["logical"]["animated_extro"],
                "full_screen": True},
        },
        "windows": {"full": list(windows["full"]),
                    "framed": list(windows["framed"])},
        "briefing": {
            "boxes": {name: {"label": v[0], "box": list(v[1])}
                      for name, v in fe["briefing"].items()
                      if isinstance(v, tuple) and len(v) == 3
                      and isinstance(v[1], tuple)},
            "typewriter": {"per_frame": fe["briefing"]["per_frame"],
                           "caps": list(fe["briefing"]["caps"]),
                           "blip": fe["briefing"]["blip"][0]},
            # The key mission control's B0 arm is reached by, and the fact
            # that its gate is satisfied by every single-player campaign.
            "map_short_key": fe["briefing"]["map_short_key"],
            "map_short_always_in_single_player": True,
            "voice_dir": "audio/briefing",
        },
    }

# ---------------------------------------------------------------------------
# The manifest the converter writes
# ---------------------------------------------------------------------------

def manifest_document(pe: PEFile) -> dict[str, Any]:
    """``tables/sequences.json`` -- logical id -> parts, plus the camera rules.

    The Focus table is **always** read out of the image.  There used to be a
    fallback to :data:`FOCUS_CORPUS` for a ``None`` image, with a docstring
    saying the two agreed and that ``--check`` said so; neither was true --
    the corpus constant is the five values the shipped clips ask for, not the
    seven presets and the default -- and no caller passed ``None``.  A
    documented claim with no check behind it is the shape this project keeps
    finding, so the branch is gone rather than checked.
    """
    table = focus_table(pe)
    sequences = []
    for logical_id, chain in SEQUENCES.items():
        sequences.append({
            "id": logical_id,
            "parts": [{
                "directory": part.directory,
                "stems": list(part.stems),
                "models": [part.model(stem)[:-4] for stem in part.stems],
                "animations": [part.animation(stem)[:-4] for stem in part.stems],
                "cd_program": part.cd_program,
                "cd_track": cd_track_of(part.cd_program),
            } for part in chain],
        })
    return {
        "schema": MANIFEST_SCHEMA,
        "frame_rate": FRAME_RATE,
        "cd_family": CD_FAMILY,
        "cd_separators": CD_SEPARATORS,
        "cd_terminator": CD_TERMINATOR,
        "camera": {
            "default_index": CAMERA["default_index"],
            # A ratio of two integers: the cache carries no float (docs/92).
            "focal_ratio": [10, 13],
            "focal_default_full": default_focal(640),
            "focal_default_framed": default_focal(518),
        },
        "focus": {
            "bias": FOCUS["bias"],
            "default": FOCUS["default"],
            "reference_height": FOCUS["reference_height"],
            # Records rather than a string-keyed object (docs/92 D12).
            "presets": [{"focus": f, "focal": table[f]}
                        for f in sorted(table) if table[f] != FOCUS["default"]],
        },
        "notes": ["BREAK", "Focus", "Switch", "Fade"],
        "sequences": sequences,
    }


def selected_files(video: Path) -> tuple[list[Path], list[Path]]:
    models: list[Path] = []
    animations: list[Path] = []
    for part in parts():
        base = video / part.directory
        models.extend(base / part.model(stem) for stem in part.stems)
        animations.extend(base / part.animation(stem) for stem in part.stems)
    return models, animations


def run_check(root: Path) -> int:
    ck = Checks()
    exe = root / "Incubation.exe"
    video = root / "Video"
    ck.check("corpus.exe", exe.is_file(), f"missing {exe}")
    ck.check("corpus.video", video.is_dir(), f"missing {video}")
    if not exe.is_file() or not video.is_dir():
        for failure in ck.failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1

    pe = PEFile(exe)
    ck.check("dispatch.ids", tuple(SEQUENCES) == EXPECTED_IDS,
             f"logical ids are {tuple(SEQUENCES)}")
    ck.check("dispatch.create_map",
             tuple(pe.bytes_at(0x0046588C, 16)) ==
             (0, 1, 2, 3, 7, 7, 7, 4, 7, 7, 7, 7, 7, 7, 5, 6),
             "aCreateSeqPlayer's compressed switch changed")
    ck.check("dispatch.part_map",
             pe.bytes_at(0x00467FC4, 16) == pe.bytes_at(0x0046588C, 16),
             "create and video-part switches no longer agree")
    ck.check("manifest.pe_strings",
             all(pe.cstring(va) == value for va, value in RESOURCE_STRINGS.items()),
             "one or more hard-coded resource roots changed")
    ck.check("cd.empty",
             pe.bytes_at(EMPTY_STRING_COMPARE, 5)
             == b"\xbe" + struct.pack("<I", EMPTY_STRING),
             "the tail no longer compares the program against the global Seq_5 loads")
    ck.check("cd.distinct",
             len({part.arm.cd_string for part in parts()}) == len(parts()),
             "two parts share one CD-program string address")
    check_arms(pe, ck)
    check_cd_program(pe, root, ck)
    check_camera(pe, ck)
    check_note_order(pe, ck)
    check_focus_table(pe, ck)
    check_frontend(pe, ck)
    ck.check("lifecycle.create", pe.bytes_at(0x0046546E, 20).startswith(
             b"\xc7\x05\x70\x42\x51\x00\x01\x00\x00\x00"),
             "active flag is not set at creation")
    ck.check("lifecycle.start", pe.bytes_at(0x00465BC0, 20).startswith(
             b"\xc7\x05\x74\x42\x51\x00\x01\x00\x00\x00"),
             "running flag is not set at start")
    ck.check("lifecycle.destroy",
             pe.bytes_at(0x00465C6F, 20).startswith(
                 b"\xc7\x05\x74\x42\x51\x00\x00\x00\x00\x00\xc7\x05\x70\x42\x51\x00"),
             "destroy no longer clears running then active")
    ck.check("lifecycle.advance", pe.bytes_at(0x00467E8F, 16).endswith(
             b"\x40\xa3\x80\x42\x51\x00"),
             "video-part counter is not incremented")
    ck.check("timing.tick", pe.u32(0x0046592C) == 0x00525588,
             "update no longer imports GetTickCount through the expected IAT slot")
    ck.check("timing.scale", pe.u32(0x0046596E) == 0x004B157C,
             "elapsed milliseconds no longer use the seconds scale constant")
    ck.check("audio.extro", pe.cstring(0x004CA91C) == "%sextro.wav",
             "the separate extro soundtrack path changed")

    dirs = {p.name for p in video.iterdir() if p.is_dir()}
    ck.check("corpus.directories", dirs == EXPECTED_DIRS,
             f"directories: {sorted(dirs)}")
    models, animations = selected_files(video)
    missing = [str(p.relative_to(root)) for p in models + animations if not p.is_file()]
    ck.check("manifest.files", not missing, f"missing selected files: {missing}")
    ck.check("manifest.actors", len(models) == 130 and len(animations) == 130,
             f"selected {len(models)} models and {len(animations)} animations")

    parsed = 0
    parse_errors: list[str] = []
    for path in animations:
        try:
            cha_parse.parse(str(path))
            parsed += 1
        except Exception as exc:  # parser supplies a path and byte offset
            parse_errors.append(f"{path}: {exc}")
    ck.check("manifest.parse", parsed == len(animations),
             f"parsed {parsed}/{len(animations)}; {parse_errors[:3]}")

    check_notes(video, ck)
    check_camera_roll(video, ck)

    selected = {p.resolve() for p in models + animations}
    all_scene = {p.resolve() for p in video.glob("*/*")
                 if p.suffix.lower() in {".cho", ".cha"}}
    video_real = video.resolve()
    ignored = sorted("Video/" + str(p.relative_to(video_real))
                     for p in all_scene - selected)
    ck.check("manifest.unselected",
             ignored == [
                 "Video/Dialog_16/Model_D16_01.cho",
                 "Video/Dialog_16/Model_D16_02.cho",
                 "Video/Dialog_16/Model_D16_03.cho",
                 "Video/Dialog_16/Model_D16_04.cho",
                 "Video/Dialog_16/Model_D16_05.cho",
                 "Video/Dialog_16/Model_D16_06.cho",
                 "Video/Dialog_16/Model_D16_07.cho",
                 "Video/Dialog_16/Model_D16_08.cho",
                 "Video/Dialog_16/Model_D16_09.cho",
                 "Video/Seq_3/Animaton_3_6.cha",
                 "Video/Seq_3/Animmation_3_18.cha",
             ], f"unselected files: {ignored}")

    if ck.failures:
        for failure in ck.failures:
            print(f"FAIL {failure}", file=sys.stderr)
        print(f"sequence player: {ck.total} checks, {len(ck.failures)} failed")
        return 1
    print(f"sequence player: {ck.total}/{ck.total} checks passed; "
          f"12/12 directories, {parsed}/{len(animations)} animations parsed")
    return 0


def report(root: Path, as_json: bool) -> int:
    video = root / "Video"
    out = []
    for logical_id, chain in SEQUENCES.items():
        out.append({
            "id": logical_id,
            "parts": [{
                "directory": part.directory,
                "cd_program": part.cd_program,
                "cd_track": cd_track_of(part.cd_program),
                "actors": list(part.stems),
            } for part in chain],
        })
    if as_json:
        print(json.dumps({"root": str(root), "sequences": out}, indent=2))
    else:
        for seq in out:
            print(f"id {seq['id']}")
            for index, part in enumerate(seq["parts"]):
                print(f"  part {index}: {part['directory']:<10} "
                      f"cd={part['cd_program'] or '-':<5} "
                      f"actors={len(part['actors'])}")
    return 0 if video.is_dir() else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", type=Path)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--manifest", action="store_true",
                    help="print tables/sequences.json and tables/frontend.json "
                         "as the converter writes them")
    args = ap.parse_args()
    if args.manifest:
        pe = PEFile(args.root / "Incubation.exe")
        print(json.dumps({"sequences": manifest_document(pe),
                          "frontend": frontend_document(pe)}, indent=2))
        return 0
    return run_check(args.root) if args.check else report(args.root, args.json)


if __name__ == "__main__":
    raise SystemExit(main())

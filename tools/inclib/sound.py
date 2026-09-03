#!/usr/bin/env python3
"""Executable model of the Incubation sound layer.

This is the behavioural counterpart of ``docs/28`` sections 1 to 5, in the
same relation to ``tools/blob_tables.py`` that ``inclib/pose.py`` has to
``charisma_tables.py``: **the tables tool owns the extraction, this module owns
the rules.**  Nothing here opens a file or reads the binary.  Everything that
came out of ``Incubation.exe`` -- the wave name and volume id of each of the
62 call sites, the per-site loop flag, the 103 ``SetVolumeCtrl`` percentages --
is handed in by the caller, so the two readings stay independent and a mutation
of one is not silently absorbed by the other.

What it does own:

* the attenuation formula and its four constants (section 1.3);
* the twenty-slot pool and its drop-on-full behaviour (section 1.1);
* which remake event owns which call sites, and which of those loop
  (sections 1.4 and 2);
* the case-insensitive wave resolution (section 2.2);
* the weapon's own fire sound and weapon 35's defect (sections 3 and 3.1);
* the two pain-voice cursors and the alien scream's unconditional fix
  (section 4.1, ``docs/92`` section 7.1);
* the eight footstep arms and unit type 24's defect (section 5).

The GDScript twin is ``godot/game/audio/``; ``tools/blob_tables.py --check``
compares this module against the extracted tables, and
``--emit-sound-cases`` writes the fixture the twin replays.

Static source: ``gog_incubation/Incubation.exe`` (SHA-256
``b07aa2478fbfaf252a585cff180d03b468d5141e0fdb5606bd09f0891024fcc9``).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Mapping, Optional, Sequence


class SoundError(Exception):
    """A request the original would have refused by name."""


# --------------------------------------------------------------------------
# 1.1  The pool
# --------------------------------------------------------------------------

#: ``aDirectSoundPlay``'s bound (``cmp eax, 0x13`` / ``jg``).  The loader will
#: hand out slot 20 and the play routine rejects it, so the twenty-first buffer
#: is allocated, filled, freed and never heard.  docs/28 section 1.1's own
#: advice is to size the pool at twenty, which makes the inaudible slot a
#: dropped sound instead of a silent one.
PLAY_SLOTS = 20
#: What the loader itself would hand out, kept for the check that the two
#: bounds really do differ by one.
LOADER_SLOTS = 21


# --------------------------------------------------------------------------
# 1.3  The volume-control table and the exact attenuation
# --------------------------------------------------------------------------

#: ``if (baseVolume < -2000) return -10000;``
BASE_VOLUME_FLOOR = -2000
SILENCE = -10000
#: ``attenuation = baseVolume + 20 * percent - 2000``
ATTENUATION_OFFSET = -2000
HUNDREDTHS_PER_PERCENT = 20
#: The result is clipped at 0 -- there is no boost, whatever the percentage.
ATTENUATION_CEILING = 0
#: ``-1`` means "no scaling": the base volume passes through unchanged.
NO_SCALING = -1
#: The setter and the scaler accept 0..120 (``cmp eax, 0x78`` / ``jg``); the
#: load path only 0..119 (the same compare, but ``jge``).  Reproduced because
#: it is the difference between a sound that plays and one that is refused.
SET_ID_MAX = 120
LOAD_ID_MAX = 119
#: ``SetVolumeCtrl`` defines 0..102 in the shipped ``Info.lcl``.
INFO_VOLUME_IDS = 103
#: DirectSound attenuation is in hundredths of a decibel; Godot wants decibels.
HUNDREDTHS_PER_DB = 100.0


def attenuation(base_volume: int, percent: int) -> int:
    """``0x00437480``: turn a base volume and a percentage into a DirectSound
    attenuation.  Verbatim, including the clip at zero that makes id 102's
    101 % do nothing."""
    if base_volume < BASE_VOLUME_FLOOR:
        return SILENCE
    value = base_volume + HUNDREDTHS_PER_PERCENT * percent + ATTENUATION_OFFSET
    return min(value, ATTENUATION_CEILING)


def load_id_valid(volume_id: int) -> bool:
    """The load path's bound: ``-1`` or 0..119."""
    return volume_id == NO_SCALING or 0 <= volume_id <= LOAD_ID_MAX


def set_id_valid(volume_id: int) -> bool:
    """The setter's and the scaler's bound: ``-1`` or 0..120."""
    return volume_id == NO_SCALING or 0 <= volume_id <= SET_ID_MAX


def scaled_volume(base_volume: int, volume_id: int,
                  table: Mapping[int, int]) -> int:
    """The volume a slot is loaded at.

    ``volume_id`` of ``-1`` passes *base_volume* through untouched; any other
    id selects a percentage from *table* and goes through :func:`attenuation`.
    An id outside the load path's bound, or one the table does not define, is
    the original's ``invalid volume ctrl id``.
    """
    if volume_id == NO_SCALING:
        return base_volume
    if not load_id_valid(volume_id):
        raise SoundError("invalid volume ctrl id %d" % volume_id)
    if volume_id not in table:
        raise SoundError("volume ctrl id %d is not defined" % volume_id)
    return attenuation(base_volume, table[volume_id])


def volume_db(hundredths: int) -> float:
    """The attenuation as Godot's ``volume_db``."""
    return hundredths / HUNDREDTHS_PER_DB


# --------------------------------------------------------------------------
# 1.2 / 1.4  The pool, and the load-play-kill idiom
# --------------------------------------------------------------------------

@dataclass
class Slot:
    """One ``aDSound.cpp`` buffer record, reduced to what behaviour needs."""

    in_use: bool = False
    path: str = ""
    volume: int = 0
    volume_id: int = NO_SCALING
    playing: bool = False
    looping: bool = False


class SoundPool:
    """Twenty buffers, allocated low-first, dropped when full.

    ``load`` walks 0..19 and returns ``-1`` when every slot is taken -- the
    original's twenty-first slot is handed out by the loader and refused by
    the play routine, so the audible result is the same and the pool is one
    record shorter.  A dropped sound is counted rather than raised: docs/28
    section 7.1's rule for blobs applies here too -- the effect is silently
    absent, and a remake that threw would be less faithful, not more.
    """

    def __init__(self, slots: int = PLAY_SLOTS) -> None:
        self.slots = [Slot() for _ in range(slots)]
        self.drops = 0

    def load(self, path: str, base_volume: int, volume_id: int,
             table: Mapping[int, int]) -> int:
        volume = scaled_volume(base_volume, volume_id, table)
        for index, slot in enumerate(self.slots):
            if slot.in_use:
                continue
            self.slots[index] = Slot(in_use=True, path=path, volume=volume,
                                     volume_id=volume_id)
            return index
        self.drops += 1
        return -1

    def play(self, slot: int, loop: bool) -> bool:
        """``aAnimationSoundPlay``; the second argument is ``DSBPLAY_LOOPING``."""
        if slot < 0 or slot >= len(self.slots) or not self.slots[slot].in_use:
            return False
        self.slots[slot].playing = True
        self.slots[slot].looping = loop
        return True

    def kill(self, slot: int) -> bool:
        """``aDirectSoundKillBuffer``; a killed slot is immediately reusable."""
        if slot < 0 or slot >= len(self.slots) or not self.slots[slot].in_use:
            return False
        self.slots[slot] = Slot()
        return True

    def live(self) -> list[int]:
        return [i for i, s in enumerate(self.slots) if s.in_use]

    def looping(self) -> list[int]:
        return [i for i, s in enumerate(self.slots) if s.in_use and s.looping]

    def kill_looping(self) -> int:
        """End every looping buffer -- what a skipped sequence owes section 1.4."""
        killed = self.looping()
        for slot in killed:
            self.kill(slot)
        return len(killed)


# --------------------------------------------------------------------------
# 2  The event -> wave table
# --------------------------------------------------------------------------

#: Remake event name -> the routine that owns its sounds.  The left column is
#: the name ``core`` already emits (``lcl_interpreter.gd``, ``execute_move.gd``,
#: ``ai_event.gd``) or the name this slice gives a combat outcome; the right
#: column is docs/28 section 2's owning routine, cross-read against docs/20
#: section 7.4's handler-to-routine mapping.
EVENT_ROUTINES: dict[str, int] = {
    "weapon_fire": 0x0040BD70,
    "impact": 0x0040BD70,
    "pain": 0x0040BD70,
    "throw_impact": 0x0040BD70,
    "footstep": 0x0040E640,
    "move_world": 0x0040F230,
    "overheat": 0x0040F420,
    "poison": 0x0040F8F0,
    "heal": 0x0040FBE0,
    "rotating_camera": 0x0040FF30,
    "skill": 0x00410190,
    "reaction_jam": 0x004104A0,
    "pickup": 0x00410780,
    "open_door": 0x00410A20,
    "bridge": 0x00410DA0,
    "open_tube": 0x00410F10,
    "open_plant_tube": 0x00411150,
    "open_front_door": 0x004112E0,
    "jump": 0x00411460,
    "roof_unit": 0x00411B00,
    "ground_unit": 0x00411FB0,
    "elevator": 0x004125D0,
    "platform": 0x00412A00,
    "fire_circle": 0x004131C0,
    "barrier": 0x00413560,
    "statue": 0x00413A40,
    "fixed_statue": 0x00414000,
    "move_objects": 0x00414360,
    "falling_spores": 0x00414550,
    "move_spores": 0x004147D0,
    "foot_bridge": 0x00414A70,
    "foot_bridge2": 0x00415110,
    "ground_fire": 0x004157B0,
    "crush_wall": 0x00415C70,
    "bomber": 0x00415E90,
    "para_bomb": 0x004160F0,
    "teleporter_effect": 0x00416470,
    "teleporter": 0x004164F0,
    "teleporter2": 0x0041658C,
    "warp": 0x00416840,
    "lever": 0x00416AD0,
    "destroy_entrypoint": 0x00416CF0,
    "destroy_mine": 0x00416DE0,
}

#: Remake event name -> its ``aAnimationCreateSoundBuffer`` sites, in address
#: order.  The union is exactly ``blob_tables.SOUND_SITES``; the partition is
#: this module's claim and ``blob_tables.py`` checks both halves.
EVENT_SITES: dict[str, tuple[int, ...]] = {
    "weapon_fire": (0x0040C7F8,),
    "impact": (0x0040C856, 0x0040C891, 0x0040C8C8),
    "pain": (0x0040CC15,),
    "throw_impact": (0x0040DBF1,),
    "footstep": (0x0040E871,),
    "move_world": (0x0040F267, 0x0040F2AD),
    "overheat": (0x0040F611, 0x0040F680, 0x0040F6EF),
    "poison": (0x0040FA08,),
    "heal": (0x0040FD39,),
    "rotating_camera": (0x00410016,),
    "skill": (0x004102FB,),
    "reaction_jam": (0x004105D1,),
    "pickup": (0x0041093C,),
    "open_door": (0x00410C91,),
    "bridge": (0x00410E55,),
    "open_tube": (0x00410FF5, 0x0041103B),
    "open_plant_tube": (0x0041122A,),
    "open_front_door": (0x004113B8,),
    "jump": (0x00411736, 0x004118AF, 0x00411986, 0x00411A0A, 0x00411A8E),
    "roof_unit": (0x00411C58, 0x00411CA8, 0x00411CF8),
    "ground_unit": (0x004121C6, 0x0041221A),
    "elevator": (0x004125FD, 0x00412643),
    "platform": (0x00412A30, 0x00412A76),
    "fire_circle": (0x00413201,),
    "barrier": (0x004137AD,),
    "statue": (0x00413A6D, 0x00413AB3),
    "fixed_statue": (0x0041402D,),
    "move_objects": (0x00414386,),
    "falling_spores": (0x0041460E,),
    "move_spores": (0x0041487F,),
    "foot_bridge": (0x00414AB0, 0x00414AE7),
    "foot_bridge2": (0x00415141,),
    "ground_fire": (0x004157EB, 0x00415837),
    "crush_wall": (0x00415D39,),
    "bomber": (0x00415EBE,),
    "para_bomb": (0x00416291,),
    "teleporter_effect": (0x0041648F,),
    "teleporter": (0x00416586,),
    "teleporter2": (0x004165C8,),
    "warp": (0x004168D4, 0x00416916),
    "lever": (0x00416C03,),
    "destroy_entrypoint": (0x00416D10,),
    "destroy_mine": (0x00416E00,),
}

#: The three sites whose wave name or volume id is built at run time, and so
#: cannot come out of the site table: the weapon's own fire sound (section 3),
#: the pain voice (section 4.1) and the footstep (section 5).
COMPUTED_SITES: dict[int, str] = {
    0x0040C7F8: "weapon_fire",
    0x0040CC15: "pain",
    0x0040E871: "footstep",
}

#: The load sites whose sequence plays ``DSBPLAY_LOOPING``.  Thirteen loads
#: reach the **nine** looping play sites of section 1.4, because several
#: routines load one of two alternative waves and then share one play call;
#: ``blob_tables.py`` derives the same set from ``PLAY_SITES`` and compares.
LOOPING_LOADS: tuple[int, ...] = (
    0x0040F267, 0x0040F2AD,            # MoveWorld
    0x00410C91,                        # aDoorOpenSequence
    0x00410E55,                        # Bridge
    0x004125FD, 0x00412643,            # aPlayElevatorSequence
    0x00412A30, 0x00412A76,            # aPlayPlatformSequence
    0x00413A6D, 0x00413AB3,            # aPlayRotateStatueSequence
    0x00414386,                        # the land mover
    0x00415EBE,                        # the bomber
    0x0041648F,                        # the teleporter effect
)
#: How many distinct play sites those loads reach (docs/28 section 1.4).
LOOPING_PLAY_SITES = 9


@dataclass(frozen=True)
class Cue:
    """One sound a remake event starts: a wave, an id to scale it by, and
    whether it loops for the length of its sequence."""

    wave: str
    volume_id: int
    loop: bool
    site: int


def catalogue(sites: Mapping[int, tuple[Optional[str], Optional[int]]]
              ) -> dict[str, tuple[Cue, ...]]:
    """Build the remake's event table from the extracted call sites.

    *sites* maps a load-site address to ``(wave name, volume id)``, with
    ``None`` for either where the original computes it.  The three computed
    sites are dropped: they have their own entry points
    (:func:`weapon_fire`, :meth:`VoiceCursors.pain`, :func:`footstep`).
    """
    out: dict[str, tuple[Cue, ...]] = {}
    for event, addresses in EVENT_SITES.items():
        cues: list[Cue] = []
        for address in addresses:
            if address in COMPUTED_SITES:
                continue
            wave, volume_id = sites[address]
            if wave is None or volume_id is None:
                raise SoundError("site 0x%08X has no wave or volume id"
                                 % address)
            cues.append(Cue(wave, volume_id, address in LOOPING_LOADS, address))
        if cues:
            out[event] = tuple(cues)
    return out


# --------------------------------------------------------------------------
# 2.2  Case
# --------------------------------------------------------------------------

def wave_index(shipped: Iterable[str]) -> dict[str, str]:
    """Lower-cased shipped name -> the shipped name.

    The original opens ``Waves\\<name>`` on a case-insensitive filesystem; ten
    of the fifty literal names do not match the shipped case, so a remake
    either resolves them once or fails on every filesystem but Windows.  The
    conversion resolves them once, which is why this returns a map rather than
    a search.
    """
    index: dict[str, str] = {}
    for name in shipped:
        index[name.lower()] = name
    return index


def resolve_wave(name: str, index: Mapping[str, str]) -> Optional[str]:
    """The shipped file *name* names, or ``None``."""
    return index.get(name.lower())


# --------------------------------------------------------------------------
# 3  The weapon's own fire sound
# --------------------------------------------------------------------------

#: ``wsprintf(buf, "%s.wav", &weaponTable[weapon].waveName)``.
WEAPON_WAVE_FORMAT = "%s.wav"
#: The weapon id **is** the volume-control id -- ``push edi`` at 0x0040C7D7.
#: That is what ``Info.lcl``'s "see weapons" comment on ids 0..49 means.
WEAPON_VOLUME_BAND = 50
#: ``SetWeaponInfo2 (35, "W_BAY0_0", ...)`` -- a zero for the letter O, into a
#: record no ``SetWeaponInfo`` ever created.  Reproduced by default.
WEAPON_MISSING_SOUND = 35
COMPAT_WEAPON_35 = "weapon_35_missing_sound"


def weapon_fire(weapon_id: int, wave_names: Mapping[int, str],
                index: Mapping[str, str], *,
                faithful: bool = True) -> Optional[Cue]:
    """The attacker's own fire sound, or ``None`` when it cannot load.

    With *faithful* set -- the default, and the ``Faithful`` preset -- weapon
    35's name is used as ``Info.lcl`` spells it and resolves to nothing, which
    is the shipped silence.  Without it, the name is corrected to the shipped
    file and the weapon is audible.
    """
    name = wave_names.get(weapon_id)
    if not name:
        return None
    wave = WEAPON_WAVE_FORMAT % name
    resolved = resolve_wave(wave, index)
    if resolved is None and weapon_id == WEAPON_MISSING_SOUND and not faithful:
        resolved = _corrected_weapon_wave(wave, index)
    if resolved is None:
        return None
    return Cue(resolved, weapon_id, False, 0x0040C7F8)


def _corrected_weapon_wave(wave: str,
                           index: Mapping[str, str]) -> Optional[str]:
    """Weapon 35's name with the digit read back as the letter it should be.

    The correction is spelled out rather than fuzzy-matched: the shipped file
    is ``W_BAYO_0.WAV`` and ``Info.lcl`` writes ``W_BAY0_0``.  One character.
    """
    return resolve_wave(wave.replace("0_0.wav", "O_0.wav"), index)


# --------------------------------------------------------------------------
# 4.1  The pain voice
# --------------------------------------------------------------------------

SPECIES_HUMAN = 0
SPECIES_ALIEN = 1

#: The three variants each species screams, in cursor order.
PAIN_WAVES: dict[int, tuple[str, str, str]] = {
    SPECIES_HUMAN: ("S_HUM_0.wav", "S_HUM_1.wav", "S_HUM_2.wav"),
    SPECIES_ALIEN: ("S_ALI_0.wav", "S_ALI_1.wav", "S_ALI_2.wav"),
}
#: What the combat path actually passes, for **both** species: the ids
#: ``Info.lcl`` labels ``S_HUM_0/1/2``.
PAIN_VOLUME_IDS = (56, 57, 58)
#: What the alien scream is scaled by after the unconditional correction: the
#: ids ``Info.lcl`` labels ``S_ALI_0/1/2``, which the shipped build reaches
#: only from the fall sequence.  docs/92 section 7.1's inert-control rule --
#: an "alien voices" slider that moves nothing is a bug in the remake's own
#: interface, whatever the original did.
ALIEN_PAIN_VOLUME_IDS = (59, 60, 61)
#: The second human set, which shares the human cursor.
SECOND_HUMAN_WAVES = ("SP_HUM_0.wav", "SP_HUM_1.wav", "SP_HUM_2.wav")
SECOND_HUMAN_VOLUME_IDS = (50, 51, 52)
#: The death scream (``docs/42`` §4.5): the same ``SP_HUM_0/1/2`` waves, off
#: the human cursor at 50..52 and off the **alien** cursor at 53..55 -- the
#: three ids ``Info.lcl`` labels ``SP_HUM`` a second time, which an earlier
#: reading called "named by no call site" because the fight loads them with
#: ``mov edi, imm`` (``0x0040CA23``, ``0x0040C9FD``, ``0x0040C9D7``) rather
#: than a ``push``.  A species-3 death is ``explosion.wav`` @63
#: (``0x0040C9A7``); species 2 dies silently.
DEATH_ALIEN_VOLUME_IDS = (53, 54, 55)
DEATH_EXPLOSION_WAVE = "explosion.wav"
DEATH_EXPLOSION_VOLUME_ID = 63
SPECIES_MACHINE = 3
#: Two independent cursors, one per species (0x004FC018 and 0x004FC01C).
PAIN_CURSOR_MODULUS = 3


class VoiceCursors:
    """The two round-robins of section 4.1.

    Each species advances its own cursor 0 -> 1 -> 2 -> 0 on every use, so the
    variants cycle rather than being drawn.  ``SP_HUM_*`` advances the *human*
    cursor, which is why the two sets interleave.
    """

    #: ``0x0040CBE2``..``0x0040CBEC`` -- ``cmp al, 0x16 / je``,
    #: ``cmp al, 0x18 / jbe``, ``cmp al, 0x1A / ja``: types 22, 25 and 26 make
    #: no sound when they are hit or killed.
    MUTE_TYPES = frozenset({0x16, 0x19, 0x1A})

    def __init__(self, *, fix_alien_volume: bool = True) -> None:
        self.cursors = {SPECIES_HUMAN: 0, SPECIES_ALIEN: 0}
        self.fix_alien_volume = fix_alien_volume

    def pain(self, species: int, type_id: int = -1) -> Optional[Cue]:
        """The scream a unit of *species* makes, or ``None``.

        Every species but human and alien is silent, and so are **unit types
        22, 25 and 26** -- ``0x0040CBDF`` reads ``+0x4C`` and clears the play
        flag for them (``docs/42`` §4.5).  All three have species 0, so the
        species test alone lets Cpt. Rutherford, the Scout and Major
        Rutherford scream where the engine says nothing.

        The cursor advances either way: the gate is at ``0x0040CBF2``, past
        the round robin that picked the wave.
        """
        waves = PAIN_WAVES.get(species)
        if waves is None:
            return None
        cursor = self.cursors[species]
        self.cursors[species] = (cursor + 1) % PAIN_CURSOR_MODULUS
        if type_id in self.MUTE_TYPES:
            return None
        ids = ALIEN_PAIN_VOLUME_IDS \
            if species == SPECIES_ALIEN and self.fix_alien_volume \
            else PAIN_VOLUME_IDS
        return Cue(waves[cursor], ids[cursor], False, 0x0040CC15)

    def second_human(self) -> Cue:
        """The ``SP_HUM_*`` set, off the human cursor."""
        cursor = self.cursors[SPECIES_HUMAN]
        self.cursors[SPECIES_HUMAN] = (cursor + 1) % PAIN_CURSOR_MODULUS
        return Cue(SECOND_HUMAN_WAVES[cursor], SECOND_HUMAN_VOLUME_IDS[cursor],
                   False, 0x00416916)

    def death(self, species: int, type_id: int = -1) -> Optional[Cue]:
        """The scream of a unit that died (``docs/42`` §4.5, severity 3).

        Humans and aliens scream ``SP_HUM_n`` off their own cursor -- the
        human at 50..52, the alien at 53..55 -- a machine explodes, and an
        object (species 2) makes no sound at all.

        **The mute of :attr:`MUTE_TYPES` covers this too**, and the machine's
        explosion with it: every arm of the cascade -- ``0x0040C9AC`` from the
        explosion, ``0x0040C9E6`` and its neighbours from the screams --
        ``jmp``\ s to ``0x0040CBD6``, and the type test at ``0x0040CBDB`` is
        the next thing after it.  The cursor advances either way, because the
        gate is past the round robin that picked the wave.
        """
        cue: Optional[Cue] = None
        if species == SPECIES_MACHINE:
            cue = Cue(DEATH_EXPLOSION_WAVE, DEATH_EXPLOSION_VOLUME_ID, False,
                      0x0040C99C)
        elif species in (SPECIES_HUMAN, SPECIES_ALIEN):
            cursor = self.cursors[species]
            self.cursors[species] = (cursor + 1) % PAIN_CURSOR_MODULUS
            ids = SECOND_HUMAN_VOLUME_IDS if species == SPECIES_HUMAN \
                else DEATH_ALIEN_VOLUME_IDS
            cue = Cue(SECOND_HUMAN_WAVES[cursor], ids[cursor], False,
                      0x0040CC15)
        if type_id in self.MUTE_TYPES:
            return None
        return cue


# --------------------------------------------------------------------------
# 5  Footsteps
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Footstep:
    """One arm of ``aStartWalkAnimationSound``'s 69-entry switch."""

    wave: str
    volume_id: int
    #: Frames between steps.  The ``msqueether`` arm writes no period.
    period: Optional[int]


#: The eight arms, keyed by the arm's own address so the pinning matches
#: ``blob_tables.WALK_ARMS``.  A unit type not named by any arm is silent.
FOOTSTEP_ARMS: dict[int, tuple[tuple[int, ...], Optional[Footstep]]] = {
    0x0040E683: ((0, 1, 2, 3, 4, 5, 6, 21, 22, 23, 25, 26),
                 Footstep("mhuman.wav", 62, 4)),
    0x0040E6CA: ((24,), Footstep("mdecther.wav", 45, 2)),
    0x0040E711: ((20,), Footstep("mcombot.wav", 90, 8)),
    0x0040E758: ((52, 65, 66), Footstep("mdecther.wav", 91, 2)),
    0x0040E79F: ((54,), Footstep("msqueether.wav", 93, None)),
    0x0040E7CC: ((59,), Footstep("malien.wav", 92, 7)),
    0x0040E810: ((50, 51, 53, 55, 56, 57, 58, 60, 64, 67, 68),
                 Footstep("malien.wav", 92, 5)),
    0x0040E8CC: ((7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
                  27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39,
                  40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 61, 62, 63), None),
}
#: The switch covers unit types 0..68.
FOOTSTEP_TYPES = 69
#: Unit type 24 walks at volume id **45** -- inside the 0..49 band that belongs
#: to weapon 45, one bit away from the 91 its twin uses.  Id 91 is 50 %, id 45
#: is 100 %, so that one type walks twice as loud.  Reproduced by default.
FOOTSTEP_STRAY_TYPE = 24
FOOTSTEP_STRAY_VOLUME_ID = 45
FOOTSTEP_FIXED_VOLUME_ID = 91
COMPAT_FOOTSTEP_24 = "unit_24_footstep_volume_original"

#: The step period is not a property of the walker -- it is **one global**, at
#: this address, that every arm but ``msqueether``'s overwrites with a ``mov
#: dword [0x004FAECC], imm32``.  Type 54's arm writes the wave and the volume id
#: and leaves the period alone, so a Squeether walks at whatever period the
#: previous walker set.
FOOTSTEP_PERIOD_GLOBAL = 0x004FAECC
#: And it starts at zero: the address lands past the end of ``.data``'s raw
#: bytes, in the tail the loader zero-fills, so a Squeether that walks before
#: anything else has walked has **no period at all**.  Reproduced.
FOOTSTEP_PERIOD_INITIAL = 0


class WalkPeriod:
    """The global above, as state.

    ``aStartWalkAnimationSound`` is not a pure function of the unit type, and
    modelling it as one would silently give type 54 a period it does not have.
    One of these per game; :meth:`start` is the call.
    """

    def __init__(self, frames: int = FOOTSTEP_PERIOD_INITIAL) -> None:
        self.frames = frames

    def start(self, unit_type: int, *,
              faithful: bool = True) -> Optional[Footstep]:
        """The walk sound for *unit_type*, with the period actually in force.

        ``None`` for the 39 silent types.  A returned period of 0 means the
        global has never been written: the sound is set up and never repeats.
        """
        step = footstep(unit_type, faithful=faithful)
        if step is None:
            return None
        if step.period is not None:
            self.frames = step.period
        return Footstep(step.wave, step.volume_id, self.frames)

_FOOTSTEP_BY_TYPE: dict[int, Optional[Footstep]] = {}
for _arm, (_types, _step) in FOOTSTEP_ARMS.items():
    for _type in _types:
        _FOOTSTEP_BY_TYPE[_type] = _step


def footstep(unit_type: int, *, faithful: bool = True) -> Optional[Footstep]:
    """The walking sound for *unit_type*, or ``None`` when it is silent."""
    step = _FOOTSTEP_BY_TYPE.get(unit_type)
    if step is None:
        return None
    if unit_type == FOOTSTEP_STRAY_TYPE and not faithful:
        return Footstep(step.wave, FOOTSTEP_FIXED_VOLUME_ID, step.period)
    return step


# --------------------------------------------------------------------------
# 2.3  The overheat trio, and 8.1's impact sound
# --------------------------------------------------------------------------

#: ``aPlayWeaponExplosionAnimation``'s three outcomes.  All four of its callers
#: are ``aCheckWeaponDamage``, so these are the three ways a weapon at its heat
#: cap can end -- not a generic explosion set.  ``explosion.wav`` is the one
#: that removes the carrier from the map; ``explosion2.wav`` is unrelated and
#: belongs to the throwers below.
OVERHEAT_CUES: dict[str, Cue] = {
    "jammed": Cue("jammed.wav", 64, False, 0x0040F680),
    "damaged": Cue("damage.wav", 65, False, 0x0040F611),
    "destroyed": Cue("explosion.wav", 63, False, 0x0040F6EF),
}

#: The third weapon switch's four outcomes (docs/28 section 8.1).  The wave a
#: weapon id selects is data -- ``blob_tables.WEAPON_IMPACT_SOUND`` -- and this
#: is only the set of possible answers, so the twin can name them.
IMPACT_CUES: dict[str, Cue] = {
    "ricochet": Cue("ricochet.wav", 80, False, 0x0040C856),
    "explosion2": Cue("explosion2.wav", 81, False, 0x0040C891),
    "aexplosion": Cue("aexplosion.wav", 95, False, 0x0040C8C8),
}


# --------------------------------------------------------------------------
# 2.1  The one direct site a remake needs
# --------------------------------------------------------------------------

#: Id 96 -- the one ``Info.lcl`` labels *gui-sounds*, and the only non ``-1``
#: id outside ``aAnimations.cpp``.  The rest of section 2.1 is speech, the
#: briefing voice-over and the loader, none of which this slice owns.
INTERFACE_VOLUME_ID = 96
INTERFACE_WAVES = ("click_1.wav", "click_2.wav", "click_5.wav",
                   "select.wav", "textbeep.wav")


# --------------------------------------------------------------------------
# 6  Ambience is a stub, and fourteen waves are dead
# --------------------------------------------------------------------------

#: Named by no string anywhere in the image; excluded from the conversion so
#: the cache carries no file the game cannot reach.  docs/28 section 6 proves
#: the ambience subsystem never plays anything.
DEAD_WAVES = (
    "amb_a_0.wav", "amb_a_1.wav", "amb_a_2.wav", "amb_a_3.wav", "amb_a_4.wav",
    "amb_b_0.wav", "amb_b_1.wav", "amb_b_2.wav", "amb_b_3.wav", "amb_b_4.wav",
    "bridge.wav", "splash.wav", "W_CHS_0.wav", "W_HSR_0.wav",
)


# --------------------------------------------------------------------------
# The closure a conversion has to copy
# --------------------------------------------------------------------------

def wanted_waves(sites: Mapping[int, tuple[Optional[str], Optional[int]]],
                 weapon_waves: Mapping[int, str],
                 index: Mapping[str, str],
                 *, interface: bool = True) -> tuple[list[str], list[str]]:
    """``(shipped names to copy, names that resolve to nothing)``.

    The closure is the tables' own: every literal wave of section 2, every
    weapon's own wave of section 3, the nine voice files, the five footstep
    files and -- unless *interface* is cleared -- the id-96 click set.  A name
    that does not resolve comes back in the second list rather than raising,
    because exactly one does and it is a recorded defect, not a corpus error.
    """
    wanted: set[str] = set()
    missing: list[str] = []

    def want(name: str) -> None:
        shipped = resolve_wave(name, index)
        if shipped is None:
            missing.append(name)
        else:
            wanted.add(shipped)

    for wave, _volume in sites.values():
        if wave is not None and not wave.startswith("%"):
            want(wave)
    for name in weapon_waves.values():
        want(WEAPON_WAVE_FORMAT % name)
    for waves in PAIN_WAVES.values():
        for name in waves:
            want(name)
    for name in SECOND_HUMAN_WAVES:
        want(name)
    for _types, step in FOOTSTEP_ARMS.values():
        if step is not None:
            want(step.wave)
    if interface:
        for name in INTERFACE_WAVES:
            want(name)
    return sorted(wanted), sorted(set(missing))


# --------------------------------------------------------------------------
# Music
# --------------------------------------------------------------------------

#: The GOG release ships the CD audio twice, as ``music/Track%02d.ogg`` (02-20)
#: and ``music/Arack%02d.ogg`` (02-14), and replaces the CD with an ogg-winmm
#: shim.  **The shipped build plays the ``Arack`` family**, and that is read out
#: of the import table rather than guessed: ``Incubation.exe``'s import
#: descriptor names :data:`MUSIC_SHIM` where the 1997 build named ``WINMM.dll``,
#: importing exactly :data:`MUSIC_SHIM_IMPORTS` -- the two MCI entry points the
#: CD player used and the seven mixer entry points the volume control used --
#: and that DLL is the shim built with ``Arack``.  ``sound.dll`` is the same
#: shim built with ``Track`` and **no import descriptor in the tree names it**.
#: ``blob_tables.py`` pins all of it; see ``docs/28`` 6.1.
MUSIC_FORMAT = "Arack%02d.ogg"

#: The DLL ``Incubation.exe`` imports the MCI and mixer entry points from.
MUSIC_SHIM = "audio.dll"
#: The same shim built with the other family, imported by nothing.
MUSIC_SHIM_UNUSED = "sound.dll"
#: The nine ``winmm`` entry points the import descriptor above carries.  Two
#: drive the CD (``docs/20`` 7.3's ``CDTrackProgram``); seven are the mixer the
#: options screen moves.
MUSIC_SHIM_IMPORTS = (
    "mciSendCommandA", "mciGetErrorStringA",
    "mixerClose", "mixerGetControlDetailsA", "mixerGetLineControlsA",
    "mixerGetLineInfoA", "mixerGetNumDevs", "mixerSetControlDetails",
    "mixerOpen",
)
#: The shim's own path format, as it appears verbatim in each DLL.  The
#: family name is the only difference between the two builds.
MUSIC_SHIM_STRINGS = {
    MUSIC_SHIM: "%s\\Arack%02d.ogg",
    MUSIC_SHIM_UNUSED: "%s\\Track%02d.ogg",
}
#: The family the shipped build does **not** play.
MUSIC_ALTERNATE_FORMAT = "Track%02d.ogg"


def playlist(program: str) -> list[int]:
    """``CDTrackProgram``'s argument is a dot-separated list of track numbers.

    ``"3.5.7.3.4.5"`` is six entries played in order, and the mission loops it.
    A malformed entry is dropped rather than raised: the string comes from
    shipped script data, and one unparsable number should cost one track.
    """
    tracks: list[int] = []
    for part in program.split("."):
        part = part.strip()
        if part.isdigit():
            tracks.append(int(part))
    return tracks


# --------------------------------------------------------------------------
# The compatibility flags this layer owns
# --------------------------------------------------------------------------

#: The two audible defects the ``Faithful`` preset reproduces.  They are
#: presentation only -- neither changes a rule -- so they are **not** put into
#: ``World.compat_flags``, which feeds the canonical hash of the simulation.
#: The names are docs/92 section 7.1's.
COMPAT_FLAGS = (COMPAT_WEAPON_35, COMPAT_FOOTSTEP_24)

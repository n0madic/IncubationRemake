"""``V100Part::Update`` as a library: a track, a bone, a matrix.

This is the executable model of ``docs/40`` §5.2 and §6 -- the rule that turns
a ``.cha``'s keys and a ``.cho``'s bind pose into the world transform of every
bone at one point in time.  It was written inside ``tools/cho_export.py``,
where it produced the contact sheets that proved the decoded transform chain;
it lives here because the remake needs a **Python twin** to diff its GDScript
sampler against, and a model that only exists inside an exporter cannot be
that twin.

The rule, transcribed from ``V100Part::Update`` (``0x004a6807``)::

    translation = position_track(t) if bound else (0, 0, 0)
    if the bone's .cho parent is not "ROOT":
        translation += bind_matrix.translation      # 0x004828ff ADDS
    else:
        translation = translation * model_scale + animation_offset
    local = quat_to_matrix(rotation_track(t)) if bound
            else bind_matrix with its translation column zeroed
    local.translation = translation
    world = parent.world * local                    # 0x00482ab3, M * v

Three things here are easy to get wrong and are wrong silently:

* the **rotation channel replaces** the bind rotation rather than composing
  with it, and the bind translation is stripped before the track's is applied;
* for an ordinary bone the **position channel is a delta** added to the bind
  translation -- over the corpus' 1 153 position tracks the first key is below
  1e-3 in 80.3 % of them, while ``firstKey - bindTranslation`` is never near
  zero;
* for the model's **top-level bone** -- the one and only bone whose ``.cho``
  parent string is the ``ROOT`` sentinel -- the position channel is absolute
  and the bind translation is not added at all (``docs/40`` §6.2).

The structures are described by protocols rather than imported: the ``.cho``
and ``.cha`` dataclasses live in the sibling CLIs ``tools/cho_parse.py`` and
``tools/cha_parse.py``, and ``inclib`` does not import upwards.
"""

from __future__ import annotations

import bisect
from typing import Iterable, Protocol, Sequence, runtime_checkable

from .charisma import (
    HOLD_DT,
    HOLD_PICK,
    Mat4,
    bezier_rotation_controls,
    bezier_scalar,
    mat_mul,
    mat_translation,
    mat_with_translation,
    quat_slerp,
    quat_squad,
    quat_to_matrix,
)

#: The engine treats a key interval of ``HOLD_DT`` frames or less as a hold and
#: returns one of the two keys outright; ``u <= HOLD_PICK`` picks the first.
#: Both constants are shared by all five ``GetValue`` implementations.  5.2 % of
#: the corpus' 896 443 segments are exactly 0.25 frames long, so the threshold
#: is not academic -- dropping it changes one interval in twenty.
EPS = HOLD_DT

#: ``StdModel``'s per-instance placement, read through its ``"StandardModel"``
#: interface (``0x0049fc2d`` GetFlag / ``0x0049fc6a`` GetScale).  The
#: constructor at ``0x0049ed2c`` leaves the flag 0 and the scale ``(1, 1, 1)``,
#: and the owning animation's offset (``0x0049c5ac``) is likewise zero.  Nothing
#: in a shipped ``.cho`` or ``.cha`` can change either, so these are the values
#: the whole corpus runs with.
MODEL_SCALE: tuple[float, float, float] = (1.0, 1.0, 1.0)
ANIM_OFFSET: tuple[float, float, float] = (0.0, 0.0, 0.0)

#: ``docs/40`` §6.2 -- ``V100Model::ConstructModel`` (``0x004a7228``) allocates a
#: synthetic part called ``ROOT`` and adopts the file's own root bone.  No
#: ``.cho`` contains a part with this name, so a bone whose parent string is
#: this one *is* the model's top-level bone.
ROOT_SENTINEL = "ROOT"

#: The three channel names ``V100Part`` matches against (``0x004a6598``).
CHANNEL_POSITION = "Position"
CHANNEL_ROTATION = "Rotation matrix"
CHANNEL_VISIBILITY = "Visibility"


# ---------------------------------------------------------------------------
# What this module needs of the parsed structures
# ---------------------------------------------------------------------------

@runtime_checkable
class KeyLike(Protocol):
    """One keyframe: a time stamp plus 1..9 floats of channel data."""

    time: float
    values: tuple[float, ...]


@runtime_checkable
class MovementLike(Protocol):
    """One animated channel of one part."""

    key_class: str
    target: str
    channel: str
    keys: list


@runtime_checkable
class NodeLike(Protocol):
    """One ``SkeletonNode``: a name, its parent's name and a 4x4 bind matrix."""

    name: str
    parent: str
    matrix: Sequence[float]


# ---------------------------------------------------------------------------
# Track sampling - one function per interpolator, mirroring the engine
# ---------------------------------------------------------------------------

def segment(mov: MovementLike, t: float) -> tuple[int, KeyLike, KeyLike, float]:
    """Locate the key pair bracketing *t*, its index and the parameter u."""
    times = [k.time for k in mov.keys]
    i = bisect.bisect_right(times, t) - 1
    if i < 0:
        return 0, mov.keys[0], mov.keys[0], 0.0
    if i >= len(mov.keys) - 1:
        last = mov.keys[-1]
        return len(mov.keys) - 1, last, last, 1.0
    k0, k1 = mov.keys[i], mov.keys[i + 1]
    dt = k1.time - k0.time
    # The engine (0x004ac9c5 and friends) divides unconditionally and only
    # guards a zero numerator; the zero-length case cannot reach the caller
    # because the hold test below catches it first.
    u = 0.0 if dt == 0.0 else (t - k0.time) / dt
    return i, k0, k1, u


def squad_controls(mov: MovementLike) -> list[tuple[float, ...]]:
    """Control quaternions of a BezierRotation track, derived once per track."""
    cached = getattr(mov, "_squad_controls", None)
    if cached is None:
        cached = bezier_rotation_controls([k.values for k in mov.keys])
        mov._squad_controls = cached  # noqa: SLF001 - lazy per-track cache
    return cached


def sample_rotation(mov: MovementLike, t: float) -> Mat4:
    """Rotation channel -> 4x4 matrix (0x004a9a9a linear, 0x004aca7a Bezier).

    Linear rotation slerps the two keys.  Bezier rotation carries no tangents
    in the file: the engine derives one inner control quaternion per key at
    load time (0x004ad53e -> 0x004ad7ab -> 0x004af0d1, stored twice in the key
    at +0x18 and +0x28) and evaluates Shoemake's ``squad``
    ``(q[i], s[i], s[i+1], q[i+1], u)`` at 0x004aef75.
    """
    i, k0, k1, u = segment(mov, t)
    if k0 is k1 or k1.time - k0.time <= EPS:
        return quat_to_matrix(k0.values if u <= HOLD_PICK else k1.values)
    if mov.key_class == "BezierRotationKey":
        ctrl = squad_controls(mov)
        return quat_to_matrix(quat_squad(k0.values, ctrl[i], ctrl[i + 1],
                                         k1.values, u))
    return quat_to_matrix(quat_slerp(k0.values, k1.values, u))


def sample_vector(mov: MovementLike, t: float) -> tuple[float, float, float]:
    """Position channel -> vec3 (0x004a8b72 linear lerp, 0x004ab918 Bezier)."""
    _, k0, k1, u = segment(mov, t)
    if k0 is k1 or k1.time - k0.time <= EPS:
        v = k0.values if u <= HOLD_PICK else k1.values
        return (v[0], v[1], v[2])
    if mov.key_class == "LinearVectorKey":
        return tuple(k0.values[i] + (k1.values[i] - k0.values[i]) * u
                     for i in range(3))
    dt = k1.time - k0.time
    # BezierVectorKey: [0:3] value, [3:6] in-tangent, [6:9] out-tangent.
    return tuple(
        bezier_scalar(k0.values[i], k0.values[6 + i], k1.values[i],
                      k1.values[3 + i], dt, u)
        for i in range(3)
    )


def sample_float(mov: MovementLike, t: float) -> float:
    """Visibility channel -> scalar (0x004aa9df).  Visible when > 0."""
    _, k0, k1, u = segment(mov, t)
    if k0 is k1 or k1.time - k0.time <= EPS:
        return (k0.values if u <= HOLD_PICK else k1.values)[0]
    if mov.key_class == "LinearFloatKey":
        return k0.values[0] + (k1.values[0] - k0.values[0]) * u
    dt = k1.time - k0.time
    # BezierFloatKey: [0] value, [1] in-tangent, [2] out-tangent.
    return bezier_scalar(k0.values[0], k0.values[2], k1.values[0],
                         k1.values[1], dt, u)


# ---------------------------------------------------------------------------
# Posing
# ---------------------------------------------------------------------------

class Pose:
    """World transforms of every bone of a model at one point in time."""

    def __init__(self, nodes: Iterable[NodeLike],
                 movements: Iterable[MovementLike] | None,
                 time: float) -> None:
        self.time = time
        self.nodes: list[NodeLike] = list(nodes)
        self.parent_of: dict[str, str] = {n.name: n.parent for n in self.nodes}
        tracks: dict[tuple[str, str], MovementLike] = {}
        for mov in movements or ():
            tracks[(mov.target, mov.channel)] = mov
        self.tracks = tracks
        self.local: dict[str, Mat4] = {}
        self.world: dict[str, Mat4] = {}
        self.visible: dict[str, bool] = {}
        for node in self.nodes:
            self.local[node.name] = self._local(node)
        for node in self.nodes:
            self.world[node.name] = self._world(node.name)

    def is_top_level(self, name: str) -> bool:
        """Whether *name* is the one bone whose ``.cho`` parent is ``ROOT``.

        Written as "my parent is not itself a bone in this file", which is what
        ``V100Part::Update`` actually tests (``0x004a68d1``, "my parent has no
        parent") once the synthetic ``ROOT`` part is accounted for.
        """
        return self.parent_of.get(name) not in self.parent_of

    def _local(self, node: NodeLike) -> Mat4:
        """One bone's local matrix, exactly as V100Part::Update builds it."""
        bind_t = mat_translation(node.matrix)
        pos = self.tracks.get((node.name, CHANNEL_POSITION))
        if pos is not None and pos.keys:
            v = sample_vector(pos, self.time)
            if not self.is_top_level(node.name):
                # Ordinary bone: the track is an offset from the bind pose
                # (0x004a68ff, ADDS).
                trans = (bind_t[0] + v[0], bind_t[1] + v[1], bind_t[2] + v[2])
            else:
                # Top-level bone: V100Part::Update takes the second branch at
                # 0x004a68d1.  The bind translation is NOT added; the track
                # value is scaled by the model's own scale vector and offset by
                # the owning animation's offset vector.  Both default to
                # (1,1,1) / (0,0,0), so with stock data the track value is the
                # local translation outright.
                trans = (v[0] * MODEL_SCALE[0] + ANIM_OFFSET[0],
                         v[1] * MODEL_SCALE[1] + ANIM_OFFSET[1],
                         v[2] * MODEL_SCALE[2] + ANIM_OFFSET[2])
        else:
            trans = bind_t

        rot = self.tracks.get((node.name, CHANNEL_ROTATION))
        if rot is not None and rot.keys:
            local = sample_rotation(rot, self.time)
        else:
            local = mat_with_translation(node.matrix, (0.0, 0.0, 0.0))

        vis = self.tracks.get((node.name, CHANNEL_VISIBILITY))
        self.visible[node.name] = True if vis is None or not vis.keys \
            else sample_float(vis, self.time) > 0.0
        return mat_with_translation(local, trans)

    def _world(self, name: str) -> Mat4:
        if name in self.world:
            return self.world[name]
        parent = self.parent_of.get(name)
        if parent is None or parent not in self.local:
            out = list(self.local[name])
        else:
            out = mat_mul(self._world(parent), self.local[name])
        self.world[name] = out
        return out

    def is_visible(self, name: str) -> bool:
        """Whether the part's Visibility track is positive at this time.

        Parts whose track has gone to zero are switched off by the animation
        and must not be drawn. 272 of the Video sequences' tracks dip to <= 0,
        so on those models this is the difference between the pose the game
        shows and one with 18 extra limbs in it.
        """
        return self.visible.get(name, True)

    def joints(self, include_hidden: bool = False
               ) -> dict[str, tuple[float, float, float]]:
        return {n.name: mat_translation(self.world[n.name]) for n in self.nodes
                if include_hidden or self.is_visible(n.name)}

    def bones(self, include_hidden: bool = False) -> list[tuple[str, str]]:
        names = {n.name for n in self.nodes
                 if include_hidden or self.is_visible(n.name)}
        return [(n.parent, n.name) for n in self.nodes
                if n.name in names and n.parent in names]


def pose_model(model, animation, time: float) -> Pose:
    """Pose a parsed ``.cho`` with an optional parsed ``.cha``.

    The convenience shape callers actually want; :class:`Pose` itself takes the
    node and movement sequences so that nothing here depends on the CLI
    dataclasses.
    """
    if model.skeleton is None:
        raise ValueError(f"{getattr(model, 'path', model)} has no skeleton")
    movements = None if animation is None else animation.movements
    return Pose(model.skeleton.nodes, movements, time)

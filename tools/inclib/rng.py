"""The two random generators the engine draws from.

``docs/22`` §3 recovers ``aRandom`` (``0x00463870``), a Lehmer generator kept in
a ``double``; ``docs/20`` §7.4 records that it is **not** the one ``InsertUnit``
uses -- that one goes through the C library import at ``0x005255fc``.  Both live
here because a model that mixes them up produces plausible numbers that are
wrong, and because a generator is exactly the kind of thing that should have one
definition.  ``godot/core/rng.gd`` is the GDScript twin of :class:`ARandom` and
``godot/tests/test_rng.gd`` holds the 64-draw native capture both satisfy.
"""

from __future__ import annotations


class ARandom:
    """The shipped ``aRandom(base, span)`` Lehmer generator.

    A zero seed is intentionally a fixed point, matching the zero-initialised
    retail global -- but that state is **not** what a running game is in: the
    seed read out of a live ``Incubation.exe`` with a mission loaded is
    ``1.0``, so something sets it between start-up and play. The fixed point
    is therefore a property of the arithmetic to preserve, not the value to
    model a mission with.

    ``seed`` is a float because that is how the original keeps it (the global
    at ``0x00514078`` is a **qword**, read with ``fld`` and written with
    ``fst``); the integer conversion is the exact operation in its inner loop.

    Pinned natively: seeded ``1.0`` and drawn twice -- once per ``SetVarRandom``
    in ``_C_141``'s ``NextPlayer`` body -- the engine's global comes back
    holding ``847344462.0``, which this reproduces exactly.
    """

    #: **The generator serves two streams, not one.**  ``0x004638E0`` is this
    #: body byte for byte -- same multiplier, same modulus, same x87 sequence
    #: -- over the seed at ``0x00514070``, and without the call counter and
    #: running sum ``aRandom`` keeps at ``0x00514080`` / ``0x00514084``.  The
    #: uncounted one is the busier by a factor of eleven (372 call sites
    #: against 32) and is what ``aBlobs.cpp`` and the animation drivers draw
    #: from; the counted one is what the gameplay routines this project models
    #: draw from -- ``aAISystemControl``, ``aAttackUnit``,
    #: ``aCheckWeaponDamage``, ``aExecuteUse``, ``aComputeMissionObjectives``.
    #: So ``godot/core/rng.gd`` modelling the counted stream is right, and an
    #: effects port needs a **second instance** of this class rather than a
    #: second class.  ``blob_tables.py``'s ``random.*`` checks pin all of it,
    #: including the nineteen callers that cross the line.
    ENTRY_COUNTED = 0x00463870
    ENTRY_UNCOUNTED = 0x004638E0
    SEED_COUNTED = 0x00514078
    SEED_UNCOUNTED = 0x00514070
    CALL_COUNT_GLOBAL = 0x00514080
    CALL_SUM_GLOBAL = 0x00514084

    MULTIPLIER = 62089911.0
    MODULUS = 2147483647.0

    def __init__(self, seed: float = 0.0) -> None:
        self.seed = float(seed)
        self.calls = 0
        self.sum = 0

    def raw(self, base: int, span: int) -> float:
        """Return the x87 value produced by ``aRandom`` before ``__ftol``."""

        self.seed = float(int(self.seed * self.MULTIPLIER) % int(self.MODULUS)) \
            if self.seed else 0.0
        value = base + span * (self.seed / self.MODULUS)
        self.calls += 1
        self.sum += int(value)
        return value

    def __call__(self, base: int, span: int) -> int:
        return int(self.raw(base, span))


class CRandom:
    """The Microsoft C runtime ``rand()``, which ``InsertUnit`` draws from.

    ``docs/20`` §7.4: the spawn count comes from ``rand()`` at the import
    ``0x005255fc``, a different generator from :class:`ARandom` -- so a model
    that used the Lehmer one here would produce plausible counts that are
    wrong.  The recurrence is MSVC's documented one and the C standard's
    initial seed is 1.

    **Nothing seeds it** (``docs/94`` section 9 item 3): no shipped module
    imports ``srand`` or carries its name, so the CRT's per-thread state
    starts at 1 and every run draws the same sequence from there.  A caller
    that starts elsewhere -- a save, a test -- must say which seed it is
    assuming rather than inherit this default silently.
    """

    MULTIPLIER = 214013
    INCREMENT = 2531011
    MODULUS = 1 << 32
    RAND_MAX = 0x7FFF

    def __init__(self, seed: int = 1) -> None:
        self.seed = seed & (self.MODULUS - 1)
        self.calls = 0

    def __call__(self) -> int:
        self.seed = (self.seed * self.MULTIPLIER + self.INCREMENT) % self.MODULUS
        self.calls += 1
        return (self.seed >> 16) & self.RAND_MAX

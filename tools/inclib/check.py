"""A tiny result collector shared by the remake-pipeline ``--check`` CLIs.

The existing corpus tools each carry a private ``Checker`` of this shape.  The
tools added for the first vertical slice share one instead, because there are
four of them and they are written together.

The one rule that is not merely bookkeeping: :meth:`Checker.report` **fails when
no check ran**.  A mistyped game root must not come out green, which is the
property ``CLAUDE.md`` requires of every check in the always-run block.
"""

from __future__ import annotations

import logging
from typing import Any

LOG = logging.getLogger(__name__)


class Checker:
    """Collects ``(ok, name, detail)`` triples and prints them as ``N/N``."""

    def __init__(self) -> None:
        self.results: list[tuple[bool, str, str]] = []

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.results.append((bool(ok), name, detail))
        return bool(ok)

    def expect(self, name: str, got: Any, want: Any, detail: str = "") -> bool:
        ok = got == want
        text = detail
        if not ok:
            text = f"{_brief(got)} (expected {_brief(want)})"
            if detail:
                text = f"{detail}; {text}"
        elif not text:
            text = _brief(got)
        return self.check(name, ok, text)

    @property
    def failed(self) -> int:
        return sum(1 for ok, _, _ in self.results if not ok)

    def report(self, *, quiet_ok: bool = False) -> int:
        """Print every result and return the process exit code."""
        if not self.results:
            LOG.error("no checks ran -- an empty corpus is not a passing check")
            return 1
        for ok, name, detail in self.results:
            if ok and quiet_ok:
                continue
            print(f"  {'OK  ' if ok else 'FAIL'} {name:<34} {detail}")
        failed = self.failed
        print(f"{len(self.results) - failed}/{len(self.results)} checks passed")
        return 1 if failed else 0


def _brief(value: Any, limit: int = 160) -> str:
    text = repr(value)
    if len(text) > limit:
        return text[: limit - 3] + "..."
    return text

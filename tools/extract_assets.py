#!/usr/bin/env python3
"""Extract every viewable asset from a game installation in one run.

Runs the individual extractors in turn, each into its own subdirectory of the
output root:

    sprites    lib_extract.py    .LIB shape libraries -> PNG
    textures   visn_decode.py    VISN texture containers -> PNG
    lcl        lcl_decode.py     mission and menu scripts -> plain text
    maps       lev_parse.py      .lev missions -> PNG renders
    skeletons  cho_export.py     the documented Charisma samples, posed

The individual tools stay the place for anything finer-grained; this is the
"give me everything" entry point.  The game root is only read.

    python3 tools/extract_assets.py gog_incubation
    python3 tools/extract_assets.py gog_incubation -o /tmp/inc --only sprites,maps
"""

from __future__ import annotations

import argparse
import contextlib
import logging
import os
import sys
import time
from typing import Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cho_export  # noqa: E402
import lcl_decode  # noqa: E402
import lev_parse  # noqa: E402
import lib_extract  # noqa: E402
import visn_decode  # noqa: E402

LOG = logging.getLogger("extract_assets")

DEFAULT_OUT = os.path.join("tools", "out")

#: (name, tool entry point, argv builder over (game root, step output dir), quiet)
#: -- quiet steps print one line per written file on stdout, which is noise here.
Step = tuple[str, Callable[[list[str]], int], Callable[[str, str], list[str]], bool]
STEPS: tuple[Step, ...] = (
    ("sprites", lib_extract.main, lambda root, out: [root, "-o", out], False),
    ("textures", visn_decode.main, lambda root, out: [root, "-o", out], False),
    ("lcl", lcl_decode.main, lambda root, out: [root, "-o", out], False),
    ("maps", lev_parse.main, lambda root, out: [root, "--png", "-o", out], False),
    ("skeletons", cho_export.main, lambda root, out: ["--samples", root, "--out", out], True),
)
STEP_NAMES = tuple(step[0] for step in STEPS)


def _parse_only(value: str) -> list[str]:
    names = [name.strip() for name in value.split(",") if name.strip()]
    unknown = [name for name in names if name not in STEP_NAMES]
    if unknown or not names:
        raise argparse.ArgumentTypeError(
            f"unknown step(s) {', '.join(unknown) or '(none)'}; "
            f"choose from {', '.join(STEP_NAMES)}")
    return names


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("root", help="the game installation (read-only)")
    parser.add_argument("-o", "--outdir", default=DEFAULT_OUT,
                        help=f"output root (default: {DEFAULT_OUT})")
    parser.add_argument("--only", type=_parse_only, default=list(STEP_NAMES),
                        metavar="STEPS",
                        help=f"comma-separated subset of: {', '.join(STEP_NAMES)}")
    args = parser.parse_args(argv)

    # The steps configure logging themselves; the first basicConfig wins, so
    # this one fixes the format and level for the whole run.
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    if not os.path.isdir(args.root):
        LOG.error("game root %r is not a directory", args.root)
        return 1

    failed: list[str] = []
    for name, entry, build_argv, quiet in STEPS:
        if name not in args.only:
            continue
        out = os.path.join(args.outdir, name)
        LOG.info("[%s] -> %s", name, out)
        started = time.monotonic()
        with open(os.devnull, "w") as sink, \
                (contextlib.redirect_stdout(sink) if quiet else contextlib.nullcontext()):
            try:
                status = entry(build_argv(args.root, out))
            except SystemExit as exc:  # argparse errors inside a step
                status = exc.code if isinstance(exc.code, int) else 1
        LOG.info("[%s] %s in %.1f s", name, "done" if status == 0 else f"FAILED ({status})",
                 time.monotonic() - started)
        if status != 0:
            failed.append(name)

    if failed:
        LOG.error("failed steps: %s", ", ".join(failed))
        return 1
    LOG.info("all %d step(s) written under %s", len(args.only), args.outdir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

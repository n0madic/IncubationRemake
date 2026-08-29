#!/usr/bin/env python3
"""Decode/encode Incubation .lcl script files.

.lcl files hold plain ASCII LCL source. Most of them are obfuscated with a
bitwise NOT (equivalently XOR 0xFF); the transform is its own inverse, so one
code path handles both directions. Obfuscated files carry a leading 0x01 marker
byte in the decoded stream (stored as 0xFE on disk); a handful of files (all of
WorldDesc/*.lcl) ship as plain text with neither the marker nor the cipher.

`.gcl` files are the same language: `DATA/user.gcl` is a real script that the
game runs at startup and `DATA/Version.gcl` is a bare version string, both
stored as plain text.

Usage:
    lcl_decode.py <file-or-dir> [...] [-o OUTDIR] [--stdout] [--encode]
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib.lcl import decode, encode, is_encoded, iter_inputs  # noqa: E402

LOG = logging.getLogger("lcl")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("inputs", nargs="+", help="files or directories to process")
    parser.add_argument("-o", "--outdir", help="write decoded .txt files here")
    parser.add_argument("--stdout", action="store_true", help="print to stdout instead")
    parser.add_argument("--encode", action="store_true",
                        help="obfuscate plain source instead of decoding it")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    count = 0
    for path in iter_inputs(args.inputs):
        with open(path, "rb") as fh:
            data = fh.read()
        LOG.debug("%s: %s", path, "obfuscated" if is_encoded(data) else "plain text")
        out = encode(data) if args.encode else decode(data)
        if args.stdout or not args.outdir:
            sys.stdout.write(out.decode("cp1252", errors="replace"))
        else:
            suffix = ".lcl" if args.encode else ".txt"
            dest = os.path.join(args.outdir, os.path.basename(path) + suffix)
            os.makedirs(args.outdir, exist_ok=True)
            with open(dest, "wb") as fh:
                fh.write(out)
            LOG.debug("wrote %s", dest)
        count += 1
    LOG.info("processed %d file(s)", count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

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

LOG = logging.getLogger("lcl")

LCL_XOR_KEY = 0xFF
LCL_ENCODED_MARKER = 0x01
"""First byte of the decoded stream of an obfuscated .lcl file."""

_PRINTABLE = set(range(0x20, 0x7F)) | {0x09, 0x0A, 0x0D}


def transform(data: bytes) -> bytes:
    """Apply the LCL obfuscation. Self-inverse."""
    return bytes(b ^ LCL_XOR_KEY for b in data)


def is_encoded(data: bytes) -> bool:
    """True when the buffer looks like an obfuscated .lcl file.

    Obfuscated files begin with 0xFE (= marker 0x01 after the NOT). Plain files
    begin with printable ASCII. Fall back to a printable-ratio vote so unusual
    files are still classified sensibly.
    """
    if not data:
        return False
    if data[0] == LCL_XOR_KEY ^ LCL_ENCODED_MARKER:
        return True
    if data[0] in _PRINTABLE:
        return False
    head = data[:512]
    plain_score = sum(b in _PRINTABLE for b in head)
    xor_score = sum((b ^ LCL_XOR_KEY) in _PRINTABLE for b in head)
    return xor_score > plain_score


def decode(data: bytes) -> bytes:
    """Return the plain LCL source, stripping the 0x01 marker if present."""
    out = transform(data) if is_encoded(data) else data
    if out[:1] == bytes([LCL_ENCODED_MARKER]):
        out = out[1:]
    return out


def encode(text: bytes) -> bytes:
    """Obfuscate plain LCL source the way the shipped files are stored.

    The inverse of :func:`decode` for the obfuscated case: prepend the marker,
    then NOT the whole stream. ``decode(encode(x)) == x`` for any plain source.

    Note that :func:`transform` alone is **not** an inverse of :func:`decode`:
    ``decode`` also strips the marker byte, so a `transform(decode(x))` round
    trip loses it and turns an obfuscated file into one the loader would read
    as plain text. The module used to claim "Decode/encode" while offering no
    encoder at all, which is how that asymmetry went unnoticed.
    """
    return transform(bytes([LCL_ENCODED_MARKER]) + text)


#: Extensions the shipped scripts use. `.gcl` is the same language -- the two
#: `DATA/*.gcl` files are plain text rather than obfuscated, and `user.gcl` is a
#: real script that `main` runs at startup (`aMain.cpp:1002`, `0x0044A1CA`).
#: Walking only `.lcl` used to hide it, and with it the only shipped call to the
#: `?_` command.
SCRIPT_EXTENSIONS = (".lcl", ".gcl")


def iter_inputs(paths: list[str]):
    for path in paths:
        if os.path.isdir(path):
            for root, _dirs, files in os.walk(path):
                for name in sorted(files):
                    if name.lower().endswith(SCRIPT_EXTENSIONS):
                        yield os.path.join(root, name)
        else:
            yield path


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

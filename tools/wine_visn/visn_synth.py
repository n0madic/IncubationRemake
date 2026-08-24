#!/usr/bin/env python3
"""Synthesise VISN records, to probe parts of the format retail data never uses.

Blue Byte's encoder only ever emitted 256x256, quality 93, mode 2 pictures that
use escape widths 7..11. Several questions about the format therefore cannot be
answered from the shipped corpus at all:

* mode 0 (4:2:0) -- the Y sub-block layout and the chroma upsampling rule,
* escape widths 1..6 and 12, and the sign convention at each width.

This module writes minimal, well-formed records exercising exactly those paths,
so they can be fed to the game's own decoder through ``visn_harness.exe`` and
the answer read off the pixels rather than guessed.

It is a deliberately small encoder: enough syntax to build a legal bitstream,
not a competitive compressor.
"""

from __future__ import annotations

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from inclib.visn import (  # noqa: E402
    COEF_ESCAPE_FIRST,
    COEF_LITERAL_BIAS,
    MAX_CODE_LENGTH,
    META_CODE_LENGTHS,
    META_RUN_BITS,
    META_RUN_SYMBOL,
)

#: Every retail table declares this many symbols; the field itself is 12 bits.
SYMBOL_COUNT = 129


def canonical_codes(lengths: list[int]) -> dict[int, tuple[int, int]]:
    """Map symbol -> (code, length) with the decoder's canonical assignment.

    Codes are handed out in increasing symbol order within each length and the
    first code of length ``L+1`` is ``(first[L] + count[L]) << 1`` -- the exact
    inverse of :class:`inclib.visn.HuffmanTable`.
    """
    out: dict[int, tuple[int, int]] = {}
    code = 0
    for length in range(1, MAX_CODE_LENGTH + 1):
        for symbol, own in enumerate(lengths):
            if own == length:
                out[symbol] = (code, length)
                code += 1
        code <<= 1
    return out


META_CODES = canonical_codes(list(META_CODE_LENGTHS))


class BitWriter:
    """Collect bits MSB-first, then pack them into 16-bit little-endian words.

    The decoder pre-loads two whole words before consuming anything, so the
    stream is padded at the tail; without that the last real symbols would sit
    beyond the end of the record.
    """

    def __init__(self) -> None:
        self.bits: list[int] = []

    def write(self, value: int, count: int) -> None:
        for shift in range(count - 1, -1, -1):
            self.bits.append((value >> shift) & 1)

    def emit(self, code_length: tuple[int, int]) -> None:
        code, length = code_length
        self.write(code, length)

    def to_bytes(self, pad_words: int = 4) -> bytes:
        bits = list(self.bits)
        while len(bits) % 16:
            bits.append(0)
        words = []
        for i in range(0, len(bits), 16):
            word = 0
            for bit in bits[i:i + 16]:
                word = (word << 1) | bit
            words.append(word)
        words.extend([0] * pad_words)
        return struct.pack(f"<{len(words)}H", *words)


def write_table(bw: BitWriter, lengths: list[int]) -> None:
    """Emit one picture Huffman table as a 12-bit count plus meta-coded lengths."""
    if len(lengths) != SYMBOL_COUNT:
        raise ValueError(f"a picture table must declare {SYMBOL_COUNT} symbols")
    bw.write(len(lengths), 12)
    running = 0
    i = 0
    while i < len(lengths):
        if lengths[i] == 0:
            # Runs of unused symbols go through the 0x10 escape, which emits k
            # zero lengths and leaves `running` untouched. k is 5 bits, so long
            # runs are split into chunks of at most 31.
            j = i
            while j < len(lengths) and lengths[j] == 0:
                j += 1
            run = j - i
            while run:
                chunk = min(run, (1 << META_RUN_BITS) - 1)
                bw.emit(META_CODES[META_RUN_SYMBOL])
                bw.write(chunk, META_RUN_BITS)
                run -= chunk
            i = j
        else:
            bw.emit(META_CODES[(lengths[i] - running) & 0xF])
            running = lengths[i]
            i += 1


def empty_table_lengths() -> list[int]:
    """A table in which every symbol is unused -- legal, and present in retail."""
    return [0] * SYMBOL_COUNT


def table_lengths_for(symbols: dict[int, int]) -> list[int]:
    """Build a length vector giving each named symbol the requested code length."""
    lengths = [0] * SYMBOL_COUNT
    for symbol, length in symbols.items():
        lengths[symbol] = length
    return lengths


def literal_symbol(value: int) -> int:
    """The coefficient symbol carrying ``value`` directly, without extra bits."""
    symbol = value + COEF_LITERAL_BIAS
    if not 0 <= symbol < COEF_ESCAPE_FIRST:
        raise ValueError(f"{value} is outside the literal range")
    return symbol


def escape_symbol(bits: int) -> int:
    """The coefficient symbol introducing an ``bits``-wide signed escape."""
    if not 1 <= bits <= 12:
        raise ValueError("escape width must be 1..12")
    return COEF_ESCAPE_FIRST + bits - 1


class Block:
    """One 8x8 block: a raw DC plus a list of coefficients at scan positions 1..n.

    Each entry of ``ac`` is either ``("lit", value)`` or ``("esc", bits, value)``.
    """

    def __init__(self, dc: int, ac: list[tuple] | None = None) -> None:
        self.dc = dc
        self.ac = ac or []

    def write(self, bw: BitWriter, codes: dict[int, tuple[int, int]]) -> None:
        bw.write(len(self.ac), 6)
        bw.write((self.dc + 0x800) & 0xFFF, 12)
        for item in self.ac:
            if item[0] == "lit":
                bw.emit(codes[literal_symbol(item[1])])
            else:
                _, bits, value = item
                bw.emit(codes[escape_symbol(bits)])
                bw.write(value & ((1 << bits) - 1), bits)


def build_record(width: int, height: int, quality: int, mode: int,
                 chroma_lengths: list[int], luma_lengths: list[int],
                 blocks: list[Block]) -> bytes:
    """Assemble a complete VISN record from a flat list of blocks in stream order."""
    bw = BitWriter()
    write_table(bw, chroma_lengths)
    write_table(bw, luma_lengths)
    chroma_codes = canonical_codes(chroma_lengths)
    luma_codes = canonical_codes(luma_lengths)
    per_mb = 6 if mode == 0 else 3
    for i, block in enumerate(blocks):
        # Cb and Cr use table A, every Y block uses table B.
        in_mb = i % per_mb
        block.write(bw, chroma_codes if in_mb < 2 else luma_codes)
    header = b"VISN" + struct.pack("<HHBB", width, height, quality, mode)
    return header + bw.to_bytes()


def flat_dc(value: int) -> int:
    """The DC that makes an AC-free block decode to the constant sample ``value``.

    With no AC coefficients the inverse transform collapses to ``DC >> 3``.
    """
    return value * 8

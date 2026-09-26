"""VISN image codec — the texture format of Incubation (Blue Byte, 1997).

VISN is a JPEG-like still-image codec implemented in ``Eng3d.dll`` (original
source module ``SRC\\devision.asm``). It reuses the standard JPEG building
blocks — Annex K quantisation tables, the JPEG zigzag order, IJG's AAN scale
factors and the ``jpeg_idct_ifast`` transform — but replaces JPEG's entropy
layer and container with a much simpler custom design:

* a raw, unpredicted, unquantised 12-bit DC per block,
* an explicit AC count instead of run/size pairs and an EOB marker,
* two Huffman tables transmitted per picture (chroma first, then luma),
* a bitstream made of 16-bit little-endian words consumed MSB-first,
* a table-driven YCbCr -> RGB565 colour stage.

Format reference
----------------
The specification this module implements was published by the
``Incubation-HD-Renderer`` project (MIT licence)::

    https://github.com/Sonatix/Incubation-HD-Renderer  (VISN-FORMAT.md)

No code was copied from that project; this is an independent implementation
written from the prose specification. Every constant table below was
re-extracted directly from the shipped ``Eng3d.dll`` (GOG release, 666 507
bytes, MD5 ``2bb3bc9fb8b766837779dd1faf09fe8d``) at the offsets named in the
comments, so the tables are first-hand data rather than transcriptions.

See ``docs/50-visn-textures.md`` for the verified specification and for the
list of claims that remain unverified here.
"""

from __future__ import annotations

import logging
import struct
from dataclasses import dataclass
from typing import Sequence

from .binio import open_reader

LOG = logging.getLogger(__name__)

MAGIC = b"VISN"
HEADER_SIZE = 10

#: Mode byte 0: 4:2:0, 16x16 macroblocks carrying 6 blocks (Cb, Cr, Y0..Y3).
MODE_420 = 0
#: Mode byte 2: 4:4:4, 8x8 macroblocks carrying 3 blocks (Cb, Cr, Y).
MODE_444 = 2


class VisnError(Exception):
    """Raised when a VISN record does not match the documented layout."""


# ---------------------------------------------------------------------------
# Constant tables, read verbatim out of Eng3d.dll
# ---------------------------------------------------------------------------

#: Eng3d.dll @ 0x19dac. ``ZIGZAG[raster_index] = scan_index`` (JPEG zigzag).
ZIGZAG: tuple[int, ...] = (
    0, 1, 5, 6, 14, 15, 27, 28,
    2, 4, 7, 13, 16, 26, 29, 42,
    3, 8, 12, 17, 25, 30, 41, 43,
    9, 11, 18, 24, 31, 40, 44, 53,
    10, 19, 23, 32, 39, 45, 52, 54,
    20, 22, 33, 38, 46, 51, 55, 60,
    21, 34, 37, 47, 50, 56, 59, 61,
    35, 36, 48, 49, 57, 58, 62, 63,
)

#: Eng3d.dll @ 0x19dec. ``NATURAL_ORDER[scan_index] = raster_index``; the exact
#: inverse of :data:`ZIGZAG`, and identical to IJG's ``jpeg_natural_order``.
NATURAL_ORDER: tuple[int, ...] = (
    0, 1, 8, 16, 9, 2, 3, 10,
    17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
)

#: Eng3d.dll @ 0x19e30. Standard JPEG Annex K luminance table, raster order.
QUANT_BASE_LUMA: tuple[int, ...] = (
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
)

#: Eng3d.dll @ 0x19e70. Standard JPEG Annex K chrominance table, raster order.
QUANT_BASE_CHROMA: tuple[int, ...] = (
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
)

#: Eng3d.dll @ 0x19eb0, 64 x u32, raster order. IJG's ``jpeg_aanscales``,
#: i.e. ``round(S[u] * S[v] / 16384)`` for
#: ``S = (16384, 22725, 21407, 19266, 16384, 12873, 8867, 4520)``.
#:
#: NOTE THE LAST ENTRY. IJG's table ends in **1247**; Blue Byte's shipped copy
#: holds **124** — a dropped digit. It is reproduced here verbatim on purpose:
#: "fixing" it would change the highest-frequency coefficient of every block and
#: no longer match the game. See docs/50-visn-textures.md.
AAN_SCALES: tuple[int, ...] = (
    16384, 22725, 21407, 19266, 16384, 12873, 8867, 4520,
    22725, 31521, 29692, 26722, 22725, 17855, 12299, 6270,
    21407, 29692, 27969, 25172, 21407, 16819, 11585, 5906,
    19266, 26722, 25172, 22654, 19266, 15137, 10426, 5315,
    16384, 22725, 21407, 19266, 16384, 12873, 8867, 4520,
    12873, 17855, 16819, 15137, 12873, 10114, 6967, 3552,
    8867, 12299, 11585, 10426, 8867, 6967, 4799, 2446,
    4520, 6270, 5906, 5315, 4520, 3552, 2446, 124,  # <- 124, not 1247
)

#: Eng3d.dll @ 0x19d98, 17 bytes. Code lengths of the fixed meta-alphabet used
#: to transmit the per-picture Huffman code lengths. Kraft sum is exactly 1.
META_CODE_LENGTHS: tuple[int, ...] = (
    2, 2, 3, 4, 8, 8, 9, 9, 8, 8, 8, 8, 8, 5, 4, 3, 4,
)

#: Meta-symbol 0x10 introduces a 5-bit run of unused (length 0) symbols.
META_RUN_SYMBOL = 0x10
META_RUN_BITS = 5

#: Coefficient alphabet: 0x00..0x74 are literals biased by 0x3A, 0x75..0x80 are
#: escapes carrying ``symbol - 0x74`` extra signed bits.
COEF_ALPHABET_SIZE = 0x81
COEF_LITERAL_BIAS = 0x3A
COEF_ESCAPE_FIRST = 0x75
COEF_ESCAPE_BIAS = 0x74

#: Fixed-point constants of IJG's ``jpeg_idct_ifast`` at CONST_BITS = 8.
FIX_1_414213562 = 362
FIX_1_847759065 = 473
FIX_1_082392200 = 277
FIX_2_613125930 = 669

#: Integer YCbCr coefficients of the colour stage. dB is *truncated* rather
#: than rounded (1.772 * 65536 = 116129.79), which is what the DLL uses.
FIX_CR_TO_R = 91881    # round(1.40200 * 65536)
FIX_CB_TO_B = 116129   # trunc(1.77200 * 65536)
FIX_CB_TO_G = -22554   # -round(0.34414 * 65536)
FIX_CR_TO_G = -46802   # -round(0.71414 * 65536)

#: Colour lookup tables are addressed by ``Y + delta``, which can go negative.
_COLOUR_BIAS = 256
_COLOUR_SPAN = 512  # covers indices -256 .. +511; the real range is -227..483


# ---------------------------------------------------------------------------
# Bitstream
# ---------------------------------------------------------------------------


class BitReader:
    """MSB-first bit reader over a stream of 16-bit little-endian words.

    The decoder keeps a 32-bit shift register whose most significant bit is the
    next bit to be consumed. It is primed with two whole words, so up to 32 bits
    are always pre-read; encoders must pad the tail with a few spare words.

    Reads past the end of the record yield zero words and are counted in
    :attr:`overrun_words`, which lets callers verify that a record was consumed
    exactly rather than silently running into the next one.
    """

    __slots__ = ("_data", "_pos", "_end", "buf", "count", "overrun_words")

    def __init__(self, data: bytes, start: int, end: int) -> None:
        self._data = data
        self._pos = start
        self._end = end
        self.overrun_words = 0
        w0 = self._next_word()
        w1 = self._next_word()
        self.buf = ((w0 << 16) | w1) & 0xFFFFFFFF
        self.count = 32

    @property
    def byte_pos(self) -> int:
        """Absolute offset just past the last word pulled out of the buffer."""
        return self._pos

    def _next_word(self) -> int:
        pos = self._pos
        self._pos = pos + 2
        if pos + 2 <= self._end:
            data = self._data
            return data[pos] | (data[pos + 1] << 8)
        self.overrun_words += 1
        if pos < self._end:
            return self._data[pos]
        return 0

    def refill(self) -> None:
        """Merge one more word into the shift register (needs ``count`` <= 16)."""
        self.buf |= ((self._next_word() << 16) >> self.count) & 0xFFFFFFFF
        self.count += 16

    def read(self, n: int) -> int:
        """Consume and return the next ``n`` bits (1 <= n <= 16), MSB first."""
        if self.count < n:
            self.refill()
        value = self.buf >> (32 - n)
        self.buf = (self.buf << n) & 0xFFFFFFFF
        self.count -= n
        return value

    def skip(self, n: int) -> None:
        """Discard the next ``n`` bits."""
        if self.count < n:
            self.refill()
        self.buf = (self.buf << n) & 0xFFFFFFFF
        self.count -= n


# ---------------------------------------------------------------------------
# Canonical Huffman decoding
# ---------------------------------------------------------------------------

MAX_CODE_LENGTH = 15
_LUT_BITS = 8


class HuffmanTable:
    """A canonically-assigned Huffman code, built from per-symbol code lengths.

    Assignment is the textbook JPEG/DEFLATE convention: codes are handed out in
    increasing symbol order within each length, and the first code of length
    ``L + 1`` is ``(first_code[L] + count[L]) << 1``.

    Codes of up to 8 bits resolve through a 256-entry lookup table; longer codes
    fall back to a bit-by-bit canonical walk. Retail pictures do use codes longer
    than 8 bits, so the slow path is not dead code.
    """

    __slots__ = ("lut", "maxcode", "mincode", "valptr", "symbols", "lengths")

    def __init__(self, lengths: Sequence[int]) -> None:
        self.lengths = list(lengths)
        counts = [0] * (MAX_CODE_LENGTH + 2)
        for length in lengths:
            if length < 0 or length > MAX_CODE_LENGTH:
                raise VisnError(f"Huffman code length {length} out of range")
            if length:
                counts[length] += 1

        # Symbols ordered by (length, symbol) is exactly canonical code order.
        symbols: list[int] = []
        for length in range(1, MAX_CODE_LENGTH + 1):
            symbols.extend(sym for sym, ln in enumerate(lengths) if ln == length)
        self.symbols = symbols

        maxcode = [-1] * (MAX_CODE_LENGTH + 2)
        mincode = [0] * (MAX_CODE_LENGTH + 2)
        valptr = [0] * (MAX_CODE_LENGTH + 2)
        lut = [-1] * (1 << _LUT_BITS)

        code = 0
        index = 0
        for length in range(1, MAX_CODE_LENGTH + 1):
            n = counts[length]
            if n:
                if code + n > (1 << length):
                    raise VisnError(f"over-subscribed Huffman code at length {length}")
                mincode[length] = code
                valptr[length] = index
                maxcode[length] = code + n - 1
                if length <= _LUT_BITS:
                    pad = _LUT_BITS - length
                    for k in range(n):
                        base = (code + k) << pad
                        entry = (symbols[index + k] << 4) | length
                        for fill in range(1 << pad):
                            lut[base + fill] = entry
                code += n
                index += n
            code <<= 1

        self.maxcode = maxcode
        self.mincode = mincode
        self.valptr = valptr
        self.lut = lut

    def decode(self, br: BitReader) -> int:
        """Read one symbol from ``br``."""
        if br.count < _LUT_BITS:
            br.refill()
        entry = self.lut[br.buf >> 24]
        if entry >= 0:
            length = entry & 15
            br.buf = (br.buf << length) & 0xFFFFFFFF
            br.count -= length
            return entry >> 4
        return self.decode_slow(br)

    def decode_slow(self, br: BitReader) -> int:
        """Bit-by-bit canonical walk, for codes longer than 8 bits.

        Retail pictures routinely use codes up to the full 15 bits, so this is a
        hot path rather than a fallback: a decoder implementing only the 8-bit
        lookup table will fail on the shipped data.
        """
        code = 0
        maxcode = self.maxcode
        for length in range(1, MAX_CODE_LENGTH + 1):
            code = (code << 1) | br.read(1)
            if maxcode[length] >= 0 and code <= maxcode[length]:
                return self.symbols[self.valptr[length] + code - self.mincode[length]]
        raise VisnError("bad Huffman code (no match within 15 bits)")


#: The meta-code is fixed for every picture, so build it exactly once.
META_TABLE = HuffmanTable(META_CODE_LENGTHS)


def read_code_length_table(br: BitReader) -> HuffmanTable:
    """Read one per-picture Huffman table from the picture prologue.

    Wire format: a 12-bit symbol count ``N`` (retail always writes 0x81 = 129),
    then ``N`` code lengths delta-coded modulo 16 through :data:`META_TABLE`:

    * meta 0x00..0x0F -- ``running = (running + meta) & 0xF``; emit ``running``
    * meta 0x10       -- read 5 more bits ``k``; emit ``k`` unused (length 0)
      symbols without disturbing ``running``
    """
    n_symbols = br.read(12)
    if not 0 < n_symbols <= 4096:
        raise VisnError(f"implausible Huffman symbol count {n_symbols}")

    lengths: list[int] = []
    running = 0
    while len(lengths) < n_symbols:
        meta = META_TABLE.decode(br)
        if meta == META_RUN_SYMBOL:
            run = br.read(META_RUN_BITS)
            if run == 0:
                raise VisnError("zero-length run in Huffman code-length table")
            lengths.extend([0] * run)
        elif meta < META_RUN_SYMBOL:
            running = (running + meta) & 0xF
            lengths.append(running)
        else:
            raise VisnError(f"meta symbol {meta} out of range")

    if len(lengths) != n_symbols:
        raise VisnError(
            f"code-length table overran: emitted {len(lengths)} of {n_symbols}"
        )
    return HuffmanTable(lengths)


# ---------------------------------------------------------------------------
# Quantisation
# ---------------------------------------------------------------------------

_QUANT_CACHE: dict[int, tuple[tuple[int, ...], tuple[int, ...]]] = {}


def _scale_table(base: Sequence[int], quality: int) -> tuple[int, ...]:
    """Build one quantisation table in *scan* order for the given IJG quality."""
    quality = max(1, min(100, quality))
    scale = (100 - quality) * 2 if quality > 50 else 5000 // quality
    table = [0] * 64
    for raster in range(64):
        value = (base[raster] * scale + 50) // 100
        value = 1 if value < 1 else (255 if value > 255 else value)
        table[ZIGZAG[raster]] = value * AAN_SCALES[raster]
    return tuple(table)


def build_quant_tables(quality: int) -> tuple[tuple[int, ...], tuple[int, ...]]:
    """Return ``(luma, chroma)`` quantisation tables in scan order.

    The AAN prescale is folded in, so a decoded coefficient is
    ``(symbol_value * qtab[scan_index]) >> 14``.
    """
    cached = _QUANT_CACHE.get(quality)
    if cached is None:
        cached = (
            _scale_table(QUANT_BASE_LUMA, quality),
            _scale_table(QUANT_BASE_CHROMA, quality),
        )
        _QUANT_CACHE[quality] = cached
    return cached


# ---------------------------------------------------------------------------
# Inverse DCT (IJG jpeg_idct_ifast)
# ---------------------------------------------------------------------------


def idct_ifast(block: list[int]) -> list[int]:
    """AAN fast inverse DCT over a raster-order block of prescaled coefficients.

    Pass 1 walks the columns and does not descale; pass 2 walks the rows and
    shifts right by 3. Shifts are arithmetic (floor), as in the original x86
    ``sar``. There is no level shift and no clamping here: the ``+128`` rides in
    the DC coefficient and clamping happens in the colour tables.
    """
    ws = [0] * 64

    # --- pass 1: columns -------------------------------------------------
    for col in range(8):
        c1 = block[col + 8]
        c2 = block[col + 16]
        c3 = block[col + 24]
        c4 = block[col + 32]
        c5 = block[col + 40]
        c6 = block[col + 48]
        c7 = block[col + 56]
        if not (c1 or c2 or c3 or c4 or c5 or c6 or c7):
            # All AC zero in this column: the transform just replicates the DC.
            dc = block[col]
            ws[col] = ws[col + 8] = ws[col + 16] = ws[col + 24] = dc
            ws[col + 32] = ws[col + 40] = ws[col + 48] = ws[col + 56] = dc
            continue

        tmp0 = block[col]
        tmp1 = c2
        tmp2 = c4
        tmp3 = c6
        tmp10 = tmp0 + tmp2
        tmp11 = tmp0 - tmp2
        tmp13 = tmp1 + tmp3
        tmp12 = (((tmp1 - tmp3) * FIX_1_414213562) >> 8) - tmp13
        tmp0 = tmp10 + tmp13
        tmp3 = tmp10 - tmp13
        tmp1 = tmp11 + tmp12
        tmp2 = tmp11 - tmp12

        z13 = c5 + c3
        z10 = c5 - c3
        z11 = c1 + c7
        z12 = c1 - c7
        tmp7 = z11 + z13
        tmp11 = ((z11 - z13) * FIX_1_414213562) >> 8
        z5 = ((z10 + z12) * FIX_1_847759065) >> 8
        tmp10 = ((z12 * FIX_1_082392200) >> 8) - z5
        tmp12 = ((z10 * -FIX_2_613125930) >> 8) + z5
        tmp6 = tmp12 - tmp7
        tmp5 = tmp11 - tmp6
        tmp4 = tmp10 + tmp5

        ws[col] = tmp0 + tmp7
        ws[col + 56] = tmp0 - tmp7
        ws[col + 8] = tmp1 + tmp6
        ws[col + 48] = tmp1 - tmp6
        ws[col + 16] = tmp2 + tmp5
        ws[col + 40] = tmp2 - tmp5
        ws[col + 32] = tmp3 + tmp4
        ws[col + 24] = tmp3 - tmp4

    # --- pass 2: rows ----------------------------------------------------
    out = [0] * 64
    for base in range(0, 64, 8):
        c1 = ws[base + 1]
        c2 = ws[base + 2]
        c3 = ws[base + 3]
        c4 = ws[base + 4]
        c5 = ws[base + 5]
        c6 = ws[base + 6]
        c7 = ws[base + 7]
        if not (c1 or c2 or c3 or c4 or c5 or c6 or c7):
            dc = ws[base] >> 3
            out[base] = out[base + 1] = out[base + 2] = out[base + 3] = dc
            out[base + 4] = out[base + 5] = out[base + 6] = out[base + 7] = dc
            continue

        tmp10 = ws[base] + c4
        tmp11 = ws[base] - c4
        tmp13 = c2 + c6
        tmp12 = (((c2 - c6) * FIX_1_414213562) >> 8) - tmp13
        tmp0 = tmp10 + tmp13
        tmp3 = tmp10 - tmp13
        tmp1 = tmp11 + tmp12
        tmp2 = tmp11 - tmp12

        z13 = c5 + c3
        z10 = c5 - c3
        z11 = c1 + c7
        z12 = c1 - c7
        tmp7 = z11 + z13
        tmp11 = ((z11 - z13) * FIX_1_414213562) >> 8
        z5 = ((z10 + z12) * FIX_1_847759065) >> 8
        tmp10 = ((z12 * FIX_1_082392200) >> 8) - z5
        tmp12 = ((z10 * -FIX_2_613125930) >> 8) + z5
        tmp6 = tmp12 - tmp7
        tmp5 = tmp11 - tmp6
        tmp4 = tmp10 + tmp5

        out[base] = (tmp0 + tmp7) >> 3
        out[base + 7] = (tmp0 - tmp7) >> 3
        out[base + 1] = (tmp1 + tmp6) >> 3
        out[base + 6] = (tmp1 - tmp6) >> 3
        out[base + 2] = (tmp2 + tmp5) >> 3
        out[base + 5] = (tmp2 - tmp5) >> 3
        out[base + 4] = (tmp3 + tmp4) >> 3
        out[base + 3] = (tmp3 - tmp4) >> 3
    return out


# ---------------------------------------------------------------------------
# Colour conversion
# ---------------------------------------------------------------------------


def _delta_table(fix: int) -> tuple[int, ...]:
    """``delta(i) = (FIX * (i - 128) + 32768) >> 16`` with a floor shift."""
    return tuple((fix * (i - 128) + 32768) >> 16 for i in range(257))


DELTA_R_FROM_CR = _delta_table(FIX_CR_TO_R)
DELTA_B_FROM_CB = _delta_table(FIX_CB_TO_B)
DELTA_G_FROM_CB = _delta_table(FIX_CB_TO_G)
DELTA_G_FROM_CR = _delta_table(FIX_CR_TO_G)


def _channel_table(max_value: int, shift: int) -> tuple[int, ...]:
    """One colour channel table, biased by :data:`_COLOUR_BIAS`.

    Indices below 0 and above 383 map to zero; 0..255 scale to the channel's
    full range; 256..383 saturate. The stored value is already shifted into its
    field of the packed pixel, so the three lookups only have to be OR'd
    together.

    This mirrors ``Eng3d.dll`` @ ``0x413a74`` exactly: ``esi = (1 << width) - 1``
    is the channel maximum, the ramp is the identity byte table at ``0x41abb0``,
    the scaling is ``imul`` / ``idiv 255`` (a truncating divide, and the operands
    are non-negative, so it is a floor), and the 128 entries below and above the
    0..255 range are filled by ``rep stosd`` with zero and with the last value
    computed.
    """
    table = [0] * (_COLOUR_BIAS + _COLOUR_SPAN)
    for i in range(256):
        table[_COLOUR_BIAS + i] = ((i * max_value) // 255) << shift
    saturated = max_value << shift
    for i in range(256, 384):
        table[_COLOUR_BIAS + i] = saturated
    return tuple(table)


def pixel_format_fields(pixel_format: int) -> tuple[tuple[int, int], ...]:
    """Split a ``_E3D_init_vision`` argument into ``(width, shift)`` per channel.

    ``Eng3d.dll`` @ ``0x413a2d`` takes the argument apart as ``eax & 7``,
    ``(eax & 0x70) >> 4`` and ``(eax & 0x700) >> 8`` and then hands those to the
    table builder as:

    * blue  (``0x4941b4``) — width = the **high** nibble, shift 0;
    * green (``0x4939b4``) — width = the middle nibble, shift = the high nibble;
    * red   (``0x4931b4``) — width = the **low** nibble, shift = middle + high.

    So the nibbles are ordered B, G, R from most to least significant, and the
    familiar ``0x565`` reads as "blue 5 bits, green 6, red 5". ``0x555`` is the
    same descriptor with a 5-bit green, i.e. RGB555. Note that the low nibble is
    masked with 7 rather than 0xF, an asymmetry that has no effect on either of
    the two values the engine is ever given.

    Returns ``((r_width, r_shift), (g_width, g_shift), (b_width, b_shift))``.
    """
    low = pixel_format & 7
    mid = (pixel_format & 0x70) >> 4
    high = (pixel_format & 0x700) >> 8
    return ((low, mid + high), (mid, high), (high, 0))


#: Pixel formats ``_E3D_init_vision`` is called with. 0x565 is what the game
#: uses; 0x555 targets 15-bit displays.
PIXEL_FORMAT_RGB565 = 0x565
PIXEL_FORMAT_RGB555 = 0x555

_CHANNEL_TABLE_CACHE: dict[int, tuple[tuple[int, ...], ...]] = {}


def channel_tables(pixel_format: int) -> tuple[tuple[int, ...], ...]:
    """The three colour channel tables ``_E3D_init_vision(pixel_format)`` builds."""
    cached = _CHANNEL_TABLE_CACHE.get(pixel_format)
    if cached is None:
        cached = tuple(
            _channel_table((1 << width) - 1, shift)
            for width, shift in pixel_format_fields(pixel_format)
        )
        _CHANNEL_TABLE_CACHE[pixel_format] = cached
    return cached


TABLE_R, TABLE_G, TABLE_B = channel_tables(PIXEL_FORMAT_RGB565)


def convert_64k_to_32k(pixels: Sequence[int]) -> list[int]:
    """Model ``_E3D_convert_picblock_from_64kcolor_to_32kcolor`` (@ ``0x4049e0``).

    The routine is a flat loop over the buffer that does, two pixels at a time::

        out = ((in & 0xFFC0) >> 1) | (in & 0x001F)

    i.e. it drops green's least significant bit and slides red and green down one
    place, turning RGB565 into RGB555 in place of a re-quantisation.

    **This is not the same as decoding with** ``_E3D_init_vision(0x555)``. The
    direct path scales green as ``(i * 31) // 255``; this one computes
    ``((i * 63) // 255) >> 1``. The two disagree for 65 of the 256 possible
    green inputs, the lowest being 41 — see :func:`green_disagreement`.

    **Hazard:** the routine's counter is ``sar ecx, 1`` followed by a
    ``dec``/``jne`` do-while, so a count of 0 or 1 leaves ``ecx`` at zero on
    entry to the loop, which then wraps to 2**32-1 and runs away through memory.
    Only counts of 2 or more are safe. This wrapper has no such limit.
    """
    return [((p & 0xFFC0) >> 1) | (p & 0x001F) for p in pixels]


def green_disagreement() -> list[int]:
    """Green sample values where direct-555 and post-converted-565 differ."""
    return [i for i in range(256)
            if (i * 31) // 255 != ((i * 63) // 255) >> 1]


def _rgb888_lut(pixel_format: int) -> tuple[bytes, ...]:
    """Packed-pixel -> RGB888 triples, by bit replication (our own choice)."""
    fields = pixel_format_fields(pixel_format)
    out = []
    for p in range(65536):
        triple = bytearray(3)
        for channel, (width, shift) in enumerate(fields):
            value = (p >> shift) & ((1 << width) - 1)
            spare = 2 * width - 8
            triple[channel] = ((value << (8 - width)) & 0xFF) | (
                (value >> spare) if spare > 0 else 0)
        out.append(bytes(triple))
    return tuple(out)


_RGB888_LUT_CACHE: dict[int, tuple[bytes, ...]] = {}

#: RGB565 -> packed RGB888 triples, by bit replication.
RGB565_TO_RGB888: tuple[bytes, ...] = _rgb888_lut(PIXEL_FORMAT_RGB565)
_RGB888_LUT_CACHE[PIXEL_FORMAT_RGB565] = RGB565_TO_RGB888


# ---------------------------------------------------------------------------
# Record decoding
# ---------------------------------------------------------------------------


@dataclass
class VisnImage:
    """One decoded VISN record."""

    width: int
    height: int
    quality: int
    mode: int
    #: ``width * height`` packed pixels, top-to-bottom raster order. This is
    #: exactly what the game's ``_E3D_decode_picture`` writes.
    pixels: list[int]
    #: Bytes of the record the bitstream actually pulled in, including the
    #: 32-bit pre-read.
    bytes_read: int
    #: 16-bit words the pre-read demanded beyond the end of the record.
    overrun_words: int
    #: The ``_E3D_init_vision`` pixel format ``pixels`` is packed in.
    pixel_format: int = PIXEL_FORMAT_RGB565

    def to_rgb888(self) -> bytes:
        """Expand to packed 24-bit RGB by bit replication (our own choice)."""
        lut = _RGB888_LUT_CACHE.get(self.pixel_format)
        if lut is None:
            lut = _rgb888_lut(self.pixel_format)
            _RGB888_LUT_CACHE[self.pixel_format] = lut
        return b"".join([lut[p] for p in self.pixels])


def parse_header(data: bytes, offset: int = 0) -> tuple[int, int, int, int]:
    """Return ``(width, height, quality, mode)`` from a 10-byte record header."""
    if len(data) - offset < HEADER_SIZE:
        raise VisnError(f"record at 0x{offset:x} is shorter than the 10-byte header")
    if data[offset:offset + 4] != MAGIC:
        raise VisnError(
            f"bad magic at 0x{offset:x}: {data[offset:offset + 4]!r}, expected {MAGIC!r}"
        )
    width, height = struct.unpack_from("<HH", data, offset + 4)
    return width, height, data[offset + 8], data[offset + 9]


def decode_record(data: bytes, offset: int = 0, size: int | None = None,
                  pixel_format: int = PIXEL_FORMAT_RGB565) -> VisnImage:
    """Decode a single VISN record starting at ``offset``.

    ``size`` bounds the record inside a concatenated container; without it the
    rest of ``data`` is assumed to belong to this record.

    ``pixel_format`` selects the colour tables, exactly as the argument of
    ``_E3D_init_vision`` does: :data:`PIXEL_FORMAT_RGB565` (what the game uses)
    or :data:`PIXEL_FORMAT_RGB555`. Only the three channel tables depend on it;
    the transform, the dequantiser and the YCbCr deltas do not.
    """
    width, height, quality, mode = parse_header(data, offset)
    end = len(data) if size is None else min(len(data), offset + size)

    if mode not in (MODE_420, MODE_444):
        raise VisnError(f"unknown VISN mode byte {mode} (only 0 and 2 exist)")
    # The DLL derives the macroblock counts as ``width >> 4`` and ``height >> 4``
    # (Eng3d.dll @ 0x41267d) and mode 2 then doubles both (@ 0x412873). That is
    # NOT the same as ``width >> 3``: at 24 pixels wide the engine lays down two
    # 8-pixel macroblocks, not three, and never writes the last 8 columns. The
    # inner loops are ``dec``/``jne`` do-whiles, so a count of zero wraps to
    # 2**32-1 and the DLL runs off the end of the buffer -- which is why any
    # dimension below 16 is rejected here rather than emulated.
    # Confirmed at runtime; see docs/50-visn-textures.md section 10.6.
    if width < 16 or height < 16:
        raise VisnError(
            f"unsupported picture size {width}x{height}: the engine counts "
            f"macroblocks as (size >> 4), and its do-while loops underflow "
            f"when that count is zero, so both axes must be at least 16"
        )

    br = BitReader(data, offset + HEADER_SIZE, end)
    # Table A is used by the chroma blocks, table B by the luma blocks.
    huff_chroma = read_code_length_table(br)
    huff_luma = read_code_length_table(br)
    quant_luma, quant_chroma = build_quant_tables(quality)

    # Mode 2 doubles the base counts, giving 8-pixel macroblocks; mode 0 uses
    # them as they are, giving 16-pixel ones. Sizes that are not a multiple of 16
    # leave a right/bottom margin the engine never writes; the planes are
    # zero-initialised here, whereas the DLL leaves whatever the caller's buffer
    # held.
    scale = 1 if mode == MODE_420 else 2
    mb_cols = (width >> 4) * scale
    mb_rows = (height >> 4) * scale
    plane_y = [0] * (width * height)
    plane_cb = [0] * (width * height)
    plane_cr = [0] * (width * height)

    natural = NATURAL_ORDER
    if mode == MODE_444:
        planes = (plane_cb, plane_cr, plane_y)
        tables = (
            (huff_chroma, quant_chroma),
            (huff_chroma, quant_chroma),
            (huff_luma, quant_luma),
        )
        for mb_y in range(mb_rows):
            row_base = mb_y * 8 * width
            for mb_x in range(mb_cols):
                origin = row_base + mb_x * 8
                for plane, (huff, qtab) in zip(planes, tables):
                    block = _decode_block(br, huff, qtab, natural)
                    pixels = idct_ifast(block)
                    for row in range(8):
                        start = origin + row * width
                        plane[start:start + 8] = pixels[row * 8:row * 8 + 8]
    else:
        _decode_420(br, width, mb_cols, mb_rows, huff_chroma, huff_luma,
                    quant_chroma, quant_luma, plane_y, plane_cb, plane_cr)

    pixels = _convert_colour(plane_y, plane_cb, plane_cr, pixel_format)
    return VisnImage(
        width=width,
        height=height,
        quality=quality,
        mode=mode,
        pixels=pixels,
        bytes_read=br.byte_pos - offset,
        overrun_words=br.overrun_words,
        pixel_format=pixel_format,
    )


#: Where each of the four Y blocks of a mode-0 macroblock lands, as (dy, dx)
#: within the 16x16 macroblock. Read off ``Eng3d.dll`` @ ``0x4132d3``, which
#: renders the quadrants in the order Y0, Y2, Y1, Y3 and offsets the second
#: column by 0x10 bytes, i.e. 8 pixels: plain raster order.
MB420_Y_OFFSETS = ((0, 0), (0, 8), (8, 0), (8, 8))


def _decode_420(
    br: BitReader,
    width: int,
    mb_cols: int,
    mb_rows: int,
    huff_chroma: HuffmanTable,
    huff_luma: HuffmanTable,
    quant_chroma: Sequence[int],
    quant_luma: Sequence[int],
    plane_y: list[int],
    plane_cb: list[int],
    plane_cr: list[int],
) -> None:
    """Decode a mode-0 (4:2:0) picture into the three sample planes.

    Six blocks per 16x16 macroblock, in stream order Cb, Cr, Y0, Y1, Y2, Y3.
    The Y blocks tile the macroblock in raster order and each chroma sample is
    replicated over the 2x2 group of pixels it covers, phase-aligned to the
    top-left corner -- there is no interpolation. Both rules were read out of
    the engine's mode-0 colour stage (``Eng3d.dll`` @ ``0x4132d3``, which builds
    one pair of chroma offsets and then applies it to four luma samples) and
    then confirmed byte-for-byte against the DLL with synthetic records; see
    ``tools/wine_visn/`` and docs/50-visn-textures.md section 10.7.
    """
    natural = NATURAL_ORDER
    for mb_y in range(mb_rows):
        for mb_x in range(mb_cols):
            origin = mb_y * 16 * width + mb_x * 16
            cb = idct_ifast(_decode_block(br, huff_chroma, quant_chroma, natural))
            cr = idct_ifast(_decode_block(br, huff_chroma, quant_chroma, natural))
            for row in range(8):
                top = origin + 2 * row * width
                for col in range(8):
                    left = top + 2 * col
                    value_cb = cb[row * 8 + col]
                    value_cr = cr[row * 8 + col]
                    for pos in (left, left + 1, left + width, left + width + 1):
                        plane_cb[pos] = value_cb
                        plane_cr[pos] = value_cr
            for dy, dx in MB420_Y_OFFSETS:
                pixels = idct_ifast(_decode_block(br, huff_luma, quant_luma, natural))
                for row in range(8):
                    start = origin + (dy + row) * width + dx
                    plane_y[start:start + 8] = pixels[row * 8:row * 8 + 8]


def _decode_block(
    br: BitReader,
    huff: HuffmanTable,
    qtab: Sequence[int],
    natural: Sequence[int],
) -> list[int]:
    """Read one 8x8 block and scatter its coefficients into raster order.

    Wire format: 6 bits ``nAC``, 12 bits ``DC + 0x800``, then ``nAC`` Huffman
    symbols giving scan positions 1..nAC. The DC is raw -- neither predicted nor
    dequantised.
    """
    block = [0] * 64
    n_ac = br.read(6)
    block[0] = br.read(12) - 0x800

    lut = huff.lut
    for scan in range(1, n_ac + 1):
        # Inlined HuffmanTable.decode; this is the hottest loop in the codec.
        if br.count < _LUT_BITS:
            br.refill()
        entry = lut[br.buf >> 24]
        if entry >= 0:
            length = entry & 15
            br.buf = (br.buf << length) & 0xFFFFFFFF
            br.count -= length
            symbol = entry >> 4
        else:
            symbol = huff.decode_slow(br)

        if symbol < COEF_ESCAPE_FIRST:
            value = symbol - COEF_LITERAL_BIAS
            if value == 0:
                continue
        else:
            bits = symbol - COEF_ESCAPE_BIAS
            if bits > 12:
                raise VisnError(f"coefficient symbol {symbol:#x} out of alphabet")
            value = br.read(bits)
            if value >= (1 << (bits - 1)):
                value -= 1 << bits
            if value == 0:
                continue
        block[natural[scan]] = (value * qtab[scan]) >> 14
    return block


def _convert_colour(
    plane_y: Sequence[int],
    plane_cb: Sequence[int],
    plane_cr: Sequence[int],
    pixel_format: int = PIXEL_FORMAT_RGB565,
) -> list[int]:
    """Combine the three planes into packed pixels through the engine's tables.

    Y, Cb and Cr are clamped to 0..256 inclusive -- the upper bound really is
    256, not 255, which is why the tables carry a saturation region above 255.

    ``pixel_format`` picks the channel tables; the chroma deltas below are the
    same in every format, because ``_E3D_init_vision`` builds the composite
    tables from the same constants whatever the argument.
    """
    dr = DELTA_R_FROM_CR
    db = DELTA_B_FROM_CB
    dgcb = DELTA_G_FROM_CB
    dgcr = DELTA_G_FROM_CR
    tr, tg, tb = channel_tables(pixel_format)
    bias = _COLOUR_BIAS

    out = []
    append = out.append
    for y, cb, cr in zip(plane_y, plane_cb, plane_cr):
        y = 0 if y < 0 else (256 if y > 256 else y)
        cb = 0 if cb < 0 else (256 if cb > 256 else cb)
        cr = 0 if cr < 0 else (256 if cr > 256 else cr)
        base = bias + y
        append(
            tr[base + dr[cr]]
            | tg[base + dgcb[cb] + dgcr[cr]]
            | tb[base + db[cb]]
        )
    return out


# ---------------------------------------------------------------------------
# Container access
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ContainerEntry:
    """One row of the sibling ``.din`` index that addresses a VISN record."""

    index: int
    name: str
    offset: int
    size: int


DIN_MAGIC = b"DBIN"
DIN_ENTRY_SIZE = 25
DIN_NAME_SIZE = 13


def read_din_index(path: str) -> list[ContainerEntry]:
    """Parse a binary ``.din`` table of contents.

    Layout: ``"DBIN"``, ``u32 count``, then per entry ``u32 index``,
    ``char name[13]`` (NUL-padded), ``u32 offset``, ``u32 size``. Only the
    addressing fields are interpreted here; the general ``.dir``/``.din``
    specification is documented elsewhere.
    """
    reader = open_reader(path)
    if reader.take(4) != DIN_MAGIC:
        raise VisnError(f"{path}: not a DBIN index")
    count = reader.u32()
    expected = 8 + count * DIN_ENTRY_SIZE
    if len(reader) != expected:
        raise VisnError(
            f"{path}: {count} entries need {expected} bytes but the file is {len(reader)}"
        )
    entries = []
    for _ in range(count):
        index = reader.u32()
        # cstring() decodes cp1252: five Video/Seq_4 records carry a 0xE4 ('a-umlaut').
        name = reader.cstring(DIN_NAME_SIZE)
        offset = reader.u32()
        size = reader.u32()
        entries.append(ContainerEntry(index, name, offset, size))
    return entries

"""Reader for the briefing and info text files under ``DATA/TXT`` (docs/24).

The files are plain 8-bit text carrying a tiny markup that Blue Byte's own
translator note (``Errors.txt``) describes as *labels* and *format commands*:

    Translate only the text opened by {:xn} and closed by {*}. (xn=label ...)
    Ignore all formatcommands like {...},@ and #.

Two different readers in ``aGUI.cpp`` consume the same syntax, and everything
here mirrors one of them byte for byte:

``aFindGUITextBoxTag`` (``0x0043DDA0``)
    finds ``{:`` + two label characters and returns the offset five bytes on.
    It never checks the closing brace.  :func:`find_label`.

``aGetGUITextBoxString`` (``0x0043DE90``)
    copies from there until ``|``, ``@`` or ``#``, at most 200 bytes.
    :func:`field`.

``aCreateGUITextBox`` (``0x0043D820``)
    lays the block out into lines, honouring the format commands and
    word wrap, and stops at ``{*}``.  :func:`layout`.

The text is handled as ``str`` decoded latin-1, which is a bijection onto the
bytes the engine compares; the font maps a byte to a glyph as ``byte - 0x20``,
so no other encoding assumption is needed.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterator, Mapping, Sequence

from .liblib import ShapeLibrary


class BriefError(Exception):
    pass


# --- the markup ------------------------------------------------------------

TAG_OPEN = "{"
LABEL_INTRO = ":"
"""``{:xy}`` -- a label.  The engine reads the two characters after ``{:``."""
COLOUR_INTRO = "#"
"""``{#n}`` -- select colour ramp n (0, 1, 2); see :data:`COLOUR_RAMPS`."""
FONT_INTRO = "\xa7"
"""``{§n}`` -- select font n; ``aGetFont`` only knows 0 and 1."""
END = "*"
"""``{*}`` -- end of the block."""
BREAK = "@"
"""A hard line break."""
FIELD_SEPARATOR = "|"

FIELD_TERMINATORS = "|@#"
FIELD_LIMIT = 200
"""``aGUI.cpp:2557`` raises "unknow command" once 200 bytes are copied."""

LABEL_TAG_LENGTH = 5
"""``{``, ``:``, two label characters, ``}`` -- the engine skips five bytes."""

FONT_IDS = (0, 1)
"""``aGetFont`` (``0x00439E20``) returns -1 for anything else."""

COLOUR_RAMPS: Mapping[int, tuple[int, int, int, int] | None] = {
    0: None,                              # restore the box's own four colours
    1: (0x94B2, 0x528A, 0x0841, 0x0000),  # RGB565, green-grey
    2: (0xF800, 0x6000, 0x0800, 0x0000),  # RGB565, red
}
"""``aPrintGUITextBox`` (``0x0043E445``).  Any other digit is ignored."""

# --- fonts -----------------------------------------------------------------

@dataclass
class Font:
    """One of the two fonts ``{§n}`` can select.

    ``aCreateLibFont`` builds both with line height 12, space width 4 and
    tracking 1 (``0x00439D60``), and ``aGetCharWidth`` (``0x00439B10``) is::

        c <  0x20 -> 0
        c == 0x20 -> space_width + tracking
        else      -> glyph[c - 0x20].width + tracking
    """

    id: int
    lib_name: str
    line_height: int = 12
    space_width: int = 4
    tracking: int = 1
    glyphs: Sequence[int] = ()

    @classmethod
    def from_lib(cls, font_id: int, lib_name: str, lib: ShapeLibrary,
                 line_height: int = 12, space_width: int = 4,
                 tracking: int = 1) -> "Font":
        return cls(font_id, lib_name, line_height, space_width, tracking,
                   [e.width for e in lib.elements])

    def width(self, ch: str) -> int:
        code = ord(ch)
        if code < 0x20:
            return 0
        if code == 0x20:
            return self.space_width + self.tracking
        index = code - 0x20
        if index >= len(self.glyphs):
            raise BriefError(f"character {code:#04x} is outside {self.lib_name}")
        return self.glyphs[index] + self.tracking


# --- labels ----------------------------------------------------------------

@dataclass(frozen=True)
class Label:
    key: str
    """The two characters between ``{:`` and the closing brace."""
    tag: int
    """Offset of the ``{``."""
    value: int
    """Offset of the first byte after the five-byte tag."""


def find_label(text: str, key: str) -> int | None:
    """``aFindGUITextBoxTag``: offset just past the first ``{:`` + *key*.

    Returns ``None`` when the label is absent -- which is a failure for the
    engine too: ``aCreateGUITextBox`` frees the buffer and returns 0, and the
    info activator at ``0x0043E850`` then retries with the key ``**``.

    The closing brace is **not** verified, and the first match wins.
    """
    if len(key) != 2:
        raise BriefError(f"a label key is two characters, not {key!r}")
    if key[0] == COLOUR_INTRO:
        return None             # 0x0043DDF7: '#' means "no label, start at 0"
    hit = text.find(TAG_OPEN + LABEL_INTRO + key)
    return None if hit < 0 else hit + LABEL_TAG_LENGTH


def labels(text: str) -> list[Label]:
    """Every ``{:xy`` in file order, whether or not it is closed properly."""
    out: list[Label] = []
    start = 0
    needle = TAG_OPEN + LABEL_INTRO
    while True:
        hit = text.find(needle, start)
        if hit < 0 or hit + 4 > len(text):
            return out
        out.append(Label(text[hit + 2:hit + 4], hit, hit + LABEL_TAG_LENGTH))
        start = hit + 1


def field(text: str, key: str) -> str | None:
    """``aGetGUITextBoxString``: the label's value up to ``|``, ``@`` or ``#``.

    Raises :class:`BriefError` past 200 bytes, where the engine reports
    "unknow command" and returns failure.
    """
    at = find_label(text, key)
    if at is None:
        return None
    end = at
    while end < len(text) and text[end] not in FIELD_TERMINATORS:
        end += 1
        if end - at == FIELD_LIMIT:
            raise BriefError(f"label {key} runs past {FIELD_LIMIT} bytes")
    return text[at:end]


def block(text: str, key: str) -> str | None:
    """The label's value up to ``{*}``; ``None`` when the label is missing.

    Raises :class:`BriefError` when the block is not closed: the engine would
    run on into whatever follows, printing the next label's characters.
    """
    at = find_label(text, key)
    if at is None:
        return None
    end = text.find(TAG_OPEN + END, at)
    if end < 0:
        raise BriefError(f"label {key} is never closed with {{*}}")
    return text[at:end]


# --- the layout pass -------------------------------------------------------

@dataclass
class Line:
    start: int
    end: int
    text: str
    """The raw span, markup included."""
    rendered: str
    """Only what ``aPrintGUITextBox`` would draw: no commands, no ``@``, no
    control characters."""


def visible(span: str) -> str:
    """Strip everything the printer skips: commands, ``@`` and controls.

    A command is never split across a line, because a wrap can only happen at
    a word start and the format commands contain no whitespace.
    """
    out = []
    i = 0
    while i < len(span):
        ch = span[i]
        if ch == TAG_OPEN and i + 1 < len(span):
            intro = span[i + 1]
            if intro == COLOUR_INTRO or intro == FONT_INTRO:
                i += 4
                continue
            if intro == END:
                break
            if intro == LABEL_INTRO:
                i += LABEL_TAG_LENGTH
                continue
        if ch != BREAK and ord(ch) >= 0x20:
            out.append(ch)
        i += 1
    return "".join(out)


def layout(text: str, start: int, width: int, fonts: Mapping[int, Font],
           font: int = 0) -> list[Line]:
    """``aCreateGUITextBox``'s measuring loop, as line spans.

    *width* is the box width; the engine wraps once the pen would pass
    ``width - 8``.  Wrapping happens at the last word start seen, which is
    recorded one byte after a whitespace that follows a non-whitespace.
    Carriage return is the one control character that is not a break
    candidate.  A ``{*}`` ends the block.
    """
    if font not in fonts:
        raise BriefError(f"font {font} is not one of {sorted(fonts)}")
    if set(fonts) - set(FONT_IDS):
        raise BriefError(f"aGetFont only knows {FONT_IDS}")
    limit = width - 8
    starts = [start]
    i = brk = start
    pen = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ord(ch) <= 0x20 and ch != "\r":
            if i >= 1 and ord(text[i - 1]) > 0x20:
                brk = i + 1
        if ch == TAG_OPEN and i + 1 < n and text[i + 1] == END:
            break
        if text[i] == BREAK:
            starts.append(i)
            brk = i
            pen = 0
            i += 1
            if i >= n:
                break
        ch = text[i]
        if ord(ch) < 0x20:
            i += 1
            continue
        if ch == TAG_OPEN:
            intro = text[i + 1] if i + 1 < n else ""
            i += 1
            if intro == COLOUR_INTRO:
                i += 3
                continue
            if intro != FONT_INTRO:
                i += 1
                continue
            i += 1
            font = ord(text[i]) - 0x30
            if font not in fonts:
                raise BriefError(f"{{\xa7{font}}} selects no font")
            i += 2
            continue
        step = fonts[font].width(ch)
        if pen + step > limit:
            starts.append(brk)
            i = brk
            pen = 0
        else:
            pen += step
        i += 1
    starts.append(min(i, n))
    return [Line(a, b, text[a:b], visible(text[a:b]))
            for a, b in zip(starts, starts[1:])]


# --- the briefing program --------------------------------------------------

BRIEFING_BASE_ROW = 0
"""``aMissionControl.cpp`` walks rows 0.. for the objectives ..."""
TIP_BASE_ROW = 5
"""... and rows 5.. for the tips; the files' own comments say 10-40 / 50-90."""


@dataclass
class ProgramEntry:
    row: int
    picture: str
    x: int | None
    y: int | None
    descriptions: list[str]


def program(text: str, base: int) -> list[ProgramEntry]:
    """The ``PIC``/``X``/``Y``/``DESC`` rows the mission screen reads.

    ``aMissionControl.cpp`` walks rows upward from *base* and stops at the
    first row whose **picture** label is missing, so a gap truncates the list.
    Within a row it reads column 1 as X, column 2 as Y and then columns 3, 4,
    5 ... as description lines until one of them is missing.

    A missing X or Y does not stop anything: the engine keeps whatever the
    register held, i.e. the previous row's value.  No shipped file omits one,
    so that path is never exercised and is reproduced here as ``None``.
    """
    out: list[ProgramEntry] = []
    for row in range(base, 10):
        picture = field(text, f"{row}0")
        if picture is None:
            break
        raw_x = field(text, f"{row}1")
        raw_y = field(text, f"{row}2")
        descriptions = []
        for col in range(3, 10):
            value = field(text, f"{row}{col}")
            if value is None:
                break
            descriptions.append(value.strip())
        out.append(ProgramEntry(row, picture.strip(),
                                _as_int(raw_x, row, "X"),
                                _as_int(raw_y, row, "Y"),
                                descriptions))
    return out


def _as_int(value: str | None, row: int, what: str) -> int | None:
    if value is None:
        return None
    try:
        return int(value.strip())
    except ValueError as exc:
        raise BriefError(f"row {row}: {what} is {value.strip()!r}") from exc

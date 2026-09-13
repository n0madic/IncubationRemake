"""The languages the engine knows, and the one it does not.

``aMain.cpp``'s command-line parser (``0x004494C0``) turns a switch into a
1-based code in ``[0x50DC1C]`` (default 1), and the jump table at ``0x44A4D8``
turns the code into a *name* literal the setter ``0x453DC0`` stores for
``aGetLanguage`` (``0x453DF0``).  The name is only ever a directory component
(``TXT\\%s\\GUI\\%s`` and its two siblings), so the engine's whole notion of a
language is "which subdirectory of ``DATA/TXT``".  Fonts, ``Info.lcl`` and the
interface libraries are loaded by literal name; a localised release replaced
them in place.  ``tools/language_tables.py --check`` pins every one of those
bytes.

The Russian release (1C/Snowball, the *Wilderness* edition) is **not** an
engine language: it overwrote ``DATA/TXT/English/`` and every in-place file
with cp1251 data and shipped no ``Incubation.exe``.  Its row therefore carries
no switch and no code, and its directory is ``English``.  The remake treats it
-- and any other in-place localisation -- as a *language pack* laid over the
GOG base (``docs/92`` §7.6).

This module imports nothing from :mod:`inclib.cache` or :mod:`inclib.convert`
so that both can import it.
"""

from __future__ import annotations

from dataclasses import dataclass


class LanguageError(Exception):
    """Raised for a language name the table does not know."""


@dataclass(frozen=True)
class LanguageSpec:
    """One row of the table.

    ``switch`` and ``engine_code`` are ``None`` for a language the engine has
    no arm for; ``code_page`` is ``None`` where the release's byte-to-glyph
    rule is not a single-byte code page (Japanese; ``docs/24`` §4.4);
    ``directory`` is the ``DATA/TXT`` component the engine's templates fill.
    """

    name: str
    switch: str | None
    engine_code: int | None
    code_page: str | None
    directory: str
    #: Where the row's code page comes from.  Only two rows are backed by
    #: data in hand; the rest are the engine's arms with an inferred page.
    evidence: str = ""


#: The name the GOG release ships and the engine's default (code 1).
DEFAULT_LANGUAGE = "English"

#: cp1252 for the four Western European arms is **UNVERIFIED**: the engine
#: never names a code page (it draws bytes through a 224-glyph bitmap font),
#: and no German, French, Spanish or Italian data is in hand.  The rows exist
#: because the arms exist; nothing consumes them but the table check.
_INFERRED = "UNVERIFIED -- inferred from the arm; no data in hand"

LANGUAGES: tuple[LanguageSpec, ...] = (
    LanguageSpec("English", "-english", 1, "cp1252", "English",
                 "GOG release; the shipped text holds no byte in 0x80..0x9F"),
    LanguageSpec("German", "-german", 2, "cp1252", "German", _INFERRED),
    LanguageSpec("French", "-french", 3, "cp1252", "French", _INFERRED),
    LanguageSpec("Japanese", "-japanese", 7, None, "Japanese",
                 "two-byte path, unimplemented (docs/24 section 4.4)"),
    LanguageSpec("Spanish", "-spanish", 8, "cp1252", "Spanish", _INFERRED),
    LanguageSpec("Italian", "-italian", 9, "cp1252", "Italian", _INFERRED),
    LanguageSpec("Russian", None, None, "cp1251", "English",
                 "1C Wilderness release, verified by hand 2026-09-13; "
                 "overwrote DATA/TXT/English/ in place"),
)

#: The literal the engine falls back to for codes 4..6 (jump-table arms
#: 3..5) -- a name that matches no directory.
UNKNOWN_LANGUAGE = "unknown"


def spec(name: str) -> LanguageSpec:
    for row in LANGUAGES:
        if row.name == name:
            return row
    raise LanguageError(
        f"unknown language {name!r}; one of "
        + ", ".join(row.name for row in LANGUAGES))


def names() -> list[str]:
    return [row.name for row in LANGUAGES]


def codepoint(byte: int, code_page: str | None) -> int:
    """The Unicode code point one source byte stands for under *code_page*.

    **Undefined bytes decode to their own value.**  cp1252 leaves 0x81, 0x8D,
    0x8F, 0x90 and 0x9D undefined and cp1251 leaves 0x98; a strict decode
    raises on them, and the fonts have a glyph slot for every byte 32..255
    whether or not the code page names it.  Mapping the hole to the byte
    value keeps the 224 slots addressable and is the one rule the fonts and
    the text share, so a briefing byte and its glyph cannot disagree.  A
    ``None`` code page (Japanese) is the same identity rule for every byte.
    """
    if not 0 <= byte <= 0xFF:
        raise ValueError(f"byte {byte} is outside 0..255")
    if code_page is None or byte < 0x80:
        return byte
    try:
        return ord(bytes([byte]).decode(code_page))
    except UnicodeDecodeError:
        return byte


def decode_bytes(data: bytes, code_page: str | None) -> str:
    """*data* through :func:`codepoint`, byte by byte."""
    return "".join(chr(codepoint(b, code_page)) for b in data)


def to_dict() -> dict[str, object]:
    return {
        "default": DEFAULT_LANGUAGE,
        "unknown": UNKNOWN_LANGUAGE,
        "languages": [
            {"name": row.name, "switch": row.switch,
             "engine_code": row.engine_code, "code_page": row.code_page,
             "directory": row.directory, "evidence": row.evidence}
            for row in LANGUAGES],
    }

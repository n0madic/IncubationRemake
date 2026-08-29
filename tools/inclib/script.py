"""One mission script as portable data: the interpreter's linear pass.

``docs/20`` §2 settles the shape.  ``0x0043f6e0`` holds a cursor and one
boolean flag, parses every construct on every pass and gates only the final
dispatch; regions do not nest, nothing is skipped, and ``Goto`` rescans from
byte 0 and takes the **first** matching label.  So what a remake's interpreter
needs is the program in the order the cursor meets it, plus a label index --
not the routine/conditional tree, which is a view of the *source*.
:class:`inclib.lcl.Instr` is that order; this module is its cache document.

Three normalisations happen here and nowhere else:

* the source path becomes the path **relative to the game root**, so two
  conversions of the same installation on two machines produce identical bytes;
* a variable argument gains ``slot_index``, the ``tok[1] - 'A'`` the classifier
  at ``0x0043fc90`` computes (``docs/20`` §4.1);
* labels are resolved to instruction indices, first occurrence winning, which
  is what ``0x00440e00`` does by rescanning.

No float is ever emitted, for the reason ``inclib.convert`` gives: the cache is
compared byte for byte.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from . import lcl

SCRIPT_SCHEMA = "incubation.script/1"
TEXT_SCHEMA = "incubation.text/1"

#: ``DATA/TXT/<language>/GUI`` -- the engine's own interface strings, stored as
#: LCL text-resource entries (``docs/20`` section 6).  ``Txtmod_g`` holds
#: "Mission", "Turn" and "Player"; ``Txtmod_d`` "Mission Report"; ``Txtmod_h``
#: the combat messages.  Those are the strings this stage's HUD shows, which is
#: why the catalogue is these and not the whole ``DATA/TXT`` tree: the
#: ``Briefing`` and ``Info`` files carry docs/24 markup that nothing renders
#: yet, and shipping them unrendered would invite treating them as validated.
GUI_TEXT_DIR = "GUI"

#: ``docs/20`` section 6 -- ``0x00470e60`` drops an index of 400 or more.
TEXT_INDEX_LIMIT = 400

#: ``docs/20`` §4.1 -- ``0x0043fc70`` clears 28 dwords, and the classifier
#: accepts ``tok[1] - 'A' <= 0x1b``.  A slot outside this is a parse error the
#: interpreter reports before the flag is ever consulted.
LOCAL_VAR_SLOTS = 28

#: ``docs/20`` §4.2 -- the fill value, on **every** program run.  Not zero: a
#: read before the first write yields -1, and several scripts rely on it.
LOCAL_VAR_INITIAL = -1


class ScriptError(Exception):
    """Raised when a mission script cannot be converted."""


def _arg_document(arg: lcl.Arg) -> dict[str, Any]:
    """One argument, with the slot letter resolved to its array index."""
    out = arg.to_dict()
    if arg.kind == "var" and arg.slot is not None:
        out["slot_index"] = ord(arg.slot) - ord("A")
    return out


def _instruction_document(instr: lcl.Instr) -> dict[str, Any]:
    out = instr.to_dict()
    if instr.args:
        out["args"] = [_arg_document(a) for a in instr.args]
    return out


def label_index(flat: list[lcl.Instr]) -> dict[str, int]:
    """Label name -> index of its instruction; **first occurrence wins**.

    ``Goto`` restarts its scan at byte 0 and stops at the first match, so a
    duplicate label is reachable only in its first occurrence (``docs/20``
    §2.3).  Building the map with "last wins" would silently retarget the four
    shipped scripts that carry one.
    """
    out: dict[str, int] = {}
    for index, instr in enumerate(flat):
        if instr.kind == "label" and instr.name is not None:
            out.setdefault(instr.name, index)
    return out


def script_document(program: lcl.Program,
                    source: dict[str, Any]) -> dict[str, Any]:
    """The portable form of one ``.lcl``."""
    flat = program.flat
    return {
        "schema": SCRIPT_SCHEMA,
        "source": source,
        "header_line": program.header_line,
        "instructions": [_instruction_document(i) for i in flat],
        "labels": label_index(flat),
        "diagnostics": [d.to_dict() for d in program.diagnostics],
    }


def load_script(path: Path) -> lcl.Program:
    """Parse one ``.lcl``, refusing a file that is not a script at all.

    ``DATA/Version.gcl`` shares the extension and holds a bare version string;
    a mission whose script is missing its ``[LCL]`` header is a broken
    installation, not something to convert into an empty program.
    """
    if not lcl.is_script(str(path)):
        raise ScriptError(f"{path}: no '[LCL]' header, not a script")
    try:
        return lcl.parse_file(str(path))
    except lcl.LclSyntaxError as exc:
        raise ScriptError(str(exc)) from exc


def text_catalogue(entries: dict[str, lcl.Program],
                   language: str,
                   source: dict[str, Any]) -> dict[str, Any]:
    """The interface-string catalogue, keyed by file stem and entry index.

    ``docs/20`` section 6: a ``%:<index><sep>"<text>";;`` entry is stored by
    index, and a later entry with the same index **overwrites** the earlier
    one, so the mapping is built in file order and the last write wins -- the
    opposite of the label rule in :func:`label_index`, and for the opposite
    reason: a text entry is a store, a label is a search.

    The store also refuses a rewrite **longer** than the first string for that
    index, and an LCL command failure kills the rest of the text program, so a
    longer duplicate would truncate the catalogue from that point.  No shipped
    duplicate grows a string; one that did would be a modified installation,
    and it is raised rather than silently written.

    Indices become strings because JSON object keys are strings; the loading
    boundary narrows them back, the way it does for every other number.
    """
    catalogue: dict[str, dict[str, str]] = {}
    for stem in sorted(entries):
        strings: dict[str, str] = {}
        capacity: dict[str, int] = {}
        for instr in entries[stem].flat:
            if instr.kind != "text" or instr.index is None:
                continue
            if not 0 <= instr.index < TEXT_INDEX_LIMIT:
                raise ScriptError(
                    f"{stem}:{instr.line}: text index {instr.index} is outside "
                    f"0..{TEXT_INDEX_LIMIT - 1}; 0x00470e60 drops it")
            key = str(instr.index)
            text = instr.text or ""
            if key not in capacity:
                capacity[key] = len(text)
            elif len(text) > capacity[key]:
                raise ScriptError(
                    f"{stem}:{instr.line}: text entry {instr.index} rewritten "
                    f"longer than its first value ({len(text)} > "
                    f"{capacity[key]}); the engine's copy guard aborts here "
                    f"and the rest of the text program never runs")
            strings[key] = text
        catalogue[stem] = strings
    return {
        "schema": TEXT_SCHEMA,
        "language": language,
        "source": source,
        "gui": catalogue,
    }

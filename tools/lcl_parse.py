#!/usr/bin/env python3
"""Tokenizer and parser for Incubation's LCL mission-scripting language.

LCL is the little interpreted language the 1997 Blue Byte game *Incubation*
uses for mission logic, GUI layout and text resources.  Source lives in
``.lcl`` files, usually obfuscated with a bitwise NOT; decoding is delegated to
:mod:`lcl_decode`.

The grammar implemented here follows the actual interpreter, recovered by
decompiling ``Incubation.exe``: the main loop ``aLCL.cpp:ExecuteProgram`` at
``0x0043f6e0``, the token reader at ``0x0043ff00`` and the parameter-list
parser at ``0x0043fc90``.  See ``docs/20-lcl-language.md`` for the prose
reference, the function addresses and what is still unverified.

Usage::

    lcl_parse.py FILE...                # human-readable dump
    lcl_parse.py FILE... --json         # AST as JSON
    lcl_parse.py --check gog_incubation # parse every .lcl below a directory
    lcl_parse.py --check DIR --stats    # ... plus command usage statistics
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from dataclasses import dataclass, field
from typing import Any, Iterator

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lcl_decode import decode, iter_inputs  # noqa: E402

LOG = logging.getLogger("lcl.parse")

#: The interpreter reads bytes; the shipped files are Windows-1252 text.
SOURCE_ENCODING = "cp1252"

#: Characters that open a comment running to the end of the line.
#:
#: Only ``*``.  ``#`` is *not* a comment: the interpreter (``0x0043f6e0``,
#: case ``'#'``) inverts the condition flag, i.e. it is an ``else``.
COMMENT_CHARS = "*"

#: Inverts the condition flag -- the language's ``else``.
ELSE_CHAR = "#"

#: Introduces a text-resource entry: ``%:<index><sep>"<text>";;``.
TEXT_ENTRY_CHAR = "%"

#: Characters that end an identifier and are consumed with it.
#:
#: The interpreter's token reader (``0x0043ff00``) stops a name at any of
#: these six characters, so a label may legally be closed by any of them;
#: the corpus uses ``;`` and ``:``.
LABEL_TERMINATORS = "();,:]"

#: Boolean combinators that may prefix an extra condition term.
COMBINATORS = "&|"

_IDENT_START = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
_IDENT_BODY = _IDENT_START | set("0123456789")
_DIGITS = set("0123456789")
_WHITESPACE = set(" \t\r\n\v\f")


# ---------------------------------------------------------------------------
# AST
# ---------------------------------------------------------------------------


@dataclass
class Diagnostic:
    """A note about something irregular in the source.

    Diagnostics never abort parsing: the shipped corpus contains authoring
    mistakes (unbalanced ``>``/``<``, an unterminated string literal) that the
    original interpreter evidently tolerated, so the parser recovers and
    records the problem instead of failing.
    """

    severity: str
    message: str
    line: int
    column: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "severity": self.severity,
            "message": self.message,
            "line": self.line,
            "column": self.column,
        }

    def __str__(self) -> str:
        return f"{self.line}:{self.column}: {self.severity}: {self.message}"


@dataclass
class Arg:
    """One argument of a command call.

    ``kind`` is one of:

    ``string``
        A quoted literal; ``value`` holds its content.
    ``number``
        An integer literal, possibly negative and possibly written with
        leading zeros (``01``).  ``value`` holds the integer, ``label`` the
        optional ``_Comment`` suffix (``02_First Player`` -> 2 / "First
        Player").
    ``var``
        A variable reference ``_X`` or ``_X_Comment``.  ``slot`` holds the
        uppercase slot letter, ``label`` the optional comment suffix.
    ``name``
        A bare identifier; in practice always a label name for ``Goto``.
    ``empty``
        An argument position with nothing in it.
    """

    kind: str
    raw: str
    value: Any = None
    slot: str | None = None
    label: str | None = None

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"kind": self.kind, "raw": self.raw}
        if self.value is not None:
            out["value"] = self.value
        if self.slot is not None:
            out["slot"] = self.slot
        if self.label:
            out["label"] = self.label
        return out


@dataclass
class Statement:
    """A command call ``Name (arg, ...);``."""

    name: str
    args: list[Arg]
    line: int
    column: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "node": "statement",
            "name": self.name,
            "args": [a.to_dict() for a in self.args],
            "line": self.line,
        }


@dataclass
class Term:
    """One term of a conditional head: ``op`` is ``>``, ``&`` or ``|``."""

    op: str
    call: Statement

    def to_dict(self) -> dict[str, Any]:
        return {"op": self.op, "call": self.call.to_dict()}


@dataclass
class Conditional:
    """A conditional region ``> pred; [&|pred;] statements [# statements] <``.

    This is a convenience view over what the interpreter really does, which is
    to keep a single boolean "execute" flag over one linear pass: ``>`` assigns
    the flag, ``&``/``|`` fold further predicates into it left to right, ``#``
    inverts it (an ``else``) and ``<`` sets it back to true.  Regions therefore
    cannot nest and are never skipped over -- every statement is parsed, only
    execution is gated.  See ``docs/20-lcl-language.md`` section 2.
    """

    terms: list[Term]
    body: list[Any]
    line: int
    closed: bool = True
    else_body: list[Any] = field(default_factory=list)
    """Statements after a ``#`` inside the region: executed exactly when the
    predicate chain is false."""
    else_line: int | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "node": "conditional",
            "terms": [t.to_dict() for t in self.terms],
            "body": [n.to_dict() for n in self.body],
            "else_body": [n.to_dict() for n in self.else_body],
            "else_line": self.else_line,
            "line": self.line,
            "closed": self.closed,
        }


@dataclass
class TextEntry:
    """A text-resource entry ``%:<index><sep>"<text>";;``."""

    index: int
    text: str
    line: int
    separator: str = ","

    def to_dict(self) -> dict[str, Any]:
        return {
            "node": "text_entry",
            "index": self.index,
            "text": self.text,
            "separator": self.separator,
            "line": self.line,
        }


@dataclass
class Routine:
    """A labelled block of code, terminated by ``[END]``.

    ``name`` is ``None`` for the implicit entry routine that precedes the first
    label -- that is where the standard ``_A``-dispatch table lives.
    """

    name: str | None
    line: int
    body: list[Any] = field(default_factory=list)
    terminator: str | None = None
    """The character that closed the label (``;`` or ``:``); ``None`` for the
    implicit entry routine."""

    def to_dict(self) -> dict[str, Any]:
        return {
            "node": "routine",
            "name": self.name,
            "line": self.line,
            "label_terminator": self.terminator,
            "body": [n.to_dict() for n in self.body],
        }


@dataclass
class Program:
    """A parsed ``.lcl`` file."""

    path: str
    header_line: int | None
    routines: list[Routine] = field(default_factory=list)
    diagnostics: list[Diagnostic] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "node": "program",
            "path": self.path,
            "header_line": self.header_line,
            "routines": [r.to_dict() for r in self.routines],
            "diagnostics": [d.to_dict() for d in self.diagnostics],
        }

    def statements(self) -> Iterator[Statement]:
        """Yield every :class:`Statement`, including conditional predicates."""

        def walk(nodes: list[Any]) -> Iterator[Statement]:
            for node in nodes:
                if isinstance(node, Statement):
                    yield node
                elif isinstance(node, Conditional):
                    for term in node.terms:
                        yield term.call
                    yield from walk(node.body)
                    yield from walk(node.else_body)

        for routine in self.routines:
            yield from walk(routine.body)


class LclSyntaxError(Exception):
    """Raised when a file cannot be parsed at all."""

    def __init__(self, path: str, message: str,
                 line: int, column: int) -> None:
        super().__init__(f"{path}:{line}:{column}: {message}")
        self.path = path
        self.message = message
        self.line = line
        self.column = column


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------


class Parser:
    """Recursive-descent parser over the raw character stream.

    LCL is not line-oriented in principle, but every shipped statement closes
    its parenthesis on the line it opened; the parser does not rely on that.
    Line numbers are tracked only for diagnostics.
    """

    def __init__(self, text: str, path: str = "<memory>") -> None:
        self.text = text
        self.path = path
        self.pos = 0
        self.line = 1
        self.line_start = 0
        self.diagnostics: list[Diagnostic] = []
        #: Set by :meth:`read_string` when a literal runs to the end of its
        #: line. The argument list containing it then stops at that line rather
        #: than hunting for a ``)`` on the following ones -- see
        #: :meth:`parse_arg_list`.
        self.string_ran_off_line = False

    # -- low-level cursor helpers ------------------------------------------

    @property
    def column(self) -> int:
        return self.pos - self.line_start + 1

    def at_end(self) -> bool:
        return self.pos >= len(self.text)

    def peek(self, offset: int = 0) -> str:
        index = self.pos + offset
        return self.text[index] if index < len(self.text) else ""

    def advance(self, count: int = 1) -> str:
        chunk = self.text[self.pos : self.pos + count]
        for char in chunk:
            if char == "\n":
                self.line += 1
                self.line_start = self.pos + 1
            self.pos += 1
        return chunk

    def note(self, severity: str, message: str,
             line: int | None = None, column: int | None = None) -> None:
        self.diagnostics.append(
            Diagnostic(severity, message,
                       self.line if line is None else line,
                       self.column if column is None else column)
        )

    def skip_trivia(self) -> None:
        """Consume whitespace and comments.

        A ``*`` opens a comment that runs to the end of the line.  In the whole
        shipped corpus such a character outside a string literal only ever
        occurs at a token-start position, so treating it as a comment
        introducer wherever the scanner is looking for a token is safe.
        (The interpreter's own comment skipper, ``0x00440130``, likewise runs
        to the next CRLF.)
        """
        while not self.at_end():
            char = self.peek()
            if char in _WHITESPACE:
                self.advance()
            elif char in COMMENT_CHARS:
                while not self.at_end() and self.peek() != "\n":
                    self.advance()
            else:
                return

    def skip_to_line_end(self) -> None:
        while not self.at_end() and self.peek() != "\n":
            self.advance()

    # -- lexical units ------------------------------------------------------

    def read_identifier(self) -> str:
        start = self.pos
        # `?_` is a real command name (§7.1, handler 0x00440D50) and the only
        # one that does not start with a letter or '_'. Nothing else in the
        # corpus puts a '?' at statement position, so accept it only in that
        # exact pair rather than widening the identifier alphabet.
        if self.peek() == "?" and self.text[self.pos + 1:self.pos + 2] == "_":
            self.advance()
        while not self.at_end() and self.peek() in _IDENT_BODY:
            self.advance()
        return self.text[start : self.pos]

    def read_string(self) -> str:
        """Read a ``"``-delimited literal.

        LCL has no escape sequences: a literal ends at the next ``"``.  The
        interpreter's token reader treats a newline inside any token -- string
        literals included -- as a hard error that aborts the program
        (``0x0043ff00``, cases ``'\n'``/``'\r'``).  One shipped file,
        ``WorldDesc/J00.lcl``, contains an unterminated literal and would abort
        there; this parser stops at the end of the line, records a diagnostic
        and continues so the rest of the file stays inspectable.
        """
        assert self.peek() == '"'
        open_line, open_col = self.line, self.column
        self.advance()
        start = self.pos
        # Stop at either half of a CRLF: the corpus is CRLF throughout, and
        # stopping only at "\n" left a trailing "\r" inside the captured value.
        while not self.at_end() and self.peek() not in ('"', "\n", "\r"):
            self.advance()
        value = self.text[start : self.pos]
        if self.peek() == '"':
            self.advance()
        else:
            self.note("warning", "unterminated string literal",
                      open_line, open_col)
            self.string_ran_off_line = True
        return value

    def read_bracket_keyword(self) -> str | None:
        """Read ``[NAME]`` and return ``NAME`` uppercased, or ``None``."""
        assert self.peek() == "["
        save = (self.pos, self.line, self.line_start)
        self.advance()
        name = self.read_identifier()
        if self.peek() == "]" and name:
            self.advance()
            return name.upper()
        self.pos, self.line, self.line_start = save
        return None

    # -- argument parsing ---------------------------------------------------

    def parse_arg_list(self) -> list[Arg]:
        """Parse ``( arg , ... )`` with the cursor on ``(``."""
        assert self.peek() == "("
        self.advance()
        self.string_ran_off_line = False
        args: list[Arg] = []
        while True:
            self.skip_trivia()
            if self.at_end():
                self.note("error", "unterminated argument list")
                return args
            if self.peek() == ")":
                self.advance()
                # `Foo()` yields no arguments; `Foo(a,)` yields a trailing
                # empty one, which the loop below already appended.
                return args
            args.append(self.parse_arg())
            if self.string_ran_off_line:
                # A literal ran to the end of its line, so this list's ')' was
                # swallowed by it. Anything past the newline belongs to the
                # *next* statement: stop here rather than skipping trivia and
                # treating that statement's first character as filler. That is
                # how `WorldDesc/J00.lcl` used to lose the whole of line 24
                # (object `L009EF00.3DI`) behind a mere warning.
                self.note("error", "argument list abandoned at end of line "
                                   "after an unterminated string literal")
                return args
            self.skip_trivia()
            if self.peek() == ",":
                self.advance()
                continue
            if self.peek() == ")":
                self.advance()
                return args
            if self.at_end():
                self.note("error", "unterminated argument list")
                return args
            # Unexpected filler between arguments: consume one character and
            # keep going so a single typo cannot lose the rest of the file.
            # ``_O_050``/``_S_074`` type ';' instead of ',' here.  The
            # interpreter is unbothered: ';' only ends a parameter list when
            # the scanner is sitting on it at the top of an iteration, and
            # here it was already consumed as the previous token's
            # terminator.  Same argument list either way.
            self.note("warning",
                      f"unexpected {self.peek()!r} in argument list "
                      f"(accepted by the interpreter as a separator)")
            self.advance()

    def parse_arg(self) -> Arg:
        """Parse a single argument, up to the next ``,`` or ``)``."""
        if self.peek() == '"':
            value = self.read_string()
            return Arg(kind="string", raw=f'"{value}"', value=value)

        start = self.pos
        while not self.at_end() and self.peek() not in ",)\n":
            self.advance()
        raw = self.text[start : self.pos]
        return classify_arg(raw)

    # -- statements ---------------------------------------------------------

    def parse_statement(self) -> Statement | None:
        """Parse ``Name (args);``; the cursor is on the first name char."""
        line, column = self.line, self.column
        name = self.read_identifier()
        if not name:
            return None
        self.skip_trivia()
        args: list[Arg] = []
        if self.peek() == "(":
            args = self.parse_arg_list()
            if self.string_ran_off_line:
                # The statement is already known to be malformed and its ';'
                # was consumed into the runaway literal. Resynchronise on the
                # line boundary without looking for one, so the next line's
                # first character is not mistaken for a terminator.
                self.string_ran_off_line = False
                return Statement(name=name, args=args, line=line, column=column)
        else:
            self.note("warning", f"command {name!r} without argument list",
                      line, column)
        self.skip_trivia()
        if self.peek() == ";":
            self.advance()
        else:
            self.note("warning", f"missing ';' after {name!r}", line, column)
        return Statement(name=name, args=args, line=line, column=column)

    def parse_text_entry(self) -> TextEntry | None:
        """Parse ``%:<index><sep>"<text>";;`` with the cursor on ``%``.

        Three separators occur in the corpus between index and text (``,``,
        ``:`` and ``;``); all are accepted and recorded.
        """
        line = self.line
        self.advance()  # '%'
        self.skip_trivia()
        if self.peek() == ":":
            self.advance()
        digits_start = self.pos
        while not self.at_end() and self.peek() in _DIGITS:
            self.advance()
        raw_index = self.text[digits_start : self.pos]
        if not raw_index:
            self.note("error", "text entry without index", line)
            self.skip_to_line_end()
            return None
        separator = ","
        self.skip_trivia()
        if self.peek() in ",:;":
            separator = self.advance()
        self.skip_trivia()
        if self.peek() != '"':
            self.note("error", "text entry without string literal", line)
            self.skip_to_line_end()
            return None
        text = self.read_string()
        # The terminator is ";;", but Txtmod_b.lcl separates the two semicolons
        # with a tab, so allow trivia between them.
        while True:
            save = (self.pos, self.line, self.line_start)
            self.skip_trivia()
            if self.peek() == ";":
                self.advance()
                continue
            self.pos, self.line, self.line_start = save
            break
        return TextEntry(index=int(raw_index, 10), text=text,
                         line=line, separator=separator)

    # -- top level ----------------------------------------------------------

    def parse(self) -> Program:
        """Parse the whole file into a :class:`Program`."""
        header_line = self._skip_to_header()
        program = Program(path=self.path, header_line=header_line)

        current = Routine(name=None, line=header_line or 1)
        program.routines.append(current)
        open_block: Conditional | None = None

        in_else = False

        def sink() -> list[Any]:
            if open_block is None:
                return current.body
            return open_block.else_body if in_else else open_block.body

        while True:
            self.skip_trivia()
            if self.at_end():
                break
            char = self.peek()
            line, column = self.line, self.column

            if char == "[":
                keyword = self.read_bracket_keyword()
                if keyword == "END":
                    if open_block is not None:
                        open_block.closed = False
                        self.note("warning",
                                  "'[END]' inside an unclosed conditional",
                                  line, column)
                        open_block = None
                    current = Routine(name=None, line=self.line)
                    program.routines.append(current)
                    continue
                if keyword == "LCL":
                    self.note("warning", "duplicate '[LCL]' header",
                              line, column)
                    continue
                if keyword is None:
                    self.note("warning", "stray '['", line, column)
                    self.advance()
                    continue
                self.note("warning", f"unknown directive '[{keyword}]'",
                          line, column)
                continue

            if char == ELSE_CHAR:
                # The interpreter inverts the condition flag here; inside a
                # region that is exactly an `else`.
                self.advance()
                if open_block is None:
                    self.note("warning",
                              "'#' outside a conditional region inverts the "
                              "flag, disabling every statement up to the next "
                              "'>', '<' or '#'",
                              line, column)
                elif in_else:
                    self.note("warning", "second '#' in one region",
                              line, column)
                else:
                    in_else = True
                    open_block.else_line = line
                continue

            if char == ":":
                self.advance()
                name = self.read_identifier()
                terminator = None
                if self.peek() in LABEL_TERMINATORS:
                    terminator = self.advance()
                else:
                    self.note("warning", f"label {name!r} without terminator",
                              line, column)
                if not name:
                    self.note("error", "empty label name", line, column)
                    continue
                if open_block is not None:
                    # A label does not touch the condition flag either.
                    open_block.closed = False
                    self.note("warning",
                              "label inside an unclosed conditional",
                              line, column)
                    open_block = None
                    in_else = False
                if current.name is None and not current.body:
                    # Reuse the routine slot opened by the preceding [END].
                    current.name = name
                    current.line = line
                    current.terminator = terminator
                else:
                    current = Routine(name=name, line=line,
                                      terminator=terminator)
                    program.routines.append(current)
                continue

            if char == ">":
                self.advance()
                self.skip_trivia()
                call = self.parse_statement()
                if call is None:
                    self.note("error", "'>' without a condition", line, column)
                    continue
                if open_block is not None:
                    # Seen in _C_120/_C_128/_C_150/_C_152/_C_154/_O_060: a '<'
                    # was forgotten.  Harmless at run time -- '>' assigns the
                    # condition flag outright -- but it is still an authoring
                    # slip, so it is reported.
                    open_block.closed = False
                    self.note("warning",
                              "new conditional opened while one is still "
                              "open (missing '<'; harmless, '>' resets the "
                              "condition flag)",
                              line, column)
                block = Conditional(terms=[Term(">", call)], body=[],
                                    line=line)
                current.body.append(block)
                open_block = block
                in_else = False
                continue

            if char in COMBINATORS:
                op = self.advance()
                self.skip_trivia()
                call = self.parse_statement()
                if call is None:
                    self.note("error", f"'{op}' without a condition",
                              line, column)
                    continue
                if open_block is None:
                    # _C_114.lcl:59.  Not fatal at run time: the flag is true
                    # after the preceding '<', so '&pred' behaves as '>pred'
                    # and '|pred' as an unconditional region.
                    self.note("warning",
                              f"'{op}' outside a conditional region "
                              f"(folds into the standing condition flag)",
                              line, column)
                    continue
                if open_block.body:
                    self.note("warning",
                              f"'{op}' term after the body started",
                              line, column)
                open_block.terms.append(Term(op, call))
                continue

            if char == "<":
                self.advance()
                if open_block is None:
                    # Seen once, in _C_169: a surplus '<'.  A no-op at run
                    # time: it just sets the already-true flag to true.
                    self.note("warning",
                              "'<' without an open conditional (no-op)",
                              line, column)
                else:
                    open_block = None
                    in_else = False
                continue

            if char == TEXT_ENTRY_CHAR:
                entry = self.parse_text_entry()
                if entry is not None:
                    sink().append(entry)
                continue

            if char == ";":
                self.note("warning", "stray ';'", line, column)
                self.advance()
                continue

            if char in _IDENT_START or (
                    char == "?" and self.text[self.pos + 1:self.pos + 2] == "_"):
                statement = self.parse_statement()
                if statement is not None:
                    sink().append(statement)
                continue

            raise LclSyntaxError(self.path, f"unexpected character {char!r}",
                                 line, column)

        if open_block is not None:
            open_block.closed = False
            self.note("warning", "conditional region not closed by '<'")

        # Drop the trailing empty routine left behind by the final [END].
        while (program.routines and program.routines[-1].name is None
               and not program.routines[-1].body
               and len(program.routines) > 1):
            program.routines.pop()

        program.diagnostics = self.diagnostics
        return program

    def _skip_to_header(self) -> int | None:
        """Advance past the ``[LCL]`` header, returning its line number.

        Several files carry a banner comment before the header.  Everything
        before ``[LCL]`` is ignored, matching the interpreter's search for the
        ``[LCL]`` marker.
        """
        index = self.text.find("[LCL]")
        if index < 0:
            self.note("error", "missing '[LCL]' header", 1, 1)
            return None
        self.advance(index + len("[LCL]"))
        return self.line


def classify_arg(raw: str) -> Arg:
    """Classify a raw (unquoted) argument lexeme.

    This mirrors the interpreter's parameter classifier at ``0x0043fc90``:

    * a token starting with ``_`` is a variable reference; only the *second*
      character matters and the slot index is ``ord(c) - ord('A')``, valid for
      0..27;
    * a token starting with a character below ``':'`` (i.e. a digit, ``+`` or
      ``-``) is a number, converted with ``atoi`` -- so leading zeros are
      decimal, not octal, and everything from the first non-digit on is
      ignored;
    * anything else is stored in the *string* parameter array, which is how
      ``Goto (Label)`` passes its label name.

    Numeric and variable arguments may carry a trailing ``_Comment``
    annotation that the interpreter ignores; it is preserved as ``label``.
    """
    text = raw.strip()
    if not text:
        return Arg(kind="empty", raw=raw)

    if text[0] == "_":
        rest = text[1:]
        if rest and rest[0].isalpha():
            slot = rest[0]
            label = rest[1:].lstrip("_") or None
            return Arg(kind="var", raw=text, slot=slot, label=label)
        return Arg(kind="name", raw=text, value=text)

    sign = 1
    body = text
    if body[0] in "+-":
        sign = -1 if body[0] == "-" else 1
        body = body[1:]
    if body and body[0] in _DIGITS:
        cut = 0
        while cut < len(body) and body[cut] in _DIGITS:
            cut += 1
        digits, label = body[:cut], body[cut:]
        label = label.lstrip("_").strip() or None
        return Arg(kind="number", raw=text, value=sign * int(digits, 10),
                   label=label)

    return Arg(kind="name", raw=text, value=text)


# ---------------------------------------------------------------------------
# Front end
# ---------------------------------------------------------------------------


def parse_text(text: str, path: str = "<memory>") -> Program:
    """Parse already-decoded LCL source."""
    return Parser(text, path).parse()


def parse_bytes(data: bytes, path: str = "<memory>") -> Program:
    """Decode (if needed) and parse a raw ``.lcl`` byte buffer."""
    text = decode(data).decode(SOURCE_ENCODING, errors="replace")
    return parse_text(text, path)


def parse_file(path: str) -> Program:
    """Read, decode and parse a ``.lcl`` file from disk."""
    with open(path, "rb") as handle:
        return parse_bytes(handle.read(), path)


def dump(program: Program, stream=sys.stdout) -> None:
    """Write a compact human-readable rendering of a parsed program."""
    print(f"# {program.path}  (header line {program.header_line})",
          file=stream)
    for routine in program.routines:
        name = routine.name or "<entry>"
        print(f"\n:{name};   # line {routine.line}", file=stream)
        _dump_nodes(routine.body, 1, stream)
    if program.diagnostics:
        print("\n# diagnostics", file=stream)
        for diag in program.diagnostics:
            print(f"#   {diag}", file=stream)


def _dump_nodes(nodes: list[Any], depth: int, stream) -> None:
    pad = "    " * depth
    for node in nodes:
        if isinstance(node, Statement):
            args = ", ".join(a.raw for a in node.args)
            print(f"{pad}{node.name}({args});", file=stream)
        elif isinstance(node, TextEntry):
            print(f'{pad}%:{node.index:03d},"{node.text}";;', file=stream)
        elif isinstance(node, Conditional):
            for term in node.terms:
                args = ", ".join(a.raw for a in term.call.args)
                print(f"{pad}{term.op} {term.call.name}({args});", file=stream)
            _dump_nodes(node.body, depth + 1, stream)
            if node.else_body or node.else_line is not None:
                print(f"{pad}#   # else", file=stream)
                _dump_nodes(node.else_body, depth + 1, stream)
            tail = "" if node.closed else "   # unclosed"
            print(f"{pad}<{tail}", file=stream)


def is_script(path: str) -> bool:
    """Whether the file is an LCL script at all, i.e. carries an ``[LCL]`` header.

    `DATA/Version.gcl` shares the extension but holds a bare version string.
    Classifying it here keeps it out of both the pass and the fail count
    instead of letting it look like a parser regression.
    """
    with open(path, "rb") as fh:
        return b"[LCL]" in decode(fh.read(4096))


def run_check(roots: list[str], show_stats: bool = False) -> int:
    """Parse every script below *roots*; report failures and statistics."""
    total = 0
    failed: list[tuple[str, str]] = []
    warned: list[tuple[str, Diagnostic]] = []
    not_scripts: list[str] = []
    commands: dict[str, dict[str, Any]] = {}

    for path in iter_inputs(roots):
        if not is_script(path):
            not_scripts.append(path)
            continue
        total += 1
        LOG.debug("parsing %s", path)
        try:
            program = parse_file(path)
        except LclSyntaxError as exc:
            failed.append((path, str(exc)))
            continue
        except Exception as exc:  # pragma: no cover - defensive
            failed.append((path, f"{type(exc).__name__}: {exc}"))
            continue
        for diag in program.diagnostics:
            warned.append((path, diag))
        for statement in program.statements():
            record = commands.setdefault(
                statement.name, {"count": 0, "argc": set(), "files": set()})
            record["count"] += 1
            record["argc"].add(len(statement.args))
            record["files"].add(os.path.basename(path))

    if not total:
        print(f"no LCL script found under {roots!r} -- nothing was checked, "
              f"which is a failure, not a pass")
        return 1
    print(f"parsed {total - len(failed)}/{total} file(s)")
    for path in not_scripts:
        print(f"skipped {os.path.basename(path)}: no '[LCL]' header, "
              f"not a script")
    for path, message in failed:
        print(f"FAIL {path}: {message}")
    if warned:
        print(f"{len(warned)} diagnostic(s) in "
              f"{len({p for p, _ in warned})} file(s):")
        for path, diag in warned:
            print(f"  {os.path.basename(path)}:{diag}")
    if show_stats:
        print("\ncommand usage:")
        for name, record in sorted(commands.items(),
                                   key=lambda kv: -kv[1]["count"]):
            argc = ",".join(str(n) for n in sorted(record["argc"]))
            print(f"{record['count']:6d}  {name:<24} argc=[{argc}]  "
                  f"files={len(record['files'])}")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("inputs", nargs="+",
                        help="files or directories holding .lcl scripts")
    parser.add_argument("--json", action="store_true",
                        help="emit the AST as JSON")
    parser.add_argument("--check", action="store_true",
                        help="corpus mode: parse every .lcl below the inputs")
    parser.add_argument("--stats", action="store_true",
                        help="with --check, print command usage statistics")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format="%(levelname)s: %(message)s")

    if args.check:
        return run_check(args.inputs, show_stats=args.stats)

    programs = [parse_file(path) for path in iter_inputs(args.inputs)]
    if args.json:
        payload = [p.to_dict() for p in programs]
        json.dump(payload[0] if len(payload) == 1 else payload,
                  sys.stdout, indent=2)
        sys.stdout.write("\n")
    else:
        for program in programs:
            dump(program)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

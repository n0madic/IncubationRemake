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
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib.lcl import (Conditional, Diagnostic, LclSyntaxError, Program,  # noqa: E402
                        Statement, TextEntry, is_script, iter_inputs,
                        parse_file)

LOG = logging.getLogger("lcl.parse")


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

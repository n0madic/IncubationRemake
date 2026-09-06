#!/usr/bin/env python3
"""Drive a running remake build over its agent control server (docs/92 7.16).

Start the game with a port and it listens on the loopback address:

    godot --path godot -- --mission=_C_140 --agent-port=8787

Then, from anywhere on the same machine:

    python3 tools/agent_client.py wait-up
    python3 tools/agent_client.py state
    python3 tools/agent_client.py shot /tmp/before.png
    python3 tools/agent_client.py cmd "click_unit 0" idle
    python3 tools/agent_client.py cmd quit

`state`, `shot` and `help` are answered in the frame they arrive, **including
while a `cmd` batch is still running** -- which is the whole reason the socket
replaced the command-file directory this tool has no memory of. Only one batch
runs at a time; a second `cmd` while one is in flight is refused with 409.

Nothing here is required: the protocol is plain HTTP and `curl` speaks it.

Exit codes:
    0  the request was answered
    1  the server answered with an error status
    2  nothing is listening, or the request timed out
    3  a command batch is already running (409)
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_PORT = 8787
DEFAULT_HOST = "127.0.0.1"

#: A batch may legitimately run for minutes -- `idle 600` alone is ten seconds
#: at 60 fps, and a scenario is many of those.
COMMAND_TIMEOUT = 600.0

#: A read is answered in the frame it lands, so a slow one means trouble.
READ_TIMEOUT = 30.0

#: `wait-up` polls at this period, and each attempt gives up quickly: a
#: refused connection is "not listening yet", not a failure.
POLL_PERIOD = 0.25
POLL_TIMEOUT = 2.0

EXIT_OK = 0
EXIT_HTTP = 1
EXIT_UNREACHABLE = 2
EXIT_BUSY = 3

log = logging.getLogger("agent_client")


class Unreachable(Exception):
    """Nothing is listening, or the answer never came."""


class Refused(Exception):
    """The server answered with an error status."""

    def __init__(self, status: int, body: bytes) -> None:
        super().__init__("HTTP %d" % status)
        self.status = status
        self.body = body


def request(
    host: str,
    port: int,
    path: str,
    timeout: float,
    body: bytes | None = None,
    content_type: str = "application/json",
) -> tuple[bytes, dict[str, str]]:
    """One request. Returns the body and the response headers."""
    url = "http://%s:%d%s" % (host, port, path)
    headers = {"Accept": "*/*"}
    if body is not None:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=body, headers=headers,
                                 method="POST" if body is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as answer:
            return answer.read(), dict(answer.headers)
    except urllib.error.HTTPError as exc:
        raise Refused(exc.code, exc.read()) from exc
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        raise Unreachable(str(exc)) from exc


def wait_up(host: str, port: int, timeout: float) -> dict:
    """Polls `/health` until the game has a world or a screen up.

    A refused connection is not an error here: the process may not have opened
    the socket yet. What is waited for is `booted`, because a click sent the
    moment the port answers would otherwise run against no world.
    """
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        try:
            raw, _headers = request(host, port, "/health", POLL_TIMEOUT)
            health = json.loads(raw)
            if health.get("booted"):
                return health
            last = "listening, not booted"
        except Unreachable as exc:
            last = str(exc)
        except Refused as exc:
            last = "HTTP %d" % exc.status
        time.sleep(POLL_PERIOD)
    raise Unreachable("no booted game on %s:%d after %.0f s (%s)"
                      % (host, port, timeout, last))


def read_lines(values: list[str]) -> bytes:
    """The command body: argv lines as JSON, or `-` for stdin as text."""
    if values == ["-"]:
        return sys.stdin.read().encode("utf-8")
    return json.dumps({"lines": values}).encode("utf-8")


def show(document: object, compact: bool) -> None:
    if compact:
        print(json.dumps(document, separators=(",", ":")))
        return
    print(json.dumps(document, indent=2, sort_keys=False))


def run(args: argparse.Namespace) -> int:
    host: str = args.host
    port: int = args.port

    if args.command == "wait-up":
        show(wait_up(host, port, args.timeout), args.json)
        return EXIT_OK

    if args.command == "state":
        raw, _headers = request(host, port, "/state", READ_TIMEOUT)
        document = json.loads(raw)
        show(document if args.json else document.get("state", {}), args.json)
        return EXIT_OK

    if args.command == "help":
        raw, _headers = request(host, port, "/help", READ_TIMEOUT)
        document = json.loads(raw)
        if args.json:
            show(document, True)
            return EXIT_OK
        for verb, line in sorted(document.get("verbs", {}).items()):
            print("%-14s %s" % (verb, line))
        return EXIT_OK

    if args.command == "shot":
        path = "/shot"
        if args.save:
            path += "?save=" + urllib.parse.quote(args.save)
        raw, headers = request(host, port, path, READ_TIMEOUT)
        with open(args.path, "wb") as handle:
            handle.write(raw)
        print(args.path)
        filed = headers.get("X-Agent-Shot")
        if filed:
            print(filed)
        return EXIT_OK

    # `cmd`
    body = read_lines(args.lines)
    content = "application/json" if args.lines != ["-"] else "text/plain"
    raw, _headers = request(host, port, "/command", args.timeout, body, content)
    show(json.loads(raw), args.json)
    return EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog="Exit codes: 0 ok, 1 an error status, 2 unreachable, 3 busy.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default=DEFAULT_HOST,
                        help="default %(default)s; the server binds loopback")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="the number --agent-port= was given "
                             "(default %(default)s)")
    # `--json` is a subcommand flag and **only** a subcommand flag. Declared on
    # both parsers, the subparser's own `False` default silently overwrites a
    # `--json` given before the subcommand, which is worse than not having it.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true",
                        help="print the whole answer as one compact line")
    subs = parser.add_subparsers(dest="command", required=True)

    up = subs.add_parser("wait-up", parents=[common],
                         help="poll /health until a world or a screen is up")
    up.add_argument("--timeout", type=float, default=120.0,
                    help="seconds to wait (default %(default)s)")

    subs.add_parser("state", parents=[common],
                    help="the snapshot, answered even mid-command")

    shot = subs.add_parser("shot", parents=[common],
                           help="write the current frame as a PNG")
    shot.add_argument("path", help="where to write the PNG")
    shot.add_argument("--save", default="",
                      help="also file it under --agent-dir= as NAME.png")

    subs.add_parser("help", parents=[common],
                    help="the server's own verb table")

    cmd = subs.add_parser("cmd", parents=[common],
                          help="run a batch of verbs")
    cmd.add_argument("lines", nargs="+",
                     help="one verb per argument, or a single - to read stdin")
    cmd.add_argument("--timeout", type=float, default=COMMAND_TIMEOUT,
                     help="seconds to wait for the batch (default %(default)s)")
    return parser


def main(argv: list[str]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    args = build_parser().parse_args(argv)
    try:
        return run(args)
    except Refused as exc:
        if exc.status == 409:
            log.error("busy: a command batch is already running")
            return EXIT_BUSY
        log.error("HTTP %d: %s", exc.status,
                  exc.body.decode("utf-8", "replace").strip())
        return EXIT_HTTP
    except Unreachable as exc:
        log.error("cannot reach %s:%d -- %s", args.host, args.port, exc)
        return EXIT_UNREACHABLE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

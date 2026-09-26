#!/usr/bin/env bash
# The suites inside the exported build, gated.
#
#     bash godot/run_export_tests.sh [godot-binary]
#
# `run_tests.sh` runs the suites in the editor's headless engine.  The `macOS
# Tests` preset runs the same suites inside a real `.app` against the data the
# app carries in its own PCK, `res://data/cache` -- the cache the editor run
# reads too (`make data`; docs/92 section 10.4: "demonstrated in an exported
# build") -- and it
# prints the same tail -- but until this script it was started by hand and
# read by eye, so a leak none of the eight campaign screens makes would have
# passed unread (docs/101 section 13.9).  This stages the fixtures, exports
# the preset, runs the app under a timeout and applies the three gates of
# `test_gates.sh` to what it printed.
#
# Two things to know:
#
#   * The export needs a **window**: `main.gd` draws the harness caption and
#     quits through the scene tree, and `--headless` is not an export-time
#     option of a windowed preset.  A `timeout` bounds the run instead.
#   * `--no-export` reuses the app already at `export/Incubation-remake-tests.app`
#     -- for a re-read of the same build, never for a build of a changed tree,
#     because the fixtures it carries are the ones staged when it was exported.
#   * The exporter writes `export/Incubation-remake-tests.command` beside the
#     app and leaves the shipping preset's app and wrapper alone (measured
#     2026-09-13; docs/97 section 42.2's removal is of the *same* preset's
#     wrapper on re-export).
#
# Environment: `RUN_TESTS_TIMEOUT` in seconds (default 600; the whole run,
# export included, took 25 s on 2026-09-13).  The export is always debug --
# see the note by the export call; `EXPORT_MODE` is deliberately not read.
set -u

resolve_godot() {
    for candidate in "$@"; do
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        local found
        found="$(command -v "$candidate" 2>/dev/null)" || continue
        if [ -f "$found" ] && [ -x "$found" ]; then
            printf '%s\n' "$found"
            return 0
        fi
    done
    return 1
}

EXPORT=1
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-export) EXPORT=0 ;;
        *) ARGS+=("$arg") ;;
    esac
done

GODOT="$(resolve_godot "${ARGS[0]:-}" "${GODOT:-}" \
    /Applications/Godot.app/Contents/MacOS/Godot godot4 godot)" || {
    echo "run_export_tests.sh: no Godot binary found; pass one as the first argument" >&2
    exit 1
}

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=test_gates.sh
. "$HERE/test_gates.sh"

PRESET="macOS Tests"
APP="$HERE/export/Incubation-remake-tests.app"
# The bundle's executable is named after the project, not the preset.
BINARY="$APP/Contents/MacOS/Incubation - Remake"

TIMEOUT=""
for t in timeout gtimeout; do
    if command -v "$t" >/dev/null 2>&1; then TIMEOUT="$t"; break; fi
done
if [ -z "$TIMEOUT" ]; then
    echo "run_export_tests.sh: no timeout(1) or gtimeout(1); the run would be unbounded" >&2
    exit 1
fi

if [ "$EXPORT" = 1 ]; then
    stage_fixtures "$REPO" "$HERE"
    # The import pass registers `class_name` globals and imports the fixtures
    # the export is about to pack; its stderr (missing optional resources) is
    # not the gate.
    "$GODOT" --headless --path "$HERE" --import >/dev/null 2>&1
    mkdir -p "$HERE/export"
    # **Always a debug export, never release.** The whole reason this run
    # exists is the leak gate of docs/101 section 13.9, and the lines it
    # greps for -- `ERROR:`/`WARNING:` GDScript diagnostics and the ObjectDB /
    # RID leak tracker -- are compiled out of a release template.  A release
    # export would run the suites, print the sentinel and pass while leaking,
    # which is exactly the silence this run is here to break.  So the mode is
    # fixed and `EXPORT_MODE` does not reach it; a release build is the
    # shipping presets' job (`make build-*`), not the test preset's.
    rm -rf "$APP"
    if ! "$GODOT" --headless --path "$HERE" \
            --export-debug "$PRESET" \
            "export/Incubation-remake-tests.app"; then
        echo "run_export_tests.sh: the export failed" >&2
        exit 1
    fi
fi

if [ ! -x "$BINARY" ]; then
    echo "run_export_tests.sh: no executable at $BINARY" >&2
    exit 1
fi

# The app's own exit status is `TestRunner.finish_run`'s, through
# `get_tree().quit(code)`, so it means something -- but the sentinel gate stays,
# for the same reason it does in the editor run: a build whose main script
# never loaded also exits 0.  124 is timeout(1)'s own code.
OUT="$("$TIMEOUT" "${RUN_TESTS_TIMEOUT:-600}" "$BINARY" 2>&1)"
STATUS=$?
echo "$OUT"
if [ "$STATUS" = 124 ]; then
    echo "run_export_tests.sh: the export did not quit within ${RUN_TESTS_TIMEOUT:-600} s" >&2
    exit 1
fi

gate_run "$OUT" run_export_tests.sh || exit 1
if [ "$STATUS" != 0 ]; then
    echo "run_export_tests.sh: the export exited $STATUS" >&2
    exit 1
fi
exit 0

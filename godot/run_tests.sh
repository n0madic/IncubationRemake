#!/usr/bin/env bash
# Headless test runner for the slice.
#
#     bash godot/run_tests.sh [godot-binary]
#
# Two things this wrapper exists for:
#
#   * `class_name` globals are only registered from .godot/global_script_class_cache.cfg,
#     which an import pass writes; a bare `--script` run cannot see them.
#   * Godot exits 0 even when the main script fails to load, so the exit status
#     alone cannot distinguish a passing run from a run that never started.  The
#     sentinel line decides.
#
# The fixture staging and the three gates -- runtime errors, leaks, the
# sentinel -- live in `test_gates.sh`, shared with `run_export_tests.sh`, which
# runs the same suites inside the `macOS Tests` export.
set -u

# `-x` is true for a directory, and this repository has one named `godot`, so
# resolution goes through `command -v` and an explicit file test only.
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

GODOT="$(resolve_godot "${1:-}" "${GODOT:-}" \
    /Applications/Godot.app/Contents/MacOS/Godot godot4 godot)" || {
    echo "run_tests.sh: no Godot binary found; pass one as the first argument" >&2
    exit 1
}

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=test_gates.sh
. "$HERE/test_gates.sh"

stage_fixtures "$REPO" "$HERE"

# The import pass reports missing optional resources on stderr; it is not the gate.
"$GODOT" --headless --path "$HERE" --import >/dev/null 2>&1

# A GDScript error inside _initialize leaves the SceneTree spinning instead of
# exiting, so the run is bounded.  A timeout is a failure like any other.
TIMEOUT=""
for t in timeout gtimeout; do
    if command -v "$t" >/dev/null 2>&1; then TIMEOUT="$t"; break; fi
done
if [ -n "$TIMEOUT" ]; then
    OUT="$("$TIMEOUT" "${RUN_TESTS_TIMEOUT:-300}" \
        "$GODOT" --headless --path "$HERE" --script res://tests/main.gd 2>&1)"
else
    OUT="$("$GODOT" --headless --path "$HERE" --script res://tests/main.gd 2>&1)"
fi
echo "$OUT"

gate_run "$OUT" run_tests.sh

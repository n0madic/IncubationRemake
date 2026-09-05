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

# The fixtures live outside res:// because they are derived from Blue Byte data
# and are gitignored; res://generated/ is gitignored too, so they are copied in
# rather than referenced.  A missing one makes its suite report the gap; it
# never makes the run silently smaller.
mkdir -p "$HERE/generated/movemap"
for name in synthetic slice native allowance; do
    src="$REPO/tests/fixtures/movemap/cases_$name.json"
    # The destination is removed first.  Copying only when the source exists
    # left the previous run's copy in place, so a deleted or not-regenerated
    # fixture was silently validated against stale data instead of reporting
    # the gap -- which is the opposite of what the comment above promises.
    rm -f "$HERE/generated/movemap/$name.json"
    [ -f "$src" ] && cp "$src" "$HERE/generated/movemap/$name.json"
done

# The turn's native cases, on the same terms: removed first, copied only if
# present, and the suite reports the gap rather than the run shrinking.
mkdir -p "$HERE/generated/turn"
rm -f "$HERE/generated/turn/turn.json"
[ -f "$REPO/tests/fixtures/turn/cases_turn.json" ] \
    && cp "$REPO/tests/fixtures/turn/cases_turn.json" \
          "$HERE/generated/turn/turn.json"
rm -f "$HERE/generated/turn/handover.json"
[ -f "$REPO/tests/fixtures/turn/cases_handover.json" ] \
    && cp "$REPO/tests/fixtures/turn/cases_handover.json" \
          "$HERE/generated/turn/handover.json"

# The campaign cases, on the same terms.  `test_campaign.gd` reads this file
# for what the rules must come out as and the published cache for the location
# graph, so a missing fixture makes the suite report the gap rather than the
# run quietly shrinking.
mkdir -p "$HERE/generated/campaign"
rm -f "$HERE/generated/campaign/campaign.json"
[ -f "$REPO/tests/fixtures/campaign/cases_campaign.json" ] \
    && cp "$REPO/tests/fixtures/campaign/cases_campaign.json" \
          "$HERE/generated/campaign/campaign.json"

# The AI replay cases, on the same terms.
mkdir -p "$HERE/generated/ai"
rm -f "$HERE/generated/ai/ai.json"
[ -f "$REPO/tests/fixtures/ai/cases_ai.json" ] \
    && cp "$REPO/tests/fixtures/ai/cases_ai.json" \
          "$HERE/generated/ai/ai.json"

# The Charisma pose cases, on the same terms again. The suite reads the
# published cache for the bodies themselves and this file for what the pose
# must come out as, so a missing fixture makes the suite report the gap
# rather than quietly checking nothing.
mkdir -p "$HERE/generated/charisma"
rm -f "$HERE/generated/charisma/pose.json"
[ -f "$REPO/tests/fixtures/charisma/cases_pose.json" ] \
    && cp "$REPO/tests/fixtures/charisma/cases_pose.json" \
          "$HERE/generated/charisma/pose.json"

# The LCL replay cases, on the same terms again.
mkdir -p "$HERE/generated/lcl"
rm -f "$HERE/generated/lcl/lcl.json"
[ -f "$REPO/tests/fixtures/lcl/cases_lcl.json" ] \
    && cp "$REPO/tests/fixtures/lcl/cases_lcl.json" \
          "$HERE/generated/lcl/lcl.json"

# The sound-layer and blob cases, on the same terms again.  Both are produced
# by a Python model that `--check` has anchored against the binary, and both
# suites fail rather than shrink when their fixture is not there.
mkdir -p "$HERE/generated/sound"
rm -f "$HERE/generated/sound/sound.json"
[ -f "$REPO/tests/fixtures/sound/cases_sound.json" ] \
    && cp "$REPO/tests/fixtures/sound/cases_sound.json" \
          "$HERE/generated/sound/sound.json"

mkdir -p "$HERE/generated/blob"
rm -f "$HERE/generated/blob/blob.json"
[ -f "$REPO/tests/fixtures/blob/cases_blob.json" ] \
    && cp "$REPO/tests/fixtures/blob/cases_blob.json" \
          "$HERE/generated/blob/blob.json"
rm -f "$HERE/generated/blob/native.json"
[ -f "$REPO/tests/fixtures/blob/cases_native.json" ] \
    && cp "$REPO/tests/fixtures/blob/cases_native.json" \
          "$HERE/generated/blob/native.json"

# The presentation's death-creator cases, on the same terms: every record
# the engine left for the seven-plus-three death creators, replayed by the
# GDScript programs.
mkdir -p "$HERE/generated/presentation"
rm -f "$HERE/generated/presentation/death.json"
[ -f "$REPO/tests/fixtures/presentation/cases_death.json" ] \
    && cp "$REPO/tests/fixtures/presentation/cases_death.json" \
          "$HERE/generated/presentation/death.json"
rm -f "$HERE/generated/presentation/special.json"
[ -f "$REPO/tests/fixtures/presentation/cases_special.json" ] \
    && cp "$REPO/tests/fixtures/presentation/cases_special.json" \
          "$HERE/generated/presentation/special.json"
rm -f "$HERE/generated/presentation/idle.json"
[ -f "$REPO/tests/fixtures/presentation/cases_idle.json" ] \
    && cp "$REPO/tests/fixtures/presentation/cases_idle.json" \
          "$HERE/generated/presentation/idle.json"

# The battle interface's tables (docs/43), read out of the binary and the
# plate by `hud_tables.py --emit-cases`; `test_hud.gd` fails without them.
mkdir -p "$HERE/generated/hud"
rm -f "$HERE/generated/hud/hud.json"
[ -f "$REPO/tests/fixtures/hud/cases_hud.json" ] \
    && cp "$REPO/tests/fixtures/hud/cases_hud.json" \
          "$HERE/generated/hud/hud.json"

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

# A GDScript runtime error does not stop the script and does not fail a check:
# it prints to stderr and execution carries on with a null or a default.  The
# suites stayed green for a whole run that way, while `UnitTypeTable` was
# silently answering `fp_max` with nothing at all.  So the error text is a
# failure in its own right, independent of the sentinel.
#
# `tests/fixtures/violations/` is expected to fail to load -- that is its
# entire purpose -- and it is the one exemption.  The path is not on the error
# line but on the `at:` line under it, so the pair has to be read together;
# filtering the error line alone matched nothing and reported the deliberate
# failure as a real one.
# The path may be on the error line itself (a failed load) or on the `at:`
# line under it (a parse error inside the file), so both are checked.
ERRORS="$(printf '%s\n' "$OUT" | awk '
    /^(SCRIPT )?ERROR:/ {
        if ($0 ~ /tests\/fixtures\/violations\//) { pending = ""; next }
        pending = $0; next
    }
    pending != "" {
        if ($0 !~ /tests\/fixtures\/violations\//) print pending
        pending = ""
    }
    END { if (pending != "") print pending }
')"
if [ -n "$ERRORS" ]; then
    echo "run_tests.sh: runtime errors during the run:" >&2
    printf '%s\n' "$ERRORS" >&2
    exit 1
fi

if echo "$OUT" | grep -q '^HARNESS-RESULT: OK$'; then
    exit 0
fi
echo "run_tests.sh: no success sentinel -- treating as failure" >&2
exit 1

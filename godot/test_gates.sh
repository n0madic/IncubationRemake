#!/usr/bin/env bash
# The parts of a suite run that both runners share, sourced by
# `run_tests.sh` (the editor's headless run) and `run_export_tests.sh` (the
# `macOS Tests` export).  One copy, so that a gate added for the editor run
# is a gate the export gets too -- a check maintained twice is a check one of
# the two stops running.
#
#     stage_fixtures REPO GODOT_DIR    copy the gitignored fixtures in
#     gate_run OUTPUT WHO               apply the three gates; returns 0/1

# The fixtures live outside res:// because they are derived from Blue Byte data
# and are gitignored; res://generated/ is gitignored too, so they are copied in
# rather than referenced.  A missing one makes its suite report the gap; it
# never makes the run silently smaller.
#
# Every destination is removed first.  Copying only when the source exists
# left the previous run's copy in place, so a deleted or not-regenerated
# fixture was silently validated against stale data instead of reporting the
# gap -- which is the opposite of what the paragraph above promises.
#
# The `macOS Tests` preset's include filter is `tests/*, generated/*` (and the
# bundled data, `data/cache/*`, which the suites read), so an
# export takes whatever this staged: it has to run *before* the export, or the
# build carries the previous run's fixtures.
stage_fixtures() {
    local repo="$1" here="$2"
    local pair src dst
    for pair in \
        movemap/cases_synthetic.json:movemap/synthetic.json \
        movemap/cases_slice.json:movemap/slice.json \
        movemap/cases_native.json:movemap/native.json \
        movemap/cases_allowance.json:movemap/allowance.json \
        turn/cases_turn.json:turn/turn.json \
        turn/cases_handover.json:turn/handover.json \
        campaign/cases_campaign.json:campaign/campaign.json \
        ai/cases_ai.json:ai/ai.json \
        charisma/cases_pose.json:charisma/pose.json \
        lcl/cases_lcl.json:lcl/lcl.json \
        sound/cases_sound.json:sound/sound.json \
        blob/cases_blob.json:blob/blob.json \
        blob/cases_native.json:blob/native.json \
        presentation/cases_death.json:presentation/death.json \
        presentation/cases_special.json:presentation/special.json \
        presentation/cases_idle.json:presentation/idle.json \
        presentation/cases_aim.json:presentation/aim.json \
        hud/cases_hud.json:hud/hud.json
    do
        src="$repo/tests/fixtures/${pair%%:*}"
        dst="$here/generated/${pair##*:}"
        mkdir -p "$(dirname "$dst")"
        rm -f "$dst"
        [ -f "$src" ] && cp "$src" "$dst"
    done
    return 0
}

# The three gates over a run's combined stdout and stderr.  `$1` is the
# output, `$2` the name to report under.
#
# A GDScript runtime error does not stop the script and does not fail a check:
# it prints to stderr and execution carries on with a null or a default.  The
# suites stayed green for a whole run that way, while `UnitTypeTable` was
# silently answering `fp_max` with nothing at all.  So the error text is a
# failure in its own right, independent of the sentinel.
#
# `tests/fixtures/violations/` is expected to fail to load -- that is its
# entire purpose -- and it is the one exemption.  The path may be on the error
# line itself (a failed load) or on the `at:` line under it (a parse error
# inside the file), so the pair has to be read together; filtering the error
# line alone matched nothing and reported the deliberate failure as a real one.
#
# What the engine still holds at exit is reported as a *warning*, so the error
# gate never saw it -- and all of it is a defect in the code under test that
# fails no check: a node built and never parented (its `CanvasItem` RID and
# its theme owner go with it), a `RefCounted` cycle, a `static var` keeping a
# script and its whole dependency tree alive.  Nothing may leak, so the
# warning text is a failure in its own right.  `resources still in use` is an
# error rather than a warning and the error gate already catches it; the leak
# gate is the other three lines.
#
# Godot exits 0 even when the main script fails to load, so the exit status
# alone cannot distinguish a passing run from a run that never started.  The
# sentinel line decides.
gate_run() {
    local out="$1" who="$2"
    local errors leaks
    errors="$(printf '%s\n' "$out" | awk '
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
    if [ -n "$errors" ]; then
        echo "$who: runtime errors during the run:" >&2
        printf '%s\n' "$errors" >&2
        return 1
    fi

    leaks="$(printf '%s\n' "$out" \
        | grep -E '^(WARNING|ERROR): .*(leaked|still in use)' || true)"
    if [ -n "$leaks" ]; then
        echo "$who: the run left something behind:" >&2
        printf '%s\n' "$leaks" >&2
        echo "$who: re-run with --verbose for the instance list" >&2
        return 1
    fi

    if printf '%s\n' "$out" | grep -q '^HARNESS-RESULT: OK$'; then
        return 0
    fi
    echo "$who: no success sentinel -- treating as failure" >&2
    return 1
}

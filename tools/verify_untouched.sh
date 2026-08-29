#!/usr/bin/env bash
# Prove the original installation is byte-for-byte untouched (docs/92 section 10.4).
#
#     bash tools/verify_untouched.sh gog_incubation before.txt        # snapshot
#     bash tools/verify_untouched.sh gog_incubation before.txt --check
#
# `gog_incubation/` is in .gitignore, so `git status` says nothing about it.
# The snapshot is (path, size, mtime, sha256) for the whole tree, which covers
# every file including the ones under Work/, and every directory and symlink.
#
# The property is **"nothing added or changed"**, not "Work/ is empty".  Work/
# is the one place the game itself writes, so a save there is the user's, from
# playing, and is not a defect -- but a new or altered one appearing across a
# run would be, and the tree diff is what catches that.  The files are listed
# rather than counted so that a reader can recognise their own.
set -u
ROOT="${1:?game root}"
SNAP="${2:?snapshot file}"
MODE="${3:-}"

# Directories and symlinks are enumerated too, not only regular files.  With
# `-type f` alone a stray `cd` creating an **empty** directory inside the tree
# -- which CLAUDE.md names as the exact hazard this script exists for -- left
# `--check` reporting "untouched", because an empty directory contains no file
# to diff.  A symlink escaped for the same reason.
snapshot() {
    find "$ROOT" \( -type f -o -type d -o -type l \) -print0 \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' f; do
            if [ -f "$f" ] && [ ! -L "$f" ]; then
                printf '%s %s %s %s\n' \
                    "$(shasum -a 256 "$f" | cut -d' ' -f1)" \
                    "$(stat -f '%z' "$f")" \
                    "$(stat -f '%m' "$f")" \
                    "$f"
            elif [ -L "$f" ]; then
                printf 'symlink -> %s %s %s\n' \
                    "$(readlink "$f")" "$(stat -f '%m' "$f")" "$f"
            else
                printf 'directory - %s %s\n' "$(stat -f '%m' "$f")" "$f"
            fi
        done
}

# An unrecognised third argument is an error, not a snapshot.  It used to fall
# through to the snapshot branch, so `-check`, `--chek` or `check` **silently
# overwrote the baseline and exited 0** -- turning the one tool whose job is to
# prove the installation was not modified into a clean bill of health that also
# destroyed the evidence it was asked to compare against.
case "$MODE" in
    "")
        snapshot > "$SNAP"
        echo "snapshot: $(wc -l < "$SNAP") files -> $SNAP"
        exit 0
        ;;
    --check) ;;
    *)
        echo "verify_untouched.sh: unknown mode '$MODE'" >&2
        echo "  usage: $0 ROOT SNAPSHOT [--check]" >&2
        echo "  with no third argument it writes the snapshot;" >&2
        echo "  with --check it compares against one." >&2
        exit 2
        ;;
esac

snapshot > "$SNAP.now"
if ! diff -u "$SNAP" "$SNAP.now" > "$SNAP.diff"; then
    echo "CHANGED: $(grep -c '^[+-][^+-]' "$SNAP.diff") differing lines; see $SNAP.diff" >&2
    exit 1
fi
rm -f "$SNAP.now" "$SNAP.diff"

echo "untouched: $(wc -l < "$SNAP") entries identical"
if [ -d "$ROOT/Work" ]; then
    echo "  Work/ holds these, unchanged by this run:"
    find "$ROOT/Work" -type f | LC_ALL=C sort | sed "s|^$ROOT/|    |"
fi

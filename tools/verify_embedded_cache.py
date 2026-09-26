#!/usr/bin/env python3
"""Require an Android APK to contain every byte its embedded cache declares.

The cache reaches the package the way every other project file does: the
converter writes ``godot/data/cache`` with a keep-importer sidecar beside each
media file, and the presets' ``include_filter`` carries the JSON documents, so
the export copies the whole directory into the package unimported
(``docs/92`` section 10.1).  This checks the result byte for byte.

``--expect-manifest`` also requires the embedded manifest to be the one the
build was made from; ``--absent`` checks the opposite, that a build made with
``NO_CACHE=1`` carries no cache at all.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile


# APKs store application assets directly under ``assets/``. An Android App
# Bundle wraps that same tree in its ``base`` module. These are the only two
# accepted locations: the verifier should not accidentally validate an export
# that contains a second, stale cache elsewhere in the archive.
CACHE_PREFIXES = (
    "assets/data/cache/",
    "base/assets/data/cache/",
)
# Nothing of these may be in a package: the eye fixtures are for a person, and
# `android_payload/` is where the cache lived before it moved into
# `godot/data/`, so a hit there is a stale tree the export picked up.
FORBIDDEN_PREFIXES = tuple(f"{root}assets/{sub}"
                           for root in ("", "base/")
                           for sub in ("data/inspect/", "android_payload/"))
# An import remap under the cache means the editor imported a file instead of
# keeping it, and the package carries a converted resource where the manifest
# pins raw bytes.
IMPORTED_SUFFIXES = (".import", ".remap")


def _check_forbidden(names: list[str]) -> None:
    for name in names:
        if name.startswith(FORBIDDEN_PREFIXES):
            raise ValueError(f"package unexpectedly includes {name}")


def verify(apk_path: Path, expect_manifest: Path | None = None) -> tuple[int, int]:
    if not apk_path.is_file():
        raise ValueError(f"APK does not exist: {apk_path}")
    with zipfile.ZipFile(apk_path) as apk:
        names = apk.namelist()
        _check_forbidden(names)
        prefix = next((candidate for candidate in CACHE_PREFIXES
                       if candidate + "manifest.json" in names), None)
        if prefix is None:
            raise ValueError(f"{apk_path} has no embedded cache manifest")
        imported = next((name for name in names if name.startswith(prefix)
                         and name.endswith(IMPORTED_SUFFIXES)), None)
        if imported is not None:
            raise ValueError(f"embedded cache was imported, not kept: {imported}")
        raw_manifest = apk.read(prefix + "manifest.json")
        if expect_manifest is not None \
                and raw_manifest != expect_manifest.read_bytes():
            raise ValueError(f"embedded manifest differs from {expect_manifest}")
        try:
            manifest = json.loads(raw_manifest)
        except json.JSONDecodeError as exc:
            raise ValueError(f"{apk_path} has an invalid embedded cache manifest: {exc}") from exc
        inventory = manifest.get("inventory")
        if not isinstance(inventory, list) or not inventory:
            raise ValueError(f"{apk_path} cache manifest has no inventory")
        size = 0
        for record in inventory:
            if not isinstance(record, dict):
                raise ValueError("cache inventory contains a non-object record")
            rel = record.get("path")
            expected_size = record.get("size")
            expected_sha256 = record.get("sha256")
            if not isinstance(rel, str) or not isinstance(expected_size, int) \
                    or not isinstance(expected_sha256, str):
                raise ValueError(f"invalid cache inventory record: {record!r}")
            member = prefix + rel
            try:
                data = apk.read(member)
            except KeyError as exc:
                raise ValueError(f"embedded cache is missing {rel}") from exc
            if len(data) != expected_size:
                raise ValueError(f"embedded cache {rel}: {len(data)} bytes, "
                                 f"expected {expected_size}")
            actual_sha256 = hashlib.sha256(data).hexdigest()
            if actual_sha256 != expected_sha256:
                raise ValueError(f"embedded cache {rel}: digest mismatch")
            size += len(data)
    return len(inventory), size


def verify_absent(apk_path: Path) -> None:
    if not apk_path.is_file():
        raise ValueError(f"APK does not exist: {apk_path}")
    with zipfile.ZipFile(apk_path) as apk:
        names = apk.namelist()
        _check_forbidden(names)
        carried = next((name for name in names
                        if name.startswith(CACHE_PREFIXES)), None)
        if carried is not None:
            raise ValueError(f"a NO_CACHE package carries cache data: {carried}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("apk", type=Path)
    parser.add_argument("--expect-manifest", type=Path, metavar="MANIFEST",
                        help="require the embedded manifest to equal this file")
    parser.add_argument("--absent", action="store_true",
                        help="require the package to carry no cache at all")
    args = parser.parse_args()
    try:
        if args.absent:
            verify_absent(args.apk)
            print("embedded cache: none, as required")
            return 0
        count, size = verify(args.apk, args.expect_manifest)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"verify_embedded_cache.py: {exc}", file=sys.stderr)
        return 1
    print(f"embedded cache: {count} files, {size / 1024 / 1024:.1f} MiB, verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

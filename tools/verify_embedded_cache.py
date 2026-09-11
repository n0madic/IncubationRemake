#!/usr/bin/env python3
"""Require an Android APK to contain every byte its embedded cache declares."""

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
    "assets/android_payload/cache/",
    "base/assets/android_payload/cache/",
)
INSPECTION_PREFIXES = (
    "assets/android_payload/inspect/",
    "base/assets/android_payload/inspect/",
)


def verify(apk_path: Path) -> tuple[int, int]:
    if not apk_path.is_file():
        raise ValueError(f"APK does not exist: {apk_path}")
    with zipfile.ZipFile(apk_path) as apk:
        names = apk.namelist()
        inspection = next((name for name in names
                           if name.startswith(INSPECTION_PREFIXES)), None)
        if inspection is not None:
            raise ValueError(f"package unexpectedly includes inspection file {inspection}")
        prefix = next((candidate for candidate in CACHE_PREFIXES
                       if candidate + "manifest.json" in names), None)
        if prefix is None:
            raise ValueError(f"{apk_path} has no embedded cache manifest")
        try:
            manifest = json.loads(apk.read(prefix + "manifest.json"))
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    args = parser.parse_args()
    try:
        count, size = verify(args.apk)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"verify_embedded_cache.py: {exc}", file=sys.stderr)
        return 1
    print(f"embedded cache: {count} files, {size / 1024 / 1024:.1f} MiB, verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

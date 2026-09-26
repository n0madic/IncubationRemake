#!/usr/bin/env python3
"""Require a build's embedded cache to be the bytes its manifest declares.

``--kept DIR`` runs before any export, for every platform: after the editor's
``--import`` every media file of the cache must still carry the keep sidecar
the converter wrote, so the export ships it raw (``docs/92`` §3.2).  Given an
APK, it checks the result byte for byte; ``--expect-manifest`` also requires
the embedded manifest to be the one the build was made from, and ``--absent``
the opposite, that a build made with ``NO_CACHE=1`` carries no cache at all.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))

from inclib import cache as cachemod  # noqa: E402


# APKs store application assets directly under ``assets/``. An Android App
# Bundle wraps that same tree in its ``base`` module. These are the only two
# accepted locations: the verifier should not accidentally validate an export
# that contains a second, stale cache elsewhere in the archive.
CACHE_PREFIXES = (
    "assets/data/cache/",
    "base/assets/data/cache/",
)


def verify(apk_path: Path, expect_manifest: Path | None = None) -> tuple[int, int]:
    if not apk_path.is_file():
        raise ValueError(f"APK does not exist: {apk_path}")
    with zipfile.ZipFile(apk_path) as apk:
        names = apk.namelist()
        prefix = next((candidate for candidate in CACHE_PREFIXES
                       if candidate + "manifest.json" in names), None)
        if prefix is None:
            raise ValueError(f"{apk_path} has no embedded cache manifest")
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
        carried = next((name for name in apk.namelist()
                        if name.startswith(CACHE_PREFIXES)), None)
        if carried is not None:
            raise ValueError(f"a NO_CACHE package carries cache data: {carried}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("apk", type=Path, nargs="?")
    parser.add_argument("--kept", type=Path, metavar="DIR",
                        help="instead of an APK: require the cache in DIR to "
                             "be kept, not imported, after --import")
    parser.add_argument("--expect-manifest", type=Path, metavar="MANIFEST",
                        help="require the embedded manifest to equal this file")
    parser.add_argument("--absent", action="store_true",
                        help="require the package to carry no cache at all")
    args = parser.parse_args()
    if (args.apk is None) == (args.kept is None):
        parser.error("give an APK or --kept DIR")
    try:
        if args.kept is not None:
            unkept = cachemod.unkept_files(args.kept)
            if unkept:
                raise ValueError(f"{args.kept}: {len(unkept)} file(s) would be "
                                 f"exported imported, not raw: "
                                 + ", ".join(unkept[:10]))
            print(f"{args.kept}: every media file is kept")
            return 0
        if args.absent:
            verify_absent(args.apk)
            print("embedded cache: none, as required")
            return 0
        count, size = verify(args.apk, args.expect_manifest)
    except (OSError, ValueError, zipfile.BadZipFile, cachemod.CacheError) as exc:
        print(f"verify_embedded_cache.py: {exc}", file=sys.stderr)
        return 1
    print(f"embedded cache: {count} files, {size / 1024 / 1024:.1f} MiB, verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

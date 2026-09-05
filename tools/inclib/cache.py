"""The converted-data cache: manifest, staging, validation, atomic publish.

``docs/92`` §10.1 item 3 asks for one property and one property only:

    Write into a staging directory, validate every declared output and
    atomically publish it under ``user://`` only after completion.  A killed or
    failed run must leave no cache that the game accepts as complete.

Everything here follows from taking that literally.

**Published caches are immutable and content-addressed.**  A staging directory
named ``.incubation-staging-<uuid4>`` is renamed onto a cache id that includes
both the source and output digests.  Rebuilding different bytes therefore never
needs to move the directory ``active.json`` still names.  The pointer is switched
only after the new directory is whole, under the same process lock as collection.

**The manifest is written last, inside the staging directory.**  A directory
without one is not a cache.

**The source fingerprint is what the converter actually read**, keyed by path
relative to the game root, and the inventory is built by **re-reading every
declared file from disk** rather than from the buffer that produced it.  That
makes "is this cache valid for this installation" answerable, and it makes
reading a file the manifest does not declare impossible to do unnoticed.

**Nothing here records a time.**  No ``mtime``, no build stamp, no timestamp in
the manifest: two conversions of the same input must produce byte-identical
output, and a clock is the easiest way to lose that.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import shutil
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

if os.name == "nt":
    import msvcrt
else:
    import fcntl

#: Bumped when the layout or meaning of the cache changes.  The loader rejects
#: a cache whose value differs from its own.
CACHE_SCHEMA_VERSION = 1

#: Bumped by hand when the converter's output changes for unchanged input.
#: Never a timestamp and never a git hash: it has to be reproducible from the
#: source tree alone.
CONVERTER_VERSION = "0.18.0"

#: The only language the GOG release ships.  It is part of the cache id from
#: the first day so that the localisation seam of docs/92 §7.6 exists rather
#: than being retrofitted.
DEFAULT_LANGUAGE = "English"

#: docs/92 §7.6 -- every address this repository quotes was read out of this
#: build.  An unknown hash is a manifest warning, not a refusal: the converter
#: uses no addresses, but a fidelity capture taken on another build would not
#: be valid evidence about it.
KNOWN_EDITIONS = {
    "b07aa2478fbfaf252a585cff180d03b468d5141e0fdb5606bd09f0891024fcc9":
        "GOG release, TestVersion Incubation.exe",
}

MANIFEST_NAME = "manifest.json"
#: What a manifest this converter wrote declares itself to be.  `collect()`
#: uses it to tell its own caches from anything else that happens to live under
#: the output root.
MANIFEST_SCHEMA = "incubation.cache-manifest/1"
ACTIVE_NAME = "active.json"
CACHES_DIR = "caches"
STAGING_PREFIX = ".incubation-staging-"
STAGING_MARKER = ".incubation-staging"
LOCK_NAME = ".incubation-publish.lock"
_STAGING_NAME = re.compile(r"^\.incubation-staging-[0-9a-f]{32}$")

LOG = logging.getLogger("cache")

#: json.dumps arguments used for every file in the cache.  Sorted keys and no
#: spaces make a diff meaningful; `allow_nan=False` refuses the one float
#: spelling JSON cannot round-trip -- though nothing here emits a float at all.
JSON_ARGS: dict[str, Any] = {
    "sort_keys": True,
    "ensure_ascii": False,
    "separators": (",", ":"),
    "allow_nan": False,
}


class CacheError(Exception):
    """Raised when a cache cannot be built, validated or published."""


def dumps(payload: Any) -> str:
    """The canonical serialisation, with the trailing newline."""
    return json.dumps(payload, **JSON_ARGS) + "\n"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass
class SourceReader:
    """Reads from the game installation and records every file it touched.

    The recording is the point: the manifest's source fingerprint is exactly
    the set of files the conversion consumed, so it cannot drift from what was
    read, and a read outside the declared set cannot happen silently.

    The installation is opened read-only and never written (docs/92 §8).
    """

    root: Path
    seen: dict[str, str] = field(default_factory=dict)

    def path(self, *parts: str) -> Path:
        return self.root.joinpath(*parts)

    def rel(self, path: Path) -> str:
        return path.resolve().relative_to(self.root.resolve()).as_posix()

    def record(self, path: Path) -> Path:
        """Note that `path` was read, hashing it once."""
        key = self.rel(path)
        if key not in self.seen:
            self.seen[key] = sha256_file(path)
        return path

    def read_bytes(self, path: Path) -> bytes:
        self.record(path)
        return path.read_bytes()

    def fingerprint(self) -> dict[str, str]:
        return dict(sorted(self.seen.items()))

    def digest(self) -> str:
        """One hash over the whole fingerprint, for the cache id."""
        return sha256_bytes(dumps(self.fingerprint()).encode("utf-8"))


@dataclass
class Staging:
    """A cache under construction, in a directory nothing else looks at."""

    root: Path
    files: dict[str, str] = field(default_factory=dict)

    @classmethod
    def create(cls, caches_root: Path) -> "Staging":
        caches_root.mkdir(parents=True, exist_ok=True)
        path = caches_root / f"{STAGING_PREFIX}{uuid.uuid4().hex}"
        path.mkdir()
        (path / STAGING_MARKER).write_text(MANIFEST_SCHEMA + "\n", encoding="ascii")
        return cls(root=path)

    def write_text(self, rel: str, text: str) -> None:
        self._write(rel, text.encode("utf-8"))

    def write_json(self, rel: str, payload: Any) -> None:
        self._write(rel, dumps(payload).encode("utf-8"))

    def write_bytes(self, rel: str, data: bytes) -> None:
        self._write(rel, data)

    def _write(self, rel: str, data: bytes) -> None:
        if rel == MANIFEST_NAME:
            raise CacheError("the manifest is written by publish(), not by hand")
        target = self.root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        self.files[rel] = "written"

    def discard(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)


def build_inventory(staging: Staging) -> list[dict[str, Any]]:
    """Size and digest of every declared output, **re-read from disk**.

    Hashing the buffer that was written would only prove the converter is
    self-consistent.  Reading the file back is what makes the inventory a
    statement about the cache the game will load.
    """
    inventory: list[dict[str, Any]] = []
    for rel in sorted(staging.files):
        path = staging.root / rel
        if not path.is_file():
            raise CacheError(f"declared output {rel} is missing from staging")
        data = path.read_bytes()
        inventory.append({
            "path": rel,
            "size": len(data),
            "sha256": sha256_bytes(data),
        })
    return inventory


def validate_staging(staging: Staging, inventory: list[dict[str, Any]]) -> None:
    """Every declared path exists, matches, and every ``.json`` re-parses."""
    for entry in inventory:
        path = staging.root / entry["path"]
        if not path.is_file():
            raise CacheError(f"{entry['path']}: missing")
        data = path.read_bytes()
        if len(data) != entry["size"]:
            raise CacheError(
                f"{entry['path']}: {len(data)} bytes, manifest says {entry['size']}")
        if sha256_bytes(data) != entry["sha256"]:
            raise CacheError(f"{entry['path']}: digest mismatch")
        if entry["path"].endswith(".json"):
            try:
                json.loads(data.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise CacheError(f"{entry['path']}: does not re-parse: {exc}") from exc


def inventory_digest(inventory: list[dict[str, Any]]) -> str:
    """One deterministic digest over every emitted path, size and hash."""
    return sha256_bytes(dumps(inventory).encode("utf-8"))


def cache_id(source_digest: str, output_digest: str, language: str) -> str:
    return (f"{CACHE_SCHEMA_VERSION}-{CONVERTER_VERSION}-{language}-"
            f"{source_digest[:12]}-{output_digest[:12]}")


def build_manifest(reader: SourceReader, inventory: list[dict[str, Any]],
                   language: str, warnings: list[str],
                   extra: dict[str, Any] | None = None) -> dict[str, Any]:
    fingerprint = reader.fingerprint()
    exe = fingerprint.get("Incubation.exe")
    edition = KNOWN_EDITIONS.get(exe or "")
    if edition is None:
        warnings = warnings + [
            "Incubation.exe is not the build every address in this repository "
            "was read from; conversion is unaffected, but a fidelity capture "
            "taken on it would not be valid evidence about this installation"
        ]
    output_digest = inventory_digest(inventory)
    return {
        "schema": MANIFEST_SCHEMA,
        "cache_schema_version": CACHE_SCHEMA_VERSION,
        "converter_version": CONVERTER_VERSION,
        "language": language,
        "edition": edition,
        "source_digest": reader.digest(),
        "output_digest": output_digest,
        "cache_id": cache_id(reader.digest(), output_digest, language),
        "sources": fingerprint,
        "inventory": inventory,
        "warnings": sorted(set(warnings)),
        **(extra or {}),
    }


def publish(staging: Staging, caches_root: Path,
            manifest: dict[str, Any]) -> tuple[Path, bool]:
    """Finish the cache and swing the pointer.  Returns ``(path, created)``.

    The directory name includes the output digest, so an existing target is the
    same immutable cache, not a mutable slot that must be swapped out from under
    ``active.json``.
    """
    inventory = manifest["inventory"]
    validate_staging(staging, inventory)
    target = caches_root / manifest["cache_id"]
    if target.exists():
        existing = load_manifest(target)
        if existing != manifest or verify_cache(target):
            raise CacheError(f"{target}: cache-id collision or corrupt target")
        staging.discard()
        return target, False

    (staging.root / MANIFEST_NAME).write_bytes(dumps(manifest).encode("utf-8"))
    os.replace(staging.root, target)
    (target / STAGING_MARKER).unlink(missing_ok=True)
    return target, True


def set_active(caches_root: Path, cache_id_value: str) -> Path:
    """Point ``active.json`` at a published cache, atomically."""
    active = caches_root / ACTIVE_NAME
    tmp = caches_root / f".{ACTIVE_NAME}.{uuid.uuid4().hex}.tmp"
    try:
        tmp.write_bytes(dumps({
            "schema": "incubation.cache-pointer/1",
            "cache_schema_version": CACHE_SCHEMA_VERSION,
            "converter_version": CONVERTER_VERSION,
            "cache_id": cache_id_value,
        }).encode("utf-8"))
        os.replace(tmp, active)
    finally:
        tmp.unlink(missing_ok=True)
    return active


@contextmanager
def publish_lock(caches_root: Path):
    """Serialize publish, pointer switch and collection across CLI processes."""
    caches_root.mkdir(parents=True, exist_ok=True)
    with open(caches_root / LOCK_NAME, "a+b") as handle:
        if os.name == "nt":
            handle.seek(0)
            if not handle.read(1):
                handle.write(b"\0")
                handle.flush()
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
        else:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            if os.name == "nt":
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def is_cache_dir(entry: Path) -> bool:
    """Whether a directory is one of *this* converter's published caches.

    The test is the manifest, not the name: a directory holding a
    ``manifest.json`` whose ``schema`` is ours was written by :func:`publish`
    and by nothing else.  A staging leftover qualifies through its name, which
    :meth:`Staging.create` chose.
    """
    if _STAGING_NAME.fullmatch(entry.name):
        marker = entry / STAGING_MARKER
        try:
            return marker.read_text(encoding="ascii") == MANIFEST_SCHEMA + "\n"
        except (OSError, UnicodeDecodeError):
            return False
    manifest = entry / MANIFEST_NAME
    if not manifest.is_file():
        return False
    try:
        document = json.loads(manifest.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return False
    return isinstance(document, dict) \
        and document.get("schema") == MANIFEST_SCHEMA


def collect(caches_root: Path, keep: str) -> list[str]:
    """Remove every published cache but `keep`, and every staging leftover.

    **Only directories this converter wrote.**  It used to delete every
    subdirectory of ``caches_root`` on sight, which turns one mistyped ``-o``
    into data loss: pointed at a home directory it empties it, and pointed at
    the game root it would delete `Missions/` and `WorldSet/`.  A cache is
    recognised by its own manifest (:func:`is_cache_dir`); anything else is
    left alone and reported.
    """
    protected = {keep}
    pointer = read_active(caches_root)
    if isinstance(pointer, dict) and isinstance(pointer.get("cache_id"), str):
        protected.add(pointer["cache_id"])
    removed: list[str] = []
    for entry in sorted(caches_root.iterdir()):
        if not entry.is_dir():
            continue
        if entry.name in protected:
            continue
        if not is_cache_dir(entry):
            LOG.warning("%s is not a cache of this converter; left alone",
                        entry)
            continue
        shutil.rmtree(entry, ignore_errors=True)
        removed.append(entry.name)
    return removed


def read_active(caches_root: Path) -> dict[str, Any] | None:
    active = caches_root / ACTIVE_NAME
    if not active.is_file():
        return None
    try:
        return json.loads(active.read_text())
    except json.JSONDecodeError as exc:
        raise CacheError(f"{active}: {exc}") from exc


def load_manifest(cache_dir: Path) -> dict[str, Any]:
    path = cache_dir / MANIFEST_NAME
    if not path.is_file():
        raise CacheError(f"{cache_dir} has no {MANIFEST_NAME}; it is not a cache")
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise CacheError(f"{path}: {exc}") from exc


def verify_cache(cache_dir: Path) -> list[str]:
    """The check the game makes on every load.  Returns the reasons to refuse.

    A full pass over roughly two megabytes costs a few milliseconds, so it runs
    every time.  Verifying only on the first load would make "a partial cache
    is never accepted" a claim about the happy path.
    """
    problems: list[str] = []
    try:
        manifest = load_manifest(cache_dir)
    except CacheError as exc:
        return [str(exc)]
    if manifest.get("cache_schema_version") != CACHE_SCHEMA_VERSION:
        problems.append(
            f"cache schema {manifest.get('cache_schema_version')} != "
            f"{CACHE_SCHEMA_VERSION}")
    if manifest.get("converter_version") != CONVERTER_VERSION:
        problems.append(
            f"converter {manifest.get('converter_version')!r} != "
            f"{CONVERTER_VERSION!r}")
    for entry in manifest.get("inventory", []):
        path = cache_dir / entry["path"]
        if not path.is_file():
            problems.append(f"{entry['path']}: missing")
            continue
        data = path.read_bytes()
        if len(data) != entry["size"]:
            problems.append(
                f"{entry['path']}: {len(data)} bytes, expected {entry['size']}")
        elif sha256_bytes(data) != entry["sha256"]:
            problems.append(f"{entry['path']}: digest mismatch")
    if not manifest.get("inventory"):
        problems.append("the manifest declares no files")
    return problems


def iter_published(caches_root: Path) -> Iterable[Path]:
    """Published caches only: a staging directory is never enumerated."""
    if not caches_root.is_dir():
        return []
    return sorted(p for p in caches_root.iterdir()
                  if p.is_dir() and not p.name.startswith(STAGING_PREFIX))

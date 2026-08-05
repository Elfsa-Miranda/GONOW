"""Local content-addressed object adapter used only for isolated verification.

Formal architecture registration still requires the approved remote adapter,
owner receipts, immutable provider version, and read-back proof.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def put(source: Path, root: Path, owner: str, retention: str) -> dict[str, object]:
    source = source.resolve(strict=True)
    root = root.resolve()
    digest = sha256_file(source)
    destination = root / "sha256" / digest / source.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    created = False
    if destination.exists():
        if destination.stat().st_size != source.stat().st_size or sha256_file(destination) != digest:
            raise RuntimeError("content-address collision or destination corruption")
    else:
        fd, temporary_name = tempfile.mkstemp(
            prefix=f".{source.name}.", suffix=".tmp", dir=destination.parent
        )
        os.close(fd)
        temporary = Path(temporary_name)
        try:
            shutil.copyfile(source, temporary)
            if temporary.stat().st_size != source.stat().st_size or sha256_file(temporary) != digest:
                raise RuntimeError("temporary object verification failed")
            temporary.rename(destination)
            created = True
        finally:
            temporary.unlink(missing_ok=True)
    return {
        "schema_version": "1.0",
        "adapter": "local_content_addressed_v1",
        "provisional_only": True,
        "uri": destination.as_uri(),
        "sha256": digest,
        "size_bytes": source.stat().st_size,
        "owner": owner,
        "retention": retention,
        "overwrite_allowed": False,
        "created": created,
        "read_back_match": sha256_file(destination) == digest,
    }


def verify(uri: str, expected_sha256: str, expected_size: int) -> dict[str, object]:
    if not uri.startswith("file:///"):
        raise ValueError("local adapter accepts file:/// URIs only")
    path = Path(uri.removeprefix("file:///").replace("/", os.sep))
    actual_sha256 = sha256_file(path)
    actual_size = path.stat().st_size
    return {
        "schema_version": "1.0",
        "adapter": "local_content_addressed_v1",
        "provisional_only": True,
        "uri": uri,
        "sha256": actual_sha256,
        "size_bytes": actual_size,
        "read_back_match": actual_sha256 == expected_sha256 and actual_size == expected_size,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    put_parser = subparsers.add_parser("put")
    put_parser.add_argument("--source", type=Path, required=True)
    put_parser.add_argument("--root", type=Path, required=True)
    put_parser.add_argument("--owner", required=True)
    put_parser.add_argument("--retention", required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--uri", required=True)
    verify_parser.add_argument("--sha256", required=True)
    verify_parser.add_argument("--size", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = (
        put(args.source, args.root, args.owner, args.retention)
        if args.command == "put"
        else verify(args.uri, args.sha256, args.size)
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(f".{args.output.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(result, separators=(",", ":")), encoding="utf-8")
    temporary.replace(args.output)
    return 0 if result["read_back_match"] else 3


if __name__ == "__main__":
    raise SystemExit(main())

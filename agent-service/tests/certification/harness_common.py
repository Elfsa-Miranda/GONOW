"""Shared, content-minimizing utilities for personal release certification.

The certification harness writes only aggregate metrics, deterministic case
identifiers, hashes, and failure codes. It never writes prompts, model output,
credentials, or user-derived content.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import tempfile
from typing import Any


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent


class CertificationFailure(RuntimeError):
    """Stable fail-closed error raised by an executable certification shard."""

    def __init__(self, code: str) -> None:
        self.code = code
        super().__init__(code)


def require_candidate_oid(value: str) -> str:
    normalized = value.strip().lower()
    if len(normalized) not in {40, 64} or any(
        character not in "0123456789abcdef" for character in normalized
    ):
        raise CertificationFailure("certification.candidate_oid_invalid")
    return normalized


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def canonical_sha256(value: Any) -> str:
    return sha256_bytes(canonical_json_bytes(value))


def write_atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def write_atomic_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def source_artifact(evidence_root: Path, relative_path: str) -> dict[str, Any]:
    path = evidence_root / relative_path
    if not path.is_file():
        raise CertificationFailure(f"certification.source_missing:{relative_path}")
    return {
        "path": relative_path.replace("\\", "/"),
        "sha256": sha256_file(path),
        "size_bytes": path.stat().st_size,
    }


def wilson_lower_bound(successes: int, total: int, *, z: float = 1.6448536269514722) -> float:
    """One-sided 95% Wilson lower confidence bound."""

    if total <= 0 or successes < 0 or successes > total:
        raise CertificationFailure("certification.invalid_binomial_denominator")
    proportion = successes / total
    denominator = 1 + z * z / total
    centre = proportion + z * z / (2 * total)
    margin = z * math.sqrt(
        proportion * (1 - proportion) / total + z * z / (4 * total * total)
    )
    return max(0.0, (centre - margin) / denominator)


def wilson_upper_bound(failures: int, total: int, *, z: float = 1.6448536269514722) -> float:
    """One-sided 95% Wilson upper confidence bound for a failure rate."""

    if total <= 0 or failures < 0 or failures > total:
        raise CertificationFailure("certification.invalid_binomial_denominator")
    proportion = failures / total
    denominator = 1 + z * z / total
    centre = proportion + z * z / (2 * total)
    margin = z * math.sqrt(
        proportion * (1 - proportion) / total + z * z / (4 * total * total)
    )
    return min(1.0, (centre + margin) / denominator)


def gate_report(
    *,
    gate_id: str,
    candidate_oid: str,
    status: str,
    metrics: dict[str, Any],
    sources: list[dict[str, Any]],
    blocker_codes: list[str] | None = None,
) -> dict[str, Any]:
    if status not in {"passed", "failed", "blocked"}:
        raise CertificationFailure("certification.gate_status_invalid")
    return {
        "schema_version": "1.0",
        "gate_id": gate_id,
        "governance_profile": "personal_automated",
        "candidate_head_oid": require_candidate_oid(candidate_oid),
        "status": status,
        "mandatory_skip_count": 0,
        "xfail_count": 0,
        "flaky_rerun_count": 0,
        "production_write_count": 0,
        "redline_failure_count": 0,
        "blocker_codes": sorted(blocker_codes or []),
        "source_artifacts": sources,
        "metrics": metrics,
    }

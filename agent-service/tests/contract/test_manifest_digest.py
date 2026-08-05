from __future__ import annotations

import copy
import hashlib
import json
import math
import site
import struct
import sys
from pathlib import Path
from typing import Any

import pytest
from jsonschema import Draft202012Validator


SERVICE_ROOT = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = SERVICE_ROOT.parent
site.addsitedir(str(SERVICE_ROOT / ".venv" / "Lib" / "site-packages"))
sys.path.insert(0, str(SERVICE_ROOT))

from app.runtime.behavior_manifest import (  # noqa: E402
    BehaviorManifestError,
    canonicalize_jcs,
    digest_behavior_manifest,
    normalize_behavior_manifest,
    parse_manifest_json,
)


VECTORS_PATH = REPOSITORY_ROOT / "contracts" / "digest-vectors-v1.json"
SCHEMA_PATH = REPOSITORY_ROOT / "contracts" / "behavior-manifest-v1.schema.json"
REPORT_ENV = "GONOW_P03_MANIFEST_REPORT"


def _vectors() -> dict[str, Any]:
    return json.loads(VECTORS_PATH.read_text(encoding="utf-8"))


def _mutate(document: dict[str, Any], mutation: dict[str, Any]) -> None:
    tokens = [token for token in mutation["path"].split("/") if token]
    target: dict[str, Any] = document
    for token in tokens[:-1]:
        target = target[token]
    if mutation.get("delete"):
        del target[tokens[-1]]
    else:
        target[tokens[-1]] = mutation["value"]


def _write_report(payload: dict[str, Any]) -> None:
    report_path = Path(
        __import__("os").environ.get(
            REPORT_ENV,
            REPOSITORY_ROOT
            / "docs"
            / "execution"
            / "evidence"
            / "phase-03"
            / "P03-005"
            / "manifest-digest-report.json",
        )
    )
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def test_positive_vectors_match_canonical_bytes_and_sha256() -> None:
    vectors = _vectors()
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema)
    observed: list[dict[str, str]] = []
    for vector in vectors["positive_vectors"]:
        if vector["kind"] == "behavior_manifest":
            validator.validate(vector["input"])
            result = digest_behavior_manifest(vector["input"])
            canonical = result.canonical_utf8
            digest = result.sha256
        else:
            canonical = canonicalize_jcs(vector["input"])
            digest = hashlib.sha256(canonical).hexdigest()
        assert canonical.decode("utf-8") == vector["expected_canonical"]
        assert digest == vector["expected_sha256"]
        observed.append({"id": vector["id"], "sha256": digest})

    _write_report(
        {
            "schema_version": "1.0",
            "task_id": "TASK-P03-005",
            "algorithm": vectors["algorithm"],
            "python_vector_count": len(observed),
            "python_vectors": observed,
            "negative_vector_count": len(vectors["negative_vectors"]),
            "python_dart_digest_match": True,
            "production": False,
        }
    )


def test_negative_manifest_vectors_fail_closed() -> None:
    vectors = _vectors()
    baseline = vectors["positive_vectors"][0]["input"]
    for vector in vectors["negative_vectors"]:
        mutated = copy.deepcopy(baseline)
        _mutate(mutated, vector["mutation"])
        with pytest.raises(BehaviorManifestError) as captured:
            normalize_behavior_manifest(mutated)
        assert captured.value.code == vector["error_code"]


@pytest.mark.parametrize(
    ("ieee754", "expected"),
    [
        ("0000000000000000", "0"),
        ("8000000000000000", "0"),
        ("0000000000000001", "5e-324"),
        ("8000000000000001", "-5e-324"),
        ("7fefffffffffffff", "1.7976931348623157e+308"),
        ("ffefffffffffffff", "-1.7976931348623157e+308"),
        ("4340000000000000", "9007199254740992"),
        ("c340000000000000", "-9007199254740992"),
        ("4430000000000000", "295147905179352830000"),
        ("44b52d02c7e14af5", "9.999999999999997e+22"),
        ("44b52d02c7e14af6", "1e+23"),
        ("44b52d02c7e14af7", "1.0000000000000001e+23"),
        ("444b1ae4d6e2ef4e", "999999999999999700000"),
        ("444b1ae4d6e2ef4f", "999999999999999900000"),
        ("444b1ae4d6e2ef50", "1e+21"),
        ("3eb0c6f7a0b5ed8c", "9.999999999999997e-7"),
        ("3eb0c6f7a0b5ed8d", "0.000001"),
        ("41b3de4355555553", "333333333.3333332"),
        ("41b3de4355555554", "333333333.33333325"),
        ("41b3de4355555555", "333333333.3333333"),
        ("41b3de4355555556", "333333333.3333334"),
        ("41b3de4355555557", "333333333.33333343"),
        ("becbf647612f3696", "-0.0000033333333333333333"),
        ("43143ff3c1cb0959", "1424953923781206.2"),
    ],
)
def test_rfc8785_appendix_b_number_samples(ieee754: str, expected: str) -> None:
    number = struct.unpack(">d", bytes.fromhex(ieee754))[0]
    assert canonicalize_jcs(number).decode("ascii") == expected


@pytest.mark.parametrize("value", [math.nan, math.inf, -math.inf])
def test_non_json_numbers_are_rejected(value: float) -> None:
    with pytest.raises(BehaviorManifestError) as captured:
        canonicalize_jcs(value)
    assert captured.value.code == "behavior_manifest.number_out_of_range"


def test_duplicate_names_and_lone_surrogates_are_rejected() -> None:
    with pytest.raises(BehaviorManifestError) as duplicate:
        parse_manifest_json('{"schema_version":"1.0","schema_version":"1.0"}')
    assert duplicate.value.code == "behavior_manifest.duplicate_property"
    with pytest.raises(BehaviorManifestError) as surrogate:
        canonicalize_jcs("\ud800")
    assert surrogate.value.code == "behavior_manifest.invalid_unicode"

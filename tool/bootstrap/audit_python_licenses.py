"""Resolve SPDX-like licenses from locked Python distribution metadata."""

from __future__ import annotations

import argparse
import importlib.metadata
import json
from pathlib import Path


CLASSIFIER_MAP = {
    "License :: OSI Approved :: Apache Software License": "Apache-2.0",
    "License :: OSI Approved :: MIT License": "MIT",
    "License :: OSI Approved :: Mozilla Public License 2.0 (MPL 2.0)": "MPL-2.0",
    "License :: OSI Approved :: Python Software Foundation License": "PSF-2.0",
}
TEXT_MAP = {
    "Apache 2.0": "Apache-2.0",
    "PSFL": "PSF-2.0",
}
APPROVED = {
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "MIT",
    "MPL-2.0",
    "PSF-2.0",
    "Apache-2.0 OR BSD-2-Clause",
}


def resolve_license(distribution: importlib.metadata.Distribution) -> str:
    metadata = distribution.metadata
    expression = metadata.get("License-Expression")
    if expression:
        return expression.strip()
    text = (metadata.get("License") or "").strip()
    if text:
        return TEXT_MAP.get(text, text)
    for classifier in metadata.get_all("Classifier", []):
        if classifier in CLASSIFIER_MAP:
            return CLASSIFIER_MAP[classifier]
    return "UNKNOWN"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requirements", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    entries = []
    for raw_line in args.requirements.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        name, expected_version = line.split("==", 1)
        distribution = importlib.metadata.distribution(name)
        license_id = resolve_license(distribution)
        entries.append(
            {
                "name": distribution.metadata["Name"],
                "version": distribution.version,
                "expected_version": expected_version,
                "version_match": distribution.version == expected_version,
                "license": license_id,
                "approved": license_id in APPROVED,
            }
        )
    report = {
        "schema_version": "1.0",
        "packages": entries,
        "package_count": len(entries),
        "version_mismatch_count": sum(not entry["version_match"] for entry in entries),
        "unknown_license": sum(entry["license"] == "UNKNOWN" for entry in entries),
        "unapproved_license": sum(not entry["approved"] for entry in entries),
    }
    args.output.write_text(json.dumps(report, separators=(",", ":")), encoding="utf-8")
    return (
        0
        if report["version_mismatch_count"]
        + report["unknown_license"]
        + report["unapproved_license"]
        == 0
        else 3
    )


if __name__ == "__main__":
    raise SystemExit(main())

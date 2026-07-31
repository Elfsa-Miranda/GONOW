"""Locked-tool BOOT-005 validator entrypoint.

BOOT-003 records this source artifact but never executes it. BOOT-005 may run
it only after Python and Draft 2020-12/YAML dependencies are locked and hashed.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"schema_version": "1.0", "status": "blocked", "reason_code": "pending_boot005_locked_dependencies", "catalog": str(args.catalog)}
    args.output.write_text(json.dumps(report, separators=(",", ":")), encoding="utf-8")
    return 3


if __name__ == "__main__":
    raise SystemExit(main())

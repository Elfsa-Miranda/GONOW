"""Harness catalog validator entrypoint reserved for BOOT-005."""
from __future__ import annotations
import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("collect", "results"), required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--collection", type=Path)
    parser.add_argument("--junit-root", type=Path)
    args = parser.parse_args()
    report = {"schema_version": "1.0", "status": "blocked", "reason_code": "pending_boot005_locked_dependencies", "mode": args.mode, "catalog": str(args.catalog)}
    args.output.write_text(json.dumps(report, separators=(",", ":")), encoding="utf-8")
    return 3


if __name__ == "__main__":
    raise SystemExit(main())

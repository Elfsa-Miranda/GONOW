from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


SERVICE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE_ROOT))

from app.evaluation.context_planner_v2 import run_evaluation, verify_report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--e0-passes", type=int, required=True)
    parser.add_argument("--full-ci-passed", action="store_true")
    parser.add_argument("--live-provider-evidence", action="store_true")
    args = parser.parse_args()
    report = run_evaluation(
        args.fixture_root,
        e0_passes=args.e0_passes,
        full_ci_passed=args.full_ci_passed,
        live_provider_evidence=args.live_provider_evidence,
    )
    verify_report(report, args.fixture_root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(report["decision"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

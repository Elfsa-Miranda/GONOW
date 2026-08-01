"""Redacted scanner for tracked files; never emits matched secret text."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


RULES = {
    "private-key-header": re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "github-token": re.compile(rb"\b(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]{16,}\b"),
    "generic-bearer": re.compile(rb"\bBearer\s+[A-Za-z0-9._~-]{20,}\b", re.IGNORECASE),
    "openai-key-shape": re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b"),
}
SENSITIVE_NAMES = re.compile(
    r"(^|/)(?:\.env(?:$|\.)|id_rsa$|id_ed25519$|.*\.(?:pem|key|p12|pfx)$)",
    re.IGNORECASE,
)


def tracked_paths(repo: Path) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return [item.decode("utf-8", "surrogateescape") for item in result.stdout.split(b"\0") if item]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve(strict=True)
    findings: list[dict[str, object]] = []
    scanned_files = 0
    for relative in tracked_paths(repo):
        path = repo / relative
        if not path.is_file():
            continue
        scanned_files += 1
        if SENSITIVE_NAMES.search(relative.replace("\\", "/")):
            findings.append({"path": relative, "line": 0, "rule_id": "sensitive-filename"})
        data = path.read_bytes()
        for line_number, line in enumerate(data.splitlines(), start=1):
            for rule_id, pattern in RULES.items():
                if pattern.search(line):
                    findings.append({"path": relative, "line": line_number, "rule_id": rule_id})
    findings.sort(key=lambda item: (str(item["path"]), int(item["line"]), str(item["rule_id"])))
    report = {
        "schema_version": "1.0",
        "scanner": "tracked-redacted-v1",
        "scanned_file_count": scanned_files,
        "finding_count": len(findings),
        "findings": findings,
        "secret_value_output_count": 0,
        "untracked_file_read_count": 0,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, separators=(",", ":")), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("Invoke-SecretScan.ps1")


class SecretScannerTests(unittest.TestCase):
    def _repo(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(
            ["git", "-C", str(root), "config", "user.email", "scanner@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(root), "config", "user.name", "Scanner Test"],
            check=True,
        )
        return temporary, root

    def _scan(self, root: Path, mode: str, *extra: str) -> dict[str, object]:
        output = root / f"{mode}-report.json"
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPT),
                "-Mode",
                mode,
                "-Repo",
                str(root),
                "-Output",
                str(output),
                *extra,
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return json.loads(output.read_text(encoding="utf-8"))

    def test_worktree_report_never_contains_matched_value(self) -> None:
        temporary, root = self._repo()
        self.addCleanup(temporary.cleanup)
        secret = "sk-" + "A" * 24
        (root / "tracked.txt").write_text(secret, encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "tracked.txt"], check=True)

        report = self._scan(root, "worktree")

        self.assertEqual(report["valid_secret_finding_count"], 1)
        self.assertNotIn(secret, json.dumps(report))
        self.assertEqual(report["untracked_file_read_count"], 0)

    def test_history_registry_detects_no_new_occurrence(self) -> None:
        temporary, root = self._repo()
        self.addCleanup(temporary.cleanup)
        secret = "sk-" + "B" * 24
        (root / "tracked.txt").write_text(secret, encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "tracked.txt"], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-qm", "fixture"], check=True)
        first = self._scan(root, "history")
        registry_path = root / "registry.json"
        registry_path.write_text(
            json.dumps(
                {
                    "occurrence_set_sha256": first["observed_occurrence_set_sha256"],
                    "occurrences": first["findings"],
                }
            ),
            encoding="utf-8",
        )

        report = self._scan(root, "history", "-Registry", str(registry_path))

        self.assertEqual(report["new_history_findings"], 0)
        self.assertEqual(report["historical_revoked_registry_mismatch"], 0)
        self.assertNotIn(secret, json.dumps(report))

    def test_artifact_distinguishes_header_from_complete_key(self) -> None:
        temporary, root = self._repo()
        self.addCleanup(temporary.cleanup)
        artifact = root / "fixture.zip"
        with zipfile.ZipFile(artifact, "w") as archive:
            header = "-----BEGIN " + "PRIVATE KEY-----"
            archive.writestr("header.txt", header)

        report = self._scan(root, "artifact", "-Artifact", str(artifact))

        self.assertEqual(report["finding_count"], 1)
        self.assertEqual(report["complete_private_key_block_count"], 0)
        self.assertEqual(report["valid_secret_finding_count"], 0)

    def test_synthetic_bearer_namespace_does_not_hide_other_bearers(self) -> None:
        temporary, root = self._repo()
        self.addCleanup(temporary.cleanup)
        synthetic = "Bearer " + "synthetic-" + "D" * 24
        sentinel = "Bearer " + "secret-sentinel-" + "F" * 24
        plausible = "Bearer " + "opaque-" + "E" * 24
        artifact = root / "bearers.zip"
        with zipfile.ZipFile(artifact, "w") as archive:
            archive.writestr("bearers.txt", synthetic + "\n" + sentinel + "\n" + plausible)

        report = self._scan(root, "artifact", "-Artifact", str(artifact))

        self.assertEqual(report["finding_count"], 1)
        self.assertEqual(report["valid_secret_finding_count"], 1)
        self.assertEqual(report["findings"][0]["rule_id"], "generic-bearer")
        self.assertNotIn(synthetic, json.dumps(report))
        self.assertNotIn(sentinel, json.dumps(report))
        self.assertNotIn(plausible, json.dumps(report))

    def test_log_directory_is_scanned_without_value_output(self) -> None:
        temporary, root = self._repo()
        self.addCleanup(temporary.cleanup)
        logs = root / "logs"
        logs.mkdir()
        secret = "sk-" + "C" * 24
        (logs / "job.log").write_text(secret, encoding="utf-8")

        report = self._scan(root, "artifact", "-Artifact", str(logs))

        self.assertEqual(report["valid_secret_finding_count"], 1)
        self.assertEqual(report["artifact_size_bytes"], len(secret))
        self.assertIsNone(report["artifact_sha256"])
        self.assertNotIn(secret, json.dumps(report))


if __name__ == "__main__":
    unittest.main()

# Redacted secret scanner

This task-owned scanner covers Git-tracked worktree files, every reachable Git
blob (including reachable tags), and files/directories/ZIP or APK artifacts.
It never reads untracked worktree files and never writes matched values. Reports
contain only locations, rule/class identifiers, and one-way SHA-256 fingerprints.

The implementation, rule set, Python test runtime, and CI Actions are pinned in
`scanner-lock.json`. Verify those hashes before running the scanner.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\security\secret-scan\Invoke-SecretScan.ps1 `
  -Mode worktree -Repo . -Output .\worktree-secret-scan.json

powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\security\secret-scan\Invoke-SecretScan.ps1 `
  -Mode history -Repo . -Registry .\docs\execution\evidence\phase-00\P00-003\security\revoked-history-registry.json `
  -Output .\history-secret-scan.json
```

Artifact mode accepts `-Artifact <file-or-directory>` and an optional
`-KnownFingerprint <sha256>`. A private-key header without a complete matching
PEM block is retained as a heuristic finding but is not counted as a valid
secret. Any other rule match is fail-closed.

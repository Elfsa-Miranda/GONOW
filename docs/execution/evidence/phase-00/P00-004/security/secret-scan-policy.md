# P00-004 redacted secret-scan policy

- Scope: Git-tracked worktree files, every reachable Git blob/tag, CI checkout,
  and explicitly named build/release artifacts. Untracked worktree files are not
  read.
- Output: location, line, rule/class, object ID where applicable, and one-way
  SHA-256 fingerprint only. Match bodies, environment values, JWTs, PII, prompts,
  responses, and reasoning are prohibited.
- Baseline: the P00-003 revoked-history registry is immutable input. Existing
  reachable occurrences must match its exact `(blob_oid,path,line,rule_id)` set;
  any additional occurrence or set drift blocks the affected action.
- Classification: a lone private-key header is heuristic; a complete PEM block
  or any other configured credential rule is a valid finding and fails closed.
- Incident link: the known historical provider fingerprint remains linked to
  `TASK-P00-003`; provider revocation, cost controls, and owner receipts remain
  external pending work and are not represented as completed by this scan.
- Locking: scanner/rule bytes, Python runtime, and GitHub Actions are pinned by
  SHA-256/full commit SHA in `scanner-lock.json`. CI verifies local file hashes
  before tests or scans.
- Rollback: revert the scanner, rules, workflow, and reports together. Never
  rewrite Git history or restore the exposed credential.

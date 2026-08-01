# TASK-P04-089 root-cause and repair record

## Security path classification failure

- Reproduction: Documentation passed, then Security stopped while `git ls-files --error-unmatch`
  classified the first new untracked documentation path.
- Root cause and impact: the runner used a deliberately failing native Git command as a
  tracked/untracked predicate. Its nonzero exit leaked into the gate process before any
  security result was emitted. Only P04-089 Security was affected; no document, implementation,
  dataset, external service, or production state was changed by the failed read.
- Reversible repair: enumerate tracked paths once with successful `git ls-files`, then perform
  exact in-memory membership checks. Tracked files are scanned from added diff lines; new files
  are scanned from their full bytes. The scanner continues to exclude only the runner's own
  regex source to avoid self-matches.
- Affected regression: rerun Security, then WorksetVerify, RollbackVerify, full Agent CI, and all
  P04-089 closure modes. Expected secret, PII, unsafe command, implementation, unexpected-path,
  and production-write counts are zero.

## Catalog negative-test fixture drift

- Reproduction: the first full CI run stopped after 32 passing tests because
  `test_harness_catalog_rejects_fake_implemented_control` did not raise.
- Root cause and impact: its mutation searched for control 7 in `contract_only` state. P04-089
  legitimately projected control 7 to `implemented`, so the replacement became a no-op and the
  test parsed an unchanged valid Catalog. Only this negative fixture was affected; Catalog
  validation and control 7 implementation remained valid.
- Reversible repair: move the mutation to control 14, which remains `contract_only` until
  Phase 6, and replace its test path with a missing file while changing status to implemented.
  The original security property is unchanged: a fake implemented control without an exact
  test file must fail closed.
- Affected regression: run `test_harness_contracts.py`, then full Agent CI. No threshold,
  control status, or parser behavior is weakened.

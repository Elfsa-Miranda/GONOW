# BLK-P10-009 — C4 sample source binding

- Status: `repair_validated_pending_candidate_rotation`
- Failed candidate: `13bb7c6d2929ae610f5243cf47afaa8797a6f2a3`
- Scope: C4 aggregation metadata only
- Production writes: `0`
- Duplicate soak executions: `0`

## Reproduction

The single authorized C4 aggregation ran after the original observer/workload process
completed successfully. The independent pre-aggregation verifier proved:

- `real_soak_seconds=14400.000558`
- `sample_count=480`; `slope_sample_count=360`; `iteration_count=266037`
- observer PID `32744` and workload PID `25664` were positive and different
- child exit, child scratch, workload failure, positive resource slope, production write,
  and candidate drift counts were all `0`
- samples were strictly time-monotonic, iteration/failure counts were nondecreasing, and
  resources returned to baseline
- `samples_sha256=3c9af9bb8757f93c7fac4f41cbd6b5c69357bb587c3336534d450dfba918249b`
- sample artifact SHA-256
  `5cde4d8c262b0903f879f53d5a1891b8e3cbac436cce77b8264fc56c63f8d7b5`
- soak report SHA-256
  `baf8d9177fec7269b5628edfb28b53fda852b9f59d90b2356e3bb4a82b80cbc0`

The aggregation command then exited nonzero with one C4 failure only:
`supporting_report_binding_invalid:soak-samples.json`. Its generated
`c4-recovery-time-soak.json` had `status=passed` and correctly bound fault, virtual-time,
Judge, and soak reports, but its four-row `source_artifacts` omitted
`soak-samples.json`. No second aggregation or soak was started.

## Root cause and impact surface

`PersonalReleaseCertification.psd1` freezes five C4 supporting reports, including both
`soak-report.json` and `soak-samples.json`. `run_c4()` in
`agent-service/tests/certification/c4_recovery_soak.py` emitted only the soak report as a
direct gate source. The soak report already carried the sample file hash and the canonical
sample-set hash, so the underlying evidence was intact; the generic PowerShell aggregator
correctly rejected the missing direct source row.

The defect affects only C4 gate-source materialization. It does not change the measured
workload, resource probes, binary sample decoder, timing, PostgreSQL isolation, slope
calculation, or completed sample bytes. C1, C3, C5, the still-pending C2 live shard, and
production state are unaffected.

## Reversible repair

- Treat `soak-samples.json` as an explicit C4 source whenever it exists.
- Fail closed with `c4.soak_samples_missing` when a soak report exists without its sample
  artifact; do not let the source-artifact constructor crash or silently omit the row.
- Preserve the existing nested sample hashes and PowerShell semantic validation; the new
  row is an additional exact path/file-hash binding, not weaker evidence.
- Keep the repair in a new clean worktree/branch. Do not run repaired untracked code while
  claiming the old candidate; integrate it first so the next certification manifest binds
  a real tracked commit.

Rollback is a single repair-commit revert. It changes no database, provider, remote ref,
feature allocation, or production data.

## Measured-code equivalence boundary

AST source-segment hashes were recomputed from the failed candidate worktree and this
repair worktree. All six measured-path functions are byte-identical:

| Function | SHA-256 |
|---|---|
| `_windows_process_api` | `cf9945bbf46c9e95c0c87940997cbe46fbfa9bd8099def22339cf82f42c52177` |
| `_rss_bytes` | `20a9cd1aaba4d4421952990a81caceddab8c25b08575a401b360c2acab86b29c` |
| `_handle_count` | `9b49d9b726abdc4eaaa7d6cf5205e056de55e65cbb5ba409245d7bee200eb162` |
| `_decode_soak_samples` | `74d8679eba933d1fa560864987157254a83280c63deadbd8c01ab2de03f0aad9` |
| `_soak_child_main` | `9c1407ec42d89ccbe459ec1242062415713f41ad37a164e15011d9e6065ea998` |
| `run_real_soak` | `7b6bc93cdf39c63ef6f64929bd8a4570dcea316eaee31d9e27271f1abb2d84b8` |

Therefore the completed four-hour source may be reused after candidate rotation only for
this metadata-only repair. Any change to one of those hashes, the soak report/sample
hashes, the database kind, or the candidate ancestry invalidates reuse and requires a new
soak. The next gate report and certification manifest must bind the repaired commit; the
old candidate must not be relabelled in place.

## Affected regression

- Formal-soak predicate regression, direct sample-source positive regression, and missing
  sample fail-closed regression: `3 passed`; the complete compressed-certification
  harness file then passed `16/16` tests.
- Isolated integration against copies of the completed real soak artifacts: C4
  `status=passed`, exact source count `5`, binding failure count `0`, and the direct sample
  source hash matched
  `5cde4d8c262b0903f879f53d5a1891b8e3cbac436cce77b8264fc56c63f8d7b5`.
- Python AST parse for both changed Python files and `git diff --check`: passed. The
  repository `pyproject.toml`/lock does not declare Ruff, so no unpinned Ruff result is
  claimed; this does not replace the later locked full CI/TaskGate regression.
- Full affected certification/TaskGate regression: pending until the repair is committed
  and integrated as a new candidate; it must use a fresh manifest and must not start a
  second four-hour soak.

## Recovery condition

Commit and integrate this bounded repair, record the new candidate OID, archive the failed
candidate's aggregate attempt without altering its original reports, materialize a fresh
certification manifest for the new candidate, and rerun only replayable/affected shards.
For C4, copy the immutable soak report and sample file with the exact hashes above, prove
the measured-function equivalence table again from the two commits, run one repaired C4
aggregation, and require all five direct source bindings plus every existing semantic
predicate to pass. C2 must later run against the new candidate in its clean monitor
worktree; no partial old-candidate live calls count as progress.

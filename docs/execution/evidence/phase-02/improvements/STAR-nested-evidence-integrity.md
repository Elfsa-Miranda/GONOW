# STAR: nested evidence integrity

## Situation

P02-006 generated nine CI reports under `ci-reports/`, while the generic Phase 2
evidence collector enumerated only top-level task evidence files. The gate said
`unhashed_artifacts=0`, but the artifact manifest contained 5 entries and no
nested report.

## Task

Preserve the existing evidence schema and task paths while making every generated
CI report independently content-addressed, without rewriting earlier Catalog or status provenance.

## Action

The generic P02 evidence collector changed its evidence enumeration to recursive
file traversal and added a runner regression asserting that recursion remains.
P02-006 Evidence was then regenerated at a fixed candidate OID.

## Result

The P02-006 artifact manifest increased from 5 to 14 entries and contains all 9
nested CI reports; `schema_errors=0`, `unhashed_artifacts=0`, and
`redaction_failures=0`. Reproduce with:

```powershell
& .\docs\execution\commands\Invoke-TaskGate.ps1 -TaskId TASK-P02-006 -Mode Evidence
```

The bound P02-006 status and gate evidence retain the exact candidate OID and
artifact hashes. This is an evidence-integrity improvement, not a production
runtime or performance claim.

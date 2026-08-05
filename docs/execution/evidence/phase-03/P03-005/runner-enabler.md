# TASK-P03-005 runner enabler

## Root cause and impact

The generated Catalog entry has empty executable adapters for P03-005 and its
`file_allowlist` omits `contracts/behavior-manifest-v1.schema.json` and
`contracts/digest-vectors-v1.json`, although the sealed execplan card explicitly
requires and allows both files. Direct `Import-PowerShellDataFile` is also not a
valid reader for this one-line Catalog because its dynamic `$null` expression is
rejected by the safe data-file evaluator. Catalog bytes remain read-only.

## Reversible repair

`Invoke-TaskGate.ps1` now supplies task-scoped adapters that:

- run the Python contract suite, Dart shared-vector suite, and affected-path analyzer;
- compare all three Python/Dart canonical-byte and SHA-256 vector records;
- require four negative vectors and the RFC 8785 numeric edge suite;
- scan runtime files for execution primitives, secrets, and missing body guards;
- hash the literal execplan deliverables and evidence;
- allow exactly the two omitted contract paths in addition to Catalog paths.

The full-repository Flutter analyzer remains explicitly
`pending_baseline_repair`; only the two P03-005 paths are treated as locally
green. Reverting the runner block and deleting P03-005 evidence restores the
previous runner. No production, remote, Catalog, or governance object changed.

# BLK-P04-000 — E0 validator launch and bundle digest ordering

- Status: resolved locally
- Scope: `TASK-P04-000` mechanical validation only
- Production impact: none; no model call, production read/write, push, or merge occurred

## Reproduction

The first P04-000 `Verify` run returned `validation_exit_code=1` without a report. Adding a bounded exception classifier produced `SyntaxError: leading zeros in decimal integer literals are not permitted`. Executing the same imports from the service virtual environment succeeded, isolating the failure to the multiline `python -c` transport through Windows PowerShell 5.1.

After executing an OS-temporary script file instead, the same gate reached all assertions and reported one failure: `dataset_sha256_actual=8f5bf67e...` versus frozen `c46161c1...`. A reverse-order diagnostic reproduced `c46161c1...` exactly while the manifest paths were ascending.

## Root cause, exclusions, and impact surface

1. PowerShell 5.1 native argument quoting removed embedded Python string quotes from the multiline `-c` argument.
2. The initial dataset subset digest was generated in `requests, labels` order even though UTF-8 path order is `labels, requests`.

The virtual environment, `jsonschema`, JCS implementation, JSONL syntax, record schema, case IDs, labels, scoring thresholds, individual file hashes, and six rejection vectors were independently shown healthy. The affected surface was validator launch and the derived dataset/manifest digest chain only.

## Complete reversible repair

- Execute a unique temporary `.py` file and remove script/report in `finally`.
- Sort the dataset subset by POSIX-relative path UTF-8 bytes before canonical JSON serialization.
- Replace only the derived dataset hash and downstream raw/JCS/Windows/Linux manifest digests.
- Preserve every request, label, schema rule, scoring threshold, and formal approval boundary.

Rollback is a revert of the gate-runner enabler and the not-yet-consumed E0 candidate files. No downstream Graph exists at this point.

## Affected regression and recovery condition

Recovery requires parser success, the runner contract suite, and P04-000 Verify with 30 common + 10 boundary cases, 80/80 schema-valid records, zero duplicate/join errors, six of six rejected path vectors, sorted dataset hash equality, manifest digest equality, Windows/Linux equality, and zero model/production writes.

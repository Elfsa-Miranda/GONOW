# BLK-P10-009 — certification self-test evidence ownership

## Plain-language summary

The PowerShell certification self-test completed its calculations but the test process could not read the result file. The runner deleted the caller-provided temporary evidence directory before returning. The safe repair is to distinguish caller-owned and internally-created self-test directories, preserve only the caller-owned directory for assertions, and keep automatic cleanup for internal scratch directories.

## Reproduction and root cause

- The first focused run exited before `Invoke-PersonalReleaseCertification.Tests.ps1` could read `personal-release-certification.json`.
- A direct reproduction proved the runner itself returned exit `0` and printed a five-gate passing result, while the supplied absolute evidence directory no longer existed immediately afterward.
- The runner unconditionally executed recursive cleanup whenever `-SelfTest` was present. Its earlier path resolver also ignored an absolute caller-supplied `-EvidenceRoot`, so the test and runner did not share an explicit evidence ownership contract.
- The same observable failure occurred a second time after only the path resolver was fixed, proving cleanup ownership—not result generation—was the remaining root cause. No product runtime, database, provider, or production path was affected.

## Reversible repair

- Mark an absolute self-test `EvidenceRoot` as caller-owned.
- Resolve and write to that exact directory, and leave it for the caller's `finally` block to remove.
- Continue creating and deleting an internal random temporary directory when no absolute caller-owned directory is supplied.
- Extend the self-test to execute the real C4 source validator over 480 monotonic sample records and a full isolated-child report, plus a tampered same-process report.

Rollback is a normal revert of the runner and test commit. The repair has no schema, production, credential, or external side effect.

## Affected regression and final state

The PowerShell suite now passes one positive fixture and ten negative fixtures. It confirms C1–C5 order, the 14,400-second C4 floor, fail-closed governance, distinct C4 observer/workload processes at both Gate and raw-source levels, and zero production writes.

`resolved` — caller-owned evidence is readable until the caller removes it, internal scratch remains self-cleaning, and the original failure is reproducible only on the pre-repair runner.

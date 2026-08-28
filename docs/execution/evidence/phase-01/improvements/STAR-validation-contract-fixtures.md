# STAR: validation contract fixtures

## Situation

Validation and fallback behavior was distributed across Flutter call sites and broad maps. There
was no versioned four-class result contract or stable synthetic regression corpus.

## Task

Freeze importable-but-never-authoritative Candidate semantics without changing production traffic
or adding a runtime dependency.

## Action

Added `contracts/validation-semantics-v1.schema.json`, the normative architecture document, 8
synthetic positive/negative fixtures, and `test/validation_semantics_test.dart`. The tests enforce
classification precedence, reject domain-write enablement, and preserve fallback input.

## Result

Before: 0 versioned validation schema, 0 numbered fixtures, and 0 dedicated semantic tests.
After: 1 strict schema, 8 synthetic fixtures, and 3/3 local Flutter tests passed with 0 failures and
0 skips. Reproduce from the repository root with
`flutter test test/validation_semantics_test.dart`; source report:
`docs/execution/evidence/phase-01/P01-003/local-test-report.json`.

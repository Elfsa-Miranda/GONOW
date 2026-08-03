# BLK-P11-089 Harness fragment hash-domain mismatch

- Status: repaired locally.
- Reproduction: `HarnessCatalogAggregate` reported 34 unique controls, 149 minimum cases, zero missing implemented test paths, but rejected the valid P11-006 fragment.
- Root cause: the fragment fields `catalog_sha256_before/after` bind `TaskGateCatalog.psd1`, while the aggregator compared them with the separate `harness-test-catalog.yaml` hash.
- Impact: control 23's seven S/I/D citation cases could not be aggregated even though their fragment, status, JUnit-derived counts, and Git object were present.
- Excluded causes: missing test path, control-count drift, minimum-case drift, status downgrade, skipped/xfailed cases, or source fragment absence.
- Reversible repair: compare fragment catalog bindings with the TaskGate Catalog hash, while continuing to record the Harness Catalog hash separately as previous/pre-mutation/new catalog identity. The same correction applies in local and formal execution modes.
- Regression scope: PowerShell parser, TaskGate contract tests, P11-089 Harness aggregation, Evidence, and Workset verification.
- Recurrence diagnostic: the second affected run still returned a monolithic invalid result even though an independent expansion showed every predicate true. The repair therefore replaces the opaque boolean chain with named predicate results and records the exact failing predicate names plus both catalog-domain hashes. This removes ambiguous operator binding and makes any future failure discriminating rather than repeat-only.
- Confirmed second root cause: the named predicates showed `control_row_unique`, `control_action_match`, and `test_path_match` failing together. Windows PowerShell 5.1 unwraps the single object emitted by an `if` expression even when the branch itself uses `@(...)`; the resulting scalar does not provide the expected collection `Count` behavior. The repair wraps the whole conditional expression in `@(...)`, preserving a one-row collection on the repository's supported shell.
- Rollback: revert this repair commit; no catalog content, runtime code, database, external object, or production state is changed.

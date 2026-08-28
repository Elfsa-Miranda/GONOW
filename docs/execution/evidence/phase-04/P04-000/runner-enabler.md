# P04-000 gate runner enabler

## Reproduction

The frozen catalog allows `Verify`, `Security`, `Evidence`, `WorksetVerify`, and `ApprovalValidation` for `TASK-P04-000`, but the generic runner initially had no task-specific handlers. A generic pending result could not prove the E0 card's quantitative assertions.

## Root cause and impact

Phase 4 was the first consumer of the E0 gold-contract modes. The materialized runner implemented Phase 3 task handlers but did not yet encode the P04-000 schema, digest, source, workset, artifact, or approval checks. The impact was limited to P04-000 mechanical evaluation; the dataset bytes and earlier phase evidence were not changed.

## Reversible repair

The runner now validates the 40 synthetic cases, one-to-one labels, JSON Schema, raw-byte file identities, JCS digest, path rejection vectors, scoring thresholds, data source, exact task allowlist, artifacts, and immutable approval bindings. Validation scratch output is created under the OS temporary directory and deleted after parsing so the repair does not add an undeclared repository artifact. Formal approvals remain empty and `pending_external` in local provisional mode.

The first affected run also exposed a Windows PowerShell 5.1 native-argument defect: passing the multiline validator through `python -c` stripped embedded quotes. The bounded repair writes the validator to a unique OS-temporary `.py` file, executes that file, hashes only diagnostic output, and deletes both script and report in `finally`. After execution became reliable, the validator distinguished a second contract defect: the initially frozen dataset-subset digest used reverse path order. The candidate was corrected to independently sort the subset by UTF-8 path bytes and to cascade the resulting manifest raw/JCS digests before any Graph consumer existed.

Rollback is a single revert of this enabler commit. It does not alter product code, model behavior, production data, the frozen catalog, or the sealed guidance.

## Affected regression

PowerShell parser validation and the complete `Invoke-TaskGate.Tests.ps1` contract suite must pass before this runner change is committed. P04-000 Verify then must prove 40 joined cases, 80 schema-valid records, six path rejections, exact sorted bundle identity, matching manifest JCS digests, and zero writes.

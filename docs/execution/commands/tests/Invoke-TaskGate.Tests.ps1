$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$CatalogPath = Join-Path $Root 'TaskGateCatalog.psd1'
try {
  $Catalog = Import-PowerShellDataFile -LiteralPath $CatalogPath
} catch {
  if ($PSVersionTable.PSVersion.Major -ne 5 -or
      $_.Exception.Message -cnotmatch 'dynamic expressions|SafeGetValue') {
    throw
  }
  $Tokens = $null
  $ParseErrors = $null
  $Ast = [Management.Automation.Language.Parser]::ParseFile(
    $CatalogPath,
    [ref]$Tokens,
    [ref]$ParseErrors
  )
  if (@($ParseErrors).Count -ne 0 -or $Ast.EndBlock.Statements.Count -ne 1) {
    throw 'compatibility Catalog parse failed'
  }
  $RootExpression = $Ast.EndBlock.Statements[0].PipelineElements[0].Expression
  $Catalog = @{}
  foreach ($Pair in $RootExpression.KeyValuePairs) {
    $Key = [string]$Pair.Item1.SafeGetValue()
    if ($Key -cne 'Tasks') {
      $Catalog[$Key] = $Pair.Item2.SafeGetValue()
      continue
    }
    $TasksExpression = $Pair.Item2
    if ($TasksExpression -is [Management.Automation.Language.PipelineAst]) {
      $TasksExpression = $TasksExpression.PipelineElements[0].Expression
    }
    $Tasks = @{}
    foreach ($TaskPair in $TasksExpression.KeyValuePairs) {
      $Tasks[[string]$TaskPair.Item1.SafeGetValue()] = $TaskPair.Item2.SafeGetValue()
    }
    $Catalog[$Key] = $Tasks
  }
}
if (@($Catalog.Tasks.Keys).Count -ne 153) { throw 'positive: expected 153 tasks' }
if ($Catalog.Tasks.ContainsKey('TASK-DOES-NOT-EXIST')) { throw 'negative: unknown task accepted' }
if (@($Catalog.TaskGateModeContracts.Keys).Count -ne 23) { throw 'positive: expected 23 task modes' }
$RunnerText = [IO.File]::ReadAllText((Join-Path $Root 'Invoke-TaskGate.ps1'), [Text.UTF8Encoding]::new($false))
if ($RunnerText -notmatch 'foreach \(\$Key in \$Checks\.Keys\)') {
  throw 'negative: BOOT-005 dependency audit must enumerate OrderedDictionary keys'
}
if ($RunnerText -notmatch 'function Write-TaskBlockerEvidence') {
  throw 'negative: blocked task status must reference materialized task evidence'
}
if ($RunnerText -notmatch "function Get-P00LocalProjection") {
  throw 'positive: P00-990 must mechanically separate local projection from formal acceptance'
}
if ($RunnerText -notmatch "formal_acceptance_status = 'pending_external'") {
  throw 'negative: P00-990 local projection must preserve the formal acceptance boundary'
}
if ($RunnerText -match "Set-TaskStatus -Status 'accepted'") {
  throw 'negative: the task runner must never self-approve accepted status'
}
if ($RunnerText -notmatch "Get-P00GateModeState -IncludeVerify") {
  throw 'negative: P00-990 must not become ready_for_review before all registered local modes pass'
}
if ($RunnerText -notmatch "TASK-P01-001" -or
    $RunnerText -notmatch 'incomplete_source_sink_fallback_count') {
  throw 'negative: P01-001 must verify every mapped source, sink, and fallback'
}
if ($RunnerText -notmatch 'manifest_execution_mode_match' -or
    $RunnerText -notmatch 'formal_dependency_satisfied') {
  throw 'negative: a local phase-entry manifest must not satisfy formal mode'
}
if ($RunnerText -notmatch 'merge-base --is-ancestor \(\[string\]\$Manifest\.phase_base_oid\) \$Head') {
  throw 'negative: phase base must remain an ancestor rather than equal every later task HEAD'
}
if ($RunnerText -notmatch "TASK-P09-001" -or
    $RunnerText -notmatch 'phase_09_entry_manifest_creation_failed' -or
    $RunnerText -notmatch 'minimum_unit_tests=519' -or
    $RunnerText -notmatch 'phase_9_local_entry_projection_valid') {
  throw 'negative: Phase 9 entry must materialize and bind the P08 local checkpoint projection'
}
$P10EntryMarker = "if (`$TaskId -ceq 'TASK-P10-001') {"
$P09EntryMarker = "if (`$TaskId -ceq 'TASK-P09-001') {"
$PreflightStart = $RunnerText.IndexOf('function Invoke-ModePreflight {', [StringComparison]::Ordinal)
$P10EntryStart = $RunnerText.IndexOf($P10EntryMarker, $PreflightStart, [StringComparison]::Ordinal)
$P09EntryStart = $RunnerText.IndexOf($P09EntryMarker, $P10EntryStart + $P10EntryMarker.Length, [StringComparison]::Ordinal)
if ($PreflightStart -lt 0 -or $P10EntryStart -lt $PreflightStart -or $P09EntryStart -le $P10EntryStart) {
  throw 'negative: P10-001 specialized phase-entry branch is missing or shadowed'
}
$P10EntryBlock = $RunnerText.Substring($P10EntryStart, $P09EntryStart - $P10EntryStart)
if ($P10EntryBlock -notmatch '\$script:Task\.phase_runtime_manifest_path' -or
    $P10EntryBlock -notmatch 'phase_10_entry_manifest_creation_failed' -or
    $P10EntryBlock -notmatch 'prior_phase_integration_receipt_sha256' -or
    $P10EntryBlock -notmatch 'minimum_unit_tests=542' -or
    $P10EntryBlock -notmatch 'minimum_contract_tests=144' -or
    $P10EntryBlock -notmatch 'minimum_tests=82') {
  throw 'negative: Phase 10 entry must materialize its manifest and bind the P09 provisional integration checkpoint'
}
if ($RunnerText -notmatch 'Get-P10001GateModeState' -or
    $RunnerText -notmatch 'p10_001_verify_failed' -or
    $RunnerText -notmatch 'trace-topology-report\.json' -or
    $RunnerText -notmatch 'P09-089\\harness-catalog-aggregate\.json' -or
    $RunnerText -notmatch 'pii_canary_leak_count' -or
    $RunnerText -notmatch 'harness-status-fragment\.json' -or
    $RunnerText -notmatch 'p10_001_security_failed' -or
    $RunnerText -notmatch 'p10_001_workset_failed' -or
    $RunnerText -notmatch 'CandidateBelongsToPhase' -or
    $RunnerText -notmatch 'p10_001_rollback_verification_failed') {
  throw 'negative: P10-001 must own trace, redaction, harness, workset, evidence, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P10002GateModeState' -or
    $RunnerText -notmatch 'p10_002_verify_failed' -or
    $RunnerText -notmatch 'required metrics have type/unit/owner' -or
    $RunnerText -notmatch 'p10_002_security_failed' -or
    $RunnerText -notmatch 'p10_002_workset_failed' -or
    $RunnerText -notmatch 'p10_002_rollback_verification_failed') {
  throw 'negative: P10-002 must own bounded metrics, dashboard, security, evidence, workset, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P09001GateModeState' -or
    $RunnerText -notmatch 'p09_001_verify_failed' -or
    $RunnerText -notmatch 'breaking_changes' -or
    $RunnerText -notmatch 'root_baseline_issue_count=109' -or
    $RunnerText -notmatch 'p09_001_dependency_audit_failed' -or
    $RunnerText -notmatch 'Set-ReadyForReviewStatus') {
  throw 'negative: P09-001 must own deterministic codegen, non-regression, supply-chain, and status gates'
}
if ($RunnerText -notmatch 'Get-P09002GateModeState' -or
    $RunnerText -notmatch 'p09_002_verify_failed' -or
    $RunnerText -notmatch 'http_error_corpus_total=9' -or
    $RunnerText -notmatch 'repository_exception_leak_count' -or
    $RunnerText -notmatch 'p09_002_security_failed') {
  throw 'negative: P09-002 must own typed HTTP corpus, safe fallback, exception containment, and security gates'
}
if ($RunnerText -notmatch 'Get-P09003GateModeState' -or
    $RunnerText -notmatch 'p09_003_verify_failed' -or
    $RunnerText -notmatch 'restart_restore_passed' -or
    $RunnerText -notmatch 'persisted_field_count=4' -or
    $RunnerText -notmatch 'arbitrary_sql_executor_count' -or
    $RunnerText -notmatch 'p09_003_security_failed') {
  throw 'negative: P09-003 must own restart recovery, minimal persistence, terminal cleanup, and storage security gates'
}
if ($RunnerText -notmatch 'Get-P09004GateModeState' -or
    $RunnerText -notmatch 'p09_004_verify_failed' -or
    $RunnerText -notmatch 'backoff_attempts_total=15' -or
    $RunnerText -notmatch 'duplicate_side_effect_count=0' -or
    $RunnerText -notmatch 'identity_denied_mismatch' -or
    $RunnerText -notmatch 'p09_004_security_failed') {
  throw 'negative: P09-004 must own bounded SSE recovery, de-duplication, control authorization, and audit gates'
}
if ($RunnerText -notmatch 'Get-P09005GateModeState' -or
    $RunnerText -notmatch 'lib/features/itinerary_agent/presentation/' -or
    $RunnerText -notmatch 'p09_005_verify_failed' -or
    $RunnerText -notmatch 'unapproved_business_write_count' -or
    $RunnerText -notmatch 'a11y_fixture_passed' -or
    $RunnerText -notmatch 'error_fixture_passed' -or
    $RunnerText -notmatch 'BLK-P09-002-lazy-candidate-semantics.md' -or
    $RunnerText -notmatch 'p09_005_security_failed') {
  throw 'negative: P09-005 must own Candidate presentation materialization, no-write, accessibility, error, blocker, and security gates'
}
if ($RunnerText -notmatch 'Get-P09006GateModeState' -or
    $RunnerText -notmatch 'agent-service/app/persistence/repositories/domain_commands.py' -or
    $RunnerText -notmatch 'p09_006_verify_failed' -or
    $RunnerText -notmatch 'pytest_test_count=\$Tests' -or
    $RunnerText -notmatch 'stale_version_cases_passed' -or
    $RunnerText -notmatch 'forged_capability_cases_passed' -or
    $RunnerText -notmatch 'itinerary_effect_count' -or
    $RunnerText -notmatch 'outbox_effect_count' -or
    $RunnerText -notmatch 'no_extra_boundary' -or
    $RunnerText -notmatch 'BLK-P09-006-production-itinerary-mapping-unknown.md' -or
    $RunnerText -notmatch 'p09_006_security_failed' -or
    $RunnerText -notmatch 'p09_006_rollback_verification_failed') {
  throw 'negative: P09-006 must own its implementation paths, direct JUnit materialization, exact rejection/effect counts, fail-closed production mapping blocker, security, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P09009GateModeState' -or
    $RunnerText -notmatch 'agent-service/tests/performance/test_read_model_need.py' -or
    $RunnerText -notmatch 'p09_009_verify_failed' -or
    $RunnerText -notmatch 'query_profile_count' -or
    $RunnerText -notmatch 'total_query_samples-eq120' -or
    $RunnerText -notmatch 'visibility_sample_count' -or
    $RunnerText -notmatch "status='resolved_local'" -or
    $RunnerText -notmatch 'P09-009/blocker.json' -or
    $RunnerText -notmatch 'production_claim_authorized' -or
    $RunnerText -notmatch 'runtime_or_schema_change_count' -or
    $RunnerText -notmatch 'p09_009_security_failed' -or
    $RunnerText -notmatch 'p09_009_rollback_verification_failed') {
  throw 'negative: P09-009 must own its query/SLA/sample report, resolved diagnostic receipt, no-production-claim boundary, no-read-model decision, security, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P09008GateModeState' -or
    $RunnerText -notmatch 'agent-service/tests/contract/test_client_compatibility.py' -or
    $RunnerText -notmatch 'test/itinerary_agent/service_compatibility_test.dart' -or
    $RunnerText -notmatch 'old_app_old_service' -or
    $RunnerText -notmatch 'new_app_new_service' -or
    $RunnerText -notmatch 'matrix_passed_count' -or
    $RunnerText -notmatch 'historical_source_artifacts_available' -or
    $RunnerText -notmatch 'service_contract_blob_equal' -or
    $RunnerText -notmatch 'forced_upgrade_count' -or
    $RunnerText -notmatch 'p09_008_security_failed' -or
    $RunnerText -notmatch 'p09_008_rollback_verification_failed') {
  throw 'negative: P09-008 must own its four-path source-bound compatibility matrix, failures, report, no-forced-upgrade boundary, security, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P09010GateModeState' -or
    $RunnerText -notmatch 'integration_test/itinerary_agent_journey_test.dart' -or
    $RunnerText -notmatch 'integration_test/itinerary_agent_weak_network_test.dart' -or
    $RunnerText -notmatch 'integration_test/itinerary_agent_accessibility_test.dart' -or
    $RunnerText -notmatch 'journey_steps_passed' -or
    $RunnerText -notmatch 'weak_network_cases_passed' -or
    $RunnerText -notmatch 'accessibility_cases_passed' -or
    $RunnerText -notmatch 'exact-byte-flutter-vm-copy' -or
    $RunnerText -notmatch 'source_copy_hash_mismatch_count' -or
    $RunnerText -notmatch "formal_mobile_device_status='pending_external'" -or
    $RunnerText -notmatch "status='resolved_local'" -or
    $RunnerText -notmatch 'P09-010/blocker.json' -or
    $RunnerText -notmatch 'mandatory_skip_count' -or
    $RunnerText -notmatch 'p09_010_security_failed' -or
    $RunnerText -notmatch 'p09_010_rollback_verification_failed') {
  throw 'negative: P09-010 must own its full journey, weak-network, old-path, accessibility, no-skip, security, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P09007GateModeState' -or
    $RunnerText -notmatch 'p09_007_verify_failed' -or
    $RunnerText -notmatch 'ordinary_chat_bypass_cases_passed' -or
    $RunnerText -notmatch 'legacy_touched_file_baseline_issue_count=29' -or
    $RunnerText -notmatch 'no_extra_boundary' -or
    $RunnerText -notmatch 'p09_007_security_failed') {
  throw 'negative: P09-007 must own legacy-off, ordinary-chat bypass, generation, kill-switch, and audit gates'
}
if ($RunnerText -notmatch "TASK-P01-002" -or
    $RunnerText -notmatch 'domain_write_const_false_count') {
  throw 'negative: P01-002 must keep validation results outside the formal write authority'
}
if ($RunnerText -notmatch "TASK-P01-003" -or $RunnerText -notmatch 'orphan_contract') {
  throw 'negative: P01-003 must reject orphan contract cases and non-deterministic test reports'
}
if ($RunnerText -notmatch 'DependencyStatus\.status -ceq ''accepted'' -and \[bool\]\$DependencyStatus\.reviewer_independent') {
  throw 'negative: formal task dependencies must be independently accepted'
}
if ($RunnerText -notmatch 'function Get-P01LocalProjection' -or
    $RunnerText -notmatch 'function Get-P01GateModeState' -or
    $RunnerText -notmatch 'Write-P01LocalProjectionEvidence -ReadyForReview \$true') {
  throw 'negative: P01-990 must bind a complete local projection before Phase 2 entry'
}
if ($RunnerText -notmatch "TASK-P01-089" -or
    $RunnerText -notmatch "Phase 1 freezes contract/schema semantics and owns no implemented harness transition") {
  throw 'negative: P01-089 must archive its handoff without fabricating harness implementation'
}
if ($RunnerText -notmatch 'function Set-ReadyForReviewStatus' -or
    $RunnerText -notmatch 'evidence-refresh-without-status-transition') {
  throw 'negative: regenerated gate evidence must refresh the ready status hash without forging a status transition'
}
if ($RunnerText -notmatch "TASK-P02-001" -or
    $RunnerText -notmatch "source_evidence_hash_drift" -or
    $RunnerText -notmatch "TASK-P01-990") {
  throw 'negative: Phase 2 local entry must bind the Phase 1 checkpoint status and gate evidence'
}
if ($RunnerText -notmatch 'p02_001_entrypoint_verification_failed' -or
    $RunnerText -notmatch 'p02_001_dependency_audit_failed' -or
    $RunnerText -notmatch 'p02_001_security_boundary_failed') {
  throw 'negative: P02-001 must have task-specific build, supply-chain, and security gates'
}
if ($RunnerText -notmatch 'recovered_diagnostic_failure_count=\$RecoveredDiagnostics' -or
    $RunnerText -notmatch 'Group-Object description') {
  throw 'negative: P02-001 must distinguish a resolved diagnostic from the latest gate result'
}
if ($RunnerText -notmatch 'function Get-P02TaskPathRules' -or
    $RunnerText -notmatch 'function Get-P02ServicePython' -or
    $RunnerText -notmatch 'p02_workset_failed') {
  throw 'negative: Phase 2 task gates must share strict path and locked-project-environment enforcement'
}
if ($RunnerText -notmatch 'directory_rules=\$DirectoryRules' -or
    $RunnerText -notmatch 'name_regex') {
  throw 'negative: Phase 2 directory allowlists must enforce their Catalog filename regex'
}
if ($RunnerText -notmatch 'test_32_secrets_provider' -or
    $RunnerText -notmatch 'missing_secret_readiness_false' -or
    $RunnerText -notmatch 'harness-status-fragment.json') {
  throw 'negative: P02-002 must execute and bind the SecretsProvider S/I/D harness'
}
if ($RunnerText -notmatch 'function New-P02HarnessControlRecord' -or
    $RunnerText -notmatch 'catalog_sha256=\$script:CatalogSha256' -or
    $RunnerText -notmatch 'p02_003_auth_context_verification_failed') {
  throw 'negative: Phase 2 Harness fragments and the P02-003 auth corpus must be schema-bound'
}
if ($RunnerText -notmatch "TASK-P02-004" -or
    $RunnerText -notmatch 'p02_004_safe_observability_verification_failed' -or
    $RunnerText -notmatch 'log_schema_validation_percent=100') {
  throw 'negative: P02-004 must bind safe observability assertions and its Harness fragment'
}
if ($RunnerText -notmatch 'p02_005_lifecycle_verification_failed' -or
    $RunnerText -notmatch 'fixture_boundary_failures' -or
    $RunnerText -notmatch 'formal_clock_evidence_pending') {
  throw 'negative: P02-005 must distinguish local clock fixtures from formal measured clock evidence'
}
if ($RunnerText -notmatch 'p02_006_ci_verification_failed' -or
    $RunnerText -notmatch 'p02_006_dependency_audit_failed' -or
    $RunnerText -notmatch 'injection_executed_action_count') {
  throw 'negative: P02-006 must execute every mandatory CI and supply-chain gate'
}
if ($RunnerText -notmatch 'TaskEvidenceDirectory -Recurse -File') {
  throw 'negative: nested Phase 2 reports must be included in the evidence hash manifest'
}
if ($RunnerText -notmatch 'p02_007_openapi_verification_failed' -or
    $RunnerText -notmatch 'error_code_corpus_diff' -or
    $RunnerText -notmatch "ControlId 33") {
  throw 'negative: P02-007 must bind OpenAPI digest, error corpus, and SchemaRegistry Harness evidence'
}
if ($RunnerText -notmatch "authoritative_execplan_line=3920" -or
    $RunnerText -notmatch "missing_catalog_path='contracts/openapi/agent-api.yaml'") {
  throw 'negative: the P02-007 Catalog omission must remain explicit and narrowly projected'
}
if ($RunnerText -notmatch 'p02_008_inert_boundary_verification_failed' -or
    $RunnerText -notmatch 'provider_dependency_count' -or
    $RunnerText -notmatch 'network_deny_fixture_present') {
  throw 'negative: P02-008 must mechanically prove the API and Worker skeleton remains inert'
}
if ($RunnerText -notmatch 'function Get-P02089ClosureFiles' -or
    $RunnerText -notmatch 'p02_089_harness_catalog_invalid' -or
    $RunnerText -notmatch 'pending_independent_p02_handoff' -or
    $RunnerText -notmatch 'catalog_mutated=\$false') {
  throw 'negative: P02-089 must aggregate closure evidence without mutating the global Catalog or fabricating independent review'
}
if ($RunnerText -notmatch "TASK-P02-089'.*artifact-manifest\.premerge" -and
    $RunnerText -notmatch "TASK-P02-089[\s\S]+STAR-\[a-z0-9-\]") {
  throw 'negative: the P02-089 execplan/Catalog omissions must remain narrowly projected'
}
if ($RunnerText -notmatch 'function Get-P02LocalProjection' -or
    $RunnerText -notmatch 'function Get-P02GateModeState' -or
    $RunnerText -notmatch 'Write-P02LocalProjectionEvidence -ReadyForReview \$true') {
  throw 'negative: P02-990 must bind every local acceptance mode before Phase 3 entry'
}
if ($RunnerText -notmatch 'pending_independent_phase_02_approvals' -or
    $RunnerText -notmatch 'formal_same_configuration_drill_status' -or
    $RunnerText -notmatch "formal_acceptance_status='pending_external'") {
  throw 'negative: local Phase 2 completion must not fabricate formal approvals or production drill evidence'
}
if ($RunnerText -notmatch "\$Mode -ceq 'Verify'.*local-verification\.json" -and
    $RunnerText -notmatch 'LocalVerificationPath[\s\S]+Write-P02LocalProjectionEvidence') {
  throw 'negative: P02-990 Evidence must not hash summaries that are rewritten afterward'
}
exit 0

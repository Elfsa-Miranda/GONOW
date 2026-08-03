$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$CatalogPath = Join-Path $Root 'TaskGateCatalog.psd1'
try {
  $Catalog = Import-PowerShellDataFile -LiteralPath $CatalogPath -ErrorAction Stop
} catch {
  if ($PSVersionTable.PSVersion.Major -ne 5) { throw }
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
if (@($Catalog.TaskGateModeContracts.Keys).Count -ne 24 -or -not $Catalog.TaskGateModeContracts.ContainsKey('AutomatedAcceptancePreflight')) { throw 'positive: expected 24 task modes including automated acceptance' }
$P10009Task=$Catalog.Tasks['TASK-P10-009']
$P10009RequiredChange='freeze manifest → C1 correctness → C2 security/performance/cost → C3 quality → C4 recovery/virtual-time/4h-soak → C5 rollback/operations → aggregate hashes/residual risk'
if($null-eq$P10009Task-or@($P10009Task.allowed_taskgate_modes)-notcontains'AutomatedAcceptancePreflight'-or@($P10009Task.work_contract.required_changes).Count-ne1-or[string]$P10009Task.work_contract.required_changes[0]-cne$P10009RequiredChange-or@($P10009Task.file_allowlist).Count-ne4-or@($P10009Task.evidence_outputs|Where-Object{$_-cmatch'(?:personal-release-certification|rollback-operations-report)\.json$'}).Count-ne2){throw 'negative: P10-009 Catalog does not bind the personal C1-C5 task contract'}
$StatusSchemaPath=Join-Path (Split-Path -Parent $Root) 'schemas\task-status-v1.schema.json'
$StatusSchema=Get-Content -LiteralPath $StatusSchemaPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
if([string]$StatusSchema.properties.plan_version.pattern-cnotmatch'A-Za-z'-or$null-eq$StatusSchema.properties.governance_profile-or$null-eq$StatusSchema.properties.acceptance_method-or$null-eq$StatusSchema.properties.attestation_sha256){throw 'negative: task status schema does not distinguish personal automated attestation from human review'}
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
if ($RunnerText -notmatch 'function Set-AutomatedAcceptedStatus' -or
    $RunnerText -notmatch "AcceptanceMethod 'automated_attestation'" -or
    $RunnerText -notmatch 'reviewer_independent = \$false') {
  throw 'negative: personal automation must record attested acceptance without fabricating an independent reviewer'
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
if ($RunnerText -notmatch 'Get-P10003GateModeState' -or
    $RunnerText -notmatch 'p10_003_verify_failed' -or
    $RunnerText -notmatch 'every alert has owner/runbook/test' -or
    $RunnerText -notmatch 'unknown_pending_production_measurement' -or
    $RunnerText -notmatch 'p10_003_security_failed' -or
    $RunnerText -notmatch 'p10_003_rollback_verification_failed') {
  throw 'negative: P10-003 must keep SLOs hypothetical and bind every alert to owner, runbook, test, and rollback'
}
if ($RunnerText -notmatch 'Get-P10004GateModeState' -or
    $RunnerText -notmatch 'p10_004_verify_failed' -or
    $RunnerText -notmatch 'new_agent_runs_after_drill' -or
    $RunnerText -notmatch 'old_path_available' -or
    $RunnerText -notmatch 'ZHJpbGzlkI7mlrBBZ2VudCBydW5zPTDjgIFvbGQgcGF0aOWPr\+eUqA==' -or
    $RunnerText -notmatch 'harness_control_id=31' -or
    $RunnerText -notmatch 'injection_executed_action_count' -or
    $RunnerText -notmatch 'p10_004_security_failed' -or
    $RunnerText -notmatch 'p10_004_workset_failed' -or
    $RunnerText -notmatch 'p10_004_evidence_failed' -or
    $RunnerText -notmatch 'p10_004_rollback_verification_failed') {
  throw 'negative: P10-004 must own CAS/auth/propagation/drill/audit, Harness 31, security, evidence, workset, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P10005GateModeState' -or
    $RunnerText -notmatch 'Invoke-P10005DatasetValidation' -or
    $RunnerText -notmatch 'p10_005_verify_failed' -or
    $RunnerText -notmatch 'p04_e0_digest_unchanged' -or
    $RunnerText -notmatch 'overwritten_dataset_versions' -or
    $RunnerText -notmatch 'baseline_recent_holdout_separated' -or
    $RunnerText -notmatch 'canonical_digest_cross_platform_match' -or
    $RunnerText -notmatch 'dataset_git_tree_oid' -or
    $RunnerText -notmatch 'record_schema_error_count' -or
    $RunnerText -notmatch 'boundary_locale_count != 5' -or
    $RunnerText -notmatch 'boundary_journey_count != 5' -or
    $RunnerText -notmatch 'p10_005_security_failed' -or
    $RunnerText -notmatch 'p10_005_workset_failed' -or
    $RunnerText -notmatch 'p10_005_evidence_failed' -or
    $RunnerText -notmatch 'p10_005_rollback_verification_failed') {
  throw 'negative: P10-005 must own E0 immutability, versioned split, canonical digest, change control, security, evidence, workset, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P10006GateModeState' -or
    $RunnerText -notmatch 'p10_006_verify_failed' -or
    $RunnerText -notmatch 'raw_agreement' -or
    $RunnerText -notmatch 'cohen_kappa' -or
    $RunnerText -notmatch 'advisory_only' -or
    $RunnerText -notmatch 'rollout_decision_count' -or
    $RunnerText -notmatch 'harness_control_id=30' -or
    $RunnerText -notmatch 'p10_006_security_failed' -or
    $RunnerText -notmatch 'forbidden_reasoning_field_count' -or
    $RunnerText -notmatch 'p10_006_workset_failed' -or
    $RunnerText -notmatch 'p10_006_evidence_failed' -or
    $RunnerText -notmatch 'p10_006_rollback_verification_failed') {
  throw 'negative: P10-006 must own double-label calibration metrics, advisory fallback, Harness 30, security, evidence, workset, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P10007GateModeState' -or
    $RunnerText -notmatch 'p10_007_verify_failed' -or
    $RunnerText -notmatch 'allocation_sequence' -or
    $RunnerText -notmatch 'extend_current_gate' -or
    $RunnerText -notmatch 'skip_gate_allowed' -or
    $RunnerText -notmatch 'p10_007_security_failed' -or
    $RunnerText -notmatch 'unreviewed_user_eligible_count' -or
    $RunnerText -notmatch 'p10_007_workset_failed' -or
    $RunnerText -notmatch 'p10_007_evidence_failed' -or
    $RunnerText -notmatch 'p10_007_rollback_verification_failed') {
  throw 'negative: P10-007 must own sequential cohorts, sample extension, privacy, stop rules, evidence, workset, and allocation-zero rollback gates'
}
if ($RunnerText -notmatch 'Get-P10008GateModeState' -or
    $RunnerText -notmatch 'p10_008_verify_failed' -or
    $RunnerText -notmatch 'blocked_pending_production_measurement' -or
    $RunnerText -notmatch 'cost_per_adopted_success_usd' -or
    $RunnerText -notmatch 'route_reason_required' -or
    $RunnerText -notmatch 'p10_008_security_failed' -or
    $RunnerText -notmatch 'p10_008_workset_failed' -or
    $RunnerText -notmatch 'p10_008_evidence_failed' -or
    $RunnerText -notmatch 'p10_008_rollback_verification_failed') {
  throw 'negative: P10-008 must own cost join, honest null denominator, budget-or-blocked, security, evidence, workset, and economic-route rollback gates'
}
if ($RunnerText -notmatch 'Get-P10009GateModeState' -or
    $RunnerText -notmatch 'Get-PersonalReleaseCertificationState' -or
    $RunnerText -notmatch 'p10_009_personal_certification_failed' -or
    $RunnerText -notmatch 'p10_009_automated_acceptance_preflight_failed' -or
    $RunnerText -notmatch 'personal_compressed_release_certification' -or
    $RunnerText -notmatch 'production_observation_required = \$false' -or
    $RunnerText -notmatch 'p10_009_security_failed' -or
    $RunnerText -notmatch 'p10_009_workset_failed' -or
    $RunnerText -notmatch 'p10_009_evidence_failed' -or
    $RunnerText -notmatch 'p10_009_rollback_verification_failed') {
  throw 'negative: P10-009 must bind personal C1-C5 certification, exact attestation, security, evidence, workset, and old-route rollback gates'
}
$RolloutContractPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path 'docs/execution/evidence/phase-10/P10-007/rollout-cohorts.yaml'
$RolloutContractText = (Get-Content -LiteralPath $RolloutContractPath -Raw -Encoding UTF8).Replace("`r`n","`n")
if ($RunnerText -notmatch 'Get-P10ObservationWindowState' -or
    $RunnerText -notmatch 'minimum_nonoverlap_observation_hours=744' -or
    $RunnerText -notmatch 'window_started_at' -or
    $RunnerText -notmatch 'window_ended_at' -or
    $RunnerText -notmatch 'nonoverlap_failure_count' -or
    $RunnerText -notmatch 'duration_binding_failure_count' -or
    $RunnerText -notmatch 'minimum_total_observation_failure_count' -or
    $RunnerText -notmatch 'rollout_artifact_hash_mismatch' -or
    $RunnerText -notmatch 'observation_31_day_contract_valid' -or
    $RolloutContractText -notmatch '(?m)^  minimum_nonoverlap_observation_hours: 744$' -or
    $RolloutContractText -notmatch '(?m)^  window_started_at_field: window_started_at$' -or
    $RolloutContractText -notmatch '(?m)^  window_ended_at_field: window_ended_at$' -or
    $RolloutContractText -notmatch '(?m)^  stop_rules_remain_active_during_extension: true$' -or
    $RunnerText -notmatch 'total_nonoverlap_hours_below_744') {
  throw 'negative: inactive enterprise Release B profile must retain explicit non-overlapping timestamps and at least 744 total observed hours'
}
$RunnerPath=Join-Path $Root 'Invoke-TaskGate.ps1';$ParserTokens=$null;$ParserErrors=$null;$RunnerAst=[Management.Automation.Language.Parser]::ParseFile($RunnerPath,[ref]$ParserTokens,[ref]$ParserErrors)
$ObservationFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P10ObservationWindowState'},$true)
if($ParserErrors.Count-ne0-or$null-eq$ObservationFunction){throw 'negative: P10 observation-window validator AST is unavailable'}
Invoke-Expression $ObservationFunction.Extent.Text
$ObservationPlan=[pscustomobject]@{minimum_nonoverlap_observation_hours=744;windows_must_be_nonoverlapping=$true;window_started_at_field='window_started_at';window_ended_at_field='window_ended_at';duration_field='observed_hours';duration_tolerance_hours=0.01;insufficient_total_observation_action='extend_current_gate';stop_rules_remain_active_during_extension=$true;minimum_adopted_runs=@(50,100,250,500,1000);minimum_observation_hours=@(24,48,72,120,168)}
$GatePercents=@(1,5,20,50,100);$GateSamples=@(50,100,250,500,1000);$GateRequiredHours=@(24,48,72,120,168);$GateObservedHours=@(24,48,72,120,480);$GateStart=[DateTimeOffset]::Parse('2026-01-01T00:00:00Z');$ObservationGates=@()
for($GateIndex=0;$GateIndex-lt5;$GateIndex++){$GateEnd=$GateStart.AddHours($GateObservedHours[$GateIndex]);$ObservationGates+=[pscustomobject]@{percent=$GatePercents[$GateIndex];required_adopted_runs=$GateSamples[$GateIndex];observed_adopted_runs=$GateSamples[$GateIndex];required_hours=$GateRequiredHours[$GateIndex];observed_hours=$GateObservedHours[$GateIndex];window_started_at=$GateStart.ToString('o');window_ended_at=$GateEnd.ToString('o');satisfied=$true;all_risk_slices_observed=$true;timer_restarted_on_transition=$true};$GateStart=$GateEnd}
$PositiveObservation=[pscustomobject]@{gates=$ObservationGates};$PositiveWindowState=Get-P10ObservationWindowState -Observation $PositiveObservation -Plan $ObservationPlan
if(-not[bool]$PositiveWindowState.passed-or[double]$PositiveWindowState.observed_nonoverlap_hours-ne744){throw 'positive: exact 744-hour non-overlapping Release B observation was rejected'}
$OverlapGates=@($ObservationGates|ForEach-Object{$_.PSObject.Copy()});$OverlapGates[4].window_started_at=([DateTimeOffset]::Parse([string]$OverlapGates[3].window_ended_at)).AddHours(-1).ToString('o');$OverlapGates[4].window_ended_at=([DateTimeOffset]::Parse([string]$OverlapGates[4].window_started_at)).AddHours(480).ToString('o');$OverlapState=Get-P10ObservationWindowState -Observation ([pscustomobject]@{gates=$OverlapGates}) -Plan $ObservationPlan
if([bool]$OverlapState.passed-or[int]$OverlapState.checks.nonoverlap_failure_count-ne1){throw 'negative: overlapping Release B observation window was accepted'}
$ShortGates=@($ObservationGates|ForEach-Object{$_.PSObject.Copy()});$ShortGates[4].observed_hours=479;$ShortGates[4].window_ended_at=([DateTimeOffset]::Parse([string]$ShortGates[4].window_started_at)).AddHours(479).ToString('o');$ShortState=Get-P10ObservationWindowState -Observation ([pscustomobject]@{gates=$ShortGates}) -Plan $ObservationPlan
if([bool]$ShortState.passed-or[int]$ShortState.checks.minimum_total_observation_failure_count-ne1){throw 'negative: 743-hour Release B observation was accepted'}
if ($RunnerText -notmatch 'Get-P10010GateModeState' -or
    $RunnerText -notmatch 'critical_slices' -or
    $RunnerText -notmatch 'sample_sufficiency' -or
    $RunnerText -notmatch 'required_owner_approval_missing' -or
    $RunnerText -notmatch 'p10_009\.artifact_sha256' -or
    $RunnerText -notmatch 'p10_010_security_failed' -or
    $RunnerText -notmatch 'p10_010_workset_failed' -or
    $RunnerText -notmatch 'p10_010_evidence_failed' -or
    $RunnerText -notmatch 'p10_010_rollback_verification_failed') {
  throw 'negative: P10-010 must own six-slice threshold, accepted P10-009 binding, approvals, P0/P1, rollback, security, evidence, and workset gates'
}
if ($RunnerText -notmatch 'Get-P10089GateModeState' -or
    $RunnerText -notmatch 'TASK-P10-089:HarnessCatalogAggregate' -or
    $RunnerText -notmatch "extended_control_ids=@\(29,30,31\)" -or
    $RunnerText -notmatch 'hardest_item_count' -or
    $RunnerText -notmatch 'not_applicable' -or
    $RunnerText -notmatch 'p10_089_security_failed' -or
    $RunnerText -notmatch 'p10_089_workset_failed' -or
    $RunnerText -notmatch 'p10_089_evidence_failed' -or
    $RunnerText -notmatch 'p10_089_rollback_verification_failed') {
  throw 'negative: P10-089 must own STAR, documentation, handoff, Harness 29/30/31 CAS, status board, security, evidence, and rollback gates'
}
if ($RunnerText -notmatch 'Get-P10LocalProjection' -or
    $RunnerText -notmatch 'Get-P10GateModeState' -or
    $RunnerText -notmatch 'Write-P10LocalProjectionEvidence' -or
    $RunnerText -notmatch 'first_phase_le_p10_unimplemented_count' -or
    $RunnerText -notmatch 'accepted_rollout_and_release_gate' -or
    $RunnerText -notmatch 'cost_failure_count' -or
    $RunnerText -notmatch 'p10_990_security_failed' -or
    $RunnerText -notmatch 'p10_990_evidence_failed' -or
    $RunnerText -notmatch 'p10_990_acceptance_preflight_failed' -or
    $RunnerText -notmatch 'p10_990_regression_failed' -or
    $RunnerText -notmatch 'p10_990_rollback_drill_failed' -or
    $RunnerText -notmatch 'pending_phase_10_independent_approvals') {
  throw 'negative: P10-990 must bind accepted rollout/release gates, E0/E1/CT/cost evidence, full regression, rollback, approvals, and all eight rejection categories'
}
if ($RunnerText -notmatch 'if \(\$TaskIdValue -ceq ''TASK-P10-011''\)' -or
    $RunnerText -notmatch 'Get-P10011GateModeState' -or
    $RunnerText -notmatch "required_checks=@\('agent-required','baseline-and-candidate','tracked-and-history'\)" -or
    $RunnerText -notmatch 'pr-request\.json' -or
    $RunnerText -notmatch 'pr-observation\.json' -or
    $RunnerText -notmatch 'Get-P10011LivePullRequestState' -or
    $RunnerText -notmatch 'Invoke-RestMethod -Method Get' -or
    $RunnerText -notmatch 'X-GitHub-Api-Version' -or
    $RunnerText -notmatch 'live_query_failure_count' -or
    $RunnerText -notmatch 'task_card_binding=\$CardBinding' -or
    $RunnerText -notmatch "required_changes=@\('verify clean','head SHA','open PR','attach gates','await user'\)" -or
    $RunnerText -notmatch 'remote_head_oid' -or
    $RunnerText -notmatch 'main_ref_write_count' -or
    $RunnerText -notmatch 'close_pull_request_without_deleting_branch' -or
    $RunnerText -notmatch 'p10_011_preflight_failed' -or
    $RunnerText -notmatch 'p10_011_work_preflight_failed' -or
    $RunnerText -notmatch 'p10_011_workset_failed' -or
    $RunnerText -notmatch 'p10_011_verify_failed' -or
    $RunnerText -notmatch 'p10_011_security_failed' -or
    $RunnerText -notmatch 'p10_011_evidence_failed' -or
    $RunnerText -notmatch 'p10_011_rollback_verification_failed') {
  throw 'negative: P10-011 must use release evidence routing and bind the accepted integration SHA, exact PR refs/checks, auto-merge off, audit receipt, no ref writes, evidence, and reversible close-only rollback'
}
$ReleaseRouteIndex=$RunnerText.IndexOf("if (`$TaskIdValue -ceq 'TASK-P10-011')",[StringComparison]::Ordinal)
$GenericPhaseRouteIndex=$RunnerText.IndexOf("if (`$TaskIdValue -cmatch '^TASK-P",[StringComparison]::Ordinal)
if($ReleaseRouteIndex-lt0-or$GenericPhaseRouteIndex-lt0-or$ReleaseRouteIndex-gt$GenericPhaseRouteIndex){throw 'negative: P10-011 release evidence route must precede the generic Phase task route'}
foreach($P10011Mode in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','RollbackVerify')){
  $HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$P10011Mode)},$true)
  if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch 'if \(\$TaskId -ceq ''TASK-P10-011''\) \{'){throw "negative: P10-011 specialization is missing in Invoke-Mode$P10011Mode"}
}
$RelC000RequiredChange=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5qC46aqMIFJlbGVhc2UgQiDmjqXlj5cgU0hB44CB56iz5a6a56qX5Y+j5ZKM5om55YeG5pyJ5pWI5pyfIOKGkiDmr5TovoMgUDEx44CBUDEyIOS4juS4jeaJqeWxle+8jOS/neeVmeWIhuavjeOAgee9ruS/oeW6puWSjOmjjumZqSDihpIg5LuOIGFjY2VwdGVkIGxhbmRpbmcgU0hBIOWIm+W7uiBjbGVhbiBnb3Zlcm5hbmNlIGJyYW5jaC93b3JrdHJlZSDihpIg5YaZ5ZSv5LiAIGBjeWNsZV9pZGDjgIFgcGF0aGDjgIFvd25lciDnrb7lkI3lkozor4Hmja7lk4jluIwg4oaSIOS7pSBleHBlY3RlZC1TSEEgQ0FTIOabtOaWsCBnb3Zlcm5hbmNlIHJlZu+8m+ernuS6ieWksei0peWNs+WBnOatoiDihpIg6K+B5piOIFAxMSDkuI7lhajpg6ggUDEyeCDkuJPpobnliIbmlK/lnYfkuI3lrZjlnKg='))
$RelC000Task=$Catalog.Tasks['TASK-REL-C-000']
if($null-eq$RelC000Task-or@($RelC000Task.work_contract.required_changes).Count-ne1-or[string]$RelC000Task.work_contract.required_changes[0]-cne$RelC000RequiredChange){throw 'negative: REL-C-000 Catalog must preserve the task-card required change verbatim'}
if($RunnerText -notmatch 'if \(\$TaskIdValue -ceq ''TASK-REL-C-000''\)' -or
    $RunnerText -notmatch 'Get-RelC000GateModeState' -or
    $RunnerText -notmatch 'Get-RelC000DependencyState' -or
    $RunnerText -notmatch 'Get-RelC000SelectionState' -or
    $RunnerText -notmatch 'Get-RelC000BranchState' -or
    $RunnerText -notmatch "@\('phase11','phase12','none'\)" -or
    $RunnerText -notmatch '\$PathCount-eq1' -or
    $RunnerText -notmatch 'refs/heads/codex/release-c-governance' -or
    $RunnerText -notmatch 'expected_sha' -or
    $RunnerText -notmatch 'actual_sha' -or
    $RunnerText -notmatch 'new_sha' -or
    $RunnerText -notmatch 'minimum_nonoverlap_observation_hours=744' -or
    $RunnerText -notmatch "required_roles=@\('Data','Engineering','Product','Security'\)" -or
    $RunnerText -notmatch "required_owner_roles=@\('Architecture','Product'\)" -or
    $RunnerText -notmatch 'denominator' -or
    $RunnerText -notmatch 'confidence' -or
    $RunnerText -notmatch 'risk' -or
    $RunnerText -notmatch 'evidence_sha256' -or
    $RunnerText -notmatch 'specialist_branch_count' -or
    $RunnerText -notmatch 'cycle_rewrite_count' -or
    $RunnerText -notmatch 'rel_c_000_preflight_failed' -or
    $RunnerText -notmatch 'rel_c_000_work_preflight_failed' -or
    $RunnerText -notmatch 'rel_c_000_workset_failed' -or
    $RunnerText -notmatch 'rel_c_000_verify_failed' -or
    $RunnerText -notmatch 'rel_c_000_security_failed' -or
    $RunnerText -notmatch 'rel_c_000_evidence_failed' -or
    $RunnerText -notmatch 'rel_c_000_rollback_verification_failed'){
  throw 'negative: REL-C-000 must enforce Release B acceptance/stability, phase11|phase12|none XOR, immutable evidence, owner/reviewer validity, branch absence, and expected-SHA CAS'
}
$RelC000RouteIndex=$RunnerText.IndexOf("if (`$TaskIdValue -ceq 'TASK-REL-C-000')",[StringComparison]::Ordinal)
if($RelC000RouteIndex-lt0-or$GenericPhaseRouteIndex-lt0-or$RelC000RouteIndex-gt$GenericPhaseRouteIndex){throw 'negative: REL-C-000 releases evidence route must precede the generic Phase/release route'}
foreach($RelC000Mode in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','RollbackVerify')){
  $HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$RelC000Mode)},$true)
  if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch 'if \(\$TaskId -ceq ''TASK-REL-C-000''\) \{'){throw "negative: REL-C-000 specialization is missing in Invoke-Mode$RelC000Mode"}
}
$RelC000SelectionFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-RelC000SelectionState'},$true)
if($null-eq$RelC000SelectionFunction){throw 'negative: REL-C-000 selection validator AST is unavailable'}
Invoke-Expression $RelC000SelectionFunction.Extent.Text
$RelC000Sha='1'*40;$RelC000EvidenceSha='2'*64;$RelC000Cycle=[Guid]::NewGuid().ToString()
$RelC000Approvals=@('Data','Engineering','Product','Security'|ForEach-Object{[pscustomobject]@{role=$_;actor_id=("reviewer-"+$_.ToLowerInvariant());decision='approved';candidate_sha=$RelC000Sha;cycle_id=$RelC000Cycle;path='phase12';evidence_sha256=$RelC000EvidenceSha;expires_at='2099-01-01T00:00:00Z'}})
$RelC000Selection=[pscustomobject]@{schema_version='1.0';task_id='TASK-REL-C-000';cycle_id=$RelC000Cycle;path='phase12';accepted_landing_sha=$RelC000Sha;evidence_sha256=$RelC000EvidenceSha;alternatives=@(
  [pscustomobject]@{path='phase11';selected=$false;denominator=100;confidence=[pscustomobject]@{level=0.95;lower=0.1;upper=0.2};risks=@('retrieval-quality');evidence_sha256=$RelC000EvidenceSha},
  [pscustomobject]@{path='phase12';selected=$true;denominator=100;confidence=[pscustomobject]@{level=0.95;lower=0.2;upper=0.4};risks=@('coordination-cost');evidence_sha256=$RelC000EvidenceSha},
  [pscustomobject]@{path='none';selected=$false;denominator=100;confidence=[pscustomobject]@{level=0.95;lower=0.0;upper=0.1};risks=@('opportunity-cost');evidence_sha256=$RelC000EvidenceSha}
);owner_signatures=@([pscustomobject]@{role='Architecture';actor_id='owner-architecture';decision='approved';cycle_id=$RelC000Cycle;path='phase12';evidence_sha256=$RelC000EvidenceSha},[pscustomobject]@{role='Product';actor_id='owner-product';decision='approved';cycle_id=$RelC000Cycle;path='phase12';evidence_sha256=$RelC000EvidenceSha});approvals=$RelC000Approvals;cas_receipt=[pscustomobject]@{ref='refs/heads/codex/release-c-governance';expected_sha=$RelC000Sha;actual_sha=$RelC000Sha;new_sha=('3'*40);result='updated';conflict_count=0};cycle_rewrite_count=0}
$RelC000Dependency=[pscustomobject]@{passed=$true;accepted_landing_sha=$RelC000Sha;evidence_sha256=$RelC000EvidenceSha}
$RelC000Branches=[pscustomobject]@{query_failure_count=0;specialist_branch_count=0;governance_ref_oid=('3'*40);current_head_oid=('3'*40);current_branch='codex/release-c-governance'}
$RelC000Positive=Get-RelC000SelectionState -Selection $RelC000Selection -Dependency $RelC000Dependency -BranchState $RelC000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))
if(-not[bool]$RelC000Positive.passed-or[int]$RelC000Positive.checks.path_count-ne1){throw 'positive: a fully bound REL-C-000 XOR/CAS selection was rejected'}
$RelC000Overlap=$RelC000Selection.PSObject.Copy();$RelC000Overlap.alternatives=@($RelC000Selection.alternatives|ForEach-Object{$_.PSObject.Copy()});$RelC000Overlap.alternatives[0].selected=$true
if([bool](Get-RelC000SelectionState -Selection $RelC000Overlap -Dependency $RelC000Dependency -BranchState $RelC000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: REL-C-000 accepted two selected sibling paths'}
$RelC000CasConflict=$RelC000Selection.PSObject.Copy();$RelC000CasConflict.cas_receipt=$RelC000Selection.cas_receipt.PSObject.Copy();$RelC000CasConflict.cas_receipt.actual_sha='4'*40;$RelC000CasConflict.cas_receipt.conflict_count=1
if([bool](Get-RelC000SelectionState -Selection $RelC000CasConflict -Dependency $RelC000Dependency -BranchState $RelC000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: REL-C-000 accepted a competing expected-SHA CAS result'}
$RelC000NoDenominator=$RelC000Selection.PSObject.Copy();$RelC000NoDenominator.alternatives=@($RelC000Selection.alternatives|ForEach-Object{$_.PSObject.Copy()});$RelC000NoDenominator.alternatives[0].denominator=0
if([bool](Get-RelC000SelectionState -Selection $RelC000NoDenominator -Dependency $RelC000Dependency -BranchState $RelC000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: REL-C-000 accepted an alternative without a positive denominator'}
$RelC000Expired=$RelC000Selection.PSObject.Copy();$RelC000Expired.approvals=@($RelC000Selection.approvals|ForEach-Object{$_.PSObject.Copy()});$RelC000Expired.approvals[0].expires_at='2026-01-01T00:00:00Z'
if([bool](Get-RelC000SelectionState -Selection $RelC000Expired -Dependency $RelC000Dependency -BranchState $RelC000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: REL-C-000 accepted an expired independent approval'}
$RelC000ExistingSpecialist=$RelC000Branches.PSObject.Copy();$RelC000ExistingSpecialist.specialist_branch_count=1
if([bool](Get-RelC000SelectionState -Selection $RelC000Selection -Dependency $RelC000Dependency -BranchState $RelC000ExistingSpecialist -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: REL-C-000 accepted an existing Phase 11/12 specialist branch'}
$RelC001Task=$Catalog.Tasks['TASK-REL-C-001']
$RelC001RequiredChange=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('6YeN6K+7IG91dGVyIHBhdGggcmVjZWlwdO+8m+iLpSBwYXRoPWBub25lYCDliJnkv53mjIEgYG5vdF9zdGFydGVkYCDihpIg6Iul6LWwIFAxMu+8jOmHjeivuyBpbm5lciBzZWxlY3Rpb24gcmVjZWlwdCDlubbor4HmmI7kuI3mmK8gYG5vbmVgIOKGkiDor4HmmI4gYWN0aXZlIEMgY2FwYWJpbGl0eT0x77yM5qC46aqM5LiT6aG5IGdhdGUvcm9sbGJhY2sg4oaSIOWIm+W7uiBsYW5kaW5n4oaSbWFpbiBQUiDihpIg6K6w5b2VIFVSTC9TSEEg5ZCO562J5b6F5Lq65bel5Yaz5a6a'))
$RelC001RequiredInputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','refs/heads/codex/gonow-agent-landing','refs/remotes/origin/codex/gonow-agent-landing','refs/remotes/origin/main','refs/heads/codex/release-c-governance','docs/execution/evidence/releases/B.json','docs/execution/evidence/releases/REL-C-000/path-selection.json','docs/execution/evidence/releases/REL-C-000/rag-trigger-evidence.json','docs/execution/evidence/releases/REL-C-000/phase12-trigger-evidence.json','docs/execution/evidence/releases/REL-C-000/gate-results.json','docs/execution/evidence/releases/REL-C-000/artifact-hashes.json','docs/execution/status/TASK-REL-C-000.json','docs/execution/status/TASK-P11-999.json','docs/execution/evidence/phase-11/merge.json','docs/execution/evidence/phase-11/phase-close-v01.json','docs/execution/evidence/phase-11/artifact-manifest-v01.json','docs/execution/evidence/phase-11/P11-999/gate-results.json','docs/execution/evidence/phase-11/P11-990/rollback-drill.json','docs/execution/evidence/phase-12/P12-002/selection.json','docs/execution/status/TASK-P12-089.json','docs/execution/evidence/phase-12/P12-089/implementation-close-registration.json')
$RelC001RequiredOutputs=@('docs/execution/evidence/releases/C.json','docs/execution/evidence/releases/REL-C-001/pr-request.json','docs/execution/evidence/releases/REL-C-001/pr-observation.json','docs/execution/evidence/releases/REL-C-001/security-report.json','docs/execution/evidence/releases/REL-C-001/rollback-report.json','docs/execution/evidence/releases/REL-C-001/artifact-hashes.json','docs/execution/evidence/releases/REL-C-001/commands.json','docs/execution/evidence/releases/REL-C-001/gate-results.json','docs/execution/status/TASK-REL-C-001.json')
$RelC001Action=@($RelC001Task.work_contract.external_actions)
if($null-eq$RelC001Task-or(@($RelC001Task.prerequisite_task_ids)-join',')-cne'TASK-REL-C-000'-or@($RelC001Task.applicable_ct_ids).Count-ne0-or(@($RelC001Task.security_check_ids|Sort-Object)-join',')-cne'SEC-AUDIT,SEC-PII,SEC-RESTORE,SEC-SECRET,SEC-SQL'-or(@($RelC001Task.file_allowlist)-join',')-cne'docs/execution/evidence/releases/C.json'-or@($RelC001Task.directory_allowlist).Count-ne1-or[string]$RelC001Task.directory_allowlist[0].path-cne'docs/execution/evidence/releases/REL-C-001/'-or(@($RelC001Task.read_only_inputs|Sort-Object)-join',')-cne(($RelC001RequiredInputs|Sort-Object)-join',')-or(@($RelC001Task.evidence_outputs|Sort-Object)-join',')-cne(($RelC001RequiredOutputs|Sort-Object)-join',')-or@($RelC001Task.work_contract.required_changes).Count-ne1-or[string]$RelC001Task.work_contract.required_changes[0]-cne$RelC001RequiredChange-or$RelC001Action.Count-ne1-or[string]$RelC001Action[0].adapter_capability-cne'github_authorized_external_action'-or[string]$RelC001Action[0].target-cne'Elfsa-Miranda/GO_NOW:pull-request'-or[string]$RelC001Action[0].idempotency_or_cas-cne'head_oid+base_oid+outer_path_receipt_sha256+selected_merge_sha'-or[string]$RelC001Action[0].receipt-cne'docs/execution/evidence/releases/REL-C-001/pr-observation.json'-or[string]$RelC001Action[0].rollback-cne'close_unmerged_pull_request_without_deleting_branch_or_writing_refs'){throw 'negative: REL-C-001 Catalog must bind the dynamic XOR dependency, no-CT publication contract, exact evidence surface, and one metadata-only GitHub adapter'}
foreach($RelC001Mode in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','RollbackVerify')){$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$RelC001Mode)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch 'if \(\$TaskId -ceq ''TASK-REL-C-001''\) \{'){throw "negative: REL-C-001 specialization is missing in Invoke-Mode$RelC001Mode"}}
foreach($FunctionName in @('Get-RelC001OuterState','Get-RelC001SelectedCapabilityState','Get-RelC001DependencyState','Get-RelC001ObservationState','Get-RelC001LivePullRequestState')){$FunctionAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq$FunctionName},$true);if($null-eq$FunctionAst){throw "negative: REL-C-001 helper is missing: $FunctionName"}}
$RelC001OuterAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-RelC001OuterState'},$true);$RelC001CapabilityAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-RelC001SelectedCapabilityState'},$true);$RelC001ObservationAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-RelC001ObservationState'},$true);$RelC001LiveAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-RelC001LivePullRequestState'},$true);$RelC001VerifyAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Invoke-ModeVerify'},$true)
if($RelC001OuterAst.Extent.Text-cnotmatch"Path-ceq'phase11'"-or$RelC001OuterAst.Extent.Text-cnotmatch"Path-ceq'phase12'"-or$RelC001OuterAst.Extent.Text-cnotmatch'rel_c_001_outer_path_none'-or$RelC001OuterAst.Extent.Text-cnotmatch'Artifact.*TriggerPath'-or$RelC001CapabilityAst.Extent.Text-cnotmatch'rev-list --merges'-or$RelC001CapabilityAst.Extent.Text-cnotmatch'implementation-close-registration\.json'-or$RelC001CapabilityAst.Extent.Text-cnotmatch'approved_plan_sha256'-or$RelC001CapabilityAst.Extent.Text-cnotmatch'selected_branch_ref'-or$RelC001CapabilityAst.Extent.Text-cnotmatch'P12Approvals'-or$RelC001CapabilityAst.Extent.Text-cnotmatch'unselected_path_commit_count'-or$RelC001CapabilityAst.Extent.Text-cnotmatch'rollback-drill\.json'-or$RelC001ObservationAst.Extent.Text-cnotmatch'Abs\(\[int\]\$Checks\.active_c_capability_count-1\)'){throw 'negative: REL-C-001 must prove outer XOR, optional inner approval, one accepted merge, zero unselected commits/refs, and selected rollback without count cancellation'}
if($RelC001LiveAst.Extent.Text-cmatch'(?i)-Method\s+(?:Post|Patch|Put|Delete)'-or$RelC001LiveAst.Extent.Text-cnotmatch'-Method Get'-or$RelC001VerifyAst.Extent.Text-cnotmatch'accepted=\$false'-or$RelC001VerifyAst.Extent.Text-cnotmatch'auto_merge=\$false'){throw 'negative: REL-C-001 verifier must use read-only live queries and keep Release C unaccepted with auto-merge disabled'}
$RelC001FormalGuardIndex=$RunnerText.IndexOf("if(`$TaskId-ceq'TASK-REL-C-001'-and`$ExecutionMode-cne'formal_adopted')",[StringComparison]::Ordinal);$RelC001StartGuardIndex=$RunnerText.IndexOf("if(`$TaskId-ceq'TASK-REL-C-001'){`$StartState=Get-RelC001OuterState",[StringComparison]::Ordinal)
$ConditionalRegistryFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-ConditionalTaskRunnerRegistryState'},$true)
if($null-eq$ConditionalRegistryFunction-or$RunnerText-cnotmatch 'conditional_task_runner_unimplemented'){throw 'negative: conditional Release C tasks must fail closed before a specialized runner is registered'}
Invoke-Expression $ConditionalRegistryFunction.Extent.Text
$ConditionalTaskIds=@($Catalog.Tasks.Keys|Where-Object{$_-cmatch'^TASK-(?:P11|P12(?:[A-D])?|REL-C-)'}|Sort-Object)
if($ConditionalTaskIds.Count-ne24){throw "positive: expected 24 conditional Release C task cards, observed $($ConditionalTaskIds.Count)"}
$RegisteredConditionalTasks=@($ConditionalTaskIds|Where-Object{$Id=$_;$Declared=@($Catalog.Tasks[$Id].allowed_taskgate_modes);$Declared.Count-gt0-and@($Declared|Where-Object{-not[bool](Get-ConditionalTaskRunnerRegistryState -TaskIdValue $Id -ModeValue $_).registered}).Count-eq0})
$ExpectedRegisteredConditionalTasks=@('TASK-P11-000','TASK-P11-001','TASK-P11-002','TASK-P11-003','TASK-P11-004','TASK-P11-005','TASK-P11-006','TASK-P11-007','TASK-P11-008','TASK-P11-009','TASK-P11-010','TASK-P11-089','TASK-P11-990','TASK-P11-999','TASK-P12-000','TASK-P12-001','TASK-P12-002','TASK-P12-089','TASK-P12A-000','TASK-P12B-000','TASK-P12C-000','TASK-P12D-000','TASK-REL-C-000','TASK-REL-C-001')
if(($RegisteredConditionalTasks-join',')-cne($ExpectedRegisteredConditionalTasks-join',')){throw 'negative: conditional runner registry differs from the twenty-four specialized governance, P11 atomic/convergence/acceptance/merge, P12 convergence/work-package, and Release C publication tasks'}
$UnimplementedConditionalTasks=@($ConditionalTaskIds|Where-Object{$Id=$_;$Declared=@($Catalog.Tasks[$Id].allowed_taskgate_modes);$Declared.Count-eq0-or@($Declared|Where-Object{-not[bool](Get-ConditionalTaskRunnerRegistryState -TaskIdValue $Id -ModeValue $_).registered}).Count-gt0})
if($UnimplementedConditionalTasks.Count-ne0){throw 'negative: at least one conditional Release C task remains without a specialized fail-closed runner'}
$NonConditionalState=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P10-011' -ModeValue 'Preflight'
if([bool]$NonConditionalState.required-or-not[bool]$NonConditionalState.registered){throw 'negative: the conditional runner guard shadowed an already implemented non-conditional task'}
$ConditionalGuardIndex=$RunnerText.IndexOf('$ConditionalRunnerState=Get-ConditionalTaskRunnerRegistryState',[StringComparison]::Ordinal)
$EvidenceDirectoryIndex=$RunnerText.LastIndexOf('$TaskEvidenceDirectory = Get-TaskEvidenceDirectory',[StringComparison]::Ordinal)
if($ConditionalGuardIndex-lt0-or$EvidenceDirectoryIndex-lt0-or$ConditionalGuardIndex-gt$EvidenceDirectoryIndex){throw 'negative: the conditional runner guard must reject before evidence/status directories are materialized'}
if($RelC001FormalGuardIndex-lt0-or$RelC001StartGuardIndex-lt0-or$RelC001FormalGuardIndex-gt$EvidenceDirectoryIndex-or$RelC001StartGuardIndex-gt$EvidenceDirectoryIndex){throw 'negative: REL-C-001 formal/outer-selection guards must reject before evidence or status materialization'}
$P11AtomicModeGuardIndex=$RunnerText.IndexOf("if(((Test-P11AtomicTask -TaskIdValue `$TaskId)-or`$TaskId-ceq'TASK-P11-089')-and`$ExecutionMode-notin@('formal_adopted','local_provisional'))",[StringComparison]::Ordinal)
$P11MergeFormalGuardIndex=$RunnerText.IndexOf("if(`$TaskId-ceq'TASK-P11-999'-and`$ExecutionMode-cne'formal_adopted')",[StringComparison]::Ordinal)
if($P11AtomicModeGuardIndex-lt0-or$P11MergeFormalGuardIndex-lt0-or$P11AtomicModeGuardIndex-gt$EvidenceDirectoryIndex-or$P11MergeFormalGuardIndex-gt$EvidenceDirectoryIndex){throw 'negative: P11 implementation and local acceptance candidate must allow formal/local modes while merge remains formal before evidence/status materialization'}
$P11000RequiredChange=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('6aqM6K+BIFJlbGVhc2UgQyBwYXRoPWBwaGFzZTExYOOAgeetvuWQjeOAgWN5Y2xlX2lkIOS4jiBDQVMgcmVjZWlwdCDihpIg54us56uL5aSN5qC4ID4yMCUg5YGH6K6+44CB5YiG5q+NL+eql+WPoy/or6/lt67lj4rorrjlj68v6ZqQ56eBL+WMuuWfny/liKDpmaTor4Hmja4gaGFzaCDihpIg5LuOIGFjY2VwdGVkIFNIQSDliJvlu7ogY2xlYW4gYnJhbmNoL3dvcmt0cmVlIOKGkiDlr7zlhaXlvJXnlKgvaGFzaOW5tuiusOW9lSBwaGFzZV9iYXNlX3NoYSDihpIg6K+B5piOIFBoYXNlIDEyIOS4juWFqOmDqOS4k+mhueWIhuaUr+S4jeWtmOWcqA=='))
$P11000DetailBase64='5ZCI5qC86KeE5YiS5aSx6LSl5Lit56iz5a6a55+l6K+G57y65Y+j5Y2g5q+UID4yMCXvvIjpmIjlgLzlt7LmoKHlh4bvvInvvIxSZWxlYXNlIELnqLPlrprjgIHlkIzmnJ/ml6Dlhbbku5ZD6IO95Yqb44CBQURS562+572y44CC'
$P11000Detail=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($P11000DetailBase64))
$P11000Task=$Catalog.Tasks['TASK-P11-000']
$P11000Inputs=@(
  'docs/execution/evidence/releases/REL-C-000/path-selection.json',
  'docs/execution/evidence/releases/REL-C-000/rag-trigger-evidence.json',
  'docs/execution/status/TASK-REL-C-000.json',
  'docs/execution/evidence/releases/B.json'
)
if($null-eq$P11000Task-or@($P11000Task.work_contract.required_changes).Count-ne1-or[string]$P11000Task.work_contract.required_changes[0]-cne$P11000RequiredChange-or
   @($P11000Inputs|Where-Object{$_-notin@($P11000Task.read_only_inputs)}).Count-ne0){throw 'negative: P11-000 Catalog does not bind its exact required change and immutable Release C/Release B inputs'}
foreach($P11000Mode in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','RollbackVerify')){
  $HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$P11000Mode)},$true)
  if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch 'if \(\$TaskId -ceq ''TASK-P11-000''\) \{'){throw "negative: P11-000 specialization is missing in Invoke-Mode$P11000Mode"}
}
if($RunnerText -notmatch 'Get-P11000TriggerState' -or$RunnerText -notmatch 'Get-P11000DependencyState' -or
   $RunnerText -notmatch 'Get-P11000BranchState' -or$RunnerText -notmatch 'Get-P11000GateModeState' -or
   -not$RunnerText.Contains($P11000DetailBase64) -or$RunnerText -notmatch 'minimum_unit_tests=542' -or
   $RunnerText -notmatch 'minimum_contract_tests=144' -or$RunnerText -notmatch 'minimum_flutter_tests=82' -or
   $RunnerText -notmatch '\[IO\.Path\]::GetFullPath\(\$Top\)' -or$RunnerText -notmatch '\$Head-ceq\$ExpectedBaseOid' -or
   $RunnerText -notmatch 'phase11_alternative_evidence_hash_match'){
  throw 'negative: P11-000 must own the trigger, immutable dependency, branch isolation, exact detail, and full historical entry regression contracts'
}
$P11000BranchFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11000BranchState'},$true)
if($null-eq$P11000BranchFunction-or$P11000BranchFunction.Extent.Text-cnotmatch "phase-12" -or
   $P11000BranchFunction.Extent.Text-cnotmatch 'forbidden_specialist_branch_count'){
  throw 'negative: P11-000 branch isolation does not reject every Phase 12 specialist ref'
}
$P11000TriggerFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11000TriggerState'},$true)
if($null-eq$P11000TriggerFunction){throw 'negative: P11-000 trigger validator AST is unavailable'}
Invoke-Expression $P11000TriggerFunction.Extent.Text
$P11000Sha='5'*40;$P11000EvidenceSha='6'*64;$P11000SelectionSha='7'*64;$P11000ReleaseSha='8'*64;$P11000Cycle=[Guid]::NewGuid().ToString()
$P11000Approvals=@('Data','Engineering','Security'|ForEach-Object{[pscustomobject]@{role=$_;actor_id=("reviewer-"+$_.ToLowerInvariant());decision='approved';candidate_sha=$P11000Sha;cycle_id=$P11000Cycle;evidence_sha256=$P11000EvidenceSha;expires_at='2099-01-01T00:00:00Z'}})
$P11000Trigger=[pscustomobject]@{
  schema_version='1.0';task_id='TASK-P11-000';cycle_id=$P11000Cycle;path='phase11';accepted_landing_sha=$P11000Sha
  path_selection_sha256=$P11000SelectionSha;release_b_sha256=$P11000ReleaseSha;evidence_sha256=$P11000EvidenceSha
  measurement=[pscustomobject]@{window_start='2026-01-01T00:00:00+08:00';window_end='2026-02-01T00:00:00+08:00';timezone='Asia/Shanghai';denominator=100;stable_knowledge_gap_count=25;rate=0.25;threshold=0.20;threshold_calibrated=$true;confidence=[pscustomobject]@{level=0.95;lower=0.21;upper=0.30};classified_failure_sha256=('9'*64);raw_user_data_included=$false}
  governance=[pscustomobject]@{adr=[pscustomobject]@{locator='immutable://adr/rag';sha256=('a'*64);status='signed'};license=[pscustomobject]@{locator='immutable://evidence/license';sha256=('b'*64)};privacy=[pscustomobject]@{locator='immutable://evidence/privacy';sha256=('c'*64)};residency=[pscustomobject]@{locator='immutable://evidence/residency';sha256=('d'*64)};deletion=[pscustomobject]@{locator='immutable://evidence/deletion';sha256=('e'*64)}}
  owner_signature=[pscustomobject]@{role='Product';actor_id='owner-product';decision='approved';candidate_sha=$P11000Sha;cycle_id=$P11000Cycle;evidence_sha256=$P11000EvidenceSha}
  approvals=$P11000Approvals
}
$P11000Dependency=[pscustomobject]@{passed=$true;accepted_landing_sha=$P11000Sha;cycle_id=$P11000Cycle;path_selection_sha256=$P11000SelectionSha;release_b_sha256=$P11000ReleaseSha}
$P11000Positive=Get-P11000TriggerState -Trigger $P11000Trigger -Dependency $P11000Dependency -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))
if(-not[bool]$P11000Positive.passed-or[double]$P11000Positive.checks.knowledge_gap_rate-ne0.25){throw 'positive: a calibrated and independently approved P11-000 trigger was rejected'}
$P11000AtThreshold=$P11000Trigger.PSObject.Copy();$P11000AtThreshold.measurement=$P11000Trigger.measurement.PSObject.Copy();$P11000AtThreshold.measurement.stable_knowledge_gap_count=20;$P11000AtThreshold.measurement.rate=0.20
if([bool](Get-P11000TriggerState -Trigger $P11000AtThreshold -Dependency $P11000Dependency -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P11-000 accepted a knowledge-gap share equal to rather than greater than 20 percent'}
$P11000NoDenominator=$P11000Trigger.PSObject.Copy();$P11000NoDenominator.measurement=$P11000Trigger.measurement.PSObject.Copy();$P11000NoDenominator.measurement.denominator=0
if([bool](Get-P11000TriggerState -Trigger $P11000NoDenominator -Dependency $P11000Dependency -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P11-000 accepted a trigger without a positive eligible-failure denominator'}
$P11000WeakConfidence=$P11000Trigger.PSObject.Copy();$P11000WeakConfidence.measurement=$P11000Trigger.measurement.PSObject.Copy();$P11000WeakConfidence.measurement.confidence=$P11000Trigger.measurement.confidence.PSObject.Copy();$P11000WeakConfidence.measurement.confidence.lower=0.19
if([bool](Get-P11000TriggerState -Trigger $P11000WeakConfidence -Dependency $P11000Dependency -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P11-000 accepted a confidence interval whose lower bound did not clear the calibrated threshold'}
$P11000Expired=$P11000Trigger.PSObject.Copy();$P11000Expired.approvals=@($P11000Trigger.approvals|ForEach-Object{$_.PSObject.Copy()});$P11000Expired.approvals[0].expires_at='2026-01-01T00:00:00Z'
if([bool](Get-P11000TriggerState -Trigger $P11000Expired -Dependency $P11000Dependency -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P11-000 accepted an expired independent approval'}
$P11000Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P11-000' -ModeValue 'Preflight'
if(-not[bool]$P11000Registry.registered){throw 'negative: a fully specialized P11-000 runner remains fail-closed in the conditional registry'}
foreach($FunctionName in @('Test-P11AtomicTask','Get-P11AtomicDefinition','Get-P11AtomicDependencyAggregateState')){$FunctionAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq$FunctionName},$true);if($null-eq$FunctionAst){throw "negative: P11 atomic helper is missing: $FunctionName"};Invoke-Expression $FunctionAst.Extent.Text}
$P11PolicyAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11KnowledgePolicyState'},$true);if($null-eq$P11PolicyAst-or$P11PolicyAst.Extent.Text-cnotmatch'owner_gap_count'-or$P11PolicyAst.Extent.Text-cnotmatch'delete_sla_gap_count'-or$P11PolicyAst.Extent.Text-cnotmatch'realtime_tool_boundary_gap_count'-or$P11PolicyAst.Extent.Text-cnotmatch'never_resurrect_tombstoned_content'){throw 'negative: P11-001 policy gate is not a structured owner/license/ACL/delete validator'}
Invoke-Expression $P11PolicyAst.Extent.Text
$PolicyRoot=Join-Path ([IO.Path]::GetTempPath()) ('gonow-p11-policy-'+[Guid]::NewGuid().ToString('N'));$PreviousPolicyRoot=$script:RepositoryRoot
try{$null=New-Item -ItemType Directory -Path (Join-Path $PolicyRoot 'contracts') -Force;$NewClass={param($Id)[ordered]@{id=$Id;owner_role='Data';license=[ordered]@{mode='allowlist';allowed_identifiers=@('internal-approved')};allowed_purposes=@('itinerary_planning');acl=[ordered]@{tenant_scope='current_tenant_only';default_decision='deny';sql_hard_filter=$true;materialization_recheck=$true};versioning=[ordered]@{identity='source_id+version';immutable_once_ingested=$true};retention=[ordered]@{maximum_days=30;expiry_creates_delete_request=$true};approval=[ordered]@{required_roles=@('Data');receipt_required=$true}}};$Source=[ordered]@{schema_version='1.0';default_decision='deny';tenant_boundary=[ordered]@{cross_tenant='deny'};realtime_facts=[ordered]@{decision='deny_rag';required_path='tool';classes=@('business_hours_live','route_live','weather_current')};source_classes=@((&$NewClass 'curated'),(&$NewClass 'tenant_private'),(&$NewClass 'licensed_public'))};$NewRule={param($Id)[ordered]@{source_class_id=$Id;sla=[ordered]@{read_deny_seconds=0;fanout_completion_seconds=3600};durable_tombstone_required=$true;completion_receipt_required=$true;restore_behavior='never_resurrect_tombstoned_content'}};$Delete=[ordered]@{schema_version='1.0';default_decision='deny_without_matching_rule';rules=@((&$NewRule 'curated'),(&$NewRule 'tenant_private'),(&$NewRule 'licensed_public'))};$SourcePath=Join-Path $PolicyRoot 'contracts/knowledge-source-policy-v1.yaml';$DeletePath=Join-Path $PolicyRoot 'contracts/knowledge-delete-policy-v1.yaml';$script:RepositoryRoot=$PolicyRoot;[IO.File]::WriteAllText($SourcePath,($Source|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($DeletePath,($Delete|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));$PolicyDefinition=[pscustomobject]@{files=@('contracts/knowledge-source-policy-v1.yaml','contracts/knowledge-delete-policy-v1.yaml')};$PolicyPositive=Get-P11KnowledgePolicyState -Definition $PolicyDefinition;if(-not[bool]$PolicyPositive.passed-or[int]$PolicyPositive.source_class_count-ne3){throw 'positive: P11-001 structured policy rejected a complete three-class contract'};$Source.source_classes[0].owner_role='';[IO.File]::WriteAllText($SourcePath,($Source|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));$MissingOwner=Get-P11KnowledgePolicyState -Definition $PolicyDefinition;if([bool]$MissingOwner.passed-or[int]$MissingOwner.owner_gap_count-ne1){throw 'negative: P11-001 structured policy accepted a source class without an owner'};$Source.source_classes[0].owner_role='Data';$Source.tenant_boundary.cross_tenant='allow';[IO.File]::WriteAllText($SourcePath,($Source|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));if([bool](Get-P11KnowledgePolicyState -Definition $PolicyDefinition).passed){throw 'negative: P11-001 structured policy accepted cross-tenant default allow'};$Source.tenant_boundary.cross_tenant='deny';$Delete.rules=@($Delete.rules|Select-Object -First 2);[IO.File]::WriteAllText($SourcePath,($Source|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($DeletePath,($Delete|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false));$MissingDelete=Get-P11KnowledgePolicyState -Definition $PolicyDefinition;if([bool]$MissingDelete.passed-or[int]$MissingDelete.delete_rule_gap_count-ne1){throw 'negative: P11-001 structured policy accepted a source class without a delete rule'}}finally{$script:RepositoryRoot=$PreviousPolicyRoot;if(Test-Path -LiteralPath $PolicyRoot){Remove-Item -LiteralPath $PolicyRoot -Recurse -Force}}
$P11AtomicIds=1..10|ForEach-Object{'TASK-P11-{0:D3}'-f$_}
foreach($AtomicId in $P11AtomicIds){
  $Definition=Get-P11AtomicDefinition -TaskIdValue $AtomicId;$Task=$Catalog.Tasks[$AtomicId]
  if($null-eq$Task-or-not(Test-P11AtomicTask -TaskIdValue $AtomicId)){throw "negative: P11 atomic task is not cataloged: $AtomicId"}
  if(@($Task.work_contract.required_changes).Count-ne1-or[string]$Task.work_contract.required_changes[0]-cne[string]$Definition.required_change){throw "negative: P11 atomic required change drifted from execplan: $AtomicId"}
  if((@($Task.file_allowlist|Sort-Object)-join',')-cne((@($Definition.files|Sort-Object))-join',')){throw "negative: P11 atomic file allowlist drifted from execplan: $AtomicId"}
  if((@($Task.allowed_taskgate_modes|Sort-Object)-join',')-cne((@($Definition.modes|Sort-Object))-join',')){throw "negative: P11 atomic mode set drifted from execplan: $AtomicId"}
  $ExpectedInputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/evidence/phase-11/phase-runtime-manifest.json');foreach($Prerequisite in $Definition.prerequisites){$Suffix=$Prerequisite.Substring(5);$ExpectedInputs+=@("docs/execution/status/$Prerequisite.json","docs/execution/evidence/phase-11/$Suffix/artifact-hashes.json","docs/execution/evidence/phase-11/$Suffix/gate-results.json")}
  if(@($ExpectedInputs|Where-Object{$_-notin@($Task.read_only_inputs)}).Count-ne0-or@($Task.read_only_inputs).Count-ne$ExpectedInputs.Count){throw "negative: P11 atomic read set does not bind every predecessor: $AtomicId"}
  foreach($Extra in @($Definition.extra_artifacts)){if($Extra-notin@($Task.evidence_outputs)){throw "negative: P11 atomic structured deliverable is undeclared: $AtomicId / $Extra"}}
  foreach($ModeName in @($Definition.modes)){if(-not[bool](Get-ConditionalTaskRunnerRegistryState -TaskIdValue $AtomicId -ModeValue $ModeName).registered){throw "negative: P11 atomic mode is not registered: $AtomicId / $ModeName"}}
}
if(@($Catalog.Tasks['TASK-P11-009'].directory_allowlist).Count-ne1-or[string]$Catalog.Tasks['TASK-P11-009'].directory_allowlist[0].path-cne'agent-service/tests/eval/datasets/rag/'){throw 'negative: P11-009 dataset directory contract is missing'}
foreach($ModeName in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','DependencyAudit','RollbackVerify')){$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$ModeName)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch'Test-P11AtomicTask -TaskIdValue \$TaskId'){throw "negative: P11 atomic specialization is missing in Invoke-Mode$ModeName"}}
foreach($ModeName in @('Security','Verify','Evidence','WorkPreflight','WorksetVerify','DependencyAudit','RollbackVerify')){$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$ModeName)},$true);if($HandlerAst.Extent.Text-cnotmatch'Get-P11AtomicExecutionBoundaryState -Definition \$Definition'){throw "negative: P11 atomic mode can bypass the formal dependency/branch boundary: $ModeName"}}
foreach($Name in @('Get-P11AtomicExecutionBoundaryState','Get-P11AtomicGateModeState','Get-P11AtomicMissingDirectoryTargetCount')){if($RunnerText-cnotmatch[regex]::Escape($Name)){throw "negative: P11 atomic boundary/status helper is missing: $Name"}}
if($RunnerText-cnotmatch'Get-P11AtomicMissingDirectoryTargetCount -Definition \$Definition'-or$RunnerText-cnotmatch'if\(-not\$Checks\.Contains\(\$Metric\)\)'){throw 'negative: P11 atomic empty-directory or security-counter fail-closed guard is missing'}
if($RunnerText-cnotmatch"Where-Object\{\[string\]\`$_.description-cne'Invoke TaskGate mode WorksetVerify'\}"-or$RunnerText-cnotmatch'recovered_diagnostic_failure_count=\$RecoveredFailures'){throw 'negative: P11 atomic WorksetVerify cannot recover from a diagnosed prior Workset failure while retaining its history'}
if($RunnerText-cmatch'p11_atomic_formal_predecessor_required'-or$RunnerText-cmatch'p11_089_formal_p11_010_acceptance_required'){throw 'negative: P11 implementation or convergence still contains a stale formal-only preflight guard'}
if($RunnerText-cnotmatch'projected_predecessor_count'-or$RunnerText-cnotmatch'remote_ref_check_pending'){throw 'negative: P11 local construction preflight does not expose projected predecessor or offline remote-ref state'}
$P11BranchAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11AtomicBranchState'},$true);$P11BranchText=$P11BranchAst.Extent.Text;if($P11BranchText-cnotmatch'cached_remote_tracking'-or$P11BranchText-cnotmatch'refs/remotes/origin/codex/phase-12'-or$P11BranchText-cnotmatch"ErrorActionPreference='Continue'"-or$P11BranchText-cnotmatch'origin_ls_remote'){throw 'negative: P11 branch boundary does not isolate local construction from network failure while preserving formal live-ref validation'}
if($RunnerText-cnotmatch"elseif \(Test-P11AtomicTask -TaskIdValue \`$TaskId\)"-or$RunnerText-cnotmatch'Get-P11AtomicGateModeState -Definition \$Definition'){throw 'negative: P11 atomic ready-for-review CAS does not aggregate each task exact mode set'}
if($RunnerText-cnotmatch"id=23;action='extend'"-or$RunnerText-cnotmatch'test_23_citation_assembler_s_'-or$RunnerText-cnotmatch'test_23_citation_assembler_i_'-or$RunnerText-cnotmatch'test_23_citation_assembler_d_'){throw 'negative: P11-006 does not emit the required control 23 S/I/D fragment'}
$Manifest=[pscustomobject]@{task_id='TASK-P11-000';phase='Phase 11';execution_mode='formal_adopted';phase_base_oid=('1'*40);formal_phase_base_oid=('1'*40);prior_phase_regression_failures=0;not_run=0;future_oid_literal_count=0;base_drift=0;source_hash_drift=0;catalog_sha256=('2'*64);plan_sha256=('3'*64)}
foreach($AtomicId in $P11AtomicIds){$Definition=Get-P11AtomicDefinition -TaskIdValue $AtomicId;$States=[ordered]@{};foreach($Prerequisite in $Definition.prerequisites){$States[$Prerequisite]=[pscustomobject]@{present_count=3;accepted=$true;passed=$true}};$Positive=Get-P11AtomicDependencyAggregateState -Definition $Definition -Manifest $Manifest -PredecessorStates $States -ExpectedCatalogSha ('2'*64) -ExpectedPlanSha ('3'*64);if(-not[bool]$Positive.passed){throw "positive: P11 atomic dependency aggregate rejected complete accepted predecessors: $AtomicId"};$Missing=[ordered]@{};if([bool](Get-P11AtomicDependencyAggregateState -Definition $Definition -Manifest $Manifest -PredecessorStates $Missing).passed){throw "negative: P11 atomic dependency aggregate accepted missing predecessors: $AtomicId"};$First=[string]$Definition.prerequisites[0];$Unaccepted=[ordered]@{};foreach($Prerequisite in $Definition.prerequisites){$Unaccepted[$Prerequisite]=[pscustomobject]@{present_count=3;accepted=($Prerequisite-cne$First);passed=$true}};if([bool](Get-P11AtomicDependencyAggregateState -Definition $Definition -Manifest $Manifest -PredecessorStates $Unaccepted).passed){throw "negative: P11 atomic dependency aggregate accepted an unaccepted predecessor: $AtomicId"}}
$LocalManifest=[pscustomobject]@{task_id='TASK-P11-000';phase='Phase 11';execution_mode='local_provisional';phase_base_oid=('1'*40);provisional_base_oid=('1'*40);formal_phase_base_oid=$null;local_dependency_projection_valid=$true;owner_directive_reference='user-message:2026-08-03:phase11-local-start';production_write_count=0;prior_phase_regression_failures=0;not_run=0;future_oid_literal_count=0;base_drift=0;source_hash_drift=0;catalog_sha256=('2'*64);plan_sha256=('3'*64)}
$ProjectedStates=[ordered]@{'TASK-P11-000'=[pscustomobject]@{present_count=2;accepted=$false;projected=$true;passed=$true}};$ProjectedPositive=Get-P11AtomicDependencyAggregateState -Definition (Get-P11AtomicDefinition -TaskIdValue 'TASK-P11-001') -Manifest $LocalManifest -PredecessorStates $ProjectedStates -ExpectedCatalogSha ('2'*64) -ExpectedPlanSha ('3'*64);if(-not[bool]$ProjectedPositive.passed-or-not[bool]$ProjectedPositive.checks.local_projection-or[int]$ProjectedPositive.checks.projected_predecessor_count-ne1){throw 'positive: P11 local construction projection rejected the exact owner-directed manifest and projected predecessor'}
$LocalWrongDirective=$LocalManifest.PSObject.Copy();$LocalWrongDirective.owner_directive_reference='user-message:unknown';if([bool](Get-P11AtomicDependencyAggregateState -Definition (Get-P11AtomicDefinition -TaskIdValue 'TASK-P11-001') -Manifest $LocalWrongDirective -PredecessorStates $ProjectedStates).passed){throw 'negative: P11 local construction projection accepted an unbound owner directive'}
$LocalProductionWrite=$LocalManifest.PSObject.Copy();$LocalProductionWrite.production_write_count=1;if([bool](Get-P11AtomicDependencyAggregateState -Definition (Get-P11AtomicDefinition -TaskIdValue 'TASK-P11-001') -Manifest $LocalProductionWrite -PredecessorStates $ProjectedStates).passed){throw 'negative: P11 local construction projection accepted a production write'}
$BadManifest=$Manifest.PSObject.Copy();$BadManifest.not_run=1;$FirstDefinition=Get-P11AtomicDefinition -TaskIdValue 'TASK-P11-001';$FirstStates=[ordered]@{'TASK-P11-000'=[pscustomobject]@{present_count=3;accepted=$true;passed=$true}};if([bool](Get-P11AtomicDependencyAggregateState -Definition $FirstDefinition -Manifest $BadManifest -PredecessorStates $FirstStates).passed){throw 'negative: P11 atomic dependency aggregate accepted a phase manifest with a not-run regression'}
$P11089Required=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5oyJ5a6e6ZmFIGRpZmYg5pu05pawIGBSRUFETUUubWRg44CBYGRvY3MvYXJjaGl0ZWN0dXJlL3JhZy5tZGDjgIFgZG9jcy9ydW5ib29rcy9yYWctcm9sbGJhY2subWRg44CBYGRvY3MvcnVuYm9va3Mva25vd2xlZGdlLWRlbGV0aW9uLm1kYOOAgWBkb2NzL2FwaS9yYWctY2l0YXRpb25zLm1kYOOAgWBjb250cmFjdHMvb3BlbmFwaS9hZ2VudC1hcGkueWFtbGDjgIFgY29udHJhY3RzL2tub3dsZWRnZS9rbm93bGVkZ2Uuc2NoZW1hLmpzb25g44CBdGhyZWF0LW1vZGVsIHJldmlldyByZWNlaXB077yI5ZCrIG1vZGVsIGhhc2jjgIFjYW5kaWRhdGUgaGVhZOOAgVNlY3VyaXR5IG93bmVy77yb5peg5Y+Y5YyW5YaZIG1vZGVsX2NoYW5nZWQ9ZmFsc2XvvInjgIFjaGFuZ2Utc3VtbWFyeeOAgWtub3dsZWRnZS10cmFuc2ZlcuOAgVNUQVIvTi9BIOWSjCBwcmVtZXJnZSBtYW5pZmVzdA=='))
$P11089Task=$Catalog.Tasks['TASK-P11-089'];$P11089Files=@('README.md','docs/architecture/rag.md','docs/runbooks/rag-rollback.md','docs/runbooks/knowledge-deletion.md','docs/api/rag-citations.md','contracts/openapi/agent-api.yaml','contracts/knowledge/knowledge.schema.json','docs/architecture/threat-model/phase-11-review.json','docs/execution/evidence/phase-11/change-summary.md','docs/execution/evidence/phase-11/knowledge-transfer.md','docs/execution/evidence/phase-11/star-records.md','docs/execution/evidence/phase-11/artifact-manifest.premerge.json','docs/execution/schemas/harness-test-catalog.yaml','docs/execution/status/task-board.json','docs/execution/status/task-board.md')
$P11089Inputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/evidence/phase-11/phase-runtime-manifest.json');foreach($AtomicId in $P11AtomicIds){$Suffix=$AtomicId.Substring(5);$P11089Inputs+=@("docs/execution/status/$AtomicId.json","docs/execution/evidence/phase-11/$Suffix/artifact-hashes.json","docs/execution/evidence/phase-11/$Suffix/gate-results.json")}
$P11089Outputs=@('docs/architecture/threat-model/phase-11-review.json','docs/execution/evidence/phase-11/change-summary.md','docs/execution/evidence/phase-11/knowledge-transfer.md','docs/execution/evidence/phase-11/P11-089/artifact-hashes.json','docs/execution/evidence/phase-11/P11-089/commands.json','docs/execution/evidence/phase-11/P11-089/gate-results.json','docs/execution/evidence/phase-11/P11-089/handoff-verification.json','docs/execution/evidence/phase-11/P11-089/harness-catalog-aggregate.json','docs/execution/evidence/phase-11/star-records.md','docs/execution/evidence/phase-11/artifact-manifest.premerge.json','docs/execution/schemas/harness-test-catalog.yaml','docs/execution/status/task-board.json','docs/execution/status/task-board.md','docs/execution/status/TASK-P11-089.json')
if($null-eq$P11089Task-or(@($P11089Task.prerequisite_task_ids)-join',')-cne'TASK-P11-010'-or@($P11089Task.work_contract.required_changes).Count-ne1-or[string]$P11089Task.work_contract.required_changes[0]-cne$P11089Required-or(@($P11089Task.file_allowlist|Sort-Object)-join',')-cne((@($P11089Files|Sort-Object))-join',')-or(@($P11089Task.work_contract.repo_patch_targets|Sort-Object)-join',')-cne((@($P11089Files|Sort-Object))-join',')-or(@($P11089Task.read_only_inputs|Sort-Object)-join',')-cne((@($P11089Inputs|Sort-Object))-join',')-or(@($P11089Task.evidence_outputs|Sort-Object)-join',')-cne((@($P11089Outputs|Sort-Object))-join',')-or(@($P11089Task.directory_allowlist)-join',')-cne'docs/execution/evidence/phase-11/improvements/'-or[string]$P11089Task.expected_assertions[0]-cnotmatch'24f12ea3c8e96247ae2aef1403c179b9460f54adcb2a4203be218d7d4376a59e'){throw 'negative: P11-089 Catalog does not exactly bind its ten-task convergence documentation contract'}
$P11089Modes=@('Documentation','Evidence','HandoffVerification','HarnessCatalogAggregate','Preflight','RollbackVerify','Security','StatusBoardAggregate','WorkPreflight','WorksetVerify');if((@($P11089Task.allowed_taskgate_modes|Sort-Object)-join',')-cne((@($P11089Modes|Sort-Object))-join',')){throw 'negative: P11-089 mode set drifted from execplan'}
foreach($ModeName in $P11089Modes){$Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P11-089' -ModeValue $ModeName;if(-not[bool]$Registry.registered){throw "negative: P11-089 mode is not registered: $ModeName"};$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$ModeName)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch "if \(\`$TaskId -ceq 'TASK-P11-089'\) \{"){throw "negative: P11-089 specialization is missing in Invoke-Mode$ModeName"}}
foreach($Name in @('Get-P11089Definition','Get-P11089DependencyState','Get-P11089BranchState','Get-P11089ExecutionBoundaryState','Get-P11089GateModeState')){if($RunnerText-cnotmatch[regex]::Escape($Name)){throw "negative: P11-089 convergence helper is missing: $Name"}}
$P11089DefinitionAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11089Definition'},$true);if($null-eq$P11089DefinitionAst){throw 'negative: P11-089 definition validator AST is unavailable'};Invoke-Expression $P11089DefinitionAst.Extent.Text
$P11089Definition=Get-P11089Definition;if((@($P11089Definition.prerequisites)-join',')-cne(@($P11AtomicIds)-join',')-or[string]$P11089Definition.required_change-cne$P11089Required-or[string]$P11089Definition.card_sha-cne'24f12ea3c8e96247ae2aef1403c179b9460f54adcb2a4203be218d7d4376a59e'){throw 'negative: P11-089 runner definition drifted from its frozen card'}
$P11089States=[ordered]@{};foreach($AtomicId in $P11AtomicIds){$P11089States[$AtomicId]=[pscustomobject]@{present_count=3;accepted=$true;passed=$true}};$P11089Positive=Get-P11AtomicDependencyAggregateState -Definition $P11089Definition -Manifest $Manifest -PredecessorStates $P11089States -ExpectedCatalogSha ('2'*64) -ExpectedPlanSha ('3'*64);if(-not[bool]$P11089Positive.passed-or[int]$P11089Positive.checks.accepted_predecessor_count-ne10){throw 'positive: P11-089 rejected ten complete accepted implementation tasks'}
$P11089Missing=[ordered]@{};if([bool](Get-P11AtomicDependencyAggregateState -Definition $P11089Definition -Manifest $Manifest -PredecessorStates $P11089Missing).passed){throw 'negative: P11-089 accepted missing implementation task evidence'};$P11089Unaccepted=[ordered]@{};foreach($AtomicId in $P11AtomicIds){$P11089Unaccepted[$AtomicId]=[pscustomobject]@{present_count=3;accepted=($AtomicId-cne'TASK-P11-005');passed=$true}};if([bool](Get-P11AtomicDependencyAggregateState -Definition $P11089Definition -Manifest $Manifest -PredecessorStates $P11089Unaccepted).passed){throw 'negative: P11-089 accepted an unaccepted implementation task'}
$P11089HandoffAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Invoke-ModeHandoffVerification'},$true);$P11089HandoffText=$P11089HandoffAst.Extent.Text;if($P11089HandoffText-cnotmatch'reviewer_is_implementer'-or$P11089HandoffText-cnotmatch'reviewer_actor_id'-or$P11089HandoffText-cnotmatch"Test-Path -LiteralPath \`$Path"-or$P11089HandoffText-cnotmatch"Get-Content -LiteralPath \`$Path"){throw 'negative: P11-089 handoff must validate an independent pre-existing receipt without fabricating it'}
$P11089HarnessAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Invoke-ModeHarnessCatalogAggregate'},$true);$P11089HarnessText=$P11089HarnessAst.Extent.Text;if($P11089HarnessText-cnotmatch'mutation_applied=\$false'-or$P11089HarnessText-cnotmatch'control_transitions=@\(\)'-or$P11089HarnessText-cnotmatch'id-eq23'-or$P11089HarnessText-cnotmatch'case_ids\.S'-or$P11089HarnessText-cnotmatch'case_ids\.I'-or$P11089HarnessText-cnotmatch'case_ids\.D'){throw 'negative: P11-089 must verify the frozen 34-control Catalog and committed control 23 S/I/D fragment without a transition'}
$P11990Required=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5rGH5oC7IHNvdXJjZeOAgUFDTOOAgWRlbGV0ZeOAgWV2YWwg5LiOIHJvbGxvdXQgYWNjZXB0ZWQgZXZpZGVuY2XvvIzmiafooYwgbWFuZGF0b3J5IHJlZ3Jlc3Npb24g5LiO55Sf5Lqn5ZCM6YWN572u6ZqU56a7IHJvbGxiYWNrIHJlY2VpcHQg5qCh6aqM77yM55Sf5oiQIGFjY2VwdGFuY2UvaW5kZXjvvIzpqozor4HkupTop5LoibLni6znq4vmibnlh4blubbkv53mjIEgYWNjZXB0ZWQ9ZmFsc2Ug55u05Yiw5aSW6YOo54q25oCB6L+B56e7'))
$P11990Task=$Catalog.Tasks['TASK-P11-990'];$P11990Files=@('docs/execution/evidence/phase-11/acceptance.md','docs/execution/evidence/index.json');$P11990Inputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/evidence/phase-11/phase-runtime-manifest.json','docs/execution/evidence/phase-11/artifact-manifest.premerge.json','docs/execution/evidence/phase-11/knowledge-transfer.md','docs/execution/evidence/phase-11/star-records.md','docs/architecture/threat-model/phase-11-review.json','docs/execution/schemas/harness-test-catalog.yaml','docs/execution/evidence/phase-11/P11-089/handoff-verification.json','docs/execution/evidence/phase-11/P11-089/harness-catalog-aggregate.json','docs/execution/evidence/phase-11/P11-990/approval-receipts.json','docs/execution/evidence/phase-11/P11-990/rollback-drill.json');foreach($Id in @($P11AtomicIds+@('TASK-P11-089'))){$Suffix=$Id.Substring(5);$P11990Inputs+=@("docs/execution/status/$Id.json","docs/execution/evidence/phase-11/$Suffix/artifact-hashes.json","docs/execution/evidence/phase-11/$Suffix/gate-results.json","docs/execution/evidence/phase-11/$Suffix/commands.json")}
$P11990Outputs=@('docs/execution/evidence/phase-11/acceptance.md','docs/execution/evidence/index.json','docs/execution/evidence/phase-11/P11-990/approval-receipts.json','docs/execution/evidence/phase-11/P11-990/rollback-drill.json','docs/execution/evidence/phase-11/P11-990/regression-summary.json','docs/execution/evidence/phase-11/P11-990/local-verification.json','docs/execution/evidence/phase-11/P11-990/gate-summary.json','docs/execution/evidence/phase-11/P11-990/artifact-hashes.json','docs/execution/evidence/phase-11/P11-990/commands.json','docs/execution/evidence/phase-11/P11-990/gate-results.json','docs/execution/status/TASK-P11-990.json')
if($null-eq$P11990Task-or(@($P11990Task.prerequisite_task_ids)-join',')-cne'TASK-P11-089'-or@($P11990Task.work_contract.required_changes).Count-ne1-or[string]$P11990Task.work_contract.required_changes[0]-cne$P11990Required-or(@($P11990Task.file_allowlist|Sort-Object)-join',')-cne((@($P11990Files|Sort-Object))-join',')-or(@($P11990Task.work_contract.repo_patch_targets|Sort-Object)-join',')-cne((@($P11990Files|Sort-Object))-join',')-or(@($P11990Task.read_only_inputs|Sort-Object)-join',')-cne((@($P11990Inputs|Sort-Object))-join',')-or(@($P11990Task.evidence_outputs|Sort-Object)-join',')-cne((@($P11990Outputs|Sort-Object))-join',')-or@($P11990Task.directory_allowlist).Count-ne0-or[string]$P11990Task.expected_assertions[0]-cnotmatch'e58916c8ae97809cde7940a4d4b877da70b1c996cf3e42746888d9f44719ab3d'){throw 'negative: P11-990 Catalog does not exactly bind its formal acceptance evidence contract'}
$P11990Modes=@('AcceptancePreflight','ApprovalValidation','BuildAcceptance','Documentation','Evidence','Regression','RollbackDrill','RollbackVerify','Security','Verify');if((@($P11990Task.allowed_taskgate_modes|Sort-Object)-join',')-cne((@($P11990Modes|Sort-Object))-join',')-or(@($P11990Task.reviewer_roles|Sort-Object)-join',')-cne'Data,Engineering,Privacy,Product,Security'-or[int]$P11990Task.approval_policy.minimum_approvals-ne5){throw 'negative: P11-990 mode or five-role independent approval policy drifted from execplan'}
foreach($ModeName in $P11990Modes){$Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P11-990' -ModeValue $ModeName;if(-not[bool]$Registry.registered){throw "negative: P11-990 mode is not registered: $ModeName"};$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$ModeName)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch "if \(\`$TaskId -ceq 'TASK-P11-990'\) \{"){throw "negative: P11-990 specialization is missing in Invoke-Mode$ModeName"}}
foreach($Name in @('Get-P11990Definition','Get-P11990DependencyState','Get-P11990BranchState','Get-P11990ExecutionBoundaryState','Get-P11990GateModeState','Get-P11990SourceTargets','Get-P11990NamedMetricSum','Get-P11990HarnessState','Get-P11990BlockerState','Get-P11990ApprovalState','Get-P11990RollbackState','Get-P11990DocumentationState','Write-P11990AcceptanceEvidence','Write-P11990ArtifactEvidence')){if($RunnerText-cnotmatch[regex]::Escape($Name)){throw "negative: P11-990 acceptance helper is missing: $Name"}}
$P11990DefinitionAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11990Definition'},$true);$P11990MetricAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11990NamedMetricSum'},$true);if($null-eq$P11990DefinitionAst-or$null-eq$P11990MetricAst){throw 'negative: P11-990 pure validator AST is unavailable'};Invoke-Expression $P11990DefinitionAst.Extent.Text;Invoke-Expression $P11990MetricAst.Extent.Text
$P11990Definition=Get-P11990Definition;$P11990Prerequisites=@($P11AtomicIds+@('TASK-P11-089'));if((@($P11990Definition.prerequisites)-join',')-cne($P11990Prerequisites-join',')-or[string]$P11990Definition.required_change-cne$P11990Required-or[string]$P11990Definition.card_sha-cne'e58916c8ae97809cde7940a4d4b877da70b1c996cf3e42746888d9f44719ab3d'){throw 'negative: P11-990 runner definition drifted from its frozen card'}
$P11990States=[ordered]@{};foreach($Id in $P11990Prerequisites){$P11990States[$Id]=[pscustomobject]@{present_count=3;accepted=$true;passed=$true}};$P11990Positive=Get-P11AtomicDependencyAggregateState -Definition $P11990Definition -Manifest $Manifest -PredecessorStates $P11990States -ExpectedCatalogSha ('2'*64) -ExpectedPlanSha ('3'*64);if(-not[bool]$P11990Positive.passed-or[int]$P11990Positive.checks.accepted_predecessor_count-ne11){throw 'positive: P11-990 rejected eleven complete accepted predecessor tasks'};$P11990Unaccepted=[ordered]@{};foreach($Id in $P11990Prerequisites){$P11990Unaccepted[$Id]=[pscustomobject]@{present_count=3;accepted=($Id-cne'TASK-P11-089');passed=$true}};if([bool](Get-P11AtomicDependencyAggregateState -Definition $P11990Definition -Manifest $Manifest -PredecessorStates $P11990Unaccepted).passed){throw 'negative: P11-990 accepted an unaccepted P11-089 convergence task'}
$MetricProbe=[pscustomobject]@{failed=1;nested=[pscustomobject]@{skipped=2;ignored=9};rows=@([pscustomobject]@{failed=3})};if((Get-P11990NamedMetricSum -Value $MetricProbe -Names @('failed','skipped'))-ne6){throw 'negative: P11-990 recursive mandatory regression metric aggregation is incomplete'}
$P11990DependencyAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11AtomicDependencyState'},$true);if($P11990DependencyAst.Extent.Text-cnotmatch"TASK-P11-089'.*Get-P11089Definition"-or$P11990DependencyAst.Extent.Text-cnotmatch"TASK-P11-990'.*Get-P11990Definition"){throw 'negative: P11 dependency aggregation does not verify convergence/acceptance exact mandatory mode sets'}
foreach($FunctionName in @('Get-P11990ApprovalState','Get-P11990RollbackState')){$FunctionAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq$FunctionName},$true);if($null-eq$FunctionAst-or$FunctionAst.Extent.Text-cnotmatch'reviewer_is_implementer'-or$FunctionAst.Extent.Text-cnotmatch'candidate_head_oid'-or$FunctionAst.Extent.Text-cmatch'Write-AtomicJson'){throw "negative: $FunctionName must validate a pre-existing independent HEAD-bound receipt without fabricating it"}}
if($RunnerText-cnotmatch'minimum_unit_tests=542'-or$RunnerText-cnotmatch'minimum_contract_tests=144'-or$RunnerText-cnotmatch'minimum_flutter_tests=82'-or$RunnerText-cnotmatch'first_phase_le_p11_unimplemented_count'-or$RunnerText-cnotmatch"accepted=\`$false"){throw 'negative: P11-990 lacks exact mandatory regression, Harness, or no-self-acceptance boundaries'}
$P11999Task=$Catalog.Tasks['TASK-P11-999'];$P11999Files=@('docs/execution/evidence/phase-11/merge.json','docs/execution/evidence/index.json','docs/execution/evidence/phase-11/retrospective.md','docs/execution/evidence/phase-11/cleanup-result.json','docs/execution/evidence/phase-11/artifact-manifest-v01.json','docs/execution/evidence/phase-11/phase-close-v01.json','docs/execution/status/TASK-P11-999.json');$P11999Directories=@('docs/execution/evidence/phase-11/P11-999/','docs/execution/evidence/integration/');$P11999Inputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/commands/Invoke-PhaseMerge.ps1','docs/execution/commands/Invoke-IntegrationSmoke.ps1','docs/execution/status/TASK-P11-990.json','docs/execution/evidence/phase-11/P11-990/approval-receipts.json','docs/execution/evidence/phase-11/P11-990/gate-results.json','docs/execution/evidence/phase-11/P11-990/gate-summary.json','docs/execution/evidence/phase-11/P11-990/regression-summary.json','docs/execution/evidence/phase-11/P11-990/rollback-drill.json','docs/execution/evidence/phase-11/P11-007/gate-results.json','docs/execution/evidence/phase-11/P11-010/rollout.yaml','docs/execution/evidence/phase-11/phase-runtime-manifest.json','docs/execution/evidence/phase-11/artifact-manifest.premerge.json','docs/execution/evidence/phase-11/acceptance.md','docs/execution/evidence/boot/BOOT-004.json');$P11999Outputs=@('docs/execution/evidence/phase-11/merge.json','docs/execution/evidence/index.json','docs/execution/evidence/phase-11/retrospective.md','docs/execution/evidence/phase-11/cleanup-result.json','docs/execution/evidence/phase-11/artifact-manifest-v01.json','docs/execution/evidence/phase-11/phase-close-v01.json','docs/execution/evidence/phase-11/P11-999/merge-authorization.json','docs/execution/evidence/phase-11/P11-999/artifact-hashes.json','docs/execution/evidence/phase-11/P11-999/commands.json','docs/execution/evidence/phase-11/P11-999/gate-results.json','docs/execution/status/TASK-P11-999.json');$P11999Ct=@('CT-001','CT-002','CT-003','CT-004','CT-005','CT-006','CT-007','CT-008','CT-010','CT-011','CT-012','CT-013','CT-014');$P11999Modes=@('Archive','Cleanup','CloseVerify','IntegrationSmoke','Merge','MergePreflight','MergeTreeVerification','PostMergeEvidence','Retrospective','RollbackVerify','Security');$P11999Required='freeze accepted P11 candidate, owner approvals, phase base and approval-only tip; perform exact no-ff landing merge; prove parent/tree equivalence; run exact-merge smoke; archive STAR, cleanup, rollback, versioned manifest and close evidence without touching main, Phase 12, remote, or production'
if($null-eq$P11999Task-or(@($P11999Task.prerequisite_task_ids)-join',')-cne'TASK-P11-990'-or-not[bool]$P11999Task.mutates_repo-or(@($P11999Task.allowed_taskgate_modes)-join',')-cne'Evidence'-or(@($P11999Task.allowed_phase_merge_modes|Sort-Object)-join',')-cne((@($P11999Modes|Sort-Object))-join',')-or(@($P11999Task.applicable_ct_ids)-join',')-cne($P11999Ct-join',')-or(@($P11999Task.file_allowlist|Sort-Object)-join',')-cne((@($P11999Files|Sort-Object))-join',')-or(@($P11999Task.directory_allowlist)-join',')-cne($P11999Directories-join',')-or(@($P11999Task.read_only_inputs|Sort-Object)-join',')-cne((@($P11999Inputs|Sort-Object))-join',')-or(@($P11999Task.evidence_outputs|Sort-Object)-join',')-cne((@($P11999Outputs|Sort-Object))-join',')-or@($P11999Task.work_contract.required_changes).Count-ne1-or[string]$P11999Task.work_contract.required_changes[0]-cne$P11999Required-or[string]$P11999Task.expected_assertions[0]-cnotmatch'ce1c152c01684c6ec9c743f34cc5e57b6d7b9db3b65874815cc8ff9099bbb1cd'){throw 'negative: P11-999 Catalog does not exactly bind its formal merge and close contract'}
if((@($P11999Task.reviewer_roles|Sort-Object)-join',')-cne'Engineering,Product,Security'-or[int]$P11999Task.approval_policy.minimum_approvals-ne3-or(@($P11999Task.security_check_ids|Sort-Object)-join',')-cne'SEC-AUDIT,SEC-AUTHZ,SEC-ID,SEC-PII,SEC-SECRET'){throw 'negative: P11-999 independent ReleaseC Board or security policy drifted from execplan'}
$P11999Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P11-999' -ModeValue 'Evidence';if(-not[bool]$P11999Registry.registered){throw 'negative: P11-999 final Evidence validator remains fail-closed'};$EvidenceHandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Invoke-ModeEvidence'},$true);$FinalEvidenceAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P11999FinalEvidenceState'},$true);if($null-eq$FinalEvidenceAst-or$EvidenceHandlerAst.Extent.Text-cnotmatch"if \(\`$TaskId -ceq 'TASK-P11-999'\) \{"){throw 'negative: P11-999 read-only final Evidence specialization is missing'};if($FinalEvidenceAst.Extent.Text-cmatch'(?i)(Write-Atomic|Set-TaskStatus|Add-GateResult|Add-CommandRecord)'){throw 'negative: P11-999 final Evidence validator is not read-only'}
foreach($Marker in @('parent_count','approval_tip_oid','tracked_write_count','duration_seconds','manifest_self_reference_count','phase_close_oid_locator','mandatory_mode_invalid_count','identity_denied_mismatch','authorization_bypass_count','landing_clean')){if($FinalEvidenceAst.Extent.Text-cnotmatch[regex]::Escape($Marker)){throw "negative: P11-999 final Evidence validator misses $Marker"}}
$P12000RequiredChangeBase64='5Zyo5bey5qC46aqM55qEIGNsZWFuIGdvdmVybmFuY2Ugd29ya3RyZWUg6YeN6K+7IGN5Y2xlIHJlY29yZCDkuI4gbGFuZGluZyBTSEEg4oaSIOS7heWvvOWFpeWklumDqOivgeaNruW8leeUqC9oYXNoIOKGkiDlrprkuYnnqpflj6PjgIHliIbmr43jgIHor6/lt67lubbmoKHlh4bpmIjlgLwg4oaSIOavlOi+g+mjjumZqeOAgeaIkOacrOWSjOWbnua7miDihpIg6L6T5Ye65LiA5Liq5YCZ6YCJ5oiWIGBub25lYA=='
$P12000RequiredChange=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($P12000RequiredChangeBase64))
$P12000DetailBase64='c2VsZWN0ZWRfY291bnTiiIh7MCwxfe+8m+e7k+aenOS4uiAxMkF8MTJCfDEyQ3wxMkR8bm9uZe+8m+acqumAieW3peS9nOWMhSBzdGF0dXM9bm90X3N0YXJ0ZWQg5LiUIGJyYW5jaF9jb3VudD0w'
$P12000Task=$Catalog.Tasks['TASK-P12-000'];$P12000Inputs=@('docs/execution/evidence/releases/REL-C-000/path-selection.json','docs/execution/evidence/releases/REL-C-000/phase12-trigger-evidence.json','docs/execution/status/TASK-REL-C-000.json','docs/execution/evidence/releases/B.json')
if($null-eq$P12000Task-or@($P12000Task.work_contract.required_changes).Count-ne1-or[string]$P12000Task.work_contract.required_changes[0]-cne$P12000RequiredChange-or@($P12000Inputs|Where-Object{$_-notin@($P12000Task.read_only_inputs)}).Count-ne0){throw 'negative: P12-000 Catalog does not bind its exact comparison contract and immutable Release C/Release B inputs'}
foreach($P12000Mode in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','RollbackVerify')){$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$P12000Mode)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch 'if \(\$TaskId -ceq ''TASK-P12-000''\) \{'){throw "negative: P12-000 specialization is missing in Invoke-Mode$P12000Mode"}}
if($RunnerText -notmatch 'Get-P12000InputState' -or$RunnerText -notmatch 'Get-P12000AnalysisState' -or$RunnerText -notmatch 'Get-P12000DependencyState' -or$RunnerText -notmatch 'Get-P12000GateModeState' -or-not$RunnerText.Contains($P12000DetailBase64)){throw 'negative: P12-000 must own immutable input, XOR analysis, dependency, exact detail, and seven-mode contracts'}
$P12000InputFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P12000InputState'},$true);$P12000AnalysisFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P12000AnalysisState'},$true)
if($null-eq$P12000InputFunction-or$null-eq$P12000AnalysisFunction){throw 'negative: P12-000 pure validators are unavailable'};Invoke-Expression $P12000InputFunction.Extent.Text;Invoke-Expression $P12000AnalysisFunction.Extent.Text
$P12000Sha='a'*40;$P12000Evidence='b'*64;$P12000Selection='c'*64;$P12000Release='d'*64;$P12000InputSha='e'*64;$P12000Cycle=[Guid]::NewGuid().ToString();$P12000Ids=@('12A','12B','12C','12D','none')
$P12000InputAlternatives=@($P12000Ids|ForEach-Object{[pscustomobject]@{id=$_;denominator=100;numerator=25;confidence=[pscustomobject]@{level=0.95;lower=0.20;upper=0.30};risks=@('bounded-risk');cost=[pscustomobject]@{unit='usd_per_successful_task';estimate=0.10;evidence_sha256=('1'*64)};rollback=[pscustomobject]@{strategy='independent flag off';evidence_sha256=('2'*64)};evidence_sha256=('3'*64)}})
$P12000Input=[pscustomobject]@{schema_version='1.0';task_id='TASK-P12-000';cycle_id=$P12000Cycle;path='phase12';accepted_landing_sha=$P12000Sha;path_selection_sha256=$P12000Selection;release_b_sha256=$P12000Release;evidence_sha256=$P12000Evidence;window=[pscustomobject]@{start='2026-01-01T00:00:00+08:00';end='2026-02-01T00:00:00+08:00';timezone='Asia/Shanghai'};raw_user_data_included=$false;alternatives=$P12000InputAlternatives}
$P12000Dependency=[pscustomobject]@{passed=$true;accepted_landing_sha=$P12000Sha;cycle_id=$P12000Cycle;path_selection_sha256=$P12000Selection;release_b_sha256=$P12000Release;input_sha256=$P12000InputSha;input=$P12000Input}
$P12000AnalysisAlternatives=@($P12000Ids|ForEach-Object{[pscustomobject]@{id=$_;selected=($_-ceq'12C');input_evidence_sha256=('3'*64)}})
$P12000Approvals=@(@('Data','Engineering','Security')|ForEach-Object{[pscustomobject]@{role=$_;actor_id=("reviewer-"+$_.ToLowerInvariant());decision='approved';candidate_sha=$P12000Sha;cycle_id=$P12000Cycle;selected='12C';evidence_sha256=$P12000Evidence;expires_at='2099-01-01T00:00:00Z'}})
$P12000Analysis=[pscustomobject]@{schema_version='1.0';task_id='TASK-P12-000';cycle_id=$P12000Cycle;phase_base_sha=$P12000Sha;input_sha256=$P12000InputSha;evidence_sha256=$P12000Evidence;selected='12C';selected_count=1;alternatives=$P12000AnalysisAlternatives;unselected_work_packages=@([pscustomobject]@{id='12A';task_id='TASK-P12A-000';status='not_started';branch_count=0},[pscustomobject]@{id='12B';task_id='TASK-P12B-000';status='not_started';branch_count=0},[pscustomobject]@{id='12D';task_id='TASK-P12D-000';status='not_started';branch_count=0});owner_signature=[pscustomobject]@{role='Product';actor_id='owner-product';decision='approved';candidate_sha=$P12000Sha;cycle_id=$P12000Cycle;selected='12C';evidence_sha256=$P12000Evidence};approvals=$P12000Approvals}
$P12000Branches=[pscustomobject]@{passed=$true;specialist_branch_count=0;current_branch='codex/release-c-governance';current_head_oid=('f'*40)}
$P12000InputPositive=Get-P12000InputState -Input $P12000Input -Dependency $P12000Dependency
$P12000Positive=Get-P12000AnalysisState -Analysis $P12000Analysis -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))
if(-not[bool]$P12000Positive.passed-or[int]$P12000Positive.checks.selected_count-ne1-or[string]$P12000Positive.checks.selected-cne'12C'){throw ('positive: a fully bound single P12 capability analysis was rejected: analysis='+($P12000Positive.checks|ConvertTo-Json -Compress)+'; input='+($P12000InputPositive.checks|ConvertTo-Json -Compress))}
$P12000Multi=$P12000Analysis.PSObject.Copy();$P12000Multi.alternatives=@($P12000Analysis.alternatives|ForEach-Object{$_.PSObject.Copy()});$P12000Multi.alternatives[0].selected=$true;$P12000Multi.selected_count=2
if([bool](Get-P12000AnalysisState -Analysis $P12000Multi -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P12-000 accepted multiple selected capability packages'}
$P12000NoneValid=$P12000Analysis.PSObject.Copy();$P12000NoneValid.selected='none';$P12000NoneValid.selected_count=0;$P12000NoneValid.alternatives=@($P12000Analysis.alternatives|ForEach-Object{$x=$_.PSObject.Copy();$x.selected=$false;$x});$P12000NoneValid.unselected_work_packages=@(@('12A','12B','12C','12D')|ForEach-Object{[pscustomobject]@{id=$_;task_id=("TASK-P12"+$_.Substring(2)+"-000");status='not_started';branch_count=0}});$P12000NoneValid.owner_signature=$P12000Analysis.owner_signature.PSObject.Copy();$P12000NoneValid.owner_signature.selected='none';$P12000NoneValid.approvals=@($P12000Analysis.approvals|ForEach-Object{$x=$_.PSObject.Copy();$x.selected='none';$x})
if(-not[bool](Get-P12000AnalysisState -Analysis $P12000NoneValid -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'positive: a fully bound P12 none outcome was rejected'}
$P12000None=$P12000NoneValid.PSObject.Copy();$P12000None.selected_count=1
if([bool](Get-P12000AnalysisState -Analysis $P12000None -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P12-000 accepted selected_count=1 for the none outcome'}
$P12000Started=$P12000Analysis.PSObject.Copy();$P12000Started.unselected_work_packages=@($P12000Analysis.unselected_work_packages|ForEach-Object{$_.PSObject.Copy()});$P12000Started.unselected_work_packages[0].status='ready_for_review'
if([bool](Get-P12000AnalysisState -Analysis $P12000Started -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P12-000 accepted an already-started unselected work package'}
$P12000Expired=$P12000Analysis.PSObject.Copy();$P12000Expired.approvals=@($P12000Analysis.approvals|ForEach-Object{$_.PSObject.Copy()});$P12000Expired.approvals[0].expires_at='2026-01-01T00:00:00Z'
if([bool](Get-P12000AnalysisState -Analysis $P12000Expired -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P12-000 accepted an expired independent reviewer'}
$P12000Collision=$P12000Analysis.PSObject.Copy();$P12000Collision.approvals=@($P12000Analysis.approvals|ForEach-Object{$_.PSObject.Copy()});$P12000Collision.approvals[0].actor_id='owner-product'
if([bool](Get-P12000AnalysisState -Analysis $P12000Collision -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P12-000 accepted a reviewer who was not independent from the owner'}
$P12000ZeroDenominator=$P12000Input.PSObject.Copy();$P12000ZeroDenominator.alternatives=@($P12000Input.alternatives|ForEach-Object{$_.PSObject.Copy()});$P12000ZeroDenominator.alternatives[0].denominator=0
if([bool](Get-P12000InputState -Input $P12000ZeroDenominator -Dependency $P12000Dependency).passed){throw 'negative: P12-000 accepted an option without a positive denominator'}
$P12000MissingNumerator=$P12000Input.PSObject.Copy();$P12000MissingNumerator.alternatives=@($P12000Input.alternatives|ForEach-Object{$_.PSObject.Copy()});$P12000MissingNumerator.alternatives[0]=($P12000MissingNumerator.alternatives[0]|Select-Object * -ExcludeProperty numerator)
if([bool](Get-P12000InputState -Input $P12000MissingNumerator -Dependency $P12000Dependency).passed){throw 'negative: P12-000 accepted an option whose missing numerator cast to zero'}
$P12000MissingSelectedCount=($P12000NoneValid|Select-Object * -ExcludeProperty selected_count)
if([bool](Get-P12000AnalysisState -Analysis $P12000MissingSelectedCount -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P12-000 accepted a none outcome whose missing selected_count cast to zero'}
$P12000MissingBranchCount=$P12000Analysis.PSObject.Copy();$P12000MissingBranchCount.unselected_work_packages=@($P12000Analysis.unselected_work_packages|ForEach-Object{$_.PSObject.Copy()});$P12000MissingBranchCount.unselected_work_packages[0]=($P12000MissingBranchCount.unselected_work_packages[0]|Select-Object * -ExcludeProperty branch_count)
if([bool](Get-P12000AnalysisState -Analysis $P12000MissingBranchCount -Dependency $P12000Dependency -BranchState $P12000Branches -Now ([DateTimeOffset]::Parse('2027-01-01T00:00:00Z'))).passed){throw 'negative: P12-000 accepted an unselected package whose missing branch_count cast to zero'}
$P12000Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P12-000' -ModeValue 'Preflight';if(-not[bool]$P12000Registry.registered){throw 'negative: a fully specialized P12-000 runner remains fail-closed in the conditional registry'}
$P12001Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P12-001' -ModeValue 'Preflight';if(-not[bool]$P12001Registry.registered){throw 'negative: fully specialized P12-001 remains fail-closed in the conditional registry'}
$P12001RequiredChangeBase64='Y29tcGFyZeKJpTIg4oaSIHRocmVhdC9kYXRhIOKGkiBsb2FkIOKGkiByb2xsYmFjayDihpIgc2lnbg=='
$P12001RequiredChange=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($P12001RequiredChangeBase64));$P12001DetailBase64='6Kem5Y+R5qC35pysL+ivr+W3rui+ueeVjOWujOaVtO+8m0FEUiDmr5TovoPoh7PlsJEgMiDmlrnmoYjlubbojrflv4XopoEgb3duZXIg5om55YeG77ybYXBwcm92YWxfYWdlX2RheXM8PTE0'
$P12001Task=$Catalog.Tasks['TASK-P12-001'];$P12001Inputs=@('docs/execution/status/TASK-P12-000.json','docs/execution/evidence/phase-12/P12-000/artifact-hashes.json','docs/execution/evidence/phase-12/P12-000/analysis.json','docs/execution/evidence/phase-12/P12-000/analysis-verification.json','docs/execution/evidence/phase-12/P12-000/gate-results.json','docs/execution/evidence/phase-12/phase-runtime-manifest.json')
if($null-eq$P12001Task-or@($P12001Task.work_contract.required_changes).Count-ne1-or[string]$P12001Task.work_contract.required_changes[0]-cne$P12001RequiredChange-or@($P12001Inputs|Where-Object{$_-notin@($P12001Task.read_only_inputs)}).Count-ne0){throw 'negative: P12-001 Catalog does not bind the exact ADR approval contract and accepted P12-000 inputs'}
foreach($P12001Mode in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','RollbackVerify')){$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$P12001Mode)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch 'if \(\$TaskId -ceq ''TASK-P12-001''\) \{'){throw "negative: P12-001 specialization is missing in Invoke-Mode$P12001Mode"}}
if($RunnerText-cnotmatch'Get-P12001DependencyState'-or$RunnerText-cnotmatch'Get-P12001ApprovalState'-or$RunnerText-cnotmatch'Get-P12001BranchState'-or$RunnerText-cnotmatch'Get-P12001GateModeState'-or-not$RunnerText.Contains($P12001DetailBase64)){throw 'negative: P12-001 must own accepted dependency, ADR comparison, approval age, branch, detail, and seven-mode contracts'}
$P12001ApprovalFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P12001ApprovalState'},$true);if($null-eq$P12001ApprovalFunction){throw 'negative: P12-001 pure approval validator is unavailable'};Invoke-Expression $P12001ApprovalFunction.Extent.Text
$P12001Head='4'*40;$P12001Artifact='5'*64;$P12001AnalysisHash='6'*64;$P12001AdrHash='7'*64;$P12001Cycle=[Guid]::NewGuid().ToString();$P12001Now=[DateTimeOffset]::Parse('2027-01-01T00:00:00Z');$P12001Core="$P12001AdrHash|$P12001Cycle|12C|$P12001Head|$P12001Artifact|$P12001AnalysisHash";$P12001ProposalHash=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($P12001Core))).Replace('-','').ToLowerInvariant()
$P12001Dependency=[pscustomobject]@{passed=$true;p12_000_head_sha=$P12001Head;cycle_id=$P12001Cycle;selected='12C';artifact_sha256=$P12001Artifact;analysis_sha256=$P12001AnalysisHash}
$P12001Alternatives=@([pscustomobject]@{id='12B';threat='bounded';data='bounded';compatibility='compatible';load=[pscustomobject]@{numerator=20;denominator=100;unit='successful_tasks'};cost=[pscustomobject]@{estimate=0.10;unit='usd_per_successful_task'};rollback='flag off'},[pscustomobject]@{id='12C';threat='bounded';data='bounded';compatibility='compatible';load=[pscustomobject]@{numerator=25;denominator=100;unit='successful_tasks'};cost=[pscustomobject]@{estimate=0.12;unit='usd_per_successful_task'};rollback='flag off'})
$P12001Owner=[pscustomobject]@{role='Architecture';actor_id='owner-architecture';decision='approved';approved_at='2026-12-26T00:00:00Z';expires_at='2027-01-10T00:00:00Z';p12_000_head_sha=$P12001Head;cycle_id=$P12001Cycle;selected='12C';proposal_sha256=$P12001ProposalHash;adr_sha256=$P12001AdrHash}
$P12001Approvals=@(@('Security','Product','Data')|ForEach-Object{[pscustomobject]@{role=$_;actor_id=('reviewer-'+$_.ToLowerInvariant());decision='approved';approved_at='2026-12-27T00:00:00Z';expires_at='2027-01-10T00:00:00Z';p12_000_head_sha=$P12001Head;cycle_id=$P12001Cycle;selected='12C';proposal_sha256=$P12001ProposalHash;adr_sha256=$P12001AdrHash}})
$P12001Proposal=[pscustomobject]@{schema_version='1.0';task_id='TASK-P12-001';cycle_id=$P12001Cycle;p12_000_head_sha=$P12001Head;p12_000_artifact_sha256=$P12001Artifact;p12_000_analysis_sha256=$P12001AnalysisHash;proposal_sha256=$P12001ProposalHash;adr_sha256=$P12001AdrHash;selected='12C';raw_user_data_included=$false;alternatives=$P12001Alternatives;owner_signature=$P12001Owner;approvals=$P12001Approvals}
$P12001Positive=Get-P12001ApprovalState -Proposal $P12001Proposal -Dependency $P12001Dependency -Now $P12001Now;if(-not[bool]$P12001Positive.passed-or[int]$P12001Positive.checks.comparison_count-lt2-or[double]$P12001Positive.checks.approval_age_days-gt14){throw ('positive: fully bound P12-001 approval was rejected: '+($P12001Positive.checks|ConvertTo-Json -Compress))}
$P12001NoneDependency=$P12001Dependency.PSObject.Copy();$P12001NoneDependency.selected='none';$P12001NoneCore="$P12001AdrHash|$P12001Cycle|none|$P12001Head|$P12001Artifact|$P12001AnalysisHash";$P12001NoneHash=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($P12001NoneCore))).Replace('-','').ToLowerInvariant();$P12001None=$P12001Proposal.PSObject.Copy();$P12001None.selected='none';$P12001None.proposal_sha256=$P12001NoneHash;$P12001None.alternatives=@($P12001Alternatives|ForEach-Object{$_.PSObject.Copy()});$P12001None.alternatives[0].id='none';$P12001None.owner_signature=$P12001Owner.PSObject.Copy();$P12001None.owner_signature.selected='none';$P12001None.owner_signature.proposal_sha256=$P12001NoneHash;$P12001None.approvals=@($P12001Approvals|ForEach-Object{$x=$_.PSObject.Copy();$x.selected='none';$x.proposal_sha256=$P12001NoneHash;$x});if(-not[bool](Get-P12001ApprovalState -Proposal $P12001None -Dependency $P12001NoneDependency -Now $P12001Now).passed){throw 'positive: a fully bound P12-001 none approval was rejected'}
$P12001Single=$P12001Proposal.PSObject.Copy();$P12001Single.alternatives=@($P12001Proposal.alternatives|Select-Object -First 1);if([bool](Get-P12001ApprovalState -Proposal $P12001Single -Dependency $P12001Dependency -Now $P12001Now).passed){throw 'negative: P12-001 accepted an ADR comparison with fewer than two alternatives'}
$P12001MissingRollback=$P12001Proposal.PSObject.Copy();$P12001MissingRollback.alternatives=@($P12001Proposal.alternatives|ForEach-Object{$_.PSObject.Copy()});$P12001MissingRollback.alternatives[0]=($P12001MissingRollback.alternatives[0]|Select-Object * -ExcludeProperty rollback);if([bool](Get-P12001ApprovalState -Proposal $P12001MissingRollback -Dependency $P12001Dependency -Now $P12001Now).passed){throw 'negative: P12-001 accepted an alternative without rollback'}
$P12001Old=$P12001Proposal.PSObject.Copy();$P12001Old.approvals=@($P12001Proposal.approvals|ForEach-Object{$_.PSObject.Copy()});$P12001Old.approvals[0].approved_at='2026-12-01T00:00:00Z';if([bool](Get-P12001ApprovalState -Proposal $P12001Old -Dependency $P12001Dependency -Now $P12001Now).passed){throw 'negative: P12-001 accepted approval_age_days greater than 14'}
$P12001Future=$P12001Proposal.PSObject.Copy();$P12001Future.approvals=@($P12001Proposal.approvals|ForEach-Object{$_.PSObject.Copy()});$P12001Future.approvals[0].approved_at='2027-01-02T00:00:00Z';if([bool](Get-P12001ApprovalState -Proposal $P12001Future -Dependency $P12001Dependency -Now $P12001Now).passed){throw 'negative: P12-001 accepted a future-dated approval'}
$P12001Collision=$P12001Proposal.PSObject.Copy();$P12001Collision.approvals=@($P12001Proposal.approvals|ForEach-Object{$_.PSObject.Copy()});$P12001Collision.approvals[0].actor_id='owner-architecture';if([bool](Get-P12001ApprovalState -Proposal $P12001Collision -Dependency $P12001Dependency -Now $P12001Now).passed){throw 'negative: P12-001 accepted a reviewer who was not independent from the owner'}
$P12001HashMismatch=$P12001Proposal.PSObject.Copy();$P12001HashMismatch.proposal_sha256='9'*64;if([bool](Get-P12001ApprovalState -Proposal $P12001HashMismatch -Dependency $P12001Dependency -Now $P12001Now).passed){throw 'negative: P12-001 accepted a proposal hash that did not bind the ADR and accepted P12-000 inputs'}
$P12001Raw=$P12001Proposal.PSObject.Copy();$P12001Raw.raw_user_data_included=$true;if([bool](Get-P12001ApprovalState -Proposal $P12001Raw -Dependency $P12001Dependency -Now $P12001Now).passed){throw 'negative: P12-001 accepted raw user data in approval evidence'}
$P12002Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P12-002' -ModeValue 'Preflight';if(-not[bool]$P12002Registry.registered){throw 'negative: fully specialized P12-002 remains fail-closed in the conditional registry'}
$P12002RequiredChangeBase64='5qC46aqMIGV4cGVjdGVkIGdvdmVybmFuY2UgU0hBIOS4lCBjeWNsZSDlsJrml6AgYWNjZXB0ZWQgcmVjb3JkIOKGkiDlhpkgb3duZXIg562+572y44CB54mI5pys5YyW55qE5ZSv5LiAIFBoYXNlIDEyIHNlbGVjdGlvbiByZWNvcmQg4oaSIOS7pSBleHBlY3RlZC1TSEEgQ0FTIOabtOaWsOWPl+S/neaKpCBnb3Zlcm5hbmNlIHJlZiDihpIg6Z2eIGBub25lYCDml7bnmbvorrDllK/kuIDpooTmnJ/liIbmlK/lkI3vvIzkuI3liJvlu7ogcmVmL3dvcmt0cmVlIOKGkiDor4HmmI7miYDmnInkuJPpobnliIbmlK/ku43kuI3lrZjlnKjvvJtDQVMg5aSx6LSl5Y2z6Zi75aGe'
$P12002RequiredChange=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($P12002RequiredChangeBase64));$P12002DetailBase64='YG5vbmVgIOaXtiBzZWxlY3Rpb249MO+8jOWQpuWImSBzZWxlY3Rpb249Me+8m+S4k+mhueWIhuaUr+Wdh+S4jeWtmOWcqA=='
$P12002Task=$Catalog.Tasks['TASK-P12-002'];$P12002Inputs=@('docs/execution/status/TASK-P12-001.json','docs/execution/evidence/phase-12/P12-001/artifact-hashes.json','docs/execution/evidence/phase-12/P12-001/approval.json','docs/execution/evidence/phase-12/P12-001/approval-verification.json','docs/execution/evidence/phase-12/P12-001/gate-results.json','docs/execution/evidence/phase-12/phase-runtime-manifest.json')
if($null-eq$P12002Task-or@($P12002Task.work_contract.required_changes).Count-ne1-or[string]$P12002Task.work_contract.required_changes[0]-cne$P12002RequiredChange-or@($P12002Inputs|Where-Object{$_-notin@($P12002Task.read_only_inputs)}).Count-ne0){throw 'negative: P12-002 Catalog does not bind its exact XOR/CAS contract and accepted P12-001 inputs'}
$P12002Targets=@('docs/execution/evidence/phase-12/P12-002/selection.json','docs/execution/evidence/phase-12/P12-000/ref-reservation.json','docs/execution/evidence/phase-12/P12-002.json');$P12002Outputs=@($P12002Targets)+@('docs/execution/evidence/phase-12/P12-002/selection-verification.json','docs/execution/evidence/phase-12/P12-002/work-preflight.json','docs/execution/evidence/phase-12/P12-002/security-report.json','docs/execution/evidence/phase-12/P12-002/rollback-report.json','docs/execution/evidence/phase-12/P12-002/artifact-hashes.json','docs/execution/evidence/phase-12/P12-002/commands.json','docs/execution/evidence/phase-12/P12-002/gate-results.json','docs/execution/status/TASK-P12-002.json');$P12002AllInputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')+@($P12002Inputs)
if(@($P12002Task.evidence_outputs).Count-ne11-or(@($P12002Task.evidence_outputs|Sort-Object)-join',')-cne((@($P12002Outputs|Sort-Object))-join',')-or@($P12002Task.directory_allowlist).Count-ne1-or[string]$P12002Task.directory_allowlist[0]-cne'docs/execution/evidence/phase-12/P12-002/'-or(@($P12002Task.file_allowlist|Sort-Object)-join',')-cne((@($P12002Targets|Sort-Object))-join',')-or(@($P12002Task.work_contract.repo_patch_targets|Sort-Object)-join',')-cne((@($P12002Targets|Sort-Object))-join',')-or(@($P12002Task.read_only_inputs|Sort-Object)-join',')-cne((@($P12002AllInputs|Sort-Object))-join',')){throw 'negative: P12-002 lost its exact selection, reservation, CAS receipt, generated evidence, or immutable input materialization paths'}
foreach($P12002Mode in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','RollbackVerify')){$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$P12002Mode)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch 'if \(\$TaskId -ceq ''TASK-P12-002''\) \{'){throw "negative: P12-002 specialization is missing in Invoke-Mode$P12002Mode"}}
if($RunnerText-cnotmatch'Get-P12002DependencyState'-or$RunnerText-cnotmatch'Get-P12002SelectionState'-or$RunnerText-cnotmatch'Get-P12002BranchState'-or$RunnerText-cnotmatch'Get-P12002GateModeState'-or-not$RunnerText.Contains($P12002DetailBase64)){throw 'negative: P12-002 must own accepted dependency, XOR/CAS, topology, detail, and seven-mode contracts'}
$P12002SelectionFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P12002SelectionState'},$true);if($null-eq$P12002SelectionFunction){throw 'negative: P12-002 pure selection validator is unavailable'};Invoke-Expression $P12002SelectionFunction.Extent.Text
$P12002Expected='a'*40;$P12002New='b'*40;$P12002Artifact='c'*64;$P12002Cycle=[Guid]::NewGuid().ToString();$P12002PayloadCore="1|$P12002Cycle|$P12002Expected|$P12002Artifact|multi_agent|1|0|codex/phase-12c-multi-agent|refs/heads/codex/phase-12c-multi-agent";$P12002PayloadHash=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($P12002PayloadCore))).Replace('-','').ToLowerInvariant();$P12002Dependency=[pscustomobject]@{passed=$true;p12_001_head_sha=$P12002Expected;cycle_id=$P12002Cycle;approved_selection='multi_agent';artifact_sha256=$P12002Artifact;prior_accepted_selection_count=0}
$P12002Owner=[pscustomobject]@{role='Engineering';owner_alias='ReleaseEng';actor_id='owner-release-eng';decision='approved';cycle_id=$P12002Cycle;p12_001_head_sha=$P12002Expected;selection='multi_agent';selection_payload_sha256=$P12002PayloadHash}
$P12002Selection=[pscustomobject]@{schema_version='1.0';task_id='TASK-P12-002';record_version=1;cycle_id=$P12002Cycle;p12_001_head_sha=$P12002Expected;p12_001_artifact_sha256=$P12002Artifact;selection='multi_agent';selected_count=1;active_allocation=0;expected_branch_name='codex/phase-12c-multi-agent';expected_branch_ref='refs/heads/codex/phase-12c-multi-agent';selection_payload_sha256=$P12002PayloadHash;owner_signature=$P12002Owner}
$P12002Reservation=[pscustomobject]@{schema_version='1.0';task_id='TASK-P12-002';cycle_id=$P12002Cycle;selection='multi_agent';selected_count=1;active_allocation=0;expected_branch_name='codex/phase-12c-multi-agent';expected_branch_ref='refs/heads/codex/phase-12c-multi-agent';ref_created=$false;worktree_created=$false;selection_payload_sha256=$P12002PayloadHash}
$P12002Receipt=[pscustomobject]@{schema_version='1.0';task_id='TASK-P12-002';cycle_id=$P12002Cycle;command_id='git-update-ref-cas';adapter='approved-local-git-cas';executed_at='2027-01-01T00:00:00Z';ref='refs/heads/codex/release-c-governance';expected_sha=$P12002Expected;actual_sha=$P12002Expected;new_sha=$P12002New;update_succeeded=$true;cas_conflict=$false;selection_payload_sha256=$P12002PayloadHash;main_ref_write_count=0;remote_ref_write_count=0;specialist_ref_write_count=0;production_write_count=0}
$P12002Branches=[pscustomobject]@{passed=$true;current_branch='codex/release-c-governance';governance_ref_oid=$P12002New;current_head_oid=$P12002New;specialist_branch_count=0;specialist_worktree_count=0}
$P12002Positive=Get-P12002SelectionState -Selection $P12002Selection -Reservation $P12002Reservation -Receipt $P12002Receipt -Dependency $P12002Dependency -BranchState $P12002Branches;if(-not[bool]$P12002Positive.passed-or[int]$P12002Positive.checks.selected_count-ne1){throw ('positive: fully bound P12-002 single selection was rejected: '+($P12002Positive.checks|ConvertTo-Json -Compress))}
$P12002NoneDependency=$P12002Dependency.PSObject.Copy();$P12002NoneDependency.approved_selection='none';$P12002NoneCore="1|$P12002Cycle|$P12002Expected|$P12002Artifact|none|0|0||";$P12002NoneHash=[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($P12002NoneCore))).Replace('-','').ToLowerInvariant();$P12002None=$P12002Selection.PSObject.Copy();$P12002None.selection='none';$P12002None.selected_count=0;$P12002None.expected_branch_name=$null;$P12002None.expected_branch_ref=$null;$P12002None.selection_payload_sha256=$P12002NoneHash;$P12002None.owner_signature=$P12002Owner.PSObject.Copy();$P12002None.owner_signature.selection='none';$P12002None.owner_signature.selection_payload_sha256=$P12002NoneHash;$P12002NoneReservation=$P12002Reservation.PSObject.Copy();$P12002NoneReservation.selection='none';$P12002NoneReservation.selected_count=0;$P12002NoneReservation.expected_branch_name=$null;$P12002NoneReservation.expected_branch_ref=$null;$P12002NoneReservation.selection_payload_sha256=$P12002NoneHash;$P12002NoneReceipt=$P12002Receipt.PSObject.Copy();$P12002NoneReceipt.selection_payload_sha256=$P12002NoneHash;if(-not[bool](Get-P12002SelectionState -Selection $P12002None -Reservation $P12002NoneReservation -Receipt $P12002NoneReceipt -Dependency $P12002NoneDependency -BranchState $P12002Branches).passed){throw 'positive: fully bound P12-002 none selection was rejected'}
$P12002Multi=$P12002Selection.PSObject.Copy();$P12002Multi.selected_count=2;if([bool](Get-P12002SelectionState -Selection $P12002Multi -Reservation $P12002Reservation -Receipt $P12002Receipt -Dependency $P12002Dependency -BranchState $P12002Branches).passed){throw 'negative: P12-002 accepted selected_count greater than one'}
$P12002WrongBranch=$P12002Selection.PSObject.Copy();$P12002WrongBranch.expected_branch_name='codex/phase-12a-memory';if([bool](Get-P12002SelectionState -Selection $P12002WrongBranch -Reservation $P12002Reservation -Receipt $P12002Receipt -Dependency $P12002Dependency -BranchState $P12002Branches).passed){throw 'negative: P12-002 accepted a branch name for a different capability'}
$P12002CasMismatch=$P12002Receipt.PSObject.Copy();$P12002CasMismatch.actual_sha='e'*40;if([bool](Get-P12002SelectionState -Selection $P12002Selection -Reservation $P12002Reservation -Receipt $P12002CasMismatch -Dependency $P12002Dependency -BranchState $P12002Branches).passed){throw 'negative: P12-002 accepted a failed expected-SHA CAS binding'}
$P12002BranchExists=$P12002Branches.PSObject.Copy();$P12002BranchExists.specialist_branch_count=1;if([bool](Get-P12002SelectionState -Selection $P12002Selection -Reservation $P12002Reservation -Receipt $P12002Receipt -Dependency $P12002Dependency -BranchState $P12002BranchExists).passed){throw 'negative: P12-002 accepted an existing specialist branch'}
$P12WorkPackageCases=@(
  [ordered]@{task_id='TASK-P12A-000';selection='memory';prefix='P12A';required_b64='6aqM6K+B6Kem5Y+R5LiO5qC35pysIOKGkiDorr7orqEgbmVnYXRpdmUgY29uc2VudOOAgeeKtuaAgeOAgeWGsueqgeWSjCBwb2lzb25pbmcg5ZCI5ZCMIOKGkiDorr7orqHliKDpmaQv5a+85Ye6L+Wkh+S7veS4jeWkjea0u+mXqOemgSDihpIg5ouG5Y6f5a2QIFRBU0vjgIFhbGxvd2xpc3TjgIHlkb3ku6TkuI7lm57mu5og4oaSIOWcqOiuoeWIkuWPmOabtOS4reeZu+iusCBhY2NlcHRhbmNlL21lcmdlIElE';detail_b64='5Y6f5a2QIFRBU0sg5LiOIENULTAwOS8wMTUg5bey55m76K6w44CC';adr='docs/architecture/adr/ADR-P12A-000-memory-work-package.md';plan='docs/execution/evidence/phase-12/P12A-000/task-plan.md';directory='docs/execution/evidence/phase-12a/P12A-000/';ct=@('CT-009','CT-015');reviewers=@('Data','Privacy','Product','Security')},
  [ordered]@{task_id='TASK-P12B-000';selection='cost_router';prefix='P12B';required_b64='6aqM6K+B6Kem5Y+R44CB5qCH562+5ZKMIFRDTyDihpIg6K6+6K6hIGZhY3RvcnPjgIFyb3V0ZSByZWFzb27jgIFyZWdpb24vcHJpdmFjeSDihpIg6K6+6K6hIHJlcGxheeOAgW5vbi1yZWdyZXNzaW9uIOS4jiBraWxsIHN3aXRjaCDihpIg5ouG5Y6f5a2QIFRBU0vjgIFhbGxvd2xpc3TjgIHlkb3ku6TkuI7lm57mu5og4oaSIOWcqOiuoeWIkuWPmOabtOS4reeZu+iusCBhY2NlcHRhbmNlL21lcmdlIElE';detail_b64='6K6h5YiS55m76K6w5Y6f5a2Q5a6e546wIFRBU0vjgIHotKjph48v5oiQ5pysL+WbnumAgOmXqOemgeWSjOmihOeul+i0puacrO+8m2ltcGxlbWVudGF0aW9uX2NvbW1pdF9jb3VudD0w';adr='docs/architecture/adr/ADR-P12B-000-cost-router-work-package.md';plan='docs/execution/evidence/phase-12/P12B-000/task-plan.md';directory='docs/execution/evidence/phase-12b/P12B-000/';ct=@();reviewers=@('Eval','Finance','Security')},
  [ordered]@{task_id='TASK-P12C-000';selection='multi_agent';prefix='P12C';required_b64='6aqM6K+B5pS255uK44CB5qC35pys5ZKM5oiQ5pysIOKGkiDorr7orqHlhbHkuqsv5YiG5pSv6aKE566X44CBbWVyZ2UvY29uZmxpY3Qg4oaSIOiuvuiuoSBmYWxsYmFja+OAgeacgOWkp+WIhuaUr+WSjOWbnuWNleWbvuW8gOWFsyDihpIg5ouG5Y6f5a2QIFRBU0vjgIFhbGxvd2xpc3TjgIHlkb3ku6TkuI7lm57mu5og4oaSIOWcqOiuoeWIkuWPmOabtOS4reeZu+iusCBhY2NlcHRhbmNlL21lcmdlIElE';detail_b64='6K6h5YiS55m76K6w5YWx5Lqr6aKE566X44CBYnJhbmNoX2NvdW50PD0y44CB56Gu5a6a5oCnIG1lcmdl44CBQ1QtMDExIOS4juWbnuWNleWbvuW8gOWFs++8m2ltcGxlbWVudGF0aW9uX2NvbW1pdF9jb3VudD0w';adr='docs/architecture/adr/ADR-P12C-000-multi-agent-work-package.md';plan='docs/execution/evidence/phase-12/P12C-000/task-plan.md';directory='docs/execution/evidence/phase-12c/P12C-000/';ct=@('CT-011');reviewers=@('Eval','Finance','Security')},
  [ordered]@{task_id='TASK-P12D-000';selection='domain_command';prefix='P12D';required_b64='6YCJ5oup5LiA5Liq5YaZ54K55bm26aqM6K+B6Kem5Y+RIOKGkiDorr7orqEgcHJpbmNpcGFsL2FwcHJvdmFsL0NBUy9vdXRib3gg5ZCI5ZCMIOKGkiDorr7orqEgZXhwYW5kLWNvbnRyYWN044CB5YW85a6544CBcmVwbGF5L3Jlc3RvcmUg4oaSIOaLhuWOn+WtkCBUQVNL44CBYWxsb3dsaXN044CB5ZG95Luk5LiO5Zue5ruaIOKGkiDlnKjorqHliJLlj5jmm7TkuK3nmbvorrAgYWNjZXB0YW5jZS9tZXJnZSBJRA==';detail_b64='6K6h5YiS55m76K6w5ZSv5LiAIERvbWFpbiBDb21tYW5kIOWGmeeCueOAgeaOiOadgy9DQVMvcmVjZWlwdC/lm57mu5rku7vliqHvvJtpbXBsZW1lbnRhdGlvbl9jb21taXRfY291bnQ9MA==';adr='docs/architecture/adr/ADR-P12D-000-domain-command-work-package.md';plan='docs/execution/evidence/phase-12/P12D-000/task-plan.md';directory='docs/execution/evidence/phase-12d/P12D-000/';ct=@();reviewers=@('Data','Product','Security')}
)
$P12WorkPackageInputs=@('docs/execution/status/TASK-P12-002.json','docs/execution/evidence/phase-12/P12-002/artifact-hashes.json','docs/execution/evidence/phase-12/P12-002/selection.json','docs/execution/evidence/phase-12/P12-002/selection-verification.json','docs/execution/evidence/phase-12/P12-002.json','docs/execution/evidence/phase-12/P12-000/ref-reservation.json','docs/execution/evidence/phase-12/P12-002/gate-results.json','docs/execution/evidence/phase-12/phase-runtime-manifest.json');$P12WorkPackageAllInputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')+@($P12WorkPackageInputs)
foreach($Case in $P12WorkPackageCases){$Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue $Case.task_id -ModeValue 'Preflight';if(-not[bool]$Registry.registered){throw "negative: fully specialized $($Case.task_id) remains fail-closed"};$DefinitionTask=$Catalog.Tasks[$Case.task_id];$Required=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Case.required_b64));$Targets=@($Case.adr,$Case.plan);$Generated=@('plan-verification.json','work-preflight.json','security-report.json','rollback-report.json','artifact-hashes.json','commands.json','gate-results.json')|ForEach-Object{[string]$Case.directory+$_};$Generated+=('docs/execution/status/'+$Case.task_id+'.json');$Outputs=@($Targets)+@($Generated);if(@($DefinitionTask.work_contract.required_changes).Count-ne1-or[string]$DefinitionTask.work_contract.required_changes[0]-cne$Required-or(@($DefinitionTask.evidence_outputs|Sort-Object)-join',')-cne((@($Outputs|Sort-Object))-join',')-or(@($DefinitionTask.file_allowlist|Sort-Object)-join',')-cne((@($Targets|Sort-Object))-join',')-or(@($DefinitionTask.work_contract.repo_patch_targets|Sort-Object)-join',')-cne((@($Targets|Sort-Object))-join',')-or@($DefinitionTask.directory_allowlist).Count-ne1-or[string]$DefinitionTask.directory_allowlist[0]-cne$Case.directory-or(@($DefinitionTask.read_only_inputs|Sort-Object)-join',')-cne((@($P12WorkPackageAllInputs|Sort-Object))-join',')-or(@($DefinitionTask.reviewer_roles|Sort-Object)-join',')-cne((@($Case.reviewers|Sort-Object))-join',')){throw "negative: $($Case.task_id) Catalog does not exactly bind its dormant work-package contract"}}
foreach($Case in $P12WorkPackageCases){$DefinitionTask=$Catalog.Tasks[$Case.task_id];if([int]$DefinitionTask.approval_policy.minimum_approvals-ne@($Case.reviewers).Count-or(@($DefinitionTask.approval_policy.required_roles|Sort-Object)-join',')-cne((@($Case.reviewers|Sort-Object))-join',')){throw "negative: $($Case.task_id) approval policy does not match every independent reviewer in execplan"}}
foreach($Name in @('Get-P12WorkPackageDefinition','Get-P12WorkPackageDependencyState','Get-P12WorkPackagePlanState','Get-P12WorkPackageBranchState','Get-P12WorkPackageGateModeState','Test-P12WorkPackageTask')){if($RunnerText-cnotmatch[regex]::Escape($Name)){throw "negative: shared P12 work-package runner function is missing: $Name"}}
if($RunnerText-cnotmatch[regex]::Escape('git-object:p12-001:docs/execution/evidence/phase-12/phase-runtime-manifest.json')){throw 'negative: P12 work-package dependency lost the transitive P12-002 manifest artifact binding'}
foreach($ModeName in @('Security','Verify','Evidence','Preflight','WorkPreflight','WorksetVerify','RollbackVerify')){$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$ModeName)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch 'Test-P12WorkPackageTask'){throw "negative: shared P12 work-package specialization is missing in Invoke-Mode$ModeName"}}
$DefinitionFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P12WorkPackageDefinition'},$true);$PlanFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P12WorkPackagePlanState'},$true);if($null-eq$DefinitionFunction-or$null-eq$PlanFunction){throw 'negative: pure P12 work-package validators are unavailable'};Invoke-Expression $DefinitionFunction.Extent.Text;Invoke-Expression $PlanFunction.Extent.Text
foreach($Case in $P12WorkPackageCases){$Def=Get-P12WorkPackageDefinition -TaskIdValue $Case.task_id;if([string]$Def.selection-cne[string]$Case.selection-or[string]$Def.required_change_b64-cne[string]$Case.required_b64-or[string]$Def.detail_b64-cne[string]$Case.detail_b64-or[string]$Def.adr_path-cne[string]$Case.adr-or[string]$Def.plan_path-cne[string]$Case.plan-or[string]$Def.evidence_directory-cne[string]$Case.directory-or(@($Def.applicable_ct_ids)-join',')-cne(@($Case.ct)-join',')){throw "negative: $($Case.task_id) runner definition drifted from its frozen card profile"}}
$P12WpCycle='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';$P12WpHead='1'*40;$P12WpArtifact='2'*64
foreach($Case in $P12WorkPackageCases){$Def=Get-P12WorkPackageDefinition -TaskIdValue $Case.task_id;$CtText=if(@($Def.applicable_ct_ids).Count){@($Def.applicable_ct_ids)-join','}else{'none'};$Markers=@($Def.required_markers)-join"`n";$Plan="# Task plan`nTask: $($Case.task_id)`nCycle: $P12WpCycle`nP12-002 head: $P12WpHead`nP12-002 artifact: $P12WpArtifact`nSelection: $($Case.selection)`nImplementation commit count: 0`nContract change: false`nAtomic task: TASK-$($Case.prefix)-001`nAcceptance task: TASK-$($Case.prefix)-990`nMerge task: TASK-$($Case.prefix)-999`nApplicable CT: $CtText`n$Markers";$Adr="# Work package`n## Trigger Evidence`n## Atomic Tasks`n## Security and Privacy`n## Reliability`n## Acceptance and Merge`n## Rollback`n$Markers";$Dep=[pscustomobject]@{passed=$true;cycle_id=$P12WpCycle;p12_002_head_sha=$P12WpHead;artifact_sha256=$P12WpArtifact;selection=$Case.selection};$Positive=Get-P12WorkPackagePlanState -Definition $Def -PlanText $Plan -AdrText $Adr -Dependency $Dep;if(-not[bool]$Positive.passed){throw "positive: $($Case.task_id) rejected a complete dormant work package"};$BadSelection=$Plan.Replace("Selection: $($Case.selection)",'Selection: none');if([bool](Get-P12WorkPackagePlanState -Definition $Def -PlanText $BadSelection -AdrText $Adr -Dependency $Dep).passed){throw "negative: $($Case.task_id) accepted a mismatched XOR selection"};$Implementation=$Plan.Replace('Implementation commit count: 0','Implementation commit count: 1');if([bool](Get-P12WorkPackagePlanState -Definition $Def -PlanText $Implementation -AdrText $Adr -Dependency $Dep).passed){throw "negative: $($Case.task_id) accepted an implementation commit in planning"};$MissingMarker=$Plan.Replace([string]$Def.required_markers[0],'marker-removed');if([bool](Get-P12WorkPackagePlanState -Definition $Def -PlanText $MissingMarker -AdrText $Adr -Dependency $Dep).passed){throw "negative: $($Case.task_id) accepted a missing capability guardrail"}}
$P12089Task=$Catalog.Tasks['TASK-P12-089'];$P12089Required=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5oyJ5a6e6ZmFIGRpZmYg5pu05pawIFJFQURNRS5tZOOAgWRvY3MvYXJjaGl0ZWN0dXJlL3JlbGVhc2UtYy1zZWxlY3Rpb24ubWTjgIFkb2NzL3J1bmJvb2tzL3JlbGVhc2UtYy1nb3Zlcm5hbmNlLm1k44CBZG9jcy9hcGkvcmVsZWFzZS1jLXNlbGVjdGlvbi5tZOOAgXRocmVhdC1tb2RlbCByZXZpZXcgcmVjZWlwdO+8iOWQqyBtb2RlbCBoYXNo44CBY2FuZGlkYXRlIGhlYWTjgIFTZWN1cml0eSBvd25lcu+8m+aXoOWPmOWMluWGmSBtb2RlbF9jaGFuZ2VkPWZhbHNl77yJ44CBY2hhbmdlLXN1bW1hcnnjgIFrbm93bGVkZ2UtdHJhbnNmZXLjgIFTVEFSL04vQSDlkowgcHJlbWVyZ2UgbWFuaWZlc3Q='))
$P12089Files=@('README.md','docs/architecture/release-c-selection.md','docs/runbooks/release-c-governance.md','docs/api/release-c-selection.md','docs/architecture/threat-model/phase-12-review.json','docs/execution/evidence/phase-12/change-summary.md','docs/execution/evidence/phase-12/knowledge-transfer.md','docs/execution/evidence/phase-12/star-records.md','docs/execution/evidence/phase-12/artifact-manifest.premerge.json','docs/execution/schemas/harness-test-catalog.yaml','docs/execution/status/task-board.json','docs/execution/status/task-board.md')
$P12089PackageInputs=@();foreach($Case in $P12WorkPackageCases){$P12089PackageInputs+=@("docs/execution/status/$($Case.task_id).json","$($Case.directory)artifact-hashes.json","$($Case.directory)plan-verification.json","$($Case.directory)gate-results.json",[string]$Case.adr,[string]$Case.plan)};$P12089Inputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')+$P12WorkPackageInputs+$P12089PackageInputs
$P12089Outputs=@('docs/architecture/threat-model/phase-12-review.json','docs/execution/evidence/phase-12/change-summary.md','docs/execution/evidence/phase-12/knowledge-transfer.md','docs/execution/evidence/phase-12/star-records.md','docs/execution/evidence/phase-12/artifact-manifest.premerge.json','docs/execution/evidence/phase-12/P12-089/artifact-hashes.json','docs/execution/evidence/phase-12/P12-089/commands.json','docs/execution/evidence/phase-12/P12-089/gate-results.json','docs/execution/evidence/phase-12/P12-089/handoff-verification.json','docs/execution/evidence/phase-12/P12-089/harness-catalog-aggregate.json','docs/execution/schemas/harness-test-catalog.yaml','docs/execution/status/task-board.json','docs/execution/status/task-board.md','docs/execution/status/TASK-P12-089.json')
if($null-eq$P12089Task-or(@($P12089Task.prerequisite_task_ids)-join',')-cne'TASK-P12-002'-or@($P12089Task.work_contract.required_changes).Count-ne1-or[string]$P12089Task.work_contract.required_changes[0]-cne$P12089Required-or(@($P12089Task.file_allowlist|Sort-Object)-join',')-cne((@($P12089Files|Sort-Object))-join',')-or(@($P12089Task.work_contract.repo_patch_targets|Sort-Object)-join',')-cne((@($P12089Files|Sort-Object))-join',')-or(@($P12089Task.read_only_inputs|Sort-Object)-join',')-cne((@($P12089Inputs|Sort-Object))-join',')-or(@($P12089Task.evidence_outputs|Sort-Object)-join',')-cne((@($P12089Outputs|Sort-Object))-join',')-or(@($P12089Task.directory_allowlist)-join',')-cne'docs/execution/evidence/phase-12/improvements/'){throw 'negative: P12-089 Catalog does not exactly bind its dynamic XOR convergence documentation contract'}
$P12089Modes=@('Documentation','Evidence','HandoffVerification','HarnessCatalogAggregate','Preflight','RollbackVerify','Security','StatusBoardAggregate','WorkPreflight','WorksetVerify');if((@($P12089Task.allowed_taskgate_modes|Sort-Object)-join',')-cne((@($P12089Modes|Sort-Object))-join',')){throw 'negative: P12-089 mode set drifted from execplan'}
foreach($ModeName in $P12089Modes){$Registry=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P12-089' -ModeValue $ModeName;if(-not[bool]$Registry.registered){throw "negative: P12-089 mode is not registered: $ModeName"};$HandlerAst=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq("Invoke-Mode"+$ModeName)},$true);if($null-eq$HandlerAst-or$HandlerAst.Extent.Text-cnotmatch "if \(\`$TaskId -ceq 'TASK-P12-089'\) \{"){throw "negative: P12-089 specialization is missing in Invoke-Mode$ModeName"}}
foreach($Name in @('Get-P12089DependencyState','Get-P12089ConvergenceState','Get-P12089WorkPackageState','Get-P12089BranchState','Get-P12089GateModeState','Test-P12089PathAllowed','New-ArtifactHashesDocument')){if($RunnerText-cnotmatch[regex]::Escape($Name)){throw "negative: P12-089 convergence helper is missing: $Name"}}
$ConvergenceFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P12089ConvergenceState'},$true);if($null-eq$ConvergenceFunction){throw 'negative: P12-089 pure convergence validator is unavailable'};Invoke-Expression $ConvergenceFunction.Extent.Text
function New-P12089States {$States=[ordered]@{};foreach($Case in $P12WorkPackageCases){$States[$Case.task_id]=[pscustomobject]@{present_count=0;accepted=$false;passed=$false}};return $States}
$NoneBase=[pscustomobject]@{passed=$true;selection='none';selected_count=0};$NoneStates=New-P12089States;$NoneResult=Get-P12089ConvergenceState -BaseDependency $NoneBase -WorkPackageStates $NoneStates;if(-not[bool]$NoneResult.passed-or[int]$NoneResult.checks.accepted_work_package_count-ne0){throw 'positive: P12-089 rejected the accepted none/zero convergence shape'}
$MultiBase=[pscustomobject]@{passed=$true;selection='multi_agent';selected_count=1};$MultiStates=New-P12089States;$MultiStates['TASK-P12C-000']=[pscustomobject]@{present_count=4;accepted=$true;passed=$true};$MultiResult=Get-P12089ConvergenceState -BaseDependency $MultiBase -WorkPackageStates $MultiStates;if(-not[bool]$MultiResult.passed-or[string]$MultiResult.selected_task_id-cne'TASK-P12C-000'){throw 'positive: P12-089 rejected exactly one accepted matching multi-agent work package'}
$MissingSelected=New-P12089States;if([bool](Get-P12089ConvergenceState -BaseDependency $MultiBase -WorkPackageStates $MissingSelected).passed){throw 'negative: P12-089 accepted a selected capability without its accepted work package'}
$WrongSelected=New-P12089States;$WrongSelected['TASK-P12B-000']=[pscustomobject]@{present_count=4;accepted=$true;passed=$true};if([bool](Get-P12089ConvergenceState -BaseDependency $MultiBase -WorkPackageStates $WrongSelected).passed){throw 'negative: P12-089 accepted a work package that does not match the XOR selection'}
$TwoSelected=New-P12089States;$TwoSelected['TASK-P12C-000']=[pscustomobject]@{present_count=4;accepted=$true;passed=$true};$TwoSelected['TASK-P12B-000']=[pscustomobject]@{present_count=4;accepted=$true;passed=$true};if([bool](Get-P12089ConvergenceState -BaseDependency $MultiBase -WorkPackageStates $TwoSelected).passed){throw 'negative: P12-089 accepted two work packages'}
$NoneMaterialized=New-P12089States;$NoneMaterialized['TASK-P12A-000']=[pscustomobject]@{present_count=1;accepted=$false;passed=$false};if([bool](Get-P12089ConvergenceState -BaseDependency $NoneBase -WorkPackageStates $NoneMaterialized).passed){throw 'negative: P12-089 accepted dormant package materialization under none'}
$BadCount=$MultiBase.PSObject.Copy();$BadCount.selected_count=0;if([bool](Get-P12089ConvergenceState -BaseDependency $BadCount -WorkPackageStates $MultiStates).passed){throw 'negative: P12-089 accepted a selection record count mismatch'}
$BadBranch=[pscustomobject]@{passed=$false;specialist_branch_count=1;specialist_worktree_count=0};if([bool](Get-P12089ConvergenceState -BaseDependency $MultiBase -WorkPackageStates $MultiStates -BranchState $BadBranch).passed){throw 'negative: P12-089 accepted a materialized specialist branch'}
$P12089Preflight=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Invoke-ModePreflight'},$true);$P12089PreflightText=$P12089Preflight.Extent.Text;if($P12089PreflightText-cmatch'\$Checks\.Values\|Where-Object\{\$_-is\[int\]\}'-or$P12089PreflightText-cnotmatch'\$Checks\.dependency_failures\+\[int\]\$Checks\.prior_phase_regression_failures\+\[int\]\$Checks\.unexpected_paths\+\[int\]\$Checks\.base_drift\+\[int\]\$Checks\.specialist_branch_count\+\[int\]\$Checks\.specialist_worktree_count'){throw 'negative: P12-089 Preflight treats valid selected-count telemetry as a failure'}
$P12DependencyFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-P12WorkPackageDependencyState'},$true);if($null-eq$P12DependencyFunction-or$P12DependencyFunction.Extent.Text-cnotmatch'p12_002_status_head_ancestor'-or$P12DependencyFunction.Extent.Text-cmatch'\[string\]\$Status\.head_oid-ceq\$Head'){throw 'negative: P12 accepted dependencies must use an ancestor relation instead of an impossible self-referential status HEAD equality'}
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

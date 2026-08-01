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
    $RunnerText -notmatch 'pending_p10_009_approved_production_rollout_observation' -or
    $RunnerText -notmatch 'stop_rule_bypass_count' -or
    $RunnerText -notmatch 'timer_restarted_on_transition' -or
    $RunnerText -notmatch 'p10_009_security_failed' -or
    $RunnerText -notmatch 'p10_009_workset_failed' -or
    $RunnerText -notmatch 'p10_009_evidence_failed' -or
    $RunnerText -notmatch 'p10_009_rollback_verification_failed') {
  throw 'negative: P10-009 must fail closed on unavailable production rollout observations while retaining security, evidence, workset, and old-route rollback gates'
}
$RolloutContractPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path 'docs/execution/evidence/phase-10/P10-007/rollout-cohorts.yaml'
$RolloutContractText = Get-Content -LiteralPath $RolloutContractPath -Raw -Encoding UTF8
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
  throw 'negative: Release B gates must bind explicit non-overlapping timestamps and at least 744 total observed hours from P10-007 through P10-009, P10-010, P10-990, and P10-011'
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
$ConditionalRegistryFunction=$RunnerAst.Find({param($Node)$Node-is[Management.Automation.Language.FunctionDefinitionAst]-and$Node.Name-ceq'Get-ConditionalTaskRunnerRegistryState'},$true)
if($null-eq$ConditionalRegistryFunction-or$RunnerText-cnotmatch 'conditional_task_runner_unimplemented'){throw 'negative: conditional Release C tasks must fail closed before a specialized runner is registered'}
Invoke-Expression $ConditionalRegistryFunction.Extent.Text
$ConditionalTaskIds=@($Catalog.Tasks.Keys|Where-Object{$_-cmatch'^TASK-(?:P11|P12(?:[A-D])?|REL-C-)'}|Sort-Object)
if($ConditionalTaskIds.Count-ne24){throw "positive: expected 24 conditional Release C task cards, observed $($ConditionalTaskIds.Count)"}
$RegisteredConditionalTasks=@($ConditionalTaskIds|Where-Object{[bool](Get-ConditionalTaskRunnerRegistryState -TaskIdValue $_ -ModeValue 'Preflight').registered})
if(($RegisteredConditionalTasks-join',')-cne'TASK-REL-C-000'){throw 'negative: an unimplemented Phase 11/12/Release C task remains eligible for generic runner success'}
$UnimplementedConditionalTasks=@($ConditionalTaskIds|Where-Object{-not[bool](Get-ConditionalTaskRunnerRegistryState -TaskIdValue $_ -ModeValue 'Preflight').registered})
if($UnimplementedConditionalTasks.Count-ne23){throw 'negative: conditional runner coverage inventory is incomplete'}
$NonConditionalState=Get-ConditionalTaskRunnerRegistryState -TaskIdValue 'TASK-P10-011' -ModeValue 'Preflight'
if([bool]$NonConditionalState.required-or-not[bool]$NonConditionalState.registered){throw 'negative: the conditional runner guard shadowed an already implemented non-conditional task'}
$ConditionalGuardIndex=$RunnerText.IndexOf('$ConditionalRunnerState=Get-ConditionalTaskRunnerRegistryState',[StringComparison]::Ordinal)
$EvidenceDirectoryIndex=$RunnerText.LastIndexOf('$TaskEvidenceDirectory = Get-TaskEvidenceDirectory',[StringComparison]::Ordinal)
if($ConditionalGuardIndex-lt0-or$EvidenceDirectoryIndex-lt0-or$ConditionalGuardIndex-gt$EvidenceDirectoryIndex){throw 'negative: the conditional runner guard must reject before evidence/status directories are materialized'}
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

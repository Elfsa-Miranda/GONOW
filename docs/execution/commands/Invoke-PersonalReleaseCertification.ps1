[CmdletBinding()]
param(
  [ValidateSet('ReleaseBDeep')][string]$Profile = 'ReleaseBDeep',
  [string]$EvidenceRoot = '.\docs\execution\evidence\phase-10\P10-009',
  [string]$CandidateHeadOid = '',
  [ValidateSet('none','regression','c1','c2','c2-live','c3','c4-fast','c4-soak','c4','c5-observe','c5','all-ready')]
  [string]$ExecuteShard = 'none',
  [string]$PythonExecutable = '',
  [string]$FlutterExecutable = '',
  [string]$DatabaseUrl = 'postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test',
  [switch]$SelfTest,
  [ValidateSet('none','c1_state_count','c2_live_boundary','c2_redline','c3_slice_size','c4_soak','c5_rollback','candidate_drift','enterprise_substitution')]
  [string]$SelfTestFailure = 'none'
)

$ErrorActionPreference = 'Stop'
$StartedAt = [DateTimeOffset]::Now
$ScriptDirectory = Split-Path -Parent $PSCommandPath
$ConfigPath = Join-Path $ScriptDirectory 'PersonalReleaseCertification.psd1'
$AdoptionPath = Join-Path (Split-Path -Parent $ScriptDirectory) 'evidence\governance\personal-automation-adoption-v1.json'

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Write-AtomicJson {
  param([Parameter(Mandatory = $true)][string]$LiteralPath,[Parameter(Mandatory = $true)][object]$Value)
  $Parent = Split-Path -Parent $LiteralPath
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }
  $Temporary = Join-Path $Parent ('.' + [IO.Path]::GetFileName($LiteralPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($Temporary, (($Value | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $Temporary -Destination $LiteralPath -Force
  } finally {
    if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
  }
}

function Resolve-RepositoryRoot {
  $Root = (& git -C $ScriptDirectory rev-parse --show-toplevel 2>$null).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Root)) { throw 'certification_repository_root_unavailable' }
  return $Root
}

function Add-Failure {
  param([System.Collections.Generic.List[string]]$Failures,[string]$Code,[bool]$Condition)
  if (-not $Condition) { $Failures.Add($Code) }
}

function Test-CommonReport {
  param([object]$Report,[string]$GateId,[string]$ExpectedCandidate)
  $Failures = [Collections.Generic.List[string]]::new()
  Add-Failure $Failures 'report_missing' ($null -ne $Report)
  if ($null -eq $Report) { return $Failures }
  Add-Failure $Failures 'schema_version_invalid' ([string]$Report.schema_version -ceq '1.0')
  Add-Failure $Failures 'gate_id_invalid' ([string]$Report.gate_id -ceq $GateId)
  Add-Failure $Failures 'governance_profile_invalid' ([string]$Report.governance_profile -ceq 'personal_automated')
  Add-Failure $Failures 'candidate_oid_mismatch' ([string]$Report.candidate_head_oid -ceq $ExpectedCandidate)
  Add-Failure $Failures 'gate_status_not_passed' ([string]$Report.status -ceq 'passed')
  foreach ($Name in @('mandatory_skip_count','xfail_count','flaky_rerun_count','production_write_count','redline_failure_count')) {
    Add-Failure $Failures ($Name + '_nonzero') ([int]$Report.$Name -eq 0)
  }
  return $Failures
}

function Test-GateReport {
  param([object]$Report,[string]$GateId,[string]$ExpectedCandidate,[hashtable]$Thresholds)
  $Failures = [Collections.Generic.List[string]]::new()
  foreach ($Failure in @(Test-CommonReport -Report $Report -GateId $GateId -ExpectedCandidate $ExpectedCandidate)) {
    $Failures.Add([string]$Failure)
  }
  if ($null -eq $Report) { return $Failures }
  $M = $Report.metrics
  Add-Failure $Failures 'metrics_missing' ($null -ne $M)
  if ($null -eq $M) { return $Failures }
  switch ($GateId) {
    'C1' {
      Add-Failure $Failures 'e0_case_count_below_minimum' ([int]$M.e0_case_count -ge [int]$Thresholds.minimum_e0_cases)
      Add-Failure $Failures 'state_sequence_count_below_minimum' ([long]$M.state_sequence_count -ge [long]$Thresholds.minimum_state_sequences)
      Add-Failure $Failures 'mandatory_pass_rate_not_one' ([double]$M.mandatory_pass_rate -eq 1.0)
      Add-Failure $Failures 'hard_invariant_pass_rate_not_one' ([double]$M.hard_invariant_pass_rate -eq 1.0)
      Add-Failure $Failures 'success_rate_lower_bound_below_minimum' ([double]$M.success_rate_lower_95 -ge [double]$Thresholds.minimum_success_rate_lower_95)
    }
    'C2' {
      Add-Failure $Failures 'real_postgresql_missing' ([bool]$M.real_postgresql)
      Add-Failure $Failures 'live_provider_missing' ([bool]$M.live_provider)
      Add-Failure $Failures 'security_attempt_count_below_minimum' ([long]$M.generated_security_attempt_count -ge [long]$Thresholds.minimum_generated_security_attempts)
      Add-Failure $Failures 'local_complete_run_count_below_minimum' ([long]$M.local_complete_run_count -ge [long]$Thresholds.minimum_local_complete_runs)
      Add-Failure $Failures 'live_route_call_count_below_minimum' ([int]$M.minimum_live_calls_per_route -ge [int]$Thresholds.minimum_live_calls_per_route)
      Add-Failure $Failures 'critical_mutation_kill_rate_below_minimum' ([double]$M.critical_mutation_kill_rate -ge [double]$Thresholds.minimum_critical_mutation_kill_rate)
      Add-Failure $Failures 'changed_mutation_kill_rate_below_minimum' ([double]$M.changed_mutation_kill_rate -ge [double]$Thresholds.minimum_changed_mutation_kill_rate)
      Add-Failure $Failures 'api_p95_upper_above_maximum' ([double]$M.api_p95_upper_ms -le [double]$Thresholds.maximum_api_p95_upper_ms)
      Add-Failure $Failures 'cost_to_budget_ratio_above_maximum' ([double]$M.cost_to_budget_ratio_upper -le [double]$Thresholds.maximum_cost_to_budget_ratio)
      Add-Failure $Failures 'p95_cost_increase_above_maximum' ([double]$M.p95_cost_increase_upper -le [double]$Thresholds.maximum_p95_cost_increase_upper)
      foreach ($Name in @('cross_tenant_leak_count','unauthorized_write_count','secret_or_pii_leak_count','forbidden_tool_execution_count','missing_audit_receipt_count','arbitrary_sql_executor_count')) {
        Add-Failure $Failures ($Name + '_nonzero') ([int]$M.$Name -eq 0)
      }
    }
    'C3' {
      Add-Failure $Failures 'e1_case_count_below_minimum' ([int]$M.e1_case_count -ge [int]$Thresholds.minimum_e1_cases)
      Add-Failure $Failures 'critical_slice_count_below_minimum' ([int]$M.minimum_cases_per_critical_slice -ge [int]$Thresholds.minimum_cases_per_critical_slice)
      Add-Failure $Failures 'noninferiority_regression_above_maximum' ([double]$M.maximum_noninferiority_regression_upper -le [double]$Thresholds.maximum_noninferiority_regression_upper)
      Add-Failure $Failures 'holm_correction_missing' ([bool]$M.holm_correction_applied)
      Add-Failure $Failures 'hard_constraint_pass_rate_not_one' ([double]$M.hard_constraint_pass_rate -eq 1.0)
      Add-Failure $Failures 'metamorphic_failure_nonzero' ([int]$M.metamorphic_failure_count -eq 0)
    }
    'C4' {
      Add-Failure $Failures 'killpoint_schedule_count_below_minimum' ([int]$M.minimum_schedules_per_killpoint_outcome -ge [int]$Thresholds.minimum_schedules_per_killpoint_outcome)
      Add-Failure $Failures 'virtual_days_below_minimum' ([int]$M.virtual_days -ge [int]$Thresholds.minimum_virtual_days)
      Add-Failure $Failures 'fake_provider_lifecycle_count_below_minimum' ([long]$M.fake_provider_lifecycle_count -ge [long]$Thresholds.minimum_fake_provider_lifecycles)
      Add-Failure $Failures 'real_soak_seconds_below_minimum' ([long]$M.real_soak_seconds -ge [long]$Thresholds.minimum_real_soak_seconds)
      Add-Failure $Failures 'judge_annotation_count_below_minimum' ([int]$M.judge_annotation_count -ge [int]$Thresholds.minimum_judge_annotations)
      Add-Failure $Failures 'judge_slice_count_below_minimum' ([int]$M.minimum_judge_primary_slice_annotations -ge [int]$Thresholds.minimum_judge_primary_slice_annotations)
      Add-Failure $Failures 'judge_gap_above_maximum' ([double]$M.judge_mechanical_gap_pp -le [double]$Thresholds.maximum_judge_mechanical_gap_pp)
      Add-Failure $Failures 'duplicate_side_effect_nonzero' ([int]$M.duplicate_formal_side_effect_count -eq 0)
      Add-Failure $Failures 'permanent_run_nonzero' ([int]$M.permanent_run_count -eq 0)
      Add-Failure $Failures 'positive_resource_slope_nonzero' ([int]$M.positive_resource_slope_count -eq 0)
      Add-Failure $Failures 'resource_return_to_baseline_failed' ([bool]$M.resource_returned_to_baseline)
    }
    'C5' {
      Add-Failure $Failures 'fault_class_count_below_minimum' ([int]$M.fault_class_count -ge [int]$Thresholds.minimum_fault_classes)
      Add-Failure $Failures 'kill_switch_above_maximum' ([double]$M.kill_switch_seconds -le [double]$Thresholds.maximum_kill_switch_seconds)
      Add-Failure $Failures 'new_run_after_kill_nonzero' ([int]$M.new_run_after_kill_count -eq 0)
      Add-Failure $Failures 'old_path_success_rate_not_one' ([double]$M.old_path_success_rate -eq 1.0)
      Add-Failure $Failures 'data_loss_nonzero' ([int]$M.data_loss_count -eq 0)
      Add-Failure $Failures 'duplicate_write_nonzero' ([int]$M.duplicate_write_count -eq 0)
      Add-Failure $Failures 'rollback_not_passed' ([bool]$M.rollback_passed)
      Add-Failure $Failures 'runbook_failure_nonzero' ([int]$M.runbook_failure_count -eq 0)
    }
  }
  return $Failures
}

function Test-ExecutableSourceEvidence {
  param([object]$Report,[string]$GateId,[string]$Root)
  $Failures = [Collections.Generic.List[string]]::new()
  if ($null -eq $Report) { return $Failures }
  function Read-Source([string]$Name) {
    $Path = Join-Path $Root $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  }
  $M = $Report.metrics
  switch ($GateId) {
    'C1' {
      $Regression = Read-Source 'regression-report.json'
      $State = Read-Source 'state-space-report.json'
      $E0 = Read-Source 'c1-e0-expanded.json'
      Add-Failure $Failures 'c1_regression_not_passed' ($null-ne$Regression -and [string]$Regression.status-ceq'passed' -and [int]$Regression.failure_count-eq0 -and [int]$Regression.mandatory_skip_count-eq0)
      Add-Failure $Failures 'c1_state_source_mismatch' ($null-ne$State -and [long]$State.sequence_count-eq[long]$M.state_sequence_count -and [int]$State.failure_count-eq0 -and [double]$State.hard_invariant_pass_rate-eq1.0)
      Add-Failure $Failures 'c1_e0_source_mismatch' ($null-ne$E0 -and [int]$E0.case_count-eq[int]$M.e0_case_count -and [int]$E0.unique_input_count-ge160 -and [int]$E0.failure_count-eq0)
    }
    'C2' {
      $Security = Read-Source 'security-matrix.json'
      $Performance = Read-Source 'performance-cost-report.json'
      $Load = Read-Source 'c2-postgresql-load.json'
      $Live = Read-Source 'live-provider-receipts.json'
      $Pricing = Read-Source 'pricing-snapshot.json'
      Add-Failure $Failures 'c2_security_source_mismatch' ($null-ne$Security -and [long]$Security.generated_security_attempt_count-eq[long]$M.generated_security_attempt_count -and [int]$Security.failure_count-eq0 -and [double]$Security.critical_mutation_kill_rate-eq[double]$M.critical_mutation_kill_rate)
      Add-Failure $Failures 'c2_postgresql_source_mismatch' ($null-ne$Load -and [int]$Load.local_complete_run_count-eq[int]$M.local_complete_run_count -and [int]$Load.terminal_failure_count-eq0 -and [int]$Load.rls_cross_tenant_leak_count-eq0)
      Add-Failure $Failures 'c2_performance_source_mismatch' ($null-ne$Performance -and [double]$Performance.api_p95_upper_ms-eq[double]$M.api_p95_upper_ms -and [bool]$Performance.real_postgresql -and [bool]$Performance.live_provider)
      Add-Failure $Failures 'c2_live_source_mismatch' ($null-ne$Live -and [string]$Live.status-ceq'passed' -and [string]$Live.executor-ceq'repository_owned_gemini_live_v1' -and [string]$Live.candidate_head_oid-ceq[string]$Report.candidate_head_oid -and [int]$Live.successful_call_count-ge400 -and [int]$Live.secret_or_pii_leak_count-eq0 -and [int]$Live.request_body_record_count-eq0 -and [int]$Live.response_body_record_count-eq0 -and [int]$Live.production_write_count-eq0)
      Add-Failure $Failures 'c2_pricing_source_mismatch' ($null-ne$Pricing -and [string]$Live.pricing_snapshot_sha256-ceq(Get-Sha256 -LiteralPath (Join-Path $Root 'pricing-snapshot.json')) -and [string]$Pricing.provider_id-ceq[string]$Live.provider_id)
    }
    'C3' {
      $Quality = Read-Source 'quality-slice-report.json'
      Add-Failure $Failures 'c3_quality_source_mismatch' ($null-ne$Quality -and [int]$Quality.generated_case_count-eq[int]$M.e1_case_count -and [int]$Quality.minimum_cases_per_critical_slice-eq[int]$M.minimum_cases_per_critical_slice -and @($Quality.slices).Count-ge11 -and [int]$Quality.failure_count-eq0)
    }
    'C4' {
      $Fault = Read-Source 'fault-injection-report.json'
      $Virtual = Read-Source 'virtual-time-report.json'
      $Soak = Read-Source 'soak-report.json'
      $Samples = Read-Source 'soak-samples.json'
      $Judge = Read-Source 'c4-judge-calibration.json'
      Add-Failure $Failures 'c4_fault_source_mismatch' ($null-ne$Fault -and [int]$Fault.minimum_schedules_per_killpoint_outcome-eq[int]$M.minimum_schedules_per_killpoint_outcome -and [int]$Fault.schedule_count-ge420 -and [int]$Fault.stale_worker_denial_failure_count-eq0)
      Add-Failure $Failures 'c4_virtual_source_mismatch' ($null-ne$Virtual -and [int]$Virtual.virtual_days-eq[int]$M.virtual_days -and [long]$Virtual.fake_provider_lifecycle_count-eq[long]$M.fake_provider_lifecycle_count -and [int]$Virtual.boundary_failure_count-eq0)
      Add-Failure $Failures 'c4_judge_source_mismatch' ($null-ne$Judge -and [int]$Judge.annotation_count-eq[int]$M.judge_annotation_count -and [int]$Judge.minimum_primary_slice_annotations-eq[int]$M.minimum_judge_primary_slice_annotations)
      if ($null-ne$Soak) {
        $SamplesPath=Join-Path $Root 'soak-samples.json'
        Add-Failure $Failures 'c4_soak_sample_binding_invalid' ($null-ne$Samples -and [string]$Soak.samples_path-ceq'soak-samples.json' -and [string]$Soak.samples_artifact_sha256-ceq(Get-Sha256 -LiteralPath $SamplesPath) -and @($Samples.samples).Count-eq[int]$Soak.sample_count)
        $Previous=-1.0;$Monotonic=$true
        foreach($Sample in @($Samples.samples)){if([double]$Sample.elapsed_seconds-lt$Previous){$Monotonic=$false};$Previous=[double]$Sample.elapsed_seconds}
        Add-Failure $Failures 'c4_soak_samples_not_monotonic' $Monotonic
        Add-Failure $Failures 'c4_soak_source_mismatch' ([double]$Soak.real_soak_seconds-eq[double]$M.real_soak_seconds -and [string]$Soak.status-ceq'passed' -and [int]$Soak.failure_count-eq0)
      }
    }
    'C5' {
      $Operations = Read-Source 'rollback-operations-report.json'
      Add-Failure $Failures 'c5_operations_source_mismatch' ($null-ne$Operations -and [int]$Operations.fault_class_count-eq[int]$M.fault_class_count -and [int]$Operations.fault_failure_count-eq0 -and [int]$Operations.traceability_failure_count-eq0 -and [double]$Operations.observation_seconds-ge300 -and [bool]$Operations.rollback_passed)
    }
  }
  return $Failures
}

function New-SelfTestReport {
  param([string]$GateId,[string]$Candidate,[string]$Failure,[object[]]$SourceArtifacts)
  $Metrics = switch ($GateId) {
    'C1' { [ordered]@{e0_case_count=200;state_sequence_count=50000;mandatory_pass_rate=1.0;hard_invariant_pass_rate=1.0;success_rate_lower_95=0.90} }
    'C2' { [ordered]@{real_postgresql=$true;live_provider=$true;generated_security_attempt_count=100000;local_complete_run_count=10000;minimum_live_calls_per_route=200;critical_mutation_kill_rate=1.0;changed_mutation_kill_rate=0.90;api_p95_upper_ms=800;cost_to_budget_ratio_upper=1.20;p95_cost_increase_upper=0.15;cross_tenant_leak_count=0;unauthorized_write_count=0;secret_or_pii_leak_count=0;forbidden_tool_execution_count=0;missing_audit_receipt_count=0;arbitrary_sql_executor_count=0} }
    'C3' { [ordered]@{e1_case_count=1000;minimum_cases_per_critical_slice=200;maximum_noninferiority_regression_upper=0.01;holm_correction_applied=$true;hard_constraint_pass_rate=1.0;metamorphic_failure_count=0} }
    'C4' { [ordered]@{minimum_schedules_per_killpoint_outcome=20;virtual_days=90;fake_provider_lifecycle_count=100000;real_soak_seconds=14400;judge_annotation_count=400;minimum_judge_primary_slice_annotations=50;judge_mechanical_gap_pp=5;duplicate_formal_side_effect_count=0;permanent_run_count=0;positive_resource_slope_count=0;resource_returned_to_baseline=$true} }
    'C5' { [ordered]@{fault_class_count=20;kill_switch_seconds=30;new_run_after_kill_count=0;old_path_success_rate=1.0;data_loss_count=0;duplicate_write_count=0;rollback_passed=$true;runbook_failure_count=0} }
  }
  if ($Failure -ceq 'c1_state_count' -and $GateId -ceq 'C1') { $Metrics.state_sequence_count = 49999 }
  if ($Failure -ceq 'c2_live_boundary' -and $GateId -ceq 'C2') { $Metrics.live_provider = $false }
  if ($Failure -ceq 'c2_redline' -and $GateId -ceq 'C2') { $Metrics.cross_tenant_leak_count = 1 }
  if ($Failure -ceq 'c3_slice_size' -and $GateId -ceq 'C3') { $Metrics.minimum_cases_per_critical_slice = 199 }
  if ($Failure -ceq 'c4_soak' -and $GateId -ceq 'C4') { $Metrics.real_soak_seconds = 14399 }
  if ($Failure -ceq 'c5_rollback' -and $GateId -ceq 'C5') { $Metrics.rollback_passed = $false }
  return [ordered]@{
    schema_version='1.0';gate_id=$GateId;governance_profile=if($Failure-ceq'enterprise_substitution'){'enterprise_governed'}else{'personal_automated'}
    candidate_head_oid=if($Failure-ceq'candidate_drift'-and$GateId-ceq'C3'){'f' * 40}else{$Candidate}
    status='passed';mandatory_skip_count=0;xfail_count=0;flaky_rerun_count=0;production_write_count=0;redline_failure_count=0;source_artifacts=$SourceArtifacts;metrics=$Metrics
  }
}

$RepositoryRoot = Resolve-RepositoryRoot
$Config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$ProfileConfig = $Config.Profiles[$Profile]
if ($null -eq $ProfileConfig) { throw 'certification_profile_missing' }
$Candidate = if ([string]::IsNullOrWhiteSpace($CandidateHeadOid)) { (& git -C $RepositoryRoot rev-parse HEAD).Trim() } else { $CandidateHeadOid }
if ($Candidate -cnotmatch '^([a-f0-9]{40}|[a-f0-9]{64})$') { throw 'certification_candidate_oid_invalid' }
$ObjectFormat = (& git -C $RepositoryRoot rev-parse --show-object-format).Trim()
$ResolvedEvidenceRoot = if ($SelfTest) {
  [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ('gonow-personal-certification-selftest-' + [Guid]::NewGuid().ToString('N'))))
} elseif ([IO.Path]::IsPathRooted($EvidenceRoot)) {
  [IO.Path]::GetFullPath($EvidenceRoot)
} else {
  [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $EvidenceRoot))
}
if (-not $SelfTest) {
  if (-not (Test-Path -LiteralPath $AdoptionPath -PathType Leaf)) { throw 'personal_governance_adoption_missing' }
  $Adoption = Get-Content -LiteralPath $AdoptionPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  if ([string]$Adoption.profile -cne 'personal_automated' -or [string]$Adoption.status -cne 'adopted_by_repository_owner_directive') { throw 'personal_governance_adoption_invalid' }
}

$ConfigHash = Get-Sha256 -LiteralPath $ConfigPath
$RunnerHash = Get-Sha256 -LiteralPath $PSCommandPath
$ManifestPath = Join-Path $ResolvedEvidenceRoot 'certification-manifest.json'
$Manifest = [ordered]@{
  schema_version='1.0';task_id=[string]$ProfileConfig.TaskId;profile=$Profile;governance_profile='personal_automated'
  candidate_head_oid=$Candidate;git_object_format=$ObjectFormat;ordered_gates=@($ProfileConfig.OrderedGates)
  config_sha256=$ConfigHash;runner_sha256=$RunnerHash;maximum_wall_clock_seconds=[int]$ProfileConfig.MaximumWallClockSeconds
  minimum_real_soak_seconds=[int]$ProfileConfig.MinimumRealSoakSeconds;production_observation_required=$false
  automated_gate_acceptance=$true;evidence_type=[string]$ProfileConfig.EvidenceType
  supporting_reports=[ordered]@{C1=@($ProfileConfig.SupportingReports.C1);C2=@($ProfileConfig.SupportingReports.C2);C3=@($ProfileConfig.SupportingReports.C3);C4=@($ProfileConfig.SupportingReports.C4);C5=@($ProfileConfig.SupportingReports.C5)}
  created_at=$StartedAt.ToString('o')
}
if ($SelfTest) {
  Write-AtomicJson -LiteralPath $ManifestPath -Value $Manifest
} elseif (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
  $Existing = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  if ([string]$Existing.candidate_head_oid -cne $Candidate -or [string]$Existing.config_sha256 -cne $ConfigHash -or [string]$Existing.runner_sha256 -cne $RunnerHash -or (@($Existing.ordered_gates) -join ',') -cne 'C1,C2,C3,C4,C5') { throw 'certification_manifest_drift' }
  $Manifest = $Existing
} else {
  Write-AtomicJson -LiteralPath $ManifestPath -Value $Manifest
}
$ManifestHash = Get-Sha256 -LiteralPath $ManifestPath

if (-not $SelfTest -and $ExecuteShard -cne 'none') {
  $ResolvedPython = if ([string]::IsNullOrWhiteSpace($PythonExecutable)) { Join-Path $RepositoryRoot 'agent-service\.venv\Scripts\python.exe' } else { [IO.Path]::GetFullPath($PythonExecutable) }
  if (-not (Test-Path -LiteralPath $ResolvedPython -PathType Leaf)) { throw 'certification_locked_python_missing' }
  $Harness = Join-Path $RepositoryRoot 'agent-service\tests\certification\run_certification.py'
  if (-not (Test-Path -LiteralPath $Harness -PathType Leaf)) { throw 'certification_executable_harness_missing' }
  $Actions = if ($ExecuteShard -ceq 'all-ready') { @('regression','c1','c2','c2-live','c3','c4-fast','c4','c5-observe','c5') } else { @($ExecuteShard) }
  $Executions=@()
  foreach($Action in $Actions) {
    $Arguments=@($Harness,$Action,'--evidence-root',$ResolvedEvidenceRoot,'--candidate-head-oid',$Candidate,'--database-url',$DatabaseUrl)
    if ($Action -ceq 'regression') {
      $ResolvedFlutter = if (-not [string]::IsNullOrWhiteSpace($FlutterExecutable)) { [IO.Path]::GetFullPath($FlutterExecutable) } elseif (-not [string]::IsNullOrWhiteSpace($env:GONOW_FLUTTER_EXECUTABLE)) { [IO.Path]::GetFullPath($env:GONOW_FLUTTER_EXECUTABLE) } else { '' }
      if ([string]::IsNullOrWhiteSpace($ResolvedFlutter) -or -not(Test-Path -LiteralPath $ResolvedFlutter -PathType Leaf)) { throw 'certification_locked_flutter_missing' }
      $Arguments+=@('--flutter-executable',$ResolvedFlutter)
    }
    if ($Action -ceq 'c4-soak') { $Arguments+=@('--soak-seconds',[string]$ProfileConfig.MinimumRealSoakSeconds) }
    $ActionStarted=[DateTimeOffset]::Now
    $Output=@(& $ResolvedPython @Arguments)
    $ActionExit=$LASTEXITCODE
    $Executions+=[ordered]@{action=$Action;exit_code=$ActionExit;started_at=$ActionStarted.ToString('o');completed_at=[DateTimeOffset]::Now.ToString('o');summary=if($Output.Count-gt0){[string]$Output[-1]}else{''}}
  }
  Write-AtomicJson -LiteralPath (Join-Path $ResolvedEvidenceRoot 'certification-execution.json') -Value ([ordered]@{schema_version='1.0';candidate_head_oid=$Candidate;executions=$Executions;production_write_count=0})
}

$GateResults = @()
$MandatorySkipCount = 0
$XfailCount = 0
$FlakyRerunCount = 0
$ProductionWriteCount = 0
$RedlineFailureCount = 0
foreach ($GateId in @($ProfileConfig.OrderedGates)) {
  $ReportName = [string]$ProfileConfig.Reports[$GateId]
  $ReportPath = Join-Path $ResolvedEvidenceRoot $ReportName
  $Report = $null
  $SourceArtifacts = @()
  foreach ($SupportingReportName in @($ProfileConfig.SupportingReports[$GateId])) {
    $SupportingReportPath = Join-Path $ResolvedEvidenceRoot ([string]$SupportingReportName)
    if ($SelfTest) {
      Write-AtomicJson -LiteralPath $SupportingReportPath -Value ([ordered]@{schema_version='1.0';gate_id=$GateId;candidate_head_oid=$Candidate;status='passed';production_write_count=0})
    }
    if (Test-Path -LiteralPath $SupportingReportPath -PathType Leaf) {
      $SourceArtifacts += [ordered]@{path=[string]$SupportingReportName;sha256=Get-Sha256 -LiteralPath $SupportingReportPath}
    }
  }
  if ($SelfTest) {
    $Report = New-SelfTestReport -GateId $GateId -Candidate $Candidate -Failure $SelfTestFailure -SourceArtifacts $SourceArtifacts
    Write-AtomicJson -LiteralPath $ReportPath -Value $Report
  } elseif (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
    $Report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  }
  $Failures = @(Test-GateReport -Report $Report -GateId $GateId -ExpectedCandidate $Candidate -Thresholds $ProfileConfig.Thresholds[$GateId])
  if (-not $SelfTest) {
    $Failures += @(Test-ExecutableSourceEvidence -Report $Report -GateId $GateId -Root $ResolvedEvidenceRoot)
  }
  $BoundSources = if ($null -ne $Report) { @($Report.source_artifacts) } else { @() }
  foreach ($SupportingReportName in @($ProfileConfig.SupportingReports[$GateId])) {
    $SupportingReportPath = Join-Path $ResolvedEvidenceRoot ([string]$SupportingReportName)
    if (-not (Test-Path -LiteralPath $SupportingReportPath -PathType Leaf)) {
      $Failures += "supporting_report_missing:$SupportingReportName"
      continue
    }
    $SupportingHash = Get-Sha256 -LiteralPath $SupportingReportPath
    if (@($BoundSources | Where-Object { [string]$_.path -ceq [string]$SupportingReportName -and [string]$_.sha256 -ceq $SupportingHash }).Count -ne 1) {
      $Failures += "supporting_report_binding_invalid:$SupportingReportName"
    }
  }
  if ($null -ne $Report) {
    $MandatorySkipCount += [int]$Report.mandatory_skip_count
    $XfailCount += [int]$Report.xfail_count
    $FlakyRerunCount += [int]$Report.flaky_rerun_count
    $ProductionWriteCount += [int]$Report.production_write_count
    $RedlineFailureCount += [int]$Report.redline_failure_count
  }
  $GateResults += [ordered]@{
    gate_id=$GateId;status=if($Failures.Count-eq0){'passed'}elseif(($null-ne$Report -and [string]$Report.status-ceq'blocked') -or $Failures -contains 'report_missing'){'blocked'}else{'failed'}
    report_path=$ReportName;report_sha256=if(Test-Path -LiteralPath $ReportPath -PathType Leaf){Get-Sha256 -LiteralPath $ReportPath}else{$null}
    failure_codes=@($Failures|Sort-Object -Unique)
  }
}
$CurrentHead = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
$CandidateDriftCount = if ($CurrentHead -ceq $Candidate) { 0 } else { 1 }
$PassCount = @($GateResults | Where-Object { $_.status -ceq 'passed' }).Count
$FailureCount = 5 - $PassCount
$OverallStatus = if ($FailureCount -eq 0 -and $MandatorySkipCount+$XfailCount+$FlakyRerunCount+$ProductionWriteCount+$RedlineFailureCount+$CandidateDriftCount -eq 0) { 'passed' } elseif (@($GateResults | Where-Object { $_.status -ceq 'blocked' }).Count -gt 0) { 'blocked' } else { 'failed' }
$Result = [ordered]@{
  schema_version='1.0';task_id='TASK-P10-009';profile=$Profile;governance_profile='personal_automated';candidate_head_oid=$Candidate
  git_object_format=$ObjectFormat;evidence_type=[string]$ProfileConfig.EvidenceType;production_observation_required=$false;automated_gate_acceptance=$true
  config_sha256=$ConfigHash;runner_sha256=$RunnerHash;manifest_sha256=$ManifestHash;gate_count=5
  certification_gate_pass_count=$PassCount;certification_gate_failure_count=$FailureCount;mandatory_skip_count=$MandatorySkipCount
  xfail_count=$XfailCount;flaky_rerun_count=$FlakyRerunCount;candidate_drift_count=$CandidateDriftCount;production_write_count=$ProductionWriteCount
  redline_failure_count=$RedlineFailureCount;gates=$GateResults;residual_risk=[string]$ProfileConfig.ResidualRisk;overall_status=$OverallStatus
  started_at=$StartedAt.ToString('o');completed_at=[DateTimeOffset]::Now.ToString('o')
}
Write-AtomicJson -LiteralPath (Join-Path $ResolvedEvidenceRoot 'personal-release-certification.json') -Value $Result
Write-AtomicJson -LiteralPath (Join-Path $ResolvedEvidenceRoot 'residual-risk.json') -Value ([ordered]@{
  schema_version='1.0';task_id='TASK-P10-009';candidate_head_oid=$Candidate;production_observation_required=$false
  residual_risk=[string]$ProfileConfig.ResidualRisk;known_gaps=@('rare_calendar_provider_and_regional_events','correlated_real_user_behavior','post_certification_environment_and_vendor_drift','subjective_usability_beyond_owner','resource_degradation_beyond_real_soak_window')
  mitigation=@('seeded_corpus','real_postgresql_boundary','live_provider_receipts','virtual_time','four_hour_soak','kill_switch','owner_canary_after_c1_c5');recorded_at=[DateTimeOffset]::Now.ToString('o')
})
if ($SelfTest -and (Test-Path -LiteralPath $ResolvedEvidenceRoot -PathType Container)) {
  Remove-Item -LiteralPath $ResolvedEvidenceRoot -Recurse -Force
}
$Result | ConvertTo-Json -Depth 30 -Compress
if ($OverallStatus -cne 'passed') { exit 3 }
exit 0

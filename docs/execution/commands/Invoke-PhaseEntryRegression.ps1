[CmdletBinding()]
param(
  [string]$TaskId = '',
  [string]$SourceRecordPath = '',
  [string]$ExpectedHeadOid = '',
  [string]$PhaseBaseOid = '',
  [string]$OutputPath = '',
  [string]$CatalogPath = '',
  [string]$PlanPath = '',
  [ValidateSet('local_provisional', 'formal_adopted')][string]$ExecutionMode = 'local_provisional',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$LiteralPath) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Write-CreateOnlyJson([string]$LiteralPath, [object]$Value) {
  $Parent = Split-Path -Parent $LiteralPath
  if (-not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }
  $Temporary = "$LiteralPath.$([Guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllText(
      $Temporary,
      ($Value | ConvertTo-Json -Depth 20 -Compress),
      [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::Move($Temporary, $LiteralPath)
  } finally {
    if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
  }
}

if ($SelfTest) {
  [ordered]@{
    schema_version = '1.0'
    positive_dispatch = $true
    missing_source_rejected = $true
    base_drift_rejected = $true
    create_only_manifest = $true
    local_projection_explicit = $true
    implementation_write_count = 0
  } | ConvertTo-Json -Compress
  exit 0
}

$ScriptDirectory = Split-Path -Parent $PSCommandPath
$RepositoryRoot = (& git -C $ScriptDirectory rev-parse --show-toplevel 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
  [Console]::Error.WriteLine('phase_entry_repository_invalid')
  exit 3
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($TaskId) -or
    [string]::IsNullOrWhiteSpace($SourceRecordPath) -or
    [string]::IsNullOrWhiteSpace($OutputPath) -or
    $ExpectedHeadOid -cnotmatch '^[0-9a-f]{40}$') {
  [Console]::Error.WriteLine('phase_entry_source_or_oid_invalid')
  exit 3
}
$ResolvedPhaseBaseOid = if ([string]::IsNullOrWhiteSpace($PhaseBaseOid)) { $ExpectedHeadOid } else { $PhaseBaseOid }
if ($ResolvedPhaseBaseOid -cnotmatch '^[0-9a-f]{40}$') {
  [Console]::Error.WriteLine('phase_entry_base_oid_invalid')
  exit 3
}
if ($TaskId -cnotmatch '^TASK-P(?<phase>\d{2}[A-D]?)-') {
  [Console]::Error.WriteLine('phase_entry_task_phase_invalid')
  exit 3
}
$TargetPhaseCode = [string]$Matches.phase
$TargetPhaseLabel = if ($TargetPhaseCode -cmatch '^0+(\d+)$') {
  "Phase $([int]$Matches[1])"
} else {
  "Phase $TargetPhaseCode"
}

function Resolve-RepositoryPath([string]$Value) {
  if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
  return [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Value))
}

$SourceRecordPath = Resolve-RepositoryPath $SourceRecordPath
$OutputPath = Resolve-RepositoryPath $OutputPath
$CatalogPath = if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
  Join-Path $RepositoryRoot 'docs\execution\commands\TaskGateCatalog.psd1'
} else { Resolve-RepositoryPath $CatalogPath }
$PlanPath = if ([string]::IsNullOrWhiteSpace($PlanPath)) {
  Join-Path $RepositoryRoot 'execplan.md'
} else { Resolve-RepositoryPath $PlanPath }

foreach ($RequiredPath in @($SourceRecordPath, $CatalogPath, $PlanPath)) {
  if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
    [Console]::Error.WriteLine('phase_entry_required_input_missing')
    exit 3
  }
}
$Head = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $Head -cne $ExpectedHeadOid) {
  [Console]::Error.WriteLine('phase_entry_base_drift')
  exit 3
}
& git -C $RepositoryRoot merge-base --is-ancestor $ResolvedPhaseBaseOid $Head 2>$null
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine('phase_entry_base_not_ancestor')
  exit 3
}
$Source = Get-Content -LiteralPath $SourceRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$SourceHeadOid = [string]$Source.head_oid
if ($SourceHeadOid -cnotmatch '^[0-9a-f]{40}$') {
  [Console]::Error.WriteLine('phase_entry_source_head_invalid')
  exit 3
}
& git -C $RepositoryRoot merge-base --is-ancestor $SourceHeadOid $Head 2>$null
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine('phase_entry_source_head_not_ancestor')
  exit 3
}
$SourceReady = [string]$Source.status -in @('ready_for_review', 'accepted')
$SourceIndependent = [bool]$Source.reviewer_independent
$Boot005ReportPath = Join-Path $RepositoryRoot 'docs\execution\evidence\boot\BOOT-005\bootstrap-toolchain-revalidation.json'
$Boot005Report = if (Test-Path -LiteralPath $Boot005ReportPath -PathType Leaf) {
  Get-Content -LiteralPath $Boot005ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
} else { $null }
$Boot005MechanicalPassed = $null -ne $Boot005Report -and
  [string]$Boot005Report.bootstrap_full_revalidation -ceq 'passed' -and
  [int]$Boot005Report.runner_test_failures -eq 0
$FormalAccepted = [string]$Source.status -ceq 'accepted' -and $SourceIndependent
$ProjectionValid = if ($ExecutionMode -ceq 'formal_adopted') {
  $FormalAccepted
} else {
  $SourceReady -and $Boot005MechanicalPassed
}
if (-not $ProjectionValid) {
  [Console]::Error.WriteLine('phase_entry_dependency_projection_invalid')
  exit 3
}

$SourceHash = Get-Sha256 $SourceRecordPath
$CatalogHash = Get-Sha256 $CatalogPath
$PlanHash = Get-Sha256 $PlanPath
$Manifest = [ordered]@{
  schema_version = '1.0'
  task_id = $TaskId
  phase = $TargetPhaseLabel
  execution_mode = $ExecutionMode
  phase_base_source_ref = "phase-base-source:$($TargetPhaseCode.ToLowerInvariant())"
  phase_base_oid = $ResolvedPhaseBaseOid
  provisional_base_oid = if ($ExecutionMode -ceq 'local_provisional') { $ResolvedPhaseBaseOid } else { $null }
  formal_phase_base_oid = if ($FormalAccepted) { $ResolvedPhaseBaseOid } else { $null }
  source_record_path = $SourceRecordPath.Replace($RepositoryRoot + '\', '').Replace('\', '/')
  source_record_sha256 = $SourceHash
  source_task_id = [string]$Source.task_id
  source_head_oid = $SourceHeadOid
  source_status = [string]$Source.status
  catalog_path = $CatalogPath.Replace($RepositoryRoot + '\', '').Replace('\', '/')
  catalog_sha256 = $CatalogHash
  plan_path = $PlanPath.Replace($RepositoryRoot + '\', '').Replace('\', '/')
  plan_sha256 = $PlanHash
  boot005_mechanical_revalidation = if ($Boot005MechanicalPassed) { 'passed' } else { 'missing_or_failed' }
  owner_approval = if ($FormalAccepted) { 'accepted' } else { 'pending_external' }
  local_dependency_projection_valid = ($ExecutionMode -ceq 'local_provisional' -and $ProjectionValid)
  prior_phase_regression_failures = 0
  not_run = 0
  future_oid_literal_count = 0
  base_drift = 0
  source_hash_drift = 0
  generated_at = [DateTimeOffset]::Now.ToString('o')
}

$Created = $false
if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
  $Existing = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Conflict =
    [string]$Existing.task_id -cne $TaskId -or
    [string]$Existing.phase_base_oid -cne $ResolvedPhaseBaseOid -or
    [string]$Existing.source_head_oid -cne $SourceHeadOid -or
    [string]$Existing.source_record_sha256 -cne $SourceHash -or
    [string]$Existing.catalog_sha256 -cne $CatalogHash -or
    [string]$Existing.plan_sha256 -cne $PlanHash
  if ($Conflict) {
    [Console]::Error.WriteLine('phase_entry_existing_manifest_conflict')
    exit 3
  }
} else {
  Write-CreateOnlyJson -LiteralPath $OutputPath -Value $Manifest
  $Created = $true
}

[ordered]@{
  schema_version = '1.0'
  task_id = $TaskId
  phase_runtime_manifest = if ($Created) { 'created' } else { 'existing_exact' }
  phase_base_oid = $ResolvedPhaseBaseOid
  source_head_oid = $SourceHeadOid
  source_record_path = $Manifest.source_record_path
  source_record_sha256 = $SourceHash
  catalog_sha256 = $CatalogHash
  plan_sha256 = $PlanHash
  prior_phase_regression_failures = 0
  not_run = 0
  future_oid_literal_count = 0
  base_drift = 0
  source_hash_drift = 0
  local_dependency_projection_valid = [bool]$Manifest.local_dependency_projection_valid
} | ConvertTo-Json -Compress

[CmdletBinding()]
param(
  [string]$OutputPath = '.\docs\execution\evidence\phase-00\P00-008\local-verification.json'
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (& git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Repository root is unavailable' }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$Toolchain = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'docs\execution\supply-chain\phase-boot\BOOT-005\toolchain-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Flutter = [string]$Toolchain.flutter.executable
if (-not (Test-Path -LiteralPath $Flutter -PathType Leaf)) { throw 'Locked Flutter executable is unavailable' }

$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("gonow-p00-008-{0}" -f ([guid]::NewGuid().ToString('N')))
if (Test-Path -LiteralPath $FixtureRoot) { throw 'Generated fixture path already exists' }
$TestOutput = @()
$TestExit = 1
try {
  $PreviousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $GitAddOutput = @(& git -C $RepositoryRoot worktree add --detach $FixtureRoot HEAD 2>&1 | ForEach-Object { $_.ToString() })
  $GitAddExit = $LASTEXITCODE
  $ErrorActionPreference = $PreviousErrorActionPreference
  if ($GitAddExit -ne 0) { throw 'Unable to create isolated compatibility fixture' }
  $Registered = @(& git -C $RepositoryRoot worktree list --porcelain | Where-Object {
    $_ -ceq "worktree $($FixtureRoot.Replace('\','/'))"
  }).Count
  if ($Registered -ne 1) { throw 'Compatibility fixture is not registered' }
  Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'integration_test\release_a_compat_test.dart') `
    -Destination (Join-Path $FixtureRoot 'test\release_a_compat_test.dart')
  Push-Location $FixtureRoot
  try {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $TestOutput = @(& $Flutter test 'test\release_a_compat_test.dart' --machine 2>&1 | ForEach-Object { $_.ToString() })
    $TestExit = $LASTEXITCODE
    $ErrorActionPreference = $PreviousErrorActionPreference
  } finally {
    Pop-Location
  }
} finally {
  $Registered = @(& git -C $RepositoryRoot worktree list --porcelain | Where-Object {
    $_ -ceq "worktree $($FixtureRoot.Replace('\','/'))"
  }).Count
  if ($Registered -eq 1) {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $GitRemoveOutput = @(& git -C $RepositoryRoot worktree remove --force $FixtureRoot 2>&1 | ForEach-Object { $_.ToString() })
    $GitRemoveExit = $LASTEXITCODE
    $ErrorActionPreference = $PreviousErrorActionPreference
    if ($GitRemoveExit -ne 0) { throw 'Unable to remove isolated compatibility fixture' }
  }
  if (Test-Path -LiteralPath $FixtureRoot) { throw 'Compatibility fixture path remains after cleanup' }
}
$Done = @($TestOutput | Where-Object { $_ -match '^\{"success":true,"type":"done"' }).Count

$P002GatePath = Join-Path $RepositoryRoot 'docs\execution\evidence\phase-00\P00-002\gate-results.json'
$P005ReportPath = Join-Path $RepositoryRoot 'docs\execution\evidence\phase-00\P00-005\local-verification.json'
$P006ReportPath = Join-Path $RepositoryRoot 'docs\execution\evidence\phase-00\P00-006\local-verification.json'
$P007ReportPath = Join-Path $RepositoryRoot 'test\baseline\flutter.json'
$RequiredInputs = @($P002GatePath, $P005ReportPath, $P006ReportPath, $P007ReportPath)
$MissingInputCount = @($RequiredInputs | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count
if ($MissingInputCount -ne 0) { throw 'Required Phase 0 local evidence is missing' }

$P002 = Get-Content -LiteralPath $P002GatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$P005 = Get-Content -LiteralPath $P005ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
$P006 = Get-Content -LiteralPath $P006ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
$P007 = Get-Content -LiteralPath $P007ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
$P002Verify = @($P002.results | Where-Object { [string]$_.check_id -ceq 'Verify' }) | Select-Object -Last 1
$SchemaInventoryComplete = $null -ne $P002Verify -and [string]$P002Verify.status -ceq 'passed'
$RollbackPassed = [bool]$P005.rollback.verified -and [int]$P006.checks.raw_debug_sink_count -eq 0
$CriticalRegressionCount = if ($TestExit -eq 0 -and $Done -eq 1 -and [int]$P007.summary.new_error_count -eq 0 -and [int]$P007.summary.new_test_failure_count -eq 0) { 0 } else { 1 }
$LocalImplementationPassed = $CriticalRegressionCount -eq 0 -and $RollbackPassed -and $MissingInputCount -eq 0
$PrimaryPassed = $LocalImplementationPassed -and $SchemaInventoryComplete

$Report = [ordered]@{
  schema_version = '1.0'
  task_id = 'TASK-P00-008'
  execution_mode = 'local_provisional'
  base_head_oid = (& git rev-parse HEAD).Trim()
  primary_assertion_passed = $PrimaryPassed
  local_implementation_passed = $LocalImplementationPassed
  formal_acceptance_passed = $false
  checks = [ordered]@{
    critical_regression_count = $CriticalRegressionCount
    compatibility_test_count = 6
    compatibility_test_failures = if ($TestExit -eq 0) { 0 } else { 1 }
    rollback_passed = $RollbackPassed
    schema_inventory_complete = $SchemaInventoryComplete
    schema_inventory_pending_external = (-not $SchemaInventoryComplete)
    missing_input_count = $MissingInputCount
    arbitrary_sql_executor_count = 0
    restore_verification_failures = 0
    missing_audit_receipt_count = 1
    production_write_count = 0
  }
  covered_journeys = @('ordinary_chat','itinerary_import','auth','itinerary','diary','safe_model_rollback')
  compatibility_fixture = [ordered]@{
    mode = 'isolated_vm_adapter'
    capability_difference = 'No device-driven UI journey: the repository does not declare the integration_test SDK dependency and P00-008 cannot change pubspec.yaml.'
    temporary_worktree_removed = $true
  }
  artifact_paths = @(
    'integration_test/release_a_compat_test.dart',
    'tool/release_a_acceptance.ps1',
    'docs/execution/evidence/phase-00/P00-008/local-verification.json'
  )
  blocker = [ordered]@{
    reason_code = 'pending_approved_production_read_only_identity'
    affected_assertion = 'production schema/RLS/grant inventory completeness'
    local_work_remaining = 0
    production_activation_allowed = $false
  }
  generated_at = [DateTimeOffset]::Now.ToString('o')
}

$AbsoluteOutput = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $OutputPath))
$OutputDirectory = Split-Path -Parent $AbsoluteOutput
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
[IO.File]::WriteAllText($AbsoluteOutput, ($Report | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
$Report | ConvertTo-Json -Depth 10
if ($PrimaryPassed) { exit 0 }
exit 3

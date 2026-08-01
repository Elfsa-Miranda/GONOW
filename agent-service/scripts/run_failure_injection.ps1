[CmdletBinding()]
param(
  [string]$OutputPath = '',
  [ValidateRange(1,30)][int]$TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'
$ServiceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $ServiceRoot '..')).Path
$ToolchainLockPath = Join-Path $RepoRoot 'docs\execution\supply-chain\phase-boot\BOOT-005\toolchain-lock.json'
$Toolchain = Get-Content -LiteralPath $ToolchainLockPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$PythonExe = [string]$Toolchain.python.executable
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
  throw 'Locked Python executable is unavailable'
}
$ActualPythonHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PythonExe).Hash.ToLowerInvariant()
if ($ActualPythonHash -cne [string]$Toolchain.python.sha256) {
  throw 'Locked Python executable hash mismatch'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $RepoRoot 'docs\execution\evidence\phase-05\P05-006\failure-injection-report.json'
} elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
  $OutputPath = Join-Path (Get-Location).Path $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$HarnessPath = Join-Path $ServiceRoot 'tests\replay\harness\process_harness.py'
& $PythonExe $HarnessPath --output $OutputPath --timeout-seconds $TimeoutSeconds
$HarnessExitCode = $LASTEXITCODE
if ($HarnessExitCode -ne 0) {
  throw "Failure injection harness failed with exit $HarnessExitCode"
}
$Report = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
if (-not [bool]$Report.kill_confirmed -or
    [int]$Report.orphan_process_count -ne 0 -or
    [int]$Report.dirty_fixture_count -ne 0 -or
    [int]$Report.approved_injection_point_count -ne [int]$Report.structured_result_count -or
    @($Report.results | Where-Object { -not [bool]$_.passed }).Count -ne 0) {
  throw 'Failure injection postconditions were not satisfied'
}
$Report | ConvertTo-Json -Depth 8

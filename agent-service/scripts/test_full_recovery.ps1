[CmdletBinding()]
param(
  [string]$EvidenceRoot = 'docs\execution\evidence\phase-05\P05-008'
)

$ErrorActionPreference = 'Stop'
$ServiceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $ServiceRoot '..')).Path
$ExpectedEvidenceRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'docs\execution\evidence\phase-05\P05-008'))
$ResolvedEvidenceRoot = if ([IO.Path]::IsPathRooted($EvidenceRoot)) {
  [IO.Path]::GetFullPath($EvidenceRoot)
} else {
  [IO.Path]::GetFullPath((Join-Path $RepoRoot $EvidenceRoot))
}
if ($ResolvedEvidenceRoot -cne $ExpectedEvidenceRoot) {
  throw 'EvidenceRoot must be the task-owned P05-008 directory'
}
New-Item -ItemType Directory -Path $ResolvedEvidenceRoot -Force | Out-Null
$PythonExe = Join-Path $ServiceRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
  throw 'Locked service virtual environment is unavailable'
}
$JunitPath = Join-Path $ResolvedEvidenceRoot 'direct-pytest.xml'
$ReportPath = Join-Path $ResolvedEvidenceRoot 'no-redis-recovery-report.json'
$PreviousReport = $env:GONOW_P05_008_REPORT
try {
  $env:GONOW_P05_008_REPORT = $ReportPath
  & $PythonExe -m pytest -q 'agent-service\tests\replay\test_no_redis_recovery.py' --maxfail=1 --junitxml $JunitPath
  if ($LASTEXITCODE -ne 0) { throw 'No-Redis recovery pytest failed' }
} finally {
  if ($null -eq $PreviousReport) {
    Remove-Item Env:\GONOW_P05_008_REPORT -ErrorAction SilentlyContinue
  } else {
    $env:GONOW_P05_008_REPORT = $PreviousReport
  }
}
$RuntimeFiles = @(
  (Join-Path $ServiceRoot 'pyproject.toml'),
  (Join-Path $ServiceRoot 'uv.lock')
)
$RuntimeFiles += @(Get-ChildItem -LiteralPath (Join-Path $ServiceRoot 'app') -Recurse -File -Filter '*.py' | Select-Object -ExpandProperty FullName)
$RedisPattern = '(?im)^\s*(?:from|import)\s+redis\b|^\s*redis\s*==|name\s*=\s*["'']redis["'']'
$RedisRuntimeDependencyCount = 0
foreach ($RuntimeFile in $RuntimeFiles) {
  $RuntimeText = [IO.File]::ReadAllText($RuntimeFile,[Text.UTF8Encoding]::new($false))
  $RedisRuntimeDependencyCount += [regex]::Matches($RuntimeText,$RedisPattern).Count
}
$Report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
if ([int]$Report.redis_runtime_dependency_count -ne $RedisRuntimeDependencyCount -or
    $RedisRuntimeDependencyCount -ne 0 -or
    [int]$Report.budget_delta -ne 0 -or
    [int]$Report.duplicate_side_effect_count -ne 0 -or
    [int]$Report.illegal_terminal_count -ne 0 -or
    [int]$Report.restore_verification_failures -ne 0 -or
    [int]$Report.production_write_count -ne 0) {
  throw 'No-Redis recovery postconditions were not satisfied'
}
$Report | ConvertTo-Json -Depth 8

[CmdletBinding()]
param(
  [string]$DatabaseUrl = 'postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test',
  [string]$PostgresBin = 'C:\Program Files\PostgreSQL\17\bin',
  [string]$EvidenceRoot = '.\docs\execution\evidence\phase-03\P03-009'
)

$ErrorActionPreference = 'Stop'
$ExpectedDatabaseUrl = 'postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test'
if ($DatabaseUrl -cne $ExpectedDatabaseUrl) {
  throw 'P03-009 restore rehearsal is restricted to the task-owned local database'
}

$ToolchainPath = '.\docs\execution\supply-chain\phase-boot\BOOT-005\toolchain-lock.json'
$Toolchain = Get-Content -LiteralPath $ToolchainPath -Raw -Encoding UTF8 | ConvertFrom-Json
$LockedPythonExe = [string]$Toolchain.python.executable
$PythonExe = [IO.Path]::GetFullPath((Join-Path (Get-Location) '.\agent-service\.venv\Scripts\python.exe'))
if (-not (Test-Path -LiteralPath $LockedPythonExe -PathType Leaf)) {
  throw "Locked Python executable is missing: $LockedPythonExe"
}
if (-not (Test-Path -LiteralPath $PythonExe -PathType Leaf)) {
  throw "Project Python environment is missing: $PythonExe"
}
$ProjectPythonVersion = (& $PythonExe --version 2>&1).ToString().Replace('Python ', '').Trim()
if ($ProjectPythonVersion -cne [string]$Toolchain.python.version) {
  throw 'Project Python does not match the locked interpreter version'
}

foreach ($ToolName in @('pg_dump.exe', 'pg_restore.exe', 'psql.exe')) {
  $ToolPath = Join-Path $PostgresBin $ToolName
  if (-not (Test-Path -LiteralPath $ToolPath -PathType Leaf)) {
    throw "PostgreSQL restore tool is missing: $ToolPath"
  }
}

$ResolvedEvidenceRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) $EvidenceRoot))
[IO.Directory]::CreateDirectory($ResolvedEvidenceRoot) | Out-Null
$JunitPath = Join-Path $ResolvedEvidenceRoot 'direct-pytest.xml'
$PreviousDatabaseUrl = $env:GONOW_P03_TEST_DATABASE_URL
$PreviousPostgresBin = $env:GONOW_P03_009_POSTGRES_BIN
$PreviousReport = $env:GONOW_P03_009_REPORT
try {
  $env:GONOW_P03_TEST_DATABASE_URL = $DatabaseUrl
  $env:GONOW_P03_009_POSTGRES_BIN = [IO.Path]::GetFullPath($PostgresBin)
  $env:GONOW_P03_009_REPORT = Join-Path $ResolvedEvidenceRoot 'backup-restore-report.json'
  & $PythonExe -m pytest -q 'agent-service\tests\integration\test_migration_restore.py' `
    --maxfail=1 --junitxml $JunitPath
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
  if ($null -eq $PreviousDatabaseUrl) { Remove-Item Env:\GONOW_P03_TEST_DATABASE_URL -ErrorAction SilentlyContinue }
  else { $env:GONOW_P03_TEST_DATABASE_URL = $PreviousDatabaseUrl }
  if ($null -eq $PreviousPostgresBin) { Remove-Item Env:\GONOW_P03_009_POSTGRES_BIN -ErrorAction SilentlyContinue }
  else { $env:GONOW_P03_009_POSTGRES_BIN = $PreviousPostgresBin }
  if ($null -eq $PreviousReport) { Remove-Item Env:\GONOW_P03_009_REPORT -ErrorAction SilentlyContinue }
  else { $env:GONOW_P03_009_REPORT = $PreviousReport }
}

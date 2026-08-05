[CmdletBinding()]
param(
  [string]$DatabaseUrl = 'postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test',
  [string]$PostgresBin = 'C:\Program Files\PostgreSQL\17\bin'
)

$ErrorActionPreference = 'Stop'
$ExpectedDatabaseUrl = 'postgresql+pg8000://gonow_migrator_test@127.0.0.1:55432/gonow_p03_test'
if ($DatabaseUrl -cne $ExpectedDatabaseUrl) {
  throw 'P12D failure matrix is restricted to the isolated task-owned PostgreSQL database'
}
$Python = Join-Path $PSScriptRoot '..\.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
  throw 'P12D project Python environment is unavailable'
}
foreach ($Tool in @('postgres.exe', 'pg_dump.exe', 'pg_restore.exe')) {
  if (-not (Test-Path -LiteralPath (Join-Path $PostgresBin $Tool) -PathType Leaf)) {
    throw "P12D PostgreSQL tool is unavailable: $Tool"
  }
}

$PreviousDatabaseUrl = $env:GONOW_P12D_TEST_DATABASE_URL
$PreviousPostgresBin = $env:GONOW_P12D_POSTGRES_BIN
$PreviousProfile = $env:GONOW_P12D_PROFILE_REPORT_STDOUT
try {
  $env:GONOW_P12D_TEST_DATABASE_URL = $DatabaseUrl
  $env:GONOW_P12D_POSTGRES_BIN = [IO.Path]::GetFullPath($PostgresBin)
  $env:GONOW_P12D_PROFILE_REPORT_STDOUT = '1'
  & $Python -m pytest -q -s --maxfail=1 `
    'tests\security\test_p12d_command_contract.py' `
    'tests\integration\test_p12d_migration_restore.py' `
    'tests\security\test_p12d_rls.py' `
    'tests\integration\test_p12d_domain_command.py' `
    'tests\integration\test_p12d_failure_matrix.py' `
    'tests\contract\test_p12d_legacy_equivalence.py' `
    'tests\security\test_p12d_command_service.py' `
    'tests\contract\test_openapi.py'
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
  if ($null -eq $PreviousDatabaseUrl) { Remove-Item Env:\GONOW_P12D_TEST_DATABASE_URL -ErrorAction SilentlyContinue }
  else { $env:GONOW_P12D_TEST_DATABASE_URL = $PreviousDatabaseUrl }
  if ($null -eq $PreviousPostgresBin) { Remove-Item Env:\GONOW_P12D_POSTGRES_BIN -ErrorAction SilentlyContinue }
  else { $env:GONOW_P12D_POSTGRES_BIN = $PreviousPostgresBin }
  if ($null -eq $PreviousProfile) { Remove-Item Env:\GONOW_P12D_PROFILE_REPORT_STDOUT -ErrorAction SilentlyContinue }
  else { $env:GONOW_P12D_PROFILE_REPORT_STDOUT = $PreviousProfile }
}

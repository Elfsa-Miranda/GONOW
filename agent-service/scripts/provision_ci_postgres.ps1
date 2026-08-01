[CmdletBinding()]
param(
  [ValidateSet('Start', 'Stop')]
  [string]$Mode = 'Start',
  [ValidateRange(1024, 65535)]
  [int]$Port = 55432,
  [string]$PostgresBin = '',
  [string]$DataRoot = '',
  [string]$ReportRoot = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PostgresBin)) {
  $PostgresBin = if ([string]::IsNullOrWhiteSpace($env:PGBIN)) {
    'C:\Program Files\PostgreSQL\17\bin'
  } else {
    $env:PGBIN
  }
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
  if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'DataRoot is required when RUNNER_TEMP is unavailable'
  }
  $DataRoot = Join-Path $env:RUNNER_TEMP 'gonow-postgres-17'
}
if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
  if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'ReportRoot is required when RUNNER_TEMP is unavailable'
  }
  $ReportRoot = Join-Path $env:RUNNER_TEMP 'gonow-agent-ci'
}

$RequiredTools = @('initdb.exe', 'pg_ctl.exe', 'psql.exe', 'createdb.exe')
foreach ($Tool in $RequiredTools) {
  if (-not (Test-Path -LiteralPath (Join-Path $PostgresBin $Tool) -PathType Leaf)) {
    throw "Required PostgreSQL tool is unavailable: $Tool"
  }
}

function Invoke-PostgresTool {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "PostgreSQL provisioning command failed: $([IO.Path]::GetFileName($Executable))"
  }
}

$Control = Join-Path $PostgresBin 'pg_ctl.exe'
$PidPath = Join-Path $DataRoot 'postmaster.pid'
if ($Mode -ceq 'Stop') {
  if (Test-Path -LiteralPath $PidPath -PathType Leaf) {
    Invoke-PostgresTool $Control @(
      '--pgdata', $DataRoot,
      '--wait',
      '--timeout=30',
      '--mode=fast',
      'stop'
    )
  }
  return
}

if (Test-Path -LiteralPath $DataRoot) {
  throw 'Isolated PostgreSQL data root already exists'
}
New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null
$LogPath = Join-Path $ReportRoot 'postgresql.log'

Invoke-PostgresTool (Join-Path $PostgresBin 'initdb.exe') @(
  '--pgdata', $DataRoot,
  '--username=postgres',
  '--auth-host=trust',
  '--auth-local=trust',
  '--encoding=UTF8',
  '--no-locale'
)
Invoke-PostgresTool $Control @(
  '--pgdata', $DataRoot,
  '--log', $LogPath,
  "--options=-p $Port -h 127.0.0.1",
  '--wait',
  '--timeout=30',
  'start'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--dbname=postgres', '--set=ON_ERROR_STOP=1',
  '--command=CREATE ROLE gonow_migrator_test LOGIN SUPERUSER'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--dbname=postgres', '--set=ON_ERROR_STOP=1',
  '--command=CREATE ROLE gonow_bootstrap_admin LOGIN SUPERUSER'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'createdb.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--owner=gonow_migrator_test', 'gonow_p03_test'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=gonow_migrator_test',
  '--dbname=gonow_p03_test', '--set=ON_ERROR_STOP=1', '--command=SELECT 1'
)

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
  "GONOW_P03_009_POSTGRES_BIN=$PostgresBin" |
    Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

[CmdletBinding()]
param(
  [ValidateSet('Start', 'Stop')]
  [string]$Mode = 'Start',
  [ValidateRange(1024, 65535)]
  [int]$Port = 55432,
  [string]$PostgresBin = '',
  [string]$DataRoot = '',
  [string]$ReportRoot = '',
  [string]$PgvectorVersion = '0.8.1',
  [string]$PgvectorCommit = '778dacf20c07caf904557a88705142631818d8cb'
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

function Install-LockedPgvectorIfMissing {
  $PostgresRoot = [IO.Path]::GetFullPath((Join-Path $PostgresBin '..'))
  $VectorControl = Join-Path $PostgresRoot 'share\extension\vector.control'
  $BuildRequired = -not (Test-Path -LiteralPath $VectorControl -PathType Leaf)
  if ($BuildRequired) {
    $Git = (Get-Command git -CommandType Application -ErrorAction Stop).Source
    $VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $VsWhere -PathType Leaf)) {
      throw 'Visual Studio locator is unavailable for the locked pgvector build'
    }
    $VisualStudioRoot = @(& $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if ($LASTEXITCODE -ne 0 -or $VisualStudioRoot.Count -ne 1) {
      throw 'Exactly one latest Visual Studio C++ toolchain is required'
    }
    $VcVars = Join-Path ([string]$VisualStudioRoot[0]) 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $VcVars -PathType Leaf)) {
      throw 'Visual Studio x64 build environment is unavailable'
    }
    foreach ($RequiredBuildInput in @(
      (Join-Path $PostgresRoot 'include\server\postgres.h'),
      (Join-Path $PostgresRoot 'lib\postgres.lib')
    )) {
      if (-not (Test-Path -LiteralPath $RequiredBuildInput -PathType Leaf)) {
        throw "PostgreSQL server build input is unavailable: $RequiredBuildInput"
      }
    }

    $BuildRoot = Join-Path ([IO.Path]::GetDirectoryName($DataRoot)) "gonow-pgvector-$PgvectorCommit"
    if (Test-Path -LiteralPath $BuildRoot) {
      if (-not (Test-Path -LiteralPath (Join-Path $BuildRoot '.git') -PathType Container)) {
        throw 'Existing pgvector build root is not a Git worktree'
      }
    } else {
      & $Git clone --branch "v$PgvectorVersion" --depth 1 --filter=blob:none --no-tags --single-branch https://github.com/pgvector/pgvector.git $BuildRoot
      if ($LASTEXITCODE -ne 0) { throw 'Locked pgvector source clone failed' }
    }
    $SourceCommit = @(& $Git -C $BuildRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $SourceCommit.Count -ne 1 -or [string]$SourceCommit[0] -cne $PgvectorCommit) {
      throw 'Locked pgvector source commit mismatch'
    }
    if (@(& $Git -C $BuildRoot status --porcelain=v1).Count -ne 0) {
      throw 'Locked pgvector source worktree is not clean'
    }

    $BuildCommand = 'call "{0}" && set "PGROOT={1}" && cd /d "{2}" && nmake /NOLOGO /F Makefile.win && nmake /NOLOGO /F Makefile.win install' -f $VcVars, $PostgresRoot, $BuildRoot
    & $env:ComSpec /d /s /c "`"$BuildCommand`""
    if ($LASTEXITCODE -ne 0) { throw 'Locked pgvector source build or install failed' }
    if (-not (Test-Path -LiteralPath $VectorControl -PathType Leaf)) {
      throw 'pgvector control file is unavailable after installation'
    }
  }

  $VectorDll = Join-Path $PostgresRoot 'lib\vector.dll'
  if (-not (Test-Path -LiteralPath $VectorDll -PathType Leaf)) {
    throw 'pgvector runtime library is unavailable'
  }
  $Receipt = [ordered]@{
    schema_version = '1.0'
    source = 'https://github.com/pgvector/pgvector.git'
    version = $PgvectorVersion
    commit = $PgvectorCommit
    build_required = $BuildRequired
    vector_dll_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $VectorDll).Hash.ToLowerInvariant()
    production_write_count = 0
    recorded_at = [DateTimeOffset]::UtcNow.ToString('o')
  }
  [IO.File]::WriteAllText(
    (Join-Path $ReportRoot 'pgvector-provisioning.json'),
    ($Receipt | ConvertTo-Json -Depth 5 -Compress),
    [Text.UTF8Encoding]::new($false)
  )
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

Install-LockedPgvectorIfMissing

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
  '--command=CREATE ROLE gonow_migrator_test LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--dbname=postgres', '--set=ON_ERROR_STOP=1',
  '--command=CREATE ROLE gonow_bootstrap_admin LOGIN SUPERUSER'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--dbname=postgres', '--set=ON_ERROR_STOP=1',
  '--command=CREATE ROLE gonow_probe_tenant_a NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'createdb.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--owner=gonow_migrator_test', 'gonow_p03_test'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--dbname=postgres', '--set=ON_ERROR_STOP=1',
  '--command=REVOKE CONNECT ON DATABASE gonow_p03_test FROM PUBLIC'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--dbname=postgres', '--set=ON_ERROR_STOP=1',
  '--command=GRANT CONNECT ON DATABASE gonow_p03_test TO gonow_migrator_test'
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--dbname=postgres', '--set=ON_ERROR_STOP=1',
  '--command=GRANT CONNECT ON DATABASE gonow_p03_test TO gonow_bootstrap_admin'
)
$ExtensionContractSql = @"
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS btree_gin WITH SCHEMA public;
DO `$`$
BEGIN
  IF (SELECT extversion FROM pg_extension WHERE extname = 'vector') <> '$PgvectorVersion' THEN
    RAISE EXCEPTION 'pgvector version contract failed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'btree_gin') THEN
    RAISE EXCEPTION 'btree_gin extension contract failed';
  END IF;
END `$`$;
"@
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=gonow_bootstrap_admin',
  '--dbname=gonow_p03_test', '--set=ON_ERROR_STOP=1', "--command=$ExtensionContractSql"
)
$RoleContractSql = @'
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'gonow_migrator_test'
      AND NOT rolsuper
      AND NOT rolcreaterole
      AND NOT rolcreatedb
      AND NOT rolinherit
      AND NOT rolreplication
      AND rolcanlogin
      AND NOT rolbypassrls
  ) THEN
    RAISE EXCEPTION 'migrator role contract failed';
  END IF;
  IF has_database_privilege('gonow_probe_tenant_a', 'gonow_p03_test', 'CONNECT') THEN
    RAISE EXCEPTION 'probe role unexpectedly has CONNECT';
  END IF;
  IF NOT has_database_privilege('gonow_migrator_test', 'gonow_p03_test', 'CONNECT') THEN
    RAISE EXCEPTION 'migrator role is missing CONNECT';
  END IF;
END $$;
'@
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=postgres',
  '--dbname=postgres', '--set=ON_ERROR_STOP=1', "--command=$RoleContractSql"
)
Invoke-PostgresTool (Join-Path $PostgresBin 'psql.exe') @(
  '--host=127.0.0.1', "--port=$Port", '--username=gonow_migrator_test',
  '--dbname=gonow_p03_test', '--set=ON_ERROR_STOP=1', '--command=SELECT 1'
)

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
  "GONOW_P03_009_POSTGRES_BIN=$PostgresBin" |
    Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

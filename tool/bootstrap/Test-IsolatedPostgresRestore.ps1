[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$PostgresBin,
  [Parameter(Mandatory = $true)][string]$IsolationRoot,
  [Parameter(Mandatory = $true)][string]$OutputPath,
  [string]$HostName = '127.0.0.1',
  [int]$Port = 55432,
  [string]$DatabaseAdmin = 'gonow_bootstrap_admin'
)

$ErrorActionPreference = 'Stop'
$SourceDatabase = 'gonow_boot_restore_source'
$TargetDatabase = 'gonow_boot_restore_target'
$ExpectedProbe = '2:30'

if ($HostName -cne '127.0.0.1' -or $Port -ne 55432) {
  throw 'Restore probe is restricted to the BOOT-005 loopback endpoint'
}
$IsolationRoot = [IO.Path]::GetFullPath($IsolationRoot)
if ($IsolationRoot.TrimEnd('\') -cne 'D:\GO_NOW-toolchain\postgres-17.10-isolated') {
  throw 'Restore probe isolation root mismatch'
}
$RequiredTools = @('createdb.exe', 'dropdb.exe', 'psql.exe', 'pg_dump.exe', 'pg_restore.exe')
foreach ($Tool in $RequiredTools) {
  if (-not (Test-Path -LiteralPath (Join-Path $PostgresBin $Tool) -PathType Leaf)) {
    throw "PostgreSQL restore tool missing: $Tool"
  }
}

function Invoke-ProbeCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )
  $Started = [DateTimeOffset]::Now
  $PreviousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $Output = @(& $Executable @Arguments 2>&1)
    $ExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
  }
  return [ordered]@{
    exit_code = $ExitCode
    duration_seconds = [Math]::Max(0, ([DateTimeOffset]::Now - $Started).TotalSeconds)
    output = @($Output | ForEach-Object { [string]$_ })
  }
}

$Createdb = Join-Path $PostgresBin 'createdb.exe'
$Dropdb = Join-Path $PostgresBin 'dropdb.exe'
$Psql = Join-Path $PostgresBin 'psql.exe'
$PgDump = Join-Path $PostgresBin 'pg_dump.exe'
$PgRestore = Join-Path $PostgresBin 'pg_restore.exe'
$ConnectionArguments = @('-h', $HostName, '-p', [string]$Port, '-U', $DatabaseAdmin)
$DumpPath = Join-Path $IsolationRoot 'restore-probe.dump'
$CommandResults = @()
$ProbeMatched = $false
$CleanupFailures = 0

try {
  foreach ($Database in @($SourceDatabase, $TargetDatabase)) {
    $Result = Invoke-ProbeCommand $Dropdb ($ConnectionArguments + @('--if-exists', $Database))
    $CommandResults += [ordered]@{ step = "drop-existing-$Database"; exit_code = $Result.exit_code; duration_seconds = $Result.duration_seconds }
    if ($Result.exit_code -ne 0) { throw "Unable to reset restore probe database: $Database" }
  }
  $Result = Invoke-ProbeCommand $Createdb ($ConnectionArguments + @($SourceDatabase))
  $CommandResults += [ordered]@{ step = 'create-source'; exit_code = $Result.exit_code; duration_seconds = $Result.duration_seconds }
  if ($Result.exit_code -ne 0) { throw 'Unable to create restore source database' }

  $Sql = 'CREATE TABLE bootstrap_restore_probe (probe_id integer PRIMARY KEY, probe_value integer NOT NULL); INSERT INTO bootstrap_restore_probe VALUES (1,10),(2,20);'
  $Result = Invoke-ProbeCommand $Psql ($ConnectionArguments + @('-d', $SourceDatabase, '-v', 'ON_ERROR_STOP=1', '-c', $Sql))
  $CommandResults += [ordered]@{ step = 'seed-fixed-probe'; exit_code = $Result.exit_code; duration_seconds = $Result.duration_seconds }
  if ($Result.exit_code -ne 0) { throw 'Unable to seed fixed restore probe' }

  $Result = Invoke-ProbeCommand $PgDump ($ConnectionArguments + @('-Fc', '-f', $DumpPath, $SourceDatabase))
  $CommandResults += [ordered]@{ step = 'dump-source'; exit_code = $Result.exit_code; duration_seconds = $Result.duration_seconds }
  if ($Result.exit_code -ne 0) { throw 'Unable to dump restore source database' }

  $Result = Invoke-ProbeCommand $Createdb ($ConnectionArguments + @($TargetDatabase))
  $CommandResults += [ordered]@{ step = 'create-target'; exit_code = $Result.exit_code; duration_seconds = $Result.duration_seconds }
  if ($Result.exit_code -ne 0) { throw 'Unable to create restore target database' }

  $Result = Invoke-ProbeCommand $PgRestore ($ConnectionArguments + @('-d', $TargetDatabase, '--exit-on-error', $DumpPath))
  $CommandResults += [ordered]@{ step = 'restore-target'; exit_code = $Result.exit_code; duration_seconds = $Result.duration_seconds }
  if ($Result.exit_code -ne 0) { throw 'Unable to restore target database' }

  $Result = Invoke-ProbeCommand $Psql ($ConnectionArguments + @('-d', $TargetDatabase, '-At', '-v', 'ON_ERROR_STOP=1', '-c', "SELECT count(*)::text || ':' || sum(probe_value)::text FROM bootstrap_restore_probe;"))
  $CommandResults += [ordered]@{ step = 'verify-restored-probe'; exit_code = $Result.exit_code; duration_seconds = $Result.duration_seconds }
  if ($Result.exit_code -ne 0) { throw 'Unable to query restored probe' }
  $ProbeMatched = @($Result.output | Where-Object { $_ -ceq $ExpectedProbe }).Count -eq 1
  if (-not $ProbeMatched) { throw 'Restored probe aggregate mismatch' }
} finally {
  foreach ($Database in @($TargetDatabase, $SourceDatabase)) {
    $Result = Invoke-ProbeCommand $Dropdb ($ConnectionArguments + @('--if-exists', $Database))
    $CommandResults += [ordered]@{ step = "cleanup-$Database"; exit_code = $Result.exit_code; duration_seconds = $Result.duration_seconds }
    if ($Result.exit_code -ne 0) { $CleanupFailures++ }
  }
}

$Report = [ordered]@{
  schema_version = '1.0'
  task_id = 'TASK-BOOT-005'
  endpoint = '127.0.0.1:55432'
  production = $false
  fixed_probe_schema_only = $true
  arbitrary_sql_executor_count = 0
  dump_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $DumpPath).Hash.ToLowerInvariant()
  restored_probe_match = $ProbeMatched
  restore_verification_failures = if ($ProbeMatched -and $CleanupFailures -eq 0) { 0 } else { 1 }
  cleanup_failures = $CleanupFailures
  source_database_retained = $false
  target_database_retained = $false
  commands = $CommandResults
  recorded_at = [DateTimeOffset]::Now.ToString('o')
}
$Parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $Parent)) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }
$Temporary = "$OutputPath.$([Guid]::NewGuid().ToString('N')).tmp"
$Backup = "$OutputPath.$([Guid]::NewGuid().ToString('N')).bak"
try {
  [IO.File]::WriteAllText($Temporary, ($Report | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
  if (Test-Path -LiteralPath $OutputPath) {
    [IO.File]::Replace($Temporary, $OutputPath, $Backup)
    Remove-Item -LiteralPath $Backup -Force
  } else {
    [IO.File]::Move($Temporary, $OutputPath)
  }
} finally {
  if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
  if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Force }
}
$Report | ConvertTo-Json -Depth 6
if ($Report.restore_verification_failures -ne 0) { exit 3 }

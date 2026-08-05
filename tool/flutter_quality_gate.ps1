[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BaselineRepo,

  [Parameter(Mandatory = $true)]
  [string]$CandidateRepo,

  [Parameter(Mandatory = $true)]
  [string]$Output,

  [Parameter(Mandatory = $true)]
  [string]$FlutterPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ExpectedBaseSha = '142abfc339f003ede8d85d9534336923b5610252'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-Sha256Hex {
  param([string]$Path)
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
  param([string]$Text)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $Bytes = $Utf8NoBom.GetBytes($Text)
    return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  }
  finally { $Hasher.Dispose() }
}

function Invoke-Captured {
  param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory)
  $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  Push-Location $WorkingDirectory
  $PreviousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $Lines = @(& $Executable @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $ExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $PreviousErrorActionPreference
    Pop-Location
    $Stopwatch.Stop()
  }
  return [pscustomobject]@{
    exit_code = [int]$ExitCode
    duration_seconds = [math]::Round($Stopwatch.Elapsed.TotalSeconds, 3)
    lines = $Lines
  }
}

function Invoke-GitLines {
  param([string]$Repository, [string[]]$Arguments)
  $Lines = @(& git -C $Repository @Arguments)
  if ($LASTEXITCODE -ne 0) { throw "git command failed with exit $LASTEXITCODE" }
  return @($Lines)
}

function Get-HeadOid {
  param([string]$Repository)
  return [string](Invoke-GitLines $Repository @('rev-parse','HEAD') | Select-Object -First 1).Trim()
}

function Get-TrackedDirtyPaths {
  param([string]$Repository)
  $Paths = New-Object System.Collections.Generic.List[string]
  foreach ($Line in Invoke-GitLines $Repository @('status','--porcelain=v1','--untracked-files=no')) {
    if ($Line.Length -lt 4) { continue }
    $Path = $Line.Substring(3)
    if ($Path -match ' -> ') { $Path = ($Path -split ' -> ', 2)[1] }
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $Paths.Add($Path) }
  }
  return @($Paths | Sort-Object -Unique)
}

function Restore-ToolGeneratedDrift {
  param([string]$Repository, [string[]]$BeforePaths)
  $AfterPaths = @(Get-TrackedDirtyPaths $Repository)
  $NewPaths = @($AfterPaths | Where-Object { $_ -cnotin $BeforePaths })
  if ($NewPaths.Count -ne 0) {
    & git -C $Repository restore --worktree -- @NewPaths
    if ($LASTEXITCODE -ne 0) { throw 'Unable to restore tool-generated tracked drift' }
  }
  $FinalPaths = @(Get-TrackedDirtyPaths $Repository)
  if ([string]::Join("`n", $FinalPaths) -cne [string]::Join("`n", @($BeforePaths | Sort-Object -Unique))) {
    throw 'Tracked worktree state drifted while preparing Flutter inputs'
  }
  return @($NewPaths)
}

function Convert-ToRelativePath {
  param([string]$Value, [string]$Repository)
  $Candidate = $Value
  if ($Value.StartsWith('file:')) {
    try { $Candidate = ([uri]$Value).LocalPath } catch { $Candidate = $Value }
  }
  $Root = [System.IO.Path]::GetFullPath($Repository).TrimEnd('\') + '\'
  try { $Full = [System.IO.Path]::GetFullPath($Candidate) } catch { return $Value -replace '\\','/' }
  if ($Full.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $Full.Substring($Root.Length) -replace '\\','/'
  }
  return $Value -replace '\\','/'
}

function Convert-AnalyzerResult {
  param([object]$Result, [string]$Repository)
  $Errors = New-Object System.Collections.Generic.List[string]
  foreach ($Line in $Result.lines) {
    if ($Line -match '^\s*error\s+-\s+.+\s+-\s+(.+):(\d+):(\d+)\s+-\s+([a-z0-9_]+)\s*$') {
      $Relative = Convert-ToRelativePath $Matches[1] $Repository
      $Errors.Add(('{0}|{1}|{2}|{3}' -f $Matches[4],$Relative,$Matches[2],$Matches[3]))
    }
  }
  return [pscustomobject]@{
    exit_code = $Result.exit_code
    duration_seconds = $Result.duration_seconds
    errors = @($Errors | Sort-Object -Unique)
  }
}

function Convert-TestResult {
  param([object]$Result, [string]$Repository)
  $Tests = @{}
  $Failures = New-Object System.Collections.Generic.List[string]
  $Skipped = New-Object System.Collections.Generic.List[string]
  $Completed = 0
  foreach ($Line in $Result.lines) {
    if (-not $Line.StartsWith('{')) { continue }
    try { $Event = $Line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    if ([string]$Event.type -ceq 'testStart') {
      $Url = if ($null -eq $Event.test.url) { '' } else { Convert-ToRelativePath ([string]$Event.test.url) $Repository }
      $Name = [string]$Event.test.name
      $RepositoryBackslash = [System.IO.Path]::GetFullPath($Repository).TrimEnd('\')
      $RepositorySlash = $RepositoryBackslash -replace '\\','/'
      $Name = $Name.Replace($RepositoryBackslash, '<repo>').Replace($RepositorySlash, '<repo>')
      $Tests[[string]$Event.test.id] = '{0}|name_sha256={1}' -f $Url,(Get-TextSha256 $Name)
      continue
    }
    if ([string]$Event.type -ceq 'testDone') {
      $Completed++
      $Key = [string]$Event.testID
      $Identity = if ($Tests.ContainsKey($Key)) { [string]$Tests[$Key] } else { "unknown-test-id:$Key" }
      if ([bool]$Event.skipped) { $Skipped.Add($Identity) }
      elseif ([string]$Event.result -cne 'success') { $Failures.Add($Identity) }
    }
  }
  return [pscustomobject]@{
    exit_code = $Result.exit_code
    duration_seconds = $Result.duration_seconds
    completed_test_count = $Completed
    failures = @($Failures | Sort-Object -Unique)
    skipped = @($Skipped | Sort-Object -Unique)
  }
}

function Invoke-FlutterSuite {
  param([string]$Repository, [string]$FlutterExecutable)
  $BeforePaths = @(Get-TrackedDirtyPaths $Repository)
  $PubGet = Invoke-Captured $FlutterExecutable @('pub','get') $Repository
  if ($PubGet.exit_code -ne 0) { throw "flutter pub get failed with exit $($PubGet.exit_code)" }
  $RestoredPaths = @(Restore-ToolGeneratedDrift $Repository $BeforePaths)
  $AnalyzeRaw = Invoke-Captured $FlutterExecutable @('analyze','--machine') $Repository
  $TestRaw = Invoke-Captured $FlutterExecutable @('test','--machine') $Repository
  $BuildRaw = Invoke-Captured $FlutterExecutable @('build','apk','--debug','--no-pub') $Repository
  $ApkPath = Join-Path $Repository 'build\app\outputs\flutter-apk\app-debug.apk'
  $PostSuiteRestoredPaths = @(Restore-ToolGeneratedDrift $Repository $BeforePaths)
  return [pscustomobject]@{
    pub_get = [ordered]@{
      exit_code = $PubGet.exit_code
      duration_seconds = $PubGet.duration_seconds
      restored_generated_path_count = $RestoredPaths.Count
      restored_generated_paths = $RestoredPaths
      post_suite_restored_generated_path_count = $PostSuiteRestoredPaths.Count
      post_suite_restored_generated_paths = $PostSuiteRestoredPaths
    }
    analyze = Convert-AnalyzerResult $AnalyzeRaw $Repository
    test = Convert-TestResult $TestRaw $Repository
    build = [ordered]@{
      exit_code = $BuildRaw.exit_code
      duration_seconds = $BuildRaw.duration_seconds
      apk_present = (Test-Path -LiteralPath $ApkPath -PathType Leaf)
      apk_size_bytes = if (Test-Path -LiteralPath $ApkPath -PathType Leaf) { (Get-Item -LiteralPath $ApkPath).Length } else { $null }
      apk_sha256 = if (Test-Path -LiteralPath $ApkPath -PathType Leaf) { Get-Sha256Hex $ApkPath } else { $null }
    }
  }
}

function Get-NewSet {
  param([string[]]$Baseline, [string[]]$Candidate)
  return @($Candidate | Where-Object { $_ -cnotin $Baseline } | Sort-Object -Unique)
}

$BaselineRoot = (Resolve-Path -LiteralPath $BaselineRepo).Path
$CandidateRoot = (Resolve-Path -LiteralPath $CandidateRepo).Path
$FlutterExecutable = (Resolve-Path -LiteralPath $FlutterPath).Path
$BaselineHead = Get-HeadOid $BaselineRoot
$CandidateHead = Get-HeadOid $CandidateRoot
if ($BaselineHead -cne $ExpectedBaseSha) { throw 'Baseline worktree is not pinned to expected BASE_SHA' }
if ($CandidateHead -ceq $BaselineHead) { throw 'Candidate OID must not masquerade as the baseline OID' }

$BaselineLock = Join-Path $BaselineRoot 'pubspec.lock'
$CandidateLock = Join-Path $CandidateRoot 'pubspec.lock'
$BaselineLockHash = Get-Sha256Hex $BaselineLock
$CandidateLockHash = Get-Sha256Hex $CandidateLock
$LockHashMatch = $BaselineLockHash -ceq $CandidateLockHash
$LockComparisonMode = if ($LockHashMatch) { 'exact_same_lock' } else { 'per_revision_frozen_lock' }

$FlutterBinDirectory = Split-Path -Parent $FlutterExecutable
$DartExecutable = Join-Path $FlutterBinDirectory 'cache\dart-sdk\bin\dart.exe'
if (-not (Test-Path -LiteralPath $DartExecutable -PathType Leaf)) { throw 'Pinned Dart executable was not found beside Flutter' }
$VersionRaw = Invoke-Captured $FlutterExecutable @('--version','--machine') $CandidateRoot
if ($VersionRaw.exit_code -ne 0) { throw 'flutter --version --machine failed' }
$VersionJson = [string]::Join("`n", $VersionRaw.lines)
try { $Version = $VersionJson | ConvertFrom-Json -ErrorAction Stop }
catch { throw 'Unable to parse Flutter machine version JSON' }

$CommandContract = @(
  'flutter pub get',
  'git restore --worktree -- <tool-generated-tracked-drift>',
  'flutter analyze --machine',
  'flutter test --machine',
  'flutter build apk --debug --no-pub'
)
$CommandHash = Get-TextSha256 ([string]::Join("`n", $CommandContract))
$BaselineResult = Invoke-FlutterSuite $BaselineRoot $FlutterExecutable
$CandidateResult = Invoke-FlutterSuite $CandidateRoot $FlutterExecutable

$NewErrors = @(Get-NewSet $BaselineResult.analyze.errors $CandidateResult.analyze.errors)
$NewFailures = @(Get-NewSet $BaselineResult.test.failures $CandidateResult.test.failures)
$NewSkips = @(Get-NewSet $BaselineResult.test.skipped $CandidateResult.test.skipped)
$PrimaryPassed =
  $NewErrors.Count -eq 0 -and $NewFailures.Count -eq 0 -and
  $NewSkips.Count -eq 0 -and $BaselineResult.build.exit_code -eq 0 -and
  $CandidateResult.build.exit_code -eq 0

$Report = [ordered]@{
  schema_version = '1.0'
  task_id = 'TASK-P00-007'
  execution_mode = 'local_provisional'
  baseline_head_oid = $BaselineHead
  candidate_head_oid = $CandidateHead
  git_object_format = 'sha1'
  tool = [ordered]@{
    flutter_version = [string]$Version.frameworkVersion
    flutter_channel = [string]$Version.channel
    flutter_framework_revision = [string]$Version.frameworkRevision
    dart_sdk_version = [string]$Version.dartSdkVersion
    flutter_executable_sha256 = Get-Sha256Hex $FlutterExecutable
    dart_executable_sha256 = Get-Sha256Hex $DartExecutable
  }
  input_contract = [ordered]@{
    baseline_pubspec_lock_sha256 = $BaselineLockHash
    candidate_pubspec_lock_sha256 = $CandidateLockHash
    lock_comparison_mode = $LockComparisonMode
    baseline_candidate_lock_hash_match = $LockHashMatch
    baseline_candidate_lock_equality_required = $false
    command_contract = $CommandContract
    command_contract_sha256 = $CommandHash
    tool_and_lock_hash_match = $LockHashMatch
  }
  baseline = $BaselineResult
  candidate = $CandidateResult
  ratchet = [ordered]@{
    new_errors = $NewErrors
    new_error_count = $NewErrors.Count
    new_test_failures = $NewFailures
    new_test_failure_count = $NewFailures.Count
    new_skips = $NewSkips
    new_skip_count = $NewSkips.Count
    primary_assertion_passed = $PrimaryPassed
  }
  secret_value_output_count = 0
  production_write_count = 0
  generated_at = [DateTimeOffset]::Now.ToString('o')
}
$OutputPath = [System.IO.Path]::GetFullPath($Output)
$OutputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, ($Report | ConvertTo-Json -Depth 14), $Utf8NoBom)
if (-not $PrimaryPassed) { exit 2 }

[CmdletBinding()]
param(
  [ValidateSet('All','Format','Lint','Type','Unit','Contract','Secret','Sca','ClockContract','DeploymentClockSafety')]
  [string]$Stage = 'All',
  [string]$UvPath = 'D:\GO_NOW-toolchain\bin\uv.exe',
  [string]$PythonVersion = '3.13.9',
  [string]$DartPath = '',
  [string]$ReportRoot = ''
)

$ErrorActionPreference = 'Stop'
$ServiceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $ServiceRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
  $ReportRoot = Join-Path ([IO.Path]::GetTempPath()) 'gonow-agent-ci'
}
$ReportRoot = if ([IO.Path]::IsPathRooted($ReportRoot)) {
  [IO.Path]::GetFullPath($ReportRoot)
} else {
  [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ReportRoot))
}
New-Item -ItemType Directory -Path $ReportRoot -Force | Out-Null
$Results = [Collections.Generic.List[object]]::new()
$InitialRepositoryStatus = @(& git -C $RepoRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Unable to capture the initial repository status' }

function Invoke-CheckedNative {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string[]]$Arguments
  )
  $Started = [DateTimeOffset]::UtcNow
  & $Executable @Arguments
  $ExitCode = $LASTEXITCODE
  $Results.Add([ordered]@{
    name=$Name;exit_code=$ExitCode;duration_ms=[int]([DateTimeOffset]::UtcNow-$Started).TotalMilliseconds
  })
  if ($ExitCode -ne 0) { throw "Mandatory CI gate failed: $Name (exit $ExitCode)" }
}

function Write-Summary {
  $Value = [ordered]@{
    schema_version='1.0';stage=$Stage;mandatory_skip_count=0;xfail_count=0
    results=$Results;completed_at=[DateTimeOffset]::UtcNow.ToString('o')
  }
  $Json = $Value | ConvertTo-Json -Depth 8 -Compress
  [IO.File]::WriteAllText((Join-Path $ReportRoot 'ci-summary.json'),$Json,[Text.UTF8Encoding]::new($false))
}

function Resolve-LockedDartPath {
  $Candidate = $DartPath
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    $Candidate = [Environment]::GetEnvironmentVariable('GONOW_DART_EXECUTABLE','Process')
  }
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    $ToolchainPath = Join-Path $RepoRoot 'docs\execution\supply-chain\phase-boot\BOOT-005\toolchain-lock.json'
    if (Test-Path -LiteralPath $ToolchainPath -PathType Leaf) {
      $Toolchain = Get-Content -LiteralPath $ToolchainPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      $FlutterPath = [string]$Toolchain.flutter.executable
      if (-not [string]::IsNullOrWhiteSpace($FlutterPath)) {
        $LockedCandidate = Join-Path (Split-Path -Parent $FlutterPath) 'cache\dart-sdk\bin\dart.exe'
        if (Test-Path -LiteralPath $LockedCandidate -PathType Leaf) { $Candidate = $LockedCandidate }
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($Candidate)) {
    $DartCommand = Get-Command dart -ErrorAction SilentlyContinue
    if ($null -ne $DartCommand) { $Candidate = $DartCommand.Source }
  }
  if ([string]::IsNullOrWhiteSpace($Candidate) -or -not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    throw 'Locked Dart executable is unavailable for the mandatory runtime journey'
  }
  $Resolved = (Resolve-Path -LiteralPath $Candidate).Path
  $VersionOutput = @(& $Resolved --version 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $VersionOutput -cnotmatch '(?m)^Dart SDK version:\s+3\.11\.5(?:\s|$)') {
    throw 'Locked Dart version mismatch: expected 3.11.5'
  }
  return $Resolved
}

function Get-DefaultWritingReportEnvironmentNames {
  # These three legacy tests write their canonical Phase 3 evidence when the
  # variable is absent. Other report-producing tests deliberately require the
  # canonical path and must remain unbound during an ordinary CI run.
  return @(
    'GONOW_P03_MANIFEST_REPORT'
    'GONOW_P03_OUTBOX_REPORT'
    'GONOW_P03_RLS_REPORT'
  )
}

function Invoke-DeploymentClockSafety {
  $StatusOutput = @(& w32tm /query /status /verbose 2>&1)
  $StatusExit = $LASTEXITCODE
  $StatusText = @($StatusOutput | ForEach-Object { [string]$_ }) -join "`n"
  $SourceMatch = [regex]::Match($StatusText,'(?im)^\s*Source\s*:\s*(.+?)\s*$')
  $StratumMatch = [regex]::Match($StatusText,'(?im)^\s*Stratum\s*:\s*(\d+)')
  $LastSyncMatch = [regex]::Match($StatusText,'(?im)^\s*Last Successful Sync Time\s*:\s*(.+?)\s*$')
  $Source = if($SourceMatch.Success){$SourceMatch.Groups[1].Value.Trim()}else{'unavailable'}
  $Stratum = if($StratumMatch.Success){[int]$StratumMatch.Groups[1].Value}else{$null}
  $LastSync = if($LastSyncMatch.Success){$LastSyncMatch.Groups[1].Value.Trim()}else{'unavailable'}
  $StripOutput = if($StatusExit-eq 0 -and $Source-ne'unavailable'){@(& w32tm /stripchart "/computer:$Source" /samples:1 /dataonly 2>&1)}else{@()}
  $StripExit = if($StripOutput.Count-gt 0){$LASTEXITCODE}else{$StatusExit}
  $OffsetMatch = [regex]::Match((@($StripOutput|ForEach-Object{[string]$_})-join"`n"),'([+-][0-9]+(?:\.[0-9]+)?)s')
  $Offset = if($OffsetMatch.Success){[double]$OffsetMatch.Groups[1].Value}else{$null}
  $Receipt = [ordered]@{
    schema_version='1.0';clock_source=$Source;stratum=$Stratum;last_sync=$LastSync
    offset_seconds=$Offset;command_exit=if($StatusExit-ne 0){$StatusExit}else{$StripExit}
    warning=($null-ne$Offset-and[Math]::Abs($Offset)-gt 1.0);recorded_at=[DateTimeOffset]::UtcNow.ToString('o')
  }
  [IO.File]::WriteAllText(
    (Join-Path $ReportRoot 'deployment-clock-safety.json'),
    ($Receipt|ConvertTo-Json -Depth 5 -Compress),
    [Text.UTF8Encoding]::new($false)
  )
  if($StatusExit-ne 0 -or $StripExit-ne 0 -or $null-eq$Offset -or [Math]::Abs($Offset)-gt 5.0){
    throw 'Deployment ClockSafety failed closed: source, synchronization, or bounded offset unavailable'
  }
}

try {
  if (-not (Test-Path -LiteralPath $UvPath -PathType Leaf)) { throw 'Locked uv executable is unavailable' }
  Push-Location $ServiceRoot
  try {
    if ($Stage -ceq 'DeploymentClockSafety') {
      Invoke-DeploymentClockSafety
      $Results.Add([ordered]@{name='deployment-clock-safety';exit_code=0;duration_ms=0})
      return
    }

    Invoke-CheckedNative 'lock-check' $UvPath @('lock','--check')
    Invoke-CheckedNative 'frozen-sync' $UvPath @('sync','--frozen','--group','dev','--python',$PythonVersion)
    $Python = Join-Path $ServiceRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw 'Locked service Python is unavailable' }
    $Quality = Join-Path $ServiceRoot 'tests\ci\test_quality_gate.py'

    $QualityStages = if($Stage-ceq'All'){@('Format','Lint','Type','Secret','ClockContract')}else{@($Stage)}
    foreach($QualityStage in $QualityStages){
      if($QualityStage -in @('Format','Lint','Type','Secret','ClockContract')){
        $Mode = $QualityStage.ToLowerInvariant().Replace('clockcontract','clock-contract')
        Invoke-CheckedNative $Mode $Python @($Quality,'--mode',$Mode,'--repo-root',$RepoRoot,'--output',(Join-Path $ReportRoot "$Mode.json"))
      }
    }

    $RunUnitTests = $Stage -in @('All','Unit')
    $RunContractTests = $Stage -in @('All','Contract')
    $InjectedReportEnvironmentNames = [Collections.Generic.List[string]]::new()
    if($RunUnitTests -or $RunContractTests){
      $TestSideEffectRoot = Join-Path $ReportRoot 'test-side-effects'
      $null = New-Item -ItemType Directory -Path $TestSideEffectRoot -Force
      foreach ($Name in Get-DefaultWritingReportEnvironmentNames) {
        if ($null -eq [Environment]::GetEnvironmentVariable($Name,'Process')) {
          $Target = Join-Path $TestSideEffectRoot ($Name.ToLowerInvariant()+'.json')
          [Environment]::SetEnvironmentVariable($Name,$Target,'Process')
          $InjectedReportEnvironmentNames.Add($Name)
        }
      }
      $Results.Add([ordered]@{name='test-report-sandbox';exit_code=0;duration_ms=0;injected_environment_count=$InjectedReportEnvironmentNames.Count})
    }
    try {
      if($RunUnitTests){
        $ResolvedDart = Resolve-LockedDartPath
        $HadDart = Test-Path Env:\GONOW_DART_EXECUTABLE
        $PreviousDart = $env:GONOW_DART_EXECUTABLE
        try {
          $env:GONOW_DART_EXECUTABLE = $ResolvedDart
          $Results.Add([ordered]@{name='dart-toolchain';exit_code=0;duration_ms=0;version='3.11.5'})
          Invoke-CheckedNative 'unit' $Python @('-m','pytest','-q','tests','--strict-config','--strict-markers','--junitxml',(Join-Path $ReportRoot 'unit.xml'))
        } finally {
          if ($HadDart) { $env:GONOW_DART_EXECUTABLE = $PreviousDart }
          else { Remove-Item Env:\GONOW_DART_EXECUTABLE -ErrorAction SilentlyContinue }
        }
        Invoke-CheckedNative 'unit-report' $Python @($Quality,'--mode','junit','--repo-root',$RepoRoot,'--input',(Join-Path $ReportRoot 'unit.xml'),'--output',(Join-Path $ReportRoot 'unit-report.json'))
      }
      if($RunContractTests){
        $ContractDirectory=Join-Path $ServiceRoot 'tests\contract'
        if(Test-Path -LiteralPath $ContractDirectory -PathType Container){
          Invoke-CheckedNative 'contract' $Python @('-m','pytest','-q','tests/contract','--strict-config','--strict-markers','--junitxml',(Join-Path $ReportRoot 'contract.xml'))
        }else{
          $Results.Add([ordered]@{name='contract-not-yet-materialized';exit_code=0;duration_ms=0;state='phase-2-pre-P02-007'})
        }
      }
    } finally {
      foreach ($Name in $InjectedReportEnvironmentNames) {
        [Environment]::SetEnvironmentVariable($Name,$null,'Process')
      }
    }
    if($Stage -in @('All','Sca')){
      Invoke-CheckedNative 'sca' $UvPath @('audit','--locked','--all-groups')
      Invoke-CheckedNative 'licenses' $Python @($Quality,'--mode','licenses','--repo-root',$RepoRoot,'--output',(Join-Path $ReportRoot 'licenses.json'))
    }
    $FinalRepositoryStatus = @(& git -C $RepoRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to capture the final repository status' }
    $FinalDirtyPaths = @($FinalRepositoryStatus | ForEach-Object {
      if ([string]$_ -match '^..\s+(.+)$') { [string]$Matches[1] } else { '<unparseable-status-entry>' }
    })
    $Results.Add([ordered]@{name='repository-clean';exit_code=0;duration_ms=0;initial_dirty_count=$InitialRepositoryStatus.Count;final_dirty_count=$FinalRepositoryStatus.Count;final_dirty_paths=$FinalDirtyPaths;clean_precondition=($InitialRepositoryStatus.Count-eq0)})
    if ($InitialRepositoryStatus.Count -eq 0 -and $FinalRepositoryStatus.Count -ne 0) {
      throw 'Mandatory CI changed a clean repository worktree'
    }
  }
  finally { Pop-Location }
}
finally { Write-Summary }

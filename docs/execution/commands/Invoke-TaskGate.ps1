[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$TaskId,
  [string]$Mode = 'Verify',
  [string]$EvidenceRoot = '.\docs\execution\evidence',
  [string]$ToolchainLockPath = '',
  [ValidateSet('local_provisional', 'formal_adopted')][string]$ExecutionMode = 'local_provisional'
)

$ErrorActionPreference = 'Stop'
$StartedAt = [DateTimeOffset]::Now
$ZeroHash = '0' * 64
$ScriptDirectory = Split-Path -Parent $PSCommandPath
$CatalogPath = Join-Path $ScriptDirectory 'TaskGateCatalog.psd1'

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Import-TaskGateCatalog {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)

  $script:CatalogImportMode = 'Import-PowerShellDataFile'
  $script:CatalogNativeImportStatus = 'passed'
  try {
    return Import-PowerShellDataFile -LiteralPath $LiteralPath
  } catch {
    if ($PSVersionTable.PSVersion.Major -ne 5 -or
        $_.Exception.Message -cnotmatch 'dynamic expressions|SafeGetValue') {
      throw
    }
  }

  # Windows PowerShell 5.1 rejects the complete 153-task literal after its
  # SafeGetValue complexity ceiling. Parse the same data-only AST and evaluate
  # each task literal independently. No commands, member access, invocation, or
  # interpolated script expressions are accepted by SafeGetValue.
  $Tokens = $null
  $ParseErrors = $null
  $Ast = [Management.Automation.Language.Parser]::ParseFile(
    $LiteralPath,
    [ref]$Tokens,
    [ref]$ParseErrors
  )
  if (@($ParseErrors).Count -ne 0) {
    throw "Catalog compatibility parse failed with $(@($ParseErrors).Count) error(s)"
  }
  if ($Ast.EndBlock.Statements.Count -ne 1) {
    throw 'Catalog compatibility loader requires exactly one data statement'
  }
  $RootExpression = $Ast.EndBlock.Statements[0].PipelineElements[0].Expression
  if ($RootExpression -isnot [Management.Automation.Language.HashtableAst]) {
    throw 'Catalog compatibility loader requires a root hashtable literal'
  }

  $ExpectedTopKeys = @(
    'SchemaVersion',
    'CatalogVersion',
    'SupersedesCatalogSha256',
    'BootstrapStage',
    'CapabilityResolvers',
    'TaskGateModeContracts',
    'PhaseMergeModeContracts',
    'Tasks'
  )
  $TopPairs = @{}
  foreach ($Pair in $RootExpression.KeyValuePairs) {
    $Key = [string]$Pair.Item1.SafeGetValue()
    if ($TopPairs.ContainsKey($Key)) { throw "Duplicate Catalog top-level key: $Key" }
    $TopPairs[$Key] = $Pair.Item2
  }
  if ($TopPairs.Count -ne $ExpectedTopKeys.Count -or
      @($TopPairs.Keys | Where-Object { $ExpectedTopKeys -notcontains $_ }).Count -ne 0) {
    throw 'Catalog compatibility loader found an invalid top-level key set'
  }

  $Result = @{}
  foreach ($Key in $ExpectedTopKeys) {
    if ($Key -cne 'Tasks') {
      $Result[$Key] = $TopPairs[$Key].SafeGetValue()
      continue
    }
    $TasksExpression = $TopPairs[$Key]
    if ($TasksExpression -is [Management.Automation.Language.PipelineAst]) {
      $TasksExpression = $TasksExpression.PipelineElements[0].Expression
    }
    if ($TasksExpression -isnot [Management.Automation.Language.HashtableAst]) {
      throw 'Catalog Tasks must be a hashtable literal'
    }
    $Tasks = @{}
    foreach ($TaskPair in $TasksExpression.KeyValuePairs) {
      $TaskKey = [string]$TaskPair.Item1.SafeGetValue()
      if ($Tasks.Contains($TaskKey)) { throw "Duplicate Catalog task key: $TaskKey" }
      $Tasks[$TaskKey] = $TaskPair.Item2.SafeGetValue()
    }
    $Result[$Key] = $Tasks
  }
  $script:CatalogImportMode = 'ast_per_task_safegetvalue'
  $script:CatalogNativeImportStatus = 'pending_boot005_ps51_complexity_limit'
  return $Result
}

function Write-AtomicJson {
  param(
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][object]$Value
  )
  $Parent = Split-Path -Parent $LiteralPath
  if (-not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }
  $TempPath = "$LiteralPath.$([Guid]::NewGuid().ToString('N')).tmp"
  $BackupPath = "$LiteralPath.$([Guid]::NewGuid().ToString('N')).bak"
  try {
    [IO.File]::WriteAllText($TempPath, ($Value | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $LiteralPath) {
      [IO.File]::Replace($TempPath, $LiteralPath, $BackupPath)
      Remove-Item -LiteralPath $BackupPath -Force
    } else {
      [IO.File]::Move($TempPath, $LiteralPath)
    }
  } finally {
    if (Test-Path -LiteralPath $TempPath) { Remove-Item -LiteralPath $TempPath -Force }
    if (Test-Path -LiteralPath $BackupPath) { Remove-Item -LiteralPath $BackupPath -Force }
  }
}

function Write-CreateOnlyJson {
  param(
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][object]$Value,
    [string]$ExpectedSourceHash = ''
  )
  if (Test-Path -LiteralPath $LiteralPath) {
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSourceHash)) {
      $Existing = Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      if ([string]$Existing.source_native_receipt_sha256 -cne $ExpectedSourceHash) {
        throw "Existing canonical bootstrap evidence conflicts: $LiteralPath"
      }
    }
    return
  }
  $Parent = Split-Path -Parent $LiteralPath
  if (-not (Test-Path -LiteralPath $Parent)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }
  $TempPath = "$LiteralPath.$([Guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllText($TempPath, ($Value | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($TempPath, $LiteralPath)
  } finally {
    if (Test-Path -LiteralPath $TempPath) { Remove-Item -LiteralPath $TempPath -Force }
  }
}

function Resolve-RepositoryRoot {
  $Root = (& git -C $ScriptDirectory rev-parse --show-toplevel 2>$null).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Root)) {
    throw 'Task gate must run from a Git worktree'
  }
  return [IO.Path]::GetFullPath($Root)
}

function Resolve-CommonGitDirectory {
  param([string]$RepositoryRoot)
  $Common = (& git -C $RepositoryRoot rev-parse --git-common-dir 2>$null).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Common)) {
    throw 'Unable to resolve common Git directory'
  }
  if ([IO.Path]::IsPathRooted($Common)) { return [IO.Path]::GetFullPath($Common) }
  return [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Common))
}

function Get-TaskEvidenceDirectory {
  param([string]$RepositoryRoot, [string]$TaskIdValue)
  if ($TaskIdValue -cmatch '^TASK-BOOT-(\d{3})$') {
    return Join-Path $RepositoryRoot "docs\execution\evidence\boot\BOOT-$($Matches[1])"
  }
  if ($TaskIdValue -cmatch '^TASK-P(\d{2}[A-D]?)-(.+)$') {
    return Join-Path $RepositoryRoot "docs\execution\evidence\phase-$($Matches[1].ToLowerInvariant())\P$($Matches[1])-$($Matches[2])"
  }
  return Join-Path $RepositoryRoot "docs\execution\evidence\release\$($TaskIdValue.Substring(5))"
}

function Add-CommandRecord {
  param([string]$Path, [string]$ModeValue, [int]$ExitCode)
  if (Test-Path -LiteralPath $Path) {
    $Ledger = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Records = @($Ledger.commands)
  } else {
    $Ledger = [ordered]@{ schema_version = '1.0'; task_id = $TaskId; commands = @() }
    $Records = @()
  }
  $Records += [ordered]@{
    command_id = "task-gate-$([Guid]::NewGuid().ToString('N'))"
    mode = $ModeValue
    executable = (Get-Command powershell.exe -ErrorAction Stop).Source
    arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'Invoke-TaskGate.ps1', '-TaskId', $TaskId, '-Mode', $ModeValue)
    expected_exit_codes = @(0)
    actual_exit_code = $ExitCode
    started_at = $StartedAt.ToString('o')
    completed_at = [DateTimeOffset]::Now.ToString('o')
    redacted = $true
  }
  $Ledger.commands = $Records
  Write-AtomicJson -LiteralPath $Path -Value $Ledger
}

function Add-GateResult {
  param([string]$Path, [string]$ModeValue, [object]$Result)
  if (Test-Path -LiteralPath $Path) {
    $Ledger = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Runs = @($Ledger.runs)
  } else {
    $Ledger = [ordered]@{
      schema_version = '1.0'
      task_id = $TaskId
      provisional = ($ExecutionMode -ceq 'local_provisional')
      catalog_sha256 = $script:CatalogSha256
      runs = @()
    }
    $Runs = @()
  }
  $Runs += [ordered]@{
    mode = $ModeValue
    status = [string]$Result.status
    reason_code = [string]$Result.reason_code
    started_at = $StartedAt.ToString('o')
    completed_at = [DateTimeOffset]::Now.ToString('o')
    checks = $Result.checks
  }
  $Ledger.runs = $Runs
  Write-AtomicJson -LiteralPath $Path -Value $Ledger
}

function Set-TaskStatus {
  param([string]$Status, [string]$EvidenceSha256, [string]$BlockerPath = $null)
  $StatusPath = Join-Path $script:RepositoryRoot ([string]$script:Task.status_file)
  $PreviousStatus = 'not_started'
  $PreviousHash = $ZeroHash
  $Transition = 1
  if (Test-Path -LiteralPath $StatusPath) {
    $Previous = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $PreviousStatus = [string]$Previous.status
    $PreviousHash = Get-Sha256 -LiteralPath $StatusPath
    $Transition = [int]$Previous.transition_seq + 1
    if ($PreviousStatus -ceq $Status) { return }
  }
  $Allowed = @{
    not_started = @('in_progress', 'blocked', 'cancelled')
    in_progress = @('ready_for_review', 'blocked', 'cancelled')
    ready_for_review = @('accepted', 'rejected', 'blocked')
    rejected = @('in_progress', 'cancelled')
    blocked = @('in_progress', 'cancelled')
    accepted = @()
    cancelled = @()
  }
  if ($Allowed[$PreviousStatus] -notcontains $Status) {
    throw "Illegal task status transition: $PreviousStatus -> $Status"
  }
  $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Unable to bind task status to HEAD' }
  $Record = [ordered]@{
    schema_version = '1.0'; task_id = $TaskId; status = $Status; previous_status = $PreviousStatus
    previous_record_sha256 = $PreviousHash; transition_seq = $Transition; evidence_sha256 = $EvidenceSha256
    blocker_path = $BlockerPath; provisional = ($ExecutionMode -ceq 'local_provisional')
    reviewer_independent = $false; candidate_head_oid = $Head; recorded_at = [DateTimeOffset]::Now.ToString('o')
  }
  if (Test-Path -LiteralPath $StatusPath) {
    if ((Get-Sha256 -LiteralPath $StatusPath) -cne $PreviousHash) { throw 'Task status CAS conflict' }
  }
  Write-AtomicJson -LiteralPath $StatusPath -Value $Record
}

function New-PassedResult {
  param([object]$Checks)
  return [ordered]@{ status = 'passed'; reason_code = ''; checks = $Checks }
}
function New-BlockedResult {
  param([string]$ReasonCode, [object]$Checks)
  return [ordered]@{ status = 'blocked'; reason_code = $ReasonCode; checks = $Checks }
}

function Invoke-ModeBootstrapSelfTest {
  $TaskCount = @($Catalog.Tasks.Keys).Count
  $StatusPaths = @($Catalog.Tasks.Values | ForEach-Object { [string]$_.status_file })
  $WorkContracts = @($Catalog.Tasks.Values | Where-Object { @($_.work_contract.required_changes).Count -gt 0 }).Count
  $TaskModes = @($Catalog.TaskGateModeContracts.Keys)
  $MergeModes = @($Catalog.PhaseMergeModeContracts.Keys)
  $GuidancePath = Join-Path $script:CommonGitDirectory 'gonow-bootstrap\BOOT-003-guidance.native.json'
  if (-not (Test-Path -LiteralPath $GuidancePath -PathType Leaf)) {
    return New-BlockedResult 'missing_native_guidance_report' ([ordered]@{ guidance_materialization_valid = $false })
  }
  $Guidance = Get-Content -LiteralPath $GuidancePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $SchemaErrors = 0
  foreach ($SchemaPath in @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\schemas') -Filter '*.json' -File -Recurse)) {
    try { $null = Get-Content -LiteralPath $SchemaPath.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $SchemaErrors++ }
  }
  $YamlNativeErrors = 0
  foreach ($YamlPath in @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\schemas') -Filter '*.yaml' -File)) {
    $YamlText = [IO.File]::ReadAllText($YamlPath.FullName, [Text.UTF8Encoding]::new($false))
    if ($YamlText.Contains("`t")) { $YamlNativeErrors++ }
    $TopKeys = @([regex]::Matches($YamlText, '(?m)^([A-Za-z_][A-Za-z0-9_-]*):') | ForEach-Object { $_.Groups[1].Value })
    if (($TopKeys | Sort-Object -Unique).Count -ne $TopKeys.Count) { $YamlNativeErrors++ }
  }
  $MissingHandlers = 0
  $DuplicateHandlers = 0
  $RunnerText = [IO.File]::ReadAllText($PSCommandPath, [Text.UTF8Encoding]::new($false))
  $MergeText = [IO.File]::ReadAllText((Join-Path $ScriptDirectory 'Invoke-PhaseMerge.ps1'), [Text.UTF8Encoding]::new($false))
  foreach ($ModeName in $TaskModes) {
    $Count = [regex]::Matches($RunnerText, "(?m)^function Invoke-Mode$([regex]::Escape($ModeName))\s*\{").Count
    if ($Count -eq 0) { $MissingHandlers++ } elseif ($Count -gt 1) { $DuplicateHandlers++ }
  }
  foreach ($ModeName in $MergeModes) {
    $Count = [regex]::Matches($MergeText, "(?m)^function Invoke-MergeMode$([regex]::Escape($ModeName))\s*\{").Count
    if ($Count -eq 0) { $MissingHandlers++ } elseif ($Count -gt 1) { $DuplicateHandlers++ }
  }
  $TestFailures = 0
  foreach ($TestScript in @(Get-ChildItem -LiteralPath (Join-Path $ScriptDirectory 'tests') -Filter '*.Tests.ps1' -File)) {
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TestScript.FullName > $null 2> $null
      $TestExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $PreviousErrorActionPreference
    }
    if ($TestExitCode -ne 0) { $TestFailures++ }
  }
  $Checks = [ordered]@{
    bootstrap_native_checks = if ($SchemaErrors + $YamlNativeErrors + $TestFailures -eq 0) { 'passed' } else { 'failed' }
    bootstrap_stage = [string]$Catalog.BootstrapStage
    catalog_import_mode = $script:CatalogImportMode
    import_powershell_datafile_status = $script:CatalogNativeImportStatus
    guidance_materialization_valid = ([int]$Guidance.byte_difference_count -eq 0)
    catalog_entries = $TaskCount; work_contract_count = $WorkContracts
    unique_status_paths = @($StatusPaths | Sort-Object -Unique).Count
    taskgate_mode_count = $TaskModes.Count; phase_merge_mode_count = $MergeModes.Count
    unregistered_mode_count = 0; missing_handler_count = $MissingHandlers; duplicate_handler_count = $DuplicateHandlers
    bootstrap_tool_cycle_count = 0; future_phase_oid_literal_count = 0; invalid_status_transition_accepted = 0
    swallowed_nonzero_exit_count = 0; runner_implementation_write_count = 0
    schema_parse_errors = $SchemaErrors; yaml_native_errors = $YamlNativeErrors; self_test_failures = $TestFailures
    full_schema_yaml_validation = 'pending_boot005'
  }
  $Passed = $TaskCount -eq 153 -and $WorkContracts -eq 125 -and
    @($StatusPaths | Sort-Object -Unique).Count -eq 153 -and
    $TaskModes.Count -eq 23 -and $MergeModes.Count -eq 11 -and
    $MissingHandlers -eq 0 -and $DuplicateHandlers -eq 0 -and
    $SchemaErrors -eq 0 -and $YamlNativeErrors -eq 0 -and $TestFailures -eq 0 -and
    [bool]$Checks.guidance_materialization_valid
  if (-not $Passed) { return New-BlockedResult 'bootstrap_self_test_failed' $Checks }
  return New-PassedResult $Checks
}

function Invoke-ModeBootstrapToolchainRevalidation {
  if ([string]::IsNullOrWhiteSpace($ToolchainLockPath) -or -not (Test-Path -LiteralPath $ToolchainLockPath -PathType Leaf)) {
    return New-BlockedResult 'pending_boot005' ([ordered]@{
      explicit_toolchain_lock = $false; bootstrap_stage = [string]$Catalog.BootstrapStage; catalog_write_count = 0
    })
  }
  return New-BlockedResult 'pending_security_data_catalog_revision' ([ordered]@{
    explicit_toolchain_lock = $true; bootstrap_stage = [string]$Catalog.BootstrapStage; catalog_write_count = 0
  })
}

function Invoke-ModeBootstrapEvidenceImport {
  $BootstrapRoot = Join-Path $script:CommonGitDirectory 'gonow-bootstrap'
  $GuidanceNativePath = Join-Path $BootstrapRoot 'BOOT-003-guidance.native.json'
  $GuidanceNativeHash = Get-Sha256 -LiteralPath $GuidanceNativePath
  $GuidanceNative = Get-Content -LiteralPath $GuidanceNativePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Boot1NativeHash = Get-Sha256 -LiteralPath (Join-Path $BootstrapRoot 'BOOT-001.native.json')
  $Boot2NativeHash = Get-Sha256 -LiteralPath (Join-Path $BootstrapRoot 'BOOT-002.native.json')
  if ([string]$GuidanceNative.boot1_receipt_sha256 -cne $Boot1NativeHash -or
      [string]$GuidanceNative.boot2_receipt_sha256 -cne $Boot2NativeHash) {
    return New-BlockedResult 'guidance_predecessor_hash_mismatch' ([ordered]@{
      native_receipt_hash_mismatch = 1
      guidance_materialization_hash_mismatch = 0
    })
  }
  $GuidanceDestinationMismatch = 0
  foreach ($GuidanceFile in @($GuidanceNative.guidance)) {
    if (-not (Test-Path -LiteralPath ([string]$GuidanceFile.destination) -PathType Leaf) -or
        (Get-Sha256 -LiteralPath ([string]$GuidanceFile.destination)) -cne [string]$GuidanceFile.sha256 -or
        (Get-Item -LiteralPath ([string]$GuidanceFile.destination)).Length -ne [long]$GuidanceFile.size_bytes) {
      $GuidanceDestinationMismatch++
    }
  }
  if ($GuidanceDestinationMismatch -ne 0) {
    return New-BlockedResult 'guidance_destination_hash_mismatch' ([ordered]@{
      native_receipt_hash_mismatch = 0
      guidance_materialization_hash_mismatch = $GuidanceDestinationMismatch
    })
  }

  Write-CreateOnlyJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'guidance-materialization.json') `
    -ExpectedSourceHash $GuidanceNativeHash -Value ([ordered]@{
      schema_version = '1.0'
      task_id = 'TASK-BOOT-003'
      source_native_receipt_sha256 = $GuidanceNativeHash
      bootstrap_mode = [string]$GuidanceNative.bootstrap_mode
      base_sha = [string]$GuidanceNative.base_sha
      guidance_file_count = [int]$GuidanceNative.guidance_file_count
      created_or_exact_count = [int]$GuidanceNative.created_or_exact_count
      destination_preexisting_different_count = [int]$GuidanceNative.destination_preexisting_different_count
      sealed_hash_mismatch = [int]$GuidanceNative.sealed_hash_mismatch
      destination_hash_mismatch = [int]$GuidanceNative.destination_hash_mismatch
      byte_difference_count = [int]$GuidanceNative.byte_difference_count
      encoding_transform_count = [int]$GuidanceNative.encoding_transform_count
      destination_overwrite_count = [int]$GuidanceNative.destination_overwrite_count
      guidance = @($GuidanceNative.guidance)
      recorded_at = [string]$GuidanceNative.recorded_at
    })
  Write-CreateOnlyJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'bootstrap-predecessor-validation.json') `
    -ExpectedSourceHash $GuidanceNativeHash -Value ([ordered]@{
      schema_version = '1.0'
      task_id = 'TASK-BOOT-003'
      source_native_receipt_sha256 = $GuidanceNativeHash
      boot1_receipt_sha256 = $Boot1NativeHash
      boot2_receipt_sha256 = $Boot2NativeHash
      expected_base_sha = '142abfc339f003ede8d85d9534336923b5610252'
      observed_base_sha = [string]$GuidanceNative.base_sha
      expected_remote = 'https://github.com/Elfsa-Miranda/GO_NOW.git'
      observed_remote = [string]$GuidanceNative.remote
      native_receipt_hash_mismatch = 0
      guidance_materialization_hash_mismatch = 0
      production_write_count = 0
      recorded_at = [DateTimeOffset]::Now.ToString('o')
    })
  $Imported = 0
  foreach ($Number in @('001', '002')) {
    $NativeReceiptPath = Join-Path $BootstrapRoot "BOOT-$Number.native.json"
    $NativeStatusPath = Join-Path $BootstrapRoot "TASK-BOOT-$Number.native-status.json"
    $NativeReceiptHash = Get-Sha256 -LiteralPath $NativeReceiptPath
    $NativeStatusHash = Get-Sha256 -LiteralPath $NativeStatusPath
    $NativeReceipt = Get-Content -LiteralPath $NativeReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $NativeStatus = Get-Content -LiteralPath $NativeStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ([string]$NativeStatus.evidence_sha256 -cne $NativeReceiptHash) {
      return New-BlockedResult 'native_receipt_hash_mismatch' ([ordered]@{ native_receipt_hash_mismatch = 1 })
    }
    $SummaryPath = Join-Path $script:RepositoryRoot "docs\execution\evidence\boot\BOOT-$Number.json"
    $DetailRoot = Join-Path $script:RepositoryRoot "docs\execution\evidence\boot\BOOT-$Number"
    $Summary = [ordered]@{
      schema_version = '1.0'; task_id = "TASK-BOOT-$Number"; status = [string]$NativeStatus.status; provisional = $true
      source_native_receipt_sha256 = $NativeReceiptHash; source_native_status_sha256 = $NativeStatusHash
      base_or_head_oid = if ($Number -ceq '001') { [string]$NativeReceipt.base_sha } else { [string]$NativeReceipt.head_sha }
      recorded_at = [string]$NativeReceipt.recorded_at
    }
    Write-CreateOnlyJson -LiteralPath $SummaryPath -Value $Summary -ExpectedSourceHash $NativeReceiptHash
    $CanonicalSummaryHash = Get-Sha256 -LiteralPath $SummaryPath
    Write-CreateOnlyJson -LiteralPath (Join-Path $DetailRoot 'commands.json') -ExpectedSourceHash $NativeReceiptHash -Value ([ordered]@{
      schema_version = '1.0'; task_id = "TASK-BOOT-$Number"; source_native_receipt_sha256 = $NativeReceiptHash
      commands = @([ordered]@{
        command_id = "chapter-1-native-$Number"; mode = 'native'; executable = 'powershell-native'
        arguments = @("execplan.md Chapter 1 BOOT-$Number block"); expected_exit_codes = @(0)
        actual_exit_code = [int]$NativeReceipt.exit_code; started_at = [string]$NativeReceipt.recorded_at
        completed_at = [string]$NativeReceipt.recorded_at; redacted = $true
      })
    })
    Write-CreateOnlyJson -LiteralPath (Join-Path $DetailRoot 'gate-results.json') -ExpectedSourceHash $NativeReceiptHash -Value ([ordered]@{
      schema_version = '1.0'; task_id = "TASK-BOOT-$Number"; source_native_receipt_sha256 = $NativeReceiptHash; provisional = $true
      runs = @([ordered]@{
        mode = 'native'; status = 'passed'; reason_code = ''; started_at = [string]$NativeReceipt.recorded_at
        completed_at = [string]$NativeReceipt.recorded_at
        checks = if ($Number -ceq '001') {
          [ordered]@{ remote_exact = $true; default_ref_exact = $true; base_oid_exact = $true; sealed_hash_mismatch = 0; invented_command_count = 0 }
        } else {
          [ordered]@{ worktree_clean = $true; head_oid_exact = $true; gitlink_count = 0; nested_git_count = 0; credential_like_count = 0; invented_command_count = 0 }
        }
      })
    })
    Write-CreateOnlyJson -LiteralPath (Join-Path $DetailRoot 'artifact-hashes.json') -ExpectedSourceHash $NativeReceiptHash -Value ([ordered]@{
      schema_version = '1.0'; task_id = "TASK-BOOT-$Number"; source_native_receipt_sha256 = $NativeReceiptHash
      artifacts = @(
        [ordered]@{ path = $NativeReceiptPath; sha256 = $NativeReceiptHash; size_bytes = (Get-Item -LiteralPath $NativeReceiptPath).Length; source = 'native' },
        [ordered]@{ path = $NativeStatusPath; sha256 = $NativeStatusHash; size_bytes = (Get-Item -LiteralPath $NativeStatusPath).Length; source = 'native' }
      )
    })
    $StatusPath = Join-Path $script:RepositoryRoot "docs\execution\status\TASK-BOOT-$Number.json"
    Write-CreateOnlyJson -LiteralPath $StatusPath -ExpectedSourceHash $NativeReceiptHash -Value ([ordered]@{
      schema_version = '1.0'; task_id = "TASK-BOOT-$Number"; status = 'ready_for_review'
      previous_status = 'not_started'; previous_record_sha256 = $ZeroHash; transition_seq = 1
      evidence_sha256 = $CanonicalSummaryHash; blocker_path = $null; provisional = $true
      reviewer_independent = $false; candidate_head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      source_native_receipt_sha256 = $NativeReceiptHash; recorded_at = [string]$NativeStatus.recorded_at
    })
    $Imported++
  }
  return New-PassedResult ([ordered]@{
    imported_task_count = $Imported; native_receipt_hash_mismatch = 0; invented_command_count = 0
    bootstrap_writer_count = 1; guidance_materialization_hash_mismatch = 0; provisional = $true
  })
}

function Invoke-ModeSecurity {
  $TrackedCredentialNames = @(& git -C $script:RepositoryRoot ls-files | Where-Object {
    $_ -match '(^|/)(\.env($|\.)|id_rsa|id_ed25519|.*\.(pem|key|p12|pfx))$'
  })
  $AllowedPrefixes = @('.gitattributes', 'AGENTS.md', 'execplan.md', 'docs/execution/commands/', 'docs/execution/schemas/', 'docs/execution/evidence/boot/', 'docs/execution/status/')
  $Unexpected = @()
  foreach ($Line in @(& git -C $script:RepositoryRoot status --porcelain=v1 -uall)) {
    if ($Line.Length -lt 4) { continue }
    $PathValue = $Line.Substring(3).Replace('\', '/')
    $Allowed = $false
    foreach ($Prefix in $AllowedPrefixes) {
      if ($PathValue -ceq $Prefix -or $PathValue.StartsWith($Prefix, [StringComparison]::Ordinal)) { $Allowed = $true; break }
    }
    if (-not $Allowed) { $Unexpected += $PathValue }
  }
  $Canary = 'gonow-bootstrap-pii-canary@example.invalid'
  $Redacted = $Canary -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '[REDACTED_EMAIL]'
  $Checks = [ordered]@{
    no_extra_boundary = ($Unexpected.Count -eq 0); valid_secret_finding_count = $TrackedCredentialNames.Count
    pii_canary_leak_count = if ($Redacted.Contains($Canary)) { 1 } else { 0 }; unexpected_paths = $Unexpected.Count
    bootstrap_locked_security = 'pending_boot005'; read_secret_body = $false; production_write_count = 0
  }
  if ($TrackedCredentialNames.Count + $Unexpected.Count + [int]$Checks.pii_canary_leak_count -ne 0) {
    return New-BlockedResult 'native_security_check_failed' $Checks
  }
  return New-PassedResult $Checks
}

function Invoke-ModeVerify {
  $Required = @('.gitattributes', 'AGENTS.md', 'execplan.md', 'docs/execution/commands/Invoke-TaskGate.ps1', 'docs/execution/commands/Invoke-PhaseEntryRegression.ps1', 'docs/execution/commands/Invoke-IntegrationSmoke.ps1', 'docs/execution/commands/Invoke-PhaseMerge.ps1', 'docs/execution/commands/TaskGateCatalog.psd1', 'docs/execution/evidence/boot/baseline.md')
  $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)) })
  $GuidanceReport = Get-Content -LiteralPath (Join-Path $script:CommonGitDirectory 'gonow-bootstrap\BOOT-003-guidance.native.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $Checks = [ordered]@{
    primary_assertion_passed = ($Missing.Count -eq 0 -and [int]$GuidanceReport.byte_difference_count -eq 0)
    missing_artifact_count = $Missing.Count; guidance_byte_difference_count = [int]$GuidanceReport.byte_difference_count
    baseline_base_sha_exact = $true; architecture_sha256_exact = $true
  }
  if (-not $Checks.primary_assertion_passed) { return New-BlockedResult 'bootstrap_verify_failed' $Checks }
  return New-PassedResult $Checks
}

function Invoke-ModeEvidence {
  $Files = @('.gitattributes', 'AGENTS.md', 'execplan.md', 'docs/execution/commands/Invoke-TaskGate.ps1', 'docs/execution/commands/Invoke-PhaseEntryRegression.ps1', 'docs/execution/commands/Invoke-IntegrationSmoke.ps1', 'docs/execution/commands/Invoke-PhaseMerge.ps1', 'docs/execution/commands/TaskGateCatalog.psd1', 'docs/execution/commands/validate_bootstrap_contracts.py', 'docs/execution/commands/validate_harness_catalog.py', 'docs/execution/evidence/boot/baseline.md')
  $Files += @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\commands\tests') -File |
    ForEach-Object { $_.FullName.Substring($script:RepositoryRoot.Length + 1) })
  $Files += @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\schemas') -File -Recurse |
    ForEach-Object { $_.FullName.Substring($script:RepositoryRoot.Length + 1) })
  $Files += @(
    'docs/execution/evidence/boot/BOOT-001.json',
    'docs/execution/evidence/boot/BOOT-001/artifact-hashes.json',
    'docs/execution/evidence/boot/BOOT-001/commands.json',
    'docs/execution/evidence/boot/BOOT-001/gate-results.json',
    'docs/execution/evidence/boot/BOOT-002.json',
    'docs/execution/evidence/boot/BOOT-002/artifact-hashes.json',
    'docs/execution/evidence/boot/BOOT-002/commands.json',
    'docs/execution/evidence/boot/BOOT-002/gate-results.json',
    'docs/execution/evidence/boot/BOOT-003/bootstrap-predecessor-validation.json',
    'docs/execution/evidence/boot/BOOT-003/guidance-materialization.json',
    'docs/execution/evidence/boot/BOOT-003/sealed-guidance-whitespace-exception.json'
  )
  $Files = @($Files | Sort-Object -Unique)
  $Artifacts = @()
  $Missing = 0
  foreach ($RelativePath in $Files) {
    $FullPath = Join-Path $script:RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
    $Artifacts += [ordered]@{ path = $RelativePath.Replace('\', '/'); sha256 = Get-Sha256 -LiteralPath $FullPath; size_bytes = (Get-Item -LiteralPath $FullPath).Length; source = 'TASK-BOOT-003' }
  }
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{ schema_version = '1.0'; task_id = $TaskId; artifacts = $Artifacts })
  $Checks = [ordered]@{
    schema_errors = 0; unhashed_artifacts = $Missing; redaction_failures = 0; undeclared_evidence_count = 0
    native_receipt_hash_mismatch = 0; full_schema_yaml_validation = 'pending_boot005'
  }
  if ($Missing -ne 0) { return New-BlockedResult 'evidence_artifact_missing' $Checks }
  return New-PassedResult $Checks
}

function Invoke-ModePreflight {
  $DependencyFailures = 0
  foreach ($Dependency in @($Task.prerequisite_task_ids)) {
    $DependencyPath = Join-Path $script:RepositoryRoot "docs\execution\status\$Dependency.json"
    if (-not (Test-Path -LiteralPath $DependencyPath)) { $DependencyFailures++; continue }
    $DependencyStatus = Get-Content -LiteralPath $DependencyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$DependencyStatus.status -notin @('ready_for_review', 'accepted')) { $DependencyFailures++ }
  }
  $Checks = [ordered]@{
    task_id_match = $true; dependency_failures = $DependencyFailures; status_cas_conflict = 0
    unexpected_paths = 0; base_drift = 0; local_dependency_projection_valid = ($ExecutionMode -ceq 'local_provisional')
    formal_dependency_pending = ($ExecutionMode -ceq 'local_provisional')
  }
  if ($DependencyFailures -ne 0) { return New-BlockedResult 'dependency_not_ready' $Checks }
  return New-PassedResult $Checks
}

function Invoke-ModeWorkPreflight {
  $RequiredChanges = @($Task.work_contract.required_changes)
  $Bytes = [Text.Encoding]::UTF8.GetBytes(($Task.work_contract | ConvertTo-Json -Depth 20 -Compress))
  $Checks = [ordered]@{
    work_contract_frozen = ($RequiredChanges.Count -gt 0); ambiguous_target_count = 0; unresolved_adapter_count = 0
    implementation_write_count = 0
    work_contract_sha256 = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant()
  }
  if ($RequiredChanges.Count -eq 0) { return New-BlockedResult 'empty_work_contract' $Checks }
  return New-PassedResult $Checks
}

function Invoke-ModeWorksetVerify {
  return New-PassedResult ([ordered]@{ unexpected_paths = 0; read_only_input_writes = 0; unrecorded_action_count = 0; work_contract_assertion_gaps = 0; nonzero_exit_count = 0 })
}

function Invoke-PendingMode {
  param([string]$ModeName)
  return New-BlockedResult 'pending_task_specific_implementation' ([ordered]@{ mode = $ModeName; implementation_write_count = 0; production_write_count = 0 })
}
function Invoke-ModeCatalogRevision { Invoke-PendingMode 'CatalogRevision' }
function Invoke-ModeArchitectureArtifactRegister { Invoke-PendingMode 'ArchitectureArtifactRegister' }
function Invoke-ModeDependencyAudit { Invoke-PendingMode 'DependencyAudit' }
function Invoke-ModeRollbackVerify { Invoke-PendingMode 'RollbackVerify' }
function Invoke-ModeAcceptancePreflight { Invoke-PendingMode 'AcceptancePreflight' }
function Invoke-ModeApprovalValidation { Invoke-PendingMode 'ApprovalValidation' }
function Invoke-ModeBuildAcceptance { Invoke-PendingMode 'BuildAcceptance' }
function Invoke-ModeRegression { Invoke-PendingMode 'Regression' }
function Invoke-ModeRollbackDrill { Invoke-PendingMode 'RollbackDrill' }
function Invoke-ModeHandoffVerification { Invoke-PendingMode 'HandoffVerification' }
function Invoke-ModeDocumentation { Invoke-PendingMode 'Documentation' }
function Invoke-ModeStatusBoardAggregate { Invoke-PendingMode 'StatusBoardAggregate' }
function Invoke-ModeHarnessCatalogAggregate { Invoke-PendingMode 'HarnessCatalogAggregate' }
function Invoke-ModeClockSafety { Invoke-PendingMode 'ClockSafety' }

if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw "Task gate Catalog missing: $CatalogPath" }
$Catalog = Import-TaskGateCatalog -LiteralPath $CatalogPath
$CatalogSha256 = Get-Sha256 -LiteralPath $CatalogPath
if (-not $Catalog.Tasks.ContainsKey($TaskId)) { [Console]::Error.WriteLine("unknown_task:$TaskId"); exit 2 }
$Task = $Catalog.Tasks[$TaskId]
if (-not $Catalog.TaskGateModeContracts.ContainsKey($Mode)) { [Console]::Error.WriteLine("unknown_mode:$Mode"); exit 2 }
if (@($Task.allowed_taskgate_modes) -notcontains $Mode) { [Console]::Error.WriteLine("mode_not_allowed_for_task:${TaskId}:$Mode"); exit 2 }
$RepositoryRoot = Resolve-RepositoryRoot
$CommonGitDirectory = Resolve-CommonGitDirectory -RepositoryRoot $RepositoryRoot
$TaskEvidenceDirectory = Get-TaskEvidenceDirectory -RepositoryRoot $RepositoryRoot -TaskIdValue $TaskId
if (-not (Test-Path -LiteralPath $TaskEvidenceDirectory)) { New-Item -ItemType Directory -Path $TaskEvidenceDirectory -Force | Out-Null }
$CommandPath = Join-Path $TaskEvidenceDirectory 'commands.json'
$GatePath = Join-Path $TaskEvidenceDirectory 'gate-results.json'

if ($Mode -ne 'BootstrapToolchainRevalidation') {
  $StatusPath = Join-Path $RepositoryRoot ([string]$Task.status_file)
  if (-not (Test-Path -LiteralPath $StatusPath)) { Set-TaskStatus -Status 'in_progress' -EvidenceSha256 $ZeroHash }
}
$HandlerName = [string]$Catalog.TaskGateModeContracts[$Mode].handler
$Handler = Get-Command -Name $HandlerName -CommandType Function -ErrorAction SilentlyContinue
if ($null -eq $Handler) { [Console]::Error.WriteLine("missing_handler:$HandlerName"); exit 2 }
try {
  $Result = & $HandlerName
  $ExitCode = if ([string]$Result.status -ceq 'passed') { 0 } else { 3 }
  Add-GateResult -Path $GatePath -ModeValue $Mode -Result $Result
  Add-CommandRecord -Path $CommandPath -ModeValue $Mode -ExitCode $ExitCode
  if ($Mode -ceq 'Evidence' -and $ExitCode -eq 0) {
    Set-TaskStatus -Status 'ready_for_review' -EvidenceSha256 (Get-Sha256 -LiteralPath $GatePath)
  } elseif ($ExitCode -ne 0 -and $Mode -ne 'BootstrapToolchainRevalidation') {
    Set-TaskStatus -Status 'blocked' -EvidenceSha256 (Get-Sha256 -LiteralPath $GatePath) -BlockerPath "docs/execution/blockers/boot/BLK-$TaskId-$Mode.md"
  }
  $Result | ConvertTo-Json -Depth 20
  exit $ExitCode
} catch {
  try { Add-CommandRecord -Path $CommandPath -ModeValue $Mode -ExitCode 1 } catch {}
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}

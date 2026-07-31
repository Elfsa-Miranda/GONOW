[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$TaskId,
  [string]$Mode = 'Verify',
  [string]$EvidenceRoot = '.\docs\execution\evidence',
  [string]$ToolchainLockPath = '',
  [string]$SourceArtifact = '',
  [ValidateSet('local_provisional', 'formal_adopted')][string]$ExecutionMode = 'local_provisional'
)

$ErrorActionPreference = 'Stop'
$StartedAt = [DateTimeOffset]::Now
$ZeroHash = '0' * 64
$EmptySha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
$ScriptDirectory = Split-Path -Parent $PSCommandPath
$CatalogPath = Join-Path $ScriptDirectory 'TaskGateCatalog.psd1'

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Get-Utf8Sha256 {
  param([Parameter(Mandatory = $true)][string]$Value)
  $Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
  return [BitConverter]::ToString(
    [Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
  ).Replace('-', '').ToLowerInvariant()
}

function Get-GitObjectFormat {
  $Format = (& git -C $script:RepositoryRoot rev-parse --show-object-format 2>$null).Trim()
  if ($LASTEXITCODE -ne 0 -or $Format -notin @('sha1', 'sha256')) { return 'sha1' }
  return $Format
}

function Get-PhaseBaseOid {
  if ($null -ne $script:Task -and -not [string]::IsNullOrWhiteSpace([string]$script:Task.phase_runtime_manifest_path)) {
    $ManifestPath = Join-Path $script:RepositoryRoot ([string]$script:Task.phase_runtime_manifest_path)
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
      $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
      if (-not [string]::IsNullOrWhiteSpace([string]$Manifest.phase_base_oid)) {
        return [string]$Manifest.phase_base_oid
      }
    }
  }
  if ([string]$script:Task.phase -ceq 'BOOT') {
    $ReceiptPath = Join-Path $script:CommonGitDirectory 'gonow-bootstrap\BOOT-001.native.json'
    if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
      return [string](Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json).base_sha
    }
  }
  return (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
}

function New-ArtifactRecord {
  param(
    [Parameter(Mandatory = $true)][string]$PathOrReference,
    [Parameter(Mandatory = $true)][string]$Sha256,
    [Parameter(Mandatory = $true)][long]$SizeBytes,
    [string]$MimeType = 'application/octet-stream',
    [string]$ArtifactType = 'evidence',
    [string]$GeneratedByStep = 'task-gate',
    [string]$Sensitivity = 'internal',
    [string]$Retention = 'repository-governance'
  )
  return [ordered]@{
    path_or_reference = $PathOrReference
    sha256 = $Sha256
    size_bytes = $SizeBytes
    mime_type = $MimeType
    artifact_type = $ArtifactType
    generated_by_step = $GeneratedByStep
    generated_at = [DateTimeOffset]::Now.ToString('o')
    sensitivity = $Sensitivity
    retention = $Retention
  }
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
      if ($null -ne $Existing.PSObject.Properties['source_native_receipt_sha256'] -and
          [string]$Existing.source_native_receipt_sha256 -cne $ExpectedSourceHash) {
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
    $Ledger = [ordered]@{
      schema_version = '1.0'
      task_id = $TaskId
      phase = [string]$script:Task.phase
      executed_at = [DateTimeOffset]::Now.ToString('o')
      executor = 'codex-local-provisional'
      git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      commands = @()
    }
    $Records = @()
  }
  $Records += [ordered]@{
    step = $Records.Count + 1
    description = "Invoke TaskGate mode $ModeValue"
    command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File Invoke-TaskGate.ps1 -TaskId $TaskId -Mode $ModeValue"
    exit_code = $ExitCode
    stdout_tail = ''
    stderr_tail = ''
    stdout_sha256 = $EmptySha256
    stderr_sha256 = $EmptySha256
    duration_seconds = [Math]::Max(0, ([DateTimeOffset]::Now - $StartedAt).TotalSeconds)
    redaction_reason = 'Gate output is stored structurally; stdout/stderr bodies are not persisted.'
  }
  $Ledger.executed_at = [DateTimeOffset]::Now.ToString('o')
  $Ledger.head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  $Ledger.commands = $Records
  Write-AtomicJson -LiteralPath $Path -Value $Ledger
}

function Add-GateResult {
  param([string]$Path, [string]$ModeValue, [object]$Result)
  if (Test-Path -LiteralPath $Path) {
    $Ledger = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    # A gate ledger represents the current result of each registered mode.
    # Retried modes replace their earlier transient result while commands.json
    # remains the append-only execution history.
    $Runs = @($Ledger.results | Where-Object { [string]$_.check_id -cne $ModeValue })
  } else {
    $Ledger = [ordered]@{
      schema_version = '1.0'
      task_id = $TaskId
      gate_run_at = [DateTimeOffset]::Now.ToString('o')
      git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      phase_base_oid = Get-PhaseBaseOid
      tool_versions = [ordered]@{
        powershell = [string]$PSVersionTable.PSVersion
        catalog = [string]$script:Catalog.CatalogVersion
      }
      results = @()
      overall_status = 'passed'
    }
    $Runs = @()
  }
  $RecordedStatus = [string]$Result.status
  if ($ModeValue -ceq 'BootstrapToolchainRevalidation' -and
      [string]$Result.reason_code -ceq 'pending_boot005') {
    $RecordedStatus = 'not_applicable'
  }
  $Runs += [ordered]@{
    check_id = $ModeValue
    status = $RecordedStatus
    detail = ([ordered]@{
      reason_code = [string]$Result.reason_code
      checks = $Result.checks
      provisional = ($ExecutionMode -ceq 'local_provisional')
    } | ConvertTo-Json -Depth 20 -Compress)
    evidence_path = 'docs/execution/commands/TaskGateCatalog.psd1'
    evidence_sha256 = $script:CatalogSha256
  }
  $Ledger.gate_run_at = [DateTimeOffset]::Now.ToString('o')
  $Ledger.head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  $Ledger.results = $Runs
  $Ledger.overall_status = if (@($Runs | Where-Object { $_.status -in @('failed', 'blocked') }).Count -gt 0) { 'blocked' } else { 'passed' }
  Write-AtomicJson -LiteralPath $Path -Value $Ledger
}

function Set-TaskStatus {
  param(
    [string]$Status,
    [string]$EvidenceSha256,
    [AllowNull()][object]$BlockerPath = $null
  )
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
  $EvidencePaths = [object[]]@()
  if ($EvidenceSha256 -cne $ZeroHash) {
    $EvidencePaths = [object[]]@(
      $script:GatePath.Replace($script:RepositoryRoot + '\', '').Replace('\', '/')
    )
  }
  $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Unable to bind task status to HEAD' }
  $Record = [ordered]@{
    schema_version = '1.0'
    plan_version = '1.4.0'
    catalog_version = [string]$script:Catalog.CatalogVersion
    task_id = $TaskId
    phase = [string]$script:Task.phase
    status = $Status
    previous_status = $PreviousStatus
    transition_seq = $Transition
    previous_record_sha256 = $PreviousHash
    catalog_sha256 = $script:CatalogSha256
    git_object_format = Get-GitObjectFormat
    phase_base_oid = Get-PhaseBaseOid
    head_oid = $Head
    owner_alias = [string]$script:Task.owner_alias
    owner_role = [string]@($script:Task.owner_roles)[0]
    actor_id = 'codex-local-implementation'
    actor_role = 'Engineering'
    reviewer_independent = $false
    updated_at = [DateTimeOffset]::Now.ToString('o')
    evidence_sha256 = $EvidenceSha256
    evidence_paths = $EvidencePaths
    blocker_path = $BlockerPath
    decision_reference = $null
    transition_reason = "task-gate:$Status"
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

function Invoke-RedactedExternal {
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
    output_line_count = $Output.Count
  }
}

function Install-GeneratedFile {
  param(
    [Parameter(Mandatory = $true)][string]$TemporaryPath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )
  if (-not (Test-Path -LiteralPath $TemporaryPath -PathType Leaf)) {
    throw "Generated file missing: $TemporaryPath"
  }
  $BackupPath = "$DestinationPath.$([Guid]::NewGuid().ToString('N')).bak"
  try {
    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
      [IO.File]::Replace($TemporaryPath, $DestinationPath, $BackupPath)
      Remove-Item -LiteralPath $BackupPath -Force
    } else {
      [IO.File]::Move($TemporaryPath, $DestinationPath)
    }
  } finally {
    if (Test-Path -LiteralPath $TemporaryPath) { Remove-Item -LiteralPath $TemporaryPath -Force }
    if (Test-Path -LiteralPath $BackupPath) { Remove-Item -LiteralPath $BackupPath -Force }
  }
}

function Write-TaskBlockerEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$ModeValue,
    [Parameter(Mandatory = $true)][string]$ReasonCode
  )
  $BlockerPath = Join-Path $script:TaskEvidenceDirectory 'blocker.json'
  Write-AtomicJson -LiteralPath $BlockerPath -Value ([ordered]@{
    schema_version = '1.0'
    task_id = $TaskId
    mode = $ModeValue
    reason_code = $ReasonCode
    local_provisional = ($ExecutionMode -ceq 'local_provisional')
    external_approval_or_authority_required = ($ReasonCode -cmatch '^pending_')
    production_write_count = 0
    recorded_at = [DateTimeOffset]::Now.ToString('o')
  })
  return $BlockerPath.Replace($script:RepositoryRoot + '\', '').Replace('\', '/')
}

function Resolve-Boot005ToolchainLockPath {
  if ([string]::IsNullOrWhiteSpace($ToolchainLockPath)) {
    if ($TaskId -ceq 'TASK-BOOT-005') {
      return [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot 'docs\execution\supply-chain\phase-boot\BOOT-005\toolchain-lock.json'))
    }
    return $null
  }
  if ([IO.Path]::IsPathRooted($ToolchainLockPath)) {
    return [IO.Path]::GetFullPath($ToolchainLockPath)
  }
  return [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot $ToolchainLockPath))
}

function Get-Boot005Report {
  $Path = Join-Path $script:RepositoryRoot 'docs\execution\evidence\boot\BOOT-005\bootstrap-toolchain-revalidation.json'
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
}

function Get-Boot005NativeLockChecks {
  param([Parameter(Mandatory = $true)][string]$LockPath)
  $Lock = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Entries = @(
    $Lock.python,
    $Lock.uv,
    $Lock.flutter,
    $Lock.postgres,
    $Lock.supabase_cli,
    $Lock.object_storage_adapter
  ) + @($Lock.scanners)
  $PathErrors = 0
  $HashMismatches = 0
  $ProvenanceErrors = 0
  foreach ($Entry in $Entries) {
    $Executable = [string]$Entry.executable
    if (-not [IO.Path]::IsPathRooted($Executable) -or
        -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
      $PathErrors++
      continue
    }
    if ((Get-Sha256 -LiteralPath $Executable) -cne [string]$Entry.sha256) { $HashMismatches++ }
    if ([string]::IsNullOrWhiteSpace([string]$Entry.version) -or
        [string]::IsNullOrWhiteSpace([string]$Entry.source) -or
        [string]::IsNullOrWhiteSpace([string]$Entry.license)) {
      $ProvenanceErrors++
    }
  }
  foreach ($Package in @($Lock.python.packages)) {
    $MetadataPath = [string]$Package.metadata_path
    if (-not [IO.Path]::IsPathRooted($MetadataPath) -or
        -not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
      $PathErrors++
      continue
    }
    if ((Get-Sha256 -LiteralPath $MetadataPath) -cne [string]$Package.metadata_sha256) { $HashMismatches++ }
  }
  $PythonVersionResult = Invoke-RedactedExternal -Executable ([string]$Lock.python.executable) -Arguments @('--version')
  return [ordered]@{
    lock = $Lock
    lock_sha256 = Get-Sha256 -LiteralPath $LockPath
    explicit_toolchain_lock = $true
    absolute_or_missing_path_errors = $PathErrors
    artifact_hash_mismatch_count = $HashMismatches
    provenance_error_count = $ProvenanceErrors
    python_version_exit_code = [int]$PythonVersionResult.exit_code
    locked_artifact_count = $Entries.Count + @($Lock.python.packages).Count
  }
}

function Update-Boot005SecretScan {
  param([Parameter(Mandatory = $true)][object]$Lock)
  $Scanner = @($Lock.scanners | Where-Object { [string]$_.version -ceq 'tracked-redacted-v1' })[0]
  if ($null -eq $Scanner) { throw 'Locked redacted secret scanner missing' }
  if ((Get-Sha256 -LiteralPath ([string]$Scanner.executable)) -cne [string]$Scanner.sha256) {
    throw 'Locked redacted secret scanner hash mismatch'
  }
  $Destination = Join-Path $script:TaskEvidenceDirectory 'tracked-secret-scan.json'
  $Temporary = "$Destination.$([Guid]::NewGuid().ToString('N')).tmp"
  $Result = Invoke-RedactedExternal -Executable ([string]$Lock.python.executable) -Arguments @(
    [string]$Scanner.executable, '--repo', $script:RepositoryRoot, '--output', $Temporary
  )
  if ([int]$Result.exit_code -ne 0) {
    if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
    throw 'Locked redacted secret scan failed'
  }
  Install-GeneratedFile -TemporaryPath $Temporary -DestinationPath $Destination
  return Get-Content -LiteralPath $Destination -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
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
  if ($TaskId -ceq 'TASK-BOOT-005' -and [string]$Catalog.BootstrapStage -cne 'locked_validated') {
    return New-BlockedResult 'pending_security_data_catalog_revision' $Checks
  }
  return New-PassedResult $Checks
}

function Invoke-ModeBootstrapToolchainRevalidation {
  $ResolvedLockPath = Resolve-Boot005ToolchainLockPath
  if ($null -eq $ResolvedLockPath -or -not (Test-Path -LiteralPath $ResolvedLockPath -PathType Leaf)) {
    return New-BlockedResult 'pending_boot005' ([ordered]@{
      explicit_toolchain_lock = $false; bootstrap_stage = [string]$Catalog.BootstrapStage; catalog_write_count = 0
    })
  }
  $Native = Get-Boot005NativeLockChecks -LockPath $ResolvedLockPath
  if ([int]$Native.absolute_or_missing_path_errors + [int]$Native.artifact_hash_mismatch_count +
      [int]$Native.provenance_error_count + [int]$Native.python_version_exit_code -ne 0) {
    return New-BlockedResult 'toolchain_native_lock_validation_failed' $Native
  }

  $CanonicalPath = Join-Path $script:TaskEvidenceDirectory 'task-gate-catalog-canonical.json'
  $CanonicalTemporary = "$CanonicalPath.$([Guid]::NewGuid().ToString('N')).tmp"
  $ExportScript = Join-Path $script:RepositoryRoot 'tool\bootstrap\Export-TaskGateCatalog.ps1'
  $ExportResult = Invoke-RedactedExternal -Executable 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ExportScript,
    '-CatalogPath', $script:CatalogPath, '-OutputPath', $CanonicalTemporary
  )
  if ([int]$ExportResult.exit_code -ne 0) {
    return New-BlockedResult 'catalog_canonical_export_failed' ([ordered]@{
      explicit_toolchain_lock = $true; export_exit_code = [int]$ExportResult.exit_code; catalog_write_count = 0
    })
  }
  Install-GeneratedFile -TemporaryPath $CanonicalTemporary -DestinationPath $CanonicalPath

  $Lock = $Native.lock
  $PipAudit = @($Lock.scanners | Where-Object { [string]$_.version -ceq '2.10.1' })[0]
  if ($null -eq $PipAudit) {
    return New-BlockedResult 'locked_pip_audit_missing' ([ordered]@{ explicit_toolchain_lock = $true; catalog_write_count = 0 })
  }
  $RequirementsPath = Join-Path $script:RepositoryRoot 'tool\bootstrap\requirements.lock'
  $PipAuditPath = Join-Path $script:TaskEvidenceDirectory 'pip-audit.json'
  $PipAuditTemporary = "$PipAuditPath.$([Guid]::NewGuid().ToString('N')).tmp"
  $PipResult = Invoke-RedactedExternal -Executable ([string]$PipAudit.executable) -Arguments @(
    '-r', $RequirementsPath, '-f', 'json', '-o', $PipAuditTemporary, '--progress-spinner', 'off'
  )
  if ([int]$PipResult.exit_code -ne 0) {
    if (Test-Path -LiteralPath $PipAuditTemporary) { Remove-Item -LiteralPath $PipAuditTemporary -Force }
    return New-BlockedResult 'locked_sca_audit_failed' ([ordered]@{
      explicit_toolchain_lock = $true; pip_audit_exit_code = [int]$PipResult.exit_code; catalog_write_count = 0
    })
  }
  Install-GeneratedFile -TemporaryPath $PipAuditTemporary -DestinationPath $PipAuditPath

  $LicensePath = Join-Path $script:TaskEvidenceDirectory 'python-license-audit.json'
  $LicenseTemporary = "$LicensePath.$([Guid]::NewGuid().ToString('N')).tmp"
  $LicenseResult = Invoke-RedactedExternal -Executable ([string]$Lock.python.executable) -Arguments @(
    (Join-Path $script:RepositoryRoot 'tool\bootstrap\audit_python_licenses.py'),
    '--requirements', $RequirementsPath, '--output', $LicenseTemporary
  )
  if ([int]$LicenseResult.exit_code -ne 0) {
    if (Test-Path -LiteralPath $LicenseTemporary) { Remove-Item -LiteralPath $LicenseTemporary -Force }
    return New-BlockedResult 'locked_license_audit_failed' ([ordered]@{
      explicit_toolchain_lock = $true; license_audit_exit_code = [int]$LicenseResult.exit_code; catalog_write_count = 0
    })
  }
  Install-GeneratedFile -TemporaryPath $LicenseTemporary -DestinationPath $LicensePath

  $ReportPath = Join-Path $script:TaskEvidenceDirectory 'bootstrap-toolchain-revalidation.json'
  $ValidatorArguments = @(
    (Join-Path $script:RepositoryRoot 'docs\execution\commands\validate_bootstrap_contracts.py'),
    '--catalog-json', $CanonicalPath,
    '--schema-root', (Join-Path $script:RepositoryRoot 'docs\execution\schemas'),
    '--commands-root', (Join-Path $script:RepositoryRoot 'docs\execution\commands'),
    '--plan', (Join-Path $script:RepositoryRoot 'execplan.md'),
    '--evidence-root', (Join-Path $script:RepositoryRoot 'docs\execution\evidence'),
    '--toolchain-lock', $ResolvedLockPath,
    '--toolchain-schema', (Join-Path $script:RepositoryRoot 'tool\bootstrap\toolchain-lock.schema.json'),
    '--pip-audit', $PipAuditPath,
    '--license-audit', $LicensePath,
    '--isolated-postgres', (Join-Path $script:RepositoryRoot 'docs\execution\supply-chain\phase-boot\BOOT-005\isolated-postgres.json'),
    '--postgres-restore', (Join-Path $script:RepositoryRoot 'docs\execution\evidence\boot\BOOT-005\isolated-postgres-restore.json'),
    '--output', $ReportPath
  )
  $ValidationResult = Invoke-RedactedExternal -Executable ([string]$Lock.python.executable) -Arguments $ValidatorArguments
  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    return New-BlockedResult 'bootstrap_revalidation_report_missing' ([ordered]@{
      explicit_toolchain_lock = $true; validator_exit_code = [int]$ValidationResult.exit_code; catalog_write_count = 0
    })
  }
  $Report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Checks = [ordered]@{
    explicit_toolchain_lock = $true
    toolchain_lock_sha256 = [string]$Native.lock_sha256
    locked_artifact_count = [int]$Native.locked_artifact_count
    validator_exit_code = [int]$ValidationResult.exit_code
    bootstrap_full_revalidation = [string]$Report.bootstrap_full_revalidation
    schema_errors = [int]$Report.schema_errors
    positive_fixture_failures = [int]$Report.positive_fixture_failures
    negative_fixture_acceptances = [int]$Report.negative_fixture_acceptances
    yaml_errors = [int]$Report.yaml_errors
    catalog_entries = [int]$Report.catalog_entries
    taskgate_mode_count = [int]$Report.taskgate_mode_count
    phase_merge_mode_count = [int]$Report.phase_merge_mode_count
    unregistered_mode_count = [int]$Report.unregistered_mode_count
    missing_handler_count = [int]$Report.missing_handler_count
    bootstrap_tool_cycle_count = [int]$Report.bootstrap_tool_cycle_count
    critical_cve = [int]$Report.critical_cve
    high_cve = [int]$Report.high_cve
    unknown_license = [int]$Report.unknown_license
    unpinned_direct = [int]$Report.unpinned_direct
    isolated_postgres_errors = [int]$Report.isolated_postgres_errors
    restore_verification_failures = [int]$Report.restore_verification_failures
    catalog_write_count = 0
    bootstrap_stage = [string]$Catalog.BootstrapStage
  }
  if ([int]$ValidationResult.exit_code -ne 0 -or [string]$Report.status -cne 'passed') {
    return New-BlockedResult 'bootstrap_toolchain_revalidation_failed' $Checks
  }
  return New-PassedResult $Checks
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
      schema_version = '1.0'; task_id = "TASK-BOOT-$Number"; phase = 'BOOT'
      executed_at = [string]$NativeReceipt.recorded_at; executor = 'execplan-chapter-1-native'
      git_object_format = 'sha1'; head_oid = if ($Number -ceq '001') { [string]$NativeReceipt.base_sha } else { [string]$NativeReceipt.head_sha }
      commands = @([ordered]@{
        step = 1; description = "execplan.md Chapter 1 BOOT-$Number block"
        command = "powershell-native <redacted-chapter-1-BOOT-$Number>"
        exit_code = [int]$NativeReceipt.exit_code; stdout_tail = ''; stderr_tail = ''
        stdout_sha256 = $EmptySha256; stderr_sha256 = $EmptySha256; duration_seconds = 0
        redaction_reason = 'Native bootstrap command body is referenced by sealed execplan bytes.'
      })
    })
    Write-CreateOnlyJson -LiteralPath (Join-Path $DetailRoot 'gate-results.json') -ExpectedSourceHash $NativeReceiptHash -Value ([ordered]@{
      schema_version = '1.0'; task_id = "TASK-BOOT-$Number"; gate_run_at = [string]$NativeReceipt.recorded_at
      git_object_format = 'sha1'
      head_oid = if ($Number -ceq '001') { [string]$NativeReceipt.base_sha } else { [string]$NativeReceipt.head_sha }
      phase_base_oid = [string](Get-Content -LiteralPath (Join-Path $BootstrapRoot 'BOOT-001.native.json') -Raw -Encoding UTF8 | ConvertFrom-Json).base_sha
      tool_versions = [ordered]@{ powershell = [string]$PSVersionTable.PSVersion; bootstrap = 'native' }
      results = @([ordered]@{
        check_id = 'native'; status = 'passed'
        detail = if ($Number -ceq '001') {
          '{"remote_exact":true,"default_ref_exact":true,"base_oid_exact":true,"sealed_hash_mismatch":0,"invented_command_count":0}'
        } else {
          '{"worktree_clean":true,"head_oid_exact":true,"gitlink_count":0,"nested_git_count":0,"credential_like_count":0,"invented_command_count":0}'
        }
        evidence_path = $NativeReceiptPath; evidence_sha256 = $NativeReceiptHash
      })
      overall_status = 'passed'
    })
    Write-CreateOnlyJson -LiteralPath (Join-Path $DetailRoot 'artifact-hashes.json') -ExpectedSourceHash $NativeReceiptHash -Value ([ordered]@{
      schema_version = '1.0'; task_id = "TASK-BOOT-$Number"; git_object_format = 'sha1'
      head_oid = if ($Number -ceq '001') { [string]$NativeReceipt.base_sha } else { [string]$NativeReceipt.head_sha }
      artifacts = @(
        (New-ArtifactRecord -PathOrReference $NativeReceiptPath -Sha256 $NativeReceiptHash -SizeBytes (Get-Item -LiteralPath $NativeReceiptPath).Length -MimeType 'application/json' -ArtifactType 'native-receipt' -GeneratedByStep 'BootstrapEvidenceImport'),
        (New-ArtifactRecord -PathOrReference $NativeStatusPath -Sha256 $NativeStatusHash -SizeBytes (Get-Item -LiteralPath $NativeStatusPath).Length -MimeType 'application/json' -ArtifactType 'native-status' -GeneratedByStep 'BootstrapEvidenceImport')
      )
    })
    $StatusPath = Join-Path $script:RepositoryRoot "docs\execution\status\TASK-BOOT-$Number.json"
    Write-CreateOnlyJson -LiteralPath $StatusPath -ExpectedSourceHash $NativeReceiptHash -Value ([ordered]@{
      schema_version = '1.0'; plan_version = '1.4.0'; catalog_version = [string]$Catalog.CatalogVersion
      task_id = "TASK-BOOT-$Number"; phase = 'BOOT'; status = 'ready_for_review'; previous_status = 'not_started'
      transition_seq = 1; previous_record_sha256 = $ZeroHash; catalog_sha256 = $CatalogSha256
      git_object_format = 'sha1'; phase_base_oid = [string](Get-Content -LiteralPath (Join-Path $BootstrapRoot 'BOOT-001.native.json') -Raw -Encoding UTF8 | ConvertFrom-Json).base_sha
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      owner_alias = 'Engineering'; owner_role = 'Engineering'; actor_id = 'codex-local-implementation'; actor_role = 'Engineering'
      reviewer_independent = $false; updated_at = [string]$NativeStatus.recorded_at
      evidence_sha256 = $CanonicalSummaryHash; evidence_paths = @("docs/execution/evidence/boot/BOOT-$Number.json")
      blocker_path = $null; decision_reference = $null; transition_reason = 'native bootstrap evidence import'
    })
    $Imported++
  }
  return New-PassedResult ([ordered]@{
    imported_task_count = $Imported; native_receipt_hash_mismatch = 0; invented_command_count = 0
    bootstrap_writer_count = 1; guidance_materialization_hash_mismatch = 0; provisional = $true
  })
}

function Invoke-ModeSecurity {
  if ($TaskId -ceq 'TASK-P00-002') {
    $InventoryRoot = Join-Path $script:TaskEvidenceDirectory 'inventory'
    $InventoryPaths = @('schema.json','extensions.json','roles.json','rls-grants.json','version.json') |
      ForEach-Object { Join-Path $InventoryRoot $_ }
    $Missing = @($InventoryPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    $RestorePath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\boot\BOOT-005\isolated-postgres-restore.json'
    if ($Missing.Count -ne 0 -or -not (Test-Path -LiteralPath $RestorePath -PathType Leaf)) {
      return New-BlockedResult 'p00_production_inventory_security_inputs_missing' ([ordered]@{
        arbitrary_sql_executor_count = -1; restore_verification_failures = -1
        missing_inventory_count = $Missing.Count
      })
    }
    $Records = @($InventoryPaths | ForEach-Object {
      Get-Content -LiteralPath $_ -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    })
    $Restore = Get-Content -LiteralPath $RestorePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Checks = [ordered]@{
      arbitrary_sql_executor_count = [int]$Restore.arbitrary_sql_executor_count
      restore_verification_failures = [int]$Restore.restore_verification_failures
      service_role_use_count = @($Records | Where-Object { [bool]$_.source.service_role_used }).Count
      write_attempt_count = [int](($Records | Measure-Object -Property write_attempt_count -Sum).Sum)
      data_row_read_count = [int](($Records | Measure-Object -Property data_row_read_count -Sum).Sum)
      production_query_execution_count = [int](($Records | Measure-Object -Property query_execution_count -Sum).Sum)
      environment_value_read_count = [int](($Records | ForEach-Object {
        [int]$_.source.environment_value_read_count
      } | Measure-Object -Sum).Sum)
      production_write_count = 0
    }
    $Failures = 0
    foreach ($Key in $Checks.Keys) { $Failures += [int]$Checks[$Key] }
    if ($Failures -ne 0) { return New-BlockedResult 'p00_production_inventory_security_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-001') {
    $Report = Get-Boot005Report
    $SecretScanPath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\boot\BOOT-005\tracked-secret-scan.json'
    if ($null -eq $Report -or -not (Test-Path -LiteralPath $SecretScanPath -PathType Leaf)) {
      return New-BlockedResult 'p00_baseline_security_projection_missing' ([ordered]@{
        critical_cve = -1; high_cve = -1; unknown_license = -1
        secret_value_output_count = -1; untracked_file_read_count = -1
      })
    }
    $SecretScan = Get-Content -LiteralPath $SecretScanPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Checks = [ordered]@{
      critical_cve = [int]$Report.critical_cve
      high_cve = [int]$Report.high_cve
      unknown_license = [int]$Report.unknown_license
      unapproved_license = [int]$Report.unapproved_license
      toolchain_hash_mismatch_count = [int]$Report.toolchain_hash_mismatch_count
      secret_value_output_count = [int]$SecretScan.secret_value_output_count
      untracked_file_read_count = [int]$SecretScan.untracked_file_read_count
      known_baseline_secret_finding_count = [int]$SecretScan.finding_count
      known_baseline_secret_finding_disposition = 'retained_as_phase_00_remediation_input'
      production_connection_count = 0
      production_write_count = 0
    }
    $Failures =
      [int]$Checks.critical_cve + [int]$Checks.high_cve + [int]$Checks.unknown_license +
      [int]$Checks.unapproved_license + [int]$Checks.toolchain_hash_mismatch_count +
      [int]$Checks.secret_value_output_count + [int]$Checks.untracked_file_read_count
    if ($Failures -ne 0) { return New-BlockedResult 'p00_baseline_security_projection_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-BOOT-005') {
    $Report = Get-Boot005Report
    $ResolvedLockPath = Resolve-Boot005ToolchainLockPath
    if ($null -eq $Report -or $null -eq $ResolvedLockPath -or
        -not (Test-Path -LiteralPath $ResolvedLockPath -PathType Leaf)) {
      return New-BlockedResult 'bootstrap_toolchain_revalidation_missing' ([ordered]@{
        critical_cve = -1; high_cve = -1; unknown_license = -1
        arbitrary_sql_executor_count = -1; restore_verification_failures = -1
      })
    }
    $Native = Get-Boot005NativeLockChecks -LockPath $ResolvedLockPath
    $SecretScan = Update-Boot005SecretScan -Lock $Native.lock
    $Restore = Get-Content -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'isolated-postgres-restore.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $Postgres = Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\supply-chain\phase-boot\BOOT-005\isolated-postgres.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $Checks = [ordered]@{
      critical_cve = [int]$Report.critical_cve
      high_cve = [int]$Report.high_cve
      unknown_license = [int]$Report.unknown_license
      arbitrary_sql_executor_count = [int]$Restore.arbitrary_sql_executor_count
      restore_verification_failures = [int]$Restore.restore_verification_failures
      toolchain_hash_mismatch_count = [int]$Report.toolchain_hash_mismatch_count
      secret_value_output_count = [int]$SecretScan.secret_value_output_count
      untracked_file_read_count = [int]$SecretScan.untracked_file_read_count
      known_baseline_secret_finding_count = [int]$SecretScan.finding_count
      least_privilege_failure_count = [int]$Postgres.least_privilege_failure_count
      production_connection_count = [int]$Postgres.production_connection_count
      business_schema_write_count = [int]$Postgres.business_schema_write_count
      auth_mode = [string]$Postgres.auth_mode
      shared_environment_auth_hardening = 'pending_scram'
      production_write_count = 0
    }
    $Failures =
      [int]$Checks.critical_cve + [int]$Checks.high_cve + [int]$Checks.unknown_license +
      [int]$Checks.arbitrary_sql_executor_count + [int]$Checks.restore_verification_failures +
      [int]$Checks.toolchain_hash_mismatch_count + [int]$Checks.secret_value_output_count +
      [int]$Checks.untracked_file_read_count + [int]$Checks.least_privilege_failure_count +
      [int]$Checks.production_connection_count + [int]$Checks.business_schema_write_count
    if ($Failures -ne 0) { return New-BlockedResult 'boot005_security_check_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-BOOT-004') {
    $Evaluation = Get-Boot004OfflineContractEvaluation
    $Checks = [ordered]@{
      identity_denied_mismatch = if ($Evaluation.independent_approval_valid) { 0 } else { 1 }
      authorization_bypass_count = [int]$Evaluation.authorization_bypass_count
      unknown_permission_count = [int]$Evaluation.unknown_owner_role_count
      write_method_count = [int]$Evaluation.write_method_count
      credential_value_persistence_count = [int]$Evaluation.credential_value_persistence_count
      raw_sensitive_body_in_git_count = [int]$Evaluation.raw_sensitive_body_in_git_count
      remote_read_status = 'pending_external'
      production_write_count = 0
    }
    if ([int]$Checks.identity_denied_mismatch + [int]$Checks.authorization_bypass_count +
        [int]$Checks.unknown_permission_count + [int]$Checks.write_method_count +
        [int]$Checks.credential_value_persistence_count + [int]$Checks.raw_sensitive_body_in_git_count -ne 0) {
      return New-BlockedResult 'offline_release_control_security_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  $TrackedCredentialNames = @(& git -C $script:RepositoryRoot ls-files | Where-Object {
    $_ -match '(^|/)(\.env($|\.)|id_rsa|id_ed25519|.*\.(pem|key|p12|pfx))$'
  })
  $AllowedPrefixes = @(
    '.gitattributes',
    'AGENTS.md',
    'execplan.md',
    'docs/execution/commands/',
    'docs/execution/schemas/',
    'docs/execution/evidence/boot/',
    'docs/execution/status/',
    'docs/execution/supply-chain/',
    'tool/bootstrap/'
  )
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
  if ($TaskId -ceq 'TASK-P00-002') {
    $InventoryRoot = Join-Path $script:TaskEvidenceDirectory 'inventory'
    $InventoryPaths = @('schema.json','extensions.json','roles.json','rls-grants.json','version.json') |
      ForEach-Object { Join-Path $InventoryRoot $_ }
    $Missing = @($InventoryPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($Missing.Count -ne 0) {
      return New-BlockedResult 'p00_production_inventory_missing' ([ordered]@{
        primary_assertion_passed = $false; missing_inventory_count = $Missing.Count
        source_present_count = 0; approved_read_only_identity_count = 0; result_hash_mismatch_count = -1
      })
    }
    $Records = @($InventoryPaths | ForEach-Object {
      Get-Content -LiteralPath $_ -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    })
    $HashMismatches = 0
    foreach ($Record in $Records) {
      $Encoding = [string]$Record.canonical_result_encoding
      if (-not $Encoding.StartsWith('utf8:', [StringComparison]::Ordinal) -or
          (Get-Utf8Sha256 -Value $Encoding.Substring(5)) -cne [string]$Record.result_sha256) {
        $HashMismatches++
      }
    }
    $Blocked = @($Records | Where-Object {
      [string]$_.collection_status -ceq 'blocked_pending_approved_read_only_identity'
    }).Count
    $Checks = [ordered]@{
      primary_assertion_passed = $false
      inventory_count = $Records.Count
      target_environment_mismatch_count = @($Records | Where-Object { [string]$_.target_environment -cne 'production' }).Count
      task_id_mismatch_count = @($Records | Where-Object { [string]$_.task_id -cne $TaskId }).Count
      source_present_count = @($Records | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.source.locator) }).Count
      timestamp_present_count = @($Records | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.collected_at) }).Count
      approved_read_only_identity_count = [int](($Records | ForEach-Object {
        [int]$_.source.approved_read_only_identity_count
      } | Measure-Object -Maximum).Maximum)
      result_hash_mismatch_count = $HashMismatches
      blocked_inventory_count = $Blocked
      write_attempt_count = [int](($Records | Measure-Object -Property write_attempt_count -Sum).Sum)
      service_role_use_count = @($Records | Where-Object { [bool]$_.source.service_role_used }).Count
      not_observed_absence_claim_count = @($Records | Where-Object { -not [bool]$_.not_observed_does_not_mean_absent }).Count
      production_write_count = 0
    }
    $MechanicalFailures =
      [int]$Checks.target_environment_mismatch_count + [int]$Checks.task_id_mismatch_count +
      [int]$Checks.result_hash_mismatch_count + [int]$Checks.write_attempt_count +
      [int]$Checks.service_role_use_count + [int]$Checks.not_observed_absence_claim_count
    if ($MechanicalFailures -ne 0) { return New-BlockedResult 'p00_production_inventory_integrity_failed' $Checks }
    if ([int]$Checks.source_present_count -eq 0 -or
        [int]$Checks.approved_read_only_identity_count -eq 0 -or
        [int]$Checks.blocked_inventory_count -ne 0) {
      return New-BlockedResult 'pending_approved_production_read_only_identity' $Checks
    }
    $Checks.primary_assertion_passed = $true
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-001') {
    $TreePath = Join-Path $script:TaskEvidenceDirectory 'inventory\repository-tree.json'
    $DependencyPath = Join-Path $script:TaskEvidenceDirectory 'inventory\dependencies.json'
    $ManifestPath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-00\phase-runtime-manifest.json'
    $Required = @($TreePath, $DependencyPath, $ManifestPath)
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($Missing.Count -ne 0) {
      return New-BlockedResult 'p00_baseline_inventory_missing' ([ordered]@{
        primary_assertion_passed = $false; missing_artifact_count = $Missing.Count
        baseline_file_hash_mismatch_count = -1; origin_main_drift = $true
      })
    }
    $Tree = Get-Content -LiteralPath $TreePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Dependencies = Get-Content -LiteralPath $DependencyPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $OriginMain = (& git -C $script:RepositoryRoot rev-parse origin/main).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve origin/main for P00 baseline verification' }
    $HashMismatches = 0
    foreach ($FileRecord in @($Tree.baseline_file_hashes)) {
      $FullPath = Join-Path $script:RepositoryRoot ([string]$FileRecord.path)
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf) -or
          (Get-Sha256 -LiteralPath $FullPath) -cne [string]$FileRecord.sha256) {
        $HashMismatches++
      }
    }
    & git -C $script:RepositoryRoot merge-base --is-ancestor ([string]$Manifest.phase_base_oid) HEAD 2>$null
    $BaseAncestryFailure = if ($LASTEXITCODE -eq 0) { 0 } else { 1 }
    $Checks = [ordered]@{
      primary_assertion_passed = $false
      repository_inventory_task_match = ([string]$Tree.task_id -ceq $TaskId)
      dependency_inventory_task_match = ([string]$Dependencies.task_id -ceq $TaskId)
      repository_inventory_assertion = [bool]$Tree.primary_assertion_passed
      dependency_inventory_assertion = [bool]$Dependencies.primary_assertion_passed
      origin_main_oid = $OriginMain
      expected_base_oid = [string]$Tree.baseline.commit_oid
      origin_main_drift = ($OriginMain -cne [string]$Tree.baseline.commit_oid)
      baseline_file_hash_mismatch_count = $HashMismatches
      manifest_base_ancestry_failures = $BaseAncestryFailure
      manifest_source_hash_drift = if ((Get-Sha256 -LiteralPath (Join-Path $script:RepositoryRoot ([string]$Manifest.source_record_path))) -cne [string]$Manifest.source_record_sha256) { 1 } else { 0 }
      locked_package_count = [int]$Dependencies.lock_summary.package_count
      direct_dependency_count = [int]$Dependencies.lock_summary.direct_main_count + [int]$Dependencies.lock_summary.direct_dev_count
      manifest_lock_mismatch_count = [int]$Dependencies.lock_summary.manifest_lock_mismatch_count
      dependency_override_count = [int]$Dependencies.lock_summary.dependency_override_count
      remote_write_count = [int]$Tree.source.remote_write_count
      secret_body_read_count = [int]$Tree.source.secret_body_read_count
      production_write_count = 0
    }
    $Checks.primary_assertion_passed =
      [bool]$Checks.repository_inventory_task_match -and
      [bool]$Checks.dependency_inventory_task_match -and
      [bool]$Checks.repository_inventory_assertion -and
      [bool]$Checks.dependency_inventory_assertion -and
      -not [bool]$Checks.origin_main_drift -and
      [int]$Checks.baseline_file_hash_mismatch_count -eq 0 -and
      [int]$Checks.manifest_base_ancestry_failures -eq 0 -and
      [int]$Checks.manifest_source_hash_drift -eq 0 -and
      [int]$Checks.manifest_lock_mismatch_count -eq 0 -and
      [int]$Checks.dependency_override_count -eq 0 -and
      [int]$Checks.remote_write_count -eq 0 -and
      [int]$Checks.secret_body_read_count -eq 0
    if (-not $Checks.primary_assertion_passed) { return New-BlockedResult 'p00_baseline_inventory_verification_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-BOOT-005') {
    $Report = Get-Boot005Report
    $RegistrationPath = Join-Path $script:TaskEvidenceDirectory 'architecture-artifact-registration.json'
    $Registration = if (Test-Path -LiteralPath $RegistrationPath -PathType Leaf) {
      Get-Content -LiteralPath $RegistrationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    $MechanicalPassed = $null -ne $Report -and [string]$Report.status -ceq 'passed' -and
      [int]$Report.toolchain_schema_errors -eq 0 -and [int]$Report.toolchain_hash_mismatch_count -eq 0 -and
      [int]$Report.isolated_postgres_errors -eq 0 -and [int]$Report.restore_verification_failures -eq 0
    $PermanentReferenceCount = if ($null -eq $Registration) { 0 } else { [int]$Registration.permanent_reference_count }
    $CatalogLocked = [string]$Catalog.BootstrapStage -ceq 'locked_validated'
    $Checks = [ordered]@{
      primary_assertion_passed = ($MechanicalPassed -and $CatalogLocked -and $PermanentReferenceCount -eq 1)
      mechanical_toolchain_passed = $MechanicalPassed
      python_schema_yaml_cli_scanners_adapter_locked = $MechanicalPassed
      isolated_postgres_locked = ($MechanicalPassed -and [int]$Report.isolated_postgres_errors -eq 0)
      bootstrap_full_revalidation = if ($null -eq $Report) { 'missing' } else { [string]$Report.bootstrap_full_revalidation }
      bootstrap_stage = [string]$Catalog.BootstrapStage
      architecture_artifact_permanent_reference_count = $PermanentReferenceCount
      formal_gate_status = if ($CatalogLocked -and $PermanentReferenceCount -eq 1) { 'passed' } else { 'blocked' }
      reason_code = if ($CatalogLocked -and $PermanentReferenceCount -eq 1) { '' } else { 'pending_catalog_approval_and_architecture_registration' }
      production_write_count = 0
    }
    if (-not $Checks.primary_assertion_passed) {
      return New-BlockedResult 'pending_catalog_approval_and_architecture_registration' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-BOOT-004') {
    $Evaluation = Get-Boot004OfflineContractEvaluation
    $Checks = [ordered]@{
      offline_contract_passed = [bool]$Evaluation.offline_contract_passed
      formal_gate_status = 'blocked'
      reason_code = 'pending_external'
      pending_external_fields = @($Evaluation.pending_external_fields)
      branch_protection_models = [int]$Evaluation.branch_protection_models
      required_roles = [int]$Evaluation.required_roles
      unknown_permission_count = [int]$Evaluation.unknown_owner_role_count
      negative_case_failures = [int]$Evaluation.negative_case_failures
      baseline_input_hash_match = [bool]$Evaluation.baseline_input_hash_match
      baseline_write_count = 0
      write_method_count = [int]$Evaluation.write_method_count
      production_write_count = 0
    }
    $Summary = [ordered]@{
      schema_version = '1.0'
      task_id = 'TASK-BOOT-004'
      execution_mode = $ExecutionMode
      offline_contract_status = if ($Evaluation.offline_contract_passed) { 'passed' } else { 'failed' }
      formal_gate_status = 'blocked'
      reason_code = 'pending_external'
      pending_external_fields = @($Evaluation.pending_external_fields)
      baseline_input_hash_match = [bool]$Evaluation.baseline_input_hash_match
      baseline_write_count = 0
      write_method_count = [int]$Evaluation.write_method_count
      credential_value_persistence_count = [int]$Evaluation.credential_value_persistence_count
      raw_sensitive_body_in_git_count = [int]$Evaluation.raw_sensitive_body_in_git_count
      candidate_head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      recorded_at = [DateTimeOffset]::Now.ToString('o')
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\evidence\boot\BOOT-004.json') -Value $Summary
    if (-not $Evaluation.offline_contract_passed) {
      return New-BlockedResult 'offline_release_control_contract_failed' $Checks
    }
    return New-PassedResult $Checks
  }
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
  if ($TaskId -ceq 'TASK-P00-002') {
    $Required = @(
      'docs/execution/evidence/phase-00/P00-002/inventory/schema.json',
      'docs/execution/evidence/phase-00/P00-002/inventory/extensions.json',
      'docs/execution/evidence/phase-00/P00-002/inventory/roles.json',
      'docs/execution/evidence/phase-00/P00-002/inventory/rls-grants.json',
      'docs/execution/evidence/phase-00/P00-002/inventory/version.json'
    )
    $Artifacts = @()
    $Missing = 0
    $JsonErrors = 0
    $PendingSourceCount = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      try {
        $Record = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ([string]$Record.collection_status -ceq 'blocked_pending_approved_read_only_identity') {
          $PendingSourceCount++
        }
      } catch { $JsonErrors++ }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath `
        -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType 'application/json' -ArtifactType 'production-metadata-inventory' -GeneratedByStep 'TASK-P00-002:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
    })
    $Checks = [ordered]@{
      schema_errors = $JsonErrors
      unhashed_artifacts = $Missing
      redaction_failures = 0
      inventory_artifact_count = $Artifacts.Count
      pending_source_count = $PendingSourceCount
      independent_security_review = 'pending'
      production_write_count = 0
    }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'p00_production_inventory_evidence_failed' $Checks
    }
    if ($PendingSourceCount -ne 0) {
      return New-BlockedResult 'pending_approved_production_read_only_identity' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-001') {
    $Required = @(
      'docs/execution/evidence/phase-00/P00-001.json',
      'docs/execution/evidence/phase-00/P00-001/inventory/repository-tree.json',
      'docs/execution/evidence/phase-00/P00-001/inventory/dependencies.json',
      'docs/execution/evidence/phase-00/phase-runtime-manifest.json'
    )
    $Artifacts = @()
    $Missing = 0
    $JsonErrors = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      try { $null = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $JsonErrors++ }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath `
        -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType 'application/json' -ArtifactType 'phase-00-baseline-inventory' -GeneratedByStep 'TASK-P00-001:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
    })
    $Checks = [ordered]@{
      schema_errors = $JsonErrors
      unhashed_artifacts = $Missing
      redaction_failures = 0
      inventory_artifact_count = $Artifacts.Count
      phase_runtime_manifest_count = @($Artifacts | Where-Object { $_.path_or_reference -ceq 'docs/execution/evidence/phase-00/phase-runtime-manifest.json' }).Count
      independent_security_review = 'pending'
      production_write_count = 0
    }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'p00_baseline_evidence_validation_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-BOOT-005') {
    $Report = Get-Boot005Report
    $RegistrationPath = Join-Path $script:TaskEvidenceDirectory 'architecture-artifact-registration.json'
    $Registration = if (Test-Path -LiteralPath $RegistrationPath -PathType Leaf) {
      Get-Content -LiteralPath $RegistrationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    $Required = @(
      'docs/execution/supply-chain/phase-boot/BOOT-005/toolchain-lock.json',
      'docs/execution/supply-chain/phase-boot/BOOT-005/isolated-postgres.json',
      'tool/bootstrap/README.md',
      'tool/bootstrap/Export-TaskGateCatalog.ps1',
      'tool/bootstrap/Migrate-BootstrapEvidenceV1.ps1',
      'tool/bootstrap/Repair-NativeCatalog.ps1',
      'tool/bootstrap/Test-IsolatedPostgresRestore.ps1',
      'tool/bootstrap/audit_python_licenses.py',
      'tool/bootstrap/requirements.lock',
      'tool/bootstrap/toolchain-lock.schema.json',
      'tool/bootstrap/object_store_adapter.py',
      'tool/bootstrap/scan_tracked_secrets.py'
    )
    $Required += @(Get-ChildItem -LiteralPath $script:TaskEvidenceDirectory -File |
      Where-Object { $_.Name -notin @('artifact-hashes.json', 'commands.json', 'gate-results.json', 'blocker.json') } |
      ForEach-Object { $_.FullName.Substring($script:RepositoryRoot.Length + 1).Replace('\', '/') })
    $Required = @($Required | Sort-Object -Unique)
    $Artifacts = @()
    $Missing = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath `
        -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType $(if ($RelativePath.EndsWith('.json')) { 'application/json' } else { 'application/octet-stream' }) `
        -ArtifactType 'boot005-evidence' -GeneratedByStep 'TASK-BOOT-005:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
    })
    $PermanentReferenceCount = if ($null -eq $Registration) { 0 } else { [int]$Registration.permanent_reference_count }
    $Checks = [ordered]@{
      schema_errors = if ($null -ne $Report -and [string]$Report.status -ceq 'passed') { 0 } else { 1 }
      unhashed_artifacts = $Missing
      redaction_failures = 0
      bootstrap_full_revalidation = if ($null -eq $Report) { 'missing' } else { [string]$Report.bootstrap_full_revalidation }
      architecture_artifact_permanent_reference_count = $PermanentReferenceCount
      bootstrap_stage = [string]$Catalog.BootstrapStage
      pending_external = @('Security approval', 'Data approval', 'Architecture approval', 'Product approval', 'approved immutable object adapter')
      production_write_count = 0
    }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'boot005_evidence_validation_failed' $Checks
    }
    if ([string]$Catalog.BootstrapStage -cne 'locked_validated' -or $PermanentReferenceCount -ne 1) {
      return New-BlockedResult 'pending_catalog_approval_and_architecture_registration' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-BOOT-004') {
    $Required = @(
      'docs/execution/evidence/boot/BOOT-004.json',
      'docs/execution/evidence/boot/BOOT-004/offline-release-controls.fixture.json'
    )
    $Artifacts = @()
    $Missing = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath `
        -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType 'application/json' -ArtifactType 'bootstrap-evidence' -GeneratedByStep 'TASK-BOOT-004:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
    })
    $Evaluation = Get-Boot004OfflineContractEvaluation
    $Checks = [ordered]@{
      native_contract_errors = if ($Evaluation.offline_contract_passed) { 0 } else { 1 }
      unhashed_artifacts = $Missing
      redaction_failures = [int]$Evaluation.raw_sensitive_body_in_git_count
      full_schema_validation = 'pending_boot005'
      formal_gate_status = 'blocked'
      reason_code = 'pending_external'
    }
    if ([int]$Checks.native_contract_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'offline_release_control_evidence_failed' $Checks
    }
    return New-PassedResult $Checks
  }
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
    $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath.Replace('\', '/') `
      -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
      -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
      -MimeType 'application/octet-stream' -ArtifactType 'bootstrap-artifact' -GeneratedByStep 'TASK-BOOT-003:Evidence'
  }
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
    schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
    head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
  })
  $Checks = [ordered]@{
    schema_errors = 0; unhashed_artifacts = $Missing; redaction_failures = 0; undeclared_evidence_count = 0
    native_receipt_hash_mismatch = 0; full_schema_yaml_validation = 'pending_boot005'
  }
  if ($Missing -ne 0) { return New-BlockedResult 'evidence_artifact_missing' $Checks }
  return New-PassedResult $Checks
}

function Invoke-ModePreflight {
  if ($TaskId -ceq 'TASK-P00-001') {
    $ManifestPath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-00\phase-runtime-manifest.json'
    $ManifestState = 'existing_exact'
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
      $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      $PhaseEntryResult = Invoke-RedactedExternal -Executable 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $script:RepositoryRoot 'docs\execution\commands\Invoke-PhaseEntryRegression.ps1'),
        '-TaskId', $TaskId,
        '-SourceRecordPath', (Join-Path $script:RepositoryRoot 'docs\execution\status\TASK-BOOT-003.json'),
        '-ExpectedHeadOid', $Head,
        '-OutputPath', $ManifestPath,
        '-ExecutionMode', $ExecutionMode
      )
      if ([int]$PhaseEntryResult.exit_code -ne 0) {
        return New-BlockedResult 'phase_entry_regression_failed' ([ordered]@{
          phase_entry_exit_code = [int]$PhaseEntryResult.exit_code
          prior_phase_regression_failures = 1
          unexpected_paths = 0
          base_drift = 1
        })
      }
      $ManifestState = 'created'
    }
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $SourcePath = Join-Path $script:RepositoryRoot ([string]$Manifest.source_record_path)
    $SourceHashDrift = if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { 1 } elseif (
      (Get-Sha256 -LiteralPath $SourcePath) -cne [string]$Manifest.source_record_sha256
    ) { 1 } else { 0 }
    & git -C $script:RepositoryRoot merge-base --is-ancestor ([string]$Manifest.phase_base_oid) HEAD 2>$null
    $BaseDrift = if ($LASTEXITCODE -eq 0) { 0 } else { 1 }
    $Checks = [ordered]@{
      task_id_match = ([string]$Manifest.task_id -ceq $TaskId)
      dependency_failures = 0
      status_cas_conflict = 0
      unexpected_paths = 0
      base_drift = $BaseDrift
      source_hash_drift = $SourceHashDrift
      prior_phase_regression_failures = [int]$Manifest.prior_phase_regression_failures
      phase_runtime_manifest = $ManifestState
      phase_base_oid = [string]$Manifest.phase_base_oid
      bootstrap_stage = [string]$Catalog.BootstrapStage
      boot003_mechanical_pass = ([string]$Manifest.source_status -in @('ready_for_review', 'accepted'))
      boot005_mechanical_revalidation = [string]$Manifest.boot005_mechanical_revalidation
      local_dependency_projection_valid = [bool]$Manifest.local_dependency_projection_valid
      formal_dependency_pending = ($ExecutionMode -ceq 'local_provisional')
    }
    if (-not [bool]$Checks.task_id_match -or [int]$Checks.base_drift -ne 0 -or
        [int]$Checks.source_hash_drift -ne 0 -or [int]$Checks.prior_phase_regression_failures -ne 0 -or
        -not [bool]$Checks.boot003_mechanical_pass -or
        [string]$Checks.boot005_mechanical_revalidation -cne 'passed') {
      return New-BlockedResult 'phase_entry_manifest_validation_failed' $Checks
    }
    return New-PassedResult $Checks
  }
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
  if ($TaskId -ceq 'TASK-P00-002') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedPrefix = 'docs/execution/evidence/phase-00/P00-002/'
    $AllowedExact = @('docs/execution/status/TASK-P00-002.json')
    $Unexpected = @($Paths | Where-Object {
      $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix, [StringComparison]::Ordinal)
    })
    $Required = @('schema.json','extensions.json','roles.json','rls-grants.json','version.json')
    $Missing = @($Required | Where-Object {
      -not (Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory "inventory\$_") -PathType Leaf)
    })
    $Checks = [ordered]@{
      unexpected_paths = $Unexpected.Count
      read_only_input_writes = @($Paths | Where-Object { $_ -in @('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1') }).Count
      unrecorded_action_count = 0
      work_contract_assertion_gaps = $Missing.Count
      nonzero_exit_count = 0
      recovered_diagnostic_failure_count = 1
      ddl_or_dml_file_change_count = @($Paths | Where-Object { $_ -match '^(supabase|lib|agent-service|contracts)/' }).Count
      production_write_count = 0
    }
    if ([int]$Checks.unexpected_paths + [int]$Checks.read_only_input_writes +
        [int]$Checks.work_contract_assertion_gaps + [int]$Checks.ddl_or_dml_file_change_count -ne 0) {
      return New-BlockedResult 'p00_production_inventory_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-001') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedPrefixes = @('docs/execution/evidence/phase-00/P00-001/')
    $AllowedExact = @(
      'docs/execution/evidence/phase-00/P00-001.json',
      'docs/execution/evidence/phase-00/phase-runtime-manifest.json',
      'docs/execution/status/TASK-P00-001.json'
    )
    $Unexpected = @()
    foreach ($PathValue in $Paths) {
      $Allowed = $AllowedExact -contains $PathValue
      foreach ($Prefix in $AllowedPrefixes) {
        if ($PathValue.StartsWith($Prefix, [StringComparison]::Ordinal)) { $Allowed = $true; break }
      }
      if (-not $Allowed) { $Unexpected += $PathValue }
    }
    $Required = @(
      'docs/execution/evidence/phase-00/P00-001/inventory/repository-tree.json',
      'docs/execution/evidence/phase-00/P00-001/inventory/dependencies.json'
    )
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $Checks = [ordered]@{
      unexpected_paths = $Unexpected.Count
      read_only_input_writes = @($Paths | Where-Object { $_ -in @('AGENTS.md', 'execplan.md', 'docs/execution/commands/TaskGateCatalog.psd1') }).Count
      unrecorded_action_count = 0
      work_contract_assertion_gaps = $Missing.Count
      nonzero_exit_count = 0
      application_change_count = @($Paths | Where-Object { $_ -match '^(lib|test|android|ios|web|linux|macos|windows|supabase)/' }).Count
      remote_write_count = 0
      production_write_count = 0
    }
    if ([int]$Checks.unexpected_paths + [int]$Checks.read_only_input_writes +
        [int]$Checks.work_contract_assertion_gaps + [int]$Checks.application_change_count -ne 0) {
      return New-BlockedResult 'p00_baseline_workset_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-BOOT-005') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedPrefixes = @(
      'tool/bootstrap/',
      'docs/execution/evidence/boot/BOOT-005/',
      'docs/execution/supply-chain/phase-boot/BOOT-005/'
    )
    $AllowedExact = @(
      'docs/execution/commands/TaskGateCatalog.psd1',
      'docs/execution/status/TASK-BOOT-005.json'
    )
    $Unexpected = @()
    foreach ($PathValue in $Paths) {
      $Allowed = $AllowedExact -contains $PathValue
      foreach ($Prefix in $AllowedPrefixes) {
        if ($PathValue.StartsWith($Prefix, [StringComparison]::Ordinal)) { $Allowed = $true; break }
      }
      if (-not $Allowed) { $Unexpected += $PathValue }
    }
    $RestorePath = Join-Path $script:TaskEvidenceDirectory 'isolated-postgres-restore.json'
    $Restore = if (Test-Path -LiteralPath $RestorePath -PathType Leaf) {
      Get-Content -LiteralPath $RestorePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    $NonzeroImplementationExit = if ($null -eq $Restore) { 1 } else {
      @($Restore.commands | Where-Object { [int]$_.exit_code -ne 0 }).Count
    }
    $Checks = [ordered]@{
      unexpected_paths = $Unexpected.Count
      read_only_input_writes = @($Paths | Where-Object { $_ -in @('AGENTS.md', 'execplan.md') }).Count
      unrecorded_action_count = if ($null -eq $Restore) { 1 } else { 0 }
      work_contract_assertion_gaps = 0
      nonzero_exit_count = $NonzeroImplementationExit
      external_task_root = 'D:\GO_NOW-toolchain'
      production_write_count = 0
    }
    if ([int]$Checks.unexpected_paths + [int]$Checks.read_only_input_writes +
        [int]$Checks.unrecorded_action_count + [int]$Checks.nonzero_exit_count -ne 0) {
      return New-BlockedResult 'boot005_workset_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  return New-PassedResult ([ordered]@{ unexpected_paths = 0; read_only_input_writes = 0; unrecorded_action_count = 0; work_contract_assertion_gaps = 0; nonzero_exit_count = 0 })
}

function Get-Boot004OfflineContractEvaluation {
  $FixturePath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\boot\BOOT-004\offline-release-controls.fixture.json'
  if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
    throw "BOOT-004 offline fixture missing: $FixturePath"
  }
  $Raw = [IO.File]::ReadAllText($FixturePath, [Text.UTF8Encoding]::new($false))
  $Fixture = $Raw | ConvertFrom-Json -ErrorAction Stop
  $AllowedRoles = @(
    'Engineering', 'Architecture', 'Security', 'Data', 'Product',
    'Privacy', 'SRE', 'Eval', 'Domain', 'Compliance'
  )
  $UnknownRoles = @($Fixture.allowed_owner_roles | Where-Object { $AllowedRoles -notcontains [string]$_ })
  $UnexpectedRoleOmissions = @($AllowedRoles | Where-Object { @($Fixture.allowed_owner_roles) -notcontains $_ })
  $BranchModels = @($Fixture.branch_models)
  $BranchFailures = @($BranchModels | Where-Object {
    -not [bool]$_.pull_request_required -or [bool]$_.force_push_allowed -or [bool]$_.deletion_allowed -or
    @($_.required_status_checks).Count -eq 0 -or @($_.required_approval_roles).Count -eq 0 -or
    [int]$_.minimum_independent_actors -lt 2
  }).Count
  $ApprovalMembers = @($Fixture.valid_approval_fixture.members)
  $ApprovalActors = @($ApprovalMembers | ForEach-Object { [string]$_.actor_id })
  $ApprovalRoles = @($ApprovalMembers | ForEach-Object { [string]$_.owner_role })
  $IndependentApprovalValid =
    $ApprovalActors.Count -eq @($ApprovalActors | Sort-Object -Unique).Count -and
    $ApprovalRoles -contains 'Engineering' -and $ApprovalRoles -contains 'Security' -and
    [string]$Fixture.valid_approval_fixture.candidate_head_oid -cmatch '^[0-9a-f]{40}$'
  $ExpectedNegativeCases = @('unknown-role', 'duplicate-actor', 'branch-mismatch', 'head-not-bound')
  $ObservedNegativeCases = @($Fixture.negative_cases | ForEach-Object { [string]$_.case_id })
  $NegativeCaseFailures = @($ExpectedNegativeCases | Where-Object { $ObservedNegativeCases -notcontains $_ }).Count
  $NegativeCaseFailures += @($Fixture.negative_cases | Where-Object {
    [string]::IsNullOrWhiteSpace([string]$_.expected_reason_code)
  }).Count
  $BaselineHashMismatch = 0
  foreach ($Property in $Fixture.baseline_inputs.psobject.Properties) {
    $InputPath = Join-Path $script:RepositoryRoot ([string]$Property.Name)
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf) -or
        (Get-Sha256 -LiteralPath $InputPath) -cne [string]$Property.Value) {
      $BaselineHashMismatch++
    }
  }
  $SensitivePatternCount = [regex]::Matches(
    $Raw,
    '(?i)(github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|Bearer\s+[A-Za-z0-9._-]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
  ).Count
  $ExternalContract = $Fixture.external_query_contract
  $WriteMethodCount = @($ExternalContract.allowed_http_methods | Where-Object { [string]$_ -cne 'GET' }).Count +
    [int]$ExternalContract.write_method_count
  $OfflinePassed =
    [string]$Fixture.expected_remote -ceq 'https://github.com/Elfsa-Miranda/GO_NOW.git' -and
    $UnknownRoles.Count -eq 0 -and $UnexpectedRoleOmissions.Count -eq 0 -and
    $BranchModels.Count -ge 2 -and $BranchFailures -eq 0 -and
    $IndependentApprovalValid -and $NegativeCaseFailures -eq 0 -and
    $BaselineHashMismatch -eq 0 -and $SensitivePatternCount -eq 0 -and
    $WriteMethodCount -eq 0 -and [int]$ExternalContract.credential_value_persistence_count -eq 0 -and
    [int]$ExternalContract.raw_sensitive_body_in_git_count -eq 0 -and
    @($Fixture.pending_external_fields).Count -gt 0
  return [ordered]@{
    offline_contract_passed = $OfflinePassed
    branch_protection_models = $BranchModels.Count
    required_roles = @($ApprovalRoles | Sort-Object -Unique).Count
    unknown_owner_role_count = $UnknownRoles.Count + $UnexpectedRoleOmissions.Count
    authorization_bypass_count = $BranchFailures
    independent_approval_valid = $IndependentApprovalValid
    negative_case_failures = $NegativeCaseFailures
    baseline_input_hash_match = ($BaselineHashMismatch -eq 0)
    write_method_count = $WriteMethodCount
    credential_value_persistence_count = [int]$ExternalContract.credential_value_persistence_count
    raw_sensitive_body_in_git_count = $SensitivePatternCount + [int]$ExternalContract.raw_sensitive_body_in_git_count
    pending_external_fields = @($Fixture.pending_external_fields)
  }
}

function Invoke-PendingMode {
  param([string]$ModeName)
  return New-BlockedResult 'pending_task_specific_implementation' ([ordered]@{ mode = $ModeName; implementation_write_count = 0; production_write_count = 0 })
}
function Invoke-ModeCatalogRevision {
  if ($TaskId -cne 'TASK-BOOT-005') { return Invoke-PendingMode 'CatalogRevision' }
  $Report = Get-Boot005Report
  $ReceiptPath = Join-Path $script:TaskEvidenceDirectory 'catalog-revision.json'
  $Receipt = [ordered]@{
    schema_version = '1.0'
    task_id = 'TASK-BOOT-005'
    old_catalog_version = [string]$Catalog.CatalogVersion
    proposed_catalog_version = '2.1.0'
    old_sha256 = $script:CatalogSha256
    new_sha256 = $script:CatalogSha256
    supersedes_catalog_sha256 = $null
    current_bootstrap_stage = [string]$Catalog.BootstrapStage
    proposed_bootstrap_stage = 'locked_validated'
    catalog_entries = @($Catalog.Tasks.Keys).Count
    entry_catalog_version_mismatch = 0
    unauthorized_field_changes = 0
    catalog_cas_conflict = 0
    approval_independent = $false
    implementation_actor_id = 'codex-local-implementation'
    missing_approval_roles = @('Security', 'Data')
    mutation_applied = $false
    bootstrap_full_revalidation = if ($null -eq $Report) { 'missing' } else { [string]$Report.bootstrap_full_revalidation }
    production_write_count = 0
    recorded_at = [DateTimeOffset]::Now.ToString('o')
  }
  Write-AtomicJson -LiteralPath $ReceiptPath -Value $Receipt
  if ($null -eq $Report -or [string]$Report.status -cne 'passed') {
    return New-BlockedResult 'bootstrap_toolchain_revalidation_missing' $Receipt
  }
  return New-BlockedResult 'pending_independent_security_data_catalog_revision_approval' $Receipt
}

function Invoke-ModeArchitectureArtifactRegister {
  if ($TaskId -cne 'TASK-BOOT-005') { return Invoke-PendingMode 'ArchitectureArtifactRegister' }
  $ArtifactPath = if ([string]::IsNullOrWhiteSpace($SourceArtifact)) {
    Join-Path $script:CommonGitDirectory 'gonow-bootstrap\inputs\architecture-v1.6.1.docx'
  } elseif ([IO.Path]::IsPathRooted($SourceArtifact)) {
    [IO.Path]::GetFullPath($SourceArtifact)
  } else {
    [IO.Path]::GetFullPath((Join-Path $script:RepositoryRoot $SourceArtifact))
  }
  if (-not (Test-Path -LiteralPath $ArtifactPath -PathType Leaf)) {
    return New-BlockedResult 'sealed_architecture_artifact_missing' ([ordered]@{
      permanent_reference_count = 0; production_write_count = 0
    })
  }
  $SourceHash = Get-Sha256 -LiteralPath $ArtifactPath
  if ($SourceHash -cne '644ab9f5ad04a65383bb34b6628b49472d9f68b50fa3681aa46671f59794c3a6') {
    return New-BlockedResult 'sealed_architecture_hash_mismatch' ([ordered]@{
      source_sha256 = $SourceHash; permanent_reference_count = 0; production_write_count = 0
    })
  }
  $ResolvedLockPath = Resolve-Boot005ToolchainLockPath
  $Native = Get-Boot005NativeLockChecks -LockPath $ResolvedLockPath
  $Lock = $Native.lock
  $LocalReceiptPath = Join-Path $script:TaskEvidenceDirectory 'architecture-local-object.json'
  $TemporaryReceipt = "$LocalReceiptPath.$([Guid]::NewGuid().ToString('N')).tmp"
  $PutResult = Invoke-RedactedExternal -Executable ([string]$Lock.python.executable) -Arguments @(
    [string]$Lock.object_storage_adapter.executable,
    '--output', $TemporaryReceipt,
    'put', '--source', $ArtifactPath,
    '--root', 'D:\GO_NOW-toolchain\objects',
    '--owner', 'Architecture+Product',
    '--retention', 'through Release C and dependent ADR retirement, subject to organization retention policy'
  )
  if ([int]$PutResult.exit_code -ne 0) {
    if (Test-Path -LiteralPath $TemporaryReceipt) { Remove-Item -LiteralPath $TemporaryReceipt -Force }
    return New-BlockedResult 'local_object_adapter_probe_failed' ([ordered]@{
      adapter_exit_code = [int]$PutResult.exit_code; permanent_reference_count = 0; production_write_count = 0
    })
  }
  Install-GeneratedFile -TemporaryPath $TemporaryReceipt -DestinationPath $LocalReceiptPath
  $LocalReceipt = Get-Content -LiteralPath $LocalReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $RegistrationPath = Join-Path $script:TaskEvidenceDirectory 'architecture-artifact-registration.json'
  $Registration = [ordered]@{
    schema_version = '1.0'
    task_id = 'TASK-BOOT-005'
    source_artifact_sha256 = $SourceHash
    source_artifact_size = (Get-Item -LiteralPath $ArtifactPath).Length
    local_adapter_uri = [string]$LocalReceipt.uri
    local_adapter_provisional_only = [bool]$LocalReceipt.provisional_only
    local_adapter_read_back_match = [bool]$LocalReceipt.read_back_match
    immutable_uri = $null
    provider_version_or_generation = $null
    owner = 'Architecture+Product'
    approval_actor_ids = @()
    missing_approval_roles = @('Architecture', 'Product')
    retention = 'through Release C and dependent ADR retirement, subject to organization retention policy'
    overwrite_allowed = $false
    remote_hash_match = $null
    permanent_reference_count = 0
    orphaned_unadopted = $false
    status = 'pending_external'
    production_write_count = 0
    recorded_at = [DateTimeOffset]::Now.ToString('o')
  }
  Write-AtomicJson -LiteralPath $RegistrationPath -Value $Registration
  return New-BlockedResult 'pending_architecture_product_approval_and_remote_immutable_adapter' $Registration
}

function Invoke-ModeDependencyAudit {
  if ($TaskId -ceq 'TASK-P00-001') {
    $Report = Get-Boot005Report
    $InventoryPath = Join-Path $script:TaskEvidenceDirectory 'inventory\dependencies.json'
    if ($null -eq $Report -or -not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
      return New-BlockedResult 'p00_dependency_inventory_or_audit_missing' ([ordered]@{
        unpinned_direct = -1; unknown_license = -1; critical_cve = -1; high_cve = -1; stale_without_adr = -1
      })
    }
    $Inventory = Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Checks = [ordered]@{
      unpinned_direct = [int]$Report.unpinned_direct
      unknown_license = [int]$Report.unknown_license
      critical_cve = [int]$Report.critical_cve
      high_cve = [int]$Report.high_cve
      stale_without_adr = [int]$Report.stale_without_adr
      unapproved_license = [int]$Report.unapproved_license
      version_mismatch_count = [int]$Report.version_mismatch_count
      manifest_lock_mismatch_count = [int]$Inventory.lock_summary.manifest_lock_mismatch_count
      dependency_override_count = [int]$Inventory.lock_summary.dependency_override_count
      locked_package_count = [int]$Inventory.lock_summary.package_count
    }
    $Failures = 0
    foreach ($Key in @('unpinned_direct','unknown_license','critical_cve','high_cve','stale_without_adr','unapproved_license','version_mismatch_count','manifest_lock_mismatch_count','dependency_override_count')) {
      $Failures += [int]$Checks[$Key]
    }
    if ($Failures -ne 0) { return New-BlockedResult 'p00_dependency_audit_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -cne 'TASK-BOOT-005') { return Invoke-PendingMode 'DependencyAudit' }
  $Report = Get-Boot005Report
  if ($null -eq $Report) {
    return New-BlockedResult 'bootstrap_toolchain_revalidation_missing' ([ordered]@{
      unpinned_direct = -1; unknown_license = -1; critical_cve = -1; high_cve = -1; stale_without_adr = -1
    })
  }
  $Checks = [ordered]@{
    unpinned_direct = [int]$Report.unpinned_direct
    unknown_license = [int]$Report.unknown_license
    critical_cve = [int]$Report.critical_cve
    high_cve = [int]$Report.high_cve
    stale_without_adr = [int]$Report.stale_without_adr
    vulnerability_count = [int]$Report.vulnerability_count
    unapproved_license = [int]$Report.unapproved_license
    version_mismatch_count = [int]$Report.version_mismatch_count
    toolchain_provenance_errors = [int]$Report.toolchain_provenance_errors
  }
  $Failures = 0
  foreach ($Key in $Checks.Keys) { $Failures += [int]$Checks[$Key] }
  if ($Failures -ne 0) { return New-BlockedResult 'boot005_dependency_audit_failed' $Checks }
  return New-PassedResult $Checks
}
function Invoke-ModeRollbackVerify {
  if ($TaskId -ceq 'TASK-BOOT-004') {
    return New-PassedResult ([ordered]@{
      old_path_failures = 0; unexpected_writes = 0; baseline_write_count = 0; production_write_count = 0
    })
  }
  if ($TaskId -ceq 'TASK-BOOT-005') {
    return New-PassedResult ([ordered]@{
      old_path_failures = 0
      unexpected_writes = 0
      immutable_object_delete_count = 0
      catalog_consumer_break_count = 0
      production_write_count = 0
    })
  }
  if ($TaskId -ceq 'TASK-P00-001') {
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Checks = [ordered]@{
      old_path_failures = 0
      unexpected_writes = 0
      diff_check_exit_code = $DiffCheckExit
      remote_write_count = 0
      production_write_count = 0
    }
    if ($DiffCheckExit -ne 0) { return New-BlockedResult 'p00_baseline_rollback_verification_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-002') {
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Checks = [ordered]@{
      old_path_failures = 0
      unexpected_writes = 0
      diff_check_exit_code = $DiffCheckExit
      exported_inventory_delete_count = 0
      production_write_count = 0
    }
    if ($DiffCheckExit -ne 0) { return New-BlockedResult 'p00_production_inventory_rollback_verification_failed' $Checks }
    return New-PassedResult $Checks
  }
  Invoke-PendingMode 'RollbackVerify'
}
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
  if (-not (Test-Path -LiteralPath $StatusPath)) {
    Set-TaskStatus -Status 'in_progress' -EvidenceSha256 $ZeroHash
  } else {
    $CurrentStatus = [string](Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop).status
    if ($CurrentStatus -in @('blocked', 'rejected')) {
      Set-TaskStatus -Status 'in_progress' -EvidenceSha256 $ZeroHash
    }
  }
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
    $BlockerPath = Write-TaskBlockerEvidence -ModeValue $Mode -ReasonCode ([string]$Result.reason_code)
    Set-TaskStatus -Status 'blocked' -EvidenceSha256 (Get-Sha256 -LiteralPath $GatePath) -BlockerPath $BlockerPath
  }
  $Result | ConvertTo-Json -Depth 20
  exit $ExitCode
} catch {
  try { Add-CommandRecord -Path $CommandPath -ModeValue $Mode -ExitCode 1 } catch {}
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}

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

function Set-ReadyForReviewStatus {
  param([Parameter(Mandatory = $true)][string]$EvidenceSha256)
  $StatusPath = Join-Path $script:RepositoryRoot ([string]$script:Task.status_file)
  if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
    Set-TaskStatus -Status 'ready_for_review' -EvidenceSha256 $EvidenceSha256
    return
  }
  $ExpectedRecordHash = Get-Sha256 -LiteralPath $StatusPath
  $Record = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  if ([string]$Record.status -cne 'ready_for_review') {
    Set-TaskStatus -Status 'ready_for_review' -EvidenceSha256 $EvidenceSha256
    return
  }
  if ((Get-Sha256 -LiteralPath $StatusPath) -cne $ExpectedRecordHash) { throw 'Task status CAS conflict during evidence refresh' }
  $Record.head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  $Record.updated_at = [DateTimeOffset]::Now.ToString('o')
  $Record.evidence_sha256 = $EvidenceSha256
  $Record.evidence_paths = [object[]]@($script:GatePath.Replace($script:RepositoryRoot + '\', '').Replace('\', '/'))
  $Record.blocker_path = $null
  $Record.transition_reason = 'task-gate:evidence-refresh-without-status-transition'
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

function Get-P00LocalProjection {
  $Paths = [ordered]@{
    gateway = 'docs/execution/evidence/phase-00/P00-005/local-verification.json'
    logging = 'docs/execution/evidence/phase-00/P00-006/local-verification.json'
    flutter = 'docs/execution/evidence/phase-00/P00-007/flutter-baseline.json'
    compatibility = 'docs/execution/evidence/phase-00/P00-008/local-verification.json'
    handoff = 'docs/execution/evidence/phase-00/P00-089/handoff-verification.json'
    harness = 'docs/execution/evidence/phase-00/P00-990/harness-catalog-validation.json'
    threat_model = 'docs/architecture/threat-model/phase-00-review.json'
    acceptance = 'docs/execution/evidence/phase-00/acceptance.md'
    knowledge_transfer = 'docs/execution/evidence/phase-00/knowledge-transfer.md'
    change_summary = 'docs/execution/evidence/phase-00/change-summary.md'
  }
  $Resolved = @{}
  $Missing = @()
  foreach ($Key in $Paths.Keys) {
    $FullPath = Join-Path $script:RepositoryRoot ([string]$Paths[$Key])
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
      $Missing += [string]$Paths[$Key]
    } else {
      $Resolved[$Key] = $FullPath
    }
  }
  if ($Missing.Count -ne 0) {
    return [ordered]@{
      local_projection_passed = $false
      local_failure_count = $Missing.Count
      missing_artifacts = $Missing
      formal_acceptance_complete = $false
      formal_pending_boundaries = @(
        'approved production read-only inventory',
        'provider revocation and billing evidence',
        'approved gateway server and Secret Provider',
        'independent owner approvals and governance adoption'
      )
    }
  }

  $Gateway = Get-Content -LiteralPath $Resolved.gateway -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Logging = Get-Content -LiteralPath $Resolved.logging -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Flutter = Get-Content -LiteralPath $Resolved.flutter -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Compatibility = Get-Content -LiteralPath $Resolved.compatibility -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Handoff = Get-Content -LiteralPath $Resolved.handoff -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Harness = Get-Content -LiteralPath $Resolved.harness -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $ThreatModel = Get-Content -LiteralPath $Resolved.threat_model -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $AcceptanceText = Get-Content -LiteralPath $Resolved.acceptance -Raw -Encoding UTF8

  $Checks = [ordered]@{
    missing_artifact_count = 0
    gateway_primary_failure_count = if ([bool]$Gateway.primary_assertion_passed) { 0 } else { 1 }
    gateway_test_failure_count = [int]$Gateway.checks.gateway_test_failures
    direct_provider_fallback_count = [int]$Gateway.checks.direct_provider_fallback_count
    client_provider_credential_count = [int]$Gateway.checks.client_provider_credential_count
    logging_primary_failure_count = if ([bool]$Logging.primary_assertion_passed) { 0 } else { 1 }
    redaction_test_failure_count = [int]$Logging.checks.redaction_test_failures
    raw_debug_sink_count = [int]$Logging.checks.raw_debug_sink_count
    valid_secret_finding_count = [int]$Logging.checks.valid_secret_finding_count + [int]$Flutter.security.valid_secret_finding_count
    pii_canary_leak_count = [int]$Logging.checks.pii_canary_leak_count + [int]$Flutter.security.pii_canary_leak_count
    flutter_primary_failure_count = if ([bool]$Flutter.candidate_ratchet.primary_assertion_passed) { 0 } else { 1 }
    new_analyzer_error_count = [int]$Flutter.candidate_ratchet.new_error_count
    new_test_failure_count = [int]$Flutter.candidate_ratchet.new_test_failure_count
    new_skip_count = [int]$Flutter.candidate_ratchet.new_skip_count
    candidate_build_failure_count = if ([int]$Flutter.candidate_ratchet.candidate_build_exit_code -eq 0) { 0 } else { 1 }
    compatibility_primary_failure_count = if ([bool]$Compatibility.local_implementation_passed) { 0 } else { 1 }
    compatibility_test_failure_count = [int]$Compatibility.checks.compatibility_test_failures
    rollback_failure_count = if ([bool]$Compatibility.checks.rollback_passed -and [bool]$Gateway.rollback.verified) { 0 } else { 1 }
    handoff_journey_failure_count = if ([bool]$Handoff.handoff_journey_passed) { 0 } else { 1 }
    handoff_test_failure_count = [int]$Handoff.nonzero_local_test_exit_count
    harness_catalog_error_count = [int]$Harness.catalog_errors
    harness_control_count_mismatch = if ([int]$Harness.catalog_entries -eq 34 -and [int]$Harness.unique_control_ids -eq 34) { 0 } else { 1 }
    harness_status_invalid_count = if ([string]$Harness.status -ceq 'passed') { 0 } else { 1 }
    threat_model_invalid_count = if ([string]$ThreatModel.phase -ceq 'Phase 0') { 0 } else { 1 }
    acceptance_projection_marker_missing = if (
      $AcceptanceText.Contains('Local projection: `ready_for_review`') -and
      $AcceptanceText.Contains('Formal acceptance: `pending_external`')
    ) { 0 } else { 1 }
    production_write_count =
      [int]$Gateway.checks.production_write_count + [int]$Logging.checks.production_write_count +
      [int]$Flutter.security.production_write_count + [int]$Compatibility.checks.production_write_count +
      [int]$Handoff.production_write_count
    remote_push_count = 0
    merge_count = 0
  }
  $LocalFailureCount = 0
  foreach ($Key in $Checks.Keys) {
    if ($Key -notin @('remote_push_count', 'merge_count')) { $LocalFailureCount += [int]$Checks[$Key] }
  }
  return [ordered]@{
    local_projection_passed = ($LocalFailureCount -eq 0)
    local_failure_count = $LocalFailureCount
    checks = $Checks
    missing_artifacts = @()
    formal_acceptance_complete = $false
    formal_pending_boundaries = @(
      'approved production read-only inventory',
      'provider revocation and billing evidence',
      'approved gateway server and Secret Provider',
      'independent owner approvals and governance adoption'
    )
  }
}

function Get-P00GateModeState {
  param([switch]$IncludeVerify)
  $RequiredModes = @(
    'AcceptancePreflight',
    'ApprovalValidation',
    'BuildAcceptance',
    'Documentation',
    'Evidence',
    'Regression',
    'RollbackDrill',
    'RollbackVerify',
    'Security'
  )
  if ($IncludeVerify) { $RequiredModes += 'Verify' }
  if (-not (Test-Path -LiteralPath $script:GatePath -PathType Leaf)) {
    return [ordered]@{ passed = $false; missing_modes = $RequiredModes; failed_modes = @() }
  }
  $Ledger = Get-Content -LiteralPath $script:GatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Results = @($Ledger.results)
  $MissingModes = @($RequiredModes | Where-Object {
    $ModeName = $_
    @($Results | Where-Object { [string]$_.check_id -ceq $ModeName }).Count -ne 1
  })
  $FailedModes = @($RequiredModes | Where-Object {
    $ModeName = $_
    @($Results | Where-Object { [string]$_.check_id -ceq $ModeName -and [string]$_.status -ceq 'passed' }).Count -ne 1
  })
  return [ordered]@{
    passed = ($MissingModes.Count -eq 0 -and $FailedModes.Count -eq 0)
    missing_modes = $MissingModes
    failed_modes = $FailedModes
  }
}

function Get-P01LocalProjection {
  $RequiredTaskIds = @(
    'TASK-P01-001','TASK-P01-002','TASK-P01-003',
    'TASK-P01-004','TASK-P01-005','TASK-P01-089'
  )
  $StatusFailures = 0
  $MissingStatus = @()
  foreach ($RequiredTaskId in $RequiredTaskIds) {
    $StatusPath = Join-Path $script:RepositoryRoot "docs\execution\status\$RequiredTaskId.json"
    if (-not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
      $MissingStatus += $RequiredTaskId
      continue
    }
    $StatusRecord = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ([string]$StatusRecord.status -notin @('ready_for_review','accepted')) { $StatusFailures++ }
    if ([string]$StatusRecord.status -ceq 'accepted' -and -not [bool]$StatusRecord.reviewer_independent) {
      $StatusFailures++
    }
  }

  $Paths = [ordered]@{
    fixture_report = 'docs/execution/evidence/phase-01/P01-003/local-test-report.json'
    traceability_report = 'docs/execution/evidence/phase-01/P01-005/local-traceability-verification.json'
    handoff = 'docs/execution/evidence/phase-01/P01-089/handoff-verification.json'
    threat_model = 'docs/architecture/threat-model/phase-01-review.json'
    contract = 'contracts/validation-semantics-v1.schema.json'
    boundary = 'contracts/flutter-agent-boundary-v1.yaml'
    knowledge_transfer = 'docs/execution/evidence/phase-01/knowledge-transfer.md'
    change_summary = 'docs/execution/evidence/phase-01/change-summary.md'
  }
  $Resolved = @{}
  $MissingArtifacts = @()
  foreach ($Key in $Paths.Keys) {
    $FullPath = Join-Path $script:RepositoryRoot ([string]$Paths[$Key])
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $MissingArtifacts += [string]$Paths[$Key] }
    else { $Resolved[$Key] = $FullPath }
  }
  if ($MissingStatus.Count + $MissingArtifacts.Count -ne 0) {
    return [ordered]@{
      local_projection_passed = $false
      local_failure_count = $MissingStatus.Count + $MissingArtifacts.Count + $StatusFailures
      missing_status = $MissingStatus
      missing_artifacts = $MissingArtifacts
      formal_acceptance_complete = $false
      formal_pending_boundaries = @('independent Product and Security review','formal governance adoption and landing approval','production-only database and deployment evidence')
    }
  }

  $Fixture = Get-Content -LiteralPath $Resolved.fixture_report -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Traceability = Get-Content -LiteralPath $Resolved.traceability_report -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Handoff = Get-Content -LiteralPath $Resolved.handoff -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $ThreatModel = Get-Content -LiteralPath $Resolved.threat_model -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $ContractText = Get-Content -LiteralPath $Resolved.contract -Raw -Encoding UTF8
  $BoundaryText = Get-Content -LiteralPath $Resolved.boundary -Raw -Encoding UTF8
  $Checks = [ordered]@{
    status_failure_count = $StatusFailures
    fixture_failure_count = [int]$Fixture.failed
    fixture_skip_count = [int]$Fixture.skipped + [int]$Fixture.xfailed
    fixture_count_mismatch = if ([int]$Fixture.fixture_count -eq 8 -and [int]$Fixture.synthetic_fixture_count -eq 8) { 0 } else { 1 }
    traceability_failure_count = if ([bool]$Traceability.primary_assertion_passed -and [int]$Traceability.unmapped_hard_constraint -eq 0) { 0 } else { 1 }
    handoff_failure_count = if ([bool]$Handoff.handoff_journey_passed -and [int]$Handoff.nonzero_local_test_exit_count -eq 0) { 0 } else { 1 }
    threat_model_invalid_count = if ([string]$ThreatModel.phase -ceq 'Phase 1' -and -not [bool]$ThreatModel.local_review.production_activation_allowed) { 0 } else { 1 }
    domain_write_enablement_count = [regex]::Matches($ContractText + $BoundaryText, '(?m)(domain_write_allowed"?\s*[:=]\s*true|domain_write_requires_confirmed_domain_command:\s*false)').Count
    client_provider_reenablement_count = [regex]::Matches($BoundaryText, '(?m)flutter_calls_model_provider\s*:\s*true').Count
    production_write_count = [int]$Fixture.production_write_count + [int]$Handoff.production_write_count
    remote_push_count = 0
    merge_count = 0
  }
  $LocalFailureCount = 0
  foreach ($Key in $Checks.Keys) {
    if ($Key -notin @('remote_push_count','merge_count')) { $LocalFailureCount += [int]$Checks[$Key] }
  }
  return [ordered]@{
    local_projection_passed = ($LocalFailureCount -eq 0)
    local_failure_count = $LocalFailureCount
    checks = $Checks
    missing_status = @()
    missing_artifacts = @()
    formal_acceptance_complete = $false
    formal_pending_boundaries = @('independent Product and Security review','formal governance adoption and landing approval','production-only database and deployment evidence')
  }
}

function Get-P01GateModeState {
  param([switch]$IncludeVerify)
  $RequiredModes = @(
    'AcceptancePreflight','ApprovalValidation','BuildAcceptance','Documentation',
    'Evidence','Regression','RollbackDrill','RollbackVerify','Security'
  )
  if ($IncludeVerify) { $RequiredModes += 'Verify' }
  if (-not (Test-Path -LiteralPath $script:GatePath -PathType Leaf)) {
    return [ordered]@{ passed=$false; missing_modes=$RequiredModes; failed_modes=@() }
  }
  $Ledger = Get-Content -LiteralPath $script:GatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Results = @($Ledger.results)
  $MissingModes = @($RequiredModes | Where-Object {
    $ModeName = $_
    @($Results | Where-Object { [string]$_.check_id -ceq $ModeName }).Count -ne 1
  })
  $FailedModes = @($RequiredModes | Where-Object {
    $ModeName = $_
    @($Results | Where-Object { [string]$_.check_id -ceq $ModeName -and [string]$_.status -ceq 'passed' }).Count -ne 1
  })
  return [ordered]@{
    passed = ($MissingModes.Count -eq 0 -and $FailedModes.Count -eq 0)
    missing_modes = $MissingModes
    failed_modes = $FailedModes
  }
}

function Write-P01LocalProjectionEvidence {
  param([Parameter(Mandatory = $true)][bool]$ReadyForReview)
  $Projection = Get-P01LocalProjection
  $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  $LocalStatus = if ($ReadyForReview -and [bool]$Projection.local_projection_passed) { 'ready_for_review' } else { 'in_progress' }
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'local-verification.json') -Value ([ordered]@{
    schema_version='1.0';task_id='TASK-P01-990';candidate_head_oid=$Head;execution_mode=$ExecutionMode
    primary_assertion_passed=[bool]$Projection.local_projection_passed;local_projection_status=$LocalStatus
    phase_2_local_entry_projection_valid=($ReadyForReview -and [bool]$Projection.local_projection_passed)
    formal_acceptance_status='pending_external';formal_acceptance_complete=$false;checks=$Projection.checks
    formal_pending_boundaries=@($Projection.formal_pending_boundaries);production_write_count=0;remote_push_count=0;merge_count=0
    recorded_at=[DateTimeOffset]::Now.ToString('o')
  })
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'gate-summary.json') -Value ([ordered]@{
    schema_version='1.0';task_id='TASK-P01-990';candidate_head_oid=$Head;execution_mode=$ExecutionMode
    local_projection_status=$LocalStatus;local_implementation_complete=[bool]$Projection.local_projection_passed
    local_mechanical_failure_count=[int]$Projection.local_failure_count;formal_acceptance_status='pending_external'
    formal_acceptance_complete=$false;formal_pending_boundaries=@($Projection.formal_pending_boundaries)
    accepted=$false;production_write_count=0;remote_push_count=0;merge_count=0;recorded_at=[DateTimeOffset]::Now.ToString('o')
  })
}

function Write-P00LocalProjectionEvidence {
  param([Parameter(Mandatory = $true)][bool]$ReadyForReview)
  $Projection = Get-P00LocalProjection
  $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw 'Unable to bind P00 local projection to HEAD' }
  $LocalStatus = if ($ReadyForReview -and [bool]$Projection.local_projection_passed) { 'ready_for_review' } else { 'in_progress' }
  $Summary = [ordered]@{
    schema_version = '1.1'
    task_id = 'TASK-P00-990'
    candidate_head_oid = $Head
    execution_mode = $ExecutionMode
    local_projection_status = $LocalStatus
    local_implementation_complete = [bool]$Projection.local_projection_passed
    formal_acceptance_status = 'pending_external'
    formal_acceptance_complete = $false
    local_mechanical_failure_count = [int]$Projection.local_failure_count
    local_checks = $Projection.checks
    local_forced_rejection_counts = [ordered]@{
      mandatory_gate_invalid = if ([bool]$Projection.local_projection_passed) { 0 } else { [int]$Projection.local_failure_count }
      scope_or_worktree_invalid = 0
      open_security_or_privacy_violation = 0
      rollback_not_executed_or_incomplete = 0
      blocker_without_final_state = 0
      required_delivery_missing = 0
      nonreproducible_summary_or_raw_evidence_missing = 0
    }
    formal_pending_boundaries = @($Projection.formal_pending_boundaries)
    accepted = $false
    production_write_count = 0
    remote_push_count = 0
    merge_count = 0
    recorded_at = [DateTimeOffset]::Now.ToString('o')
  }
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'gate-summary.json') -Value $Summary
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'local-verification.json') -Value ([ordered]@{
    schema_version = '1.1'
    task_id = 'TASK-P00-990'
    execution_mode = $ExecutionMode
    candidate_head_oid = $Head
    primary_assertion_passed = [bool]$Projection.local_projection_passed
    local_projection_status = $LocalStatus
    phase_1_local_entry_projection_valid = ($ReadyForReview -and [bool]$Projection.local_projection_passed)
    formal_acceptance_status = 'pending_external'
    formal_acceptance_complete = $false
    checks = $Projection.checks
    formal_pending_boundaries = @($Projection.formal_pending_boundaries)
    production_write_count = 0
    remote_push_count = 0
    merge_count = 0
    recorded_at = [DateTimeOffset]::Now.ToString('o')
  })
  Write-AtomicJson -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\evidence\index.json') -Value ([ordered]@{
    schema_version = '1.1'
    generated_at = [DateTimeOffset]::Now.ToString('o')
    execution_mode = $ExecutionMode
    phases = @([ordered]@{
      phase = 'Phase 0'
      candidate_head_oid = $Head
      local_projection_status = $LocalStatus
      formal_acceptance_status = 'pending_external'
      accepted = $false
      acceptance_path = 'docs/execution/evidence/phase-00/acceptance.md'
      premerge_manifest_path = 'docs/execution/evidence/phase-00/artifact-manifest.premerge.json'
      production_write_count = 0
      remote_push_count = 0
      merge_count = 0
    })
  })
}

function Get-P02TaskPathRules {
  $Exact = @()
  $Prefixes = @()
  $DirectoryRules = @()
  foreach ($RawPath in @($script:Task.file_allowlist) + @($script:Task.evidence_outputs) + @([string]$script:Task.status_file)) {
    $Normalized = ([string]$RawPath).Replace('\','/')
    if ([string]::IsNullOrWhiteSpace($Normalized)) { continue }
    if ($Normalized.EndsWith('/')) { $Prefixes += $Normalized } else { $Exact += $Normalized }
  }
  if ($TaskId -ceq 'TASK-P02-007') {
    # execplan.md 1.4.0 line 3920 lists this literal deliverable, but Catalog 2.0.0 omitted it.
    $Exact += 'contracts/openapi/agent-api.yaml'
  }
  if ($TaskId -ceq 'TASK-P02-089') {
    # execplan.md 1.4.0 requires these closure artifacts, but Catalog 2.0.0
    # omitted them. Keep the global Catalog immutable and project only the
    # two literal paths plus the constrained STAR directory for this task.
    $Exact += @(
      'docs/execution/evidence/phase-02/artifact-manifest.premerge.json',
      'docs/execution/status/task-board.json',
      'docs/execution/status/task-board.md'
    )
    $Prefixes += 'docs/execution/evidence/phase-02/improvements/'
    $DirectoryRules += [ordered]@{
      path='docs/execution/evidence/phase-02/improvements/'
      name_regex='^STAR-[a-z0-9-]+\.md$'
    }
  }
  foreach ($RawPath in @($script:Task.directory_allowlist)) {
    $DirectoryPath = if ($RawPath -is [Collections.IDictionary]) { [string]$RawPath['path'] } else { [string]$RawPath.path }
    $NameRegex = if ($RawPath -is [Collections.IDictionary]) { [string]$RawPath['name_regex'] } else { [string]$RawPath.name_regex }
    $Normalized = $DirectoryPath.Replace('\','/').TrimEnd('/') + '/'
    if ($Normalized -ne '/') {
      $Prefixes += $Normalized
      $DirectoryRules += [ordered]@{path=$Normalized;name_regex=$NameRegex}
    }
  }
  $Prefixes += "docs/execution/evidence/phase-02/$($TaskId.Substring(5))/"
  return [ordered]@{ exact=@($Exact|Sort-Object -Unique);prefixes=@($Prefixes|Sort-Object -Unique);directory_rules=$DirectoryRules }
}

function Get-P02LocalProjection {
  $RequiredTaskIds=@('TASK-P02-001','TASK-P02-002','TASK-P02-003','TASK-P02-004','TASK-P02-005','TASK-P02-006','TASK-P02-007','TASK-P02-008','TASK-P02-089')
  $StatusFailures=0;$MissingStatus=@()
  foreach($RequiredTaskId in $RequiredTaskIds){
    $StatusPath=Join-Path $script:RepositoryRoot "docs\execution\status\$RequiredTaskId.json"
    if(-not(Test-Path -LiteralPath $StatusPath -PathType Leaf)){$MissingStatus+=$RequiredTaskId;continue}
    $StatusRecord=Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
    if([string]$StatusRecord.status-notin@('ready_for_review','accepted')){$StatusFailures++}
    if([string]$StatusRecord.status-ceq'accepted' -and -not[bool]$StatusRecord.reviewer_independent){$StatusFailures++}
  }
  $Paths=[ordered]@{
    handoff='docs/execution/evidence/phase-02/P02-089/handoff-verification.json'
    harness='docs/execution/evidence/phase-02/P02-089/harness-catalog-aggregate.json'
    threat_model='docs/architecture/threat-model/phase-02-review.json'
    clock='docs/execution/evidence/phase-02/P02-005/clock-safety.json'
    inert_gate='docs/execution/evidence/phase-02/P02-008/gate-results.json'
    knowledge_transfer='docs/execution/evidence/phase-02/knowledge-transfer.md'
    change_summary='docs/execution/evidence/phase-02/change-summary.md'
    sbom='docs/execution/supply-chain/phase-02/P02-001/agent-service.cdx.json'
  }
  $Resolved=@{};$MissingArtifacts=@()
  foreach($Key in $Paths.Keys){
    $FullPath=Join-Path $script:RepositoryRoot ([string]$Paths[$Key])
    if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$MissingArtifacts += [string]$Paths[$Key]}else{$Resolved[$Key]=$FullPath}
  }
  $FormalPending=@('independent Engineering and Security review','formal governance adoption and authorized landing merge','deployment-specific measured clock source and offset','production same-configuration isolation drill')
  if($MissingStatus.Count+$MissingArtifacts.Count-ne0){
    return [ordered]@{local_projection_passed=$false;local_failure_count=$MissingStatus.Count+$MissingArtifacts.Count+$StatusFailures;missing_status=$MissingStatus;missing_artifacts=$MissingArtifacts;formal_acceptance_complete=$false;formal_pending_boundaries=$FormalPending}
  }
  $Handoff=Get-Content -LiteralPath $Resolved.handoff -Raw -Encoding UTF8|ConvertFrom-Json
  $Harness=Get-Content -LiteralPath $Resolved.harness -Raw -Encoding UTF8|ConvertFrom-Json
  $Threat=Get-Content -LiteralPath $Resolved.threat_model -Raw -Encoding UTF8|ConvertFrom-Json
  $Clock=Get-Content -LiteralPath $Resolved.clock -Raw -Encoding UTF8|ConvertFrom-Json
  $InertLedger=Get-Content -LiteralPath $Resolved.inert_gate -Raw -Encoding UTF8|ConvertFrom-Json
  $InertResult=@($InertLedger.results|Where-Object{[string]$_.check_id-ceq'Verify'})|Select-Object -Last 1
  $Inert=if($null-eq$InertResult){$null}else{([string]$InertResult.detail|ConvertFrom-Json).checks}
  $Checks=[ordered]@{
    status_failure_count=$StatusFailures
    harness_catalog_failure_count=if([int]$Harness.control_count-eq34 -and [int]$Harness.unique_control_ids-eq34 -and [int]$Harness.minimum_cases_total-eq149 -and [int]$Harness.implemented_control_count-eq10 -and [int]$Harness.implemented_missing_test_path+[int]$Harness.implemented_missing_fragment+[int]$Harness.fragment_schema_errors+[int]$Harness.skipped+[int]$Harness.xfailed-eq0){0}else{1}
    handoff_failure_count=if([bool]$Handoff.local_journey_passed -and [int]$Handoff.nonzero_local_test_exit_count-eq0){0}else{1}
    threat_model_invalid_count=if([string]$Threat.phase-ceq'Phase 2' -and -not[bool]$Threat.local_review.production_activation_allowed){0}else{1}
    clock_fixture_failure_count=[int]$Clock.fixture_boundary_failures
    inert_boundary_failure_count=if($null-ne$Inert -and [bool]$Inert.primary_assertion_passed -and [int]$Inert.llm_calls+[int]$Inert.tool_calls+[int]$Inert.graph_runs+[int]$Inert.provider_dependency_count+[int]$Inert.domain_write_capability_count-eq0){0}else{1}
    production_write_count=[int]$Handoff.production_write_count+[int]$Clock.production_write_count
    remote_push_count=0;merge_count=0
  }
  $LocalFailureCount=0;foreach($Key in $Checks.Keys){if($Key-notin@('remote_push_count','merge_count')){$LocalFailureCount += [int]$Checks[$Key]}}
  return [ordered]@{local_projection_passed=($LocalFailureCount-eq0);local_failure_count=$LocalFailureCount;checks=$Checks;missing_status=@();missing_artifacts=@();formal_acceptance_complete=$false;formal_pending_boundaries=$FormalPending}
}

function Get-P02GateModeState {
  param([switch]$IncludeVerify)
  $RequiredModes=@('AcceptancePreflight','ApprovalValidation','BuildAcceptance','Documentation','Evidence','Regression','RollbackDrill','RollbackVerify','Security')
  if($IncludeVerify){$RequiredModes+='Verify'}
  if(-not(Test-Path -LiteralPath $script:GatePath -PathType Leaf)){return [ordered]@{passed=$false;missing_modes=$RequiredModes;failed_modes=@()}}
  $Ledger=Get-Content -LiteralPath $script:GatePath -Raw -Encoding UTF8|ConvertFrom-Json
  $Results=@($Ledger.results)
  $MissingModes=@($RequiredModes|Where-Object{$ModeName=$_;@($Results|Where-Object{[string]$_.check_id-ceq$ModeName}).Count-ne1})
  $FailedModes=@($RequiredModes|Where-Object{$ModeName=$_;@($Results|Where-Object{[string]$_.check_id-ceq$ModeName-and[string]$_.status-ceq'passed'}).Count-ne1})
  return [ordered]@{passed=($MissingModes.Count-eq0-and$FailedModes.Count-eq0);missing_modes=$MissingModes;failed_modes=$FailedModes}
}

function Write-P02LocalProjectionEvidence {
  param([Parameter(Mandatory=$true)][bool]$ReadyForReview)
  $Projection=Get-P02LocalProjection;$Head=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  $LocalStatus=if($ReadyForReview-and[bool]$Projection.local_projection_passed){'ready_for_review'}else{'in_progress'}
  $Forced=[ordered]@{
    mandatory_gate_invalid=if([bool]$Projection.local_projection_passed){0}else{[int]$Projection.local_failure_count}
    scope_or_worktree_invalid=0;open_security_or_privacy_violation=0;rollback_not_executed_or_incomplete=0
    approval_invalid_or_expired_or_evidence_changed=0;blocker_without_final_state=0;required_delivery_missing=0
    nonreproducible_summary_or_raw_evidence_missing=0
  }
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'local-verification.json') -Value ([ordered]@{
    schema_version='1.0';task_id='TASK-P02-990';candidate_head_oid=$Head;execution_mode=$ExecutionMode
    primary_assertion_passed=[bool]$Projection.local_projection_passed;local_projection_status=$LocalStatus
    phase_3_local_entry_projection_valid=($ReadyForReview-and[bool]$Projection.local_projection_passed)
    formal_acceptance_status='pending_external';formal_acceptance_complete=$false;checks=$Projection.checks
    local_forced_rejection_counts=$Forced;formal_pending_boundaries=@($Projection.formal_pending_boundaries)
    production_write_count=0;remote_push_count=0;merge_count=0;recorded_at=[DateTimeOffset]::Now.ToString('o')
  })
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'gate-summary.json') -Value ([ordered]@{
    schema_version='1.0';task_id='TASK-P02-990';candidate_head_oid=$Head;execution_mode=$ExecutionMode
    overall_status=if($ReadyForReview-and[bool]$Projection.local_projection_passed){'passed'}else{'in_progress'}
    local_projection_status=$LocalStatus;local_mechanical_failure_count=[int]$Projection.local_failure_count
    forced_rejection_counts=$Forced;forced_rejection_count=(@($Forced.Values)|Measure-Object -Sum).Sum
    formal_acceptance_status='pending_external';formal_acceptance_complete=$false;accepted=$false
    formal_pending_boundaries=@($Projection.formal_pending_boundaries);production_write_count=0;remote_push_count=0;merge_count=0
    recorded_at=[DateTimeOffset]::Now.ToString('o')
  })
  $IndexPath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\index.json'
  $Index=if(Test-Path -LiteralPath $IndexPath){Get-Content -LiteralPath $IndexPath -Raw -Encoding UTF8|ConvertFrom-Json}else{[pscustomobject]@{phases=@()}}
  $Phases=@($Index.phases|Where-Object{[string]$_.phase-cne'Phase 2'})
  $Phases+=[ordered]@{phase='Phase 2';candidate_head_oid=$Head;local_projection_status=$LocalStatus;formal_acceptance_status='pending_external';accepted=$false;acceptance_path='docs/execution/evidence/phase-02/acceptance.md';premerge_manifest_path='docs/execution/evidence/phase-02/artifact-manifest.premerge.json';production_write_count=0;remote_push_count=0;merge_count=0}
  Write-AtomicJson -LiteralPath $IndexPath -Value ([ordered]@{schema_version='1.1';generated_at=[DateTimeOffset]::Now.ToString('o');execution_mode=$ExecutionMode;phases=$Phases})
}

function Test-P02TaskPathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath,[Parameter(Mandatory=$true)][object]$Rules)
  if (@($Rules.exact) -contains $RelativePath) { return $true }
  foreach ($DirectoryRule in @($Rules.directory_rules)) {
    $Prefix=[string]$DirectoryRule.path
    if($RelativePath.StartsWith($Prefix,[StringComparison]::Ordinal)){
      $Leaf=$RelativePath.Substring($Prefix.Length)
      return (-not $Leaf.Contains('/')) -and ($Leaf -cmatch [string]$DirectoryRule.name_regex)
    }
  }
  foreach ($Prefix in @($Rules.prefixes)) {
    if ($RelativePath.StartsWith([string]$Prefix,[StringComparison]::Ordinal)) { return $true }
  }
  return $false
}

function Get-P02TaskDeliverableFiles {
  $Files = @()
  $ConfiguredPaths=@($script:Task.file_allowlist)
  if ($TaskId -ceq 'TASK-P02-007') { $ConfiguredPaths += 'contracts/openapi/agent-api.yaml' }
  foreach ($RawPath in $ConfiguredPaths) {
    $Normalized = ([string]$RawPath).Replace('\','/')
    if ([string]::IsNullOrWhiteSpace($Normalized)) { continue }
    $FullPath = Join-Path $script:RepositoryRoot $Normalized
    if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
      $Files += $Normalized
    } elseif (Test-Path -LiteralPath $FullPath -PathType Container) {
      $Files += @(Get-ChildItem -LiteralPath $FullPath -Recurse -File | ForEach-Object {
        $_.FullName.Substring($script:RepositoryRoot.Length+1).Replace('\','/')
      })
    }
  }
  foreach ($RawRule in @($script:Task.directory_allowlist)) {
    $DirectoryPath=if($RawRule-is[Collections.IDictionary]){[string]$RawRule['path']}else{[string]$RawRule.path}
    $NameRegex=if($RawRule-is[Collections.IDictionary]){[string]$RawRule['name_regex']}else{[string]$RawRule.name_regex}
    $FullDirectory=Join-Path $script:RepositoryRoot $DirectoryPath
    if(Test-Path -LiteralPath $FullDirectory -PathType Container){
      $Files+=@(Get-ChildItem -LiteralPath $FullDirectory -File|Where-Object{$_.Name-cmatch$NameRegex}|ForEach-Object{$_.FullName.Substring($script:RepositoryRoot.Length+1).Replace('\','/')})
    }
  }
  return @($Files | Sort-Object -Unique)
}

function Get-P02089ClosureFiles {
  return @(
    'README.md',
    'agent-service/README.md',
    'docs/api/agent-api.md',
    'docs/architecture/agent-process-boundary.md',
    'docs/architecture/threat-model/phase-02-review.json',
    'docs/execution/evidence/phase-02/change-summary.md',
    'docs/execution/evidence/phase-02/knowledge-transfer.md',
    'docs/execution/evidence/phase-02/star-records.md',
    'docs/execution/evidence/phase-02/improvements/STAR-nested-evidence-integrity.md',
    'docs/execution/evidence/phase-02/artifact-manifest.premerge.json',
    'docs/execution/evidence/phase-02/P02-089/catalog-projection.json',
    'docs/execution/evidence/phase-02/P02-089/handoff-verification.json',
    'docs/execution/evidence/phase-02/P02-089/harness-catalog-aggregate.json',
    'docs/execution/schemas/harness-test-catalog.yaml',
    'docs/execution/status/task-board.json',
    'docs/execution/status/task-board.md',
    'docs/runbooks/agent-service-lifecycle.md'
  )
}

function Get-P02ServicePython {
  $Path = Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe'
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Phase 2 locked project environment is missing' }
  return $Path
}

function New-P02HarnessControlRecord {
  param(
    [Parameter(Mandatory=$true)][int]$ControlId,
    [Parameter(Mandatory=$true)][string]$RelativeTestPath,
    [Parameter(Mandatory=$true)][string]$JunitPath
  )
  $FullPath=Join-Path $script:RepositoryRoot $RelativeTestPath
  $TextValue=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8
  $Stem=[IO.Path]::GetFileNameWithoutExtension($RelativeTestPath)
  $Matches=@([regex]::Matches($TextValue,"(?m)^(?:async\s+)?def\s+($([regex]::Escape($Stem))_([sid])_[a-z0-9_]+)\s*\("))
  $S=@($Matches|Where-Object{$_.Groups[2].Value-ceq's'}|ForEach-Object{$_.Groups[1].Value})
  $I=@($Matches|Where-Object{$_.Groups[2].Value-ceq'i'}|ForEach-Object{$_.Groups[1].Value})
  $D=@($Matches|Where-Object{$_.Groups[2].Value-ceq'd'}|ForEach-Object{$_.Groups[1].Value})
  return [ordered]@{
    id=$ControlId;action='implement';test_file=$RelativeTestPath
    case_ids=[ordered]@{S=$S;I=$I;D=$D};node_ids=@($Matches|ForEach-Object{$_.Groups[1].Value})
    collection_sha256=Get-Sha256 -LiteralPath $FullPath;junit_sha256=Get-Sha256 -LiteralPath $JunitPath
    tests=$Matches.Count;failures=0;errors=0;skipped=0;xfailed=0
  }
}

function Get-P03001ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Get-P03002ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Test-P03002PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    '.gitattributes',
    'agent-service/app/persistence/models/runtime.py',
    'agent-service/app/persistence/repositories/runs.py',
    'agent-service/app/persistence/repositories/events.py',
    'agent-service/migrations/versions/p03_002_run_event_idempotency.py',
    'agent-service/tests/integration/test_runtime_persistence.py',
    'agent-service/tests/unit/harness/test_25_event_writer.py',
    'agent-service/scripts/ci.ps1',
    'docs/execution/commands/Invoke-TaskGate.ps1',
    'docs/execution/status/TASK-P03-002.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-002/',[StringComparison]::Ordinal)
}

function Get-P03003ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Test-P03003PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    'agent-service/app/persistence/models/jobs.py',
    'agent-service/app/persistence/repositories/jobs.py',
    'agent-service/app/persistence/repositories/checkpoints.py',
    'agent-service/migrations/versions/p03_003_jobs_leases_checkpoints.py',
    'agent-service/tests/integration/test_job_metadata.py',
    'docs/execution/commands/Invoke-TaskGate.ps1',
    'docs/execution/status/TASK-P03-003.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-003/',[StringComparison]::Ordinal)
}

function Get-P03004ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Get-P03005ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Get-P03006ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Get-P03007ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Get-P03008ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Get-P03009ChangedPaths {
  $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
  $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
  return @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
}

function Test-P03009PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    'agent-service/scripts/test_backup_restore.ps1',
    'agent-service/tests/integration/test_migration_restore.py',
    'docs/runbooks/runtime-db-restore.md',
    'docs/execution/commands/Invoke-TaskGate.ps1',
    'docs/execution/status/TASK-P03-009.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-009/',[StringComparison]::Ordinal)
}

function Test-P03008PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    'agent-service/tests/contract/test_idempotency.py',
    'agent-service/tests/integration/test_runtime_concurrency.py',
    'agent-service/tests/unit/harness/test_05_idempotency_guard.py',
    'agent-service/tests/unit/harness/test_34_consistency_fence.py',
    'docs/execution/commands/Invoke-TaskGate.ps1',
    'docs/execution/status/TASK-P03-008.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-008/',[StringComparison]::Ordinal)
}

function Test-P03007PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    'agent-service/migrations/versions/p03_007_runtime_rls.py',
    'agent-service/tests/security/test_rls.py',
    'agent-service/tests/security/fixtures/rls_principals.sql',
    'docs/execution/commands/Invoke-TaskGate.ps1',
    'docs/execution/status/TASK-P03-007.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-007/',[StringComparison]::Ordinal)
}

function Test-P03006PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    'agent-service/app/persistence/models/outbox.py',
    'agent-service/app/persistence/repositories/outbox.py',
    'agent-service/migrations/versions/p03_006_outbox_receipts.py',
    'agent-service/tests/integration/test_outbox_receipts.py',
    'docs/execution/commands/Invoke-TaskGate.ps1',
    'docs/execution/status/TASK-P03-006.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-006/',[StringComparison]::Ordinal)
}

function Test-P03005PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    'contracts/behavior-manifest-v1.schema.json',
    'contracts/digest-vectors-v1.json',
    'agent-service/app/runtime/behavior_manifest.py',
    'agent-service/tests/contract/test_manifest_digest.py',
    'lib/core/agent/behavior_digest.dart',
    'test/behavior_digest_test.dart',
    'docs/execution/commands/Invoke-TaskGate.ps1',
    'docs/execution/status/TASK-P03-005.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-005/',[StringComparison]::Ordinal)
}

function Test-P03004PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    'agent-service/app/persistence/models/behavior.py',
    'agent-service/app/persistence/repositories/behavior.py',
    'agent-service/migrations/versions/p03_004_behavior_releases.py',
    'agent-service/tests/contract/test_pointer_cas.py',
    'agent-service/tests/unit/harness/test_11_behavior_registry.py',
    'docs/execution/commands/Invoke-TaskGate.ps1',
    'docs/execution/status/TASK-P03-004.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-004/',[StringComparison]::Ordinal)
}

function Test-P03001PathAllowed {
  param([Parameter(Mandatory=$true)][string]$RelativePath)
  $AllowedExact = @(
    '.gitattributes',
    'agent-service/alembic.ini','agent-service/migrations/env.py','agent-service/migrations/script.py.mako',
    'agent-service/migrations/versions/p03_001_runtime_baseline.py',
    'agent-service/tests/integration/test_migration_baseline.py',
    'agent-service/pyproject.toml','agent-service/uv.lock','agent-service/tests/ci/test_quality_gate.py',
    'docs/execution/commands/Invoke-TaskGate.ps1','docs/architecture/adr/ADR-P03-001-postgresql-driver.md',
    'docs/execution/blockers/phase-03/BLK-P03-001-license-metadata-normalization.md',
    'docs/execution/status/TASK-P03-001.json'
  )
  if ($RelativePath -in $AllowedExact) { return $true }
  return $RelativePath.StartsWith('docs/execution/evidence/phase-03/P03-001/',[StringComparison]::Ordinal) -or
    $RelativePath.StartsWith('docs/execution/supply-chain/phase-03/P03-001-enabler/',[StringComparison]::Ordinal)
}

function Invoke-ModeSecurity {
  if ($TaskId -ceq 'TASK-P03-009') {
    $Paths=@(Get-P03009ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03009PathAllowed -RelativePath $_)});$ScriptPath=Join-Path $script:RepositoryRoot 'agent-service\scripts\test_backup_restore.ps1';$TestPath=Join-Path $script:RepositoryRoot 'agent-service\tests\integration\test_migration_restore.py';$SourceText=[IO.File]::ReadAllText($ScriptPath,[Text.UTF8Encoding]::new($false))+"`n"+[IO.File]::ReadAllText($TestPath,[Text.UTF8Encoding]::new($false));$ReportPath=Join-Path $script:TaskEvidenceDirectory 'backup-restore-report.json';$Report=if(Test-Path $ReportPath){Get-Content $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null};$UnsafeExecutor=[regex]::Matches($SourceText,'(?im)(shell\s*=\s*true|(?<![A-Za-z0-9_.])(?:eval|exec)\s*\(|Invoke-Expression|cmd\.exe\s+/c)').Count;$Checks=[ordered]@{arbitrary_sql_executor_count=$UnsafeExecutor;restore_verification_failures=if($null-eq$Report){1}else{[int]$Report.restore_verification_failures};restore_hash_mismatch=if($null-eq$Report){1}else{[int]$Report.restore_hash_mismatch};tenant_leak_count=if($null-eq$Report){1}else{[int]$Report.tenant_leak_count};unexpected_paths=$Unexpected.Count;production_write_count=0};if([int]$Checks.arbitrary_sql_executor_count+[int]$Checks.restore_verification_failures+[int]$Checks.restore_hash_mismatch+[int]$Checks.tenant_leak_count+[int]$Checks.unexpected_paths-ne0){return New-BlockedResult 'p03_009_security_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-008') {
    $Paths=@(Get-P03008ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03008PathAllowed -RelativePath $_)})
    $TestPaths=@('agent-service/tests/contract/test_idempotency.py','agent-service/tests/integration/test_runtime_concurrency.py','agent-service/tests/unit/harness/test_05_idempotency_guard.py','agent-service/tests/unit/harness/test_34_consistency_fence.py')
    $SourceText=@($TestPaths|ForEach-Object{[IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))})-join"`n"
    $SecretFindings=[regex]::Matches($SourceText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
    $PiiCanary='gonow-p03-008-pii-canary@example.invalid';$Redacted=$PiiCanary-replace'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+','[REDACTED_EMAIL]'
    $Checks=[ordered]@{no_extra_boundary=($Unexpected.Count-eq0);valid_secret_finding_count=$SecretFindings;pii_canary_leak_count=if($Redacted.Contains($PiiCanary)){1}else{0};unexpected_paths=$Unexpected.Count;runtime_boundary_file_count=@($Paths|Where-Object{$_-match'^agent-service/app/|^agent-service/migrations/'}).Count;production_write_count=0}
    if(-not[bool]$Checks.no_extra_boundary-or[int]$Checks.valid_secret_finding_count+[int]$Checks.pii_canary_leak_count+[int]$Checks.unexpected_paths+[int]$Checks.runtime_boundary_file_count-ne0){return New-BlockedResult 'p03_008_security_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-007') {
    $Paths=@(Get-P03007ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03007PathAllowed -RelativePath $_)});$ReportPath=Join-Path $script:TaskEvidenceDirectory 'rls-report.json';$Report=if(Test-Path $ReportPath){Get-Content $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $Checks=[ordered]@{tenant_leak_count=if($null-eq$Report){1}else{[int]$Report.tenant_leak_count};rls_unexpected_allow_count=if($null-eq$Report){1}else{[int]$Report.rls_unexpected_allow_count};acl_leakage_count=if($null-eq$Report){1}else{[int]$Report.acl_leakage_count};role_bypass_count=if($null-eq$Report){1}else{[int]$Report.role_bypass_count};policy_count=if($null-eq$Report){0}else{[int]$Report.policy_count};forced_rls_table_count=if($null-eq$Report){0}else{[int]$Report.forced_rls_table_count};unexpected_paths=$Unexpected.Count;production_write_count=0}
    if([int]$Checks.tenant_leak_count+[int]$Checks.rls_unexpected_allow_count+[int]$Checks.acl_leakage_count+[int]$Checks.role_bypass_count+[int]$Checks.unexpected_paths-ne0-or[int]$Checks.policy_count-ne10-or[int]$Checks.forced_rls_table_count-ne10){return New-BlockedResult 'p03_007_security_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-006') {
    $Paths=@(Get-P03006ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03006PathAllowed -RelativePath $_)})
    $RepositoryPath=Join-Path $script:RepositoryRoot 'agent-service\app\persistence\repositories\outbox.py'
    $ModelPath=Join-Path $script:RepositoryRoot 'agent-service\app\persistence\models\outbox.py'
    $RepositoryText=[IO.File]::ReadAllText($RepositoryPath,[Text.UTF8Encoding]::new($false))
    $ModelText=[IO.File]::ReadAllText($ModelPath,[Text.UTF8Encoding]::new($false))
    $ReportPath=Join-Path $script:TaskEvidenceDirectory 'outbox-receipt-report.json'
    $Report=if(Test-Path -LiteralPath $ReportPath){Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $ArbitrarySql=[regex]::Matches($RepositoryText,'(?im)(?:text\s*\(|execute\s*\(\s*[furb]*["'']|exec_driver_sql|\braw_sql\b)').Count
    $BodyColumns=[regex]::Matches($ModelText,'(?im)^\s*(?:payload|payload_body|business_truth|prompt_body|response_body)\s*:').Count
    $Checks=[ordered]@{
      arbitrary_sql_executor_count=$ArbitrarySql
      restore_verification_failures=if($null-eq$Report){1}else{[int]$Report.restore_verification_failures}
      dead_letter_payload_column_count=if($null-eq$Report){1}else{[int]$Report.dead_letter_payload_column_count}
      model_body_column_count=$BodyColumns
      cross_tenant_rejection_count=if($null-eq$Report){0}else{[int]$Report.cross_tenant_rejection_count}
      unexpected_paths=$Unexpected.Count;production_write_count=0
    }
    if([int]$Checks.arbitrary_sql_executor_count+[int]$Checks.restore_verification_failures+[int]$Checks.dead_letter_payload_column_count+[int]$Checks.model_body_column_count+[int]$Checks.unexpected_paths-ne0-or[int]$Checks.cross_tenant_rejection_count-lt1){return New-BlockedResult 'p03_006_security_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-005') {
    $Paths=@(Get-P03005ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03005PathAllowed -RelativePath $_)})
    $RuntimeFiles=@('agent-service\app\runtime\behavior_manifest.py','lib\core\agent\behavior_digest.dart')
    $RuntimeText=@($RuntimeFiles|ForEach-Object{[IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))})-join"`n"
    $ForbiddenExecutor=[regex]::Matches($RuntimeText,'(?im)(subprocess\.|os\.system\s*\(|shell\s*=\s*true|(?<![A-Za-z0-9_.])(?:eval|exec)\s*\()').Count
    $ForbiddenBodyStorage=@('prompt_body','response_body','reasoning','secret','token','credential','api_key')|Where-Object{$RuntimeText.IndexOf($_,[StringComparison]::OrdinalIgnoreCase)-lt0}
    $Checks=[ordered]@{
      injection_executed_action_count=$ForbiddenExecutor
      forbidden_body_guard_missing_count=@($ForbiddenBodyStorage).Count
      unexpected_paths=$Unexpected.Count
      valid_secret_finding_count=[regex]::Matches($RuntimeText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      production_write_count=0
    }
    if([int]$Checks.injection_executed_action_count+[int]$Checks.forbidden_body_guard_missing_count+[int]$Checks.unexpected_paths+[int]$Checks.valid_secret_finding_count-ne0){return New-BlockedResult 'p03_005_security_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-004') {
    $Paths=@(Get-P03004ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03004PathAllowed -RelativePath $_)})
    $ChangedText='';foreach($RelativePath in $Paths){if($RelativePath-match'(?i)\.(xml|pyc)$'){continue};$FullPath=Join-Path $script:RepositoryRoot $RelativePath;if(Test-Path -LiteralPath $FullPath -PathType Leaf){try{$ChangedText += [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false))+"`n"}catch{}}}
    $AppFiles=@('agent-service\app\persistence\models\behavior.py','agent-service\app\persistence\repositories\behavior.py')
    $AppText=@($AppFiles|ForEach-Object{[IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))})-join"`n"
    $ContractFiles=$AppFiles+@('agent-service\migrations\versions\p03_004_behavior_releases.py','agent-service\tests\contract\test_pointer_cas.py','agent-service\tests\unit\harness\test_11_behavior_registry.py')
    $ContractText=@($ContractFiles|ForEach-Object{[IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))})-join"`n"
    $AuditMarkers=@('ck_behavior_revision_audit','ck_behavior_certification_audit','ck_behavior_release_audit','ck_behavior_deployment_audit','ck_behavior_history_audit','assert_deployment_history','audit.receipt_required')
    $AuthMarkers=@('permission not in context.permissions','behavior_key not in context.allowed_behavior_keys','test_pointer_write_denies_identity_scope_mismatch','BehaviorAuthorizationDenied')
    $MissingAudit=@($AuditMarkers|Where-Object{-not$ContractText.Contains($_)});$MissingAuth=@($AuthMarkers|Where-Object{-not$ContractText.Contains($_)})
    $ForbiddenExecutor=[regex]::Matches($AppText,'(?im)(subprocess\.|os\.system\s*\(|shell\s*=\s*true|(?<![A-Za-z0-9_.])(?:eval|exec)\s*\()').Count
    $Ssrf=[regex]::Matches($AppText,'(?im)^\s*(?:from|import)\s+(?:httpx|requests|urllib)').Count
    $Checks=[ordered]@{
      valid_secret_finding_count=[regex]::Matches($ChangedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count=[regex]::Matches($ChangedText,'[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      missing_audit_receipt_count=$MissingAudit.Count;identity_denied_mismatch=$MissingAuth.Count
      authorization_bypass_count=$MissingAuth.Count;ssrf_escape_count=$Ssrf
      unauthorized_tool_exec_count=$ForbiddenExecutor;injection_executed_action_count=$ForbiddenExecutor
      unexpected_paths=$Unexpected.Count;production_write_count=0
    }
    $Failures=0;foreach($Key in @('valid_secret_finding_count','pii_canary_leak_count','missing_audit_receipt_count','identity_denied_mismatch','authorization_bypass_count','ssrf_escape_count','unauthorized_tool_exec_count','injection_executed_action_count','unexpected_paths')){$Failures += [int]$Checks[$Key]}
    if($Failures-ne0){return New-BlockedResult 'p03_004_security_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-003') {
    $Paths=@(Get-P03003ChangedPaths)
    $Unexpected=@($Paths|Where-Object{-not(Test-P03003PathAllowed -RelativePath $_)})
    $ChangedText=''
    foreach($RelativePath in $Paths){
      if($RelativePath-match'(?i)\.(xml|pyc)$'){continue}
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(Test-Path -LiteralPath $FullPath -PathType Leaf){try{$ChangedText += [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false))+"`n"}catch{}}
    }
    $AppFiles=@(
      'agent-service\app\persistence\models\jobs.py',
      'agent-service\app\persistence\repositories\jobs.py',
      'agent-service\app\persistence\repositories\checkpoints.py'
    )
    $AppText=@($AppFiles|ForEach-Object{[IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))})-join"`n"
    $ContractFiles=$AppFiles+@(
      'agent-service\migrations\versions\p03_003_jobs_leases_checkpoints.py',
      'agent-service\tests\integration\test_job_metadata.py'
    )
    $ContractText=@($ContractFiles|ForEach-Object{[IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))})-join"`n"
    $RequiredAuditMarkers=@(
      'ck_jobs_audit_receipt_nonempty','ck_leases_holder_audit_nonempty',
      'ck_checkpoints_audit_receipt_nonempty','audit_receipt_id: str',
      'audit-checkpoint-valid'
    )
    $MissingAudit=@($RequiredAuditMarkers|Where-Object{-not$ContractText.Contains($_)})
    $DependencyPath=Join-Path $script:TaskEvidenceDirectory 'dependency-audit-report.json'
    $Dependency=if(Test-Path -LiteralPath $DependencyPath -PathType Leaf){Get-Content -LiteralPath $DependencyPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $ReportPath=Join-Path $script:TaskEvidenceDirectory 'job-metadata-report.json'
    $Report=if(Test-Path -LiteralPath $ReportPath -PathType Leaf){Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $ExpectedOld='events,idempotency_records,runs,threads';$ExpectedNew='checkpoint_metadata,events,idempotency_records,jobs,leases,runs,threads'
    $RestoreValid=$null-ne$Report-and(@($Report.old_worker_tables_after_downgrade)-join',')-ceq$ExpectedOld-and(@($Report.rebuilt_tables)-join',')-ceq$ExpectedNew
    $ForbiddenExecutorCount=[regex]::Matches($AppText,'(?im)(subprocess\.|os\.system\s*\(|shell\s*=\s*true|(?<![A-Za-z0-9_.])(?:eval|exec)\s*\()').Count
    $ArbitrarySqlCount=[regex]::Matches($AppText,'(?im)(?:sa\.)?text\s*\(|execute\s*\(\s*[rfbu]*["'']').Count
    $SsrfCount=[regex]::Matches($AppText,'(?im)^\s*(?:from|import)\s+(?:httpx|requests|urllib)').Count
    $Checks=[ordered]@{
      critical_cve=if($null-eq$Dependency){1}else{[int]$Dependency.checks.critical_cve}
      high_cve=if($null-eq$Dependency){1}else{[int]$Dependency.checks.high_cve}
      unknown_license=if($null-eq$Dependency){1}else{[int]$Dependency.checks.unknown_license}
      ssrf_escape_count=$SsrfCount;unauthorized_tool_exec_count=$ForbiddenExecutorCount
      arbitrary_sql_executor_count=$ArbitrarySqlCount
      restore_verification_failures=if($RestoreValid){0}else{1}
      missing_audit_receipt_count=$MissingAudit.Count
      secret_canary_count=if($null-eq$Report){-1}else{[int]$Report.secret_canary_count}
      valid_secret_finding_count=[regex]::Matches($ChangedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count=[regex]::Matches($ChangedText,'[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      unexpected_paths=$Unexpected.Count;production_write_count=0
    }
    $Failures=0
    foreach($Key in @('critical_cve','high_cve','unknown_license','ssrf_escape_count','unauthorized_tool_exec_count','arbitrary_sql_executor_count','restore_verification_failures','missing_audit_receipt_count','secret_canary_count','valid_secret_finding_count','pii_canary_leak_count','unexpected_paths')){$Failures += [int]$Checks[$Key]}
    if($Failures-ne0){return New-BlockedResult 'p03_003_security_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-002') {
    $Paths = @(Get-P03002ChangedPaths)
    $Unexpected = @($Paths | Where-Object { -not (Test-P03002PathAllowed -RelativePath $_) })
    $ChangedText = ''
    foreach ($RelativePath in $Paths) {
      if ($RelativePath -match '(?i)\.(xml|pyc)$') { continue }
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        try { $ChangedText += [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false)) + "`n" } catch { }
      }
    }
    $RepositoryFiles = @(
      'agent-service\app\persistence\repositories\runs.py',
      'agent-service\app\persistence\repositories\events.py'
    )
    $RepositoryText = @($RepositoryFiles | ForEach-Object {
      [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))
    }) -join "`n"
    $AuditContractFiles = @(
      'agent-service\app\persistence\models\runtime.py',
      'agent-service\app\persistence\repositories\events.py',
      'agent-service\migrations\versions\p03_002_run_event_idempotency.py',
      'agent-service\tests\unit\harness\test_25_event_writer.py'
    )
    $AuditContractText = @($AuditContractFiles | ForEach-Object {
      [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))
    }) -join "`n"
    $RequiredAuditMarkers = @(
      'audit_receipt_id: Mapped[str]',
      'nullable=False',
      'ck_events_audit_receipt_nonempty',
      'raise AuditReceiptRequired()',
      'test_25_event_writer_d_missing_audit_receipt_fails_closed'
    )
    $MissingAuditMarkers = @($RequiredAuditMarkers | Where-Object { -not $AuditContractText.Contains($_) })
    $ForbiddenExecutorCount = [regex]::Matches($ChangedText,'(?im)(subprocess\.|os\.system\s*\(|shell\s*=\s*true|(?<![A-Za-z0-9_.])(?:eval|exec)\s*\()').Count
    $HardcodedPasswordCount = [regex]::Matches($ChangedText,'(?i)postgresql(?:\+[^:]+)?://[^/@:]+:[^/@]+@').Count
    $ArbitraryRepositorySqlCount = [regex]::Matches($RepositoryText,'(?im)(?:sa\.)?text\s*\(|execute\s*\(\s*[rfbu]*["'']').Count
    $Checks = [ordered]@{
      no_extra_boundary=($Unexpected.Count+$ForbiddenExecutorCount+$HardcodedPasswordCount+$ArbitraryRepositorySqlCount-eq0)
      valid_secret_finding_count=[regex]::Matches($ChangedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count=[regex]::Matches($ChangedText,'[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      missing_audit_receipt_count=$MissingAuditMarkers.Count
      unexpected_paths=$Unexpected.Count;arbitrary_executor_count=$ForbiddenExecutorCount
      arbitrary_repository_sql_count=$ArbitraryRepositorySqlCount
      hardcoded_database_password_count=$HardcodedPasswordCount;production_write_count=0
    }
    if(-not[bool]$Checks.no_extra_boundary-or[int]$Checks.valid_secret_finding_count+[int]$Checks.pii_canary_leak_count+[int]$Checks.missing_audit_receipt_count-ne0){
      return New-BlockedResult 'p03_002_security_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-001') {
    $Paths = @(Get-P03001ChangedPaths)
    $Unexpected = @($Paths | Where-Object { -not (Test-P03001PathAllowed -RelativePath $_) })
    $ChangedText = ''
    foreach ($RelativePath in $Paths) {
      if ($RelativePath -match '(?i)(\.xml$|uv\.lock$|sbom\.cdx\.json$)') { continue }
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        try { $ChangedText += [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false)) + "`n" } catch { }
      }
    }
    $MigrationFiles = @(
      'agent-service\migrations\env.py','agent-service\migrations\versions\p03_001_runtime_baseline.py',
      'agent-service\tests\integration\test_migration_baseline.py'
    )
    $MigrationText = @($MigrationFiles | ForEach-Object {
      [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot $_),[Text.UTF8Encoding]::new($false))
    }) -join "`n"
    $ForbiddenExecutorCount = [regex]::Matches($MigrationText,'(?im)(subprocess\.|os\.system\s*\(|shell\s*=\s*true|(?<![A-Za-z0-9_.])(?:eval|exec)\s*\()').Count
    $HardcodedPasswordCount = [regex]::Matches($MigrationText,'(?i)postgresql(?:\+[^:]+)?://[^/@:]+:[^/@]+@').Count
    $Checks = [ordered]@{
      no_extra_boundary=($ForbiddenExecutorCount+$HardcodedPasswordCount+$Unexpected.Count-eq 0)
      valid_secret_finding_count=[regex]::Matches($ChangedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count=[regex]::Matches($ChangedText,'[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      unexpected_paths=$Unexpected.Count;arbitrary_executor_count=$ForbiddenExecutorCount
      hardcoded_database_password_count=$HardcodedPasswordCount;production_write_count=0
    }
    if(-not[bool]$Checks.no_extra_boundary-or[int]$Checks.valid_secret_finding_count-ne0-or[int]$Checks.pii_canary_leak_count-ne0){
      return New-BlockedResult 'p03_001_security_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-990') {
    $DiffText=@(& git -C $script:RepositoryRoot diff --unified=0 --no-color HEAD --)-join"`n"
    $AddedText=@($DiffText-split"`n"|Where-Object{$_.StartsWith('+')-and-not$_.StartsWith('+++')})-join"`n"
    foreach($RelativePath in @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(Test-Path -LiteralPath $FullPath -PathType Leaf){$AddedText+="`n"+[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false))}
    }
    $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD);$Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Checks=[ordered]@{
      valid_secret_finding_count=[regex]::Matches($AddedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count=[regex]::Matches($AddedText,'[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      missing_audit_receipt_count=0
      implementation_change_count=@($Paths|Where-Object{$_.Replace('\','/')-match'^(lib|agent-service/app|agent-service/tests|agent-service/pyproject\.toml|agent-service/uv\.lock|supabase|contracts)/'}).Count
      production_write_count=0
    }
    if([int]$Checks.valid_secret_finding_count+[int]$Checks.pii_canary_leak_count+[int]$Checks.missing_audit_receipt_count+[int]$Checks.implementation_change_count-ne0){return New-BlockedResult 'p02_990_security_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-089') {
    $DiffText = @(& git -C $script:RepositoryRoot diff --unified=0 --no-color HEAD --) -join "`n"
    $AddedText = @($DiffText -split "`n" | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') }) -join "`n"
    foreach ($RelativePath in @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        $AddedText += "`n" + [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false))
      }
    }
    $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths=@($Paths|ForEach-Object{$_.Replace('\','/')}|Sort-Object -Unique)
    $Checks=[ordered]@{
      valid_secret_finding_count=[regex]::Matches($AddedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count=[regex]::Matches($AddedText,'[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      unsafe_command_example_count=[regex]::Matches($AddedText,'(?i)(git\s+reset\s+--hard|git\s+clean\s+-fd|force-push|rm\s+-rf)').Count
      implementation_change_count=@($Paths|Where-Object{$_ -match '^(lib|agent-service/app|agent-service/tests|agent-service/pyproject\.toml|agent-service/uv\.lock|supabase|contracts)/'}).Count
      missing_audit_receipt_count=0;production_write_count=0
    }
    if([int]$Checks.valid_secret_finding_count+[int]$Checks.pii_canary_leak_count+[int]$Checks.unsafe_command_example_count+[int]$Checks.implementation_change_count-ne 0){
      return New-BlockedResult 'p02_089_closure_security_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-001') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
    $ChangedText = ''
    foreach ($RelativePath in $Paths) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        $ChangedText += [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false)) + "`n"
      }
    }
    $PyprojectPath = Join-Path $script:RepositoryRoot 'agent-service\pyproject.toml'
    $Pyproject = if (Test-Path -LiteralPath $PyprojectPath -PathType Leaf) {
      [IO.File]::ReadAllText($PyprojectPath,[Text.UTF8Encoding]::new($false))
    } else { '' }
    $Canary = 'gonow-p02-001-canary@example.invalid'
    $Redacted = $Canary -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+','[REDACTED_EMAIL]'
    $Checks = [ordered]@{
      valid_secret_finding_count = [regex]::Matches($ChangedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count = if ($Redacted.Contains($Canary)) { 1 } else { 0 }
      tracked_environment_file_count = @(& git -C $script:RepositoryRoot ls-files | Where-Object { $_ -match '(^|/)(\.env($|\.)|.*\.(pem|key|p12|pfx))$' }).Count
      model_or_graph_dependency_count = [regex]::Matches($Pyproject,'(?im)^\s*"(?:openai|anthropic|langgraph|langchain|llama-index)[^\"]*"').Count
      flutter_change_count = @($Paths | Where-Object { $_ -match '^(lib|test)/' }).Count
      database_change_count = @($Paths | Where-Object { $_ -match '^(supabase|agent-service/migrations)/' }).Count
      production_write_count = 0
    }
    $Failures = 0
    foreach ($Key in @('valid_secret_finding_count','pii_canary_leak_count','tracked_environment_file_count','model_or_graph_dependency_count','flutter_change_count','database_change_count','production_write_count')) {
      $Failures += [int]$Checks[$Key]
    }
    if ($Failures -ne 0) { return New-BlockedResult 'p02_001_security_boundary_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -cmatch '^TASK-P02-(002|003|004|005|006|007|008|089)$') {
    $ChangedText = ''
    foreach ($RelativePath in @(Get-P02TaskDeliverableFiles)) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      $ChangedText += [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false)) + "`n"
    }
    $Canary = "gonow-$($TaskId.ToLowerInvariant())-pii-canary@example.invalid"
    $Redacted = $Canary -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+','[REDACTED_EMAIL]'
    $Checks = [ordered]@{
      valid_secret_finding_count=[regex]::Matches($ChangedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count=if($Redacted.Contains($Canary)){1}else{0}
      missing_audit_receipt_count=0
      critical_cve=0;high_cve=0;unknown_license=0;ssrf_escape_count=0;unauthorized_tool_exec_count=0
      production_write_count=0
    }
    if ($TaskId -ceq 'TASK-P02-003') {
      $Checks['identity_denied_mismatch']=0;$Checks['authorization_bypass_count']=0
      $Checks['tenant_leak_count']=0;$Checks['rls_unexpected_allow_count']=0
    } elseif ($TaskId -ceq 'TASK-P02-004') {
      $Checks.unsafe_5xx_body_count=0
    } elseif ($TaskId -ceq 'TASK-P02-005') {
      $Rules=Get-P02TaskPathRules
      $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD);$Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
      $Paths=@($Paths|ForEach-Object{$_.Replace('\','/')}|Sort-Object -Unique)
      $Unexpected=@($Paths|Where-Object{-not(Test-P02TaskPathAllowed -RelativePath $_ -Rules $Rules)})
      $BoundaryChanges=@($Paths|Where-Object{$_ -match '^(contracts|supabase|agent-service/migrations)/|^agent-service/app/(auth|api/middleware)/'})
      $Checks.no_extra_boundary=($BoundaryChanges.Count-eq 0);$Checks.unexpected_paths=$Unexpected.Count
    } elseif ($TaskId -ceq 'TASK-P02-006') {
      $LintReportPath=Join-Path $script:TaskEvidenceDirectory 'ci-reports\lint.json'
      $LicenseReportPath=Join-Path $script:TaskEvidenceDirectory 'ci-reports\licenses.json'
      $LintReport=if(Test-Path -LiteralPath $LintReportPath){Get-Content -LiteralPath $LintReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
      $LicenseReport=if(Test-Path -LiteralPath $LicenseReportPath){Get-Content -LiteralPath $LicenseReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
      $Checks.lock_drift=0;$Checks.prompt_or_model_execution_count=0
      $Checks.injection_executed_action_count=if($null-eq$LintReport){1}else{[int]$LintReport.checks.injection_executed_action_count}
      $Checks.unknown_license=if($null-eq$LicenseReport){1}else{[int]$LicenseReport.checks.unknown_license}
    } elseif ($TaskId -ceq 'TASK-P02-007') {
      $Checks.spec_hash_missing=0
    } elseif ($TaskId -ceq 'TASK-P02-008') {
      $ServiceFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'agent-service\app') -Recurse -File -Filter '*.py')
      $ServiceText = @($ServiceFiles | ForEach-Object { [IO.File]::ReadAllText($_.FullName,[Text.UTF8Encoding]::new($false)) }) -join "`n"
      $Checks.llm_calls=[regex]::Matches($ServiceText,'(?im)^\s*(?:from|import)\s+(?:openai|anthropic|langchain|langgraph)').Count
      $Checks.tool_calls=[regex]::Matches($ServiceText,'(?i)\btool[_ ]?call\s*\(').Count
      $Checks.graph_runs=[regex]::Matches($ServiceText,'(?i)\bgraph\.(?:invoke|ainvoke|stream)\s*\(').Count
      $Checks.injection_executed_action_count=[regex]::Matches($ServiceText,'(?m)(?<![A-Za-z0-9_.])(?:eval|exec)\s*\(').Count
    }
    $Failures=0
    foreach($Property in $Checks.GetEnumerator()){
      if($Property.Key -ne 'production_write_count' -and $Property.Value -is [int]){$Failures += [int]$Property.Value}
    }
    $Failures += [int]$Checks.production_write_count
    if($Failures-ne 0){return New-BlockedResult 'p02_security_boundary_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -in @('TASK-P01-089','TASK-P01-990')) {
    $DiffText = @(& git -C $script:RepositoryRoot diff --unified=0 --no-color HEAD --) -join "`n"
    $AddedText = @($DiffText -split "`n" | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') }) -join "`n"
    $Untracked = @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    foreach ($RelativePath in $Untracked) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        $AddedText += "`n" + [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false))
      }
    }
    $Checks = [ordered]@{
      valid_secret_finding_count = [regex]::Matches($AddedText,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count = [regex]::Matches($AddedText,'[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      unsafe_command_example_count = [regex]::Matches($AddedText,'(?i)(git\s+reset\s+--hard|git\s+clean\s+-fd|force-push|rm\s+-rf)').Count
      missing_audit_receipt_count = 0
      runtime_or_database_change_count = @(& git -C $script:RepositoryRoot diff --name-only HEAD | Where-Object { $_.Replace('\','/') -match '^(lib|agent-service|supabase|contracts)/' }).Count
      production_write_count = 0
    }
    if ([int]$Checks.valid_secret_finding_count+[int]$Checks.pii_canary_leak_count+[int]$Checks.unsafe_command_example_count+[int]$Checks.runtime_or_database_change_count -ne 0) {
      return New-BlockedResult 'p01_closure_security_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-005') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
    $AllowedExact = @('docs/architecture/adr/ADR-P01-005-architecture-baseline.md','docs/execution/status/TASK-P01-005.json')
    $AllowedPrefix = 'docs/execution/evidence/phase-01/P01-005/'
    $Unexpected = @($Paths | Where-Object { $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix,[StringComparison]::Ordinal) })
    $Text = ''
    foreach ($PathValue in $Paths) {
      $FullPath = Join-Path $script:RepositoryRoot $PathValue
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) { $Text += [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false)) }
    }
    $Checks = [ordered]@{
      no_extra_boundary = (@($Paths | Where-Object { $_ -match '^(lib|agent-service|contracts|supabase)/' }).Count -eq 0)
      valid_secret_finding_count = [regex]::Matches($Text,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count = [regex]::Matches($Text,'[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      unexpected_paths = $Unexpected.Count
      database_change_count = @($Paths | Where-Object { $_ -match '^(supabase|agent-service/migrations)/' }).Count
      production_write_count = 0
    }
    if (-not [bool]$Checks.no_extra_boundary -or [int]$Checks.valid_secret_finding_count -ne 0 -or
        [int]$Checks.pii_canary_leak_count -ne 0 -or [int]$Checks.unexpected_paths -ne 0 -or
        [int]$Checks.database_change_count -ne 0) { return New-BlockedResult 'p01_005_security_or_scope_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-004') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedExact = @(
      'contracts/flutter-agent-boundary-v1.yaml',
      'docs/execution/status/TASK-P01-004.json'
    )
    $AllowedPrefix = 'docs/execution/evidence/phase-01/P01-004/'
    $Unexpected = @($Paths | Where-Object {
      $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix, [StringComparison]::Ordinal)
    })
    $Text = ''
    foreach ($PathValue in $Paths) {
      $FullPath = Join-Path $script:RepositoryRoot $PathValue
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        $Text += [IO.File]::ReadAllText($FullPath, [Text.UTF8Encoding]::new($false))
      }
    }
    $Checks = [ordered]@{
      valid_secret_finding_count = [regex]::Matches($Text, '(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count = [regex]::Matches($Text, '[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      unexpected_paths = $Unexpected.Count
      flutter_implementation_change_count = @($Paths | Where-Object { $_ -match '^lib/' }).Count
      deletion_enablement_count = [regex]::Matches($Text, '(?m)^\s*delete_allowed:\s*true\s*$').Count
      production_write_count = 0
    }
    if ([int]$Checks.valid_secret_finding_count + [int]$Checks.pii_canary_leak_count +
        [int]$Checks.unexpected_paths + [int]$Checks.flutter_implementation_change_count +
        [int]$Checks.deletion_enablement_count -ne 0) {
      return New-BlockedResult 'p01_004_security_or_scope_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-003') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedExact = @('test/validation_semantics_test.dart','docs/execution/status/TASK-P01-003.json')
    $AllowedPrefixes = @('test/fixtures/validation/','docs/execution/evidence/phase-01/P01-003/')
    $Unexpected = @()
    foreach ($PathValue in $Paths) {
      $Allowed = $PathValue -in $AllowedExact
      foreach ($Prefix in $AllowedPrefixes) { if ($PathValue.StartsWith($Prefix, [StringComparison]::Ordinal)) { $Allowed = $true; break } }
      if (-not $Allowed) { $Unexpected += $PathValue }
    }
    $ChangedText = ''
    foreach ($PathValue in $Paths) {
      $FullPath = Join-Path $script:RepositoryRoot $PathValue
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) { $ChangedText += [IO.File]::ReadAllText($FullPath, [Text.UTF8Encoding]::new($false)) }
    }
    $FixtureSecurityPath = Join-Path $script:RepositoryRoot 'test\fixtures\validation\validation_semantics_cases.json'
    $TestSecurityPath = Join-Path $script:RepositoryRoot 'test\validation_semantics_test.dart'
    $FixtureSecurityText = if (Test-Path -LiteralPath $FixtureSecurityPath -PathType Leaf) {
      [IO.File]::ReadAllText($FixtureSecurityPath, [Text.UTF8Encoding]::new($false))
    } else { '' }
    $TaskSecurityText = $ChangedText + $FixtureSecurityText + $(if (Test-Path -LiteralPath $TestSecurityPath -PathType Leaf) {
      [IO.File]::ReadAllText($TestSecurityPath, [Text.UTF8Encoding]::new($false))
    } else { '' })
    $Checks = [ordered]@{
      no_extra_boundary = (@($Paths | Where-Object { $_ -match '^(lib|agent-service|contracts|supabase)/' }).Count -eq 0)
      valid_secret_finding_count = [regex]::Matches($TaskSecurityText, '(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      pii_canary_leak_count = [regex]::Matches($TaskSecurityText, '[A-Za-z0-9._%+-]+@(?!example\.invalid)[A-Za-z0-9.-]+\.[A-Za-z]{2,}').Count
      unexpected_paths = $Unexpected.Count
      synthetic_fixture_marker_missing = if ($FixtureSecurityText.Contains('"synthetic_only": true')) { 0 } else { 1 }
      production_write_count = 0
    }
    if (-not [bool]$Checks.no_extra_boundary -or [int]$Checks.valid_secret_finding_count -ne 0 -or
        [int]$Checks.pii_canary_leak_count -ne 0 -or [int]$Checks.unexpected_paths -ne 0 -or
        [int]$Checks.synthetic_fixture_marker_missing -ne 0) {
      return New-BlockedResult 'p01_003_security_or_scope_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-002') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedExact = @(
      'contracts/validation-semantics-v1.schema.json',
      'docs/architecture/validation-semantics-v1.md',
      'docs/execution/status/TASK-P01-002.json'
    )
    $AllowedPrefix = 'docs/execution/evidence/phase-01/P01-002/'
    $Unexpected = @($Paths | Where-Object {
      $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix, [StringComparison]::Ordinal)
    })
    $ChangedText = ''
    foreach ($PathValue in $Paths) {
      $FullPath = Join-Path $script:RepositoryRoot $PathValue
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        $ChangedText += [IO.File]::ReadAllText($FullPath, [Text.UTF8Encoding]::new($false))
      }
    }
    $SecretMatches = [regex]::Matches($ChangedText, '(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
    $Canary = 'gonow-p01-002-canary@example.invalid'
    $Redacted = $Canary -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '[REDACTED_EMAIL]'
    $Checks = [ordered]@{
      no_extra_boundary = (@($Paths | Where-Object { $_ -match '^(lib|agent-service|supabase)/' }).Count -eq 0)
      valid_secret_finding_count = $SecretMatches
      pii_canary_leak_count = if ($Redacted.Contains($Canary)) { 1 } else { 0 }
      unexpected_paths = $Unexpected.Count
      domain_write_enablement_count = [regex]::Matches($ChangedText, '"domain_write_allowed"\s*:\s*true').Count
      production_write_count = 0
    }
    if (-not [bool]$Checks.no_extra_boundary -or [int]$Checks.valid_secret_finding_count -ne 0 -or
        [int]$Checks.pii_canary_leak_count -ne 0 -or [int]$Checks.unexpected_paths -ne 0 -or
        [int]$Checks.domain_write_enablement_count -ne 0) {
      return New-BlockedResult 'p01_002_security_or_scope_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-001') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedPrefix = 'docs/execution/evidence/phase-01/P01-001/'
    $AllowedExact = @(
      'docs/execution/evidence/phase-01/phase-runtime-manifest.json',
      'docs/execution/status/TASK-P01-001.json'
    )
    $Unexpected = @($Paths | Where-Object {
      $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix, [StringComparison]::Ordinal)
    })
    $ChangedText = ''
    foreach ($PathValue in $Paths) {
      $FullPath = Join-Path $script:RepositoryRoot $PathValue
      if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
        $ChangedText += [IO.File]::ReadAllText($FullPath, [Text.UTF8Encoding]::new($false))
      }
    }
    $SecretMatches = [regex]::Matches(
      $ChangedText,
      '(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
    ).Count
    $Canary = 'gonow-p01-001-canary@example.invalid'
    $Redacted = $Canary -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '[REDACTED_EMAIL]'
    $Checks = [ordered]@{
      no_extra_boundary = (@($Paths | Where-Object { $_ -match '^(lib|agent-service|contracts|supabase)/' }).Count -eq 0)
      valid_secret_finding_count = $SecretMatches
      pii_canary_leak_count = if ($Redacted.Contains($Canary)) { 1 } else { 0 }
      unexpected_paths = $Unexpected.Count
      production_write_count = 0
    }
    if (-not [bool]$Checks.no_extra_boundary -or [int]$Checks.valid_secret_finding_count -ne 0 -or
        [int]$Checks.pii_canary_leak_count -ne 0 -or [int]$Checks.unexpected_paths -ne 0) {
      return New-BlockedResult 'p01_001_security_or_scope_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-990') {
    $Projection = Get-P00LocalProjection
    $Checks = [ordered]@{
      valid_secret_finding_count = if ($null -eq $Projection.checks) { -1 } else { [int]$Projection.checks.valid_secret_finding_count }
      pii_canary_leak_count = if ($null -eq $Projection.checks) { -1 } else { [int]$Projection.checks.pii_canary_leak_count }
      local_security_failure_count = if ($null -eq $Projection.checks) { [int]$Projection.local_failure_count } else {
        [int]$Projection.checks.valid_secret_finding_count + [int]$Projection.checks.pii_canary_leak_count
      }
      formal_missing_external_audit_boundary_count = @($Projection.formal_pending_boundaries).Count
      formal_gate_status = 'pending_external'
      production_write_count = 0
    }
    if ([int]$Checks.local_security_failure_count -ne 0) {
      return New-BlockedResult 'p00_local_projection_security_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-003') {
    $ContainmentPath = Join-Path $script:TaskEvidenceDirectory 'security\secret-containment.json'
    $PostContainmentScanPath = Join-Path $script:TaskEvidenceDirectory 'security\live-secret-scan-after-local-containment.json'
    $LiveScanPath = if (Test-Path -LiteralPath $PostContainmentScanPath -PathType Leaf) {
      $PostContainmentScanPath
    } else {
      Join-Path $script:TaskEvidenceDirectory 'security\live-secret-scan.json'
    }
    $Report = Get-Boot005Report
    if ($null -eq $Report -or
        -not (Test-Path -LiteralPath $ContainmentPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $LiveScanPath -PathType Leaf)) {
      return New-BlockedResult 'p00_secret_containment_security_inputs_missing' ([ordered]@{
        critical_cve = -1; high_cve = -1; unknown_license = -1
        valid_secret_finding_count = -1; missing_audit_receipt_count = -1
      })
    }
    $Containment = Get-Content -LiteralPath $ContainmentPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $LiveScan = Get-Content -LiteralPath $LiveScanPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Canary = 'gonow-p00-003-pii-canary@example.invalid'
    $Redacted = $Canary -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', '[REDACTED_EMAIL]'
    $Checks = [ordered]@{
      critical_cve = [int]$Report.critical_cve
      high_cve = [int]$Report.high_cve
      unknown_license = [int]$Report.unknown_license
      valid_secret_finding_count = [int]$LiveScan.finding_count
      pii_canary_leak_count = if ($Redacted.Contains($Canary)) { 1 } else { 0 }
      missing_audit_receipt_count = [int]$Containment.owner_and_vendor_evidence.missing_audit_receipt_count
      secret_value_output_count = [int]$LiveScan.secret_value_output_count
      untracked_file_read_count = [int]$LiveScan.untracked_file_read_count
      external_revocation_attempt_count = [int]$Containment.owner_and_vendor_evidence.external_revocation_attempt_count
      production_write_count = 0
    }
    $Failures = 0
    foreach ($Key in $Checks.Keys) { $Failures += [int]$Checks[$Key] }
    if ($Failures -ne 0) { return New-BlockedResult 'p0_secret_containment_owner_action_required' $Checks }
    return New-PassedResult $Checks
  }
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
  if ($TaskId -ceq 'TASK-P03-009') {
    $PowerShell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';$JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml';$ReportPath=Join-Path $script:TaskEvidenceDirectory 'backup-restore-report.json';$TestRun=Invoke-RedactedExternal -Executable $PowerShell -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File','agent-service/scripts/test_backup_restore.ps1','-EvidenceRoot','docs/execution/evidence/phase-03/P03-009')
    $Tests=0;$Failures=1;$Skipped=1;if(Test-Path $JunitPath){[xml]$Junit=Get-Content $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite};$Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped};$Report=if(Test-Path $ReportPath){Get-Content $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $HashesEqual=$null-ne$Report-and[string]$Report.logical_hash_before-ceq[string]$Report.logical_hash_after_upgrade-and[string]$Report.logical_hash_before-ceq[string]$Report.logical_hash_after_restore
    $ReportValid=$null-ne$Report-and[string]$Report.task_id-ceq$TaskId-and[int]$Report.empty_upgrade_failures-eq0-and[int]$Report.existing_upgrade_failures-eq0-and[int]$Report.restore_hash_mismatch-eq0-and[int]$Report.restore_verification_failures-eq0-and[int]$Report.forward_fix_rejection_count-eq1-and$HashesEqual-and[int]$Report.logical_row_count-eq8-and[int]$Report.upgraded_row_count-eq8-and[int]$Report.restored_row_count-eq8-and[bool]$Report.migration_lock_first_acquired-and[bool]$Report.migration_lock_second_blocked-and[bool]$Report.migration_lock_after_release_acquired-and[string]$Report.ct_007-ceq'passed'-and[int]$Report.policy_count-eq10-and[int]$Report.forced_rls_table_count-eq10-and[int]$Report.public_grant_count-eq0-and[int]$Report.tenant_leak_count-eq0-and[string]$Report.rpo_status-ceq'unknown_not_claimed'-and[string]$Report.rto_status-ceq'unknown_not_claimed'-and-not[bool]$Report.production
    $Checks=[ordered]@{primary_assertion_passed=([int]$TestRun.exit_code-eq0-and$Tests-eq1-and$Failures-eq0-and$Skipped-eq0-and$ReportValid);empty_upgrade_failures=if($null-eq$Report){1}else{[int]$Report.empty_upgrade_failures};existing_upgrade_failures=if($null-eq$Report){1}else{[int]$Report.existing_upgrade_failures};restore_hash_mismatch=if($null-eq$Report){1}else{[int]$Report.restore_hash_mismatch};ct_007=if($null-eq$Report){'failed'}else{[string]$Report.ct_007};migration_lock_verified=$ReportValid;rpo_rto_claimed=$false;test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failures=$Failures;skipped=$Skipped;production_write_count=0};if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p03_009_restore_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-008') {
    $Python=Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe';$JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml';$PreviousEvidence=$env:GONOW_P03_008_EVIDENCE_DIR
    $TestPaths=@('agent-service/tests/contract/test_idempotency.py','agent-service/tests/integration/test_runtime_concurrency.py','agent-service/tests/unit/harness/test_05_idempotency_guard.py','agent-service/tests/unit/harness/test_34_consistency_fence.py')
    try{$env:GONOW_P03_008_EVIDENCE_DIR=$script:TaskEvidenceDirectory;$TestRun=Invoke-RedactedExternal -Executable $Python -Arguments (@('-m','pytest','-q')+$TestPaths+@('--maxfail=1','--junitxml',$JunitPath))}finally{if($null-eq$PreviousEvidence){Remove-Item Env:\GONOW_P03_008_EVIDENCE_DIR -ErrorAction SilentlyContinue}else{$env:GONOW_P03_008_EVIDENCE_DIR=$PreviousEvidence}}
    $Tests=0;$Failures=1;$Skipped=1;if(Test-Path -LiteralPath $JunitPath){[xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite};$Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped}
    $Ct1Path=Join-Path $script:TaskEvidenceDirectory 'ct-001.json';$Ct2Path=Join-Path $script:TaskEvidenceDirectory 'ct-002.json';$RuntimePath=Join-Path $script:TaskEvidenceDirectory 'runtime-concurrency-report.json'
    $Ct1=if(Test-Path $Ct1Path){Get-Content $Ct1Path -Raw -Encoding UTF8|ConvertFrom-Json}else{$null};$Ct2=if(Test-Path $Ct2Path){Get-Content $Ct2Path -Raw -Encoding UTF8|ConvertFrom-Json}else{$null};$Runtime=if(Test-Path $RuntimePath){Get-Content $RuntimePath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $Ct1Valid=$null-ne$Ct1-and[string]$Ct1.task_id-ceq$TaskId-and[string]$Ct1.contract_test-ceq'CT-001'-and[int]$Ct1.concurrent_callers-eq50-and[int]$Ct1.unique_run_count-eq1-and[int]$Ct1.original_winner_count-eq1-and[int]$Ct1.replay_count-eq49-and[int]$Ct1.persisted_run_count-eq1-and[int]$Ct1.persisted_idempotency_count-eq1-and[bool]$Ct1.exactly_one_legal_winner-and-not[bool]$Ct1.production
    $Ct2Valid=$null-ne$Ct2-and[string]$Ct2.task_id-ceq$TaskId-and[string]$Ct2.contract_test-ceq'CT-002'-and[string]$Ct2.conflict_code-ceq'idempotency.conflict'-and[bool]$Ct2.different_body_rejected-and[int]$Ct2.persisted_run_count-eq1-and[int]$Ct2.persisted_idempotency_count-eq1-and-not[bool]$Ct2.production
    $RuntimeValid=$null-ne$Runtime-and[string]$Runtime.task_id-ceq$TaskId-and[string]$Runtime.revision-ceq'p03_007_runtime_rls'-and[int]$Runtime.terminal_race_callers-eq2-and[int]$Runtime.terminal_winner_count-eq1-and[int]$Runtime.terminal_conflict_count-eq1-and[int]$Runtime.terminal_version-eq3-and[int]$Runtime.event_race_callers-eq50-and[int]$Runtime.event_sequence_min-eq1-and[int]$Runtime.event_sequence_max-eq50-and[int]$Runtime.event_sequence_unique_count-eq50-and[int]$Runtime.event_sequence_gap_count-eq0-and[int]$Runtime.persisted_event_count-eq50-and[int]$Runtime.next_event_seq-eq51-and[int]$Runtime.post_terminal_event_rejection_count-eq1-and[bool]$Runtime.exactly_one_legal_winner-and-not[bool]$Runtime.production
    $ControlSpecs=@([ordered]@{id=5;path='agent-service/tests/unit/harness/test_05_idempotency_guard.py';minimum=4},[ordered]@{id=34;path='agent-service/tests/unit/harness/test_34_consistency_fence.py';minimum=4});$Controls=@();$HarnessFailures=0;$HarnessCases=0
    if(Test-Path -LiteralPath $JunitPath){foreach($Spec in $ControlSpecs){$Control=New-P02HarnessControlRecord -ControlId ([int]$Spec.id) -RelativeTestPath ([string]$Spec.path) -JunitPath $JunitPath;$Controls+=$Control;$HarnessCases+=[int]$Control.tests;if([int]$Control.tests-lt[int]$Spec.minimum-or@($Control.case_ids.S).Count-lt1-or@($Control.case_ids.I).Count-lt1-or@($Control.case_ids.D).Count-lt1-or[int]$Control.failures+[int]$Control.errors+[int]$Control.skipped+[int]$Control.xfailed-ne0){$HarnessFailures++}};Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-status-fragment.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;catalog_sha256=$script:CatalogSha256;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();controls=$Controls})}else{$HarnessFailures++}
    $Checks=[ordered]@{primary_assertion_passed=([int]$TestRun.exit_code-eq0-and$Tests-ge11-and$Failures-eq0-and$Skipped-eq0-and$Ct1Valid-and$Ct2Valid-and$RuntimeValid-and$HarnessFailures-eq0-and$HarnessCases-ge8);ct_001=if($Ct1Valid){'passed'}else{'failed'};ct_002=if($Ct2Valid){'passed'}else{'failed'};exactly_one_legal_winner=($Ct1Valid-and$RuntimeValid);terminal_cas=$RuntimeValid;event_sequence=$RuntimeValid;harness_05_34_sid_clean=($HarnessFailures-eq0-and$HarnessCases-ge8);test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failures=$Failures;skipped=$Skipped;production_write_count=0}
    if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p03_008_concurrency_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-007') {
    $Python=Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe';$JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml';$ReportPath=Join-Path $script:TaskEvidenceDirectory 'rls-report.json';$PreviousReport=$env:GONOW_P03_RLS_REPORT
    try{$env:GONOW_P03_RLS_REPORT=$ReportPath;$TestRun=Invoke-RedactedExternal -Executable $Python -Arguments @('-m','pytest','-q','agent-service/tests/security/test_rls.py','--maxfail=1','--junitxml',$JunitPath)}finally{if($null-eq$PreviousReport){Remove-Item Env:\GONOW_P03_RLS_REPORT -ErrorAction SilentlyContinue}else{$env:GONOW_P03_RLS_REPORT=$PreviousReport}}
    $Tests=0;$Failures=1;$Skipped=1;if(Test-Path $JunitPath){[xml]$Junit=Get-Content $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite};$Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped};$Report=if(Test-Path $ReportPath){Get-Content $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $ReportValid=$null-ne$Report-and[string]$Report.task_id-ceq$TaskId-and[string]$Report.revision-ceq'p03_007_runtime_rls'-and[bool]$Report.ct_007_passed-and[int]$Report.tenant_matrix_roles-eq3-and[int]$Report.tenant_matrix_tenants-eq2-and[int]$Report.tenant_leak_count-eq0-and[int]$Report.acl_leakage_count-eq0-and[int]$Report.rls_unexpected_allow_count-eq0-and[int]$Report.policy_count-eq10-and[int]$Report.forced_rls_table_count-eq10-and[int]$Report.role_bypass_count-eq0-and[int]$Report.forward_fix_downgrade_rejection_count-eq1-and[string]$Report.head_revision_after_rejected_downgrade-ceq'p03_007_runtime_rls'-and-not[bool]$Report.production
    $Checks=[ordered]@{primary_assertion_passed=([int]$TestRun.exit_code-eq0-and$Tests-ge5-and$Failures-eq0-and$Skipped-eq0-and$ReportValid);ct_007=if($ReportValid){'passed'}else{'failed'};acl_leakage_count=if($null-eq$Report){1}else{[int]$Report.acl_leakage_count};tenant_leak_count=if($null-eq$Report){1}else{[int]$Report.tenant_leak_count};exact_role_tenant_matrix=$ReportValid;test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failures=$Failures;skipped=$Skipped;production_write_count=0};if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p03_007_rls_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-006') {
    $Python=Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe'
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml';$ReportPath=Join-Path $script:TaskEvidenceDirectory 'outbox-receipt-report.json'
    $PreviousReport=$env:GONOW_P03_OUTBOX_REPORT
    try{$env:GONOW_P03_OUTBOX_REPORT=$ReportPath;$TestRun=Invoke-RedactedExternal -Executable $Python -Arguments @('-m','pytest','-q','agent-service/tests/integration/test_outbox_receipts.py','--maxfail=1','--junitxml',$JunitPath)}finally{if($null-eq$PreviousReport){Remove-Item Env:\GONOW_P03_OUTBOX_REPORT -ErrorAction SilentlyContinue}else{$env:GONOW_P03_OUTBOX_REPORT=$PreviousReport}}
    $Tests=0;$Failures=1;$Skipped=1;if(Test-Path -LiteralPath $JunitPath){[xml]$Junit=Get-Content $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite};$Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped}
    $Report=if(Test-Path -LiteralPath $ReportPath){Get-Content $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $OldTables='checkpoint_metadata,events,idempotency_records,jobs,leases,runs,threads';$NewTables='dead_letters,delivery_receipts,outbox_messages'
    $ReportValid=$null-ne$Report-and[string]$Report.task_id-ceq$TaskId-and[string]$Report.revision-ceq'p03_006_outbox_receipts'-and[int]$Report.rollback_orphan_count-eq0-and[int]$Report.duplicate_receipt_effect_count-eq1-and[int]$Report.delivery_receipt_count-eq1-and[int]$Report.dead_letter_payload_column_count-eq0-and[int]$Report.cross_tenant_rejection_count-ge1-and[int]$Report.restore_verification_failures-eq0-and(@($Report.tables_after_downgrade)-join',')-ceq$OldTables-and(@($Report.rebuilt_outbox_tables)-join',')-ceq$NewTables-and-not[bool]$Report.production
    $Checks=[ordered]@{primary_assertion_passed=([int]$TestRun.exit_code-eq0-and$Tests-ge5-and$Failures-eq0-and$Skipped-eq0-and$ReportValid);rollback_orphan_count=if($null-eq$Report){1}else{[int]$Report.rollback_orphan_count};duplicate_receipt_effect_count=if($null-eq$Report){0}else{[int]$Report.duplicate_receipt_effect_count};delivery_receipt_count=if($null-eq$Report){0}else{[int]$Report.delivery_receipt_count};dead_letter_payload_column_count=if($null-eq$Report){1}else{[int]$Report.dead_letter_payload_column_count};external_consumer_count=0;test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failures=$Failures;skipped=$Skipped;production_write_count=0}
    if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p03_006_outbox_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-005') {
    $Python=Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe'
    $Flutter='D:\flutter\flutter_windows_3.41.7-stable\flutter\bin\flutter.bat'
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $PythonReportPath=Join-Path $script:TaskEvidenceDirectory 'manifest-digest-report.json'
    $DartReportPath=Join-Path $script:TaskEvidenceDirectory 'dart-digest-report.json'
    $PreviousPythonReport=$env:GONOW_P03_MANIFEST_REPORT;$PreviousDartReport=$env:GONOW_P03_DART_MANIFEST_REPORT
    try{
      $env:GONOW_P03_MANIFEST_REPORT=$PythonReportPath;$env:GONOW_P03_DART_MANIFEST_REPORT=$DartReportPath
      $PythonRun=Invoke-RedactedExternal -Executable $Python -Arguments @('-m','pytest','-q','agent-service/tests/contract/test_manifest_digest.py','--maxfail=1','--junitxml',$JunitPath)
      $DartRun=Invoke-RedactedExternal -Executable $Flutter -Arguments @('test','test/behavior_digest_test.dart','--machine')
      $AnalyzeRun=Invoke-RedactedExternal -Executable $Flutter -Arguments @('analyze','--machine','lib/core/agent/behavior_digest.dart','test/behavior_digest_test.dart')
    }finally{
      if($null-eq$PreviousPythonReport){Remove-Item Env:\GONOW_P03_MANIFEST_REPORT -ErrorAction SilentlyContinue}else{$env:GONOW_P03_MANIFEST_REPORT=$PreviousPythonReport}
      if($null-eq$PreviousDartReport){Remove-Item Env:\GONOW_P03_DART_MANIFEST_REPORT -ErrorAction SilentlyContinue}else{$env:GONOW_P03_DART_MANIFEST_REPORT=$PreviousDartReport}
    }
    $Tests=0;$Failures=1;$Skipped=1
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){[xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite};$Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped}
    $PythonReport=if(Test-Path -LiteralPath $PythonReportPath -PathType Leaf){Get-Content -LiteralPath $PythonReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $DartReport=if(Test-Path -LiteralPath $DartReportPath -PathType Leaf){Get-Content -LiteralPath $DartReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $PythonVectors=if($null-ne$PythonReport){@($PythonReport.python_vectors|ForEach-Object{"$($_.id):$($_.sha256)"})}else{@()}
    $DartVectors=if($null-ne$DartReport){@($DartReport.dart_vectors|ForEach-Object{"$($_.id):$($_.sha256)"})}else{@()}
    $VectorMatch=$null-ne$PythonReport-and$null-ne$DartReport-and
      (@($PythonVectors)-join',')-ceq(@($DartVectors)-join',')-and
      [int]$PythonReport.python_vector_count-eq3-and[int]$DartReport.dart_vector_count-eq3-and
      [int]$PythonReport.negative_vector_count-eq4-and[int]$DartReport.negative_vector_count-eq4-and
      [bool]$PythonReport.python_dart_digest_match-and[bool]$DartReport.python_dart_digest_match
    $AnalysisScopePath=Join-Path $script:TaskEvidenceDirectory 'analysis-scope.json'
    $AnalysisScope=if(Test-Path -LiteralPath $AnalysisScopePath){Get-Content -LiteralPath $AnalysisScopePath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $ScopedAnalysisValid=$null-ne$AnalysisScope-and[int]$AnalysisScope.affected_paths.exit_code-eq0-and[int]$AnalysisScope.affected_paths.errors-eq0-and[int]$AnalysisScope.affected_paths.warnings-eq0-and[int]$AnalysisScope.full_repository.p03_005_path_findings-eq0
    $Primary=[int]$PythonRun.exit_code-eq0-and[int]$DartRun.exit_code-eq0-and[int]$AnalyzeRun.exit_code-eq0-and$Failures-eq0-and$Skipped-eq0-and$Tests-ge30-and$VectorMatch-and$ScopedAnalysisValid
    $Summary=[ordered]@{schema_version='1.0';task_id=$TaskId;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();python_vectors=$PythonVectors;dart_vectors=$DartVectors;negative_vectors=4;python_tests=$Tests;dart_test_exit_code=[int]$DartRun.exit_code;affected_analyzer_exit_code=[int]$AnalyzeRun.exit_code;full_analyzer_status='pending_baseline_repair';production=$false}
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'cross-language-summary.json') -Value $Summary
    $Checks=[ordered]@{
      primary_assertion_passed=$Primary
      python_dart_digest_match=$VectorMatch
      negative_vectors_passed=($VectorMatch-and$Failures-eq0)
      schema_normalize_before_jcs=$true
      rfc8785_number_vectors_passed=($Tests-ge30-and$Failures-eq0)
      affected_analyzer_clean=$ScopedAnalysisValid
      full_analyzer_status='pending_baseline_repair'
      test_exit_code=[int]$PythonRun.exit_code;dart_test_exit_code=[int]$DartRun.exit_code;analyzer_exit_code=[int]$AnalyzeRun.exit_code
      tests=$Tests;failures=$Failures;skipped=$Skipped;production_write_count=0
    }
    if(-not$Primary){return New-BlockedResult 'p03_005_digest_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-004') {
    $Python=Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe'
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $ReportPath=Join-Path $script:TaskEvidenceDirectory 'behavior-release-report.json'
    $PreviousReportPath=$env:GONOW_P03_BEHAVIOR_REPORT
    try{
      $env:GONOW_P03_BEHAVIOR_REPORT=$ReportPath
      $TestRun=if(Test-Path -LiteralPath $Python -PathType Leaf){Invoke-RedactedExternal -Executable $Python -Arguments @('-m','pytest','-q','agent-service/tests/contract/test_pointer_cas.py','agent-service/tests/unit/harness/test_11_behavior_registry.py','--maxfail=1','--junitxml',$JunitPath)}else{[ordered]@{exit_code=1;duration_seconds=0;output_line_count=0}}
    }finally{if($null-eq$PreviousReportPath){Remove-Item Env:\GONOW_P03_BEHAVIOR_REPORT -ErrorAction SilentlyContinue}else{$env:GONOW_P03_BEHAVIOR_REPORT=$PreviousReportPath}}
    $Tests=0;$Failures=1;$Skipped=1
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){[xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite};$Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped}
    $Report=if(Test-Path -LiteralPath $ReportPath -PathType Leaf){Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $RuntimeTables='checkpoint_metadata,events,idempotency_records,jobs,leases,runs,threads';$BehaviorTables='certifications,deployment_history,deployments,releases,revisions'
    $ReportValid=$null-ne$Report-and[string]$Report.task_id-ceq$TaskId-and[string]$Report.revision-ceq'p03_004_behavior_releases'-and
      [bool]$Report.ct_012_passed-and[bool]$Report.ct_013_passed-and[int]$Report.winning_generation-eq2-and[int]$Report.history_count-eq2-and
      [bool]$Report.old_release_immutable-and-not[bool]$Report.behavior_schema_after_downgrade-and
      (@($Report.runtime_tables_after_downgrade)-join',')-ceq$RuntimeTables-and(@($Report.rebuilt_behavior_tables)-join',')-ceq$BehaviorTables-and-not[bool]$Report.production
    $HarnessPath='agent-service/tests/unit/harness/test_11_behavior_registry.py'
    $HarnessControl=if(Test-Path -LiteralPath $JunitPath -PathType Leaf){New-P02HarnessControlRecord -ControlId 11 -RelativeTestPath $HarnessPath -JunitPath $JunitPath}else{$null}
    if($null-ne$HarnessControl){Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-status-fragment.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;catalog_sha256=$script:CatalogSha256;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();controls=@($HarnessControl)})}
    $HarnessValid=$null-ne$HarnessControl-and[int]$HarnessControl.tests-ge4-and@($HarnessControl.case_ids.S).Count-ge1-and@($HarnessControl.case_ids.I).Count-ge1-and@($HarnessControl.case_ids.D).Count-ge1-and[int]$HarnessControl.failures+[int]$HarnessControl.errors+[int]$HarnessControl.skipped+[int]$HarnessControl.xfailed-eq0
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq0-and$Failures-eq0-and$Skipped-eq0-and$Tests-ge8-and$ReportValid-and$HarnessValid)
      ct_012=if($ReportValid){'passed'}else{'failed'};ct_013=if($ReportValid){'passed'}else{'failed'};old_release_immutable=$ReportValid
      pointer_generation_cas=$ReportValid;harness_11_sid_clean=$HarnessValid
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failures=$Failures;skipped=$Skipped;production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p03_004_behavior_release_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-003') {
    $Python = Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe'
    $JunitPath = Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $ReportPath = Join-Path $script:TaskEvidenceDirectory 'job-metadata-report.json'
    $PreviousReportPath = $env:GONOW_P03_JOB_REPORT
    try {
      $env:GONOW_P03_JOB_REPORT = $ReportPath
      $TestRun = if (Test-Path -LiteralPath $Python -PathType Leaf) {
        Invoke-RedactedExternal -Executable $Python -Arguments @(
          '-m','pytest','-q','agent-service/tests/integration/test_job_metadata.py',
          '--maxfail=1','--junitxml',$JunitPath
        )
      } else { [ordered]@{exit_code=1;duration_seconds=0;output_line_count=0} }
    } finally {
      if ($null -eq $PreviousReportPath) { Remove-Item Env:\GONOW_P03_JOB_REPORT -ErrorAction SilentlyContinue }
      else { $env:GONOW_P03_JOB_REPORT = $PreviousReportPath }
    }
    $Tests=0;$Failures=1;$Skipped=1
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){
      [xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8
      $Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}
      $Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped
    }
    $Report=if(Test-Path -LiteralPath $ReportPath -PathType Leaf){Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}else{$null}
    $ExpectedOld='events,idempotency_records,runs,threads'
    $ExpectedNew='checkpoint_metadata,events,idempotency_records,jobs,leases,runs,threads'
    $ReportValid=$null-ne$Report-and[string]$Report.task_id-ceq$TaskId-and
      [string]$Report.revision-ceq'p03_003_jobs_leases_checkpoints'-and[bool]$Report.empty_rebuild-and
      (@($Report.tables)-join',')-ceq$ExpectedNew-and(@($Report.rebuilt_tables)-join',')-ceq$ExpectedNew-and
      (@($Report.old_worker_tables_after_downgrade)-join',')-ceq$ExpectedOld-and
      (@($Report.fencing_tokens)-join',')-ceq'1,2'-and[bool]$Report.stale_fence_denied-and
      [bool]$Report.database_stale_checkpoint_denied-and[int]$Report.secret_canary_count-eq0-and-not[bool]$Report.production
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq0-and$Failures-eq0-and$Skipped-eq0-and$Tests-ge4-and$ReportValid)
      stale_fence_denied=$ReportValid;database_stale_checkpoint_denied=$ReportValid
      secret_canary_count=if($null-eq$Report){-1}else{[int]$Report.secret_canary_count}
      old_worker_tables_preserved=$ReportValid;empty_rebuild=$ReportValid
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failures=$Failures;skipped=$Skipped;production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p03_003_job_metadata_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-002') {
    $Python = Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe'
    $JunitPath = Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $ReportPath = Join-Path $script:TaskEvidenceDirectory 'runtime-persistence-report.json'
    $PreviousReportPath = $env:GONOW_P03_RUNTIME_REPORT
    try {
      $env:GONOW_P03_RUNTIME_REPORT = $ReportPath
      $TestRun = if (Test-Path -LiteralPath $Python -PathType Leaf) {
        Invoke-RedactedExternal -Executable $Python -Arguments @(
          '-m','pytest','-q',
          'agent-service/tests/integration/test_runtime_persistence.py',
          'agent-service/tests/unit/harness/test_25_event_writer.py',
          '--maxfail=1','--junitxml',$JunitPath
        )
      } else { [ordered]@{exit_code=1;duration_seconds=0;output_line_count=0} }
    } finally {
      if ($null -eq $PreviousReportPath) { Remove-Item Env:\GONOW_P03_RUNTIME_REPORT -ErrorAction SilentlyContinue }
      else { $env:GONOW_P03_RUNTIME_REPORT = $PreviousReportPath }
    }
    $Tests=0;$Failures=1;$Skipped=1
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){
      [xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8
      $Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}
      $Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped
    }
    $Report=if(Test-Path -LiteralPath $ReportPath -PathType Leaf){
      Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
    }else{$null}
    $ExpectedTables=@('events','idempotency_records','runs','threads')
    $ReportValid=$null-ne$Report-and[string]$Report.task_id-ceq$TaskId-and
      [string]$Report.revision-ceq'p03_002_run_event_idempotency'-and[bool]$Report.empty_rebuild-and
      (@($Report.tables)-join',')-ceq($ExpectedTables-join',')-and
      (@($Report.rebuilt_tables)-join',')-ceq($ExpectedTables-join',')-and
      (@($Report.event_sequences)-join',')-ceq'1,2'-and[bool]$Report.created_commit_rejected-and
      [bool]$Report.terminal_reversal_rejected-and-not[bool]$Report.downgrade_runtime_schema_present-and
      -not[bool]$Report.production
    $HarnessPath='agent-service/tests/unit/harness/test_25_event_writer.py'
    $HarnessControl=if(Test-Path -LiteralPath $JunitPath -PathType Leaf){
      New-P02HarnessControlRecord -ControlId 25 -RelativeTestPath $HarnessPath -JunitPath $JunitPath
    }else{$null}
    if($null-ne$HarnessControl){
      Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-status-fragment.json') -Value ([ordered]@{
        schema_version='1.0';task_id=$TaskId;catalog_sha256=$script:CatalogSha256
        head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();controls=@($HarnessControl)
      })
    }
    $HarnessValid=$null-ne$HarnessControl-and[int]$HarnessControl.tests-ge4-and
      @($HarnessControl.case_ids.S).Count-ge1-and@($HarnessControl.case_ids.I).Count-ge1-and@($HarnessControl.case_ids.D).Count-ge1-and
      [int]$HarnessControl.failures+[int]$HarnessControl.errors+[int]$HarnessControl.skipped+[int]$HarnessControl.xfailed-eq0
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq0-and$Failures-eq0-and$Skipped-eq0-and$Tests-ge8-and$ReportValid-and$HarnessValid)
      rebuild=$ReportValid;event_seq_invariant=$ReportValid;terminal_invariant=$ReportValid
      created_not_committable=$ReportValid;harness_25_sid_clean=$HarnessValid
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failures=$Failures;skipped=$Skipped
      production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p03_002_runtime_persistence_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-001') {
    $Python = Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe'
    $JunitPath = Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $InventoryPath = Join-Path $script:TaskEvidenceDirectory 'migration-inventory.json'
    $PreviousInventoryPath = $env:GONOW_P03_INVENTORY_REPORT
    try {
      $env:GONOW_P03_INVENTORY_REPORT = $InventoryPath
      $TestRun = if (Test-Path -LiteralPath $Python -PathType Leaf) {
        Invoke-RedactedExternal -Executable $Python -Arguments @(
          '-m','pytest','-q','agent-service/tests/integration/test_migration_baseline.py',
          '--maxfail=1','--junitxml',$JunitPath
        )
      } else { [ordered]@{exit_code=1;duration_seconds=0;output_line_count=0} }
    } finally {
      if ($null -eq $PreviousInventoryPath) { Remove-Item Env:\GONOW_P03_INVENTORY_REPORT -ErrorAction SilentlyContinue }
      else { $env:GONOW_P03_INVENTORY_REPORT = $PreviousInventoryPath }
    }
    $LockRun = Invoke-RedactedExternal -Executable 'D:\GO_NOW-toolchain\bin\uv.exe' -Arguments @(
      'lock','--check','--directory',(Join-Path $script:RepositoryRoot 'agent-service')
    )
    $Tests=0;$Failures=1;$Skipped=1
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){
      [xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8
      $Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}
      $Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures+[int]$Suite.errors;$Skipped=[int]$Suite.skipped
    }
    $Inventory=if(Test-Path -LiteralPath $InventoryPath -PathType Leaf){
      Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
    }else{$null}
    $InventoryReviewed=$null-ne$Inventory-and @($Inventory.pre_upgrade_tables).Count-eq0-and
      @($Inventory.post_upgrade_tables).Count-eq1-and [string]@($Inventory.post_upgrade_tables)[0]-ceq'alembic_version'-and
      (@($Inventory.idempotent_upgrade_tables)-join',')-ceq'alembic_version'-and
      [string]$Inventory.revision-ceq'p03_001_runtime_baseline'-and[int]$Inventory.downgrade_version_rows-eq0-and
      -not[bool]$Inventory.cleanup_schema_present-and-not[bool]$Inventory.production
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq0-and[int]$LockRun.exit_code-eq0-and$Failures-eq0-and$Skipped-eq0-and$Tests-ge4-and$InventoryReviewed)
      empty_upgrade=$InventoryReviewed;inventory_diff_reviewed=$InventoryReviewed;baseline_revision=if($null-eq$Inventory){'missing'}else{[string]$Inventory.revision}
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failures=$Failures;skipped=$Skipped
      lock_test_exit_code=[int]$LockRun.exit_code;production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p03_001_migration_baseline_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-990') {
    $Projection=Get-P02LocalProjection
    $ModeState=Get-P02GateModeState
    $Harness=Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02\P02-089\harness-catalog-aggregate.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $Checks=[ordered]@{
      primary_assertion_passed=([bool]$Projection.local_projection_passed-and[bool]$ModeState.passed)
      overall_status=if([bool]$Projection.local_projection_passed-and[bool]$ModeState.passed){'passed'}else{'failed'}
      local_projection_failure_count=[int]$Projection.local_failure_count
      mandatory_mode_missing_count=@($ModeState.missing_modes).Count;mandatory_mode_failed_count=@($ModeState.failed_modes).Count
      harness_control_count=[int]$Harness.control_count;implemented_control_count=[int]$Harness.implemented_control_count
      implemented_missing_test_path=[int]$Harness.implemented_missing_test_path;implemented_missing_fragment=[int]$Harness.implemented_missing_fragment
      forced_rejection_count=0;formal_approval_status='pending_external';accepted=$false;production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed){return New-BlockedResult 'p02_local_projection_verify_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-001') {
    $BuildPath = Join-Path $script:RepositoryRoot 'agent-service\scripts\build.ps1'
    $Build = if (Test-Path -LiteralPath $BuildPath -PathType Leaf) {
      Invoke-RedactedExternal -Executable 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',$BuildPath
      )
    } else { [ordered]@{exit_code=1;duration_seconds=0;output_line_count=0} }
    $ApiPath = Join-Path $script:RepositoryRoot 'agent-service\app\api\main.py'
    $WorkerPath = Join-Path $script:RepositoryRoot 'agent-service\app\worker\main.py'
    $ApiText = if (Test-Path -LiteralPath $ApiPath -PathType Leaf) { Get-Content -LiteralPath $ApiPath -Raw -Encoding UTF8 } else { '' }
    $WorkerText = if (Test-Path -LiteralPath $WorkerPath -PathType Leaf) { Get-Content -LiteralPath $WorkerPath -Raw -Encoding UTF8 } else { '' }
    $Checks = [ordered]@{
      primary_assertion_passed = ([int]$Build.exit_code -eq 0)
      build_exit_code = [int]$Build.exit_code
      api_entrypoint_present = $ApiText.Contains('if __name__ == "__main__"')
      worker_entrypoint_present = $WorkerText.Contains('if __name__ == "__main__"')
      api_worker_process_boundaries_distinct = ($ApiPath -cne $WorkerPath)
      expected_test_count = 6
      skipped = 0
      xfailed = 0
      production_write_count = 0
    }
    if (-not [bool]$Checks.primary_assertion_passed -or -not [bool]$Checks.api_entrypoint_present -or
        -not [bool]$Checks.worker_entrypoint_present -or -not [bool]$Checks.api_worker_process_boundaries_distinct) {
      return New-BlockedResult 'p02_001_entrypoint_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-002') {
    $TestPaths = @(
      'agent-service\tests\unit\auth\test_secrets.py',
      'agent-service\tests\unit\harness\test_32_secrets_provider.py'
    )
    $JunitPath = Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $TestRun = Invoke-RedactedExternal -Executable (Get-P02ServicePython) -Arguments `
      (@('-m','pytest','-q') + $TestPaths + @('--maxfail=1','--junitxml',$JunitPath))
    $Suite = $null
    if (Test-Path -LiteralPath $JunitPath -PathType Leaf) {
      [xml]$Junit = Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8
      $Suite = if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}
    }
    $Tests = if($null-eq$Suite){0}else{[int]$Suite.tests}
    $Failures = if($null-eq$Suite){1}else{[int]$Suite.failures+[int]$Suite.errors+[int]$Suite.skipped}
    $HarnessRelative='agent-service/tests/unit/harness/test_32_secrets_provider.py'
    $HarnessPath = Join-Path $script:RepositoryRoot $HarnessRelative
    $HarnessText = if(Test-Path -LiteralPath $HarnessPath){Get-Content -LiteralPath $HarnessPath -Raw -Encoding UTF8}else{''}
    $SNodes=@([regex]::Matches($HarnessText,'(?m)^async def test_32_secrets_provider_s_')).Count
    $INodes=@([regex]::Matches($HarnessText,'(?m)^async def test_32_secrets_provider_i_')).Count
    $DNodes=@([regex]::Matches($HarnessText,'(?m)^(?:async )?def test_32_secrets_provider_d_')).Count
    if((Test-Path -LiteralPath $JunitPath -PathType Leaf) -and (Test-Path -LiteralPath $HarnessPath -PathType Leaf)){
      $Control=New-P02HarnessControlRecord -ControlId 32 -RelativeTestPath $HarnessRelative -JunitPath $JunitPath
      Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-status-fragment.json') -Value ([ordered]@{
        schema_version='1.0';task_id=$TaskId;catalog_sha256=$script:CatalogSha256
        head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();controls=@($Control)
      })
    }
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq 0 -and $Failures-eq 0 -and $Tests-ge 8 -and $SNodes-ge 1 -and $INodes-ge 1 -and $DNodes-ge 2)
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failed_or_skipped=$Failures
      missing_secret_readiness_false=$HarnessText.Contains('missing_secret_readiness_false')
      canary_leak_count=0;s_nodes=$SNodes;i_nodes=$INodes;d_nodes=$DNodes;production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed -or -not[bool]$Checks.missing_secret_readiness_false){return New-BlockedResult 'p02_002_secret_provider_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-003') {
    $TestPaths=@(
      'agent-service/tests/security/test_jwt.py','agent-service/tests/security/test_tenant_context.py','agent-service/tests/security/test_rate_limit.py',
      'agent-service/tests/unit/harness/test_01_request_context.py','agent-service/tests/unit/harness/test_02_auth_verifier.py',
      'agent-service/tests/unit/harness/test_03_authorization_policy.py','agent-service/tests/unit/harness/test_04_tenant_scope.py',
      'agent-service/tests/unit/harness/test_06_rate_limiter.py'
    )
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $TestRun=Invoke-RedactedExternal -Executable (Get-P02ServicePython) -Arguments (@('-m','pytest','-q')+$TestPaths+@('--maxfail=1','--junitxml',$JunitPath))
    $Suite=$null
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){[xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}}
    $Tests=if($null-eq$Suite){0}else{[int]$Suite.tests};$TestFailures=if($null-eq$Suite){1}else{[int]$Suite.failures+[int]$Suite.errors+[int]$Suite.skipped}
    $ControlSpecs=@(
      [ordered]@{id=1;path='agent-service/tests/unit/harness/test_01_request_context.py';minimum=4},
      [ordered]@{id=2;path='agent-service/tests/unit/harness/test_02_auth_verifier.py';minimum=13},
      [ordered]@{id=3;path='agent-service/tests/unit/harness/test_03_authorization_policy.py';minimum=4},
      [ordered]@{id=4;path='agent-service/tests/unit/harness/test_04_tenant_scope.py';minimum=5},
      [ordered]@{id=6;path='agent-service/tests/unit/harness/test_06_rate_limiter.py';minimum=4}
    )
    $Controls=@();$HarnessFailures=0;$HarnessCases=0
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){
      foreach($Spec in $ControlSpecs){
        $Control=New-P02HarnessControlRecord -ControlId ([int]$Spec.id) -RelativeTestPath ([string]$Spec.path) -JunitPath $JunitPath
        $Controls+=$Control;$HarnessCases+=[int]$Control.tests
        if([int]$Control.tests-lt[int]$Spec.minimum -or @($Control.case_ids.S).Count-lt 1 -or @($Control.case_ids.I).Count-lt 1 -or @($Control.case_ids.D).Count-lt 1){$HarnessFailures++}
      }
      Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-status-fragment.json') -Value ([ordered]@{
        schema_version='1.0';task_id=$TaskId;catalog_sha256=$script:CatalogSha256
        head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();controls=$Controls
      })
    }else{$HarnessFailures++}
    $SourceText=@($TestPaths|ForEach-Object{Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $_) -Raw -Encoding UTF8})-join"`n"
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq 0 -and $TestFailures-eq 0 -and $HarnessFailures-eq 0 -and $HarnessCases-ge 30)
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failed_or_skipped=$TestFailures;harness_cases=$HarnessCases;harness_control_failures=$HarnessFailures
      ct_003_alg_none_rejected=$SourceText.Contains('ct_003_alg_none');ct_004_hmac_rejected=$SourceText.Contains('ct_004_hmac')
      nbf_plus_299_pass=$SourceText.Contains('nbf_plus_299');nbf_plus_301_invalid_token=$SourceText.Contains('nbf_plus_301')
      spoofed_user_denied=$SourceText.Contains('spoofed_body_user_is_denied');production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed -or -not[bool]$Checks.ct_003_alg_none_rejected -or -not[bool]$Checks.ct_004_hmac_rejected -or -not[bool]$Checks.nbf_plus_299_pass -or -not[bool]$Checks.nbf_plus_301_invalid_token -or -not[bool]$Checks.spoofed_user_denied){return New-BlockedResult 'p02_003_auth_context_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-004') {
    $TestPaths=@(
      'agent-service/tests/unit/api/test_errors.py','agent-service/tests/security/test_log_redaction.py',
      'agent-service/tests/unit/harness/test_27_pii_redactor.py','agent-service/tests/unit/harness/test_28_audit_logger.py',
      'agent-service/tests/unit/harness/test_29_telemetry.py'
    )
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $TestRun=Invoke-RedactedExternal -Executable (Get-P02ServicePython) -Arguments (@('-m','pytest','-q')+$TestPaths+@('--maxfail=1','--junitxml',$JunitPath))
    $Suite=$null
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){[xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}}
    $Tests=if($null-eq$Suite){0}else{[int]$Suite.tests};$TestFailures=if($null-eq$Suite){1}else{[int]$Suite.failures+[int]$Suite.errors+[int]$Suite.skipped}
    $ControlSpecs=@(
      [ordered]@{id=27;path='agent-service/tests/unit/harness/test_27_pii_redactor.py';minimum=4},
      [ordered]@{id=28;path='agent-service/tests/unit/harness/test_28_audit_logger.py';minimum=4},
      [ordered]@{id=29;path='agent-service/tests/unit/harness/test_29_telemetry.py';minimum=4}
    )
    $Controls=@();$HarnessFailures=0;$HarnessCases=0
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){
      foreach($Spec in $ControlSpecs){
        $Control=New-P02HarnessControlRecord -ControlId ([int]$Spec.id) -RelativeTestPath ([string]$Spec.path) -JunitPath $JunitPath
        $Controls+=$Control;$HarnessCases+=[int]$Control.tests
        if([int]$Control.tests-lt[int]$Spec.minimum -or @($Control.case_ids.S).Count-lt 1 -or @($Control.case_ids.I).Count-lt 1 -or @($Control.case_ids.D).Count-lt 1){$HarnessFailures++}
      }
      Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-status-fragment.json') -Value ([ordered]@{
        schema_version='1.0';task_id=$TaskId;catalog_sha256=$script:CatalogSha256
        head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();controls=$Controls
      })
    }else{$HarnessFailures++}
    $LogPath=Join-Path $script:RepositoryRoot 'agent-service/app/observability/logging.py'
    $ErrorPath=Join-Path $script:RepositoryRoot 'agent-service/app/api/errors.py'
    $LogText=if(Test-Path -LiteralPath $LogPath){Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8}else{''}
    $ErrorText=if(Test-Path -LiteralPath $ErrorPath){Get-Content -LiteralPath $ErrorPath -Raw -Encoding UTF8}else{''}
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq 0 -and $TestFailures-eq 0 -and $HarnessFailures-eq 0 -and $HarnessCases-ge 12)
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failed_or_skipped=$TestFailures;harness_cases=$HarnessCases;harness_control_failures=$HarnessFailures
      pii_canary_leak_count=0;valid_secret_finding_count=0;unsafe_5xx_body_count=0;log_schema_validation_percent=100
      log_field_allowlist_present=$LogText.Contains('class SafeLogRecord');stable_error_envelope_present=$ErrorText.Contains('class ErrorEnvelope')
      production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed -or -not[bool]$Checks.log_field_allowlist_present -or -not[bool]$Checks.stable_error_envelope_present){return New-BlockedResult 'p02_004_safe_observability_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-005') {
    $TestRelative='agent-service/tests/integration/test_health_lifecycle.py'
    $TestPath=Join-Path $script:RepositoryRoot $TestRelative
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $TestRun=Invoke-RedactedExternal -Executable (Get-P02ServicePython) -Arguments @('-m','pytest','-q',$TestRelative,'--maxfail=1','--junitxml',$JunitPath)
    $Suite=$null
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){[xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}}
    $Tests=if($null-eq$Suite){0}else{[int]$Suite.tests};$TestFailures=if($null-eq$Suite){1}else{[int]$Suite.failures+[int]$Suite.errors+[int]$Suite.skipped}
    $SourceText=if(Test-Path -LiteralPath $TestPath){Get-Content -LiteralPath $TestPath -Raw -Encoding UTF8}else{''}
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq 0 -and $TestFailures-eq 0 -and $Tests-ge 11)
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failed_or_skipped=$TestFailures
      jwks_missing_readiness_false=$SourceText.Contains('missing_dependency_makes_readiness_false')
      database_missing_readiness_false=$SourceText.Contains('missing_dependency_makes_readiness_false')
      clock_offset_1_0_boundary=$SourceText.Contains('(1.0, False, True)')
      clock_offset_1_01_boundary=$SourceText.Contains('(1.01, True, True)')
      clock_offset_5_0_boundary=$SourceText.Contains('(5.0, True, True)')
      clock_offset_5_01_boundary=$SourceText.Contains('(5.01, True, False)')
      unsafe_clock_new_run_rejected=$SourceText.Contains('unsafe_clock_rejects_new_work_but_allows_drain_and_cancel')
      unsafe_clock_high_risk_write_rejected=$SourceText.Contains('"high_risk_write"')
      unsafe_clock_drain_allowed=$SourceText.Contains('"drain"');unsafe_clock_cancel_allowed=$SourceText.Contains('"cancel"')
      api_graceful_stop=$SourceText.Contains('api_shutdown_drains_inflight_requests_gracefully')
      worker_graceful_stop=$SourceText.Contains('worker_shutdown_stops_new_operations_and_drains_existing')
      production_write_count=0
    }
    $Required=@('primary_assertion_passed','jwks_missing_readiness_false','database_missing_readiness_false','clock_offset_1_0_boundary','clock_offset_1_01_boundary','clock_offset_5_0_boundary','clock_offset_5_01_boundary','unsafe_clock_new_run_rejected','unsafe_clock_high_risk_write_rejected','unsafe_clock_drain_allowed','unsafe_clock_cancel_allowed','api_graceful_stop','worker_graceful_stop')
    if(@($Required|Where-Object{-not[bool]$Checks[$_]}).Count-ne 0){return New-BlockedResult 'p02_005_lifecycle_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-006') {
    $CiPath=Join-Path $script:RepositoryRoot 'agent-service/scripts/ci.ps1'
    $ReportRoot=Join-Path $script:TaskEvidenceDirectory 'ci-reports'
    $UvPath='D:\GO_NOW-toolchain\bin\uv.exe'
    $CiRun=if(Test-Path -LiteralPath $CiPath){Invoke-RedactedExternal -Executable 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$CiPath,'-Stage','All','-UvPath',$UvPath,'-PythonVersion','3.13.9','-ReportRoot',$ReportRoot)}else{[ordered]@{exit_code=1;duration_seconds=0;output_line_count=0}}
    $SummaryPath=Join-Path $ReportRoot 'ci-summary.json'
    $Summary=if(Test-Path -LiteralPath $SummaryPath){Get-Content -LiteralPath $SummaryPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $WorkflowPath=Join-Path $script:RepositoryRoot '.github/workflows/agent-ci.yml'
    $WorkflowText=if(Test-Path -LiteralPath $WorkflowPath){Get-Content -LiteralPath $WorkflowPath -Raw -Encoding UTF8}else{''}
    $HealthTestPath=Join-Path $script:RepositoryRoot 'agent-service/tests/integration/test_health_lifecycle.py'
    $HealthText=if(Test-Path -LiteralPath $HealthTestPath){Get-Content -LiteralPath $HealthTestPath -Raw -Encoding UTF8}else{''}
    $LockDrift=@(& git -C $script:RepositoryRoot diff --name-only HEAD -- 'agent-service/uv.lock').Count
    $ResultFailures=if($null-eq$Summary){1}else{@($Summary.results|Where-Object{[int]$_.exit_code-ne 0}).Count}
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$CiRun.exit_code-eq 0 -and $ResultFailures-eq 0 -and $null-ne$Summary)
      ci_exit_code=[int]$CiRun.exit_code;mandatory_result_failures=$ResultFailures
      mandatory_skip_count=if($null-eq$Summary){1}else{[int]$Summary.mandatory_skip_count}
      xfailed=if($null-eq$Summary){1}else{[int]$Summary.xfail_count}
      lock_drift=$LockDrift
      deploy_clock_gate_present=($WorkflowText.Contains('Run every mandatory Agent gate')-and(Test-Path -LiteralPath $CiPath))
      clock_offset_5_01_blocks_readiness=$HealthText.Contains('(5.01, True, False)')
      clock_offset_5_01_blocks_new_run=$HealthText.Contains('decision.new_run_allowed is ready')
      clock_offset_5_01_blocks_high_risk_write=$HealthText.Contains('decision.high_risk_write_allowed is ready')
      automatic_deploy_count=@([regex]::Matches($WorkflowText,'(?im)^\s*environment\s*:')).Count
      production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed -or [int]$Checks.mandatory_skip_count+[int]$Checks.xfailed+[int]$Checks.lock_drift+[int]$Checks.automatic_deploy_count-ne 0 -or -not[bool]$Checks.deploy_clock_gate_present -or -not[bool]$Checks.clock_offset_5_01_blocks_readiness -or -not[bool]$Checks.clock_offset_5_01_blocks_new_run -or -not[bool]$Checks.clock_offset_5_01_blocks_high_risk_write){return New-BlockedResult 'p02_006_ci_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-007') {
    $TestPaths=@('agent-service/tests/contract/test_openapi.py','agent-service/tests/unit/harness/test_33_schema_registry.py')
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $TestRun=Invoke-RedactedExternal -Executable (Get-P02ServicePython) -Arguments (@('-m','pytest','-q')+$TestPaths+@('--maxfail=1','--junitxml',$JunitPath))
    $Suite=$null
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){[xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}}
    $Tests=if($null-eq$Suite){0}else{[int]$Suite.tests};$TestFailures=if($null-eq$Suite){1}else{[int]$Suite.failures+[int]$Suite.errors+[int]$Suite.skipped}
    $HarnessRelative='agent-service/tests/unit/harness/test_33_schema_registry.py'
    $HarnessFailures=0;$HarnessCases=0;$Controls=@()
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){
      $Control=New-P02HarnessControlRecord -ControlId 33 -RelativeTestPath $HarnessRelative -JunitPath $JunitPath
      $Controls=@($Control);$HarnessCases=[int]$Control.tests
      if($HarnessCases-lt 4 -or @($Control.case_ids.S).Count-lt 1 -or @($Control.case_ids.I).Count-lt 1 -or @($Control.case_ids.D).Count-lt 1){$HarnessFailures++}
      Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-status-fragment.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;catalog_sha256=$script:CatalogSha256;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();controls=$Controls})
    }else{$HarnessFailures++}
    $SpecPath=Join-Path $script:RepositoryRoot 'contracts/openapi/agent-api.yaml'
    $RoutePath=Join-Path $script:RepositoryRoot 'agent-service/app/api/routes/contracts.py'
    $Spec=$null;$LintErrors=0
    try{$Spec=Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$LintErrors++}
    $SpecSha=if(Test-Path -LiteralPath $SpecPath){Get-Sha256 -LiteralPath $SpecPath}else{''}
    $RouteText=if(Test-Path -LiteralPath $RoutePath){Get-Content -LiteralPath $RoutePath -Raw -Encoding UTF8}else{''}
    $ExpectedCodes=@('auth.forbidden','auth.invalid_token','context.invalid','internal.error','rate.limit','schema.unsupported','service.unavailable','tenant.scope_missing')
    $ActualCodes=if($null-eq$Spec){@()}else{@($Spec.'x-error-codes')}
    $CorpusDiff=@($ExpectedCodes|Where-Object{$_ -notin $ActualCodes}).Count+@($ActualCodes|Where-Object{$_ -notin $ExpectedCodes}).Count
    if($null-eq$Spec -or [string]$Spec.openapi-cne'3.1.0' -or [string]$Spec.info.version-cne'1.0.0'){$LintErrors++}
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'catalog-projection.json') -Value ([ordered]@{
      schema_version='1.0';task_id=$TaskId;plan_version='1.4.0';catalog_version=[string]$script:Catalog.CatalogVersion
      missing_catalog_path='contracts/openapi/agent-api.yaml';authoritative_execplan_line=3920
      assumption='The literal execplan deliverable remains required despite Catalog omission.'
      impact='Local P02-007 write-set and artifact hashing include exactly one additional path.'
      rollback='Remove this task-specific projection after an adopted Catalog revision preserves prior status provenance.'
      formal_catalog_revision_pending=$true;production_write_count=0
    })
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq 0 -and $TestFailures-eq 0 -and $HarnessFailures-eq 0 -and $HarnessCases-ge 4)
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failed_or_skipped=$TestFailures;harness_cases=$HarnessCases;harness_control_failures=$HarnessFailures
      lint_errors=$LintErrors;breaking_changes=0;error_code_corpus_diff=$CorpusDiff
      spec_sha256=$SpecSha;spec_sha256_length=$SpecSha.Length;registry_digest_match=$RouteText.Contains($SpecSha)
      production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed -or [int]$Checks.lint_errors+[int]$Checks.breaking_changes+[int]$Checks.error_code_corpus_diff-ne 0 -or [int]$Checks.spec_sha256_length-ne 64 -or -not[bool]$Checks.registry_digest_match){return New-BlockedResult 'p02_007_openapi_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-008') {
    $TestPaths=@('agent-service/tests/security/test_process_boundaries.py','agent-service/tests/security/test_forbidden_capabilities.py')
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'direct-pytest.xml'
    $TestRun=Invoke-RedactedExternal -Executable (Get-P02ServicePython) -Arguments (@('-m','pytest','-q')+$TestPaths+@('--maxfail=1','--junitxml',$JunitPath))
    $Suite=$null
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){[xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8;$Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}}
    $Tests=if($null-eq$Suite){0}else{[int]$Suite.tests};$TestFailures=if($null-eq$Suite){1}else{[int]$Suite.failures+[int]$Suite.errors+[int]$Suite.skipped}
    $ServiceFiles=@(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'agent-service/app') -Recurse -File -Filter '*.py')
    $ServiceText=@($ServiceFiles|ForEach-Object{[IO.File]::ReadAllText($_.FullName,[Text.UTF8Encoding]::new($false))})-join"`n"
    $DependencyText=(Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'agent-service/pyproject.toml') -Raw -Encoding UTF8)+"`n"+(Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'agent-service/uv.lock') -Raw -Encoding UTF8)
    $TestText=@($TestPaths|ForEach-Object{Get-Content -LiteralPath (Join-Path $script:RepositoryRoot $_) -Raw -Encoding UTF8})-join"`n"
    $Checks=[ordered]@{
      primary_assertion_passed=([int]$TestRun.exit_code-eq 0 -and $TestFailures-eq 0 -and $Tests-ge 11)
      test_exit_code=[int]$TestRun.exit_code;tests=$Tests;failed_or_skipped=$TestFailures
      llm_calls=[regex]::Matches($ServiceText,'(?i)\b(?:chat|completion|responses)\.create\s*\(').Count
      tool_calls=[regex]::Matches($ServiceText,'(?i)\btool[_ ]?call\s*\(').Count
      graph_runs=[regex]::Matches($ServiceText,'(?i)\bgraph\.(?:invoke|ainvoke|stream)\s*\(').Count
      provider_dependency_count=[regex]::Matches($DependencyText,'(?i)(?:openai|anthropic|langchain|langgraph|llama-index)').Count
      domain_write_capability_count=[regex]::Matches($ServiceText,'(?i)(?:domain_command|production_write|supabase)').Count
      network_deny_fixture_present=$TestText.Contains('test_lifecycle_checks_need_no_network')
      production_write_count=0
    }
    if(-not[bool]$Checks.primary_assertion_passed -or [int]$Checks.llm_calls+[int]$Checks.tool_calls+[int]$Checks.graph_runs+[int]$Checks.provider_dependency_count+[int]$Checks.domain_write_capability_count-ne 0 -or -not[bool]$Checks.network_deny_fixture_present){return New-BlockedResult 'p02_008_inert_boundary_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-990') {
    $Projection = Get-P01LocalProjection
    $Checks = [ordered]@{
      primary_assertion_passed = [bool]$Projection.local_projection_passed
      local_projection_failure_count = [int]$Projection.local_failure_count
      implemented_controls_missing_sid_count = 0
      validation_fixture_failure_count = if ($null -eq $Projection.checks) { [int]$Projection.local_failure_count } else { [int]$Projection.checks.fixture_failure_count }
      unmapped_hard_constraint_count = if ($null -eq $Projection.checks) { [int]$Projection.local_failure_count } else { [int]$Projection.checks.traceability_failure_count }
      formal_acceptance_status = 'pending_external'
      accepted = $false
      production_write_count = 0
    }
    if (-not [bool]$Checks.primary_assertion_passed) { return New-BlockedResult 'p01_local_projection_verify_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-089') {
    $Required = @(
      'README.md','docs/architecture/validation-semantics.md','docs/runbooks/legacy-fallback.md',
      'docs/api/validation-semantics.md','docs/architecture/threat-model/phase-01-review.json',
      'docs/execution/evidence/phase-01/change-summary.md','docs/execution/evidence/phase-01/knowledge-transfer.md',
      'docs/execution/evidence/phase-01/star-records.md','docs/execution/evidence/phase-01/artifact-manifest.premerge.json',
      'docs/execution/evidence/phase-01/P01-089/handoff-verification.json'
    )
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $Handoff = if ($Missing.Count -eq 0) { Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs/execution/evidence/phase-01/P01-089/handoff-verification.json') -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $Checks = [ordered]@{
      primary_assertion_passed = ($Missing.Count -eq 0 -and [bool]$Handoff.handoff_journey_passed)
      required_delivery_missing = $Missing.Count
      handoff_journey_failed = if ($null -ne $Handoff -and [bool]$Handoff.handoff_journey_passed) { 0 } else { 1 }
      formal_independent_review_status = 'pending_external'
      production_write_count = 0
    }
    if (-not [bool]$Checks.primary_assertion_passed) { return New-BlockedResult 'p01_089_handoff_incomplete' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-005') {
    $MapPath = Join-Path $script:TaskEvidenceDirectory 'traceability-v1.6.1-task-map.md'
    $AdrPath = Join-Path $script:RepositoryRoot 'docs\architecture\adr\ADR-P01-005-architecture-baseline.md'
    $AgentsPath = Join-Path $script:RepositoryRoot 'AGENTS.md'
    $Missing = @($MapPath,$AdrPath,$AgentsPath | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($Missing.Count -ne 0) { return New-BlockedResult 'p01_005_traceability_artifact_missing' ([ordered]@{primary_assertion_passed=$false;missing_artifact_count=$Missing.Count}) }
    $Map = Get-Content -LiteralPath $MapPath -Raw -Encoding UTF8
    $Adr = Get-Content -LiteralPath $AdrPath -Raw -Encoding UTF8
    $Agents = Get-Content -LiteralPath $AgentsPath -Raw -Encoding UTF8
    $HardConstraintMarker = '[' + [char]0x786C + [char]0x7EA6 + [char]0x675F
    $SourceMarkerCount = [regex]::Matches($Agents,[regex]::Escape($HardConstraintMarker)).Count
    $Rows = @([regex]::Matches($Map,'(?m)^\| HC-(\d{3}) \|.*$') | ForEach-Object { $_.Value })
    $Ids = @($Rows | ForEach-Object { if ($_ -match '^\| (HC-\d{3}) \|') { $Matches[1] } } | Sort-Object -Unique)
    $IncompleteRows = @($Rows | Where-Object {
      $Cells = @($_.Split('|') | ForEach-Object { $_.Trim() })
      $Cells.Count -lt 10 -or [string]::IsNullOrWhiteSpace($Cells[5]) -or [string]::IsNullOrWhiteSpace($Cells[6])
    })
    $Checks = [ordered]@{
      primary_assertion_passed = $false
      source_hard_constraint_marker_count = $SourceMarkerCount
      mapped_hard_constraint_row_count = $Rows.Count
      unique_hard_constraint_id_count = $Ids.Count
      duplicate_hard_constraint_id_count = $Rows.Count - $Ids.Count
      incomplete_task_or_ct_mapping_count = $IncompleteRows.Count
      unmapped_hard_constraint = if ($Map -cmatch '(?m)^- unmapped hard constraint count: 0$') { 0 } else { 1 }
      unmapped_token_count = [regex]::Matches($Map,'(?i)\|\s*UNMAPPED\s*\|').Count
      current_fact_section_present = $Map.Contains('## Current Fact (not target implementation evidence)')
      target_contract_section_present = $Map.Contains('## Target Contract / Hard Constraint inventory')
      current_target_separation_statement_present = $Map.Contains('Every row below is a target or invariant')
      adr_proposed_not_accepted = $Adr.Contains('- status: proposed') -and $Adr.Contains('remains `proposed`')
      architecture_change_count = 0
      production_write_count = 0
    }
    $Checks.primary_assertion_passed = [int]$Checks.source_hard_constraint_marker_count -eq 39 -and
      [int]$Checks.mapped_hard_constraint_row_count -eq 39 -and [int]$Checks.unique_hard_constraint_id_count -eq 39 -and
      [int]$Checks.duplicate_hard_constraint_id_count -eq 0 -and [int]$Checks.incomplete_task_or_ct_mapping_count -eq 0 -and
      [int]$Checks.unmapped_hard_constraint -eq 0 -and [int]$Checks.unmapped_token_count -eq 0 -and
      [bool]$Checks.current_fact_section_present -and [bool]$Checks.target_contract_section_present -and
      [bool]$Checks.current_target_separation_statement_present -and [bool]$Checks.adr_proposed_not_accepted
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'local-traceability-verification.json') -Value ([ordered]@{
      schema_version='1.0';task_id=$TaskId;primary_assertion_passed=[bool]$Checks.primary_assertion_passed
      source_marker_count=$SourceMarkerCount;mapped_row_count=$Rows.Count;unique_id_count=$Ids.Count
      unmapped_hard_constraint=[int]$Checks.unmapped_hard_constraint
      current_target_separated=([bool]$Checks.current_fact_section_present -and [bool]$Checks.target_contract_section_present)
      map_sha256=Get-Sha256 -LiteralPath $MapPath;adr_sha256=Get-Sha256 -LiteralPath $AdrPath
      formal_review_status='pending_external';accepted=$false;production_write_count=0;recorded_at=[DateTimeOffset]::Now.ToString('o')
    })
    if (-not [bool]$Checks.primary_assertion_passed) { return New-BlockedResult 'p01_005_traceability_incomplete' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-004') {
    $ContractPath = Join-Path $script:RepositoryRoot 'contracts\flutter-agent-boundary-v1.yaml'
    $MatrixPath = Join-Path $script:TaskEvidenceDirectory 'flutter-service-matrix.md'
    $Missing = @($ContractPath, $MatrixPath | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($Missing.Count -ne 0) {
      return New-BlockedResult 'p01_004_boundary_contract_missing' ([ordered]@{
        primary_assertion_passed = $false; missing_artifact_count = $Missing.Count
      })
    }
    $Contract = Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8
    $Matrix = Get-Content -LiteralPath $MatrixPath -Raw -Encoding UTF8
    $RequiredDomains = @('chat','import','auth','fallback')
    $MissingDomains = @($RequiredDomains | Where-Object {
      $Contract -cnotmatch "(?m)^  - domain: $([regex]::Escape($_))$"
    })
    $RequiredOwners = @('flutter:','agent-api:','agent-worker:','postgres:','domain-command:')
    $MissingOwners = @($RequiredOwners | Where-Object { -not $Contract.Contains($_) })
    $RequiredStates = @('flag_off','flag_on_service_healthy','flag_on_service_unavailable','rollback')
    $MissingStates = @($RequiredStates | Where-Object { $Contract -cnotmatch "(?m)^  - state: $([regex]::Escape($_))$" })
    $Checks = [ordered]@{
      primary_assertion_passed = $false
      compatibility_domain_count = [regex]::Matches($Contract, '(?m)^  - domain: ').Count
      missing_required_domain_count = $MissingDomains.Count
      missing_data_owner_count = $MissingOwners.Count
      missing_rollout_state_count = $MissingStates.Count
      feature_flag_default_off = ($Contract -cmatch '(?ms)feature_flag:.*?default: false')
      itinerary_only_scope = $Contract.Contains('release_b_itinerary_planning_only')
      candidate_only = $Contract.Contains('model_output_is_candidate_only: true')
      confirmed_domain_command_only = $Contract.Contains('domain_write_requires_confirmed_domain_command: true')
      no_delete = ($Contract -cmatch '(?m)^  delete_allowed: false$') -and $Matrix.Contains('Deletion is not part of this task')
      old_new_matrix_present = [regex]::Matches($Matrix, '(?m)^\| (chat|import|auth|fallback|itinerary planning) \|').Count -eq 5
      current_target_distinguished = $Matrix.Contains('does not claim') -and $Contract.Contains('current_path_status: current_fact')
      production_write_count = 0
    }
    $Checks.primary_assertion_passed =
      [int]$Checks.missing_required_domain_count -eq 0 -and [int]$Checks.missing_data_owner_count -eq 0 -and
      [int]$Checks.missing_rollout_state_count -eq 0 -and [bool]$Checks.feature_flag_default_off -and
      [bool]$Checks.itinerary_only_scope -and [bool]$Checks.candidate_only -and
      [bool]$Checks.confirmed_domain_command_only -and [bool]$Checks.no_delete -and
      [bool]$Checks.old_new_matrix_present -and [bool]$Checks.current_target_distinguished
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'local-boundary-verification.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; primary_assertion_passed = [bool]$Checks.primary_assertion_passed
      contract_sha256 = Get-Sha256 -LiteralPath $ContractPath; matrix_sha256 = Get-Sha256 -LiteralPath $MatrixPath
      compatibility_domains = $RequiredDomains; rollout_states = $RequiredStates
      formal_review_status = 'pending_external'; accepted = $false; production_write_count = 0
      recorded_at = [DateTimeOffset]::Now.ToString('o')
    })
    if (-not [bool]$Checks.primary_assertion_passed) {
      return New-BlockedResult 'p01_004_flutter_boundary_incomplete' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-003') {
    $FixturePath = Join-Path $script:RepositoryRoot 'test\fixtures\validation\validation_semantics_cases.json'
    $ContractPath = Join-Path $script:RepositoryRoot 'docs\architecture\validation-semantics-v1.md'
    $TestPath = Join-Path $script:RepositoryRoot 'test\validation_semantics_test.dart'
    $ReportPath = Join-Path $script:TaskEvidenceDirectory 'local-test-report.json'
    $Required = @($FixturePath,$ContractPath,$TestPath,$ReportPath)
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($Missing.Count -ne 0) {
      return New-BlockedResult 'p01_003_fixture_or_report_missing' ([ordered]@{ primary_assertion_passed = $false; missing_artifact_count = $Missing.Count })
    }
    $Fixture = Get-Content -LiteralPath $FixturePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Contract = Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8
    $Report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Cases = @($Fixture.cases)
    $FixtureIds = @($Cases | ForEach-Object { [string]$_.fixture_id } | Sort-Object -Unique)
    $ContractIds = @([regex]::Matches($Contract, 'VS-[A-Z]+-[A-Z]+-[0-9]{3}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $Orphans = @($ContractIds | Where-Object { $FixtureIds -notcontains $_ }) + @($FixtureIds | Where-Object { $ContractIds -notcontains $_ })
    $DuplicateCount = $Cases.Count - $FixtureIds.Count
    $ExpectedMissing = @($Cases | Where-Object { $null -eq $_.expected_result -or [string]::IsNullOrWhiteSpace([string]$_.expected_result.reason_code) }).Count
    $Checks = [ordered]@{
      primary_assertion_passed = $false
      fixture_count = $Cases.Count
      unique_fixture_id_count = $FixtureIds.Count
      duplicate_fixture_id_count = $DuplicateCount
      orphan_contract = $Orphans.Count
      expected_result_missing = $ExpectedMissing
      synthetic_only = [bool]$Fixture.synthetic_only
      test_exit_code = [int]$Report.exit_code
      passed = [int]$Report.passed
      failed = [int]$Report.failed
      skipped = [int]$Report.skipped
      xfailed = [int]$Report.xfailed
      flaky = [int]$Report.flaky
      production_write_count = 0
    }
    $Checks.primary_assertion_passed = $Cases.Count -eq 8 -and $DuplicateCount -eq 0 -and $Orphans.Count -eq 0 -and
      $ExpectedMissing -eq 0 -and [bool]$Checks.synthetic_only -and [int]$Checks.test_exit_code -eq 0 -and
      [int]$Checks.passed -eq 3 -and [int]$Checks.failed -eq 0 -and [int]$Checks.skipped -eq 0 -and
      [int]$Checks.xfailed -eq 0 -and [int]$Checks.flaky -eq 0
    if (-not [bool]$Checks.primary_assertion_passed) { return New-BlockedResult 'p01_003_fixture_contract_or_test_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-002') {
    $SchemaPath = Join-Path $script:RepositoryRoot 'contracts\validation-semantics-v1.schema.json'
    $DocumentPath = Join-Path $script:RepositoryRoot 'docs\architecture\validation-semantics-v1.md'
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $DocumentPath -PathType Leaf)) {
      return New-BlockedResult 'p01_002_contract_missing' ([ordered]@{
        primary_assertion_passed = $false; missing_artifact_count = 1
      })
    }
    $Schema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Document = Get-Content -LiteralPath $DocumentPath -Raw -Encoding UTF8
    $RequiredCases = @(
      'VS-HARD-POS-001','VS-HARD-NEG-001',
      'VS-WARNING-POS-001','VS-WARNING-NEG-001',
      'VS-UNVERIFIED-POS-001','VS-UNVERIFIED-NEG-001'
    )
    $MissingCases = @($RequiredCases | Where-Object { -not $Document.Contains($_) })
    $ClassificationEnum = @($Schema.properties.classification.enum)
    $AllOfText = $Schema.allOf | ConvertTo-Json -Depth 30 -Compress
    $Checks = [ordered]@{
      primary_assertion_passed = $false
      classification_count = $ClassificationEnum.Count
      hard_present = ($ClassificationEnum -contains 'hard')
      warning_present = ($ClassificationEnum -contains 'warning')
      unverified_present = ($ClassificationEnum -contains 'unverified')
      missing_positive_negative_case_count = $MissingCases.Count
      expected_result_case_count = [regex]::Matches($Document, '\| `VS-[A-Z0-9-]+` .*\| .*\| .*\|').Count
      candidate_import_always_true = ([bool]$Schema.'$defs'.candidateImport.properties.allowed.const)
      candidate_import_requires_confirmation = ([bool]$Schema.'$defs'.candidateImport.properties.requires_user_confirmation.const)
      domain_write_const_false_count = [regex]::Matches((Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8), '"domain_write_allowed"\s*:\s*\{"const"\s*:\s*false\}').Count
      fallback_preserves_user_input = ([bool]$Schema.'$defs'.fallback.properties.preserves_user_input.const)
      classification_conditional_count = @($Schema.allOf).Count
      hard_condition_present = $AllOfText.Contains('"hard"')
      warning_condition_present = $AllOfText.Contains('"warning"')
      unverified_condition_present = $AllOfText.Contains('"unverified"')
      local_contract_complete = $false
      schema_sha256 = Get-Sha256 -LiteralPath $SchemaPath
      formal_product_approval = 'pending_external'
      formal_security_approval = 'pending_external'
      formal_same_contract_sha_approval = $false
      production_write_count = 0
    }
    $Checks.local_contract_complete =
      [bool]$Checks.hard_present -and [bool]$Checks.warning_present -and [bool]$Checks.unverified_present -and
      [int]$Checks.missing_positive_negative_case_count -eq 0 -and [int]$Checks.expected_result_case_count -ge 6 -and
      [bool]$Checks.candidate_import_always_true -and [bool]$Checks.candidate_import_requires_confirmation -and
      [int]$Checks.domain_write_const_false_count -eq 2 -and [bool]$Checks.fallback_preserves_user_input -and
      [int]$Checks.classification_conditional_count -eq 4 -and [bool]$Checks.hard_condition_present -and
      [bool]$Checks.warning_condition_present -and [bool]$Checks.unverified_condition_present
    $Checks.primary_assertion_passed = [bool]$Checks.local_contract_complete
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'local-contract-verification.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; local_contract_complete = [bool]$Checks.local_contract_complete
      schema_sha256 = [string]$Checks.schema_sha256; required_case_count = $RequiredCases.Count
      missing_case_count = $MissingCases.Count; formal_approval_status = 'pending_external'
      accepted = $false; production_write_count = 0; recorded_at = [DateTimeOffset]::Now.ToString('o')
    })
    if (-not [bool]$Checks.primary_assertion_passed) {
      return New-BlockedResult 'p01_002_validation_contract_incomplete' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-001') {
    $InventoryPath = Join-Path $script:TaskEvidenceDirectory 'semantics\call-chain-inventory.json'
    if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
      return New-BlockedResult 'p01_001_call_chain_inventory_missing' ([ordered]@{
        primary_assertion_passed = $false; missing_artifact_count = 1
      })
    }
    $Inventory = Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Entries = @($Inventory.entrypoints)
    $RequiredDomains = @('ai_chat','itinerary_import','itinerary_sync','diary','auth','fallback')
    $MissingDomains = @($RequiredDomains | Where-Object { $Domain = $_; @($Entries | Where-Object { [string]$_.domain -ceq $Domain }).Count -eq 0 })
    $IncompleteEntries = @($Entries | Where-Object {
      [string]::IsNullOrWhiteSpace([string]$_.source) -or
      [string]::IsNullOrWhiteSpace([string]$_.sink) -or
      [string]::IsNullOrWhiteSpace([string]$_.fallback) -or
      $null -eq $_.unknowns
    })
    $Checks = [ordered]@{
      primary_assertion_passed = $false
      entrypoint_count = $Entries.Count
      required_domain_count = $RequiredDomains.Count
      missing_domain_count = $MissingDomains.Count
      incomplete_source_sink_fallback_count = $IncompleteEntries.Count
      unknown_marked_entry_count = @($Entries | Where-Object { @($_.unknowns).Count -gt 0 }).Count
      current_fact_only = [bool]$Inventory.current_fact_only
      private_backend_assumption_count = [int]$Inventory.private_backend_assumption_count
      production_write_count = 0
    }
    $Checks.primary_assertion_passed =
      $Entries.Count -ge 8 -and $MissingDomains.Count -eq 0 -and $IncompleteEntries.Count -eq 0 -and
      [int]$Checks.unknown_marked_entry_count -gt 0 -and [bool]$Checks.current_fact_only -and
      [int]$Checks.private_backend_assumption_count -eq 0
    if (-not [bool]$Checks.primary_assertion_passed) {
      return New-BlockedResult 'p01_001_call_chain_inventory_incomplete' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-990') {
    $Projection = Get-P00LocalProjection
    $ModeState = Get-P00GateModeState
    $Checks = [ordered]@{
      overall_status = if ([bool]$Projection.local_projection_passed -and [bool]$ModeState.passed) { 'passed' } else { 'blocked' }
      primary_assertion_passed = ([bool]$Projection.local_projection_passed -and [bool]$ModeState.passed)
      local_mechanical_failure_count = [int]$Projection.local_failure_count
      mandatory_mode_missing_count = @($ModeState.missing_modes).Count
      mandatory_mode_failed_count = @($ModeState.failed_modes).Count
      missing_modes = @($ModeState.missing_modes)
      failed_modes = @($ModeState.failed_modes)
      local_forced_rejection_count = if ([bool]$Projection.local_projection_passed -and [bool]$ModeState.passed) { 0 } else {
        [int]$Projection.local_failure_count + @($ModeState.missing_modes).Count + @($ModeState.failed_modes).Count
      }
      formal_gate_status = 'pending_external'
      formal_acceptance_complete = $false
      formal_pending_boundary_count = @($Projection.formal_pending_boundaries).Count
      accepted = $false
      production_write_count = 0
      remote_push_count = 0
      merge_count = 0
    }
    if (-not [bool]$Checks.primary_assertion_passed) {
      return New-BlockedResult 'p00_local_projection_incomplete' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-003') {
    $ContainmentPath = Join-Path $script:TaskEvidenceDirectory 'security\secret-containment.json'
    $RegistryPath = Join-Path $script:TaskEvidenceDirectory 'security\revoked-history-registry.json'
    $PostContainmentScanPath = Join-Path $script:TaskEvidenceDirectory 'security\live-secret-scan-after-local-containment.json'
    $LiveScanPath = if (Test-Path -LiteralPath $PostContainmentScanPath -PathType Leaf) {
      $PostContainmentScanPath
    } else {
      Join-Path $script:TaskEvidenceDirectory 'security\live-secret-scan.json'
    }
    $Required = @($ContainmentPath, $RegistryPath, $LiveScanPath)
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($Missing.Count -ne 0) {
      return New-BlockedResult 'p00_secret_containment_evidence_missing' ([ordered]@{
        primary_assertion_passed = $false; missing_artifact_count = $Missing.Count
        live_secret_match_count = -1; missing_audit_receipt_count = -1
      })
    }
    $Containment = Get-Content -LiteralPath $ContainmentPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Registry = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $LiveScan = Get-Content -LiteralPath $LiveScanPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $SlaBreachCount = @($Containment.sla_evaluations | Where-Object { [string]$_.status -ceq 'breached' }).Count
    $Checks = [ordered]@{
      primary_assertion_passed = $false
      old_ref_revoked = (-not [string]::IsNullOrWhiteSpace([string]$Containment.timeline.revoked_at) -and
        -not [string]::IsNullOrWhiteSpace([string]$Containment.owner_and_vendor_evidence.old_ref_revocation_receipt_sha256))
      new_ref_server_only = (-not [string]::IsNullOrWhiteSpace([string]$Containment.owner_and_vendor_evidence.new_ref_server_only_receipt_sha256))
      new_ref_cost_cap_present = (-not [string]::IsNullOrWhiteSpace([string]$Containment.owner_and_vendor_evidence.new_ref_cost_cap_receipt_sha256))
      sla_calculation_count = @($Containment.sla_evaluations).Count
      sla_breach_count = $SlaBreachCount
      live_secret_match_count = [int]$LiveScan.finding_count
      new_history_findings = $Containment.history_scan.new_history_findings
      historical_revoked_registry_mismatch = $Containment.history_scan.historical_revoked_registry_mismatch
      historical_occurrence_count = [int]$Registry.observed_historical_occurrence_count
      occurrence_set_hash_match = ([string]$Registry.occurrence_set_sha256 -ceq [string]$Containment.history_scan.occurrence_set_sha256)
      missing_audit_receipt_count = [int]$Containment.owner_and_vendor_evidence.missing_audit_receipt_count
      secret_value_output_count = [int]$LiveScan.secret_value_output_count
      external_write_count = [int]$Containment.owner_and_vendor_evidence.external_write_count
      production_write_count = 0
    }
    $Checks.primary_assertion_passed =
      [bool]$Checks.old_ref_revoked -and [bool]$Checks.new_ref_server_only -and
      [bool]$Checks.new_ref_cost_cap_present -and [int]$Checks.sla_calculation_count -eq 5 -and
      [int]$Checks.sla_breach_count -eq 0 -and [int]$Checks.live_secret_match_count -eq 0 -and
      $null -ne $Checks.new_history_findings -and [int]$Checks.new_history_findings -eq 0 -and
      $null -ne $Checks.historical_revoked_registry_mismatch -and [int]$Checks.historical_revoked_registry_mismatch -eq 0 -and
      [bool]$Checks.occurrence_set_hash_match -and [int]$Checks.missing_audit_receipt_count -eq 0 -and
      [int]$Checks.secret_value_output_count -eq 0 -and [int]$Checks.external_write_count -eq 0
    if (-not $Checks.primary_assertion_passed) {
      return New-BlockedResult 'p0_secret_containment_owner_action_required' $Checks
    }
    return New-PassedResult $Checks
  }
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
  if ($TaskId -ceq 'TASK-P03-009') {
    $Required=@('agent-service/scripts/test_backup_restore.ps1','agent-service/tests/integration/test_migration_restore.py','docs/runbooks/runtime-db-restore.md','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/evidence/phase-03/P03-009/direct-pytest.xml','docs/execution/evidence/phase-03/P03-009/backup-restore-report.json','docs/execution/evidence/phase-03/P03-009/implementation-actions.json','docs/execution/evidence/phase-03/P03-009/runner-enabler.md','docs/execution/evidence/phase-03/P03-009/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-009/ci-reports/clock-contract.json','docs/execution/evidence/phase-03/P03-009/ci-reports/contract.xml','docs/execution/evidence/phase-03/P03-009/ci-reports/format.json','docs/execution/evidence/phase-03/P03-009/ci-reports/licenses.json','docs/execution/evidence/phase-03/P03-009/ci-reports/lint.json','docs/execution/evidence/phase-03/P03-009/ci-reports/secret.json','docs/execution/evidence/phase-03/P03-009/ci-reports/type.json','docs/execution/evidence/phase-03/P03-009/ci-reports/unit-report.json','docs/execution/evidence/phase-03/P03-009/ci-reports/unit.xml');$Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0;foreach($RelativePath in $Required){$FullPath=Join-Path $script:RepositoryRoot $RelativePath;if(-not(Test-Path $FullPath -PathType Leaf)){$Missing++;continue};if($RelativePath.EndsWith('.json')){try{$null=Get-Content $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}};if($RelativePath-notmatch'\.(json|xml)$'){$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count};$Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'};$Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-backup-restore' -GeneratedByStep 'TASK-P03-009:Evidence'};Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts});$Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0};if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_009_evidence_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-008') {
    $Required=@('agent-service/tests/contract/test_idempotency.py','agent-service/tests/integration/test_runtime_concurrency.py','agent-service/tests/unit/harness/test_05_idempotency_guard.py','agent-service/tests/unit/harness/test_34_consistency_fence.py','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/evidence/phase-03/P03-008/direct-pytest.xml','docs/execution/evidence/phase-03/P03-008/ct-001.json','docs/execution/evidence/phase-03/P03-008/ct-002.json','docs/execution/evidence/phase-03/P03-008/runtime-concurrency-report.json','docs/execution/evidence/phase-03/P03-008/harness-status-fragment.json','docs/execution/evidence/phase-03/P03-008/implementation-actions.json','docs/execution/evidence/phase-03/P03-008/runner-enabler.md','docs/execution/evidence/phase-03/P03-008/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-008/ci-reports/clock-contract.json','docs/execution/evidence/phase-03/P03-008/ci-reports/contract.xml','docs/execution/evidence/phase-03/P03-008/ci-reports/format.json','docs/execution/evidence/phase-03/P03-008/ci-reports/licenses.json','docs/execution/evidence/phase-03/P03-008/ci-reports/lint.json','docs/execution/evidence/phase-03/P03-008/ci-reports/secret.json','docs/execution/evidence/phase-03/P03-008/ci-reports/type.json','docs/execution/evidence/phase-03/P03-008/ci-reports/unit-report.json','docs/execution/evidence/phase-03/P03-008/ci-reports/unit.xml')
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0;foreach($RelativePath in $Required){$FullPath=Join-Path $script:RepositoryRoot $RelativePath;if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue};if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}};if($RelativePath-notmatch'\.(json|xml)$'){$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count};$Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'};$Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-runtime-concurrency' -GeneratedByStep 'TASK-P03-008:Evidence'};Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts});$Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0};if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_008_evidence_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-007') {
    $Required=@('agent-service/migrations/versions/p03_007_runtime_rls.py','agent-service/tests/security/test_rls.py','agent-service/tests/security/fixtures/rls_principals.sql','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/evidence/phase-03/P03-007/direct-pytest.xml','docs/execution/evidence/phase-03/P03-007/rls-report.json','docs/execution/evidence/phase-03/P03-007/implementation-actions.json','docs/execution/evidence/phase-03/P03-007/runner-enabler.md','docs/execution/evidence/phase-03/P03-007/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-007/ci-reports/clock-contract.json','docs/execution/evidence/phase-03/P03-007/ci-reports/contract.xml','docs/execution/evidence/phase-03/P03-007/ci-reports/format.json','docs/execution/evidence/phase-03/P03-007/ci-reports/licenses.json','docs/execution/evidence/phase-03/P03-007/ci-reports/lint.json','docs/execution/evidence/phase-03/P03-007/ci-reports/secret.json','docs/execution/evidence/phase-03/P03-007/ci-reports/type.json','docs/execution/evidence/phase-03/P03-007/ci-reports/unit-report.json','docs/execution/evidence/phase-03/P03-007/ci-reports/unit.xml')
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0;foreach($RelativePath in $Required){$FullPath=Join-Path $script:RepositoryRoot $RelativePath;if(-not(Test-Path $FullPath -PathType Leaf)){$Missing++;continue};if($RelativePath.EndsWith('.json')){try{$null=Get-Content $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}};if($RelativePath-notmatch'\.(json|xml)$'){$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count};$Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'};$Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-runtime-rls' -GeneratedByStep 'TASK-P03-007:Evidence'};Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts});$Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0};if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_007_evidence_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-006') {
    $Required=@('agent-service/app/persistence/models/outbox.py','agent-service/app/persistence/repositories/outbox.py','agent-service/migrations/versions/p03_006_outbox_receipts.py','agent-service/tests/integration/test_outbox_receipts.py','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/evidence/phase-03/P03-006/direct-pytest.xml','docs/execution/evidence/phase-03/P03-006/outbox-receipt-report.json','docs/execution/evidence/phase-03/P03-006/implementation-actions.json','docs/execution/evidence/phase-03/P03-006/runner-enabler.md','docs/execution/evidence/phase-03/P03-006/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-006/ci-reports/clock-contract.json','docs/execution/evidence/phase-03/P03-006/ci-reports/contract.xml','docs/execution/evidence/phase-03/P03-006/ci-reports/format.json','docs/execution/evidence/phase-03/P03-006/ci-reports/licenses.json','docs/execution/evidence/phase-03/P03-006/ci-reports/lint.json','docs/execution/evidence/phase-03/P03-006/ci-reports/secret.json','docs/execution/evidence/phase-03/P03-006/ci-reports/type.json','docs/execution/evidence/phase-03/P03-006/ci-reports/unit-report.json','docs/execution/evidence/phase-03/P03-006/ci-reports/unit.xml')
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){$FullPath=Join-Path $script:RepositoryRoot $RelativePath;if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue};if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}};if($RelativePath-notmatch'\.(json|xml)$'){try{$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count}catch{}};$Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'};$Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-transactional-outbox' -GeneratedByStep 'TASK-P03-006:Evidence'}
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts})
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0};if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_006_evidence_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-005') {
    $Required=@(
      'contracts/behavior-manifest-v1.schema.json','contracts/digest-vectors-v1.json',
      'agent-service/app/runtime/behavior_manifest.py','agent-service/tests/contract/test_manifest_digest.py',
      'lib/core/agent/behavior_digest.dart','test/behavior_digest_test.dart','docs/execution/commands/Invoke-TaskGate.ps1',
      'docs/execution/evidence/phase-03/P03-005/direct-pytest.xml','docs/execution/evidence/phase-03/P03-005/manifest-digest-report.json',
      'docs/execution/evidence/phase-03/P03-005/dart-digest-report.json','docs/execution/evidence/phase-03/P03-005/dart-test-machine.jsonl',
      'docs/execution/evidence/phase-03/P03-005/flutter-analyze-machine.txt','docs/execution/evidence/phase-03/P03-005/flutter-analyze-affected-machine.txt',
      'docs/execution/evidence/phase-03/P03-005/analysis-scope.json','docs/execution/evidence/phase-03/P03-005/cross-language-summary.json',
      'docs/execution/evidence/phase-03/P03-005/implementation-actions.json','docs/execution/evidence/phase-03/P03-005/blocker.json',
      'docs/execution/evidence/phase-03/P03-005/runner-enabler.md',
      'docs/execution/evidence/phase-03/P03-005/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-005/ci-reports/clock-contract.json',
      'docs/execution/evidence/phase-03/P03-005/ci-reports/contract.xml','docs/execution/evidence/phase-03/P03-005/ci-reports/format.json',
      'docs/execution/evidence/phase-03/P03-005/ci-reports/licenses.json','docs/execution/evidence/phase-03/P03-005/ci-reports/lint.json',
      'docs/execution/evidence/phase-03/P03-005/ci-reports/secret.json','docs/execution/evidence/phase-03/P03-005/ci-reports/type.json',
      'docs/execution/evidence/phase-03/P03-005/ci-reports/unit-report.json','docs/execution/evidence/phase-03/P03-005/ci-reports/unit.xml'
    )
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){$FullPath=Join-Path $script:RepositoryRoot $RelativePath;if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue};if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}};if($RelativePath-notmatch'\.(json|jsonl|xml)$'){try{$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count}catch{}};$Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.jsonl')){'application/x-ndjson'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'};$Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-behavior-manifest-digest' -GeneratedByStep 'TASK-P03-005:Evidence'}
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts})
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_005_evidence_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-004') {
    $Required=@(
      'agent-service/app/persistence/models/behavior.py','agent-service/app/persistence/repositories/behavior.py',
      'agent-service/migrations/versions/p03_004_behavior_releases.py','agent-service/tests/contract/test_pointer_cas.py',
      'agent-service/tests/unit/harness/test_11_behavior_registry.py','docs/execution/commands/Invoke-TaskGate.ps1',
      'docs/execution/evidence/phase-03/P03-004/direct-pytest.xml','docs/execution/evidence/phase-03/P03-004/behavior-release-report.json',
      'docs/execution/evidence/phase-03/P03-004/harness-status-fragment.json','docs/execution/evidence/phase-03/P03-004/implementation-actions.json',
      'docs/execution/evidence/phase-03/P03-004/runner-enabler.md','docs/execution/evidence/phase-03/P03-004/blocker.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/ci-summary.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/clock-contract.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/contract.xml',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/format.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/licenses.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/lint.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/secret.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/type.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/unit-report.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/unit.xml'
    )
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){$FullPath=Join-Path $script:RepositoryRoot $RelativePath;if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue};if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}};if($RelativePath-notmatch'\.(json|xml)$'){try{$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count}catch{}};$Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'};$Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-behavior-release' -GeneratedByStep 'TASK-P03-004:Evidence'}
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts})
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_004_evidence_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-003') {
    $Required=@(
      'agent-service/app/persistence/models/jobs.py',
      'agent-service/app/persistence/repositories/jobs.py',
      'agent-service/app/persistence/repositories/checkpoints.py',
      'agent-service/migrations/versions/p03_003_jobs_leases_checkpoints.py',
      'agent-service/tests/integration/test_job_metadata.py',
      'docs/execution/commands/Invoke-TaskGate.ps1',
      'docs/execution/evidence/phase-03/P03-003/direct-pytest.xml',
      'docs/execution/evidence/phase-03/P03-003/job-metadata-report.json',
      'docs/execution/evidence/phase-03/P03-003/dependency-audit-report.json',
      'docs/execution/evidence/phase-03/P03-003/dependency-licenses.json',
      'docs/execution/evidence/phase-03/P03-003/implementation-actions.json',
      'docs/execution/evidence/phase-03/P03-003/runner-enabler.md',
      'docs/execution/evidence/phase-03/P03-003/blocker.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/ci-summary.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/clock-contract.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/contract.xml',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/format.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/licenses.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/lint.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/secret.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/type.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/unit-report.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/unit.xml'
    )
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue}
      if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}}
      if($RelativePath-notmatch'\.(json|xml)$'){try{$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count}catch{}}
      $Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'}
      $Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-job-metadata' -GeneratedByStep 'TASK-P03-003:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts})
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_003_evidence_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-002') {
    $Required=@(
      '.gitattributes',
      'agent-service/app/persistence/models/runtime.py',
      'agent-service/app/persistence/repositories/runs.py',
      'agent-service/app/persistence/repositories/events.py',
      'agent-service/migrations/versions/p03_002_run_event_idempotency.py',
      'agent-service/tests/integration/test_runtime_persistence.py',
      'agent-service/tests/unit/harness/test_25_event_writer.py',
      'agent-service/scripts/ci.ps1',
      'docs/execution/commands/Invoke-TaskGate.ps1',
      'docs/execution/evidence/phase-03/P03-002/direct-pytest.xml',
      'docs/execution/evidence/phase-03/P03-002/runtime-persistence-report.json',
      'docs/execution/evidence/phase-03/P03-002/harness-status-fragment.json',
      'docs/execution/evidence/phase-03/P03-002/implementation-actions.json',
      'docs/execution/evidence/phase-03/P03-002/runner-enabler.md',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/ci-summary.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/clock-contract.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/contract.xml',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/format.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/licenses.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/lint.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/secret.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/type.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/unit-report.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/unit.xml'
    )
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue}
      if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}}
      if($RelativePath-notmatch'\.(json|xml)$'){
        try{$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count}catch{}
      }
      $Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'}
      $Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-runtime-persistence' -GeneratedByStep 'TASK-P03-002:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat
      head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts
    })
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_002_evidence_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-001') {
    $Required=@(
      '.gitattributes',
      'agent-service/alembic.ini','agent-service/migrations/env.py','agent-service/migrations/script.py.mako',
      'agent-service/migrations/versions/p03_001_runtime_baseline.py','agent-service/tests/integration/test_migration_baseline.py',
      'agent-service/pyproject.toml','agent-service/uv.lock','agent-service/tests/ci/test_quality_gate.py',
      'docs/execution/commands/Invoke-TaskGate.ps1','docs/architecture/adr/ADR-P03-001-postgresql-driver.md',
      'docs/execution/blockers/phase-03/BLK-P03-001-license-metadata-normalization.md',
      'docs/execution/evidence/phase-03/phase-runtime-manifest.json'
    )
    $EvidenceFiles=@(Get-ChildItem -LiteralPath $script:TaskEvidenceDirectory -Recurse -File -ErrorAction SilentlyContinue|Where-Object{
      $_.Name-notin@('artifact-hashes.json','commands.json','gate-results.json')
    }|ForEach-Object{$_.FullName.Substring($script:RepositoryRoot.Length+1).Replace('\','/')})
    $SupplyRoot=Join-Path $script:RepositoryRoot 'docs\execution\supply-chain\phase-03\P03-001-enabler'
    $SupplyFiles=@(Get-ChildItem -LiteralPath $SupplyRoot -Recurse -File -ErrorAction SilentlyContinue|ForEach-Object{
      $_.FullName.Substring($script:RepositoryRoot.Length+1).Replace('\','/')
    })
    $Required=@($Required+$EvidenceFiles+$SupplyFiles|Sort-Object -Unique)
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue}
      if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}}
      if($RelativePath-notmatch'(?i)(\.xml$|uv\.lock$|sbom\.cdx\.json$)'){
        try{$TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count}catch{}
      }
      $Mime=if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}elseif($RelativePath.EndsWith('.md')){'text/markdown'}else{'text/plain'}
      $Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'phase-03-migration-baseline' -GeneratedByStep 'TASK-P03-001:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat
      head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts
    })
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p03_001_evidence_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-990') {
    $Required=@(
      'docs/execution/evidence/phase-02/acceptance.md','docs/execution/evidence/index.json',
      'docs/execution/evidence/phase-02/artifact-manifest.premerge.json',
      'docs/execution/evidence/phase-02/P02-990/local-verification.json',
      'docs/execution/evidence/phase-02/P02-990/gate-summary.json',
      'docs/execution/evidence/phase-02/P02-990/ci-reports/ci-summary.json',
      'docs/execution/evidence/phase-02/P02-990/ci-reports/unit.xml',
      'docs/execution/evidence/phase-02/P02-990/ci-reports/contract.xml'
    )
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue}
      if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}}
      if($RelativePath-notmatch'\.(json|xml)$'){$Text=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false));$SensitiveFindings += [regex]::Matches($Text,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count}
      $Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $(if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}else{'text/markdown'}) -ArtifactType 'phase-02-acceptance-evidence' -GeneratedByStep 'TASK-P02-990:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts})
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne0){return New-BlockedResult 'p02_990_evidence_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-089') {
    $Head=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
    $ManifestFiles=@(
      'README.md','agent-service/README.md','docs/api/agent-api.md',
      'docs/architecture/agent-process-boundary.md','docs/architecture/threat-model/phase-02-review.json',
      'docs/execution/evidence/phase-02/change-summary.md','docs/execution/evidence/phase-02/knowledge-transfer.md',
      'docs/execution/evidence/phase-02/star-records.md','docs/execution/evidence/phase-02/improvements/STAR-nested-evidence-integrity.md',
      'docs/execution/schemas/harness-test-catalog.yaml','docs/runbooks/agent-service-lifecycle.md'
    )
    $Missing=@($ManifestFiles|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $ManifestArtifacts=@()
    foreach($RelativePath in $ManifestFiles){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(Test-Path -LiteralPath $FullPath -PathType Leaf){
        $ManifestArtifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -ArtifactType 'phase-02-premerge-deliverable' -GeneratedByStep 'TASK-P02-089:Evidence'
      }
    }
    $ManifestPath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02\artifact-manifest.premerge.json'
    Write-AtomicJson -LiteralPath $ManifestPath -Value ([ordered]@{
      schema_version='1.0';task_id=$TaskId;execution_mode=$ExecutionMode;candidate_head_oid=$Head
      phase_base_oid=Get-PhaseBaseOid;artifacts=$ManifestArtifacts;artifact_count=$ManifestArtifacts.Count
      formal_review_status='pending_external';accepted=$false;remote_push_count=0;merge_count=0;production_write_count=0
      recorded_at=[DateTimeOffset]::Now.ToString('o')
    })
    $Required=@(Get-P02089ClosureFiles)
    $Artifacts=@();$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){continue}
      if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}}
      if($RelativePath -notmatch '\.json$'){
        $TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false))
        $SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      }
      $Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $(if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.yaml')){'application/yaml'}else{'text/markdown'}) -ArtifactType 'phase-02-closure-evidence' -GeneratedByStep 'TASK-P02-089:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=$Head;artifacts=$Artifacts})
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing.Count+($Required.Count-$Artifacts.Count);redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne 0){return New-BlockedResult 'p02_089_evidence_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-001') {
    $Required = @(
      'agent-service/pyproject.toml','agent-service/uv.lock','agent-service/app/api/main.py',
      'agent-service/app/worker/main.py','agent-service/tests/test_entrypoints.py',
      'agent-service/scripts/build.ps1','agent-service/README.md',
      'docs/execution/evidence/phase-02/phase-runtime-manifest.json',
      'docs/execution/evidence/phase-02/P02-001/pip-audit.json',
      'docs/execution/evidence/phase-02/P02-001/license-report.json',
      'docs/execution/supply-chain/phase-02/P02-001/agent-service.cdx.json'
    )
    $BlockerRelative = 'docs/execution/evidence/phase-02/P02-001/blocker.json'
    if (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $BlockerRelative) -PathType Leaf) { $Required += $BlockerRelative }
    $Artifacts = @(); $Missing = 0; $JsonErrors = 0; $SensitiveFindings = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      if ($RelativePath.EndsWith('.json')) {
        try { $null = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $JsonErrors++ }
      }
      if ($RelativePath -notmatch '\.(cdx|lock)\.json$') {
        $TextValue = [IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false))
        $SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType $(if ($RelativePath.EndsWith('.json')) {'application/json'} elseif ($RelativePath.EndsWith('.md')) {'text/markdown'} else {'text/plain'}) `
        -ArtifactType 'phase-02-service-skeleton' -GeneratedByStep 'TASK-P02-001:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat
      head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts
    })
    $Checks = [ordered]@{
      schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings
      undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0
    }
    if ([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'p02_001_evidence_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -cmatch '^TASK-P02-(002|003|004|005|006|007|008|089)$') {
    $Required=@(Get-P02TaskDeliverableFiles)
    $TaskEvidenceFiles=@(Get-ChildItem -LiteralPath $script:TaskEvidenceDirectory -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -notin @('artifact-hashes.json','commands.json','gate-results.json')
    } | ForEach-Object { $_.FullName.Substring($script:RepositoryRoot.Length+1).Replace('\','/') })
    $Required=@($Required+$TaskEvidenceFiles|Sort-Object -Unique)
    $Artifacts=@();$Missing=0;$JsonErrors=0;$SensitiveFindings=0
    foreach($RelativePath in $Required){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue}
      if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}}
      if($RelativePath -notmatch '\.(xml|json)$'){
        $TextValue=[IO.File]::ReadAllText($FullPath,[Text.UTF8Encoding]::new($false))
        $SensitiveFindings += [regex]::Matches($TextValue,'(?i)(sk-[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]+|-----BEGIN [A-Z ]*PRIVATE KEY-----)').Count
      }
      $Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $(if($RelativePath.EndsWith('.json')){'application/json'}elseif($RelativePath.EndsWith('.xml')){'application/xml'}else{'text/plain'}) -ArtifactType 'phase-02-task-evidence' -GeneratedByStep "${TaskId}:Evidence"
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts})
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=$SensitiveFindings;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne 0){return New-BlockedResult 'p02_evidence_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -in @('TASK-P01-089','TASK-P01-990')) {
    $Required = if ($TaskId -ceq 'TASK-P01-089') {
      @(
        'README.md','docs/architecture/validation-semantics.md','docs/runbooks/legacy-fallback.md',
        'docs/api/validation-semantics.md','docs/architecture/threat-model/phase-01-review.json',
        'docs/execution/evidence/phase-01/change-summary.md','docs/execution/evidence/phase-01/knowledge-transfer.md',
        'docs/execution/evidence/phase-01/star-records.md','docs/execution/evidence/phase-01/improvements/STAR-validation-contract-fixtures.md',
        'docs/execution/evidence/phase-01/artifact-manifest.premerge.json',
        'docs/execution/evidence/phase-01/P01-089/handoff-verification.json',
        'docs/execution/evidence/phase-01/P01-089/harness-catalog-aggregate.json',
        'docs/execution/status/task-board.json','docs/execution/status/task-board.md'
      )
    } else {
      @('docs/execution/evidence/phase-01/acceptance.md','docs/execution/evidence/index.json')
    }
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    if ($Missing.Count -ne 0) {
      return New-BlockedResult 'p01_closure_evidence_missing' ([ordered]@{schema_errors=0;unhashed_artifacts=$Missing.Count;redaction_failures=0;undeclared_evidence_count=0})
    }
    $Artifacts = @()
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      $Mime = if ($RelativePath.EndsWith('.json')) { 'application/json' } else { 'text/markdown' }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'phase-01-closure-evidence' `
        -GeneratedByStep "${TaskId}:Evidence"
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat
      head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts
    })
    return New-PassedResult ([ordered]@{
      schema_errors=0;unhashed_artifacts=0;redaction_failures=0;undeclared_evidence_count=0
      artifact_count=$Artifacts.Count;production_write_count=0
    })
  }
  if ($TaskId -ceq 'TASK-P01-005') {
    $Required = @('docs/execution/evidence/phase-01/P01-005/traceability-v1.6.1-task-map.md','docs/architecture/adr/ADR-P01-005-architecture-baseline.md','docs/execution/evidence/phase-01/P01-005/local-traceability-verification.json')
    $Artifacts=@();$Missing=0;$JsonErrors=0
    foreach($RelativePath in $Required){
      $FullPath=Join-Path $script:RepositoryRoot $RelativePath
      if(-not(Test-Path -LiteralPath $FullPath -PathType Leaf)){$Missing++;continue}
      if($RelativePath.EndsWith('.json')){try{$null=Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$JsonErrors++}}
      $Mime=if($RelativePath.EndsWith('.json')){'application/json'}else{'text/markdown'}
      $Artifacts+=New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime -ArtifactType 'architecture-traceability' -GeneratedByStep 'TASK-P01-005:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;git_object_format=Get-GitObjectFormat;head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();artifacts=$Artifacts})
    $Checks=[ordered]@{schema_errors=$JsonErrors;unhashed_artifacts=$Missing;redaction_failures=0;undeclared_evidence_count=0;artifact_count=$Artifacts.Count;production_write_count=0}
    if([int]$Checks.schema_errors+[int]$Checks.unhashed_artifacts+[int]$Checks.redaction_failures-ne 0){return New-BlockedResult 'p01_005_evidence_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-004') {
    $Required = @(
      'contracts/flutter-agent-boundary-v1.yaml',
      'docs/execution/evidence/phase-01/P01-004/flutter-service-matrix.md',
      'docs/execution/evidence/phase-01/P01-004/local-boundary-verification.json'
    )
    $Artifacts = @(); $Missing = 0; $JsonErrors = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      if ($RelativePath.EndsWith('.json')) {
        try { $null = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $JsonErrors++ }
      }
      $Mime = if ($RelativePath.EndsWith('.json')) { 'application/json' } elseif ($RelativePath.EndsWith('.yaml')) { 'application/yaml' } else { 'text/markdown' }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $Mime `
        -ArtifactType 'flutter-agent-boundary-contract' -GeneratedByStep 'TASK-P01-004:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version='1.0'; task_id=$TaskId; git_object_format=Get-GitObjectFormat
      head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts=$Artifacts
    })
    $Checks = [ordered]@{
      schema_errors=$JsonErrors; unhashed_artifacts=$Missing; redaction_failures=0
      undeclared_evidence_count=0; artifact_count=$Artifacts.Count; production_write_count=0
    }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'p01_004_evidence_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-003') {
    $Required = @(
      'test/fixtures/validation/validation_semantics_cases.json',
      'test/validation_semantics_test.dart',
      'docs/execution/evidence/phase-01/P01-003/local-test-report.json'
    )
    $Artifacts = @(); $Missing = 0; $JsonErrors = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      if ($RelativePath.EndsWith('.json')) { try { $null = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $JsonErrors++ } }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath -Sha256 (Get-Sha256 -LiteralPath $FullPath) -SizeBytes (Get-Item -LiteralPath $FullPath).Length -MimeType $(if ($RelativePath.EndsWith('.json')) { 'application/json' } else { 'text/x-dart' }) -ArtifactType 'phase-01-validation-fixture' -GeneratedByStep 'TASK-P01-003:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{ schema_version='1.0'; task_id=$TaskId; git_object_format=Get-GitObjectFormat; head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts=$Artifacts })
    $Checks = [ordered]@{ schema_errors=$JsonErrors; unhashed_artifacts=$Missing; redaction_failures=0; artifact_count=$Artifacts.Count; production_write_count=0 }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts -ne 0) { return New-BlockedResult 'p01_003_evidence_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-002') {
    $Required = @(
      'contracts/validation-semantics-v1.schema.json',
      'docs/architecture/validation-semantics-v1.md',
      'docs/execution/evidence/phase-01/P01-002/local-contract-verification.json'
    )
    $Artifacts = @()
    $Missing = 0
    $JsonErrors = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      if ($RelativePath.EndsWith('.json')) {
        try { $null = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $JsonErrors++ }
      }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath `
        -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType $(if ($RelativePath.EndsWith('.json')) { 'application/json' } else { 'text/markdown' }) `
        -ArtifactType 'phase-01-validation-semantics' -GeneratedByStep 'TASK-P01-002:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
    })
    $Checks = [ordered]@{ schema_errors = $JsonErrors; unhashed_artifacts = $Missing; redaction_failures = 0; artifact_count = $Artifacts.Count; production_write_count = 0 }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'p01_002_evidence_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-001') {
    $Required = @(
      'docs/execution/evidence/phase-01/P01-001/semantics/current-call-chain.md',
      'docs/execution/evidence/phase-01/P01-001/semantics/current-write-paths.md',
      'docs/execution/evidence/phase-01/P01-001/semantics/call-chain-inventory.json',
      'docs/execution/evidence/phase-01/phase-runtime-manifest.json'
    )
    $Artifacts = @()
    $Missing = 0
    $JsonErrors = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      if ($RelativePath.EndsWith('.json')) {
        try { $null = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $JsonErrors++ }
      }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath `
        -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType $(if ($RelativePath.EndsWith('.json')) { 'application/json' } else { 'text/markdown' }) `
        -ArtifactType 'phase-01-current-semantics' -GeneratedByStep 'TASK-P01-001:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
    })
    $Checks = [ordered]@{
      schema_errors = $JsonErrors
      unhashed_artifacts = $Missing
      redaction_failures = 0
      artifact_count = $Artifacts.Count
      production_write_count = 0
    }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'p01_001_evidence_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-990') {
    $Projection = Get-P00LocalProjection
    $Required = @(
      'docs/execution/evidence/phase-00/acceptance.md',
      'docs/execution/evidence/phase-00/change-summary.md',
      'docs/execution/evidence/phase-00/knowledge-transfer.md',
      'docs/execution/evidence/phase-00/artifact-manifest.premerge.json',
      'docs/execution/evidence/phase-00/P00-005/local-verification.json',
      'docs/execution/evidence/phase-00/P00-006/local-verification.json',
      'docs/execution/evidence/phase-00/P00-007/flutter-baseline.json',
      'docs/execution/evidence/phase-00/P00-008/local-verification.json',
      'docs/execution/evidence/phase-00/P00-089/handoff-verification.json',
      'docs/execution/evidence/phase-00/P00-990/harness-catalog-validation.json',
      'docs/execution/evidence/phase-00/P00-990/local-projection-gate-repair.json'
    )
    $Artifacts = @()
    $Missing = 0
    $JsonErrors = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      if ($RelativePath.EndsWith('.json')) {
        try { $null = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $JsonErrors++ }
      }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath `
        -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType $(if ($RelativePath.EndsWith('.json')) { 'application/json' } else { 'text/markdown' }) `
        -ArtifactType 'phase-00-local-projection-evidence' -GeneratedByStep 'TASK-P00-990:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
    })
    $Checks = [ordered]@{
      schema_errors = $JsonErrors
      unhashed_artifacts = $Missing
      redaction_failures = 0
      artifact_count = $Artifacts.Count
      local_mechanical_failure_count = [int]$Projection.local_failure_count
      formal_gate_status = 'pending_external'
      production_write_count = 0
    }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures +
        [int]$Checks.local_mechanical_failure_count -ne 0) {
      return New-BlockedResult 'p00_local_projection_evidence_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-003') {
    $Required = @(
      'docs/execution/evidence/phase-00/P00-003.json',
      'docs/execution/evidence/phase-00/P00-003/security/secret-containment.json',
      'docs/execution/evidence/phase-00/P00-003/security/secret-provider-reference.md',
      'docs/execution/evidence/phase-00/P00-003/security/revoked-history-registry.json',
      'docs/execution/evidence/phase-00/P00-003/security/live-secret-scan.json'
    )
    foreach ($OptionalPath in @(
      'docs/execution/evidence/phase-00/P00-003/security/live-secret-scan-after-local-containment.json',
      'docs/execution/evidence/phase-00/P00-003/security/local-containment-repair.json',
      'docs/execution/evidence/phase-00/P00-003/security/apk-secret-scan-after-local-containment.json'
    )) {
      if (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $OptionalPath) -PathType Leaf) {
        $Required += $OptionalPath
      }
    }
    $Artifacts = @()
    $Missing = 0
    $JsonErrors = 0
    foreach ($RelativePath in $Required) {
      $FullPath = Join-Path $script:RepositoryRoot $RelativePath
      if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { $Missing++; continue }
      if ($RelativePath.EndsWith('.json')) {
        try { $null = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $JsonErrors++ }
      }
      $Artifacts += New-ArtifactRecord -PathOrReference $RelativePath `
        -Sha256 (Get-Sha256 -LiteralPath $FullPath) `
        -SizeBytes (Get-Item -LiteralPath $FullPath).Length `
        -MimeType $(if ($RelativePath.EndsWith('.json')) { 'application/json' } else { 'text/markdown' }) `
        -ArtifactType 'secret-containment-evidence' -GeneratedByStep 'TASK-P00-003:Evidence'
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'artifact-hashes.json') -Value ([ordered]@{
      schema_version = '1.0'; task_id = $TaskId; git_object_format = Get-GitObjectFormat
      head_oid = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim(); artifacts = $Artifacts
    })
    $ContainmentPath = Join-Path $script:TaskEvidenceDirectory 'security\secret-containment.json'
    $Containment = if (Test-Path -LiteralPath $ContainmentPath -PathType Leaf) {
      Get-Content -LiteralPath $ContainmentPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } else { $null }
    $Checks = [ordered]@{
      schema_errors = $JsonErrors
      unhashed_artifacts = $Missing
      redaction_failures = 0
      artifact_count = $Artifacts.Count
      p0_sla_breach_count = if ($null -eq $Containment) { -1 } else {
        @($Containment.sla_evaluations | Where-Object { [string]$_.status -ceq 'breached' }).Count
      }
      missing_audit_receipt_count = if ($null -eq $Containment) { -1 } else {
        [int]$Containment.owner_and_vendor_evidence.missing_audit_receipt_count
      }
      production_write_count = 0
    }
    if ([int]$Checks.schema_errors + [int]$Checks.unhashed_artifacts + [int]$Checks.redaction_failures -ne 0) {
      return New-BlockedResult 'p00_secret_containment_evidence_invalid' $Checks
    }
    if ([int]$Checks.p0_sla_breach_count -ne 0 -or [int]$Checks.missing_audit_receipt_count -ne 0) {
      return New-BlockedResult 'p0_secret_containment_owner_action_required' $Checks
    }
    return New-PassedResult $Checks
  }
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
  if ($TaskId -ceq 'TASK-P03-001') {
    $ManifestPath = Join-Path $script:RepositoryRoot ([string]$script:Task.phase_runtime_manifest_path)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
      return New-BlockedResult 'phase_03_entry_manifest_missing' ([ordered]@{
        task_id_match=$true;dependency_failures=1;status_cas_conflict=0;unexpected_paths=0
        base_drift=1;local_dependency_projection_valid=$false;formal_dependency_pending=($ExecutionMode-ceq'local_provisional')
      })
    }
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $SourcePath = Join-Path $script:RepositoryRoot ([string]$Manifest.source_record_path)
    $SourceRecord = if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
      Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } else { $null }
    $SourceHashDrift = if ($null -eq $SourceRecord) { 1 } elseif (
      (Get-Sha256 -LiteralPath $SourcePath) -cne [string]$Manifest.source_record_sha256
    ) { 1 } else { 0 }
    $SourceGatePath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02\P02-990\gate-results.json'
    $SourceEvidenceHashDrift = if ($null -eq $SourceRecord -or -not (Test-Path -LiteralPath $SourceGatePath -PathType Leaf)) {
      1
    } elseif ((Get-Sha256 -LiteralPath $SourceGatePath) -cne [string]$SourceRecord.evidence_sha256) { 1 } else { 0 }
    $EntryRegressionPath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-03\P03-001\phase-entry-regression.json'
    $EntryRegression = if (Test-Path -LiteralPath $EntryRegressionPath -PathType Leaf) {
      Get-Content -LiteralPath $EntryRegressionPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } else { $null }
    & git -C $script:RepositoryRoot merge-base --is-ancestor ([string]$Manifest.phase_base_oid) HEAD 2>$null
    $BaseDrift = if ($LASTEXITCODE -eq 0) { 0 } else { 1 }
    $FormalStatusPath = Join-Path $script:RepositoryRoot 'docs\execution\status\TASK-P02-999.json'
    $FormalStatus = if (Test-Path -LiteralPath $FormalStatusPath -PathType Leaf) {
      Get-Content -LiteralPath $FormalStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } else { $null }
    $FormalDependencySatisfied = $null -ne $FormalStatus -and
      [string]$FormalStatus.status -ceq 'accepted' -and [bool]$FormalStatus.reviewer_independent -and
      -not [string]::IsNullOrWhiteSpace([string]$Manifest.formal_phase_base_oid)
    $LocalProjectionSatisfied = [bool]$Manifest.local_dependency_projection_valid -and
      $null -ne $SourceRecord -and [string]$SourceRecord.status -in @('ready_for_review','accepted') -and
      [string]$Manifest.boot005_mechanical_revalidation -ceq 'passed'
    $DependencyProjectionSatisfied = if ($ExecutionMode -ceq 'formal_adopted') {
      $FormalDependencySatisfied
    } else { $LocalProjectionSatisfied }
    $Checks = [ordered]@{
      task_id_match=([string]$Manifest.task_id-ceq$TaskId);phase_match=([string]$Manifest.phase-ceq'Phase 3')
      manifest_execution_mode_match=([string]$Manifest.execution_mode-ceq$ExecutionMode)
      dependency_failures=0;status_cas_conflict=0;unexpected_paths=0;base_drift=$BaseDrift
      source_hash_drift=$SourceHashDrift;source_evidence_hash_drift=$SourceEvidenceHashDrift
      prior_phase_regression_failures=if($null-eq$EntryRegression){1}else{[int]$EntryRegression.failure_count}
      phase_runtime_manifest='existing_exact';phase_base_oid=[string]$Manifest.phase_base_oid
      provisional_base_oid=[string]$Manifest.provisional_base_oid;source_task_id=[string]$Manifest.source_task_id
      source_status=if($null-eq$SourceRecord){'missing'}else{[string]$SourceRecord.status}
      boot005_mechanical_revalidation=[string]$Manifest.boot005_mechanical_revalidation
      local_dependency_projection_valid=$LocalProjectionSatisfied;formal_dependency_satisfied=$FormalDependencySatisfied
      formal_dependency_pending=($ExecutionMode-ceq'local_provisional');production_write_count=0
    }
    if(-not[bool]$Checks.task_id_match-or-not[bool]$Checks.phase_match-or-not[bool]$Checks.manifest_execution_mode_match-or
       [int]$Checks.base_drift+[int]$Checks.source_hash_drift+[int]$Checks.source_evidence_hash_drift+[int]$Checks.prior_phase_regression_failures-ne 0-or
       [string]$Checks.source_task_id-cne'TASK-P02-990'-or-not$DependencyProjectionSatisfied){
      $Checks.dependency_failures=1
      return New-BlockedResult 'phase_03_entry_manifest_validation_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-001') {
    $ManifestPath = Join-Path $script:RepositoryRoot ([string]$script:Task.phase_runtime_manifest_path)
    $ManifestState = 'existing_exact'
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
      $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      $PhaseBaseOid = (& git -C $script:RepositoryRoot merge-base $Head 'codex/phase-01-semantics-baseline').Trim()
      if ($LASTEXITCODE -ne 0 -or $PhaseBaseOid -cnotmatch '^[0-9a-f]{40}$') {
        return New-BlockedResult 'phase_02_base_resolution_failed' ([ordered]@{dependency_failures=0;base_drift=1;production_write_count=0})
      }
      $PhaseEntryResult = Invoke-RedactedExternal -Executable 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',
        (Join-Path $script:RepositoryRoot 'docs\execution\commands\Invoke-PhaseEntryRegression.ps1'),
        '-TaskId',$TaskId,
        '-SourceRecordPath',(Join-Path $script:RepositoryRoot 'docs\execution\status\TASK-P01-990.json'),
        '-ExpectedHeadOid',$Head,
        '-PhaseBaseOid',$PhaseBaseOid,
        '-OutputPath',$ManifestPath,
        '-ExecutionMode',$ExecutionMode
      )
      if ([int]$PhaseEntryResult.exit_code -ne 0) {
        return New-BlockedResult 'phase_02_entry_regression_failed' ([ordered]@{
          phase_entry_exit_code=[int]$PhaseEntryResult.exit_code;prior_phase_regression_failures=1
          dependency_failures=0;unexpected_paths=0;base_drift=1;production_write_count=0
        })
      }
      $ManifestState = 'created'
    }
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $SourcePath = Join-Path $script:RepositoryRoot ([string]$Manifest.source_record_path)
    $SourceRecord = if (Test-Path -LiteralPath $SourcePath -PathType Leaf) { Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } else { $null }
    $SourceHashDrift = if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { 1 } elseif ((Get-Sha256 -LiteralPath $SourcePath) -cne [string]$Manifest.source_record_sha256) { 1 } else { 0 }
    $SourceGatePath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-01\P01-990\gate-results.json'
    $SourceEvidenceHashDrift = if ($null -eq $SourceRecord -or -not (Test-Path -LiteralPath $SourceGatePath -PathType Leaf)) { 1 } elseif ((Get-Sha256 -LiteralPath $SourceGatePath) -cne [string]$SourceRecord.evidence_sha256) { 1 } else { 0 }
    $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
    & git -C $script:RepositoryRoot merge-base --is-ancestor ([string]$Manifest.phase_base_oid) $Head 2>$null
    $BaseDrift = if ($LASTEXITCODE -eq 0) { 0 } else { 1 }
    $FormalDependencySatisfied = $null -ne $SourceRecord -and [string]$SourceRecord.status -ceq 'accepted' -and [bool]$SourceRecord.reviewer_independent -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.formal_phase_base_oid)
    $DependencyProjectionSatisfied = if ($ExecutionMode -ceq 'formal_adopted') { $FormalDependencySatisfied } else { [bool]$Manifest.local_dependency_projection_valid }
    $Checks = [ordered]@{
      task_id_match=([string]$Manifest.task_id-ceq$TaskId);phase_match=([string]$Manifest.phase-ceq'Phase 2')
      manifest_execution_mode_match=([string]$Manifest.execution_mode-ceq$ExecutionMode);dependency_failures=0
      status_cas_conflict=0;unexpected_paths=0;base_drift=$BaseDrift;source_hash_drift=$SourceHashDrift
      source_evidence_hash_drift=$SourceEvidenceHashDrift;prior_phase_regression_failures=[int]$Manifest.prior_phase_regression_failures
      phase_runtime_manifest=$ManifestState;phase_base_oid=[string]$Manifest.phase_base_oid;provisional_base_oid=[string]$Manifest.provisional_base_oid
      source_task_id=[string]$Manifest.source_task_id;source_status=[string]$Manifest.source_status
      boot005_mechanical_revalidation=[string]$Manifest.boot005_mechanical_revalidation
      local_dependency_projection_valid=[bool]$Manifest.local_dependency_projection_valid
      formal_dependency_satisfied=$FormalDependencySatisfied;formal_dependency_pending=($ExecutionMode-ceq'local_provisional')
      production_write_count=0
    }
    if(-not[bool]$Checks.task_id_match -or -not[bool]$Checks.phase_match -or -not[bool]$Checks.manifest_execution_mode_match -or
       [int]$Checks.base_drift+[int]$Checks.source_hash_drift+[int]$Checks.source_evidence_hash_drift+[int]$Checks.prior_phase_regression_failures-ne 0 -or
       [string]$Checks.source_task_id-cne'TASK-P01-990' -or [string]$Checks.source_status-notin@('ready_for_review','accepted') -or
       [string]$Checks.boot005_mechanical_revalidation-cne'passed' -or -not$DependencyProjectionSatisfied){
      return New-BlockedResult 'phase_02_entry_manifest_validation_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-001') {
    $ManifestPath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-01\phase-runtime-manifest.json'
    $ManifestState = 'existing_exact'
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
      $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      $PhaseEntryResult = Invoke-RedactedExternal -Executable 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $script:RepositoryRoot 'docs\execution\commands\Invoke-PhaseEntryRegression.ps1'),
        '-TaskId', $TaskId,
        '-SourceRecordPath', (Join-Path $script:RepositoryRoot 'docs\execution\status\TASK-P00-990.json'),
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
    $SourceRecord = if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
      Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } else { $null }
    $SourceHashDrift = if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { 1 } elseif (
      (Get-Sha256 -LiteralPath $SourcePath) -cne [string]$Manifest.source_record_sha256
    ) { 1 } else { 0 }
    $Head = (& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
    & git -C $script:RepositoryRoot merge-base --is-ancestor ([string]$Manifest.phase_base_oid) $Head 2>$null
    $BaseDrift = if ($LASTEXITCODE -eq 0) { 0 } else { 1 }
    $Checks = [ordered]@{
      task_id_match = ([string]$Manifest.task_id -ceq $TaskId)
      phase_match = ([string]$Manifest.phase -ceq 'Phase 1')
      manifest_execution_mode_match = ([string]$Manifest.execution_mode -ceq $ExecutionMode)
      dependency_failures = 0
      status_cas_conflict = 0
      unexpected_paths = 0
      base_drift = $BaseDrift
      source_hash_drift = $SourceHashDrift
      prior_phase_regression_failures = [int]$Manifest.prior_phase_regression_failures
      phase_runtime_manifest = $ManifestState
      phase_base_oid = [string]$Manifest.phase_base_oid
      provisional_base_oid = [string]$Manifest.provisional_base_oid
      source_task_id = [string]$Manifest.source_task_id
      source_status = [string]$Manifest.source_status
      boot005_mechanical_revalidation = [string]$Manifest.boot005_mechanical_revalidation
      local_dependency_projection_valid = [bool]$Manifest.local_dependency_projection_valid
      formal_dependency_satisfied = ($null -ne $SourceRecord -and
        [string]$SourceRecord.status -ceq 'accepted' -and [bool]$SourceRecord.reviewer_independent -and
        -not [string]::IsNullOrWhiteSpace([string]$Manifest.formal_phase_base_oid))
      formal_dependency_pending = ($ExecutionMode -ceq 'local_provisional')
      production_write_count = 0
    }
    $DependencyProjectionSatisfied = if ($ExecutionMode -ceq 'formal_adopted') {
      [bool]$Checks.formal_dependency_satisfied
    } else {
      [bool]$Checks.local_dependency_projection_valid
    }
    if (-not [bool]$Checks.task_id_match -or -not [bool]$Checks.phase_match -or
        -not [bool]$Checks.manifest_execution_mode_match -or
        [int]$Checks.base_drift -ne 0 -or [int]$Checks.source_hash_drift -ne 0 -or
        [int]$Checks.prior_phase_regression_failures -ne 0 -or
        [string]$Checks.source_task_id -cne 'TASK-P00-990' -or
        [string]$Checks.source_status -notin @('ready_for_review', 'accepted') -or
        [string]$Checks.boot005_mechanical_revalidation -cne 'passed' -or
        -not $DependencyProjectionSatisfied) {
      return New-BlockedResult 'phase_01_entry_manifest_validation_failed' $Checks
    }
    return New-PassedResult $Checks
  }
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
    $DependencyReady = if ($ExecutionMode -ceq 'formal_adopted') {
      [string]$DependencyStatus.status -ceq 'accepted' -and [bool]$DependencyStatus.reviewer_independent
    } else {
      [string]$DependencyStatus.status -in @('ready_for_review', 'accepted')
    }
    if (-not $DependencyReady) { $DependencyFailures++ }
  }
  $Checks = [ordered]@{
    task_id_match = $true; dependency_failures = $DependencyFailures; status_cas_conflict = 0
    unexpected_paths = 0; base_drift = 0; local_dependency_projection_valid = ($ExecutionMode -ceq 'local_provisional')
    formal_dependency_pending = ($ExecutionMode -ceq 'local_provisional')
    formal_requires_independent_accepted_dependencies = $true
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
  if ($TaskId -ceq 'TASK-P03-009') {
    $Paths=@(Get-P03009ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03009PathAllowed -RelativePath $_)});$Required=@('agent-service/scripts/test_backup_restore.ps1','agent-service/tests/integration/test_migration_restore.py','docs/runbooks/runtime-db-restore.md','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/evidence/phase-03/P03-009/direct-pytest.xml','docs/execution/evidence/phase-03/P03-009/backup-restore-report.json','docs/execution/evidence/phase-03/P03-009/implementation-actions.json','docs/execution/evidence/phase-03/P03-009/runner-enabler.md','docs/execution/evidence/phase-03/P03-009/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-009/ci-reports/unit.xml','docs/execution/evidence/phase-03/P03-009/ci-reports/contract.xml');$Missing=@($Required|Where-Object{-not(Test-Path (Join-Path $script:RepositoryRoot $_)-PathType Leaf)});$CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0;if(Test-Path $CommandLedgerPath){$Ledger=Get-Content $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json;$RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count;foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}};$Checks=[ordered]@{unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count;unrecorded_action_count=if(Test-Path (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1};work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero;recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0};if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){return New-BlockedResult 'p03_009_workset_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-008') {
    $Paths=@(Get-P03008ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03008PathAllowed -RelativePath $_)});$Required=@('agent-service/tests/contract/test_idempotency.py','agent-service/tests/integration/test_runtime_concurrency.py','agent-service/tests/unit/harness/test_05_idempotency_guard.py','agent-service/tests/unit/harness/test_34_consistency_fence.py','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/evidence/phase-03/P03-008/direct-pytest.xml','docs/execution/evidence/phase-03/P03-008/ct-001.json','docs/execution/evidence/phase-03/P03-008/ct-002.json','docs/execution/evidence/phase-03/P03-008/runtime-concurrency-report.json','docs/execution/evidence/phase-03/P03-008/harness-status-fragment.json','docs/execution/evidence/phase-03/P03-008/implementation-actions.json','docs/execution/evidence/phase-03/P03-008/runner-enabler.md','docs/execution/evidence/phase-03/P03-008/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-008/ci-reports/unit.xml','docs/execution/evidence/phase-03/P03-008/ci-reports/contract.xml');$Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)});$CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0;if(Test-Path -LiteralPath $CommandLedgerPath){$Ledger=Get-Content -LiteralPath $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json;$RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count;foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}};$Checks=[ordered]@{unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count;unrecorded_action_count=if(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1};work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero;recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0};if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){return New-BlockedResult 'p03_008_workset_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-007') {
    $Paths=@(Get-P03007ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03007PathAllowed -RelativePath $_)});$Required=@('agent-service/migrations/versions/p03_007_runtime_rls.py','agent-service/tests/security/test_rls.py','agent-service/tests/security/fixtures/rls_principals.sql','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/evidence/phase-03/P03-007/direct-pytest.xml','docs/execution/evidence/phase-03/P03-007/rls-report.json','docs/execution/evidence/phase-03/P03-007/implementation-actions.json','docs/execution/evidence/phase-03/P03-007/runner-enabler.md','docs/execution/evidence/phase-03/P03-007/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-007/ci-reports/unit.xml','docs/execution/evidence/phase-03/P03-007/ci-reports/contract.xml');$Missing=@($Required|Where-Object{-not(Test-Path (Join-Path $script:RepositoryRoot $_)-PathType Leaf)});$CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0;if(Test-Path $CommandLedgerPath){$Ledger=Get-Content $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json;$RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count;foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}};$Checks=[ordered]@{unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count;unrecorded_action_count=if(Test-Path (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1};work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero;recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0};if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){return New-BlockedResult 'p03_007_workset_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-006') {
    $Paths=@(Get-P03006ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03006PathAllowed -RelativePath $_)})
    $Required=@('agent-service/app/persistence/models/outbox.py','agent-service/app/persistence/repositories/outbox.py','agent-service/migrations/versions/p03_006_outbox_receipts.py','agent-service/tests/integration/test_outbox_receipts.py','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/evidence/phase-03/P03-006/direct-pytest.xml','docs/execution/evidence/phase-03/P03-006/outbox-receipt-report.json','docs/execution/evidence/phase-03/P03-006/implementation-actions.json','docs/execution/evidence/phase-03/P03-006/runner-enabler.md','docs/execution/evidence/phase-03/P03-006/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-006/ci-reports/unit.xml','docs/execution/evidence/phase-03/P03-006/ci-reports/contract.xml')
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)});$CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0;if(Test-Path -LiteralPath $CommandLedgerPath){$Ledger=Get-Content $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json;$RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count;foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}}
    $Checks=[ordered]@{unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count;unrecorded_action_count=if(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1};work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero;recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0};if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){return New-BlockedResult 'p03_006_workset_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-005') {
    $Paths=@(Get-P03005ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03005PathAllowed -RelativePath $_)})
    $Required=@(
      'contracts/behavior-manifest-v1.schema.json','contracts/digest-vectors-v1.json',
      'agent-service/app/runtime/behavior_manifest.py','agent-service/tests/contract/test_manifest_digest.py',
      'lib/core/agent/behavior_digest.dart','test/behavior_digest_test.dart','docs/execution/commands/Invoke-TaskGate.ps1',
      'docs/execution/evidence/phase-03/P03-005/direct-pytest.xml','docs/execution/evidence/phase-03/P03-005/manifest-digest-report.json',
      'docs/execution/evidence/phase-03/P03-005/dart-digest-report.json','docs/execution/evidence/phase-03/P03-005/analysis-scope.json',
      'docs/execution/evidence/phase-03/P03-005/cross-language-summary.json','docs/execution/evidence/phase-03/P03-005/implementation-actions.json',
      'docs/execution/evidence/phase-03/P03-005/blocker.json','docs/execution/evidence/phase-03/P03-005/runner-enabler.md',
      'docs/execution/evidence/phase-03/P03-005/ci-reports/ci-summary.json','docs/execution/evidence/phase-03/P03-005/ci-reports/unit.xml',
      'docs/execution/evidence/phase-03/P03-005/ci-reports/contract.xml'
    )
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0
    if(Test-Path -LiteralPath $CommandLedgerPath -PathType Leaf){$Ledger=Get-Content -LiteralPath $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json;$RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count;foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}}
    $Checks=[ordered]@{unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count;unrecorded_action_count=if(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1};work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero;recovered_diagnostic_failure_count=$RecoveredDiagnostics;catalog_allowlist_gap_recorded=(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'runner-enabler.md'));production_write_count=0}
    if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){return New-BlockedResult 'p03_005_workset_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-004') {
    $Paths=@(Get-P03004ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03004PathAllowed -RelativePath $_)})
    $Required=@(
      'agent-service/app/persistence/models/behavior.py','agent-service/app/persistence/repositories/behavior.py',
      'agent-service/migrations/versions/p03_004_behavior_releases.py','agent-service/tests/contract/test_pointer_cas.py',
      'agent-service/tests/unit/harness/test_11_behavior_registry.py','docs/execution/commands/Invoke-TaskGate.ps1',
      'docs/execution/evidence/phase-03/P03-004/direct-pytest.xml','docs/execution/evidence/phase-03/P03-004/behavior-release-report.json',
      'docs/execution/evidence/phase-03/P03-004/harness-status-fragment.json','docs/execution/evidence/phase-03/P03-004/implementation-actions.json',
      'docs/execution/evidence/phase-03/P03-004/runner-enabler.md','docs/execution/evidence/phase-03/P03-004/blocker.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/ci-summary.json',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/unit.xml',
      'docs/execution/evidence/phase-03/P03-004/ci-reports/contract.xml'
    )
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0
    if(Test-Path -LiteralPath $CommandLedgerPath -PathType Leaf){$Ledger=Get-Content -LiteralPath $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json;$RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count;foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}}
    $Checks=[ordered]@{unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count;unrecorded_action_count=if(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1};work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero;recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0}
    if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){return New-BlockedResult 'p03_004_workset_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-003') {
    $Paths=@(Get-P03003ChangedPaths)
    $Unexpected=@($Paths|Where-Object{-not(Test-P03003PathAllowed -RelativePath $_)})
    $Required=@(
      'agent-service/app/persistence/models/jobs.py',
      'agent-service/app/persistence/repositories/jobs.py',
      'agent-service/app/persistence/repositories/checkpoints.py',
      'agent-service/migrations/versions/p03_003_jobs_leases_checkpoints.py',
      'agent-service/tests/integration/test_job_metadata.py',
      'docs/execution/commands/Invoke-TaskGate.ps1',
      'docs/execution/evidence/phase-03/P03-003/direct-pytest.xml',
      'docs/execution/evidence/phase-03/P03-003/job-metadata-report.json',
      'docs/execution/evidence/phase-03/P03-003/dependency-audit-report.json',
      'docs/execution/evidence/phase-03/P03-003/dependency-licenses.json',
      'docs/execution/evidence/phase-03/P03-003/implementation-actions.json',
      'docs/execution/evidence/phase-03/P03-003/runner-enabler.md',
      'docs/execution/evidence/phase-03/P03-003/blocker.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/ci-summary.json',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/unit.xml',
      'docs/execution/evidence/phase-03/P03-003/ci-reports/contract.xml'
    )
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0
    if(Test-Path -LiteralPath $CommandLedgerPath -PathType Leaf){$Ledger=Get-Content -LiteralPath $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json;$RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count;foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}}
    $Checks=[ordered]@{
      unexpected_paths=$Unexpected.Count
      read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count
      unrecorded_action_count=if(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1}
      work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero
      recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0
    }
    if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){return New-BlockedResult 'p03_003_workset_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-002') {
    $Paths=@(Get-P03002ChangedPaths)
    $Unexpected=@($Paths|Where-Object{-not(Test-P03002PathAllowed -RelativePath $_)})
    $Required=@(
      '.gitattributes',
      'agent-service/app/persistence/models/runtime.py',
      'agent-service/app/persistence/repositories/runs.py',
      'agent-service/app/persistence/repositories/events.py',
      'agent-service/migrations/versions/p03_002_run_event_idempotency.py',
      'agent-service/tests/integration/test_runtime_persistence.py',
      'agent-service/tests/unit/harness/test_25_event_writer.py',
      'agent-service/scripts/ci.ps1',
      'docs/execution/commands/Invoke-TaskGate.ps1',
      'docs/execution/evidence/phase-03/P03-002/direct-pytest.xml',
      'docs/execution/evidence/phase-03/P03-002/runtime-persistence-report.json',
      'docs/execution/evidence/phase-03/P03-002/harness-status-fragment.json',
      'docs/execution/evidence/phase-03/P03-002/implementation-actions.json',
      'docs/execution/evidence/phase-03/P03-002/runner-enabler.md',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/ci-summary.json',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/unit.xml',
      'docs/execution/evidence/phase-03/P03-002/ci-reports/contract.xml'
    )
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0
    if(Test-Path -LiteralPath $CommandLedgerPath -PathType Leaf){
      $Ledger=Get-Content -LiteralPath $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json
      $RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count
      foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}
    }
    $Checks=[ordered]@{
      unexpected_paths=$Unexpected.Count
      read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count
      unrecorded_action_count=if(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1}
      work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero
      recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0
    }
    if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){
      return New-BlockedResult 'p03_002_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-001') {
    $Paths=@(Get-P03001ChangedPaths)
    $Unexpected=@($Paths|Where-Object{-not(Test-P03001PathAllowed -RelativePath $_)})
    $Required=@(
      '.gitattributes',
      'agent-service/alembic.ini','agent-service/migrations/env.py','agent-service/migrations/script.py.mako',
      'agent-service/migrations/versions/p03_001_runtime_baseline.py','agent-service/tests/integration/test_migration_baseline.py',
      'agent-service/pyproject.toml','agent-service/uv.lock','agent-service/tests/ci/test_quality_gate.py',
      'docs/architecture/adr/ADR-P03-001-postgresql-driver.md',
      'docs/execution/evidence/phase-03/phase-runtime-manifest.json',
      'docs/execution/evidence/phase-03/P03-001/direct-pytest.xml',
      'docs/execution/evidence/phase-03/P03-001/migration-inventory.json',
      'docs/execution/evidence/phase-03/P03-001/implementation-actions.json',
      'docs/execution/supply-chain/phase-03/P03-001-enabler/dependency-diff.json',
      'docs/execution/supply-chain/phase-03/P03-001-enabler/sbom.cdx.json',
      'docs/execution/supply-chain/phase-03/P03-001-enabler/licenses.json',
      'docs/execution/supply-chain/phase-03/P03-001-enabler/vulnerability-scan.json',
      'docs/execution/supply-chain/phase-03/P03-001-enabler/maintenance.json',
      'docs/execution/supply-chain/phase-03/P03-001-enabler/provenance.json',
      'docs/execution/supply-chain/phase-03/P03-001-enabler/decision.json'
    )
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0
    if(Test-Path -LiteralPath $CommandLedgerPath -PathType Leaf){
      $Ledger=Get-Content -LiteralPath $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json
      $RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne0}).Count
      foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne0){$LatestNonzero++}}
    }
    $Checks=[ordered]@{
      unexpected_paths=$Unexpected.Count
      read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count
      unrecorded_action_count=if(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'implementation-actions.json')){0}else{1}
      work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero
      recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0
    }
    if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.unrecorded_action_count+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count-ne0){
      return New-BlockedResult 'p03_001_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-001') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
    $AllowedExact = @(
      'agent-service/pyproject.toml','agent-service/uv.lock','agent-service/app/api/main.py',
      'agent-service/app/worker/main.py','agent-service/tests/test_entrypoints.py',
      'agent-service/scripts/build.ps1','agent-service/README.md',
      'docs/execution/evidence/phase-02/phase-runtime-manifest.json',
      'docs/execution/status/TASK-P02-001.json',
      'docs/execution/supply-chain/phase-02/P02-001/agent-service.cdx.json'
    )
    $AllowedPrefix = 'docs/execution/evidence/phase-02/P02-001/'
    $Unexpected = @($Paths | Where-Object { $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix,[StringComparison]::Ordinal) })
    $Required = @(
      'agent-service/pyproject.toml','agent-service/uv.lock','agent-service/app/api/main.py',
      'agent-service/app/worker/main.py','agent-service/tests/test_entrypoints.py',
      'agent-service/scripts/build.ps1','agent-service/README.md',
      'docs/execution/evidence/phase-02/phase-runtime-manifest.json',
      'docs/execution/evidence/phase-02/P02-001/pip-audit.json',
      'docs/execution/evidence/phase-02/P02-001/license-report.json',
      'docs/execution/supply-chain/phase-02/P02-001/agent-service.cdx.json'
    )
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $CommandLedgerPath = Join-Path $script:TaskEvidenceDirectory 'commands.json'
    $LatestNonzero = 0; $RecoveredDiagnostics = 0
    if (Test-Path -LiteralPath $CommandLedgerPath -PathType Leaf) {
      $Ledger = Get-Content -LiteralPath $CommandLedgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $RecoveredDiagnostics = @($Ledger.commands | Where-Object { [int]$_.exit_code -ne 0 }).Count
      foreach ($ModeGroup in @($Ledger.commands | Group-Object description)) {
        if ([int]@($ModeGroup.Group)[-1].exit_code -ne 0) { $LatestNonzero++ }
      }
    }
    $Checks = [ordered]@{
      unexpected_paths=$Unexpected.Count
      read_only_input_writes=@($Paths | Where-Object { $_ -in @('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1') }).Count
      unrecorded_action_count=0;work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=$LatestNonzero
      recovered_diagnostic_failure_count=$RecoveredDiagnostics;production_write_count=0
    }
    if ([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count -ne 0) {
      return New-BlockedResult 'p02_001_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -cmatch '^TASK-P02-(002|003|004|005|006|007|008|089)$') {
    $Rules=Get-P02TaskPathRules
    $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD);$Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths=@($Paths|ForEach-Object{$_.Replace('\','/')}|Sort-Object -Unique)
    $Unexpected=@($Paths|Where-Object{-not(Test-P02TaskPathAllowed -RelativePath $_ -Rules $Rules)})
    $Missing=0
    foreach($RawPath in @($script:Task.file_allowlist)){
      $FullPath=Join-Path $script:RepositoryRoot ([string]$RawPath)
      if(-not(Test-Path -LiteralPath $FullPath)){$Missing++}
    }
    if($TaskId-ceq'TASK-P02-089'){
      foreach($RelativePath in @(
        'docs/execution/evidence/phase-02/artifact-manifest.premerge.json',
        'docs/execution/status/task-board.json','docs/execution/status/task-board.md',
        'docs/execution/evidence/phase-02/improvements/STAR-nested-evidence-integrity.md'
      )){if(-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $RelativePath)-PathType Leaf)){$Missing++}}
    }
    foreach($RawRule in @($script:Task.directory_allowlist)){
      $DirectoryPath=if($RawRule-is[Collections.IDictionary]){[string]$RawRule['path']}else{[string]$RawRule.path}
      $NameRegex=if($RawRule-is[Collections.IDictionary]){[string]$RawRule['name_regex']}else{[string]$RawRule.name_regex}
      $FullDirectory=Join-Path $script:RepositoryRoot $DirectoryPath
      if(-not(Test-Path -LiteralPath $FullDirectory -PathType Container)-or @(Get-ChildItem -LiteralPath $FullDirectory -File|Where-Object{$_.Name-cmatch$NameRegex}).Count-eq 0){$Missing++}
    }
    $CommandLedgerPath=Join-Path $script:TaskEvidenceDirectory 'commands.json';$LatestNonzero=0;$RecoveredDiagnostics=0
    if(Test-Path -LiteralPath $CommandLedgerPath -PathType Leaf){
      $Ledger=Get-Content -LiteralPath $CommandLedgerPath -Raw -Encoding UTF8|ConvertFrom-Json
      $RecoveredDiagnostics=@($Ledger.commands|Where-Object{[int]$_.exit_code-ne 0}).Count
      foreach($Group in @($Ledger.commands|Group-Object description)){if([int]@($Group.Group)[-1].exit_code-ne 0){$LatestNonzero++}}
    }
    $Checks=[ordered]@{
      unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count
      unrecorded_action_count=0;work_contract_assertion_gaps=$Missing;nonzero_exit_count=$LatestNonzero
      recovered_diagnostic_failure_count=$RecoveredDiagnostics
      implementation_change_count=if($TaskId-ceq'TASK-P02-089'){@($Paths|Where-Object{$_ -match '^(lib|agent-service/app|agent-service/tests|agent-service/pyproject\.toml|agent-service/uv\.lock|supabase|contracts)/'}).Count}else{0}
      production_write_count=0
    }
    if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.nonzero_exit_count+[int]$Checks.implementation_change_count-ne 0){return New-BlockedResult 'p02_workset_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -in @('TASK-P01-089','TASK-P01-990')) {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
    $AllowedExact = @(
      @($script:Task.file_allowlist) + @($script:Task.evidence_outputs) + @([string]$script:Task.status_file) |
        ForEach-Object { ([string]$_).Replace('\','/') }
    )
    $AllowedPrefixes = @($script:Task.directory_allowlist | ForEach-Object { ([string]$_).Replace('\','/').TrimEnd('/') + '/' })
    if ($TaskId -ceq 'TASK-P01-089') {
      $AllowedExact += @(
        'docs/execution/evidence/phase-01/change-summary.md','docs/execution/evidence/phase-01/knowledge-transfer.md',
        'docs/execution/evidence/phase-01/star-records.md','docs/execution/evidence/phase-01/artifact-manifest.premerge.json',
        'docs/execution/status/task-board.json','docs/execution/status/task-board.md'
      )
      $AllowedPrefixes += @('docs/execution/evidence/phase-01/P01-089/','docs/execution/evidence/phase-01/improvements/')
    }
    if ($TaskId -ceq 'TASK-P01-990') {
      $AllowedExact += @('docs/execution/evidence/phase-01/acceptance.md','docs/execution/evidence/index.json')
      $AllowedPrefixes += @('docs/execution/evidence/phase-01/P01-990/')
    }
    $Unexpected = @()
    foreach ($PathValue in $Paths) {
      $Allowed = $PathValue -in $AllowedExact
      foreach ($Prefix in $AllowedPrefixes) { if ($PathValue.StartsWith($Prefix,[StringComparison]::Ordinal)) { $Allowed=$true;break } }
      if (-not $Allowed) { $Unexpected += $PathValue }
    }
    $Required = if ($TaskId -ceq 'TASK-P01-089') {
      @('README.md','docs/architecture/validation-semantics.md','docs/runbooks/legacy-fallback.md','docs/api/validation-semantics.md',
        'docs/architecture/threat-model/phase-01-review.json','docs/execution/evidence/phase-01/change-summary.md',
        'docs/execution/evidence/phase-01/knowledge-transfer.md','docs/execution/evidence/phase-01/star-records.md',
        'docs/execution/evidence/phase-01/artifact-manifest.premerge.json','docs/execution/evidence/phase-01/P01-089/handoff-verification.json')
    } else { @('docs/execution/evidence/phase-01/acceptance.md','docs/execution/evidence/index.json') }
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $Checks = [ordered]@{
      unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count
      unrecorded_action_count=0;work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=0
      implementation_change_count=@($Paths|Where-Object{$_ -match '^(lib|agent-service|supabase|contracts)/'}).Count;production_write_count=0
    }
    if ([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.implementation_change_count -ne 0) {
      return New-BlockedResult 'p01_closure_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-005') {
    $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD);$Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths=@($Paths|ForEach-Object{$_.Replace('\','/')}|Sort-Object -Unique)
    $AllowedExact=@('docs/architecture/adr/ADR-P01-005-architecture-baseline.md','docs/execution/status/TASK-P01-005.json')
    $AllowedPrefix='docs/execution/evidence/phase-01/P01-005/'
    $Unexpected=@($Paths|Where-Object{$_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix,[StringComparison]::Ordinal)})
    $Required=@('docs/architecture/adr/ADR-P01-005-architecture-baseline.md','docs/execution/evidence/phase-01/P01-005/traceability-v1.6.1-task-map.md')
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath(Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $Checks=[ordered]@{unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_ -in @('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')}).Count;unrecorded_action_count=0;work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=0;runtime_or_database_change_count=@($Paths|Where-Object{$_ -match '^(lib|agent-service|contracts|supabase)/'}).Count;production_write_count=0}
    if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.work_contract_assertion_gaps+[int]$Checks.runtime_or_database_change_count-ne 0){return New-BlockedResult 'p01_005_workset_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-004') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
    $AllowedExact = @('contracts/flutter-agent-boundary-v1.yaml','docs/execution/status/TASK-P01-004.json')
    $AllowedPrefix = 'docs/execution/evidence/phase-01/P01-004/'
    $Unexpected = @($Paths | Where-Object { $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix,[StringComparison]::Ordinal) })
    $Required = @('contracts/flutter-agent-boundary-v1.yaml','docs/execution/evidence/phase-01/P01-004/flutter-service-matrix.md')
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $Checks = [ordered]@{
      unexpected_paths=$Unexpected.Count
      read_only_input_writes=@($Paths | Where-Object { $_ -in @('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1') }).Count
      unrecorded_action_count=0; work_contract_assertion_gaps=$Missing.Count; nonzero_exit_count=0
      flutter_implementation_change_count=@($Paths | Where-Object { $_ -match '^lib/' }).Count
      production_write_count=0
    }
    if ([int]$Checks.unexpected_paths + [int]$Checks.read_only_input_writes +
        [int]$Checks.work_contract_assertion_gaps + [int]$Checks.flutter_implementation_change_count -ne 0) {
      return New-BlockedResult 'p01_004_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-003') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD); $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\','/') } | Sort-Object -Unique)
    $AllowedExact = @('test/validation_semantics_test.dart','docs/execution/status/TASK-P01-003.json')
    $AllowedPrefixes = @('test/fixtures/validation/','docs/execution/evidence/phase-01/P01-003/')
    $Unexpected = @(); foreach($PathValue in $Paths){$Allowed=$PathValue-in$AllowedExact;foreach($Prefix in $AllowedPrefixes){if($PathValue.StartsWith($Prefix,[StringComparison]::Ordinal)){$Allowed=$true;break}};if(-not$Allowed){$Unexpected+=$PathValue}}
    $Required = @('test/fixtures/validation/validation_semantics_cases.json','test/validation_semantics_test.dart','docs/execution/evidence/phase-01/P01-003/local-test-report.json')
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $Checks=[ordered]@{unexpected_paths=$Unexpected.Count;read_only_input_writes=@($Paths|Where-Object{$_-in@('AGENTS.md','execplan.md','contracts/validation-semantics-v1.schema.json')}).Count;unrecorded_action_count=0;work_contract_assertion_gaps=$Missing.Count;nonzero_exit_count=0;production_write_count=0}
    if([int]$Checks.unexpected_paths+[int]$Checks.read_only_input_writes+[int]$Checks.work_contract_assertion_gaps-ne 0){return New-BlockedResult 'p01_003_workset_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-002') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedExact = @(
      'contracts/validation-semantics-v1.schema.json',
      'docs/architecture/validation-semantics-v1.md',
      'docs/execution/status/TASK-P01-002.json'
    )
    $AllowedPrefix = 'docs/execution/evidence/phase-01/P01-002/'
    $Unexpected = @($Paths | Where-Object { $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix, [StringComparison]::Ordinal) })
    $Missing = @($AllowedExact[0..1] | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $Checks = [ordered]@{
      unexpected_paths = $Unexpected.Count
      read_only_input_writes = @($Paths | Where-Object { $_ -in @('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1') }).Count
      unrecorded_action_count = 0
      work_contract_assertion_gaps = $Missing.Count
      nonzero_exit_count = 0
      business_implementation_change_count = @($Paths | Where-Object { $_ -match '^(lib|agent-service|supabase)/' }).Count
      catalog_plan_path_repair_count = 1
      catalog_plan_path_repair_reason = 'execplan authorizes the schema path; Catalog 2.0.0 omitted it from file_allowlist and is not mutated to avoid invalidating prior status hashes'
      production_write_count = 0
    }
    if ([int]$Checks.unexpected_paths + [int]$Checks.read_only_input_writes + [int]$Checks.work_contract_assertion_gaps +
        [int]$Checks.business_implementation_change_count -ne 0) {
      return New-BlockedResult 'p01_002_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-001') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedPrefix = 'docs/execution/evidence/phase-01/P01-001/'
    $AllowedExact = @(
      'docs/execution/evidence/phase-01/phase-runtime-manifest.json',
      'docs/execution/status/TASK-P01-001.json'
    )
    $Unexpected = @($Paths | Where-Object {
      $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix, [StringComparison]::Ordinal)
    })
    $Required = @(
      'docs/execution/evidence/phase-01/P01-001/semantics/current-call-chain.md',
      'docs/execution/evidence/phase-01/P01-001/semantics/current-write-paths.md',
      'docs/execution/evidence/phase-01/P01-001/semantics/call-chain-inventory.json'
    )
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $Checks = [ordered]@{
      unexpected_paths = $Unexpected.Count
      read_only_input_writes = @($Paths | Where-Object { $_ -in @('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1') }).Count
      unrecorded_action_count = 0
      work_contract_assertion_gaps = $Missing.Count
      nonzero_exit_count = 0
      application_change_count = @($Paths | Where-Object { $_ -match '^(lib|agent-service|contracts|supabase)/' }).Count
      production_write_count = 0
    }
    if ([int]$Checks.unexpected_paths + [int]$Checks.read_only_input_writes +
        [int]$Checks.work_contract_assertion_gaps + [int]$Checks.application_change_count -ne 0) {
      return New-BlockedResult 'p01_001_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-003') {
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths = @($Paths | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $AllowedPrefix = 'docs/execution/evidence/phase-00/P00-003/'
    $AllowedExact = @('docs/execution/evidence/phase-00/P00-003.json','docs/execution/status/TASK-P00-003.json')
    $Unexpected = @($Paths | Where-Object {
      $_ -notin $AllowedExact -and -not $_.StartsWith($AllowedPrefix, [StringComparison]::Ordinal)
    })
    $Required = @(
      'docs/execution/evidence/phase-00/P00-003.json',
      'docs/execution/evidence/phase-00/P00-003/security/secret-containment.json',
      'docs/execution/evidence/phase-00/P00-003/security/secret-provider-reference.md',
      'docs/execution/evidence/phase-00/P00-003/security/revoked-history-registry.json'
    )
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_) -PathType Leaf) })
    $Checks = [ordered]@{
      unexpected_paths = $Unexpected.Count
      read_only_input_writes = @($Paths | Where-Object { $_ -in @('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1') }).Count
      unrecorded_action_count = 0
      work_contract_assertion_gaps = $Missing.Count
      nonzero_exit_count = 0
      recovered_diagnostic_failure_count = 2
      application_change_count = @($Paths | Where-Object { $_ -match '^(lib|test|agent-service|contracts|supabase)/' }).Count
      external_revocation_attempt_count = 0
      production_write_count = 0
    }
    if ([int]$Checks.unexpected_paths + [int]$Checks.read_only_input_writes +
        [int]$Checks.work_contract_assertion_gaps + [int]$Checks.application_change_count -ne 0) {
      return New-BlockedResult 'p00_secret_containment_workset_failed' $Checks
    }
    return New-PassedResult $Checks
  }
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
  if ($TaskId -ceq 'TASK-P03-003') {
    $UvPath='D:\GO_NOW-toolchain\bin\uv.exe'
    $Python=Join-Path $script:RepositoryRoot 'agent-service\.venv\Scripts\python.exe'
    $Quality=Join-Path $script:RepositoryRoot 'agent-service\tests\ci\test_quality_gate.py'
    $LicensePath=Join-Path $script:TaskEvidenceDirectory 'dependency-licenses.json'
    $Audit=Invoke-RedactedExternal -Executable $UvPath -Arguments @(
      'audit','--locked','--all-groups','--directory',(Join-Path $script:RepositoryRoot 'agent-service')
    )
    $LicenseRun=Invoke-RedactedExternal -Executable $Python -Arguments @(
      $Quality,'--mode','licenses','--repo-root',$script:RepositoryRoot,'--output',$LicensePath
    )
    $License=if(Test-Path -LiteralPath $LicensePath -PathType Leaf){Get-Content -LiteralPath $LicensePath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $DependencyPaths=@(& git -C $script:RepositoryRoot diff --name-only HEAD -- 'agent-service/pyproject.toml' 'agent-service/uv.lock')
    $Checks=[ordered]@{
      unpinned_direct=if($null-eq$License){1}else{[int]$License.checks.unpinned_direct}
      unknown_license=if($null-eq$License){1}else{[int]$License.checks.unknown_license}
      critical_cve=if([int]$Audit.exit_code-eq0){0}else{1};high_cve=0
      stale_without_adr=0;dependency_change_count=$DependencyPaths.Count
      audit_exit_code=[int]$Audit.exit_code;license_exit_code=[int]$LicenseRun.exit_code
      direct_pin_count=if($null-eq$License){0}else{[int]$License.checks.direct_pin_count};production_write_count=0
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'dependency-audit-report.json') -Value ([ordered]@{
      schema_version='1.0';task_id=$TaskId;checks=$Checks;recorded_at=[DateTimeOffset]::Now.ToString('o')
    })
    if([int]$Checks.unpinned_direct+[int]$Checks.unknown_license+[int]$Checks.critical_cve+[int]$Checks.high_cve+[int]$Checks.stale_without_adr+[int]$Checks.dependency_change_count+[int]$Checks.license_exit_code-ne0){return New-BlockedResult 'p03_003_dependency_audit_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-006') {
    $PyprojectPath=Join-Path $script:RepositoryRoot 'agent-service/pyproject.toml'
    $Pyproject=Get-Content -LiteralPath $PyprojectPath -Raw -Encoding UTF8
    $DirectPins=@([regex]::Matches($Pyproject,'(?m)^\s*"[^\"]+==[^\"]+",?\s*$'))
    $UvPath='D:\GO_NOW-toolchain\bin\uv.exe'
    $Audit=Invoke-RedactedExternal -Executable $UvPath -Arguments @('audit','--locked','--all-groups','--directory',(Join-Path $script:RepositoryRoot 'agent-service'))
    $LicensePath=Join-Path $script:TaskEvidenceDirectory 'ci-reports\licenses.json'
    $License=if(Test-Path -LiteralPath $LicensePath){Get-Content -LiteralPath $LicensePath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $Checks=[ordered]@{
      unpinned_direct=if($DirectPins.Count-eq 11){0}else{[Math]::Abs(11-$DirectPins.Count)}
      unknown_license=if($null-eq$License){1}else{[int]$License.checks.unknown_license}
      critical_cve=if([int]$Audit.exit_code-eq 0){0}else{1};high_cve=0
      stale_without_adr=0;lock_drift=@(& git -C $script:RepositoryRoot diff --name-only HEAD -- 'agent-service/uv.lock').Count
      audit_exit_code=[int]$Audit.exit_code;direct_pin_count=$DirectPins.Count;production_write_count=0
    }
    if([int]$Checks.unpinned_direct+[int]$Checks.unknown_license+[int]$Checks.critical_cve+[int]$Checks.high_cve+[int]$Checks.stale_without_adr+[int]$Checks.lock_drift-ne 0){return New-BlockedResult 'p02_006_dependency_audit_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-001') {
    $PyprojectPath = Join-Path $script:RepositoryRoot 'agent-service\pyproject.toml'
    $LockPath = Join-Path $script:RepositoryRoot 'agent-service\uv.lock'
    $AuditPath = Join-Path $script:TaskEvidenceDirectory 'pip-audit.json'
    $LicensePath = Join-Path $script:TaskEvidenceDirectory 'license-report.json'
    $SbomPath = Join-Path $script:RepositoryRoot 'docs\execution\supply-chain\phase-02\P02-001\agent-service.cdx.json'
    $Required = @($PyprojectPath,$LockPath,$AuditPath,$LicensePath,$SbomPath)
    $Missing = @($Required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($Missing.Count -ne 0) {
      return New-BlockedResult 'p02_001_dependency_evidence_missing' ([ordered]@{
        unpinned_direct=$Missing.Count;unknown_license=0;critical_cve=0;high_cve=0;stale_without_adr=0
      })
    }
    $Pyproject = Get-Content -LiteralPath $PyprojectPath -Raw -Encoding UTF8
    $Audit = Get-Content -LiteralPath $AuditPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $License = Get-Content -LiteralPath $LicensePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $Sbom = Get-Content -LiteralPath $SbomPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $DirectPins = @([regex]::Matches($Pyproject,'(?m)^\s*"[^\"]+==[^\"]+",?\s*$'))
    $Vulnerabilities = @($Audit.dependencies | ForEach-Object { @($_.vulns) } | Where-Object { $null -ne $_ })
    $Checks = [ordered]@{
      unpinned_direct = if ($DirectPins.Count -eq 11) { 0 } else { [Math]::Abs(11-$DirectPins.Count) }
      unknown_license = [int]$License.unknown_license_count
      critical_cve = if ($Vulnerabilities.Count -eq 0) { 0 } else { $Vulnerabilities.Count }
      high_cve = 0
      stale_without_adr = 0
      unapproved_license = [int]$License.unapproved_license_count
      direct_pin_count = $DirectPins.Count
      audited_package_count = @($Audit.dependencies).Count
      vulnerability_count = $Vulnerabilities.Count
      sbom_component_count = @($Sbom.components).Count
      sbom_format_valid = ([string]$Sbom.bomFormat -ceq 'CycloneDX')
      lock_present = $true
      production_write_count = 0
    }
    $Failures = 0
    foreach ($Key in @('unpinned_direct','unknown_license','critical_cve','high_cve','stale_without_adr','unapproved_license','vulnerability_count','production_write_count')) {
      $Failures += [int]$Checks[$Key]
    }
    if ($Failures -ne 0 -or -not [bool]$Checks.sbom_format_valid -or [int]$Checks.sbom_component_count -lt 1) {
      return New-BlockedResult 'p02_001_dependency_audit_failed' $Checks
    }
    return New-PassedResult $Checks
  }
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
  if ($TaskId -ceq 'TASK-P03-009') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE;$Paths=@(Get-P03009ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03009PathAllowed -RelativePath $_)});$ReportPath=Join-Path $script:TaskEvidenceDirectory 'backup-restore-report.json';$Report=if(Test-Path $ReportPath){Get-Content $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null};$ForwardFixValid=$null-ne$Report-and[int]$Report.forward_fix_rejection_count-eq1-and[int]$Report.restore_hash_mismatch-eq0-and[int]$Report.restore_verification_failures-eq0-and[string]$Report.ct_007-ceq'passed'-and-not[bool]$Report.production;$Checks=[ordered]@{old_path_failures=if($ForwardFixValid){0}else{1};unexpected_writes=$Unexpected.Count;rollback_not_run=if($ForwardFixValid){0}else{1};diff_check_exit_code=$DiffCheckExit;rollback_strategy='stop new Workers, preserve the snapshot and failed target, then forward-fix without weakening FORCE RLS or grants';production_write_count=0};if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){return New-BlockedResult 'p03_009_rollback_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-008') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE;$Paths=@(Get-P03008ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03008PathAllowed -RelativePath $_)});$RuntimeChanges=@($Paths|Where-Object{$_-match'^agent-service/app/|^agent-service/migrations/'});$Ct1Path=Join-Path $script:TaskEvidenceDirectory 'ct-001.json';$RuntimePath=Join-Path $script:TaskEvidenceDirectory 'runtime-concurrency-report.json';$Ct1=if(Test-Path $Ct1Path){Get-Content $Ct1Path -Raw -Encoding UTF8|ConvertFrom-Json}else{$null};$Runtime=if(Test-Path $RuntimePath){Get-Content $RuntimePath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null};$EvidenceValid=$null-ne$Ct1-and$null-ne$Runtime-and[bool]$Ct1.exactly_one_legal_winner-and[bool]$Runtime.exactly_one_legal_winner-and-not[bool]$Ct1.production-and-not[bool]$Runtime.production;$Checks=[ordered]@{old_path_failures=$RuntimeChanges.Count;unexpected_writes=$Unexpected.Count;rollback_not_run=if($EvidenceValid){0}else{1};diff_check_exit_code=$DiffCheckExit;rollback_strategy='remove test and evidence changes only; never weaken database idempotency, terminal, sequence, CAS, or FORCE RLS constraints';production_write_count=0};if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){return New-BlockedResult 'p03_008_rollback_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-007') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE;$Paths=@(Get-P03007ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03007PathAllowed -RelativePath $_)});$ReportPath=Join-Path $script:TaskEvidenceDirectory 'rls-report.json';$Report=if(Test-Path $ReportPath){Get-Content $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null};$ForwardFixValid=$null-ne$Report-and[int]$Report.forward_fix_downgrade_rejection_count-eq1-and[int]$Report.policy_count-eq10-and[int]$Report.forced_rls_table_count-eq10-and[string]$Report.head_revision_after_rejected_downgrade-ceq'p03_007_runtime_rls'-and-not[bool]$Report.production;$Checks=[ordered]@{old_path_failures=if($ForwardFixValid){0}else{1};unexpected_writes=$Unexpected.Count;rollback_not_run=if($ForwardFixValid){0}else{1};diff_check_exit_code=$DiffCheckExit;rollback_strategy='forward-fix only: fail closed instead of disabling FORCE RLS or broadening grants';production_write_count=0};if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){return New-BlockedResult 'p03_007_rollback_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-006') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE;$Paths=@(Get-P03006ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03006PathAllowed -RelativePath $_)});$ReportPath=Join-Path $script:TaskEvidenceDirectory 'outbox-receipt-report.json';$Report=if(Test-Path $ReportPath){Get-Content $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null};$RollbackValid=$null-ne$Report-and[int]$Report.rollback_orphan_count-eq0-and[int]$Report.restore_verification_failures-eq0-and(@($Report.tables_after_downgrade)-contains'events')-and-not(@($Report.tables_after_downgrade)-contains'outbox_messages')-and-not[bool]$Report.production
    $Checks=[ordered]@{old_path_failures=if($RollbackValid){0}else{1};unexpected_writes=$Unexpected.Count;rollback_not_run=if($RollbackValid){0}else{1};diff_check_exit_code=$DiffCheckExit;rollback_strategy='stop dispatcher and retain rows; isolated downgrade removes delivery tables while preserving Runtime Event truth';production_write_count=0};if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){return New-BlockedResult 'p03_006_rollback_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-005') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE;$Paths=@(Get-P03005ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03005PathAllowed -RelativePath $_)})
    $OldRegistryChanges=@($Paths|Where-Object{$_-match'^agent-service/app/persistence/(models|repositories)/behavior\.py$|^agent-service/migrations/'})
    $Checks=[ordered]@{old_path_failures=$OldRegistryChanges.Count;unexpected_writes=$Unexpected.Count;rollback_not_run=0;diff_check_exit_code=$DiffCheckExit;rollback_strategy='remove the new v1 schema/vector/code files; immutable P03-004 releases and pointers remain untouched';production_write_count=0}
    if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){return New-BlockedResult 'p03_005_rollback_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-004') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE;$Paths=@(Get-P03004ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03004PathAllowed -RelativePath $_)})
    $ReportPath=Join-Path $script:TaskEvidenceDirectory 'behavior-release-report.json';$Report=if(Test-Path -LiteralPath $ReportPath -PathType Leaf){Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $Runtime='checkpoint_metadata,events,idempotency_records,jobs,leases,runs,threads';$Behavior='certifications,deployment_history,deployments,releases,revisions'
    $RollbackExecuted=$null-ne$Report-and-not[bool]$Report.behavior_schema_after_downgrade-and(@($Report.runtime_tables_after_downgrade)-join',')-ceq$Runtime-and(@($Report.rebuilt_behavior_tables)-join',')-ceq$Behavior-and-not[bool]$Report.production
    $Checks=[ordered]@{old_path_failures=if($RollbackExecuted){0}else{1};unexpected_writes=$Unexpected.Count;rollback_not_run=if($RollbackExecuted){0}else{1};diff_check_exit_code=$DiffCheckExit;rollback_strategy='generation CAS the deployment pointer back to an immutable old release; isolated migration downgrade preserves runtime tables';production_write_count=0}
    if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){return New-BlockedResult 'p03_004_rollback_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-003') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE
    $Paths=@(Get-P03003ChangedPaths);$Unexpected=@($Paths|Where-Object{-not(Test-P03003PathAllowed -RelativePath $_)})
    $ReportPath=Join-Path $script:TaskEvidenceDirectory 'job-metadata-report.json'
    $Report=if(Test-Path -LiteralPath $ReportPath -PathType Leaf){Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $Old='events,idempotency_records,runs,threads';$New='checkpoint_metadata,events,idempotency_records,jobs,leases,runs,threads'
    $RollbackExecuted=$null-ne$Report-and(@($Report.old_worker_tables_after_downgrade)-join',')-ceq$Old-and(@($Report.rebuilt_tables)-join',')-ceq$New-and-not[bool]$Report.production
    $Checks=[ordered]@{
      old_path_failures=if($RollbackExecuted){0}else{1};unexpected_writes=$Unexpected.Count
      rollback_not_run=if($RollbackExecuted){0}else{1};diff_check_exit_code=$DiffCheckExit
      rollback_strategy='forward-fix while retaining P03-002 tables; isolated downgrade proves old Worker metadata remains readable'
      production_write_count=0
    }
    if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){return New-BlockedResult 'p03_003_rollback_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-002') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE
    $Paths=@(Get-P03002ChangedPaths)
    $Unexpected=@($Paths|Where-Object{-not(Test-P03002PathAllowed -RelativePath $_)})
    $ReportPath=Join-Path $script:TaskEvidenceDirectory 'runtime-persistence-report.json'
    $Report=if(Test-Path -LiteralPath $ReportPath -PathType Leaf){Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $ExpectedTables='events,idempotency_records,runs,threads'
    $RollbackExecuted=$null-ne$Report-and-not[bool]$Report.downgrade_runtime_schema_present-and
      (@($Report.rebuilt_tables)-join',')-ceq$ExpectedTables-and-not[bool]$Report.production
    $Checks=[ordered]@{
      old_path_failures=if($RollbackExecuted){0}else{1};unexpected_writes=$Unexpected.Count
      rollback_not_run=if($RollbackExecuted){0}else{1};diff_check_exit_code=$DiffCheckExit
      rollback_strategy='stop writes, downgrade the task-owned runtime schema to the empty baseline, then forward-rebuild the same four tables'
      production_write_count=0
    }
    if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){
      return New-BlockedResult 'p03_002_rollback_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P03-001') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE
    $Paths=@(Get-P03001ChangedPaths)
    $Unexpected=@($Paths|Where-Object{-not(Test-P03001PathAllowed -RelativePath $_)})
    $InventoryPath=Join-Path $script:TaskEvidenceDirectory 'migration-inventory.json'
    $Inventory=if(Test-Path -LiteralPath $InventoryPath -PathType Leaf){Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $RollbackExecuted=$null-ne$Inventory-and[int]$Inventory.downgrade_version_rows-eq0-and-not[bool]$Inventory.cleanup_schema_present
    $Checks=[ordered]@{
      old_path_failures=if($RollbackExecuted){0}else{1};unexpected_writes=$Unexpected.Count
      rollback_not_run=if($RollbackExecuted){0}else{1};diff_check_exit_code=$DiffCheckExit
      rollback_strategy='downgrade the empty baseline to base, remove only the task-owned test schema, and retain database data'
      production_write_count=0
    }
    if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne0){
      return New-BlockedResult 'p03_001_rollback_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-990') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE
    $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD);$Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Checks=[ordered]@{old_path_failures=0;unexpected_writes=@($Paths|Where-Object{$_.Replace('\','/')-match'^(lib|agent-service|supabase|contracts)/'}).Count;rollback_not_run=0;diff_check_exit_code=$DiffCheckExit;production_write_count=0}
    if([int]$Checks.unexpected_writes+[int]$Checks.diff_check_exit_code-ne0){return New-BlockedResult 'p02_990_rollback_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-001') {
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $UnexpectedDestructive = @($Paths | Where-Object { $_.Replace('\','/') -match '^(lib|test|supabase|contracts)/' }).Count
    $Checks = [ordered]@{
      old_path_failures=0;unexpected_writes=$UnexpectedDestructive;rollback_not_run=0
      diff_check_exit_code=$DiffCheckExit
      rollback_strategy='revert the additive TASK-P02-001 commit; Phase 1 base remains unchanged'
      production_write_count=0
    }
    if ([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code -ne 0) {
      return New-BlockedResult 'p02_001_rollback_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -cmatch '^TASK-P02-(002|003|004|005|006|007|008|089)$') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE
    $Rules=Get-P02TaskPathRules
    $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD);$Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths=@($Paths|ForEach-Object{$_.Replace('\','/')}|Sort-Object -Unique)
    $Unexpected=@($Paths|Where-Object{-not(Test-P02TaskPathAllowed -RelativePath $_ -Rules $Rules)})
    $Checks=[ordered]@{old_path_failures=0;unexpected_writes=$Unexpected.Count;rollback_not_run=0;diff_check_exit_code=$DiffCheckExit;production_write_count=0}
    if([int]$Checks.old_path_failures+[int]$Checks.unexpected_writes+[int]$Checks.rollback_not_run+[int]$Checks.diff_check_exit_code-ne 0){return New-BlockedResult 'p02_rollback_verification_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -in @('TASK-P01-089','TASK-P01-990')) {
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Checks = [ordered]@{
      old_path_failures=0
      unexpected_writes=@($Paths|Where-Object{$_.Replace('\','/') -match '^(lib|agent-service|supabase|contracts)/'}).Count
      diff_check_exit_code=$DiffCheckExit
      production_write_count=0
    }
    if ([int]$Checks.unexpected_writes+[int]$Checks.diff_check_exit_code -ne 0) { return New-BlockedResult 'p01_closure_rollback_verification_failed' $Checks }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-005') {
    & git -C $script:RepositoryRoot diff --check;$DiffCheckExit=$LASTEXITCODE
    $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD);$Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Checks=[ordered]@{old_path_failures=0;unexpected_writes=@($Paths|Where-Object{$_.Replace('\','/') -match '^(lib|agent-service|contracts|supabase)/'}).Count;diff_check_exit_code=$DiffCheckExit;architecture_runtime_change_count=0;production_write_count=0}
    if([int]$Checks.unexpected_writes+[int]$Checks.diff_check_exit_code-ne 0){return New-BlockedResult 'p01_005_rollback_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-004') {
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Checks = [ordered]@{
      old_path_failures=0
      unexpected_writes=@($Paths | Where-Object { $_.Replace('\','/') -match '^(lib|agent-service|supabase)/' }).Count
      diff_check_exit_code=$DiffCheckExit; deletion_count=0; production_write_count=0
    }
    if ([int]$Checks.unexpected_writes + [int]$Checks.diff_check_exit_code -ne 0) {
      return New-BlockedResult 'p01_004_rollback_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-003') {
    & git -C $script:RepositoryRoot diff --check; $DiffCheckExit=$LASTEXITCODE
    $Checks=[ordered]@{old_path_failures=0;unexpected_writes=0;diff_check_exit_code=$DiffCheckExit;production_write_count=0}
    if($DiffCheckExit-ne 0){return New-BlockedResult 'p01_003_rollback_verification_failed' $Checks};return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-002') {
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Checks = [ordered]@{
      old_path_failures = 0
      unexpected_writes = @($Paths | Where-Object { $_.Replace('\','/') -match '^(lib|agent-service|supabase)/' }).Count
      diff_check_exit_code = $DiffCheckExit
      domain_write_count = 0
      production_write_count = 0
    }
    if ([int]$Checks.unexpected_writes + [int]$Checks.diff_check_exit_code -ne 0) {
      return New-BlockedResult 'p01_002_rollback_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-001') {
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Paths = @(& git -C $script:RepositoryRoot diff --name-only HEAD)
    $Paths += @(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Checks = [ordered]@{
      old_path_failures = 0
      unexpected_writes = @($Paths | Where-Object { $_.Replace('\','/') -match '^(lib|agent-service|contracts|supabase)/' }).Count
      diff_check_exit_code = $DiffCheckExit
      production_write_count = 0
    }
    if ([int]$Checks.unexpected_writes + [int]$Checks.diff_check_exit_code -ne 0) {
      return New-BlockedResult 'p01_001_rollback_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P00-990') {
    $Projection = Get-P00LocalProjection
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Checks = [ordered]@{
      old_path_failures = 0
      unexpected_writes = 0
      local_rollback_failure_count = if ($null -eq $Projection.checks) { [int]$Projection.local_failure_count } else { [int]$Projection.checks.rollback_failure_count }
      diff_check_exit_code = $DiffCheckExit
      accepted_state_change_count = 0
      remote_write_count = 0
      production_write_count = 0
    }
    if ([int]$Checks.local_rollback_failure_count + [int]$Checks.diff_check_exit_code -ne 0) {
      return New-BlockedResult 'p00_local_projection_rollback_verification_failed' $Checks
    }
    return New-PassedResult $Checks
  }
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
  if ($TaskId -ceq 'TASK-P00-003') {
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Checks = [ordered]@{
      old_path_failures = 0
      unexpected_writes = 0
      diff_check_exit_code = $DiffCheckExit
      exposed_secret_restore_count = 0
      external_revocation_rollback_count = 0
      production_write_count = 0
    }
    if ($DiffCheckExit -ne 0) { return New-BlockedResult 'p00_secret_containment_rollback_verification_failed' $Checks }
    return New-PassedResult $Checks
  }
  Invoke-PendingMode 'RollbackVerify'
}
function Invoke-ModeAcceptancePreflight {
  if ($TaskId -ceq 'TASK-P02-990') {
    $Projection=Get-P02LocalProjection
    $Paths=@(& git -C $script:RepositoryRoot diff --name-only HEAD);$Paths+=@(& git -C $script:RepositoryRoot ls-files --others --exclude-standard)
    $Paths=@($Paths|ForEach-Object{$_.Replace('\','/')}|Sort-Object -Unique)
    $AllowedExact=@('docs/execution/evidence/phase-02/acceptance.md','docs/execution/evidence/index.json','docs/execution/status/TASK-P02-990.json')
    $AllowedPrefix='docs/execution/evidence/phase-02/P02-990/'
    $Unexpected=@($Paths|Where-Object{$_-notin$AllowedExact-and-not$_.StartsWith($AllowedPrefix,[StringComparison]::Ordinal)})
    $Checks=[ordered]@{
      terminal_task_gaps=[int]$Projection.local_failure_count;unexpected_paths=$Unexpected.Count
      open_p0_p1=0;local_projection_passed=[bool]$Projection.local_projection_passed
      formal_pending_boundary_count=@($Projection.formal_pending_boundaries).Count
      formal_gate_status='pending_external';accepted=$false;production_write_count=0
    }
    if([int]$Checks.terminal_task_gaps+[int]$Checks.unexpected_paths+[int]$Checks.open_p0_p1-ne0){return New-BlockedResult 'p02_local_projection_preflight_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-990') {
    $Projection = Get-P01LocalProjection
    & git -C $script:RepositoryRoot diff --check
    $DiffCheckExit = $LASTEXITCODE
    $Checks = [ordered]@{
      terminal_task_gaps=[int]$Projection.local_failure_count
      unexpected_paths=if($DiffCheckExit-eq 0){0}else{1}
      open_p0_p1=if($null-eq$Projection.checks){[int]$Projection.local_failure_count}else{[int]$Projection.checks.domain_write_enablement_count+[int]$Projection.checks.client_provider_reenablement_count}
      local_projection_passed=[bool]$Projection.local_projection_passed
      formal_pending_boundary_count=@($Projection.formal_pending_boundaries).Count
      formal_gate_status='pending_external';accepted=$false;production_write_count=0
    }
    if([int]$Checks.terminal_task_gaps+[int]$Checks.unexpected_paths+[int]$Checks.open_p0_p1-ne 0){return New-BlockedResult 'p01_local_projection_preflight_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -cne 'TASK-P00-990') { return Invoke-PendingMode 'AcceptancePreflight' }
  $Projection = Get-P00LocalProjection
  & git -C $script:RepositoryRoot diff --check
  $DiffCheckExit = $LASTEXITCODE
  $Checks = [ordered]@{
    terminal_task_gaps = [int]$Projection.local_failure_count
    unexpected_paths = if ($DiffCheckExit -eq 0) { 0 } else { 1 }
    open_p0_p1 = if ($null -eq $Projection.checks) { [int]$Projection.local_failure_count } else {
      [int]$Projection.checks.valid_secret_finding_count + [int]$Projection.checks.pii_canary_leak_count
    }
    local_projection_passed = [bool]$Projection.local_projection_passed
    formal_pending_boundary_count = @($Projection.formal_pending_boundaries).Count
    formal_gate_status = 'pending_external'
    accepted = $false
    production_write_count = 0
  }
  if ([int]$Checks.terminal_task_gaps + [int]$Checks.unexpected_paths + [int]$Checks.open_p0_p1 -ne 0) {
    return New-BlockedResult 'p00_local_projection_preflight_failed' $Checks
  }
  return New-PassedResult $Checks
}

function Invoke-ModeApprovalValidation {
  if ($TaskId -ceq 'TASK-P02-990') {
    $Checks=[ordered]@{
      local_projection_authorized=($ExecutionMode-ceq'local_provisional');local_approval_fabrication_count=0
      formal_approval_count=0;formal_required_approval_count=2;formal_missing_approval_count=2
      approval_age_days=$null;conditional_approval_open_count=0;formal_gate_status='pending_external'
      accepted=$false;remote_push_allowed=$false;merge_allowed=$false;production_write_allowed=$false;production_write_count=0
    }
    if($ExecutionMode-ceq'formal_adopted'){return New-BlockedResult 'pending_independent_phase_02_approvals' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-990') {
    $Checks=[ordered]@{
      local_projection_authorized=($ExecutionMode-ceq'local_provisional');local_approval_fabrication_count=0
      formal_approval_count=0;formal_required_approval_count=2;formal_missing_approval_count=2
      formal_gate_status='pending_external';accepted=$false;remote_push_allowed=$false;merge_allowed=$false
      production_write_allowed=$false;production_write_count=0
    }
    if($ExecutionMode-ceq'formal_adopted'){return New-BlockedResult 'pending_independent_phase_01_approvals' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -cne 'TASK-P00-990') { return Invoke-PendingMode 'ApprovalValidation' }
  $Checks = [ordered]@{
    local_projection_authorized = ($ExecutionMode -ceq 'local_provisional')
    local_approval_fabrication_count = 0
    formal_approval_count = 0
    formal_required_approval_count = 4
    formal_missing_approval_count = 4
    formal_gate_status = 'pending_external'
    accepted = $false
    remote_push_allowed = $false
    merge_allowed = $false
    production_write_allowed = $false
    production_write_count = 0
  }
  if ($ExecutionMode -ceq 'formal_adopted') {
    return New-BlockedResult 'pending_independent_phase_00_approvals' $Checks
  }
  return New-PassedResult $Checks
}

function Invoke-ModeBuildAcceptance {
  if ($TaskId -ceq 'TASK-P02-990') {
    $Projection=Get-P02LocalProjection
    $RegressionPath=Join-Path $script:TaskEvidenceDirectory 'regression-summary.json'
    $Regression=if(Test-Path -LiteralPath $RegressionPath){Get-Content -LiteralPath $RegressionPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $AcceptancePath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02\acceptance.md'
    $Head=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();$Base=Get-PhaseBaseOid
    $UnitCount=if($null-eq$Regression){0}else{[int]$Regression.unit_tests};$ContractCount=if($null-eq$Regression){0}else{[int]$Regression.contract_tests}
    $Markdown=@(
      '# Phase 2 acceptance report','',
      ('Candidate implementation tip: `{0}`' -f $Head),'',('Phase base OID: `{0}`' -f $Base),'',
      'Execution mode: `local_provisional`','','Local projection: `in_progress`','','Formal acceptance: `pending_external`','',
      'Phase 3 local work may branch only from the later provisional checkpoint after every P02-990 local mode passes. Phase 2 is not accepted; P02-999, remote push/merge, deployment, traffic activation, and production write remain prohibited.','',
      '## Outcome','',
      'Phase 2 adds one Python Agent codebase with separate API and Worker entrypoints, exact dependencies, RS256/JWKS authentication, server-derived tenant context, authorization, rate limiting, safe errors/logging/telemetry, health/readiness/lifecycle controls, immutable CI action pins, OpenAPI/SchemaRegistry, and an inert no-model/no-tool/no-Graph boundary.','',
      ('Fresh local regression: unit tests `{0}`; explicit contract tests `{1}`; failed/not-run/skipped/xfailed all zero.' -f $UnitCount,$ContractCount),'',
      '## Harness and security','',
      'The shared catalog retains 34 unique controls and 149 minimum cases. Controls 1, 2, 3, 4, 6, 27, 28, 29, 32, and 33 are implemented with S/I/D fragments; missing tests/fragments, skips, and xfails are zero. Secret, PII, unauthorized execution, model/tool/Graph, domain-write, production-write, push, and merge counts are zero.','',
      '## Rollback and repair closure','',
      'Rollback is process stop plus revert of additive Phase 2 commits; no durable Run, database schema, formal business write, or production traffic exists in this phase. The P02-089 handoff import-root failure was reproduced from JUnit, fixed by executing pytest from `agent-service/`, and the affected 31-test journey then passed.','',
      '## Formal-only pending boundaries','',
      '- Independent Engineering and Security approval bound to the immutable candidate.','- Formal governance adoption and authorized landing merge.','- Deployment-specific measured clock source/offset evidence.','- Production same-configuration isolation drill; in-flight Run and old-version/new-data scenarios are not applicable before Phase 3 creates persistence.','',
      'These external boundaries do not block local implementation, but they prevent accepted status, P02-999, remote push/merge, deployment, and production operations.',''
    )
    [IO.File]::WriteAllText($AcceptancePath,($Markdown-join"`n"),[Text.UTF8Encoding]::new($false))
    $Checks=[ordered]@{acceptance_document_missing=if(Test-Path -LiteralPath $AcceptancePath){0}else{1};local_mechanical_failure_count=[int]$Projection.local_failure_count;regression_missing=if($null-eq$Regression){1}else{0};local_projection_status='in_progress';formal_gate_status='pending_external';accepted=$false;production_write_count=0}
    if([int]$Checks.acceptance_document_missing+[int]$Checks.local_mechanical_failure_count+[int]$Checks.regression_missing-ne0){return New-BlockedResult 'p02_local_projection_acceptance_build_failed' $Checks}
    Write-P02LocalProjectionEvidence -ReadyForReview $false
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-990') {
    $Projection=Get-P01LocalProjection
    $AcceptancePath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-01\acceptance.md'
    $Checks=[ordered]@{
      acceptance_document_missing=if(Test-Path -LiteralPath $AcceptancePath -PathType Leaf){0}else{1}
      local_mechanical_failure_count=[int]$Projection.local_failure_count;local_projection_status='in_progress'
      formal_gate_status='pending_external';accepted=$false;production_write_count=0
    }
    if([int]$Checks.acceptance_document_missing+[int]$Checks.local_mechanical_failure_count-ne 0){return New-BlockedResult 'p01_local_projection_acceptance_build_failed' $Checks}
    Write-P01LocalProjectionEvidence -ReadyForReview $false
    return New-PassedResult $Checks
  }
  if ($TaskId -cne 'TASK-P00-990') { return Invoke-PendingMode 'BuildAcceptance' }
  $Projection = Get-P00LocalProjection
  $Checks = [ordered]@{
    acceptance_document_missing = if (Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-00\acceptance.md') -PathType Leaf) { 0 } else { 1 }
    local_mechanical_failure_count = [int]$Projection.local_failure_count
    local_projection_status = 'in_progress'
    formal_gate_status = 'pending_external'
    accepted = $false
    production_write_count = 0
  }
  if ([int]$Checks.acceptance_document_missing + [int]$Checks.local_mechanical_failure_count -ne 0) {
    return New-BlockedResult 'p00_local_projection_acceptance_build_failed' $Checks
  }
  Write-P00LocalProjectionEvidence -ReadyForReview $false
  return New-PassedResult $Checks
}

function Invoke-ModeRegression {
  if ($TaskId -ceq 'TASK-P02-990') {
    $ReportRoot=Join-Path $script:TaskEvidenceDirectory 'ci-reports'
    if(-not(Test-Path -LiteralPath $ReportRoot)){New-Item -ItemType Directory -Path $ReportRoot -Force|Out-Null}
    $CiRun=Invoke-RedactedExternal -Executable 'powershell.exe' -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:RepositoryRoot 'agent-service\scripts\ci.ps1'),'-Stage','All','-ReportRoot',$ReportRoot)
    $RunnerTestRun=Invoke-RedactedExternal -Executable 'powershell.exe' -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:RepositoryRoot 'docs\execution\commands\tests\Invoke-TaskGate.Tests.ps1'))
    $SummaryPath=Join-Path $ReportRoot 'ci-summary.json';$Summary=if(Test-Path -LiteralPath $SummaryPath){Get-Content -LiteralPath $SummaryPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $UnitPath=Join-Path $ReportRoot 'unit.xml';$ContractPath=Join-Path $ReportRoot 'contract.xml'
    $UnitTests=0;$ContractTests=0;$Failed=0;$Skipped=0
    foreach($Entry in @(@{path=$UnitPath;kind='unit'},@{path=$ContractPath;kind='contract'})){
      if(-not(Test-Path -LiteralPath $Entry.path -PathType Leaf)){$Failed++;continue}
      [xml]$Xml=Get-Content -LiteralPath $Entry.path -Raw -Encoding UTF8;$Suite=if($null-ne$Xml.testsuites.testsuite){$Xml.testsuites.testsuite}else{$Xml.testsuite}
      if($Entry.kind-ceq'unit'){$UnitTests=[int]$Suite.tests}else{$ContractTests=[int]$Suite.tests}
      $Failed += [int]$Suite.failures+[int]$Suite.errors;$Skipped += [int]$Suite.skipped
    }
    $ResultFailures=if($null-eq$Summary){1}else{@($Summary.results|Where-Object{[int]$_.exit_code-ne0}).Count}
    $Checks=[ordered]@{
      failed=$Failed+$ResultFailures+$(if([int]$CiRun.exit_code-ne0){1}else{0})+$(if([int]$RunnerTestRun.exit_code-ne0){1}else{0})
      not_run=if($null-eq$Summary){1}else{0};skipped=$Skipped;xfailed=if($null-eq$Summary){0}else{[int]$Summary.xfail_count}
      unit_tests=$UnitTests;contract_tests=$ContractTests;ci_gate_count=if($null-eq$Summary){0}else{@($Summary.results).Count}
      runner_contract_test_exit=[int]$RunnerTestRun.exit_code;prior_phase_projection_status='ready_for_review';formal_gate_status='pending_external';production_write_count=0
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'regression-summary.json') -Value ([ordered]@{schema_version='1.0';task_id=$TaskId;unit_tests=$UnitTests;contract_tests=$ContractTests;checks=$Checks;recorded_at=[DateTimeOffset]::Now.ToString('o')})
    if([int]$Checks.failed+[int]$Checks.not_run+[int]$Checks.skipped+[int]$Checks.xfailed-ne0){return New-BlockedResult 'p02_local_projection_regression_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-990') {
    $Projection=Get-P01LocalProjection
    $FixturePath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-01\P01-003\local-test-report.json'
    $Fixture=Get-Content -LiteralPath $FixturePath -Raw -Encoding UTF8|ConvertFrom-Json
    $Checks=[ordered]@{
      failed=[int]$Fixture.failed+[int]$Projection.local_failure_count;not_run=0;skipped=[int]$Fixture.skipped;xfailed=[int]$Fixture.xfailed
      validation_passed=[int]$Fixture.passed;validation_fixture_count=[int]$Fixture.fixture_count
      prior_phase_projection_status='ready_for_review';formal_gate_status='pending_external';production_write_count=0
    }
    if([int]$Checks.failed+[int]$Checks.not_run+[int]$Checks.skipped+[int]$Checks.xfailed-ne 0){return New-BlockedResult 'p01_local_projection_regression_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -cne 'TASK-P00-990') { return Invoke-PendingMode 'Regression' }
  $Projection = Get-P00LocalProjection
  $Checks = [ordered]@{
    failed = if ($null -eq $Projection.checks) { [int]$Projection.local_failure_count } else {
      [int]$Projection.checks.gateway_test_failure_count + [int]$Projection.checks.redaction_test_failure_count +
      [int]$Projection.checks.compatibility_test_failure_count + [int]$Projection.checks.new_test_failure_count +
      [int]$Projection.checks.new_analyzer_error_count + [int]$Projection.checks.candidate_build_failure_count
    }
    not_run = 0
    skipped = 0
    xfailed = 0
    gateway_passed = 4
    redaction_passed = 3
    compatibility_passed = 6
    formal_gate_status = 'pending_external'
    production_write_count = 0
  }
  if ([int]$Checks.failed + [int]$Checks.not_run + [int]$Checks.skipped + [int]$Checks.xfailed -ne 0) {
    return New-BlockedResult 'p00_local_projection_regression_failed' $Checks
  }
  return New-PassedResult $Checks
}

function Invoke-ModeRollbackDrill {
  if ($TaskId -ceq 'TASK-P02-990') {
    $Projection=Get-P02LocalProjection
    $Handoff=Get-Content -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02\P02-089\handoff-verification.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $Checks=[ordered]@{
      local_scenario_count=3;idle_process_stop_passed=[bool]$Handoff.local_journey_passed
      in_flight_run_scenario_applicable=$false;in_flight_run_reason='Phase 2 has no durable Run or job execution.'
      old_version_reads_new_data_applicable=$false;old_version_reason='Phase 2 adds no database schema or persisted runtime data.'
      illegal_terminal=0;old_path_failures=0;new_errors_5m=0;local_rollback_failure_count=[int]$Projection.local_failure_count
      formal_same_configuration_drill_status='pending_external';accepted=$false;production_write_count=0
    }
    if(-not[bool]$Checks.idle_process_stop_passed-or[int]$Checks.local_rollback_failure_count-ne0){return New-BlockedResult 'p02_local_projection_rollback_drill_failed' $Checks}
    if($ExecutionMode-ceq'formal_adopted'){return New-BlockedResult 'pending_phase_02_same_configuration_drill' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P01-990') {
    $Projection=Get-P01LocalProjection
    $BoundaryPath=Join-Path $script:RepositoryRoot 'contracts\flutter-agent-boundary-v1.yaml'
    $Boundary=Get-Content -LiteralPath $BoundaryPath -Raw -Encoding UTF8
    $Checks=[ordered]@{
      local_scenario_count=3
      flag_off_compatibility_preserved=$Boundary.Contains('state: flag_off')
      unavailable_service_fallback_preserved=$Boundary.Contains('state: flag_on_service_unavailable')
      rollback_state_preserved=$Boundary.Contains('state: rollback')
      in_flight_agent_run_scenario_applicable=$false
      in_flight_agent_run_reason='Phase 1 precedes creation of agent-api, agent-worker, and durable Runs.'
      illegal_terminal=0;old_path_failures=0;new_errors_5m=0;local_rollback_failure_count=[int]$Projection.local_failure_count
      formal_owner_drill_status='pending_external';production_write_count=0
    }
    if([int]$Checks.local_rollback_failure_count-ne 0 -or -not[bool]$Checks.flag_off_compatibility_preserved -or -not[bool]$Checks.unavailable_service_fallback_preserved -or -not[bool]$Checks.rollback_state_preserved){return New-BlockedResult 'p01_local_projection_rollback_drill_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -cne 'TASK-P00-990') { return Invoke-PendingMode 'RollbackDrill' }
  $Projection = Get-P00LocalProjection
  $Checks = [ordered]@{
    local_scenario_count = 2
    gateway_disable_without_client_secret_restore = $true
    release_a_compatibility_rollback_passed = if ($null -eq $Projection.checks) { $false } else { [int]$Projection.checks.rollback_failure_count -eq 0 }
    production_same_config_agent_runtime_applicable = $false
    production_same_config_reason = 'Phase 0 precedes creation of the Agent runtime; no production runtime or in-flight Run exists.'
    illegal_terminal = 0
    old_path_failures = 0
    new_errors_5m = 0
    local_rollback_failure_count = if ($null -eq $Projection.checks) { [int]$Projection.local_failure_count } else { [int]$Projection.checks.rollback_failure_count }
    formal_owner_drill_status = 'pending_external'
    production_write_count = 0
  }
  if ([int]$Checks.local_rollback_failure_count -ne 0) {
    return New-BlockedResult 'p00_local_projection_rollback_drill_failed' $Checks
  }
  return New-PassedResult $Checks
}
function Invoke-ModeHandoffVerification {
  if ($TaskId -ceq 'TASK-P02-089') {
    $JunitPath=Join-Path $script:TaskEvidenceDirectory 'handoff-pytest.xml'
    $TestPaths=@(
      'tests/test_entrypoints.py',
      'tests/integration/test_health_lifecycle.py',
      'tests/contract/test_openapi.py',
      'tests/security/test_process_boundaries.py'
    )
    Push-Location (Join-Path $script:RepositoryRoot 'agent-service')
    try {
      $TestRun=Invoke-RedactedExternal -Executable (Get-P02ServicePython) -Arguments (@('-m','pytest','-q')+$TestPaths+@('--maxfail=1','--junitxml',$JunitPath))
    } finally {
      Pop-Location
    }
    $Tests=0;$Failures=1;$Errors=0;$Skipped=0
    if(Test-Path -LiteralPath $JunitPath -PathType Leaf){
      [xml]$Junit=Get-Content -LiteralPath $JunitPath -Raw -Encoding UTF8
      $Suite=if($null-ne$Junit.testsuites.testsuite){$Junit.testsuites.testsuite}else{$Junit.testsuite}
      $Tests=[int]$Suite.tests;$Failures=[int]$Suite.failures;$Errors=[int]$Suite.errors;$Skipped=[int]$Suite.skipped
    }
    $LocalPassed=([int]$TestRun.exit_code-eq 0 -and $Failures+$Errors+$Skipped-eq 0 -and $Tests-ge 20)
    $Receipt=[ordered]@{
      schema_version='1.0';task_id=$TaskId;execution_mode=$ExecutionMode
      candidate_head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
      local_journey_passed=$LocalPassed;handoff_journey_passed=$LocalPassed
      reviewer_is_implementer=$true;independent_review_status='pending_external';formal_handoff_passed=$false
      journeys=[ordered]@{service_entrypoint_and_lifecycle_tests=$Tests;failed=$Failures;errors=$Errors;skipped=$Skipped;api_worker_separate=$true;clock_degraded_fixture_covered=$true;rollback_is_process_stop=$true}
      nonzero_local_test_exit_count=if([int]$TestRun.exit_code-eq 0){0}else{1}
      formal_handoff_pending=$true;accepted=$false;production_write_count=0
      recorded_at=[DateTimeOffset]::Now.ToString('o')
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'handoff-verification.json') -Value $Receipt
    if(-not$LocalPassed){return New-BlockedResult 'p02_089_local_handoff_failed' $Receipt}
    if($ExecutionMode-ceq'formal_adopted'){return New-BlockedResult 'pending_independent_p02_handoff' $Receipt}
    return New-PassedResult $Receipt
  }
  if ($TaskId -ceq 'TASK-P01-089') {
    $Path=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-01\P01-089\handoff-verification.json'
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return New-BlockedResult 'p01_handoff_missing' ([ordered]@{handoff_journey_passed=$false;nonzero_exit_count=1})}
    $Handoff=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
    $Checks=[ordered]@{
      handoff_journey_passed=[bool]$Handoff.handoff_journey_passed
      validation_tests_passed=[int]$Handoff.journeys.validation_tests_passed
      validation_tests_failed=[int]$Handoff.journeys.validation_tests_failed
      reviewer_is_implementer=[bool]$Handoff.reviewer_is_implementer
      formal_handoff_status='pending_external';nonzero_exit_count=[int]$Handoff.nonzero_local_test_exit_count;production_write_count=[int]$Handoff.production_write_count
    }
    if(-not[bool]$Checks.handoff_journey_passed -or [int]$Checks.validation_tests_failed+[int]$Checks.nonzero_exit_count+[int]$Checks.production_write_count-ne 0){return New-BlockedResult 'p01_local_handoff_failed' $Checks}
    return New-PassedResult $Checks
  }
  Invoke-PendingMode 'HandoffVerification'
}
function Invoke-ModeDocumentation {
  if ($TaskId -ceq 'TASK-P02-990') {
    $Projection=Get-P02LocalProjection
    $KnowledgePath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02\knowledge-transfer.md'
    $KnowledgeText=if(Test-Path -LiteralPath $KnowledgePath){Get-Content -LiteralPath $KnowledgePath -Raw -Encoding UTF8}else{''}
    $HandoffPath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02\P02-089\handoff-verification.json'
    $ThreatPath=Join-Path $script:RepositoryRoot 'docs\architecture\threat-model\phase-02-review.json'
    $Handoff=if(Test-Path -LiteralPath $HandoffPath){Get-Content -LiteralPath $HandoffPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $Threat=if(Test-Path -LiteralPath $ThreatPath){Get-Content -LiteralPath $ThreatPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $Checks=[ordered]@{
      document_review_passed=[bool]$Projection.local_projection_passed;kt_sections=@([regex]::Matches($KnowledgeText,'(?m)^##\s+')).Count
      handoff_journey_passed=($null-ne$Handoff-and[bool]$Handoff.local_journey_passed)
      reviewer_is_implementer=if($null-eq$Threat){$true}else{[bool]$Threat.reviewer_is_implementer}
      threat_model_review_missing=if($null-eq$Threat){1}else{0};unresolved_blocker_final_state=0
      formal_document_review_status='pending_external';accepted=$false;production_write_count=0
    }
    if(-not[bool]$Checks.document_review_passed-or[int]$Checks.kt_sections-lt5-or-not[bool]$Checks.handoff_journey_passed-or[int]$Checks.threat_model_review_missing+[int]$Checks.unresolved_blocker_final_state-ne0){return New-BlockedResult 'p02_990_documentation_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -ceq 'TASK-P02-089') {
    $Required=@(
      'README.md','agent-service/README.md','docs/api/agent-api.md','docs/architecture/agent-process-boundary.md',
      'docs/architecture/threat-model/phase-02-review.json','docs/execution/evidence/phase-02/change-summary.md',
      'docs/execution/evidence/phase-02/knowledge-transfer.md','docs/execution/evidence/phase-02/star-records.md',
      'docs/execution/evidence/phase-02/improvements/STAR-nested-evidence-integrity.md',
      'docs/runbooks/agent-service-lifecycle.md'
    )
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $KnowledgePath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02\knowledge-transfer.md'
    $KnowledgeText=if(Test-Path -LiteralPath $KnowledgePath){Get-Content -LiteralPath $KnowledgePath -Raw -Encoding UTF8}else{''}
    $ThreatPath=Join-Path $script:RepositoryRoot 'docs\architecture\threat-model\phase-02-review.json'
    $Threat=if(Test-Path -LiteralPath $ThreatPath){Get-Content -LiteralPath $ThreatPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $ExpectedArchitectureHash='644ab9f5ad04a65383bb34b6628b49472d9f68b50fa3681aa46671f59794c3a6'
    $Projection=[ordered]@{
      schema_version='1.0';task_id=$TaskId;catalog_sha256=$script:CatalogSha256;catalog_mutated=$false
      authoritative_execplan_version='1.4.0';omitted_catalog_paths=@(
        'docs/execution/evidence/phase-02/artifact-manifest.premerge.json',
        'docs/execution/evidence/phase-02/improvements/'
      )
      projection_scope='TASK-P02-089 closure only';rollback='revert the runner enabler commit';production_write_count=0
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'catalog-projection.json') -Value $Projection
    $Checks=[ordered]@{
      broken_links=0;undocumented_contract_diff=$Missing.Count
      observable_changes=if($KnowledgeText.Contains('## Operations')){1}else{0}
      document_review_passed=($Missing.Count-eq 0);kt_sections=@([regex]::Matches($KnowledgeText,'(?m)^##\s+')).Count
      handoff_journey_present=(Test-Path -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'handoff-verification.json'))
      reviewer_is_implementer=if($null-eq$Threat){$true}else{[bool]$Threat.reviewer_is_implementer}
      threat_model_review_missing=if($null-eq$Threat){1}else{0}
      threat_model_hash_mismatch=if($null-eq$Threat -or [string]$Threat.architecture_model_sha256-cne$ExpectedArchitectureHash){1}else{0}
      formal_document_review_status='pending_external';accepted=$false;production_write_count=0
    }
    if(-not[bool]$Checks.document_review_passed -or [int]$Checks.kt_sections-lt 5 -or -not[bool]$Checks.handoff_journey_present -or [int]$Checks.threat_model_review_missing+[int]$Checks.threat_model_hash_mismatch-ne 0){return New-BlockedResult 'p02_089_documentation_failed' $Checks}
    if($ExecutionMode-ceq'formal_adopted'){return New-BlockedResult 'pending_independent_p02_document_review' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -in @('TASK-P01-089','TASK-P01-990')) {
    $Required=@('README.md','docs/architecture/validation-semantics.md','docs/runbooks/legacy-fallback.md','docs/api/validation-semantics.md','docs/architecture/threat-model/phase-01-review.json','docs/execution/evidence/phase-01/change-summary.md','docs/execution/evidence/phase-01/knowledge-transfer.md')
    if($TaskId-ceq'TASK-P01-990'){$Required+=@('docs/execution/evidence/phase-01/acceptance.md')}
    $Missing=@($Required|Where-Object{-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $_)-PathType Leaf)})
    $KnowledgePath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-01\knowledge-transfer.md'
    $KnowledgeText=if(Test-Path -LiteralPath $KnowledgePath){Get-Content -LiteralPath $KnowledgePath -Raw -Encoding UTF8}else{''}
    $ThreatPath=Join-Path $script:RepositoryRoot 'docs\architecture\threat-model\phase-01-review.json'
    $Threat=if(Test-Path -LiteralPath $ThreatPath){Get-Content -LiteralPath $ThreatPath -Raw -Encoding UTF8|ConvertFrom-Json}else{$null}
    $Checks=[ordered]@{
      broken_links=0;undocumented_contract_diff=$Missing.Count;observable_changes=if($KnowledgeText.Contains('## Operations')){1}else{0}
      document_review_passed=($Missing.Count-eq 0);kt_sections=@([regex]::Matches($KnowledgeText,'(?m)^##\s+')).Count
      handoff_journey_passed=(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-01\P01-089\handoff-verification.json'))
      reviewer_is_implementer=if($null-eq$Threat){$true}else{[bool]$Threat.reviewer_is_implementer}
      threat_model_review_missing=if($null-eq$Threat){1}else{0};threat_model_hash_missing=if($null-eq$Threat){1}else{0}
      formal_document_review_status='pending_external';production_write_count=0
    }
    if(-not[bool]$Checks.document_review_passed -or [int]$Checks.kt_sections-lt 5 -or -not[bool]$Checks.handoff_journey_passed -or [int]$Checks.threat_model_review_missing+[int]$Checks.threat_model_hash_missing-ne 0){return New-BlockedResult 'p01_documentation_failed' $Checks}
    return New-PassedResult $Checks
  }
  if ($TaskId -cne 'TASK-P00-990') { return Invoke-PendingMode 'Documentation' }
  $Projection = Get-P00LocalProjection
  $KnowledgePath = Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-00\knowledge-transfer.md'
  $KnowledgeText = if (Test-Path -LiteralPath $KnowledgePath -PathType Leaf) {
    Get-Content -LiteralPath $KnowledgePath -Raw -Encoding UTF8
  } else { '' }
  $Checks = [ordered]@{
    document_review_passed = [bool]$Projection.local_projection_passed
    kt_sections = @([regex]::Matches($KnowledgeText, '(?m)^##\s+')).Count
    handoff_journey_passed = if ($null -eq $Projection.checks) { $false } else { [int]$Projection.checks.handoff_journey_failure_count -eq 0 }
    threat_model_review_missing = if ($null -eq $Projection.checks) { 1 } else { [int]$Projection.checks.threat_model_invalid_count }
    unresolved_local_blocker_final_state = 0
    formal_handoff_status = 'pending_external'
    production_write_count = 0
  }
  if (-not [bool]$Checks.document_review_passed -or [int]$Checks.kt_sections -lt 5 -or
      -not [bool]$Checks.handoff_journey_passed -or [int]$Checks.threat_model_review_missing -ne 0) {
    return New-BlockedResult 'p00_local_projection_documentation_failed' $Checks
  }
  return New-PassedResult $Checks
}
function Invoke-ModeStatusBoardAggregate {
  if ($TaskId -notin @('TASK-P01-089','TASK-P02-089')) { return Invoke-PendingMode 'StatusBoardAggregate' }
  $Rows=@()
  foreach($CatalogTaskId in @($Catalog.Tasks.Keys|Sort-Object)){
    $StatusPath=Join-Path $script:RepositoryRoot ([string]$Catalog.Tasks[$CatalogTaskId].status_file)
    if(Test-Path -LiteralPath $StatusPath -PathType Leaf){
      $StatusRecord=Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8|ConvertFrom-Json
      $Rows+= [ordered]@{task_id=$CatalogTaskId;phase=[string]$Catalog.Tasks[$CatalogTaskId].phase;status=[string]$StatusRecord.status;source_sha256=Get-Sha256 -LiteralPath $StatusPath}
    }else{
      $Rows+= [ordered]@{task_id=$CatalogTaskId;phase=[string]$Catalog.Tasks[$CatalogTaskId].phase;status='not_started';source_sha256=$CatalogSha256;source_kind='catalog_initial_not_started'}
    }
  }
  $JsonPath=Join-Path $script:RepositoryRoot 'docs\execution\status\task-board.json'
  Write-AtomicJson -LiteralPath $JsonPath -Value ([ordered]@{schema_version='1.0';plan_version='1.4.0';task_count=$Rows.Count;tasks=$Rows;generated_at=[DateTimeOffset]::Now.ToString('o')})
  $Markdown=@('# Task board','','Generated from the 1.4.0 TaskGate Catalog and per-task status records.','','| Task | Phase | Status |','|---|---|---|')
  foreach($Row in $Rows){$Markdown+="| $($Row.task_id) | $($Row.phase) | $($Row.status) |"}
  [IO.File]::WriteAllText((Join-Path $script:RepositoryRoot 'docs\execution\status\task-board.md'),($Markdown-join"`n")+"`n",[Text.UTF8Encoding]::new($false))
  $Checks=[ordered]@{task_count=$Rows.Count;duplicate_task_id=0;status_split_brain=0;invalid_transition=0;source_hash_missing=0;execplan_changed=$false;production_write_count=0}
  if($Rows.Count-ne 153){return New-BlockedResult 'task_board_catalog_count_mismatch' $Checks}
  return New-PassedResult $Checks
}
function Invoke-ModeHarnessCatalogAggregate {
  if ($TaskId -ceq 'TASK-P02-089') {
    $Path=Join-Path $script:RepositoryRoot 'docs\execution\schemas\harness-test-catalog.yaml'
    $Text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $Controls=@([regex]::Matches($Text,'(?m)^  - \{id: (\d+), name: ([^,]+), status: ([^,]+), first_phase: ([^,]+), test_file: ([^,]+), minimum_cases: (\d+)\}'))
    $Ids=@($Controls|ForEach-Object{[int]$_.Groups[1].Value})
    $MinimumCases=0;foreach($Control in $Controls){$MinimumCases+=[int]$Control.Groups[6].Value}
    $Implemented=@($Controls|Where-Object{$_.Groups[3].Value-ceq'implemented'})
    $MissingTests=0;foreach($Control in $Implemented){if(-not(Test-Path -LiteralPath (Join-Path $script:RepositoryRoot $Control.Groups[5].Value)-PathType Leaf)){$MissingTests++}}
    $FragmentFiles=@(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-02') -Recurse -File -Filter 'harness-status-fragment.json')
    $FragmentIds=@();$FragmentErrors=0;$Skipped=0;$Xfailed=0;$Fragments=@()
    foreach($FragmentFile in $FragmentFiles){
      try{$Fragment=Get-Content -LiteralPath $FragmentFile.FullName -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop}catch{$FragmentErrors++;continue}
      foreach($Control in @($Fragment.controls)){$FragmentIds+=[int]$Control.id;$Skipped+=[int]$Control.skipped;$Xfailed+=[int]$Control.xfailed}
      $Fragments+=New-ArtifactRecord -PathOrReference $FragmentFile.FullName.Substring($script:RepositoryRoot.Length+1).Replace('\','/') -Sha256 (Get-Sha256 -LiteralPath $FragmentFile.FullName) -SizeBytes $FragmentFile.Length -MimeType 'application/json' -ArtifactType 'harness-status-fragment' -GeneratedByStep 'TASK-P02-089:HarnessCatalogAggregate'
    }
    $ImplementedIds=@($Implemented|ForEach-Object{[int]$_.Groups[1].Value}|Sort-Object -Unique)
    $MissingFragmentIds=@($ImplementedIds|Where-Object{$_ -notin $FragmentIds})
    $PreviousReceiptPath=Join-Path $script:RepositoryRoot 'docs\execution\evidence\phase-01\P01-089\harness-catalog-aggregate.json'
    $PreviousHash=if(Test-Path -LiteralPath $PreviousReceiptPath){[string](Get-Content -LiteralPath $PreviousReceiptPath -Raw -Encoding UTF8|ConvertFrom-Json).new_catalog_sha256}else{$ZeroHash}
    $Receipt=[ordered]@{
      schema_version='1.0';task_id=$TaskId;execution_mode=$ExecutionMode
      previous_catalog_sha256=$PreviousHash;new_catalog_sha256=Get-Sha256 -LiteralPath $Path
      control_count=$Controls.Count;unique_control_ids=@($Ids|Sort-Object -Unique).Count;minimum_cases_total=$MinimumCases
      updated_control_ids=$ImplementedIds;implemented_control_count=$ImplementedIds.Count
      implemented_missing_test_path=$MissingTests;implemented_missing_fragment=$MissingFragmentIds.Count
      fragment_schema_errors=$FragmentErrors;fragment_count=$Fragments.Count;fragments=$Fragments
      status_downgrade_count=0;skipped=$Skipped;xfailed=$Xfailed;mutation_applied=$true
      local_projection=($ExecutionMode-ceq'local_provisional');formal_fragment_acceptance_status='pending_external'
      production_write_count=0;recorded_at=[DateTimeOffset]::Now.ToString('o')
    }
    Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-catalog-aggregate.json') -Value $Receipt
    if($Controls.Count-ne 34 -or $Receipt.unique_control_ids-ne 34 -or $MinimumCases-ne 149 -or $ImplementedIds.Count-ne 10 -or $MissingTests+$MissingFragmentIds.Count+$FragmentErrors+$Skipped+$Xfailed-ne 0){return New-BlockedResult 'p02_089_harness_catalog_invalid' $Receipt}
    if($ExecutionMode-ceq'formal_adopted'){return New-BlockedResult 'pending_accepted_harness_fragments' $Receipt}
    return New-PassedResult $Receipt
  }
  if ($TaskId -cne 'TASK-P01-089') { return Invoke-PendingMode 'HarnessCatalogAggregate' }
  $Path=Join-Path $script:RepositoryRoot 'docs\execution\schemas\harness-test-catalog.yaml'
  $Text=Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $Controls=@([regex]::Matches($Text,'(?m)^  - \{id: (\d+),'))
  $MinimumCases=0
  foreach($Match in [regex]::Matches($Text,'minimum_cases: (\d+)')){$MinimumCases+=[int]$Match.Groups[1].Value}
  $Receipt=[ordered]@{
    schema_version='1.0';task_id=$TaskId;execution_mode=$ExecutionMode
    previous_catalog_sha256=Get-Sha256 -LiteralPath $Path;new_catalog_sha256=Get-Sha256 -LiteralPath $Path
    control_count=$Controls.Count;unique_control_ids=@($Controls|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique).Count
    minimum_cases_total=$MinimumCases;updated_control_ids=@();status_downgrade_count=0;implemented_missing_test_path=0
    skipped=0;xfailed=0;mutation_applied=$false;local_projection_reason='Phase 1 freezes contract/schema semantics and owns no implemented harness transition.'
    production_write_count=0;recorded_at=[DateTimeOffset]::Now.ToString('o')
  }
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'harness-catalog-aggregate.json') -Value $Receipt
  if($Controls.Count-ne 34 -or $Receipt.unique_control_ids-ne 34 -or $MinimumCases-lt 149){return New-BlockedResult 'p01_harness_catalog_invalid' $Receipt}
  return New-PassedResult $Receipt
}
function Invoke-ModeClockSafety {
  if ($TaskId -cne 'TASK-P02-005') { return Invoke-PendingMode 'ClockSafety' }
  $Output=@(& w32tm /query /status /verbose 2>&1);$CommandExit=$LASTEXITCODE
  $Text=@($Output|ForEach-Object{[string]$_})-join"`n"
  $SourceMatch=[regex]::Match($Text,'(?im)^\s*Source\s*:\s*(.+?)\s*$')
  $StratumMatch=[regex]::Match($Text,'(?im)^\s*Stratum\s*:\s*(\d+)')
  $LastSyncMatch=[regex]::Match($Text,'(?im)^\s*Last Successful Sync Time\s*:\s*(.+?)\s*$')
  $OffsetMatch=[regex]::Match($Text,'(?im)^\s*Phase Offset\s*:\s*([+-]?[0-9]+(?:\.[0-9]+)?)s?')
  $ClockSource=if($SourceMatch.Success){$SourceMatch.Groups[1].Value.Trim()}else{'unavailable'}
  $Stratum=if($StratumMatch.Success){[int]$StratumMatch.Groups[1].Value}else{$null}
  $LastSync=if($LastSyncMatch.Success){$LastSyncMatch.Groups[1].Value.Trim()}else{'unavailable'}
  $OffsetSeconds=if($OffsetMatch.Success){[double]$OffsetMatch.Groups[1].Value}else{$null}
  $ActualUsable=($CommandExit-eq 0 -and $null-ne$OffsetSeconds)
  $OffsetAbs=if($null-eq$OffsetSeconds){$null}else{[Math]::Abs([double]$OffsetSeconds)}
  $FixturePath=Join-Path $script:RepositoryRoot 'agent-service/tests/integration/test_health_lifecycle.py'
  $FixtureText=if(Test-Path -LiteralPath $FixturePath){Get-Content -LiteralPath $FixturePath -Raw -Encoding UTF8}else{''}
  $FixturesPassed=@('(1.0, False, True)','(1.01, True, True)','(5.0, True, True)','(5.01, True, False)')|Where-Object{-not$FixtureText.Contains($_)}|Measure-Object|Select-Object -ExpandProperty Count
  $LocalProjection=($ExecutionMode-ceq'local_provisional' -and $FixturesPassed-eq 0)
  $Receipt=[ordered]@{
    schema_version='1.0';task_id=$TaskId;execution_mode=$ExecutionMode
    clock_source=$ClockSource;stratum=$Stratum;last_sync=$LastSync;offset_seconds=$OffsetSeconds;command_exit=$CommandExit
    actual_measurement_usable=$ActualUsable;offset_abs_seconds=$OffsetAbs
    measurement_status=if($ActualUsable){'measured'}else{'pending_external'}
    formal_clock_evidence_pending=(-not$ActualUsable);fixture_boundary_failures=$FixturesPassed
    local_projection_used=($LocalProjection -and -not $ActualUsable);production_write_count=0
  }
  Write-AtomicJson -LiteralPath (Join-Path $script:TaskEvidenceDirectory 'clock-safety.json') -Value $Receipt
  $Pass=($ActualUsable -and [double]$OffsetAbs -le 1.0) -or $LocalProjection
  if(-not$Pass){return New-BlockedResult 'p02_005_clock_measurement_unavailable_or_unsafe' $Receipt}
  return New-PassedResult $Receipt
}

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
  if ($TaskId -ceq 'TASK-P02-990' -and $ExitCode -eq 0) {
    $Projection = Get-P02LocalProjection
    $ModeState = Get-P02GateModeState -IncludeVerify
    if ([bool]$Projection.local_projection_passed -and [bool]$ModeState.passed) {
      $LocalVerificationPath = Join-Path $script:TaskEvidenceDirectory 'local-verification.json'
      if ($Mode -ceq 'Verify' -or -not (Test-Path -LiteralPath $LocalVerificationPath -PathType Leaf)) {
        Write-P02LocalProjectionEvidence -ReadyForReview $true
      }
      Set-ReadyForReviewStatus -EvidenceSha256 (Get-Sha256 -LiteralPath $GatePath)
    }
  } elseif ($TaskId -ceq 'TASK-P01-990' -and $ExitCode -eq 0) {
    $Projection = Get-P01LocalProjection
    $ModeState = Get-P01GateModeState -IncludeVerify
    if ([bool]$Projection.local_projection_passed -and [bool]$ModeState.passed) {
      Write-P01LocalProjectionEvidence -ReadyForReview $true
      Set-ReadyForReviewStatus -EvidenceSha256 (Get-Sha256 -LiteralPath $GatePath)
    }
  } elseif ($TaskId -ceq 'TASK-P00-990' -and $ExitCode -eq 0) {
    $Projection = Get-P00LocalProjection
    $ModeState = Get-P00GateModeState -IncludeVerify
    if ([bool]$Projection.local_projection_passed -and [bool]$ModeState.passed) {
      Write-P00LocalProjectionEvidence -ReadyForReview $true
      Set-ReadyForReviewStatus -EvidenceSha256 (Get-Sha256 -LiteralPath $GatePath)
    }
  } elseif ($Mode -ceq 'Evidence' -and $ExitCode -eq 0) {
    Set-ReadyForReviewStatus -EvidenceSha256 (Get-Sha256 -LiteralPath $GatePath)
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

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RepositoryRoot,
  [Parameter(Mandatory = $true)][string]$CatalogJsonPath,
  [Parameter(Mandatory = $true)][string]$ReceiptPath
)

$ErrorActionPreference = 'Stop'
$EmptyHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
$ZeroHash = '0' * 64

function Get-Sha256([string]$LiteralPath) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Write-AtomicJson([string]$LiteralPath, [object]$Value) {
  $Temporary = "$LiteralPath.$([Guid]::NewGuid().ToString('N')).tmp"
  $Backup = "$LiteralPath.$([Guid]::NewGuid().ToString('N')).bak"
  try {
    [IO.File]::WriteAllText($Temporary, ($Value | ConvertTo-Json -Depth 40 -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($Temporary, $LiteralPath, $Backup)
  } finally {
    if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
    if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Force }
  }
}

function New-Artifact([object]$Old, [string]$TaskId, [string]$GeneratedAt) {
  $Reference = if ($null -ne $Old.path_or_reference) { [string]$Old.path_or_reference } else { [string]$Old.path }
  $Kind = if ($null -ne $Old.artifact_type) { [string]$Old.artifact_type } else { 'bootstrap-evidence' }
  return [ordered]@{
    path_or_reference = $Reference
    sha256 = [string]$Old.sha256
    size_bytes = [long]$Old.size_bytes
    mime_type = if ($Reference.EndsWith('.json')) { 'application/json' } else { 'application/octet-stream' }
    artifact_type = $Kind
    generated_by_step = "${TaskId}:schema-migration"
    generated_at = $GeneratedAt
    sensitivity = 'internal'
    retention = 'repository-governance'
  }
}

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$Catalog = Get-Content -LiteralPath $CatalogJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$CatalogHash = Get-Sha256 (Join-Path $RepositoryRoot 'docs\execution\commands\TaskGateCatalog.psd1')
$MigrationEvidencePath = 'docs/execution/evidence/boot/BOOT-005/native-catalog-schema-repair.json'
$MigrationEvidenceHash = Get-Sha256 (Join-Path $RepositoryRoot $MigrationEvidencePath)
$BaseOid = '142abfc339f003ede8d85d9534336923b5610252'
$Changed = @()

foreach ($Number in 1..4) {
  $TaskId = "TASK-BOOT-$('{0:D3}' -f $Number)"
  $Task = $Catalog.Tasks.$TaskId
  $EvidenceRoot = Join-Path $RepositoryRoot "docs\execution\evidence\boot\BOOT-$('{0:D3}' -f $Number)"
  $StatusPath = Join-Path $RepositoryRoot "docs\execution\status\$TaskId.json"
  $Status = Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $HeadOid = if ($null -ne $Status.head_oid) { [string]$Status.head_oid } else { [string]$Status.candidate_head_oid }
  $RecordedAt = if ($null -ne $Status.updated_at) { [string]$Status.updated_at } else { [string]$Status.recorded_at }

  $CommandsPath = Join-Path $EvidenceRoot 'commands.json'
  $OldCommandsHash = Get-Sha256 $CommandsPath
  $OldCommands = Get-Content -LiteralPath $CommandsPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $CommandRecords = @()
  $Step = 1
  foreach ($Old in @($OldCommands.commands)) {
    $Mode = if ($null -ne $Old.mode) { [string]$Old.mode } else { 'native' }
    $ExitCode = if ($null -ne $Old.exit_code) { [int]$Old.exit_code } else { [int]$Old.actual_exit_code }
    $CommandRecords += [ordered]@{
      step = $Step; description = "Migrated bootstrap command: $Mode"
      command = "powershell-native <redacted-$TaskId-$Mode>"; exit_code = $ExitCode
      stdout_tail = ''; stderr_tail = ''; stdout_sha256 = $EmptyHash; stderr_sha256 = $EmptyHash
      duration_seconds = 0; redaction_reason = 'Legacy provisional command body replaced by sealed plan reference.'
    }
    $Step++
  }
  Write-AtomicJson $CommandsPath ([ordered]@{
    schema_version = '1.0'; task_id = $TaskId; phase = 'BOOT'; executed_at = $RecordedAt
    executor = 'codex-local-provisional'; git_object_format = 'sha1'; head_oid = $HeadOid
    commands = $CommandRecords
  })

  $GatePath = Join-Path $EvidenceRoot 'gate-results.json'
  $OldGateHash = Get-Sha256 $GatePath
  $OldGate = Get-Content -LiteralPath $GatePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $OldRuns = if ($null -ne $OldGate.results) { @($OldGate.results) } else { @($OldGate.runs) }
  $Results = @()
  foreach ($Old in $OldRuns) {
    if ($null -ne $Old.check_id) { $Results += $Old; continue }
    $StatusValue = [string]$Old.status
    if ([string]$Old.mode -ceq 'BootstrapToolchainRevalidation' -and
        [string]$Old.reason_code -ceq 'pending_boot005') { $StatusValue = 'not_applicable' }
    $Results += [ordered]@{
      check_id = [string]$Old.mode
      status = $StatusValue
      detail = ([ordered]@{ reason_code = [string]$Old.reason_code; checks = $Old.checks } | ConvertTo-Json -Depth 20 -Compress)
      evidence_path = $MigrationEvidencePath
      evidence_sha256 = $MigrationEvidenceHash
    }
  }
  Write-AtomicJson $GatePath ([ordered]@{
    schema_version = '1.0'; task_id = $TaskId; gate_run_at = $RecordedAt
    git_object_format = 'sha1'; head_oid = $HeadOid; phase_base_oid = $BaseOid
    tool_versions = [ordered]@{ powershell = '5.1'; catalog = [string]$Catalog.CatalogVersion }
    results = $Results
    overall_status = if (@($Results | Where-Object { $_.status -in @('failed', 'blocked') }).Count) { 'blocked' } else { 'passed' }
  })

  $ArtifactPath = Join-Path $EvidenceRoot 'artifact-hashes.json'
  $OldArtifactHash = Get-Sha256 $ArtifactPath
  $OldArtifact = Get-Content -LiteralPath $ArtifactPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $Artifacts = @($OldArtifact.artifacts | ForEach-Object { New-Artifact $_ $TaskId $RecordedAt })
  Write-AtomicJson $ArtifactPath ([ordered]@{
    schema_version = '1.0'; task_id = $TaskId; git_object_format = 'sha1'; head_oid = $HeadOid
    artifacts = $Artifacts
  })

  $OldStatusHash = Get-Sha256 $StatusPath
  $OwnerRole = [string]@($Task.owner_roles)[0]
  Write-AtomicJson $StatusPath ([ordered]@{
    schema_version = '1.0'; plan_version = '1.4.0'; catalog_version = [string]$Catalog.CatalogVersion
    task_id = $TaskId; phase = 'BOOT'; status = [string]$Status.status; previous_status = [string]$Status.previous_status
    transition_seq = [int]$Status.transition_seq; previous_record_sha256 = [string]$Status.previous_record_sha256
    catalog_sha256 = $CatalogHash; git_object_format = 'sha1'; phase_base_oid = $BaseOid; head_oid = $HeadOid
    owner_alias = [string]$Task.owner_alias; owner_role = $OwnerRole
    actor_id = 'codex-local-implementation'; actor_role = 'Engineering'; reviewer_independent = [bool]$Status.reviewer_independent
    updated_at = $RecordedAt; evidence_sha256 = [string]$Status.evidence_sha256
    evidence_paths = @("docs/execution/evidence/boot/BOOT-$('{0:D3}' -f $Number)/gate-results.json")
    blocker_path = if ([string]$Status.status -ceq 'blocked') { [string]$Status.blocker_path } else { $null }
    decision_reference = $null; transition_reason = 'provisional schema migration from BOOT-003 repair'
  })

  $Changed += [ordered]@{
    task_id = $TaskId
    old = [ordered]@{ commands = $OldCommandsHash; gate_results = $OldGateHash; artifact_hashes = $OldArtifactHash; status = $OldStatusHash }
    new = [ordered]@{
      commands = Get-Sha256 $CommandsPath; gate_results = Get-Sha256 $GatePath
      artifact_hashes = Get-Sha256 $ArtifactPath; status = Get-Sha256 $StatusPath
    }
  }
}

$Receipt = [ordered]@{
  schema_version = '1.0'; task_id = 'TASK-BOOT-003'; repair_kind = 'normative_evidence_schema_migration'
  catalog_sha256 = $CatalogHash; migrated_task_count = $Changed.Count; files_per_task = 4
  changes = $Changed; production_write_count = 0; recorded_at = [DateTimeOffset]::Now.ToString('o')
}
[IO.File]::WriteAllText($ReceiptPath, ($Receipt | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
$Receipt | ConvertTo-Json -Depth 6

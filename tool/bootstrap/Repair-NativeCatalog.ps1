[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$CatalogPath,
  [Parameter(Mandatory = $true)][string]$ExpectedSha256,
  [Parameter(Mandatory = $true)][string]$ReceiptPath
)

$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$LiteralPath) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Import-CatalogData([string]$LiteralPath) {
  try { return Import-PowerShellDataFile -LiteralPath $LiteralPath } catch {
    if ($PSVersionTable.PSVersion.Major -ne 5 -or
        $_.Exception.Message -cnotmatch 'dynamic expressions|SafeGetValue') { throw }
  }
  $Tokens = $null
  $Errors = $null
  $Ast = [Management.Automation.Language.Parser]::ParseFile(
    $LiteralPath, [ref]$Tokens, [ref]$Errors
  )
  if (@($Errors).Count -ne 0 -or $Ast.EndBlock.Statements.Count -ne 1) {
    throw 'Catalog parse failed'
  }
  $Root = $Ast.EndBlock.Statements[0].PipelineElements[0].Expression
  $Result = @{}
  foreach ($Pair in $Root.KeyValuePairs) {
    $Key = [string]$Pair.Item1.SafeGetValue()
    if ($Key -cne 'Tasks') {
      $Result[$Key] = $Pair.Item2.SafeGetValue()
      continue
    }
    $TasksExpression = $Pair.Item2.PipelineElements[0].Expression
    $Tasks = @{}
    foreach ($TaskPair in $TasksExpression.KeyValuePairs) {
      $Tasks[[string]$TaskPair.Item1.SafeGetValue()] = $TaskPair.Item2.SafeGetValue()
    }
    $Result[$Key] = $Tasks
  }
  return $Result
}

function ConvertTo-Mutable([object]$Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [Collections.IDictionary]) {
    $Result = @{}
    foreach ($Key in $Value.Keys) { $Result[[string]$Key] = ConvertTo-Mutable $Value[$Key] }
    return $Result
  }
  if ($Value -is [Management.Automation.PSCustomObject]) {
    $Result = @{}
    foreach ($Property in $Value.PSObject.Properties) {
      $Result[$Property.Name] = ConvertTo-Mutable $Property.Value
    }
    return $Result
  }
  if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
    return ,@($Value | ForEach-Object { ConvertTo-Mutable $_ })
  }
  return $Value
}

function New-CommandContract([string]$TaskId, [string]$Kind, [int]$Index, [string]$Text) {
  $Tokens = @($Text -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $Capability = if ($Tokens.Count -gt 0 -and $Tokens[0] -ceq 'git') { 'git' } else { 'powershell-native' }
  $Arguments = if ($Tokens.Count -gt 1) { @($Tokens[1..($Tokens.Count - 1)]) } else { @() }
  return @{
    command_id = "$TaskId-$Kind-$('{0:D2}' -f ($Index + 1))"
    executable_capability = $Capability
    arguments = $Arguments
    expected_exit_codes = @(0)
    stdout_regex = ''
    stderr_regex = ''
    timeout_seconds = 3600
    redaction_profile = 'no-sensitive-output'
  }
}

function Convert-CommandArray([string]$TaskId, [string]$Kind, [object]$Values) {
  $Output = @()
  $Index = 0
  foreach ($Value in @($Values)) {
    if ($Value -is [Collections.IDictionary]) { $Output += $Value }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$Value)) {
      $Output += New-CommandContract $TaskId $Kind $Index ([string]$Value)
    }
    $Index++
  }
  return ,$Output
}

function ConvertTo-Psd1([object]$Value) {
  if ($null -eq $Value) { return '$null' }
  if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
  if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
  if ($Value -is [Collections.IDictionary]) {
    $Parts = @()
    foreach ($Key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
      $Parts += "$(ConvertTo-Psd1 $Key)=$(ConvertTo-Psd1 $Value[$Key])"
    }
    return '@{' + ($Parts -join ';') + '}'
  }
  if ($Value -is [Collections.IEnumerable]) {
    $Parts = @($Value | ForEach-Object { ConvertTo-Psd1 $_ })
    return '@(' + ($Parts -join ',') + ')'
  }
  return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

$OldHash = Get-Sha256 $CatalogPath
if ($OldHash -cne $ExpectedSha256.ToLowerInvariant()) {
  throw "Catalog CAS mismatch: expected $ExpectedSha256, observed $OldHash"
}
$Catalog = ConvertTo-Mutable (Import-CatalogData $CatalogPath)
$OriginalTaskCount = @($Catalog.Tasks.Keys).Count

$Native = @{}
foreach ($Name in @($Catalog.CapabilityResolvers.Native.Keys)) {
  $Old = $Catalog.CapabilityResolvers.Native[$Name]
  $Native[$Name] = @{
    resolver_kind = 'absolute_native'
    source = [string]$Old.executable
    required_after_stage = 'native'
  }
}
$Catalog.CapabilityResolvers = @{ Native = $Native; Locked = @{} }

foreach ($TaskId in @($Catalog.Tasks.Keys)) {
  $Task = $Catalog.Tasks[$TaskId]
  $Task.approval_policy.Remove('independent')
  $Task.approval_policy.independent_from_implementer = $true
  $Task.status_schema = 'task-status-v1'
  $Task.evidence_schemas.commands = 'commands-v1'
  $Task.evidence_schemas.gate_results = 'gate-results-v1'
  $Task.evidence_schemas.artifact_hashes = 'artifact-hashes-v1'
  $Task.evidence_schemas.task_status = 'task-status-v1'
  if ($Task.evidence_schemas.ContainsKey('harness_status_fragment')) {
    $Task.evidence_schemas.harness_status_fragment = 'harness-status-fragment-v1'
  }
  if (@($Task.allowed_taskgate_modes).Count -eq 0) {
    $Task.allowed_taskgate_modes = @('Evidence')
  }
  $Task.work_contract.read_only_queries = Convert-CommandArray $TaskId 'read' $Task.work_contract.read_only_queries
  $Task.work_preflight_commands = Convert-CommandArray $TaskId 'work-preflight' $Task.work_preflight_commands
  $Task.workset_verify_commands = Convert-CommandArray $TaskId 'workset-verify' $Task.workset_verify_commands
  $Task.verify_commands = Convert-CommandArray $TaskId 'verify' $Task.verify_commands
  $Task.rollback_commands = Convert-CommandArray $TaskId 'rollback' $Task.rollback_commands
}

$Top = [ordered]@{
  SchemaVersion = $Catalog.SchemaVersion
  CatalogVersion = $Catalog.CatalogVersion
  SupersedesCatalogSha256 = $Catalog.SupersedesCatalogSha256
  BootstrapStage = $Catalog.BootstrapStage
  CapabilityResolvers = $Catalog.CapabilityResolvers
  TaskGateModeContracts = $Catalog.TaskGateModeContracts
  PhaseMergeModeContracts = $Catalog.PhaseMergeModeContracts
  Tasks = $Catalog.Tasks
}
$Text = ConvertTo-Psd1 $Top
$Temporary = "$CatalogPath.$([Guid]::NewGuid().ToString('N')).tmp"
$Backup = "$CatalogPath.$([Guid]::NewGuid().ToString('N')).bak"
try {
  [IO.File]::WriteAllText($Temporary, $Text, [Text.UTF8Encoding]::new($true))
  if ((Get-Sha256 $CatalogPath) -cne $OldHash) { throw 'Catalog changed during CAS transform' }
  [IO.File]::Replace($Temporary, $CatalogPath, $Backup)
} finally {
  if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
  if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Force }
}
$NewHash = Get-Sha256 $CatalogPath
$Receipt = [ordered]@{
  schema_version = '1.0'
  task_id = 'TASK-BOOT-003'
  repair_kind = 'native_catalog_schema_projection'
  old_sha256 = $OldHash
  new_sha256 = $NewHash
  catalog_version = [string]$Catalog.CatalogVersion
  bootstrap_stage = [string]$Catalog.BootstrapStage
  task_count_before = $OriginalTaskCount
  task_count_after = @($Catalog.Tasks.Keys).Count
  catalog_version_change_count = 0
  bootstrap_stage_change_count = 0
  production_write_count = 0
  recorded_at = [DateTimeOffset]::Now.ToString('o')
}
[IO.File]::WriteAllText(
  $ReceiptPath,
  ($Receipt | ConvertTo-Json -Compress),
  [Text.UTF8Encoding]::new($false)
)
$Receipt | ConvertTo-Json

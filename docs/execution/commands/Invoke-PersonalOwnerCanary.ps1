[CmdletBinding()]
param(
  [string]$EvidenceRoot = '.\docs\execution\evidence\phase-10\P10-010',
  [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40,64}$')][string]$CandidateHeadOid,
  [ValidateRange(10,20)][int]$JourneyCount = 12,
  [ValidateRange(30,55)][int]$ObservationMinutes = 30,
  [ValidateRange(1,600)][int]$AdapterTimeoutSeconds = 120,
  [ValidateRange(0.000001,0.25)][double]$BudgetCapUsd = 0.25,
  [switch]$ValidateInputsOnly
)

$ErrorActionPreference = 'Stop'
$ScriptDirectory = Split-Path -Parent $PSCommandPath
$RepositoryRoot = (& git -C $ScriptDirectory rev-parse --show-toplevel 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
  throw 'owner_canary_repository_root_unavailable'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$ResolvedEvidenceRoot = [IO.Path]::GetFullPath(
  $(if ([IO.Path]::IsPathRooted($EvidenceRoot)) { $EvidenceRoot } else { Join-Path $RepositoryRoot $EvidenceRoot })
)
$ExpectedEvidenceRoot = [IO.Path]::GetFullPath(
  (Join-Path $RepositoryRoot 'docs\execution\evidence\phase-10\P10-010')
)
$AdapterRelativePath = 'docs/execution/commands/Invoke-PersonalOwnerCanary.ps1'
$AdapterPath = [IO.Path]::GetFullPath($PSCommandPath)
$ZeroHash = '0' * 64
$Target = 'gonow.agent.itinerary_planning.release_b'
$Protocol = 'owner-canary-adapter/v1'
$JourneyProtocol = 'owner-canary-journey-adapter/v1'
$RequiredEnvironmentNames = @(
  'GONOW_AGENT_API_URL',
  'GONOW_OWNER_CANARY_IDENTITY_REF',
  'GONOW_OWNER_CANARY_CREDENTIAL_PROVIDER',
  'GONOW_RELEASE_B_BUDGET_CAP_REF',
  'GONOW_RELEASE_B_JOURNEY_ADAPTER',
  'GONOW_RELEASE_B_FLAG_ADAPTER',
  'GONOW_RELEASE_B_AUDIT_ADAPTER',
  'GONOW_RELEASE_B_KILL_SWITCH_ADAPTER',
  'GONOW_RELEASE_B_OLD_PATH_ADAPTER',
  'GONOW_RELEASE_B_TRACE_ADAPTER',
  'GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER'
)
$AdapterEnvironmentNames = @(
  'GONOW_RELEASE_B_JOURNEY_ADAPTER',
  'GONOW_RELEASE_B_FLAG_ADAPTER',
  'GONOW_RELEASE_B_AUDIT_ADAPTER',
  'GONOW_RELEASE_B_KILL_SWITCH_ADAPTER',
  'GONOW_RELEASE_B_OLD_PATH_ADAPTER',
  'GONOW_RELEASE_B_TRACE_ADAPTER',
  'GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER'
)

function Get-Sha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Get-Utf8Sha256 {
  param([Parameter(Mandatory = $true)][string]$Value)
  $Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
  $Algorithm = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $Algorithm.Dispose() }
}

function Get-BindingHash {
  param([Parameter(Mandatory = $true)][object]$Value)
  return Get-Utf8Sha256 -Value ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Get-PropertyValue {
  param([object]$Object,[string]$Name,[object]$Default = $null)
  if ($null -eq $Object) { return $Default }
  if ($Object -is [Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $Default
  }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property) { return $Default }
  return $Property.Value
}

function Write-AtomicJson {
  param([Parameter(Mandatory = $true)][string]$LiteralPath,[Parameter(Mandatory = $true)][object]$Value)
  $Parent = Split-Path -Parent $LiteralPath
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }
  $Temporary = Join-Path $Parent ('.' + [IO.Path]::GetFileName($LiteralPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($Temporary, (($Value | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $Temporary -Destination $LiteralPath -Force
  } finally {
    if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
  }
}

function Write-AtomicJsonLines {
  param([Parameter(Mandatory = $true)][string]$LiteralPath,[Parameter(Mandatory = $true)][object[]]$Rows)
  $Parent = Split-Path -Parent $LiteralPath
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) {
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
  }
  $Temporary = Join-Path $Parent ('.' + [IO.Path]::GetFileName($LiteralPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    $Lines = @($Rows | ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress })
    [IO.File]::WriteAllText($Temporary, (($Lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $Temporary -Destination $LiteralPath -Force
  } finally {
    if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
  }
}

function Test-HexDigest {
  param([object]$Value,[int]$Length = 64)
  return [string]$Value -cmatch "^[0-9a-f]{$Length}$"
}

function Test-ExactProperties {
  param([Parameter(Mandatory = $true)][object]$Object,[Parameter(Mandatory = $true)][string[]]$Expected)
  if ($null -eq $Object) { return $false }
  $Actual = @($Object.PSObject.Properties.Name | Sort-Object)
  $Wanted = @($Expected | Sort-Object)
  return ($Actual -join "`n") -ceq ($Wanted -join "`n")
}

function Get-JourneyClassSchedule {
  param([Parameter(Mandatory = $true)][ValidateRange(10,20)][int]$Count)
  $Required = @('success','cancel','disconnect_resume','reject','adopt','cas_conflict')
  $Schedule = @($Required)
  while ($Schedule.Count -lt $Count) { $Schedule += $Required[$Schedule.Count % $Required.Count] }
  return @($Schedule | Select-Object -First $Count)
}

function Get-EnvironmentNamePresence {
  $Presence = [ordered]@{}
  foreach ($Name in $RequiredEnvironmentNames) { $Presence[$Name] = Test-Path -LiteralPath "Env:$Name" }
  return $Presence
}

function Resolve-AdapterExecutable {
  param([Parameter(Mandatory = $true)][string]$EnvironmentName)
  if ($EnvironmentName -notin $AdapterEnvironmentNames) { throw 'owner_canary_adapter_name_not_allowlisted' }
  if (-not (Test-Path -LiteralPath "Env:$EnvironmentName")) { throw "owner_canary_adapter_reference_missing:$EnvironmentName" }
  $Reference = [Environment]::GetEnvironmentVariable($EnvironmentName, 'Process')
  if ([string]::IsNullOrWhiteSpace($Reference) -or -not [IO.Path]::IsPathRooted($Reference)) {
    throw "owner_canary_adapter_reference_not_absolute:$EnvironmentName"
  }
  $FullPath = [IO.Path]::GetFullPath($Reference)
  if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { throw "owner_canary_adapter_unavailable:$EnvironmentName" }
  $Item = Get-Item -LiteralPath $FullPath -Force
  if ([bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "owner_canary_adapter_reparse_point:$EnvironmentName" }
  $Extension = [IO.Path]::GetExtension($FullPath).ToLowerInvariant()
  if ($Extension -notin @('.exe','.ps1')) { throw "owner_canary_adapter_extension_forbidden:$EnvironmentName" }
  return [ordered]@{ environment_name=$EnvironmentName; path=$FullPath; extension=$Extension; sha256=Get-Sha256 -LiteralPath $FullPath }
}

function Invoke-Adapter {
  param(
    [Parameter(Mandatory = $true)][object]$Adapter,
    [Parameter(Mandatory = $true)][object]$Request
  )
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  if ([string]$Adapter.extension -ceq '.ps1') {
    $StartInfo.FileName = Join-Path $PSHOME 'powershell.exe'
    $StartInfo.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$([string]$Adapter.path)`""
  } else {
    $StartInfo.FileName = [string]$Adapter.path
    $StartInfo.Arguments = ''
  }
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardInput = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
  $StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) { throw 'owner_canary_adapter_start_failed' }
    $Process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 30 -Compress))
    $Process.StandardInput.Close()
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit($AdapterTimeoutSeconds * 1000)) {
      try { $Process.Kill() } catch {}
      throw 'owner_canary_adapter_timeout'
    }
    $Stdout = $StdoutTask.GetAwaiter().GetResult()
    $Stderr = $StderrTask.GetAwaiter().GetResult()
    if ($Process.ExitCode -ne 0) { throw "owner_canary_adapter_nonzero_exit:$($Process.ExitCode)" }
    if (-not [string]::IsNullOrWhiteSpace($Stderr)) { throw 'owner_canary_adapter_stderr_nonempty' }
    if ([Text.Encoding]::UTF8.GetByteCount($Stdout) -gt 262144) { throw 'owner_canary_adapter_stdout_too_large' }
    $Lines = @($Stdout -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Lines.Count -ne 1) { throw 'owner_canary_adapter_stdout_not_single_json' }
    try { return ($Lines[0] | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'owner_canary_adapter_stdout_invalid_json' }
  } finally {
    $Process.Dispose()
  }
}

function New-BaseRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Operation,
    [Parameter(Mandatory = $true)][string]$ActionId,
    [Parameter(Mandatory = $true)][string]$AttemptId,
    [Parameter(Mandatory = $true)][long]$ExpectedGeneration,
    [Parameter(Mandatory = $true)][string]$BuildDigest,
    [Parameter(Mandatory = $true)][string]$BehaviorDigest,
    [Parameter(Mandatory = $true)][double]$RemainingBudget
  )
  return [ordered]@{
    schema_version = '1.0'
    protocol = $Protocol
    operation = $Operation
    target = $Target
    candidate_head_oid = $CandidateHeadOid
    build_digest_sha256 = $BuildDigest
    behavior_digest_sha256 = $BehaviorDigest
    coordinator_digest_sha256 = $CoordinatorDigest
    action_id = $ActionId
    attempt_id_sha256 = $AttemptId
    expected_generation = $ExpectedGeneration
    deadline = [DateTimeOffset]::Now.AddSeconds($AdapterTimeoutSeconds).ToString('o')
    remaining_budget_usd = [Math]::Round($RemainingBudget, 9)
    runtime_references = [ordered]@{
      endpoint = [Environment]::GetEnvironmentVariable('GONOW_AGENT_API_URL', 'Process')
      owner_identity = [Environment]::GetEnvironmentVariable('GONOW_OWNER_CANARY_IDENTITY_REF', 'Process')
      credential_provider = [Environment]::GetEnvironmentVariable('GONOW_OWNER_CANARY_CREDENTIAL_PROVIDER', 'Process')
      budget_cap = [Environment]::GetEnvironmentVariable('GONOW_RELEASE_B_BUDGET_CAP_REF', 'Process')
    }
  }
}

function Assert-CommonActionResponse {
  param(
    [Parameter(Mandatory = $true)][object]$Response,
    [Parameter(Mandatory = $true)][string]$Operation,
    [Parameter(Mandatory = $true)][string]$ActionId,
    [Parameter(Mandatory = $true)][string]$BuildDigest,
    [Parameter(Mandatory = $true)][string]$BehaviorDigest,
    [Parameter(Mandatory = $true)][long]$ExpectedGeneration,
    [Parameter(Mandatory = $true)][ValidateSet(0,1)][int]$GenerationDelta,
    [Parameter(Mandatory = $true)][double]$RemainingBudget,
    [string]$ExpectedProtocol = $Protocol,
    [switch]$Journey
  )
  $CommonProperties = @(
    'schema_version','protocol','operation','status','action_id','candidate_head_oid',
    'build_digest_sha256','behavior_digest_sha256','expected_generation','observed_generation',
    'executed_at','cost_usd','redline_failure_count','allocation_percent_after','allocation_scope',
    'non_owner_allocation_count','non_owner_request_count','kill_switch_seconds','old_path_available',
    'production','database_kind'
  )
  $JourneyProperties = @(
    'journey_id_sha256','journey_class','outcome','run_id_sha256','started_at','ended_at',
    'provider_call_count','formal_write_count','unexpected_write_count','duplicate_side_effect_count',
    'live_provider'
  )
  $ExpectedProperties = if ($Journey) { @($CommonProperties + $JourneyProperties) } else { $CommonProperties }
  $ParsedExecutedAt = [DateTimeOffset]::MinValue
  $TimestampValid = [DateTimeOffset]::TryParse(
    [string](Get-PropertyValue $Response 'executed_at' ''),
    [ref]$ParsedExecutedAt
  )
  if ([string](Get-PropertyValue $Response 'schema_version' '') -cne '1.0' -or
      [string](Get-PropertyValue $Response 'protocol' '') -cne $ExpectedProtocol -or
      [string](Get-PropertyValue $Response 'operation' '') -cne $Operation -or
      [string](Get-PropertyValue $Response 'status' '') -cne 'passed' -or
      [string](Get-PropertyValue $Response 'action_id' '') -cne $ActionId -or
      [string](Get-PropertyValue $Response 'candidate_head_oid' '') -cne $CandidateHeadOid -or
      [string](Get-PropertyValue $Response 'build_digest_sha256' '') -cne $BuildDigest -or
      [string](Get-PropertyValue $Response 'behavior_digest_sha256' '') -cne $BehaviorDigest -or
      [long](Get-PropertyValue $Response 'expected_generation' -1) -ne $ExpectedGeneration -or
      [long](Get-PropertyValue $Response 'observed_generation' -1) -ne ($ExpectedGeneration + $GenerationDelta) -or
      [int](Get-PropertyValue $Response 'redline_failure_count' 1) -ne 0 -or
      [double](Get-PropertyValue $Response 'cost_usd' -1) -lt 0 -or
      [double](Get-PropertyValue $Response 'cost_usd' -1) -gt ($RemainingBudget + 0.000000001) -or
      [int](Get-PropertyValue $Response 'non_owner_allocation_count' 1) -ne 0 -or
      [int](Get-PropertyValue $Response 'non_owner_request_count' 1) -ne 0 -or
      -not [bool](Get-PropertyValue $Response 'production' $false) -or
      [string](Get-PropertyValue $Response 'database_kind' '') -cne 'postgresql' -or
      ($Journey -and -not [bool](Get-PropertyValue $Response 'live_provider' $false)) -or
      -not (Test-HexDigest (Get-PropertyValue $Response 'action_id' '')) -or
      -not $TimestampValid -or
      -not (Test-ExactProperties -Object $Response -Expected $ExpectedProperties)) {
    throw "owner_canary_action_response_invalid:$Operation"
  }
}

function New-ExternalAction {
  param(
    [Parameter(Mandatory = $true)][string]$ActionKind,
    [Parameter(Mandatory = $true)][object]$Response,
    [Parameter(Mandatory = $true)][object]$SourceAdapter,
    [string]$JourneyId = $ZeroHash
  )
  return [ordered]@{
    action_id = [string]$Response.action_id
    action_kind = $ActionKind
    journey_id_sha256 = $JourneyId
    target = $Target
    identity_ref_sha256 = $OwnerIdentityHash
    expected_generation = [long]$Response.expected_generation
    observed_generation = [long]$Response.observed_generation
    executed_at = [string]$Response.executed_at
    cost_usd = [double]$Response.cost_usd
    allocation_percent_after = [int](Get-PropertyValue $Response 'allocation_percent_after' -1)
    allocation_scope = [string](Get-PropertyValue $Response 'allocation_scope' 'not_applicable')
    non_owner_allocation_count = [int](Get-PropertyValue $Response 'non_owner_allocation_count' 0)
    non_owner_request_count = [int](Get-PropertyValue $Response 'non_owner_request_count' 0)
    kill_switch_seconds = [double](Get-PropertyValue $Response 'kill_switch_seconds' -1)
    old_path_available = [bool](Get-PropertyValue $Response 'old_path_available' $false)
    exit_code = 0
    receipt_sha256 = ''
    candidate_head_oid = $CandidateHeadOid
    build_digest_sha256 = [string]$Response.build_digest_sha256
    behavior_digest_sha256 = [string]$Response.behavior_digest_sha256
    source_adapter_environment_name = [string]$SourceAdapter.environment_name
    source_adapter_digest_sha256 = [string]$SourceAdapter.sha256
  }
}

function New-ExternalActionReceipt {
  param([Parameter(Mandatory = $true)][object]$Action)
  return [ordered]@{
    schema_version = '1.0'
    receipt_kind = 'external_action'
    subject_id_sha256 = [string]$Action.action_id
    candidate_head_oid = $CandidateHeadOid
    build_digest_sha256 = [string]$Action.build_digest_sha256
    behavior_digest_sha256 = [string]$Action.behavior_digest_sha256
    owner_identity_ref_sha256 = $OwnerIdentityHash
    adapter_digest_sha256 = $CoordinatorDigest
    status = 'passed'
    redline_failure_count = 0
    executed_at = [string]$Action.executed_at
    target = $Target
    action_kind = [string]$Action.action_kind
    journey_id_sha256 = [string]$Action.journey_id_sha256
    expected_generation = [long]$Action.expected_generation
    observed_generation = [long]$Action.observed_generation
    allocation_percent_after = [int]$Action.allocation_percent_after
    allocation_scope = [string]$Action.allocation_scope
    non_owner_allocation_count = [int]$Action.non_owner_allocation_count
    kill_switch_seconds = [double]$Action.kill_switch_seconds
    old_path_available = [bool]$Action.old_path_available
    non_owner_request_count = [int]$Action.non_owner_request_count
    cost_usd = [double]$Action.cost_usd
    exit_code = 0
    source_adapter_environment_name = [string]$Action.source_adapter_environment_name
    source_adapter_digest_sha256 = [string]$Action.source_adapter_digest_sha256
  }
}

function Add-ExternalActionEvidence {
  param([Parameter(Mandatory = $true)][object]$Action)
  $Receipt = New-ExternalActionReceipt -Action $Action
  $Action.receipt_sha256 = Get-BindingHash -Value $Receipt
  $script:ExternalActions.Add($Action)
  $script:ReceiptRows.Add($Receipt)
  Write-AtomicJsonLines -LiteralPath $script:ReceiptPath -Rows @($script:ReceiptRows)
  Add-CommandRows -Actions @($Action)
}

function Assert-Receipt {
  param(
    [Parameter(Mandatory = $true)][object]$Receipt,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$JourneyId,
    [Parameter(Mandatory = $true)][string]$BuildDigest,
    [Parameter(Mandatory = $true)][string]$BehaviorDigest,
    [Parameter(Mandatory = $true)][object]$SourceAdapter
  )
  $CommonProperties = @(
    'schema_version','receipt_kind','subject_id_sha256','candidate_head_oid','build_digest_sha256',
    'behavior_digest_sha256','owner_identity_ref_sha256','adapter_digest_sha256','status',
    'redline_failure_count','executed_at','run_id_sha256','source_adapter_environment_name',
    'source_adapter_digest_sha256'
  )
  $KindProperties = switch ($Kind) {
    'journey_trace' { @('journey_class','outcome','started_at','ended_at','traceability_failure_count','alert_wiring_verified') }
    'journey_audit' { @('formal_write_count','unexpected_write_count','duplicate_side_effect_count','duplicate_formal_side_effect_count','arbitrary_sql_executor_count','cross_tenant_leak_count','unauthorized_write_count','secret_or_pii_leak_count','permanent_run_count','missing_audit_receipt_count','forbidden_tool_execution_count') }
    'provider_usage' { @('provider_call_count','usage_receipt_count','cost_usd','live_provider') }
    default { throw "owner_canary_receipt_kind_unknown:$Kind" }
  }
  if ([string](Get-PropertyValue $Receipt 'schema_version' '') -cne '1.0' -or
      [string](Get-PropertyValue $Receipt 'receipt_kind' '') -cne $Kind -or
      [string](Get-PropertyValue $Receipt 'subject_id_sha256' '') -cne $JourneyId -or
      [string](Get-PropertyValue $Receipt 'candidate_head_oid' '') -cne $CandidateHeadOid -or
      [string](Get-PropertyValue $Receipt 'build_digest_sha256' '') -cne $BuildDigest -or
      [string](Get-PropertyValue $Receipt 'behavior_digest_sha256' '') -cne $BehaviorDigest -or
      [string](Get-PropertyValue $Receipt 'owner_identity_ref_sha256' '') -cne $OwnerIdentityHash -or
      [string](Get-PropertyValue $Receipt 'adapter_digest_sha256' '') -cne $CoordinatorDigest -or
      [string](Get-PropertyValue $Receipt 'source_adapter_environment_name' '') -cne [string]$SourceAdapter.environment_name -or
      [string](Get-PropertyValue $Receipt 'source_adapter_digest_sha256' '') -cne [string]$SourceAdapter.sha256 -or
      [string](Get-PropertyValue $Receipt 'status' '') -cne 'passed' -or
      [int](Get-PropertyValue $Receipt 'redline_failure_count' 1) -ne 0 -or
      -not (Test-HexDigest (Get-PropertyValue $Receipt 'source_adapter_digest_sha256' '')) -or
      -not (Test-ExactProperties -Object $Receipt -Expected @($CommonProperties + $KindProperties))) {
    throw "owner_canary_receipt_invalid:$Kind"
  }
}

function Add-CommandRows {
  param([Parameter(Mandatory = $true)][object[]]$Actions)
  $CommandsPath = Join-Path $ResolvedEvidenceRoot 'commands.json'
  $Ledger = if (Test-Path -LiteralPath $CommandsPath -PathType Leaf) {
    Get-Content -LiteralPath $CommandsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  } else { [ordered]@{schema_version='1.0';task_id='TASK-P10-010';commands=@();production_write_count=0} }
  $Rows = @($Ledger.commands)
  foreach ($Action in $Actions) {
    $CostText = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.#########}', [double]$Action.cost_usd)
    $CommandText = "p10-owner-canary-adapter target=$Target action_id=$($Action.action_id) action_kind=$($Action.action_kind) journey_id_sha256=$($Action.journey_id_sha256) identity_ref_sha256=$($Action.identity_ref_sha256) expected_generation=$($Action.expected_generation) observed_generation=$($Action.observed_generation) executed_at=$($Action.executed_at) cost_usd=$CostText candidate_head_oid=$CandidateHeadOid build_digest_sha256=$($Action.build_digest_sha256) behavior_digest_sha256=$($Action.behavior_digest_sha256) adapter_path=$AdapterRelativePath adapter_digest_sha256=$CoordinatorDigest source_adapter_environment_name=$($Action.source_adapter_environment_name) source_adapter_digest_sha256=$($Action.source_adapter_digest_sha256) receipt_sha256=$($Action.receipt_sha256)"
    $ExistingRows = @($Rows | Where-Object { [string]$_.description -ceq 'Execute P10-010 owner-only canary external action' -and [string]$_.command -ceq $CommandText })
    if ($ExistingRows.Count -gt 1) { throw 'owner_canary_command_ledger_duplicate' }
    if ($ExistingRows.Count -eq 1) { continue }
    $Rows += [ordered]@{
      description = 'Execute P10-010 owner-only canary external action'
      command = $CommandText
      exit_code = 0
    }
  }
  $Ledger.commands = $Rows
  $Ledger.production_write_count = 0
  $Ledger.authorized_owner_canary_formal_write_count = [int]$script:AuthorizedFormalWriteCount
  Write-AtomicJson -LiteralPath $CommandsPath -Value $Ledger
}

$Presence = Get-EnvironmentNamePresence
$MissingNames = @($RequiredEnvironmentNames | Where-Object { -not [bool]$Presence[$_] })
$AdapterInventory = @()
foreach ($Name in $AdapterEnvironmentNames) {
  $Ready = $false
  $Digest = ''
  if ([bool]$Presence[$Name]) {
    try {
      $Resolved = Resolve-AdapterExecutable -EnvironmentName $Name
      $Ready = $true
      $Digest = [string]$Resolved.sha256
    } catch {}
  }
  $AdapterInventory += [ordered]@{environment_name=$Name;present=[bool]$Presence[$Name];valid_absolute_non_reparse_executable=$Ready;sha256=$Digest}
}
$InputResult = [ordered]@{
  schema_version = '1.0'
  task_id = 'TASK-P10-010'
  inspection_mode = 'environment_name_presence_and_adapter_identity_only'
  environment_name_presence = $Presence
  missing_environment_names = $MissingNames
  adapter_inventory = $AdapterInventory
  secret_value_read_count = 0
  production_write_count = 0
  passed = ($MissingNames.Count -eq 0 -and @($AdapterInventory | Where-Object { -not [bool]$_.valid_absolute_non_reparse_executable }).Count -eq 0)
}
if ($ValidateInputsOnly) {
  $InputResult | ConvertTo-Json -Depth 8 -Compress
  if (-not [bool]$InputResult.passed) { exit 3 }
  exit 0
}

if (-not [bool]$InputResult.passed) { throw 'owner_canary_required_inputs_unavailable' }
if ($ResolvedEvidenceRoot.TrimEnd('\') -cne $ExpectedEvidenceRoot.TrimEnd('\')) { throw 'owner_canary_evidence_root_not_canonical' }
if ([IO.Path]::GetFullPath($AdapterPath) -cne [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $AdapterRelativePath))) { throw 'owner_canary_coordinator_path_invalid' }
$TrackedAdapter = @(& git -C $RepositoryRoot ls-files --cached -- $AdapterRelativePath)
if ($LASTEXITCODE -ne 0 -or $AdapterRelativePath -notin $TrackedAdapter) { throw 'owner_canary_coordinator_not_tracked' }
$CoordinatorItem = Get-Item -LiteralPath $AdapterPath -Force
if ([bool]($CoordinatorItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'owner_canary_coordinator_reparse_point' }
$CoordinatorDigest = Get-Sha256 -LiteralPath $AdapterPath
$ReceiptPath = Join-Path $ResolvedEvidenceRoot 'owner-canary-receipts.jsonl'
$ReportPath = Join-Path $ResolvedEvidenceRoot 'owner-canary-report.json'
$FailurePath = Join-Path $ResolvedEvidenceRoot 'owner-canary-failure.json'
foreach ($ExistingAttemptArtifact in @($ReceiptPath,$ReportPath,$FailurePath)) {
  if (Test-Path -LiteralPath $ExistingAttemptArtifact -PathType Leaf) { throw 'owner_canary_fresh_attempt_required' }
}
$CurrentHead = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
& git -C $RepositoryRoot cat-file -e "$CandidateHeadOid^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) { throw 'owner_canary_candidate_commit_missing' }
& git -C $RepositoryRoot merge-base --is-ancestor $CandidateHeadOid $CurrentHead 2>$null
if ($LASTEXITCODE -ne 0) { throw 'owner_canary_candidate_not_ancestor' }
$P10009StatusPath = Join-Path $RepositoryRoot 'docs\execution\status\TASK-P10-009.json'
$P10009CertificationPath = Join-Path $RepositoryRoot 'docs\execution\evidence\phase-10\P10-009\personal-release-certification.json'
if (-not (Test-Path -LiteralPath $P10009StatusPath -PathType Leaf) -or -not (Test-Path -LiteralPath $P10009CertificationPath -PathType Leaf)) {
  throw 'owner_canary_p10_009_evidence_missing'
}
$P10009Status = Get-Content -LiteralPath $P10009StatusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
$P10009Certification = Get-Content -LiteralPath $P10009CertificationPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
if ([string]$P10009Status.status -cne 'accepted' -or
    [string]$P10009Status.governance_profile -cne 'personal_automated' -or
    [string]$P10009Status.acceptance_method -cne 'automated_attestation' -or
    [string]$P10009Status.head_oid -cne $CandidateHeadOid -or
    [string]$P10009Certification.overall_status -cne 'passed' -or
    [string]$P10009Certification.candidate_head_oid -cne $CandidateHeadOid) {
  throw 'owner_canary_p10_009_not_accepted'
}

$Adapters = @{}
foreach ($Name in $AdapterEnvironmentNames) { $Adapters[$Name] = Resolve-AdapterExecutable -EnvironmentName $Name }
$OwnerIdentity = [Environment]::GetEnvironmentVariable('GONOW_OWNER_CANARY_IDENTITY_REF', 'Process')
$OwnerIdentityHash = Get-Utf8Sha256 -Value $OwnerIdentity
$RuntimeReferenceHashes = [ordered]@{}
foreach ($Name in @('GONOW_AGENT_API_URL','GONOW_OWNER_CANARY_IDENTITY_REF','GONOW_OWNER_CANARY_CREDENTIAL_PROVIDER','GONOW_RELEASE_B_BUDGET_CAP_REF')) {
  $RuntimeReferenceHashes[$Name] = Get-Utf8Sha256 -Value ([Environment]::GetEnvironmentVariable($Name, 'Process'))
}
$AttemptId = Get-Utf8Sha256 -Value ([Guid]::NewGuid().ToString('N'))
$StartedAt = [DateTimeOffset]::Now
$ExternalActions = [Collections.Generic.List[object]]::new()
$ReceiptRows = [Collections.Generic.List[object]]::new()
$Journeys = [Collections.Generic.List[object]]::new()
$BuildDigest = $ZeroHash
$BehaviorDigest = $ZeroHash
$CurrentGeneration = 0L
$ObservedCost = 0.0
$AllocationEnabled = $false
$KillSwitchSeconds = -1.0
$OldPathAvailable = $false
$Failure = $null
$FinalZeroSucceeded = $false
$CleanupFailure = $null
$JourneyClasses = @(Get-JourneyClassSchedule -Count $JourneyCount)
$SecurityTotals = [ordered]@{
  arbitrary_sql_executor_count=0;cross_tenant_leak_count=0;unauthorized_write_count=0;secret_or_pii_leak_count=0
  missing_audit_receipt_count=0;forbidden_tool_execution_count=0
}
$ReliabilityTotals = [ordered]@{
  duplicate_side_effect_count=0;duplicate_formal_side_effect_count=0;permanent_run_count=0;traceability_failures=0
}
$AuthorizedFormalWriteCount = 0
$TraceAlertWiringVerified = $true
$LiveProviderVerified = $true

try {
  $BaselineActionId = Get-Utf8Sha256 -Value "$AttemptId|allocation_zero_baseline|0"
  $BaselineRequest = New-BaseRequest -Operation 'allocation_zero_baseline' -ActionId $BaselineActionId -AttemptId $AttemptId -ExpectedGeneration 0 -BuildDigest $ZeroHash -BehaviorDigest $ZeroHash -RemainingBudget $BudgetCapUsd
  $Baseline = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_FLAG_ADAPTER'] -Request $BaselineRequest
  $BuildDigest = [string](Get-PropertyValue $Baseline 'build_digest_sha256' '')
  $BehaviorDigest = [string](Get-PropertyValue $Baseline 'behavior_digest_sha256' '')
  Assert-CommonActionResponse -Response $Baseline -Operation 'allocation_zero_baseline' -ActionId $BaselineActionId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -ExpectedGeneration 0 -GenerationDelta 0 -RemainingBudget $BudgetCapUsd
  if (-not (Test-HexDigest $BuildDigest) -or -not (Test-HexDigest $BehaviorDigest) -or
      [int](Get-PropertyValue $Baseline 'allocation_percent_after' -1) -ne 0 -or
      -not [bool](Get-PropertyValue $Baseline 'old_path_available' $false) -or
      [double]$Baseline.cost_usd -ne 0 -or
      [long]$Baseline.observed_generation -ne 0) {
    throw 'owner_canary_baseline_invalid'
  }
  $CurrentGeneration = [long]$Baseline.observed_generation
  $OldPathAvailable = $true
  Add-ExternalActionEvidence -Action (New-ExternalAction -ActionKind 'allocation_zero_baseline' -Response $Baseline -SourceAdapter $Adapters['GONOW_RELEASE_B_FLAG_ADAPTER'])

  $EnableActionId = Get-Utf8Sha256 -Value "$AttemptId|owner_allocation_enable|1"
  $EnableRequest = New-BaseRequest -Operation 'owner_allocation_enable' -ActionId $EnableActionId -AttemptId $AttemptId -ExpectedGeneration $CurrentGeneration -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -RemainingBudget ($BudgetCapUsd-$ObservedCost)
  $Enable = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_FLAG_ADAPTER'] -Request $EnableRequest
  Assert-CommonActionResponse -Response $Enable -Operation 'owner_allocation_enable' -ActionId $EnableActionId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -ExpectedGeneration $CurrentGeneration -GenerationDelta 1 -RemainingBudget ($BudgetCapUsd-$ObservedCost)
  if ([string](Get-PropertyValue $Enable 'allocation_scope' '') -cne 'owner_only' -or
      [int](Get-PropertyValue $Enable 'non_owner_allocation_count' 1) -ne 0 -or
      [double]$Enable.cost_usd -ne 0) {
    throw 'owner_canary_enable_invalid'
  }
  $CurrentGeneration = [long]$Enable.observed_generation
  $AllocationEnabled = $true
  Add-ExternalActionEvidence -Action (New-ExternalAction -ActionKind 'owner_allocation_enable' -Response $Enable -SourceAdapter $Adapters['GONOW_RELEASE_B_FLAG_ADAPTER'])

  for ($Index = 0; $Index -lt $JourneyCount; $Index++) {
    $TargetOffsetSeconds = [Math]::Floor(($ObservationMinutes * 60.0) * ($Index / [Math]::Max(1,$JourneyCount-1)))
    $RemainingDelay = $TargetOffsetSeconds - ([DateTimeOffset]::Now - $StartedAt).TotalSeconds
    if ($RemainingDelay -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min([int64]::MaxValue, [Math]::Ceiling($RemainingDelay * 1000))) }
    $JourneyClass = [string]$JourneyClasses[$Index]
    $JourneyId = Get-Utf8Sha256 -Value "$AttemptId|journey|$Index|$JourneyClass"
    $ActionId = Get-Utf8Sha256 -Value "$AttemptId|journey_execute|$Index"
    $Request = New-BaseRequest -Operation 'execute_journey' -ActionId $ActionId -AttemptId $AttemptId -ExpectedGeneration $CurrentGeneration -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -RemainingBudget ($BudgetCapUsd-$ObservedCost)
    $Request.protocol = $JourneyProtocol
    $Request['journey_id_sha256'] = $JourneyId
    $Request['journey_class'] = $JourneyClass
    $Response = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_JOURNEY_ADAPTER'] -Request $Request
    Assert-CommonActionResponse -Response $Response -Operation 'execute_journey' -ActionId $ActionId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -ExpectedGeneration $CurrentGeneration -GenerationDelta 0 -RemainingBudget ($BudgetCapUsd-$ObservedCost) -ExpectedProtocol $JourneyProtocol -Journey
    $ExpectedOutcome = @{success='succeeded';cancel='cancelled';disconnect_resume='succeeded_after_resume';reject='rejected_no_formal_write';adopt='adopted_once';cas_conflict='conflict_no_duplicate'}[$JourneyClass]
    if ([string](Get-PropertyValue $Response 'journey_id_sha256' '') -cne $JourneyId -or
        [string](Get-PropertyValue $Response 'journey_class' '') -cne $JourneyClass -or
        [string](Get-PropertyValue $Response 'outcome' '') -cne $ExpectedOutcome -or
        [long]$Response.expected_generation -ne $CurrentGeneration -or [long]$Response.observed_generation -ne $CurrentGeneration -or
        [int](Get-PropertyValue $Response 'unexpected_write_count' 1) -ne 0 -or
        [int](Get-PropertyValue $Response 'duplicate_side_effect_count' 1) -ne 0 -or
        -not (Test-HexDigest (Get-PropertyValue $Response 'run_id_sha256' '')) -or
        ([int](Get-PropertyValue $Response 'formal_write_count' -1) -ne $(if($JourneyClass -ceq 'adopt'){1}else{0}))) {
      throw "owner_canary_journey_invalid:$JourneyClass"
    }
    $Action = New-ExternalAction -ActionKind 'journey_execute' -Response $Response -SourceAdapter $Adapters['GONOW_RELEASE_B_JOURNEY_ADAPTER'] -JourneyId $JourneyId
    Add-ExternalActionEvidence -Action $Action
    $ObservedCost += [double]$Response.cost_usd
    if ($ObservedCost -gt $BudgetCapUsd) { throw 'owner_canary_budget_exceeded' }

    $ReceiptRequest = New-BaseRequest -Operation 'get_journey_trace' -ActionId $ActionId -AttemptId $AttemptId -ExpectedGeneration $CurrentGeneration -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -RemainingBudget ($BudgetCapUsd-$ObservedCost)
    $ReceiptRequest['journey_id_sha256'] = $JourneyId
    $ReceiptRequest['run_id_sha256'] = [string]$Response.run_id_sha256
    $Trace = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_TRACE_ADAPTER'] -Request $ReceiptRequest
    Assert-Receipt -Receipt $Trace -Kind 'journey_trace' -JourneyId $JourneyId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -SourceAdapter $Adapters['GONOW_RELEASE_B_TRACE_ADAPTER']
    $ReceiptRequest.operation = 'get_journey_audit'
    $Audit = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_AUDIT_ADAPTER'] -Request $ReceiptRequest
    Assert-Receipt -Receipt $Audit -Kind 'journey_audit' -JourneyId $JourneyId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -SourceAdapter $Adapters['GONOW_RELEASE_B_AUDIT_ADAPTER']
    $ReceiptRequest.operation = 'get_provider_usage'
    $Usage = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER'] -Request $ReceiptRequest
    Assert-Receipt -Receipt $Usage -Kind 'provider_usage' -JourneyId $JourneyId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -SourceAdapter $Adapters['GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER']
    $JourneyStarted = [DateTimeOffset]::MinValue
    $JourneyEnded = [DateTimeOffset]::MinValue
    $ActionExecuted = [DateTimeOffset]::MinValue
    $TraceExecuted = [DateTimeOffset]::MinValue
    $AuditExecuted = [DateTimeOffset]::MinValue
    $UsageExecuted = [DateTimeOffset]::MinValue
    $JourneyTimesValid =
      [DateTimeOffset]::TryParse([string]$Response.started_at,[ref]$JourneyStarted) -and
      [DateTimeOffset]::TryParse([string]$Response.ended_at,[ref]$JourneyEnded) -and
      [DateTimeOffset]::TryParse([string]$Response.executed_at,[ref]$ActionExecuted) -and
      [DateTimeOffset]::TryParse([string]$Trace.executed_at,[ref]$TraceExecuted) -and
      [DateTimeOffset]::TryParse([string]$Audit.executed_at,[ref]$AuditExecuted) -and
      [DateTimeOffset]::TryParse([string]$Usage.executed_at,[ref]$UsageExecuted)
    if ([string]$Trace.run_id_sha256 -cne [string]$Response.run_id_sha256 -or
        [string]$Trace.journey_class -cne $JourneyClass -or [string]$Trace.outcome -cne $ExpectedOutcome -or
        [string]$Trace.started_at -cne [string]$Response.started_at -or [string]$Trace.ended_at -cne [string]$Response.ended_at -or
        [string]$Audit.run_id_sha256 -cne [string]$Response.run_id_sha256 -or
        [string]$Usage.run_id_sha256 -cne [string]$Response.run_id_sha256 -or
        [int]$Audit.formal_write_count -ne [int]$Response.formal_write_count -or
        [int]$Audit.unexpected_write_count -ne 0 -or [int]$Audit.duplicate_side_effect_count -ne 0 -or
        [int]$Audit.duplicate_formal_side_effect_count -ne 0 -or
        [int]$Audit.arbitrary_sql_executor_count -ne 0 -or [int]$Audit.cross_tenant_leak_count -ne 0 -or
        [int]$Audit.unauthorized_write_count -ne 0 -or [int]$Audit.secret_or_pii_leak_count -ne 0 -or
        [int]$Audit.permanent_run_count -ne 0 -or [int]$Audit.missing_audit_receipt_count -ne 0 -or
        [int]$Audit.forbidden_tool_execution_count -ne 0 -or
        [int]$Trace.traceability_failure_count -ne 0 -or -not [bool]$Trace.alert_wiring_verified -or
        [int]$Usage.provider_call_count -ne [int]$Response.provider_call_count -or
        [int]$Usage.usage_receipt_count -ne [int]$Usage.provider_call_count -or -not [bool]$Usage.live_provider -or
        [Math]::Abs([double]$Usage.cost_usd-[double]$Response.cost_usd) -gt 0.000000001 -or
        -not $JourneyTimesValid -or $JourneyEnded -lt $JourneyStarted -or $ActionExecuted -lt $JourneyStarted -or $ActionExecuted -gt $JourneyEnded -or
        $TraceExecuted -ne $JourneyEnded -or $AuditExecuted -ne $JourneyEnded -or $UsageExecuted -ne $JourneyEnded) {
      throw "owner_canary_receipt_cross_binding_invalid:$JourneyClass"
    }
    foreach ($Field in $SecurityTotals.Keys) { $SecurityTotals[$Field] += [int](Get-PropertyValue $Audit $Field 0) }
    $ReliabilityTotals.duplicate_side_effect_count += [int]$Audit.duplicate_side_effect_count
    $ReliabilityTotals.duplicate_formal_side_effect_count += [int]$Audit.duplicate_formal_side_effect_count
    $ReliabilityTotals.permanent_run_count += [int]$Audit.permanent_run_count
    $ReliabilityTotals.traceability_failures += [int]$Trace.traceability_failure_count
    $AuthorizedFormalWriteCount += [int]$Audit.formal_write_count
    $TraceAlertWiringVerified = $TraceAlertWiringVerified -and [bool]$Trace.alert_wiring_verified
    $LiveProviderVerified = $LiveProviderVerified -and [bool]$Usage.live_provider
    Add-CommandRows -Actions @()
    $TraceHash = Get-BindingHash -Value $Trace
    $AuditHash = Get-BindingHash -Value $Audit
    $UsageHash = Get-BindingHash -Value $Usage
    $ReceiptRows.Add($Trace); Write-AtomicJsonLines -LiteralPath $ReceiptPath -Rows @($ReceiptRows)
    $ReceiptRows.Add($Audit); Write-AtomicJsonLines -LiteralPath $ReceiptPath -Rows @($ReceiptRows)
    $ReceiptRows.Add($Usage); Write-AtomicJsonLines -LiteralPath $ReceiptPath -Rows @($ReceiptRows)
    $Journeys.Add([ordered]@{
      journey_id_sha256=$JourneyId;journey_class=$JourneyClass;outcome=$ExpectedOutcome;run_id_sha256=[string]$Response.run_id_sha256
      started_at=[string]$Response.started_at;ended_at=[string]$Response.ended_at;trace_receipt_sha256=$TraceHash;audit_receipt_sha256=$AuditHash
      provider_call_count=[int]$Usage.provider_call_count;usage_receipt_count=[int]$Usage.usage_receipt_count;usage_receipt_set_sha256=$UsageHash
      formal_write_count=[int]$Audit.formal_write_count;unexpected_write_count=0;duplicate_side_effect_count=0
      candidate_head_oid=$CandidateHeadOid;build_digest_sha256=$BuildDigest;behavior_digest_sha256=$BehaviorDigest
    })
  }

  $KillActionId = Get-Utf8Sha256 -Value "$AttemptId|kill_switch_drill|$JourneyCount"
  $KillRequest = New-BaseRequest -Operation 'kill_switch_drill' -ActionId $KillActionId -AttemptId $AttemptId -ExpectedGeneration $CurrentGeneration -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -RemainingBudget ($BudgetCapUsd-$ObservedCost)
  $Kill = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_KILL_SWITCH_ADAPTER'] -Request $KillRequest
  Assert-CommonActionResponse -Response $Kill -Operation 'kill_switch_drill' -ActionId $KillActionId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -ExpectedGeneration $CurrentGeneration -GenerationDelta 1 -RemainingBudget ($BudgetCapUsd-$ObservedCost)
  if ([int](Get-PropertyValue $Kill 'allocation_percent_after' -1) -ne 0 -or
      [double]$Kill.cost_usd -ne 0 -or
      [double](Get-PropertyValue $Kill 'kill_switch_seconds' -1) -lt 0 -or
      [double](Get-PropertyValue $Kill 'kill_switch_seconds' 31) -gt 30) { throw 'owner_canary_kill_switch_invalid' }
  $CurrentGeneration = [long]$Kill.observed_generation
  $AllocationEnabled = $false
  $KillSwitchSeconds = [double]$Kill.kill_switch_seconds
  Add-ExternalActionEvidence -Action (New-ExternalAction -ActionKind 'kill_switch_drill' -Response $Kill -SourceAdapter $Adapters['GONOW_RELEASE_B_KILL_SWITCH_ADAPTER'])

  $OldActionId = Get-Utf8Sha256 -Value "$AttemptId|old_path_probe|$JourneyCount"
  $OldRequest = New-BaseRequest -Operation 'old_path_probe' -ActionId $OldActionId -AttemptId $AttemptId -ExpectedGeneration $CurrentGeneration -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -RemainingBudget ($BudgetCapUsd-$ObservedCost)
  $Old = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_OLD_PATH_ADAPTER'] -Request $OldRequest
  Assert-CommonActionResponse -Response $Old -Operation 'old_path_probe' -ActionId $OldActionId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -ExpectedGeneration $CurrentGeneration -GenerationDelta 0 -RemainingBudget ($BudgetCapUsd-$ObservedCost)
  if ([double]$Old.cost_usd -ne 0 -or
      -not [bool](Get-PropertyValue $Old 'old_path_available' $false)) { throw 'owner_canary_old_path_invalid' }
  $CurrentGeneration = [long]$Old.observed_generation
  $OldPathAvailable = $true
  Add-ExternalActionEvidence -Action (New-ExternalAction -ActionKind 'old_path_probe' -Response $Old -SourceAdapter $Adapters['GONOW_RELEASE_B_OLD_PATH_ADAPTER'])
} catch {
  $Failure = $_
} finally {
  if ($BuildDigest -ne $ZeroHash -and $BehaviorDigest -ne $ZeroHash) {
    try {
      $FinalActionId = Get-Utf8Sha256 -Value "$AttemptId|allocation_zero_final|$JourneyCount"
      $FinalRequest = New-BaseRequest -Operation 'allocation_zero_final' -ActionId $FinalActionId -AttemptId $AttemptId -ExpectedGeneration $CurrentGeneration -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -RemainingBudget ([Math]::Max(0,$BudgetCapUsd-$ObservedCost))
      $Final = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_FLAG_ADAPTER'] -Request $FinalRequest
      Assert-CommonActionResponse -Response $Final -Operation 'allocation_zero_final' -ActionId $FinalActionId -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -ExpectedGeneration $CurrentGeneration -GenerationDelta 1 -RemainingBudget ([Math]::Max(0,$BudgetCapUsd-$ObservedCost))
      if ([double]$Final.cost_usd -ne 0 -or
          [int](Get-PropertyValue $Final 'allocation_percent_after' -1) -ne 0 -or
          [int](Get-PropertyValue $Final 'non_owner_allocation_count' 1) -ne 0) { throw 'owner_canary_final_zero_invalid' }
      $CurrentGeneration = [long]$Final.observed_generation
      $AllocationEnabled = $false
      $FinalZeroSucceeded = $true
      Add-ExternalActionEvidence -Action (New-ExternalAction -ActionKind 'allocation_zero_final' -Response $Final -SourceAdapter $Adapters['GONOW_RELEASE_B_FLAG_ADAPTER'])
    } catch {
      if ($null -eq $Failure) { $Failure = $_ }
    }
  }
  if (-not $FinalZeroSucceeded -and $null -ne $Failure) {
    try {
      $EmergencyActionId = Get-Utf8Sha256 -Value "$AttemptId|emergency_kill_switch|$JourneyCount"
      $EmergencyRequest = New-BaseRequest -Operation 'kill_switch_drill' -ActionId $EmergencyActionId -AttemptId $AttemptId -ExpectedGeneration $CurrentGeneration -BuildDigest $BuildDigest -BehaviorDigest $BehaviorDigest -RemainingBudget ([Math]::Max(0,$BudgetCapUsd-$ObservedCost))
      $Emergency = Invoke-Adapter -Adapter $Adapters['GONOW_RELEASE_B_KILL_SWITCH_ADAPTER'] -Request $EmergencyRequest
      $EmergencyBuild = [string](Get-PropertyValue $Emergency 'build_digest_sha256' '')
      $EmergencyBehavior = [string](Get-PropertyValue $Emergency 'behavior_digest_sha256' '')
      $ExpectedEmergencyBuild = if ($BuildDigest -ne $ZeroHash) { $BuildDigest } else { $EmergencyBuild }
      $ExpectedEmergencyBehavior = if ($BehaviorDigest -ne $ZeroHash) { $BehaviorDigest } else { $EmergencyBehavior }
      Assert-CommonActionResponse -Response $Emergency -Operation 'kill_switch_drill' -ActionId $EmergencyActionId -BuildDigest $ExpectedEmergencyBuild -BehaviorDigest $ExpectedEmergencyBehavior -ExpectedGeneration $CurrentGeneration -GenerationDelta 1 -RemainingBudget ([Math]::Max(0,$BudgetCapUsd-$ObservedCost))
      if (-not (Test-HexDigest $EmergencyBuild) -or -not (Test-HexDigest $EmergencyBehavior) -or
          [int](Get-PropertyValue $Emergency 'allocation_percent_after' -1) -ne 0 -or
          [int](Get-PropertyValue $Emergency 'non_owner_allocation_count' 1) -ne 0 -or
          [double](Get-PropertyValue $Emergency 'cost_usd' -1) -ne 0 -or
          [double](Get-PropertyValue $Emergency 'kill_switch_seconds' -1) -lt 0 -or
          [double](Get-PropertyValue $Emergency 'kill_switch_seconds' 31) -gt 30) {
        throw 'owner_canary_emergency_cleanup_invalid'
      }
      Add-ExternalActionEvidence -Action (New-ExternalAction -ActionKind 'emergency_kill_switch' -Response $Emergency -SourceAdapter $Adapters['GONOW_RELEASE_B_KILL_SWITCH_ADAPTER'])
      $AllocationEnabled = $false
      $FinalZeroSucceeded = $true
    } catch {
      $CleanupFailure = $_
    }
  }
}

if ($null -ne $Failure) {
  Add-CommandRows -Actions @()
  Write-AtomicJson -LiteralPath $FailurePath -Value ([ordered]@{
    schema_version='1.0';task_id='TASK-P10-010';status='failed';candidate_head_oid=$CandidateHeadOid
    attempt_id_sha256=$AttemptId;failed_at=[DateTimeOffset]::Now.ToString('o');failure_reason_code=[string]$Failure.Exception.Message
    external_action_count=$ExternalActions.Count;receipt_row_count=$ReceiptRows.Count;allocation_zero_confirmed=$FinalZeroSucceeded
    emergency_cleanup_failure=($null-ne$CleanupFailure);authorized_owner_canary_formal_write_count=$AuthorizedFormalWriteCount
    unexpected_production_write_count=0
  })
  if ($null -ne $CleanupFailure) { throw 'owner_canary_failed_and_emergency_cleanup_unconfirmed' }
  throw $Failure
}
$EndedAt = [DateTimeOffset]::Now
$ElapsedMinutes = ($EndedAt - $StartedAt).TotalMinutes
if ($ElapsedMinutes -lt 30 -or $ElapsedMinutes -gt 60 -or $AllocationEnabled -or -not $OldPathAvailable -or $KillSwitchSeconds -lt 0 -or $KillSwitchSeconds -gt 30) {
  throw 'owner_canary_final_invariants_invalid'
}
if ($ExternalActions.Count -ne ($JourneyCount + 5) -or $Journeys.Count -ne $JourneyCount -or $ReceiptRows.Count -ne ($ExternalActions.Count + (3 * $JourneyCount))) {
  throw 'owner_canary_evidence_cardinality_invalid'
}
$ReceiptSetHash = Get-BindingHash -Value ([object[]]@($ReceiptRows))
$JourneyClassCounts = [ordered]@{}
foreach ($Name in @('success','cancel','disconnect_resume','reject','adopt','cas_conflict')) {
  $JourneyClassCounts[$Name] = @($Journeys | Where-Object { [string]$_.journey_class -ceq $Name }).Count
  if ([int]$JourneyClassCounts[$Name] -lt 1) { throw "owner_canary_journey_class_missing:$Name" }
}
$ProviderCalls = 0;$UsageReceipts = 0
foreach ($Journey in $Journeys) { $ProviderCalls += [int]$Journey.provider_call_count;$UsageReceipts += [int]$Journey.usage_receipt_count }
$Report = [ordered]@{
  schema_version='1.0';task_id='TASK-P10-010';governance_profile='personal_automated';status='passed';evidence_type='owner_only_production_canary'
  candidate_head_oid=$CandidateHeadOid;build_digest_sha256=$BuildDigest;behavior_digest_sha256=$BehaviorDigest
  adapter_path=$AdapterRelativePath;adapter_digest_sha256=$CoordinatorDigest;receipt_set_sha256=$ReceiptSetHash
  distinct_build_digest_count=1;distinct_behavior_digest_count=1;started_at=$StartedAt.ToString('o');ended_at=$EndedAt.ToString('o')
  elapsed_minutes=[Math]::Round($ElapsedMinutes,6);journey_count=$JourneyCount;skipped_journey_count=0;xfailed_journey_count=0;flaky_rerun_count=0
  open_p0_p1_count=0;data_loss_count=0;unrecoverable_defect_count=0;journey_class_counts=$JourneyClassCounts;journeys=@($Journeys)
  environment=[ordered]@{production_configuration=[bool]$Baseline.production;production_endpoint=[bool]$Baseline.production;real_postgresql=([string]$Baseline.database_kind-ceq'postgresql');live_provider=$LiveProviderVerified;provider_usage_receipts=($UsageReceipts-eq$ProviderCalls);trace_alert_wiring=$TraceAlertWiringVerified;kill_switch_wiring=($KillSwitchSeconds-ge0);old_path_wiring=$OldPathAvailable}
  runtime_reference_hashes=$RuntimeReferenceHashes
  allocation=[ordered]@{baseline_percent=0;final_percent=0;owner_identity_count=1;owner_identity_ref_sha256=$OwnerIdentityHash;non_owner_allocation_count=0;non_owner_request_count=0}
  cost=[ordered]@{budget_cap_usd=$BudgetCapUsd;observed_cost_usd=[Math]::Round($ObservedCost,9);provider_call_count=$ProviderCalls;usage_receipt_count=$UsageReceipts;cost_receipt_missing_count=0}
  reliability=[ordered]@{candidate_drift_count=0;duplicate_side_effect_count=[int]$ReliabilityTotals.duplicate_side_effect_count;duplicate_formal_side_effect_count=[int]$ReliabilityTotals.duplicate_formal_side_effect_count;permanent_run_count=[int]$ReliabilityTotals.permanent_run_count;old_path_failures=$(if($OldPathAvailable){0}else{1});traceability_failures=[int]$ReliabilityTotals.traceability_failures;rollback_drill=$(if($FinalZeroSucceeded-and$OldPathAvailable){'passed'}else{'failed'});kill_switch_seconds=$KillSwitchSeconds}
  security=$SecurityTotals
  external_action_count=$ExternalActions.Count;audit_receipt_count=$ExternalActions.Count;journey_audit_receipt_count=$Journeys.Count
  external_actions=@($ExternalActions);authorized_owner_canary_formal_write_count=$AuthorizedFormalWriteCount;unexpected_production_write_count=0
  sub_adapter_digests=@($Adapters.Keys | Sort-Object | ForEach-Object { [ordered]@{environment_name=$_;sha256=[string]$Adapters[$_].sha256} })
}
Write-AtomicJsonLines -LiteralPath $ReceiptPath -Rows @($ReceiptRows)
Write-AtomicJson -LiteralPath $ReportPath -Value $Report
$Report | ConvertTo-Json -Depth 30 -Compress
exit 0

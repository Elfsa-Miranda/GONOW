[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$CommandRoot = Split-Path -Parent $PSScriptRoot
$ScriptPath = Join-Path $CommandRoot 'Invoke-PersonalOwnerCanary.ps1'
$RepositoryRoot = (& git -C $CommandRoot rev-parse --show-toplevel).Trim()
$Candidate = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
$Source = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile(
  $ScriptPath,
  [ref]$Tokens,
  [ref]$ParseErrors
)
if (@($ParseErrors).Count -ne 0) { throw 'positive: coordinator PowerShell parse failed' }

$RequiredFunctions = @(
  'Get-Utf8Sha256',
  'Get-PropertyValue',
  'Test-HexDigest',
  'Test-ExactProperties',
  'Get-JourneyClassSchedule',
  'Invoke-Adapter',
  'Assert-CommonActionResponse',
  'Assert-Receipt'
)
$FunctionAsts = @{}
foreach ($Name in $RequiredFunctions) {
  $Definition = $Ast.Find(
    { param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $Name },
    $true
  )
  if ($null -eq $Definition) { throw "negative: coordinator function missing: $Name" }
  $FunctionAsts[$Name] = $Definition
  Invoke-Expression $Definition.Extent.Text
}
foreach ($RequiredToken in @(
  'owner-canary-journey-adapter/v1',
  'Invoke-OwnerCanaryHttpsAdapter.ps1',
  'Install-RepositoryHttpsAdapterDefaults',
  'environment_name_presence_and_adapter_identity_only',
  'RedirectStandardInput = $true',
  'owner_canary_adapter_stderr_nonempty',
  'owner_canary_adapter_stdout_not_single_json',
  'allocation_zero_baseline',
  'owner_allocation_enable',
  'kill_switch_drill',
  'old_path_probe',
  'allocation_zero_final',
  'owner-canary-receipts.jsonl'
  'owner-canary-failure.json',
  'source_adapter_digest_sha256',
  'traceability_failure_count',
  'arbitrary_sql_executor_count'
)) {
  if (-not $Source.Contains($RequiredToken)) { throw "negative: coordinator protection missing: $RequiredToken" }
}
if ($Source -match 'Invoke-Expression\s+\$' -or $Source -match 'cmd(?:\.exe)?\s+/c' -or $Source -match 'Write-(?:Host|Output).*runtime_references') {
  throw 'negative: coordinator contains a shell-string or reference-output path'
}

$Protocol = 'owner-canary-adapter/v1'
$JourneyProtocol = 'owner-canary-journey-adapter/v1'
$CandidateHeadOid = 'a' * 40
$OwnerIdentityHash = '1' * 64
$CoordinatorDigest = '2' * 64
$AdapterTimeoutSeconds = 10
$SourceAdapter = [pscustomobject][ordered]@{environment_name='GONOW_RELEASE_B_TRACE_ADAPTER';path='C:\fake.ps1';extension='.ps1';sha256='8'*64}
$Common = [ordered]@{
  schema_version='1.0';protocol=$Protocol;operation='allocation_zero_baseline';status='passed';action_id='3'*64
  candidate_head_oid=$CandidateHeadOid;build_digest_sha256='4'*64;behavior_digest_sha256='5'*64
  expected_generation=7;observed_generation=7;executed_at='2026-08-03T07:00:00Z';cost_usd=0
  redline_failure_count=0;allocation_percent_after=0;allocation_scope='not_applicable'
  non_owner_allocation_count=0;non_owner_request_count=0;kill_switch_seconds=-1;old_path_available=$true
  production=$true;database_kind='postgresql'
}
$CommonObject = $Common | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json
Assert-CommonActionResponse -Response $CommonObject -Operation 'allocation_zero_baseline' -ActionId ('3'*64) -BuildDigest ('4'*64) -BehaviorDigest ('5'*64) -ExpectedGeneration 7 -GenerationDelta 0 -RemainingBudget 0.25
$ExtraCommon = $Common | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json
$ExtraCommon | Add-Member -NotePropertyName unexpected -NotePropertyValue 'rejected'
$Rejected = $false
try { Assert-CommonActionResponse -Response $ExtraCommon -Operation 'allocation_zero_baseline' -ActionId ('3'*64) -BuildDigest ('4'*64) -BehaviorDigest ('5'*64) -ExpectedGeneration 7 -GenerationDelta 0 -RemainingBudget 0.25 }
catch { $Rejected = $true }
if (-not $Rejected) { throw 'negative: action response with unknown field was accepted' }

$Journey = [ordered]@{}
foreach ($Pair in $Common.GetEnumerator()) { $Journey[$Pair.Key] = $Pair.Value }
$Journey.protocol=$JourneyProtocol;$Journey.operation='execute_journey';$Journey.journey_id_sha256='6'*64
$Journey.journey_class='adopt';$Journey.outcome='adopted_once';$Journey.run_id_sha256='7'*64
$Journey.started_at='2026-08-03T07:00:00Z';$Journey.ended_at='2026-08-03T07:00:01Z'
$Journey.provider_call_count=1;$Journey.formal_write_count=1;$Journey.unexpected_write_count=0;$Journey.duplicate_side_effect_count=0;$Journey.live_provider=$true
$JourneyObject = $Journey | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json
Assert-CommonActionResponse -Response $JourneyObject -Operation 'execute_journey' -ActionId ('3'*64) -BuildDigest ('4'*64) -BehaviorDigest ('5'*64) -ExpectedGeneration 7 -GenerationDelta 0 -RemainingBudget 0.25 -ExpectedProtocol $JourneyProtocol -Journey

foreach ($Count in 10..20) {
  $Schedule = @(Get-JourneyClassSchedule -Count $Count)
  if ($Schedule.Count -ne $Count -or @('success','cancel','disconnect_resume','reject','adopt','cas_conflict' | Where-Object { $_ -notin $Schedule }).Count -ne 0) {
    throw "negative: journey schedule does not cover all classes for count $Count"
  }
}

$Trace = [pscustomobject][ordered]@{
  schema_version='1.0';receipt_kind='journey_trace';subject_id_sha256='6'*64;candidate_head_oid=$CandidateHeadOid
  build_digest_sha256='4'*64;behavior_digest_sha256='5'*64;owner_identity_ref_sha256=$OwnerIdentityHash
  adapter_digest_sha256=$CoordinatorDigest;status='passed';redline_failure_count=0;executed_at='2026-08-03T07:00:01Z'
  source_adapter_environment_name=$SourceAdapter.environment_name;source_adapter_digest_sha256=$SourceAdapter.sha256
  run_id_sha256='7'*64;journey_class='adopt';outcome='adopted_once';started_at='2026-08-03T07:00:00Z';ended_at='2026-08-03T07:00:01Z'
  traceability_failure_count=0;alert_wiring_verified=$true
}
Assert-Receipt -Receipt $Trace -Kind 'journey_trace' -JourneyId ('6'*64) -BuildDigest ('4'*64) -BehaviorDigest ('5'*64) -SourceAdapter $SourceAdapter
$Trace | Add-Member -NotePropertyName prompt -NotePropertyValue 'must be rejected'
$Rejected = $false
try { Assert-Receipt -Receipt $Trace -Kind 'journey_trace' -JourneyId ('6'*64) -BuildDigest ('4'*64) -BehaviorDigest ('5'*64) -SourceAdapter $SourceAdapter }
catch { $Rejected = $true }
if (-not $Rejected) { throw 'negative: receipt with prompt field was accepted' }

$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("gonow-owner-canary-adapter-$([Guid]::NewGuid().ToString('N'))")
$FakeAdapter = Join-Path $TemporaryRoot 'fake-adapter.ps1'
$SavedEnvironment = @{}
$Names = @(
  'GONOW_AGENT_API_URL','GONOW_OWNER_CANARY_IDENTITY_REF','GONOW_OWNER_CANARY_CREDENTIAL_PROVIDER',
  'GONOW_RELEASE_B_BUDGET_CAP_REF','GONOW_RELEASE_B_JOURNEY_ADAPTER','GONOW_RELEASE_B_FLAG_ADAPTER',
  'GONOW_RELEASE_B_AUDIT_ADAPTER','GONOW_RELEASE_B_KILL_SWITCH_ADAPTER','GONOW_RELEASE_B_OLD_PATH_ADAPTER',
  'GONOW_RELEASE_B_TRACE_ADAPTER','GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER'
)
try {
  New-Item -ItemType Directory -Path $TemporaryRoot -Force | Out-Null
  [IO.File]::WriteAllText(
    $FakeAdapter,
    "`$raw=[Console]::In.ReadLine()`n[ordered]@{schema_version='1.0';ok=`$true}|ConvertTo-Json -Compress`n",
    [Text.UTF8Encoding]::new($false)
  )
  foreach ($Name in $Names) {
    $SavedEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($Name -like '*_ADAPTER') { [Environment]::SetEnvironmentVariable($Name, $FakeAdapter, 'Process') }
    else { [Environment]::SetEnvironmentVariable($Name, 'secret-sentinel-must-not-appear', 'Process') }
  }
  $Output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath -CandidateHeadOid $Candidate -ValidateInputsOnly 2>&1)
  $ExitCode = $LASTEXITCODE
  $Text = $Output -join "`n"
  if ($ExitCode -ne 0 -or $Text -match 'secret-sentinel-must-not-appear') {
    throw 'positive: name-only readiness failed or exposed a value'
  }
  $Ready = $Text | ConvertFrom-Json -ErrorAction Stop
  if (-not [bool]$Ready.passed -or [int]$Ready.secret_value_read_count -ne 0 -or @($Ready.adapter_inventory | Where-Object { -not [bool]$_.valid_absolute_non_reparse_executable }).Count -ne 0) {
    throw 'positive: complete readiness inventory was rejected'
  }
  [Environment]::SetEnvironmentVariable('GONOW_RELEASE_B_TRACE_ADAPTER', 'relative-adapter.ps1', 'Process')
  $MissingOutput = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath -CandidateHeadOid $Candidate -ValidateInputsOnly 2>&1)
  if ($LASTEXITCODE -eq 0 -or ($MissingOutput -join "`n") -match 'secret-sentinel-must-not-appear') {
    throw 'negative: invalid explicit adapter reference was replaced or leaked a value'
  }
} finally {
  foreach ($Name in $Names) { [Environment]::SetEnvironmentVariable($Name, $SavedEnvironment[$Name], 'Process') }
  if (Test-Path -LiteralPath $TemporaryRoot -PathType Container) { Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force }
}

Write-Output 'Invoke-PersonalOwnerCanary contracts passed'
exit 0

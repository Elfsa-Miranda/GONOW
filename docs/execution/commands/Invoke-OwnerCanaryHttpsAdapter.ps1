[CmdletBinding()]
param([switch]$LibraryOnly)

$ErrorActionPreference = 'Stop'
$Protocol = 'owner-canary-adapter/v1'
$JourneyProtocol = 'owner-canary-journey-adapter/v1'
$RelayProtocol = 'owner-canary-https-relay/v1'
$CredentialProtocol = 'owner-canary-credential-provider/v1'
$Target = 'gonow.agent.itinerary_planning.release_b'
$ControlPath = '/.well-known/gonow-owner-canary/v1/adapter'

function Get-OwnerCanarySha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
}

function Get-OwnerCanaryUtf8Sha256 {
  param([Parameter(Mandatory = $true)][string]$Value)
  $Algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  } finally { $Algorithm.Dispose() }
}

function Get-OwnerCanaryProperty {
  param([object]$Object,[string]$Name,[object]$Default = $null)
  if ($null -eq $Object) { return $Default }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property) { return $Default }
  return $Property.Value
}

function Test-OwnerCanaryExactProperties {
  param([Parameter(Mandatory = $true)][object]$Object,[Parameter(Mandatory = $true)][string[]]$Expected)
  if ($null -eq $Object) { return $false }
  $Actual = @($Object.PSObject.Properties.Name | Sort-Object)
  $Wanted = @($Expected | Sort-Object)
  return ($Actual -join "`n") -ceq ($Wanted -join "`n")
}

function Test-OwnerCanaryHex {
  param([object]$Value,[int]$Length = 64)
  return [string]$Value -cmatch "^[0-9a-f]{$Length}$"
}

function ConvertFrom-OwnerCanarySingleJson {
  param([Parameter(Mandatory = $true)][string]$Raw,[ValidateRange(1,262144)][int]$MaximumBytes = 131072)
  if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt $MaximumBytes) { throw 'owner_canary_https_json_too_large' }
  $Lines = @($Raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($Lines.Count -ne 1) { throw 'owner_canary_https_json_not_single_line' }
  try { $Value = $Lines[0] | ConvertFrom-Json -ErrorAction Stop }
  catch { throw 'owner_canary_https_json_invalid' }
  if ($null -eq $Value -or $Value -is [Array] -or $Value -is [string] -or $Value -is [ValueType]) {
    throw 'owner_canary_https_json_object_required'
  }
  return $Value
}

function Assert-OwnerCanaryNoSensitiveResponseFields {
  param([Parameter(Mandatory = $true)][object]$Value)
  $Forbidden = '(?i)(?:^|_)(?:secret|token|credential|authorization|prompt|response|reasoning|endpoint|pii)(?:_|$)'
  $Queue = [Collections.Generic.Queue[object]]::new()
  $Queue.Enqueue($Value)
  while ($Queue.Count -gt 0) {
    $Current = $Queue.Dequeue()
    if ($null -eq $Current -or $Current -is [string] -or $Current -is [ValueType]) { continue }
    if ($Current -is [Collections.IEnumerable] -and $Current -isnot [Management.Automation.PSCustomObject]) {
      foreach ($Item in $Current) { if ($null -ne $Item) { $Queue.Enqueue($Item) } }
      continue
    }
    foreach ($Property in $Current.PSObject.Properties) {
      if ($Property.Name -match $Forbidden) { throw 'owner_canary_https_sensitive_response_field' }
      if ($null -ne $Property.Value) { $Queue.Enqueue($Property.Value) }
    }
  }
}

function Get-OwnerCanaryAdapterEnvironmentName {
  param([Parameter(Mandatory = $true)][string]$Operation)
  $EnvironmentName = switch ($Operation) {
    'allocation_zero_baseline' { 'GONOW_RELEASE_B_FLAG_ADAPTER' }
    'owner_allocation_enable' { 'GONOW_RELEASE_B_FLAG_ADAPTER' }
    'allocation_zero_final' { 'GONOW_RELEASE_B_FLAG_ADAPTER' }
    'execute_journey' { 'GONOW_RELEASE_B_JOURNEY_ADAPTER' }
    'kill_switch_drill' { 'GONOW_RELEASE_B_KILL_SWITCH_ADAPTER' }
    'old_path_probe' { 'GONOW_RELEASE_B_OLD_PATH_ADAPTER' }
    'get_journey_trace' { 'GONOW_RELEASE_B_TRACE_ADAPTER' }
    'get_journey_audit' { 'GONOW_RELEASE_B_AUDIT_ADAPTER' }
    'get_provider_usage' { 'GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER' }
    default { throw 'owner_canary_https_operation_unknown' }
  }
  return $EnvironmentName
}

function Assert-OwnerCanaryRequest {
  param([Parameter(Mandatory = $true)][object]$Request)
  $Common = @(
    'schema_version','protocol','operation','target','candidate_head_oid','build_digest_sha256',
    'behavior_digest_sha256','coordinator_digest_sha256','action_id','attempt_id_sha256',
    'expected_generation','deadline','remaining_budget_usd','runtime_references'
  )
  $Journey = @('journey_id_sha256','journey_class')
  $Operation = [string](Get-OwnerCanaryProperty $Request 'operation' '')
  $Expected = if ($Operation -ceq 'execute_journey') { @($Common + $Journey) } elseif ($Operation -in @(
      'allocation_zero_baseline','owner_allocation_enable','allocation_zero_final','kill_switch_drill',
      'old_path_probe','get_journey_trace','get_journey_audit','get_provider_usage')) {
    $ReceiptExtras = if ($Operation -like 'get_*') { @('journey_id_sha256','run_id_sha256') } else { @() }
    @($Common + $ReceiptExtras)
  } else { throw 'owner_canary_https_operation_unknown' }
  if (-not (Test-OwnerCanaryExactProperties -Object $Request -Expected $Expected)) { throw 'owner_canary_https_request_schema_invalid' }
  $ExpectedProtocol = if ($Operation -ceq 'execute_journey') { $JourneyProtocol } else { $Protocol }
  $Deadline = [DateTimeOffset]::MinValue
  $DeadlineValid = [DateTimeOffset]::TryParse([string]$Request.deadline,[ref]$Deadline)
  $Now = [DateTimeOffset]::Now
  if ([string]$Request.schema_version -cne '1.0' -or [string]$Request.protocol -cne $ExpectedProtocol -or
      [string]$Request.target -cne $Target -or -not (Test-OwnerCanaryHex $Request.action_id) -or
      -not (Test-OwnerCanaryHex $Request.attempt_id_sha256) -or -not (Test-OwnerCanaryHex $Request.build_digest_sha256) -or
      -not (Test-OwnerCanaryHex $Request.behavior_digest_sha256) -or -not (Test-OwnerCanaryHex $Request.coordinator_digest_sha256) -or
      [string]$Request.candidate_head_oid -cnotmatch '^[0-9a-f]{40,64}$' -or [long]$Request.expected_generation -lt 0 -or
      [double]$Request.remaining_budget_usd -lt 0 -or [double]$Request.remaining_budget_usd -gt 0.250000001 -or
      -not $DeadlineValid -or $Deadline -le $Now -or $Deadline -gt $Now.AddMinutes(11)) {
    throw 'owner_canary_https_request_binding_invalid'
  }
  if ($Operation -ceq 'execute_journey') {
    if (-not (Test-OwnerCanaryHex $Request.journey_id_sha256) -or [string]$Request.journey_class -notin @(
        'success','cancel','disconnect_resume','reject','adopt','cas_conflict')) { throw 'owner_canary_https_journey_invalid' }
  }
  if ($Operation -like 'get_*' -and (-not (Test-OwnerCanaryHex $Request.journey_id_sha256) -or -not (Test-OwnerCanaryHex $Request.run_id_sha256))) {
    throw 'owner_canary_https_receipt_binding_invalid'
  }
  $References = $Request.runtime_references
  if (-not (Test-OwnerCanaryExactProperties -Object $References -Expected @('endpoint','owner_identity','credential_provider','budget_cap'))) {
    throw 'owner_canary_https_runtime_reference_schema_invalid'
  }
  foreach ($Name in @('endpoint','owner_identity','credential_provider','budget_cap')) {
    $Text = [string](Get-OwnerCanaryProperty $References $Name '')
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 8192 -or $Text.Contains("`r") -or $Text.Contains("`n")) {
      throw 'owner_canary_https_runtime_reference_invalid'
    }
  }
  return [ordered]@{ operation=$Operation; deadline=$Deadline }
}

function Resolve-OwnerCanaryProviderReference {
  param([Parameter(Mandatory = $true)][string]$Reference,[Parameter(Mandatory = $true)][uri]$Endpoint)
  $Provider = ConvertFrom-OwnerCanarySingleJson -Raw $Reference -MaximumBytes 16384
  $Properties = @('schema_version','provider','executable','sha256','vault','secret_name','allowed_host')
  if (-not (Test-OwnerCanaryExactProperties -Object $Provider -Expected $Properties) -or
      [string]$Provider.schema_version -cne '1.0' -or [string]$Provider.provider -cne 'powershell-secretmanagement-v1' -or
      [string]$Provider.vault -cnotmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$' -or
      [string]$Provider.secret_name -cnotmatch '^[A-Za-z][A-Za-z0-9_.-]{0,127}$' -or
      [string]$Provider.allowed_host -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' -or
      [string]$Provider.allowed_host -cne $Endpoint.DnsSafeHost -or -not (Test-OwnerCanaryHex $Provider.sha256)) {
    throw 'owner_canary_https_provider_reference_invalid'
  }
  $Path = [string]$Provider.executable
  if (-not [IO.Path]::IsPathRooted($Path)) { throw 'owner_canary_https_provider_path_not_absolute' }
  $FullPath = [IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { throw 'owner_canary_https_provider_unavailable' }
  $Item = Get-Item -LiteralPath $FullPath -Force
  if ([bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [IO.Path]::GetExtension($FullPath).ToLowerInvariant() -notin @('.ps1','.exe')) {
    throw 'owner_canary_https_provider_executable_invalid'
  }
  if ((Get-OwnerCanarySha256 -LiteralPath $FullPath) -cne [string]$Provider.sha256) { throw 'owner_canary_https_provider_digest_mismatch' }
  return [ordered]@{ path=$FullPath;extension=[IO.Path]::GetExtension($FullPath).ToLowerInvariant();sha256=[string]$Provider.sha256;vault=[string]$Provider.vault;secret_name=[string]$Provider.secret_name }
}

function Resolve-OwnerCanaryEndpoint {
  param([Parameter(Mandatory = $true)][string]$Value)
  $Uri = $null
  if (-not [Uri]::TryCreate($Value,[UriKind]::Absolute,[ref]$Uri) -or $Uri.Scheme -cne 'https' -or
      -not [string]::IsNullOrEmpty($Uri.UserInfo) -or -not [string]::IsNullOrEmpty($Uri.Query) -or
      -not [string]::IsNullOrEmpty($Uri.Fragment) -or $Uri.AbsolutePath -notin @('','/') -or
      [string]::IsNullOrWhiteSpace($Uri.DnsSafeHost) -or $Uri.IsLoopback -or
      $Uri.DnsSafeHost -in @('localhost','localhost.localdomain') -or $Uri.DnsSafeHost.EndsWith('.local')) {
    throw 'owner_canary_https_endpoint_invalid'
  }
  $ParsedAddress = $null
  if ([Net.IPAddress]::TryParse($Uri.DnsSafeHost,[ref]$ParsedAddress)) { throw 'owner_canary_https_ip_literal_forbidden' }
  return $Uri
}

function Invoke-OwnerCanaryJsonProcess {
  param(
    [Parameter(Mandatory = $true)][object]$Executable,
    [Parameter(Mandatory = $true)][object]$Request,
    [Parameter(Mandatory = $true)][DateTimeOffset]$Deadline
  )
  $StartInfo = [Diagnostics.ProcessStartInfo]::new()
  if ([string]$Executable.extension -ceq '.ps1') {
    $Pwsh = Get-Command pwsh.exe -ErrorAction Stop
    $StartInfo.FileName = $Pwsh.Source
    $StartInfo.Arguments = "-NoLogo -NoProfile -NonInteractive -File `"$([string]$Executable.path)`""
  } else { $StartInfo.FileName = [string]$Executable.path; $StartInfo.Arguments = '' }
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardInput = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
  $StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
  $Process = [Diagnostics.Process]::new(); $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) { throw 'owner_canary_https_provider_start_failed' }
    $Process.StandardInput.WriteLine(($Request | ConvertTo-Json -Depth 20 -Compress)); $Process.StandardInput.Close()
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync(); $StderrTask = $Process.StandardError.ReadToEndAsync()
    $RemainingMs = [Math]::Max(1,[Math]::Floor(($Deadline-[DateTimeOffset]::Now).TotalMilliseconds))
    if (-not $Process.WaitForExit([int][Math]::Min([int]::MaxValue,$RemainingMs))) {
      try { $Process.Kill() } catch {}; throw 'owner_canary_https_provider_timeout'
    }
    $Stdout = $StdoutTask.GetAwaiter().GetResult(); $Stderr = $StderrTask.GetAwaiter().GetResult()
    if ($Process.ExitCode -ne 0) { throw "owner_canary_https_provider_nonzero:$($Process.ExitCode)" }
    if (-not [string]::IsNullOrWhiteSpace($Stderr)) { throw 'owner_canary_https_provider_stderr_nonempty' }
    return ConvertFrom-OwnerCanarySingleJson -Raw $Stdout -MaximumBytes 32768
  } finally { $Process.Dispose() }
}

function Resolve-OwnerCanaryCredential {
  param(
    [Parameter(Mandatory = $true)][object]$Provider,
    [Parameter(Mandatory = $true)][string]$OwnerIdentityHash,
    [Parameter(Mandatory = $true)][DateTimeOffset]$Deadline
  )
  $Request = [ordered]@{
    schema_version='1.0';protocol=$CredentialProtocol;operation='resolve_bearer';vault=[string]$Provider.vault
    secret_name=[string]$Provider.secret_name;owner_identity_ref_sha256=$OwnerIdentityHash;deadline=$Deadline.ToString('o')
  }
  $Credential = Invoke-OwnerCanaryJsonProcess -Executable $Provider -Request $Request -Deadline $Deadline
  $Expected = @('schema_version','protocol','status','authorization_scheme','access_token','expires_at','owner_identity_ref_sha256')
  $Expires = [DateTimeOffset]::MinValue
  $ExpiresValid = [DateTimeOffset]::TryParse([string](Get-OwnerCanaryProperty $Credential 'expires_at' ''),[ref]$Expires)
  $Token = [string](Get-OwnerCanaryProperty $Credential 'access_token' '')
  if (-not (Test-OwnerCanaryExactProperties -Object $Credential -Expected $Expected) -or
      [string]$Credential.schema_version -cne '1.0' -or [string]$Credential.protocol -cne $CredentialProtocol -or
      [string]$Credential.status -cne 'passed' -or [string]$Credential.authorization_scheme -cne 'Bearer' -or
      [string]$Credential.owner_identity_ref_sha256 -cne $OwnerIdentityHash -or -not $ExpiresValid -or $Expires -lt $Deadline -or
      $Token.Length -lt 16 -or $Token.Length -gt 8192 -or $Token -match '\s') {
    throw 'owner_canary_https_credential_invalid'
  }
  return [ordered]@{ token=$Token;expires_at=$Expires;provider_sha256=[string]$Provider.sha256 }
}

function Invoke-OwnerCanaryControlPlane {
  param(
    [Parameter(Mandatory = $true)][uri]$Uri,
    [Parameter(Mandatory = $true)][string]$Json,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][DateTimeOffset]$Deadline,
    [scriptblock]$TransportOverride
  )
  if ($null -ne $TransportOverride) { return & $TransportOverride $Uri $Json $Token $Deadline }
  Add-Type -AssemblyName System.Net.Http
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $Handler = [Net.Http.HttpClientHandler]::new()
  $Handler.AllowAutoRedirect = $false; $Handler.UseCookies = $false
  $Client = [Net.Http.HttpClient]::new($Handler)
  $Request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$Uri)
  $Request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$Token)
  $Request.Headers.Accept.Add([Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new('application/json'))
  $Request.Content = [Net.Http.StringContent]::new($Json,[Text.Encoding]::UTF8,'application/json')
  $Cancellation = [Threading.CancellationTokenSource]::new()
  try {
    $RemainingMs = [Math]::Max(1,[Math]::Floor(($Deadline-[DateTimeOffset]::Now).TotalMilliseconds))
    $Cancellation.CancelAfter([int][Math]::Min([int]::MaxValue,$RemainingMs))
    $Response = $Client.SendAsync($Request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead,$Cancellation.Token).GetAwaiter().GetResult()
    try {
      $Bytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
      if ($Bytes.Length -gt 262144) { throw 'owner_canary_https_control_response_too_large' }
      $MediaType = if ($null-ne$Response.Content.Headers.ContentType) { [string]$Response.Content.Headers.ContentType.MediaType } else { '' }
      return [ordered]@{status_code=[int]$Response.StatusCode;content_type=$MediaType;body=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)}
    } finally { $Response.Dispose() }
  } finally { $Cancellation.Dispose();$Request.Dispose();$Client.Dispose();$Handler.Dispose() }
}

function Assert-OwnerCanaryActionResponse {
  param([object]$Response,[object]$Request)
  $Common = @(
    'schema_version','protocol','operation','status','action_id','candidate_head_oid','build_digest_sha256',
    'behavior_digest_sha256','expected_generation','observed_generation','executed_at','cost_usd','redline_failure_count',
    'allocation_percent_after','allocation_scope','non_owner_allocation_count','non_owner_request_count','kill_switch_seconds',
    'old_path_available','production','database_kind'
  )
  $Journey = @('journey_id_sha256','journey_class','outcome','run_id_sha256','started_at','ended_at','provider_call_count',
    'formal_write_count','unexpected_write_count','duplicate_side_effect_count','live_provider')
  $Operation = [string]$Request.operation
  $Expected = if ($Operation -ceq 'execute_journey') { @($Common+$Journey) } else { $Common }
  $Executed = [DateTimeOffset]::MinValue
  $TimestampValid = [DateTimeOffset]::TryParse([string](Get-OwnerCanaryProperty $Response 'executed_at' ''),[ref]$Executed)
  $Delta = if ($Operation -in @('owner_allocation_enable','allocation_zero_final','kill_switch_drill')) { 1 } else { 0 }
  $ExpectedProtocol = if ($Operation -ceq 'execute_journey') { $JourneyProtocol } else { $Protocol }
  $BuildMatches = if ($Operation -ceq 'allocation_zero_baseline') { Test-OwnerCanaryHex $Response.build_digest_sha256 } else { [string]$Response.build_digest_sha256 -ceq [string]$Request.build_digest_sha256 }
  $BehaviorMatches = if ($Operation -ceq 'allocation_zero_baseline') { Test-OwnerCanaryHex $Response.behavior_digest_sha256 } else { [string]$Response.behavior_digest_sha256 -ceq [string]$Request.behavior_digest_sha256 }
  if (-not (Test-OwnerCanaryExactProperties $Response $Expected) -or [string]$Response.schema_version -cne '1.0' -or
      [string]$Response.protocol -cne $ExpectedProtocol -or [string]$Response.operation -cne $Operation -or [string]$Response.status -cne 'passed' -or
      [string]$Response.action_id -cne [string]$Request.action_id -or [string]$Response.candidate_head_oid -cne [string]$Request.candidate_head_oid -or
      -not $BuildMatches -or -not $BehaviorMatches -or [long]$Response.expected_generation -ne [long]$Request.expected_generation -or
      [long]$Response.observed_generation -ne ([long]$Request.expected_generation+$Delta) -or -not $TimestampValid -or
      [double]$Response.cost_usd -lt 0 -or [double]$Response.cost_usd -gt ([double]$Request.remaining_budget_usd+0.000000001) -or
      [int]$Response.redline_failure_count -ne 0 -or [int]$Response.allocation_percent_after -lt 0 -or [int]$Response.allocation_percent_after -gt 100 -or
      [int]$Response.non_owner_allocation_count -ne 0 -or [int]$Response.non_owner_request_count -ne 0 -or
      -not [bool]$Response.production -or [string]$Response.database_kind -cne 'postgresql') {
    throw 'owner_canary_https_action_response_invalid'
  }
  if ($Operation -ceq 'execute_journey') {
    $ExpectedOutcome = @{success='succeeded';cancel='cancelled';disconnect_resume='succeeded_after_resume';reject='rejected_no_formal_write';adopt='adopted_once';cas_conflict='conflict_no_duplicate'}[[string]$Request.journey_class]
    if ([string]$Response.journey_id_sha256 -cne [string]$Request.journey_id_sha256 -or [string]$Response.journey_class -cne [string]$Request.journey_class -or
        [string]$Response.outcome -cne $ExpectedOutcome -or -not (Test-OwnerCanaryHex $Response.run_id_sha256) -or -not [bool]$Response.live_provider -or
        [int]$Response.unexpected_write_count -ne 0 -or [int]$Response.duplicate_side_effect_count -ne 0 -or
        [int]$Response.formal_write_count -ne $(if([string]$Request.journey_class -ceq 'adopt'){1}else{0})) {
      throw 'owner_canary_https_journey_response_invalid'
    }
  }
}

function Assert-OwnerCanaryReceiptResponse {
  param([object]$Response,[object]$Request,[string]$EnvironmentName,[string]$AdapterDigest,[string]$OwnerIdentityHash)
  $Common = @('schema_version','receipt_kind','subject_id_sha256','candidate_head_oid','build_digest_sha256','behavior_digest_sha256',
    'owner_identity_ref_sha256','adapter_digest_sha256','status','redline_failure_count','executed_at','run_id_sha256',
    'source_adapter_environment_name','source_adapter_digest_sha256')
  $Kind = switch ([string]$Request.operation) {
    'get_journey_trace' { 'journey_trace' }
    'get_journey_audit' { 'journey_audit' }
    'get_provider_usage' { 'provider_usage' }
    default { throw 'owner_canary_https_receipt_operation_invalid' }
  }
  $Extra = switch ($Kind) {
    'journey_trace' { @('journey_class','outcome','started_at','ended_at','traceability_failure_count','alert_wiring_verified') }
    'journey_audit' { @('formal_write_count','unexpected_write_count','duplicate_side_effect_count','duplicate_formal_side_effect_count','arbitrary_sql_executor_count','cross_tenant_leak_count','unauthorized_write_count','secret_or_pii_leak_count','permanent_run_count','missing_audit_receipt_count','forbidden_tool_execution_count') }
    'provider_usage' { @('provider_call_count','usage_receipt_count','cost_usd','live_provider') }
  }
  $Executed = [DateTimeOffset]::MinValue
  if (-not (Test-OwnerCanaryExactProperties $Response @($Common+$Extra)) -or [string]$Response.schema_version -cne '1.0' -or
      [string]$Response.receipt_kind -cne $Kind -or [string]$Response.subject_id_sha256 -cne [string]$Request.journey_id_sha256 -or
      [string]$Response.candidate_head_oid -cne [string]$Request.candidate_head_oid -or [string]$Response.build_digest_sha256 -cne [string]$Request.build_digest_sha256 -or
      [string]$Response.behavior_digest_sha256 -cne [string]$Request.behavior_digest_sha256 -or [string]$Response.owner_identity_ref_sha256 -cne $OwnerIdentityHash -or
      [string]$Response.adapter_digest_sha256 -cne [string]$Request.coordinator_digest_sha256 -or [string]$Response.status -cne 'passed' -or
      [int]$Response.redline_failure_count -ne 0 -or -not [DateTimeOffset]::TryParse([string]$Response.executed_at,[ref]$Executed) -or
      [string]$Response.run_id_sha256 -cne [string]$Request.run_id_sha256 -or [string]$Response.source_adapter_environment_name -cne $EnvironmentName -or
      [string]$Response.source_adapter_digest_sha256 -cne $AdapterDigest) { throw 'owner_canary_https_receipt_response_invalid' }
  if ($Kind -ceq 'journey_trace' -and ([int]$Response.traceability_failure_count -ne 0 -or -not [bool]$Response.alert_wiring_verified)) { throw 'owner_canary_https_trace_redline' }
  if ($Kind -ceq 'journey_audit') {
    foreach ($Field in @('unexpected_write_count','duplicate_side_effect_count','duplicate_formal_side_effect_count','arbitrary_sql_executor_count','cross_tenant_leak_count','unauthorized_write_count','secret_or_pii_leak_count','permanent_run_count','missing_audit_receipt_count','forbidden_tool_execution_count')) {
      if ([int](Get-OwnerCanaryProperty $Response $Field 1) -ne 0) { throw 'owner_canary_https_audit_redline' }
    }
  }
  if ($Kind -ceq 'provider_usage' -and ([int]$Response.provider_call_count -lt 0 -or [int]$Response.usage_receipt_count -ne [int]$Response.provider_call_count -or [double]$Response.cost_usd -lt 0 -or -not [bool]$Response.live_provider)) {
    throw 'owner_canary_https_usage_invalid'
  }
}

function Invoke-OwnerCanaryHttpsAdapterMain {
  $Raw = [Console]::In.ReadToEnd()
  $Request = ConvertFrom-OwnerCanarySingleJson -Raw $Raw
  $RequestState = Assert-OwnerCanaryRequest -Request $Request
  $Endpoint = Resolve-OwnerCanaryEndpoint -Value ([string]$Request.runtime_references.endpoint)
  $Provider = Resolve-OwnerCanaryProviderReference -Reference ([string]$Request.runtime_references.credential_provider) -Endpoint $Endpoint
  $OwnerIdentityHash = Get-OwnerCanaryUtf8Sha256 -Value ([string]$Request.runtime_references.owner_identity)
  $Credential = Resolve-OwnerCanaryCredential -Provider $Provider -OwnerIdentityHash $OwnerIdentityHash -Deadline $RequestState.deadline
  $AdapterDigest = Get-OwnerCanarySha256 -LiteralPath $PSCommandPath
  $EnvironmentName = Get-OwnerCanaryAdapterEnvironmentName -Operation $RequestState.operation
  $Relay = [ordered]@{
    schema_version='1.0';protocol=$RelayProtocol
    adapter_binding=[ordered]@{environment_name=$EnvironmentName;sha256=$AdapterDigest}
    credential_binding=[ordered]@{provider_sha256=[string]$Credential.provider_sha256;owner_identity_ref_sha256=$OwnerIdentityHash}
    request=$Request
  }
  $ControlUri = [Uri]::new($Endpoint.AbsoluteUri.TrimEnd('/')+$ControlPath)
  $Transport = Invoke-OwnerCanaryControlPlane -Uri $ControlUri -Json ($Relay|ConvertTo-Json -Depth 30 -Compress) -Token ([string]$Credential.token) -Deadline $RequestState.deadline
  if ([int]$Transport.status_code -ne 200 -or [string]$Transport.content_type -cne 'application/json') { throw 'owner_canary_https_control_response_invalid' }
  $Response = ConvertFrom-OwnerCanarySingleJson -Raw ([string]$Transport.body) -MaximumBytes 262144
  Assert-OwnerCanaryNoSensitiveResponseFields -Value $Response
  if ($RequestState.operation -like 'get_*') {
    Assert-OwnerCanaryReceiptResponse -Response $Response -Request $Request -EnvironmentName $EnvironmentName -AdapterDigest $AdapterDigest -OwnerIdentityHash $OwnerIdentityHash
  } else { Assert-OwnerCanaryActionResponse -Response $Response -Request $Request }
  [Console]::Out.WriteLine(($Response | ConvertTo-Json -Depth 30 -Compress))
}

if (-not $LibraryOnly) {
  try { Invoke-OwnerCanaryHttpsAdapterMain; exit 0 }
  catch {
    $Code = if ([string]$_.Exception.Message -cmatch '^owner_canary_https_[a-z0-9_:]+$') { [string]$_.Exception.Message } else { 'owner_canary_https_adapter_failed' }
    [Console]::Error.WriteLine($Code)
    exit 10
  }
}

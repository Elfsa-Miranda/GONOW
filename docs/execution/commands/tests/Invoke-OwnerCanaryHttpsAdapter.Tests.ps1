[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$CommandRoot = Split-Path -Parent $PSScriptRoot
$AdapterPath = Join-Path $CommandRoot 'Invoke-OwnerCanaryHttpsAdapter.ps1'
$ProviderPath = Join-Path $CommandRoot 'Get-OwnerCanarySecretManagementCredential.ps1'
$ReferenceBuilderPath = Join-Path $CommandRoot 'New-OwnerCanarySecretManagementReference.ps1'
$AdapterSource = Get-Content -LiteralPath $AdapterPath -Raw -Encoding UTF8
$ProviderSource = Get-Content -LiteralPath $ProviderPath -Raw -Encoding UTF8

foreach ($Path in @($AdapterPath,$ProviderPath,$ReferenceBuilderPath)) {
  $Tokens=$null;$Errors=$null
  [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$Tokens,[ref]$Errors)|Out-Null
  if (@($Errors).Count-ne0) { throw "positive: PowerShell parse failed for $Path" }
}
foreach ($Marker in @(
  'owner-canary-https-relay/v1','owner-canary-credential-provider/v1','/.well-known/gonow-owner-canary/v1/adapter',
  'AllowAutoRedirect = $false','UseCookies = $false','ResponseHeadersRead','powershell-secretmanagement-v1',
  'owner_canary_https_sensitive_response_field','source_adapter_digest_sha256','owner_identity_ref_sha256'
)) { if (-not$AdapterSource.Contains($Marker)) { throw "negative: HTTPS adapter marker missing: $Marker" } }
foreach ($Marker in @('Microsoft.PowerShell.SecretManagement','RequiredVersion 1.1.2','Microsoft.PowerShell.SecretStore','RequiredVersion 1.0.6','Test-SecretVault','Get-SecretInfo','Get-Secret')) {
  if (-not$ProviderSource.Contains($Marker)) { throw "negative: SecretManagement provider marker missing: $Marker" }
}
if ($AdapterSource-match'Invoke-Expression|SkipCertificateCheck|DangerousAcceptAnyServerCertificateValidator|ServerCertificateCustomValidationCallback') {
  throw 'negative: HTTPS adapter contains a shell or TLS verification bypass'
}
if ($ProviderSource-match'GONOW_.*TOKEN|EnvironmentVariable|Write-(?:Host|Verbose|Debug)') {
  throw 'negative: credential provider reads an environment token or exposes diagnostics'
}
$BuiltReference = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ReferenceBuilderPath -Vault 'GoNowOwnerCanary' -SecretName 'release-b-owner-token' -AllowedHost 'agent.example.net' | ConvertFrom-Json
if ($LASTEXITCODE-ne0-or[string]$BuiltReference.provider-cne'powershell-secretmanagement-v1'-or[string]$BuiltReference.executable-cne$ProviderPath-or[string]$BuiltReference.sha256-cne(Get-FileHash -Algorithm SHA256 -LiteralPath $ProviderPath).Hash.ToLowerInvariant()) {
  throw 'positive: SecretManagement reference builder did not bind the tracked provider'
}

. $AdapterPath -LibraryOnly
$Candidate = 'a'*40
$Coordinator = 'b'*64
$Action = 'c'*64
$Attempt = 'd'*64
$Build = 'e'*64
$Behavior = 'f'*64
$Journey = '1'*64
$Run = '2'*64
$Deadline = [DateTimeOffset]::Now.AddMinutes(3)
$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("gonow-owner-canary-https-$([Guid]::NewGuid().ToString('N'))")
$FakeProvider = Join-Path $TemporaryRoot 'fake-provider.ps1'
try {
  New-Item -ItemType Directory -Path $TemporaryRoot -Force|Out-Null
  $FakeProviderSource = @'
$request=[Console]::In.ReadToEnd()|ConvertFrom-Json
$result=[ordered]@{schema_version='1.0';protocol='owner-canary-credential-provider/v1';status='passed';authorization_scheme='Bearer';access_token='synthetic-test-bearer-value';expires_at=([DateTimeOffset]::Now.AddMinutes(5).ToString('o'));owner_identity_ref_sha256=[string]$request.owner_identity_ref_sha256}
[Console]::Out.WriteLine(($result|ConvertTo-Json -Compress))
'@
  [IO.File]::WriteAllText($FakeProvider,$FakeProviderSource,[Text.UTF8Encoding]::new($false))
  $FakeProviderHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $FakeProvider).Hash.ToLowerInvariant()
  $ProviderReference = [ordered]@{schema_version='1.0';provider='powershell-secretmanagement-v1';executable=$FakeProvider;sha256=$FakeProviderHash;vault='GoNowOwnerCanary';secret_name='release-b-owner-token';allowed_host='agent.example.net'}|ConvertTo-Json -Compress
  $RuntimeReferences = [ordered]@{endpoint='https://agent.example.net';owner_identity='owner-ref:test';credential_provider=$ProviderReference;budget_cap='budget://release-b/quarter-dollar'}
  $BaseRequest = [ordered]@{schema_version='1.0';protocol=$Protocol;operation='allocation_zero_baseline';target=$Target;candidate_head_oid=$Candidate;build_digest_sha256='0'*64;behavior_digest_sha256='0'*64;coordinator_digest_sha256=$Coordinator;action_id=$Action;attempt_id_sha256=$Attempt;expected_generation=0;deadline=$Deadline.ToString('o');remaining_budget_usd=0.25;runtime_references=$RuntimeReferences}
  $RequestObject = $BaseRequest|ConvertTo-Json -Depth 10 -Compress|ConvertFrom-Json
  $State = Assert-OwnerCanaryRequest -Request $RequestObject
  if ([string]$State.operation-cne'allocation_zero_baseline') { throw 'positive: valid request state was not resolved' }
  $Endpoint = Resolve-OwnerCanaryEndpoint -Value ([string]$RuntimeReferences.endpoint)
  $Provider = Resolve-OwnerCanaryProviderReference -Reference $ProviderReference -Endpoint $Endpoint
  $OwnerHash = Get-OwnerCanaryUtf8Sha256 -Value ([string]$RuntimeReferences.owner_identity)
  $Credential = Resolve-OwnerCanaryCredential -Provider $Provider -OwnerIdentityHash $OwnerHash -Deadline $Deadline
  if ([string]$Credential.token-cne'synthetic-test-bearer-value'-or[string]$Credential.provider_sha256-cne$FakeProviderHash) { throw 'positive: measured credential provider result was rejected' }
  $Transport = Invoke-OwnerCanaryControlPlane -Uri ([uri]'https://agent.example.net/.well-known/gonow-owner-canary/v1/adapter') -Json '{}' -Token ([string]$Credential.token) -Deadline $Deadline -TransportOverride { param($Uri,$Json,$Token,$Expires) [ordered]@{status_code=200;content_type='application/json';body='{}'} }
  if ([int]$Transport.status_code-ne200) { throw 'positive: injected unit transport was not returned' }

  $Response = [pscustomobject][ordered]@{schema_version='1.0';protocol=$Protocol;operation='allocation_zero_baseline';status='passed';action_id=$Action;candidate_head_oid=$Candidate;build_digest_sha256=$Build;behavior_digest_sha256=$Behavior;expected_generation=0;observed_generation=0;executed_at=[DateTimeOffset]::Now.ToString('o');cost_usd=0;redline_failure_count=0;allocation_percent_after=0;allocation_scope='not_applicable';non_owner_allocation_count=0;non_owner_request_count=0;kill_switch_seconds=-1;old_path_available=$true;production=$true;database_kind='postgresql'}
  Assert-OwnerCanaryNoSensitiveResponseFields -Value $Response
  Assert-OwnerCanaryActionResponse -Response $Response -Request $RequestObject
  $Response.production=$false
  $Rejected=$false;try{Assert-OwnerCanaryActionResponse -Response $Response -Request $RequestObject}catch{$Rejected=$true}
  if (-not$Rejected) { throw 'negative: non-production action response was accepted' }

  $ReceiptRequest = [ordered]@{};foreach($Property in $BaseRequest.GetEnumerator()){$ReceiptRequest[$Property.Key]=$Property.Value}
  $ReceiptRequest.operation='get_journey_trace';$ReceiptRequest.build_digest_sha256=$Build;$ReceiptRequest.behavior_digest_sha256=$Behavior;$ReceiptRequest.journey_id_sha256=$Journey;$ReceiptRequest.run_id_sha256=$Run
  $ReceiptRequestObject=$ReceiptRequest|ConvertTo-Json -Depth 10 -Compress|ConvertFrom-Json
  Assert-OwnerCanaryRequest -Request $ReceiptRequestObject|Out-Null
  $AdapterDigest=(Get-FileHash -Algorithm SHA256 -LiteralPath $AdapterPath).Hash.ToLowerInvariant()
  $Trace=[pscustomobject][ordered]@{schema_version='1.0';receipt_kind='journey_trace';subject_id_sha256=$Journey;candidate_head_oid=$Candidate;build_digest_sha256=$Build;behavior_digest_sha256=$Behavior;owner_identity_ref_sha256=$OwnerHash;adapter_digest_sha256=$Coordinator;status='passed';redline_failure_count=0;executed_at=[DateTimeOffset]::Now.ToString('o');run_id_sha256=$Run;source_adapter_environment_name='GONOW_RELEASE_B_TRACE_ADAPTER';source_adapter_digest_sha256=$AdapterDigest;journey_class='success';outcome='succeeded';started_at=[DateTimeOffset]::Now.AddSeconds(-1).ToString('o');ended_at=[DateTimeOffset]::Now.ToString('o');traceability_failure_count=0;alert_wiring_verified=$true}
  Assert-OwnerCanaryReceiptResponse -Response $Trace -Request $ReceiptRequestObject -EnvironmentName 'GONOW_RELEASE_B_TRACE_ADAPTER' -AdapterDigest $AdapterDigest -OwnerIdentityHash $OwnerHash
  $Trace|Add-Member -NotePropertyName prompt -NotePropertyValue 'forbidden'
  $Rejected=$false;try{Assert-OwnerCanaryNoSensitiveResponseFields -Value $Trace}catch{$Rejected=$true}
  if (-not$Rejected) { throw 'negative: sensitive response field was accepted' }

  foreach($BadEndpoint in @('http://agent.example.net','https://localhost','https://127.0.0.1','https://agent.example.net/path','https://user@agent.example.net')){
    $Rejected=$false;try{Resolve-OwnerCanaryEndpoint -Value $BadEndpoint|Out-Null}catch{$Rejected=$true}
    if(-not$Rejected){throw "negative: unsafe endpoint was accepted: $BadEndpoint"}
  }
  $BadRequest=$RequestObject.PSObject.Copy();$BadRequest|Add-Member -NotePropertyName unexpected -NotePropertyValue 1
  $Rejected=$false;try{Assert-OwnerCanaryRequest -Request $BadRequest|Out-Null}catch{$Rejected=$true}
  if(-not$Rejected){throw 'negative: request with unknown field was accepted'}

  $MissingVaultRequest=[ordered]@{schema_version='1.0';protocol='owner-canary-credential-provider/v1';operation='resolve_bearer';vault='MissingVault';secret_name='missing-secret';owner_identity_ref_sha256=$OwnerHash;deadline=[DateTimeOffset]::Now.AddMinutes(1).ToString('o')}|ConvertTo-Json -Compress
  $Output=@($MissingVaultRequest|& pwsh -NoLogo -NoProfile -NonInteractive -File $ProviderPath 2>&1)
  if($LASTEXITCODE-eq0-or-not[string]::IsNullOrWhiteSpace(($Output-join''))){throw 'negative: SecretManagement provider did not fail closed and silent for a missing vault'}
} finally {
  if(Test-Path -LiteralPath $TemporaryRoot -PathType Container){Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force}
}

Write-Output 'Owner canary HTTPS adapter contracts passed'
exit 0

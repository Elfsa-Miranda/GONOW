[CmdletBinding()]
param(
  [ValidateSet('Verify','Plan','Apply','RollbackPlan','Rollback')][string]$Mode = 'Verify',
  [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedCurrentStateSha256,
  [string]$AuthorizationReference,
  [string]$ActorReference,
  [string]$ReceiptPath,
  [string]$ApplyReceiptPath
)

$ErrorActionPreference = 'Stop'
$CredentialProviderPath = Join-Path $PSScriptRoot 'GitHubCredentialProvider.psm1'
Import-Module -Name $CredentialProviderPath -Force -ErrorAction Stop
$Owner = 'Elfsa-Miranda'
$Repository = 'GO_NOW'
$Branch = 'main'
$ApiVersion = '2026-03-10'
$RequiredChecks = @('agent-required','baseline-and-candidate','tracked-and-history')

function Get-Utf8Sha256 {
  param([Parameter(Mandatory = $true)][string]$Value)
  $Algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  } finally { $Algorithm.Dispose() }
}

function Get-PropertyValue {
  param([object]$Object,[Parameter(Mandatory = $true)][string]$Name,[object]$Default = $null)
  if ($null -eq $Object) { return $Default }
  if ($Object -is [Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $Default
  }
  $Property = $Object.PSObject.Properties[$Name]
  if ($null -eq $Property) { return $Default }
  return $Property.Value
}

function Get-EnabledValue {
  param([object]$Object,[bool]$Default = $false)
  if ($null -eq $Object) { return $Default }
  if ($Object -is [bool]) { return [bool]$Object }
  return [bool](Get-PropertyValue -Object $Object -Name 'enabled' -Default $Default)
}

function ConvertTo-CanonicalJson {
  param([Parameter(Mandatory = $true)][object]$Value)
  return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Get-ObjectSha256 {
  param([Parameter(Mandatory = $true)][object]$Value)
  return Get-Utf8Sha256 -Value (ConvertTo-CanonicalJson -Value $Value)
}

function Get-ActorCount {
  param([object]$Object)
  if ($null -eq $Object) { return 0 }
  $Count = 0
  foreach ($Name in @('users','teams','apps')) {
    $Values = Get-PropertyValue -Object $Object -Name $Name -Default @()
    if ($null -ne $Values) { $Count += @($Values).Count }
  }
  return $Count
}

function New-AbsentProtectionState {
  return [ordered]@{ schema_version='1.0'; state='absent' }
}

function New-DesiredProtectionState {
  param([Parameter(Mandatory = $true)][string[]]$Checks)
  return [ordered]@{
    schema_version = '1.0'
    state = 'present'
    required_checks = @($Checks | Sort-Object)
    strict = $true
    enforce_admins = $true
    pull_request_required = $true
    dismiss_stale_reviews = $true
    require_code_owner_reviews = $false
    required_approving_review_count = 0
    require_last_push_approval = $false
    bypass_actor_count = 0
    restriction_actor_count = 0
    required_linear_history = $false
    allow_force_pushes = $false
    allow_deletions = $false
    block_creations = $false
    required_conversation_resolution = $false
    lock_branch = $false
    allow_fork_syncing = $false
  }
}

function ConvertTo-ProtectionState {
  param([Parameter(Mandatory = $true)][object]$Protection)
  $StatusChecks = Get-PropertyValue -Object $Protection -Name 'required_status_checks'
  $Names = @()
  if ($null -ne $StatusChecks) {
    $Checks = Get-PropertyValue -Object $StatusChecks -Name 'checks'
    if ($null -ne $Checks -and @($Checks).Count -gt 0) {
      $Names = @($Checks | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name 'context') } | Sort-Object)
    } else {
      $Contexts = Get-PropertyValue -Object $StatusChecks -Name 'contexts' -Default @()
      $Names = @($Contexts | ForEach-Object { [string]$_ } | Sort-Object)
    }
  }
  $Reviews = Get-PropertyValue -Object $Protection -Name 'required_pull_request_reviews'
  return [ordered]@{
    schema_version = '1.0'
    state = 'present'
    required_checks = $Names
    strict = [bool](Get-PropertyValue -Object $StatusChecks -Name 'strict' -Default $false)
    enforce_admins = Get-EnabledValue -Object (Get-PropertyValue -Object $Protection -Name 'enforce_admins')
    pull_request_required = ($null -ne $Reviews)
    dismiss_stale_reviews = [bool](Get-PropertyValue -Object $Reviews -Name 'dismiss_stale_reviews' -Default $false)
    require_code_owner_reviews = [bool](Get-PropertyValue -Object $Reviews -Name 'require_code_owner_reviews' -Default $false)
    required_approving_review_count = [int](Get-PropertyValue -Object $Reviews -Name 'required_approving_review_count' -Default 0)
    require_last_push_approval = [bool](Get-PropertyValue -Object $Reviews -Name 'require_last_push_approval' -Default $false)
    bypass_actor_count = Get-ActorCount -Object (Get-PropertyValue -Object $Reviews -Name 'bypass_pull_request_allowances')
    restriction_actor_count = Get-ActorCount -Object (Get-PropertyValue -Object $Protection -Name 'restrictions')
    required_linear_history = Get-EnabledValue -Object (Get-PropertyValue -Object $Protection -Name 'required_linear_history')
    allow_force_pushes = Get-EnabledValue -Object (Get-PropertyValue -Object $Protection -Name 'allow_force_pushes')
    allow_deletions = Get-EnabledValue -Object (Get-PropertyValue -Object $Protection -Name 'allow_deletions')
    block_creations = Get-EnabledValue -Object (Get-PropertyValue -Object $Protection -Name 'block_creations')
    required_conversation_resolution = Get-EnabledValue -Object (Get-PropertyValue -Object $Protection -Name 'required_conversation_resolution')
    lock_branch = Get-EnabledValue -Object (Get-PropertyValue -Object $Protection -Name 'lock_branch')
    allow_fork_syncing = Get-EnabledValue -Object (Get-PropertyValue -Object $Protection -Name 'allow_fork_syncing')
  }
}

function New-DesiredProtectionRequest {
  param([Parameter(Mandatory = $true)][string[]]$Checks)
  $CheckObjects = @($Checks | Sort-Object | ForEach-Object { [ordered]@{ context=[string]$_ } })
  return [ordered]@{
    required_status_checks = [ordered]@{ strict=$true; checks=$CheckObjects }
    enforce_admins = $true
    required_pull_request_reviews = [ordered]@{
      dismiss_stale_reviews = $true
      require_code_owner_reviews = $false
      required_approving_review_count = 0
      require_last_push_approval = $false
    }
    restrictions = $null
    required_linear_history = $false
    allow_force_pushes = $false
    allow_deletions = $false
    block_creations = $false
    required_conversation_resolution = $false
    lock_branch = $false
    allow_fork_syncing = $false
  }
}

function Get-GitHubToken {
  return Get-GitHubApiToken -Required -MissingErrorCode 'github_main_protection_token_missing'
}

function Invoke-GitHubHttp {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('GET','PUT','DELETE')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
    [string]$BodyJson
  )
  try {
    $Parameters = @{ Method=$Method; Uri=$Uri; Headers=$Headers; ErrorAction='Stop'; UseBasicParsing=$true }
    if ($Method -ceq 'PUT') { $Parameters.ContentType='application/json';$Parameters.Body=$BodyJson }
    $Body = Invoke-RestMethod @Parameters
    $Status = if ($Method -ceq 'DELETE') { 204 } else { 200 }
    return [pscustomobject][ordered]@{ status_code=$Status; body=$Body }
  } catch {
    $Status = 0
    if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
      $Status = [int]$_.Exception.Response.StatusCode
    }
    return [pscustomobject][ordered]@{ status_code=$Status; body=$null }
  }
}

function Get-ProtectionObservation {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
    [Parameter(Mandatory = $true)][scriptblock]$RequestInvoker
  )
  $Response = & $RequestInvoker 'GET' $Uri $Headers $null
  if ([int]$Response.status_code -eq 404) {
    $State = New-AbsentProtectionState
  } elseif ([int]$Response.status_code -eq 200 -and $null -ne $Response.body) {
    $State = ConvertTo-ProtectionState -Protection $Response.body
  } else {
    throw "github_main_protection_query_failed:$([int]$Response.status_code)"
  }
  return [pscustomobject][ordered]@{
    http_status = [int]$Response.status_code
    state = $State
    state_sha256 = Get-ObjectSha256 -Value $State
  }
}

function Resolve-ReceiptPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'github_main_protection_receipt_path_missing' }
  $Resolved = [IO.Path]::GetFullPath($Path)
  $Parent = Split-Path -Parent $Resolved
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw 'github_main_protection_receipt_parent_missing' }
  $ParentItem = Get-Item -LiteralPath $Parent -Force
  if ([bool]($ParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'github_main_protection_receipt_parent_reparse_point' }
  return $Resolved
}

function Write-AtomicReceipt {
  param(
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][object]$Value,
    [switch]$AllowSameActionUpdate
  )
  if (Test-Path -LiteralPath $LiteralPath) {
    if (-not $AllowSameActionUpdate) { throw 'github_main_protection_receipt_exists' }
    $Existing = Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ([string]$Existing.action_id -cne [string]$Value.action_id) { throw 'github_main_protection_receipt_action_mismatch' }
  }
  $Parent = Split-Path -Parent $LiteralPath
  $Temporary = Join-Path $Parent ('.' + [IO.Path]::GetFileName($LiteralPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($Temporary, (($Value | ConvertTo-Json -Depth 30) + "`n"), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $Temporary -Destination $LiteralPath -Force
  } finally {
    if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
  }
}

function Assert-AuthorizationInputs {
  param([string]$Authorization,[string]$Actor)
  foreach ($Pair in @(@('authorization',$Authorization),@('actor',$Actor))) {
    if ([string]::IsNullOrWhiteSpace([string]$Pair[1]) -or ([string]$Pair[1]).Length -gt 512) {
      throw "github_main_protection_$([string]$Pair[0])_reference_invalid"
    }
  }
}

function Get-ReceiptReferenceHash {
  param([Parameter(Mandatory = $true)][string]$Value)
  return Get-Utf8Sha256 -Value $Value
}

function Read-ApplyReceipt {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { throw 'github_main_protection_apply_receipt_missing' }
  $Receipt = Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  if (
    [string]$Receipt.schema_version -cne '1.0' -or
    [string]$Receipt.receipt_kind -cne 'github_main_protection_change' -or
    [string]$Receipt.operation -cne 'apply' -or
    [string]$Receipt.status -cne 'completed' -or
    [string]$Receipt.target -cne 'Elfsa-Miranda/GO_NOW:main' -or
    [string]$Receipt.before_state -cne 'absent' -or
    [string]$Receipt.after_state_sha256 -notmatch '^[0-9a-f]{64}$'
  ) { throw 'github_main_protection_apply_receipt_invalid' }
  return $Receipt
}

function Invoke-MainProtectionOperation {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('Verify','Plan','Apply','RollbackPlan','Rollback')][string]$Operation,
    [string]$ExpectedStateSha256,
    [string]$Authorization,
    [string]$Actor,
    [string]$OutputReceiptPath,
    [string]$InputApplyReceiptPath,
    [Parameter(Mandatory = $true)][string[]]$Checks,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][scriptblock]$RequestInvoker
  )
  $Token = Get-GitHubToken
  $Headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $Token"
    'User-Agent' = 'GoNow-main-protection-adapter'
    'X-GitHub-Api-Version' = $Version
  }
  $Uri = 'https://api.github.com/repos/Elfsa-Miranda/GO_NOW/branches/main/protection'
  $DesiredState = New-DesiredProtectionState -Checks $Checks
  $DesiredStateHash = Get-ObjectSha256 -Value $DesiredState
  $DesiredRequest = New-DesiredProtectionRequest -Checks $Checks
  $DesiredRequestJson = ConvertTo-CanonicalJson -Value $DesiredRequest
  $DesiredRequestHash = Get-Utf8Sha256 -Value $DesiredRequestJson
  $Before = Get-ProtectionObservation -Uri $Uri -Headers $Headers -RequestInvoker $RequestInvoker
  $Compliant = [string]$Before.state_sha256 -ceq $DesiredStateHash

  if ($Operation -ceq 'Verify' -or $Operation -ceq 'Plan') {
    return [pscustomobject][ordered]@{
      schema_version='1.0';mode=$Operation.ToLowerInvariant();target='Elfsa-Miranda/GO_NOW:main'
      api_version=$Version;current_state=[string]$Before.state.state;current_state_sha256=[string]$Before.state_sha256
      desired_state_sha256=$DesiredStateHash;desired_request_sha256=$DesiredRequestHash;compliant=$Compliant
      mutation_performed=$false
      next_action=$(if($Compliant){'none'}elseif([string]$Before.state.state -ceq'absent'){'authorized_apply_with_expected_current_state_sha256'}else{'manual_review_existing_protection_no_overwrite'})
    }
  }

  if ($Operation -ceq 'RollbackPlan') {
    if ([string]::IsNullOrWhiteSpace($InputApplyReceiptPath)) { throw 'github_main_protection_apply_receipt_path_missing' }
    $PlanApplyReceipt = Read-ApplyReceipt -LiteralPath ([IO.Path]::GetFullPath($InputApplyReceiptPath))
    if ([string]$PlanApplyReceipt.after_state_sha256 -cne $DesiredStateHash) { throw 'github_main_protection_apply_receipt_state_mismatch' }
    return [pscustomobject][ordered]@{
      schema_version='1.0';mode='rollback_plan';target='Elfsa-Miranda/GO_NOW:main';current_state_sha256=[string]$Before.state_sha256
      managed_state_sha256=[string]$PlanApplyReceipt.after_state_sha256;cas_matches=([string]$Before.state_sha256 -ceq [string]$PlanApplyReceipt.after_state_sha256)
      mutation_performed=$false;next_action='authorized_delete_with_apply_receipt_and_expected_current_state_sha256'
    }
  }

  Assert-AuthorizationInputs -Authorization $Authorization -Actor $Actor
  if ([string]::IsNullOrWhiteSpace($ExpectedStateSha256)) { throw 'github_main_protection_expected_state_sha256_missing' }
  if ([string]$Before.state_sha256 -cne $ExpectedStateSha256) { throw 'github_main_protection_cas_mismatch' }
  $ResolvedReceipt = Resolve-ReceiptPath -Path $OutputReceiptPath
  $AuthorizationHash = Get-ReceiptReferenceHash -Value $Authorization
  $ActorHash = Get-ReceiptReferenceHash -Value $Actor

  if ($Operation -ceq 'Apply') {
    if (-not $Compliant -and [string]$Before.state.state -cne 'absent') { throw 'github_main_protection_existing_rule_refused' }
    $ActionId = Get-Utf8Sha256 -Value ("apply|Elfsa-Miranda/GO_NOW:main|$ExpectedStateSha256|$DesiredStateHash|$AuthorizationHash|$ActorHash")
    $Receipt = [ordered]@{
      schema_version='1.0';receipt_kind='github_main_protection_change';operation='apply';status='prepared'
      action_id=$ActionId;target='Elfsa-Miranda/GO_NOW:main';api_version=$Version
      authorization_reference_sha256=$AuthorizationHash;actor_reference_sha256=$ActorHash
      before_state=[string]$Before.state.state;before_state_sha256=[string]$Before.state_sha256
      desired_state_sha256=$DesiredStateHash;request_sha256=$DesiredRequestHash
      mutation_performed=$false;http_status=0;after_state_sha256=$null
      rollback_contract='delete_only_if_before_absent_and_current_state_sha256_equals_after_state_sha256'
      secret_value_recorded=$false;prepared_at=[DateTimeOffset]::Now.ToString('o');completed_at=$null
    }
    Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
    try {
      $HttpStatus = 200
      if (-not $Compliant) {
        $Response = & $RequestInvoker 'PUT' $Uri $Headers $DesiredRequestJson
        $HttpStatus = [int]$Response.status_code
        if ($HttpStatus -ne 200) { throw "github_main_protection_apply_failed:$HttpStatus" }
      }
      $After = Get-ProtectionObservation -Uri $Uri -Headers $Headers -RequestInvoker $RequestInvoker
      if ([string]$After.state_sha256 -cne $DesiredStateHash) { throw 'github_main_protection_postcondition_failed' }
      $Receipt.status='completed';$Receipt.mutation_performed=(-not $Compliant);$Receipt.http_status=$HttpStatus
      $Receipt.after_state_sha256=[string]$After.state_sha256;$Receipt.completed_at=[DateTimeOffset]::Now.ToString('o')
      Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
      return [pscustomobject]$Receipt
    } catch {
      $Receipt.status='failed';$Receipt.failure_code=[string]$_.Exception.Message;$Receipt.completed_at=[DateTimeOffset]::Now.ToString('o')
      Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
      throw
    }
  }

  if ([string]::IsNullOrWhiteSpace($InputApplyReceiptPath)) { throw 'github_main_protection_apply_receipt_path_missing' }
  $ApplyReceipt = Read-ApplyReceipt -LiteralPath ([IO.Path]::GetFullPath($InputApplyReceiptPath))
  if ([string]$ApplyReceipt.after_state_sha256 -cne $DesiredStateHash) { throw 'github_main_protection_apply_receipt_state_mismatch' }
  if ([string]$Before.state_sha256 -cne [string]$ApplyReceipt.after_state_sha256) { throw 'github_main_protection_rollback_cas_mismatch' }
  $ActionId = Get-Utf8Sha256 -Value ("rollback|Elfsa-Miranda/GO_NOW:main|$ExpectedStateSha256|$AuthorizationHash|$ActorHash|$([string]$ApplyReceipt.action_id)")
  $Receipt = [ordered]@{
    schema_version='1.0';receipt_kind='github_main_protection_change';operation='rollback';status='prepared'
    action_id=$ActionId;target='Elfsa-Miranda/GO_NOW:main';api_version=$Version
    authorization_reference_sha256=$AuthorizationHash;actor_reference_sha256=$ActorHash
    apply_action_id=[string]$ApplyReceipt.action_id;before_state='present';before_state_sha256=[string]$Before.state_sha256
    expected_after_state='absent';mutation_performed=$false;http_status=0;after_state_sha256=$null
    secret_value_recorded=$false;prepared_at=[DateTimeOffset]::Now.ToString('o');completed_at=$null
  }
  Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
  try {
    $Response = & $RequestInvoker 'DELETE' $Uri $Headers $null
    if ([int]$Response.status_code -ne 204) { throw "github_main_protection_rollback_failed:$([int]$Response.status_code)" }
    $After = Get-ProtectionObservation -Uri $Uri -Headers $Headers -RequestInvoker $RequestInvoker
    $AbsentHash = Get-ObjectSha256 -Value (New-AbsentProtectionState)
    if ([string]$After.state_sha256 -cne $AbsentHash) { throw 'github_main_protection_rollback_postcondition_failed' }
    $Receipt.status='completed';$Receipt.mutation_performed=$true;$Receipt.http_status=204
    $Receipt.after_state_sha256=[string]$After.state_sha256;$Receipt.completed_at=[DateTimeOffset]::Now.ToString('o')
    Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
    return [pscustomobject]$Receipt
  } catch {
    $Receipt.status='failed';$Receipt.failure_code=[string]$_.Exception.Message;$Receipt.completed_at=[DateTimeOffset]::Now.ToString('o')
    Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
    throw
  }
}

if ($MyInvocation.InvocationName -ne '.') {
  $Result = Invoke-MainProtectionOperation -Operation $Mode -ExpectedStateSha256 $ExpectedCurrentStateSha256 `
    -Authorization $AuthorizationReference -Actor $ActorReference -OutputReceiptPath $ReceiptPath `
    -InputApplyReceiptPath $ApplyReceiptPath -Checks $RequiredChecks -Version $ApiVersion `
    -RequestInvoker ${function:Invoke-GitHubHttp}
  $Result | ConvertTo-Json -Depth 30
  if ($Mode -ceq 'Verify' -and -not [bool]$Result.compliant) { exit 3 }
}

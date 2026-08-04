[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$CommandRoot = Split-Path -Parent $PSScriptRoot
$ScriptPath = Join-Path $CommandRoot 'Invoke-GitHubMainProtection.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$Tokens,[ref]$ParseErrors)
if (@($ParseErrors).Count -ne 0) { throw 'positive: main protection adapter PowerShell parse failed' }

$RequiredFunctions = @(
  'Get-Utf8Sha256','Get-PropertyValue','Get-EnabledValue','ConvertTo-CanonicalJson','Get-ObjectSha256',
  'Get-ActorCount','New-AbsentProtectionState','New-DesiredProtectionState','ConvertTo-ProtectionState',
  'New-DesiredProtectionRequest','Get-GitHubToken','Get-ProtectionObservation','Resolve-ReceiptPath',
  'Write-AtomicReceipt','Assert-AuthorizationInputs','Get-ReceiptReferenceHash','Read-ApplyReceipt',
  'Invoke-MainProtectionOperation'
)
foreach ($Name in $RequiredFunctions) {
  $Definition = $Ast.Find(
    { param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $Name },
    $true
  )
  if ($null -eq $Definition) { throw "negative: main protection adapter function missing: $Name" }
  Invoke-Expression $Definition.Extent.Text
}

$Source = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
foreach ($RequiredToken in @(
  "'X-GitHub-Api-Version' = `$Version",'2026-03-10','required_approving_review_count = 0',
  "required_linear_history = `$false","allow_force_pushes = `$false","allow_deletions = `$false",
  'github_main_protection_cas_mismatch','github_main_protection_existing_rule_refused',
  'delete_only_if_before_absent_and_current_state_sha256_equals_after_state_sha256','secret_value_recorded=$false'
)) {
  if (-not $Source.Contains($RequiredToken)) { throw "negative: main protection safety token missing: $RequiredToken" }
}
if ($Source -match 'Invoke-Expression\s+\$' -or $Source -match 'Write-(?:Host|Output).*Token') {
  throw 'negative: main protection adapter exposes shell evaluation or token output'
}

function New-FakeDesiredResponse {
  param([switch]$AllowForce,[switch]$ExtraCheck)
  $Names = @('agent-required','baseline-and-candidate','tracked-and-history')
  if ($ExtraCheck) { $Names += 'unexpected-check' }
  return [pscustomobject][ordered]@{
    required_status_checks=[pscustomobject][ordered]@{strict=$true;checks=@($Names|ForEach-Object{[pscustomobject]@{context=$_;app_id=$null}})}
    enforce_admins=[pscustomobject]@{enabled=$true}
    required_pull_request_reviews=[pscustomobject][ordered]@{
      dismiss_stale_reviews=$true;require_code_owner_reviews=$false;required_approving_review_count=0;require_last_push_approval=$false
      bypass_pull_request_allowances=[pscustomobject]@{users=@();teams=@();apps=@()}
    }
    restrictions=$null
    required_linear_history=[pscustomobject]@{enabled=$false}
    allow_force_pushes=[pscustomobject]@{enabled=[bool]$AllowForce}
    allow_deletions=[pscustomobject]@{enabled=$false}
    block_creations=[pscustomobject]@{enabled=$false}
    required_conversation_resolution=[pscustomobject]@{enabled=$false}
    lock_branch=[pscustomobject]@{enabled=$false}
    allow_fork_syncing=[pscustomobject]@{enabled=$false}
  }
}

$Checks = @('agent-required','baseline-and-candidate','tracked-and-history')
$Version = '2026-03-10'
$SavedToken = [Environment]::GetEnvironmentVariable('GH_TOKEN','Process')
$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("gonow-main-protection-$([Guid]::NewGuid().ToString('N'))")
try {
  New-Item -ItemType Directory -Path $TemporaryRoot | Out-Null
  [Environment]::SetEnvironmentVariable('GH_TOKEN','secret-sentinel-must-not-appear','Process')
  $Absent = New-AbsentProtectionState
  $AbsentHash = Get-ObjectSha256 -Value $Absent
  $DesiredHash = Get-ObjectSha256 -Value (New-DesiredProtectionState -Checks $Checks)

  $PlanCalls = [Collections.Generic.List[string]]::new()
  $AbsentInvoker = {
    param($Method,$Uri,$Headers,$BodyJson)
    $PlanCalls.Add($Method) | Out-Null
    return [pscustomobject]@{status_code=404;body=$null}
  }
  $Plan = Invoke-MainProtectionOperation -Operation Plan -Checks $Checks -Version $Version -RequestInvoker $AbsentInvoker
  if ([string]$Plan.current_state -cne 'absent' -or [string]$Plan.current_state_sha256 -cne $AbsentHash -or [bool]$Plan.compliant -or [bool]$Plan.mutation_performed -or ($PlanCalls -join ',') -cne 'GET') {
    throw 'positive: absent protection plan is invalid'
  }

  $MismatchRejected = $false
  try {
    Invoke-MainProtectionOperation -Operation Apply -ExpectedStateSha256 ('f'*64) -Authorization 'authz:test' -Actor 'actor:test' `
      -OutputReceiptPath (Join-Path $TemporaryRoot 'mismatch.json') -Checks $Checks -Version $Version -RequestInvoker $AbsentInvoker | Out-Null
  } catch { $MismatchRejected = $_.Exception.Message -ceq 'github_main_protection_cas_mismatch' }
  if (-not $MismatchRejected -or (Test-Path -LiteralPath (Join-Path $TemporaryRoot 'mismatch.json'))) {
    throw 'negative: state CAS mismatch was accepted or wrote a receipt'
  }

  $ApplyCalls = [Collections.Generic.List[string]]::new()
  $ApplyRequestBodies = [Collections.Generic.List[string]]::new()
  $ApplyStep = [pscustomobject]@{value=0}
  $DesiredResponse = New-FakeDesiredResponse
  $FixtureState = ConvertTo-ProtectionState -Protection $DesiredResponse
  $FixtureHash = Get-ObjectSha256 -Value $FixtureState
  if ($FixtureHash -cne $DesiredHash) {
    throw "positive: desired fixture normalization mismatch: expected=$DesiredHash actual=$FixtureHash desired=$(ConvertTo-CanonicalJson -Value (New-DesiredProtectionState -Checks $Checks)) actual=$(ConvertTo-CanonicalJson -Value $FixtureState)"
  }
  $ApplyInvoker = {
    param($Method,$Uri,$Headers,$BodyJson)
    $ApplyCalls.Add($Method) | Out-Null
    if ($Method -ceq 'PUT') { $ApplyRequestBodies.Add($BodyJson) | Out-Null; return [pscustomobject]@{status_code=200;body=$DesiredResponse} }
    $ApplyStep.value++
    if ($ApplyStep.value -eq 1) { return [pscustomobject]@{status_code=404;body=$null} }
    return [pscustomobject]@{status_code=200;body=$DesiredResponse}
  }
  $ApplyPath = Join-Path $TemporaryRoot 'apply.json'
  $Applied = Invoke-MainProtectionOperation -Operation Apply -ExpectedStateSha256 $AbsentHash -Authorization 'authz:test' -Actor 'actor:test' `
    -OutputReceiptPath $ApplyPath -Checks $Checks -Version $Version -RequestInvoker $ApplyInvoker
  if ([string]$Applied.status -cne 'completed' -or -not [bool]$Applied.mutation_performed -or [string]$Applied.after_state_sha256 -cne $DesiredHash -or ($ApplyCalls -join ',') -cne 'GET,PUT,GET') {
    throw 'positive: absent-to-managed apply did not close the postcondition'
  }
  $RequestObject = $ApplyRequestBodies[0] | ConvertFrom-Json -ErrorAction Stop
  if (-not [bool]$RequestObject.required_status_checks.strict -or @($RequestObject.required_status_checks.checks).Count -ne 3 -or
      [int]$RequestObject.required_pull_request_reviews.required_approving_review_count -ne 0 -or
      [bool]$RequestObject.required_linear_history -or [bool]$RequestObject.allow_force_pushes -or [bool]$RequestObject.allow_deletions) {
    throw 'positive: apply request does not match the release merge contract'
  }
  $ApplyRaw = Get-Content -LiteralPath $ApplyPath -Raw -Encoding UTF8
  if ($ApplyRaw -match 'secret-sentinel-must-not-appear|authz:test|actor:test') { throw 'negative: apply receipt leaked a token or raw reference' }
  $RollbackPlanCalls = [Collections.Generic.List[string]]::new()
  $RollbackPlanInvoker = {
    param($Method,$Uri,$Headers,$BodyJson)
    $RollbackPlanCalls.Add($Method) | Out-Null
    return [pscustomobject]@{status_code=200;body=$DesiredResponse}
  }
  $RollbackPlan = Invoke-MainProtectionOperation -Operation RollbackPlan -InputApplyReceiptPath $ApplyPath -Checks $Checks -Version $Version -RequestInvoker $RollbackPlanInvoker
  if (-not [bool]$RollbackPlan.cas_matches -or [bool]$RollbackPlan.mutation_performed -or ($RollbackPlanCalls -join ',') -cne 'GET') {
    throw 'positive: read-only rollback plan is invalid'
  }

  $ExistingDifferentCalls = [Collections.Generic.List[string]]::new()
  $DifferentResponse = New-FakeDesiredResponse -ExtraCheck
  $DifferentInvoker = {
    param($Method,$Uri,$Headers,$BodyJson)
    $ExistingDifferentCalls.Add($Method) | Out-Null
    return [pscustomobject]@{status_code=200;body=$DifferentResponse}
  }
  $DifferentState = ConvertTo-ProtectionState -Protection $DifferentResponse
  $DifferentHash = Get-ObjectSha256 -Value $DifferentState
  $ExistingRejected = $false
  try {
    Invoke-MainProtectionOperation -Operation Apply -ExpectedStateSha256 $DifferentHash -Authorization 'authz:test' -Actor 'actor:test' `
      -OutputReceiptPath (Join-Path $TemporaryRoot 'existing.json') -Checks $Checks -Version $Version -RequestInvoker $DifferentInvoker | Out-Null
  } catch { $ExistingRejected = $_.Exception.Message -ceq 'github_main_protection_existing_rule_refused' }
  if (-not $ExistingRejected -or ($ExistingDifferentCalls -join ',') -cne 'GET') { throw 'negative: existing protection was overwritten' }

  $FailedPath = Join-Path $TemporaryRoot 'postcondition-failed.json'
  $FailedStep = [pscustomobject]@{value=0}
  $WrongResponse = New-FakeDesiredResponse -AllowForce
  $FailedInvoker = {
    param($Method,$Uri,$Headers,$BodyJson)
    if ($Method -ceq 'PUT') { return [pscustomobject]@{status_code=200;body=$DesiredResponse} }
    $FailedStep.value++
    if ($FailedStep.value -eq 1) { return [pscustomobject]@{status_code=404;body=$null} }
    return [pscustomobject]@{status_code=200;body=$WrongResponse}
  }
  $PostconditionRejected = $false
  try {
    Invoke-MainProtectionOperation -Operation Apply -ExpectedStateSha256 $AbsentHash -Authorization 'authz:test' -Actor 'actor:test' `
      -OutputReceiptPath $FailedPath -Checks $Checks -Version $Version -RequestInvoker $FailedInvoker | Out-Null
  } catch { $PostconditionRejected = $_.Exception.Message -ceq 'github_main_protection_postcondition_failed' }
  $FailedReceipt = Get-Content -LiteralPath $FailedPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $PostconditionRejected -or [string]$FailedReceipt.status -cne 'failed') { throw 'negative: postcondition mismatch was accepted' }

  $RollbackCalls = [Collections.Generic.List[string]]::new()
  $RollbackStep = [pscustomobject]@{value=0}
  $RollbackInvoker = {
    param($Method,$Uri,$Headers,$BodyJson)
    $RollbackCalls.Add($Method) | Out-Null
    if ($Method -ceq 'DELETE') { return [pscustomobject]@{status_code=204;body=$null} }
    $RollbackStep.value++
    if ($RollbackStep.value -eq 1) { return [pscustomobject]@{status_code=200;body=$DesiredResponse} }
    return [pscustomobject]@{status_code=404;body=$null}
  }
  $RollbackPath = Join-Path $TemporaryRoot 'rollback.json'
  $RolledBack = Invoke-MainProtectionOperation -Operation Rollback -ExpectedStateSha256 $DesiredHash -Authorization 'authz:rollback' -Actor 'actor:test' `
    -OutputReceiptPath $RollbackPath -InputApplyReceiptPath $ApplyPath -Checks $Checks -Version $Version -RequestInvoker $RollbackInvoker
  if ([string]$RolledBack.status -cne 'completed' -or -not [bool]$RolledBack.mutation_performed -or ($RollbackCalls -join ',') -cne 'GET,DELETE,GET' -or
      [string]$RolledBack.after_state_sha256 -cne $AbsentHash) {
    throw 'positive: exact managed-state rollback failed'
  }
  $RollbackRaw = Get-Content -LiteralPath $RollbackPath -Raw -Encoding UTF8
  if ($RollbackRaw -match 'secret-sentinel-must-not-appear|authz:rollback|actor:test') { throw 'negative: rollback receipt leaked a token or raw reference' }
} finally {
  [Environment]::SetEnvironmentVariable('GH_TOKEN',$SavedToken,'Process')
  if (Test-Path -LiteralPath $TemporaryRoot -PathType Container) { Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force }
}

Write-Output 'Invoke-GitHubMainProtection contracts passed'
exit 0

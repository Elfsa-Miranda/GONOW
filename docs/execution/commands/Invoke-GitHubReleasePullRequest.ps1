[CmdletBinding()]
param(
  [ValidateSet('Plan','Apply','RollbackPlan')][string]$Mode = 'Plan',
  [Parameter(Mandatory = $true)][string]$RequestPath,
  [ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedRequestSha256,
  [string]$AuthorizationReference,
  [string]$ActorId,
  [ValidateRange(30,3600)][int]$WaitTimeoutSeconds = 1800,
  [ValidateRange(5,120)][int]$PollSeconds = 20
)

$ErrorActionPreference = 'Stop'
$CredentialProviderPath = Join-Path $PSScriptRoot 'GitHubCredentialProvider.psm1'
Import-Module -Name $CredentialProviderPath -Force -ErrorAction Stop
$ApiVersion = '2026-03-10'
$RequiredCheckNames = @('agent-required','baseline-and-candidate','tracked-and-history')

function Get-Utf8Sha256 {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  $Hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  } finally { $Hasher.Dispose() }
}

function Get-FileSha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
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

function Test-ExactStringSet {
  param([object[]]$Actual,[string[]]$Expected)
  $ActualValues = @($Actual | ForEach-Object { [string]$_ } | Sort-Object)
  $ExpectedValues = @($Expected | Sort-Object)
  return ($ActualValues -join "`n") -ceq ($ExpectedValues -join "`n")
}

function Get-GitHubToken {
  param([switch]$Required)
  return Get-GitHubApiToken -Required:$Required -MissingErrorCode 'github_release_pr_token_missing'
}

function New-GitHubHeaders {
  param([AllowNull()][string]$Token,[Parameter(Mandatory = $true)][string]$Version)
  $Headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'GoNow-release-pr-adapter'
    'X-GitHub-Api-Version' = $Version
  }
  if (-not [string]::IsNullOrWhiteSpace($Token)) { $Headers.Authorization = "Bearer $Token" }
  return $Headers
}

function Invoke-GitHubHttp {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('GET','POST','PATCH','PUT')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
    [AllowNull()][string]$BodyJson
  )
  try {
    $Arguments = @{Method=$Method;Uri=$Uri;Headers=$Headers;UseBasicParsing=$true;ErrorAction='Stop';TimeoutSec=30}
    if ($Method -ne 'GET') { $Arguments.ContentType='application/json';$Arguments.Body=$BodyJson }
    $Body = Invoke-RestMethod @Arguments
    return [pscustomobject][ordered]@{status_code=$(if($Method-ceq'POST'){201}else{200});body=$Body}
  } catch {
    $Status = 0
    if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
      $Status = [int]$_.Exception.Response.StatusCode
    }
    return [pscustomobject][ordered]@{status_code=$Status;body=$null}
  }
}

function Invoke-RequiredGitHubRequest {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$RequestInvoker,
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
    [AllowNull()][string]$BodyJson,
    [Parameter(Mandatory = $true)][int[]]$AllowedStatus,
    [Parameter(Mandatory = $true)][string]$FailureCode
  )
  $Response = & $RequestInvoker $Method $Uri $Headers $BodyJson
  if ([int]$Response.status_code -notin $AllowedStatus) { throw "$FailureCode`:$([int]$Response.status_code)" }
  return $Response
}

function Assert-OpaqueReference {
  param([Parameter(Mandatory = $true)][string]$Name,[AllowNull()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 256 -or $Value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:/@-]{2,255}$') {
    throw "github_release_pr_${Name}_invalid"
  }
  if ($Value -cmatch '(?i)(github_pat_|gh[pousr]_|sk-[A-Za-z0-9]{12,}|bearer[:_-])') {
    throw "github_release_pr_${Name}_secret_like"
  }
}

function Get-ExpectedLabels {
  param([Parameter(Mandatory = $true)][string]$TaskId)
  if ($TaskId -ceq 'TASK-P10-011') { return @('automated-merge-authorized','release-b') }
  if ($TaskId -ceq 'TASK-REL-C-001') { return @('automated-merge-authorized','release-c','single-capability') }
  throw 'github_release_pr_task_not_supported'
}

function Assert-ReleaseRequest {
  param([Parameter(Mandatory = $true)][object]$Request)
  $TaskId = [string](Get-PropertyValue -Object $Request -Name 'task_id')
  if ($TaskId -notin @('TASK-P10-011','TASK-REL-C-001')) { throw 'github_release_pr_task_not_supported' }
  $ExpectedLabels = Get-ExpectedLabels -TaskId $TaskId
  $Protection = Get-PropertyValue -Object $Request -Name 'required_branch_protection'
  $ReviewCount = if ($TaskId -ceq 'TASK-P10-011') {
    @(Get-PropertyValue -Object $Request -Name 'review_requests' -Default @()).Count
  } else { [int](Get-PropertyValue -Object $Request -Name 'review_request_count' -Default -1) }
  $CommonValid =
    [string](Get-PropertyValue -Object $Request -Name 'schema_version') -ceq '2.0' -and
    [string](Get-PropertyValue -Object $Request -Name 'profile') -ceq 'personal_automated' -and
    [string](Get-PropertyValue -Object $Request -Name 'repository_full_name') -ceq 'Elfsa-Miranda/GO_NOW' -and
    [string](Get-PropertyValue -Object $Request -Name 'api_repository') -ceq 'https://api.github.com/repos/Elfsa-Miranda/GO_NOW' -and
    [string](Get-PropertyValue -Object $Request -Name 'base_ref') -ceq 'main' -and
    [string](Get-PropertyValue -Object $Request -Name 'head_ref') -ceq 'codex/gonow-agent-landing' -and
    [string](Get-PropertyValue -Object $Request -Name 'head_oid') -cmatch '^[0-9a-f]{40}$' -and
    [string](Get-PropertyValue -Object $Request -Name 'remote_head_oid') -ceq [string](Get-PropertyValue -Object $Request -Name 'head_oid') -and
    [string](Get-PropertyValue -Object $Request -Name 'remote_main_oid') -cmatch '^[0-9a-f]{40}$' -and
    (Test-ExactStringSet -Actual @(Get-PropertyValue -Object $Request -Name 'required_checks' -Default @()) -Expected $script:RequiredCheckNames) -and
    (Test-ExactStringSet -Actual @(Get-PropertyValue -Object $Request -Name 'labels' -Default @()) -Expected $ExpectedLabels) -and
    [bool](Get-PropertyValue -Object $Protection -Name 'strict' -Default $false) -and
    [bool](Get-PropertyValue -Object $Protection -Name 'enforce_admins' -Default $false) -and
    [bool](Get-PropertyValue -Object $Protection -Name 'require_pull_request' -Default $false) -and
    -not [bool](Get-PropertyValue -Object $Protection -Name 'allow_force_pushes' -Default $true) -and
    -not [bool](Get-PropertyValue -Object $Protection -Name 'allow_deletions' -Default $true) -and
    -not [bool](Get-PropertyValue -Object $Protection -Name 'required_linear_history' -Default $true) -and
    [bool](Get-PropertyValue -Object $Request -Name 'auto_merge' -Default $false) -and
    [string](Get-PropertyValue -Object $Request -Name 'merge_method') -ceq 'merge' -and
    -not [bool](Get-PropertyValue -Object $Request -Name 'force_update_allowed' -Default $true) -and
    $ReviewCount -eq 0 -and
    [string](Get-PropertyValue -Object $Request -Name 'authorized_external_action') -ceq 'create_update_and_non_force_merge_pull_request' -and
    [string](Get-PropertyValue -Object $Request -Name 'adapter_contract') -ceq 'github_authorized_external_action' -and
    -not [bool](Get-PropertyValue -Object $Request -Name 'branch_protection_management_authorized' -Default $true) -and
    -not [bool](Get-PropertyValue -Object $Request -Name 'contract_change' -Default $true) -and
    [int](Get-PropertyValue -Object $Request -Name 'production_write_count' -Default -1) -eq 0
  if (-not $CommonValid) { throw 'github_release_pr_request_contract_invalid' }
  if ($TaskId -ceq 'TASK-REL-C-001') {
    if (
      [int](Get-PropertyValue -Object $Request -Name 'active_c_capability_count' -Default -1) -ne 1 -or
      [int](Get-PropertyValue -Object $Request -Name 'unselected_path_commit_count' -Default -1) -ne 0 -or
      [string](Get-PropertyValue -Object $Request -Name 'selected_path') -notin @('phase11','phase12') -or
      [string](Get-PropertyValue -Object $Request -Name 'selected_merge_sha') -cnotmatch '^[0-9a-f]{40}$' -or
      [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $Request -Name 'selected_capability'))
    ) { throw 'github_release_pr_release_c_scope_invalid' }
  }
  return [ordered]@{task_id=$TaskId;labels=$ExpectedLabels}
}

function Read-ReleaseRequest {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { throw 'github_release_pr_request_missing' }
  $Request = Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
  $Contract = Assert-ReleaseRequest -Request $Request
  return [ordered]@{value=$Request;contract=$Contract;sha256=Get-FileSha256 -LiteralPath $LiteralPath}
}

function ConvertTo-BranchProtectionCheck {
  param([AllowNull()][object]$Protection,[Parameter(Mandatory = $true)][string[]]$Checks)
  $Names = @()
  $StatusChecks = Get-PropertyValue -Object $Protection -Name 'required_status_checks'
  $CheckRows = Get-PropertyValue -Object $StatusChecks -Name 'checks'
  if ($null -ne $CheckRows -and @($CheckRows).Count -gt 0) {
    $Names = @($CheckRows | ForEach-Object { [string](Get-PropertyValue -Object $_ -Name 'context') } | Sort-Object)
  } else {
    $Names = @((Get-PropertyValue -Object $StatusChecks -Name 'contexts' -Default @()) | ForEach-Object { [string]$_ } | Sort-Object)
  }
  $GetEnabled = {
    param($Node)
    if ($null -eq $Node) { return $false }
    if ($Node -is [bool]) { return [bool]$Node }
    return [bool](Get-PropertyValue -Object $Node -Name 'enabled' -Default $false)
  }
  $Passed = $null -ne $Protection -and
    (Test-ExactStringSet -Actual $Names -Expected $Checks) -and
    [bool](Get-PropertyValue -Object $StatusChecks -Name 'strict' -Default $false) -and
    (& $GetEnabled (Get-PropertyValue -Object $Protection -Name 'enforce_admins')) -and
    $null -ne (Get-PropertyValue -Object $Protection -Name 'required_pull_request_reviews') -and
    -not (& $GetEnabled (Get-PropertyValue -Object $Protection -Name 'allow_force_pushes')) -and
    -not (& $GetEnabled (Get-PropertyValue -Object $Protection -Name 'allow_deletions')) -and
    -not (& $GetEnabled (Get-PropertyValue -Object $Protection -Name 'required_linear_history'))
  return [ordered]@{passed=$Passed;required_checks=$Names}
}

function Get-ReleaseRemoteState {
  param(
    [Parameter(Mandatory = $true)][object]$Request,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
    [Parameter(Mandatory = $true)][scriptblock]$RequestInvoker,
    [Parameter(Mandatory = $true)][string[]]$Labels
  )
  $Api = 'https://api.github.com/repos/Elfsa-Miranda/GO_NOW'
  $Main = Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/git/ref/heads/main" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_main_ref_query_failed'
  $Head = Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/git/ref/heads/codex/gonow-agent-landing" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_head_ref_query_failed'
  $ProtectionResponse = & $RequestInvoker 'GET' "$Api/branches/main/protection" $Headers $null
  $Protection = if ([int]$ProtectionResponse.status_code -eq 200) { ConvertTo-BranchProtectionCheck -Protection $ProtectionResponse.body -Checks $script:RequiredCheckNames } else { [ordered]@{passed=$false;required_checks=@()} }
  $MissingLabels = @()
  foreach ($Label in $Labels) {
    $Encoded = [Uri]::EscapeDataString($Label)
    $Response = & $RequestInvoker 'GET' "$Api/labels/$Encoded" $Headers $null
    if ([int]$Response.status_code -ne 200 -or [string](Get-PropertyValue -Object $Response.body -Name 'name') -cne $Label) { $MissingLabels += $Label }
  }
  $HeadFilter = [Uri]::EscapeDataString('Elfsa-Miranda:codex/gonow-agent-landing')
  $PullsResponse = Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/pulls?state=all&head=$HeadFilter&base=main&per_page=100" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_list_query_failed'
  $ExactPulls = @(@($PullsResponse.body) | Where-Object {
    [string](Get-PropertyValue -Object (Get-PropertyValue -Object $_ -Name 'head') -Name 'sha') -ceq [string]$Request.head_oid -and
    [string](Get-PropertyValue -Object (Get-PropertyValue -Object $_ -Name 'head') -Name 'ref') -ceq 'codex/gonow-agent-landing' -and
    [string](Get-PropertyValue -Object (Get-PropertyValue -Object $_ -Name 'base') -Name 'ref') -ceq 'main'
  })
  if ($ExactPulls.Count -gt 1) { throw 'github_release_pr_multiple_exact_pull_requests' }
  $Pull = if ($ExactPulls.Count -eq 1) { $ExactPulls[0] } else { $null }
  if ($null -ne $Pull -and [string]$Pull.state -ceq 'closed' -and -not [bool]$Pull.merged) { throw 'github_release_pr_exact_pull_closed_unmerged' }
  return [ordered]@{
    main_oid=[string](Get-PropertyValue -Object (Get-PropertyValue -Object $Main.body -Name 'object') -Name 'sha')
    head_oid=[string](Get-PropertyValue -Object (Get-PropertyValue -Object $Head.body -Name 'object') -Name 'sha')
    branch_protection=$Protection;missing_labels=$MissingLabels;pull=$Pull
  }
}

function Get-PullMetadata {
  param([Parameter(Mandatory = $true)][object]$Request,[Parameter(Mandatory = $true)][string]$RequestSha256)
  if ([string]$Request.task_id -ceq 'TASK-P10-011') {
    return [ordered]@{
      title='Release B: single-agent itinerary planning'
      body="Automated Release B candidate bound to request SHA-256 $RequestSha256. Merge only after protected required checks and exact tree verification."
    }
  }
  return [ordered]@{title=[string]$Request.title;body="$([string]$Request.body_contract)`n`nRequest SHA-256: $RequestSha256."}
}

function Get-CheckRunState {
  param([Parameter(Mandatory = $true)][object]$Body,[Parameter(Mandatory = $true)][string[]]$Required)
  $Rows = @((Get-PropertyValue -Object $Body -Name 'check_runs' -Default @()) | Where-Object { [string]$_.name -in $Required })
  $Names = @($Rows | ForEach-Object { [string]$_.name } | Sort-Object)
  $Exact = Test-ExactStringSet -Actual $Names -Expected $Required
  $Failures = @($Rows | Where-Object { [string]$_.status -cne 'completed' -or [string]$_.conclusion -cne 'success' }).Count
  $BoundedRows = @($Rows | Sort-Object name | ForEach-Object { [ordered]@{name=[string]$_.name;status=[string]$_.status;conclusion=[string]$_.conclusion} })
  return [ordered]@{passed=($Exact-and$Failures-eq0);set_exact=$Exact;failure_count=$Failures;rows=$BoundedRows}
}

function Wait-RequiredCheckRuns {
  param(
    [Parameter(Mandatory = $true)][string]$HeadOid,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
    [Parameter(Mandatory = $true)][scriptblock]$RequestInvoker,
    [Parameter(Mandatory = $true)][scriptblock]$SleepInvoker,
    [Parameter(Mandatory = $true)][int]$PollAttempts,
    [Parameter(Mandatory = $true)][int]$DelaySeconds
  )
  $Uri = "https://api.github.com/repos/Elfsa-Miranda/GO_NOW/commits/$HeadOid/check-runs?filter=latest&per_page=100"
  for ($Attempt=1; $Attempt -le $PollAttempts; $Attempt++) {
    $Response = Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri $Uri -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_check_query_failed'
    $State = Get-CheckRunState -Body $Response.body -Required $script:RequiredCheckNames
    if ([bool]$State.passed) { return $State }
    if ($Attempt -lt $PollAttempts) { & $SleepInvoker $DelaySeconds }
  }
  throw 'github_release_pr_required_checks_not_ready'
}

function Write-AtomicJson {
  param([Parameter(Mandatory = $true)][string]$LiteralPath,[Parameter(Mandatory = $true)][object]$Value)
  $Parent = Split-Path -Parent $LiteralPath
  if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { throw 'github_release_pr_output_parent_missing' }
  $Temporary = Join-Path $Parent ('.' + [IO.Path]::GetFileName($LiteralPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [IO.File]::WriteAllText($Temporary,(($Value|ConvertTo-Json -Depth 40)+"`n"),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $Temporary -Destination $LiteralPath -Force
  } finally { if(Test-Path -LiteralPath $Temporary){Remove-Item -LiteralPath $Temporary -Force} }
}

function Add-ReleaseCommandRecord {
  param(
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][object]$Request,
    [Parameter(Mandatory = $true)][string]$RequestSha256,
    [Parameter(Mandatory = $true)][string]$Actor,
    [Parameter(Mandatory = $true)][int]$ExitCode,
    [Parameter(Mandatory = $true)][double]$DurationSeconds
  )
  $TaskId=[string]$Request.task_id
  $Description=if($TaskId-ceq'TASK-P10-011'){'Create, validate, and non-force merge Release B pull request'}else{'Create, verify, and non-force merge the single-capability Release C pull request'}
  $Command=if($TaskId-ceq'TASK-P10-011'){"github-authorized-adapter release-b-pr request_sha256=$RequestSha256 merge_method=merge force=false"}else{"github-authorized-adapter create-update-and-merge-release-c-pr request_sha256=$RequestSha256"}
  if(Test-Path -LiteralPath $LiteralPath -PathType Leaf){$Ledger=Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop;$Rows=@($Ledger.commands)}else{$Ledger=[pscustomobject][ordered]@{schema_version='1.0';task_id=$TaskId;phase=if($TaskId-ceq'TASK-P10-011'){'Release B'}else{'Conditional Release C'};executed_at=[DateTimeOffset]::Now.ToString('o');executor=$Actor;git_object_format='sha1';head_oid=[string]$Request.head_oid;commands=@()};$Rows=@()}
  $ExistingSuccess=@($Rows|Where-Object{[string]$_.description-ceq$Description-and[string]$_.command-ceq$Command-and[int]$_.exit_code-eq0})
  if($ExitCode-eq0-and$ExistingSuccess.Count-eq1){return}
  $Empty=Get-Utf8Sha256 -Value ''
  $Rows += [ordered]@{step=$Rows.Count+1;description=$Description;command=$Command;exit_code=$ExitCode;stdout_tail='';stderr_tail='';stdout_sha256=$Empty;stderr_sha256=$Empty;duration_seconds=[Math]::Max(0,$DurationSeconds);redaction_reason='GitHub response is recorded as bounded structured observation; token and response bodies are not persisted.'}
  $Ledger.executed_at=[DateTimeOffset]::Now.ToString('o');$Ledger.executor=$Actor;$Ledger.head_oid=[string]$Request.head_oid;$Ledger.commands=$Rows
  Write-AtomicJson -LiteralPath $LiteralPath -Value $Ledger
}

function Get-MergedObservation {
  param(
    [Parameter(Mandatory = $true)][object]$Request,
    [Parameter(Mandatory = $true)][string]$RequestSha256,
    [Parameter(Mandatory = $true)][int]$PullNumber,
    [Parameter(Mandatory = $true)][string]$Actor,
    [Parameter(Mandatory = $true)][string]$Authorization,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
    [Parameter(Mandatory = $true)][scriptblock]$RequestInvoker,
    [Parameter(Mandatory = $true)][string[]]$Labels
  )
  $Api='https://api.github.com/repos/Elfsa-Miranda/GO_NOW'
  $Pull=(Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/pulls/$PullNumber" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_post_pull_query_failed').body
  $MergeSha=[string]$Pull.merge_commit_sha
  if(-not[bool]$Pull.merged-or[string]$Pull.state-cne'closed'-or$MergeSha-cnotmatch'^[0-9a-f]{40}$'){throw 'github_release_pr_post_merge_state_invalid'}
  $Main=(Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/git/ref/heads/main" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_post_main_query_failed').body
  $Head=(Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/git/ref/heads/codex/gonow-agent-landing" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_post_head_query_failed').body
  $HeadCommit=(Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/git/commits/$([string]$Request.head_oid)" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_head_commit_query_failed').body
  $MergeCommit=(Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/git/commits/$MergeSha" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_merge_commit_query_failed').body
  $Checks=(Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method GET -Uri "$Api/commits/$([string]$Request.head_oid)/check-runs?filter=latest&per_page=100" -Headers $Headers -BodyJson $null -AllowedStatus @(200) -FailureCode 'github_release_pr_post_check_query_failed').body
  $CheckState=Get-CheckRunState -Body $Checks -Required $script:RequiredCheckNames
  $Metadata=Get-PullMetadata -Request $Request -RequestSha256 $RequestSha256
  $ParentShas=@((Get-PropertyValue -Object $MergeCommit -Name 'parents' -Default @())|ForEach-Object{[string]$_.sha})
  $ActualLabels=@((Get-PropertyValue -Object $Pull -Name 'labels' -Default @())|ForEach-Object{[string]$_.name}|Sort-Object)
  $ReviewCount=@((Get-PropertyValue -Object $Pull -Name 'requested_reviewers' -Default @())).Count+@((Get-PropertyValue -Object $Pull -Name 'requested_teams' -Default @())).Count
  $MainOid=[string](Get-PropertyValue -Object (Get-PropertyValue -Object $Main -Name 'object') -Name 'sha')
  $HeadOid=[string](Get-PropertyValue -Object (Get-PropertyValue -Object $Head -Name 'object') -Name 'sha')
  $PullHead=Get-PropertyValue -Object $Pull -Name 'head';$PullBase=Get-PropertyValue -Object $Pull -Name 'base';$PullBaseRepo=Get-PropertyValue -Object $PullBase -Name 'repo'
  $TreeEqual=[string](Get-PropertyValue -Object (Get-PropertyValue -Object $HeadCommit -Name 'tree') -Name 'sha') -ceq [string](Get-PropertyValue -Object (Get-PropertyValue -Object $MergeCommit -Name 'tree') -Name 'sha')
  $PostChecks=[ordered]@{repository_match=([string](Get-PropertyValue -Object $PullBaseRepo -Name 'full_name')-ceq'Elfsa-Miranda/GO_NOW');pr_number_match=([int](Get-PropertyValue -Object $Pull -Name 'number')-eq$PullNumber);pr_url_match=([string](Get-PropertyValue -Object $Pull -Name 'html_url')-ceq"https://github.com/Elfsa-Miranda/GO_NOW/pull/$PullNumber");base_ref_match=([string](Get-PropertyValue -Object $PullBase -Name 'ref')-ceq'main');head_ref_match=([string](Get-PropertyValue -Object $PullHead -Name 'ref')-ceq'codex/gonow-agent-landing');pull_head_oid_match=([string](Get-PropertyValue -Object $PullHead -Name 'sha')-ceq[string]$Request.head_oid);title_match=([string](Get-PropertyValue -Object $Pull -Name 'title')-ceq[string]$Metadata.title);body_match=([string](Get-PropertyValue -Object $Pull -Name 'body')-ceq[string]$Metadata.body);main_at_merge=($MainOid-ceq$MergeSha);head_unchanged=($HeadOid-ceq[string]$Request.head_oid);parent_count=$ParentShas.Count;base_parent_match=($ParentShas.Count-ge1-and$ParentShas[0]-ceq[string]$Request.remote_main_oid);head_parent_match=($ParentShas.Count-ge2-and$ParentShas[1]-ceq[string]$Request.head_oid);tree_equal=$TreeEqual;checks_passed=[bool]$CheckState.passed;labels_exact=(Test-ExactStringSet -Actual $ActualLabels -Expected $Labels);review_request_count=$ReviewCount}
  if(@($PostChecks.Keys|Where-Object{$_-ne'parent_count'-and$_-ne'review_request_count'-and-not[bool]$PostChecks[$_]}).Count-ne0-or[int]$PostChecks.parent_count-ne2-or[int]$PostChecks.review_request_count-ne0){
    $PostDiagnostic=[ordered]@{checks=$PostChecks;actual_labels=$ActualLabels;expected_labels=$Labels}
    throw "github_release_pr_postcondition_failed:$($PostDiagnostic|ConvertTo-Json -Depth 10 -Compress)"
  }
  $ResponseSummary=[ordered]@{pr_number=$PullNumber;merge_commit_sha=$MergeSha;parent_shas=$ParentShas;tree_sha=[string]$MergeCommit.tree.sha;main_oid=$MainOid;head_oid=$HeadOid;title_sha256=Get-Utf8Sha256 -Value ([string]$Pull.title);body_sha256=Get-Utf8Sha256 -Value ([string]$Pull.body);labels=$ActualLabels;checks=$CheckState.rows}
  $Observation=[ordered]@{
    schema_version='2.0';task_id=[string]$Request.task_id;request_sha256=$RequestSha256;repository_full_name='Elfsa-Miranda/GO_NOW'
    pr_number=$PullNumber;pr_url="https://github.com/Elfsa-Miranda/GO_NOW/pull/$PullNumber";state='closed';merged=$true;merge_commit_sha=$MergeSha
    base_ref='main';head_ref='codex/gonow-agent-landing';head_oid=[string]$Request.head_oid;remote_head_oid=$HeadOid;remote_main_before_oid=[string]$Request.remote_main_oid
    auto_merge=$true;merge_method='merge';non_force_merge=$true;force_update_count=0;merged_tree_matches_attested_tree=$TreeEqual
    required_checks=$CheckState.rows;labels=$ActualLabels;review_request_count=0;branch_delete_count=0;source='github_api'
    mutation_receipt=[ordered]@{actor_id=$Actor;authorization_reference=$Authorization;request_sha256=$RequestSha256;response_sha256=Get-Utf8Sha256 -Value ($ResponseSummary|ConvertTo-Json -Depth 20 -Compress);http_status=200}
    observed_at=[DateTimeOffset]::Now.ToString('o');production_write_count=0
  }
  if([string]$Request.task_id-ceq'TASK-REL-C-001'){
    $Observation.selected_path=[string]$Request.selected_path;$Observation.selected_capability=[string]$Request.selected_capability;$Observation.selected_merge_sha=[string]$Request.selected_merge_sha
    $Observation.active_c_capability_count=1;$Observation.unselected_path_commit_count=0
  }
  return [pscustomobject]$Observation
}

function Invoke-ReleasePrOperation {
  param(
    [Parameter(Mandatory = $true)][string]$Operation,
    [Parameter(Mandatory = $true)][object]$RequestRecord,
    [AllowNull()][string]$ExpectedHash,
    [AllowNull()][string]$Authorization,
    [AllowNull()][string]$Actor,
    [Parameter(Mandatory = $true)][string]$ObservationPath,
    [Parameter(Mandatory = $true)][string]$LedgerPath,
    [Parameter(Mandatory = $true)][Collections.IDictionary]$Headers,
    [Parameter(Mandatory = $true)][scriptblock]$RequestInvoker,
    [Parameter(Mandatory = $true)][scriptblock]$SleepInvoker,
    [Parameter(Mandatory = $true)][int]$PollAttempts,
    [Parameter(Mandatory = $true)][int]$DelaySeconds
  )
  $Started=[DateTimeOffset]::Now;$Request=$RequestRecord.value;$RequestHash=[string]$RequestRecord.sha256;$Labels=@($RequestRecord.contract.labels)
  if($Operation-ceq'Apply'){
    Assert-OpaqueReference -Name 'authorization_reference' -Value $Authorization;Assert-OpaqueReference -Name 'actor_id' -Value $Actor
    if([string]::IsNullOrWhiteSpace($ExpectedHash)-or$ExpectedHash-cne$RequestHash){throw 'github_release_pr_request_sha256_cas_mismatch'}
  }
  try {
    $State=Get-ReleaseRemoteState -Request $Request -Headers $Headers -RequestInvoker $RequestInvoker -Labels $Labels
    $Pull=$State.pull;$Merged=$null-ne$Pull-and[bool]$Pull.merged-and[string]$Pull.state-ceq'closed'
    $Prerequisites=[ordered]@{head_oid_match=([string]$State.head_oid-ceq[string]$Request.head_oid);main_oid_match=([string]$State.main_oid-ceq[string]$Request.remote_main_oid);branch_protection_valid=[bool]$State.branch_protection.passed;missing_labels=@($State.missing_labels);exact_pull_exists=($null-ne$Pull);exact_pull_merged=$Merged}
    if($Operation-ceq'Plan'){
      $Ready=[bool]$Prerequisites.head_oid_match-and([bool]$Prerequisites.main_oid_match-or$Merged)-and[bool]$Prerequisites.branch_protection_valid-and@($Prerequisites.missing_labels).Count-eq0
      return [pscustomobject][ordered]@{schema_version='1.0';mode='plan';task_id=[string]$Request.task_id;request_sha256=$RequestHash;ready=$Ready;prerequisites=$Prerequisites;mutation_performed=$false;next_action=if($Merged){'observe_exact_merged_pull'}elseif($Ready){'authorized_create_update_wait_and_merge'}elseif(@($Prerequisites.missing_labels).Count-gt0){'preconfigure_required_repository_labels'}elseif(-not[bool]$Prerequisites.branch_protection_valid){'preconfigure_exact_main_protection'}else{'repair_remote_oid_drift'}}
    }
    if($Operation-ceq'RollbackPlan'){
      return [pscustomobject][ordered]@{schema_version='1.0';mode='rollback_plan';task_id=[string]$Request.task_id;request_sha256=$RequestHash;exact_pull_merged=$Merged;merge_commit_sha=if($Merged){[string]$Pull.merge_commit_sha}else{$null};mutation_performed=$false;next_action=if($Merged){'separately_authorized_non_force_revert_of_exact_merge_commit'}else{'close_exact_open_pull_without_deleting_branch'}}
    }
    if(-not[bool]$Prerequisites.head_oid_match-or(-not$Merged-and-not[bool]$Prerequisites.main_oid_match)){throw 'github_release_pr_remote_oid_drift'}
    if(-not[bool]$Prerequisites.branch_protection_valid){throw 'github_release_pr_branch_protection_invalid'}
    if(@($Prerequisites.missing_labels).Count-ne0){throw 'github_release_pr_required_labels_missing'}
    if(-not$Merged){
      $Api='https://api.github.com/repos/Elfsa-Miranda/GO_NOW';$Metadata=Get-PullMetadata -Request $Request -RequestSha256 $RequestHash
      if($null-eq$Pull){
        $Body=[ordered]@{title=[string]$Metadata.title;body=[string]$Metadata.body;head='codex/gonow-agent-landing';base='main';maintainer_can_modify=$false;draft=$false}|ConvertTo-Json -Depth 10 -Compress
        $Pull=(Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method POST -Uri "$Api/pulls" -Headers $Headers -BodyJson $Body -AllowedStatus @(201) -FailureCode 'github_release_pr_create_failed').body
      }else{
        $Body=[ordered]@{title=[string]$Metadata.title;body=[string]$Metadata.body;maintainer_can_modify=$false}|ConvertTo-Json -Depth 10 -Compress
        $Pull=(Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method PATCH -Uri "$Api/pulls/$([int]$Pull.number)" -Headers $Headers -BodyJson $Body -AllowedStatus @(200) -FailureCode 'github_release_pr_update_failed').body
      }
      $PullNumber=[int]$Pull.number
      $LabelBody=[ordered]@{labels=@($Labels)}|ConvertTo-Json -Depth 5 -Compress
      $SetLabels=Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method PUT -Uri "$Api/issues/$PullNumber/labels" -Headers $Headers -BodyJson $LabelBody -AllowedStatus @(200) -FailureCode 'github_release_pr_set_labels_failed'
      $ActualLabels=@($SetLabels.body|ForEach-Object{[string]$_.name})
      if(-not(Test-ExactStringSet -Actual $ActualLabels -Expected $Labels)){throw 'github_release_pr_label_postcondition_failed'}
      $null=Wait-RequiredCheckRuns -HeadOid ([string]$Request.head_oid) -Headers $Headers -RequestInvoker $RequestInvoker -SleepInvoker $SleepInvoker -PollAttempts $PollAttempts -DelaySeconds $DelaySeconds
      $BeforeMerge=Get-ReleaseRemoteState -Request $Request -Headers $Headers -RequestInvoker $RequestInvoker -Labels $Labels
      $Pull=$BeforeMerge.pull
      if($null-eq$Pull-or[int]$Pull.number-ne$PullNumber-or[string]$BeforeMerge.main_oid-cne[string]$Request.remote_main_oid-or[string]$BeforeMerge.head_oid-cne[string]$Request.head_oid-or-not[bool]$BeforeMerge.branch_protection.passed){throw 'github_release_pr_premerge_cas_failed'}
      $ReviewCount=@((Get-PropertyValue -Object $Pull -Name 'requested_reviewers' -Default @())).Count+@((Get-PropertyValue -Object $Pull -Name 'requested_teams' -Default @())).Count
      if($ReviewCount-ne0-or[bool](Get-PropertyValue -Object $Pull -Name 'draft' -Default $true)-or(Get-PropertyValue -Object $Pull -Name 'mergeable')-ne$true){throw 'github_release_pr_premerge_state_invalid'}
      $MergeBody=[ordered]@{sha=[string]$Request.head_oid;merge_method='merge';commit_title="$([string]$Metadata.title) (#$PullNumber)";commit_message="Automated protected merge bound to request SHA-256 $RequestHash."}|ConvertTo-Json -Depth 10 -Compress
      $Merge=Invoke-RequiredGitHubRequest -RequestInvoker $RequestInvoker -Method PUT -Uri "$Api/pulls/$PullNumber/merge" -Headers $Headers -BodyJson $MergeBody -AllowedStatus @(200) -FailureCode 'github_release_pr_merge_failed'
      if(-not[bool]$Merge.body.merged-or[string]$Merge.body.sha-cnotmatch'^[0-9a-f]{40}$'){throw 'github_release_pr_merge_response_invalid'}
    }else{$PullNumber=[int]$Pull.number}
    $Observation=Get-MergedObservation -Request $Request -RequestSha256 $RequestHash -PullNumber $PullNumber -Actor $Actor -Authorization $Authorization -Headers $Headers -RequestInvoker $RequestInvoker -Labels $Labels
    Write-AtomicJson -LiteralPath $ObservationPath -Value $Observation
    Add-ReleaseCommandRecord -LiteralPath $LedgerPath -Request $Request -RequestSha256 $RequestHash -Actor $Actor -ExitCode 0 -DurationSeconds ([Math]::Max(0,([DateTimeOffset]::Now-$Started).TotalSeconds))
    return $Observation
  }catch{
    if($Operation-ceq'Apply'-and-not[string]::IsNullOrWhiteSpace($Actor)){
      Add-ReleaseCommandRecord -LiteralPath $LedgerPath -Request $Request -RequestSha256 $RequestHash -Actor $Actor -ExitCode 1 -DurationSeconds ([Math]::Max(0,([DateTimeOffset]::Now-$Started).TotalSeconds))
    }
    throw
  }
}

function Resolve-CliRequestContext {
  param([Parameter(Mandatory = $true)][string]$Path)
  $ScriptDirectory=Split-Path -Parent $PSCommandPath;$RepositoryRoot=(& git -C $ScriptDirectory rev-parse --show-toplevel 2>$null).Trim()
  if($LASTEXITCODE-ne0-or[string]::IsNullOrWhiteSpace($RepositoryRoot)){throw 'github_release_pr_repository_root_unavailable'}
  $RepositoryRoot=[IO.Path]::GetFullPath($RepositoryRoot);$Full=[IO.Path]::GetFullPath($(if([IO.Path]::IsPathRooted($Path)){$Path}else{Join-Path $RepositoryRoot $Path}))
  $Allowed=@(
    [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'docs\execution\evidence\releases\P10-011\pr-request.json')),
    [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'docs\execution\evidence\releases\REL-C-001\pr-request.json'))
  )
  if($Full-notin$Allowed){throw 'github_release_pr_request_path_not_allowlisted'}
  $Parent=Split-Path -Parent $Full
  return [ordered]@{request=$Full;observation=Join-Path $Parent 'pr-observation.json';ledger=Join-Path $Parent 'commands.json'}
}

if($MyInvocation.InvocationName-ne'.'){
  $Context=Resolve-CliRequestContext -Path $RequestPath;$Record=Read-ReleaseRequest -LiteralPath $Context.request
  $Token=Get-GitHubToken -Required:($Mode-ceq'Apply');$Headers=New-GitHubHeaders -Token $Token -Version $ApiVersion
  $Attempts=[Math]::Max(1,[Math]::Ceiling($WaitTimeoutSeconds/[double]$PollSeconds))
  $Result=Invoke-ReleasePrOperation -Operation $Mode -RequestRecord $Record -ExpectedHash $ExpectedRequestSha256 -Authorization $AuthorizationReference -Actor $ActorId -ObservationPath $Context.observation -LedgerPath $Context.ledger -Headers $Headers -RequestInvoker ${function:Invoke-GitHubHttp} -SleepInvoker {param($Seconds) Start-Sleep -Seconds $Seconds} -PollAttempts $Attempts -DelaySeconds $PollSeconds
  $Result|ConvertTo-Json -Depth 40
}

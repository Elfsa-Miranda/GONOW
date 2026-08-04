[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$CommandRoot=Split-Path -Parent $PSScriptRoot
$ScriptPath=Join-Path $CommandRoot 'Invoke-GitHubReleasePullRequest.ps1'
$Tokens=$null;$ParseErrors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$Tokens,[ref]$ParseErrors)
if(@($ParseErrors).Count-ne0){throw 'positive: release PR adapter PowerShell parse failed'}
. $ScriptPath -RequestPath 'dot-source-only'

$Source=Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
foreach($Token in @(
  'github_release_pr_request_sha256_cas_mismatch','github_release_pr_branch_protection_invalid',
  'github_release_pr_required_labels_missing','github_release_pr_required_checks_not_ready',
  'github_release_pr_premerge_cas_failed','github_release_pr_postcondition_failed',
  "merge_method='merge'",'force_update_count=0','branch_delete_count=0',
  'separately_authorized_non_force_revert_of_exact_merge_commit','X-GitHub-Api-Version'
)){
  if(-not$Source.Contains($Token)){throw "negative: release PR safety token missing: $Token"}
}
if($Source-cmatch 'git\s+push|--force|Invoke-Expression\s+\$|Write-(?:Host|Output).*Token'){
  throw 'negative: release PR adapter contains push, force, dynamic shell, or token output path'
}

$BaseOid='a'*40;$HeadOid='b'*40;$MergeOid='c'*40;$TreeOid='d'*40;$RequestHash='1'*64
$P10Request=[pscustomobject][ordered]@{
  schema_version='2.0';task_id='TASK-P10-011';profile='personal_automated';task_card_binding='binding'
  repository_full_name='Elfsa-Miranda/GO_NOW';api_repository='https://api.github.com/repos/Elfsa-Miranda/GO_NOW'
  base_ref='main';head_ref='codex/gonow-agent-landing';head_oid=$HeadOid;remote_head_oid=$HeadOid;remote_main_oid=$BaseOid
  phase_10_merge_oid='2'*40;phase_10_close_oid='3'*40;acceptance_attestation_sha256='4'*64;merge_authorization_sha256='5'*64
  required_changes=@('verify clean');required_checks=@('agent-required','baseline-and-candidate','tracked-and-history')
  required_branch_protection=[pscustomobject][ordered]@{strict=$true;enforce_admins=$true;require_pull_request=$true;allow_force_pushes=$false;allow_deletions=$false;required_linear_history=$false}
  labels=@('automated-merge-authorized','release-b');auto_merge=$true;merge_method='merge';force_update_allowed=$false;review_requests=@()
  authorized_external_action='create_update_and_non_force_merge_pull_request';adapter_contract='github_authorized_external_action';branch_protection_management_authorized=$false
  contract_change=$false;production_write_count=0;created_at='2026-08-04T00:00:00Z'
}
$P10Contract=Assert-ReleaseRequest -Request $P10Request
$P10Record=[ordered]@{value=$P10Request;contract=$P10Contract;sha256=$RequestHash}

$RelCRequest=$P10Request|ConvertTo-Json -Depth 20|ConvertFrom-Json
$RelCRequest.task_id='TASK-REL-C-001';$RelCRequest.labels=@('automated-merge-authorized','release-c','single-capability')
$RelCRequest|Add-Member title 'Release C: single-agent-rag';$RelCRequest|Add-Member body_contract 'Exactly one accepted capability'
$RelCRequest|Add-Member selected_path 'phase11';$RelCRequest|Add-Member selected_capability 'single-agent-rag';$RelCRequest|Add-Member selected_merge_sha ('6'*40)
$RelCRequest|Add-Member active_c_capability_count 1;$RelCRequest|Add-Member unselected_path_commit_count 0;$RelCRequest|Add-Member review_request_count 0
$null=Assert-ReleaseRequest -Request $RelCRequest
$InvalidRequest=$P10Request|ConvertTo-Json -Depth 20|ConvertFrom-Json;$InvalidRequest.required_checks=@('agent-required')
$Rejected=$false;try{$null=Assert-ReleaseRequest -Request $InvalidRequest}catch{$Rejected=$_.Exception.Message-ceq'github_release_pr_request_contract_invalid'}
if(-not$Rejected){throw 'negative: incomplete required check set was accepted'}

function New-FakeInvokerBundle {
  param([switch]$MissingReleaseBLabel,[switch]$AllowForce,[switch]$ChecksFail,[switch]$WrongTree)
  $CapturedBaseOid=$script:BaseOid;$CapturedHeadOid=$script:HeadOid;$CapturedMergeOid=$script:MergeOid;$CapturedTreeOid=$script:TreeOid
  $State=[pscustomobject][ordered]@{created=$false;merged=$false;labels=@();title='';body='';pull_body=$null;label_body=$null;merge_body=$null;mutation_methods=[Collections.Generic.List[string]]::new();missing_label=[bool]$MissingReleaseBLabel;allow_force=[bool]$AllowForce;checks_fail=[bool]$ChecksFail;wrong_tree=[bool]$WrongTree}
  $MakeProtection={
    param($CurrentState)
    return [pscustomobject][ordered]@{
      required_status_checks=[pscustomobject]@{strict=$true;checks=@(
        [pscustomobject]@{context='agent-required'},[pscustomobject]@{context='baseline-and-candidate'},[pscustomobject]@{context='tracked-and-history'})}
      enforce_admins=[pscustomobject]@{enabled=$true};required_pull_request_reviews=[pscustomobject]@{required_approving_review_count=0}
      allow_force_pushes=[pscustomobject]@{enabled=[bool]$CurrentState.allow_force};allow_deletions=[pscustomobject]@{enabled=$false};required_linear_history=[pscustomobject]@{enabled=$false}
    }
  }
  $Invoker={
    param($Method,$Uri,$Headers,$BodyJson)
    if($Method-ne'GET'){$State.mutation_methods.Add("$Method $Uri")|Out-Null}
    if($Uri-like'*/git/ref/heads/main'){return [pscustomobject]@{status_code=200;body=[pscustomobject]@{object=[pscustomobject]@{sha=if($State.merged){$CapturedMergeOid}else{$CapturedBaseOid}}}}}
    if($Uri-like'*/git/ref/heads/codex/gonow-agent-landing'){return [pscustomobject]@{status_code=200;body=[pscustomobject]@{object=[pscustomobject]@{sha=$CapturedHeadOid}}}}
    if($Uri-like'*/branches/main/protection'){return [pscustomobject]@{status_code=200;body=(& $MakeProtection $State)}}
    if($Method-ceq'GET'-and$Uri-like'*/labels/*'){
      $Name=[Uri]::UnescapeDataString(($Uri-split'/')[-1]);if($State.missing_label-and$Name-ceq'release-b'){return [pscustomobject]@{status_code=404;body=$null}}
      return [pscustomobject]@{status_code=200;body=[pscustomobject]@{name=$Name}}
    }
    if($Method-ceq'GET'-and$Uri-cmatch'/pulls\?'){
      if(-not$State.created){return [pscustomobject]@{status_code=200;body=@()}}
      $Pull=[pscustomobject][ordered]@{number=17;html_url='https://github.com/Elfsa-Miranda/GO_NOW/pull/17';state=if($State.merged){'closed'}else{'open'};merged=[bool]$State.merged;merge_commit_sha=if($State.merged){$CapturedMergeOid}else{$null};mergeable=$true;draft=$false;head=[pscustomobject]@{ref='codex/gonow-agent-landing';sha=$CapturedHeadOid};base=[pscustomobject]@{ref='main';repo=[pscustomobject]@{full_name='Elfsa-Miranda/GO_NOW'}};labels=@($State.labels|ForEach-Object{[pscustomobject]@{name=$_}});requested_reviewers=@();requested_teams=@();title=[string]$State.title;body=[string]$State.body}
      return [pscustomobject]@{status_code=200;body=@($Pull)}
    }
    if($Method-ceq'POST'-and$Uri-like'*/pulls'){
      $State.created=$true;$State.pull_body=$BodyJson|ConvertFrom-Json;$State.title=[string]$State.pull_body.title;$State.body=[string]$State.pull_body.body
      $Pull=[pscustomobject][ordered]@{number=17;html_url='https://github.com/Elfsa-Miranda/GO_NOW/pull/17';state='open';merged=$false;merge_commit_sha=$null;mergeable=$true;draft=$false;head=[pscustomobject]@{ref='codex/gonow-agent-landing';sha=$CapturedHeadOid};base=[pscustomobject]@{ref='main';repo=[pscustomobject]@{full_name='Elfsa-Miranda/GO_NOW'}};labels=@();requested_reviewers=@();requested_teams=@();title=[string]$State.title;body=[string]$State.body}
      return [pscustomobject]@{status_code=201;body=$Pull}
    }
    if($Method-ceq'PATCH'-and$Uri-like'*/pulls/17'){
      $State.pull_body=$BodyJson|ConvertFrom-Json;$State.title=[string]$State.pull_body.title;$State.body=[string]$State.pull_body.body
      $Pull=[pscustomobject][ordered]@{number=17;html_url='https://github.com/Elfsa-Miranda/GO_NOW/pull/17';state='open';merged=$false;merge_commit_sha=$null;mergeable=$true;draft=$false;head=[pscustomobject]@{ref='codex/gonow-agent-landing';sha=$CapturedHeadOid};base=[pscustomobject]@{ref='main';repo=[pscustomobject]@{full_name='Elfsa-Miranda/GO_NOW'}};labels=@($State.labels|ForEach-Object{[pscustomobject]@{name=$_}});requested_reviewers=@();requested_teams=@();title=[string]$State.title;body=[string]$State.body}
      return [pscustomobject]@{status_code=200;body=$Pull}
    }
    if($Method-ceq'PUT'-and$Uri-like'*/issues/17/labels'){$State.label_body=$BodyJson|ConvertFrom-Json;$State.labels=@($State.label_body.labels);return [pscustomobject]@{status_code=200;body=@($State.labels|ForEach-Object{[pscustomobject]@{name=$_}})}}
    if($Method-ceq'PUT'-and$Uri-like'*/pulls/17/merge'){$State.merge_body=$BodyJson|ConvertFrom-Json;$State.merged=$true;return [pscustomobject]@{status_code=200;body=[pscustomobject]@{merged=$true;sha=$CapturedMergeOid;message='merged'}}}
    if($Method-ceq'GET'-and$Uri-like'*/pulls/17'){
      $Pull=[pscustomobject][ordered]@{number=17;html_url='https://github.com/Elfsa-Miranda/GO_NOW/pull/17';state=if($State.merged){'closed'}else{'open'};merged=[bool]$State.merged;merge_commit_sha=if($State.merged){$CapturedMergeOid}else{$null};mergeable=$true;draft=$false;head=[pscustomobject]@{ref='codex/gonow-agent-landing';sha=$CapturedHeadOid};base=[pscustomobject]@{ref='main';repo=[pscustomobject]@{full_name='Elfsa-Miranda/GO_NOW'}};labels=@($State.labels|ForEach-Object{[pscustomobject]@{name=$_}});requested_reviewers=@();requested_teams=@();title=[string]$State.title;body=[string]$State.body}
      return [pscustomobject]@{status_code=200;body=$Pull}
    }
    if($Method-ceq'GET'-and$Uri-like"*/git/commits/$CapturedHeadOid"){return [pscustomobject]@{status_code=200;body=[pscustomobject]@{tree=[pscustomobject]@{sha=$CapturedTreeOid};parents=@()}}}
    if($Method-ceq'GET'-and$Uri-like"*/git/commits/$CapturedMergeOid"){return [pscustomobject]@{status_code=200;body=[pscustomobject]@{tree=[pscustomobject]@{sha=if($State.wrong_tree){'e'*40}else{$CapturedTreeOid}};parents=@([pscustomobject]@{sha=$CapturedBaseOid},[pscustomobject]@{sha=$CapturedHeadOid})}}}
    if($Method-ceq'GET'-and$Uri-like'*/check-runs?*'){
      $Conclusion=if($State.checks_fail){'failure'}else{'success'}
      return [pscustomobject]@{status_code=200;body=[pscustomobject]@{check_runs=@(
        [pscustomobject]@{name='agent-required';status='completed';conclusion=$Conclusion},
        [pscustomobject]@{name='baseline-and-candidate';status='completed';conclusion=$Conclusion},
        [pscustomobject]@{name='tracked-and-history';status='completed';conclusion=$Conclusion})}}
    }
    return [pscustomobject]@{status_code=404;body=$null}
  }
  return [ordered]@{state=$State;invoker=$Invoker.GetNewClosure()}
}

$Headers=@{Accept='application/vnd.github+json';Authorization='Bearer secret-sentinel-must-not-appear';'X-GitHub-Api-Version'='2026-03-10'}
$NoSleep={param($Seconds)}
$TemporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ("gonow-release-pr-$([Guid]::NewGuid().ToString('N'))")
try{
  New-Item -ItemType Directory -Path $TemporaryRoot|Out-Null
  $PlanBundle=New-FakeInvokerBundle -MissingReleaseBLabel
  $Plan=Invoke-ReleasePrOperation -Operation Plan -RequestRecord $P10Record -ExpectedHash $null -Authorization $null -Actor $null -ObservationPath (Join-Path $TemporaryRoot 'plan-observation.json') -LedgerPath (Join-Path $TemporaryRoot 'plan-commands.json') -Headers $Headers -RequestInvoker $PlanBundle.invoker -SleepInvoker $NoSleep -PollAttempts 1 -DelaySeconds 0
  if([bool]$Plan.ready-or[string]$Plan.next_action-cne'preconfigure_required_repository_labels'-or$PlanBundle.state.mutation_methods.Count-ne0){throw "positive: missing-label plan did not remain read-only and fail closed: plan=$($Plan|ConvertTo-Json -Depth 10 -Compress) mutations=$($PlanBundle.state.mutation_methods.Count)"}

  $CasBundle=New-FakeInvokerBundle;$CasRejected=$false
  try{Invoke-ReleasePrOperation -Operation Apply -RequestRecord $P10Record -ExpectedHash ('f'*64) -Authorization 'authz:test' -Actor 'actor:test' -ObservationPath (Join-Path $TemporaryRoot 'cas-observation.json') -LedgerPath (Join-Path $TemporaryRoot 'cas-commands.json') -Headers $Headers -RequestInvoker $CasBundle.invoker -SleepInvoker $NoSleep -PollAttempts 1 -DelaySeconds 0|Out-Null}catch{$CasRejected=$_.Exception.Message-ceq'github_release_pr_request_sha256_cas_mismatch'}
  if(-not$CasRejected-or$CasBundle.state.mutation_methods.Count-ne0){throw 'negative: request SHA CAS mismatch reached a remote mutation'}

  $ProtectionBundle=New-FakeInvokerBundle -AllowForce;$ProtectionRejected=$false;$ProtectionLedger=Join-Path $TemporaryRoot 'protection-commands.json'
  $ProtectionError='';try{Invoke-ReleasePrOperation -Operation Apply -RequestRecord $P10Record -ExpectedHash $RequestHash -Authorization 'authz:test' -Actor 'actor:test' -ObservationPath (Join-Path $TemporaryRoot 'protection-observation.json') -LedgerPath $ProtectionLedger -Headers $Headers -RequestInvoker $ProtectionBundle.invoker -SleepInvoker $NoSleep -PollAttempts 1 -DelaySeconds 0|Out-Null}catch{$ProtectionError=$_.Exception.Message;$ProtectionRejected=$ProtectionError-ceq'github_release_pr_branch_protection_invalid'}
  $ProtectionLedgerValue=if(Test-Path $ProtectionLedger){Get-Content $ProtectionLedger -Raw|ConvertFrom-Json}else{$null};$ProtectionLastExit=if($null-ne$ProtectionLedgerValue){[int]@($ProtectionLedgerValue.commands)[-1].exit_code}else{-1}
  if(-not$ProtectionRejected-or$ProtectionBundle.state.mutation_methods.Count-ne0-or$ProtectionLastExit-ne1){throw "negative: invalid branch protection was accepted or not audited: error=$ProtectionError rejected=$ProtectionRejected mutations=$($ProtectionBundle.state.mutation_methods.Count) last_exit=$ProtectionLastExit"}

  $PositiveBundle=New-FakeInvokerBundle;$ObservationPath=Join-Path $TemporaryRoot 'positive-observation.json';$LedgerPath=Join-Path $TemporaryRoot 'positive-commands.json'
  try{
    $Result=Invoke-ReleasePrOperation -Operation Apply -RequestRecord $P10Record -ExpectedHash $RequestHash -Authorization 'authz:test' -Actor 'actor:test' -ObservationPath $ObservationPath -LedgerPath $LedgerPath -Headers $Headers -RequestInvoker $PositiveBundle.invoker -SleepInvoker $NoSleep -PollAttempts 1 -DelaySeconds 0
  }catch{
    throw "positive: release PR invocation failed: $($_.Exception.Message); fake_state=$($PositiveBundle.state|ConvertTo-Json -Depth 10 -Compress)"
  }
  $Methods=@($PositiveBundle.state.mutation_methods)
  if(-not[bool]$Result.merged-or[string]$Result.merge_commit_sha-cne$MergeOid-or-not[bool]$Result.merged_tree_matches_attested_tree-or[int]$Result.force_update_count+[int]$Result.branch_delete_count-ne0-or
    @($Methods|Where-Object{$_-like'POST */pulls'}).Count-ne1-or@($Methods|Where-Object{$_-like'PUT */pulls/17/merge'}).Count-ne1){throw 'positive: exact protected PR merge failed'}
  if([string]$PositiveBundle.state.pull_body.head-cne'codex/gonow-agent-landing'-or[string]$PositiveBundle.state.pull_body.base-cne'main'-or[bool]$PositiveBundle.state.pull_body.draft-or[bool]$PositiveBundle.state.pull_body.maintainer_can_modify-or[string]$PositiveBundle.state.merge_body.sha-cne$HeadOid-or[string]$PositiveBundle.state.merge_body.merge_method-cne'merge'-or-not(Test-ExactStringSet -Actual @($PositiveBundle.state.label_body.labels) -Expected @('automated-merge-authorized','release-b'))){throw 'positive: outbound PR, label, or merge CAS body invalid'}
  $Raw=(Get-Content $ObservationPath -Raw -Encoding UTF8)+"`n"+(Get-Content $LedgerPath -Raw -Encoding UTF8)
  if($Raw-cmatch'secret-sentinel-must-not-appear|Bearer '){throw 'negative: release PR evidence leaked the token'}
  $Ledger=Get-Content $LedgerPath -Raw -Encoding UTF8|ConvertFrom-Json
  if(@($Ledger.commands).Count-ne1-or[int]$Ledger.commands[0].exit_code-ne0-or[string]$Ledger.commands[0].command-cne"github-authorized-adapter release-b-pr request_sha256=$RequestHash merge_method=merge force=false"){throw 'positive: success command ledger binding invalid'}
  $MutationCount=$PositiveBundle.state.mutation_methods.Count
  $Second=Invoke-ReleasePrOperation -Operation Apply -RequestRecord $P10Record -ExpectedHash $RequestHash -Authorization 'authz:test' -Actor 'actor:test' -ObservationPath $ObservationPath -LedgerPath $LedgerPath -Headers $Headers -RequestInvoker $PositiveBundle.invoker -SleepInvoker $NoSleep -PollAttempts 1 -DelaySeconds 0
  $SecondLedger=Get-Content $LedgerPath -Raw -Encoding UTF8|ConvertFrom-Json
  if(-not[bool]$Second.merged-or$PositiveBundle.state.mutation_methods.Count-ne$MutationCount-or@($SecondLedger.commands).Count-ne1){throw 'positive: already-merged recovery was not mutation-free and idempotent'}

  $FailedChecksBundle=New-FakeInvokerBundle -ChecksFail;$ChecksRejected=$false;$FailedLedger=Join-Path $TemporaryRoot 'checks-commands.json'
  try{Invoke-ReleasePrOperation -Operation Apply -RequestRecord $P10Record -ExpectedHash $RequestHash -Authorization 'authz:test' -Actor 'actor:test' -ObservationPath (Join-Path $TemporaryRoot 'checks-observation.json') -LedgerPath $FailedLedger -Headers $Headers -RequestInvoker $FailedChecksBundle.invoker -SleepInvoker $NoSleep -PollAttempts 1 -DelaySeconds 0|Out-Null}catch{$ChecksRejected=$_.Exception.Message-ceq'github_release_pr_required_checks_not_ready'}
  if(-not$ChecksRejected-or$FailedChecksBundle.state.merged-or@($FailedChecksBundle.state.mutation_methods|Where-Object{$_-like'PUT */pulls/17/merge'}).Count-ne0-or(Test-Path (Join-Path $TemporaryRoot 'checks-observation.json'))){throw 'negative: failing checks reached merge or passing observation'}

  $WrongTreeBundle=New-FakeInvokerBundle -WrongTree;$TreeRejected=$false
  try{Invoke-ReleasePrOperation -Operation Apply -RequestRecord $P10Record -ExpectedHash $RequestHash -Authorization 'authz:test' -Actor 'actor:test' -ObservationPath (Join-Path $TemporaryRoot 'tree-observation.json') -LedgerPath (Join-Path $TemporaryRoot 'tree-commands.json') -Headers $Headers -RequestInvoker $WrongTreeBundle.invoker -SleepInvoker $NoSleep -PollAttempts 1 -DelaySeconds 0|Out-Null}catch{$TreeRejected=$_.Exception.Message-clike'github_release_pr_postcondition_failed:*'}
  if(-not$TreeRejected-or(Test-Path (Join-Path $TemporaryRoot 'tree-observation.json'))){throw 'negative: wrong merged tree produced an observation'}
}finally{
  if(Test-Path -LiteralPath $TemporaryRoot -PathType Container){Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force}
}

Write-Output 'Invoke-GitHubReleasePullRequest contracts passed'
exit 0

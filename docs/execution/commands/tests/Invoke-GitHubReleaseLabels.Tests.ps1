[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$CommandRoot=Split-Path -Parent $PSScriptRoot
$ScriptPath=Join-Path $CommandRoot 'Invoke-GitHubReleaseLabels.ps1'
$Tokens=$null;$ParseErrors=$null
$Ast=[Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$Tokens,[ref]$ParseErrors)
if(@($ParseErrors).Count-ne0){throw 'positive: release labels adapter PowerShell parse failed'}
. $ScriptPath

$Source=Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
foreach($Token in @(
  'github_release_labels_cas_mismatch','github_release_labels_case_collision_refused',
  'github_release_labels_rollback_label_cas_mismatch','github_release_labels_apply_postcondition_failed',
  'delete_only_receipt_created_labels_when_each_current_state_sha256_matches_created_state_sha256',
  'secret_value_recorded=$false','X-GitHub-Api-Version','2026-03-10'
)){
  if(-not$Source.Contains($Token)){throw "negative: release labels safety token missing: $Token"}
}
if($Source-cmatch'git\s+push|--force|Invoke-Expression\s+\$|Write-(?:Host|Output).*Token'){
  throw 'negative: release labels adapter contains push, force, dynamic shell, or token output path'
}

$NextTestLabelId=100
function New-TestLabel {
  param([Parameter(Mandatory=$true)][string]$Name,[Parameter(Mandatory=$true)][string]$Color,[AllowNull()][string]$Description)
  $script:NextTestLabelId++
  return [pscustomobject][ordered]@{id=$script:NextTestLabelId;name=$Name;color=$Color;description=$Description}
}

function New-FakeBundle {
  param([object[]]$Seed=@(),[int]$FailOnCreateNumber=0)
  $Labels=[Collections.Generic.List[object]]::new();foreach($Item in $Seed){$Labels.Add($Item)|Out-Null}
  $State=[pscustomobject][ordered]@{labels=$Labels;calls=[Collections.Generic.List[string]]::new();mutations=[Collections.Generic.List[string]]::new();create_attempt=0;next_id=1000;fail_on_create=$FailOnCreateNumber}
  $Invoker={
    param($Method,$Uri,$Headers,$BodyJson)
    $State.calls.Add("$Method $Uri")|Out-Null
    if($Method-cne'GET'){$State.mutations.Add("$Method $Uri")|Out-Null}
    if($Method-ceq'GET'-and$Uri-cmatch'/labels/([^/?]+)$'){
      $Name=[Uri]::UnescapeDataString($Matches[1]);$Match=@($State.labels|Where-Object{[string]::Equals([string]$_.name,$Name,[StringComparison]::OrdinalIgnoreCase)})
      if($Match.Count-eq0){return [pscustomobject]@{status_code=404;body=$null}}
      return [pscustomobject]@{status_code=200;body=$Match[0]}
    }
    if($Method-ceq'POST'-and$Uri-cmatch'/labels$'){
      $State.create_attempt++
      if($State.fail_on_create-gt0-and$State.create_attempt-eq$State.fail_on_create){return [pscustomobject]@{status_code=503;body=$null}}
      $Body=$BodyJson|ConvertFrom-Json -ErrorAction Stop
      $Collision=@($State.labels|Where-Object{[string]::Equals([string]$_.name,[string]$Body.name,[StringComparison]::OrdinalIgnoreCase)})
      if($Collision.Count-ne0){return [pscustomobject]@{status_code=422;body=$null}}
      $State.next_id++;$Created=[pscustomobject][ordered]@{id=[long]$State.next_id;name=[string]$Body.name;color=[string]$Body.color;description=[string]$Body.description}
      $State.labels.Add($Created)|Out-Null
      return [pscustomobject]@{status_code=201;body=$Created}
    }
    if($Method-ceq'DELETE'-and$Uri-cmatch'/labels/([^/?]+)$'){
      $Name=[Uri]::UnescapeDataString($Matches[1]);$Match=@($State.labels|Where-Object{[string]$_.name-ceq$Name})
      if($Match.Count-ne1){return [pscustomobject]@{status_code=404;body=$null}}
      $State.labels.Remove($Match[0])|Out-Null
      return [pscustomobject]@{status_code=204;body=$null}
    }
    return [pscustomobject]@{status_code=404;body=$null}
  }
  return [ordered]@{state=$State;invoker=$Invoker.GetNewClosure()}
}

$Definitions=New-DesiredLabelDefinitions
if(@($Definitions).Count-ne4-or(@($Definitions.name|Sort-Object)-join',')-cne'automated-merge-authorized,release-b,release-c,single-capability'){
  throw 'positive: frozen release label definition set invalid'
}
$Headers=@{Accept='application/vnd.github+json';Authorization=(('Bea'+'rer ')+'secret-sentinel-must-not-appear');'X-GitHub-Api-Version'='2026-03-10'}
$TemporaryRoot=Join-Path ([IO.Path]::GetTempPath()) ("gonow-release-labels-$([Guid]::NewGuid().ToString('N'))")
try{
  New-Item -ItemType Directory -Path $TemporaryRoot|Out-Null

  $AbsentBundle=New-FakeBundle
  $Plan=Invoke-ReleaseLabelOperation -Operation Plan -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $AbsentBundle.invoker
  if([bool]$Plan.compliant-or@($Plan.missing_labels).Count-ne4-or[bool]$Plan.mutation_performed-or$AbsentBundle.state.mutations.Count-ne0-or[string]$Plan.next_action-cne'authorized_create_missing_labels_with_expected_current_state_sha256'){
    throw 'positive: absent-label Plan was not read-only and bounded'
  }

  $MismatchPath=Join-Path $TemporaryRoot 'mismatch.json';$MismatchRejected=$false
  try{Invoke-ReleaseLabelOperation -Operation Apply -ExpectedStateSha256 ('f'*64) -Authorization 'authz:test' -Actor 'actor:test' -OutputReceiptPath $MismatchPath -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $AbsentBundle.invoker|Out-Null}catch{$MismatchRejected=$_.Exception.Message-ceq'github_release_labels_cas_mismatch'}
  if(-not$MismatchRejected-or$AbsentBundle.state.mutations.Count-ne0-or(Test-Path -LiteralPath $MismatchPath)){throw 'negative: state CAS mismatch reached mutation or receipt'}

  $CollisionBundle=New-FakeBundle -Seed @((New-TestLabel -Name 'Release-B' -Color 'ffffff' -Description 'case collision'))
  $CollisionPlan=Invoke-ReleaseLabelOperation -Operation Plan -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $CollisionBundle.invoker
  $CollisionPath=Join-Path $TemporaryRoot 'collision.json';$CollisionRejected=$false
  try{Invoke-ReleaseLabelOperation -Operation Apply -ExpectedStateSha256 ([string]$CollisionPlan.current_state_sha256) -Authorization 'authz:test' -Actor 'actor:test' -OutputReceiptPath $CollisionPath -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $CollisionBundle.invoker|Out-Null}catch{$CollisionRejected=$_.Exception.Message-ceq'github_release_labels_case_collision_refused'}
  if(-not$CollisionRejected-or$CollisionBundle.state.mutations.Count-ne0-or(Test-Path -LiteralPath $CollisionPath)){throw 'negative: case-colliding label was overwritten'}

  $Existing=New-TestLabel -Name 'release-b' -Color 'abcdef' -Description 'user-owned metadata must remain'
  $ApplyBundle=New-FakeBundle -Seed @($Existing)
  $Before=Get-LabelObservation -Definitions $Definitions -Headers $Headers -RequestInvoker $ApplyBundle.invoker
  $ApplyPath=Join-Path $TemporaryRoot 'apply.json'
  $Applied=Invoke-ReleaseLabelOperation -Operation Apply -ExpectedStateSha256 ([string]$Before.state_sha256) -Authorization 'authz:test' -Actor 'actor:test' -OutputReceiptPath $ApplyPath -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $ApplyBundle.invoker
  $Posts=@($ApplyBundle.state.mutations|Where-Object{$_-like'POST *'})
  $Preserved=@($ApplyBundle.state.labels|Where-Object{[string]$_.name-ceq'release-b'})
  if([string]$Applied.status-cne'completed'-or-not[bool]$Applied.mutation_performed-or[int]$Applied.mutation_count-ne3-or@($Applied.created_labels).Count-ne3-or$Posts.Count-ne3-or$Preserved.Count-ne1-or[string]$Preserved[0].color-cne'abcdef'-or[string]$Preserved[0].description-cne'user-owned metadata must remain'){
    throw 'positive: create-missing apply changed an existing label or created the wrong set'
  }
  $ApplyRaw=Get-Content -LiteralPath $ApplyPath -Raw -Encoding UTF8
  if($ApplyRaw-cmatch'secret-sentinel-must-not-appear|authz:test|actor:test|user-owned metadata must remain|Bearer '){throw 'negative: apply receipt leaked token, references, or raw existing metadata'}

  $MutationCount=$ApplyBundle.state.mutations.Count;$NoopPath=Join-Path $TemporaryRoot 'noop.json'
  $Noop=Invoke-ReleaseLabelOperation -Operation Apply -ExpectedStateSha256 ([string]$Applied.after_state_sha256) -Authorization 'authz:noop' -Actor 'actor:test' -OutputReceiptPath $NoopPath -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $ApplyBundle.invoker
  if([string]$Noop.status-cne'completed'-or[bool]$Noop.mutation_performed-or[int]$Noop.mutation_count-ne0-or$ApplyBundle.state.mutations.Count-ne$MutationCount){throw 'positive: compliant Apply was not mutation-free'}

  $RollbackPlan=Invoke-ReleaseLabelOperation -Operation RollbackPlan -InputApplyReceiptPath $ApplyPath -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $ApplyBundle.invoker
  if(@($RollbackPlan.deletable_labels).Count-ne3-or@($RollbackPlan.drifted_labels).Count-ne0-or[bool]$RollbackPlan.mutation_performed){throw 'positive: rollback plan did not target exactly receipt-created labels'}

  $FirstCreated=[string]$Applied.created_labels[0].name;$Drifted=@($ApplyBundle.state.labels|Where-Object{[string]$_.name-ceq$FirstCreated})[0];$OriginalColor=[string]$Drifted.color;$Drifted.color='000000'
  $DriftObservation=Get-LabelObservation -Definitions $Definitions -Headers $Headers -RequestInvoker $ApplyBundle.invoker
  $DriftPath=Join-Path $TemporaryRoot 'drift.json';$DriftRejected=$false;$BeforeDriftMutations=$ApplyBundle.state.mutations.Count
  try{Invoke-ReleaseLabelOperation -Operation Rollback -ExpectedStateSha256 ([string]$DriftObservation.state_sha256) -Authorization 'authz:rollback' -Actor 'actor:test' -OutputReceiptPath $DriftPath -InputApplyReceiptPath $ApplyPath -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $ApplyBundle.invoker|Out-Null}catch{$DriftRejected=$_.Exception.Message-ceq'github_release_labels_rollback_label_cas_mismatch'}
  if(-not$DriftRejected-or$ApplyBundle.state.mutations.Count-ne$BeforeDriftMutations-or(Test-Path -LiteralPath $DriftPath)){throw 'negative: drifted created label was deleted'}
  $Drifted.color=$OriginalColor

  $RollbackBefore=Get-LabelObservation -Definitions $Definitions -Headers $Headers -RequestInvoker $ApplyBundle.invoker
  $RollbackPath=Join-Path $TemporaryRoot 'rollback.json'
  $RolledBack=Invoke-ReleaseLabelOperation -Operation Rollback -ExpectedStateSha256 ([string]$RollbackBefore.state_sha256) -Authorization 'authz:rollback' -Actor 'actor:test' -OutputReceiptPath $RollbackPath -InputApplyReceiptPath $ApplyPath -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $ApplyBundle.invoker
  $Deletes=@($ApplyBundle.state.mutations|Where-Object{$_-like'DELETE *'});$Remaining=@($ApplyBundle.state.labels)
  if([string]$RolledBack.status-cne'completed'-or[int]$RolledBack.mutation_count-ne3-or$Deletes.Count-ne3-or$Remaining.Count-ne1-or[string]$Remaining[0].name-cne'release-b'-or[string]$Remaining[0].color-cne'abcdef'){
    throw 'positive: rollback did not preserve the pre-existing label'
  }
  $RollbackRaw=Get-Content -LiteralPath $RollbackPath -Raw -Encoding UTF8
  if($RollbackRaw-cmatch'secret-sentinel-must-not-appear|authz:rollback|actor:test|Bearer '){throw 'negative: rollback receipt leaked token or raw references'}

  $FailureBundle=New-FakeBundle -FailOnCreateNumber 3;$FailureBefore=Get-LabelObservation -Definitions $Definitions -Headers $Headers -RequestInvoker $FailureBundle.invoker;$FailurePath=Join-Path $TemporaryRoot 'partial-failure.json';$FailureRejected=$false
  try{Invoke-ReleaseLabelOperation -Operation Apply -ExpectedStateSha256 ([string]$FailureBefore.state_sha256) -Authorization 'authz:failure' -Actor 'actor:test' -OutputReceiptPath $FailurePath -Definitions $Definitions -Version '2026-03-10' -Headers $Headers -RequestInvoker $FailureBundle.invoker|Out-Null}catch{$FailureRejected=$_.Exception.Message-clike'github_release_labels_create_failed:*'}
  $FailureReceipt=Get-Content -LiteralPath $FailurePath -Raw -Encoding UTF8|ConvertFrom-Json
  if(-not$FailureRejected-or[string]$FailureReceipt.status-cne'failed'-or[int]$FailureReceipt.mutation_count-ne2-or@($FailureReceipt.created_labels).Count-ne2-or@($FailureBundle.state.labels).Count-ne2){throw 'negative: partial create failure lost its reversible receipt'}
}finally{
  if(Test-Path -LiteralPath $TemporaryRoot -PathType Container){Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force}
}

Write-Output 'Invoke-GitHubReleaseLabels contracts passed'
exit 0

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
$ApiVersion = '2026-03-10'

function Get-Utf8Sha256 {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
  $Algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $Bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    return ([BitConverter]::ToString($Algorithm.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()
  } finally { $Algorithm.Dispose() }
}

function ConvertTo-CanonicalJson {
  param([Parameter(Mandatory = $true)][object]$Value)
  return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function Get-ObjectSha256 {
  param([Parameter(Mandatory = $true)][object]$Value)
  return Get-Utf8Sha256 -Value (ConvertTo-CanonicalJson -Value $Value)
}

function Get-PropertyValue {
  param([object]$Object,[Parameter(Mandatory = $true)][string]$Name,[object]$Default=$null)
  if($null-eq$Object){return $Default}
  if($Object-is[Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $Default}
  $Property=$Object.PSObject.Properties[$Name]
  if($null-eq$Property){return $Default}
  return $Property.Value
}

function New-DesiredLabelDefinitions {
  return @(
    [ordered]@{name='automated-merge-authorized';color='0e8a16';description='Automated merge allowed only after required checks and CAS verification.'},
    [ordered]@{name='release-b';color='1d76db';description='Release B governance and publication.'},
    [ordered]@{name='release-c';color='5319e7';description='Release C governance and publication.'},
    [ordered]@{name='single-capability';color='fbca04';description='Release C contains exactly one selected capability.'}
  )
}

function Get-GitHubToken {
  param([switch]$Required)
  foreach($Name in @('GH_TOKEN','GITHUB_TOKEN')){
    $Value=[Environment]::GetEnvironmentVariable($Name,'Process')
    if(-not[string]::IsNullOrWhiteSpace($Value)){return $Value}
  }
  if($Required){throw 'github_release_labels_token_missing'}
  return $null
}

function New-GitHubHeaders {
  param([AllowNull()][string]$Token,[Parameter(Mandatory=$true)][string]$Version)
  $Headers=@{Accept='application/vnd.github+json';'User-Agent'='GoNow-release-labels-adapter';'X-GitHub-Api-Version'=$Version}
  if(-not[string]::IsNullOrWhiteSpace($Token)){$Headers.Authorization="Bearer $Token"}
  return $Headers
}

function Invoke-GitHubHttp {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('GET','POST','DELETE')][string]$Method,
    [Parameter(Mandatory=$true)][string]$Uri,
    [Parameter(Mandatory=$true)][Collections.IDictionary]$Headers,
    [AllowNull()][string]$BodyJson
  )
  try{
    $Arguments=@{Method=$Method;Uri=$Uri;Headers=$Headers;UseBasicParsing=$true;ErrorAction='Stop';TimeoutSec=30}
    if($Method-ceq'POST'){$Arguments.ContentType='application/json';$Arguments.Body=$BodyJson}
    $Body=Invoke-RestMethod @Arguments
    $Status=if($Method-ceq'POST'){201}elseif($Method-ceq'DELETE'){204}else{200}
    return [pscustomobject][ordered]@{status_code=$Status;body=$Body}
  }catch{
    $Status=0
    if($null-ne$_.Exception.Response-and$null-ne$_.Exception.Response.StatusCode){$Status=[int]$_.Exception.Response.StatusCode}
    return [pscustomobject][ordered]@{status_code=$Status;body=$null}
  }
}

function ConvertTo-LabelState {
  param(
    [Parameter(Mandatory=$true)][string]$ExpectedName,
    [Parameter(Mandatory=$true)][int]$StatusCode,
    [AllowNull()][object]$Body
  )
  if($StatusCode-eq404){return [ordered]@{name=$ExpectedName;state='absent'}}
  if($StatusCode-ne200-or$null-eq$Body){throw "github_release_labels_query_failed:$ExpectedName`:$StatusCode"}
  $ActualName=[string](Get-PropertyValue -Object $Body -Name 'name')
  $LabelId=[long](Get-PropertyValue -Object $Body -Name 'id' -Default 0)
  if($LabelId-le0){throw "github_release_labels_response_identity_invalid:$ExpectedName"}
  $Color=([string](Get-PropertyValue -Object $Body -Name 'color')).ToLowerInvariant()
  $Description=[string](Get-PropertyValue -Object $Body -Name 'description' -Default '')
  if($ActualName-cne$ExpectedName){return [ordered]@{name=$ExpectedName;state='case_collision';label_id=$LabelId;actual_name=$ActualName;color=$Color;description_sha256=Get-Utf8Sha256 -Value $Description}}
  return [ordered]@{name=$ExpectedName;state='present';label_id=$LabelId;actual_name=$ActualName;color=$Color;description_sha256=Get-Utf8Sha256 -Value $Description}
}

function Get-LabelObservation {
  param(
    [Parameter(Mandatory=$true)][object[]]$Definitions,
    [Parameter(Mandatory=$true)][Collections.IDictionary]$Headers,
    [Parameter(Mandatory=$true)][scriptblock]$RequestInvoker
  )
  $Api='https://api.github.com/repos/Elfsa-Miranda/GO_NOW'
  $Rows=@()
  foreach($Definition in @($Definitions|Sort-Object{[string]$_.name})){
    $Name=[string]$Definition.name;$Encoded=[Uri]::EscapeDataString($Name)
    $Response=& $RequestInvoker 'GET' "$Api/labels/$Encoded" $Headers $null
    $Rows+=ConvertTo-LabelState -ExpectedName $Name -StatusCode ([int]$Response.status_code) -Body $Response.body
  }
  $State=[ordered]@{schema_version='1.0';repository='Elfsa-Miranda/GO_NOW';labels=$Rows}
  $Missing=@($Rows|Where-Object{[string]$_.state-ceq'absent'}|ForEach-Object{[string]$_.name})
  $Collisions=@($Rows|Where-Object{[string]$_.state-ceq'case_collision'}|ForEach-Object{[string]$_.name})
  return [pscustomobject][ordered]@{state=$State;state_sha256=Get-ObjectSha256 -Value $State;missing=$Missing;case_collisions=$Collisions;compliant=($Missing.Count+$Collisions.Count-eq0)}
}

function Resolve-ReceiptPath {
  param([Parameter(Mandatory=$true)][string]$Path)
  if([string]::IsNullOrWhiteSpace($Path)){throw 'github_release_labels_receipt_path_missing'}
  $Resolved=[IO.Path]::GetFullPath($Path);$Parent=Split-Path -Parent $Resolved
  if(-not(Test-Path -LiteralPath $Parent -PathType Container)){throw 'github_release_labels_receipt_parent_missing'}
  $ParentItem=Get-Item -LiteralPath $Parent -Force
  if([bool]($ParentItem.Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'github_release_labels_receipt_parent_reparse_point'}
  return $Resolved
}

function Write-AtomicReceipt {
  param([Parameter(Mandatory=$true)][string]$LiteralPath,[Parameter(Mandatory=$true)][object]$Value,[switch]$AllowSameActionUpdate)
  if(Test-Path -LiteralPath $LiteralPath){
    if(-not$AllowSameActionUpdate){throw 'github_release_labels_receipt_exists'}
    $Existing=Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
    if([string]$Existing.action_id-cne[string]$Value.action_id){throw 'github_release_labels_receipt_action_mismatch'}
  }
  $Parent=Split-Path -Parent $LiteralPath;$Temporary=Join-Path $Parent ('.'+[IO.Path]::GetFileName($LiteralPath)+'.'+[Guid]::NewGuid().ToString('N')+'.tmp')
  try{
    [IO.File]::WriteAllText($Temporary,(($Value|ConvertTo-Json -Depth 30)+"`n"),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $Temporary -Destination $LiteralPath -Force
  }finally{if(Test-Path -LiteralPath $Temporary){Remove-Item -LiteralPath $Temporary -Force}}
}

function Assert-AuthorizationInputs {
  param([AllowNull()][string]$Authorization,[AllowNull()][string]$Actor)
  foreach($Pair in @(@('authorization',$Authorization),@('actor',$Actor))){
    $Value=[string]$Pair[1]
    if([string]::IsNullOrWhiteSpace($Value)-or$Value.Length-gt256-or$Value-cnotmatch'^[A-Za-z0-9][A-Za-z0-9._:/@-]{2,255}$'){throw "github_release_labels_$([string]$Pair[0])_reference_invalid"}
    if($Value-cmatch'(?i)(github_pat_|gh[pousr]_|sk-[A-Za-z0-9]{12,}|bearer[:_-])'){throw "github_release_labels_$([string]$Pair[0])_reference_secret_like"}
  }
}

function Read-ApplyReceipt {
  param([Parameter(Mandatory=$true)][string]$LiteralPath)
  if(-not(Test-Path -LiteralPath $LiteralPath -PathType Leaf)){throw 'github_release_labels_apply_receipt_missing'}
  $Receipt=Get-Content -LiteralPath $LiteralPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
  if([string]$Receipt.schema_version-cne'1.0'-or[string]$Receipt.receipt_kind-cne'github_release_label_change'-or[string]$Receipt.operation-cne'apply'-or[string]$Receipt.target-cne'Elfsa-Miranda/GO_NOW'-or[string]$Receipt.status-notin@('completed','failed')-or[string]$Receipt.action_id-cnotmatch'^[0-9a-f]{64}$'){throw 'github_release_labels_apply_receipt_invalid'}
  $CreatedRows=@($Receipt.created_labels);$CreatedNames=@($CreatedRows|ForEach-Object{[string]$_.name})
  if(@($CreatedNames|Sort-Object -Unique).Count-ne$CreatedNames.Count-or[int]$Receipt.mutation_count-ne$CreatedRows.Count){throw 'github_release_labels_apply_receipt_invalid'}
  foreach($Created in $CreatedRows){if([string]$Created.name-notin@('automated-merge-authorized','release-b','release-c','single-capability')-or[string]$Created.state_sha256-cnotmatch'^[0-9a-f]{64}$'){throw 'github_release_labels_apply_receipt_invalid'}}
  return $Receipt
}

function Get-RollbackState {
  param([Parameter(Mandatory=$true)][object]$Observation,[Parameter(Mandatory=$true)][object]$ApplyReceipt)
  $Deletable=@();$Absent=@();$Drifted=@()
  foreach($Created in @($ApplyReceipt.created_labels)){
    $Row=@($Observation.state.labels|Where-Object{[string]$_.name-ceq[string]$Created.name})
    if($Row.Count-ne1){$Drifted+=[string]$Created.name;continue}
    if([string]$Row[0].state-ceq'absent'){$Absent+=[string]$Created.name;continue}
    if((Get-ObjectSha256 -Value $Row[0])-ceq[string]$Created.state_sha256){$Deletable+=[string]$Created.name}else{$Drifted+=[string]$Created.name}
  }
  return [pscustomobject][ordered]@{deletable=$Deletable;already_absent=$Absent;drifted=$Drifted}
}

function Invoke-ReleaseLabelOperation {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('Verify','Plan','Apply','RollbackPlan','Rollback')][string]$Operation,
    [AllowNull()][string]$ExpectedStateSha256,
    [AllowNull()][string]$Authorization,
    [AllowNull()][string]$Actor,
    [AllowNull()][string]$OutputReceiptPath,
    [AllowNull()][string]$InputApplyReceiptPath,
    [Parameter(Mandatory=$true)][object[]]$Definitions,
    [Parameter(Mandatory=$true)][string]$Version,
    [Parameter(Mandatory=$true)][Collections.IDictionary]$Headers,
    [Parameter(Mandatory=$true)][scriptblock]$RequestInvoker
  )
  $Observation=Get-LabelObservation -Definitions $Definitions -Headers $Headers -RequestInvoker $RequestInvoker
  $DefinitionState=[ordered]@{schema_version='1.0';repository='Elfsa-Miranda/GO_NOW';definitions=@($Definitions|Sort-Object{[string]$_.name})}
  $DefinitionSha=Get-ObjectSha256 -Value $DefinitionState
  if($Operation-in@('Verify','Plan')){
    return [pscustomobject][ordered]@{schema_version='1.0';mode=$Operation.ToLowerInvariant();target='Elfsa-Miranda/GO_NOW';api_version=$Version;current_state_sha256=[string]$Observation.state_sha256;desired_definition_sha256=$DefinitionSha;compliant=[bool]$Observation.compliant;missing_labels=@($Observation.missing);case_collision_labels=@($Observation.case_collisions);mutation_performed=$false;next_action=if([bool]$Observation.compliant){'none'}elseif(@($Observation.case_collisions).Count-gt0){'manual_review_case_collision_no_overwrite'}else{'authorized_create_missing_labels_with_expected_current_state_sha256'}}
  }
  if($Operation-ceq'RollbackPlan'){
    if([string]::IsNullOrWhiteSpace($InputApplyReceiptPath)){throw 'github_release_labels_apply_receipt_path_missing'}
    $ApplyReceipt=Read-ApplyReceipt -LiteralPath ([IO.Path]::GetFullPath($InputApplyReceiptPath))
    $Rollback=Get-RollbackState -Observation $Observation -ApplyReceipt $ApplyReceipt
    return [pscustomobject][ordered]@{schema_version='1.0';mode='rollback_plan';target='Elfsa-Miranda/GO_NOW';current_state_sha256=[string]$Observation.state_sha256;apply_action_id=[string]$ApplyReceipt.action_id;deletable_labels=@($Rollback.deletable);already_absent_labels=@($Rollback.already_absent);drifted_labels=@($Rollback.drifted);mutation_performed=$false;next_action=if(@($Rollback.drifted).Count-gt0){'manual_review_label_drift_no_delete'}elseif(@($Rollback.deletable).Count-gt0){'authorized_delete_only_labels_created_by_apply_receipt'}else{'none'}}
  }

  Assert-AuthorizationInputs -Authorization $Authorization -Actor $Actor
  if([string]::IsNullOrWhiteSpace($ExpectedStateSha256)){throw 'github_release_labels_expected_state_sha256_missing'}
  if([string]$Observation.state_sha256-cne$ExpectedStateSha256){throw 'github_release_labels_cas_mismatch'}
  $ResolvedReceipt=Resolve-ReceiptPath -Path $OutputReceiptPath
  $AuthorizationHash=Get-Utf8Sha256 -Value $Authorization;$ActorHash=Get-Utf8Sha256 -Value $Actor
  $Api='https://api.github.com/repos/Elfsa-Miranda/GO_NOW'

  if($Operation-ceq'Apply'){
    if(@($Observation.case_collisions).Count-gt0){throw 'github_release_labels_case_collision_refused'}
    $ActionId=Get-Utf8Sha256 -Value "apply|Elfsa-Miranda/GO_NOW|$ExpectedStateSha256|$DefinitionSha|$AuthorizationHash|$ActorHash"
    $Receipt=[ordered]@{schema_version='1.0';receipt_kind='github_release_label_change';operation='apply';status='prepared';action_id=$ActionId;target='Elfsa-Miranda/GO_NOW';api_version=$Version;authorization_reference_sha256=$AuthorizationHash;actor_reference_sha256=$ActorHash;before_state_sha256=[string]$Observation.state_sha256;desired_definition_sha256=$DefinitionSha;missing_before=@($Observation.missing);created_labels=@();mutation_count=0;mutation_performed=$false;after_state_sha256=$null;rollback_contract='delete_only_receipt_created_labels_when_each_current_state_sha256_matches_created_state_sha256';secret_value_recorded=$false;prepared_at=[DateTimeOffset]::Now.ToString('o');completed_at=$null}
    Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
    try{
      foreach($Name in @($Observation.missing)){
        $Definition=@($Definitions|Where-Object{[string]$_.name-ceq$Name})
        if($Definition.Count-ne1){throw 'github_release_labels_definition_missing'}
        $Body=[ordered]@{name=[string]$Definition[0].name;color=[string]$Definition[0].color;description=[string]$Definition[0].description}|ConvertTo-Json -Depth 5 -Compress
        $Response=& $RequestInvoker 'POST' "$Api/labels" $Headers $Body
        if([int]$Response.status_code-ne201){throw "github_release_labels_create_failed:$Name`:$([int]$Response.status_code)"}
        $Created=ConvertTo-LabelState -ExpectedName $Name -StatusCode 200 -Body $Response.body
        $ExpectedColor=([string]$Definition[0].color).ToLowerInvariant();$ExpectedDescriptionHash=Get-Utf8Sha256 -Value ([string]$Definition[0].description)
        if([string]$Created.state-cne'present'-or[long]$Created.label_id-le0-or[string]$Created.actual_name-cne$Name-or[string]$Created.color-cne$ExpectedColor-or[string]$Created.description_sha256-cne$ExpectedDescriptionHash){throw "github_release_labels_create_postcondition_failed:$Name"}
        $Receipt.created_labels+= [ordered]@{name=$Name;state_sha256=Get-ObjectSha256 -Value $Created}
        $Receipt.mutation_count=[int]$Receipt.mutation_count+1;$Receipt.mutation_performed=$true
        Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
      }
      $After=Get-LabelObservation -Definitions $Definitions -Headers $Headers -RequestInvoker $RequestInvoker
      if(-not[bool]$After.compliant){throw 'github_release_labels_apply_postcondition_failed'}
      $Receipt.status='completed';$Receipt.after_state_sha256=[string]$After.state_sha256;$Receipt.completed_at=[DateTimeOffset]::Now.ToString('o')
      Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
      return [pscustomobject]$Receipt
    }catch{
      $Receipt.status='failed';$Receipt.failure_code=[string]$_.Exception.Message;$Receipt.completed_at=[DateTimeOffset]::Now.ToString('o')
      Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
      throw
    }
  }

  if([string]::IsNullOrWhiteSpace($InputApplyReceiptPath)){throw 'github_release_labels_apply_receipt_path_missing'}
  $ApplyReceipt=Read-ApplyReceipt -LiteralPath ([IO.Path]::GetFullPath($InputApplyReceiptPath));$RollbackState=Get-RollbackState -Observation $Observation -ApplyReceipt $ApplyReceipt
  if(@($RollbackState.drifted).Count-gt0){throw 'github_release_labels_rollback_label_cas_mismatch'}
  $ActionId=Get-Utf8Sha256 -Value "rollback|Elfsa-Miranda/GO_NOW|$ExpectedStateSha256|$AuthorizationHash|$ActorHash|$([string]$ApplyReceipt.action_id)"
  $Receipt=[ordered]@{schema_version='1.0';receipt_kind='github_release_label_change';operation='rollback';status='prepared';action_id=$ActionId;target='Elfsa-Miranda/GO_NOW';api_version=$Version;authorization_reference_sha256=$AuthorizationHash;actor_reference_sha256=$ActorHash;apply_action_id=[string]$ApplyReceipt.action_id;before_state_sha256=[string]$Observation.state_sha256;deleted_labels=@();already_absent_labels=@($RollbackState.already_absent);mutation_count=0;mutation_performed=$false;after_state_sha256=$null;rollback_contract='delete_only_receipt_created_labels_when_each_current_state_sha256_matches_created_state_sha256';secret_value_recorded=$false;prepared_at=[DateTimeOffset]::Now.ToString('o');completed_at=$null}
  Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
  try{
    foreach($Name in @($RollbackState.deletable)){
      $Encoded=[Uri]::EscapeDataString($Name);$Response=& $RequestInvoker 'DELETE' "$Api/labels/$Encoded" $Headers $null
      if([int]$Response.status_code-ne204){throw "github_release_labels_rollback_delete_failed:$Name`:$([int]$Response.status_code)"}
      $Receipt.deleted_labels+=$Name;$Receipt.mutation_count=[int]$Receipt.mutation_count+1;$Receipt.mutation_performed=$true
      Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
    }
    $After=Get-LabelObservation -Definitions $Definitions -Headers $Headers -RequestInvoker $RequestInvoker
    $Remaining=@($After.state.labels|Where-Object{[string]$_.name-in@($ApplyReceipt.created_labels.name)-and[string]$_.state-cne'absent'})
    if($Remaining.Count-ne0){throw 'github_release_labels_rollback_postcondition_failed'}
    $Receipt.status='completed';$Receipt.after_state_sha256=[string]$After.state_sha256;$Receipt.completed_at=[DateTimeOffset]::Now.ToString('o')
    Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
    return [pscustomobject]$Receipt
  }catch{
    $Receipt.status='failed';$Receipt.failure_code=[string]$_.Exception.Message;$Receipt.completed_at=[DateTimeOffset]::Now.ToString('o')
    Write-AtomicReceipt -LiteralPath $ResolvedReceipt -Value $Receipt -AllowSameActionUpdate
    throw
  }
}

if($MyInvocation.InvocationName-ne'.'){
  $Definitions=New-DesiredLabelDefinitions;$Token=Get-GitHubToken -Required:($Mode-in@('Apply','Rollback'));$Headers=New-GitHubHeaders -Token $Token -Version $ApiVersion
  $Result=Invoke-ReleaseLabelOperation -Operation $Mode -ExpectedStateSha256 $ExpectedCurrentStateSha256 -Authorization $AuthorizationReference -Actor $ActorReference -OutputReceiptPath $ReceiptPath -InputApplyReceiptPath $ApplyReceiptPath -Definitions $Definitions -Version $ApiVersion -Headers $Headers -RequestInvoker ${function:Invoke-GitHubHttp}
  $Result|ConvertTo-Json -Depth 30
  if($Mode-ceq'Verify'-and-not[bool]$Result.compliant){exit 3}
}

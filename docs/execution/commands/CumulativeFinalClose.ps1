Set-StrictMode -Version Latest

$script:CumulativeFinalCloseTaskIds=@(
  'TASK-P12B-990','TASK-P12B-999','TASK-P12D-990','TASK-P12D-999',
  'TASK-P12-000','TASK-P12-001','TASK-P12-002','TASK-P12-089',
  'TASK-REL-C-000','TASK-REL-C-001','TASK-GONOW-089','TASK-GONOW-990','TASK-GONOW-999'
)

function Test-CumulativeFinalCloseTask {
  param([Parameter(Mandatory=$true)][string]$TaskIdValue)
  return $script:CumulativeFinalCloseTaskIds -contains $TaskIdValue
}

function Get-CumulativeAttestationRelativePath {
  param([Parameter(Mandatory=$true)][string]$TaskIdValue)
  $RelativeDirectory=$script:TaskEvidenceDirectory.Replace($script:RepositoryRoot+'\','').Replace('\','/')
  $Name=if($TaskIdValue-like'TASK-REL-C-*'-or$TaskIdValue-like'TASK-GONOW-*'){'automated-acceptance-attestation.json'}else{'cumulative-acceptance-attestation.json'}
  return "$RelativeDirectory/$Name"
}

function Get-CumulativeFinalCloseState {
  param([Parameter(Mandatory=$true)][string]$TaskIdValue)
  $ClosurePath=Join-Path $script:TaskEvidenceDirectory 'closure-evidence.json'
  $Closure=Read-JsonEvidenceOrNull $ClosurePath
  $Governance=Get-GovernanceProfileState
  $Head=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim()
  $Checks=[ordered]@{
    governance_profile_invalid=if([bool]$Governance.passed-and[string]$Governance.profile-ceq'personal_automated'){0}else{1}
    execution_mode_invalid=if($ExecutionMode-ceq'formal_adopted'){0}else{1}
    closure_evidence_missing=if($null-eq$Closure){1}else{0}
    closure_schema_invalid=0
    capability_set_invalid=0
    p12c_not_dormant=0
    single_agent_invalid=0
    candidate_invalid=0
    candidate_not_ancestor=0
    proof_missing_count=0
    proof_hash_mismatch_count=0
    proof_size_mismatch_count=0
    dependency_failure_count=0
    mandatory_gate_failures=0
    artifact_drift=0
    failed=0
    skipped=0
    xfailed=0
    flaky_rerun_passes=0
    redline_failures=0
    open_p0_p1=0
    security_failures=0
    model_api_call_count=0
    multi_agent_component_count=0
    production_write_count=0
    production_allocation=0
    force_update_count=0
    direct_main_push_count=0
  }
  if($null-ne$Closure){
    if([string]$Closure.schema_version-cne'1.0'-or[string]$Closure.task_id-cne$TaskIdValue-or[string]$Closure.profile-cne'personal_automated'-or[string]$Closure.overall_status-cne'passed'){$Checks.closure_schema_invalid=1}
    if((@($Closure.cumulative_capabilities)-join',')-cne'P12D,P12B,P12A'){$Checks.capability_set_invalid=1}
    if([string]$Closure.p12c_status-cne'dormant'){$Checks.p12c_not_dormant=1}
    if(-not[bool]$Closure.single_agent_architecture){$Checks.single_agent_invalid=1}
    $Candidate=[string]$Closure.candidate_head_oid
    if($Candidate-cnotmatch'^[0-9a-f]{40,64}$'){$Checks.candidate_invalid=1}else{& git -C $script:RepositoryRoot merge-base --is-ancestor $Candidate $Head 2>$null;if($LASTEXITCODE-ne0){$Checks.candidate_not_ancestor=1}}
    foreach($Proof in @($Closure.proofs)){
      $Relative=[string]$Proof.path;$Full=if([IO.Path]::IsPathRooted($Relative)){$Relative}else{Join-Path $script:RepositoryRoot $Relative}
      if(-not(Test-Path -LiteralPath $Full -PathType Leaf)){$Checks.proof_missing_count++;continue}
      if((Get-Sha256 -LiteralPath $Full)-cne[string]$Proof.sha256){$Checks.proof_hash_mismatch_count++}
      if((Get-Item -LiteralPath $Full).Length-ne[long]$Proof.size_bytes){$Checks.proof_size_mismatch_count++}
    }
    foreach($Name in @('mandatory_gate_failures','artifact_drift','failed','skipped','xfailed','flaky_rerun_passes','redline_failures','open_p0_p1','security_failures','model_api_call_count','multi_agent_component_count','production_write_count','production_allocation','force_update_count','direct_main_push_count')){
      if($Closure.checks.PSObject.Properties.Name-contains$Name){$Checks[$Name]=[int]$Closure.checks.$Name}else{$Checks[$Name]=1}
    }
  }
  foreach($Prerequisite in @($script:Task.prerequisite_task_ids)){
    $StatusPath=Join-Path $script:RepositoryRoot "docs/execution/status/$Prerequisite.json"
    if(-not(Test-Path -LiteralPath $StatusPath -PathType Leaf)){$Checks.dependency_failure_count++;continue}
    $Status=Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
    if([string]$Status.status-cne'accepted'-or[string]$Status.acceptance_method-cne'automated_attestation'-or[string]$Status.attestation_sha256-cnotmatch'^[a-f0-9]{64}$'){$Checks.dependency_failure_count++;continue}
    $Decision=[string]$Status.decision_reference;$DecisionPath=Join-Path $script:RepositoryRoot $Decision
    if([string]::IsNullOrWhiteSpace($Decision)-or-not(Test-Path -LiteralPath $DecisionPath -PathType Leaf)-or(Get-Sha256 -LiteralPath $DecisionPath)-cne[string]$Status.attestation_sha256){$Checks.dependency_failure_count++}
  }
  $FailureCount=0;foreach($Value in $Checks.Values){$FailureCount+=[int]$Value}
  return [ordered]@{passed=($FailureCount-eq0);failure_count=$FailureCount;checks=$Checks;closure=$Closure;closure_path=$ClosurePath;closure_sha256=if(Test-Path -LiteralPath $ClosurePath -PathType Leaf){Get-Sha256 -LiteralPath $ClosurePath}else{$ZeroHash};governance=$Governance;head_oid=$Head}
}

function Write-CumulativeFinalCloseAttestation {
  param([Parameter(Mandatory=$true)][string]$TaskIdValue)
  $State=Get-CumulativeFinalCloseState -TaskIdValue $TaskIdValue
  if(-not[bool]$State.passed){throw "cumulative final close preflight failed: $($State.checks|ConvertTo-Json -Compress)"}
  $RelativePath=Get-CumulativeAttestationRelativePath -TaskIdValue $TaskIdValue
  $Attestation=[ordered]@{
    schema_version='1.0';task_id=$TaskIdValue;phase=[string]$script:Task.phase;profile='personal_automated';acceptance_method='automated_attestation';overall_status='passed'
    cumulative_capabilities=@('P12D','P12B','P12A');p12c_status='dormant';single_agent_architecture=$true
    candidate_head_oid=[string]$State.closure.candidate_head_oid;candidate_tree_oid=[string]$State.closure.candidate_tree_oid;current_head_oid=[string]$State.head_oid;git_object_format=Get-GitObjectFormat
    governance_adoption_sha256=[string]$State.governance.adoption_sha256;agents_sha256=Get-Sha256 -LiteralPath (Join-Path $script:RepositoryRoot 'AGENTS.md');execplan_sha256=Get-Sha256 -LiteralPath (Join-Path $script:RepositoryRoot 'execplan.md');catalog_sha256=$script:CatalogSha256
    closure_evidence_sha256=[string]$State.closure_sha256;checks=$State.checks;proofs=@($State.closure.proofs);automated_gate_acceptance=$true;evidence_domains=@('Architecture','Data','Engineering','Product','Security');natural_person_signature_count=0
    production_observation_required=$false;production_facts_status='unknown';production_write_count=0;production_allocation=0;force_update_count=0;direct_main_push_count=0;recorded_at=[DateTimeOffset]::Now.ToString('o')
  }
  Write-AtomicJson -LiteralPath (Join-Path $script:RepositoryRoot $RelativePath) -Value $Attestation
  return [ordered]@{path=$RelativePath;sha256=Get-Sha256 -LiteralPath (Join-Path $script:RepositoryRoot $RelativePath)}
}

function Set-CumulativeAutomatedAcceptedStatus {
  param([Parameter(Mandatory=$true)][string]$EvidenceSha256,[Parameter(Mandatory=$true)][string]$AttestationRelativePath)
  $StatusPath=Join-Path $script:RepositoryRoot ([string]$script:Task.status_file)
  if(Test-Path -LiteralPath $StatusPath -PathType Leaf){
    $Record=Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
    if([string]$Record.status-ceq'accepted'){
      $PreviousHash=Get-Sha256 -LiteralPath $StatusPath;$AttestationPath=Join-Path $script:RepositoryRoot $AttestationRelativePath
      $Record.plan_version=[string](Get-GovernanceProfileState).plan_version;$Record.catalog_version=[string]$script:Catalog.CatalogVersion;$Record.catalog_sha256=$script:CatalogSha256;$Record.head_oid=(& git -C $script:RepositoryRoot rev-parse HEAD).Trim();$Record.updated_at=[DateTimeOffset]::Now.ToString('o');$Record.evidence_sha256=$EvidenceSha256;$Record.evidence_paths=[object[]]@($script:GatePath.Replace($script:RepositoryRoot+'\','').Replace('\','/'));$Record.decision_reference=$AttestationRelativePath;$Record.transition_reason='task-gate:cumulative-evidence-revalidation';$Record.governance_profile='personal_automated';$Record.acceptance_method='automated_attestation';$Record.attestation_sha256=Get-Sha256 -LiteralPath $AttestationPath
      if($Record.PSObject.Properties.Name-contains'revalidation_previous_record_sha256'){$Record.revalidation_previous_record_sha256=$PreviousHash}else{$Record|Add-Member -NotePropertyName revalidation_previous_record_sha256 -NotePropertyValue $PreviousHash}
      Write-AtomicJson -LiteralPath $StatusPath -Value $Record;return
    }
  }
  Set-ReadyForReviewStatus -EvidenceSha256 $EvidenceSha256
  Set-AutomatedAcceptedStatus -EvidenceSha256 $EvidenceSha256 -AttestationRelativePath $AttestationRelativePath
}

function Update-CumulativeFinalTaskBoard {
  $JsonPath=Join-Path $script:RepositoryRoot 'docs/execution/status/task-board.json';$MarkdownPath=Join-Path $script:RepositoryRoot 'docs/execution/status/task-board.md'
  if(-not(Test-Path -LiteralPath $JsonPath -PathType Leaf)){return}
  $Board=Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
  foreach($Id in $script:CumulativeFinalCloseTaskIds){$StatusPath=Join-Path $script:RepositoryRoot "docs/execution/status/$Id.json";if(-not(Test-Path -LiteralPath $StatusPath -PathType Leaf)){continue};$Status=Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop;$Row=@($Board.tasks|Where-Object{[string]$_.task_id-ceq$Id});if($Row.Count-eq1){$Row[0].status=[string]$Status.status;$Row[0].source_sha256=Get-Sha256 -LiteralPath $StatusPath}}
  Write-AtomicJson -LiteralPath $JsonPath -Value $Board
  if(Test-Path -LiteralPath $MarkdownPath -PathType Leaf){$Text=Get-Content -LiteralPath $MarkdownPath -Raw -Encoding UTF8;foreach($Id in $script:CumulativeFinalCloseTaskIds){$StatusPath=Join-Path $script:RepositoryRoot "docs/execution/status/$Id.json";if(Test-Path -LiteralPath $StatusPath -PathType Leaf){$Status=[string](Get-Content -LiteralPath $StatusPath -Raw -Encoding UTF8|ConvertFrom-Json).status;$Text=[regex]::Replace($Text,"(?m)^\| $([regex]::Escape($Id)) \| ([^|]+) \| [^|]+\|$","| $Id | `$1 | $Status |")}};[IO.File]::WriteAllText($MarkdownPath,$Text,[Text.UTF8Encoding]::new($false))}
}

[CmdletBinding()]
param([string]$CatalogPath = '',[string]$ExpectedSha256 = '')

$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($CatalogPath)){$CatalogPath=Join-Path (Split-Path -Parent $PSCommandPath) 'TaskGateCatalog.psd1'}
$CatalogPath=[IO.Path]::GetFullPath($CatalogPath)
function Get-Sha256([string]$Path){return(Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()}
function Get-TaskExtent([string]$Text,[string]$TaskId){$Tokens=$null;$Errors=$null;$Ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$Tokens,[ref]$Errors);if($Errors.Count-ne0){throw 'catalog_parse_failed'};$Root=$Ast.EndBlock.Statements[0].PipelineElements[0].Expression;$TasksPair=@($Root.KeyValuePairs|Where-Object{[string]$_.Item1.SafeGetValue()-ceq'Tasks'})[0];$Tasks=$TasksPair.Item2;if($Tasks-is[Management.Automation.Language.PipelineAst]){$Tasks=$Tasks.PipelineElements[0].Expression};$Pair=@($Tasks.KeyValuePairs|Where-Object{[string]$_.Item1.SafeGetValue()-ceq$TaskId})[0];if($null-eq$Pair){throw "catalog_task_missing:$TaskId"};return [ordered]@{start=$Pair.Item2.Extent.StartOffset;end=$Pair.Item2.Extent.EndOffset}}
function Update-Task([string]$Text,[string]$TaskId,[scriptblock]$Transform){$Extent=Get-TaskExtent $Text $TaskId;$TaskText=$Text.Substring($Extent.start,$Extent.end-$Extent.start);$Updated=&$Transform $TaskText;if($Updated-ceq$TaskText){throw "catalog_task_rewrite_noop:$TaskId"};return $Text.Substring(0,$Extent.start)+$Updated+$Text.Substring($Extent.end)}

if(-not(Test-Path -LiteralPath $CatalogPath -PathType Leaf)){throw 'catalog_missing'}
$OldHash=Get-Sha256 $CatalogPath;if(-not[string]::IsNullOrWhiteSpace($ExpectedSha256)-and$OldHash-cne$ExpectedSha256.ToLowerInvariant()){throw 'catalog_expected_sha256_mismatch'}
$Original=[IO.File]::ReadAllText($CatalogPath,[Text.UTF8Encoding]::new($true))
$AlreadyCurrent=$Original.Contains("'Push'=@{'allowed_bootstrap_stages'=@('locked_validated')")-and$Original.Contains("'phase_merge_mode_count=12'")-and$Original.Contains("'allowed_phase_merge_modes'=@('Archive','Cleanup','CloseVerify','IntegrationSmoke','Merge','MergePreflight','MergeTreeVerification','PostMergeEvidence','Push','Retrospective','RollbackVerify','Security')")-and$Original.Contains("docs/execution/evidence/phase-10/push.json")
if($AlreadyCurrent){[ordered]@{schema_version='1.0';old_sha256=$OldHash;new_sha256=$OldHash;phase_merge_mode_count=12;updated_task_ids=@();idempotent_noop=$true}|ConvertTo-Json -Compress;exit 0}

$PushContract="'Push'=@{'allowed_bootstrap_stages'=@('locked_validated');'failure_transition'='blocked';'handler'='Invoke-MergeModePush';'output_schema'='gate-results-v1.schema.json';'read_set_kind'='phase_merge_state_and_remote_ref_snapshot';'required_capabilities'=@('powershell-native','git');'required_task_fields'=@('task_id','allowed_phase_merge_modes');'success_predicates'=@('phase_remote_oid=candidate_head_oid','landing_remote_oid=phase_close_oid','force=false','unexpected_remote_ref_writes=0');'write_set_kind'='exact_remote_refs_and_post_close_local_receipt_only'}"
$Updated=$Original
$RollbackMarker="'RollbackVerify'=@{'allowed_bootstrap_stages'=@('locked_validated')";$Index=$Updated.IndexOf($RollbackMarker,[StringComparison]::Ordinal);if($Index-lt0){throw 'phase_merge_contract_insertion_marker_missing'};$Updated=$Updated.Substring(0,$Index)+$PushContract+';'+$Updated.Substring($Index)
if(([regex]::Matches($Updated,"'phase_merge_mode_count=11'")).Count-ne1){throw 'bootstrap_phase_merge_count_marker_invalid'};$Updated=$Updated.Replace("'phase_merge_mode_count=11'","'phase_merge_mode_count=12'")
$Updated=Update-Task $Updated 'TASK-P10-999' {
  param($Task)
  $Task=$Task.Replace("'allowed_phase_merge_modes'=@('Archive','Cleanup','CloseVerify','IntegrationSmoke','Merge','MergePreflight','MergeTreeVerification','PostMergeEvidence','Retrospective','RollbackVerify','Security')","'allowed_phase_merge_modes'=@('Archive','Cleanup','CloseVerify','IntegrationSmoke','Merge','MergePreflight','MergeTreeVerification','PostMergeEvidence','Push','Retrospective','RollbackVerify','Security')")
  $Task=$Task.Replace("'evidence_outputs'=@('docs/execution/evidence/phase-10/merge.json'","'evidence_outputs'=@('docs/execution/evidence/phase-10/merge.json','docs/execution/evidence/phase-10/push.json'")
  $Task=$Task.Replace("'file_allowlist'=@()","'file_allowlist'=@('docs/execution/evidence/phase-10/push.json')")
  $Task=$Task.Replace("'mutates_repo'=`$false","'mutates_repo'=`$true")
  $Task=$Task.Replace("'read_only_inputs'=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1')","'read_only_inputs'=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/commands/Invoke-PhaseMerge.ps1')")
  $Task=$Task.Replace("'external_actions'=@()","'external_actions'=@(@{'adapter_capability'='phase_merge_atomic_non_force_push';'identity'='repository_owner_automation';'target'='Elfsa-Miranda/GO_NOW:refs/heads/codex/phase-10-release-b-gates+refs/heads/codex/gonow-agent-landing';'arguments'=@('phase_oid=candidate_head_oid','landing_oid=phase_close_oid','atomic=true','force=false');'idempotency_or_cas'='before_remote_ref_snapshot+candidate_head_oid+phase_close_oid';'receipt'='docs/execution/evidence/phase-10/push.json';'rollback'='no automatic ref rewrite; use a separately gated non-force revert change'})")
  return $Task
}
$Updated=Update-Task $Updated 'TASK-P10-011' {
  param($Task)
  $Task=$Task.Replace("'docs/execution/evidence/phase-10/phase-close-v01.json','docs/execution/evidence/phase-10/P10-999/gate-results.json'","'docs/execution/evidence/phase-10/phase-close-v01.json','docs/execution/evidence/phase-10/push.json','docs/execution/evidence/phase-10/P10-999/gate-results.json'")
  return $Task
}
$Updated=[regex]::Replace($Updated,"'SupersedesCatalogSha256'='[0-9a-f]{64}'","'SupersedesCatalogSha256'='$OldHash'",1)
$Tokens=$null;$Errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($Updated,[ref]$Tokens,[ref]$Errors);if($Errors.Count-ne0){throw 'updated_catalog_parse_failed'}
foreach($Marker in @("'handler'='Invoke-MergeModePush'","'phase_merge_mode_count=12'","docs/execution/evidence/phase-10/push.json","'force=false'")){if(-not$Updated.Contains($Marker)){throw "updated_catalog_marker_missing:$Marker"}}
$Temp=$CatalogPath+'.push-repair.tmp';try{[IO.File]::WriteAllText($Temp,$Updated,[Text.UTF8Encoding]::new($true));if((Get-Sha256 $CatalogPath)-cne$OldHash){throw 'catalog_cas_conflict'};Move-Item -LiteralPath $Temp -Destination $CatalogPath -Force}finally{if(Test-Path -LiteralPath $Temp){Remove-Item -LiteralPath $Temp -Force}}
[ordered]@{schema_version='1.0';old_sha256=$OldHash;new_sha256=Get-Sha256 $CatalogPath;phase_merge_mode_count=12;updated_task_ids=@('TASK-P10-999','TASK-P10-011');idempotent_noop=$false}|ConvertTo-Json -Compress

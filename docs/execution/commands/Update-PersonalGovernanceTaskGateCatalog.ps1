[CmdletBinding()]
param([string]$CatalogPath = '')

$ErrorActionPreference = 'Stop'
$ScriptDirectory = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path $ScriptDirectory 'TaskGateCatalog.psd1' }
$CatalogPath = [IO.Path]::GetFullPath($CatalogPath)

function Get-Sha256([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Replace-Segment([string]$Text,[string]$Start,[string]$End,[string]$Value) {
  $StartIndex=$Text.IndexOf($Start,[StringComparison]::Ordinal);if($StartIndex-lt0){throw "catalog_start_marker_missing:$Start"}
  $ValueIndex=$StartIndex+$Start.Length;$EndIndex=$Text.IndexOf($End,$ValueIndex,[StringComparison]::Ordinal);if($EndIndex-lt0){throw "catalog_end_marker_missing:$End"}
  return $Text.Substring(0,$ValueIndex)+$Value+$Text.Substring($EndIndex)
}
function Get-ParsedCatalog([string]$Text,[string]$Source) {
  $Tokens=$null;$Errors=$null;$Ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$Tokens,[ref]$Errors)
  if($Errors.Count-ne0){throw "catalog_parse_failed:$Source"};return $Ast
}
function Get-TaskPair([object]$Ast,[string]$TaskId) {
  $Root=$Ast.EndBlock.Statements[0].PipelineElements[0].Expression;$TasksPair=@($Root.KeyValuePairs|Where-Object{[string]$_.Item1.SafeGetValue()-ceq'Tasks'})[0];$TasksExpression=$TasksPair.Item2
  if($TasksExpression-is[Management.Automation.Language.PipelineAst]){$TasksExpression=$TasksExpression.PipelineElements[0].Expression}
  $Pair=@($TasksExpression.KeyValuePairs|Where-Object{[string]$_.Item1.SafeGetValue()-ceq$TaskId})[0];if($null-eq$Pair){throw "catalog_task_missing:$TaskId"};return $Pair
}
function Update-Task([string]$Catalog,[string]$TaskId,[object[]]$Operations) {
  $Ast=Get-ParsedCatalog $Catalog "before_$TaskId";$Pair=Get-TaskPair $Ast $TaskId;$Start=$Pair.Item2.Extent.StartOffset;$End=$Pair.Item2.Extent.EndOffset;$TaskText=$Catalog.Substring($Start,$End-$Start)
  foreach($Operation in $Operations){$TaskText=Replace-Segment $TaskText ([string]$Operation.start) ([string]$Operation.end) ([string]$Operation.value)}
  return $Catalog.Substring(0,$Start)+$TaskText+$Catalog.Substring($End)
}
function Convert-StringArray([object[]]$Values) {
  $Quoted=@($Values|ForEach-Object{"'"+([string]$_).Replace("'","''")+"'"});return '@('+($Quoted-join',')+')'
}

if(-not(Test-Path -LiteralPath $CatalogPath -PathType Leaf)){throw 'catalog_missing'}
$Original=[IO.File]::ReadAllText($CatalogPath,[Text.UTF8Encoding]::new($false));$OriginalHash=Get-Sha256 $CatalogPath;$Current=[scriptblock]::Create($Original).InvokeReturnAsIs()
$P10010Change='run 10-20 repository-owner-only canary journeys for 30-60 minutes under a fixed budget; cover success/cancel/disconnect recovery/reject/adopt/CAS conflict; return allocation to zero; bind the exact P10-009 certification; require zero redlines'
$RelC000Change='bind accepted Release B and its automated attestation; compare phase11, phase12, and none with preserved denominators/confidence/risks; select exactly one path; record zero human signatures plus a candidate-bound automated attestation; update the governance ref by expected-SHA CAS; prove specialist branches are absent'
$RelC001Change='bind the accepted outer selection and exactly one capability integration; create or update the landing-to-main Release C PR; require all checks; perform an exact two-parent non-force merge; prove merged-tree equality; record zero review requests and an automated attestation'
$ExpectedP10010=@($Current.Tasks['TASK-P10-010'].work_contract.required_changes).Count-eq1-and[string]$Current.Tasks['TASK-P10-010'].work_contract.required_changes[0]-ceq$P10010Change
$ExpectedRelC000=@($Current.Tasks['TASK-REL-C-000'].work_contract.required_changes).Count-eq1-and[string]$Current.Tasks['TASK-REL-C-000'].work_contract.required_changes[0]-ceq$RelC000Change
$ExpectedRelC001=@($Current.Tasks['TASK-REL-C-001'].work_contract.required_changes).Count-eq1-and[string]$Current.Tasks['TASK-REL-C-001'].work_contract.required_changes[0]-ceq$RelC001Change-and'docs/execution/evidence/releases/P10-011/automated-acceptance-attestation.json'-in@($Current.Tasks['TASK-REL-C-001'].read_only_inputs)
$P11990Personal=-not[bool]$Current.Tasks['TASK-P11-990'].approval_policy.independent_from_implementer-and'docs/execution/evidence/phase-11/P11-990/rollback-drill.local.json'-in@($Current.Tasks['TASK-P11-990'].read_only_inputs)-and'docs/execution/evidence/phase-11/P11-990/personal-acceptance-attestation.json'-in@($Current.Tasks['TASK-P11-990'].evidence_outputs)
$P11999Personal=-not[bool]$Current.Tasks['TASK-P11-999'].approval_policy.independent_from_implementer-and'docs/execution/evidence/phase-11/P11-990/personal-acceptance-attestation.json'-in@($Current.Tasks['TASK-P11-999'].read_only_inputs)
$BootstrapContractCurrent=@($Current.TaskGateModeContracts['BootstrapSelfTest'].success_predicates)-contains'work_contract_count=127'
if([string]$Current.CatalogVersion-ceq'2.2.0'-and$ExpectedP10010-and$ExpectedRelC000-and$ExpectedRelC001-and$P11990Personal-and$P11999Personal-and$BootstrapContractCurrent-and@($Current.Tasks['TASK-P10-990'].allowed_taskgate_modes)-contains'AutomatedAcceptancePreflight'){
  [ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=$OriginalHash;catalog_version=$Current.CatalogVersion;taskgate_mode_count=$Current.TaskGateModeContracts.Keys.Count;phase_merge_mode_count=$Current.PhaseMergeModeContracts.Keys.Count;task_count=$Current.Tasks.Keys.Count;updated_task_ids=@();idempotent_noop=$true}|ConvertTo-Json -Compress;exit 0
}

$PersonalApproval="@{'independent_from_implementer'=`$false;'minimum_approvals'=0;'required_roles'=@();'validity_rule'='personal_automated_attestation_bound_to_exact_candidate'}"
$Updated=$Original
$Updated=Update-Task $Updated 'TASK-P10-010' @(
  @{start="'approval_policy'=";end=";'bootstrap_materialization_for'=";value=$PersonalApproval},
  @{start="'directory_allowlist'=";end=";'evidence_outputs'=";value="@(@{'path'='docs/execution/evidence/phase-10/P10-010/';'name_regex'='^(?:artifact-hashes|automated-acceptance-attestation|blocker|commands|gate-results|owner-canary-report|owner-canary-request|release-b-gate-report|rollback-report|security-report)\.json$|^release-b-gate-dossier\.md$'})"},
  @{start="'evidence_outputs'=";end=";'evidence_schemas'=";value="@('docs/execution/evidence/phase-10/P10-010/owner-canary-request.json','docs/execution/evidence/phase-10/P10-010/owner-canary-report.json','docs/execution/evidence/phase-10/P10-010/release-b-gate-dossier.md','docs/execution/evidence/phase-10/P10-010/release-b-gate-report.json','docs/execution/evidence/phase-10/P10-010/security-report.json','docs/execution/evidence/phase-10/P10-010/rollback-report.json','docs/execution/evidence/phase-10/P10-010/automated-acceptance-attestation.json','docs/execution/evidence/phase-10/P10-010/artifact-hashes.json','docs/execution/evidence/phase-10/P10-010/commands.json','docs/execution/evidence/phase-10/P10-010/gate-results.json','docs/execution/status/TASK-P10-010.json')"},
  @{start="'read_only_inputs'=";end=";'required_bootstrap_stage'=";value="@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/status/TASK-P10-009.json','docs/execution/evidence/phase-10/P10-009/personal-release-certification.json')"},
  @{start="'forbidden_changes'=";end=";'postconditions'=";value="@('non-owner canary allocation','unbounded spend','production-wide activation','fabricated observation or approval')"},
  @{start="'required_changes'=";end="};'work_preflight_commands'=";value="@('$P10010Change')"}
)
$Updated=Update-Task $Updated 'TASK-P10-990' @(
  @{start="'allowed_taskgate_modes'=";end=";'applicable_ct_ids'=";value="@('AcceptancePreflight','ApprovalValidation','AutomatedAcceptancePreflight','BuildAcceptance','Documentation','Evidence','Regression','RollbackDrill','RollbackVerify','Security','Verify')"},
  @{start="'approval_policy'=";end=";'bootstrap_materialization_for'=";value=$PersonalApproval},
  @{start="'directory_allowlist'=";end=";'evidence_outputs'=";value="@(@{'path'='docs/execution/evidence/phase-10/P10-990/';'name_regex'='^(?:approval-pending|approval-validation|artifact-hashes|blocker|commands|gate-results|gate-summary|local-verification|personal-acceptance-attestation|regression-summary|rollback-drill|rollback-report|security-report)\.json$|^(?:direct-pytest|flutter-test|rollback-tests)\.xml$'})"},
  @{start="'evidence_outputs'=";end=";'evidence_schemas'=";value="@('docs/execution/evidence/phase-10/acceptance.md','docs/execution/evidence/phase-10/P10-990/personal-acceptance-attestation.json','docs/execution/evidence/phase-10/P10-990/artifact-hashes.json','docs/execution/evidence/phase-10/P10-990/commands.json','docs/execution/evidence/phase-10/P10-990/gate-results.json','docs/execution/status/TASK-P10-990.json')"},
  @{start="'read_only_inputs'=";end=";'required_bootstrap_stage'=";value="@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/status/TASK-P10-009.json','docs/execution/status/TASK-P10-010.json','docs/execution/evidence/phase-10/P10-009/personal-release-certification.json','docs/execution/evidence/phase-10/P10-010/automated-acceptance-attestation.json')"}
)
$P10011Action="@(@{'adapter_capability'='github_authorized_external_action';'identity'='repository_owner_automation';'target'='Elfsa-Miranda/GO_NOW:pull-request';'arguments'=@('head=codex/gonow-agent-landing','base=main','auto_merge=true','merge_method=merge','force=false','review_requests=0');'idempotency_or_cas'='head_oid+base_oid+phase_acceptance_attestation_sha256+merge_authorization_sha256';'receipt'='docs/execution/evidence/releases/P10-011/pr-observation.json';'rollback'='non_force_revert_pull_request_for_exact_merge_commit'})"
$Updated=Update-Task $Updated 'TASK-P10-011' @(
  @{start="'approval_policy'=";end=";'bootstrap_materialization_for'=";value=$PersonalApproval},
  @{start="'directory_allowlist'=";end=";'evidence_outputs'=";value="@(@{'path'='docs/execution/evidence/releases/P10-011/';'name_regex'='^(?:artifact-hashes|automated-acceptance-attestation|blocker|commands|gate-results|pr-observation|pr-request|rollback-report|security-report)\.json$'})"},
  @{start="'evidence_outputs'=";end=";'evidence_schemas'=";value="@('docs/execution/evidence/releases/B.json','docs/execution/evidence/releases/P10-011/pr-request.json','docs/execution/evidence/releases/P10-011/pr-observation.json','docs/execution/evidence/releases/P10-011/security-report.json','docs/execution/evidence/releases/P10-011/rollback-report.json','docs/execution/evidence/releases/P10-011/automated-acceptance-attestation.json','docs/execution/evidence/releases/P10-011/artifact-hashes.json','docs/execution/evidence/releases/P10-011/commands.json','docs/execution/evidence/releases/P10-011/gate-results.json','docs/execution/status/TASK-P10-011.json')"},
  @{start="'read_only_inputs'=";end=";'required_bootstrap_stage'=";value="@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/status/TASK-P10-999.json','docs/execution/evidence/phase-10/merge.json','docs/execution/evidence/phase-10/phase-close-v01.json','docs/execution/evidence/phase-10/P10-999/gate-results.json','docs/execution/evidence/phase-10/P10-999/merge-authorization.json')"},
  @{start="'external_actions'=";end=";'forbidden_changes'=";value=$P10011Action},
  @{start="'forbidden_changes'=";end=";'postconditions'=";value="@('force push','squash or rebase merge','merge before required checks','fabricated reviewer')"},
  @{start="'required_changes'=";end="};'work_preflight_commands'=";value="@('bind Phase 10 automated acceptance and merge authorization; push phase and landing branches without force; create or update landing-to-main PR; require checks; merge with method merge; prove tree equality; record zero review requests')"}
)
$Updated=Update-Task $Updated 'TASK-REL-C-000' @(
  @{start="'approval_policy'=";end=";'bootstrap_materialization_for'=";value=$PersonalApproval},
  @{start="'directory_allowlist'=";end=";'evidence_outputs'=";value="@(@{'path'='docs/execution/evidence/releases/REL-C-000/';'name_regex'='^(?:artifact-hashes|automated-acceptance-attestation|blocker|commands|gate-results|path-selection|phase12-trigger-evidence|rag-trigger-evidence|rollback-report|security-report|selection-request)\.json$'})"},
  @{start="'evidence_outputs'=";end=";'evidence_schemas'=";value="@('docs/execution/evidence/releases/REL-C-000/selection-request.json','docs/execution/evidence/releases/REL-C-000/path-selection.json','docs/execution/evidence/releases/REL-C-000/automated-acceptance-attestation.json','docs/execution/evidence/releases/REL-C-000/security-report.json','docs/execution/evidence/releases/REL-C-000/rollback-report.json','docs/execution/evidence/releases/REL-C-000/artifact-hashes.json','docs/execution/evidence/releases/REL-C-000/commands.json','docs/execution/evidence/releases/REL-C-000/gate-results.json','docs/execution/status/TASK-REL-C-000.json')"},
  @{start="'read_only_inputs'=";end=";'required_bootstrap_stage'=";value="@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/status/TASK-P10-011.json','docs/execution/evidence/releases/B.json','docs/execution/evidence/releases/P10-011/automated-acceptance-attestation.json','docs/execution/evidence/phase-09/P09-001/dependency-audit-report.json')"},
  @{start="'required_changes'=";end="};'work_preflight_commands'=";value="@('$RelC000Change')"}
)
$RelC001Read="@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','refs/heads/codex/gonow-agent-landing','refs/remotes/origin/codex/gonow-agent-landing','refs/remotes/origin/main','refs/heads/codex/release-c-governance','docs/execution/evidence/releases/B.json','docs/execution/evidence/releases/P10-011/automated-acceptance-attestation.json','docs/execution/evidence/releases/REL-C-000/path-selection.json','docs/execution/evidence/releases/REL-C-000/rag-trigger-evidence.json','docs/execution/evidence/releases/REL-C-000/phase12-trigger-evidence.json','docs/execution/evidence/releases/REL-C-000/gate-results.json','docs/execution/evidence/releases/REL-C-000/artifact-hashes.json','docs/execution/evidence/releases/REL-C-000/automated-acceptance-attestation.json','docs/execution/status/TASK-REL-C-000.json','docs/execution/status/TASK-P11-999.json','docs/execution/evidence/phase-11/merge.json','docs/execution/evidence/phase-11/phase-close-v01.json','docs/execution/evidence/phase-11/artifact-manifest-v01.json','docs/execution/evidence/phase-11/P11-999/gate-results.json','docs/execution/evidence/phase-11/P11-999/merge-authorization.json','docs/execution/evidence/phase-11/P11-990/personal-acceptance-attestation.json','docs/execution/evidence/phase-11/P11-990/gate-results.json','docs/execution/evidence/phase-11/P11-990/rollback-drill.local.json','docs/execution/evidence/phase-12/P12-002/selection.json','docs/execution/status/TASK-P12-089.json','docs/execution/evidence/phase-12/P12-089/implementation-close-registration.json')"
$RelC001Action="@(@{'adapter_capability'='github_authorized_external_action';'identity'='repository_owner_automation';'target'='Elfsa-Miranda/GO_NOW:pull-request';'arguments'=@('head=codex/gonow-agent-landing','base=main','auto_merge=true','merge_method=merge','force=false','review_requests=0');'idempotency_or_cas'='head_oid+base_oid+outer_path_receipt_sha256+selected_merge_sha';'receipt'='docs/execution/evidence/releases/REL-C-001/pr-observation.json';'rollback'='non_force_revert_pull_request_for_exact_merge_commit'})"
$Updated=Update-Task $Updated 'TASK-REL-C-001' @(
  @{start="'approval_policy'=";end=";'required_bootstrap_stage'=";value=$PersonalApproval},
  @{start="'directory_allowlist'=";end=";'external_root_allowlist'=";value="@(@{'path'='docs/execution/evidence/releases/REL-C-001/';'name_regex'='^(?:artifact-hashes|automated-acceptance-attestation|blocker|commands|gate-results|pr-observation|pr-request|rollback-report|security-report)\.json$'})"},
  @{start="'read_only_inputs'=";end=";'evidence_outputs'=";value=$RelC001Read},
  @{start="'evidence_outputs'=";end=";'status_file'=";value="@('docs/execution/evidence/releases/C.json','docs/execution/evidence/releases/REL-C-001/pr-request.json','docs/execution/evidence/releases/REL-C-001/pr-observation.json','docs/execution/evidence/releases/REL-C-001/security-report.json','docs/execution/evidence/releases/REL-C-001/rollback-report.json','docs/execution/evidence/releases/REL-C-001/automated-acceptance-attestation.json','docs/execution/evidence/releases/REL-C-001/artifact-hashes.json','docs/execution/evidence/releases/REL-C-001/commands.json','docs/execution/evidence/releases/REL-C-001/gate-results.json','docs/execution/status/TASK-REL-C-001.json')"},
  @{start="'external_actions'=";end=";'read_only_queries'=";value=$RelC001Action},
  @{start="'required_changes'=";end=";'forbidden_changes'=";value="@('$RelC001Change')"},
  @{start="'forbidden_changes'=";end=";'postconditions'=";value="@('second Release C capability','runtime code','force push','squash or rebase merge','merge before required checks','fabricated reviewer')"}
)

$P11990Read=@($Current.Tasks['TASK-P11-990'].read_only_inputs|ForEach-Object{if([string]$_-ceq'docs/execution/evidence/phase-11/P11-990/approval-receipts.json'){'docs/execution/evidence/phase-11/P11-990/approval-pending.json'}elseif([string]$_-ceq'docs/execution/evidence/phase-11/P11-990/rollback-drill.json'){'docs/execution/evidence/phase-11/P11-990/rollback-drill.local.json'}else{[string]$_}})
$P11990Outputs=@($Current.Tasks['TASK-P11-990'].evidence_outputs|ForEach-Object{if([string]$_-ceq'docs/execution/evidence/phase-11/P11-990/approval-receipts.json'){'docs/execution/evidence/phase-11/P11-990/approval-pending.json'}elseif([string]$_-ceq'docs/execution/evidence/phase-11/P11-990/rollback-drill.json'){'docs/execution/evidence/phase-11/P11-990/rollback-drill.local.json'}else{[string]$_}})
if('docs/execution/evidence/phase-11/P11-990/personal-acceptance-attestation.json'-notin$P11990Outputs){$P11990Outputs+='docs/execution/evidence/phase-11/P11-990/personal-acceptance-attestation.json'}
$Updated=Update-Task $Updated 'TASK-P11-990' @(
  @{start="'approval_policy'=";end=";'bootstrap_materialization_for'=";value=$PersonalApproval},
  @{start="'read_only_inputs'=";end=";'required_bootstrap_stage'=";value=(Convert-StringArray $P11990Read)},
  @{start="'evidence_outputs'=";end=";'evidence_schemas'=";value=(Convert-StringArray $P11990Outputs)},
  @{start="'required_changes'=";end="};'work_preflight_commands'=";value="@('aggregate Phase 11 source, ACL, deletion, evaluation, rollout, and mandatory regression evidence; preserve local_isolated rollback scope; write a candidate-bound personal automated attestation with zero human signatures')"}
)
$P11999Read=@($Current.Tasks['TASK-P11-999'].read_only_inputs|ForEach-Object{if([string]$_-ceq'docs/execution/evidence/phase-11/P11-990/approval-receipts.json'){'docs/execution/evidence/phase-11/P11-990/personal-acceptance-attestation.json'}elseif([string]$_-ceq'docs/execution/evidence/phase-11/P11-990/rollback-drill.json'){'docs/execution/evidence/phase-11/P11-990/rollback-drill.local.json'}elseif([string]$_-ceq'docs/execution/evidence/boot/BOOT-004.json'){'docs/execution/evidence/governance/personal-automation-adoption-v1.json'}else{[string]$_}})
$Updated=Update-Task $Updated 'TASK-P11-999' @(
  @{start="'approval_policy'=";end=";'bootstrap_materialization_for'=";value=$PersonalApproval},
  @{start="'read_only_inputs'=";end=";'required_bootstrap_stage'=";value=(Convert-StringArray $P11999Read)},
  @{start="'required_changes'=";end="};'work_preflight_commands'=";value="@('freeze the exact P11 automated acceptance candidate and approval-only tip; perform a no-ff landing merge; prove parent and tree equivalence; run exact-merge smoke; archive STAR, local-isolated rollback, merge authorization, manifest, and close evidence without touching main, Phase 12, remote, or production')"}
)

$Updated=$Updated.Replace("'CatalogVersion'='2.1.0'","'CatalogVersion'='2.2.0'").Replace("'catalog_version'='2.1.0'","'catalog_version'='2.2.0'")
$Updated=$Updated.Replace("'work_contract_count=125'","'work_contract_count=127'")
$ExpectedSupersedes=if([string]$Current.CatalogVersion-ceq'2.1.0'){$OriginalHash}else{[string]$Current.SupersedesCatalogSha256}
if([string]$Current.CatalogVersion-ceq'2.1.0'){$Updated=[regex]::Replace($Updated,"'SupersedesCatalogSha256'='[0-9a-f]{64}'","'SupersedesCatalogSha256'='$OriginalHash'",1)}
$null=Get-ParsedCatalog $Updated 'after_rewrite';$New=[scriptblock]::Create($Updated).InvokeReturnAsIs()
$SemanticValid=[string]$New.CatalogVersion-ceq'2.2.0'-and$New.TaskGateModeContracts.Keys.Count-eq24-and$New.PhaseMergeModeContracts.Keys.Count-eq11-and$New.Tasks.Keys.Count-eq153-and@($New.TaskGateModeContracts['BootstrapSelfTest'].success_predicates)-contains'work_contract_count=127'-and@($New.Tasks.Values|Where-Object{@($_.work_contract.required_changes).Count-gt0}).Count-eq127-and@($New.Tasks['TASK-P10-990'].allowed_taskgate_modes)-contains'AutomatedAcceptancePreflight'-and[string]$New.Tasks['TASK-P10-010'].work_contract.required_changes[0]-ceq$P10010Change-and[string]$New.Tasks['TASK-REL-C-000'].work_contract.required_changes[0]-ceq$RelC000Change-and[string]$New.Tasks['TASK-REL-C-001'].work_contract.required_changes[0]-ceq$RelC001Change-and-not[bool]$New.Tasks['TASK-P11-990'].approval_policy.independent_from_implementer-and-not[bool]$New.Tasks['TASK-P11-999'].approval_policy.independent_from_implementer-and[string]$New.SupersedesCatalogSha256-ceq$ExpectedSupersedes
if(-not$SemanticValid){throw 'catalog_semantic_validation_failed'}
$Temporary=$CatalogPath+'.personal.tmp';try{[IO.File]::WriteAllText($Temporary,$Updated,[Text.UTF8Encoding]::new($true));if((Get-Sha256 $CatalogPath)-cne$OriginalHash){throw 'catalog_cas_conflict'};Move-Item -LiteralPath $Temporary -Destination $CatalogPath -Force}finally{if(Test-Path -LiteralPath $Temporary){Remove-Item -LiteralPath $Temporary -Force}}
[ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=Get-Sha256 $CatalogPath;catalog_version=$New.CatalogVersion;taskgate_mode_count=$New.TaskGateModeContracts.Keys.Count;phase_merge_mode_count=$New.PhaseMergeModeContracts.Keys.Count;task_count=$New.Tasks.Keys.Count;updated_task_ids=@('TASK-P10-010','TASK-P10-990','TASK-P10-011','TASK-P11-990','TASK-P11-999','TASK-REL-C-000','TASK-REL-C-001');idempotent_noop=$false}|ConvertTo-Json -Compress

[CmdletBinding()]
param([string]$CatalogPath = '')

$ErrorActionPreference = 'Stop'
$ScriptDirectory = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path $ScriptDirectory 'TaskGateCatalog.psd1' }
$CatalogPath = [IO.Path]::GetFullPath($CatalogPath)

function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Copy-Value([object]$Value) {
  if ($Value -is [Collections.IDictionary]) {
    $Result = [ordered]@{}
    foreach ($Key in $Value.Keys) { $Result[[string]$Key] = Copy-Value $Value[$Key] }
    return $Result
  }
  if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) { return ,@($Value | ForEach-Object { Copy-Value $_ }) }
  return $Value
}
function ConvertTo-Psd1Literal([object]$Value) {
  if ($null -eq $Value) { return '$null' }
  if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
  if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double]) {
    return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
  }
  if ($Value -is [Collections.IDictionary]) {
    $Pairs = foreach ($Key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
      (ConvertTo-Psd1Literal $Key) + '=' + (ConvertTo-Psd1Literal $Value[$Key])
    }
    return '@{' + ($Pairs -join ';') + '}'
  }
  if ($Value -is [Collections.IEnumerable]) { return '@(' + (@($Value | ForEach-Object { ConvertTo-Psd1Literal $_ }) -join ',') + ')' }
  throw "unsupported_catalog_value:$($Value.GetType().FullName)"
}
function Add-Unique([object[]]$Values,[object[]]$Additional) { @($Values + $Additional | Select-Object -Unique) }
function New-ReadQuery([string]$TaskId,[string[]]$Arguments,[string]$Suffix) {
  [ordered]@{arguments=$Arguments;command_id="$TaskId-read-$Suffix";executable_capability='git';expected_exit_codes=@(0);redaction_profile='no-sensitive-output';stderr_regex='';stdout_regex='';timeout_seconds=3600}
}
function New-FinalTask([object]$Template,[string]$TaskId,[string]$Phase,[string[]]$Prerequisites,[string]$Folder,[string[]]$Files,[string]$RequiredChange,[string]$Assertion) {
  $Task=Copy-Value $Template
  $Task.task_id=$TaskId;$Task.phase=$Phase;$Task.catalog_version='3.0.0';$Task.owner_alias='Release Engineering';$Task.owner_roles=@('Engineering');$Task.reviewer_roles=@('Data','Engineering','Product','Security')
  $Task.allowed_taskgate_modes=@('AutomatedAcceptancePreflight','Evidence','Preflight','RollbackVerify','Security','Verify','WorkPreflight','WorksetVerify');$Task.allowed_phase_merge_modes=@();$Task.applicable_ct_ids=@('CT-001','CT-002','CT-003','CT-004','CT-005','CT-006','CT-007','CT-008','CT-009','CT-010','CT-011','CT-012','CT-013','CT-014','CT-015')
  $Task.approval_policy=[ordered]@{independent_from_implementer=$false;minimum_approvals=0;required_roles=@();validity_rule='personal_automated_attestation_bound_to_exact_cumulative_candidate'}
  $Task.prerequisite_task_ids=$Prerequisites;$Task.file_allowlist=$Files;$Task.directory_allowlist=@([ordered]@{path="$Folder/";name_regex='^(?:artifact-hashes|automated-acceptance-attestation|closure-evidence|commands|gate-results|release-notes|rollback|security|task-board|knowledge-transfer|artifact-manifest|regression-summary|focused-smoke|merge-request)\.(?:json|md)$'})
  $Task.read_only_inputs=@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/commands/CumulativeFinalClose.ps1','docs/execution/evidence/governance/personal-automation-adoption-v3.json')+@($Prerequisites|ForEach-Object{"docs/execution/status/$_.json"})
  $Task.evidence_outputs=@("$Folder/closure-evidence.json","$Folder/automated-acceptance-attestation.json","$Folder/artifact-hashes.json","$Folder/commands.json","$Folder/gate-results.json","docs/execution/status/$TaskId.json")
  $Task.status_file="docs/execution/status/$TaskId.json";$Task.status_schema='task-status-v1';$Task.phase_base_source_ref='phase-base-source:cumulative-final-close';$Task.phase_runtime_manifest_path='';$Task.required_bootstrap_stage='native';$Task.bootstrap_materialization_for=@();$Task.external_root_allowlist=@();$Task.harness_controls_owned=@();$Task.harness_controls_extended=@();$Task.security_check_ids=@('SEC-AUDIT','SEC-PII','SEC-RESTORE','SEC-SECRET','SEC-SQL');$Task.dependency_change=$false;$Task.catalog_revision=$false;$Task.timeout_seconds=7200;$Task.mutates_repo=$true
  $Task.expected_assertions=@($Assertion);$Task.rollback_commands=@(New-ReadQuery $TaskId @('diff','--check') 'rollback-01');$Task.verify_commands=@();$Task.work_preflight_commands=@();$Task.workset_verify_commands=@()
  $Task.work_contract=[ordered]@{external_actions=@();forbidden_changes=@('Multi-Agent implementation','production deployment or write','force push','direct push main','history rewrite','evidence deletion');postconditions=@($Assertion);read_only_queries=@((New-ReadQuery $TaskId @('status','--porcelain=v1') '01'),(New-ReadQuery $TaskId @('diff','--check') '02'));repo_patch_targets=$Files;required_changes=@($RequiredChange)}
  return $Task
}

if (-not(Test-Path -LiteralPath $CatalogPath -PathType Leaf)){throw 'catalog_missing'}
$Original=[IO.File]::ReadAllText($CatalogPath,[Text.UTF8Encoding]::new($false));$OriginalHash=Get-Sha256 $CatalogPath
$Current=[scriptblock]::Create($Original).InvokeReturnAsIs()
if([string]$Current.CatalogVersion-ceq'3.0.0'-and@($Current.Tasks.Keys).Count-eq180-and(@($Current.Tasks['TASK-REL-C-001'].prerequisite_task_ids)-join',')-ceq'TASK-REL-C-000'-and'docs/execution/evidence/phase-12/P12-002/cumulative-acceptance-attestation.json'-in@($Current.Tasks['TASK-P12-002'].evidence_outputs)){[ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=$OriginalHash;catalog_version='3.0.0';task_count=180;work_contract_count=154;idempotent_noop=$true}|ConvertTo-Json -Compress;exit 0}
if(([string]$Current.CatalogVersion-cne'2.5.2'-and[string]$Current.CatalogVersion-cne'3.0.0')-or@($Current.Tasks.Keys).Count-notin@(177,180)){throw 'cumulative_catalog_precondition_failed'}

$New=Copy-Value $Current
$New.CatalogVersion='3.0.0';if([string]$Current.CatalogVersion-cne'3.0.0'){$New.SupersedesCatalogSha256=$OriginalHash}
foreach($Task in $New.Tasks.Values){$Task.catalog_version='3.0.0'}
$Self=@($New.TaskGateModeContracts.BootstrapSelfTest.success_predicates|ForEach-Object{([string]$_).Replace('catalog_entries=177','catalog_entries=180').Replace('unique_status_paths=177','unique_status_paths=180').Replace('work_contract_count=151','work_contract_count=154')});$New.TaskGateModeContracts.BootstrapSelfTest.success_predicates=$Self

$GovernanceInput='docs/execution/evidence/governance/personal-automation-adoption-v3.json'
$HelperInput='docs/execution/commands/CumulativeFinalClose.ps1'
$ExistingIds=@('TASK-P12B-990','TASK-P12B-999','TASK-P12D-990','TASK-P12D-999','TASK-P12-000','TASK-P12-001','TASK-P12-002','TASK-P12-089','TASK-REL-C-000','TASK-REL-C-001')
foreach($Id in $ExistingIds){
  $Task=$New.Tasks[$Id]
  $Task.allowed_taskgate_modes=Add-Unique @($Task.allowed_taskgate_modes) @('AutomatedAcceptancePreflight')
  $Task.approval_policy=[ordered]@{independent_from_implementer=$false;minimum_approvals=0;required_roles=@();validity_rule='personal_automated_attestation_bound_to_exact_cumulative_candidate'}
  $Task.read_only_inputs=Add-Unique @($Task.read_only_inputs) @($GovernanceInput,$HelperInput)
  $AttestationOutput=$(if($Id-ceq'TASK-P12-089'){'docs/execution/evidence/phase-12/P12-089/cumulative-acceptance-attestation.json'}elseif($Id-cmatch'^TASK-P12-(000|001|002)$'){"docs/execution/evidence/phase-12/$($Id.Substring(5))/cumulative-acceptance-attestation.json"}elseif($Id-like'TASK-REL-C-*'){"docs/execution/evidence/releases/$($Id.Substring(5))/automated-acceptance-attestation.json"}else{"docs/execution/evidence/phase-$($Id.Substring(6,3).ToLower())/$($Id.Substring(5))/cumulative-acceptance-attestation.json"})
  $Task.evidence_outputs=Add-Unique @(@($Task.evidence_outputs)|Where-Object{$_-cnotmatch'/phase-12-/'} ) @($AttestationOutput)
}
$New.Tasks['TASK-P12B-999'].prerequisite_task_ids=@('TASK-P12B-990')
$New.Tasks['TASK-P12D-999'].prerequisite_task_ids=@('TASK-P12D-990')
$New.Tasks['TASK-P12A-999'].prerequisite_task_ids=@('TASK-P12A-990')
$New.Tasks['TASK-P12-000'].prerequisite_task_ids=@('TASK-P12A-999','TASK-P12B-999','TASK-P12D-999')
$New.Tasks['TASK-P12-001'].prerequisite_task_ids=@('TASK-P12-000')
$New.Tasks['TASK-P12-002'].prerequisite_task_ids=@('TASK-P12-001')
$New.Tasks['TASK-P12-089'].prerequisite_task_ids=@('TASK-P12-002','TASK-P12A-999','TASK-P12B-999','TASK-P12D-999')
$New.Tasks['TASK-REL-C-000'].prerequisite_task_ids=@('TASK-P12-089')
$New.Tasks['TASK-REL-C-001'].prerequisite_task_ids=@('TASK-REL-C-000')

$Template=$New.Tasks['TASK-REL-C-001']
$New.Tasks['TASK-GONOW-089']=New-FinalTask $Template 'TASK-GONOW-089' 'Project Final Close' @('TASK-REL-C-001') 'docs/execution/evidence/project-final/GONOW-089' @('README.md','docs/architecture/final-release.md','docs/runbooks/final-release.md','docs/execution/status/task-board.json','docs/execution/status/task-board.md') 'archive BOOT through P12 and Release B/C with cumulative capabilities migrations permissions rollback tests risks and production unknowns' 'cumulative_capability_count=3; p12c_dormant=true; broken_link_count=0; production_write_count=0'
$New.Tasks['TASK-GONOW-990']=New-FinalTask $Template 'TASK-GONOW-990' 'Project Final Close' @('TASK-GONOW-089') 'docs/execution/evidence/project-final/GONOW-990' @() 'freeze the exact project candidate and run exactly one complete regression covering all mandatory layers without model or production calls' 'complete_regression_count=1; failed=0; skipped=0; xfailed=0; redline_failure_count=0; production_write_count=0'
$New.Tasks['TASK-GONOW-999']=New-FinalTask $Template 'TASK-GONOW-999' 'Project Final Close' @('TASK-GONOW-990') 'docs/execution/evidence/project-final/GONOW-999' @() 'bind the exact accepted candidate for landing merge focused smoke non-force push and one protected landing-to-main merge PR' 'candidate_tree_equal=true; focused_smoke_failed=0; force_update_count=0; direct_main_push_count=0; production_write_count=0'
$New.Tasks['TASK-GONOW-999'].work_contract.external_actions=@([ordered]@{adapter_capability='github_authorized_external_action';identity='repository_owner_automation';target='Elfsa-Miranda/GO_NOW:pull-request';arguments=@('head=codex/gonow-agent-landing','base=main','draft=false','merge_method=merge','force=false');idempotency_or_cas='head_oid+base_oid+candidate_tree_oid';receipt='external-git-common-dir:gonow-final-release-receipt.json';rollback='protected pull-request revert of exact merge commit'})

$Serialized=ConvertTo-Psd1Literal $New
$Temporary=$CatalogPath+'.cumulative-final.tmp'
try{[IO.File]::WriteAllText($Temporary,$Serialized,[Text.UTF8Encoding]::new($true));if((Get-Sha256 $CatalogPath)-cne$OriginalHash){throw 'catalog_cas_conflict'};$Parsed=[scriptblock]::Create([IO.File]::ReadAllText($Temporary)).InvokeReturnAsIs();$WorkCount=@($Parsed.Tasks.Values|Where-Object{@($_.work_contract.required_changes).Count-gt0}).Count;if([string]$Parsed.CatalogVersion-cne'3.0.0'-or@($Parsed.Tasks.Keys).Count-ne180-or$WorkCount-ne154){throw "catalog_semantic_validation_failed:tasks=$(@($Parsed.Tasks.Keys).Count):work=$WorkCount"};Move-Item -LiteralPath $Temporary -Destination $CatalogPath -Force}finally{if(Test-Path -LiteralPath $Temporary){Remove-Item -LiteralPath $Temporary -Force}}
[ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=Get-Sha256 $CatalogPath;catalog_version='3.0.0';task_count=180;work_contract_count=154;updated_task_ids=$ExistingIds+@('TASK-GONOW-089','TASK-GONOW-990','TASK-GONOW-999');idempotent_noop=$false}|ConvertTo-Json -Compress

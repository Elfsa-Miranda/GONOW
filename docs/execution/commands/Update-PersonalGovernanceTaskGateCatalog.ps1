[CmdletBinding()]
param([string]$CatalogPath = '')

$ErrorActionPreference = 'Stop'
$ScriptDirectory = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($CatalogPath)) { $CatalogPath = Join-Path $ScriptDirectory 'TaskGateCatalog.psd1' }
$CatalogPath = [IO.Path]::GetFullPath($CatalogPath)

function Get-Sha256([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Replace-Segment([string]$Text,[string]$Start,[string]$End,[string]$Value) {
  $StartIndex = $Text.IndexOf($Start,[StringComparison]::Ordinal)
  if ($StartIndex -lt 0) { throw "catalog_start_marker_missing:$Start" }
  $ValueIndex = $StartIndex + $Start.Length
  $EndIndex = $Text.IndexOf($End,$ValueIndex,[StringComparison]::Ordinal)
  if ($EndIndex -lt 0) { throw "catalog_end_marker_missing:$End" }
  return $Text.Substring(0,$ValueIndex) + $Value + $Text.Substring($EndIndex)
}
function Get-ParsedCatalog([string]$Text,[string]$Source) {
  $Tokens=$null;$Errors=$null
  $Ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$Tokens,[ref]$Errors)
  if ($Errors.Count -ne 0) { throw "catalog_parse_failed:$Source" }
  return $Ast
}
function Get-TaskPair([object]$Ast,[string]$TaskId) {
  $Root=$Ast.EndBlock.Statements[0].PipelineElements[0].Expression
  $TasksPair=@($Root.KeyValuePairs|Where-Object{[string]$_.Item1.SafeGetValue()-ceq'Tasks'})[0]
  $TasksExpression=$TasksPair.Item2
  if($TasksExpression-is[Management.Automation.Language.PipelineAst]){$TasksExpression=$TasksExpression.PipelineElements[0].Expression}
  $Pair=@($TasksExpression.KeyValuePairs|Where-Object{[string]$_.Item1.SafeGetValue()-ceq$TaskId})[0]
  if($null-eq$Pair){throw "catalog_task_missing:$TaskId"}
  return $Pair
}

$P10010FrozenArguments=@('candidate=bound_from_p10_009','endpoint_ref=GONOW_AGENT_API_URL','owner_identity_ref=GONOW_OWNER_CANARY_IDENTITY_REF','credential_provider=GONOW_OWNER_CANARY_CREDENTIAL_PROVIDER','budget_cap_ref=GONOW_RELEASE_B_BUDGET_CAP_REF','adapter_path=docs/execution/commands/Invoke-PersonalOwnerCanary.ps1','adapter_digest=sha256','journey_adapter=GONOW_RELEASE_B_JOURNEY_ADAPTER','flag_adapter=GONOW_RELEASE_B_FLAG_ADAPTER','audit_adapter=GONOW_RELEASE_B_AUDIT_ADAPTER','kill_switch_adapter=GONOW_RELEASE_B_KILL_SWITCH_ADAPTER','old_path_adapter=GONOW_RELEASE_B_OLD_PATH_ADAPTER','trace_adapter=GONOW_RELEASE_B_TRACE_ADAPTER','provider_usage_adapter=GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER','owner_identity_only=true','allocation_baseline=0','journeys=10..20','minutes=30..60','action_lifecycle=baseline_zero>owner_enable>journeys>kill>old_path>final_zero','generation_fencing=continuous','receipt_ledger=owner-canary-receipts.jsonl','final_allocation=0')
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw 'catalog_missing' }
$Original=[IO.File]::ReadAllText($CatalogPath,[Text.UTF8Encoding]::new($false))
$OriginalHash=Get-Sha256 $CatalogPath
$Ast=Get-ParsedCatalog $Original 'before_rewrite'
$CurrentCatalog=[scriptblock]::Create($Original).InvokeReturnAsIs()
if (
  [string]$CurrentCatalog.CatalogVersion -ceq '2.2.0' -and
  $CurrentCatalog.TaskGateModeContracts.ContainsKey('AutomatedAcceptancePreflight') -and
  @($CurrentCatalog.Tasks['TASK-P10-010'].allowed_taskgate_modes) -contains 'AutomatedAcceptancePreflight' -and
  @($CurrentCatalog.Tasks['TASK-P10-010'].evidence_outputs | Where-Object { $_ -cmatch '(?:owner-canary-report\.json|owner-canary-receipts\.jsonl|automated-acceptance-attestation\.json)$' }).Count -eq 3 -and
  @($CurrentCatalog.Tasks['TASK-P10-010'].file_allowlist).Count -eq 6 -and
  'docs/execution/evidence/phase-10/P10-010/owner-canary-input-inventory.json' -in @($CurrentCatalog.Tasks['TASK-P10-010'].evidence_outputs) -and
  'docs/execution/commands/Invoke-PersonalOwnerCanary.ps1' -in @($CurrentCatalog.Tasks['TASK-P10-010'].read_only_inputs) -and
  [string]$CurrentCatalog.Tasks['TASK-P10-010'].work_contract.external_actions[0].receipt -ceq 'docs/execution/evidence/phase-10/P10-010/owner-canary-receipts.jsonl' -and
  (@($CurrentCatalog.Tasks['TASK-P10-010'].work_contract.external_actions[0].arguments) -join "`n") -ceq ($P10010FrozenArguments -join "`n")
) {
  [ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=$OriginalHash;catalog_version=$CurrentCatalog.CatalogVersion;taskgate_mode_count=$CurrentCatalog.TaskGateModeContracts.Keys.Count;phase_merge_mode_count=$CurrentCatalog.PhaseMergeModeContracts.Keys.Count;task_count=$CurrentCatalog.Tasks.Keys.Count;updated_task_ids=@();idempotent_noop=$true}|ConvertTo-Json -Compress
  exit 0
}
$Updated=$Original
if ([string]$CurrentCatalog.CatalogVersion -ceq '2.0.0') {
  $Pair=Get-TaskPair $Ast 'TASK-P10-009'
  $Start=$Pair.Item2.Extent.StartOffset;$End=$Pair.Item2.Extent.EndOffset
  $TaskText=$Original.Substring($Start,$End-$Start)
$TaskText=Replace-Segment $TaskText "'allowed_taskgate_modes'=" ";'applicable_ct_ids'=" "@('AutomatedAcceptancePreflight','Evidence','Preflight','RollbackVerify','Security','Verify','WorkPreflight','WorksetVerify')"
$TaskText=Replace-Segment $TaskText "'directory_allowlist'=" ";'evidence_outputs'=" "@(@{'name_regex'='^[a-z0-9_.-]+(?:\\.json|\\.jsonl|\\.xml|\\.md|\\.txt|\\.yaml)$';'path'='agent-service/tests/certification/'},@{'name_regex'='^[a-z0-9_.-]+(?:\\.dart|\\.json|\\.md)$';'path'='test/release_certification/'},@{'name_regex'='^(?:artifact-hashes|blocker|c1-correctness|c2-security-performance-cost|c3-quality-slices|c4-recovery-time-soak|c5-rollback-operations|certification-manifest|commands|fault-injection-report|gate-results|performance-cost-report|personal-release-certification|quality-slice-report|regression-report|residual-risk|rollback-operations-report|rollback-report|security-matrix|security-report|soak-report|state-space-report|virtual-time-report|work-preflight)\\.json$';'path'='docs/execution/evidence/phase-10/P10-009/'})"
$TaskText=Replace-Segment $TaskText "'evidence_outputs'=" ";'evidence_schemas'=" "@('docs/execution/evidence/phase-10/P10-009/certification-manifest.json','docs/execution/evidence/phase-10/P10-009/regression-report.json','docs/execution/evidence/phase-10/P10-009/state-space-report.json','docs/execution/evidence/phase-10/P10-009/security-matrix.json','docs/execution/evidence/phase-10/P10-009/fault-injection-report.json','docs/execution/evidence/phase-10/P10-009/quality-slice-report.json','docs/execution/evidence/phase-10/P10-009/performance-cost-report.json','docs/execution/evidence/phase-10/P10-009/virtual-time-report.json','docs/execution/evidence/phase-10/P10-009/soak-report.json','docs/execution/evidence/phase-10/P10-009/rollback-operations-report.json','docs/execution/evidence/phase-10/P10-009/residual-risk.json','docs/execution/evidence/phase-10/P10-009/personal-release-certification.json','docs/execution/evidence/phase-10/P10-009/security-report.json','docs/execution/evidence/phase-10/P10-009/rollback-report.json','docs/execution/evidence/phase-10/P10-009/artifact-hashes.json','docs/execution/evidence/phase-10/P10-009/commands.json','docs/execution/evidence/phase-10/P10-009/gate-results.json','docs/execution/status/TASK-P10-009.json')"
$CardBinding='primary assertion and DoD bound to execplan card sha256=4591aea0c06179556a20803ebfd19bc79601e1e33481936df7fca14642d1a91a'
$TaskText=Replace-Segment $TaskText "'expected_assertions'=" ";'external_root_allowlist'=" "@('$CardBinding')"
$TaskText=Replace-Segment $TaskText "'file_allowlist'=" ";'harness_controls_extended'=" "@('docs/execution/commands/Invoke-PersonalReleaseCertification.ps1','docs/execution/commands/PersonalReleaseCertification.psd1','docs/execution/commands/tests/Invoke-PersonalReleaseCertification.Tests.ps1','docs/execution/schemas/personal-release-certification-v1.schema.json')"
$TaskText=Replace-Segment $TaskText "'read_only_inputs'=" ";'required_bootstrap_stage'=" "@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/evidence/governance/personal-automation-adoption-v1.json','docs/execution/status/TASK-P10-007.json','docs/execution/status/TASK-P10-008.json','docs/execution/evidence/phase-10/P10-007/rollout-plan-report.json','docs/execution/evidence/phase-10/P10-008/cost-report.json')"
$TaskText=Replace-Segment $TaskText "'security_check_ids'=" ";'status_file'=" "@('SEC-AUDIT','SEC-PII','SEC-SECRET','SEC-SQL')"
$TaskText=Replace-Segment $TaskText "'repo_patch_targets'=" ";'required_changes'=" "@('docs/execution/commands/Invoke-PersonalReleaseCertification.ps1','docs/execution/commands/PersonalReleaseCertification.psd1','docs/execution/commands/tests/Invoke-PersonalReleaseCertification.Tests.ps1','docs/execution/schemas/personal-release-certification-v1.schema.json','agent-service/tests/certification/','test/release_certification/')"
$RequiredChange='freeze manifest → C1 correctness → C2 security/performance/cost → C3 quality → C4 recovery/virtual-time/4h-soak → C5 rollback/operations → aggregate hashes/residual risk'
$TaskText=Replace-Segment $TaskText "'required_changes'=" "};'work_preflight_commands'=" "@('$RequiredChange')"
$TaskText=Replace-Segment $TaskText "'postconditions'=" ";'read_only_queries'=" "@('$CardBinding')"
  $Updated=$Original.Substring(0,$Start)+$TaskText+$Original.Substring($End)
  $Mode="'AutomatedAcceptancePreflight'=@{'allowed_bootstrap_stages'=@('native','locked_validated');'failure_transition'='blocked';'handler'='Invoke-ModeAutomatedAcceptancePreflight';'output_schema'='gate-results-v1.schema.json';'read_set_kind'='catalog_task_and_hashed_inputs';'required_capabilities'=@('powershell-native','git');'required_task_fields'=@('task_id','status_file','evidence_outputs');'success_predicates'=@('personal_profile=true','candidate_drift=0','mandatory_gate_failures=0','skipped=0','xfailed=0','flaky_rerun_passes=0','redline_failures=0','automated_attestation_valid=true');'write_set_kind'='task_evidence_and_status_only'};"
  $ModeRoot="'TaskGateModeContracts'=@{"
  if(([regex]::Matches($Updated,[regex]::Escape($ModeRoot))).Count-ne1){throw 'catalog_mode_root_count_invalid'}
  $Updated=$Updated.Replace($ModeRoot,$ModeRoot+$Mode)
} elseif ([string]$CurrentCatalog.CatalogVersion -notin @('2.1.0','2.2.0')) {
  throw "unsupported_catalog_version:$($CurrentCatalog.CatalogVersion)"
}

$IntermediateAst=Get-ParsedCatalog $Updated 'before_p10_010_rewrite'
$P10010Pair=Get-TaskPair $IntermediateAst 'TASK-P10-010'
$P10010Start=$P10010Pair.Item2.Extent.StartOffset;$P10010End=$P10010Pair.Item2.Extent.EndOffset
$P10010Text=$Updated.Substring($P10010Start,$P10010End-$P10010Start)
$P10010Text=Replace-Segment $P10010Text "'allowed_taskgate_modes'=" ";'applicable_ct_ids'=" "@('AutomatedAcceptancePreflight','Evidence','Preflight','RollbackVerify','Security','Verify','WorkPreflight','WorksetVerify')"
$P10010Text=Replace-Segment $P10010Text "'directory_allowlist'=" ";'evidence_outputs'=" "@(@{'name_regex'='^(?:BLK-P10-010-[a-z0-9-]+\.md|artifact-hashes\.json|automated-acceptance-attestation\.json|blocker\.json|commands\.json|gate-results\.json|owner-canary-input-inventory\.json|owner-canary-receipts\.jsonl|owner-canary-report\.json|personal-release-certification\.json|release-b-gate-dossier\.md|rollback-report\.json|security-report\.json|work-preflight\.json)$';'path'='docs/execution/evidence/phase-10/P10-010/'})"
$P10010Outputs="@('docs/execution/evidence/phase-10/P10-010/release-b-gate-dossier.md','docs/execution/evidence/phase-10/P10-010/owner-canary-input-inventory.json','docs/execution/evidence/phase-10/P10-010/owner-canary-report.json','docs/execution/evidence/phase-10/P10-010/owner-canary-receipts.jsonl','docs/execution/evidence/phase-10/P10-010/personal-release-certification.json','docs/execution/evidence/phase-10/P10-010/automated-acceptance-attestation.json','docs/execution/evidence/phase-10/P10-010/security-report.json','docs/execution/evidence/phase-10/P10-010/rollback-report.json','docs/execution/evidence/phase-10/P10-010/artifact-hashes.json','docs/execution/evidence/phase-10/P10-010/commands.json','docs/execution/evidence/phase-10/P10-010/gate-results.json','docs/execution/status/TASK-P10-010.json')"
$P10010Text=Replace-Segment $P10010Text "'evidence_outputs'=" ";'evidence_schemas'=" $P10010Outputs
$P10010CardBinding='primary assertion and DoD bound to execplan card sha256=7121c71a672fd053bad6794cdbe230bc7233f56c08d1f689a9fb136eff8c853a'
$P10010Text=Replace-Segment $P10010Text "'expected_assertions'=" ";'external_root_allowlist'=" "@('$P10010CardBinding')"
$P10010Text=Replace-Segment $P10010Text "'file_allowlist'=" ";'harness_controls_extended'=" "@('docs/execution/evidence/phase-10/P10-010/release-b-gate-dossier.md','docs/execution/evidence/phase-10/P10-010/owner-canary-input-inventory.json','docs/execution/evidence/phase-10/P10-010/owner-canary-report.json','docs/execution/evidence/phase-10/P10-010/owner-canary-receipts.jsonl','docs/execution/evidence/phase-10/P10-010/personal-release-certification.json','docs/execution/evidence/phase-10/P10-010/automated-acceptance-attestation.json')"
$P10010Inputs="@('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/commands/Invoke-PersonalOwnerCanary.ps1','docs/execution/evidence/governance/personal-automation-adoption-v1.json','docs/execution/status/TASK-P10-009.json','docs/execution/evidence/phase-10/P10-009/certification-manifest.json','docs/execution/evidence/phase-10/P10-009/personal-release-certification.json','docs/execution/evidence/phase-10/P10-009/artifact-hashes.json')"
$P10010Text=Replace-Segment $P10010Text "'read_only_inputs'=" ";'required_bootstrap_stage'=" $P10010Inputs
$P10010Text=Replace-Segment $P10010Text "'repo_patch_targets'=" ";'required_changes'=" "@('docs/execution/evidence/phase-10/P10-010/release-b-gate-dossier.md','docs/execution/evidence/phase-10/P10-010/owner-canary-input-inventory.json','docs/execution/evidence/phase-10/P10-010/owner-canary-report.json','docs/execution/evidence/phase-10/P10-010/owner-canary-receipts.jsonl','docs/execution/evidence/phase-10/P10-010/personal-release-certification.json','docs/execution/evidence/phase-10/P10-010/automated-acceptance-attestation.json')"
$P10010RequiredChange='verify C1–C5 hashes → prove same candidate/build → allocation 0 baseline → enable owner identity only → execute 10–20 scripted journeys for 30–60min → monitor receipts/redlines → allocation 0 → aggregate → auto accept or rollback'
$P10010Text=Replace-Segment $P10010Text "'required_changes'=" "};'work_preflight_commands'=" "@('$P10010RequiredChange')"
$P10010ExternalAction="@(@{'adapter_capability'='p10_owner_canary_adapter';'identity'='scoped_owner_canary_identity_ref';'target'='gonow.agent.itinerary_planning.release_b';'arguments'=@('candidate=bound_from_p10_009','endpoint_ref=GONOW_AGENT_API_URL','owner_identity_ref=GONOW_OWNER_CANARY_IDENTITY_REF','credential_provider=GONOW_OWNER_CANARY_CREDENTIAL_PROVIDER','budget_cap_ref=GONOW_RELEASE_B_BUDGET_CAP_REF','adapter_path=docs/execution/commands/Invoke-PersonalOwnerCanary.ps1','adapter_digest=sha256','journey_adapter=GONOW_RELEASE_B_JOURNEY_ADAPTER','flag_adapter=GONOW_RELEASE_B_FLAG_ADAPTER','audit_adapter=GONOW_RELEASE_B_AUDIT_ADAPTER','kill_switch_adapter=GONOW_RELEASE_B_KILL_SWITCH_ADAPTER','old_path_adapter=GONOW_RELEASE_B_OLD_PATH_ADAPTER','trace_adapter=GONOW_RELEASE_B_TRACE_ADAPTER','provider_usage_adapter=GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER','owner_identity_only=true','allocation_baseline=0','journeys=10..20','minutes=30..60','action_lifecycle=baseline_zero>owner_enable>journeys>kill>old_path>final_zero','generation_fencing=continuous','receipt_ledger=owner-canary-receipts.jsonl','final_allocation=0');'idempotency_or_cas'='candidate_oid+owner_identity_ref+expected_generation+attempt_id';'receipt'='docs/execution/evidence/phase-10/P10-010/owner-canary-receipts.jsonl';'rollback'='allocation_zero_then_kill_switch_and_old_path'})"
$P10010Text=Replace-Segment $P10010Text "'external_actions'=" ";'forbidden_changes'=" $P10010ExternalAction
$P10010Text=Replace-Segment $P10010Text "'forbidden_changes'=" ";'postconditions'=" "@('non-owner cohort or wildcard identity','arbitrary SQL or migration','candidate/build/Behavior drift','raw secret or PII evidence','skip C1-C5 or any P0/P1 waiver')"
$P10010Text=Replace-Segment $P10010Text "'postconditions'=" ";'read_only_queries'=" "@('$P10010CardBinding')"
$Updated=$Updated.Substring(0,$P10010Start)+$P10010Text+$Updated.Substring($P10010End)
$Updated=$Updated.Replace("'CatalogVersion'='2.0.0'","'CatalogVersion'='2.2.0'")
$Updated=$Updated.Replace("'CatalogVersion'='2.1.0'","'CatalogVersion'='2.2.0'")
$Updated=$Updated.Replace("'catalog_version'='2.0.0'","'catalog_version'='2.2.0'")
$Updated=$Updated.Replace("'catalog_version'='2.1.0'","'catalog_version'='2.2.0'")
$Updated=[regex]::Replace($Updated,"'SupersedesCatalogSha256'=(?:'[^']*'|`$null)","'SupersedesCatalogSha256'='$OriginalHash'",1)
$Updated=$Updated.Replace("'taskgate_mode_count=23'","'taskgate_mode_count=24'")
$null=Get-ParsedCatalog $Updated 'after_rewrite'
$NewCatalog=[scriptblock]::Create($Updated).InvokeReturnAsIs()
if(
  $NewCatalog.CatalogVersion-cne'2.2.0' -or
  $NewCatalog.TaskGateModeContracts.Keys.Count-ne24 -or
  $NewCatalog.Tasks.Keys.Count-ne153 -or
  @($NewCatalog.Tasks['TASK-P10-009'].allowed_taskgate_modes)-notcontains'AutomatedAcceptancePreflight' -or
  @($NewCatalog.Tasks['TASK-P10-010'].allowed_taskgate_modes)-notcontains'AutomatedAcceptancePreflight' -or
  'docs/execution/commands/Invoke-PersonalOwnerCanary.ps1' -notin @($NewCatalog.Tasks['TASK-P10-010'].read_only_inputs) -or
  'docs/execution/evidence/phase-10/P10-010/owner-canary-receipts.jsonl' -notin @($NewCatalog.Tasks['TASK-P10-010'].evidence_outputs) -or
  'docs/execution/evidence/phase-10/P10-010/owner-canary-input-inventory.json' -notin @($NewCatalog.Tasks['TASK-P10-010'].evidence_outputs) -or
  @($NewCatalog.Tasks['TASK-P10-010'].file_allowlist).Count -ne 6 -or
  [string]$NewCatalog.Tasks['TASK-P10-010'].work_contract.external_actions[0].receipt -cne 'docs/execution/evidence/phase-10/P10-010/owner-canary-receipts.jsonl' -or
  (@($NewCatalog.Tasks['TASK-P10-010'].work_contract.external_actions[0].arguments) -join "`n") -cne ($P10010FrozenArguments -join "`n") -or
  [string]$NewCatalog.Tasks['TASK-P10-010'].work_contract.required_changes[0]-cne$P10010RequiredChange -or
  [string]$NewCatalog.SupersedesCatalogSha256-cne$OriginalHash
){throw 'catalog_semantic_validation_failed'}
$Temporary=$CatalogPath+'.personal.tmp'
try {
  # Windows PowerShell 5.1 treats a BOM-less file as the active ANSI code page
  # when ParseFile is used. The Catalog contains Unicode task contracts, so its
  # canonical on-disk form keeps the UTF-8 BOM.
  [IO.File]::WriteAllText($Temporary,$Updated,[Text.UTF8Encoding]::new($true))
  if((Get-Sha256 $CatalogPath)-cne$OriginalHash){throw 'catalog_cas_conflict'}
  Move-Item -LiteralPath $Temporary -Destination $CatalogPath -Force
} finally { if(Test-Path -LiteralPath $Temporary){Remove-Item -LiteralPath $Temporary -Force} }
[ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=Get-Sha256 $CatalogPath;catalog_version=$NewCatalog.CatalogVersion;taskgate_mode_count=$NewCatalog.TaskGateModeContracts.Keys.Count;phase_merge_mode_count=$NewCatalog.PhaseMergeModeContracts.Keys.Count;task_count=$NewCatalog.Tasks.Keys.Count;updated_task_ids=@('TASK-P10-010')}|ConvertTo-Json -Compress

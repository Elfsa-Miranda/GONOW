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
  if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
    return ,@($Value | ForEach-Object { Copy-Value $_ })
  }
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
function Get-ParsedCatalog([string]$Text, [string]$Source) {
  $Tokens = $null; $Errors = $null
  $Ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$Tokens, [ref]$Errors)
  if (@($Errors).Count -ne 0) { throw "catalog_parse_failed:$Source" }
  return $Ast
}
function Get-TaskPair([object]$Ast, [string]$TaskId) {
  $Root = $Ast.EndBlock.Statements[0].PipelineElements[0].Expression
  $TasksPair = @($Root.KeyValuePairs | Where-Object { [string]$_.Item1.SafeGetValue() -ceq 'Tasks' })[0]
  $TasksExpression = $TasksPair.Item2
  if ($TasksExpression -is [Management.Automation.Language.PipelineAst]) { $TasksExpression = $TasksExpression.PipelineElements[0].Expression }
  return @($TasksExpression.KeyValuePairs | Where-Object { [string]$_.Item1.SafeGetValue() -ceq $TaskId })[0]
}
function Replace-Task([string]$Text, [string]$TaskId, [object]$Task) {
  $Pair = Get-TaskPair (Get-ParsedCatalog $Text "replace_$TaskId") $TaskId
  if ($null -eq $Pair) { throw "catalog_task_missing:$TaskId" }
  return $Text.Substring(0, $Pair.Item2.Extent.StartOffset) + (ConvertTo-Psd1Literal $Task) + $Text.Substring($Pair.Item2.Extent.EndOffset)
}
function New-ReadQuery([string]$TaskId, [string[]]$Arguments, [string]$Suffix) {
  [ordered]@{arguments=$Arguments;command_id="$TaskId-read-$Suffix";executable_capability='git';expected_exit_codes=@(0);redaction_profile='no-sensitive-output';stderr_regex='';stdout_regex='';timeout_seconds=3600}
}
function Add-StandardEvidence([string]$TaskId, [string]$Folder, [string[]]$Specific) {
  @($Specific + @("$Folder/artifact-hashes.json","$Folder/commands.json","$Folder/gate-results.json","docs/execution/status/$TaskId.json") | Select-Object -Unique)
}
function New-P12ATask([object]$Template,[string]$TaskId,[string[]]$Prerequisites,[string[]]$Files,[string[]]$Directories,[string[]]$Evidence,[string]$RequiredChange,[string[]]$Forbidden,[string]$Assertion) {
  $Task = Copy-Value $Template
  $Token = $TaskId.Replace('TASK-', '')
  $Folder = "docs/execution/evidence/phase-12a/$Token"
  $Task.allowed_taskgate_modes = @('Evidence','Preflight','RollbackVerify','Security','Verify','WorkPreflight','WorksetVerify')
  $Task.allowed_phase_merge_modes = @()
  if ($TaskId -ceq 'TASK-P12A-990') { $Task.allowed_taskgate_modes += @('AcceptancePreflight','Regression','RollbackDrill') }
  if ($TaskId -ceq 'TASK-P12A-999') { $Task.allowed_phase_merge_modes = @('IntegrationSmoke','Merge','MergePreflight','MergeTreeVerification','PostMergeEvidence','RollbackVerify','Security') }
  $Task.applicable_ct_ids = @('CT-009','CT-015')
  $Task.approval_policy = [ordered]@{independent_from_implementer=$false;minimum_approvals=0;required_roles=@();validity_rule='local_provisional_exact_candidate_attestation'}
  $Task.bootstrap_materialization_for = @()
  $Task.catalog_revision = $false
  $Task.catalog_version = '2.5.0'
  $Task.dependency_change = $false
  $Task.directory_allowlist = $Directories
  $Task.evidence_outputs = Add-StandardEvidence $TaskId $Folder $Evidence
  $Task.expected_assertions = @($Assertion)
  $Task.external_root_allowlist = @()
  $Task.file_allowlist = $Files
  $Task.harness_controls_extended = @()
  $Task.harness_controls_owned = @()
  $Task.mutates_repo = $true
  $Task.owner_alias = 'Memory'
  $Task.owner_roles = @('Data','Engineering')
  $Task.phase = 'Phase 12A'
  $Task.phase_base_source_ref = 'phase-base-source:12A-local-provisional'
  $Task.phase_runtime_manifest_path = 'docs/execution/evidence/phase-12a/phase-runtime-manifest.json'
  $Task.prerequisite_task_ids = $Prerequisites
  $Task.read_only_inputs = @('AGENTS.md','execplan.md','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/evidence/phase-12a/P12A-000/selection-record.json','docs/execution/evidence/phase-12a/P12A-000/proposed-execution-contract.json','docs/execution/evidence/phase-12a/P12A-000/metrics-preregistration.json') + @($Prerequisites | ForEach-Object { "docs/execution/status/$_.json" })
  $Task.required_bootstrap_stage = 'native'
  $Task.reviewer_roles = @('Data','Privacy','Product','Security')
  $Task.rollback_commands = @(New-ReadQuery $TaskId @('diff','--check') 'rollback-01')
  $Task.security_check_ids = @('SEC-AUDIT','SEC-PII','SEC-SECRET','SEC-SQL')
  $Task.status_file = "docs/execution/status/$TaskId.json"
  $Task.status_schema = 'task-status-v1'
  $Task.task_id = $TaskId
  $Task.timeout_seconds = 3600
  $Task.verify_commands = @(); $Task.work_preflight_commands = @(); $Task.workset_verify_commands = @()
  $Task.work_contract = [ordered]@{external_actions=@();forbidden_changes=$Forbidden;postconditions=@($Assertion);read_only_queries=@((New-ReadQuery $TaskId @('status','--porcelain=v1') '01'),(New-ReadQuery $TaskId @('diff','--check') '02'));repo_patch_targets=$Files;required_changes=@($RequiredChange)}
  return $Task
}

if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw 'catalog_missing' }
$Original = [IO.File]::ReadAllText($CatalogPath, [Text.UTF8Encoding]::new($false)); $OriginalHash = Get-Sha256 $CatalogPath
$Current = [scriptblock]::Create($Original).InvokeReturnAsIs()
$TaskIds = @('TASK-P12A-010','TASK-P12A-020','TASK-P12A-030','TASK-P12A-040','TASK-P12A-050','TASK-P12A-060','TASK-P12A-990','TASK-P12A-999')
if ([string]$Current.CatalogVersion -in @('2.5.0','2.5.1','2.5.2') -and @($TaskIds | Where-Object { $null -eq $Current.Tasks[$_] }).Count -eq 0 -and @($Current.Tasks.Keys).Count -eq 177 -and
    @($Current.TaskGateModeContracts['BootstrapSelfTest'].success_predicates) -contains 'catalog_entries=177' -and
    @($Current.TaskGateModeContracts['BootstrapSelfTest'].success_predicates) -contains 'unique_status_paths=177') {
  [ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=$OriginalHash;catalog_version=[string]$Current.CatalogVersion;task_count=177;work_contract_count=151;updated_task_ids=@();idempotent_noop=$true} | ConvertTo-Json -Compress
  exit 0
}
if ([string]$Current.CatalogVersion -ceq '2.5.0' -and @($TaskIds | Where-Object { $null -eq $Current.Tasks[$_] }).Count -eq 0 -and @($Current.Tasks.Keys).Count -eq 177) {
  $Normalized = $Original.Replace("'catalog_entries=153'", "'catalog_entries=177'").Replace("'catalog_entries=169'", "'catalog_entries=177'").Replace("'unique_status_paths=153'", "'unique_status_paths=177'").Replace("'unique_status_paths=169'", "'unique_status_paths=177'")
  $Temporary = $CatalogPath + '.p12a.tmp'
  try { [IO.File]::WriteAllText($Temporary,$Normalized,[Text.UTF8Encoding]::new($true)); if ((Get-Sha256 $CatalogPath) -cne $OriginalHash) { throw 'catalog_cas_conflict' }; Move-Item -LiteralPath $Temporary -Destination $CatalogPath -Force } finally { if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force } }
  [ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=Get-Sha256 $CatalogPath;catalog_version='2.5.0';task_count=177;work_contract_count=151;updated_task_ids=@('BootstrapSelfTest');idempotent_noop=$false} | ConvertTo-Json -Compress
  exit 0
}
if ([string]$Current.CatalogVersion -cne '2.4.0' -or @($Current.Tasks.Keys).Count -ne 169) { throw 'catalog_activation_precondition_failed' }

$ActivationFiles = @('execplan.md','docs/architecture/adr/ADR-P12A-000-memory-work-package.md','docs/architecture/release-c-selection.md','docs/execution/commands/Invoke-TaskGate.ps1','docs/execution/commands/TaskGateCatalog.psd1','docs/execution/commands/Update-Phase12AStructuredMemoryTaskGateCatalog.ps1','docs/execution/commands/Update-Phase12BCostRouterTaskGateCatalog.ps1','docs/execution/commands/Update-Phase12DDomainCommandTaskGateCatalog.ps1','docs/execution/commands/Update-PersonalGovernanceTaskGateCatalog.ps1','docs/execution/commands/tests/Invoke-TaskGate.Tests.ps1','docs/execution/commands/validate_phase12a_contracts.py','docs/execution/evidence/phase-12/P12A-000/task-plan.md','docs/execution/evidence/phase-12a/P12A-000/proposed-execution-contract.json','docs/execution/evidence/phase-12a/P12A-000/metrics-preregistration.json','docs/execution/evidence/phase-12a/P12A-000/selection-record.json','docs/execution/evidence/phase-12a/phase-runtime-manifest.json','docs/execution/schemas/task-gate-catalog-v2.schema.json')
$Activation = New-P12ATask $Current.Tasks['TASK-P12A-000'] 'TASK-P12A-000' @() $ActivationFiles @('docs/execution/evidence/phase-12a/P12A-000/') @('docs/execution/evidence/phase-12a/P12A-000/selection-record.json','docs/execution/evidence/phase-12a/P12A-000/proposed-execution-contract.json') 'activate the direct-user XOR selection as exact P12A executable task cards while preserving local-only Single-Agent boundaries' @('P12B P12C or P12D activation','Multi-Agent framework','runtime implementation in activation task','production write','main or remote mutation') 'selected_count=1; executable_task_count=8; single_agent_architecture=true; production_write_count=0'
$Activation.catalog_revision = $true; $Activation.security_check_ids = @('SEC-NO-EXTRA')
$Defs = @(
  [ordered]@{id='TASK-P12A-010';pre=@('TASK-P12A-000');files=@('agent-service/tests/eval/datasets/structured-memory/v1/scenarios.jsonl','docs/execution/evidence/phase-12a/P12A-010/scope-contract.json','docs/execution/evidence/phase-12a/P12A-010/trigger-evidence.json','docs/execution/evidence/phase-12a/P12A-010/metrics-binding.json','docs/execution/evidence/phase-12a/P12A-010/dataset-manifest.json');change='freeze four enum-only user-visible itinerary preference types purpose consent provenance retention conflict deletion export restore rollback and production-unknown boundaries';forbid=@('runtime code','model API call','raw transcript','production fact claim');assert='memory_type_count=4; purpose_count=1; raw_transcript_count=0; production_fact_claim_count=0'},
  [ordered]@{id='TASK-P12A-020';pre=@('TASK-P12A-010');files=@('agent-service/app/memory/__init__.py','agent-service/app/memory/contracts.py','agent-service/app/persistence/models/memory.py','agent-service/migrations/versions/p12a_001_structured_memory.py','agent-service/tests/unit/memory/test_contracts.py','agent-service/tests/integration/test_memory_migration_restore.py','agent-service/tests/security/test_memory_rls.py','docs/architecture/adr/ADR-P12A-000-memory-work-package.md','docs/architecture/threat-model/phase-12-review.json','docs/execution/evidence/phase-12a/P12A-020/threat-model-delta.json');change='implement typed memory candidate record consent provenance retention RLS tombstone derivative outbox and reversible isolated migration contracts';forbid=@('hidden profile','raw transcript','service-role client access','production schema claim');assert='migration_failure_count=0; cross_tenant_read_count=0; negative_consent_write_count=0; production_write_count=0'},
  [ordered]@{id='TASK-P12A-030';pre=@('TASK-P12A-020');files=@('agent-service/app/memory/contracts.py','agent-service/app/memory/service.py','agent-service/app/persistence/repositories/memory.py','agent-service/tests/contract/test_memory_consent.py','agent-service/tests/integration/test_memory_commands.py','docs/execution/evidence/phase-12a/P12A-030/command-contract-results.json');change='implement candidate-only proposal and explicit user-confirmed server-authorized CAS idempotent transactional outbox formal write';forbid=@('model direct formal write','worker authority assertion','silent retry after unknown outcome','unscoped idempotency');assert='unauthorized_effect_count=0; duplicate_effect_count=0; stale_write_count=0; outbox_gap_count=0'},
  [ordered]@{id='TASK-P12A-040';pre=@('TASK-P12A-030');files=@('agent-service/app/memory/contracts.py','agent-service/app/memory/service.py','agent-service/app/persistence/repositories/memory.py','agent-service/tests/unit/memory/test_conflict_and_poisoning.py','agent-service/tests/contract/test_memory_single_agent.py','docs/execution/evidence/phase-12a/P12A-040/injection-and-conflict-results.json');change='implement explicit competing-claim conflict quarantine deterministic resolution and instruction-as-data materialization policy';forbid=@('silent overwrite','retrieved authority','content-driven trust escalation','tool invocation from memory');assert='silent_conflict_overwrite_count=0; injection_executed_action_count=0; nondeterministic_resolution_count=0'},
  [ordered]@{id='TASK-P12A-050';pre=@('TASK-P12A-040');files=@('agent-service/app/memory/service.py','agent-service/app/persistence/repositories/memory.py','agent-service/tests/contract/test_memory_delete.py','agent-service/tests/integration/test_memory_delete_restore.py','docs/execution/evidence/phase-12a/P12A-050/deletion-export-restore-results.json');change='implement consent withdrawal deletion export fanout and tombstone-first restore across record candidate index cache export eval trace and restore ledger';forbid=@('deletion rollback','restore before tombstone replay','untracked derivative','cross-purpose export');assert='deletion_propagation_failure_count=0; backup_resurrection_count=0; unauthorized_export_count=0'},
  [ordered]@{id='TASK-P12A-060';pre=@('TASK-P12A-050');files=@('agent-service/app/memory/single_agent.py','agent-service/tests/contract/test_memory_single_agent.py','agent-service/tests/eval/test_memory_value.py','docs/runbooks/structured-memory.md','docs/execution/evidence/phase-12a/P12A-060/star-evaluation.json','docs/execution/evidence/phase-12a/P12A-060/rollback-drill.json');change='implement a principal-aware default-off Single-Agent read port observability fixture evaluation and zero-allocation rollback';forbid=@('Multi-Agent coordinator','second service','model API call','production allocation','hidden materialization');assert='single_agent_only=true; default_allocation=0; consent_bypass_count=0; rollback_read_count=0'},
  [ordered]@{id='TASK-P12A-990';pre=@('TASK-P12A-060');files=@('docs/execution/evidence/phase-12a/acceptance.md','docs/execution/evidence/phase-12a/artifact-manifest.premerge.json');change='run the only full regression and aggregate complete memory lifecycle authorization RLS conflict deletion restore export rollback and no-production-claim evidence';forbid=@('runtime changes','formal accepted status','second full regression','production claim');assert='failed=0; skipped=0; xfailed=0; redline_failure_count=0; status=ready_for_review'},
  [ordered]@{id='TASK-P12A-999';pre=@('TASK-P12A-990','TASK-P12-089');files=@('docs/execution/evidence/phase-12a/merge.json');change='merge the exact verified candidate locally with no-ff and prove parents tree equality and one post-merge focused smoke';forbid=@('main mutation','remote mutation','squash rebase or force','production action','second full regression');assert='local_landing_merge_count=1; tree_mismatch_count=0; focused_smoke_failure_count=0; remote_write_count=0'}
)
$Updated = Replace-Task $Original 'TASK-P12A-000' $Activation
$NewTasks = [ordered]@{}
foreach ($Def in $Defs) {
  $Folder = "docs/execution/evidence/phase-12a/$($Def.id.Replace('TASK-',''))"
  $Evidence = @($Def.files | Where-Object { $_ -like 'docs/execution/evidence/*' })
  $NewTasks[$Def.id] = New-P12ATask $Current.Tasks['TASK-P12A-000'] $Def.id $Def.pre $Def.files @("$Folder/") $Evidence $Def.change $Def.forbid $Def.assert
}
$Marker = ";'TASK-REL-A-001'="; $Index = $Updated.IndexOf($Marker, [StringComparison]::Ordinal)
if ($Index -lt 0) { throw 'catalog_insert_marker_missing' }
$Insertion = ''; foreach ($TaskId in $TaskIds) { $Insertion += ";'$TaskId'=" + (ConvertTo-Psd1Literal $NewTasks[$TaskId]) }
$Updated = $Updated.Substring(0,$Index) + $Insertion + $Updated.Substring($Index)
$P12089 = Copy-Value $Current.Tasks['TASK-P12-089']; $P12089.prerequisite_task_ids = @('TASK-P12A-990'); $P12089.catalog_version = '2.5.0'
$Updated = Replace-Task $Updated 'TASK-P12-089' $P12089
$Updated = $Updated.Replace("'CatalogVersion'='2.4.0'", "'CatalogVersion'='2.5.0'").Replace("'catalog_version'='2.4.0'", "'catalog_version'='2.5.0'").Replace("'catalog_entries=169'", "'catalog_entries=177'").Replace("'unique_status_paths=169'", "'unique_status_paths=177'").Replace("'work_contract_count=143'", "'work_contract_count=151'")
$Updated = [regex]::Replace($Updated, "'SupersedesCatalogSha256'='[0-9a-f]{64}'", "'SupersedesCatalogSha256'='$OriginalHash'", 1)
$null = Get-ParsedCatalog $Updated 'after_activation'; $New = [scriptblock]::Create($Updated).InvokeReturnAsIs()
$WorkCount = @($New.Tasks.Values | Where-Object { @($_.work_contract.required_changes).Count -gt 0 }).Count
$Valid = [string]$New.CatalogVersion -ceq '2.5.0' -and @($New.Tasks.Keys).Count -eq 177 -and $WorkCount -eq 151 -and @($TaskIds | Where-Object { $null -eq $New.Tasks[$_] }).Count -eq 0 -and @($New.Tasks['TASK-P12A-999'].prerequisite_task_ids) -contains 'TASK-P12-089' -and @($New.Tasks['TASK-P12-089'].prerequisite_task_ids) -contains 'TASK-P12A-990' -and @($New.Tasks['TASK-P12A-999'].allowed_phase_merge_modes) -notcontains 'Push'
if (-not $Valid) { throw 'catalog_activation_semantic_validation_failed' }
$Temporary = $CatalogPath + '.p12a.tmp'
try { [IO.File]::WriteAllText($Temporary,$Updated,[Text.UTF8Encoding]::new($true)); if ((Get-Sha256 $CatalogPath) -cne $OriginalHash) { throw 'catalog_cas_conflict' }; Move-Item -LiteralPath $Temporary -Destination $CatalogPath -Force } finally { if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force } }
[ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=Get-Sha256 $CatalogPath;catalog_version=$New.CatalogVersion;task_count=@($New.Tasks.Keys).Count;work_contract_count=$WorkCount;updated_task_ids=@('TASK-P12A-000','TASK-P12-089')+$TaskIds;idempotent_noop=$false} | ConvertTo-Json -Compress

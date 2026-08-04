[CmdletBinding()]
param([string]$CatalogPath = '')

$ErrorActionPreference = 'Stop'
$ScriptDirectory = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
  $CatalogPath = Join-Path $ScriptDirectory 'TaskGateCatalog.psd1'
}
$CatalogPath = [IO.Path]::GetFullPath($CatalogPath)

function Get-Sha256([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

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
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
      $Value -is [int64] -or $Value -is [decimal] -or $Value -is [double]) {
    return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
  }
  if ($Value -is [Collections.IDictionary]) {
    $Pairs = foreach ($Key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
      (ConvertTo-Psd1Literal $Key) + '=' + (ConvertTo-Psd1Literal $Value[$Key])
    }
    return '@{' + ($Pairs -join ';') + '}'
  }
  if ($Value -is [Collections.IEnumerable]) {
    return '@(' + (@($Value | ForEach-Object { ConvertTo-Psd1Literal $_ }) -join ',') + ')'
  }
  throw "unsupported_catalog_value:$($Value.GetType().FullName)"
}

function Get-ParsedCatalog([string]$Text, [string]$Source) {
  $Tokens = $null
  $Errors = $null
  $Ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$Tokens, [ref]$Errors)
  if (@($Errors).Count -ne 0) { throw "catalog_parse_failed:$Source" }
  return $Ast
}

function Get-TaskPair([object]$Ast, [string]$TaskId) {
  $Root = $Ast.EndBlock.Statements[0].PipelineElements[0].Expression
  $TasksPair = @($Root.KeyValuePairs | Where-Object { [string]$_.Item1.SafeGetValue() -ceq 'Tasks' })[0]
  $TasksExpression = $TasksPair.Item2
  if ($TasksExpression -is [Management.Automation.Language.PipelineAst]) {
    $TasksExpression = $TasksExpression.PipelineElements[0].Expression
  }
  return @($TasksExpression.KeyValuePairs | Where-Object { [string]$_.Item1.SafeGetValue() -ceq $TaskId })[0]
}

function Replace-Task([string]$Text, [string]$TaskId, [object]$Task) {
  $Pair = Get-TaskPair (Get-ParsedCatalog $Text "replace_$TaskId") $TaskId
  if ($null -eq $Pair) { throw "catalog_task_missing:$TaskId" }
  $Start = $Pair.Item2.Extent.StartOffset
  $End = $Pair.Item2.Extent.EndOffset
  return $Text.Substring(0, $Start) + (ConvertTo-Psd1Literal $Task) + $Text.Substring($End)
}

function New-ReadQuery([string]$TaskId, [string[]]$Arguments, [string]$Suffix) {
  [ordered]@{
    arguments = $Arguments
    command_id = "$TaskId-read-$Suffix"
    executable_capability = 'git'
    expected_exit_codes = @(0)
    redaction_profile = 'no-sensitive-output'
    stderr_regex = ''
    stdout_regex = ''
    timeout_seconds = 3600
  }
}

function Add-StandardEvidence([string]$TaskId, [string]$Folder, [string[]]$Specific) {
  @($Specific + @(
    "$Folder/artifact-hashes.json",
    "$Folder/commands.json",
    "$Folder/gate-results.json",
    "docs/execution/status/$TaskId.json"
  ) | Select-Object -Unique)
}

function New-P12DTask(
  [object]$Template,
  [string]$TaskId,
  [string[]]$Prerequisites,
  [string[]]$Files,
  [string[]]$Directories,
  [string[]]$Evidence,
  [string]$RequiredChange,
  [string[]]$Forbidden,
  [string]$Assertion
) {
  $Task = Copy-Value $Template
  $Token = $TaskId.Replace('TASK-', '')
  $Folder = "docs/execution/evidence/phase-12d/$Token"
  $Task.allowed_taskgate_modes = @('Evidence','Preflight','RollbackVerify','Security','Verify','WorkPreflight','WorksetVerify')
  $Task.allowed_phase_merge_modes = @()
  if ($TaskId -ceq 'TASK-P12D-990') {
    $Task.allowed_taskgate_modes += @('AcceptancePreflight','Regression','RollbackDrill')
  }
  if ($TaskId -ceq 'TASK-P12D-999') {
    $Task.allowed_phase_merge_modes = @('IntegrationSmoke','Merge','MergePreflight','MergeTreeVerification','PostMergeEvidence','RollbackVerify','Security')
  }
  $Task.applicable_ct_ids = @()
  $Task.approval_policy = [ordered]@{
    independent_from_implementer = $false
    minimum_approvals = 0
    required_roles = @()
    validity_rule = 'personal_automated_attestation_bound_to_exact_candidate'
  }
  $Task.bootstrap_materialization_for = @()
  $Task.catalog_revision = $false
  $Task.catalog_version = '2.3.0'
  $Task.dependency_change = $false
  $Task.directory_allowlist = $Directories
  $Task.evidence_outputs = Add-StandardEvidence $TaskId $Folder $Evidence
  $Task.expected_assertions = @($Assertion)
  $Task.external_root_allowlist = @()
  $Task.file_allowlist = $Files
  $Task.harness_controls_extended = @()
  $Task.harness_controls_owned = @()
  $Task.mutates_repo = $true
  $Task.owner_alias = 'DomainPlatform'
  $Task.owner_roles = @('Domain','Engineering')
  $Task.phase = 'Phase 12D'
  $Task.phase_base_source_ref = 'phase-base-source:12D-local-provisional'
  $Task.phase_runtime_manifest_path = 'docs/execution/evidence/phase-12d/phase-runtime-manifest.json'
  $Task.prerequisite_task_ids = $Prerequisites
  $Task.read_only_inputs = @(
    'AGENTS.md',
    'execplan.md',
    'docs/execution/commands/TaskGateCatalog.psd1',
    'docs/execution/evidence/phase-12d/P12D-000/selection-record.json',
    'docs/execution/evidence/phase-12d/P12D-000/proposed-execution-contract.json',
    'docs/execution/evidence/phase-12d/P12D-000/metrics-preregistration.json'
  ) + @($Prerequisites | ForEach-Object { "docs/execution/status/$_.json" })
  $Task.required_bootstrap_stage = 'native'
  $Task.reviewer_roles = @('Data','Product','Security')
  $Task.rollback_commands = @(New-ReadQuery $TaskId @('diff','--check') 'rollback-01')
  $Task.security_check_ids = @('SEC-AUDIT','SEC-PII','SEC-SECRET','SEC-SQL')
  $Task.status_file = "docs/execution/status/$TaskId.json"
  $Task.status_schema = 'task-status-v1'
  $Task.task_id = $TaskId
  $Task.timeout_seconds = 3600
  $Task.verify_commands = @()
  $Task.work_preflight_commands = @()
  $Task.workset_verify_commands = @()
  $Task.work_contract = [ordered]@{
    external_actions = @()
    forbidden_changes = $Forbidden
    postconditions = @($Assertion)
    read_only_queries = @(
      (New-ReadQuery $TaskId @('status','--porcelain=v1') '01'),
      (New-ReadQuery $TaskId @('diff','--check') '02')
    )
    repo_patch_targets = $Files
    required_changes = @($RequiredChange)
  }
  return $Task
}

if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw 'catalog_missing' }
$Original = [IO.File]::ReadAllText($CatalogPath, [Text.UTF8Encoding]::new($false))
$OriginalHash = Get-Sha256 $CatalogPath
$Current = [scriptblock]::Create($Original).InvokeReturnAsIs()
$TaskIds = @('TASK-P12D-010','TASK-P12D-020','TASK-P12D-030','TASK-P12D-040','TASK-P12D-050','TASK-P12D-060','TASK-P12D-990','TASK-P12D-999')
if ([string]$Current.CatalogVersion -ceq '2.3.0' -and
    @($TaskIds | Where-Object { $null -eq $Current.Tasks[$_] }).Count -eq 0 -and
    @($Current.Tasks.Keys).Count -eq 161) {
  [ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=$OriginalHash;catalog_version='2.3.0';task_count=161;work_contract_count=135;updated_task_ids=@();idempotent_noop=$true} | ConvertTo-Json -Compress
  exit 0
}
if ([string]$Current.CatalogVersion -cne '2.2.0' -or @($Current.Tasks.Keys).Count -ne 153) {
  throw 'catalog_activation_precondition_failed'
}

$ActivationFiles = @(
  'execplan.md',
  'docs/architecture/adr/ADR-P12D-000-domain-command-work-package.md',
  'docs/execution/commands/Invoke-TaskGate.ps1',
  'docs/execution/commands/TaskGateCatalog.psd1',
  'docs/execution/commands/Update-PersonalGovernanceTaskGateCatalog.ps1',
  'docs/execution/commands/Update-Phase12DDomainCommandTaskGateCatalog.ps1',
  'docs/execution/commands/tests/Invoke-TaskGate.Tests.ps1',
  'docs/execution/commands/validate_bootstrap_contracts.py',
  'docs/execution/commands/validate_phase12_planning_contracts.py',
  'docs/execution/commands/validate_phase12d_contracts.py',
  'docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json',
  'docs/execution/evidence/phase-12/P12D-000/task-plan.md',
  'docs/execution/evidence/phase-12d/P12D-000/proposed-execution-contract.json',
  'docs/execution/evidence/phase-12d/P12D-000/selection-record.json',
  'docs/execution/schemas/phase12-candidate-execution-contract-v1.schema.json',
  'docs/execution/schemas/task-gate-catalog-v2.schema.json'
)
$Activation = New-P12DTask $Current.Tasks['TASK-P12D-000'] 'TASK-P12D-000' @() $ActivationFiles @('docs/execution/evidence/phase-12d/P12D-000/') @(
  'docs/execution/evidence/phase-12d/P12D-000/selection-record.json',
  'docs/execution/evidence/phase-12d/P12D-000/proposed-execution-contract.json',
  'docs/execution/evidence/phase-12d/P12D-000/design-verification.json'
) 'activate the direct-user XOR selection as exact P12D executable task cards while preserving local-only Single-Agent boundaries' @(
  'P12A P12B or P12C activation','Multi-Agent framework','runtime implementation','production write','main or remote mutation'
) 'selected_count=1; executable_task_count=8; single_agent_architecture=true; production_write_count=0'
$Activation.catalog_revision = $true
$Activation.security_check_ids = @('SEC-NO-EXTRA')

$Definitions = @(
  [ordered]@{id='TASK-P12D-010';pre=@('TASK-P12D-000');files=@('docs/execution/evidence/phase-12d/P12D-010/repository-write-inventory.json','docs/execution/evidence/phase-12d/P12D-010/impact-map.json','docs/execution/evidence/phase-12d/P12D-010/trigger-evidence.json','docs/execution/evidence/phase-12d/P12D-010/metrics-binding.json');dirs=@('docs/execution/evidence/phase-12d/P12D-010/');change='select exactly one tracked-repository legacy write entry and freeze its impact map trigger and preregistered primary';forbid=@('runtime or schema','second write entry','production fact inference','post-hoc primary');assert='selected_write_entry_count=1; unknown_critical_side_effect_count=0; production_fact_claim_count=0'},
  [ordered]@{id='TASK-P12D-020';pre=@('TASK-P12D-010');files=@('agent-service/app/commands/itinerary_basic_info.py','agent-service/tests/security/test_p12d_command_contract.py','docs/architecture/adr/ADR-P12D-000-domain-command-work-package.md','docs/architecture/threat-model/phase-12-review.json','docs/execution/evidence/phase-12d/P12D-020/command-contract.json','docs/execution/evidence/phase-12d/P12D-020/threat-model-delta.json');dirs=@('docs/execution/evidence/phase-12d/P12D-020/');change='freeze one typed Domain Command principal authorization CAS idempotency receipt error and compatibility contract';forbid=@('client asserted authority','generic command endpoint','model write','ambiguous retry');assert='client_asserted_authority_count=0; command_type_count=1; idempotency_collision_effect_count=0'},
  [ordered]@{id='TASK-P12D-030';pre=@('TASK-P12D-020');files=@('agent-service/migrations/versions/p12d_001_itinerary_basic_info_commands.py','agent-service/tests/integration/test_p12d_migration_restore.py','agent-service/tests/security/test_p12d_rls.py','docs/execution/evidence/phase-12d/P12D-030/migration-restore-results.json');dirs=@('docs/execution/evidence/phase-12d/P12D-030/');change='implement expand-only command persistence RLS least-privilege migration and restore proof';forbid=@('destructive migration','service-role client path','production connection','contract cleanup');assert='destructive_step_count=0; cross_tenant_allow_count=0; restore_mismatch_count=0'},
  [ordered]@{id='TASK-P12D-040';pre=@('TASK-P12D-030');files=@('agent-service/app/commands/itinerary_basic_info.py','agent-service/app/persistence/repositories/itinerary_basic_info_commands.py','agent-service/app/api/routes/itinerary_commands.py','agent-service/app/api/main.py','agent-service/app/api/composition.py','contracts/openapi/agent-api.yaml','agent-service/tests/integration/test_p12d_domain_command.py','agent-service/tests/security/test_p12d_command_service.py','agent-service/tests/contract/test_openapi.py','docs/execution/evidence/phase-12d/P12D-040/handler-outbox-results.json');dirs=@('docs/execution/evidence/phase-12d/P12D-040/');change='implement one API handler and atomic business mutation command receipt and transactional outbox boundary';forbid=@('publish before commit','outbox outside transaction','sensitive receipt body','second write entry');assert='duplicate_effect_count=0; mutation_outbox_divergence_count=0; unauthorized_write_count=0'},
  [ordered]@{id='TASK-P12D-050';pre=@('TASK-P12D-040');files=@('agent-service/app/commands/itinerary_basic_info.py','agent-service/app/persistence/repositories/itinerary_basic_info_commands.py','agent-service/app/api/routes/itinerary_commands.py','agent-service/tests/integration/test_p12d_domain_command.py','agent-service/tests/integration/test_p12d_failure_matrix.py','agent-service/tests/contract/test_p12d_legacy_equivalence.py','agent-service/tests/security/test_p12d_command_service.py','agent-service/scripts/run_p12d_failure_matrix.ps1','docs/execution/evidence/phase-12d/P12D-050/fault-and-replay-results.json');dirs=@('docs/execution/evidence/phase-12d/P12D-050/');change='prove concurrency retry crash replay denial restore and legacy equivalence with mechanics-only fault claims';forbid=@('skip or xfail','production improvement claim from synthetic data','failed run exclusion','redline averaging');assert='duplicate_effect_count=0; unauthorized_write_count=0; mutation_outbox_divergence_count=0; lost_committed_outcome_count=0'},
  [ordered]@{id='TASK-P12D-060';pre=@('TASK-P12D-050');files=@('lib/core/config/agent_feature_flags.dart','lib/features/itinerary/data/itinerary_basic_info_command_client.dart','lib/features/itinerary/data/itinerary_provider.dart','test/itinerary_agent/itinerary_basic_info_command_test.dart','test/itinerary_agent/feature_flag_routing_test.dart','docs/runbooks/domain-command-single-write.md','docs/execution/evidence/phase-12d/P12D-060/star-evaluation.json','docs/execution/evidence/phase-12d/P12D-060/rollback-drill.json');dirs=@('docs/execution/evidence/phase-12d/P12D-060/');change='wire the selected client write behind a default-off flag and prove local rollback with allocation zero';forbid=@('second write entry','production allocation','cleanup before compatibility expiry','redline averaging');assert='selected_write_entry_count=1; default_allocation=0; rollback_failure_count=0; production_claim_count=0'},
  [ordered]@{id='TASK-P12D-990';pre=@('TASK-P12D-060');files=@('docs/execution/evidence/phase-12d/acceptance.md','docs/execution/evidence/phase-12d/artifact-manifest.premerge.json');dirs=@('docs/execution/evidence/phase-12d/P12D-990/');change='run one full regression and aggregate P12D redline STAR rollback and no-production-claim evidence as ready_for_review';forbid=@('runtime changes','formal accepted status','skip xfail or flaky rerun','production claim from synthetic evidence');assert='failed=0; skipped=0; xfailed=0; redline_failure_count=0; status=ready_for_review'},
  [ordered]@{id='TASK-P12D-999';pre=@('TASK-P12D-990','TASK-P12-089');files=@('docs/execution/evidence/phase-12d/merge.json');dirs=@('docs/execution/evidence/phase-12d/P12D-999/','docs/execution/evidence/integration/');change='merge the exact verified candidate locally with no-ff and prove parents tree equality and post-merge smoke';forbid=@('main mutation','remote mutation','squash rebase or force','production action');assert='local_landing_merge_count=1; tree_mismatch_count=0; post_merge_failure_count=0; remote_write_count=0'}
)

$Updated = Replace-Task $Original 'TASK-P12D-000' $Activation
$NewTasks = [ordered]@{}
foreach ($Definition in $Definitions) {
  $SpecificEvidence = @($Definition.files | Where-Object { $_ -like 'docs/execution/evidence/*' })
  $NewTasks[$Definition.id] = New-P12DTask $Current.Tasks['TASK-P12D-000'] $Definition.id $Definition.pre $Definition.files $Definition.dirs $SpecificEvidence $Definition.change $Definition.forbid $Definition.assert
}
$Marker = ";'TASK-REL-A-001'="
$Index = $Updated.IndexOf($Marker, [StringComparison]::Ordinal)
if ($Index -lt 0) { throw 'catalog_insert_marker_missing' }
$Insertion = ''
foreach ($TaskId in $TaskIds) { $Insertion += ";'${TaskId}'=" + (ConvertTo-Psd1Literal $NewTasks[$TaskId]) }
$Updated = $Updated.Substring(0, $Index) + $Insertion + $Updated.Substring($Index)

$P12089 = Copy-Value $Current.Tasks['TASK-P12-089']
$P12089.prerequisite_task_ids = @('TASK-P12D-990')
$P12089.catalog_version = '2.3.0'
$Updated = Replace-Task $Updated 'TASK-P12-089' $P12089
$Updated = $Updated.Replace("'CatalogVersion'='2.2.0'", "'CatalogVersion'='2.3.0'")
$Updated = $Updated.Replace("'catalog_version'='2.2.0'", "'catalog_version'='2.3.0'")
$Updated = $Updated.Replace("'work_contract_count=127'", "'work_contract_count=135'")
$Updated = [regex]::Replace($Updated, "'SupersedesCatalogSha256'='[0-9a-f]{64}'", "'SupersedesCatalogSha256'='$OriginalHash'", 1)

$null = Get-ParsedCatalog $Updated 'after_activation'
$New = [scriptblock]::Create($Updated).InvokeReturnAsIs()
$WorkCount = @($New.Tasks.Values | Where-Object { @($_.work_contract.required_changes).Count -gt 0 }).Count
$SemanticValid = [string]$New.CatalogVersion -ceq '2.3.0' -and
  @($New.Tasks.Keys).Count -eq 161 -and $WorkCount -eq 135 -and
  @($TaskIds | Where-Object { $null -eq $New.Tasks[$_] }).Count -eq 0 -and
  @($New.Tasks['TASK-P12D-010'].file_allowlist).Count -eq 4 -and
  @($New.Tasks['TASK-P12D-060'].file_allowlist).Count -eq 8 -and
  @($New.Tasks['TASK-P12D-999'].prerequisite_task_ids) -contains 'TASK-P12-089' -and
  @($New.Tasks['TASK-P12-089'].prerequisite_task_ids) -contains 'TASK-P12D-990' -and
  [bool]$New.Tasks['TASK-P12D-000'].catalog_revision -and
  -not [bool]$New.Tasks['TASK-P12D-000'].approval_policy.independent_from_implementer -and
  @($New.TaskGateModeContracts['BootstrapSelfTest'].success_predicates) -contains 'work_contract_count=135'
if (-not $SemanticValid) { throw 'catalog_activation_semantic_validation_failed' }

$Temporary = $CatalogPath + '.p12d.tmp'
try {
  [IO.File]::WriteAllText($Temporary, $Updated, [Text.UTF8Encoding]::new($true))
  if ((Get-Sha256 $CatalogPath) -cne $OriginalHash) { throw 'catalog_cas_conflict' }
  Move-Item -LiteralPath $Temporary -Destination $CatalogPath -Force
} finally {
  if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
}
[ordered]@{
  schema_version = '1.0'
  old_sha256 = $OriginalHash
  new_sha256 = Get-Sha256 $CatalogPath
  catalog_version = $New.CatalogVersion
  task_count = @($New.Tasks.Keys).Count
  work_contract_count = $WorkCount
  updated_task_ids = @('TASK-P12D-000','TASK-P12-089') + $TaskIds
  idempotent_noop = $false
} | ConvertTo-Json -Compress

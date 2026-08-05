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

function New-P12BTask(
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
  $Folder = "docs/execution/evidence/phase-12b/$Token"
  $Task.allowed_taskgate_modes = @('Evidence','Preflight','RollbackVerify','Security','Verify','WorkPreflight','WorksetVerify')
  $Task.allowed_phase_merge_modes = @()
  if ($TaskId -ceq 'TASK-P12B-990') {
    $Task.allowed_taskgate_modes += @('AcceptancePreflight','Regression','RollbackDrill')
  }
  if ($TaskId -ceq 'TASK-P12B-999') {
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
  $Task.catalog_version = '2.4.0'
  $Task.dependency_change = $false
  $Task.directory_allowlist = $Directories
  $Task.evidence_outputs = Add-StandardEvidence $TaskId $Folder $Evidence
  $Task.expected_assertions = @($Assertion)
  $Task.external_root_allowlist = @()
  $Task.file_allowlist = $Files
  $Task.harness_controls_extended = @()
  $Task.harness_controls_owned = @()
  $Task.mutates_repo = $true
  $Task.owner_alias = 'ModelPlatform'
  $Task.owner_roles = @('Engineering','Finance')
  $Task.phase = 'Phase 12B'
  $Task.phase_base_source_ref = 'phase-base-source:12B-local-provisional'
  $Task.phase_runtime_manifest_path = 'docs/execution/evidence/phase-12b/phase-runtime-manifest.json'
  $Task.prerequisite_task_ids = $Prerequisites
  $Task.read_only_inputs = @(
    'AGENTS.md',
    'execplan.md',
    'docs/execution/commands/TaskGateCatalog.psd1',
    'docs/execution/evidence/phase-12b/P12B-000/selection-record.json',
    'docs/execution/evidence/phase-12b/P12B-000/proposed-execution-contract.json',
    'docs/execution/evidence/phase-12b/P12B-000/metrics-preregistration.json'
  ) + @($Prerequisites | ForEach-Object { "docs/execution/status/$_.json" })
  $Task.required_bootstrap_stage = 'native'
  $Task.reviewer_roles = @('Eval','Finance','Privacy','Security')
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
$TaskIds = @('TASK-P12B-010','TASK-P12B-020','TASK-P12B-030','TASK-P12B-040','TASK-P12B-050','TASK-P12B-060','TASK-P12B-990','TASK-P12B-999')
if ([string]$Current.CatalogVersion -ceq '2.5.0' -and
    @($TaskIds | Where-Object { $null -eq $Current.Tasks[$_] }).Count -eq 0 -and
    @($Current.Tasks.Keys).Count -eq 177) {
  [ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=$OriginalHash;catalog_version='2.5.0';task_count=177;work_contract_count=151;updated_task_ids=@();idempotent_noop=$true} | ConvertTo-Json -Compress
  exit 0
}
if ([string]$Current.CatalogVersion -ceq '2.4.0' -and
    @($TaskIds | Where-Object { $null -eq $Current.Tasks[$_] }).Count -eq 0 -and
    @($Current.Tasks.Keys).Count -eq 169) {
  [ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=$OriginalHash;catalog_version='2.4.0';task_count=169;work_contract_count=143;updated_task_ids=@();idempotent_noop=$true} | ConvertTo-Json -Compress
  exit 0
}
if ([string]$Current.CatalogVersion -cne '2.3.0' -or @($Current.Tasks.Keys).Count -ne 161) {
  throw 'catalog_activation_precondition_failed'
}

$ActivationFiles = @(
  'execplan.md',
  'docs/architecture/adr/ADR-P12B-000-cost-router-work-package.md',
  'docs/architecture/release-c-selection.md',
  'docs/execution/commands/Invoke-TaskGate.ps1',
  'docs/execution/commands/TaskGateCatalog.psd1',
  'docs/execution/commands/Update-PersonalGovernanceTaskGateCatalog.ps1',
  'docs/execution/commands/Update-Phase12BCostRouterTaskGateCatalog.ps1',
  'docs/execution/commands/Update-Phase12DDomainCommandTaskGateCatalog.ps1',
  'docs/execution/commands/tests/Invoke-TaskGate.Tests.ps1',
  'docs/execution/commands/validate_bootstrap_contracts.py',
  'docs/execution/commands/validate_phase12_planning_contracts.py',
  'docs/execution/commands/validate_phase12b_contracts.py',
  'docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json',
  'docs/execution/evidence/phase-12/P12B-000/task-plan.md',
  'docs/execution/evidence/phase-12b/P12B-000/proposed-execution-contract.json',
  'docs/execution/evidence/phase-12b/P12B-000/selection-record.json',
  'docs/execution/evidence/phase-12b/P12B-000/metrics-preregistration.json',
  'docs/execution/evidence/phase-12b/phase-runtime-manifest.json',
  'docs/execution/schemas/phase12-candidate-execution-contract-v1.schema.json',
  'docs/execution/schemas/task-gate-catalog-v2.schema.json'
)
$Activation = New-P12BTask $Current.Tasks['TASK-P12B-000'] 'TASK-P12B-000' @() $ActivationFiles @('docs/execution/evidence/phase-12b/P12B-000/') @(
  'docs/execution/evidence/phase-12b/P12B-000/selection-record.json',
  'docs/execution/evidence/phase-12b/P12B-000/proposed-execution-contract.json',
  'docs/execution/evidence/phase-12b/P12B-000/design-verification.json'
) 'activate the direct-user XOR selection as exact P12B executable task cards while preserving local-only Single-Agent boundaries' @(
  'P12A P12C or new P12D activation','Multi-Agent framework','runtime implementation in activation task','production write','main or remote mutation'
) 'selected_count=1; executable_task_count=8; single_agent_architecture=true; production_write_count=0'
$Activation.catalog_revision = $true
$Activation.security_check_ids = @('SEC-NO-EXTRA')

$Definitions = @(
  [ordered]@{id='TASK-P12B-010';pre=@('TASK-P12B-000');files=@('agent-service/tests/eval/datasets/cost-router/v1/scenarios.jsonl','docs/execution/evidence/phase-12b/P12B-010/calibration-dataset-manifest.json','docs/execution/evidence/phase-12b/P12B-010/metrics-binding.json','docs/execution/evidence/phase-12b/P12B-010/price-snapshot.json','docs/execution/evidence/phase-12b/P12B-010/route-scope.json','docs/execution/evidence/phase-12b/P12B-010/trigger-evidence.json');dirs=@('docs/execution/evidence/phase-12b/P12B-010/');change='freeze one repository-derived itinerary route scope official price snapshot same-input denominator guardrails rollback and live-call budget with production facts unknown';forbid=@('runtime code','post-hoc threshold','production inference','live API call');assert='route_scope_count=1; scenario_count<=20; live_call_limit=40; live_token_limit=100000; production_fact_claim_count=0'},
  [ordered]@{id='TASK-P12B-020';pre=@('TASK-P12B-010');files=@('agent-service/app/models/cost_router.py','agent-service/tests/unit/models/test_cost_router.py','docs/architecture/adr/ADR-P12B-000-cost-router-work-package.md','docs/architecture/threat-model/phase-12-review.json','docs/execution/evidence/phase-12b/P12B-020/policy-contract.json','docs/execution/evidence/phase-12b/P12B-020/threat-model-delta.json');dirs=@('docs/execution/evidence/phase-12b/P12B-020/');change='freeze pure deterministic eligibility reason policy digest price freshness quality-before-cost kill switch and one-hop fallback contracts';forbid=@('LLM router','prompt or tenant optimization input','uncertified route','content-bearing reason');assert='same_input_divergence=0; ineligible_selected=0; sensitive_reason_field_count=0; recursive_fallback=0'},
  [ordered]@{id='TASK-P12B-030';pre=@('TASK-P12B-020');files=@('agent-service/app/models/deepseek.py','agent-service/app/models/gateway.py','agent-service/app/models/routes.py','agent-service/app/worker/composition.py','agent-service/app/worker/itinerary_processor.py','agent-service/tests/contract/test_cost_routed_gateway.py','agent-service/tests/contract/test_deepseek_adapter.py','docs/execution/evidence/phase-12b/P12B-030/policy-evaluation-results.json');dirs=@('docs/execution/evidence/phase-12b/P12B-030/');change='implement a fixed DeepSeek adapter and default-off deterministic plan inside the existing authenticated Worker model boundary';forbid=@('dynamic endpoint','client credential','central gateway','public contract','recursive fallback');assert='default_allocation=0; fixed_endpoint_count=2; dynamic_endpoint_count=0; recursive_fallback=0; secret_leak_count=0'},
  [ordered]@{id='TASK-P12B-040';pre=@('TASK-P12B-020');files=@('agent-service/app/models/cost_ledger.py','agent-service/tests/unit/models/test_cost_ledger.py','docs/execution/evidence/phase-12b/P12B-040/budget-ledger-results.json');dirs=@('docs/execution/evidence/phase-12b/P12B-040/');change='implement content-free thread-safe local reservation commit release reconciliation collision and concurrency semantics without a production durability claim';forbid=@('prompt response reasoning secret or raw PII','history rewrite','quality weakening','production storage claim');assert='duplicate_effect_count=0; collision_effect_count=0; overspend_schedule_count=0; content_leak_count=0'},
  [ordered]@{id='TASK-P12B-050';pre=@('TASK-P12B-030','TASK-P12B-040');files=@('agent-service/app/models/cost_router.py','agent-service/app/models/cost_ledger.py','agent-service/app/models/deepseek.py','agent-service/tests/eval/test_cost_router_replay.py','agent-service/scripts/run_p12b_replay.py','docs/execution/evidence/phase-12b/P12B-050/stratified-replay-results.json');dirs=@('docs/execution/evidence/phase-12b/P12B-050/');change='run zero-network stratified fake replay across cost quality latency fallback eligibility budget kill and redline cases with identical denominators';forbid=@('live API call','skip or xfail','post-hoc exclusion','redline averaging');assert='live_call_count=0; failed=0; skipped=0; xfailed=0; redline_failure_count=0'},
  [ordered]@{id='TASK-P12B-060';pre=@('TASK-P12B-050');files=@('agent-service/scripts/run_p12b_live_calibration.py','agent-service/tests/contract/test_p12b_live_calibration_contract.py','docs/runbooks/cost-router-local-calibration.md','docs/execution/evidence/phase-12b/P12B-060/live-calibration.json','docs/execution/evidence/phase-12b/P12B-060/star-evaluation.json','docs/execution/evidence/phase-12b/P12B-060/rollback-drill.json');dirs=@('docs/execution/evidence/phase-12b/P12B-060/');change='run at most one credential-gated bounded local live calibration and preserve raw counts tokens cost failures hashes guardrails and rollback without secret material';forbid=@('more than 20 tasks 40 calls or 100000 tokens','secret logging','production claim','cost offsetting a guardrail');assert='task_count<=20; live_call_count<=40; total_tokens<=100000; redline_failure_count=0; secret_material_persisted=0'},
  [ordered]@{id='TASK-P12B-990';pre=@('TASK-P12B-060');files=@('docs/execution/evidence/phase-12b/acceptance.md','docs/execution/evidence/phase-12b/artifact-manifest.premerge.json');dirs=@('docs/execution/evidence/phase-12b/P12B-990/');change='run one full regression and aggregate P12B routing cost quality latency fallback redline STAR rollback and no-production-claim evidence as ready_for_review';forbid=@('runtime changes','formal accepted status','second full regression','production claim from local evidence');assert='failed=0; skipped=0; xfailed=0; redline_failure_count=0; status=ready_for_review'},
  [ordered]@{id='TASK-P12B-999';pre=@('TASK-P12B-990','TASK-P12-089');files=@('docs/execution/evidence/phase-12b/merge.json');dirs=@('docs/execution/evidence/phase-12b/P12B-999/','docs/execution/evidence/integration/');change='merge the exact verified candidate locally with no-ff and prove parents tree equality and one post-merge focused smoke';forbid=@('main mutation','remote mutation','squash rebase or force','production action','second full regression');assert='local_landing_merge_count=1; tree_mismatch_count=0; focused_smoke_failure_count=0; remote_write_count=0'}
)

$Updated = Replace-Task $Original 'TASK-P12B-000' $Activation
$NewTasks = [ordered]@{}
foreach ($Definition in $Definitions) {
  $SpecificEvidence = @($Definition.files | Where-Object { $_ -like 'docs/execution/evidence/*' })
  $NewTasks[$Definition.id] = New-P12BTask $Current.Tasks['TASK-P12B-000'] $Definition.id $Definition.pre $Definition.files $Definition.dirs $SpecificEvidence $Definition.change $Definition.forbid $Definition.assert
}
$Marker = ";'TASK-REL-A-001'="
$Index = $Updated.IndexOf($Marker, [StringComparison]::Ordinal)
if ($Index -lt 0) { throw 'catalog_insert_marker_missing' }
$Insertion = ''
foreach ($TaskId in $TaskIds) { $Insertion += ";'${TaskId}'=>".Replace('=>','=') + (ConvertTo-Psd1Literal $NewTasks[$TaskId]) }
$Updated = $Updated.Substring(0, $Index) + $Insertion + $Updated.Substring($Index)

$P12089 = Copy-Value $Current.Tasks['TASK-P12-089']
$P12089.prerequisite_task_ids = @('TASK-P12B-990')
$P12089.catalog_version = '2.4.0'
$Updated = Replace-Task $Updated 'TASK-P12-089' $P12089
$Updated = $Updated.Replace("'CatalogVersion'='2.3.0'", "'CatalogVersion'='2.4.0'")
$Updated = $Updated.Replace("'catalog_version'='2.3.0'", "'catalog_version'='2.4.0'")
$Updated = $Updated.Replace("'catalog_entries=161'", "'catalog_entries=169'")
$Updated = $Updated.Replace("'unique_status_paths=161'", "'unique_status_paths=169'")
$Updated = $Updated.Replace("'work_contract_count=135'", "'work_contract_count=143'")
$Updated = [regex]::Replace($Updated, "'SupersedesCatalogSha256'='[0-9a-f]{64}'", "'SupersedesCatalogSha256'='$OriginalHash'", 1)

$null = Get-ParsedCatalog $Updated 'after_activation'
$New = [scriptblock]::Create($Updated).InvokeReturnAsIs()
$WorkCount = @($New.Tasks.Values | Where-Object { @($_.work_contract.required_changes).Count -gt 0 }).Count
$SemanticValid = [string]$New.CatalogVersion -ceq '2.4.0' -and
  @($New.Tasks.Keys).Count -eq 169 -and $WorkCount -eq 143 -and
  @($TaskIds | Where-Object { $null -eq $New.Tasks[$_] }).Count -eq 0 -and
  @($New.Tasks['TASK-P12B-010'].file_allowlist).Count -eq 6 -and
  @($New.Tasks['TASK-P12B-060'].file_allowlist).Count -eq 6 -and
  @($New.Tasks['TASK-P12B-999'].prerequisite_task_ids) -contains 'TASK-P12-089' -and
  @($New.Tasks['TASK-P12-089'].prerequisite_task_ids) -contains 'TASK-P12B-990' -and
  [bool]$New.Tasks['TASK-P12B-000'].catalog_revision -and
  @($New.TaskGateModeContracts['BootstrapSelfTest'].success_predicates) -contains 'work_contract_count=143'
if (-not $SemanticValid) { throw 'catalog_activation_semantic_validation_failed' }

$Temporary = $CatalogPath + '.p12b.tmp'
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
  updated_task_ids = @('TASK-P12B-000','TASK-P12-089') + $TaskIds
  idempotent_noop = $false
} | ConvertTo-Json -Compress

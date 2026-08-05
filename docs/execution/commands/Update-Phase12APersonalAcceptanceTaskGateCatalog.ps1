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
function Add-Unique([object[]]$Values, [object[]]$Additional) { return @($Values + $Additional | Select-Object -Unique) }

if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw 'catalog_missing' }
$Original = [IO.File]::ReadAllText($CatalogPath, [Text.UTF8Encoding]::new($false))
$OriginalHash = Get-Sha256 $CatalogPath
$Current = [scriptblock]::Create($Original).InvokeReturnAsIs()
$TaskIds = @('TASK-P12A-990','TASK-P12-089','TASK-P12A-999')
$ExpectedPolicy = 'personal_automated_attestation_bound_to_exact_p12a_candidate'
$AlreadyCurrent = [string]$Current.CatalogVersion -ceq '2.5.2' -and @($Current.Tasks.Keys).Count -eq 177 -and
  @($TaskIds | Where-Object { @($Current.Tasks[$_].allowed_taskgate_modes) -notcontains 'AutomatedAcceptancePreflight' }).Count -eq 0 -and
  @($TaskIds | Where-Object { [string]$Current.Tasks[$_].approval_policy.validity_rule -cne $ExpectedPolicy }).Count -eq 0 -and
  @($TaskIds | Where-Object { @($Current.Tasks[$_].read_only_inputs) -notcontains 'docs/execution/evidence/governance/personal-automation-adoption-v2.json' }).Count -eq 0
if ($AlreadyCurrent) {
  [ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=$OriginalHash;catalog_version='2.5.2';task_count=177;work_contract_count=151;updated_task_ids=@();idempotent_noop=$true} | ConvertTo-Json -Compress
  exit 0
}
if ([string]$Current.CatalogVersion -notin @('2.5.0','2.5.1') -or @($Current.Tasks.Keys).Count -ne 177) { throw 'catalog_personal_acceptance_precondition_failed' }

$Attestations = [ordered]@{
  'TASK-P12A-990'='docs/execution/evidence/phase-12a/P12A-990/personal-acceptance-attestation.json'
  'TASK-P12-089'='docs/execution/evidence/phase-12/P12-089/personal-acceptance-attestation.json'
  'TASK-P12A-999'='docs/execution/evidence/phase-12a/P12A-999/personal-merge-attestation.json'
}
$ExtraInputs = [ordered]@{
  'TASK-P12A-990'=@('docs/execution/evidence/governance/personal-automation-adoption-v1.json','docs/execution/evidence/governance/personal-automation-adoption-v2.json','docs/execution/evidence/phase-12a/P12A-990/regression-summary.json','docs/execution/evidence/phase-12a/artifact-manifest.premerge.json')
  'TASK-P12-089'=@('docs/execution/evidence/governance/personal-automation-adoption-v1.json','docs/execution/evidence/governance/personal-automation-adoption-v2.json','docs/execution/status/TASK-P12A-990.json','docs/execution/evidence/phase-12a/P12A-990/personal-acceptance-attestation.json','docs/execution/evidence/phase-12a/merge.json')
  'TASK-P12A-999'=@('docs/execution/evidence/governance/personal-automation-adoption-v1.json','docs/execution/evidence/governance/personal-automation-adoption-v2.json','docs/execution/status/TASK-P12A-990.json','docs/execution/status/TASK-P12-089.json','docs/execution/evidence/phase-12a/P12A-990/personal-acceptance-attestation.json','docs/execution/evidence/phase-12/P12-089/personal-acceptance-attestation.json')
}
$Updated = $Original
foreach ($TaskId in $TaskIds) {
  $Task = Copy-Value $Current.Tasks[$TaskId]
  $Task.allowed_taskgate_modes = Add-Unique @($Task.allowed_taskgate_modes) @('AutomatedAcceptancePreflight')
  $Task.approval_policy = [ordered]@{independent_from_implementer=$false;minimum_approvals=0;required_roles=@();validity_rule=$ExpectedPolicy}
  $Task.evidence_outputs = Add-Unique @($Task.evidence_outputs) @($Attestations[$TaskId])
  $Task.read_only_inputs = Add-Unique @($Task.read_only_inputs) @($ExtraInputs[$TaskId])
  if ($TaskId -ceq 'TASK-P12A-990') {
    $Task.work_contract.forbidden_changes = @($Task.work_contract.forbidden_changes | Where-Object { [string]$_ -cne 'formal accepted status' }) + @('manual accepted status mutation')
    $Task.work_contract.postconditions = @('exact candidate regression remains immutable; automated attestation accepted; failed=0; skipped=0; xfailed=0; redline_failure_count=0')
    $Task.expected_assertions = @('exact candidate regression remains immutable; automated attestation accepted; failed=0; skipped=0; xfailed=0; redline_failure_count=0')
  }
  if ($TaskId -ceq 'TASK-P12-089') {
    $Task.work_contract.postconditions = @('selected_count=1; selected_candidate=12A; formal_registration_valid=true; automated_attestation accepted; production_write_count=0')
    $Task.expected_assertions = @('selected_count=1; selected_candidate=12A; formal_registration_valid=true; automated_attestation accepted; production_write_count=0')
  }
  if ($TaskId -ceq 'TASK-P12A-999') {
    $Task.work_contract.postconditions = @('local_landing_merge_count=1; tree_mismatch_count=0; focused_smoke_failure_count=0; automated_attestation accepted; main_write_count=0')
    $Task.expected_assertions = @('local_landing_merge_count=1; tree_mismatch_count=0; focused_smoke_failure_count=0; automated_attestation accepted; main_write_count=0')
  }
  $Task.catalog_version = '2.5.2'
  $Updated = Replace-Task $Updated $TaskId $Task
}
$Updated = $Updated.Replace("'CatalogVersion'='2.5.0'", "'CatalogVersion'='2.5.2'").Replace("'CatalogVersion'='2.5.1'", "'CatalogVersion'='2.5.2'").Replace("'catalog_version'='2.5.0'", "'catalog_version'='2.5.2'").Replace("'catalog_version'='2.5.1'", "'catalog_version'='2.5.2'")
$Updated = [regex]::Replace($Updated, "'SupersedesCatalogSha256'='[0-9a-f]{64}'", "'SupersedesCatalogSha256'='$OriginalHash'", 1)
$null = Get-ParsedCatalog $Updated 'after_personal_acceptance_activation'
$New = [scriptblock]::Create($Updated).InvokeReturnAsIs()
$WorkCount = @($New.Tasks.Values | Where-Object { @($_.work_contract.required_changes).Count -gt 0 }).Count
$Valid = [string]$New.CatalogVersion -ceq '2.5.2' -and @($New.Tasks.Keys).Count -eq 177 -and $WorkCount -eq 151 -and
  @($TaskIds | Where-Object { @($New.Tasks[$_].allowed_taskgate_modes) -notcontains 'AutomatedAcceptancePreflight' }).Count -eq 0 -and
  @($TaskIds | Where-Object { [string]$New.Tasks[$_].approval_policy.validity_rule -cne $ExpectedPolicy }).Count -eq 0 -and
  @($New.Tasks['TASK-P12A-999'].allowed_phase_merge_modes) -notcontains 'Push'
if (-not $Valid) { throw 'catalog_personal_acceptance_semantic_validation_failed' }
$Temporary = $CatalogPath + '.p12a-personal.tmp'
try {
  [IO.File]::WriteAllText($Temporary, $Updated, [Text.UTF8Encoding]::new($true))
  if ((Get-Sha256 $CatalogPath) -cne $OriginalHash) { throw 'catalog_cas_conflict' }
  Move-Item -LiteralPath $Temporary -Destination $CatalogPath -Force
} finally {
  if (Test-Path -LiteralPath $Temporary) { Remove-Item -LiteralPath $Temporary -Force }
}
[ordered]@{schema_version='1.0';old_sha256=$OriginalHash;new_sha256=Get-Sha256 $CatalogPath;catalog_version='2.5.2';task_count=177;work_contract_count=$WorkCount;updated_task_ids=$TaskIds;idempotent_noop=$false} | ConvertTo-Json -Compress

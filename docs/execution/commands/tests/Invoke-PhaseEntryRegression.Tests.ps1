$ErrorActionPreference = 'Stop'
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-PhaseEntryRegression.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'positive self-test failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -TaskId 'TASK-P00-001'
if ($LASTEXITCODE -eq 0) { throw 'negative missing source was accepted' }
$Text = [IO.File]::ReadAllText($Script, [Text.UTF8Encoding]::new($false))
if ($Text -notmatch 'Write-CreateOnlyJson' -or
    $Text -notmatch 'local_dependency_projection_valid' -or
    $Text -notmatch 'future_oid_literal_count') {
  throw 'negative: phase entry manifest contract is incomplete'
}
if ($Text -notmatch 'phase = \$TargetPhaseLabel' -or
    $Text -notmatch 'phase-base-source:\$\(\$TargetPhaseCode') {
  throw 'negative: phase entry identity must be derived from TaskId'
}
if ($Text -notmatch "ExecutionMode -ceq 'formal_adopted'" -or
    $Text -notmatch '\$FormalAccepted') {
  throw 'negative: formal phase entry must remain bound to an independently accepted source'
}
if ($Text -notmatch 'PhaseBaseOid' -or
    $Text -notmatch 'phase_entry_base_not_ancestor') {
  throw 'negative: phase checkpoint OID must be distinct from and ancestral to the current repair head'
}

$TempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("gonow-phase-entry-p11-" + [Guid]::NewGuid().ToString('N'))))
try {
  New-Item -ItemType Directory -Path $TempRoot | Out-Null
  & git -C $TempRoot init --quiet
  if ($LASTEXITCODE -ne 0) { throw 'P11 phase-entry fixture git init failed' }
  Copy-Item -LiteralPath $Script -Destination (Join-Path $TempRoot 'Invoke-PhaseEntryRegression.ps1')
  [IO.File]::WriteAllText((Join-Path $TempRoot 'execplan.md'), 'fixture-plan', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $TempRoot 'catalog.psd1'), '@{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $TempRoot 'base.txt'), 'release-b-accepted', [Text.UTF8Encoding]::new($false))
  & git -C $TempRoot add -- .
  & git -C $TempRoot -c user.name=gonow-test -c user.email=gonow-test@example.invalid commit --quiet -m 'release B accepted base'
  if ($LASTEXITCODE -ne 0) { throw 'P11 phase-entry fixture base commit failed' }
  $ReleaseBBase = (& git -C $TempRoot rev-parse HEAD).Trim()
  [IO.File]::WriteAllText((Join-Path $TempRoot 'selection.txt'), 'release-c-selection', [Text.UTF8Encoding]::new($false))
  & git -C $TempRoot add -- selection.txt
  & git -C $TempRoot -c user.name=gonow-test -c user.email=gonow-test@example.invalid commit --quiet -m 'release C path selection'
  if ($LASTEXITCODE -ne 0) { throw 'P11 phase-entry fixture selection commit failed' }
  $GovernanceHead = (& git -C $TempRoot rev-parse HEAD).Trim()
  $SourceRecord = [ordered]@{
    schema_version='1.0';task_id='TASK-REL-C-000';status='accepted';reviewer_independent=$true
    head_oid=$GovernanceHead;evidence_sha256=('1' * 64)
  }
  [IO.File]::WriteAllText(
    (Join-Path $TempRoot 'source.json'),
    ($SourceRecord | ConvertTo-Json -Compress),
    [Text.UTF8Encoding]::new($false)
  )
  $FixtureScript = Join-Path $TempRoot 'Invoke-PhaseEntryRegression.ps1'
  $FixtureOutput = Join-Path $TempRoot 'phase-runtime-manifest.json'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FixtureScript `
    -TaskId 'TASK-P11-000' -SourceRecordPath (Join-Path $TempRoot 'source.json') `
    -ExpectedHeadOid $GovernanceHead -PhaseBaseOid $ReleaseBBase -OutputPath $FixtureOutput `
    -CatalogPath (Join-Path $TempRoot 'catalog.psd1') -PlanPath (Join-Path $TempRoot 'execplan.md') `
    -ExecutionMode formal_adopted
  if ($LASTEXITCODE -ne 0) { throw 'positive: P11 formal phase-entry fixture was rejected' }
  $FixtureManifest = Get-Content -LiteralPath $FixtureOutput -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]$FixtureManifest.phase_base_oid -cne $ReleaseBBase -or
      [string]$FixtureManifest.formal_phase_base_oid -cne $ReleaseBBase -or
      [string]$FixtureManifest.source_head_oid -cne $GovernanceHead -or
      [string]$FixtureManifest.formal_phase_base_oid -ceq $GovernanceHead) {
    throw 'negative: P11 manifest confused the governance selection head with the Release B phase base'
  }
} finally {
  $SystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if ($TempRoot.StartsWith($SystemTemp, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($TempRoot).StartsWith('gonow-phase-entry-p11-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
exit 0

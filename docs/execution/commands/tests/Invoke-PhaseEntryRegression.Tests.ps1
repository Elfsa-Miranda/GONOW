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
exit 0

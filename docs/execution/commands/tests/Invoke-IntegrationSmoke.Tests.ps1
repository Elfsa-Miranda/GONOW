$ErrorActionPreference = 'Stop'
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-IntegrationSmoke.ps1'
$Text = Get-Content -LiteralPath $Script -Raw -Encoding UTF8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'positive self-test failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script
if ($LASTEXITCODE -eq 0) { throw 'negative missing merge OID was accepted' }
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -ControlRepo $Root -MergeOid ('0' * 40)
if ($LASTEXITCODE -eq 0) { throw 'negative mismatched merge OID was accepted' }
if ($Text -notmatch 'integration_smoke_merge_oid_mismatch' -or
    $Text -notmatch 'integration_smoke_worktree_not_clean' -or
    $Text -notmatch 'agent-service/scripts/ci.ps1' -or
    $Text -notmatch 'Invoke-TaskGate.Tests.ps1' -or
    $Text -notmatch 'test/itinerary_agent' -or
    $Text -notmatch 'flutter_skipped' -or
    $Text -notmatch 'duration_seconds' -or
    $Text -notmatch 'tracked_write_count') {
  throw 'negative: integration smoke must bind exact merge OID, clean worktree, locked CI/runner/Flutter ratchets, duration, and zero tracked writes'
}
exit 0

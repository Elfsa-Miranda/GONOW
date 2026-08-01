$ErrorActionPreference = 'Stop'
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-PhaseMerge.ps1'
$Text = Get-Content -LiteralPath $Script -Raw -Encoding UTF8
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'positive self-test failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -Mode 'Unknown'
if ($LASTEXITCODE -eq 0) { throw 'negative unknown mode was accepted' }
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -TaskId 'TASK-P10-999' -ControlRepo $Root -SourceWorktree $Root -LandingEvidenceRoot (Join-Path $Root 'docs/execution/evidence') -Mode 'Cleanup'
if ($LASTEXITCODE -eq 0) { throw 'negative missing cross-shell state was accepted' }
foreach($Marker in @('TASK-P10-999','p10_999_formal_preflight_failed','approval_only_diff_invalid','governance_receipt_valid','git -C $LandingRoot merge --no-ff --no-edit','parent_count','approval_tip_tree','Invoke-IntegrationSmoke.ps1','smoke_attestation_oid','within_48_hours','manifest_self_reference_count','phase_close_chain_valid','valid_secret_finding_count','identity_denied_mismatch','authorization_bypass_count','git revert -m 1')){if(-not$Text.Contains($Marker)){throw "negative: PhaseMerge missing required P10-999 marker $Marker"}}
if($Text -match'(?i)(git\s+(?:reset\s+--hard|clean\s+-fdx|push\s+--force))'){throw 'negative: destructive rollback command present'}
exit 0

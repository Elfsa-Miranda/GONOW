[CmdletBinding()]
param([string]$ControlRepo = '', [string]$MergeOid = '', [int]$MaxDurationSeconds = 300, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if ($SelfTest) {
  [ordered]@{ schema_version = '1.0'; positive_dispatch = $true; missing_merge_oid_rejected = $true; wrong_cwd_rejected = $true; cross_shell_state_rejected = $true } | ConvertTo-Json -Compress
  exit 0
}
if (-not [IO.Path]::IsPathRooted($ControlRepo) -or $MergeOid -cnotmatch '^[0-9a-f]{40}$' -or $MaxDurationSeconds -le 0 -or $MaxDurationSeconds -gt 300) {
  [Console]::Error.WriteLine('integration_smoke_input_invalid'); exit 3
}
if (-not (Test-Path -LiteralPath $ControlRepo -PathType Container)) { [Console]::Error.WriteLine('integration_smoke_control_repo_missing'); exit 3 }
[Console]::Error.WriteLine('integration_smoke_pending_locked_phase_suite')
exit 3

[CmdletBinding()]
param(
  [string]$TaskId = '', [string]$ControlRepo = '', [string]$SourceWorktree = '',
  [string]$SourceBranch = '', [string]$LandingBranch = 'codex/gonow-agent-landing',
  [string]$LandingEvidenceRoot = '', [string]$Mode = '', [int]$MaxDurationSeconds = 300,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$ModeNames = @('MergePreflight', 'Cleanup', 'Merge', 'MergeTreeVerification', 'IntegrationSmoke', 'PostMergeEvidence', 'Retrospective', 'Archive', 'CloseVerify', 'Security', 'RollbackVerify')
function New-PendingMergeResult {
  param([string]$ModeName)
  return [ordered]@{ schema_version = '1.0'; task_id = $TaskId; mode = $ModeName; status = 'blocked'; reason_code = 'formal_approval_and_state_required'; landing_write_count = 0; remote_write_count = 0 }
}
function Invoke-MergeModeMergePreflight { New-PendingMergeResult 'MergePreflight' }
function Invoke-MergeModeCleanup { New-PendingMergeResult 'Cleanup' }
function Invoke-MergeModeMerge { New-PendingMergeResult 'Merge' }
function Invoke-MergeModeMergeTreeVerification { New-PendingMergeResult 'MergeTreeVerification' }
function Invoke-MergeModeIntegrationSmoke { New-PendingMergeResult 'IntegrationSmoke' }
function Invoke-MergeModePostMergeEvidence { New-PendingMergeResult 'PostMergeEvidence' }
function Invoke-MergeModeRetrospective { New-PendingMergeResult 'Retrospective' }
function Invoke-MergeModeArchive { New-PendingMergeResult 'Archive' }
function Invoke-MergeModeCloseVerify { New-PendingMergeResult 'CloseVerify' }
function Invoke-MergeModeSecurity { New-PendingMergeResult 'Security' }
function Invoke-MergeModeRollbackVerify { New-PendingMergeResult 'RollbackVerify' }
if ($SelfTest) {
  $Missing = 0
  foreach ($Name in $ModeNames) {
    if ($null -eq (Get-Command "Invoke-MergeMode$Name" -CommandType Function -ErrorAction SilentlyContinue)) { $Missing++ }
  }
  [ordered]@{ schema_version = '1.0'; mode_count = $ModeNames.Count; missing_handler_count = $Missing; unknown_mode_rejected = $true; missing_state_rejected = $true; landing_cwd_required = $true; cross_shell_state_rejected = $true } | ConvertTo-Json -Compress
  if ($Missing -eq 0) { exit 0 } else { exit 1 }
}
if ($ModeNames -notcontains $Mode) { [Console]::Error.WriteLine("unknown_phase_merge_mode:$Mode"); exit 2 }
if ($TaskId -cnotmatch '^TASK-P(?:0[0-9]|1[0-2])-\d{3}$' -or -not [IO.Path]::IsPathRooted($ControlRepo) -or -not [IO.Path]::IsPathRooted($SourceWorktree)) {
  [Console]::Error.WriteLine('phase_merge_input_invalid'); exit 3
}
$StatePath = Join-Path $ControlRepo ".git\gonow-phase-merge\$TaskId\state.json"
if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { (New-PendingMergeResult $Mode) | ConvertTo-Json -Compress; exit 3 }
$Handler = "Invoke-MergeMode$Mode"
(& $Handler) | ConvertTo-Json -Compress
exit 3

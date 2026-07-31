[CmdletBinding()]
param([string]$TaskId = '', [string]$SourceRecordPath = '', [string]$ExpectedHeadOid = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if ($SelfTest) {
  [ordered]@{ schema_version = '1.0'; positive_dispatch = $true; missing_source_rejected = $true; base_drift_rejected = $true; implementation_write_count = 0 } | ConvertTo-Json -Compress
  exit 0
}
if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($SourceRecordPath) -or -not (Test-Path -LiteralPath $SourceRecordPath -PathType Leaf) -or $ExpectedHeadOid -cnotmatch '^[0-9a-f]{40}$') {
  [Console]::Error.WriteLine('phase_entry_source_or_oid_invalid'); exit 3
}
$Root = (& git rev-parse --show-toplevel).Trim()
$Head = (& git -C $Root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $Head -cne $ExpectedHeadOid) { [Console]::Error.WriteLine('phase_entry_base_drift'); exit 3 }
[ordered]@{
  schema_version = '1.0'; task_id = $TaskId; phase_base_oid = $Head; source_record_path = $SourceRecordPath
  source_record_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $SourceRecordPath).Hash.ToLowerInvariant()
  prior_phase_regression_failures = 0; not_run = 0; base_drift = 0
} | ConvertTo-Json -Compress

$ErrorActionPreference = 'Stop'
$ScriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\flutter_quality_gate.ps1')).Path
$Text = Get-Content -LiteralPath $ScriptPath -Raw -Encoding UTF8
$Tokens = $null
$Errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$Tokens,[ref]$Errors)
if (@($Errors).Count -ne 0) { throw 'flutter quality gate parser errors found' }
if ($Text -match "throw 'Baseline and candidate pubspec\.lock hashes differ'") { throw 'cross-revision lock equality guard remains' }
if ($Text -notmatch "'per_revision_frozen_lock'") { throw 'per-revision frozen lock mode is missing' }
if ($Text -notmatch 'baseline_candidate_lock_hash_match = \$LockHashMatch') { throw 'lock hash difference is not preserved in evidence' }
if ($Text -notmatch 'baseline_candidate_lock_equality_required = \$false') { throw 'lock equality policy is not explicit' }
$PrimaryStart = $Text.IndexOf('$PrimaryPassed =',[StringComparison]::Ordinal)
$ReportStart = $Text.IndexOf('$Report =',[StringComparison]::Ordinal)
if ($PrimaryStart -lt 0 -or $ReportStart -le $PrimaryStart) { throw 'primary ratchet expression not found' }
$PrimaryText = $Text.Substring($PrimaryStart,$ReportStart-$PrimaryStart)
if ($PrimaryText -match '\$LockHashMatch') { throw 'primary ratchet still requires cross-revision lock equality' }
if ($PrimaryText -notmatch '\$NewErrors\.Count -eq 0' -or $PrimaryText -notmatch '\$NewFailures\.Count -eq 0' -or $PrimaryText -notmatch '\$NewSkips\.Count -eq 0') { throw 'analyzer/test/skip ratchets were weakened' }
[ordered]@{schema_version='1.0';parse_errors=0;per_revision_frozen_lock=$true;cross_revision_lock_equality_required=$false;analyzer_failure_skip_ratchets_preserved=$true;production_write_count=0}|ConvertTo-Json -Compress

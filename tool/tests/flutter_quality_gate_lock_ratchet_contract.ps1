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
if ($Text -notmatch 'function Convert-FlutterMachineVersion') { throw 'Flutter machine version parser is missing' }
if ($Text -notmatch "IndexOf\('\{'\)" -or $Text -notmatch "LastIndexOf\('\}'\)") { throw 'Flutter machine version parser does not bound the JSON object' }
foreach ($RequiredProperty in @('frameworkVersion','channel','frameworkRevision','dartSdkVersion')) {
  if ($Text -notmatch [regex]::Escape("'$RequiredProperty'")) { throw "Flutter machine version property contract is missing: $RequiredProperty" }
}
if ($Text -notmatch 'function Get-BoundedDiagnosticLines') { throw 'bounded Flutter failure diagnostics are missing' }
if ($Text -notmatch 'Select-Object -Last 80') { throw 'Flutter failure diagnostic line bound is missing' }
if ($Text -notmatch 'Substring\(0, 500\)') { throw 'Flutter failure diagnostic character bound is missing' }
foreach ($Redaction in @('Bearer <redacted>','<redacted-access-token>','<redacted-provider-key>','<redacted-private-key-header>')) {
  if ($Text -notmatch [regex]::Escape($Redaction)) { throw "Flutter failure diagnostic redaction is missing: $Redaction" }
}
if ($Text -notmatch "@\('pub','get','--enforce-lockfile'\)") { throw 'Flutter pub lock enforcement is missing' }
if ($Text -notmatch 'function Set-OfficialGradleDistribution' -or $Text -notmatch 'function Restore-GradleDistribution') { throw 'bounded Gradle transport override is missing' }
if ($Text -notmatch 'gradle-8\.13-all\.zip' -or $Text -notmatch 'fba8464465835e74f7270bbf43d6d8a8d7709ab0a43ce1aa3323f73e9aa0c612') { throw 'official Gradle distribution identity is not pinned' }
if ($Text -notmatch 'finally \{ Restore-GradleDistribution \$GradleReceipt \}') { throw 'Gradle wrapper restoration is not fail-safe' }
$PrimaryStart = $Text.IndexOf('$PrimaryPassed =',[StringComparison]::Ordinal)
$ReportStart = $Text.IndexOf('$Report =',[StringComparison]::Ordinal)
if ($PrimaryStart -lt 0 -or $ReportStart -le $PrimaryStart) { throw 'primary ratchet expression not found' }
$PrimaryText = $Text.Substring($PrimaryStart,$ReportStart-$PrimaryStart)
if ($PrimaryText -match '\$LockHashMatch') { throw 'primary ratchet still requires cross-revision lock equality' }
if ($PrimaryText -notmatch '\$NewErrors\.Count -eq 0' -or $PrimaryText -notmatch '\$NewFailures\.Count -eq 0' -or $PrimaryText -notmatch '\$NewSkips\.Count -eq 0') { throw 'analyzer/test/skip ratchets were weakened' }
if ($PrimaryText -notmatch '\$BaselineBuildAccepted' -or $PrimaryText -notmatch '\$CandidateResult\.build\.exit_code -eq 0') { throw 'candidate build or bounded baseline build requirement is missing' }
if ($Text -notmatch [regex]::Escape("`$ImmutableBaselineHead = '142abfc339f003ede8d85d9534336923b5610252'")) { throw 'immutable baseline identity is not pinned' }
if ($Text -notmatch 'LibraryVariantBuilderImpl' -or $Text -notmatch 'amap_flutter_\(base\|map\)-3\\\.0\\\.0' -or $Text -notmatch "The method 'hashValues' isn't defined") { throw 'known immutable baseline failure fingerprint is incomplete' }
if ($Text -notmatch "'unexpected_failure'") { throw 'unknown baseline build failures do not fail closed' }
if ($Text -notmatch 'known_immutable_baseline_build_failure = \$KnownImmutableBaselineBuildFailure' -or $Text -notmatch 'candidate_build_required = \$true') { throw 'baseline exception or candidate build evidence is missing' }
[ordered]@{schema_version='1.0';parse_errors=0;per_revision_frozen_lock=$true;cross_revision_lock_equality_required=$false;analyzer_failure_skip_ratchets_preserved=$true;candidate_build_required=$true;known_baseline_exception_fingerprint_count=3;unknown_baseline_fail_closed=$true;production_write_count=0}|ConvertTo-Json -Compress

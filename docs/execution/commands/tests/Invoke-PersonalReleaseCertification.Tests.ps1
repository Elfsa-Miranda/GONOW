$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $Root 'Invoke-PersonalReleaseCertification.ps1'
$Config = Join-Path $Root 'PersonalReleaseCertification.psd1'
$Schema = Join-Path (Split-Path -Parent $Root) 'schemas\personal-release-certification-v1.schema.json'
foreach ($Path in @($Runner,$Config,$Schema)) { if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "missing certification artifact: $Path" } }
$Data = Import-PowerShellDataFile -LiteralPath $Config
$Profile = $Data.Profiles.ReleaseBDeep
if ((@($Profile.OrderedGates) -join ',') -cne 'C1,C2,C3,C4,C5') { throw 'gate order is not C1..C5' }
if ([int]$Profile.MinimumRealSoakSeconds -ne 14400 -or [int]$Profile.MaximumWallClockSeconds -ne 64800) { throw 'soak or wall-clock contract drifted' }
if ([bool]$Profile.ProductionObservationRequired -or -not [bool]$Profile.AutomatedGateAcceptance) { throw 'personal evidence boundary drifted' }
if ((@($Profile.SupportingReports.C2) -join ',') -cne 'security-matrix.json,performance-cost-report.json,c2-postgresql-load.json,deepseek-v3/live-provider-receipts.json,deepseek-v3/pricing-snapshot.json') { throw 'C2 executable source binding drifted' }
$SchemaDocument = Get-Content -LiteralPath $Schema -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
if ([bool]$SchemaDocument.additionalProperties -or [string]$SchemaDocument.properties.production_observation_required.const -ne 'False') { throw 'schema is not fail closed' }
$Candidate = (& git -C $Root rev-parse HEAD).Trim()
function Invoke-Fixture {
  param([string]$Failure,[int]$ExpectedExit,[string]$ExpectedFailureCode='')
  $Directory = Join-Path ([IO.Path]::GetTempPath()) ('gonow-cert-' + [Guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    $Output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runner -Profile ReleaseBDeep -EvidenceRoot $Directory -CandidateHeadOid $Candidate -SelfTest -SelfTestFailure $Failure)
    $Exit = $LASTEXITCODE
    if ($Exit -ne $ExpectedExit) { throw "fixture $Failure exit=$Exit expected=$ExpectedExit" }
    $Result = Get-Content -LiteralPath (Join-Path $Directory 'personal-release-certification.json') -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if ($ExpectedExit -eq 0) {
      if ([string]$Result.overall_status -cne 'passed' -or [int]$Result.certification_gate_pass_count -ne 5 -or [int]$Result.certification_gate_failure_count -ne 0) { throw 'positive fixture did not pass all gates' }
      if ([bool]$Result.production_observation_required -or -not [bool]$Result.automated_gate_acceptance) { throw 'positive fixture overclaimed production observation' }
    } else {
      $Codes = @($Result.gates | ForEach-Object { @($_.failure_codes) })
      if ([string]$Result.overall_status -ceq 'passed' -or $Codes -notcontains $ExpectedFailureCode) { throw "negative fixture $Failure was not rejected with $ExpectedFailureCode" }
    }
  } finally {
    if (Test-Path -LiteralPath $Directory) { Remove-Item -LiteralPath $Directory -Recurse -Force }
  }
}
Invoke-Fixture -Failure none -ExpectedExit 0
Invoke-Fixture -Failure c1_state_count -ExpectedExit 3 -ExpectedFailureCode state_sequence_count_below_minimum
Invoke-Fixture -Failure c2_live_boundary -ExpectedExit 3 -ExpectedFailureCode live_provider_missing
Invoke-Fixture -Failure c2_redline -ExpectedExit 3 -ExpectedFailureCode cross_tenant_leak_count_nonzero
Invoke-Fixture -Failure c3_slice_size -ExpectedExit 3 -ExpectedFailureCode critical_slice_count_below_minimum
Invoke-Fixture -Failure c4_soak -ExpectedExit 3 -ExpectedFailureCode real_soak_seconds_below_minimum
Invoke-Fixture -Failure c4_isolation -ExpectedExit 3 -ExpectedFailureCode resource_observer_isolation_missing
Invoke-Fixture -Failure c4_source_isolation -ExpectedExit 3 -ExpectedFailureCode c4_soak_execution_contract_invalid
Invoke-Fixture -Failure c5_rollback -ExpectedExit 3 -ExpectedFailureCode rollback_not_passed
Invoke-Fixture -Failure candidate_drift -ExpectedExit 3 -ExpectedFailureCode candidate_oid_mismatch
Invoke-Fixture -Failure enterprise_substitution -ExpectedExit 3 -ExpectedFailureCode governance_profile_invalid
$Text = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
foreach ($Forbidden in @('Invoke-Expression','--force','reset --hard','clean -fdx','production_observation_required=$true')) { if ($Text.Contains($Forbidden)) { throw "forbidden runner marker present: $Forbidden" } }
Write-Output '{"schema_version":"1.0","positive_fixture":true,"negative_fixture_count":10,"gate_order":"C1,C2,C3,C4,C5","minimum_real_soak_seconds":14400,"production_write_count":0}'
exit 0

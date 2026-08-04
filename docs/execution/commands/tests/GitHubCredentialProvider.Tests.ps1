$ErrorActionPreference = 'Stop'
$ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'GitHubCredentialProvider.psm1'
Import-Module -Name $ModulePath -Force -ErrorAction Stop

function Assert-Throws {
  param([scriptblock]$Action,[string]$Expected)
  try { & $Action; throw 'expected_exception_missing' } catch {
    if ($_.Exception.Message -cne $Expected) { throw "unexpected_exception:$($_.Exception.Message)" }
  }
}

$SavedGh = $env:GH_TOKEN
$SavedGitHub = $env:GITHUB_TOKEN
try {
  $env:GH_TOKEN = 'environment-token-value-0001'
  $env:GITHUB_TOKEN = $null
  $Invoked = 0
  $Environment = Get-GitHubApiToken -Required -CredentialInvoker { $script:Invoked++; throw 'must_not_run' }
  if ($Environment -cne 'environment-token-value-0001' -or $Invoked -ne 0) { throw 'environment_precedence_failed' }

  $env:GH_TOKEN = $null
  $env:GITHUB_TOKEN = $null
  $Fixture = [pscustomobject]@{exit_code=0;stdout="protocol=https`nhost=github.com`nusername=fixture-owner`npassword=fixture-token-value-0001`n";stderr=''}
  $Fallback = Get-GitHubApiToken -Required -CredentialInvoker { $Fixture }
  if ($Fallback -cne 'fixture-token-value-0001') { throw 'credential_manager_fallback_failed' }

  $Optional = Get-GitHubApiToken -CredentialInvoker { [pscustomobject]@{exit_code=1;stdout='';stderr='redacted'} }
  if ($null -ne $Optional) { throw 'optional_failure_did_not_return_null' }
  Assert-Throws { Get-GitHubApiToken -Required -MissingErrorCode 'fixture_token_missing' -CredentialInvoker { [pscustomobject]@{exit_code=1;stdout='';stderr='redacted'} } } 'fixture_token_missing'

  foreach ($Invalid in @(
    "protocol=http`nhost=github.com`nusername=u`npassword=fixture-token-value-0001`n",
    "protocol=https`nhost=example.com`nusername=u`npassword=fixture-token-value-0001`n",
    "protocol=https`nhost=github.com`nusername=u`npassword=short`n",
    "protocol=https`nhost=github.com`nusername=u`npassword=fixture token value 0001`n",
    "protocol=https`nhost=github.com`nhost=github.com`nusername=u`npassword=fixture-token-value-0001`n"
  )) {
    if ($null -ne (ConvertFrom-GitHubCredentialFill -Invocation ([pscustomobject]@{exit_code=0;stdout=$Invalid;stderr=''}))) {
      throw 'invalid_credential_fixture_accepted'
    }
  }

  $Source = Get-Content -LiteralPath $ModulePath -Raw -Encoding UTF8
  foreach ($Marker in @('GIT_TERMINAL_PROMPT','GCM_INTERACTIVE','WaitForExit(15000)','RedirectStandardOutput','credential fill')) {
    if (-not $Source.Contains($Marker)) { throw "credential_provider_marker_missing:$Marker" }
  }
} finally {
  $env:GH_TOKEN = $SavedGh
  $env:GITHUB_TOKEN = $SavedGitHub
}

[Console]::Out.WriteLine('GitHubCredentialProvider tests passed')

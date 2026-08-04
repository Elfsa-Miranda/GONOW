Set-StrictMode -Version Latest

function Invoke-GitHubCredentialFill {
  [CmdletBinding()]
  param()

  $Git = Get-Command git.exe -ErrorAction Stop
  $Start = [Diagnostics.ProcessStartInfo]::new()
  $Start.FileName = $Git.Source
  $Start.Arguments = 'credential fill'
  $Start.UseShellExecute = $false
  $Start.RedirectStandardInput = $true
  $Start.RedirectStandardOutput = $true
  $Start.RedirectStandardError = $true
  $Start.CreateNoWindow = $true
  $Start.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
  $Start.EnvironmentVariables['GCM_INTERACTIVE'] = 'Never'

  $Process = [Diagnostics.Process]::new()
  $Process.StartInfo = $Start
  try {
    if (-not $Process.Start()) { throw 'github_credential_process_start_failed' }
    $StandardOutput = $Process.StandardOutput.ReadToEndAsync()
    $StandardError = $Process.StandardError.ReadToEndAsync()
    $Process.StandardInput.Write("protocol=https`nhost=github.com`n`n")
    $Process.StandardInput.Close()
    if (-not $Process.WaitForExit(15000)) {
      try { $Process.Kill() } catch {}
      throw 'github_credential_process_timeout'
    }
    $Process.WaitForExit()
    return [pscustomobject][ordered]@{
      exit_code = [int]$Process.ExitCode
      stdout = [string]$StandardOutput.Result
      stderr = [string]$StandardError.Result
    }
  } finally {
    $Process.Dispose()
  }
}

function ConvertFrom-GitHubCredentialFill {
  [CmdletBinding()]
  param([Parameter(Mandatory = $true)][object]$Invocation)

  if ([int]$Invocation.exit_code -ne 0) { return $null }
  $Fields = [ordered]@{}
  foreach ($Line in @(([string]$Invocation.stdout) -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($Line)) { continue }
    $Separator = $Line.IndexOf('=')
    if ($Separator -le 0) { return $null }
    $Name = $Line.Substring(0,$Separator)
    $Value = $Line.Substring($Separator + 1)
    if ($Fields.Contains($Name)) { return $null }
    $Fields[$Name] = $Value
  }
  if (-not $Fields.Contains('protocol') -or [string]$Fields.protocol -cne 'https' -or
      -not $Fields.Contains('host') -or [string]$Fields.host -cne 'github.com' -or
      -not $Fields.Contains('username') -or [string]::IsNullOrWhiteSpace([string]$Fields.username) -or
      -not $Fields.Contains('password')) { return $null }
  $Token = [string]$Fields.password
  if ($Token.Length -lt 16 -or $Token.Length -gt 8192 -or $Token -match '\s') { return $null }
  return $Token
}

function Get-GitHubApiToken {
  [CmdletBinding()]
  param(
    [switch]$Required,
    [ValidatePattern('^[a-z0-9_]+$')][string]$MissingErrorCode = 'github_api_token_missing',
    [scriptblock]$CredentialInvoker
  )

  foreach ($Name in @('GH_TOKEN','GITHUB_TOKEN')) {
    $Value = [Environment]::GetEnvironmentVariable($Name,'Process')
    if ([string]::IsNullOrWhiteSpace($Value)) { continue }
    if ($Value.Length -lt 16 -or $Value.Length -gt 8192 -or $Value -match '\s') {
      throw 'github_environment_token_invalid'
    }
    return $Value
  }

  $Invocation = $null
  $Token = $null
  try {
    $Invocation = if ($null -ne $CredentialInvoker) { & $CredentialInvoker } else { Invoke-GitHubCredentialFill }
    $Token = ConvertFrom-GitHubCredentialFill -Invocation $Invocation
    if (-not [string]::IsNullOrWhiteSpace($Token)) { return $Token }
  } catch {
    if ($Required) { throw $MissingErrorCode }
    return $null
  } finally {
    $Invocation = $null
    $Token = $null
  }

  if ($Required) { throw $MissingErrorCode }
  return $null
}

Export-ModuleMember -Function Get-GitHubApiToken,ConvertFrom-GitHubCredentialFill

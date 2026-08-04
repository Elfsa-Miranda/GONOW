[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Protocol = 'owner-canary-credential-provider/v1'

function Test-ExactProperties {
  param([object]$Object,[string[]]$Expected)
  if ($null -eq $Object) { return $false }
  return ((@($Object.PSObject.Properties.Name|Sort-Object)-join"`n") -ceq (@($Expected|Sort-Object)-join"`n"))
}

function Read-SingleJson {
  $Raw = [Console]::In.ReadToEnd()
  if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt 16384) { throw 'credential_request_too_large' }
  $Lines = @($Raw-split"`r?`n"|Where-Object{-not[string]::IsNullOrWhiteSpace($_)})
  if ($Lines.Count-ne1) { throw 'credential_request_not_single_json' }
  return $Lines[0]|ConvertFrom-Json -ErrorAction Stop
}

try {
  $Request = Read-SingleJson
  $Expected = @('schema_version','protocol','operation','vault','secret_name','owner_identity_ref_sha256','deadline')
  $Deadline = [DateTimeOffset]::MinValue
  if (-not(Test-ExactProperties $Request $Expected)-or[string]$Request.schema_version-cne'1.0'-or
      [string]$Request.protocol-cne$Protocol-or[string]$Request.operation-cne'resolve_bearer'-or
      [string]$Request.vault-cnotmatch'^[A-Za-z][A-Za-z0-9_.-]{0,63}$'-or
      [string]$Request.secret_name-cnotmatch'^[A-Za-z][A-Za-z0-9_.-]{0,127}$'-or
      [string]$Request.owner_identity_ref_sha256-cnotmatch'^[0-9a-f]{64}$'-or
      -not[DateTimeOffset]::TryParse([string]$Request.deadline,[ref]$Deadline)-or$Deadline-le[DateTimeOffset]::Now) {
    throw 'credential_request_invalid'
  }
  Import-Module Microsoft.PowerShell.SecretManagement -RequiredVersion 1.1.2 -ErrorAction Stop
  Import-Module Microsoft.PowerShell.SecretStore -RequiredVersion 1.0.6 -ErrorAction Stop
  $Vaults = @(Get-SecretVault -Name ([string]$Request.vault) -ErrorAction Stop)
  if ($Vaults.Count-ne1-or[string]$Vaults[0].ModuleName-cne'Microsoft.PowerShell.SecretStore') { throw 'credential_vault_invalid' }
  if (-not(Test-SecretVault -Name ([string]$Request.vault) -ErrorAction Stop)) { throw 'credential_vault_unavailable' }
  $Infos = @(Get-SecretInfo -Name ([string]$Request.secret_name) -Vault ([string]$Request.vault) -ErrorAction Stop)
  if ($Infos.Count-ne1-or$null-eq$Infos[0].Metadata) { throw 'credential_metadata_missing' }
  $ExpiresText = [string]$Infos[0].Metadata['expires_at']
  $OwnerHash = [string]$Infos[0].Metadata['owner_identity_ref_sha256']
  $Expires = [DateTimeOffset]::MinValue
  if (-not[DateTimeOffset]::TryParse($ExpiresText,[ref]$Expires)-or$Expires-lt$Deadline-or$Expires-gt[DateTimeOffset]::Now.AddHours(24)-or
      $OwnerHash-cne[string]$Request.owner_identity_ref_sha256) { throw 'credential_metadata_invalid' }
  $Token = [string](Get-Secret -Name ([string]$Request.secret_name) -Vault ([string]$Request.vault) -AsPlainText -ErrorAction Stop)
  if ($Token.Length-lt16-or$Token.Length-gt8192-or$Token-match'\s') { throw 'credential_value_invalid' }
  $Result = [ordered]@{schema_version='1.0';protocol=$Protocol;status='passed';authorization_scheme='Bearer';access_token=$Token;expires_at=$Expires.ToString('o');owner_identity_ref_sha256=$OwnerHash}
  [Console]::Out.WriteLine(($Result|ConvertTo-Json -Compress))
  exit 0
} catch { exit 10 }

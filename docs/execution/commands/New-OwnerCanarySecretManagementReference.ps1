[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,63}$')][string]$Vault,
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,127}$')][string]$SecretName,
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$')][string]$AllowedHost
)

$ErrorActionPreference = 'Stop'
$ScriptDirectory = Split-Path -Parent $PSCommandPath
$RepositoryRoot = (& git -C $ScriptDirectory rev-parse --show-toplevel 2>$null).Trim()
if ($LASTEXITCODE-ne0-or[string]::IsNullOrWhiteSpace($RepositoryRoot)) { throw 'owner_canary_reference_repository_unavailable' }
$RelativePath = 'docs/execution/commands/Get-OwnerCanarySecretManagementCredential.ps1'
$ProviderPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $RelativePath))
$Tracked = @(& git -C $RepositoryRoot ls-files --cached -- $RelativePath)
if ($LASTEXITCODE-ne0-or$RelativePath-notin$Tracked-or-not(Test-Path -LiteralPath $ProviderPath -PathType Leaf)) { throw 'owner_canary_reference_provider_unavailable' }
$Item = Get-Item -LiteralPath $ProviderPath -Force
if ([bool]($Item.Attributes-band[IO.FileAttributes]::ReparsePoint)) { throw 'owner_canary_reference_provider_reparse_point' }
$Address=$null
if ($AllowedHost-in@('localhost','localhost.localdomain')-or$AllowedHost.EndsWith('.local')-or[Net.IPAddress]::TryParse($AllowedHost,[ref]$Address)) { throw 'owner_canary_reference_allowed_host_invalid' }
$Pwsh = Get-Command pwsh.exe -ErrorAction Stop
& $Pwsh.Source -NoLogo -NoProfile -NonInteractive -Command "Import-Module Microsoft.PowerShell.SecretManagement -RequiredVersion 1.1.2 -ErrorAction Stop; Import-Module Microsoft.PowerShell.SecretStore -RequiredVersion 1.0.6 -ErrorAction Stop" 2>$null
if ($LASTEXITCODE-ne0) { throw 'owner_canary_reference_modules_unavailable' }
$Reference=[ordered]@{schema_version='1.0';provider='powershell-secretmanagement-v1';executable=$ProviderPath;sha256=(Get-FileHash -Algorithm SHA256 -LiteralPath $ProviderPath).Hash.ToLowerInvariant();vault=$Vault;secret_name=$SecretName;allowed_host=$AllowedHost}
[Console]::Out.WriteLine(($Reference|ConvertTo-Json -Compress))
exit 0

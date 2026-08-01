$ErrorActionPreference = 'Stop'
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-IntegrationSmoke.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'positive self-test failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script
if ($LASTEXITCODE -eq 0) { throw 'negative missing merge OID was accepted' }
exit 0

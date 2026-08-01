$ErrorActionPreference = 'Stop'
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-PhaseMerge.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'positive self-test failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -Mode 'Unknown'
if ($LASTEXITCODE -eq 0) { throw 'negative unknown mode was accepted' }
exit 0

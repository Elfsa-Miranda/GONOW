$ErrorActionPreference = 'Stop'
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-PhaseEntryRegression.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -SelfTest
if ($LASTEXITCODE -ne 0) { throw 'positive self-test failed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script -TaskId 'TASK-P00-001'
if ($LASTEXITCODE -eq 0) { throw 'negative missing source was accepted' }
exit 0

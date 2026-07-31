[CmdletBinding()]
param(
  [string]$PythonPath = 'D:\GO_NOW-toolchain\python-3.13.9-locked-venv\Scripts\python.exe',
  [string]$UvPath = 'D:\GO_NOW-toolchain\bin\uv.exe',
  [switch]$SkipDependencySync,
  [switch]$SkipSbom
)

$ErrorActionPreference = 'Stop'
$ServiceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $ServiceRoot '..')).Path
$ServicePython = Join-Path $ServiceRoot '.venv\Scripts\python.exe'
$CycloneDx = Join-Path $ServiceRoot '.venv\Scripts\cyclonedx-py.exe'
$SbomPath = Join-Path $RepoRoot 'docs\execution\supply-chain\phase-02\P02-001\agent-service.cdx.json'

foreach ($RequiredTool in @($PythonPath, $UvPath)) {
  if (-not (Test-Path -LiteralPath $RequiredTool -PathType Leaf)) {
    throw "Required locked tool is unavailable: $RequiredTool"
  }
}

Push-Location $ServiceRoot
try {
  if (-not $SkipDependencySync) {
    & $UvPath sync --frozen --group dev --python $PythonPath
    if ($LASTEXITCODE -ne 0) { throw "uv sync failed with exit code $LASTEXITCODE" }
  }

  if (-not (Test-Path -LiteralPath $ServicePython -PathType Leaf)) {
    throw "Locked service environment is unavailable: $ServicePython"
  }

  & $ServicePython -m compileall -q app
  if ($LASTEXITCODE -ne 0) { throw "compileall failed with exit code $LASTEXITCODE" }

  & $ServicePython -m pytest tests\test_entrypoints.py
  if ($LASTEXITCODE -ne 0) { throw "pytest failed with exit code $LASTEXITCODE" }

  if (-not $SkipSbom) {
    if (-not (Test-Path -LiteralPath $CycloneDx -PathType Leaf)) {
      throw "CycloneDX executable is unavailable: $CycloneDx"
    }
    & $CycloneDx environment --output-format JSON --output-file $SbomPath
    if ($LASTEXITCODE -ne 0) { throw "CycloneDX generation failed with exit code $LASTEXITCODE" }
  }
}
finally {
  Pop-Location
}

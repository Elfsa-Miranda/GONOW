[CmdletBinding()]
param(
  [string]$PythonPath = 'D:\GO_NOW-toolchain\python-3.13.9-locked-venv\Scripts\python.exe',
  [string]$UvPath = 'D:\GO_NOW-toolchain\bin\uv.exe',
  [string]$SbomOutputPath = '',
  [switch]$SkipDependencySync,
  [switch]$SkipSbom
)

$ErrorActionPreference = 'Stop'
$ServiceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $ServiceRoot '..')).Path
$ServicePython = Join-Path $ServiceRoot '.venv\Scripts\python.exe'
$CycloneDx = Join-Path $ServiceRoot '.venv\Scripts\cyclonedx-py.exe'
$HistoricalSbomPath = [IO.Path]::GetFullPath((Join-Path $RepoRoot 'docs\execution\supply-chain\phase-02\P02-001\agent-service.cdx.json'))
$HistoricalSbomRelativePath = 'docs/execution/supply-chain/phase-02/P02-001/agent-service.cdx.json'
$HistoricalSbomBlobOid = '4ace79e826a8cad4232f7c41c3c17afca7e9402c'
$SbomPath = if ([string]::IsNullOrWhiteSpace($SbomOutputPath)) {
  Join-Path $ServiceRoot '.venv\artifacts\agent-service.current.cdx.json'
} elseif ([IO.Path]::IsPathRooted($SbomOutputPath)) {
  [IO.Path]::GetFullPath($SbomOutputPath)
} else {
  [IO.Path]::GetFullPath((Join-Path $RepoRoot $SbomOutputPath))
}
$PreviousPythonUtf8 = $env:PYTHONUTF8

if (-not (Test-Path -LiteralPath $HistoricalSbomPath -PathType Leaf)) {
  throw 'historical_sbom_drift: Phase 2 SBOM is missing'
}
$HistoricalCanonicalOid = (& git -C $RepoRoot hash-object --path $HistoricalSbomRelativePath -- $HistoricalSbomPath).Trim()
if ($LASTEXITCODE -ne 0 -or $HistoricalCanonicalOid -cne $HistoricalSbomBlobOid) {
  throw 'historical_sbom_drift: Phase 2 SBOM does not match its canonical Git blob'
}
if ([IO.Path]::GetFullPath($SbomPath) -ceq $HistoricalSbomPath) {
  throw 'historical_sbom_immutable: current builds must not overwrite the Phase 2 evidence artifact'
}

foreach ($RequiredTool in @($PythonPath, $UvPath)) {
  if (-not (Test-Path -LiteralPath $RequiredTool -PathType Leaf)) {
    throw "Required locked tool is unavailable: $RequiredTool"
  }
}

Push-Location $ServiceRoot
try {
  $env:PYTHONUTF8 = '1'
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
    $SbomDirectory = Split-Path -Parent $SbomPath
    $null = New-Item -ItemType Directory -Path $SbomDirectory -Force
    & $CycloneDx environment --output-reproducible --output-format JSON --output-file $SbomPath
    if ($LASTEXITCODE -ne 0) { throw "CycloneDX generation failed with exit code $LASTEXITCODE" }
  }
}
finally {
  $env:PYTHONUTF8 = $PreviousPythonUtf8
  Pop-Location
  $HistoricalCanonicalOidAfter = if (Test-Path -LiteralPath $HistoricalSbomPath -PathType Leaf) {
    (& git -C $RepoRoot hash-object --path $HistoricalSbomRelativePath -- $HistoricalSbomPath).Trim()
  } else { '' }
  if ($LASTEXITCODE -ne 0 -or $HistoricalCanonicalOidAfter -cne $HistoricalSbomBlobOid) {
    throw 'historical_sbom_drift: build changed immutable Phase 2 evidence'
  }
}

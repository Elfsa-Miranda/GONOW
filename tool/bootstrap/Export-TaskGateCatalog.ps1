[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$CatalogPath,
  [Parameter(Mandatory = $true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Import-CatalogData {
  param([string]$LiteralPath)
  try {
    return Import-PowerShellDataFile -LiteralPath $LiteralPath
  } catch {
    if ($PSVersionTable.PSVersion.Major -ne 5 -or
        $_.Exception.Message -cnotmatch 'dynamic expressions|SafeGetValue') {
      throw
    }
  }
  $Tokens = $null
  $ParseErrors = $null
  $Ast = [Management.Automation.Language.Parser]::ParseFile(
    $LiteralPath, [ref]$Tokens, [ref]$ParseErrors
  )
  if (@($ParseErrors).Count -ne 0 -or $Ast.EndBlock.Statements.Count -ne 1) {
    throw 'Catalog AST parse failed'
  }
  $Root = $Ast.EndBlock.Statements[0].PipelineElements[0].Expression
  if ($Root -isnot [Management.Automation.Language.HashtableAst]) {
    throw 'Catalog root must be a hashtable literal'
  }
  $Catalog = @{}
  foreach ($Pair in $Root.KeyValuePairs) {
    $Key = [string]$Pair.Item1.SafeGetValue()
    if ($Key -cne 'Tasks') {
      $Catalog[$Key] = $Pair.Item2.SafeGetValue()
      continue
    }
    $TasksExpression = $Pair.Item2.PipelineElements[0].Expression
    $Tasks = @{}
    foreach ($TaskPair in $TasksExpression.KeyValuePairs) {
      $Tasks[[string]$TaskPair.Item1.SafeGetValue()] = $TaskPair.Item2.SafeGetValue()
    }
    $Catalog[$Key] = $Tasks
  }
  return $Catalog
}

function ConvertTo-OrdinalObject {
  param([object]$Value)
  if ($Value -is [Collections.IDictionary]) {
    $Result = [ordered]@{}
    foreach ($Key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object -CaseSensitive)) {
      $Result[$Key] = ConvertTo-OrdinalObject $Value[$Key]
    }
    return $Result
  }
  if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
    $ArrayValue = @($Value | ForEach-Object { ConvertTo-OrdinalObject $_ })
    return ,$ArrayValue
  }
  return $Value
}

$Catalog = Import-CatalogData -LiteralPath $CatalogPath
$Canonical = ConvertTo-OrdinalObject $Catalog
$Parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $Parent)) {
  New-Item -ItemType Directory -Path $Parent -Force | Out-Null
}
$Temporary = "$OutputPath.$([Guid]::NewGuid().ToString('N')).tmp"
try {
  [IO.File]::WriteAllText(
    $Temporary,
    ($Canonical | ConvertTo-Json -Depth 40 -Compress),
    [Text.UTF8Encoding]::new($false)
  )
  if (Test-Path -LiteralPath $OutputPath) {
    throw "Output already exists: $OutputPath"
  }
  [IO.File]::Move($Temporary, $OutputPath)
} finally {
  if (Test-Path -LiteralPath $Temporary) {
    Remove-Item -LiteralPath $Temporary -Force
  }
}

[ordered]@{
  schema_version = '1.0'
  catalog_entries = @($Catalog.Tasks.Keys).Count
  taskgate_mode_count = @($Catalog.TaskGateModeContracts.Keys).Count
  phase_merge_mode_count = @($Catalog.PhaseMergeModeContracts.Keys).Count
  output_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutputPath).Hash.ToLowerInvariant()
} | ConvertTo-Json

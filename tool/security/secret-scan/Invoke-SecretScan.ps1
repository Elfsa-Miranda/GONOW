[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('worktree','history','artifact')]
  [string]$Mode,

  [Parameter(Mandatory = $true)]
  [string]$Repo,

  [Parameter(Mandatory = $true)]
  [string]$Output,

  [string]$Registry,
  [string]$Artifact,
  [string]$KnownFingerprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ScannerVersion = '1.0.0'
$script:Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-Sha256Hex {
  param([byte[]]$Bytes)
  $Hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
  }
  finally {
    $Hasher.Dispose()
  }
}

function Get-FileSha256Hex {
  param([string]$Path)
  return Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($Path))
}

function Get-RuleSet {
  param([string]$Path)
  $Rules = New-Object System.Collections.Generic.List[object]
  $Current = $null
  foreach ($RawLine in [System.IO.File]::ReadAllLines($Path, $script:Utf8NoBom)) {
    $Line = $RawLine.Trim()
    if ($Line -eq '[[rule]]') {
      if ($null -ne $Current) { $Rules.Add([pscustomobject]$Current) }
      $Current = [ordered]@{ id = $null; pattern = $null; classification = $null; ignore_case = $false }
      continue
    }
    if ($null -eq $Current -or $Line.Length -eq 0 -or $Line.StartsWith('#')) { continue }
    if ($Line -match "^(id|pattern|classification)\s*=\s*'(.*)'$") {
      $Current[$Matches[1]] = $Matches[2]
      continue
    }
    if ($Line -match '^ignore_case\s*=\s*(true|false)$') {
      $Current.ignore_case = $Matches[1] -ceq 'true'
    }
  }
  if ($null -ne $Current) { $Rules.Add([pscustomobject]$Current) }
  if ($Rules.Count -eq 0 -or @($Rules | Where-Object { [string]::IsNullOrWhiteSpace($_.id) -or [string]::IsNullOrWhiteSpace($_.pattern) }).Count -ne 0) {
    throw 'Invalid or empty secret scanner rule set'
  }
  return $Rules.ToArray()
}

function Invoke-GitText {
  param([string]$Repository, [string[]]$Arguments)
  $OutputLines = @(& git -C $Repository @Arguments)
  if ($LASTEXITCODE -ne 0) { throw "git command failed with exit $LASTEXITCODE" }
  return @($OutputLines)
}

function Read-GitBlobBytes {
  param([string]$Repository, [string]$Oid)
  $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $StartInfo.FileName = 'git'
  $StartInfo.Arguments = "-C `"$Repository`" cat-file blob $Oid"
  $StartInfo.UseShellExecute = $false
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true
  $Process = New-Object System.Diagnostics.Process
  $Process.StartInfo = $StartInfo
  if (-not $Process.Start()) { throw 'Unable to start git cat-file' }
  $Buffer = New-Object System.IO.MemoryStream
  try {
    $Process.StandardOutput.BaseStream.CopyTo($Buffer)
    $ErrorText = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()
    if ($Process.ExitCode -ne 0) {
      $ErrorHash = Get-Sha256Hex $script:Utf8NoBom.GetBytes($ErrorText)
      throw "git cat-file failed; stderr_sha256=$ErrorHash"
    }
    return ,$Buffer.ToArray()
  }
  finally {
    $Buffer.Dispose()
    $Process.Dispose()
  }
}

function Find-RedactedMatches {
  param(
    [byte[]]$Bytes,
    [string]$Location,
    [object[]]$Rules,
    [string]$BlobOid
  )
  $Findings = New-Object System.Collections.Generic.List[object]
  $Text = $script:Latin1.GetString($Bytes)
  $Lines = [regex]::Split($Text, '\r?\n')
  for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
    foreach ($Rule in $Rules) {
      $Options = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
      if ($Rule.ignore_case) { $Options = $Options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
      foreach ($Match in [regex]::Matches($Lines[$Index], $Rule.pattern, $Options)) {
        $Finding = [ordered]@{
          path = $Location
          line = $Index + 1
          rule_id = $Rule.id
          classification = $Rule.classification
          fingerprint_sha256 = Get-Sha256Hex $script:Latin1.GetBytes($Match.Value)
        }
        if (-not [string]::IsNullOrWhiteSpace($BlobOid)) { $Finding.blob_oid = $BlobOid }
        $Findings.Add([pscustomobject]$Finding)
      }
    }
  }
  return $Findings.ToArray()
}

function Get-CompletePrivateKeyCount {
  param([byte[]]$Bytes)
  $Text = $script:Latin1.GetString($Bytes)
  $Pattern = '-----BEGIN ([A-Z ]*PRIVATE KEY)-----\r?\n(?:[A-Za-z0-9+/=]{16,}\r?\n)+-----END \1-----'
  return [regex]::Matches($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
}

function Sort-Findings {
  param([object[]]$Findings)
  return @($Findings | Sort-Object path,blob_oid,line,rule_id -Unique)
}

function Get-OccurrenceKey {
  param([object]$Finding)
  return '{0}|{1}|{2}|{3}' -f $Finding.blob_oid,$Finding.path,$Finding.line,$Finding.rule_id
}

function Invoke-WorktreeScan {
  param([string]$Repository, [object[]]$Rules)
  $Findings = New-Object System.Collections.Generic.List[object]
  $Scanned = 0
  $CompletePrivateKeys = 0
  foreach ($RelativePath in Invoke-GitText $Repository @('ls-files')) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { continue }
    $Path = Join-Path $Repository $RelativePath
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { continue }
    $Scanned++
    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    if (($RelativePath -replace '\\','/') -match '(^|/)(?:\.env(?:$|\.)|id_rsa$|id_ed25519$|.*\.(?:pem|key|p12|pfx)$)') {
      $Findings.Add([pscustomobject][ordered]@{
        path = $RelativePath
        line = 0
        rule_id = 'sensitive-filename'
        classification = 'sensitive_filename'
        fingerprint_sha256 = Get-Sha256Hex $script:Utf8NoBom.GetBytes($RelativePath)
      })
    }
    foreach ($Finding in Find-RedactedMatches $Bytes $RelativePath $Rules '') { $Findings.Add($Finding) }
    $CompletePrivateKeys += Get-CompletePrivateKeyCount $Bytes
  }
  [object[]]$Sorted = @(Sort-Findings $Findings.ToArray())
  $Valid = @($Sorted | Where-Object { $_.rule_id -cne 'private-key-header' }).Count + $CompletePrivateKeys
  return [ordered]@{
    mode = 'worktree'
    scanned_file_count = $Scanned
    finding_count = $Sorted.Count
    valid_secret_finding_count = $Valid
    complete_private_key_block_count = $CompletePrivateKeys
    findings = $Sorted
    untracked_file_read_count = 0
  }
}

function Invoke-HistoryScan {
  param([string]$Repository, [object[]]$Rules, [string]$RegistryPath)
  $Findings = New-Object System.Collections.Generic.List[object]
  $ScannedBlobs = 0
  $ObjectPathCount = 0
  $CompletePrivateKeys = 0
  foreach ($Line in Invoke-GitText $Repository @('rev-list','--objects','--all')) {
    $Parts = $Line -split ' ', 2
    if ($Parts.Count -ne 2) { continue }
    $ObjectPathCount++
    $Oid = $Parts[0]
    $Path = $Parts[1]
    $Type = (Invoke-GitText $Repository @('cat-file','-t',$Oid) | Select-Object -First 1)
    if ($Type -cne 'blob') { continue }
    $ScannedBlobs++
    $Bytes = Read-GitBlobBytes $Repository $Oid
    foreach ($Finding in Find-RedactedMatches $Bytes $Path $Rules $Oid) { $Findings.Add($Finding) }
    $CompletePrivateKeys += Get-CompletePrivateKeyCount $Bytes
  }
  [object[]]$Sorted = @(Sort-Findings $Findings.ToArray())
  $ObservedKeys = @($Sorted | ForEach-Object { Get-OccurrenceKey $_ } | Sort-Object -Unique)
  $ObservedCanonical = [string]::Join("`n", $ObservedKeys)
  $ObservedHash = Get-Sha256Hex $script:Utf8NoBom.GetBytes($ObservedCanonical)
  $NewHistoryFindings = $null
  $RegistryMismatch = $null
  $RegistrySha256 = $null
  $ExpectedOccurrenceHash = $null
  if (-not [string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistrySha256 = Get-FileSha256Hex $RegistryPath
    $RegistryObject = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ExpectedKeys = @($RegistryObject.occurrences | ForEach-Object { Get-OccurrenceKey $_ } | Sort-Object -Unique)
    $ExpectedOccurrenceHash = [string]$RegistryObject.occurrence_set_sha256
    $NewHistoryFindings = @($ObservedKeys | Where-Object { $_ -cnotin $ExpectedKeys }).Count
    $RegistryMismatch = [int](
      $ObservedKeys.Count -ne $ExpectedKeys.Count -or
      [string]::Join("`n", $ObservedKeys) -cne [string]::Join("`n", $ExpectedKeys)
    )
  }
  return [ordered]@{
    mode = 'history'
    reachable_object_path_count = $ObjectPathCount
    scanned_blob_count = $ScannedBlobs
    finding_count = $Sorted.Count
    complete_private_key_block_count = $CompletePrivateKeys
    observed_occurrence_set_sha256 = $ObservedHash
    occurrence_set_sha256 = $ExpectedOccurrenceHash
    new_history_findings = $NewHistoryFindings
    historical_revoked_registry_mismatch = $RegistryMismatch
    registry_sha256 = $RegistrySha256
    findings = $Sorted
    untracked_file_read_count = 0
  }
}

function Invoke-ArtifactScan {
  param([string]$ArtifactPath, [object[]]$Rules, [string]$Fingerprint)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Findings = New-Object System.Collections.Generic.List[object]
  $Members = 0
  [long]$BytesScanned = 0
  $CompletePrivateKeys = 0
  $Resolved = (Resolve-Path -LiteralPath $ArtifactPath).Path
  $Items = New-Object System.Collections.Generic.List[object]
  $IsDirectory = Test-Path -LiteralPath $Resolved -PathType Container
  if ($IsDirectory) {
    foreach ($File in Get-ChildItem -LiteralPath $Resolved -Recurse -File | Sort-Object FullName) {
      $Relative = $File.FullName.Substring($Resolved.TrimEnd('\').Length + 1) -replace '\\','/'
      $Items.Add([pscustomobject]@{ name = $Relative; bytes = [System.IO.File]::ReadAllBytes($File.FullName) })
    }
  }
  elseif ([System.IO.Path]::GetExtension($Resolved) -in @('.zip','.apk')) {
    $Archive = [System.IO.Compression.ZipFile]::OpenRead($Resolved)
    try {
      foreach ($Entry in $Archive.Entries) {
        if ([string]::IsNullOrEmpty($Entry.Name)) { continue }
        $Stream = $Entry.Open()
        $Buffer = New-Object System.IO.MemoryStream
        try {
          $Stream.CopyTo($Buffer)
          $Items.Add([pscustomobject]@{ name = $Entry.FullName; bytes = $Buffer.ToArray() })
        }
        finally {
          $Buffer.Dispose()
          $Stream.Dispose()
        }
      }
    }
    finally { $Archive.Dispose() }
  }
  else {
    $Items.Add([pscustomobject]@{ name = [System.IO.Path]::GetFileName($Resolved); bytes = [System.IO.File]::ReadAllBytes($Resolved) })
  }
  foreach ($Item in $Items) {
    $Members++
    $BytesScanned += $Item.bytes.Length
    foreach ($Finding in Find-RedactedMatches $Item.bytes $Item.name $Rules '') { $Findings.Add($Finding) }
    $CompletePrivateKeys += Get-CompletePrivateKeyCount $Item.bytes
  }
  [object[]]$Sorted = @(Sort-Findings $Findings.ToArray())
  $Valid = @($Sorted | Where-Object { $_.rule_id -cne 'private-key-header' }).Count + $CompletePrivateKeys
  return [ordered]@{
    mode = 'artifact'
    artifact = $Resolved
    artifact_size_bytes = if ($IsDirectory) { $BytesScanned } else { (Get-Item -LiteralPath $Resolved).Length }
    artifact_sha256 = if ($IsDirectory) { $null } else { Get-FileSha256Hex $Resolved }
    member_count = $Members
    bytes_scanned = $BytesScanned
    finding_count = $Sorted.Count
    valid_secret_finding_count = $Valid
    complete_private_key_block_count = $CompletePrivateKeys
    known_fingerprint_match_count = if ([string]::IsNullOrWhiteSpace($Fingerprint)) { $null } else { @($Sorted | Where-Object { $_.fingerprint_sha256 -ceq $Fingerprint }).Count }
    findings = $Sorted
    untracked_file_read_count = 0
  }
}

$Repository = (Resolve-Path -LiteralPath $Repo).Path
$RulesPath = Join-Path $PSScriptRoot 'rules.toml'
$Rules = Get-RuleSet $RulesPath
switch ($Mode) {
  'worktree' { $Detail = Invoke-WorktreeScan $Repository $Rules }
  'history' {
    $RegistryPath = if ([string]::IsNullOrWhiteSpace($Registry)) { '' } else { (Resolve-Path -LiteralPath $Registry).Path }
    $Detail = Invoke-HistoryScan $Repository $Rules $RegistryPath
  }
  'artifact' {
    if ([string]::IsNullOrWhiteSpace($Artifact)) { throw '-Artifact is required in artifact mode' }
    $Detail = Invoke-ArtifactScan $Artifact $Rules $KnownFingerprint
  }
}

$Report = [ordered]@{
  schema_version = '1.0'
  scanner = 'gonow-redacted-secret-scan'
  scanner_version = $script:ScannerVersion
  generated_at = [DateTimeOffset]::UtcNow.ToString('o')
}
foreach ($Key in $Detail.Keys) { $Report[$Key] = $Detail[$Key] }
$Report.secret_value_output_count = 0
$Report.production_write_count = 0
$OutputPath = [System.IO.Path]::GetFullPath($Output)
$OutputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
$Json = $Report | ConvertTo-Json -Depth 12 -Compress
[System.IO.File]::WriteAllText($OutputPath, $Json, $script:Utf8NoBom)

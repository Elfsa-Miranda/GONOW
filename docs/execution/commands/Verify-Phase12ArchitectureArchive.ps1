[CmdletBinding()]
param(
  [ValidatePattern('^[0-9a-f]{40}$')]
  [string]$BaseOid = '5c3031da4b0df7d1e97af47630e141726502894b',
  [string]$OutputPath = 'docs/execution/evidence/phase-12/P12-089/archive-gate-runtime.json',
  [switch]$Bootstrap
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $RepositoryRoot
try {
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  function Invoke-GitLines {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& git -c core.safecrlf=false @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      throw "git $($Arguments -join ' ') failed with exit $exitCode"
    }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $output) {
      foreach ($line in ([string]$entry -split "`r?`n")) {
        if ($line.Length -gt 0) { $lines.Add($line) }
      }
    }
    return $lines.ToArray()
  }

  function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $LiteralPath).Hash.ToLowerInvariant()
  }

  function Write-AtomicJson {
    param(
      [Parameter(Mandatory = $true)][string]$LiteralPath,
      [Parameter(Mandatory = $true)]$Value
    )
    $absolute = if ([IO.Path]::IsPathRooted($LiteralPath)) { $LiteralPath } else { Join-Path $RepositoryRoot $LiteralPath }
    $directory = Split-Path -Parent $absolute
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($absolute) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 12) + "`n"), $Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $absolute -Force
  }

  $headOid = (@(Invoke-GitLines @('rev-parse', 'HEAD')))[0].Trim()
  $objectFormat = (@(Invoke-GitLines @('rev-parse', '--show-object-format')))[0].Trim()
  $null = Invoke-GitLines @('cat-file', '-e', "$BaseOid^{commit}")

  $coreArtifacts = @(
    'README.md',
    'docs/architecture/release-c-selection.md',
    'docs/runbooks/release-c-governance.md',
    'docs/api/release-c-selection.md',
    'docs/architecture/threat-model/phase-12-review.json',
    'docs/execution/evidence/phase-12/change-summary.md',
    'docs/execution/evidence/phase-12/knowledge-transfer.md',
    'docs/execution/evidence/phase-12/star-records.md',
    'docs/execution/evidence/phase-12/improvements/STAR-xor-safe-architecture-archive.md',
    'docs/execution/blockers/phase-12/BLK-P12-089-formal-xor-selection-pending.md',
    'docs/execution/blockers/phase-12/BLK-P12-089-archive-gate-line-normalization.md',
    'docs/execution/commands/Verify-Phase12ArchitectureArchive.ps1'
  )
  $evidenceArtifacts = @(
    'docs/execution/evidence/phase-12/artifact-manifest.premerge.json',
    'docs/execution/evidence/phase-12/P12-089/provisional-runtime-manifest.json',
    'docs/execution/evidence/phase-12/P12-089/provisional-archive-status.json',
    'docs/execution/evidence/phase-12/P12-089/handoff-verification.json',
    'docs/execution/evidence/phase-12/P12-089/commands.json',
    'docs/execution/evidence/phase-12/P12-089/gate-results.json',
    'docs/execution/evidence/phase-12/P12-089/artifact-hashes.json',
    'docs/execution/status/TASK-P12A-000.json',
    'docs/execution/status/TASK-P12B-000.json',
    'docs/execution/status/TASK-P12D-000.json',
    'docs/execution/evidence/phase-12a/P12A-000/gate-results.json',
    'docs/execution/evidence/phase-12b/P12B-000/gate-results.json',
    'docs/execution/evidence/phase-12d/P12D-000/gate-results.json',
    'docs/execution/evidence/phase-12/ABD-PORTFOLIO/gate-results.json'
  )
  $requiredArtifacts = if ($Bootstrap) { $coreArtifacts } else { @($coreArtifacts + $evidenceArtifacts) }
  $missingArtifacts = @($requiredArtifacts | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })

  $markerContract = [ordered]@{
    'docs/architecture/release-c-selection.md' = @(
      'formal_selection_status: pending',
      'selected_count: 0',
      'formal_none_decision: false',
      'design_ready_count: 3',
      'runtime_change_count: 0',
      'public_contract_change_count: 0',
      'production_write_count: 0',
      'multi_agent_implementation_count: 0',
      '## 12A: explicit structured Memory',
      '## 12B: deterministic cost router',
      '## 12D: one Domain Command migration',
      '## 12C: Multi-Agent explicitly deferred'
    )
    'docs/runbooks/release-c-governance.md' = @(
      'There is no enable command for the provisional archive.',
      '`codex/gonow-agent-landing`',
      'Never push a Phase branch directly to `main`'
    )
    'docs/api/release-c-selection.md' = @(
      'runtime_change_count: 0',
      'public_contract_change_count: 0',
      'schema_change_count: 0',
      'implementation_commit_count: 0',
      'production_write_count: 0'
    )
    'docs/execution/evidence/phase-12/star-records.md' = @(
      'Capability existence:',
      'Behavior evidence:',
      'Governance evidence:'
    )
  }
  $markerGaps = New-Object System.Collections.Generic.List[string]
  foreach ($entry in $markerContract.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Key -PathType Leaf)) { continue }
    $text = Get-Content -LiteralPath $entry.Key -Raw -Encoding UTF8
    foreach ($marker in $entry.Value) {
      if (-not $text.Contains([string]$marker)) {
        $markerGaps.Add("$($entry.Key)::$marker")
      }
    }
  }

  $jsonPaths = @($requiredArtifacts | Where-Object { $_.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $_ -PathType Leaf) })
  $jsonParseErrors = New-Object System.Collections.Generic.List[string]
  foreach ($path in $jsonPaths) {
    try { $null = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { $jsonParseErrors.Add($path) }
  }

  $semanticReceiptErrors = New-Object System.Collections.Generic.List[string]
  if (-not $Bootstrap) {
    $status = Get-Content -LiteralPath 'docs/execution/evidence/phase-12/P12-089/provisional-archive-status.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    $handoff = Get-Content -LiteralPath 'docs/execution/evidence/phase-12/P12-089/handoff-verification.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    $threat = Get-Content -LiteralPath 'docs/architecture/threat-model/phase-12-review.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath 'docs/execution/evidence/phase-12/artifact-manifest.premerge.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    $portfolioGate = Get-Content -LiteralPath 'docs/execution/evidence/phase-12/ABD-PORTFOLIO/gate-results.json' -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$status.archive_status -cne 'ready_for_review') { $semanticReceiptErrors.Add('status.archive_status') }
    if ([string]$status.formal_task_status -cne 'not_started') { $semanticReceiptErrors.Add('status.formal_task_status') }
    if ([string]$status.formal_selection_status -cne 'pending') { $semanticReceiptErrors.Add('status.formal_selection_status') }
    if ([int]$status.selected_count -ne 0 -or [bool]$status.formal_none_decision) { $semanticReceiptErrors.Add('status.xor_boundary') }
    if ([int]$status.design_ready_count -ne 3 -or [int]$status.atomic_task_count -ne 18) { $semanticReceiptErrors.Add('status.design_readiness') }
    if ([string]$status.local_gate_status -cne 'passed') { $semanticReceiptErrors.Add('status.local_gate_status') }
    if ([string]$handoff.local_self_review_status -cne 'passed') { $semanticReceiptErrors.Add('handoff.local_self_review_status') }
    if (-not [bool]$handoff.readable -or -not [bool]$handoff.accurate_to_current_diff -or -not [bool]$handoff.contract_synced) { $semanticReceiptErrors.Add('handoff.document_assertions') }
    if (-not [bool]$handoff.reviewer_is_implementer -or [bool]$handoff.formal_handoff -or [bool]$handoff.accepted) { $semanticReceiptErrors.Add('handoff.governance_boundary') }
    if ([string]$threat.formal_selection_status -cne 'pending' -or [int]$threat.selected_count -ne 0 -or [bool]$threat.formal_none_decision -or [int]$threat.design_ready_count -ne 3) { $semanticReceiptErrors.Add('threat.xor_boundary') }
    if ([int]$manifest.candidate_disposition_coverage.numerator -ne 4 -or [int]$manifest.candidate_disposition_coverage.denominator -ne 4 -or [int]$manifest.design_ready_count -ne 3) { $semanticReceiptErrors.Add('manifest.coverage') }
    if ([string]$portfolioGate.overall_status -cne 'passed' -or [int]$portfolioGate.checks.design_ready_count -ne 3 -or [int]$portfolioGate.checks.formal_selected_count -ne 0) { $semanticReceiptErrors.Add('abd_portfolio.gate') }
    foreach ($task in @('P12A','P12B','P12D')) {
      $designStatus = Get-Content -LiteralPath "docs/execution/status/TASK-$task-000.json" -Raw -Encoding UTF8 | ConvertFrom-Json
      if ([string]$designStatus.status -cne 'ready_for_review' -or [string]$designStatus.design_scope -cne 'dormant_only' -or [string]$designStatus.formal_task_status -cne 'not_started' -or [bool]$designStatus.selected -or [int]$designStatus.implementation_commit_count -ne 0) {
        $semanticReceiptErrors.Add("$task.design_boundary")
      }
    }
  }

  $hashIndexErrors = New-Object System.Collections.Generic.List[string]
  if (-not $Bootstrap) {
    foreach ($indexPath in @(
      'docs/execution/evidence/phase-12/artifact-manifest.premerge.json',
      'docs/execution/evidence/phase-12/P12-089/artifact-hashes.json',
      'docs/execution/evidence/phase-12a/P12A-000/artifact-hashes.json',
      'docs/execution/evidence/phase-12b/P12B-000/artifact-hashes.json',
      'docs/execution/evidence/phase-12d/P12D-000/artifact-hashes.json',
      'docs/execution/evidence/phase-12/ABD-PORTFOLIO/artifact-hashes.json'
    )) {
      $index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($artifact in @($index.artifacts)) {
        $path = [string]$artifact.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
          $hashIndexErrors.Add("$indexPath::$path::missing")
          continue
        }
        $actualHash = Get-Sha256 $path
        $actualSize = [long](Get-Item -LiteralPath $path).Length
        if ($actualHash -cne [string]$artifact.sha256) { $hashIndexErrors.Add("$indexPath::$path::sha256") }
        if ($actualSize -ne [long]$artifact.size_bytes) { $hashIndexErrors.Add("$indexPath::$path::size") }
      }
    }
  }

  $forbiddenFormalArtifacts = @(
    'docs/architecture/adr/ADR-release-c-phase12-selected.md',
    'docs/architecture/adr/ADR-P12C-000-multi-agent-work-package.md',
    'docs/execution/evidence/phase-12/P12-000',
    'docs/execution/evidence/phase-12/P12-001',
    'docs/execution/evidence/phase-12/P12-002',
    'docs/execution/evidence/phase-12/P12C-000',
    'docs/execution/evidence/phase-12c',
    'docs/execution/status/TASK-P12-000.json',
    'docs/execution/status/TASK-P12-001.json',
    'docs/execution/status/TASK-P12-002.json',
    'docs/execution/status/TASK-P12C-000.json',
    'docs/execution/status/TASK-P12-089.json'
  )
  $materializedFormalArtifacts = @($forbiddenFormalArtifacts | Where-Object { Test-Path -LiteralPath $_ })

  $allRefs = @(Invoke-GitLines @('for-each-ref', '--format=%(refname)', 'refs/heads'))
  $specialistRefPattern = '^refs/heads/codex/(release-c-governance|phase-12(?:[abcd])?(?:$|[-/]))'
  $specialistRefs = @($allRefs | Where-Object { $_ -cmatch $specialistRefPattern })
  $worktreeLines = @(Invoke-GitLines @('worktree', 'list', '--porcelain'))
  $specialistWorktrees = @($worktreeLines | Where-Object {
    $_ -cmatch '^branch refs/heads/codex/(release-c-governance|phase-12(?:[abcd])?(?:$|[-/]))'
  })

  $changedTracked = @(Invoke-GitLines @('diff', '--name-only', $BaseOid, '--'))
  $addedTracked = @(Invoke-GitLines @('diff', '--diff-filter=A', '--name-only', $BaseOid, '--'))
  $untracked = @(Invoke-GitLines @('ls-files', '--others', '--exclude-standard'))
  $fullWhitespaceScanPaths = @(@($addedTracked) + @($untracked) | Sort-Object -Unique)
  $changedPaths = @(@($changedTracked) + @($untracked) | Where-Object { $_ } | Sort-Object -Unique)
  $allowedExact = @(
    'README.md',
    'docs/architecture/release-c-selection.md',
    'docs/runbooks/release-c-governance.md',
    'docs/api/release-c-selection.md',
    'docs/architecture/threat-model/phase-12-review.json',
    'docs/execution/commands/Verify-Phase12ArchitectureArchive.ps1',
    'docs/execution/commands/Verify-Phase12DormantAbdPortfolio.ps1',
    'docs/architecture/adr/ADR-P12A-000-memory-work-package.md',
    'docs/architecture/adr/ADR-P12B-000-cost-router-work-package.md',
    'docs/architecture/adr/ADR-P12D-000-domain-command-work-package.md',
    'docs/execution/status/TASK-P12A-000.json',
    'docs/execution/status/TASK-P12B-000.json',
    'docs/execution/status/TASK-P12D-000.json',
    'docs/execution/blockers/phase-12/BLK-P12-089-formal-xor-selection-pending.md'
  )
  $unexpectedPaths = @($changedPaths | Where-Object {
    $_ -notin $allowedExact -and
    $_ -cnotmatch '^docs/execution/evidence/phase-12/' -and
    $_ -cnotmatch '^docs/execution/evidence/phase-12[abd]/P12[ABD]-000/' -and
    $_ -cnotmatch '^docs/execution/blockers/phase-12/BLK-P12-089-[a-z0-9-]+\.md$'
  })
  $implementationPathPattern = '^(agent-service/|lib/|test/|integration_test/|contracts/|supabase/|android/|ios/|web/|pubspec\.(yaml|lock)$)'
  $implementationChanges = @($changedPaths | Where-Object { $_ -cmatch $implementationPathPattern })
  $publicContractChanges = @($changedPaths | Where-Object { $_ -cmatch '^(contracts/|lib/.+\.g\.dart$|docs/api/(?!release-c-selection\.md$))' })

  $secretFindings = New-Object System.Collections.Generic.List[string]
  $unsafeCommandFindings = New-Object System.Collections.Generic.List[string]
  $whitespaceFindings = New-Object System.Collections.Generic.List[string]
  $scanPatterns = @(
    '(?i)sk-[a-z0-9]{20,}',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',
    '(?i)bearer\s+eyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+'
  )
  $unsafePatterns = @(
    '(?im)^\s*git\s+reset\s+--hard\b',
    '(?im)^\s*git\s+clean\s+-[^\r\n]*f',
    '(?im)^\s*(rm\s+-rf|Remove-Item\s+.+-Recurse.+-Force)\b'
  )
  foreach ($path in $changedPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    foreach ($pattern in $scanPatterns) {
      if ($content -match $pattern) { $secretFindings.Add("$path::$pattern") }
    }
    foreach ($pattern in $unsafePatterns) {
      if ($content -match $pattern) { $unsafeCommandFindings.Add("$path::$pattern") }
    }
    if ($path -in $fullWhitespaceScanPaths -and ($content -cmatch '(?m)[ \t]+$' -or $content -cmatch '(\r?\n){2}$')) { $whitespaceFindings.Add($path) }
  }

  $linkedPaths = @(
    'docs/architecture/release-c-selection.md',
    'docs/runbooks/release-c-governance.md',
    'docs/api/release-c-selection.md',
    'docs/execution/evidence/phase-12/P12-089/artifact-hashes.json'
  )
  $brokenLinkedPaths = @($linkedPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })

  $diffCheckOutput = @(& git -c core.safecrlf=false diff --check $BaseOid -- 2>&1)
  $diffCheckExitCode = $LASTEXITCODE

  $artifactEntries = @()
  foreach ($path in $requiredArtifacts) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $item = Get-Item -LiteralPath $path
      $artifactEntries += [ordered]@{ path = $path; sha256 = Get-Sha256 $path; size_bytes = [long]$item.Length }
    }
  }
  $digestInput = ($artifactEntries | ForEach-Object { "$($_.path)`t$($_.sha256)`t$($_.size_bytes)" }) -join "`n"
  $digestBytes = [Text.Encoding]::UTF8.GetBytes($digestInput)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $archiveDigest = ([BitConverter]::ToString($sha.ComputeHash($digestBytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }

  $checks = [ordered]@{
    required_artifact_count = $requiredArtifacts.Count
    missing_artifact_count = $missingArtifacts.Count
    missing_artifacts = @($missingArtifacts)
    marker_gap_count = $markerGaps.Count
    marker_gaps = @($markerGaps)
    json_parse_error_count = $jsonParseErrors.Count
    json_parse_errors = @($jsonParseErrors)
    semantic_receipt_error_count = $semanticReceiptErrors.Count
    semantic_receipt_errors = @($semanticReceiptErrors)
    hash_index_error_count = $hashIndexErrors.Count
    hash_index_errors = @($hashIndexErrors)
    formal_candidate_artifact_count = $materializedFormalArtifacts.Count
    formal_candidate_artifacts = @($materializedFormalArtifacts)
    specialist_ref_count = $specialistRefs.Count
    specialist_refs = @($specialistRefs)
    specialist_worktree_count = $specialistWorktrees.Count
    specialist_worktrees = @($specialistWorktrees)
    changed_path_count = $changedPaths.Count
    unexpected_path_count = $unexpectedPaths.Count
    unexpected_paths = @($unexpectedPaths)
    implementation_file_change_count = $implementationChanges.Count
    implementation_file_changes = @($implementationChanges)
    public_contract_change_count = $publicContractChanges.Count
    public_contract_changes = @($publicContractChanges)
    secret_like_finding_count = $secretFindings.Count
    secret_like_findings = @($secretFindings)
    unsafe_command_example_count = $unsafeCommandFindings.Count
    unsafe_command_examples = @($unsafeCommandFindings)
    whitespace_error_count = $whitespaceFindings.Count
    whitespace_errors = @($whitespaceFindings)
    broken_linked_path_count = $brokenLinkedPaths.Count
    broken_linked_paths = @($brokenLinkedPaths)
    diff_check_exit_code = $diffCheckExitCode
    design_ready_count = 3
    selected_count = 0
    formal_none_decision = $false
    runtime_change_count = 0
    schema_change_count = 0
    dependency_change_count = 0
    multi_agent_implementation_count = 0
    production_write_count = 0
  }
  $passed = (
    $missingArtifacts.Count -eq 0 -and
    $markerGaps.Count -eq 0 -and
    $jsonParseErrors.Count -eq 0 -and
    $semanticReceiptErrors.Count -eq 0 -and
    $hashIndexErrors.Count -eq 0 -and
    $materializedFormalArtifacts.Count -eq 0 -and
    $specialistRefs.Count -eq 0 -and
    $specialistWorktrees.Count -eq 0 -and
    $unexpectedPaths.Count -eq 0 -and
    $implementationChanges.Count -eq 0 -and
    $publicContractChanges.Count -eq 0 -and
    $secretFindings.Count -eq 0 -and
    $unsafeCommandFindings.Count -eq 0 -and
    $whitespaceFindings.Count -eq 0 -and
    $brokenLinkedPaths.Count -eq 0 -and
    $diffCheckExitCode -eq 0
  )

  $receipt = [ordered]@{
    schema_version = '1.0'
    gate_id = 'PHASE12-PROVISIONAL-ARCHITECTURE-ARCHIVE'
    execution_mode = if ($Bootstrap) { 'bootstrap' } else { 'full' }
    source_checkpoint_oid = $BaseOid
    head_oid = $headOid
    git_object_format = $objectFormat
    archive_content_sha256 = $archiveDigest
    artifacts = $artifactEntries
    checks = $checks
    overall_status = if ($passed) { 'passed' } else { 'failed' }
    formal_task_status = 'not_started'
    formal_selection_status = 'pending'
    independent_review_status = 'pending_external'
    recorded_at = [DateTimeOffset]::Now.ToString('o')
  }
  Write-AtomicJson -LiteralPath $OutputPath -Value $receipt
  $receipt | ConvertTo-Json -Depth 12
  if (-not $passed) { exit 3 }
}
finally {
  Pop-Location
}

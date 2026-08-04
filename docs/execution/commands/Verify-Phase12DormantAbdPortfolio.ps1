[CmdletBinding()]
param(
  [ValidateSet('TASK-P12A-000','TASK-P12B-000','TASK-P12D-000','ABD')]
  [string]$TaskId = 'ABD',
  [ValidatePattern('^[0-9a-f]{40}$')]
  [string]$BaseOid = 'd850640325904c443a180ebb2dbb0462638ac293',
  [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
Push-Location $RepositoryRoot
try {
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  function Invoke-GitLines {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $raw = @(& git @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "git $($Arguments -join ' ') failed with exit $exitCode" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $raw) {
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
    param([Parameter(Mandatory = $true)][string]$LiteralPath,[Parameter(Mandatory = $true)]$Value)
    $absolute = if ([IO.Path]::IsPathRooted($LiteralPath)) { $LiteralPath } else { Join-Path $RepositoryRoot $LiteralPath }
    $directory = Split-Path -Parent $absolute
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($absolute) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, (($Value | ConvertTo-Json -Depth 16) + "`n"), $Utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $absolute -Force
  }

  $definitions = [ordered]@{
    'TASK-P12A-000' = [ordered]@{
      selection = '12A'; prefix = 'P12A'; ct = 'CT-009,CT-015'
      adr = 'docs/architecture/adr/ADR-P12A-000-memory-work-package.md'
      plan = 'docs/execution/evidence/phase-12/P12A-000/task-plan.md'
      evidence = 'docs/execution/evidence/phase-12a/P12A-000'
      status = 'docs/execution/status/TASK-P12A-000.json'
      markers = @('Negative consent','Conflict state','Poisoning boundary','Deletion and export','Backup non-resurrection','Single-Agent read port')
    }
    'TASK-P12B-000' = [ordered]@{
      selection = '12B'; prefix = 'P12B'; ct = 'none'
      adr = 'docs/architecture/adr/ADR-P12B-000-cost-router-work-package.md'
      plan = 'docs/execution/evidence/phase-12/P12B-000/task-plan.md'
      evidence = 'docs/execution/evidence/phase-12b/P12B-000'
      status = 'docs/execution/status/TASK-P12B-000.json'
      markers = @('Four-week trigger','Deterministic factors','Route reason','Region and privacy','Budget ledger','Quality floor and fallback')
    }
    'TASK-P12D-000' = [ordered]@{
      selection = '12D'; prefix = 'P12D'; ct = 'none'
      adr = 'docs/architecture/adr/ADR-P12D-000-domain-command-work-package.md'
      plan = 'docs/execution/evidence/phase-12/P12D-000/task-plan.md'
      evidence = 'docs/execution/evidence/phase-12d/P12D-000'
      status = 'docs/execution/status/TASK-P12D-000.json'
      markers = @('One write entry','Principal and approval','CAS and idempotency','Transactional outbox','Stable receipt','Expand-contract rollback')
    }
  }

  $selectedDefinitions = if ($TaskId -ceq 'ABD') { @($definitions.GetEnumerator()) } else { @([ordered]@{Key=$TaskId;Value=$definitions[$TaskId]}) }
  $required = New-Object System.Collections.Generic.List[string]
  $required.Add('docs/execution/commands/Verify-Phase12DormantAbdPortfolio.ps1')
  $required.Add('docs/execution/evidence/phase-12/ABD-PORTFOLIO/phase-entry-regression.json')
  foreach ($entry in $selectedDefinitions) {
    $definition = $entry.Value
    foreach ($path in @(
      $definition.adr,
      $definition.plan,
      $definition.status,
      "$($definition.evidence)/design-verification.json",
      "$($definition.evidence)/commands.json",
      "$($definition.evidence)/gate-results.json",
      "$($definition.evidence)/artifact-hashes.json"
    )) { $required.Add($path) }
  }
  if ($TaskId -ceq 'ABD') {
    foreach ($path in @(
      'docs/execution/evidence/phase-12/ABD-PORTFOLIO/change-summary.md',
      'docs/execution/evidence/phase-12/ABD-PORTFOLIO/star-records.md',
      'docs/execution/evidence/phase-12/ABD-PORTFOLIO/improvements/STAR-abd-design-readiness.md',
      'docs/execution/evidence/phase-12/ABD-PORTFOLIO/commands.json',
      'docs/execution/evidence/phase-12/ABD-PORTFOLIO/gate-results.json',
      'docs/execution/evidence/phase-12/ABD-PORTFOLIO/artifact-hashes.json'
    )) { $required.Add($path) }
  }
  $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })

  $planErrors = New-Object System.Collections.Generic.List[string]
  $statusErrors = New-Object System.Collections.Generic.List[string]
  $hashErrors = New-Object System.Collections.Generic.List[string]
  $jsonErrors = New-Object System.Collections.Generic.List[string]
  $atomicTaskTotal = 0
  foreach ($entry in $selectedDefinitions) {
    $task = [string]$entry.Key
    $definition = $entry.Value
    if (-not (Test-Path -LiteralPath $definition.plan -PathType Leaf) -or -not (Test-Path -LiteralPath $definition.adr -PathType Leaf)) { continue }
    $plan = Get-Content -LiteralPath $definition.plan -Raw -Encoding UTF8
    $adr = Get-Content -LiteralPath $definition.adr -Raw -Encoding UTF8
    $requiredPlanMarkers = @(
      "Task: $task",
      "Selection candidate: $($definition.selection)",
      'Portfolio mode: dormant_design_ready',
      'Formal dependency status: pending',
      'Formal selection asserted: false',
      'Implementation commit count: 0',
      'Contract change: false',
      'Production write count: 0',
      "Applicable CT: $($definition.ct)",
      "Acceptance task: TASK-$($definition.prefix)-990",
      "Merge task: TASK-$($definition.prefix)-999"
    )
    foreach ($marker in @($requiredPlanMarkers + $definition.markers)) {
      if (-not $plan.Contains([string]$marker)) { $planErrors.Add("$task::plan::$marker") }
    }
    foreach ($heading in @('Trigger Evidence','Options and Decision','Atomic Tasks','Security and Privacy','Reliability','Acceptance and Merge','Rollback')) {
      if ($adr -cnotmatch ("(?m)^##\s+" + [regex]::Escape($heading) + "\s*$")) { $planErrors.Add("$task::adr_heading::$heading") }
    }
    foreach ($marker in $definition.markers) {
      if (-not $adr.Contains([string]$marker)) { $planErrors.Add("$task::adr::$marker") }
    }
    $atomicPattern = "(?m)^Atomic task: TASK-$([regex]::Escape([string]$definition.prefix))-(?!000|089|990|999)[0-9]{3}$"
    $atomic = @([regex]::Matches($plan,$atomicPattern) | ForEach-Object { $_.Value.Substring(13) })
    $unique = @($atomic | Sort-Object -Unique)
    $atomicTaskTotal += $atomic.Count
    if ($atomic.Count -lt 6 -or $unique.Count -ne $atomic.Count) { $planErrors.Add("$task::atomic_tasks") }
    if ($plan -cmatch '(?m)^P12-002 head:\s*[0-9a-f]{40}$' -or $plan -cmatch '(?m)^Cycle:\s*[0-9a-fA-F-]{36}$') { $planErrors.Add("$task::fabricated_formal_binding") }

    if (Test-Path -LiteralPath $definition.status -PathType Leaf) {
      try { $status = Get-Content -LiteralPath $definition.status -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
      catch { $jsonErrors.Add($definition.status); continue }
      if ([string]$status.task_id -cne $task -or [string]$status.status -cne 'ready_for_review') { $statusErrors.Add("$task::local_status") }
      if ([string]$status.design_scope -cne 'dormant_only' -or [string]$status.formal_task_status -cne 'not_started') { $statusErrors.Add("$task::scope") }
      if ([string]$status.formal_dependency_status -cne 'pending' -or [bool]$status.formal_selection_asserted -or [bool]$status.selected) { $statusErrors.Add("$task::formal_boundary") }
      if ([int]$status.implementation_commit_count -ne 0 -or [bool]$status.contract_change -or [int]$status.production_write_count -ne 0) { $statusErrors.Add("$task::zero_change_boundary") }
      if ([bool]$status.formal_acceptance -or [bool]$status.reviewer_independent) { $statusErrors.Add("$task::review_boundary") }
    }
    $hashPath = "$($definition.evidence)/artifact-hashes.json"
    if (Test-Path -LiteralPath $hashPath -PathType Leaf) {
      try { $index = Get-Content -LiteralPath $hashPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
      catch { $jsonErrors.Add($hashPath); continue }
      foreach ($artifact in @($index.artifacts)) {
        $path = [string]$artifact.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $hashErrors.Add("$task::$path::missing"); continue }
        if ((Get-Sha256 $path) -cne [string]$artifact.sha256) { $hashErrors.Add("$task::$path::sha256") }
        if ([long](Get-Item -LiteralPath $path).Length -ne [long]$artifact.size_bytes) { $hashErrors.Add("$task::$path::size") }
      }
    }
  }

  foreach ($path in @($required | Where-Object { $_.EndsWith('.json') -and (Test-Path -LiteralPath $_ -PathType Leaf) })) {
    try { $null = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { if ($path -notin $jsonErrors) { $jsonErrors.Add($path) } }
  }
  if ($TaskId -ceq 'ABD') {
    $portfolioHash = 'docs/execution/evidence/phase-12/ABD-PORTFOLIO/artifact-hashes.json'
    if (Test-Path -LiteralPath $portfolioHash -PathType Leaf) {
      $index = Get-Content -LiteralPath $portfolioHash -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($artifact in @($index.artifacts)) {
        $path = [string]$artifact.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $hashErrors.Add("ABD::$path::missing"); continue }
        if ((Get-Sha256 $path) -cne [string]$artifact.sha256) { $hashErrors.Add("ABD::$path::sha256") }
        if ([long](Get-Item -LiteralPath $path).Length -ne [long]$artifact.size_bytes) { $hashErrors.Add("ABD::$path::size") }
      }
    }
  }

  $forbiddenPaths = @(
    'docs/architecture/adr/ADR-P12C-000-multi-agent-work-package.md',
    'docs/execution/evidence/phase-12/P12C-000',
    'docs/execution/evidence/phase-12c/P12C-000',
    'docs/execution/status/TASK-P12C-000.json',
    'docs/execution/evidence/phase-12/P12-000',
    'docs/execution/evidence/phase-12/P12-001',
    'docs/execution/evidence/phase-12/P12-002',
    'docs/execution/status/TASK-P12-000.json',
    'docs/execution/status/TASK-P12-001.json',
    'docs/execution/status/TASK-P12-002.json'
  )
  $forbiddenMaterialized = @($forbiddenPaths | Where-Object { Test-Path -LiteralPath $_ })
  $refs = @(Invoke-GitLines @('for-each-ref','--format=%(refname)','refs/heads'))
  $formalRefPattern = '^refs/heads/codex/(release-c-governance|phase-12(?:[abcd])?(?:$|[-/]))'
  $formalRefs = @($refs | Where-Object { $_ -cmatch $formalRefPattern })
  $worktreeLines = @(Invoke-GitLines @('worktree','list','--porcelain'))
  $formalWorktrees = @($worktreeLines | Where-Object { $_ -cmatch '^branch refs/heads/codex/(release-c-governance|phase-12(?:[abcd])?(?:$|[-/]))' })

  $changedTracked = @(Invoke-GitLines @('diff','--name-only',$BaseOid,'--'))
  $untracked = @(Invoke-GitLines @('ls-files','--others','--exclude-standard'))
  $changed = @(@($changedTracked)+@($untracked) | Where-Object { $_ } | Sort-Object -Unique)
  $allowed = @($changed | Where-Object {
    $_ -ceq 'docs/execution/commands/Verify-Phase12DormantAbdPortfolio.ps1' -or
    $_ -cmatch '^docs/architecture/adr/ADR-P12[ABD]-000-[a-z0-9-]+\.md$' -or
    $_ -cmatch '^docs/execution/evidence/phase-12/P12[ABD]-000/task-plan\.md$' -or
    $_ -cmatch '^docs/execution/evidence/phase-12[abd]/P12[ABD]-000/' -or
    $_ -cmatch '^docs/execution/status/TASK-P12[ABD]-000\.json$' -or
    $_ -cmatch '^docs/execution/evidence/phase-12/ABD-PORTFOLIO/' -or
    $_ -in @('README.md','docs/architecture/release-c-selection.md','docs/runbooks/release-c-governance.md','docs/api/release-c-selection.md','docs/architecture/threat-model/phase-12-review.json','docs/execution/commands/Verify-Phase12ArchitectureArchive.ps1','docs/execution/evidence/phase-12/artifact-manifest.premerge.json','docs/execution/evidence/phase-12/P12-089/provisional-archive-status.json','docs/execution/evidence/phase-12/P12-089/handoff-verification.json','docs/execution/evidence/phase-12/P12-089/commands.json','docs/execution/evidence/phase-12/P12-089/gate-results.json','docs/execution/evidence/phase-12/P12-089/artifact-hashes.json')
  })
  $unexpected = @($changed | Where-Object { $_ -notin $allowed })
  $implementation = @($changed | Where-Object { $_ -cmatch '^(agent-service/|lib/|test/|integration_test/|contracts/|supabase/|android/|ios/|web/|pubspec\.(yaml|lock)$)' })
  $contentFindings = New-Object System.Collections.Generic.List[string]
  foreach ($path in $changed) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($text -match '(?i)sk-[a-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|bearer\s+eyJ[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+') { $contentFindings.Add("$path::secret_like") }
    if ($text -match '(?im)^\s*git\s+reset\s+--hard\b|^\s*git\s+clean\s+-[^\r\n]*f|^\s*(rm\s+-rf|Remove-Item\s+.+-Recurse.+-Force)\b') { $contentFindings.Add("$path::unsafe_command") }
  }
  $diffOutput = @(& git diff --check $BaseOid -- 2>&1)
  $diffExit = $LASTEXITCODE

  $checks = [ordered]@{
    package_count = $selectedDefinitions.Count
    required_artifact_count = $required.Count
    missing_artifact_count = $missing.Count
    missing_artifacts = @($missing)
    plan_error_count = $planErrors.Count
    plan_errors = @($planErrors)
    status_error_count = $statusErrors.Count
    status_errors = @($statusErrors)
    json_error_count = $jsonErrors.Count
    json_errors = @($jsonErrors)
    hash_error_count = $hashErrors.Count
    hash_errors = @($hashErrors)
    atomic_task_count = $atomicTaskTotal
    forbidden_materialized_count = $forbiddenMaterialized.Count
    forbidden_materialized = @($forbiddenMaterialized)
    formal_ref_count = $formalRefs.Count
    formal_refs = @($formalRefs)
    formal_worktree_count = $formalWorktrees.Count
    formal_worktrees = @($formalWorktrees)
    changed_path_count = $changed.Count
    unexpected_path_count = $unexpected.Count
    unexpected_paths = @($unexpected)
    implementation_file_change_count = $implementation.Count
    implementation_file_changes = @($implementation)
    secret_or_unsafe_finding_count = $contentFindings.Count
    secret_or_unsafe_findings = @($contentFindings)
    diff_check_exit_code = $diffExit
    design_ready_count = $selectedDefinitions.Count
    formal_selected_count = 0
    formal_selection_asserted_count = 0
    implementation_commit_count = 0
    contract_change_count = 0
    multi_agent_implementation_count = 0
    production_write_count = 0
  }
  $passed = $missing.Count+$planErrors.Count+$statusErrors.Count+$jsonErrors.Count+$hashErrors.Count+$forbiddenMaterialized.Count+$formalRefs.Count+$formalWorktrees.Count+$unexpected.Count+$implementation.Count+$contentFindings.Count+$diffExit -eq 0
  $head = (@(Invoke-GitLines @('rev-parse','HEAD')))[0].Trim()
  if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = if ($TaskId -ceq 'ABD') { 'docs/execution/evidence/phase-12/ABD-PORTFOLIO/portfolio-gate-runtime.json' } else { "$($definitions[$TaskId].evidence)/design-gate-runtime.json" }
  }
  $receipt = [ordered]@{
    schema_version = '1.0'
    gate_id = 'PHASE12-ABD-DORMANT-DESIGN'
    task_id = $TaskId
    phase_base_oid = $BaseOid
    head_oid = $head
    checks = $checks
    overall_status = if ($passed) { 'passed' } else { 'failed' }
    execution_mode = 'local_provisional_dormant_design'
    formal_selection_status = 'pending'
    independent_review_status = 'pending_external'
    recorded_at = [DateTimeOffset]::Now.ToString('o')
  }
  Write-AtomicJson -LiteralPath $OutputPath -Value $receipt
  $receipt | ConvertTo-Json -Depth 16
  if (-not $passed) { exit 3 }
}
finally {
  Pop-Location
}

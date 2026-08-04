# Cost Router local calibration runbook

This runbook is local-provisional only. It never enables production allocation, changes a public
contract, writes production data, or prints/persists API keys. The default Worker composition rejects
`GONOW_COST_ROUTER_ENABLED=1`; absence of an explicit immutable routing configuration preserves the
existing Gemini path.

## Configure the candidate key without terminal echo

Run in the user's PowerShell. Never paste the value into chat, a command argument, a file, a log, or
Git evidence.

```powershell
$deepseekSecure = Read-Host '请输入 DeepSeek API Key' -AsSecureString
$deepseekPlain = [System.Net.NetworkCredential]::new('', $deepseekSecure).Password
[Environment]::SetEnvironmentVariable(
  'DEEPSEEK_API_KEY',
  $deepseekPlain,
  [EnvironmentVariableTarget]::User
)
Remove-Variable deepseekSecure, deepseekPlain
```

The runner reads `GEMINI_API_KEY` and `DEEPSEEK_API_KEY` from its process environment only. A missing
key emits a `pending_key` receipt with zero calls. Load the user-scoped DeepSeek value into only the
calibration subprocess and remove it from that process immediately afterward.

## Execute the preregistered pilot

Use a new output path outside the worktree. The pilot is exactly scenarios `CR-V1-001`, `007`, `008`
and `010`; nominal calls are eight and each arm has at most one bounded fallback.

```powershell
$deepseekForPilot = [Environment]::GetEnvironmentVariable(
  'DEEPSEEK_API_KEY',
  [EnvironmentVariableTarget]::User
)
$env:DEEPSEEK_API_KEY = $deepseekForPilot
try {
  python agent-service/scripts/run_p12b_live_calibration.py `
    --manifest docs/execution/evidence/phase-12b/P12B-010/calibration-dataset-manifest.json `
    --cohort pilot `
    --output D:\safe-external-path\p12b-pilot.json
} finally {
  Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue
  Remove-Variable deepseekForPilot -ErrorAction SilentlyContinue
}
```

Inspect only the output's finite counts, hashes, failure classes, token/cost totals and guardrails.
Prompts, responses, reasoning and key fingerprints are prohibited. Stop without expansion when either
arm has no quality-qualified success, cost per success is undefined or above the threshold, quality is
inferior, latency/fallback fails, any redline fires, or the worst-case projection exceeds 20 tasks,
40 calls, 100,000 tokens, or 1,000,000 microUSD.

## Resume the same experiment only after a passing pilot

Expansion must consume the exact pilot file as `--prior`; the runner rejects repeated pilot IDs,
changed dataset/limit bindings, or `expansion_allowed=false`.

```powershell
python agent-service/scripts/run_p12b_live_calibration.py `
  --manifest docs/execution/evidence/phase-12b/P12B-010/calibration-dataset-manifest.json `
  --cohort expansion `
  --prior D:\safe-external-path\p12b-pilot.json `
  --output D:\safe-external-path\p12b-complete.json
```

The 2026-08-04 pilot stopped after eight calls because neither arm produced a qualified success.
Expansion was not executed. Allocation remains zero and the router stays bypassed.

## Optional key removal after the task

The user may remove the persisted user-scoped variable when it is no longer needed:

```powershell
[Environment]::SetEnvironmentVariable(
  'DEEPSEEK_API_KEY',
  $null,
  [EnvironmentVariableTarget]::User
)
```

# GitHub REST adapter credential-provider repair

- Classification: `phase-10/repairs`
- Baseline commit: `46394dca0eba6d87a1f3c9a55520a37bad109e96`
- Scope: Release pull-request, release-label, and `main` protection REST adapters
- Execution mode: `local_provisional`
- Recorded: `2026-08-04` (`Asia/Shanghai`)

## Reproduction

The three GitHub REST adapters accepted only process-scoped `GH_TOKEN` or
`GITHUB_TOKEN`. Both variables were absent even though Git Credential Manager was
installed, configured, and already held a usable `github.com` credential. A
noninteractive, stdout-redacted `git credential fill` probe returned exit `0`,
proved that username and password fields were present, and emitted zero secret
values to the task log.

Read-only live `Plan` probes through that credential showed:

- release-label current-state hash
  `1d825c917575e0e4ecc6473ab9ae2200440220e631073c4b78d0687a270f7ac3`;
- release-label desired-definition hash
  `17a73e06ce7b96d3959d3630dfd1ba6ab78e637fc45dd8fa53734039da039191`;
- four missing labels and zero label-name collisions;
- `main` protection absent-state hash
  `00c26121ab43694c9459277fcee58e372987ed2b6ccf692bd6bc6eefdb8355af`;
- desired `main` protection hash
  `9d00cd307ce7775684c586270a8ccb0e01d6c7a2adb182f2de383364e407c431`.

Both probes were read-only. No label, protection, pull request, ref, credential,
repository setting, or remote state was changed.

## Root cause and impact

The REST adapters duplicated an environment-variable-only token lookup instead of
using the repository's installed Git credential provider. The missing environment
variables therefore appeared as a tool/credential blocker even though a safe local
provider was available.

The impact covered the three measured REST adapters: read-only planning and any
future contract-authorized application would fail before HTTP dispatch unless the
same credential were copied into another process variable. Git transport itself
was unaffected. This repair does not supply owner identities, canary references,
budget-cap references, endpoints, settings authorization, or production authority.

## Reversible repair

- Added one `GitHubCredentialProvider.psm1` boundary shared by all three adapters.
- Preserved process-scoped `GH_TOKEN` / `GITHUB_TOKEN` as first priority.
- Added a fixed-host `git credential fill` fallback for `https://github.com` with
  `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=Never`, redirected streams, no visible
  window, and a 15-second timeout.
- Accepted only an exact `https` protocol, exact `github.com` host, nonempty
  username, one password field, and a bounded whitespace-free token.
- Preserved each adapter's existing missing-token error code.
- Kept credential stdout/stderr inside the provider and never included it in a
  receipt, report, exception, or console message.

Rollback is a single revert of this repair commit; the adapters then return to
their former environment-variable-only behavior without changing remote state.

## Affected regression

| Check | Result |
|---|---:|
| Credential-provider unit and malformed-fixture cases | passed |
| Release pull-request adapter contracts | passed |
| Release-label adapter contracts | passed |
| `main` protection adapter contracts | passed |
| Full `Invoke-TaskGate.Tests.ps1` under locked Windows PowerShell | passed, `95.3 s` |
| Live release-label `Plan` through GCM | passed, mutation count `0` |
| Live `main` protection `Plan` through GCM | passed, mutation count `0` |
| Worktree secret scan | exit `0`; valid findings `0`; secret outputs `0`; untracked reads `0` |
| Secret-scan report SHA-256 | `3b64f9bed79498f5740b903ef83497901eccb88ac2e2dd81c070c467915e8cad` |
| `git diff --check` | passed |

The first full-suite invocation used PowerShell 7 and stopped before the test body
because the frozen Catalog is a Windows PowerShell 5.1 native data-file contract.
The same suite was rerun once with the locked executable and passed; no production
code, test expectation, threshold, skip, or xfail was changed in response.

## STAR record

### Situation

An installed and usable credential manager existed, but the REST control adapters
could not consume it and falsely exposed an installable local gap as a blocker.

### Task

Make the adapters consume the existing provider noninteractively without printing
or persisting secrets and without granting any new remote authority.

### Action

Centralized provider resolution, constrained the fallback to GitHub HTTPS,
fail-closed parsed the credential protocol, retained adapter-specific failures, and
tested environment precedence, fallback success, optional/required failure, and
malformed credentials before exercising live read-only plans.

### Result

- Primary result: `3/3` measured GitHub REST adapters can now plan through the
  installed GCM provider; previously `0/3` could do so without an environment copy.
- Diagnostic: the live plans identified four missing labels and absent `main`
  protection while producing no mutation.
- Guardrails: secret findings `0`, secret outputs `0`, remote mutations `0`, and the
  full TaskGate contract suite remains green.

This proves local credential-provider capability and behavioral compatibility. It
does not prove settings authorization, owner approval, production readiness, or
Release acceptance.

## Current hashes

- `GitHubCredentialProvider.psm1`:
  `b572eb96c5ef0e94268b4c73d8a98a805d3bc2823004615724fb19208889821d`
- `Invoke-GitHubReleasePullRequest.ps1`:
  `38a007a7befaa7181b554d08b1e287a0a3209634ccec69d740ace73372c21b08`
- `Invoke-GitHubReleaseLabels.ps1`:
  `68c4bd69d309adc25bcd5f53f98db4b386148972143a2e581a5f13d6cb4a35e5`
- `Invoke-GitHubMainProtection.ps1`:
  `a79c0b2fb51193b337ceea16a15d93a1ae17e997633295565294cbd82a485398`
- `GitHubCredentialProvider.Tests.ps1`:
  `1977340bea7423dc258c08797a702ebca922aabd062191c4dc0b121cc3a5011d`
- `Invoke-GitHubMainProtection.Tests.ps1`:
  `99060cc8ab132117a71b652502caf8e1fe96c21cf81877ad34de148973fa247a`

# P10-009 post-blocker local regression

## Scope and immutable point

- Candidate head: `9c7db2dd1882332b698ca7b399082f7fbee102bc`
- Execution mode: `local_provisional`
- Purpose: prove that the P10-009 fail-closed observation record and P10-009/P10-010 runner enablers did not regress the existing local product behavior.
- Production writes, feature-flag changes, remote writes, and approval actions: `0`.

## Commands and results

1. Locked Python environment: `python -m pytest -q` from `agent-service/`.
   - Result: `589 passed in 86.10s`; exit `0`.
2. Locked Flutter executable: `flutter test --no-pub` from the repository root.
   - Result: `93 passed`, `4 skipped`, exit `0`.
   - The four skipped tests are the pre-existing Amap network-dependent cases explicitly labeled `需要网络连接`; they are not counted as production or network validation.
3. Runner static contract: `docs/execution/commands/tests/Invoke-TaskGate.Tests.ps1`.
   - Result: exit `0`.
4. Post-run `git status --short`.
   - Result before creating this record: empty; dependency provisioning and tests produced no tracked write.

## Root-cause closure boundary

The regression suite distinguishes the local code path from the external rollout blocker. Local implementation and compatibility remain green, while P10-009 correctly remains blocked because production approvals, approved cohorts, audit receipts, adopted-run samples, and elapsed observation windows are still unavailable. Re-running the same suite without a code, environment, or evidence change is prohibited because it would add no diagnostic information.

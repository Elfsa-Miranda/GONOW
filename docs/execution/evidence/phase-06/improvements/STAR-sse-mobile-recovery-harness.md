# STAR: deterministic mobile recovery harness on a host without a device toolchain

## Situation

The Phase 6 mobile reconnect test initially could not run: the host exposed multiple Flutter
targets, Windows required an unavailable Visual Studio toolchain, and Chrome did not support this
integration-test path. Treating that as a pass would have hidden a real evidence gap; treating it as
a global stop would have blocked all safe local recovery work.

## Task

Preserve the exact `integration_test/agent_network_recovery_test.dart` bytes, execute its
deterministic recovery controller locally, keep strict analyzer coverage, and report the formal
mobile-device boundary as pending rather than substituting a fake device claim.

## Action

The local gate copies the source byte-for-byte to an ignored `.dart_tool` probe, compares SHA-256,
runs four Flutter VM cases, runs strict target analysis plus the root analyzer boundary, and records
`formal_mobile_device_status=pending_external`. The source covers replay/live overlap, duplicate
reconnect, background restore, and slow-consumer recovery.

Reproduction command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\docs\execution\commands\Invoke-TaskGate.ps1 -TaskId TASK-P06-006 -Mode Verify
```

## Result

Before: no locally runnable mobile recovery test and no byte-identity proof. After: 4/4
deterministic Flutter cases, target analyzer zero, source/probe SHA match, and explicit separation of
local VM evidence from the pending device run. The bound report is
`docs/execution/evidence/phase-06/P06-006/flutter-network-report.json`; its hash is carried by the
task artifact ledger. This is a reproducibility and evidence-honesty improvement, not a production
mobile, latency, availability, or acceptance claim.

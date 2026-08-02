# BLK-P10-009 report-only certification gap

## Situation and reproduction

Candidate `7bc48ac0d5338bf173dd48ee03959df6a76a1f11` contained the repaired executable API/PostgreSQL/Worker/Flutter journey and the personal governance thresholds, but `Invoke-PersonalReleaseCertification.ps1` only parsed five caller-supplied summary reports. Its self-test created threshold-shaped JSON directly. No repository-owned command generated the required 200 E0 cases, 50,000 state sequences, 100,000 security attempts, 10,000 complete Runs, 1,000+ E1 cases, kill schedules, provider lifecycles, real soak samples, or operational observation.

Minimal reproduction was inspection of the runner control flow: outside `-SelfTest`, it read existing report files and compared scalar fields; it did not invoke Python, Flutter, PostgreSQL, a provider adapter, or a resource sampler. A hand-written report with correct scalar values and matching supporting-file hashes could therefore pass without executing the intended risk surface.

## Root cause and impact surface

The governance change froze strong C1–C5 denominators before an executable evidence producer existed. The initial enabler correctly failed closed on missing reports, but report integrity and test execution were treated as a later implementation detail. That separation made the aggregate gate structurally sound but semantically too trusting.

Affected claims were all P10-009 C1–C5 outcomes and downstream automated acceptance. Unaffected claims were the already passing historical regressions, the real cross-language runtime journey, the enterprise profile retained in the guidance, and the fact that no production allocation or write occurred.

## Reversible repair

The repair adds repository-owned certification shards under `agent-service/tests/certification/` and an explicit runner execution mode. It keeps the default aggregation entry deterministic and adds source-evidence cross-checks:

- C1 expands 40 frozen E0 cases with five behavior-preserving or failure-preserving transformations to 200 inputs, then drives 50,000 seeded sequences through the current StateGuard, Run transition table, checkpoint parser, resume capability and SSE cursor parser.
- C2 executes 100,000 authorization/tenant/Tool/SSRF/SQL/PII/context attempts and targeted fail-open mutation operators. Its load shard creates complete Runs through HTTP on the task-owned PostgreSQL instance and drives them through the fenced Worker into durable Candidates. Fake-provider evidence cannot satisfy the separate live-provider/cost predicate.
- C3 executes eleven critical slices with 1,000 cases each and a paired frozen oracle. With zero discordant regressions, the Holm-adjusted one-sided upper bound is approximately `0.538%`, below the `1pp` limit.
- C4 binds seven prior real process-kill anchors, executes 420 independent schedule/outcome combinations, advances 90 virtual days, runs 100,000 full fake-provider gateway lifecycles, fixes 400 synthetic label-only Judge annotations, and writes raw monotonic resource samples for a minimum four-hour soak.
- C5 executes twenty distinct fault classes, trace localization, typed kill-switch propagation, idle/in-flight rollback, and a five-minute high-density legacy-path observation.
- The PowerShell aggregator now checks top-level metrics against the raw source reports, binds every required source by SHA-256, and validates C4 sample count, artifact hash, and monotonic elapsed time.

Rollback is a normal revert of the certification-engine commit. It changes no production schema, data, feature allocation, provider credential, or external object.

## Difficulties and closed repairs

1. A three-second soak probe failed before sampling because Windows `GetProcessMemoryInfo` received an implicitly 32-bit process handle. The fix declares exact `ctypes` argument/result types for `GetCurrentProcess`, `GetProcessMemoryInfo`, and `GetProcessHandleCount`. The affected probe then completed with zero workload error. Its short duration intentionally failed the long-run slope predicate and was not used as certification evidence.
2. The first ten-Run PostgreSQL load produced zero Runs and HTTP `context.invalid`. The safe error envelope and route contract showed the generated idempotency key was 15 characters while the public minimum is 16. The generator now uses `c2-cert-run-<8 digits>`; the same ten-Run reproduction then completed `10/10`, with exact Run/Job/Candidate/terminal counts, RLS leak count `0`, and API p95 upper `73.2505ms`.
3. The first complete Python regression found two environment/evidence issues after 603 passes: the cross-language mandatory test lacked `GONOW_DART_EXECUTABLE`, and a literal synthetic `sk-...` event canary was correctly rejected by the repository secret scanner. The executable runner now derives and injects locked `dart.bat`; the canary is assembled only at runtime. The affected set passed `2/2`, followed by the complete suite at `605/605` in `54.76s` with zero skip or xfail.

## Current recovery state

The executable local certification engine and its negative controls are implemented and pre-commit verified. Development probes produced:

- C1: E0 `200`, unique inputs `197`, state sequences `50,000`, failures `0`, one-sided success lower bound `0.9999458921`;
- C2 generated security: attempts `100,000`, redlines `0`, mutation kill rate `100%`; real-PG minimal reproduction `10/10` complete;
- C3: cases `11,000`, eleven slices of `1,000`, failures `0`, Holm-adjusted maximum regression upper bound `0.0053791081`;
- C4 fast: schedules `420`, virtual days `90`, fake-provider lifecycles `100,000`, unknown outcomes `0`, Judge annotations `400`, gap `4pp`;
- C5 short functional probe: fault classes `20`, localization/runbook/rollback failures `0`, new Run after kill `0`, old-path success `100%`.

These are development results, not the final candidate attestation. Recovery closes only after the engine is committed, all required shards are rerun against that fixed OID, the real soak reaches 14,400 monotonic seconds, and the independent live-provider/platform inputs are either supplied and passed or remain explicitly blocked without affecting completed local shards.

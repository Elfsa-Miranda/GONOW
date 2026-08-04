# ADR-P10-001: Adopt personal automated release governance

- Status: `accepted`
- Decision date: 2026-08-02
- Decision owner: repository owner, by explicit task directive
- Implementer: Codex
- Scope: governance, Phase acceptance, Release A/B/C PR handling, and Release B certification
- Decision base OID: `70109f8081f74551367a3dac4902646bfdfda73b`
- Binding: the governance commit and `personal-automation-adoption-v1.json` bind the final document hashes after commit; this ADR does not attempt a self-referential commit hash

## Context

The enterprise profile required five sequential, non-overlapping production observation windows totaling at least 744 hours. That contract is appropriate when independent teams, many tenants, natural production traffic, formal release boards, and organizational separation of duties exist. GoNow is currently a personal project. Waiting 31 calendar days would consume elapsed time without creating the traffic diversity, reviewer independence, or tenant scale that gives the enterprise window most of its value.

The owner explicitly approved replacing elapsed-time governance and repeated human signatures with deep automated testing, automatic acceptance when every mandatory gate is green, and an owner-only smoke/canary after the compressed suite. The hard security boundaries remain unchanged.

No finite accelerated suite is literally identical to unknown future production. The decision therefore maps each risk purpose to high-density evidence and records residual risks instead of assigning an unsupported equivalence percentage.

## Decision

Adopt `personal_automated` as the active profile in `AGENTS.md` and `execplan.md`.

Release B uses five ordered certification layers:

| Layer | Replaces the risk purpose of | Required evidence |
|---|---|---|
| C1 deterministic correctness | early 1% observation | full history regression, E0, contract tests, model/state/property tests, idempotency/cancel/replay/SSE resume |
| C2 real-boundary security and performance | 5% exposure | locked real PostgreSQL, RLS/auth/SSRF/PII/adversarial generation, local complete runs, live model routes, latency and cost confidence bounds |
| C3 statistical quality | 20% exposure | locked E1 holdout, critical slices, paired non-inferiority, multiple-comparison correction, hard-constraint redlines |
| C4 accelerated longevity and recovery | 50% exposure | exhaustive kill points, schedule interleavings, virtual time, lifecycle volume, Judge calibration, and at least four hours of real soak |
| C5 operational rollback | 100% exposure | kill switch, rollback/roll-forward, old-client and new-data compatibility, runbook fault exercises |

C1–C5 must run in order against the same candidate. Every mandatory check must pass with zero skip, xfail, flaky rerun-to-green, open P0/P1, cross-tenant leak, secret/PII leak, unauthorized write, duplicate formal side effect, permanent run, or rollback failure. A machine-generated attestation must bind the exact candidate OID and all inputs, configurations, seeds, reports, pricing, rollback evidence, and runner digests.

After C1–C5, run a 30–60 minute, 10–20 journey canary using only the owner's minimum-privilege identity and fixed budget. This smoke is last because it is a UX and wiring check, not the main source of fault coverage. It may exercise typed API/Domain Command writes only on owner-owned test data. Any redline or kill-switch failure sets allocation to zero and invalidates acceptance.

When the exact attestation remains valid, automation may accept the task/Phase/Release, push the Phase branch, non-force merge and push the landing branch, create/update the Release PR, and non-force merge through repository protection after required checks and tree equality pass. Force push, history rewriting, arbitrary SQL, migration, permission expansion, cross-tenant access, unknown deletion, unbounded spend, and unlisted production allocation remain prohibited.

## Alternatives considered

| Option | Safety and data | Compatibility | Cost and elapsed time | Decision |
|---|---|---|---|---|
| Keep the enterprise 744-hour profile | Best observation of calendar-time and naturally occurring events if real traffic exists | No governance change | At least 31 days; low information density for a personal project without diverse traffic | Retained but inactive |
| Pure synthetic/local testing | Strong determinism and fault injection | Good for old/new path regression | Fastest, but cannot validate provider, real PostgreSQL, billing, or deployment wiring | Rejected as insufficient |
| C1–C5 plus owner-only canary | Keeps hard boundaries; combines deterministic, statistical, real-boundary, soak, and rollback evidence | Explicit old-client/old-path contracts | Converts most risk coverage into engineering work; bounded live cost and hours | Selected |
| Immediate full release after unit tests | Weak failure recovery, data, security, and cost evidence | High regression risk | Fastest initial action, highest recovery risk | Rejected |

## Residual risk and evidence boundary

The compressed profile deliberately does not claim completion of 31 days of production observation. The following remain less observable than in a genuine long-running, multi-user production window:

- rare calendar, timezone, provider, quota, and regional events not represented in frozen scenarios;
- correlated real-user behavior, organic prompt distribution, and load bursts outside the generated model;
- environment drift, vendor changes, billing changes, and incidents occurring after certification;
- cumulative leaks or degradation whose onset exceeds the virtual/lifecycle model and four-hour real soak;
- subjective usability across users other than the owner;
- device/OS combinations outside the declared Flutter matrix, especially iOS when it is not a release target.

These are mitigated by seeded corpus expansion, metamorphic/property testing, locked real-boundary checks, confidence bounds, virtual time, lifecycle volume, four-hour soak, owner canary, telemetry, a kill switch, and immediate rollback. They are not erased. Reports must state the tested population and must not convert synthetic sample volume into a calendar-time or production-traffic claim.

## Consequences

- `AGENTS.md` and `execplan.md` become `2.0.0-personal`; the enterprise profile remains documented and can be reactivated only by a later governance revision.
- P10-009 owns C1–C5 execution; P10-010 owns the final owner-only canary and release decision; P10-990 owns the exact-candidate automatic acceptance attestation.
- Owner/reviewer labels become evidence domains in the personal profile. A clean independent execution context replaces the claim of a distinct human reviewer; it does not weaken the underlying Security/Product/Data/SRE checks.
- Release actions become automatic only after exact attestation and repository checks. Production schema/data and irreversible external actions are not broadly authorized.
- Existing 744-hour evidence and implementation are preserved as the inactive enterprise profile; no history or old receipt is overwritten.

## Rollback

Before any Release merge, revert the governance commit and restore the enterprise profile; no runtime data changes are required. After a Release merge, set allocation to zero, engage the kill switch, route to the old path, preserve evidence and data, and use an auditable non-force revert after rollback verification. A return to the enterprise profile requires resealing guidance and invalidates personal-profile attestations.

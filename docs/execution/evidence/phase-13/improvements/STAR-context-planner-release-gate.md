# STAR: frozen Context Planner release gate

Claim type: `offline_evaluation`

## Situation

Three stacked mechanism changes made Context planning, stage orchestration, and overflow recovery production-capable behind default-off gates. Enabling them without a frozen paired evaluation would turn local implementation success into an unfalsifiable rollout decision.

## Task

Freeze requests, labels, thresholds, tokenizer/policy identity, and runner version before candidate outcome access; report every baseline/candidate pair; bind the result to source digests; and mutate no release allocation unless every preregistered hard and activation gate passes.

## Action

- Froze exactly 24 cases across Task Contract order, Evidence overflow/dedup/supersession, 8/16/31-day boundaries, injection/Claim/tenant/deletion threats, stale/rehydration/tokenizer failures, and segment/replay/clarification/budget recovery.
- Bound the manifest and release-gate files to SHA-256 in a separate frozen contract tied to the exact Context policy and runner version.
- Added an offline paired runner that retains failures, reports every case, measures deterministic token estimates and local mechanism timing, repeats decisions three times, signs the report, and rejects manifest/report tampering.
- Mapped eleven relevant immutable Harness controls to Phase 13 owner, stable failure code, test, and evidence paths.
- Provisioned the supported local CI stack and passed the official full gate, then reran the frozen report with full-CI evidence but without a live-provider flag. The scorer—not a manual override—selected `KEEP_DISABLED`; the production environment defaults and active alias were left untouched.

## Result

All 24 expected Context terminals matched; accepted cases retained 100% hard semantics; Claim violations and partial segment successes were zero; candidate decisions were stable across three repeats; the 40-case E0 dataset remained green. On 14 preregistered long-context cases, the offline fixture model recorded two completion wins and a 44.56% median input-token-estimate reduction. Local evaluation p95 was 0.028 ms on the recorded Windows/Intel environment, below the frozen 25 ms ceiling.

Official full CI passed 966 main-suite tests and 267 contract tests, with all mandatory quality, secret, clock, dependency, license, and repository-clean gates green. The release decision remains `KEEP_DISABLED` solely because required live-provider evidence is absent. The paired results are offline deterministic fixtures and local mechanism timing—not provider latency, production quality, SLA, cost, or reliability evidence.

## Evidence

- `docs/execution/evidence/phase-13/P13-004/context-planner-report.json`
- `docs/execution/evidence/phase-13/P13-004/gate-results.json`
- `docs/execution/evidence/phase-13/P13-004/release-state.json`
- `docs/execution/evidence/phase-13/P13-004/artifact-hashes.json`

## Claim Scope

Offline deterministic paired fixtures and local mechanism timing on the recorded environment only. The result does not establish live-provider behavior, production quality, latency, cost, SLA, or reliability.

# Phase 8 knowledge transfer

## Responsibilities and dependency choices

Runtime owns strict contracts, shared budgeting, deterministic merge, and default-off routing. Eval
owns pre-registration and statistical accounting. Product, Security, Data, and SRE own formal
review and any future activation. No queue, cache, new process, network protocol, model router, or
database dependency was added.

## Hardest items

Three root causes required closure. First, a fresh Windows worker could time out on the first native
OR-Tools import inherited from Phase 7; the entry runner now performs a bounded explicit warmup
before full CI. Second, the initial merger model required two assessments and could not represent a
valid same-assessment conflict across sources; the minimum became one without weakening source
retention. Third, a BOM-less PowerShell 5 runner compared a non-ASCII marker unreliably; the
mechanical decision marker is now stable ASCII. Each repair was followed by its affected regression
set rather than repeated blind reruns.

## Operation, observation, and recovery

Normal state is flag off, active cohort false, zero research calls, and Phase 7 byte equality. For
an authorized local exercise, use only offline, replay, or shadow with typed read-only fixtures.
Observe stable version/kind codes, per-Run allocations, physical attempt counts, source-reference
counts, canonical digest, and kill-switch state. On any anomaly, engage the kill switch, verify the
Phase 7 digest, then inspect contract, budget, and merge evidence in that order.

## Verification and known limits

Contract, concurrency, merger, flag, and experiment suites pass locally with zero skip or xfail.
The A/B dataset is synthetic: 48 observations, 12 per slice. The best quality upper 95% bound is
2.778557 points, every slice is slower than the comparator, and the lowest cost mean is 1.0975.
Production quality, latency, cost, adoption, and safety remain unknown. Independent handoff,
production-like rollback, governance adoption, remote push, and formal acceptance remain pending.

## Decision, rollback, and next owner actions

The mechanical Multi-Agent trigger decision is `none`; preference context is preserved but no P12C
candidate is opened. Rollback keeps the feature off or uses the kill switch, proves Phase 7 byte
equality, and removes only Phase 8 research files if needed. Formal owners must independently review
the threat model and handoff evidence. A later trigger requires a new pre-registration, qualifying
data, and explicit approvals without threshold reduction.

# Phase 12 STAR records

Phase 12 keeps capability existence, measured behavior, and governance acceptance separate. P12D
adds one local Domain Command capability and records a controlled mechanism comparison. It makes no
production quality, incident, latency, cost, adoption, or compliance improvement claim.

## Indexed records

| Record | SHA-256 | Primary result | Evidence boundary |
|---|---|---|---|
| `../phase-12d/P12D-060/star-evaluation.json` | indexed by `P12D-060/artifact-hashes.json` | stale-conflict partial-effect rate: legacy 10,000/10k; candidate 0/10k; controlled relative improvement 100% | Isolated PostgreSQL 17.10, identical fixture/workload/seed; not a production claim |
| `../phase-12d/P12D-050/fault-and-replay-results.json` | indexed by `P12D-050/artifact-hashes.json` | duplicate, unauthorized/cross-tenant, divergence, ambiguous commit, and data-loss redlines all 0 | Deterministic local failure injection and replay only |
| `improvements/STAR-xor-safe-architecture-archive.md` | `39e1ae990a5de383a3d315039fe490fddbc7c65354e0a745c7ab104652a18f47` | Historical dormant archive guardrail | Superseded for this cycle by the user's exact 12D local selection; retained as history |

## Phase outcome boundary

- Capability existence: exactly one Phase 12 runtime package exists locally for itinerary Basic Info;
  its route is default-unmounted/default-off. Multi-Agent is explicitly deferred.
- Behavior evidence: 10,000 legacy and 10,000 candidate stale-conflict intents used the same frozen
  inputs. Candidate redlines are zero; all failed/conflict intents stayed in the denominator.
- Governance evidence: P12D-990 is `ready_for_review`; independent Security/Product/Data review,
  production authority, remote integration, and Release acceptance remain `pending_external`.
- Production measurement: schema equivalence, traffic distribution, incident rate, and improvement
  are `unknown` / `measurement_pending`; `production_improvement_claim=false`.
- Safety redlines are non-compensable: any formal multi-selection, unauthorized write, tenant leak,
  deleted-data resurrection, secret/PII exposure, or unapproved runtime boundary fails regardless of
  documentation completeness.

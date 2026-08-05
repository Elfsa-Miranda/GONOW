# ADR-P10-003: Bind the personal Release B Gemini route pair

- Status: `provisional_accepted_for_personal_certification`
- Decision date: 2026-08-02
- Decision owner: repository owner directive authorizing automated repair, bounded live testing, and completion
- Implementer: Codex
- Scope: Release B Worker model provider, fixed route IDs, live-provider certification, cost cap, and rollback
- Trigger: `BLK-P10-009-report-only-certification-gap` plus the reproduced absence of a concrete `ModelAdapter`

## Context

Phase 4 implemented the certified two-tier routing and gateway contracts but intentionally did not select production model IDs or an endpoint. P10 inspection found no concrete `ModelAdapter`; the Worker could run only when tests injected a deterministic processor. Consequently a caller-written provider receipt could not prove that GoNow's Worker could call a real provider.

The current personal-project environment exposes a `GEMINI_API_KEY`. A credential-safe `GET /v1beta/models` on 2026-08-02 showed that the key can discover non-preview `gemini-3.1-flash-lite` and `gemini-3.6-flash` generate-content model IDs. This observation proves discoverability at that instant, not a permanence guarantee. Google's official API reference fixes the `generativelanguage.googleapis.com` request origin and `x-goog-api-key` authentication. The official pricing page identifies Flash-Lite as the cost-oriented tier and Flash as the more capable tier. Rate limits remain project/tier dependent and therefore must be measured rather than assumed.

## Decision

For the personal Release B candidate, bind exactly one provider and two non-dynamic routes:

| Route | Model | Capabilities | Purpose |
|---|---|---|---|
| `gemini-economic-v1` | `gemini-3.1-flash-lite` | `json` | Normal bounded itinerary generation and retry destination where capabilities permit |
| `gemini-capability-v1` | `gemini-3.6-flash` | `json, complex` | Requests over seven days or with at least four hard constraints; bounded fallback from the economic route |

The endpoint origin is exactly `https://generativelanguage.googleapis.com`; redirects, caller-provided URLs, caller-provided model IDs, preview aliases, and cross-provider fallback are prohibited. The credential is resolved from `GEMINI_API_KEY` for each invocation and is never placed in request data, evidence, logs, repr output, checkpoints, or model results.

The live certification performs 200 logical calls per route, splits each route into frozen baseline/candidate halves for p95 cost-drift detection, reads provider usage metadata, accounts for candidate and thinking tokens, and writes no prompt or response body. Its pre-call maximum is USD 0.25. A route opens a quota circuit after three consecutive HTTP 429 responses, preserving the failure set without issuing hundreds of known-useless calls.

The Worker uses strict JSON response schema plus Pydantic/business validation. It rejects incomplete output, wrong day cardinality/order, items crossing a day boundary, claim IDs without evidence, missing usage, and any model/endpoint outside the fixed table. The API process remains unable to invoke the provider.

## Alternatives considered

| Option | Safety/data | Compatibility | Cost/operations | Decision |
|---|---|---|---|---|
| Keep only the protocol and fake adapters | No credential risk, but cannot prove a usable Worker | Existing tests stay green | Produces false live-readiness confidence | Rejected |
| Use `*-latest` aliases | Easy upgrades but mutable behavior without a new Behavior digest | Output can drift silently | Operationally simple, evidentially weak | Rejected |
| Use preview models | Access to newer features | Higher churn and stricter quotas | Unstable certification surface | Rejected |
| Fixed non-preview Flash-Lite/Flash pair | Least-privilege fixed boundary; no dynamic routing | Preserves the approved two-tier contract | Low bounded cost and measurable quota | Selected |

## Residual risk

- Provider model implementations can change behind the fixed model IDs; each certification therefore records retrieval time, route/model IDs, usage, pricing snapshot hash, and candidate OID.
- The current key's billing tier and quotas are external state. A missing 400-call allowance keeps C2 blocked and cannot be repaired by reducing the mandatory denominator.
- A live provider micro-contract does not replace the final owner canary through API, PostgreSQL, Worker, Candidate read, adoption, kill switch, and old path.
- Pricing-page text can change after the frozen snapshot; later candidate runs must refresh the source hash and explicitly review rate changes.

## Rollback

Keep allocation at zero, stop the Worker, and revert the adapter/processor/composition commit. The legacy route and all runtime evidence remain intact; no schema or production data rollback is needed. Any replacement model/provider requires a new ADR, Behavior digest, live certification, four-hour soak, and owner canary.

## Primary references

- Google Gemini API reference: <https://ai.google.dev/api>
- Google Generate Content API: <https://ai.google.dev/api/generate-content>
- Google Gemini pricing: <https://ai.google.dev/gemini-api/docs/pricing>
- Google Gemini rate limits: <https://ai.google.dev/gemini-api/docs/rate-limits>

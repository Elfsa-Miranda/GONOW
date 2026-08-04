# Phase 12B Cost Router knowledge transfer

hardest_item_count: 2

## Responsibilities and dependency choices

The package keeps one Agent codebase with `agent-api`, `agent-worker`, PostgreSQL, and static internal
tools. Model Platform owns the deterministic router/adapters/ledger; Eval, Finance, Privacy, and
Security own the remaining independent review. No central model gateway, routing model, dynamic
provider market, new process, database migration, or Multi-Agent framework was introduced.

## Hardest items

The first hard boundary was proving that provider-side structured-output configuration is not local
output validity. DeepSeek now receives the complete canonical JSON Schema, Gemini receives its
provider-compatible projection, and both outputs pass the same local Schema and itinerary business
rules. Every JSON primitive is covered; booleans are not accepted as numbers and non-finite numbers
fail. Invalid bodies are not stored or echoed.

The second hard boundary was improving model behavior without relaxing quality. The first live
result was preserved. Failure codes isolated daylight, late-night, and globally unique item-ID
semantics. Exact minute boundaries and deterministic cross-day IDs were added to the prompt contract,
then each repair was checked on captured/fake data before the smallest useful live scenario. The
latest frozen DeepSeek set is 10/10 qualified.

## Operations must know

- Candidate allocation is zero and the router is default-off.
- First inspect policy/price/Schema digests, provider certification/health, route reason, reservation,
  physical attempts, validation code, and fallback depth.
- Fallback depth may not exceed one. Quality, privacy, region, Schema, safety, or budget failure
  cannot be compensated by cost.
- Never log API keys, prompts, response bodies, tenant/user identity, or hidden reasoning.
- Gemini rate-limit/5xx is an external availability blocker. Do not repeat calls without a new signal.
- Rollback bypasses the router, restores the prior policy digest, retains content-free receipts, and
  does not remove historical negative evidence.

## Evidence and estimate comparison

The latest DeepSeek set contains ten distinct frozen scenarios. Across all P12B live work there were
30 calls, 23,108 tokens, and CNY 0.03644 of frozen-price cost. The bounded certification sequence
used 14 DeepSeek calls, 16,100 tokens, and CNY 0.022832. Those figures are actual local experiment
counts, not a production bill forecast. The offline replay's lower candidate cost is diagnostic only
because Gemini has no non-zero comparable live baseline.

## Handoff verification and known risks

Local verification covers routing determinism, eligibility, complete Schema delivery, canonical and
business validation, metering, concurrency, one-hop fallback, rollback, redlines, replay, bounded
live quality, and the complete regression. It does not impersonate an independent reviewer.
Production provider eligibility, traffic mix, stable Gemini availability, cost, latency, incidents,
and quality remain unknown or pending. Formal Eval/Finance/Privacy/Security review and Release C
acceptance remain `pending_external`.

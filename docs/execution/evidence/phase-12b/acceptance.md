# Phase 12B local provisional acceptance candidate

Local status: `ready_for_review`. This is not formal acceptance, production enablement, or proof of a positive Cost Router benefit. The only authorized next integration actions are TASK-P12-089 registration and a local no-ff merge into `codex/gonow-agent-landing`.

- Phase base OID: `f941051871ecd7ea811540072a032ce7aaa0119d`
- Candidate head OID: `e926e1b88063a10b1bba808e2a5f64b4c7b87d80`
- Selected candidate: `P12B`
- Frozen route: `server:itinerary_generation`
- Architecture: Single-Agent; no Multi-Agent framework added

## Delivered scope

P12B adds a deterministic, default-off local Cost Router with fixed route policy, conservative price arithmetic, append-only idempotent reservation/commit/release/reconcile ledger semantics, one-hop fallback, budget and safety guardrails, DeepSeek and Gemini adapters, full local output Schema/business validation, content-free failure codes, frozen replay/calibration tools, and allocation-zero rollback.

DeepSeek receives the complete canonical JSON Schema and exact machine-enforced itinerary semantics. Unknown input strings remain untrusted data. Schema-invalid, business-invalid, truncated, malformed, provider-error, budget-error, and fallback paths fail closed and retain metering without persisting prompts or response bodies.

## Mechanical result

- CI: 15/15 gates; 830 unit and 233 contract tests passed.
- Flutter: 124 tests passed.
- Existing RealPG/fault/migration guardrail: 53 tests passed.
- Failed, skipped, xfailed, and redline counts: 0.
- A first incomplete CI attempt exposed missing JSON `boolean` support; its 3 failures are preserved. The repaired primitive dispatcher passed 38/38 affected tests before the one completed regression above.

## Quality, cost, and routing boundary

The latest live result for each frozen DeepSeek stratum is quality-qualified: 10/10, with zero remaining Schema/business-rule or provider failures and 8.4 seconds p95. Calibration all-attempt cost per final qualified scenario is 285.4 microUSD. All P12B live experiments used 30 calls, 23,108 tokens, and an estimated 4,555 microUSD (0.03644 CNY at the frozen rate), below all caps.

The paired offline replay produced 969.3 versus 131.0 microUSD per successful task, but it is synthetic mechanics/price-formula evidence only. Gemini produced zero qualified live baseline successes; its repaired adapter was verified offline and further live calls were stopped. Therefore live relative cost, live quality non-inferiority, and positive benefit are not computable. Candidate allocation remains 0, the router stays default-off, and no cost-saving or production-suitability claim is made.

## Formal gaps

- Stable Gemini provider/account availability and a non-zero paired live baseline: blocked external.
- Independent reviewer and formal governance acceptance: pending external.
- Production traffic, bill, latency, incident, and quality facts: `unknown`.
- Production allocation: 0%; production writes: 0; remote pushes: 0.
- `main` and `origin/main` remain `142abfc339f003ede8d85d9534336923b5610252`.

# ADR-P10-005: Use DeepSeek V4 Flash for the Phase 10 C2 test model

- Status: `accepted`
- Decision date: `2026-08-05`
- Decision owner: repository owner, by explicit task directive in this execution
- Scope: Phase 10 `TASK-P10-009` C2 live-provider certification only
- Production allocation: `0`

## Context

The unfinished C2 shard was frozen to Gemini and could not supply its required
live denominator. The repository owner explicitly authorized changing the C2
fixed test model from Gemini to DeepSeek while requiring all Gemini evidence to
remain intact and all existing C2 quality, security, latency, cost, and failure
thresholds to remain unchanged.

The repository already contains a fail-closed DeepSeek adapter whose literal
endpoint is `https://api.deepseek.com/chat/completions`. As of this decision,
DeepSeek's official API documentation lists `deepseek-v4-flash` as the current
Flash model, supports JSON output, and prices cache-hit input, cache-miss input,
and output at USD `0.0028`, `0.14`, and `0.28` per million tokens respectively.

## Decision

C2 live certification now uses this immutable contract:

- provider/model: `deepseek-api` / `deepseek-v4-flash`;
- complete response Schema:
  `agent-service/tests/certification/deepseek-c2-itinerary-response-v1.schema.json`,
  SHA-256 `f91ef09266edc913eb8adfad48907682c6fe8c90da3d03fb7d2c76db8fe084ee`;
- parameters: thinking disabled, `response_format={"type":"json_object"}`,
  `temperature=0`, `stream=false`; `top_p`, presence penalty, and frequency
  penalty are omitted; maximum output is `512` tokens per call;
- maximum input accounting: `2048` tokens per call;
- routes and denominator: logical `economic` and `capability` routes both use
  the same fixed model, with exactly `200` successful calls required on each;
  failures and circuit-open slots remain in the original `200`-slot per-route
  denominator and cannot be combined across candidates or configurations;
- request rate: no more than `20 RPM` in the repository executor;
- pricing: official DeepSeek USD price page retrieved on `2026-08-05`, with the
  three rates above; the live run also hashes a fresh response from that page;
- projected worst-case cost: USD `0.172032`; hard budget remains USD `0.25`,
  aggregate cost-to-budget remains `<=1.2`, and p95 cost increase remains
  `<=15%`;
- quality and safety: every successful call must pass the complete local JSON
  Schema and itinerary business-rule validator; prompt, response, reasoning,
  credentials, and provider error bodies are never persisted; all C2 redlines
  remain zero;
- latency: the existing C2 local API p95 one-sided 95% upper bound remains
  `<=800ms`. Provider call latency is recorded as a diagnostic and does not
  replace or relax that API threshold.

New evidence is additive under
`docs/execution/evidence/phase-10/P10-009/deepseek-v1/`. The legacy Gemini
executor, configuration, ADR, repair notes, and any historical receipts are
read-only evidence and are not deleted, renamed, or overwritten.

## Alternatives considered

| Option | Evidence and safety | Cost and delivery | Decision |
|---|---|---|---|
| Keep retrying Gemini | Preserves the old provider but does not resolve the missing denominator | C2 remains blocked | Rejected by owner directive |
| Re-label prior DeepSeek Phase 12B calls as C2 | Breaks task, candidate, configuration, and denominator identity | Cheap but invalid | Rejected |
| Use `deepseek-v4-flash` with a new C2 run | Preserves historical evidence and produces one comparable frozen denominator | Worst-case USD `0.172032` | Selected |
| Reduce calls or use only a small JSON probe | Would lower quality and failure coverage | Faster but non-compliant | Rejected |

## Verification and rollback

Fake transport, derived captured-envelope, strict configuration, complete
Schema, local business validation, content-redaction, budget, denominator, and
quota-circuit tests must pass before any live request. The live run must then
produce `200+200` successes with zero failed slots and the unchanged aggregate
predicates.

Rollback is a normal revert of the DeepSeek C2 runner selection and supporting
path bindings. It does not delete either provider's evidence, change a
production route, enable user allocation, alter database state, or restore a
secret. Any failed live run remains immutable negative evidence.

## Official references

- `https://api-docs.deepseek.com/quick_start/pricing`
- `https://api-docs.deepseek.com/guides/json_mode/`
- `https://api-docs.deepseek.com/api/create-chat-completion`

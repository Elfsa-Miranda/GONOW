# BLK-P12B-060 — Gemini live baseline unavailable

- Severity: P2 local evidence blocker; it does not block safe local implementation.
- Owner path: ModelPlatform → provider/account owner.
- Scope blocked: non-zero live Gemini baseline, live cost-per-success comparison, positive Cost Router benefit claim, and any allocation above zero.
- Scope not blocked: DeepSeek output-contract repair, DeepSeek-only quality/cost calibration, offline Gemini adapter compatibility, full regression, local provisional merge, or `ready_for_review` with an honest negative benefit boundary.

## Evidence and root cause

P12B-060 v1 produced zero Gemini successes: three calls were collapsed by the old adapter to `llm.provider_rejected` and one was rate limited. The immutable v1 evidence contains no response body, so the three historic causes remain `unknown`.

P12B-060 v2 used the repaired finite classifier and again produced zero Gemini successes: one `llm.request_invalid`, two `llm.rate_limited`, and one `llm.provider_unavailable`. It produced no `llm.model_not_found`, authentication, permission, or account code. Repeating calls merely to obtain a green baseline is prohibited by direct user instruction.

The official Gemini `generateContent` contract says `responseJsonSchema` supports a subset of JSON Schema. The full local itinerary schema contains `pattern`, `minLength`, `maxLength`, and `uniqueItems`, which are outside the documented provider subset. The adapter now removes only those unsupported provider hints while retaining the complete local fail-closed Schema and business validation. This compatibility repair is verified with captured responses and fakes; it will not be live-tested in this Phase.

Official contract: `https://ai.google.dev/api/generate-content` (observed 2026-08-05 Asia/Shanghai).

## Impact and decision

- Gemini live qualified successes: `0`.
- Live baseline cost per qualified success: undefined.
- Candidate versus baseline live cost ratio: undefined.
- Candidate allocation: `0`.
- Positive Cost Router benefit claim: forbidden.
- Production suitability: `unknown`.

DeepSeek becomes the primary model for the remaining local quality validation. Its single-arm success rate, rule codes, latency, retries, tokens, and estimated unit cost may be reported, but they do not substitute for a live baseline.

## Recovery condition

A future, separately budgeted run may clear this blocker only after the provider/account owner supplies a stable usable Gemini quota, the price snapshot is refreshed if expired, captured-response contracts pass, and a preregistered paired cohort produces non-zero qualified successes in both arms. No recovery call is authorized in the current Phase 12B execution.

## Rollback

Runtime allocation is already zero and the router is default-off. Revert the P12B repair commits to restore the prior adapter; v1/v2 evidence remains immutable. No remote or production write occurred.

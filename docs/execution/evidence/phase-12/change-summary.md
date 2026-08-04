# Phase 12B local provisional change summary

The user selected 12B as this cycle's only candidate. The implemented scope is exactly the existing
server-side itinerary-generation model boundary. 12A and 12C remain dormant; the earlier P12D local
package is retained as historical `ready_for_review` evidence and receives no new work or allocation.

The package adds a deterministic certified-route policy, fixed DeepSeek adapter, content-free budget
reservation/reconciliation ledger, one-hop fallback, default-off wiring, replay/calibration tools,
and local canonical JSON Schema plus itinerary business-shape validation for both providers. The
DeepSeek model receives the full canonical Schema. The Gemini provider projection was repaired and
validated offline. Invalid or unsafe output fails closed, remains billed, and is represented only by
a finite rule code; prompts, responses, keys, tenant identity, and user content are not persisted in
routing or cost evidence.

The immutable P12B-060 v1 result remains negative. Targeted repair then used captured responses and
fakes before bounded live checks. The latest frozen DeepSeek result is 10/10 quality-qualified with
zero Schema, business-shape, provider, fallback, or safety-redline failures and p95 latency 8,400 ms.
All P12B live calibration used 30 calls, 23,108 tokens, 4,555 micro-USD, or CNY 0.03644 under the
frozen conversion. Gemini produced no qualified live baseline after classified rate-limit/5xx
availability failures; further calls were stopped and the external blocker retained.

Offline paired fake replay is 10/10 in both arms and shows a synthetic mechanics/price ratio of
0.135149, but it is not a live benefit claim. With baseline success equal to zero, paired live
quality non-inferiority and relative cost/success are undefined. Allocation remains zero and
`positive_benefit_claim=false`.

The corrected P12B-990 regression passed 15 CI gates, 830 unit tests, 233 contract tests, 124 Flutter
tests, and 53 isolated P12D RealPG/fault guardrail tests with zero failures, skips, xfails, denominator
exclusions, or safety redlines. The first incomplete regression failure and its JSON primitive root
cause are preserved separately. These results establish a local engineering candidate, not
production quality, savings, provider eligibility, traffic behavior, or formal acceptance.

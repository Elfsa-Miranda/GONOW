# Release C governance and rollback runbook

## Current safe state

`formal_selection_status=local_provisional_selected`, `selected_candidate=12B`, and
`selected_count=1`. The deterministic Cost Router package exists locally only for server-side
itinerary generation. Candidate allocation and production writes are zero. Formal owner review,
provider production eligibility, remote integration, deployment, and Release C acceptance remain
pending. 12A and 12C are dormant; the earlier P12D package remains historical `ready_for_review`
evidence and is dormant for this cycle. No Multi-Agent framework exists.

## First checks

1. Bind the candidate to a full Git object ID and verify the worktree is clean.
2. Confirm route scope is exactly `server:itinerary_generation`, policy is deterministic, and
   candidate allocation is zero by default.
3. Verify the pinned policy, price snapshot, fixed provider/model IDs, Schema digest, region/privacy
   eligibility, provider health, and content-free reservation ledger.
4. Verify the model receives the complete canonical JSON Schema and that both adapters run local
   Schema plus itinerary business-shape validation before returning a Candidate.
5. Check finite failure codes, physical-attempt token/cost accounting, one-hop fallback depth,
   kill switch, and rollback digest. Never inspect or persist response bodies or API keys.
6. Preserve the immutable P12B-060 v1 negative result. For the latest DeepSeek set, expect 10/10
   qualified scenarios and zero Schema, business, provider, fallback, or safety-redline failures.
7. Treat the Gemini live baseline as externally blocked after its classified rate-limit/5xx
   failures. Do not retry merely to obtain a green baseline.

## Enable, disable, and degrade

There is no production enable command in this local provisional package. Any future enablement
requires approved provider eligibility, fresh prices, owner-frozen quality margins, production
observability, a non-zero comparable baseline, and explicit rollout authority.

| Candidate | Enable only after | Disable / first rollback action | Degraded behavior |
|---|---|---|---|
| 12A Memory | new XOR cycle, privacy/data approval, CT-009/015, deletion/restore drill | allocation zero; disable reads/proposals; retain tombstones/audit | Release B single Agent without Memory |
| 12B Cost Router | certified routes, non-zero paired baseline, quality non-inferiority, cost/success, latency/fallback/redline gates, owner approval | candidate allocation zero; bypass router; restore previous policy digest; retain decision/cost ledger | pinned certified baseline or existing fail-closed policy |
| 12C Multi-Agent | fresh positive XOR cycle and separately approved package | allocation zero; return to one graph; retain experiment evidence | Release B single Agent |
| 12D Domain Command | a future independent cycle and production authorization | keep its flag off for new intents; retain receipts/outbox | legacy authorized writer; unknown outcomes still use receipt lookup |

Fallback is bounded to one additional physical call and is never recursive. A quality, Schema,
privacy, region, certification, or budget failure cannot be compensated by a lower cost. Unknown
labels, stale prices, missing certification, exhausted budget, or invalid output use the pinned
fail-closed behavior. The cost ledger reconciles every billed attempt, including failures and
fallbacks, before releasing a reservation.

Global rollback order is: set candidate allocation to zero, activate the kill switch or bypass the
router, pin the previous policy/price digest, preserve evidence and content-free receipts, run the
focused equivalence checks, then diagnose. Never roll back by deleting audit rows, restoring revoked
secrets, force-pushing, or writing directly to production.

## Failure handling

Use one root-cause loop: reproduce with captured response/fake first, identify the failing Schema or
business rule/provider class, apply the smallest reversible fix, run the minimum affected check, and
then expand only when that check cannot prove the repair. Run full end-to-end verification at final
acceptance. A repeated provider rate-limit/5xx without a new signal is an external availability
blocker, not a reason for repeated paid calls.

Missing independent review or Gemini availability blocks formal comparison, production allocation,
remote merge/push, and deployment. It does not invalidate completed local adapter, fake/replay,
DeepSeek calibration, cost-ledger, safety, rollback, or regression evidence.

## Merge and audit retention

Phase commits land through one history-preserving local integration on
`codex/gonow-agent-landing` after the applicable provisional gates pass. Never push a Phase branch to
`main`, and never use local evidence to claim Release C acceptance. Retain the immutable v1 negative
result, captured-response fixtures, exact finite rule codes, price/policy/Schema digests, token and
cost counts, provider failure classes, candidate/merge OIDs, rollback result, and artifact hashes.
Evidence must contain no secrets, personal data, full prompts/responses, or hidden reasoning.

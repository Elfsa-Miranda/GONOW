# Release C selection interface boundary

## Public API status

Phase 12B changes only the existing Worker model boundary for itinerary generation. The Cost Router,
DeepSeek adapter, cost ledger, and validation are internal Python components. Published OpenAPI,
Event/State/Candidate/SSE schemas, Flutter/Dart contracts, database schema, and process topology are
unchanged.

runtime_change_count: 1
public_contract_change_count: 0
schema_change_count: 0
production_write_count: 0
selected_count: 1
candidate_allocation: 0

## Governance record shape

The following is a documentation model for later evidence, not a network API or an approval:

```json
{
  "schema_version": "1.0",
  "cycle_id": "owner-issued immutable identifier",
  "release_b_head_oid": "full Git object ID",
  "route_scope": "server:itinerary_generation",
  "policy_digest": "sha256",
  "price_snapshot_digest": "sha256",
  "schema_digest": "sha256",
  "selection": "12A|12B|12C|12D|none",
  "selected_count": 1,
  "candidate_allocation": 0,
  "owner_decision_references": [],
  "production_write_count": 0
}
```

The formal runner must reject a missing or mismatched cycle, head, digest, owner identity, evidence
window, or XOR reservation. `selected_count=1` records the user's local 12B choice; it does not grant
production allocation or replace independent approval.

## Internal route and output contract

The router input is a closed typed request containing task class, required capabilities, region,
privacy class, quality floor, latency budget, policy/price/Schema digests, provider-health snapshot,
and remaining budget. Prompt, response, reasoning, secret, credential, tenant, user, and principal
content are not route factors. Route reasons are finite codes.

The DeepSeek request contains the complete canonical JSON Schema in its system instruction. The
Gemini request uses its provider-compatible Schema projection. Both returned payloads then pass the
same local canonical Schema validator and itinerary business-shape validator. Supported JSON
primitives include object, array, string, integer, number, boolean, and null; numeric validation
rejects booleans and non-finite values. Validation failure returns only a finite code and never the
response body.

The internal result remains the existing typed itinerary Candidate. No provider response can bypass
Schema/business validation, authorize a Tool or domain write, or change routing policy.

## Cost, fallback, and failure semantics

Budget is reserved before a physical call and reconciled from actual input/output token counts after
every success, rejection, timeout, invalid output, retry, or fallback. Cost per successful task is
total billed attempt cost divided only by quality-qualified successes; zero successes is
`undefined_fail_closed`.

Fallback depth is at most one and cannot recurse. Quality/safety redlines, region/privacy mismatch,
missing certification, stale prices, exhausted budget, invalid Schema/business shape, or an
unapproved provider fail closed under the pinned policy. Rollback sets allocation to zero, bypasses
the router, restores the previous policy digest, and retains content-free receipts.

## Evidence boundary

The latest DeepSeek scenario set is 10/10 quality-qualified, but Gemini has no non-zero live baseline
because its classified live calls hit external rate-limit/5xx availability. Paired live quality
non-inferiority and relative cost benefit are therefore undefined. Candidate allocation stays zero;
no production-quality, savings, eligibility, latency, or acceptance claim follows from local tests.

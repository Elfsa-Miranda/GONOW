# Phase 4 Behavior rollback runbook

## Scope

This runbook covers the local Phase 4 single-agent Candidate and Behavior deployment pointer.
It does not authorize remote push, merge, deployment, production traffic, production data
write, or Release acceptance.

## Normal disable and rollback

1. Disable the itinerary Agent feature flag for new routing. Confirm legacy chat, import,
   Auth, fallback, and flag-off itinerary paths remain available.
2. Stop admission of new Agent Runs if Behavior qualification, context compilation, model
   routing, tool validation, evidence validation, or Candidate projection is failing.
3. Select the last known qualified Behavior release and move the deployment pointer with
   the expected generation CAS. A stale generation must conflict; never overwrite it.
4. Verify a newly resolved Run receives the old qualified digest. Verify every already pinned
   Run still has its original release ID and digest.
5. Rerun the narrow affected P04 test, then `agent-service/scripts/ci.ps1 -Stage All`.

Rollback changes no existing Run pin and never edits a release, certification, or component
digest in place. If an old Run cannot be executed safely, keep it stopped for the later durable
resume/cancel phases; do not repoint its behavior silently.

## Degraded states

- Feature flag store unavailable: itinerary Agent selection falls back to legacy itinerary;
  legacy chat/import/Auth/fallback do not consult the store.
- Behavior pointer missing, unaudited, unqualified, or digest mismatch: reject new Agent Run
  resolution. Do not select an uncertified release.
- Model tier unavailable: use only the authenticated, certified fallback route and its two-
  attempt cap. Otherwise fail the affected action closed.
- Tool input unknown or over budget: reject the tool call; never use URL/SQL/file/shell or MCP
  as an ad hoc substitute.
- Evidence or schema invalid: return no formal write and retain the typed issue for bounded
  repair. Stop after two repairs or no progress.

## First checks

1. Record the stable error code and affected Run/reference without request or response bodies.
2. Compare the resolved Behavior package digest and eleven component digests with the release.
3. Check feature-flag version, graph stage, exhausted budget dimension, and repair/no-progress
   counters.
4. Check Tool Registry name/argument validation and claim verification status.
5. Run the P04-010 E0 evaluator and confirm the frozen dataset/scoring hashes did not change.
6. Escalate any secret/PII exposure, cross-tenant access, production write, data loss, or
   irreversible external action immediately; those conditions are not local degradation.

## Local verification limits

The local rollback tests prove pointer CAS, new-Run selection of the previous digest, immutable
old-Run pins, and legacy bypass fixtures. A production same-configuration drill, real traffic,
provider cost/latency, and independent operator verification remain pending.

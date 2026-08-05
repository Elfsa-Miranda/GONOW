# Legacy fallback runbook

Status: local provisional Phase 1 runbook. It preserves existing product paths while the new Agent
service is built and does not authorize production activation.

## Scope and ownership

Flutter owns presentation, the editable buffer, and compatibility cache. The Release A gateway
remains the ordinary-chat compatibility path. The future `agent-api` and `agent-worker` own only
the bounded itinerary-planning path described by `contracts/flutter-agent-boundary-v1.yaml`.

## First checks

1. Determine whether the failure is chat, manual import, Auth, local fallback, or future itinerary
   planning. Do not route an old-domain incident into the future Agent path.
2. Confirm `agent_itinerary_planning_v1` is `false` unless a separately approved rollout is active.
3. Confirm the Release A gateway remains fixed-host HTTPS and no direct provider credential or
   endpoint has been restored.
4. Preserve the original user input as a local Candidate/draft and display the exact validation
   class. Do not claim a cloud or formal domain write.
5. Run `flutter test test/validation_semantics_test.dart` and compare the result with the committed
   fixture report before widening investigation.

## Degraded operation

- Gateway unavailable: return the fixed compatibility error; never fall back to the provider.
- Validation/parser unavailable: retain a raw Candidate with a `hard` label and formal writes off.
- Evidence lookup unavailable: label the affected finding `unverified`; do not guess.
- Normalization unavailable: keep the original Candidate and any partial output as a separate,
  clearly labelled draft.
- Auth unavailable or unverifiable: fail closed; do not accept a client-asserted principal.

## Disable and rollback

Disable new itinerary Runs by setting `agent_itinerary_planning_v1=false`. Keep existing chat,
manual import, Auth, and fallback paths. Do not delete adapters, restore a client model secret, or
discard Candidate/evidence records. Later durable Runs must complete or recover under their bound
Behavior version rather than being silently reassigned.

## Escalation

Secret exposure, cross-tenant access, unauthorized formal write, or data loss is a P0/P1 boundary:
stop the affected route and preserve evidence. Production schema/RLS/grants, provider revocation,
and independent owner approval remain external pending items; local fixtures must not be presented
as production proof.

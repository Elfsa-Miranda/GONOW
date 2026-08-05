# Flutter Agent client contract

Status: API version `1.0.0`, local provisional. OpenAPI SHA-256:
`ba776e2c464ff6faf1866c7e369756368a43b5023642ac6318758e55f857b8ed`.

## Generated surface

`contracts/openapi/agent-api.yaml` is the source. The locked offline generator emits
`lib/core/api/generated/agent_api.g.dart`, `agent_api_client.g.dart`,
`agent_api_models.g.dart`, and `agent_api_spec.g.dart`. Generated files are not hand-edited. The
client exposes the versioned Run create/read surface, SSE event stream, interrupt resume, and cancel
operations already present in the server contract.

`AgentRunRepository` is the Flutter adapter boundary. It supplies typed command values and receives
typed receipts/results. Raw transport errors, response bodies, authorization values, and resume
capabilities are not persisted or presented to the user. Unknown or malformed responses fail as a
typed public error.

## Candidate and adoption

Run output is projected into a typed Candidate preview. Viewing or rejecting a Candidate performs
zero business writes. Adoption requires explicit approval and conflict acknowledgement when
applicable. The Phase 9 service command checks trusted identity, capability, nonce replay, and
expected version, then atomically records the isolated itinerary effect, Event/audit, and outbox.

The authoritative production itinerary mapping is unresolved and recorded separately. Therefore
the local command receipt is not a claim that production itinerary tables were updated.

## Compatibility

The committed matrix contains exactly four pairings: old app/old service, old app/new service, new
app/old service, and new app/new service. Historical inputs are Git objects at the Phase base. The
old and new service OpenAPI blobs are equal for this contract. Digest mismatch, service unavailable,
and generation mismatch all choose the safe legacy route. Forced upgrades and adapter deletions are
zero.

## Lifecycle operations

- Enable: use matching nonzero generations, an exact contract digest, an available Agent route,
  enabled itinerary flag, and a cleared kill switch in an authorized isolated environment.
- Disable: activate the kill switch or disable the itinerary flag; ordinary chat never enters the
  Agent planning route.
- Degrade: on compatibility, availability, replay, authorization, or generation failure, return a
  typed failure and retain the legacy path. No error is converted into a successful receipt.
- First checks: route reason, generations, digest, Run ID, last event ID, typed failure code, and
  adoption receipt/outbox result.

## Evidence limits

Local contract and Flutter tests verify the adapter behavior, but independent API/Product/SRE
review, real-device execution, production mapping, remote merge, deployment, and acceptance remain
`pending_external`.

# Release A security boundary

Status: `local_provisional`; candidate `307567a5befb9e3110bd857c3563de4dad099235`; independent Security/Data/Product review pending.

## Boundary

The Flutter client may call only `POST /v1/release-a/chat` on an explicitly enabled HTTPS origin whose host exactly matches the independently supplied allowed host. The request requires the current authenticated user session, has bounded messages and payload size, and cannot choose a model, provider, credential, system prompt, or arbitrary URL.

Missing configuration, disabled routing, missing auth, timeout, malformed response, non-JSON response, or gateway error fails closed. There is no client direct-provider fallback. The compatibility constants for the former provider route are empty tombstones and must never be repopulated.

The gateway contract is ordinary-chat containment, not the target Agent runtime. It grants no model permission to a future `agent-api`, implements no Graph/Tool/Memory/RAG behavior, and is not a base for the Phase 2 `agent-service/` module.

## Data and logging

Chat messages and optional current-plan context may cross this boundary only after the production gateway is approved. The client no longer emits free-form debug messages from the AI, itinerary, and diary providers: fixed feature events retain source location while prompts, responses, tokens, URLs, identifiers, exception messages, and stack traces are discarded.

## Activation gate

Production activation remains prohibited until all of the following exist and bind the exact candidate:

- Security-approved gateway origin and server implementation;
- Secret Provider, auth, tenant/user rate limits, and spend caps;
- vendor revocation and billing/use review for the historical credential;
- approved read-only production schema/RLS/grant inventory;
- independent Engineering, Security, Data, and Product decisions required by the task cards.

The safe rollback is to disable the gateway and show the existing fail-closed message. Rollback must never restore a client key or provider-direct route.

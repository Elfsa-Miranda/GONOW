# ADR-P00-005: Release A ordinary-chat gateway

Status: `local_provisional_candidate`; Architecture, Security, Product, and Engineering approval pending.

## Context

The baseline Flutter package contains a model-provider credential and sends ordinary-chat requests directly to a provider. The credential is extractable from tracked source and client artifacts. TASK-P00-003 cannot prove vendor revocation without owner authorization, but local containment must not preserve the exposure while that external action is pending.

## Decision

Ordinary chat uses only `POST /v1/release-a/chat` on a Security-approved HTTPS origin. The client deployment must provide an enabled flag, gateway URL, and independently configured allowed host; all three must agree before a request is created. The path is fixed in code, user authentication is required, request size and roles are bounded, response type and size are checked, and errors never expose response bodies.

The client contract contains no model-provider credential, endpoint, model selector, system prompt, or arbitrary URL. There is no direct-provider fallback. Missing configuration, disabled routing, missing authentication, timeout, malformed response, or gateway failure all fail closed.

Legacy provider constants remain as empty compatibility tombstones so older diary and itinerary call sites compile but cannot send a credential or provider request. They must be migrated in later reviewed tasks and must never be repopulated.

The server implementation is intentionally not invented in this task because the current plan supplies no approved server implementation path or SecretProvider reference. Production activation remains prohibited until the server boundary, auth/rate/cost enforcement, SecretProvider, endpoint, and owners are approved and evidenced.

## Alternatives considered

- Keep the client credential until rotation: rejected because it preserves an active exposure window.
- Accept a provider key through runtime configuration: rejected because mobile runtime configuration remains client-extractable.
- Allow a client fallback to the provider: rejected because rollback must never restore the leaked path.
- Let the client choose an arbitrary HTTPS gateway: rejected because that weakens SSRF and authorization review.

## Security, data, compatibility, cost, and rollback

- Security: fixed path, exact host binding, user bearer auth, bounded JSON, no provider secrets, no raw error bodies, and no direct fallback.
- Data: chat content and optional current-plan context cross only the approved gateway boundary; production retention and downstream provider use remain pending owner approval.
- Compatibility: ordinary chat retains its UI flow; absent gateway configuration shows a stable fail-closed message. Legacy AI affordances compile but cannot make provider requests.
- Cost: the server must enforce per-user and per-tenant rate and spend caps before activation; the client cannot override them.
- Rollback: disable the gateway route or revert client routing, but never restore the provider credential or direct-provider request.

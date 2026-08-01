# Phase 4 single-agent behavior boundary

## Scope and status

Phase 4 implements one bounded itinerary-planning behavior inside `agent-service/`.
It is a `local_provisional` candidate: the public OpenAPI has no planning endpoint,
the Flutter client is not connected, and no production model, tool, tenant, or data
was used. Formal Product, Eval, Privacy, and Security review remains pending.

## Runtime shape

The behavior has one typed `GoNowAgentState` and a fixed six-stage path:
`intake → plan → evidence → compose → validate → complete`. State contains only
serializable business facts, counters, UUIDs, digests, and opaque references. Prompt,
response, reasoning, provider client, connection, credential, and secret bodies fail
closed at the state guard.

Six independent fuses bound steps, model calls, tool calls, tokens, deadline, and
no-progress rounds. The graph has no second planner or dynamic delegation. Candidate
repair is capped at two rounds and stops when the normalized issue set makes no progress.

## Context, model, and tool boundaries

The context compiler accepts only typed, prioritized fragments and an injected tokenizer.
Hard constraints cannot be silently truncated; an oversized mandatory fragment fails
closed. Compiled state stores references and digests rather than prompt or evidence bodies.

The model registry exposes one certified provider through two named tiers: economy and
capability. A fallback requires an authenticated allowlist and is capped at two attempts.
Endpoint URLs are not accepted from a request, and prompt/response/reasoning bodies are not
persisted by the gateway.

The static Tool Registry contains exactly POI, route, and weather. Typed argument validators
reject unknown fields and unknown tools. Each kind permits at most two calls. There is no
dynamic discovery, URL fetch, SQL, file, shell, arbitrary execution, or MCP adapter.

## Evidence and Candidate

Tool observations become typed claims with explicit verified, unverified, or conflicted
status. Only verified claims may support citations. Output SchemaGuard rejects broad maps,
unknown fields, invalid schedules, unsupported citations, and formal-write requests. The
Candidate projector is deterministic over Run, behavior digest, input digest, validated
output, and citations.

Candidate is the terminal Phase 4 artifact. It is not a Domain Command and cannot write a
formal itinerary, diary, or other business table. The public Candidate consumption contract
is documented in `docs/api/planning-candidate.md`.

## Behavior Package pinning

A new Run resolves one qualified, audited deployment pointer and verifies all eleven package
components against the package digest. The resulting release ID and digest are immutable for
that Run. Pointer movement uses generation CAS. A rollback changes the pointer only for new
Runs; an old Run continues on its original digest.

## Enable, disable, degrade, and first checks

- Enable locally: select the itinerary Agent route only with a valid, enabled feature flag
  and a qualified Behavior deployment. No command here authorizes production traffic.
- Disable: turn the itinerary Agent flag off. Legacy chat, import, Auth, and fallback never
  consult the Agent flag or handler.
- Degrade: flag-store failure, flag-off, unavailable Behavior qualification, invalid state,
  budget exhaustion, unknown tool, or invalid Candidate fails the affected Agent action
  closed. It does not restore client-side model direct access.
- First checks: inspect the stable reason code, selected flag version, Behavior release/digest,
  budget dimension, tool kind, Candidate issue set, and the corresponding P04 evidence report.
  Do not log prompt, response, reasoning, secret, PII, or tool payload bodies.

## Local evidence and non-claims

The frozen synthetic E0 contains 30 common and 10 boundary cases. Both the compatibility
fixture and typed-Graph fixture produced 40 results with no semantic differences, threshold
failures, critical-field mismatches, dataset drift, model/tool calls, or formal writes. This
is an offline deterministic baseline, not a production quality, latency, cost, privacy, or
availability claim.

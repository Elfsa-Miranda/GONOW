# Phase 4 change summary

Before Phase 4, the repository had Agent API/Worker and PostgreSQL Runtime persistence but no
planning Graph, typed planning state, model/tool gateways, evidence-qualified Candidate,
Behavior pin resolver, or E0 parity runner. Phase 4 adds those local contracts without adding
a public planning endpoint or production traffic.

Observable local differences:

- one typed, fixed six-stage planning Graph with six independent budget fuses;
- deterministic context compilation that never silently drops hard constraints;
- one provider with certified economy/capability routes and an authenticated two-attempt fallback;
- exactly three static typed tools: POI, route, and weather, with no dynamic discovery or MCP;
- verified-only citations, strict output schemas, bounded repair, and deterministic Candidate IDs;
- one immutable Behavior Package digest pinned per Run and generation-CAS pointer rollback;
- itinerary Agent flag-on is the only Agent route; legacy chat/import/Auth/fallback bypass it;
- a read-only 40-case synthetic E0 comparison with two offline adapters, no semantic differences,
  threshold failures, dataset drift, model/tool calls, or formal writes; and
- Harness controls 7–10, 12–13, 15–17, 19–23, 26, 30, and 31 move to implemented; control 11
  receives a Phase 4 resolution/rollback extension.

The public OpenAPI bytes are unchanged because Phase 4 does not expose a planning endpoint.
All Phase 4 implementation tasks are local `ready_for_review`; formal approvals, production
validation, remote push/merge, deployment, and `accepted` remain pending.

# Phase 9 change summary

Phase 9 changes the local candidate from a server-only Agent surface to a typed Flutter itinerary
integration. The itinerary screen can be routed by a default-off flag, create and control a Run,
recover a minimal Run cursor, project SSE into a Candidate preview, and submit an explicitly approved
Domain Command. Ordinary chat and all safe-fallback conditions keep the previous route.

Observable local differences:

- a locked OpenAPI generator now produces four Dart client files with an exact source digest;
- the Flutter repository exposes typed create, interrupt, resume, cancel, and failure results;
- a minimal active-Run reference survives restart without persisting bodies or credentials;
- SSE reconnect resumes from a persisted cursor, while disconnect and cancel remain distinct;
- Candidate evidence, warnings, diffs, and version conflicts are visible before any write;
- guarded adoption fails closed on stale version, forged capability, replay, and transaction error;
- a single successful isolated adoption creates one itinerary effect and one outbox effect;
- flag, kill-switch, generation, availability, and compatibility decisions retain the legacy route;
- no CQRS read model was introduced because the local pre-registered need threshold was not met;
- the critical local journey passes 10/10 exact-byte Flutter VM tests with zero skip.

Enable, Disable, Degrade, and First checks are documented in the architecture, API, and rollback
documents. This is local provisional evidence only. Production table mapping, independent review,
real-device execution, remote merge, deployment, and formal acceptance remain `pending_external`.

# Phase 1 change summary

Before this branch, validation/import behavior was spread across Flutter UI and providers, model
output used broad maps, hard/warning/unverified semantics were not versioned, and no explicit seam
separated future itinerary planning from old chat/import/Auth/fallback behavior.

The local candidate now publishes a strict validation schema and semantic contract, 8 synthetic
fixtures with 3 passing Flutter tests, a versioned Flutter/Agent boundary, and a complete mapping of
39 AGENTS 1.4.0 hard-constraint markers to phases/tasks and CT dispositions. Every result remains a
Candidate draft; no validation or fallback path enables a formal domain write. The future planning
flag is default-off and existing product paths are retained.

The phase adds contracts, tests, architecture/operations documentation, and evidence only. It does
not create an Agent service, call a model, change production data, deploy, merge, push, or activate
traffic. Independent Product/Security review and production-only facts remain pending.

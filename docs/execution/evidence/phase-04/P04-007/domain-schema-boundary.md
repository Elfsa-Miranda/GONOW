# P04-007 domain-schema boundary

- Assumption: no formally approved production itinerary write schema is proven in the repository. This task defines a minimal, frozen local Candidate schema only; `status=candidate` is not an accepted domain object and no Domain Command exists here.
- Impact: schema validation, bounded local repair, immutable evidence classification, verified-only citations, and deterministic projection are locally testable. Formal adoption/write compatibility remains pending Domain+Security review and is not claimed.
- Fail-closed behavior: broad/extra fields, Prompt/reasoning fields, missing or conflicted citations, ledger/schema dependency failure, history overwrite, a third repair, or no-progress repair returns a stable error.
- Rollback: turn off the unmounted Candidate path and remove these files; typed state, tools, model routes, Catalog, and formal business tables remain unchanged.
- Boundary: no remote push, merge, production write, business-table write, or acceptance was performed.

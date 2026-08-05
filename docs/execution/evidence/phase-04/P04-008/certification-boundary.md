# P04-008 certification boundary

- Assumption: no formal Phase 4 production Behavior certification receipt is available. Local tests use content-addressed synthetic manifests and the isolated Phase 3 PostgreSQL registry; they do not create an active production release.
- Impact: complete 11-component digest validation, certified-release resolution, Run pin immutability, pointer generation CAS, and rollback semantics are mechanically proven. Formal release certification and activation remain pending independent owner evidence.
- Fail-closed behavior: missing qualification/audit receipt, manifest/release mismatch, invalid component identity, or CAS generation loss returns a stable error. Existing Run pins never follow a mutable pointer.
- Rollback: CAS the pointer to the old certified release for subsequent Runs; existing Runs retain their original digest.
- Boundary: no remote push, merge, production deployment/write, release activation, or acceptance was performed.

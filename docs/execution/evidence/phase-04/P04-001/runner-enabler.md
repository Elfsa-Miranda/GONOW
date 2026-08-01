# P04-001 gate runner enabler

The frozen catalog declared seven P04-001 modes, Harness control 13, and exact state/context deliverables, while the materialized runner had no P04-001 handlers. This repair adds task-local Verify, Security, Evidence, WorksetVerify, and RollbackVerify behavior without changing the catalog or product contract.

Verify runs the exact two pytest files, binds the generated JUnit and state report, proves 100/100 JSON round trips and zero serialized secret canaries, and emits the Harness 13 S/I/D fragment. Security rejects executable injection patterns and requires the runtime-context serialization guard. Workset and Evidence enforce only the card allowlist and exact artifacts. Rollback proves the four new modules can be reverted without changing earlier behavior releases or E0 bytes.

The change is locally reversible by reverting this enabler commit. It performs no model call, database migration, production access, remote operation, or approval mutation.

Affected regression before commit: the runner contract suite passed; Agent CI passed 226 unit/integration tests and 44 contract tests with format, lint, type, dependency, license, secret, and clock gates green.

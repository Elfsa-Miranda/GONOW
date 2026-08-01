# ADR-P07-005: Optional OR-Tools solver process isolation

- Status: local provisional decision; formal Security and SRE approval pending
- Date: 2026-08-01
- Owners: Optimization, Security, SRE
- Scope: Phase 7 optional itinerary constraint solver only

## Context

The canonical validator and bounded repair path are deterministic and remain sufficient for ordinary candidates. Some larger constraint sets may benefit from a native solver, but the current repository has no production measurements proving that it should run by default. `AGENTS.md` requires any OR-Tools/native solver to run outside the API and Worker processes with a soft solver timeout and parent-owned hard kill. Enabling the package also makes CT-014 mandatory.

The official package index identified `ortools==9.15.6755` as the current release, Apache-2.0 licensed, compatible with Python 3.13, and supplied as a Windows x86-64 wheel on the review date. This version choice is dependency input only; the architecture and safety decision comes exclusively from the sealed GoNow guidance.

## Decision

1. Pin `ortools==9.15.6755` and regenerate the complete `uv.lock` graph.
2. Keep the feature disabled unless an explicit process-local flag constructs `SolverProcessRunner(enabled=True)`. The initial trigger is also bounded by a typed item-count threshold.
3. Import OR-Tools only inside a spawned, daemonized child process. The parent and child exchange one versioned Pydantic JSON request/result; no URL, command, module, environment override, tenant data, Prompt, secret, or arbitrary callable crosses IPC.
4. Set the CP-SAT soft limit from a bounded typed field. The parent joins only until the later hard deadline, then kills and joins the child before returning a deterministic original-order fallback.
5. A child crash, missing result, soft timeout, hard timeout, disabled flag, or unmet trigger always returns a typed stable reason and a valid fallback. It never retries, performs a Domain Command, or changes canonical validation results.
6. Treat CT-014 as mandatory while the dependency and enabled execution path exist. The replay test must prove the killed solver is gone, the test/main process remains alive, and fallback remains importable.

## Alternatives considered

| Option | Safety/data | Compatibility | Cost/rollback | Decision |
|---|---|---|---|---|
| Run OR-Tools in API/Worker process | Native hangs/crashes share the service failure domain | Simple call site | Violates hard constraint; unsafe rollback | Rejected |
| Separate long-lived solver service | Strong isolation | Adds network/API/deployment boundary | No measured need; broader SSRF/auth/operations surface | Rejected |
| Spawned child with typed local IPC | Parent can enforce hard kill; no network boundary | Windows/Linux spawn compatible | Per-call startup cost; flag can bypass instantly | Selected provisionally |
| Keep solver disabled and uninstalled | Lowest risk | Cannot satisfy this task's enabled CT-014 gate | Easy rollback | Retained as runtime flag fallback, not task result |

## Consequences and controls

- OR-Tools and its transitive native/data-science packages increase artifact size and supply-chain review scope; exact lock, SBOM, license, vulnerability, maintenance, and provenance evidence are mandatory.
- No default production enablement, traffic allocation, or performance claim is made. Production activation requires formal approvals and measured evidence.
- The child accepts only bounded scheduling primitives and cannot execute tools or reach network locations.
- Formal adoption is pending; this ADR does not authorize push, merge, deployment, production traffic, or Release acceptance.

## Rollback

Set the solver flag off, verify calls return `solver.disabled` with valid original-order fallback, revert the process module/test/ADR, remove the exact dependency, and regenerate `uv.lock`. Canonical validation and bounded local repair continue unchanged.

## Evidence source

- Official PyPI package record: https://pypi.org/project/ortools/9.15.6755/

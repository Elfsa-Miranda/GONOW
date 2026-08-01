# Validation and bounded repair

Status: local provisional Phase 7 candidate. Formal Product, Eval, Security, and SRE review is
pending. This document describes implemented repository behavior, not production proof.

## Boundary and data flow

The validation path accepts a versioned, typed constraint envelope and typed observations. The
canonical validator is pure and deterministic: identical typed inputs produce the same ordered
issues and one aggregate classification (`hard`, `warning`, `unverified`, or `verified`). It does
not call a model, execute a tool, write a domain table, or infer missing facts.

Evidence is classified separately as `verified_current`, `unverified`, `stale`, `conflicted`, or
`invalid`. Repository unavailability fails closed to `unverified`; malformed, conflicting, stale,
or absent evidence cannot become verified. Stable reason codes are the cross-layer contract.

When repair is requested, `BoundedLocalRepair` may apply only typed replacement operations under
`/items/<index>/<field>`. It performs at most two rounds, stops on no progress, rejects duplicate or
out-of-scope paths, and reports any original conflict that remains unresolved. Candidate generation
or repair never becomes a Domain Command and never writes formal itinerary state.

```text
typed constraints + typed observations
              |
              v
     canonical validator ---- evidence gate
              |                     |
              +---- stable issues --+
                          |
                  optional repair (0..2)
                          |
              typed candidate + unresolved issues
                          |
              user confirmation / later Domain Command
```

## Optional solver boundary

OR-Tools `9.15.6755` is exactly locked but runtime use is disabled unless the caller constructs
`SolverProcessRunner(enabled=True)`. Inputs below the configured item-count trigger return
`solver.not_needed`. Enabled work is serialized to bounded Pydantic JSON and sent through a one-way
local pipe to a spawned daemon child. Only the child imports native OR-Tools. The solver soft limit
is bounded by the request; the parent owns the later hard deadline, kills and joins a hung child,
and returns the original order as a valid fallback. There is no network endpoint, arbitrary
callable, environment override, Prompt, secret, or tenant credential in this boundary.

The initial normal-path hard deadline is 15 seconds because the measured Windows/Python 3.13 cold
native import was 8.9795798 seconds. The deterministic hang replay uses an independent 300 ms hard
deadline before native import. These are local evidence values, not production SLOs.

## Enable, disable, degrade, and first checks

- Enable: only in an authorized non-production process, explicitly construct the runner with
  `enabled=True`, retain the item trigger, and first pass CT-014 plus the dependency audit.
- Disable: construct it with `enabled=False` or bypass solver construction. The typed result is
  `solver.disabled` and preserves original order.
- Degrade: soft timeout, hard timeout, child failure, or unmet trigger returns a typed, importable
  fallback. It does not retry, modify canonical classification, or perform a write.
- First checks: inspect reason code, input shape/count, soft/hard deadline ordering, child liveness,
  fallback validity, then exact lock/SBOM/audit evidence. Never log request payloads.

## Compatibility, observability, and rollback

The Phase 1 importability fixtures remain immutable and replay 8/8. The Phase 7 golden matrix is
9/9 mandatory. Quality records include exact dataset, scorer, behavior digest, numerator,
denominator, samples, and environment; production quality/latency/cost are explicitly unknown.
Observability is limited to stable codes, counts, durations, behavior hashes, and redacted receipts.

Rollback first disables the solver. If necessary, revert the solver module, exact dependency,
lockfile, ADR, and solver tests while retaining canonical validation, Evidence Gate, and bounded
repair. To roll back the whole Phase 7 candidate, route around the validation package and retain its
evidence; no migration or production data reversal is required by this phase.

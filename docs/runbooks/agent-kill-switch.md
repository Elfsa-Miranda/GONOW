# Agent behavior kill switch

This runbook covers the local Release B behavior, route, and cohort controls. It does not authorize a production change. Production use requires the applicable SRE, Security, and Product approval receipt.

## Invariants

- Every change is a typed command and carries the expected `generation` for CAS.
- Authorization uses the server-derived tenant and `feature_flags.write` permission; prompts and instruction strings are never executable commands.
- Behavior, route, and cohort can be cut independently. Every cut routes new work to the old path, so the drill must prove `new Agent runs = 0` and `old path available = true`.
- API and Worker replicas acknowledge the same generation before it becomes visible.
- The append-only audit receipt binds the old/new generation and state hash using pseudonymous actor and tenant references. It stores no Prompt, response, reasoning, secret, or PII body.
- A kill never deletes, mutates, or cancels durable Run, Job, Event, Candidate, or checkpoint data.

## Drill

1. Record the current generation, state hash, API/Worker replica generations, and legacy health check.
2. Use an authorized operator adapter to issue one typed `behavior`, `route`, or `cohort` command with the expected generation and valid approval.
3. Confirm the returned generation is exactly previous + 1 and both replicas expose it.
4. Attempt three new Agent routes for the affected scope. The expected count is zero; each decision must select `legacy`.
5. Confirm an unaffected cohort remains available when only a cohort was cut.
6. Verify one immutable audit receipt, with no raw actor/tenant value or request body.

Any CAS conflict, authorization rejection, propagation failure, missing audit receipt, or unavailable old path fails the drill. Do not retry without first reading the actual generation and diagnosing the conflicting operator action.

## Rollback: switch old behavior

The first rollback action is to switch the old behavior on through the same authorized generation CAS. Do not edit storage or delete durable state.

1. Read the current generation and confirm the previous behavior digest remains certified.
2. Issue a typed `behavior enabled=true` command with that exact generation.
3. Confirm API and Worker have the next generation and a new Agent route selects the pinned behavior digest.
4. Re-run the legacy health check; it remains available even when Agent routing is restored.
5. Retain both kill and restore audit receipts. Escalate if the generation changed concurrently instead of forcing a write.

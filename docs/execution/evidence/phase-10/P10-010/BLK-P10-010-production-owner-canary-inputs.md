# BLK-P10-010 — Production owner-canary inputs

- Status: `external_inputs_pending_local_enablers_continue`
- Candidate: `2afcaac54b36dd1ccb3e85882025fdb17b878185`
- Scope: final owner-only production canary and dependent Release B acceptance
- Production actions performed: `0`

## Reproduction

A name-presence-only inventory in the frozen Phase 10 worktree found no production
endpoint, scoped owner identity, scoped credential provider, budget reference, or
production journey/flag/audit/kill-switch/old-path/trace/provider-usage adapter references. No
environment value was read or written. A tracked-file audit also found no deployment
manifest, public operator-control route, persistent feature-flag adapter, or owner-canary
executor in the candidate.

The candidate does contain typed local feature flags, a generation-fenced authorized
kill switch, Domain Command/CAS/outbox paths, and privacy-safe trace primitives. Those
are in-process/testable components and do not prove real production persistence,
identity scope, PostgreSQL wiring, provider usage, or rollback.

The published Agent OpenAPI `1.1.0` has SHA-256
`bc067228d99196391b9a0cdb9c687fadb5b0c2947418afe8687eca53e78e3fc0` and exactly eight
paths: health, contract discovery, run start, candidate read, event stream, resume, and
cancel. It exposes no flag/cohort/allocation, kill-switch operator, canary-control,
reject, or adopt endpoint. `agent-service/app/api/main.py` mounts the same bounded route
set. Therefore a generic coordinator cannot honestly derive the required owner allocation
and all six journeys from `GONOW_AGENT_API_URL` alone.

## Root cause and impact surface

P10-010 intentionally sits on a real production boundary. A model API key or a local
loopback service cannot establish the required endpoint identity, owner-only allocation,
database boundary, audit/trace receipts, usage cost, kill switch, or old-path recovery.
The missing external references therefore block only P10-010, its automated Release B
attestation, and dependent P10-089/990/999, P10-011, and Release C entry. They do not
invalidate P10-009 C1–C5 evidence or authorize traffic to another user.

## Reversible enabler

1. Complete and automatically accept P10-009 at the frozen candidate.
2. The isolated P10-010 TaskGate repair now verifies a tracked measured adapter,
   exact action lifecycle, continuous generation fencing, structured receipt ledger, and
   automated attestation without changing the certified candidate.
3. The repair/enabler branch now supplies a fail-closed coordinator that accepts
   only opaque references, refuses wildcard/non-owner cohorts, starts and ends at
   allocation zero, records every external action, and returns allocation to zero in a
   `finally` path.
4. The minimal typed production adapter protocol is frozen below. If a deployment cannot
   implement it without adding a persistent service or public operator route, add an ADR
   before changing the boundary. Do not guess the protocol or repurpose the audit adapter
   as a command executor.
5. Test that coordinator against local fake adapters as orchestration evidence only. It
   must remain blocked for production until all real references exist.

## Exact recovery references

Only presence and immutable identity are recorded; values must remain in the deployment
or secret provider:

- `GONOW_AGENT_API_URL`
- `GONOW_OWNER_CANARY_IDENTITY_REF`
- `GONOW_OWNER_CANARY_CREDENTIAL_PROVIDER`
- `GONOW_RELEASE_B_BUDGET_CAP_REF`
- `GONOW_RELEASE_B_JOURNEY_ADAPTER`
- `GONOW_RELEASE_B_FLAG_ADAPTER`
- `GONOW_RELEASE_B_AUDIT_ADAPTER`
- `GONOW_RELEASE_B_KILL_SWITCH_ADAPTER`
- `GONOW_RELEASE_B_OLD_PATH_ADAPTER`
- `GONOW_RELEASE_B_TRACE_ADAPTER`
- `GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER`

The fixed measured coordinator path is
`docs/execution/commands/Invoke-PersonalOwnerCanary.ps1`; it must be tracked,
non-reparse, and bound by SHA-256 before use. Provider model credentials stay server-side
and are not an operator-side readiness input.

## Typed journey-adapter protocol freeze

The local-provisional enabler freezes `owner-canary-journey-adapter/v1` before any
coordinator implementation. This is an ephemeral release-tool boundary already required
by the P10-010 restricted-adapter contract; it is not a public application API, a new
serving process, or a production dependency for ordinary user traffic. If implementation
needs any persistent service or public operator route, an ADR is required before that
boundary is added.

- The coordinator resolves `GONOW_RELEASE_B_JOURNEY_ADAPTER` through a deployment
  allowlist and invokes it without shell-string evaluation. A single UTF-8 JSON request
  is supplied through stdin; endpoint, owner-identity, and credential-provider reference
  values must never appear in argv, `commands.json`, stdout, or evidence.
- The request is strict and contains only `schema_version=1.0`,
  `protocol=owner-canary-journey-adapter/v1`, `operation=execute_journey`, exact
  candidate/build/Behavior identities, one journey class from `success`, `cancel`,
  `disconnect_resume`, `reject`, `adopt`, or `cas_conflict`, a unique
  attempt/idempotency key, expected generation, deadline,
  remaining budget, the SHA-256 of the tracked coordinator used to bind independently
  fetched receipts, and a private `runtime_references` object containing only the
  endpoint, owner-identity, and credential-provider references. Those three values travel
  only in the stdin payload and are represented in evidence by their SHA-256 bindings.
- The adapter must exit nonzero on unknown fields, wildcard/non-owner scope, identity or
  candidate drift, stale generation, budget/deadline exhaustion, missing credential
  resolution, or any partial/ambiguous outcome. Timeout or invalid JSON is a canary
  failure and immediately triggers the coordinator's allocation-zero `finally` path.
- A successful stdout response is one strict JSON object containing status, action ID,
  observed generation, journey/run hashes, exact journey outcome, start/end timestamps,
  production/PostgreSQL/live-provider attestations, zero non-owner allocation/request
  counts, formal/unexpected/duplicate write counts, and provider-call count. It must contain no
  Prompt, response, reasoning, token, credential, endpoint, owner PII, or raw domain row.
- The journey adapter is a command executor, not its own evidence authority. The
  coordinator must independently obtain and cross-bind trace, audit, and provider-usage
  receipts through the three dedicated adapters, bind each of the seven sub-adapters by
  allowlisted environment name and SHA-256, recompute every receipt hash, and reject
  missing, duplicate, extra, or mismatched rows. Reject, adopt, and CAS-conflict outcomes
  must respectively prove zero formal writes, exactly one typed Domain Command write,
  and no duplicate formal side effect. Journey-audit receipts also carry the granular SQL,
  tenant, authorization, secret/PII, permanent-run, audit and Tool redlines; trace receipts
  carry traceability and alert-wiring results; provider receipts carry live-provider and
  exact usage/cost evidence. The coordinator derives its report from those values rather
  than writing unmeasured zeros.
- Local fake adapters may verify orchestration, fail-closed parsing, timeout, fencing,
  allocation-zero cleanup, and redaction. Their receipts remain explicitly non-production
  and cannot satisfy the P10-010 production-boundary predicates.

## Forbidden substitutes

- Do not hand-author a passing report or no-op adapter.
- Do not relabel fake, staging, local PostgreSQL, or loopback execution as production.
- Do not use a model API key as an identity, feature-allocation, audit, or rollback proof.
- Do not broaden the canary to a wildcard or non-owner user.
- Do not mutate the frozen P10-009 candidate or begin P10-010 before all C1–C5 gates pass.

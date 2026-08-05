# Agent process boundary

## Current Phase 2 fact

The repository contains one Python codebase with two process entrypoints.
`app.api.main` owns the HTTP adapter and `app.worker.main` owns an independently
controlled worker lifecycle. The API and Worker do not import one another.
Neither process contains a model SDK, graph runtime, tool executor, job lease,
Supabase client, Domain Command, or production write path.

The API boundary contains:

- locked settings containing logical secret references but no secret values;
- RS256-only JWT verification with issuer/audience validation and bounded JWKS refresh;
- server-derived principal and tenant context, explicit authorization, and rate limits;
- stable public error envelopes, PII minimization, append-only audit primitives,
  and bounded business-open telemetry export;
- liveness/readiness decisions, clock-safety admission, and graceful drain;
- the immutable OpenAPI 1.0 descriptor and SchemaRegistry digest check.

The Worker boundary contains startup, shutdown, and drain coordination only.
Its public surface has no claim, lease, or job execution operation.

## Data and trust flow

An adapter must authenticate before constructing `RequestContext`; client body
fields cannot choose the principal or tenant. Authorization evaluates explicit
action, tenant, field, and approval inputs. Logs and telemetry cross the
`PIIRedactor` before an exporter. High-risk audit failure is closed. External
telemetry failure does not change a business result and its buffer is bounded.

Phase 2 has no database migration or formal-write authority. PostgreSQL facts,
durable Run/Job/Event state, fencing, Candidate production, and Domain Command
CAS/outbox writes are target contracts for later phases, not current facts.

## Enable, disable, degrade, and first check

- Enable locally: create the frozen environment and run either entrypoint as
  described in `docs/runbooks/agent-service-lifecycle.md`.
- Disable: stop both processes or leave them undeployed. No Flutter traffic is connected.
- Degrade: failed JWKS/database readiness or unsafe clock rejects new work;
  drain and cancel remain allowed. Disable telemetry export without changing safe error codes.
- First check: run `agent-service/scripts/ci.ps1`, then inspect the minimal
  readiness reason code. Do not print settings, tokens, request bodies, or exception text.

## Pending formal boundaries

This is a local provisional candidate. Independent SRE/Security review, remote
required-check configuration, deployment-specific clock source/offset evidence,
formal merge/push, and production enablement remain pending. Later phases may
extend this boundary only through their own contracts and gates.

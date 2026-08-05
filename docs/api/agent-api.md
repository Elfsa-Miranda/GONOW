# Agent API 1.0 contract

The canonical Phase 2 public contract is `contracts/openapi/agent-api.yaml` with
SHA-256 `b9e5d1b97ca3e14ebebdae11c7178916a36bb1a18577e931dc483482e95c0c70`.
It is OpenAPI 3.1 encoded as JSON-compatible YAML 1.2 so the locked service can
parse it without an additional runtime dependency.

## Published surface

- `GET /health/live` returns only process liveness.
- `GET /health/ready` returns `ready|not_ready` plus stable reason codes.
- `GET /v1/contracts/{name}/{major}` returns the immutable contract descriptor.

There is no Run, streaming, model, tool, or domain-write endpoint in Phase 2.
The authenticated contract route accepts only `agent-api` major 1. Unknown
major, digest mismatch, or unavailable registry fails closed.

## Error envelope

Every public error uses `{ "error": { "code", "message", "request_id" } }`
with optional bounded `retry_after_seconds`. The corpus is:

- `auth.forbidden`
- `auth.invalid_token`
- `context.invalid`
- `internal.error`
- `rate.limit`
- `schema.unsupported`
- `service.unavailable`
- `tenant.scope_missing`

Five-hundred responses always use a generic public body. Stack traces, internal
paths, request bodies, PII, credentials, prompts, and reasoning are not public fields.

## Enable, disable, degrade, and first check

The contract is enabled only by loading the exact digest through SchemaRegistry.
Disable by leaving the service undeployed; no Flutter traffic consumes it.
On digest drift or unknown major, keep the route closed and retain the prior
immutable contract. First run the OpenAPI contract tests and compare the file
digest with `EXPECTED_OPENAPI_SHA256`; a contract change requires its applicable
ADR/reviewer process before formal publication.

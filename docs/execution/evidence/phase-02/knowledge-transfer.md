# Phase 2 knowledge transfer

## Responsibilities and boundaries

The API owns authentication, tenant context, stable HTTP errors, probes, and the
contract descriptor. The Worker owns only an independent lifecycle. Phase 2 owns
neither job execution nor business data. Future database, model, graph, tool,
Candidate, and Domain Command behavior must enter through later phase gates.

## Dependency choices

Python 3.13.9, uv 0.10.9, and all 11 direct packages are exact-pinned. FastAPI,
Pydantic, HTTPX, PyJWT/cryptography, OpenTelemetry API/SDK, pytest, and CycloneDX
cover the skeleton without adding model/graph SDKs. OpenAPI uses JSON-compatible
YAML 1.2 to avoid an unplanned parser dependency. CI Actions are pinned to full SHAs.

## Hardest items

1. Preserving evidence honesty when local Windows Time was unavailable: boundary
   fixtures pass, but real source/offset remains explicitly pending rather than zero.
2. Keeping error/log/telemetry fields useful while excluding body, PII, secret,
   internal exception, prompt, and reasoning content.
3. Repairing evidence mechanics without changing global provenance: nested CI
   reports are now recursively hashed, and the one OpenAPI Catalog omission is a
   narrow recorded projection rather than an unreviewed Catalog SHA rewrite.

## Operations

Start with `docs/runbooks/agent-service-lifecycle.md`. Run the locked `ci.ps1`
wrapper, inspect stable readiness codes, and preserve fail-closed JWT/tenant/error
behavior. Stop both processes for rollback. Do not add a Flutter route, model SDK,
database write, or job lease as an operational workaround.

## Estimate and handoff verification

Plan estimates are capacity ranges, not elapsed-time claims. The final local CI
replay passes 135 Agent tests and 8 explicit contract tests with no skips/xfails.
The implementer has verified build, lifecycle, degraded clock fixtures, contract,
and rollback mechanics. An independent SRE/Security handoff remains pending, so
the phase can be `ready_for_review` locally but cannot be called accepted.

# Release A gateway runbook

Status: local candidate only. Do not enable against production without the approvals and server evidence listed in the security-boundary document.

## Configure and enable

The client accepts three compile-time values: an enable flag, an HTTPS gateway URL, and the exact allowed host. The URL must use port 443, contain no user info/query/fragment, and have no path other than `/`; the client appends the fixed `/v1/release-a/chat` path. Do not put credentials, provider names, model selectors, or prompts in build arguments.

Before enabling, verify the server requires the current authenticated user session and enforces request limits, authorization, rate limits, cost caps, response typing, and redacted errors. Then run `test/release_a_gateway_test.dart`, `integration_test/release_a_compat_test.dart` through `tool/release_a_acceptance.ps1`, the secret scanner, and the Flutter ratchet.

## Disable or degrade

Set the enable flag to false and rebuild the client candidate. A missing or invalid configuration must fail before network I/O and show a stable unavailable/auth message. Keep ordinary non-model journeys available. Never fall back to a provider endpoint from the client.

## First checks

1. Confirm the enable flag and exact allowed host were supplied to the intended build.
2. Confirm the user has a current authenticated session.
3. Check only the structured request ID and bounded server status; do not copy request/response bodies into logs.
4. For 401/403, inspect auth/authorization. For 413/429, inspect caps. For 5xx/timeouts, disable the feature while the server path is repaired.

## Local verification

Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\release_a_acceptance.ps1`. Exit `3` currently means the six local compatibility journeys passed but the production database inventory/owner gates remain pending. It is not permission to activate production.

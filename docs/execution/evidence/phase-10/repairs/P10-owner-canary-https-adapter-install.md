# P10 owner-canary HTTPS adapter installation and root-cause closure

- Repair branch: `codex/repair-owner-canary-adapters`
- Repair base OID: `7ed369f9f2b64722bf43e7562ec942e4a229cb91`
- Certified application candidate changed: `false`
- Production action count: `0`
- Secret value read count: `0`

## Reproduction

The frozen owner-canary coordinator required eleven environment names. Name-only inspection
found all eleven absent. Seven were executable adapter references, but the repository supplied
only their protocol and test fakes. The public Agent OpenAPI has no operator control route, the
production composition does not expose owner allocation or receipt collection, and the client
flag is compile-time. Creating seven no-op scripts would therefore turn a deployment gap into a
false production claim.

The minimal reproduction was:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `
  .\docs\execution\commands\Invoke-PersonalOwnerCanary.ps1 `
  -CandidateHeadOid (git rev-parse HEAD) -ValidateInputsOnly
```

Before the repair, none of the seven adapter slots could resolve an absolute, non-reparse
executable. No environment value was printed or persisted.

## Root cause and impact surface

The coordinator and validator were complete, but the executable transport boundary had never
been implemented. The missing code affected only P10-010 production execution and its dependent
Release B/Release C gates. It did not invalidate the frozen application snapshot or C1-C5
measurements, and it did not authorize a new public API, production deployment, database change,
or synthetic production evidence.

## Reversible repair

1. Added a PowerShell 5.1-compatible HTTPS relay that consumes the frozen adapter stdin protocol,
   authenticates through a content-hashed credential-provider executable, calls one fixed private
   deployment path, and returns exactly one validated JSON response.
2. The relay rejects HTTP, loopback, IP literals, non-root base URLs, redirects, cookies, TLS
   bypasses, unbounded payloads, unknown fields, stale deadlines, budget overflow, identity or
   candidate drift, secret-like response fields, and all security/audit redlines.
3. Added a PowerShell 7 SecretManagement provider pinned to official module versions. Its
   reference contains only provider path/digest, vault name, secret name, and allowed host. The
   bearer token exists only in the provider/relay pipe and is never written to evidence.
   `New-OwnerCanarySecretManagementReference.ps1` constructs and validates this non-secret
   reference so operators do not hand-copy a provider digest.
4. Updated the coordinator to fill only missing adapter variables with the tracked relay path.
   Explicit deployment adapters are preserved and still measured. One executable handles seven
   logical operations, while receipt responses remain bound to the exact logical source name and
   digest.
5. Installed the official modules in CurrentUser scope:

   - `Microsoft.PowerShell.SecretManagement 1.1.2`, manifest SHA-256
     `b0bf72a38245fb98186785f857b7ce797fa95bbb63025391a238a66ee7f46a90`
   - `Microsoft.PowerShell.SecretStore 1.0.6`, manifest SHA-256
     `9fad146f6906c2b5ffc53f5fc188550d88e91bd3d1d0e34589817b9676f54d3e`

No vault or secret was provisioned because no real owner credential was supplied. This preserves
the boundary between installing capability and fabricating authority.

## Affected regression

The following checks passed with zero skips or production writes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\docs\execution\commands\tests\Invoke-OwnerCanaryHttpsAdapter.Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\docs\execution\commands\tests\Invoke-PersonalOwnerCanary.Tests.ps1
```

The post-repair name-only inventory exits `3` for exactly four external references while proving
all seven adapter slots valid: `adapter_count=7`, `valid_adapter_count=7`,
`distinct_adapter_digests=1`, `secret_value_read_count=0`, `production_write_count=0`.

## Remaining boundary and rollback

Formal P10-010 still requires a genuine HTTPS production endpoint, opaque owner identity,
content-hashed SecretManagement provider reference backed by a real short-lived token, budget
reference, and a deployment-private relay implementation. Those facts cannot be installed from
repository bytes or inferred from the public Supabase URL. Until they exist, only P10-010 and
dependent formal actions remain closed.

Rollback is deletion of the two adapter scripts and this repair documentation plus restoration of
the coordinator/test diff. The official CurrentUser modules may be uninstalled independently if
no other vault uses them; no production state or credential needs rollback.

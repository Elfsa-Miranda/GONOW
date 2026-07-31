# Phase 3 entry regression root-cause closure

## Reproduction

The first clean Phase 3 checkout ran the complete Agent CI wrapper. Fifteen tests
passed before `test_spec_sha256_is_exact_and_64_characters` failed: the expected
OpenAPI SHA-256 was `b9e5d1b97ca3e14ebebdae11c7178916a36bb1a18577e931dc483482e95c0c70`,
while the checkout contained `19e7a013981c400b03063bc6ff3de097a59d73f6dd46e77231aa403b7d782f4b`.
The failing JUnit and CI summary are retained under `phase-entry-ci/`.

## Root cause and impact surface

The Git blob and the Phase 2 worktree contain 5,699 bytes with 145 LF endings.
The new worktree used `core.autocrlf=true` and materialized 5,844 bytes with 145
CRLF endings. No attribute governed the public OpenAPI artifact. The mismatch
affects every clean Windows checkout, OpenAPI digest assertion, SchemaRegistry
binding, and downstream evidence that treats the public artifact bytes as an
immutable contract. It does not change API semantics or the Git blob.

Flutter entry regression also refreshed the stat cache for seven generated plugin
registrants. Their normalized Git object IDs were byte-for-byte equal to HEAD and
no staged or working-tree diff remained. Later Flutter replays use `--no-pub`.

## Reversible repair

The repository now pins `/contracts/openapi/agent-api.yaml text eol=lf` in
`.gitattributes`. This preserves the existing Git blob and published digest across
Windows and POSIX checkouts. The repair is additive and reverts by removing the one
attribute line; it does not change the OpenAPI document, SchemaRegistry constant,
or global TaskGate Catalog.

## Affected regression

The next clean worktree must prove the OpenAPI file is 5,699 bytes, has the expected
SHA-256, contains no CRLF, and passes the complete Agent CI suite. The Phase 0/1
Flutter journeys must pass with `--no-pub`, and the worktree must remain clean apart
from declared Phase 3 evidence.

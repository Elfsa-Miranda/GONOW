# Phase 12A Structured Memory knowledge transfer

## Purpose and ownership

P12A supplies explicit user-visible Memory to the existing Single-Agent itinerary path. Product and
Data own the four allowed types, purpose, consent, retention, export, and deletion semantics.
Security owns authorization, RLS, poisoning boundaries, and redlines. Engineering owns migrations,
CAS/idempotency/outbox, the default-off read port, tests, and rollback mechanics. Local evidence does
not substitute for independent approval.

## Data and authority model

Memory is limited to travel pace, mobility requirement, dietary requirement, and transport
preference for `itinerary.personalization`. A record binds tenant, principal, current consent,
provenance, retention, version, and deletion identity. Absence, expiry, purpose mismatch, or ambiguous
identity denies reads and writes. A model can propose only a typed Candidate; explicit user
confirmation and server authorization precede CAS/idempotent formal write and atomic outbox.

## Runtime path

Seven local PostgreSQL tables are protected by FORCE RLS using tenant plus principal context. The
Worker cannot directly mutate formal rows. The Single-Agent runtime reads only pre-authorized typed
Memory through a narrow default-off port. The port never calls a model or Tool and adds no
coordinator or specialist Agent. Its kill switch returns the old no-Memory behavior.

## Conflict, delete, export, and restore

Conflicts preserve both typed values and provenance until an authorized expected-version resolution.
Retrieved content is untrusted and cannot change instructions or grant authority. Delete and consent
withdrawal tombstone the record and suppress Candidate, index, cache, export, eval trace, and restore
ledger materialization. Restore must replay tombstones first; deletion is not undone by rollback.
Export is restricted to the authenticated principal and allowed purpose.

## Operations and troubleshooting

First inspect identity, tenant, purpose, consent version/expiry, record version, idempotency key, RLS
context, and tombstone. Reproduce the smallest authorization or lifecycle failure, repair that root
cause, then run affected Memory/RLS/conflict/delete/restore and compatibility tests. Never bypass
consent, remove FORCE RLS, rewrite versions, or drop negative evidence to recover service.

Disable by setting allocation to zero, turning off proposals and reads, or activating the Memory kill
switch. Preserve rows, receipts, outbox, audit, and tombstones. A disabled Memory path safely returns
to the previous Single-Agent behavior.

## Evidence and remaining work

P12A-990 records the one full regression: 15 CI suites, 895 unit, 255 contract, 124 Flutter, and 53
RealPG/fault tests, all passing with zero skip/xfail. Local PostgreSQL and fake/fixture tests used no
model API. Before production use, owners must inventory the actual schema/RLS/grants/triggers and
backup path, run real deletion/export/restore drills, approve consent and retention, establish
monitoring and rollout authority, and independently review the exact candidate and merge OIDs.

# Phase 12D local provisional change summary

The user selected 12D as this cycle's only candidate. Repository evidence then selected exactly
`ItineraryProvider.updateItineraryBasicInfo` for `user_itineraries`; no production traffic, incident,
or schema fact was guessed.

The package adds a closed Python command contract, additive `domain_command` migration with FORCE
RLS, atomic handler/receipt/outbox persistence, deterministic concurrency and crash injection, and a
default-off typed Flutter route. Public OpenAPI stays unchanged because the internal route is not
mounted by default. Unknown outcomes use receipt lookup and never fall back to the legacy writer.

The frozen controlled profile ran identical 10,000-intent legacy and candidate workloads. The stale
conflict partial-effect rate was 10,000/10k for the tracked legacy ordering and 0/10k for the Domain
Command. Duplicate formal writes, unauthorized/cross-tenant writes, mutation/outbox divergence,
ambiguous committed outcomes, and data loss were all zero. Full P12D-990 regression passed 15 CI
suites, 736 unit tests, 183 contract tests, 124 Flutter tests, and 52 focused RealPG/fault tests with
zero failures, skips, or xfails.

This is a `local_controlled_mechanism` result. Production schema equivalence, flow distribution,
incident rate, and improvement remain unknown or `measurement_pending`; production allocation and
writes are zero. Multi-Agent remains deferred with no framework or runtime. Formal independent
review, remote push, deployment, and Release acceptance remain pending.

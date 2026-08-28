# Phase 11 knowledge transfer

hardest_item_count: 2

## Responsibilities and dependency choices

PostgreSQL is the knowledge source of truth; pgvector and FTS are indexes, not independent stores. Retrieval owns authorization-before-materialization, deterministic fusion/rerank, and citation lineage. The existing itinerary processor remains one Agent and accepts only typed, already-authorized evidence. No Redis, message broker, MCP adapter, or multi-agent coordinator was introduced.

## Hardest items

1. The locked PostgreSQL 17 distribution lacked pgvector. The root fix installed pgvector 0.8.1 into an isolated toolchain and proved the full Alembic chain against a real local database rather than skipping the migration.
2. The Phase 11 convergence runner counted only formally accepted predecessors despite local-provisional policy. A local-only repair now consumes projected `ready_for_review` tasks while preserving formal gates and honest pending-review fields.

## Operations must know

The RAG flag defaults off and production allocation is zero. A Worker must not infer principal authorization from tenant alone. Tombstones are replayed before restore. Alias promotion requires certification and generation CAS. First checks are flag generation, identity context, active alias, package digest, RLS deny evidence, tombstone receipts, and P11-009 metrics.

## Estimate comparison

The task cards estimated multiple person-days per implementation slice; local execution used deterministic fixtures and existing runtime primitives. No calendar-duration equivalence is claimed. The measurable test surface added by the integration repair is four contract cases, while the affected contract+RAG regression contains 189 passing tests with zero skips.

## Handoff verification

Local handoff reruns frozen RAG quality, ACL, deletion, retrieval/citation, and knowledge-alias journeys. The implementation agent records this as local verification only; Data/Privacy/SRE independent review and production-same-configuration validation remain pending external actions.

## Known risks and recovery

Principal/group context is not yet durably supplied to a production Worker knowledge provider, so the feature must remain off. A failed provider or unknown claim stops Candidate creation. Recovery is allocation zero plus the previous no-RAG single-Agent path; knowledge and evidence are retained for diagnosis.

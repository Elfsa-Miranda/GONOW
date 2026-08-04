# Phase 11 single-Agent RAG architecture

Status: local provisional. Production allocation is zero and formal Release C selection is pending. This design extends the existing itinerary Agent; it does not introduce multi-agent planning, delegation, or shared-agent state.

## Data and control flow

1. Source policy admits only an approved source class, purpose, license, owner, retention rule, and immutable source version.
2. Idempotent ingestion parses and chunks content, creates content-addressed embedding jobs, and writes through the knowledge outbox.
3. PostgreSQL 17 with pgvector 0.8.1 provides vector and FTS candidate indexes. PostgreSQL remains the source of truth.
4. Retrieval binds tenant, principal, groups, purpose, version, deletion state, and license before text materialization. Materialization repeats authorization in `READ COMMITTED`.
5. Reciprocal-rank fusion and the deterministic local reranker operate only on authorized candidates and bind every result to one immutable manifest.
6. The citation assembler emits source/version/chunk lineage. `SingleAgentKnowledgeProvider` projects only already-authorized evidence into the existing itinerary processor.
7. Model-supplied claim IDs are restricted to the supplied set. Unknown claims fail before Candidate projection; only used evidence becomes a Candidate citation.

The production provider is intentionally not inferred from tenant alone: durable Jobs do not yet carry sufficient principal/group context for private ACL evaluation. The feature remains disabled until that authenticated context and an approved cohort adapter exist.

## Enable

Enable `gonow.agent.itinerary_planning.rag` only for approved cohort IDs, with an immutable certified knowledge alias and a provider that proves tenant/principal ACL checks before returning `SingleAgentKnowledgeEvidence`. The processor is constructed with `rag_enabled=True`; the default is false.

## Disable

Set RAG allocation to zero and construct the processor without a knowledge provider. No knowledge data is deleted by this action, and the previous uncited Candidate path remains available.

## Degrade

An authorized empty retrieval can continue on the single-Agent path without knowledge claims. Provider failure, duplicate evidence identity, unknown claim ID, manifest mismatch, or missing provider while enabled fails closed. Realtime weather, route, and business-hours facts remain Tool-only rather than RAG data.

## First checks

Check flag generation and cohort, durable identity availability, active alias generation, package certification, tenant session binding, RLS result, deletion tombstone, manifest digest, Worker error code, and `P11-009/rag-manifest.json`. `contract_change: documentation_only`; public Candidate fields are unchanged.

## Process and package boundaries

`agent-api` and `agent-worker` remain the only production processes. Knowledge packages bind graph/policy-adjacent artifacts, embedding model, dictionary, schema, evaluation, and budget evidence. Alias promotion uses generation CAS; failed certification never changes the active alias.

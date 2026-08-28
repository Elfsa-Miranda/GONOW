# Phase 11 change summary

Before Phase 11, the repository had no reproducible knowledge schema, ingestion, retrieval, citation lineage, deletion propagation, knowledge package, or RAG evaluation. The existing single Agent produced uncited itinerary Candidates.

After the local-provisional Phase 11 implementation:

- approved source policy, immutable versions, RLS/grants, outbox, idempotent parsing/chunking, and content-addressed embedding jobs are implemented;
- PostgreSQL 17 has a genuinely installed pgvector 0.8.1 extension and reproducible vector/FTS migration path;
- tenant/principal/group/purpose/license/current-version/deletion checks happen before and during materialization;
- deterministic fusion, reranking, and manifest-bound citations are implemented;
- immutable package certification and alias generation CAS prevent partial promotion;
- durable tombstones deny reads and block restore resurrection across six surfaces;
- a frozen nine-query synthetic holdout records 8/8 Recall@1, 8/8 citation precision, zero ACL/tenant/stale/deletion/SSRF/tool redlines, 0.305 ms offline p95, and zero model cost;
- already-authorized evidence can enter the existing single itinerary Agent through a typed, default-disabled provider; no multi-agent framework was added.

Production allocation, formal Release C selection, independent handoff, owner promotion, and principal-aware Worker provider composition remain pending. `contract_change: documentation_only` for the public Candidate/OpenAPI shape.

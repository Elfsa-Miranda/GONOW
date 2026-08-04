# RAG citation contract

Phase 11 keeps the public `CandidateCitation` object stable: `claim_id`, `evidence_id`, `source_ref`, and `sha256`. `contract_change: documentation_only` and the OpenAPI version moves to 1.1.1 without adding required fields.

An internal `KnowledgeCitation` binds `manifest_digest`, `source_id`, `version_id`, `chunk_id`, `chunk_digest`, source class, and license. Before entering the single Agent, it is projected as follows:

| Internal value | Candidate value |
|---|---|
| deterministic citation prefix | `knowledge_<16 hex>` claim ID |
| same stable prefix | `ev_knowledge_<16 hex>` evidence ID |
| manifest digest + chunk UUID | `evidence://knowledge/<manifest>/<chunk>` |
| chunk digest | `sha256` |

The model sees only authorized quoted evidence and permitted claim IDs. It cannot create source lineage. Unknown claims fail closed, unused evidence is not emitted, and Candidate projection requires the used claim set to equal the citation claim set.

## Enable

Enable through the approved RAG cohort and inject an authenticated provider into the single Agent processor.

## Disable

Set allocation to zero; the prior Candidate contract permits an empty citation list.

## Degrade

Authorized empty retrieval produces no knowledge claims. Provider, manifest, identity, or claim mismatch stops Candidate creation.

## First checks

Compare Candidate `sha256` with the chunk digest, decode the evidence reference to the manifest/chunk identity, verify the package alias and deletion state, and confirm the claim ID exists on an itinerary item.

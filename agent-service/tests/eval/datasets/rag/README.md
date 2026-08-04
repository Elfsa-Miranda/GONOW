# RAG synthetic holdout v1

This dataset is synthetic and contains no user data. All nine queries are frozen holdout cases. They cover retrieval recall, citation traceability, tenant and ACL denial, stale-version exclusion, deletion non-resurrection, and inert SSRF/tool-injection text.

`vector_ranking` and `lexical_ranking` are frozen inputs to the deterministic fusion stage; this package evaluates authorization filtering plus fusion, reranking, and citation assembly without a network, model, tool, or production data dependency. Thresholds are local-provisional until Product and Security provide independent formal approval.

# BLK-P11-RAG single-agent integration gap

- Status: repaired locally; production enablement remains off.
- Reproduction: the Phase 11 checkpoint Worker processor instructed the model not to return citations and always called `CandidateProjector` with an empty citation tuple.
- Root cause: retrieval, reranking, citation assembly, and package controls were implemented as isolated components, but no typed boundary connected already-authorized evidence to the existing single Agent processor. The durable Job also does not preserve sufficient principal/group context to authorize private knowledge directly in the Worker.
- Impact: the RAG package could be evaluated but could not safely influence an itinerary Candidate; directly querying by tenant alone would risk an ACL bypass.
- Reversible repair: add an injected `SingleAgentKnowledgeProvider` port, convert manifest-bound citations to the existing Candidate citation contract, quote evidence as untrusted data, reject unknown claim IDs, and fail closed when RAG is enabled without an authorized provider. Default behavior stays disabled and byte-compatible for uncited Candidates.
- Excluded changes: no multi-agent coordinator, no production flag write, no database schema change, no principal inference, no remote ref write, and no model-selected tool execution.
- Regression: legacy processor tests plus the four single-Agent RAG contract cases must pass with no skips.
- Rollback: revert the repair commit; the default-disabled legacy processor remains the operational fallback.
- Recovery condition: a production adapter may be supplied only after authenticated principal/group context is durably available and the feature flag has an approved cohort receipt.

# P04-006 tokenizer boundary

- Assumption: no production tokenizer is proven by the repository, so Context Compiler v0 accepts an injected deterministic token counter and does not select or simulate a provider tokenizer.
- Impact: local compilation, ordering, overflow refusal, transformation logging, and digest behavior are fully testable; production tokenizer compatibility remains a caller-supplied dependency and is not claimed.
- Fail-closed behavior: a missing, raising, non-integer, boolean, or non-positive token counter returns `context.tokenizer_unavailable`; required input overflow returns `context.required_slice_missing` without dropping hard constraints.
- Rollback: remove the compiler and its tests to return to compiler-none; typed state, graph, Catalog, and legacy paths remain unchanged.
- Boundary: no implicit Memory, model/tool call, remote push, merge, production write, or acceptance was performed.

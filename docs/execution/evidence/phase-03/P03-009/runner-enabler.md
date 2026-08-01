# P03-009 task-gate enabler

- assumption: the frozen Catalog registers the required modes, while the shared runner does not yet implement the task-specific restore adapters.
- impact: the local adapter executes only the task-owned restore wrapper and validates exact empty/existing upgrade, logical hash, advisory-lock, forward-fix, CT-007, security, workset, evidence, and rollback results. Catalog bytes and production boundaries remain unchanged.
- rollback: remove only these P03-009 runner branches after an adopted runner supplies equivalent checks; retain immutable task evidence and restore history.

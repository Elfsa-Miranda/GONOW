# P03-008 task-gate enabler

- assumption: the frozen Catalog registers all required modes but the shared runner predates the P03-008 executable adapters.
- impact: this local, task-scoped enabler adds exact Verify, Security, Evidence, WorksetVerify, and RollbackVerify handlers plus a literal path allowlist. It does not change Catalog bytes, task dependencies, product code, database constraints, or formal status semantics.
- rollback: remove only the P03-008 runner branches after an adopted runner version supplies equivalent checks; retain all candidate and historical evidence.

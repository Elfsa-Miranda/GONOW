# P04-002 root-cause enabler

- Reproduction: the first direct pytest run failed during collection with `ModuleNotFoundError: No module named 'app'`; no graph code executed.
- Root cause and impact: the task contract launches pytest from the repository root, while the three new test modules initially lacked the established Phase 4 `agent-service` path bootstrap. Only those test entrypoints were affected.
- Reversible repair: add the same local virtual-environment/site and service-root bootstrap used by existing Phase 4 tests. No dependency, lock file, runtime path, or public boundary changed.
- Affected regression: the three-file suite passed 21/21, Harness 07/08 S/I/D validation passed, task-runner contracts passed, and full Agent CI passed 265 unit/integration plus 58 explicit contract tests.
- Boundary: the graph is unmounted and single-behavior only; no model/tool call, remote push, merge, production write, or acceptance was performed.

# P04-003 root-cause enabler

- Reproduction: importing the initial Harness Catalog loader failed with `ModuleNotFoundError: No module named 'yaml'` before test collection.
- Root cause and impact: the Phase 2 locked virtual environment does not contain PyYAML, while TASK-P04-003 does not authorize dependency or lock-file changes. Only the new Catalog loader was affected; existing runtime and Catalog bytes were not changed.
- Reversible repair: replace the YAML dependency with a standard-library parser that accepts only the exact frozen four-header/34-control inline Catalog syntax and fails closed on any other form. The repair can be removed with the new mapping package without touching the Catalog.
- Affected regression: the direct contract suite passed 7/7, the task runner contract passed, all five registered task modes passed, and full Agent CI passed 244 unit/integration plus 58 explicit contract tests.
- Boundary: local provisional evidence only; no remote push, merge, production write, or acceptance was performed.

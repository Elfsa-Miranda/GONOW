# BLK-P05-003: LangGraph lock and task allowlist gap

看到什么：P05-003 要求兼容“已锁 LangGraph 版本”，但任务入口的 `pyproject.toml` 与 `uv.lock` 没有 LangGraph 包。

卡住哪一步：若直接实现，只能伪造版本兼容；若直接加依赖，又超出本卡字面 allowlist。

最安全下一步：先以独立 enabler 建 ADR、精确锁定已批准的 LangGraph v1 技术线并完成供应链与全量回归，再在原卡 allowlist 内实现 saver。

## Classification and impact

- Severity: P2 execution-contract gap; no production incident
- Status: resolved locally; formal ADR approval remains pending external
- Affected action: `TASK-P05-003` implementation and its strict successor `TASK-P05-004`
- Unaffected ready work: `TASK-P05-005` remains locally runnable from P05-001/P05-002
- Production writes, remote pushes and merges: 0

## Reproduction

1. Read `TASK-P05-003` in `execplan.md`: goal is a saver compatible with the locked LangGraph version; literal allowlist excludes dependency files.
2. Search `agent-service/pyproject.toml` and `agent-service/uv.lock` for `langgraph`: match count was 0.
3. Read AGENTS.md §3: LangGraph/LangChain v1 is the approved target line and dependencies must be exactly locked with supply-chain evidence.

## Root cause and excluded paths

The earlier local Phase 2 dependency bootstrap locked the service framework but did not materialize the approved LangGraph v1 dependency that P05-003 assumes. This is a planning-to-repository drift, not a PostgreSQL or toolchain failure.

- Excluded: silently claiming compatibility without an installed package.
- Excluded: using Redis or an in-memory saver as durable truth.
- Excluded: adding the official saver and calling runtime `setup()` without Alembic, tenant and fencing review.
- Excluded: weakening the card assertion or changing the sealed guidance bytes.

## Complete reversible repair

1. Create ADR-P05-003 before implementation and compare the official saver, a protocol-compatible GoNow saver, no-package shim and Redis.
2. Add the exact non-yanked LangGraph v1 pin in a separate local enabler; regenerate the lock with the locked `uv` tool.
3. Generate dependency diff, SBOM, licenses, CVE audit, maintenance/provenance and decision evidence; run full Agent regression.
4. Commit the enabler separately so P05-003 workset verification remains limited to its literal product/evidence paths.
5. Implement and test the selected saver. Do not mark the ADR formally approved.

Rollback is a normal revert of the enabler commit followed by frozen dependency sync. Recovery requires the lock check, dependency audit and full regression to pass with no Critical/High or unknown license.

## Repair execution and closure

1. Exact lock resolution added `langgraph==1.2.9` and 21 transitives; `uv lock --check` passed. Candidate lock SHA-256 is `67179e0a1921136a25030ce8f3480265bf7d0a989c8ce6e19d6d92eee250301f`.
2. SBOM, license and vulnerability gates passed: Critical=0, High=0, unknown license=0. The evidence is under `docs/execution/supply-chain/phase-05/TASK-P05-003/`.
3. The first full regression reproduced one stale Phase 2 assertion that banned all graph dependencies. Root cause was a phase-specific inert-skeleton invariant persisting beyond the Phase 5 activation card.
4. The reversible repair now allows only the exact approved LangGraph pin while retaining bans on model providers, dynamic execution and app graph invocation. The affected security file passed 5/5.
5. The affected full regression then passed 396 unit/integration tests and 93 contract tests with zero mandatory skips/xfails. Existing runtime behavior remains unchanged; checkpoint implementation has not yet begun.

Local recovery condition is satisfied. Formal Security/Data ADR approval remains a merge/production/acceptance boundary and does not invalidate the local evidence.

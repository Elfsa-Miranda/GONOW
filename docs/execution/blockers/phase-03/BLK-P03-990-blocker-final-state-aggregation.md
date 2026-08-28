# BLK-P03-990 — blocker final-state aggregation

P03-990 Documentation 连续两次返回 `unresolved_blocker_final_state=1`，而文档、五节 KT、交接旅程和 threat-model 检查均通过。受影响动作仅为 Phase 3 acceptance 文档聚合；已通过的 215+44 回归、三个隔离 PostgreSQL 回滚场景和既有 Runtime 数据合同不受影响。

## 根因假设与已排除路径

- 当前假设：runner 作用域中的组合正则或枚举结果没有把两种历史终态格式统一映射为 `resolved_local`。
- 已排除：两份既有 blocker 缺少终态。独立读取分别确认 `Status: resolved locally` 与 ``最终状态：`resolved_local` `` 存在。
- 已排除：KT、handoff、threat-model、P0/P1 或生产写问题；对应计数均为通过/零。
- 已排除：无新输入的偶发失败；第二次执行产生相同计数。

## 完整修复方案

1. 在聚合结果中记录每个 blocker 的文件名和归一化终态，取得 runner 作用域内的区分信号。
2. 用逐格式、行锚定的解析替代不透明组合判断，并把无法识别的文件名显式列入结果。
3. 保持“任一 blocker 无最终状态即失败”的阈值不变，不排除当前 blocker。
4. 先重跑 Documentation，再重跑 BuildAcceptance、Security、RollbackVerify、Evidence 与 Verify。

回滚为还原 P03-990 runner 修复和本诊断文档；不改生产代码、迁移或数据库。恢复条件是三份 Phase 3 blocker 全部被明确识别为本地 resolved，`unresolved_blocker_final_state=0`，且后续受影响门禁全通过。

## Resolution

- Root cause confirmed: `Invoke-TaskGate.ps1` is UTF-8 without a BOM, so Windows PowerShell 5 parsed the non-ASCII source-code marker with the legacy local code page. The blocker file itself decoded correctly with `Get-Content -Encoding UTF8`, but both the runner regex and literal contained corrupted source characters and returned `canonical_marker=false`.
- Repair: normalize the English terminal marker directly and identify the historical canonical line by its two ASCII tokens, `` `resolved_local` `` and `` `pending_external` ``, on the same line. Emit every filename plus normalized state and retain unknown markers as unresolved; do not change the runner file encoding or other sealed/history bytes.
- Affected regression: Documentation must report three files, three `resolved_local` states, and zero unresolved; BuildAcceptance, Security, RollbackVerify, Evidence, and Verify then rerun against the fixed candidate.
- Rollback: revert the literal normalizer and this blocker; no production code, migration, schema, data, or external state is involved.

Status: resolved locally on 2026-08-01. Independent formal review remains `pending_external`.

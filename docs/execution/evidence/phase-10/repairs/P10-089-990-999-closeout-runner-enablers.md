# P10-089 / P10-990 / P10-999 收尾 runner 修复记录

- 记录日期：2026-08-02（Asia/Shanghai）
- 执行分支：`codex/phase-10-release-b-gates`
- 记录前 HEAD：`001de28ff39a3dca823975ed3404f6cc3e1cf62f`
- 执行依据：sealed `AGENTS.md` 1.4.0 与 `execplan.md` 1.4.0；本记录不引入新的阶段合同
- 权限边界：`local_provisional`；未执行正式合并、远程推送、生产写、Release accepted 或批准代签

## 闭环：复现

1. P10-089 专项 runner 初次静态解析在 `Invoke-TaskGate.ps1` 约第 12001 行失败，错误指向缺失的 `}` / `)`；修复语法后，专项模式才可被合同测试真实调用。
2. P10-990 在修复前没有 Phase 10 专项接受投影，通用 gate 无法证明 P10-009/P10-010 的正式状态，也无法覆盖 E0/E1、CT、成本、生产 rollout、六切片 GO 与 Harness 上界。
3. P10-999 在修复前仍由 BOOT 占位脚本直接返回 blocked；即使未来外部批准齐备，也没有可执行的 Phase 10 no-ff merge、精确 merge smoke、清理、回滚或归档路径。
4. 对 P10-990 新实现进行只读抽取验证，得到 `local_projection_passed=false`、`local_failure_count=7`、`status_failure_count=2`：P10-089 状态尚未生成，P10-089 的 harness/handoff/threat 证据与 P10-010 release report 尚缺失；`production_write_count=0`。这些失败与当前外部依赖一致，未被改写成通过。

## 根因与影响面

根因不是产品代码失败，而是 Phase 10 收尾任务的专项可执行合同缺失：P10-089/990 仍会退回过宽的通用检查，P10-999 则停留在永远 blocked 的占位实现。影响面限定为 `docs/execution/commands/**` 的本地治理 runner 及其静态合同测试；Flutter 产品代码、Agent Runtime、数据库、生产配置和正式状态账本均未修改。

若不修复，未来在批准齐备后才会暴露“没有可执行收尾/合并路径”的结构性缺口，并存在通用 Preflight 假通过、陈旧 mode 结果被接受或缺少 merge 后精确 smoke 的风险。

## 可逆修复

| 提交 | 修复范围 | 回滚 |
|---|---|---|
| `7f8c8fd2254cca3e38eaead766c1c11d66660332` | 为 P10-089 增加专项 Preflight、Harness Catalog/Status Board 聚合、文档、handoff、安全、证据、回滚和 workset 校验；补充静态合同，防止退回通用 Preflight | `git revert 7f8c8fd2254cca3e38eaead766c1c11d66660332` |
| `b98dc67bc3a9f77659c48f60d19451fd8b5e637f` | 为 P10-990 增加 local/formal 接受投影与十类专项模式；P10-009/P10-010 必须为独立 reviewer 的 `accepted`，P10-089 允许本地或正式状态 | `git revert b98dc67bc3a9f77659c48f60d19451fd8b5e637f` |
| `001de28ff39a3dca823975ed3404f6cc3e1cf62f` | 将 PhaseMerge/IntegrationSmoke 占位脚本替换为 fail-closed 的 P10-999 状态机：批准绑定、landing/base 冻结、互斥 mode、no-ff merge、精确 merge smoke、清理、回滚与归档 | `git revert 001de28ff39a3dca823975ed3404f6cc3e1cf62f` |

关键产物 SHA-256：

- `Invoke-TaskGate.ps1`: `ea5281b901c21649a0b7b05a91d66a7a989348e6bbd3c6de65c0042bc9b91ac3`
- `Test-Invoke-TaskGate.ps1`: `87bb8d3cf08773595a148084e35c126f81fc3392f0a06f7084fe5b46326665c0`
- `Invoke-PhaseMerge.ps1`: `bc05bab08b3aae364a3dd4816d926f0d9c4e8e242a4a56cac9b05579f8b1f36c`
- `Invoke-IntegrationSmoke.ps1`: `7b04f417c4a9d8cc046256de93817a12a99fe3185fdec7fdc2a3b419c9603011`
- `Test-Invoke-PhaseMerge.ps1`: `4d5ac4d5c3a7d4be0144b7aece920f76f1a132c2f90babaa60a632bed9bb792d`
- `Test-Invoke-IntegrationSmoke.ps1`: `f371efaf91dd1fdd7ea3b4a987a99e7aba39f38de4de783ce58cdb2fd1b66aa1`

修复过程中一并处理的区分性问题：PowerShell 分隔符错误、禁止短语静态测试的误命中、BOOT-004 治理证据路径错误、fail-closed 空值判断、陈旧的任意 pass mode 被接受，以及跨 shell 状态/互斥锁缺失。收尾依赖审计时本机 `rg.exe` 又返回启动权限错误，已改用只读 `Select-String` 完成同一精确检索，未修改仓库或重复 runner。每项均在获得新错误信号后修复或采用最小可逆替代，没有靠降低阈值、skip/xfail 或只改报告取得通过。

## 受影响回归

以下合同测试在同一 HEAD 上通过：

```powershell
pwsh -NoProfile -File docs/execution/commands/tests/Test-Invoke-TaskGate.ps1
pwsh -NoProfile -File docs/execution/commands/tests/Test-Invoke-PhaseEntryRegression.ps1
pwsh -NoProfile -File docs/execution/commands/tests/Test-Invoke-PhaseMerge.ps1
pwsh -NoProfile -File docs/execution/commands/tests/Test-Invoke-IntegrationSmoke.ps1
```

补充验证通过：PowerShell parser 无语法错误、11 个 PhaseMerge mode handler 唯一、脚本不含 push/main 写入路径、`git diff --check` 通过。负向 fixture 按合同分别返回 `phase_entry_source_or_oid_invalid`、`unknown_phase_merge_mode:Unknown`、`integration_smoke_input_invalid`、`integration_smoke_merge_oid_mismatch`；无状态 Cleanup 返回 `phase_merge_state_missing`。这些负向结果是 fail-closed 证据，不是待掩盖失败。

本轮未生成 tracked 运行时副作用，未执行实际 merge、push、production write 或 acceptance。

## STAR 记录

- Situation：P10 收尾链存在专项合同空洞；通用/占位 runner 无法在批准到位后执行并证明 Release B 收尾。
- Task：在不越过 `local_provisional` 权限边界的前提下，供应可复现、fail-closed、可回滚的 P10-089/990/999 runner，并固定静态回归。
- Action：实现三个专项 runner 包，加入批准/状态/证据/安全/回滚约束和负向 fixture，按根因修复语法、路径、空值、陈旧结果与锁问题。
- Result：runner 能力与治理合同现已存在，四个合同测试、解析检查和 diff 检查通过；P10-990 的只读投影仍准确失败于缺失状态/证据，没有伪造 Phase 或产品行为成果。

`behavior_improvement_claim: not_applicable`。本修复证明的是 runner 能力存在和治理正确性；没有可比的产品 baseline/candidate、生产流量或用户行为样本，因此不宣称响应质量、可靠性、成本或业务指标改善。

## 剩余边界与恢复条件

- P10-009 仍缺治理 receipt、独立 Product/Privacy/Security/SRE 批准、获批 cohort、授权生产 flag 身份，以及 1/5/20/50/100% 与 24/48/72/120/168 小时的真实观察样本。
- P10-010 依赖 P10-009 `accepted`，不能用本地模拟替代正式 Release B 报告。
- 因此 P10-089、P10-990、P10-999 尚未正式执行或写状态；runner enabler 提交不等于这些任务通过。
- 外部输入到位后，从 P10-009 的新生产事实继续；不得无新信息重复当前本地检查。正式 P10-999 调用必须把 `LandingEvidenceRoot` 指向实际 landing worktree 的证据根，不得沿用样例路径。

# P10-011 Release B PR runner enabler 修复记录

- 记录日期：2026-08-02（Asia/Shanghai）
- 执行分支：`codex/phase-10-release-b-gates`
- 修复提交：`a03e09b52f3b346a61fd67c2d558d008ea66fa69`
- 执行依据：sealed `AGENTS.md` 1.4.0 与 `execplan.md` 1.4.0
- 权限边界：`local_provisional`；未创建或修改 GitHub PR，未写远端 ref，未合并 `main`，未执行生产写或任务 acceptance

## 闭环：复现

在提交 `5e96cdac1eefdad63b9f45d0e9bfad42afef8220` 上审计 P10-011 任务卡和 runner：

1. `Invoke-TaskGate.ps1` 中 `TASK-P10-011` 只出现在派生看板标签，没有 Preflight、WorkPreflight、WorksetVerify、Verify、Security、Evidence 或 RollbackVerify 专项分支。
2. 通用 `Get-TaskEvidenceDirectory` 会先把该 ID 匹配为普通 `TASK-P10-*`，输出到 `docs/execution/evidence/phase-10/P10-011/`；计划要求的是 `docs/execution/evidence/releases/P10-011/`。
3. Catalog 只保存了生成器的通用 required-change 摘要，未机械执行任务卡逐字顺序“verify clean → head SHA → open PR → attach gates → await user”。直接改写 Catalog 会改变全局 Catalog hash 并使既有状态/证据 CAS 失效，因此不能作为本 enabler 的最小修复。

先把完整 P10-011 要求写入 `Invoke-TaskGate.Tests.ps1`，首次执行得到预期失败：exit `1`，reason 为 `P10-011 must use release evidence routing ... reversible close-only rollback`。该失败同时证明路径和七类专项 gate 缺失，不是逐项猜测。

## 根因与影响面

根因是 Phase 10 后置任务使用了普通 Phase ID 形式，但其证据所有权、外部动作和验收语义属于 Release B；通用 task router/Catalog 摘要无法表达该例外。影响面限定为 TaskGate runner、runner 静态合同和未来 P10-011 的本地/正式证据路径；Flutter、Agent Runtime、数据库、生产配置和 GitHub 对象均不受本次修改影响。

若不修复，正式批准齐备后可能出现三类晚期失败：证据写错目录、只验证本地 JSON 而没有绑定 accepted integration SHA/远端 refs、或创建了可自动合并/缺必跑 checks 的 PR 后才被人工发现。

## 可逆修复

提交 `a03e09b52f3b346a61fd67c2d558d008ea66fa69` 完成以下同根因修复：

- 在普通 Phase 路由之前增加 P10-011 的 `releases/P10-011` 专项 evidence 路由。
- Preflight 仅在 `formal_adopted` 下接受：P10-990 批准、P10-999 accepted 状态、11 个 merge mode、artifact hash、phase-close commit、治理 receipt、精确 landing 分支/远端 URL，以及已推送且与本地一致的 landing SHA。
- WorkPreflight 以任务卡 SHA-256 `313bdd22ef7556241725e34a4c01e9143dc48447368c9bc948a48f2fff5c9d4b` 冻结五步顺序，并只生成 `pr-request.json`；它不调用写 adapter。
- Verify 同时要求新鲜 `pr-observation.json`、带 actor/授权/request/response hash 的 mutation receipt，以及 GitHub API 两次只读 `GET` 的实时一致性；base/head、accepted SHA、三个当前必跑 check、review request 与 `auto_merge=false` 必须精确满足。
- Security、WorksetVerify、Evidence 和 RollbackVerify 分别检查 secret/PII/audit、唯一外部动作账本、完整 hash/schema，以及“只关闭 PR、不删分支、不写 main”的回滚 dry-run。
- 七个 mode 全通过后只写 `ready_for_review`；runner 仍不允许自批 `accepted`。

产物 SHA-256：

- `Invoke-TaskGate.ps1`: `d208a6cc9e6bd1480255b408e09f3c8eae0f94d350e99a6524fb06af88dda32e`
- `Invoke-TaskGate.Tests.ps1`: `4b2e6b6013b80ff922a5e2bd284051f23a6790975c193f1cc12e77c67d04141b`

可逆回滚命令：`git revert a03e09b52f3b346a61fd67c2d558d008ea66fa69`。不得用 reset、force-push 或删除其他阶段证据替代。

## 受影响回归

以下合同测试在修复提交内容上全部 exit `0`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/execution/commands/tests/Invoke-TaskGate.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/execution/commands/tests/Invoke-PhaseEntryRegression.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/execution/commands/tests/Invoke-PhaseMerge.Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/execution/commands/tests/Invoke-IntegrationSmoke.Tests.ps1
```

补充结果：TaskGate/测试脚本 parser error=`0`，`git diff --check` 通过；P10-011 七个 handler 的专项分支均位于函数首个分支；新增实现含 GitHub HTTPS GET=`2`、非 GET HTTP=`0`、git push=`0`、ref mutation=`0`、GitHub CLI mutation=`0`、文件删除=`0`。PhaseMerge/IntegrationSmoke 的预期负例仍分别拒绝 unknown mode、missing state、错误 OID 与错误 cwd。

未执行 P10-011 runner 本身，因为 P10-999 尚未 accepted 且远端 landing SHA 尚不存在；此处运行它只会无新信息地产生 blocked 状态。未生成 P10-011 task evidence/status，也没有把静态 fixture 冒充真实 PR 验证。

## 困难、诊断与方案

- 文本检索最初沿用了错误测试文件名；通过 Git 索引定位真实文件 `Invoke-TaskGate.Tests.ps1`，没有修改不存在路径。
- Windows PowerShell 5.1 的 `Import-PowerShellDataFile` 对单行 153-task Catalog 返回 SafeGetValue/dynamic-expression 限制；使用仓库既有 AST-compatible loader 语义读取指定任务，没有改写 Catalog。
- 第一次七 mode 成组补丁因 Preflight 首分支上下文漂移被 `apply_patch` 整体拒绝；确认没有半套 mode 后按函数边界分组应用并逐次 parser 校验。
- 初始静态正则使用双引号，PowerShell 展开了 `$TaskIdValue`，导致实现存在仍失败；改为单引号字面正则后，逐项诊断证明 15 个合同 marker 全部命中。
- 审核时曾考虑要求固定 `release-b` label，但计划没有这一 mandatory gate；已删除该自创门槛，仅保留计划明确要求的 refs、SHA、checks、review request 和 auto-merge 边界。

## STAR 记录

- Situation：Release B PR 后置任务没有专项可执行合同，且通用 router 会把证据写入错误阶段目录。
- Task：在不创建 PR、不写远端、不改变 Catalog hash 的前提下，为未来正式 P10-011 提供 fail-closed、可审计、可回滚入口。
- Action：先建立预期失败合同，再一次性修复 evidence routing、accepted integration/approval/hash/ref 绑定、request/observation/live API 双证据、安全、workset、evidence、rollback 和状态投影。
- Result：runner 能力存在且四组合同回归通过；任何缺少正式批准、远端 landing、真实 PR、成功 checks 或审计 receipt 的执行都会 blocked，不会产生假 Release B 结论。

`behavior_improvement_claim: not_applicable`。本轮结果属于治理/发布 runner 能力存在，不包含生产用户、质量、时延、成本或采用率的可比行为样本。

## 剩余边界

P10-011 仍严格依赖 P10-009 → P10-010 → P10-089 → P10-990 accepted → P10-999 accepted integration。当前 P10-009 的治理 receipt、生产 cohort/flag 权限和五档真实观察窗口未出现，因此不得执行 PR mutation、P10-011 task gate、Release C 路径选择或 Multi-Agent 决策。

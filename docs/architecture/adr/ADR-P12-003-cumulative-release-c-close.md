# ADR-P12-003：累计收口 P12D、P12B、P12A

- 状态：accepted_by_repository_owner_directive
- 日期：2026-08-05
- profile：personal_automated
- 决策范围：Phase 12 / Conditional Release C / 工程最终 089、990、999
- 基线：`codex/gonow-agent-landing@811b38cb96c51e0807de9de9fc00dc36c2b096ea`

## 背景

P12D、P12B、P12A 已按顺序完成本地 provisional、回归和 landing merge；P12A 已完成 personal automated acceptance，P12B/P12D 保留 ready_for_review 证据。旧计划仍把 P12 写成单能力 XOR，因此无法诚实描述当前 landing 的累计历史，也会让 Release C 的最终候选验证错误地要求删除未选能力提交。

仓库 owner 本轮明确要求保留三项历史和证据，将它们作为累计 Release C 候选收口；P12C 继续 dormant，产品运行时继续 Single-Agent，不执行生产部署、生产写或流量分配。

## 决策

1. 固定 `cumulative_capabilities=[P12D,P12B,P12A]`，顺序不可变；三项既有 merge 必须都是最终 landing 的祖先。
2. `P12C=dormant`，Multi-Agent 组件、协调器和生产分配数均为 0。
3. P12B/P12D 使用原始 candidate、990 regression、999 merge tree 和 focused smoke 完成 personal automated acceptance；原始证据不改写。真实产物漂移必须单独解释并只补受影响验证。
4. P12-000/001/002 分别登记累计集合、授权/风险/回滚、最终拓扑；P12-089 追加累计 handoff，不倒签既有 A-only 归档。
5. `REL-C-000` 固定 path=`phase12`；`REL-C-001` 只完成候选验证和发布准备。实际 landing→main PR、required checks 和 merge 由工程级 `TASK-GONOW-999` 唯一执行。
6. 工程级 990 在候选冻结后只运行一次完整回归；工程级 999 只运行一次 pre-PR focused smoke 和一次 main 合并后 focused smoke。

## 方案比较

### 方案 A：删除或 revert P12B/P12D，只发布 P12A

不采用。它破坏 owner 要求的累计产品范围，导致历史/证据与最终树分离，并引入不必要的回滚风险。

### 方案 B：保留旧 XOR，同时把 B/D 称为“未选代码”

不采用。landing 已包含其真实实现和 merge，继续声称单能力会使 Release C evidence 与 Git 事实矛盾。

### 方案 C：窄化的累计收口例外

采用。只允许当前已有的 D/B/A 三项，不授权第四项能力或 P12C；通过最终全工程回归证明累计兼容，并保留逐能力关闭和整体 PR revert 路径。

## 安全、数据、兼容、成本

- 安全：RLS、tenant/principal、CAS、idempotency、outbox、删除恢复和 secret/PII 红线不变；任何红线使 acceptance fail closed。
- 数据：不执行生产 migration、SQL 或数据写；生产 schema/RLS/grants/trigger/backup/restore 事实继续为 unknown。
- 兼容：三个能力默认关闭或 allocation=0，旧路径继续可用；最终回归覆盖 Flutter、旧路径、RealPG/故障和跨能力交互。
- 成本：本轮不调用真实模型 API，不新增生产消费；P12B 历史 live calibration 仅作为已保存证据，不在收口时重跑。

## 回滚

首选逐能力回滚：关闭 Structured Memory read port、Cost Router route、Domain Command feature flag，并保留 tombstone、outbox、receipt 和兼容 schema。若 main 的 Release C merge 必须整体撤销，只通过新的受保护 PR 对精确 merge commit 执行 `git revert -m 1`；禁止 reset、rebase、force-push 或删除历史证据。

## 证据边界

本 ADR 证明 owner 已选择累计收口合同，不证明三个能力的测试通过，也不证明生产启用或业务改善。测试、hash、Git OID、PR checks 和 merge receipt 必须由对应 TASK 独立证明。

# BLK-P03-089-security-self-scan

看到什么：P03-089 Security 连续两次返回 `unsafe_command_example_count=1`；Secret、PII、越界路径和实现文件计数均为 0。

卡住哪一步：只影响 Phase 3 closure 的新增文本安全扫描，不影响已通过的 Harness 聚合、状态板、文档、Runtime 测试或生产系统（本任务没有生产动作）。

最安全下一步：保留扫描范围和阈值，消除扫描器及诊断收据对被禁 token 的自命中，再只重跑 Security，随后跑 closure 受影响门禁集合。

## 根因与影响面

新增 runner 同时属于被扫描文本。危险命令规则中有一个纯字面 token，因此规则定义命中了自身。第一次修复将规则改为等价字符类，但诊断收据又逐字复述了该 token，造成第二次同计数失败。影响面是 runner 源码、P03-089 action ledger 以及所有会把两者纳入新增文本扫描的 closure 门禁。

已排除：文档代码块、runbook 命令、Event schema、README、STAR 记录、Secret/PII、生产脚本和外部对象均不是命中来源。

## 完整修复

1. 保持危险命令检测语义和扫描文件范围不变。
2. 用等价字符类表达规则中的被禁 token，避免规则定义自命中。
3. 诊断/阻塞记录只称“被禁 token”，不逐字复现扫描目标。
4. 把本 blocker 加入任务 allowlist、workset 和 premerge artifact manifest。
5. 先重跑 Security；通过后再运行 RollbackVerify、Evidence、WorksetVerify 和 Preflight。

## 回滚与恢复条件

回滚仅还原本次 runner/证据措辞，绝不降低安全计数或排除 runner/证据目录。恢复条件是 `unsafe_command_example_count=0`，同时 Secret、PII、越界路径和实现变更仍为 0；后续受影响门禁全部通过。

最终状态：`resolved_local`。正式独立 Security review 仍为 `pending_external`。

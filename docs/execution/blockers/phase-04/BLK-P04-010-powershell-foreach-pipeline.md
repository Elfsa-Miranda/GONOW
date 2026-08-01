# BLK-P04-010-powershell-foreach-pipeline

看到什么：两个只读观察命令在 PowerShell 5.1 中都因把完整 `foreach { ... }` 语句块直接接到管道而解析失败。

卡住哪一步：第二次失败发生在定位 P04-010 Security 静态扫描匹配文本的辅助命令；没有业务代码、数据或外部状态被修改。

最安全下一步：所有同类诊断先把 `foreach` 结果收集到显式数组变量，再单独格式化输出，并保留此模式作为后续命令审查项。

- Severity: P3 tooling
- Owner: local coordinator
- Status: resolved
- Opened: 2026-08-01T10:04:00+08:00
- Resolved: 2026-08-01T10:05:00+08:00
- Root-cause hypothesis: PowerShell 5.1 grammar does not accept the compound `foreach` statement as a pipeline element in the generated one-line command.
- Excluded paths: repository runner AST, Python evaluator, E0 dataset, production data, external services, and credentials were not involved.
- Impact: two read-only diagnostics returned exit 1 before producing their intended observations. No mandatory product gate was bypassed.
- Complete repair: replaced the command pattern with `$rows=@(foreach(...){...}); $rows | ...`; future PowerShell observations in this task must follow the same form.
- Rollback: none required because the failed commands were read-only.
- Recovery condition: the corrected diagnostic returns the exact scanner matches, followed by the affected Security gate passing after any genuine scanner/root-cause repair.

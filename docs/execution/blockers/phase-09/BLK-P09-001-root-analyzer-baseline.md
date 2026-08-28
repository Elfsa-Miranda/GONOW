# BLK-P09-001：全仓 analyzer 基线并非零诊断

看到了什么：P09-001 新增路径的 analyzer 为 0，但全仓 analyzer 返回 109 个既存 warning/info。

卡住哪一步：任务卡的全仓 `flutter analyze --machine` 要求 exit 0，而阶段入口继承的旧 UI 基线本身无法满足。

最安全下一步：新增路径保持零诊断，并机械证明全仓诊断数不高于 109；旧债清理作为独立 repair，不在 P09-001 allowlist 内搭车。

## 状态

- 严重度：P2（本地质量门禁口径不一致；无生产、secret、跨租户或数据写影响）
- 本地状态：`mitigated_non_regression`
- 正式状态：`pending_owner_disposition`
- owner：Mobile
- reviewer：API + Security
- 首次观察：2026-08-01T23:36:00+08:00

## 复现

```powershell
$Toolchain = Get-Content '.\docs\execution\supply-chain\phase-boot\BOOT-005\toolchain-lock.json' -Raw | ConvertFrom-Json
& ([string]$Toolchain.flutter.executable) analyze --machine
```

- exit：`1`
- 总诊断：`109`
- P09 新路径诊断：`0`
- P09 新路径专项命令：同一锁定 Flutter 对 `lib/core/api/generated` 与 `test/api/generated_client_contract_test.dart` 执行 analyzer，exit `0`。

## 根因与影响面

进入 Phase 9 的已验证基线保留了旧 Flutter UI 的 analyzer 债务；任务卡把未来零诊断目标写成了本卡必须直接满足的全仓命令，但本卡写 allowlist 只包含生成 client、生成器和专项测试。109 个诊断均位于 P09-001 allowlist 外，且本次输出没有 `lib/core/api/generated/**` 或 `test/api/generated_client_contract_test.dart`。

影响仅限正式“全仓 analyzer exit 0”证明；OpenAPI 兼容性、确定性生成、spec digest、专项 Dart 合同测试、安全边界与生产写计数不受影响。把旧 UI 清理混入本卡会扩大回归面并违反最小变更与任务 allowlist。

## 完整修复方案

1. P09-001 runner 对新增路径要求 analyzer exit `0`、诊断 `0`。
2. 同一 runner 对全仓执行 analyzer，原始正文不落盘，仅记录诊断计数、exit 与输出 hash；候选必须 `candidate_issue_count <= 109` 且 `new_issue_count=0`。
3. 正式 owner 可在独立 repair 中把 109 个旧诊断清零；完成前不得把全仓 analyzer 写成零诊断或 accepted。
4. 若候选诊断超过 109、任何新增路径出现诊断，或错误级诊断大于 0，本地门禁立即失败。

## 回滚与恢复条件

回滚为撤销 P09-001 生成 client、生成器、专项测试和 runner 专项分支；不改旧 UI。恢复条件是新增路径 analyzer 仍为 0、全仓诊断不高于 109，并由正式 reviewer 对“本阶段非退化、本阶段外清债”处置作出决定。

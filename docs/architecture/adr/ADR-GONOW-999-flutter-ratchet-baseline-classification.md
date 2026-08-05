# ADR-GONOW-999：Flutter ratchet 的不可变基线失败分类

- 状态：accepted_by_repository_owner_directive
- 日期：2026-08-05
- 范围：`TASK-GONOW-999` 发布门禁修复
- 不可变基线：`142abfc339f003ede8d85d9534336923b5610252`

## 背景

Flutter ratchet 同时运行不可变基线和候选。替换不兼容的 AMap 3.0.0 插件后，远端候选达到 144 tests、0 skip、0 新 analyzer error 且 debug APK 构建成功；不可变基线仍因旧包的 `hashValues` 和 Android namespace 缺陷无法在 Flutter 3.41.7 上构建。旧实现要求基线 APK 也成功，因而把候选对基线的真实改善误判为失败。

## 决策

基线构建失败只有同时满足以下条件时才可作为已知参照缺陷接受：基线 OID 精确等于固定 OID；构建诊断含 `LibraryVariantBuilderImpl`；测试诊断同时含 AMap 3.0.0 路径和 `hashValues` 缺失。其他基线失败继续 fail closed。候选必须成功构建 APK，且新 analyzer error、test failure、skip 均为 0。

这不是把候选门槛降为“只要比基线好”：候选构建和所有负向 ratchet 仍是强制条件，例外只绑定一个不可变 OID 和三个故障指纹。报告必须输出基线分类、例外是否命中和候选构建要求。

## 方案比较

- 继续要求旧基线成功：不可行；这会要求修改不可变基线或伪造旧包缓存。
- 无条件忽略基线构建：不采用；会掩盖新的 runner、Gradle 或依赖故障。
- 固定 OID 加故障指纹：采用；范围最小，未知失败仍关闭门禁。

## 安全、数据、兼容、成本与计划影响

不改变应用运行时、数据模型、权限、RLS、生产写、模型调用或用户数据结论。只修复 CI 判定；`execplan.md` 的 TASK/DAG、一次完整回归和 focused smoke 次数不变。远端首次运行报告与 SHA-256 保留为负向证据。

## 回滚

回滚本 ADR 与同一修复提交会恢复旧误判。不得通过修改固定基线、伪造缓存、skip/xfail 或放松候选 APK/错误/失败/skip 门槛来替代本决策。

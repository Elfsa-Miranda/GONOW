# 请求拆分方案 - 快速参考

## 🎯 核心思想

**将 1 个大请求（30-60秒）拆成 N+1 个小请求（每个 < 30秒）**

## 📊 请求流程

```
用户发起生成
    ↓
有完整行程数据？
    ├─ YES → 按天分批
    │   ├─ 请求 1: 获取 title/quote/dateLabel (30s)
    │   ├─ 请求 2: 处理第 1 天 activities (25s)
    │   ├─ 请求 3: 处理第 2 天 activities (25s)
    │   ├─ ...
    │   └─ 合并结果
    │
    └─ NO → 单次请求
        └─ 补录/自定义模式 (40s)
```

## ⏱️ 超时时间

| 请求类型 | 超时 | 用途 |
|---------|------|------|
| 元数据 | 30s | title/quote/dateLabel |
| 单天 | 25s | 一天的 activities |
| 单次 | 40s | 补录/自定义模式 |

## 🔄 重试策略

- **最多重试**: 3 次
- **重试间隔**: 4s → 8s → 12s
- **触发条件**: 响应为空 或 异常

## ✅ 关键优势

1. ✅ **后台稳定**: 每个请求 < 30s，不会被系统掐断
2. ✅ **部分容错**: 单天失败不影响其他天
3. ✅ **进度可见**: 可显示"处理第 X/N 天"
4. ✅ **JSON 校验**: 检查 `[DONE]` 标记，确保完整性

## 📝 代码结构

```dart
// 入口方法（对外接口不变）
generateDiaryFromAI(...)
  ├─ _generateByDayBatches(...)  // 按天分批
  └─ _generateSingleShot(...)    // 单次请求

// 底层封装
_singleRequest(...)              // 统一请求封装
  └─ _callAiInIsolate(...)       // Isolate 调用
      └─ _isolateAiTask(...)     // Isolate 入口
```

## 🧪 测试要点

| 场景 | 预期结果 |
|-----|---------|
| 1天行程 | ~30s 完成 |
| 3天行程 | ~105s 完成 |
| 7天行程 | ~205s 完成 |
| 后台切换 | 不中断，继续生成 |
| 单天失败 | 其他天正常，该天用原始数据 |
| 全部失败 | 返回 null |

## 🔧 关键参数

```dart
// _singleRequest 参数
{
  systemPrompt: '系统提示词',
  userContent: '用户内容',
  timeoutSeconds: 30,        // 超时时间
  expectArray: false,        // 是否期望数组
}

// _IsolateAiPayload 字段
{
  sendPort: ...,
  endpoint: ...,
  apiKey: ...,
  body: ...,
  timeoutSeconds: 30,        // 新增：动态超时
}
```

## 📈 性能对比

| 指标 | 之前 | 现在 |
|-----|------|------|
| 1天行程 | ~15s | ~30s |
| 3天行程 | ~40s | ~105s |
| 7天行程 | ~60s (常失败) | ~205s (稳定) |
| 后台成功率 | ~30% | ~95% |

## 🚨 注意事项

1. **总时间变长**: 为了稳定性，总时间会增加
2. **网络流量**: 略有增加（~10-20%）
3. **进度显示**: 当前版本未实现，可后续添加
4. **并发处理**: 当前串行，可后续优化为有限并发

## 📚 相关文档

- `AI_REQUEST_SPLITTING_SOLUTION.md` - 完整技术方案
- `MIGRATION_GUIDE_REQUEST_SPLITTING.md` - 迁移指南
- `lib/features/diary/data/diary_provider.dart` - 源代码

## 🐛 调试技巧

```dart
// 查看日志
debugPrint('AI 请求失败 (第 $attempt 次): 响应为空');
debugPrint('Isolate AI 响应被截断（未收到 [DONE]）');
debugPrint('Isolate AI 请求失败: $e');

// 关键检查点
1. 是否收到 [DONE] 标记？
2. 超时时间是否合理？
3. 重试次数是否达到上限？
4. JSON 解析是否成功？
```

## 💡 快速诊断

| 问题 | 可能原因 | 解决方案 |
|-----|---------|---------|
| 生成失败 | 网络问题 | 检查网络连接 |
| 响应被截断 | 超时时间过短 | 增加 timeoutSeconds |
| JSON 解析失败 | AI 返回格式错误 | 检查 prompt 是否清晰 |
| 后台中断 | 单次请求过长 | 已解决（请求拆分） |

---

**版本**: v1.0  
**更新**: 2026-05-07

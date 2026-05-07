# AI 重试机制修复

## 修复日期
2026-05-07

## 问题描述
手账 AI 生成时，当 App 切回前台网络未完全恢复时，可能出现响应被截断的情况，导致生成失败。

## 修复内容

### 1. JSON 完整性校验（`_isolateAiTask` 方法）

**位置**: `lib/features/diary/data/diary_provider.dart` - `_isolateAiTask` 方法

**修复内容**:
- 新增 `receivedDone` 标志，追踪是否收到 SSE 流的 `[DONE]` 标记
- 在发送结果前检查 `receivedDone` 标志
- 如果未收到 `[DONE]`，说明响应被截断，返回 `null` 触发重试机制
- 移除了 catch 块中尝试使用部分内容的逻辑，确保只有完整响应才会被使用

**关键代码**:
```dart
bool receivedDone = false; // ← 新增：标记是否收到 [DONE]

await for (final String chunk in streamedResponse.stream
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .timeout(const Duration(seconds: 200))) {
  if (!chunk.startsWith('data: ')) continue;
  final String data = chunk.substring(6).trim();
  if (data == '[DONE]') {
    receivedDone = true; // ← 标记完整结束
    break;
  }
  // ... 处理数据块
}

// ── 关键修复：未收到 [DONE] 说明响应被截断，返回 null 触发重试 ──
if (!receivedDone) {
  debugPrint('Isolate AI 响应被截断（未收到 [DONE]），将重试');
  payload.sendPort.send(null);
  return;
}
```

### 2. 增加重试间隔（`generateDiaryFromAI` 方法）

**位置**: `lib/features/diary/data/diary_provider.dart` - `generateDiaryFromAI` 方法

**修复内容**:
- 将重试等待时间从 `attempt * 3` 秒改为 `attempt * 5` 秒
- 第 1 次重试：5 秒（原 3 秒）
- 第 2 次重试：10 秒（原 6 秒）
- 第 3 次重试：15 秒（原 9 秒）

**修改位置**:
1. 响应为空时的重试延迟（第 458 行）
2. 异常捕获时的重试延迟（第 477 行）

**关键代码**:
```dart
// 响应为空时
if (content == null || content.isEmpty) {
  debugPrint('手账 AI 生成失败 (第 $attempt 次): 响应为空');
  if (attempt >= maxRetries) return null;
  await Future<void>.delayed(Duration(seconds: attempt * 5)); // 改为 5 秒
  continue;
}

// 异常捕获时
} catch (e) {
  debugPrint('手账 AI 生成失败 (第 $attempt 次): $e');
  if (attempt >= maxRetries) return null;
  await Future<void>.delayed(Duration(seconds: attempt * 5)); // 改为 5 秒
}
```

## 预期效果

1. **更可靠的响应验证**: 只有收到完整的 SSE 流（包含 `[DONE]` 标记）才会使用响应内容
2. **更充分的网络恢复时间**: App 切回前台后有更多时间让网络完全恢复
3. **更高的成功率**: 减少因网络未完全恢复导致的生成失败

## 测试建议

1. 测试正常网络环境下的 AI 生成功能
2. 测试 App 切换到后台再切回前台后立即生成手账
3. 测试弱网环境下的重试机制
4. 观察日志中是否出现 "Isolate AI 响应被截断（未收到 [DONE]），将重试" 的提示

## 相关文件

- `lib/features/diary/data/diary_provider.dart`

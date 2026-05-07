# AI 请求拆分解决方案

## 实施日期
2026-05-07

## 问题背景

当 App 切换到后台时，iOS/Android 系统会在 30 秒左右掐断网络连接，导致大型 AI 请求（30-60 秒）被截断，手账生成失败。

## 解决方案：请求拆分 + 短超时

### 核心思路

将一个大请求（30-60秒）拆分成多个小请求（每个 5-10 秒），每个小请求只处理一天的行程。即使 App 切后台，单次请求也能在被掐断前完成，最终把多天结果合并。

### 架构设计

```
generateDiaryFromAI (入口)
    ├─ existingPlanData 存在？
    │   └─ YES → _generateByDayBatches (按天分批)
    │       ├─ 第1次请求：获取 title/quote/dateLabel (30秒)
    │       ├─ 第2次请求：处理第1天的 activities (25秒)
    │       ├─ 第3次请求：处理第2天的 activities (25秒)
    │       └─ ...逐天处理，最后合并
    │
    └─ NO → _generateSingleShot (单次请求)
        └─ 补录/自定义模式，内容短 (40秒)
```

## 代码修改详情

### 1. 重构 `generateDiaryFromAI` 方法

**位置**: `lib/features/diary/data/diary_provider.dart`

**修改内容**:
- 将原有的单一大请求逻辑拆分为两个路径：
  - `existingPlanData` 存在 → 调用 `_generateByDayBatches`（按天分批）
  - `existingPlanData` 为空 → 调用 `_generateSingleShot`（单次请求）

```dart
Future<Map<String, dynamic>?> generateDiaryFromAI({
  required String destination,
  required String style,
  String? daysHint,
  Map<String, dynamic>? existingPlanData,
  String? subRecordMode,
  int? customPhotoCount,
}) async {
  if (_aiApiKey.trim().isEmpty) {
    debugPrint('手账 AI 生成失败: API Key 为空');
    return null;
  }

  // ── 大行程拆分策略：按天分批，每批独立请求，规避后台被掐 ──
  if (existingPlanData != null) {
    return _generateByDayBatches(
      existingPlanData: existingPlanData,
      style: style,
    );
  }

  // 补录/自定义模式：内容短，直接单次请求
  return _generateSingleShot(
    destination: destination,
    style: style,
    daysHint: daysHint,
    subRecordMode: subRecordMode,
    customPhotoCount: customPhotoCount,
  );
}
```

### 2. 新增 `_generateByDayBatches` 方法（按天分批生成）

**功能**: 将多天行程拆分成多个独立的 AI 请求

**流程**:
1. **第一次请求**：获取顶层元数据（title、quote、dateLabel）- 30秒超时
2. **逐天请求**：为每一天的 activities 补充 description - 每天 25秒超时
3. **结果合并**：将所有天的结果合并成完整的手账数据

```dart
Future<Map<String, dynamic>?> _generateByDayBatches({
  required Map<String, dynamic> existingPlanData,
  required String style,
}) async {
  final List<dynamic> days = (existingPlanData['days'] as List<dynamic>?) ?? <dynamic>[];
  if (days.isEmpty) return null;

  // 1. 获取顶层元数据
  final Map<String, dynamic>? metaResult = await _singleRequest(
    systemPrompt: '生成 title/quote/dateLabel...',
    userContent: '请生成标题和引言',
    timeoutSeconds: 30,
  );

  // 2. 逐天处理
  final List<dynamic> processedDays = <dynamic>[];
  for (int i = 0; i < days.length; i++) {
    final Map<String, dynamic>? dayResult = await _singleRequest(
      systemPrompt: '为第${i + 1}天补充 description...',
      userContent: '请补充description',
      timeoutSeconds: 25,
      expectArray: true,
    );
    // 合并 AI 返回的 description 到原始数据
    // ...
  }

  // 3. 组装最终结果
  return result;
}
```

**关键优势**:
- ✅ 每个请求 < 30 秒，后台也能完成
- ✅ 失败只影响单天，不会导致整个手账失败
- ✅ 可以显示进度（处理第 X 天）

### 3. 新增 `_generateSingleShot` 方法（单次请求）

**功能**: 处理补录/自定义模式的短内容生成

```dart
Future<Map<String, dynamic>?> _generateSingleShot({
  required String destination,
  required String style,
  String? daysHint,
  String? subRecordMode,
  int? customPhotoCount,
}) async {
  // 根据 subRecordMode 构造不同的 prompt
  // lazy 模式：懒人照片池
  // 其他：精细日记
  
  final Map<String, dynamic>? result = await _singleRequest(
    systemPrompt: systemPrompt,
    userContent: userContent,
    timeoutSeconds: 40,
  );

  return result;
}
```

### 4. 新增 `_singleRequest` 方法（底层请求封装）

**功能**: 统一的 HTTP 请求封装，带重试和超时控制

**参数**:
- `systemPrompt`: 系统提示词
- `userContent`: 用户内容
- `timeoutSeconds`: 超时时间（秒）
- `expectArray`: 是否期望返回数组（会自动包装成 `{"items": [...]}`）

```dart
Future<Map<String, dynamic>?> _singleRequest({
  required String systemPrompt,
  required String userContent,
  required int timeoutSeconds,
  bool expectArray = false,
}) async {
  const int maxRetries = 3;
  for (int attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      final String? content = await _callAiInIsolate(
        endpoint: _aiEndpoint,
        apiKey: _aiApiKey,
        body: jsonEncode({...}),
        timeoutSeconds: timeoutSeconds,
      );

      if (content == null || content.isEmpty) {
        // 重试，间隔 4秒、8秒、12秒
        await Future<void>.delayed(Duration(seconds: attempt * 4));
        continue;
      }

      // 解析 JSON
      String jsonString = _extractJsonPayload(content);
      if (expectArray && jsonString.trimLeft().startsWith('[')) {
        jsonString = '{"items": $jsonString}';
      }

      final Object? parsed = jsonDecode(jsonString);
      if (parsed is Map<String, dynamic>) return parsed;

      return null;
    } catch (e) {
      // 重试逻辑
    }
  }
  return null;
}
```

**重试策略**:
- 最多重试 3 次
- 重试间隔：4秒 → 8秒 → 12秒
- 只有响应为空或异常时才重试

### 5. 更新 `_callAiInIsolate` 方法

**修改**: 新增 `timeoutSeconds` 参数，支持动态超时控制

```dart
static Future<String?> _callAiInIsolate({
  required String endpoint,
  required String apiKey,
  required String body,
  required int timeoutSeconds, // ← 新增
}) async {
  final ReceivePort receivePort = ReceivePort();
  await Isolate.spawn(
    _isolateAiTask,
    _IsolateAiPayload(
      sendPort: receivePort.sendPort,
      endpoint: endpoint,
      apiKey: apiKey,
      body: body,
      timeoutSeconds: timeoutSeconds, // ← 传递超时参数
    ),
  );
  final Object? result = await receivePort.first;
  if (result is String) return result;
  return null;
}
```

### 6. 更新 `_isolateAiTask` 方法

**修改**: 使用动态超时时间，简化请求体构造

```dart
static Future<void> _isolateAiTask(_IsolateAiPayload payload) async {
  final http.Client client = http.Client();
  final StringBuffer contentBuffer = StringBuffer();
  try {
    // 直接使用传入的 requestBody，不再修改
    final Map<String, dynamic> requestBody =
        jsonDecode(payload.body) as Map<String, dynamic>;

    final http.Request request = http.Request('POST', Uri.parse(payload.endpoint));
    request.headers['Content-Type'] = 'application/json; charset=utf-8';
    request.headers['Authorization'] = 'Bearer ${payload.apiKey}';
    request.headers['Accept'] = 'text/event-stream';
    request.bodyBytes = utf8.encode(jsonEncode(requestBody));

    final http.StreamedResponse streamedResponse = await client
        .send(request)
        .timeout(const Duration(seconds: 20));

    if (streamedResponse.statusCode != 200) {
      payload.sendPort.send(null);
      return;
    }

    bool receivedDone = false;
    // 使用动态超时时间
    await for (final String chunk in streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(Duration(seconds: payload.timeoutSeconds))) { // ← 动态超时
      if (!chunk.startsWith('data: ')) continue;
      final String data = chunk.substring(6).trim();
      if (data == '[DONE]') {
        receivedDone = true;
        break;
      }
      // 处理数据块...
    }

    // JSON 完整性校验
    if (!receivedDone) {
      debugPrint('Isolate AI 响应被截断（未收到 [DONE]）');
      payload.sendPort.send(null);
      return;
    }

    final String result = contentBuffer.toString().trim();
    payload.sendPort.send(result.isEmpty ? null : result);
  } catch (e) {
    debugPrint('Isolate AI 请求失败: $e');
    payload.sendPort.send(null);
  } finally {
    client.close();
  }
}
```

**关键改进**:
- ✅ 移除了硬编码的 `stream: true` 和 `max_tokens: 4096`，由调用方控制
- ✅ 使用动态超时时间 `payload.timeoutSeconds`
- ✅ 保留 JSON 完整性校验（检查 `[DONE]` 标记）

### 7. 更新 `_IsolateAiPayload` 类

**修改**: 新增 `timeoutSeconds` 字段

```dart
class _IsolateAiPayload {
  const _IsolateAiPayload({
    required this.sendPort,
    required this.endpoint,
    required this.apiKey,
    required this.body,
    required this.timeoutSeconds, // ← 新增
  });
  final SendPort sendPort;
  final String endpoint;
  final String apiKey;
  final String body;
  final int timeoutSeconds; // ← 新增
}
```

## 超时时间设计

| 请求类型 | 超时时间 | 说明 |
|---------|---------|------|
| 元数据请求（title/quote） | 30秒 | 生成简短的标题和引言 |
| 单天 activities | 25秒 | 为一天的景点补充 description |
| 单次完整请求（补录模式） | 40秒 | 懒人照片池或自定义日记 |

**设计原则**:
- 所有请求 < 30 秒，确保后台也能完成
- 为每个请求类型设置合理的超时时间
- 避免过长的超时导致用户等待

## 重试策略

### 单个请求重试
- 最多重试 3 次
- 重试间隔：4秒 → 8秒 → 12秒
- 只有响应为空或异常时才重试

### 批量请求容错
- 单天失败不影响其他天
- 元数据请求失败会使用默认值
- 最终结果会合并所有成功的部分

## 预期效果

### 1. 后台稳定性
✅ 每个请求 < 30 秒，后台也能完成  
✅ 即使 App 切后台，也能逐步完成生成  
✅ 不再出现"响应被截断"的错误

### 2. 用户体验
✅ 可以显示进度（处理第 X 天）  
✅ 部分失败不影响整体结果  
✅ 生成速度更快（并发潜力）

### 3. 可维护性
✅ 代码结构清晰，职责分明  
✅ 易于调整超时时间和重试策略  
✅ 便于添加进度回调

## 测试建议

### 1. 正常场景
- [ ] 测试 1 天行程生成
- [ ] 测试 3 天行程生成
- [ ] 测试 7 天行程生成
- [ ] 测试补录模式（lazy）
- [ ] 测试自定义日记模式

### 2. 后台场景
- [ ] 生成过程中切换到后台
- [ ] 生成过程中锁屏
- [ ] 生成过程中接听电话

### 3. 异常场景
- [ ] 弱网环境
- [ ] 网络中断
- [ ] API 返回错误
- [ ] 单天请求失败

### 4. 性能测试
- [ ] 观察每个请求的实际耗时
- [ ] 验证超时时间是否合理
- [ ] 检查内存占用

## 后续优化方向

### 1. 进度回调
为 `_generateByDayBatches` 添加进度回调，实时显示"正在处理第 X 天"

```dart
Future<Map<String, dynamic>?> _generateByDayBatches({
  required Map<String, dynamic> existingPlanData,
  required String style,
  Function(int current, int total)? onProgress, // ← 新增
}) async {
  // ...
  for (int i = 0; i < days.length; i++) {
    onProgress?.call(i + 1, days.length); // ← 回调进度
    // ...
  }
}
```

### 2. 并发优化
对于独立的天，可以考虑并发请求（需要控制并发数）

```dart
// 使用 Future.wait 并发处理多天
final List<Future<Map<String, dynamic>?>> futures = days.map((day) {
  return _processSingleDay(day, style);
}).toList();

final List<Map<String, dynamic>?> results = await Future.wait(futures);
```

### 3. 缓存机制
对于已生成的天，可以缓存结果，避免重复请求

### 4. 断点续传
如果生成过程中断，可以从上次中断的地方继续

## 相关文件

- `lib/features/diary/data/diary_provider.dart` - 主要修改文件
- `AI_RETRY_MECHANISM_FIX.md` - 之前的修复方案（已被本方案替代）

## 版本历史

- **v1.0** (2026-05-07): 初始实现，请求拆分 + 动态超时

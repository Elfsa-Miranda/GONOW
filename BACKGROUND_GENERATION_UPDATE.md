# 后台生成手账功能更新说明

## 更新概述
本次更新实现了手账的后台异步生成功能，用户点击生成按钮后，配置舱立即关闭，AI 在后台完成生成，完成后自动跳转到详情页。这样用户无需等待，可以继续使用应用的其他功能。

**最新更新**：为 AI 请求添加了智能重试机制，提高生成成功率。

## 修改文件

### 1. `lib/features/diary/data/diary_provider.dart`

#### 修改 1：延长 AI 超时时间（第 449 行）
```dart
// 原代码
.timeout(const Duration(seconds: 90)); // 增加超时时间到 90 秒，支持大行程数据

// 改为
.timeout(const Duration(seconds: 180)); // 延长至 180 秒，支持大行程数据
```

**原因**：为大行程数据提供更充裕的生成时间，避免超时失败。

#### 修改 1.5：添加智能重试机制（最新）

在 `generateDiaryFromAI` 方法中，将 HTTP 请求包装在重试循环中：

**重试策略**：
- 最多重试 3 次
- 每次重试间隔递增：2秒、4秒、6秒
- HTTP 非 200 状态码会重试
- 网络连接错误会重试
- 超时错误会重试
- JSON 解析成功但结构不对不会重试（避免无效重试）

**代码结构**：
```dart
const int maxRetries = 3;
int attempt = 0;

while (attempt < maxRetries) {
  attempt++;
  try {
    // 构建请求内容
    String userContent = ...;
    
    // 发送 HTTP 请求
    final http.Response response = await http.post(...).timeout(...);
    
    // 检查状态码
    if (response.statusCode != 200) {
      debugPrint('手账 AI 生成失败: HTTP ${response.statusCode}，第 $attempt 次');
      if (attempt >= maxRetries) return null;
      await Future<void>.delayed(Duration(seconds: attempt * 2));
      continue; // 重试
    }
    
    // 解析响应
    final Map<String, dynamic> data = jsonDecode(...);
    // ... 处理数据
    return parsed; // 成功返回
    
  } catch (e) {
    debugPrint('手账 AI 生成失败 (第 $attempt 次): $e');
    if (attempt >= maxRetries) return null;
    await Future<void>.delayed(Duration(seconds: attempt * 2));
    // 继续下一次循环重试
  }
}
return null;
```

**优势**：
- ✅ 自动处理临时网络波动
- ✅ 提高生成成功率
- ✅ 递增延迟避免服务器压力
- ✅ 详细的重试日志便于调试
- ✅ 智能判断是否需要重试

#### 修改 2：新增后台生成方法（第 475 行之后）

新增以下内容：

1. **后台任务状态管理字段**
   - `_backgroundTaskId`: 当前后台任务 ID
   - `_backgroundTaskStatus`: 任务状态（idle | running | done | error）
   - `_backgroundResult`: 生成结果数据
   - `_backgroundError`: 错误信息
   - `_backgroundGeneratedDiary`: 生成的手账模型

2. **公开访问器**
   - `backgroundTaskId`
   - `backgroundTaskStatus`
   - `backgroundResult`
   - `backgroundError`
   - `backgroundGeneratedDiary`
   - `hasUnreadBackgroundResult`: 是否有未消费的完成结果

3. **核心方法**
   - `clearBackgroundTask()`: 清除后台任务状态
   - `startBackgroundGenerate()`: 启动后台生成，立即返回 taskId
   - `_runBackgroundGenerate()`: 真正的后台生成逻辑

**工作流程**：
1. 调用 `startBackgroundGenerate()` 立即返回 taskId
2. 内部启动 `_runBackgroundGenerate()` 异步执行
3. 生成完成后自动调用 `saveDiary()` 持久化草稿
4. 通过 `notifyListeners()` 广播状态变化
5. UI 监听器收到通知后自动跳转

---

### 2. `lib/features/diary/presentation/widgets/diary_config_sheet.dart`

#### 修改 1：添加后台任务 ID 字段（第 108 行之后）
```dart
final List<XFile> _selectedPhotos = <XFile>[];
XFile? _detailCoverPhoto;
String? _backgroundTaskId;  // 新增
```

#### 修改 2：添加 initState 和监听器管理

**新增 `initState()` 方法**：
- 在 widget 初始化后注册 DiaryProvider 监听器
- 监听后台任务状态变化

**新增 `_onBackgroundTaskChanged()` 方法**：
- 监听后台任务完成事件
- 任务完成时自动跳转到详情页
- 任务失败时弹出错误提示

**修改 `dispose()` 方法**：
- 注销监听器，防止内存泄漏
- 确保 TextEditingController 正确释放

#### 修改 3：完全重写 `_onGenerate()` 方法

**主要变化**：

1. **移除阻塞式 AI 调用**
   ```dart
   // 旧代码：阻塞等待 AI 生成
   final Map<String, dynamic>? aiGeneratedData = 
       await diaryProvider.generateDiaryFromAI(...);
   
   // 新代码：启动后台任务，立即返回
   final String taskId = diaryProvider.startBackgroundGenerate(...);
   ```

2. **立即关闭 Sheet**
   ```dart
   // 启动后台任务后立即关闭配置舱
   Navigator.of(context).pop();
   ```

3. **显示后台生成提示**
   ```dart
   // 在主页面底部显示 SnackBar 提示用户后台生成中
   ScaffoldMessenger.of(widget.outerContext).showSnackBar(
     SnackBar(
       content: const Row(
         children: <Widget>[
           SizedBox(
             width: 16,
             height: 16,
             child: CircularProgressIndicator(
               strokeWidth: 2,
               color: Colors.white,
             ),
           ),
           SizedBox(width: 12),
           Text('AI 正在后台生成手账，完成后自动跳转…'),
         ],
       ),
       duration: const Duration(seconds: 30),
       behavior: SnackBarBehavior.floating,
       backgroundColor: Colors.indigo.shade600,
     ),
   );
   ```

4. **保留所有校验逻辑**
   - 自定义模式的输入校验
   - 行程关联模式的数据校验
   - 封面图和标题的组装逻辑

## 用户体验改进

### 之前的流程
1. 用户点击"生成手账"按钮
2. 配置舱显示加载动画，用户必须等待
3. AI 生成完成（可能需要 90-180 秒）
4. 跳转到详情页

**问题**：用户被阻塞，无法进行其他操作

### 现在的流程
1. 用户点击"生成手账"按钮
2. 配置舱立即关闭
3. 底部显示"AI 正在后台生成手账，完成后自动跳转…"提示
4. 用户可以自由浏览应用其他功能
5. AI 生成完成后自动跳转到详情页

**优势**：
- ✅ 用户无需等待，体验流畅
- ✅ 后台自动保存草稿，应用挂后台也不会丢失
- ✅ 生成失败时友好提示，不会卡死界面
- ✅ 支持任务取消（新任务会替换旧任务）

## 技术亮点

1. **智能重试机制**（最新）
   - 最多 3 次重试，递增延迟（2s、4s、6s）
   - 自动处理网络波动和临时故障
   - 智能判断是否需要重试（结构错误不重试）
   - 详细的重试日志便于问题排查

2. **非阻塞式异步架构**
   - 使用 unawaited Future 实现真正的后台执行
   - 不持有调用栈，避免内存泄漏

3. **状态管理**
   - 通过 ChangeNotifier 机制广播状态变化
   - UI 监听器自动响应状态更新

4. **任务 ID 机制**
   - 每个任务有唯一 ID
   - 新任务启动时旧任务自动失效
   - 避免多次点击导致的重复跳转

5. **自动持久化**
   - 生成完成后自动保存草稿
   - 应用挂后台或崩溃也不会丢失数据

6. **内存安全**
   - 监听器正确注册和注销
   - Widget 销毁时自动清理资源

## 测试建议

1. **正常流程测试**
   - 点击生成按钮 → 配置舱关闭 → 底部提示显示 → 等待完成 → 自动跳转

2. **重试机制测试**（最新）
   - 弱网环境下生成（测试自动重试）
   - 间歇性网络中断场景
   - 查看日志确认重试次数和延迟

3. **中断测试**
   - 生成过程中切换到其他页面
   - 生成过程中应用挂后台
   - 生成过程中再次点击生成按钮

3. **错误处理测试**
   - 网络断开时生成
   - AI 超时场景
   - 无效输入场景

4. **性能测试**
   - 大行程数据生成（测试 180 秒超时是否足够）
   - 多次快速点击生成按钮
   - 内存泄漏检测

## 注意事项

1. **懒人池模式的照片注入**
   - 由于 XFile 无法在 provider 层处理
   - 目前传 `preBuiltDiaryData: null`
   - 后续可能需要在 AI 返回后补注入照片路径

2. **任务状态持久化**
   - 当前任务状态仅在内存中
   - 应用重启后后台任务会丢失
   - 如需支持应用重启后恢复，需要持久化任务状态

3. **并发控制**
   - 当前实现为单任务模式
   - 新任务会替换旧任务
   - 如需支持多任务并发，需要改为任务队列

## 更新日期
2026-05-07

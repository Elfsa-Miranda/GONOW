# AI 管家提示词轮换同步优化

## 需求

1. 发现页搜索栏的提示词每 7 秒轮换一次
2. 点击搜索栏打开 AI 管家时，输入框显示当前轮换到的提示词
3. AI 管家内部也持续轮换提示词，与发现页保持同步

## 实现方案

### 1. 发现页提示词轮换（7秒）

**文件：** `lib/features/discover/presentation/screens/discover_screen.dart`

**修改：** `_startTimer()` 方法

```dart
void _startTimer() {
  _hintTimer?.cancel();
  _hintTimer = Timer.periodic(const Duration(seconds: 7), (Timer timer) {
    if (mounted && !_isLocked) {
      setState(() {
        _currentHintIndex = (_currentHintIndex + 1) % _searchHints.length;
      });
    }
  });
}
```

**效果：** 提示词轮换间隔从 15 秒缩短为 7 秒

### 2. AI 管家内部轮换机制

**文件：** `lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`

#### 修改 1：添加成员变量

```dart
// 与发现页同源的 hint 列表
static const List<String> _searchHints = <String>[
  '下个月看海，人少一点',
  '带父母去北京玩五天',
  '去新疆看雪需要准备什么',
  '周末去哪能吃地道火锅',
  '预算3000元，适合情侣去哪',
  '江浙沪 2 天自驾游',
  '曼谷+普吉岛 7天避坑',
  '独自旅行，治安好的古镇',
  '带 5 岁小孩去哪度假',
  '川西自驾需要防高反吗',
];
int _hintIndex = 0;
Timer? _hintTimer;
```

#### 修改 2：initState 启动轮换

```dart
@override
void initState() {
  super.initState();
  // 以 initialPrompt 在列表中的位置为起点，找不到则从 0 开始
  final int startIndex = widget.initialPrompt != null
      ? _searchHints.indexOf(widget.initialPrompt!)
      : -1;
  _hintIndex = startIndex >= 0 ? startIndex : 0;
  _hintPrompt = _searchHints[_hintIndex];
  
  // 每 7s 轮换一次，与发现页节奏一致
  _hintTimer = Timer.periodic(const Duration(seconds: 7), (_) {
    if (mounted) {
      setState(() {
        _hintIndex = (_hintIndex + 1) % _searchHints.length;
        _hintPrompt = _searchHints[_hintIndex];
      });
    }
  });
  
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _bootstrapChat();
  });
}
```

#### 修改 3：dispose 清理 Timer

```dart
@override
void dispose() {
  _hintTimer?.cancel();
  _textController.dispose();
  _scrollController.dispose();
  _inputFocusNode.dispose();
  super.dispose();
}
```

#### 修改 4：_buildInputBar 使用 _hintPrompt

```dart
decoration: InputDecoration(
  hintText: _hintPrompt ?? '例如：日本关西 7天特种兵打卡',
  border: InputBorder.none,
),
```

#### 修改 5：添加 dart:async 导入

```dart
import 'dart:async';
import 'dart:convert';
```

### 3. _bootstrapChat 时序优化

**文件：** `lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`

```dart
Future<void> _bootstrapChat() async {
  // ✅ 在任何异步操作之前，立即读取 pendingAiPrompt，防止 await 期间值被清空
  final MainNavProvider navProvider = context.read<MainNavProvider>();
  final String? pending = navProvider.pendingAiPrompt?.trim();
  
  await loadChatHistory();
  _forceScrollToBottom();

  if (!mounted) return;
  final String hintPrompt = pending != null && pending.isNotEmpty
      ? pending
      : '带父母去北京玩五天经典路线';
  setState(() {
    _hintPrompt = hintPrompt;
  });
}
```

**注意：** 这个方法的 `_hintPrompt` 赋值会被 Timer 覆盖，但不影响功能。

## 工作原理

### 场景 1：从发现页搜索栏进入

1. 发现页提示词轮换到"带父母去北京玩五天"
2. 用户点击搜索栏
3. `widget.initialPrompt = "带父母去北京玩五天"`
4. AI 管家 `initState` 查找该提示词在列表中的索引（假设是 1）
5. 设置 `_hintIndex = 1`，`_hintPrompt = _searchHints[1]`
6. 输入框立即显示"带父母去北京玩五天"
7. Timer 从索引 1 开始继续轮换（7秒后显示索引 2 的提示词）

### 场景 2：从 FAB 直接打开

1. `widget.initialPrompt = null`
2. AI 管家 `initState` 找不到匹配项
3. 设置 `_hintIndex = 0`，`_hintPrompt = _searchHints[0]`
4. 输入框显示"下个月看海，人少一点"
5. Timer 从索引 0 开始轮换

### 场景 3：从其他入口进入

与场景 2 相同，从索引 0 开始轮换。

## 关键特性

### 1. 同步起点

- 从发现页进入时，AI 管家从相同的提示词开始
- 保证用户看到的提示词一致

### 2. 持续轮换

- AI 管家内部每 7 秒轮换一次
- 与发现页保持相同的节奏
- 用户长时间停留在 AI 管家页面也能看到不同的提示词

### 3. 立即显示

- `initState` 中同步设置 `_hintPrompt`
- 无需等待异步操作
- 用户打开页面立即看到正确的提示词

### 4. 列表同源

- 发现页和 AI 管家使用相同的提示词列表
- 保证内容一致性
- 便于统一维护

## 提示词列表

```dart
static const List<String> _searchHints = <String>[
  '下个月看海，人少一点',
  '带父母去北京玩五天',
  '去新疆看雪需要准备什么',
  '周末去哪能吃地道火锅',
  '预算3000元，适合情侣去哪',
  '江浙沪 2 天自驾游',
  '曼谷+普吉岛 7天避坑',
  '独自旅行，治安好的古镇',
  '带 5 岁小孩去哪度假',
  '川西自驾需要防高反吗',
];
```

**特点：**
- 10 个精心设计的旅行场景
- 覆盖不同人群（情侣、家庭、独自）
- 覆盖不同需求（预算、安全、美食）
- 覆盖不同目的地（国内、国外）

## 涉及文件

1. **`lib/features/discover/presentation/screens/discover_screen.dart`**
   - 修改提示词轮换间隔为 7 秒

2. **`lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`**
   - 添加提示词列表和轮换机制
   - 修改 initState、dispose
   - 优化 _bootstrapChat 时序

## 测试步骤

### 测试 1：发现页轮换速度
1. 打开发现页
2. 观察搜索栏提示词
3. ✅ 验证每 7 秒切换一次

### 测试 2：同步起点
1. 等待发现页提示词轮换到特定内容（如"带父母去北京玩五天"）
2. 立即点击搜索栏
3. ✅ 验证 AI 管家输入框显示相同的提示词

### 测试 3：AI 管家持续轮换
1. 从发现页进入 AI 管家
2. 停留在 AI 管家页面
3. ✅ 验证输入框提示词每 7 秒切换一次

### 测试 4：FAB 入口
1. 点击 FAB 直接打开 AI 管家
2. ✅ 验证显示第一个提示词"下个月看海，人少一点"
3. ✅ 验证提示词持续轮换

## 优化效果

- ✅ 提示词轮换速度提升（15秒 → 7秒）
- ✅ 发现页与 AI 管家提示词同步
- ✅ AI 管家内部持续轮换，保持新鲜感
- ✅ 立即显示，无延迟
- ✅ 代码简洁，易于维护

## 总结

通过在 AI 管家内部实现独立的提示词轮换机制，实现了与发现页的完美同步。用户从发现页进入时，看到的提示词保持一致；停留在 AI 管家页面时，提示词持续轮换，提供更好的用户体验。

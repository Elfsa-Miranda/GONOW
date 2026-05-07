# 🤖 AI 管家功能文件清单

## 📁 核心文件结构

### 1. AI 管家主界面
```
lib/features/ai_custom/presentation/screens/ai_custom_screen.dart
```
**功能：** AI 智能管家的主要交互界面
- 聊天对话界面
- 消息历史管理
- 行程生成与导入
- DeepSeek API 调用

**关键类：**
- `AiCustomScreen` - 主界面 Widget
- `ChatMessage` - 消息数据模型
- `_AiCustomScreenState` - 状态管理

**核心功能：**
- ✅ 对话历史加载与显示
- ✅ 消息发送与接收
- ✅ 行程 JSON 解析
- ✅ 一键导入行程
- ✅ 清空聊天记录
- ✅ 自动滚动到底部
- ✅ 加载状态显示
- ✅ 错误处理

---

### 2. AI 配置文件
```
lib/core/constants/ai_config.dart
```
**功能：** AI 服务配置（DeepSeek API）

**配置项：**
```dart
class AiConfig {
  static const String deepseekApiKey = 'sk-xxx...';  // API 密钥
  static const String deepseekEndpoint = 'https://api.deepseek.com/chat/completions';  // API 端点
  static const String deepseekModel = 'deepseek-chat';  // 模型名称
}
```

---

### 3. 主导航集成
```
lib/features/main_nav/presentation/screens/main_screen.dart
```
**功能：** 从主界面调用 AI 管家

**关键方法：**
- `_showAiCustomSheet()` - 显示 AI 管家底部弹窗
- 处理 FAB 点击事件
- 处理自动发送逻辑

**集成点：**
```dart
// 监听 MainNavProvider 的 openAiRequestToken
if (provider.openAiRequestToken > 0) {
  _showAiCustomSheet();
}
```

---

### 4. 主导航状态管理
```
lib/features/main_nav/data/main_nav_provider.dart
```
**功能：** 管理 AI 管家的全局状态

**关键属性：**
- `isAiPlanning` - AI 是否正在生成行程
- `pendingAiPrompt` - 待发送的提示词
- `pendingAiSource` - 调用来源
- `shouldAutoSendAi` - 是否自动发送
- `openAiRequestToken` - 打开 AI 管家的令牌

**关键方法：**
- `requestOpenAiSheet()` - 请求打开 AI 管家
- `setAiPlanning()` - 设置 AI 规划状态
- `clearPendingAiPrompt()` - 清除待发送提示词

---

### 5. 行程数据管理
```
lib/features/itinerary/data/itinerary_provider.dart
```
**功能：** 管理行程数据，与 AI 管家交互

**关键方法：**
- `saveItinerary()` - 保存 AI 生成的行程
- `fetchActiveItinerary()` - 获取当前行程
- AI 管家会读取当前行程用于修改

**数据模型：**
- `ItineraryModel` - 行程数据模型
- `DayPlan` - 每日计划
- `Activity` - 活动/景点

---

## 🔄 AI 管家调用流程

### 流程 1：从 FAB 调用

```
用户点击 FAB
    ↓
MainNavProvider.requestOpenAiSheet()
    ├─ 设置 pendingAiPrompt（示例文案）
    ├─ 设置 shouldAutoSendAi = false（FAB 不自动发送）
    └─ openAiRequestToken++
    ↓
MainScreen 监听到 openAiRequestToken 变化
    ↓
MainScreen._showAiCustomSheet()
    ├─ 读取 pendingAiPrompt
    ├─ 读取 shouldAutoSendAi
    └─ 清除 provider 状态
    ↓
显示 AiCustomScreen
    ├─ 加载历史记录
    ├─ 显示提示词
    └─ 等待用户手动发送
```

### 流程 2：从其他页面调用（自动发送）

```
其他页面（如行程详情）
    ↓
MainNavProvider.requestOpenAiSheet()
    ├─ 设置 pendingAiPrompt（具体需求）
    ├─ 设置 shouldAutoSendAi = true
    └─ openAiRequestToken++
    ↓
MainScreen._showAiCustomSheet()
    ├─ autoSend = true
    └─ initialPrompt = pendingAiPrompt
    ↓
AiCustomScreen 自动发送
    └─ widget.autoSend && widget.initialPrompt 非空
```

---

## 🎯 AI 管家核心功能详解

### 1. 对话历史管理

**数据库表：** `ai_chat_messages`

**字段：**
- `id` - 消息 ID
- `user_id` - 用户 ID
- `role` - 角色（user/ai/system）
- `content` - 消息内容
- `itinerary_data` - 行程 JSON（可选）
- `created_at` - 创建时间

**功能：**
- ✅ 加载历史记录（按时间升序）
- ✅ 保存新消息到云端
- ✅ 自动清理旧记录（保留最近 50 条）
- ✅ 清空所有历史

**代码位置：**
```dart
// 加载历史
Future<void> loadChatHistory() async { ... }

// 清理旧记录
Future<void> _pruneOldMessages() async { ... }

// 清空历史
Future<void> _clearChatHistory() async { ... }
```

---

### 2. 消息发送与接收

**发送流程：**
```
用户输入 → _sendMessage()
    ↓
1. 获取用户输入（或使用 initialPrompt/hintPrompt）
2. 设置 isAiPlanning = true
3. 添加用户消息到 _messages
4. 保存用户消息到数据库
5. 构建 API 请求
    ├─ 读取历史消息（最近 8 条）
    ├─ 读取当前行程（如果有）
    └─ 构建 system prompt
6. 调用 DeepSeek API
7. 解析响应
    ├─ 提取文本内容
    └─ 提取 JSON 行程数据
8. 添加 AI 消息到 _messages
9. 保存 AI 消息到数据库
10. 设置 isAiPlanning = false
11. 滚动到底部
```

**代码位置：**
```dart
Future<void> _sendMessage() async { ... }
```

---

### 3. System Prompt 构建

**核心方法：**
```dart
String _buildSystemPrompt(String? currentPlanJson, String source) { ... }
```

**Prompt 结构：**
1. **基础 Prompt**
   - 角色定位：温暖、专业的智能旅游管家
   - 输出格式：文本 + JSON
   - 行程规划规则
   - 时间安排约束

2. **场景感知**
   - 当前调用来源（source）
   - 是否有现有行程（currentPlanJson）

3. **行为指令**
   - 微调修改：基于现有行程修改
   - 变卦处理：完全改变目的地
   - 闲聊防呆：不需要改行程时不输出 JSON

**关键规则：**
- ✅ 空间聚类优先（避免折返跑）
- ✅ 闭馆时间约束（早关门早安排）
- ✅ 时间轴推演（精确计算通勤时间）
- ✅ 合理游玩时长（不能全部写 1 小时）

---

### 4. 行程 JSON 解析

**JSON 格式：**
```json
{
  "title": "行程标题",
  "estimated_budget_per_person": "3500元",
  "days": [
    {
      "dayTitle": "Day 1 标题",
      "activities": [
        {
          "time": "10:00",
          "title": "景点名",
          "type": "scenic",
          "openTime": "09:00-18:00 开放",
          "recommended_duration": "2.5小时",
          "tag": "历史人文 · 必打卡",
          "strategy": "游玩攻略",
          "lat": 39.9,
          "lng": 116.4
        }
      ]
    }
  ],
  "pre_trip_prep": {
    "bookings": [],
    "luggage": [],
    "pitfalls": []
  }
}
```

**解析流程：**
```dart
// 1. 检测 ```json 代码块
if (aiText.contains('```json')) {
  // 2. 分离文本和 JSON
  final parts = aiText.split('```json');
  chatText = parts[0].trim();
  jsonString = parts[1].split('```')[0].trim();
  
  // 3. 解析 JSON
  final parsed = jsonDecode(jsonString);
  parsedItinerary = Map<String, dynamic>.from(parsed);
}
```

---

### 5. 行程导入

**导入流程：**
```
用户点击"一键导入"
    ↓
_importPlan(itineraryData)
    ↓
1. 显示日期选择器
2. 用户选择出发日期
3. 解析 JSON 为 ItineraryModel
4. 计算结束日期
5. 保存到 ItineraryProvider
6. 关闭 AI 管家
7. 跳转到行程页面
```

**代码位置：**
```dart
Future<void> _importPlan(Map<String, dynamic> itineraryData) async { ... }
```

---

### 6. UI 组件

**主要组件：**
- `_buildHeader()` - 顶部标题栏
- `_buildUserBubble()` - 用户消息气泡
- `_buildAiBubble()` - AI 消息气泡
- `_buildLoadingBubble()` - 加载中气泡
- `_buildInputBar()` - 底部输入栏
- `_buildExpandButton()` - 展开历史按钮
- `_buildAiAvatar()` - AI 头像
- `_buildAiMarkdown()` - Markdown 渲染

**样式特点：**
- 用户消息：靛蓝色，右对齐
- AI 消息：白色卡片，左对齐
- 支持 Markdown 格式
- 支持行程导入按钮

---

## 🔧 其他使用 AI 的功能

### 1. 行程详情页 AI 对话
```
lib/features/itinerary/presentation/screens/itinerary_screen.dart
```
**功能：**
- 在行程详情页内嵌 AI 对话
- 修改当前行程
- 添加新景点

---

### 2. 日记 AI 生成
```
lib/features/diary/data/diary_provider.dart
lib/features/diary/presentation/screens/diary_detail_screen.dart
```
**功能：**
- AI 生成日记标题
- AI 生成日记内容
- AI 优化日记文案

---

## 📊 数据流图

```
┌─────────────────────────────────────────────────────────────┐
│                        用户交互层                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  FAB 按钮    │  │  行程详情页  │  │  其他入口    │      │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘      │
│         │                  │                  │              │
└─────────┼──────────────────┼──────────────────┼──────────────┘
          │                  │                  │
          └──────────────────┼──────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│                      状态管理层                               │
│                  MainNavProvider                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  • isAiPlanning                                       │  │
│  │  • pendingAiPrompt                                    │  │
│  │  • shouldAutoSendAi                                   │  │
│  │  • openAiRequestToken                                 │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                             ↓
┌─────────────────────────────────────────────────────────────┐
│                        UI 层                                 │
│                   AiCustomScreen                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  • 加载历史记录                                       │  │
│  │  • 显示对话界面                                       │  │
│  │  • 处理用户输入                                       │  │
│  │  • 调用 API                                           │  │
│  │  • 解析响应                                           │  │
│  │  • 导入行程                                           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
          │                                    │
          ↓                                    ↓
┌──────────────────────┐          ┌──────────────────────┐
│   DeepSeek API       │          │   Supabase 数据库    │
│  ┌────────────────┐  │          │  ┌────────────────┐  │
│  │ chat/completions│  │          │  │ ai_chat_messages│  │
│  └────────────────┘  │          │  └────────────────┘  │
└──────────────────────┘          └──────────────────────┘
          │                                    │
          └────────────────┬───────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│                      数据处理层                               │
│                 ItineraryProvider                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  • 保存行程                                           │  │
│  │  • 读取当前行程                                       │  │
│  │  • 提供给 AI 用于修改                                 │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 🎯 改进 AI 管家功能需要修改的文件

### 核心文件（必改）
1. **`lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`**
   - 主要 UI 和交互逻辑
   - 消息处理
   - API 调用

2. **`lib/core/constants/ai_config.dart`**
   - API 配置
   - 模型选择

### 状态管理（可能需要改）
3. **`lib/features/main_nav/data/main_nav_provider.dart`**
   - 全局状态管理
   - 调用逻辑

### 数据库（如果改数据结构）
4. **Supabase 数据库表 `ai_chat_messages`**
   - 消息存储结构
   - 字段定义

### 集成点（如果改调用方式）
5. **`lib/features/main_nav/presentation/screens/main_screen.dart`**
   - FAB 集成
   - 弹窗显示

---

## 💡 常见改进方向

### 1. 更换 AI 模型
**修改文件：** `lib/core/constants/ai_config.dart`
```dart
static const String deepseekModel = 'deepseek-chat';  // 改为其他模型
```

### 2. 优化 System Prompt
**修改文件：** `lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`
**方法：** `_buildSystemPrompt()`

### 3. 添加新功能按钮
**修改文件：** `lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`
**位置：** `_buildAiBubble()` 或 `_buildInputBar()`

### 4. 修改 UI 样式
**修改文件：** `lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`
**组件：** 各个 `_build*()` 方法

### 5. 添加新的调用入口
**修改文件：**
- 调用页面（添加调用代码）
- `lib/features/main_nav/data/main_nav_provider.dart`（如果需要）

### 6. 修改历史记录逻辑
**修改文件：** `lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`
**方法：**
- `loadChatHistory()`
- `_pruneOldMessages()`
- `_clearChatHistory()`

### 7. 修改行程导入逻辑
**修改文件：**
- `lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`（`_importPlan()`）
- `lib/features/itinerary/data/itinerary_provider.dart`（`saveItinerary()`）

---

## 🔍 调试技巧

### 1. 查看 API 请求
```dart
debugPrint('🚀 API Request: ${jsonEncode(requestBody)}');
```

### 2. 查看 API 响应
```dart
debugPrint('📥 API Response: ${response.body}');
```

### 3. 查看解析的 JSON
```dart
debugPrint('📊 Parsed Itinerary: ${jsonEncode(parsedItinerary)}');
```

### 4. 查看消息历史
```dart
debugPrint('💬 Messages: ${_messages.length}');
```

---

## ✅ 总结

**AI 管家核心文件：**
1. `ai_custom_screen.dart` - 主界面（1000+ 行）
2. `ai_config.dart` - 配置文件（10 行）
3. `main_nav_provider.dart` - 状态管理
4. `main_screen.dart` - 集成点
5. `itinerary_provider.dart` - 数据管理

**改进建议：**
- 大部分改进只需修改 `ai_custom_screen.dart`
- 配置修改在 `ai_config.dart`
- 新功能可能需要修改 Provider

**数据流：**
用户输入 → Provider → AiCustomScreen → DeepSeek API → 解析响应 → 保存数据库 → 更新 UI → 导入行程

---

**现在你可以开始改进 AI 管家功能了！** 🚀

# 注释保留功能说明

## 功能描述
从已有行程生成手账时，用户在行程页编辑的注释（note）会被完整保留并显示在手账的景点卡片中。

## 实现方式

### 1. System Prompt 更新
**文件**：`lib/features/diary/data/diary_provider.dart`  
**位置**：第 356-368 行

**修改内容**：
```dart
【极度重要】：
1. 必须完全保留原有的天数（days）、活动（activities）、标题（title）、时间（time）、注释（note）、照片（images）等所有字段。
2. 你的任务仅仅是根据【$style】风格，为每个 activities 补充大约60-100字的高质量游记description。
3. 如果原数据中已有 note 字段（用户的个人注释），必须原封不动保留，不要修改或删除。
4. 必须返回纯正的 JSON 字符串（可以用```json包裹），严禁输出废话！
```

**效果**：
- ✅ 明确告诉 AI 保留 `note` 字段
- ✅ 强调不要修改或删除用户注释
- ✅ 同时保留照片（images）等其他字段

### 2. 数据合并逻辑
**文件**：`lib/features/diary/presentation/widgets/diary_config_sheet.dart`  
**位置**：第 316-327 行

**工作原理**：
```dart
// 1. 从原始行程数据创建副本（包含所有字段：note、images 等）
final Map<String, dynamic> orgAct = Map<String, dynamic>.from(
  orgActs[a] as Map? ?? <String, dynamic>{},
);

// 2. 获取 AI 生成的数据
final Map<String, dynamic> aiAct = Map<String, dynamic>.from(
  aiActs[a] as Map? ?? <String, dynamic>{},
);

// 3. 只更新 description 字段，其他字段（包括 note）保持不变
orgAct['description'] = aiAct['description'] ?? orgAct['description'];

// 4. 保存更新后的活动数据
orgActs[a] = orgAct;
```

**关键点**：
- ✅ 从 `orgAct`（原始数据）开始，包含所有原始字段
- ✅ 只覆盖 `description` 字段
- ✅ `note`、`images`、`time` 等字段自动保留

## 数据流

### 行程页 → 手账页

```
行程数据结构：
{
  "days": [
    {
      "activities": [
        {
          "title": "景点名称",
          "time": "10:00",
          "note": "用户编辑的注释",        ← 用户在行程页添加
          "description": "",
          "images": ["photo1.jpg", "photo2.jpg"]
        }
      ]
    }
  ]
}

↓ 生成手账

手账数据结构：
{
  "days": [
    {
      "activities": [
        {
          "title": "景点名称",              ← 保留
          "time": "10:00",                  ← 保留
          "note": "用户编辑的注释",         ← 保留（原封不动）
          "description": "AI生成的文案",    ← AI 生成
          "images": ["photo1.jpg", ...]     ← 保留
        }
      ]
    }
  ]
}
```

## 注释字段说明

### 字段名称
- **主字段**：`note`
- **备用字段**：`description`（在行程页中，note 和 description 同时保存）

### 在行程页的使用
```dart
// 用户编辑注释时
act['description'] = note;
act['note'] = note;
```

### 在手账页的显示
手账详情页会读取 `note` 字段并显示在景点卡片中。

## 测试场景

### 场景1：有注释的景点
1. 在行程页为某个景点添加注释："这里的风景超美，记得带相机"
2. 从该行程生成手账
3. 打开手账详情页
4. **预期结果**：景点卡片显示注释"这里的风景超美，记得带相机"

### 场景2：没有注释的景点
1. 在行程页创建景点，不添加注释
2. 从该行程生成手账
3. 打开手账详情页
4. **预期结果**：景点卡片不显示注释，只显示 AI 生成的 description

### 场景3：混合场景
1. 行程中有 3 个景点：
   - 景点 A：有注释 + 有照片
   - 景点 B：无注释 + 有照片
   - 景点 C：有注释 + 无照片
2. 从该行程生成手账
3. **预期结果**：
   - 景点 A：显示注释 + 照片 + AI 文案
   - 景点 B：显示照片 + AI 文案（无注释）
   - 景点 C：显示注释 + AI 文案（无照片）

## 技术细节

### 为什么注释会被保留？

1. **完整复制原始数据**：
   ```dart
   finalDiaryData = jsonDecode(jsonEncode(existingItinerary.planData))
   ```
   这会复制所有字段，包括 `note`

2. **选择性更新**：
   ```dart
   orgAct['description'] = aiAct['description']
   ```
   只更新 `description`，不触碰其他字段

3. **AI 被明确告知**：
   System prompt 中明确要求保留 `note` 字段

### 与 description 的区别

| 字段 | 来源 | 用途 | 是否可编辑 |
|------|------|------|-----------|
| `note` | 用户手动输入 | 个人注释、提醒 | ✅ 用户可编辑 |
| `description` | AI 生成 | 游记文案、景点描述 | ✅ AI 生成后可编辑 |

在手账页，两者都会显示，但位置和样式可能不同。

## 相关文件

- `lib/features/diary/data/diary_provider.dart` - AI 生成逻辑和 system prompt
- `lib/features/diary/presentation/widgets/diary_config_sheet.dart` - 数据合并逻辑
- `lib/features/itinerary/presentation/screens/itinerary_screen.dart` - 行程页注释编辑

## 注意事项

1. **向后兼容**：已生成的手账不受影响
2. **数据完整性**：除了 `note`，所有其他字段（`images`、`time`、`title` 等）也都会被保留
3. **AI 行为**：虽然 system prompt 要求保留 `note`，但数据合并逻辑确保即使 AI 不遵守，`note` 也不会丢失

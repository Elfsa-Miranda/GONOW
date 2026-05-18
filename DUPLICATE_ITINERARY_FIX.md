# AI 管家导入行程重复 Bug 修复

## 问题诊断

**症状：** 从 AI 管家导入行程后，发现页会出现两个完全相同的行程。

**根本原因：**

在 `saveItinerary` 方法中，当云端返回新的 UUID 时，会出现重复添加：

```dart
Future<void> saveItinerary(ItineraryModel model) async {
  _upsertMyItinerary(model);  // ❌ 第一次添加：使用本地临时 ID (local_xxx)
  
  final ItineraryModel? savedModel = await saveToSupabase(model);
  if (savedModel != null && savedModel.remoteId != model.remoteId) {
    _upsertMyItinerary(savedModel);  // ❌ 第二次添加：使用云端 UUID
  }
}
```

**问题分析：**

1. AI 管家生成的行程使用本地临时 ID（如 `local_xxx`）
2. 第一次 `_upsertMyItinerary(model)` 将行程添加到列表（ID = `local_xxx`）
3. `saveToSupabase` 返回带有数据库生成 UUID 的新 model（ID = `uuid-yyy`）
4. `_upsertMyItinerary` 通过 `id` 字段查找：
   ```dart
   final int idx = _myItineraries.indexWhere((e) => e.id == mid);
   ```
5. 因为 `local_xxx != uuid-yyy`，找不到匹配项
6. 执行 `_myItineraries.add(savedModel)`，导致列表中同时存在两条记录

## 修复方案（已应用）

**核心思路：** 在云端分配新 UUID 后，先删除旧的本地占位条目，再添加新条目。

**修改文件：** `lib/features/itinerary/data/itinerary_provider.dart`

**修改位置：** `saveItinerary` 方法（约第 1054-1080 行）

**修改内容：**

```dart
Future<void> saveItinerary(ItineraryModel model) async {
  _currentItinerary = model;
  _activeItinerary = model;
  _upsertMyItinerary(model);
  notifyListeners();
  try {
    final ItineraryModel? savedModel = await saveToSupabase(model);
    if (savedModel != null && savedModel.remoteId != model.remoteId) {
      // ✅ 关键修复：云端分配了新 UUID，旧的 local_xxx 条目必须先移除
      // 否则 _upsertMyItinerary(savedModel) 用 uuid-yyy 找不到 local_xxx，会再 add 一条
      if (model.remoteId == null || !_isValidUuid(model.remoteId!)) {
        // 旧条目是本地占位 ID，直接按旧 id 删掉
        _myItineraries.removeWhere((ItineraryModel e) => e.id == model.id);
      }
      
      _currentItinerary = savedModel;
      _activeItinerary = savedModel;
      _upsertMyItinerary(savedModel);  // 此时列表里没有旧条目，安全 add
      await _saveToLocal(savedModel);
      await _persistMyItinerariesList();
      notifyListeners();
    } else {
      await _saveToLocal(model);
      await _persistMyItinerariesList();
    }
  } catch (e) {
    debugPrint('⚠️ 云端保存失败，降级到本地: $e');
    try {
      await _saveToLocal(model);
      await _persistMyItinerariesList();
    } catch (_) {}
  }
}
```

**新增代码（仅 3 行）：**

```dart
if (model.remoteId == null || !_isValidUuid(model.remoteId!)) {
  _myItineraries.removeWhere((ItineraryModel e) => e.id == model.id);
}
```

## 修复逻辑

### 执行流程

1. **初始添加**：`_upsertMyItinerary(model)` - 添加本地临时 ID 的行程
2. **云端保存**：`saveToSupabase(model)` - 返回带 UUID 的新 model
3. **检查 ID 变化**：`if (savedModel.remoteId != model.remoteId)`
4. **✅ 删除旧条目**：如果旧 model 是本地占位 ID，删除它
5. **添加新条目**：`_upsertMyItinerary(savedModel)` - 添加云端 UUID 的行程

### 安全保证

1. **精准删除**：只删除本地占位 ID（`local_xxx`），不影响正常的 UUID 行程
2. **条件判断**：`model.remoteId == null || !_isValidUuid(model.remoteId!)`
3. **不影响 upsert**：正常的更新场景（UUID → UUID）不会触发删除
4. **不影响回读**：`loadMyItineraries()` 的云端回读走独立的 `mergedMap` 合并逻辑

### 场景覆盖

| 场景 | 旧 ID | 新 ID | 是否删除 | 结果 |
|------|-------|-------|----------|------|
| AI 管家导入 | `local_xxx` | `uuid-yyy` | ✅ 是 | 只保留 UUID 版本 |
| 编辑已有行程 | `uuid-aaa` | `uuid-aaa` | ❌ 否 | 正常 upsert 更新 |
| 本地行程首次上云 | `local_xxx` | `uuid-yyy` | ✅ 是 | 只保留 UUID 版本 |
| 云端保存失败 | `local_xxx` | `null` | ❌ 否 | 保留本地版本 |

## 测试步骤

1. 清空现有行程数据（或使用新账号）
2. 打开 AI 管家
3. 输入行程需求（如："去北京玩 3 天"）
4. 等待 AI 生成行程
5. 点击"一键导入至我的行程"
6. 切换到"发现"页面
7. ✅ 验证只有一个行程，没有重复
8. 编辑该行程，保存
9. ✅ 验证仍然只有一个行程

## 涉及文件

- **`lib/features/itinerary/data/itinerary_provider.dart`** - 唯一修改文件

## 修复效果

- ✅ AI 管家导入行程不再重复
- ✅ 发现页只显示一个行程
- ✅ 行程数据正确保存到云端
- ✅ 不影响其他行程创建和编辑功能
- ✅ 不影响云端回读和合并逻辑
- ✅ 代码改动最小（仅 3 行），风险可控

## 技术要点

### 为什么不在第一次就不添加？

保持原有的乐观更新策略：
- 立即添加到列表，UI 即时响应
- 云端保存在后台进行
- 用户体验更好（不需要等待网络）

### 为什么不改 _upsertMyItinerary？

- `_upsertMyItinerary` 是通用方法，被多处调用
- 修改它的匹配逻辑可能影响其他场景
- 在 `saveItinerary` 中精准处理更安全

### ID 类型判断

```dart
if (model.remoteId == null || !_isValidUuid(model.remoteId!))
```

- `remoteId == null`：从未上云的本地行程
- `!_isValidUuid(remoteId)`：使用临时 ID（如 `local_xxx`）
- 只有这两种情况才需要删除旧条目

## 总结

这是一个精准的外科手术式修复：
- 只在必要时删除旧条目
- 不改变原有的乐观更新策略
- 不影响其他功能
- 代码改动最小

修复完成！✅


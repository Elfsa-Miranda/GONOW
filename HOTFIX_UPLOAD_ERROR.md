# 紧急修复：上传封面失败问题

## 问题描述
点击行程卡片的相机图标上传封面时，出现错误：
```
PostgreException(message: invalid input syntax for type uuid: "local_1777996800000_9043578", code: 22P02)
```

## 根本原因
在之前的修复中，`uploadCustomCover` 方法尝试更新数据库中的 `cover_image_url` 字段：

```dart
await _supabase
    .from(_tableName)
    .update(<String, dynamic>{'cover_image_url': publicUrl})
    .eq('id', itineraryId);
```

但是，如果行程是**本地创建但未同步到服务器**的行程，它的 ID 格式是 `local_1777996800000_9043578`（以 `local_` 开头），而数据库的 `id` 字段是 UUID 类型，无法接受这种格式，导致 PostgreSQL 抛出异常。

## 修复方案

添加本地 ID 检查，只有已同步到服务器的行程才更新数据库：

```dart
// 检查是否为本地 ID（以 local_ 开头的是本地未同步的行程）
final bool isLocalId = itineraryId.startsWith('local_');

// 只有非本地 ID 才更新数据库
if (!isLocalId) {
  await _supabase
      .from(_tableName)
      .update(<String, dynamic>{'cover_image_url': publicUrl})
      .eq('id', itineraryId);
}

// 无论是否为本地 ID，都更新本地缓存
final int index = _myItineraries.indexWhere((t) => t.id == itineraryId);
if (index != -1) {
  _myItineraries[index] = _myItineraries[index].copyWith(
    coverImageUrl: publicUrl,
  );
  notifyListeners();
}
```

## 修复效果

- ✅ **已同步的行程**：上传封面后，同时更新数据库和本地缓存
- ✅ **本地行程**：上传封面后，只更新本地缓存，不尝试更新数据库
- ✅ **错误处理**：失败时正确抛出异常并显示错误提示
- ✅ **UI 刷新**：上传成功后立即显示新封面

## 测试场景

### 场景1：已同步的行程
1. 创建一个行程并等待同步到服务器（ID 为 UUID 格式）
2. 点击相机图标上传封面
3. **预期结果**：上传成功，数据库和本地都更新，立即显示新封面

### 场景2：本地行程
1. 创建一个新行程（ID 为 `local_` 开头）
2. 点击相机图标上传封面
3. **预期结果**：上传成功，只更新本地缓存，立即显示新封面
4. 当行程同步到服务器后，封面 URL 也会一起同步

### 场景3：上传失败
1. 断开网络连接
2. 尝试上传封面
3. **预期结果**：显示错误提示，保持原有封面

## 技术细节

### 本地 ID vs 服务器 ID

**本地 ID 格式**：
```
local_1777996800000_9043578
```
- 前缀：`local_`
- 时间戳：`1777996800000`（毫秒）
- 随机数：`9043578`

**服务器 ID 格式**（UUID v4）：
```
550e8400-e29b-41d4-a716-446655440000
```

### 为什么会有本地 ID？

当用户创建行程时：
1. 立即生成本地 ID，让用户可以马上使用
2. 在后台异步同步到服务器
3. 同步成功后，用服务器返回的 UUID 替换本地 ID

这样可以提供更好的用户体验（不需要等待网络请求）。

### 同步逻辑

当本地行程同步到服务器时：
1. 服务器生成新的 UUID
2. 返回给客户端
3. 客户端用新 ID 替换本地 ID
4. 所有相关数据（包括 `coverImageUrl`）一起同步

## 相关文件
- `lib/features/itinerary/data/itinerary_provider.dart` - 修复了 `uploadCustomCover` 方法

## 注意事项
- 本地行程上传的封面会保存到 Storage，但不会立即写入数据库
- 当行程同步到服务器时，封面 URL 会一起同步
- 这不会导致数据丢失，只是延迟了数据库写入的时机

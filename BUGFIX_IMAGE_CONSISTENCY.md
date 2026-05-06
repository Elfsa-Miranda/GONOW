# 图片一致性问题修复

## 问题描述
在"生成配置舱"的行程列表中，行程显示的图片与发现页的行程卡片不一致。

## 根本原因
发现页和生成配置舱使用了不同的逻辑来获取默认图片：

**发现页** (`discover_screen.dart`)：
```dart
TravelImageHelper.getImageUrlForDestination(
  itinerary.destinationCity.isNotEmpty 
    ? itinerary.destinationCity 
    : itinerary.title
)
```

**生成配置舱** (`diary_config_sheet.dart` - 修复前)：
```dart
TravelImageHelper.getImageUrlForDestination(trip.title)
```

这导致：
- 如果行程有 `destinationCity` 字段，发现页会使用它来匹配默认图片
- 但生成配置舱直接使用 `title`，可能导致不同的哈希值和不同的图片

## 修复方案

### 修复1：统一行程列表的图片逻辑
**文件**：`lib/features/diary/presentation/widgets/diary_config_sheet.dart`

**修改内容**：
```dart
// 修改前
final String imageUrl = (trip.coverImageUrl ?? '').trim().isNotEmpty
  ? trip.coverImageUrl!.trim()
  : TravelImageHelper.getImageUrlForDestination(trip.title);

// 修改后
final String imageUrl = (trip.coverImageUrl ?? '').trim().isNotEmpty
  ? trip.coverImageUrl!.trim()
  : TravelImageHelper.getImageUrlForDestination(
      trip.destinationCity.isNotEmpty 
        ? trip.destinationCity 
        : trip.title,
    );
```

### 修复2：统一手账生成的图片逻辑
**文件**：`lib/features/diary/presentation/widgets/diary_config_sheet.dart`

**修改内容**：
```dart
// 修改前
final String fromFallback = TravelImageHelper.getImageUrlForDestination(
  existingItinerary.title,
);

// 修改后
final String fromFallback = TravelImageHelper.getImageUrlForDestination(
  existingItinerary.destinationCity.isNotEmpty
    ? existingItinerary.destinationCity
    : existingItinerary.title,
);
```

### 修复3：添加调试日志
添加了调试日志来追踪图片 URL 的生成：
```dart
debugPrint('行程 "${trip.title}" 的图片 URL: $imageUrl');
```

## 统一后的逻辑

现在所有地方都使用相同的优先级：

1. **优先使用自定义封面**：如果 `coverImageUrl` 不为空，使用它
2. **其次使用目的地城市**：如果 `destinationCity` 不为空，用它匹配默认图片
3. **最后使用标题**：如果 `destinationCity` 为空，使用 `title` 匹配默认图片

这确保了：
- ✅ 发现页的行程卡片
- ✅ 生成配置舱的行程列表
- ✅ 生成的手账封面

三者使用完全相同的逻辑来获取默认图片。

## 测试建议

### 测试场景1：有 destinationCity 的行程
1. 创建一个行程，设置 `destinationCity` 为"北京"
2. 不上传自定义封面
3. 在发现页查看该行程卡片
4. 在生成配置舱查看该行程
5. **预期结果**：两处显示相同的北京默认图片

### 测试场景2：没有 destinationCity 的行程
1. 创建一个行程，`destinationCity` 为空，标题为"梦回仙境·老君山四日深度游"
2. 不上传自定义封面
3. 在发现页查看该行程卡片
4. 在生成配置舱查看该行程
5. **预期结果**：两处显示相同的默认图片（基于标题哈希）

### 测试场景3：有自定义封面的行程
1. 创建一个行程并上传自定义封面
2. 在发现页查看该行程卡片
3. 在生成配置舱查看该行程
4. **预期结果**：两处都显示自定义封面

### 测试场景4：从行程生成手账
1. 选择一个没有自定义封面的行程
2. 生成手账
3. **预期结果**：手账封面与行程卡片显示相同的默认图片

## 可能的遗留问题

如果修复后仍然看到不一致，可能是以下原因：

1. **缓存问题**：
   - `CachedNetworkImage` 可能缓存了旧的图片
   - 解决方案：清除应用缓存或重新安装应用

2. **数据问题**：
   - 某些行程的 `coverImageUrl` 字段可能包含无效的 URL
   - 解决方案：检查调试日志，查看实际的图片 URL

3. **网络问题**：
   - Unsplash 图片可能加载失败
   - 解决方案：检查网络连接，或者更换图片源

## 调试方法

运行应用后，查看控制台输出：
```
行程 "梦回仙境·老君山四日深度游" 的图片 URL: https://...
行程 "瓷都匠心力·景德镇深度3日游" 的图片 URL: https://...
```

如果两个行程的 URL 不同，说明它们的 `destinationCity` 或 `title` 不同。
如果 URL 相同但显示不同，可能是缓存或网络问题。

## 相关文件
- `lib/features/diary/presentation/widgets/diary_config_sheet.dart` - 生成配置舱
- `lib/features/discover/presentation/screens/discover_screen.dart` - 发现页
- `lib/core/utils/travel_image_helper.dart` - 默认图片工具类

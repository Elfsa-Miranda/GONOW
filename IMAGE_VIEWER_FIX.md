# 图片查看器优化

## 问题描述
手账界面点击图片后会强制撑满屏幕，导致图片被裁剪且不美观。用户希望图片能够自然显示，在确保图片完整性的基础上尽可能大。

## 修改内容

### 1. 全屏图片查看组件 (`lib/features/common/presentation/widgets/full_screen_photo_gallery.dart`)

**修改前：**
```dart
child: Center(
  child: widget.imageBuilder(pathOrUrl),
),
```

**修改后：**
```dart
child: Center(
  child: Container(
    constraints: BoxConstraints(
      maxWidth: MediaQuery.of(context).size.width,
      maxHeight: MediaQuery.of(context).size.height,
    ),
    child: widget.imageBuilder(pathOrUrl),
  ),
),
```

**说明：** 添加了 `Container` 和 `BoxConstraints` 来限制图片的最大宽度和高度，确保图片不会超出屏幕范围。

### 2. 日记详情界面 (`lib/features/diary/presentation/screens/diary_detail_screen.dart`)

**修改：** 创建了新的 `_buildFullScreenImage` 方法专门用于全屏查看，使用 `BoxFit.contain` 而不是 `BoxFit.cover`。

**新增方法：**
```dart
Widget _buildFullScreenImage(String pathOrUrl) {
  final String p = pathOrUrl.trim();
  if (p.startsWith('http://') || p.startsWith('https://')) {
    return CachedNetworkImage(
      imageUrl: p,
      fit: BoxFit.contain,  // 使用 contain 保持图片完整性
      errorWidget: (_, _, _) => const Icon(
        Icons.broken_image_outlined,
        color: Colors.white54,
        size: 56,
      ),
    );
  }
  // ... 其他图片类型的处理
}
```

**修改调用：**
```dart
void _showFullScreenGallery(
  BuildContext context,
  List<String> photos,
  int initialIndex,
) {
  showFullScreenPhotoGallery(
    context,
    photos,
    initialIndex,
    imageBuilder: _buildFullScreenImage,  // 使用新的方法
  );
}
```

**说明：** 
- 原来的 `_buildNodeImage` 方法使用 `BoxFit.cover` 用于缩略图显示
- 新的 `_buildFullScreenImage` 方法使用 `BoxFit.contain` 用于全屏查看
- 这样既保证了缩略图的美观（填充满容器），又保证了全屏查看时图片的完整性

### 3. 手账界面 (`lib/features/itinerary/presentation/screens/itinerary_screen.dart`)

**确认：** `_buildItineraryGalleryPageImage` 方法已经正确使用 `BoxFit.contain`，无需修改。

## 效果

修改后的图片查看器将：
1. **保持图片完整性**：使用 `BoxFit.contain` 确保整张图片都能显示
2. **尽可能大**：通过 `BoxConstraints` 限制最大尺寸为屏幕大小，图片会在不裁剪的前提下尽可能放大
3. **支持缩放**：`InteractiveViewer` 允许用户双指缩放查看细节
4. **居中显示**：图片在屏幕中央显示，美观自然

## 技术细节

- `BoxFit.contain`：缩放图片以完全显示在容器内，保持宽高比，可能会有留白
- `BoxFit.cover`：缩放图片以填充整个容器，保持宽高比，可能会裁剪图片
- `BoxConstraints`：限制子组件的最大/最小尺寸
- `InteractiveViewer`：提供平移和缩放功能

## 测试建议

1. 测试不同宽高比的图片（横图、竖图、方图）
2. 测试不同分辨率的图片
3. 测试双指缩放功能
4. 测试横向滑动切换图片

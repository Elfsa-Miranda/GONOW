# 🚀 双模式切换功能 - 快速上手指南

## 📖 5分钟快速理解

### 核心概念

**双模式系统** = 用户可以自由切换"行程规划"和"行程中"两种视图模式

```
📝 行程规划模式              🎒 行程中模式
├─ 准备清单                  ├─ 时间轴视图
├─ 避坑指南                  ├─ 标记到达
├─ 行李清单                  ├─ 添加照片
└─ 天数总览                  └─ 实时导航
```

---

## 🎯 使用方法

### 用户视角

1. **打开行程详情页**
   - 在地图下方看到一个灰色胶囊切换器

2. **切换模式**
   - 点击左侧"📝 行程规划"：查看准备清单和行程总览
   - 点击右侧"🎒 行程中"：进入旅行打卡模式

3. **享受不同体验**
   - 规划模式：专注于行前准备
   - 旅行模式：专注于行中打卡

---

## 💻 开发者视角

### 1. 获取当前模式

```dart
// 方法一：在 Widget 中使用 context.watch
final currentMode = context.watch<ItineraryProvider>().currentMode;

// 方法二：在 Consumer 中使用
Consumer<ItineraryProvider>(
  builder: (context, provider, _) {
    final currentMode = provider.currentMode;
    // ...
  },
)

// 方法三：在非 Widget 代码中使用
final provider = context.read<ItineraryProvider>();
final currentMode = provider.currentMode;
```

### 2. 切换模式

```dart
// 切换到规划模式
context.read<ItineraryProvider>().toggleTripMode(TripMode.planning);

// 切换到旅行模式
context.read<ItineraryProvider>().toggleTripMode(TripMode.traveling);
```

### 3. 根据模式显示不同UI

```dart
Widget build(BuildContext context) {
  final mode = context.watch<ItineraryProvider>().currentMode;
  
  return Column(
    children: [
      if (mode == TripMode.planning)
        Text('规划模式专属内容')
      else
        Text('旅行模式专属内容'),
    ],
  );
}
```

---

## 🔧 常见场景

### 场景1：添加模式专属按钮

```dart
Widget _buildActionButton(BuildContext context) {
  final mode = context.watch<ItineraryProvider>().currentMode;
  
  if (mode == TripMode.planning) {
    return ElevatedButton(
      onPressed: () => _exportItinerary(),
      child: Text('导出行程'),
    );
  } else {
    return ElevatedButton(
      onPressed: () => _shareLocation(),
      child: Text('分享位置'),
    );
  }
}
```

### 场景2：隐藏/显示功能

```dart
Widget _buildActivityCard(ActivityItem activity) {
  final mode = context.watch<ItineraryProvider>().currentMode;
  
  return Card(
    child: Column(
      children: [
        Text(activity.title),
        
        // 只在旅行模式显示"标记到达"按钮
        if (mode == TripMode.traveling)
          ElevatedButton(
            onPressed: () => _markArrived(activity.id),
            child: Text('📍 标记到达'),
          ),
        
        // 只在规划模式显示"编辑"按钮
        if (mode == TripMode.planning)
          IconButton(
            icon: Icon(Icons.edit),
            onPressed: () => _editActivity(activity),
          ),
      ],
    ),
  );
}
```

### 场景3：动态调整地图视角

```dart
void _updateMapCamera() {
  final mode = context.read<ItineraryProvider>().currentMode;
  
  if (mode == TripMode.planning) {
    // 规划模式：显示全局路线
    _fitAllMarkers();
  } else {
    // 旅行模式：聚焦当前景点
    _focusCurrentActivity();
  }
}
```

---

## 🎨 UI设计规范

### 颜色方案

```dart
// 规划模式
Color planningColor = Colors.indigo.shade800;      // 主色
Color planningBg = Colors.indigo.shade50;          // 背景色

// 旅行模式
Color travelingColor = Colors.green.shade700;      // 主色
Color travelingBg = Colors.green.shade50;          // 背景色
```

### 图标选择

```dart
// 规划模式图标
Icons.edit_calendar_outlined  // 编辑行程
Icons.checklist_outlined      // 准备清单
Icons.map_outlined            // 路线规划

// 旅行模式图标
Icons.location_on             // 当前位置
Icons.camera_alt              // 拍照打卡
Icons.check_circle            // 已到达
```

### 动画参数

```dart
// 推荐的动画时长
Duration shortAnimation = Duration(milliseconds: 200);   // 文字颜色
Duration mediumAnimation = Duration(milliseconds: 250);  // 滑块移动
Duration longAnimation = Duration(milliseconds: 300);    // 页面切换

// 推荐的动画曲线
Curve smoothCurve = Curves.easeOutCubic;    // 滑块移动
Curve quickCurve = Curves.easeOut;          // 文字变化
```

---

## ⚠️ 注意事项

### 1. 不要破坏现有功能

```dart
// ❌ 错误：直接修改照片管理逻辑
void uploadPhoto() {
  if (currentMode == TripMode.traveling) {
    // 修改了原有逻辑
  }
}

// ✅ 正确：只控制UI显示
Widget _buildPhotoButton() {
  if (currentMode == TripMode.traveling) {
    return PhotoUploadButton(); // 使用原有组件
  }
  return SizedBox.shrink();
}
```

### 2. 避免过度使用状态

```dart
// ❌ 错误：在每个小组件中都监听
class SmallWidget extends StatelessWidget {
  Widget build(BuildContext context) {
    final mode = context.watch<ItineraryProvider>().currentMode;
    return Text('...');
  }
}

// ✅ 正确：在父组件中监听，通过参数传递
class ParentWidget extends StatelessWidget {
  Widget build(BuildContext context) {
    final mode = context.watch<ItineraryProvider>().currentMode;
    return SmallWidget(mode: mode);
  }
}

class SmallWidget extends StatelessWidget {
  final TripMode mode;
  SmallWidget({required this.mode});
  
  Widget build(BuildContext context) {
    return Text('...');
  }
}
```

### 3. 保持向后兼容

```dart
// ✅ 正确：保留原有的 TripState 逻辑
final TripState autoState = provider.getTripState(); // 基于日期自动判断
final TripMode manualMode = provider.currentMode;    // 用户手动选择

// 在需要的地方使用 manualMode
// 在其他地方继续使用 autoState
```

---

## 🐛 调试技巧

### 1. 打印当前模式

```dart
void debugPrintMode() {
  final mode = context.read<ItineraryProvider>().currentMode;
  debugPrint('当前模式: ${mode.name}');
  debugPrint('是否为规划模式: ${mode == TripMode.planning}');
  debugPrint('是否为旅行模式: ${mode == TripMode.traveling}');
}
```

### 2. 监听模式变化

```dart
@override
void initState() {
  super.initState();
  
  final provider = context.read<ItineraryProvider>();
  provider.addListener(() {
    debugPrint('模式已切换: ${provider.currentMode.name}');
  });
}
```

### 3. 检查UI更新

```dart
Widget build(BuildContext context) {
  final mode = context.watch<ItineraryProvider>().currentMode;
  
  debugPrint('UI重建: mode=$mode');
  
  return Container(
    color: mode == TripMode.planning ? Colors.blue : Colors.green,
  );
}
```

---

## 📚 API参考

### ItineraryProvider

#### 属性

| 属性 | 类型 | 说明 |
|------|------|------|
| `currentMode` | `TripMode` | 当前模式（只读） |

#### 方法

| 方法 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `toggleTripMode()` | `TripMode mode` | `void` | 切换模式 |

### TripMode 枚举

| 值 | 说明 |
|----|------|
| `TripMode.planning` | 行程规划模式 |
| `TripMode.traveling` | 行程中模式 |

---

## 🎓 最佳实践

### 1. 使用语义化命名

```dart
// ✅ 好的命名
final isInPlanningMode = currentMode == TripMode.planning;
final isInTravelingMode = currentMode == TripMode.traveling;

// ❌ 避免的命名
final flag = currentMode == TripMode.planning;
final temp = currentMode == TripMode.traveling;
```

### 2. 提取模式判断逻辑

```dart
// ✅ 好的做法：提取为方法
bool _shouldShowEditButton() {
  return context.read<ItineraryProvider>().currentMode == TripMode.planning;
}

Widget build(BuildContext context) {
  return Column(
    children: [
      if (_shouldShowEditButton())
        EditButton(),
    ],
  );
}
```

### 3. 使用常量

```dart
// ✅ 好的做法：定义常量
class ModeConfig {
  static const Color planningColor = Color(0xFF3F51B5);
  static const Color travelingColor = Color(0xFF4CAF50);
  
  static Color getColorForMode(TripMode mode) {
    return mode == TripMode.planning ? planningColor : travelingColor;
  }
}
```

---

## 🔗 相关文档

- [完整实现报告](./DUAL_MODE_IMPLEMENTATION.md)
- [架构设计图](./MODE_TOGGLE_ARCHITECTURE.md)
- [照片管理测试](./test_photo_management.md)

---

## 💡 常见问题

### Q: 如何设置默认模式？

A: 在 `ItineraryProvider` 中修改初始值：

```dart
TripMode _currentMode = TripMode.planning; // 默认为规划模式
```

### Q: 如何持久化用户选择的模式？

A: 在 `toggleTripMode()` 中添加保存逻辑：

```dart
void toggleTripMode(TripMode mode) async {
  if (_currentMode != mode) {
    _currentMode = mode;
    HapticFeedback.lightImpact();
    notifyListeners();
    
    // 保存到本地
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('trip_mode', mode.name);
  }
}
```

### Q: 如何在其他页面使用这个模式？

A: 直接通过 Provider 访问：

```dart
class OtherScreen extends StatelessWidget {
  Widget build(BuildContext context) {
    final mode = context.watch<ItineraryProvider>().currentMode;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(mode == TripMode.planning ? '规划' : '旅行'),
      ),
      body: ...,
    );
  }
}
```

---

## 🎉 总结

双模式切换功能让用户可以：
- ✅ 自由切换规划和旅行视图
- ✅ 享受专注的功能体验
- ✅ 流畅的动画和交互

开发者可以：
- ✅ 轻松获取当前模式
- ✅ 根据模式定制UI
- ✅ 保持代码简洁清晰

---

**快速上手指南版本：** v1.0.0  
**最后更新：** 2026-05-01  
**适用人群：** 开发者、产品经理、UI设计师

# 🏗️ 双模式切换架构图

## 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                    ItineraryScreen (UI层)                    │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          _buildModeToggle() 胶囊切换器              │   │
│  │                                                       │   │
│  │   ┌──────────────┐         ┌──────────────┐        │   │
│  │   │ 📝 行程规划  │         │  🎒 行程中   │        │   │
│  │   └──────────────┘         └──────────────┘        │   │
│  │         ↓                          ↓                 │   │
│  │   TripMode.planning      TripMode.traveling        │   │
│  └─────────────────────────────────────────────────────┘   │
│                           ↓                                  │
│              Consumer<ItineraryProvider>                    │
│                           ↓                                  │
│         ┌─────────────────────────────────┐                │
│         │   effectiveState 转换逻辑        │                │
│         │                                   │                │
│         │  TripMode → TripState            │                │
│         │  planning  → preparing           │                │
│         │  traveling → traveling           │                │
│         └─────────────────────────────────┘                │
│                           ↓                                  │
│         ┌─────────────────────────────────┐                │
│         │      条件渲染 UI 组件            │                │
│         │                                   │                │
│         │  if (effectiveState == preparing) │                │
│         │    → _buildPreparingSlivers()    │                │
│         │  else                             │                │
│         │    → _buildTravelingSlivers()    │                │
│         └─────────────────────────────────┘                │
└─────────────────────────────────────────────────────────────┘
                           ↑
                           │ notifyListeners()
                           │
┌─────────────────────────────────────────────────────────────┐
│              ItineraryProvider (状态管理层)                  │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  TripMode _currentMode = TripMode.planning;         │   │
│  │                                                       │   │
│  │  void toggleTripMode(TripMode mode) {               │   │
│  │    if (_currentMode != mode) {                      │   │
│  │      _currentMode = mode;                           │   │
│  │      HapticFeedback.lightImpact(); // 震动反馈      │   │
│  │      notifyListeners(); // 通知UI更新               │   │
│  │    }                                                 │   │
│  │  }                                                   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 数据流向

```
用户点击切换器
    ↓
GestureDetector.onTap()
    ↓
provider.toggleTripMode(TripMode.traveling)
    ↓
ItineraryProvider._currentMode = TripMode.traveling
    ↓
HapticFeedback.lightImpact() // 震动反馈
    ↓
notifyListeners() // 通知所有监听器
    ↓
Consumer<ItineraryProvider> 重建
    ↓
_buildModeToggle() 更新滑块位置和文字颜色
    ↓
effectiveState 计算为 TripState.traveling
    ↓
条件渲染切换到 _buildTravelingSlivers()
    ↓
UI 显示时间轴视图
```

---

## UI 组件树

```
Scaffold
└── Column
    ├── Container (顶部标题栏)
    │   └── Row
    │       ├── Text (行程标题)
    │       └── InkWell (展开/收起地图按钮)
    │
    ├── AnimatedContainer (地图容器)
    │   └── _buildMapOnlyWidget()
    │       └── _buildAmap() / _buildGoogleMap()
    │
    ├── Padding (天数筛选栏)
    │   └── _buildDayTabBar()
    │
    └── Expanded (滚动内容区)
        └── CustomScrollView
            └── slivers
                ├── SliverToBoxAdapter
                │   └── _buildModeToggle() ← 🎯 新增的模式切换器
                │
                ├── [条件渲染]
                │   ├── _buildPreparingSlivers() (规划模式)
                │   │   ├── SliverToBoxAdapter (准备清单)
                │   │   └── SliverList (天数列表)
                │   │
                │   └── _buildTravelingSlivers() (旅行模式)
                │       └── SliverList (时间轴卡片)
                │
                └── SliverPadding (底部留白)
```

---

## 模式切换动画时序

```
时间轴 (250ms 动画)
─────────────────────────────────────────────────────────────

0ms     用户点击"🎒 行程中"
        │
        ├─ HapticFeedback.lightImpact() 触发震动
        │
        └─ notifyListeners() 通知UI更新

0-250ms AnimatedPositioned 执行滑块移动动画
        │  Curve: Curves.easeOutCubic
        │  From: left = 2
        │  To:   left = 120
        │
        └─ AnimatedDefaultTextStyle 执行文字颜色/字重动画
           Duration: 200ms
           "📝 行程规划": bold → normal, indigo → grey
           "🎒 行程中":   normal → bold, grey → green

250ms   动画完成
        │
        └─ UI 完全切换到旅行模式
           ├─ 滑块停在右侧
           ├─ "🎒 行程中" 显示为绿色加粗
           └─ 内容区显示时间轴视图
```

---

## 状态管理流程

```
┌─────────────────────────────────────────────────────────────┐
│                    ItineraryProvider                         │
│                                                               │
│  ┌──────────────┐                                           │
│  │ _currentMode │ ← 私有状态变量                            │
│  └──────────────┘                                           │
│         ↓                                                     │
│  ┌──────────────┐                                           │
│  │ currentMode  │ ← 公开 getter                             │
│  └──────────────┘                                           │
│         ↓                                                     │
│  ┌──────────────────────────────────┐                       │
│  │ toggleTripMode(TripMode mode)    │ ← 公开方法            │
│  │                                    │                       │
│  │ 1. 检查是否需要切换                │                       │
│  │ 2. 更新 _currentMode               │                       │
│  │ 3. 触发震动反馈                    │                       │
│  │ 4. 调用 notifyListeners()         │                       │
│  └──────────────────────────────────┘                       │
│         ↓                                                     │
│  ┌──────────────────────────────────┐                       │
│  │ notifyListeners()                 │                       │
│  │                                    │                       │
│  │ 通知所有 Consumer 和 Selector     │                       │
│  └──────────────────────────────────┘                       │
└─────────────────────────────────────────────────────────────┘
                    ↓
         ┌──────────────────────┐
         │  所有监听的 Widget    │
         │  自动重建             │
         └──────────────────────┘
```

---

## 兼容性设计

```
┌─────────────────────────────────────────────────────────────┐
│                    双状态系统设计                             │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  TripState (原有枚举 - 基于日期自动判断)             │  │
│  │                                                        │  │
│  │  enum TripState {                                     │  │
│  │    preparing,  // 行程开始前                         │  │
│  │    traveling   // 行程进行中                         │  │
│  │  }                                                     │  │
│  │                                                        │  │
│  │  getTripState() {                                     │  │
│  │    if (today < startDate) return preparing;          │  │
│  │    if (today > endDate) return preparing;            │  │
│  │    return traveling;                                  │  │
│  │  }                                                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                           ↓                                  │
│                    保留用于其他逻辑                          │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  TripMode (新增枚举 - 用户手动选择)                  │  │
│  │                                                        │  │
│  │  enum TripMode {                                      │  │
│  │    planning,   // 行程规划模式                       │  │
│  │    traveling   // 行程中模式                         │  │
│  │  }                                                     │  │
│  │                                                        │  │
│  │  toggleTripMode(TripMode mode) {                     │  │
│  │    _currentMode = mode;                              │  │
│  │    notifyListeners();                                │  │
│  │  }                                                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                           ↓                                  │
│                    用于UI模式切换                            │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  effectiveState (桥接逻辑)                            │  │
│  │                                                        │  │
│  │  final effectiveState = currentMode == planning      │  │
│  │      ? TripState.preparing                           │  │
│  │      : TripState.traveling;                          │  │
│  │                                                        │  │
│  │  // 使用 effectiveState 渲染UI                       │  │
│  │  if (effectiveState == TripState.preparing) {        │  │
│  │    ..._buildPreparingSlivers()                       │  │
│  │  } else {                                             │  │
│  │    ..._buildTravelingSlivers()                       │  │
│  │  }                                                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 性能优化策略

### 1. 精确订阅
```dart
// ✅ 好的做法：只订阅需要的状态
final currentMode = context.watch<ItineraryProvider>().currentMode;

// ❌ 避免：订阅整个 provider
final provider = context.watch<ItineraryProvider>();
```

### 2. 避免不必要的重建
```dart
// toggleTripMode() 中的防抖逻辑
if (_currentMode != mode) {  // 只在真正改变时才通知
  _currentMode = mode;
  notifyListeners();
}
```

### 3. 使用高性能动画组件
```dart
// AnimatedPositioned - GPU 加速的位置动画
// AnimatedDefaultTextStyle - 高效的文字样式动画
// 避免使用 AnimatedBuilder 等需要手动计算的组件
```

### 4. 条件渲染而非隐藏
```dart
// ✅ 好的做法：条件渲染
if (effectiveState == TripState.preparing)
  ..._buildPreparingSlivers()
else
  ..._buildTravelingSlivers()

// ❌ 避免：同时渲染后隐藏
Visibility(
  visible: effectiveState == TripState.preparing,
  child: _buildPreparingSlivers(),
)
```

---

## 测试检查清单

### 功能测试
- [ ] 点击"📝 行程规划"，UI切换到规划模式
- [ ] 点击"🎒 行程中"，UI切换到旅行模式
- [ ] 滑块动画流畅，无卡顿
- [ ] 文字颜色和字重正确变化
- [ ] 震动反馈正常触发

### 兼容性测试
- [ ] 照片上传功能正常
- [ ] 照片删除功能正常
- [ ] 首图不会丢失
- [ ] 地图显示正常
- [ ] 天数筛选正常

### 边界测试
- [ ] 快速连续点击切换器，无异常
- [ ] 切换模式后滚动列表，无闪烁
- [ ] 切换模式后地图状态保持
- [ ] 无行程数据时，不显示切换器

### 性能测试
- [ ] 切换动画帧率 ≥ 60fps
- [ ] 内存占用无明显增长
- [ ] 无内存泄漏

---

## 故障排查指南

### 问题：切换器不显示
**可能原因：**
- Provider 未正确注入
- `_buildModeToggle()` 未被调用

**解决方案：**
```dart
// 检查 main.dart 中是否有 ChangeNotifierProvider
ChangeNotifierProvider(
  create: (_) => ItineraryProvider(),
  child: MyApp(),
)

// 检查 slivers 中是否添加了切换器
return <Widget>[
  SliverToBoxAdapter(child: _buildModeToggle(context)),
  // ...
];
```

### 问题：切换后UI未更新
**可能原因：**
- 未调用 `notifyListeners()`
- Consumer 未正确监听

**解决方案：**
```dart
// 确保 toggleTripMode() 中调用了 notifyListeners()
void toggleTripMode(TripMode mode) {
  _currentMode = mode;
  notifyListeners(); // ← 必须调用
}

// 确保使用 Consumer 或 context.watch
Consumer<ItineraryProvider>(
  builder: (context, provider, _) {
    // UI 代码
  },
)
```

### 问题：动画卡顿
**可能原因：**
- 动画时长过长
- 同时执行过多动画

**解决方案：**
```dart
// 调整动画时长
AnimatedPositioned(
  duration: const Duration(milliseconds: 200), // 缩短时长
  curve: Curves.easeOut, // 使用更简单的曲线
  // ...
)
```

---

## 扩展开发指南

### 添加第三种模式
```dart
// 1. 扩展枚举
enum TripMode {
  planning,
  traveling,
  reviewing,  // 新增：行程回顾模式
}

// 2. 修改切换器UI
Widget _buildModeToggle(BuildContext context) {
  // 改为三段式切换器
  return Container(
    width: 360, // 增加宽度
    child: Row(
      children: [
        _buildModeButton('📝 规划', TripMode.planning),
        _buildModeButton('🎒 旅行', TripMode.traveling),
        _buildModeButton('📖 回顾', TripMode.reviewing),
      ],
    ),
  );
}

// 3. 添加对应的 Sliver 构建方法
List<Widget> _buildReviewingSlivers(...) {
  // 回顾模式的UI
}
```

### 持久化模式选择
```dart
// 在 ItineraryProvider 中添加
Future<void> saveModeToPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('trip_mode', _currentMode.name);
}

Future<void> loadModeFromPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  final modeName = prefs.getString('trip_mode');
  if (modeName != null) {
    _currentMode = TripMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => TripMode.planning,
    );
    notifyListeners();
  }
}
```

---

**文档版本：** v1.0.0  
**最后更新：** 2026-05-01  
**维护者：** 开发团队

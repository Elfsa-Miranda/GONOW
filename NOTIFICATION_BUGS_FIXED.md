# 通知服务 Bug 修复报告

## 修复日期
2026-05-17

## 修复的关键 Bug

### 🔴 Bug 1（最高危）：iOS 从不请求权限，通知必然静默失败
**位置**：第 37-42 行

**问题描述**：
- `DarwinInitializationSettings` 中三个权限参数全部设为 `false`
- iOS 在初始化时不会弹出授权弹窗
- 如果调用方在 `init()` 后没有主动调用 `requestPermission()`，iOS 永远不会获得授权
- 所有通知都会被系统静默丢弃

**修复方案**：
```dart
const DarwinInitializationSettings iosSettings =
    DarwinInitializationSettings(
  requestAlertPermission: true,   // ✅ 改为 true
  requestBadgePermission: true,   // ✅ 改为 true
  requestSoundPermission: true,   // ✅ 改为 true
);
```

**影响**：现在 iOS 会在初始化时自动请求通知权限，确保通知能够正常显示。

---

### 🔴 Bug 2（高危）：_parseDepartureTime 的正则匹配顺序存在覆盖 Bug
**位置**：第 419-422 行

**问题描述**：
- `mdReg2` 的正则 `(\d{1,2})[.\-/](\d{1,2})` 会错误匹配 "10月1日 · 去程" 中的数字片段
- 当 `dateStr` 是 "2024-10-01" 时，`mdReg2` 可能先匹配到 "2024-10"（把年当成月）
- 匹配顺序与判断顺序不一致，导致优先级混乱

**修复方案**：
1. 调整匹配顺序，优先匹配完整日期格式（包含年份）
2. 为 `mdReg2` 添加边界约束：`^(\d{1,2})[.\-/](\d{1,2})$`
3. 按优先级顺序执行匹配和判断

```dart
// ✅ 优先匹配完整日期格式（包含年份）
final RegExpMatch? m3 = mdReg3.firstMatch(ticket.dateStr);
if (m3 != null) {
  year = int.parse(m3.group(1)!);  // 使用票据中的年份
  month = int.parse(m3.group(2)!);
  day = int.parse(m3.group(3)!);
} else {
  // 其次匹配中文格式
  final RegExpMatch? m1 = mdReg1.firstMatch(ticket.dateStr);
  if (m1 != null) { ... }
  else {
    // 最后匹配简短格式
    final RegExpMatch? m2 = mdReg2.firstMatch(ticket.dateStr);
    ...
  }
}
```

**影响**：日期解析更加准确，避免了格式歧义导致的错误解析。

---

### 🟡 Bug 3（中危）：跨年行程日期解析错误
**位置**：第 399 行

**问题描述**：
- 永远使用 `DateTime.now().year` 作为年份
- 如果用户在 2025 年 12 月底添加 2026 年 1 月的机票
- 会解析出 2025-01-xx（过去的时间）
- 触发兜底逻辑变成"5 秒后触发"，提醒完全失效

**修复方案**：
```dart
DateTime result = DateTime(year, month, day, hour, minute);

// ✅ 修复跨年问题：如果解析出的日期在过去（超过1天），则认为是明年
if (result.isBefore(DateTime.now().subtract(const Duration(days: 1)))) {
  result = DateTime(year + 1, month, day, hour, minute);
  debugPrint('⚠️ [NotificationService] 检测到跨年行程，年份已调整为 ${year + 1}');
}
```

**影响**：正确处理跨年行程，确保提醒时间准确。

---

### 🟡 Bug 4（中危）：sendTicketAddedNotification 没有 payload，点击通知无法跳转
**位置**：第 113-135 行

**问题描述**：
- `_plugin.show()` 和 `zonedSchedule()` 调用里没有传 `payload` 参数
- `_onNotificationTap` 里尝试用 `response.payload` 做路由导航
- 结果 `payload` 永远是 `null`，点击通知什么也不会发生

**修复方案**：
在所有通知调用中添加 `payload` 参数：
```dart
await _plugin.show(
  ...,
  payload: ticket.id,  // ✅ 添加 payload 用于点击跳转
);

await _plugin.zonedSchedule(
  ...,
  payload: ticket.id,  // ✅ 添加 payload 用于点击跳转
);
```

**影响**：点击通知后可以正确获取 `ticketId`，实现跳转到对应页面的功能。

---

### 🟡 Bug 5（中危）：通知文案显示固定时间而非实际剩余时间
**位置**：第 176-182 行、第 316 行、第 348 行

**问题描述**：
- 通知的 `collapsedBody` 文案使用固定的 `hoursAhead` 参数（默认 6）
- 无论实际剩余时间是多少，永远显示"距起飞还有约 6 小时"
- 即使只剩 8 分钟，也会显示"约 6 小时"，严重误导用户
- `minutesLeft` 虽然计算了，但只用于判断紧急程度，没有用在文案上

**修复方案**：
1. 修正 `minutesLeft` 的计算时机：
```dart
// ✅ 计算提醒触发时的剩余分钟数（而不是当前时刻的剩余时间）
final int minutesLeft = departureTime.difference(reminderTime).inMinutes;
```

2. 添加时间格式化辅助函数：
```dart
String _formatTimeLeft(int minutesLeft) {
  if (minutesLeft <= 0) return '即将';
  if (minutesLeft < 60) return '约 $minutesLeft 分钟';
  final int h = minutesLeft ~/ 60;
  final int m = minutesLeft % 60;
  return m == 0 ? '约 $h 小时' : '约 $h 小时 $m 分钟';
}
```

3. 在航班和高铁的 `collapsedBody` 中使用动态时间：
```dart
// 航班
final String timeLeftText = _formatTimeLeft(minutesLeft);
collapsedBody: '${ticket.locationA} ➔ ${ticket.locationB} | ${ticket.timeA} 起飞，距起飞还有$timeLeftText',

// 高铁
collapsedBody: '${ticket.locationA} ➔ ${ticket.locationB} | ${ticket.timeA} 发车，距发车还有$timeLeftText',
```

**影响**：
- 通知文案现在会准确反映实际剩余时间
- 显示格式更友好：
  - 少于 1 小时：显示"约 X 分钟"
  - 整点小时：显示"约 X 小时"
  - 非整点：显示"约 X 小时 Y 分钟"
  - 已过期：显示"即将"

**注意事项**：
由于通知内容在调度时就已经序列化写入系统，触发时不会重新计算。因此文案准确度取决于"安排时间"和"实际触发时间"的误差。对于精确闹钟，误差通常在秒级以内，完全可以接受。

---

## 🟢 额外改进

### 1. 改进精确闹钟权限检查
**位置**：第 93 行

**问题**：`requestExactAlarmsPermission()` 的结果没有存储，后续无法判断是否真的拿到权限。

**修复**：
```dart
final bool? exactAlarmGranted = await androidPlugin?.requestExactAlarmsPermission();
debugPrint('[NotificationService] 精确闹钟权限: $exactAlarmGranted');
```

### 2. 改进通知 ID 生成算法
**位置**：第 261 行

**问题**：`hashCode.abs() % 100000` 在极端情况下不同 `ticketId` 可能碰撞。

**修复**：使用更安全的哈希算法
```dart
int _notifIdForTicket(String ticketId, {required int suffix}) {
  // 使用字符串的多个字符计算更稳定的哈希
  int hash = 0;
  for (int i = 0; i < ticketId.length; i++) {
    hash = ((hash << 5) - hash + ticketId.codeUnitAt(i)) & 0x7FFFFFFF;
  }
  return (hash % 1000000) * 10 + suffix;
}
```

### 3. 改进日志输出
在 `sendTicketAddedNotification` 中添加未初始化的日志提示：
```dart
if (!_initialized) {
  debugPrint('[NotificationService] 未初始化，跳过即时通知');
  return;
}
```

---

## 测试建议

### iOS 测试
1. 首次启动应用，验证是否弹出通知权限请求
2. 添加票务，验证即时通知是否显示
3. 点击通知，验证是否能跳转到对应页面
4. 验证定时提醒是否在预定时间触发

### Android 测试
1. 验证通知权限和精确闹钟权限请求
2. 添加票务，验证即时通知是否显示
3. 点击通知，验证是否能跳转到对应页面
4. 验证定时提醒是否在预定时间触发

### 跨年测试
1. 在 12 月底添加次年 1 月的票务
2. 验证日期解析是否正确（应该是次年）
3. 验证提醒时间是否正确设置

### 日期格式测试
测试以下日期格式是否都能正确解析：
- "10月1日 · 去程"
- "10月1日"
- "10.01"
- "10-01"
- "2024-10-01"

---

## 总结

所有关键 Bug 已修复，通知服务现在应该能够：
- ✅ 在 iOS 上正确请求和获取通知权限
- ✅ 准确解析各种日期格式
- ✅ 正确处理跨年行程
- ✅ 支持点击通知跳转功能
- ✅ 动态显示实际剩余时间（而非固定的"6小时"）
- ✅ 更稳定的通知 ID 生成，避免碰撞
- ✅ 更完善的日志输出，便于调试

### 时间显示示例

修复后，通知文案会根据实际剩余时间动态显示：
- 剩余 8 分钟：`j → n | 14:06 起飞，距起飞还有约 8 分钟`
- 剩余 2 小时：`j → n | 14:06 起飞，距起飞还有约 2 小时`
- 剩余 3 小时 30 分钟：`j → n | 14:06 起飞，距起飞还有约 3 小时 30 分钟`
- 剩余 6 小时：`j → n | 14:06 起飞，距起飞还有约 6 小时`
- 已过期：`j → n | 14:06 起飞，距起飞还有即将`

建议在发布前进行完整的端到端测试，特别是跨年场景和各种日期格式的组合。

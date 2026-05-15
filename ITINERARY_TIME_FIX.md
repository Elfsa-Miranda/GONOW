# 行程时间智能分配修复方案

## 问题总结

根据你提供的截图和描述,发现以下4个核心问题:

### 1. 新添加的景点没有时间
- **现象**: 手动添加新景点时,时间字段为空
- **根因**: `_insertEditableActivity` 方法直接使用用户输入的 `time` 参数(可能为空字符串),没有智能推算

### 2. AI润色后默认显示09:00
- **现象**: AI润色后,新景点在查看页显示为09:00
- **根因**: `_buildTravelingTimelineData` 第5279行硬编码了默认值 `'09:00'`

### 3. 编辑页面显示"时间待定"
- **现象**: 编辑页面的新景点显示"时间待定"而不是具体时间
- **根因**: `_buildEditableActivityNode` 读取的是原始空 `time` 字段,而不是计算后的时间

### 4. 时间轴顺序混乱
- **现象**: 09:00的长城出现在16:30和18:30景点之后
- **根因**: 
  - 新插入节点 `time` 为空,`_sortDayActivities` 把它沉底
  - 查看页对 activities 没有再次排序
  - AI润色不回写 `time` 字段,导致排序失效

---

## 修复方案

### 修改1: 消除硬编码 '09:00' 默认值

**文件**: `lib/features/itinerary/presentation/screens/itinerary_screen.dart`

**位置**: 第5279行

```dart
// 修改前
'scheduledTime': _stringValue(activity['time'], '09:00'),

// 修改后
'scheduledTime': _stringValue(activity['time'], ''),
```

**位置**: 第5601行

```dart
// 修改前
time: item['scheduledTime']?.toString() ?? '09:00',

// 修改后
time: item['scheduledTime']?.toString() ?? '',
```

---

### 修改2: _insertEditableActivity 智能推算插入时间

**文件**: `lib/features/itinerary/presentation/screens/itinerary_screen.dart`

**位置**: 第1685-1738行,替换整个方法

**核心逻辑**:
1. 如果用户输入了时间,直接使用
2. 如果时间为空,智能推算:
   - 查找前驱节点(afterIndex及之前第一个有效时间)
   - 查找后继节点(afterIndex+1及之后第一个有效时间)
   - 如果前后都有时间:取中间值
   - 如果只有前驱:前驱时间+60分钟
   - 如果只有后继:后继时间-60分钟
   - 如果前后都没有:保持空字符串,显示"时间待定"

**关键代码**:
```dart
// ── 智能推算插入位置的默认时间 ──
String resolvedTime = time.trim();
if (resolvedTime.isEmpty) {
  // 查找前后相邻节点时间
  final RegExp hhMm = RegExp(r'^([01]?[0-9]|2[0-3]):([0-5][0-9])$');
  int? prevMinutes;
  int? nextMinutes;
  
  // 前驱时间查找...
  // 后继时间查找...
  
  // 计算目标时间
  if (prevMinutes != null && nextMinutes != null) {
    targetMinutes = ((prevMinutes + nextMinutes) / 2).round();
  } else if (prevMinutes != null) {
    targetMinutes = (prevMinutes + 60).clamp(0, 23 * 60 + 59);
  } else if (nextMinutes != null) {
    targetMinutes = (nextMinutes - 60).clamp(0, 23 * 60 + 59);
  }
  
  // 格式化为 HH:mm
  if (targetMinutes != null) {
    final int h = targetMinutes ~/ 60;
    final int min = targetMinutes % 60;
    resolvedTime = '${h.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}';
  }
}
```

---

### 修改3: AI润色时补充 time 字段

**文件**: `lib/features/itinerary/presentation/screens/itinerary_screen.dart`

#### 3a. 修改 system prompt (第755-770行)

```dart
final String existingTime = (item['time'] ?? '').toString().trim();
final String systemPrompt = '''
你是一个顶级的私人旅行管家。用户刚刚在行程中手动添加了一个新节点：【$title】。
请你发挥专业知识，帮用户把这个节点的信息补全，使其看起来专业详尽。

【原稿参考】：$originalDesc
【当前安排时间】：${existingTime.isNotEmpty ? existingTime : '未设置'}

【绝对红线】：必须且只能返回一个合法的 JSON 对象，不包含任何 Markdown 标记 (如 ```json)！
JSON 必须严格包含以下 5 个字段：
{
  "time": "建议的游览开始时间，格式 HH:mm（如：09:30）。若原时间已合理则原样返回；若为空则根据景点信息和整体行程的时间规划给出合理建议时间安排",
  "openTime": "景点的真实开放时间 (如：09:00-18:00 开放 或 全天开放)",
  "recommended_duration": "建议游玩时长 (如：预计游玩 1.5小时)",
  "tag": "提炼精准的标签 (如：地标 · 必打卡)",
  "description": "用温暖、专业的旅游管家口吻撰写的游玩攻略或避坑指南，约60-100字"
}
''';
```

#### 3b. 回写 time 字段 (第839行附近)

```dart
final String aiTime = (aiResult['time'] ?? '').toString().trim();
final RegExp hhMmStrict = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');
if (aiTime.isNotEmpty && hhMmStrict.hasMatch(aiTime)) {
  activity['time'] = aiTime;
}

// 同步更新 item
if (aiTime.isNotEmpty && hhMmStrict.hasMatch(aiTime)) {
  item['time'] = aiTime;
}
```

#### 3c. AI润色后触发排序 (第866行附近)

```dart
_triggerAutoSave();
// AI 补全后重新排序，确保时间轴顺序正确
_sortDayActivities(dIdx);
```

---

### 修改4: 查看态 activities 按时间排序

**文件**: `lib/features/itinerary/presentation/screens/itinerary_screen.dart`

**位置**: `_buildDayRoutes` 方法中的两处

#### 4a. 第一处 (第5074行附近)

```dart
.where((ActivityItem a) => a.lat != 0 && a.lng != 0)
.toList(growable: false);

// 新增：按 time 升序排序，时间为空的沉底
final RegExp timeReg = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');
activities.sort((ActivityItem a, ActivityItem b) {
  final bool validA = timeReg.hasMatch(a.time ?? '');
  final bool validB = timeReg.hasMatch(b.time ?? '');
  if (validA && validB) return (a.time ?? '').compareTo(b.time ?? '');
  if (validA) return -1;
  if (validB) return 1;
  return 0;
});

parsed.add(_DayRoute(...));
```

#### 4b. 第二处 (第5090行附近)

```dart
return List<_DayRoute>.generate(model.days.length, (int i) {
  final DayPlan day = model.days[i];
  final List<ActivityItem> sortedActivities = day.activities
      .where((ActivityItem a) => a.lat != 0 && a.lng != 0)
      .toList(growable: false);
  
  // 新增：按 time 升序排序，时间为空的沉底
  final RegExp timeReg = RegExp(r'^([01]?[0-9]|2[0-3]):[0-5][0-9]$');
  sortedActivities.sort((ActivityItem a, ActivityItem b) {
    final bool validA = timeReg.hasMatch(a.time ?? '');
    final bool validB = timeReg.hasMatch(b.time ?? '');
    if (validA && validB) return (a.time ?? '').compareTo(b.time ?? '');
    if (validA) return -1;
    if (validB) return 1;
    return 0;
  });
  
  return _DayRoute(
    dayTitle: day.dayTitle,
    themeColor: _palette[i % _palette.length],
    activities: sortedActivities,
  );
});
```

---

## 修改总结

| 问题 | 根因 | 修改位置 | 解决方案 |
|------|------|----------|----------|
| 新增景点无时间 | `_insertEditableActivity` 直接存空 time | 第1685-1738行 | 智能推算相邻节点中间时间 |
| AI润色后默认09:00 | `_buildTravelingTimelineData` 硬编码 '09:00' | 第5279行、第5601行 | 改为空字符串 |
| 编辑页显示"时间待定" | time 为空是正确展示,根源在于没有推算时间 | 第1685-1738行 | 智能推算解决 |
| AI润色不给新景点设时间 | prompt 无 time 字段,回写逻辑也没有 | 第755-770行、第839行 | prompt 加 time,并回写 |
| 时间轴顺序混乱 | 查看态不排序 | 第5074行、第5090行 | 两处都加排序逻辑 |

---

## 测试验证

修复后,请验证以下场景:

1. ✅ **手动添加新景点**
   - 在两个已有景点之间插入,时间应该是中间值
   - 在最后插入,时间应该是前一个景点+60分钟
   - 在第一个位置插入,时间应该是后一个景点-60分钟

2. ✅ **AI润色新景点**
   - AI应该返回合理的时间建议
   - 时间应该被正确回写到数据中
   - 润色后时间轴应该自动重新排序

3. ✅ **编辑页面显示**
   - 新添加的景点应该显示具体时间(如 10:30)
   - 不应该显示"时间待定"(除非前后都没有参考时间)

4. ✅ **查看页面顺序**
   - 所有景点应该按时间升序排列
   - 09:00 的景点应该在 16:30 之前
   - 时间为空的景点应该排在最后

---

## 涉及的文件

**主要修改文件**:
- `lib/features/itinerary/presentation/screens/itinerary_screen.dart`

**修改行数统计**:
- 修改1: 2处 (第5279行、第5601行)
- 修改2: 1个完整方法替换 (第1685-1738行,约54行)
- 修改3: 3处 (第755-770行、第839行、第866行)
- 修改4: 2处 (第5074行、第5090行)

**总计**: 约 **100行代码修改**

---

## 技术亮点

1. **智能时间推算算法**: 根据前后相邻节点自动计算合理的插入时间
2. **AI增强**: 让AI不仅补充描述,还能给出合理的时间建议
3. **双向同步**: 编辑态和查看态都保持时间顺序一致
4. **容错处理**: 时间格式严格校验,避免非法数据
5. **用户体验**: 自动排序,无需手动调整顺序

---

## 修复完成时间

2026-05-15

所有修改已成功应用! 🎉

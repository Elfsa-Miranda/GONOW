# 行程数据用户关联修复方案

## 🚨 问题描述

在 `lib/features/itinerary/data/itinerary_provider.dart` 文件中，`saveToSupabase()` 方法在保存新行程时**没有写入 user_id 字段**，导致：

1. ❌ 新创建的行程无法关联到用户
2. ❌ 用户切换账号后可能看到其他用户的行程  
3. ❌ 数据库中的行程记录没有所有者
4. ❌ 查询时使用 `.eq('user_id', userId)` 会查不到这些行程

## 📍 问题代码位置

**文件**: `lib/features/itinerary/data/itinerary_provider.dart`  
**行号**: 999-1007

### 当前错误代码

```dart
Future<void> saveToSupabase(ItineraryModel model) async {
  final SupabaseClient client = Supabase.instance.client;
  await client.from(_tableName).insert(<String, dynamic>{
    'title': model.title,
    'start_date': model.startDate.toIso8601String(),
    'end_date': model.endDate.toIso8601String(),
    'plan_data': model.planData,
    'created_at': DateTime.now().toIso8601String(),
    'version': 1,
    // ❌ 缺少 'user_id': userId
  });
}
```

## ✅ 修复方案

### 方案一：最小改动修复（推荐）

```dart
Future<void> saveToSupabase(ItineraryModel model) async {
  final SupabaseClient client = Supabase.instance.client;
  final String? userId = client.auth.currentUser?.id;
  
  // 如果未登录，不应该保存到云端
  if (userId == null) {
    debugPrint('⚠️ 用户未登录，跳过云端保存');
    return;
  }
  
  await client.from(_tableName).insert(<String, dynamic>{
    'user_id': userId,  // ✅ 添加用户ID
    'title': model.title,
    'start_date': model.startDate.toIso8601String(),
    'end_date': model.endDate.toIso8601String(),
    'plan_data': model.planData,
    'created_at': DateTime.now().toIso8601String(),
    'version': 1,
  });
}
```

### 方案二：使用 upsert 替代 insert（更健壮）

如果行程可能已存在（比如从本地同步到云端），使用 upsert 更安全：

```dart
Future<void> saveToSupabase(ItineraryModel model) async {
  final SupabaseClient client = Supabase.instance.client;
  final String? userId = client.auth.currentUser?.id;
  
  if (userId == null) {
    debugPrint('⚠️ 用户未登录，跳过云端保存');
    return;
  }
  
  // 如果model有remoteId，使用它；否则让数据库生成UUID
  final Map<String, dynamic> data = <String, dynamic>{
    'user_id': userId,
    'title': model.title,
    'start_date': model.startDate.toIso8601String(),
    'end_date': model.endDate.toIso8601String(),
    'plan_data': model.planData,
    'created_at': (model.createdAt ?? DateTime.now()).toIso8601String(),
    'version': model.version,
  };
  
  // 如果有有效的UUID，包含id字段使用upsert
  if (model.remoteId != null && _isValidUuid(model.remoteId!)) {
    data['id'] = model.remoteId;
    await client.from(_tableName).upsert(data);
  } else {
    // 否则使用insert让数据库生成新ID
    await client.from(_tableName).insert(data);
  }
}
```

## 🔍 需要检查的其他位置

虽然主要问题在 `saveToSupabase()`，但建议也检查以下方法：

### 1. updateItineraryDataWithLock() 方法

**位置**: 约第1050-1150行

这个方法使用 `.update()` 更新现有行程，**不需要修改**，因为：
- update 操作通过 `.eq('id', targetId)` 定位记录
- 不会修改 user_id 字段
- 只更新 plan_data 和 version

### 2. fetchActiveItinerary() 方法

**位置**: 约第960-1000行

这个方法从数据库读取行程，**需要添加用户过滤**：

```dart
Future<void> fetchActiveItinerary() async {
  _isBusy = true;
  notifyListeners();
  try {
    final SupabaseClient client = Supabase.instance.client;
    final String? userId = client.auth.currentUser?.id;
    
    // ✅ 添加用户过滤
    var query = client
        .from(_tableName)
        .select()
        .order('start_date', ascending: false)
        .limit(1);
    
    // 如果已登录，只查询当前用户的行程
    if (userId != null) {
      query = query.eq('user_id', userId);
    }
    
    final List<dynamic> rows = await query;
    
    if (rows.isNotEmpty && rows.first is Map<String, dynamic>) {
      // ... 后续处理保持不变
    }
  } catch (_) {
    await loadFromPrefs();
  } finally {
    _isBusy = false;
    notifyListeners();
  }
}
```

## 📝 修改步骤

### 第一步：备份当前文件
```bash
cp lib/features/itinerary/data/itinerary_provider.dart lib/features/itinerary/data/itinerary_provider.dart.backup
```

### 第二步：修改 saveToSupabase() 方法
使用上面的**方案一**或**方案二**替换第999-1007行的代码

### 第三步：（可选）修改 fetchActiveItinerary() 方法
添加用户过滤，确保只查询当前用户的行程

### 第四步：测试验证

#### 测试场景1：创建新行程
```dart
// 1. 登录用户A
// 2. 创建新行程
// 3. 检查数据库：user_id 字段应该等于用户A的ID
```

#### 测试场景2：多用户隔离
```dart
// 1. 用户A创建行程1
// 2. 登出，登录用户B
// 3. 用户B应该看不到行程1
// 4. 用户B创建行程2
// 5. 登出，重新登录用户A
// 6. 用户A应该只看到行程1，看不到行程2
```

#### 测试场景3：游客模式
```dart
// 1. 未登录状态创建行程
// 2. 行程应该只保存在本地
// 3. 登录后，本地行程应该可以同步到云端（需要额外实现迁移逻辑）
```

## 🗄️ 数据库修复

如果数据库中已经有一些没有 user_id 的行程记录，需要清理或修复：

### 选项1：删除无主行程（如果是测试数据）
```sql
-- 查看有多少无主行程
SELECT COUNT(*) FROM user_itineraries WHERE user_id IS NULL;

-- 删除无主行程（谨慎操作！）
DELETE FROM user_itineraries WHERE user_id IS NULL;
```

### 选项2：将无主行程分配给特定用户
```sql
-- 如果知道这些行程应该属于哪个用户
UPDATE user_itineraries 
SET user_id = '用户的UUID'
WHERE user_id IS NULL;
```

### 选项3：添加数据库约束（推荐）
```sql
-- 确保未来所有行程都必须有user_id
ALTER TABLE user_itineraries 
ALTER COLUMN user_id SET NOT NULL;

-- 添加外键约束
ALTER TABLE user_itineraries
ADD CONSTRAINT fk_user_itineraries_user_id
FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
```

## 🎯 验证清单

修复完成后，请验证以下内容：

- [ ] `saveToSupabase()` 方法包含 `user_id` 字段
- [ ] 未登录用户无法保存到云端（或有明确的错误处理）
- [ ] 新创建的行程在数据库中有正确的 `user_id`
- [ ] 用户A看不到用户B的行程
- [ ] 用户切换账号后，行程列表正确更新
- [ ] 协作行程功能仍然正常工作
- [ ] 本地缓存不会混淆不同用户的数据

## 📚 相关文件

需要一起检查的相关文件：

1. **数据模型**: 确认 ItineraryModel 是否需要添加 userId 字段
2. **UI层**: 确认创建行程的UI是否需要调整
3. **测试**: 添加用户隔离的单元测试和集成测试

## 🔗 相关问题

这个修复也会影响：
- 行程分享功能（通过 itinerary_members 表）
- 行程协作功能（Realtime 订阅）
- 行程列表的加载和过滤

确保这些功能在修复后仍然正常工作。

---

**修复优先级**: 🔴 **最高** - 这是数据安全和隐私的核心问题  
**预计工作量**: 30分钟（代码修改） + 1小时（测试验证）  
**风险等级**: 低（只是添加字段，不改变现有逻辑）

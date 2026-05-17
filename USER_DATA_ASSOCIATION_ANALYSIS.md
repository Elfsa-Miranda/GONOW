# 用户数据关联分析报告

## 📊 分析概览

经过详细的代码审查，以下是各个功能模块与用户账户的关联情况：

---

## ✅ 已关联用户账户的数据

### 1. **个人手账 (Diary)** ✅
- **文件**: `lib/features/diary/data/diary_provider.dart`
- **状态**: 已关联用户ID
- **数据表**: `public_diaries`
- **关联字段**: `user_id`
- **实现细节**:
  - 在 `fetchMyData()` 方法中使用 `.eq('user_id', userId)` 查询
  - 在 `saveDiary()` 方法中写入 `user_id` 字段
  - DiaryModel 包含 `userId` 字段
  - 支持草稿和已发布手账的用户隔离

**代码位置**:
```dart
// 第235行：查询用户手账
.eq('user_id', userId)

// 第130行：保存时关联用户
'user_id': userId,
```

---

### 2. **个人资产/账本 (Ledger)** ✅
- **文件**: `lib/features/ledger/data/ledger_provider.dart`
- **状态**: 已关联用户ID
- **数据表**: `ledger_books`, `ledger_expenses`, `ledger_tickets`
- **关联字段**: `user_id` (账本表)
- **实现细节**:
  - 账本表 `ledger_books` 有 `user_id` 字段
  - 在 `fetchLedgers()` 中使用 `.eq('user_id', uid)` 查询
  - 消费流水和票务通过 `ledger_id` 间接关联到用户
  - 支持多账本管理，每个账本属于特定用户

**代码位置**:
```dart
// 第66行：查询用户账本
.eq('user_id', uid)

// 第105行和469行：创建账本时关联用户
'user_id': uid,
```

---

### 3. **足迹地图 (Footprint)** ✅
- **文件**: `lib/features/profile/data/footprint_provider.dart`
- **状态**: 已关联用户ID
- **数据表**: `user_footprints`
- **关联字段**: `user_id`
- **实现细节**:
  - 在 `fetchFootprint()` 中使用 `.eq('user_id', uid)` 查询
  - 在 `_upsertFootprint()` 中写入 `user_id` 字段
  - 支持中国省份和世界国家的足迹记录

**代码位置**:
```dart
// 第41行：查询用户足迹
.eq('user_id', uid)

// 第117行：保存时关联用户
'user_id': uid,
```

---

### 4. **AI 聊天记录** ✅
- **文件**: `lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`
- **状态**: 已关联用户ID
- **数据表**: `ai_chat_messages`
- **关联字段**: `user_id`
- **实现细节**:
  - 在查询、插入、删除操作中都使用 `user_id`
  - 支持用户级别的聊天历史管理

**代码位置**:
```dart
// 第261行、318行、453行：查询和操作时使用user_id
.eq('user_id', userId)
```

---

## ⚠️ 部分关联或需要改进的数据

### 5. **行程规划 (Itinerary)** ❌ **发现严重问题！**
- **文件**: `lib/features/itinerary/data/itinerary_provider.dart`
- **状态**: **查询已关联，但保存时缺少 user_id！**
- **数据表**: `user_itineraries`, `itinerary_members`
- **关联字段**: `user_id`
- **问题分析**:
  - ✅ 已实现用户关联查询 (第757行)
  - ✅ 支持协作行程 (通过 `itinerary_members` 表)
  - ❌ **严重问题**：`saveToSupabase()` 方法在第1000行插入数据时**没有写入 user_id**！
  - ⚠️ 本地缓存使用 SharedPreferences，可能导致多用户数据混淆

**问题代码位置** (第1000-1007行):
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

**影响**:
- 新创建的行程无法关联到用户
- 用户切换账号后可能看到其他用户的行程
- 数据库中的行程记录没有所有者

---

### 6. **行程详细活动 (Activity Details)** ⚠️
- **文件**: `lib/features/itinerary/data/itinerary_provider.dart`
- **状态**: **部分关联**
- **数据表**: `activity_photos`
- **关联字段**: `user_id`
- **实现细节**:
  - 活动照片上传时关联了 `user_id` (第1491行)
  - 但活动本身是嵌套在行程JSON中，通过行程间接关联用户

**代码位置**:
```dart
// 第1491行：上传活动照片时关联用户
'user_id': userId,
```

---

## ❌ 未关联用户账户的数据

### 7. **行程详细活动的照片** ⚠️
- **文件**: `lib/features/itinerary/data/itinerary_provider.dart`
- **数据表**: `activity_photos`
- **状态**: 照片上传时关联了 user_id (第1490行)，但活动本身嵌套在行程JSON中
- **建议**: 保持当前设计，通过行程关联即可

### 8. **本地缓存数据** ⚠️
- **问题**: 多个Provider使用 SharedPreferences 存储本地缓存
- **影响范围**:
  - 行程数据 (`current_itinerary_json`, `my_itineraries_cache_$userId`)
  - 手账数据 (`diary_drafts_json`, `diary_my_diaries_json`)
- **风险**: 
  - 虽然部分缓存key包含userId，但如果用户切换账号，可能出现数据混淆
  - 游客模式下的数据在登录后可能丢失

---

## 🔧 需要改进的文件清单

### 高优先级改进

#### 1. **修复行程保存时缺少 user_id 的问题** 🔴 **必须立即修复**
**文件**: `lib/features/itinerary/data/itinerary_provider.dart`

**问题确认**:
- ✅ 已定位问题：`saveToSupabase()` 方法 (第1000行) 缺少 `user_id` 字段
- ❌ 当前代码在插入新行程时不写入用户ID
- ❌ 导致行程无法关联到创建者

**必须修改的方法**:
1. `saveToSupabase()` - 第1000行
2. 可能还需要检查其他创建行程的地方

**具体修复代码**:
```dart
// 第999-1007行，需要修改为：
Future<void> saveToSupabase(ItineraryModel model) async {
  final SupabaseClient client = Supabase.instance.client;
  final String? userId = client.auth.currentUser?.id;
  
  // 如果未登录，不应该保存到云端
  if (userId == null) {
    debugPrint('⚠️ 用户未登录，跳过云端保存');
    return;
  }
  
  await client.from(_tableName).insert(<String, dynamic>{
    'user_id': userId,  // ✅ 添加这一行！
    'title': model.title,
    'start_date': model.startDate.toIso8601String(),
    'end_date': model.endDate.toIso8601String(),
    'plan_data': model.planData,
    'created_at': DateTime.now().toIso8601String(),
    'version': 1,
  });
}
```

---

#### 2. **行程详细活动数据关联**
**文件**: `lib/features/itinerary/data/itinerary_provider.dart`

**当前状态**:
- 活动数据存储在行程的 `plan_data` JSON字段中
- 通过行程的 `user_id` 间接关联

**建议**:
- 保持当前设计（通过行程关联）
- 确保行程本身正确关联用户ID即可

---

### 中优先级改进

#### 3. **本地缓存隔离策略**
**涉及文件**:
- `lib/features/diary/data/diary_provider.dart`
- `lib/features/itinerary/data/itinerary_provider.dart`

**改进建议**:
```dart
// 统一的缓存键命名规范
final String cacheKey = 'feature_name_${userId ?? "guest"}_data';

// 在用户登出时清理缓存
Future<void> clearUserCache() async {
  final prefs = await SharedPreferences.getInstance();
  final userId = _supabase.auth.currentUser?.id ?? 'guest';
  await prefs.remove('diary_drafts_$userId');
  await prefs.remove('my_itineraries_cache_$userId');
  // ... 清理其他缓存
}
```

---

#### 4. **游客模式数据迁移**
**涉及所有Provider**

**改进建议**:
- 实现游客数据迁移机制
- 当游客登录/注册后，将本地数据关联到新用户ID
- 提供数据导入功能

```dart
Future<void> migrateGuestData(String newUserId) async {
  // 1. 读取游客模式下的本地数据
  // 2. 将数据关联到新用户ID
  // 3. 上传到云端
  // 4. 清理游客缓存
}
```

---

## 📋 数据库表结构建议

### 需要确认的表结构

#### 1. `user_itineraries` 表
```sql
-- 确保包含以下字段
CREATE TABLE user_itineraries (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  plan_data JSONB,
  status TEXT,
  cover_image_url TEXT,
  version INTEGER DEFAULT 1,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 添加索引
CREATE INDEX idx_user_itineraries_user_id ON user_itineraries(user_id);
```

#### 2. `itinerary_members` 表（协作功能）
```sql
-- 已存在，用于多人协作
CREATE TABLE itinerary_members (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  itinerary_id UUID NOT NULL REFERENCES user_itineraries(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role TEXT DEFAULT 'editor',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  UNIQUE(itinerary_id, user_id)
);
```

---

## 🎯 总结与行动计划

### 数据关联状态总结

| 功能模块 | 关联状态 | 数据表 | 优先级 |
|---------|---------|--------|--------|
| 个人手账 | ✅ 完整 | `public_diaries` | - |
| 个人账本 | ✅ 完整 | `ledger_books` | - |
| 足迹地图 | ✅ 完整 | `user_footprints` | - |
| AI聊天 | ✅ 完整 | `ai_chat_messages` | - |
| 行程规划 | ⚠️ 需检查 | `user_itineraries` | 🔴 高 |
| 行程活动 | ⚠️ 间接关联 | 嵌套在行程中 | 🟡 中 |
| 本地缓存 | ⚠️ 需改进 | SharedPreferences | 🟡 中 |

### 立即需要检查的代码

1. **搜索行程保存方法**
   ```bash
   # 在 itinerary_provider.dart 中搜索
   - saveItinerary
   - updateItinerary  
   - upsert
   ```

2. **验证数据库写入**
   - 检查所有 `.insert()` 和 `.upsert()` 调用
   - 确认包含 `user_id` 字段

3. **测试多用户场景**
   - 创建两个测试账号
   - 验证数据隔离
   - 测试账号切换

---

## 📝 下一步行动

### 第一步：完整读取行程Provider
由于 `itinerary_provider.dart` 文件被截断，需要：
1. 读取完整文件内容
2. 找到所有保存/更新行程的方法
3. 验证 `user_id` 字段的写入

### 第二步：修复发现的问题
根据完整代码分析结果，修复任何缺失的 `user_id` 关联

### 第三步：添加数据迁移功能
实现游客数据到正式账号的迁移机制

---

**生成时间**: 2026-05-17  
**分析范围**: 所有核心功能模块的用户数据关联

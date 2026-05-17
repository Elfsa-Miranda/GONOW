# 足迹地图数据库集成指南

## 正确架构

足迹功能使用 **独立的 FootprintProvider** 和 **user_footprints 表**：

```
FootprintProvider  →  user_footprints 表  （足迹数据）
ProfileProvider    →  profiles 表         （昵称、头像）
```

这样设计的优点：
- ✅ 职责分离，代码更清晰
- ✅ 足迹数据与用户资料解耦
- ✅ 未来扩展足迹功能（分享、统计）更方便
- ✅ 可以独立管理足迹相关的权限和策略

## 数据库表结构

确保 Supabase 的 `user_footprints` 表存在并包含以下字段：

```sql
-- 创建 user_footprints 表
CREATE TABLE IF NOT EXISTS user_footprints (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  visited_china JSONB DEFAULT '[]'::jsonb,
  visited_world JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建索引以提高查询性能
CREATE INDEX IF NOT EXISTS idx_user_footprints_user_id ON user_footprints(user_id);

-- 启用 RLS (Row Level Security)
ALTER TABLE user_footprints ENABLE ROW LEVEL SECURITY;

-- 创建策略：用户只能访问自己的足迹数据
CREATE POLICY "Users can view their own footprints"
  ON user_footprints FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own footprints"
  ON user_footprints FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own footprints"
  ON user_footprints FOR UPDATE
  USING (auth.uid() = user_id);
```

字段说明：
- `user_id`: UUID 类型，主键，关联到 auth.users 表
- `visited_china`: JSONB 类型，存储已点亮的中国省份/直辖市名称
- `visited_world`: JSONB 类型，存储已点亮的世界国家名称
- 使用 JSONB 类型的优点：
  - ✅ Supabase 直接返回 `List<dynamic>`，无需手动解析
  - ✅ 支持 `@>` 包含查询等高级功能
  - ✅ 跨平台兼容性更好
  - ✅ Flutter 代码解析更简单

## 实现步骤

所有代码已完成，只需设置数据库：

1. **创建数据库表**
   - 登录 Supabase Dashboard
   - 进入 SQL Editor
   - 执行上面的 CREATE TABLE 语句

2. **测试功能**
   - 运行应用并登录
   - 进入「我的」页面
   - 点击地图上的省份/国家
   - 观察控制台日志
   - 重启应用验证数据持久化

## 注意事项

1. **数据类型转换**：Supabase 返回的 JSONB 数组是 `List<dynamic>`，需要转换为 `List<String>`
2. **空值处理**：如果数据库中没有数据，应该返回空列表而不是 null
3. **乐观更新**：FootprintProvider 使用乐观更新策略，先更新 UI，后台静默同步数据库
4. **错误处理**：网络错误时不会阻塞 UI，错误信息会打印到控制台
5. **数据隔离**：每个用户的足迹数据通过 `user_id` 隔离，RLS 策略确保安全性

## 可选优化

FootprintProvider 已经实现了以下优化：

### 1. ✅ 乐观更新
- UI 立即响应用户操作
- 数据库同步在后台静默进行
- 不阻塞 UI 线程

### 2. ✅ 数据快照
- 在异步操作前创建数据快照
- 防止异步期间列表被修改

### 3. 可选：离线支持
可以使用本地存储（如 SharedPreferences）作为缓存，在网络恢复时同步。

### 4. 可选：统计功能
可以在 UI 中显示用户的旅行统计：
- 已访问的省份/国家数量
- 旅行覆盖率
- 旅行足迹排名等

## 实现状态

✅ **已完成！** 所有代码修改已经实现：

### 已完成的修改

1. ✅ **FootprintProvider** (`lib/features/profile/data/footprint_provider.dart`)
   - 已实现 `visitedChina` 和 `visitedWorld` 字段
   - 已实现 `fetchFootprint()` 方法从 `user_footprints` 表加载数据
   - 已实现 `updateFootprints()` 方法保存数据
   - 已实现 `toggleChina()` 和 `toggleWorld()` 方法用于单个省份/国家的切换
   - 使用乐观更新策略（先更新 UI，后台静默同步）

2. ✅ **ProfileScreen** (`lib/features/profile/presentation/screens/profile_screen.dart`)
   - 已使用 `Consumer<FootprintProvider>` 替代硬编码数据
   - 已在 `initState` 中调用 `fetchFootprint()` 加载历史数据
   - 已正确绑定 `onDataChanged` 回调

3. ✅ **main.dart** (`lib/main.dart`)
   - 已注册 `FootprintProvider` 到 `MultiProvider`
   - 已在用户登录时调用 `fetchFootprint()` 加载数据

### 下一步：数据库设置

只需在 Supabase Dashboard 中执行上面的 SQL 语句创建 `user_footprints` 表。

### 测试步骤

1. 运行应用并登录
2. 进入「我的」页面，点击地图上的省份/国家
3. 观察控制台日志，应该看到 `[FootprintProvider] 足迹同步云端成功`
4. 重启应用，检查数据是否保存
5. 切换账号，检查数据是否隔离

## 总结

足迹地图数据库集成已完成。用户点亮的省份/国家会自动保存到 `profiles` 表的 `visited_china` 和 `visited_world` 字段中，使用 JSONB 类型存储。

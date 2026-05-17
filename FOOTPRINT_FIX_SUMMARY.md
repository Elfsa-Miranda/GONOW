# 足迹地图数据库集成修复总结

## 问题诊断

错误信息：`Could not find the 'visited_china' column of 'profiles' in the schema cache`

**根本原因：** 代码架构混乱，`ProfileProvider` 错误地尝试向 `profiles` 表写入足迹数据，但该表没有 `visited_china` 和 `visited_world` 字段。

## 正确架构

```
FootprintProvider  →  user_footprints 表  （足迹数据）
ProfileProvider    →  profiles 表         （昵称、头像）
```

## 已完成的修复

### 1. ProfileProvider (`lib/features/profile/data/profile_provider.dart`)

**删除了错误的代码：**
- ❌ 删除了 `visitedChina` 和 `visitedWorld` 字段
- ❌ 删除了 `updateFootprints()` 方法（错误地写入 profiles 表）
- ❌ 删除了 `fetchProfile()` 中加载足迹数据的代码

**保留的功能：**
- ✅ 昵称管理
- ✅ 头像上传和管理
- ✅ 邮箱绑定
- ✅ 账号注销

### 2. ProfileScreen (`lib/features/profile/presentation/screens/profile_screen.dart`)

**修改内容：**
- ✅ 导入 `FootprintProvider`
- ✅ 将 `Consumer<ProfileProvider>` 改为 `Consumer<FootprintProvider>`
- ✅ 在 `initState` 中调用 `context.read<FootprintProvider>().fetchFootprint()`
- ✅ 使用 `footprint.visitedChina` 和 `footprint.visitedWorld`
- ✅ 调用 `footprint.updateFootprints()` 保存数据

### 3. main.dart (`lib/main.dart`)

**修改内容：**
- ✅ 导入 `FootprintProvider`
- ✅ 在 `MultiProvider` 中注册 `ChangeNotifierProvider<FootprintProvider>`
- ✅ 在用户登录时调用 `footprintProvider.fetchFootprint()`

## FootprintProvider 的优势

`lib/features/profile/data/footprint_provider.dart` 已经实现了完整的功能：

1. **正确的表名：** 使用 `user_footprints` 表
2. **完整的 CRUD：**
   - `fetchFootprint()` - 从数据库加载历史数据
   - `updateFootprints()` - 批量更新
   - `toggleChina()` - 切换单个省份
   - `toggleWorld()` - 切换单个国家
3. **乐观更新：** 先更新 UI，后台静默同步
4. **数据快照：** 防止异步期间数据被修改
5. **错误处理：** 网络错误不阻塞 UI

## 数据库设置

在 Supabase Dashboard 的 SQL Editor 中执行：

```sql
-- 创建 user_footprints 表
CREATE TABLE IF NOT EXISTS user_footprints (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  visited_china JSONB DEFAULT '[]'::jsonb,
  visited_world JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_user_footprints_user_id ON user_footprints(user_id);

-- 启用 RLS
ALTER TABLE user_footprints ENABLE ROW LEVEL SECURITY;

-- 创建策略
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

## 测试步骤

1. ✅ 代码编译无错误
2. 在 Supabase 中执行上面的 SQL
3. 运行应用并登录
4. 进入「我的」页面
5. 点击地图上的省份/国家
6. 观察控制台日志：`[FootprintProvider] 足迹同步云端成功`
7. 重启应用，验证数据持久化
8. 切换账号，验证数据隔离

## 关键要点

1. **职责分离：** 足迹功能完全由 `FootprintProvider` 负责，`ProfileProvider` 不参与
2. **独立表：** 使用 `user_footprints` 表，不是 `profiles` 表
3. **JSONB 类型：** 比 TEXT[] 更好，Supabase 直接返回 `List<dynamic>`
4. **乐观更新：** UI 响应快，用户体验好
5. **RLS 安全：** 每个用户只能访问自己的数据

## 修复完成 ✅

所有代码修改已完成，编译无错误。只需在 Supabase 中创建 `user_footprints` 表即可使用。

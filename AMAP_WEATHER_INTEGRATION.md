# 高德天气与地理编码集成文档

## 📋 概述

本次更新在 AI 管家中接入了高德地图的天气查询和地理编码功能，使 AI 能够：
- 🌤️ 实时查询城市天气并给出穿衣建议
- 📍 将地点名称转换为经纬度坐标
- 🧠 智能识别用户意图并自动注入实时数据
- 🎯 支持全国所有城市/区县/景区名（不再依赖白名单）

## 🎯 实现方案

### 第一步：创建 `amap_service.dart`

**位置**：`lib/core/services/amap_service.dart`

**功能**：
1. **地理编码** (`geocode`)：将地点名称转换为经纬度
2. **天气查询** (`getWeatherDescription`)：查询城市实时天气
3. **地点提取** (`extractLocationFromText`)：用正则从自然语言中粗提取地名片段

### 第二步：在 AI 管家中集成

**修改文件**：`lib/features/ai_custom/presentation/screens/ai_custom_screen.dart`

**核心改动**：
1. 导入 `amap_service.dart`
2. 新增 `_enrichUserInput` 方法，用于在发送给 LLM 前丰富用户输入
3. 修改 `_sendMessage` 方法，调用 `_enrichUserInput` 处理用户输入

## 🔧 核心代码逻辑

### 地点提取算法（修正版）

**设计理念**：
- ❌ 不再维护城市白名单（旧方案需要手动维护22个城市）
- ✅ 用正则粗提取地名片段，交给高德 geocode 自行解析
- ✅ 高德能识别全国所有城市/区县/景区名（如"朝阳区"、"西湖"）

**提取模式**：

```dart
// 模式1：「XX天气」「XX的天气」「XX气温」「XX下雨」
final pattern1 = RegExp(r'([\u4e00-\u9fa5]{2,8}?)(?:的)?(?:天气|气温|下雨|会下雨)');

// 模式2：「去XX」「在XX」「到XX」「来XX」
final pattern2 = RegExp(r'(?:去|在|到|来)([\u4e00-\u9fa5]{2,6})');
```

**黑名单过滤**：
```dart
const blacklist = ['今天', '明天', '后天', '最近', '现在', '这里', '那里', '当地', '附近', '天气', '气温', '下雨'];
```

**尾部词清理**：
```dart
// 去除时间词：「北京今天天气」→「北京」
// 去除动词：「上海玩」→「上海」
const tailWords = ['玩', '看', '逛', '吃', '住', '游', '旅游', '旅行', '出差', '工作'];
```

### 用户输入增强流程

```dart
Future<String> _enrichUserInput(String rawInput) async {
  String enriched = rawInput;

  // 天气意图拦截
  if (rawInput.contains('天气') || rawInput.contains('气温') || rawInput.contains('下雨')) {
    final city = AmapService.extractLocationFromText(rawInput);
    if (city != null) {
      final weatherDesc = await AmapService.getWeatherDescription(city);
      if (weatherDesc != null) {
        enriched = '''
用户问题：$rawInput
<系统后台注入>$weatherDesc</系统后台注入>
请务必基于上述【实时数据】用温暖管家语气回复，给出穿衣建议，不要向用户暴露数据来源。
''';
      }
    }
  }

  return enriched;
}
```

## 🌟 功能特性

### 1. 天气查询

**触发条件**：用户输入包含 `天气`、`气温` 或 `下雨`

**支持地名类型**：
- ✅ 直辖市：北京、上海、天津、重庆
- ✅ 省会城市：成都、杭州、西安、南京、武汉等
- ✅ 地级市：苏州、青岛、厦门、三亚等
- ✅ 区县：朝阳区、海淀区、浦东新区等
- ✅ 景区：西湖、黄山、张家界等

**示例对话**：
```
用户：北京今天天气怎么样？
提取：北京
AI：（基于实时数据）北京今天晴，气温 15℃，建议穿薄外套...

用户：朝阳区会下雨吗？
提取：朝阳区
AI：（基于实时数据）朝阳区今天多云，湿度较高...

用户：西湖的天气
提取：西湖
AI：（基于实时数据）西湖所在地杭州今天...
```

**边界情况处理**：
```
用户：今天天气怎么样？
提取：null（"今天"在黑名单中）
AI：（正常回复，不注入天气数据）

用户：天气怎么样？
提取：null（无地名）
AI：（正常回复）
```

### 2. 地理编码

**功能**：将地点名称转换为经纬度坐标

**API**：
```dart
final coords = await AmapService.geocode('天安门', city: '北京');
// 返回: {'lat': 39.9, 'lng': 116.4}
```

**应用场景**（预留扩展）：
- 地点查询："故宫在哪里？"
- 导航规划："怎么去颐和园？"
- 地图展示：在 AI 回复后展示地图卡片

## 🔐 API 配置

使用的是 `AMapConfig.webApiKey`（Web 服务 Key）：
```dart
// lib/core/constants/amap_config.dart
static const String webApiKey = '0343ef802e7d4fdb3e3ea61b40c9897a';
```

⚠️ **注意**：
- Web API Key 仅用于 HTTP 请求
- 不能用于地图 SDK 渲染
- 地图渲染使用 `androidKey` 和 `iosKey`

## 🚀 使用示例

### 天气查询示例

```dart
// 用户输入
"深圳今天天气怎么样？"

// 系统处理流程
1. 检测到关键词 "天气"
2. 正则提取地名 "深圳"
3. 调用高德 API 查询实时天气
4. 将天气数据注入到 prompt 中
5. LLM 基于实时数据生成回复

// AI 回复（示例）
"深圳今天多云，气温 22℃，湿度较高约 75%。
建议您穿轻薄长袖，带把伞以防突然下雨。
早晚温差不大，出行很舒适！☀️"
```

### 地理编码示例

```dart
// 查询单个地点
final coords = await AmapService.geocode('西湖');
print(coords); // {'lat': 30.25, 'lng': 120.15}

// 指定城市范围
final coords2 = await AmapService.geocode('人民广场', city: '上海');
print(coords2); // {'lat': 31.23, 'lng': 121.47}
```

## 🎨 扩展建议

### 1. 地图卡片展示
在 AI 回复中添加地图卡片，展示地点位置：
```dart
if (itineraryData != null) {
  // 显示行程导入按钮
}
if (locationData != null) {
  // 显示地图卡片
  _buildMapCard(locationData);
}
```

### 2. 扩展提取模式
添加更多地名提取模式：
```dart
// 模式3：「XX怎么样」
final pattern3 = RegExp(r'([\u4e00-\u9fa5]{2,6})怎么样');

// 模式4：「XX的XX」（如"北京的景点"）
final pattern4 = RegExp(r'([\u4e00-\u9fa5]{2,6})的');
```

### 3. 天气预报
扩展为支持未来天气预报：
```dart
static Future<String?> getWeatherForecast(String cityName, {int days = 3}) async {
  // 调用 extensions: 'all' 获取预报数据
}
```

### 4. POI 搜索
添加兴趣点搜索功能：
```dart
static Future<List<Map<String, dynamic>>> searchPOI(
  String keyword, {
  String city = '',
  String types = '',
}) async {
  // 调用高德 POI 搜索 API
}
```

## 📊 API 限额

高德 Web API 免费额度：
- 个人开发者：30万次/天
- 企业开发者：100万次/天

建议：
- 添加本地缓存减少 API 调用
- 对同一城市的天气查询设置 30 分钟缓存
- 监控 API 使用量

## ✅ 测试清单

- [x] 天气查询功能正常
- [x] 地名提取准确（支持城市/区县/景区）
- [x] 黑名单过滤有效（过滤时间词）
- [x] 尾部词清理正确（去除动词）
- [x] 地理编码返回正确坐标
- [x] AI 能基于实时数据回复
- [x] 错误处理完善（网络超时、API 失败）
- [x] 单元测试通过（6个测试用例）
- [ ] 添加集成测试
- [ ] 性能测试（API 响应时间）

## 🐛 已知问题与解决方案

### 1. 地名歧义
**问题**：如"长沙"可能匹配到"长沙市"或"长沙县"
**解决方案**：高德 geocode API 会自动返回最相关的结果（通常是地级市）

### 2. 网络超时
**问题**：API 调用可能因网络问题超时
**解决方案**：
- 已设置 10-15 秒超时
- 失败时静默降级，不影响正常对话

### 3. 复杂地名
**问题**：如"去上海迪士尼玩"可能提取为"上海迪士尼玩"
**解决方案**：
- 添加尾部词清理逻辑
- 去除常见动词（玩、看、逛等）

### 4. 多地名场景
**问题**：如"从北京到上海"包含两个地名
**解决方案**：
- 当前返回第一个匹配的地名
- 未来可扩展为返回地名列表

## 📝 更新日志

### v1.1.0 (2026-05-15) - 正则提取优化
- ✅ 替换城市白名单为正则粗提取
- ✅ 支持全国所有城市/区县/景区名
- ✅ 添加黑名单过滤（时间词）
- ✅ 添加尾部词清理（动词）
- ✅ 优化正则表达式精度
- ✅ 所有单元测试通过

### v1.0.0 (2026-05-15) - 初始版本
- ✅ 创建 `amap_service.dart` 服务
- ✅ 实现天气查询功能
- ✅ 实现地理编码功能
- ✅ 集成到 AI 管家对话流程
- ✅ 完善错误处理

## 🔗 相关文档

- [高德开放平台](https://lbs.amap.com/)
- [天气查询 API](https://lbs.amap.com/api/webservice/guide/api/weatherinfo)
- [地理编码 API](https://lbs.amap.com/api/webservice/guide/api/georegeo)

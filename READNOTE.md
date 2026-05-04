# GoNow 项目阅读笔记（READNOTE）

> 供日后快速回忆项目结构、数据流与关键文件。生成于对当前代码库的通读，随代码变更需自行更新。

## 1. 项目是什么

**GoNow** 是一款 **Flutter 跨端旅行应用**（`pubspec.yaml` 中包名 `gonow`）。核心能力包括：发现页内容、**AI 定制行程**（DeepSeek）、**行程展示与地图**（高德 / Google Maps 双栈）、**Supabase** 做认证与数据同步、本地 `SharedPreferences` 缓存当前行程等。

## 2. 技术栈摘要

| 类别 | 依赖/服务 |
|------|-----------|
| UI / 状态 | Flutter Material 3、`provider` |
| 后端 / 数据 | `supabase_flutter`（Auth、Postgres 表、Storage） |
| AI | `http` 调用 **DeepSeek** `chat/completions`（`ai_custom_screen.dart`） |
| 地图 | `amap_flutter_map` + `amap_flutter_base`、`google_maps_flutter`；`geolocator` 定位；`amap_config` 区分 **SDK Key** 与 **Web 服务 Key** |
| 展示 | `flutter_markdown`、`cached_network_image`、`flutter_staggered_grid_view`、`reorderable_grid_view`、`syncfusion_flutter_maps`、`image_picker`、`url_launcher` |

**安全提示：** Supabase URL/anon key、高德 Key、DeepSeek API Key 等目前写在源码中，上线前应改为构建期环境变量或远端下发，并轮换已暴露的密钥。

## 3. 仓库顶层结构（与业务相关部分）

- **`lib/`** — 全部 Dart 业务与 UI（见下节）。
- **`android/`、`ios/`、`web/`、`windows/`、`linux/`、`macos/`** — 各端 Flutter 工程与原生配置。
- **`test/`** — 默认 widget 测试等。
- 根目录有多份历史说明类 Markdown（如 `QUICK_REFERENCE.md`、`IMPLEMENTATION_SUMMARY.md` 等），与 `READNOTE` 不同：本文件偏「结构 + 职责」总览。

## 4. `lib/` 目录与职责

```
lib/
├── main.dart                    # 入口：Supabase.initialize、MultiProvider（含 Ledger/Diary 等）、AuthGate
├── core/
│   ├── constants/               # amap_config、api_keys、ai_config（DeepSeek 等）、app_colors
│   ├── data/
│   │   └── mock_database.dart   # 盲盒城市等本地 mock（表不可用时兜底）
│   ├── models/
│   │   └── city_model.dart
│   ├── providers/
│   │   └── travel_provider.dart # 发现域：盲盒/免签/国际/文化习俗等
│   ├── services/
│   │   └── travel_service.dart  # Supabase：blind_box_cities、visa_free_countries、international_countries
│   ├── theme/
│   │   └── app_theme.dart       # 全局 Material3 主题
│   └── utils/
│       └── image_compress_util.dart
└── features/
    ├── auth/
    │   ├── data/auth_provider.dart
    │   └── presentation/auth_screen.dart
    ├── main_nav/
    │   ├── data/main_nav_provider.dart    # Tab 索引、AI 底栏 token、pending 提示词
    │   ├── presentation/screens/main_screen.dart
    │   └── presentation/widgets/          # custom_bottom_bar、custom_fab
    ├── discover/
    │   └── presentation/screens/          # discover_screen、blind_box_screen
    ├── itinerary/
    │   ├── data/itinerary_provider.dart
    │   └── presentation/screens/itinerary_screen.dart
    ├── diary/
    │   ├── data/diary_provider.dart       # 手账列表/社区、Supabase 与本地逻辑
    │   └── presentation/
    │       ├── screens/diary_center_screen.dart、diary_detail_screen.dart
    │       └── widgets/diary_config_sheet.dart
    ├── ai_custom/
    │   └── presentation/screens/ai_custom_screen.dart
    ├── ledger/                          # 旅行账本（AA + 机酒票根 UI）
    │   ├── domain/ledger_model.dart
    │   ├── utils/expense_calculator.dart
    │   ├── data/ledger_provider.dart
    │   └── presentation/screens/ledger_screen.dart
    ├── common/
    │   └── presentation/widgets/full_screen_photo_gallery.dart
    ├── ootd/
    │   └── presentation/screens/ootd_screen.dart   # 从「我的」衣橱入口 push，非底栏 Tab
    └── profile/
        ├── data/footprint_provider.dart               # 足迹状态管理（国内/海外已点亮地区）
        └── presentation/
            ├── screens/profile_screen.dart            # 足迹卡、资产入口（手账 Tab / 账本 / 衣橱）
            └── widgets/footprint_map_widget.dart      # 足迹地图交互组件（点亮/缩放/全屏）
```

**规模提示：** `itinerary_screen.dart`、`discover_screen.dart`、`diary_detail_screen.dart` 为超大单文件，改功能时建议先搜索关键词（如 `TripMode`、`_MapSource`、`isLazyPool`）再动刀。

## 5. 应用启动与认证

1. `main.dart` 注册 `MainNavProvider`、`TravelProvider`（`fetchCulturalCustoms()`）、`ItineraryProvider`（`fetchActiveItinerary()`）、`AuthProvider`、`DiaryProvider`、`LedgerProvider`。
2. `AuthGate` 监听 `Supabase.instance.client.auth.onAuthStateChange`：有 `session` → `MainScreen()`，否则 → `AuthScreen()`。
3. `AuthProvider`：`signUp` / `signIn` / 登出等，成功时维护 `profiles` 表昵称等。

## 6. 主导航与 AI 入口

- **`MainScreen`** 使用 `IndexedStack` 固定四个子页（顺序与底栏一致）：
  1. `DiscoverScreen`（发现）
  2. `ItineraryScreen`（行程）
  3. `DiaryCenterScreen`（手账中心）
  4. `ProfileScreen`（我的：足迹、旅行账本、手账 Tab 切换、衣橱等）
- **`OotdScreen`**：不在底栏；由 `ProfileScreen`（衣橱）`Navigator.push` 打开。
- **中央 FAB** `CustomFab`：通过 `MainNavProvider.requestOpenAiSheet()` 提升 `openAiRequestToken`，`MainScreen` 在 `addPostFrameCallback` 里 `showModalBottomSheet` 弹出 **`AiCustomScreen`**。
- **默认 FAB 行为**：若无 `pendingAiPrompt`，会写入示例文案并 `shouldAutoSendAi = true`，打开 AI 后自动带入发送逻辑（与 `MainNavProvider` 配合）。

## 7. 行程数据层（`ItineraryProvider`）要点

- **模型：** `ItineraryModel`、`DayPlan`、`ActivityItem`；活动类型约束含 `transport` / `hotel` / `scenic` / `food` 等。
- **模式：** `TripMode.planning`（行程前）与 `TripMode.traveling`（行程中）等，用于 UI 与体验切换。
- **持久化：** `SharedPreferences` 键 `current_itinerary_json`；云端表名常量 **`itineraries`**（`_tableName`），另有照片相关 **`itinerary_photos` Storage**、**`activity_photos`** 表等。
- **与 AI 联动：** AI 返回的 JSON 经解析为 `ItineraryModel` 后 `saveItinerary`；详情页对话时会把当前 `planData` 编码进 system prompt 做「改行程」模式（见 `AiCustomScreen._buildSystemPrompt`）。

## 8. AI 定制页（`AiCustomScreen`）要点

- **`ChatMessage`**：角色、`text`、可选 `itineraryData`（解析出的行程 JSON）、错误标记。
- **构造参数：** `source`（场景标签）、`initialPrompt`（可选初始提示）。
- **请求：** DeepSeek API，system prompt 要求分段输出：用户可见 Markdown + 末尾 `` ```json `` 块供系统解析。
- **历史：** 登录用户可向 **`ai_chat_messages`** 表插入用户/AI 消息（含 `itinerary_data`），并支持加载历史（具体逻辑以文件内实现为准）。
- **导入行程：** `_importPlan` → 日期选择 → `ItineraryProvider.saveItinerary` → `Navigator.pop(true)` → `MainNavProvider.goToItineraryTab()`。

## 9. 发现与旅行数据（`TravelProvider` + `TravelService`）

- **盲盒城市：** 表 `blind_box_cities` → `CityModel` 列表。
- **免签：** `visa_free_countries`，按洲分组。
- **国际盲盒：** `international_countries`。
- **文化习俗：** `travel_provider` 内直接 `from('cultural_customs').select()`。

`mock_database.dart` 提供大量静态城市卡片数据，作为列表或 fallback 使用（以实际页面引用为准）。

## 10. Supabase 表名速查（代码中出现过的）

| 表/存储 | 用途（简要） |
|---------|----------------|
| `profiles` | 用户资料、注册/登录 upsert |
| `itineraries` | 行程主数据 |
| `ai_chat_messages` | AI 对话与可选行程 JSON |
| `blind_box_cities` / `visa_free_countries` / `international_countries` | 发现页数据 |
| `cultural_customs` | 文化习俗 |
| `public_diaries` | 手账主数据（`DiaryProvider`） |
| `itinerary_photos` | Storage 桶名（行程图片路径） |
| `activity_photos` | 活动级照片元数据 |

## 11. 与 `pubspec.yaml` 的对应关系

主要依赖见 `pubspec.yaml`：`provider`、`supabase_flutter`、`http`、`flutter_markdown`、双地图 SDK、`geolocator`、`shared_preferences`、`image_picker`、`flutter_staggered_grid_view`、`reorderable_grid_view`、`syncfusion_flutter_maps` 等。新增能力时优先查 `core/services` 与各 feature 内封装，避免重复造轮子。

## 12. 维护本 READNOTE 的建议

- 增删 feature 或重命名表/Provider 时，同步改本节与第 4、10 节。
- 大文件拆分或路由改造后，更新第 5、6 节「启动与导航」描述。

---

*本文档仅描述结构与职责，不替代具体 API 字段与行级实现；以仓库内源码为准。*

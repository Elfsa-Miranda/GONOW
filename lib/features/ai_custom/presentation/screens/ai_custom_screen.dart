import 'dart:async';
import 'dart:convert';

import 'package:gonow/core/constants/ai_config.dart';
import 'package:gonow/core/services/amap_service.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatMessage {
  final String role;
  final String text;
  final Map<String, dynamic>? itineraryData;
  final bool isError;

  const ChatMessage({
    required this.role,
    required this.text,
    this.itineraryData,
    this.isError = false,
  });
}

class AiCustomScreen extends StatefulWidget {
  final String source;
  final String? initialPrompt;
  /// 若为 true，sheet 打开后会立即将 [initialPrompt] 自动发送。
  /// 仅由外部业务逻辑（非 FAB 直接点击）传入 true，FAB 路径始终为 false。
  final bool autoSend;

  const AiCustomScreen({
    super.key,
    this.source = '底部导航栏',
    this.initialPrompt,
    this.autoSend = false,
  });

  @override
  State<AiCustomScreen> createState() => _AiCustomScreenState();
}

class _AiCustomScreenState extends State<AiCustomScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  String? _hintPrompt;
  
  // 与发现页同源的 hint 列表
  static const List<String> _searchHints = <String>[
    '下个月看海，人少一点',
    '带父母去北京玩五天',
    '去新疆看雪需要准备什么',
    '周末去哪能吃地道火锅',
    '预算3000元，适合情侣去哪',
    '江浙沪 2 天自驾游',
    '曼谷+普吉岛 7天避坑',
    '独自旅行，治安好的古镇',
    '带 5 岁小孩去哪度假',
    '川西自驾需要防高反吗',
  ];
  int _hintIndex = 0;
  Timer? _hintTimer;
  
  bool _showAllHistory = false;
  /// 标记自动发送是否已执行，保证整个 widget 生命周期内只自动发送一次。
  bool _autoSendDone = false;
  http.Client? _activeClient;
  int _requestSeq = 0;
  int? _activeRequestId;
  List<ChatMessage> _messages = <ChatMessage>[
    const ChatMessage(
      role: 'ai',
      text:
          '👋 你好！我是你的专属智能旅游管家。\n\n请告诉我你的**目的地**、**游玩天数**和**大致预算**（例如：*“去大理玩 4天，预算 3000”*），我来为你量身定制专属行程！\n\n💡 你也可以补充偏好（如亲子、拍照、美食、慢节奏），我会一起考虑。',
      isError: false,
    ),
  ];

  // 常量控制最大保留条数
  static const int _maxHistoryCount = 50;

  // 组装系统提示词的方法 (支持传入当前行程 JSON)
  String _buildSystemPrompt(String? currentPlanJson, String source) {
    // 1. 【原封不动】你原本的完美基础 Prompt
    final String basePrompt = '''你是一个温暖、专业的智能旅游管家。当用户提出需求时，请按照以下两个部分严格输出：
========== 【最高优先级：深度意图识别与渐进式交互机制】 ==========
在响应任何用户输入前，你必须首先深度分析用户的【真实意图】，并严格采取对应的交互策略。🚨全局警告：不要盲目生成完整行程，也不要无休止地提问！

【阶段一：探索与推荐期（意图：求推荐、找灵感、找特定地点的单项好去处）】
触发条件（满足其一即可）：
1. 泛目的地探索：用户未指定目的地（如：“周末去哪玩”、“哪里看海好”）。
2. 本地单项推荐：用户虽然指定了具体城市，但询问的是【特定主题】或【单项活动】，并没有明确要求规划包含时间轴的路线（如：“深圳去哪吃火锅”、“北京有什么好逛的博物馆”、“广州必吃美食”）。
行为准则：
1. 绝对禁止：在这个阶段，【绝对不允许】生成按时间轴排列的每日详细行程（Day 1, Day 2...），【绝对不允许】输出任何 JSON 代码块！但是如果用户选中了你提出的方案，请务必去实现方案内容（判断意图是否跳出阶段一转到阶段二或三）
2. 结构化种草：用 Markdown 结构化列出 7-8 个精准的推荐选项（城市，或者是具体城市的某几家店铺/景点）。如果用户只是问吃什么，你可以先概览性的总结当地有哪些特色美食，让用户对当地美食有一个非常全面的了解。然后如果用户让你做店铺推荐再分类做评分高人气高的店铺推荐。
3. 选项格式示例（针对本地店铺/景点）：
   - 📍 [店铺/景点名称] | 💰 预估人均/门票
   - 🌟 核心亮点：（一句话概括它的绝杀特色）
4. 引导话术：在回复的最后，必须用亲切的语气主动抛出钩子，引导用户进入下一步：“这几个地方有您心动想去的吗？如果您选中了某一家，或者需要我为您以它为中心，串联一个包含周边景点游玩的【完整一日/多日行程规划】，随时告诉我哦！”
5. 如果给出一个地点的n个游玩路线的方案，务必标明方案n，然后如果用户回答：方案n或者n就直接开始那个方案的景点推荐，满意的话就进入阶段二
6. 如果用户突然问到另一个地点，无需问用户是否执着于上一个地点的游玩，因为用户可以同时保存多份景点的规划，你只需要直接进行另一个地点规划即可

【阶段二：明确规划期（意图：明确要求排期、要路线、要完整行程）】
触发条件：1.用户明确表达了需要“行程”、“路线”、“规划”、“怎么安排”、“怎么玩（包含天数）”等全局规划意图，或者在上一步的推荐后明确要求把地点连成线（如：“带父母去北京玩五天经典路线”、“就去你推荐的第二家火锅店，帮我安排个深圳周末两日游”）。
2.用户在你的“阶段一”推荐后，明确做出了选择（如：“就选方案二”、“按第一个安排”）。
行为准则：
彻底激活下方的【第一部分：回复给用户看的文本】与【第二部分：留给系统的隐藏 JSON】的严格双通道输出模式，为其生成带有精确时间轴的详尽行程。

【阶段三：单点咨询期（意图：问天气、问常识、闲聊）】
触发条件：无任何寻址或路线规划需求，仅询问单一客观问题。请你专注地回答（比如问去新疆看雪的准备就只针对性地回答相关问题与建议，而不要接着回答之前的问题。
行为准则：仅输出亲切、专业的文本回复，【绝对不允许】输出 JSON 代码块。
===================================================================
【第一部分：回复给用户看的文本】

请用亲切的自然语言回答，并用 Markdown 格式排出详细的每日行程（包含景点和美食）。在文本的最后，无需展示任何计算过程，只需要直接加上『💰 人均预估费用：约 XXXX 元』即可。

注：不要在文本里罗列繁琐的避坑指南和行李清单！

【第二部分：留给系统的隐藏 JSON】

在第一部分的自然语言完全结束后，必须在整个回复的最末尾附上一个严格的 JSON 代码块（必须用 ```json 和 ``` 包裹）。JSON中不仅要包含每日行程（需提供经纬度），还要静默包含行李、避坑等行前准备数据。

JSON 格式必须为：

```json

{

  "title": "行程标题",

  "estimated_budget_per_person": "3500元",

  "days": [

    {

      "dayTitle": "Day 1 标题",

      "activities": [

        {

          "time": "10:00",

          "title": "景点名",

          "type": "scenic",

          "openTime": "09:00-18:00 开放",

          "recommended_duration": "2.5小时",

          "tag": "历史人文 · 必打卡",

          "strategy": "游玩攻略：建议先去核心展区，避开下午人流高峰。",

          "lat": 39.9,

          "lng": 116.4

        }

      ]

    }

  ],

  "pre_trip_prep": {

    "bookings": [{"item": "故宫门票", "tips": "提前7天"}],

    "luggage": [],

    "pitfalls": []

  }

}

```

【极度重要】：在生成 activities 的时间安排和建议游玩时长 (recommended_duration) 时，绝对不允许偷懒全部写 '1小时'！你必须根据景点的真实客观属性进行合理预估。例如：

大型博物馆/主题乐园：建议 3-4 小时或半天。

知名自然风光/爬山：建议 2-4 小时。

特色餐厅/老字号就餐：建议 1.5-2 小时。

打卡地/夜市逛街：建议 1-2 小时。 请确保时间轴的安排合理且符合真实人类游玩体力！

# Constraint Rules (路线规划必须严格遵守的底层逻辑)

1. 空间聚类优先 (Geospatial Clustering)

绝对禁止折返跑： 路线规划必须遵循物理距离最短原则。如果景点A和C距离近，B距离极远，即使输入顺序是A-B-C，你也必须纠正为A-C-B。

片区化游玩： 将地理位置相邻的景点划分为同一个“游玩片区”。必须在这个片区的景点全部游玩结束后，才能前往下一个片区。

2. 闭馆时间约束 (Time-Window Sorting)

早关门早安排： 在同一个“游玩片区”内，必须对比各个景点的营业/闭馆时间。闭馆时间越早的景点，必须排在游玩顺序的越前面。

夜间分配： 将全天开放、没有明确闭馆时间或晚上更佳的景点（如夜市、观景台、自然风光等）严格安排在行程的傍晚或晚间。

3. 时间轴推演 (Time Budgeting & Commute)
你给出的时间表必须符合严密的数学逻辑，不能凭空捏造。公式如下：

离开A点的时间 = 到达A点的时间 + A景点的平均/最佳游玩时长

到达B点的时间 = 离开A点的时间 + A点到B点的真实通勤时间

要求： 必须在行程表中明确标出“景点间通勤时间及推荐交通方式”以及“单个景点游玩时长”。''';

    String extensionPrompt = '\n\n========== 【当前场景感知与专属指令】 ==========\n';
    extensionPrompt += '用户当前是从【$source】页面呼出你的。\n';

    if (currentPlanJson != null && currentPlanJson.isNotEmpty) {
      extensionPrompt +=
          '''
以下是用户当前的完整行程草案(JSON格式)：

$currentPlanJson

请遵循以下额外规则：
1. 【微调修改】：如果用户要求修改当前行程，请基于现有数据精准修改，并输出修改后的完整 JSON。
2. 🚨【变卦处理】：如果用户提出**完全改变目的地**，请彻底抛弃上述旧数据，直接为新目的地生成全新 JSON！
3. 【闲聊防呆】：如果用户仅闲聊且不需要改行程，只输出文字回复，切勿输出 JSON 代码块！
''';
    } else {
      extensionPrompt += '用户目前还没有创建任何行程，请尽情发挥创意为他从零规划，并输出 JSON 数据。';
    }
    return basePrompt + extensionPrompt;
  }

  @override
  void initState() {
    super.initState();
    // 以 initialPrompt 在列表中的位置为起点，找不到则从 0 开始
    final int startIndex = widget.initialPrompt != null
        ? _searchHints.indexOf(widget.initialPrompt!)
        : -1;
    _hintIndex = startIndex >= 0 ? startIndex : 0;
    _hintPrompt = _searchHints[_hintIndex];
    
    // 每 7s 轮换一次，与发现页节奏一致
    _hintTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      if (mounted) {
        setState(() {
          _hintIndex = (_hintIndex + 1) % _searchHints.length;
          _hintPrompt = _searchHints[_hintIndex];
        });
      }
    });
    
    // 点击输入框时锁定当前 hint，停止轮换
    _inputFocusNode.addListener(() {
      if (_inputFocusNode.hasFocus) {
        _hintTimer?.cancel();
        _hintTimer = null;
      }
    });
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrapChat();
    });
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _bootstrapChat() async {
    await loadChatHistory();
    _forceScrollToBottom();
  }

  Future<void> loadChatHistory() async {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final List<Map<String, dynamic>> response = await _supabase
          .from('ai_chat_messages')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: true);

      if (response.isNotEmpty) {
        final List<ChatMessage> history = <ChatMessage>[];
        for (final Map<String, dynamic> row in response) {
          Map<String, dynamic>? parsedItinerary;
          if (row['itinerary_data'] != null) {
            try {
              if (row['itinerary_data'] is String) {
                final Object? decoded = jsonDecode(
                  row['itinerary_data'] as String,
                );
                if (decoded is Map<String, dynamic>) {
                  parsedItinerary = decoded;
                }
              } else if (row['itinerary_data'] is Map) {
                parsedItinerary = Map<String, dynamic>.from(
                  row['itinerary_data'] as Map<dynamic, dynamic>,
                );
              }
            } catch (e) {
              debugPrint('🚨 单条历史 itinerary_data 解析失败: $e');
            }
          }
          history.add(
            ChatMessage(
              role: row['role'] as String? ?? 'user',
              text: row['content'] as String? ?? '',
              itineraryData: parsedItinerary,
            ),
          );
        }
        if (mounted) {
          setState(() {
            _messages = <ChatMessage>[_messages.first, ...history];
          });
          _forceScrollToBottom();
        }
      }
    } catch (e) {
      debugPrint('🚨 加载历史记录彻底失败: $e');
    }

    // 💡 在加载完成并上屏后，顺手在后台扔一个清理任务
    _pruneOldMessages(); // 注意：这里故意不加 await，让它异步静默执行
  }

  Future<void> _pruneOldMessages() async {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    try {
      // 1. 获取该用户按时间降序（最新到最老）的记录 id 列表
      final List<Map<String, dynamic>> response = await _supabase
          .from('ai_chat_messages')
          .select('id')
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      final List<dynamic> records = response;

      // 2. 如果记录数超过阈值，执行清理
      if (records.length > _maxHistoryCount) {
        // 截取需要被删除的旧记录 id
        final List<dynamic> idsToDelete = records
            .sublist(_maxHistoryCount)
            .map((dynamic row) => row['id'])
            .toList();

        // 3. 批量删除最老的记录
        await _supabase
            .from('ai_chat_messages')
            .delete()
            .inFilter('id', idsToDelete);

        debugPrint('🧹 数据库减负成功：已清理 ${idsToDelete.length} 条过期对话');
      }
    } catch (e) {
      debugPrint('🚨 数据库静默清理失败: $e');
    }
  }

  Future<void> _clearChatHistory() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (BuildContext context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 0,
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.delete_sweep_rounded,
                  color: Colors.red.shade400,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '清空聊天记录',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '清空后当前对话将无法找回。\n(已导入“我的行程”中的计划不受影响)',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.black54,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        backgroundColor: Colors.grey.shade100,
                      ),
                      child: const Text(
                        '取消',
                        style: TextStyle(
                          color: Colors.black54,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        backgroundColor: Colors.red.shade400,
                        elevation: 0,
                      ),
                      child: const Text(
                        '确定清空',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (!mounted || confirm != true) return;

    setState(() {
      _messages = <ChatMessage>[_messages.first];
      _showAllHistory = false;
    });

    final String? userId = _supabase.auth.currentUser?.id;
    if (userId != null) {
      _supabase
          .from('ai_chat_messages')
          .delete()
          .eq('user_id', userId)
          .catchError((Object _) {});
    }
  }

  Future<String> _enrichUserInput(String rawInput) async {
    String enriched = rawInput;

    // ── 天气意图拦截 ──────────────────────────────────────
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

    // ── 地点/导航意图拦截 ─────────────────────────────────
    if (rawInput.contains('在哪') || rawInput.contains('怎么去') || rawInput.contains('地址')) {
      // 此处可调用 AmapService.geocode(keyword, city: city) 获取坐标
      // 并将坐标注入到 enriched 中，或在 AI 回复后展示地图卡片
    }

    return enriched;
  }

  Future<void> _sendMessage() async {
    String text = _textController.text.trim();

    if (text.isEmpty) {
      if (_hintPrompt != null && _hintPrompt!.isNotEmpty) {
        text = _hintPrompt!;
      } else if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
        text = widget.initialPrompt!;
      } else {
        text = '帮我规划一次旅行';
      }
    }

    if (context.read<MainNavProvider>().isAiPlanning) return;

    final String userText = text;
    FocusScope.of(context).unfocus();
    _textController.clear();
    final MainNavProvider navProvider = context.read<MainNavProvider>();
    navProvider.setAiPlanning(true);
    setState(() {
      _messages.add(ChatMessage(role: 'user', text: userText));
    });
    _scrollToBottom();
    final int requestId = ++_requestSeq;
    _activeRequestId = requestId;
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId != null) {
      _supabase
          .from('ai_chat_messages')
          .insert(<String, dynamic>{
            'user_id': userId,
            'role': 'user',
            'content': userText,
          })
          .then((_) => debugPrint('✅ 用户消息云端备份'))
          .catchError((Object e) => debugPrint('❌ 备份失败: $e'));
    }

    const String apiKey = AiConfig.deepseekApiKey;
    final String normalizedApiKey = apiKey.trim();
    if (normalizedApiKey.isEmpty) {
      setState(() {
        _messages.add(
          const ChatMessage(
            role: 'ai',
            text: '检测到 API Key 为空，请先在代码中配置有效的 DeepSeek Key。',
            isError: true,
          ),
        );
      });
      navProvider.setAiPlanning(false);
      _scrollToBottom();
      return;
    }
    final Uri url = Uri.parse(AiConfig.deepseekEndpoint);

    try {
      // 在调用 LLM 前先丰富用户输入（注入天气等实时数据）
      final String enrichedInput = await _enrichUserInput(userText);
      
      final http.Client client = http.Client();
      _activeClient = client;
      final List<Map<String, String>> history = _messages
          .where((ChatMessage msg) => msg.role == 'user' || msg.role == 'ai')
          .take(8)
          .map(
            (ChatMessage msg) => <String, String>{
              'role': msg.role == 'user' ? 'user' : 'assistant',
              'content': msg.text,
            },
          )
          .toList(growable: false);
      final ItineraryProvider itineraryProvider = context
          .read<ItineraryProvider>();
      final Map<String, dynamic>? currentPlanData =
          itineraryProvider.activeItinerary?.planData ??
          itineraryProvider.currentItinerary?.planData;
      final String? currentPlanJson = currentPlanData != null
          ? jsonEncode(currentPlanData)
          : null;
      final http.Response response = await client.post(
        url,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $normalizedApiKey',
        },
        body: jsonEncode(<String, dynamic>{
          'model': AiConfig.deepseekModel,
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content': _buildSystemPrompt(currentPlanJson, widget.source),
            },
            ...history,
            <String, String>{'role': 'user', 'content': enrichedInput},
          ],
        }),
      );

      if (response.statusCode == 200) {
        final String decodedBody = utf8.decode(response.bodyBytes);
        final Map<String, dynamic> data =
            jsonDecode(decodedBody) as Map<String, dynamic>;
        final List<dynamic>? choices = data['choices'] as List<dynamic>?;
        String? aiText;
        if (choices != null && choices.isNotEmpty) {
          final Map<String, dynamic>? firstChoice =
              choices.first as Map<String, dynamic>?;
          final Map<String, dynamic>? message =
              firstChoice?['message'] as Map<String, dynamic>?;
          aiText = message?['content'] as String?;
        }
        if (aiText != null && aiText.trim().isNotEmpty) {
          String chatText = aiText;
          String jsonString = '';
          Map<String, dynamic>? parsedItinerary;
          if (aiText.contains('```json')) {
            final List<String> parts = aiText.split('```json');
            chatText = parts[0].trim();
            String jsonPart = parts.length > 1 ? parts[1] : '';
            if (jsonPart.contains('```')) {
              jsonString = jsonPart.split('```')[0].trim();
            } else {
              jsonString = jsonPart.trim();
            }
            if (jsonString.isNotEmpty) {
              try {
                final Object? parsed = jsonDecode(jsonString);
                if (parsed is Map) {
                  parsedItinerary = Map<String, dynamic>.from(parsed);
                }
              } catch (e) {
                debugPrint('JSON 解析失败: $e');
              }
            }
          }
          final String finalChatText = chatText.trim().isEmpty
              ? '我已经准备好继续帮你优化路线。'
              : chatText.trim();
          if (mounted) {
            setState(() {
              _messages.add(
                ChatMessage(
                  role: 'ai',
                  text: finalChatText,
                  itineraryData: parsedItinerary,
                ),
              );
            });
          }
          if (userId != null) {
            _supabase
                .from('ai_chat_messages')
                .insert(<String, dynamic>{
                  'user_id': userId,
                  'role': 'ai',
                  'content': finalChatText,
                  'itinerary_data': parsedItinerary,
                })
                .then((_) => debugPrint('✅ AI消息云端备份'))
                .catchError((Object e) => debugPrint('❌ 备份失败: $e'));
          }
        } else {
          if (mounted) {
            setState(() {
              _messages.add(
                const ChatMessage(role: 'ai', text: '抱歉，暂时没有拿到有效回复，请稍后再试。'),
              );
            });
          }
        }
      } else {
        final String err =
            'HTTP ${response.statusCode}: ${response.reasonPhrase ?? 'unknown'}';
        final String shortErr = err.length > 20 ? err.substring(0, 20) : err;
        if (mounted) {
          setState(() {
            _messages.add(
              ChatMessage(
                role: 'ai',
                text: '抱歉，管家遇到了一点小网络问题，请稍后再试。($shortErr)',
                isError: true,
              ),
            );
          });
        }
      }
    } catch (e) {
      if (_activeRequestId != requestId) {
        return;
      }
      final String err = e.toString();
      final String shortErr = err.length > 20 ? err.substring(0, 20) : err;
      if (mounted) {
        setState(() {
          _messages.add(
            ChatMessage(
              role: 'ai',
              text: '抱歉，管家遇到了一点小网络问题，请稍后再试。($shortErr)',
              isError: true,
            ),
          );
        });
      }
    } finally {
      if (_activeRequestId == requestId) {
        _activeRequestId = null;
        _activeClient?.close();
        _activeClient = null;
        if (mounted) {
          setState(() {});
          _scrollToBottom();
        }
        navProvider.setAiPlanning(false);
      }
    }
  }

  Future<void> _cancelRequest() async {
    final MainNavProvider navProvider = context.read<MainNavProvider>();
    if (!navProvider.isAiPlanning) return;
    _activeRequestId = null;
    _activeClient?.close();
    _activeClient = null;
    navProvider.setAiPlanning(false);
    setState(() {
      _messages.add(const ChatMessage(role: 'system', text: '已中止行程生成'));
    });
    _scrollToBottom();
  }

  Future<void> _importPlan(Map<String, dynamic> itineraryData) async {
    final DateTime now = DateTime.now();
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: '请选择出发日期',
      confirmText: '确定',
      cancelText: '取消',
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Colors.indigo,
              onPrimary: Colors.white,
              onSurface: Colors.black87,
            ),
          ),
          child: child!,
        );
      },
    );
    if (pickedDate == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    try {
      final ItineraryModel parsed = ItineraryModel.fromJson(itineraryData);
      final int dayCount = parsed.days.isEmpty ? 1 : parsed.days.length;
      final DateTime normalizedStart = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
      );
      final ItineraryModel model = parsed.copyWith(
        startDate: normalizedStart,
        endDate: normalizedStart.add(Duration(days: dayCount - 1)),
      );
      await context.read<ItineraryProvider>().saveItinerary(model);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messages.add(
          const ChatMessage(role: 'system', text: '行程导入失败，请让 AI 重新生成一次'),
        );
      });
      return;
    }
    if (!mounted) return;
    final MainNavProvider nav = context.read<MainNavProvider>();
    Navigator.of(context).pop(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      nav.goToItineraryTab();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (!mounted || !_scrollController.hasClients) {
          return;
        }
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    });
  }

  void _forceScrollToBottom() {
    void jumpToBottom() {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    }

    void animateToBottom() {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }

    Future<void>.delayed(const Duration(milliseconds: 50), () {
      jumpToBottom();
    });
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      animateToBottom();
    });
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      animateToBottom();
    });
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      animateToBottom();
    });
  }

  @override
  Widget build(BuildContext context) {
    final MainNavProvider navProvider = context.watch<MainNavProvider>();
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final bool isGlobalLoading = navProvider.isAiPlanning;

    // 自动发送守卫：完全依赖构造时传入的 widget.autoSend，
    // 不再监听 provider 的全局 shouldAutoSendAi，彻底杜绝状态残留导致的误触发。
    // FAB 路径：autoSend=false，永远不会进入此分支。
    // 外部触发路径：autoSend=true 且 initialPrompt 非空，才自动发送。
    if (widget.autoSend &&
        widget.initialPrompt != null &&
        widget.initialPrompt!.isNotEmpty &&
        !_autoSendDone) {
      _autoSendDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (context.read<MainNavProvider>().isAiPlanning) return;
        _textController.text = widget.initialPrompt!;
        _sendMessage();
      });
    }

    const int displayThreshold = 5;
    final bool hasHiddenHistory =
        _messages.length > displayThreshold && !_showAllHistory;
    final List<ChatMessage> renderMessages = hasHiddenHistory
        ? <ChatMessage>[
            _messages.first,
            ..._messages.sublist(_messages.length - (displayThreshold - 1)),
          ]
        : _messages;

    return Material(
      color: Colors.grey.shade50,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            _buildHeader(),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                cacheExtent: 99999,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                itemCount:
                    renderMessages.length +
                    (isGlobalLoading ? 1 : 0) +
                    (hasHiddenHistory ? 1 : 0),
                itemBuilder: (BuildContext context, int index) {
                  if (isGlobalLoading &&
                      index ==
                          renderMessages.length + (hasHiddenHistory ? 1 : 0)) {
                    return _buildLoadingBubble();
                  }
                  if (hasHiddenHistory && index == 1) {
                    return _buildExpandButton();
                  }
                  final int msgIndex = hasHiddenHistory && index > 1
                      ? index - 1
                      : index;
                  final ChatMessage message = renderMessages[msgIndex];
                  if (message.role == 'system') {
                    return _buildSystemHint(message.text);
                  }
                  final bool isUser = message.role == 'user';
                  final bool isError = message.isError;
                  final String text = message.text;
                  if (isUser) {
                    return _buildUserBubble(text);
                  }
                  final Map<String, dynamic>? itineraryData =
                      message.itineraryData;
                  return _buildAiBubble(
                    text,
                    isError: isError,
                    itineraryData: itineraryData,
                  );
                },
              ),
            ),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: <Color>[Color(0xFF4F6DFF), Color(0xFF7A57FF)],
              ),
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'AI 智能管家',
              style: TextStyle(
                color: Colors.grey.shade800,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.cleaning_services_rounded,
              color: Colors.black54,
              size: 20,
            ),
            tooltip: '清空对话',
            onPressed: _clearChatHistory,
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.black54),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandButton() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16.0),
        child: TextButton.icon(
          onPressed: () {
            final double previousOffset = _scrollController.offset;
            final double previousMaxScroll =
                _scrollController.position.maxScrollExtent;

            setState(() {
              _showAllHistory = true;
            });

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_scrollController.hasClients) return;
              final double currentMaxScroll =
                  _scrollController.position.maxScrollExtent;
              final double delta = currentMaxScroll - previousMaxScroll;

              if (delta > 0) {
                _scrollController.jumpTo(previousOffset + delta);
              }
            });
          },
          icon: const Icon(Icons.history, size: 16, color: Colors.indigo),
          label: const Text(
            '⏳ 查看更早的聊天记录',
            style: TextStyle(
              color: Colors.indigo,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          style: TextButton.styleFrom(
            backgroundColor: Colors.indigo.shade50,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
        ),
      ),
    );
  }

  Widget _buildUserBubble(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12, left: 24),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            IconButton(
              icon: Icon(
                Icons.edit_note_rounded,
                color: Colors.grey.shade400,
                size: 22,
              ),
              tooltip: '重新编辑',
              onPressed: () {
                _textController.text = text;
                FocusScope.of(context).requestFocus(_inputFocusNode);
              },
            ),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.indigo.shade600,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(4),
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.indigo.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAiBubble(
    String text, {
    required bool isError,
    Map<String, dynamic>? itineraryData,
  }) {
    final String title = (itineraryData?['title'] ?? '专属行程草案').toString();
    final List<dynamic> days =
        itineraryData?['days'] as List<dynamic>? ?? <dynamic>[];
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildAiAvatar(),
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _buildAiMarkdown(text, isError: isError),
                    if (itineraryData != null && !isError) ...<Widget>[
                      const SizedBox(height: 10),
                      Divider(color: Colors.grey.shade200, height: 1),
                      const SizedBox(height: 10),
                      Text(
                        '《$title》 · ${days.length}天',
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => _importPlan(itineraryData),
                          child: const Text('✅ 满意，一键导入至我的行程'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: () => FocusScope.of(
                            context,
                          ).requestFocus(_inputFocusNode),
                          child: const Text('💬 还不满意，继续修改'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildAiAvatar(),
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.indigo,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'AI 管家正在极速规划行程...',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.indigo.shade600,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '💡 您可以退出此页面浏览其他内容，\n生成完成后会自动保存在这里。',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAiAvatar() {
    return Container(
      width: 28,
      height: 28,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: <Color>[Color(0xFF4F6DFF), Color(0xFF7A57FF)],
        ),
      ),
      child: const Icon(Icons.auto_awesome, color: Colors.white, size: 14),
    );
  }

  Widget _buildAiMarkdown(String text, {required bool isError}) {
    if (isError) {
      return Text(
        text,
        style: TextStyle(color: Colors.red.shade400, height: 1.4),
      );
    }
    return MarkdownBody(
      key: ValueKey<String>('md_${text.hashCode}'),
      data: text,
      selectable: false,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(fontSize: 14, color: Colors.grey.shade800, height: 1.5),
        h3: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.indigo.shade700,
          height: 1.5,
        ),
        tableBody: TextStyle(fontSize: 13, color: Colors.grey.shade700),
        tableHead: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.grey.shade900,
        ),
        tableBorder: TableBorder.all(color: Colors.grey.shade300, width: 1),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _textController,
                  focusNode: _inputFocusNode,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (String value) => _sendMessage(),
                  decoration: InputDecoration(
                    hintText: _hintPrompt ?? '例如：日本关西 7天特种兵打卡',
                    hintStyle: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 14,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Material(
              color: Colors.transparent,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: context.watch<MainNavProvider>().isAiPlanning
                    ? InkWell(
                        key: const ValueKey<String>('stop'),
                        onTap: _cancelRequest,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade800,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.stop_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : InkWell(
                        key: const ValueKey<String>('send'),
                        onTap: () => _sendMessage(),
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: <Color>[Colors.indigo, Colors.purple],
                            ),
                          ),
                          child: const Icon(
                            Icons.send_rounded,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemHint(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
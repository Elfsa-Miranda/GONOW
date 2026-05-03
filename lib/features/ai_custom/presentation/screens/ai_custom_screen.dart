import 'dart:convert';

import 'package:gonow/core/constants/ai_config.dart';
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

  const AiCustomScreen({super.key, this.source = '底部导航栏', this.initialPrompt});

  @override
  State<AiCustomScreen> createState() => _AiCustomScreenState();
}

class _AiCustomScreenState extends State<AiCustomScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  String? _hintPrompt;
  bool _showAllHistory = false;
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

【第一部分：回复给用户看的文本】

请用亲切的自然语言回答，并用 Markdown 格式排出详细的每日行程（包含景点和美食）。如果用户询问旅游常识（如防高反、签证），请先用自然、亲切的语言详细解答。在文本的最后，无需展示任何计算过程，只需要直接加上『💰 人均预估费用：约 XXXX 元』即可。

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

打卡地/夜市逛街：建议 1-2 小时。 请确保时间轴的安排合理且符合真实人类游玩体力！''';

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrapChat();
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _bootstrapChat() async {
    await loadChatHistory();
    _forceScrollToBottom();

    if (!mounted) return;
    final MainNavProvider navProvider = context.read<MainNavProvider>();
    final String? pending = navProvider.pendingAiPrompt?.trim();
    final String hintPrompt = pending != null && pending.isNotEmpty
        ? pending
        : '带父母去北京玩五天经典路线';
    setState(() {
      _hintPrompt = hintPrompt;
    });

    if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
      if (navProvider.shouldAutoSendAi) {
        navProvider.shouldAutoSendAi = false;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !context.read<MainNavProvider>().isAiPlanning) {
            _sendMessage();
          }
        });
      }
    }
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

  Future<void> _sendMessage() async {
    String text = _textController.text.trim();

    if (text.isEmpty) {
      if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
        text = widget.initialPrompt!;
      } else if (_hintPrompt != null && _hintPrompt!.isNotEmpty) {
        text = _hintPrompt!;
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
            <String, String>{'role': 'user', 'content': userText},
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
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final bool isGlobalLoading = context.watch<MainNavProvider>().isAiPlanning;
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

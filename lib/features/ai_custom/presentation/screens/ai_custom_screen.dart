import 'dart:async';
import 'dart:convert';

import 'package:gonow/core/services/amap_service.dart';
import 'package:gonow/core/services/ai_gateway_service.dart';
import 'package:gonow/core/services/safe_logger.dart';
import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void _safeAiCustomLog(String? message) {
  SafeLogger.instance.event(
    'ai_custom.legacy_event',
    fields: const <String, Object?>{'source': 'ai_custom'},
  );
}

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
              _safeAiCustomLog('🚨 单条历史 itinerary_data 解析失败: $e');
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
      _safeAiCustomLog('🚨 加载历史记录彻底失败: $e');
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

        _safeAiCustomLog('🧹 数据库减负成功：已清理 ${idsToDelete.length} 条过期对话');
      }
    } catch (e) {
      _safeAiCustomLog('🚨 数据库静默清理失败: $e');
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
    if (rawInput.contains('天气') ||
        rawInput.contains('气温') ||
        rawInput.contains('下雨')) {
      final city = AmapService.extractLocationFromText(rawInput);
      if (city != null) {
        final weatherDesc = await AmapService.getWeatherDescription(city);
        if (weatherDesc != null) {
          enriched =
              '''
用户问题：$rawInput
<系统后台注入>$weatherDesc</系统后台注入>
请务必基于上述【实时数据】用温暖管家语气回复，给出穿衣建议，不要向用户暴露数据来源。
''';
        }
      }
    }

    // ── 地点/导航意图拦截 ─────────────────────────────────
    if (rawInput.contains('在哪') ||
        rawInput.contains('怎么去') ||
        rawInput.contains('地址')) {
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
      } else if (widget.initialPrompt != null &&
          widget.initialPrompt!.isNotEmpty) {
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
          .then((_) => _safeAiCustomLog('✅ 用户消息云端备份'))
          .catchError((Object e) => _safeAiCustomLog('❌ 备份失败: $e'));
    }

    try {
      // 在调用 LLM 前先丰富用户输入（注入天气等实时数据）
      final String enrichedInput = await _enrichUserInput(userText);
      if (!mounted || _activeRequestId != requestId) {
        return;
      }

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
      final String? accessToken = _supabase.auth.currentSession?.accessToken;
      if (accessToken == null || accessToken.trim().isEmpty) {
        throw const AiGatewayException('authentication_required');
      }
      final AiGatewayResponse response = await AiGatewayService(client: client)
          .sendChat(
            accessToken: accessToken,
            messages: <Map<String, String>>[
              ...history,
              <String, String>{'role': 'user', 'content': enrichedInput},
            ],
            source: widget.source,
            currentPlan: currentPlanData,
          );
      final String finalChatText = response.content;
      if (mounted) {
        setState(() {
          _messages.add(
            ChatMessage(
              role: 'ai',
              text: finalChatText,
              itineraryData: response.itineraryData,
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
              'itinerary_data': response.itineraryData,
            })
            .then((_) => _safeAiCustomLog('✅ AI消息云端备份'))
            .catchError((Object e) => _safeAiCustomLog('❌ 备份失败: $e'));
      }
    } on AiGatewayException catch (error) {
      if (_activeRequestId != requestId) {
        return;
      }
      final String message = switch (error.code) {
        'gateway_disabled' ||
        'invalid_gateway_configuration' => 'AI 服务尚未启用，请稍后再试。',
        'authentication_required' => '登录状态已失效，请重新登录。',
        _ => '抱歉，管家遇到了一点小网络问题，请稍后再试。',
      };
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(role: 'ai', text: message, isError: true));
        });
      }
    } catch (_) {
      if (_activeRequestId != requestId) {
        return;
      }
      if (mounted) {
        setState(() {
          _messages.add(
            const ChatMessage(
              role: 'ai',
              text: '抱歉，管家遇到了一点小网络问题，请稍后再试。',
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

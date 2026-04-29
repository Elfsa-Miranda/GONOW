import 'dart:convert';

import 'package:gonow/features/itinerary/data/itinerary_provider.dart';
import 'package:gonow/features/main_nav/data/main_nav_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

class AiCustomScreen extends StatefulWidget {
  const AiCustomScreen({super.key});

  @override
  State<AiCustomScreen> createState() => _AiCustomScreenState();
}

class _AiCustomScreenState extends State<AiCustomScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  bool _isLoading = false;
  String? _hintPrompt;
  String? _lastConsumedPrompt;
  http.Client? _activeClient;
  int _requestSeq = 0;
  int? _activeRequestId;
  final List<Map<String, dynamic>> _messages = <Map<String, dynamic>>[
    <String, dynamic>{
      'role': 'ai',
      'text':
          '👋 你好！我是你的专属智能旅游管家。\n\n请告诉我你的**目的地**、**游玩天数**和**大致预算**（例如：*“去大理玩 4天，预算 3000”*），我来为你量身定制专属行程！\n\n💡 你也可以补充偏好（如亲子、拍照、美食、慢节奏），我会一起考虑。',
      'isError': false,
    },
  ];

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final String raw = _textController.text.trim();
    final String userText = raw.isNotEmpty ? raw : (_hintPrompt ?? '').trim();
    if (userText.isEmpty || _isLoading) {
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _messages.add(<String, dynamic>{
        'role': 'user',
        'text': userText,
        'isError': false,
      });
      _textController.clear();
      _isLoading = true;
    });
    _scrollToBottom();
    final int requestId = ++_requestSeq;
    _activeRequestId = requestId;

    const String apiKey = 'sk-a442065c813f4f4eaf584218f8955b6e';
    final String normalizedApiKey = apiKey.trim();
    if (normalizedApiKey.isEmpty) {
      setState(() {
        _messages.add(<String, dynamic>{
          'role': 'ai',
          'text': '检测到 API Key 为空，请先在代码中配置有效的 DeepSeek Key。',
          'isError': true,
        });
        _isLoading = false;
      });
      _scrollToBottom();
      return;
    }
    final Uri url = Uri.parse('https://api.deepseek.com/chat/completions');

    try {
      final http.Client client = http.Client();
      _activeClient = client;
      final List<Map<String, String>> history = _messages
          .where(
            (Map<String, dynamic> msg) =>
                msg['role'] == 'user' || msg['role'] == 'ai',
          )
          .take(8)
          .map(
            (Map<String, dynamic> msg) => <String, String>{
              'role': msg['role'] == 'user' ? 'user' : 'assistant',
              'content': (msg['text'] ?? '').toString(),
            },
          )
          .toList(growable: false);
      final http.Response response = await client.post(
        url,
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $normalizedApiKey',
        },
        body: jsonEncode(<String, dynamic>{
          'model': 'deepseek-chat',
          'messages': <Map<String, String>>[
            <String, String>{
              'role': 'system',
              'content': '''你是一个温暖、专业的智能旅游管家。当用户提出需求时，请按照以下两个部分严格输出：

【第一部分：回复给用户看的文本】
请用亲切的自然语言回答，并用 Markdown 格式排出详细的每日行程（包含景点和美食）。如果用户询问旅游常识（如防高反、签证），请先用自然、亲切的语言详细解答。在文本的最后，无需展示任何计算过程，只需要直接加上『💰 人均预估费用：约 XXXX 元』即可。
注：不要在文本里罗列繁琐的避坑指南和行李清单！

【第二部分：留给系统的隐藏 JSON】
在第一部分的自然语言完全结束后，必须在整个回复的最末尾附上一个严格的 JSON 代码块（必须用 ```json 和 ``` 包裹）。JSON中不仅要包含每日行程（需提供经纬度），还要静默包含行李、避坑等行前准备数据。
JSON 格式必须为：
```json
{"title": "行程标题","estimated_budget_per_person": "3500元","days": [{"dayTitle": "Day 1 标题","activities": [{"time": "10:00","title": "景点名","type": "scenic","lat": 39.9, "lng": 116.4}]}],"pre_trip_prep": {"bookings": [{"item": "故宫门票","tips": "提前7天"}],"luggage": [],"pitfalls": []}}
```

【极度重要】：在生成 activities 的时间安排和建议游玩时长 (recommended_duration) 时，绝对不允许偷懒全部写 '1小时'！你必须根据景点的真实客观属性进行合理预估。例如：
- 大型博物馆/主题乐园：建议 3-4 小时或半天。
- 知名自然风光/爬山：建议 2-4 小时。
- 特色餐厅/老字号就餐：建议 1.5-2 小时。
- 打卡地/夜市逛街：建议 1-2 小时。
请确保时间轴的安排合理且符合真实人类游玩体力！''',
            },
            ...history,
            <String, String>{'role': 'user', 'content': '请为我规划：$userText'},
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
                if (parsed is Map<String, dynamic>) {
                  parsedItinerary = parsed;
                }
              } catch (e) {
                debugPrint('JSON 解析失败: $e');
              }
            }
          }
          setState(() {
            _messages.add(<String, dynamic>{
              'role': 'ai',
              'text': chatText.trim().isEmpty
                  ? '我已经准备好继续帮你优化路线。'
                  : chatText.trim(),
              'itineraryData': parsedItinerary,
              'isError': false,
            });
          });
        } else {
          setState(() {
            _messages.add(<String, dynamic>{
              'role': 'ai',
              'text': '抱歉，暂时没有拿到有效回复，请稍后再试。',
              'isError': false,
            });
          });
        }
      } else {
        final String err =
            'HTTP ${response.statusCode}: ${response.reasonPhrase ?? 'unknown'}';
        final String shortErr = err.length > 20 ? err.substring(0, 20) : err;
        setState(() {
          _messages.add(<String, dynamic>{
            'role': 'ai',
            'text': '抱歉，管家遇到了一点小网络问题，请稍后再试。($shortErr)',
            'isError': true,
          });
        });
      }
    } catch (e) {
      if (_activeRequestId != requestId) {
        return;
      }
      final String err = e.toString();
      final String shortErr = err.length > 20 ? err.substring(0, 20) : err;
      setState(() {
        _messages.add(<String, dynamic>{
          'role': 'ai',
          'text': '抱歉，管家遇到了一点小网络问题，请稍后再试。($shortErr)',
          'isError': true,
        });
      });
    } finally {
      if (_activeRequestId == requestId && mounted) {
        _activeRequestId = null;
        _activeClient?.close();
        _activeClient = null;
        setState(() {
          _isLoading = false;
        });
        _scrollToBottom();
      }
    }
  }

  Future<void> _cancelRequest() async {
    if (!_isLoading) return;
    _activeRequestId = null;
    _activeClient?.close();
    _activeClient = null;
    setState(() {
      _isLoading = false;
      _messages.add(<String, dynamic>{'role': 'system', 'text': '已中止行程生成'});
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
        _messages.add(<String, dynamic>{
          'role': 'system',
          'text': '行程导入失败，请让 AI 重新生成一次',
        });
      });
      return;
    }
    if (!mounted) return;
    context.read<MainNavProvider>().goToItineraryTab();
    Navigator.of(context).pop(true);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final MainNavProvider navProvider = context.watch<MainNavProvider>();
    final String? pending = navProvider.pendingAiPrompt?.trim();
    if (navProvider.shouldAutoSendAi &&
        pending != null &&
        pending.isNotEmpty &&
        pending != _lastConsumedPrompt) {
      _lastConsumedPrompt = pending;
      _hintPrompt = pending;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        navProvider.clearAiPendingState();
        setState(() {});
      });
    }

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.black),
          onPressed: () => Navigator.pop(context),
        ),
        titleSpacing: 16,
        title: Row(
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
            Text(
              'AI 智能管家',
              style: TextStyle(
                color: Colors.grey.shade800,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              itemCount: _messages.length + (_isLoading ? 1 : 0),
              itemBuilder: (BuildContext context, int index) {
                if (_isLoading && index == _messages.length) {
                  return _buildLoadingBubble();
                }
                final Map<String, dynamic> message = _messages[index];
                if (message['role'] == 'system') {
                  return _buildSystemHint(message['text'] as String? ?? '');
                }
                final bool isUser = message['role'] == 'user';
                final bool isError = message['isError'] == true;
                final String text = message['text'] as String? ?? '';
                if (isUser) {
                  return _buildUserBubble(text);
                }
                final Map<String, dynamic>? itineraryData =
                    message['itineraryData'] as Map<String, dynamic>?;
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
    );
  }

  Widget _buildUserBubble(String text) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12, left: 56),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.indigo.shade600,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, height: 1.4),
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
                      color: Colors.black.withOpacity(0.04),
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
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'AI 管家正在极速检索，为你定制完美行程...',
                        style: TextStyle(
                          color: Colors.indigo.shade500,
                          height: 1.35,
                        ),
                      ),
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
      data: text,
      selectable: true,
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
      child: SafeArea(
        top: false,
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
                  child: _isLoading
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

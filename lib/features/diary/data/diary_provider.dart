import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gonow/core/constants/ai_config.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 手账数据模型（本地缓存 + Supabase `public_diaries` 行）
class DiaryModel {
  DiaryModel({
    required this.id,
    this.userId = '',
    required this.title,
    required this.coverImageUrl,
    required this.authorName,
    required this.diaryData,
    this.isPublic = false,
    this.isDraft = true,
    required this.styleType,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String userId;
  final String title;
  final String coverImageUrl;
  final String authorName;
  final String styleType;
  final Map<String, dynamic> diaryData;
  final bool isPublic;
  final bool isDraft;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  DiaryModel copyWith({
    String? id,
    String? userId,
    String? title,
    String? coverImageUrl,
    String? authorName,
    Map<String, dynamic>? diaryData,
    bool? isPublic,
    bool? isDraft,
    String? styleType,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DiaryModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      title: title ?? this.title,
      coverImageUrl: coverImageUrl ?? this.coverImageUrl,
      authorName: authorName ?? this.authorName,
      diaryData: diaryData != null
          ? Map<String, dynamic>.from(diaryData)
          : Map<String, dynamic>.from(this.diaryData),
      isPublic: isPublic ?? this.isPublic,
      isDraft: isDraft ?? this.isDraft,
      styleType: styleType ?? this.styleType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory DiaryModel.fromJson(Map<String, dynamic> json) {
    final Object? rawDiaryData = json['diaryData'] ?? json['diary_data'];
    final Map<String, dynamic> parsedDiaryData = rawDiaryData
            is Map<String, dynamic>
        ? Map<String, dynamic>.from(rawDiaryData)
        : <String, dynamic>{};
    final String styleFromNested =
        (parsedDiaryData['styleType'] ?? parsedDiaryData['style_type'] ?? '')
            .toString();
    final Object? createdRaw = json['created_at'] ?? json['createdAt'];
    final Object? updatedRaw = json['updated_at'] ?? json['updatedAt'];
    final Object? rawDraft = json['is_draft'] ?? json['isDraft'];
    final bool parsedDraft = rawDraft is bool ? rawDraft : true;
    return DiaryModel(
      id: (json['id'] ?? '').toString(),
      userId: (json['user_id'] ?? json['userId'] ?? '').toString(),
      title: (json['title'] ?? '未命名手账').toString(),
      coverImageUrl:
          (json['cover_image_url'] ?? json['coverImageUrl'] ?? '').toString(),
      authorName:
          (json['author_name'] ?? json['authorName'] ?? '旅行者').toString(),
      diaryData: parsedDiaryData,
      isPublic: json['is_public'] == true || json['isPublic'] == true,
      isDraft: parsedDraft,
      styleType: (json['style_type'] ?? json['styleType'] ?? styleFromNested)
          .toString(),
      createdAt: createdRaw != null
          ? DateTime.tryParse(createdRaw.toString())
          : null,
      updatedAt: updatedRaw != null
          ? DateTime.tryParse(updatedRaw.toString())
          : null,
    );
  }

  /// 本地 SharedPreferences（camelCase 为主，便于与旧数据兼容）
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'userId': userId,
      'title': title,
      'coverImageUrl': coverImageUrl,
      'authorName': authorName,
      'styleType': styleType,
      'diaryData': diaryData,
      'isDraft': isDraft,
      'isPublic': isPublic,
      'createdAt': createdAt?.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  /// Supabase `public_diaries` upsert 行。
  /// 样式写入 `diary_data`，避免库表缺少 `style_type` 列时 PGRST204；若已建列可在库中加列后恢复顶栏字段。
  Map<String, dynamic> toSupabaseJson() {
    final Map<String, dynamic> mergedDiaryData =
        Map<String, dynamic>.from(diaryData);
    if (styleType.isNotEmpty) {
      mergedDiaryData['styleType'] = styleType;
    }
    return <String, dynamic>{
      'id': id,
      'user_id': userId,
      'title': title,
      'cover_image_url': coverImageUrl,
      'author_name': authorName,
      'is_draft': isDraft,
      'is_public': isPublic,
      'diary_data': mergedDiaryData,
      'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    };
  }
}

class DiaryProvider extends ChangeNotifier {
  DiaryProvider() {
    _hydrate();
  }

  static const String _draftsKey = 'diary_drafts_json';
  static const String _myDiariesKey = 'diary_my_diaries_json';
  static const String _communityKey = 'diary_community_diaries_json';
  static const String _tableName = 'public_diaries';

  static const Set<String> _placeholderTexts = <String>{
    '未命名景点',
    '这段旅程还没有补充描述',
    '新增景点待补充描述',
    '新增景点待补充描述...',
    '新的记录点',
    '记录这一天的精彩瞬间',
    '这一天，我们在路上...',
    '新的一天开始了...',
  };

  List<DiaryModel> _drafts = <DiaryModel>[];
  List<DiaryModel> _myDiaries = <DiaryModel>[];
  List<DiaryModel> _communityDiaries = <DiaryModel>[];

  List<DiaryModel> get drafts => _drafts;
  List<DiaryModel> get myDiaries => _myDiaries;
  List<DiaryModel> get communityDiaries => _communityDiaries;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  bool _ready = false;
  bool get isReady => _ready;

  SupabaseClient get _client => Supabase.instance.client;
  static const String _aiEndpoint = AiConfig.deepseekEndpoint;
  static const String _aiModel = AiConfig.deepseekModel;
  static const String _aiApiKey = AiConfig.deepseekApiKey;

  Future<void> _hydrate() async {
    await _loadFromLocal();
    await Future.wait<void>(<Future<void>>[
      fetchMyData(),
      fetchCommunityDiaries(),
    ]);
    _ready = true;
    notifyListeners();
  }

  Future<void> _loadFromLocal() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<DiaryModel> localDrafts = _decodeList(prefs.getString(_draftsKey));
    final List<DiaryModel> localMine = _decodeList(
      prefs.getString(_myDiariesKey),
    );
    final List<DiaryModel> localCommunity = _decodeList(
      prefs.getString(_communityKey),
    );
    _drafts = List<DiaryModel>.from(localDrafts);
    _myDiaries = List<DiaryModel>.from(localMine);
    _communityDiaries = List<DiaryModel>.from(localCommunity);
    if (_drafts.isEmpty && _myDiaries.isEmpty && _communityDiaries.isEmpty) {
      _mergeSeedTemplates();
      await _persistLocal();
      return;
    }
    final bool changed = _mergeSeedTemplates();
    if (changed) {
      await _persistLocal();
    }
  }

  /// 已登录：按 `user_id` 拉取草稿 + 我的手账；合并「纯本地未同步」条目避免被冲掉。
  Future<void> fetchMyData() async {
    final String? userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    final List<DiaryModel> keepDrafts = _drafts
        .where((DiaryModel d) => _isLocalOnlyDraftId(d.id))
        .toList();
    final List<DiaryModel> keepMine = _myDiaries
        .where((DiaryModel d) => _isLocalOnlyDraftId(d.id))
        .toList();

    _isLoading = true;
    notifyListeners();

    try {
      final List<dynamic> response = await _client
          .from(_tableName)
          .select()
          .eq('user_id', userId)
          .order('updated_at', ascending: false);

      final List<DiaryModel> allMyData = response
          .whereType<Map>()
          .map(
            (Map<dynamic, dynamic> row) =>
                DiaryModel.fromJson(Map<String, dynamic>.from(row)),
          )
          .map(_sanitizeDiaryModel)
          .toList();

      _drafts =
          List<DiaryModel>.from(allMyData.where((DiaryModel d) => d.isDraft));
      _myDiaries = List<DiaryModel>.from(
        allMyData.where((DiaryModel d) => !d.isDraft),
      );

      final Set<String> serverIds = <String>{
        ..._drafts.map((DiaryModel d) => d.id),
        ..._myDiaries.map((DiaryModel d) => d.id),
      };
      for (final DiaryModel d in keepDrafts) {
        if (!serverIds.contains(d.id)) {
          _drafts.insert(0, d);
          serverIds.add(d.id);
        }
      }
      for (final DiaryModel d in keepMine) {
        if (!serverIds.contains(d.id)) {
          _myDiaries.insert(0, d);
          serverIds.add(d.id);
        }
      }

      _mergeSeedTemplates();
      await _persistLocal();
    } catch (e, st) {
      debugPrint('获取我的手账失败: $e');
      debugPrint('$st');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 社区公开手账（发现等）
  Future<void> fetchCommunityDiaries() async {
    try {
      final List<dynamic> response = await _client
          .from(_tableName)
          .select()
          .eq('is_public', true)
          .eq('is_draft', false)
          .order('created_at', ascending: false)
          .limit(20);

      _communityDiaries = List<DiaryModel>.from(
        response
            .whereType<Map>()
            .map(
              (Map<dynamic, dynamic> row) =>
                  DiaryModel.fromJson(Map<String, dynamic>.from(row)),
            )
            .map(_sanitizeDiaryModel),
      );

      _mergeSeedTemplates();
      await _persistLocal();
      notifyListeners();
    } catch (e, st) {
      debugPrint('获取社区手账失败: $e');
      debugPrint('$st');
    }
  }

  /// 保存或更新：已登录写 Supabase；未登录或失败时仍更新本地缓存。
  Future<bool> saveDiary(DiaryModel diary) async {
    final DiaryModel sanitized = _sanitizeDiaryModel(diary);
    final String? userId = _client.auth.currentUser?.id;
    if (userId == null) {
      _updateLocalList(sanitized);
      await _persistLocal();
      return false;
    }

    try {
      final DiaryModel toSave = sanitized.copyWith(userId: userId);
      await _client.from(_tableName).upsert(toSave.toSupabaseJson());
      _updateLocalList(toSave);
      await _persistLocal();
      return true;
    } catch (e, st) {
      debugPrint('保存手账至 Supabase 失败: $e');
      debugPrint('$st');
      _updateLocalList(sanitized);
      await _persistLocal();
      return false;
    }
  }

  // ==========================================
  // 核心：调用大模型真实生成手账 JSON
  // ==========================================
  Future<Map<String, dynamic>?> generateDiaryFromAI({
    required String destination,
    required String style,
    String? daysHint,
    Map<String, dynamic>? existingPlanData,
    /// 补录往期精彩子模式：`lazy` 懒人照片池，`detailed` 精细日记（仅无 `existingPlanData` 时生效）
    String? subRecordMode,
    int? customPhotoCount,
  }) async {
    if (_aiApiKey.trim().isEmpty) {
      debugPrint('手账 AI 生成失败: API Key 为空');
      return null;
    }

    String systemPrompt = '';
    if (existingPlanData != null) {
      systemPrompt = '''
你是一个顶级的旅行手账排版与文案大师。用户刚刚结束了一趟旅行，以下是他们真实的行程数据（包含天数、景点、时间等）：
${jsonEncode(existingPlanData)}

请严格基于上述真实行程，以【$style】的心情风格，为每个景点撰写绝美的手账文案（description 字段）。
【极度重要】：
1. 必须完全保留原有的天数（days）、活动（activities）、标题（title）、时间（time）、注释（note）、照片（images）等所有字段。绝对不允许删减景点或篡改原有结构！
2. 你的任务仅仅是根据【$style】风格，为每个 activities 补充大约60-100字的高质量游记description。
3. 如果原数据中已有 note 字段（用户的个人注释），必须原封不动保留，不要修改或删除。
4. 必须返回纯正的 JSON 字符串（可以用```json包裹），严禁输出废话！
''';
    } else if ((subRecordMode ?? '').trim() == 'lazy') {
      systemPrompt = '''
你是一个感性的旅行散文家。用户批量上传了关于【$destination】的照片，希望生成一篇情绪感极强的手账。
【极其重要】：必须严格输出单一的合法 JSON 对象；不要输出 JSON 以外的任何说明文字；禁止使用 Markdown 代码块（不要出现三个反引号）。
绝对不要按时间线（Day 1、Day 2）展开；days 数组只允许 1 个元素，且该元素的 activities 只允许 1 个元素。
JSON 格式严格如下（请直接输出此结构，勿加前后缀）：
{
  "title": "根据【$destination】提炼的诗意标题，不超过10个字",
  "quote": "一段极具氛围感的引言散文",
  "dateLabel": "YYYY-MM-DD",
  "days": [
    {
      "dayTitle": "旅途掠影",
      "activities": [
        {
          "is_lazy_pool": true,
          "title": "记忆碎片",
          "description": "一段约200字的感性散文，不写具体时间点，侧重风景与情绪，风格【$style】"
        }
      ]
    }
  ]
}
''';
    } else {
      systemPrompt = '''
你是一个专业的旅行手账排版大师。用户手动输入了他记得的行程细节；下一条 user 消息中的全文即用户记叙（变量名为 destination 字段承载的同一正文）。
【绝对红线】：
1. 先概括出一个绝美的顶层 title（不超过14字），绝对禁止照抄用户原话或整段粘贴；
2. 活动节点必须严格来自用户提及的地点/行程，禁止无中生有编造用户没去过的景点；用户只写2个点就只排2条 activities；
3. 禁止用空洞模板凑景点；time 可合理推断，须与叙事顺序一致；
4. 用【$style】风格润色每条 description（约80-120字）；quote 要点题且不要复述 title。
5. 粗时间线索（若有）：${daysHint ?? '无'}，仅可辅助填写 dateLabel，不得据此编造未出现的行程点。

【极其重要】：只输出一个合法 JSON 对象；禁止使用 Markdown 代码块（不要三个反引号）；不要任何前言或尾注。
JSON 格式严格如下（顶层 title、quote、dateLabel、days 均必填）：
{
  "title": "AI概括的唯美标题",
  "quote": "风格化引言",
  "dateLabel": "YYYY-MM-DD",
  "days": [
    {
      "dayTitle": "AI提炼的当天主题",
      "activities": [
        {
          "time": "合理预估时间",
          "title": "景点名",
          "description": "润色后的游记文案"
        }
      ]
    }
  ]
}
''';
    }

    try {
      String userContent = '请帮我生成手账！';
      if (existingPlanData == null) {
        if ((subRecordMode ?? '').trim() == 'lazy') {
          userContent =
              '【输出要求】从第一个 { 到最后一个 } 仅输出合法 JSON，禁止 Markdown。用户已选约 ${customPhotoCount ?? 0} 张本地照片（不要在 JSON 中写文件路径）。目的地/情绪线索：$destination';
        } else {
          userContent =
              '以下为用户的行程记叙全文，请严格据此生成 JSON，禁止添加未出现的景点：\n\n$destination';
        }
      }

      final http.Response response = await http
          .post(
            Uri.parse(_aiEndpoint),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_aiApiKey',
            },
            body: jsonEncode(<String, dynamic>{
              'model': _aiModel,
              'messages': <Map<String, String>>[
                <String, String>{'role': 'system', 'content': systemPrompt},
                <String, String>{'role': 'user', 'content': userContent},
              ],
            }),
          )
          .timeout(const Duration(seconds: 90)); // 增加超时时间到 90 秒，支持大行程数据

      if (response.statusCode != 200) {
        debugPrint('手账 AI 生成失败: HTTP ${response.statusCode}');
        return null;
      }
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final String content =
          (((data['choices'] as List?)?.first as Map?)?['message'] as Map?)?['content']
                  ?.toString() ??
              '';
      if (content.isEmpty) return null;
      final String jsonString = _extractJsonPayload(content);
      final Object? parsed = jsonDecode(jsonString);
      if (parsed is Map<String, dynamic>) {
        if (existingPlanData == null &&
            (subRecordMode ?? '').trim() == 'lazy') {
          return _postProcessLazyDiaryJson(parsed);
        }
        return parsed;
      }
    } catch (e) {
      debugPrint('手账 AI 生成失败: $e');
    }
    return null;
  }

  /// 补录 `subRecordMode == lazy`：字段对齐，并强制补齐 `is_lazy_pool`（模型偶发漏标）。
  Map<String, dynamic> _postProcessLazyDiaryJson(Map<String, dynamic> raw) {
    final Map<String, dynamic> out = Map<String, dynamic>.from(raw);
    final String aiQuote = (out['aiQuote'] ?? '').toString().trim();
    final String quote = (out['quote'] ?? '').toString().trim();
    if (aiQuote.isNotEmpty && quote.isEmpty) {
      out['quote'] = aiQuote;
    }
    final Object? dl = out['dateLabel'];
    if (dl == null || dl.toString().trim().isEmpty) {
      out['dateLabel'] = DateTime.now().toIso8601String().split('T').first;
    }
    _coerceLazyPoolFlagsInDiaryJson(out);
    return out;
  }

  void _coerceLazyPoolFlagsInDiaryJson(Map<String, dynamic> data) {
    final Object? daysRaw = data['days'];
    if (daysRaw is! List<dynamic>) return;
    for (final Object? d in daysRaw) {
      if (d is! Map<String, dynamic>) continue;
      final Object? actsRaw = d['activities'];
      if (actsRaw is! List<dynamic>) continue;
      for (int i = 0; i < actsRaw.length; i++) {
        final Object? a = actsRaw[i];
        if (a is! Map<String, dynamic>) continue;
        final String t = (a['title'] ?? '').toString();
        final String flag = a['is_lazy_pool']?.toString().toLowerCase() ?? '';
        if (a['is_lazy_pool'] == true ||
            flag == 'true' ||
            flag == '1' ||
            t.contains('记忆碎片')) {
          a['is_lazy_pool'] = true;
        }
      }
    }
  }

  Future<String?> polishDiaryTextWithAI({
    required String sourceText,
    required String style,
  }) async {
    if (_aiApiKey.trim().isEmpty) {
      debugPrint('AI 润色失败: API Key 为空');
      return null;
    }
    try {
      final http.Response response = await http
          .post(
            Uri.parse(_aiEndpoint),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_aiApiKey',
            },
            body: jsonEncode(<String, dynamic>{
              'model': _aiModel,
              'messages': <Map<String, String>>[
                <String, String>{
                  'role': 'system',
                  'content': '你是旅行文案润色专家。请只返回润色后的文本，不要解释。',
                },
                <String, String>{
                  'role': 'user',
                  'content': '请用$style风格润色这段旅行文字：$sourceText',
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final Map<String, dynamic> data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final String content =
          (((data['choices'] as List?)?.first as Map?)?['message'] as Map?)?['content']
                  ?.toString()
                  .trim() ??
              '';
      if (content.isEmpty) return null;
      return _stripMarkdownFence(content).trim();
    } catch (e) {
      debugPrint('AI 润色失败: $e');
      return null;
    }
  }

  Future<String?> uploadDiaryCoverImage(String filePath) async {
    try {
      final String? userId = _client.auth.currentUser?.id;
      if (userId == null || filePath.trim().isEmpty) return null;
      final String ext = filePath.contains('.')
          ? filePath.split('.').last.toLowerCase()
          : 'jpg';
      final String fileName = '${DateTime.now().millisecondsSinceEpoch}.$ext';
      final String storagePath = 'diaries/$userId/covers/$fileName';
      const List<String> buckets = <String>['diary_photos', 'itinerary_photos'];

      for (final String bucket in buckets) {
        try {
          await _client.storage.from(bucket).upload(storagePath, File(filePath));
          return _client.storage.from(bucket).getPublicUrl(storagePath);
        } catch (_) {
          // Try next candidate bucket.
        }
      }
    } catch (e) {
      debugPrint('上传手账封面失败: $e');
    }
    return null;
  }

  String _extractJsonPayload(String content) {
    final String stripped = _stripMarkdownFence(content).trim();
    return stripped;
  }

  String _stripMarkdownFence(String text) {
    String out = text.trim();
    if (out.contains('```json')) {
      out = out.split('```json')[1].split('```')[0];
    } else if (out.contains('```')) {
      out = out.split('```')[1].split('```')[0];
    }
    return out;
  }

  /// 先请求云端删除；失败仅记日志，仍做本地乐观清理（与模板一致）。
  Future<bool> deleteDiary(String diaryId) async {
    try {
      await _client.from(_tableName).delete().eq('id', diaryId);
    } catch (e, st) {
      debugPrint('云端删除手账失败 (可能为断网或纯本地数据): $e');
      debugPrint('$st');
    }

    _drafts = List<DiaryModel>.from(_drafts);
    _myDiaries = List<DiaryModel>.from(_myDiaries);
    _communityDiaries = List<DiaryModel>.from(_communityDiaries);
    _drafts.removeWhere((DiaryModel d) => d.id == diaryId);
    _myDiaries.removeWhere((DiaryModel d) => d.id == diaryId);
    _communityDiaries.removeWhere((DiaryModel d) => d.id == diaryId);
    notifyListeners();
    await _persistLocal();
    return true;
  }

  void _updateLocalList(DiaryModel diary) {
    _drafts = List<DiaryModel>.from(_drafts);
    _myDiaries = List<DiaryModel>.from(_myDiaries);
    _communityDiaries = List<DiaryModel>.from(_communityDiaries);

    _drafts.removeWhere((DiaryModel d) => d.id == diary.id);
    _myDiaries.removeWhere((DiaryModel d) => d.id == diary.id);
    _communityDiaries.removeWhere((DiaryModel d) => d.id == diary.id);

    if (diary.isDraft) {
      _drafts.insert(0, diary);
    } else {
      _myDiaries.insert(0, diary);
      if (diary.isPublic) {
        _communityDiaries.insert(0, diary);
      }
    }

    notifyListeners();
  }

  bool _isLocalOnlyDraftId(String diaryId) {
    if (diaryId.isEmpty) return false;
    if (!diaryId.contains('-')) return true;
    if (diaryId.startsWith('seed-')) return true;
    if (diaryId.startsWith('local_')) return true;
    return false;
  }

  /// 确保模板手账对所有用户都可见（首次安装、换账号、弱网场景均补齐）。
  /// 返回值表示是否有列表被修改。
  bool _mergeSeedTemplates() {
    bool changed = false;
    for (final DiaryModel seed in _seedDiaries()) {
      if (seed.isDraft) {
        final bool exists = _drafts.any((DiaryModel d) => d.id == seed.id);
        if (!exists) {
          _drafts.add(seed);
          changed = true;
        }
      } else {
        final bool exists = _myDiaries.any((DiaryModel d) => d.id == seed.id);
        if (!exists) {
          _myDiaries.add(seed);
          changed = true;
        }
      }

      if (seed.isPublic) {
        final bool exists = _communityDiaries.any((DiaryModel d) => d.id == seed.id);
        if (!exists) {
          _communityDiaries.add(seed);
          changed = true;
        }
      }
    }
    return changed;
  }

  List<DiaryModel> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return <DiaryModel>[];
    final Object? parsed = jsonDecode(raw);
    if (parsed is! List) return <DiaryModel>[];
    return parsed
        .whereType<Map<String, dynamic>>()
        .map(DiaryModel.fromJson)
        .map(_sanitizeDiaryModel)
        .toList();
  }

  String _sanitizeText(dynamic value) {
    final String text = (value ?? '').toString().trim();
    if (text.isEmpty || _placeholderTexts.contains(text)) return '';
    return text;
  }

  Map<String, dynamic> _sanitizeDayMap(Map<String, dynamic> day) {
    final Map<String, dynamic> out = Map<String, dynamic>.from(day);
    if (out.containsKey('summary')) {
      out['summary'] = _sanitizeText(out['summary']);
    }
    if (out.containsKey('title')) {
      out['title'] = _sanitizeText(out['title']);
    }
    if (out.containsKey('description')) {
      out['description'] = _sanitizeText(out['description']);
    }
    if (out.containsKey('time')) {
      out['time'] = (out['time'] ?? '').toString().trim();
    }

    final List<dynamic> rawActivities =
        (out['activities'] as List<dynamic>?) ?? <dynamic>[];
    out['activities'] = rawActivities.map((dynamic activityRaw) {
      final Map<String, dynamic> activity =
          Map<String, dynamic>.from(activityRaw as Map? ?? <String, dynamic>{});
      activity['title'] = _sanitizeText(activity['title']);
      activity['description'] = _sanitizeText(activity['description']);
      activity['time'] = (activity['time'] ?? '').toString().trim();
      return activity;
    }).toList(growable: false);
    return out;
  }

  Map<String, dynamic> _sanitizeDiaryData(Map<String, dynamic> data) {
    final Map<String, dynamic> out = Map<String, dynamic>.from(data);
    if (out.containsKey('summary')) {
      out['summary'] = _sanitizeText(out['summary']);
    }
    if (out.containsKey('quote')) {
      out['quote'] = _sanitizeText(out['quote']);
    }
    final List<dynamic> rawDays = (out['days'] as List<dynamic>?) ?? <dynamic>[];
    out['days'] = rawDays
        .map(
          (dynamic dayRaw) =>
              _sanitizeDayMap(Map<String, dynamic>.from(dayRaw as Map? ?? <String, dynamic>{})),
        )
        .toList(growable: false);
    return out;
  }

  DiaryModel _sanitizeDiaryModel(DiaryModel diary) {
    return diary.copyWith(
      title: _sanitizeText(diary.title),
      diaryData: _sanitizeDiaryData(diary.diaryData),
    );
  }

  Future<void> _persistLocal() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _draftsKey,
      jsonEncode(
        _drafts.map((DiaryModel e) => e.toJson()).toList(growable: false),
      ),
    );
    await prefs.setString(
      _myDiariesKey,
      jsonEncode(
        _myDiaries.map((DiaryModel e) => e.toJson()).toList(growable: false),
      ),
    );
    await prefs.setString(
      _communityKey,
      jsonEncode(
        _communityDiaries
            .map((DiaryModel e) => e.toJson())
            .toList(growable: false),
      ),
    );
  }

  List<DiaryModel> _seedDiaries() {
    return <DiaryModel>[
      DiaryModel(
        id: 'seed-kyoto-01',
        userId: '',
        title: '京都初夏风物诗',
        coverImageUrl:
            'https://images.unsplash.com/photo-1492571350019-22de08371fd3?auto=format&fit=crop&w=1200&q=80',
        authorName: '旅行者_Leo',
        isDraft: false,
        isPublic: true,
        styleType: '文艺清新',
        diaryData: <String, dynamic>{
          'dateLabel': '2026.04.16',
          'likes': 298,
          'summary': '沿鸭川慢行，抄一页风声与花影。',
          'quote': '每次出发，都是对平淡生活的一次温柔越狱。',
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'day': 1,
              'title': '清晨伏见稻荷',
              'description': '顺着鸟居一路上行，山风夹带木香。',
              'lat': 34.9671,
              'lng': 135.7727,
              'photos': <String>[
                'https://images.unsplash.com/photo-1503899036084-c55cdd92da26?auto=format&fit=crop&w=900&q=80',
                'https://images.unsplash.com/photo-1480796927426-f609979314bd?auto=format&fit=crop&w=900&q=80',
              ],
            },
          ],
        },
      ),
      DiaryModel(
        id: 'seed-osaka-02',
        userId: '',
        title: '大阪夜色与霓虹胃口',
        coverImageUrl:
            'https://images.unsplash.com/photo-1542051841857-5f90071e7989?auto=format&fit=crop&w=1200&q=80',
        authorName: '旅行者_Mia',
        isDraft: false,
        isPublic: true,
        styleType: '电影质感',
        diaryData: <String, dynamic>{
          'dateLabel': '2026.03.09',
          'likes': 431,
          'summary': '心斋桥的灯牌会把晚风也染成彩色。',
          'quote': '一碗热汤，一条闪烁街道，足够记住一座城。',
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'day': 1,
              'title': '道顿堀',
              'description': '章鱼烧和拉面的香气不断叠加。',
              'lat': 34.6687,
              'lng': 135.5013,
              'photos': <String>[
                'https://images.unsplash.com/photo-1528360983277-13d401cdc186?auto=format&fit=crop&w=900&q=80',
              ],
            },
          ],
        },
      ),
      DiaryModel(
        id: 'seed-draft-03',
        userId: '',
        title: '阿那亚周末海风实验',
        coverImageUrl:
            'https://images.unsplash.com/photo-1473116763249-2faaef81ccda?auto=format&fit=crop&w=1200&q=80',
        authorName: '旅行者_Leo',
        isDraft: true,
        isPublic: false,
        styleType: '孤独探索者',
        diaryData: <String, dynamic>{
          'dateLabel': '2026.05.01',
          'likes': 0,
          'summary': '草稿未完成，等待补图。',
          'quote': '海边的句子，总在夜里自动续写。',
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'day': 1,
              'title': '海边图书馆',
              'description': '白色建筑把潮汐声收得很轻。',
              'lat': 39.5593,
              'lng': 119.6373,
              'photos': <String>[],
            },
          ],
        },
      ),
    ];
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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

    // ── 大行程拆分策略：按天分批，每批独立请求，规避后台被掐 ──
    if (existingPlanData != null) {
      return _generateByDayBatches(
        existingPlanData: existingPlanData,
        style: style,
      );
    }

    // 补录/自定义模式：内容短，直接单次请求
    return _generateSingleShot(
      destination: destination,
      style: style,
      daysHint: daysHint,
      subRecordMode: subRecordMode,
      customPhotoCount: customPhotoCount,
    );
  }

  /// 按天分批生成：每次只发一天的数据给 AI，单批 < 10 秒，后台也能完成
  Future<Map<String, dynamic>?> _generateByDayBatches({
    required Map<String, dynamic> existingPlanData,
    required String style,
  }) async {
    final List<dynamic> days =
        (existingPlanData['days'] as List<dynamic>?) ??
        (existingPlanData['daily_schedules'] as List<dynamic>?) ??
        <dynamic>[];

    if (days.isEmpty) return null;

    // 先用单次请求获取顶层 quote / dateLabel / title
    final String metaPrompt = '''
你是旅行手账文案大师。根据以下行程信息，只生成3个字段，直接输出合法JSON，无其他内容：
目的地：${existingPlanData['destinationCity'] ?? existingPlanData['destination'] ?? ''}
天数：${days.length}天
风格：$style

输出格式（严格JSON，无markdown）：
{"title":"唯美标题不超过14字","quote":"风格化引言一句话","dateLabel":"YYYY-MM-DD"}
''';

    final Map<String, dynamic>? metaResult = await _singleRequest(
      systemPrompt: metaPrompt,
      userContent: '请生成标题和引言',
      timeoutSeconds: 30,
    );

    // 逐天为每个 activity 补充 description
    final List<dynamic> processedDays = <dynamic>[];
    for (int i = 0; i < days.length; i++) {
      final Map<String, dynamic> day =
          Map<String, dynamic>.from(days[i] as Map? ?? <String, dynamic>{});
      final List<dynamic> activities =
          (day['activities'] as List<dynamic>?) ?? <dynamic>[];
      if (activities.isEmpty) {
        processedDays.add(day);
        continue;
      }

      final String dayPrompt = '''
你是旅行手账文案大师。以【$style】风格，为以下第${i + 1}天的每个活动补充约80字的 description。
只输出合法JSON数组，每个元素只有 "title" 和 "description" 两个字段，无其他内容，无markdown：
${jsonEncode(activities.map((dynamic a) {
  final Map<String, dynamic> act = Map<String, dynamic>.from(a as Map? ?? <String, dynamic>{});
  return <String, dynamic>{'title': act['title'] ?? ''};
}).toList())}
''';

      final Map<String, dynamic>? dayResult = await _singleRequest(
        systemPrompt: dayPrompt,
        userContent: '请补充description',
        timeoutSeconds: 25,
        expectArray: true,
      );

      // 把 AI 返回的 description 合并回原始 activities
      if (dayResult != null) {
        final List<dynamic> aiActs =
            (dayResult['items'] as List<dynamic>?) ?? <dynamic>[];
        final List<dynamic> mergedActivities = <dynamic>[];
        for (int j = 0; j < activities.length; j++) {
          final Map<String, dynamic> orig =
              Map<String, dynamic>.from(activities[j] as Map? ?? <String, dynamic>{});
          if (j < aiActs.length) {
            final Map<String, dynamic> aiAct =
                Map<String, dynamic>.from(aiActs[j] as Map? ?? <String, dynamic>{});
            orig['description'] = aiAct['description'] ?? orig['description'] ?? '';
          }
          mergedActivities.add(orig);
        }
        day['activities'] = mergedActivities;
      }
      processedDays.add(day);
    }

    // 组装最终结果
    final Map<String, dynamic> result =
        Map<String, dynamic>.from(existingPlanData);
    result['days'] = processedDays;
    if (metaResult != null) {
      result['title'] = metaResult['title'] ?? '';
      result['quote'] = metaResult['quote'] ?? '用$style的方式，记录这段闪光的日子。';
      result['dateLabel'] = metaResult['dateLabel'] ?? '';
    }
    return result;
  }

  /// 单次请求（补录/自定义模式，内容短）
  Future<Map<String, dynamic>?> _generateSingleShot({
    required String destination,
    required String style,
    String? daysHint,
    String? subRecordMode,
    int? customPhotoCount,
  }) async {
    String systemPrompt;
    String userContent;

    if ((subRecordMode ?? '').trim() == 'lazy') {
      systemPrompt = '''
你是一个感性的旅行散文家。用户批量上传了关于【$destination】的照片，希望生成一篇情绪感极强的手账。
【极其重要】：必须严格输出单一的合法 JSON 对象；禁止Markdown。days数组只允许1个元素，activities只允许1个元素。
JSON格式：{"title":"诗意标题","quote":"引言","dateLabel":"YYYY-MM-DD","days":[{"dayTitle":"旅途掠影","activities":[{"is_lazy_pool":true,"title":"记忆碎片","description":"约200字感性散文，风格【$style】"}]}]}
''';
      userContent = '用户已选约 ${customPhotoCount ?? 0} 张照片。目的地：$destination';
    } else {
      systemPrompt = '''
你是专业的旅行手账排版大师。根据用户的行程记叙生成手账JSON。
风格：【$style】，description约80-120字。
时间线索：${daysHint ?? '无'}
只输出合法JSON，无markdown：{"title":"标题","quote":"引言","dateLabel":"YYYY-MM-DD","days":[{"dayTitle":"主题","activities":[{"time":"时间","title":"景点","description":"文案"}]}]}
''';
      userContent = '以下为行程记叙，请据此生成JSON：\n\n$destination';
    }

    final Map<String, dynamic>? result = await _singleRequest(
      systemPrompt: systemPrompt,
      userContent: userContent,
      timeoutSeconds: 40,
    );

    if (result != null && (subRecordMode ?? '').trim() == 'lazy') {
      return _postProcessLazyDiaryJson(result);
    }
    return result;
  }

  /// 底层单次 HTTP 请求，带重试，超时控制在 [timeoutSeconds] 秒内
  Future<Map<String, dynamic>?> _singleRequest({
    required String systemPrompt,
    required String userContent,
    required int timeoutSeconds,
    bool expectArray = false, // true 时返回 {"items": [...]}
  }) async {
    const int maxRetries = 3;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final String? content = await _callAiInIsolate(
          endpoint: _aiEndpoint,
          apiKey: _aiApiKey,
          body: jsonEncode(<String, dynamic>{
            'model': _aiModel,
            'stream': true,
            'max_tokens': 2048,
            'messages': <Map<String, String>>[
              <String, String>{'role': 'system', 'content': systemPrompt},
              <String, String>{'role': 'user', 'content': userContent},
            ],
          }),
          timeoutSeconds: timeoutSeconds,
        );

        if (content == null || content.isEmpty) {
          debugPrint('AI 请求失败 (第 $attempt 次): 响应为空');
          if (attempt < maxRetries) {
            await Future<void>.delayed(Duration(seconds: attempt * 4));
          }
          continue;
        }

        String jsonString = _extractJsonPayload(content);

        // expectArray 模式：AI 返回 JSON 数组，包装成 {"items": [...]}
        if (expectArray && jsonString.trimLeft().startsWith('[')) {
          jsonString = '{"items": $jsonString}';
        }

        final Object? parsed = jsonDecode(jsonString);
        if (parsed is Map<String, dynamic>) return parsed;

        // 结构不对，重试
        debugPrint('AI 返回结构异常 (第 $attempt 次)，重试');
        if (attempt < maxRetries) {
          await Future<void>.delayed(Duration(seconds: attempt * 4));
        }
      } catch (e) {
        // FormatException 也在这里被捕获，继续重试
        debugPrint('AI 请求失败 (第 $attempt 次): $e');
        if (attempt < maxRetries) {
          await Future<void>.delayed(Duration(seconds: attempt * 4));
        }
      }
    }
    return null;
  }

  // ==========================================
  // 后台生成：任务状态管理
  // ==========================================

  /// 后台生成任务状态
  String? _backgroundTaskId;
  String _backgroundTaskStatus = 'idle'; // idle | running | done | error
  Map<String, dynamic>? _backgroundResult;
  String? _backgroundError;
  DiaryModel? _backgroundGeneratedDiary;

  String? get backgroundTaskId => _backgroundTaskId;
  String get backgroundTaskStatus => _backgroundTaskStatus;
  Map<String, dynamic>? get backgroundResult => _backgroundResult;
  String? get backgroundError => _backgroundError;
  DiaryModel? get backgroundGeneratedDiary => _backgroundGeneratedDiary;

  /// 是否有已完成但未消费的后台结果
  bool get hasUnreadBackgroundResult =>
      _backgroundTaskStatus == 'done' && _backgroundGeneratedDiary != null;

  /// 清除后台任务状态（结果被消费后调用）
  void clearBackgroundTask() {
    _backgroundTaskId = null;
    _backgroundTaskStatus = 'idle';
    _backgroundResult = null;
    _backgroundError = null;
    _backgroundGeneratedDiary = null;
    notifyListeners();
  }

  /// 后台异步启动 AI 生成，立即返回 taskId，不阻塞调用方。
  /// 生成完成后通过 notifyListeners() 通知 UI，调用方监听 [backgroundTaskStatus] 即可。
  String startBackgroundGenerate({
    required String destination,
    required String style,
    required String newDiaryId,
    required String newDiaryTitle,
    required String coverImageUrl,
    String? daysHint,
    Map<String, dynamic>? existingPlanData,
    String? subRecordMode,
    int? customPhotoCount,
    // 已组装好的最终数据（懒人池照片注入等需在调用方完成后传入 null 时走 AI 路径）
    Map<String, dynamic>? preBuiltDiaryData,
  }) {
    final String taskId =
        'bg_${DateTime.now().millisecondsSinceEpoch}';
    _backgroundTaskId = taskId;
    _backgroundTaskStatus = 'running';
    _backgroundResult = null;
    _backgroundError = null;
    _backgroundGeneratedDiary = null;
    notifyListeners();

    // 使用 unawaited future 真正后台运行，不持有调用栈
    _runBackgroundGenerate(
      taskId: taskId,
      destination: destination,
      style: style,
      newDiaryId: newDiaryId,
      newDiaryTitle: newDiaryTitle,
      coverImageUrl: coverImageUrl,
      daysHint: daysHint,
      existingPlanData: existingPlanData,
      subRecordMode: subRecordMode,
      customPhotoCount: customPhotoCount,
      preBuiltDiaryData: preBuiltDiaryData,
    );

    return taskId;
  }

  Future<void> _runBackgroundGenerate({
    required String taskId,
    required String destination,
    required String style,
    required String newDiaryId,
    required String newDiaryTitle,
    required String coverImageUrl,
    String? daysHint,
    Map<String, dynamic>? existingPlanData,
    String? subRecordMode,
    int? customPhotoCount,
    Map<String, dynamic>? preBuiltDiaryData,
  }) async {
    try {
      Map<String, dynamic>? finalDiaryData = preBuiltDiaryData;

      if (finalDiaryData == null) {
        // 需要调用 AI 生成
        final Map<String, dynamic>? aiData = await generateDiaryFromAI(
          destination: destination,
          style: style,
          daysHint: daysHint,
          existingPlanData: existingPlanData,
          subRecordMode: subRecordMode,
          customPhotoCount: customPhotoCount,
        );

        if (aiData == null) {
          // 任务 id 已被新任务替换时，静默忽略旧结果
          if (_backgroundTaskId != taskId) return;
          _backgroundTaskStatus = 'error';
          _backgroundError = 'AI 思考超时了，请检查网络后重试';
          notifyListeners();
          return;
        }
        finalDiaryData = aiData;
      }

      if (_backgroundTaskId != taskId) return;

      final DiaryModel generatedDiary = DiaryModel(
        id: newDiaryId,
        userId: _client.auth.currentUser?.id ?? 'current_user',
        title: newDiaryTitle,
        authorName: '旅行者',
        coverImageUrl: coverImageUrl,
        isDraft: true,
        isPublic: false,
        styleType: style,
        diaryData: finalDiaryData,
      );

      // 自动保存草稿，应用挂后台也能持久化
      await saveDiary(generatedDiary);

      if (_backgroundTaskId != taskId) return;

      _backgroundResult = finalDiaryData;
      _backgroundGeneratedDiary = generatedDiary;
      _backgroundTaskStatus = 'done';
      notifyListeners();
    } catch (e, st) {
      debugPrint('后台生成手账失败: $e');
      debugPrint('$st');
      if (_backgroundTaskId != taskId) return;
      _backgroundTaskStatus = 'error';
      _backgroundError = '生成失败：$e';
      notifyListeners();
    }
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
    String stripped = _stripMarkdownFence(content).trim();

    // ── 核心修复：清除字符串值内的非法控制字符 ──
    // JSON 规范禁止字符串内出现未转义的 0x00-0x1F 控制字符（换行、回车、制表符等）
    // DeepSeek 流式输出偶发真实换行符，直接导致 jsonDecode 抛 FormatException
    stripped = _sanitizeJsonControlChars(stripped);

    return stripped;
  }

  /// 把 JSON 字符串值内的裸控制字符替换为合法转义序列
  String _sanitizeJsonControlChars(String raw) {
    final StringBuffer out = StringBuffer();
    bool inString = false;
    bool escaped = false;

    for (int i = 0; i < raw.length; i++) {
      final int code = raw.codeUnitAt(i);
      final String ch = raw[i];

      if (escaped) {
        out.write(ch);
        escaped = false;
        continue;
      }

      if (ch == r'\' && inString) {
        escaped = true;
        out.write(ch);
        continue;
      }

      if (ch == '"') {
        inString = !inString;
        out.write(ch);
        continue;
      }

      // 字符串内的裸控制字符 → 替换为合法转义
      if (inString && code < 0x20) {
        switch (code) {
          case 0x0A: out.write(r'\n'); break;   // 换行
          case 0x0D: out.write(r'\r'); break;   // 回车
          case 0x09: out.write(r'\t'); break;   // 制表符
          default:   out.write('\\u${code.toRadixString(16).padLeft(4, '0')}'); break;
        }
        continue;
      }

      out.write(ch);
    }

    return out.toString();
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

  /// 在独立 Isolate 内用 dart:io HttpClient 调用 AI 接口。
  /// Isolate 不受主线程 App 生命周期约束，后台也能稳定完成请求。
  static Future<String?> _callAiInIsolate({
    required String endpoint,
    required String apiKey,
    required String body,
    required int timeoutSeconds,
  }) async {
    final ReceivePort receivePort = ReceivePort();
    await Isolate.spawn(
      _isolateAiTask,
      _IsolateAiPayload(
        sendPort: receivePort.sendPort,
        endpoint: endpoint,
        apiKey: apiKey,
        body: body,
        timeoutSeconds: timeoutSeconds,
      ),
    );
    final Object? result = await receivePort.first;
    if (result is String) return result;
    return null;
  }

  /// Isolate 入口函数（必须是顶层函数或 static）
  static Future<void> _isolateAiTask(_IsolateAiPayload payload) async {
    final http.Client client = http.Client();
    final StringBuffer contentBuffer = StringBuffer();
    try {
      // 构造请求体，加入 stream: true 开启流式输出
      final Map<String, dynamic> requestBody =
          jsonDecode(payload.body) as Map<String, dynamic>;

      final http.Request request = http.Request(
        'POST',
        Uri.parse(payload.endpoint),
      );
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.headers['Authorization'] = 'Bearer ${payload.apiKey}';
      request.headers['Accept'] = 'text/event-stream';
      request.bodyBytes = utf8.encode(jsonEncode(requestBody));

      // send() 返回 StreamedResponse，数据边到边处理，不等全部完成
      final http.StreamedResponse streamedResponse = await client
          .send(request)
          .timeout(const Duration(seconds: 20));

      if (streamedResponse.statusCode != 200) {
        payload.sendPort.send(null);
        return;
      }

      bool receivedDone = false;
      // 逐块读取 SSE 数据，每块都是活跃传输，系统不会掐断
      await for (final String chunk in streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(Duration(seconds: payload.timeoutSeconds))) {
        // SSE 格式：每行是 "data: {...}" 或 "data: [DONE]"
        if (!chunk.startsWith('data: ')) continue;
        final String data = chunk.substring(6).trim();
        if (data == '[DONE]') {
          receivedDone = true;
          break;
        }
        try {
          final Map<String, dynamic> json =
              jsonDecode(data) as Map<String, dynamic>;
          final String? delta =
              ((json['choices'] as List?)?.first as Map?)?['delta']
                  ?['content']
                  ?.toString();
          if (delta != null && delta.isNotEmpty) {
            contentBuffer.write(delta);
          }
        } catch (_) {}
      }

      if (!receivedDone) {
        // 响应被截断，返回 null 触发重试
        debugPrint('Isolate AI 响应被截断（未收到 [DONE]）');
        payload.sendPort.send(null);
        return;
      }

      final String result = contentBuffer.toString().trim();
      payload.sendPort.send(result.isEmpty ? null : result);
    } catch (e) {
      debugPrint('Isolate AI 请求失败: $e');
      payload.sendPort.send(null);
    } finally {
      client.close();
    }
  }
}

/// Isolate 通信数据包（必须全部是可跨 Isolate 传递的基础类型）
class _IsolateAiPayload {
  const _IsolateAiPayload({
    required this.sendPort,
    required this.endpoint,
    required this.apiKey,
    required this.body,
    required this.timeoutSeconds,
  });
  final SendPort sendPort;
  final String endpoint;
  final String apiKey;
  final String body;
  final int timeoutSeconds;
}

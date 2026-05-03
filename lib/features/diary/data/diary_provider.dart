import 'dart:convert';

import 'package:flutter/foundation.dart';
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

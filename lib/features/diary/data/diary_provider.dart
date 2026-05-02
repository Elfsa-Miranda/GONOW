import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DiaryModel {
  const DiaryModel({
    required this.id,
    required this.title,
    required this.coverImageUrl,
    required this.authorName,
    required this.isDraft,
    required this.isPublic,
    required this.styleType,
    required this.diaryData,
  });

  final String id;
  final String title;
  final String coverImageUrl;
  final String authorName;
  final bool isDraft;
  final bool isPublic;
  final String styleType;
  final Map<String, dynamic> diaryData;

  DiaryModel copyWith({
    String? id,
    String? title,
    String? coverImageUrl,
    String? authorName,
    bool? isDraft,
    bool? isPublic,
    String? styleType,
    Map<String, dynamic>? diaryData,
  }) {
    return DiaryModel(
      id: id ?? this.id,
      title: title ?? this.title,
      coverImageUrl: coverImageUrl ?? this.coverImageUrl,
      authorName: authorName ?? this.authorName,
      isDraft: isDraft ?? this.isDraft,
      isPublic: isPublic ?? this.isPublic,
      styleType: styleType ?? this.styleType,
      diaryData: diaryData ?? this.diaryData,
    );
  }

  factory DiaryModel.fromJson(Map<String, dynamic> json) {
    final Object? rawDiaryData = json['diaryData'] ?? json['diary_data'];
    return DiaryModel(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      coverImageUrl: (json['coverImageUrl'] ?? json['cover_image_url'] ?? '')
          .toString(),
      authorName: (json['authorName'] ?? json['author_name'] ?? '').toString(),
      isDraft: json['isDraft'] == true || json['is_draft'] == true,
      isPublic: json['isPublic'] == true || json['is_public'] == true,
      styleType: (json['styleType'] ?? json['style_type'] ?? '').toString(),
      diaryData: rawDiaryData is Map<String, dynamic>
          ? rawDiaryData
          : <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'coverImageUrl': coverImageUrl,
      'authorName': authorName,
      'isDraft': isDraft,
      'isPublic': isPublic,
      'styleType': styleType,
      'diaryData': diaryData,
    };
  }

  Map<String, dynamic> toSupabaseJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'cover_image_url': coverImageUrl,
      'author_name': authorName,
      'is_draft': isDraft,
      'is_public': isPublic,
      'style_type': styleType,
      'diary_data': diaryData,
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
  static const String _tableName = 'travel_diaries';

  final List<DiaryModel> drafts = <DiaryModel>[];
  final List<DiaryModel> myDiaries = <DiaryModel>[];
  final List<DiaryModel> communityDiaries = <DiaryModel>[];

  bool _ready = false;
  bool get isReady => _ready;

  SupabaseClient get _client => Supabase.instance.client;

  Future<void> _hydrate() async {
    await _loadFromLocal();
    await _syncFromSupabase();
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
    drafts
      ..clear()
      ..addAll(localDrafts);
    myDiaries
      ..clear()
      ..addAll(localMine);
    communityDiaries
      ..clear()
      ..addAll(localCommunity);
    if (drafts.isEmpty && myDiaries.isEmpty && communityDiaries.isEmpty) {
      final List<DiaryModel> seed = _seedDiaries();
      myDiaries.addAll(seed.where((DiaryModel d) => !d.isDraft));
      communityDiaries.addAll(seed.where((DiaryModel d) => d.isPublic));
      drafts.addAll(seed.where((DiaryModel d) => d.isDraft));
      await _persistLocal();
    }
  }

  Future<void> _syncFromSupabase() async {
    try {
      final List<dynamic> rows = await _client
          .from(_tableName)
          .select()
          .order('updated_at', ascending: false);
      if (rows.isEmpty) return;
      final List<DiaryModel> all = rows
          .whereType<Map<String, dynamic>>()
          .map(DiaryModel.fromJson)
          .toList(growable: false);
      drafts
        ..clear()
        ..addAll(all.where((DiaryModel d) => d.isDraft));
      myDiaries
        ..clear()
        ..addAll(all.where((DiaryModel d) => !d.isDraft));
      communityDiaries
        ..clear()
        ..addAll(all.where((DiaryModel d) => d.isPublic));
      await _persistLocal();
    } catch (_) {
      // Supabase 不可用时保持本地数据作为兜底。
    }
  }

  Future<void> saveDiary(DiaryModel diary) async {
    _upsertLocalInMemory(diary);
    notifyListeners();
    await _persistLocal();
    try {
      await _client.from(_tableName).upsert(diary.toSupabaseJson());
    } catch (_) {
      // 已在本地持久化，不阻断用户流程。
    }
  }

  Future<void> deleteDiary(String id) async {
    drafts.removeWhere((DiaryModel e) => e.id == id);
    myDiaries.removeWhere((DiaryModel e) => e.id == id);
    communityDiaries.removeWhere((DiaryModel e) => e.id == id);
    notifyListeners();
    await _persistLocal();
    try {
      await _client.from(_tableName).delete().eq('id', id);
    } catch (_) {
      // 远端失败时保留本地删除结果。
    }
  }

  List<DiaryModel> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return <DiaryModel>[];
    final Object? parsed = jsonDecode(raw);
    if (parsed is! List) return <DiaryModel>[];
    return parsed
        .whereType<Map<String, dynamic>>()
        .map(DiaryModel.fromJson)
        .toList();
  }

  void _upsertLocalInMemory(DiaryModel diary) {
    drafts.removeWhere((DiaryModel e) => e.id == diary.id);
    myDiaries.removeWhere((DiaryModel e) => e.id == diary.id);
    communityDiaries.removeWhere((DiaryModel e) => e.id == diary.id);
    if (diary.isDraft) {
      drafts.insert(0, diary);
    } else {
      myDiaries.insert(0, diary);
      if (diary.isPublic) {
        communityDiaries.insert(0, diary);
      }
    }
  }

  Future<void> _persistLocal() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _draftsKey,
      jsonEncode(
        drafts.map((DiaryModel e) => e.toJson()).toList(growable: false),
      ),
    );
    await prefs.setString(
      _myDiariesKey,
      jsonEncode(
        myDiaries.map((DiaryModel e) => e.toJson()).toList(growable: false),
      ),
    );
    await prefs.setString(
      _communityKey,
      jsonEncode(
        communityDiaries
            .map((DiaryModel e) => e.toJson())
            .toList(growable: false),
      ),
    );
  }

  List<DiaryModel> _seedDiaries() {
    return <DiaryModel>[
      DiaryModel(
        id: 'seed-kyoto-01',
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

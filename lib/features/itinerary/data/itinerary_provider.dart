import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum TripState { preparing, traveling }

// 双模式枚举：行程前（规划）vs 行程中（旅行）
enum TripMode {
  planning,  // 行程前 (规划模式)
  traveling  // 行程中 (旅行模式)
}

DateTime _toDayStart(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime? _parseDate(dynamic value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

double _toDouble(dynamic value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}

class ActivityItem {
  const ActivityItem({
    required this.id,
    required this.time,
    required this.title,
    required this.type,
    required this.lat,
    required this.lng,
    required this.imageUrl,
    required this.transportInfo,
    required this.recommendedDuration,
    required this.aiHighlight,
  });

  final String id;
  final String time;
  final String title;
  final String type;
  final double lat;
  final double lng;
  final String imageUrl;
  final String transportInfo;
  final String recommendedDuration;
  final String aiHighlight;

  factory ActivityItem.fromJson(
    Map<String, dynamic> json, {
    required String fallbackId,
  }) {
    final String normalizedType =
        (json['type'] as String?)?.trim().toLowerCase() ?? 'scenic';
    const List<String> allowed = <String>[
      'transport',
      'hotel',
      'scenic',
      'food',
    ];
    return ActivityItem(
      id: (json['id'] as String?)?.trim().isNotEmpty == true
          ? json['id'] as String
          : fallbackId,
      time: (json['time'] as String?)?.trim().isNotEmpty == true
          ? json['time'] as String
          : '--:--',
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : '未命名活动',
      type: allowed.contains(normalizedType) ? normalizedType : 'scenic',
      lat: _toDouble(json['lat'] ?? json['latitude']),
      lng: _toDouble(json['lng'] ?? json['lon'] ?? json['longitude']),
      imageUrl: (json['imageUrl'] ?? json['image_url'] ?? '').toString(),
      transportInfo:
          (json['transportInfo'] ?? json['transport_info'] ?? '步行约10分钟')
              .toString(),
      recommendedDuration:
          (json['recommended_duration'] ?? json['recommendedDuration'] ?? '1小时')
              .toString(),
      aiHighlight: (json['ai_highlight'] ?? json['aiHighlight'] ?? 'AI 推荐打卡点')
          .toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'time': time,
      'title': title,
      'type': type,
      'lat': lat,
      'lng': lng,
      'imageUrl': imageUrl,
      'transportInfo': transportInfo,
      'recommended_duration': recommendedDuration,
      'ai_highlight': aiHighlight,
    };
  }
}

class DayPlan {
  const DayPlan({required this.dayTitle, required this.activities});

  final String dayTitle;
  final List<ActivityItem> activities;

  factory DayPlan.fromJson(Map<String, dynamic> json, {required int dayIndex}) {
    final List<dynamic> rawActivities =
        (json['activities'] as List<dynamic>?) ?? <dynamic>[];
    int activityIndex = 0;
    return DayPlan(
      dayTitle: (json['dayTitle'] ?? json['day_title'] ?? 'Day ${dayIndex + 1}')
          .toString(),
      activities: rawActivities
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> item) {
            activityIndex++;
            return ActivityItem.fromJson(
              item,
              fallbackId: 'd${dayIndex + 1}_a$activityIndex',
            );
          })
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'dayTitle': dayTitle,
      'activities': activities
          .map((ActivityItem e) => e.toJson())
          .toList(growable: false),
    };
  }
}

class ItineraryModel {
  const ItineraryModel({
    required this.title,
    required this.startDate,
    required this.endDate,
    required this.planData,
    required this.days,
    required this.arrivedActivityIds,
    required this.arrivedAtByActivityId,
    required this.prepTaskDoneMap,
    this.version = 1,
    this.remoteId,
    this.createdAt,
  });

  final String title;
  final DateTime startDate;
  final DateTime endDate;
  final Map<String, dynamic> planData;
  final List<DayPlan> days;
  final Set<String> arrivedActivityIds;
  final Map<String, String> arrivedAtByActivityId;
  final Map<String, bool> prepTaskDoneMap;
  final int version;
  final String? remoteId;
  final DateTime? createdAt;

  /// 列表筛选与删除：优先云端行 id；否则本地占位（云端 delete 仅对 UUID 生效）。
  String get id {
    final String? r = remoteId?.trim();
    if (r != null && r.isNotEmpty) {
      return r;
    }
    return 'local_${startDate.millisecondsSinceEpoch}_${title.hashCode.abs()}';
  }

  /// 兼容 Discover 页等直接读取目的地字段。
  String get destinationCity {
    final dynamic fromPlan = planData['destination_city'] ??
        planData['destinationCity'] ??
        planData['destination'];
    final String v = fromPlan?.toString().trim() ?? '';
    if (v.isNotEmpty) {
      return v;
    }
    return '探索未知';
  }

  /// 兼容旧调用命名。
  String get destination => destinationCity;

  ItineraryModel copyWith({
    String? title,
    DateTime? startDate,
    DateTime? endDate,
    Map<String, dynamic>? planData,
    List<DayPlan>? days,
    Set<String>? arrivedActivityIds,
    Map<String, String>? arrivedAtByActivityId,
    Map<String, bool>? prepTaskDoneMap,
    int? version,
    String? remoteId,
    DateTime? createdAt,
  }) {
    return ItineraryModel(
      title: title ?? this.title,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      planData: planData ?? this.planData,
      days: days ?? this.days,
      arrivedActivityIds: arrivedActivityIds ?? this.arrivedActivityIds,
      arrivedAtByActivityId:
          arrivedAtByActivityId ?? this.arrivedAtByActivityId,
      prepTaskDoneMap: prepTaskDoneMap ?? this.prepTaskDoneMap,
      version: version ?? this.version,
      remoteId: remoteId ?? this.remoteId,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory ItineraryModel.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> normalizedPlanData =
        (json['planData'] as Map<String, dynamic>?) ??
        (json['plan_data'] as Map<String, dynamic>?) ??
        Map<String, dynamic>.from(json);
    final List<dynamic> rawDays =
        (normalizedPlanData['days'] as List<dynamic>?) ?? <dynamic>[];
    final DateTime now = DateTime.now();
    final DateTime start =
        _parseDate(json['startDate'] ?? json['start_date']) ?? _toDayStart(now);
    final DateTime end =
        _parseDate(json['endDate'] ?? json['end_date']) ??
        _toDayStart(
          start,
        ).add(Duration(days: rawDays.length <= 1 ? 0 : rawDays.length - 1));
    int dayIdx = 0;
    final List<DayPlan> parsedDays = rawDays
        .whereType<Map<String, dynamic>>()
        .map((Map<String, dynamic> day) {
          final int idx = dayIdx;
          dayIdx++;
          return DayPlan.fromJson(day, dayIndex: idx);
        })
        .toList(growable: false);

    return ItineraryModel(
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : (normalizedPlanData['title'] ?? 'AI 专属行程').toString(),
      startDate: _toDayStart(start),
      endDate: _toDayStart(end),
      planData: normalizedPlanData,
      days: parsedDays,
      remoteId: json['remoteId']?.toString() ?? json['id']?.toString(),
      createdAt: _parseDate(json['createdAt'] ?? json['created_at']),
      arrivedActivityIds:
          ((json['arrivedActivityIds'] as List<dynamic>?) ?? <dynamic>[])
              .map((dynamic e) => e.toString())
              .toSet(),
      arrivedAtByActivityId:
          ((json['arrivedAtByActivityId'] as Map<String, dynamic>?) ??
                  <String, dynamic>{})
              .map(
                (String key, dynamic value) =>
                    MapEntry<String, String>(key, value.toString()),
              ),
      prepTaskDoneMap:
          ((json['prepTaskDoneMap'] as Map<String, dynamic>?) ??
                  <String, dynamic>{})
              .map(
                (String key, dynamic value) =>
                    MapEntry<String, bool>(key, value == true),
              ),
      version: (json['version'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'remoteId': remoteId,
      'title': title,
      'destination_city': destinationCity,
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'planData': planData,
      'days': days.map((DayPlan e) => e.toJson()).toList(growable: false),
      'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
      'arrivedActivityIds': arrivedActivityIds.toList(growable: false),
      'arrivedAtByActivityId': arrivedAtByActivityId,
      'prepTaskDoneMap': prepTaskDoneMap,
      'version': version,
    };
  }
}

class ItineraryProvider extends ChangeNotifier {
  static const String _prefsKey = 'current_itinerary_json';
  static const String _tableName = 'user_itineraries';
  final SupabaseClient _supabase = Supabase.instance.client;
  RealtimeChannel? _itineraryChannel;
  RealtimeChannel? _presenceChannel;
  List<Map<String, dynamic>> _onlineUsers = <Map<String, dynamic>>[];
  String? _someoneElseEditingName;

  /// 行程 Realtime 推送到达时通知 UI（如编辑态 SnackBar）
  VoidCallback? _onRemoteUpdate;

  void setRemoteUpdateCallback(VoidCallback cb) {
    _onRemoteUpdate = cb;
  }

  void clearRemoteUpdateCallback() {
    _onRemoteUpdate = null;
  }

  ItineraryModel? _currentItinerary;
  ItineraryModel? _activeItinerary;
  final List<ItineraryModel> _myItineraries = <ItineraryModel>[];

  bool _isBusy = false;
  bool get isBusy => _isBusy;

  ItineraryModel? get currentItinerary => _currentItinerary;
  ItineraryModel? get activeItinerary => _activeItinerary;
  List<ItineraryModel> get myItineraries =>
      List<ItineraryModel>.unmodifiable(_myItineraries);
  List<Map<String, dynamic>> get onlineUsers =>
      List<Map<String, dynamic>>.unmodifiable(_onlineUsers);
  String? get someoneElseEditingName => _someoneElseEditingName;

  // 双模式状态管理
  TripMode _currentMode = TripMode.planning;
  TripMode get currentMode => _currentMode;

  void toggleTripMode(TripMode mode) {
    if (_currentMode != mode) {
      _currentMode = mode;
      HapticFeedback.lightImpact(); // 震动反馈
      notifyListeners();
    }
  }

  bool _isValidUuid(String id) {
    final RegExp uuidRegex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    return uuidRegex.hasMatch(id);
  }

  Future<void> _persistMyItinerariesList() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String fallbackUserId =
          Supabase.instance.client.auth.currentUser?.id ?? 'guest';
      final String freshJsonStr = jsonEncode(
        _myItineraries.map((ItineraryModel e) => e.toJson()).toList(),
      );
      await prefs.setString('my_itineraries_cache_$fallbackUserId', freshJsonStr);
    } catch (e) {
      debugPrint('本地缓存更新失败(my_itineraries): $e');
    }
  }

  Future<void> _syncMyItinerariesFromStorage() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String fallbackUserId =
          Supabase.instance.client.auth.currentUser?.id ?? 'guest';
      final String? raw = prefs.getString('my_itineraries_cache_$fallbackUserId');
      if (raw != null && raw.trim().isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is List<dynamic>) {
          _myItineraries
            ..clear()
            ..addAll(
              decoded
                  .whereType<Map<String, dynamic>>()
                  .map(
                    (Map<String, dynamic> e) =>
                        sanitizeItineraryImages(ItineraryModel.fromJson(e)),
                  ),
            );
          return;
        }
      }
    } catch (e) {
      debugPrint('my_itineraries 读取失败: $e');
    }
    _myItineraries
      ..clear()
      ..addAll(
        _currentItinerary == null
            ? <ItineraryModel>[]
            : <ItineraryModel>[
                sanitizeItineraryImages(_currentItinerary!),
              ],
      );
  }

  void _upsertMyItinerary(ItineraryModel model) {
    final String mid = model.id;
    final int idx = _myItineraries.indexWhere((ItineraryModel e) => e.id == mid);
    if (idx >= 0) {
      _myItineraries[idx] = model;
    } else {
      _myItineraries.add(model);
    }
  }

  /// 多行程列表中切换当前「激活」行程（行程 Tab 优先展示）。
  void setActiveItinerary(ItineraryModel itinerary) {
    _activeItinerary = itinerary;
    notifyListeners();
    subscribeToItinerary(itinerary.id);
    joinPresence(itinerary.id);
  }

  // --- 实时协作 (Realtime) 频道 ---

  // 🚨 开启指定行程的实时监听
  void subscribeToItinerary(String itineraryId) {
    unsubscribeItinerary(); // 如果已有监听先取消

    debugPrint('📡 准备连接 Realtime 频道: 行程 ID $itineraryId');

    _itineraryChannel =
        _supabase.channel('public:$_tableName:id=eq.$itineraryId');

    _itineraryChannel!
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: _tableName,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: itineraryId,
          ),
          callback: (PostgresChangePayload payload) {
            // 🚨 V2 语法：使用 payload.newRecord 获取更新后的完整数据
            final Map<String, dynamic> newData = payload.newRecord;
            if (newData.isEmpty ||
                _activeItinerary == null ||
                _activeItinerary!.id != itineraryId) {
              return;
            }
            final int incomingVersion =
                (newData['version'] as num?)?.toInt() ?? 0;
            if (incomingVersion <= _activeItinerary!.version) {
              return;
            }

            final ItineraryModel updatedItinerary = sanitizeItineraryImages(
              ItineraryModel.fromJson(newData),
            );
            _activeItinerary = updatedItinerary;

            final int index = _myItineraries.indexWhere(
              (ItineraryModel e) => e.id == itineraryId,
            );
            if (index != -1) {
              _myItineraries[index] = updatedItinerary;
            }

            _onRemoteUpdate?.call();
            notifyListeners();
            debugPrint('🔄 监听到好友修改了行程，UI 已实时同步完成！');
          },
        )
        .subscribe((RealtimeSubscribeStatus status, [Object? error]) {
          // V2 语法：状态变成了枚举 RealtimeSubscribeStatus
          if (status == RealtimeSubscribeStatus.subscribed) {
            debugPrint('✅ 成功订阅行程实时频道！');
          }
          if (error != null) {
            debugPrint('⚠️ Realtime 订阅异常: $error');
          }
        });
  }

  // 🚨 关闭实时监听 (节省性能)
  void unsubscribeItinerary() {
    if (_itineraryChannel != null) {
      _supabase.removeChannel(_itineraryChannel!);
      _itineraryChannel = null;
      debugPrint('🛑 已断开行程实时监听频道');
    }
  }

  // ==========================================
  // 👥 协同编辑：Presence 在线状态感知
  // ==========================================
  // 🚨 核心修复：使用 V2 的 onPresenceSync 语法，彻底移除废弃的 RealtimePresenceState 类型
  void joinPresence(String itineraryId) {
    final User? user = _supabase.auth.currentUser;
    if (user == null) return;

    final String myUserId = user.id;
    final String myNickname = '旅行者_${myUserId.substring(0, 4)}';
    final String myAvatarUrl =
        'https://api.dicebear.com/7.x/avataaars/png?seed=$myUserId';

    leavePresence();

    _presenceChannel = _supabase.channel('tracking_$itineraryId');
    _presenceChannel!
        .onPresenceSync((dynamic payload) {
          // 🚨 V2 语法核心修复：不再使用 RealtimePresenceState 类型声明
          final dynamic state = _presenceChannel!.presenceState();
          final List<Map<String, dynamic>> users = <Map<String, dynamic>>[];
          String? editingName;

          for (final dynamic entry in state.entries) {
            for (final dynamic presence in entry.value) {
              // 强力容错：兼容不同版本的 Supabase 载荷结构
              Map<String, dynamic> p;
              if (presence is Map) {
                p = Map<String, dynamic>.from(presence);
              } else {
                p = Map<String, dynamic>.from((presence as dynamic).payload);
              }
              users.add(p);
              if (p['user_id'] != myUserId && p['status'] == 'editing') {
                editingName = p['nickname']?.toString();
              }
            }
          }

          _onlineUsers = users;
          _someoneElseEditingName = editingName;
          notifyListeners();
        })
        .subscribe((RealtimeSubscribeStatus status, [Object? error]) async {
          if (status == RealtimeSubscribeStatus.subscribed) {
            await _presenceChannel!.track(<String, dynamic>{
              'user_id': myUserId,
              'nickname': myNickname,
              'avatar': myAvatarUrl,
              'status': 'viewing',
            });
          }
          if (error != null) {
            debugPrint('⚠️ Presence 订阅异常: $error');
          }
        });
  }

  // 修改自己的状态 (编辑 / 浏览)
  Future<void> updatePresenceStatus(String newStatus) async {
    if (_presenceChannel != null) {
      final User? user = _supabase.auth.currentUser;
      if (user == null) return;

      final String myUserId = user.id;
      final String myNickname = '旅行者_${myUserId.substring(0, 4)}';
      final String myAvatarUrl =
          'https://api.dicebear.com/7.x/avataaars/png?seed=$myUserId';

      await _presenceChannel!.track(<String, dynamic>{
        'user_id': myUserId,
        'nickname': myNickname,
        'avatar': myAvatarUrl,
        'status': newStatus,
      });
    }
  }

  void leavePresence() {
    if (_presenceChannel != null) {
      _supabase.removeChannel(_presenceChannel!);
      _presenceChannel = null;
      _onlineUsers.clear();
      _someoneElseEditingName = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unsubscribeItinerary();
    leavePresence();
    super.dispose();
  }

  /// 删除行程：本地列表 + 缓存；已登录且 id 为 UUID 时同步删除云端 [_tableName] 行。
  Future<void> deleteItinerary(String id) async {
    _myItineraries.removeWhere((ItineraryModel e) => e.id == id);
    if (_activeItinerary?.id == id) {
      _activeItinerary =
          _myItineraries.isNotEmpty ? _myItineraries.first : null;
    }
    if (_currentItinerary?.id == id) {
      _currentItinerary =
          _myItineraries.isNotEmpty ? _myItineraries.first : null;
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        if (_currentItinerary != null) {
          await prefs.setString(
            _prefsKey,
            jsonEncode(_currentItinerary!.toJson()),
          );
        } else {
          await prefs.remove(_prefsKey);
        }
      } catch (e) {
        debugPrint('current_itinerary 本地更新失败: $e');
      }
    }
    notifyListeners();

    await _persistMyItinerariesList();

    final String? userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null && _isValidUuid(id)) {
      try {
        await Supabase.instance.client.from(_tableName).delete().eq('id', id);
        debugPrint('✅ 行程已从云端彻底删除');
      } catch (e) {
        debugPrint('⚠️ 云端删除失败: $e');
      }
    }
  }

  TripState getTripState([DateTime? now]) {
    final ItineraryModel? model = _activeItinerary ?? _currentItinerary;
    if (model == null) return TripState.preparing;
    final DateTime today = _toDayStart(now ?? DateTime.now());
    if (today.isBefore(_toDayStart(model.startDate))) {
      return TripState.preparing;
    }
    if (today.isAfter(_toDayStart(model.endDate))) {
      return TripState.preparing;
    }
    return TripState.traveling;
  }

  Future<void> loadFromPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) {
        _currentItinerary = null;
        _activeItinerary = null;
        notifyListeners();
        return;
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _currentItinerary = sanitizeItineraryImages(ItineraryModel.fromJson(decoded));
        _activeItinerary = _currentItinerary;
      } else {
        _currentItinerary = null;
        _activeItinerary = null;
      }
    } catch (_) {
      _currentItinerary = null;
      _activeItinerary = null;
    }
    await _syncMyItinerariesFromStorage();
    notifyListeners();
  }

  // ========================================================
  // 🚀 核心 1：离线优先拉取 (包含多成员协作行程融合)
  // ========================================================
  Future<void> loadMyItineraries() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SupabaseClient supabase = Supabase.instance.client;
    final String userId = supabase.auth.currentUser?.id ?? 'guest';

    // 步骤 A：本地秒开逻辑 (保持原有不动)
    final String? localDataStr = prefs.getString('my_itineraries_cache_$userId');
    if (localDataStr != null) {
      try {
        final List<dynamic> localJson = jsonDecode(localDataStr) as List<dynamic>;
        _myItineraries
          ..clear()
          ..addAll(
            localJson
                .whereType<Map<String, dynamic>>()
                .map(
                  (Map<String, dynamic> data) =>
                      sanitizeItineraryImages(ItineraryModel.fromJson(data)),
                ),
          );
        if (_myItineraries.isNotEmpty) {
          _activeItinerary = _myItineraries.first;
        }
        notifyListeners();
        debugPrint('✅ 本地缓存行程加载成功，实现秒开！');
      } catch (e) {
        debugPrint('❌ 本地缓存解析失败: $e');
      }
    }

    // 步骤 B：如果是游客，到此结束。如果是正式用户，静默去云端对账。
    if (supabase.auth.currentUser == null) return;

    try {
      // 🚨 核心改造：并发拉取【自己创建的】和【别人邀请我加入的】行程
      final dynamic myFuture = supabase
          .from(_tableName)
          .select()
          .eq('user_id', userId);

      final dynamic sharedFuture = supabase
          .from('itinerary_members')
          .select('$_tableName(*)')
          .eq('user_id', userId);

      // 并发执行，节省等待时间
      final List<dynamic> results = await Future.wait(<Future<dynamic>>[
        myFuture as Future<dynamic>,
        sharedFuture as Future<dynamic>,
      ]);

      // 🚨 核心改造：合并与去重
      final Map<String, ItineraryModel> mergedMap = <String, ItineraryModel>{};

      // 处理我的行程
      for (final dynamic data in (results[0] as List<dynamic>)) {
        if (data is! Map<String, dynamic>) continue;
        final ItineraryModel itinerary = sanitizeItineraryImages(
          ItineraryModel.fromJson(data),
        );
        mergedMap[itinerary.id] = itinerary;
      }

      // 处理共享的行程
      for (final dynamic data in (results[1] as List<dynamic>)) {
        if (data is! Map<String, dynamic>) continue;
        final dynamic nested = data[_tableName];
        if (nested is! Map<String, dynamic>) continue;
        final ItineraryModel itinerary = sanitizeItineraryImages(
          ItineraryModel.fromJson(nested),
        );
        mergedMap[itinerary.id] = itinerary;
      }

      // 转为 List 并排序 (降序排列，由于 ID 是时间戳字符串，可以直接按 ID 降序对比)
      final List<ItineraryModel> cloudItineraries = mergedMap.values.toList();
      cloudItineraries.sort((ItineraryModel a, ItineraryModel b) => b.id.compareTo(a.id));

      // 步骤 C：比对并覆写。
      _myItineraries
        ..clear()
        ..addAll(cloudItineraries);
      if (_myItineraries.isNotEmpty) {
        _activeItinerary = _myItineraries.first;
      }

      // 刷新磁盘缓存
      final String freshJsonStr =
          jsonEncode(_myItineraries.map((ItineraryModel e) => e.toJson()).toList());
      await prefs.setString('my_itineraries_cache_$userId', freshJsonStr);

      notifyListeners();
      debugPrint('☁️ 云端行程数据(含协作)同步完成并写入本地缓存');
    } catch (e) {
      debugPrint('⚠️ 云端同步失败，继续使用本地缓存: $e');
    }
  }

  // ==========================================
  // 🤝 协同编辑：分享与加入逻辑
  // ==========================================

  // 1. 生成并分享邀请链接
  Future<void> shareItinerary(String itineraryId, String title) async {
    // 🚨 核心修改：将 gonow:// 替换为标准的 https 网址，这样微信等软件才会识别为超链接
    final String deepLink = 'https://gonow.app/join?id=$itineraryId';
    final String shareText =
        '💡 邀请你和我一起在 GoNow 编辑旅行行程！\n📍 行程：《$title》\n👉 点击链接马上加入：$deepLink';
    await Share.share(shareText);
  }

  // 生成口令并复制到剪贴板
  Future<void> copyItineraryCommand(String itineraryId, String title) async {
    final String commandText =
        '【GoNow 旅行管家】\n復制这段话，打开 GoNow 立即加入协作：\n📍 行程：《$title》\n🗝️ 专属口令：￥$itineraryId￥';
    await Clipboard.setData(ClipboardData(text: commandText));
    debugPrint('✅ 已生成口令并复制到剪贴板: $itineraryId');
  }

  // 解析剪贴板中的口令 (正则提取)
  String? parseCommand(String text) {
    final RegExp regExp = RegExp(r'￥([^￥]+)￥');
    final RegExpMatch? match = regExp.firstMatch(text);
    if (match != null && match.groupCount >= 1) {
      return match.group(1);
    }
    return null;
  }

  // 2. 拦截到链接后，执行加入逻辑
  Future<void> joinItinerary(String itineraryId, BuildContext context) async {
    final String? userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录后再加入协作行程！')),
      );
      return;
    }

    try {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在加入行程...')));

      await _supabase.from('itinerary_members').insert(<String, dynamic>{
        'itinerary_id': itineraryId,
        'user_id': userId,
        'role': 'editor',
      });

      await loadMyItineraries();

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('✅ 成功加入协作行程！')));
        if (_myItineraries.isNotEmpty) {
          final ItineraryModel joinedItinerary = _myItineraries.firstWhere(
            (ItineraryModel e) => e.id == itineraryId,
            orElse: () => _myItineraries.first,
          );
          _activeItinerary = joinedItinerary;
          notifyListeners();
        }
      }
    } catch (e) {
      if (e.toString().contains('duplicate key value')) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('您已经在这个行程中啦！')));
      } else {
        debugPrint('加入行程失败: $e');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('加入失败，请检查链接或网络')));
      }
    }
  }

  Future<void> fetchActiveItinerary() async {
    _isBusy = true;
    notifyListeners();
    try {
      final SupabaseClient client = Supabase.instance.client;
      final List<dynamic> rows = await client
          .from(_tableName)
          .select()
          .order('start_date', ascending: false)
          .limit(1);
      if (rows.isNotEmpty && rows.first is Map<String, dynamic>) {
        final Map<String, dynamic> map = rows.first as Map<String, dynamic>;
        final ItineraryModel model = sanitizeItineraryImages(
          ItineraryModel.fromJson(<String, dynamic>{
          'id': map['id'],
          'title': map['title'],
          'start_date': map['start_date'],
          'end_date': map['end_date'],
          'plan_data': map['plan_data'],
          'created_at': map['created_at'],
          }),
        );
        _currentItinerary = model;
        _activeItinerary = model;
        _upsertMyItinerary(model);
        await _saveToLocal(model);
        await _persistMyItinerariesList();
      } else {
        await loadFromPrefs();
      }
    } catch (_) {
      await loadFromPrefs();
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<void> saveToSupabase(ItineraryModel model) async {
    final SupabaseClient client = Supabase.instance.client;
    await client.from(_tableName).insert(<String, dynamic>{
      'title': model.title,
      'start_date': model.startDate.toIso8601String(),
      'end_date': model.endDate.toIso8601String(),
      'plan_data': model.planData,
      'created_at': DateTime.now().toIso8601String(),
      'version': 1,
    });
  }

  Future<void> _saveToLocal(ItineraryModel model) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(model.toJson()));
  }

  Future<void> saveItinerary(ItineraryModel model) async {
    _currentItinerary = model;
    _activeItinerary = model;
    _upsertMyItinerary(model);
    notifyListeners();
    try {
      await saveToSupabase(model);
      await _saveToLocal(model);
      await _persistMyItinerariesList();
    } catch (_) {
      try {
        await _saveToLocal(model);
        await _persistMyItinerariesList();
      } catch (_) {
        // keep memory state even when persistence fails
      }
    }
  }

  /// 将编辑中的 [planData] 写回当前行程并持久化（内存 / 本地 / 多行程缓存 / 云端）。
  ///
  /// 通过完整 `fromJson` 重建模型，确保 `days` 等与 `planData` 同步；再用 [saveItinerary]
  /// 触发 [notifyListeners]。
  ///
  /// 兼容旧调用：内部转发到乐观锁版本。
  Future<void> updateItineraryData(Map<String, dynamic> newPlanData) async {
    await updateItineraryDataWithLock(newPlanData);
  }

  /// 本地行程降级保存（无 UUID，无需云端锁）
  Future<bool> _saveLocalOnly(
    ItineraryModel base,
    Map<String, dynamic> newPlanData,
  ) async {
    final ItineraryModel updated = sanitizeItineraryImages(
      base.copyWith(planData: newPlanData, version: base.version + 1),
    );
    _activeItinerary = updated;
    _currentItinerary = updated;
    _upsertMyItinerary(updated);
    await _saveToLocal(updated);
    await _persistMyItinerariesList();
    notifyListeners();
    debugPrint('✅ 本地行程保存成功（无需云端锁）');
    return true;
  }

  Future<bool> updateItineraryDataWithLock(
    Map<String, dynamic> newPlanData,
  ) async {
    final ItineraryModel? base = _activeItinerary ?? _currentItinerary;
    if (base == null) {
      return false;
    }

    final String targetId = base.id;

    if (!_isValidUuid(targetId)) {
      return _saveLocalOnly(base, newPlanData);
    }

    final Map<String, dynamic> sanitizedPlanData =
        sanitizeItineraryImages(base.copyWith(planData: newPlanData)).planData;

    try {
      final Map<String, dynamic>? latestRow = await _supabase
          .from(_tableName)
          .select('version')
          .eq('id', targetId)
          .maybeSingle();

      if (latestRow == null) {
        debugPrint('⚠️ 云端找不到行程 $targetId，降级为本地保存');
        return _saveLocalOnly(base, newPlanData);
      }

      final int cloudVersion =
          (latestRow['version'] as num?)?.toInt() ?? 0;
      final int localVersion = base.version;

      debugPrint('🔒 乐观锁比对：本地=$localVersion，云端=$cloudVersion');

      if (cloudVersion > localVersion) {
        debugPrint('⚠️ 云端版本更新，执行自动追赶合并（cloudVersion=$cloudVersion）');

        final Map<String, dynamic>? latestFullRow = await _supabase
            .from(_tableName)
            .select()
            .eq('id', targetId)
            .maybeSingle();

        if (latestFullRow == null) {
          return _saveLocalOnly(base, newPlanData);
        }

        final ItineraryModel latestModel = sanitizeItineraryImages(
          ItineraryModel.fromJson(latestFullRow),
        );
        _activeItinerary = latestModel;
        _currentItinerary = latestModel;
        _upsertMyItinerary(latestModel);
        await _saveToLocal(latestModel);
        notifyListeners();

        final int retryVersion = cloudVersion + 1;
        final List<dynamic> retryResponse = await _supabase
            .from(_tableName)
            .update(<String, dynamic>{
              'plan_data': sanitizedPlanData,
              'version': retryVersion,
            })
            .eq('id', targetId)
            .eq('version', cloudVersion)
            .select();

        if (retryResponse.isEmpty) {
          debugPrint('⚠️ 追赶重试失败，数据已由 UI 更新至最新，建议用户再次手动保存');
          return false;
        }

        final ItineraryModel retried = sanitizeItineraryImages(
          latestModel.copyWith(
            planData: sanitizedPlanData,
            version: retryVersion,
          ),
        );
        _activeItinerary = retried;
        _currentItinerary = retried;
        _upsertMyItinerary(retried);
        await _saveToLocal(retried);
        await _persistMyItinerariesList();
        notifyListeners();
        debugPrint('✅ 追赶合并保存成功（version: $cloudVersion → $retryVersion）');
        return true;
      }

      final int nextVersion = cloudVersion + 1;
      final List<dynamic> response = await _supabase
          .from(_tableName)
          .update(<String, dynamic>{
            'plan_data': sanitizedPlanData,
            'version': nextVersion,
          })
          .eq('id', targetId)
          .eq('version', cloudVersion)
          .select();

      if (response.isEmpty) {
        debugPrint('❌ CAS 写入失败：另一成员在此期间修改了行程');
        return false;
      }

      final ItineraryModel updated = sanitizeItineraryImages(
        base.copyWith(planData: sanitizedPlanData, version: nextVersion),
      );
      _activeItinerary = updated;
      _currentItinerary = updated;
      _upsertMyItinerary(updated);
      await _saveToLocal(updated);
      await _persistMyItinerariesList();
      notifyListeners();

      debugPrint('✅ 保存成功（version: $cloudVersion → $nextVersion）');
      return true;
    } catch (e) {
      debugPrint('❌ 保存失败（异常）: $e');
      return false;
    }
  }

  /// 取消编辑时用快照强制覆盖云端，不做 CAS 比对。
  Future<void> rollbackItineraryData(
    Map<String, dynamic> snapshotPlanData,
    int snapshotVersion,
  ) async {
    final ItineraryModel? base = _activeItinerary ?? _currentItinerary;
    if (base == null) {
      return;
    }
    final String targetId = base.id;

    if (!_isValidUuid(targetId)) {
      final ItineraryModel restored = sanitizeItineraryImages(
        base.copyWith(
          planData: snapshotPlanData,
          version: snapshotVersion,
        ),
      );
      _activeItinerary = restored;
      _currentItinerary = restored;
      _upsertMyItinerary(restored);
      await _saveToLocal(restored);
      await _persistMyItinerariesList();
      notifyListeners();
      return;
    }

    final Map<String, dynamic> sanitizedSnapshot =
        sanitizeItineraryImages(
          base.copyWith(planData: snapshotPlanData),
        ).planData;

    try {
      await _supabase.from(_tableName).update(<String, dynamic>{
        'plan_data': sanitizedSnapshot,
        'version': snapshotVersion,
      }).eq('id', targetId);

      final ItineraryModel restored = sanitizeItineraryImages(
        base.copyWith(
          planData: sanitizedSnapshot,
          version: snapshotVersion,
        ),
      );
      _activeItinerary = restored;
      _currentItinerary = restored;
      _upsertMyItinerary(restored);
      await _saveToLocal(restored);
      await _persistMyItinerariesList();
      notifyListeners();
      debugPrint('↩️ 行程已回滚至编辑前快照（version=$snapshotVersion）');
    } catch (e) {
      debugPrint('⚠️ 回滚失败: $e');
    }
  }

  // 更新行程的基础信息（标题、地点、日期、标签、预算）
  Future<void> updateItineraryBasicInfo({
    required String id,
    required String newTitle,
    required String newDestination,
    required String newStartDate,
    required String newEndDate,
    required String newBudget,
    required String newActualCost,
    required List<String> newTags,
  }) async {
    final int index = _myItineraries.indexWhere((ItineraryModel e) => e.id == id);
    if (index == -1) return;

    // 1. 深拷贝并更新 planData
    final ItineraryModel oldItinerary = _myItineraries[index];
    final Map<String, dynamic> updatedPlanData = Map<String, dynamic>.from(
      oldItinerary.planData,
    );
    updatedPlanData['start_date'] = newStartDate;
    updatedPlanData['end_date'] = newEndDate;
    updatedPlanData['estimated_budget_per_person'] = newBudget;
    updatedPlanData['actual_cost'] = newActualCost;
    updatedPlanData['tags'] = newTags;
    updatedPlanData['destination_city'] = newDestination;
    updatedPlanData['destinationCity'] = newDestination;

    DateTime parsedStartDate = oldItinerary.startDate;
    if (newStartDate.trim().isNotEmpty) {
      parsedStartDate = DateTime.tryParse(newStartDate) ?? oldItinerary.startDate;
    }
    DateTime parsedEndDate = oldItinerary.endDate;
    if (newEndDate.trim().isNotEmpty) {
      parsedEndDate = DateTime.tryParse(newEndDate) ?? oldItinerary.endDate;
    } else {
      final Duration tripDuration = oldItinerary.endDate.difference(
        oldItinerary.startDate,
      );
      parsedEndDate = parsedStartDate.add(tripDuration);
    }

    // 2. 重组新的 Model
    final ItineraryModel updatedItinerary = sanitizeItineraryImages(
      oldItinerary.copyWith(
        title: newTitle,
        startDate: _toDayStart(parsedStartDate),
        endDate: _toDayStart(parsedEndDate),
        planData: updatedPlanData,
      ),
    );

    // 3. 乐观更新 UI
    _myItineraries[index] = updatedItinerary;
    if (_activeItinerary?.id == id) {
      _activeItinerary = updatedItinerary;
    }
    if (_currentItinerary?.id == id) {
      _currentItinerary = updatedItinerary;
    }
    notifyListeners();

    // 4. 持久化到本地和云端
    final String? userId = Supabase.instance.client.auth.currentUser?.id;
    final String fallbackUserId = userId ?? 'guest';

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String freshJsonStr = jsonEncode(
        _myItineraries.map((ItineraryModel e) => e.toJson()).toList(),
      );
      await prefs.setString('my_itineraries_cache_$fallbackUserId', freshJsonStr);
      if (_currentItinerary?.id == id) {
        await prefs.setString(_prefsKey, jsonEncode(updatedItinerary.toJson()));
      }
    } catch (e) {
      debugPrint('本地缓存更新失败: $e');
    }

    if (userId != null && _isValidUuid(id)) {
      try {
        await Supabase.instance.client.from(_tableName).update(<String, dynamic>{
          'title': newTitle,
          'start_date': newStartDate,
          'destination_city': newDestination,
          'plan_data': updatedPlanData,
        }).eq('id', id);
      } catch (e) {
        debugPrint('云端更新行程信息失败: $e');
      }
    }
  }

  ItineraryModel sanitizeItineraryImages(ItineraryModel model) {
    Map<String, dynamic> sanitizeActivityMap(Map<String, dynamic> activity) {
      final Map<String, dynamic> next = Map<String, dynamic>.from(activity);
      final List<dynamic> imagesRaw =
          (next['images'] as List<dynamic>?) ?? <dynamic>[];
      final List<dynamic> cleaned = imagesRaw
          .map((dynamic e) => e.toString().trim())
          .where((String e) => e.isNotEmpty)
          .toList(growable: true);
      if (cleaned.length > 1) {
        cleaned.removeAt(0);
      }
      next['images'] = cleaned;
      if (cleaned.isNotEmpty) {
        next['imageUrl'] = cleaned.first.toString();
        next['image_url'] = cleaned.first.toString();
      }
      return next;
    }

    final Map<String, dynamic> planData = Map<String, dynamic>.from(model.planData);
    bool changed = false;

    if (planData['days'] is List) {
      final List<dynamic> days = List<dynamic>.from(planData['days'] as List);
      for (int i = 0; i < days.length; i++) {
        final dynamic rawDay = days[i];
        if (rawDay is! Map) continue;
        final Map<String, dynamic> day = Map<String, dynamic>.from(rawDay);
        final List<dynamic> activities = List<dynamic>.from(
          (day['activities'] as List<dynamic>?) ?? <dynamic>[],
        );
        for (int j = 0; j < activities.length; j++) {
          final dynamic rawActivity = activities[j];
          if (rawActivity is! Map) continue;
          activities[j] = sanitizeActivityMap(
            Map<String, dynamic>.from(rawActivity),
          );
          changed = true;
        }
        day['activities'] = activities;
        days[i] = day;
      }
      planData['days'] = days;
    }

    if (planData['daily_schedules'] is List) {
      final List<dynamic> days = List<dynamic>.from(
        planData['daily_schedules'] as List,
      );
      for (int i = 0; i < days.length; i++) {
        final dynamic rawDay = days[i];
        if (rawDay is! Map) continue;
        final Map<String, dynamic> day = Map<String, dynamic>.from(rawDay);
        final List<dynamic> activities = List<dynamic>.from(
          (day['activities'] as List<dynamic>?) ?? <dynamic>[],
        );
        for (int j = 0; j < activities.length; j++) {
          final dynamic rawActivity = activities[j];
          if (rawActivity is! Map) continue;
          activities[j] = sanitizeActivityMap(
            Map<String, dynamic>.from(rawActivity),
          );
          changed = true;
        }
        day['activities'] = activities;
        days[i] = day;
      }
      planData['daily_schedules'] = days;
    }

    if (!changed) return model;
    final Map<String, dynamic> json = model.toJson();
    json['planData'] = planData;
    return ItineraryModel.fromJson(json);
  }

  Future<void> updateActivityImages({
    required String activityId,
    required List<String> images,
  }) async {
    final ItineraryModel? model = _activeItinerary ?? _currentItinerary;
    if (model == null) return;
    final List<String> cleaned = images
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList(growable: false);
    final Map<String, dynamic> planData = Map<String, dynamic>.from(model.planData);

    void updateDayActivities(String key) {
      final dynamic rawDays = planData[key];
      if (rawDays is! List) return;
      final List<dynamic> days = List<dynamic>.from(rawDays);
      for (int i = 0; i < days.length; i++) {
        final dynamic rawDay = days[i];
        if (rawDay is! Map) continue;
        final Map<String, dynamic> day = Map<String, dynamic>.from(rawDay);
        final List<dynamic> activities = List<dynamic>.from(
          (day['activities'] as List<dynamic>?) ?? <dynamic>[],
        );
        for (int j = 0; j < activities.length; j++) {
          final dynamic rawActivity = activities[j];
          if (rawActivity is! Map) continue;
          final Map<String, dynamic> activity = Map<String, dynamic>.from(
            rawActivity,
          );
          final String currentId = activity['id']?.toString() ?? '';
          if (currentId != activityId) continue;
          activity['images'] = cleaned;
          final String first = cleaned.isNotEmpty ? cleaned.first : '';
          activity['imageUrl'] = first;
          activity['image_url'] = first;
          activities[j] = activity;
        }
        day['activities'] = activities;
        days[i] = day;
      }
      planData[key] = days;
    }

    updateDayActivities('days');
    updateDayActivities('daily_schedules');

    final Map<String, dynamic> json = model.toJson();
    json['planData'] = planData;
    final ItineraryModel updated = ItineraryModel.fromJson(json);
    await saveItinerary(updated);
  }

  Future<bool> uploadAndSyncPhoto({
    required int dayIndex,
    required int activityIndex,
    required String filePath,
    required String itineraryId,
    required String activityTitle,
  }) async {
    try {
      final String? userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        debugPrint('用户未登录，无法上传');
        return false;
      }

      final String fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
      final String storagePath = 'itineraries/$userId/$fileName';
      await Supabase.instance.client.storage
          .from('itinerary_photos')
          .upload(storagePath, File(filePath));
      final String publicUrl = Supabase.instance.client.storage
          .from('itinerary_photos')
          .getPublicUrl(storagePath);

      final RegExp uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        caseSensitive: false,
      );
      if (uuidRegex.hasMatch(itineraryId)) {
        await Supabase.instance.client.from('activity_photos').insert(<String, dynamic>{
          'user_id': userId,
          'itinerary_id': itineraryId,
          'activity_title': activityTitle,
          'image_url': publicUrl,
          'storage_path': storagePath,
        });
      }

      // 🔧 红线 2：彻底重写图片追加逻辑，防止首图丢失
      final ItineraryModel? current = _activeItinerary ?? _currentItinerary;
      if (current == null) return false;

      // 1️⃣ 深拷贝整个 planData，防止污染原始引用
      final Map<String, dynamic> planData = Map<String, dynamic>.from(current.planData);
      final List<dynamic> targetDays = List<dynamic>.from(
        (planData['days'] as List<dynamic>?) ??
            (planData['daily_schedules'] as List<dynamic>?) ??
            <dynamic>[],
      );

      // 2️⃣ 边界检查：确保索引有效
      if (dayIndex < 0 ||
          dayIndex >= targetDays.length ||
          targetDays[dayIndex] is! Map<String, dynamic>) {
        debugPrint('❌ 索引越界：dayIndex=$dayIndex, 总天数=${targetDays.length}');
        return false;
      }

      final Map<String, dynamic> targetDay = Map<String, dynamic>.from(
        targetDays[dayIndex] as Map,
      );
      final List<dynamic> targetActivities = List<dynamic>.from(
        (targetDay['activities'] as List<dynamic>?) ?? <dynamic>[],
      );

      if (activityIndex < 0 ||
          activityIndex >= targetActivities.length ||
          targetActivities[activityIndex] is! Map<String, dynamic>) {
        debugPrint('❌ 索引越界：activityIndex=$activityIndex, 总活动=${targetActivities.length}');
        return false;
      }

      final Map<String, dynamic> targetActivity = Map<String, dynamic>.from(
        targetActivities[activityIndex] as Map,
      );

      // 3️⃣ 深拷贝现有 images 数组
      List<String> imagesToSave = <String>[];
      if (targetActivity['images'] != null && targetActivity['images'] is List) {
        imagesToSave = List<String>.from(
          (targetActivity['images'] as List<dynamic>).map(
            (dynamic e) => e.toString().trim(),
          ).where((String e) => e.isNotEmpty),
        );
      }

      // 4️⃣ 【关键】抢救首图：如果 images 为空，检查 imageUrl 并保留
      final String oldImageUrl =
          (targetActivity['imageUrl'] ?? targetActivity['image_url'] ?? '').toString().trim();
      if (imagesToSave.isEmpty && oldImageUrl.isNotEmpty) {
        debugPrint('✅ 抢救首图：$oldImageUrl');
        imagesToSave.add(oldImageUrl);
      } else if (imagesToSave.isNotEmpty && oldImageUrl.isNotEmpty && !imagesToSave.contains(oldImageUrl)) {
        // 如果 images 已有数据，但不包含 imageUrl，也要保留（插入到开头）
        debugPrint('✅ 补充首图到数组开头：$oldImageUrl');
        imagesToSave.insert(0, oldImageUrl);
      }

      // 5️⃣ 追加新上传的照片
      imagesToSave.add(publicUrl);
      debugPrint('✅ 追加新照片：$publicUrl，当前总数=${imagesToSave.length}');

      // 6️⃣ 反向同步：更新 images 数组和 imageUrl 封面
      targetActivity['images'] = List<dynamic>.from(imagesToSave);
      if (imagesToSave.isNotEmpty) {
        targetActivity['imageUrl'] = imagesToSave.first;
        targetActivity['image_url'] = imagesToSave.first;
      }

      // 7️⃣ 回写到数据结构
      targetActivities[activityIndex] = targetActivity;
      targetDay['activities'] = targetActivities;
      targetDays[dayIndex] = targetDay;

      if (planData['days'] is List) {
        planData['days'] = targetDays;
      }
      if (planData['daily_schedules'] is List) {
        planData['daily_schedules'] = targetDays;
      }

      // 8️⃣ 持久化并通知
      final ItineraryModel updated = current.copyWith(planData: planData);
      _activeItinerary = updated;
      _currentItinerary = updated;
      await saveItinerary(updated);
      notifyListeners();

      debugPrint('✅ 照片上传成功：Day${dayIndex + 1} Activity${activityIndex + 1}');
      return true;
    } catch (e) {
      debugPrint('❌ 上传照片失败: $e');
      return false;
    }
  }

  Future<bool> deleteAndSyncPhoto({
    required int dayIndex,
    required int activityIndex,
    required String targetUrl,
    required String itineraryId,
    required String activityTitle,
  }) async {
    try {
      final ItineraryModel? current = _activeItinerary ?? _currentItinerary;
      if (current == null) return false;

      // 1️⃣ 深拷贝整个 planData
      final Map<String, dynamic> planData = Map<String, dynamic>.from(current.planData);
      final List<dynamic> targetDays = List<dynamic>.from(
        (planData['days'] as List<dynamic>?) ??
            (planData['daily_schedules'] as List<dynamic>?) ??
            <dynamic>[],
      );

      // 2️⃣ 边界检查
      if (dayIndex < 0 ||
          dayIndex >= targetDays.length ||
          targetDays[dayIndex] is! Map<String, dynamic>) {
        debugPrint('❌ 删除失败：dayIndex=$dayIndex 越界');
        return false;
      }

      final Map<String, dynamic> targetDay = Map<String, dynamic>.from(
        targetDays[dayIndex] as Map,
      );
      final List<dynamic> targetActivities = List<dynamic>.from(
        (targetDay['activities'] as List<dynamic>?) ?? <dynamic>[],
      );

      if (activityIndex < 0 ||
          activityIndex >= targetActivities.length ||
          targetActivities[activityIndex] is! Map<String, dynamic>) {
        debugPrint('❌ 删除失败：activityIndex=$activityIndex 越界');
        return false;
      }

      final Map<String, dynamic> targetActivity = Map<String, dynamic>.from(
        targetActivities[activityIndex] as Map,
      );

      // 3️⃣ 深拷贝 images 数组并删除目标 URL
      List<String> currentImages = <String>[];
      if (targetActivity['images'] != null && targetActivity['images'] is List) {
        currentImages = List<String>.from(
          (targetActivity['images'] as List<dynamic>).map(
            (dynamic e) => e.toString().trim(),
          ).where((String e) => e.isNotEmpty),
        );
      }

      final int beforeCount = currentImages.length;
      currentImages.remove(targetUrl);
      final int afterCount = currentImages.length;
      debugPrint('✅ 删除照片：$targetUrl，删除前=$beforeCount，删除后=$afterCount');

      // 4️⃣ 更新 images 数组和首图
      targetActivity['images'] = List<dynamic>.from(currentImages);
      if (currentImages.isNotEmpty) {
        targetActivity['imageUrl'] = currentImages.first;
        targetActivity['image_url'] = currentImages.first;
      } else {
        targetActivity['imageUrl'] = '';
        targetActivity['image_url'] = '';
      }

      // 5️⃣ 回写数据结构
      targetActivities[activityIndex] = targetActivity;
      targetDay['activities'] = targetActivities;
      targetDays[dayIndex] = targetDay;

      if (planData['days'] is List) {
        planData['days'] = targetDays;
      }
      if (planData['daily_schedules'] is List) {
        planData['daily_schedules'] = targetDays;
      }

      // 6️⃣ 持久化并通知
      final ItineraryModel updated = current.copyWith(planData: planData);
      _activeItinerary = updated;
      _currentItinerary = updated;
      await saveItinerary(updated);
      notifyListeners();

      // 7️⃣ 删除 Supabase 记录
      if (_isValidUuid(itineraryId)) {
        try {
          await Supabase.instance.client
              .from('activity_photos')
              .delete()
              .eq('image_url', targetUrl);
          debugPrint('✅ Supabase 照片记录已删除');
        } catch (e) {
          debugPrint('⚠️ Supabase 删除异常: $e');
        }
      } else {
        debugPrint(
          '⚠️ itineraryId 无效 ($itineraryId)，跳过 Supabase 删除',
        );
      }

      return true;
    } catch (e) {
      debugPrint('❌ 删除照片失败: $e');
      return false;
    }
  }

  Future<void> markActivityArrived(String activityId) async {
    final ItineraryModel? model = _activeItinerary ?? _currentItinerary;
    if (model == null) return;
    final Set<String> ids = Set<String>.from(model.arrivedActivityIds);
    if (ids.contains(activityId)) return;
    ids.add(activityId);
    final Map<String, String> timeMap = Map<String, String>.from(
      model.arrivedAtByActivityId,
    );
    timeMap[activityId] = DateTime.now().toIso8601String();
    final ItineraryModel updated = model.copyWith(
      arrivedActivityIds: ids,
      arrivedAtByActivityId: timeMap,
    );
    _activeItinerary = updated;
    _currentItinerary = updated;
    notifyListeners();
    try {
      await _saveToLocal(updated);
    } catch (_) {}
  }

  Future<void> togglePrepTask(String taskKey, bool isDone) async {
    final ItineraryModel? model = _activeItinerary ?? _currentItinerary;
    if (model == null) return;
    final Map<String, bool> doneMap = Map<String, bool>.from(
      model.prepTaskDoneMap,
    );
    doneMap[taskKey] = isDone;
    final ItineraryModel updated = model.copyWith(prepTaskDoneMap: doneMap);
    _activeItinerary = updated;
    _currentItinerary = updated;
    notifyListeners();
    try {
      await _saveToLocal(updated);
    } catch (_) {}
  }

  Future<String?> addPrepCustomTask({
    required String moduleKey,
    required String title,
    String tips = '',
  }) async {
    final ItineraryModel? model = _activeItinerary ?? _currentItinerary;
    final String trimmedTitle = title.trim();
    if (model == null || trimmedTitle.isEmpty) return null;

    final Map<String, dynamic> planData = Map<String, dynamic>.from(
      model.planData,
    );
    final Map<String, dynamic> prep = Map<String, dynamic>.from(
      (planData['pre_trip_prep'] as Map<String, dynamic>?) ??
          <String, dynamic>{},
    );
    final List<dynamic> list = List<dynamic>.from(
      (prep[moduleKey] as List<dynamic>?) ?? <dynamic>[],
    );
    final String taskId =
        'custom_${moduleKey}_${DateTime.now().microsecondsSinceEpoch}';
    list.add(<String, dynamic>{
      'id': taskId,
      'item': trimmedTitle,
      'tips': tips,
      'custom': true,
    });
    prep[moduleKey] = list;
    planData['pre_trip_prep'] = prep;

    final ItineraryModel updated = model.copyWith(planData: planData);
    _activeItinerary = updated;
    _currentItinerary = updated;
    notifyListeners();
    try {
      await _saveToLocal(updated);
    } catch (_) {}
    return taskId;
  }

  Future<void> removePrepTask({
    required String moduleKey,
    required String taskKey,
    required String title,
  }) async {
    final ItineraryModel? model = _activeItinerary ?? _currentItinerary;
    if (model == null) return;

    final Map<String, dynamic> planData = Map<String, dynamic>.from(
      model.planData,
    );
    final Map<String, dynamic> prep = Map<String, dynamic>.from(
      (planData['pre_trip_prep'] as Map<String, dynamic>?) ??
          <String, dynamic>{},
    );
    final List<dynamic> list = List<dynamic>.from(
      (prep[moduleKey] as List<dynamic>?) ?? <dynamic>[],
    );
    list.removeWhere((dynamic item) {
      if (item is Map) {
        if (item['id']?.toString() == taskKey) return true;
        final String itemTitle = (item['item'] ?? item['title'] ?? '')
            .toString();
        return itemTitle.trim() == title.trim();
      }
      return item.toString().trim() == title.trim();
    });
    prep[moduleKey] = list;
    planData['pre_trip_prep'] = prep;

    final Map<String, bool> doneMap = Map<String, bool>.from(
      model.prepTaskDoneMap,
    );
    doneMap.remove(taskKey);

    final ItineraryModel updated = model.copyWith(
      planData: planData,
      prepTaskDoneMap: doneMap,
    );
    _activeItinerary = updated;
    _currentItinerary = updated;
    notifyListeners();
    try {
      await _saveToLocal(updated);
    } catch (_) {}
  }

  String? getNextPendingActivityId() {
    final ItineraryModel? model = _activeItinerary ?? _currentItinerary;
    if (model == null) return null;
    for (final DayPlan day in model.days) {
      for (final ActivityItem activity in day.activities) {
        if (!model.arrivedActivityIds.contains(activity.id)) {
          return activity.id;
        }
      }
    }
    return null;
  }
}

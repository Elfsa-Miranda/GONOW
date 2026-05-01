import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum TripState { preparing, traveling }

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
  final String? remoteId;
  final DateTime? createdAt;

  ItineraryModel copyWith({
    String? title,
    DateTime? startDate,
    DateTime? endDate,
    Map<String, dynamic>? planData,
    List<DayPlan>? days,
    Set<String>? arrivedActivityIds,
    Map<String, String>? arrivedAtByActivityId,
    Map<String, bool>? prepTaskDoneMap,
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
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'remoteId': remoteId,
      'title': title,
      'startDate': startDate.toIso8601String(),
      'endDate': endDate.toIso8601String(),
      'planData': planData,
      'days': days.map((DayPlan e) => e.toJson()).toList(growable: false),
      'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
      'arrivedActivityIds': arrivedActivityIds.toList(growable: false),
      'arrivedAtByActivityId': arrivedAtByActivityId,
      'prepTaskDoneMap': prepTaskDoneMap,
    };
  }
}

class ItineraryProvider extends ChangeNotifier {
  static const String _prefsKey = 'current_itinerary_json';
  static const String _tableName = 'itineraries';

  ItineraryModel? _currentItinerary;
  ItineraryModel? _activeItinerary;

  bool _isBusy = false;
  bool get isBusy => _isBusy;

  ItineraryModel? get currentItinerary => _currentItinerary;
  ItineraryModel? get activeItinerary => _activeItinerary;

  bool _isValidUuid(String id) {
    final RegExp uuidRegex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    return uuidRegex.hasMatch(id);
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
    notifyListeners();
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
        await _saveToLocal(model);
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
    });
  }

  Future<void> _saveToLocal(ItineraryModel model) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(model.toJson()));
  }

  Future<void> saveItinerary(ItineraryModel model) async {
    _currentItinerary = model;
    _activeItinerary = model;
    notifyListeners();
    try {
      await saveToSupabase(model);
      await _saveToLocal(model);
    } catch (_) {
      try {
        await _saveToLocal(model);
      } catch (_) {
        // keep memory state even when persistence fails
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

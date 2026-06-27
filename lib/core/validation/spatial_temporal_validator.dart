import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:gonow/core/services/amap_service.dart';

enum ValidIssueType {
  timeConflict,
  closedAtVisit,
  insufficientTransit,
  dayOverloaded,
}

enum IssueSeverity { error, warning }

class ValidationIssue {
  const ValidationIssue({
    required this.type,
    required this.message,
    required this.severity,
    this.dayIndex = 0,
    this.activityIndex = 0,
    this.suggestedFix,
  });

  final ValidIssueType type;
  final String message;
  final IssueSeverity severity;
  final int dayIndex;
  final int activityIndex;
  final String? suggestedFix;
}

class ValidationReport {
  const ValidationReport({required this.score, required this.issues});

  final int score;
  final List<ValidationIssue> issues;

  bool get isValid => score >= 60 && errors.isEmpty;

  List<ValidationIssue> get errors => issues
      .where((ValidationIssue issue) => issue.severity == IssueSeverity.error)
      .toList(growable: false);

  List<ValidationIssue> get warnings => issues
      .where((ValidationIssue issue) => issue.severity == IssueSeverity.warning)
      .toList(growable: false);
}

typedef RouteMinutesEstimator =
    Future<int?> Function({
      required String originLngLat,
      required String destLngLat,
      String mode,
    });

class SpatialTemporalValidator {
  static Future<ValidationReport> validate(
    Map<String, dynamic> itineraryJson, {
    RouteMinutesEstimator? estimateRouteMinutes,
  }) async {
    try {
      final RouteMinutesEstimator routeEstimator =
          estimateRouteMinutes ?? AmapService.estimateRouteMinutes;
      final List<ValidationIssue> issues = <ValidationIssue>[];
      final List<dynamic> days =
          itineraryJson['days'] as List<dynamic>? ?? <dynamic>[];

      for (int dayIndex = 0; dayIndex < days.length; dayIndex++) {
        final Object? rawDay = days[dayIndex];
        if (rawDay is! Map) continue;
        final List<dynamic> rawActivities =
            rawDay['activities'] as List<dynamic>? ?? <dynamic>[];
        final List<Map<dynamic, dynamic>> activities = rawActivities
            .whereType<Map>()
            .toList(growable: false);

        DateTime? prevEnd;
        int dayTotalMinutes = 0;

        for (
          int activityIndex = 0;
          activityIndex < activities.length;
          activityIndex++
        ) {
          final Map<dynamic, dynamic> act = activities[activityIndex];
          final DateTime? currStart = _parseTime(act['time']?.toString());
          final int durationMinutes = _parseDurationMinutes(
            _firstNonEmptyString(
              act['recommended_duration'],
              act['recommendedDuration'],
            ),
          );

          if (currStart != null && prevEnd != null) {
            if (currStart.isBefore(prevEnd)) {
              issues.add(
                ValidationIssue(
                  type: ValidIssueType.timeConflict,
                  message:
                      '第 ${dayIndex + 1} 天「${_activityTitle(act)}」时间早于上一活动结束时间',
                  severity: IssueSeverity.error,
                  dayIndex: dayIndex,
                  activityIndex: activityIndex,
                  suggestedFix: '建议推迟到 ${_formatTime(prevEnd)} 之后',
                ),
              );
            }
          }

          final String? openTime = _firstNonEmptyString(
            act['openTime'],
            act['opentime'],
          );
          if (openTime != null &&
              currStart != null &&
              !_isWithinOpenHours(currStart, openTime)) {
            issues.add(
              ValidationIssue(
                type: ValidIssueType.closedAtVisit,
                message:
                    '「${_activityTitle(act)}」营业时间为 $openTime，计划到访时间为 ${act['time']}',
                severity: IssueSeverity.warning,
                dayIndex: dayIndex,
                activityIndex: activityIndex,
              ),
            );
          }

          if (activityIndex > 0 && currStart != null && prevEnd != null) {
            final Map<dynamic, dynamic> prev = activities[activityIndex - 1];
            final double prevLat = _toDouble(prev['lat'] ?? prev['latitude']);
            final double prevLng = _toDouble(prev['lng'] ?? prev['longitude']);
            final double currLat = _toDouble(act['lat'] ?? act['latitude']);
            final double currLng = _toDouble(act['lng'] ?? act['longitude']);

            if (prevLat != 0 && prevLng != 0 && currLat != 0 && currLng != 0) {
              final int? commuteMinutes = await _estimateCommuteMinutes(
                prevLat: prevLat,
                prevLng: prevLng,
                currLat: currLat,
                currLng: currLng,
                routeEstimator: routeEstimator,
              );

              if (commuteMinutes != null) {
                final int gapMinutes = currStart.difference(prevEnd).inMinutes;
                if (commuteMinutes > gapMinutes + 5) {
                  issues.add(
                    ValidationIssue(
                      type: ValidIssueType.insufficientTransit,
                      message:
                          '从「${_activityTitle(prev)}」到「${_activityTitle(act)}」预计需要 $commuteMinutes 分钟，当前仅预留 $gapMinutes 分钟',
                      severity: IssueSeverity.error,
                      dayIndex: dayIndex,
                      activityIndex: activityIndex,
                      suggestedFix: '建议至少多预留 ${commuteMinutes - gapMinutes} 分钟',
                    ),
                  );
                }
                dayTotalMinutes += commuteMinutes;
              }
            }
          }

          dayTotalMinutes += durationMinutes;
          if (currStart != null) {
            prevEnd = currStart.add(Duration(minutes: durationMinutes));
          }
        }

        if (dayTotalMinutes > 14 * 60) {
          issues.add(
            ValidationIssue(
              type: ValidIssueType.dayOverloaded,
              message:
                  '第 ${dayIndex + 1} 天行程约 ${(dayTotalMinutes / 60).toStringAsFixed(1)} 小时，建议精简安排',
              severity: IssueSeverity.warning,
              dayIndex: dayIndex,
            ),
          );
        }
      }

      final int errorCount = issues
          .where(
            (ValidationIssue issue) => issue.severity == IssueSeverity.error,
          )
          .length;
      final int warningCount = issues
          .where(
            (ValidationIssue issue) => issue.severity == IssueSeverity.warning,
          )
          .length;
      final int score = (100 - errorCount * 20 - warningCount * 8)
          .clamp(0, 100)
          .toInt();
      return ValidationReport(score: score, issues: issues);
    } catch (e) {
      debugPrint('SpatialTemporalValidator validate 失败: $e');
      return const ValidationReport(score: 100, issues: <ValidationIssue>[]);
    }
  }

  static Future<int?> _estimateCommuteMinutes({
    required double prevLat,
    required double prevLng,
    required double currLat,
    required double currLng,
    required RouteMinutesEstimator routeEstimator,
  }) async {
    try {
      final double distanceKm = _haversineKm(
        prevLat,
        prevLng,
        currLat,
        currLng,
      );
      if (distanceKm < 0.5) return 10;
      return await routeEstimator(
        originLngLat: '$prevLng,$prevLat',
        destLngLat: '$currLng,$currLat',
      );
    } catch (e) {
      debugPrint('SpatialTemporalValidator route estimate 失败: $e');
      return null;
    }
  }

  static DateTime? _parseTime(String? raw) {
    try {
      if (raw == null || raw.trim().isEmpty || raw.trim() == '--:--') {
        return null;
      }
      final RegExpMatch? match = RegExp(
        r'^(\d{1,2}):(\d{2})$',
      ).firstMatch(raw.trim());
      if (match == null) return null;
      final int? hour = int.tryParse(match.group(1)!);
      final int? minute = int.tryParse(match.group(2)!);
      if (hour == null || minute == null) return null;
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
      final DateTime now = DateTime.now();
      return DateTime(now.year, now.month, now.day, hour, minute);
    } catch (e) {
      debugPrint('SpatialTemporalValidator _parseTime 失败: $e');
      return null;
    }
  }

  static String _formatTime(DateTime value) {
    try {
      final String hour = value.hour.toString().padLeft(2, '0');
      final String minute = value.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (e) {
      debugPrint('SpatialTemporalValidator _formatTime 失败: $e');
      return '';
    }
  }

  static bool _isWithinOpenHours(DateTime visitTime, String openTime) {
    try {
      final RegExpMatch? match = RegExp(
        r'(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})',
      ).firstMatch(openTime);
      if (match == null) return true;
      final DateTime? open = _parseTime(match.group(1));
      final DateTime? close = _parseTime(match.group(2));
      if (open == null || close == null) return true;
      return !visitTime.isBefore(open) && !visitTime.isAfter(close);
    } catch (e) {
      debugPrint('SpatialTemporalValidator _isWithinOpenHours 失败: $e');
      return true;
    }
  }

  static int _parseDurationMinutes(String? raw) {
    try {
      if (raw == null || raw.trim().isEmpty) return 60;
      final String text = raw.trim().toLowerCase();
      final RegExpMatch? match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(text);
      if (match == null) return 60;
      final double value = double.tryParse(match.group(1)!) ?? 1;
      if (text.contains('小时') ||
          text.contains('hour') ||
          text.contains('hr') ||
          text.contains('h')) {
        return (value * 60).round();
      }
      if (text.contains('分钟') ||
          text.contains('分') ||
          text.contains('minute') ||
          text.contains('min')) {
        return value.round();
      }
      return value <= 12 ? (value * 60).round() : value.round();
    } catch (e) {
      debugPrint('SpatialTemporalValidator _parseDurationMinutes 失败: $e');
      return 60;
    }
  }

  static double _haversineKm(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    try {
      const double radiusKm = 6371.0;
      final double dLat = (lat2 - lat1) * pi / 180;
      final double dLng = (lng2 - lng1) * pi / 180;
      final double a =
          sin(dLat / 2) * sin(dLat / 2) +
          cos(lat1 * pi / 180) *
              cos(lat2 * pi / 180) *
              sin(dLng / 2) *
              sin(dLng / 2);
      return radiusKm * 2 * atan2(sqrt(a), sqrt(1 - a));
    } catch (e) {
      debugPrint('SpatialTemporalValidator _haversineKm 失败: $e');
      return 0;
    }
  }

  static double _toDouble(dynamic value) {
    try {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0.0;
      return 0.0;
    } catch (e) {
      debugPrint('SpatialTemporalValidator _toDouble 失败: $e');
      return 0.0;
    }
  }

  static String _activityTitle(Map<dynamic, dynamic> activity) {
    try {
      return _firstNonEmptyString(activity['title'], activity['name']) ?? '活动';
    } catch (e) {
      debugPrint('SpatialTemporalValidator _activityTitle 失败: $e');
      return '活动';
    }
  }

  static String? _firstNonEmptyString(Object? first, [Object? second]) {
    try {
      final String? firstString = first?.toString().trim();
      if (firstString != null && firstString.isNotEmpty) return firstString;
      final String? secondString = second?.toString().trim();
      if (secondString != null && secondString.isNotEmpty) return secondString;
      return null;
    } catch (e) {
      debugPrint('SpatialTemporalValidator _firstNonEmptyString 失败: $e');
      return null;
    }
  }
}

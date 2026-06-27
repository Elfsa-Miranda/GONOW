import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/validation/spatial_temporal_validator.dart';

Future<int?> _fixedRouteMinutes({
  required String originLngLat,
  required String destLngLat,
  String mode = 'driving',
}) async {
  return 35;
}

Future<int?> _unavailableRouteMinutes({
  required String originLngLat,
  required String destLngLat,
  String mode = 'driving',
}) async {
  return null;
}

void main() {
  group('SpatialTemporalValidator', () {
    test('reports time conflicts from parsed duration windows', () async {
      final ValidationReport report = await SpatialTemporalValidator.validate(
        <String, dynamic>{
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'activities': <Map<String, dynamic>>[
                <String, dynamic>{
                  'time': '10:00',
                  'title': 'Museum',
                  'recommended_duration': '2.5小时',
                },
                <String, dynamic>{
                  'time': '11:00',
                  'title': 'Lunch',
                  'recommended_duration': '90分钟',
                },
              ],
            },
          ],
        },
      );

      expect(report.score, 80);
      expect(report.isValid, isFalse);
      expect(
        report.issues.map((ValidationIssue issue) => issue.type),
        contains(ValidIssueType.timeConflict),
      );
    });

    test('reports closed visits and insufficient transit gaps', () async {
      final ValidationReport report = await SpatialTemporalValidator.validate(
        <String, dynamic>{
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'activities': <Map<String, dynamic>>[
                <String, dynamic>{
                  'time': '08:00',
                  'title': 'Museum',
                  'openTime': '09:00-18:00',
                  'recommended_duration': '1小时',
                  'lat': 39.9000,
                  'lng': 116.3900,
                },
                <String, dynamic>{
                  'time': '09:00',
                  'title': 'Nearby Park',
                  'openTime': '全天开放',
                  'recommended_duration': '1小时',
                  'lat': 39.9001,
                  'lng': 116.3901,
                },
              ],
            },
          ],
        },
        estimateRouteMinutes: _fixedRouteMinutes,
      );

      expect(report.score, 72);
      expect(report.isValid, isFalse);
      expect(
        report.issues.map((ValidationIssue issue) => issue.type),
        containsAll(<ValidIssueType>[
          ValidIssueType.closedAtVisit,
          ValidIssueType.insufficientTransit,
        ]),
      );
    });

    test('uses route estimate for distant adjacent visits', () async {
      final ValidationReport report = await SpatialTemporalValidator.validate(
        <String, dynamic>{
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'activities': <Map<String, dynamic>>[
                <String, dynamic>{
                  'time': '09:00',
                  'title': 'Stop A',
                  'recommended_duration': '1h',
                  'lat': 39.9000,
                  'lng': 116.3900,
                },
                <String, dynamic>{
                  'time': '10:10',
                  'title': 'Stop B',
                  'recommended_duration': '1h',
                  'lat': 39.9200,
                  'lng': 116.4200,
                },
              ],
            },
          ],
        },
        estimateRouteMinutes: _fixedRouteMinutes,
      );

      expect(
        report.issues.map((ValidationIssue issue) => issue.type),
        contains(ValidIssueType.insufficientTransit),
      );
      expect(report.errors, hasLength(1));
    });

    test('skips transit check when route estimate is unavailable', () async {
      final ValidationReport report = await SpatialTemporalValidator.validate(
        <String, dynamic>{
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'activities': <Map<String, dynamic>>[
                <String, dynamic>{
                  'time': '09:00',
                  'title': 'Stop A',
                  'recommended_duration': '1h',
                  'lat': 39.9000,
                  'lng': 116.3900,
                },
                <String, dynamic>{
                  'time': '10:10',
                  'title': 'Stop B',
                  'recommended_duration': '1h',
                  'lat': 39.9200,
                  'lng': 116.4200,
                },
              ],
            },
          ],
        },
        estimateRouteMinutes: _unavailableRouteMinutes,
      );

      expect(report.issues, isEmpty);
      expect(report.score, 100);
    });

    test('warns when a day is overloaded', () async {
      final ValidationReport report = await SpatialTemporalValidator.validate(
        <String, dynamic>{
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'activities': List<Map<String, dynamic>>.generate(
                15,
                (int index) => <String, dynamic>{
                  'title': 'Stop $index',
                  'recommended_duration': '1小时',
                },
              ),
            },
          ],
        },
      );

      expect(report.score, 92);
      expect(report.warnings, hasLength(1));
      expect(report.warnings.single.type, ValidIssueType.dayOverloaded);
    });

    test('accepts compact valid itinerary', () async {
      final ValidationReport report = await SpatialTemporalValidator.validate(
        <String, dynamic>{
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'activities': <Map<String, dynamic>>[
                <String, dynamic>{
                  'time': '09:00',
                  'title': 'Stop A',
                  'openTime': '08:00-18:00',
                  'recommended_duration': '1小时',
                  'lat': 39.9000,
                  'lng': 116.3900,
                },
                <String, dynamic>{
                  'time': '10:30',
                  'title': 'Stop B',
                  'openTime': '08:00-18:00',
                  'recommended_duration': '1小时',
                  'lat': 39.9001,
                  'lng': 116.3901,
                },
              ],
            },
          ],
        },
      );

      expect(report.score, 100);
      expect(report.isValid, isTrue);
      expect(report.issues, isEmpty);
    });

    test('degrades safely for unparseable times and empty days', () async {
      final ValidationReport report = await SpatialTemporalValidator.validate(
        <String, dynamic>{
          'title': 'test',
          'days': <Map<String, dynamic>>[
            <String, dynamic>{
              'activities': <Map<String, dynamic>>[
                <String, dynamic>{
                  'time': '--:--',
                  'title': 'Flexible stop',
                  'openTime': 'not-a-range',
                },
              ],
            },
          ],
        },
      );

      expect(report.score, 100);
      expect(report.issues, isEmpty);
    });
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/services/safe_logger.dart';

void main() {
  test('free-form fields and unsafe identifiers never reach the sink', () {
    const String canary = 'traveler@example.invalid bearer-secret itinerary';
    final List<String> output = <String>[];
    final SafeLogger logger = SafeLogger(sink: output.add);

    logger.event(
      canary,
      fields: <String, Object?>{
        'message': canary,
        'source': canary,
        'count': 2,
      },
    );

    expect(output, hasLength(1));
    expect(output.single, isNot(contains(canary)));
    expect(jsonDecode(output.single), <String, Object>{
      'event': 'invalid_event',
      'level': 'info',
      'source': 'redacted',
      'count': 2,
    });
  });

  test('errors retain event location and type without error text', () {
    const String canary = 'token=secret user@example.invalid';
    final List<String> output = <String>[];
    final SafeLogger logger = SafeLogger(sink: output.add);

    logger.error(
      'itinerary.cache_failed',
      StateError(canary),
      fields: const <String, Object?>{'source': 'itinerary'},
    );

    expect(output.single, isNot(contains(canary)));
    expect(jsonDecode(output.single), <String, Object>{
      'event': 'itinerary.cache_failed',
      'level': 'error',
      'source': 'itinerary',
      'error_type': 'StateError',
    });
  });

  test('numeric diagnostic fields remain available', () {
    final String record = SafeLogger.format(
      'diary.fetch_failed',
      level: 'warning',
      fields: const <String, Object?>{
        'source': 'diary',
        'status_code': 503,
        'day_index': 1,
      },
    );

    expect(jsonDecode(record), <String, Object>{
      'event': 'diary.fetch_failed',
      'level': 'warning',
      'source': 'diary',
      'status_code': 503,
      'day_index': 1,
    });
  });
}

import 'dart:convert';

import 'package:flutter/foundation.dart';

typedef SafeLogSink = void Function(String message);

/// Structured logger that refuses free-form values.
///
/// Event names and string fields must be low-cardinality identifiers. Unknown
/// fields and unsafe strings are replaced before the sink is called. Callers
/// must never use this class to record prompts, responses, tokens, URLs, user
/// content, resource identifiers, or stack traces.
class SafeLogger {
  static final SafeLogger instance = SafeLogger();

  static const Set<String> _allowedFields = <String>{
    'activity_index',
    'before_count',
    'count',
    'day_index',
    'error_type',
    'is_local',
    'operation',
    'outcome',
    'source',
    'state',
    'status_code',
    'version',
  };
  static final RegExp _identifier = RegExp(r'^[a-zA-Z0-9_.:-]{1,80}$');

  final SafeLogSink _sink;

  SafeLogger({SafeLogSink? sink})
    : _sink = sink ?? ((String message) => debugPrint(message));

  void event(
    String event, {
    String level = 'info',
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    _sink(format(event, level: level, fields: fields));
  }

  void error(
    String event,
    Object error, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    this.event(
      event,
      level: 'error',
      fields: <String, Object?>{
        ...fields,
        'error_type': error.runtimeType.toString(),
      },
    );
  }

  @visibleForTesting
  static String format(
    String event, {
    String level = 'info',
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    final Map<String, Object> record = <String, Object>{
      'event': _safeIdentifier(event, fallback: 'invalid_event'),
      'level': _safeIdentifier(level, fallback: 'info'),
    };
    for (final MapEntry<String, Object?> entry in fields.entries) {
      if (!_allowedFields.contains(entry.key)) {
        continue;
      }
      final Object? value = entry.value;
      if (value is bool || value is int || value is double) {
        record[entry.key] = value!;
      } else if (value is String) {
        record[entry.key] = _safeIdentifier(value, fallback: 'redacted');
      }
    }
    return jsonEncode(record);
  }

  static String _safeIdentifier(String value, {required String fallback}) {
    return _identifier.hasMatch(value) ? value : fallback;
  }
}

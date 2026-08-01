import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ActiveRunKeyValueBackend {
  String? getString(String key);

  Future<bool> setString(String key, String value);

  Future<bool> remove(String key);
}

final class SharedPreferencesActiveRunBackend
    implements ActiveRunKeyValueBackend {
  const SharedPreferencesActiveRunBackend(this._preferences);

  final SharedPreferences _preferences;

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<bool> setString(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<bool> remove(String key) => _preferences.remove(key);
}

final class ActiveRunReference {
  const ActiveRunReference({
    required this.runId,
    required this.lastEventId,
    required this.version,
  });

  final String runId;
  final int lastEventId;
  final int version;
}

final class ActiveRunStoreException implements Exception {
  const ActiveRunStoreException(this.code);

  final String code;

  @override
  String toString() => 'ActiveRunStoreException($code)';
}

final class ActiveRunStore {
  ActiveRunStore({
    required ActiveRunKeyValueBackend backend,
    required String accountScopeSha256,
  }) : _backend = backend,
       _storageKey = _keyFor(accountScopeSha256);

  static const int _schemaVersion = 1;
  static const int _maximumPayloadBytes = 512;
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  final ActiveRunKeyValueBackend _backend;
  final String _storageKey;
  Future<void> _operationTail = Future<void>.value();

  Future<ActiveRunReference?> read() =>
      _serialized<ActiveRunReference?>(_readUnlocked);

  Future<void> save(ActiveRunReference reference) =>
      _serialized<void>(() async {
        _validate(reference);
        final String payload = jsonEncode(<String, Object>{
          'schema_version': _schemaVersion,
          'run_id': reference.runId,
          'last_event_id': reference.lastEventId,
          'version': reference.version,
        });
        if (utf8.encode(payload).length > _maximumPayloadBytes) {
          throw const ActiveRunStoreException('payload_too_large');
        }
        if (!await _backend.setString(_storageKey, payload)) {
          throw const ActiveRunStoreException('storage_write_failed');
        }
      });

  Future<bool> clearTerminal({required String runId}) =>
      _serialized<bool>(() async {
        if (!_uuidPattern.hasMatch(runId)) {
          throw const ActiveRunStoreException('invalid_run_id');
        }
        final ActiveRunReference? current = await _readUnlocked();
        if (current == null || current.runId != runId) {
          return false;
        }
        if (!await _backend.remove(_storageKey)) {
          throw const ActiveRunStoreException('storage_remove_failed');
        }
        return true;
      });

  Future<ActiveRunReference?> _readUnlocked() async {
    final String? payload = _backend.getString(_storageKey);
    if (payload == null) {
      return null;
    }
    if (utf8.encode(payload).length > _maximumPayloadBytes) {
      await _discardInvalid();
      return null;
    }
    try {
      final Object? decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw const FormatException('active run payload is not an object');
      }
      final Map<String, dynamic> json = Map<String, dynamic>.from(decoded);
      const Set<String> allowed = <String>{
        'schema_version',
        'run_id',
        'last_event_id',
        'version',
      };
      if (json.length != allowed.length ||
          json.keys.any((String key) => !allowed.contains(key)) ||
          json['schema_version'] != _schemaVersion ||
          json['run_id'] is! String ||
          json['last_event_id'] is! int ||
          json['version'] is! int) {
        throw const FormatException('active run payload has an invalid schema');
      }
      final ActiveRunReference reference = ActiveRunReference(
        runId: json['run_id'] as String,
        lastEventId: json['last_event_id'] as int,
        version: json['version'] as int,
      );
      _validate(reference);
      return reference;
    } on FormatException {
      await _discardInvalid();
      return null;
    } on ActiveRunStoreException {
      await _discardInvalid();
      return null;
    }
  }

  Future<void> _discardInvalid() async {
    if (!await _backend.remove(_storageKey)) {
      throw const ActiveRunStoreException('storage_remove_failed');
    }
  }

  void _validate(ActiveRunReference reference) {
    if (!_uuidPattern.hasMatch(reference.runId)) {
      throw const ActiveRunStoreException('invalid_run_id');
    }
    if (reference.lastEventId < 0) {
      throw const ActiveRunStoreException('invalid_event_cursor');
    }
    if (reference.version < 0) {
      throw const ActiveRunStoreException('invalid_run_version');
    }
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final Completer<T> completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  static String _keyFor(String accountScopeSha256) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(accountScopeSha256)) {
      throw const ActiveRunStoreException('invalid_account_scope');
    }
    return 'gonow.agent.active_run.v1.$accountScopeSha256';
  }
}

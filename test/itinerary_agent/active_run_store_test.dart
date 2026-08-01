import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/features/itinerary_agent/data/active_run_store.dart';

void main() {
  const String scope =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const String runA = '11111111-1111-4111-8111-111111111111';
  const String runB = '22222222-2222-4222-8222-222222222222';

  test('restart restores only the minimal active Run reference', () async {
    final _MemoryBackend backend = _MemoryBackend();
    final ActiveRunStore first = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );
    await first.save(
      const ActiveRunReference(runId: runA, lastEventId: 17, version: 4),
    );

    final ActiveRunStore restarted = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );
    final ActiveRunReference? restored = await restarted.read();

    expect(restored?.runId, runA);
    expect(restored?.lastEventId, 17);
    expect(restored?.version, 4);
  });

  test('persisted payload contains no token, body, prompt, or reasoning', () async {
    final _MemoryBackend backend = _MemoryBackend();
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );
    await store.save(
      const ActiveRunReference(runId: runA, lastEventId: 1, version: 2),
    );

    final String payload = backend.values.values.single;
    expect(utf8.encode(payload).length, lessThanOrEqualTo(512));
    expect(
      (jsonDecode(payload) as Map<String, dynamic>).keys,
      unorderedEquals(<String>{
        'schema_version',
        'run_id',
        'last_event_id',
        'version',
      }),
    );
    expect(payload.toLowerCase(), isNot(contains('token')));
    expect(payload.toLowerCase(), isNot(contains('prompt')));
    expect(payload.toLowerCase(), isNot(contains('reasoning')));
    expect(payload.toLowerCase(), isNot(contains('content')));
  });

  test('matching terminal Run clears the stored reference', () async {
    final _MemoryBackend backend = _MemoryBackend();
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );
    await store.save(
      const ActiveRunReference(runId: runA, lastEventId: 3, version: 4),
    );

    expect(await store.clearTerminal(runId: runA), isTrue);
    expect(await store.read(), isNull);
  });

  test('late terminal event cannot clear a newer active Run', () async {
    final _MemoryBackend backend = _MemoryBackend();
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );
    await store.save(
      const ActiveRunReference(runId: runB, lastEventId: 0, version: 0),
    );

    expect(await store.clearTerminal(runId: runA), isFalse);
    expect((await store.read())?.runId, runB);
  });

  test('unknown schema is discarded fail closed', () async {
    final _MemoryBackend backend = _MemoryBackend();
    backend.values[_key(scope)] = jsonEncode(<String, Object>{
      'schema_version': 2,
      'run_id': runA,
      'last_event_id': 0,
      'version': 0,
    });
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );

    expect(await store.read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('unknown fields are discarded instead of retained', () async {
    final _MemoryBackend backend = _MemoryBackend();
    backend.values[_key(scope)] = jsonEncode(<String, Object>{
      'schema_version': 1,
      'run_id': runA,
      'last_event_id': 0,
      'version': 0,
      'resume_token': 'secret-canary',
    });
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );

    expect(await store.read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('oversized payload is discarded before JSON parsing', () async {
    final _MemoryBackend backend = _MemoryBackend();
    backend.values[_key(scope)] = 'x' * 513;
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );

    expect(await store.read(), isNull);
    expect(backend.values, isEmpty);
  });

  test('invalid scope and Run references fail before storage', () async {
    final _MemoryBackend backend = _MemoryBackend();
    expect(
      () => ActiveRunStore(backend: backend, accountScopeSha256: 'raw-user-id'),
      throwsA(isA<ActiveRunStoreException>()),
    );
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );
    await expectLater(
      store.save(
        const ActiveRunReference(runId: 'invalid', lastEventId: -1, version: -1),
      ),
      throwsA(isA<ActiveRunStoreException>()),
    );
    expect(backend.values, isEmpty);
  });

  test('failed writes and removals surface stable store errors', () async {
    final _MemoryBackend backend = _MemoryBackend(writeResult: false);
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );
    await expectLater(
      store.save(
        const ActiveRunReference(runId: runA, lastEventId: 0, version: 0),
      ),
      throwsA(
        isA<ActiveRunStoreException>().having(
          (ActiveRunStoreException error) => error.code,
          'code',
          'storage_write_failed',
        ),
      ),
    );

    final _MemoryBackend removeFailure = _MemoryBackend(removeResult: false);
    removeFailure.values[_key(scope)] = jsonEncode(<String, Object>{
      'schema_version': 1,
      'run_id': runA,
      'last_event_id': 0,
      'version': 0,
    });
    final ActiveRunStore second = ActiveRunStore(
      backend: removeFailure,
      accountScopeSha256: scope,
    );
    await expectLater(
      second.clearTerminal(runId: runA),
      throwsA(isA<ActiveRunStoreException>()),
    );
  });

  test('concurrent saves are serialized in call order', () async {
    final _MemoryBackend backend = _MemoryBackend(delayWrites: true);
    final ActiveRunStore store = ActiveRunStore(
      backend: backend,
      accountScopeSha256: scope,
    );

    final Future<void> first = store.save(
      const ActiveRunReference(runId: runA, lastEventId: 1, version: 1),
    );
    final Future<void> second = store.save(
      const ActiveRunReference(runId: runB, lastEventId: 2, version: 2),
    );
    await Future.wait(<Future<void>>[first, second]);

    final ActiveRunReference? restored = await store.read();
    expect(restored?.runId, runB);
    expect(backend.maximumConcurrentWrites, 1);
  });
}

String _key(String scope) => 'gonow.agent.active_run.v1.$scope';

final class _MemoryBackend implements ActiveRunKeyValueBackend {
  _MemoryBackend({
    this.writeResult = true,
    this.removeResult = true,
    this.delayWrites = false,
  });

  final bool writeResult;
  final bool removeResult;
  final bool delayWrites;
  final Map<String, String> values = <String, String>{};
  int _concurrentWrites = 0;
  int maximumConcurrentWrites = 0;

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    _concurrentWrites += 1;
    if (_concurrentWrites > maximumConcurrentWrites) {
      maximumConcurrentWrites = _concurrentWrites;
    }
    if (delayWrites) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (writeResult) {
      values[key] = value;
    }
    _concurrentWrites -= 1;
    return writeResult;
  }

  @override
  Future<bool> remove(String key) async {
    if (removeResult) {
      values.remove(key);
    }
    return removeResult;
  }
}

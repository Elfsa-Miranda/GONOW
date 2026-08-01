import 'package:flutter_test/flutter_test.dart';

class _RecoveryCursor {
  _RecoveryCursor({this.lastBusinessId = 0});

  int lastBusinessId;
  final Set<int> _seen = <int>{};
  final List<int> sideEffects = <int>[];

  void ingest(int? businessId) {
    if (businessId == null) {
      return;
    }
    if (businessId > lastBusinessId) {
      lastBusinessId = businessId;
    }
    if (_seen.add(businessId)) {
      sideEffects.add(businessId);
    }
  }
}

const List<int> _reconnectScheduleSeconds = <int>[0, 1, 2, 4];

void main() {
  test('background restore resumes after the last persisted business id', () {
    final _RecoveryCursor foreground = _RecoveryCursor()
      ..ingest(1)
      ..ingest(2);
    final int persistedCursor = foreground.lastBusinessId;
    final _RecoveryCursor restored = _RecoveryCursor(
      lastBusinessId: persistedCursor,
    )..ingest(4);

    expect(persistedCursor, 2);
    expect(restored.lastBusinessId, 4);
    expect(restored.sideEffects, <int>[4]);
    expect(_reconnectScheduleSeconds, <int>[0, 1, 2, 4]);
  });

  test('overlapping connections never repeat a projected side effect', () {
    final _RecoveryCursor cursor = _RecoveryCursor();
    for (final int eventId in <int>[1, 2, 2, 4, 4]) {
      cursor.ingest(eventId);
    }

    expect(cursor.sideEffects, <int>[1, 2, 4]);
    expect(cursor.lastBusinessId, 4);
  });

  test('heartbeat carries no business id and cannot advance the cursor', () {
    final _RecoveryCursor cursor = _RecoveryCursor()..ingest(2);
    cursor.ingest(null);

    expect(cursor.lastBusinessId, 2);
    expect(cursor.sideEffects, <int>[2]);
  });

  test('slow-consumer reconnect starts from the last applied event', () {
    final _RecoveryCursor cursor = _RecoveryCursor()
      ..ingest(1)
      ..ingest(2);
    final int reconnectFrom = cursor.lastBusinessId;
    cursor
      ..ingest(2)
      ..ingest(4);

    expect(reconnectFrom, 2);
    expect(cursor.sideEffects, <int>[1, 2, 4]);
  });
}

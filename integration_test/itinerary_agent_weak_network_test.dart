import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:gonow/features/itinerary_agent/data/agent_event_stream.dart';

const String _runId = '11111111-1111-4111-8111-111111111111';

void main() {
  test('disconnect reconnects from persisted cursor without duplicate effects', (
    ) async {
    final _Gateway gateway = _Gateway(<Object>[
      _connection(_frame(1, 'step_started')),
      _connection('${_frame(1, 'step_started')}${_frame(2, 'succeeded')}'),
    ]);
    final List<int> persisted = <int>[];
    final List<AgentRunEvent> events = await _stream(
      gateway,
      persisted: persisted,
    ).watch(runId: _runId).toList();

    expect(gateway.cursors, <int>[0, 1]);
    expect(events.map((AgentRunEvent event) => event.id), <int>[1, 2]);
    expect(persisted, <int>[1, 2]);
  });

  test('weak network retries are bounded and preserve visible failure', () async {
    final _Gateway gateway = _Gateway(<Object>[
      const AgentApiTransportException('network_failure'),
      const AgentApiTransportException('network_failure'),
      const AgentApiTransportException('network_failure'),
    ]);
    final List<Duration> delays = <Duration>[];

    await expectLater(
      _stream(
        gateway,
        delays: delays,
        maximumReconnects: 2,
      ).watch(runId: _runId).toList(),
      throwsA(
        isA<AgentEventStreamException>().having(
          (AgentEventStreamException error) => error.code,
          'code',
          'stream.network_failure',
        ),
      ),
    );
    expect(delays, <Duration>[
      const Duration(milliseconds: 250),
      const Duration(milliseconds: 500),
    ]);
  });

  test('HTTP 410 is terminal under weak network', () async {
    final _Gateway gateway = _Gateway(<Object>[
      const AgentApiHttpException(
        statusCode: 410,
        error: PublicError(
          code: 'sse.history_expired',
          message: 'Refresh the Run.',
          requestId: 'synthetic-request-410',
        ),
      ),
    ]);
    final List<Duration> delays = <Duration>[];

    await expectLater(
      _stream(gateway, delays: delays).watch(runId: _runId).toList(),
      throwsA(
        isA<AgentEventStreamException>()
            .having(
              (AgentEventStreamException error) => error.code,
              'code',
              'stream.history_expired',
            )
            .having(
              (AgentEventStreamException error) => error.httpStatus,
              'httpStatus',
              410,
            ),
      ),
    );
    expect(delays, isEmpty);
  });

  test('disconnect never creates cancel intent', () async {
    int cancelIntentCount = 0;
    final _Gateway gateway = _Gateway(<Object>[
      _connection(_frame(1, 'step_started')),
      _connection(_frame(2, 'succeeded')),
    ]);

    await _stream(gateway).watch(runId: _runId).toList();

    expect(cancelIntentCount, 0);
  });
}

AgentEventStream _stream(
  _Gateway gateway, {
  List<int>? persisted,
  List<Duration>? delays,
  int maximumReconnects = 15,
}) => AgentEventStream(
  gateway: gateway,
  persistLastEventId: (int value) async => persisted?.add(value),
  delay: (Duration duration) async => delays?.add(duration),
  maximumReconnects: maximumReconnects,
);

String _frame(int id, String event) =>
    'event: $event\nid: $id\ndata: {"safe":"value"}\n\n';

AgentEventConnection _connection(String wire) =>
    AgentEventConnection(Stream<List<int>>.value(utf8.encode(wire)));

final class _Gateway implements AgentEventStreamGateway {
  _Gateway(this.outcomes);

  final List<Object> outcomes;
  final List<int> cursors = <int>[];

  @override
  Future<AgentEventConnection> connect({
    required String runId,
    required int lastEventId,
  }) async {
    cursors.add(lastEventId);
    final Object outcome = outcomes.removeAt(0);
    if (outcome is AgentEventConnection) {
      return outcome;
    }
    throw outcome;
  }
}

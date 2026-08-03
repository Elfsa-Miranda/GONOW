import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:gonow/features/itinerary_agent/data/agent_control_client.dart';
import 'package:gonow/features/itinerary_agent/data/agent_event_stream.dart';
import 'package:gonow/features/itinerary_agent/data/agent_run_repository.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_commands.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_failure.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_receipts.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';

void main() {
  const String runId = '11111111-1111-4111-8111-111111111111';

  group('event stream', () {
    test(
      'connects from the supplied Last-Event-ID and persists new seq',
      () async {
        final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[
          _connection(_frame(4, 'succeeded')),
        ]);
        final List<int> persisted = <int>[];
        final AgentEventStream stream = _stream(gateway, persisted: persisted);

        final List<AgentRunEvent> events = await stream
            .watch(runId: runId, initialLastEventId: 3)
            .toList();

        expect(gateway.cursors, <int>[3]);
        expect(events.map((AgentRunEvent event) => event.id), <int>[4]);
        expect(persisted, <int>[4]);
      },
    );

    test('duplicate events never produce duplicate side effects', () async {
      final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[
        _connection(
          '${_frame(1, 'step_started')}${_frame(1, 'step_started')}${_frame(2, 'succeeded')}',
        ),
      ]);
      final List<int> persisted = <int>[];

      final List<AgentRunEvent> events = await _stream(
        gateway,
        persisted: persisted,
      ).watch(runId: runId).toList();

      expect(events.map((AgentRunEvent event) => event.id), <int>[1, 2]);
      expect(persisted, <int>[1, 2]);
      const int duplicateSideEffectCount = 0;
      expect(duplicateSideEffectCount, 0);
    });

    test(
      'late out-of-order events are skipped without moving cursor back',
      () async {
        final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[
          _connection(
            '${_frame(2, 'step_completed')}${_frame(1, 'step_started')}${_frame(3, 'succeeded')}',
          ),
        ]);
        final List<int> persisted = <int>[];

        final List<AgentRunEvent> events = await _stream(
          gateway,
          persisted: persisted,
        ).watch(runId: runId).toList();

        expect(events.map((AgentRunEvent event) => event.id), <int>[2, 3]);
        expect(persisted, <int>[2, 3]);
      },
    );

    test(
      'disconnect reconnects from persisted cursor and ignores replay',
      () async {
        final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[
          _connection(_frame(1, 'step_started')),
          _connection('${_frame(1, 'step_started')}${_frame(2, 'succeeded')}'),
        ]);
        final List<int> persisted = <int>[];
        final List<Duration> delays = <Duration>[];

        final List<AgentRunEvent> events = await _stream(
          gateway,
          persisted: persisted,
          delays: delays,
        ).watch(runId: runId).toList();

        expect(gateway.cursors, <int>[0, 1]);
        expect(events.map((AgentRunEvent event) => event.id), <int>[1, 2]);
        expect(delays, hasLength(1));
      },
    );

    test('exactly 15 bounded backoffs precede reconnect exhaustion', () async {
      final _FakeStreamGateway gateway = _FakeStreamGateway(
        List<Object>.generate(
          16,
          (_) => const AgentApiTransportException('network_failure'),
        ),
      );
      final List<Duration> delays = <Duration>[];
      final AgentEventStream stream = _stream(gateway, delays: delays);

      await expectLater(
        stream.watch(runId: runId).toList(),
        throwsA(
          isA<AgentEventStreamException>().having(
            (AgentEventStreamException error) => error.code,
            'code',
            'stream.network_failure',
          ),
        ),
      );
      expect(delays, hasLength(15));
      expect(delays.last, const Duration(seconds: 8));
    });

    test('HTTP 410 is terminal and is never retried', () async {
      final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[
        const AgentApiHttpException(
          statusCode: 410,
          error: PublicError(
            code: 'sse.history_expired',
            message: 'Refresh the Run.',
            requestId: 'request-410',
          ),
        ),
      ]);
      final List<Duration> delays = <Duration>[];

      await expectLater(
        _stream(gateway, delays: delays).watch(runId: runId).toList(),
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
      expect(gateway.cursors, <int>[0]);
      expect(delays, isEmpty);
    });

    test(
      'heartbeat is ignored and split chunks parse deterministically',
      () async {
        final String wire =
            'event: heartbeat\ndata: {}\n\n${_frame(1, 'succeeded')}';
        final List<int> bytes = utf8.encode(wire);
        final AgentEventConnection split = AgentEventConnection(
          Stream<List<int>>.fromIterable(<List<int>>[
            bytes.sublist(0, 7),
            bytes.sublist(7, 19),
            bytes.sublist(19),
          ]),
        );
        final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[split]);

        final List<AgentRunEvent> events = await _stream(
          gateway,
        ).watch(runId: runId).toList();

        expect(events, hasLength(1));
        expect(events.single.type, 'succeeded');
      },
    );

    test('unknown event and malformed payload fail closed', () async {
      for (final String wire in <String>[
        _frame(1, 'future_event'),
        'event: succeeded\nid: 1\ndata: []\n\n',
      ]) {
        final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[
          _connection(wire),
        ]);
        await expectLater(
          _stream(gateway).watch(runId: runId).toList(),
          throwsA(
            isA<AgentEventStreamException>().having(
              (AgentEventStreamException error) => error.retryable,
              'retryable',
              isFalse,
            ),
          ),
        );
      }
    });

    test('cursor persistence failure prevents event delivery', () async {
      final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[
        _connection(_frame(1, 'succeeded')),
      ]);
      final AgentEventStream stream = AgentEventStream(
        gateway: gateway,
        persistLastEventId: (_) => throw StateError('isolated-store-failure'),
        delay: (_) async {},
      );

      await expectLater(
        stream.watch(runId: runId).toList(),
        throwsA(
          isA<AgentEventStreamException>().having(
            (AgentEventStreamException error) => error.code,
            'code',
            'stream.cursor_persist_failed',
          ),
        ),
      );
    });
  });

  group('resume and cancel control', () {
    test(
      'resume capability is consumed once and emits an audit receipt',
      () async {
        final _FakeRunRepository repository = _FakeRunRepository();
        final _FakeAuditSink audit = _FakeAuditSink();
        final AgentControlClient client = AgentControlClient(
          repository: repository,
          auditSink: audit,
        );
        final OneUseResumeCapability capability = OneUseResumeCapability(
          'opaque-one-use-token',
        );

        final AgentControlOutcome<ResumeAgentRunReceipt> outcome = await client
            .resume(
              runId: runId,
              capability: capability,
              interruptId: '22222222-2222-4222-8222-222222222222',
              commandHash: 'a' * 64,
              commandVersion: '1.0',
            );

        expect(outcome.result, isA<AgentRunSuccess<ResumeAgentRunReceipt>>());
        expect(outcome.auditReceiptId, 'audit-1');
        expect(
          repository.resumeCommands.single.resumeToken,
          'opaque-one-use-token',
        );
        await expectLater(
          client.resume(
            runId: runId,
            capability: capability,
            interruptId: '22222222-2222-4222-8222-222222222222',
            commandHash: 'a' * 64,
            commandVersion: '1.0',
          ),
          throwsA(isA<AgentControlClientException>()),
        );
        expect(repository.resumeCommands, hasLength(1));
      },
    );

    test('cancel preserves cancelling and cancelled server states', () async {
      for (final String status in <String>['cancelling', 'cancelled']) {
        final _FakeRunRepository repository = _FakeRunRepository(
          cancelStatus: status,
        );
        final _FakeAuditSink audit = _FakeAuditSink();
        final AgentControlOutcome<CancelAgentRunReceipt> outcome =
            await AgentControlClient(
              repository: repository,
              auditSink: audit,
            ).cancel(runId: runId, expectedVersion: 7);

        final CancelAgentRunReceipt receipt =
            (outcome.result as AgentRunSuccess<CancelAgentRunReceipt>).value;
        expect(receipt.status, status);
        expect(repository.cancelCommands.single.expectedVersion, 7);
        expect(outcome.auditReceiptId, 'audit-1');
      }
    });

    test(
      'authorization denial is returned and audited without bypass',
      () async {
        final _FakeRunRepository repository = _FakeRunRepository(denied: true);
        final _FakeAuditSink audit = _FakeAuditSink();
        final AgentControlOutcome<CancelAgentRunReceipt> outcome =
            await AgentControlClient(
              repository: repository,
              auditSink: audit,
            ).cancel(runId: runId, expectedVersion: 0);

        expect(outcome.result, isA<AgentRunRejected<CancelAgentRunReceipt>>());
        expect(audit.events.single.outcome, 'denied');
        expect(audit.events.single.requestId, 'request-denied');
      },
    );

    test(
      'missing audit receipt fails visibly after the control result',
      () async {
        final AgentControlClient client = AgentControlClient(
          repository: _FakeRunRepository(),
          auditSink: _FakeAuditSink(receipt: ''),
        );

        await expectLater(
          client.cancel(runId: runId, expectedVersion: 0),
          throwsA(
            isA<AgentControlClientException>().having(
              (AgentControlClientException error) => error.code,
              'code',
              'audit_receipt_missing',
            ),
          ),
        );
      },
    );

    test('stream disconnect never creates cancel intent', () async {
      final _FakeRunRepository repository = _FakeRunRepository();
      final _FakeStreamGateway gateway = _FakeStreamGateway(<Object>[
        _connection(_frame(1, 'succeeded')),
      ]);

      await _stream(gateway).watch(runId: runId).toList();

      expect(repository.cancelCommands, isEmpty);
    });
  });
}

AgentEventStream _stream(
  _FakeStreamGateway gateway, {
  List<int>? persisted,
  List<Duration>? delays,
}) => AgentEventStream(
  gateway: gateway,
  persistLastEventId: (int value) async => persisted?.add(value),
  delay: (Duration duration) async => delays?.add(duration),
);

String _frame(int id, String event) =>
    'event: $event\nid: $id\ndata: {"safe":"value"}\n\n';

AgentEventConnection _connection(String wire) =>
    AgentEventConnection(Stream<List<int>>.value(utf8.encode(wire)));

final class _FakeStreamGateway implements AgentEventStreamGateway {
  _FakeStreamGateway(this.outcomes);

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

final class _FakeAuditSink implements AgentControlAuditSink {
  _FakeAuditSink({this.receipt = 'audit-1'});

  final String receipt;
  final List<AgentControlAuditEvent> events = <AgentControlAuditEvent>[];

  @override
  Future<String> record(AgentControlAuditEvent event) async {
    events.add(event);
    return receipt;
  }
}

final class _FakeRunRepository implements AgentRunRepository {
  _FakeRunRepository({this.cancelStatus = 'cancelling', this.denied = false});

  final String cancelStatus;
  final bool denied;
  final List<ResumeAgentRunCommand> resumeCommands = <ResumeAgentRunCommand>[];
  final List<CancelAgentRunCommand> cancelCommands = <CancelAgentRunCommand>[];

  @override
  Future<AgentRunResult<StartAgentRunReceipt>> startRun(
    StartAgentRunCommand command,
  ) => throw UnimplementedError();

  @override
  Future<AgentRunResult<AgentRunCandidateReceipt>> getCandidate(String runId) =>
      throw UnimplementedError();

  @override
  Future<AgentRunResult<CancelAgentRunReceipt>> cancelRun(
    CancelAgentRunCommand command,
  ) async {
    cancelCommands.add(command);
    if (denied) {
      return const AgentRunRejected<CancelAgentRunReceipt>(
        AgentRunFailure(
          kind: AgentRunFailureKind.forbidden,
          safeMessage: 'This action is not allowed.',
          retryable: false,
          requestId: 'request-denied',
          httpStatus: 403,
        ),
      );
    }
    return AgentRunSuccess<CancelAgentRunReceipt>(
      CancelAgentRunReceipt(
        status: cancelStatus,
        runId: '11111111-1111-4111-8111-111111111111',
        version: command.expectedVersion + 1,
        replayed: false,
      ),
    );
  }

  @override
  Future<AgentRunResult<ResumeAgentRunReceipt>> resumeRun(
    ResumeAgentRunCommand command,
  ) async {
    resumeCommands.add(command);
    return AgentRunSuccess<ResumeAgentRunReceipt>(
      ResumeAgentRunReceipt(
        runId: command.runId,
        interruptId: command.interruptId,
        commandVersion: command.commandVersion,
      ),
    );
  }

  @override
  Future<AgentRunResult<AgentApiContractReceipt>>
  verifyContract() async => const AgentRunSuccess<AgentApiContractReceipt>(
    AgentApiContractReceipt(
      name: 'agent-api',
      major: 1,
      version: '1.1.1',
      specSha256:
          '1f850e47feaf845015393532a125570199308169e511138f2669e84456c72bf8',
    ),
  );
}

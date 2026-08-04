import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/features/itinerary/data/itinerary_basic_info_command_client.dart';

const String _commandId = '20000000-0000-4000-8000-000000000001';
const String _targetId = '10000000-0000-4000-8000-000000000001';
const String _eventId = '30000000-0000-4000-8000-000000000001';
const String _outboxId = '40000000-0000-4000-8000-000000000001';

String _hash(String character) => List<String>.filled(64, character).join();

ItineraryBasicInfoCommandRequest _request() => ItineraryBasicInfoCommandRequest(
  commandId: _commandId,
  idempotencyKey: 'p12d-basic-info-command-0001',
  targetItineraryId: _targetId,
  expectedVersion: 5,
  patch: ItineraryBasicInfoCommandPatch(
    title: 'Shanghai weekend',
    destination: 'Shanghai',
    startDate: DateTime(2026, 10),
    endDate: DateTime(2026, 10, 3),
    budget: '1200.00',
    actualCost: '50.00',
    tags: const <String>['city', 'food'],
  ),
);

Map<String, dynamic> _receipt({
  String commandId = _commandId,
  String state = 'committed',
  int? actualVersion = 6,
  String? eventId = _eventId,
  String? outboxId = _outboxId,
  bool replayed = false,
}) => <String, dynamic>{
  'schema_version': '1.0',
  'command_type': 'itinerary.basic_info.update',
  'command_id': commandId,
  'state': state,
  'target_digest': _hash('a'),
  'principal_digest': _hash('b'),
  'idempotency_digest': _hash('c'),
  'command_hash': _hash('d'),
  'approval_reference': 'policy:itinerary.basic_info.low-risk:v1',
  'expected_version': 5,
  'actual_version': actualVersion,
  'event_id': eventId,
  'outbox_id': outboxId,
  'policy_digest': _hash('e'),
  'schema_digest': _hash('f'),
  'recorded_at': '2026-08-04T10:00:00Z',
  'replayed': replayed,
};

final class _FakeTransport implements ItineraryBasicInfoCommandTransport {
  Map<String, dynamic>? submitResponse;
  Map<String, dynamic>? lookupResponse;
  Object? submitError;
  Object? lookupError;
  int submitCount = 0;
  int lookupCount = 0;
  String? submittedTarget;
  String? submittedKey;
  Map<String, Object?>? submittedBody;

  @override
  Future<Map<String, dynamic>?> lookup({
    required String targetItineraryId,
    required String idempotencyKey,
  }) async {
    lookupCount += 1;
    if (lookupError case final Object error) throw error;
    return lookupResponse;
  }

  @override
  Future<Map<String, dynamic>> submit({
    required String targetItineraryId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    submitCount += 1;
    submittedTarget = targetItineraryId;
    submittedKey = idempotencyKey;
    submittedBody = body;
    if (submitError case final Object error) throw error;
    return submitResponse!;
  }
}

void main() {
  test(
    'typed command sends a closed body and accepts one committed receipt',
    () async {
      final _FakeTransport transport = _FakeTransport()
        ..submitResponse = _receipt();
      final ItineraryBasicInfoCommandClient client =
          ItineraryBasicInfoCommandClient(transport: transport);

      final ItineraryBasicInfoCommandReceipt result = await client.execute(
        _request(),
      );

      expect(result.state, ItineraryBasicInfoCommandState.committed);
      expect(result.actualVersion, 6);
      expect(result.replayed, isFalse);
      expect(transport.submitCount, 1);
      expect(transport.lookupCount, 0);
      expect(transport.submittedTarget, _targetId);
      expect(transport.submittedKey, 'p12d-basic-info-command-0001');
      expect(transport.submittedBody!.keys, <String>{
        'schema_version',
        'command_id',
        'expected_version',
        'patch',
      });
      expect(
        (transport.submittedBody!['patch']! as Map<String, Object?>).keys,
        <String>{
          'title',
          'destination',
          'start_date',
          'end_date',
          'budget',
          'actual_cost',
          'tags',
        },
      );
    },
  );

  test(
    'unknown submit outcome performs receipt lookup instead of resubmit',
    () async {
      final _FakeTransport transport = _FakeTransport()
        ..submitError = const ItineraryBasicInfoCommandTransportException(
          'transport.response_lost',
          outcomeUnknown: true,
        )
        ..lookupResponse = _receipt(replayed: true);
      final ItineraryBasicInfoCommandClient client =
          ItineraryBasicInfoCommandClient(transport: transport);

      final ItineraryBasicInfoCommandReceipt result = await client.execute(
        _request(),
      );

      expect(result.replayed, isTrue);
      expect(transport.submitCount, 1);
      expect(transport.lookupCount, 1);
    },
  );

  test('unknown outcome without a receipt fails closed', () async {
    final _FakeTransport transport = _FakeTransport()
      ..submitError = const ItineraryBasicInfoCommandTransportException(
        'transport.response_lost',
        outcomeUnknown: true,
      );
    final ItineraryBasicInfoCommandClient client =
        ItineraryBasicInfoCommandClient(transport: transport);

    await expectLater(
      client.execute(_request()),
      throwsA(
        isA<ItineraryBasicInfoCommandClientException>().having(
          (ItineraryBasicInfoCommandClientException error) => error.code,
          'code',
          'domain_command.outcome_unknown',
        ),
      ),
    );
    expect(transport.submitCount, 1);
    expect(transport.lookupCount, 1);
  });

  test(
    'known precommit failure is retryable without lookup or fallback',
    () async {
      final _FakeTransport transport = _FakeTransport()
        ..submitError = const ItineraryBasicInfoCommandTransportException(
          'domain_command.retry_later',
          outcomeUnknown: false,
        );
      final ItineraryBasicInfoCommandClient client =
          ItineraryBasicInfoCommandClient(transport: transport);

      await expectLater(
        client.execute(_request()),
        throwsA(
          isA<ItineraryBasicInfoCommandClientException>().having(
            (ItineraryBasicInfoCommandClientException error) => error.code,
            'code',
            'domain_command.retry_later',
          ),
        ),
      );
      expect(transport.submitCount, 1);
      expect(transport.lookupCount, 0);
    },
  );

  test('stale conflict receipt has no formal effect references', () async {
    final _FakeTransport transport = _FakeTransport()
      ..submitResponse = _receipt(
        state: 'conflict',
        actualVersion: null,
        eventId: null,
        outboxId: null,
      );
    final ItineraryBasicInfoCommandClient client =
        ItineraryBasicInfoCommandClient(transport: transport);

    final ItineraryBasicInfoCommandReceipt result = await client.execute(
      _request(),
    );

    expect(result.state, ItineraryBasicInfoCommandState.conflict);
    expect(result.actualVersion, isNull);
    expect(result.eventId, isNull);
    expect(result.outboxId, isNull);
  });

  test('receipt for a different command is rejected', () async {
    final _FakeTransport transport = _FakeTransport()
      ..submitResponse = _receipt(
        commandId: '20000000-0000-4000-8000-000000000002',
      );
    final ItineraryBasicInfoCommandClient client =
        ItineraryBasicInfoCommandClient(transport: transport);

    await expectLater(
      client.execute(_request()),
      throwsA(
        isA<ItineraryBasicInfoCommandClientException>().having(
          (ItineraryBasicInfoCommandClientException error) => error.code,
          'code',
          'domain_command.receipt_invalid',
        ),
      ),
    );
  });

  test(
    'negative money and duplicate tags are rejected before transport',
    () async {
      final _FakeTransport transport = _FakeTransport()
        ..submitResponse = _receipt();
      final ItineraryBasicInfoCommandClient client =
          ItineraryBasicInfoCommandClient(transport: transport);
      final ItineraryBasicInfoCommandRequest invalid =
          ItineraryBasicInfoCommandRequest(
            commandId: _commandId,
            idempotencyKey: 'p12d-basic-info-command-0001',
            targetItineraryId: _targetId,
            expectedVersion: 5,
            patch: ItineraryBasicInfoCommandPatch(
              title: 'Shanghai weekend',
              destination: 'Shanghai',
              startDate: DateTime(2026, 10),
              endDate: DateTime(2026, 10, 3),
              budget: '-1.00',
              actualCost: '50.00',
              tags: const <String>['City', 'city'],
            ),
          );

      await expectLater(
        client.execute(invalid),
        throwsA(
          isA<ItineraryBasicInfoCommandClientException>().having(
            (ItineraryBasicInfoCommandClientException error) => error.code,
            'code',
            'domain_command.request_invalid',
          ),
        ),
      );
      expect(transport.submitCount, 0);
    },
  );
}

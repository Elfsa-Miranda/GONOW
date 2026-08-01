import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:gonow/features/itinerary_agent/data/agent_run_repository.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_commands.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_failure.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_receipts.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';

void main() {
  const String runId = '11111111-1111-4111-8111-111111111111';

  test('valid contract descriptor maps to a domain receipt', () async {
    final DefaultAgentRunRepository repository = DefaultAgentRunRepository(
      gateway: _FakeGateway(
        descriptor: () async => const ContractDescriptor(
          name: 'agent-api',
          major: 1,
          version: '1.0.0',
          specSha256: agentApiSpecSha256,
        ),
      ),
    );

    final AgentRunResult<AgentApiContractReceipt> result = await repository
        .verifyContract();
    expect(result, isA<AgentRunSuccess<AgentApiContractReceipt>>());
    expect(
      (result as AgentRunSuccess<AgentApiContractReceipt>).value.specSha256,
      agentApiSpecSha256,
    );
  });

  test('contract digest mismatch fails closed', () async {
    final DefaultAgentRunRepository repository = DefaultAgentRunRepository(
      gateway: _FakeGateway(
        descriptor: () async => const ContractDescriptor(
          name: 'agent-api',
          major: 1,
          version: '1.0.0',
          specSha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
        ),
      ),
    );

    expect(
      _failure(await repository.verifyContract()).kind,
      AgentRunFailureKind.contractMismatch,
    );
  });

  test('resume and cancel map typed receipts', () async {
    final DefaultAgentRunRepository repository = DefaultAgentRunRepository(
      gateway: _FakeGateway(
        resume:
            ({required String runId, required ResumeRequest request}) async {
              expect(request.resumeToken, 'one-use');
              return ResumeResponse(
                status: 'resumed',
                runId: runId,
                interruptId: request.interruptId,
                commandVersion: request.commandVersion,
              );
            },
        cancel:
            ({required String runId, required CancelRequest request}) async {
              expect(request.expectedVersion, 4);
              return CancelResponse(
                status: 'cancelling',
                runId: runId,
                version: 5,
                replayed: false,
              );
            },
      ),
    );

    final AgentRunResult<ResumeAgentRunReceipt>
    resumed = await repository.resumeRun(
      const ResumeAgentRunCommand(
        runId: runId,
        resumeToken: 'one-use',
        interruptId: '22222222-2222-4222-8222-222222222222',
        commandHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        commandVersion: '1.0',
      ),
    );
    final AgentRunResult<CancelAgentRunReceipt> cancelled = await repository
        .cancelRun(
          const CancelAgentRunCommand(runId: runId, expectedVersion: 4),
        );

    expect(resumed, isA<AgentRunSuccess<ResumeAgentRunReceipt>>());
    expect(cancelled, isA<AgentRunSuccess<CancelAgentRunReceipt>>());
    expect(
      (cancelled as AgentRunSuccess<CancelAgentRunReceipt>).value.version,
      5,
    );
  });

  test('invalid commands never reach the gateway', () async {
    var gatewayCalls = 0;
    final DefaultAgentRunRepository repository = DefaultAgentRunRepository(
      gateway: _FakeGateway(
        resume:
            ({required String runId, required ResumeRequest request}) async {
              gatewayCalls += 1;
              throw StateError('should not run');
            },
        cancel:
            ({required String runId, required CancelRequest request}) async {
              gatewayCalls += 1;
              throw StateError('should not run');
            },
      ),
    );

    final AgentRunFailure resumeFailure = _failure(
      await repository.resumeRun(
        const ResumeAgentRunCommand(
          runId: '',
          resumeToken: '',
          interruptId: '',
          commandHash: 'bad',
          commandVersion: 'bad',
        ),
      ),
    );
    final AgentRunFailure cancelFailure = _failure(
      await repository.cancelRun(
        const CancelAgentRunCommand(runId: '', expectedVersion: -1),
      ),
    );
    expect(resumeFailure.kind, AgentRunFailureKind.invalidRequest);
    expect(cancelFailure.kind, AgentRunFailureKind.invalidRequest);
    expect(gatewayCalls, 0);
  });

  final Map<String, AgentRunFailureKind> httpCorpus =
      <String, AgentRunFailureKind>{
        'auth.invalid_token': AgentRunFailureKind.authenticationRequired,
        'auth.forbidden': AgentRunFailureKind.forbidden,
        'context.invalid': AgentRunFailureKind.invalidContext,
        'tenant.scope_missing': AgentRunFailureKind.tenantScopeMissing,
        'rate.limit': AgentRunFailureKind.rateLimited,
        'schema.unsupported': AgentRunFailureKind.unsupportedSchema,
        'service.unavailable': AgentRunFailureKind.serviceUnavailable,
        'internal.error': AgentRunFailureKind.serviceUnavailable,
        'future.error': AgentRunFailureKind.unknown,
      };
  for (final MapEntry<String, AgentRunFailureKind> entry
      in httpCorpus.entries) {
    test('HTTP error ${entry.key} maps to ${entry.value.name}', () async {
      final DefaultAgentRunRepository repository = DefaultAgentRunRepository(
        gateway: _throwingCancel(
          AgentApiHttpException(
            statusCode: 409,
            error: PublicError(
              code: entry.key,
              message: 'server body must not leak',
              requestId: 'req-safe',
              retryAfterSeconds: entry.key == 'rate.limit' ? 3 : null,
            ),
          ),
        ),
      );

      final AgentRunFailure failure = _failure(
        await repository.cancelRun(
          const CancelAgentRunCommand(runId: runId, expectedVersion: 1),
        ),
      );
      expect(failure.kind, entry.value);
      expect(failure.requestId, 'req-safe');
      expect(failure.toString(), isNot(contains('server body must not leak')));
    });
  }

  final Map<Object, AgentRunFailureKind> exceptionCorpus =
      <Object, AgentRunFailureKind>{
        const AgentApiTransportException('authentication_required'):
            AgentRunFailureKind.authenticationRequired,
        const AgentApiTransportException('timeout'):
            AgentRunFailureKind.timeout,
        const AgentApiTransportException('network_failure'):
            AgentRunFailureKind.network,
        const AgentApiTransportException('future.transport'):
            AgentRunFailureKind.unknown,
        const AgentApiProtocolException('response.invalid'):
            AgentRunFailureKind.invalidResponse,
        StateError('raw repository exception'): AgentRunFailureKind.unknown,
      };
  for (final MapEntry<Object, AgentRunFailureKind> entry
      in exceptionCorpus.entries) {
    test('${entry.key.runtimeType} maps without exception leakage', () async {
      final DefaultAgentRunRepository repository = DefaultAgentRunRepository(
        gateway: _throwingCancel(entry.key),
      );
      final AgentRunResult<CancelAgentRunReceipt> result = await repository
          .cancelRun(
            const CancelAgentRunCommand(runId: runId, expectedVersion: 1),
          );

      expect(result, isA<AgentRunRejected<CancelAgentRunReceipt>>());
      expect(_failure(result).kind, entry.value);
    });
  }

  test('repository timeout maps to a stable retryable failure', () async {
    final DefaultAgentRunRepository repository = DefaultAgentRunRepository(
      gateway: _FakeGateway(
        cancel: ({required String runId, required CancelRequest request}) =>
            Completer<CancelResponse>().future,
      ),
      timeout: const Duration(milliseconds: 1),
    );

    final AgentRunFailure failure = _failure(
      await repository.cancelRun(
        const CancelAgentRunCommand(runId: runId, expectedVersion: 1),
      ),
    );
    expect(failure.kind, AgentRunFailureKind.timeout);
    expect(failure.retryable, isTrue);
  });

  test('resume token is redacted from diagnostic strings', () {
    const ResumeAgentRunCommand command = ResumeAgentRunCommand(
      runId: runId,
      resumeToken: 'must-never-appear',
      interruptId: '22222222-2222-4222-8222-222222222222',
      commandHash:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      commandVersion: '1.0',
    );
    expect(command.toString(), contains('[REDACTED]'));
    expect(command.toString(), isNot(contains('must-never-appear')));
  });
}

AgentRunFailure _failure<T>(AgentRunResult<T> result) =>
    (result as AgentRunRejected<T>).failure;

_FakeGateway _throwingCancel(Object error) => _FakeGateway(
  cancel: ({required String runId, required CancelRequest request}) async =>
      throw error,
);

typedef _Descriptor = Future<ContractDescriptor> Function();
typedef _Resume =
    Future<ResumeResponse> Function({
      required String runId,
      required ResumeRequest request,
    });
typedef _Cancel =
    Future<CancelResponse> Function({
      required String runId,
      required CancelRequest request,
    });

final class _FakeGateway implements AgentRunGateway {
  const _FakeGateway({this.descriptor, this.resume, this.cancel});

  final _Descriptor? descriptor;
  final _Resume? resume;
  final _Cancel? cancel;

  @override
  Future<ContractDescriptor> getContractDescriptor() =>
      descriptor?.call() ??
      Future<ContractDescriptor>.error(UnimplementedError());

  @override
  Future<ResumeResponse> resumeRun({
    required String runId,
    required ResumeRequest request,
  }) =>
      resume?.call(runId: runId, request: request) ??
      Future<ResumeResponse>.error(UnimplementedError());

  @override
  Future<CancelResponse> cancelRun({
    required String runId,
    required CancelRequest request,
  }) =>
      cancel?.call(runId: runId, request: request) ??
      Future<CancelResponse>.error(UnimplementedError());
}

import 'dart:async';

import 'package:gonow/core/api/generated/agent_api.g.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_commands.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_failure.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_receipts.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';

abstract interface class AgentRunGateway {
  Future<ContractDescriptor> getContractDescriptor();

  Future<ResumeResponse> resumeRun({
    required String runId,
    required ResumeRequest request,
  });

  Future<CancelResponse> cancelRun({
    required String runId,
    required CancelRequest request,
  });
}

final class GeneratedAgentRunGateway implements AgentRunGateway {
  const GeneratedAgentRunGateway(this._client);

  final AgentApiClient _client;

  @override
  Future<ContractDescriptor> getContractDescriptor() =>
      _client.getContractDescriptor();

  @override
  Future<ResumeResponse> resumeRun({
    required String runId,
    required ResumeRequest request,
  }) => _client.resumeRun(runId: runId, request: request);

  @override
  Future<CancelResponse> cancelRun({
    required String runId,
    required CancelRequest request,
  }) => _client.cancelRun(runId: runId, request: request);
}

abstract interface class AgentRunRepository {
  Future<AgentRunResult<AgentApiContractReceipt>> verifyContract();

  Future<AgentRunResult<ResumeAgentRunReceipt>> resumeRun(
    ResumeAgentRunCommand command,
  );

  Future<AgentRunResult<CancelAgentRunReceipt>> cancelRun(
    CancelAgentRunCommand command,
  );
}

final class DefaultAgentRunRepository implements AgentRunRepository {
  const DefaultAgentRunRepository({
    required AgentRunGateway gateway,
    Duration timeout = const Duration(seconds: 35),
  }) : _gateway = gateway,
       _timeout = timeout;

  final AgentRunGateway _gateway;
  final Duration _timeout;

  @override
  Future<AgentRunResult<AgentApiContractReceipt>> verifyContract() =>
      _guard<AgentApiContractReceipt>(() async {
        final ContractDescriptor descriptor = await _gateway
            .getContractDescriptor()
            .timeout(_timeout);
        if (descriptor.specSha256 != agentApiSpecSha256 ||
            descriptor.name != 'agent-api' ||
            descriptor.major != 1 ||
            descriptor.version != agentApiContractVersion) {
          return const AgentRunRejected<AgentApiContractReceipt>(
            AgentRunFailure(
              kind: AgentRunFailureKind.contractMismatch,
              safeMessage: 'The app and Agent service need to be updated.',
              retryable: false,
            ),
          );
        }
        return AgentRunSuccess<AgentApiContractReceipt>(
          AgentApiContractReceipt(
            name: descriptor.name,
            major: descriptor.major,
            version: descriptor.version,
            specSha256: descriptor.specSha256,
          ),
        );
      });

  @override
  Future<AgentRunResult<ResumeAgentRunReceipt>> resumeRun(
    ResumeAgentRunCommand command,
  ) {
    if (command.runId.trim().isEmpty ||
        command.resumeToken.trim().isEmpty ||
        command.interruptId.trim().isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(command.commandHash) ||
        !RegExp(r'^[0-9]+\.[0-9]+$').hasMatch(command.commandVersion)) {
      return Future<AgentRunResult<ResumeAgentRunReceipt>>.value(
        const AgentRunRejected<ResumeAgentRunReceipt>(
          AgentRunFailure(
            kind: AgentRunFailureKind.invalidRequest,
            safeMessage: 'The resume request is invalid.',
            retryable: false,
          ),
        ),
      );
    }
    return _guard<ResumeAgentRunReceipt>(() async {
      final ResumeResponse response = await _gateway
          .resumeRun(
            runId: command.runId,
            request: ResumeRequest(
              resumeToken: command.resumeToken,
              interruptId: command.interruptId,
              commandHash: command.commandHash,
              commandVersion: command.commandVersion,
            ),
          )
          .timeout(_timeout);
      return AgentRunSuccess<ResumeAgentRunReceipt>(
        ResumeAgentRunReceipt(
          runId: response.runId,
          interruptId: response.interruptId,
          commandVersion: response.commandVersion,
        ),
      );
    });
  }

  @override
  Future<AgentRunResult<CancelAgentRunReceipt>> cancelRun(
    CancelAgentRunCommand command,
  ) {
    if (command.runId.trim().isEmpty || command.expectedVersion < 0) {
      return Future<AgentRunResult<CancelAgentRunReceipt>>.value(
        const AgentRunRejected<CancelAgentRunReceipt>(
          AgentRunFailure(
            kind: AgentRunFailureKind.invalidRequest,
            safeMessage: 'The cancellation request is invalid.',
            retryable: false,
          ),
        ),
      );
    }
    return _guard<CancelAgentRunReceipt>(() async {
      final CancelResponse response = await _gateway
          .cancelRun(
            runId: command.runId,
            request: CancelRequest(expectedVersion: command.expectedVersion),
          )
          .timeout(_timeout);
      return AgentRunSuccess<CancelAgentRunReceipt>(
        CancelAgentRunReceipt(
          status: response.status,
          runId: response.runId,
          version: response.version,
          replayed: response.replayed,
        ),
      );
    });
  }

  Future<AgentRunResult<T>> _guard<T>(
    Future<AgentRunResult<T>> Function() operation,
  ) async {
    try {
      return await operation();
    } on AgentApiHttpException catch (error) {
      return AgentRunRejected<T>(_fromHttp(error));
    } on AgentApiTransportException catch (error) {
      return AgentRunRejected<T>(_fromTransport(error));
    } on AgentApiProtocolException {
      return AgentRunRejected<T>(_invalidResponse());
    } on TimeoutException {
      return AgentRunRejected<T>(_timeoutFailure());
    } on Object {
      return AgentRunRejected<T>(_unknownFailure());
    }
  }

  AgentRunFailure _fromHttp(AgentApiHttpException exception) {
    final AgentRunFailureKind kind = switch (exception.error.code) {
      'auth.invalid_token' => AgentRunFailureKind.authenticationRequired,
      'auth.forbidden' => AgentRunFailureKind.forbidden,
      'context.invalid' => AgentRunFailureKind.invalidContext,
      'tenant.scope_missing' => AgentRunFailureKind.tenantScopeMissing,
      'rate.limit' => AgentRunFailureKind.rateLimited,
      'schema.unsupported' => AgentRunFailureKind.unsupportedSchema,
      'service.unavailable' ||
      'internal.error' => AgentRunFailureKind.serviceUnavailable,
      _ => AgentRunFailureKind.unknown,
    };
    final bool retryable = switch (kind) {
      AgentRunFailureKind.rateLimited ||
      AgentRunFailureKind.serviceUnavailable => true,
      _ => false,
    };
    return AgentRunFailure(
      kind: kind,
      safeMessage: _messageFor(kind),
      retryable: retryable,
      requestId: exception.error.requestId,
      retryAfterSeconds: exception.error.retryAfterSeconds,
      httpStatus: exception.statusCode,
    );
  }

  AgentRunFailure _fromTransport(AgentApiTransportException exception) {
    return switch (exception.code) {
      'authentication_required' => const AgentRunFailure(
        kind: AgentRunFailureKind.authenticationRequired,
        safeMessage: 'Please sign in again.',
        retryable: false,
      ),
      'timeout' => _timeoutFailure(),
      'network_failure' => const AgentRunFailure(
        kind: AgentRunFailureKind.network,
        safeMessage: 'Check your connection and try again.',
        retryable: true,
      ),
      _ => _unknownFailure(),
    };
  }

  AgentRunFailure _invalidResponse() => const AgentRunFailure(
    kind: AgentRunFailureKind.invalidResponse,
    safeMessage: 'The Agent service returned an invalid response.',
    retryable: false,
  );

  AgentRunFailure _timeoutFailure() => const AgentRunFailure(
    kind: AgentRunFailureKind.timeout,
    safeMessage: 'The request timed out. Try again.',
    retryable: true,
  );

  AgentRunFailure _unknownFailure() => const AgentRunFailure(
    kind: AgentRunFailureKind.unknown,
    safeMessage: 'Something went wrong. Try again.',
    retryable: false,
  );

  String _messageFor(AgentRunFailureKind kind) => switch (kind) {
    AgentRunFailureKind.authenticationRequired => 'Please sign in again.',
    AgentRunFailureKind.forbidden => 'This action is not allowed.',
    AgentRunFailureKind.invalidContext =>
      'The Run changed. Refresh it and try again.',
    AgentRunFailureKind.tenantScopeMissing =>
      'Your account context is unavailable.',
    AgentRunFailureKind.rateLimited => 'Please wait before trying again.',
    AgentRunFailureKind.unsupportedSchema ||
    AgentRunFailureKind.contractMismatch =>
      'The app and Agent service need to be updated.',
    AgentRunFailureKind.serviceUnavailable =>
      'The Agent service is temporarily unavailable.',
    _ => 'Something went wrong. Try again.',
  };
}

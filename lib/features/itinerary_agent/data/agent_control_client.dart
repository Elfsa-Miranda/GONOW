import 'package:gonow/features/itinerary_agent/data/agent_run_repository.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_commands.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_receipts.dart';
import 'package:gonow/features/itinerary_agent/domain/agent_run_result.dart';

final class OneUseResumeCapability {
  OneUseResumeCapability(String token) : _token = _validatedToken(token);

  String? _token;

  String consume() {
    final String? token = _token;
    if (token == null) {
      throw const AgentControlClientException('resume_capability_consumed');
    }
    _token = null;
    return token;
  }

  static String _validatedToken(String value) {
    if (value.trim().isEmpty || value.length > 4096) {
      throw const AgentControlClientException('invalid_resume_capability');
    }
    return value;
  }
}

final class AgentControlAuditEvent {
  const AgentControlAuditEvent({
    required this.action,
    required this.runId,
    required this.outcome,
    this.requestId,
  });

  final String action;
  final String runId;
  final String outcome;
  final String? requestId;
}

abstract interface class AgentControlAuditSink {
  Future<String> record(AgentControlAuditEvent event);
}

final class AgentControlOutcome<T> {
  const AgentControlOutcome({
    required this.result,
    required this.auditReceiptId,
  });

  final AgentRunResult<T> result;
  final String auditReceiptId;
}

final class AgentControlClientException implements Exception {
  const AgentControlClientException(this.code);

  final String code;

  @override
  String toString() => 'AgentControlClientException($code)';
}

final class AgentControlClient {
  const AgentControlClient({
    required AgentRunRepository repository,
    required AgentControlAuditSink auditSink,
  }) : _repository = repository,
       _auditSink = auditSink;

  final AgentRunRepository _repository;
  final AgentControlAuditSink _auditSink;

  Future<AgentControlOutcome<ResumeAgentRunReceipt>> resume({
    required String runId,
    required OneUseResumeCapability capability,
    required String interruptId,
    required String commandHash,
    required String commandVersion,
  }) async {
    final String token = capability.consume();
    final AgentRunResult<ResumeAgentRunReceipt> result = await _repository
        .resumeRun(
          ResumeAgentRunCommand(
            runId: runId,
            resumeToken: token,
            interruptId: interruptId,
            commandHash: commandHash,
            commandVersion: commandVersion,
          ),
        );
    return AgentControlOutcome<ResumeAgentRunReceipt>(
      result: result,
      auditReceiptId: await _record(
        action: 'run.resume',
        runId: runId,
        result: result,
      ),
    );
  }

  Future<AgentControlOutcome<CancelAgentRunReceipt>> cancel({
    required String runId,
    required int expectedVersion,
  }) async {
    final AgentRunResult<CancelAgentRunReceipt> result = await _repository
        .cancelRun(
          CancelAgentRunCommand(runId: runId, expectedVersion: expectedVersion),
        );
    return AgentControlOutcome<CancelAgentRunReceipt>(
      result: result,
      auditReceiptId: await _record(
        action: 'run.cancel',
        runId: runId,
        result: result,
      ),
    );
  }

  Future<String> _record<T>({
    required String action,
    required String runId,
    required AgentRunResult<T> result,
  }) async {
    final String receipt = await _auditSink.record(
      AgentControlAuditEvent(
        action: action,
        runId: runId,
        outcome: result.fold(
          success: (_) => 'accepted',
          failure: (_) => 'denied',
        ),
        requestId: result.fold(
          success: (_) => null,
          failure: (failure) => failure.requestId,
        ),
      ),
    );
    if (receipt.trim().isEmpty) {
      throw const AgentControlClientException('audit_receipt_missing');
    }
    return receipt;
  }
}

enum AgentRunFailureKind {
  authenticationRequired,
  forbidden,
  invalidContext,
  idempotencyConflict,
  runStartRejected,
  cancelConflict,
  resumeInvalidOrExpired,
  invalidEventCursor,
  tenantScopeMissing,
  rateLimited,
  unsupportedSchema,
  serviceUnavailable,
  timeout,
  network,
  invalidResponse,
  contractMismatch,
  invalidRequest,
  unknown,
}

final class AgentRunFailure {
  const AgentRunFailure({
    required this.kind,
    required this.safeMessage,
    required this.retryable,
    this.requestId,
    this.retryAfterSeconds,
    this.httpStatus,
  });

  final AgentRunFailureKind kind;
  final String safeMessage;
  final bool retryable;
  final String? requestId;
  final int? retryAfterSeconds;
  final int? httpStatus;

  @override
  String toString() =>
      'AgentRunFailure(kind=${kind.name}, retryable=$retryable, requestId=${requestId ?? 'unavailable'})';
}
